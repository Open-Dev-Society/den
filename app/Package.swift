// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Den",
    platforms: [.macOS(.v26)], // the on-device model (FoundationModels) arrived in macOS 26
    targets: [
        .executableTarget(
            name: "Den",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
