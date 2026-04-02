import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class AutoLipSyncServiceTests: XCTestCase {

    // MARK: - Source Selection

    func testBestSourceWithOWP() async {
        let source = await AutoLipSyncService.bestAvailableSource(hasOWPAlignment: true)
        XCTAssertEqual(source, .owpAlignment)
    }

    func testBestSourceWithoutOWPFallsToRhubarbOrSyllables() async {
        let source = await AutoLipSyncService.bestAvailableSource(hasOWPAlignment: false)
        XCTAssertTrue(source == .rhubarb || source == .syllables,
                      "Expected rhubarb or syllables, got \(source)")
    }

    // MARK: - Syllable Heuristic

    func testSyllableHeuristicGeneratesKeyframes() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "Hello world this is a test",
            estimatedDurationSeconds: 3.0,
            fps: 24,
            startFrame: 0
        )
        XCTAssertEqual(result.source, .syllables)
        XCTAssertGreaterThan(result.visemeKeyframes.count, 0)
        XCTAssertEqual(result.fps, 24)
    }

    func testEmptyTextReturnsNoKeyframes() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "",
            estimatedDurationSeconds: 1.0,
            fps: 24,
            startFrame: 0
        )
        XCTAssertEqual(result.source, .syllables)
        XCTAssertTrue(result.visemeKeyframes.isEmpty)
        XCTAssertEqual(result.durationFrames, 0)
    }

    func testKeyframesRespectStartFrame() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "Test phrase here",
            estimatedDurationSeconds: 2.0,
            fps: 24,
            startFrame: 100
        )
        if let first = result.visemeKeyframes.first {
            XCTAssertGreaterThanOrEqual(first.frame, 100,
                "First keyframe should be at or after startFrame")
        }
    }

    func testDurationMatchesEstimate() {
        let fps = 24
        let duration = 3.0
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "One two three four",
            estimatedDurationSeconds: duration,
            fps: fps,
            startFrame: 0
        )
        XCTAssertEqual(result.durationFrames, Int(duration * Double(fps)))
    }

    func testSingleWordGeneratesAtLeastOneKeyframe() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "Hello",
            estimatedDurationSeconds: 1.0,
            fps: 24,
            startFrame: 0
        )
        XCTAssertGreaterThanOrEqual(result.visemeKeyframes.count, 1)
    }

    // MARK: - Beat Conversion

    func testKeyframesToBeatsProducesCorrectCount() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "Hello world",
            estimatedDurationSeconds: 2.0,
            fps: 24,
            startFrame: 0
        )
        let beats = AutoLipSyncService.keyframesToBeats(result.visemeKeyframes)
        XCTAssertEqual(beats.count, result.visemeKeyframes.count)
    }

    func testKeyframesToBeatsFrameRanges() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "Test audio sync",
            estimatedDurationSeconds: 2.0,
            fps: 24,
            startFrame: 0
        )
        let beats = AutoLipSyncService.keyframesToBeats(result.visemeKeyframes)
        for (kf, beat) in zip(result.visemeKeyframes, beats) {
            XCTAssertEqual(beat.startFrame, kf.frame)
            XCTAssertEqual(beat.endFrame, kf.frame + kf.duration)
            XCTAssertEqual(beat.mode, "speech")
            XCTAssertNil(beat.songName)
        }
    }

    func testKeyframesToBeatsCustomMode() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "La la la",
            estimatedDurationSeconds: 1.5,
            fps: 24,
            startFrame: 0
        )
        let beats = AutoLipSyncService.keyframesToBeats(result.visemeKeyframes, mode: "sing")
        for beat in beats {
            XCTAssertEqual(beat.mode, "sing")
        }
    }

    func testEmptyKeyframesToBeatsReturnsEmpty() {
        let beats = AutoLipSyncService.keyframesToBeats([])
        XCTAssertTrue(beats.isEmpty)
    }

    // MARK: - Single Beat Conversion

    func testResultToSingleBeat() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "This is a long sentence with many words",
            estimatedDurationSeconds: 4.0,
            fps: 24,
            startFrame: 0
        )
        let beat = AutoLipSyncService.resultToSingleBeat(result)
        XCTAssertNotNil(beat)
        if let beat {
            XCTAssertLessThan(beat.startFrame, beat.endFrame)
            XCTAssertEqual(beat.mode, "speech")
        }
    }

    func testResultToSingleBeatNilForEmpty() {
        let result = AutoLipSyncService.generateWithSyllableHeuristic(
            text: "",
            estimatedDurationSeconds: 1.0,
            fps: 24,
            startFrame: 0
        )
        let beat = AutoLipSyncService.resultToSingleBeat(result)
        XCTAssertNil(beat)
    }

    // MARK: - Audio Duration

    func testAudioDurationNilForMissingFile() {
        let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent_audio_file_xyz.wav")
        let duration = AutoLipSyncService.audioDuration(url: bogusURL)
        XCTAssertNil(duration)
    }

    func testAudioDurationEstimateForSmallFile() throws {
        // Write a fake audio file of known size
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audio_\(UUID().uuidString).wav")
        let fakeData = Data(repeating: 0, count: 176_000) // ~1 second worth
        try fakeData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let duration = AutoLipSyncService.audioDuration(url: tempURL)
        XCTAssertNotNil(duration)
        if let duration {
            XCTAssertEqual(duration, 1.0, accuracy: 0.01)
        }
    }
}
