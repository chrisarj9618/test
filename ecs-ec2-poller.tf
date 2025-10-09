# Terraform project layout

This example provisions a **GitLab Runner manager EC2 instance** that uses **Fleeting + AWS plugin** to launch ephemeral EC2 workers per job. Fill in the variables in `terraform.tfvars`.

---

## files

- `main.tf`
- `variables.tf`
- `outputs.tf`
- `templates/config.toml.tmpl`
- `templates/user_data.sh.tmpl`
- `terraform.tfvars` (create this locally; example at bottom)

---

### main.tf
```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# --- VPC & Subnet discovery (data model) ---
# Select VPC by id or by tag:Name
data "aws_vpc" "by_id" {
  count = var.vpc_id != "" ? 1 : 0
  id    = var.vpc_id
}

data "aws_vpc" "by_name" {
  count = var.vpc_id == "" && var.vpc_name != "" ? 1 : 0
  filter { name = "tag:Name" values = [var.vpc_name] }
}

data "aws_vpc" "default" {
  count = var.vpc_id == "" && var.vpc_name == "" ? 1 : 0
  default = true
}

locals {
  vpc_id = coalesce(
    try(data.aws_vpc.by_id[0].id, null),
    try(data.aws_vpc.by_name[0].id, null),
    try(data.aws_vpc.default[0].id, null)
  )

  # Discover subnets by tags if not explicitly provided
  # Public subnets (for manager by default)
}

data "aws_subnets" "public" {
  count = length(var.worker_subnet_ids) == 0 || var.manager_subnet_id == "" ? 1 : 0
  filter { name = "vpc-id" values = [local.vpc_id] }
  filter { name = "tag:${var.public_subnet_tag_key}" values = [var.public_subnet_tag_value] }
}

data "aws_subnets" "private" {
  count = length(var.worker_subnet_ids) == 0 ? 1 : 0
  filter { name = "vpc-id" values = [local.vpc_id] }
  filter { name = "tag:${var.private_subnet_tag_key}" values = [var.private_subnet_tag_value] }
}

locals {
  manager_subnet_id   = var.manager_subnet_id != "" ? var.manager_subnet_id : try(data.aws_subnets.public[0].ids[0], null)
  worker_subnet_ids   = length(var.worker_subnet_ids) > 0 ? var.worker_subnet_ids : try(data.aws_subnets.private[0].ids, [])
  common_tags = merge({
    Project     = "gitlab-runner-fleet",
    Environment = var.environment,
  }, var.tags)
}

# --- IAM for the manager EC2 (allows it to create/terminate worker instances and read the secret) ---
resource "aws_iam_role" "manager_role" {
  name               = "${var.name}-manager-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service" identifiers = ["ec2.amazonaws.com"] }
  }
}

resource "aws_iam_policy" "manager_policy" {
  name   = "${var.name}-manager-policy"
  policy = data.aws_iam_policy_document.manager_permissions.json
}

data "aws_iam_policy_document" "manager_permissions" {
  statement {
    sid     = "EC2Crud"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:Describe*",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:CreateSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress"
    ]
    resources = ["*"]
  }
  statement {
    sid = "PassRole"
    actions = ["iam:PassRole"]
    resources = ["*"]
  }
  statement {
    sid = "ReadRunnerToken"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [var.runner_secret_arn]
  }
}

resource "aws_iam_role_policy_attachment" "attach_manager" {
  role       = aws_iam_role.manager_role.name
  policy_arn = aws_iam_policy.manager_policy.arn
}

resource "aws_iam_instance_profile" "manager_profile" {
  name = "${var.name}-manager-instance-profile"
  role = aws_iam_role.manager_role.name
}

# --- Security Group for manager ---
resource "aws_security_group" "manager_sg" {
  name        = "${var.name}-manager-sg"
  description = "Security group for GitLab runner manager"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.allow_ssh_cidrs
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  tags = local.common_tags
}

# --- Key pair (optional) ---
resource "aws_key_pair" "manager_key" {
  count      = var.ssh_public_key == null ? 0 : 1
  key_name   = "${var.name}-manager-key"
  public_key = var.ssh_public_key
}

# --- Manager EC2 instance ---
resource "aws_instance" "manager" {
  ami                         = var.manager_ami_id
  instance_type               = var.manager_instance_type
  subnet_id                   = local.manager_subnet_id
  vpc_security_group_ids      = [aws_security_group.manager_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.manager_profile.name
  key_name                    = length(aws_key_pair.manager_key) > 0 ? aws_key_pair.manager_key[0].key_name : null
  associate_public_ip_address = var.associate_public_ip

  user_data = templatefile("${path.module}/templates/user_data.sh.tmpl", {
    gitlab_url        = var.gitlab_url
    runner_secret_arn = var.runner_secret_arn
    runner_secret_json_key = var.runner_secret_json_key
    runner_tags       = join(",", var.runner_tags)
    region            = var.region
    worker_ami_id     = var.worker_ami_id
    worker_type       = var.worker_instance_type
    subnet_ids        = join(",", local.worker_subnet_ids)
    sg_ids            = join(",", var.worker_security_group_ids)
    key_name          = var.worker_key_name
    idle_time         = var.autoscaler_idle_time
    max_use_count     = var.autoscaler_max_use_count
    capacity_per_inst = var.autoscaler_capacity_per_instance
  })

  tags = merge(local.common_tags, { Name = "${var.name}-manager" })
}

# Helpful outputs
output "manager_public_ip" { value = aws_instance.manager.public_ip }
output "manager_instance_id" { value = aws_instance.manager.id }
```


