# Acceptance Test Runbook

## What the suite proves

- `TestCompleteStack` deploys the full foundation, checks the pinned EKS/AMI/add-on set and private-only API, enters through a real OpenVPN tunnel, installs Karpenter, provisions a workload node, and waits for consolidation.
- With `--lore-image` and `--lore-client`, `TestCompleteStack` also enables the Lore foundation and add-ons, verifies ECR/S3/DynamoDB/Route 53 controls, validates private DNS and trusted TLS, exercises QUIC through the pinned Lore client, pushes and clones a binary tree, checks deduplicated S3 growth and shared locks, disrupts both workload tiers, verifies durable cache reconstruction, exercises S3 version recovery and DynamoDB PITR, and proves the default service account has no usable AWS workload credentials.
- `TestNetwork` checks the three-AZ subnet layout, three NAT gateways, routing, and VPN prefix list.
- `TestOpenVPNFailoverAndRevocation` checks TLS, IMDSv2, encrypted disk, no SSH ingress, SSM health, instance replacement, stable EIP recovery, CRL rejection, and a healthy control client.
- Contract tests check the supported layout, local EKS wrapper wiring, add-ons discovery, and Karpenter tags.

The complete run is serialized and can take more than an hour. It creates billable resources. Use a dedicated account and do not add an external timeout.

## Preconditions

The wrapper requires `aws`, OpenTofu or Terraform, Go, kubectl, OpenVPN, `curl`, `jq`, OpenSSL, `tar`, and a SHA-256 utility. The run ID must be at most 16 characters, lowercase alphanumeric/hyphen, and cannot start or end with a hyphen.

Lore acceptance is explicitly opt-in and additionally requires `crane`, an
executable Lore v0.8.5 client built from commit
`2d86d1dda98bfc1575ac7a20a6ff8c7fbc760383`, and a prepublished immutable image
in a stable repository within the authorized account and region's private ECR
registry. Pass the client and source image with `--lore-client` and
`--lore-image`. After foundation creates the run-specific ECR repository, the
test mirrors and verifies both image platforms before applying add-ons. The
wrapper creates the separate Lore CA and runtime secret only when both
arguments are supplied.

The wrapper refuses a pre-existing Terraform state in:

```text
terraform/examples/complete/foundation
terraform/examples/complete/addons
terraform/tests/fixtures/network
terraform/tests/fixtures/openvpn
```

Terratest directly uses these local roots. Never work around this guard by deleting or renaming a state file.

Run from an isolated checkout or worktree. The wrapper refuses configured backends, override files, local tfvars, non-default workspaces, cached nonlocal backend metadata, and inherited `TF_VAR_*`, `TF_WORKSPACE`, `TF_DATA_DIR`, or `TF_CLI_ARGS*` variables. This prevents a durable studio backend or operator input from being loaded by acceptance tests. Move operator files out of the test checkout; never have the wrapper delete them.

## PKI and environment contract

Each run atomically reserves two uniquely named Secrets Manager bundles before creating two isolated PKIs, preventing another runner from reusing the same run ID:

```text
acc-<run-id>             revoked-user, control-user
acc-<run-id>-complete    complete-user
```

Use separate `EASYRSA_PASSIN` and `EASYRSA_PASSOUT` files containing the same random value. Reusing one file path can fail with OpenSSL 3 because pass-output processing may consume or replace the pass-input file. The observed working random command is `openssl rand -out <file> -hex 32`.

Terratest consumes:

