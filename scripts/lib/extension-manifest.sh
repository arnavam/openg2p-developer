#!/usr/bin/env bash
# Load custom Registry Gen2 extension manifests (.openg2p-extension.yaml).

extension_manifest_root() {
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
}

extension_manifest_load_env() {
  local root
  root="$(extension_manifest_root)"
  if [[ -f "${root}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${root}/.env"
  fi
}

extension_manifest_resolve_path() {
  local root="$1"
  local path="$2"
  if [[ "$path" != /* ]]; then
    path="${root}/${path}"
  fi
  local dir part
  dir="$(dirname "$path")"
  part="$(basename "$path")"
  echo "$(cd "$dir" && pwd)/${part}"
}

extension_manifest_workspace() {
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/workspace-path.sh"
  workspace_open
}

extension_manifest_file_for_variant() {
  local variant="$1"
  local workspace
  workspace="$(extension_manifest_workspace)"
  echo "${workspace}/${variant}/.openg2p-extension.yaml"
}

extension_manifest_get() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -1 | sed -E 's/^["'\''"]|["'\''"]$//g'
}

extension_manifest_is_builtin_variant() {
  local variant="$1"
  [[ "$variant" == "farmer-registry" || "$variant" == "national-social-registry" ]]
}

extension_manifest_exists() {
  local variant="$1"
  [[ -f "$(extension_manifest_file_for_variant "$variant")" ]]
}

extension_manifest_list_variants() {
  local workspace manifest variant
  workspace="$(extension_manifest_workspace)"
  shopt -s nullglob
  for manifest in "${workspace}"/*/.openg2p-extension.yaml; do
    variant="$(extension_manifest_get "$manifest" "variant")"
    [[ -n "$variant" ]] || variant="$(basename "$(dirname "$manifest")")"
    printf '%s\n' "$variant"
  done
}

extension_manifest_load() {
  local variant="$1"
  local file
  file="$(extension_manifest_file_for_variant "$variant")"
  if [[ ! -f "$file" ]]; then
    echo "Extension manifest not found: ${file}" >&2
    echo "Run: make extension-package NAME=${variant}" >&2
    return 1
  fi

  EXTENSION_MANIFEST_FILE="$file"
  EXTENSION_VARIANT="$(extension_manifest_get "$file" "variant")"
  EXTENSION_LABEL="$(extension_manifest_get "$file" "label")"
  EXTENSION_PRODUCT_REPO="$(extension_manifest_get "$file" "product_repo")"
  EXTENSION_DIR_NAME="$(extension_manifest_get "$file" "extension_dir")"
  EXTENSION_PYTHON_MODULE="$(extension_manifest_get "$file" "python_module")"
  EXTENSION_PIP_NAME="$(extension_manifest_get "$file" "pip_name")"
  EXTENSION_VARIANT_TOKEN="$(extension_manifest_get "$file" "variant_token")"
  EXTENSION_REGISTRY_DB="$(extension_manifest_get "$file" "registry_db")"
  EXTENSION_MASTER_DATA_DB="$(extension_manifest_get "$file" "master_data_db")"
  EXTENSION_STAFF_API_PORT="$(extension_manifest_get "$file" "staff_api_port")"
  EXTENSION_UI_PORT="$(extension_manifest_get "$file" "ui_port")"
  EXTENSION_MASTER_DATA_API_PORT="$(extension_manifest_get "$file" "master_data_api_port")"
  EXTENSION_WORKER_QUEUE="$(extension_manifest_get "$file" "worker_queue")"
  EXTENSION_KEYCLOAK_CLIENT_ID="$(extension_manifest_get "$file" "keycloak_client_id")"
  EXTENSION_UI_APP_MNEMONIC="$(extension_manifest_get "$file" "ui_app_mnemonic")"

  [[ -n "$EXTENSION_VARIANT" ]] || EXTENSION_VARIANT="$variant"
  [[ -n "$EXTENSION_PRODUCT_REPO" ]] || EXTENSION_PRODUCT_REPO="$variant"
  [[ -n "$EXTENSION_LABEL" ]] || EXTENSION_LABEL="$EXTENSION_VARIANT"

  local workspace
  workspace="$(extension_manifest_workspace)"
  EXTENSION_PRODUCT_REPO_PATH="${workspace}/${EXTENSION_PRODUCT_REPO}"
  EXTENSION_DIR="${EXTENSION_PRODUCT_REPO_PATH}/${EXTENSION_DIR_NAME}"
}

extension_manifest_slug_validate() {
  local slug="$1"
  if [[ ! "$slug" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "NAME must be lowercase kebab-case (e.g. disability-registry)" >&2
    return 1
  fi
}

extension_manifest_derive_names() {
  local slug="$1"
  local short="${slug%-registry}"
  [[ "$short" == "$slug" ]] && short="$slug"
  short="${short//-/_}"

  DERIVED_VARIANT="$slug"
  DERIVED_LABEL="$(extension_manifest_title_case "$slug")"
  DERIVED_PRODUCT_REPO="$slug"
  if [[ "$slug" == *-registry ]]; then
    DERIVED_EXTENSION_DIR="${slug/-registry/-extension}"
  else
    DERIVED_EXTENSION_DIR="${slug}-extension"
  fi
  DERIVED_PYTHON_MODULE="openg2p_registry_${short}_extension"
  DERIVED_PIP_NAME="openg2p-registry-${short//_/-}-extension"
  DERIVED_VARIANT_TOKEN="${short//_/-}"
  DERIVED_VARIANT_TOKEN="${DERIVED_VARIANT_TOKEN%%-*}"
  [[ -z "$DERIVED_VARIANT_TOKEN" ]] && DERIVED_VARIANT_TOKEN="${short//_/-}"
  DERIVED_REGISTRY_DB="${short}_registry_db"
  DERIVED_MASTER_DATA_DB="${short}_master_data_db"
  DERIVED_KEYCLOAK_CLIENT_ID="${slug}-staff-portal"
  DERIVED_UI_APP_MNEMONIC="${slug}-staff-portal"
  DERIVED_WORKER_QUEUE="${short}_registry_worker_queue"
  DERIVED_HELM_CHART_NAME="openg2p-${slug}"
}

extension_manifest_title_case() {
  local slug="$1" out="" part first rest base
  if [[ "$slug" == *-registry ]]; then
    base="${slug%-registry}"
  else
    base="$slug"
  fi
  base="${base//-/_}"
  IFS=_ read -r -a parts <<< "$base"
  for part in "${parts[@]}"; do
    first="$(printf '%s' "$part" | cut -c1 | tr '[:lower:]' '[:upper:]')"
    rest="$(printf '%s' "$part" | cut -c2-)"
    out+="${out:+ }${first}${rest}"
  done
  echo "${out} Registry"
}

extension_manifest_next_ports() {
  local workspace="$1"
  local api_port=8041
  local ui_port=3020
  local manifest api ui

  for api in \
    "${FARMER_REGISTRY_STAFF_API_PORT:-8001}" \
    "${NSR_REGISTRY_STAFF_API_PORT:-8011}" \
    "${IAM_STAFF_PORT:-8020}" \
    "${AWE_API_PORT:-8030}"; do
    if [[ -n "$api" && "$api" =~ ^[0-9]+$ ]] && (( api_port <= api )); then
      api_port=$((api + 10))
    fi
  done

  for ui in \
    "${FARMER_REGISTRY_UI_PORT:-3000}" \
    "${NSR_REGISTRY_UI_PORT:-3010}"; do
    if [[ -n "$ui" && "$ui" =~ ^[0-9]+$ ]] && (( ui_port <= ui )); then
      ui_port=$((ui + 10))
    fi
  done

  shopt -s nullglob
  for manifest in "${workspace}"/*/.openg2p-extension.yaml; do
    api="$(extension_manifest_get "$manifest" "staff_api_port")"
    ui="$(extension_manifest_get "$manifest" "ui_port")"
    if [[ -n "$api" && "$api" =~ ^[0-9]+$ ]] && (( api_port <= api )); then
      api_port=$((api + 10))
    fi
    if [[ -n "$ui" && "$ui" =~ ^[0-9]+$ ]] && (( ui_port <= ui )); then
      ui_port=$((ui + 10))
    fi
  done

  DERIVED_STAFF_API_PORT="$api_port"
  DERIVED_UI_PORT="$ui_port"
}

extension_manifest_render_template() {
  local template="$1"
  local output="$2"
  shift 2
  local content dir
  content="$(cat "$template")"
  while [[ $# -gt 0 ]]; do
    content="${content//${1}/${2}}"
    shift 2
  done
  dir="$(dirname "$output")"
  mkdir -p "$dir"
  printf '%s\n' "$content" > "$output"
}

extension_manifest_build_oidc_audiences_json() {
  # Allowed JWT `aud` values for IAM token validation (LoginProvider.audiences).
  # Must include clients used by the hub Staff Portal (iam-staff-portal) and
  # Keycloak's default access-token audience (`account`), plus registry UIs.
  # Keep this list short: when Keycloak returns `aud` as an array, IAM requires
  # every listed audience to appear in the token (subset check).
  local -a items=("iam-staff-portal" "account" "nsr-registry-staff-portal" "farmer-registry-staff-portal")
  local variant manifest client_id
  while IFS= read -r variant; do
    [[ -n "$variant" ]] || continue
    manifest="$(extension_manifest_file_for_variant "$variant")"
    client_id="$(extension_manifest_get "$manifest" "keycloak_client_id")"
    [[ -n "$client_id" ]] || continue
    items+=("$client_id")
  done < <(extension_manifest_list_variants)
  # LoginProvider.audiences is a VARCHAR of JSON-encoded list, not a JSON array column.
  python3 -c 'import json, sys; print(json.dumps(json.dumps(sys.argv[1:])))' "${items[@]}"
}

# Local Docker/Keycloak often has no audience mappers, so tokens only carry
# `aud: "account"` (string) or a short list — the multi-client allow-list above
# then fails IAM's subset check. Empty list disables the audience gate locally.
extension_manifest_build_oidc_audiences_json_local() {
  python3 -c 'import json; print(json.dumps(json.dumps([])))'
}
