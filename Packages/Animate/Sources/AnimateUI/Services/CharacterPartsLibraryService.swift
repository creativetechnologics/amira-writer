import Foundation
import AppKit
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class CharacterPartsLibraryService {
    private let store: AnimateStore

    static let gridColumns = 4
    static let gridRows = 3
    static let totalCells = gridColumns * gridRows

    static let cellLayout: [(kind: PartKind, emotion: String?)] = [
        (.front, nil),
        (.quarterLeft, nil),
        (.quarterRight, nil),
        (.back, nil),

        (.front, "angry"),
        (.front, "sad"),
        (.front, "happy"),
        (.front, "surprised"),

        (.leftProfile, nil),
        (.rightProfile, nil),
        (.front, "fearful"),
        (.front, nil),
    ]

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

    // MARK: - Grid Generation

    func generatePartsGrid(
        character: AnimationCharacter,
        costume: CharacterCostumeReferenceSet,
        projectRoot: URL
    ) async throws -> [CharacterPart] {
        let apiKey = store.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }

        guard let frontSlot = costume.fullBodySlots.first(where: { $0.pose == .frontNeutral }),
              let referencePath = frontSlot.approvedVariant?.imagePath else {
            throw ServiceError.noReferenceImage
        }

        let referenceURL = store.resolvedCharacterAssetURL(for: referencePath)
            ?? URL(fileURLWithPath: referencePath)
        let referenceData = (try? Data(contentsOf: referenceURL)) ?? Data()
        guard !referenceData.isEmpty else { throw ServiceError.noReferenceImage }

        let gridPrompt = buildGridPrompt(character: character, costume: costume)

        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: gridPrompt,
            referenceImages: [
                GeminiImageService.ReferenceImage(
                    data: referenceData.base64EncodedString(),
                    mimeType: "image/png"
                )
            ],
            model: .flash,
            aspectRatio: "1:1",
            imageSize: "4K"
        )

        let result = try await service.generate(request: request, apiKey: apiKey)
        let imageData = result.imageData
        guard !imageData.isEmpty else { throw ServiceError.noImageReturned }

        return try sliceAndSaveGrid(imageData: imageData, character: character, costume: costume, projectRoot: projectRoot)
    }

    // MARK: - Prompt

    private func buildGridPrompt(
        character: AnimationCharacter,
        costume: CharacterCostumeReferenceSet
    ) -> String {
        let cols = Self.gridColumns
        let rows = Self.gridRows

        let cellDescriptions = Self.cellLayout.enumerated().map { idx, cell -> String in
            let row = idx / cols
            let col = idx % cols
            let view: String
            switch cell.kind {
            case .front: view = "front-facing"
            case .back: view = "back view"
            case .leftProfile: view = "left profile"
            case .rightProfile: view = "right profile"
            case .quarterLeft: view = "three-quarter turned to their left"
            case .quarterRight: view = "three-quarter turned to their right"
            }
            let expr = cell.emotion.map { " with a \($0) expression on their face" } ?? " with a neutral/calm expression"
            return "  - Row \(row+1), Column \(col+1): \(character.name) in \(view) view\(expr), wearing the \(costume.name) outfit, full-body standing on white background"
        }.joined(separator: "\n")

        return """
        Generate a clean character reference grid image arranged in a perfect \(cols)×\(rows) grid (\(cols) columns, \(rows) rows) with uniform-sized cells.
        Every cell has a solid white (#FFFFFF) background.
        Maintain CONSISTENT scale, proportions, and framing across ALL cells. Each cell should show the character at the same relative size.
        The grid lines between cells should be barely visible — thin 1px light gray lines (E0E0E0).

        GRID SPOTS:
        \(cellDescriptions)

        STYLE: Clean flat-color 2D animation reference art. No gradients, no shading, no drop shadows.
        Each character stands on the same imaginary ground line so their feet align across cells.
        Clean linework, consistent proportions.
        No text labels, no watermarks, no frame borders, no cell numbers.
        Every cell has pure white background.
        """
    }

    // MARK: - Slice & Save

    private func sliceAndSaveGrid(
        imageData: Data,
        character: AnimationCharacter,
        costume: CharacterCostumeReferenceSet,
        projectRoot: URL
    ) throws -> [CharacterPart] {
        guard let image = NSImage(data: imageData),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            throw ServiceError.slicingFailed
        }

        let fullW = rep.pixelsWide
        let fullH = rep.pixelsHigh
        let cellW = fullW / Self.gridColumns
        let cellH = fullH / Self.gridRows

        guard cellW >= 128, cellH >= 128 else {
            throw ServiceError.slicingFailed
        }

        let dir = partsDirectory(projectRoot: projectRoot, characterSlug: character.owpSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var manifest = loadManifest(projectRoot: projectRoot, characterSlug: character.owpSlug)
        manifest.parts = []
        var parts: [CharacterPart] = []

        // Save full grid
        let gridFilename = "\(character.owpSlug)-parts-grid.png"
        let gridURL = dir.appendingPathComponent(gridFilename)
        try imageData.write(to: gridURL)

        for idx in 0..<Self.totalCells {
            let cell = Self.cellLayout[idx]
            let col = idx % Self.gridColumns
            let row = idx / Self.gridColumns

            let rect = NSRect(
                x: col * cellW,
                y: fullH - (row + 1) * cellH,
                width: cellW,
                height: cellH
            )

            guard let cellImage = cropCell(from: rep, rect: rect) else { continue }
            guard let cellData = cellImage.representation(using: .png, properties: [:]) else { continue }

            let filename = partFilename(slug: character.owpSlug, kind: cell.kind, emotion: cell.emotion)
            let cellURL = dir.appendingPathComponent(filename)
            try cellData.write(to: cellURL)

            let bbox = computeBoundingBox(imageData: cellData)

            let part = CharacterPart(
                characterSlug: character.owpSlug,
                costumeName: costume.name,
                partKind: cell.kind,
                emotion: cell.emotion,
                imagePath: filename,
                boundingBox: bbox,
                generationPrompt: "Grid cell \(row+1),\(col+1)"
            )
            parts.append(part)
        }

        manifest.parts = parts
        manifest.updatedAt = Date()
        try saveManifest(manifest, projectRoot: projectRoot)

        return parts
    }

    private func cropCell(from rep: NSBitmapImageRep, rect: NSRect) -> NSBitmapImageRep? {
        guard let cropped = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(rect.width),
            pixelsHigh: Int(rect.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: cropped)
        rep.draw(in: NSRect(x: 0, y: 0, width: rect.width, height: rect.height),
                 from: rect,
                 operation: .copy,
                 fraction: 1.0,
                 respectFlipped: false,
                 hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        return cropped
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
        guard let image = NSImage(data: imageData),
              let tiff = image.tiffRepresentation,
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
        case slicingFailed

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "Gemini API key is not set"
            case .noReferenceImage: "No approved reference image found for this costume"
            case .noImageReturned: "Gemini did not return an image"
            case .slicingFailed: "Failed to slice the generated grid into individual parts"
            }
        }
    }
}
