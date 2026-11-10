#!/usr/bin/env bash
# Runs the recommender on this computer as the current user: the two llama-server processes on
# loopback plus the service at http://127.0.0.1:8080/. Ctrl+C stops all three.
#
#   scripts/run-local.sh [--llm-file qwen3-4b-instruct-q4_k_m.gguf]
#
# First run creates ~/.catrec/config.yaml from deploy/local/config.yaml.template.
# Env overrides: CATREC_CONFIG, CATREC_MODELS_DIR (default /opt/catrec/models).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME/.catrec"
CONFIG="${CATREC_CONFIG:-$HOME_DIR/config.yaml}"
MODELS_DIR="${CATREC_MODELS_DIR:-/opt/catrec/models}"
LLM_FILE=qwen3-8b-instruct-q4_k_m.gguf
EMBED_FILE=bge-m3-q8_0.gguf
while [[ $# -gt 0 ]]; do
  case "$1" in
    --llm-file) LLM_FILE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
LLM_ALIAS="${LLM_FILE%.gguf}"
EMBED_ALIAS="${EMBED_FILE%.gguf}"

command -v llama-server >/dev/null || { echo "llama-server not found (brew install llama.cpp)" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found (brew install node@24)" >&2; exit 1; }
[[ "$(node -p 'process.versions.node.split(".")[0]')" == 24 ]] || { echo "Node.js 24 required (found $(node --version))" >&2; exit 1; }
for f in "$LLM_FILE" "$EMBED_FILE"; do
  [[ -f "$MODELS_DIR/$f" ]] || { echo "missing $MODELS_DIR/$f (run scripts/fetch-models.sh)" >&2; exit 1; }
done

for port in 8080 8081 8082; do
  if nc -z -G 1 127.0.0.1 "$port" 2>/dev/null; then
    echo "port $port is already in use (old com.catrec launchd services still running? see docs/operations.md)" >&2
    exit 1
  fi
done

install -d -m 700 "$HOME_DIR" "$HOME_DIR/logs"
if [[ ! -f "$CONFIG" ]]; then
  sed -e "s|__HOME__|$HOME|g" -e "s|__LLM_ALIAS__|$LLM_ALIAS|g" "$REPO/deploy/local/config.yaml.template" > "$CONFIG"
  chmod 600 "$CONFIG"
  echo "created $CONFIG"
elif ! grep -q "model: $LLM_ALIAS\$" "$CONFIG"; then
  echo "note: $CONFIG has a different llm.model than $LLM_ALIAS; update it to match --llm-file" >&2
fi

(cd "$REPO/service" && { [[ -d node_modules ]] || npm ci; } && npm run --silent build)

PIDS=()
cleanup() { [[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

llama-server --host 127.0.0.1 --port 8081 --model "$MODELS_DIR/$LLM_FILE" --alias "$LLM_ALIAS" \
  --ctx-size 8192 --parallel 1 --n-gpu-layers 999 --no-webui >"$HOME_DIR/logs/llm.log" 2>&1 &
PIDS+=($!)
llama-server --host 127.0.0.1 --port 8082 --model "$MODELS_DIR/$EMBED_FILE" --alias "$EMBED_ALIAS" \
  --embedding --pooling cls --ctx-size 8192 --batch-size 8192 --ubatch-size 8192 \
  --n-gpu-layers 999 --no-webui >"$HOME_DIR/logs/embeddings.log" 2>&1 &
PIDS+=($!)

echo "loading models (logs in $HOME_DIR/logs)..."
for port in 8081 8082; do
  for _ in $(seq 1 120); do
    curl -fs "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fs "http://127.0.0.1:$port/health" >/dev/null 2>&1 || { echo "model server on port $port did not start; see $HOME_DIR/logs" >&2; exit 1; }
done

echo "open http://127.0.0.1:8080/  (Ctrl+C to stop)"
# In the background so that a SIGTERM to this script (from the Mail app, say) runs cleanup right away:
# bash delays traps until a foreground child exits.
CATREC_CONFIG="$CONFIG" node "$REPO/service/dist/src/main.js" &
PIDS+=($!)
wait "$!"
