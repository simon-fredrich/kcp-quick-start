.PHONY: deploy-infra
deploy-infra:
	hack/deploy-infra.sh

.PHONY: teardown-infra
teardown-infra:
	hack/teardown-infra.sh

.PHONY: deploy-kcp-admin
deploy-kcp-admin:
	hack/deploy-kcp-admin.sh

.PHONY: teardown-kcp-admin
teardown-kcp-admin:
	hack/teardown-kcp-admin.sh

.PHONY: install-test-deps
install-test-deps:
	hack/install-test-deps.sh