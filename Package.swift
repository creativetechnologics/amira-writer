// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NovotroOpera",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "NovotroWriteUI",
            targets: ["NovotroWriteUI"]
        )
    ],
    dependencies: [
        .package(path: "./Packages/NovotroProjectKit"),
        .package(path: "./Packages/NovotroScore"),
        .package(path: "./Packages/NovotroAnimate")
    ],
    targets: [
        .target(
            name: "NovotroWriteUI",
            dependencies: ["NovotroProjectKit"],
            path: "Sources/NovotroWrite",
            exclude: ["NovotroWriteApp.swift"]
        ),
        .executableTarget(
            name: "NovotroOpera",
            dependencies: [
                "NovotroProjectKit",
                "NovotroWriteUI",
                .product(name: "NovotroScoreUI", package: "NovotroScore"),
                .product(name: "NovotroAnimateUI", package: "NovotroAnimate")
            ],
            path: "Sources/NovotroOpera"
        ),
        .testTarget(
            name: "NovotroWriteTests",
            dependencies: ["NovotroWriteUI", "NovotroProjectKit"],
            path: "Tests/NovotroWriteTests"
        )
    ]
)
