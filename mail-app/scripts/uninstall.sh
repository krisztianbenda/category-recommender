#!/usr/bin/env bash
# Removes the Mail integration completely (FR-021). Labels in Gmail and what the recommender has
# learned stay; delete learned data under "Learned data" in the web UI if you want it gone.
set -euo pipefail

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/com.catrec.mail" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.catrec.mail.plist"
rm -rf "$HOME/Applications/Category Recommender.app"
defaults delete com.catrec.mail 2>/dev/null || true
tccutil reset AppleEvents com.catrec.mail 2>/dev/null || true
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "removed"
