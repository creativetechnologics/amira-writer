import Foundation

/// Gemini API key — stored in `<project>/config/api-credentials.json`
/// (via ProjectCredentialStore) and synced between machines by Syncthing.
@available(macOS 26.0, *)
struct GeminiCredentialStore: Sendable {
    func loadAPIKey() -> String {
        guard ProjectCredentialStore.shared.isActive() else { return "" }
        return ProjectCredentialStore.shared.geminiAPIKey()
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