```text
TF_ACC=1
TERRAFORM_BINARY
AWS_REGION
AWS_DEFAULT_REGION
TEST_AWS_ACCOUNT_ID
TEST_RUN_ID
OPENVPN_PKI_ROOT
EASYRSA_BATCH=1
EASYRSA_PASSIN
EASYRSA_PASSOUT
TEST_OPENVPN_PKI_ENV
TEST_OPENVPN_CLIENT_NAME
TEST_OPENVPN_RUNTIME_SECRET_ARN
TEST_OPENVPN_PROFILE
TEST_OPENVPN_CONTROL_PROFILE
TEST_COMPLETE_OPENVPN_RUNTIME_SECRET_ARN
TEST_COMPLETE_OPENVPN_PROFILE
TEST_OPENVPN_CONNECT_CLI (optional macOS path)
TEST_LORE_IMAGE (set by the wrapper when Lore acceptance is enabled)
TEST_LORE_RUNTIME_SECRET_NAME (set by the wrapper)
TEST_LORE_CA_FILE (set by the wrapper)
TEST_LORE_CLIENT (set by the wrapper)
```

`make test-live ENGINE=<engine>` runs `go test ./terraform/tests -count=1 -p 1 -parallel 1 -v -timeout 0`.

The optional macOS fallback was validated with OpenVPN Connect 3.6.0 and accepts version 3.6 or newer in the 3.x line; use a current 3.x release. It refuses a pre-existing OpenVPN Connect app session, imports one uniquely named temporary profile, launches the app minimized, waits for the warm IPC host, and connects the exact imported profile with `--connect-shortcut=<id>`. A cold shortcut process is insufficient because its host exits and removes the tunnel. The test does not mutate the global `launch-options` setting or other app settings. Cleanup disconnects the shortcut, quits and waits for the app, then removes only the exact temporary profile ID. Keep OpenVPN Connect closed for the entire acceptance test.

## Failure handling

An ordinary assertion failure still runs registered Terratest destroys. Wait for the process to exit. If it is interrupted or a destroy fails, preserve the work directory and all four states. The wrapper writes the account, region, engine, run ID, secret ARNs, and PKI root to `run-manifest.json`. As soon as the EKS key is observable, it also records a run-owned `cleanup_evidence.eks_kms_key` marker. Recover only from that manifest. If failure occurs before KMS evidence exists, the wrapper still removes the exact runtime secrets once all state, run-owned Auto Scaling groups, and active instances are proven absent; its audit continues but cannot pass without KMS cleanup evidence.

```bash
set -euo pipefail
export WORK_DIR=/tmp/unrealops-acceptance-<run-id>
export MANIFEST="$WORK_DIR/run-manifest.json"
ENGINE="$(jq -er .engine "$MANIFEST")"
AWS_REGION="$(jq -er .region "$MANIFEST")"
export AWS_DEFAULT_REGION="$AWS_REGION"
EXPECTED_ACCOUNT_ID="$(jq -er .account_id "$MANIFEST")"
RUN_ID="$(jq -er .run_id "$MANIFEST")"
SECRET_ARN="$(jq -er .secret_arn "$MANIFEST")"
COMPLETE_SECRET_ARN="$(jq -er .complete_secret_arn "$MANIFEST")"
export E2E_NAME="unrealops-e2e-$RUN_ID"
export VPN_NAME="unrealops-vpn-$RUN_ID"
export NETWORK_NAME="unrealops-network-$RUN_ID"
ROOT="$(pwd)"
export ENGINE AWS_REGION EXPECTED_ACCOUNT_ID RUN_ID SECRET_ARN COMPLETE_SECRET_ARN ROOT
export FOUNDATION=terraform/examples/complete/foundation
export ADDONS=terraform/examples/complete/addons
export VPN_FIXTURE=terraform/tests/fixtures/openvpn
export NETWORK_FIXTURE=terraform/tests/fixtures/network
export AUDIT_SCRIPT=.agents/skills/test-unrealops-infrastructure/scripts/audit-acceptance-cleanup.sh

assert_account_scope() {
  test "$(aws sts get-caller-identity --region "$AWS_REGION" --query Account --output text)" = \
    "$EXPECTED_ACCOUNT_ID"
}
recovery_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}
assert_account_scope
```

