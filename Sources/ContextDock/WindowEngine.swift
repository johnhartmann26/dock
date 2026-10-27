import AppKit
import ApplicationServices

/// Owns which window belongs to which context, and moves windows in and out of view.
///
/// Hiding follows AeroSpace's virtual-workspace trick (MIT): a window that isn't in the current
/// context is parked in the bottom-right corner of its screen with a 1px sliver showing, because
/// macOS won't place a window fully offscreen. Nothing is closed, minimized or relaunched, so tabs,
/// unsaved work and background processes carry on. Each parked window's exact frame is written to
/// disk, so a relaunch after a crash puts everything back.
@MainActor
final class WindowEngine {
    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let bundleID: String
        let element: AXUIElement
        var context: String
        var parkedFrame: CGRect?       // set while hidden in the corner
        var lastFocus: Date
    }

    private struct SavedWindow: Codable {
        var bundleID: String
        var context: String
        var parkedFrame: CGRect?
    }

    private struct SavedState: Codable {
        var current: String
        var windows: [String: SavedWindow]
    }

    private(set) var windows: [CGWindowID: Window] = [:]
    private(set) var current: String
    var config: DockConfig { didSet { applyVisibility(); changed() } }
    var onChange: () -> Void = {}

    private var observers: [pid_t: AXObserver] = [:]
    private var saved: [CGWindowID: SavedWindow] = [:]
    private var ignoreFocusUntil = Date.distantPast
    private var awaitingWindow: (bundleID: String, until: Date)?
    /// Browsers that just came forward, and until when a parked window's new tab counts as "a link landed here".
    private var linkWatch: [pid_t: Date] = [:]
    private var lastLinkSwitch = Date.distantPast
    private var titles: [CGWindowID: String] = [:]
    /// Last ⌘-` / ⌘⇧-` press; window cycling stays inside the current context.
    private var lastCycleKey = Date.distantPast
    private var keyMonitor: Any?
    /// Demo mode: your windows minimized out of the way, demo windows closed again at the end.
    private var demoMinimized: [CGWindowID] = []
    private var demoCreated: Set<CGWindowID> = []
    private var demoActive = false
    /// When each app last got a new window, so an activation that opens one doesn't pull you away.
    private var lastAdoptAt: [pid_t: Date] = [:]
    private let startedAt = Date()
    /// Leaving or entering a fullscreen Space makes macOS focus whatever window that app has on the
    /// new Space, often a parked one from another context. That isn't the user asking to switch.
    private var lastSpaceChange = Date.distantPast
    /// Windows from another context seen fullscreen; not parked until they've left fullscreen and we
    /// know whether you followed them out (see `checkLeftFullScreen`).
    private var seenFullScreen: Set<CGWindowID> = []

    /// Your own windows tucked away by demo mode: Dock clicks and running dots ignore them.
    private func demoHidden(_ id: CGWindowID) -> Bool { demoActive && demoMinimized.contains(id) }

    private static let stateURL = DockConfig.url.deletingLastPathComponent().appendingPathComponent("state.json")
    private static let fallbackNewWindowApps: Set<String> = [
        "company.thebrowser.dia", "dev.serafim.fast", "com.apple.Safari", "com.google.Chrome",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.apple.Terminal", "com.microsoft.VSCode",
        "dev.zed.Zed", "com.apple.finder", "com.mitchellh.ghostty", "com.googlecode.iterm2",
    ]
    static let browsers: Set<String> = [
        "company.thebrowser.dia", "dev.serafim.fast", "com.apple.Safari", "com.google.Chrome",
        "company.thebrowser.Browser", "org.mozilla.firefox",
    ]

    init(config: DockConfig) {
        self.config = config
        let state = (try? Data(contentsOf: Self.stateURL)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        let ids = Set(config.contexts.map(\.id))
        self.current = state.map(\.current).flatMap { ids.contains($0) ? $0 : nil } ?? config.contexts[0].id
        for (key, value) in state?.windows ?? [:] {
            if let id = CGWindowID(key) { saved[id] = value }
        }
    }

    // MARK: - Lifecycle

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appLaunched(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appTerminated(app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastSpaceChange = Date()
                // AX only shows the current Space's windows, so look again for ones we haven't met
                // (they get their saved context), and re-pin parked windows once the Space settles:
                // moves made while another Space was showing don't always stick.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.rescan()
                    self?.reassert("space changed")
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert("wake") }
            // Apps and the window server settle for a moment after wake; check again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.reassert("wake+2s") }
        }
        // Lid closed with sleep held off (Electron apps often do this) only sleeps the displays, and
        // unlocking or fast user switching never sends didWake; re-pin on those too.
        for (name, why) in [(NSWorkspace.screensDidWakeNotification, "displays woke"),
                            (NSWorkspace.sessionDidBecomeActiveNotification, "session active")] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassert(why) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert("displays changed") }
        }

        // Global key monitors need the Accessibility grant we already have; this only watches for ⌘-`.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 50, e.modifierFlags.contains(.command) else { return }
            MainActor.assumeIsolated { self?.lastCycleKey = Date() }
        }

        for app in NSWorkspace.shared.runningApplications where manages(app) {
            observe(app)
            scan(app)
        }
        applyVisibility()
        persist()
        changed()
    }

    /// Puts every parked window back where it was. Called on quit, on SIGTERM and from Recover.
    func restoreAll() {
        for (id, w) in windows where w.parkedFrame != nil {
            unpark(id)
        }
        rescueStrays()
        persist()
    }

    // MARK: - Switching

    /// The last few switches (and wake/display passes) and why, for `contextdock://dump`.
    private var recentSwitches: [String] = []

    func note(_ event: String) {
        recentSwitches.append("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(event)")
        recentSwitches = Array(recentSwitches.suffix(20))
    }

    func switchTo(_ target: String, focusing preferred: CGWindowID? = nil, reason: String = "dock") {
        guard config.contexts.contains(where: { $0.id == target }) else { return }
        if target == current {
            if let preferred { focus(preferred) }
            return
        }
        noteFocusedWindow()
        ignoreFocusUntil = Date().addingTimeInterval(0.45)
        note("\(current) -> \(target): \(reason)")
        current = target
        applyVisibility()
        focusCurrent(preferring: preferred)
        persist()
        changed()
    }

    /// Unparks the current context first, then parks the rest (less flicker), grouped per app.
    private func applyVisibility() {
        let byApp = Dictionary(grouping: windows.values, by: \.pid)
        for (pid, list) in byApp {
            let app = AX.app(pid)
            AX.withoutAnimations(app) {
                for w in list where w.context == current || isShared(w.bundleID) { unpark(w.id) }
                for w in list where w.context != current && !isShared(w.bundleID) && !seenFullScreen.contains(w.id) { park(w.id) }
            }
        }
    }

    private func focusCurrent(preferring preferred: CGWindowID?) {
        if let preferred, windows[preferred] != nil {
            focus(preferred)
            return
        }
        // Fullscreen windows are skipped: focusing one jumps to its Space instead of showing this
        // context's desktop. They stay a swipe or ⌘-Tab away.
        let candidates = windows.values
            .filter { $0.context == current && !isShared($0.bundleID) && !AX.isMinimized($0.element) }
            .filter { !AX.isFullScreen($0.element) }
            .sorted { $0.lastFocus > $1.lastFocus }
        if let top = candidates.first {
            focus(top.id)
        } else {
            // Nothing here yet: take keyboard focus off the parked windows. NSApp.activate() is only a
            // request on macOS 14+ and gets refused for a background app, so ask through AX instead.
            AX.set(AX.app(getpid()), kAXFrontmostAttribute, kCFBooleanTrue)
            NSApp.activate()
        }
    }

    func focus(_ id: CGWindowID) {
        guard var w = windows[id] else { return }
        if AX.isMinimized(w.element) { AX.set(w.element, kAXMinimizedAttribute, kCFBooleanFalse) }
        AX.raise(w.element)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        w.lastFocus = Date()
        windows[id] = w
    }

    // MARK: - Dock actions

    /// Clicking an app in the current context's Dock.
    func openApp(_ bundleID: String) {
        let mine = windows.values
            .filter { $0.bundleID == bundleID && ($0.context == current || isShared(bundleID)) && !demoHidden($0.id) }
            .sorted { $0.lastFocus > $1.lastFocus }
        if let top = mine.first(where: { !AX.isMinimized($0.element) }) ?? mine.first {
            ignoreFocusUntil = Date().addingTimeInterval(0.3)
            focus(top.id)
            return
        }

        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            launch(bundleID)
            return
        }

        let elsewhere = windows.values.filter { $0.bundleID == bundleID && !demoHidden($0.id) }.sorted { $0.lastFocus > $1.lastFocus }
        if elsewhere.isEmpty {
            // Running with no windows: do what the native Dock does (a reopen event shows the main
            // window). ⌘N here would mean "new message" in Mimestream or Messages.
            launch(bundleID)
        } else if newWindowApps.contains(bundleID) {
            newWindow(in: running)
        } else if let w = elsewhere.first {
            // A single-window app: bring its window to this context.
            move(w.id, to: current)
            focus(w.id)
        }
    }

    /// Right-click > New Window Here: always a fresh window in the current context.
    func newWindowHere(_ bundleID: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            newWindow(in: running)
        } else {
            launch(bundleID)
        }
    }

    /// Launches the app, or for a running one sends the reopen event a native Dock click sends.
    private func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        awaitingWindow = (bundleID, Date().addingTimeInterval(8))
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Activates the app and sends ⌘N. The window that appears joins the current context.
    private func newWindow(in app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        awaitingWindow = (bundleID, Date().addingTimeInterval(3))
        app.activate()
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: down) // "n"
                e?.flags = .maskCommand
                e?.postToPid(pid)
            }
        }
    }

    // MARK: - Assignment

    func move(_ id: CGWindowID, to context: String) {
        guard config.contexts.contains(where: { $0.id == context }) else { return }
        guard var w = windows[id] else {
            // Not visible to us right now (on another Space): change its saved context, so it lands
            // there when it shows up.
            if var s = saved[id] {
                s.context = context
                saved[id] = s
                note("moved saved window \(id) to \(context) (applies when it's next seen)")
                persist()
            }
            return
        }
        w.context = context
        windows[id] = w
        if context == current { unpark(id) } else if !isShared(w.bundleID) { park(id) }
        persist()
        changed()
    }

    /// The window in front right now (any app), if we manage it.
    var focusedWindow: CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let el = AX.focusedWindow(of: AX.app(app.processIdentifier)) else { return nil }
        return AX.windowID(el).flatMap { windows[$0] != nil ? $0 : nil }
    }

    func moveFocusedWindow(to context: String) {
        guard let id = focusedWindow, context != current else { return }
        move(id, to: context)
        ignoreFocusUntil = Date().addingTimeInterval(0.45)
        focusCurrent(preferring: nil)
    }

    func windows(of bundleID: String, in context: String) -> [Window] {
        windows.values.filter { $0.bundleID == bundleID && $0.context == context }.sorted { $0.lastFocus > $1.lastFocus }
    }

    func hasWindows(_ bundleID: String, in context: String) -> Bool {
        windows.values.contains { $0.bundleID == bundleID && ($0.context == context || isShared(bundleID)) && !demoHidden($0.id) }
    }

    func isShared(_ bundleID: String) -> Bool { config.shared.contains(bundleID) }

    /// A window from another context that was fullscreen: once it has left fullscreen, follow it if
    /// it's the one in front (you exited fullscreen to keep using it), otherwise park it as usual.
    private func checkLeftFullScreen(_ id: CGWindowID) {
        guard let w = windows[id] else { seenFullScreen.remove(id); return }
        if looksFullScreen(w) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.checkLeftFullScreen(id) }
            return
        }
        seenFullScreen.remove(id)
        guard w.context != current, !isShared(w.bundleID) else { return }
        if focusedWindow == id {
            switchTo(w.context, focusing: id, reason: "left fullscreen \(w.bundleID) \(id)")
        } else {
            park(id)
        }
    }

    /// Native fullscreen, or filling a whole screen without being parked (a parked window from another
    /// context sits in the corner, so a full-screen one that isn't parked is in a fullscreen Space).
    private func looksFullScreen(_ w: Window) -> Bool {
        if AX.isFullScreen(w.element) { return true }
        guard w.parkedFrame == nil, let f = AX.frame(w.element) else { return false }
        for screen in NSScreen.screens where Self.same(f, screen.axFrame) || Self.same(f, screen.axVisibleFrame) {
            return true
        }
        return false
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        let dx = abs(a.minX - b.minX), dy = abs(a.minY - b.minY)
        let dw = abs(a.width - b.width), dh = abs(a.height - b.height)
        return max(dx, dy, dw, dh) < 2
    }

    /// The context an app's new windows belong to, if it has one (config `homes`).
    func home(of bundleID: String) -> String? {
        guard let id = config.homes?[bundleID], config.contexts.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var newWindowApps: Set<String> { Self.fallbackNewWindowApps }

    // MARK: - Parking

    private func park(_ id: CGWindowID) {
        guard var w = windows[id], w.parkedFrame == nil,
              !AX.isMinimized(w.element), !AX.isFullScreen(w.element),
              let frame = AX.frame(w.element) else { return }
        w.parkedFrame = frame
        windows[id] = w
        AX.setPosition(w.element, parkCorner(for: frame))
    }

    /// Bottom-right of the visible area of the screen the window came from (or the main screen if that one is gone).
    private func parkCorner(for frame: CGRect) -> CGPoint {
        let screen = NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY)) ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.axVisibleFrame
        return CGPoint(x: v.maxX - 1, y: v.maxY - 1)
    }

    private func unpark(_ id: CGWindowID) {
        guard var w = windows[id], let frame = w.parkedFrame else { return }
        w.parkedFrame = nil
        windows[id] = w
        AX.setFrame(w.element, onScreen(frame))
    }

    /// Keeps a restored frame on a display that still exists.
    private func onScreen(_ frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if NSScreen.containing(axPoint: center) != nil { return frame }
        let v = (NSScreen.main ?? NSScreen.screens[0]).axVisibleFrame
        let size = CGSize(width: min(frame.width, v.width), height: min(frame.height, v.height))
        return CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// A window sitting in a park corner that we have no frame for (e.g. state file lost): centre it.
    private func rescueStrays() {
        for app in NSWorkspace.shared.runningApplications where manages(app) {
            for el in AX.windows(of: AX.app(app.processIdentifier)) where AX.isManageable(el) {
                guard let f = AX.frame(el), isInParkCorner(f) else { continue }
                AX.setFrame(el, onScreen(CGRect(x: -10_000, y: -10_000, width: f.width, height: f.height)))
            }
        }
    }

    private func isInParkCorner(_ f: CGRect) -> Bool {
        NSScreen.screens.contains { s in
            let v = s.axVisibleFrame
            return abs(f.minX - (v.maxX - 1)) < 3 && abs(f.minY - (v.maxY - 1)) < 3
        }
    }

    /// After wake or a display change: pin parked windows back to their (possibly new) corner without
    /// showing them, and pull anything back that an app or macOS moved out of its corner.
    private func reassert(_ why: String) {
        var parked = 0, moved = 0
        for w in windows.values {
            guard let frame = w.parkedFrame else { continue }
            parked += 1
            if !isTucked(w.element, parkedFrom: frame) {
                moved += 1
                AX.setPosition(w.element, parkCorner(for: frame))
            }
        }
        applyVisibility()
        note("\(why): \(parked) parked, \(moved) re-pinned")
        persist()
        changed()
    }

    /// Out of view: pushed off the right edge. macOS clamps the vertical position (it keeps the title
    /// bar's height on screen), so only x tells whether a parked window is still hidden.
    private func isTucked(_ el: AXUIElement, parkedFrom frame: CGRect) -> Bool {
        guard let now = AX.frame(el)?.origin else { return true }
        return now.x >= parkCorner(for: frame).x - 2
    }

    /// An app moved one of its parked windows back on screen (Safari does when a video leaves or
    /// enters fullscreen, because macOS pulls a window on screen when it's brought forward). Put it
    /// straight back, so it shows for a frame or two instead of until the next pass.
    private func windowMoved(_ el: AXUIElement) {
        guard let id = AX.windowID(el), let w = windows[id], let frame = w.parkedFrame,
              !seenFullScreen.contains(id), !isTucked(el, parkedFrom: frame) else { return }
        AX.setPosition(el, parkCorner(for: frame))
        note("re-tucked \(w.bundleID) \(id): the app moved it back on screen")
    }

    // MARK: - Discovery

    private func manages(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != getpid() && app.bundleIdentifier != nil
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard manages(app) else { return }
        observe(app)
        // First windows can take a moment; window-created notifications cover later ones. They count
        // as new (so a link that launched Chrome takes you to Work), except in ContextDock's first 30s,
        // when apps restoring windows at login shouldn't bounce you between contexts.
        let fresh = Date().timeIntervalSince(startedAt) > 30
        for delay in [0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan(app, asNew: fresh) }
        }
    }

    private func appTerminated(_ pid: pid_t) {
        windows = windows.filter { $0.value.pid != pid }
        observers[pid] = nil
        persist()
        changed()
    }

    private func rescan() {
        for app in NSWorkspace.shared.runningApplications where manages(app) {
            observe(app)
            scan(app)
        }
    }

    private func scan(_ app: NSRunningApplication, asNew: Bool = false) {
        let pid = app.processIdentifier
        for el in AX.windows(of: AX.app(pid)) { adopt(el, pid: pid, isNew: asNew) }
        prune(pid)
    }

    /// New windows join the current context, except ones we already knew from before a relaunch.
    @discardableResult
    private func adopt(_ el: AXUIElement, pid: pid_t, isNew: Bool = false) -> Bool {
        guard AX.isManageable(el), let id = AX.windowID(el), windows[id] == nil,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        // A window you asked for here (Dock click, New Window Here) stays here; otherwise an app with a
        // home context (Safari → Personal) sends its windows there.
        let askedHere = awaitingWindow.map { $0.bundleID == bundleID && Date() < $0.until } == true
        var context = askedHere ? current : (home(of: bundleID) ?? current)
        var parked: CGRect?
        if let s = saved[id], s.bundleID == bundleID, config.contexts.contains(where: { $0.id == s.context }) {
            context = s.context
            parked = s.parkedFrame
        }
        windows[id] = Window(id: id, pid: pid, bundleID: bundleID, element: el, context: context,
                             parkedFrame: parked, lastFocus: parked == nil ? Date() : .distantPast)
        if demoActive { demoCreated.insert(id) }
        lastAdoptAt[pid] = Date()
        observeWindow(el, pid: pid, bundleID: bundleID)
        titles[id] = Self.normalized(AX.title(el))

        if isNew, parked == nil, context != current, !isShared(bundleID) {
            // e.g. Velja opened a personal link in a new Safari window while you were in Work. Decide a
            // moment later: a new window can also be a fullscreen video (Safari makes one), which lives
            // in its own Space and shouldn't move you.
            persist()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let w = self.windows[id], w.context != self.current else { return }
                if self.looksFullScreen(w) {
                    if self.seenFullScreen.insert(id).inserted {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.checkLeftFullScreen(id) }
                    }
                    self.note("fullscreen: \(bundleID) \(id) joined \(w.context), stayed in \(self.current)")
                } else {
                    self.switchTo(w.context, focusing: id, reason: "home \(bundleID) \(id)")
                }
            }
            return true
        }

        if context == current || isShared(bundleID) {
            if parked != nil { unpark(id) }
            else if let f = AX.frame(el), isInParkCorner(f) {
                // e.g. ⌘N cascaded off a parked window
                AX.setFrame(el, onScreen(CGRect(x: -10_000, y: -10_000, width: f.width, height: f.height)))
            }
        } else if parked == nil {
            park(id)
        }

        if let wait = awaitingWindow, wait.bundleID == bundleID, Date() < wait.until, context == current {
            awaitingWindow = nil
            ignoreFocusUntil = Date().addingTimeInterval(0.3)
            focus(id)
        }
        persist()
        changed()
        return true
    }

    /// Drops windows that are really closed. AX only lists windows on the current Space, so a window
    /// missing from it might just be on another Space (a fullscreen one, another desktop); the window
    /// server sees every Space and decides.
    private func prune(_ pid: pid_t) {
        let alive = Set(AX.windows(of: AX.app(pid)).compactMap(AX.windowID))
        let before = windows.count
        windows = windows.filter { $0.value.pid != pid || alive.contains($0.key) || AX.windowExists($0.key) }
        if windows.count != before { persist(); changed() }
    }

    // MARK: - Focus following

    private func noteFocusedWindow() {
        if let id = focusedWindow, windows[id]?.context == current {
            windows[id]?.lastFocus = Date()
        }
    }

    /// ⌘-Tab, ⌘-`, a link landing in a browser window, a notification click: if the window that
    /// comes forward lives in another context, go to that context.
    private func focusChanged(pid: pid_t) {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid), manages(app),
              let el = AX.focusedWindow(of: AX.app(pid)), let id = AX.windowID(el) else { return }
        if windows[id] == nil, !adopt(el, pid: pid) { return }
        guard let w = windows[id] else { return }
        if let wait = awaitingWindow, wait.bundleID == w.bundleID, Date() < wait.until { return }
        if Date() < ignoreFocusUntil {
            if w.context == current { windows[id]?.lastFocus = Date() }
            return
        }
        if w.context != current && !isShared(w.bundleID) {
            // A fullscreen window has a Space to itself, so seeing it needs no switch: clicking play in
            // a fullscreen Safari video from Work leaves you in Work.
            if looksFullScreen(w) {
                windows[id]?.lastFocus = Date()
                if seenFullScreen.insert(id).inserted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.checkLeftFullScreen(id) }
                }
                return
            }
            // Only a *parked* window is macOS's fallback pick; a visible one (say, a window that just
            // left fullscreen) is the one you're looking at, so that still follows.
            if Date().timeIntervalSince(lastSpaceChange) < 1.0, w.parkedFrame != nil {
                // macOS picked this window because the Space changed. Stay in this context, and take
                // keyboard focus off the parked window without focusing another window, which could
                // pull you back to a different Space mid-swipe.
                note("space change: stayed in \(current), not following \(w.bundleID) \(id)")
                ignoreFocusUntil = Date().addingTimeInterval(0.4)
                AX.set(AX.app(getpid()), kAXFrontmostAttribute, kCFBooleanTrue)
                return
            }
            if Date().timeIntervalSince(lastCycleKey) < 0.6, let next = nextWindowInContext(pid: pid) {
                // ⌘-` landed on a parked window: cycle to this app's next window here instead.
                ignoreFocusUntil = Date().addingTimeInterval(0.3)
                note("⌘-` kept in \(current): \(w.bundleID) \(id) -> \(next)")
                focus(next)
                return
            }
            windows[id]?.lastFocus = Date()
            switchTo(w.context, focusing: id, reason: "focus-follow \(w.bundleID) \(id)")
        } else {
            windows[id]?.lastFocus = Date()
        }
    }

    /// The app's least recently used window in the current context, so repeated ⌘-` goes round them.
    private func nextWindowInContext(pid: pid_t) -> CGWindowID? {
        windows.values
            .filter { $0.pid == pid && $0.context == current && !AX.isMinimized($0.element) }
            .min { $0.lastFocus < $1.lastFocus }?.id
    }

    // MARK: - Links landing in parked browser windows

    /// A link from another app activates the browser, which may put the tab in a window other than
    /// the one it focuses (Dia routes by profile). Hold the focus decision briefly so a parked
    /// window that gets the new tab can claim it.
    ///
    /// Any app gets the same short wait: if it opens a new window meanwhile (a document from Finder,
    /// ⌘N, a link that makes a window), that window joins the current context and we stay here.
    private func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let activatedAt = Date()
        // Windows on a Space we couldn't see at launch show up once their app comes forward.
        if manages(app) { scan(app) }
        guard let bundleID = app.bundleIdentifier, Self.browsers.contains(bundleID) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, (self.lastAdoptAt[pid] ?? .distantPast) < activatedAt else { return }
                self.focusChanged(pid: pid)
            }
            return
        }
        // Our own switches and ⌘N activate the browser too; those aren't links.
        let ours = activatedAt < ignoreFocusUntil || awaitingWindow.map { $0.bundleID == bundleID && activatedAt < $0.until } == true
        linkWatch[pid] = ours ? nil : activatedAt.addingTimeInterval(2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.lastLinkSwitch < activatedAt,
                  (self.lastAdoptAt[pid] ?? .distantPast) < activatedAt else { return }
            self.focusChanged(pid: pid)
        }
    }

    private func titleChanged(_ el: AXUIElement, pid: pid_t) {
        guard let id = AX.windowID(el), let w = windows[id] else { return }
        let title = Self.normalized(AX.title(el))
        let before = titles[id]
        titles[id] = title
        guard title != before, let until = linkWatch[pid], Date() < until,
              w.parkedFrame != nil, w.context != current, !isShared(w.bundleID) else { return }
        linkWatch[pid] = nil
        lastLinkSwitch = Date()
        switchTo(w.context, focusing: id, reason: "link-landed \(w.bundleID) \(id)")
    }

    /// Ignores unread counters like "(3) Inbox" so a badge update in a parked tab isn't read as a new tab.
    private static func normalized(_ title: String) -> String {
        title.replacingOccurrences(of: #"\(\d+\)\s*|•\s*"#, with: "", options: .regularExpression)
    }

    // MARK: - AX observers

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        let el = AX.app(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, el, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func observeWindow(_ el: AXUIElement, pid: pid_t, bundleID: String) {
        guard let observer = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, el, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(observer, el, kAXMovedNotification as CFString, refcon)
        if Self.browsers.contains(bundleID) {
            AXObserverAddNotification(observer, el, kAXTitleChangedNotification as CFString, refcon)
        }
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch notification {
        case kAXWindowCreatedNotification:
            adopt(element, pid: pid, isNew: true)
        case kAXUIElementDestroyedNotification:
            prune(pid)
        case kAXTitleChangedNotification:
            titleChanged(element, pid: pid)
        case kAXMovedNotification:
            windowMoved(element)
        default:
            // Decide a moment later, once any Space change behind this focus change has been announced.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self?.focusChanged(pid: pid)
            }
        }
    }

    // MARK: - State

    private func persist() {
        var out: [String: SavedWindow] = [:]
        for (id, w) in windows {
            out[String(id)] = SavedWindow(bundleID: w.bundleID, context: w.context, parkedFrame: w.parkedFrame)
        }
        // Keep entries for apps that are still launching so a relaunch doesn't lose them.
        for (id, s) in saved where out[String(id)] == nil && windows[id] == nil
            && !NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID).isEmpty {
            out[String(id)] = s
        }
        let data = try? JSONEncoder().encode(SavedState(current: current, windows: out))
        try? data?.write(to: Self.stateURL, options: .atomic)
    }

    private func changed() { onChange() }

    // MARK: - Demo mode

    /// contextdock://demo/start: minimizes every managed window (all contexts) so a recording shows
    /// only windows opened afterwards. Parked windows are minimized from their corner, so they come
    /// back parked.
    func demoStart() {
        guard !demoActive else { return }
        demoActive = true
        demoCreated = []
        demoMinimized = windows.values.filter { !AX.isMinimized($0.element) }.map(\.id)
        for id in demoMinimized { if let w = windows[id] { AX.set(w.element, kAXMinimizedAttribute, kCFBooleanTrue) } }
        note("demo start: minimized \(demoMinimized.count)")
    }

    /// contextdock://demo/end: closes the windows that appeared during the demo, then un-minimizes yours.
    func demoEnd() {
        guard demoActive else { return }
        demoActive = false
        for id in demoCreated {
            guard let w = windows[id], let close: AXUIElement = AX.get(w.element, kAXCloseButtonAttribute) else { continue }
            AXUIElementPerformAction(close, kAXPressAction as CFString)
        }
        for id in demoMinimized { if let w = windows[id] { AX.set(w.element, kAXMinimizedAttribute, kCFBooleanFalse) } }
        note("demo end: closed \(demoCreated.count), restored \(demoMinimized.count)")
        demoCreated = []
        demoMinimized = []
        applyVisibility()
        focusCurrent(preferring: nil)
        changed()
    }

    /// Writes debug.json next to the state: every managed window with its live frame.
    func dump() {
        let rows: [[String: Any]] = windows.values.sorted { $0.id < $1.id }.map { w in
            let f = AX.frame(w.element) ?? .zero
            return ["id": w.id, "app": w.bundleID, "context": w.context, "title": AX.title(w.element),
                    "frame": [f.minX, f.minY, f.width, f.height], "parked": w.parkedFrame != nil, "fullscreen": AX.isFullScreen(w.element),
                    "focused": w.id == focusedWindow]
        }
        let out: [String: Any] = ["current": current, "frontApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "windows": rows,
                                  "recentSwitches": recentSwitches]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.stateURL.deletingLastPathComponent().appendingPathComponent("debug.json"))
        }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let engine = Unmanaged<WindowEngine>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { engine.handle(name, element: element) }
}
