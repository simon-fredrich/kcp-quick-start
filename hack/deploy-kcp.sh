#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-600s}"
KCP_VERSION="${KCP_VERSION:-v0.33.1}"
ETCD_IMAGE="${ETCD_IMAGE:-europe-docker.pkg.dev/gardener-project/public/gardener/etcd-wrapper:v0.6.2}"
ETCD_BACKUP_IMAGE="${ETCD_BACKUP_IMAGE:-europe-docker.pkg.dev/gardener-project/public/gardener/etcdbrctl:v0.41.2}"
KUBE_DIR="${REPO_ROOT}/.kube"
KIND_CONFIG="${KUBE_DIR}/${KIND_CONFIG:-kind.kubeconfig}"
ADMIN_KUBECONFIG="${KUBE_DIR}/${ADMIN_KUBECONFIG:-admin.kubeconfig}"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

preflight_checks() {
  log "Running kcp deployment pre-flight checks..."
  local cmd
  for cmd in git helm kubectl; do
    if ! command -v "${cmd}" &>/dev/null; then
      log "ERROR: required command '${cmd}' not found on PATH."
      exit 1
    fi
  done
  log "Pre-flight checks passed."
}

apply_etcd() {
  local etcd_name="$1"

  kubectl --kubeconfig=${KIND_CONFIG} apply -f - <<EOF
apiVersion: druid.gardener.cloud/v1alpha1
kind: Etcd
metadata:
  name: ${etcd_name}
  labels:
    app: etcd-statefulset
    gardener.cloud/role: controlplane
    role: test
spec:
  annotations:
    app: etcd-statefulset
    gardener.cloud/role: controlplane
    role: test
  labels:
    app: etcd-statefulset
    gardener.cloud/role: controlplane
    role: test
  etcd:
    image: ${ETCD_IMAGE}
    metrics: basic
    defragmentationSchedule: "0 */24 * * *"
    resources:
      limits: { cpu: 500m, memory: 1Gi }
      requests: { cpu: 100m, memory: 200Mi }
    clientPort: 2379
    serverPort: 2380
    quota: 8Gi
  backup:
    image: ${ETCD_BACKUP_IMAGE}
    port: 8080
    fullSnapshotSchedule: "0 */24 * * *"
    resources:
      limits: { cpu: 200m, memory: 1Gi }
      requests: { cpu: 23m, memory: 128Mi }
    garbageCollectionPolicy: Exponential
    garbageCollectionPeriod: 43200s
    deltaSnapshotPeriod: 300s
    deltaSnapshotMemoryLimit: 1Gi
    compression:
      enabled: true
      policy: "gzip"
    leaderElection:
      reelectionPeriod: 5s
      etcdConnectionTimeout: 5s
  sharedConfig:
    autoCompactionMode: periodic
    autoCompactionRetention: "15m"
  replicas: 1
EOF
}

apply_shard() {
  local shard_name="$1"
  local etcd_name="$2"

  kubectl --kubeconfig=${KIND_CONFIG} apply -f - <<EOF
apiVersion: operator.kcp.io/v1alpha1
kind: Shard
metadata:
  labels:
    app.kubernetes.io/name: kcp-operator
    app.kubernetes.io/managed-by: kustomize
  name: ${shard_name}
spec:
  replicas: 1
  etcd:
    endpoints:
      - http://${etcd_name}-client.default.svc.cluster.local:2379
  rootShard:
    ref:
      name: root
  auth:
    serviceAccount:
      enabled: true
  image:
    tag: ${KCP_VERSION}
  deploymentTemplate:
    spec:
      template:
        spec:
          hostAliases:
            - ip: "10.96.100.100"
              hostnames:
                - kcp.quickstart.local
EOF
  kubectl --kubeconfig=${KIND_CONFIG} wait --for=condition=Available "shard/${shard_name}" \
    --timeout="${DEPLOYMENT_TIMEOUT}"
}

