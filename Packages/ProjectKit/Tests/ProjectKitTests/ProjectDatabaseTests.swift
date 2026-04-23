import Darwin
import Foundation
import XCTest
@testable import ProjectKit

final class ProjectDatabaseTests: XCTestCase {
    func testActiveVersionIDInvariantPrefersExplicitActiveVersion() async throws {
        let fixture = try makeFixtureProject()
        let songPath = "Songs/01 Opening.ows"
        let oldVersionID = UUID()
        let newerVersionID = UUID()
        let now = Date()

        try writeSong(
            in: fixture.projectURL,
            relativePath: songPath,
            title: "Opening",
            activeVersionID: oldVersionID,
            versions: [
                SongVersionFixture(
                    id: oldVersionID,
                    label: "Active",
                    lyrics: "Active lyrics",
                    createdAt: now.addingTimeInterval(-300),
                    updatedAt: now.addingTimeInterval(-200),
                    saveType: "manual"
                ),
                SongVersionFixture(
                    id: newerVersionID,
                    label: "Newest",
                    lyrics: "Newest lyrics",
                    createdAt: now.addingTimeInterval(-100),
                    updatedAt: now.addingTimeInterval(-10),
                    saveType: "manual"
                ),
            ]
        )

        let database = ProjectDatabase(projectURL: fixture.projectURL)
        try await database.ensureCurrentIndex()
        let loaded = try await database.loadProject()

        guard let scene = loaded.scenes.first(where: { $0.relativePath == songPath }) else {
            return XCTFail("Expected scene for \(songPath)")
        }

        XCTAssertEqual(scene.activeVersionID, oldVersionID)
        XCTAssertEqual(scene.activeVersion?.id, oldVersionID)
        XCTAssertEqual(scene.activeVersion?.lyrics, "Active lyrics")
    }

