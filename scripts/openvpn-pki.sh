#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly EASYRSA_VERSION="3.2.6"
readonly EASYRSA_SHA256="c2572990ce91112eef8d1b8e4a3b58790da95b68501785c621f69121dfbd22d7"
readonly EASYRSA_URL="https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_VERSION}/EasyRSA-${EASYRSA_VERSION}.tgz"
readonly DEFAULT_PKI_ROOT="${HOME}/.config/unrealops/pki"

usage() {
	cat <<'EOF'
Manage an offline OpenVPN certificate authority and its AWS runtime bundle.

Usage:
  openvpn-pki.sh init \
    --environment NAME --secret-id NAME_OR_ARN [--region AWS_REGION]

  openvpn-pki.sh client \
    --environment NAME --name USER --endpoint HOST \
    [--port 1194] [--output FILE]

  openvpn-pki.sh revoke \
    --environment NAME --name USER \
    [--secret-id NAME_OR_ARN] [--region AWS_REGION]

The encrypted CA is kept under ~/.config/unrealops/pki/NAME by default.
Set OPENVPN_PKI_ROOT to use another offline location. The init command creates
or updates a Secrets Manager secret containing only the runtime server bundle.
The CA private key and client private keys are never uploaded.

Required commands: aws, curl, jq, openvpn, openssl, tar, and sha256sum or shasum.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_environment() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] ||
		die "environment must contain only letters, digits, dots, underscores, and hyphens"
}

validate_identity() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$ ]] ||
		die "client name must contain only letters, digits, dots, underscores, @, and hyphens"
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

base64_file() {
	base64 <"$1" | tr -d '\n'
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
		die "missing ${METADATA_FILE}; run the init command first"

	if [[ -z "${SECRET_ID}" ]]; then
		SECRET_ID="$(jq -er '.secret_id' "${METADATA_FILE}")"
	fi
	if [[ -z "${AWS_REGION_VALUE}" ]]; then
		AWS_REGION_VALUE="$(jq -r '.region // ""' "${METADATA_FILE}")"
	fi
}

install_easyrsa() {
	local archive actual_hash temporary_directory

	if [[ -x "${EASYRSA_HOME}/easyrsa" ]]; then
		[[ "$("${EASYRSA_HOME}/easyrsa" --version 2>&1)" == *"${EASYRSA_VERSION}"* ]] ||
			die "unexpected Easy-RSA version in ${EASYRSA_HOME}"
		return
	fi

	temporary_directory="$(mktemp -d)"
	archive="${temporary_directory}/easyrsa.tgz"
	trap 'rm -rf "${temporary_directory}"' RETURN

	curl --fail --silent --show-error --location "${EASYRSA_URL}" --output "${archive}"
	actual_hash="$(sha256_file "${archive}")"
	[[ "${actual_hash}" == "${EASYRSA_SHA256}" ]] ||
		die "Easy-RSA checksum mismatch: expected ${EASYRSA_SHA256}, received ${actual_hash}"

	mkdir -p "${TOOLS_DIRECTORY}"
	tar -xzf "${archive}" -C "${TOOLS_DIRECTORY}"
	chmod 0700 "${EASYRSA_HOME}/easyrsa"
	rm -rf "${temporary_directory}"
	trap - RETURN
}

run_easyrsa() {
	(
		cd "${EASYRSA_HOME}"
		./easyrsa --pki="${PKI_DIRECTORY}" "$@"
	)
}

run_easyrsa_with_unencrypted_key() {
	(
		# EASYRSA_PASSOUT is needed for the offline CA, but it overrides Easy-RSA's
		# `nopass` argument when inherited by server and client key generation.
		unset EASYRSA_PASSOUT
		run_easyrsa "$@"
	)
}

assert_unencrypted_private_key() {
	local private_key="$1"

	if grep -Eq 'BEGIN ENCRYPTED PRIVATE KEY|Proc-Type: 4,ENCRYPTED' "${private_key}"; then
		die "generated runtime key is encrypted: ${private_key}"
	fi
	openssl pkey -in "${private_key}" -check -noout >/dev/null
}

