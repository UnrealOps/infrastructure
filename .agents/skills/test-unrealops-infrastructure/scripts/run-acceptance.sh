#!/usr/bin/env bash

set -euo pipefail
umask 077

usage() {
	cat <<'EOF'
Run the complete billable UnrealOps Terratest suite with isolated PKI and cleanup.

Usage:
  run-acceptance.sh --engine tofu|terraform --account-id 123456789012 \
    --region us-west-2 --run-id tofu-12345 --confirm-billable \
    [--work-dir PATH] [--openvpn-connect-cli PATH]
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

engine=""
account_id=""
region=""
run_id=""
work_dir=""
connect_cli=""
confirmed="false"

while (($#)); do
	case "$1" in
	--engine)
		engine="${2:-}"
		shift 2
		;;
	--account-id)
		account_id="${2:-}"
		shift 2
		;;
	--region)
		region="${2:-}"
		shift 2
		;;
	--run-id)
		run_id="${2:-}"
		shift 2
		;;
	--work-dir)
		work_dir="${2:-}"
		shift 2
		;;
	--openvpn-connect-cli)
		connect_cli="${2:-}"
		shift 2
		;;
	--confirm-billable)
		confirmed="true"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

[[ "$engine" == "tofu" || "$engine" == "terraform" ]] || die "--engine must be tofu or terraform"
[[ "$account_id" =~ ^[0-9]{12}$ ]] || die "--account-id must be exactly 12 digits"
[[ -n "$region" ]] || die "--region is required; region defaults are forbidden"
[[ ${#run_id} -le 16 && "$run_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
	die "--run-id must be 1-16 lowercase letters, digits, or hyphens and cannot start/end with a hyphen"
[[ "$confirmed" == "true" ]] || die "--confirm-billable is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
audit_script="$script_dir/audit-acceptance-cleanup.sh"
work_dir="${work_dir:-${TMPDIR:-/tmp}/unrealops-acceptance-${run_id}}"

state_roots=(
	terraform/examples/complete/foundation
	terraform/examples/complete/addons
	terraform/tests/fixtures/openvpn
	terraform/tests/fixtures/network
)

assert_clean_terraform_environment() {
	local name
	local -a unsafe_names=()

	while IFS='=' read -r name _; do
		case "$name" in
		TF_VAR_* | TF_WORKSPACE | TF_DATA_DIR | TF_CLI_ARGS | TF_CLI_ARGS_*)
			unsafe_names+=("$name")
			;;
		esac
	done < <(env)

	if ((${#unsafe_names[@]} > 0)); then
		die "unset inherited Terraform control variables before acceptance: ${unsafe_names[*]}"
	fi
}

assert_isolated_terraform_root() {
	local root="$1" root_directory="$repo_root/$1"
	local path terraform_source backend_pattern backend_type backend_path

	path="$(find "$root_directory" -maxdepth 1 \( \
		-type f -o -type l \
		\) \( \
		\( -name '*.tfvars' ! -name '*.tfvars.example' \) -o \
		-name '*.tfvars.json' -o \
		-name 'override.tf' -o \
		-name 'override.tf.json' -o \
		-name '*_override.tf' -o \
		-name '*_override.tf.json' \
		\) -print -quit)"
	[[ -z "$path" ]] ||
		die "acceptance requires an isolated root; move local inputs or overrides out of $root: $path"

	backend_pattern='backend[[:space:]]*"[^"]+"[[:space:]]*\{'
	while IFS= read -r -d '' path; do
		terraform_source="$(<"$path")"
		[[ ! "$terraform_source" =~ $backend_pattern ]] ||
			die "acceptance forbids configured backends; use a clean checkout or worktree: $path"
	done < <(find "$root_directory" -maxdepth 1 -type f -name '*.tf' -print0)

	[[ ! -e "$root_directory/.terraform/environment" ]] ||
		die "acceptance forbids a cached Terraform workspace selection: $root/.terraform/environment"
	[[ ! -d "$root_directory/terraform.tfstate.d" ]] ||
		die "acceptance forbids local non-default Terraform workspaces: $root/terraform.tfstate.d"

	path="$root_directory/.terraform/terraform.tfstate"
	if [[ -e "$path" ]]; then
		[[ -f "$path" && ! -L "$path" ]] ||
			die "refusing unexpected cached backend metadata: $path"
		backend_type="$(jq -er '.backend.type // "local"' "$path")" ||
			die "could not parse cached backend metadata: $path"
		backend_path="$(jq -er '.backend.config.path // "terraform.tfstate"' "$path")" ||
			die "could not parse cached local-state path: $path"
		[[ "$backend_type" == "local" && "$backend_path" == "terraform.tfstate" ]] ||
			die "acceptance requires the default local backend; remove cached nonlocal metadata from $root"
	fi
}

export PATH="/usr/local/sbin:/opt/homebrew/sbin:$PATH"
export AWS_REGION="$region"
export AWS_DEFAULT_REGION="$region"
export AWS_PAGER=""

require_command jq
assert_clean_terraform_environment
for root in "${state_roots[@]}"; do
	assert_isolated_terraform_root "$root"
done

for command in aws "$engine" go kubectl openvpn curl jq openssl tar make tflint trivy; do
	require_command "$command"
done
command -v sha256sum >/dev/null 2>&1 || require_command shasum
[[ -z "$connect_cli" || -x "$connect_cli" ]] || die "OpenVPN Connect CLI is not executable: $connect_cli"

assert_account_scope() {
	local scoped_account
	scoped_account="$(aws sts get-caller-identity --region "$region" --query Account --output text)" || return 1
	if [[ "$scoped_account" != "$account_id" ]]; then
		printf 'error: refusing AWS account %s; expected %s\n' "$scoped_account" "$account_id" >&2
		return 1
	fi
}

assert_account_scope || die "unable to verify the explicitly supplied AWS account"

e2e_name="unrealops-e2e-$run_id"
network_name="unrealops-network-$run_id"
vpn_name="unrealops-vpn-$run_id"
for selector in "Environment=$e2e_name" "Test=$network_name" "Test=$vpn_name" \
	"ClusterName=$e2e_name" "karpenter.sh/discovery=$e2e_name"; do
	key="${selector%%=*}"
	value="${selector#*=}"
	owned_count="$(aws resourcegroupstaggingapi get-resources --region "$region" \
		--tag-filters "Key=$key,Values=$value" --query 'length(ResourceTagMappingList)' --output text)"
	[[ "$owned_count" == "0" ]] || die "run ID is not fresh; AWS still returns $owned_count resources for $selector"
done

# Provider default tags are not guaranteed to propagate through every
# launch-template-created OpenVPN resource. Refuse exact module ownership too,
# so a stale stack cannot be mistaken for a fresh run merely because its
# Environment/Test tag is absent or delayed in the tagging API.
for openvpn_name in "$e2e_name-openvpn" "$vpn_name-openvpn"; do
	owned_count="$(aws resourcegroupstaggingapi get-resources --region "$region" \
		--tag-filters "Key=Module,Values=openvpn" "Key=Name,Values=$openvpn_name" \
		--query 'length(ResourceTagMappingList)' --output text)"
	[[ "$owned_count" == "0" ]] ||
		die "run ID is not fresh; AWS still returns $owned_count exact OpenVPN resources for $openvpn_name"
done

stale_openvpn_asgs="$(aws autoscaling describe-auto-scaling-groups --region "$region" \
	--auto-scaling-group-names "$e2e_name-openvpn" "$vpn_name-openvpn" \
	--query 'AutoScalingGroups[].AutoScalingGroupName' --output text |
	tr '\t' '\n' | sed '/^$/d;/^None$/d')"
[[ -z "$stale_openvpn_asgs" ]] ||
	die "run ID is not fresh; exact OpenVPN Auto Scaling groups remain: $(tr '\n' ' ' <<<"$stale_openvpn_asgs")"

stale_openvpn_instances="$(aws ec2 describe-instances --region "$region" --filters \
	'Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped' \
	'Name=tag:Module,Values=openvpn' \
	"Name=tag:Name,Values=$e2e_name-openvpn,$vpn_name-openvpn" \
	--query 'Reservations[].Instances[].InstanceId' --output text |
	tr '\t' '\n' | sed '/^$/d;/^None$/d')"
[[ -z "$stale_openvpn_instances" ]] ||
	die "run ID is not fresh; active exact OpenVPN instances remain: $(tr '\n' ' ' <<<"$stale_openvpn_instances")"

az_count="$(aws ec2 describe-availability-zones --region "$region" \
	--filters Name=state,Values=available --query 'length(AvailabilityZones)' --output text)"
((az_count >= 3)) || die "$region has only $az_count available AZs; three are required"

state_is_empty() {
	local root="$1" state_file="$repo_root/$1/terraform.tfstate"
	[[ ! -f "$repo_root/$root/.terraform.tfstate.lock.info" ]] || return 1
	[[ ! -f "$state_file" ]] && return 0
	[[ "$(jq -er '[.resources[]? | select(.mode == "managed")] | length' "$state_file")" == "0" ]]
}

list_owned_asgs() {
	assert_account_scope || return 1
	aws autoscaling describe-auto-scaling-groups --region "$region" --output json |
		jq -r \
			--arg e2e "$e2e_name" \
			--arg network "$network_name" \
			--arg vpn "$vpn_name" \
			--arg e2e_openvpn "$e2e_name-openvpn" \
			--arg vpn_openvpn "$vpn_name-openvpn" '
        .AutoScalingGroups[]
        | select(
            .AutoScalingGroupName == $e2e_openvpn
            or .AutoScalingGroupName == $vpn_openvpn
            or (
              any(.Tags[]?; .Key == "Module" and .Value == "openvpn")
              and any(.Tags[]?;
                .Key == "Name" and (.Value == $e2e_openvpn or .Value == $vpn_openvpn))
            )
            or any(.Tags[]?;
              (.Key == "Environment" and .Value == $e2e)
              or (.Key == "Test" and (.Value == $network or .Value == $vpn))
              or (.Key == "ClusterName" and .Value == $e2e)
              or (.Key == "eks:cluster-name" and .Value == $e2e)
              or (.Key == "eks:eks-cluster-name" and .Value == $e2e)
              or (.Key == "aws:eks:cluster-name" and .Value == $e2e)
              or (.Key == "eks:nodegroup-name" and .Value == ($e2e + "-system"))
              or (.Key == ("kubernetes.io/cluster/" + $e2e))
              or (.Key == "karpenter.sh/discovery" and .Value == $e2e))
          )
        | .AutoScalingGroupName
      '
}

list_active_owned_instances() {
	assert_account_scope || return 1
	aws ec2 describe-instances --region "$region" --output json |
		jq -r \
			--arg e2e "$e2e_name" \
			--arg network "$network_name" \
			--arg vpn "$vpn_name" \
			--arg e2e_openvpn "$e2e_name-openvpn" \
			--arg vpn_openvpn "$vpn_name-openvpn" '
        .Reservations[].Instances[]
        | select(.State.Name != "terminated")
        | select(
            (
              any(.Tags[]?; .Key == "Module" and .Value == "openvpn")
              and any(.Tags[]?;
                .Key == "Name" and (.Value == $e2e_openvpn or .Value == $vpn_openvpn))
            )
            or any(.Tags[]?;
              (.Key == "Environment" and .Value == $e2e)
              or (.Key == "Test" and (.Value == $network or .Value == $vpn))
              or (.Key == "ClusterName" and .Value == $e2e)
              or (.Key == "eks:cluster-name" and .Value == $e2e)
              or (.Key == "eks:eks-cluster-name" and .Value == $e2e)
              or (.Key == "aws:eks:cluster-name" and .Value == $e2e)
              or (.Key == "eks:nodegroup-name" and .Value == ($e2e + "-system"))
              or (.Key == ("kubernetes.io/cluster/" + $e2e))
              or (.Key == "karpenter.sh/discovery" and .Value == $e2e))
          )
        | .InstanceId
      '
}

cleanup_invariants_met() {
	local root owned_asgs active_instances
	for root in "${state_roots[@]}"; do
		state_is_empty "$root" || return 1
	done
	owned_asgs="$(list_owned_asgs)" || return 1
	active_instances="$(list_active_owned_instances)" || return 1
	[[ -z "$owned_asgs" && -z "$active_instances" ]]
}

wait_for_owned_compute_cleanup() {
	local deadline=$((SECONDS + 900)) owned_asgs active_instances
	while :; do
		owned_asgs="$(list_owned_asgs)" || return 1
		active_instances="$(list_active_owned_instances)" || return 1
		if [[ -z "$owned_asgs" && -z "$active_instances" ]]; then
			return 0
		fi
		if ((SECONDS >= deadline)); then
			[[ -z "$owned_asgs" ]] ||
				printf 'cleanup incomplete: exact run-owned Auto Scaling groups remain:\n%s\n' "$owned_asgs" >&2
			[[ -z "$active_instances" ]] ||
				printf 'cleanup incomplete: active exact run-owned EC2 instances remain:\n%s\n' \
					"$active_instances" >&2
			return 1
		fi
		printf 'Waiting for exact run-owned Auto Scaling groups and EC2 instances to disappear...\n' >&2
		sleep 15
	done
}

for root in "${state_roots[@]}"; do
	state_is_empty "$root" || die "managed resources or a state lock already exist in $root"
done

lock_dir="${TMPDIR:-/tmp}/unrealops-acceptance.lock"
mkdir "$lock_dir" 2>/dev/null || die "another acceptance wrapper appears to be running: $lock_dir"
audit_completed="false"
secrets_terminal="false"
secret_ids=()
kms_key_arn=""
kms_watch_pid=""
kms_watch_stop_file="$work_dir/.stop-kms-evidence-watch"
pki_env="acc-$run_id"
complete_pki_env="acc-$run_id-complete"
secret_name="unrealops/acceptance/$pki_env/openvpn"
complete_secret_name="unrealops/acceptance/$complete_pki_env/openvpn"

secret_absent() {
	local secret_id="$1" error_file
	error_file="$(mktemp)"
	if aws secretsmanager describe-secret --region "$region" --secret-id "$secret_id" >/dev/null 2>"$error_file"; then
		rm -f "$error_file"
		return 1
	fi
	if grep -q 'ResourceNotFoundException' "$error_file"; then
		rm -f "$error_file"
		return 0
	fi
	cat "$error_file" >&2
	rm -f "$error_file"
	return 1
}

reserve_secret() {
	local secret_id="$1" owner_key="$2" owner_value="$3" reservation_payload
	assert_account_scope || return 1
	reservation_payload="$(jq -nc --arg run_id "$run_id" \
		'{schema_version:"reservation",run_id:$run_id}')" || return 1
	aws secretsmanager create-secret --region "$region" \
		--name "$secret_id" \
		--description "Reserved exclusively for UnrealOps acceptance run $run_id" \
		--secret-string "$reservation_payload" \
		--tags "Key=ManagedBy,Value=Terratest" "Key=TestRunId,Value=$run_id" \
		"Key=$owner_key,Value=$owner_value" \
		--query ARN --output text
}

delete_secret() {
	local secret_id="$1"
	assert_account_scope || return 1
	if secret_absent "$secret_id"; then
		return 0
	fi
	aws secretsmanager delete-secret --region "$region" --secret-id "$secret_id" \
		--force-delete-without-recovery >/dev/null || return 1
	for _ in {1..60}; do
		secret_absent "$secret_id" && return 0
		sleep 10
	done
	printf 'error: secret still exists after deletion request: %s\n' "$secret_id" >&2
	return 1
}

capture_kms_evidence() {
	local candidate="" manifest_file="$work_dir/run-manifest.json"
	local state_file="$repo_root/terraform/examples/complete/foundation/terraform.tfstate"
	local manifest_tmp

	if [[ -n "$kms_key_arn" ]]; then
		return 0
	fi

	if [[ -f "$manifest_file" ]]; then
		candidate="$(jq -r '.cleanup_evidence.eks_kms_key.arn // .kms_key_arn // empty' "$manifest_file")" ||
			return 1
	fi
	if [[ -z "$candidate" && -f "$work_dir/acceptance.log" ]]; then
		candidate="$(sed -n 's/^.*UNREALOPS_ACCEPTANCE_KMS_KEY_ARN=//p' \
			"$work_dir/acceptance.log" | tail -1)"
	fi
	if [[ -z "$candidate" && -f "$state_file" ]]; then
		candidate="$(jq -r '
      first(
        .resources[]?
        | select(.mode == "managed" and .type == "aws_kms_key")
        | .instances[]?.attributes.arn
        | select(. != null and . != "")
      ) // empty
    ' "$state_file" 2>/dev/null)" || return 1
	fi

	[[ -n "$candidate" ]] || return 0
	if [[ "$candidate" != arn:*:kms:"$region":"$account_id":key/* ]]; then
		printf 'error: refusing KMS evidence outside account %s and region %s: %s\n' \
			"$account_id" "$region" "$candidate" >&2
		return 1
	fi

	kms_key_arn="$candidate"
	if [[ -f "$manifest_file" ]]; then
		manifest_tmp="$manifest_file.tmp"
		jq --arg kms_key_arn "$kms_key_arn" '
      del(.kms_key_arn)
      | .cleanup_evidence.eks_kms_key = {
          arn: $kms_key_arn,
          owner_type: "eks-cluster",
          owner_name: .names.e2e,
          captured_from: "terraform-output:cluster_kms_key_arn"
        }
    ' \
			"$manifest_file" >"$manifest_tmp" || return 1
		mv "$manifest_tmp" "$manifest_file" || return 1
	fi
}

watch_kms_evidence() {
	while [[ ! -e "$kms_watch_stop_file" ]]; do
		if capture_kms_evidence && [[ -n "$kms_key_arn" ]]; then
			return 0
		fi
		sleep 2
	done
}

stop_kms_evidence_watch() {
	if [[ -n "$kms_watch_pid" ]]; then
		: >"$kms_watch_stop_file"
		wait "$kms_watch_pid" 2>/dev/null || true
		kms_watch_pid=""
		rm -f "$kms_watch_stop_file"
	fi
}

on_exit() {
	local status=$? secret_id
	local -a audit_secret_args=()
	local -a audit_manifest_args=()
	trap - EXIT
	set +e
	stop_kms_evidence_watch
	if ! capture_kms_evidence; then
		printf 'KMS cleanup evidence could not be recovered; preserve %s and do not treat the audit as final.\n' \
			"$work_dir" >&2
	fi
	if [[ -f "$work_dir/run-manifest.json" ]]; then
		audit_manifest_args=(--manifest "$work_dir/run-manifest.json")
	fi
	if [[ "$secrets_terminal" == "false" && ${#secret_ids[@]} -gt 0 ]]; then
		if cleanup_invariants_met; then
			secrets_terminal="true"
			for secret_id in "${secret_ids[@]}"; do
				if ! delete_secret "$secret_id"; then
					secrets_terminal="false"
					printf 'Runtime secret could not be removed during exit cleanup: %s\n' "$secret_id" >&2
				fi
			done
		else
			printf 'Runtime secrets and PKI were preserved at %s because cleanup could not be proven.\n' \
				"$work_dir" >&2
		fi
	fi
	if [[ ${#secret_ids[@]} -gt 0 && "$audit_completed" == "false" &&
		-d "$work_dir" && -f "$work_dir/run-manifest.json" ]]; then
		for secret_id in "${secret_ids[@]}"; do
			audit_secret_args+=(--secret-id "$secret_id")
		done
		printf 'Running a final zero-wait cleanup audit after an unexpected exit.\n' >&2
		"$audit_script" --account-id "$account_id" --region "$region" --run-id "$run_id" \
			"${audit_secret_args[@]}" "${audit_manifest_args[@]}" --wait-seconds 0 \
			2>&1 | tee -a "$work_dir/cleanup-audit.log"
	elif [[ ${#secret_ids[@]} -gt 0 && "$audit_completed" == "false" && -d "$work_dir" ]]; then
		printf 'Cleanup audit skipped because a run manifest was not established; pre-test secret cleanup was attempted directly.\n' >&2
	fi
	rmdir "$lock_dir" 2>/dev/null || true
	exit "$status"
}
trap on_exit EXIT

for secret_id in "$secret_name" "$complete_secret_name"; do
	secret_absent "$secret_id" || die "runtime secret already exists or cannot be proven absent: $secret_id"
done

[[ ! -e "$work_dir" ]] || die "work directory already exists: $work_dir"
mkdir -p "$work_dir"
chmod 0700 "$work_dir"

cd "$repo_root"

# Never allow inherited live-test authorization or fixture paths to turn the
# static validation phase into a billable acceptance run.
live_test_variables=(
	TF_ACC
	TERRAFORM_BINARY
	TEST_AWS_ACCOUNT_ID
	TEST_RUN_ID
	TEST_OPENVPN_PKI_ENV
	TEST_OPENVPN_CLIENT_NAME
	TEST_OPENVPN_RUNTIME_SECRET_ARN
	TEST_OPENVPN_PROFILE
	TEST_OPENVPN_CONTROL_PROFILE
	TEST_COMPLETE_OPENVPN_RUNTIME_SECRET_ARN
	TEST_COMPLETE_OPENVPN_PROFILE
	TEST_OPENVPN_CONNECT_CLI
)
for variable in "${live_test_variables[@]}"; do
	unset "$variable"
done

MAKEFLAGS='' MFLAGS='' GNUMAKEFLAGS='' MAKEOVERRIDES='' TF_ACC='' TERRAFORM_BINARY='' \
	make check ENGINE="$engine"
make security

pass_in="$work_dir/easyrsa-pass-in"
pass_out="$work_dir/easyrsa-pass-out"
openssl rand -out "$pass_in" -hex 32
cp "$pass_in" "$pass_out"
chmod 0600 "$pass_in" "$pass_out"

export OPENVPN_PKI_ROOT="$work_dir/pki"
export EASYRSA_BATCH=1
export EASYRSA_PASSIN="file:$pass_in"
export EASYRSA_PASSOUT="file:$pass_out"

reserved_secret_arn="$(reserve_secret "$secret_name" Test "$vpn_name")" ||
	die "failed to reserve runtime secret atomically: $secret_name"
secret_ids+=("$reserved_secret_arn")
reserved_complete_secret_arn="$(reserve_secret "$complete_secret_name" Environment "$e2e_name")" ||
	die "failed to reserve runtime secret atomically: $complete_secret_name"
secret_ids+=("$reserved_complete_secret_arn")

jq -n \
	--arg account_id "$account_id" --arg region "$region" --arg engine "$engine" --arg run_id "$run_id" \
	--arg pki_root "$OPENVPN_PKI_ROOT" --arg e2e_name "$e2e_name" \
	--arg network_name "$network_name" --arg vpn_name "$vpn_name" \
	--arg secret_name "$secret_name" --arg complete_secret_name "$complete_secret_name" \
	--arg secret_arn "$reserved_secret_arn" --arg complete_secret_arn "$reserved_complete_secret_arn" \
	'{
    account_id:$account_id,
    region:$region,
    engine:$engine,
    run_id:$run_id,
    pki_root:$pki_root,
    names:{e2e:$e2e_name,network:$network_name,openvpn:$vpn_name},
    secret_names:{openvpn:$secret_name,complete:$complete_secret_name},
    secret_arn:$secret_arn,
    complete_secret_arn:$complete_secret_arn
  }' \
	>"$work_dir/run-manifest.json"

assert_account_scope || die "AWS account changed before OpenVPN runtime upload"
scripts/openvpn-pki.sh init --environment "$pki_env" --region "$region" --secret-id "$reserved_secret_arn"
scripts/openvpn-pki.sh client --environment "$pki_env" --name revoked-user --endpoint 127.0.0.1
scripts/openvpn-pki.sh client --environment "$pki_env" --name control-user --endpoint 127.0.0.1

assert_account_scope || die "AWS account changed before complete-stack OpenVPN runtime upload"
scripts/openvpn-pki.sh init --environment "$complete_pki_env" --region "$region" \
	--secret-id "$reserved_complete_secret_arn"
scripts/openvpn-pki.sh client --environment "$complete_pki_env" --name complete-user --endpoint 127.0.0.1

secret_arn="$(jq -er '.secret_id' "$OPENVPN_PKI_ROOT/$pki_env/metadata.json")"
complete_secret_arn="$(jq -er '.secret_id' "$OPENVPN_PKI_ROOT/$complete_pki_env/metadata.json")"
[[ "$secret_arn" == "$reserved_secret_arn" ]] || die "OpenVPN runtime secret ownership changed unexpectedly"
[[ "$complete_secret_arn" == "$reserved_complete_secret_arn" ]] ||
	die "complete-stack OpenVPN runtime secret ownership changed unexpectedly"

export TF_ACC=1
export TERRAFORM_BINARY="$engine"
export TEST_AWS_ACCOUNT_ID="$account_id"
export TEST_RUN_ID="$run_id"
export TEST_OPENVPN_PKI_ENV="$pki_env"
export TEST_OPENVPN_CLIENT_NAME="revoked-user"
export TEST_OPENVPN_RUNTIME_SECRET_ARN="$secret_arn"
export TEST_OPENVPN_PROFILE="$OPENVPN_PKI_ROOT/$pki_env/profiles/revoked-user.ovpn"
export TEST_OPENVPN_CONTROL_PROFILE="$OPENVPN_PKI_ROOT/$pki_env/profiles/control-user.ovpn"
export TEST_COMPLETE_OPENVPN_RUNTIME_SECRET_ARN="$complete_secret_arn"
export TEST_COMPLETE_OPENVPN_PROFILE="$OPENVPN_PKI_ROOT/$complete_pki_env/profiles/complete-user.ovpn"
if [[ -n "$connect_cli" ]]; then
	export TEST_OPENVPN_CONNECT_CLI="$connect_cli"
fi

rm -f "$kms_watch_stop_file"
watch_kms_evidence &
kms_watch_pid=$!
set +e
make test-live ENGINE="$engine" 2>&1 | tee "$work_dir/acceptance.log"
test_pipeline_status=("${PIPESTATUS[@]}")
set -e
stop_kms_evidence_watch
test_status="${test_pipeline_status[0]}"
test_log_status="${test_pipeline_status[1]}"
if ((test_log_status != 0)); then
	printf 'Acceptance log could not be written to %s (tee exit %d).\n' \
		"$work_dir/acceptance.log" "$test_log_status" >&2
	test_status=1
fi

if ! capture_kms_evidence || [[ -z "$kms_key_arn" ]]; then
	printf 'Run-linked EKS KMS evidence is unavailable; cleanup will continue, but the final audit must remain non-passing.\n' >&2
fi

states_clean="true"
for root in "${state_roots[@]}"; do
	if ! state_is_empty "$root"; then
		printf 'cleanup incomplete: state remains in %s\n' "$root" >&2
		states_clean="false"
	fi
done

inventory_clean="false"
if [[ "$states_clean" == "true" ]]; then
	if wait_for_owned_compute_cleanup; then
		inventory_clean="true"
	else
		printf 'cleanup incomplete: exact run-owned compute could not be proven absent within 900 seconds\n' >&2
	fi
else
	printf 'Skipping the compute-cleanup wait because managed-resource state is not empty.\n' >&2
fi

cleanup_ready="false"
secret_cleanup_status=0
audit_wait_seconds=0
if [[ "$states_clean" == "true" && "$inventory_clean" == "true" ]]; then
	cleanup_ready="true"
	audit_wait_seconds=900
	if ! delete_secret "$secret_arn"; then
		secret_cleanup_status=1
	fi
	if ! delete_secret "$complete_secret_arn"; then
		secret_cleanup_status=1
	fi
	if ((secret_cleanup_status == 0)); then
		secrets_terminal="true"
	fi
else
	printf 'Runtime secrets and PKI were preserved at %s for recovery.\n' "$work_dir" >&2
fi

set +e
"$audit_script" --account-id "$account_id" --region "$region" --run-id "$run_id" \
	--manifest "$work_dir/run-manifest.json" \
	--secret-id "$secret_arn" --secret-id "$complete_secret_arn" \
	--wait-seconds "$audit_wait_seconds" \
	2>&1 | tee "$work_dir/cleanup-audit.log"
audit_pipeline_status=("${PIPESTATUS[@]}")
set -e
audit_status="${audit_pipeline_status[0]}"
audit_log_status="${audit_pipeline_status[1]}"
audit_completed="true"
if ((audit_log_status != 0)); then
	printf 'Cleanup audit log could not be written to %s (tee exit %d).\n' \
		"$work_dir/cleanup-audit.log" "$audit_log_status" >&2
	audit_status=1
fi

if ((test_status != 0)); then
	printf 'Acceptance assertions failed (exit %d); cleanup audit exit was %d. Logs and PKI remain at %s.\n' \
		"$test_status" "$audit_status" "$work_dir" >&2
	exit "$test_status"
fi
if [[ "$cleanup_ready" != "true" ]]; then
	printf 'Acceptance tests finished but cleanup prerequisites were not met; preserve %s and recover before rerunning.\n' \
		"$work_dir" >&2
	exit 1
fi
if ((secret_cleanup_status != 0)); then
	printf 'Acceptance tests finished but one or more runtime secrets could not be removed; inspect %s.\n' \
		"$work_dir/cleanup-audit.log" >&2
	exit 1
fi
if ((audit_status != 0)); then
	printf 'Acceptance tests passed but cleanup audit failed; preserve %s and recover before rerunning.\n' "$work_dir" >&2
	exit "$audit_status"
fi

printf 'Acceptance tests and cleanup audit passed. Remove the test-only PKI when logs are no longer needed: %s\n' "$work_dir"