---

### variables.tf
```hcl
# You can either provide vpc_id directly OR a vpc_name to discover by tag:Name.
variable "vpc_id"    { type = string default = "" }
variable "vpc_name"  { type = string default = "" }

# Discover subnets by tags (recommended). If left empty, you can still override
# with explicit subnet IDs below.
variable "private_subnet_tag_key"   { type = string default = "Tier" }
variable "private_subnet_tag_value" { type = string default = "private" }
variable "public_subnet_tag_key"    { type = string default = "Tier" }
variable "public_subnet_tag_value"  { type = string default = "public" }

# Optional explicit overrides (leave empty to use discovery above)
variable "manager_subnet_id"   { type = string default = "" }
variable "worker_subnet_ids"   { type = list(string) default = [] }

variable "name" { type = string default = "gitlab-fleet" }
variable "environment" { type = string default = "dev" }
variable "region" { type = string default = "ap-south-1" }

# Manager EC2 settings
variable "manager_ami_id"         { type = string description = "AMI for manager (Ubuntu 22.04 recommended)" }
variable "manager_instance_type"  { type = string default = "t3.micro" }
variable "associate_public_ip"    { type = bool   default = true }

variable "allow_ssh_cidrs" { type = list(string) default = ["0.0.0.0/0"] }
variable "ssh_public_key"  { type = string default = null }

# GitLab
variable "gitlab_url"  { type = string }
# We will NOT pass the token via Terraform (keeps it out of tfstate). Instead, the
# manager will read it from AWS Secrets Manager at boot with IAM permissions.
variable "runner_secret_arn"      { type = string description = "ARN of Secrets Manager secret that stores the runner token (string or JSON)" }
variable "runner_secret_json_key" { type = string default = "" description = "If the secret is JSON, set the key name that contains the token" }
variable "runner_tags"            { type = list(string) default = ["aws-fleet"] }

# Worker settings consumed by Fleeting plugin
variable "worker_ami_id"            { type = string }
variable "worker_instance_type"     { type = string default = "t3.medium" }
variable "worker_security_group_ids" { type = list(string) }
variable "worker_key_name"          { type = string default = null }

# Autoscaler knobs
variable "autoscaler_idle_time"              { type = string default = "5m" }
variable "autoscaler_max_use_count"         { type = number default = 1 }
variable "autoscaler_capacity_per_instance" { type = number default = 1 }

variable "tags" {
  type    = map(string)
  default = {}
}
```

---

### outputs.tf
```hcl
output "manager_public_dns" {
  value = aws_instance.manager.public_dns
}
```

---