The final cleanup audit requires this manifest marker. For older interrupted runs without it, pass the exact KMS key using `--kms-key-id`; the auditor will accept it only if KMS still reports an exact EKS-run ownership tag. Never substitute an unrelated key that happens to be pending deletion.

Before any further destroy, recover an older run's exact key from the acceptance marker, Terraform output, or preserved state and backfill the same structured manifest evidence written by the wrapper. If none of those run-owned sources has an ARN, stop; KMS evidence cannot be guessed.

```bash
KMS_KEY_ARN="$(jq -r '.cleanup_evidence.eks_kms_key.arn // empty' "$MANIFEST")"
if test -z "$KMS_KEY_ARN"; then
  KMS_KEY_ARN="$(sed -n 's/^.*UNREALOPS_ACCEPTANCE_KMS_KEY_ARN=//p' \
    "$WORK_DIR/acceptance.log" 2>/dev/null | tail -1 | tr -d '\r')"
fi
if test -z "$KMS_KEY_ARN"; then
  KMS_KEY_ARN="$("$ENGINE" -chdir="$FOUNDATION" output -raw cluster_kms_key_arn 2>/dev/null || true)"
fi
if test -z "$KMS_KEY_ARN" && test -f "$FOUNDATION/terraform.tfstate"; then
  KMS_KEY_ARN="$(jq -r '
    first(
      .resources[]?
      | select(.mode == "managed" and .type == "aws_kms_key")
      | .instances[]?.attributes.arn
      | select(. != null and . != "")
    ) // empty
  ' "$FOUNDATION/terraform.tfstate")"
fi
test -n "$KMS_KEY_ARN" ||
  recovery_die "Exact run-owned EKS KMS evidence is unavailable; preserve state and stop."
case "$KMS_KEY_ARN" in
  arn:*:kms:"$AWS_REGION":"$EXPECTED_ACCOUNT_ID":key/*) ;;
  *) recovery_die "Refusing out-of-scope KMS evidence: $KMS_KEY_ARN" ;;
esac
MANIFEST_TMP="$(mktemp "$MANIFEST.tmp.XXXXXX")"
jq --arg kms_key_arn "$KMS_KEY_ARN" '
  del(.kms_key_arn)
  | .cleanup_evidence.eks_kms_key = {
      arn: $kms_key_arn,
      owner_type: "eks-cluster",
      owner_name: .names.e2e,
      captured_from: "terraform-output:cluster_kms_key_arn"
    }
' "$MANIFEST" >"$MANIFEST_TMP"
mv "$MANIFEST_TMP" "$MANIFEST"
```

Define the state helper once:

```bash
managed_resource_count() {
  local state_file="$1/terraform.tfstate"
  test -f "$state_file" || { echo 0; return; }
  jq '[.resources[]? | select(.mode == "managed")] | length' "$state_file"
}
```

Determine whether the private cluster still exists. If it does, require a working exact OpenVPN ASG before touching Kubernetes. A partial foundation destroy can remove OpenVPN while leaving EKS; in that case create and inspect a targeted recovery plan. Apply it only when every changing resource address belongs to `module.openvpn`. If the plan needs to recreate networking too, stop and preserve state rather than broadening recovery implicitly.

