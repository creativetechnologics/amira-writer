import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DAssetGapQueueServiceTests: XCTestCase {
    func testQueueMissingDraftsQueuesCharacterAndPipelineItems() {
        let store = AnimateStore()
        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )
        store.characters = [character]

        var status = Animate3DProductionStatus.empty
        status.sceneName = "Luke Scene"
        status.backgroundName = "Moon Valley"
        status.generationQueueItems = [
            Animate3DGenerationQueueItem(
                kind: .bodyModel,
                title: "Luke 3D body model",
                detail: "Generate Luke's body model.",
                destinationPath: "Animate/characters/luke/models/",
                providerHint: "Meshy",
                prompt: "Generate Luke body model.",
                characterSlug: "luke",
                characterName: "Luke"
            ),
            Animate3DGenerationQueueItem(
                kind: .worldPreviewImage,
                title: "Moon Valley world preview",
                detail: "Generate the valley preview plate.",
                destinationPath: "Animate/3d/world-catalog/",
                providerHint: "Nano Banana 2",
                prompt: "Generate Moon Valley preview.",
                characterSlug: nil,
                characterName: "Environment"
            ),
            Animate3DGenerationQueueItem(
                kind: .lightRig,
                title: "Moon Valley light rig",
                detail: "Manual light rig authoring.",
                destinationPath: "Animate/3d/light-rigs/light-rigs.json",
                providerHint: "In-app registry",
                prompt: "Create a light rig.",
                characterSlug: nil,
                characterName: nil
            )
        ]

        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Luke Scene",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/luke.ows"
        )

        let queued = Animate3DAssetGapQueueService(store: store).queueMissingDrafts(
            scene: scene,
            status: status
        )

        XCTAssertEqual(queued, 2)
        XCTAssertEqual(store.batchQueue.count, 2)

        let characterItem = try? XCTUnwrap(store.batchQueue.first(where: { $0.characterID == character.id }))
        XCTAssertEqual(characterItem?.characterSlug, "luke")
        XCTAssertNil(characterItem?.outputRootRelativePath)

        let pipelineItem = try? XCTUnwrap(store.batchQueue.first(where: { $0.characterID == nil }))
        XCTAssertEqual(pipelineItem?.characterName, "Environment")
        XCTAssertEqual(pipelineItem?.outputRootRelativePath, "3d/world-catalog/batch-queue-batches")
    }

    func testQueueMissingDraftsFallsBackToLegacyWorldConceptPath() {
        let store = AnimateStore()

        var status = Animate3DProductionStatus.empty
        status.sceneName = "Silver"
        status.backgroundName = "Silver Corridor"
        status.worldChunkTitle = nil

        let scene = AnimationScene(
            id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
            name: "Silver",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/silver.ows"
        )

        let queued = Animate3DAssetGapQueueService(store: store).queueMissingDrafts(
            scene: scene,
            status: status
        )

        XCTAssertEqual(queued, 1)
        XCTAssertEqual(store.batchQueue.first?.outputRootRelativePath, "3d/world-catalog/batch-queue-batches")
    }
}
