import Foundation
import ProjectKit

// MARK: - Script Card Importer
//
// Projects existing bracket markup in a song's lyrics into structured
// `SongScriptCards`. This runs every time a project is loaded so the
// Write workspace can show structured cards even for legacy projects
// that have never been migrated. The lyrics text itself is not modified;
// the importer only reads.
//
// Flow:
//   1. Numbered `[[a.s.sub.dir - …]]` markup → `LegacyDirectionCard`.
//   2. Canonical Animate DSL `[camera: …]` and friends → `ScriptShotCard`
//      (or, when the tag is `action`, an `ActionCard`).
//   3. Single-bracket prose `[ … ]` (anything not picked up above) →
//      `ActionCard`.
//
// The `originalRawMarkup` substring is preserved on every card so the
// DSL exporter can round-trip cleanly without lossy reconstruction.

enum ScriptCardImporter {

    // MARK: Public API

    static func importLyrics(_ lyrics: String, songRelativePath: String) -> SongScriptCards {
        let nsLyrics = lyrics as NSString
        let lineOffsets = computeLineOffsets(in: lyrics)

        // 1. Numbered directions.
        let parsedDirections = DirectionParser.parseDirections(
            from: lyrics,
            songPath: songRelativePath
        )
        let directionRanges = DirectionParser.directionRanges(in: lyrics)

        let legacyCards: [LegacyDirectionCard] = zip(parsedDirections, directionRanges)
            .map { direction, range in
                LegacyDirectionCard(
                    address: direction.address.displayString,
                    descriptionText: direction.descriptionText,
                    lyricAnchor: anchor(
                        forRange: range,
                        in: lyrics,
                        nsLyrics: nsLyrics,
                        lineOffsets: lineOffsets
                    ),
                    originalRawMarkup: direction.rawMarkup
                )
            }

        // 2. Canonical Animate DSL — split shot vs action vs other.
        let canonicalRanges = AnimatePromptParser.canonicalPromptRanges(in: lyrics)
        var shotCards: [ScriptShotCard] = []
        var actionCardsFromDSL: [ActionCard] = []

        for range in canonicalRanges {
            let raw = nsLyrics.substring(with: range)
            guard let parsed = BracketDSLParser.parse(raw) else { continue }
            let lyricAnchor = anchor(
                forRange: range,
                in: lyrics,
                nsLyrics: nsLyrics,
                lineOffsets: lineOffsets
            )
            switch parsed.tag {
            case "camera", "cinematography":
                shotCards.append(makeShotCard(parsed: parsed, raw: raw, anchor: lyricAnchor))
            case "action":
                actionCardsFromDSL.append(
                    ActionCard(
                        text: parsed.primary,
                        lyricAnchor: lyricAnchor,
                        originalRawMarkup: raw,
                        tags: tagSetFrom(parameters: parsed.parameters)
                    )
                )
            default:
                // Tags we don't yet card-ify get parked as actions so
                // they survive round-tripping unchanged.
                actionCardsFromDSL.append(
                    ActionCard(
                        text: "\(parsed.tag): \(parsed.primary)",
                        lyricAnchor: lyricAnchor,
                        originalRawMarkup: raw,
                        tags: tagSetFrom(parameters: parsed.parameters)
                    )
                )
            }
        }

        // 3. Plain `[ ... ]` storyboarding prose.
        let proseRanges = StoryboardPromptParser.promptRanges(in: lyrics)
        let plainActionCards: [ActionCard] = proseRanges.map { range in
            let raw = nsLyrics.substring(with: range)
            let inner = stripOuterBrackets(raw)
            return ActionCard(
                text: inner,
                lyricAnchor: anchor(
                    forRange: range,
                    in: lyrics,
                    nsLyrics: nsLyrics,
                    lineOffsets: lineOffsets
                ),
                originalRawMarkup: raw
            )
        }

        let allActions = (actionCardsFromDSL + plainActionCards)
            .sorted { ($0.lyricAnchor?.startLine ?? 0) < ($1.lyricAnchor?.startLine ?? 0) }

        let scene = ScriptScene(
            label: nil,
            lyricAnchor: nil,
            directions: legacyCards,
            actions: allActions,
            shots: shotCards
        )

        return SongScriptCards(
            songRelativePath: songRelativePath,
            scenes: scene.directions.isEmpty
                && scene.actions.isEmpty
                && scene.shots.isEmpty
                ? []
                : [scene]
        )
    }

