# Decision log

## 2026-10-27: Engine: our own Accessibility engine, AeroSpace-style corner parking

**Decision.** ContextDock owns the whole model in one process: which window belongs to which context, and moving windows in and out of view through the Accessibility (AX) API. A window outside the current context is parked in the bottom-right corner of its screen with a 1px sliver showing. Nothing is closed, minimized or relaunched.

**Why.**
- Native Spaces on macOS 26 with SIP on have no public API to move another app's window, switch Space or ask which Space a window is on. yabai's SIP-on window moves depend on an internal SkyLight symbol it finds by parsing Mach-O, and 26.6 already broke its Space creation ([yabai changelog](https://github.com/koekeishiya/yabai/blob/master/CHANGELOG.md), [space_manager.c](https://github.com/koekeishiya/yabai/blob/master/src/space_manager.c)). Switching Space also animates as a slide, which is not the instant swap in the reference video.
- AeroSpace already does exactly this trick, under MIT ([MacWindow.swift `hideInCorner`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/MacWindow.swift), [guide: emulation of virtual workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)). As an *external* engine it costs more than it gives here:
  - it's a tiling WM first (all-floating needs an `on-window-detected` rule);
  - on quit it re-centres every window, so positions are lost ([appBundleUtil.swift](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/util/appBundleUtil.swift));
  - its event stream has no window-closed or window-moved events ([aerospace-subscribe](https://github.com/nikitabobko/AeroSpace/blob/main/docs/aerospace-subscribe.adoc));
  - it's a separate, not-notarized prerelease install.
- Dockman (MIT) only pins its own panels to Spaces, and Powerspaces (GPL-3.0) only reads Space data. Neither moves other apps' windows. No code was taken from either.

**What we took from AeroSpace (MIT):**
- the corner position: `visibleRect.bottomRight − 1px`;
- the order: unpark the target context first, then park the rest;
- focusing a window by setting AXMain, then AXRaise, then activating the app;
- the `AXEnhancedUserInterface` toggle that stops Chrome and Electron from animating moves;
- following focus into another workspace.

The code is our own and short. If AeroSpace code is copied verbatim later, add its license notice.

**Tradeoffs we accept:**
- Mission Control shows parked windows tiny in a corner.
- A hung app can delay a switch by up to the 0.6s AX timeout.
- Native full-screen windows are left alone (they live in their own Space).

## Verified on John's Mac (macOS 26.6.2, one built-in display), 2026-10-27

- Accessibility grant is picked up without relaunching, and it survives rebuilds because the app is signed with the Apple Development certificate.
- 9 existing windows were adopted into Work on first launch.
- Switching Work → Personal parked all 8 Work windows. Personal → Work restored every frame to the exact pixel. Repeated 4 round trips with identical frames.
- The Work Dia window and a second Dia window in Personal stay in their own contexts.
- The focused window per context is restored (Dia Work in Work, Dia Personal in Personal).
- Clicking Dia in the Personal Dock with no Dia window there: activate Dia + ⌘N. The new window joined Personal and took focus.
- Switching to a context with no windows: ContextDock takes focus through AX (`NSApp.activate()` alone was refused on macOS 26), so typing can't reach a parked window.
- Quit: every window came back on screen. Relaunch put them back in their contexts.
- `kill -9` while in Personal: windows stayed parked (expected). Relaunch, then switch to Work, restored them to exact frames.
- Activating Claude (Work) from Agents switched the Dock to Work (the ⌘-Tab path).
- A background job in a Terminal window in Agents kept running while Work was showing (ticks 4 → 12 over 8s).
- Single-window app (Discord) clicked in the Personal Dock: its window moved to Personal. John confirmed that's what he wanted.

## Failed / open

- **Links from other apps with Dia.** In the first run, `open https://example.com` from Agents put the tab in the *Work* Dia window, but Dia focused the Personal one, so the Dock followed to Personal. See the 2026-10-27 link-routing entry below.
- Hover states and the cascade animation were only seen in one screenshot, not checked frame by frame.
- Not yet tested:
  - sleep/wake;
  - a display plug/unplug;
  - notifications clicked from another context;
  - ⌘-` inside an app across contexts;
  - dialogs and sheets on parked windows.

## Assumptions

- A Dia window's title starts with its Dia profile ("Work: …", "Solo: …"). That could later drive automatic assignment, but nothing relies on it yet.
- The reference video's clock reads 9:41, Apple's marketing time, so it may be a staged mock-up rather than a screen recording. Its focus features (exit countdown, held notifications, site classification) are out of scope per the brief.

## 2026-10-27: Link routing: follow the parked window that gets the new tab

**Decision (John).** When a link from another app lands in a parked browser window, switch to that window's context. The alternative was making ContextDock the default https handler, which we didn't pick.

**How it works:**
- When a browser activates for a reason we didn't cause (not our own switch, not our ⌘N), ContextDock watches that browser's parked windows for 2.5s.
- If a parked window's title changes, ContextDock switches to that window's context and focuses it. A browser window's title is its active tab's title, so a new tab changes it.
- The usual follow-the-focused-window decision waits 0.35s, so the parked window can claim the link first. If it claims later, there are two quick switches but you end up in the right place.
- Unread counters ("(3) …", "• …") are ignored, so a badge update in a parked tab isn't read as a new tab.

Browsers covered: Dia, Yab, Safari, Chrome, Arc, Firefox.

**Tested live:** three links opened from Agents. Each time Dia put the link in its last-used window (Personal) and focused it, and the Dock went to Personal with that window in front. The Dia mis-route from the first run (tab in one window, focus on another) didn't happen again on its own.

**Parked-window path verified live (AppleScript, John approved Automation for Dia):**
- Setup: the Personal Dia window was focused last, then Agents was active.
- One script ran `activate` on Dia, then `make new tab at end of tabs of <window whose active profile is "Work">`.
- Result, 4 runs out of 4: the Dock went straight to Work with the Work Dia window in front on the new tab, and the Personal window stayed parked.
- The switch trail in `contextdock://dump` shows a single `agents -> work: link-landed company.thebrowser.dia 707239`, so the parked window claimed the tab before focus-follow ran.

**Known gaps:**
- A link that reuses an already-active tab with the same title isn't detected.
- A parked tab whose page title changes by itself in the 2.5s after you bring the browser forward could cause a false switch.

Every switch now records its reason (dock, hotkey, url, menu, focus-follow, link-landed) in the last 20 entries of `recentSwitches` in `debug.json`. `log show` returned nothing for this app from a non-admin shell, so the trail lives in the dump instead.

## 2026-10-27: Signing is pinned

Keychain listed John's two Apple Development certificates in a different order on a later build. That signed the app with the other certificate, and the Accessibility grant stopped applying. `scripts/build-app.sh` now saves the first certificate's SHA-1 in `.signing-identity` (gitignored) and reuses it on every build.

## 2026-10-27: Sleep/wake, first pass

**Change.** The wake pass no longer un-parks windows to re-measure them, which would have flashed every hidden window at wake. It now pins parked windows back to their corner, using the screen of their saved frame, or the main screen if that screen is gone, and only touches windows that moved. It runs on:
- system wake, and again 2s later;
- display wake;
- session becoming active (unlock, fast user switching);
- display configuration changes.

Each pass is recorded in `recentSwitches` as "<why>: N parked, M re-pinned".

**Lid test (John, 15:11 local):** the Mac did **not** system-sleep. `pmset -g log` shows only "Display is turned off" (15:11:39) and "on" (15:12:09). `pmset -g` reports "sleep prevented by Claude, powerd, ChatGPT": the Electron apps hold NoIdleSleep assertions. Through the display-off and lock:
- all 6 parked windows stayed in the corner with correct saved frames;
- the 3 visible windows kept their exact frames;
- the Dock panel stayed at (0, 1037, 1800×132).

ContextDock didn't run a pass, because it only listened for system wake at the time. The display-wake and unlock hooks were added after this test.

**Still open:** a real system sleep (`pmset sleepnow`) and a display plug/unplug.
