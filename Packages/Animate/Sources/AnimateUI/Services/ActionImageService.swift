import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
struct ActionImageService {

    struct ActionPose: Identifiable, Codable, Sendable {
        var id: UUID = UUID()
        var characterSlug: String
        var sceneName: String
        var description: String
        var prompt: String
        var imagePath: String?
        var source: String  // "script" or "manual"
    }

    /// Scan all scenes for a character and extract action poses they need.
    /// Returns pose descriptions derived from shot notes, lyrics, and direction templates.
    static func scanPosesFromScript(
        for character: AnimationCharacter,
        scenes: [AnimationScene]
    ) -> [ActionPose] {
        let characterScenes = scenes.filter { $0.characterSlugs.contains(character.owpSlug) }
        var poses: [ActionPose] = []
        var seenDescriptions = Set<String>()

        for scene in characterScenes {
            // Extract action hints from shot notes
            for shot in scene.shots {
                if !shot.notes.isEmpty {
                    let desc = shot.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = desc.lowercased()
                    guard !normalized.isEmpty, seenDescriptions.insert(normalized).inserted else { continue }
                    poses.append(ActionPose(
                        characterSlug: character.assetFolderSlug,
                        sceneName: scene.name,
                        description: desc,
                        prompt: "",  // Will be filled by MiniMax
                        source: "script"
                    ))
                }

                // Extract from lyric excerpts that imply action
                if let lyric = shot.sourceLyricExcerpt, !lyric.isEmpty {
                    let normalized = lyric.lowercased()
                    guard seenDescriptions.insert(normalized).inserted else { continue }
                    poses.append(ActionPose(
                        characterSlug: character.assetFolderSlug,
                        sceneName: scene.name,
                        description: "Action from lyrics: \(lyric)",
                        prompt: "",
                        source: "script"
                    ))
                }
            }

            // Extract from direction template notes
            if let template = scene.directionTemplate, !template.notes.isEmpty {
                let normalized = template.notes.lowercased()
                guard seenDescriptions.insert(normalized).inserted else { continue }
                poses.append(ActionPose(
                    characterSlug: character.assetFolderSlug,
                    sceneName: scene.name,
                    description: template.notes,
                    prompt: "",
                    source: "script"
                ))
            }
        }

        return poses
    }

    /// Use the configured supplemental LLM to generate an image generation prompt for an action pose.
    static func generatePrompt(
        for pose: ActionPose,
        character: AnimationCharacter,
        configuration: SupplementalLLMConfiguration
    ) async throws -> String {
        guard !configuration.apiKey.isEmpty else { throw ActionImageError.noAPIKey }

        let subject = character.age.map { "a \($0)-year-old \(character.genderType.promptNoun)" }
            ?? "a \(character.genderType.promptNoun)"

        let systemPrompt = """
        You are an expert at writing image generation prompts for character action poses.

        RULES:
        1. NEVER include character names or proper nouns.
        2. Describe the pose physically: body position, limb placement, weight distribution, direction of movement.
        3. Include: camera angle, lighting, background context, art style.
        4. Translate any scene labels, script shorthand, or internal references into concrete visible details instead of quoting them.
        5. Describe only what the image model can actually see in the frame.
        6. Output ONLY the prompt text, nothing else.
        """

        let userPrompt = """
        Generate an image prompt for \(subject) performing this action:

        Hidden context label (do not mention directly): \(pose.sceneName)
        Action brief: \(pose.description)

        Make it a full-body dynamic action pose with clear body mechanics, cinematic lighting, and a believable grounded environment.
        """

        return try await SupplementalLLMClient(configuration: configuration)
            .complete(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.7,
                maxTokens: 500,
                jsonMode: false
            )
    }

    /// Directory where action images are stored for a character.
    static func actionImagesDirectory(animateURL: URL, characterSlug: String) -> URL {
        ProjectPaths(root: animateURL.deletingLastPathComponent())
            .characterActionImages(slug: characterSlug)
    }

    /// Scan existing action images from disk.
    static func scanExistingImages(animateURL: URL, characterSlug: String) -> [String] {
        let dir = actionImagesDirectory(animateURL: animateURL, characterSlug: characterSlug)
        return ImagineProjectStorage.scanImages(in: dir)
    }

    /// Persistence path for the poses JSON.
    static func posesJSONPath(animateURL: URL, characterSlug: String) -> URL {
        actionImagesDirectory(animateURL: animateURL, characterSlug: characterSlug)
            .appendingPathComponent("poses.json")
    }

    static func loadPoses(animateURL: URL, characterSlug: String) -> [ActionPose] {
        let url = posesJSONPath(animateURL: animateURL, characterSlug: characterSlug)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONCoders.makeDecoder().decode([ActionPose].self, from: data)) ?? []
    }

    static func savePoses(_ poses: [ActionPose], animateURL: URL, characterSlug: String) throws {
        let dir = actionImagesDirectory(animateURL: animateURL, characterSlug: characterSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = posesJSONPath(animateURL: animateURL, characterSlug: characterSlug)
        let encoder = JSONCoders.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(poses).write(to: url, options: .atomic)
    }

    enum ActionImageError: LocalizedError {
        case noAPIKey, invalidEndpoint, requestFailed, invalidResponse
        var errorDescription: String? {
            switch self {
            case .noAPIKey: "Supplemental LLM API key is not set."
            case .invalidEndpoint: "Supplemental LLM endpoint URL is invalid."
            case .requestFailed: "Supplemental LLM request failed."
            case .invalidResponse: "Invalid response from supplemental LLM."
            }
        }
    }
}
