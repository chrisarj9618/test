#!/bin/bash
set -e

GITLAB_TOKEN="${gitlab_token:?Missing GITLAB_TOKEN}"
PARENT_GROUP_PATH="${1:?Pass parent group path as first arg}"
SUBGROUP_NAME="${2:?Pass subgroup name as second arg}"
GITLAB_API="https://gitlab.com/api/v4"

# URL encode utility
urlencode() {
  local LANG=C
  for ((i=0; i<${#1}; i++)); do
    local c=${1:$i:1}
    case $c in
      [a-zA-Z0-9.~_-]) printf "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# Fetch parent group ID
parent_group=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_API/groups/$(urlencode "$PARENT_GROUP_PATH")")

parent_group_id=$(echo "$parent_group" | jq -r '.id')
if [[ "$parent_group_id" == "null" || -z "$parent_group_id" ]]; then
  echo "❌ ERROR: Parent group not found"
  exit 1
fi

# Check if subgroup exists
subgroup_full_path="${PARENT_GROUP_PATH}/${SUBGROUP_NAME}"
subgroup=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API/groups/$(urlencode "$subgroup_full_path")")
echo $subgroup
subgroup_id=$(echo "$subgroup" | jq -r '.id')

if [[ "$subgroup_id" == "null" || -z "$subgroup_id" ]]; then
  echo "ℹ️ Subgroup '${subgroup_full_path}' does not exist."
  echo "create_subgroup=false" > subgroup_status.env
else
  echo "✅ Subgroup exists with ID $subgroup_id"
  echo "create_subgroup=false" > subgroup_status.env
fi

# Save outputs
echo $subgroup >> subsgroup_status.env
echo "existing_subgroup_id=${subgroup_id:-}" >> subgroup_status.env
echo "parent_group_id=$parent_group_id" >> subgroup_status.env
echo "SUBGROUP_NAME=$SUBGROUP_NAME" >> subgroup_status.env
echo "PARENT_GROUP_PATH=$PARENT_GROUP_PATH" >> subgroup_status.env
