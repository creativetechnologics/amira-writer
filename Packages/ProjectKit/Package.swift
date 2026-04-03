// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProjectKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "ProjectKit",
            targets: ["ProjectKit"]
        ),
        .executable(
            name: "ProjectCLI",
            targets: ["ProjectCLI"]
        ),
        .executable(
            name: "ProjectService",
            targets: ["ProjectService"]
        ),
        .executable(
            name: "ProjectMCP",
            targets: ["ProjectMCP"]
        ),
        .executable(
            name: "ProjectServiceApp",
            targets: ["ProjectServiceApp"]
        ),
        .executable(
            name: "SyncTest",
            targets: ["SyncTest"]
        ),
    ],
    targets: [
        .target(
            name: "ProjectKit",
            path: "Sources/ProjectKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "ProjectCLI",
            dependencies: ["ProjectKit"],
            path: "Sources/ProjectCLI",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "ProjectService",
            dependencies: ["ProjectKit"],
            path: "Sources/ProjectService",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "ProjectMCP",
            dependencies: ["ProjectKit"],
            path: "Sources/ProjectMCP",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "ProjectServiceApp",
            dependencies: ["ProjectKit"],
            path: "Sources/ProjectServiceApp",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "SyncTest",
            dependencies: ["ProjectKit"],
            path: "Sources/SyncTest"
        ),
        .testTarget(
            name: "ProjectKitTests",
            dependencies: ["ProjectKit"],
            path: "Tests/ProjectKitTests"
        ),
    ]
)
