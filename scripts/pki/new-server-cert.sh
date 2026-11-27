#!/usr/bin/env bash
# Issues the recommender's server certificate from the existing CA (specs/005-mail-app-lan, R11).
# Use it to add the Mac mini's Bonjour name, after its LAN address changes, or to renew the
# certificate before its 825 days run out. Device certificates are not affected.
#
#   scripts/pki/new-server-cert.sh <server-lan-ip> [--dns <name>]... [--dir /Users/catrec/.catrec/pki]
#
# The certificate names the IP, catrec.local and every --dns name, for example the Mac mini's
# local hostname from System Settings > General > Sharing (krisz-mac-mini.local). The previous
# certificate and key are kept as server.crt.previous and server.key.previous.
set -euo pipefail

usage() { echo "usage: $0 <server-lan-ip> [--dns NAME]... [--dir DIR]" >&2; exit 2; }
IP="${1:-}"
[[ -z "$IP" || "$IP" == -* ]] && usage
[[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "server-lan-ip: an IPv4 address such as 192.168.1.10" >&2; exit 2; }
shift
DIR="${CATREC_PKI_DIR:-/Users/catrec/.catrec/pki}"
NAMES=("catrec.local")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dns)
      [[ $# -ge 2 ]] || usage
      [[ "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || { echo "--dns: letters, digits, - and . only" >&2; exit 2; }
      NAMES+=("$2")
      shift 2
      ;;
    --dir) [[ $# -ge 2 ]] || usage; DIR="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

umask 077
[[ -f "$DIR/ca.key" ]] || { echo "no CA in $DIR (run init-ca.sh, or bring the offline ca.key back)" >&2; exit 1; }
cd "$DIR"

SAN="IP:$IP"
for name in "${NAMES[@]}"; do SAN="$SAN,DNS:$name"; done

openssl ecparam -name prime256v1 -genkey -noout -out server.key.new
openssl req -new -key server.key.new -out server.csr -subj "/CN=catrec"
printf 'basicConstraints=CA:FALSE\nsubjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' "$SAN" > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt.new -days 825 -sha256 -extfile server.ext
rm -f server.csr server.ext

if [[ -f server.crt ]]; then
  mv -f server.crt server.crt.previous
  [[ -f server.key ]] && mv -f server.key server.key.previous
fi
mv server.key.new server.key
mv server.crt.new server.crt
chmod 600 server.key
chmod 644 server.crt

echo "Server certificate written to $DIR, for: ${SAN//,/ }"
echo "Restart the service: sudo launchctl kickstart -k system/com.catrec.service"
