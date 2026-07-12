// swift-tools-version:5.9
import PackageDescription

// HopBearerRelay — the cloud-relay transport (one outbound WebSocket, URLSession only) as a fully
// INDEPENDENT package depending only on the Hop SDK.
let package = Package(
    name: "HopBearerRelay",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerRelay", targets: ["HopBearerRelay"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/wrappers/apple"),
    ],
    targets: [
        .target(name: "HopBearerRelay", dependencies: [.product(name: "HopContract", package: "apple")]),
        // Pure-logic coverage: the stable peerId derivation, the exponential-backoff step, the 429
        // Retry-After parse, and the jittered reconnect delay. None need a live WebSocket, so they run in
        // a headless macOS CI job.
        .testTarget(name: "HopBearerRelayTests", dependencies: ["HopBearerRelay"]),
    ]
)
