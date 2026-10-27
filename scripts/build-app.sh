#!/bin/zsh
# Builds build/ContextDock.app. Signs with your Apple Development certificate (if present) so the
# Accessibility grant survives rebuilds; ad-hoc signing would need re-granting after every build.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build" || true
swift build -c release >/dev/null
APP=build/ContextDock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ContextDock "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Keychain order isn't stable, and a different certificate voids the Accessibility grant, so the
# first pick is remembered in .signing-identity (by SHA-1).
if [[ -z "${CODESIGN_IDENTITY:-}" && ! -s .signing-identity ]]; then
  security find-identity -v -p codesigning | grep -m1 'Apple Development' | awk '{print $2}' > .signing-identity || true
fi
IDENTITY="${CODESIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null)}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
