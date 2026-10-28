import AppKit
import ScreenCaptureKit

/// The Spaces-style slide between contexts.
///
/// Snapshot the screen (without ContextDock's own windows), cover the screen with that picture just
/// below the Dock, swap the real windows underneath, snapshot again, then slide the old picture out
/// while the new one slides in. When the slide ends the overlay goes away and you're looking at the
/// live windows, which match its last frame. After the first visit to a context its last picture is
/// kept (in memory only), so later slides start at once and the windows move while it plays.
///
/// Needs Screen Recording permission. Until it's granted, switches are instant.
@MainActor
final class Slide {
    private(set) var running = false
    var log: (String) -> Void = { _ in }

    private var window: NSWindow?
    private var filter: SCContentFilter?
    private var display: SCDisplay?
    private var askedForPermission = false
    private let slideTime: CFTimeInterval = 0.15

    var permitted: Bool { CGPreflightScreenCaptureAccess() }

    /// The last picture of each context, taken as you left it. Kept in memory only, so the slide can
    /// start straight away instead of waiting for the windows to move and a second snapshot.
    private var pictures: [String: CGImage] = [:]

    /// direction: +1 when moving to the context on the right (content moves left), -1 back.
    func run(direction: Int, from: String, to: String, below dock: NSWindow, swap: @escaping () -> Void) {
        guard !running else { swap(); return }
        guard permitted else {
            if !askedForPermission {
                askedForPermission = true
                CGRequestScreenCaptureAccess()
                log("slide: needs Screen Recording permission (switching instantly until then)")
            }
            swap()
            return
        }
        running = true
        Task { @MainActor in
            let began = Date()
            guard let before = await capture(), let screen = dock.screen ?? NSScreen.main else {
                swap()
                running = false
                return
            }
            pictures[from] = before
            let captured = Date()
            let w = window ?? makeWindow()
            window = w
            w.alphaValue = 1
            w.setFrame(screen.frame, display: false)
            let root = w.contentView!.layer!
            let old = layer(before, in: root.bounds)
            let new = layer(pictures[to], in: root.bounds)
            root.sublayers = [new, old]
            w.order(.below, relativeTo: dock.windowNumber)
            // The overlay has to be on screen before the windows move, or the new context flashes
            // for a frame first. Push it to the window server and give it a frame.
            w.displayIfNeeded()
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(20))
            let covered = Date()

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let duration: CFTimeInterval = reduceMotion ? 0.12 : slideTime
            let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }

            if pictures[to] != nil {
                // Slide to the remembered picture now; the windows move underneath while it plays
                // (Core Animation keeps going while the main thread is busy moving them). Then the
                // overlay fades out over the live windows, which hides anything that changed since.
                animate(old: old, new: new, in: root.bounds, direction: direction, duration: duration, fade: reduceMotion)
                swap()
                let moved = Date()
                let left = duration - moved.timeIntervalSince(covered)
                if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
                await NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.08
                    w.animator().alphaValue = 0
                }
                w.orderOut(nil)
                root.sublayers = nil
                running = false
                log("slide: from memory, to \(to), first snapshot \(ms(began, captured))ms, cover \(ms(captured, covered))ms, swap \(ms(covered, moved))ms (during the slide), total \(ms(began, Date()))ms")
                return
            }

            // First visit to this context since launch: move the windows, then picture them.
            swap()
            let moved = Date()
            // Let apps finish redrawing after their windows moved before taking the "after" picture.
            try? await Task.sleep(for: .milliseconds(25))
            let after = await capture()
            if let after { pictures[to] = after }
            let swapped = Date()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            new.contents = after
            CATransaction.commit()
            animate(old: old, new: new, in: root.bounds, direction: direction, duration: duration, fade: reduceMotion || after == nil) { [weak self] in
                w.orderOut(nil)
                root.sublayers = nil
                self?.running = false
                self?.log("slide: first visit, to \(to), snapshot \(ms(began, captured))ms, cover \(ms(captured, covered))ms, swap \(ms(covered, moved))ms, snapshot \(ms(moved, swapped))ms, total \(ms(began, Date()))ms")
            }
        }
    }

    private func animate(old: CALayer, new: CALayer, in bounds: CGRect, direction: Int, duration: CFTimeInterval,
                         fade: Bool, done: (() -> Void)? = nil) {
        CATransaction.begin()
        if let done { CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } } }
        if fade {
            // Fade the old picture away over the live windows.
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0
            a.duration = duration
            old.opacity = 0
            old.add(a, forKey: "fade")
        } else {
            // Like Spaces: both pictures move one screen width, the old one out, the new one in
            // from the side you're heading toward.
            let shift = CGFloat(direction) * bounds.width
            let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.18, 1.0)
            for (l, from, to) in [(old, bounds.midX, bounds.midX - shift), (new, bounds.midX + shift, bounds.midX)] {
                let a = CABasicAnimation(keyPath: "position.x")
                a.fromValue = from
                a.toValue = to
                a.duration = duration
                a.timingFunction = curve
                l.position.x = to
                l.add(a, forKey: "slide")
            }
        }
        CATransaction.commit()
        // Hand the animation to the window server now, before the main thread gets busy.
        CATransaction.flush()
    }

    /// Drop cached capture targets after a display change.
    func displaysChanged() {
        filter = nil
        pictures = [:]
        display = nil
        prepare()
    }

    /// Looking up what to capture costs ~200ms the first time, so do it ahead of the first switch.
    func prepare() {
        guard permitted else { return }
        Task { @MainActor in try? await self.makeFilter() }
    }

    private func makeFilter() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let d = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else { return }
        let me = content.applications.filter { $0.processID == getpid() }
        filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
        display = d
    }

    private func capture() async -> CGImage? {
        do {
            if filter == nil { try await makeFilter() }
            guard let filter, let display else { return nil }
            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log("slide: snapshot failed (\(error.localizedDescription))")
            filter = nil
            return nil
        }
    }

    private func layer(_ image: CGImage?, in bounds: CGRect) -> CALayer {
        let l = CALayer()
        l.frame = bounds
        l.contents = image
        l.contentsGravity = .resize
        l.actions = ["contents": NSNull(), "position": NSNull(), "opacity": NSNull()]   // only explicit animations
        return l
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.ignoresMouseEvents = true
        // Above app windows, below the Dock (which is .floating); the menu bar stays on top.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        w.contentView = v
        return w
    }
}
