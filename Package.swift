// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SysRec",
    // macOS 26 for CATapDescription.bundleIDs / processRestoreEnabled.
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic (CSV parsing, naming, trimming math), unit-tested.
        .target(name: "SysRecCore"),
        // The menu-bar app: Core Audio tap, Spotify control, UI.
        .executableTarget(
            name: "SysRec",
            dependencies: ["SysRecCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SysRecCoreTests",
            dependencies: ["SysRecCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
