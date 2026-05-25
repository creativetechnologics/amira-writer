import AppKit
import Foundation

// MARK: - Speech Delegate

/// Delegate that bridges NSSpeechSynthesizer completion to a Swift concurrency continuation.
private final class SpeechDelegate: NSObject, NSSpeechSynthesizerDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Never>?

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        continuation?.resume()
        continuation = nil
    }
}

/// Generates speech audio for dialogue beats using macOS NSSpeechSynthesizer.
///
/// Produces AIFF files at the project's audio folder. These files can then be
/// loaded by AnimationAudioPlayer or used as lipsync source audio.
@available(macOS 26.0, *)
struct TTSService: Sendable {

    enum TTSError: LocalizedError {
        case synthesisFailed
        case invalidText
        case outputURLNotWritable

        var errorDescription: String? {
            switch self {
            case .synthesisFailed: "NSSpeechSynthesizer failed to generate audio."
            case .invalidText: "No text provided for TTS generation."
            case .outputURLNotWritable: "Cannot write to the output URL."
            }
        }
    }

    struct Request: Sendable {
        let text: String
        let voiceIdentifier: String?
        let rate: Float          // Words per minute. Default ≈ 175.
        let outputURL: URL
    }

    /// Synthesize speech to an AIFF file at `request.outputURL`.
    static func synthesize(_ request: Request) async throws {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TTSError.invalidText }

        let voiceName = request.voiceIdentifier.map { NSSpeechSynthesizer.VoiceName(rawValue: $0) }
        guard let synth = NSSpeechSynthesizer(voice: voiceName) else {
            throw TTSError.synthesisFailed
        }
        synth.rate = request.rate > 0 ? request.rate : 175

        let delegate = SpeechDelegate()
        synth.delegate = delegate

        guard synth.startSpeaking(text, to: request.outputURL) else {
            throw TTSError.synthesisFailed
        }

        await withCheckedContinuation { continuation in
            delegate.continuation = continuation
        }
    }

    /// Generate TTS for each dialogue beat in a blocking plan and write AIFF files.
    /// Returns map of (actingBeatID -> outputURL).
    ///
    /// Uses `beat.action` as the spoken text since `ActingBeat` does not carry
    /// a separate `dialogue` property.
    static func generateDialogueAudio(
        blockingPlan: CharacterBlockingPlan,
        outputDirectory: URL
    ) async -> [(beatID: Int, url: URL)] {
        var results: [(beatID: Int, url: URL)] = []
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for (index, beat) in blockingPlan.actingBeats.enumerated() {
            let text = beat.action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let fileName = "tts-\(blockingPlan.characterSlug)-beat\(index).aiff"
            let outputURL = outputDirectory.appendingPathComponent(fileName)
            let request = Request(text: text, voiceIdentifier: nil, rate: 175, outputURL: outputURL)
            do {
                try await synthesize(request)
                results.append((beatID: index, url: outputURL))
            } catch {
                // Skip failed beats silently
            }
        }
        return results
    }

    /// Returns available system voice identifiers.
    static var availableVoices: [String] {
        NSSpeechSynthesizer.availableVoices.map { $0.rawValue }
    }

}
