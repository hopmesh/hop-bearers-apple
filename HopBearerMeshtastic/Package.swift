// swift-tools-version:5.9
import PackageDescription

// HopBearerMeshtastic, the Meshtastic/LoRa transport as a fully INDEPENDENT package. It depends on nothing
// but the Hop SDK (the pure-Swift HopContract), like every other bearer; a host that wants to relay Hop
// traffic through a connected Meshtastic radio pulls in just this. Nothing here is shared with any other
// bearer ("1 isolated lib per bearer"), but it speaks the SAME Hop link-frame grammar (HELLO/PING/PONG/
// DATA) so the consumer sees identical linkUp/linkBytes/linkDown semantics regardless of radio.
let package = Package(
    name: "HopBearerMeshtastic",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerMeshtastic", targets: ["HopBearerMeshtastic"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/apple"),
    ],
    targets: [
        // The SDK package (dir "apple") provides the "HopContract" product.
        .target(name: "HopBearerMeshtastic", dependencies: [.product(name: "HopContract", package: "apple")]),
        // Pure-logic + state-machine coverage: the Meshtastic protobuf codec, the fragment/reassembly
        // layer, the Hop link-frame grammar, dedup, and the full MeshtasticBearer state machine driven
        // against a fake radio (no CoreBluetooth). The real GATT client (MeshtasticBearer+Radio.swift) is
        // excluded from the coverage denominator and covered by the on-device workflow.
        .testTarget(name: "HopBearerMeshtasticTests", dependencies: ["HopBearerMeshtastic"]),
    ]
)
