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
KIND_CONFIG="${KIND_CONFIG:-kind-config.yaml}"
ROOT_SHARD="${ROOT_SHARD:-root-shard.yaml}"
FRONT_PROXY="${FRONT_PROXY:-front-proxy.yaml}"
ADMIN_KUBECONFIG="${ADMIN_KUBECONFIG:-admin-kubeconfig.yaml}"
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
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
  else
    log "Generating kind cluster config..."

    cat >"${REPO_ROOT}/${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30443
    hostPort: 8443
    protocol: TCP
EOF

    kind create cluster --name "${CLUSTER_NAME}" --config="${REPO_ROOT}/${KIND_CONFIG}"
    log "Kind cluster '${CLUSTER_NAME}' created."
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}"
}

# ---------------------------------------------------------------------------
# install_cert_manager — Apply cert-manager and wait for it to roll out.
# ---------------------------------------------------------------------------
install_cert_manager() {
  kubectl apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" --wait=true
  log "cert-manager is Available."
}

# ---------------------------------------------------------------------------
# deploy_kcp — Install kcp via helm
# ---------------------------------------------------------------------------
deploy_kcp() {
  log "Add kcp repo to helm"
  helm repo add kcp https://kcp-dev.github.io/helm-charts >/dev/null
  helm repo update >/dev/null

  log "Check if kcp-operator is already installed"
  if helm status kcp-operator --namespace kcp-operator >/dev/null 2>&1; then
    log "kcp-operator is already installed"
  else
    log "kcp-operator is not installed"
    log "Install kcp-operator using helm"
    helm install --create-namespace --namespace kcp-operator kcp-operator kcp/kcp-operator
  fi

  if ls kcp-operator >/dev/null 2>&1; then
    log "https://github.com/kcp-dev/kcp-operator already cloned"
  else
    git clone https://github.com/kcp-dev/kcp-operator
  fi

  if helm status etcd >/dev/null 2>&1; then
    log "etcd is already installed"
  else
    log "etcd is not installed"
    log "Install etcd from kcp-operator using helm"
    helm install etcd "${REPO_ROOT}/kcp-operator/hack/ci/testdata/etcd"
  fi

  log "Create Root Shard"
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF
  kubectl wait --for=condition=Ready issuer/selfsigned \
  --timeout="${DEPLOYMENT_TIMEOUT}"
  
  cat <<EOF | kubectl apply -f -
apiVersion: operator.kcp.io/v1alpha1
kind: RootShard
metadata:
  name: root
spec:
  external:
    # replace the hostname with the external DNS name for your kcp instance
    hostname: localhost
    port: 6443
  certificates:
    # this references the issuer created above
    issuerRef:
      group: cert-manager.io
      kind: Issuer
      name: selfsigned
  cache:
    embedded:
      # kcp comes with a cache server accessible to all shards,
      # in this case it is fine to enable the embedded instance
      enabled: true
  etcd:
    endpoints:
      # this is the service URL to etcd. Replace if Helm chart was
      # installed under a different name or the namespace is not "default"
      - http://etcd.default.svc.cluster.local:2379
EOF
  kubectl wait --for=condition=Available rootshard/root \
  --timeout="${DEPLOYMENT_TIMEOUT}"

  log "Set up Front Proxy"
  cat <<EOF | kubectl apply -f -
apiVersion: operator.kcp.io/v1alpha1
kind: FrontProxy
metadata:
  name: frontproxy
spec:
  rootShard:
    ref:
      # the name of the RootShard object created before
      name: root
  serviceTemplate:
    spec:
      # expose this front-proxy via a load balancer
      type: LoadBalancer
EOF
  kubectl wait --for=condition=Available frontproxy/frontproxy \
  --timeout="${DEPLOYMENT_TIMEOUT}"

  log "Create admin-kubeconfig"
  cat <<EOF | kubectl apply -f -
apiVersion: operator.kcp.io/v1alpha1
kind: Kubeconfig
metadata:
  name: kubeconfig-kcp-admin
spec:
  # the user name embedded in the kubeconfig
  username: kcp-admin
  groups:
    # system:kcp:admin is a special privileged group in kcp.
    # the kubeconfig generated from this should be kept secure at all times
    - system:kcp:admin
  # the kubeconfig will be valid for 365d but will be automatically refreshed
  validity: 8766h
  secretRef:
    # the name of the secret that the assembled kubeconfig should be written to
    name: admin-kubeconfig
  target:
    # a reference to the frontproxy deployed previously so the kubeconfig is accepted by it
    frontProxyRef:
      name: frontproxy
EOF
  kubectl wait --for=condition=Available kubeconfig/kubeconfig-kcp-admin \
  --timeout="${DEPLOYMENT_TIMEOUT}"

  kubectl get secret admin-kubeconfig -o jsonpath="{.data.kubeconfig}" | base64 -d > "${REPO_ROOT}/admin.kubeconfig"

  KUBECONFIG="${REPO_ROOT}/admin.kubeconfig" kubectl get pods
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
  log "Cluster config: ${REPO_ROOT}/${KIND_CONFIG}"
  log "Deployment Timeout: ${DEPLOYMENT_TIMEOUT}"
  log ""

  preflight_checks
  create_kind_cluster
  install_cert_manager
  deploy_kcp

  log ""
  log "=========================================="
  log "  Infrastructure deployment complete!"
  log "=========================================="
  log "Cluster: ${CLUSTER_NAME}"
  # log "flux-operator version: ${FLUX_OPERATOR_VERSION}"
  log "cert-manager version: ${CERT_MANAGER_VERSION}"
  log "To tear down: make teardown-infra"
}

# Run main only when executed directly so the functions above can be sourced
# and exercised individually (e.g. from a test harness).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi