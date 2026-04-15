import Foundation

struct DrawThingsLoRAReference: Codable, Hashable, Sendable {
    var file: String
    var weight: Double
    var mode: String

    init(
        file: String,
        weight: Double,
        mode: String = "all"
    ) {
        self.file = file
        self.weight = weight
        self.mode = mode
    }
}

struct DrawThingsPreparedPrompt: Sendable {
    var prompt: String
    var loras: [DrawThingsLoRAReference]
}

private struct DrawThingsCustomModelDescriptor: Decodable {
    var file: String?
    var version: String?
}

private struct DrawThingsCustomLoRADescriptor: Decodable {
    var file: String?
    var version: String?
    var prefix: String?
    var name: String?
}

struct DrawThingsPromptTriggerMapping: Hashable, Sendable {
    var characterTokens: [String]
    var triggerWord: String
}

enum DrawThingsPromptIdentityInjector {
    static func injectTriggers(
        into prompt: String,
        mappings: [DrawThingsPromptTriggerMapping]
    ) -> String {
        var updatedPrompt = prompt
        var fallbackTriggerWords: [String] = []

        for mapping in mappings {
            let triggerWord = mapping.triggerWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !triggerWord.isEmpty else { continue }
            if hasCharacterMatch(in: updatedPrompt, tokens: mapping.characterTokens) {
                updatedPrompt = replacingCharacterTokens(
                    in: updatedPrompt,
                    tokens: mapping.characterTokens,
                    with: triggerWord
                )
                updatedPrompt = collapsingRepeatedToken(
                    triggerWord,
                    in: updatedPrompt
                )
            } else {
                guard !containsPromptToken(triggerWord, in: updatedPrompt) else { continue }
                fallbackTriggerWords.append(triggerWord)
            }
        }

        let uniqueFallbackTriggerWords = Array(
            NSOrderedSet(array: fallbackTriggerWords.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            })
        )
        .compactMap { $0 as? String }
        .filter { !$0.isEmpty }

        guard !uniqueFallbackTriggerWords.isEmpty else {
            return updatedPrompt
        }
        return "\(uniqueFallbackTriggerWords.joined(separator: ", ")), \(updatedPrompt)"
    }

    static func containsPromptToken(
        _ token: String,
        in prompt: String
    ) -> Bool {
        promptTokenRange(token, in: prompt) != nil
    }

    private static func hasCharacterMatch(
        in prompt: String,
        tokens: [String]
    ) -> Bool {
        let normalizedTokens = tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted {
                if $0.count == $1.count {
                    return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                return $0.count > $1.count
            }

        for token in normalizedTokens {
            if promptTokenRange(token, in: prompt) != nil {
                return true
            }
        }
        return false
    }

    private static func replacingCharacterTokens(
        in prompt: String,
        tokens: [String],
        with replacement: String
    ) -> String {
        let normalizedTokens = tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted {
                if $0.count == $1.count {
                    return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                return $0.count > $1.count
            }

        var updatedPrompt = prompt
        for token in normalizedTokens {
            updatedPrompt = replacingPromptToken(
                token,
                with: replacement,
                in: updatedPrompt
            )
        }
        return updatedPrompt
    }

    private static func replacingPromptToken(
        _ token: String,
        with replacement: String,
        in prompt: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return prompt
        }

        let nsRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return regex.stringByReplacingMatches(
            in: prompt,
            options: [],
            range: nsRange,
            withTemplate: replacement
        )
    }

    private static func collapsingRepeatedToken(
        _ token: String,
        in prompt: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?:\\s+\(escaped))+(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return prompt
        }

        let nsRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return regex.stringByReplacingMatches(
            in: prompt,
            options: [],
            range: nsRange,
            withTemplate: token
        )
    }

    private static func promptTokenRange(
        _ token: String,
        in prompt: String
    ) -> Range<String.Index>? {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let nsRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = regex.firstMatch(in: prompt, options: [], range: nsRange),
              let range = Range(match.range, in: prompt) else {
            return nil
        }
        return range
    }
}

@available(macOS 26.0, *)
@MainActor
struct DrawThingsLoRAService {
    private struct PreferredLoRASelection: Sendable {
        var file: String
        var triggerWord: String
    }

    private struct CharacterLoRAUsage: Sendable {
        var character: AnimationCharacter
        var sourceURL: URL
        var importedFilename: String
        var triggerWord: String
        var weight: Double
        var promptTokens: [String]
    }

