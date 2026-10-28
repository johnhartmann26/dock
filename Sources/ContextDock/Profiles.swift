import AppKit

/// Browsers that keep profiles inside one window (Dia: a profile is a set of tabs a window can
/// switch to). On a context switch, every window of such a browser shows that context's profile,
/// so the browser can be shared and links open in the right profile.
///
/// Uses the browser's AppleScript `focus` command, so macOS asks once for permission to control it.
/// It runs off the main thread (about 0.1s), and only when the browser is already running, so a
/// switch never launches it. Dia's `focus` also brings Dia to the front, so if it took the front,
/// `onStoleFocus` lets the engine focus the context's own window again (not the app that was in
/// front before: right after a switch that's still the old context's app, and following it would
/// switch you back).
@MainActor
final class BrowserProfiles {
    var log: (String) -> Void = { _ in }
    var onStoleFocus: () -> Void = {}
    private let queue = DispatchQueue(label: "ContextDock.profiles")

    func apply(_ profiles: [String: [String: String]]?, context: String) {
        for (bundleID, byContext) in profiles ?? [:] {
            guard let profile = byContext[context],
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { continue }
            let name = profile.replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application id "\(bundleID)"
                repeat with w in windows
                    if name of active profile of w is not "\(name)" then focus (profile "\(name)" of w)
                end repeat
            end tell
            """
            let front = NSWorkspace.shared.frontmostApplication
            queue.async { [weak self] in
                // Ask for permission the proper way first: a script run without it just fails.
                var target = AEAddressDesc()
                let status: OSStatus = bundleID.withCString { id in
                    AECreateDesc(typeApplicationBundleID, id, strlen(id), &target)
                    defer { AEDisposeDesc(&target) }
                    return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
                }
                guard status == noErr else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.log("profile: no permission to control \(bundleID) (\(status)); allow ContextDock in System Settings > Privacy & Security > Automation")
                        }
                    }
                    return
                }
                let began = Date()
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                let message = error?[NSAppleScript.errorMessage] as? String
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let now = NSWorkspace.shared.frontmostApplication
                        if front?.bundleIdentifier != bundleID, now?.bundleIdentifier == bundleID {
                            self?.onStoleFocus()
                        }
                        self?.log(message.map { "profile: \(profile) in \(bundleID) failed: \($0)" }
                                  ?? "profile: \(profile) in \(bundleID), \(ms)ms")
                    }
                }
            }
        }
    }
}
