import Foundation
import Security

/// Project-local credential store. Keeps API keys inside the OWP project
/// folder (at `<project>/config/api-credentials.json`) so they automatically
/// sync between Gary's machines via the Syncthing replica of that folder.
///
/// File permissions are forced to owner-only (0600) on every write. The JSON
/// itself is plaintext — Gary's threat model treats his own machines as
/// trusted, and Keychain also yields plaintext to any process running as him.
///
/// **Migration strategy**: the existing macOS Keychain stores are still
/// consulted as a fallback. The first time an OWP is opened on a machine
/// whose JSON is empty, we read each key from Keychain and WRITE it to JSON,
/// then continue to use JSON as the source of truth. Keychain writes are
/// kept synchronised on every save for belt-and-braces redundancy.
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
    /// into memory (or migrates from Keychain if the file doesn't yet exist).
    func setActiveProject(_ owpURL: URL?) {
        ioQueue.sync {
            guard let owpURL else {
                cachedFileURL = nil
                cachedPayload = Payload()
                isPayloadLoaded = false
                return
            }
            let dir = owpURL.appendingPathComponent("config", isDirectory: true)
            let file = dir.appendingPathComponent("api-credentials.json")
            cachedFileURL = file

            if FileManager.default.fileExists(atPath: file.path) {
                if let data = try? Data(contentsOf: file),
                   let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
                    cachedPayload = decoded
                    isPayloadLoaded = true
                    return
                }
            }
            // File missing or corrupt — migrate from Keychain.
            var migrated = Payload()
            migrated.geminiAPIKey = Self.readKeychain(service: "com.amira.writer.animate", account: "gemini-api-key") ?? ""
            migrated.miniMaxAPIKey = Self.readKeychain(service: "com.amira.writer.animate", account: "minimax-api-key") ?? ""
            migrated.viduAPIKey = Self.readKeychain(service: "com.amira.writer.animate", account: "vidu-api-key") ?? ""
            migrated.runPodAPIKey = Self.readKeychain(service: "com.amira.writer.animate", account: "runpod-api-key") ?? ""
            // Vertex settings live in UserDefaults, not Keychain.
            migrated.vertexProjectID = UserDefaults.standard.string(forKey: "animate.gemini.vertex.projectID") ?? ""
            migrated.vertexRegion = UserDefaults.standard.string(forKey: "animate.gemini.vertex.region") ?? ""

            cachedPayload = migrated
            isPayloadLoaded = true
            writeFileLocked(payload: migrated, to: file)
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

    private static func readKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
