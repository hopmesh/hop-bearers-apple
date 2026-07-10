// swift-tools-version:5.9
import PackageDescription

// HopBearerLan — the LAN transport (mDNS + TCP) as a fully INDEPENDENT package. It depends on nothing
// but the Hop SDK (the C-ABI contract face + bearer kit); a host that wants LAN links pulls in just
// this. Nothing here is shared with any other bearer — "1 isolated lib per bearer".
let package = Package(
    name: "HopBearerLan",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerLan", targets: ["HopBearerLan"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/wrappers/Hop"),
    ],
    targets: [
        // the SDK package (dir "Hop") provides the "Hop" product.
        .target(name: "HopBearerLan", dependencies: [.product(name: "HopContract", package: "Hop")]),
        // Pure-logic coverage (apple-07): the dedup tiebreaker / survivor pick, the wasSurfaced
        // link-lifecycle rule (apple-12), the length-prefix deframer, and the Bonjour-name hex parse.
        // None of these need a live NWConnection, so they run in a headless macOS CI job.
        .testTarget(name: "HopBearerLanTests", dependencies: ["HopBearerLan"]),
    ]
)
