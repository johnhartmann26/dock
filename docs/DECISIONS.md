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

**Real system sleep: not applicable on John's Mac.** It never system-sleeps, because an app he runs keeps it awake. `pmset sleepnow` was also refused from the Claude session (0xe00002e2, not permitted). The case that happens day to day is the lid closing (display off plus lock), which passed above and now also triggers the re-pin pass. The system-wake handler stays in place for other setups but hasn't been tested here.

**Still open:** a display plug/unplug.

## 2026-10-27: ⌘-`, notification clicks, reopening apps with no windows

**⌘-` stays inside the context (judgment call, flagged to John once).** A global key monitor records ⌘-` and ⌘⇧-` presses. If the focus change that follows lands on a parked window from another context, ContextDock focuses the app's least recently used window in the current context. That cycles round the current context's windows instead of jumping contexts. ⌘-Tab, notification clicks and links still follow the window to its context.

Tested by John in Dia, with one Dia window in Work and one in Personal. The switch log shows each press landing on the parked window and being sent back (`⌘-\` kept in work … 744183 -> 707239` ×3, and the same in Personal ×4). With one window per context that looks like "⌘-` does nothing", which is the intended outcome. John doesn't use ⌘-`. Cycling between two windows in one context hasn't been tested, because the second Work Dia window was closed before the test.

**Notification clicks follow to the window's context: verified by John.** A Messages notification clicked while in Agents produced `agents -> personal: focus-follow com.apple.MobileSMS 744478`. A notification click activates the app like ⌘-Tab does, so it goes through the same focus-follow path.

**Bug fixed: clicking a running app that has no windows.** Clicking Mimestream in the Work Dock (Mimestream running, no windows) sent ⌘N, which in Mimestream and Messages creates a new draft instead of showing the main window. Now an app that's running with no windows gets the same reopen event the native Dock sends (`NSWorkspace.openApplication`). ⌘N is used only for multi-window apps (browsers, editors, terminals, Finder) that have windows in other contexts. Verified: Mimestream from the Work Dock showed its Inbox window in Work, focused. The window had an old id (411348), so Mimestream had kept it ordered out, and it was adopted into Work.

**Also fixed:** right-click > New Window Here focused an existing window when there was one; it now always opens a new window. `contextdock://new-window/<bundle id>` does the same.

## 2026-10-27: Design pass against the reference video

**Method.**
- `ContextDock --gallery` opens a review window: every context selected, a forced hover on a context button and on an app (`forcedHover` environment value), and a live Dock that switches every 1.6s. It has no engine, panel or menu bar item.
- Captures were the gallery window only (`screencapture -l`) or a region inside it, recorded with `screencapture -V` and cut into 30fps frames for timing.
- Colours were sampled from the video frames.

**Changes.**
- **Pill:** flat colour with no gradient or glow, like the video. Work uses the video's Building blue **#3277BB**, Personal its Writing amber **#CF8812**, and Agents a violet toned to match, **#7B5CC4**. The defaults changed, and so did the three `color` values in John's config.json (nothing else in it).
- **Bar:** Liquid Glass (`glassEffect`) faded the whole bar to about half opacity while it re-morphed during a width change. Replaced with `NSVisualEffectView` (behind-window blur, dark appearance, `.menu` material). In a swatch test over the gallery gradient, `.menu` darkened the background about 27% and kept its hue. The video's bar darkens its wallpaper about 25% and stays warm. `hudWindow` barely darkened, and `headerView`/`sidebar` went grey.
  - The gallery's own Dock rows can't show bar colour, because the blur samples what's behind the *window*, not the gradient inside it. Only the live Dock, a separate window over the desktop, shows it. John confirmed on 2026-10-27 that the live bar's tint looks right on his desktop.
- **Switch animation:** it took 0.47s against the video's ~0.3s, now 0.30–0.33s. Old icons and the old label leave in 50ms (`quickExit`); `.identity` had kept them fully visible until the animation ended, so they overlapped the new pill and hung past the shrinking bar. The new pill arrives solid and slides, with no orange/purple cross-fade. Its label fades in after 110ms, once the pill is wide enough. The icon cascade uses an 18ms stagger and a 0.2s spring.
- **Hover:** works on the live, non-activating Dock panel (checked by moving the pointer onto it). A context button brightens; an app icon lifts 2pt, scales 1.08 and shows its name in a frosted capsule. The video shows no hover states, so these follow the native Dock.

**Left as is:** layout, spacing and the icon-to-control size ratios already matched the video within a few points.

## 2026-10-27: Demo setup findings; demo dropped

