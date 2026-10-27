# ContextDock

A floating Dock with three contexts (Work, Personal, Agents). Each context has its own Dock apps and its own real windows. Clicking a context swaps the whole set of windows on screen, and everything is still there when you come back. Nothing is closed or relaunched: windows outside the current context are parked offscreen in a corner. See [docs/DECISIONS.md](docs/DECISIONS.md) for why.

## Build and run

Requires macOS 26 and Xcode 26 or later (Swift 6). No other dependencies.

```bash
./scripts/build-app.sh
open build/ContextDock.app
```

On first launch, approve **ContextDock** in System Settings > Privacy & Security > Accessibility. It starts within a second of the grant. The build signs with your first "Apple Development" certificate so the grant survives rebuilds. Set `CODESIGN_IDENTITY` to pick a different one.

## Using it

| Do this | To |
|---|---|
| Click a context in the Dock, or ⌃⌥1 / ⌃⌥2 / ⌃⌥3 | Switch context |
| Click an app in the Dock | Bring up its most recent window in this context |
| ⌃⌥⇧1 / 2 / 3, or the menu bar > Move Front Window To | Send the front window to another context |
| Right-click an app in the Dock | List its windows here, move one, or open a new window here |
| Menu bar > Show All Windows (Recover) | Put every parked window back on screen |
| Menu bar > Quit | Restore all windows and quit |

**When you click an app in the Dock:**
- If it has a window in this context, that window comes up.
- If the app is a browser, editor or terminal with windows only in other contexts, ContextDock sends ⌘N and the new window joins this context.
- If it's a single-window app (Slack, Discord), its window moves here.
- If the app isn't running, it launches here.

**Where new windows go:** new windows join the current context.

**What follows focus:** if a window from another context comes forward, the Dock switches to that context. That covers ⌘-Tab, ⌘-`, clicking the native Dock, notifications, and links that land in an existing window.

**Shared apps:** windows of the apps in `shared` stay visible in every context (Music, 1Password and Finder by default).

**Editing contexts:** menu bar > Edit Dock Contents… opens `~/Library/Application Support/ContextDock/config.json` (contexts, Dock apps by bundle id, colours, keys, `shared`). Relaunch to apply.

**Automation:** `open -g contextdock://switch/work`, `contextdock://move-front/personal`, `contextdock://open/<bundle id>`, `contextdock://recover`, `contextdock://dump` (writes `debug.json` next to the state).

## What happens if it dies

Window assignments and each parked window's exact frame are written to `~/Library/Application Support/ContextDock/state.json` on every change.
- **Quit, logout, `kill`, Ctrl-C:** everything is restored first.
- **Hard crash (`kill -9`):** windows stay parked. Relaunching ContextDock puts each one back exactly. If the state file is lost, Recover centres any window left in a park corner.

## Known limits (v0.1)

- **Links from other apps:** if the browser puts the tab in a parked window, ContextDock switches to that window's context (it watches parked browser windows for a new tab for 2.5s after the browser comes forward). It can't tell when a link reuses a tab that already has the same title.
- **Mission Control** shows parked windows tiny in a corner.
- **Native full-screen windows** aren't moved. They keep their own Space.
- **Floating panels and palettes** (Granola's notepad, ChatGPT's bar, Meet picture-in-picture) aren't managed, so they show in every context.
- **Sleep and displays:** display off, lock and unlock were tested and held. Real system sleep and plugging/unplugging a display haven't been tested yet (the code re-pins parked windows on both).
- **Restarting the Mac:** after a restart, windows get new ids, so they all start in the current context. Persistence across a restart is out of scope for v1.
