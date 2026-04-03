import Foundation

@available(macOS 26.0, *)
struct CharacterRenderSelectionContext: Sendable, Hashable {
    var preferredAngle: AngleView?
    var preferredPose: CharacterPackagePose?
    var expressionCue: String?
    var actionCue: String?
    var mouthCue: String?

    init(
        preferredAngle: AngleView? = nil,
        preferredPose: CharacterPackagePose? = nil,
        expressionCue: String? = nil,
        actionCue: String? = nil,
        mouthCue: String? = nil
    ) {
        self.preferredAngle = preferredAngle
        self.preferredPose = preferredPose
        self.expressionCue = expressionCue
        self.actionCue = actionCue
        self.mouthCue = mouthCue
    }

    var hasSemanticOverrides: Bool {
        preferredAngle != nil ||
        preferredPose != nil ||
        normalizedExpressionCue != nil ||
        normalizedActionCue != nil ||
        normalizedMouthCue != nil
    }

    var normalizedExpressionCue: String? {
        Self.normalize(expressionCue)
    }

    var normalizedActionCue: String? {
        Self.normalize(actionCue)
    }

    var normalizedMouthCue: String? {
        Self.normalizeMouth(mouthCue)
    }

    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("motion:") {
            return String(trimmed.dropFirst("motion:".count))
        }

        return trimmed
    }

    static func normalizeMouth(_ value: String?) -> String? {
        guard let normalized = normalize(value) else { return nil }

        if normalized.hasPrefix("viseme:") {
            let visemeValue = String(normalized.dropFirst("viseme:".count))
            if let rawValue = Int(visemeValue),
               let viseme = PrestonBlairViseme(rawValue: rawValue) {
                return viseme.token
            }
            return visemeValue
        }

        if let rawValue = Int(normalized),
           let viseme = PrestonBlairViseme(rawValue: rawValue) {
            return viseme.token
        }

        return normalized
    }
}
