#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Verify empty managed state and absence of resources owned by one UnrealOps environment.

Usage:
  audit-cleanup.sh --account-id 123456789012 --region REGION \
    --environment studio-prod --engine tofu \
    --kms-key-id KMS_KEY_ARN [--kms-key-id LORE_KMS_KEY_ARN] \
    --runtime-secret-id SECRET_ARN [--runtime-secret-id LORE_SECRET_ARN] \
    --vpc-id VPC_ID \
    --foundation-lineage UUID --addons-lineage UUID \
    (--no-route53-record | \
      --route53-zone-id ZONE_ID --route53-record-name VPN_DNS_NAME) \
    [--retained-state-bucket-arn arn:aws:s3:::BUCKET] \
    [--allow-active-runtime-secret]

Initialize both roots against their durable backends before running this audit.
The KMS and runtime-secret options are repeatable for Lore-enabled deployments.
The audit is read-only. A deleted KMS key may remain only when disabled and in
PendingDeletion with no alias. A runtime secret scheduled for recovery-window
deletion is accepted; an active runtime secret is not.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

account_id=""
region=""
environment=""
engine=""
kms_key_ids=()
runtime_secret_ids=()
vpc_id=""
foundation_lineage=""
addons_lineage=""
route53_zone_id=""
route53_record_name=""
retained_state_bucket_arn=""
no_route53_record=false
allow_active_runtime_secret=false

