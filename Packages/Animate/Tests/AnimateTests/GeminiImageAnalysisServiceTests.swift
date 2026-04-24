import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class GeminiImageAnalysisServiceTests: XCTestCase {

    func testConfigDefaults() {
        let config = GeminiImageAnalysisService.AnalysisConfig(apiKey: "test-key")

        XCTAssertEqual(config.visualModelID, "gemini-3-flash-preview")
        XCTAssertEqual(config.embeddingModelID, "gemini-embedding-2")
        XCTAssertEqual(config.embeddingDimension, 3072)
        XCTAssertEqual(config.thinkingLevel, .low)
        XCTAssertEqual(config.baseURL, "https://generativelanguage.googleapis.com")
    }

    func testConfigCustomValues() {
        let config = GeminiImageAnalysisService.AnalysisConfig(
            apiKey: "custom-key",
            visualModelID: "custom-model",
            embeddingModelID: "custom-embedding",
            embeddingDimension: 768,
            thinkingLevel: .minimal
        )

        XCTAssertEqual(config.apiKey, "custom-key")
        XCTAssertEqual(config.visualModelID, "custom-model")
        XCTAssertEqual(config.embeddingModelID, "custom-embedding")
        XCTAssertEqual(config.embeddingDimension, 768)
        XCTAssertEqual(config.thinkingLevel, .minimal)
    }

    func testServiceCreation() async {
        let config = GeminiImageAnalysisService.AnalysisConfig(apiKey: "test-key")
        let service = GeminiImageAnalysisService(config: config)
        XCTAssertNotNil(service)
    }

    func testNoAPIKeyError() async {
        let config = GeminiImageAnalysisService.AnalysisConfig(apiKey: "")
        let service = GeminiImageAnalysisService(config: config)

        do {
            _ = try await service.analyzeImage(imageData: Data())
            XCTFail("Should have thrown noAPIKey error")
        } catch let error as GeminiImageAnalysisService.AnalysisError {
            XCTAssertEqual(error, .noAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNoAPIKeyForEmbedding() async {
        let config = GeminiImageAnalysisService.AnalysisConfig(apiKey: "")
        let service = GeminiImageAnalysisService(config: config)

        do {
            _ = try await service.embedImage(imageData: Data())
            XCTFail("Should have thrown noAPIKey error")
        } catch let error as GeminiImageAnalysisService.AnalysisError {
            XCTAssertEqual(error, .noAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNoAPIKeyForTextEmbedding() async {
        let config = GeminiImageAnalysisService.AnalysisConfig(apiKey: "")
        let service = GeminiImageAnalysisService(config: config)

        do {
            _ = try await service.embedText("test query")
            XCTFail("Should have thrown noAPIKey error")
        } catch let error as GeminiImageAnalysisService.AnalysisError {
            XCTAssertEqual(error, .noAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAnalysisResultStructure() {
        let result = GeminiImageAnalysisService.VisualAnalysisResult(
            summary: "Test summary",
            shortCaption: "Short caption",
            longCaption: "Long caption",
            assetRoles: ["reference"],
            entities: [],
            scene: GeminiImageAnalysisService.VisualAnalysisResult.SceneInfo(
                setting: "outdoor",
                topography: nil,
                terrain: nil,
                foliage: nil,
                architecture: nil,
                weather: nil,
                season: nil,
                timeOfDay: nil,
                lighting: nil
            ),
            camera: GeminiImageAnalysisService.VisualAnalysisResult.CameraInfo(
                angle: nil,
                distance: nil,
                composition: nil,
                movement: nil
            ),
            style: GeminiImageAnalysisService.VisualAnalysisResult.StyleInfo(
                palette: nil,
                mood: nil,
                genre: nil,
                artisticStyle: nil
            ),
            quality: GeminiImageAnalysisService.VisualAnalysisResult.QualityInfo(
                overall: nil,
                sharpness: nil,
                exposure: nil,
                colorAccuracy: nil,
                artifacts: []
            ),
            retrievalTags: ["tag1", "tag2"],
            confidence: GeminiImageAnalysisService.VisualAnalysisResult.ConfidenceInfo(
                overall: 0.95,
                uncertainFields: []
            ),
            rawJSON: "{}"
        )

        XCTAssertEqual(result.summary, "Test summary")
        XCTAssertEqual(result.retrievalTags.count, 2)
        XCTAssertEqual(result.confidence.overall, 0.95)
    }

    func testEmbeddingResultStructure() {
        let vector: [Float] = [0.1, 0.2, 0.3]
        let result = GeminiImageAnalysisService.EmbeddingResult(
            vector: vector,
            dimension: 3,
            modelID: "test-model"
        )

        XCTAssertEqual(result.vector.count, 3)
        XCTAssertEqual(result.dimension, 3)
        XCTAssertEqual(result.modelID, "test-model")
    }

    func testThinkingLevelRawValues() {
        XCTAssertEqual(GeminiImageAnalysisService.ThinkingLevel.minimal.rawValue, "minimal")
        XCTAssertEqual(GeminiImageAnalysisService.ThinkingLevel.low.rawValue, "low")
    }
}