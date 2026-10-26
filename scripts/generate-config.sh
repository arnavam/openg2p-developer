#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

OPENG2P_WORKSPACE="$(workspace_open)"
ODOO_PATH="${ODOO_PATH:-${OPENG2P_WORKSPACE}/odoo17}"
PBMS_PATH="${PBMS_PATH:-${OPENG2P_WORKSPACE}/pbms}"
GENERATED_DIR="${ROOT_DIR}/generated"

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-adminsecret}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"

PBMS_HTTP_PORT="${PBMS_HTTP_PORT:-8069}"
PBMS_STAFF_API_PORT="${PBMS_STAFF_API_PORT:-8050}"
PBMS_DB_NAME="${PBMS_DB_NAME:-pbmsdb}"
PBMS_DB_USER="${PBMS_DB_USER:-pbmsuser}"
PBMS_DB_PASSWORD="${PBMS_DB_PASSWORD:-pbmspass}"
PBMS_BGTASK_DB_NAME="${PBMS_BGTASK_DB_NAME:-bgtaskdb}"
PBMS_REGISTRY_VARIANT="${PBMS_REGISTRY_VARIANT:-farmer-registry}"
PBMS_REDIS_DB="${PBMS_REDIS_DB:-1}"
FARMER_REGISTRY_STAFF_API_PORT="${FARMER_REGISTRY_STAFF_API_PORT:-8001}"
FARMER_REGISTRY_UI_PORT="${FARMER_REGISTRY_UI_PORT:-3001}"
NSR_REGISTRY_STAFF_API_PORT="${NSR_REGISTRY_STAFF_API_PORT:-8011}"
NSR_REGISTRY_UI_PORT="${NSR_REGISTRY_UI_PORT:-3002}"
MASTER_DATA_API_PORT="${MASTER_DATA_API_PORT:-8042}"
NSR_MASTER_DATA_API_PORT="${NSR_MASTER_DATA_API_PORT:-8043}"
STAFF_PORTAL_UI_PORT="${STAFF_PORTAL_UI_PORT:-3000}"
IAM_STAFF_PORT="${IAM_STAFF_PORT:-8020}"
KEYCLOAK_IAM_CLIENT_SECRET="${KEYCLOAK_IAM_CLIENT_SECRET:-dev-iam-staff-secret}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-staff}"
AWE_API_PORT="${AWE_API_PORT:-8030}"
AWE_UI_PORT="${AWE_UI_PORT:-8031}"
KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET="${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET:-dev-awe-resolver-secret}"
AWE_REGISTRY_CALLBACK_SECRET_ID="${AWE_REGISTRY_CALLBACK_SECRET_ID:-00000000-0000-4000-8000-000000000001}"
AWE_REGISTRY_CALLBACK_HMAC_SECRET="${AWE_REGISTRY_CALLBACK_HMAC_SECRET:-dev-registry-awe-callback-secret}"
ID_GENERATOR_PORT="${ID_GENERATOR_PORT:-8040}"
ID_GENERATOR_URL="http://localhost:${ID_GENERATOR_PORT}/v1"
G2P_BRIDGE_API_PORT="${G2P_BRIDGE_API_PORT:-8002}"
G2P_BRIDGE_EXAMPLE_BANK_PORT="${G2P_BRIDGE_EXAMPLE_BANK_PORT:-8003}"
SPAR_MAPPER_API_PORT="${SPAR_MAPPER_API_PORT:-8004}"
SPAR_BENE_API_PORT="${SPAR_BENE_API_PORT:-8005}"
G2P_BRIDGE_REDIS_DB="${G2P_BRIDGE_REDIS_DB:-2}"
EXAMPLE_BANK_REDIS_DB="${EXAMPLE_BANK_REDIS_DB:-3}"

# Registry staff API JWT middleware (keep false for local dev — true can cause dashboard login loops)
REGISTRY_AUTH_ENABLED="${REGISTRY_AUTH_ENABLED:-false}"

