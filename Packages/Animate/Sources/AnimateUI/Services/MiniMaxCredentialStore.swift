import Foundation

/// MiniMax API key — stored in `<project>/config/api-credentials.json`
/// (via ProjectCredentialStore) and synced between machines by Syncthing.
@available(macOS 26.0, *)
struct MiniMaxCredentialStore: Sendable {
    func loadAPIKey() -> String {
        guard ProjectCredentialStore.shared.isActive() else { return "" }
        return ProjectCredentialStore.shared.miniMaxAPIKey()
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setMiniMaxAPIKey(trimmed)
    }

    func deleteAPIKey() {
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setMiniMaxAPIKey("")
    }
}
