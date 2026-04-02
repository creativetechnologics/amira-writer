import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class EmotionLibraryTests: XCTestCase {

    func testResolveExactID() {
        let preset = EmotionLibrary.resolve("joy")
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.id, "joy")
    }

    func testResolveAlias() {
        let preset = EmotionLibrary.resolve("happy")
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.id, "joy")
    }

    func testResolveSubstring() {
        let preset = EmotionLibrary.resolve("very happy")
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.id, "joy")
    }

    func testResolveUnknownReturnsNil() {
        XCTAssertNil(EmotionLibrary.resolve("xyzzy"))
    }

    func testAllCategoriesHavePresets() {
        for category in EmotionLibrary.EmotionCategory.allCases {
            let count = EmotionLibrary.presets(in: category).count
            XCTAssertGreaterThan(count, 0, "Category \(category) has no presets")
        }
    }

    func testBlendMidpoint() {
        let blended = EmotionLibrary.blend("joy", "sad", ratio: 0.5)
        XCTAssertNotNil(blended)
        guard let b = blended else { return }

        let joy = EmotionLibrary.resolve("joy")!
        let sad = EmotionLibrary.resolve("sad")!

        XCTAssertEqual(b.browLift, (joy.browLift + sad.browLift) / 2, accuracy: 0.001)
        XCTAssertEqual(b.smile, (joy.smile + sad.smile) / 2, accuracy: 0.001)
    }

    func testTransitionGeneratesCorrectFrameCount() {
        let from = EmotionLibrary.resolve("neutral")!
        let to = EmotionLibrary.resolve("joy")!
        let frames = EmotionLibrary.transition(from: from, to: to, frameCount: 10)
        XCTAssertEqual(frames.count, 10)
    }

    func testTransitionStartAndEnd() {
        let from = EmotionLibrary.resolve("neutral")!
        let to = EmotionLibrary.resolve("angry")!
        let frames = EmotionLibrary.transition(from: from, to: to, frameCount: 20)

        XCTAssertEqual(frames.first?.browLift ?? 999, from.browLift, accuracy: 0.001)
        XCTAssertEqual(frames.last?.browLift ?? 999, to.browLift, accuracy: 0.001)
    }

    func testIntensityZeroIsNeutral() {
        let joy = EmotionLibrary.resolve("joy")!
        let zeroed = joy.withIntensity(0)
        XCTAssertEqual(zeroed.browLift, 0, accuracy: 0.001)
        XCTAssertEqual(zeroed.smile, 0, accuracy: 0.001)
        XCTAssertEqual(zeroed.eyeOpen, 1.0, accuracy: 0.001) // eyeOpen neutral = 1.0
    }

    func testMicroExpressionPeakAndFade() {
        let preset = EmotionLibrary.resolve("surprised")!
        let frames = EmotionLibrary.microExpression(preset: preset, durationFrames: 10, peakIntensity: 0.8)
        XCTAssertEqual(frames.count, 10)

        // Frame 0 should have low intensity
        XCTAssertLessThan(abs(frames[0].browLift), abs(preset.browLift))
        // Last frame should be nearly zero
        XCTAssertLessThan(abs(frames[9].browLift), 0.05)
    }

    func testPresetCountIsAtLeast25() {
        XCTAssertGreaterThanOrEqual(EmotionLibrary.presets.count, 25)
    }

    func testCompoundCategoryExists() {
        let compounds = EmotionLibrary.presets(in: .compound)
        XCTAssertGreaterThanOrEqual(compounds.count, 3)
    }
}