```bash
assert_account_scope
CLUSTER_ERROR="$(mktemp)"
if aws eks describe-cluster --region "$AWS_REGION" --name "$E2E_NAME" >/dev/null 2>"$CLUSTER_ERROR"; then
  CLUSTER_EXISTS=true
elif grep -q ResourceNotFoundException "$CLUSTER_ERROR"; then
  CLUSTER_EXISTS=false
else
  cat "$CLUSTER_ERROR" >&2
  rm -f "$CLUSTER_ERROR"
  recovery_die "Could not determine whether the exact EKS cluster exists."
fi
rm -f "$CLUSTER_ERROR"
export CLUSTER_EXISTS

if test "$CLUSTER_EXISTS" = false && test "$(managed_resource_count "$ADDONS")" != 0; then
  recovery_die "EKS is absent while add-ons state is nonempty; preserve state for state-aware recovery."
fi

if test "$CLUSTER_EXISTS" = true; then
  OPENVPN_ASG="$E2E_NAME-openvpn"
  OPENVPN_ASG_COUNT="$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" \
    --auto-scaling-group-names "$OPENVPN_ASG" \
    --query 'length(AutoScalingGroups)' --output text)"
  OPENVPN_ADDRESS_COUNT="$(aws ec2 describe-addresses --region "$AWS_REGION" --filters \
    'Name=tag:Module,Values=openvpn' "Name=tag:Name,Values=$OPENVPN_ASG" \
    --query 'length(Addresses)' --output text)"
  ENDPOINT="$(aws ec2 describe-addresses --region "$AWS_REGION" --filters \
    'Name=tag:Module,Values=openvpn' "Name=tag:Name,Values=$OPENVPN_ASG" \
    --query 'Addresses[0].PublicIp' --output text | sed '/^None$/d')"

  if test "$OPENVPN_ASG_COUNT" != 1 || test "$OPENVPN_ADDRESS_COUNT" != 1 || test -z "$ENDPOINT"; then
    assert_account_scope
    "$ENGINE" -chdir="$FOUNDATION" init -input=false
    RECOVERY_PLAN="$WORK_DIR/recover-openvpn.tfplan"
    "$ENGINE" -chdir="$FOUNDATION" plan -input=false -out="$RECOVERY_PLAN" \
      -target=module.openvpn \
      -var="aws_region=$AWS_REGION" \
      -var="name=$E2E_NAME" \
      -var="openvpn_runtime_secret_arn=$COMPLETE_SECRET_ARN"
    "$ENGINE" -chdir="$FOUNDATION" show -json "$RECOVERY_PLAN" | jq -e '
      [
        .resource_changes[]?
        | select(.change.actions != ["no-op"] and .change.actions != ["read"])
        | .address
      ] as $changes
      | ($changes | length) > 0
      and all($changes[]; startswith("module.openvpn."))
    ' >/dev/null || {
      recovery_die "OpenVPN recovery plan changes resources outside module.openvpn; do not apply it."
    }
    assert_account_scope
    "$ENGINE" -chdir="$FOUNDATION" apply -input=false "$RECOVERY_PLAN"
    OPENVPN_ASG_COUNT="$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" \
      --auto-scaling-group-names "$OPENVPN_ASG" \
      --query 'length(AutoScalingGroups)' --output text)"
    test "$OPENVPN_ASG_COUNT" = 1
    OPENVPN_ADDRESS_COUNT="$(aws ec2 describe-addresses --region "$AWS_REGION" --filters \
      'Name=tag:Module,Values=openvpn' "Name=tag:Name,Values=$OPENVPN_ASG" \
      --query 'length(Addresses)' --output text)"
    test "$OPENVPN_ADDRESS_COUNT" = 1
    ENDPOINT="$(aws ec2 describe-addresses --region "$AWS_REGION" --filters \
      'Name=tag:Module,Values=openvpn' "Name=tag:Name,Values=$OPENVPN_ASG" \
      --query 'Addresses[0].PublicIp' --output text | sed '/^None$/d')"
    test -n "$ENDPOINT"
  fi

  OPENVPN_DEADLINE=$((SECONDS + 900))
  while :; do
    # shellcheck disable=SC2016 # JMESPath requires literal backticks.
    OPENVPN_INSERVICE="$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" \
      --auto-scaling-group-names "$OPENVPN_ASG" \
      --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`])' --output text)"
    test "$OPENVPN_INSERVICE" = 1 && break
    if ((SECONDS >= OPENVPN_DEADLINE)); then
      recovery_die "Recovered OpenVPN ASG has no InService instance; preserve state and stop."
    fi
    sleep 15
  done
  export ENDPOINT
  printf '%s\n' "$ENDPOINT" >"$WORK_DIR/recovery-openvpn-endpoint"
