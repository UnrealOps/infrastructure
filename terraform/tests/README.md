# Acceptance tests

With `TF_ACC` unset, `go test ./...` runs contract tests and skips live tests. Prefer the repository test skill for a billable run because it verifies the account, prepares isolated PKIs, serializes Terratest, preserves recovery material on failure, removes external secrets when safe, and performs an independent cleanup audit. Its wrapper requires AWS CLI v2, OpenTofu or Terraform, Go, kubectl, OpenVPN, GNU Make, TFLint, Trivy, `curl`, `jq`, OpenSSL, `tar`, and a SHA-256 utility:

```bash
.agents/skills/test-unrealops-infrastructure/scripts/run-acceptance.sh \
  --engine tofu \
  --account-id 123456789012 \
  --region us-west-2 \
  --run-id tofu-12345 \
  --confirm-billable
```

On macOS, pass `--openvpn-connect-cli "/Applications/OpenVPN Connect/OpenVPN Connect.app/Contents/MacOS/OpenVPN Connect"` when an unprivileged `openvpn` process cannot create a `utun` interface. The fallback was validated with OpenVPN Connect 3.6.0 and accepts version 3.6 or newer in the 3.x line; use a current 3.x release. Close OpenVPN Connect before starting and do not interact with it during the run. The test imports one uniquely named temporary profile, starts the app minimized, waits for the warm IPC host, and sends `--connect-shortcut=<id>` for that exact profile. It does not mutate `launch-options` or another global setting. Cleanup disconnects the shortcut, quits and waits for the app, then removes only the imported profile ID.

For advanced/manual invocation, the suite requires `TF_ACC=1`, `AWS_REGION`, `AWS_DEFAULT_REGION`, `TEST_AWS_ACCOUNT_ID`, and a unique `TEST_RUN_ID` of at most 16 lowercase alphanumeric/hyphen characters. It also requires separate revocation and complete-stack runtime secret/profile variables documented in `.agents/skills/test-unrealops-infrastructure/references/acceptance-runbook.md`. Use distinct `EASYRSA_PASSIN` and `EASYRSA_PASSOUT` files even when they contain the same passphrase.

Use a dedicated account with quotas for three NAT gateways, EKS, EC2, IAM, KMS, and EIPs. A full run is intentionally scheduled or manual because it is billable and can take more than an hour. Tests register destroy cleanup before apply, but deferred destroys are not proof of cleanup.

After an interrupted or failed run, preserve state, PKI, profiles, and runtime secrets until OpenVPN replacements and private-cluster cleanup are complete. Follow the skill's cleanup inventory, then run its read-only audit against only the authorized account and region. The failover test permanently revokes its test client; never use a production PKI.

`.github/workflows/acceptance.yml` runs both engines monthly or on demand through OIDC. Configure `AWS_ACCEPTANCE_ROLE_ARN`, `AWS_ACCEPTANCE_ACCOUNT_ID`, and optionally `AWS_REGION`. Protect the `acceptance-tofu` and `acceptance-terraform` environments when manual approval is required.
