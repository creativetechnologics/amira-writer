import Foundation

/// Comprehensive emotion preset library with blending and compound emotion support
@available(macOS 26.0, *)
struct EmotionLibrary: Sendable {

    /// A single expression preset with all face parameters
    struct ExpressionPreset: Codable, Sendable, Identifiable {
        var id: String  // canonical name
        var displayName: String
        var category: EmotionCategory
        var aliases: [String]
        var browLift: Double
        var browTilt: Double
        var eyeOpen: Double
        var smile: Double
        var headPitch: Double

        /// Blend this preset with another at a given ratio (0 = self, 1 = other)
        func blended(with other: ExpressionPreset, ratio: Double) -> ExpressionPreset {
            let t = max(0, min(1, ratio))
            let s = 1 - t
            return ExpressionPreset(
                id: t < 0.5 ? id : other.id,
                displayName: t < 0.5 ? displayName : other.displayName,
                category: t < 0.5 ? category : other.category,
                aliases: [],
                browLift: browLift * s + other.browLift * t,
                browTilt: browTilt * s + other.browTilt * t,
                eyeOpen: eyeOpen * s + other.eyeOpen * t,
                smile: smile * s + other.smile * t,
                headPitch: headPitch * s + other.headPitch * t
            )
        }

        /// Apply intensity scaling (0 = neutral, 1 = full expression)
        func withIntensity(_ intensity: Double) -> ExpressionPreset {
            let i = max(0, min(1, intensity))
            return ExpressionPreset(
                id: id,
                displayName: displayName,
                category: category,
                aliases: aliases,
                browLift: browLift * i,
                browTilt: browTilt * i,
                eyeOpen: 1.0 + (eyeOpen - 1.0) * i,  // eyeOpen defaults to 1.0
                smile: smile * i,
                headPitch: headPitch * i
            )
        }
    }

    enum EmotionCategory: String, Codable, Sendable, CaseIterable {
        case positive       // joy, love, pride, relief
        case negative       // sad, angry, fear, disgust
        case surprise       // surprise, shock, awe
        case social         // attentive, skeptical, smug
        case neutral        // neutral, rest, contemplative
        case compound       // bittersweet, nervous excitement
        case microExpression // brief flickers
    }

    // MARK: - Core Presets