fi
```

When `CLUSTER_EXISTS=true`, reconnect before touching Kubernetes. In a dedicated terminal, load the manifest variables again, remove every preserved `remote` line just as the live test does, and run the open-source client. macOS may require `sudo` for `utun` creation.

```bash
ENDPOINT="$(<"$WORK_DIR/recovery-openvpn-endpoint")"
RECOVERY_PROFILE="$WORK_DIR/recovery-complete-user.ovpn"
awk 'NF == 0 || $1 != "remote"' \
  "$WORK_DIR/pki/acc-$RUN_ID-complete/profiles/complete-user.ovpn" >"$RECOVERY_PROFILE"
chmod 0600 "$RECOVERY_PROFILE"
sudo openvpn --config "$RECOVERY_PROFILE" --remote "$ENDPOINT" 1194 --auth-nocache
```

In the main terminal, create a temporary kubeconfig, delete only the labeled acceptance workload and NodeClaims, and wait until both NodeClaims and nodes disappear. Do not continue to the add-ons destroy on timeout.

```bash
if test "$CLUSTER_EXISTS" = true; then
  assert_account_scope
  export KUBECONFIG="$WORK_DIR/recovery-kubeconfig"
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$E2E_NAME" --kubeconfig "$KUBECONFIG"
  kubectl delete deployment karpenter-acceptance --ignore-not-found=true --wait=true
  KARPENTER_SELECTOR='unrealops.io/capacity-provider=karpenter'
  KARPENTER_NODECLAIMS_AVAILABLE=false
  if kubectl api-resources --api-group=karpenter.sh -o name | \
    grep -Eq '^nodeclaims(\.karpenter\.sh)?$'; then
    KARPENTER_NODECLAIMS_AVAILABLE=true
    kubectl delete nodeclaims.karpenter.sh -l "$KARPENTER_SELECTOR" \
      --ignore-not-found=true --wait=false
  fi

  KARPENTER_DEADLINE=$((SECONDS + 600))
  while :; do
    KARPENTER_NODES="$(kubectl get nodes -l "$KARPENTER_SELECTOR" -o name)"
    KARPENTER_CLAIMS=""
    if test "$KARPENTER_NODECLAIMS_AVAILABLE" = true; then
      KARPENTER_CLAIMS="$(kubectl get nodeclaims.karpenter.sh -l "$KARPENTER_SELECTOR" -o name)"
    fi
    if test -z "$KARPENTER_NODES" && test -z "$KARPENTER_CLAIMS"; then
      break
    fi
    if ((SECONDS >= KARPENTER_DEADLINE)); then
      recovery_die "Karpenter cleanup timed out; preserve state and keep the VPN connected."
    fi
    sleep 15
  done
fi
```

Destroy each nonempty root with explicit region and required variables, rechecking the account before every phase. Keep the VPN connected through the add-ons destroy, then disconnect it before foundation cleanup.

```bash
if test "$(managed_resource_count "$ADDONS")" != 0; then
  assert_account_scope
  "$ENGINE" -chdir="$ADDONS" init -input=false
  "$ENGINE" -chdir="$ADDONS" destroy -input=false -auto-approve \
    -var="aws_region=$AWS_REGION" \
    -var="cluster_name=$E2E_NAME"
fi

# Stop the OpenVPN process in the other terminal now.
if test "$(managed_resource_count "$FOUNDATION")" != 0; then
  assert_account_scope
  "$ENGINE" -chdir="$FOUNDATION" init -input=false
  "$ENGINE" -chdir="$FOUNDATION" destroy -input=false -auto-approve \
    -var="aws_region=$AWS_REGION" \
    -var="name=$E2E_NAME" \
    -var="openvpn_runtime_secret_arn=$COMPLETE_SECRET_ARN" \
    -var="deletion_protection=false"