    func testAuxiliaryProjectFilesRoundTripForTextAndBinary() async throws {
        let fixture = try makeFixtureProject()
        let songPath = "Songs/01 Opening.ows"
        try writeSong(
            in: fixture.projectURL,
            relativePath: songPath,
            title: "Opening",
            activeVersionID: UUID(),
            versions: [
                SongVersionFixture(
                    id: UUID(),
                    label: "Initial",
                    lyrics: "Initial lyrics",
                    createdAt: Date().addingTimeInterval(-120),
                    updatedAt: Date().addingTimeInterval(-60),
                    saveType: "manual"
                ),
            ]
        )

        let projectSettingsBytes = Data("{\"showDirections\":true}".utf8)
        let tsvBytes = Data("A\tB\tC\n1\t2\t3\n".utf8)
        let sf2Bytes = Data([0x53, 0x46, 0x32, 0x00, 0x01, 0xF1, 0xAA, 0x10])
        let wavBytes = Data([0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])

        let indexedAuxFiles: [(String, Data)] = [
            ("Settings/project-settings.json", projectSettingsBytes),
            ("Metadata/helpers.tsv", tsvBytes),
        ]

        let mediaAuxFiles: [(String, Data)] = [
            ("SoundFonts/sentinel.sf2", sf2Bytes),
            ("Mix/sentinel.wav", wavBytes),
        ]

        for (path, bytes) in indexedAuxFiles + mediaAuxFiles {
            try writeFile(in: fixture.projectURL, relativePath: path, data: bytes)
        }

        let database = ProjectDatabase(projectURL: fixture.projectURL)
        try await database.ensureCurrentIndex()
        let loaded = try await database.loadProject()

        for (path, expected) in indexedAuxFiles {
            let stored = loaded.projectFile(at: path)?.jsonData
            XCTAssertEqual(stored, expected, "Expected DB record for \(path) to match original bytes")
        }

        for (path, expected) in mediaAuxFiles {
            let stored = try await database.loadProjectFile(path: path)
            XCTAssertEqual(stored?.jsonData, expected, "Expected direct DB fallback for \(path)")
        }

        for (path, _) in indexedAuxFiles + mediaAuxFiles {
            try FileManager.default.removeItem(at: fixture.projectURL.appendingPathComponent(path))
        }

        try await database.exportLegacy()

        for (path, expected) in indexedAuxFiles {
            let restored = try Data(contentsOf: fixture.projectURL.appendingPathComponent(path))
            XCTAssertEqual(restored, expected, "Expected exported file \(path) to match original bytes")
        }

        for (path, _) in mediaAuxFiles {
            let restoredPath = fixture.projectURL.appendingPathComponent(path)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: restoredPath.path),
                "Expected media file \(path) to stay as a source-only file after rebuild without inlining"
            )
        }
    }

    func testUpdateSongTextTargetsRequestedVersionID() async throws {
        let fixture = try makeFixtureProject()
        let songPath = "Songs/01 Opening.ows"
        let firstVersion = UUID()
        let secondVersion = UUID()
        let now = Date()

        try writeSong(
            in: fixture.projectURL,
            relativePath: songPath,
            title: "Opening",
            activeVersionID: firstVersion,
            versions: [
                SongVersionFixture(
                    id: firstVersion,
                    label: "First",
                    lyrics: "First lyrics",
                    createdAt: now.addingTimeInterval(-240),
                    updatedAt: now.addingTimeInterval(-120),
                    saveType: "manual"
                ),
                SongVersionFixture(
                    id: secondVersion,
                    label: "Second",
                    lyrics: "Second lyrics",
                    createdAt: now.addingTimeInterval(-180),
                    updatedAt: now.addingTimeInterval(-60),
                    saveType: "manual"
                ),
            ]
        )

        let database = ProjectDatabase(projectURL: fixture.projectURL)
        try await database.ensureCurrentIndex()
        try await database.updateSongText(
            relativePath: songPath,
            lyrics: "Updated second lyrics",
            versionID: secondVersion,
            actorID: "test-actor"
        )

        guard let scene = try await database.loadScene(relativePath: songPath) else {
            return XCTFail("Expected updated scene")
        }

        XCTAssertEqual(scene.activeVersionID, secondVersion)
        XCTAssertEqual(scene.versions.first(where: { $0.id == secondVersion })?.lyrics, "Updated second lyrics")
        XCTAssertEqual(scene.versions.first(where: { $0.id == firstVersion })?.lyrics, "First lyrics")
    }

    func testChangeLogSemanticsForMutationEndpoints() async throws {
        let fixture = try makeFixtureProject()
        let songPath = "Songs/01 Opening.ows"
        let versionID = UUID()
        try writeSong(
            in: fixture.projectURL,
            relativePath: songPath,
            title: "Opening",
            activeVersionID: versionID,
            versions: [
                SongVersionFixture(
                    id: versionID,
                    label: "Initial",
                    lyrics: "Initial lyrics",
                    createdAt: Date().addingTimeInterval(-120),
                    updatedAt: Date().addingTimeInterval(-60),
                    saveType: "manual"
                ),
            ]
        )

        let database = ProjectDatabase(projectURL: fixture.projectURL)
        try await database.ensureCurrentIndex()
        let token = try await database.currentChangeToken()

        try await database.upsertProjectFile(
            path: "Settings/project-settings.json",
            jsonData: Data("{\"showDirections\":false}".utf8),
            actorID: "project-file-actor"
        )
        try await database.updateSongText(
            relativePath: songPath,
            lyrics: "changed lyrics",
            versionID: versionID,
            actorID: "text-actor"
        )
        try await database.updateSongPlayback(
            relativePath: songPath,
            versionID: versionID,
            playbackJSON: Data("{\"notes\":[{\"pitch\":60}],\"lengthTicks\":960}".utf8),
            actorID: "playback-actor"
        )
        try await database.upsertAnimationScene(
            owsPath: songPath,
            jsonData: Data("{\"tracks\":{\"camera\":{\"keyframes\":[{\"at\":0}]}}}".utf8),
            actorID: "animate-actor"
        )

        let changes = try await database.listChanges(since: token)
        XCTAssertEqual(changes.count, 4)
        guard changes.count == 4 else {
            XCTFail("Expected 4 change events, found \(changes.count): \(changes.map { "\($0.entityType):\($0.entityKey):\($0.eventType):\($0.actorID ?? "nil")" })")
            return
        }

        XCTAssertEqual(changes[0].entityType, "project_file")
        XCTAssertEqual(changes[0].entityKey, "Settings/project-settings.json")
        XCTAssertEqual(changes[0].eventType, "upsert")
        XCTAssertEqual(changes[0].actorID, "project-file-actor")

        XCTAssertEqual(changes[1].entityType, "scene")
        XCTAssertEqual(changes[1].entityKey, songPath)
        XCTAssertEqual(changes[1].eventType, "upsert")
        XCTAssertEqual(changes[1].actorID, "text-actor")

        XCTAssertEqual(changes[2].entityType, "scene")
        XCTAssertEqual(changes[2].entityKey, songPath)
        XCTAssertEqual(changes[2].eventType, "upsert")
        XCTAssertEqual(changes[2].actorID, "playback-actor")

        XCTAssertEqual(changes[3].entityType, "scene")
        XCTAssertEqual(changes[3].entityKey, songPath)
        XCTAssertEqual(changes[3].eventType, "upsert")
        XCTAssertEqual(changes[3].actorID, "animate-actor")
    }

    func testShouldPreferRemoteServiceHonorsEnvironmentOverrides() {
        let projectURL = URL(fileURLWithPath: "/tmp/Fixture.owp")
        unsetenv("PROJECT_SERVICE_FORCE")
        unsetenv("PROJECT_SERVICE_DISABLE")
        XCTAssertFalse(ProjectConnection.shouldPreferRemoteService(for: projectURL))

        setenv("PROJECT_SERVICE_FORCE", "1", 1)
        XCTAssertTrue(ProjectConnection.shouldPreferRemoteService(for: projectURL))

        setenv("PROJECT_SERVICE_DISABLE", "1", 1)
        XCTAssertFalse(ProjectConnection.shouldPreferRemoteService(for: projectURL))

        unsetenv("PROJECT_SERVICE_FORCE")
        unsetenv("PROJECT_SERVICE_DISABLE")
    }
}

