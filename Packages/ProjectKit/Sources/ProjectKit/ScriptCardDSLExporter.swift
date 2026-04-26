import Foundation

// MARK: - Script Card DSL Exporter
//
// Deterministic projection from structured `ScriptShotCard` / `ActionCard`
// / `LegacyDirectionCard` records back to the bracket DSL Animate already
// understands. Used:
//   1. As the compatibility shim feeding Animate's `SceneDirectionParser`
//      until Animate consumes structured records directly.
//   2. As a debug "Show generated DSL" toggle in the Write workspace.
//
// Output must be stable: same input → same string, byte-for-byte. Tests
// rely on this so we can round-trip lyrics → cards → DSL → cards.

public enum ScriptCardDSLExporter {

    // MARK: Public API

    /// Render every card in a scene to bracket DSL, one element per line in
    /// scene order: legacy directions → action cards → shot cards.
    public static func exportDSL(_ scene: ScriptScene) -> String {
        var lines: [String] = []
        for direction in scene.directions {
            lines.append(direction.originalRawMarkup)
        }
        for action in scene.actions {
            lines.append(renderAction(action))
        }
        for shot in scene.shots {
            lines.append(renderShot(shot))
        }
        return lines.joined(separator: "\n")
    }

    /// Render a single shot card to a single `[camera: …]` line.
    public static func renderShot(_ shot: ScriptShotCard) -> String {
        // If the importer preserved the original substring and the card
        // hasn't been edited, prefer the verbatim raw markup. We detect
        // "unedited" by checking that no structured field carries data
        // beyond what the raw string would have produced — simplest proxy
        // is: status == .importedLegacy && originalRawMarkup non-nil.
        if shot.status == .importedLegacy,
           let raw = shot.provenance.originalRawMarkup,
           !raw.isEmpty {
            return raw
        }

        var params: [(String, String)] = []
        if let label = nonEmpty(shot.camera.label) {
            params.append(("label", label))
        }
        if let focus = nonEmpty(shot.camera.focus) {
            params.append(("focus", focus))
        }
        if let shotSize = nonEmpty(shot.camera.shotSize) {
            params.append(("size", shotSize))
        }
        if let intent = nonEmpty(shot.camera.intent) {
            params.append(("intent", intent))
        }
        appendTimingParams(shot.timing, into: &params)
        appendTagParams(shot.tags, into: &params)
        if let notes = nonEmpty(shot.camera.notes) {
            params.append(("notes", notes))
        }

        let primary = nonEmpty(shot.camera.movement) ?? "hold"
        return formatBracket(tag: "camera", primary: primary, params: params)
    }

    /// Render an action card to a `[action: …]` line.
    public static func renderAction(_ action: ActionCard) -> String {
        if !action.originalRawMarkup.isEmpty {
            return action.originalRawMarkup
        }

        var params: [(String, String)] = []
        appendTagParams(action.tags, into: &params)
        return formatBracket(tag: "action", primary: action.text, params: params)
    }

    // MARK: Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func appendTimingParams(
        _ timing: TimingSpec,
        into params: inout [(String, String)]
    ) {
        if let start = timing.startBar, let end = timing.endBar {
            params.append(("bars", "\(start)-\(end)"))
        } else if let start = timing.startBar {
            params.append(("bars", "\(start)"))
        }
        if let start = timing.startBeat, let end = timing.endBeat {
            params.append(("beats", "\(start)-\(end)"))
        } else if let start = timing.startBeat {
            params.append(("beats", "\(start)"))
        }
        if let start = timing.startFrame, let end = timing.endFrame {
            params.append(("frames", "\(start)-\(end)"))
        } else if let start = timing.startFrame {
            params.append(("frames", "\(start)"))
        }
    }

    private static func appendTagParams(
        _ tags: TagSet,
        into params: inout [(String, String)]
    ) {
        if !tags.characters.isEmpty {
            params.append(("characters", tags.characters.joined(separator: ",")))
        }
        if !tags.places.isEmpty {
            params.append(("places", tags.places.joined(separator: ",")))
        }
        if !tags.props.isEmpty {
            params.append(("props", tags.props.joined(separator: ",")))
        }
        if !tags.mood.isEmpty {
            params.append(("mood", tags.mood.joined(separator: ",")))
        }
        if !tags.lighting.isEmpty {
            params.append(("lighting", tags.lighting.joined(separator: ",")))
        }
        if !tags.landmarks.isEmpty {
            params.append(("landmarks", tags.landmarks.joined(separator: ",")))
        }
        if !tags.automation.isEmpty {
            params.append(("automation", tags.automation.joined(separator: ",")))
        }
    }

    private static func formatBracket(
        tag: String,
        primary: String,
        params: [(String, String)]
    ) -> String {
        let primaryClean = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if params.isEmpty {
            return "[\(tag): \(primaryClean)]"
        }
        let kv = params.map { "\($0.0)=\($0.1)" }.joined(separator: " | ")
        return "[\(tag): \(primaryClean) | \(kv)]"
    }
}
