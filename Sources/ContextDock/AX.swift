import AppKit
import ApplicationServices

/// Private but long-stable bridge from an AX window to its CGWindowID (used by AeroSpace and yabai).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        // A hung app must not freeze the Dock.
        AXUIElementSetMessagingTimeout(el, 0.6)
        return el
    }

    static func get<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? T
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, value) == .success
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        get(app, kAXWindowsAttribute) ?? []
    }

    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        get(app, kAXFocusedWindowAttribute)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p: AXValue = get(el, kAXPositionAttribute), let s: AXValue = get(el, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &point)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { set(el, kAXPositionAttribute, v) }
    }

    static func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { set(el, kAXSizeAttribute, v) }
    }

    /// Position, then size, then position again: macOS clamps a resize against the old origin.
    static func setFrame(_ el: AXUIElement, _ frame: CGRect) {
        setPosition(el, frame.origin)
        setSize(el, frame.size)
        setPosition(el, frame.origin)
    }

    static func isMinimized(_ el: AXUIElement) -> Bool { get(el, kAXMinimizedAttribute) ?? false }
    static func isFullScreen(_ el: AXUIElement) -> Bool { get(el, "AXFullScreen") ?? false }
    static func title(_ el: AXUIElement) -> String { get(el, kAXTitleAttribute) ?? "" }

    /// Real document windows. Panels, popovers and floating palettes are left alone (they follow their app),
    /// and so is anything above normal window level or tiny: call indicators (Granola's), picture-in-picture,
    /// HUDs. Those stay visible in every context, because parking them makes the app fight back (flicker).
    static func isManageable(_ el: AXUIElement) -> Bool {
        let role: String? = get(el, kAXRoleAttribute)
        let subrole: String? = get(el, kAXSubroleAttribute)
        guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return false }
        if let id = windowID(el), let level = windowLevel(id), level != 0 { return false }
        guard let f = frame(el), f.width >= 80, f.height >= 80 else { return false }
        return true
    }

    /// Whether the window server still has this window, on any Space.
    static func windowExists(_ id: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
        return !(info?.isEmpty ?? true)
    }

    /// On the Space that's showing right now.
    static func isOnScreen(_ id: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// The window server layer (0 = normal windows; floating panels and overlays sit higher).
    static func windowLevel(_ id: CGWindowID) -> Int? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
        return info?.first?[kCGWindowLayer as String] as? Int
    }

    /// Chrome and Electron animate AX frame changes while AXEnhancedUserInterface is on (AeroSpace does the same toggle).
    static func withoutAnimations(_ app: AXUIElement, _ body: () -> Void) {
        let enhanced: Bool = get(app, "AXEnhancedUserInterface") ?? false
        if enhanced { set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        body()
        if enhanced { set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    static func raise(_ el: AXUIElement) {
        set(el, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }
}

/// AX uses a top-left origin on the primary display; NSScreen uses bottom-left.
extension NSScreen {
    var axVisibleFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let v = visibleFrame
        return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }

    var axFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func containing(axPoint p: CGPoint) -> NSScreen? {
        screens.first { $0.axFrame.contains(p) }
    }
}
