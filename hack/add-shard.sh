#!/usr/bin/env bash
#
# Adds a shard and its own single-replica etcd to the existing local KCP setup.
# Requires the existing KCP operator, etcd-druid, cert-manager, and RootShard.
# Reuses the etcd configuration and image defaults from deploy-kcp.sh.
#
# Usage: hack/add-shard.sh [-n namespace] [-r root-shard] [-e etcd-name] [-d] shard-name
#
# Example: hack/add-shard.sh shard-03
#          hack/add-shard.sh -d shard-03
#
# -d validates both manifests with server-side dry-run; creates nothing.
# Defaults: namespace=default, root-shard=root, etcd-name=etcd-<shard-name>.
# Environment: KIND_CONFIG (filename under .kube), KCP_VERSION,
# ETCD_IMAGE, ETCD_BACKUP_IMAGE, DEPLOYMENT_TIMEOUT (default 600s).
# The new shard enables LogicalClusterMigration. Existing shards and the cache
# must also have it enabled for rebalancing. No workspaces are moved here.
# Safe to rerun with the same names; failed deployments are left for inspection.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-kcp.sh"

NAMESPACE="default"
ROOT_SHARD="root"
ETCD_NAME=""
DRY_RUN="none"

while getopts "n:r:e:dh" opt; do
  case "${opt}" in
    n) NAMESPACE="${OPTARG}" ;;
    r) ROOT_SHARD="${OPTARG}" ;;
    e) ETCD_NAME="${OPTARG}" ;;
    d) DRY_RUN="server" ;;
    h)
      sed -n '/^# Adds a shard/,/^# Safe to rerun/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) exit 1 ;;
  esac
done
shift "$((OPTIND - 1))"
if [[ "$#" -ne 1 ]]; then
  echo "ERROR: specify exactly one shard name; use -h for usage." >&2
  exit 1
fi
SHARD_NAME="$1"
ETCD_NAME="${ETCD_NAME:-etcd-${SHARD_NAME}}"
for name in "${SHARD_NAME}" "${ETCD_NAME}" "${NAMESPACE}" "${ROOT_SHARD}"; do
  if [[ ${#name} -gt 63 || ! "${name}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "ERROR: '${name}' must be a DNS label of at most 63 characters." >&2
    exit 1
  fi
done
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required." >&2
  exit 1
fi
if [[ ! -f "${KIND_CONFIG}" ]]; then
  echo "ERROR: hosting kubeconfig not found at ${KIND_CONFIG}." >&2
  exit 1
fi

kubectl --kubeconfig="${KIND_CONFIG}" -n "${NAMESPACE}" wait \
  --for=condition=Available "rootshard/${ROOT_SHARD}" --timeout="${DEPLOYMENT_TIMEOUT}"

# Do not repurpose an etcd already used by another shard.
existing_shards="$(kubectl --kubeconfig="${KIND_CONFIG}" -n "${NAMESPACE}" get shards \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.etcd.endpoints}{"\n"}{end}')"
while IFS=$'\t' read -r name endpoints; do
  if [[ "${name}" == "${SHARD_NAME}" &&
    "${endpoints}" != "[\"http://${ETCD_NAME}-client.${NAMESPACE}.svc.cluster.local:2379\"]" ]]; then
    echo "ERROR: shard '${SHARD_NAME}' already exists with different etcd endpoints; refusing to change storage." >&2
    exit 1
  fi
  if [[ -n "${name}" && "${name}" != "${SHARD_NAME}" &&
    "${endpoints}" == *"//${ETCD_NAME}-client."* ]]; then
    echo "ERROR: etcd '${ETCD_NAME}' is already used by shard '${name}'." >&2
    exit 1
  fi
done <<< "${existing_shards}"
root_endpoints="$(kubectl --kubeconfig="${KIND_CONFIG}" -n "${NAMESPACE}" get rootshards \
  -o jsonpath='{range .items[*]}{.spec.etcd.endpoints}{"\n"}{end}')"
if [[ "${root_endpoints}" == *"//${ETCD_NAME}-client."* ]]; then
  echo "ERROR: etcd '${ETCD_NAME}' is already used by a root shard." >&2
  exit 1
fi

log "Deploying etcd '${ETCD_NAME}' for shard '${SHARD_NAME}' (dry-run=${DRY_RUN})..."
apply_etcd "${ETCD_NAME}" "${NAMESPACE}" "${DRY_RUN}"
if [[ "${DRY_RUN}" == none ]]; then
  kubectl --kubeconfig="${KIND_CONFIG}" -n "${NAMESPACE}" wait \
    --for=condition=Ready "etcd/${ETCD_NAME}" --timeout="${DEPLOYMENT_TIMEOUT}"
fi

kubectl --kubeconfig="${KIND_CONFIG}" -n "${NAMESPACE}" apply --dry-run="${DRY_RUN}" -f - <<EOF
apiVersion: operator.kcp.io/v1alpha1
kind: Shard
metadata:
  name: ${SHARD_NAME}
  labels:
    app.kubernetes.io/name: kcp-operator
    app.kubernetes.io/managed-by: kustomize
spec:
  replicas: 1
  etcd:
    endpoints:
      - http://${ETCD_NAME}-client.${NAMESPACE}.svc.cluster.local:2379
  rootShard:
    ref:
      name: ${ROOT_SHARD}
  auth:
    serviceAccount:
      enabled: true
  extraArgs:
    - --feature-gates=LogicalClusterMigration=true
  image:
    tag: ${KCP_VERSION}
EOF
if [[ "${DRY_RUN}" == server ]]; then
  log "Server-side validation passed; no resources were changed."
  exit 0
fi
kubectl --kubeconfig="${KIND_CONFIG}" -n "${NAMESPACE}" wait \
  --for=condition=Available "shard/${SHARD_NAME}" --timeout="${DEPLOYMENT_TIMEOUT}"
log "Shard '${SHARD_NAME}' and etcd '${ETCD_NAME}' are ready."
log "Preview redistribution with: go run ./cmd/rebalance --namespace=${NAMESPACE}"
