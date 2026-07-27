# Repository Guidelines

## Project Structure & Module Organization

The supported vertical slice lives in `terraform/modules/`: `network`, `openvpn`, `eks`, `karpenter-infra`, and `cluster-addons`. Apply `terraform/examples/complete/foundation`, connect through OpenVPN, then apply `terraform/examples/complete/addons` with the same cluster name. Add-ons discover the cluster and Karpenter prerequisites from AWS; never use `terraform_remote_state`. Terratest suites and fixtures live in `terraform/tests/`; helpers belong in `scripts/`, and repo-level runbooks in `.agents/skills/`. Do not add game-service infrastructure without explicitly expanding scope.

## Build, Test, and Development Commands

- `make fmt` formats supported HCL and Go sources.
- `make check` runs formatting, initialization/validation, linting, and non-live Go tests.
- `make validate ENGINE=tofu` validates every supported module and example; use `ENGINE=terraform` for compatibility checks.
- `make security` fails on high or critical IaC misconfigurations in supported roots.
- Use `$test-unrealops-infrastructure` for billable acceptance tests; its wrapper requires an explicit account, region, run ID, and cost confirmation, then audits cleanup.
- `make vpn-pki-init ENV=dev AWS_REGION=us-west-2` creates the offline CA and uploads only OpenVPN runtime material.

## Coding Style & Naming Conventions

Canonical HCL uses two-space indentation and must pass `tofu fmt` or `terraform fmt`. Use `snake_case` for variables, locals, outputs, and resource labels; use lowercase hyphenated module directories. Modules must not configure providers or backends. Describe and validate every input, mark secrets sensitive, and never embed credentials, account IDs, regions, or CIDRs. Format Go with `gofmt` and shell with `shfmt` when available.

## Testing Guidelines

Name Go files `*_test.go` and functions `TestXxx`. Each public module needs create/assert/destroy Terratest coverage. Live tests must call `requireAcc`, use unique names, register cleanup immediately, and verify success and security boundaries. Dependency upgrades require Terraform and OpenTofu acceptance runs. After failures, verify cleanup in the authorized account and region.

## Branch, Commit, Pull Request & Release Guidelines

Name branches `<type>/<kebab-case>`, for example `feat/eks-deployment`. Use Conventional Commits with scopes such as `network`, `openvpn`, `eks`, `karpenter`, `tests`, `docs`, or `deps`: `feat(eks): add private endpoint controls`. Repository releases version the full tested module suite under Semantic Versioning. `feat` increments MINOR, `fix` increments PATCH, and `!` or a `BREAKING CHANGE:` footer increments MAJOR; `docs`, `test`, `refactor`, `chore`, and `ci` do not release unless breaking. Tag releases `vMAJOR.MINOR.PATCH`, and require consumers to pin immutable tags.

PRs must explain infrastructure and cost impact, linked issues, migration or rollback concerns, sanitized plan results, and commands run. Never commit state, private keys, client profiles, kubeconfigs, credentials, or populated `*.tfvars`.
