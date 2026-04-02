import Foundation

@available(macOS 26.0, *)
struct Animate3DGenerationOverridePersistence: Sendable {

    struct PersistedOverrideState: Codable, Sendable {
        var pinnedKeys: Set<String>
        var skippedKeys: Set<String>
        var draftOverrides: [String: PersistedDraftOverride]

        static let empty = PersistedOverrideState(
            pinnedKeys: [],
            skippedKeys: [],
            draftOverrides: [:]
        )
    }

    struct PersistedDraftOverride: Codable, Sendable {
        var providerHintOverride: String
        var promptAppendix: String
        var isLocked: Bool
    }

    private static func overrideFileURL(animateURL: URL) -> URL {
        animateURL
            .appendingPathComponent("3d")
            .appendingPathComponent("generation-overrides.json")
    }

    static func save(_ state: PersistedOverrideState, animateURL: URL) {
        let url = overrideFileURL(animateURL: animateURL)
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Animate3DOverridePersistence] Save failed: %@", error.localizedDescription)
        }
    }

    static func load(animateURL: URL) -> PersistedOverrideState {
        let url = overrideFileURL(animateURL: animateURL)

        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedOverrideState.self, from: data)
        else {
            return .empty
        }

        return state
    }

    static func clear(animateURL: URL) {
        let url = overrideFileURL(animateURL: animateURL)
        try? FileManager.default.removeItem(at: url)
    }
}
