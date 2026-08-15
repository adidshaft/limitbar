#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=build/LimitBar.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/LimitBar" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework ServiceManagement -framework SwiftUI

cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity so the app's designated requirement — and therefore
# the "Always Allow" keychain grant it earns for the Claude credential — stays
# constant across rebuilds. Ad-hoc (`--sign -`) changes the cdhash every build,
# which silently revokes that grant and forces re-approval each time.
# Identity resolves from LIMITBAR_SIGN_ID, else a git-ignored ./.signing-id file
# (so no personal cert name lands in this public repo), else ad-hoc.
SIGN_ID="${LIMITBAR_SIGN_ID:-}"
if [ -z "$SIGN_ID" ] && [ -f .signing-id ]; then
  SIGN_ID="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' .signing-id | head -n1 | tr -d '\r\n')"
fi
if [ -n "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "Built $APP  (signed: $SIGN_ID)"
else
  codesign --force --sign - "$APP"
  echo "Built $APP  (ad-hoc — set ./.signing-id for a persistent keychain grant)"
fi
