// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZipherX",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "ZipherX",
            targets: ["ZipherX"]
        )
    ],
    dependencies: [
        // SQLCipher for encrypted database
        // .package(url: "https://github.com/nicklockwood/SQLite.swift.git", from: "0.14.1"),
    ],
    targets: [
        .target(
            name: "ZipherX",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "ZipherXTests",
            dependencies: ["ZipherX"],
            path: "Tests"
        )
    ]
)
