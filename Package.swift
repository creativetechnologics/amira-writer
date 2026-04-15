// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Opera",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "WriteUI",
            targets: ["WriteUI"]
        ),
        .library(
            name: "MixUI",
            targets: ["MixUI"]
        ),
        .executable(
            name: "Opera",
            targets: ["Opera"]
        )
    ],
    dependencies: [
        .package(path: "./Packages/ProjectKit"),
        .package(path: "./Packages/Score"),
        .package(path: "./Packages/Animate")
    ],
    targets: [
        .target(
            name: "WriteUI",
            dependencies: [
                .product(name: "ProjectKit", package: "ProjectKit")
            ],
            path: "Sources/WriteUI",
            exclude: ["WriteApp.swift"]
        ),
        .target(
            name: "MixUI",
            dependencies: [
                .product(name: "ProjectKit", package: "ProjectKit")
            ],
            path: "Sources/MixUI"
        ),
        .executableTarget(
            name: "Opera",
            dependencies: [
                .product(name: "ProjectKit", package: "ProjectKit"),
                "WriteUI",
                "MixUI",
                .product(name: "ScoreUI", package: "Score"),
                .product(name: "AnimateUI", package: "Animate")
            ],
            path: "Sources/Opera"
        ),
        // .testTarget(
        //     name: "WriteTests",
        //     dependencies: [
        //         "WriteUI",
        //         .product(name: "ProjectKit", package: "ProjectKit")
        //     ],
        //     path: "Tests/WriteTests"
        // ),
        // .testTarget(
        //     name: "MixTests",
        //     dependencies: [
        //         "MixUI",
        //         .product(name: "ProjectKit", package: "ProjectKit")
        //     ],
        //     path: "Tests/MixTests"
        // )
    ]
)