deploy_kcp() {
  log "Add kcp repo to helm"
  helm --kubeconfig=${KIND_CONFIG} repo add kcp https://kcp-dev.github.io/helm-charts >/dev/null
  helm --kubeconfig=${KIND_CONFIG} repo update >/dev/null

  log "Check if kcp-operator is already installed"
  if helm --kubeconfig=${KIND_CONFIG} status kcp-operator --namespace kcp-operator >/dev/null 2>&1; then
    log "kcp-operator is already installed"
  else
    log "kcp-operator is not installed"
    log "Install kcp-operator using helm"
    helm --kubeconfig=${KIND_CONFIG} install --create-namespace --namespace kcp-operator kcp-operator kcp/kcp-operator
  fi

  if [[ -d "${REPO_ROOT}/etcd-druid" ]]; then
    log "https://github.com/gardener/etcd-druid.git already cloned"
  else
    git clone https://github.com/gardener/etcd-druid.git "${REPO_ROOT}/etcd-druid"
  fi

  log "Check if etcd-druid is already installed"
  if helm --kubeconfig=${KIND_CONFIG} status etcd-druid >/dev/null 2>&1; then
    log "etcd-druid is already installed"
  else
    log "etcd-druid is not installed"
    log "Install etcd-druid using helm"
    helm --kubeconfig=${KIND_CONFIG} install etcd-druid "${REPO_ROOT}/etcd-druid/charts"
  fi

  for etcd_name in etcd-root etcd-1 etcd-2; do
    apply_etcd "${etcd_name}"
    kubectl --kubeconfig=${KIND_CONFIG} wait --for=condition=Ready "etcd/${etcd_name}" \
      --timeout="${DEPLOYMENT_TIMEOUT}"
  done

  log "Create Root Shard"
  kubectl --kubeconfig=${KIND_CONFIG} apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: operator.kcp.io/v1alpha1
kind: RootShard
metadata:
  name: root
spec:
  external:
    hostname: kcp.quickstart.local
    port: 6443
  certificates:
    issuerRef:
      group: cert-manager.io
      kind: Issuer
      name: selfsigned
  cache:
    embedded:
      enabled: true
  etcd:
    endpoints:
      - http://etcd-root-client.default.svc.cluster.local:2379
  image:
    tag: ${KCP_VERSION}
  replicas: 1
  proxy:
    replicas: 1
    image:
      tag: ${KCP_VERSION}
  deploymentTemplate:
    spec:
      template:
        spec:
          hostAliases:
            - ip: "10.96.100.100"
              hostnames:
                - kcp.quickstart.local
EOF
  kubectl --kubeconfig=${KIND_CONFIG} wait --for=condition=Available rootshard/root \
    --timeout="${DEPLOYMENT_TIMEOUT}"

  log "Create Shards"
  apply_shard shard-01 etcd-1
  apply_shard shard-02 etcd-2

  log "Set up Front Proxy"
  kubectl --kubeconfig=${KIND_CONFIG} apply -f - <<EOF
apiVersion: operator.kcp.io/v1alpha1
kind: FrontProxy
metadata:
  name: frontproxy
spec:
  replicas: 1
  auth:
    serviceAccount:
      enabled: true
  rootShard:
    ref:
      name: root
  serviceTemplate:
    spec:
      type: ClusterIP
      clusterIP: 10.96.100.100
  image:
    tag: ${KCP_VERSION}
  certificateTemplates:
    server:
      spec:
        dnsNames:
          - localhost
        ipAddresses:
          - 127.0.0.1
          - 127.0.0.2
EOF
  kubectl --kubeconfig=${KIND_CONFIG} wait --for=condition=Available frontproxy/frontproxy \
    --timeout="${DEPLOYMENT_TIMEOUT}"

  log "Create admin-kubeconfig"
  kubectl --kubeconfig=${KIND_CONFIG} apply -f - <<EOF
apiVersion: operator.kcp.io/v1alpha1
kind: Kubeconfig
metadata:
  name: kubeconfig-kcp-admin
spec:
  username: kcp-admin
  groups:
    - system:kcp:admin
  validity: 8766h
  secretRef:
    name: admin-kubeconfig
  target:
    frontProxyRef:
      name: frontproxy
EOF
  kubectl --kubeconfig=${KIND_CONFIG} wait --for=condition=Available kubeconfig/kubeconfig-kcp-admin \
    --timeout="${DEPLOYMENT_TIMEOUT}"

  local admin_kubeconfig_tmp
  admin_kubeconfig_tmp="$(mktemp "${REPO_ROOT}/.admin.kubeconfig.XXXXXX")"
  if ! kubectl --kubeconfig=${KIND_CONFIG} -n default get secret admin-kubeconfig -o jsonpath="{.data.kubeconfig}" | base64 -d > "${admin_kubeconfig_tmp}"; then
    rm -f "${admin_kubeconfig_tmp}"
    return 1
  fi
  if [[ ! -s "${admin_kubeconfig_tmp}" ]]; then
    log "ERROR: admin-kubeconfig Secret contains no kubeconfig."
    rm -f "${admin_kubeconfig_tmp}"
    return 1
  fi
  mv "${admin_kubeconfig_tmp}" "${ADMIN_KUBECONFIG}"

  kubectl --kubeconfig=${KIND_CONFIG} get pods -A
  log "kcp deployed."
}

main() {
  log "=========================================="
  log "  Deploy kcp"
  log "=========================================="
  log "Deployment timeout: ${DEPLOYMENT_TIMEOUT}"
  log ""

  preflight_checks
  cd "${REPO_ROOT}"
  deploy_kcp
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi