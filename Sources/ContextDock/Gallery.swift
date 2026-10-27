import AppKit
import SwiftUI

/// `ContextDock --gallery`: every Dock state on a wallpaper-like background, for design review
/// against the reference video. The bottom Dock switches context every 1.6s to show the animation.
@MainActor
final class GalleryDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = DockConfig.load()
        let ids = config.contexts.map(\.id)
        let rows: [(String, String?)] = ids.map { ($0, nil) }
            + [(ids[0], ids[1]), (ids[0], config.contexts[0].apps.first)]
        let live = DockState(config: config, current: ids[0])

        if CommandLine.arguments.contains("--materials") {
            let options: [(String, NSVisualEffectView.Material, CGFloat)] = [
                ("hudWindow", .hudWindow, 1), ("popover", .popover, 1), ("menu", .menu, 1),
                ("fullScreenUI", .fullScreenUI, 1), ("underWindowBackground", .underWindowBackground, 1),
                ("headerView", .headerView, 1), ("sidebar", .sidebar, 1), ("hudWindow 0.5", .hudWindow, 0.5),
            ]
            let swatches = VStack(spacing: 14) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    Text(o.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 600, height: 48)
                        .background(Frosted(cornerRadius: 20, material: o.1, alpha: o.2))
                }
            }
            .padding(30)
            .frame(width: 900)
            var origin = NSPoint(x: 80, y: 80)
            if let n = CommandLine.arguments.firstIndex(of: "--at"), n + 2 < CommandLine.arguments.count,
               let x = Double(CommandLine.arguments[n + 1]), let y = Double(CommandLine.arguments[n + 2]) {
                origin = NSPoint(x: x, y: y)
            }
            window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 900, height: 600)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.contentView = NSHostingView(rootView: swatches)
            window.orderFrontRegardless()
            if let n = CommandLine.arguments.firstIndex(of: "--window-id-file"), n + 1 < CommandLine.arguments.count {
                try? String(window.windowNumber).write(toFile: CommandLine.arguments[n + 1], atomically: true, encoding: .utf8)
            }
            return
        }

        let view = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                DockView(state: DockState(config: config, current: row.0))
                    .environment(\.forcedHover, row.1)
                    .frame(height: 108)
            }
            DockView(state: live).frame(height: 108)
        }
        .frame(width: 900)
        .background(
            LinearGradient(colors: [Color(hex: "#3B2A6B"), Color(hex: "#7A3C6E"), Color(hex: "#D9752F")],
                           startPoint: .top, endPoint: .bottom)
        )

        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 108 * CGFloat(rows.count + 1)),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ContextDock Gallery"
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        var i = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
            MainActor.assumeIsolated {
                i = (i + 1) % ids.count
                live.show(ids[i])
            }
        }
        if let n = CommandLine.arguments.firstIndex(of: "--window-id-file"), n + 1 < CommandLine.arguments.count {
            try? String(window.windowNumber).write(toFile: CommandLine.arguments[n + 1], atomically: true, encoding: .utf8)
        }
    }
}
