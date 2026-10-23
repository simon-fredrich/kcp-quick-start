#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-600s}"
KUBE_DIR="${REPO_ROOT}/.kube"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

preflight_checks() {
  log "Running kcp teardown pre-flight checks..."
  local cmd
  for cmd in helm kubectl; do
    if ! command -v "${cmd}" &>/dev/null; then
      log "ERROR: required command '${cmd}' not found on PATH."
      exit 1
    fi
  done
  log "Pre-flight checks passed."
}

delete_resource() {
  local resource="$1"
  local name="$2"

  log "Deleting ${resource}/${name}..."
  kubectl delete "${resource}/${name}" --ignore-not-found --wait=true \
    --timeout="${DEPLOYMENT_TIMEOUT}"
}

uninstall_release() {
  local release="$1"
  local namespace="${2:-default}"

  log "Uninstalling Helm release '${release}' from namespace '${namespace}'..."
  helm uninstall "${release}" --namespace "${namespace}" --ignore-not-found \
    --wait --timeout "${DEPLOYMENT_TIMEOUT}"
}

main() {
  log "=== Teardown kcp ==="

  preflight_checks
  delete_resource kubeconfig kubeconfig-kcp-admin
  delete_resource frontproxy frontproxy
  delete_resource shard shard-01
  delete_resource shard shard-02
  delete_resource rootshard root
  delete_resource issuer selfsigned
  delete_resource etcd etcd-root
  delete_resource etcd etcd-1
  delete_resource etcd etcd-2

  uninstall_release etcd-druid
  uninstall_release kcp-operator kcp-operator

  log "Removing generated admin kubeconfig..."
  rm -f "${KUBE_DIR}"

  log "=== kcp teardown complete ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
