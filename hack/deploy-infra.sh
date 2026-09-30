#!/usr/bin/env bash

# deploy-infra.sh — Deploy a kind cluster running kcp with two isolated team
# workspaces (team-alpha, team-beta), each with its own client certificate and
# scoped kubeconfig.
#
# Steps:
#   1. Create kind cluster
#   2. Install cert-manager
#   3. Deploy kcp (two-pass helm upgrade so kcp and kcp-front-proxy can
#      resolve each other via hostAliases)


set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-kcp}"
KIND_CONFIG="${KIND_CONFIG:-kind-config.yaml}"
KCP_NAMESPACE="${KCP_NAMESPACE:-kcp}"
KCP_EXTERNAL_HOSTNAME="${KCP_EXTERNAL_HOSTNAME:-localhost}"
KCP_PORT="${KCP_PORT:-8443}"
KCP_NODE_PORT="${KCP_NODE_PORT:-30443}"
DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-600s}"

FLUX_OPERATOR_VERSION="${FLUX_OPERATOR_VERSION:-v0.60.0}"
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
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
  else
    kind create cluster --name "${CLUSTER_NAME}" --config="${SCRIPT_DIR}/${KIND_CONFIG}"
    log "Kind cluster '${CLUSTER_NAME}' created."
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}"
}

wait_for_fluxinstance() {
  local timeout="${1:-${DEPLOYMENT_TIMEOUT}}"
  timeout="${timeout%s}"
  local deadline=$(( $(date +%s) + timeout ))

  log "Waiting up to ${timeout}s for FluxInstance/flux to become Ready..."

  while true; do
    local ready_status
    ready_status=$(kubectl get fluxinstance/flux -n flux-system -o json 2>/dev/null \
      | jq -r '.status.conditions[]? | select(.type == "Ready") | .status' 2>/dev/null) || true

    if [[ "${ready_status}" == "True" ]]; then
      log "FluxInstance/flux is Ready."
      return 0
    fi

    local reason message
    reason=$(kubectl get fluxinstance/flux -n flux-system -o json 2>/dev/null \
      | jq -r '.status.conditions[]? | select(.type == "Ready") | .reason // "Pending"' 2>/dev/null) || true
    message=$(kubectl get fluxinstance/flux -n flux-system -o json 2>/dev/null \
      | jq -r '.status.conditions[]? | select(.type == "Ready") | .message // ""' 2>/dev/null) || true
    log "  FluxInstance/flux is not Ready yet (reason: ${reason:-Pending})."
    if [[ -n "${message}" ]]; then
      log "    ${message}"
    fi

    if [[ $(date +%s) -ge ${deadline} ]]; then
      log "ERROR: Timed out waiting for FluxInstance/flux after ${timeout}s."
      log "FluxInstance description:"
      kubectl describe fluxinstance/flux -n flux-system 2>/dev/null || true
      log "FluxReport:"
      kubectl get fluxreport/flux -n flux-system -o yaml 2>/dev/null || true
      exit 1
    fi

    sleep 10
  done
}

