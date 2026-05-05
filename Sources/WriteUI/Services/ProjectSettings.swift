import Foundation

/// Project-level settings stored inside the OWP bundle as JSON.
/// Syncs between machines via SyncThing alongside the project data.
struct ProjectSettingsData: Codable {
    // MARK: - Direction / Action / Camera Visibility
    var showDirections: Bool?
    var showStoryboarding: Bool?
    var showAnimateDirections: Bool?

    // MARK: - Direction / Action / Camera Colors
    var directionMarkupColorHex: String?
    var storyboardingMarkupColorHex: String?
    var animateMarkupColorHex: String?
    var scriptBackgroundColorHex: String?

    // MARK: - LLM Provider
    var llmProvider: String?
    var llmMiniMaxKey: String?
    var llmDeepSeekKey: String?
    var llmOpenCodeKey: String?
    var llmMiniMaxModel: String?
    var llmDeepSeekModel: String?
    var llmOpenCodeModel: String?
    var llmClaudeModel: String?
}

@available(macOS 26.0, *)
enum ProjectSettingsPersistence {
    private static let filename = "Settings/project-settings.json"

    static func settingsURL(for projectURL: URL) -> URL {
        projectURL.appendingPathComponent(filename)
    }

    static func load(from projectURL: URL) -> ProjectSettingsData {
        let url = settingsURL(for: projectURL)
        guard let data = try? Data(contentsOf: url) else { return ProjectSettingsData() }
        return (try? JSONDecoder().decode(ProjectSettingsData.self, from: data)) ?? ProjectSettingsData()
    }

    static func save(_ settings: ProjectSettingsData, to projectURL: URL) {
        let url = settingsURL(for: projectURL)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