fi

if test "$(managed_resource_count "$VPN_FIXTURE")" != 0; then
  assert_account_scope
  "$ENGINE" -chdir="$VPN_FIXTURE" init -input=false
  "$ENGINE" -chdir="$VPN_FIXTURE" destroy -input=false -auto-approve \
    -var="region=$AWS_REGION" -var="name=$VPN_NAME" \
    -var="runtime_secret_arn=$SECRET_ARN"
fi

if test "$(managed_resource_count "$NETWORK_FIXTURE")" != 0; then
  assert_account_scope
  "$ENGINE" -chdir="$NETWORK_FIXTURE" init -input=false
  "$ENGINE" -chdir="$NETWORK_FIXTURE" destroy -input=false -auto-approve \
    -var="region=$AWS_REGION" -var="name=$NETWORK_NAME"
fi
```

If any destroy remains incomplete, skip secret deletion, run a zero-wait read-only audit immediately, and preserve its findings with the state and PKI. The audit is expected to report the still-active runtime secrets as well as any infrastructure remnants.

```bash
DESTROYS_COMPLETE=true
for STATE_ROOT in "$FOUNDATION" "$ADDONS" "$VPN_FIXTURE" "$NETWORK_FIXTURE"; do
  if test -f "$STATE_ROOT/.terraform.tfstate.lock.info" || \
    test "$(managed_resource_count "$STATE_ROOT")" != 0; then
    DESTROYS_COMPLETE=false
  fi
done
if test "$DESTROYS_COMPLETE" != true; then
  set +e
  "$AUDIT_SCRIPT" --account-id "$EXPECTED_ACCOUNT_ID" --region "$AWS_REGION" \
    --run-id "$RUN_ID" --manifest "$MANIFEST" \
    --secret-id "$SECRET_ARN" --secret-id "$COMPLETE_SECRET_ARN" --wait-seconds 0
  RECOVERY_AUDIT_STATUS=$?
  set -e
  recovery_die \
    "A destroy remains incomplete (audit exit $RECOVERY_AUDIT_STATUS); preserve state, manifest, logs, and PKI."
fi
```

After every destroy succeeds, require every managed state and lock to be gone, then wait up to 15 minutes for exact run-owned ASGs and active instances. The OpenVPN instance check requires `Module=openvpn` and an exact run Name as a conjunction.

```bash
for STATE_ROOT in "$FOUNDATION" "$ADDONS" "$VPN_FIXTURE" "$NETWORK_FIXTURE"; do
  test ! -f "$STATE_ROOT/.terraform.tfstate.lock.info"
  test "$(managed_resource_count "$STATE_ROOT")" = 0
done

