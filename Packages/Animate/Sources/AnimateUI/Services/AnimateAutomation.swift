import Foundation
import ProjectKit

@available(macOS 26.0, *)
public struct LoRAE2EResult: Sendable {
    public let characterName: String
    public let projectLoRAPath: String
    public let drawThingsLoRAPath: String
    public let generatedImagePath: String
    public let promptFilePath: String
}

@available(macOS 26.0, *)
@MainActor
public enum AnimateAutomation {
    public static func runLoRAE2E(
        projectURL: URL,
        characterQuery: String,
        presetRawValue: String = "high",
        prompt: String? = nil,
        sceneSlug: String = "lora-smoke-test",
        onEvent: @escaping (String) -> Void = { _ in }
    ) async throws -> LoRAE2EResult {
        let requestedPreset = LORATrainingModels.TrainingPreset(rawValue: presetRawValue) ?? .high
        let preset = LORATrainingModels.TrainingPreset.high
        let animateURL = ProjectPaths(root: projectURL).animate
        let drawThingsConfig = DrawThingsPlaceConfig()
        var characters = try loadCharacters(animateURL: animateURL)

        guard let character = resolvedCharacter(
            matching: characterQuery,
            from: characters
        ) else {
            throw NSError(domain: "AnimateAutomation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not find character \(characterQuery)"])
        }

        let galleryState = ImagineGallerySelectionState.load(
            animateURL: animateURL,
            characterSlug: character.assetFolderSlug
        )
        let selectedPaths = Array(galleryState.loraSelectedPaths).sorted()
        guard !selectedPaths.isEmpty else {
            throw NSError(domain: "AnimateAutomation", code: 3, userInfo: [NSLocalizedDescriptionKey: "No LORA-selected images found for \(character.name)"])
        }

        let resolvedPaths = try selectedPaths.map { path in
            try resolveCharacterAssetPath(
                path,
                projectURL: projectURL,
                animateURL: animateURL
            ).path
        }

        var config = LORATrainingModels.TrainingConfig()
        config.preset = preset
        config.triggerWord = LORATrainingModels.generateTriggerWord(for: character.name)
        config.subjectClassNoun = character.genderType.promptNoun
        config.selectedImagePaths = resolvedPaths

        let service = RunPodLORAService.shared
        var lastStatus = ""
        var lastStep = -1
        var lastErrorMessage = ""

        onEvent("Starting RunPod LORA training for \(character.name)")
        if requestedPreset != .high {
            onEvent("requested_preset=\(requestedPreset.rawValue) overridden_to=high")
        }
        onEvent("preset=\(preset.rawValue) steps=\(config.steps) images=\(resolvedPaths.count) trigger=\(config.triggerWord)")

        try await service.startTraining(
            config: config,
            characterName: character.name,
            characterSlug: character.assetFolderSlug,
            imagePaths: resolvedPaths,
            animateURL: animateURL
        ) { job in
            let shouldPrint =
                job.status.rawValue != lastStatus ||
                job.currentStep != lastStep ||
                (job.errorMessage ?? "") != lastErrorMessage
            guard shouldPrint else { return }
            lastStatus = job.status.rawValue
            lastStep = job.currentStep
            lastErrorMessage = job.errorMessage ?? ""
            let progressBits = [
                "status=\(job.status.rawValue)",
                "step=\(job.currentStep)/\(job.totalSteps)"
            ] + (job.errorMessage.map { ["detail=\($0)"] } ?? [])
            onEvent(progressBits.joined(separator: " | "))
        }

        guard let outputLORAPath = service.currentJob?.outputLORAPath else {
            throw NSError(domain: "AnimateAutomation", code: 5, userInfo: [NSLocalizedDescriptionKey: "Training finished without an output LoRA path"])
        }

        let trainedFilename = URL(fileURLWithPath: outputLORAPath).lastPathComponent
        guard let characterIndex = characters.firstIndex(where: { $0.id == character.id }) else {
            throw NSError(domain: "AnimateAutomation", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to reload character state after training"])
        }
        characters[characterIndex].activeLORAFilename = trainedFilename
        characters[characterIndex].activeLORATriggerWord = config.triggerWord
        if characters[characterIndex].activeLORAWeight <= 0 {
            characters[characterIndex].activeLORAWeight = 1.0
        }
        try saveCharacter(
            characters[characterIndex],
            animateURL: animateURL
        )

        let syncedCharacter = characters[characterIndex]

        let syncedFilename = try await DrawThingsLoRAService().syncActiveLoRA(
            for: syncedCharacter,
            animateURL: animateURL,
            config: drawThingsConfig
        )

        let drawThingsLoRAPath = try await resolvedDrawThingsLoRAPath(
            filename: syncedFilename,
            config: drawThingsConfig
        )

        let smokePrompt = prompt ?? defaultSmokePrompt(for: syncedCharacter)
        let preparedPrompt = try await DrawThingsLoRAService().preparePrompt(
            prompt: smokePrompt,
            characters: characters,
            animateURL: animateURL,
            config: drawThingsConfig
        )
        let attachedLoRAs = preparedPrompt.loras
            .map { "\($0.file)@\($0.weight)" }
            .joined(separator: ", ")
        onEvent("drawthings_prompt=\(preparedPrompt.prompt)")
        onEvent("drawthings_loras=\(attachedLoRAs)")

        let generated = try await ImagineGenerationService().generateWithDrawThings(
            prompt: smokePrompt,
            model: .fluxKlein9B,
            config: drawThingsConfig,
            owpURL: projectURL,
            sceneSlug: sceneSlug,
            shotIndex: 0,
            moment: .beginning,
            characters: characters,
            batchSize: 1
        )

        guard let generatedImageURL = generated.first else {
            throw NSError(domain: "AnimateAutomation", code: 7, userInfo: [NSLocalizedDescriptionKey: "Draw Things returned no smoke-test image"])
        }

        let promptFileURL = generatedImageURL.deletingPathExtension().appendingPathExtension("prompt.txt")

        return LoRAE2EResult(
            characterName: syncedCharacter.name,
            projectLoRAPath: outputLORAPath,
            drawThingsLoRAPath: drawThingsLoRAPath.path,
            generatedImagePath: generatedImageURL.path,
            promptFilePath: promptFileURL.path
        )
    }

