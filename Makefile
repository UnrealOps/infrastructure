SHELL := /usr/bin/env bash

ENGINE ?= tofu
ENV ?= dev
USER ?= $(shell id -un)
AWS_REGION ?=
PKI_SECRET_NAME ?= unrealops/$(ENV)/openvpn/runtime
CLUSTER_NAME ?= $(ENV)
LORE_SECRET_NAME ?= unrealops/$(CLUSTER_NAME)/lore/runtime
LORE_CA_OUTPUT ?= $(CLUSTER_NAME)-lore-ca.crt

SUPPORTED_DIRS := \
	terraform/modules/network \
	terraform/modules/openvpn \
	terraform/modules/eks \
	terraform/modules/karpenter-infra \
	terraform/modules/cluster-addons-infra \
	terraform/modules/cluster-addons \
	terraform/modules/lore-infra \
	terraform/modules/lore-workload \
	terraform/examples/complete/foundation \
	terraform/examples/complete/addons

TRIVY_SKIP_DIRS := \
	--tf-exclude-downloaded-modules \
	--skip-dirs '**/.terraform'

.PHONY: fmt fmt-check validate lint security test check test-live foundation-init addons-init vpn-pki-init vpn-client vpn-revoke lore-pki-init lore-pki-rotate lore-ca

fmt:
	@for dir in $(SUPPORTED_DIRS); do [ ! -d "$$dir" ] || $(ENGINE) fmt "$$dir"; done
	@files="$$(find terraform/tests -type f -name '*.go' -print)"; [ -z "$$files" ] || gofmt -w $$files

fmt-check:
	@for dir in $(SUPPORTED_DIRS); do [ ! -d "$$dir" ] || $(ENGINE) fmt -check "$$dir"; done
	@files="$$(find terraform/tests -type f -name '*.go' -print)"; [ -z "$$files" ] || test -z "$$(gofmt -l $$files)" || { gofmt -l $$files; exit 1; }

validate:
	ENGINE=$(ENGINE) scripts/validate.sh

lint:
	@command -v tflint >/dev/null || { echo "tflint is required" >&2; exit 1; }
	@config="$$(pwd)/.tflint.hcl"; for dir in $(SUPPORTED_DIRS); do [ ! -d "$$dir" ] || tflint --chdir="$$dir" --config="$$config"; done

security:
	@command -v trivy >/dev/null || { echo "trivy is required" >&2; exit 1; }
	@set -e; for dir in $(SUPPORTED_DIRS); do [ ! -d "$$dir" ] || trivy config $(TRIVY_SKIP_DIRS) --exit-code 1 --severity HIGH,CRITICAL "$$dir"; done

test:
	go test ./... -count=1

check: fmt-check validate lint test

test-live:
	@test "$(TF_ACC)" = "1" || { echo "Set TF_ACC=1 to authorize billable AWS tests" >&2; exit 1; }
	@set -e; cleanup() { \
		for dir in \
			terraform/examples/complete/foundation \
			terraform/examples/complete/addons \
			terraform/modules/cluster-addons-infra \
			terraform/modules/lore-infra \
			terraform/modules/lore-workload \
			terraform/tests/fixtures/network \
			terraform/tests/fixtures/openvpn; do \
			rm -rf "$$dir/.terraform"; \
			rm -f "$$dir/.terraform.lock.hcl"; \
		done; \
	}; trap cleanup EXIT; cleanup; \
	TF_ACC=1 TERRAFORM_BINARY=$(ENGINE) go test ./terraform/tests -count=1 -p 1 -parallel 1 -v -timeout 0

foundation-init:
	rm -rf terraform/examples/complete/foundation/.terraform
	rm -f terraform/examples/complete/foundation/.terraform.lock.hcl
	$(ENGINE) -chdir=terraform/examples/complete/foundation init

addons-init:
	rm -rf terraform/examples/complete/addons/.terraform
	rm -f terraform/examples/complete/addons/.terraform.lock.hcl
	$(ENGINE) -chdir=terraform/examples/complete/addons init

vpn-pki-init:
	@test -n "$(AWS_REGION)" || { echo "AWS_REGION is required" >&2; exit 1; }
	scripts/openvpn-pki.sh init --environment "$(ENV)" --region "$(AWS_REGION)" --secret-id "$(PKI_SECRET_NAME)"

vpn-client:
	@test -n "$(ENDPOINT)" || { echo "ENDPOINT is required" >&2; exit 1; }
	scripts/openvpn-pki.sh client --environment "$(ENV)" --name "$(USER)" --endpoint "$(ENDPOINT)"

vpn-revoke:
	@test -n "$(AWS_REGION)" || { echo "AWS_REGION is required" >&2; exit 1; }
	scripts/openvpn-pki.sh revoke --environment "$(ENV)" --name "$(USER)" --region "$(AWS_REGION)" --secret-id "$(PKI_SECRET_NAME)"

lore-pki-init:
	@test -n "$(AWS_REGION)" || { echo "AWS_REGION is required" >&2; exit 1; }
	scripts/lore-pki.sh init --cluster-name "$(CLUSTER_NAME)" --region "$(AWS_REGION)" --secret-id "$(LORE_SECRET_NAME)"

lore-pki-rotate:
	@test -n "$(AWS_REGION)" || { echo "AWS_REGION is required" >&2; exit 1; }
	scripts/lore-pki.sh rotate --cluster-name "$(CLUSTER_NAME)" --region "$(AWS_REGION)" --secret-id "$(LORE_SECRET_NAME)"

lore-ca:
	scripts/lore-pki.sh export-ca --cluster-name "$(CLUSTER_NAME)" --output "$(LORE_CA_OUTPUT)"
