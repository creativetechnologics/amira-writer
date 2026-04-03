import XCTest
import simd
@testable import AnimateUI

@available(macOS 26.0, *)
final class DirectionTemplateCompilerTests: XCTestCase {

    // MARK: - Helpers

    private func makePlan(
        name: String = "Alice",
        slug: String = "alice",
        entranceFrame: Int = 0,
        exitFrame: Int? = nil,
        keyPositions: [BlockingKeyframe] = [],
        actingBeats: [ActingBeat] = []
    ) -> CharacterBlockingPlan {
        var positions = keyPositions
        if positions.isEmpty {
            positions = [
                BlockingKeyframe(
                    frame: 0,
                    position: SIMD3<Double>(0, 0, -3),
                    facing: .camera,
                    pose: "standing",
                    emotion: "neutral",
                    easing: .linear
                )
            ]
        }
        return CharacterBlockingPlan(
            characterName: name,
            characterSlug: slug,
            preferredCostumeName: nil,
            entranceFrame: entranceFrame,
            exitFrame: exitFrame,
            keyPositions: positions,
            actingBeats: actingBeats,
            lipsyncBeats: [],
            holdStyle: .onTwos
        )
    }

    // MARK: - Test 1: Empty input returns default establishing shot

    func testEmptyBlockingPlansReturnsDefaultEstablishingShot() {
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [],
            sceneDurationFrames: 240,
            fps: 24
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].frame, 0)
        XCTAssertEqual(result[0].shotType, .wide)
        XCTAssertNil(result[0].focusCharacterSlug)
    }

    func testZeroDurationReturnsDefaultEstablishingShot() {
        let plan = makePlan()
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: 0,
            fps: 24
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].frame, 0)
        XCTAssertEqual(result[0].shotType, .wide)
    }

    // MARK: - Test 2: Entrance event generates a camera instruction

    func testEntranceEventGeneratesCameraInstruction() {
        // Scene: 20 seconds at 24 fps = 480 frames.
        // establishDuration = min(fps*4, 480/4) = min(96, 120) = 96 frames.
        // lastCutFrame starts at establishDuration (96). minimumCutInterval = 48.
        // Alice enters at frame 144 (fps*6): 144 - 96 = 48 >= 48 → accepted.
        let fps = 24
        let plan = makePlan(
            name: "Alice",
            slug: "alice",
            entranceFrame: fps * 6,  // frame 144 — comfortably past establish + min interval
            keyPositions: [
                BlockingKeyframe(
                    frame: fps * 6,
                    position: SIMD3<Double>(0, 0, -3),
                    facing: .camera,
                    pose: "standing",
                    emotion: "neutral",
                    easing: .easeOut
                )
            ]
        )
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 20,  // 480 frames
            fps: fps
        )
        // Should have at least the establishing shot + the entrance cut.
        XCTAssertGreaterThanOrEqual(result.count, 2)
        let entranceCut = result.first { $0.frame == fps * 6 }
        XCTAssertNotNil(entranceCut, "Expected a camera cut at the entrance frame")
        XCTAssertEqual(entranceCut?.shotType, .medium)
        XCTAssertEqual(entranceCut?.focusCharacterSlug, "alice")
        XCTAssertTrue(entranceCut?.motivation.contains("enters") ?? false)
    }

    // MARK: - Test 3: High-intensity speaking beats generate close-ups

    func testHighIntensitySpeakingBeatGeneratesCloseUp() {
        let fps = 24
        // establishDuration = min(fps*4, 480/4) = 96. lastCutFrame starts at 96.
        // minimumCutInterval = 48. Beat at fps*7 = 168: 168 - 96 = 72 >= 48 → accepted.
        let highBeat = ActingBeat(
            startFrame: fps * 7,
            endFrame: fps * 9,
            action: "speak",
            intensity: 0.9
        )
        let plan = makePlan(
            entranceFrame: 0,
            actingBeats: [highBeat]
        )
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 20,
            fps: fps
        )
        let speakCut = result.first { $0.frame == fps * 7 }
        XCTAssertNotNil(speakCut, "Expected a cut at the high-intensity speak beat")
        XCTAssertEqual(speakCut?.shotType, .close,
            "High-intensity speech (intensity 0.9) should yield a close-up")
    }

    func testLowIntensitySpeakingBeatGeneratesMediumShot() {
        let fps = 24
        // establishDuration = min(fps*4, 480/4) = 96. lastCutFrame starts at 96.
        // minimumCutInterval = 48. Beat at fps*7 = 168: 168 - 96 = 72 >= 48 → accepted.
        let lowBeat = ActingBeat(
            startFrame: fps * 7,
            endFrame: fps * 9,
            action: "speak",
            intensity: 0.4
        )
        let plan = makePlan(
            entranceFrame: 0,
            actingBeats: [lowBeat]
        )
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 20,
            fps: fps
        )
        let speakCut = result.first { $0.frame == fps * 7 }
        XCTAssertNotNil(speakCut, "Expected a cut at the low-intensity speak beat")
        XCTAssertEqual(speakCut?.shotType, .medium,
            "Low-intensity speech (intensity 0.4) should yield a medium shot")
    }

    // MARK: - Test 4: Minimum cut interval (no cuts faster than 2 seconds)

    func testMinimumCutIntervalIsEnforced() {
        let fps = 24
        let minInterval = fps * 2  // 48 frames

        // Two speak beats placed only 1 second apart — only the first should fire.
        let beat1 = ActingBeat(startFrame: fps * 5,     endFrame: fps * 6, action: "speak", intensity: 0.9)
        let beat2 = ActingBeat(startFrame: fps * 5 + fps, endFrame: fps * 7, action: "speak", intensity: 0.9)
        let plan = makePlan(entranceFrame: 0, actingBeats: [beat1, beat2])

        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 20,
            fps: fps
        )

        // Verify no two consecutive cuts are closer than the minimum interval.
        let frames = result.map(\.frame).sorted()
        for i in 1 ..< frames.count {
            let gap = frames[i] - frames[i - 1]
            XCTAssertGreaterThanOrEqual(
                gap, minInterval,
                "Gap between frame \(frames[i-1]) and \(frames[i]) is \(gap), which is below the 2-second minimum"
            )
        }
    }

    func testNoConsecutiveCutsWithinTwoSeconds() {
        let fps = 24
        let minInterval = fps * 2

        // Three entrances 1 second apart — only first and third (or fewer) should generate cuts.
        let planA = makePlan(name: "Alice", slug: "alice", entranceFrame: fps * 4,
                             keyPositions: [BlockingKeyframe(frame: fps * 4, position: .zero, facing: .camera,
                                                              pose: "standing", emotion: "neutral", easing: .linear)])
        let planB = makePlan(name: "Bob",   slug: "bob",   entranceFrame: fps * 5,
                             keyPositions: [BlockingKeyframe(frame: fps * 5, position: .zero, facing: .camera,
                                                              pose: "standing", emotion: "neutral", easing: .linear)])
        let planC = makePlan(name: "Carol", slug: "carol", entranceFrame: fps * 6,
                             keyPositions: [BlockingKeyframe(frame: fps * 6, position: .zero, facing: .camera,
                                                              pose: "standing", emotion: "neutral", easing: .linear)])

        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [planA, planB, planC],
            sceneDurationFrames: fps * 30,
            fps: fps
        )

        let frames = result.map(\.frame).sorted()
        for i in 1 ..< frames.count {
            let gap = frames[i] - frames[i - 1]
            XCTAssertGreaterThanOrEqual(
                gap, minInterval,
                "Cut gap \(gap) frames is below the \(minInterval)-frame minimum"
            )
        }
    }

    // MARK: - Test 5: Summary formatting

    func testSummaryForEmptyInstructions() {
        let summary = DirectionTemplateCompiler.summary(for: [])
        XCTAssertEqual(summary, "No camera instructions")
    }

    func testSummaryForSingleInstruction() {
        let single = DirectionTemplateCompiler.CameraInstruction(
            frame: 0,
            shotType: .wide,
            focalLength: 31.5,
            focusCharacterSlug: nil,
            motivation: "Establishing",
            easing: .easeInOut
        )
        let summary = DirectionTemplateCompiler.summary(for: [single])
        XCTAssertTrue(summary.contains("1 camera cut"), "Expected singular form — got: \(summary)")
        XCTAssertTrue(summary.contains("wide"), "Expected shot type in summary — got: \(summary)")
    }

    func testSummaryForMultipleInstructions() {
        let instructions = [
            DirectionTemplateCompiler.CameraInstruction(
                frame: 0,
                shotType: .wide,
                focalLength: 31.5,
                focusCharacterSlug: nil,
                motivation: "Establishing",
                easing: .easeInOut
            ),
            DirectionTemplateCompiler.CameraInstruction(
                frame: 48,
                shotType: .close,
                focalLength: 92.5,
                focusCharacterSlug: "alice",
                motivation: "Alice speaks",
                easing: .easeInOut
            ),
            DirectionTemplateCompiler.CameraInstruction(
                frame: 96,
                shotType: .medium,
                focalLength: 45.0,
                focusCharacterSlug: "bob",
                motivation: "Bob speaks",
                easing: .easeInOut
            ),
        ]
        let summary = DirectionTemplateCompiler.summary(for: instructions)
        XCTAssertTrue(summary.contains("3 camera cuts"), "Expected plural form — got: \(summary)")
        XCTAssertTrue(summary.contains("close"),  "Expected 'close' in summary — got: \(summary)")
        XCTAssertTrue(summary.contains("medium"), "Expected 'medium' in summary — got: \(summary)")
        XCTAssertTrue(summary.contains("wide"),   "Expected 'wide' in summary — got: \(summary)")
    }

    // MARK: - Test 6: Closing wide shot added for long gaps

    func testClosingWideShotAddedForLongGap() {
        let fps = 24
        // Single character entering at frame 0, scene runs for 30 seconds (720 frames).
        // The gap from the last content cut to the end exceeds 6 seconds, so a closing
        // wide shot should be appended near the end.
        let plan = makePlan(
            entranceFrame: 0,
            keyPositions: [
                BlockingKeyframe(frame: 0, position: SIMD3<Double>(0, 0, -3), facing: .camera,
                                 pose: "standing", emotion: "neutral", easing: .linear)
            ]
        )
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 30,  // 720 frames
            fps: fps
        )
        let last = result.last
        XCTAssertNotNil(last)
        XCTAssertEqual(last?.shotType, .wide)
        XCTAssertTrue(last?.motivation.lowercased().contains("closing") ?? false,
                      "Expected closing wide shot at end — got: \(last?.motivation ?? "nil")")
        // Closing shot should be in the last 3 seconds.
        XCTAssertEqual(last?.frame, fps * 30 - fps * 3)
    }

    // MARK: - Test 7: toCameraChoreographyPlan round-trip

    func testToCameraChoreographyPlanProducesKeyframes() {
        let fps = 24
        let plan = makePlan(
            entranceFrame: 0,
            keyPositions: [
                BlockingKeyframe(frame: 0, position: SIMD3<Double>(1, 0, -3), facing: .camera,
                                 pose: "standing", emotion: "neutral", easing: .linear)
            ]
        )
        let instructions = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 10,
            fps: fps
        )
        let choreo = DirectionTemplateCompiler.toCameraChoreographyPlan(
            instructions: instructions,
            blockingPlans: [plan]
        )
        XCTAssertEqual(choreo.keyframes.count, instructions.count)
        // First keyframe should be an establishing wide shot at frame 0.
        XCTAssertEqual(choreo.keyframes[0].frame, 0)
        XCTAssertEqual(choreo.keyframes[0].shotType, .wide)
        XCTAssertEqual(choreo.keyframes[0].shotIntent, .establishing)
    }

    // MARK: - Test 8: Strong emotion generates close-up

    func testStrongEmotionGeneratesCloseUp() {
        let fps = 24
        // establishDuration = min(fps*4, 480/4) = 96. lastCutFrame starts at 96.
        // minimumCutInterval = 48. Emotion at fps*7 = 168: 168 - 96 = 72 >= 48 → accepted.
        let keyPositions: [BlockingKeyframe] = [
            BlockingKeyframe(frame: 0,       position: SIMD3<Double>(0, 0, -3), facing: .camera,
                             pose: "standing", emotion: "neutral", easing: .linear),
            BlockingKeyframe(frame: fps * 7, position: SIMD3<Double>(0, 0, -3), facing: .camera,
                             pose: "standing", emotion: "angry",   easing: .linear),
        ]
        let plan = makePlan(entranceFrame: 0, keyPositions: keyPositions)
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 20,
            fps: fps
        )
        let emotionCut = result.first { $0.frame == fps * 7 }
        XCTAssertNotNil(emotionCut, "Expected a cut when emotion changes to 'angry'")
        XCTAssertEqual(emotionCut?.shotType, .close,
            "Strong emotion 'angry' should trigger a close-up")
    }

    func testNeutralEmotionDoesNotGenerateCut() {
        let fps = 24
        // If the keyframe re-asserts "neutral" from "neutral", no event should fire.
        let keyPositions: [BlockingKeyframe] = [
            BlockingKeyframe(frame: 0, position: SIMD3<Double>(0, 0, -3), facing: .camera,
                             pose: "standing", emotion: "neutral", easing: .linear),
            BlockingKeyframe(frame: fps * 5, position: SIMD3<Double>(0, 0, -3), facing: .camera,
                             pose: "standing", emotion: "neutral", easing: .linear),
        ]
        let plan = makePlan(entranceFrame: 0, keyPositions: keyPositions)
        let result = DirectionTemplateCompiler.compileCameraChoreography(
            blockingPlans: [plan],
            sceneDurationFrames: fps * 20,
            fps: fps
        )
        // Only the establishing shot should exist — no extra cuts from neutral→neutral.
        let extraCuts = result.filter { $0.frame == fps * 5 }
        XCTAssertTrue(extraCuts.isEmpty,
            "Re-asserting 'neutral' emotion should not trigger an extra camera cut")
    }
}
