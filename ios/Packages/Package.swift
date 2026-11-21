// swift-tools-version: 6.2
// Local SPM package with the app's modules. Logic lives here so it can be tested with
// `swift test` on macOS without a simulator (docs/08-dev-harness.md §2).
import PackageDescription

let package = Package(
    name: "Zone2Core",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "Zone2Kit", targets: ["Zone2Kit"]),
        .library(name: "Zone2UI", targets: ["Zone2UI"]),
        .library(name: "TrainerKit", targets: ["TrainerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Models, API client, GRDB store, SyncEngine, formatting. No UI.
        .target(
            name: "Zone2Kit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
        // Design system and screens.
        .target(
            name: "Zone2UI",
            dependencies: ["Zone2Kit"],
            resources: [.process("Resources")]
        ),
        // Smart trainer and BLE heart rate: byte parsers and the 1 Hz ride recorder (docs/11-trainer.md).
        // No CoreBluetooth here, so it is tested on raw bytes.
        .target(name: "TrainerKit", dependencies: ["Zone2Kit"]),
        .testTarget(name: "TrainerKitTests", dependencies: ["TrainerKit"]),
        .testTarget(name: "Zone2KitTests", dependencies: ["Zone2Kit"]),
        .testTarget(name: "Zone2UITests", dependencies: ["Zone2UI"]),
    ]
)
