import Foundation
import ProjectKit

/// Project-local credential store. Keeps API keys inside the OWP project
/// folder (at `<project>/Settings/api-credentials.json`, post-Wave-D) so they
/// automatically sync between Gary's machines via the Syncthing replica.
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
        var openAIAPIKey: String = ""
        var imageAnalysisGeminiAPIKey: String = ""
        var miniMaxAPIKey: String = ""
        var deepSeekAPIKey: String = ""
        var supplementalLLMProvider: String = SupplementalLLMProvider.deepSeek.rawValue
        var supplementalLLMModel: String = SupplementalLLMProvider.deepSeek.defaultModel
        var viduAPIKey: String = ""
        var runPodAPIKey: String = ""
        var meshyAPIKey: String = ""
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
                   let decoded = try? JSONCoders.makeDecoder().decode(Payload.self, from: data) {
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
            Self.writeFileLocked(payload: fresh, to: file)
        }
    }

    // MARK: - Accessors

    func geminiAPIKey() -> String { ioQueue.sync { cachedPayload.geminiAPIKey } }
    func openAIAPIKey() -> String { ioQueue.sync { cachedPayload.openAIAPIKey } }
    func imageAnalysisGeminiAPIKey() -> String { ioQueue.sync { cachedPayload.imageAnalysisGeminiAPIKey } }
    func miniMaxAPIKey() -> String { ioQueue.sync { cachedPayload.miniMaxAPIKey } }
    func deepSeekAPIKey() -> String { ioQueue.sync { cachedPayload.deepSeekAPIKey } }
    func supplementalLLMProvider() -> SupplementalLLMProvider {
        ioQueue.sync {
            SupplementalLLMProvider(rawValue: cachedPayload.supplementalLLMProvider) ?? .deepSeek
        }
    }
    func supplementalLLMModel() -> String {
        ioQueue.sync {
            let provider = SupplementalLLMProvider(rawValue: cachedPayload.supplementalLLMProvider) ?? .deepSeek
            let stored = cachedPayload.supplementalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? provider.defaultModel : stored
        }
    }
    func viduAPIKey() -> String { ioQueue.sync { cachedPayload.viduAPIKey } }
    func runPodAPIKey() -> String { ioQueue.sync { cachedPayload.runPodAPIKey } }
    func meshyAPIKey() -> String { ioQueue.sync { cachedPayload.meshyAPIKey } }
    func vertexProjectID() -> String { ioQueue.sync { cachedPayload.vertexProjectID } }
    func vertexRegion() -> String { ioQueue.sync { cachedPayload.vertexRegion } }

    func setGeminiAPIKey(_ value: String) { update { $0.geminiAPIKey = value } }
    func setOpenAIAPIKey(_ value: String) { update { $0.openAIAPIKey = value } }
    func setImageAnalysisGeminiAPIKey(_ value: String) { update { $0.imageAnalysisGeminiAPIKey = value } }
    func setMiniMaxAPIKey(_ value: String) { update { $0.miniMaxAPIKey = value } }
    func setDeepSeekAPIKey(_ value: String) { update { $0.deepSeekAPIKey = value } }
    func setSupplementalLLMProvider(_ value: SupplementalLLMProvider) {
        update {
            $0.supplementalLLMProvider = value.rawValue
            if $0.supplementalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !value.knownModels.contains($0.supplementalLLMModel) {
                $0.supplementalLLMModel = value.defaultModel
            }
        }
    }
    func setSupplementalLLMModel(_ value: String) { update { $0.supplementalLLMModel = value } }
    func setViduAPIKey(_ value: String) { update { $0.viduAPIKey = value } }
    func setRunPodAPIKey(_ value: String) { update { $0.runPodAPIKey = value } }
    func setMeshyAPIKey(_ value: String) { update { $0.meshyAPIKey = value } }
    func setVertexProjectID(_ value: String) { update { $0.vertexProjectID = value } }
    func setVertexRegion(_ value: String) { update { $0.vertexRegion = value } }

    /// True when an OWP has been loaded and the JSON file is usable.
    func isActive() -> Bool { ioQueue.sync { cachedFileURL != nil } }

    // MARK: - Internals

    private func update(_ mutate: (inout Payload) -> Void) {
        // Apply the mutation synchronously so subsequent reads see it, but
        // fan the disk write to the ioQueue so callers aren't blocked on I/O.
        ioQueue.sync { mutate(&cachedPayload) }
        let snapshot = ioQueue.sync { (cachedPayload, cachedFileURL) }
        if let url = snapshot.1 {
            ioQueue.async { [payload = snapshot.0] in
                Self.writeFileLocked(payload: payload, to: url)
            }
        }
    }

    nonisolated(unsafe) private static let sharedEncoder: JSONEncoder = {
        let encoder = JSONCoders.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Safe from any thread (JSONEncoder is Sendable, FileManager is thread-safe).
    private static func writeFileLocked(payload: Payload, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try sharedEncoder.encode(payload)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[ProjectCredentialStore] write failed: \(error)")
        }
    }

}
