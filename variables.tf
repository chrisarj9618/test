variable "gitlab_token" {
  description = "GitLab token with API scope"
  type        = string
  sensitive   = true
}

variable "gitlab_base_url" {
  description = "Provider base URL (https://gitlab.com for SaaS)"
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_api_base_url" {
  description = "API base for the shell script (e.g., https://gitlab.com/api/v4). Leave null for default."
  type        = string
  default     = null
}

variable "parent_full_path" {
  description = "Full path of the parent group (e.g., chris/devops/automation/terraform)"
  type        = string
}

variable "subgroup_path" {
  description = "Slug/path of the subgroup to ensure (e.g., frontoend-moduels)"
  type        = string
}

variable "subgroup_name" {
  description = "Display name of the subgroup (defaults to subgroup_path when null)"
  type        = string
  default     = null
}
