#!/bin/bash
# Builds build/Lifelog.app (the menu-bar app).
#
# Signing: always the same local identity ("Lifelog Local Signing", created on first build by tools/signing-cert.sh).
# macOS keys privacy grants to the signing identity, so a stable one means Screen Recording / Accessibility survive
# rebuilds. Don't sign with an Apple Development cert: they expire yearly and the keychain's first one can change,
# and every change silently voids the grants. Override with LIFELOG_SIGN_IDENTITY=<sha1 or name> if you must.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Lifelog.app
IDENTITY="${LIFELOG_SIGN_IDENTITY:-$(tools/signing-cert.sh)}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f recorder/Info.plist "$APP/Contents/Info.plist"
[ -f recorder/AppIcon.icns ] && /bin/cp -f recorder/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -module-name Lifelog \
  recorder/*.swift -o "$APP/Contents/MacOS/Lifelog"
codesign --force --sign "$IDENTITY" --identifier com.lifelog.recorder "$APP" >/dev/null
echo "built $APP (signed with $IDENTITY)"
echo "  designated requirement: $(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')"
