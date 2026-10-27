import AppKit
import ScreenCaptureKit

/// The Spaces-style slide between contexts.
///
/// Snapshot the screen (without ContextDock's own windows), cover the screen with that picture just
/// below the Dock, swap the real windows underneath, snapshot again, then slide the old picture out
/// while the new one slides in. When the slide ends the overlay goes away and you're looking at the
/// live windows, which match its last frame. Snapshots are kept in memory only for the transition.
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
    private let slideTime: CFTimeInterval = 0.28

    var permitted: Bool { CGPreflightScreenCaptureAccess() }

    /// direction: +1 when moving to the context on the right (content moves left), -1 back.
    func run(direction: Int, below dock: NSWindow, swap: @escaping () -> Void) {
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
            let captured = Date()
            let w = window ?? makeWindow()
            window = w
            w.setFrame(screen.frame, display: false)
            let root = w.contentView!.layer!
            let old = layer(before, in: root.bounds)
            let new = layer(nil, in: root.bounds)
            root.sublayers = [new, old]
            w.order(.below, relativeTo: dock.windowNumber)

            swap()
            // Let apps finish redrawing after their windows moved before taking the "after" picture.
            try? await Task.sleep(for: .milliseconds(45))
            let after = await capture()
            let swapped = Date()

            let width = root.bounds.width
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            CATransaction.begin()
            CATransaction.setAnimationDuration(reduceMotion ? 0.18 : slideTime)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.25, 1))
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    w.orderOut(nil)
                    root.sublayers = nil
                    self?.running = false
                    let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                    self?.log("slide: snapshot \(ms(began, captured))ms, swap+snapshot \(ms(captured, swapped))ms, slide \(ms(swapped, Date()))ms")
                }
            }
            if reduceMotion || after == nil {
                // Fade the old picture away over the live windows.
                old.opacity = 0
            } else {
                // Start the new picture just off the side it comes from, then slide both.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                new.contents = after
                new.position.x += CGFloat(direction) * width
                CATransaction.commit()
                old.position.x -= CGFloat(direction) * width
                new.position.x -= CGFloat(direction) * width
            }
            CATransaction.commit()
        }
    }

    /// Drop cached capture targets after a display change.
    func displaysChanged() {
        filter = nil
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
        l.actions = ["contents": NSNull()]
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
