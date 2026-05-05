import Foundation
import ProjectKit

// MARK: - Live Shot Markup

struct ScriptCameraMarkupInstance: Equatable, Identifiable {
    var id: UUID { card.id }
    let rawRange: NSRange
    let rawMarkup: String
    let card: ScriptShotCard
}

enum ScriptShotMarkup {
    private static let cameraBracketPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<!\[)\[((?:camera|cinematography)\s*:[^\[\]]+)\](?!\])"#,
            options: [.caseInsensitive]
        )
    }()

    private static let legacyCameraCurlyPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<!\{)\{(camera\s*:[\s\S]*?)\}(?!\})"#,
            options: [.caseInsensitive]
        )
    }()

    private static let technicalBracketPattern: NSRegularExpression = {
        let tags = [
            "scene",
            "enter",
            "exit",
            "move",
            "emotion",
            "gesture",
            "object",
            "object_move",
            "object_state",
            "object_visibility",
            "prop",
            "prop_move",
            "prop_state",
            "prop_visibility",
            "lipsync",
            "pause",
            "sfx",
            "transition"
        ].joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?<!\\[)\\[((?:\(tags))\\s*:[^\\[\\]]+)\\](?!\\])",
            options: [.caseInsensitive]
        )
    }()

    private static let technicalCurlyPattern: NSRegularExpression = {
        let tags = [
            "scene",
            "enter",
            "exit",
            "move",
            "emotion",
            "gesture",
            "object",
            "object_move",
            "object_state",
            "object_visibility",
            "prop",
            "prop_move",
            "prop_state",
            "prop_visibility",
            "lipsync",
            "pause",
            "sfx",
            "transition"
        ].joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?<!\\{)\\{((?:\(tags))\\s*:[\\s\\S]*?)\\}(?!\\})",
            options: [.caseInsensitive]
        )
    }()

    private static let movementValues: Set<String> = [
        "zoom_in",
        "zoom_out",
        "pan_left",
        "pan_right",
        "pan_up",
        "pan_down",
        "track",
        "shake",
        "hold",
        "dolly",
        "dolly_in",
        "dolly_out",
        "truck_left",
        "truck_right",
        "tilt_up",
        "tilt_down",
        "push_in",
        "pull_back"
    ]

    static func cameraInstances(in text: String) -> [ScriptCameraMarkupInstance] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let ranges = (cameraBracketPattern.matches(in: text, range: fullRange).map(\.range)
            + legacyCameraCurlyPattern.matches(in: text, range: fullRange).map(\.range))
            .sorted {
                if $0.location == $1.location { return $0.length < $1.length }
                return $0.location < $1.location
            }

        return ranges.compactMap { range in
            let raw = nsString.substring(with: range)
            let fallbackID = deterministicUUID(seed: "\(range.location):\(raw)")
            let card: ScriptShotCard
            if let parsed = BracketDSLParser.parse(raw) {
                card = makeShotCard(
                    parsed: parsed,
                    raw: raw,
                    fallbackID: fallbackID
                )
            } else {
                card = ScriptShotCard(
                    id: fallbackID,
                    label: "Camera Direction",
                    direction: raw,
                    camera: CameraSpec(notes: raw),
                    status: .importedLegacy,
                    provenance: CardProvenance(
                        source: .importedLegacy,
                        originalRawMarkup: raw
                    )
                )
            }
            return ScriptCameraMarkupInstance(rawRange: range, rawMarkup: raw, card: card)
        }
    }

    static func technicalDirectionRanges(in text: String) -> [NSRange] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        return (technicalBracketPattern.matches(in: text, range: fullRange).map(\.range)
            + technicalCurlyPattern.matches(in: text, range: fullRange).map(\.range))
            .sorted {
                if $0.location == $1.location { return $0.length < $1.length }
                return $0.location < $1.location
            }
    }

    static func makeShotCard(
        parsed: BracketDSL,
        raw: String,
        anchor: LyricAnchor? = nil,
        fallbackID: UUID = UUID()
    ) -> ScriptShotCard {
        let primary = normalized(parsed.primary)
        let isMovement = movementValues.contains(primary)
        let explicitSize = firstNonEmpty(
            parsed.parameters["size"],
            parsed.parameters["shot"],
            parsed.parameters["framing"]
        )
        let fromShotSize = normalizedOptional(parsed.parameters["from"])
        let toShotSize = normalizedOptional(parsed.parameters["to"])
        let shotSize = explicitSize
            ?? (isMovement ? nil : primary.nilIfEmpty)
            ?? toShotSize
            ?? fromShotSize

        let movement = isMovement
            ? primary
            : normalizedOptional(parsed.parameters["movement"])

        let cardID = parsed.parameters["id"]
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? fallbackID

        let camera = CameraSpec(
            shotSize: shotSize,
            fromShotSize: fromShotSize,
            toShotSize: toShotSize,
            movement: movement,
            focus: firstNonEmpty(parsed.parameters["focus"], parsed.parameters["subject"]),
            intent: parsed.parameters["intent"],
            label: parsed.parameters["label"],
            notes: parsed.parameters["notes"]
        )

        return ScriptShotCard(
            id: cardID,
            label: parsed.parameters["label"],
            direction: parsed.parameters["direction"] ?? "",
            action: "",
            camera: camera,
            tags: tagSetFrom(parameters: parsed.parameters),
            characterFraming: characterFramingFrom(parameters: parsed.parameters),
            setting: settingFrom(parameters: parsed.parameters),
            timing: timingSpecFrom(parameters: parsed.parameters),
            lyricAnchor: anchor,
            status: .importedLegacy,
            provenance: CardProvenance(
                source: .importedLegacy,
                originalRawMarkup: raw
            )
        )
    }

    static func editedMarkup(for card: ScriptShotCard) -> String {
        var edited = card
        edited.status = .manual
        edited.provenance = CardProvenance(source: .manual)
        return ScriptCardDSLExporter.renderShot(edited, includeID: true)
    }

    static func replacementCard(
        from card: ScriptShotCard,
        label: String,
        direction: String,
        shotSize: String,
        movement: String,
        focus: String,
        intent: String,
        bars: String,
        notes: String,
        timeOfDay: String = "",
        interiorExterior: String = "",
        weatherAtmosphere: String = "",
        lightSource: String = "",
        lens: String = "",
        cameraAngle: String = "",
        depthOfField: String = "",
        continuityNotes: String = "",
        characters: String,
        characterLeft: String = "",
        characterMiddle: String = "",
        characterRight: String = "",
        characterLeftFacing: String = "",
        characterMiddleFacing: String = "",
        characterRightFacing: String = "",
        places: String,
        props: String,
        mood: String,
        lighting: String,
        landmarks: String
    ) -> ScriptShotCard {
        var updated = card
        let trimmedLabel = label.trimmed.nilIfEmpty
        updated.label = trimmedLabel
        updated.camera.label = trimmedLabel
        updated.camera.shotSize = shotSize.trimmed.nilIfEmpty
        updated.camera.movement = movement.trimmed.nilIfEmpty
        updated.camera.focus = focus.trimmed.nilIfEmpty
        updated.camera.intent = intent.trimmed.nilIfEmpty
        updated.direction = direction.trimmed
        updated.camera.notes = notes.trimmed.nilIfEmpty
        updated.setting = ShotSettingSpec(
            timeOfDay: timeOfDay.trimmed.nilIfEmpty,
            interiorExterior: interiorExterior.trimmed.nilIfEmpty,
            weatherAtmosphere: weatherAtmosphere.trimmed.nilIfEmpty,
            lightSource: lightSource.trimmed.nilIfEmpty,
            lens: lens.trimmed.nilIfEmpty,
            cameraAngle: cameraAngle.trimmed.nilIfEmpty,
            depthOfField: depthOfField.trimmed.nilIfEmpty,
            continuityNotes: continuityNotes.trimmed.nilIfEmpty
        )
        let parsedBars = parseRangePair(bars)
        updated.timing.startBar = parsedBars.start
        updated.timing.endBar = parsedBars.end
        updated.characterFraming = ShotCharacterFramingSpec(
            left: splitList(characterLeft),
            middle: splitList(characterMiddle),
            right: splitList(characterRight),
            leftFacing: characterLeftFacing.trimmed.nilIfEmpty,
            middleFacing: characterMiddleFacing.trimmed.nilIfEmpty,
            rightFacing: characterRightFacing.trimmed.nilIfEmpty
        )
        updated.tags.characters = mergedUnique(
            splitList(characters) + updated.characterFraming.allCharacters
        )
        updated.tags.places = splitList(places)
        updated.tags.props = splitList(props)
        updated.tags.mood = splitList(mood)
        updated.tags.lighting = splitList(lighting)
        updated.tags.landmarks = splitList(landmarks)
        updated.status = .manual
        updated.provenance = CardProvenance(source: .manual)
        return updated
    }

    private static func timingSpecFrom(parameters: [String: String]) -> TimingSpec {
        var spec = TimingSpec()
        if let bars = parameters["bars"] {
            let pair = parseRangePair(bars)
            spec.startBar = pair.start
            spec.endBar = pair.end
        }
        if let beats = parameters["beats"] {
            let pair = parseRangePair(beats)
            spec.startBeat = pair.start
            spec.endBeat = pair.end
        }
        if let frames = parameters["frames"] {
            let pair = parseRangePair(frames)
            spec.startFrame = pair.start
            spec.endFrame = pair.end
        }
        return spec
    }

    private static func tagSetFrom(parameters: [String: String]) -> TagSet {
        TagSet(
            characters: splitList(parameters["characters"]),
            places: splitList(parameters["places"]),
            props: splitList(parameters["props"]),
            mood: splitList(parameters["mood"]),
            lighting: splitList(parameters["lighting"]),
            landmarks: splitList(parameters["landmarks"]),
            automation: splitList(parameters["automation"])
        )
    }

    private static func settingFrom(parameters: [String: String]) -> ShotSettingSpec {
        ShotSettingSpec(
            timeOfDay: firstNonEmpty(
                parameters["time_of_day"],
                parameters["timeOfDay"],
                parameters["tod"]
            ),
            interiorExterior: firstNonEmpty(
                parameters["interior_exterior"],
                parameters["interiorExterior"],
                parameters["int_ext"],
                parameters["intExt"],
                parameters["location_type"]
            ),
            weatherAtmosphere: firstNonEmpty(
                parameters["weather_atmosphere"],
                parameters["weatherAtmosphere"],
                parameters["atmosphere"],
                parameters["weather"]
            ),
            lightSource: firstNonEmpty(
                parameters["light_source"],
                parameters["lightSource"],
                parameters["lighting_source"]
            ),
            lens: firstNonEmpty(
                parameters["lens"]
            ),
            cameraAngle: firstNonEmpty(
                parameters["camera_angle"],
                parameters["cameraAngle"],
                parameters["angle"]
            ),
            depthOfField: firstNonEmpty(
                parameters["depth_of_field"],
                parameters["depthOfField"],
                parameters["dof"]
            ),
            continuityNotes: firstNonEmpty(
                parameters["continuity_notes"],
                parameters["continuityNotes"],
                parameters["continuity"]
            )
        )
    }

    private static func characterFramingFrom(parameters: [String: String]) -> ShotCharacterFramingSpec {
        ShotCharacterFramingSpec(
            left: splitList(firstNonEmpty(
                parameters["character_left"],
                parameters["characterLeft"],
                parameters["characters_left"],
                parameters["left_characters"]
            )),
            middle: splitList(firstNonEmpty(
                parameters["character_middle"],
                parameters["characterMiddle"],
                parameters["characters_middle"],
                parameters["middle_characters"]
            )),
            right: splitList(firstNonEmpty(
                parameters["character_right"],
                parameters["characterRight"],
                parameters["characters_right"],
                parameters["right_characters"]
            )),
            leftFacing: firstNonEmpty(
                parameters["character_left_facing"],
                parameters["characterLeftFacing"],
                parameters["characters_left_facing"],
                parameters["left_character_facing"],
                parameters["left_facing"]
            ),
            middleFacing: firstNonEmpty(
                parameters["character_middle_facing"],
                parameters["characterMiddleFacing"],
                parameters["characters_middle_facing"],
                parameters["middle_character_facing"],
                parameters["middle_facing"]
            ),
            rightFacing: firstNonEmpty(
                parameters["character_right_facing"],
                parameters["characterRightFacing"],
                parameters["characters_right_facing"],
                parameters["right_character_facing"],
                parameters["right_facing"]
            )
        )
    }

    private static func mergedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(trimmed)
        }
        return ordered
    }

    private static func parseRangePair(_ raw: String) -> (start: Int?, end: Int?) {
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        if let dashIndex = cleaned.firstIndex(of: "-") {
            let startStr = cleaned[..<dashIndex]
            let endStr = cleaned[cleaned.index(after: dashIndex)...]
            return (Int(startStr), Int(endStr))
        }
        return (Int(cleaned), nil)
    }

    private static func splitList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let normalized = normalizedOptional(value) {
                return normalized
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .lowercased()
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalized(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func deterministicUUID(seed: String) -> UUID {
        let bytes = Array(seed.utf8)
        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x84222325cbf29ce4
        for byte in bytes {
            a ^= UInt64(byte)
            a &*= 0x100000001b3
            b &+= UInt64(byte) &* 0x9e3779b185ebca87
            b = (b << 7) | (b >> 57)
        }
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: a.bigEndian) { raw in
            for index in 0..<8 { uuidBytes[index] = raw[index] }
        }
        withUnsafeBytes(of: b.bigEndian) { raw in
            for index in 0..<8 { uuidBytes[index + 8] = raw[index] }
        }
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
