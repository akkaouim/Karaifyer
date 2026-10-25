// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Karaifyer",
    // macOS 26 for CATapDescription.bundleIDs / processRestoreEnabled (as SysRec).
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic (CSV, track list, pipeline JSON, LRC, chord grid, run state), unit-tested.
        .target(name: "KaraifyerCore"),
        // The app: SysRec's recorder (copied) + the Karaoké tab driving the karaoke pipeline.
        .executableTarget(
            name: "Karaifyer",
            dependencies: ["KaraifyerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The lyrics video renderer for the pipeline's video step (same drawing as the Lecteur).
        .executableTarget(name: "karaifyer-render", dependencies: ["KaraifyerCore"]),
        .testTarget(
            name: "KaraifyerCoreTests",
            dependencies: ["KaraifyerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
