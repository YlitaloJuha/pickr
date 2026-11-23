// swift-tools-version: 6.4
// Tools version 6.4 is required for `.iOS(.v27)`.
import PackageDescription

/// Every target uses the same `async` semantics as the app target, which builds with
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES`: a `nonisolated async` function runs on its
/// caller's actor unless it is marked `@concurrent`.
let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

/// The models layer, like the app target, is main-actor isolated by default.
let modelSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)] + concurrencySettings

let package = Package(
    name: "PickrKit",
    // macOS is listed only so that `swift test` runs on a Mac.
    platforms: [.iOS(.v27), .macOS(.v26)],
    products: [
        .library(name: "PickrCore", targets: ["PickrCore"]),
        .library(name: "PickrPersistence", targets: ["PickrPersistence"]),
        .library(name: "PickrModels", targets: ["PickrModels"]),
    ],
    targets: [
        .target(name: "PickrCore", swiftSettings: concurrencySettings),
        .target(name: "PickrPersistence", dependencies: ["PickrCore"], swiftSettings: concurrencySettings),
        .target(name: "PickrModels", dependencies: ["PickrCore", "PickrPersistence"], swiftSettings: modelSettings),
        .target(name: "PickrTestSupport", dependencies: ["PickrCore", "PickrModels"], swiftSettings: modelSettings),
        .testTarget(
            name: "PickrCoreTests",
            dependencies: ["PickrCore", "PickrTestSupport"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "PickrPersistenceTests",
            dependencies: ["PickrPersistence", "PickrTestSupport"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "PickrModelsTests",
            dependencies: ["PickrModels", "PickrTestSupport"],
            swiftSettings: modelSettings
        ),
    ]
)