write_runtime_payload() {
	local payload_file="$1"

	jq -n \
		--arg schema_version "1" \
		--arg ca_crt "$(base64_file "${PKI_DIRECTORY}/ca.crt")" \
		--arg server_crt "$(base64_file "${PKI_DIRECTORY}/issued/server.crt")" \
		--arg server_key "$(base64_file "${PKI_DIRECTORY}/private/server.key")" \
		--arg crl_pem "$(base64_file "${PKI_DIRECTORY}/crl.pem")" \
		--arg tls_crypt_key "$(base64_file "${PKI_DIRECTORY}/private/easyrsa-tls.key")" \
		'{
      schema_version: $schema_version,
      ca_crt: $ca_crt,
      server_crt: $server_crt,
      server_key: $server_key,
      crl_pem: $crl_pem,
      tls_crypt_key: $tls_crypt_key
    }' >"${payload_file}"
}

upload_runtime_bundle() {
	local payload_file secret_arn

	payload_file="$(mktemp)"
	trap 'rm -f "${payload_file}"' RETURN
	write_runtime_payload "${payload_file}"

	if aws_cli secretsmanager describe-secret --secret-id "${SECRET_ID}" >/dev/null 2>&1; then
		secret_arn="$(aws_cli secretsmanager put-secret-value \
			--secret-id "${SECRET_ID}" \
			--secret-string "file://${payload_file}" \
			--query ARN --output text)"
	else
		[[ "${SECRET_ID}" != arn:* ]] ||
			die "secret ARN does not exist; pass a new secret name to init"
		secret_arn="$(aws_cli secretsmanager create-secret \
			--name "${SECRET_ID}" \
			--description "OpenVPN runtime bundle for ${ENVIRONMENT}; CA key is stored offline" \
			--secret-string "file://${payload_file}" \
			--query ARN --output text)"
	fi

	jq -n \
		--arg secret_id "${secret_arn}" \
		--arg region "${AWS_REGION_VALUE}" \
		--arg easyrsa_version "${EASYRSA_VERSION}" \
		'{secret_id: $secret_id, region: $region, easyrsa_version: $easyrsa_version}' \
		>"${METADATA_FILE}"
	chmod 0600 "${METADATA_FILE}"

	rm -f "${payload_file}"
	trap - RETURN
	printf 'Runtime bundle uploaded to %s\n' "${secret_arn}"
}

command_init() {
	[[ -n "${ENVIRONMENT}" ]] || die "--environment is required"
	[[ -n "${SECRET_ID}" ]] || die "--secret-id is required"
	validate_environment "${ENVIRONMENT}"
	[[ ! -e "${PKI_DIRECTORY}/private/ca.key" ]] ||
		die "a CA already exists for ${ENVIRONMENT}; refusing to overwrite it"

	require_command aws
	require_command curl
	require_command jq
	require_command openvpn
	require_command openssl
	require_command tar
	command -v sha256sum >/dev/null 2>&1 || require_command shasum

	mkdir -p "${ENVIRONMENT_DIRECTORY}"
	chmod 0700 "${ENVIRONMENT_DIRECTORY}"
	install_easyrsa

	run_easyrsa init-pki
	printf '\nCreate an encrypted CA. Easy-RSA will prompt for its passphrase.\n' >&2
	run_easyrsa --req-cn="${ENVIRONMENT} OpenVPN CA" build-ca
	run_easyrsa_with_unencrypted_key --batch --req-cn=server build-server-full server nopass
	assert_unencrypted_private_key "${PKI_DIRECTORY}/private/server.key"
	run_easyrsa --batch gen-crl
	run_easyrsa gen-tls-crypt-key

	chmod 0600 \
		"${PKI_DIRECTORY}/private/ca.key" \
		"${PKI_DIRECTORY}/private/server.key" \
		"${PKI_DIRECTORY}/private/easyrsa-tls.key"
	upload_runtime_bundle
	printf 'Offline CA initialized in %s\n' "${ENVIRONMENT_DIRECTORY}"
}

