#!/usr/bin/env bash
#
# Lists workspaces across every operator-managed KCP shard in a namespace.
# Requires kubectl, jq, and the kubeconfig exported by
# hack/generate-kcp-wildcard-kubeconfig.sh. No persistent port-forwards needed.
#
# Usage: hack/list-kcp-workspaces.sh [-k hosting-kubeconfig] [-c kcp-kubeconfig] [-n namespace] [-r workspaces|logicalclusters]
#
# Defaults: .kube/kind.kubeconfig, .kube/kcp-wildcard.kubeconfig, default, workspaces.
# Workspace objects live on their parent's shard; use -r logicalclusters to see
# the logical clusters actually stored on each shard (including system clusters).
# This uses the unrestricted administrator credential; keep it private.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOSTING_KUBECONFIG="${REPO_ROOT}/.kube/kind.kubeconfig"
KCP_KUBECONFIG="${REPO_ROOT}/.kube/kcp-wildcard.kubeconfig"
NAMESPACE="default"
RESOURCE="workspaces"

while getopts "k:c:n:r:h" opt; do
  case "${opt}" in
    k) HOSTING_KUBECONFIG="${OPTARG}" ;;
    c) KCP_KUBECONFIG="${OPTARG}" ;;
    n) NAMESPACE="${OPTARG}" ;;
    r) RESOURCE="${OPTARG}" ;;
    h)
      sed -n '/^# Lists workspaces/,/^# This uses/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) exit 1 ;;
  esac
done
shift "$((OPTIND - 1))"
if [[ "$#" -ne 0 ]]; then
  echo "ERROR: unexpected positional arguments; use -h for usage." >&2
  exit 1
fi
case "${RESOURCE}" in
  workspaces) API_PATH="tenancy.kcp.io/v1alpha1/workspaces"; LIST_KIND="WorkspaceList" ;;
  logicalclusters) API_PATH="core.kcp.io/v1alpha1/logicalclusters"; LIST_KIND="LogicalClusterList" ;;
  *) echo "ERROR: -r must be workspaces or logicalclusters." >&2; exit 1 ;;
esac
for cmd in kubectl jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' not found on PATH." >&2
    exit 1
  fi
done
for config in "${HOSTING_KUBECONFIG}" "${KCP_KUBECONFIG}"; do
  if [[ ! -f "${config}" ]]; then
    echo "ERROR: kubeconfig not found: ${config}" >&2
    exit 1
  fi
