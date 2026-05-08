import Foundation
import AppKit
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class CharacterPartsLibraryService {
    private let store: AnimateStore

    init(store: AnimateStore) {
        self.store = store
    }

    // MARK: - Parts Directory

    func partsDirectory(projectRoot: URL, characterSlug: String) -> URL {
        ProjectPaths(root: projectRoot)
            .characterFolder(slug: characterSlug)
            .appendingPathComponent("parts-library", isDirectory: true)
    }

    private func manifestURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("manifest.json")
    }

    // MARK: - Manifest

    func loadManifest(projectRoot: URL, characterSlug: String) -> CharacterPartsManifest {
        let dir = partsDirectory(projectRoot: projectRoot, characterSlug: characterSlug)
        let url = manifestURL(dir)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CharacterPartsManifest.self, from: data)
        else {
            return CharacterPartsManifest(characterSlug: characterSlug, parts: [])
        }
        return manifest
    }

    func saveManifest(_ manifest: CharacterPartsManifest, projectRoot: URL) throws {
        let dir = partsDirectory(projectRoot: projectRoot, characterSlug: manifest.characterSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(dir))
    }

    // MARK: - Generation

    func generatePart(
        character: AnimationCharacter,
        costume: CharacterCostumeReferenceSet,
        partKind: PartKind,
        emotion: String? = nil,
        projectRoot: URL
    ) async throws -> CharacterPart {
        let apiKey = store.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ServiceError.noAPIKey
        }

        // Find the front-neutral reference image from the costume
        guard let frontSlot = costume.fullBodySlots.first(where: { $0.pose == .frontNeutral }),
              let referencePath = frontSlot.approvedVariant?.imagePath else {
            throw ServiceError.noReferenceImage
        }

        let referenceURL = store.resolvedCharacterAssetURL(for: referencePath)
            ?? URL(fileURLWithPath: referencePath)

        guard let referenceData = try? Data(contentsOf: referenceURL) else {
            throw ServiceError.noReferenceImage
        }

        let prompt = buildPrompt(character: character, costume: costume, partKind: partKind, emotion: emotion)

        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: prompt,
            referenceImages: [
                GeminiImageService.ReferenceImage(
                    data: referenceData.base64EncodedString(),
                    mimeType: "image/png"
                )
            ],
            model: .flash,
            aspectRatio: "3:4",
            imageSize: "1K"
        )

        let result = try await service.generate(request: request, apiKey: apiKey)
        let imageData = result.imageData
        guard !imageData.isEmpty else {
            throw ServiceError.noImageReturned
        }

        // Save the generated part
        let dir = partsDirectory(projectRoot: projectRoot, characterSlug: character.owpSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let filename = partFilename(slug: character.owpSlug, kind: partKind, emotion: emotion)
        let imageURL = dir.appendingPathComponent(filename)
        try imageData.write(to: imageURL)

        // Compute bounding box
        let bbox = computeBoundingBox(imageData: imageData)

        let part = CharacterPart(
            characterSlug: character.owpSlug,
            costumeName: costume.name,
            partKind: partKind,
            emotion: emotion,
            imagePath: filename,
            boundingBox: bbox,
            generationPrompt: prompt
        )

        // Update manifest
        var manifest = loadManifest(projectRoot: projectRoot, characterSlug: character.owpSlug)
        manifest.parts.removeAll { $0.partKind == partKind && $0.emotion == emotion }
        manifest.parts.append(part)
        manifest.updatedAt = Date()
        try saveManifest(manifest, projectRoot: projectRoot)

        return part
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        character: AnimationCharacter,
        costume: CharacterCostumeReferenceSet,
        partKind: PartKind,
        emotion: String?
    ) -> String {
        var parts: [String] = []

        parts.append("Generate a clean character illustration of \(character.name)")

        if !character.description.isEmpty {
            parts.append("(\(character.description.prefix(300)))")
        }

        parts.append("wearing their \(costume.name) outfit")
        parts.append("on a solid white background (#FFFFFF)")

        parts.append("View: \(partKind.angleDescription)")
        parts.append("Full-body, standing pose, neutral arms at sides")

        if let emotion = emotion {
            parts.append("Expression: \(emotion)")
            if emotion == "angry" { parts.append("furrowed brow, tense jaw, determined stare") }
            if emotion == "sad" { parts.append("downcast eyes, slight frown, softened posture") }
            if emotion == "happy" { parts.append("gentle smile, bright eyes, relaxed stance") }
            if emotion == "surprised" { parts.append("raised eyebrows, slightly open mouth, alert posture") }
            if emotion == "fearful" { parts.append("wide eyes, tense shoulders, defensive stance") }
        } else {
            parts.append("Expression: neutral, calm")
        }

        parts.append("Style: clean vector-style 2D animation art, flat colors, crisp edges, no shading")
        parts.append("Solid pure white background only, tight framing around the character, no shadow on the floor")
        parts.append("No text, no watermark, no frame border")

        return parts.joined(separator: ". ")
    }

    // MARK: - Filenames

    private func partFilename(slug: String, kind: PartKind, emotion: String?) -> String {
        if let emotion = emotion {
            return "\(slug)-\(kind.rawValue)-\(emotion).png"
        }
        return "\(slug)-\(kind.rawValue).png"
    }

    // MARK: - Bounding Box

    private func computeBoundingBox(imageData: Data) -> PartBoundingBox? {
        guard let image = NSImage(data: imageData) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }

        var minX = w, minY = h, maxX = 0, maxY = 0
        var found = false

        for y in 0..<h {
            for x in 0..<w {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent
                let g = color.greenComponent
                let b = color.blueComponent
                // Detect non-white pixels (white = all ≈ 1.0)
                if r < 0.95 || g < 0.95 || b < 0.95 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    found = true
                }
            }
        }

        guard found else { return nil }

        return PartBoundingBox(
            minX: Double(minX) / Double(w),
            minY: Double(minY) / Double(h),
            maxX: Double(maxX) / Double(w),
            maxY: Double(maxY) / Double(h)
        )
    }

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case noAPIKey
        case noReferenceImage
        case noImageReturned

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "Gemini API key is not set"
            case .noReferenceImage: "No approved reference image found for this costume"
            case .noImageReturned: "Gemini did not return an image"
            }
        }
    }
}
