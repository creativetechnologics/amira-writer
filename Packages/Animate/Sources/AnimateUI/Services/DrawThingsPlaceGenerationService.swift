import Foundation

struct DrawThingsPlaceGenerationService {
    enum ServiceError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case noImageData
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Draw Things host/port is invalid."
            case .invalidResponse:
                return "Draw Things returned an invalid response."
            case .noImageData:
                return "Draw Things did not return an image."
            case .httpError(let status, let body):
                return body.isEmpty ? "Draw Things error \(status)." : "Draw Things error \(status): \(body)"
            }
        }
    }

    private struct GenerationRequest: Encodable {
        var prompt: String
        var negative_prompt: String
        var width: Int
        var height: Int
        var steps: Int
        var cfg_scale: Double
        var seed: Int?
        var batch_size: Int = 1
        var n_iter: Int = 1
    }

    private struct Img2ImgRequest: Encodable {
        var prompt: String
        var negative_prompt: String
        var init_images: [String]
        var denoising_strength: Double
        var width: Int
        var height: Int
        var steps: Int
        var cfg_scale: Double
        var seed: Int?
        var batch_size: Int = 1
        var n_iter: Int = 1
    }

    private struct GenerationResponse: Decodable {
        var images: [String]
    }

    func generateImage(
        prompt: String,
        config: DrawThingsPlaceConfig,
        outputURL: URL
    ) async throws {
        let clampedSteps = max(4, min(config.steps, 8))
        guard var components = URLComponents(string: config.apiHost) else {
            throw ServiceError.invalidBaseURL
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        components.port = config.apiPort
        components.path = "/sdapi/v1/txt2img"
        guard let url = components.url else {
            throw ServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONEncoder().encode(
            GenerationRequest(
                prompt: prompt,
                negative_prompt: config.negativePrompt,
                width: config.imageWidth,
                height: config.imageHeight,
                steps: clampedSteps,
                cfg_scale: config.cfgScale,
                seed: config.seed
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ServiceError.httpError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(GenerationResponse.self, from: data)
        guard let encodedImage = decoded.images.first else {
            throw ServiceError.noImageData
        }

        let cleanedBase64 = encodedImage
            .components(separatedBy: ",")
            .last ?? encodedImage
        guard let imageData = Data(base64Encoded: cleanedBase64) else {
            throw ServiceError.invalidResponse
        }

        try imageData.write(to: outputURL, options: .atomic)
    }

    func generateImg2ImgImage(
        prompt: String,
        sourceImageURL: URL,
        denoisingStrength: Double,
        config: DrawThingsPlaceConfig,
        outputURL: URL
    ) async throws {
        let clampedSteps = max(4, min(config.steps, 8))
        guard var components = URLComponents(string: config.apiHost) else {
            throw ServiceError.invalidBaseURL
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        components.port = config.apiPort
        components.path = "/sdapi/v1/img2img"
        guard let url = components.url else {
            throw ServiceError.invalidBaseURL
        }

        let sourceData = try Data(contentsOf: sourceImageURL)
        let base64Source = sourceData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONEncoder().encode(
            Img2ImgRequest(
                prompt: prompt,
                negative_prompt: config.negativePrompt,
                init_images: [base64Source],
                denoising_strength: denoisingStrength,
                width: config.imageWidth,
                height: config.imageHeight,
                steps: clampedSteps,
                cfg_scale: config.cfgScale,
                seed: config.seed
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ServiceError.httpError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(GenerationResponse.self, from: data)
        guard let encodedImage = decoded.images.first else {
            throw ServiceError.noImageData
        }

        let cleanedBase64 = encodedImage
            .components(separatedBy: ",")
            .last ?? encodedImage
        guard let imageData = Data(base64Encoded: cleanedBase64) else {
            throw ServiceError.invalidResponse
        }

        try imageData.write(to: outputURL, options: .atomic)
    }
}
