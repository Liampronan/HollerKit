// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HollerKit",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "HollerKit", targets: ["HollerKit"])
    ],
    targets: [
        .target(
            name: "HollerKit",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "HollerKitTests", dependencies: ["HollerKit"])
    ]
)
