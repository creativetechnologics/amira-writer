import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class Animate3DGenerationOverridePersistenceTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverridePersistenceTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoadRoundTrip() {
        let state = Animate3DGenerationOverridePersistence.PersistedOverrideState(
            pinnedKeys: ["bodyModel|luke", "faceRig|luke"],
            skippedKeys: ["motionSet|amira"],
            draftOverrides: [
                "bodyModel|luke": .init(
                    providerHintOverride: "Use Rodin",
                    promptAppendix: "Anime style eyes",
                    isLocked: true
                )
            ]
        )

        Animate3DGenerationOverridePersistence.save(state, animateURL: tempDir)
        let loaded = Animate3DGenerationOverridePersistence.load(animateURL: tempDir)

        XCTAssertEqual(loaded.pinnedKeys, ["bodyModel|luke", "faceRig|luke"])
        XCTAssertEqual(loaded.skippedKeys, ["motionSet|amira"])
        XCTAssertEqual(loaded.draftOverrides.count, 1)
        XCTAssertEqual(loaded.draftOverrides["bodyModel|luke"]?.providerHintOverride, "Use Rodin")
        XCTAssertEqual(loaded.draftOverrides["bodyModel|luke"]?.promptAppendix, "Anime style eyes")
        XCTAssertTrue(loaded.draftOverrides["bodyModel|luke"]?.isLocked ?? false)
    }

    func testLoadFromMissingFileReturnsEmpty() {
        let loaded = Animate3DGenerationOverridePersistence.load(animateURL: tempDir)
        XCTAssertTrue(loaded.pinnedKeys.isEmpty)
        XCTAssertTrue(loaded.skippedKeys.isEmpty)
        XCTAssertTrue(loaded.draftOverrides.isEmpty)
    }

    func testClearRemovesFile() {
        let state = Animate3DGenerationOverridePersistence.PersistedOverrideState(
            pinnedKeys: ["test"], skippedKeys: [], draftOverrides: [:]
        )
        Animate3DGenerationOverridePersistence.save(state, animateURL: tempDir)

        let fileURL = tempDir.appendingPathComponent("3d/generation-overrides.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        Animate3DGenerationOverridePersistence.clear(animateURL: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEmptyStateConstant() {
        let empty = Animate3DGenerationOverridePersistence.PersistedOverrideState.empty
        XCTAssertTrue(empty.pinnedKeys.isEmpty)
        XCTAssertTrue(empty.skippedKeys.isEmpty)
        XCTAssertTrue(empty.draftOverrides.isEmpty)
    }
}
