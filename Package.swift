// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextDock",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ContextDock",
            path: "Sources/ContextDock",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
