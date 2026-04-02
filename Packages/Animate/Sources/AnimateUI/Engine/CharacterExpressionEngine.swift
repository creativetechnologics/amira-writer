import Foundation

@available(macOS 26.0, *)
struct CharacterExpressionState: Sendable, Hashable {
    var cue: String
    var intensity: Double
    var browLift: Double
    var browTilt: Double
    var eyeOpen: Double
    var smile: Double
    var blink: Double
    var headPitch: Double

    static let neutral = CharacterExpressionState(
        cue: "neutral",
        intensity: 0,
        browLift: 0,
        browTilt: 0,
        eyeOpen: 1,
        smile: 0,
        blink: 0,
        headPitch: 0
    )

    func withCue(_ cue: String) -> CharacterExpressionState {
        var copy = self
        copy.cue = cue
        return copy
    }

    func applying(_ preset: CharacterPerformanceExpressionPreset) -> CharacterExpressionState {
        CharacterExpressionState(
            cue: cue,
            intensity: intensity,
            browLift: preset.browLift,
            browTilt: preset.browTilt,
            eyeOpen: preset.eyeOpen,
            smile: preset.smile,
            blink: blink,
            headPitch: preset.headPitch
        )
    }
}

@available(macOS 26.0, *)
struct CharacterExpressionEngine: Sendable {
    func state(
        for characterName: String,
        blocking: CharacterBlockingPlan,
        frame: Int,
        liveCue: String?,
        profile: Character3DPerformanceProfile? = nil
    ) -> CharacterExpressionState {
        let cue = normalizedCue(liveCue)
            ?? activeEmotion(in: blocking, frame: frame)
            ?? activeActionHint(in: blocking, frame: frame)
            ?? "neutral"
        let intensity = activeIntensity(in: blocking, frame: frame)
        let canonicalCue = profile?.canonicalExpressionCue(for: cue)
        let behaviorCue = profile?.expressionBehaviorCue(for: cue)
            ?? canonicalCue.flatMap { isSemanticExpressionCue($0) ? $0 : nil }
            ?? cue
        var state = stateForCue(behaviorCue, intensity: intensity)
        if let canonicalCue, canonicalCue.caseInsensitiveCompare(state.cue) != .orderedSame {
            state = state.withCue(canonicalCue)
        }
        state.blink = blinkValue(for: characterName, frame: frame, cue: behaviorCue)
        if behaviorCue == "surprised" || behaviorCue == "shocked" {
            state.blink = 0
        }
        return state
    }
}

@available(macOS 26.0, *)
private extension CharacterExpressionEngine {
    func normalizedCue(_ cue: String?) -> String? {
        CharacterRenderSelectionContext.normalize(cue)
    }

    func activeEmotion(in blocking: CharacterBlockingPlan, frame: Int) -> String? {
        blocking.keyPositions
            .sorted { $0.frame < $1.frame }
            .last(where: { $0.frame <= frame })?
            .emotion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    func activeActionHint(in blocking: CharacterBlockingPlan, frame: Int) -> String? {
        blocking.actingBeats
            .first(where: { $0.startFrame <= frame && frame <= $0.endFrame })?
            .action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    func activeIntensity(in blocking: CharacterBlockingPlan, frame: Int) -> Double {
        blocking.actingBeats
            .first(where: { $0.startFrame <= frame && frame <= $0.endFrame })?
            .intensity ?? 0.4
    }

    func stateForCue(_ cue: String, intensity: Double) -> CharacterExpressionState {
        let normalizedIntensity = max(0.2, min(1.0, intensity))
        switch cue {
        case _ where cue.contains("joy") || cue.contains("happy") || cue.contains("hope") || cue.contains("warm"):
            return CharacterExpressionState(cue: "joy", intensity: normalizedIntensity, browLift: 0.28, browTilt: -0.08, eyeOpen: 0.92, smile: 0.75, blink: 0, headPitch: -0.04)
        case _ where cue.contains("sad") || cue.contains("grief") || cue.contains("worry") || cue.contains("tired"):
            return CharacterExpressionState(cue: "sad", intensity: normalizedIntensity, browLift: -0.18, browTilt: 0.24, eyeOpen: 0.66, smile: -0.18, blink: 0, headPitch: 0.1)
        case _ where cue.contains("angry") || cue.contains("fury") || cue.contains("intense") || cue.contains("determined"):
            return CharacterExpressionState(cue: cue.contains("determined") ? "determined" : "angry", intensity: normalizedIntensity, browLift: -0.22, browTilt: -0.25, eyeOpen: 0.85, smile: -0.08, blink: 0, headPitch: -0.03)
        case _ where cue.contains("surprise") || cue.contains("shocked") || cue.contains("alarm"):
            return CharacterExpressionState(cue: "surprised", intensity: normalizedIntensity, browLift: 0.4, browTilt: 0, eyeOpen: 1.2, smile: 0.02, blink: 0, headPitch: -0.02)
        case _ where cue.contains("listen") || cue.contains("curious") || cue.contains("concern"):
            return CharacterExpressionState(cue: "attentive", intensity: normalizedIntensity, browLift: 0.12, browTilt: 0.1, eyeOpen: 1.0, smile: 0.06, blink: 0, headPitch: 0.02)
        default:
            return .neutral
        }
    }

    func blinkValue(for characterName: String, frame: Int, cue: String) -> Double {
        let seed = abs(characterName.lowercased().hashValue % 11) + 5
        let period = max(18, seed * 6)
        let phase = frame % period
        if phase == period - 1 || phase == period - 2 {
            return cue == "joy" ? 0.4 : 0.9
        }
        return 0
    }

    func isSemanticExpressionCue(_ cue: String) -> Bool {
        [
            "joy", "happy", "hope", "warm", "smile",
            "sad", "grief", "worry", "tired",
            "angry", "fury", "intense", "determined",
            "surprised", "surprise", "shocked", "alarm",
            "attentive", "listen", "curious", "concern",
            "neutral", "rest", "default"
        ].contains { cue.contains($0) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
