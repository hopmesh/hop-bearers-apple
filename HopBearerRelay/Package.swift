// swift-tools-version:5.9
import PackageDescription

// HopBearerRelay, the cloud-relay transport (one outbound WebSocket, URLSession only) as a fully
// INDEPENDENT package depending only on the Hop SDK.
let package = Package(
    name: "HopBearerRelay",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerRelay", targets: ["HopBearerRelay"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/apple"),
    ],
    targets: [
        .target(name: "HopBearerRelay", dependencies: [.product(name: "HopContract", package: "apple")]),
        // Pure-logic coverage: the stable peerId derivation, the exponential-backoff step, the 429
        // Retry-After parse, and the jittered reconnect delay. None need a live WebSocket, so they run in
        // a headless macOS CI job.
        //
        // The TEST target additionally links `Hop` (the libhop node) so one case can drive failover
        // through the REAL §19 pool rather than a hand-rolled resolver: PLAT-003 was that no SDK
        // exposed the pool at all, so "an SDK-only host survives its relay going dark" was unprovable.
        // The library target still depends on HopContract alone, so a consumer driving the node via
        // UniFFI does not double-link the Rust core.
        .testTarget(
            name: "HopBearerRelayTests",
            dependencies: ["HopBearerRelay", .product(name: "Hop", package: "apple")]
        ),
    ]
)
