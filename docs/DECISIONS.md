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

- **Links from other apps with Dia.** From Agents, `open https://example.com` put the tab in the *Work* Dia window. Dia's focused window was the Personal one, so the Dock followed to Personal. Dia chose a destination window that wasn't its focused one (likely its profile link routing). Options:
  - (a) watch title changes of parked browser windows right after a link opens, and follow that window;
  - (b) make ContextDock the default https handler (Velja/Finicky pattern) and hand each link to the current context's window. macOS asks John to confirm the handler change;
  - (c) set up Dia's own per-profile link rules.
  Needs John's call.
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