wait_for_cert_manager() {
  local timeout="${1:-${DEPLOYMENT_TIMEOUT}}"
  timeout="${timeout%s}"
  local deadline=$(( $(date +%s) + timeout ))
  local deployments=(cert-manager cert-manager-cainjector cert-manager-webhook)

  log "Waiting up to ${timeout}s for Deployment/{${deployments[*]}} to become Available..."

  while true; do
    local all_available=true dep status reason message
    for dep in "${deployments[@]}"; do
      status=$(kubectl get -n cert-manager "deployment/${dep}" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || true

      if [[ "${status}" != "True" ]]; then
        all_available=false
        reason=$(kubectl get -n cert-manager "deployment/${dep}" \
          -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null) || true
        message=$(kubectl get -n cert-manager "deployment/${dep}" \
          -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null) || true
        log "  Deployment/${dep} is not Available yet (reason: ${reason:-Pending})."
        if [[ -n "${message}" ]]; then
          log "    ${message}"
        fi
      fi
    done

    if [[ "${all_available}" == "true" ]]; then
      return 0
    fi

    if [[ $(date +%s) -ge ${deadline} ]]; then
      log "ERROR: Timed out waiting for cert-manager deployments after ${timeout}s."
      kubectl get deployment -n cert-manager
      exit 1
    fi

    sleep 5
  done
}

wait_for_kcp() {
  local timeout="${1:-${DEPLOYMENT_TIMEOUT}}"
  timeout="${timeout%s}"
  local deadline=$(( $(date +%s) + timeout ))
  local deployments=(kcp kcp-front-proxy)

  log "Waiting up to ${timeout}s for Deployment/{${deployments[*]}} to become Available..."

  while true; do
    local all_available=true dep status reason message
    for dep in "${deployments[@]}"; do
      status=$(kubectl get -n "${KCP_NAMESPACE}" "deployment/${dep}" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || true

      if [[ "${status}" != "True" ]]; then
        all_available=false
        reason=$(kubectl get -n "${KCP_NAMESPACE}" "deployment/${dep}" \
          -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null) || true
        message=$(kubectl get -n "${KCP_NAMESPACE}" "deployment/${dep}" \
          -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null) || true
        log "  Deployment/${dep} is not Available yet (reason: ${reason:-Pending})."
        if [[ -n "${message}" ]]; then
          log "    ${message}"
        fi
      fi
    done

    if [[ "${all_available}" == "true" ]]; then
      return 0
    fi

    if [[ $(date +%s) -ge ${deadline} ]]; then
      log "ERROR: Timed out waiting for kcp deployments after ${timeout}s."
      kubectl get deployment -n "${KCP_NAMESPACE}"
      exit 1
    fi

    sleep 5
  done
}

# ---------------------------------------------------------------------------
# install_flux_operator — Apply flux-operator and wait for it to roll out.
# ---------------------------------------------------------------------------
install_flux_operator() {
  kubectl apply -f \
    "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/${FLUX_OPERATOR_VERSION}/install.yaml"
  kubectl apply -f "${REPO_ROOT}/deploy/flux-system/fluxinstance.yaml"
  wait_for_fluxinstance "${DEPLOYMENT_TIMEOUT}"
  log "flux-operator installed and FluxInstance/flux is Ready."
}

# ---------------------------------------------------------------------------
# install_cert_manager — Apply cert-manager and wait for it to roll out.
# ---------------------------------------------------------------------------
install_cert_manager() {
  kubectl apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  wait_for_cert_manager "${DEPLOYMENT_TIMEOUT}"
  log "cert-manager is Available."
}

# ---------------------------------------------------------------------------
# deploy_kcp — Install kcp via helm, then re-run with hostAliases so
# kcp-front-proxy and kcp can resolve KCP_EXTERNAL_HOSTNAME back to each other.
# ---------------------------------------------------------------------------
deploy_kcp() {
  helm repo add kcp https://kcp-dev.github.io/helm-charts >/dev/null
  helm repo update >/dev/null

  helm upgrade --install kcp kcp/kcp \
    --namespace "${KCP_NAMESPACE}" \
    --create-namespace \
    --set externalHostname="${KCP_EXTERNAL_HOSTNAME}" \
    --set-string externalPort="${KCP_PORT}" \
    --set kcpFrontProxy.service.type=NodePort \
    --set kcpFrontProxy.service.nodePort="${KCP_NODE_PORT}" \
    --set audit.enabled=false

  wait_for_kcp "${DEPLOYMENT_TIMEOUT}"

  local front_proxy_ip
  front_proxy_ip="$(kubectl get svc kcp-front-proxy -n "${KCP_NAMESPACE}" \
    -o jsonpath='{.spec.clusterIP}')"
  if [[ -z "${front_proxy_ip}" ]]; then
    log "ERROR: could not resolve the kcp-front-proxy ClusterIP."
    exit 1
  fi
  log "kcp-front-proxy ClusterIP: ${front_proxy_ip}"

  helm upgrade kcp kcp/kcp \
    --namespace "${KCP_NAMESPACE}" \
    --reuse-values \
    --set kcp.hostAliases.enabled=true \
    --set "kcp.hostAliases.values[0].ip=${front_proxy_ip}" \
    --set "kcp.hostAliases.values[0].hostnames[0]=${KCP_EXTERNAL_HOSTNAME}" \
    --set kcpFrontProxy.hostAliases.enabled=true \
    --set "kcpFrontProxy.hostAliases.values[0].ip=${front_proxy_ip}" \
    --set "kcpFrontProxy.hostAliases.values[0].hostnames[0]=${KCP_EXTERNAL_HOSTNAME}" \
    --wait

  kubectl get pods -n "${KCP_NAMESPACE}"
  log "kcp deployed."
}

# ---------------------------------------------------------------------------
# main — Orchestrate the n-step deployment sequence.
# ---------------------------------------------------------------------------
main() {
  log "=========================================="
  log "  Deploy Infrastructure to Kind Cluster"
  log "=========================================="
  log "Cluster name: ${CLUSTER_NAME}"
  log "kcp namespace: ${KCP_NAMESPACE}"
  log "External URL: https://${KCP_EXTERNAL_HOSTNAME}:${KCP_PORT}"
  log "KCP Node Port: ${KCP_NODE_PORT}"
  log "Deployment Timeout: ${DEPLOYMENT_TIMEOUT}"
  log ""

  preflight_checks

  # Step 1: Create kind cluster
  log "=== Step 1/n: Create kind cluster ==="
  create_kind_cluster

  log "=== Step 2/n: Install flux-operator ==="
  install_flux_operator

  # Step 2: Install cert-manager
  log "=== Step 3/n: Install cert-manager ==="
  install_cert_manager

  # Step 3: Deploy kcp
  log "=== Step 4/n: Deploy kcp ==="
  deploy_kcp

  log ""
  log "=========================================="
  log "  Infrastructure deployment complete!"
  log "=========================================="
  log "Cluster: ${CLUSTER_NAME}"
  log "flux-operator version: ${FLUX_OPERATOR_VERSION}"
  log "cert-manager version: ${CERT_MANAGER_VERSION}"
  log "To tear down: make teardown-infra"
}

# Run main only when executed directly so the functions above can be sourced
# and exercised individually (e.g. from a test harness).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi