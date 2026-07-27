#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Read-only audit for one UnrealOps acceptance run.

Usage:
  audit-acceptance-cleanup.sh --account-id 123456789012 --region us-west-2 \
    --run-id tofu-12345 (--manifest PATH | --kms-key-id ID_OR_ARN) \
    [--secret-id NAME_OR_ARN ...] \
    [--wait-seconds 0]

Prefer --manifest. A direct --kms-key-id is accepted only when the key retains
an exact ownership tag for this run. A manifest without KMS evidence still
audits all other resources, but the result remains non-passing.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 2
}

account_id=""
region=""
run_id=""
manifest_path=""
kms_key_id=""
kms_evidence_mode=""
expected_kms_arn=""
wait_seconds=0
secret_ids=()

while (($#)); do
	case "$1" in
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
	--manifest)
		manifest_path="${2:-}"
		shift 2
		;;
	--secret-id)
		secret_ids+=("${2:-}")
		shift 2
		;;
	--kms-key-id)
		kms_key_id="${2:-}"
		shift 2
		;;
	--wait-seconds)
		wait_seconds="${2:-}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

[[ "$account_id" =~ ^[0-9]{12}$ ]] || die "--account-id must be exactly 12 digits"
[[ -n "$region" ]] || die "--region is required; region defaults are forbidden"
[[ ${#run_id} -le 16 && "$run_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid --run-id"
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a nonnegative integer"
command -v aws >/dev/null 2>&1 || die "aws is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

e2e="unrealops-e2e-$run_id"
network="unrealops-network-$run_id"
vpn="unrealops-vpn-$run_id"

if [[ -n "$manifest_path" ]]; then
	[[ -r "$manifest_path" ]] || die "--manifest is not readable: $manifest_path"
	manifest_account="$(jq -er '.account_id' "$manifest_path")" || die "manifest is missing account_id"
	manifest_region="$(jq -er '.region' "$manifest_path")" || die "manifest is missing region"
	manifest_run_id="$(jq -er '.run_id' "$manifest_path")" || die "manifest is missing run_id"
	manifest_e2e="$(jq -er '.names.e2e' "$manifest_path")" || die "manifest is missing names.e2e"
	[[ "$manifest_account" == "$account_id" ]] || die "manifest account does not match --account-id"
	[[ "$manifest_region" == "$region" ]] || die "manifest region does not match --region"
	[[ "$manifest_run_id" == "$run_id" ]] || die "manifest run_id does not match --run-id"
	[[ "$manifest_e2e" == "$e2e" ]] || die "manifest EKS owner does not match this run"

	manifest_kms_key_id="$(jq -r --arg owner "$e2e" '
    .cleanup_evidence.eks_kms_key
    | select(.owner_type == "eks-cluster")
    | select(.owner_name == $owner)
    | select(.captured_from == "terraform-output:cluster_kms_key_arn")
    | .arn
    | select(type == "string" and length > 0)
  ' "$manifest_path")" || die "could not parse run-linked EKS KMS cleanup evidence"
	if [[ -n "$manifest_kms_key_id" ]]; then
		IFS=: read -r marker_arn marker_partition marker_service marker_region marker_account marker_resource \
			<<<"$manifest_kms_key_id"
		[[ "$marker_arn" == "arn" && -n "$marker_partition" &&
			"$marker_service" == "kms" && "$marker_region" == "$region" &&
			"$marker_account" == "$account_id" && "$marker_resource" == key/?* ]] ||
			die "manifest KMS evidence points outside the authorized account/region"
	fi
	if [[ -n "$kms_key_id" && "$kms_key_id" != "$manifest_kms_key_id" ]]; then
		die "--kms-key-id does not match the run-linked manifest marker"
	fi
	if [[ -n "$manifest_kms_key_id" ]]; then
		kms_key_id="$manifest_kms_key_id"
		kms_evidence_mode="manifest"
	else
		kms_evidence_mode="missing"
	fi
elif [[ -n "$kms_key_id" ]]; then
	kms_evidence_mode="tags"
else
	die "KMS cleanup evidence is mandatory; supply --manifest or --kms-key-id"
fi

export AWS_REGION="$region"
export AWS_DEFAULT_REGION="$region"
export AWS_PAGER=""
actual_account="$(aws sts get-caller-identity --region "$region" --query Account --output text)" ||
	die "could not verify the explicitly supplied AWS account"
[[ "$actual_account" == "$account_id" ]] || die "refusing AWS account $actual_account; expected $account_id"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
[[ ${#secret_ids[@]} -gt 0 ]] || secret_ids=(
	"unrealops/acceptance/acc-$run_id/openvpn"
	"unrealops/acceptance/acc-$run_id-complete/openvpn"
)

state_roots=(
	terraform/examples/complete/foundation
	terraform/examples/complete/addons
	terraform/tests/fixtures/openvpn
	terraform/tests/fixtures/network
)
selectors=(
	"Environment=$e2e"
	"Test=$network"
	"Test=$vpn"
	"ClusterName=$e2e"
	"karpenter.sh/discovery=$e2e"
	"eks:cluster-name=$e2e"
	"eks:eks-cluster-name=$e2e"
	"aws:eks:cluster-name=$e2e"
	"kubernetes.io/cluster/$e2e=owned"
	"kubernetes.io/cluster/$e2e=shared"
)

findings_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -f "$findings_file" "$error_file"' EXIT

record() {
	printf '%s\n' "$*" >>"$findings_file"
}

record_output() {
	local label="$1" output="$2"
	output="$(tr '\t' '\n' <<<"$output" | sed '/^$/d;/^None$/d' | sort -u)"
	[[ -z "$output" ]] || record "$label: $(tr '\n' ' ' <<<"$output")"
}

has_ownership_tag() {
	jq -e --arg e2e "$e2e" --arg network "$network" --arg vpn "$vpn" '
    (
      any(.Tags[]?;
        (.Key == "Environment" and .Value == $e2e) or
        (.Key == "Test" and (.Value == $network or .Value == $vpn)) or
        (.Key == "ClusterName" and .Value == $e2e) or
        (.Key == "karpenter.sh/discovery" and .Value == $e2e) or
        (.Key == "eks:cluster-name" and .Value == $e2e) or
        (.Key == "eks:eks-cluster-name" and .Value == $e2e) or
        (.Key == "aws:eks:cluster-name" and .Value == $e2e) or
        (.Key == ("kubernetes.io/cluster/" + $e2e) and
          (.Value == "owned" or .Value == "shared"))
      )
    ) or (
      .tags.Environment? == $e2e or
      .tags.Test? == $network or
      .tags.Test? == $vpn or
      .tags.ClusterName? == $e2e or
      .tags["karpenter.sh/discovery"]? == $e2e or
      .tags["eks:cluster-name"]? == $e2e or
      .tags["eks:eks-cluster-name"]? == $e2e or
      .tags["aws:eks:cluster-name"]? == $e2e or
      (.tags["kubernetes.io/cluster/" + $e2e]? == "owned" or
        .tags["kubernetes.io/cluster/" + $e2e]? == "shared")
    )
  ' >/dev/null
}

has_exact_eks_owner_tag() {
	jq -e --arg e2e "$e2e" '
    any(.Tags[]?;
      (.TagKey == "Environment" and .TagValue == $e2e) or
      (.TagKey == "ClusterName" and .TagValue == $e2e) or
      (.TagKey == "karpenter.sh/discovery" and .TagValue == $e2e)
    )
  ' >/dev/null
}

audit_expected_kms_key() {
	local output state enabled deletion_date key_arn tags
	local arn_prefix partition service key_region key_account key_resource

	if [[ "$kms_evidence_mode" == "missing" ]]; then
		record "manifest lacks run-linked EKS KMS cleanup evidence"
		return
	fi

	if output="$(aws kms describe-key --region "$region" --key-id "$kms_key_id" 2>"$error_file")"; then
		key_arn="$(jq -er '.KeyMetadata.Arn' <<<"$output")" || die "KMS response is missing KeyMetadata.Arn"
		state="$(jq -er '.KeyMetadata.KeyState' <<<"$output")" || die "KMS response is missing KeyMetadata.KeyState"
		enabled="$(jq -er '.KeyMetadata.Enabled | if type == "boolean" then tostring else error("missing boolean") end' <<<"$output")" || die "KMS response is missing KeyMetadata.Enabled"
		deletion_date="$(jq -r '.KeyMetadata.DeletionDate // empty' <<<"$output")" || die "could not parse KMS deletion date"
		expected_kms_arn="$key_arn"

		IFS=: read -r arn_prefix partition service key_region key_account key_resource <<<"$key_arn"
		if [[ "$arn_prefix" != "arn" || -z "$partition" || "$service" != "kms" ||
			"$key_region" != "$region" || "$key_account" != "$account_id" || "$key_resource" != key/* ]]; then
			record "KMS cleanup evidence points outside the authorized account/region: $key_arn"
		elif [[ "$kms_evidence_mode" == "manifest" && "$key_arn" != "$kms_key_id" ]]; then
			record "manifest KMS ARN resolved to a different key: expected=$kms_key_id actual=$key_arn"
		elif [[ "$kms_evidence_mode" == "tags" ]]; then
			tags="$(aws kms list-resource-tags --region "$region" --key-id "$key_arn" --output json)" ||
				die "could not enumerate ownership tags for KMS key: $key_arn"
			if ! has_exact_eks_owner_tag <<<"$tags"; then
				record "explicit KMS key lacks an exact run ownership tag: $key_arn"
			elif [[ "$state" == "PendingDeletion" && "$enabled" == "false" && -n "$deletion_date" ]]; then
				printf 'Expected scheduled KMS remnant: %s deletion=%s\n' "$key_arn" "$deletion_date"
			else
				record "KMS key is not safely pending deletion: $key_arn state=$state enabled=$enabled"
			fi
		elif [[ "$state" == "PendingDeletion" && "$enabled" == "false" && -n "$deletion_date" ]]; then
			printf 'Expected scheduled KMS remnant: %s deletion=%s\n' "$key_arn" "$deletion_date"
		else
			record "KMS key is not safely pending deletion: $key_arn state=$state enabled=$enabled"
		fi
	elif grep -q 'NotFoundException' "$error_file"; then
		if [[ "$kms_evidence_mode" == "manifest" ]]; then
			expected_kms_arn="$kms_key_id"
			printf 'Run-linked KMS key is fully deleted: %s\n' "$kms_key_id"
		else
			record "explicit KMS key could not be found, so ownership tags cannot be verified: $kms_key_id"
		fi
	else
		cat "$error_file" >&2
		die "could not audit KMS key: $kms_key_id"
	fi
}

check_tagged_resources() {
	local selector="$1"
	local key="${selector%%=*}" value="${selector#*=}" arns arn secret_id secret_resource expected_secret
	arns="$(aws resourcegroupstaggingapi get-resources --region "$region" \
		--tag-filters "Key=$key,Values=$value" --query 'ResourceTagMappingList[].ResourceARN' --output text)" ||
		die "could not enumerate resources tagged $selector"
	for arn in $arns; do
		if [[ -n "$expected_kms_arn" && "$arn" == "$expected_kms_arn" ]]; then
			continue
		fi
		expected_secret=false
		if [[ "$arn" == arn:*:secretsmanager:*:secret:* ]]; then
			secret_resource="${arn#*:secret:}"
			for secret_id in "${secret_ids[@]}"; do
				if [[ "$secret_id" == "$arn" || "$secret_resource" == "$secret_id"-?????? ]]; then
					expected_secret=true
					break
				fi
			done
		fi
		if [[ "$expected_secret" == "true" ]]; then
			continue
		fi
		if [[ "$arn" == arn:*:kms:* ]]; then
			record "unexpected run-owned KMS key remains ($selector): $arn"
		else
			record "tagged resource remains ($selector): $arn"
		fi
	done
}

check_ec2_owner() {
	local key="$1" value="$2" output
	output="$(aws ec2 describe-instances --region "$region" --filters \
		"Name=tag:$key,Values=$value" 'Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped' \
		--query 'Reservations[].Instances[].InstanceId' --output text)" || die "could not enumerate EC2 instances for $key=$value"
	record_output "active EC2 instances ($key=$value)" "$output"

	output="$(aws ec2 describe-volumes --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'Volumes[].VolumeId' --output text)" || die "could not enumerate EBS volumes for $key=$value"
	record_output "EBS volumes ($key=$value)" "$output"
	output="$(aws ec2 describe-vpcs --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'Vpcs[].VpcId' --output text)" || die "could not enumerate VPCs for $key=$value"
	record_output "VPCs ($key=$value)" "$output"
	output="$(aws ec2 describe-nat-gateways --region "$region" --filter "Name=tag:$key,Values=$value" --output json |
		jq -r '.NatGateways[] | select(.State != "deleted") | .NatGatewayId')" ||
		die "could not enumerate NAT gateways for $key=$value"
	record_output "NAT gateways ($key=$value)" "$output"
	output="$(aws ec2 describe-addresses --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'Addresses[].AllocationId' --output text)" || die "could not enumerate Elastic IPs for $key=$value"
	record_output "Elastic IPs ($key=$value)" "$output"
	output="$(aws ec2 describe-launch-templates --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'LaunchTemplates[].LaunchTemplateId' --output text)" || die "could not enumerate launch templates for $key=$value"
	record_output "launch templates ($key=$value)" "$output"
	output="$(aws ec2 describe-vpc-endpoints --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'VpcEndpoints[].VpcEndpointId' --output text)" || die "could not enumerate VPC endpoints for $key=$value"
	record_output "VPC endpoints ($key=$value)" "$output"
	output="$(aws ec2 describe-subnets --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'Subnets[].SubnetId' --output text)" || die "could not enumerate subnets for $key=$value"
	record_output "subnets ($key=$value)" "$output"
	output="$(aws ec2 describe-route-tables --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'RouteTables[].RouteTableId' --output text)" || die "could not enumerate route tables for $key=$value"
	record_output "route tables ($key=$value)" "$output"
	output="$(aws ec2 describe-internet-gateways --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'InternetGateways[].InternetGatewayId' --output text)" || die "could not enumerate internet gateways for $key=$value"
	record_output "internet gateways ($key=$value)" "$output"
	output="$(aws ec2 describe-network-interfaces --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" || die "could not enumerate network interfaces for $key=$value"
	record_output "network interfaces ($key=$value)" "$output"
	output="$(aws ec2 describe-security-groups --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'SecurityGroups[].GroupId' --output text)" || die "could not enumerate security groups for $key=$value"
	record_output "security groups ($key=$value)" "$output"
	output="$(aws ec2 describe-flow-logs --region "$region" --filter "Name=tag:$key,Values=$value" \
		--query 'FlowLogs[].FlowLogId' --output text)" || die "could not enumerate VPC flow logs for $key=$value"
	record_output "VPC flow logs ($key=$value)" "$output"
	output="$(aws ec2 describe-managed-prefix-lists --region "$region" --filters "Name=tag:$key,Values=$value" \
		--query 'PrefixLists[].PrefixListId' --output text)" || die "could not enumerate managed prefix lists for $key=$value"
	record_output "managed prefix lists ($key=$value)" "$output"
}

check_autoscaling_groups() {
	local output
	output="$(aws autoscaling describe-auto-scaling-groups --region "$region" --output json | jq -r \
		--arg e2e "$e2e" --arg network "$network" --arg vpn "$vpn" \
		--arg e2e_openvpn "$e2e-openvpn" --arg vpn_openvpn "$vpn-openvpn" '
      .AutoScalingGroups[]
      | select(
          any(.Tags[]?;
            (.Key == "Environment" and .Value == $e2e) or
            (.Key == "Test" and (.Value == $network or .Value == $vpn)) or
            (.Key == "ClusterName" and .Value == $e2e) or
            (.Key == "karpenter.sh/discovery" and .Value == $e2e) or
            (.Key == "eks:cluster-name" and .Value == $e2e) or
            (.Key == "eks:eks-cluster-name" and .Value == $e2e) or
            (.Key == "aws:eks:cluster-name" and .Value == $e2e) or
            (.Key == "eks:nodegroup-name" and .Value == ($e2e + "-system")) or
            (.Key == ("kubernetes.io/cluster/" + $e2e) and
              (.Value == "owned" or .Value == "shared"))
          ) or (
            any(.Tags[]?; .Key == "Module" and .Value == "openvpn") and
            any(.Tags[]?; .Key == "Name" and (.Value == $e2e_openvpn or .Value == $vpn_openvpn))
          )
        )
      | .AutoScalingGroupName
    ')" || die "could not enumerate ownership-tagged Auto Scaling groups"
	record_output "ownership-tagged Auto Scaling groups" "$output"
}

check_openvpn_network_interfaces() {
	local vpcs_json groups_json owned_vpc_ids owned_groups group_id vpc_id output

	vpcs_json="$(aws ec2 describe-vpcs --region "$region" --output json)" ||
		die "could not enumerate VPCs for OpenVPN ENI ownership"
	owned_vpc_ids="$(jq -r --arg e2e "$e2e" --arg vpn "$vpn" '
    .Vpcs[]
    | select(any(.Tags[]?;
        (.Key == "Environment" and .Value == $e2e) or
        (.Key == "Test" and .Value == $vpn)
      ))
    | .VpcId
  ' <<<"$vpcs_json")" || die "could not parse run-owned VPCs"

	groups_json="$(aws ec2 describe-security-groups --region "$region" \
		--filters 'Name=tag:Module,Values=openvpn' --output json)" ||
		die "could not enumerate OpenVPN security groups"
	owned_groups="$(jq -r --arg e2e "$e2e" --arg vpn "$vpn" '
    .SecurityGroups[]
    | select(
        any(.Tags[]?; .Key == "Module" and .Value == "openvpn") and
        any(.Tags[]?;
          (.Key == "Environment" and .Value == $e2e) or
          (.Key == "Test" and .Value == $vpn)
        )
      )
    | [.GroupId, .VpcId]
    | @tsv
  ' <<<"$groups_json")" || die "could not parse run-owned OpenVPN security groups"

	while IFS=$'\t' read -r group_id vpc_id; do
		[[ -n "$group_id" && -n "$vpc_id" ]] || continue
		if ! grep --fixed-strings --line-regexp --quiet -- "$vpc_id" <<<"$owned_vpc_ids"; then
			record "OpenVPN security group is outside the exact run-owned VPC inventory: $group_id vpc=$vpc_id"
			continue
		fi
		output="$(aws ec2 describe-network-interfaces --region "$region" --filters \
			"Name=group-id,Values=$group_id" "Name=vpc-id,Values=$vpc_id" \
			--query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ||
			die "could not enumerate OpenVPN ENIs for security group $group_id"
		record_output "OpenVPN network interfaces (security-group=$group_id vpc=$vpc_id)" "$output"
	done <<<"$owned_groups"
}

check_tagged_log_groups() {
	local prefix name arn tags log_groups
	for prefix in "/aws/eks/" "/unrealops/" "/aws/vpc-flow-log/"; do
		log_groups="$(aws logs describe-log-groups --region "$region" --log-group-name-prefix "$prefix" --output json |
			jq -r '.logGroups[] | [.logGroupName, ((.logGroupArn // .arn) | sub(":\\*$"; ""))] | @tsv')" ||
			die "could not enumerate CloudWatch log groups with prefix $prefix"
		while IFS=$'\t' read -r name arn; do
			[[ -n "$name" && -n "$arn" ]] || continue
			tags="$(aws logs list-tags-for-resource --region "$region" --resource-arn "$arn" --output json)" ||
				die "could not enumerate tags for CloudWatch log group $name"
			if has_ownership_tag <<<"$tags"; then
				record "ownership-tagged CloudWatch log group remains: $name"
			fi
		done <<<"$log_groups"
	done
}

is_expected_role_name() {
	local name="$1"
	[[ "$name" == "$e2e-openvpn" ||
		"$name" == "$vpn-openvpn" ||
		"$name" == "$e2e-ebs-csi" ||
		"$name" == "$e2e-karpenter-controller" ||
		"$name" == "$e2e-karpenter-node" ||
		"$name" == "$e2e-system-eks-node-group" ]]
}

is_exact_run_prefixed_iam_name() {
	local name="$1"
	[[ "$name" == "$e2e-"* ||
		"$name" == "$network-"* ||
		"$name" == "$vpn-"* ]]
}

is_tagged_iam_name_candidate() {
	local name="$1"
	[[ "$name" == vpc-flow-log-role-* ||
		"$name" == vpc-flow-log-to-cloudwatch-* ]]
}

is_karpenter_generated_instance_profile_name() {
	local name="$1"
	[[ "$name" == "${e2e}_"?* ]]
}

is_expected_instance_profile_name() {
	local name="$1"
	[[ "$name" == "$e2e-openvpn" ||
		"$name" == "$vpn-openvpn" ||
		"$name" == "$e2e-system-eks-node-group" ]]
}

check_iam_resources() {
	local name arn tags resources

	resources="$(aws iam list-roles --region "$region" --output json |
		jq -r '.Roles[] | [.RoleName,.Arn] | @tsv')" || die "could not enumerate IAM roles"
	while IFS=$'\t' read -r name arn; do
		[[ -n "$name" ]] || continue
		if is_expected_role_name "$name" || is_exact_run_prefixed_iam_name "$name"; then
			record "exact run-owned IAM role remains: $arn"
		elif is_tagged_iam_name_candidate "$name"; then
			tags="$(aws iam list-role-tags --region "$region" --role-name "$name" --output json)" ||
				die "could not enumerate tags for IAM role $name"
			if has_ownership_tag <<<"$tags"; then
				record "ownership-tagged IAM role remains: $arn"
			fi
		fi
	done <<<"$resources"

	resources="$(aws iam list-instance-profiles --region "$region" --output json |
		jq -r '.InstanceProfiles[] | [.InstanceProfileName,.Arn] | @tsv')" ||
		die "could not enumerate IAM instance profiles"
	while IFS=$'\t' read -r name arn; do
		[[ -n "$name" ]] || continue
		if is_expected_instance_profile_name "$name" || is_exact_run_prefixed_iam_name "$name"; then
			record "exact run-owned IAM instance profile remains: $arn"
		elif is_karpenter_generated_instance_profile_name "$name"; then
			tags="$(aws iam list-instance-profile-tags --region "$region" \
				--instance-profile-name "$name" --output json)" ||
				die "could not enumerate tags for IAM instance profile $name"
			if has_ownership_tag <<<"$tags"; then
				if is_karpenter_generated_instance_profile_name "$name"; then
					record "ownership-tagged Karpenter-generated IAM instance profile remains: $arn"
				else
					record "ownership-tagged IAM instance profile remains: $arn"
				fi
			fi
		fi
	done <<<"$resources"

	resources="$(aws iam list-policies --region "$region" --scope Local --output json |
		jq -r '.Policies[] | [.PolicyName,.Arn] | @tsv')" ||
		die "could not enumerate customer-managed IAM policies"
	while IFS=$'\t' read -r name arn; do
		[[ -n "$name" ]] || continue
		if is_exact_run_prefixed_iam_name "$name"; then
			record "exact run-owned customer-managed IAM policy remains: $arn"
		elif is_tagged_iam_name_candidate "$name"; then
			tags="$(aws iam list-policy-tags --region "$region" --policy-arn "$arn" --output json)" ||
				die "could not enumerate tags for customer-managed IAM policy $arn"
			if has_ownership_tag <<<"$tags"; then
				record "ownership-tagged customer-managed IAM policy remains: $arn"
			fi
		fi
	done <<<"$resources"

	resources="$(aws iam list-open-id-connect-providers --region "$region" --output json |
		jq -r '.OpenIDConnectProviderList[].Arn')" || die "could not enumerate IAM OIDC providers"
	while read -r arn; do
		[[ -n "$arn" ]] || continue
		tags="$(aws iam list-open-id-connect-provider-tags --region "$region" \
			--open-id-connect-provider-arn "$arn" --output json)" ||
			die "could not enumerate tags for IAM OIDC provider $arn"
		if has_ownership_tag <<<"$tags"; then
			record "ownership-tagged IAM OIDC provider remains: $arn"
		fi
	done <<<"$resources"
}

audit_once() {
	: >"$findings_file"
	local root state_file count output secret_id deleted_date alias_count aliases_output
	local name arn tags event_rules

	for root in "${state_roots[@]}"; do
		state_file="$repo_root/$root/terraform.tfstate"
		[[ ! -f "$repo_root/$root/.terraform.tfstate.lock.info" ]] || record "state lock remains: $root"
		if [[ -f "$state_file" ]]; then
			count="$(jq -er '[.resources[]? | select(.mode == "managed")] | length' "$state_file")" ||
				die "could not enumerate managed resources in Terraform state: $root"
			[[ "$count" == "0" ]] || record "Terraform state contains $count managed resources: $root"
		fi
	done

	audit_expected_kms_key
	for selector in "${selectors[@]}"; do
		check_tagged_resources "$selector"
	done
	check_ec2_owner Environment "$e2e"
	check_ec2_owner Test "$network"
	check_ec2_owner Test "$vpn"
	check_ec2_owner karpenter.sh/discovery "$e2e"
	check_ec2_owner ClusterName "$e2e"
	check_ec2_owner eks:cluster-name "$e2e"
	check_ec2_owner eks:eks-cluster-name "$e2e"
	check_ec2_owner aws:eks:cluster-name "$e2e"
	check_ec2_owner "kubernetes.io/cluster/$e2e" owned
	check_ec2_owner "kubernetes.io/cluster/$e2e" shared
	check_openvpn_network_interfaces

	if aws eks describe-cluster --region "$region" --name "$e2e" >/dev/null 2>"$error_file"; then
		record "EKS cluster remains: $e2e"
	elif ! grep -q 'ResourceNotFoundException' "$error_file"; then
		cat "$error_file" >&2
		die "could not audit EKS cluster"
	fi

	check_autoscaling_groups

	if aws sqs get-queue-url --region "$region" --queue-name "Karpenter-$e2e" >/dev/null 2>"$error_file"; then
		record "SQS queue remains: Karpenter-$e2e"
	elif ! grep -Eq 'AWS.SimpleQueueService.NonExistentQueue|QueueDoesNotExist' "$error_file"; then
		cat "$error_file" >&2
		die "could not audit Karpenter queue"
	fi

	for log_group in "/aws/eks/$e2e/cluster" "/unrealops/$e2e/openvpn" "/unrealops/$vpn/openvpn"; do
		output="$(aws logs describe-log-groups --region "$region" --log-group-name-prefix "$log_group" \
			--query "logGroups[?logGroupName==\`$log_group\`].logGroupName" --output text)" ||
			die "could not audit CloudWatch log group $log_group"
		record_output "CloudWatch log groups" "$output"
	done
	check_tagged_log_groups

	for secret_id in "${secret_ids[@]}"; do
		if output="$(aws secretsmanager describe-secret --region "$region" --secret-id "$secret_id" 2>"$error_file")"; then
			deleted_date="$(jq -r '.DeletedDate // empty' <<<"$output")" ||
				die "could not parse runtime secret response: $secret_id"
			[[ -n "$deleted_date" ]] || record "active runtime secret remains: $secret_id"
		elif ! grep -q 'ResourceNotFoundException' "$error_file"; then
			cat "$error_file" >&2
			die "could not audit runtime secret: $secret_id"
		fi
	done

	check_iam_resources

	event_rules="$(aws events list-rules --region "$region" --name-prefix Karpenter --output json |
		jq -r '.Rules[] | [.Name,.Arn] | @tsv')" || die "could not enumerate Karpenter EventBridge rules"
	while IFS=$'\t' read -r name arn; do
		[[ -n "$name" ]] || continue
		tags="$(aws events list-tags-for-resource --region "$region" --resource-arn "$arn" --output json)" ||
			die "could not enumerate tags for EventBridge rule $name"
		if jq -e --arg cluster "$e2e" '.Tags[]? | select(.Key == "ClusterName" and .Value == $cluster)' \
			<<<"$tags" >/dev/null; then
			record "Karpenter EventBridge rule remains: $name"
		fi
	done <<<"$event_rules"

	alias_count="$(aws kms list-aliases --region "$region" --query \
		"length(Aliases[?AliasName==\`alias/eks/$e2e\`])" --output text)" || die "could not enumerate KMS aliases"
	[[ "$alias_count" == "0" ]] || record "KMS alias remains: alias/eks/$e2e"
	if [[ -n "$kms_key_id" ]]; then
		if aliases_output="$(aws kms list-aliases --region "$region" --key-id "$kms_key_id" \
			--output json 2>"$error_file")"; then
			output="$(jq -r '.Aliases[]?.AliasName' <<<"$aliases_output")" ||
				die "could not parse aliases targeting the run-linked KMS key"
			record_output "KMS aliases targeting run-linked key" "$output"
		elif ! grep -q 'NotFoundException' "$error_file"; then
			cat "$error_file" >&2
			die "could not audit aliases targeting KMS key $kms_key_id"
		fi
	fi
}

deadline=$((SECONDS + wait_seconds))
while :; do
	audit_once
	if [[ ! -s "$findings_file" ]]; then
		printf 'Cleanup audit passed for account %s, region %s, run %s.\n' "$account_id" "$region" "$run_id"
		exit 0
	fi
	if ((SECONDS >= deadline)); then
		printf 'Cleanup audit found active resources:\n' >&2
		sort -u "$findings_file" >&2
		exit 1
	fi
	printf 'Cleanup not yet complete; retrying in 15 seconds.\n' >&2
	sleep 15
done
