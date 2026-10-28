import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        // --gallery: a design-review window only (no engine, no panel, no menu bar item).
        let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--gallery") ? GalleryDelegate() : AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var engine: WindowEngine!
    private var state: DockState!
    private var panel: DockPanel!
    private var statusItem: NSStatusItem!
    private var hotKeys = HotKeys()
    private var signalSources: [DispatchSourceSignal] = []
    private var trustTimer: Timer?
    private var swipeMonitor: Any?
    /// Held for the app's lifetime: with the Dock hidden (a long fullscreen video) ContextDock has no
    /// visible window, and App Nap would then delay the events and timers it reacts to.
    private var noNap: NSObjectProtocol?
    private var swipeDistance: CGFloat = 0
    private var swipeUsed = false
    private let threeFinger = ThreeFingerSwipe()
    private let profiles = BrowserProfiles()
    /// The context whose browser profiles were last applied.
    private var profilesShown: String?
    private var lastStep: (reason: String, at: Date)?
    /// The context a slide is on its way to, until its windows have moved.
    private var heading: String?
    private lazy var slide: Slide = {
        let s = Slide()
        s.log = { [weak self] in self?.engine.note($0) }
        return s
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                       reason: "Switching windows between contexts")
        let config = DockConfig.load()
        engine = WindowEngine(config: config)
        state = DockState(config: config, current: engine.current)
        state.onSelect = { [weak self] id in self?.userSwitch(to: id, reason: "dock") }
        state.onOpenApp = { [weak self] id in self?.engine.openApp(id) }
        state.onMenuForApp = { [weak self] id in self?.windowMenu(for: id) }
        engine.onChange = { [weak self] in self?.syncUI() }

        panel = DockPanel(state: state)
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.slide.displaysChanged() }
        }
        // Scroll events land on the panel only over the visible bar (the rest is click-through).
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.handleSwipe(event)
            return nil
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        installSignalHandlers()

        if AX.trusted {
            begin()
        } else {
            AX.promptForTrust()
            // Starts by itself once Accessibility is granted in System Settings.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard AX.trusted else { return }
                    t.invalidate()
                    self?.begin()
                }
            }
        }
        syncUI()
    }

    private func begin() {
        engine.start()
        threeFinger.log = { [weak self] in self?.engine.note($0) }
        profiles.log = { [weak self] in self?.engine.note($0) }
        profiles.onStoleFocus = { [weak self] in self?.engine.refocus() }
        if profilesShown != engine.current {
            profilesShown = engine.current
            profiles.apply(engine.config.profiles, context: engine.current)
        }
        // A browser that just opened shows this context's profile once its window is up.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let id = app?.bundleIdentifier, self.engine.config.profiles?[id] != nil else { return }
                for delay in [1.5, 4.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.profiles.apply(self.engine.config.profiles?.filter { $0.key == id }, context: self.engine.current)
                    }
                }
            }
        }
        threeFinger.onSwipe = { [weak self] dir in self?.step(fingers: dir, reason: "3-finger swipe") }
        threeFinger.begin()
        slide.prepare()
        for ctx in engine.config.contexts {
            guard let code = HotKeys.keyCode(for: ctx.key) else { continue }
            let id = ctx.id
            hotKeys.register(code, modifiers: [.control, .option]) { [weak self] in self?.userSwitch(to: id, reason: "hotkey") }
            hotKeys.register(code, modifiers: [.control, .option, .shift]) { [weak self] in self?.engine.moveFocusedWindow(to: id) }
        }
    }

    /// Two-finger swipe on the Dock: one context per swipe, like swiping between desktops.
    /// Fingers moving left go to the context on the right. Stops at the ends.
    private func handleSwipe(_ event: NSEvent) {
        // Trackpad gestures only; momentum after the fingers lift is ignored.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            swipeDistance = 0
            swipeUsed = false
        }
        guard !swipeUsed, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        // Normalise to finger movement whatever the natural-scrolling setting.
        swipeDistance += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        guard abs(swipeDistance) > 36 else { return }
        swipeUsed = true
        step(fingers: swipeDistance < 0 ? -1 : 1, reason: "swipe")
    }

    /// One context left or right. Fingers moving left (-1) go to the context on the right; stops at the ends.
    /// A three-finger swipe over the Dock also arrives as the Dock's scroll, so once either kind of
    /// swipe steps, the other is ignored for a moment: one gesture, one step.
    private func step(fingers: Int, reason: String) {
        let way = fingers < 0 ? "right" : "left"
        if let last = lastStep, last.reason != reason, Date().timeIntervalSince(last.at) < 0.6 {
            engine.note("\(reason) \(way): ignored, same gesture as the \(last.reason)")
            return
        }
        lastStep = (reason, Date())
        let ids = engine.config.contexts.map(\.id)
        // During a slide the windows may not have moved yet, so count from where it's heading.
        let here = heading ?? engine.current
        guard let i = ids.firstIndex(of: here) else { return }
        let next = fingers < 0 ? i + 1 : i - 1
        guard ids.indices.contains(next) else {
            engine.note("\(reason) \(way): already at the end (\(here))")
            return
        }
        userSwitch(to: ids[next], reason: reason)
    }

    /// A switch you asked for (Dock, hotkey, swipe, menu) plays the slide; switches an app
    /// triggers (focus-follow, links, home windows) stay instant so their window isn't held up.
    private func userSwitch(to id: String, reason: String) {
        let ids = engine.config.contexts.map(\.id)
        guard id != engine.current, let from = ids.firstIndex(of: engine.current), let to = ids.firstIndex(of: id) else {
            heading = nil
            engine.switchTo(id, reason: reason)
            return
        }
        guard engine.config.switchAnimation ?? true, !slide.running else {
            // A swipe during a slide switches at once and wins over the slide's own switch.
            heading = nil
            engine.switchTo(id, reason: reason)
            return
        }
        heading = id
        slide.run(direction: to > from ? 1 : -1, from: engine.current, to: id, below: panel) { [weak self] in
            guard let self, self.heading == id else { return }
            self.heading = nil
            self.engine.switchTo(id, reason: reason)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.restoreAll()
    }

    /// contextdock://switch/<id>, move-front/<id>, open/<bundle id>, recover, dump
    /// (for Raycast, Shortcuts and scripts; the Dock stays in sync because it all goes through the engine).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "contextdock" {
            let arg = url.pathComponents.dropFirst().first ?? ""
            switch url.host {
            case "switch": engine.switchTo(arg, reason: "url")
            case "switch-animated": userSwitch(to: arg, reason: "url")
            case "move-front": engine.moveFocusedWindow(to: arg)
            case "move":   // contextdock://move/<window id>/<context>
                let parts = url.pathComponents.dropFirst()
                if parts.count == 2, let id = CGWindowID(parts.first!) { engine.move(id, to: parts.last!) }
            case "open": engine.openApp(arg)
            case "new-window": engine.newWindowHere(arg)
            case "recover": recover()
            case "dump": engine.dump()
            case "demo": arg == "start" ? engine.demoStart() : engine.demoEnd()
            case "login": setOpenAtLogin(arg == "on")
            case "panel": panel.setHidden(arg == "hide")   // debug: show / hide
            default: break
            }
        }
    }

    /// SIGTERM/SIGINT/SIGHUP (logout, `kill`, Ctrl-C) put every window back before exiting.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.engine.restoreAll() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - UI sync

    private func syncUI() {
        if profilesShown != engine.current {
            profilesShown = engine.current
            // During a slide, the overlay covers the browser coming to the front to switch profile,
            // and Dia's own profile animation after it (about a third of a second).
            let release = slide.hold()
            profiles.apply(engine.config.profiles, context: engine.current) { changed in
                if changed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: release) } else { release() }
            }
        }
        state.show(engine.current)
        let ctx = engine.current
        state.running = Set(state.config.contexts.first { $0.id == ctx }?.apps.filter { engine.hasWindows($0, in: ctx) } ?? [])
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button, let ctx = state.currentContext else { return }
        let image = Glyph.image(ctx.symbol, pointSize: 12)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = AX.trusted ? " \(ctx.name)" : " Needs Accessibility"
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for ctx in engine.config.contexts {
            let item = menu.addItem(withTitle: ctx.name, action: #selector(switchFromMenu(_:)), keyEquivalent: ctx.key)
            item.keyEquivalentModifierMask = [.control, .option]
            item.representedObject = ctx.id
            item.state = ctx.id == engine.current ? .on : .off
            item.target = self
        }
        menu.addItem(.separator())
        let move = menu.addItem(withTitle: "Move Front Window To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for ctx in engine.config.contexts where ctx.id != engine.current {
            let item = sub.addItem(withTitle: ctx.name, action: #selector(moveFromMenu(_:)), keyEquivalent: ctx.key)
            item.keyEquivalentModifierMask = [.control, .option, .shift]
            item.representedObject = ctx.id
            item.target = self
        }
        move.submenu = sub
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit Dock Contents…", action: #selector(editConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Show All Windows (Recover)", action: #selector(recover), keyEquivalent: "").target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ContextDock", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    /// Right-click on a Dock app: its windows in this context, and where to send the front one.
    private func windowMenu(for bundleID: String) -> NSMenu {
        let menu = NSMenu()
        for w in engine.windows(of: bundleID, in: engine.current) {
            let title = AX.title(w.element)
            let item = menu.addItem(withTitle: title.isEmpty ? "Untitled window" : title, action: #selector(focusWindow(_:)), keyEquivalent: "")
            item.representedObject = w.id
            item.target = self
        }
        if let front = engine.windows(of: bundleID, in: engine.current).first {
            menu.addItem(.separator())
            for ctx in engine.config.contexts where ctx.id != engine.current {
                let item = menu.addItem(withTitle: "Move Front Window to \(ctx.name)", action: #selector(moveWindow(_:)), keyEquivalent: "")
                item.representedObject = [front.id, ctx.id] as [Any]
                item.target = self
            }
        }
        menu.addItem(.separator())
        let item = menu.addItem(withTitle: "New Window Here", action: #selector(openApp(_:)), keyEquivalent: "")
        item.representedObject = bundleID
        item.target = self
        return menu
    }

    @objc private func switchFromMenu(_ sender: NSMenuItem) { userSwitch(to: sender.representedObject as! String, reason: "menu") }
    @objc private func moveFromMenu(_ sender: NSMenuItem) { engine.moveFocusedWindow(to: sender.representedObject as! String) }
    @objc private func focusWindow(_ sender: NSMenuItem) { engine.focus(sender.representedObject as! CGWindowID) }
    @objc private func openApp(_ sender: NSMenuItem) { engine.newWindowHere(sender.representedObject as! String) }
    @objc private func moveWindow(_ sender: NSMenuItem) {
        let pair = sender.representedObject as! [Any]
        engine.move(pair[0] as! CGWindowID, to: pair[1] as! String)
    }

    @objc private func editConfig() { NSWorkspace.shared.open(DockConfig.url) }
    @objc private func recover() { engine.restoreAll() ; engine.switchTo(engine.current) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() { setOpenAtLogin(SMAppService.mainApp.status != .enabled) }

    /// A regular Login Item (System Settings > General > Login Items), so it can be turned off there too.
    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ContextDock: login item change failed: \(error.localizedDescription)")
        }
        updateStatusItem()
    }
}

/// The floating bar. Non-activating so clicking it never steals focus from your window.
final class DockPanel: NSPanel {
    init(state: DockState) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable = false
        hidesOnDeactivate = false
        let host = NSHostingView(rootView: DockView(state: state))
        host.sizingOptions = []
        contentView = host
        place()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    /// Hidden means transparent and click-through (debug only). macOS already keeps this panel off
    /// fullscreen Spaces, so nothing hides it in normal use.
    func setHidden(_ hidden: Bool) {
        ignoresMouseEvents = hidden
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = hidden ? 0.08 : 0.16
            animator().alphaValue = hidden ? 0 : 1
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Spans the bottom of the main screen's usable area; the bar is centred inside and clicks on
    /// the transparent rest fall through to the windows below.
    func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        setFrame(NSRect(x: v.minX, y: v.minY, width: v.width, height: DockMetrics.panelHeight), display: true)
    }
}

/// Global hotkeys via Carbon (no extra permission needed).
@MainActor
final class HotKeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private static var shared: HotKeys?

    init() {
        HotKeys.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            MainActor.assumeIsolated { HotKeys.shared?.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ keyCode: UInt32, modifiers: NSEvent.ModifierFlags, _ handler: @escaping () -> Void) {
        var mods: UInt32 = 0
        if modifiers.contains(.control) { mods |= UInt32(controlKey) }
        if modifiers.contains(.option) { mods |= UInt32(optionKey) }
        if modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
        if modifiers.contains(.command) { mods |= UInt32(cmdKey) }
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        if RegisterEventHotKey(keyCode, mods, EventHotKeyID(signature: OSType(0x43444B21), id: id), GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
            handlers[id] = handler
        }
    }

    static func keyCode(for key: String) -> UInt32? {
        let codes: [String: Int] = ["1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
                                    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9]
        return codes[key].map(UInt32.init)
    }
}
