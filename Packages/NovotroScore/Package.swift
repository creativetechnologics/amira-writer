// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NovotroScore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "NovotroScoreUI",
            targets: ["NovotroScoreUI"]
        )
    ],
    dependencies: [
        .package(path: "../NovotroProjectKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", from: "2.30.6")
    ],
    targets: [
        .target(
            name: "NovotroScoreUI",
            dependencies: [
                "NovotroProjectKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/NovotroScore",
            exclude: ["NovotroScoreApp.swift"],
            resources: [
                .copy("Resources/hyph-en-us.pat.txt"),
                .copy("Resources/cmudict.dict"),
                .copy("Resources/mbrola-us1"),
                .copy("Resources/mbrola-us2"),
                .copy("Resources/suno-instrument-prompts.json")
            ]
        ),
        .executableTarget(
            name: "NovotroScore",
            dependencies: ["NovotroScoreUI"],
            path: "Sources/NovotroScore",
            sources: ["NovotroScoreApp.swift"]
        ),
        .executableTarget(
            name: "novotro-score-mcp",
            path: "Sources/NovotroScoreMCP"
        ),
        .testTarget(
            name: "NovotroScoreTests",
            dependencies: ["NovotroScore", "NovotroProjectKit"],
            path: "Tests/NovotroScoreTests"
        ),
    ]
)
