import AppKit

/// A three-finger left/right swipe anywhere on the trackpad moves one context.
///
/// macOS has no public API for system-wide trackpad gestures, so this reads raw touches through the
/// private MultitouchSupport framework (what BetterTouchTool and Swish use). It's loaded with dlopen;
/// if a macOS update changes it, the feature switches itself off and the Dock swipe and hotkeys
/// still work.
///
/// It only acts while macOS's own three-finger horizontal swipe is off (Trackpad > More Gestures >
/// Swipe between full-screen apps set to four fingers), so one swipe never does both.
@MainActor
final class ThreeFingerSwipe {
    /// -1 = fingers moved left (go to the context on the right), +1 = fingers moved right.
    var onSwipe: (Int) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    private typealias Callback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeRawPointer) -> Void

    private var devices: [UnsafeRawPointer] = []
    private var register: Register?
    private var unregister: Register?
    private var start: Start?
    private var stop: Stop?
    private var createList: CreateList?
    private var warnedSystemOwnsGesture = false

    fileprivate static var shared: ThreeFingerSwipe?

    func begin() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let c = dlsym(handle, "MTDeviceCreateList"), let r = dlsym(handle, "MTRegisterContactFrameCallback"),
              let u = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let s = dlsym(handle, "MTDeviceStart"), let st = dlsym(handle, "MTDeviceStop") else {
            log("three-finger swipe off: MultitouchSupport isn't available")
            return
        }
        createList = unsafeBitCast(c, to: CreateList.self)
        register = unsafeBitCast(r, to: Register.self)
        unregister = unsafeBitCast(u, to: Register.self)
        start = unsafeBitCast(s, to: Start.self)
        stop = unsafeBitCast(st, to: Stop.self)
        ThreeFingerSwipe.shared = self
        attach()

        // Trackpads can stop reporting after sleep, and a Magic Trackpad may connect later.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reattach() }
            }
        }
    }

    private func attach() {
        guard let list = createList?()?.takeRetainedValue() as? [AnyObject] else { return }
        devices = list.map { UnsafeRawPointer(Unmanaged.passRetained($0).toOpaque()) }
        for d in devices {
            register?(d, contactCallback)
            start?(d, 0)
        }
        log("three-finger swipe listening on \(devices.count) trackpad(s)")
    }

    func reattach() {
        for d in devices {
            unregister?(d, contactCallback)
            stop?(d)
            Unmanaged<AnyObject>.fromOpaque(d).release()
        }
        devices = []
        attach()
    }

    /// macOS uses three-finger horizontal swipes itself unless they're set to four fingers or off
    /// (2 = swipe between full-screen apps; built-in and Magic Trackpad keep separate settings).
    fileprivate func systemOwnsThreeFingerSwipe() -> Bool {
        for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            let v = CFPreferencesCopyAppValue("TrackpadThreeFingerHorizSwipeGesture" as CFString, domain as CFString) as? Int
            if (v ?? 0) != 0 { return true }
        }
        return false
    }

    fileprivate func fire(_ direction: Int) {
        if systemOwnsThreeFingerSwipe() {
            if !warnedSystemOwnsGesture {
                warnedSystemOwnsGesture = true
                log("three-finger swipe ignored: macOS still uses it (set Swipe between full-screen apps to four fingers)")
            }
            return
        }
        warnedSystemOwnsGesture = false
        onSwipe(direction)
    }
}

/// One finger in a MultitouchSupport frame.
private struct Touch {
    let id: Int32
    let x: Float, y: Float
}

/// Gesture state, touched only on the multitouch callback thread.
///
/// A gesture starts when three fingers are down and follows *those* fingers by id, so a finger
/// landing late, lifting early or a thumb grazing the pad doesn't restart it. It ends when every
/// finger is up, or when a fourth arrives (four fingers is the Spaces swipe).
private struct SwipeTracker {
    var start: [Int32: (x: Float, y: Float)] = [:]
    var fired = false
    var abandoned = false

    mutating func update(_ touches: [Touch]) -> Int? {
        if touches.isEmpty {
            start = [:]
            fired = false
            abandoned = false
            return nil
        }
        if touches.count >= 4 { abandoned = true }
        guard !abandoned, !fired else { return nil }
        if start.isEmpty {
            guard touches.count == 3 else { return nil }
            for t in touches { start[t.id] = (t.x, t.y) }
            return nil
        }
        var dx: Float = 0, dy: Float = 0, n: Float = 0
        for t in touches {
            guard let s = start[t.id] else { continue }
            dx += t.x - s.x
            dy += t.y - s.y
            n += 1
        }
        guard n >= 2 else { return nil }
        dx /= n
        dy /= n
        guard abs(dx) > 0.08, abs(dx) > abs(dy) * 1.2 else { return nil }
        fired = true
        return dx < 0 ? -1 : 1
    }
}

private nonisolated(unsafe) var tracker = SwipeTracker()
private nonisolated(unsafe) var loggedStates = false

/// MultitouchSupport's per-frame callback. Each finger record is 96 bytes: identifier at offset 16,
/// touch state at 20, and the
/// normalized position (two Floats, 0...1, origin bottom-left) at 32.
private let contactCallback: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = { _, data, count, _, _ in
    var touches: [Touch] = []
    var states: [Int32] = []
    if let data {
        for i in 0..<Int(count) {
            let f = data.advanced(by: i * 96)
            let state = f.load(fromByteOffset: 20, as: Int32.self)
            states.append(state)
            // In contact. Published reverse-engineering numbers these 3-5 or 4-6 (making, touching,
            // breaking); 3...5 covers "touching" under either, and hovering is rare on a trackpad.
            guard (3...5).contains(state) else { continue }
            touches.append(Touch(id: f.load(fromByteOffset: 16, as: Int32.self),
                                 x: f.load(fromByteOffset: 32, as: Float.self),
                                 y: f.load(fromByteOffset: 36, as: Float.self)))
        }
    }
    if count >= 3, !loggedStates {
        loggedStates = true
        let seen = states.map(String.init).joined(separator: ",")
        DispatchQueue.main.async { MainActor.assumeIsolated { ThreeFingerSwipe.shared?.log("three-finger swipe: first touch states \(seen)") } }
    }
    if let dir = tracker.update(touches) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { ThreeFingerSwipe.shared?.fire(dir) }
        }
    }
    return 0
}
