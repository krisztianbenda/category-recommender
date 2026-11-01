#!/usr/bin/env bash
# Issues a client certificate for one device and prints its fingerprint for access.devices.
#
#   scripts/pki/new-device.sh <device-name> [--dir /Users/catrec/.catrec/pki] [--days 825]
#
# Writes <dir>/devices/<name>.p12 (password-protected; you will be prompted) to import on the
# device. Then add the printed entry to access.devices in the service config; it applies within
# a second, no restart needed.
set -euo pipefail

NAME="${1:-}"
[[ -z "$NAME" || "$NAME" == -* ]] && { echo "usage: $0 <device-name> [--dir DIR] [--days N]" >&2; exit 2; }
[[ "$NAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "device name: letters, digits, . _ - only" >&2; exit 2; }
shift
DIR="${CATREC_PKI_DIR:-/Users/catrec/.catrec/pki}"
DAYS=825
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

umask 077
[[ -f "$DIR/ca.key" ]] || { echo "no CA in $DIR (run init-ca.sh, or bring the offline ca.key back)" >&2; exit 1; }
OUT="$DIR/devices"
mkdir -p "$OUT"
cd "$OUT"
[[ -f "$NAME.crt" ]] && { echo "$NAME already exists" >&2; exit 1; }

openssl ecparam -name prime256v1 -genkey -noout -out "$NAME.key"
openssl req -new -key "$NAME.key" -out "$NAME.csr" -subj "/CN=$NAME"
printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\n' > "$NAME.ext"
openssl x509 -req -in "$NAME.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -out "$NAME.crt" -days "$DAYS" -sha256 -extfile "$NAME.ext"

LEGACY=()
openssl version | grep -q '^OpenSSL 3' && LEGACY=(-legacy) # Apple keychains need legacy PKCS#12
if [[ -n "${CATREC_P12_PASS:-}" ]]; then
  openssl pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -name "$NAME" -inkey "$NAME.key" -in "$NAME.crt" -certfile "$DIR/ca.crt" -out "$NAME.p12" -passout env:CATREC_P12_PASS
else
  openssl pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -name "$NAME" -inkey "$NAME.key" -in "$NAME.crt" -certfile "$DIR/ca.crt" -out "$NAME.p12"
fi
rm -f "$NAME.csr" "$NAME.ext" "$NAME.key"

FP="$(openssl x509 -in "$NAME.crt" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr 'a-f' 'A-F')"
echo
echo "Import $OUT/$NAME.p12 on the device, then add to access.devices:"
echo "    - name: $NAME"
echo "      fingerprintSha256: \"$FP\""
echo "      user: owner"
