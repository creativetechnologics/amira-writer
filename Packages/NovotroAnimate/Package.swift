// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NovotroAnimate",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "NovotroAnimateUI",
            targets: ["NovotroAnimateUI"]
        )
    ],
    dependencies: [
        .package(path: "../NovotroProjectKit")
    ],
    targets: [
        .target(
            name: "NovotroAnimateUI",
            dependencies: ["NovotroProjectKit"],
            path: "Sources/NovotroAnimate",
            exclude: ["NovotroAnimateApp.swift"]
        ),
        .executableTarget(
            name: "NovotroAnimate",
            dependencies: ["NovotroAnimateUI"],
            path: "Sources/NovotroAnimate",
            sources: ["NovotroAnimateApp.swift"]
        ),
        .testTarget(
            name: "NovotroAnimateTests",
            dependencies: ["NovotroAnimate", "NovotroProjectKit"],
            path: "Tests/NovotroAnimateTests"
        )
    ]
)
