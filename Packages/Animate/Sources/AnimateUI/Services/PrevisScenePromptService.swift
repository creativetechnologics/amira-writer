import Foundation

@available(macOS 26.0, *)
@MainActor
final class PrevisScenePromptService {
    private let store: AnimateStore

    init(store: AnimateStore) {
        self.store = store
    }

    func generateLayout(scene: AnimationScene, shot: AnimationSceneShot) async throws -> ShotPrevis3DState {
        let shotIndex = scene.shots.firstIndex(where: { $0.id == shot.id }) ?? 0
        let contextBlock = buildContextBlock(scene: scene, shot: shot, shotIndex: shotIndex)

        let instruction = """
        You are a film director and 3D pre-visualization artist. You output camera positions, character positions/rotations, and environment notes for a 3D pre-viz scene.

        The scene uses a three.js viewer with:
        - a ground plane at y=0
        - characters loaded from GLB files
        - a perspective camera with OrbitControls

        Output format: a JSON object matching this schema:

        {
          "keyframes": [
            { "label": "beginning", "position": [x, y, z], "lookAt": [x, y, z], "fov": number },
            { "label": "middle", "position": [x, y, z], "lookAt": [x, y, z], "fov": number },
            { "label": "end", "position": [x, y, z], "lookAt": [x, y, z], "fov": number }
          ],
          "characterPoses": {
            "character_slug": {
              "characterSlug": "slug",
              "costumeName": "costume name",
              "position": [x, y, z],
              "rotation": [yaw, pitch, roll],
              "scale": 1,
              "boneRotations": {
                "head": [yaw, pitch, roll],
                "spine": [yaw, pitch, roll]
              }
            }
          },
          "objectTransforms": {},
          "environmentConfig": {
            "placeID": null,
            "groundType": "grid",
            "backdropColor": "#1a1f27"
          },
          "lightingPreset": "golden-hour"
        }

        RULES FOR CAMERA PLACEMENT:
        - The camera looks at the characters' midpoint (typically y=1.2 for human eye-level)
        - Position should match the shot type:
          * extreme_wide: distance 8m, fov 60
          * wide: distance 5m, fov 55
          * medium: distance 3m, fov 50
          * medium_close: distance 2m, fov 45
          * close: distance 1m, fov 35
          * extreme_close: distance 0.5m, fov 25
        - Default focal character should be in the center of the frame
        - Camera z should typically be positive (behind the subject) or offset
        - Camera y should be 1.3-1.8m for eye-level, 2-3m for slight high angle, 0.8-1m for slight low angle
        - Beginning/Middle/End keyframes should share the SAME camera setup unless the stage directions indicate camera movement

        RULES FOR CHARACTER PLACEMENT:
        - position: [x, y, z] where x is left-right (negative = left), y is height (0 = floor), z is depth (negative = farther away)
        - rotation: [yaw_degrees, 0, 0] where yaw is facing direction (0 = face +z/-z direction)
        - scale: 1 for normal size
        - If one character is the focus, place them at origin (0, 0, 0)
        - If two characters, place focus at (0, 0, 0) and secondary at (0.8, 0, 0) or (-0.8, 0, 0) depending on blocking
        - Bone rotations are in degrees. Only include non-zero bone rotations.
        - head yaw: -20 = looking left, +20 = looking right
        - spine yaw: ±10-15 for slight body rotation

        RULES FOR LIGHTING:
        - Choose from: "golden-hour", "noon", "night-interior", "overcast"
        - Match the scene time-of-day and mood from the context

        CONTEXT FOR THIS SHOT:
        \(contextBlock)

        Return ONLY the JSON object. No explanation, no markdown, no code blocks. Just the JSON.
        """

        let jsonText = try await completeInstruction(instruction)
        let cleaned = cleanJSONOutput(jsonText)

        guard let data = cleaned.data(using: .utf8),
              let state = try? JSONDecoder().decode(ShotPrevis3DState.self, from: data)
        else {
            throw ServiceError.invalidJSON(String(cleaned.prefix(200)))
        }

        return state
    }

