import Foundation

// MARK: - Structured Script Document
//
// The Write middle pane needs a live model that treats shots as editable spans
// over lyric text instead of as raw bracket substrings. The `.ows` lyrics field
// remains the compatibility format; this model is the editor-facing projection.

public struct ScriptTextAnchor: Codable, Sendable, Equatable, Hashable {
    /// UTF-16 offset in `StructuredScriptDocument.visibleText`.
    public var offset: Int

    public init(offset: Int) {
        self.offset = max(0, offset)
    }
}

public enum StructuredHiddenMarkupKind: String, Codable, Sendable {
    case technical
    case action
    case lyricSpeaker
}

public struct StructuredHiddenMarkup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: StructuredHiddenMarkupKind
    public var anchor: ScriptTextAnchor
    public var rawMarkup: String
    public var sourceOrder: Int

    public init(
        id: UUID = UUID(),
        kind: StructuredHiddenMarkupKind,
        anchor: ScriptTextAnchor,
        rawMarkup: String,
        sourceOrder: Int
    ) {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.rawMarkup = rawMarkup
        self.sourceOrder = sourceOrder
    }
}

public struct StructuredShotSpan: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var card: ScriptShotCard
    public var startAnchor: ScriptTextAnchor
    /// Derived in v1 from the next shot's start. Stored so renderers do not
    /// need to recompute extents for every paint pass.
    public var endAnchor: ScriptTextAnchor
    public var originalRawMarkup: String
    public var sourceOrder: Int

    public init(
        id: UUID,
        card: ScriptShotCard,
        startAnchor: ScriptTextAnchor,
        endAnchor: ScriptTextAnchor,
        originalRawMarkup: String,
        sourceOrder: Int
    ) {
        self.id = id
        self.card = card
        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
        self.originalRawMarkup = originalRawMarkup
        self.sourceOrder = sourceOrder
    }
}

public struct StructuredLyricBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var speakerName: String
    public var text: String
    public var technicalPrefix: String
    public var anchor: ScriptTextAnchor
    public var originalRawMarkup: String
    public var sourceOrder: Int
    public var preservesImportedRaw: Bool

    public init(
        id: UUID,
        speakerName: String,
        text: String,
        technicalPrefix: String = "",
        anchor: ScriptTextAnchor,
        originalRawMarkup: String,
        sourceOrder: Int,
        preservesImportedRaw: Bool = true
    ) {
        self.id = id
        self.speakerName = speakerName
        self.text = text
        self.technicalPrefix = technicalPrefix
        self.anchor = anchor
        self.originalRawMarkup = originalRawMarkup
        self.sourceOrder = sourceOrder
        self.preservesImportedRaw = preservesImportedRaw
    }
}

public struct StructuredScriptDocument: Codable, Sendable, Equatable {
    public var visibleText: String
    public var shots: [StructuredShotSpan]
    public var hiddenMarkup: [StructuredHiddenMarkup]
    public var lyricBlocks: [StructuredLyricBlock]

    public init(
        visibleText: String = "",
        shots: [StructuredShotSpan] = [],
        hiddenMarkup: [StructuredHiddenMarkup] = [],
        lyricBlocks: [StructuredLyricBlock] = []
    ) {
        self.visibleText = visibleText
        self.shots = shots
        self.hiddenMarkup = hiddenMarkup
        self.lyricBlocks = lyricBlocks
    }

    public var visibleLength: Int {
        (visibleText as NSString).length
    }

    public func recomputingShotExtents() -> StructuredScriptDocument {
        var copy = self
        copy.shots.sort {
            if $0.startAnchor.offset == $1.startAnchor.offset {
                return $0.sourceOrder < $1.sourceOrder
            }
            return $0.startAnchor.offset < $1.startAnchor.offset
        }
        let length = copy.visibleLength
        for index in copy.lyricBlocks.indices {
            copy.lyricBlocks[index].anchor.offset = max(
                0,
                min(copy.lyricBlocks[index].anchor.offset, length)
            )
        }
        copy.lyricBlocks.sort {
            if $0.anchor.offset == $1.anchor.offset {
                return $0.sourceOrder < $1.sourceOrder
            }
            return $0.anchor.offset < $1.anchor.offset
        }
        for index in copy.shots.indices {
            let start = max(0, min(copy.shots[index].startAnchor.offset, length))
            let end = index + 1 < copy.shots.count
                ? copy.shots[index + 1].startAnchor.offset
                : length
            copy.shots[index].startAnchor.offset = start
            copy.shots[index].endAnchor.offset = max(start, min(end, length))
        }
        return copy
    }
}

