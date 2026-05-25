import Foundation

/// RunPod API key — stored in `<project>/Settings/api-credentials.json`
/// (via ProjectCredentialStore) and synced between machines by Syncthing.
///
/// Two read-only fallbacks remain for scripted / legacy setups:
///   1. `RUNPOD_API_KEY` environment variable — used by CI and one-off scripts.
///   2. `~/.lora-maker/runpod_api_key` — the legacy LORA Maker credential file.
@available(macOS 26.0, *)
struct RunPodCredentialStore: Sendable {
    func loadAPIKey() -> String {
        if let fromEnvironment = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }

        if ProjectCredentialStore.shared.isActive() {
            let fromProject = ProjectCredentialStore.shared.runPodAPIKey()
            if !fromProject.isEmpty { return fromProject }
        }

        let localFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lora-maker/runpod_api_key")
        if let data = try? Data(contentsOf: localFile),
           let fromFile = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromFile.isEmpty {
            return fromFile
        }

        return ""
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setRunPodAPIKey(trimmed)
    }

    func deleteAPIKey() {
        guard ProjectCredentialStore.shared.isActive() else { return }
        ProjectCredentialStore.shared.setRunPodAPIKey("")
    }
}
