#!/usr/bin/env bash
# Usage:
#   ./check-group.sh "<parent_full_path>" "<subgroup_path>" [--emit-tfvars]
# Examples:
#   ./check-group.sh "chris/devops/automation/terraform" "frontoend-moduels"
#   ./check-group.sh "chris/devops/automation/terraform" "frontoend-moduels" --emit-tfvars
#
# Behavior:
#  - Always prints JSON to STDOUT for Terraform data.external:
#      {"exists":true|false,"id":<num?>,"full_path":"...","parent_id":<num>}
#  - If third arg is --emit-tfvars, also writes generated.auto.tfvars with:
#      parent_full_path = "..."
#      subgroup_path    = "..."

set -euo pipefail

PARENT_FULL_PATH="${1:-}"
SUBGROUP_PATH="${2:-}"
ACTION="${3:-}"

BASE_URL="${GITLAB_API_BASE_URL:-https://gitlab.com/api/v4}"
TOKEN="${GITLAB_TOKEN:-}"

emit_json() { jq -c -n "$1"; }

if [[ -z "$TOKEN" ]]; then
  >&2 echo "GITLAB_TOKEN is required"
  emit_json '{exists:false}'
  exit 0
fi
if [[ -z "$PARENT_FULL_PATH" || -z "$SUBGROUP_PATH" ]]; then
  emit_json '{exists:false}'
  exit 0
fi

HDR=("PRIVATE-TOKEN: ${TOKEN}")

# 1) Resolve exact parent by full_path
parent_json="$(curl -sS -H "${HDR[@]}" --get \
  --data-urlencode "search=$(basename "$PARENT_FULL_PATH")" \
  "$BASE_URL/groups")"

parent_id="$(jq -r --arg fp "$PARENT_FULL_PATH" \
  '.[]
   | select(.full_path == $fp)
   | .id' <<<"$parent_json" || true)"

if [[ -z "$parent_id" || "$parent_id" == "null" ]]; then
  # parent missing -> tell TF the subgroup doesn't exist (no parent id)
  emit_json '{exists:false}'
  exit 0
fi

# 2) Check for subgroup under this parent
children_json="$(curl -sS -H "${HDR[@]}" \
  "$BASE_URL/groups/${parent_id}/subgroups?per_page=100")"

match="$(jq -r --arg p "$SUBGROUP_PATH" \
  '.[] | select(.path == $p) | @json' <<<"$children_json" || true)"

if [[ -n "$match" && "$match" != "null" ]]; then
  id="$(jq -r '.id' <<<"$match")"
  full_path="$(jq -r '.full_path' <<<"$match")"
  jq -c -n --argjson id "$id" --arg full_path "$full_path" --argjson parent_id "$parent_id" \
    '{exists:true, id:$id, full_path:$full_path, parent_id:$parent_id}'
else
  jq -c -n --argjson parent_id "$parent_id" \
    '{exists:false, parent_id:$parent_id}'
fi

# 3) Optionally emit a .auto.tfvars file so Terraform needs no -var flags
if [[ "$ACTION" == "--emit-tfvars" ]]; then
  cat > generated.auto.tfvars <<EOF
parent_full_path = "${PARENT_FULL_PATH}"
subgroup_path    = "${SUBGROUP_PATH}"
EOF
fi
