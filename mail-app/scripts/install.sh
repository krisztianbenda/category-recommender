#!/usr/bin/env bash
# Installs the Mail integration for the current user: the app in ~/Applications, started at login.
# It does not touch Mail or Gmail. macOS asks for permission the first time the app reads from Mail.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Category Recommender.app"
AGENT="$HOME/Library/LaunchAgents/com.catrec.mail.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/com.catrec.mail" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
"$DIR/build-app.sh" "$APP"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.catrec.mail</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/CategoryRecommender</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$DOMAIN" "$AGENT"
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "installed. In Mail, select an email and press Control-Option-L, or click the tag icon in the menu bar."
