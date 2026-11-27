#!/usr/bin/env bash
# Creates the local CA and the server certificate (research R13). Keys never enter the repo.
#
#   scripts/pki/init-ca.sh <server-lan-ip> [--dns <name>]... [--dir /Users/catrec/.catrec/pki]
#
# --dns adds a name to the server certificate, such as the Mac mini's local hostname
# (krisz-mac-mini.local), so other Macs can reach it by name (specs/005-mail-app-lan, R11).
#
# Tip: after issuing your device certificates, move ca.key to offline storage (e.g. an
# encrypted USB stick). It is only needed to issue new device certificates, and to renew the
# server certificate with new-server-cert.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IP="${1:-}"
[[ -z "$IP" || "$IP" == -* ]] && { echo "usage: $0 <server-lan-ip> [--dns NAME]... [--dir DIR]" >&2; exit 2; }
[[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "server-lan-ip: an IPv4 address such as 192.168.1.10" >&2; exit 2; }
shift
ARGS=("$@")
DIR="${CATREC_PKI_DIR:-/Users/catrec/.catrec/pki}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) [[ $# -ge 2 ]] || { echo "--dir needs a directory" >&2; exit 2; }; DIR="$2"; shift 2 ;;
    --dns) shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

umask 077
mkdir -p "$DIR"
cd "$DIR"
[[ -f ca.key ]] && { echo "a CA already exists in $DIR; refusing to overwrite" >&2; exit 1; }

openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -new -key ca.key -out ca.csr -subj "/CN=catrec home CA"
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
openssl x509 -req -in ca.csr -signkey ca.key -out ca.crt -days 3650 -sha256 -extfile ca.ext
rm -f ca.csr ca.ext
chmod 600 ca.key
chmod 644 ca.crt

CATREC_PKI_DIR="$DIR" "$HERE/new-server-cert.sh" "$IP" ${ARGS[@]+"${ARGS[@]}"}
echo "CA and server certificate written to $DIR"
echo "Install ca.crt as a trusted root on each device so browsers trust the server."
