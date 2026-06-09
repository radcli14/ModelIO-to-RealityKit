// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ModelIO-to-RealityKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15), // Monterey
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ModelIO-to-RealityKit",
            targets: ["ModelIO-to-RealityKit"]
        ),
    ],
    dependencies: [
        // Test-only: GLB loading for round-trip tests. Not exposed to library consumers.
        .package(url: "https://github.com/warrenm/GLTFKit2", from: "0.5.15"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ModelIO-to-RealityKit"
        ),
        .testTarget(
            name: "ModelIO-to-RealityKitTests",
            dependencies: [
                "ModelIO-to-RealityKit",
                .product(name: "GLTFKit2", package: "GLTFKit2"),
            ],
            resources: [
                .process("xyzBlock.obj"),
                .process("xyzBlock.mtl"),
                .process("Diffuse.png"),
                .process("normal.png"),
                .process("roughness.png"),
                .process("left_hand.usdz"),
            ]
        ),
    ]
)