public enum StructuredScriptDocumentProjector {
    private struct HiddenEvent {
        enum Kind {
            case camera
            case technical
            case action
            case lyricSpeaker
            case lyricBlock
        }

        var range: NSRange
        var rawMarkup: String
        var kind: Kind
        var sourceOrder: Int
        var speakerName: String? = nil
        var lyricText: String? = nil
        var lyricTechnicalPrefix: String? = nil
    }

    private struct Insertion {
        var offset: Int
        var sourceOrder: Int
        var text: String
    }

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
        let tags = technicalTags.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?<!\\[)\\[((?:\(tags))\\s*:[^\\[\\]]+)\\](?!\\])",
            options: [.caseInsensitive]
        )
    }()

    private static let technicalCurlyPattern: NSRegularExpression = {
        let tags = technicalTags.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?<!\\{)\\{((?:\(tags))\\s*:[\\s\\S]*?)\\}(?!\\})",
            options: [.caseInsensitive]
        )
    }()

    private static let actionBracketPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<!\[)\[(action\s*:[^\[\]]+)\](?!\])"#,
            options: [.caseInsensitive]
        )
    }()

    private static let actionCurlyPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<!\{)\{(action\s*:[\s\S]*?)\}(?!\})"#,
            options: [.caseInsensitive]
        )
    }()

    private static let plainBracketPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<!\[)\[([^\[\]]+)\](?!\])"#,
            options: [.caseInsensitive]
        )
    }()

    private static let lyricSpeakerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?m)^[ \t]*([A-Z][A-Z0-9 ._'’\-]*(?:\([A-Za-z0-9 ._'’\-]+\)[A-Z0-9 ._'’\-]*)*):(?=[ \t]*(?:\r?\n|$))"#,
            options: []
        )
    }()

    private static let tripleBraceMetaBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{\{([A-Za-z][A-Za-z0-9_\-:]*)\}\}\}[\s\S]*?\{\{\{/[A-Za-z][A-Za-z0-9_\-:]*\}\}\}\s*"#,
            options: []
        )
    }()

    private static let technicalTags = [
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
    ]

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

    public static func parse(
        _ rawText: String,
        hideLyricSpeakerCues: Bool = false
    ) -> StructuredScriptDocument {
        let nsRaw = rawText as NSString
        let fullRange = NSRange(location: 0, length: nsRaw.length)
        let cameraRanges = (cameraBracketPattern.matches(in: rawText, range: fullRange).map(\.range)
            + legacyCameraCurlyPattern.matches(in: rawText, range: fullRange).map(\.range))
        let technicalRanges = (technicalBracketPattern.matches(in: rawText, range: fullRange).map(\.range)
            + technicalCurlyPattern.matches(in: rawText, range: fullRange).map(\.range))
        let actionRanges = (actionBracketPattern.matches(in: rawText, range: fullRange).map(\.range)
            + actionCurlyPattern.matches(in: rawText, range: fullRange).map(\.range))
        let plainActionRanges = plainBracketPattern.matches(in: rawText, range: fullRange)
            .map(\.range)
            .filter { isPlainActionMarkup(nsRaw.substring(with: $0)) }
        let tripleBraceMetaBlockRanges = tripleBraceMetaBlockPattern.matches(in: rawText, range: fullRange)
            .map(\.range)

        var sourceOrder = 0
        var events: [HiddenEvent] = []
        for range in cameraRanges {
            events.append(
                HiddenEvent(
                    range: range,
                    rawMarkup: nsRaw.substring(with: range),
                    kind: .camera,
                    sourceOrder: sourceOrder
                )
            )
            sourceOrder += 1
        }
        for range in technicalRanges {
            events.append(
                HiddenEvent(
                    range: range,
                    rawMarkup: nsRaw.substring(with: range),
                    kind: .technical,
                    sourceOrder: sourceOrder
                )
            )
            sourceOrder += 1
        }
        for range in actionRanges {
            events.append(
                HiddenEvent(
                    range: range,
                    rawMarkup: nsRaw.substring(with: range),
                    kind: .action,
                    sourceOrder: sourceOrder
                )
            )
            sourceOrder += 1
        }
        for range in plainActionRanges {
            events.append(
                HiddenEvent(
                    range: range,
                    rawMarkup: nsRaw.substring(with: range),
                    kind: .action,
                    sourceOrder: sourceOrder
                )
            )
            sourceOrder += 1
        }
        for range in tripleBraceMetaBlockRanges {
            events.append(
                HiddenEvent(
                    range: range,
                    rawMarkup: nsRaw.substring(with: range),
                    kind: .technical,
                    sourceOrder: sourceOrder
                )
            )
            sourceOrder += 1
        }
        if hideLyricSpeakerCues {
            events.append(
                contentsOf: lyricBlockEvents(
                    in: rawText,
                    nsRaw: nsRaw,
                    startingSourceOrder: sourceOrder
                )
            )
        }

        events.sort {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }
        for index in events.indices {
            events[index].sourceOrder = index
        }

        var visible = ""
        var rawCursor = 0
        var visibleCursor = 0
        var shots: [StructuredShotSpan] = []
        var hidden: [StructuredHiddenMarkup] = []
        var lyricBlocks: [StructuredLyricBlock] = []

        for event in events {
            guard event.range.location >= rawCursor else { continue }
            if event.range.location > rawCursor {
                let range = NSRange(location: rawCursor, length: event.range.location - rawCursor)
                let chunk = nsRaw.substring(with: range)
                visible += chunk
                visibleCursor += (chunk as NSString).length
            }

            let anchor = ScriptTextAnchor(offset: visibleCursor)
            switch event.kind {
            case .camera:
                let card = makeShotCard(
                    rawMarkup: event.rawMarkup,
                    fallbackID: deterministicUUID(seed: "\(event.range.location):\(event.rawMarkup)")
                )
                shots.append(
                    StructuredShotSpan(
                        id: card.id,
                        card: card,
                        startAnchor: anchor,
                        endAnchor: anchor,
                        originalRawMarkup: event.rawMarkup,
                        sourceOrder: event.sourceOrder
                    )
                )
            case .technical:
                hidden.append(
                    StructuredHiddenMarkup(
                        id: deterministicUUID(seed: "\(event.range.location):\(event.rawMarkup)"),
                        kind: .technical,
                        anchor: anchor,
                        rawMarkup: event.rawMarkup,
                        sourceOrder: event.sourceOrder
                    )
                )
            case .action:
                hidden.append(
                    StructuredHiddenMarkup(
                        id: deterministicUUID(seed: "\(event.range.location):\(event.rawMarkup)"),
                        kind: .action,
                        anchor: anchor,
                        rawMarkup: event.rawMarkup,
                        sourceOrder: event.sourceOrder
                    )
                )
            case .lyricSpeaker:
                hidden.append(
                    StructuredHiddenMarkup(
                        id: deterministicUUID(seed: "\(event.range.location):\(event.rawMarkup)"),
                        kind: .lyricSpeaker,
                        anchor: anchor,
                        rawMarkup: event.rawMarkup,
                        sourceOrder: event.sourceOrder
                    )
                )
            case .lyricBlock:
                lyricBlocks.append(
                    StructuredLyricBlock(
                        id: deterministicUUID(seed: "\(event.range.location):\(event.rawMarkup)"),
                        speakerName: event.speakerName ?? lyricSpeakerName(from: event.rawMarkup),
                        text: event.lyricText ?? "",
                        technicalPrefix: event.lyricTechnicalPrefix ?? "",
                        anchor: anchor,
                        originalRawMarkup: event.rawMarkup,
                        sourceOrder: event.sourceOrder
                    )
                )
            }

            rawCursor = NSMaxRange(event.range)
        }

        if rawCursor < nsRaw.length {
            visible += nsRaw.substring(with: NSRange(location: rawCursor, length: nsRaw.length - rawCursor))
        }

        return StructuredScriptDocument(
            visibleText: visible,
            shots: shots,
            hiddenMarkup: hidden,
            lyricBlocks: lyricBlocks
        )
        .recomputingShotExtents()
    }

    public static func export(_ document: StructuredScriptDocument) -> String {
        let normalized = document.recomputingShotExtents()
        let visible = normalized.visibleText as NSString
        let length = visible.length
        var insertions: [Insertion] = []

        for shot in normalized.shots {
            insertions.append(
                Insertion(
                    offset: max(0, min(shot.startAnchor.offset, length)),
                    sourceOrder: shot.sourceOrder,
                    text: renderMarkup(for: shot)
                )
            )
        }

        for hidden in normalized.hiddenMarkup {
            insertions.append(
                Insertion(
                    offset: max(0, min(hidden.anchor.offset, length)),
                    sourceOrder: hidden.sourceOrder,
                    text: hidden.rawMarkup
                )
            )
        }

        for lyricBlock in normalized.lyricBlocks {
            insertions.append(
                Insertion(
                    offset: max(0, min(lyricBlock.anchor.offset, length)),
                    sourceOrder: lyricBlock.sourceOrder,
                    text: renderLyricBlock(lyricBlock)
                )
            )
        }

        insertions.sort {
            if $0.offset == $1.offset {
                return $0.sourceOrder < $1.sourceOrder
            }
            return $0.offset < $1.offset
        }

        var result = ""
        var cursor = 0
        for insertion in insertions {
            if insertion.offset > cursor {
                result += visible.substring(
                    with: NSRange(location: cursor, length: insertion.offset - cursor)
                )
                cursor = insertion.offset
            }
            result += insertion.text
        }
        if cursor < length {
            result += visible.substring(with: NSRange(location: cursor, length: length - cursor))
        }
        return result
    }

    public static func applyingVisibleEdit(
        to document: StructuredScriptDocument,
        affectedRange: NSRange,
        replacementString: String,
        resultingVisibleText: String
    ) -> StructuredScriptDocument {
        let replacementLength = (replacementString as NSString).length
        let resultingLength = (resultingVisibleText as NSString).length
        var copy = document
        copy.visibleText = resultingVisibleText

        for index in copy.shots.indices {
            copy.shots[index].startAnchor.offset = shiftedOffset(
                copy.shots[index].startAnchor.offset,
                affectedRange: affectedRange,
                replacementLength: replacementLength,
                resultingLength: resultingLength
            )
        }
        for index in copy.hiddenMarkup.indices {
            copy.hiddenMarkup[index].anchor.offset = shiftedOffset(
                copy.hiddenMarkup[index].anchor.offset,
                affectedRange: affectedRange,
                replacementLength: replacementLength,
                resultingLength: resultingLength
            )
        }
        for index in copy.lyricBlocks.indices {
            copy.lyricBlocks[index].anchor.offset = shiftedOffset(
                copy.lyricBlocks[index].anchor.offset,
                affectedRange: affectedRange,
                replacementLength: replacementLength,
                resultingLength: resultingLength
            )
        }

        return copy.recomputingShotExtents()
    }

    public static func movingShotStart(
        in document: StructuredScriptDocument,
        shotID: UUID,
        to targetOffset: Int
    ) -> StructuredScriptDocument {
        var copy = document.recomputingShotExtents()
        guard let index = copy.shots.firstIndex(where: { $0.id == shotID }) else { return document }
        let lowerBound = index > 0 ? copy.shots[index - 1].startAnchor.offset : 0
        let upperBound = index + 1 < copy.shots.count
            ? copy.shots[index + 1].startAnchor.offset
            : copy.visibleLength
        copy.shots[index].startAnchor.offset = max(lowerBound, min(targetOffset, upperBound))
        markShotAsPositionEdited(&copy.shots[index])
        return copy.recomputingShotExtents()
    }

    public static func movingShotEnd(
        in document: StructuredScriptDocument,
        shotID: UUID,
        to targetOffset: Int
    ) -> StructuredScriptDocument {
        let normalized = document.recomputingShotExtents()
        guard let index = normalized.shots.firstIndex(where: { $0.id == shotID }),
              index + 1 < normalized.shots.count else { return document }
        return movingShotStart(
            in: normalized,
            shotID: normalized.shots[index + 1].id,
            to: targetOffset
        )
    }

    public static func removingShot(
        from document: StructuredScriptDocument,
        shotID: UUID
    ) -> StructuredScriptDocument {
        var copy = document
        copy.shots.removeAll { $0.id == shotID }
        return copy.recomputingShotExtents()
    }

    public static func addingShot(
        to document: StructuredScriptDocument,
        at targetOffset: Int,
        sourceOrder: Int? = nil
    ) -> StructuredScriptDocument {
        var copy = document.recomputingShotExtents()
        let order = sourceOrder ?? nextSourceOrder(in: copy)
        let clampedOffset = max(0, min(targetOffset, copy.visibleLength))
        let card = ScriptShotCard(
            label: "New Shot",
            direction: "",
            camera: CameraSpec(
                shotSize: "medium",
                movement: "hold",
                label: "New Shot"
            ),
            status: .manual,
            provenance: CardProvenance(source: .manual)
        )
        copy.shots.append(
            StructuredShotSpan(
                id: card.id,
                card: card,
                startAnchor: ScriptTextAnchor(offset: clampedOffset),
                endAnchor: ScriptTextAnchor(offset: clampedOffset),
                originalRawMarkup: "",
                sourceOrder: order
            )
        )
        return copy.recomputingShotExtents()
    }

    public static func addingLyricBlock(
        to document: StructuredScriptDocument,
        at targetOffset: Int,
        speakerName: String = "SINGER",
        text: String = "New lyric"
    ) -> StructuredScriptDocument {
        var copy = document.recomputingShotExtents()
        let order = nextSourceOrder(in: copy)
        copy.lyricBlocks.append(
            StructuredLyricBlock(
                id: UUID(),
                speakerName: speakerName,
                text: text,
                anchor: ScriptTextAnchor(offset: max(0, min(targetOffset, copy.visibleLength))),
                originalRawMarkup: "",
                sourceOrder: order,
                preservesImportedRaw: false
            )
        )
        return copy.recomputingShotExtents()
    }

    public static func addingAction(
        to document: StructuredScriptDocument,
        at targetOffset: Int,
        text: String = "New action"
    ) -> StructuredScriptDocument {
        var copy = document.recomputingShotExtents()
        let order = nextSourceOrder(in: copy)
        copy.hiddenMarkup.append(
            StructuredHiddenMarkup(
                id: UUID(),
                kind: .action,
                anchor: ScriptTextAnchor(offset: max(0, min(targetOffset, copy.visibleLength))),
                rawMarkup: "[\(text)]",
                sourceOrder: order
            )
        )
        return copy.recomputingShotExtents()
    }

    public static func updatingShotCard(
        in document: StructuredScriptDocument,
        shotID: UUID,
        card: ScriptShotCard
    ) -> StructuredScriptDocument {
        var copy = document
        guard let index = copy.shots.firstIndex(where: { $0.id == shotID }) else {
            return document
        }
        copy.shots[index].card = card
        copy.shots[index].originalRawMarkup = ""
        markShotAsPositionEdited(&copy.shots[index])
        return copy.recomputingShotExtents()
    }

    public static func updatingHiddenMarkup(
        in document: StructuredScriptDocument,
        markupID: UUID,
        rawMarkup: String
    ) -> StructuredScriptDocument {
        var copy = document
        guard let index = copy.hiddenMarkup.firstIndex(where: { $0.id == markupID }) else {
            return document
        }
        copy.hiddenMarkup[index].rawMarkup = rawMarkup
        return copy.recomputingShotExtents()
    }

    public static func actionDisplayText(from rawMarkup: String) -> String {
        let trimmed = rawMarkup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = BracketDSLParser.parse(trimmed) else {
            return stripOuterMarkup(trimmed)
        }
        guard normalized(parsed.tag) == "action" else {
            return stripOuterMarkup(trimmed)
        }

        if let description = parsed.parameters["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            let subject = displaySubjectName(parsed.primary)
            guard !subject.isEmpty,
                  !hasDisplaySubjectPrefix(description, subject: subject) else {
                return description
            }
            return "\(subject) \(description)"
        }

        let primary = parsed.primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty {
            return displaySubjectName(primary)
        }

        return stripOuterMarkup(trimmed)
    }

    public static func actionRawMarkup(displayText: String, preserving rawMarkup: String) -> String {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = BracketDSLParser.parse(rawMarkup),
              normalized(parsed.tag) == "action" else {
            return "[\(text)]"
        }

        var params = parsed.parameters
        var primary = parsed.primary
        if params.keys.contains("description") {
            params["description"] = strippingDisplaySubjectPrefix(from: text, subject: parsed.primary)
        } else {
            primary = text
        }

        var parts: [String] = ["action: \(quoteIfNeeded(primary))"]
        for key in params.keys.sorted() {
            guard let value = params[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            parts.append("\(key)=\(quoteIfNeeded(value))")
        }
        return "[\(parts.joined(separator: " | "))]"
    }

    public static func isShotDirectionActionMarkup(_ rawMarkup: String) -> Bool {
        guard let parsed = BracketDSLParser.parse(rawMarkup),
              normalized(parsed.tag) == "action" else {
            return false
        }
        let description = parsed.parameters["description"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !description.isEmpty
    }

    public static func updatingLyricSpeaker(
        in document: StructuredScriptDocument,
        markerID: UUID,
        speakerName: String
    ) -> StructuredScriptDocument {
        var copy = document
        if let blockIndex = copy.lyricBlocks.firstIndex(where: { $0.id == markerID }) {
            copy.lyricBlocks[blockIndex].speakerName = speakerName
            copy.lyricBlocks[blockIndex].preservesImportedRaw = false
            return copy.recomputingShotExtents()
        }
        guard let index = copy.hiddenMarkup.firstIndex(where: {
            $0.id == markerID && $0.kind == .lyricSpeaker
        }) else { return document }
        copy.hiddenMarkup[index].rawMarkup = renderLyricSpeakerCue(speakerName)
        return copy.recomputingShotExtents()
    }

    public static func lyricSpeakerName(from rawMarkup: String) -> String {
        rawMarkup.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func renderLyricSpeakerCue(_ speakerName: String) -> String {
        let trimmed = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "SINGER" : trimmed
        return "\(fallback.uppercased()):"
    }

    public static func updatingLyricBlockText(
        in document: StructuredScriptDocument,
        blockID: UUID,
        text: String
    ) -> StructuredScriptDocument {
        var copy = document
        guard let index = copy.lyricBlocks.firstIndex(where: { $0.id == blockID }) else {
            return document
        }
        copy.lyricBlocks[index].text = text
        copy.lyricBlocks[index].preservesImportedRaw = false
        return copy.recomputingShotExtents()
    }

    public static func movingLyricBlock(
        in document: StructuredScriptDocument,
        blockID: UUID,
        to targetOffset: Int
    ) -> StructuredScriptDocument {
        var copy = document.recomputingShotExtents()
        guard let index = copy.lyricBlocks.firstIndex(where: { $0.id == blockID }) else {
            return document
        }
        copy.lyricBlocks[index].anchor.offset = max(0, min(targetOffset, copy.visibleLength))
        copy.lyricBlocks[index].preservesImportedRaw = false
        return copy.recomputingShotExtents()
    }

    private static func nextSourceOrder(in document: StructuredScriptDocument) -> Int {
        let shotMax = document.shots.map(\.sourceOrder).max() ?? 0
        let hiddenMax = document.hiddenMarkup.map(\.sourceOrder).max() ?? 0
        let lyricMax = document.lyricBlocks.map(\.sourceOrder).max() ?? 0
        return max(shotMax, hiddenMax, lyricMax) + 1
    }

    private static func shiftedOffset(
        _ offset: Int,
        affectedRange: NSRange,
        replacementLength: Int,
        resultingLength: Int
    ) -> Int {
        let start = affectedRange.location
        let end = NSMaxRange(affectedRange)
        let delta = replacementLength - affectedRange.length
        let shifted: Int
        if affectedRange.length == 0 {
            shifted = offset < start ? offset : offset + replacementLength
        } else if offset < start {
            shifted = offset
        } else if offset <= end {
            shifted = start + replacementLength
        } else {
            shifted = offset + delta
        }
        return max(0, min(shifted, resultingLength))
    }

    private static func renderMarkup(for shot: StructuredShotSpan) -> String {
        if shot.card.status == .importedLegacy,
           let raw = shot.card.provenance.originalRawMarkup,
           !raw.isEmpty {
            return raw
        }
        return ScriptCardDSLExporter.renderShot(
            shot.card,
            includeID: true,
            preserveImportedRaw: false
        )
    }

    private static func renderLyricBlock(_ block: StructuredLyricBlock) -> String {
        if block.preservesImportedRaw, !block.originalRawMarkup.isEmpty {
            return block.originalRawMarkup
        }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let technicalPrefix = block.technicalPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            renderLyricSpeakerCue(block.speakerName),
            ""
        ]
        if !technicalPrefix.isEmpty {
            lines.append(technicalPrefix)
        }
        if !text.isEmpty {
            lines.append(text)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func stripOuterMarkup(_ rawMarkup: String) -> String {
        BracketDSLParser.stripOuterBrackets(rawMarkup)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displaySubjectName(_ rawValue: String) -> String {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let words = cleaned.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return cleaned }
        return words.map { word in
            guard let first = word.first else { return word }
            let rest = word.dropFirst()
            return String(first).uppercased() + rest.lowercased()
        }
        .joined(separator: " ")
    }

    private static func hasDisplaySubjectPrefix(_ description: String, subject: String) -> Bool {
        let normalizedDescription = description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedSubject = subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedSubject.isEmpty else { return false }
        return normalizedDescription == normalizedSubject
            || normalizedDescription.hasPrefix("\(normalizedSubject) ")
            || normalizedDescription.hasPrefix("\(normalizedSubject):")
            || normalizedDescription.hasPrefix("\(normalizedSubject),")
    }

    private static func strippingDisplaySubjectPrefix(from displayText: String, subject rawSubject: String) -> String {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = displaySubjectName(rawSubject)
        guard !subject.isEmpty,
              hasDisplaySubjectPrefix(text, subject: subject) else {
            return text
        }

        let nsText = text as NSString
        let subjectLength = (subject as NSString).length
        guard nsText.length >= subjectLength else { return text }
        var location = subjectLength
        while location < nsText.length {
            let character = nsText.character(at: location)
            if character == 0x20 || character == 0x09 || character == 0x3A || character == 0x2C {
                location += 1
            } else {
                break
            }
        }
        guard location < nsText.length else { return text }
        return nsText.substring(from: location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\"\"" }
        let needsQuotes = trimmed.contains { character in
            character.isWhitespace || character == "|" || character == "\""
        }
        guard needsQuotes else { return trimmed }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func isPlainActionMarkup(_ rawMarkup: String) -> Bool {
        guard let parsed = BracketDSLParser.parse(rawMarkup) else {
            return true
        }
        let tag = normalized(parsed.tag)
        if tag == "camera" || tag == "cinematography" || tag == "action" {
            return false
        }
        return !technicalTags.contains(tag)
    }

    private static func lyricBlockEvents(
        in rawText: String,
        nsRaw: NSString,
        startingSourceOrder: Int
    ) -> [HiddenEvent] {
        let fullRange = NSRange(location: 0, length: nsRaw.length)
        let speakerMatches = lyricSpeakerPattern.matches(in: rawText, range: fullRange)
        guard !speakerMatches.isEmpty else { return [] }

        var events: [HiddenEvent] = []
        var sourceOrder = startingSourceOrder

        for (index, match) in speakerMatches.enumerated() {
            let speakerCueRange = match.range
            let speakerName = lyricSpeakerName(from: nsRaw.substring(with: speakerCueRange))
            let segmentStart = NSMaxRange(speakerCueRange)
            let segmentEnd = index + 1 < speakerMatches.count
                ? speakerMatches[index + 1].range.location
                : nsRaw.length
            guard segmentEnd > segmentStart else { continue }

            let segmentRange = NSRange(location: segmentStart, length: segmentEnd - segmentStart)
            let segment = nsRaw.substring(with: segmentRange) as NSString
            let paragraphRanges = nonEmptyParagraphRanges(in: segment as String)

            for (paragraphIndex, paragraphRange) in paragraphRanges.enumerated() {
                let rawRange: NSRange
                if paragraphIndex == 0 {
                    rawRange = NSRange(
                        location: speakerCueRange.location,
                        length: segmentStart + NSMaxRange(paragraphRange) - speakerCueRange.location
                    )
                } else {
                    rawRange = NSRange(
                        location: segmentStart + paragraphRange.location,
                        length: paragraphRange.length
                    )
                }
                guard rawRange.location >= 0, NSMaxRange(rawRange) <= nsRaw.length else { continue }
                let paragraphText = segment.substring(with: paragraphRange)
                let splitParagraph = splitLyricParagraph(paragraphText)
                let lyricText = splitParagraph.lyricText
                guard !lyricText.isEmpty else { continue }
                let separatedTechnicalPrefix = paragraphIndex > 0 && !splitParagraph.technicalPrefix.isEmpty
                let eventRange = separatedTechnicalPrefix
                    ? lyricOnlyRange(
                        in: paragraphText,
                        absoluteParagraphLocation: segmentStart + paragraphRange.location
                    ) ?? rawRange
                    : rawRange
                events.append(
                    HiddenEvent(
                        range: eventRange,
                        rawMarkup: nsRaw.substring(with: eventRange),
                        kind: .lyricBlock,
                        sourceOrder: sourceOrder,
                        speakerName: speakerName,
                        lyricText: lyricText,
                        lyricTechnicalPrefix: separatedTechnicalPrefix ? "" : splitParagraph.technicalPrefix
                    )
                )
                sourceOrder += 1
            }
        }

        return events
    }

    private static func splitLyricParagraph(_ rawText: String) -> (technicalPrefix: String, lyricText: String) {
        var technicalLines: [String] = []
        var lyricLines: [String] = []
        var reachedLyricText = false

        for line in rawText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reachedLyricText, isLeadingTechnicalCueLine(trimmed) {
                technicalLines.append(trimmed)
                continue
            }
            if !trimmed.isEmpty {
                reachedLyricText = true
            }
            if reachedLyricText {
                lyricLines.append(line)
            }
        }

        return (
            technicalPrefix: technicalLines.joined(separator: "\n"),
            lyricText: normalizeLyricCardText(
                lyricLines.joined(separator: "\n")
            )
        )
    }

    private static func lyricOnlyRange(
        in paragraphText: String,
        absoluteParagraphLocation: Int
    ) -> NSRange? {
        let nsText = paragraphText as NSString
        var cursor = 0
        var lyricStart: Int?
        var lyricEnd = 0

        while cursor < nsText.length {
            var lineEnd = cursor
            while lineEnd < nsText.length {
                let char = nsText.character(at: lineEnd)
                if char == 0x000A || char == 0x000D { break }
                lineEnd += 1
            }

            var nextCursor = lineEnd
            if nextCursor < nsText.length {
                let char = nsText.character(at: nextCursor)
                nextCursor += 1
                if char == 0x000D,
                   nextCursor < nsText.length,
                   nsText.character(at: nextCursor) == 0x000A {
                    nextCursor += 1
                }
            }

            let lineRange = NSRange(location: cursor, length: lineEnd - cursor)
            let line = nsText.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if lyricStart == nil {
                if trimmed.isEmpty || isLeadingTechnicalCueLine(trimmed) {
                    cursor = nextCursor
                    continue
                }
                lyricStart = cursor
            }
            lyricEnd = nextCursor
            cursor = nextCursor
        }

        guard let start = lyricStart, lyricEnd > start else { return nil }
        return NSRange(
            location: absoluteParagraphLocation + start,
            length: lyricEnd - start
        )
    }

    private static func normalizeLyricCardText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLeadingTechnicalCueLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            return true
        }
        if line.hasPrefix("{") && line.hasSuffix("}") {
            return true
        }
        return false
    }

    public static func nonEmptyParagraphRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        var paragraphStart: Int?
        var paragraphEnd = 0

        while cursor < nsText.length {
            var lineEnd = cursor
            while lineEnd < nsText.length {
                let char = nsText.character(at: lineEnd)
                if char == 0x000A || char == 0x000D { break }
                lineEnd += 1
            }

            var nextCursor = lineEnd
            if nextCursor < nsText.length {
                let char = nsText.character(at: nextCursor)
                nextCursor += 1
                if char == 0x000D, nextCursor < nsText.length, nsText.character(at: nextCursor) == 0x000A {
                    nextCursor += 1
                }
            }

            let lineRange = NSRange(location: cursor, length: lineEnd - cursor)
            let line = nsText.substring(with: lineRange)
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if isBlank {
                if let start = paragraphStart, paragraphEnd > start {
                    ranges.append(NSRange(location: start, length: paragraphEnd - start))
                }
                paragraphStart = nil
                paragraphEnd = 0
            } else {
                if paragraphStart == nil {
                    paragraphStart = cursor
                }
                paragraphEnd = nextCursor
            }

            cursor = max(nextCursor, cursor + 1)
        }

        if let start = paragraphStart, paragraphEnd > start {
            ranges.append(NSRange(location: start, length: paragraphEnd - start))
        }

        return ranges
    }

    private static func markShotAsPositionEdited(_ shot: inout StructuredShotSpan) {
        shot.card.status = .manual
        shot.card.provenance = CardProvenance(source: .manual)
    }

    private static func makeShotCard(rawMarkup: String, fallbackID: UUID) -> ScriptShotCard {
        guard let parsed = BracketDSLParser.parse(rawMarkup) else {
            return ScriptShotCard(
                id: fallbackID,
                label: "Camera Direction",
                direction: rawMarkup,
                camera: CameraSpec(notes: rawMarkup),
                status: .importedLegacy,
                provenance: CardProvenance(
                    source: .importedLegacy,
                    originalRawMarkup: rawMarkup
                )
            )
        }

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
            camera: camera,
            tags: tagSet(from: parsed.parameters),
            characterFraming: characterFraming(from: parsed.parameters),
            setting: setting(from: parsed.parameters),
            timing: timingSpec(from: parsed.parameters),
            status: .importedLegacy,
            provenance: CardProvenance(
                source: .importedLegacy,
                originalRawMarkup: rawMarkup
            )
        )
    }

    private static func timingSpec(from parameters: [String: String]) -> TimingSpec {
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

    private static func tagSet(from parameters: [String: String]) -> TagSet {
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

    private static func setting(from parameters: [String: String]) -> ShotSettingSpec {
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

    private static func characterFraming(from parameters: [String: String]) -> ShotCharacterFramingSpec {
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
        let resolved = normalized(value)
        return resolved.isEmpty ? nil : resolved
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
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
