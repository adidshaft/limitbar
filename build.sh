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
codesign --force --sign - "$APP"
echo "Built $APP"
