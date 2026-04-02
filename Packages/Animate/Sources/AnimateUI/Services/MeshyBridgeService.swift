import Foundation

@available(macOS 26.0, *)
final class MeshyBridgeService: Sendable {

    /// Determines if a generation queue item kind needs Meshy 3D conversion
    static func needsMeshyConversion(_ kind: String) -> Bool {
        kind == "bodyModel"
    }

    /// Configuration for a Meshy bridge job
    struct BridgeJob: Sendable {
        let characterID: UUID
        let characterSlug: String
        let costumeName: String
        let sourceImagePaths: [String]  // Local file paths to generated reference images
        let meshyConfig: MeshyMultiImageRequest
    }

    /// Result of a completed bridge job
    struct BridgeResult: Sendable {
        let characterID: UUID
        let taskID: String
        let downloadedFormats: [String]  // e.g. ["glb", "usdz"]
        let assetDirectory: URL
        let models: [Character3DModel]
    }

    /// Execute a bridge job: encode images → submit to Meshy → poll → download → return result
    static func execute(
        job: BridgeJob,
        apiKey: String,
        animateURL: URL,
        onProgress: @Sendable @escaping (MeshyTaskStatus, Int) -> Void
    ) async throws -> BridgeResult {
        let service = MeshyService(apiKey: apiKey)

        // Encode source images as base64 data URIs
        let imageDataURLs = job.sourceImagePaths.compactMap { path -> String? in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            let mime = ext == "png" ? "image/png" : "image/jpeg"
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }

        guard !imageDataURLs.isEmpty else {
            throw MeshyService.ServiceError.invalidResponse
        }

        // Build request
        var request = job.meshyConfig
        request.imageURLs = imageDataURLs
        // Use the first image as texture reference
        if request.shouldTexture {
            request.textureImageURL = imageDataURLs.first
        }

        // Submit to Meshy
        let endpoint: String
        let taskID: String
        if imageDataURLs.count > 1 {
            taskID = try await service.createMultiImageTo3D(request)
            endpoint = "multi-image-to-3d"
        } else {
            let singleRequest = MeshyImageRequest(
                imageURL: imageDataURLs[0],
                aiModel: request.aiModel,
                topology: request.topology,
                targetPolycount: request.targetPolycount,
                shouldRemesh: request.shouldRemesh,
                shouldTexture: request.shouldTexture,
                enablePBR: request.enablePBR,
                removeLighting: request.removeLighting,
                textureImageURL: request.textureImageURL,
                targetFormats: request.targetFormats
            )
            taskID = try await service.createImageTo3D(singleRequest)
            endpoint = "image-to-3d"
        }

        // Poll until complete
        let result = try await service.pollUntilComplete(
            endpoint: endpoint,
            taskID: taskID
        ) { response in
            onProgress(response.status, response.progress)
        }

        guard let modelURLs = result.modelURLs else {
            throw MeshyService.ServiceError.invalidResponse
        }

        // Download assets
        let assetDir = animateURL
            .appendingPathComponent("Characters")
            .appendingPathComponent(job.characterSlug)
            .appendingPathComponent("3d-models")
            .appendingPathComponent(taskID)

        try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)

        var downloadedModels: [Character3DModel] = []

        for (format, urlString) in modelURLs {
            guard let remoteURL = URL(string: urlString) else { continue }
            if format.hasPrefix("pre_remeshed") || format == "mtl" { continue }

            let destination = assetDir.appendingPathComponent("model.\(format)")
            try await service.downloadAsset(from: remoteURL, to: destination)

            let model = Character3DModel(
                costumeName: job.costumeName,
                modelFileName: "model.\(format)",
                modelFormat: format,
                notes: "Auto-generated via Meshy.ai bridge (\(taskID))"
            )
            downloadedModels.append(model)
        }

        // Download thumbnail
        if let thumbStr = result.thumbnailURL, let thumbURL = URL(string: thumbStr) {
            let thumbDest = assetDir.appendingPathComponent("thumbnail.png")
            try? await service.downloadAsset(from: thumbURL, to: thumbDest)
        }

        // Save metadata
        let metadataURL = assetDir.appendingPathComponent("metadata.json")
        let metadata: [String: Any] = [
            "taskID": taskID,
            "characterSlug": job.characterSlug,
            "costumeName": job.costumeName,
            "modelURLs": modelURLs,
            "sourceImageCount": job.sourceImagePaths.count,
            "config": [
                "polycount": request.targetPolycount,
                "topology": request.topology,
                "texture": request.shouldTexture,
                "removeLighting": request.removeLighting,
                "pbr": request.enablePBR,
                "formats": request.targetFormats
            ] as [String: Any],
            "downloadedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? data.write(to: metadataURL)
        }

        return BridgeResult(
            characterID: job.characterID,
            taskID: taskID,
            downloadedFormats: downloadedModels.map(\.modelFormat),
            assetDirectory: assetDir,
            models: downloadedModels
        )
    }
}
