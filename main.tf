resource "null_resource" "ensure_gitlab_subgroups" {
  provisioner "local-exec" {
    command = "./ensure_subgroups.sh ${var.gitlab_group_path}"
    environment = {
      GITLAB_TOKEN   = var.gitlab_token
      GITLAB_API_URL = "https://gitlab.com/api/v4"
    }
  }
}
