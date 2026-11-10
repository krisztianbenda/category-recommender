#!/usr/bin/env bash
# Runs all mail-app checks that need neither Mail nor real data.
# Swift Testing needs extra search paths when only the Command Line Tools are installed.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

ARGS=()
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
  ARGS+=(-Xswiftc -F -Xswiftc "$CLT/Frameworks"
         -Xlinker -F -Xlinker "$CLT/Frameworks"
         -Xlinker -rpath -Xlinker "$CLT/Frameworks"
         -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi

swift test --disable-xctest --enable-swift-testing "${ARGS[@]}" "$@"
node --test tests/*.test.mjs
