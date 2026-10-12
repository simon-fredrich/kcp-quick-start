.PHONY: deploy-infra
deploy-infra:
	hack/deploy-infra.sh

.PHONY: teardown-infra
teardown-infra:
	hack/teardown-infra.sh
