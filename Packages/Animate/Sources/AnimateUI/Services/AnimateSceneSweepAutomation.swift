import Foundation
import ProjectKit

/// Namespace for CLI automation tasks.
@available(macOS 26.0, *)
public enum AnimateAutomation {}

@available(macOS 26.0, *)
public struct DrawThingsSceneSweepItemResult: Codable, Sendable {
    public let label: String
    public let songPath: String
    public let shotNumber: Int
    public let moment: String
    public let expectedCharacterSlugs: [String]
    public let imagePath: String
    public let promptFilePath: String
}

@available(macOS 26.0, *)
public struct DrawThingsSceneSweepResult: Sendable {
    public let outputDirectory: String
    public let items: [DrawThingsSceneSweepItemResult]
    public let failures: [String]
}

@available(macOS 26.0, *)
private struct DrawThingsSceneSweepSample: Sendable {
    let label: String
    let songPath: String
    let shotNumber: Int
    let moment: ImagineShotMoment
    let expectedCharacterSlugs: [String]
}

@available(macOS 26.0, *)
@MainActor
public extension AnimateAutomation {
    static func runDrawThingsSceneSweep(
        projectURL: URL,
        outputDirectoryURL: URL,
        drawThingsHost: String = "http://Garys-Server.local",
        drawThingsPort: Int = 7860,
        onEvent: @escaping (String) -> Void = { _ in }
    ) async throws -> DrawThingsSceneSweepResult {
        let store = AnimateStore()
        await store.openOWP(url: projectURL, skipBackgroundRefresh: true)

        let scenes = store.scenes
        guard !scenes.isEmpty else {
            throw NSError(
                domain: "AnimateAutomation",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "No scenes loaded from \(projectURL.path)"]
            )
        }

        let animateURL = ProjectPaths(root: projectURL).animate
        let samples = defaultDrawThingsSceneSweepSamples()
        let targetCharacterSlugs = Set(samples.flatMap(\.expectedCharacterSlugs))
        var drawThingsConfig = store.drawThingsPlaceConfig
        drawThingsConfig.apiHost = drawThingsHost
        drawThingsConfig.apiPort = drawThingsPort
        drawThingsConfig.negativePrompt = mergedNegativePrompt(
            existing: drawThingsConfig.negativePrompt
        )

        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let promptService = ImagineScenePromptService(store: store)
        let generationService = ImagineGenerationService()

        var itemResults: [DrawThingsSceneSweepItemResult] = []
        var failures: [String] = []

