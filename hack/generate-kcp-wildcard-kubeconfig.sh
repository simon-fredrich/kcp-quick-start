#!/usr/bin/env bash
#
# Creates a KCP system:masters client certificate using the existing
# root-client-ca cert-manager Issuer, then exports a shard-local kubeconfig.
# This is unrestricted KCP administrator access, not a kind cluster credential.
#
# Start a direct root-shard port-forward in another terminal and keep it running:
#   kubectl --kubeconfig=.kube/kind.kubeconfig -n default port-forward svc/root-kcp 9443:6443
#
# Usage:
#   hack/generate-kcp-wildcard-kubeconfig.sh [-k hosting-kubeconfig] [-n namespace] [-s shard-url] [-t tls-server-name] [-o output]
#
# Defaults:
#   -k  <repository>/.kube/kind.kubeconfig
#   -n  default
#   -s  https://localhost:9443 (direct root shard, NOT the front proxy)
#   -t  localhost (must appear in the shard's serving certificate)
#   -o  <repository>/.kube/kcp-wildcard.kubeconfig
#
# Requires kubectl, base64, openssl, jq, cert-manager, and the project's root
# shard with Issuer root-client-ca and CA Secrets root-ca, root-client-ca,
# and root-server-ca.
# Re-running exports the current certificate. cert-manager renews its Secret,
# but the embedded kubeconfig must be regenerated to pick up that renewal.
#
# After exporting, list workspaces across all operator-managed shards with:
#   hack/list-kcp-workspaces.sh
# Or list the logical clusters stored on each shard:
#   hack/list-kcp-workspaces.sh -r logicalclusters

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOSTING_KUBECONFIG="${REPO_ROOT}/.kube/kind.kubeconfig"
NAMESPACE="default"
SHARD_URL="https://localhost:9443"
TLS_SERVER_NAME="localhost"
OUTPUT="${REPO_ROOT}/.kube/kcp-wildcard.kubeconfig"
CERT_NAME="kcp-wildcard-admin"
WILDCARD_PATH="/clusters/*/apis/core.kcp.io/v1alpha1/logicalclusters"

while getopts "k:n:s:t:o:h" opt; do
  case "${opt}" in
    k) HOSTING_KUBECONFIG="${OPTARG}" ;;
    n) NAMESPACE="${OPTARG}" ;;
    s) SHARD_URL="${OPTARG}" ;;
    t) TLS_SERVER_NAME="${OPTARG}" ;;
    o) OUTPUT="${OPTARG}" ;;
    h)
      sed -n '/^# Creates a KCP/,/^# but the embedded kubeconfig/p' "$0" | sed 's/^# \{0,1\}//'
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

for cmd in kubectl base64 openssl jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' not found on PATH." >&2
    exit 1
  fi
