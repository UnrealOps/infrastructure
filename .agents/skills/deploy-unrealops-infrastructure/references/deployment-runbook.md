# Complete Deployment Runbook

## Scope and prerequisites

This repository supports only `account-bootstrap`, `network`, `openvpn`, `eks`, `karpenter-infra`, and `cluster-addons`, plus the opt-in Lore extension. Do not extend or deploy archived stacks.

Install OpenTofu or Terraform within the roots' declared version constraint, plus AWS CLI v2, kubectl, OpenVPN, Go, `curl`, `jq`, OpenSSL, `tar`, and `sha256sum` or `shasum`. Homebrew may install OpenVPN in `/usr/local/sbin` or `/opt/homebrew/sbin`; add that directory to `PATH`.

Durable environments require all of the following:

- Separate encrypted, locked remote state for the account-bootstrap, foundation, and add-ons roots.
- `deletion_protection = true`.
- A user-confirmed unique lowercase environment name and non-overlapping VPC CIDR.
- Restricted `openvpn_ingress_cidrs` when operators have stable source addresses.
- At least one durable `admin_principal_arns` entry produced by account bootstrap or an equivalently managed external IAM role.
- An approved encrypted operations store for the inputs and recovery metadata listed under [Retain the durable handoff](#retain-the-durable-handoff).

The checked-in local-state configuration is only for evaluation and acceptance testing.

## Preflight

Set explicit values; never infer the account or region from an AWS profile:

```bash
export AWS_REGION="REPLACE_WITH_CONFIRMED_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
export EXPECTED_ACCOUNT_ID="REPLACE_WITH_12_DIGIT_ACCOUNT_ID"
export ENGINE=tofu
export ENVIRONMENT="REPLACE_WITH_CONFIRMED_UNIQUE_NAME"

assert_account() {
  local actual_account
  if [[ ! "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ||
    "$AWS_REGION" == "REPLACE_WITH_CONFIRMED_REGION" ]]; then
    printf 'Set the confirmed AWS account ID and region first\n' >&2
    return 1
  fi
  actual_account="$(aws sts get-caller-identity --region "$AWS_REGION" \
    --query Account --output text)" || return
  if [[ "$actual_account" != "$EXPECTED_ACCOUNT_ID" ]]; then
    printf 'Refusing AWS account %s; expected %s\n' \
      "$actual_account" "$EXPECTED_ACCOUNT_ID" >&2
    return 1
  fi
}

assert_durable_admin_identity() {
  local allowed_principals_json="$1" identity_json
  identity_json="$(aws sts get-caller-identity --region "$AWS_REGION" \
    --output json)" || return
  jq -e --arg account "$EXPECTED_ACCOUNT_ID" \
    --argjson allowed "$allowed_principals_json" '
      .Account as $actual_account
      | .Arn as $caller
      | $actual_account == $account and any($allowed[];
          . == $caller or
          ((split(":")) as $allowed_arn
           | ($caller | split(":")) as $caller_arn
           | $allowed_arn[1] == $caller_arn[1] and
             $allowed_arn[4] == $caller_arn[4] and
             ($allowed_arn[5] | startswith("role/")) and
             $caller_arn[2] == "sts" and
             ($caller_arn[5] | startswith(
               "assumed-role/" +
               (($allowed_arn[5] | ltrimstr("role/")) | split("/") | last) +
               "/"))))
    ' <<<"$identity_json" >/dev/null
}

validate_foundation_plan() {
  local plan_name="$1" expected_deletion_protection="$2"
  local expected_creator_admin="$3" allow_planning_placeholder="$4"
  "$ENGINE" -chdir=terraform/examples/complete/foundation show \
    -json "$plan_name" | jq -e \
    --arg region "$AWS_REGION" \
    --arg account "$EXPECTED_ACCOUNT_ID" \
    --arg environment "$ENVIRONMENT" \
    --argjson deletion_protection "$expected_deletion_protection" \
    --argjson creator_admin "$expected_creator_admin" \
    --argjson allow_placeholder "$allow_planning_placeholder" '
      (.variables.openvpn_runtime_secret_arn.value | split(":")) as $secret
      | .variables.aws_region.value == $region and
      .variables.name.value == $environment and
      .variables.deletion_protection.value == $deletion_protection and
      .variables.enable_cluster_creator_admin_permissions.value == $creator_admin and
      (.variables.openvpn_ingress_cidrs.value | length > 0) and
      (.variables.admin_principal_arns.value | length > 0) and
      all(.variables.admin_principal_arns.value[];
        (split(":")) as $arn
        | $arn[2] == "iam" and $arn[4] == $account and
          ($arn[5] | test("^(role|user)/"))) and
      $secret[2] == "secretsmanager" and $secret[3] == $region and
        $secret[4] == $account and $secret[5] == "secret" and
        ($allow_placeholder or $secret[6] != "planning-only") and
      ((.variables.openvpn_route53_zone_id.value == null and
        .variables.openvpn_route53_record_name.value == null) or
       ((.variables.openvpn_route53_zone_id.value | type) == "string" and
        (.variables.openvpn_route53_zone_id.value | length) > 0 and
        (.variables.openvpn_route53_record_name.value | type) == "string" and
        (.variables.openvpn_route53_record_name.value | length) > 0))
    '
}

validate_addons_plan() {
  local plan_name="$1" require_cluster_data="${2:-true}"
  [[ "$require_cluster_data" == "true" ||
    "$require_cluster_data" == "false" ]]
  "$ENGINE" -chdir=terraform/examples/complete/addons show \
    -json "$plan_name" | jq -e --arg region "$AWS_REGION" \
    --arg environment "$ENVIRONMENT" \
    --argjson require_cluster_data "$require_cluster_data" '
      .variables.aws_region.value == $region and
      .variables.cluster_name.value == $environment and
      (($require_cluster_data | not) or
        ((
          [.planned_values.root_module.resources[]?
            | select(.address == "data.aws_eks_cluster.this")
            | .values.name] +
          [.prior_state.values.root_module.resources[]?
            | select(.address == "data.aws_eks_cluster.this")
            | .values.name]
        ) | unique) == [$environment])
    '
}

(
  set -euo pipefail
  assert_account
  make check ENGINE="$ENGINE"
  make security
)
```

Confirm at least three available AZs and sufficient quota for three NAT gateways, four EIPs, one EKS cluster, the OpenVPN instance, the configured system-node maximum plus replacement headroom, VPCs, KMS keys, and IAM resources. The system-node default is two `m6i.large` instances with `min = 2`, `desired = 2`, and `max = 3`, allowing default controller replicas to remain separated. This release was acceptance-tested in `us-west-2`; validate all pinned EKS, AMI, add-on, and Karpenter versions before using another region. Repository releases own those private source constants.

Before planning, obtain these choices rather than inventing them: environment name, VPC CIDR, VPN ingress CIDRs, the permanent IAM principals trusted to assume the administrator role, runtime secret ARN or plan-only placeholder, deletion protection, tags, and all three state backends. Inspect any existing state and confirm its lineage and environment with the operator.

## Configure durable state

Backend credentials must come from the normal AWS credential chain. Never place access keys, secret keys, session tokens, or other credentials in backend files, tfvars, shell arguments, or the repository.

Store three backend config files outside the repository in the studio's approved encrypted operations store. They must select different state keys. For example, an S3 account-bootstrap file may contain:

```hcl
bucket       = "studio-terraform-state"
key          = "unrealops/account-bootstrap.tfstate"
region       = "REPLACE_WITH_CONFIRMED_REGION"
encrypt      = true
use_lockfile = true
```

The foundation file uses its own key:

```hcl
bucket       = "studio-terraform-state"
key          = "unrealops/<environment>/foundation.tfstate"
region       = "REPLACE_WITH_CONFIRMED_REGION"
encrypt      = true
use_lockfile = true
```

The add-ons file uses the same durable backend with a distinct key:

```hcl
bucket       = "studio-terraform-state"
key          = "unrealops/<environment>/addons.tfstate"
region       = "REPLACE_WITH_CONFIRMED_REGION"
encrypt      = true
use_lockfile = true
```

Require bucket versioning and a policy that restricts state access. Then export absolute paths and restrict their permissions:

```bash
export BACKEND_TYPE=s3
export ACCOUNT_BOOTSTRAP_BACKEND_CONFIG=/secure/operations/unrealops-account-bootstrap.s3.tfbackend
export FOUNDATION_BACKEND_CONFIG=/secure/operations/unrealops-foundation.s3.tfbackend
export ADDONS_BACKEND_CONFIG=/secure/operations/unrealops-addons.s3.tfbackend

chmod 600 "$ACCOUNT_BOOTSTRAP_BACKEND_CONFIG" "$FOUNDATION_BACKEND_CONFIG" "$ADDONS_BACKEND_CONFIG"
```

Initialize account bootstrap first. Dependency lockfiles are generated locally and ignored:

```bash
ACCOUNT_BOOTSTRAP_STATE_PROVENANCE_ARGS=()
if [[ -n "${EXPECTED_ACCOUNT_BOOTSTRAP_STATE_LINEAGE:-}" ]]; then
  ACCOUNT_BOOTSTRAP_STATE_PROVENANCE_ARGS=(
    --expected-lineage "$EXPECTED_ACCOUNT_BOOTSTRAP_STATE_LINEAGE"
  )
elif [[ "${CONFIRM_NEW_ACCOUNT_BOOTSTRAP_STATE:-}" == "yes" ]]; then
  ACCOUNT_BOOTSTRAP_STATE_PROVENANCE_ARGS=(--allow-new-state)
else
  printf '%s\n' \
    'Recover EXPECTED_ACCOUNT_BOOTSTRAP_STATE_LINEAGE or set CONFIRM_NEW_ACCOUNT_BOOTSTRAP_STATE=yes after confirming this is a new access boundary.' >&2
  false
fi

.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh \
  --root account-bootstrap \
  --engine "$ENGINE" \
  --backend-type "$BACKEND_TYPE" \
  --backend-config "$ACCOUNT_BOOTSTRAP_BACKEND_CONFIG" \
  --peer-backend-config "$FOUNDATION_BACKEND_CONFIG" \
  --peer-backend-config "$ADDONS_BACKEND_CONFIG" \
  --environment "$ENVIRONMENT" \
  "${ACCOUNT_BOOTSTRAP_STATE_PROVENANCE_ARGS[@]}"
```

## Bootstrap durable EKS administrator identity

Copy `terraform/examples/account-bootstrap/terraform.tfvars.example`, set
`cluster_names = [ENVIRONMENT]`, and name the exact permanent IAM user or role
ARNs that may assume the role. Prefer an IAM Identity Center permission-set role.
An empty trust list resolves to the permanent issuer behind the applying
session; confirm that resolved ARN in the saved plan. With explicit
authorization to change IAM, save, inspect, and apply the bootstrap plan:

```bash
ACCOUNT_BOOTSTRAP_TFVARS=terraform/examples/account-bootstrap/terraform.tfvars
test -e "$ACCOUNT_BOOTSTRAP_TFVARS" ||
  cp terraform/examples/account-bootstrap/terraform.tfvars.example "$ACCOUNT_BOOTSTRAP_TFVARS"

ACCOUNT_BOOTSTRAP_PLAN=terraform/examples/account-bootstrap/account-bootstrap.tfplan
rm -f "$ACCOUNT_BOOTSTRAP_PLAN"
assert_account
"$ENGINE" -chdir=terraform/examples/account-bootstrap plan -out=account-bootstrap.tfplan
"$ENGINE" -chdir=terraform/examples/account-bootstrap show account-bootstrap.tfplan
assert_account
"$ENGINE" -chdir=terraform/examples/account-bootstrap apply account-bootstrap.tfplan
"$ENGINE" -chdir=terraform/examples/account-bootstrap output admin_principal_arns
```

Copy that output into the foundation's `admin_principal_arns`. The role is not
an infrastructure deployment role: its AWS policy only lists clusters and
describes the named clusters, while the foundation grants Kubernetes authority
through an EKS access entry.

Then initialize the foundation with its external backend config:

```bash
FOUNDATION_STATE_PROVENANCE_ARGS=()
if [[ -n "${EXPECTED_FOUNDATION_STATE_LINEAGE:-}" ]]; then
  FOUNDATION_STATE_PROVENANCE_ARGS=(
    --expected-lineage "$EXPECTED_FOUNDATION_STATE_LINEAGE"
  )
elif [[ "${CONFIRM_NEW_FOUNDATION_STATE:-}" == "yes" ]]; then
  FOUNDATION_STATE_PROVENANCE_ARGS=(--allow-new-state)
else
  printf '%s\n' \
    'Recover EXPECTED_FOUNDATION_STATE_LINEAGE or set CONFIRM_NEW_FOUNDATION_STATE=yes after confirming this is a new environment.' >&2
  false
fi

.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh \
  --root foundation \
  --engine "$ENGINE" \
  --backend-type "$BACKEND_TYPE" \
  --backend-config "$FOUNDATION_BACKEND_CONFIG" \
  --peer-backend-config "$ACCOUNT_BOOTSTRAP_BACKEND_CONFIG" \
  --peer-backend-config "$ADDONS_BACKEND_CONFIG" \
  --environment "$ENVIRONMENT" \
  "${FOUNDATION_STATE_PROVENANCE_ARGS[@]}"
```

The helper creates only an ignored `backend_override.tf`; it refuses backend config files inside the repository, files readable by group or other users, raw AWS credentials, unresolved placeholders, duplicate root/peer bucket-key pairs, and unexpected existing override files. It also refuses any existing state unless its retained lineage is supplied, validates the account-bootstrap IAM-only boundary, and requires a non-empty foundation state to expose `cluster_name = ENVIRONMENT`. Do not migrate, replace, or adopt a lineage merely to bypass that check.

## Plan without creating resources

Planning may query AWS data sources and briefly lock remote state, but it does not authorize `vpn-pki-init`, `apply`, or another billable write. Use an existing runtime secret ARN or construct a clearly labeled, syntactically valid placeholder from the confirmed values: `PLANNING_ONLY_SECRET_ARN="arn:aws:secretsmanager:${AWS_REGION}:${EXPECTED_ACCOUNT_ID}:secret:planning-only"`. The module does not read the secret during plan.

Prepare the foundation inputs and set every confirmed choice. For a durable environment, set `deletion_protection = true`, durable administrators, and the exact requested region:

```bash
FOUNDATION_TFVARS=terraform/examples/complete/foundation/terraform.tfvars
if [[ -e "$FOUNDATION_TFVARS" ]]; then
  printf 'Reusing %s; verify that it belongs to this environment\n' \
    "$FOUNDATION_TFVARS"
else
  cp terraform/examples/complete/foundation/terraform.tfvars.example \
    "$FOUNDATION_TFVARS"
fi
```

Stop and edit that file. Confirm the runtime secret or planning placeholder matches the authorized account and region, `name = ENVIRONMENT`, `deletion_protection = true`, at least one durable administrator ARN, the approved VPC/VPN CIDRs, optional Route 53 pair, and tags. Only after that review, set the gate and plan:

```bash
export FOUNDATION_INPUTS_CONFIRMED=yes

(
  set -euo pipefail
  test "$FOUNDATION_INPUTS_CONFIRMED" = "yes"
  PLAN_FILE=terraform/examples/complete/foundation/foundation.tfplan
  rm -f "$PLAN_FILE"
  trap 'rm -f "$PLAN_FILE"' EXIT
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/foundation plan \
    -var="aws_region=$AWS_REGION" \
    -var="name=$ENVIRONMENT" \
    -var="deletion_protection=true" \
    -var="enable_cluster_creator_admin_permissions=true" \
    -input=false -out=foundation.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/foundation show foundation.tfplan
  validate_foundation_plan foundation.tfplan true true true
  trap - EXIT
)
```

Stop there for a plan-only request. Do not apply a plan containing a placeholder secret ARN. Do not plan add-ons yet: that root needs a live foundation cluster in AWS (for data sources), a running private EKS API, and VPN connectivity. State both limitations in the result.

## Create the VPN identity material

Obtain explicit billable-resource authorization, then re-check the exact account immediately before creating or updating the runtime secret:

```bash
export PKI_SECRET_NAME="unrealops/$ENVIRONMENT/openvpn/runtime"

assert_account && make vpn-pki-init \
  ENV="$ENVIRONMENT" \
  AWS_REGION="$AWS_REGION" \
  PKI_SECRET_NAME="$PKI_SECRET_NAME"
```

The encrypted CA and client keys remain under `${OPENVPN_PKI_ROOT:-$HOME/.config/unrealops/pki}`. Back them up according to studio policy. Record the runtime secret ARN from `<pki-root>/<environment>/metadata.json`; Terraform does not own this secret. Replace any plan-only placeholder with that exact ARN and regenerate the foundation plan.

```bash
RUNTIME_SECRET_ARN="$(jq -er '.secret_id' \
  "${OPENVPN_PKI_ROOT:-$HOME/.config/unrealops/pki}/$ENVIRONMENT/metadata.json")" &&
  [[ "$RUNTIME_SECRET_ARN" == \
    arn:*:secretsmanager:"$AWS_REGION":"$EXPECTED_ACCOUNT_ID":secret:* ]] &&
  [[ "$RUNTIME_SECRET_ARN" != *:secret:planning-only ]] &&
  export RUNTIME_SECRET_ARN
```

## Deploy the foundation

Populate `terraform.tfvars` with the exact region, environment, VPC CIDR, runtime secret ARN, ingress CIDRs, durable administrator ARNs, deletion protection, and tags. Keep `enable_cluster_creator_admin_permissions = true` only for bootstrap.

Re-run the backend helper if this is a new checkout, then save and inspect a fresh plan:

```bash
.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh \
  --root foundation \
  --engine "$ENGINE" \
  --backend-type "$BACKEND_TYPE" \
  --backend-config "$FOUNDATION_BACKEND_CONFIG" \
  --peer-backend-config "$ACCOUNT_BOOTSTRAP_BACKEND_CONFIG" \
  --peer-backend-config "$ADDONS_BACKEND_CONFIG" \
  --environment "$ENVIRONMENT" \
  "${FOUNDATION_STATE_PROVENANCE_ARGS[@]}" &&

(
  set -euo pipefail
  test "${FOUNDATION_INPUTS_CONFIRMED:-}" = "yes"
  PLAN_FILE=terraform/examples/complete/foundation/foundation.tfplan
  rm -f "$PLAN_FILE"
  trap 'rm -f "$PLAN_FILE"' EXIT
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/foundation plan \
    -var="aws_region=$AWS_REGION" \
    -var="name=$ENVIRONMENT" \
    -var="openvpn_runtime_secret_arn=$RUNTIME_SECRET_ARN" \
    -var="deletion_protection=true" \
    -var="enable_cluster_creator_admin_permissions=true" \
    -input=false -out=foundation.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/foundation show foundation.tfplan
  validate_foundation_plan foundation.tfplan true true false
  trap - EXIT
)
```

Never apply an unreviewed plan. Re-check the exact account immediately before the saved-plan apply:

```bash
validate_foundation_plan foundation.tfplan true true false &&
  FOUNDATION_PLAN_SECRET_ARN="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation show \
    -json foundation.tfplan | \
    jq -er '.variables.openvpn_runtime_secret_arn.value')" &&
  test "$FOUNDATION_PLAN_SECRET_ARN" = "$RUNTIME_SECRET_ARN" &&
  assert_account && \
  "$ENGINE" -chdir=terraform/examples/complete/foundation apply foundation.tfplan
```

Capture durable outputs before later changes or destruction:

```bash
CLUSTER_NAME="$("$ENGINE" -chdir=terraform/examples/complete/foundation \
  output -raw cluster_name)" &&
  VPC_ID="$("$ENGINE" -chdir=terraform/examples/complete/foundation \
    output -raw vpc_id)" &&
  CLUSTER_KMS_KEY_ARN="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation output -raw cluster_kms_key_arn)" &&
  RUNTIME_SECRET_ARN="$(jq -er '.secret_id' \
    "${OPENVPN_PKI_ROOT:-$HOME/.config/unrealops/pki}/$ENVIRONMENT/metadata.json")" &&
  test "$CLUSTER_NAME" = "$ENVIRONMENT" &&
  [[ "$VPC_ID" == vpc-* ]] &&
  [[ "$CLUSTER_KMS_KEY_ARN" == \
    arn:*:kms:"$AWS_REGION":"$EXPECTED_ACCOUNT_ID":key/* ]] &&
  [[ "$RUNTIME_SECRET_ARN" == \
    arn:*:secretsmanager:"$AWS_REGION":"$EXPECTED_ACCOUNT_ID":secret:* ]] &&
  export CLUSTER_NAME VPC_ID CLUSTER_KMS_KEY_ARN RUNTIME_SECRET_ARN
```

Confirm these values belong to the expected account, region, and environment before recording them in the durable handoff.

## Connect and validate durable administrator access

Create a named client profile and print its exact path:

```bash
(
  set -euo pipefail
  ENDPOINT="$("$ENGINE" -chdir=terraform/examples/complete/foundation \
    output -raw openvpn_endpoint)"
  VPN_PROFILE="${OPENVPN_PKI_ROOT:-$HOME/.config/unrealops/pki}/$ENVIRONMENT/profiles/$(id -un).ovpn"
  if [[ ! -e "$VPN_PROFILE" ]]; then
    make vpn-client ENV="$ENVIRONMENT" USER="$(id -un)" ENDPOINT="$ENDPOINT"
  fi
  test -s "$VPN_PROFILE"
  awk -v endpoint="$ENDPOINT" '
    $1 == "remote" && $2 == endpoint { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$VPN_PROFILE"
  printf 'VPN profile: %s\n' "$VPN_PROFILE"
)
```

In a dedicated terminal, export `VPN_PROFILE` to the exact path printed above, start OpenVPN, and leave it running. Wait for `Initialization Sequence Completed` before continuing:

```bash
sudo openvpn --config "$VPN_PROFILE"
```

On macOS, OpenVPN Connect may instead import and activate that exact profile. Create a temporary kubeconfig only after the tunnel is active, then prove the private API is ready:

```bash
KUBECONFIG_DIRECTORY="$(mktemp -d)" &&
  test -n "$KUBECONFIG_DIRECTORY" &&
  test "$KUBECONFIG_DIRECTORY" != "/" &&
  test -d "$KUBECONFIG_DIRECTORY" &&
  chmod 700 "$KUBECONFIG_DIRECTORY" &&
  KUBECONFIG="$KUBECONFIG_DIRECTORY/kubeconfig" &&
  export KUBECONFIG_DIRECTORY KUBECONFIG &&
  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --kubeconfig "$KUBECONFIG" &&
  kubectl --kubeconfig "$KUBECONFIG" \
    --request-timeout=15s get --raw=/readyz
```

In a separate AWS session authenticated as one of the durable `admin_principal_arns`, rerun Preflight so its checked functions and variables exist, then create another temporary kubeconfig. The STS identity must match a configured IAM user or the assumed-role form of a configured IAM role, and every command must succeed:

```bash
DURABLE_ADMIN_PRINCIPALS="$("$ENGINE" \
  -chdir=terraform/examples/complete/foundation show -json foundation.tfplan | \
  jq -ce '.variables.admin_principal_arns.value')" &&
  assert_durable_admin_identity "$DURABLE_ADMIN_PRINCIPALS" &&
  DURABLE_ADMIN_KUBECONFIG_DIRECTORY="$(mktemp -d)" &&
  test -n "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY" &&
  test "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY" != "/" &&
  test -d "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY" &&
  chmod 700 "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY" &&
  DURABLE_ADMIN_KUBECONFIG="$DURABLE_ADMIN_KUBECONFIG_DIRECTORY/kubeconfig" &&
  export DURABLE_ADMIN_KUBECONFIG_DIRECTORY DURABLE_ADMIN_KUBECONFIG &&
  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --kubeconfig "$DURABLE_ADMIN_KUBECONFIG" &&
  kubectl --kubeconfig "$DURABLE_ADMIN_KUBECONFIG" \
    auth can-i '*' '*' --all-namespaces | grep -qx yes
```

The authorization result must be `yes`. Only then set `enable_cluster_creator_admin_permissions = false` in the retained foundation inputs, save and inspect a new plan, and apply it after another exact-account check:

```bash
export CREATOR_ADMIN_OFF_INPUTS_CONFIRMED=yes

(
  set -euo pipefail
  test "$CREATOR_ADMIN_OFF_INPUTS_CONFIRMED" = "yes"
  PLAN_FILE=terraform/examples/complete/foundation/creator-admin-off.tfplan
  rm -f "$PLAN_FILE"
  trap 'rm -f "$PLAN_FILE"' EXIT
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/foundation plan \
    -var="aws_region=$AWS_REGION" \
    -var="name=$ENVIRONMENT" \
    -var="openvpn_runtime_secret_arn=$RUNTIME_SECRET_ARN" \
    -var="deletion_protection=true" \
    -var="enable_cluster_creator_admin_permissions=false" \
    -input=false -out=creator-admin-off.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/foundation show \
    creator-admin-off.tfplan
  validate_foundation_plan creator-admin-off.tfplan true false false
  : "${DURABLE_ADMIN_PRINCIPALS:?rerun the durable administrator check}"
  OFF_PLAN_ADMIN_PRINCIPALS="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation show \
    -json creator-admin-off.tfplan | \
    jq -cS '.variables.admin_principal_arns.value | sort')"
  VALIDATED_ADMIN_PRINCIPALS="$(jq -cS 'sort' \
    <<<"$DURABLE_ADMIN_PRINCIPALS")"
  test "$OFF_PLAN_ADMIN_PRINCIPALS" = "$VALIDATED_ADMIN_PRINCIPALS"
  trap - EXIT
)
```

After explicit review, re-check the exact account immediately before applying that saved plan:

```bash
OFF_PLAN_ADMIN_PRINCIPALS="$("$ENGINE" \
  -chdir=terraform/examples/complete/foundation show \
  -json creator-admin-off.tfplan | \
  jq -cS '.variables.admin_principal_arns.value | sort')" &&
  VALIDATED_ADMIN_PRINCIPALS="$(jq -cS 'sort' \
    <<<"${DURABLE_ADMIN_PRINCIPALS:?rerun the durable administrator check}")" &&
  test "$OFF_PLAN_ADMIN_PRINCIPALS" = "$VALIDATED_ADMIN_PRINCIPALS" &&
  assert_durable_admin_identity "$DURABLE_ADMIN_PRINCIPALS" &&
  assert_account && \
  "$ENGINE" -chdir=terraform/examples/complete/foundation apply \
  creator-admin-off.tfplan
```

Repeat the durable administrator check after this apply; the command must still succeed:

```bash
assert_durable_admin_identity "$DURABLE_ADMIN_PRINCIPALS" &&
  kubectl --kubeconfig "$DURABLE_ADMIN_KUBECONFIG" \
    auth can-i '*' '*' --all-namespaces | grep -qx yes &&
  FOUNDATION_STATE_LINEAGE="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation state pull | \
    jq -er '.lineage | select(type == "string" and length > 0)')" &&
  export FOUNDATION_STATE_LINEAGE
```

Do not proceed if durable access is lost or the lineage cannot be read.

Switch the deployment shell to that validated durable-administrator AWS session before continuing, and set `KUBECONFIG="$DURABLE_ADMIN_KUBECONFIG"`. The add-ons Kubernetes and Helm providers obtain their EKS token from the shell's AWS credential chain; the removed cluster-creator access must not be their credential source. Re-run `assert_account` after switching sessions. Confirm that this session can also read and lock the state objects needed for its work before proceeding; access to account-bootstrap state is not required for ordinary cluster administration.

## Deploy add-ons

Prepare the add-ons inputs. Set the exact region, set `cluster_name` to the foundation environment name (`ENVIRONMENT` / foundation `name`), and set tags. Do not configure foundation remote state; the add-ons root discovers the cluster and Karpenter AWS prerequisites from AWS data sources.

Example add-ons tfvars:

```hcl
aws_region   = "REPLACE_WITH_CONFIRMED_REGION"
cluster_name = "REPLACE_WITH_CONFIRMED_UNIQUE_NAME"
```

```bash
ADDONS_TFVARS=terraform/examples/complete/addons/terraform.tfvars
if [[ -e "$ADDONS_TFVARS" ]]; then
  printf 'Reusing %s; verify that it belongs to this environment\n' \
    "$ADDONS_TFVARS"
else
  cp terraform/examples/complete/addons/terraform.tfvars.example \
    "$ADDONS_TFVARS"
fi
```

Stop and edit that file. Require `aws_region = AWS_REGION`, `cluster_name = ENVIRONMENT`, and the approved tags. Then explicitly confirm both the inputs and whether the add-ons state is new or retained:

```bash
export ADDONS_INPUTS_CONFIRMED=yes
ADDONS_STATE_PROVENANCE_ARGS=()
if [[ -n "${EXPECTED_ADDONS_STATE_LINEAGE:-}" ]]; then
  ADDONS_STATE_PROVENANCE_ARGS=(
    --expected-lineage "$EXPECTED_ADDONS_STATE_LINEAGE"
  )
elif [[ "${CONFIRM_NEW_ADDONS_STATE:-}" == "yes" ]]; then
  ADDONS_STATE_PROVENANCE_ARGS=(--allow-new-state)
else
  printf '%s\n' \
    'Recover EXPECTED_ADDONS_STATE_LINEAGE or set CONFIRM_NEW_ADDONS_STATE=yes after confirming this is a new add-ons state.' >&2
  false
fi

.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh \
  --root addons \
  --engine "$ENGINE" \
  --backend-type "$BACKEND_TYPE" \
  --backend-config "$ADDONS_BACKEND_CONFIG" \
  --peer-backend-config "$ACCOUNT_BOOTSTRAP_BACKEND_CONFIG" \
  --peer-backend-config "$FOUNDATION_BACKEND_CONFIG" \
  --environment "$ENVIRONMENT" \
  "${ADDONS_STATE_PROVENANCE_ARGS[@]}" &&

(
  set -euo pipefail
  test "$ADDONS_INPUTS_CONFIRMED" = "yes"
  PLAN_FILE=terraform/examples/complete/addons/addons.tfplan
  rm -f "$PLAN_FILE"
  trap 'rm -f "$PLAN_FILE"' EXIT
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/addons plan \
    -var="aws_region=$AWS_REGION" \
    -var="cluster_name=$ENVIRONMENT" \
    -input=false -out=addons.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/addons show addons.tfplan
  validate_addons_plan addons.tfplan
  trap - EXIT
)
```

After explicit review, re-check the exact account immediately before applying that saved plan:

```bash
assert_account &&
  "$ENGINE" -chdir=terraform/examples/complete/addons apply addons.tfplan &&
  ADDONS_STATE_LINEAGE="$("$ENGINE" \
    -chdir=terraform/examples/complete/addons state pull | \
    jq -er '.lineage | select(type == "string" and length > 0)')" &&
  test "$ADDONS_STATE_LINEAGE" != "$FOUNDATION_STATE_LINEAGE" &&
  export ADDONS_STATE_LINEAGE
```

The add-ons backend stores only the add-ons root's own managed state. Discovery of foundation resources uses AWS APIs and the known `cluster_name`, not foundation Terraform state.

## Verify the deployment and pins

The earlier `make check` validates the modules' private version constants. The following checks read their expected values from Terraform outputs and compare them with deployed resources.

Verify the EKS version, active state, private-only endpoint, system-node AMI release, and all five managed add-ons:

```bash
(
  set -euo pipefail
  assert_account
  EXPECTED_EKS_VERSION="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation output -raw cluster_version)"
  EXPECTED_ADDONS="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation output -json cluster_addon_versions)"
  SYSTEM_AMI_RELEASE="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation \
    output -raw system_node_ami_release_version)"
  EXPECTED_SYSTEM_NODE_GROUP_SIZE="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation \
    output -json system_node_group_size)"
  SYSTEM_NODE_GROUP_NAME="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation \
    output -raw system_node_group_name)"
  EXPECTED_SYSTEM_NODE_INSTANCE_TYPES="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation \
    output -json system_node_instance_types)"

  LORE_ENABLED="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation \
    output -json lore_ecr_repository_url | jq -r 'type == "string"')"
  if [[ "$LORE_ENABLED" != "true" ]]; then
    EXPECTED_ADDONS="$(jq 'del(.cloudwatch_observability)' \
      <<<"$EXPECTED_ADDONS")"
  fi

  CLUSTER_JSON="$(aws eks describe-cluster \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --output json)"
  jq -e --arg version "$EXPECTED_EKS_VERSION" '
    .cluster.status == "ACTIVE" and
    .cluster.version == $version and
    .cluster.resourcesVpcConfig.endpointPrivateAccess == true and
    .cluster.resourcesVpcConfig.endpointPublicAccess == false
  ' <<<"$CLUSTER_JSON"

  NODEGROUP_JSON="$(aws eks describe-nodegroup \
    --region "$AWS_REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$SYSTEM_NODE_GROUP_NAME" \
    --output json)"
  jq -e --arg release "$SYSTEM_AMI_RELEASE" \
    --argjson size "$EXPECTED_SYSTEM_NODE_GROUP_SIZE" \
    --argjson instance_types "$EXPECTED_SYSTEM_NODE_INSTANCE_TYPES" '
    .nodegroup.status == "ACTIVE" and
    .nodegroup.releaseVersion == $release and
    .nodegroup.instanceTypes == $instance_types and
    .nodegroup.scalingConfig.minSize == $size.min and
    .nodegroup.scalingConfig.desiredSize == $size.desired and
    .nodegroup.scalingConfig.maxSize == $size.max
  ' <<<"$NODEGROUP_JSON"

  if [[ "$LORE_ENABLED" == "true" ]]; then
    test "$(jq 'length' <<<"$EXPECTED_ADDONS")" -eq 6
  else
    test "$(jq 'length' <<<"$EXPECTED_ADDONS")" -eq 5
  fi
  ADDONS_TSV="$(jq -er '
    {
      vpc_cni: "vpc-cni",
      coredns: "coredns",
      kube_proxy: "kube-proxy",
      ebs_csi_driver: "aws-ebs-csi-driver",
      pod_identity_agent: "eks-pod-identity-agent",
      cloudwatch_observability: "amazon-cloudwatch-observability"
    } as $names
    | to_entries[]
    | .key as $key
    | [$names[$key], .value]
    | @tsv
  ' <<<"$EXPECTED_ADDONS")"
  while IFS=$'\t' read -r addon expected_version; do
    ADDON_JSON="$(aws eks describe-addon \
      --region "$AWS_REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --addon-name "$addon" \
      --output json)"
    jq -e --arg version "$expected_version" '
      .addon.status == "ACTIVE" and .addon.addonVersion == $version
    ' <<<"$ADDON_JSON"
  done <<<"$ADDONS_TSV"

  kubectl --kubeconfig "$KUBECONFIG" wait \
    --for=condition=Ready nodes \
    -l unrealops.io/node-role=system \
    --timeout=10m
  SYSTEM_NODE_COUNT="$(kubectl --kubeconfig "$KUBECONFIG" get nodes \
    -l unrealops.io/node-role=system -o json | jq '.items | length')"
  EXPECTED_SYSTEM_NODE_COUNT="$(jq -er '.desired' \
    <<<"$EXPECTED_SYSTEM_NODE_GROUP_SIZE")"
  test "$SYSTEM_NODE_COUNT" -ge "$EXPECTED_SYSTEM_NODE_COUNT"
)
```

Verify the pinned Karpenter controller and resources:

```bash
(
  set -euo pipefail
  assert_account
  EXPECTED_KARPENTER_VERSION="$("$ENGINE" \
    -chdir=terraform/examples/complete/addons output -raw karpenter_version)"
  SYSTEM_AMI_RELEASE="$("$ENGINE" \
    -chdir=terraform/examples/complete/foundation \
    output -raw system_node_ami_release_version)"
  EXPECTED_AMI_ALIAS="al2023@v${SYSTEM_AMI_RELEASE##*-}"
  NODE_CLASS="$("$ENGINE" -chdir=terraform/examples/complete/addons \
    output -raw node_class_name)"
  NODE_POOL="$("$ENGINE" -chdir=terraform/examples/complete/addons \
    output -raw node_pool_name)"

  kubectl --kubeconfig "$KUBECONFIG" -n kube-system rollout status \
    deployment/karpenter --timeout=10m
  kubectl --kubeconfig "$KUBECONFIG" -n kube-system get deployment karpenter \
    -o json | jq -e --arg version "$EXPECTED_KARPENTER_VERSION" '
      .status.availableReplicas >= 2 and
      any(.spec.template.spec.containers[];
        .name == "controller" and
        ((.image | split("@")[0]) | endswith(":" + $version)))
    '
  kubectl --kubeconfig "$KUBECONFIG" wait \
    --for=condition=Ready "ec2nodeclass/$NODE_CLASS" --timeout=10m
  kubectl --kubeconfig "$KUBECONFIG" wait \
    --for=condition=Ready "nodepool/$NODE_POOL" --timeout=10m
  kubectl --kubeconfig "$KUBECONFIG" get "ec2nodeclass/$NODE_CLASS" \
    -o json | jq -e --arg alias "$EXPECTED_AMI_ALIAS" '
      .spec.amiSelectorTerms | any(.[]; .alias == $alias)
    '
  kubectl --kubeconfig "$KUBECONFIG" get "nodepool/$NODE_POOL" \
    -o json | jq -e --arg node_class "$NODE_CLASS" '
      .spec.template.spec.nodeClassRef.name == $node_class and
      .spec.disruption.consolidationPolicy == "WhenEmptyOrUnderutilized"
    '
)
```

Run functional verification before installing application workloads. It creates a temporary billable EC2 node and therefore remains inside the explicit deployment authorization. Run the workload in a subshell so its Deployment is removed after an error; Karpenter itself must consolidate the resulting empty node:

```bash
(
  set -euo pipefail
  assert_account
  cleanup_verification() {
    kubectl --kubeconfig "$KUBECONFIG" delete deployment \
      unrealops-karpenter-verification --ignore-not-found=true --wait=true
  }
  trap cleanup_verification EXIT

  kubectl --kubeconfig "$KUBECONFIG" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unrealops-karpenter-verification
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unrealops-karpenter-verification
  template:
    metadata:
      labels:
        app: unrealops-karpenter-verification
    spec:
      nodeSelector:
        unrealops.io/capacity-provider: karpenter
        karpenter.sh/capacity-type: on-demand
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: "1"
              memory: 1Gi
YAML

  kubectl --kubeconfig "$KUBECONFIG" rollout status \
    deployment/unrealops-karpenter-verification --timeout=20m
  test -n "$(kubectl --kubeconfig "$KUBECONFIG" get nodes \
    -l unrealops.io/capacity-provider=karpenter -o name)"
  kubectl --kubeconfig "$KUBECONFIG" delete deployment \
    unrealops-karpenter-verification --wait=true

  deadline=$((SECONDS + 900))
  while ((SECONDS < deadline)); do
    nodes="$(kubectl --kubeconfig "$KUBECONFIG" get nodes \
      -l unrealops.io/capacity-provider=karpenter -o name)"
    claims="$(kubectl --kubeconfig "$KUBECONFIG" get nodeclaims.karpenter.sh \
      -l unrealops.io/capacity-provider=karpenter -o name)"
    [[ -n "$nodes" || -n "$claims" ]] || break
    sleep 30
  done
  test -z "$nodes$claims"
)
```

## Retain the durable handoff

Before ending the deployment session, store the following in the studio's approved encrypted operations system:

- Confirmed account, region, environment, engine, repository release tag, and commit.
- Backend type and all three external backend config files, with separate state keys and no credentials.
- The exact account-bootstrap, foundation, and add-ons state lineages captured after deployment.
- The populated account-bootstrap, foundation, and add-ons inputs, including the trusted permanent IAM principals and the add-ons `cluster_name` (equal to the environment).
- Runtime secret ARN, its external encryption KMS key ARN when configured, offline PKI backup and recovery instructions, and client-revocation procedure.
- Cluster name verified equal to the environment, VPC ID, KMS key ARN, and an explicit Route 53 decision: `OPENVPN_ROUTE53_CONFIGURED=yes` plus zone/record coordinates, or `OPENVPN_ROUTE53_CONFIGURED=no`.
- Sanitized plan summaries, apply timestamps, durable administrator principals, and commands run.

Never commit backend config, populated tfvars, plans, state, kubeconfigs, profiles, PKI, or credentials. The generated `backend_override.tf` files are ignored and recreatable; the retained external config files are the durable source. After all cluster work is complete, disconnect the OpenVPN client. Remove the two temporary kubeconfigs at the end of the operator session:

```bash
(
  set -euo pipefail
  : "${KUBECONFIG_DIRECTORY:?missing temporary kubeconfig directory}"
  : "${DURABLE_ADMIN_KUBECONFIG_DIRECTORY:?missing durable-admin kubeconfig directory}"
  test "$KUBECONFIG_DIRECTORY" != "/"
  test "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY" != "/"
  test -d "$KUBECONFIG_DIRECTORY"
  test -d "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY"
  rm -f -- \
    "$KUBECONFIG_DIRECTORY/kubeconfig" \
    "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY/kubeconfig"
  rmdir -- "$KUBECONFIG_DIRECTORY" "$DURABLE_ADMIN_KUBECONFIG_DIRECTORY"
) &&
  unset KUBECONFIG KUBECONFIG_DIRECTORY &&
  unset DURABLE_ADMIN_KUBECONFIG DURABLE_ADMIN_KUBECONFIG_DIRECTORY
```

When studio retention policy no longer requires the saved plans, remove exactly the files created by this runbook:

```bash
rm -f -- \
  terraform/examples/account-bootstrap/account-bootstrap.tfplan \
  terraform/examples/complete/foundation/foundation.tfplan \
  terraform/examples/complete/foundation/creator-admin-off.tfplan \
  terraform/examples/complete/foundation/deletion-protection-off.tfplan \
  terraform/examples/complete/foundation/foundation-destroy.tfplan \
  terraform/examples/complete/addons/addons.tfplan \
  terraform/examples/complete/addons/addons-destroy.tfplan
```

## Destroy

Obtain explicit destroy authorization for the exact account, region, and environment. Recover the durable handoff, including the foundation and add-ons state lineages, then initialize those roots with their respective external backend files. Do not destroy account bootstrap as part of ordinary environment cleanup; retain its state and role until every referenced cluster access entry is removed and identity retirement is separately authorized.

```bash
(
set -euo pipefail
: "${EXPECTED_FOUNDATION_STATE_LINEAGE:?recover the foundation lineage}"
: "${EXPECTED_ADDONS_STATE_LINEAGE:?recover the add-ons lineage}"
: "${VPC_ID:?recover the foundation VPC ID}"
: "${CLUSTER_KMS_KEY_ARN:?recover the EKS KMS key ARN}"
: "${RUNTIME_SECRET_ARN:?recover the runtime secret ARN}"

.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh \
  --root foundation \
  --engine "$ENGINE" \
  --backend-type "$BACKEND_TYPE" \
  --backend-config "$FOUNDATION_BACKEND_CONFIG" \
  --peer-backend-config "$ACCOUNT_BOOTSTRAP_BACKEND_CONFIG" \
  --peer-backend-config "$ADDONS_BACKEND_CONFIG" \
  --environment "$ENVIRONMENT" \
  --expected-lineage "$EXPECTED_FOUNDATION_STATE_LINEAGE"
.agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh \
  --root addons \
  --engine "$ENGINE" \
  --backend-type "$BACKEND_TYPE" \
  --backend-config "$ADDONS_BACKEND_CONFIG" \
  --peer-backend-config "$ACCOUNT_BOOTSTRAP_BACKEND_CONFIG" \
  --peer-backend-config "$FOUNDATION_BACKEND_CONFIG" \
  --environment "$ENVIRONMENT" \
  --expected-lineage "$EXPECTED_ADDONS_STATE_LINEAGE"

assert_account
CURRENT_FOUNDATION_STATE_LINEAGE="$("$ENGINE" \
  -chdir=terraform/examples/complete/foundation state pull | jq -er '.lineage')"
CURRENT_ADDONS_STATE_LINEAGE="$("$ENGINE" \
  -chdir=terraform/examples/complete/addons state pull | jq -er '.lineage')"
CURRENT_VPC_ID="$("$ENGINE" -chdir=terraform/examples/complete/foundation \
  output -raw vpc_id)"
CURRENT_CLUSTER_KMS_KEY_ARN="$("$ENGINE" \
  -chdir=terraform/examples/complete/foundation \
  output -raw cluster_kms_key_arn)"
test "$CURRENT_FOUNDATION_STATE_LINEAGE" = \
  "$EXPECTED_FOUNDATION_STATE_LINEAGE"
test "$CURRENT_ADDONS_STATE_LINEAGE" = "$EXPECTED_ADDONS_STATE_LINEAGE"
test "$CURRENT_FOUNDATION_STATE_LINEAGE" != "$CURRENT_ADDONS_STATE_LINEAGE"
test "$CURRENT_VPC_ID" = "$VPC_ID"
test "$CURRENT_CLUSTER_KMS_KEY_ARN" = "$CLUSTER_KMS_KEY_ARN"
)
```

Stop if either exact lineage differs. Recreate a temporary kubeconfig and connect OpenVPN while the private cluster API still exists.

Delete application workloads first. Then remove workload NodeClaims and wait for Karpenter-created nodes and claims to disappear:

```bash
(
  set -euo pipefail
  assert_account
  kubectl --kubeconfig "$KUBECONFIG" delete nodeclaims.karpenter.sh \
    -l unrealops.io/capacity-provider=karpenter \
    --ignore-not-found=true --wait=false

  nodes=""
  claims=""
  deadline=$((SECONDS + 900))
  while ((SECONDS < deadline)); do
    nodes="$(kubectl --kubeconfig "$KUBECONFIG" get nodes \
      -l unrealops.io/capacity-provider=karpenter -o name)"
    claims="$(kubectl --kubeconfig "$KUBECONFIG" get nodeclaims.karpenter.sh \
      -l unrealops.io/capacity-provider=karpenter -o name)"
    [[ -n "$nodes" || -n "$claims" ]] || break
    sleep 30
  done
  test -z "$nodes$claims"
)
```

Save and review the add-ons destroy plan, then re-check the exact account immediately before applying it:

```bash
(
  set -euo pipefail
  PLAN_FILE=terraform/examples/complete/addons/addons-destroy.tfplan
  rm -f "$PLAN_FILE"
  trap 'rm -f "$PLAN_FILE"' EXIT
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/addons plan -destroy \
    -input=false \
    -var="aws_region=$AWS_REGION" \
    -var="cluster_name=$ENVIRONMENT" \
    -out=addons-destroy.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/addons show \
    addons-destroy.tfplan
  # Destroy plans have an empty planned final state, so validate inputs but do
  # not require the EKS data source in planned_values.
  validate_addons_plan addons-destroy.tfplan false
  trap - EXIT
)
```

After explicit review, re-check the exact account immediately before applying that saved plan:

```bash
(
  set -euo pipefail
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/addons apply \
    addons-destroy.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/addons state pull | \
    jq -e --arg lineage "$EXPECTED_ADDONS_STATE_LINEAGE" '
      .lineage == $lineage and
      ([.resources[]? | select(.mode == "managed")] | length) == 0
    '
)
```

In the OpenVPN terminal, press Ctrl-C and wait for the foreground client to exit; for OpenVPN Connect, disconnect the imported profile. Confirm that the tunnel interface and private VPC route are gone. For a durable environment, set `deletion_protection = false` in the retained foundation inputs and apply that change through its own reviewed saved plan:

```bash
export DELETION_PROTECTION_OFF_INPUTS_CONFIRMED=yes

(
  set -euo pipefail
  test "$DELETION_PROTECTION_OFF_INPUTS_CONFIRMED" = "yes"
  PLAN_FILE=terraform/examples/complete/foundation/deletion-protection-off.tfplan
  rm -f "$PLAN_FILE"
  trap 'rm -f "$PLAN_FILE"' EXIT
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/foundation plan \
    -var="aws_region=$AWS_REGION" \
    -var="name=$ENVIRONMENT" \
    -var="openvpn_runtime_secret_arn=$RUNTIME_SECRET_ARN" \
    -var="deletion_protection=false" \
    -var="enable_cluster_creator_admin_permissions=false" \
    -input=false -out=deletion-protection-off.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/foundation show \
    deletion-protection-off.tfplan
  validate_foundation_plan deletion-protection-off.tfplan false false false
  trap - EXIT
)
```

After explicit review, re-check the exact account immediately before applying that saved plan:

```bash
assert_account && \
  "$ENGINE" -chdir=terraform/examples/complete/foundation apply \
  deletion-protection-off.tfplan
```

Then save, review, and apply foundation destruction:

```bash
(
  set -euo pipefail
  PLAN_FILE=terraform/examples/complete/foundation/foundation-destroy.tfplan
  rm -f "$PLAN_FILE"
  trap 'rm -f "$PLAN_FILE"' EXIT
  assert_account
  "$ENGINE" -chdir=terraform/examples/complete/foundation plan -destroy \
    -input=false \
    -var="aws_region=$AWS_REGION" \
    -var="name=$ENVIRONMENT" \
    -var="openvpn_runtime_secret_arn=$RUNTIME_SECRET_ARN" \
    -var="deletion_protection=false" \
    -var="enable_cluster_creator_admin_permissions=false" \
    -out=foundation-destroy.tfplan
  "$ENGINE" -chdir=terraform/examples/complete/foundation show \
    foundation-destroy.tfplan
  validate_foundation_plan foundation-destroy.tfplan false false false
  trap - EXIT
)
```

After explicit review, re-check the exact account immediately before applying that saved plan:

```bash
assert_account && \
  "$ENGINE" -chdir=terraform/examples/complete/foundation apply \
  foundation-destroy.tfplan
```

Require empty managed remote state and no environment-owned residue before deleting the external runtime secret. Recover the optional Route 53 inputs from the handoff; when they were configured, pass both exact values to each audit:

```bash
case "${OPENVPN_ROUTE53_CONFIGURED:?recover the explicit Route 53 decision}" in
  yes)
    : "${OPENVPN_ROUTE53_ZONE_ID:?recover the Route 53 zone ID}"
    : "${OPENVPN_ROUTE53_RECORD_NAME:?recover the Route 53 record name}"
    AUDIT_ROUTE53_ARGS=(
    --route53-zone-id "$OPENVPN_ROUTE53_ZONE_ID"
    --route53-record-name "$OPENVPN_ROUTE53_RECORD_NAME"
    )
    ;;
  no) AUDIT_ROUTE53_ARGS=(--no-route53-record) ;;
  *) printf 'OPENVPN_ROUTE53_CONFIGURED must be yes or no\n' >&2; false ;;
esac

.agents/skills/deploy-unrealops-infrastructure/scripts/audit-cleanup.sh \
  --account-id "$EXPECTED_ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --environment "$ENVIRONMENT" \
  --engine "$ENGINE" \
  --vpc-id "$VPC_ID" \
  --foundation-lineage "$EXPECTED_FOUNDATION_STATE_LINEAGE" \
  --addons-lineage "$EXPECTED_ADDONS_STATE_LINEAGE" \
  --kms-key-id "$CLUSTER_KMS_KEY_ARN" \
  --runtime-secret-id "$RUNTIME_SECRET_ARN" \
  "${AUDIT_ROUTE53_ARGS[@]}" \
  --allow-active-runtime-secret
```

After that audit passes, schedule deletion of the exact secret under the studio's recovery-window policy. Re-check the account immediately before the write:

```bash
export SECRET_RECOVERY_DAYS=30
assert_account && aws secretsmanager delete-secret \
  --region "$AWS_REGION" \
  --secret-id "$RUNTIME_SECRET_ARN" \
  --recovery-window-in-days "$SECRET_RECOVERY_DAYS"
```

Run the final audit without `--allow-active-runtime-secret`; rerun it after eventual-consistency delays until it passes:

```bash
.agents/skills/deploy-unrealops-infrastructure/scripts/audit-cleanup.sh \
  --account-id "$EXPECTED_ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --environment "$ENVIRONMENT" \
  --engine "$ENGINE" \
  --vpc-id "$VPC_ID" \
  --foundation-lineage "$EXPECTED_FOUNDATION_STATE_LINEAGE" \
  --addons-lineage "$EXPECTED_ADDONS_STATE_LINEAGE" \
  --kms-key-id "$CLUSTER_KMS_KEY_ARN" \
  --runtime-secret-id "$RUNTIME_SECRET_ARN" \
  "${AUDIT_ROUTE53_ARGS[@]}"
```

The only accepted Terraform-managed remnant is the recorded EKS KMS key when it is disabled, has no alias, and is in `PendingDeletion` with a deletion date. Report its key ID and deletion date. The external remote-backend infrastructure is not owned by these roots; retain or retire it only under its separate state-platform policy. Retain or securely destroy the offline CA according to studio policy.

Never destroy the foundation before add-ons: the Kubernetes and Helm providers need the private cluster API to remove their resources.
