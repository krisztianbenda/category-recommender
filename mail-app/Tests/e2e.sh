#!/usr/bin/env bash
# End to end with synthetic data: the real service and the real client, with a stub model and a
# synthetic Mail. Also checks that the running app only talks to this computer (SC-006). Touches
# neither the real Mail nor the real data directory.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
WORK="$(mktemp -d)"
SERVICE_PID=""
APP_PID=""
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$SERVICE_PID" ]] && kill "$SERVICE_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

[[ -d "$REPO/service/node_modules" ]] || (cd "$REPO/service" && npm ci)
"$REPO/service/node_modules/.bin/tsx" --tsconfig "$REPO/service/tsconfig.json" "$DIR/tests/stub-service.mts" >"$WORK/addresses" &
SERVICE_PID=$!
for _ in $(seq 1 100); do
  [[ -s "$WORK/addresses" ]] && break
  sleep 0.2
done
[[ -s "$WORK/addresses" ]] || { echo "stub service did not start" >&2; exit 1; }
SERVICE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["service"])' "$WORK/addresses")"
REDIRECT_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["redirector"])' "$WORK/addresses")"

echo "== client and session against the real service"
CATREC_TEST_BASE_URL="$SERVICE_URL" CATREC_TEST_REDIRECT_URL="$REDIRECT_URL" \
  "$DIR/scripts/test.sh" --filter LiveServiceTests

echo "== a batch in the window, through real key events"
cd "$DIR"
swift build >/dev/null
CATREC_BASE_URL="$SERVICE_URL" CATREC_MAIL_LOG="$WORK/batch.log" \
  .build/debug/CategoryRecommender --demo --batch --drive "$WORK/batch-drive.json"
cat "$WORK/batch-drive.json" && echo
if [[ ! -s "$WORK/batch-drive.json" ]] || grep -q false "$WORK/batch-drive.json"; then
  echo "batch window keys:" >&2
  cat "$WORK/batch-drive.json" >&2
  exit 1
fi
if grep -qE 'newborn|clinic|Family|Gadgets|Porto|example' "$WORK/batch.log"; then
  echo "the batch log contains personal-looking content" >&2
  exit 1
fi
grep -q batch_opened "$WORK/batch.log" || { echo "no batch_opened event" >&2; exit 1; }
echo "ok"

echo "== the running app only connects to this computer"
cd "$DIR"
swift build >/dev/null
CATREC_BASE_URL="$SERVICE_URL" CATREC_MAIL_LOG="$WORK/app.log" \
  .build/debug/CategoryRecommender --demo --batch &
APP_PID=$!
sleep 5
OUTSIDE="$(lsof -nP -a -p "$APP_PID" -iTCP -iUDP 2>/dev/null | awk 'NR>1 {print $9}' | grep -vE '127\.0\.0\.1|\[::1\]' || true)"
if [[ -n "$OUTSIDE" ]]; then
  echo "unexpected connections:" >&2
  echo "$OUTSIDE" >&2
  exit 1
fi
if grep -qE 'newborn|clinic|Family|Gadgets' "$WORK/app.log"; then
  echo "the log contains personal-looking content" >&2
  exit 1
fi
echo "ok"
