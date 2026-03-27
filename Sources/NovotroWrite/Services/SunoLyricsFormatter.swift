import Foundation

enum SunoLyricsFormatter {
    enum SpeakerGender: String, Sendable {
        case male
        case female
        case unknown
    }

    private enum SpeakerRole: Equatable {
        case named(String)
        case duet
        case ensemble
    }

    private enum LineKind {
        case blank
        case ignore
        case speaker(SpeakerRole)
        case section(String)
        case instrumental
        case lyric(String)
    }

    private struct LyricBlock {
        var explicitSection: String?
        var speaker: SpeakerRole?
        var lyrics: [String]
    }

    struct Result: Sendable {
        var formattedText: String
        var speakerLabels: [String: String]
    }

    static func format(librettoText: String?, speakerGenderHints: [String: SpeakerGender] = [:]) -> Result {
        guard let librettoText else {
            return Result(formattedText: "", speakerLabels: [:])
        }

        let cleanedText = stripSynopsis(from: DirectionParser.stripDirections(from: librettoText))
        guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(formattedText: "", speakerLabels: [:])
        }

        let blocks = collectLyricBlocks(lines: cleanedText.components(separatedBy: .newlines))
        guard !blocks.isEmpty else {
            return Result(formattedText: "", speakerLabels: [:])
        }

        let speakers = blocks.compactMap { block -> String? in
            guard case let .named(name)? = block.speaker else { return nil }
            return name
        }
        let speakerMap = buildSpeakerMap(from: speakers, genderHints: speakerGenderHints)
        let hasSpecialSpeaker = blocks.contains { block in
            guard let speaker = block.speaker else { return false }
            switch speaker {
            case .duet, .ensemble:
                return true
            case .named:
                return false
            }
        }
        let shouldEmitSpeakerLabels = speakerMap.count + (hasSpecialSpeaker ? 1 : 0) > 1
        let sections = inferredSections(for: blocks)

        var output: [String] = []
        for (block, section) in zip(blocks, sections) {
            appendBlankLineIfNeeded(&output)
            output.append(section)

            if shouldEmitSpeakerLabels,
               let speakerLabel = displaySpeakerLabel(for: block.speaker, speakerMap: speakerMap) {
                if let last = output.last, !last.isEmpty, !last.hasPrefix("[") {
                    output.append("")
                }
                output.append("[\(speakerLabel)]")
            }

            if !block.lyrics.isEmpty {
                output.append(contentsOf: block.lyrics)
            }
        }

