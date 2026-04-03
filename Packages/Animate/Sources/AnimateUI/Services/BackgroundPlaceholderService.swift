import AppKit
import Foundation

/// Creates placeholder background images for scenes that don't yet have backgrounds.
@available(macOS 26.0, *)
struct BackgroundPlaceholderService {

    /// Generate placeholder background PNGs for a list of location names.
    /// Skips any file that already exists on disk.
    /// Callers must pass the `locations` array explicitly — passing an empty
    /// array is a no-op. Do not rely on `amiraLocations` as a default; the
    /// list of locations is project-specific and should come from the caller.
    static func generatePlaceholders(
        locations: [(name: String, fileName: String, tintColor: NSColor)],
        outputDirectory: URL
    ) {
        guard !locations.isEmpty else { return }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for location in locations {
            let url = outputDirectory.appendingPathComponent(location.fileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            let image = makePlaceholder(size: NSSize(width: 1920, height: 1080),
                                        label: location.name,
                                        tintColor: location.tintColor)
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
    }

    private static func makePlaceholder(size: NSSize, label: String, tintColor: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        // Gradient background
        let gradient = NSGradient(colors: [
            tintColor.withAlphaComponent(0.6),
            NSColor.black.withAlphaComponent(0.9)
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -45)
        // Label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 72, weight: .thin),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5)
        ]
        let str = label as NSString
        let strSize = str.size(withAttributes: attrs)
        let strRect = NSRect(
            x: (size.width - strSize.width) / 2,
            y: (size.height - strSize.height) / 2,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: strRect, withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    /// Amira-specific locations used during initial project scaffolding.
    /// NOTE: This array is Amira-specific and should be passed by callers that
    /// need it — do not reference it from generic code or use it as a default
    /// parameter in `generatePlaceholders`. Callers should pass location names
    /// explicitly so this service remains project-agnostic.
    static let amiraLocations: [(name: String, fileName: String, tintColor: NSColor)] = [
        ("Palace Courtyard", "palace-courtyard.png", .systemBlue),
        ("Grand Hall", "grand-hall.png", .systemPurple),
        ("The Garden", "garden.png", .systemGreen),
        ("Forest Path", "forest-path.png", .systemGreen),
        ("Village Square", "village-square.png", .systemOrange),
        ("Throne Room", "throne-room.png", .systemRed),
        ("The Dungeon", "dungeon.png", .systemGray),
        ("The Rooftop", "rooftop.png", .systemCyan),
        ("The Market", "market.png", .systemYellow),
        ("River Bank", "river-bank.png", .systemTeal),
    ]
}