done

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kcp-shards.XXXXXX")"
FORWARD_PID=""
stop_forward() {
  if [[ -n "${FORWARD_PID}" ]]; then
    if kill -0 "${FORWARD_PID}" 2>/dev/null; then
      kill "${FORWARD_PID}"
    fi
    wait "${FORWARD_PID}" || true
    FORWARD_PID=""
  fi
}
cleanup() {
  stop_forward
  rm -f "${TEMP_DIR}/shards.tsv" "${TEMP_DIR}/forward.log" \
    "${TEMP_DIR}/response.json" "${TEMP_DIR}/rows.tsv" "${TEMP_DIR}/clusters.tsv" \
    "${TEMP_DIR}/apis.json" "${TEMP_DIR}/workspaces.json"
  rmdir "${TEMP_DIR}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl --kubeconfig="${HOSTING_KUBECONFIG}" --request-timeout=30s -n "${NAMESPACE}" \
  get services -l 'app.kubernetes.io/managed-by=kcp-operator,app.kubernetes.io/component in (rootshard,shard)' \
  -o json |
  jq -r '.items[] | select(any(.spec.ports[]; .name == "https" and .port == 6443)) |
    [.metadata.labels["app.kubernetes.io/instance"], .metadata.name,
     (.metadata.name + "." + .metadata.namespace + ".svc.cluster.local")] | @tsv' \
  > "${TEMP_DIR}/shards.tsv"
if [[ ! -s "${TEMP_DIR}/shards.tsv" ]]; then
  echo "ERROR: no operator-managed shard Services found in namespace ${NAMESPACE}." >&2
  exit 1
fi

if [[ "${RESOURCE}" == workspaces ]]; then
  printf 'SHARD\tPARENT_CLUSTER\tWORKSPACE\tURL\tPHASE\n' > "${TEMP_DIR}/rows.tsv"
else
  printf 'SHARD\tLOGICAL_CLUSTER\tPATH\tPHASE\n' > "${TEMP_DIR}/rows.tsv"
fi
while IFS=$'\t' read -r shard service tls_name; do
  echo "Listing ${RESOURCE} on shard ${shard} (${service})." >&2
  : > "${TEMP_DIR}/forward.log"
  kubectl --kubeconfig="${HOSTING_KUBECONFIG}" -n "${NAMESPACE}" \
    port-forward --address=127.0.0.1 "svc/${service}" :6443 \
    > "${TEMP_DIR}/forward.log" 2>&1 &
  FORWARD_PID="$!"
  port=""
  for ((attempt=0; attempt<150; attempt++)); do
    port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 6443$/\1/p' "${TEMP_DIR}/forward.log")"
    if [[ -n "${port}" ]]; then
      break
    fi
    if ! kill -0 "${FORWARD_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if [[ -z "${port}" ]]; then
    echo "ERROR: port-forward failed to become ready for shard ${shard}." >&2
    cat "${TEMP_DIR}/forward.log" >&2
    exit 1
  fi
  if ! kubectl --kubeconfig="${KCP_KUBECONFIG}" --server="https://127.0.0.1:${port}" \
    --tls-server-name="${tls_name}" --request-timeout=30s \
    get --raw="/clusters/*/apis/core.kcp.io/v1alpha1/logicalclusters" > "${TEMP_DIR}/response.json"; then
    echo "ERROR: wildcard request failed on shard ${shard}; no partial results printed." >&2
    exit 1
  fi
  if ! jq -e --arg kind "LogicalClusterList" \
    '.kind == $kind and (.items | type == "array")' "${TEMP_DIR}/response.json" >/dev/null; then
    echo "ERROR: unexpected response on shard ${shard}; expected LogicalClusterList." >&2
    exit 1
  fi
  if [[ "${RESOURCE}" == workspaces ]]; then
    jq -r '.items[].metadata.annotations["kcp.io/cluster"]' \
      "${TEMP_DIR}/response.json" > "${TEMP_DIR}/clusters.tsv"
    # Workspaces are bound APIs and do not support the bare wildcard URL.
    # Discover and query them in each logical cluster stored on this shard.
    while IFS= read -r cluster; do
      kubectl --kubeconfig="${KCP_KUBECONFIG}" --server="https://127.0.0.1:${port}" \
        --tls-server-name="${tls_name}" --request-timeout=30s \
        get --raw="/clusters/${cluster}/apis" > "${TEMP_DIR}/apis.json"
      if ! jq -e 'any(.groups[].versions[]; .groupVersion == "tenancy.kcp.io/v1alpha1")' \
        "${TEMP_DIR}/apis.json" >/dev/null; then
        continue
      fi
      kubectl --kubeconfig="${KCP_KUBECONFIG}" --server="https://127.0.0.1:${port}" \
        --tls-server-name="${tls_name}" --request-timeout=30s \
        get --raw="/clusters/${cluster}/apis/tenancy.kcp.io/v1alpha1" > "${TEMP_DIR}/apis.json"
      if ! jq -e 'any(.resources[]; .name == "workspaces")' "${TEMP_DIR}/apis.json" >/dev/null; then
        continue
      fi
      kubectl --kubeconfig="${KCP_KUBECONFIG}" --server="https://127.0.0.1:${port}" \
        --tls-server-name="${tls_name}" --request-timeout=30s \
        get --raw="/clusters/${cluster}/apis/${API_PATH}" > "${TEMP_DIR}/workspaces.json"
      if ! jq -e --arg kind "${LIST_KIND}" '.kind == $kind and (.items | type == "array")' \
        "${TEMP_DIR}/workspaces.json" >/dev/null; then
        echo "ERROR: expected ${LIST_KIND} in cluster ${cluster} on shard ${shard}." >&2
        exit 1
      fi
      jq -r --arg shard "${shard}" --arg cluster "${cluster}" '.items[] |
        [$shard, $cluster, .metadata.name, .spec.URL, .status.phase] | @tsv' \
        "${TEMP_DIR}/workspaces.json" >> "${TEMP_DIR}/rows.tsv"
    done < "${TEMP_DIR}/clusters.tsv"
  else
    jq -r --arg shard "${shard}" '.items[] |
      [$shard, .metadata.annotations["kcp.io/cluster"],
       .metadata.annotations["kcp.io/path"], .status.phase] | @tsv' \
      "${TEMP_DIR}/response.json" >> "${TEMP_DIR}/rows.tsv"
  fi
  stop_forward
done < "${TEMP_DIR}/shards.tsv"
cat "${TEMP_DIR}/rows.tsv"
