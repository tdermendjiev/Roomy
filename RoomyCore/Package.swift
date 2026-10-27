// swift-tools-version: 5.9
//
// RoomyCore — the platform-independent heart of Roomy.
//
// Targets
//   RoomyCore           Foundation-only scanner, rule catalog, probes, disposal. macOS + Linux.
//   RoomyFleet          Policy, audit log, Prometheus metrics, licensing, hub (central inventory + dashboard). macOS + Linux.
//   roomy               The CLI (ArgumentParser). Same binary logic on macOS and Linux.
//
// The license-minting tool lives in tools/licensetool (private, not part of the public export).
//
import PackageDescription

let package = Package(
    name: "RoomyCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RoomyCore", targets: ["RoomyCore"]),
        .library(name: "RoomyFleet", targets: ["RoomyFleet"]),
        .executable(name: "roomy", targets: ["roomy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "RoomyCore",
            resources: [.embedInCode("Rules/builtin-rules.json")]
        ),
        .target(
            name: "RoomyFleet",
            dependencies: [
                "RoomyCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.embedInCode("Hub/dashboard.html")]
        ),
        .executableTarget(
            name: "roomy",
            dependencies: [
                "RoomyCore",
                "RoomyFleet",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "RoomyCoreTests", dependencies: ["RoomyCore"]),
        .testTarget(name: "RoomyFleetTests", dependencies: ["RoomyFleet"]),
        .testTarget(name: "roomyCLITests", dependencies: ["roomy"]),
    ]
)
