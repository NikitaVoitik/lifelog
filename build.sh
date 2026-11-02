#!/bin/bash
# Builds build/Lifelog.app (the menu-bar app). Signs with your Apple Development identity if you have one,
# so macOS privacy permissions survive rebuilds; falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Lifelog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f recorder/Info.plist "$APP/Contents/Info.plist"
[ -f recorder/AppIcon.icns ] && /bin/cp -f recorder/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -module-name Lifelog \
  recorder/*.swift -o "$APP/Contents/MacOS/Lifelog"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}' || true)
codesign --force --sign "${IDENTITY:--}" --identifier com.lifelog.recorder "$APP" >/dev/null
echo "built $APP (signed with ${IDENTITY:-ad-hoc})"
