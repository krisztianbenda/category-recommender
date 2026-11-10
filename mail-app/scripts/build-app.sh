#!/usr/bin/env bash
# Builds the app bundle at the given path. Writes where to find the local service into the bundle,
# so nothing host-specific is compiled in (constitution IV).
#
#   mail-app/scripts/build-app.sh "$HOME/Applications/Category Recommender.app"
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
APP="${1:?usage: build-app.sh <path to .app>}"
[[ "$APP" == *.app ]] || { echo "the path must end in .app" >&2; exit 2; }

for tool in node npm llama-server; do
  command -v "$tool" >/dev/null || { echo "$tool not found (see docs/operations.md)" >&2; exit 1; }
done
[[ "$(node -p 'process.versions.node.split(".")[0]')" == 24 ]] || { echo "Node.js 24 required (found $(node --version))" >&2; exit 1; }

cd "$DIR"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/CategoryRecommender"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CategoryRecommender"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/mail-bridge.js "$APP/Contents/Resources/mail-bridge.js"

# The tools the local service needs, found now because an app gets a minimal PATH.
TOOLS_PATH="$(dirname "$(command -v node)"):$(dirname "$(command -v llama-server)"):/usr/bin:/bin:/usr/sbin:/sbin"
RUN_LOCAL="$REPO/scripts/run-local.sh" TOOLS_PATH="$TOOLS_PATH" node -e '
  require("fs").writeFileSync(process.argv[1], JSON.stringify({
    runLocalScript: process.env.RUN_LOCAL,
    path: process.env.TOOLS_PATH,
  }, null, 2) + "\n");
' "$APP/Contents/Resources/install.json"

codesign --force --sign - --identifier com.catrec.mail "$APP" 2>/dev/null
echo "built $APP"