    static let presets: [ExpressionPreset] = [
        // === POSITIVE ===
        ExpressionPreset(
            id: "joy", displayName: "Joy",
            category: .positive, aliases: ["happy", "glad", "cheerful"],
            browLift: 0.28, browTilt: -0.08, eyeOpen: 0.92, smile: 0.75, headPitch: 0.05
        ),
        ExpressionPreset(
            id: "love", displayName: "Love",
            category: .positive, aliases: ["adoring", "tender", "affectionate"],
            browLift: 0.15, browTilt: 0.05, eyeOpen: 0.85, smile: 0.45, headPitch: 0.08
        ),
        ExpressionPreset(
            id: "pride", displayName: "Pride",
            category: .positive, aliases: ["proud", "confident", "triumphant"],
            browLift: 0.1, browTilt: -0.12, eyeOpen: 0.88, smile: 0.35, headPitch: -0.15
        ),
        ExpressionPreset(
            id: "relief", displayName: "Relief",
            category: .positive, aliases: ["relieved", "grateful"],
            browLift: 0.2, browTilt: 0.0, eyeOpen: 0.78, smile: 0.3, headPitch: 0.1
        ),
        ExpressionPreset(
            id: "excitement", displayName: "Excitement",
            category: .positive, aliases: ["excited", "thrilled", "eager"],
            browLift: 0.35, browTilt: -0.05, eyeOpen: 1.1, smile: 0.65, headPitch: -0.05
        ),
        ExpressionPreset(
            id: "hopeful", displayName: "Hopeful",
            category: .positive, aliases: ["hope", "optimistic", "warm"],
            browLift: 0.22, browTilt: 0.06, eyeOpen: 0.95, smile: 0.28, headPitch: 0.06
        ),

        // === NEGATIVE ===
        ExpressionPreset(
            id: "sad", displayName: "Sad",
            category: .negative, aliases: ["grief", "sorrow", "melancholy", "dejected"],
            browLift: -0.18, browTilt: 0.24, eyeOpen: 0.66, smile: -0.18, headPitch: 0.12
        ),
        ExpressionPreset(
            id: "angry", displayName: "Angry",
            category: .negative, aliases: ["fury", "rage", "furious"],
            browLift: -0.22, browTilt: -0.25, eyeOpen: 0.85, smile: -0.08, headPitch: -0.08
        ),
        ExpressionPreset(
            id: "fear", displayName: "Fear",
            category: .negative, aliases: ["afraid", "scared", "terrified", "frightened"],
            browLift: 0.3, browTilt: 0.2, eyeOpen: 1.15, smile: -0.15, headPitch: 0.05
        ),
        ExpressionPreset(
            id: "disgust", displayName: "Disgust",
            category: .negative, aliases: ["disgusted", "revolted", "repulsed"],
            browLift: -0.1, browTilt: -0.15, eyeOpen: 0.7, smile: -0.3, headPitch: -0.06
        ),
        ExpressionPreset(
            id: "contempt", displayName: "Contempt",
            category: .negative, aliases: ["scornful", "disdainful"],
            browLift: 0.05, browTilt: -0.18, eyeOpen: 0.82, smile: -0.12, headPitch: -0.1
        ),
        ExpressionPreset(
            id: "worried", displayName: "Worried",
            category: .negative, aliases: ["anxious", "nervous", "uneasy", "worry"],
            browLift: 0.1, browTilt: 0.22, eyeOpen: 0.9, smile: -0.1, headPitch: 0.04
        ),
        ExpressionPreset(
            id: "frustrated", displayName: "Frustrated",
            category: .negative, aliases: ["annoyed", "irritated", "exasperated"],
            browLift: -0.15, browTilt: -0.18, eyeOpen: 0.8, smile: -0.15, headPitch: -0.04
        ),
        ExpressionPreset(
            id: "tired", displayName: "Tired",
            category: .negative, aliases: ["exhausted", "weary", "fatigued"],
            browLift: -0.12, browTilt: 0.08, eyeOpen: 0.55, smile: -0.05, headPitch: 0.08
        ),

        // === SURPRISE ===
        ExpressionPreset(
            id: "surprised", displayName: "Surprised",
            category: .surprise, aliases: ["shocked", "startled", "astonished"],
            browLift: 0.4, browTilt: 0.0, eyeOpen: 1.2, smile: 0.0, headPitch: -0.05
        ),
        ExpressionPreset(
            id: "awe", displayName: "Awe",
            category: .surprise, aliases: ["amazed", "wonder", "awed"],
            browLift: 0.35, browTilt: 0.05, eyeOpen: 1.1, smile: 0.12, headPitch: 0.08
        ),

        // === SOCIAL ===
        ExpressionPreset(
            id: "attentive", displayName: "Attentive",
            category: .social, aliases: ["listening", "curious", "interested", "listen"],
            browLift: 0.12, browTilt: 0.1, eyeOpen: 1.0, smile: 0.06, headPitch: 0.04
        ),
        ExpressionPreset(
            id: "skeptical", displayName: "Skeptical",
            category: .social, aliases: ["doubtful", "suspicious", "dubious"],
            browLift: -0.05, browTilt: -0.2, eyeOpen: 0.82, smile: -0.06, headPitch: -0.04
        ),
        ExpressionPreset(
            id: "smug", displayName: "Smug",
            category: .social, aliases: ["smirk", "self-satisfied", "cocky"],
            browLift: 0.08, browTilt: -0.1, eyeOpen: 0.8, smile: 0.25, headPitch: -0.1
        ),
        ExpressionPreset(
            id: "determined", displayName: "Determined",
            category: .social, aliases: ["resolute", "focused", "intense"],
            browLift: -0.08, browTilt: -0.15, eyeOpen: 0.92, smile: 0.0, headPitch: -0.06
        ),
        ExpressionPreset(
            id: "sympathetic", displayName: "Sympathetic",
            category: .social, aliases: ["compassionate", "concerned", "empathetic"],
            browLift: 0.12, browTilt: 0.18, eyeOpen: 0.88, smile: 0.08, headPitch: 0.06
        ),
        ExpressionPreset(
            id: "shy", displayName: "Shy",
            category: .social, aliases: ["bashful", "timid", "embarrassed"],
            browLift: 0.1, browTilt: 0.12, eyeOpen: 0.72, smile: 0.15, headPitch: 0.12
        ),

        // === NEUTRAL ===
        ExpressionPreset(
            id: "neutral", displayName: "Neutral",
            category: .neutral, aliases: ["rest", "default", "blank"],
            browLift: 0, browTilt: 0, eyeOpen: 1.0, smile: 0, headPitch: 0
        ),
        ExpressionPreset(
            id: "contemplative", displayName: "Contemplative",
            category: .neutral, aliases: ["pensive", "thoughtful", "reflective"],
            browLift: -0.04, browTilt: 0.08, eyeOpen: 0.85, smile: 0.0, headPitch: 0.06
        ),
        ExpressionPreset(
            id: "serene", displayName: "Serene",
            category: .neutral, aliases: ["calm", "peaceful", "tranquil"],
            browLift: 0.04, browTilt: 0.0, eyeOpen: 0.82, smile: 0.1, headPitch: 0.04
        ),

        // === COMPOUND ===
        ExpressionPreset(
            id: "bittersweet", displayName: "Bittersweet",
            category: .compound, aliases: ["nostalgic", "wistful"],
            browLift: 0.05, browTilt: 0.15, eyeOpen: 0.78, smile: 0.2, headPitch: 0.06
        ),
        ExpressionPreset(
            id: "nervousExcitement", displayName: "Nervous Excitement",
            category: .compound, aliases: ["jittery", "butterflies"],
            browLift: 0.25, browTilt: 0.1, eyeOpen: 1.05, smile: 0.3, headPitch: 0.0
        ),
        ExpressionPreset(
            id: "guiltySadness", displayName: "Guilty Sadness",
            category: .compound, aliases: ["ashamed", "remorseful", "guilty"],
            browLift: -0.1, browTilt: 0.2, eyeOpen: 0.65, smile: -0.12, headPitch: 0.15
        ),
        ExpressionPreset(
            id: "reluctantDetermination", displayName: "Reluctant Determination",
            category: .compound, aliases: ["grim resolve", "duty-bound"],
            browLift: -0.06, browTilt: 0.08, eyeOpen: 0.88, smile: -0.04, headPitch: -0.04
        ),

        // === MICRO-EXPRESSIONS ===
        ExpressionPreset(
            id: "microSmirk", displayName: "Micro Smirk",
            category: .microExpression, aliases: ["flash smirk", "brief smile"],
            browLift: 0.02, browTilt: -0.03, eyeOpen: 0.95, smile: 0.18, headPitch: 0.0
        ),
        ExpressionPreset(
            id: "microFlinch", displayName: "Micro Flinch",
            category: .microExpression, aliases: ["flash flinch", "brief wince"],
            browLift: 0.15, browTilt: 0.08, eyeOpen: 0.7, smile: -0.06, headPitch: 0.03
        ),
    ]

