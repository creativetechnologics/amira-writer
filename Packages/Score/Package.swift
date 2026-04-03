// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Score",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ScoreUI",
            targets: ["ScoreUI"]
        ),
        .executable(
            name: "Score",
            targets: ["Score"]
        )
    ],
    dependencies: [
        .package(path: "../ProjectKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", from: "2.30.6")
    ],
    targets: [
        .target(
            name: "ScoreUI",
            dependencies: [
                .product(name: "ProjectKit", package: "ProjectKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/ScoreUI",
            resources: [
                .copy("Resources/hyph-en-us.pat.txt"),
                .copy("Resources/cmudict.dict"),
                .copy("Resources/mbrola-us1"),
                .copy("Resources/mbrola-us2"),
                .copy("Resources/suno-instrument-prompts.json")
            ]
        ),
        .executableTarget(
            name: "Score",
            dependencies: ["ScoreUI"],
            path: "Sources/Score",
            sources: ["ScoreMain.swift"]
        ),
        .executableTarget(
            name: "ScoreMCP",
            path: "Sources/ScoreMCP"
        ),
        .testTarget(
            name: "ScoreTests",
            dependencies: [
                "ScoreUI",
                .product(name: "ProjectKit", package: "ProjectKit")
            ],
            path: "Tests/ScoreTests"
        ),
    ]
)
