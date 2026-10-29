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

**Follow-up 3: the log showed the Dock "shown" on time** (22:25:34.300 and 22:25:53.258, each about 40ms before Safari's re-tuck at the moment John left fullscreen), but John still saw it late or missing. So the decision was right and the display wasn't. The Dock had been hidden with `orderOut` and shown with `orderFrontRegardless`, and re-ordering a window during a Space swipe animation evidently leaves it showing late or not at all. Now the panel is never ordered out. Hidden means alpha 0 plus `ignoresMouseEvents`, so clicks and swipes pass through, and showing is an alpha change. A 0.3s check after each show logs (and re-orders) if the panel still isn't on screen.

**Follow-up 4: the hide logic was the problem, so it's gone.** The log again had the Dock hidden and shown on time, and the 0.3s check never fired. But the window server reported the panel *not on screen* while John was in the fullscreen video, including right after a restart, before anything had hidden it. So macOS already keeps a `.canJoinAllSpaces` panel without `.fullScreenAuxiliary` off fullscreen Spaces. The earlier conclusion, drawn from swipes at 22:02:59, was wrong; those swipes were on the desktop. All fullscreen hide/show logic is removed, and the Dock is a plain all-Spaces window that macOS shows as soon as a desktop Space is. `contextdock://panel/hide|show` remains for debugging.

John confirmed: after a long fullscreen video the Dock shows right away on returning to the desktop, and it isn't over the video.

## 2026-10-27: Chrome for Work, Dia for Personal; robot symbol for Agents

**Browsers (John):** Chrome is Work's browser, Dia Personal's and Yab Agents'; Safari is out. Velja routes links. Dock firsts: Chrome in Work, Dia in Personal, Yab in Agents. Homes: Chrome → work, Dia → personal, Yab → agents. Existing windows keep their contexts: the Dia "CSM Workspace" window stays in Work and the Safari window in Personal until John moves or closes them.

**Launch gap fixed:** the first windows of an app that just launched are found by a scan, not a window-created event, so a link that *launched* a home browser wouldn't have moved you to its context. Scans in the first seconds after an app launches now count as new windows, except in ContextDock's first 30s, so apps restoring windows at login don't bounce you between contexts.

**Tested:** from Personal, a link opened in Chrome went to Work: `personal -> work: link-landed com.google.Chrome`. The test tab landed in the Chrome window John was using to sign in with a passkey; he was told to close it. No more test links will be opened in his Chrome.

**Agents symbol:** SF Symbols has no robot on macOS 26 (`robot` and `robot.fill` don't exist). `Glyphs.swift` draws one on a 16×16 grid: a rounded head, visor eyes, a small smile and an antenna. `symbol: "robot"` uses it in the Dock and the menu bar; any other value is an SF Symbol name. A round-eyed variant was drawn too, but not kept.

**Switching to a context skips its fullscreen windows (John).** Clicking Personal sometimes landed on Dia's fullscreen video, not the Personal desktop: that window was Personal's most recent, and focusing it makes macOS jump to its Space. `focusCurrent` now ignores windows with AXFullScreen when choosing what to bring up after a Dock, hotkey or swipe switch. It picks the most recent normal window, or ContextDock takes focus if there's none, so you stay on the desktop. The frame-filling heuristic isn't used here, because a zoomed normal window in the current context also fills the screen.
John confirmed that clicking Personal with the Dia video fullscreen keeps him on the desktop with his normal windows.

## 2026-10-27: Smaller Dock; windows kept out from behind it

**Size (John: "scale down just a bit"):** about 12% smaller. Icons 46→40pt, context controls 34→30pt, corner 24→21pt, labels 14.5→13pt, symbol 14→12.5pt, and tighter padding. The bar is now about 61pt tall.

**Reserved strip (John: windows go behind it too easily):** the native Dock reserves its strip (`visibleFrame`), but this floating Dock doesn't. Now, 0.35s after a visible window stops moving or resizing, and once the mouse is up, ContextDock checks whether its bottom is behind the Dock: `DockMetrics.reserved`, the bar plus its gap plus 6pt, measured from the bottom of the main screen, across the full width like the native Dock.
- A window that reaches the bottom of the screen (maximized, tiled, "Fill") or is too tall to fit gets shortened.
- A window dragged partway down gets moved up.
- Windows mostly inside the strip, fullscreen, minimized or parked are left alone, as are ContextDock's own park/unpark moves (0.8s ignore).
- If you drag a window back down within 10s of a nudge, it's treated as deliberate and left there.

John confirmed that dragging or maximizing a window now keeps it out from behind the Dock, and it feels right.

## 2026-10-27: Global three-finger swipe

**John asked for a three-finger left/right swipe anywhere to switch contexts.** There's no public API for system-wide trackpad gestures, so `Gestures.swift` loads the private MultitouchSupport framework with dlopen (MTDeviceCreateList, MTRegisterContactFrameCallback, MTDeviceStart), as BetterTouchTool and Swish do. It works with SIP on and needs no extra permission. Each finger record is 96 bytes, and the normalized position is two Floats at offset 32. If the framework or its symbols are missing, the feature logs that it's off and does nothing.

**Gesture:**
- Exactly three fingers, averaged.
- Fires once per gesture after 0.12 of the trackpad width, if the movement is at least 1.5× more horizontal than vertical, so vertical three-finger swipes (Mission Control) are ignored.
- Same direction as the Dock swipe (fingers left → the context on the right), through one shared `step(fingers:)`, and stops at the ends.

**No double action:** it only acts while `TrackpadThreeFingerHorizSwipeGesture` is 0 for both the built-in trackpad and a Magic Trackpad, so macOS isn't also using three fingers. This is re-read on every swipe, and a skip is logged once. John moved "Swipe between full-screen apps" to four fingers (3-finger = 0, 4-finger = 2).

**Robustness:** devices are re-attached on wake and display wake. A Magic Trackpad connected later is picked up on the next wake, not yet on connect.

**Verified:** the listener attached to 1 trackpad. The swipe itself needs John's fingers.

**Follow-ups on the three-finger swipe:**
- **Double step:** one three-finger swipe over the Dock fired both the Dock swipe and the global swipe (23:20:40.485 `swipe`, then .578 `3-finger swipe`), because a three-finger move there also arrives as the Dock's scroll. Once either source steps, the other is ignored for 0.6s.
- **Missed swipes (John):** the tracker reset whenever the finger count left exactly 3 (a late or early finger, a grazing thumb), so the rest of the swipe was too short to count. It now starts when three fingers are down, follows those fingers by id (offset 16), and averages the movement of at least two of them. It ends when all fingers are up, or is abandoned if a fourth arrives (the Spaces swipe). The threshold is 0.08 of the width at ≥1.2× horizontal. Only fingers in contact count.
- **Touch states, verified on John's trackpad:** the first three-finger frame logged states `4,1,4`, so 4 = touching and 1 = just landing. That's the 0-based numbering (3 making, 4 touching, 5 breaking), and the accepted range 3...5 is right.

John: a dozen three-finger swipes, every one switched.

## 2026-10-27: Frosted wipe between contexts

**John asked for a short animation between contexts and picked the frosted wipe** over a real slide or a crossfade, both of which would need Screen Recording permission to snapshot the screen. Animating the real windows isn't practical through AX.

**How it works (`Wipe.swift`):**
- A borderless window one level below the Dock carries a behind-window blur (`.fullScreenUI`, dark), a 22% tint of the destination context's colour, and a 140pt soft-edge gradient mask.
- It sweeps in from the side you're switching toward (fingers left / next context → right to left) over about 130ms, easing in.
- The windows swap while it fully covers the screen (about 80–100ms of AX moves, hidden).
- It continues off the other side over about 170ms, easing out.
- AppKit animates window frames over `animationResizeTime`, not the context's duration (the first reveal measured 77ms), so `WipeWindow` returns the intended duration.

**When it plays:** for switches you make (Dock click, hotkey, Dock swipe, three-finger swipe, menu). Focus-follow, links, home windows and `contextdock://switch` stay instant; `contextdock://switch-animated/<id>` plays it. A switch requested mid-wipe goes through instantly. With Reduce Motion on, it fades in place. `"switchAnimation": false` in config.json turns it off.

**Measured:** covered at 120–131ms, swap 76–103ms, reveal 102–176ms. The look hasn't been recorded, because frames would show John's windows; John judges it on screen.

**Replaced: the frosted wipe "looks pretty bad" (John), so it's now a Spaces-style slide from real snapshots.** John chose this over a crossfade or no animation, accepting Screen Recording permission. `Slide.swift`:
1. ScreenCaptureKit snapshots the main display, excluding ContextDock's own windows (`SCContentFilter(excludingApplications:)`, `SCScreenshotManager.captureImage`, at full backing resolution).
2. An opaque overlay one level below the Dock shows the snapshot. The windows swap underneath, and 45ms later, once apps have redrawn, a second snapshot is taken.
3. Both pictures slide by one screen width toward the side you're leaving over 0.28s, with a cubic-bezier (0.25, 0.85, 0.25, 1) curve. Then the overlay is removed, leaving the live windows.

The menu bar and the Dock stay live on top. Snapshots exist only in memory during the transition. Without permission, ContextDock asks once and switches instantly. With Reduce Motion on, or if the second snapshot fails, the old picture fades over the live windows instead. The content filter is built at launch and after display changes, because the first lookup costs about 200ms. `Wipe.swift` is removed. Screen Recording was granted to the pinned Apple Development signature.

**Measured:** snapshot 37–93ms, swap plus second snapshot 122–139ms, slide 288–293ms, so about 0.45–0.5s from click to settled.

**Slide fix after John: "it really doesn't work".** A 2.5s screen recording, made with John's OK and deleted afterwards, showed two problems:
1. **A flash of the new context.** The new screen appeared for a frame (0.73s), then the old snapshot (0.77s), and only then the slide. The overlay wasn't on screen yet when the windows started moving. Now ContextDock calls `displayIfNeeded()` and `CATransaction.flush()` and waits 34ms (two frames) before swapping.
2. **Only the old picture moved.** The new layer's start and end positions were set in the same transaction, so it never animated. Now both layers get explicit `position.x` animations: old out, new in, by one screen width. Implicit actions are disabled, the duration is 0.3s, and the curve is (0.32, 0, 0.18, 1).

Re-recorded: no flash, and both screens slide together over about 0.3s (frames 1.00–1.30s). Measured: snapshot 29ms, swap plus second snapshot 162ms, slide 312ms.

John confirmed the slide looks right on his screen.

**Faster slide (John asked for it).** A switch took 0.5–0.65s from trigger to done: snapshot 25–107ms, overlay plus swap plus second snapshot 165–260ms, slide 310ms. Now the slide is 0.2s (0.15s fade with Reduce Motion), the wait before the swap is 20ms (one frame, down from 34ms), and the wait before the second snapshot is 25ms (down from 45ms). The log now splits the middle part: over five switches, cover 20–22ms, swap 45–65ms, second snapshot 46–53ms, slide 213–229ms, so about 0.4s in all. If the one-frame flash of the new context comes back, the 20ms wait goes back to 34ms.

**Faster again (John asked for more).** The slide is now 0.15s (0.12s fade with Reduce Motion). I tried taking the snapshots at point resolution instead of Retina, but it saved only a few milliseconds, so they stay sharp at Retina resolution. Measured over five switches: snapshot 30–35ms, cover 21–22ms, swap 51–84ms, second snapshot 46–64ms, slide 163–165ms, about 0.35s in all. The fixed part before the slide is about 0.15–0.2s: two snapshots and the window moves themselves.

John confirmed the 0.15s slide feels right.

**Switching felt slow and missed about one swipe in four (John).** The log had the slide running on every switch it recorded, with the overlay on screen and the picture changing, so the problem was before the slide.
- **Slow:** nothing moved for 0.2–0.35s after a swipe: the first snapshot, the window moves (65–190ms that morning) and the second snapshot all happened before the slide started. Now ContextDock keeps each context's last picture in memory, taken as you leave it. The slide starts toward that picture about 70–95ms after the swipe, and the windows move underneath while it plays. At the end the overlay fades out over 80ms onto the live windows, which hides anything that changed since the picture was taken. The first visit to a context after launch still uses the old two-snapshot path. Measured over eight switches: about 0.32s from swipe to settled with motion from ~80ms, against ~0.55s with motion from ~250ms before. Pictures are cleared when displays change.
- **Missed swipes, cause 1:** after a three-finger swipe fired, the tracker reset only when every finger was off the pad, so a finger left resting made the next swipe do nothing. Now it starts over once fewer than three fingers remain.
- **Missed swipes, cause 2:** a swipe during a slide counted from the context you were leaving if the windows hadn't moved yet, so it repeated the first step. Steps now count from where a slide is heading, and a later swipe wins over the slide's own switch.
- Every swipe that doesn't switch is now logged with why (at the end, same gesture as a Dock swipe, macOS still owns three-finger swipes), and the log keeps 60 lines instead of 20.

John confirmed: swiping feels fast and every swipe switched.

**No name in the context pill (John: "too much space").** The selected context's pill used to hold its name, so it was about 80–100pt wide, and the Dock changed width on every switch as the name changed. Now the pill is a fixed 42pt icon-only capsule. Hovering any context button shows its name and shortcut above it ("Work ⌃⌥2"), in the same frosted label as app names, and the plain-tooltip `.help` is gone. Checked in the gallery: all three contexts, the hover label, and a Work Dock about 70pt narrower.

John confirmed the icon-only pill looks right.

**Three-finger swipe dead over windows (John).** The log had working three-finger swipes until 16:24:55, then nothing: no switch and no "ignored" line, so the tracker never fired. Over the Dock the Dock's own two-finger handler still caught the gesture, which is why it seemed to depend on where the pointer was. The tracker followed the first three touches by id. A thumb or palm resting on the pad could be one of those three, or the fourth touch that made it give up as a Spaces swipe. And a gesture that ended with one finger still down left it waiting on ids that were gone. Now each finger is measured from where it landed, and only moving fingers count: a swipe is three fingers moving the same way sideways (more than 7% of the pad) with nothing else moving more than 3.5%, and four moving fingers is the Spaces swipe. It re-arms when fewer than three fingers are down. Gestures where three or more fingers moved without a swipe are now logged with why. Not yet confirmed on John's trackpad.

Follow-up: after the update, John's log had 10 three-finger swipes over windows and none dropped (8 switches, 2 at the Personal end). One gesture switched twice, 0.16s apart (Personal → Work → Agents), most likely fingers lifting unevenly. His real back-to-back swipes were 0.45s or more apart, so a swipe within 0.3s of the last one is now ignored and logged.

**Zoom showed in every context (John).** Zoom's meeting window (1242×1055, normal window level, on screen) was filed under Work, but ContextDock read its frame as 0×0 and its title as blank. Asked directly, Zoom listed no windows over AX, and no focused or main window either, even though the window server showed the window. A window AX can't see can't be moved, so `park` gave up and it stayed in view everywhere. After a restart ContextDock didn't see the window at all.

Now each scan compares the window server's on-screen normal windows (level 0, at least 80×80, not transparent) with what AX lists for that app. An app with windows AX doesn't list gets a context: the one its tracked window had, else its home, else the context you're in when it's first seen. The whole app is hidden (like ⌘H) while you're anywhere else and shown when you come back. ContextDock only unhides apps it hid itself, and it unhides them all on quit. Once AX can see the app's windows again, or it has none, it goes back to normal handling. ⌃⌥⇧<n> / Move Front Window To moves such an app as a whole. Not yet confirmed: Zoom's window was off screen when this was built.

**Dia: one window in every context, a profile per context (John).** John wants one Dia window, shown in all three contexts, that shows Solo in Personal and Work in Work and Agents. Different windows per context is "bad".
- **Tried and dropped:** opening a window per profile with `--profile-directory` (Chromium's launch option). Dia ignored it; no window opened.
- **What Dia offers:** its AppleScript dictionary treats a profile as "a space of tabs" that a window can switch to (`active profile`, `focus`). `focus (profile "Work" of window 1)` switched John's window in about 0.25s from the command line.
- **Built:** a `profiles` config key (browser → context → profile name). Dia is now in `shared`, so its window is never parked, and in all three Docks (Work first, Agents second after Yab). Its Personal home is removed, so new Dia windows no longer pull you to Personal. `BrowserProfiles` runs the `focus` script for every window of the browser on each context change, on a background queue, and only if the browser is running (an AppleScript `tell` would launch it). It also runs at startup and 1.5s and 4s after the browser launches. A Dock click on Dia focuses the one window, as for any shared app.
- **Bug found and fixed: the scripting was blocked silently.** ContextDock is signed with the hardened runtime, which blocks Apple Events with -1743 unless the app has the `com.apple.security.automation.apple-events` entitlement. macOS didn't prompt and didn't list ContextDock under Automation. `Resources/ContextDock.entitlements` now declares it, and the build signs with it. Accessibility and Screen Recording grants survived the re-sign. The Info.plist Apple Events usage string now says what the scripting is for.
- **Verified:** Personal → Solo, Work → Work, Agents → Work, Personal → Solo, with one Dia window throughout. Each switch took 150–185ms in the background, or 38ms when the profile was already right.
- **John's config changes:** Dia added to `shared`, `profiles` added, Dia added to the Work and Agents Docks, the Dia → Personal home removed. A backup is saved as `config.json.before-dia-profiles`.

**Dia is the only browser (John).** Yab and Chrome are out of every Dock, and their homes (Chrome → Work, Yab → Agents) are gone, so a new window from either now stays in the context you're in. Dia, shared with a profile per context, comes first in all three Docks. Open Chrome or Yab windows are left alone: one Chrome window is still filed in Work. The built-in defaults match. John's config was backed up as `config.json.before-browser-cleanup`.

**Dia came to the front too often (John).** Dia's AppleScript `focus` (profile) command also activates Dia. With Notes in front, Dia was frontmost 0.1s after a profile change. So every switch between Personal and Work or Agents pulled Dia forward over the context's own windows. Now `BrowserProfiles` notes the frontmost app before the script runs, and if the browser took over, gives focus back to that app through AX. Verified over four switches: Dia's profile followed (Work, Solo, Work, Solo), and Dia was never left in front. The context's own app (Granola in Work) or ContextDock itself (a context with no windows of its own; shared apps like Dia don't count) stayed in front.

**Bug found and fixed: Mimestream was hidden as if it were Zoom.** The log had "hid Mimestream: its windows can't be moved, and it belongs to agents". The Zoom fallback treated any app with one on-screen window missing from AX as unmovable, and Mimestream has normal windows plus one AX doesn't list. Now only an app with no windows listed in AX at all counts (Zoom in a meeting). If AX lists an app's windows again, ContextDock stops hiding it and unhides it if ContextDock hid it.

**Bug found and fixed: Personal bounced back to Work (John: "I cannot go to the Personal context").** The previous fix gave the front back to whatever app had it before Dia's profile switch. Right after a switch, that app still belonged to the old context (Granola in Work). Focus-follow then took you back there about 0.25s later. The log had four in a row: "work -> personal", then "personal -> work: focus-follow com.granola.app". Now `BrowserProfiles.onStoleFocus` calls `engine.refocus()`, which focuses the new context's own top window (or ContextDock when it has none), with the usual 0.45s focus-follow pause.

While testing, the context's own window often didn't come forward after a switch either. `focus()` relied on `NSRunningApplication.activate()`, which macOS 14+ often refuses for a background app. It now also sets AXFrontmost on the app, as ContextDock already does for itself. Verified with the ⌃⌥2/⌃⌥1 hotkeys over four switches: work → Granola in front, personal → Discord, work → Granola, personal → Discord, with no bounce. Switches made through the `contextdock://` URL leave ContextDock in front, because macOS activates the app that opens a URL. That only affects scripted switches.

## The slide covers Dia's profile switch

Dia's `focus` command brings Dia to the front, redraws it in the other profile, and then ContextDock puts the context's own window back. That took 150-400ms and ran after the slide had already ended, so you saw Dia flash on top. Instead of a longer slide for every switch, the slide's overlay now stays up until the profile switch and the refocus are done (at most 0.7s, plus 40ms to draw), then fades out. Switches that don't change the profile (Work to Agents) aren't held at all. On a first visit the "after" picture is taken once the profile has switched, so it's remembered correctly.

Follow-up: Dia also plays its own profile animation inside its window for a moment after `focus` returns, which still showed as a slight flicker. The profile script now reports whether a window actually changed profile, and when one did, the overlay holds 0.35s longer (cap raised to 1s). Personal to Work now takes about 0.75s in all; Work to Agents (same profile) is unchanged at about 0.3s.

## Refinement pass (switching, windows, Dock look)

- **A second switch during a slide carries the slide on.** A quick Personal → Work → Agents used to land in Agents while the cover kept showing Work for up to 1.1s (it was waiting on Dia's profile switch for Work). Now everything on the cover keeps moving from where it is, with the next context's picture right behind, and the wait is for the newest switch only. If there's no remembered picture to carry on to, the cover drops and the switch is instant.
- **Profile switches slide slower instead of pausing.** When a running browser changes profile (Personal ↔ Work/Agents), the slide takes 0.6s instead of 0.15s, so it's still moving while Dia finishes instead of stopping on a still picture. Same total time (~0.75s); switches with no profile change keep the 0.15s slide.
- **An app in only one context's Dock lives there.** Its new windows open in that context (and take you there), like a `homes` entry. Found a Messages window living in Agents with Messages only in the Personal Dock. A Dock click still opens a window where you are.
- **Windows whose accessibility handle goes stale are picked up again.** Granola's Work window was showing in Personal: Granola had given it a new AX handle and the old one stopped answering, so it couldn't be parked. Before parking or restoring, a window that doesn't answer is looked up again by its window id.
- **The Dock follows light and dark mode** like the macOS Dock (it was forced dark). Text, dots and dividers use the system's primary color; the selected context's pill keeps its color with a white symbol. Shadow a little lighter (0.2).

## The Dock stuttered on Personal ↔ Work

The Dock animates on the main thread, and during a profile switch the main thread was waiting on Dia (busy redrawing) for 100-200ms: reading the title of a Dia window Dia had just retitled, rescanning each app as it came forward, and the focus calls. Measured with a main-thread stall log per switch (`main thread a -> b: stalled …` in the dump), and `sample`. Now title changes of shared apps (Dia) are skipped before asking the app anything (a link landing in a shared app never switches anyway), focus changes during a switch are skipped before any AX read, the rescan on activation waits until the switch is over, and focus/raise run on a background queue. The ~100ms freeze at ~200ms is gone; what's left is ~60ms when the windows move, before the Dock's animation starts.

## The Dock is Liquid Glass

On macOS 26 the Dock's background is AppKit's `NSGlassEffectView` (regular style), like the system Dock, so what's behind shows through. AppKit's glass just resizes when the Dock's width changes, unlike SwiftUI's `glassEffect`, which fades out while it re-morphs. Frosted blur on older macOS. A single-window screenshot shows it black because it has nothing behind it to sample.

Follow-up: in light mode the plain glass looked dark over anything but a white page. It now gets a 60% white tint in light mode (`DockGlassView.lightTint`), re-applied when the appearance changes; dark mode stays plain glass, which John said looks good.

Follow-up: dark mode had the same problem the other way (plain glass looked light over anything but a dark background). It now gets a 45% black tint in dark mode (`DockGlassView.darkTint`).

## A wallpaper per context, light and dark

`wallpapers` in config.json maps a context to a light-mode and a dark-mode picture; the menu-bar menu sets them for the current context with a file picker (starts in /System/Library/Desktop Pictures). Set with `NSWorkspace.setDesktopImageURL` on every screen, keeping each screen's fill options, only when it differs (4-23ms). On a switch it's set in the swap, under the slide, which holds 120ms for it to draw; it's re-applied when the system appearance changes. A context without a picture shows your own desktop picture, saved (in ContextDock's defaults) the first time ContextDock replaces it, so a context without one doesn't keep the last context's. Tested with a Work picture: in Work it showed, back in Personal the original returned; the test picture was removed from the config afterwards.

## Seeded wallpapers in each context's color

The system's colored wallpapers (Mac Blue, iMac Purple…) are single light images with no dark version, and only approximate the Dock colors. `scripts/make-wallpapers.swift` draws a pair per context from config.json's colors instead: light is a pale wash with softer fields of the color and neighbouring hues; dark is near-black in the color with glowing fields. Amber turns olive when shifted toward yellow in the dark, so Personal's hues only shift toward red. Written as HEIC (2-4.5MB each) to ~/Library/Application Support/ContextDock/Wallpapers and set in John's config for all three contexts (config backed up as config.json.before-wallpapers).

## One slide length for every switch

Work ↔ Agents slid in 0.15s while switches that change Dia's profile slid in 0.6s, and John found the difference jarring ("the personal is fine if that's always the duration"). Every switch now slides over 0.6s; the per-switch duration is gone.

## Closed windows that apps keep (Granola)

Granola doesn't destroy its window when you click the red button; it hides it. Coming back to Work, ContextDock focused the context's most recently used window, which was that hidden Granola window, and focusing it brought it back. Reproduced (open Granola in Work, close it, go to Personal and back: it reappeared), fixed, and re-run (it stays closed across two round trips). A window that isn't on screen and isn't parked, minimized or fullscreen now counts as closed by its app: it's skipped when picking the window to focus after a switch, and a Dock click treats the app as having no window here (so it gets the app's normal reopen).

## Back to a Dia window per context

The one shared Dia window that switched profile on every switch caused a string of problems: Dia flashing to the front, its profile animation showing through, the Dock stuttering while Dia was busy, slow switches. John decided against it ("it's lead to lots of issues. let's instead have 3 different windows"). Dia is no longer shared: each context has its own Dia windows, parked and restored like any other app's, and nothing happens to them on a switch. `profiles` now only sets the profile of a window you open in a context (Dock click, New Window Here, launch): about 0.3s after it's adopted, ContextDock runs `focus (profile …)` on Dia's front window if it isn't already in that profile. Tested: from the Work Dock a new Dia window opened and was switched to Work, while the existing Solo window stayed in Personal. The per-switch profile code, the slide's profile hold and `refocus()` are gone; the slide's hold remains for the wallpaper. The 0.6s slide stays for every switch, as John asked. Config backed up as config.json.before-separate-dia.

## Links into per-context Dia windows: tried and dropped

Tested with example.com links opened from each context: Dia sends links from other apps to one profile (Solo) and switches whichever Dia window it picks to that profile, so a link from Work or Agents landed in another context's window (or flipped Work's window to Solo), and ContextDock followed it. Tried moving the link instead: reopen it in this context's window with Dia's AppleScript (`make new tab`, `close`, `move … to profile`), and put the landing window back in its profile. It was unreliable (matching windows by title, "Access not allowed" and stale tab ids on 2 of 3 runs), and John chose to copy and paste links into the right window instead. Nothing was kept; links behave as before (ContextDock follows a link to the window it lands in).