    // MARK: Card construction

    private static func makeShotCard(
        parsed: BracketDSL,
        raw: String,
        anchor: LyricAnchor?
    ) -> ScriptShotCard {
        let timing = timingSpecFrom(parameters: parsed.parameters)
        let camera = CameraSpec(
            shotSize: parsed.parameters["size"]
                ?? parsed.parameters["to"]
                ?? parsed.parameters["from"],
            movement: parsed.primary.isEmpty ? nil : parsed.primary,
            focus: parsed.parameters["focus"] ?? parsed.parameters["subject"],
            intent: parsed.parameters["intent"],
            label: parsed.parameters["label"],
            notes: parsed.parameters["notes"]
        )
        let tags = tagSetFrom(parameters: parsed.parameters)
        return ScriptShotCard(
            label: parsed.parameters["label"],
            direction: parsed.parameters["intent"] ?? "",
            action: "",
            camera: camera,
            tags: tags,
            timing: timing,
            lyricAnchor: anchor,
            status: .importedLegacy,
            provenance: CardProvenance(
                source: .importedLegacy,
                originalRawMarkup: raw
            )
        )
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

    // MARK: Tokenisation

    private static func splitList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    private static func stripOuterBrackets(_ raw: String) -> String {
        BracketDSLParser.stripOuterBrackets(raw)
    }

    // MARK: Anchoring

    private static func computeLineOffsets(in text: String) -> [Int] {
        var offsets: [Int] = [0]
        let nsString = text as NSString
        let length = nsString.length
        for index in 0..<length {
            if nsString.character(at: index) == 0x000A {
                offsets.append(index + 1)
            }
        }
        return offsets
    }

    private static func lineNumber(forCharacter index: Int, lineOffsets: [Int]) -> Int {
        var resolved = 0
        for (idx, offset) in lineOffsets.enumerated() {
            if offset <= index { resolved = idx } else { break }
        }
        return resolved
    }

    private static func anchor(
        forRange range: NSRange,
        in lyrics: String,
        nsLyrics: NSString,
        lineOffsets: [Int]
    ) -> LyricAnchor? {
        guard range.location != NSNotFound, range.length >= 0 else { return nil }
        let startLine = lineNumber(forCharacter: range.location, lineOffsets: lineOffsets)
        let endLocation = max(range.location, range.location + range.length - 1)
        let endLine = lineNumber(forCharacter: endLocation, lineOffsets: lineOffsets)
        let excerpt = excerptForLineRange(
            startLine: startLine,
            endLine: endLine,
            lineOffsets: lineOffsets,
            nsLyrics: nsLyrics
        )
        return LyricAnchor(startLine: startLine, endLine: endLine, excerpt: excerpt)
    }

    private static func excerptForLineRange(
        startLine: Int,
        endLine: Int,
        lineOffsets: [Int],
        nsLyrics: NSString
    ) -> String {
        guard startLine < lineOffsets.count else { return "" }
        let startOffset = lineOffsets[startLine]
        let endOffset: Int
        if endLine + 1 < lineOffsets.count {
            endOffset = lineOffsets[endLine + 1] - 1
        } else {
            endOffset = nsLyrics.length
        }
        let length = max(0, endOffset - startOffset)
        guard startOffset + length <= nsLyrics.length else { return "" }
        let raw = nsLyrics.substring(with: NSRange(location: startOffset, length: length))
        let firstNonEmpty = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)
        let display = (firstNonEmpty ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return display.count > 120 ? String(display.prefix(120)) + "…" : display
    }
}
