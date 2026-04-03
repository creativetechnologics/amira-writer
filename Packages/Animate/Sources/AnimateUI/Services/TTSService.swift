import AppKit
import Foundation

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

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let voiceName = request.voiceIdentifier.map { NSSpeechSynthesizer.VoiceName(rawValue: $0) }
                let synth = NSSpeechSynthesizer(voice: voiceName)
                synth?.rate = request.rate > 0 ? request.rate : 175
                guard synth?.startSpeaking(text, to: request.outputURL) == true else {
                    continuation.resume(throwing: TTSError.synthesisFailed)
                    return
                }
                // NSSpeechSynthesizer is synchronous when writing to file —
                // poll until isSpeaking becomes false.
                while synth?.isSpeaking == true {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continuation.resume()
            }
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
            // Only synthesise beats that look like spoken dialogue
            guard isSpeechAction(text) else { continue }

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

    // MARK: - Private helpers

    /// Determines if an action string looks like spoken dialogue rather than movement.
    private static func isSpeechAction(_ action: String) -> Bool {
        let speechKeywords = ["say", "speak", "ask", "reply", "shout", "whisper", "tell",
                              "exclaim", "announce", "call", "yell", "mumble", "mutter",
                              "dialogue", "monologue", "narrate", "talk"]
        let lower = action.lowercased()
        return speechKeywords.contains(where: { lower.contains($0) })
    }
}