### templates/config.toml.tmpl
```toml
# (Deprecated in favor of inline render from user_data that injects the token at boot.)
# Keeping this header for reference; not used now.
```

---

### templates/user_data.sh.tmpl
```bash
#!/bin/bash
set -eux

# Vars from Terraform templatefile
GITLAB_URL="${gitlab_url}"
RUNNER_SECRET_ARN="${runner_secret_arn}"
RUNNER_SECRET_JSON_KEY="${runner_secret_json_key}"
REGION="${region}"
RUNNER_TAGS="${runner_tags}"
WORKER_AMI_ID="${worker_ami_id}"
WORKER_TYPE="${worker_type}"
SUBNET_IDS="${subnet_ids}"
SG_IDS="${sg_ids}"
KEY_NAME="${key_name}"
IDLE_TIME="${idle_time}"
MAX_USE_COUNT="${max_use_count}"
CAPACITY_PER_INST="${capacity_per_inst}"

# Basic deps
apt-get update
apt-get install -y curl apt-transport-https ca-certificates gnupg lsb-release docker.io awscli jq
usermod -aG docker ubuntu || true

# GitLab Runner
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash
apt-get install -y gitlab-runner

# Fleeting + AWS plugin
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-fleeting/script.deb.sh | bash
apt-get install -y gitlab-fleeting gitlab-fleeting-plugin-aws

# Fetch runner token from Secrets Manager
SECRET_STR=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$RUNNER_SECRET_ARN" --query SecretString --output text)
if [ -n "$RUNNER_SECRET_JSON_KEY" ] && [ "$RUNNER_SECRET_JSON_KEY" != "" ]; then
  RUNNER_TOKEN=$(echo "$SECRET_STR" | jq -r ".[$RUNNER_SECRET_JSON_KEY]")
else
  RUNNER_TOKEN="$SECRET_STR"
fi

# Render /etc/gitlab-runner/config.toml with injected token
install -d -m 0755 /etc/gitlab-runner
cat > /etc/gitlab-runner/config.toml <<EOF
concurrent = 100
check_interval = 3

[[runners]]
  name = "aws-fleet"
  url = "$GITLAB_URL"
  token = "$RUNNER_TOKEN"
  executor = "docker"

  [runners.docker]
    image = "ubuntu:22.04"
    privileged = true
    disable_cache = false

  [runners.autoscaler]
    plugin = "fleeting"
    max_use_count = $MAX_USE_COUNT
    capacity_per_instance = $CAPACITY_PER_INST
    idle_time = "$IDLE_TIME"

    [runners.autoscaler.plugin_config]
      provider = "aws"
      region = "$REGION"
      machine_image = "$WORKER_AMI_ID"
      instance_type = "$WORKER_TYPE"
      subnet_ids = [${SUBNET_IDS}]
      security_group_ids = [${SG_IDS}]
      key_name = "$KEY_NAME"

  [runners.cache]
    Type = "s3"
    Shared = true
EOF

# Start runner
systemctl enable --now gitlab-runner

# Tag the manager instance for clarity
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" --tags Key=Role,Value=gitlab-runner-manager || true
```



---

### terraform.tfvars (example)
```hcl
name         = "gitlab-fleet"
environment  = "dev"
region       = "ap-south-1"

vpc_id            = "vpc-0123456789abcdef0"
manager_subnet_id = "subnet-aaaabbbb"
manager_ami_id    = "ami-0abcdef1234567890"   # Ubuntu 22.04 in ap-south-1

allow_ssh_cidrs = ["203.0.113.0/24"]
ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... chris@laptop"

# GitLab
gitlab_url   = "https://gitlab.com/"
runner_token = "GR1345..."    # group/project or instance token
runner_tags  = ["aws-fleet", "docker"]

# Worker fleet
worker_ami_id               = "ami-0abcdef1234567890"  # your build AMI
worker_instance_type        = "t3.medium"
worker_subnet_ids           = ["subnet-aaaabbbb", "subnet-ccccdddd"]
worker_security_group_ids   = ["sg-0123abcd"]
worker_key_name             = null

# Autoscaler tuning
autoscaler_idle_time              = "5m"
autoscaler_max_use_count         = 1
autoscaler_capacity_per_instance = 1

# Extra tags
tags = { Owner = "Chris" }
```