        let compact = collapseBlankLines(output)
        return Result(
            formattedText: compact.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            speakerLabels: speakerMap
        )
    }

    static func speakerGenderHints(from characters: [OPWCharacter]) -> [String: SpeakerGender] {
        var hints: [String: SpeakerGender] = [:]

        for character in characters {
            let normalized = normalizedSpeakerKey(character.name)
            guard !normalized.isEmpty else { continue }

            let combined = "\(character.name) \(character.description)"
            let inferred = inferredGender(for: combined, hints: [:])
            hints[normalized] = inferred

            if let firstToken = normalized.split(separator: " ").first {
                hints[String(firstToken)] = inferred
            }
        }

        return hints
    }

    private static func collectLyricBlocks(lines: [String]) -> [LyricBlock] {
        var blocks: [LyricBlock] = []
        var activeSpeaker: SpeakerRole?
        var pendingSection: String?
        var currentSpeaker: SpeakerRole?
        var currentSection: String?
        var currentLyrics: [String] = []

        func flushCurrentBlock() {
            guard !currentLyrics.isEmpty else {
                currentSpeaker = nil
                currentSection = nil
                return
            }

            blocks.append(LyricBlock(explicitSection: currentSection, speaker: currentSpeaker, lyrics: currentLyrics))
            currentSpeaker = nil
            currentSection = nil
            currentLyrics = []
        }

        for rawLine in lines {
            switch classifyLine(rawLine, allowPlainLyrics: activeSpeaker != nil || !currentLyrics.isEmpty) {
            case .blank:
                flushCurrentBlock()
            case .ignore:
                continue
            case .speaker(let speaker):
                flushCurrentBlock()
                activeSpeaker = speaker
            case .section(let section):
                flushCurrentBlock()
                pendingSection = section
            case .instrumental:
                flushCurrentBlock()
                blocks.append(LyricBlock(explicitSection: "[Instrumental]", speaker: nil, lyrics: []))
            case .lyric(let lyric):
                if currentLyrics.isEmpty {
                    currentSpeaker = currentSpeaker ?? activeSpeaker
                    currentSection = pendingSection
                    pendingSection = nil
                }
                currentLyrics.append(lyric)
            }
        }

        flushCurrentBlock()
        return blocks
    }

    private static func inferredSections(for blocks: [LyricBlock]) -> [String] {
        let signatures = blocks.map { block -> String? in
            guard block.explicitSection == nil, !block.lyrics.isEmpty else { return nil }
            return lyricSignature(for: block.lyrics)
        }

        var signatureCounts: [String: Int] = [:]
        for signature in signatures.compactMap({ $0 }) where !signature.isEmpty {
            signatureCounts[signature, default: 0] += 1
        }

        let automaticVerseCount = blocks.enumerated().reduce(into: 0) { count, entry in
            let (index, block) = entry
            guard block.explicitSection == nil, !block.lyrics.isEmpty else { return }
            let signature = signatures[index] ?? ""
            if signatureCounts[signature, default: 0] <= 1 {
                count += 1
            }
        }

        var verseIndex = 1
        return blocks.enumerated().map { index, block in
            if let explicitSection = block.explicitSection {
                return explicitSection
            }

            if block.lyrics.isEmpty {
                return "[Instrumental]"
            }

            let signature = signatures[index] ?? ""
            if signatureCounts[signature, default: 0] > 1 {
                return "[Chorus]"
            }

            if automaticVerseCount == 1 {
                return "[Verse]"
            }

            defer { verseIndex += 1 }
            return "[Verse \(verseIndex)]"
        }
    }

    private static func classifyLine(_ rawLine: String, allowPlainLyrics: Bool) -> LineKind {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blank }

        if let section = explicitSectionHeader(from: trimmed) {
            return section == "[Instrumental]" ? .instrumental : .section(section)
        }

        if let section = sectionalCue(from: trimmed) {
            return section == "[Instrumental]" ? .instrumental : .section(section)
        }

        if let speaker = speakerRole(from: trimmed) {
            return .speaker(speaker)
        }

        if let lyric = tabbedLyricLine(from: rawLine) {
            return .lyric(lyric)
        }

        if allowPlainLyrics, let lyric = plainLyricLine(from: trimmed) {
            return .lyric(lyric)
        }

        return .ignore
    }

    private static func buildSpeakerMap(from speakers: [String], genderHints: [String: SpeakerGender]) -> [String: String] {
        var result: [String: String] = [:]
        var maleCount = 0
        var femaleCount = 0
        var singerCount = 0

        for speaker in speakers {
            guard result[speaker] == nil else { continue }

            let label: String
            switch inferredGender(for: speaker, hints: genderHints) {
            case .male:
                maleCount += 1
                label = "Male \(maleCount)"
            case .female:
                femaleCount += 1
                label = "Female \(femaleCount)"
            case .unknown:
                singerCount += 1
                label = "Singer \(singerCount)"
            }
            result[speaker] = label
        }

        return result
    }

    private static func displaySpeakerLabel(for speaker: SpeakerRole?, speakerMap: [String: String]) -> String? {
        guard let speaker else { return nil }

        switch speaker {
        case .named(let name):
            return speakerMap[name]
        case .duet:
            return "Duet"
        case .ensemble:
            return "Ensemble"
        }
    }

    private static func inferredGender(for speaker: String, hints: [String: SpeakerGender]) -> SpeakerGender {
        let normalized = normalizedSpeakerKey(speaker)
        if let hinted = hints[normalized], hinted != .unknown {
            return hinted
        }

        let tokens = normalized.split(separator: " ").map(String.init)
        if tokens.count == 1, let hinted = hints[tokens[0]], hinted != .unknown {
            return hinted
        }

        let directMaleTerms: Set<String> = [
            "man", "male", "boy", "father", "dad", "king", "prince", "sir", "mr", "mister", "brother", "son", "husband", "groom"
        ]
        let directFemaleTerms: Set<String> = [
            "woman", "female", "girl", "mother", "mom", "queen", "princess", "lady", "ms", "mrs", "miss", "sister", "daughter", "wife", "bride"
        ]
        if tokens.contains(where: directMaleTerms.contains) { return .male }
        if tokens.contains(where: directFemaleTerms.contains) { return .female }

        let maleNames: Set<String> = [
            "aaron", "adam", "alex", "andrew", "anthony", "ben", "benjamin", "billy", "charles", "chris", "christopher",
            "dan", "daniel", "david", "edward", "eli", "ethan", "frank", "gabriel", "gary", "george", "henry", "isaac",
            "jack", "jacob", "jake", "james", "jason", "jeremy", "jesse", "joel", "john", "johnny", "jon", "jonah",
            "jonathan", "jordan", "joseph", "josh", "joshua", "julian", "kevin", "leo", "logan", "lucas", "luke", "mark",
            "matt", "matthew", "max", "michael", "mike", "nathan", "nicholas", "noah", "oliver", "owen", "paul", "peter",
            "robert", "sam", "samuel", "sebastian", "stephen", "thomas", "tim", "timothy", "victor", "will", "william", "zach"
        ]
        let femaleNames: Set<String> = [
            "abigail", "adele", "alexis", "alice", "alicia", "amira", "amy", "ana", "anna", "ava", "bella", "beth", "caroline",
            "charlotte", "chloe", "claire", "diana", "ella", "emily", "emma", "eva", "faith", "grace", "hannah", "isabel",
            "isabella", "jane", "jessica", "joanna", "julia", "julie", "kate", "katherine", "katie", "laura", "lena", "lily",
            "lucy", "maria", "mary", "maya", "mia", "natalie", "nora", "olivia", "rachel", "rose", "sarah", "sophia",
            "victoria", "violet", "yasmin", "zoe"
        ]

        for token in tokens {
            if maleNames.contains(token) { return .male }
            if femaleNames.contains(token) { return .female }
        }

        return .unknown
    }

    private static func normalizedSpeakerKey(_ speaker: String) -> String {
        speaker
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N} ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSynopsis(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\{\{\{SYNOPSIS\}\}\}[\s\S]*?\{\{\{/SYNOPSIS\}\}\}\s*"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func lyricSignature(for lyrics: [String]) -> String {
        lyrics
            .map { line in
                line
                    .lowercased()
                    .replacingOccurrences(of: #"[^\p{L}\p{N} ]+"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private static func explicitSectionHeader(from trimmedLine: String) -> String? {
        let delimiters: [(Character, Character)] = [("[", "]"), ("{", "}"), ("(", ")")]

        for (open, close) in delimiters {
            guard trimmedLine.first == open, trimmedLine.last == close else { continue }
            let inner = String(trimmedLine.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { continue }
            if let section = canonicalSectionHeader(from: inner) {
                return section
            }
        }

        return nil
    }

    private static func sectionalCue(from trimmedLine: String) -> String? {
        guard trimmedLine.first == "{" || trimmedLine.first == "[" || trimmedLine.first == "(" else {
            return nil
        }

        let inner = String(trimmedLine.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return nil }

        if let section = canonicalSectionHeader(from: inner) {
            return section
        }

        let normalized = inner
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("instrumental") {
            return "[Instrumental]"
        }

        return nil
    }

    private static func canonicalSectionHeader(from rawHeader: String) -> String? {
        let lowercased = rawHeader.lowercased()

        let patterns: [(String, String)] = [
            (#"\bpre[ -]?chorus\b(?:\s*(\d+))?"#, "Pre-Chorus"),
            (#"\bpost[ -]?chorus\b(?:\s*(\d+))?"#, "Post-Chorus"),
            (#"\bverse\b(?:\s*(\d+))?"#, "Verse"),
            (#"\bchorus\b(?:\s*(\d+))?"#, "Chorus"),
            (#"\bbridge\b(?:\s*(\d+))?"#, "Bridge"),
            (#"\bintro\b(?:\s*(\d+))?"#, "Intro"),
            (#"\boutro\b(?:\s*(\d+))?"#, "Outro"),
            (#"\bhook\b(?:\s*(\d+))?"#, "Hook"),
            (#"\brefrain\b(?:\s*(\d+))?"#, "Refrain"),
            (#"\binterlude\b(?:\s*(\d+))?"#, "Interlude"),
            (#"\binstrumental\b(?:\s*(\d+))?"#, "Instrumental"),
            (#"\bbreakdown\b(?:\s*(\d+))?"#, "Breakdown"),
            (#"\bcoda\b(?:\s*(\d+))?"#, "Coda")
        ]

        for (pattern, label) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (lowercased as NSString).length)
            guard let match = regex.firstMatch(in: lowercased, range: range) else { continue }

            if match.numberOfRanges > 1,
               let numberRange = Range(match.range(at: 1), in: lowercased) {
                let number = lowercased[numberRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !number.isEmpty {
                    return "[\(label) \(number)]"
                }
            }

            return "[\(label)]"
        }

        return nil
    }

    private static func speakerRole(from trimmedLine: String) -> SpeakerRole? {
        guard isSpeakerLabelContent(trimmedLine) else { return nil }

        let normalized = normalizedSpeakerKey(trimmedLine)
        if normalized.contains("both") || normalized.contains("duet") {
            return .duet
        }
        if normalized.contains("ensemble") || normalized.contains("company") || normalized == "all" {
            return .ensemble
        }
        if normalized.contains(" and ") || normalized.contains(" with ") || normalized.contains(" plus ") {
            return .duet
        }
        return .named(trimmedLine.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func tabbedLyricLine(from rawLine: String) -> String? {
        guard rawLine.unicodeScalars.first.map(CharacterSet.whitespacesAndNewlines.contains) == true else {
            return nil
        }

        return cleanedLyricContent(from: rawLine)
    }

    private static func plainLyricLine(from trimmedLine: String) -> String? {
        guard !looksLikeMetadata(trimmedLine) else { return nil }
        guard speakerRole(from: trimmedLine) == nil else { return nil }
        guard explicitSectionHeader(from: trimmedLine) == nil else { return nil }
        return cleanedLyricContent(from: trimmedLine)
    }

    private static func cleanedLyricContent(from rawLine: String) -> String? {
        var content = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        if (content.hasPrefix("[") && content.hasSuffix("]"))
            || (content.hasPrefix("{") && content.hasSuffix("}"))
            || (content.hasPrefix("(") && content.hasSuffix(")") && content.count > 4)
            || content == "_" {
            return nil
        }

        content = stripTrailingSyllableAnnotation(from: content)
        content = stripDelimitedContent(content, open: "{", close: "}")
        content = stripDelimitedContent(content, open: "[", close: "]")
        content = content.replacingOccurrences(of: "_", with: " ")
        content = content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private static func stripTrailingSyllableAnnotation(from text: String) -> String {
        text.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
    }

    private static func stripDelimitedContent(_ text: String, open: Character, close: Character) -> String {
        var result = ""
        var depth = 0

        for character in text {
            if character == open {
                depth += 1
            } else if character == close {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(character)
            }
        }

        return result
    }

    private static func isSpeakerLabelContent(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }
        guard stripped.count <= 48 else { return false }
        guard explicitSectionHeader(from: stripped) == nil else { return false }
        guard !looksLikeMetadata(stripped) else { return false }
        guard stripped.range(of: #"^[A-Za-z0-9][A-Za-z0-9 '&\-/\.]*$"#, options: .regularExpression) != nil else {
            return false
        }

        let tokens = stripped.split(whereSeparator: \.isWhitespace)
        guard (1...6).contains(tokens.count) else { return false }

        let alphaTokens = tokens.filter { token in
            token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        guard !alphaTokens.isEmpty else { return false }

        return alphaTokens.allSatisfy { token in
            let string = String(token)
            let lowered = string.lowercased()
            if ["and", "with", "plus"].contains(lowered) {
                return true
            }
            if string == string.uppercased() {
                return true
            }
            guard let first = string.unicodeScalars.first else { return false }
            return CharacterSet.uppercaseLetters.contains(first)
        }
    }

    private static func looksLikeMetadata(_ text: String) -> Bool {
        let uppercased = text.uppercased()
        if uppercased.hasPrefix("INT.") || uppercased.hasPrefix("EXT.") || uppercased.hasPrefix("INT/") || uppercased.hasPrefix("EXT/") {
            return true
        }
        if uppercased.hasPrefix("(SUNG") || uppercased.hasPrefix("SUNG") {
            return true
        }
        if uppercased.hasPrefix("===") {
            return true
        }
        if text.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func appendBlankLineIfNeeded(_ output: inout [String]) {
        if let last = output.last, !last.isEmpty {
            output.append("")
        }
    }

    private static func collapseBlankLines(_ lines: [String]) -> [String] {
        var output: [String] = []
        var previousBlank = true

        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank {
                if !previousBlank {
                    output.append("")
                }
            } else {
                output.append(line)
            }
            previousBlank = blank
        }

        return output
    }
}
