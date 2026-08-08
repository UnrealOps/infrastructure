#!/usr/bin/env bash
set -euo pipefail

engine="${ENGINE:-tofu}"
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$root_dir/.terraform-plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

directories=(
	terraform/modules/network
	terraform/modules/openvpn
	terraform/modules/eks
	terraform/modules/karpenter-infra
	terraform/modules/cluster-addons-infra
	terraform/modules/cluster-addons
	terraform/modules/lore-infra
	terraform/modules/lore-workload
	terraform/examples/complete/foundation
	terraform/examples/complete/addons
)

cleanup() {
	local relative_dir directory
	for relative_dir in "${directories[@]}"; do
		directory="$root_dir/$relative_dir"
		rm -rf "$directory/.terraform"
		rm -f "$directory/.terraform.lock.hcl"
	done
}
trap cleanup EXIT

command -v "$engine" >/dev/null 2>&1 || {
	echo "$engine is required" >&2
	exit 1
}

for relative_dir in "${directories[@]}"; do
	directory="$root_dir/$relative_dir"
	[[ -d "$directory" ]] || continue
	echo "Validating $relative_dir with $engine"
	rm -rf "$directory/.terraform"
	rm -f "$directory/.terraform.lock.hcl"
	"$engine" -chdir="$directory" init -backend=false -input=false >/dev/null
	"$engine" -chdir="$directory" validate
done
