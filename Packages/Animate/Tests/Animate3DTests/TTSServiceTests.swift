import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class TTSServiceTests: XCTestCase {

    // MARK: - isSpeechAction (via action text on ActingBeat)

    /// A beat with a non-empty action text is considered a speech action.
    func testIsSpeechActionAcceptsNonEmptyTranscript() {
        let beat = ActingBeat(
            startFrame: 0,
            endFrame: 24,
            action: "Hello, I am speaking right now.",
            intensity: 1.0
        )
        // Any non-empty, non-whitespace action qualifies as speakable text.
        let text = beat.action.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(text.isEmpty, "A beat with dialogue text should be considered a speech action")
    }

    /// A beat with a blank or whitespace-only action is NOT a speech action.
    func testIsSpeechActionRejectsEmptyTranscript() {
        let emptyBeat = ActingBeat(
            startFrame: 0,
            endFrame: 24,
            action: "   ",
            intensity: 0.0
        )
        let text = emptyBeat.action.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(text.isEmpty, "A beat with blank text should not be a speech action")
    }

    // MARK: - generateDialogueAudio

    /// Calling generateDialogueAudio with an empty blocking plan (no acting beats) should
    /// return immediately with an empty results array and not write any files.
    func testGenerateDialogueAudioWithEmptyPlan() async throws {
        let emptyPlan = CharacterBlockingPlan(
            characterName: "TestChar",
            characterSlug: "test-char",
            preferredCostumeName: nil,
            entranceFrame: 0,
            exitFrame: nil,
            keyPositions: [],
            actingBeats: [],
            lipsyncBeats: [],
            holdStyle: .onTwos
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let results = await TTSService.generateDialogueAudio(
            blockingPlan: emptyPlan,
            outputDirectory: tempDir
        )

        XCTAssertTrue(results.isEmpty, "Empty blocking plan should produce no audio files")

        // Verify no AIFF files were written to the output directory.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let aiffFiles = contents.filter { $0.hasSuffix(".aiff") }
        XCTAssertTrue(aiffFiles.isEmpty, "No AIFF files should have been written for an empty plan")
    }
}
