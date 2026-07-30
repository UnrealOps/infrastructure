#!/bin/sh
set -eu

system_ca_bundle=/etc/ssl/certs/ca-certificates.crt
custom_ca_file=${LORE_CA_CERT_FILE:-}
runtime_ca_bundle=${TMPDIR:-/tmp}/lore-ca-bundle.crt

if [ -n "$custom_ca_file" ] && [ -r "$custom_ca_file" ]; then
	cp "$system_ca_bundle" "$runtime_ca_bundle"
	printf '\n' >>"$runtime_ca_bundle"
	cat "$custom_ca_file" >>"$runtime_ca_bundle"
	export SSL_CERT_FILE="$runtime_ca_bundle"
	export AWS_CA_BUNDLE="$runtime_ca_bundle"
	export GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="$runtime_ca_bundle"
fi

exec /usr/local/bin/loreserver "$@"
