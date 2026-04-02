import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DGenerationQueueActionSupportTests: XCTestCase {
    func testPreflightOwnerResolvesCharacterAndPipelineOutputs() throws {
        let store = AnimateStore()
        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )
        store.characters = [character]

        let bodyItem = Animate3DGenerationQueueItem(
            kind: .bodyModel,
            title: "Luke body model",
            detail: "Generate Luke body model.",
            destinationPath: "Animate/characters/luke/models/",
            providerHint: "Meshy",
            prompt: "Generate Luke.",
            characterSlug: "luke",
            characterName: "Luke"
        )
        let bodyOwner = Animate3DGenerationQueueActionSupport.PreflightOwner(item: bodyItem, store: store)
        XCTAssertEqual(bodyOwner.characterID, character.id)
        XCTAssertEqual(bodyOwner.characterSlug, "luke")
        XCTAssertNil(bodyOwner.outputRootRelativePath)

        let worldItem = Animate3DGenerationQueueItem(
            kind: .worldPreviewImage,
            title: "Moon Valley preview",
            detail: "Generate a world preview.",
            destinationPath: "Animate/3d/world-catalog/moon-valley.png",
            providerHint: "Nano Banana 2",
            prompt: "Generate Moon Valley.",
            characterSlug: nil,
            characterName: "Environment"
        )
        let worldOwner = Animate3DGenerationQueueActionSupport.PreflightOwner(item: worldItem, store: store)
        XCTAssertNil(worldOwner.characterID)
        XCTAssertEqual(worldOwner.outputRootRelativePath, "3d/world-catalog/batch-queue-batches")
    }

    func testQueuePreflightDraftsAndManifestEditorContextUseRegistryPaths() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let store = AnimateStore()
        let worldItem = Animate3DGenerationQueueItem(
            kind: .worldPreviewImage,
            title: "Moon Valley preview",
            detail: "Generate a world preview.",
            destinationPath: "Animate/3d/world-catalog/moon-valley.png",
            providerHint: "Nano Banana 2",
            prompt: "Generate Moon Valley.",
            characterSlug: nil,
            characterName: "Environment"
        )
        let owner = Animate3DGenerationQueueActionSupport.PreflightOwner(item: worldItem, store: store)
        let draft = GeminiGenerationDraft(
            title: "Moon Valley preview",
            destinationDescription: "Animate/3d/world-catalog/",
            prompt: "Generate Moon Valley.",
            contextNote: "runtime world: place Moon Valley",
            model: .flash,
            aspectRatio: "16:9",
            imageSize: "1K",
            referenceItems: []
        )

        let queued = Animate3DGenerationQueueActionSupport.queuePreflightDrafts([draft], owner: owner, store: store)
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(store.batchQueue.count, 1)
        XCTAssertEqual(store.batchQueue.first?.outputRootRelativePath, "3d/world-catalog/batch-queue-batches")
        XCTAssertTrue(Animate3DGenerationQueueActionSupport.isQueued(item: worldItem, store: store))

        let manifestItem = Animate3DGenerationQueueItem(
            kind: .worldChunk,
            title: "Moon Valley world chunk",
            detail: "Register a world chunk.",
            destinationPath: "Animate/3d/world-catalog/world-catalog.json",
            providerHint: "In-app registry",
            prompt: "Register the Moon Valley world chunk.",
            characterSlug: nil,
            characterName: nil,
            manifestKind: .worldCatalog
        )
        let context = Animate3DGenerationQueueActionSupport.manifestEditorContext(
            for: manifestItem,
            projectURL: projectURL
        )
        XCTAssertEqual(context?.kind, .worldCatalog)
        XCTAssertEqual(context?.relativePath, Animate3DRegistryIndex().worldCatalogPath)
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DQueueActionSupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
