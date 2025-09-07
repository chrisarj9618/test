#!/usr/bin/env bash
set -euo pipefail

# Inputs
GITLAB_API_URL="${GITLAB_API_URL:-https://gitlab.com/api/v4}"
GITLAB_TOKEN="${GITLAB_TOKEN:?GitLab token not set}"
FULL_PATH="${1:?Usage: $0 <group_path like parent/child/subgroup>}"

# Function to check if a group exists
group_exists() {
  local path="$1"
  local resp
  resp=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_API_URL}/groups/${path}")
  [[ "$resp" != *"404 Group Not Found"* && "$resp" != *"error"* ]]
}

# Function to create subgroup
create_group() {
  local name="$1"
  local path="$2"
  local parent_id="$3"
  curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
       --header "Content-Type: application/json" \
       -X POST "${GITLAB_API_URL}/groups" \
       -d "{\"name\":\"${name}\",\"path\":\"${path}\",\"parent_id\":${parent_id}}" >/dev/null
}

# Walk through subgroups
IFS='/' read -ra parts <<< "$FULL_PATH"
current_path=""
parent_id="null"

for part in "${parts[@]}"; do
  current_path="${current_path:+$current_path/}$part"

  if group_exists "$current_path"; then
    echo "✅ Group $current_path exists"
    parent_id=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "${GITLAB_API_URL}/groups/${current_path}" | jq '.id')
  else
    echo "➕ Creating group $current_path"
    create_group "$part" "$part" "$parent_id"
    parent_id=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "${GITLAB_API_URL}/groups/${current_path}" | jq '.id')
  fi
done
