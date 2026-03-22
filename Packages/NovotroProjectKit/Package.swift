// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NovotroProjectKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "NovotroProjectKit",
            targets: ["NovotroProjectKit"]
        ),
        .executable(
            name: "novotro-project-cli",
            targets: ["novotro-project-cli"]
        ),
        .executable(
            name: "novotro-project-service",
            targets: ["novotro-project-service"]
        ),
        .executable(
            name: "novotro-project-mcp",
            targets: ["novotro-project-mcp"]
        ),
        .executable(
            name: "NovotroProjectServiceApp",
            targets: ["NovotroProjectServiceApp"]
        ),
        .executable(
            name: "novotro-sync-test",
            targets: ["novotro-sync-test"]
        ),
    ],
    targets: [
        .target(
            name: "NovotroProjectKit",
            path: "Sources/NovotroProjectKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "novotro-project-cli",
            dependencies: ["NovotroProjectKit"],
            path: "Sources/novotro-project-cli",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "novotro-project-service",
            dependencies: ["NovotroProjectKit"],
            path: "Sources/novotro-project-service",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "novotro-project-mcp",
            dependencies: ["NovotroProjectKit"],
            path: "Sources/novotro-project-mcp",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "NovotroProjectServiceApp",
            dependencies: ["NovotroProjectKit"],
            path: "Sources/NovotroProjectServiceApp",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "novotro-sync-test",
            dependencies: ["NovotroProjectKit"],
            path: "Sources/novotro-sync-test"
        ),
        .testTarget(
            name: "NovotroProjectKitTests",
            dependencies: ["NovotroProjectKit"],
            path: "Tests/NovotroProjectKitTests"
        ),
    ]
)
