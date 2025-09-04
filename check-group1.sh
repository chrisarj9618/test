#!/usr/bin/env bash
# bash ./check-group.sh "<parent_full_path>" "<subgroup_path>" [--emit-tfvars]
set -euo pipefail

PARENT_FULL_PATH="${1:-}"
SUBGROUP_PATH="${2:-}"
ACTION="${3:-}"

# write tfvars in the current working dir (where CI cd’s before running TF)
TFVARS_OUT="${TFVARS_OUT:-generated.auto.tfvars}"

# ALWAYS write the tfvars first so TF never prompts
{
  printf 'parent_full_path = "%s"\n' "$PARENT_FULL_PATH"
  printf 'subgroup_path    = "%s"\n' "$SUBGROUP_PATH"
} > "$TFVARS_OUT"

echo "Wrote $TFVARS_OUT in $(pwd)"
[ -s "$TFVARS_OUT" ] || { echo "ERROR: $TFVARS_OUT is empty"; exit 1; }

# If we only needed tfvars, we could early-exit on --emit-tfvars,
# but we also print JSON for Terraform external data source below.

BASE_URL="${GITLAB_API_BASE_URL:-https://gitlab.com/api/v4}"
TOKEN="${GITLAB_TOKEN:-}"
emit_json() { jq -c -n "$1"; }

# If inputs missing, still return safe JSON
if [[ -z "$PARENT_FULL_PATH" || -z "$SUBGROUP_PATH" ]]; then
  emit_json '{exists:false}'
  exit 0
fi

# If token missing, don’t fail—still emit false
if [[ -z "$TOKEN" ]]; then
  emit_json '{exists:false}'
  exit 0
fi

# Query GitLab
parent_json="$(curl -sS -H "PRIVATE-TOKEN: ${TOKEN}" --get \
  --data-urlencode "search=$(basename "$PARENT_FULL_PATH")" \
  "$BASE_URL/groups" || true)"

parent_id="$(jq -r --arg fp "$PARENT_FULL_PATH" \
  '.[]
   | select(.full_path == $fp)
   | .id' <<<"$parent_json" 2>/dev/null || true)"

if [[ -z "$parent_id" || "$parent_id" == "null" ]]; then
  emit_json '{exists:false}'
  exit 0
fi

children_json="$(curl -sS -H "PRIVATE-TOKEN: ${TOKEN}" \
  "$BASE_URL/groups/${parent_id}/subgroups?per_page=100" || true)"

match="$(jq -r --arg p "$SUBGROUP_PATH" \
  '.[] | select(.path == $p) | @json' <<<"$children_json" 2>/dev/null || true)"

if [[ -n "$match" && "$match" != "null" ]]; then
  id="$(jq -r '.id' <<<"$match" 2>/dev/null || true)"
  fp="$(jq -r '.full_path' <<<"$match" 2>/dev/null || true)"
  jq -c -n --argjson id "$id" --arg full_path "$fp" --argjson parent_id "$parent_id" \
    '{exists:true, id:$id, full_path:$full_path, parent_id:$parent_id}'
else
  jq -c -n --argjson parent_id "$parent_id" \
    '{exists:false, parent_id:$parent_id}'
fi
