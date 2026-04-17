// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Animate",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "AnimateUI",
            targets: ["AnimateUI"]
        ),
        .executable(
            name: "Animate",
            targets: ["Animate"]
        )
    ],
    dependencies: [
        .package(path: "../ProjectKit")
    ],
    targets: [
        .target(
            name: "AnimateUI",
            dependencies: [
                .product(name: "ProjectKit", package: "ProjectKit")
            ],
            path: "Sources/AnimateUI",
            exclude: ["_archived_3d"],
            resources: [
                .copy("Resources/Models3D"),
                .copy("Resources/gemini_inspiration_batch.py")
            ]
        ),
        .executableTarget(
            name: "Animate",
            dependencies: ["AnimateUI"],
            path: "Sources/Animate",
            sources: ["AnimateMain.swift"]
        ),
        .testTarget(
            name: "AnimateTests",
            dependencies: [
                "AnimateUI",
                .product(name: "ProjectKit", package: "ProjectKit")
            ],
            path: "Tests/AnimateTests"
        ),
        .testTarget(
            name: "Animate3DTests",
            dependencies: [
                "AnimateUI"
            ],
            path: "Tests/Animate3DTests"
        )
    ]
)
