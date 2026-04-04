import Foundation

enum PlacesScriptIndexService {
    private static let sceneHeadingPrefixes = [
        "INT.", "EXT.", "INT ", "EXT ", "INT/", "EXT/", "INT./EXT.", "EXT./INT.", "INT/EXT", "EXT/INT"
    ]

    static func buildRequirements(
        projectURL: URL,
        scenes: [AnimationScene]
    ) async -> [PlacesScriptSceneRequirement] {
        var results: [PlacesScriptSceneRequirement] = []

        for scene in scenes {
            let lyrics = await ProjectDatabaseBridge
                .hydrateSongData(projectURL: projectURL, relativePath: scene.owpSongPath)?
                .extractLyrics() ?? ""
            let locations = extractLocations(from: lyrics, fallbackSceneName: scene.name)
            results.append(
                PlacesScriptSceneRequirement(
                    sceneID: scene.id,
                    sceneName: scene.name,
                    songPath: scene.owpSongPath,
                    locations: locations
                )
            )
        }

        return results
    }

    static func extractLocations(
        from lyrics: String,
        fallbackSceneName: String
    ) -> [PlacesScriptLocationRequirement] {
        let lines = lyrics
            .components(separatedBy: .newlines)
            .map { sanitize(line: $0) }
            .filter { !$0.isEmpty }

        var ordered: [PlacesScriptLocationRequirement] = []
        var seen: Set<String> = []

        for line in lines {
            if let requirement = parseLocationRequirement(from: line) {
                guard seen.insert(requirement.normalizedKey).inserted else { continue }
                ordered.append(requirement)
            }
        }

        if ordered.isEmpty {
            let fallback = cleanedFallbackName(fallbackSceneName)
            guard !fallback.isEmpty else { return [] }
            ordered.append(
                PlacesScriptLocationRequirement(
                    displayName: fallback,
                    normalizedKey: normalizedKey(for: fallback),
                    inferredCategory: "",
                    sourceLine: nil,
                    isFallback: true
                )
            )
        }

        return ordered
    }

    static func normalizedKey(for value: String) -> String {
        let lowered = value
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return lowered
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func fileStem(for value: String) -> String {
        normalizedKey(for: value)
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func parseLocationRequirement(from line: String) -> PlacesScriptLocationRequirement? {
        if let location = parseSceneHeading(line) {
            return location
        }

        if let location = parseExplicitLocationLine(line) {
            return location
        }

        return nil
    }

    private static func parseSceneHeading(_ line: String) -> PlacesScriptLocationRequirement? {
        let uppercased = line.uppercased()
        guard sceneHeadingPrefixes.contains(where: { uppercased.hasPrefix($0) }) else {
            return nil
        }

        let category: String = uppercased.hasPrefix("INT") && !uppercased.hasPrefix("INT/") && !uppercased.hasPrefix("INT./EXT.")
            ? "Interior"
            : (uppercased.hasPrefix("EXT") && !uppercased.hasPrefix("EXT/") && !uppercased.hasPrefix("EXT./INT.") ? "Exterior" : "")

        let trimmed = stripSceneHeadingPrefix(from: line)
        let locationText = trimTimeQualifier(from: trimmed)
        let displayName = canonicalDisplayName(locationText)
        let key = normalizedKey(for: displayName)
        guard !displayName.isEmpty, !key.isEmpty else { return nil }

        return PlacesScriptLocationRequirement(
            displayName: displayName,
            normalizedKey: key,
            inferredCategory: category,
            sourceLine: line
        )
    }

    private static func parseExplicitLocationLine(_ line: String) -> PlacesScriptLocationRequirement? {
        guard let match = line.range(
            of: #"^(?:LOCATION|SETTING|PLACE)\s*:\s*(.+)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        let raw = String(line[match])
            .replacingOccurrences(of: #"^(?:LOCATION|SETTING|PLACE)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        let displayName = canonicalDisplayName(trimTimeQualifier(from: raw))
        let key = normalizedKey(for: displayName)
        guard !displayName.isEmpty, !key.isEmpty else { return nil }

        return PlacesScriptLocationRequirement(
            displayName: displayName,
            normalizedKey: key,
            inferredCategory: "",
            sourceLine: line
        )
    }

    private static func sanitize(line: String) -> String {
        line
            .replacingOccurrences(of: #"\[\[.*?\]\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSceneHeadingPrefix(from line: String) -> String {
        line
            .replacingOccurrences(
                of: #"^(INT\.?/EXT\.?|EXT\.?/INT\.?|INT\.?|EXT\.?)\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:-—–"))
    }

    private static func trimTimeQualifier(from line: String) -> String {
        let separators = [" — ", " – ", " - ", " —", " –", " -"]

        for separator in separators {
            let components = line.components(separatedBy: separator)
            guard components.count >= 2 else { continue }
            let tail = components.dropFirst().joined(separator: separator)
            if looksLikeTimeQualifier(tail) {
                return components.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? line
            }
        }

        return line
    }

    private static func looksLikeTimeQualifier(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { return false }

        let allowed = Set([
            "DAY", "NIGHT", "DAWN", "DUSK", "SUNSET", "SUNRISE", "LATER", "CONTINUOUS", "MOMENTS LATER",
            "EVENING", "MORNING", "AFTERNOON", "MAGIC HOUR", "GOLDEN HOUR"
        ])

        if allowed.contains(normalized) {
            return true
        }

        let compact = normalized.replacingOccurrences(of: #"[^A-Z ]"#, with: "", options: .regularExpression)
        return allowed.contains(compact)
    }

    private static func canonicalDisplayName(_ value: String) -> String {
        let cleaned = value
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:-—–"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else { return "" }
        return cleaned
            .lowercased()
            .split(separator: " ")
            .map { token in
                let word = String(token)
                if ["and", "of", "the", "a", "an", "in", "on", "at", "to"].contains(word) {
                    return word
                }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func cleanedFallbackName(_ sceneName: String) -> String {
        sceneName
            .replacingOccurrences(of: #"^\d+(?:\.\d+)*\s*[-–—]?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
