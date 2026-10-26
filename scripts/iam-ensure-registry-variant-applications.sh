#!/usr/bin/env bash
# Register IAM staff portal applications for registry variant Keycloak clients.
#
# Local dev UI env uses per-variant APPLICATION_MNEMONIC values
# (farmer-registry-staff-portal, nsr-registry-staff-portal, ...). Production
# registries push the catalog at install time; this script mirrors that for
# openg2p-developer using iam-service/samples/registry_registration_payload.json.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"

OPENG2P_WORKSPACE="$(workspace_open)"
IAM_API_DIR="${OPENG2P_WORKSPACE}/iam-service/iam-staff-portal-api"
ENV_FILE="${ROOT_DIR}/generated/iam/staff-portal-api.env"
PAYLOAD_FILE="${IAM_API_DIR}/samples/registry_registration_payload.json"

FARMER_REGISTRY_UI_PORT="${FARMER_REGISTRY_UI_PORT:-3001}"
NSR_REGISTRY_UI_PORT="${NSR_REGISTRY_UI_PORT:-3002}"

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"

export PGPASSWORD="${POSTGRES_PASSWORD}"

if ! psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_SUPERUSER}" -d iam_staff -tc \
  "SELECT 1 FROM information_schema.tables WHERE table_name = 'staff_portal_applications'" | grep -q 1; then
  echo "[iam-variants] iam_staff.staff_portal_applications not found; run make iam-init first" >&2
  exit 1
fi

if [[ ! -d "${IAM_API_DIR}/venv" ]]; then
  echo "[iam-variants] IAM venv missing at ${IAM_API_DIR}. Run: make install-iam" >&2
  exit 1
fi

if [[ ! -f "$PAYLOAD_FILE" ]]; then
  echo "[iam-variants] Missing ${PAYLOAD_FILE}. Run: make clone" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[iam-variants] Missing ${ENV_FILE}. Run: make generate" >&2
  exit 1
fi

variants_json="$(
  NSR_REGISTRY_UI_PORT="$NSR_REGISTRY_UI_PORT" \
  FARMER_REGISTRY_UI_PORT="$FARMER_REGISTRY_UI_PORT" \
  python3 - <<'PY'
import json
import os

variants = [
    {
        "mnemonic": "registry-staff-portal",
        "url": f"http://localhost:{os.environ['NSR_REGISTRY_UI_PORT']}",
    },
    {
        "mnemonic": "farmer-registry-staff-portal",
        "url": f"http://localhost:{os.environ['FARMER_REGISTRY_UI_PORT']}",
    },
    {
        "mnemonic": "nsr-registry-staff-portal",
        "url": f"http://localhost:{os.environ['NSR_REGISTRY_UI_PORT']}",
    },
]

print(json.dumps(variants))
PY
)"

while IFS= read -r custom_variant; do
  [[ -n "$custom_variant" ]] || continue
  extension_manifest_load "$custom_variant"
  variants_json="$(
    python3 - <<PY
import json
variants = json.loads('''${variants_json}''')
variants.append({
    "mnemonic": "${EXTENSION_KEYCLOAK_CLIENT_ID}",
    "url": f"http://localhost:${EXTENSION_UI_PORT}",
})
print(json.dumps(variants))
PY
  )"
done < <(extension_manifest_list_variants)

echo "[iam-variants] Registering IAM registry staff portal applications ..."

(
  cd "$IAM_API_DIR"
  # shellcheck disable=SC1091
  source venv/bin/activate
  export IAM_STAFF_ENV_FILE="$ENV_FILE"
  export REGISTRY_IAM_PAYLOAD="$PAYLOAD_FILE"
  export REGISTRY_IAM_VARIANTS="$variants_json"
  python "${ROOT_DIR}/scripts/lib/iam_register_registry_apps.py"
)

echo "[iam-variants] IAM registry applications ready."
