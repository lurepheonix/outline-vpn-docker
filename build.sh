#!/bin/bash

CONFIG_DIR=config

if [[ ! -f .env ]]
then
  echo "Environment variables not found!"
  exit
fi

# trunk-ignore(shellcheck/SC1091)
set -o allexport; source .env; set +o allexport

function fetch() {
  curl --silent --show-error --fail "$@"
}

function set_hostname() {
  # These are URLs that return the client's apparent IP address.
  # We have more than one to try in case one starts failing
  # (e.g. https://github.com/Jigsaw-Code/outline-server/issues/776).
  local -ar urls=(
    'https://icanhazip.com/'
    'https://ipinfo.io/ip'
    'https://domains.google.com/checkip'
  )
  for url in "${urls[@]}"; do
    PUBLIC_HOSTNAME="$(fetch --ipv4 "${url}")" && return
  done
  echo "Failed to determine the server's IP address.  Try using --hostname <server IP>." >&2
  return 1
}

function generate_certificate() {
  # Generate self-signed cert and store it in the persistent state directory.
  local -r CERTIFICATE_NAME="${CONFIG_DIR}/shadowbox-selfsigned"
  readonly SB_CERTIFICATE_FILE="${CERTIFICATE_NAME}.crt"
  readonly SB_PRIVATE_KEY_FILE="${CERTIFICATE_NAME}.key"
  declare -a openssl_req_flags=(
    -x509 -nodes -days 36500 -newkey rsa:4096
    -subj "/CN=${PUBLIC_HOSTNAME}"
    -keyout "${SB_PRIVATE_KEY_FILE}" -out "${SB_CERTIFICATE_FILE}"
  )
  openssl req "${openssl_req_flags[@]}" >&2
}

function generate_certificate_fingerprint() {
  # Example format: "SHA256 Fingerprint=BD:DB:C9:A4:39:5C:B3:4E:6E:CF:18:43:61:9F:07:A2:09:07:37:35:63:67"
  local CERT_OPENSSL_FINGERPRINT
  CERT_OPENSSL_FINGERPRINT="$(openssl x509 -in "${SB_CERTIFICATE_FILE}" -noout -sha256 -fingerprint)" || return
  # Example format: "BDDBC9A4395CB34E6ECF1843619F07A2090737356367"
  local CERT_HEX_FINGERPRINT
  CERT_HEX_FINGERPRINT="$(echo "${CERT_OPENSSL_FINGERPRINT#*=}" | tr -d :)" || return
  echo $CERT_HEX_FINGERPRINT
  output_config "certSha256:${CERT_HEX_FINGERPRINT}"
}

function create_persisted_state_dir() {
  readonly STATE_DIR="${CONFIG_DIR}/persisted-state"
  mkdir -p "${STATE_DIR}"
  chmod ug+rwx,g+s,o-rwx "${STATE_DIR}"
}

# Generate a secret key for access to the Management API and store it in a tag.
# 16 bytes = 128 bits of entropy should be plenty for this use.
function safe_base64() {
  # Implements URL-safe base64 of stdin, stripping trailing = chars.
  # Writes result to stdout.
  # TODO: this gives the following errors on Mac:
  #   base64: invalid option -- w
  #   tr: illegal option -- -
  local url_safe
  url_safe="$(base64 -w 0 - | tr '/+' '_-')"
  echo -n "${url_safe%%=*}"  # Strip trailing = chars
}

function join() {
  local IFS="$1"
  shift
  echo "$*"
}

function output_config() {
  echo "$@" >> "${ACCESS_CONFIG}"
}

function add_api_url_to_config() {
  output_config "apiUrl:${PUBLIC_API_URL}"
}

function write_config() {
  local -a config=()
  if (( SB_KEYS_PORT != 0 )); then
    config+=("\"portForNewAccessKeys\": ${SB_KEYS_PORT}")
  fi
  # printf is needed to escape the hostname.
  config+=("$(printf '"hostname": "%q"' "${PUBLIC_HOSTNAME}")")
  echo "{$(join , "${config[@]}")}" > "${CONFIG_DIR}/shadowbox_server_config.json"
}

function go() {
  readonly ACCESS_CONFIG="${ACCESS_CONFIG:-${CONFIG_DIR}/access.txt}"

  mkdir "${CONFIG_DIR}"
  create_persisted_state_dir
  set_hostname
  generate_certificate
  generate_certificate_fingerprint
  write_config
}

go
