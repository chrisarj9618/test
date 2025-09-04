#!/usr/bin/env bash
# Modes:
# - Called by Terraform external data source: reads JSON from STDIN (query)
# - Called by CI "precheck" to write generated.auto.tfvars:
#     bash ./check-group.sh --emit-tfvars "parent/full/path" "subgroup-path"

set -euo pipefail

# defaults
BASE_URL_DEFAULT="https://gitlab.com/api/v4"

# Try to read JSON from stdin (external data source mode)
STDIN_PAYLOAD="$(cat | tr -d '\r' || true)"

if jq -e . >/dev/null 2>&1 <<<"$STDIN_PAYLOAD"; then
  # --- External data source mode ---
  PARENT_FULL_PATH="$(jq -r '.parent_full_path' <<<"$STDIN_PAYLOAD")"
  SUBGROUP_PATH="$(jq -r '.subgroup_path' <<<"$STDIN_PAYLOAD")"
  TOKEN="$(jq -r '.gitlab_token' <<<"$STDIN_PAYLOAD")"
  BASE_URL="$(jq -r '.gitlab_api_base_url // empty' <<<"$STDIN_PAYLOAD")"
  [[ -n "${BASE_URL:-}" ]] || BASE_URL="$BASE_URL_DEFAULT"

  # safety: if anything missing, return exists:false
  if [[ -z "${PARENT_FULL_PATH:-}" || -z "${SUBGROUP_PATH:-}" || -z "${TOKEN:-}" ]]; then
    jq -c -n '{exists:false}'
    exit 0
  fi

  # look up parent
  parent_json="$(curl -sS -H "PRIVATE-TOKEN: ${TOKEN}" --get \
    --data-urlencode "search=$(basename "$PARENT_FULL_PATH")" \
    "$BASE_URL/groups" || true)"

  parent_id="$(jq -r --arg fp "$PARENT_FULL_PATH" \
    '.[]
     | select(.full_path == $fp)
     | .id' <<<"$parent_json" 2>/dev/null || true)"

  if [[ -z "$parent_id" || "$parent_id" == "null" ]]; then
    jq -c -n '{exists:false}'
    exit 0
  fi

  # check subgroup under parent
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
  exit 0
fi

# --- Precheck mode (CLI) to generate .auto.tfvars ---
if [[ "${1:-}" == "--emit-tfvars" ]]; then
  PARENT_FULL_PATH="${2:-}"
  SUBGROUP_PATH="${3:-}"
  if [[ -z "$PARENT_FULL_PATH" || -z "$SUBGROUP_PATH" ]]; then
    echo "Usage: $0 --emit-tfvars <parent_full_path> <subgroup_path>" >&2
    exit 2
  fi
  cat > generated.auto.tfvars <<EOF
parent_full_path = "${PARENT_FULL_PATH}"
subgroup_path    = "${SUBGROUP_PATH}"
EOF
  echo "Wrote $(pwd)/generated.auto.tfvars"
  # Optionally also print a benign JSON so you can run it locally the same way
  jq -c -n '{ok:true}'
  exit 0
fi

# If neither mode matched:
echo "Unsupported invocation. Either pipe JSON (Terraform) or use --emit-tfvars <parent> <subgroup> (CI precheck)." >&2
exit 2