    private static func loadCharacters(
        animateURL: URL
    ) throws -> [AnimationCharacter] {
        let charactersDirectory = ProjectPaths(root: animateURL.deletingLastPathComponent()).animateCharacters
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: charactersDirectory.path) else {
            return []
        }

        let decoder = JSONDecoder()
        let directories = try fileManager.contentsOfDirectory(
            at: charactersDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return try directories.compactMap { directory in
            let rigURL = directory.appendingPathComponent("rig.json")
            guard fileManager.fileExists(atPath: rigURL.path) else { return nil }
            let data = try Data(contentsOf: rigURL)
            return try decoder.decode(AnimationCharacter.self, from: data)
        }
    }

    private static func saveCharacter(
        _ character: AnimationCharacter,
        animateURL: URL
    ) throws {
        let charPaths = ProjectPaths(root: animateURL.deletingLastPathComponent())
        let directory = charPaths.characterFolder(slug: character.assetFolderSlug)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rigURL = charPaths.characterRigJSON(slug: character.assetFolderSlug)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(character)
        try data.write(to: rigURL, options: .atomic)
    }

    private static func resolveCharacterAssetPath(
        _ path: String,
        projectURL: URL,
        animateURL: URL
    ) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AnimateAutomation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Empty selected image path"])
        }

        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: trimmed)
        if trimmed.hasPrefix("/"), fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let relativeCandidates: [String]
        if trimmed.hasPrefix("Animate/") {
            relativeCandidates = [trimmed]
        } else if trimmed.hasPrefix("characters/") || trimmed.hasPrefix("backgrounds/") {
            relativeCandidates = ["Animate/\(trimmed)", trimmed]
        } else if let animateRange = trimmed.range(of: "/Animate/") {
            relativeCandidates = ["Animate/" + trimmed[animateRange.upperBound...], trimmed]
        } else {
            relativeCandidates = [trimmed, "Animate/\(trimmed)"]
        }

        for candidate in relativeCandidates {
            let projectCandidate = projectURL.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: projectCandidate.path) {
                return projectCandidate
            }
            if candidate.hasPrefix("Animate/") {
                let animateRelative = String(candidate.dropFirst("Animate/".count))
                let animateCandidate = animateURL.appendingPathComponent(animateRelative)
                if fileManager.fileExists(atPath: animateCandidate.path) {
                    return animateCandidate
                }
            } else {
                let animateCandidate = animateURL.appendingPathComponent(candidate)
                if fileManager.fileExists(atPath: animateCandidate.path) {
                    return animateCandidate
                }
            }
        }

        throw NSError(domain: "AnimateAutomation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing selected image: \(path)"])
    }

    private static func resolvedCharacter(
        matching query: String,
        from characters: [AnimationCharacter]
    ) -> AnimationCharacter? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return characters.first {
            [$0.name, $0.assetFolderSlug, $0.owpSlug]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(normalized)
        }
    }

    private static func defaultSmokePrompt(for character: AnimationCharacter) -> String {
        "\(character.name), young army medic portrait, photorealistic cinematic documentary photography, realistic skin texture, detailed face, neutral studio background, natural lighting, NOT cartoon, NOT anime, NOT illustration, no text, no watermark"
    }

    private static func resolvedDrawThingsLoRAPath(
        filename: String,
        config: DrawThingsPlaceConfig
    ) async throws -> URL {
        guard var components = URLComponents(string: config.apiHost) else {
            throw NSError(domain: "AnimateAutomation", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid Draw Things host \(config.apiHost)"])
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        components.port = config.apiPort
        components.path = "/sdapi/v1/options"
        guard let url = components.url else {
            throw NSError(domain: "AnimateAutomation", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid Draw Things URL"])
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelName = payload["model"] as? String else {
            throw NSError(domain: "AnimateAutomation", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not resolve Draw Things model directory"])
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", modelName]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
              ) else {
            throw NSError(domain: "AnimateAutomation", code: 11, userInfo: [NSLocalizedDescriptionKey: "Spotlight lookup failed for Draw Things model \(modelName)"])
        }

        for line in output.split(separator: "\n") {
            let candidate = URL(fileURLWithPath: String(line))
            if candidate.lastPathComponent == modelName {
                return candidate.deletingLastPathComponent().appendingPathComponent(filename)
            }
        }

        throw NSError(domain: "AnimateAutomation", code: 12, userInfo: [NSLocalizedDescriptionKey: "Could not find Draw Things model directory for \(modelName)"])
    }
}
