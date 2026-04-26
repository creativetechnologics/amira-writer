import AppKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ImagineProjectStorage {

    // MARK: - Directory Paths

    static func imagineRoot(owpURL: URL) -> URL {
        ProjectPaths(root: owpURL).animateImagine
    }

    static func scenesRoot(owpURL: URL) -> URL {
        imagineRoot(owpURL: owpURL).appendingPathComponent("scenes", isDirectory: true)
    }

    static func sceneDirectory(owpURL: URL, sceneSlug: String) -> URL {
        scenesRoot(owpURL: owpURL).appendingPathComponent(sceneSlug, isDirectory: true)
    }

    static func shotDirectory(owpURL: URL, sceneSlug: String, shotIndex: Int) -> URL {
        sceneDirectory(owpURL: owpURL, sceneSlug: sceneSlug)
            .appendingPathComponent("shot-\(String(format: "%03d", shotIndex + 1))", isDirectory: true)
    }

    static func momentDirectory(owpURL: URL, sceneSlug: String, shotIndex: Int, moment: ImagineShotMoment) -> URL {
        shotDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex)
            .appendingPathComponent(moment.directoryName, isDirectory: true)
    }

    // MARK: - Directory Creation

    static func ensureDirectories(owpURL: URL, sceneSlug: String, shotCount: Int) throws {
        let fm = FileManager.default
        for shotIndex in 0..<shotCount {
            for moment in ImagineShotMoment.allCases {
                let dir = momentDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment)
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
        }
    }

    // MARK: - Image Scanning

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "tiff"]

    static func scanImages(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { (a, b) in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
            .map(\.path)
    }

    static func scanShotGallery(owpURL: URL, sceneSlug: String, shotIndex: Int, shotID: UUID, sceneID: UUID) -> ImagineSceneShotGallery {
        var gallery = ImagineSceneShotGallery(shotID: shotID, sceneID: sceneID)
        for moment in ImagineShotMoment.allCases {
            let dir = momentDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment)
            let paths = scanImages(in: dir)
            switch moment {
            case .beginning: gallery.beginningImagePaths = paths
            case .middle: gallery.middleImagePaths = paths
            case .end: gallery.endImagePaths = paths
            }
        }
        return gallery
    }

    // MARK: - Gallery JSON Persistence

    private static func galleriesJSONURL(owpURL: URL) -> URL {
        imagineRoot(owpURL: owpURL).appendingPathComponent("galleries.json")
    }

    static func loadGalleries(owpURL: URL) -> [ImagineSceneShotGallery] {
        let url = galleriesJSONURL(owpURL: owpURL)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ImagineSceneShotGallery].self, from: data)) ?? []
    }

    static func saveGalleries(_ galleries: [ImagineSceneShotGallery], owpURL: URL) throws {
        let url = galleriesJSONURL(owpURL: owpURL)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(galleries)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Image Save

    static func saveGeneratedImage(
        _ imageData: Data,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment,
        filePrefix: String = "gen"
    ) throws -> URL {
        let dir = momentDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "\(filePrefix)_\(timestamp).png"
        let outputURL = dir.appendingPathComponent(filename)
        try imageData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    static func saveGeneratedImageAsync(
        _ imageData: Data,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment,
        filePrefix: String = "gen"
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try saveGeneratedImage(
                imageData,
                owpURL: owpURL,
                sceneSlug: sceneSlug,
                shotIndex: shotIndex,
                moment: moment,
                filePrefix: filePrefix
            )
        }.value
    }

    // MARK: - Finder Integration

    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func revealDirectoryInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // MARK: - Import

    static func importImage(from sourceURL: URL, to destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDir.path) {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }
        let destURL = destinationDir.appendingPathComponent(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: destURL.path) {
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let newName = "\(stem)_\(timestamp).\(ext)"
            let uniqueURL = destinationDir.appendingPathComponent(newName)
            try fm.copyItem(at: sourceURL, to: uniqueURL)
            return uniqueURL
        }
        try fm.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    // MARK: - Universal Image Picker: Scan All Project Images

    static func scanAllProjectImages(owpURL: URL, characters: [AnimationCharacter], scenes: [AnimationScene]) -> [ImagineImageCategory: [ImagineImagePickerEntry]] {
        var result: [ImagineImageCategory: [ImagineImagePickerEntry]] = [:]
        let owpPaths = ProjectPaths(root: owpURL)
        let animateURL = owpPaths.animate

        // Imagine > Scenes
        let scenesDir = scenesRoot(owpURL: owpURL)
        var imagineEntries: [ImagineImagePickerEntry] = []
        if FileManager.default.fileExists(atPath: scenesDir.path) {
            if let sceneDirs = try? FileManager.default.contentsOfDirectory(at: scenesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for sceneDir in sceneDirs where sceneDir.hasDirectoryPath {
                    let sceneSlug = sceneDir.lastPathComponent
                    if let shotDirs = try? FileManager.default.contentsOfDirectory(at: sceneDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for shotDir in shotDirs where shotDir.hasDirectoryPath {
                            for moment in ImagineShotMoment.allCases {
                                let momentDir = shotDir.appendingPathComponent(moment.directoryName)
                                for path in scanImages(in: momentDir) {
                                    imagineEntries.append(ImagineImagePickerEntry(
                                        path: path,
                                        categoryLabel: "Scenes",
                                        subcategoryLabel: "\(sceneSlug) / \(shotDir.lastPathComponent) / \(moment.rawValue)"
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }
        result[.imagine] = imagineEntries

        // Characters
        var charEntries: [ImagineImagePickerEntry] = []
        for character in characters {
            let slug = character.assetFolderSlug
            let inspirationDir = owpPaths.characterInspiration(slug: slug)
            for path in scanImages(in: inspirationDir) {
                charEntries.append(ImagineImagePickerEntry(
                    path: path,
                    categoryLabel: character.name,
                    subcategoryLabel: "Inspiration"
                ))
            }
            let animatedDir = owpPaths.characterAnimated(slug: slug)
            for path in scanImages(in: animatedDir) {
                charEntries.append(ImagineImagePickerEntry(
                    path: path,
                    categoryLabel: character.name,
                    subcategoryLabel: "Animated"
                ))
            }
        }
        result[.characters] = charEntries

        // Places
        let backgroundsDir = owpPaths.animateBackgrounds
        var placeEntries: [ImagineImagePickerEntry] = []
        for path in scanImages(in: backgroundsDir) {
            placeEntries.append(ImagineImagePickerEntry(
                path: path,
                categoryLabel: "Backgrounds",
                subcategoryLabel: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            ))
        }
        result[.places] = placeEntries

        // Props
        let propsDir = ProjectPaths(root: animateURL.deletingLastPathComponent()).animateProps
        var propEntries: [ImagineImagePickerEntry] = []
        for path in scanImages(in: propsDir) {
            propEntries.append(ImagineImagePickerEntry(
                path: path,
                categoryLabel: "Props",
                subcategoryLabel: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            ))
        }
        result[.props] = propEntries

        return result
    }
}