        for (index, sample) in samples.enumerated() {
            guard let scene = scenes.first(where: { $0.owpSongPath == sample.songPath }) else {
                let message = "missing_scene label=\(sample.label) song=\(sample.songPath)"
                failures.append(message)
                onEvent(message)
                continue
            }
            guard scene.shots.indices.contains(sample.shotNumber - 1) else {
                let message = "missing_shot label=\(sample.label) song=\(sample.songPath) shot=\(sample.shotNumber)"
                failures.append(message)
                onEvent(message)
                continue
            }

            onEvent("sample \(index + 1)/\(samples.count) label=\(sample.label) song=\(sample.songPath) shot=\(sample.shotNumber) moment=\(sample.moment.rawValue)")

            do {
                let basePrompt = promptService.prefillPrompt(
                    scene: scene,
                    shotIndex: sample.shotNumber - 1,
                    moment: sample.moment
                )
                let prompt = hardenedScenePrompt(
                    basePrompt,
                    expectedCharacterCount: sample.expectedCharacterSlugs.count
                )
                onEvent("prompt label=\(sample.label) text=\(prompt)")

                let capturedConfig = drawThingsConfig
                let capturedProjectURL = projectURL
                let capturedSceneSlug = sanitizedSlug(for: scene.owpSongPath)
                let capturedShotIndex = sample.shotNumber - 1
                let capturedMoment = sample.moment
                let capturedCharacters = store.characters
                let savedImages = try await retryingGeneration(maxAttempts: 3) {
                    try await generationService.generateWithDrawThings(
                        prompt: prompt,
                        model: .fluxKlein9B,
                        config: capturedConfig,
                        owpURL: capturedProjectURL,
                        sceneSlug: capturedSceneSlug,
                        shotIndex: capturedShotIndex,
                        moment: capturedMoment,
                        characters: capturedCharacters,
                        batchSize: 1
                    )
                }

                guard let generatedImageURL = savedImages.first else {
                    throw NSError(
                        domain: "AnimateAutomation",
                        code: 21,
                        userInfo: [NSLocalizedDescriptionKey: "Draw Things returned no image for \(sample.label)"]
                    )
                }

                let promptFileURL = generatedImageURL.deletingPathExtension().appendingPathExtension("prompt.txt")
                let imageDestinationURL = outputDirectoryURL.appendingPathComponent("\(sample.label).png")
                let promptDestinationURL = outputDirectoryURL.appendingPathComponent("\(sample.label).prompt.txt")

                try replaceItem(at: imageDestinationURL, with: generatedImageURL)
                if FileManager.default.fileExists(atPath: promptFileURL.path) {
                    try replaceItem(at: promptDestinationURL, with: promptFileURL)
                } else {
                    try prompt.write(to: promptDestinationURL, atomically: true, encoding: .utf8)
                }

                itemResults.append(
                    DrawThingsSceneSweepItemResult(
                        label: sample.label,
                        songPath: sample.songPath,
                        shotNumber: sample.shotNumber,
                        moment: sample.moment.rawValue,
                        expectedCharacterSlugs: sample.expectedCharacterSlugs,
                        imagePath: imageDestinationURL.path,
                        promptFilePath: promptDestinationURL.path
                    )
                )

                onEvent("generated label=\(sample.label) image=\(imageDestinationURL.lastPathComponent)")
            } catch {
                let message = "failed label=\(sample.label) reason=\(error.localizedDescription)"
                failures.append(message)
                onEvent(message)
            }
        }

        let manifestURL = outputDirectoryURL.appendingPathComponent("manifest.json")
        let manifest = SceneSweepManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            drawThingsHost: drawThingsHost,
            drawThingsPort: drawThingsPort,
            items: itemResults,
            failures: failures
        )
        let manifestData = try JSONEncoder.sceneSweepEncoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        return DrawThingsSceneSweepResult(
            outputDirectory: outputDirectoryURL.path,
            items: itemResults,
            failures: failures
        )
    }
}

