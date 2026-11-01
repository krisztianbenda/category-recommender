#!/usr/bin/env bash
# Creates the local CA and the server certificate (research R13). Keys never enter the repo.
#
#   scripts/pki/init-ca.sh <server-lan-ip> [--dir /Users/catrec/.catrec/pki]
#
# Tip: after issuing your device certificates, move ca.key to offline storage (e.g. an
# encrypted USB stick). It is only needed to issue new device certificates.
set -euo pipefail

IP="${1:-}"
[[ -z "$IP" || "$IP" == -* ]] && { echo "usage: $0 <server-lan-ip> [--dir DIR]" >&2; exit 2; }
shift
DIR="${CATREC_PKI_DIR:-/Users/catrec/.catrec/pki}"
[[ "${1:-}" == "--dir" ]] && DIR="$2"

umask 077
mkdir -p "$DIR"
cd "$DIR"
[[ -f ca.key ]] && { echo "a CA already exists in $DIR; refusing to overwrite" >&2; exit 1; }

openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -new -key ca.key -out ca.csr -subj "/CN=catrec home CA"
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
openssl x509 -req -in ca.csr -signkey ca.key -out ca.crt -days 3650 -sha256 -extfile ca.ext

openssl ecparam -name prime256v1 -genkey -noout -out server.key
openssl req -new -key server.key -out server.csr -subj "/CN=catrec"
printf 'basicConstraints=CA:FALSE\nsubjectAltName=IP:%s,DNS:catrec.local\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' "$IP" > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256 -extfile server.ext

rm -f ./*.csr ./*.ext
chmod 600 ca.key server.key
chmod 644 ca.crt server.crt
echo "CA and server certificate written to $DIR"
echo "Install ca.crt as a trusted root on each device so browsers trust the server."
