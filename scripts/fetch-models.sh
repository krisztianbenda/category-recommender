#!/usr/bin/env bash
# Downloads the pinned GGUF model files (constitution I: the ONLY step that uses the internet).
# Run as the admin user, never as `catrec`. It never reads the catrec data directory.
#
#   scripts/fetch-models.sh [--dir /opt/catrec/models] [--only <file>] [--pin]
#
#   --pin   download files whose hash is UNPINNED, print and record their SHA-256 in
#           scripts/models.lock (review, then commit). Without --pin, unpinned files are refused.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOCK="$HERE/models.lock"
DIR="${CATREC_MODELS_DIR:-/opt/catrec/models}"
ONLY=""
PIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --pin) PIN=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(id -un)" == "catrec" ]]; then
  echo "refusing to run as the catrec service user" >&2
  exit 1
fi

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$DIR"
status=0
while read -r name hash url; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
  target="$DIR/$name"

  if [[ "$hash" == "UNPINNED" && $PIN -eq 0 ]]; then
    echo "SKIP  $name: checksum not pinned yet (run with --pin, review, commit models.lock)" >&2
    status=1
    continue
  fi

  if [[ -f "$target" && "$hash" != "UNPINNED" && "$(sha256 "$target")" == "$hash" ]]; then
    echo "OK    $name (already present)"
    continue
  fi

  echo "GET   $name"
  tmp="$target.part"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 -C - -o "$tmp" "$url"
  got="$(sha256 "$tmp")"

  if [[ "$hash" == "UNPINNED" ]]; then
    mv "$tmp" "$target"
    # Record the hash in the lock file (trust on first use).
    sed -i.bak "s|^$name UNPINNED |$name $got |" "$LOCK" && rm -f "$LOCK.bak"
    echo "PIN   $name sha256=$got  <- verify against the publisher, then commit scripts/models.lock"
  elif [[ "$got" == "$hash" ]]; then
    mv "$tmp" "$target"
    echo "OK    $name"
  else
    rm -f "$tmp"
    echo "FAIL  $name: checksum mismatch (expected $hash, got $got)" >&2
    status=1
  fi
done < "$LOCK"

chmod 644 "$DIR"/*.gguf 2>/dev/null || true
exit $status
