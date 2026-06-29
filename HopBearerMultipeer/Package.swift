// swift-tools-version:5.9
import PackageDescription

// HopBearerMultipeer — no-router Wi-Fi P2P (MultipeerConnectivity / AWDL), the Apple counterpart to
// Android Wi-Fi Direct, as a fully INDEPENDENT package depending only on the Hop SDK.
let package = Package(
    name: "HopBearerMultipeer",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerMultipeer", targets: ["HopBearerMultipeer"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/wrappers/Hop"),
    ],
    targets: [
        .target(name: "HopBearerMultipeer", dependencies: [.product(name: "Hop", package: "Hop")]),
    ]
)
