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
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