    private func completeInstruction(_ instruction: String) async throws -> String {
        let openAIKey = store.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openAIKey.isEmpty {
            return try await OpenAITextGenerationService().generateText(
                instruction: instruction,
                apiKey: openAIKey
            )
        }
        return try await ImagineScenePromptService.runCodexExecStatic(instruction: instruction)
    }

    private func cleanJSONOutput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Context Builder

    private func buildContextBlock(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int
    ) -> String {
        var parts: [String] = []

        parts.append("SCENE: \(sceneDisplayName(scene))")
        parts.append("SHOT: \(shot.name) (#\(shotIndex + 1) of \(scene.shots.count))")

        if let camera = shot.cameraShot {
            parts.append("CAMERA SHOT TYPE: \(camera.rawValue)")
        } else if let defaultCam = scene.directionTemplate?.defaultCameraShot {
            parts.append("CAMERA SHOT TYPE (default): \(defaultCam.rawValue)")
        }

        if let intent = shot.shotIntent {
            parts.append("SHOT INTENT: \(intent.rawValue)")
        }

        if !shot.notes.isEmpty {
            parts.append("STAGE DIRECTIONS: \(shot.notes)")
        }

        if let lyric = shot.sourceLyricExcerpt, !lyric.isEmpty {
            parts.append("DIALOGUE: \"\(lyric)\"")
        }

        // Characters
        let sceneChars = orderedSceneCharacters(for: scene, shot: shot)
        if !sceneChars.isEmpty {
            parts.append("VISIBLE CHARACTERS:")
            for char in sceneChars {
                let isFocus = char.owpSlug == shot.focusCharacterSlug
                let marker = isFocus ? "FOCUS" : "secondary"
                var desc = "  - \(marker): \(char.name) (slug: \(char.owpSlug))"
                if !char.description.isEmpty {
                    desc += " — \(char.description.prefix(200))"
                }
                if let age = char.age {
                    desc += " (age ~\(age))"
                }
                desc += " — wardrobe: \(char.defaultWardrobeType.rawValue)"
                parts.append(desc)
            }
        }

        // Place / background
        if let backgroundID = scene.backgroundID,
           let place = store.backgrounds.first(where: { $0.id == backgroundID }) {
            var placeLines: [String] = ["PLACE: \(place.name)"]
            for field in [place.visualBrief, place.coreIdentity, place.physicalLayoutAndTopography, place.visualContinuityAnchors] {
                let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { placeLines.append(trimmed) }
            }
            parts.append(placeLines.joined(separator: " | "))
        }

        // Scene overview
        if let template = scene.directionTemplate, !template.notes.isEmpty {
            parts.append("SCENE OVERVIEW: \(template.notes)")
        }

        return parts.joined(separator: "\n")
    }

    private func orderedSceneCharacters(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> [AnimationCharacter] {
        let searchable = [shot.name, shot.notes, shot.sourceLyricExcerpt ?? "", scene.directionTemplate?.notes ?? ""]
            .joined(separator: "\n")

        let sceneChars = store.characters.filter {
            scene.characterSlugs.contains($0.owpSlug) ||
            $0.owpSlug == shot.focusCharacterSlug ||
            characterIsMentioned($0, in: searchable)
        }

        guard let focusSlug = shot.focusCharacterSlug else { return sceneChars }
        return sceneChars.sorted { lhs, rhs in
            if lhs.owpSlug == focusSlug { return true }
            if rhs.owpSlug == focusSlug { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func characterIsMentioned(_ character: AnimationCharacter, in text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains(character.name.lowercased()) || lower.contains(character.owpSlug.lowercased())
    }

    private func sceneDisplayName(_ scene: AnimationScene) -> String {
        URL(fileURLWithPath: scene.owpSongPath).deletingPathExtension().lastPathComponent
    }
}

@available(macOS 26.0, *)
extension PrevisScenePromptService {
    enum ServiceError: LocalizedError {
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let text):
                return "Failed to parse LLM layout JSON: \(text)"
            }
        }
    }
}
