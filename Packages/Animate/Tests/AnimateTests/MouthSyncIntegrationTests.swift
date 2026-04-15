import XCTest
@testable import AnimateUI
import AVFoundation
import CoreMedia
import Metal

@available(macOS 26.0, *)
final class MouthSyncIntegrationTests: XCTestCase {

    func testGraceCover2Demo() async throws {
        let testDir = URL(fileURLWithPath: "/tmp/mouth-sync-test")
        let desktopDir = URL(fileURLWithPath: "/Volumes/Storage VIII/Users/gary/Desktop")
        let sourceVideo = testDir.appendingPathComponent("lincoln_60s.mp4")
        let outputVideo = desktopDir.appendingPathComponent("mouth_synced_lincoln_grace_cover_2.mp4")
        let spriteFolder = testDir.appendingPathComponent("sprites/bunny")
        let audioStem = desktopDir.appendingPathComponent("Grace Cover 2 (2m24s).mp3")

        guard FileManager.default.fileExists(atPath: sourceVideo.path) else {
            XCTFail("Source video not found at \(sourceVideo.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: audioStem.path) else {
            XCTFail("Audio not found at \(audioStem.path)")
            return
        }

        if FileManager.default.fileExists(atPath: outputVideo.path) {
            try FileManager.default.removeItem(at: outputVideo)
        }

        let track = CharacterSyncTrack(
            characterName: "Bunny",
            characterSlug: "bunny",
            audioStemURL: audioStem,
            dialogueText: nil,
            mouthSpriteFolderURL: spriteFolder
        )

        let config = VideoMouthSyncConfiguration(
            sourceVideoURL: sourceVideo,
            outputVideoURL: outputVideo,
            format: .mp4,
            resolution: .source,
            fps: 24,
            characterTracks: [track],
            mixedAudioURL: audioStem,
            smoothingStrength: 1,
            featherRadius: 3.0
        )

        let pipeline = await VideoMouthSyncPipeline()

        do {
            let result = try await pipeline.process(config)
            XCTAssertGreaterThan(result.totalFrames, 0, "Should have processed frames")
            XCTAssertGreaterThan(result.durationSeconds, 0, "Should have duration")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: outputVideo.path),
                "Output video should exist"
            )

            let attrs = try FileManager.default.attributesOfItem(atPath: outputVideo.path)
            let fileSize = attrs[.size] as? Int ?? 0
            XCTAssertGreaterThan(fileSize, 1000, "Output video should have content")

            print("[MouthSyncTest] SUCCESS: \(result.totalFrames) frames, \(String(format: "%.1f", result.durationSeconds))s, \(fileSize) bytes")
        } catch {
            print("[MouthSyncTest] Pipeline error: \(error)")
            throw error
        }
    }

    func testBushSpeechDemo() async throws {
        let testDir = URL(fileURLWithPath: "/tmp/mouth-sync-test")
        let desktopDir = URL(fileURLWithPath: "/Volumes/Storage VIII/Users/gary/Desktop")
        let sourceVideo = testDir.appendingPathComponent("bush_state_union_30s.mp4")
        let outputVideo = desktopDir.appendingPathComponent("mouth_synced_bush_state_union_30s.mp4")
        let spriteFolder = testDir.appendingPathComponent("sprites/bunny")
        let audioStem = testDir.appendingPathComponent("bush_state_union_30s.m4a")

        guard FileManager.default.fileExists(atPath: sourceVideo.path) else {
            XCTFail("Source video not found at \(sourceVideo.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: audioStem.path) else {
            XCTFail("Audio not found at \(audioStem.path)")
            return
        }

        if FileManager.default.fileExists(atPath: outputVideo.path) {
            try FileManager.default.removeItem(at: outputVideo)
        }

        let track = CharacterSyncTrack(
            characterName: "Bunny",
            characterSlug: "bunny",
            audioStemURL: audioStem,
            dialogueText: nil,
            mouthSpriteFolderURL: spriteFolder
        )

        let config = VideoMouthSyncConfiguration(
            sourceVideoURL: sourceVideo,
            outputVideoURL: outputVideo,
            format: .mp4,
            resolution: .source,
            fps: 24,
            characterTracks: [track],
            mixedAudioURL: nil,
            smoothingStrength: 1,
            featherRadius: 3.0
        )

        let pipeline = await VideoMouthSyncPipeline()
        let result = try await pipeline.process(config)

        XCTAssertGreaterThan(result.totalFrames, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputVideo.path))
    }

    func testVideoMouthSyncPipeline() async throws {
        let testDir = URL(fileURLWithPath: "/tmp/mouth-sync-test")
        let sourceVideo = testDir.appendingPathComponent("lincoln_60s.mp4")
        let outputVideo = testDir.appendingPathComponent("lincoln_60s_synced.mp4")
        let spriteFolder = testDir.appendingPathComponent("sprites/bunny")
        let audioStem = testDir.appendingPathComponent("lincoln_60s_audio.wav")

        guard FileManager.default.fileExists(atPath: sourceVideo.path) else {
            XCTFail("Source video not found at \(sourceVideo.path)")
            return
        }

        if FileManager.default.fileExists(atPath: outputVideo.path) {
            try FileManager.default.removeItem(at: outputVideo)
        }

        let track = CharacterSyncTrack(
            characterName: "Bunny",
            characterSlug: "bunny",
            audioStemURL: audioStem,
            dialogueText: "Hello world, this is a test of the mouth sync pipeline",
            mouthSpriteFolderURL: spriteFolder
        )

        let config = VideoMouthSyncConfiguration(
            sourceVideoURL: sourceVideo,
            outputVideoURL: outputVideo,
            format: .mp4,
            resolution: .source,
            fps: 24,
            characterTracks: [track],
            mixedAudioURL: nil,
            smoothingStrength: 1,
            featherRadius: 3.0
        )

        let pipeline = await VideoMouthSyncPipeline()

        do {
            let result = try await pipeline.process(config)
            XCTAssertGreaterThan(result.totalFrames, 0, "Should have processed frames")
            XCTAssertGreaterThan(result.durationSeconds, 0, "Should have duration")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: outputVideo.path),
                "Output video should exist"
            )

            let attrs = try FileManager.default.attributesOfItem(atPath: outputVideo.path)
            let fileSize = attrs[.size] as? Int ?? 0
            XCTAssertGreaterThan(fileSize, 1000, "Output video should have content")

            print("[MouthSyncTest] SUCCESS: \(result.totalFrames) frames, \(String(format: "%.1f", result.durationSeconds))s, \(fileSize) bytes")
        } catch {
            print("[MouthSyncTest] Pipeline error: \(error)")
            throw error
        }
    }
}
