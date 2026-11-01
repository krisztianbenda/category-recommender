#!/usr/bin/env bash
# One-time macOS setup (run with sudo from the repository root, after scripts/fetch-models.sh):
#   - creates the non-admin service user `catrec` and its data/log dirs (mode 700)
#   - builds the service and installs it to /opt/catrec/service
#   - installs the launchd units and the pf egress anchor
#
#   sudo deploy/macos/setup.sh --config /Users/catrec/.catrec/config.yaml [--port 8443]
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="/Users/catrec/.catrec/config.yaml"
PORT=8443
MODELS_DIR="${CATREC_MODELS_DIR:-/opt/catrec/models}"
SERVICE_DIR=/opt/catrec/service
LLM_FILE=qwen3-8b-instruct-q4_k_m.gguf
LLM_ALIAS=qwen3-8b-instruct-q4_k_m
EMBED_FILE=bge-m3-q8_0.gguf
EMBED_ALIAS=bge-m3-q8_0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --llm-file) LLM_FILE="$2"; LLM_ALIAS="${2%.gguf}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

LLAMA_SERVER="$(command -v llama-server || true)"
NODE="$(command -v node || true)"
[[ -x "$LLAMA_SERVER" ]] || { echo "llama-server not found (brew install llama.cpp)" >&2; exit 1; }
[[ -x "$NODE" ]] || { echo "node not found (Node.js 22 LTS)" >&2; exit 1; }
for f in "$LLM_FILE" "$EMBED_FILE"; do
  [[ -f "$MODELS_DIR/$f" ]] || { echo "missing $MODELS_DIR/$f (run scripts/fetch-models.sh)" >&2; exit 1; }
done
fdesetup status | grep -q "FileVault is On" || echo "WARNING: FileVault is off; the service will refuse to start with storage.encryption=filevault" >&2

# 1. Service user (no admin rights, no login shell).
if ! id catrec >/dev/null 2>&1; then
  sysadminctl -addUser catrec -fullName "catrec service" -shell /usr/bin/false -home /Users/catrec
  dscl . -create /Users/catrec IsHidden 1
fi
install -d -o catrec -m 700 /Users/catrec/.catrec "/Users/catrec/Library/Application Support/catrec"
install -d -o catrec -m 700 /var/log/catrec

# 2. Build and install the service (no network needed once node_modules is present).
(cd "$REPO/service" && sudo -u "${SUDO_USER:-$USER}" npm ci && sudo -u "${SUDO_USER:-$USER}" npm run build)
install -d -m 755 "$SERVICE_DIR"
rsync -a --delete "$REPO/service/dist" "$REPO/service/node_modules" "$REPO/service/package.json" "$SERVICE_DIR/"
chown -R root:wheel "$SERVICE_DIR"

# 3. launchd units.
fill() {
  sed -e "s|__LLAMA_SERVER__|$LLAMA_SERVER|g" -e "s|__NODE__|$NODE|g" \
      -e "s|__MODELS_DIR__|$MODELS_DIR|g" -e "s|__LLM_FILE__|$LLM_FILE|g" -e "s|__LLM_ALIAS__|$LLM_ALIAS|g" \
      -e "s|__EMBED_FILE__|$EMBED_FILE|g" -e "s|__EMBED_ALIAS__|$EMBED_ALIAS|g" \
      -e "s|__SERVICE_DIR__|$SERVICE_DIR|g" -e "s|__CONFIG__|$CONFIG|g" -e "s|__PORT__|$PORT|g" "$1"
}
for unit in com.catrec.pf com.catrec.llm com.catrec.embeddings com.catrec.service; do
  fill "$REPO/deploy/macos/launchd/$unit.plist" > "/Library/LaunchDaemons/$unit.plist"
  chown root:wheel "/Library/LaunchDaemons/$unit.plist"
  chmod 644 "/Library/LaunchDaemons/$unit.plist"
done

# 4. pf egress anchor.
fill "$REPO/deploy/macos/pf/catrec.conf" > /etc/pf.anchors/catrec
if ! grep -q 'anchor "catrec"' /etc/pf.conf; then
  cp /etc/pf.conf "/etc/pf.conf.catrec-backup.$(date +%Y%m%d%H%M%S)"
  printf '\nanchor "catrec"\nload anchor "catrec" from "/etc/pf.anchors/catrec"\n' >> /etc/pf.conf
fi
pfctl -nf /etc/pf.conf # syntax check
pfctl -E -f /etc/pf.conf 2>/dev/null || true

for unit in com.catrec.pf com.catrec.llm com.catrec.embeddings com.catrec.service; do
  launchctl bootout system "/Library/LaunchDaemons/$unit.plist" 2>/dev/null || true
  launchctl bootstrap system "/Library/LaunchDaemons/$unit.plist"
done

echo "Installed. Check: sudo launchctl list | grep catrec ; sudo pfctl -a catrec -sr"
echo "Config: $CONFIG (must exist, owned by catrec, mode 600)"
