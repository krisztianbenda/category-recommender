#!/usr/bin/env bash
# End to end with synthetic data: the real service and the real client, with a stub model and a
# synthetic Mail. Also checks that the running app only talks to this computer (SC-006). Touches
# neither the real Mail nor the real data directory. The same against the service in LAN mode, with
# a throwaway PKI and a throwaway keychain that is never added to the user's keychain search list
# (specs/005-mail-app-lan, research R14).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
WORK="$(mktemp -d)"
SERVICE_PID=""
APP_PID=""
KEYCHAIN="$WORK/e2e.keychain-db"
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$SERVICE_PID" ]] && kill "$SERVICE_PID" 2>/dev/null || true
  [[ -f "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN" 2>/dev/null || true
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
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/addresses" "$1"; }
SERVICE_URL="$(field service)"
REDIRECT_URL="$(field redirector)"
LAN_URL="$(field lan)"
CA_FILE="$(field caFile)"
DEVICE="$(field deviceName)"
UNLISTED="$(field unlistedName)"
IMPOSTOR_URL="$(field impostor)"
IMPOSTOR_HITS_URL="$(field impostorHits)"

# The test device certificates, in a keychain file of their own, usable without a prompt (-A).
security create-keychain -p catrec-e2e "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p catrec-e2e "$KEYCHAIN"
for p12 in "$(field deviceP12)" "$(field unlistedP12)"; do
  security import "$p12" -k "$KEYCHAIN" -P "$(field p12Password)" -A >/dev/null
done
LAN_ENV=(CATREC_BASE_URL="$LAN_URL" CATREC_CA_FILE="$CA_FILE" CATREC_DEVICE_CERT="$DEVICE" CATREC_KEYCHAIN="$KEYCHAIN")

echo "== client and session against the real service"
CATREC_TEST_BASE_URL="$SERVICE_URL" CATREC_TEST_REDIRECT_URL="$REDIRECT_URL" \
  "$DIR/scripts/test.sh" --filter LiveServiceTests

echo "== client against the service in LAN mode, with a test device certificate"
CATREC_TEST_LAN_URL="$LAN_URL" CATREC_TEST_CA_FILE="$CA_FILE" CATREC_TEST_DEVICE_CERT="$DEVICE" \
  CATREC_KEYCHAIN="$KEYCHAIN" CATREC_TEST_UNLISTED_CERT="$UNLISTED" \
  CATREC_TEST_IMPOSTOR_URL="$IMPOSTOR_URL" CATREC_TEST_IMPOSTOR_HITS_URL="$IMPOSTOR_HITS_URL" \
  "$DIR/scripts/test.sh" --filter LiveServiceTestsLAN

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

echo "== the same batch against the service in LAN mode"
env "${LAN_ENV[@]}" CATREC_MAIL_LOG="$WORK/batch-lan.log" \
  .build/debug/CategoryRecommender --demo --batch --drive "$WORK/batch-lan-drive.json"
cat "$WORK/batch-lan-drive.json" && echo
if [[ ! -s "$WORK/batch-lan-drive.json" ]] || grep -q false "$WORK/batch-lan-drive.json"; then
  echo "batch window keys against the LAN service:" >&2
  cat "$WORK/batch-lan-drive.json" >&2
  exit 1
fi
if grep -qE 'newborn|clinic|Family|Gadgets|Porto|example|127\.0\.0\.1' "$WORK/batch-lan.log"; then
  echo "the LAN batch log contains personal-looking content or an address" >&2
  exit 1
fi
grep -q recommender_remote "$WORK/batch-lan.log" || { echo "no recommender_remote event" >&2; exit 1; }
echo "ok"

echo "== the remote self-test"
selftest() {
  local out="$1"
  shift
  env "${LAN_ENV[@]}" "$@" .build/debug/CategoryRecommender --self-test-remote --out "$out"
  cat "$out"
  if grep -qE '127\.0\.0\.1|localhost|example\.test|fabricated|Self-test' "$out"; then
    echo "the self-test report contains an address or content" >&2
    exit 1
  fi
}
expect_steps() {
  python3 - "$@" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
want = dict(pair.split("=") for pair in sys.argv[2:])
got = {step["name"]: step["result"] for step in report["steps"]}
order = ["address", "reachable", "identity", "accepted", "model", "timing"]
problems = [f"{name}: {got.get(name)} (want {result})" for name, result in want.items() if got.get(name) != result]
if [step["name"] for step in report["steps"]] != order:
    problems.append(f"steps out of order: {[step['name'] for step in report['steps']]}")
if report["ok"] != all(result == "pass" for result in got.values()):
    problems.append("ok does not match the steps")
if want.get("timing") == "pass" and not isinstance(report.get("timingMs"), int):
    problems.append("no timingMs")
if problems:
    sys.exit("self-test report: " + "; ".join(problems))
PY
}
selftest "$WORK/selftest-ok.json"
expect_steps "$WORK/selftest-ok.json" address=pass reachable=pass identity=pass accepted=pass model=pass timing=pass
selftest "$WORK/selftest-impostor.json" CATREC_BASE_URL="$IMPOSTOR_URL"
expect_steps "$WORK/selftest-impostor.json" address=pass reachable=pass identity=fail accepted=not_run timing=not_run
selftest "$WORK/selftest-unlisted.json" CATREC_DEVICE_CERT="$UNLISTED"
expect_steps "$WORK/selftest-unlisted.json" identity=pass accepted=fail model=not_run
selftest "$WORK/selftest-closed.json" CATREC_BASE_URL="https://127.0.0.1:1"
expect_steps "$WORK/selftest-closed.json" address=pass reachable=fail identity=not_run
selftest "$WORK/selftest-public.json" CATREC_BASE_URL="https://203.0.113.7:8443"
expect_steps "$WORK/selftest-public.json" address=fail reachable=not_run
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
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
echo "ok"

echo "== with the LAN service, the running app only connects to it"
LAN_PORT="${LAN_URL##*:}"
env "${LAN_ENV[@]}" CATREC_MAIL_LOG="$WORK/app-lan.log" .build/debug/CategoryRecommender --demo --batch &
APP_PID=$!
sleep 5
OTHER="$(lsof -nP -a -p "$APP_PID" -iTCP -iUDP 2>/dev/null | awk 'NR>1 {print $9}' | grep -vE "^127\.0\.0\.1:[0-9]+->127\.0\.0\.1:$LAN_PORT\$" || true)"
if [[ -n "$OTHER" ]]; then
  echo "connections other than to the LAN service:" >&2
  echo "$OTHER" >&2
  exit 1
fi
echo "ok"