COMPUTE_DEADLINE=$((SECONDS + 900))
while :; do
  assert_account_scope
  OWNED_ASGS="$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" --output json | jq -r \
    --arg e2e "$E2E_NAME" --arg network "$NETWORK_NAME" --arg vpn "$VPN_NAME" \
    --arg e2e_openvpn "$E2E_NAME-openvpn" --arg vpn_openvpn "$VPN_NAME-openvpn" '
      .AutoScalingGroups[]
      | select(
          .AutoScalingGroupName == $e2e_openvpn or
          .AutoScalingGroupName == $vpn_openvpn or
          (any(.Tags[]?; .Key == "Module" and .Value == "openvpn") and
           any(.Tags[]?; .Key == "Name" and (.Value == $e2e_openvpn or .Value == $vpn_openvpn))) or
          any(.Tags[]?;
            (.Key == "Environment" and .Value == $e2e) or
            (.Key == "Test" and (.Value == $network or .Value == $vpn)) or
            (.Key == "ClusterName" and .Value == $e2e) or
            (.Key == "eks:cluster-name" and .Value == $e2e) or
            (.Key == "eks:nodegroup-name" and .Value == ($e2e + "-system")) or
            (.Key == ("kubernetes.io/cluster/" + $e2e)) or
            (.Key == "karpenter.sh/discovery" and .Value == $e2e))
        )
      | .AutoScalingGroupName
    ')"
  OWNED_INSTANCES="$(aws ec2 describe-instances --region "$AWS_REGION" --output json | jq -r \
    --arg e2e "$E2E_NAME" --arg network "$NETWORK_NAME" --arg vpn "$VPN_NAME" \
    --arg e2e_openvpn "$E2E_NAME-openvpn" --arg vpn_openvpn "$VPN_NAME-openvpn" '
      .Reservations[].Instances[]
      | select(.State.Name != "terminated")
      | select(
          (any(.Tags[]?; .Key == "Module" and .Value == "openvpn") and
           any(.Tags[]?; .Key == "Name" and (.Value == $e2e_openvpn or .Value == $vpn_openvpn))) or
          any(.Tags[]?;
            (.Key == "Environment" and .Value == $e2e) or
            (.Key == "Test" and (.Value == $network or .Value == $vpn)) or
            (.Key == "ClusterName" and .Value == $e2e) or
            (.Key == "eks:cluster-name" and .Value == $e2e) or
            (.Key == "eks:nodegroup-name" and .Value == ($e2e + "-system")) or
            (.Key == ("kubernetes.io/cluster/" + $e2e)) or
            (.Key == "karpenter.sh/discovery" and .Value == $e2e))
        )
      | .InstanceId
    ')"
  if test -z "$OWNED_ASGS" && test -z "$OWNED_INSTANCES"; then
    break
  fi
  if ((SECONDS >= COMPUTE_DEADLINE)); then
    printf 'Run-owned compute still exists. ASGs=%s instances=%s\n' \
      "$OWNED_ASGS" "$OWNED_INSTANCES" >&2
    recovery_die "Run-owned compute cleanup timed out; preserve secrets and state."
  fi
  sleep 15
done
```

Only after those proofs succeed, delete the two manifest-owned runtime secrets and wait until Secrets Manager reports each exact ARN absent or with a deletion date. A failed or unknown API response is not a terminal state.

```bash
secret_terminal() {
  local secret_id="$1" error_file output
  error_file="$(mktemp)"
  if output="$(aws secretsmanager describe-secret --region "$AWS_REGION" \
    --secret-id "$secret_id" 2>"$error_file")"; then
    rm -f "$error_file"
    test -n "$(jq -r '.DeletedDate // empty' <<<"$output")"
    return
  fi
  if grep -q ResourceNotFoundException "$error_file"; then
    rm -f "$error_file"
    return 0
  fi
  cat "$error_file" >&2
  rm -f "$error_file"
  return 1
}

for SECRET_ID in "$SECRET_ARN" "$COMPLETE_SECRET_ARN"; do
  assert_account_scope
  if ! secret_terminal "$SECRET_ID"; then
    aws secretsmanager delete-secret --region "$AWS_REGION" --secret-id "$SECRET_ID" \
      --force-delete-without-recovery >/dev/null
  fi
  SECRET_DEADLINE=$((SECONDS + 600))
  until secret_terminal "$SECRET_ID"; do
    if ((SECONDS >= SECRET_DEADLINE)); then
      recovery_die "Runtime secret still exists after deletion request: $SECRET_ID"
    fi
    sleep 10
  done
done
```

Run the read-only audit even when a destroy remains incomplete. Never issue broad prefix-based deletion when state is lost; use exact names, ownership tags, and IDs from state, `run-manifest.json`, and `acceptance.log`. Remove the preserved PKI only after this final audit passes and its evidence has been retained.

```bash
.agents/skills/test-unrealops-infrastructure/scripts/audit-acceptance-cleanup.sh \
  --account-id "$EXPECTED_ACCOUNT_ID" --region "$AWS_REGION" --run-id "$RUN_ID" \
  --manifest "$MANIFEST" --wait-seconds 900
```
