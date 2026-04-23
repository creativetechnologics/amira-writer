import Foundation
import ProjectKit
import Testing
@testable import ScoreUI

@Suite("Project Database Bridge")
struct ProjectDatabaseBridgeTests {
    @Test func loadScoreProjectUsesCanonicalDatabaseProjectFiles() async throws {
        let projectURL = try makeProjectPackage()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let database = ProjectDatabase(projectURL: projectURL)
        try await database.ensureCurrentIndex()
        let canonicalMetadata = ProjectMetadata(
            name: "Canonical Metadata",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            notes: "from metadata path"
        )
        let legacyMetadata = ProjectMetadata(
            name: "Legacy Metadata",
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40),
            notes: "from legacy path"
        )

        try await database.upsertProjectFile(
            path: ProjectDatabaseBridge.metadataPath,
            jsonData: try metadataData(canonicalMetadata),
            actorID: "test"
        )
        try await database.upsertProjectFile(
            path: ProjectDatabaseBridge.legacyMetadataPath,
            jsonData: try metadataData(legacyMetadata),
            actorID: "test"
        )

        let dbMappings: [String: InstrumentMapping] = [
            "db-track": InstrumentMapping(
                channelKey: "db-track",
                displayName: "DB Track",
                trackRole: .instrument,
                sf2Path: "SoundFonts/db.sf2"
            )
        ]
        try await database.upsertProjectFile(
            path: ProjectDatabaseBridge.projectInstrumentsPath,
            jsonData: try metadataEncoder().encode(dbMappings),
            actorID: "test"
        )

        let loaded = try await ProjectDatabaseBridge.loadScoreProject(url: projectURL)
        #expect(loaded.metadata.name == "Canonical Metadata")
        #expect(loaded.projectInstrumentMappings["db-track"]?.displayName == "DB Track")
        #expect(loaded.projectInstrumentMappings["disk-track"] == nil)
    }

    @Test func projectFileUpsertsSynchronizeCanonicalMetadataAndInstrumentPaths() async throws {
        let projectURL = try makeProjectPackage()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let database = ProjectDatabase(projectURL: projectURL)
        try await database.ensureCurrentIndex()
        let connection = try await ProjectConnection.open(projectURL: projectURL, preferService: false)

        let metadata = ProjectMetadata(
            name: "Synced Name",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            notes: "Synced Notes"
        )
        let mappings: [String: InstrumentMapping] = [
            "strings": InstrumentMapping(
                channelKey: "strings",
                displayName: "Strings",
                trackRole: .instrument,
                sf2Path: "SoundFonts/strings.sf2"
            )
        ]

        try await connection.upsertProjectFile(
            path: ProjectDatabaseBridge.metadataPath,
            jsonData: try metadataData(metadata),
            actorID: "test"
        )
        try await connection.upsertProjectFile(
            path: ProjectDatabaseBridge.projectInstrumentsPath,
            jsonData: try metadataEncoder().encode(mappings),
            actorID: "test"
        )

        let loadedMetadataFile = try await connection.loadProjectFile(path: ProjectDatabaseBridge.metadataPath)
        let loadedMappingsFile = try await connection.loadProjectFile(path: ProjectDatabaseBridge.projectInstrumentsPath)
        let changes = try await database.listChanges(since: 0)

        let loadedMetadata = try #require(loadedMetadataFile).jsonData
        let loadedMappings = try #require(loadedMappingsFile).jsonData
        let decodedMetadata = try ProjectDatabaseBridge.configuredDecoder().decode(ProjectMetadata.self, from: loadedMetadata)
        let decodedMappings = try ProjectDatabaseBridge.configuredDecoder().decode([String: InstrumentMapping].self, from: loadedMappings)

        #expect(decodedMetadata.name == "Synced Name")
        #expect(decodedMetadata.notes == "Synced Notes")
        #expect(decodedMappings["strings"]?.displayName == "Strings")
        #expect(changes.contains(where: { $0.entityType == "project_file" && $0.entityKey == ProjectDatabaseBridge.metadataPath }))
        #expect(changes.contains(where: { $0.entityType == "project_file" && $0.entityKey == ProjectDatabaseBridge.projectInstrumentsPath }))
    }

    @Test func loadScoreProjectUsesDiskSongMembershipWhenDatabaseSummaryIsStale() async throws {
        let projectURL = try makeProjectPackage()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let database = ProjectDatabase(projectURL: projectURL)
        try await database.ensureCurrentIndex()

        let songsURL = projectURL.appendingPathComponent("Songs", isDirectory: true)
        let now = isoFormatter().string(from: Date(timeIntervalSince1970: 15))
        let versionID = UUID()
        let songObject: [String: Any] = [
            "songID": UUID().uuidString,
            "title": "Finale",
            "canonicalTitle": "finale",
            "notes": "",
            "updatedAt": now,
            "activeVersionID": versionID.uuidString,
            "versions": [[
                "id": versionID.uuidString,
                "label": "Version 1",
                "createdAt": now,
                "updatedAt": now,
                "lyrics": "Goodbye",
                "saveType": "manual",
                "isBookmarked": false,
            ]],
        ]
        let songData = try JSONSerialization.data(withJSONObject: songObject, options: [.prettyPrinted, .sortedKeys])
        try songData.write(to: songsURL.appendingPathComponent("02 Finale.ows"), options: .atomic)

        let loaded = try await ProjectDatabaseBridge.loadScoreProject(url: projectURL)

        #expect(loaded.stubs.map(\.relativePath) == ["Songs/01 Opening.ows", "Songs/02 Finale.ows"])
        #expect(loaded.songAssets.map(\.relativePath) == ["Songs/01 Opening.ows", "Songs/02 Finale.ows"])
        #expect(loaded.librettoFiles.map(\.relativePath) == ["Songs/01 Opening.ows", "Songs/02 Finale.ows"])
    }

    @Test func loadScoreProjectPrefersCanonicalSceneTitleForDisplayName() async throws {
        let projectURL = try makeProjectPackage()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let connection = try await ProjectConnection.open(projectURL: projectURL, preferService: false)
        try await connection.ensureCurrentIndex()

        let existingScene = try await connection.loadScene(relativePath: "Songs/01 Opening.ows")
        var scene = try #require(existingScene)
        scene.title = "Opening Reprise"
        scene.canonicalTitle = "opening reprise"
        scene.updatedAt = Date(timeIntervalSince1970: 25)
        try await connection.upsertScene(scene, actorID: "test")

        let loaded = try await ProjectDatabaseBridge.loadScoreProject(url: projectURL)

        #expect(loaded.songAssets.first?.displayName == "Opening Reprise")
    }
}