John decided not to record the demo, so that deliverable from the brief isn't produced. `contextdock://demo/start|end` stays for a later recording:
- **start:** minimizes every managed window (parked ones from their corner, so they come back parked).
- **end:** closes windows that appeared during the demo and un-minimizes the rest.
- While a demo is active, Dock clicks and running dots ignore the minimized windows, so clicking Dia opens a fresh window instead of restoring a real one.

**Bug found and fixed: opening a document pulled you to another context.** Opening "Launch plan.txt" from Work while TextEdit's last window was in Personal switched the Dock to Personal (focus-follow on activation), and the new document landed there. Now every app activation waits 0.3s before following focus. If the app gets a new window in that time (a document from Finder or Terminal, ⌘N, a link that makes a window), the window joins the current context and the Dock stays put. ⌘-Tab to an app whose windows live elsewhere still follows, 0.3s later. Verified: the same open from Work stayed in Work with no follow.

**Not a bug:** two `work -> agents: dock` switches during setup were John clicking Agents.

**Seen once, not investigated:** after demo start, Discord's window was visible in Personal. It either didn't minimize or restored itself (Electron).

## 2026-10-27: Calmer switch animation; Personal first

**John: the switch felt like the Dock "fully closing and reopening".** The video-style sequence was too much day to day: clear every icon, shrink the bar to the context buttons, then cascade the new icons in. That's a deliberate departure from the reference. Now:
- the bar stays open and glides to its new width, all on one `.smooth(duration: 0.32)` curve with no bounce;
- old icons fade and settle slightly in place (0.14s) while new ones fade and rise in a beat later, with an 18ms stagger;
- apps that are in both contexts keep their tile, because tiles are keyed by bundle id;
- the pill slides drawn above the other buttons (`zIndex`), so the Work briefcase no longer shows through it;
- the label fades in at 0.18s, once the pill has nearly arrived.

John confirmed on the live Dock that the new switch feels right.

Checked with window-only captures of the gallery (`screencapture -l` in a loop). A region recording earlier caught one of John's windows (Meet call controls) sitting over the gallery and was deleted. Only window-only captures are used for this from now on.

**Order is Personal, Work, Agents** (John). John had already swapped the shortcuts in his config.json (Personal ⌃⌥1, Work ⌃⌥2) and moved Music from shared into Personal. Only the order of the `contexts` array changed in his file. The defaults and the app icon (amber dot, blue Work pill, violet dot) follow the same order.

## 2026-10-27: Floating windows stay out of contexts; the corner sliver

**Granola's live-call indicator flickered and disappeared on switches (John).** The indicator ("Nub", 42×70) is a floating window, at window-server layer 3 rather than the normal 0. Granola appears to show it when its main window is out of view. Switching away from Work parked Granola's main window, so the indicator appeared, and ContextDock adopted it into the current context, parked it on the next switch, and Granola pulled it back: flicker. Now any window above normal level or under 80×80 is never managed: call indicators, picture-in-picture, HUDs. They stay where their app puts them, in every context. Verified after install: only Granola's main window is managed, and the indicator is on screen at its own position. John then confirmed that the indicator stays put when he switches.

