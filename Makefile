.PHONY: deploy-infra
deploy-infra:
	hack/deploy-infra.sh

.PHONY: teardown-infra
teardown-infra:
	hack/teardown-infra.sh

.PHONY: proxy-up
proxy-up:
	hack/proxy-up.sh

.PHONY: cluster-scope
cluster-scope:
	hack/cluster-scope.sh

.PHONY: admin-scope
admin-scope:
	hack/admin-scope.sh

.PHONY: shards-up
shards-up:
	kubectl apply -f ./hack/deploy/kcp/shards