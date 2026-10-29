import AppKit

/// Right ⌘ + ←/→ steps between contexts, Right ⌘ + a context's key jumps to it. Only the right-hand
/// Command key, so left ⌘←/→ keeps moving to the start/end of a line in text.
///
/// Carbon hotkeys can't tell the two Command keys apart, so this is an event tap: it sees every key
/// press, acts on these few and swallows them, and passes everything else through untouched. Needs
/// the Accessibility permission ContextDock already has.
@MainActor
final class RightCommandKeys {
    var onStep: (_ fingers: Int) -> Void = { _ in }
    var onJump: (_ keyCode: Int64) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    /// Key codes that jump to a context (1, 2, 3).
    var jumpKeys: Set<Int64> = []

    private var tap: CFMachPort?
    /// Key codes whose key-down we swallowed, so their key-up is swallowed too.
    private var swallowed: Set<Int64> = []

    private static let left: Int64 = 123, right: Int64 = 124
    /// NX_DEVICERCMDKEYMASK / NX_DEVICELCMDKEYMASK in the event's raw flags.
    private static let rightCommand: UInt64 = 0x10, leftCommand: UInt64 = 0x08

    func begin() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: rightCommandCallback, userInfo: refcon) else {
            log("right ⌘ keys: couldn't watch the keyboard (needs Accessibility)")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("right ⌘ keys: listening")
    }

    /// Returns true to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowed.remove(code) != nil }
        let raw = event.flags.rawValue
        let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate]
        guard raw & Self.rightCommand != 0, raw & Self.leftCommand == 0, event.flags.intersection(others).isEmpty,
              code == Self.left || code == Self.right || jumpKeys.contains(code) else { return false }
        swallowed.insert(code)
        // Holding the keys repeats; one press, one switch.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
        switch code {
        case Self.left: onStep(1)        // like fingers moving right: the context on the left
        case Self.right: onStep(-1)
        default: onJump(code)
        }
        return true
    }
}

private func rightCommandCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                  _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<RightCommandKeys>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { keys.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
