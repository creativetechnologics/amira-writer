import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class SceneProductionCompilerTests: XCTestCase {
    func testCompilerCarriesBackgroundAndLipsyncBeats() {
        let input = SceneProductionInput(
            sceneName: "Silver Corridor",
            sceneID: UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!,
            lyrics: "",
            directions: [
                SceneDirection(
                    tag: .enter,
                    primaryValue: "Mark",
                    parameters: ["position": "center_left", "bars": "1-2"]
                ),
                SceneDirection(
                    tag: .lipsync,
                    primaryValue: "Mark",
                    parameters: ["mode": "singing", "song": "silver", "bars": "3-4"]
                )
            ],
            shots: [],
            characterSlugs: ["mark"],
            objectSetups: [],
            backgroundName: "Silver Corridor Plate",
            baseFPS: 24,
            totalBeats: 16,
            bpm: 120
        )

        let plan = SceneProductionCompiler.compile(input)

        XCTAssertEqual(plan.backgroundName, "Silver Corridor Plate")
        XCTAssertEqual(plan.characterBlocking.count, 1)
        XCTAssertEqual(plan.characterBlocking[0].lipsyncBeats.count, 1)
        XCTAssertEqual(plan.characterBlocking[0].lipsyncBeats[0].mode, "singing")
        XCTAssertEqual(plan.characterBlocking[0].lipsyncBeats[0].songName, "silver")
    }

    func testCompilerResolvesDisplayNameToCanonicalSlugAndCostume() {
        let input = SceneProductionInput(
            sceneName: "Silver Corridor",
            sceneID: UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!,
            lyrics: "",
            directions: [
                SceneDirection(
                    tag: .enter,
                    primaryValue: "Mark Price",
                    parameters: ["position": "center_left", "bars": "1-2"]
                )
            ],
            shots: [],
            characterSlugs: ["mark-price"],
            characterCast: [
                SceneProductionCharacterInput(
                    name: "Mark Price",
                    slug: "mark-price",
                    preferredCostumeName: "Dress Uniform"
                )
            ],
            objectSetups: [],
            backgroundName: "Silver Corridor Plate",
            baseFPS: 24,
            totalBeats: 16,
            bpm: 120
        )

        let plan = SceneProductionCompiler.compile(input)

        XCTAssertEqual(plan.characterBlocking.count, 1)
        XCTAssertEqual(plan.characterBlocking[0].characterName, "Mark Price")
        XCTAssertEqual(plan.characterBlocking[0].characterSlug, "mark-price")
        XCTAssertEqual(plan.characterBlocking[0].preferredCostumeName, "Dress Uniform")
    }

    func testMouthEnginePrefersLiveVisemeCue() {
        let blocking = CharacterBlockingPlan(
            characterName: "Mark",
            characterSlug: "mark",
            preferredCostumeName: nil,
            entranceFrame: 0,
            exitFrame: nil,
            keyPositions: [
                BlockingKeyframe(
                    frame: 0,
                    position: SIMD3<Double>(0, 0, -3),
                    facing: .camera,
                    pose: "standing",
                    emotion: "neutral",
                    easing: .linear
                )
            ],
            actingBeats: [],
            lipsyncBeats: [CharacterLipsyncBeat(startFrame: 0, endFrame: 20, mode: "speech", songName: nil)],
            holdStyle: .onTwos
        )

        let state = CharacterMouthEngine().state(
            for: "Mark",
            blocking: blocking,
            frame: 8,
            liveCue: "viseme:mbp",
            baseFPS: 24
        )

        XCTAssertEqual(state.viseme, .mbp)
        XCTAssertEqual(state.cue, "mbp")
    }
}
