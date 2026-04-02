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

    func testQueuePreflightDraftsSupportsMultipleOwnersByDraftID() {
        let store = AnimateStore()
        let character = AnimationCharacter(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            name: "Amira",
            description: "Lead",
            owpSlug: "amira",
            parts: []
        )
        store.characters = [character]

        let characterItem = Animate3DGenerationQueueItem(
            kind: .faceRig,
            title: "Amira face rig",
            detail: "Generate Amira face rig.",
            destinationPath: "Animate/characters/amira/face-rigs/",
            providerHint: "Gemini",
            prompt: "Generate Amira face rig.",
            characterSlug: "amira",
            characterName: "Amira"
        )
        let pipelineItem = Animate3DGenerationQueueItem(
            kind: .worldPreviewImage,
            title: "Citadel preview",
            detail: "Generate citadel preview.",
            destinationPath: "Animate/3d/world-catalog/citadel.png",
            providerHint: "Nano Banana 2",
            prompt: "Generate citadel preview.",
            characterSlug: nil,
            characterName: "Environment"
        )

        let characterDraft = GeminiGenerationDraft(
            title: characterItem.title,
            destinationDescription: characterItem.destinationDescription,
            prompt: characterItem.prompt,
            contextNote: nil,
            model: .flash,
            aspectRatio: characterItem.draftAspectRatio,
            imageSize: "1K",
            referenceItems: []
        )
        let pipelineDraft = GeminiGenerationDraft(
            title: pipelineItem.title,
            destinationDescription: pipelineItem.destinationDescription,
            prompt: pipelineItem.prompt,
            contextNote: "runtime world: citadel",
            model: .flash,
            aspectRatio: pipelineItem.draftAspectRatio,
            imageSize: "1K",
            referenceItems: []
        )

        let queued = Animate3DGenerationQueueActionSupport.queuePreflightDrafts(
            [characterDraft, pipelineDraft],
            ownersByDraftID: [
                characterDraft.id: Animate3DGenerationQueueActionSupport.PreflightOwner(item: characterItem, store: store),
                pipelineDraft.id: Animate3DGenerationQueueActionSupport.PreflightOwner(item: pipelineItem, store: store)
            ],
            store: store
        )

        XCTAssertEqual(queued, 2)
        XCTAssertEqual(store.batchQueue.count, 2)
        XCTAssertEqual(store.batchQueue.first?.characterID, character.id)
        XCTAssertEqual(store.batchQueue.last?.outputRootRelativePath, "3d/world-catalog/batch-queue-batches")
    }

    func testQueueItemsQueuesVisibleDraftablesThroughSharedHelper() {
        let store = AnimateStore()
        let character = AnimationCharacter(
            id: UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-111111111111")!,
            name: "Mark",
            description: "Soldier",
            owpSlug: "mark",
            parts: []
        )
        store.characters = [character]

        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Mark Scene",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/mark-scene.ows"
        )

        let bodyItem = Animate3DGenerationQueueItem(
            kind: .bodyModel,
            title: "Mark body model",
            detail: "Generate Mark body model.",
            destinationPath: "Animate/characters/mark/models/",
            providerHint: "Meshy",
            prompt: "Generate Mark body model.",
            characterSlug: "mark",
            characterName: "Mark"
        )
        let worldItem = Animate3DGenerationQueueItem(
            kind: .worldPreviewImage,
            title: "Barracks preview",
            detail: "Generate barracks preview.",
            destinationPath: "Animate/3d/world-catalog/barracks.png",
            providerHint: "Nano Banana 2",
            prompt: "Generate barracks preview.",
            characterSlug: nil,
            characterName: "Environment"
        )

        var status = Animate3DProductionStatus.empty
        status.sceneName = "Mark Scene"
        status.generationQueueItems = [bodyItem, worldItem]

        let queued = Animate3DGenerationQueueActionSupport.queue(
            items: [bodyItem, worldItem],
            scene: scene,
            status: status,
            store: store
        )

        XCTAssertEqual(queued, 2)
        XCTAssertEqual(store.batchQueue.count, 2)
        XCTAssertTrue(Animate3DGenerationQueueActionSupport.isQueued(item: bodyItem, store: store))
        XCTAssertTrue(Animate3DGenerationQueueActionSupport.isQueued(item: worldItem, store: store))
    }

    func testPrioritizedItemsPromotesPinnedAndFiltersSkipped() {
        var body = Animate3DGenerationQueueItem(
            kind: .bodyModel,
            title: "Body",
            detail: "Generate body.",
            destinationPath: "Animate/characters/body/",
            providerHint: "Meshy",
            prompt: "Generate body.",
            characterSlug: "body",
            characterName: "Body"
        )
        body.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        var face = Animate3DGenerationQueueItem(
            kind: .faceRig,
            title: "Face",
            detail: "Generate face.",
            destinationPath: "Animate/characters/face/",
            providerHint: "Gemini",
            prompt: "Generate face.",
            contextSummary: "runtime facial: sing, smile",
            characterSlug: "face",
            characterName: "Face"
        )
        face.id = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!

        var world = Animate3DGenerationQueueItem(
            kind: .worldMesh,
            title: "World",
            detail: "Manual world mesh.",
            destinationPath: "Animate/3d/world-catalog/world.glb",
            providerHint: "World Labs",
            prompt: "Generate world.",
            characterSlug: nil,
            characterName: nil
        )
        world.id = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!

        let prioritized = Animate3DGenerationQueueActionSupport.prioritizedItems(
            from: [body, face, world],
            pinnedIDs: [world.id],
            skippedIDs: [body.id]
        )

        XCTAssertEqual(prioritized.map(\.id), [world.id, face.id])
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DQueueActionSupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
