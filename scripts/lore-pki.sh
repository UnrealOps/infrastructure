#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly DEFAULT_PKI_ROOT="${HOME}/.config/unrealops/lore-pki"
readonly LEAF_VALIDITY_DAYS="397"

usage() {
	cat <<'EOF'
Manage the offline Lore certificate authority and AWS runtime bundle.

Usage:
  lore-pki.sh init \
    --cluster-name NAME [--secret-id NAME_OR_ARN] [--region AWS_REGION]

  lore-pki.sh rotate \
    --cluster-name NAME [--secret-id NAME_OR_ARN] [--region AWS_REGION]

  lore-pki.sh export-ca \
    --cluster-name NAME [--output FILE]

The encrypted CA key is kept under
~/.config/unrealops/lore-pki/CLUSTER_NAME and is never uploaded. Secrets
Manager receives only the CA certificate plus the shared edge server, write
server, and edge replication-client leaf certificates and keys.

Set LORE_PKI_ROOT to use a different offline location.
For non-interactive automation, set LORE_CA_PASSIN and LORE_CA_PASSOUT to
OpenSSL passphrase sources such as file:/secure/path. The input and output
files should be distinct even when they contain the same passphrase.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_cluster_name() {
	[[ "$1" =~ ^[a-z][a-z0-9-]{1,28}[a-z0-9]$ ]] ||
		die "cluster name must be 3-30 lowercase alphanumeric or hyphen characters and start with a letter"
}

aws_cli() {
	if [[ -n "${AWS_REGION_VALUE}" ]]; then
		aws --region "${AWS_REGION_VALUE}" "$@"
	else
		aws "$@"
	fi
}

load_metadata() {
	[[ -f "${METADATA_FILE}" ]] ||
		die "missing ${METADATA_FILE}; run init first"

	if [[ -z "${SECRET_ID}" ]]; then
		SECRET_ID="$(jq -er '.secret_id' "${METADATA_FILE}")"
	fi
	if [[ -z "${AWS_REGION_VALUE}" ]]; then
		AWS_REGION_VALUE="$(jq -r '.region // ""' "${METADATA_FILE}")"
	fi
}

write_leaf_extensions() {
	local kind="$1"
	local dns_name="${2:-}"
	local output_file="$3"

	if [[ "${kind}" == "server" ]]; then
		cat >"${output_file}" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${dns_name}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
	else
		cat >"${output_file}" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
	fi
}

sign_leaf() {
	local common_name="$1"
	local kind="$2"
	local dns_name="$3"
	local output_prefix="$4"
	local working_directory="$5"
	local extensions_file="${working_directory}/${output_prefix}.ext"
	local csr_file="${working_directory}/${output_prefix}.csr"
	local key_file="${working_directory}/${output_prefix}.key"
	local cert_file="${working_directory}/${output_prefix}.crt"
	local -a serial_arguments

	write_leaf_extensions "${kind}" "${dns_name}" "${extensions_file}"
	openssl genpkey \
		-algorithm EC \
		-pkeyopt ec_paramgen_curve:P-256 \
		-out "${key_file}"
	openssl req \
		-new \
		-sha256 \
		-key "${key_file}" \
		-subj "/CN=${common_name}" \
		-out "${csr_file}"

	if [[ -f "${SERIAL_FILE}" ]]; then
		serial_arguments=(-CAserial "${SERIAL_FILE}")
	else
		serial_arguments=(-CAcreateserial -CAserial "${SERIAL_FILE}")
	fi

	printf '\nUnlock the offline Lore CA to sign %s.\n' "${common_name}" >&2
	openssl x509 \
		-req \
		-sha256 \
		-days "${LEAF_VALIDITY_DAYS}" \
		-in "${csr_file}" \
		-CA "${CA_CERT_FILE}" \
		-CAkey "${CA_KEY_FILE}" \
		"${CA_PASSIN_ARGUMENTS[@]}" \
		"${serial_arguments[@]}" \
		-extfile "${extensions_file}" \
		-out "${cert_file}"

	openssl verify -CAfile "${CA_CERT_FILE}" "${cert_file}" >/dev/null
	openssl pkey -in "${key_file}" -check -noout >/dev/null
}

issue_runtime_certificates() {
	local working_directory="$1"

	sign_leaf \
		"lore.${CLUSTER_NAME}.internal" \
		server \
		"lore.${CLUSTER_NAME}.internal" \
		edge \
		"${working_directory}"
	sign_leaf \
		"lore-write.lore.svc.cluster.local" \
		server \
		"lore-write.lore.svc.cluster.local" \
		write \
		"${working_directory}"
	sign_leaf \
		"${CLUSTER_NAME}-lore-edge-replication" \
		client \
		"" \
		edge-client \
		"${working_directory}"
}

write_runtime_payload() {
	local certificate_directory="$1"
	local payload_file="$2"

	jq -n \
		--arg schema_version "1" \
		--arg issued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--rawfile ca_cert "${CA_CERT_FILE}" \
		--rawfile edge_cert "${certificate_directory}/edge.crt" \
		--rawfile edge_key "${certificate_directory}/edge.key" \
		--rawfile write_cert "${certificate_directory}/write.crt" \
		--rawfile write_key "${certificate_directory}/write.key" \
		--rawfile edge_client_cert "${certificate_directory}/edge-client.crt" \
		--rawfile edge_client_key "${certificate_directory}/edge-client.key" \
		'{
		  schema_version: $schema_version,
		  issued_at: $issued_at,
		  ca_cert: $ca_cert,
		  edge_cert: $edge_cert,
		  edge_key: $edge_key,
		  write_cert: $write_cert,
		  write_key: $write_key,
		  edge_client_cert: $edge_client_cert,
		  edge_client_key: $edge_client_key
		}' >"${payload_file}"
}

