import Foundation

/// Meshy API key — stored in `<project>/Settings/api-credentials.json`
/// (via ProjectCredentialStore) and synced between machines by Syncthing.
@available(macOS 26.0, *)
struct MeshyCredentialStore: Sendable {
    func loadAPIKey() -> String {
        guard ProjectCredentialStore.shared.isActive() else { return "" }
        return ProjectCredentialStore.shared.meshyAPIKey()
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setMeshyAPIKey(trimmed)
    }

    func deleteAPIKey() {
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setMeshyAPIKey("")
    }
}
