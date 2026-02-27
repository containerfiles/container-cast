// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "container-cast",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.26.3"),
    ],
    targets: [
        .executableTarget(
            name: "container-cast",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
            ]
        ),
        .executableTarget(
            name: "container-cast-runner",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        ),
        .testTarget(
            name: "container-castTests",
            dependencies: ["container-cast"]
        ),
    ]
)
