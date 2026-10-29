# ContextDock

A floating Dock with three contexts (Work, Personal, Agents). Each context has its own Dock apps and its own real windows. Clicking a context swaps the whole set of windows on screen, and everything is still there when you come back. Nothing is closed or relaunched: windows outside the current context are parked offscreen in a corner. See [docs/DECISIONS.md](docs/DECISIONS.md) for why.

## Build and run

Requires macOS 26 and Xcode 26 or later (Swift 6). No other dependencies.

```bash
./scripts/install.sh
```

This builds the app, quits the running copy (your windows are put back first), installs it to `/Applications/ContextDock.app` and launches it. Run it again after any change. `./scripts/build-app.sh` alone only builds `build/ContextDock.app`.

On first launch, approve **ContextDock** in System Settings > Privacy & Security > Accessibility. It starts within a second of the grant. The build signs with your first "Apple Development" certificate so the grant survives rebuilds. Set `CODESIGN_IDENTITY` to pick a different one.

## Using it

| Do this | To |
|---|---|
| Click a context in the Dock, or ⌃⌥1 / ⌃⌥2 / ⌃⌥3 | Switch context |
| Three-finger swipe left or right anywhere (with macOS's "Swipe between full-screen apps" set to four fingers) | Next or previous context |
| Two-finger swipe left or right on the Dock bar | Next or previous context, like swiping between desktops (stops at the ends) |
| Click an app in the Dock | Bring up its most recent window in this context |
| ⌃⌥⇧1 / 2 / 3, or the menu bar > Move Front Window To | Send the front window to another context |
| Right-click an app in the Dock | List its windows here, move one, or open a new window here |
| Menu bar > Show All Windows (Recover) | Put every parked window back on screen |
| Menu bar > Open at Login | Start ContextDock when you log in (also in System Settings > General > Login Items) |
| Menu bar > Quit | Restore all windows and quit |

**When you click an app in the Dock:**
- If it has a window in this context, that window comes up.
- If the app is a browser, editor or terminal with windows only in other contexts, ContextDock sends ⌘N and the new window joins this context.
- If it's a single-window app (Slack, Discord), its window moves here.
- If the app is running with no windows (Mimestream, Messages), it gets the native Dock's "reopen", so its main window shows here.
- If the app isn't running, it launches here.

**Where new windows go:** new windows join the current context. That includes opening a document in an app whose last window is in another context: you stay where you are.

**⌘-`** cycles only the current context's windows of the front app.

**What follows focus:** if a window from another context comes forward, the Dock switches to that context. That covers ⌘-Tab, clicking the native Dock, notifications, and links that land in an existing window.

**Home apps (one browser per context):** `homes` in config.json maps an app to a context, for example `"com.google.Chrome": "work"`. A new window from a home app goes to its home context and the Dock switches there, so a link a router like Velja opens in that browser takes you there from anywhere. An app that's in only one context's Dock (Messages only in Personal) has that context as its home without being listed. Dia is the only browser, shared, with a profile per context (below). Windows you open on purpose (a Dock click or New Window Here) stay where you are.

**Browsers:** a browser is an app like any other, with its own windows in each context. ContextDock never changes a browser's profile; set each window's profile yourself (Dia: Personal's window in Solo, Work's in Work).

**Switch animation:** switches you make slide like Spaces: the old screen slides out and the new one slides in. It uses screen snapshots, so it needs Screen Recording permission; until that's granted, switches are instant. Set `"switchAnimation": false` in config.json to turn it off. With Reduce Motion on, it fades instead.

**Room for the Dock:** like the native Dock, the strip it sits in is kept clear. A window you drag or resize so it ends up behind the Dock gets moved up or shortened when you let go. Drag it back down within 10 seconds and it stays.

**Shared apps:** windows of the apps in `shared` stay visible in every context (Music, 1Password and Finder by default).

**Editing contexts:** menu bar > Edit Dock Contents… opens `~/Library/Application Support/ContextDock/config.json` (contexts, Dock apps by bundle id, colours, keys, `shared`). Relaunch to apply.

**Automation:** `open -g contextdock://switch/work`, `contextdock://move-front/personal`, `contextdock://move/<window id>/<context>` (ids are in `debug.json`), `contextdock://open/<bundle id>`, `contextdock://new-window/<bundle id>`, `contextdock://recover`, `contextdock://dump` (writes `debug.json` next to the state), `contextdock://login/on` or `/off`, `contextdock://demo/start` and `contextdock://demo/end` (minimize your windows for a clean recording, then restore them).

## App icon

`swift scripts/make-icon.swift` redraws `Resources/AppIcon.icns`: the dusk gradient from the reference video with a small Dock (the Work pill, the Personal and Agents buttons, an app). It's drawn from shapes because SF Symbols can't be used in app icons. Run `./scripts/install.sh` afterwards.

## Design review

`/Applications/ContextDock.app/Contents/MacOS/ContextDock --gallery` opens a window with every Dock state, forced hover states and a Dock that switches every 1.6s. It doesn't touch your windows.

## What happens if it dies

Window assignments and each parked window's exact frame are written to `~/Library/Application Support/ContextDock/state.json` on every change.
- **Quit, logout, `kill`, Ctrl-C:** everything is restored first.
- **Hard crash (`kill -9`):** windows stay parked. Relaunching ContextDock puts each one back exactly. If the state file is lost, Recover centres any window left in a park corner.

## Known limits (v0.1)

- **Links from other apps:** if the browser puts the tab in a parked window, ContextDock switches to that window's context (it watches parked browser windows for a new tab for 2.5s after the browser comes forward). It can't tell when a link reuses a tab that already has the same title.
- **Mission Control** shows parked windows tiny in a corner.
- **Native fullscreen windows** aren't moved; they keep their own Space. Using one (a fullscreen video, say) never switches context, and macOS keeps the Dock off fullscreen Spaces. Exit fullscreen with it in front and you're taken to its context.
- **Floating windows** (Granola's call indicator and notepad, ChatGPT's bar, picture-in-picture) aren't managed, so they show in every context. That covers anything above normal window level or smaller than 80×80.
- **Safari and fullscreen video:** leaving a fullscreen Safari video's Space makes Safari pull its parked window on screen. ContextDock puts it straight back, but it can flicker for a frame.
- **A faint sliver at the bottom right:** macOS keeps 1px × ~32px of each parked window, plus its shadow, on screen.
- **Sleep and displays:** display off, lock and unlock were tested and held. Real system sleep and plugging/unplugging a display haven't been tested yet (the code re-pins parked windows on both).
- **Restarting the Mac:** after a restart, windows get new ids, so they all start in the current context. Persistence across a restart is out of scope for v1.

**A wallpaper per context:** the menu-bar menu has *Wallpaper for <context>*, with a picture for light mode and one for dark mode (either alone is used for both). It changes while the slide covers the screen, and again when your Mac switches between light and dark. A context without its own picture shows the desktop picture you had before ContextDock first changed it. In config.json: `"wallpapers": {"work": {"light": "/path/a.heic", "dark": "/path/b.heic"}}`. `swift scripts/make-wallpapers.swift ~/Library/Application\ Support/ContextDock/Wallpapers` makes a light and a dark picture for each context in its Dock color (soft blurred color fields).
