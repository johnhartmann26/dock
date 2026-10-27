import AppKit

/// A frosted panel that sweeps across the screen during a context switch. The windows swap while it
/// fully covers the screen, then it carries on and reveals the new context. It blurs what's behind it
/// (no screen capture, so no Screen Recording permission), sits below the Dock, and is tinted with the
/// destination context's colour. With Reduce Motion on it fades in place instead.
@MainActor
final class Wipe {
    private var window: WipeWindow?
    private(set) var running = false
    var log: (String) -> Void = { _ in }

    private let edge: CGFloat = 140       // soft leading and trailing edges
    private let coverTime = 0.13
    private let revealTime = 0.17

    /// direction: +1 when moving to the context on the right (the sweep travels right to left), -1 back.
    func run(direction: Int, tint: NSColor, below dock: NSWindow, swap: @escaping () -> Void) {
        guard !running, let screen = dock.screen ?? NSScreen.main else { swap(); return }
        running = true
        let began = Date()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let full = screen.frame
        let w = window ?? makeWindow()
        window = w
        tintView(w, tint)

        let covering = NSRect(x: full.minX - edge, y: full.minY, width: full.width + 2 * edge, height: full.height)
        let fromRight = NSRect(x: full.maxX, y: full.minY, width: covering.width, height: full.height)
        let toLeft = NSRect(x: full.minX - covering.width, y: full.minY, width: covering.width, height: full.height)
        let (start, end) = direction > 0 ? (fromRight, toLeft) : (toLeft, fromRight)

        if reduceMotion {
            w.setFrame(covering, display: false)
            w.alphaValue = 0
        } else {
            w.setFrame(start, display: false)
            w.alphaValue = 1
        }
        w.order(.below, relativeTo: dock.windowNumber)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = coverTime
            w.duration = coverTime
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if reduceMotion { w.animator().alphaValue = 1 } else { w.animator().setFrame(covering, display: true) }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let covered = Date()
                swap()
                let swapped = Date()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = self.revealTime
                    w.duration = self.revealTime
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    if reduceMotion { w.animator().alphaValue = 0 } else { w.animator().setFrame(end, display: true) }
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        w.orderOut(nil)
                        self?.running = false
                        let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                        self?.log("wipe: covered \(ms(began, covered))ms, swap \(ms(covered, swapped))ms, reveal \(ms(swapped, Date()))ms")
                    }
                })
            }
        })
    }

    private func makeWindow() -> WipeWindow {
        let w = WipeWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        // Above app windows, below the Dock (which is .floating).
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true

        let tint = CALayer()
        tint.name = "tint"
        blur.layer?.addSublayer(tint)

        // Soft edges: fade the panel in over `edge` points at each side.
        let mask = CAGradientLayer()
        mask.name = "mask"
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        blur.layer?.mask = mask

        w.contentView = blur
        return w
    }

    private func tintView(_ w: NSWindow, _ color: NSColor) {
        guard let layer = w.contentView?.layer, let screen = NSScreen.main else { return }
        let width = screen.frame.width + 2 * edge
        let bounds = CGRect(x: 0, y: 0, width: width, height: screen.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let tint = layer.sublayers?.first(where: { $0.name == "tint" }) {
            tint.frame = bounds
            tint.backgroundColor = color.withAlphaComponent(0.22).cgColor
        }
        if let mask = layer.mask as? CAGradientLayer {
            mask.frame = bounds
            let e = NSNumber(value: Double(edge / width))
            mask.locations = [0, e, NSNumber(value: 1 - e.doubleValue), 1]
        }
        CATransaction.commit()
    }
}

/// AppKit animates a window's frame over `animationResizeTime`, not the animation context's
/// duration, so the wipe sets it explicitly.
final class WipeWindow: NSWindow {
    var duration: TimeInterval = 0.15
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { duration }
}