command_client() {
	local output_file

	[[ -n "${ENVIRONMENT}" ]] || die "--environment is required"
	[[ -n "${CLIENT_NAME}" ]] || die "--name is required"
	[[ -n "${ENDPOINT}" ]] || die "--endpoint is required"
	validate_environment "${ENVIRONMENT}"
	validate_identity "${CLIENT_NAME}"
	[[ "${ENDPOINT}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] ||
		die "--endpoint must be an IPv4 address or DNS hostname"
	if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
		die "--port must be between 1 and 65535"
	fi
	[[ -f "${PKI_DIRECTORY}/private/ca.key" ]] ||
		die "missing offline CA for ${ENVIRONMENT}; run init first"
	[[ ! -e "${PKI_DIRECTORY}/issued/${CLIENT_NAME}.crt" ]] ||
		die "certificate ${CLIENT_NAME} already exists"

	install_easyrsa
	require_command openssl
	run_easyrsa_with_unencrypted_key --batch --req-cn="${CLIENT_NAME}" build-client-full "${CLIENT_NAME}" nopass
	assert_unencrypted_private_key "${PKI_DIRECTORY}/private/${CLIENT_NAME}.key"

	output_file="${OUTPUT_FILE:-${ENVIRONMENT_DIRECTORY}/profiles/${CLIENT_NAME}.ovpn}"
	mkdir -p "$(dirname "${output_file}")"
	{
		cat <<EOF
client
dev tun
proto udp4
remote ${ENDPOINT} ${PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server name
auth-nocache
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

<ca>
EOF
		cat "${PKI_DIRECTORY}/ca.crt"
		printf '</ca>\n<cert>\n'
		cat "${PKI_DIRECTORY}/issued/${CLIENT_NAME}.crt"
		printf '</cert>\n<key>\n'
		cat "${PKI_DIRECTORY}/private/${CLIENT_NAME}.key"
		printf '</key>\n<tls-crypt>\n'
		cat "${PKI_DIRECTORY}/private/easyrsa-tls.key"
		printf '</tls-crypt>\n'
	} >"${output_file}"
	chmod 0600 "${output_file}"
	printf 'Client profile written to %s\n' "${output_file}"
}

command_revoke() {
	[[ -n "${ENVIRONMENT}" ]] || die "--environment is required"
	[[ -n "${CLIENT_NAME}" ]] || die "--name is required"
	validate_environment "${ENVIRONMENT}"
	validate_identity "${CLIENT_NAME}"
	[[ -f "${PKI_DIRECTORY}/issued/${CLIENT_NAME}.crt" ]] ||
		die "issued certificate not found: ${CLIENT_NAME}"

	require_command aws
	require_command jq
	require_command openssl
	load_metadata
	install_easyrsa

	run_easyrsa --batch revoke-issued "${CLIENT_NAME}"
	run_easyrsa --batch gen-crl
	upload_runtime_bundle
	printf 'Certificate revoked and CRL published: %s\n' "${CLIENT_NAME}"
}

[[ $# -ge 1 ]] || {
	usage
	exit 1
}

COMMAND="$1"
shift

ENVIRONMENT=""
SECRET_ID=""
AWS_REGION_VALUE=""
CLIENT_NAME=""
ENDPOINT=""
PORT="1194"
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--environment)
		[[ $# -ge 2 ]] || die "--environment requires a value"
		ENVIRONMENT="$2"
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
	--name)
		[[ $# -ge 2 ]] || die "--name requires a value"
		CLIENT_NAME="$2"
		shift 2
		;;
	--endpoint)
		[[ $# -ge 2 ]] || die "--endpoint requires a value"
		ENDPOINT="$2"
		shift 2
		;;
	--port)
		[[ $# -ge 2 ]] || die "--port requires a value"
		PORT="$2"
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

if [[ -n "${ENVIRONMENT}" ]]; then
	PKI_ROOT="${OPENVPN_PKI_ROOT:-${DEFAULT_PKI_ROOT}}"
	ENVIRONMENT_DIRECTORY="${PKI_ROOT}/${ENVIRONMENT}"
	PKI_DIRECTORY="${ENVIRONMENT_DIRECTORY}/pki"
	TOOLS_DIRECTORY="${ENVIRONMENT_DIRECTORY}/tools"
	EASYRSA_HOME="${TOOLS_DIRECTORY}/EasyRSA-${EASYRSA_VERSION}"
	METADATA_FILE="${ENVIRONMENT_DIRECTORY}/metadata.json"
else
	PKI_ROOT=""
	ENVIRONMENT_DIRECTORY=""
	PKI_DIRECTORY=""
	TOOLS_DIRECTORY=""
	EASYRSA_HOME=""
	METADATA_FILE=""
fi

case "${COMMAND}" in
init) command_init ;;
client) command_client ;;
revoke) command_revoke ;;
-h | --help | help) usage ;;
*) die "unknown command: ${COMMAND}" ;;
esac
