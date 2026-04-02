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
}