mkdir -p \
  "${GENERATED_DIR}/farmer-registry" \
  "${GENERATED_DIR}/national-social-registry" \
  "${GENERATED_DIR}/pbms" \
  "${GENERATED_DIR}/iam/data" \
  "${GENERATED_DIR}/awe" \
  "${GENERATED_DIR}/bridge" \
  "${GENERATED_DIR}/spar" \
  "${GENERATED_DIR}/odoo"

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
  local auth_enabled="${9:-false}"
  local master_data_api_port="${10:-${MASTER_DATA_API_PORT}}"
  local extension_module="${11:-openg2p_registry_extensions}"

  local common=(
    "{{OPENG2P_WORKSPACE}}" "${OPENG2P_WORKSPACE}"
    "{{ODOO_PATH}}" "${ODOO_PATH}"
    "{{POSTGRES_HOST}}" "${POSTGRES_HOST}"
    "{{POSTGRES_PORT}}" "${POSTGRES_PORT}"
    "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}"
    "{{REDIS_HOST}}" "${REDIS_HOST}"
    "{{REDIS_PORT}}" "${REDIS_PORT}"
    "{{MINIO_ENDPOINT}}" "${MINIO_ENDPOINT}"
    "{{MINIO_ROOT_USER}}" "${MINIO_ROOT_USER}"
    "{{MINIO_ROOT_PASSWORD}}" "${MINIO_ROOT_PASSWORD}"
    "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}"
    "{{IAM_STAFF_PORT}}" "${IAM_STAFF_PORT}"
    "{{REGISTRY_DB_NAME}}" "${db_name}"
    "{{REGISTRY_MASTER_DATA_DB_NAME}}" "${master_db_name}"
    "{{REGISTRY_STAFF_API_PORT}}" "${staff_api_port}"
    "{{REGISTRY_UI_PORT}}" "${ui_port}"
    "{{MASTER_DATA_API_PORT}}" "${master_data_api_port}"
    "{{REGISTRY_WORKER_QUEUE}}" "${worker_queue}"
    "{{REGISTRY_KEYCLOAK_CLIENT_ID}}" "${keycloak_client_id}"
    "{{REGISTRY_UI_APP_MNEMONIC}}" "${ui_app_mnemonic}"
    "{{REGISTRY_AUTH_ENABLED}}" "${auth_enabled}"
    "{{REGISTRY_EXTENSION_MODULE}}" "${extension_module}"
    "{{AWE_API_PORT}}" "${AWE_API_PORT}"
    "{{AWE_REGISTRY_CALLBACK_SECRET_ID}}" "${AWE_REGISTRY_CALLBACK_SECRET_ID}"
    "{{AWE_REGISTRY_CALLBACK_HMAC_SECRET}}" "${AWE_REGISTRY_CALLBACK_HMAC_SECRET}"
    "{{ID_GENERATOR_URL}}" "${ID_GENERATOR_URL}"
  )

  render "${ROOT_DIR}/templates/registry-staff-portal-api.env.tpl" \
    "${GENERATED_DIR}/${variant_dir}/staff-portal-api.env" \
    "${common[@]}"

  render "${ROOT_DIR}/templates/registry-celery-workers.env.tpl" \
    "${GENERATED_DIR}/${variant_dir}/celery-workers.env" \
    "${common[@]}"

  render "${ROOT_DIR}/templates/registry-celery-beat.env.tpl" \
    "${GENERATED_DIR}/${variant_dir}/celery-beat.env" \
    "${common[@]}"

  render "${ROOT_DIR}/templates/registry-staff-portal-ui.env.tpl" \
    "${GENERATED_DIR}/${variant_dir}/staff-portal-ui.env" \
    "${common[@]}"

  render "${ROOT_DIR}/templates/master-data-api.env.tpl" \
    "${GENERATED_DIR}/${variant_dir}/master-data-api.env" \
    "${common[@]}"
}

render "${ROOT_DIR}/templates/pbms-odoo.conf.tpl" "${GENERATED_DIR}/odoo/pbms-odoo.conf" \
  "{{OPENG2P_WORKSPACE}}" "${OPENG2P_WORKSPACE}" \
  "{{ODOO_PATH}}" "${ODOO_PATH}" \
  "{{PBMS_PATH}}" "${PBMS_PATH}" \
  "{{POSTGRES_HOST}}" "${POSTGRES_HOST}" \
  "{{POSTGRES_PORT}}" "${POSTGRES_PORT}" \
  "{{PBMS_HTTP_PORT}}" "${PBMS_HTTP_PORT}"

case "${PBMS_REGISTRY_VARIANT}" in
  farmer-registry) PBMS_REGISTRY_DB_NAME="farmer_registry_db" ;;
  national-social-registry) PBMS_REGISTRY_DB_NAME="nsr_registry_db" ;;
  *)
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"
    if extension_manifest_load "${PBMS_REGISTRY_VARIANT}" 2>/dev/null; then
      PBMS_REGISTRY_DB_NAME="${EXTENSION_REGISTRY_DB}"
    else
      PBMS_REGISTRY_DB_NAME="farmer_registry_db"
    fi
    ;;
esac

PBMS_SIGNING_KEY_PATH="${PBMS_SIGNING_KEY_PATH:-${OPENG2P_WORKSPACE}/g2p-bridge/test/keys/test-partner.p12}"
PBMS_SIGNING_KEY_PASSWORD="${PBMS_SIGNING_KEY_PASSWORD:-testpartner}"

