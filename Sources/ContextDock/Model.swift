import AppKit
import SwiftUI

/// One persistent environment: its own Dock items and its own windows.
struct DockContext: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var color: String          // hex, e.g. "#2F6BD8"
    var apps: [String]         // bundle identifiers, in Dock order
    var key: String            // ⌃⌥ + key switches to this context

    var tint: Color { Color(hex: color) }
}

struct DockConfig: Codable {
    var contexts: [DockContext]
    /// Apps whose windows stay visible in every context (music, password manager).
    var shared: [String]

    static let fallback = DockConfig(
        contexts: [
            DockContext(id: "work", name: "Work", symbol: "briefcase.fill", color: "#2F6BD8",
                        apps: ["company.thebrowser.dia", "com.mimestream.Mimestream", "com.tinyspeck.slackmacgap",
                               "com.granola.app", "com.flexibits.fantastical2.mac"],
                        key: "1"),
            DockContext(id: "personal", name: "Personal", symbol: "house.fill", color: "#D9862B",
                        apps: ["company.thebrowser.dia", "com.apple.MobileSMS", "com.culturedcode.ThingsMac",
                               "com.apple.Notes", "com.hnc.Discord"],
                        key: "2"),
            DockContext(id: "agents", name: "Agents", symbol: "sparkles", color: "#8A5CF6",
                        apps: ["com.anthropic.claudefordesktop", "com.openai.codex", "dev.serafim.fast",
                               "com.microsoft.VSCode", "com.apple.Terminal"],
                        key: "3"),
        ],
        shared: ["com.apple.Music", "com.1password.1password", "com.apple.finder"]
    )

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// Loads ~/Library/Application Support/ContextDock/config.json, writing the default on first run.
    static func load() -> DockConfig {
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(DockConfig.self, from: data) {
            return config
        }
        fallback.save()
        return fallback
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: DockConfig.url, options: .atomic)
    }
}

/// An app tile in a context's Dock.
struct DockApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage
    var id: String { bundleID }

    init?(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        self.bundleID = bundleID
        self.name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
