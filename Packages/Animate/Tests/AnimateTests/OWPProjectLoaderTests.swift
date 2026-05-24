import Foundation
import XCTest
@testable import AnimateUI
import ProjectKit

final class OWPProjectLoaderTests: XCTestCase {
    func testDiscoverScenesUsesPackageIDsAcrossLoads() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: projectURL.appendingPathComponent("Songs", isDirectory: true))

        let overtureID = UUID(uuidString: "C8F37189-2263-4163-A7D1-FA6287F6B9A6")!
        let prologueID = UUID(uuidString: "68C9EC73-3B9F-4C77-BEB0-EAB4CCEB4A7E")!
        try writeScenePackage(
            slug: "1-01-0-overture",
            sceneID: overtureID,
            versionID: UUID(uuidString: "A8F37189-2263-4163-A7D1-FA6287F6B9A6")!,
            title: "1.01.0 - Overture",
            manuscript: "Overture",
            in: projectURL
        )
        try writeScenePackage(
            slug: "1-02-0-prologue",
            sceneID: prologueID,
            versionID: UUID(uuidString: "B8F37189-2263-4163-A7D1-FA6287F6B9A6")!,
            title: "1.02.0 - Prologue",
            manuscript: "Prologue",
            in: projectURL
        )

        let firstLoad = try await OWPProjectLoader().load(from: projectURL)
        let secondLoad = try await OWPProjectLoader().load(from: projectURL)

        XCTAssertEqual(firstLoad.songs.map(\.id), [overtureID, prologueID])
        XCTAssertEqual(secondLoad.songs.map(\.id), [overtureID, prologueID])
        XCTAssertEqual(firstLoad.songs.map(\.id), secondLoad.songs.map(\.id))
    }

    func testDiscoverScenesUsesCanonicalSceneJSONPaths() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: projectURL.appendingPathComponent("Songs", isDirectory: true))

        let sceneID = UUID(uuidString: "C8F37189-2263-4163-A7D1-FA6287F6B9A6")!
        try writeScenePackage(
            slug: "1-01-0-overture",
            sceneID: sceneID,
            versionID: UUID(uuidString: "A8F37189-2263-4163-A7D1-FA6287F6B9A6")!,
            title: "1.01.0 - Overture",
            manuscript: "Overture",
            in: projectURL
        )

        let firstLoad = try await OWPProjectLoader().load(from: projectURL)
        let secondLoad = try await OWPProjectLoader().load(from: projectURL)

        XCTAssertEqual(firstLoad.songs.count, 1)
        XCTAssertEqual(firstLoad.songs.first?.id, sceneID)
        XCTAssertEqual(firstLoad.songs.first?.owsPath, "Scenes/1-01-0-overture/scene.json")
        XCTAssertEqual(firstLoad.songs.first?.id, secondLoad.songs.first?.id)
    }

    func testScenePackagesLoadWhenSongsFolderIsAbsent() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: projectURL.appendingPathComponent("Songs", isDirectory: true))

        let sceneID = UUID(uuidString: "22023608-71f8-49B1-BCEE-C7698CC781D7")!
        let versionID = UUID(uuidString: "CE057D8A-E511-4EA7-8CB1-A448AC9DB2AF")!
        try writeScenePackage(
            slug: "1-03-0-scene-luke-s-notebook",
            sceneID: sceneID,
            versionID: versionID,
            title: "1.03.0 - Scene - Luke's Notebook",
            manuscript: "Luke keeps writing between med crates.",
            in: projectURL
        )

        let load = try await OWPProjectLoader().load(from: projectURL)
        let canonicalPath = "Scenes/1-03-0-scene-luke-s-notebook/scene.json"
        XCTAssertEqual(load.songs.map(\.id), [sceneID])
        XCTAssertEqual(load.songs.map(\.owsPath), [canonicalPath])

        let hydratedSongData = await ProjectDatabaseBridge.hydrateSongData(
            projectURL: projectURL,
            relativePath: canonicalPath
        )
        let songData = try XCTUnwrap(hydratedSongData)
        XCTAssertEqual(songData.lyricsText, "Luke keeps writing between med crates.")
        XCTAssertEqual(songData.notes.count, 1)
        XCTAssertEqual(songData.lengthTicks, 96)
    }

    func testScenePackagesSupplySavedShotsWithoutScenesManifest() throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: projectURL.appendingPathComponent("Songs", isDirectory: true))

        let sceneID = UUID(uuidString: "22023608-71f8-49B1-BCEE-C7698CC781D7")!
        let versionID = UUID(uuidString: "CE057D8A-E511-4EA7-8CB1-A448AC9DB2AF")!
        try writeScenePackage(
            slug: "1-03-0-scene-luke-s-notebook",
            sceneID: sceneID,
            versionID: versionID,
            title: "1.03.0 - Scene - Luke's Notebook",
            manuscript: "Luke keeps writing between med crates.",
            in: projectURL
        )

        let savedScenes = ProjectDatabaseBridge.loadSavedScenesFromDisk(projectURL: projectURL)
        let scene = try XCTUnwrap(savedScenes["Scenes/1-03-0-scene-luke-s-notebook/scene.json"])
        XCTAssertEqual(scene.shots.count, 1)
        XCTAssertEqual(scene.shots.first?.name, "Convoy unload after the prologue")
        XCTAssertEqual(scene.shots.first?.cameraShot, .wide)
        XCTAssertEqual(scene.shots.first?.shotIntent, .establishing)
    }

    func testStoryboardSceneIDMigrationCopiesOldSceneFramesToStableSceneFolder() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Storyboard migration requires macOS 26 APIs")
        }

        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let currentSceneID = UUID(uuidString: "C8F37189-2263-4163-A7D1-FA6287F6B9A6")!
        let oldSceneID = UUID(uuidString: "9DD3183F-1130-4A06-8C9F-32B464CA3ADA")!
        let shotID = UUID(uuidString: "53287F54-358E-5564-AF48-DC329CC8F78F")!
        let sourceURL = ProjectPaths(root: projectURL)
            .shotStoryboardImage(sceneID: oldSceneID, shotID: shotID, frame: .begin)
        let destinationURL = ProjectPaths(root: projectURL)
            .shotStoryboardImage(sceneID: currentSceneID, shotID: shotID, frame: .begin)
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: sourceURL, options: .atomic)

        let scene = AnimationScene(
            id: currentSceneID,
            name: "Overture",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/1.01.0 - Overture.ows",
            shots: [
                AnimationSceneShot(
                    id: shotID,
                    name: "Opening valley",
                    startFrame: 0,
                    endFrame: 48
                )
            ]
        )

        let report = StoryboardSceneIDMigrationService.migrate(
            projectRoot: projectURL,
            scenes: [scene]
        )

        XCTAssertEqual(report.checkedPNGs, 1)
        XCTAssertEqual(report.copied.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: destinationURL), pngData)
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OWPProjectLoaderTests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("Test.owp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("Songs", isDirectory: true),
            withIntermediateDirectories: true
        )
        return projectURL
    }

    private func writeSong(_ path: String, songID: UUID, title: String, in projectURL: URL) throws {
        try writeRawSong(
            path,
            payload: [
                "songID": songID.uuidString,
                "title": title,
                "versions": []
            ],
            in: projectURL
        )
    }

    private func writeRawSong(_ path: String, payload: [String: Any], in projectURL: URL) throws {
        let url = projectURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeScenePackage(
        slug: String,
        sceneID: UUID,
        versionID: UUID,
        title: String,
        manuscript: String,
        in projectURL: URL
    ) throws {
        let scenesURL = projectURL.appendingPathComponent("Scenes", isDirectory: true)
        let sceneURL = scenesURL.appendingPathComponent(slug, isDirectory: true)
        let versionURL = sceneURL
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(versionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: versionURL, withIntermediateDirectories: true)

        let index: [String: Any] = [
            "schemaVersion": 1,
            "projectID": UUID().uuidString,
            "updatedAt": "2026-05-01T00:00:00Z",
            "scenes": [[
                "id": sceneID.uuidString,
                "slug": slug,
                "title": title,
                "order": 1030000,
                "updatedAt": "2026-05-01T00:00:00Z",
            ]],
        ]
        try writeJSON(index, to: scenesURL.appendingPathComponent("scene-index.json"))

        let scene: [String: Any] = [
            "schemaVersion": 1,
            "id": sceneID.uuidString,
            "songID": sceneID.uuidString,
            "slug": slug,
            "canonicalTitle": slug,
            "title": title,
            "notes": "Created during migration.",
            "order": 1030000,
            "activeVersionID": versionID.uuidString.lowercased(),
            "updatedAt": "2026-05-01T00:00:00Z",
            "versionOrder": [versionID.uuidString.lowercased()],
            "versions": [[
                "id": versionID.uuidString.lowercased(),
                "label": "Current Draft",
                "saveType": "imported",
                "createdAt": "2026-05-01T00:00:00Z",
                "updatedAt": "2026-05-01T00:00:00Z",
                "isBookmarked": false,
            ]],
        ]
        try writeJSON(scene, to: sceneURL.appendingPathComponent("scene.json"))
        try Data(manuscript.utf8).write(to: versionURL.appendingPathComponent("manuscript.md"), options: .atomic)
        try writeJSON([
            "schemaVersion": 1,
            "sceneID": sceneID.uuidString,
            "versionID": versionID.uuidString.lowercased(),
            "playback": [
                "ticksPerQuarter": 96,
                "tempoEvents": [["tick": 0, "bpm": 120]],
                "notes": [[
                    "id": UUID().uuidString,
                    "startTick": 0,
                    "duration": 96,
                    "pitch": 60,
                    "velocity": 80,
                    "channel": 0,
                    "trackIndex": 0,
                    "muted": false,
                ]],
                "trackNames": ["0": "Luke"],
                "lyrics": manuscript,
            ],
        ], to: versionURL.appendingPathComponent("score.playback.json"))
        try writeJSON([
            "schemaVersion": 1,
            "sceneID": sceneID.uuidString,
            "shots": [[
                "id": UUID().uuidString,
                "label": "Convoy unload after the prologue",
                "notes": "Opening ridge shot.",
                "camera": [
                    "shotSize": "wide",
                    "intent": "establishing",
                    "label": "Convoy unload after the prologue",
                    "notes": "Opening ridge shot.",
                ],
                "timing": [
                    "startFrame": 10,
                    "endFrame": 42,
                ],
            ]],
        ], to: versionURL.appendingPathComponent("shots.json"))
    }

    private func writeJSON(_ payload: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
