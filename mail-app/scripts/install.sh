#!/usr/bin/env bash
# Installs the Mail integration for the current user: the app in ~/Applications, started at login.
# It does not touch Mail or Gmail. macOS asks for permission the first time the app reads from Mail.
#
#   mail-app/scripts/install.sh                     the recommender on this Mac, as before
#   mail-app/scripts/install.sh --remote <url> --ca <pem> --device <name> [--name <label>]
#                                                   a recommender on the home network
#                                                   (specs/005-mail-app-lan, contracts/client-settings.md)
#
# The installer never reads, copies or imports a .p12 or any key. The owner adds this Mac's device
# certificate by opening its .p12 in Finder.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Category Recommender.app"
AGENT="$HOME/Library/LaunchAgents/com.catrec.mail.plist"
DOMAIN="gui/$(id -u)"
SUPPORT="$HOME/Library/Application Support/Category Recommender"
CA_COPY="$SUPPORT/recommender-ca.pem"
PREFS=com.catrec.mail

usage() {
  echo "usage: install.sh [--remote <https url> --ca <ca.crt> --device <device name> [--name <label>]]" >&2
  exit 2
}

REMOTE="" CA="" DEVICE="" NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) [[ $# -ge 2 ]] || usage; REMOTE="$2"; shift 2 ;;
    --ca) [[ $# -ge 2 ]] || usage; CA="$2"; shift 2 ;;
    --device) [[ $# -ge 2 ]] || usage; DEVICE="$2"; shift 2 ;;
    --name) [[ $# -ge 2 ]] || usage; NAME="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ -n "$REMOTE$CA$DEVICE$NAME" ]]; then
  [[ -n "$REMOTE" && -n "$CA" && -n "$DEVICE" ]] || { echo "--remote, --ca and --device go together" >&2; exit 2; }
  [[ "$REMOTE" == https://* ]] || { echo "--remote must be an https:// address" >&2; exit 2; }
  [[ -f "$CA" && -r "$CA" ]] || { echo "cannot read $CA" >&2; exit 2; }
  # Only the CA's certificate, which is public. A key given here by mistake is never copied.
  if grep -q "PRIVATE KEY" "$CA"; then
    echo "$CA holds a private key. Give the CA certificate (ca.crt), never ca.key" >&2
    exit 2
  fi
  [[ "$(grep -c -- "-----BEGIN CERTIFICATE-----" "$CA")" == 1 ]] || {
    echo "$CA must hold exactly one PEM certificate (the CA's ca.crt)" >&2
    exit 2
  }
fi

launchctl bootout "$DOMAIN/com.catrec.mail" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

if [[ -n "$REMOTE" ]]; then
  mkdir -p "$SUPPORT"
  chmod 700 "$SUPPORT"
  cp "$CA" "$CA_COPY"
  chmod 600 "$CA_COPY"
  defaults write "$PREFS" baseURL -string "$REMOTE"
  defaults write "$PREFS" caCertificate -string "$CA_COPY"
  defaults write "$PREFS" deviceCertificate -string "$DEVICE"
  if [[ -n "$NAME" ]]; then
    defaults write "$PREFS" recommenderName -string "$NAME"
  else
    defaults delete "$PREFS" recommenderName 2>/dev/null || true
  fi
  "$DIR/build-app.sh" --no-local-service "$APP"
else
  for key in baseURL caCertificate deviceCertificate recommenderName; do
    defaults delete "$PREFS" "$key" 2>/dev/null || true
  done
  rm -f "$CA_COPY"
  "$DIR/build-app.sh" "$APP"
fi

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
if [[ -n "$REMOTE" ]]; then
  echo "If you have not yet, open this Mac's .p12 in Finder to add its device certificate, then check the connection:"
  echo "  open -n \"$APP\" --args --self-test-remote --out /tmp/catrec-remote.json"
  echo "The report (pass or fail for each step, no addresses or content) appears in /tmp/catrec-remote.json."
fi