pbms_common=(
  "{{POSTGRES_HOST}}" "${POSTGRES_HOST}"
  "{{POSTGRES_PORT}}" "${POSTGRES_PORT}"
  "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}"
  "{{REDIS_HOST}}" "${REDIS_HOST}"
  "{{REDIS_PORT}}" "${REDIS_PORT}"
  "{{PBMS_DB_NAME}}" "${PBMS_DB_NAME}"
  "{{PBMS_DB_USER}}" "${PBMS_DB_USER}"
  "{{PBMS_DB_PASSWORD}}" "${PBMS_DB_PASSWORD}"
  "{{PBMS_BGTASK_DB_NAME}}" "${PBMS_BGTASK_DB_NAME}"
  "{{PBMS_REGISTRY_DB_NAME}}" "${PBMS_REGISTRY_DB_NAME}"
  "{{PBMS_STAFF_API_PORT}}" "${PBMS_STAFF_API_PORT}"
  "{{PBMS_REDIS_DB}}" "${PBMS_REDIS_DB}"
  "{{G2P_BRIDGE_API_PORT}}" "${G2P_BRIDGE_API_PORT}"
  "{{PBMS_SIGNING_KEY_PATH}}" "${PBMS_SIGNING_KEY_PATH}"
  "{{PBMS_SIGNING_KEY_PASSWORD}}" "${PBMS_SIGNING_KEY_PASSWORD}"
)

render "${ROOT_DIR}/templates/pbms-staff-portal-api.env.tpl" \
  "${GENERATED_DIR}/pbms/staff-portal-api.env" \
  "${pbms_common[@]}"

render "${ROOT_DIR}/templates/pbms-celery-beat.env.tpl" \
  "${GENERATED_DIR}/pbms/celery-beat.env" \
  "${pbms_common[@]}"

render "${ROOT_DIR}/templates/pbms-celery-workers.env.tpl" \
  "${GENERATED_DIR}/pbms/celery-workers.env" \
  "${pbms_common[@]}"

render_registry_variant \
  "farmer-registry" \
  "farmer_registry_db" \
  "farmer_master_data_db" \
  "${FARMER_REGISTRY_STAFF_API_PORT}" \
  "${FARMER_REGISTRY_UI_PORT}" \
  "farmer_registry_worker_queue" \
  "farmer-registry-staff-portal" \
  "farmer-registry-staff-portal" \
  "${REGISTRY_AUTH_ENABLED}" \
  "${MASTER_DATA_API_PORT}" \
  "openg2p_registry_farmer_extension"

render_registry_variant \
  "national-social-registry" \
  "nsr_registry_db" \
  "nsr_master_data_db" \
  "${NSR_REGISTRY_STAFF_API_PORT}" \
  "${NSR_REGISTRY_UI_PORT}" \
  "nsr_registry_worker_queue" \
  "nsr-registry-staff-portal" \
  "nsr-registry-staff-portal" \
  "${REGISTRY_AUTH_ENABLED}" \
  "${NSR_MASTER_DATA_API_PORT}" \
  "openg2p_registry_nsr_extension"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"

while IFS= read -r custom_variant; do
  [[ -n "$custom_variant" ]] || continue
  extension_manifest_load "$custom_variant"
  mkdir -p "${GENERATED_DIR}/${custom_variant}"
  render_registry_variant \
    "${custom_variant}" \
    "${EXTENSION_REGISTRY_DB}" \
    "${EXTENSION_MASTER_DATA_DB}" \
    "${EXTENSION_STAFF_API_PORT}" \
    "${EXTENSION_UI_PORT}" \
    "${EXTENSION_WORKER_QUEUE}" \
    "${EXTENSION_KEYCLOAK_CLIENT_ID}" \
    "${EXTENSION_UI_APP_MNEMONIC}" \
    "${REGISTRY_AUTH_ENABLED}" \
    "${EXTENSION_MASTER_DATA_API_PORT:-${MASTER_DATA_API_PORT}}" \
    "${EXTENSION_PYTHON_MODULE:-openg2p_registry_extensions}"
done < <(extension_manifest_list_variants)

render "${ROOT_DIR}/templates/iam-staff-portal-api.env.tpl" \
  "${GENERATED_DIR}/iam/staff-portal-api.env" \
  "{{POSTGRES_HOST}}" "${POSTGRES_HOST}" \
  "{{POSTGRES_PORT}}" "${POSTGRES_PORT}" \
  "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}" \
  "{{REDIS_HOST}}" "${REDIS_HOST}" \
  "{{REDIS_PORT}}" "${REDIS_PORT}" \
  "{{MINIO_ENDPOINT}}" "${MINIO_ENDPOINT}" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{IAM_STAFF_PORT}}" "${IAM_STAFF_PORT}" \
  "{{NSR_REGISTRY_STAFF_API_PORT}}" "${NSR_REGISTRY_STAFF_API_PORT}" \
  "{{IAM_DATA_DIR}}" "${GENERATED_DIR}/iam/data" \
  "{{KEYCLOAK_IAM_CLIENT_SECRET}}" "${KEYCLOAK_IAM_CLIENT_SECRET}"

