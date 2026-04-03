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

    func testAudioDurationNilForMissingFile() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent_audio_file_xyz.wav")
        let duration = await AutoLipSyncService.audioDuration(url: bogusURL)
        XCTAssertNil(duration)
    }

    func testAudioDurationEstimateForSmallFile() async throws {
        // Write a valid minimal WAV file of known duration (~1 second)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audio_\(UUID().uuidString).wav")
        let wavData = minimalWAVData(durationSeconds: 1.0)
        try wavData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let duration = await AutoLipSyncService.audioDuration(url: tempURL)
        XCTAssertNotNil(duration)
        if let duration {
            XCTAssertEqual(duration, 1.0, accuracy: 0.1)
        }
    }

    // MARK: - Helpers

    private func minimalWAVData(durationSeconds: Double, sampleRate: Int = 44100, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let bytesPerSample = bitsPerSample / 8
        let numSamples = Int(durationSeconds * Double(sampleRate))
        let dataSize = numSamples * channels * bytesPerSample
        let fmtChunkSize: Int32 = 16
        let fileSize = Int32(4 + 24 + 8 + dataSize) // WAVE + fmt chunk + data header + data

        var data = Data()
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fmtChunkSize.littleEndian) { Array($0) })
        let audioFormat: Int16 = 1 // PCM
        data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        let numChannels = Int16(channels)
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        let sr = Int32(sampleRate)
        data.append(contentsOf: withUnsafeBytes(of: sr.littleEndian) { Array($0) })
        let byteRate = Int32(sampleRate * channels * bytesPerSample)
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = Int16(channels * bytesPerSample)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        let bps = Int16(bitsPerSample)
        data.append(contentsOf: withUnsafeBytes(of: bps.littleEndian) { Array($0) })
        // data chunk
        data.append(contentsOf: "data".utf8)
        let ds = Int32(dataSize)
        data.append(contentsOf: withUnsafeBytes(of: ds.littleEndian) { Array($0) })
        data.append(Data(count: dataSize)) // silence
        return data
    }
}
