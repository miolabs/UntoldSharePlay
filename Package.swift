// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UntoldSharePlay",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        // The session, the typed channels, the participants and the host
        // election, the shared frame and the immersive-space coordinator.
        // No engine dependency: a RealityKit game uses this product alone.
        .library(name: "UntoldSharePlay", targets: ["UntoldSharePlay"]),
    ],
    targets: [
        .target(
            name: "UntoldSharePlay",
            path: "Sources/UntoldSharePlay",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "UntoldSharePlayTests",
            dependencies: ["UntoldSharePlay"],
            path: "Tests/UntoldSharePlayTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
