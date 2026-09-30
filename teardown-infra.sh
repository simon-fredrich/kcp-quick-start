# Delete the kind cluster
kind delete cluster --name kcp

rm -f ca.crt admin-client.crt admin-client.key admin.kubeconfig
rm -f team-*.crt team-*.key team-*.kubeconfig

