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
            log("three-finger swipe ignored: macOS still uses it (set Swipe between full-screen apps to four fingers)")
            return
        }
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
/// Counts the fingers that are *moving*, each measured from where it landed, so a thumb or palm
/// resting on the pad doesn't count. Three fingers moving the same way sideways is a swipe. A fourth
/// finger moving with them is the Spaces swipe and is left alone. After a swipe fires, it re-arms
/// once fewer than three fingers are down.
private struct SwipeTracker {
    var landed: [Int32: (x: Float, y: Float)] = [:]
    var fired = false
    var abandoned = false
    /// The most fingers seen moving in this touch, for the log when nothing fired.
    var mostMoving = 0
    /// When the last swipe fired. Fingers lifting unevenly can look like a second swipe right
    /// after the first; real back-to-back swipes are 0.45s or more apart.
    var firedAt: Double = 0

    enum Outcome { case swipe(Int), missed(String) }

    mutating func update(_ touches: [Touch], at time: Double) -> Outcome? {
        let ids = Set(touches.map(\.id))
        landed = landed.filter { ids.contains($0.key) }
        for t in touches where landed[t.id] == nil { landed[t.id] = (t.x, t.y) }

        if touches.isEmpty {
            let report: Outcome? = (!fired && !abandoned && mostMoving >= 3)
                ? .missed("\(mostMoving) fingers moved, no swipe") : nil
            fired = false
            abandoned = false
            mostMoving = 0
            return report
        }
        if fired || abandoned {
            // Re-arm once fewer than three fingers remain; whatever is still down starts from here.
            if touches.count < 3 {
                fired = false
                abandoned = false
                mostMoving = 0
                for t in touches { landed[t.id] = (t.x, t.y) }
            }
            return nil
        }

        var left = 0, right = 0, stirring = 0
        for t in touches {
            guard let l = landed[t.id] else { continue }
            let dx = t.x - l.x, dy = t.y - l.y
            if abs(dx) > 0.035 || abs(dy) > 0.035 { stirring += 1 }
            guard abs(dx) > 0.07, abs(dx) > abs(dy) * 1.2 else { continue }
            if dx < 0 { left += 1 } else { right += 1 }
        }
        mostMoving = max(mostMoving, stirring)
        if stirring >= 4 {
            abandoned = true
            return .missed("4 fingers moving (Spaces swipe)")
        }
        // Three sideways together, and nothing else moving with them.
        guard stirring == 3, left == 3 || right == 3 else { return nil }
        fired = true
        guard time - firedAt > 0.3 else { return .missed("second swipe within 0.3s of the last, treated as the same one") }
        firedAt = time
        return .swipe(left == 3 ? -1 : 1)
    }
}

private nonisolated(unsafe) var tracker = SwipeTracker()
private nonisolated(unsafe) var loggedStates = false

/// MultitouchSupport's per-frame callback. Each finger record is 96 bytes: identifier at offset 16,
/// touch state at 20, and the
/// normalized position (two Floats, 0...1, origin bottom-left) at 32.
private let contactCallback: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = { _, data, count, timestamp, _ in
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
    switch tracker.update(touches, at: timestamp) {
    case .swipe(let dir)?:
        DispatchQueue.main.async { MainActor.assumeIsolated { ThreeFingerSwipe.shared?.fire(dir) } }
    case .missed(let why)?:
        DispatchQueue.main.async { MainActor.assumeIsolated { ThreeFingerSwipe.shared?.log("three-finger swipe: \(why)") } }
    case nil:
        break
    }
    return 0
}
