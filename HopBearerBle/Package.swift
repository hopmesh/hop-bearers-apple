// swift-tools-version:5.9
import PackageDescription

// HopBearerBle, the BLE transport (CoreBluetooth L2CAP + GATT-PSM handshake) as a fully INDEPENDENT
// package depending only on the Hop SDK. ALL Bluetooth lives here, including the iBeacon/CoreLocation
// background-wake (BeaconWake.swift), nothing BLE leaks into the SDK, the driver, or the app.
let package = Package(
    name: "HopBearerBle",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerBle", targets: ["HopBearerBle"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/apple"),
    ],
    targets: [
        .target(name: "HopBearerBle", dependencies: [.product(name: "HopContract", package: "apple")]),
        // The tests drive the REAL bearer dedup through a fake DedupLink + a fake LinkSink, so the test
        // target needs HopContract to name LinkSink / HopRole (the sink the bearer surfaces links to).
        .testTarget(name: "HopBearerBleTests", dependencies: ["HopBearerBle", .product(name: "HopContract", package: "apple")]),
    ]
)