    // MARK: - Lookup

    /// Resolve a cue string to the best matching preset
    static func resolve(_ cue: String) -> ExpressionPreset? {
        let normalized = cue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact ID match
        if let preset = presets.first(where: { $0.id == normalized }) {
            return preset
        }

        // Alias match
        if let preset = presets.first(where: { $0.aliases.contains(normalized) }) {
            return preset
        }

        // Substring match (e.g., "very happy" matches "happy" alias of joy)
        for preset in presets {
            let allNames = [preset.id] + preset.aliases
            for name in allNames {
                if normalized.contains(name) || name.contains(normalized) {
                    return preset
                }
            }
        }

        return nil
    }

    /// Get all presets in a category
    static func presets(in category: EmotionCategory) -> [ExpressionPreset] {
        presets.filter { $0.category == category }
    }

    // MARK: - Blending

    /// Create a compound expression by blending two named presets
    static func blend(_ cueA: String, _ cueB: String, ratio: Double = 0.5) -> ExpressionPreset? {
        guard let a = resolve(cueA), let b = resolve(cueB) else { return nil }
        return a.blended(with: b, ratio: ratio)
    }

    // MARK: - Transition Curves

    /// Generate interpolated expression states for a smooth transition
    /// Returns (frameCount) evenly spaced states from `from` to `to`
    static func transition(
        from: ExpressionPreset,
        to: ExpressionPreset,
        frameCount: Int
    ) -> [ExpressionPreset] {
        guard frameCount > 1 else { return [to] }
        return (0..<frameCount).map { i in
            let t = Double(i) / Double(frameCount - 1)
            // Use smoothstep for natural-looking transitions
            let smooth = t * t * (3 - 2 * t)
            return from.blended(with: to, ratio: smooth)
        }
    }

    // MARK: - Micro-Expressions

    /// Generate a brief micro-expression flash (appears and fades over given frame count)
    /// Peak intensity at 30% of duration, then gradual fade
    static func microExpression(
        preset: ExpressionPreset,
        durationFrames: Int,
        peakIntensity: Double = 0.6
    ) -> [ExpressionPreset] {
        guard durationFrames > 0 else { return [] }
        let peakFrame = Int(Double(durationFrames) * 0.3)

        return (0..<durationFrames).map { frame in
            let intensity: Double
            if frame <= peakFrame {
                // Ramp up
                let t = peakFrame > 0 ? Double(frame) / Double(peakFrame) : 1.0
                intensity = t * peakIntensity
            } else {
                // Fade out
                let remaining = durationFrames - peakFrame
                let t = remaining > 0 ? Double(frame - peakFrame) / Double(remaining) : 1.0
                intensity = peakIntensity * (1 - t)
            }
            return preset.withIntensity(intensity)
        }
    }
}
