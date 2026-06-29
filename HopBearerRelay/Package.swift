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
        .package(path: "../../../sdk/wrappers/Hop"),
    ],
    targets: [
        .target(name: "HopBearerRelay", dependencies: [.product(name: "Hop", package: "Hop")]),
    ]
)
