import Foundation
import XCTest
import simd
@testable import AnimateUI

@available(macOS 26.0, *)
final class ActingBeatMotionPlannerTests: XCTestCase {

    // MARK: - Helpers

    private func makeBlocking(
        beats: [ActingBeat],
        keyPositions: [BlockingKeyframe] = [],
        characterName: String = "Luke",
        characterSlug: String = "luke"
    ) -> CharacterBlockingPlan {
        let defaultKeyPosition = BlockingKeyframe(
            frame: 0,
            position: SIMD3<Double>(0, 0, -3),
            facing: .camera,
            pose: "standing",
            emotion: "neutral",
            easing: .easeInOut
        )
        return CharacterBlockingPlan(
            characterName: characterName,
            characterSlug: characterSlug,
            preferredCostumeName: nil,
            entranceFrame: 0,
            exitFrame: nil,
            keyPositions: keyPositions.isEmpty ? [defaultKeyPosition] : keyPositions,
            actingBeats: beats,
            lipsyncBeats: [],
            holdStyle: .onTwos
        )
    }

    // MARK: - Tests

    func testPlanFiltersShortBeats() {
        // At 24fps, 10 frames = 0.42s (below 1.0s minimum), 48 frames = 2.0s (above)
        let shortBeat = ActingBeat(startFrame: 0, endFrame: 10, action: "gesture", intensity: 0.5)
        let normalBeat = ActingBeat(startFrame: 48, endFrame: 96, action: "walk", intensity: 0.5)

        let blocking = makeBlocking(beats: [shortBeat, normalBeat])
        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 1, "Only the normal-length beat should appear")
        XCTAssertEqual(plan[0].actingBeat.action, "walk")
    }

    func testPlanSkipsNonMotionActions() {
        let thinkBeat = ActingBeat(startFrame: 0, endFrame: 72, action: "think", intensity: 0.5)
        let internalBeat = ActingBeat(startFrame: 72, endFrame: 144, action: "internal", intensity: 0.5)
        let narrateBeat = ActingBeat(startFrame: 144, endFrame: 216, action: "narrate", intensity: 0.5)
        let offscreenBeat = ActingBeat(startFrame: 216, endFrame: 288, action: "offscreen", intensity: 0.5)
        let walkBeat = ActingBeat(startFrame: 288, endFrame: 360, action: "walk", intensity: 0.5)

        let blocking = makeBlocking(beats: [thinkBeat, internalBeat, narrateBeat, offscreenBeat, walkBeat])
        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 1, "Only motion actions should be planned")
        XCTAssertEqual(plan[0].actingBeat.action, "walk")
    }

    func testPlanGeneratesCorrectPrompts() {
        let walkBeat = ActingBeat(startFrame: 0, endFrame: 72, action: "walk", intensity: 0.5)
        let blocking = makeBlocking(beats: [walkBeat])

        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(plan[0].request.prompt.contains("walks forward"),
                      "Walk prompt should contain 'walks forward', got: \(plan[0].request.prompt)")
    }

    func testCfgScaleMapping() {
        // Low intensity (0.2) -> CFG 5.0, high intensity (1.0) -> CFG 10.0
        let lowBeat = ActingBeat(startFrame: 0, endFrame: 72, action: "gesture", intensity: 0.2)
        let highBeat = ActingBeat(startFrame: 72, endFrame: 144, action: "gesture", intensity: 1.0)

        let blocking = makeBlocking(beats: [lowBeat, highBeat])
        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].request.cfgScale, 5.0, accuracy: 0.01,
                       "Minimum intensity should map to CFG 5.0")
        XCTAssertEqual(plan[1].request.cfgScale, 10.0, accuracy: 0.01,
                       "Maximum intensity should map to CFG 10.0")
    }

    func testDurationClamping() {
        // 24fps, 480 frames = 20s -> should be clamped to 12s (default max)
        let longBeat = ActingBeat(startFrame: 0, endFrame: 480, action: "walk", intensity: 0.5)
        let blocking = makeBlocking(beats: [longBeat])

        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].estimatedDurationSeconds, 12.0, accuracy: 0.01,
                       "Duration should be clamped to maximum 12s")
        XCTAssertEqual(plan[0].request.durationSeconds, 12.0, accuracy: 0.01)
    }

    func testEmotionContextFromKeyframes() {
        let keyframes = [
            BlockingKeyframe(frame: 0, position: SIMD3<Double>(0, 0, -3), facing: .camera,
                             pose: "standing", emotion: "neutral", easing: .easeInOut),
            BlockingKeyframe(frame: 48, position: SIMD3<Double>(0, 0, -3), facing: .camera,
                             pose: "standing", emotion: "angry", easing: .easeInOut),
        ]
        // Beat starts at frame 60 -> active emotion should be "angry" (set at frame 48)
        let beat = ActingBeat(startFrame: 60, endFrame: 132, action: "gesture", intensity: 0.8)
        let blocking = makeBlocking(beats: [beat], keyPositions: keyframes)

        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].emotionContext, "angry")
        XCTAssertTrue(plan[0].request.prompt.contains("angry"),
                      "Prompt should include the emotion")
    }

    func testNeutralEmotionReturnsNil() {
        let keyframes = [
            BlockingKeyframe(frame: 0, position: SIMD3<Double>(0, 0, -3), facing: .camera,
                             pose: "standing", emotion: "neutral", easing: .easeInOut),
        ]
        let beat = ActingBeat(startFrame: 0, endFrame: 72, action: "walk", intensity: 0.5)
        let blocking = makeBlocking(beats: [beat], keyPositions: keyframes)

        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 1)
        XCTAssertNil(plan[0].emotionContext, "Neutral emotion should return nil")
    }

    func testSummaryFormatting() {
        let beat1 = ActingBeat(startFrame: 0, endFrame: 72, action: "walk", intensity: 0.5)
        let beat2 = ActingBeat(startFrame: 72, endFrame: 144, action: "gesture", intensity: 0.6)
        let blocking = makeBlocking(beats: [beat1, beat2])

        let plan = ActingBeatMotionPlanner.plan(from: blocking)
        let summary = ActingBeatMotionPlanner.summary(for: plan)

        XCTAssertTrue(summary.contains("2 motion clips"), "Summary should mention 2 clips, got: \(summary)")
        XCTAssertTrue(summary.contains("6.0s total"), "Summary should show total duration, got: \(summary)")
        XCTAssertTrue(summary.contains("gesture"), "Summary should list actions")
        XCTAssertTrue(summary.contains("walk"), "Summary should list actions")
    }

    func testEmptyPlanSummary() {
        let summary = ActingBeatMotionPlanner.summary(for: [])
        XCTAssertEqual(summary, "No motions to generate")
    }

    func testEstimatedGenerationTime() {
        let beat = ActingBeat(startFrame: 0, endFrame: 72, action: "walk", intensity: 0.5)
        let blocking = makeBlocking(beats: [beat])

        let plan = ActingBeatMotionPlanner.plan(from: blocking)
        let estimate = ActingBeatMotionPlanner.estimatedGenerationTime(for: plan)

        XCTAssertEqual(estimate, 60.0, accuracy: 0.01,
                       "One clip should estimate ~60s generation time")
    }

    func testCharacterInfoPassthrough() {
        let beat = ActingBeat(startFrame: 0, endFrame: 72, action: "walk", intensity: 0.5)
        let blocking = makeBlocking(beats: [beat], characterName: "Amira", characterSlug: "amira_v2")

        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].characterName, "Amira")
        XCTAssertEqual(plan[0].characterSlug, "amira_v2")
    }

    func testMotionActionsIncludeSpeakAndSing() {
        // speak and sing involve physical motion (gesturing, swaying) so should NOT be filtered
        let speakBeat = ActingBeat(startFrame: 0, endFrame: 72, action: "speak", intensity: 0.5)
        let singBeat = ActingBeat(startFrame: 72, endFrame: 144, action: "sing", intensity: 0.7)

        let blocking = makeBlocking(beats: [speakBeat, singBeat])
        let plan = ActingBeatMotionPlanner.plan(from: blocking)

        XCTAssertEqual(plan.count, 2, "speak and sing are motion actions")
    }
}
