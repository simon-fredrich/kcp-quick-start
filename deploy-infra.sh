# step 1: create a kind cluster
kind create cluster --name kcp --config=kind-config.yaml
kubectl cluster-info --context kind-kcp
kubectl config use-context kind-kcp

# step 2: install cert-manager
kubectl apply -f cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

# step 4: deploy kcp with helm
helm repo add kcp https://kcp-dev.github.io/helm-charts
helm repo update

helm upgrade --install kcp kcp/kcp \
  --namespace kcp \
  --create-namespace \
  --set externalHostname=localhost \
  --set-string externalPort=8443 \
  --set kcpFrontProxy.service.type=NodePort \
  --set kcpFrontProxy.service.nodePort=30443 \
  --set audit.enabled=false \
  --wait

KCP_FRONT_PROXY_IP=$(kubectl get svc kcp-front-proxy -n kcp -o jsonpath='{.spec.clusterIP}')
helm upgrade kcp kcp/kcp \
  --namespace kcp \
  --reuse-values \
  --set kcp.hostAliases.enabled=true \
  --set "kcp.hostAliases.values[0].ip=${KCP_FRONT_PROXY_IP}" \
  --set "kcp.hostAliases.values[0].hostnames[0]=localhost" \
  --set kcpFrontProxy.hostAliases.enabled=true \
  --set "kcpFrontProxy.hostAliases.values[0].ip=${KCP_FRONT_PROXY_IP}" \
  --set "kcpFrontProxy.hostAliases.values[0].hostnames[0]=localhost" \
  --wait

kubectl get pods -n kcp

# step 5: configure admin access
kubectl get secret kcp-ca -n kcp \
  -o=jsonpath='{.data.tls\.crt}' | base64 -d > ca.crt

kubectl --kubeconfig=admin.kubeconfig config set-cluster base \
  --server https://localhost:8443/clusters/root \
  --certificate-authority=ca.crt

kubectl apply -n kcp -f admin-client-cert.yaml
kubectl wait --for=condition=Ready certificate/cluster-admin-client-cert -n kcp --timeout=60s

kubectl get secret cluster-admin-client-cert -n kcp \
  -o=jsonpath='{.data.tls\.crt}' | base64 -d > admin-client.crt
kubectl get secret cluster-admin-client-cert -n kcp \
  -o=jsonpath='{.data.tls\.key}' | base64 -d > admin-client.key

kubectl --kubeconfig=admin.kubeconfig config set-credentials kcp-admin \
  --client-certificate=admin-client.crt \
  --client-key=admin-client.key

kubectl --kubeconfig=admin.kubeconfig config set-context base \
  --cluster=base \
  --user=kcp-admin

kubectl --kubeconfig=admin.kubeconfig config use-context base

export KUBECONFIG=admin.kubeconfig
kubectl ws tree

# step 6: create team workspaces
kubectl ws create team-alpha --enter
kubectl ws ..
kubectl ws create team-beta --enter
kubectl ws :root

kubectl ws tree

# step 7: generate team certificates
kind export kubeconfig --name kcp --kubeconfig "$KIND_KUBECONFIG"
export KIND_KUBECONFIG=$HOME/.kube/config

KUBECONFIG=${KIND_KUBECONFIG} kubectl apply -n kcp -f team-alpha-cert.yaml
KUBECONFIG=${KIND_KUBECONFIG} kubectl apply -n kcp -f team-beta-cert.yaml

for team in alpha beta; do
  KUBECONFIG=${KIND_KUBECONFIG} kubectl wait --for=condition=Ready certificate/team-${team}-cert -n kcp --timeout=60s
done

# step 8: grant workspace access
k --kubeconfig=admin.kubeconfig config use-context base
kubectl ws :root:team-alpha
kubectl apply -f team-alpha-access.yaml

kubectl ws :root:team-beta
kubectl apply -f team-beta-access.yaml

kubectl ws :root

# step 9: create team kubeconfigs
for team in alpha beta; do
  KUBECONFIG=${KIND_KUBECONFIG} kubectl get secret team-${team}-cert -n kcp \
    -o=jsonpath='{.data.tls\.crt}' | base64 -d > team-${team}.crt
  KUBECONFIG=${KIND_KUBECONFIG} kubectl get secret team-${team}-cert -n kcp \
    -o=jsonpath='{.data.tls\.key}' | base64 -d > team-${team}.key
done

for team in alpha beta; do
  kubectl --kubeconfig=team-${team}.kubeconfig config set-cluster kcp \
    --server https://${KCP_EXTERNAL_HOSTNAME}:${KCP_PORT}/clusters/root:team-${team} \
    --certificate-authority=ca.crt

  kubectl --kubeconfig=team-${team}.kubeconfig config set-credentials team-${team} \
    --client-certificate=team-${team}.crt \
    --client-key=team-${team}.key

  kubectl --kubeconfig=team-${team}.kubeconfig config set-context team-${team} \
    --cluster=kcp \
    --user=team-${team}

  kubectl --kubeconfig=team-${team}.kubeconfig config use-context team-${team}
done

# step 10: verify team access
for team in alpha beta; do
  echo "--- team-${team} ---"
  KUBECONFIG=team-${team}.kubeconfig kubectl get namespaces
done

for team in alpha beta; do
  KUBECONFIG=team-${team}.kubeconfig kubectl get namespace demo-${team} >/dev/null 2>&1 || \
    KUBECONFIG=team-${team}.kubeconfig kubectl create namespace demo-${team}
  KUBECONFIG=team-${team}.kubeconfig kubectl get namespace demo-${team}
done

# Team Alpha should NOT be able to access Team Beta's workspace
KUBECONFIG=team-alpha.kubeconfig kubectl get namespaces \
  --server https://${KCP_EXTERNAL_HOSTNAME}:${KCP_PORT}/clusters/root:team-beta && \
  echo "ERROR: Team Alpha can access Team Beta (isolation broken)" || \
  echo "OK: Team Alpha cannot access Team Beta (isolation works)"