    enum LoRAError: LocalizedError {
        case configuredLoRAMissing(character: String, filename: String)
        case modelsDirectoryNotFound(modelName: String?)
        case copyFailed(source: String, destination: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .configuredLoRAMissing(let character, let filename):
                return "The active LoRA for \(character) is missing: \(filename)."
            case .modelsDirectoryNotFound(let modelName):
                if let modelName, !modelName.isEmpty {
                    return "Could not find the Draw Things models folder for model \(modelName)."
                }
                return "Could not find the Draw Things models folder."
            case .copyFailed(let source, let destination, let detail):
                return "Could not sync LoRA into Draw Things.\nSource: \(source)\nDestination: \(destination)\n\(detail)"
            }
        }
    }

    private static var cachedModelsDirectory: URL?

    func preparePrompt(
        prompt: String,
        characters: [AnimationCharacter],
        animateURL: URL,
        config: DrawThingsPlaceConfig
    ) async throws -> DrawThingsPreparedPrompt {
        let applicable = try configuredUsages(
            for: prompt,
            characters: characters,
            animateURL: animateURL
        )
        guard !applicable.isEmpty else {
            return DrawThingsPreparedPrompt(prompt: prompt, loras: [])
        }

        let modelsDirectory = try await resolveModelsDirectory(config: config)
        var syncedLoRAs: [DrawThingsLoRAReference] = []
        var triggerMappings: [DrawThingsPromptTriggerMapping] = []

        for usage in applicable {
            let importedFilename = try syncLoRA(
                sourceURL: usage.sourceURL,
                importedFilename: usage.importedFilename,
                modelsDirectory: modelsDirectory
            )
            try await ensureLoRARegistryEntry(
                importedFilename: importedFilename,
                usage: usage,
                modelsDirectory: modelsDirectory,
                config: config
            )
            let selection = await preferredGenerationSelection(
                importedFilename: importedFilename,
                usage: usage,
                modelsDirectory: modelsDirectory,
                config: config
            )
            syncedLoRAs.append(
                DrawThingsLoRAReference(
                    file: selection.file,
                    weight: usage.weight
                )
            )
            triggerMappings.append(
                DrawThingsPromptTriggerMapping(
                    characterTokens: usage.promptTokens,
                    triggerWord: selection.triggerWord
                )
            )
        }

        let effectivePrompt = DrawThingsPromptIdentityInjector.injectTriggers(
            into: prompt,
            mappings: triggerMappings
        )
        let dedupedLoRAs = Array(
            Dictionary(uniqueKeysWithValues: syncedLoRAs.map { ($0.file, $0) }).values
        ).sorted { $0.file < $1.file }

        return DrawThingsPreparedPrompt(
            prompt: effectivePrompt,
            loras: dedupedLoRAs
        )
    }

    @discardableResult
    func syncActiveLoRA(
        for character: AnimationCharacter,
        animateURL: URL,
        config: DrawThingsPlaceConfig
    ) async throws -> String {
        guard let usage = try configuredUsage(
            for: character,
            animateURL: animateURL
        ) else {
            throw LoRAError.configuredLoRAMissing(
                character: character.name,
                filename: character.activeLORAFilename ?? "(none)"
            )
        }
        let modelsDirectory = try await resolveModelsDirectory(config: config)
        let importedFilename = try syncLoRA(
            sourceURL: usage.sourceURL,
            importedFilename: usage.importedFilename,
            modelsDirectory: modelsDirectory
        )
        try await ensureLoRARegistryEntry(
            importedFilename: importedFilename,
            usage: usage,
            modelsDirectory: modelsDirectory,
            config: config
        )
        return await preferredGenerationSelection(
            importedFilename: importedFilename,
            usage: usage,
            modelsDirectory: modelsDirectory,
            config: config
        ).file
    }

    // MARK: - Matching

    private func configuredUsages(
        for prompt: String,
        characters: [AnimationCharacter],
        animateURL: URL
    ) throws -> [CharacterLoRAUsage] {
        try characters.compactMap { character in
            guard matchesPrompt(prompt, character: character) else { return nil }
            return try configuredUsage(for: character, animateURL: animateURL)
        }
    }

    private func configuredUsage(
        for character: AnimationCharacter,
        animateURL: URL
    ) throws -> CharacterLoRAUsage? {
        guard let rawFilename = character.activeLORAFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawFilename.isEmpty else {
            return nil
        }

        let filename = URL(fileURLWithPath: rawFilename).lastPathComponent
        let sourceURL = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(character.assetFolderSlug)
            .appendingPathComponent("lora")
            .appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LoRAError.configuredLoRAMissing(
                character: character.name,
                filename: filename
            )
        }

        let triggerWord = normalizedTriggerWord(
            explicitTriggerWord: character.activeLORATriggerWord,
            fallbackFilename: filename
        )
        let promptTokens = promptTokens(for: character)

        return CharacterLoRAUsage(
            character: character,
            sourceURL: sourceURL,
            importedFilename: importedFilename(
                for: character,
                sourceFilename: filename
            ),
            triggerWord: triggerWord,
            weight: max(0.05, character.activeLORAWeight),
            promptTokens: promptTokens
        )
    }

    private func matchesPrompt(
        _ prompt: String,
        character: AnimationCharacter
    ) -> Bool {
        promptTokens(for: character).contains {
            DrawThingsPromptIdentityInjector.containsPromptToken($0, in: prompt)
        }
    }

    private func promptTokens(
        for character: AnimationCharacter
    ) -> [String] {
        let filenameStem = character.activeLORAFilename
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""
        return Array(
            NSOrderedSet(array: [
                character.name,
                character.name.split(separator: " ").first.map(String.init) ?? character.name,
                character.activeLORATriggerWord ?? "",
                filenameStem
            ])
        )
        .compactMap { $0 as? String }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func normalizedTriggerWord(
        explicitTriggerWord: String?,
        fallbackFilename: String
    ) -> String {
        let explicit = explicitTriggerWord?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        return URL(fileURLWithPath: fallbackFilename)
            .deletingPathExtension()
            .lastPathComponent
    }

    private func importedFilename(
        for character: AnimationCharacter,
        sourceFilename: String
    ) -> String {
        let safeSource = sourceFilename.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "_",
            options: .regularExpression
        )
        return "amira__\(character.assetFolderSlug)__\(safeSource)"
    }

    // MARK: - Sync

    private func syncLoRA(
        sourceURL: URL,
        importedFilename: String,
        modelsDirectory: URL
    ) throws -> String {
        let destinationURL = modelsDirectory.appendingPathComponent(importedFilename)
        let fileManager = FileManager.default

        let shouldCopy: Bool
        if fileManager.fileExists(atPath: destinationURL.path) {
            let sourceValues = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let destinationValues = try destinationURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            shouldCopy =
                sourceValues.fileSize != destinationValues.fileSize ||
                (sourceValues.contentModificationDate ?? .distantPast) > (destinationValues.contentModificationDate ?? .distantPast)
        } else {
            shouldCopy = true
        }

        guard shouldCopy else {
            return importedFilename
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw LoRAError.copyFailed(
                source: sourceURL.path,
                destination: destinationURL.path,
                detail: error.localizedDescription
            )
        }

        return importedFilename
    }

    private func ensureLoRARegistryEntry(
        importedFilename: String,
        usage: CharacterLoRAUsage,
        modelsDirectory: URL,
        config: DrawThingsPlaceConfig
    ) async throws {
        let registryURL = modelsDirectory.appendingPathComponent("custom_lora.json")
        let fileManager = FileManager.default

        var entries: [[String: Any]] = []
        if fileManager.fileExists(atPath: registryURL.path) {
            let data = try Data(contentsOf: registryURL)
            if let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                entries = decoded
            }
        }

        let version = await inferredLoRAVersion(
            sourceFilename: usage.sourceURL.lastPathComponent,
            modelsDirectory: modelsDirectory,
            config: config
        )
        let normalizedImportedFilename = importedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedImportedFilename.isEmpty else { return }

        let desiredEntry: [String: Any] = [
            "file": normalizedImportedFilename,
            "prefix": registryPrefix(for: usage.triggerWord),
            "name": usage.character.name,
            "version": version,
            "is_lo_ha": false
        ]

        let existingIndex = entries.firstIndex {
            (($0["file"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedImportedFilename) == .orderedSame
        }

        if let existingIndex {
            var existing = entries[existingIndex]
            var didChange = false

            for (key, value) in desiredEntry {
                let currentValue = existing[key]
                switch (currentValue, value) {
                case let (lhs as String, rhs as String):
                    if lhs != rhs {
                        existing[key] = rhs
                        didChange = true
                    }
                case let (lhs as Bool, rhs as Bool):
                    if lhs != rhs {
                        existing[key] = rhs
                        didChange = true
                    }
                case (nil, _):
                    existing[key] = value
                    didChange = true
                default:
                    break
                }
            }

            guard didChange else { return }
            entries[existingIndex] = existing
        } else {
            entries.append(desiredEntry)
        }

        let data = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys]
        )
        if !fileManager.fileExists(atPath: modelsDirectory.path) {
            try fileManager.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true
            )
        }
        try data.write(to: registryURL, options: .atomic)
    }

    private func inferredLoRAVersion(
        sourceFilename: String,
        modelsDirectory: URL,
        config: DrawThingsPlaceConfig
    ) async -> String {
        if let currentModelName = await currentModelName(config: config),
           let version = registeredModelVersion(
               for: currentModelName,
               modelsDirectory: modelsDirectory
           ) {
            return version
        }

        let lowerSource = sourceFilename.lowercased()
        if lowerSource.contains("flux2") || lowerSource.contains("flux_2") || lowerSource.contains("flux-2") {
            if lowerSource.contains("9b") {
                return "flux2_9b"
            }
        }
        if lowerSource.contains("z-image") || lowerSource.contains("z_image") {
            return "z_image"
        }
        if lowerSource.contains("flux.1") || lowerSource.contains("flux1") || lowerSource.contains("flux_1") {
            return "flux1"
        }
        if lowerSource.contains("sdxl") {
            return "sdxl_base_v0.9"
        }
        return "v1"
    }

    private func preferredGenerationSelection(
        importedFilename: String,
        usage: CharacterLoRAUsage,
        modelsDirectory: URL,
        config: DrawThingsPlaceConfig
    ) async -> PreferredLoRASelection {
        let normalizedImportedFilename = importedFilename.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedImportedFilename.isEmpty else {
            return PreferredLoRASelection(
                file: importedFilename,
                triggerWord: usage.triggerWord
            )
        }

        let importedExtension = URL(fileURLWithPath: normalizedImportedFilename)
            .pathExtension
            .lowercased()
        if importedExtension == "ckpt" {
            return PreferredLoRASelection(
                file: normalizedImportedFilename,
                triggerWord: usage.triggerWord
            )
        }

        let registryURL = modelsDirectory.appendingPathComponent("custom_lora.json")
        guard let data = try? Data(contentsOf: registryURL),
              let descriptors = try? JSONDecoder().decode(
                  [DrawThingsCustomLoRADescriptor].self,
                  from: data
              ) else {
            return PreferredLoRASelection(
                file: normalizedImportedFilename,
                triggerWord: usage.triggerWord
            )
        }

        let expectedVersion = await inferredLoRAVersion(
            sourceFilename: usage.sourceURL.lastPathComponent,
            modelsDirectory: modelsDirectory,
            config: config
        )
        let normalizedExpectedVersion = normalizedToken(expectedVersion)
        let normalizedTrigger = normalizedToken(usage.triggerWord)
        let normalizedCharacterName = normalizedToken(usage.character.name)
        let normalizedImportedStem = normalizedToken(
            URL(fileURLWithPath: normalizedImportedFilename)
                .deletingPathExtension()
                .lastPathComponent
        )
        let normalizedSourceStem = normalizedToken(
            usage.sourceURL
                .deletingPathExtension()
                .lastPathComponent
        )

        let candidates = descriptors.compactMap { descriptor -> (score: Int, descriptor: DrawThingsCustomLoRADescriptor, file: String)? in
            guard let file = descriptor.file?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !file.isEmpty else {
                return nil
            }

            let candidateURL = modelsDirectory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: candidateURL.path) else {
                return nil
            }

            let candidateExtension = candidateURL.pathExtension.lowercased()
            guard candidateExtension == "ckpt" else {
                return nil
            }

            let normalizedVersion = normalizedToken(descriptor.version)
            guard normalizedVersion.isEmpty || normalizedVersion == normalizedExpectedVersion else {
                return nil
            }

            let normalizedPrefix = normalizedToken(descriptor.prefix)
            let normalizedName = normalizedToken(descriptor.name)
            let normalizedFile = normalizedToken(file)
            let triggerMatches = !normalizedTrigger.isEmpty && (
                normalizedPrefix == normalizedTrigger ||
                normalizedFile.contains(normalizedTrigger)
            )
            let importedStemMatches = !normalizedImportedStem.isEmpty && normalizedFile.contains(normalizedImportedStem)
            let sourceStemMatches = !normalizedSourceStem.isEmpty && normalizedFile.contains(normalizedSourceStem)

            guard triggerMatches || importedStemMatches || sourceStemMatches else {
                return nil
            }

            var score = 0
            if normalizedPrefix == normalizedTrigger {
                score += 100
            }
            if normalizedFile.contains(normalizedTrigger) {
                score += 60
            }
            if importedStemMatches {
                score += 50
            }
            if sourceStemMatches {
                score += 40
            }
            if normalizedName == normalizedCharacterName {
                score += 20
            }
            if normalizedVersion == normalizedExpectedVersion {
                score += 20
            }

            return (score, descriptor, file)
        }

        if let candidate = candidates.sorted(by: {
            if $0.score == $1.score {
                return $0.file.localizedStandardCompare($1.file) == .orderedAscending
            }
            return $0.score > $1.score
        }).first {
            let preferredTrigger = candidate.descriptor.prefix?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PreferredLoRASelection(
                file: candidate.file,
                triggerWord: {
                    guard let preferredTrigger, !preferredTrigger.isEmpty else {
                        return usage.triggerWord
                    }
                    return preferredTrigger
                }()
            )
        }

        return PreferredLoRASelection(
            file: normalizedImportedFilename,
            triggerWord: usage.triggerWord
        )
    }

    private func registryPrefix(
        for triggerWord: String
    ) -> String {
        let normalized = triggerWord.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return "" }
        return normalized.hasSuffix(" ") ? normalized : "\(normalized) "
    }

    private func normalizedToken(
        _ value: String?
    ) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func registeredModelVersion(
        for modelFilename: String,
        modelsDirectory: URL
    ) -> String? {
        let metadataURL = modelsDirectory.appendingPathComponent("custom.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let descriptors = try? JSONDecoder().decode(
                  [DrawThingsCustomModelDescriptor].self,
                  from: data
              ) else {
            return nil
        }

        let normalizedFilename = modelFilename.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedFilename.isEmpty else { return nil }

        return descriptors.first(where: {
            ($0.file ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedFilename) == .orderedSame
        })?.version
    }

    // MARK: - Draw Things Models Directory

    private func resolveModelsDirectory(
        config: DrawThingsPlaceConfig
    ) async throws -> URL {
        if let cached = Self.cachedModelsDirectory,
           directoryLooksLikeDrawThingsModels(cached, currentModelName: nil) {
            return cached
        }

        let currentModelName = await currentModelName(config: config)
        let candidates = candidateModelsDirectories()
        if let directMatch = candidates.first(where: { directoryLooksLikeDrawThingsModels($0, currentModelName: currentModelName) }) {
            Self.cachedModelsDirectory = directMatch
            return directMatch
        }

        if let currentModelName,
           let spotlightMatch = locateModelDirectoryWithSpotlight(named: currentModelName) {
            Self.cachedModelsDirectory = spotlightMatch
            return spotlightMatch
        }

        throw LoRAError.modelsDirectoryNotFound(modelName: currentModelName)
    }

    private func currentModelName(
        config: DrawThingsPlaceConfig
    ) async -> String? {
        guard var components = URLComponents(string: config.apiHost) else {
            return nil
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        components.port = config.apiPort
        components.path = "/sdapi/v1/options"
        guard let url = components.url else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = payload["model"] as? String else {
                return nil
            }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    private func candidateModelsDirectories() -> [URL] {
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment

        if let envPath = environment["DRAWTHINGS_MODELS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envPath.isEmpty {
            candidates.append(URL(fileURLWithPath: envPath))
        }

        candidates.append(URL(fileURLWithPath: "/Volumes/Storage XI/AI Models/Draw Things"))
        candidates.append(URL(fileURLWithPath: "/Volumes/Storage VIII/AI Models/Draw Things"))
        candidates.append(URL(fileURLWithPath: ("~/AI Models/Draw Things" as NSString).expandingTildeInPath))
        candidates.append(URL(fileURLWithPath: ("~/Library/Application Support/Draw Things/Models" as NSString).expandingTildeInPath))
        candidates.append(URL(fileURLWithPath: ("~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models" as NSString).expandingTildeInPath))

        var seen: Set<String> = []
        return candidates.filter { url in
            let standardized = url.standardizedFileURL.path
            guard !seen.contains(standardized) else { return false }
            seen.insert(standardized)
            return true
        }
    }

    private func directoryLooksLikeDrawThingsModels(
        _ url: URL,
        currentModelName: String?
    ) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        if let currentModelName,
           fileManager.fileExists(atPath: url.appendingPathComponent(currentModelName).path) {
            return true
        }
        if fileManager.fileExists(atPath: url.appendingPathComponent("custom_lora.json").path),
           let entries = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
           entries.contains(where: {
               let ext = $0.pathExtension.lowercased()
               return (ext == "ckpt" || ext == "safetensors") && !$0.lastPathComponent.hasSuffix(".part")
           }) {
            return true
        }
        return false
    }

    private func locateModelDirectoryWithSpotlight(
        named modelName: String
    ) -> URL? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", modelName]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in output.split(separator: "\n") {
            let url = URL(fileURLWithPath: String(line))
            guard url.lastPathComponent == modelName else { continue }
            return url.deletingLastPathComponent()
        }

        return nil
    }
}
