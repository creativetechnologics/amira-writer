import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class SilverSceneSmokeTests: XCTestCase {
    func testSilverLoadsRenderableSceneFromDisk() async throws {
        let projectURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
        let store = AnimateStore()
        store.disableExternalFileWatch = true

        await store.openOWP(url: projectURL)

        guard let silver = store.scenes.first(where: { $0.owpSongPath == "Songs/1.05.0 - Silver.ows" }) else {
            return XCTFail("Silver scene not loaded")
        }

        store.selectedSceneID = silver.id

        XCTAssertEqual(silver.objectSetups.count, 6)
        XCTAssertEqual(silver.shots.count, 5)
        XCTAssertNotNil(silver.backgroundID)

        let background = store.backgrounds.first(where: { $0.id == silver.backgroundID })
        XCTAssertEqual(background?.approvedImagePath, "Animate/backgrounds/silver-base-corridor-midday.png")
        XCTAssertNotNil(background?.sourceURL)

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
}
