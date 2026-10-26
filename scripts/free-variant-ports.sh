#!/usr/bin/env bash
# Stop native processes on registry variant ports so `make *-registry-run` reloads generated env.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/registry-variant.sh"

VARIANT="${1:-national-social-registry}"
registry_variant_validate "$VARIANT"
registry_variant_paths "$VARIANT"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
fi

IAM_STAFF_PORT="${IAM_STAFF_PORT:-8020}"
AWE_API_PORT="${AWE_API_PORT:-8030}"
AWE_UI_PORT="${AWE_UI_PORT:-8031}"
MASTER_DATA_API_PORT="${MASTER_DATA_API_PORT:-8042}"
NSR_MASTER_DATA_API_PORT="${NSR_MASTER_DATA_API_PORT:-8043}"

free_port() {
  local port="$1"
  local label="$2"
  local pids=""

  # Under OrbStack (and similar), the host-side listener for a Docker
  # published port is a shared forwarder process, not one process per port.
  # Killing it by PID can take down port-forwarding for every container, not
  # just this one. If a running container actually publishes this port,
  # leave it alone — it's infra, not a leftover native process.
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Ports}}' 2>/dev/null \
      | grep -qE "(:|^)${port}->"; then
    echo "Skipping ${label} (port ${port}) — published by a running Docker container."
    return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
  fi
  if [[ -z "$pids" ]] && command -v fuser >/dev/null 2>&1; then
    pids="$(fuser -n tcp "${port}" 2>/dev/null | tr -cs '0-9' '\n' | sed '/^$/d' || true)"
  fi
  if [[ -z "$pids" ]]; then
    return 0
  fi
  echo "Stopping ${label} (port ${port}) ..."
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 1
  pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
  fi
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
}

stop_matching_processes() {
  local label="$1"
  local pattern="$2"
  local pids
  pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    return 0
  fi
  echo "Stopping ${label} ..."
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 1
  # shellcheck disable=SC2086
  kill -9 $pids 2>/dev/null || true
}

# shellcheck disable=SC1090
source "${GENERATED_DIR}/staff-portal-api.env"
# shellcheck disable=SC1090
source "${GENERATED_DIR}/staff-portal-ui.env"

free_port "${REGISTRY_STAFF_PORTAL_API_APP_PORT}" "${VARIANT} staff API"
free_port "${PORT}" "${VARIANT} staff UI"
free_port "${IAM_STAFF_PORT}" "IAM staff API"
free_port "${AWE_API_PORT}" "AWE API"
free_port "${AWE_UI_PORT}" "AWE admin UI"
case "$VARIANT" in
  farmer-registry) free_port "${MASTER_DATA_API_PORT}" "${VARIANT} Master Data API" ;;
  national-social-registry) free_port "${NSR_MASTER_DATA_API_PORT}" "${VARIANT} Master Data API" ;;
  *)
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"
    extension_manifest_load "$VARIANT"
    free_port "${EXTENSION_MASTER_DATA_API_PORT:-${MASTER_DATA_API_PORT}}" "${VARIANT} Master Data API"
    ;;
esac

# Next.js can keep running after the shell job exits; stop by path as well.
stop_matching_processes "${VARIANT} staff UI (next dev)" "${UI_DIR}/node_modules/.bin/next dev"
stop_matching_processes "${VARIANT} staff UI (next dev)" "next dev --webpack"

stop_matching_processes "AWE admin UI (vite)" "${OPENG2P_WORKSPACE}/awe/ui/node_modules/.bin/vite"
stop_matching_processes "AWE admin UI (vite)" ".openg2p-vite.config.mjs"

# Celery workers/beat do not bind HTTP ports; stop them explicitly so DB
# connections from a prior run are released before restart.
case "$VARIANT" in
  farmer-registry) BEAT_DB_NAME="${FARMER_REGISTRY_DB:-farmer_registry_db}" ;;
  national-social-registry) BEAT_DB_NAME="${NSR_REGISTRY_DB:-nsr_registry_db}" ;;
  *)
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"
    extension_manifest_load "$VARIANT"
    BEAT_DB_NAME="${EXTENSION_REGISTRY_DB}"
    ;;
esac

stop_matching_processes "${VARIANT} Celery beat" "openg2p-registry-celery-beat.*celery_app beat"
stop_matching_processes "${VARIANT} Celery beat worker" "openg2p-registry-celery-beat.*worker -Q celery"
stop_matching_processes "${VARIANT} Celery beat" "celery-beat-${BEAT_DB_NAME}.db"
stop_matching_processes "${VARIANT} Celery beat" "${REGISTRY_ROOT}/celery/openg2p-registry-celery-beat"
stop_matching_processes "${VARIANT} Celery worker" "${REGISTRY_ROOT}/celery/openg2p-registry-celery-worker"
stop_matching_processes "${VARIANT} Celery worker" "openg2p-registry-celery-worker.*farmer_registry_worker_queue"
stop_matching_processes "${VARIANT} Celery worker" "openg2p-registry-celery-worker.*nsr_registry_worker_queue"
stop_matching_processes "${VARIANT} Master Data API" "openg2p_gen2_master_data.main"
stop_matching_processes "${VARIANT} staff API" "openg2p_registry_staff_api.main"

# Celery beat persists its schedule under /tmp. A stale file from an older
# registry-platform version can reference removed tasks (e.g.
# intake_form_change_request_beat_producer) and spam errors in a tight loop.
BEAT_SCHEDULE="/tmp/celery-beat-${BEAT_DB_NAME}.db"
if [[ -f "$BEAT_SCHEDULE" ]]; then
  echo "Removing stale Celery beat schedule ${BEAT_SCHEDULE} ..."
  rm -f "$BEAT_SCHEDULE"
fi

echo "Ports cleared for ${LABEL}."
