terraform {
  required_version = ">= 1.5.0"
  required_providers {
    gitlab = {
      source  = "gitlabhq/gitlab"
      version = "~> 17.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "gitlab" {
  token   = var.gitlab_token
  base_url = var.gitlab_base_url
}

# Ask the script if the subgroup exists; no files are written in this mode.
data "external" "subgroup_lookup" {
  program = [
    "bash",
    "${path.module}/check-group.sh",
    var.parent_full_path,
    var.subgroup_path
  ]

  env = {
    GITLAB_TOKEN        = var.gitlab_token
    GITLAB_API_BASE_URL = coalesce(var.gitlab_api_base_url, "")
  }

  query = {}
}

locals {
  exists       = try(tobool(data.external.subgroup_lookup.result.exists), false)
  existing_id  = try(tonumber(data.external.subgroup_lookup.result.id), null)
  parent_id    = tonumber(data.external.subgroup_lookup.result.parent_id)
  subgroup_name = coalesce(var.subgroup_name, var.subgroup_path)
}

resource "gitlab_group" "subgroup" {
  count     = local.exists ? 0 : 1
  name      = local.subgroup_name
  path      = var.subgroup_path
  parent_id = local.parent_id
}

output "subgroup_id" {
  value = local.exists ? local.existing_id : gitlab_group.subgroup[0].id
}

output "subgroup_exists_already" {
  value = local.exists
}
