import Foundation
import ProjectKit

/// Project-local credential store. Keeps API keys inside the OWP project
/// folder (at `<project>/config/api-credentials.json`) so they automatically
/// sync between Gary's machines via the Syncthing replica of that folder.
///
/// File permissions are forced to owner-only (0600) on every write. The JSON
/// itself is plaintext — Gary's threat model treats his own machines as
/// trusted, and Keychain also yielded plaintext to any process running as him.
///
/// The Keychain path was removed because ad-hoc rebuilds generate a fresh
/// code signature on every build, and macOS re-prompts for access to the
/// Keychain ACL on each launch. The project-folder JSON is now the single
/// source of truth; Vertex project/region still migrate from UserDefaults.
@available(macOS 26.0, *)
final class ProjectCredentialStore: @unchecked Sendable {
    static let shared = ProjectCredentialStore()

    struct Payload: Codable, Equatable {
        var geminiAPIKey: String = ""
        var miniMaxAPIKey: String = ""
        var viduAPIKey: String = ""
        var runPodAPIKey: String = ""
        var vertexProjectID: String = ""
        var vertexRegion: String = ""
    }

    private let ioQueue = DispatchQueue(label: "com.amira.writer.ProjectCredentialStore")
    private var cachedPayload: Payload = Payload()
    private var cachedFileURL: URL?
    private var isPayloadLoaded = false

    private init() {}

    /// Call once the user opens an OWP project. Loads the credential file
    /// into memory, or creates an empty one if it doesn't yet exist.
    func setActiveProject(_ owpURL: URL?) {
        ioQueue.sync {
            guard let owpURL else {
                cachedFileURL = nil
                cachedPayload = Payload()
                isPayloadLoaded = false
                return
            }
            let file = ProjectPaths(root: owpURL).apiCredentialsJSON
            cachedFileURL = file

            if FileManager.default.fileExists(atPath: file.path) {
                if let data = try? Data(contentsOf: file),
                   let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
                    cachedPayload = decoded
                    isPayloadLoaded = true
                    return
                }
            }
            // File missing or corrupt — start fresh. Vertex settings
            // migrate from UserDefaults since they never lived in Keychain.
            var fresh = Payload()
            fresh.vertexProjectID = UserDefaults.standard.string(forKey: "animate.gemini.vertex.projectID") ?? ""
            fresh.vertexRegion = UserDefaults.standard.string(forKey: "animate.gemini.vertex.region") ?? ""

            cachedPayload = fresh
            isPayloadLoaded = true
            writeFileLocked(payload: fresh, to: file)
        }
    }

    // MARK: - Accessors

    func geminiAPIKey() -> String { ioQueue.sync { cachedPayload.geminiAPIKey } }
    func miniMaxAPIKey() -> String { ioQueue.sync { cachedPayload.miniMaxAPIKey } }
    func viduAPIKey() -> String { ioQueue.sync { cachedPayload.viduAPIKey } }
    func runPodAPIKey() -> String { ioQueue.sync { cachedPayload.runPodAPIKey } }
    func vertexProjectID() -> String { ioQueue.sync { cachedPayload.vertexProjectID } }
    func vertexRegion() -> String { ioQueue.sync { cachedPayload.vertexRegion } }

    func setGeminiAPIKey(_ value: String) { update { $0.geminiAPIKey = value } }
    func setMiniMaxAPIKey(_ value: String) { update { $0.miniMaxAPIKey = value } }
    func setViduAPIKey(_ value: String) { update { $0.viduAPIKey = value } }
    func setRunPodAPIKey(_ value: String) { update { $0.runPodAPIKey = value } }
    func setVertexProjectID(_ value: String) { update { $0.vertexProjectID = value } }
    func setVertexRegion(_ value: String) { update { $0.vertexRegion = value } }

    /// True when an OWP has been loaded and the JSON file is usable.
    func isActive() -> Bool { ioQueue.sync { cachedFileURL != nil } }

    // MARK: - Internals

    private func update(_ mutate: (inout Payload) -> Void) {
        ioQueue.sync {
            mutate(&cachedPayload)
            if let url = cachedFileURL {
                writeFileLocked(payload: cachedPayload, to: url)
            }
        }
    }

    /// Assumes ioQueue is held.
    private func writeFileLocked(payload: Payload, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
            // Force owner-read-write-only on the file.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[ProjectCredentialStore] write failed: \(error)")
        }
    }

}
