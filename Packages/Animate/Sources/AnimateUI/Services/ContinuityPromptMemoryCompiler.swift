import Foundation

/// Converts noisy review/history artifacts into prompt-ready visual rules.
///
/// Important boundary: review state, ratings, rejection status, "Gary feedback",
/// and other UI/process metadata belong in sidecars and rule artifacts. Gemini
/// should only receive compact visual instructions that can affect pixels.
@available(macOS 26.0, *)
enum ContinuityPromptMemoryCompiler {
    static func visualInstruction(
        from rawText: String,
        prefix: String? = nil,
        maxCharacters: Int = 220
    ) -> String? {
        let visualText = distilledVisualText(from: rawText, maxFragments: 4, maxCharacters: maxCharacters)
        guard !visualText.isEmpty else { return nil }
        if let prefix, !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return capped("\(prefix): \(visualText)", maxCharacters: maxCharacters)
        }
        return visualText
    }

    static func visualRule(
        category: String,
        notes: [String],
        tags: [String],
        maxCharacters: Int = 260
    ) -> String? {
        let fragments = uniqueFragments(
            notes.flatMap { visualFragments(from: cleaned($0)) }
        )
        let selected = fragments.filter(containsVisualKeyword)
        let body = (selected.isEmpty ? fragments : selected)
            .prefix(5)
            .joined(separator: " ")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let categoryLabel = category.replacingOccurrences(of: "_", with: " ")
        let visualTags = tags
            .map { cleanedTag($0) }
            .filter { !$0.isEmpty && isPromptSafeTag($0) }
        let tagHint = visualTags.prefix(3).isEmpty ? "" : " (\(visualTags.prefix(3).joined(separator: ", ")))"
        return capped("Visual continuity rule — \(categoryLabel)\(tagHint): \(body)", maxCharacters: maxCharacters)
    }

    static func sanitizedPromptClause(_ rawText: String, maxCharacters: Int = 220) -> String? {
        visualInstruction(from: rawText, maxCharacters: maxCharacters)
    }

    static func cleaned(_ rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "—", with: " — ")
            .replacingOccurrences(of: " | ", with: "\n")

        let legacyTrainerName = "Continuity " + "Builder"
        let patterns = [
            #"(?i)\bImage review status:\s*(?:rejected|rated\s*\d+|unrated)\.?"#,
            #"(?i)\bUse the written notes as continuity learning input[^.\n|]*\.?"#,
            #"(?i)\bbut never treat the rejected image itself as a positive reference\.?"#,
            #"(?i)\bReview scope:[^.\n|]*\.?"#,
            "(?i)\\b\(legacyTrainerName) feedback for [^:\\n]{0,120}:\\s*",
            #"(?i)\bContinuity rule \([^)]+\):\s*"#,
            #"(?i)\bApply this [a-z_ ]+ correction when relevant:\s*"#,
            "(?i)\\b\(legacyTrainerName) training candidate\\.?\\s*",
            #"(?i)\bGenerate a single image for Gary to critique\.?\s*"#,
            #"(?i)\bAUTHORITATIVE CONTINUITY MEMORY[^.\n]*\.?\s*"#,
            #"(?i)\bQuestion this image is meant to answer:[^\n]*"#,
            #"(?i)\bSelected candidate label:[^.\n]*\.?\s*"#,
            #"(?i)\bCloseness score:[^.\n]*\.?\s*"#,
            #"(?i)\bLatest Gary feedback to repair or preserve:\s*"#,
            #"(?i)\bDirect edit request from Gary:\s*"#,
            #"(?i)\bRejecting this[^:\n]{0,120}:\s*"#,
            #"(?i)\bReference only textual feedback notes for continuity corrections;?\s*"#,
            #"(?i)\bnever use rejected image as positive example\.?"#,
            #"(?i)\bnever use a rejected image as a positive example\.?"#,
            #"(?i)\bOnce it appears, what is still wrong or right\?[^.\n]*\.?\s*"#,
            #"(?i)\bGive concrete visual rules that future prompts can reuse\.?"#,
            #"(?i)\bfor Gary to critique\b"#,
            #"(?i)\bPlease refer to (?:the )?(?:master reference map|master map image|master map|reference map)[^.!\n]*[.!]?"#,
            #"(?i)\buse the (?:master reference map|master map image|master map|reference map) for future [^.!\n]*(?:prompts|images|generations)[.!]?"#,
            #"(?i)\bfuture [^.!\n]*(?:prompts|images|generations)[^.!\n]*[.!]?"#,
            #"(?i)\bprompt(?:ing)? should\b"#,
            #"(?i)\bthis prompt\b"#,
            #"(?i)\bthe prompt\b"#
        ]

        for pattern in patterns {
            text = replaceRegex(pattern, in: text, with: " ")
        }

        text = replaceRegex(#"\s+"#, in: text, with: " ")
        text = replaceRegex(#"\s+([,.!?;:])"#, in: text, with: "$1")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func distilledVisualText(from rawText: String, maxFragments: Int, maxCharacters: Int) -> String {
        let fragments = uniqueFragments(visualFragments(from: cleaned(rawText)))
        let visual = fragments.filter(containsVisualKeyword)
        let selected = (visual.isEmpty ? fragments : visual).prefix(maxFragments)
        return capped(selected.joined(separator: " "), maxCharacters: maxCharacters)
    }

    private static func visualFragments(from text: String) -> [String] {
        let delimiterSet = CharacterSet(charactersIn: "\n|•")
        return text
            .components(separatedBy: delimiterSet)
            .flatMap { chunk -> [String] in
                let sentenceish = chunk.replacingOccurrences(of: ". ", with: ".\n")
                return sentenceish.components(separatedBy: "\n")
            }
            .map { fragment in
                normalizeVisualFragment(fragment)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-–—• "))
            }
            .filter { fragment in
                guard fragment.count >= 4 else { return false }
                let lower = fragment.lowercased()
                let banned = [
                    "continuity builder",
                    "review status",
                    "learning input",
                    "selected candidate",
                    "closeness score",
                    "training candidate",
                    "rejected image as positive example",
                    "future prompts can reuse",
                    "generate a single image"
                ]
                return !banned.contains { lower.contains($0) }
            }
    }

    private static func normalizeVisualFragment(_ rawFragment: String) -> String {
        var fragment = rawFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixPatterns = [
            #"(?i)^(?:okay|ok|yeah|so|like|also|and|but again|again|first of all|second(?:ly)?|third(?:ly)?)[, ]+"#,
            #"(?i)^(?:please|make sure to|it needs to|we need to)\s+"#,
            #"(?i)^(?:the image|this image|that image|the picture|this picture|that picture)\s+"#,
            #"(?i)^is\s+"#
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in prefixPatterns {
                let next = replaceRegex(pattern, in: fragment, with: "")
                if next != fragment {
                    fragment = next.trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        let replacements: [(String, String)] = [
            (#"(?i)\bshould not\b"#, "must not"),
            (#"(?i)\bshould be\b"#, "must be"),
            (#"(?i)\bneeds to be\b"#, "must be"),
            (#"(?i)\bneeds to\b"#, "must"),
            (#"(?i)\bthere should not be\b"#, "there must not be"),
            (#"(?i)\bthere should be\b"#, "there must be")
        ]
        for (pattern, replacement) in replacements {
            fragment = replaceRegex(pattern, in: fragment, with: replacement)
        }
        return fragment
    }

    private static func uniqueFragments(_ fragments: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for fragment in fragments {
            let normalized = fragment
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(fragment)
        }
        return result
    }

    private static func containsVisualKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = [
            "river", "bridge", "ravine", "town", "hill", "slope", "road", "building",
            "bank", "north", "south", "map", "valley", "mountain", "water", "flood",
            "sun", "lighting", "shadow", "vehicle", "humvee", "soldier", "uniform",
            "camouflage", "satchel", "polaroid", "camera", "costume", "face", "head",
            "hair", "skin", "boots", "belt", "palette", "grain", "style", "lens",
            "texture", "material", "mud", "stone", "brick", "signage", "power line",
            "cliff", "soil", "foreground", "background", "open matte", "4:3"
        ]
        return keywords.contains { lower.contains($0) }
    }

    private static func cleanedTag(_ tag: String) -> String {
        tag
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isPromptSafeTag(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        let blocked = [
            "rejected", "unrated", "rated", "review", "feedback", "positive feedback",
            "correction feedback", "image feedback", "continuity builder", "canvas",
            "generated", "candidate", "selected", "closeness"
        ]
        guard !blocked.contains(where: { lower == $0 || lower.contains($0) }) else { return false }
        return containsVisualKeyword(lower)
    }

    private static func capped(_ value: String, maxCharacters: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: max(1, maxCharacters - 1))
        var prefix = String(trimmed[..<index])
        if let lastSpace = prefix.lastIndex(where: { $0 == " " || $0 == "\n" }), prefix.distance(from: lastSpace, to: prefix.endIndex) < 40 {
            prefix = String(prefix[..<lastSpace])
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func replaceRegex(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
