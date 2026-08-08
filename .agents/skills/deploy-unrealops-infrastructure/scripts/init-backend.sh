#!/usr/bin/env bash

set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Initialize one supported UnrealOps root with a durable remote backend.

Usage:
  init-backend.sh --root foundation|addons --engine tofu|terraform \
    --backend-type s3 --backend-config /absolute/path/to/root.s3.tfbackend \
    --peer-backend-config /absolute/path/to/other-root.s3.tfbackend \
    --environment NAME \
    (--allow-new-state | --expected-lineage UUID)

Both backend configs must be credential-free, private regular files outside the
repository and must select distinct S3 bucket/key pairs. Existing state must
match its retained lineage; --allow-new-state refuses any existing state.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

validate_backend_config() {
  local supplied_path="$1" label="$2" config_dir canonical_path mode

  [[ "$supplied_path" == /* ]] || die "$label must be an absolute path"
  [[ -f "$supplied_path" && ! -L "$supplied_path" ]] ||
    die "$label must be a regular, non-symlink file"
  [[ -r "$supplied_path" ]] || die "$label is not readable"

  config_dir="$(cd "$(dirname "$supplied_path")" && pwd -P)"
  canonical_path="$config_dir/$(basename "$supplied_path")"
  case "$canonical_path" in
    "$repo_root" | "$repo_root"/*)
      die "$label must be stored outside the repository"
      ;;
  esac

  mode="$(file_mode "$canonical_path")"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "could not determine $label permissions"
  (((8#$mode & 077) == 0)) ||
    die "$label permissions must deny all group/other access (for example, chmod 600)"

  if grep -Eiq '(access_key|secret_key|session_token|web_identity_token|(^|[[:space:]])token)[[:space:]]*=' \
    "$canonical_path"; then
    die "$label must not contain AWS access keys, secret keys, or raw tokens"
  fi
  grep -Eq '^[[:space:]]*encrypt[[:space:]]*=[[:space:]]*true([[:space:]]|$)' \
    "$canonical_path" || die "$label must set encrypt = true"
  grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true([[:space:]]|$)' \
    "$canonical_path" || die "$label must set use_lockfile = true"

  printf '%s\n' "$canonical_path"
}

backend_string_value() {
  local config_path="$1" key_name="$2" values
  values="$(sed -nE \
    "s|^[[:space:]]*${key_name}[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*$|\\1|p" \
    "$config_path")"
  [[ -n "$values" && "$values" != *$'\n'* ]] ||
    die "$config_path must set exactly one non-empty $key_name string"
  case "$values" in
    *'<'* | *'>'* | *REPLACE_WITH*)
      die "$config_path contains an unresolved placeholder in $key_name"
      ;;
  esac
  printf '%s\n' "$values"
}

root_name=""
engine=""
backend_type=""
backend_config=""
peer_backend_config=""
environment=""
expected_lineage=""
allow_new_state=false

while (($#)); do
  case "$1" in
    --root)
      (($# >= 2)) || die "$1 requires a value"
      root_name="$2"
      shift 2
      ;;
    --engine)
      (($# >= 2)) || die "$1 requires a value"
      engine="$2"
      shift 2
      ;;
    --backend-type)
      (($# >= 2)) || die "$1 requires a value"
      backend_type="$2"
      shift 2
      ;;
    --backend-config)
      (($# >= 2)) || die "$1 requires a value"
      backend_config="$2"
      shift 2
      ;;
    --peer-backend-config)
      (($# >= 2)) || die "$1 requires a value"
      peer_backend_config="$2"
      shift 2
      ;;
    --environment)
      (($# >= 2)) || die "$1 requires a value"
      environment="$2"
      shift 2
      ;;
    --expected-lineage)
      (($# >= 2)) || die "$1 requires a value"
      expected_lineage="$2"
      shift 2
      ;;
    --allow-new-state)
      allow_new_state=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$root_name" in
  foundation | addons) ;;
  *) die "--root must be foundation or addons" ;;
esac
case "$engine" in
  tofu | terraform) ;;
  *) die "--engine must be tofu or terraform" ;;
esac
[[ "$backend_type" == "s3" ]] || die "only the AWS S3 remote backend is supported"
[[ "$environment" =~ ^[a-z][a-z0-9-]{1,28}[a-z0-9]$ ]] || die "invalid --environment"
if [[ "$allow_new_state" == "true" ]]; then
  [[ -z "$expected_lineage" ]] ||
    die "--allow-new-state and --expected-lineage are mutually exclusive"
else
  [[ "$expected_lineage" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
    die "supply exactly one of --allow-new-state or a UUID --expected-lineage"
fi
command -v "$engine" >/dev/null 2>&1 || die "$engine is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../../../.." && pwd -P)"
backend_config="$(validate_backend_config "$backend_config" "--backend-config")"
peer_backend_config="$(validate_backend_config \
  "$peer_backend_config" "--peer-backend-config")"

backend_bucket="$(backend_string_value "$backend_config" bucket)"
backend_key="$(backend_string_value "$backend_config" key)"
backend_string_value "$backend_config" region >/dev/null
peer_backend_bucket="$(backend_string_value "$peer_backend_config" bucket)"
peer_backend_key="$(backend_string_value "$peer_backend_config" key)"
backend_string_value "$peer_backend_config" region >/dev/null
if [[ "$backend_bucket" == "$peer_backend_bucket" && "$backend_key" == "$peer_backend_key" ]]; then
  die "foundation and add-ons backend configs must select distinct S3 bucket/key pairs"
fi

root_relative="terraform/examples/complete/$root_name"
root_directory="$repo_root/$root_relative"
backend_override="$root_directory/backend_override.tf"
temporary_override="$(mktemp "$root_directory/.backend_override.tf.XXXXXX")"
trap 'rm -f "$temporary_override"' EXIT

printf '# Generated locally by deploy-unrealops-infrastructure; do not commit.\nterraform {\n  backend "%s" {}\n}\n' \
  "$backend_type" >"$temporary_override"

if [[ -L "$backend_override" ]]; then
  die "refusing symlinked $backend_override"
elif [[ -e "$backend_override" ]]; then
  cmp -s "$temporary_override" "$backend_override" ||
    die "refusing to replace unexpected $backend_override"
  rm -f "$temporary_override"
else
  mv "$temporary_override" "$backend_override"
fi
trap - EXIT

"$engine" -chdir="$root_directory" init \
  -input=false \
  -backend-config="$backend_config"

state_error="$(mktemp)"
trap 'rm -f "$state_error"' EXIT
if state_output="$("$engine" -chdir="$root_directory" state pull 2>"$state_error")"; then
  actual_lineage="$(jq -er '.lineage | select(type == "string")' \
    <<<"$state_output")" || die "$root_name state has an invalid lineage value"
  if [[ -z "$actual_lineage" ]]; then
    [[ "$allow_new_state" == "true" ]] ||
      die "$root_name state lacks a valid lineage"
    jq -e '
      .serial == 0 and
      (.outputs | type == "object" and length == 0) and
      ([.resources[]? | select(.mode == "managed")] | length) == 0
    ' <<<"$state_output" >/dev/null ||
      die "$root_name state lacks a lineage but is not an empty new state"
    printf 'Verified that %s uses a new, empty state object for environment %s.\n' \
      "$root_name" "$environment"
    printf 'Initialized %s with backend type %s and external config %s\n' \
      "$root_name" "$backend_type" "$backend_config"
    exit 0
  fi
  if [[ "$allow_new_state" == "true" ]]; then
    die "$root_name state already exists with lineage $actual_lineage; rerun only with retained --expected-lineage evidence"
  fi
  [[ "$actual_lineage" == "$expected_lineage" ]] ||
    die "$root_name state lineage $actual_lineage does not match expected $expected_lineage"

  managed_count="$(jq '[.resources[]? | select(.mode == "managed")] | length' \
    <<<"$state_output")"
  if [[ "$root_name" == "foundation" ]]; then
    cluster_name="$(jq -r '.outputs.cluster_name.value // empty' <<<"$state_output")"
    [[ -z "$cluster_name" || "$cluster_name" == "$environment" ]] ||
      die "foundation state cluster $cluster_name does not match environment $environment"
    if ((managed_count > 0)); then
      [[ "$cluster_name" == "$environment" ]] ||
        die "non-empty foundation state lacks cluster_name=$environment provenance"
    fi
    jq -e '[.resources[]? | select(.mode == "managed" and .type == "helm_release")] | length == 0' \
      <<<"$state_output" >/dev/null || die "foundation state contains add-ons resources"
  else
    jq -e '
      [
        .resources[]?
        | select(.mode == "managed" and (.type | startswith("aws_")))
        | .type as $resource_type
        | select(
            ((.module // "") | startswith("module.lore_workload")) | not or
            ([
              "aws_cloudwatch_dashboard",
              "aws_cloudwatch_metric_alarm",
              "aws_route53_record"
            ] | index($resource_type) == null)
          )
      ] | length == 0
    ' <<<"$state_output" >/dev/null ||
      die "add-ons state contains AWS resources outside the Lore workload allowlist"
  fi
  printf 'Verified %s state lineage %s for environment %s.\n' \
    "$root_name" "$actual_lineage" "$environment"
elif grep -Eqi 'no (stored )?state file.*found|state snapshot.*not found' "$state_error"; then
  [[ "$allow_new_state" == "true" ]] || {
    cat "$state_error" >&2
    die "$root_name state is absent but an existing lineage was required"
  }
  printf 'Verified that %s uses a new, absent state object for environment %s.\n' \
    "$root_name" "$environment"
else
  cat "$state_error" >&2
  die "could not verify $root_name state provenance"
fi

printf 'Initialized %s with backend type %s and external config %s\n' \
  "$root_name" "$backend_type" "$backend_config"