# Local Keycloak has no multi-client audience mappers. IAM rejects tokens when
# LoginProvider.audiences is a long allow-list and `aud` is a short array/string.
# Empty list disables the audience gate (same idea as AWE audience: "").
REGISTRY_OIDC_AUDIENCES="$(bash -c 'source "'"${ROOT_DIR}"'/scripts/lib/extension-manifest.sh"; extension_manifest_build_oidc_audiences_json_local')"

render "${ROOT_DIR}/templates/iam-data/login_providers.json.tpl" \
  "${GENERATED_DIR}/iam/data/login_providers.json" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{IAM_STAFF_PORT}}" "${IAM_STAFF_PORT}" \
  "{{STAFF_PORTAL_UI_PORT}}" "${STAFF_PORTAL_UI_PORT}" \
  "{{KEYCLOAK_IAM_CLIENT_SECRET}}" "${KEYCLOAK_IAM_CLIENT_SECRET}" \
  "{{REGISTRY_OIDC_AUDIENCES}}" "${REGISTRY_OIDC_AUDIENCES}"

AWE_CONFIG_PATH="${GENERATED_DIR}/awe/config/default.yaml"
mkdir -p "${GENERATED_DIR}/awe/config"
render "${ROOT_DIR}/templates/awe-config.yaml.tpl" "${AWE_CONFIG_PATH}" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{KEYCLOAK_REALM}}" "${KEYCLOAK_REALM}" \
  "{{KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}}" "${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}"

render "${ROOT_DIR}/templates/awe-api.env.tpl" "${GENERATED_DIR}/awe/awe-api.env" \
  "{{POSTGRES_HOST}}" "${POSTGRES_HOST}" \
  "{{POSTGRES_PORT}}" "${POSTGRES_PORT}" \
  "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{KEYCLOAK_REALM}}" "${KEYCLOAK_REALM}" \
  "{{AWE_API_PORT}}" "${AWE_API_PORT}" \
  "{{AWE_CONFIG_PATH}}" "${AWE_CONFIG_PATH}" \
  "{{KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}}" "${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}"

render "${ROOT_DIR}/templates/awe-admin-ui.config.json.tpl" \
  "${GENERATED_DIR}/awe/admin-ui.config.json" \
  "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
  "{{KEYCLOAK_REALM}}" "${KEYCLOAK_REALM}"

for tpl in "${ROOT_DIR}"/templates/bridge-*.env.tpl "${ROOT_DIR}"/templates/spar-*.env.tpl; do
  [[ -f "$tpl" ]] || continue
  base="$(basename "$tpl" .tpl)"
  case "$base" in
    bridge-partner-api.env)
      out="${GENERATED_DIR}/bridge/partner-api.env"
      ;;
    bridge-celery-worker.env)
      out="${GENERATED_DIR}/bridge/celery-worker.env"
      ;;
    bridge-celery-beat.env)
      out="${GENERATED_DIR}/bridge/celery-beat.env"
      ;;
    bridge-example-bank.env)
      out="${GENERATED_DIR}/bridge/example-bank.env"
      ;;
    spar-mapper-partner-api.env)
      out="${GENERATED_DIR}/spar/mapper-partner-api.env"
      ;;
    spar-bene-portal-api.env)
      out="${GENERATED_DIR}/spar/bene-portal-api.env"
      ;;
    *)
      continue
      ;;
  esac
  render "${tpl}" "$out" \
    "{{POSTGRES_HOST}}" "${POSTGRES_HOST}" \
    "{{POSTGRES_PORT}}" "${POSTGRES_PORT}" \
    "{{POSTGRES_PASSWORD}}" "${POSTGRES_PASSWORD}" \
    "{{REDIS_HOST}}" "${REDIS_HOST}" \
    "{{REDIS_PORT}}" "${REDIS_PORT}" \
    "{{KEYCLOAK_URL}}" "${KEYCLOAK_URL}" \
    "{{G2P_BRIDGE_API_PORT}}" "${G2P_BRIDGE_API_PORT}" \
    "{{G2P_BRIDGE_EXAMPLE_BANK_PORT}}" "${G2P_BRIDGE_EXAMPLE_BANK_PORT}" \
    "{{SPAR_MAPPER_API_PORT}}" "${SPAR_MAPPER_API_PORT}" \
    "{{SPAR_BENE_API_PORT}}" "${SPAR_BENE_API_PORT}" \
    "{{G2P_BRIDGE_REDIS_DB}}" "${G2P_BRIDGE_REDIS_DB}" \
    "{{EXAMPLE_BANK_REDIS_DB}}" "${EXAMPLE_BANK_REDIS_DB}"
done

echo
echo "Generated configs are in ${GENERATED_DIR}"
