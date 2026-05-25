import Foundation

/// Minimal Vertex AI client for Gemini image-generation endpoints.
///
/// Auth strategy: delegate to the locally-installed `gcloud` CLI for OAuth
/// token refresh. The user runs `gcloud auth application-default login` once
/// on the machine that runs Amira Writer; we shell out to
/// `gcloud auth application-default print-access-token` whenever we need a
/// fresh token. Tokens are cached in memory for ~55 minutes.
///
/// This keeps the integration simple: no JWT signing, no service-account JSON
/// file parsing in Swift, no vendored Google Auth library.
@available(macOS 26.0, *)
actor VertexAIClient {
    enum VertexError: LocalizedError {
        case gcloudNotFound
        case gcloudFailed(String)
        case missingConfig

        var errorDescription: String? {
            switch self {
            case .gcloudNotFound:
                return "gcloud CLI not found. Install it: brew install --cask google-cloud-sdk"
            case .gcloudFailed(let msg):
                return "gcloud token fetch failed: \(msg)"
            case .missingConfig:
                return "Vertex project ID is not configured. Open Gemini Settings → Vertex."
            }
        }
    }

    let projectID: String
    let region: String

    private var cachedToken: String?
    private var tokenAcquiredAt: Date?
    private static let tokenValidSeconds: TimeInterval = 55 * 60  // refresh before 1h hard expiry

    init(projectID: String, region: String = "us-central1") {
        self.projectID = projectID
        self.region = region
    }

    // MARK: - Endpoint construction

    /// URL for a Gemini-family model on Vertex AI's `generateContent` endpoint.
    ///
    /// Preview Gemini models (3.x-*-preview, including the image variants) are
    /// only exposed via the **global** endpoint, which uses a different hostname
    /// pattern than regional endpoints. See:
    /// https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations
    nonisolated func generateContentURL(modelID: String) -> URL? {
        let host: String
        if region == "global" {
            host = "aiplatform.googleapis.com"
        } else {
            host = "\(region)-aiplatform.googleapis.com"
        }
        let path = "https://\(host)/v1/projects/\(projectID)/locations/\(region)/publishers/google/models/\(modelID):generateContent"
        return URL(string: path)
    }

    // MARK: - Token acquisition

    /// Returns a valid access token, shelling out to gcloud if necessary.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let token = cachedToken,
           let acquired = tokenAcquiredAt,
           Date().timeIntervalSince(acquired) < Self.tokenValidSeconds {
            return token
        }
        let fresh = try await Self.fetchTokenViaGcloud()
        cachedToken = fresh
        tokenAcquiredAt = Date()
        return fresh
    }

    /// Call this on 401 to invalidate and refetch.
    func invalidateToken() {
        cachedToken = nil
        tokenAcquiredAt = nil
    }

    /// Shells out to `gcloud auth application-default print-access-token`.
    /// We probe a few common install paths because apps launched from /Applications
    /// don't always inherit the user's interactive $PATH.
    static func fetchTokenViaGcloud() async throws -> String {
        let candidates = [
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "/usr/bin/gcloud",
            "\(NSHomeDirectory())/google-cloud-sdk/bin/gcloud",
        ]
        let gcloudPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary = gcloudPath else { throw VertexError.gcloudNotFound }

        return try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["auth", "application-default", "print-access-token"]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                let outStr = String(decoding: outData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let errStr = String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0, !outStr.isEmpty {
                    cont.resume(returning: outStr)
                } else {
                    cont.resume(throwing: VertexError.gcloudFailed(
                        errStr.isEmpty ? "exit \(proc.terminationStatus)" : errStr))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: VertexError.gcloudFailed(error.localizedDescription))
            }
        }
    }
}

@available(macOS 26.0, *)
actor VertexAIClientCache {
    static let shared = VertexAIClientCache()

    private var clientsByConfig: [String: VertexAIClient] = [:]

    func client(projectID: String, region: String) -> VertexAIClient {
        let key = "\(projectID)|\(region)"
        if let existing = clientsByConfig[key] {
            return existing
        }
        let created = VertexAIClient(projectID: projectID, region: region)
        clientsByConfig[key] = created
        return created
    }
}

// MARK: - User-facing configuration

/// Where the Gemini image-gen request goes. Value persists via UserDefaults.
@available(macOS 26.0, *)
enum ImageGenBackend: String, CaseIterable, Sendable {
    case aiStudio = "aistudio"
    case vertex = "vertex"

    var displayName: String {
        switch self {
        case .aiStudio: return "Google AI Studio"
        case .vertex: return "Vertex AI"
        }
    }
}

/// Lives in UserDefaults (project/region aren't secrets).
@available(macOS 26.0, *)
struct VertexSettings: Sendable, Equatable {
    var projectID: String
    var region: String

    // "global" is the correct default for Gemini preview image models — they
    // aren't served from regional endpoints like us-central1.
    static let `default` = VertexSettings(projectID: "", region: "global")
}

@available(macOS 26.0, *)
enum ImageGenBackendStore {
    private static let backendKey = "animate.gemini.backend.v1"
    private static let vertexProjectKey = "animate.gemini.vertex.projectID"
    private static let vertexRegionKey = "animate.gemini.vertex.region"

    static func currentBackend() -> ImageGenBackend {
        let raw = UserDefaults.standard.string(forKey: backendKey) ?? ImageGenBackend.aiStudio.rawValue
        return ImageGenBackend(rawValue: raw) ?? .aiStudio
    }

    static func setBackend(_ backend: ImageGenBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: backendKey)
    }

    static func currentVertexSettings() -> VertexSettings {
        let project = UserDefaults.standard.string(forKey: vertexProjectKey) ?? ""
        let region = UserDefaults.standard.string(forKey: vertexRegionKey) ?? "global"
        return VertexSettings(projectID: project, region: region)
    }

    static func setVertexSettings(_ settings: VertexSettings) {
        UserDefaults.standard.set(settings.projectID, forKey: vertexProjectKey)
        UserDefaults.standard.set(settings.region, forKey: vertexRegionKey)
    }
}
