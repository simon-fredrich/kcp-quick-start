.PHONY: deploy-infra
deploy-infra:
	hack/deploy-infra.sh

.PHONY: teardown-infra
teardown-infra:
	hack/teardown-infra.sh

.PHONY: teardown-kcp
teardown-kcp:
	hack/teardown-kcp.sh

.PHONY: proxy-up
proxy-up:
	hack/proxy-up.sh

.PHONY: cluster
cluster:
	hack/cluster-scope.sh

.PHONY: admin
admin:
	hack/admin-scope.sh

.PHONY: deploy-kcp
deploy-kcp:
	hack/deploy-kcp.sh
