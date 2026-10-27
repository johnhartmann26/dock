#!/bin/zsh
# Builds ContextDock and installs it to /Applications, replacing the running copy.
# Quitting first lets ContextDock put every window back before the new copy re-parks them.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if pgrep -x ContextDock >/dev/null; then
  osascript -e 'quit app id "dev.johnhartmann.ContextDock"' || true
  for _ in {1..20}; do pgrep -x ContextDock >/dev/null || break; sleep 0.25; done
fi
rm -rf /Applications/ContextDock.app
ditto build/ContextDock.app /Applications/ContextDock.app
# Only the installed copy should answer contextdock:// links and show up in Spotlight.
$LSREGISTER -u build/ContextDock.app 2>/dev/null || true
$LSREGISTER -f /Applications/ContextDock.app
open /Applications/ContextDock.app
echo "Installed /Applications/ContextDock.app"
