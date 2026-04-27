import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class ContinuityPromptMemoryCompilerTests: XCTestCase {
    func testSanitizerRemovesReviewAndProcessBoilerplate() {
        let raw = """
        Image review status: rejected. Use the written notes as continuity learning input but never treat the rejected image itself as a positive reference.
        Continuity Builder training candidate. Generate a single image for Gary to critique.
        Selected candidate label: left. Closeness score: 35%.
        Latest Gary feedback to repair or preserve: Please refer to the master map for future place prompts. The town needs to be further up the hillside and no buildings should be close to the river.
        """

        let clause = ContinuityPromptMemoryCompiler.visualInstruction(from: raw) ?? ""
        let lower = clause.lowercased()

        XCTAssertFalse(lower.contains("image review status"))
        XCTAssertFalse(lower.contains("learning input"))
        XCTAssertFalse(lower.contains("continuity builder"))
        XCTAssertFalse(lower.contains("gary"))
        XCTAssertFalse(lower.contains("selected candidate"))
        XCTAssertFalse(lower.contains("closeness score"))
        XCTAssertFalse(lower.contains("future place prompts"))
        XCTAssertTrue(lower.contains("town"))
        XCTAssertTrue(lower.contains("river"))
    }

    func testVisualRuleDoesNotLeakReviewStatusTags() {
        let rule = ContinuityPromptMemoryCompiler.visualRule(
            category: "geography",
            notes: ["The stone arch bridge must not have walls on top."],
            tags: ["rated_5", "positive_feedback", "review", "bridge", "stone"]
        ) ?? ""
        let lower = rule.lowercased()

        XCTAssertTrue(lower.contains("bridge"))
        XCTAssertTrue(lower.contains("stone"))
        XCTAssertFalse(lower.contains("rated"))
        XCTAssertFalse(lower.contains("positive_feedback"))
        XCTAssertFalse(lower.contains("positive feedback"))
        XCTAssertFalse(lower.contains("review"))
    }
}
