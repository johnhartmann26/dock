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
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert() }
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

    func switchTo(_ target: String, focusing preferred: CGWindowID? = nil) {
        guard config.contexts.contains(where: { $0.id == target }) else { return }
        if target == current {
            if let preferred { focus(preferred) }
            return
        }
        noteFocusedWindow()
        ignoreFocusUntil = Date().addingTimeInterval(0.45)
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
                for w in list where w.context != current && !isShared(w.bundleID) { park(w.id) }
            }
        }
    }

    private func focusCurrent(preferring preferred: CGWindowID?) {
        if let preferred, windows[preferred] != nil {
            focus(preferred)
            return
        }
        let candidates = windows.values
            .filter { $0.context == current && !isShared($0.bundleID) && !AX.isMinimized($0.element) }
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
            .filter { $0.bundleID == bundleID && ($0.context == current || isShared(bundleID)) }
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

        let elsewhere = windows.values.filter { $0.bundleID == bundleID }.sorted { $0.lastFocus > $1.lastFocus }
        if elsewhere.isEmpty || newWindowApps.contains(bundleID) {
            newWindow(in: running)
        } else if let w = elsewhere.first {
            // A single-window app: bring its window to this context.
            move(w.id, to: current)
            focus(w.id)
        }
    }

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
        guard var w = windows[id] else { return }
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
        windows.values.contains { $0.bundleID == bundleID && ($0.context == context || isShared(bundleID)) }
    }

    func isShared(_ bundleID: String) -> Bool { config.shared.contains(bundleID) }

    private var newWindowApps: Set<String> { Self.fallbackNewWindowApps }

    // MARK: - Parking

    private func park(_ id: CGWindowID) {
        guard var w = windows[id], w.parkedFrame == nil,
              !AX.isMinimized(w.element), !AX.isFullScreen(w.element),
              let frame = AX.frame(w.element) else { return }
        let screen = NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY)) ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.axVisibleFrame
        w.parkedFrame = frame
        windows[id] = w
        AX.setPosition(w.element, CGPoint(x: v.maxX - 1, y: v.maxY - 1))
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

    /// After wake or a display change, re-park anything an app pulled back and re-anchor corners.
    private func reassert() {
        for (id, w) in windows where w.parkedFrame != nil {
            guard let frame = w.parkedFrame else { continue }
            var copy = w
            copy.parkedFrame = nil
            windows[id] = copy
            AX.setFrame(w.element, frame)      // back to its spot so park() measures the right screen
            park(id)
        }
        applyVisibility()
        changed()
    }

    // MARK: - Discovery

    private func manages(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != getpid() && app.bundleIdentifier != nil
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard manages(app) else { return }
        observe(app)
        // First windows can take a moment; window-created notifications cover later ones.
        for delay in [0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan(app) }
        }
    }

    private func appTerminated(_ pid: pid_t) {
        windows = windows.filter { $0.value.pid != pid }
        observers[pid] = nil
        persist()
        changed()
    }

    private func scan(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        for el in AX.windows(of: AX.app(pid)) { adopt(el, pid: pid) }
        prune(pid)
    }

    /// New windows join the current context, except ones we already knew from before a relaunch.
    @discardableResult
    private func adopt(_ el: AXUIElement, pid: pid_t) -> Bool {
        guard AX.isManageable(el), let id = AX.windowID(el), windows[id] == nil,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        var context = current
        var parked: CGRect?
        if let s = saved[id], s.bundleID == bundleID, config.contexts.contains(where: { $0.id == s.context }) {
            context = s.context
            parked = s.parkedFrame
        }
        windows[id] = Window(id: id, pid: pid, bundleID: bundleID, element: el, context: context,
                             parkedFrame: parked, lastFocus: parked == nil ? Date() : .distantPast)
        observeWindow(el, pid: pid, bundleID: bundleID)
        titles[id] = Self.normalized(AX.title(el))

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

    private func prune(_ pid: pid_t) {
        let alive = Set(AX.windows(of: AX.app(pid)).compactMap(AX.windowID))
        let before = windows.count
        windows = windows.filter { $0.value.pid != pid || alive.contains($0.key) }
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
        windows[id]?.lastFocus = Date()
        if w.context != current && !isShared(w.bundleID) {
            switchTo(w.context, focusing: id)
        }
    }

    // MARK: - Links landing in parked browser windows

    /// A link from another app activates the browser, which may put the tab in a window other than
    /// the one it focuses (Dia routes by profile). Hold the focus decision briefly so a parked
    /// window that gets the new tab can claim it.
    private func appActivated(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, Self.browsers.contains(bundleID) else {
            focusChanged(pid: app.processIdentifier)
            return
        }
        let pid = app.processIdentifier
        let activatedAt = Date()
        // Our own switches and ⌘N activate the browser too; those aren't links.
        let ours = activatedAt < ignoreFocusUntil || awaitingWindow.map { $0.bundleID == bundleID && activatedAt < $0.until } == true
        linkWatch[pid] = ours ? nil : activatedAt.addingTimeInterval(2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.lastLinkSwitch < activatedAt else { return }
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
        switchTo(w.context, focusing: id)
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
        if Self.browsers.contains(bundleID) {
            AXObserverAddNotification(observer, el, kAXTitleChangedNotification as CFString, refcon)
        }
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch notification {
        case kAXWindowCreatedNotification:
            adopt(element, pid: pid)
        case kAXUIElementDestroyedNotification:
            prune(pid)
        case kAXTitleChangedNotification:
            titleChanged(element, pid: pid)
        default:
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { focusChanged(pid: pid) }
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

    /// Writes debug.json next to the state: every managed window with its live frame.
    func dump() {
        let rows: [[String: Any]] = windows.values.sorted { $0.id < $1.id }.map { w in
            let f = AX.frame(w.element) ?? .zero
            return ["id": w.id, "app": w.bundleID, "context": w.context, "title": AX.title(w.element),
                    "frame": [f.minX, f.minY, f.width, f.height], "parked": w.parkedFrame != nil,
                    "focused": w.id == focusedWindow]
        }
        let out: [String: Any] = ["current": current, "frontApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "windows": rows]
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
