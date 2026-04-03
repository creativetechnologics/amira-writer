import Foundation

@available(macOS 26.0, *)
enum SunoLyricsFormatter {
    enum SpeakerGender: String, Sendable {
        case male
        case female
        case unknown
    }

    private struct LyricBlock {
        var section: String?
        var speaker: String?
        var lyrics: [String]
    }

    struct Result: Sendable {
        var formattedText: String
        var speakerLabels: [String: String]
    }

    static func format(librettoText: String?, speakerGenderHints: [String: SpeakerGender] = [:]) -> Result {
        guard let librettoText, !librettoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(formattedText: "", speakerLabels: [:])
        }

        let lines = DirectionParser.stripDirections(from: librettoText).components(separatedBy: .newlines)
        let blocks = collectLyricBlocks(lines: lines)
        let speakerHints = blocks.compactMap(\.speaker)
        let speakerMap = buildSpeakerMap(from: speakerHints, genderHints: speakerGenderHints)
        let shouldEmitSpeakerLabels = speakerMap.count > 1

        var output: [String] = []
        var activeSpeaker: String?

        for block in blocks {
            if let section = block.section {
                appendBlankLineIfNeeded(&output)
                output.append(section)
                activeSpeaker = nil
            }

            if shouldEmitSpeakerLabels,
               let speaker = block.speaker,
               let label = speakerMap[speaker] {
                if activeSpeaker != label {
                    appendBlankLineIfNeeded(&output)
                    output.append("[\(label)]")
                    activeSpeaker = label
                }
            } else {
                activeSpeaker = nil
            }

            output.append(contentsOf: block.lyrics)
        }

        let compact = collapseBlankLines(output)
        return Result(
            formattedText: compact.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            speakerLabels: speakerMap
        )
    }

    private static func collectLyricBlocks(lines: [String]) -> [LyricBlock] {
        var blocks: [LyricBlock] = []
        var pendingSpeaker: String?
        var pendingSection: String?
        var currentSpeaker: String?
        var currentSection: String?
        var currentLyrics: [String] = []

        func flushCurrentBlock() {
            guard !currentLyrics.isEmpty else {
                currentSpeaker = nil
                currentSection = nil
                return
            }
            blocks.append(LyricBlock(section: currentSection, speaker: currentSpeaker, lyrics: currentLyrics))
            currentSpeaker = nil
            currentSection = nil
            currentLyrics = []
        }

        for (index, rawLine) in lines.enumerated() {
            if let lyricLine = cleanedLyricLine(from: rawLine) {
                if currentLyrics.isEmpty {
                    currentSpeaker = pendingSpeaker
                    currentSection = pendingSection
                    pendingSection = nil
                }
                currentLyrics.append(lyricLine)
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flushCurrentBlock()
                pendingSpeaker = nil
                continue
            }

            flushCurrentBlock()

            if let section = normalizedSectionHeader(from: rawLine) {
                pendingSection = section
                pendingSpeaker = nil
                continue
            }

            if let speaker = speakerCandidate(from: rawLine, nextNonEmptyLine: nextNonEmptyLine(after: index, in: lines)) {
                pendingSpeaker = speaker
                continue
            }

            pendingSpeaker = nil
            pendingSection = nil
        }

        flushCurrentBlock()
        return blocks
    }

    private static func buildSpeakerMap(from speakers: [String], genderHints: [String: SpeakerGender]) -> [String: String] {
        var result: [String: String] = [:]
        var singerCount = 0
        var manCount = 0
        var womanCount = 0

        for speaker in speakers {
            guard result[speaker] == nil else { continue }
            let label: String
            switch inferredGender(for: speaker, hints: genderHints) {
            case .male:
                manCount += 1
                label = "Man \(manCount)"
            case .female:
                womanCount += 1
                label = "Woman \(womanCount)"
            case .unknown:
                singerCount += 1
                label = "Singer \(singerCount)"
            }
            result[speaker] = label
        }
        return result
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
            "victoria", "violet", "zoe"
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

    private static func normalizedSectionHeader(from rawLine: String) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("\t"), !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        guard isRecognizedSectionHeader(inner) else { return nil }
        return "[\(inner)]"
    }

    private static func speakerCandidate(from rawLine: String, nextNonEmptyLine: String?) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("\t"), !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("["),
              !trimmed.hasPrefix("{"),
              !trimmed.hasPrefix("("),
              trimmed.count <= 40 else { return nil }
        guard let nextNonEmptyLine, cleanedLyricLine(from: nextNonEmptyLine) != nil else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSpeakerLabelContent(normalized) else { return nil }
        return normalized
    }

    private static func cleanedLyricLine(from rawLine: String) -> String? {
        guard rawLine.hasPrefix("\t") else { return nil }
        var content = rawLine.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        if (content.hasPrefix("[") && content.hasSuffix("]"))
            || (content.hasPrefix("{") && content.hasSuffix("}"))
            || (content.hasPrefix("(") && content.hasSuffix(")") && content.count > 4)
            || content == "_" {
            return nil
        }

        if let tabRange = content.range(of: "\t", options: .backwards) {
            let suffix = content[tabRange.upperBound...]
            if suffix.hasPrefix("(") && suffix.hasSuffix(")") {
                content = String(content[..<tabRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }

        content = stripDelimitedContent(content, open: "{", close: "}")
        content = stripDelimitedContent(content, open: "[", close: "]")
        content = content.replacingOccurrences(of: "_", with: " ")
        content = content.replacingOccurrences(of: "  ", with: " ")
        content = content.trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func stripDelimitedContent(_ text: String, open: Character, close: Character) -> String {
        var result = ""
        var depth = 0
        for ch in text {
            if ch == open {
                depth += 1
            } else if ch == close {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(ch)
            }
        }
        return result
    }

    private static func nextNonEmptyLine(after index: Int, in lines: [String]) -> String? {
        guard index + 1 < lines.count else { return nil }
        for line in lines[(index + 1)...] {
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return line
            }
        }
        return nil
    }

    private static func isRecognizedSectionHeader(_ header: String) -> Bool {
        let normalized = header
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bases: [String] = [
            "verse",
            "chorus",
            "pre chorus",
            "post chorus",
            "bridge",
            "intro",
            "outro",
            "hook",
            "refrain",
            "interlude",
            "instrumental",
            "breakdown",
            "coda"
        ]

        return bases.contains { base in
            normalized == base || normalized.hasPrefix(base + " ")
        }
    }

    private static func isSpeakerLabelContent(_ text: String) -> Bool {
        guard text.range(of: #"[.!?,;]"#, options: .regularExpression) == nil else { return false }
        guard text.range(of: #"^[A-Za-z0-9][A-Za-z0-9 '&\-\.]*$"#, options: .regularExpression) != nil else {
            return false
        }

        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(tokens.count) else { return false }

        let alphaTokens = tokens.filter { token in
            token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        guard !alphaTokens.isEmpty else { return false }

        return alphaTokens.allSatisfy { token in
            let string = String(token)
            if string == string.uppercased() { return true }
            guard let first = string.unicodeScalars.first else { return false }
            return CharacterSet.uppercaseLetters.contains(first)
        }
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
