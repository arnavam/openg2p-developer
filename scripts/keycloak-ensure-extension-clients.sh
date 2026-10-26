#!/usr/bin/env bash
# Ensure Keycloak OIDC clients for custom extension manifests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
if [[ ! -f "${LIB_DIR}/extension-manifest.sh" && -f /scripts/lib/extension-manifest.sh ]]; then
  LIB_DIR=/scripts/lib
fi
# shellcheck disable=SC1091
source "${LIB_DIR}/extension-manifest.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/keycloak-registry-roles.sh"

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-staff}"
KCADM="${KCADM:-/opt/keycloak/bin/kcadm.sh}"

if [[ ! -x "$KCADM" ]]; then
  echo "[keycloak] kcadm not available; skip custom extension clients." >&2
  exit 0
fi

kc_login() {
  "${KCADM}" config credentials \
    --server "${KEYCLOAK_URL}" \
    --realm master \
    --user "${KEYCLOAK_ADMIN:-admin}" \
    --password "${KEYCLOAK_ADMIN_PASSWORD:-admin}" >/dev/null
}

client_internal_id() {
  local client_id="$1"
  "${KCADM}" get clients -r "${KEYCLOAK_REALM}" -q "clientId=${client_id}" --fields id 2>/dev/null \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

ensure_client() {
  local client_id="$1"
  shift
  local internal_id
  internal_id="$(client_internal_id "${client_id}" || true)"
  if [[ -z "${internal_id}" ]]; then
    echo "[keycloak]   + client ${client_id}"
    "${KCADM}" create clients -r "${KEYCLOAK_REALM}" -s "clientId=${client_id}" "$@"
  else
    echo "[keycloak]   ~ client ${client_id}"
    "${KCADM}" update "clients/${internal_id}" -r "${KEYCLOAK_REALM}" "$@"
  fi
}

ensure_client_role() {
  local client_id="$1"
  local role_name="$2"
  local client_uuid role_name_enc
  client_uuid="$(client_internal_id "${client_id}")"
  [[ -n "${client_uuid}" ]] || return 0
  role_name_enc="${role_name// /%20}"
  if "${KCADM}" get "clients/${client_uuid}/roles/${role_name_enc}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1; then
    return 0
  fi
  "${KCADM}" create "clients/${client_uuid}/roles" -r "${KEYCLOAK_REALM}" -s "name=${role_name}"
}

assign_client_role() {
  local username="$1"
  local client_id="$2"
  local role_name="$3"
  local client_uuid role_id role_name_enc
  client_uuid="$(client_internal_id "${client_id}")"
  [[ -n "${client_uuid}" ]] || return 0
  role_name_enc="${role_name// /%20}"
  role_id="$("${KCADM}" get "clients/${client_uuid}/roles/${role_name_enc}" -r "${KEYCLOAK_REALM}" --fields id | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "${role_id}" ]] || return 0
  "${KCADM}" add-roles \
    -r "${KEYCLOAK_REALM}" \
    --uusername "${username}" \
    --cid "${client_uuid}" \
    --rolename "${role_name}" >/dev/null 2>&1 || true
}

ensure_iam_staff_portal_redirect() {
  local ui_port="$1"
  local iam_client_uuid
  iam_client_uuid="$(client_internal_id "iam-staff-portal" || true)"
  [[ -n "${iam_client_uuid}" ]] || return 0
  local target_uri="http://localhost:${ui_port}/*"
  local client_json
  client_json="$("${KCADM}" get "clients/${iam_client_uuid}" -r "${KEYCLOAK_REALM}" 2>/dev/null || true)"
  [[ -n "${client_json}" ]] || return 0
  if ! echo "${client_json}" | grep -Fq "\"${target_uri}\""; then
    echo "[keycloak]   + adding ${target_uri} to iam-staff-portal redirectUris"
    local updated_json
    updated_json="$(echo "${client_json}" | sed "s|\"redirectUris\" : \[|\"redirectUris\" : \[ \"${target_uri}\",|")"
    echo "${updated_json}" | "${KCADM}" update "clients/${iam_client_uuid}" -r "${KEYCLOAK_REALM}" -f - >/dev/null 2>&1 || true
  fi
}

manifests=()
if [[ -n "${1:-}" ]]; then
  manifests=("$(extension_manifest_file_for_variant "$1")")
else
  while IFS= read -r manifest; do
    [[ -n "$manifest" ]] && manifests+=("$manifest")
  done < <(find "$(extension_manifest_workspace)" -maxdepth 2 -name '.openg2p-extension.yaml' 2>/dev/null | sort)
fi

[[ ${#manifests[@]} -gt 0 ]] || exit 0

kc_login

for manifest in "${manifests[@]}"; do
  [[ -f "$manifest" ]] || continue
  client_id="$(extension_manifest_get "$manifest" "keycloak_client_id")"
  ui_port="$(extension_manifest_get "$manifest" "ui_port")"
  [[ -n "$client_id" && -n "$ui_port" ]] || continue

  ensure_client "${client_id}" \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s 'redirectUris=["http://localhost:'"${ui_port}"'/*"]' \
    -s 'webOrigins=["http://localhost:'"${ui_port}"'"]'

  ensure_iam_staff_portal_redirect "${ui_port}"

  for role in "${REGISTRY_STAFF_CLIENT_ROLES[@]}"; do
    ensure_client_role "${client_id}" "${role}"
    for u in "${KEYCLOAK_DEV_USER:-staff}" alex.carter nina.patel; do
      assign_client_role "$u" "${client_id}" "${role}"
    done
  done
done

echo "[keycloak] Custom extension clients provisioned."
