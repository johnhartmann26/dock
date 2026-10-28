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
    /// The same for every switch, long enough to cover a browser changing profile underneath.
    private let slideTime: CFTimeInterval = 0.6

    var permitted: Bool { CGPreflightScreenCaptureAccess() }

    /// The last picture of each context, taken as you left it. Kept in memory only, so the slide can
    /// start straight away instead of waiting for the windows to move and a second snapshot.
    private var pictures: [String: CGImage] = [:]

    /// Work started by the switch that changes what's on screen after the windows move (a browser
    /// switching profile brings itself to the front, redraws, then the context's window is put back).
    /// The overlay stays up until it's done, at most `holdLimit`, so you don't see it happen.
    private var holds = 0
    private var slideNumber = 0
    private let holdLimit: TimeInterval = 1.0

    /// Keep the overlay up until the returned closure is called. Does nothing when no slide is playing.
    func hold() -> () -> Void {
        guard running else { return {} }
        holds += 1
        let number = slideNumber
        var released = false
        return { [weak self] in
            guard !released, let self, self.slideNumber == number else { return }
            released = true
            self.holds -= 1
        }
    }

    private func waitForHolds() async -> Bool {
        guard holds > 0 else { return false }
        let limit = Date().addingTimeInterval(holdLimit)
        while holds > 0, Date() < limit { try? await Task.sleep(for: .milliseconds(10)) }
        // Give the app a moment to draw what it just switched to.
        try? await Task.sleep(for: .milliseconds(40))
        return true
    }

    /// The picture the slide is heading to, while it's on screen, so a second switch can carry on from it.
    private weak var showing: CALayer?

    /// direction: +1 when moving to the context on the right (content moves left), -1 back.
    func run(direction: Int, from: String, to: String, below dock: NSWindow, swap: @escaping () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: CFTimeInterval = reduceMotion ? 0.12 : slideTime
        if running {
            // A second switch while the slide plays (a quick double swipe): carry on from where the
            // picture is now to the next context, instead of finishing the old slide first.
            if let w = window, w.isVisible, let root = w.contentView?.layer, let showing, let picture = pictures[to], !reduceMotion {
                chain(direction: direction, to: to, picture: picture, window: w, root: root, from: showing,
                      duration: duration, swap: swap)
            } else {
                drop()
                swap()
            }
            return
        }
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
        holds = 0
        slideNumber += 1
        let number = slideNumber
        Task { @MainActor in
            let began = Date()
            guard let before = await capture(), let screen = dock.screen ?? NSScreen.main else {
                guard number == slideNumber else { return }
                swap()
                running = false
                return
            }
            guard number == slideNumber else { return }
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
            guard number == slideNumber else { return }
            let covered = Date()
            let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }

            if pictures[to] != nil {
                // Slide to the remembered picture now; the windows move underneath while it plays
                // (Core Animation keeps going while the main thread is busy moving them). Then the
                // overlay fades out over the live windows, which hides anything that changed since.
                showing = new
                animate(old: old, new: new, in: root.bounds, direction: direction, duration: duration, fade: reduceMotion)
                swap()
                let moved = Date()
                guard let held = await finish(w, number: number, left: duration - moved.timeIntervalSince(covered)) else { return }
                log("slide: from memory, to \(to), first snapshot \(ms(began, captured))ms, cover \(ms(captured, covered))ms, swap \(ms(covered, moved))ms (during the slide)\(held > 0.001 ? ", held \(Int(held * 1000))ms" : ""), total \(ms(began, Date()))ms")
                return
            }

            // First visit to this context since launch: move the windows, then picture them.
            swap()
            let moved = Date()
            // Let apps finish redrawing after their windows moved before taking the "after" picture.
            if await !waitForHolds() { try? await Task.sleep(for: .milliseconds(25)) }
            guard number == slideNumber else { return }
            let after = await capture()
            guard number == slideNumber else { return }
            if let after { pictures[to] = after }
            let swapped = Date()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            new.contents = after
            CATransaction.commit()
            showing = new
            animate(old: old, new: new, in: root.bounds, direction: direction, duration: duration, fade: reduceMotion || after == nil) { [weak self] in
                guard let self, number == self.slideNumber else { return }
                w.orderOut(nil)
                root.sublayers = nil
                self.showing = nil
                self.running = false
                self.log("slide: first visit, to \(to), snapshot \(ms(began, captured))ms, cover \(ms(captured, covered))ms, swap \(ms(covered, moved))ms, snapshot \(ms(moved, swapped))ms, total \(ms(began, Date()))ms")
            }
        }
    }

    /// Keep sliding from wherever the pictures are now: everything on the overlay moves on by the
    /// same amount, with the next context's picture coming in right behind the one that was arriving.
    private func chain(direction: Int, to: String, picture: CGImage, window w: NSWindow, root: CALayer, from current: CALayer,
                       duration: CFTimeInterval, swap: @escaping () -> Void) {
        slideNumber += 1
        holds = 0
        let number = slideNumber
        let began = Date()
        let bounds = root.bounds
        let shift = CGFloat(direction) * bounds.width
        let x = current.presentation()?.position.x ?? current.position.x
        let delta = bounds.midX - (x + shift)
        let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.18, 1.0)
        w.alphaValue = 1
        let new = layer(picture, in: bounds)
        CATransaction.begin()
        for l in root.sublayers ?? [] {
            let at = l.presentation()?.position.x ?? l.position.x
            l.removeAllAnimations()
            slideLayer(l, from: at, to: at + delta, duration: duration, curve: curve)
        }
        root.addSublayer(new)
        slideLayer(new, from: x + shift, to: bounds.midX, duration: duration, curve: curve)
        CATransaction.commit()
        CATransaction.flush()
        showing = new
        swap()
        Task { @MainActor in
            guard let held = await finish(w, number: number, left: duration - Date().timeIntervalSince(began)) else { return }
            log("slide: carried on to \(to)\(held > 0.001 ? ", held \(Int(held * 1000))ms" : ""), total \(Int(Date().timeIntervalSince(began) * 1000))ms")
        }
    }

    /// Wait for the slide to end and anything holding the cover, then fade the cover out over the
    /// live windows. Returns how long it was held, or nil if another switch took over meanwhile.
    private func finish(_ w: NSWindow, number: Int, left: TimeInterval) async -> TimeInterval? {
        if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
        guard number == slideNumber else { return nil }
        let held = Date()
        _ = await waitForHolds()
        guard number == slideNumber else { return nil }
        let heldFor = Date().timeIntervalSince(held)
        await NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            w.animator().alphaValue = 0
        }
        guard number == slideNumber else { return nil }
        w.orderOut(nil)
        w.contentView?.layer?.sublayers = nil
        showing = nil
        running = false
        return heldFor
    }

    /// Take the cover down now (a switch it can't carry on to).
    private func drop() {
        slideNumber += 1
        holds = 0
        window?.orderOut(nil)
        window?.contentView?.layer?.sublayers = nil
        showing = nil
        running = false
        log("slide: dropped for a switch it couldn't carry on to")
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
            slideLayer(old, from: bounds.midX, to: bounds.midX - shift, duration: duration, curve: curve)
            slideLayer(new, from: bounds.midX + shift, to: bounds.midX, duration: duration, curve: curve)
        }
        CATransaction.commit()
        // Hand the animation to the window server now, before the main thread gets busy.
        CATransaction.flush()
    }

    private func slideLayer(_ l: CALayer, from: CGFloat, to: CGFloat, duration: CFTimeInterval, curve: CAMediaTimingFunction) {
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = curve
        l.position.x = to
        l.add(a, forKey: "slide")
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
