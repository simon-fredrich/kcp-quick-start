#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-kcp}"
KUBE_DIR="${REPO_ROOT}/.kube"
KIND_CONFIG="${KUBE_DIR}/${KIND_CONFIG:-kind.kubeconfig}"
ADMIN_KUBECONFIG="${KUBE_DIR}/${ADMIN_KUBECONFIG:-admin.kubeconfig}"
DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-600s}"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"

# kind defaults to the docker provider; tell it to drive podman instead.
export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

# ---------------------------------------------------------------------------
# log — Print a timestamped log message (ISO 8601 UTC).
# ---------------------------------------------------------------------------
log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

# ---------------------------------------------------------------------------
# preflight_checks — Verify required CLI tools are on PATH.
# ---------------------------------------------------------------------------
preflight_checks() {
  log "Running pre-flight checks..."
  local cmd
  for cmd in podman kind kubectl helm; do
    if ! command -v "${cmd}" &>/dev/null; then
      log "ERROR: required command '${cmd}' not found on PATH."
      exit 1
    fi
  done

  if ! podman info &>/dev/null; then
    log "ERROR: podman is not running. Please start podman and try again."
    exit 1
  fi

  log "Pre-flight checks passed."
}

# ---------------------------------------------------------------------------
# create_kind_cluster — Create the kind cluster (skipped if it already
# exists) and select it as the current kubectl context.
# ---------------------------------------------------------------------------
create_kind_cluster() {
  mkdir -p ${KUBE_DIR}

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
  else
    log "Creating kind cluster..."

    cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30443
    hostPort: 8443
    protocol: TCP
EOF
    log "Kind cluster '${CLUSTER_NAME}' created."
  fi
  kind get kubeconfig --name "${CLUSTER_NAME}" > "${KIND_CONFIG}"
  kubectl --kubeconfig=${KIND_CONFIG} config use-context "kind-${CLUSTER_NAME}"
}

# ---------------------------------------------------------------------------
# install_cert_manager — Apply cert-manager and wait for it to roll out.
# ---------------------------------------------------------------------------
install_cert_manager() {
  kubectl --kubeconfig=${KIND_CONFIG} apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kubectl --kubeconfig=${KIND_CONFIG} -n cert-manager rollout status deployment/cert-manager \
    --timeout="${DEPLOYMENT_TIMEOUT}"
  kubectl --kubeconfig=${KIND_CONFIG} -n cert-manager rollout status deployment/cert-manager-cainjector \
    --timeout="${DEPLOYMENT_TIMEOUT}"
  kubectl --kubeconfig=${KIND_CONFIG} -n cert-manager rollout status deployment/cert-manager-webhook \
    --timeout="${DEPLOYMENT_TIMEOUT}"
  log "cert-manager is Available."
}

main() {
  log "=========================================="
  log "  Deploy Infrastructure to Kind Cluster"
  log "=========================================="
  log "Cluster name: ${CLUSTER_NAME}"
  log "Cluster config: ${REPO_ROOT}/${KIND_CONFIG}"
  log "Deployment Timeout: ${DEPLOYMENT_TIMEOUT}"
  log ""

  preflight_checks
  create_kind_cluster
  install_cert_manager

  log ""
  log "=========================================="
  log "  Infrastructure deployment complete!"
  log "=========================================="
  log "Cluster: ${CLUSTER_NAME}"
  log "cert-manager version: ${CERT_MANAGER_VERSION}"
  log "To expose front-proxy locally: make proxy-up"
  log "To tear down: make teardown-infra"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi