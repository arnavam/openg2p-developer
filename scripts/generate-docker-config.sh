#!/usr/bin/env bash
# Generate Docker-network env files under generated/**/docker/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Ensure native IAM data (login_providers.json) exists for mounting into IAM.
bash "${ROOT_DIR}/scripts/generate-config.sh" >/dev/null

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

GENERATED_DIR="${ROOT_DIR}/generated"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-adminsecret}"
MINIO_API_PORT="${MINIO_API_PORT:-9000}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:${MINIO_API_PORT}}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8080}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:${KEYCLOAK_PORT}}"
KEYCLOAK_IAM_CLIENT_SECRET="${KEYCLOAK_IAM_CLIENT_SECRET:-dev-iam-staff-secret}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-staff}"
KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET="${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET:-dev-awe-resolver-secret}"
AWE_REGISTRY_CALLBACK_SECRET_ID="${AWE_REGISTRY_CALLBACK_SECRET_ID:-00000000-0000-4000-8000-000000000001}"
AWE_REGISTRY_CALLBACK_HMAC_SECRET="${AWE_REGISTRY_CALLBACK_HMAC_SECRET:-dev-registry-awe-callback-secret}"
IAM_STAFF_PORT="${IAM_STAFF_PORT:-8020}"
FARMER_REGISTRY_STAFF_API_PORT="${FARMER_REGISTRY_STAFF_API_PORT:-8001}"
FARMER_REGISTRY_UI_PORT="${FARMER_REGISTRY_UI_PORT:-3001}"
NSR_REGISTRY_STAFF_API_PORT="${NSR_REGISTRY_STAFF_API_PORT:-8011}"
NSR_REGISTRY_UI_PORT="${NSR_REGISTRY_UI_PORT:-3002}"
STAFF_PORTAL_UI_PORT="${STAFF_PORTAL_UI_PORT:-3000}"
REGISTRY_AUTH_ENABLED="${REGISTRY_AUTH_ENABLED:-false}"

mkdir -p \
  "${GENERATED_DIR}/farmer-registry/docker" \
  "${GENERATED_DIR}/national-social-registry/docker" \
  "${GENERATED_DIR}/iam/docker" \
  "${GENERATED_DIR}/awe/docker/config" \
  "${GENERATED_DIR}/staff-portal/docker"

