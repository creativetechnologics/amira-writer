import Foundation
import XCTest
@testable import AnimateUI
import ProjectKit

final class OWPProjectLoaderTests: XCTestCase {
    func testDiscoverSongsUsesPersistedSongIDsAcrossLoads() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let overtureID = UUID(uuidString: "C8F37189-2263-4163-A7D1-FA6287F6B9A6")!
        let prologueID = UUID(uuidString: "68C9EC73-3B9F-4C77-BEB0-EAB4CCEB4A7E")!
        try writeSong("Songs/1.01.0 - Overture.ows", songID: overtureID, title: "1.01.0 - Overture", in: projectURL)
        try writeSong("Songs/1.02.0 - Prologue.ows", songID: prologueID, title: "1.02.0 - Prologue", in: projectURL)

        let firstLoad = try await OWPProjectLoader().load(from: projectURL)
        let secondLoad = try await OWPProjectLoader().load(from: projectURL)

        XCTAssertEqual(firstLoad.songs.map(\.id), [overtureID, prologueID])
        XCTAssertEqual(secondLoad.songs.map(\.id), [overtureID, prologueID])
        XCTAssertEqual(firstLoad.songs.map(\.id), secondLoad.songs.map(\.id))
    }

    func testDiscoverSongsFallsBackToDeterministicPathIDWhenSongIDIsMissing() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        try writeRawSong(
            "Songs/1.01.0 - Overture.ows",
            payload: [
                "title": "1.01.0 - Overture",
                "versions": []
            ],
            in: projectURL
        )

        let firstLoad = try await OWPProjectLoader().load(from: projectURL)
        let secondLoad = try await OWPProjectLoader().load(from: projectURL)

        XCTAssertEqual(firstLoad.songs.count, 1)
        XCTAssertEqual(firstLoad.songs.first?.id, secondLoad.songs.first?.id)
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
}