upload_runtime_bundle() {
	local certificate_directory="$1"
	local payload_file
	local secret_arn

	payload_file="$(mktemp)"
	trap 'rm -f "${payload_file}"' RETURN
	write_runtime_payload "${certificate_directory}" "${payload_file}"

	if aws_cli secretsmanager describe-secret --secret-id "${SECRET_ID}" >/dev/null 2>&1; then
		secret_arn="$(aws_cli secretsmanager put-secret-value \
			--secret-id "${SECRET_ID}" \
			--secret-string "file://${payload_file}" \
			--query ARN \
			--output text)"
	else
		[[ "${SECRET_ID}" != arn:* ]] ||
			die "secret ARN does not exist; pass a new secret name to init"
		secret_arn="$(aws_cli secretsmanager create-secret \
			--name "${SECRET_ID}" \
			--description "Lore runtime TLS bundle for ${CLUSTER_NAME}; CA key remains offline" \
			--secret-string "file://${payload_file}" \
			--query ARN \
			--output text)"
	fi

	jq -n \
		--arg secret_id "${secret_arn}" \
		--arg region "${AWS_REGION_VALUE}" \
		'{secret_id: $secret_id, region: $region}' \
		>"${METADATA_FILE}"
	chmod 0600 "${METADATA_FILE}"

	rm -f "${payload_file}"
	trap - RETURN
	printf 'Lore runtime bundle uploaded to %s\n' "${secret_arn}"
}

