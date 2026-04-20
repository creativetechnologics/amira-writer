import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ImagineGallerySelectionState: Codable, Equatable {
    /// Images picked as Gemini generation references (top-left checkbox)
    var selectedPaths: Set<String> = []
    /// Images picked for LORA training dataset (top-right checkbox)
    var loraSelectedPaths: Set<String> = []
    /// Rejected / hidden images (greyed out)
    var hiddenPaths: Set<String> = []
    /// Batch job keys the user explicitly removed from the status list.
    var dismissedBatchJobKeys: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case selectedPaths
        case loraSelectedPaths
        case hiddenPaths
        case dismissedBatchJobKeys
    }

    init(
        selectedPaths: Set<String> = [],
        loraSelectedPaths: Set<String> = [],
        hiddenPaths: Set<String> = [],
        dismissedBatchJobKeys: Set<String> = []
    ) {
        self.selectedPaths = selectedPaths
        self.loraSelectedPaths = loraSelectedPaths
        self.hiddenPaths = hiddenPaths
        self.dismissedBatchJobKeys = dismissedBatchJobKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedPaths = try container.decodeIfPresent(Set<String>.self, forKey: .selectedPaths) ?? []
        loraSelectedPaths = try container.decodeIfPresent(Set<String>.self, forKey: .loraSelectedPaths) ?? []
        hiddenPaths = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenPaths) ?? []
        dismissedBatchJobKeys = try container.decodeIfPresent(Set<String>.self, forKey: .dismissedBatchJobKeys) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedPaths, forKey: .selectedPaths)
        try container.encode(loraSelectedPaths, forKey: .loraSelectedPaths)
        try container.encode(hiddenPaths, forKey: .hiddenPaths)
        try container.encode(dismissedBatchJobKeys, forKey: .dismissedBatchJobKeys)
    }

    static func load(animateURL: URL, characterSlug: String) -> ImagineGallerySelectionState {
        let url = ProjectPaths(root: animateURL.deletingLastPathComponent())
            .characterInspirationGalleryStateJSON(slug: characterSlug)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ImagineGallerySelectionState.self, from: data) else {
            return ImagineGallerySelectionState()
        }

        let normalized = state.normalized(animateURL: animateURL)
        if normalized != state {
            normalized.save(animateURL: animateURL, characterSlug: characterSlug)
        }
        return normalized
    }

    func save(animateURL: URL, characterSlug: String) {
        let charPaths = ProjectPaths(root: animateURL.deletingLastPathComponent())
        let dir = charPaths.characterFolder(slug: characterSlug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = charPaths.characterInspirationGalleryStateJSON(slug: characterSlug)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let normalizedState = normalized(animateURL: animateURL)
        if let data = try? encoder.encode(normalizedState) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func normalized(animateURL: URL) -> ImagineGallerySelectionState {
        ImagineGallerySelectionState(
            selectedPaths: Self.normalizedPaths(selectedPaths, animateURL: animateURL),
            loraSelectedPaths: Self.normalizedPaths(loraSelectedPaths, animateURL: animateURL),
            hiddenPaths: Self.normalizedPaths(hiddenPaths, animateURL: animateURL),
            dismissedBatchJobKeys: dismissedBatchJobKeys
        )
    }

    private static func normalizedPaths(_ paths: Set<String>, animateURL: URL) -> Set<String> {
        Set(paths.compactMap { normalizedPath($0, animateURL: animateURL) })
    }

    static func normalizedPath(_ path: String, animateURL: URL) -> String? {
        let trimmed = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !trimmed.isEmpty else { return nil }

        let sanitized = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
        let animateRoot = animateURL.standardizedFileURL
        let projectRoot = animateRoot.deletingLastPathComponent().standardizedFileURL

        if sanitized.hasPrefix("Animate/") {
            return sanitized
        }

        if sanitized.hasPrefix("characters/")
            || sanitized.hasPrefix("backgrounds/")
            || sanitized.hasPrefix("generated/")
            || sanitized.hasPrefix("imagine/")
            || sanitized.hasPrefix("objects/")
            || sanitized.hasPrefix("scene-generation/")
        {
            return "Animate/\(sanitized)"
        }

        guard sanitized.hasPrefix("/") else {
            return sanitized
        }

        let absoluteURL = URL(fileURLWithPath: sanitized).standardizedFileURL
        if let projectRelative = relativePath(from: absoluteURL, to: projectRoot) {
            return projectRelative
        }
        if let animateRelative = relativePath(from: absoluteURL, to: animateRoot) {
            return "Animate/\(animateRelative)"
        }
        return absoluteURL.path
    }

    private static func relativePath(from sourceURL: URL, to baseURL: URL) -> String? {
        let sourceComponents = sourceURL.pathComponents
        let baseComponents = baseURL.pathComponents
        guard sourceComponents.count >= baseComponents.count,
              Array(sourceComponents.prefix(baseComponents.count)) == baseComponents else {
            return nil
        }

        let relativeComponents = sourceComponents.dropFirst(baseComponents.count)
        guard !relativeComponents.isEmpty else { return nil }
        return relativeComponents.joined(separator: "/")
    }
}
