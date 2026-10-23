#!/usr/bin/env bash

# teardown-infra.sh — Delete the kind cluster created by deploy-infra.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-kcp}"
export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
KUBE_DIR="${REPO_ROOT}/.kube"
KIND_CONFIG="${KUBE_DIR}/${KIND_CONFIG:-kind.kubeconfig}"
ADMIN_KUBECONFIG="${KUBE_DIR}/${ADMIN_KUBECONFIG:-admin.kubeconfig}"

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
  log "Delete kubeconfigs ${KUBE_DIR}..."
  rm -rf ${KUBE_DIR}
  log "Kubeconfigs ${KUBE_DIR} deleted."

  log "=== Done ==="
}

# Run main only when executed directly so unit tests (tests/unit/hack/) can
# source this script and exercise purge_registry_cache in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
