import AppKit
import Carbon.HIToolbox
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = DockConfig.load()
        engine = WindowEngine(config: config)
        state = DockState(config: config, current: engine.current)
        state.onSelect = { [weak self] id in self?.engine.switchTo(id) }
        state.onOpenApp = { [weak self] id in self?.engine.openApp(id) }
        state.onMenuForApp = { [weak self] id in self?.windowMenu(for: id) }
        engine.onChange = { [weak self] in self?.syncUI() }

        panel = DockPanel(state: state)
        panel.orderFrontRegardless()
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
        for ctx in engine.config.contexts {
            guard let code = HotKeys.keyCode(for: ctx.key) else { continue }
            let id = ctx.id
            hotKeys.register(code, modifiers: [.control, .option]) { [weak self] in self?.engine.switchTo(id, reason: "hotkey") }
            hotKeys.register(code, modifiers: [.control, .option, .shift]) { [weak self] in self?.engine.moveFocusedWindow(to: id) }
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
            case "move-front": engine.moveFocusedWindow(to: arg)
            case "open": engine.openApp(arg)
            case "new-window": engine.newWindowHere(arg)
            case "recover": recover()
            case "dump": engine.dump()
            case "demo": arg == "start" ? engine.demoStart() : engine.demoEnd()
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
        state.show(engine.current)
        let ctx = engine.current
        state.running = Set(state.config.contexts.first { $0.id == ctx }?.apps.filter { engine.hasWindows($0, in: ctx) } ?? [])
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button, let ctx = state.currentContext else { return }
        let image = NSImage(systemSymbolName: ctx.symbol, accessibilityDescription: ctx.name)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
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

    @objc private func switchFromMenu(_ sender: NSMenuItem) { engine.switchTo(sender.representedObject as! String, reason: "menu") }
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
