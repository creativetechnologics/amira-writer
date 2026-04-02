import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class VisemeBlendEngineTests: XCTestCase {

    func testRestSnapshotValues() {
        let rest = VisemeBlendEngine.MouthSnapshot.rest
        XCTAssertEqual(rest.jawOpen, 0.02, accuracy: 0.001)
        XCTAssertEqual(rest.pucker, 0, accuracy: 0.001)
    }

    func testLerpMidpoint() {
        let a = VisemeBlendEngine.MouthSnapshot(jawOpen: 0, mouthWidth: 0, mouthHeight: 0, pucker: 0, smileBlend: 0)
        let b = VisemeBlendEngine.MouthSnapshot(jawOpen: 1, mouthWidth: 1, mouthHeight: 1, pucker: 1, smileBlend: 1)
        let mid = a.lerped(to: b, t: 0.5)

        XCTAssertEqual(mid.jawOpen, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid.mouthWidth, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid.pucker, 0.5, accuracy: 0.001)
    }

    func testLerpClampsToRange() {
        let a = VisemeBlendEngine.MouthSnapshot.rest
        let b = VisemeBlendEngine.visemeSnapshots[.ai]!

        let underflow = a.lerped(to: b, t: -1)
        XCTAssertEqual(underflow.jawOpen, a.jawOpen, accuracy: 0.001)

        let overflow = a.lerped(to: b, t: 2)
        XCTAssertEqual(overflow.jawOpen, b.jawOpen, accuracy: 0.001)
    }

    func testAllVisemesHaveSnapshots() {
        for viseme in PrestonBlairViseme.allCases {
            XCTAssertNotNil(VisemeBlendEngine.visemeSnapshots[viseme], "Missing snapshot for \(viseme)")
        }
    }

    func testBlendedStateAtKeyframe() {
        let keyframes = [
            VisemeBlendEngine.TimedViseme(frame: 0, viseme: .rest, durationFrames: 10),
            VisemeBlendEngine.TimedViseme(frame: 10, viseme: .ai, durationFrames: 10),
        ]

        // At frame 0, should be rest
        let atZero = VisemeBlendEngine.blendedState(at: 0, keyframes: keyframes)
        XCTAssertEqual(atZero.jawOpen, VisemeBlendEngine.visemeSnapshots[.rest]!.jawOpen, accuracy: 0.001)

        // At frame 10, should be close to ai
        let atTen = VisemeBlendEngine.blendedState(at: 10, keyframes: keyframes)
        XCTAssertEqual(atTen.jawOpen, VisemeBlendEngine.visemeSnapshots[.ai]!.jawOpen, accuracy: 0.1)
    }

    func testEmptyKeyframesReturnsRest() {
        let result = VisemeBlendEngine.blendedState(at: 5, keyframes: [])
        XCTAssertEqual(result.jawOpen, VisemeBlendEngine.MouthSnapshot.rest.jawOpen, accuracy: 0.001)
    }

    func testGenerateSmoothedFrames() {
        let keyframes = [
            VisemeBlendEngine.TimedViseme(frame: 0, viseme: .rest, durationFrames: 5),
            VisemeBlendEngine.TimedViseme(frame: 5, viseme: .o, durationFrames: 5),
            VisemeBlendEngine.TimedViseme(frame: 10, viseme: .rest, durationFrames: 5),
        ]

        let frames = VisemeBlendEngine.generateSmoothedFrames(
            keyframes: keyframes, startFrame: 0, endFrame: 15
        )
        XCTAssertEqual(frames.count, 15)

        // Should start near rest and end near rest
        XCTAssertLessThan(frames[0].pucker, 0.1)
        XCTAssertLessThan(frames[14].pucker, 0.1)

        // Mid-range should have some pucker (O shape)
        XCTAssertGreaterThan(frames[6].pucker, 0.1)
    }
}