while (($#)); do
  case "$1" in
    --account-id)
      (($# >= 2)) || die "$1 requires a value"
      account_id="$2"
      shift 2
      ;;
    --region)
      (($# >= 2)) || die "$1 requires a value"
      region="$2"
      shift 2
      ;;
    --environment)
      (($# >= 2)) || die "$1 requires a value"
      environment="$2"
      shift 2
      ;;
    --engine)
      (($# >= 2)) || die "$1 requires a value"
      engine="$2"
      shift 2
      ;;
    --kms-key-id)
      (($# >= 2)) || die "$1 requires a value"
      kms_key_ids+=("$2")
      shift 2
      ;;
    --runtime-secret-id)
      (($# >= 2)) || die "$1 requires a value"
      runtime_secret_ids+=("$2")
      shift 2
      ;;
    --vpc-id)
      (($# >= 2)) || die "$1 requires a value"
      vpc_id="$2"
      shift 2
      ;;
    --foundation-lineage)
      (($# >= 2)) || die "$1 requires a value"
      foundation_lineage="$2"
      shift 2
      ;;
    --addons-lineage)
      (($# >= 2)) || die "$1 requires a value"
      addons_lineage="$2"
      shift 2
      ;;
    --route53-zone-id)
      (($# >= 2)) || die "$1 requires a value"
      route53_zone_id="$2"
      shift 2
      ;;
    --route53-record-name)
      (($# >= 2)) || die "$1 requires a value"
      route53_record_name="$2"
      shift 2
      ;;
    --retained-state-bucket-arn)
      (($# >= 2)) || die "$1 requires a value"
      retained_state_bucket_arn="$2"
      shift 2
      ;;
    --no-route53-record)
      no_route53_record=true
      shift
      ;;
    --allow-active-runtime-secret)
      allow_active_runtime_secret=true
      shift
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
[[ "$environment" =~ ^[a-z][a-z0-9-]{1,28}[a-z0-9]$ ]] || die "invalid --environment"
case "$engine" in
  tofu | terraform) ;;
  *) die "--engine must be tofu or terraform" ;;
esac
((${#kms_key_ids[@]} > 0)) || die "at least one --kms-key-id is required"
((${#runtime_secret_ids[@]} > 0)) || die "at least one --runtime-secret-id is required"
[[ "$vpc_id" =~ ^vpc-[0-9a-f]+$ ]] || die "--vpc-id must be an AWS VPC ID"
lineage_pattern='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
[[ "$foundation_lineage" =~ $lineage_pattern ]] || die "invalid --foundation-lineage"
[[ "$addons_lineage" =~ $lineage_pattern ]] || die "invalid --addons-lineage"
[[ "$foundation_lineage" != "$addons_lineage" ]] ||
  die "foundation and add-ons lineages must differ"
if [[ "$no_route53_record" == "true" ]]; then
  [[ -z "$route53_zone_id" && -z "$route53_record_name" ]] ||
    die "--no-route53-record cannot be combined with Route 53 coordinates"
else
  [[ -n "$route53_zone_id" && -n "$route53_record_name" ]] ||
    die "supply --no-route53-record or both Route 53 coordinates"
fi
for kms_key_id in "${kms_key_ids[@]}"; do
  [[ "$kms_key_id" == arn:*:kms:"$region":"$account_id":key/* ]] ||
    die "--kms-key-id must be a KMS key ARN in the expected account and region"
done
for runtime_secret_id in "${runtime_secret_ids[@]}"; do
  [[ "$runtime_secret_id" == arn:*:secretsmanager:"$region":"$account_id":secret:* ]] ||
    die "--runtime-secret-id must be a Secrets Manager ARN in the expected account and region"
done
if [[ -n "$retained_state_bucket_arn" ]]; then
  [[ "$retained_state_bucket_arn" == arn:aws:s3:::* ]] ||
    die "--retained-state-bucket-arn must be an S3 bucket ARN"
fi
command -v aws >/dev/null 2>&1 || die "aws is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v "$engine" >/dev/null 2>&1 || die "$engine is required"

export AWS_REGION="$region"
export AWS_DEFAULT_REGION="$region"
export AWS_PAGER=""
actual_account="$(aws sts get-caller-identity --region "$region" --query Account --output text)"
[[ "$actual_account" == "$account_id" ]] ||
  die "refusing AWS account $actual_account; expected $account_id"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../../../.." && pwd -P)"
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

array_contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

kms_is_safe_remnant() {
  local key_id="$1" allow_not_found="${2:-false}" report="${3:-false}"
  local output tags state enabled deletion_date
  if ! output="$(aws kms describe-key --region "$region" --key-id "$key_id" 2>"$error_file")"; then
    if grep -q 'NotFoundException' "$error_file"; then
      [[ "$allow_not_found" == "true" ]]
      return
    fi
    cat "$error_file" >&2
    die "could not audit KMS key $key_id"
  fi
  state="$(jq -r '.KeyMetadata.KeyState' <<<"$output")"
  enabled="$(jq -r '.KeyMetadata.Enabled' <<<"$output")"
  deletion_date="$(jq -r '.KeyMetadata.DeletionDate // empty' <<<"$output")"
  if [[ "$state" == "PendingDeletion" && "$enabled" == "false" && -n "$deletion_date" ]]; then
    tags="$(aws kms list-resource-tags --region "$region" --key-id "$key_id" --output json)"
    jq -e --arg environment "$environment" '
      any(.Tags[]?; .TagKey == "Environment" and .TagValue == $environment) and
      any(.Tags[]?; .TagKey == "Project" and .TagValue == "UnrealOps")
    ' <<<"$tags" >/dev/null || return 1
    if [[ "$report" == "true" ]]; then
      printf 'Expected scheduled KMS remnant: %s deletion=%s\n' \
        "$key_id" "$deletion_date"
    fi
    return 0
  fi
  return 1
}

check_tagged_resources() {
  local key="$1" value="$2" output arn
  output="$(aws resourcegroupstaggingapi get-resources --region "$region" \
    --tag-filters "Key=$key,Values=$value" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text)"
  for arn in $output; do
    array_contains "$arn" "${runtime_secret_ids[@]}" && continue
    if array_contains "$arn" "${kms_key_ids[@]}" && kms_is_safe_remnant "$arn"; then
      continue
    fi
    [[ -n "$retained_state_bucket_arn" && "$arn" == "$retained_state_bucket_arn" ]] &&
      continue
    case "$arn" in
      arn:aws:ec2:"$region":"$account_id":* | arn:aws:eks:"$region":"$account_id":*)
        # EC2 and EKS retain terminal entries in the Resource Groups Tagging
        # API after their service APIs report deletion. The exact active-state
        # checks below are authoritative for these resource families.
        continue
        ;;
    esac
    record "tagged resource remains ($key=$value): $arn"
  done
}

check_ec2_resources() {
  local key="$1" value="$2" output
  output="$(aws ec2 describe-instances --region "$region" --filters \
    "Name=tag:$key,Values=$value" \
    'Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped' \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  record_output "active EC2 instances ($key=$value)" "$output"

  output="$(aws ec2 describe-fleets --region "$region" --filters \
    "Name=tag:$key,Values=$value" \
    --query 'Fleets[?FleetState!=`deleted`].FleetId' --output text)"
  record_output "active EC2 fleets ($key=$value)" "$output"

  output="$(aws ec2 describe-volumes --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'Volumes[].VolumeId' --output text)"
  record_output "EBS volumes ($key=$value)" "$output"
  output="$(aws ec2 describe-network-interfaces --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
  record_output "network interfaces ($key=$value)" "$output"
  output="$(aws ec2 describe-vpcs --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'Vpcs[].VpcId' --output text)"
  record_output "VPCs ($key=$value)" "$output"
  output="$(aws ec2 describe-subnets --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'Subnets[].SubnetId' --output text)"
  record_output "subnets ($key=$value)" "$output"
  output="$(aws ec2 describe-route-tables --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'RouteTables[].RouteTableId' --output text)"
  record_output "route tables ($key=$value)" "$output"
  output="$(aws ec2 describe-internet-gateways --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'InternetGateways[].InternetGatewayId' --output text)"
  record_output "internet gateways ($key=$value)" "$output"
  output="$(aws ec2 describe-nat-gateways --region "$region" \
    --filter "Name=tag:$key,Values=$value" --output json |
    jq -r '.NatGateways[] | select(.State != "deleted") | .NatGatewayId')"
  record_output "NAT gateways ($key=$value)" "$output"
  output="$(aws ec2 describe-addresses --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'Addresses[].AllocationId' --output text)"
  record_output "Elastic IPs ($key=$value)" "$output"
  output="$(aws ec2 describe-launch-templates --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'LaunchTemplates[].LaunchTemplateId' --output text)"
  record_output "launch templates ($key=$value)" "$output"
  output="$(aws ec2 describe-vpc-endpoints --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text)"
  record_output "VPC endpoints ($key=$value)" "$output"
  output="$(aws ec2 describe-security-groups --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'SecurityGroups[].GroupId' --output text)"
  record_output "security groups ($key=$value)" "$output"
  output="$(aws ec2 describe-flow-logs --region "$region" --filter "Name=tag:$key,Values=$value" \
    --query 'FlowLogs[].FlowLogId' --output text)"
  record_output "VPC flow logs ($key=$value)" "$output"
  output="$(aws ec2 describe-managed-prefix-lists --region "$region" --filters "Name=tag:$key,Values=$value" \
    --query 'PrefixLists[].PrefixListId' --output text)"
  record_output "managed prefix lists ($key=$value)" "$output"
}

check_exact_vpc_residue() {
  local output
  output="$(aws ec2 describe-vpcs --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" --query 'Vpcs[].VpcId' --output text)"
  record_output "exact VPC" "$output"
  output="$(aws ec2 describe-subnets --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" --query 'Subnets[].SubnetId' --output text)"
  record_output "exact VPC subnets" "$output"
  output="$(aws ec2 describe-route-tables --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" --query 'RouteTables[].RouteTableId' --output text)"
  record_output "exact VPC route tables" "$output"
  output="$(aws ec2 describe-network-acls --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" --query 'NetworkAcls[].NetworkAclId' --output text)"
  record_output "exact VPC network ACLs" "$output"
  output="$(aws ec2 describe-internet-gateways --region "$region" \
    --filters "Name=attachment.vpc-id,Values=$vpc_id" \
    --query 'InternetGateways[].InternetGatewayId' --output text)"
  record_output "exact VPC internet gateways" "$output"
  output="$(aws ec2 describe-nat-gateways --region "$region" \
    --filter "Name=vpc-id,Values=$vpc_id" --output json |
    jq -r '.NatGateways[] | select(.State != "deleted") | .NatGatewayId')"
  record_output "exact VPC NAT gateways" "$output"
  output="$(aws ec2 describe-network-interfaces --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
  record_output "exact VPC network interfaces" "$output"
  output="$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" --query 'SecurityGroups[].GroupId' --output text)"
  record_output "exact VPC security groups" "$output"
  output="$(aws ec2 describe-vpc-endpoints --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text)"
  record_output "exact VPC endpoints" "$output"
  output="$(aws ec2 describe-flow-logs --region "$region" \
    --filter "Name=resource-id,Values=$vpc_id" --query 'FlowLogs[].FlowLogId' --output text)"
  record_output "exact VPC flow logs" "$output"
}

has_environment_tag() {
  jq -e --arg environment "$environment" '
    (
      any(.Tags[]?;
        (.Key == "Environment" and .Value == $environment) or
        (.Key == "ClusterName" and .Value == $environment) or
        (.Key == "karpenter.sh/discovery" and .Value == $environment)
      )
    ) and any(.Tags[]?; .Key == "Project" and .Value == "UnrealOps")
  ' >/dev/null
}

check_iam_resources() {
  local name arn tags output roles_json roles_tsv profiles_json policies_json policies_tsv oidc_json oidc_arns
  roles_json="$(aws iam list-roles --region "$region" --output json)"
  roles_tsv="$(jq -r '.Roles[] | [.RoleName,.Arn] | @tsv' <<<"$roles_json")"
  while IFS=$'\t' read -r name arn; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "$environment-openvpn" ||
      "$name" == "$environment-ebs-csi" ||
      "$name" == "$environment-karpenter-controller" ||
      "$name" == "$environment-karpenter-node" ||
      "$name" == "$environment-system-eks-node-group" ]]; then
      record "IAM role remains: $arn"
      continue
    fi
    if [[ "$name" == "$environment-"* ]]; then
      record "environment-prefixed IAM role remains: $arn"
      continue
    fi
    if [[ "$name" != vpc-flow-log-role-* ]]; then
      continue
    fi
    tags="$(aws iam list-role-tags --region "$region" --role-name "$name" --output json)"
    has_environment_tag <<<"$tags" && record "environment-tagged IAM role remains: $arn"
  done <<<"$roles_tsv"

  profiles_json="$(aws iam list-instance-profiles --region "$region" --output json)"
  output="$(jq -r \
    --arg environment "$environment" '
      .InstanceProfiles[]
      | select(.InstanceProfileName == ($environment + "-openvpn") or
          .InstanceProfileName == ($environment + "-system-eks-node-group") or
          (.InstanceProfileName | startswith($environment + "_")))
      | .Arn
    ' <<<"$profiles_json")"
  record_output "IAM instance profiles" "$output"

  policies_json="$(aws iam list-policies --region "$region" --scope Local --output json)"
  policies_tsv="$(jq -r '.Policies[] | [.PolicyName,.Arn] | @tsv' <<<"$policies_json")"
  while IFS=$'\t' read -r name arn; do
    if [[ "$name" == "$environment-"* ]]; then
      record "environment-prefixed IAM policy remains: $arn"
      continue
    fi
    if [[ "$name" != vpc-flow-log-to-cloudwatch-* ]]; then
      continue
    fi
    tags="$(aws iam list-policy-tags --region "$region" --policy-arn "$arn" --output json)"
    has_environment_tag <<<"$tags" && record "environment-tagged IAM policy remains: $arn"
  done <<<"$policies_tsv"

  oidc_json="$(aws iam list-open-id-connect-providers --region "$region" --output json)"
  oidc_arns="$(jq -r '.OpenIDConnectProviderList[].Arn' <<<"$oidc_json")"
  while read -r arn; do
    [[ -n "$arn" ]] || continue
    tags="$(aws iam list-open-id-connect-provider-tags --region "$region" \
      --open-id-connect-provider-arn "$arn" --output json)"
    if has_environment_tag <<<"$tags" || jq -e --arg name "$environment-eks-irsa" \
      'any(.Tags[]?; .Key == "Name" and .Value == $name)' <<<"$tags" >/dev/null; then
      record "environment-tagged IAM OIDC provider remains: $arn"
    fi
  done <<<"$oidc_arns"
}

for root_name in foundation addons; do
  root_directory="$repo_root/terraform/examples/complete/$root_name"
  if ! state_output="$("$engine" -chdir="$root_directory" state pull 2>"$error_file")"; then
    cat "$error_file" >&2
    die "could not read $root_name state; initialize its durable backend first"
  fi
  managed_state="$(jq -r '
    .resources[]?
    | select(.mode == "managed")
    | ((.module // "") + (if .module then "." else "" end) + .type + "." + .name)
  ' <<<"$state_output")"
  record_output "$root_name managed state entries" "$managed_state"
  actual_lineage="$(jq -er '.lineage' <<<"$state_output")"
  if [[ "$root_name" == "foundation" ]]; then
    [[ "$actual_lineage" == "$foundation_lineage" ]] ||
      die "foundation state lineage does not match --foundation-lineage"
  else
    [[ "$actual_lineage" == "$addons_lineage" ]] ||
      die "add-ons state lineage does not match --addons-lineage"
  fi
done

for selector in \
  "Environment=$environment" \
  "ClusterName=$environment" \
  "karpenter.sh/discovery=$environment" \
  "eks:cluster-name=$environment" \
  "eks:eks-cluster-name=$environment" \
  "aws:eks:cluster-name=$environment" \
  "kubernetes.io/cluster/$environment=owned,shared"; do
  key="${selector%%=*}"
  value="${selector#*=}"
  check_tagged_resources "$key" "$value"
  check_ec2_resources "$key" "$value"
done

check_exact_vpc_residue

if aws eks describe-cluster --region "$region" --name "$environment" >/dev/null 2>"$error_file"; then
  record "EKS cluster remains: $environment"
elif ! grep -q 'ResourceNotFoundException' "$error_file"; then
  cat "$error_file" >&2
  die "could not audit EKS cluster"
fi

output="$(aws autoscaling describe-auto-scaling-groups --region "$region" --output json | jq -r \
  --arg environment "$environment" '
    .AutoScalingGroups[]
    | select(.AutoScalingGroupName == ($environment + "-openvpn") or
        any(.Tags[]?;
          (.Key == "Environment" and .Value == $environment) or
          (.Key == "eks:cluster-name" and .Value == $environment) or
          (.Key == "karpenter.sh/discovery" and .Value == $environment)
        ))
    | .AutoScalingGroupName
  ')"
record_output "Auto Scaling groups" "$output"

if aws sqs get-queue-url --region "$region" --queue-name "Karpenter-$environment" \
  >/dev/null 2>"$error_file"; then
  record "SQS queue remains: Karpenter-$environment"
elif ! grep -Eq 'AWS.SimpleQueueService.NonExistentQueue|QueueDoesNotExist' "$error_file"; then
  cat "$error_file" >&2
  die "could not audit Karpenter queue"
fi

for log_group in \
  "/aws/eks/$environment/cluster" \
  "/unrealops/$environment/openvpn" \
  "/aws/vpc-flow-log/$vpc_id" \
  "/aws/containerinsights/$environment/application" \
  "/aws/containerinsights/$environment/dataplane" \
  "/aws/containerinsights/$environment/host" \
  "/aws/containerinsights/$environment/performance" \
  "/aws/otel/containerinsights/$environment/application" \
  "/aws/lore/$environment/metrics"; do
  output="$(aws logs describe-log-groups --region "$region" --log-group-name-prefix "$log_group" \
    --query "logGroups[?logGroupName==\`$log_group\`].logGroupName" --output text)"
  record_output "CloudWatch log groups" "$output"
done

check_iam_resources

event_rules_json="$(aws events list-rules --region "$region" --name-prefix Karpenter --output json)"
event_rules_tsv="$(jq -r '.Rules[] | [.Name,.Arn] | @tsv' <<<"$event_rules_json")"
while IFS=$'\t' read -r name arn; do
  [[ -n "$name" ]] || continue
  tags="$(aws events list-tags-for-resource --region "$region" --resource-arn "$arn" --output json)"
  if jq -e --arg environment "$environment" \
    '.Tags[]? | select(.Key == "ClusterName" and .Value == $environment)' \
    <<<"$tags" >/dev/null; then
    record "Karpenter EventBridge rule remains: $name"
  fi
done <<<"$event_rules_tsv"

for expected_alias in "alias/eks/$environment" "alias/$environment-lore"; do
  alias_count="$(aws kms list-aliases --region "$region" --query \
    "length(Aliases[?AliasName==\`$expected_alias\`])" --output text)"
  [[ "$alias_count" == "0" ]] || record "KMS alias remains: $expected_alias"
done
for kms_key_id in "${kms_key_ids[@]}"; do
  if aliases_output="$(aws kms list-aliases --region "$region" --key-id "$kms_key_id" \
    --output json 2>"$error_file")"; then
    target_aliases="$(jq -r '.Aliases[]?.AliasName' <<<"$aliases_output")"
    record_output "KMS aliases targeting recorded key" "$target_aliases"
  elif ! grep -q 'NotFoundException' "$error_file"; then
    cat "$error_file" >&2
    die "could not audit aliases for KMS key $kms_key_id"
  fi
  kms_is_safe_remnant "$kms_key_id" true true ||
    record "KMS key is not deleted or safely pending deletion: $kms_key_id"
done

if [[ -n "$route53_zone_id" ]]; then
  normalized_route53_name="${route53_record_name%.}."
  route53_output="$(aws route53 list-resource-record-sets --region "$region" \
    --hosted-zone-id "$route53_zone_id" --output json)"
  remaining_route53_record="$(jq -r --arg name "$normalized_route53_name" '
    .ResourceRecordSets[]?
    | select((.Name | ascii_downcase) == ($name | ascii_downcase) and .Type == "A")
    | [.Name, .Type]
    | @tsv
  ' <<<"$route53_output")"
  record_output "Route 53 VPN A record" "$remaining_route53_record"
fi

for runtime_secret_id in "${runtime_secret_ids[@]}"; do
  if secret_output="$(aws secretsmanager describe-secret --region "$region" \
    --secret-id "$runtime_secret_id" 2>"$error_file")"; then
    deleted_date="$(jq -r '.DeletedDate // empty' <<<"$secret_output")"
    if [[ -n "$deleted_date" ]]; then
      printf 'Runtime secret scheduled for deletion: %s deletion=%s\n' \
        "$runtime_secret_id" "$deleted_date"
    elif [[ "$allow_active_runtime_secret" == "true" ]]; then
      printf 'Expected retained runtime secret: %s\n' "$runtime_secret_id"
    else
      record "active runtime secret remains: $runtime_secret_id"
    fi
  elif ! grep -q 'ResourceNotFoundException' "$error_file"; then
    cat "$error_file" >&2
    die "could not audit runtime secret"
  fi
done

if [[ -s "$findings_file" ]]; then
  printf 'Cleanup audit found active resources:\n' >&2
  sort -u "$findings_file" >&2
  exit 1
fi

printf 'Cleanup audit passed for account %s, region %s, environment %s.\n' \
  "$account_id" "$region" "$environment"
