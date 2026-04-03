// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Amira3DEngine",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "Amira3DEngine",
            targets: ["Amira3DEngine"]
        )
    ],
    targets: [
        .target(
            name: "Amira3DEngine",
            path: "Sources/Amira3DEngine"
        ),
        .testTarget(
            name: "Amira3DEngineTests",
            dependencies: ["Amira3DEngine"],
            path: "Tests/Amira3DEngineTests"
        )
    ]
)
