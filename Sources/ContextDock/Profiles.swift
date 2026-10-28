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
/// switch you back). `done` runs once every browser has switched and the focus is put back, so the
/// slide can keep covering the screen until then; it says whether any window changed profile (Dia
/// then still plays its own profile animation for a moment).
@MainActor
final class BrowserProfiles {
    var log: (String) -> Void = { _ in }
    var onStoleFocus: () -> Void = {}
    private let queue = DispatchQueue(label: "ContextDock.profiles")

    func apply(_ profiles: [String: [String: String]]?, context: String, done: @escaping (_ changed: Bool) -> Void = { _ in }) {
        let browsers = (profiles ?? [:]).compactMap { bundleID, byContext in
            byContext[context].map { (bundleID, $0) }
        }.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.0).isEmpty }
        guard !browsers.isEmpty else { done(false); return }
        var left = browsers.count
        var changed = false
        let finished = { (switched: Bool) in
            changed = changed || switched
            left -= 1
            if left == 0 { done(changed) }
        }
        for (bundleID, profile) in browsers {
            let name = profile.replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            set switched to false
            tell application id "\(bundleID)"
                repeat with w in windows
                    if name of active profile of w is not "\(name)" then
                        focus (profile "\(name)" of w)
                        set switched to true
                    end if
                end repeat
            end tell
            return switched
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
                            finished(false)
                        }
                    }
                    return
                }
                let began = Date()
                var error: NSDictionary?
                let switched = NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue ?? false
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                let message = error?[NSAppleScript.errorMessage] as? String
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let now = NSWorkspace.shared.frontmostApplication
                        if front?.bundleIdentifier != bundleID, now?.bundleIdentifier == bundleID {
                            self?.onStoleFocus()
                        }
                        self?.log(message.map { "profile: \(profile) in \(bundleID) failed: \($0)" }
                                  ?? "profile: \(profile) in \(bundleID), \(switched ? "switched" : "already"), \(ms)ms")
                        finished(switched)
                    }
                }
            }
        }
    }
}
