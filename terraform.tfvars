gitlab_token        = "glpat-XXXXXXXX"
gitlab_base_url     = "https://gitlab.com/api/v4" # or your self-managed URL

parent_group_id     = 12345678

# Case A: create subgroup
subgroup_full_path  = null
subgroup_name       = "team-a"
subgroup_path       = "team-a"

# Case B: use existing subgroup
# subgroup_full_path  = "myco/platform/team-a"

project_name        = "payments-api"
project_path        = "payments-api"
create_project      = true
