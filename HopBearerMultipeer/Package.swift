// swift-tools-version:5.9
import PackageDescription

// HopBearerMultipeer, the Apple peer-to-peer transport (MultipeerConnectivity: AWDL / Wi-Fi / infra)
// as a fully INDEPENDENT package, matching HopBearerBle / HopBearerLan / HopBearerRelay.
//
// It is the LAST Apple transport that was still minted inside the driver (its own 10_000 link-id
// space, routed through an `mcPeerByLink` dictionary), which meant it never passed through
// `BearerManager` and therefore could not be switched off at runtime like the others. That mattered
// beyond tidiness: MultipeerConnectivity carries local traffic on Apple devices, so with no way to
// disable it there was no way to prove a delivery actually rode BLE.
let package = Package(
    name: "HopBearerMultipeer",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerMultipeer", targets: ["HopBearerMultipeer"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/apple"),
    ],
    targets: [
        // the SDK package (dir "apple") provides the "HopContract" product.
        .target(name: "HopBearerMultipeer", dependencies: [.product(name: "HopContract", package: "apple")]),
        // Pure-logic coverage (apple-07): the invite tiebreak, the display-name peer-id parse, and the
        // link table transitions. None of these need a live MCSession, so they run headlessly in CI;
        // the MCSession/advertiser/browser glue lives in +Radio.swift and is device-covered.
        .testTarget(name: "HopBearerMultipeerTests", dependencies: ["HopBearerMultipeer"]),
    ]
)
