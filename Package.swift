// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Queryable",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "Queryable",
            targets: ["Queryable"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "Queryable",
            dependencies: []
        ),
        .testTarget(
            name: "QueryableTests",
            dependencies: ["Queryable"]
        )
    ]
)
