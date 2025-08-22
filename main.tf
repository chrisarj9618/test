terraform {
  required_version = ">= 1.3.0"
  required_providers {
    gitlab = {
      source  = "gitlabhq/gitlab"
      version = "~> 16.9" # or newer
    }
  }
}

############################################
# Provider config
############################################
variable "gitlab_token" {
  description = "GitLab personal access token with api scope"
  type        = string
  sensitive   = true
}

variable "gitlab_base_url" {
  description = "GitLab API base URL (use SaaS default or your self-managed URL)"
  type        = string
  default     = "https://gitlab.com/api/v4"
}

provider "gitlab" {
  token    = var.gitlab_token
  base_url = var.gitlab_base_url
}

############################################
# Inputs
############################################
# Parent group ID under which the subgroup should live
variable "parent_group_id" {
  type        = number
  description = "Numeric ID of the parent group (namespace)"
}

# If you ALREADY have the subgroup, set its full path here (e.g. myco/platform/team-a).
# If null, Terraform will create the subgroup using the name/path/parent below.
variable "subgroup_full_path" {
  type        = string
  default     = null
  description = "Existing subgroup full path. If set, creation is skipped."
}

# Used only when creating a new subgroup
variable "subgroup_name" {
  type        = string
  default     = "team-a"
}
variable "subgroup_path" {
  type        = string
  default     = "team-a"
}

# Project settings
variable "project_name" {
  type        = string
  default     = "example-service"
}
variable "project_path" {
  type        = string
  default     = "example-service"
}

# Global on/off switch for creating the project
variable "create_project" {
  type        = bool
  default     = true
  description = "Set false to skip creating the project"
}

############################################
# Subgroup: use existing OR create new
############################################
# If subgroup_full_path is provided, look it up.
data "gitlab_group" "existing_subgroup" {
  count     = var.subgroup_full_path != null ? 1 : 0
  full_path = var.subgroup_full_path
}

# If subgroup_full_path is NOT provided, create the subgroup.
resource "gitlab_group" "subgroup" {
  count     = var.subgroup_full_path == null ? 1 : 0
  name      = var.subgroup_name
  path      = var.subgroup_path
  parent_id = var.parent_group_id

  # Optional extras:
  visibility_level = "private"
  description      = "Managed by Terraform"
}

# Compute the target namespace ID for the project, regardless of path chosen above.
locals {
  subgroup_id = var.subgroup_full_path != null
    ? data.gitlab_group.existing_subgroup[0].id
    : gitlab_group.subgroup[0].id
}

############################################
# Project (conditional)
############################################
resource "gitlab_project" "project" {
  count        = var.create_project ? 1 : 0
  name         = var.project_name
  path         = var.project_path
  namespace_id = local.subgroup_id

  visibility_level = "private"
  initialize_with_readme = true

  # Optional goodies
  default_branch = "main"

  # Example: protect main
  push_rules {
    deny_delete_tag = true
  }
}