install_runtime_certificates() {
	local source_directory="$1"

	mkdir -p "${RUNTIME_DIRECTORY}"
	for name in edge edge-client write; do
		cp "${source_directory}/${name}.crt" "${RUNTIME_DIRECTORY}/${name}.crt"
		cp "${source_directory}/${name}.key" "${RUNTIME_DIRECTORY}/${name}.key"
	done
	chmod 0600 "${RUNTIME_DIRECTORY}"/*.key
	chmod 0644 "${RUNTIME_DIRECTORY}"/*.crt
}

command_init() {
	local staging_directory

	[[ ! -e "${CA_KEY_FILE}" ]] ||
		die "a Lore CA already exists for ${CLUSTER_NAME}; refusing to overwrite it"
	require_command aws
	require_command jq
	require_command openssl

	mkdir -p "${CLUSTER_DIRECTORY}"
	chmod 0700 "${CLUSTER_DIRECTORY}"

	printf '\nCreate a passphrase for the encrypted offline Lore CA.\n' >&2
	openssl genrsa \
		-aes256 \
		"${CA_PASSOUT_ARGUMENTS[@]}" \
		-out "${CA_KEY_FILE}" \
		4096
	chmod 0600 "${CA_KEY_FILE}"
	printf '\nUnlock the offline Lore CA to create its certificate.\n' >&2
	openssl req \
		-x509 \
		-new \
		-sha256 \
		-days 3650 \
		-key "${CA_KEY_FILE}" \
		"${CA_PASSIN_ARGUMENTS[@]}" \
		-subj "/CN=${CLUSTER_NAME} Lore CA" \
		-addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
		-addext "keyUsage=critical,keyCertSign,cRLSign" \
		-out "${CA_CERT_FILE}"
	chmod 0644 "${CA_CERT_FILE}"

	staging_directory="$(mktemp -d "${CLUSTER_DIRECTORY}/issue.XXXXXX")"
	trap 'rm -rf "${staging_directory}"' RETURN
	issue_runtime_certificates "${staging_directory}"
	upload_runtime_bundle "${staging_directory}"
	install_runtime_certificates "${staging_directory}"
	rm -rf "${staging_directory}"
	trap - RETURN

	printf 'Offline Lore CA initialized in %s\n' "${CLUSTER_DIRECTORY}"
	printf 'Restart the Lore edge and write deployments after applying the workload.\n'
}

command_rotate() {
	local staging_directory

	[[ -f "${CA_KEY_FILE}" && -f "${CA_CERT_FILE}" ]] ||
		die "missing offline Lore CA for ${CLUSTER_NAME}; run init first"
	require_command aws
	require_command jq
	require_command openssl
	load_metadata

	staging_directory="$(mktemp -d "${CLUSTER_DIRECTORY}/rotation.XXXXXX")"
	trap 'rm -rf "${staging_directory}"' RETURN
	issue_runtime_certificates "${staging_directory}"
	upload_runtime_bundle "${staging_directory}"
	install_runtime_certificates "${staging_directory}"
	rm -rf "${staging_directory}"
	trap - RETURN

	printf 'Lore leaf certificates rotated; the offline CA was preserved.\n'
	printf 'Perform a controlled restart of lore-write, then lore-edge.\n'
}

command_export_ca() {
	local destination

	[[ -f "${CA_CERT_FILE}" ]] ||
		die "missing offline Lore CA for ${CLUSTER_NAME}; run init first"
	destination="${OUTPUT_FILE:-${PWD}/${CLUSTER_NAME}-lore-ca.crt}"
	mkdir -p "$(dirname "${destination}")"
	cp "${CA_CERT_FILE}" "${destination}"
	chmod 0644 "${destination}"
	printf 'Lore CA certificate exported to %s\n' "${destination}"
}

[[ $# -ge 1 ]] || {
	usage
	exit 1
}

COMMAND="$1"
shift

if [[ "${COMMAND}" == "-h" || "${COMMAND}" == "--help" || "${COMMAND}" == "help" ]]; then
	usage
	exit 0
fi

CLUSTER_NAME=""
SECRET_ID=""
AWS_REGION_VALUE=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--cluster-name)
		[[ $# -ge 2 ]] || die "--cluster-name requires a value"
		CLUSTER_NAME="$2"
		shift 2
		;;
	--secret-id)
		[[ $# -ge 2 ]] || die "--secret-id requires a value"
		SECRET_ID="$2"
		shift 2
		;;
	--region)
		[[ $# -ge 2 ]] || die "--region requires a value"
		AWS_REGION_VALUE="$2"
		shift 2
		;;
	--output)
		[[ $# -ge 2 ]] || die "--output requires a value"
		OUTPUT_FILE="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

[[ -n "${CLUSTER_NAME}" ]] || die "--cluster-name is required"
validate_cluster_name "${CLUSTER_NAME}"

PKI_ROOT="${LORE_PKI_ROOT:-${DEFAULT_PKI_ROOT}}"
CLUSTER_DIRECTORY="${PKI_ROOT}/${CLUSTER_NAME}"
CA_KEY_FILE="${CLUSTER_DIRECTORY}/ca.key.pem"
CA_CERT_FILE="${CLUSTER_DIRECTORY}/ca.crt"
SERIAL_FILE="${CLUSTER_DIRECTORY}/ca.srl"
RUNTIME_DIRECTORY="${CLUSTER_DIRECTORY}/runtime"
METADATA_FILE="${CLUSTER_DIRECTORY}/metadata.json"
SECRET_ID="${SECRET_ID:-unrealops/${CLUSTER_NAME}/lore/runtime}"
CA_PASSIN_ARGUMENTS=()
CA_PASSOUT_ARGUMENTS=()
if [[ -n "${LORE_CA_PASSIN:-}" ]]; then
	CA_PASSIN_ARGUMENTS=(-passin "${LORE_CA_PASSIN}")
fi
if [[ -n "${LORE_CA_PASSOUT:-}" ]]; then
	CA_PASSOUT_ARGUMENTS=(-passout "${LORE_CA_PASSOUT}")
fi

case "${COMMAND}" in
init) command_init ;;
rotate) command_rotate ;;
export-ca) command_export_ca ;;
-h | --help | help) usage ;;
*) die "unknown command: ${COMMAND}" ;;
esac
