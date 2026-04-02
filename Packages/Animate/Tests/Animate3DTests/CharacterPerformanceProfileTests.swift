import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class CharacterPerformanceProfileTests: XCTestCase {
    func testExpressionPresetResolvesAliasCue() {
        let profile = Character3DPerformanceProfile(
            expressionPresets: [
                "angry": CharacterPerformanceExpressionPreset(
                    browLift: -0.2,
                    browTilt: -0.3,
                    eyeOpen: 0.8,
                    smile: -0.1,
                    headPitch: 0
                )
            ]
        )

        let resolved = profile.resolvedExpressionPreset(for: "determined")
        XCTAssertEqual(resolved?.key, "angry")
    }

    func testVisemePresetResolvesFallbackToken() {
        let profile = Character3DPerformanceProfile(
            visemePresets: [
                "o": CharacterPerformanceMouthPreset(
                    jawOpen: 0.5,
                    mouthWidth: 0.4,
                    mouthHeight: 0.6,
                    pucker: 0.5,
                    smileBlend: 0
                )
            ]
        )

        let state = CharacterMouthState(
            cue: "u",
            viseme: .u,
            jawOpen: 0.4,
            mouthWidth: 0.35,
            mouthHeight: 0.45,
            pucker: 0.7,
            smileBlend: 0
        )

        let resolved = profile.resolvedVisemePreset(for: state)
        XCTAssertEqual(resolved?.key, "o")
    }

    func testExpressionEngineRetagsToCanonicalPresetCue() {
        let profile = Character3DPerformanceProfile(
            expressionPresets: [
                "hero_angry": CharacterPerformanceExpressionPreset(
                    browLift: -0.2,
                    browTilt: -0.3,
                    eyeOpen: 0.8,
                    smile: -0.1,
                    headPitch: 0
                )
            ]
        )
        let blocking = CharacterBlockingPlan(
            characterName: "Luke",
            characterSlug: "luke",
            preferredCostumeName: nil,
            entranceFrame: 0,
            exitFrame: nil,
            keyPositions: [],
            actingBeats: [
                ActingBeat(startFrame: 0, endFrame: 12, action: "determined", intensity: 0.7)
            ],
            lipsyncBeats: [],
            holdStyle: .onTwos
        )

        let state = CharacterExpressionEngine().state(
            for: "Luke",
            blocking: blocking,
            frame: 4,
            liveCue: nil,
            profile: profile
        )

        XCTAssertEqual(state.cue, "hero_angry")
        XCTAssertLessThan(state.browLift, 0)
    }

    func testMouthEngineRetagsAndRemapsCanonicalVisemeCue() {
        let profile = Character3DPerformanceProfile(
            visemePresets: [
                "o": CharacterPerformanceMouthPreset(
                    jawOpen: 0.6,
                    mouthWidth: 0.5,
                    mouthHeight: 0.7,
                    pucker: 0.4,
                    smileBlend: 0
                )
            ]
        )
        let blocking = CharacterBlockingPlan(
            characterName: "Luke",
            characterSlug: "luke",
            preferredCostumeName: nil,
            entranceFrame: 0,
            exitFrame: nil,
            keyPositions: [],
            actingBeats: [],
            lipsyncBeats: [],
            holdStyle: .onTwos
        )

        let state = CharacterMouthEngine().state(
            for: "Luke",
            blocking: blocking,
            frame: 0,
            liveCue: "u",
            baseFPS: 24,
            profile: profile
        )

        XCTAssertEqual(state.cue, "o")
        XCTAssertEqual(state.viseme, PrestonBlairViseme.o)
    }
}
