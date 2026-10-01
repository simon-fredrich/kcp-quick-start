#!/usr/bin/env bash

# Removes the Certificate/Secret and local files deploy-kcp-admin.sh generated.

set -euo pipefail

# Host cluster context, pinned explicitly so these calls don't depend on
# the caller's ambient KUBECONFIG/current-context.
HOST_CONTEXT="kind-${CLUSTER_NAME:-kcp}"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

kubectl --context="${HOST_CONTEXT}" delete certificate cluster-admin-client-cert -n kcp --ignore-not-found
kubectl --context="${HOST_CONTEXT}" delete secret cluster-admin-client-cert -n kcp --ignore-not-found
log "Removed Certificate/Secret cluster-admin-client-cert from namespace 'kcp'."

kubectl --kubeconfig=admin.kubeconfig config unset contexts.base >/dev/null 2>&1 || true
kubectl --kubeconfig=admin.kubeconfig config unset users.kcp-admin >/dev/null 2>&1 || true
kubectl --kubeconfig=admin.kubeconfig config unset clusters.base >/dev/null 2>&1 || true
log "Removed 'base' context, 'kcp-admin' user and 'base' cluster from admin.kubeconfig."

rm -f ca.crt admin-client.crt admin-client.key
log "Removed ca.crt, admin-client.crt, admin-client.key."
