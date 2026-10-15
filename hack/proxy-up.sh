#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

PORT=${PORT:-6443}
CLUSTER_NAME=${CLUSTER_NAME:-kcp}

export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
KUBECONFIG="$(mktemp "${TMPDIR:-/tmp}/kcp-proxy-kubeconfig.XXXXXX")"
export KUBECONFIG
trap 'rm -f "${KUBECONFIG}"' EXIT
kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG}"

while true; do
  echo "starting/restarting proxy service"
  kubectl --context="kind-${CLUSTER_NAME}" -n default port-forward \
    svc/frontproxy-sample-front-proxy "${PORT}:6443"
  sleep 3
done