private func makeProjectPackage() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectURL = root.appendingPathComponent("BridgeTest.owp", isDirectory: true)
    let songsURL = projectURL.appendingPathComponent("Songs", isDirectory: true)
    let metadataURL = projectURL.appendingPathComponent("Metadata", isDirectory: true)
    let settingsURL = projectURL.appendingPathComponent("Settings", isDirectory: true)
    try fm.createDirectory(at: songsURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: metadataURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: settingsURL, withIntermediateDirectories: true)

    let diskMetadata = ProjectMetadata(
        name: "Disk Metadata",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        notes: "disk"
    )
    try metadataData(diskMetadata).write(
        to: projectURL.appendingPathComponent(OWPProjectIO.projectMetadataFile),
        options: .atomic
    )

    let diskMappings: [String: InstrumentMapping] = [
        "disk-track": InstrumentMapping(
            channelKey: "disk-track",
            displayName: "Disk Track",
            trackRole: .instrument,
            sf2Path: "SoundFonts/disk.sf2"
        )
    ]
    try metadataEncoder().encode(diskMappings.values.sorted(by: { $0.channelKey < $1.channelKey })).write(
        to: projectURL.appendingPathComponent(OWPProjectIO.projectInstrumentsFile),
        options: .atomic
    )

    let now = isoFormatter().string(from: Date(timeIntervalSince1970: 5))
    let songVersionID = UUID()
    let songObject: [String: Any] = [
        "songID": UUID().uuidString,
        "title": "Opening",
        "canonicalTitle": "opening",
        "notes": "",
        "updatedAt": now,
        "activeVersionID": songVersionID.uuidString,
        "versions": [[
            "id": songVersionID.uuidString,
            "label": "Version 1",
            "createdAt": now,
            "updatedAt": now,
            "lyrics": "Hello",
            "saveType": "manual",
            "isBookmarked": false,
        ]],
    ]
    let songData = try JSONSerialization.data(withJSONObject: songObject, options: [.prettyPrinted, .sortedKeys])
    try songData.write(to: songsURL.appendingPathComponent("01 Opening.ows"), options: .atomic)

    return projectURL
}

private func metadataData(_ metadata: ProjectMetadata) throws -> Data {
    try metadataEncoder().encode(metadata)
}

private func metadataEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func isoFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}
