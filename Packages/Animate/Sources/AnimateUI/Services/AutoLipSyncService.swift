import AVFoundation
import Foundation

/// Orchestrates automatic lip sync generation from audio files.
///
/// Selects the best available method (Rhubarb CLI, OWP alignment, or syllable heuristic),
/// runs analysis, and returns results ready for `CharacterMouthEngine` consumption.
@available(macOS 26.0, *)
struct AutoLipSyncService: Sendable {

    // MARK: - Types

    enum LipSyncSource: String, Sendable, Equatable {
        case rhubarb      // External Rhubarb CLI tool (most accurate)
        case syllables    // Heuristic syllable-based (fallback)
        case owpAlignment // From OWP lyric alignment data (for singing)
    }

    struct LipSyncResult: Sendable {
        let source: LipSyncSource
        let visemeKeyframes: [LipSyncEngine.VisemeKeyframe]
        let durationFrames: Int
        let fps: Int
    }

    // MARK: - Source Selection

    /// Determine the best available lip sync method.
    @MainActor
    static func bestAvailableSource(hasOWPAlignment: Bool) -> LipSyncSource {
        if hasOWPAlignment { return .owpAlignment }
        if RhubarbLipSync().isAvailable { return .rhubarb }
        return .syllables
    }

    // MARK: - Main Entry Point

    /// Generate lip sync data from an audio file.
    /// Uses Rhubarb if available, otherwise falls back to syllable heuristics.
    @MainActor
    static func generateFromAudio(
        audioURL: URL,
        dialogueText: String? = nil,
        fps: Int = 24,
        startFrame: Int = 0
    ) async throws -> LipSyncResult {
        let rhubarb = RhubarbLipSync()
        if rhubarb.isAvailable {
            return try await generateWithRhubarb(
                rhubarb: rhubarb,
                audioURL: audioURL,
                dialogueText: dialogueText,
                fps: fps,
                startFrame: startFrame
            )
        } else {
            return generateWithSyllableHeuristic(
                text: dialogueText ?? "",
                estimatedDurationSeconds: await audioDuration(url: audioURL) ?? 5.0,
                fps: fps,
                startFrame: startFrame
            )
        }
    }

    // MARK: - Rhubarb Path

    /// Generate lip sync using Rhubarb CLI.
    @MainActor
    private static func generateWithRhubarb(
        rhubarb: RhubarbLipSync,
        audioURL: URL,
        dialogueText: String?,
        fps: Int,
        startFrame: Int
    ) async throws -> LipSyncResult {
        var keyframes = try await rhubarb.analyzeToVisemes(
            audioURL: audioURL,
            fps: fps,
            dialogueText: dialogueText
        )

        // Offset frames to start position
        if startFrame > 0 {
            keyframes = keyframes.map { kf in
                LipSyncEngine.VisemeKeyframe(
                    frame: kf.frame + startFrame,
                    viseme: kf.viseme,
                    duration: kf.duration
                )
            }
        }

        let maxFrame = keyframes.map { $0.frame + $0.duration }.max() ?? startFrame

        return LipSyncResult(
            source: .rhubarb,
            visemeKeyframes: keyframes,
            durationFrames: maxFrame - startFrame,
            fps: fps
        )
    }

    // MARK: - Syllable Heuristic Path

    /// Generate lip sync from dialogue text using syllable heuristics.
    /// Used as fallback when Rhubarb is not installed.
    static func generateWithSyllableHeuristic(
        text: String,
        estimatedDurationSeconds: Double,
        fps: Int,
        startFrame: Int
    ) -> LipSyncResult {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return LipSyncResult(source: .syllables, visemeKeyframes: [], durationFrames: 0, fps: fps)
        }

        // Estimate syllable count: ~1.5 syllables per word average
        let estimatedSyllables = max(1, Int(Double(words.count) * 1.5))
        let totalFrames = max(1, Int(estimatedDurationSeconds * Double(fps)))
        let framesPerSyllable = max(2, totalFrames / estimatedSyllables)

        // Generate viseme sequence cycling through common mouth shapes
        let visemeCycle: [PrestonBlairViseme] = [.consonant, .ai, .e, .o, .mbp, .rest]
        var keyframes: [LipSyncEngine.VisemeKeyframe] = []

        for i in 0..<estimatedSyllables {
            let frame = startFrame + i * framesPerSyllable
            let remaining = totalFrames - (i * framesPerSyllable)
            let duration = min(framesPerSyllable, remaining)
            guard duration > 0 else { break }

            keyframes.append(LipSyncEngine.VisemeKeyframe(
                frame: frame,
                viseme: visemeCycle[i % visemeCycle.count],
                duration: duration
            ))
        }

        return LipSyncResult(
            source: .syllables,
            visemeKeyframes: keyframes,
            durationFrames: totalFrames,
            fps: fps
        )
    }

    // MARK: - Beat Conversion

    /// Convert viseme keyframes to `CharacterLipsyncBeat` entries for the mouth engine.
    ///
    /// Each keyframe becomes one beat. The mouth engine's `syntheticViseme` will cycle
    /// through its own speech pattern within each beat's frame range.
    static func keyframesToBeats(
        _ keyframes: [LipSyncEngine.VisemeKeyframe],
        mode: String = "speech"
    ) -> [CharacterLipsyncBeat] {
        guard !keyframes.isEmpty else { return [] }

        return keyframes.map { kf in
            CharacterLipsyncBeat(
                startFrame: kf.frame,
                endFrame: kf.frame + kf.duration,
                mode: mode,
                songName: nil
            )
        }
    }

    /// Convenience: generate beats covering the full result as a single span.
    ///
    /// Produces one beat that spans all keyframes, which causes the mouth engine
    /// to run its full speech cycle for the entire duration.
    static func resultToSingleBeat(
        _ result: LipSyncResult,
        startFrame: Int = 0,
        mode: String = "speech"
    ) -> CharacterLipsyncBeat? {
        guard !result.visemeKeyframes.isEmpty else { return nil }
        let first = result.visemeKeyframes.first!
        let last = result.visemeKeyframes.last!
        return CharacterLipsyncBeat(
            startFrame: first.frame,
            endFrame: last.frame + last.duration,
            mode: mode,
            songName: nil
        )
    }

    // MARK: - Audio Duration

    /// Get accurate audio duration using AVFoundation (works for WAV, MP3, AAC, FLAC, etc.)
    static func audioDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