render() {
  local template="$1"
  local output="$2"
  shift 2
  local content
  content="$(cat "$template")"
  while [[ $# -gt 0 ]]; do
    local key="$1"
    local value="$2"
    content="${content//${key}/${value}}"
    shift 2
  done
  printf '%s\n' "$content" > "$output"
  echo "Generated ${output}"
}

render_registry_variant() {
  local variant_dir="$1"
  local db_name="$2"
  local master_db_name="$3"
  local staff_api_port="$4"
  local ui_port="$5"
  local worker_queue="$6"
  local keycloak_client_id="$7"
  local ui_app_mnemonic="$8"
  local staff_api_service="$9"
  local master_data_api_service="${10}"
  local auth_enabled="${11:-false}"

  local out="${GENERATED_DIR}/${variant_dir}/docker"
  mkdir -p "$out"

  local common=(
    "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}"
    "{{MINIO_ROOT_USER}}" "${MINIO_ROOT_USER}"
    "{{MINIO_ROOT_PASSWORD}}" "${MINIO_ROOT_PASSWORD}"
    "{{MINIO_ENDPOINT}}" "${MINIO_ENDPOINT}"
    "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}"
    "{{REGISTRY_DB_NAME}}" "${db_name}"
    "{{REGISTRY_MASTER_DATA_DB_NAME}}" "${master_db_name}"
    "{{REGISTRY_STAFF_API_PORT}}" "${staff_api_port}"
    "{{REGISTRY_UI_PORT}}" "${ui_port}"
    "{{REGISTRY_WORKER_QUEUE}}" "${worker_queue}"
    "{{REGISTRY_KEYCLOAK_CLIENT_ID}}" "${keycloak_client_id}"
    "{{REGISTRY_UI_APP_MNEMONIC}}" "${ui_app_mnemonic}"
    "{{REGISTRY_AUTH_ENABLED}}" "${auth_enabled}"
    "{{REGISTRY_STAFF_API_SERVICE}}" "${staff_api_service}"
    "{{REGISTRY_MASTER_DATA_API_SERVICE}}" "${master_data_api_service}"
    "{{IAM_STAFF_PORT}}" "${IAM_STAFF_PORT}"
    "{{AWE_REGISTRY_CALLBACK_SECRET_ID}}" "${AWE_REGISTRY_CALLBACK_SECRET_ID}"
    "{{AWE_REGISTRY_CALLBACK_HMAC_SECRET}}" "${AWE_REGISTRY_CALLBACK_HMAC_SECRET}"
  )

  render "${ROOT_DIR}/templates/docker/registry-staff-portal-api.env.tpl" \
    "${out}/staff-portal-api.env" "${common[@]}"
  render "${ROOT_DIR}/templates/docker/registry-celery-workers.env.tpl" \
    "${out}/celery-workers.env" "${common[@]}"
  render "${ROOT_DIR}/templates/docker/registry-celery-beat.env.tpl" \
    "${out}/celery-beat.env" "${common[@]}"
  render "${ROOT_DIR}/templates/docker/registry-partner-api.env.tpl" \
    "${out}/partner-api.env" "${common[@]}"
  render "${ROOT_DIR}/templates/docker/registry-staff-portal-ui.env.tpl" \
    "${out}/staff-portal-ui.env" "${common[@]}"
  render "${ROOT_DIR}/templates/docker/master-data-api.env.tpl" \
    "${out}/master-data-api.env" "${common[@]}"
}

render_registry_variant \
  "farmer-registry" \
  "farmer_registry_db" \
  "farmer_master_data_db" \
  "${FARMER_REGISTRY_STAFF_API_PORT}" \
  "${FARMER_REGISTRY_UI_PORT}" \
  "farmer_registry_worker_queue" \
  "farmer-registry-staff-portal" \
  "farmer-registry-staff-portal" \
  "farmer-registry-staff-api" \
  "farmer-master-data-api" \
  "${REGISTRY_AUTH_ENABLED}"

render_registry_variant \
  "national-social-registry" \
  "nsr_registry_db" \
  "nsr_master_data_db" \
  "${NSR_REGISTRY_STAFF_API_PORT}" \
  "${NSR_REGISTRY_UI_PORT}" \
  "nsr_registry_worker_queue" \
  "nsr-registry-staff-portal" \
  "nsr-registry-staff-portal" \
  "nsr-registry-staff-api" \
  "nsr-master-data-api" \
  "${REGISTRY_AUTH_ENABLED}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"

while IFS= read -r custom_variant; do
  [[ -n "$custom_variant" ]] || continue
  extension_manifest_load "$custom_variant"
  render_registry_variant \
    "${custom_variant}" \
    "${EXTENSION_REGISTRY_DB}" \
    "${EXTENSION_MASTER_DATA_DB}" \
    "${EXTENSION_STAFF_API_PORT}" \
    "${EXTENSION_UI_PORT}" \
    "${EXTENSION_WORKER_QUEUE}" \
    "${EXTENSION_KEYCLOAK_CLIENT_ID}" \
    "${EXTENSION_UI_APP_MNEMONIC}" \
    "${custom_variant}-staff-api" \
    "${custom_variant}-master-data-api" \
    "${REGISTRY_AUTH_ENABLED}"
done < <(extension_manifest_list_variants)

render "${ROOT_DIR}/templates/docker/iam-staff-portal-api.env.tpl" \
  "${GENERATED_DIR}/iam/docker/staff-portal-api.env" \
  "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}" \
  "{{KEYCLOAK_IAM_CLIENT_SECRET}}" "${KEYCLOAK_IAM_CLIENT_SECRET}" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{MINIO_ENDPOINT}}" "${MINIO_ENDPOINT}" \
  "{{NSR_REGISTRY_STAFF_API_PORT}}" "${NSR_REGISTRY_STAFF_API_PORT}"

render "${ROOT_DIR}/templates/awe-config.yaml.tpl" \
  "${GENERATED_DIR}/awe/docker/config/default.yaml" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{KEYCLOAK_REALM}}" "${KEYCLOAK_REALM}" \
  "{{KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}}" "${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}"

render "${ROOT_DIR}/templates/docker/awe-api.env.tpl" \
  "${GENERATED_DIR}/awe/docker/awe-api.env" \
  "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{KEYCLOAK_REALM}}" "${KEYCLOAK_REALM}" \
  "{{KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}}" "${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}"

render "${ROOT_DIR}/templates/awe-admin-ui.config.json.tpl" \
  "${GENERATED_DIR}/awe/docker/admin-ui.config.json" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{KEYCLOAK_REALM}}" "${KEYCLOAK_REALM}"

render "${ROOT_DIR}/templates/docker/staff-portal-ui.env.tpl" \
  "${GENERATED_DIR}/staff-portal/docker/staff-portal-ui.env" \
  "{{IAM_STAFF_PORT}}" "${IAM_STAFF_PORT}"

echo
echo "Docker configs are in ${GENERATED_DIR}/**/docker/"