done
SHARD_URL="${SHARD_URL%/}"
if [[ "${SHARD_URL}" != https://* || "${SHARD_URL#https://}" == */* ]]; then
  echo "ERROR: -s must be an HTTPS shard URL without a path (for example https://localhost:9443)." >&2
  exit 1
fi
if [[ ! -f "${HOSTING_KUBECONFIG}" ]]; then
  echo "ERROR: hosting kubeconfig not found: ${HOSTING_KUBECONFIG}" >&2
  exit 1
fi
if [[ "${OUTPUT}" -ef "${HOSTING_KUBECONFIG}" ]]; then
  echo "ERROR: output must not overwrite the hosting kubeconfig." >&2
  exit 1
fi

hosting_kubectl() {
  kubectl --kubeconfig="${HOSTING_KUBECONFIG}" --request-timeout=30s -n "${NAMESPACE}" "$@"
}

hosting_kubectl wait --for=condition=Ready issuers.cert-manager.io/root-client-ca --timeout=120s

echo "Issuing KCP administrator certificate via root-client-ca." >&2
hosting_kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${NAMESPACE}
spec:
  secretName: ${CERT_NAME}
  commonName: kcp-wildcard-admin
  subject:
    organizations:
      - system:masters
  duration: 24h
  renewBefore: 8h
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  usages:
    - client auth
  issuerRef:
    name: root-client-ca
    kind: Issuer
    group: cert-manager.io
EOF
generation="$(hosting_kubectl get certificates.cert-manager.io "${CERT_NAME}" -o jsonpath='{.metadata.generation}')"
hosting_kubectl wait \
  --for="jsonpath={.status.conditions[?(@.type==\"Ready\")].observedGeneration}=${generation}" \
  "certificates.cert-manager.io/${CERT_NAME}" --timeout=120s
hosting_kubectl wait --for=condition=Ready "certificates.cert-manager.io/${CERT_NAME}" --timeout=120s

mkdir -p "$(dirname "${OUTPUT}")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kcp-wildcard.XXXXXX")"
TEMP_OUTPUT=""
cleanup() {
  rm -f "${TEMP_DIR}/client.crt" "${TEMP_DIR}/client.key" "${TEMP_DIR}/server-ca.crt" \
    "${TEMP_DIR}/client-ca.crt" "${TEMP_DIR}/root-ca.crt" "${TEMP_DIR}/logicalclusters.json"
  rmdir "${TEMP_DIR}"
  if [[ -n "${TEMP_OUTPUT}" ]]; then
    rm -f "${TEMP_OUTPUT}"
  fi
}
trap cleanup EXIT
TEMP_OUTPUT="$(mktemp "$(dirname "${OUTPUT}")/.kcp-wildcard.XXXXXX")"

# Read the key and certificate from the same Secret version.
hosting_kubectl get secret "${CERT_NAME}" -o json |
  jq -er '.data | [."tls.crt", ."tls.key"] | .[] | select(length > 0)' |
  {
    IFS= read -r cert
    IFS= read -r key
    printf '%s' "${cert}" | base64 -d > "${TEMP_DIR}/client.crt"
    printf '%s' "${key}" | base64 -d > "${TEMP_DIR}/client.key"
  }
hosting_kubectl get secret root-server-ca -o jsonpath='{.data.tls\.crt}' |
  base64 -d > "${TEMP_DIR}/server-ca.crt"
hosting_kubectl get secret root-client-ca -o jsonpath='{.data.tls\.crt}' |
  base64 -d > "${TEMP_DIR}/client-ca.crt"
hosting_kubectl get secret root-ca -o jsonpath='{.data.tls\.crt}' |
  base64 -d > "${TEMP_DIR}/root-ca.crt"
openssl verify -purpose sslclient -CAfile "${TEMP_DIR}/root-ca.crt" \
  -untrusted "${TEMP_DIR}/client-ca.crt" "${TEMP_DIR}/client.crt"

kubectl --kubeconfig="${TEMP_OUTPUT}" config set-cluster kcp-root-shard \
  --server="${SHARD_URL}/clusters/root" \
  --tls-server-name="${TLS_SERVER_NAME}" \
  --certificate-authority="${TEMP_DIR}/server-ca.crt" --embed-certs=true >/dev/null
kubectl --kubeconfig="${TEMP_OUTPUT}" config set-credentials kcp-wildcard-admin \
  --client-certificate="${TEMP_DIR}/client.crt" \
  --client-key="${TEMP_DIR}/client.key" --embed-certs=true >/dev/null
kubectl --kubeconfig="${TEMP_OUTPUT}" config set-context kcp-wildcard-admin \
  --cluster=kcp-root-shard --user=kcp-wildcard-admin >/dev/null
kubectl --kubeconfig="${TEMP_OUTPUT}" config use-context kcp-wildcard-admin >/dev/null

echo "Testing the wildcard LogicalCluster list against ${SHARD_URL}." >&2
if ! kubectl --kubeconfig="${TEMP_OUTPUT}" --server="${SHARD_URL}" --request-timeout=30s \
  get --raw="${WILDCARD_PATH}" > "${TEMP_DIR}/logicalclusters.json"; then
  echo "ERROR: wildcard request failed; existing output was not replaced." >&2
  echo "For local access, keep this running in another terminal:" >&2
  echo "kubectl --kubeconfig=${HOSTING_KUBECONFIG} -n ${NAMESPACE} port-forward svc/root-kcp 9443:6443" >&2
  exit 1
fi
if ! jq -e '.kind == "LogicalClusterList" and (.items | type == "array")' \
  "${TEMP_DIR}/logicalclusters.json" >/dev/null; then
  echo "ERROR: wildcard endpoint did not return a LogicalClusterList; existing output was not replaced." >&2
  exit 1
fi
chmod 600 "${TEMP_OUTPUT}"
mv "${TEMP_OUTPUT}" "${OUTPUT}"
TEMP_OUTPUT=""

echo "Wrote ${OUTPUT} (unrestricted KCP administrator; keep private)." >&2
echo "This lists only logical clusters stored on this shard, not every shard." >&2
echo "For all shards, run: ${SCRIPT_DIR}/list-kcp-workspaces.sh -c ${OUTPUT}" >&2
echo "Keep the direct-shard port-forward running when using the kubeconfig." >&2
echo "List logical clusters with:" >&2
printf 'kubectl --kubeconfig=%q --server=%q get --raw=%q\n' \
  "${OUTPUT}" "${SHARD_URL}" "${WILDCARD_PATH}"