@available(macOS 26.0, *)
private extension AnimateAutomation {
    static func defaultDrawThingsSceneSweepSamples() -> [DrawThingsSceneSweepSample] {
        [
            .init(label: "01-lukes-notebook-luke", songPath: "Songs/1.03.0 - Scene - Luke's Notebook.ows", shotNumber: 3, moment: .middle, expectedCharacterSlugs: ["luke"]),
            .init(label: "02-assignment-luke-matt-mark", songPath: "Songs/1.04.0 - Scene - Assignment.ows", shotNumber: 12, moment: .middle, expectedCharacterSlugs: ["luke", "matt", "mark"]),
            .init(label: "03-silver-mark", songPath: "Songs/1.05.0 - Silver.ows", shotNumber: 11, moment: .middle, expectedCharacterSlugs: ["mark"]),
            .init(label: "04-shortcut-luke-matt", songPath: "Songs/1.08.0 - The Shortcut.ows", shotNumber: 9, moment: .middle, expectedCharacterSlugs: ["luke", "matt"]),
            .init(label: "05-lay-down-your-burdens-amira", songPath: "Songs/1.11.0 - Lay Down Your Burdens.ows", shotNumber: 8, moment: .middle, expectedCharacterSlugs: ["amira"]),
            .init(label: "06-first-meeting-luke-amira", songPath: "Songs/1.14.0 - First Meeting.ows", shotNumber: 19, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "07-after-the-incident-luke-amira", songPath: "Songs/1.15.0 - Scene - After The Incident.ows", shotNumber: 3, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "08-lament-amira", songPath: "Songs/1.17.0 - Lament.ows", shotNumber: 5, moment: .middle, expectedCharacterSlugs: ["amira"]),
            .init(label: "09-amiras-interruption-luke-amira", songPath: "Songs/1.22.0 - Scene - Amira's Interruption.ows", shotNumber: 15, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "10-time-of-war-luke-amira", songPath: "Songs/1.25.0 - Time Of War.ows", shotNumber: 1, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "11-a-new-life-luke-amira", songPath: "Songs/1.28.0 - A New Life.ows", shotNumber: 1, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "12-amira-shows-journal-luke-amira", songPath: "Songs/1.31.1 - Scene - Amira Shows Luke The Journal.ows", shotNumber: 2, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "13-who-gets-written-matt-mark", songPath: "Songs/1.37.0 - Scene - Who Gets Written.ows", shotNumber: 12, moment: .middle, expectedCharacterSlugs: ["matt", "mark"]),
            .init(label: "14-lukes-packet-luke-matt", songPath: "Songs/1.41.0 - Scene - Luke's Packet.ows", shotNumber: 1, moment: .middle, expectedCharacterSlugs: ["luke", "matt"]),
            .init(label: "15-act1-finale-luke-amira", songPath: "Songs/1.44.0 - Something More (Act I Finale).ows", shotNumber: 22, moment: .end, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "16-entracte-luke-mark", songPath: "Songs/2.01.0 - Entracte (Act II Opening).ows", shotNumber: 9, moment: .middle, expectedCharacterSlugs: ["luke", "mark"]),
            .init(label: "17-the-confession-luke-amira", songPath: "Songs/2.09.0 - The Confession.ows", shotNumber: 1, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "18-the-teacher-luke-amira", songPath: "Songs/2.13.0 - Scene - The Teacher.ows", shotNumber: 1, moment: .middle, expectedCharacterSlugs: ["luke", "amira"]),
            .init(label: "19-marks-handoff-mark", songPath: "Songs/2.25.0 - Scene - Mark's Handoff.ows", shotNumber: 1, moment: .middle, expectedCharacterSlugs: ["mark"]),
            .init(label: "20-matts-copy-matt", songPath: "Songs/2.27.0 - Scene - Matt's Copy.ows", shotNumber: 1, moment: .middle, expectedCharacterSlugs: ["matt"])
        ]
    }

    static func retryingGeneration(
        maxAttempts: Int,
        operation: @escaping @Sendable () async throws -> [URL]
    ) async throws -> [URL] {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                try? await Task.sleep(for: .seconds(Double(attempt) * 2.0))
            }
        }
        throw lastError ?? NSError(domain: "AnimateAutomation", code: 23, userInfo: [NSLocalizedDescriptionKey: "Image generation failed"])
    }

    static func replaceItem(
        at destinationURL: URL,
        with sourceURL: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    static func sanitizedSlug(
        for songPath: String
    ) -> String {
        let base = URL(fileURLWithPath: songPath).deletingPathExtension().lastPathComponent
        let lowered = base.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(mapped).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func hardenedScenePrompt(
        _ basePrompt: String,
        expectedCharacterCount: Int
    ) -> String {
        let cleanedBase = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let guardrail: String
        if expectedCharacterCount <= 1 {
            guardrail = "One complete visible person only, fully formed and opaque, no ghost figure, no duplicate body, no partial person, no cropped half-person at frame edge."
        } else {
            guardrail = "\(expectedCharacterCount) complete visible people only, one body per named character, each fully formed and opaque, distinct faces and distinct posture, no ghost figures, no partial people, no duplicate bodies, no double exposure, no cropped half-person at frame edge."
        }
        return [cleanedBase, guardrail]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func mergedNegativePrompt(
        existing: String
    ) -> String {
        let additions = [
            "ghost person",
            "transparent person",
            "partial person",
            "half person",
            "cropped person",
            "duplicate person",
            "double exposure",
            "motion ghosting",
            "extra body",
            "extra person",
            "disembodied limbs",
            "floating limbs",
            "fused body",
            "cloned face",
            "same face"
        ]

        return ([existing] + additions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

@available(macOS 26.0, *)
private struct SceneSweepManifest: Encodable {
    let generatedAt: String
    let drawThingsHost: String
    let drawThingsPort: Int
    let items: [DrawThingsSceneSweepItemResult]
    let failures: [String]
}

@available(macOS 26.0, *)
private extension JSONEncoder {
    static var sceneSweepEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
