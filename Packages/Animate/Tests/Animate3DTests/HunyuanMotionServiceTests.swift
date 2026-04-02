import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class HunyuanMotionServiceTests: XCTestCase {

    func testRequestValidation() {
        var request = HunyuanMotionService.MotionRequest(prompt: "walk forward")
        request.durationSeconds = 20  // over max
        request.cfgScale = -5  // under min
        request.numVariations = 10  // over max

        let validated = request.validated
        XCTAssertEqual(validated.durationSeconds, 12)  // clamped to max
        XCTAssertEqual(validated.cfgScale, 1)  // clamped to min
        XCTAssertEqual(validated.numVariations, 4)  // clamped to max
    }

    func testMotionPromptFromAction() {
        let walkPrompt = HunyuanMotionService.motionPrompt(for: "walk", characterName: "Luke")
        XCTAssertTrue(walkPrompt.contains("walks forward"))

        let speakPrompt = HunyuanMotionService.motionPrompt(for: "speak", characterName: "Amira", emotion: "angry", intensity: 0.8)
        XCTAssertTrue(speakPrompt.contains("gestures"))
        XCTAssertTrue(speakPrompt.contains("angry"))
        XCTAssertTrue(speakPrompt.contains("energetically"))

        let singPrompt = HunyuanMotionService.motionPrompt(for: "sing", characterName: "Luke", intensity: 0.2)
        XCTAssertTrue(singPrompt.contains("singing"))
        XCTAssertTrue(singPrompt.contains("subtly"))
    }

    func testMotionPromptUnknownAction() {
        let custom = HunyuanMotionService.motionPrompt(for: "backflip", characterName: "Luke", intensity: 0.9)
        XCTAssertTrue(custom.contains("backflip"))
        XCTAssertTrue(custom.contains("dramatically"))
    }

    func testMotionCategories() {
        for category in HunyuanMotionService.MotionCategory.allCases {
            XCTAssertFalse(category.examplePrompts.isEmpty, "Category \(category) has no examples")
        }
    }

    func testDefaultSpaceURL() {
        XCTAssertEqual(HunyuanMotionService.defaultSpaceURL, "https://tencent-hy-motion-1-0.hf.space")
    }

    func testServiceInitWithCustomURL() {
        let service = HunyuanMotionService(spaceURL: "https://custom.space.example")
        XCTAssertEqual(service.spaceURL, "https://custom.space.example")
    }
}
