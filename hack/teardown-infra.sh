#!/usr/bin/env bash

# teardown-infra.sh — Delete the kind cluster created by deploy-infra.sh.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kcp}"
export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

# ---------------------------------------------------------------------------
# log — Print a timestamped log message (ISO 8601 UTC).
# ---------------------------------------------------------------------------
log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

main() {
  log "=== Teardown Infrastructure ==="

  log "Deleting kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
  log "Cluster '${CLUSTER_NAME}' deleted (or did not exist)."

  log "=== Done ==="
}

# Run main only when executed directly so unit tests (tests/unit/hack/) can
# source this script and exercise purge_registry_cache in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