**"I see the other windows slightly in the bottom right": expected, a macOS limit.** Parked windows sit at the bottom-right corner of the screen (the visible frame reaches the bottom because John's Dock auto-hides). macOS lets a window go off the right edge down to 1px, but clamps the vertical position so the top 32–52px (the title bar) stays on screen. Parked windows ended at y=1137 or 1117 on a 1169pt-tall screen. So each one leaves a 1px × ~32px sliver, and its drop shadow draws a faint smudge around it. AeroSpace has the same artifact. Hiding it fully would take private window-server calls that need SIP disabled, so it stays.

## 2026-10-27: Two-finger swipe on the Dock

A horizontal two-finger swipe over the Dock bar moves one context per gesture. Fingers moving left go to the context on the right (Personal → Work → Agents), matching swiping between desktops. The direction is normalised for the natural-scrolling setting with `isDirectionInvertedFromDevice`. It needs 36pt of travel, ignores momentum and mostly-vertical scrolls, and doesn't wrap at the ends. Only scrolls over the visible bar reach it, because the rest of the panel is click-through.

Tested with synthetic trackpad-phase scroll events: past the last context it did nothing, and the reverse swipe gave `agents -> work: swipe`. John confirmed the direction feels right on his trackpad.

**Steam:** John reported Steam misbehaving. ContextDock manages none of Steam's windows and has parked none. Steam draws its UI in "Steam Helper" windows, which were all ordered out by Steam itself. Treated as a Steam issue.

## 2026-10-27: One browser per context; Velja routes links

**John's plan:** Dia is the Work browser, Yab the Agents browser and Safari the Personal browser. Velja (installed, running, the default https handler) picks the browser for each link. ContextDock doesn't integrate with Velja; it only has to send each browser's windows to the right context.

**`homes` (new config key, optional so older configs load):** bundle id → context. A *new* window (AX window-created) from a home app joins its home context. If that isn't the current one, the Dock switches there and focuses the window. A window you asked for in the current context (Dock click or New Window Here, via `awaitingWindow`) stays where you are. Windows found by a scan, not created, get their home context without a switch. Existing windows keep their saved context.

John's config: Personal's Dock has Safari where Dia was. Homes are Safari → personal, Dia → work, Yab → agents. The defaults match.

**Tested (links opened straight into each browser, bypassing Velja):**
- From Work, a link in Safari landed as a tab in the existing, parked Personal Safari window: `work -> personal: link-landed com.apple.Safari 745928`.
- From Personal, a link in Yab opened a new window: `personal -> agents: home dev.serafim.fast 746109`.

John then clicked real links through Velja, and each one took him to the right context.

With one browser per context, the Dia link-routing problem from earlier (a tab landing in another context's Dia window) mostly goes away.

## 2026-10-27: Fullscreen video (Safari, Dia), verified by John

**Problems, in the order John hit them:**
1. Leaving a fullscreen Dia video ping-ponged Work ↔ Personal. On the desktop, macOS focused the app's only window there, a parked one from another context, and ContextDock followed it.
2. AX lists only the current Space's windows, so a launch while in fullscreen saw one window, and pruning dropped windows on other Spaces.
3. Play/pause in a fullscreen Safari video from another context switched to Personal.
4. Safari's parked window blinked on screen when a video entered or left fullscreen.
5. The Dock took about a second to come back after swiping back from a fullscreen Space.

**Rules now:**
- **Fullscreen windows never switch context.** That covers focusing one, clicking in it and ⌘-Tab to it. It also covers a new window that turns out fullscreen; Safari makes a separate window for fullscreen video, and the home rule waits 0.4s to check. "Fullscreen" is AXFullScreen, or a window from another context that fills a screen without being parked.
- **Leaving fullscreen:** a fullscreen window from another context isn't parked until it has left fullscreen (checked every 1.2s). Then, if it's in front, ContextDock follows it to its context; if not, it's parked.
- **After a Space change,** focus moving to a *parked* window is macOS's fallback pick and isn't followed; ContextDock takes keyboard focus instead, so it never yanks you to another Space. A visible window is followed as usual.
- **On every Space change and app activation,** ContextDock rescans for windows it hasn't seen (they get their saved context). Pruning only drops windows the window server says are gone.
- **Parked windows** are watched with kAXMoved and put straight back when an app moves them on screen. The Space-change pass is the backstop. It counts a window as back only by x, since macOS clamps y.
- **The Dock hides** while the front app's focused window is fullscreen *and on screen*. It checks at once on every Space change and app activation, and again at 0.3s and 1.1s.

**Verified by John:** play/pause in a fullscreen Safari video from Work keeps him in Work, and exiting takes him to Personal with the video. The Safari blip is mostly gone; it can still flash for a frame, because the re-tuck happens after the app's move. The Dock shows right away on swiping back.

**Follow-up (John): after a longer stretch in fullscreen, the Safari blip and the Dock delay came back.** The logic itself handled the short exits right away (re-tuck immediate, backstop pass with 0 re-pinned). The likely cause is App Nap: with the Dock hidden, ContextDock has no visible window, and macOS throttles it after a few minutes, delaying its notifications and timers. That's inferred, not observed; App Nap state isn't readable from a shell. Fix: `NSAppSleepDisabled` in Info.plist, plus a lifetime `ProcessInfo.beginActivity([.userInitiatedAllowingIdleSystemSleep, .latencyCritical])`, which doesn't stop the Mac sleeping.

**Follow-up 2: App Nap wasn't it (John: still happens after a long video).** The log then showed both effects precisely:
- **Blip:** Safari moves its parked window on screen at the instant you leave the fullscreen Space (22:22:55, :59, 23:05, :08), and ContextDock re-tucks it in the same instant. The parked window is the one the fullscreen video belongs to. Safari pulls it on screen itself, and the only way to stop that would be not parking it, which would show a Personal window on the Work desktop. So a frame or two of flicker is the floor here. Known limit.
- **Dock:** macOS does show this panel over fullscreen Spaces. At 22:02:59, before the hide logic existed, John swiped it during a fullscreen video. So hiding has to stay ours. Showing it again depended on a Space notification plus re-checks at 0, 0.3 and 1.1s, and all of those can land while the swipe animation is still running. Now the Dock remembers which fullscreen window it hid for and polls twice a second, only while hidden, until that window is off screen or gone, then comes back. Every hide and show is in `recentSwitches`. The App Nap opt-out stays; it's right for a window manager anyway.
