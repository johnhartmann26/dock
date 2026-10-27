import AppKit
import SwiftUI

/// One persistent environment: its own Dock items and its own windows.
struct DockContext: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String         // an SF Symbol name, or "robot" (drawn in Glyphs.swift)
    var color: String          // hex, e.g. "#2F6BD8"
    var apps: [String]         // bundle identifiers, in Dock order
    var key: String            // ⌃⌥ + key switches to this context

    var tint: Color { Color(hex: color) }
}

struct DockConfig: Codable {
    var contexts: [DockContext]
    /// Apps whose windows stay visible in every context (music, password manager).
    var shared: [String]
    /// Apps whose new windows always go to one context, by bundle id (one browser per context).
    /// Optional so configs from before this key still load.
    var homes: [String: String]?

    static let fallback = DockConfig(
        contexts: [
            DockContext(id: "personal", name: "Personal", symbol: "house.fill", color: "#CF8812",
                        apps: ["company.thebrowser.dia", "com.apple.MobileSMS", "com.culturedcode.ThingsMac",
                               "com.apple.Notes", "com.hnc.Discord"],
                        key: "1"),
            DockContext(id: "work", name: "Work", symbol: "briefcase.fill", color: "#3277BB",
                        apps: ["com.google.Chrome", "com.mimestream.Mimestream", "com.tinyspeck.slackmacgap",
                               "com.granola.app", "com.flexibits.fantastical2.mac"],
                        key: "2"),
            DockContext(id: "agents", name: "Agents", symbol: "robot", color: "#7B5CC4",
                        apps: ["dev.serafim.fast", "com.anthropic.claudefordesktop", "com.openai.codex",
                               "com.microsoft.VSCode", "com.apple.Terminal"],
                        key: "3"),
        ],
        shared: ["com.apple.Music", "com.1password.1password", "com.apple.finder"],
        homes: ["com.google.Chrome": "work", "company.thebrowser.dia": "personal", "dev.serafim.fast": "agents"]
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
