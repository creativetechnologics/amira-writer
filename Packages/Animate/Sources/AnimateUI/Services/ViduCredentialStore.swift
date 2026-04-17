import Foundation

/// Vidu API key — stored in `<project>/config/api-credentials.json`
/// (via ProjectCredentialStore) and synced between machines by Syncthing.
@available(macOS 26.0, *)
struct ViduCredentialStore: Sendable {
    func loadAPIKey() -> String {
        guard ProjectCredentialStore.shared.isActive() else { return "" }
        return ProjectCredentialStore.shared.viduAPIKey()
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setViduAPIKey(trimmed)
    }

    func deleteAPIKey() {
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setViduAPIKey("")
    }
}
