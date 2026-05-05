import Foundation

/// Gemini API key — stored in `<project>/Settings/api-credentials.json`
/// (via ProjectCredentialStore) and synced between machines by Syncthing.
@available(macOS 26.0, *)
struct GeminiCredentialStore: Sendable {
    func loadAPIKey() -> String {
        let projectKey = ProjectCredentialStore.shared.isActive()
            ? ProjectCredentialStore.shared.geminiAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if !projectKey.isEmpty { return projectKey }

        let environmentKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environmentKey.isEmpty { return environmentKey }

        let legacyKeyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lora-maker/gemini_api_key")
        if let key = try? String(contentsOf: legacyKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        return ""
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setGeminiAPIKey(trimmed)
    }

    func clearAPIKey() {
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setGeminiAPIKey("")
    }
}
