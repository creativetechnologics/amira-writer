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

    func testVisemePresetResolvesCustomTokenKey() {
        let profile = Character3DPerformanceProfile(
            visemePresets: [
                "wide_o": CharacterPerformanceMouthPreset(
                    jawOpen: 0.5,
                    mouthWidth: 0.42,
                    mouthHeight: 0.62,
                    pucker: 0.44,
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
        XCTAssertEqual(resolved?.key, "wide_o")
    }

    func testAvailableVisemesIncludesBaseVisemeToken() {
        let profile = Character3DPerformanceProfile(
            visemePresets: [
                "hero_open": CharacterPerformanceMouthPreset(
                    aliases: [],
                    baseVisemeToken: "o",
                    jawOpen: 0.5,
                    mouthWidth: 0.42,
                    mouthHeight: 0.62,
                    pucker: 0.44,
                    smileBlend: 0
                )
            ]
        )

        XCTAssertEqual(profile.availableVisemes(), [.o])
    }

    func testExpressionEngineRetagsToCanonicalPresetCue() {
        let profile = Character3DPerformanceProfile(
            expressionPresets: [
                "hero_resolve": CharacterPerformanceExpressionPreset(
                    aliases: [],
                    baseCue: "angry",
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

        XCTAssertEqual(state.cue, "hero_resolve")
        XCTAssertLessThan(state.browLift, 0)
    }

    func testExpressionCueResolutionReportsBaseCueProvenance() {
        let profile = Character3DPerformanceProfile(
            expressionPresets: [
                "hero_resolve": CharacterPerformanceExpressionPreset(
                    aliases: ["determined"],
                    baseCue: "angry",
                    browLift: -0.2,
                    browTilt: -0.3,
                    eyeOpen: 0.8,
                    smile: -0.1,
                    headPitch: 0
                )
            ]
        )

        let resolution = profile.expressionCueResolution(for: "determined")
        XCTAssertEqual(resolution?.canonicalCue, "hero_resolve")
        XCTAssertEqual(resolution?.behaviorCue, "angry")
        XCTAssertEqual(resolution?.provenance, "baseCue:angry")
    }

    func testExpressionEngineFallsBackToAvailableNeutralCuePool() {
        let profile = Character3DPerformanceProfile(
            expressionPresets: [
                "hero_neutral": CharacterPerformanceExpressionPreset(
                    aliases: [],
                    baseCue: "neutral",
                    browLift: 0,
                    browTilt: 0,
                    eyeOpen: 1,
                    smile: 0,
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
                ActingBeat(startFrame: 0, endFrame: 12, action: "alarm", intensity: 0.7)
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

        XCTAssertEqual(state.cue, "neutral")
        XCTAssertEqual(profile.expressionCueProvenance(for: "alarm"), "neutralFallback:neutral")
    }

    func testMouthEngineRetagsAndRemapsCanonicalVisemeCue() {
        let profile = Character3DPerformanceProfile(
            visemePresets: [
                "hero_open": CharacterPerformanceMouthPreset(
                    aliases: [],
                    baseVisemeToken: "o",
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

        XCTAssertEqual(state.cue, "hero_open")
        XCTAssertEqual(state.viseme, PrestonBlairViseme.o)
        XCTAssertEqual(profile.visemeCueProvenance(for: state), "baseViseme:o")
    }

    func testMouthEngineSpeechCycleUsesAvailableProfileVisemes() {
        let profile = Character3DPerformanceProfile(
            visemePresets: [
                "wide_o": CharacterPerformanceMouthPreset(
                    jawOpen: 0.6,
                    mouthWidth: 0.5,
                    mouthHeight: 0.7,
                    pucker: 0.4,
                    smileBlend: 0
                ),
                "rest": CharacterPerformanceMouthPreset(
                    jawOpen: 0.02,
                    mouthWidth: 0.4,
                    mouthHeight: 0.08,
                    pucker: 0,
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
            actingBeats: [
                ActingBeat(startFrame: 0, endFrame: 12, action: "speak", intensity: 0.5)
            ],
            lipsyncBeats: [],
            holdStyle: .onTwos
        )

        let firstState = CharacterMouthEngine().state(
            for: "Luke",
            blocking: blocking,
            frame: 0,
            liveCue: nil,
            baseFPS: 24,
            profile: profile
        )
        let secondState = CharacterMouthEngine().state(
            for: "Luke",
            blocking: blocking,
            frame: 2,
            liveCue: nil,
            baseFPS: 24,
            profile: profile
        )

        XCTAssertEqual(firstState.cue, "wide_o")
        XCTAssertEqual(firstState.viseme, .o)
        XCTAssertEqual(secondState.cue, "rest")
        XCTAssertEqual(secondState.viseme, .rest)
    }
}
