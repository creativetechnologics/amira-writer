import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class MeshyServiceTests: XCTestCase {

    func testMultiImageRequestEncodesCorrectJSON() throws {
        let request = MeshyMultiImageRequest(
            imageURLs: ["data:image/png;base64,abc123", "data:image/png;base64,def456"],
            aiModel: "meshy-6",
            topology: "triangle",
            targetPolycount: 100_000,
            shouldRemesh: true,
            shouldTexture: true,
            enablePBR: false,
            removeLighting: true,
            textureImageURL: "data:image/png;base64,abc123",
            targetFormats: ["glb", "usdz"],
            symmetryMode: "auto"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["image_urls"] as? [String], ["data:image/png;base64,abc123", "data:image/png;base64,def456"])
        XCTAssertEqual(json["ai_model"] as? String, "meshy-6")
        XCTAssertEqual(json["topology"] as? String, "triangle")
        XCTAssertEqual(json["target_polycount"] as? Int, 100_000)
        XCTAssertEqual(json["should_remesh"] as? Bool, true)
        XCTAssertEqual(json["should_texture"] as? Bool, true)
        XCTAssertEqual(json["enable_pbr"] as? Bool, false)
        XCTAssertEqual(json["remove_lighting"] as? Bool, true)
        XCTAssertEqual(json["texture_image_url"] as? String, "data:image/png;base64,abc123")
        XCTAssertEqual(json["target_formats"] as? [String], ["glb", "usdz"])
        XCTAssertEqual(json["symmetry_mode"] as? String, "auto")
    }

    func testSingleImageRequestEncodesCorrectJSON() throws {
        let request = MeshyImageRequest(
            imageURL: "data:image/png;base64,abc123",
            aiModel: "latest",
            topology: "triangle",
            targetPolycount: 100_000,
            shouldRemesh: true,
            shouldTexture: true,
            enablePBR: false,
            removeLighting: true,
            targetFormats: ["glb"]
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["image_url"] as? String, "data:image/png;base64,abc123")
        XCTAssertEqual(json["target_polycount"] as? Int, 100_000)
    }

    func testTaskResponseDecodesSucceededTask() throws {
        let json = """
        {
            "id": "018a210d-8ba4-705c-b111-1f1776f7f578",
            "status": "SUCCEEDED",
            "progress": 100,
            "model_urls": {
                "glb": "https://assets.meshy.ai/model.glb",
                "usdz": "https://assets.meshy.ai/model.usdz"
            },
            "thumbnail_url": "https://assets.meshy.ai/thumb.png",
            "texture_urls": [
                {
                    "base_color": "https://assets.meshy.ai/base.png",
                    "metallic": "https://assets.meshy.ai/metal.png",
                    "normal": "https://assets.meshy.ai/normal.png",
                    "roughness": "https://assets.meshy.ai/rough.png"
                }
            ],
            "task_error": { "message": "" },
            "created_at": 1692771842000,
            "finished_at": 1692771850000
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(MeshyTaskResponse.self, from: json)

        XCTAssertEqual(response.id, "018a210d-8ba4-705c-b111-1f1776f7f578")
        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.progress, 100)
        XCTAssertEqual(response.modelURLs?["glb"], "https://assets.meshy.ai/model.glb")
        XCTAssertEqual(response.modelURLs?["usdz"], "https://assets.meshy.ai/model.usdz")
        XCTAssertEqual(response.thumbnailURL, "https://assets.meshy.ai/thumb.png")
        XCTAssertEqual(response.textureURLs?.first?.baseColor, "https://assets.meshy.ai/base.png")
        XCTAssertEqual(response.taskError?.message, "")
    }

    func testTaskResponseDecodesFailedTask() throws {
        let json = """
        {
            "id": "failed-task-id",
            "status": "FAILED",
            "progress": 42,
            "model_urls": null,
            "thumbnail_url": null,
            "texture_urls": null,
            "task_error": { "message": "Server Busy" },
            "created_at": 1692771842000,
            "finished_at": 0
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(MeshyTaskResponse.self, from: json)

        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.taskError?.message, "Server Busy")
        XCTAssertEqual(response.finishedAt, 0)
    }

    func testCreditEstimation() {
        let meshyLatest = MeshyMultiImageRequest(imageURLs: ["img"], shouldTexture: true)
        XCTAssertEqual(meshyLatest.estimatedCredits, 30)

        let meshyNoTexture = MeshyMultiImageRequest(imageURLs: ["img"], shouldTexture: false)
        XCTAssertEqual(meshyNoTexture.estimatedCredits, 20)

        let oldModel = MeshyMultiImageRequest(imageURLs: ["img"], aiModel: "meshy-5", shouldTexture: true)
        XCTAssertEqual(oldModel.estimatedCredits, 15)
    }

    func testCredentialStoreRoundTrip() {
        let store = MeshyCredentialStore()
        store.clearAPIKey()

        XCTAssertEqual(store.loadAPIKey(), "")

        store.saveAPIKey("msy_test_key_12345")
        XCTAssertEqual(store.loadAPIKey(), "msy_test_key_12345")

        store.saveAPIKey("  msy_updated_key  ")
        XCTAssertEqual(store.loadAPIKey(), "msy_updated_key")

        store.clearAPIKey()
        XCTAssertEqual(store.loadAPIKey(), "")
    }

    func testCredentialStoreClearsOnEmptyString() {
        let store = MeshyCredentialStore()
        store.saveAPIKey("msy_temp")
        store.saveAPIKey("")
        XCTAssertEqual(store.loadAPIKey(), "")
    }
}
