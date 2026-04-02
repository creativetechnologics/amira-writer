import Foundation

// MARK: - Request Types

@available(macOS 26.0, *)
struct MeshyMultiImageRequest: Encodable, Sendable {
    var imageURLs: [String]
    var aiModel: String = "latest"
    var topology: String = "triangle"
    var targetPolycount: Int = 100_000
    var shouldRemesh: Bool = true
    var shouldTexture: Bool = true
    var enablePBR: Bool = false
    var removeLighting: Bool = true
    var textureImageURL: String?
    var targetFormats: [String] = ["glb", "usdz"]
    var symmetryMode: String = "auto"
}

@available(macOS 26.0, *)
struct MeshyImageRequest: Encodable, Sendable {
    var imageURL: String
    var aiModel: String = "latest"
    var topology: String = "triangle"
    var targetPolycount: Int = 100_000
    var shouldRemesh: Bool = true
    var shouldTexture: Bool = true
    var enablePBR: Bool = false
    var removeLighting: Bool = true
    var textureImageURL: String?
    var targetFormats: [String] = ["glb", "usdz"]
    var symmetryMode: String = "auto"
}

// MARK: - Response Types

@available(macOS 26.0, *)
struct MeshyCreateTaskResponse: Decodable, Sendable {
    let result: String  // task ID
}

@available(macOS 26.0, *)
struct MeshyTaskResponse: Decodable, Sendable {
    let id: String
    let status: MeshyTaskStatus
    let progress: Int
    let modelURLs: [String: String]?
    let thumbnailURL: String?
    let textureURLs: [MeshyTextureSet]?
    let taskError: MeshyTaskError?
    let createdAt: Int64
    let finishedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, status, progress
        case modelURLs = "model_urls"
        case thumbnailURL = "thumbnail_url"
        case textureURLs = "texture_urls"
        case taskError = "task_error"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
    }
}

enum MeshyTaskStatus: String, Decodable, Sendable {
    case pending = "PENDING"
    case inProgress = "IN_PROGRESS"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case canceled = "CANCELED"
}

@available(macOS 26.0, *)
struct MeshyTextureSet: Decodable, Sendable {
    let baseColor: String?
    let metallic: String?
    let normal: String?
    let roughness: String?

    enum CodingKeys: String, CodingKey {
        case baseColor = "base_color"
        case metallic, normal, roughness
    }
}

@available(macOS 26.0, *)
struct MeshyTaskError: Decodable, Sendable {
    let message: String
}

@available(macOS 26.0, *)
struct MeshyBalanceResponse: Decodable, Sendable {
    let balance: Int
}

// MARK: - Estimated credit cost

@available(macOS 26.0, *)
extension MeshyMultiImageRequest {
    var estimatedCredits: Int {
        let isMeshy6 = aiModel == "meshy-6" || aiModel == "latest"
        if isMeshy6 {
            return shouldTexture ? 30 : 20
        } else {
            return shouldTexture ? 15 : 5
        }
    }
}

@available(macOS 26.0, *)
extension MeshyImageRequest {
    var estimatedCredits: Int {
        let isMeshy6 = aiModel == "meshy-6" || aiModel == "latest"
        if isMeshy6 {
            return shouldTexture ? 30 : 20
        } else {
            return shouldTexture ? 15 : 5
        }
    }
}
