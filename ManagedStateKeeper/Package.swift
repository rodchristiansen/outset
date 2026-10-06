// swift-tools-version:6.0
import PackageDescription

// Managed State Keeper: the Prefs / Run / Logs window for outset. It stands apart
// from Outset.xcodeproj; the outset engine, its paths and its launchd jobs are
// unchanged, and the GUI talks to the engine only through the root helper.
let package = Package(
    name: "ManagedStateKeeper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ManagedStateKeeperApp", targets: ["ManagedStateKeeperApp"]),
        .executable(name: "ManagedStateKeeperHelper", targets: ["ManagedStateKeeperHelper"])
    ],
    targets: [
        .target(
            name: "ManagedStateKeeperXPC",
            path: "Sources/ManagedStateKeeperXPC"
        ),
        .executableTarget(
            name: "ManagedStateKeeperApp",
            dependencies: ["ManagedStateKeeperXPC"],
            path: "Sources/ManagedStateKeeperApp"
        ),
        .executableTarget(
            name: "ManagedStateKeeperHelper",
            dependencies: ["ManagedStateKeeperXPC"],
            path: "Sources/ManagedStateKeeperHelper"
        ),
        .testTarget(
            name: "ManagedStateKeeperAppTests",
            dependencies: ["ManagedStateKeeperApp", "ManagedStateKeeperXPC"],
            path: "Tests/ManagedStateKeeperAppTests"
        )
    ]
)
