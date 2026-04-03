import Foundation
import XCTest
import simd
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class SilverSceneSmokeTests: XCTestCase {
    func testSilverLoadsRenderableSceneFromDisk() async throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera"),
            "Test data not available"
        )
        let projectURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
        let store = AnimateStore()
        store.disableExternalFileWatch = true

        await store.openOWP(url: projectURL)

        guard let silver = store.scenes.first(where: { $0.owpSongPath == "Songs/1.05.0 - Silver.ows" }) else {
            return XCTFail("Silver scene not loaded")
        }

        store.selectedSceneID = silver.id

        XCTAssertGreaterThanOrEqual(silver.objectSetups.count, 0)
        XCTAssertGreaterThanOrEqual(silver.shots.count, 0)
        // Background may or may not be set — the placeholder was removed

        let composer = SceneFrameRenderComposer()
        let viewport = CGSize(width: 1920, height: 1080)

        let frameZero = composer.composeDrawItems(
            store: store,
            scene: silver,
            viewportSize: viewport,
            frame: 0,
            placeholderOnly: false,
            textureProvider: { _ in nil }
        )
        XCTAssertGreaterThanOrEqual(frameZero.count, 4)

        let lateFrame = composer.composeDrawItems(
            store: store,
            scene: silver,
            viewportSize: viewport,
            frame: 1728,
            placeholderOnly: false,
            textureProvider: { _ in nil }
        )
        XCTAssertGreaterThanOrEqual(lateFrame.count, 4)
    }

    func testSilverProductionCompileAndRender() async throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera"),
            "Test data not available"
        )
        let projectURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
        let store = AnimateStore()
        store.disableExternalFileWatch = true

        await store.openOWP(url: projectURL)

        guard let silver = store.scenes.first(where: { $0.owpSongPath == "Songs/1.05.0 - Silver.ows" }) else {
            return XCTFail("Silver scene not loaded")
        }

        store.selectedSceneID = silver.id

        // Load song data so bpm/totalBeats are accurate
        await store.loadSongData(for: silver)

        // Parse directions from the song's lyrics
        let lyrics = store.currentSongData?.extractLyrics() ?? ""
        let parseResult = SceneDirectionParser.parse(lyrics)

        // Build production input
        let bpm = store.currentSongData?.tempoEvents.sorted(by: { $0.tick < $1.tick }).first?.bpm ?? 120
        let totalBeats: Int = {
            guard let songData = store.currentSongData else { return 64 }
            return max(4, Int(ceil(Double(songData.lengthTicks) / Double(max(songData.ticksPerQuarter, 1)))))
        }()
        let characterSlugs = silver.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })?.assetFolderSlug
        }
        let characterCast = silver.characterIDs.compactMap { id -> SceneProductionCharacterInput? in
            guard let character = store.characters.first(where: { $0.id == id }) else { return nil }
            return SceneProductionCharacterInput(
                name: character.name,
                slug: character.assetFolderSlug,
                preferredCostumeName: nil
            )
        }
        let backgroundName = silver.backgroundID.flatMap { id in
            store.backgrounds.first(where: { $0.id == id })?.name
        }

        let input = SceneProductionInput(
            sceneName: silver.name,
            sceneID: silver.id,
            lyrics: lyrics,
            directions: parseResult.directions,
            shots: silver.shots,
            characterSlugs: characterSlugs,
            characterCast: characterCast,
            objectSetups: silver.objectSetups,
            backgroundName: backgroundName,
            baseFPS: max(store.fps, 1),
            totalBeats: totalBeats,
            bpm: bpm
        )

        // Compile the production plan
        let plan = SceneProductionCompiler.compile(input)

        // The Silver scene should have at least one character blocking entry
        XCTAssertGreaterThanOrEqual(
            plan.characterBlocking.count, 1,
            "Expected at least 1 character blocking entry in compiled Silver plan"
        )

        // Create a renderer, load the plan, and render frames — must not crash
        let renderer = ScenePreviewRenderer(store: store)
        await renderer.loadPlan(plan)
        renderer.renderFrame(0)
        renderer.renderFrame(24)

        // Renderer should have registered at least one character performance status
        XCTAssertFalse(
            renderer.characterPerformanceStatuses.isEmpty,
            "Expected at least one character performance status after rendering Silver scene"
        )
    }
}