private struct FixtureProject {
    let rootURL: URL
    let projectURL: URL
}

private struct SongVersionFixture {
    let id: UUID
    let label: String
    let lyrics: String
    let createdAt: Date
    let updatedAt: Date
    let saveType: String
}

private func makeFixtureProject() throws -> FixtureProject {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let root = base
        .appendingPathComponent(".tmp-tests", isDirectory: true)
        .appendingPathComponent("ProjectKitTests-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("Fixture.owp", isDirectory: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent("Songs"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent("Metadata"), withIntermediateDirectories: true)

    let metadata: [String: Any] = [
        "name": "Fixture Project",
        "notes": "fixture",
        "createdAt": isoString(Date().addingTimeInterval(-1000)),
        "updatedAt": isoString(Date().addingTimeInterval(-500)),
    ]
    let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    try writeFile(in: project, relativePath: "Metadata/project.json", data: metadataData)

    return FixtureProject(rootURL: root, projectURL: project)
}

private func writeSong(
    in projectURL: URL,
    relativePath: String,
    title: String,
    activeVersionID: UUID,
    versions: [SongVersionFixture]
) throws {
    let canonicalTitle = title.lowercased()
    let updatedAt = versions.map(\.updatedAt).max() ?? Date()
    let root: [String: Any] = [
        "songID": UUID().uuidString,
        "title": title,
        "canonicalTitle": canonicalTitle,
        "notes": "",
        "updatedAt": isoString(updatedAt),
        "activeVersionID": activeVersionID.uuidString,
        "versions": versions.map { version in
            [
                "id": version.id.uuidString,
                "label": version.label,
                "createdAt": isoString(version.createdAt),
                "updatedAt": isoString(version.updatedAt),
                "lyrics": version.lyrics,
                "saveType": version.saveType,
                "isBookmarked": false,
            ]
        },
    ]

    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try writeFile(in: projectURL, relativePath: relativePath, data: data)
}

private func writeFile(in projectURL: URL, relativePath: String, data: Data) throws {
    let url = projectURL.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
