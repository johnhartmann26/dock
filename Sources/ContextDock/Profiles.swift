import AppKit

/// Browsers that keep profiles inside a window (Dia: a profile is a set of tabs a window shows).
/// Each context has its own browser window; a window you open in a context (Dock click, New Window
/// Here) is switched once to that context's profile, so Personal's window shows Solo and Work's
/// shows Work. Windows are never switched on a context switch.
///
/// Uses the browser's AppleScript `focus` command, so macOS asks once for permission to control it.
/// The new window is the browser's front window (`window 1`) when this runs.
@MainActor
final class BrowserProfiles {
    var log: (String) -> Void = { _ in }
    private let queue = DispatchQueue(label: "ContextDock.profiles")

    func applyToNewWindow(of bundleID: String, profile: String) {
        let name = profile.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(bundleID)"
            if (count of windows) > 0 then
                set w to window 1
                if name of active profile of w is not "\(name)" then
                    focus (profile "\(name)" of w)
                    return true
                end if
            end if
            return false
        end tell
        """
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
            var error: NSDictionary?
            let switched = NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue ?? false
            let message = error?[NSAppleScript.errorMessage] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.log(message.map { "profile: new \(bundleID) window to \(profile) failed: \($0)" }
                              ?? "profile: new \(bundleID) window \(switched ? "switched to" : "already in") \(profile)")
                }
            }
        }
    }
}