---

## Apply
```bash
terraform init
terraform apply
```

---

## .gitlab-ci.yml (Terraform with GitLab HTTP backend)
```yaml
stages: [validate, plan, apply]

variables:
  TF_ROOT: "./"                   # path where your Terraform lives
  TF_STATE_NAME: "aws-runners"    # logical state name within the project
  TF_IN_AUTOMATION: "true"

  # GitLab HTTP backend auth (do NOT hardcode in files)
  TF_HTTP_USERNAME: "gitlab-ci-token"
  TF_HTTP_PASSWORD: "$CI_JOB_TOKEN"

  # Backend addresses (GitLab.com example). For self-managed, change the domain.
  TF_ADDRESS: "https://gitlab.com/api/v4/projects/$CI_PROJECT_ID/terraform/state/$TF_STATE_NAME"
  TF_LOCK_ADDRESS: "$TF_ADDRESS/lock"
  TF_UNLOCK_ADDRESS: "$TF_ADDRESS/lock"
  TF_LOCK_METHOD: "POST"
  TF_UNLOCK_METHOD: "DELETE"
  TF_RETRY_WAIT_MIN: "5"

image: registry.gitlab.com/gitlab-org/terraform-images/stable:latest

before_script:
  - cd "$TF_ROOT"
  - terraform --version

validate:
  stage: validate
  script:
    - terraform init -backend-config="address=$TF_ADDRESS" \
                     -backend-config="lock_address=$TF_LOCK_ADDRESS" \
                     -backend-config="unlock_address=$TF_UNLOCK_ADDRESS" \
                     -backend-config="lock_method=$TF_LOCK_METHOD" \
                     -backend-config="unlock_method=$TF_UNLOCK_METHOD" \
                     -backend-config="retry_wait_min=$TF_RETRY_WAIT_MIN"
    - terraform validate

plan:
  stage: plan
  script:
    - terraform init -backend-config="address=$TF_ADDRESS" \
                     -backend-config="lock_address=$TF_LOCK_ADDRESS" \
                     -backend-config="unlock_address=$TF_UNLOCK_ADDRESS" \
                     -backend-config="lock_method=$TF_LOCK_METHOD" \
                     -backend-config="unlock_method=$TF_UNLOCK_METHOD" \
                     -backend-config="retry_wait_min=$TF_RETRY_WAIT_MIN"
    - terraform plan -out tfplan
  artifacts:
    paths: ["$TF_ROOT/tfplan"]
    when: always

apply:
  stage: apply
  # Optional: require manual approval
  when: manual
  script:
    - terraform init -backend-config="address=$TF_ADDRESS" \
                     -backend-config="lock_address=$TF_LOCK_ADDRESS" \
                     -backend-config="unlock_address=$TF_UNLOCK_ADDRESS" \
                     -backend-config="lock_method=$TF_LOCK_METHOD" \
                     -backend-config="unlock_method=$TF_UNLOCK_METHOD" \
                     -backend-config="retry_wait_min=$TF_RETRY_WAIT_MIN"
    - terraform apply -auto-approve tfplan
```

### Notes for HTTP backend
- Do **not** put credentials in `backend.tf`; we pass them via env vars (`TF_HTTP_USERNAME`/`TF_HTTP_PASSWORD`).
- The address uses `$CI_PROJECT_ID` and your chosen `$TF_STATE_NAME` to keep states separated.
- For **self-managed GitLab**, replace `gitlab.com` with your domain.


When the manager comes up, it will register the runner and autoscale EC2 workers as jobs queue up.

### Notes
- Ensure the **manager AMI** has Docker and can reach the internet (for packages and Docker pulls).
- Tighten IAM by scoping resources (specific AMIs, subnets, and using condition keys like `ec2:ResourceTag/Project`).
- Add S3 cache credentials under `[runners.cache]` for faster CI.
- If you prefer instance **Auto Scaling Groups** for workers, swap the plugin config to use an ASG (and grant `autoscaling:*` describe/update permissions) and reference the group name instead of raw subnet/AMI.
