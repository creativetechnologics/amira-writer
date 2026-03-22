import Foundation
import XCTest
import NovotroProjectKit
@testable import NovotroAnimate

@available(macOS 26.0, *)
final class ProjectDatabaseBridgeTests: XCTestCase {
    func testLoadAnimateProjectUsesDatabaseBackedProjectFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let projectURL = try makeProjectPackage(in: rootURL)

        let database = NovotroProjectDatabase(projectURL: projectURL)
        try await database.ensureCurrentIndex()
        let connection = try await NovotroProjectConnection.open(projectURL: projectURL, preferService: false)
        let scenePath = try await database.loadProject().scenes.first?.relativePath ?? "Songs/01 Scene.ows"

        let character = OPWCharacter(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Mara",
            description: "Lead"
        )
        let charactersFile = OPWCharactersFile(characters: [character])
        try await database.upsertProjectFile(
            path: "Characters/characters.json",
            jsonData: try encoded(charactersFile),
            actorID: "test"
        )

        let indexFile = OWPIndexFile(
            cueMappings: [],
            instrumentMappings: [
                OWPInstrumentMapping(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    channelKey: "tr0-ch0",
                    displayName: "Lead Vox",
                    trackRoleRaw: "vocal",
                    colorHex: "#FFAA22"
                )
            ]
        )
        try await database.upsertProjectFile(
            path: "index.json",
            jsonData: try encoded(indexFile),
            actorID: "test"
        )

        let metadata = AnimateMetadata(
            createdDate: Date(timeIntervalSince1970: 10),
            fps: 30,
            resolution: .init(width: 1280, height: 720)
        )
        try await ProjectDatabaseBridge.upsertAnimateMetadata(
            database: connection,
            metadata: metadata
        )

        let scenePayload = AnimateSceneData(
            owsSongPath: scenePath,
            backgroundID: nil,
            characterIDs: [],
            characterSlugs: ["mara"],
            keyframes: [],
            defaultAudioPath: "Assets/dialogue/mara.wav",
            tracks: [:],
            directionTemplate: nil
        )
        try await ProjectDatabaseBridge.upsertAnimationScene(
            database: connection,
            sceneData: scenePayload,
            relativePath: scenePayload.owsSongPath
        )

        let loaded = try await ProjectDatabaseBridge.loadAnimateProject(url: projectURL)

        XCTAssertEqual(loaded.characters.map(\.name), ["Mara"])
        XCTAssertEqual(loaded.animateMetadata?.fps, 30)
        XCTAssertEqual(loaded.indexFile?.instrumentMappings.count, 1)
        XCTAssertEqual(loaded.instrumentMappings.count, 1)
        XCTAssertNotNil(loaded.savedScenes[scenePath])
        XCTAssertEqual(loaded.songs.count, 1)
    }

    func testBridgeRoundTripsAnimateManagedProjectFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let projectURL = try makeProjectPackage(in: rootURL)

        let database = NovotroProjectDatabase(projectURL: projectURL)
        try await database.ensureCurrentIndex()
        let connection = try await NovotroProjectConnection.open(projectURL: projectURL, preferService: false)

        let selectionManifest = CharacterPackageSelectionManifest(
            activePackageIDsByCharacterSlug: [
                "mara": UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            ]
        )
        try await ProjectDatabaseBridge.upsertCharacterPackageSelections(
            database: connection,
            manifest: selectionManifest
        )

        let presetManifest = SceneShotPresetManifest(
            presets: [
                SceneShotPreset(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    name: "Tight Emotional Close-up",
                    notes: "Favor eye-line intensity."
                )
            ]
        )
        try await ProjectDatabaseBridge.upsertShotPresets(
            database: connection,
            manifest: presetManifest
        )

        let scenePayloads = [
            AnimateSceneData(
                owsSongPath: "Songs/01 Scene.ows",
                backgroundID: nil,
                characterIDs: [],
                characterSlugs: ["mara"],
                keyframes: [],
                defaultAudioPath: nil,
                tracks: [:],
                directionTemplate: nil
            )
        ]
        try await ProjectDatabaseBridge.upsertAnimateScenesManifest(
            database: connection,
            sceneData: scenePayloads
        )

        let loadedSelections = try await ProjectDatabaseBridge.loadCharacterPackageSelections(database: connection)
        let loadedPresets = try await ProjectDatabaseBridge.loadShotPresets(database: connection)
        let sceneManifestFile = try await database.loadProjectFile(path: ProjectDatabaseBridge.animateScenesPath)

        XCTAssertEqual(
            loadedSelections?.activePackageIDsByCharacterSlug["mara"],
            selectionManifest.activePackageIDsByCharacterSlug["mara"]
        )
        XCTAssertEqual(loadedPresets?.presets.first?.name, "Tight Emotional Close-up")
        XCTAssertNotNil(sceneManifestFile)
    }

    func testLoadAnimateProjectUsesDiskSongMembershipWhenDatabaseCacheIsStale() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let projectURL = try makeProjectPackage(in: rootURL)

        let database = NovotroProjectDatabase(projectURL: projectURL)
        try await database.ensureCurrentIndex()

        try makeSongFile(at: projectURL.appendingPathComponent("Songs/02 Finale.ows"))

        let loaded = try await ProjectDatabaseBridge.loadAnimateProject(url: projectURL)

        XCTAssertEqual(loaded.songs.map(\.owsPath), ["Songs/01 Scene.ows", "Songs/02 Finale.ows"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeProjectPackage(in rootURL: URL) throws -> URL {
        let projectURL = rootURL.appendingPathComponent("AnimateParity.owp", isDirectory: true)
        let songsURL = projectURL.appendingPathComponent("Songs", isDirectory: true)
        let animateURL = projectURL.appendingPathComponent("Animate", isDirectory: true)
        let charactersURL = projectURL.appendingPathComponent("Characters", isDirectory: true)

        try FileManager.default.createDirectory(at: songsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: animateURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: charactersURL, withIntermediateDirectories: true)

        try makeSongFile(at: songsURL.appendingPathComponent("01 Scene.ows"))
        return projectURL
    }

    private func makeSongFile(at url: URL) throws {
        let versionID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let songID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let now = Date(timeIntervalSince1970: 20)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let root: [String: Any] = [
            "songID": songID.uuidString,
            "title": "Scene",
            "canonicalTitle": "scene",
            "notes": "",
            "updatedAt": iso.string(from: now),
            "activeVersionID": versionID.uuidString,
            "versions": [[
                "id": versionID.uuidString,
                "label": "Base",
                "createdAt": iso.string(from: now),
                "updatedAt": iso.string(from: now),
                "lyrics": "Hello scene",
                "saveType": "manual",
                "isBookmarked": false
            ]]
        ]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
