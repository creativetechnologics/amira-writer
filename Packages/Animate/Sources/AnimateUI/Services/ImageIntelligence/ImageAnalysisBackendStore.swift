import Foundation

public enum ImageAnalysisBackend: String, CaseIterable, Codable, Sendable {
    case aiStudio = "aiStudio"
    case vertex = "vertex"

    public var displayName: String {
        switch self {
        case .aiStudio: return "AI Studio"
        case .vertex: return "Vertex AI"
        }
    }

    public var description: String {
        switch self {
        case .aiStudio:
            return "Routes requests to generativelanguage.googleapis.com with your API key."
        case .vertex:
            return "Routes requests to Vertex AI using gcloud OAuth. Useful for GCP credits or org billing."
        }
    }
}

public enum ImageAnalysisBackendStore {
    private static let backendKey = "ImageAnalysisBackend"
    private static let projectIDKey = "ImageAnalysisVertexProjectID"
    private static let regionKey = "ImageAnalysisVertexRegion"

    public static func currentBackend() -> ImageAnalysisBackend {
        if let raw = UserDefaults.standard.string(forKey: backendKey),
           let backend = ImageAnalysisBackend(rawValue: raw) {
            return backend
        }
        return .aiStudio
    }

    public static func setBackend(_ backend: ImageAnalysisBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: backendKey)
    }

    public static func currentVertexProjectID() -> String {
        if let stored = UserDefaults.standard.string(forKey: projectIDKey),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return ProjectCredentialStore.shared.vertexProjectID()
    }

    public static func currentVertexRegion() -> String {
        if let stored = UserDefaults.standard.string(forKey: regionKey),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        let projectRegion = ProjectCredentialStore.shared.vertexRegion()
        return projectRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "global"
            : projectRegion
    }

    public static func setVertexSettings(projectID: String, region: String) {
        UserDefaults.standard.set(projectID, forKey: projectIDKey)
        UserDefaults.standard.set(region, forKey: regionKey)
    }

    static func vertexConfig() -> VertexImageAnalysisClient.AnalysisConfig? {
        let pid = currentVertexProjectID()
        guard !pid.isEmpty else { return nil }
        return VertexImageAnalysisClient.AnalysisConfig(
            projectID: pid,
            region: currentVertexRegion()
        )
    }
}
