import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DCharacterAssetServiceTests: XCTestCase {
    func testInventoryScansSidecarFolders() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let animateURL = projectURL.appendingPathComponent("Animate")
        try createFile(
            at: animateURL.appendingPathComponent("characters/luke/models/luke.glb"),
            contents: "model"
        )
        try createFile(
            at: animateURL.appendingPathComponent("characters/luke/face-rigs/face.json"),
            contents: "{}"
        )
        try createFile(
            at: animateURL.appendingPathComponent("characters/luke/mouth-profiles/mouth.json"),
            contents: "{}"
        )
        try createFile(
            at: animateURL.appendingPathComponent("characters/luke/expressions/expressions.json"),
            contents: "{}"
        )
        try createFile(
            at: animateURL.appendingPathComponent("characters/luke/motions/walk.json"),
            contents: "{}"
        )
        try createFile(
            at: animateURL.appendingPathComponent("characters/luke/materials/materials.json"),
            contents: "{}"
        )

        let inventory = Animate3DCharacterAssetService().inventory(
            for: "luke",
            in: animateURL
        )

        XCTAssertEqual(inventory.files(for: .models).count, 1)
        XCTAssertEqual(inventory.files(for: .faceRigs).count, 1)
        XCTAssertEqual(inventory.files(for: .mouthProfiles).count, 1)
        XCTAssertEqual(inventory.files(for: .expressions).count, 1)
        XCTAssertEqual(inventory.files(for: .motions).count, 1)
        XCTAssertEqual(inventory.files(for: .materials).count, 1)
        XCTAssertEqual(inventory.totalFileCount, 6)
    }

    func testImportAndRemoveSidecarFilesRoundTrip() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let animateURL = projectURL.appendingPathComponent("Animate")
        let sourceURL = projectURL.appendingPathComponent("source.glb")
        try Data("glb".utf8).write(to: sourceURL)

        let imported = try Animate3DCharacterAssetService().importFiles(
            for: "luke",
            category: .models,
            from: [sourceURL],
            in: animateURL
        )

        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported[0].path))

        try Animate3DCharacterAssetService().removeFile(
            for: "luke",
            category: .models,
            relativePath: imported[0].lastPathComponent,
            in: animateURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: imported[0].path))
    }

    private func makeProjectURL() throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return tempURL
    }

    private func createFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}
