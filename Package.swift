// swift-tools-version:5.9
import PackageDescription

// HopBearersApple: the ROOT manifest that makes this tree consumable as a SwiftPM package.
//
// WHY THIS FILE EXISTS. SwiftPM can only resolve a dependency whose manifest sits at the REPOSITORY
// ROOT. This tree exports to the hop-bearers-apple mirror, whose root therefore held five package
// DIRECTORIES and no Package.swift, so the documented usage in README.md
//
//     .package(url: "https://github.com/hopmesh/hop-bearers-apple.git", from: "0.0.2")
//     .product(name: "HopBearerBle", package: "hop-bearers-apple")
//
// could never work. Resolving the real published tag from a scratch package fails with "the package
// manifest at '/Package.swift' cannot be accessed", so every tagged release of the Apple bearers was
// published but unusable. That was verified against the live tag before this file was written.
//
// Each bearer stays its own PRODUCT, so a consumer still links only the transports it wants ("1
// isolated lib per bearer"); one package exposing five products is how SwiftPM expresses that. The
// per-bearer Package.swift files remain, because the monorepo builds and coverage-gates each bearer
// independently (tools/apple-cov-gate.sh runs `swift test` inside each one). SwiftPM ignores a manifest
// in a subdirectory that nothing references, so the two coexist.
//
// WHY THE SDK DEPENDENCY IS A URL RATHER THAN A PATH, even in the monorepo. This manifest is the
// PACKAGING face of the tree, and it has to describe what a consumer of the mirror gets, which is
// always the published SDK. A path dependency cannot serve that: `sdk/apple` and this directory
// `bearers/apple` share the final component "apple", which is a path dependency's identity, so SwiftPM
// read the package as depending on itself and refused with "cyclic dependency between packages
// HopBearersApple -> HopBearersApple requires tools-version 6.0 or later". Raising the manifest to
// tools-version 6.0 would push a Swift 6 toolchain requirement onto every consumer to work around a
// directory name, so the dependency is the published package in both trees instead. DEVELOPMENT still
// happens in the per-bearer packages, which keep their path dependency on the in-tree SDK and are what
// CI tests; this manifest only has to describe the shipped artifact.
let package = Package(
    name: "HopBearersApple",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerBle", targets: ["HopBearerBle"]),
        .library(name: "HopBearerLan", targets: ["HopBearerLan"]),
        .library(name: "HopBearerMultipeer", targets: ["HopBearerMultipeer"]),
        .library(name: "HopBearerRelay", targets: ["HopBearerRelay"]),
        .library(name: "HopBearerMeshtastic", targets: ["HopBearerMeshtastic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hopmesh/hop-sdk-apple.git", from: "0.0.2"),
    ],
    targets: [
        // Sources stay in the per-bearer package layout, so each target points at where they already
        // live rather than moving a single file.
        .target(name: "HopBearerBle",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerBle/Sources/HopBearerBle"),
        .target(name: "HopBearerLan",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerLan/Sources/HopBearerLan"),
        .target(name: "HopBearerMultipeer",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerMultipeer/Sources/HopBearerMultipeer"),
        .target(name: "HopBearerRelay",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerRelay/Sources/HopBearerRelay"),
        .target(name: "HopBearerMeshtastic",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerMeshtastic/Sources/HopBearerMeshtastic"),
    ]
)
