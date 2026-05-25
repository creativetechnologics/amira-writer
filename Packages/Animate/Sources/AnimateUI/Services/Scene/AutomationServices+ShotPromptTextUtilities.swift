import Foundation

@available(macOS 26.0, *)
extension EffectiveShotSpecBuilder {
    nonisolated static func isLowSignalActionLine(_ value: String) -> Bool {
        let lower = value.lowercased()
        let disallowedPhrases = [
            "seeded from script line",
            "first time",
            "for the first time",
            "beginning frame",
            "middle frame",
            "end frame",
            "scene",
            "shot"
        ]
        if disallowedPhrases.contains(where: { lower.contains($0) }) {
            return true
        }
        let tokenCount = lower
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
        return tokenCount <= 3
    }

    nonisolated static func isNarrativeOrMotivationLine(_ value: String) -> Bool {
        let lower = value.lowercased()
        let disallowedPhrases = [
            "official record",
            "mission",
            "for what the job asks",
            "what the job asks",
            "personal record",
            "private record",
            "because",
            "so that",
            "longs",
            "wants to",
            "needs to",
            "decides to",
            "realizes",
            "understands",
            "remembers",
            "why the shot exists",
            "dramatic",
            "motivation",
            "story beat",
            "script"
        ]
        return disallowedPhrases.contains { lower.contains($0) }
    }

    nonisolated static func cleanedVisualText(
        _ value: String?,
        characterNames: [String],
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "" }

        text = replacingRegex(
            in: text,
            pattern: promptProtocol.sanitization.seededScriptLinePattern,
            with: ""
        )
        for pattern in promptProtocol.sanitization.additionalStripPatterns {
            text = replacingRegex(in: text, pattern: pattern, with: "")
        }
        if promptProtocol.sanitization.stripBracketedSpans {
            text = replacingRegex(in: text, pattern: #"\[[^\]]*\]"#, with: "")
        }
        if promptProtocol.sanitization.stripResidualSquareBrackets {
            text = replacingRegex(in: text, pattern: #"\["#, with: "")
            text = replacingRegex(in: text, pattern: #"\]"#, with: "")
        }
        if promptProtocol.sanitization.collapseWhitespace {
            text = replacingRegex(in: text, pattern: #"\s+"#, with: " ")
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in characterNames {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: trimmedName)
            cleaned = replacingRegex(
                in: cleaned,
                pattern: "(?i)\\b\(escaped)\\b",
                with: promptProtocol.sanitization.replaceCharacterNamesWith
            )
        }
        if promptProtocol.sanitization.collapseWhitespace {
            cleaned = replacingRegex(in: cleaned, pattern: #"\s+"#, with: " ")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func characterNameVariants(
        from names: [String],
        sanitization: ShotPromptSanitization
    ) -> [String] {
        var set = Set<String>()
        for rawName in names {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            set.insert(trimmed)
            if sanitization.includeNameFragments {
                for part in trimmed.split(separator: " ").map(String.init)
                where part.count >= sanitization.minimumNameFragmentLength {
                    set.insert(part)
                }
            }
        }
        return Array(set).sorted { $0.count > $1.count }
    }

    nonisolated static func firstSentence(
        from value: String,
        sanitization: ShotPromptSanitization
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        for delimiter in sanitization.firstSentenceDelimiters {
            if let range = trimmed.range(of: delimiter) {
                let prefix = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return prefix
                }
            }
        }
        return trimmed
    }

    nonisolated static func leadingSentences(from value: String, maxCount: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxCount > 0 else { return "" }
        let parts = trimmed
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return trimmed }
        return parts.prefix(maxCount).joined(separator: ". ") + "."
    }

    nonisolated static func replacingRegex(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    nonisolated static func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains(where: { text.contains($0) })
    }

    nonisolated static func isVehicleInteriorShotText(_ text: String) -> Bool {
        containsAny(
            text.lowercased(),
            terms: [
                "vehicle interior",
                "humvee interior",
                "military vehicle interior",
                "inside a military vehicle",
                "inside the military vehicle",
                "inside a vehicle",
                "seated in the humvee",
                "from inside the vehicle",
                "from inside the humvee",
                "through the windshield"
            ]
        )
    }

    nonisolated static func deduplicateSentences(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
