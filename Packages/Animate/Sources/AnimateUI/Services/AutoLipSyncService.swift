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

    /// Generate lip sync from dialogue text using phoneme-aware word heuristics.
    /// Used as fallback when Rhubarb is not installed.
    ///
    /// Maps common English phoneme patterns to Preston-Blair visemes and distributes
    /// them proportionally to word length, with brief rest frames between words.
    static func generateWithSyllableHeuristic(
        text: String,
        estimatedDurationSeconds: Double,
        fps: Int,
        startFrame: Int
    ) -> LipSyncResult {
        let words = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return LipSyncResult(source: .syllables, visemeKeyframes: [], durationFrames: 0, fps: fps)
        }

        let totalFrames = max(1, Int(estimatedDurationSeconds * Double(fps)))

        // Estimate character budget: allocate frames by word length.
        // Reserve ~17% of total for inter-word rest gaps.
        let restBudgetFraction = 0.17
        let speechFrames = max(1, Int(Double(totalFrames) * (1.0 - restBudgetFraction)))
        let totalCharacters = words.reduce(0) { $0 + $1.count }
        let restFramesPerGap = max(1, Int(Double(totalFrames) * restBudgetFraction / Double(max(words.count, 1))))

        var keyframes: [LipSyncEngine.VisemeKeyframe] = []
        var cursor = startFrame

        for (wordIndex, word) in words.enumerated() {
            // Frames allocated to this word, proportional to character count.
            let wordFraction = totalCharacters > 0
                ? Double(word.count) / Double(totalCharacters)
                : 1.0 / Double(words.count)
            let wordFrames = max(2, Int(Double(speechFrames) * wordFraction))

            // Produce 1–3 visemes per word depending on length.
            let visemesForWord = phonemeVisemes(for: word)
            let framesPerViseme = max(2, wordFrames / visemesForWord.count)

            for (vIdx, viseme) in visemesForWord.enumerated() {
                let isLastViseme = vIdx == visemesForWord.count - 1
                let duration = isLastViseme
                    ? max(2, wordFrames - vIdx * framesPerViseme)
                    : framesPerViseme
                guard cursor + duration <= startFrame + totalFrames else { break }
                keyframes.append(LipSyncEngine.VisemeKeyframe(
                    frame: cursor,
                    viseme: viseme,
                    duration: duration
                ))
                cursor += duration
            }

            // Brief rest between words (skip after last word).
            if wordIndex < words.count - 1 {
                let restDuration = min(restFramesPerGap, max(1, startFrame + totalFrames - cursor))
                guard cursor + restDuration <= startFrame + totalFrames else { break }
                keyframes.append(LipSyncEngine.VisemeKeyframe(
                    frame: cursor,
                    viseme: .rest,
                    duration: restDuration
                ))
                cursor += restDuration
            }
        }

        return LipSyncResult(
            source: .syllables,
            visemeKeyframes: keyframes,
            durationFrames: totalFrames,
            fps: fps
        )
    }

    // MARK: - Phoneme-aware viseme mapping

    /// Maps an English word to an ordered sequence of Preston-Blair visemes.
    /// Longer words get more visemes; single-syllable words get 1–2.
    private static func phonemeVisemes(for word: String) -> [PrestonBlairViseme] {
        let lower = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !lower.isEmpty else { return [.rest] }

        var visemes: [PrestonBlairViseme] = []

        // Leading consonant cluster → first viseme.
        if lower.hasPrefix("wh") || lower.hasPrefix("qu") {
            visemes.append(.wq)
        } else if lower.hasPrefix("sh") || lower.hasPrefix("ch") || lower.hasPrefix("zh") {
            visemes.append(.e)
        } else if lower.hasPrefix("f") || lower.hasPrefix("v") || lower.hasPrefix("ph") {
            visemes.append(.fv)
        } else if lower.hasPrefix("m") || lower.hasPrefix("b") || lower.hasPrefix("p") {
            visemes.append(.mbp)
        } else if lower.hasPrefix("l") || lower.hasPrefix("n") {
            visemes.append(.l)
        } else if lower.hasPrefix("w") {
            visemes.append(.wq)
        }

        // Vowel nucleus → primary open viseme.
        let vowelViseme = dominantVowelViseme(lower)
        visemes.append(vowelViseme)

        // Trailing consonant → closing viseme for longer words.
        if lower.count >= 5 {
            if lower.hasSuffix("ght") || lower.hasSuffix("t") || lower.hasSuffix("d") || lower.hasSuffix("nt") {
                visemes.append(.consonant)
            } else if lower.hasSuffix("m") || lower.hasSuffix("b") || lower.hasSuffix("p") {
                visemes.append(.mbp)
            } else if lower.hasSuffix("l") || lower.hasSuffix("n") {
                visemes.append(.l)
            } else if lower.hasSuffix("f") || lower.hasSuffix("v") {
                visemes.append(.fv)
            }
        }

        // Deduplicate consecutive identical visemes.
        var deduped: [PrestonBlairViseme] = []
        for v in visemes where deduped.last != v {
            deduped.append(v)
        }

        return deduped.isEmpty ? [vowelViseme] : deduped
    }

    /// Returns the dominant vowel viseme for a word based on vowel digraph patterns.
    private static func dominantVowelViseme(_ lower: String) -> PrestonBlairViseme {
        // Check digraphs first (order matters — longer patterns before shorter ones).
        if lower.contains("oo") || lower.contains("ew") || lower.contains("ue") { return .u }
        if lower.contains("ou") || lower.contains("ow") || lower.contains("oa") { return .o }
        if lower.contains("ee") || lower.contains("ea") || lower.contains("ey") { return .e }
        if lower.contains("ai") || lower.contains("ay") { return .ai }
        if lower.contains("sh") || lower.contains("ch") { return .e }

        // Single vowels.
        if lower.contains("o") { return .o }
        if lower.contains("u") { return .u }
        if lower.contains("e") { return .e }
        if lower.contains("i") || lower.contains("a") { return .ai }

        // Default cycle for consonant-heavy words.
        let defaultCycle: [PrestonBlairViseme] = [.rest, .mbp, .ai, .e, .o, .rest]
        let idx = lower.unicodeScalars.first.map { Int($0.value) % defaultCycle.count } ?? 0
        return defaultCycle[idx]
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
