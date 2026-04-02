import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DProductionCoordinatorTests: XCTestCase {
    func testRefreshReloadsWhenCharacterRegistryChanges() async throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Luke Scene",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/luke.ows"
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        store.characters = [character]
        store.scenes = [scene]

        let coordinator = Animate3DProductionCoordinator(store: store)
        await coordinator.refresh(
            scene: scene,
            lyrics: "",
            scenario: .empty,
            forceReload: true
        )
        XCTAssertEqual(coordinator.status.modelBackedCharacterCount, 0)

        let bodyPath = "Animate/3d/generated-assets/luke/default/luke.glb"
        try createDataFile(Data(), at: projectURL.appendingPathComponent(bodyPath))
        try ProjectDatabaseBridge.saveAnimate3DCharacterRegistryToDisk(
            Animate3DCharacterRegistry(
                bundles: [
                    Animate3DCharacterBundleDescriptor(
                        characterSlug: "luke",
                        costumeName: "default",
                        bodyModelPath: bodyPath
                    )
                ]
            ),
            projectURL: projectURL
        )

        await coordinator.refresh(
            scene: scene,
            lyrics: "",
            scenario: .empty,
            forceReload: false
        )
        XCTAssertEqual(coordinator.status.modelBackedCharacterCount, 1)
        let readiness = try XCTUnwrap(coordinator.status.bundleReadiness.first)
        XCTAssertEqual(readiness.resolvedBundleSourcePath, "Animate/3d/character-registry/character-registry.json")
        XCTAssertTrue(readiness.resolvedBundleAssetPaths.contains(bodyPath))
        let runtimeStatus = try XCTUnwrap(coordinator.status.runtimeCharacters.first)
        XCTAssertEqual(runtimeStatus.modelSourcePath, bodyPath)
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DProductionCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDataFile(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
