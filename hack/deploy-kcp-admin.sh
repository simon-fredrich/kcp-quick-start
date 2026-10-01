#!/usr/bin/env bash

# Step 1: Extract the kcp CA cert from the kcp-ca secret into ca.crt
# Step 2: Register the "base" cluster entry (server + CA) in admin.kubeconfig
# Step 3: Request a cluster-admin client certificate from cert-manager
# Step 4: Wait for the certificate to be issued
# Step 5: Extract the issued client cert/key into admin-client.crt/.key
# Step 6: Add them as the kcp-admin user credentials in admin.kubeconfig
# Step 7: Create the base context (cluster=base, user=kcp-admin) and switch to it

set -euo pipefail

KCP_EXTERNAL_HOSTNAME=localhost
KCP_PORT=8443
# Host cluster context, pinned explicitly so these calls don't depend on
# the caller's ambient KUBECONFIG/current-context (which switches to
# admin.kubeconfig's 'base' context once Step 7 below runs).
HOST_CONTEXT="kind-${CLUSTER_NAME:-kcp}"

# ---------------------------------------------------------------------------
# log — Print a timestamped log message (ISO 8601 UTC).
# ---------------------------------------------------------------------------
log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

kubectl --context="${HOST_CONTEXT}" get secret kcp-ca -n kcp \
  -o=jsonpath='{.data.tls\.crt}' | base64 -d > ca.crt
log "Wrote kcp CA cert to ca.crt."

kubectl --kubeconfig=admin.kubeconfig config set-cluster base \
  --server https://${KCP_EXTERNAL_HOSTNAME}:${KCP_PORT}/clusters/root \
  --certificate-authority=ca.crt
log "Registered cluster 'base' in admin.kubeconfig."

log "Requesting cluster-admin client certificate from cert-manager..."
kubectl --context="${HOST_CONTEXT}" apply -n kcp -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cluster-admin-client-cert
spec:
  commonName: cluster-admin
  issuerRef:
    name: kcp-front-proxy-client-issuer
    kind: Issuer
  secretName: cluster-admin-client-cert
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  usages:
    - client auth
  subject:
    organizations:
      - system:kcp:admin
EOF

log "Waiting for certificate to be issued..."
kubectl --context="${HOST_CONTEXT}" wait --for=condition=Ready certificate/cluster-admin-client-cert -n kcp --timeout=60s
log "Certificate issued."

kubectl --context="${HOST_CONTEXT}" get secret cluster-admin-client-cert -n kcp \
  -o=jsonpath='{.data.tls\.crt}' | base64 -d > admin-client.crt
kubectl --context="${HOST_CONTEXT}" get secret cluster-admin-client-cert -n kcp \
  -o=jsonpath='{.data.tls\.key}' | base64 -d > admin-client.key
log "Wrote client cert/key to admin-client.crt / admin-client.key."

kubectl --kubeconfig=admin.kubeconfig config set-credentials kcp-admin \
  --client-certificate=admin-client.crt \
  --client-key=admin-client.key
log "Registered user 'kcp-admin' in admin.kubeconfig."

kubectl --kubeconfig=admin.kubeconfig config set-context base \
  --cluster=base \
  --user=kcp-admin

kubectl --kubeconfig=admin.kubeconfig config use-context base
log "Context 'base' active in admin.kubeconfig."

log "Done. Verifying with: KUBECONFIG=admin.kubeconfig kubectl ws tree"
KUBECONFIG=admin.kubeconfig kubectl ws tree