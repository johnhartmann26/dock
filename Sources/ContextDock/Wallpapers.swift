import AppKit

/// Each context's desktop picture, light or dark with the system.
///
/// Set on every screen when you switch (while the slide covers the screen) and when the system
/// changes between light and dark, only when it differs from what's showing. A context without a
/// picture of its own shows the desktop picture you had before ContextDock first changed it.
@MainActor
final class Wallpapers {
    var log: (String) -> Void = { _ in }

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Returns whether it changed the picture on any screen.
    /// Your own desktop picture, saved the first time ContextDock replaces it.
    private var original: String? {
        get { UserDefaults.standard.string(forKey: "originalWallpaper") }
        set { UserDefaults.standard.set(newValue, forKey: "originalWallpaper") }
    }

    @discardableResult
    func apply(_ wallpaper: Wallpaper?, context: String) -> Bool {
        let own = wallpaper?.path(dark: Self.isDark)
        if own != nil, original == nil, let screen = NSScreen.main {
            original = NSWorkspace.shared.desktopImageURL(for: screen)?.path
        }
        guard let path = own ?? original else { return false }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("wallpaper: \(path) for \(context) not found")
            return false
        }
        var changed = false
        let began = Date()
        for screen in NSScreen.screens where NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != url.standardizedFileURL {
            do {
                // Keep the screen's own fill and color settings.
                let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
                changed = true
            } catch {
                log("wallpaper: couldn't set \(url.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        if changed {
            log("wallpaper: \(url.lastPathComponent) for \(context) (\(Self.isDark ? "dark" : "light")), \(Int(Date().timeIntervalSince(began) * 1000))ms")
        }
        return changed
    }

    /// Ask for a picture file, starting in the system's desktop pictures.
    static func choose(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
