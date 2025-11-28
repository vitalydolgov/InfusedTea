// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "InfusedTea",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "InfusedTea",
            targets: ["InfusedTea"]
        ),
    ],
    targets: [
        .target(
            name: "InfusedTea"
        ),
        .testTarget(
            name: "InfusedTeaTests",
            dependencies: ["InfusedTea"]
        ),
    ]
)
