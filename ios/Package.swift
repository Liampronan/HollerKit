// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HollerKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "HollerKit", targets: ["HollerKit"])
    ],
    targets: [
        .target(name: "HollerKit"),
        .testTarget(name: "HollerKitTests", dependencies: ["HollerKit"])
    ]
)
