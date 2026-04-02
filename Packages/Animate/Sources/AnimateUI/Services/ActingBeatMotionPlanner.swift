import Foundation

/// Plans motion generation requests from a character's acting beats
@available(macOS 26.0, *)
struct ActingBeatMotionPlanner: Sendable {

    struct PlannedMotion: Sendable {
        let actingBeat: ActingBeat
        let request: HunyuanMotionService.MotionRequest
        let emotionContext: String?
        let characterName: String
        let characterSlug: String
        let estimatedDurationSeconds: Double
    }

    /// Generate motion requests for all acting beats in a blocking plan.
    /// Filters to only actionable beats (skips short or non-motion beats).
    static func plan(
        from blocking: CharacterBlockingPlan,
        fps: Int = 24,
        minimumDurationSeconds: Double = 1.0,
        maximumDurationSeconds: Double = 12.0
    ) -> [PlannedMotion] {
        var results: [PlannedMotion] = []

        for beat in blocking.actingBeats {
            let durationFrames = beat.endFrame - beat.startFrame
            let durationSeconds = Double(durationFrames) / Double(fps)

            // Skip very short beats
            guard durationSeconds >= minimumDurationSeconds else { continue }

            // Skip non-motion actions (pure vocal/internal)
            guard isMotionAction(beat.action) else { continue }

            // Find the active emotion at this beat's start
            let emotion = activeEmotion(at: beat.startFrame, in: blocking)

            // Generate prompt
            let prompt = HunyuanMotionService.motionPrompt(
                for: beat.action,
                characterName: blocking.characterName,
                emotion: emotion,
                intensity: beat.intensity
            )

            // Clamp duration to HY-Motion's supported range
            let clampedDuration = min(maximumDurationSeconds, max(minimumDurationSeconds, durationSeconds))

            let request = HunyuanMotionService.MotionRequest(
                prompt: prompt,
                durationSeconds: clampedDuration,
                cfgScale: cfgScaleForIntensity(beat.intensity)
            )

            results.append(PlannedMotion(
                actingBeat: beat,
                request: request,
                emotionContext: emotion,
                characterName: blocking.characterName,
                characterSlug: blocking.characterSlug,
                estimatedDurationSeconds: clampedDuration
            ))
        }

        return results
    }

    /// Check if an action type involves physical movement (vs pure vocal/internal).
    private static func isMotionAction(_ action: String) -> Bool {
        let nonMotionActions: Set<String> = ["think", "internal", "narrate", "offscreen"]
        return !nonMotionActions.contains(action.lowercased())
    }

    /// Find the active emotion at a given frame from the blocking keyframes.
    private static func activeEmotion(at frame: Int, in blocking: CharacterBlockingPlan) -> String? {
        var activeEmotion: String?
        for kf in blocking.keyPositions {
            if kf.frame <= frame {
                activeEmotion = kf.emotion
            } else {
                break
            }
        }
        // Return nil for neutral/empty emotions
        if let emotion = activeEmotion, !emotion.isEmpty, emotion != "neutral" {
            return emotion
        }
        return nil
    }

    /// Map acting beat intensity to CFG scale.
    /// Higher intensity -> higher guidance (more exaggerated motion).
    private static func cfgScaleForIntensity(_ intensity: Double) -> Double {
        // Map 0.2-1.0 intensity to 5.0-10.0 CFG scale
        let clamped = max(0.2, min(1.0, intensity))
        return 5.0 + (clamped - 0.2) * (5.0 / 0.8)
    }

    /// Estimate total generation time for a plan.
    static func estimatedGenerationTime(for plan: [PlannedMotion]) -> TimeInterval {
        // Rough estimate: ~60 seconds per motion clip on HuggingFace free tier
        Double(plan.count) * 60.0
    }

    /// Summary of a planned motion set.
    static func summary(for plan: [PlannedMotion]) -> String {
        guard !plan.isEmpty else { return "No motions to generate" }
        let totalDuration = plan.reduce(0.0) { $0 + $1.estimatedDurationSeconds }
        let actions = Set(plan.map { $0.actingBeat.action }).sorted()
        return "\(plan.count) motion clip\(plan.count == 1 ? "" : "s") (\(String(format: "%.1f", totalDuration))s total) — \(actions.joined(separator: ", "))"
    }
}
