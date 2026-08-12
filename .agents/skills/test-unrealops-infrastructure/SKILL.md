---
name: test-unrealops-infrastructure
description: Test and clean up the supported UnrealOps Terraform and OpenTofu network, OpenVPN, private EKS, and Karpenter modules. Use when running repository checks, Terratest contract tests, billable AWS acceptance tests, diagnosing failures, recovering interrupted runs, or proving test resources are gone from an explicitly authorized account and region.
---

# Test UnrealOps Infrastructure

## Choose the test level

Run non-live validation without AWS mutation:

```bash
make check ENGINE=tofu
make check ENGINE=terraform
make security
```

For live tests, first read [references/acceptance-runbook.md](references/acceptance-runbook.md) and [references/cleanup-inventory.md](references/cleanup-inventory.md). Live tests are billable and require explicit account, region, run ID, engine, and cost authorization.

```bash
.agents/skills/test-unrealops-infrastructure/scripts/run-acceptance.sh \
  --engine tofu \
  --account-id 123456789012 \
  --region us-west-2 \
  --run-id tofu-12345 \
  --confirm-billable
```

To include the full Lore foundation, workload, TLS/QUIC, binary push/clone,
deduplication, distributed-lock, tier-failover, AWS recovery, and default
service-account credential-boundary checks, publish the
pinned image to a stable repository in the same private ECR registry and add
both opt-in arguments:

```bash
.agents/skills/test-unrealops-infrastructure/scripts/run-acceptance.sh \
  --engine tofu \
  --account-id 123456789012 \
  --region us-west-2 \
  --run-id lore-12345 \
  --lore-image 123456789012.dkr.ecr.us-west-2.amazonaws.com/lore-acceptance@sha256:<digest> \
  --lore-client /absolute/path/to/lore \
  --confirm-billable
```

The Lore client must be v0.8.5 from the pinned source. The test validates that
the immutable source digest belongs to the authorized account and region and
that its ECR manifest contains both supported Linux architectures, then deploys
that digest directly. The wrapper also creates a separate encrypted Lore CA and
deterministic runtime secret, passes the CA to the client without changing the
host trust store, and includes that secret in the guarded cleanup audit.
Omitting the two Lore arguments leaves the existing acceptance stack unchanged.

On macOS, add `--openvpn-connect-cli "/Applications/OpenVPN Connect/OpenVPN Connect.app/Contents/MacOS/OpenVPN Connect"` when the unprivileged OpenVPN binary cannot create `utun`. This fallback was validated with OpenVPN Connect 3.6.0 and accepts version 3.6 or newer in the 3.x line; use a current 3.x release. It refuses to run while an app session already exists, imports one uniquely named temporary profile, launches the app minimized and waits for its warm process, then connects that exact profile with `--connect-shortcut=<id>`; it never changes the global `launch-options` setting. Cleanup disconnects the shortcut, quits and waits for the app, and removes only the exact imported profile ID. Keep OpenVPN Connect closed for the whole test.

## Protect cleanup

- Never default or infer the account or region. Compare STS with the supplied account before any mutation and pass the region to every AWS call.
- Do not run concurrently. Terratest writes directly to five repository roots; use an isolated checkout or worktree. The wrapper refuses nonempty state, configured backends, overrides, local tfvars, non-default workspaces, cached nonlocal backend metadata, and inherited Terraform input/CLI controls.
- Let `go test` finish after an assertion failure so deferred destroys can execute. Do not impose an external timeout.
- Preserve state, test PKI, profiles, and runtime secrets after an interrupted or incomplete destroy. Replacement VPN instances may still require the secrets.
- Destroy Karpenter workloads, add-ons, foundation, standalone OpenVPN, standalone network, and the standalone account-bootstrap fixture. Delete external secrets only after all five states are empty and exact run-owned Auto Scaling groups and active EC2 instances are absent. Missing KMS evidence prevents a passing final audit, but must not retain secrets after those consumption checks prove them safe to remove.

Always finish with the read-only audit, supplying exact nonstandard secret names or a captured KMS key when needed:

```bash
.agents/skills/test-unrealops-infrastructure/scripts/audit-acceptance-cleanup.sh \
  --account-id 123456789012 \
  --region us-west-2 \
  --run-id tofu-12345 \
  --manifest /tmp/unrealops-acceptance-tofu-12345/run-manifest.json
```

A pass requires empty managed-resource state, no active test-owned AWS resources, and run-linked evidence for the EKS encryption key. Prefer the generated manifest; a direct key ID is accepted only while the key retains an exact run ownership tag. Report a disabled key in `PendingDeletion` separately; its alias must be absent. Never inspect or modify another region during cleanup.
