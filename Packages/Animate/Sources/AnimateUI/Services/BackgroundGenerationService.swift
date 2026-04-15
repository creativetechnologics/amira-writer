import AppKit
import Foundation

/// Generates background plate images for all locations in the world catalog.
///
/// For each location entry it first checks if Gemini image generation is available.
/// If a Gemini API key is set, it uses `GeminiImageService` to generate a photorealistic
/// background; otherwise it falls back to a Core Graphics gradient placeholder using
/// `BackgroundPlaceholderService`-style rendering with location-specific colours.
///
/// Generated images are saved to `<owpURL>/Animate/backgrounds/<location-slug>.png`.
/// Progress is reported via an `onProgress` callback.
@available(macOS 26.0, *)
@MainActor
final class BackgroundGenerationService {

    // MARK: - Types

    struct WorldCatalog: Codable {
        var locations: [LocationEntry]
    }

    struct LocationEntry: Codable, Identifiable {
        var id: UUID
        var name: String
        var slug: String
        var description: String?
        var timeOfDay: String?
        var lighting: String?
    }

    struct GenerationResult {
        let locationSlug: String
        let outputURL: URL
        let usedGemini: Bool
    }

    enum GenerationError: LocalizedError {
        case noProjectURL
        case catalogNotFound
        case imageRenderFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProjectURL:
                return "No project URL is set."
            case .catalogNotFound:
                return "world-catalog.json not found in Animate/3d/world-catalog/."
            case .imageRenderFailed(let msg):
                return "Failed to render background image: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Generate background plates for every location in the world catalog.
    ///
    /// - Parameters:
    ///   - owpURL: The project root URL.
    ///   - geminiAPIKey: Optional Gemini API key; if non-empty, uses AI generation.
    ///   - onProgress: Called on the main actor with `(completedCount, totalCount)`.
    /// - Returns: Array of results for locations that were processed.
    func generateAll(
        owpURL: URL,
        geminiAPIKey: String,
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> [GenerationResult] {
        let catalog = try loadCatalog(owpURL: owpURL)
        let backgroundsDir = owpURL.appendingPathComponent("Animate/backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: backgroundsDir, withIntermediateDirectories: true)

        let total = catalog.locations.count
        var results: [GenerationResult] = []

        for (index, location) in catalog.locations.enumerated() {
            let outputURL = backgroundsDir.appendingPathComponent("\(location.slug).png")

            // Skip if already generated
            if FileManager.default.fileExists(atPath: outputURL.path) {
                onProgress(index + 1, total)
                results.append(GenerationResult(
                    locationSlug: location.slug,
                    outputURL: outputURL,
                    usedGemini: false
                ))
                continue
            }

            let usedGemini: Bool
            if !geminiAPIKey.isEmpty {
                usedGemini = await generateWithGemini(
                    location: location,
                    apiKey: geminiAPIKey,
                    outputURL: outputURL
                )
            } else {
                usedGemini = false
            }

            if !usedGemini {
                generateWithCoreGraphics(location: location, outputURL: outputURL)
            }

            onProgress(index + 1, total)
            results.append(GenerationResult(
                locationSlug: location.slug,
                outputURL: outputURL,
                usedGemini: usedGemini
            ))
        }

        return results
    }

    // MARK: - Catalog Loading

    private func loadCatalog(owpURL: URL) throws -> WorldCatalog {
        let catalogURL = owpURL
            .appendingPathComponent("Animate/3d/world-catalog/world-catalog.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw GenerationError.catalogNotFound
        }
        let data = try Data(contentsOf: catalogURL)
        return try JSONDecoder().decode(WorldCatalog.self, from: data)
    }

    // MARK: - Gemini Generation

    private func generateWithGemini(
        location: LocationEntry,
        apiKey: String,
        outputURL: URL
    ) async -> Bool {
        let timeOfDay = location.timeOfDay ?? "day"
        let lighting = location.lighting ?? "natural"
        let prompt = """
            Generate a cinematic wide-angle background scene for the location "\(location.name)".
            Time of day: \(timeOfDay). Lighting: \(lighting).
            \(location.description.map { "Description: \($0)." } ?? "")
            Style: rich, painterly, anime-inspired. No characters. 16:9 landscape orientation.
            1920x1080 resolution. Full-bleed, no borders.
            """
        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: prompt,
            model: .flash,
            aspectRatio: "16:9",
            imageSize: "2K"
        )
        do {
            print("[BackgroundGenerationService] Gemini API call — image-generation for location: \(location.slug)")
            let result = try await service.generate(request: request, apiKey: apiKey)
            try result.imageData.write(to: outputURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Core Graphics Fallback

    private func generateWithCoreGraphics(location: LocationEntry, outputURL: URL) {
        let size = NSSize(width: 1920, height: 1080)
        let (topColor, bottomColor) = gradientColors(for: location)
        let image = NSImage(size: size, flipped: false) { bounds in
            _ = topColor  // ensure capture
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw gradient background
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let cgColors = [topColor.cgColor, bottomColor.cgColor] as CFArray
            let locations: [CGFloat] = [0.0, 1.0]
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: cgColors,
                locations: locations
            ) else { return false }

            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: bounds.height),
                end: CGPoint(x: 0, y: 0),
                options: []
            )

            // Draw location name text
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 48, weight: .light),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                .paragraphStyle: paragraphStyle
            ]
            let str = location.name as NSString
            let textRect = CGRect(
                x: 80,
                y: bounds.midY - 36,
                width: bounds.width - 160,
                height: 72
            )
            str.draw(in: textRect, withAttributes: attrs)
            return true
        }

        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
            try? png.write(to: outputURL)
        }
    }

    private func gradientColors(for location: LocationEntry) -> (NSColor, NSColor) {
        let slug = location.slug.lowercased()
        let timeOfDay = location.timeOfDay?.lowercased() ?? "day"

        // Pick palette based on slug keywords and time of day
        if slug.contains("interior") || slug.contains("room") || slug.contains("hall") {
            return (NSColor(red: 0.25, green: 0.18, blue: 0.32, alpha: 1),
                    NSColor(red: 0.10, green: 0.08, blue: 0.14, alpha: 1))
        }
        if slug.contains("forest") || slug.contains("garden") || slug.contains("park") {
            return timeOfDay == "night"
                ? (NSColor(red: 0.05, green: 0.12, blue: 0.08, alpha: 1),
                   NSColor(red: 0.02, green: 0.05, blue: 0.04, alpha: 1))
                : (NSColor(red: 0.40, green: 0.62, blue: 0.34, alpha: 1),
                   NSColor(red: 0.22, green: 0.38, blue: 0.18, alpha: 1))
        }
        if slug.contains("ocean") || slug.contains("sea") || slug.contains("beach") {
            return (NSColor(red: 0.18, green: 0.52, blue: 0.72, alpha: 1),
                    NSColor(red: 0.25, green: 0.30, blue: 0.45, alpha: 1))
        }
        if slug.contains("desert") || slug.contains("sand") {
            return (NSColor(red: 0.85, green: 0.65, blue: 0.35, alpha: 1),
                    NSColor(red: 0.55, green: 0.35, blue: 0.18, alpha: 1))
        }
        if slug.contains("city") || slug.contains("street") || slug.contains("urban") {
            return timeOfDay == "night"
                ? (NSColor(red: 0.06, green: 0.06, blue: 0.14, alpha: 1),
                   NSColor(red: 0.02, green: 0.02, blue: 0.08, alpha: 1))
                : (NSColor(red: 0.55, green: 0.62, blue: 0.70, alpha: 1),
                   NSColor(red: 0.35, green: 0.40, blue: 0.48, alpha: 1))
        }

        // Default sky gradient
        return timeOfDay == "night"
            ? (NSColor(red: 0.05, green: 0.07, blue: 0.18, alpha: 1),
               NSColor(red: 0.01, green: 0.02, blue: 0.08, alpha: 1))
            : (NSColor(red: 0.42, green: 0.68, blue: 0.88, alpha: 1),
               NSColor(red: 0.72, green: 0.85, blue: 0.95, alpha: 1))
    }
}
