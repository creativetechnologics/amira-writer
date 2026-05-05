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
    public static func renderShot(
        _ shot: ScriptShotCard,
        includeID: Bool = false,
        preserveImportedRaw: Bool = true
    ) -> String {
        // If the importer preserved the original substring and the card
        // hasn't been edited, prefer the verbatim raw markup. We detect
        // "unedited" by checking that no structured field carries data
        // beyond what the raw string would have produced — simplest proxy
        // is: status == .importedLegacy && originalRawMarkup non-nil.
        if preserveImportedRaw,
           shot.status == .importedLegacy,
           let raw = shot.provenance.originalRawMarkup,
           !raw.isEmpty {
            return raw
        }

        var params: [(String, String)] = []
        if includeID {
            params.append(("id", shot.id.uuidString))
        }
        if let label = nonEmpty(shot.camera.label) {
            params.append(("label", label))
        }
        if let focus = nonEmpty(shot.camera.focus) {
            params.append(("focus", focus))
        }
        if let fromShotSize = nonEmpty(shot.camera.fromShotSize) {
            params.append(("from", fromShotSize))
        }
        if let toShotSize = nonEmpty(shot.camera.toShotSize) {
            params.append(("to", toShotSize))
        }
        let primary = primaryValue(for: shot)
        if let shotSize = nonEmpty(shot.camera.shotSize),
           shotSize != primary,
           nonEmpty(shot.camera.fromShotSize) == nil,
           nonEmpty(shot.camera.toShotSize) == nil {
            params.append(("size", shotSize))
        }
        if let intent = nonEmpty(shot.camera.intent) {
            params.append(("intent", intent))
        }
        if let direction = nonEmpty(shot.direction) {
            params.append(("direction", direction))
        }
        appendSettingParams(shot.setting, into: &params)
        appendTimingParams(shot.timing, into: &params)
        appendTagParams(shot.tags, into: &params)
        appendCharacterFramingParams(shot.characterFraming, into: &params)
        if let notes = nonEmpty(shot.camera.notes) {
            params.append(("notes", notes))
        }

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

    private static func primaryValue(for shot: ScriptShotCard) -> String {
        if let movement = nonEmpty(shot.camera.movement),
           movement != "hold" {
            return movement
        }
        if let shotSize = nonEmpty(shot.camera.shotSize) {
            return shotSize
        }
        return nonEmpty(shot.camera.movement) ?? "hold"
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

    private static func appendSettingParams(
        _ setting: ShotSettingSpec,
        into params: inout [(String, String)]
    ) {
        if let timeOfDay = nonEmpty(setting.timeOfDay) {
            params.append(("time_of_day", timeOfDay))
        }
        if let interiorExterior = nonEmpty(setting.interiorExterior) {
            params.append(("interior_exterior", interiorExterior))
        }
        if let weatherAtmosphere = nonEmpty(setting.weatherAtmosphere) {
            params.append(("weather_atmosphere", weatherAtmosphere))
        }
        if let lightSource = nonEmpty(setting.lightSource) {
            params.append(("light_source", lightSource))
        }
        if let lens = nonEmpty(setting.lens) {
            params.append(("lens", lens))
        }
        if let cameraAngle = nonEmpty(setting.cameraAngle) {
            params.append(("camera_angle", cameraAngle))
        }
        if let depthOfField = nonEmpty(setting.depthOfField) {
            params.append(("depth_of_field", depthOfField))
        }
        if let continuityNotes = nonEmpty(setting.continuityNotes) {
            params.append(("continuity_notes", continuityNotes))
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

    private static func appendCharacterFramingParams(
        _ framing: ShotCharacterFramingSpec,
        into params: inout [(String, String)]
    ) {
        if !framing.left.isEmpty {
            params.append(("character_left", framing.left.joined(separator: ",")))
        }
        if let leftFacing = nonEmpty(framing.leftFacing) {
            params.append(("character_left_facing", leftFacing))
        }
        if !framing.middle.isEmpty {
            params.append(("character_middle", framing.middle.joined(separator: ",")))
        }
        if let middleFacing = nonEmpty(framing.middleFacing) {
            params.append(("character_middle_facing", middleFacing))
        }
        if !framing.right.isEmpty {
            params.append(("character_right", framing.right.joined(separator: ",")))
        }
        if let rightFacing = nonEmpty(framing.rightFacing) {
            params.append(("character_right_facing", rightFacing))
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
