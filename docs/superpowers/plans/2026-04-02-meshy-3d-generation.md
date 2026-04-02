# Meshy 3D Generation Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Meshy.ai 3D model generation to the character page — crop adjustment on reference workflow thumbnails, a new inline 3D generation section, unified API settings, and laptop layout fixes.

**Architecture:** New `MeshyService` and `MeshyCredentialStore` mirror existing Gemini patterns. A new `Meshy3DGenerationPane` view is inserted as a collapsible section in `CharactersPageView.characterDetail` between "Character Reference Workflow" and "Animated Images". The existing `ImageCropperView` is extended with a "Crop Pose" context menu item on reference workflow thumbnails. `GeminiSettingsSheet` is renamed to `APISettingsSheet` with tabbed sections.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26), URLSession, Security framework (Keychain), XCTest

**Spec:** `docs/superpowers/specs/2026-04-02-meshy-3d-generation-design.md`

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `Sources/AnimateUI/Models/MeshyModels.swift` | Request/response types for Meshy API |
| `Sources/AnimateUI/Services/MeshyCredentialStore.swift` | Keychain storage for Meshy API key |
| `Sources/AnimateUI/Services/MeshyService.swift` | API client: create tasks, poll status, download assets |
| `Sources/AnimateUI/Views/Meshy3DGenerationPane.swift` | Inline collapsible section UI for 3D generation |
| `Tests/AnimateTests/MeshyServiceTests.swift` | Unit tests for models, credential store, service encoding/decoding |

### Modified Files
| File | Change |
|------|--------|
| `Sources/AnimateUI/AnimateStore.swift` | Add Meshy state (apiKey, credential store, generation status) |
| `Sources/AnimateUI/Views/CharactersPageView.swift` | Add Meshy pane to characterDetail, add AppStorage toggle, fix laptop layout |
| `Sources/AnimateUI/Views/CharacterReferenceWorkflowSheet.swift` | Add "Adjust Crop" context menu to MiniVariantChip and approvedVariantThumbnail |
| `Sources/AnimateUI/Views/GeminiSettingsSheet.swift` | Rename to `APISettingsSheet`, add Meshy section with tabs |
| `Sources/AnimateUI/Views/ContentView.swift` | Update reference from GeminiSettingsSheet to APISettingsSheet |

All paths are relative to `Packages/Animate/`.

---

### Task 1: Meshy Models

**Files:**
- Create: `Sources/AnimateUI/Models/MeshyModels.swift`
- Test: `Tests/AnimateTests/MeshyServiceTests.swift`

- [ ] **Step 1: Write failing test for request JSON encoding**

Create `Tests/AnimateTests/MeshyServiceTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift test --filter MeshyServiceTests 2>&1 | head -30`
Expected: Compilation error — `MeshyMultiImageRequest` not found.

- [ ] **Step 3: Write the models**

Create `Sources/AnimateUI/Models/MeshyModels.swift`:

```swift
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
```

- [ ] **Step 4: Add test for response decoding**

Append to `MeshyServiceTests.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift test --filter MeshyServiceTests 2>&1 | tail -20`
Expected: All 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/Models/MeshyModels.swift Packages/Animate/Tests/AnimateTests/MeshyServiceTests.swift
git commit -m "feat: add Meshy API request/response models with tests"
```

---

### Task 2: MeshyCredentialStore

**Files:**
- Create: `Sources/AnimateUI/Services/MeshyCredentialStore.swift`
- Test: `Tests/AnimateTests/MeshyServiceTests.swift` (append)

- [ ] **Step 1: Write failing test for credential store**

Append to `MeshyServiceTests.swift`:

```swift
    func testCredentialStoreRoundTrip() {
        let store = MeshyCredentialStore()
        // Clean up from any prior run
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift test --filter testCredentialStore 2>&1 | head -20`
Expected: Compilation error — `MeshyCredentialStore` not found.

- [ ] **Step 3: Create MeshyCredentialStore**

Create `Sources/AnimateUI/Services/MeshyCredentialStore.swift`:

```swift
import Foundation
import Security

@available(macOS 26.0, *)
struct MeshyCredentialStore: Sendable {
    private let service = "com.amira.writer.animate"
    private let account = "meshy-api-key"

    func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return key
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAPIKey()
            return
        }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }

    func clearAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift test --filter testCredentialStore 2>&1 | tail -10`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/Services/MeshyCredentialStore.swift Packages/Animate/Tests/AnimateTests/MeshyServiceTests.swift
git commit -m "feat: add MeshyCredentialStore for Keychain API key storage"
```

---

### Task 3: MeshyService API Client

**Files:**
- Create: `Sources/AnimateUI/Services/MeshyService.swift`
- Test: `Tests/AnimateTests/MeshyServiceTests.swift` (append)

- [ ] **Step 1: Write failing test for request building**

Append to `MeshyServiceTests.swift`:

```swift
    func testServiceBuildsCorrectMultiImageURLRequest() throws {
        let service = MeshyService(apiKey: "msy_test_key")
        let request = MeshyMultiImageRequest(
            imageURLs: ["data:image/png;base64,abc"],
            targetPolycount: 50_000,
            targetFormats: ["glb"]
        )

        let urlRequest = try service.buildCreateTaskRequest(
            endpoint: "multi-image-to-3d",
            body: request
        )

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.meshy.ai/openapi/v1/multi-image-to-3d")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer msy_test_key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as! [String: Any]
        XCTAssertEqual(body["target_polycount"] as? Int, 50_000)
    }

    func testServiceBuildsCorrectGetTaskRequest() throws {
        let service = MeshyService(apiKey: "msy_test_key")
        let urlRequest = service.buildGetTaskRequest(
            endpoint: "multi-image-to-3d",
            taskID: "task-abc-123"
        )

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.meshy.ai/openapi/v1/multi-image-to-3d/task-abc-123")
        XCTAssertEqual(urlRequest.httpMethod, "GET")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer msy_test_key")
    }

    func testServiceBuildsBalanceRequest() throws {
        let service = MeshyService(apiKey: "msy_test_key")
        let urlRequest = service.buildBalanceRequest()

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.meshy.ai/openapi/v1/balance")
        XCTAssertEqual(urlRequest.httpMethod, "GET")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer msy_test_key")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift test --filter testServiceBuilds 2>&1 | head -20`
Expected: Compilation error — `MeshyService` not found.

- [ ] **Step 3: Create MeshyService**

Create `Sources/AnimateUI/Services/MeshyService.swift`:

```swift
import Foundation

@available(macOS 26.0, *)
final class MeshyService: Sendable {
    static let baseURL = "https://api.meshy.ai/openapi/v1"

    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Error

    enum ServiceError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case httpError(Int, String)
        case taskFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "No Meshy API key configured."
            case .invalidResponse: "Invalid response from Meshy API."
            case .httpError(let code, let msg): "Meshy API error \(code): \(msg)"
            case .taskFailed(let msg): "3D generation failed: \(msg)"
            case .cancelled: "Generation was cancelled."
            }
        }
    }

    // MARK: - Request Builders

    func buildCreateTaskRequest<T: Encodable>(endpoint: String, body: T) throws -> URLRequest {
        let url = URL(string: "\(Self.baseURL)/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        return request
    }

    func buildGetTaskRequest(endpoint: String, taskID: String) -> URLRequest {
        let url = URL(string: "\(Self.baseURL)/\(endpoint)/\(taskID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func buildBalanceRequest() -> URLRequest {
        let url = URL(string: "\(Self.baseURL)/balance")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - API Calls

    func createMultiImageTo3D(_ request: MeshyMultiImageRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        let urlRequest = try buildCreateTaskRequest(endpoint: "multi-image-to-3d", body: request)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        let result = try JSONDecoder().decode(MeshyCreateTaskResponse.self, from: data)
        return result.result
    }

    func createImageTo3D(_ request: MeshyImageRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        let urlRequest = try buildCreateTaskRequest(endpoint: "image-to-3d", body: request)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        let result = try JSONDecoder().decode(MeshyCreateTaskResponse.self, from: data)
        return result.result
    }

    func getTaskStatus(endpoint: String, taskID: String) async throws -> MeshyTaskResponse {
        let urlRequest = buildGetTaskRequest(endpoint: endpoint, taskID: taskID)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        return try JSONDecoder().decode(MeshyTaskResponse.self, from: data)
    }

    func pollUntilComplete(
        endpoint: String,
        taskID: String,
        onProgress: @Sendable (MeshyTaskResponse) -> Void
    ) async throws -> MeshyTaskResponse {
        while true {
            let task = try await getTaskStatus(endpoint: endpoint, taskID: taskID)
            onProgress(task)

            switch task.status {
            case .succeeded:
                return task
            case .failed:
                throw ServiceError.taskFailed(task.taskError?.message ?? "Unknown error")
            case .canceled:
                throw ServiceError.cancelled
            case .pending, .inProgress:
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    func checkBalance() async throws -> Int {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        let urlRequest = buildBalanceRequest()
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        let result = try JSONDecoder().decode(MeshyBalanceResponse.self, from: data)
        return result.balance
    }

    func downloadAsset(from remoteURL: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ServiceError.invalidResponse
        }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Helpers

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw ServiceError.httpError(httpResponse.statusCode, body)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift test --filter MeshyServiceTests 2>&1 | tail -15`
Expected: All tests PASS (including the new request builder tests).

- [ ] **Step 5: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/Services/MeshyService.swift Packages/Animate/Tests/AnimateTests/MeshyServiceTests.swift
git commit -m "feat: add MeshyService API client with request builders and polling"
```

---

### Task 4: AnimateStore — Meshy State

**Files:**
- Modify: `Sources/AnimateUI/AnimateStore.swift`

This task adds Meshy API key management, generation state, and asset download orchestration to AnimateStore — mirroring the existing Gemini key pattern.

- [ ] **Step 1: Add Meshy properties to AnimateStore**

In `AnimateStore.swift`, near the existing Gemini properties (around line 100-111), add after the `selectedGeminiModel` property:

```swift
    // MARK: - Meshy Settings

    var meshyAPIKey: String = "" {
        didSet {
            guard !isHydratingMeshySettings else { return }
            meshyCredentialStore.saveAPIKey(meshyAPIKey)
        }
    }

    var meshyBalance: Int?
    var meshyGenerationTaskID: String?
    var meshyGenerationStatus: MeshyTaskStatus?
    var meshyGenerationProgress: Int = 0
    var meshyGenerationError: String?
    var isGeneratingMeshy3D: Bool = false
    var meshyGeneratingCharacterID: UUID?
```

Near the existing `geminiCredentialStore` declaration (around line 211), add:

```swift
    private let meshyCredentialStore = MeshyCredentialStore()
    private var isHydratingMeshySettings = false
```

Near the existing `geminiModelDefaultsKey` (around line 244), there's nothing needed since Meshy has no UserDefaults settings.

- [ ] **Step 2: Add Meshy key management methods**

Near the existing `setGeminiAPIKey` / `clearGeminiAPIKey` methods (around line 251-257), add:

```swift
    func setMeshyAPIKey(_ apiKey: String) {
        meshyAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearMeshyAPIKey() {
        meshyAPIKey = ""
        meshyBalance = nil
    }
```

- [ ] **Step 3: Add Meshy hydration to init**

Find where `hydrateGeminiSettings()` is called (in the store's initialization path) and add `hydrateMeshySettings()` alongside it:

```swift
    private func hydrateMeshySettings() {
        isHydratingMeshySettings = true
        meshyAPIKey = meshyCredentialStore.loadAPIKey()
        isHydratingMeshySettings = false
    }
```

Call this method from the same location where `hydrateGeminiSettings()` is called.

- [ ] **Step 4: Add 3D generation orchestration method**

Add the main generation method that coordinates the full pipeline:

```swift
    func generateMeshy3DModel(
        for characterID: UUID,
        imageURLs: [String],
        textureImageURL: String?,
        config: MeshyMultiImageRequest
    ) async {
        guard !meshyAPIKey.isEmpty else {
            meshyGenerationError = "No Meshy API key configured. Open Settings to add one."
            return
        }
        guard !isGeneratingMeshy3D else { return }

        isGeneratingMeshy3D = true
        meshyGeneratingCharacterID = characterID
        meshyGenerationError = nil
        meshyGenerationProgress = 0
        meshyGenerationStatus = .pending

        do {
            let service = MeshyService(apiKey: meshyAPIKey)
            var request = config
            request.imageURLs = imageURLs
            if let textureURL = textureImageURL {
                request.textureImageURL = textureURL
            }

            // Create task
            let endpoint: String
            let taskID: String
            if imageURLs.count > 1 {
                taskID = try await service.createMultiImageTo3D(request)
                endpoint = "multi-image-to-3d"
            } else {
                let singleRequest = MeshyImageRequest(
                    imageURL: imageURLs[0],
                    aiModel: request.aiModel,
                    topology: request.topology,
                    targetPolycount: request.targetPolycount,
                    shouldRemesh: request.shouldRemesh,
                    shouldTexture: request.shouldTexture,
                    enablePBR: request.enablePBR,
                    removeLighting: request.removeLighting,
                    textureImageURL: request.textureImageURL,
                    targetFormats: request.targetFormats,
                    symmetryMode: request.symmetryMode
                )
                taskID = try await service.createImageTo3D(singleRequest)
                endpoint = "image-to-3d"
            }

            meshyGenerationTaskID = taskID

            // Poll until complete
            let result = try await service.pollUntilComplete(
                endpoint: endpoint,
                taskID: taskID
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.meshyGenerationStatus = progress.status
                    self?.meshyGenerationProgress = progress.progress
                }
            }

            // Download assets
            guard let modelURLs = result.modelURLs else {
                throw MeshyService.ServiceError.invalidResponse
            }

            try await downloadMeshyAssets(
                service: service,
                characterID: characterID,
                taskID: taskID,
                modelURLs: modelURLs,
                thumbnailURL: result.thumbnailURL
            )

            meshyGenerationStatus = .succeeded

        } catch {
            meshyGenerationError = error.localizedDescription
            meshyGenerationStatus = .failed
        }

        isGeneratingMeshy3D = false
    }

    private func downloadMeshyAssets(
        service: MeshyService,
        characterID: UUID,
        taskID: String,
        modelURLs: [String: String],
        thumbnailURL: String?
    ) async throws {
        guard let character = characters.first(where: { $0.id == characterID }),
              let animateURL = animateURL else { return }

        let slug = character.owpSlug.isEmpty ? character.id.uuidString : character.owpSlug
        let assetDir = animateURL
            .appendingPathComponent("Characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("3d-models")
            .appendingPathComponent(taskID)

        try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)

        // Download each model format
        for (format, urlString) in modelURLs {
            guard let remoteURL = URL(string: urlString) else { continue }
            // Skip pre_remeshed variants and mtl companions
            if format.hasPrefix("pre_remeshed") || format == "mtl" { continue }
            let destination = assetDir.appendingPathComponent("model.\(format)")
            try await service.downloadAsset(from: remoteURL, to: destination)

            // Add to character's models3D array
            let model3D = Character3DModel(
                costumeName: "meshy-\(taskID.prefix(8))",
                modelFileName: "model.\(format)",
                modelFormat: format,
                notes: "Generated via Meshy.ai (\(taskID))"
            )
            addModel3D(model3D, to: characterID)
        }

        // Download thumbnail
        if let thumbURLString = thumbnailURL, let thumbURL = URL(string: thumbURLString) {
            let thumbDest = assetDir.appendingPathComponent("thumbnail.png")
            try? await service.downloadAsset(from: thumbURL, to: thumbDest)
        }

        // Save metadata
        let metadataURL = assetDir.appendingPathComponent("metadata.json")
        let metadata: [String: Any] = [
            "taskID": taskID,
            "modelURLs": modelURLs,
            "downloadedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? data.write(to: metadataURL)
        }
    }

    private func addModel3D(_ model: Character3DModel, to characterID: UUID) {
        guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[index].models3D.append(model)
        saveCharacters()
    }

    func fetchMeshyBalance() async {
        guard !meshyAPIKey.isEmpty else {
            meshyBalance = nil
            return
        }
        let service = MeshyService(apiKey: meshyAPIKey)
        meshyBalance = try? await service.checkBalance()
    }
```

- [ ] **Step 5: Verify the project compiles**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/AnimateStore.swift
git commit -m "feat: add Meshy state management and 3D generation orchestration to AnimateStore"
```

---

### Task 5: Unified API Settings Sheet

**Files:**
- Modify: `Sources/AnimateUI/Views/GeminiSettingsSheet.swift` (rename to APISettingsSheet)
- Modify: `Sources/AnimateUI/Views/ContentView.swift`

- [ ] **Step 1: Rename and expand GeminiSettingsSheet**

Replace the full contents of `Sources/AnimateUI/Views/GeminiSettingsSheet.swift` with:

```swift
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct APISettingsSheet: View {
    @Bindable var store: AnimateStore
    let onDismiss: () -> Void

    @State private var geminiKeyDraft: String = ""
    @State private var meshyKeyDraft: String = ""
    @State private var revealGeminiKey: Bool = false
    @State private var revealMeshyKey: Bool = false
    @State private var selectedTab: SettingsTab = .gemini

    enum SettingsTab: String, CaseIterable {
        case gemini = "Gemini"
        case meshy = "Meshy"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            Picker("Service", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .gemini:
                geminiForm
            case .meshy:
                meshyForm
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            geminiKeyDraft = store.geminiAPIKey
            meshyKeyDraft = store.meshyAPIKey
            Task { await store.fetchMeshyBalance() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Settings")
                .font(.title3.weight(.semibold))
            Text("Manage API keys for AI services used by Animate. Keys are stored locally in your macOS Keychain.")
                .font(.callout)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Gemini

    private var geminiForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "Gemini API Key",
                draft: $geminiKeyDraft,
                reveal: $revealGeminiKey,
                placeholder: "Paste Gemini API key...",
                isSaved: !store.geminiAPIKey.isEmpty,
                savedLabel: "Gemini key saved.",
                unsavedLabel: "No Gemini key saved yet."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Model")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Picker("Default Model", selection: $store.selectedGeminiModel) {
                    ForEach(GeminiModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Text("Default for master sheets, head poses, costume poses, accessories, and other Gemini requests.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Meshy

    private var meshyForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "Meshy API Key",
                draft: $meshyKeyDraft,
                reveal: $revealMeshyKey,
                placeholder: "Paste Meshy API key...",
                isSaved: !store.meshyAPIKey.isEmpty,
                savedLabel: "Meshy key saved.",
                unsavedLabel: "No Meshy key saved yet."
            )

            if let balance = store.meshyBalance {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.secondary)
                    Text("\(balance) credits remaining")
                        .font(.callout)
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Spacer()
                    Button("Refresh") {
                        Task { await store.fetchMeshyBalance() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Used for 3D model generation from character reference images. Get a key at meshy.ai/settings/api.")
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared API Key Field

    private func apiKeyField(
        label: String,
        draft: Binding<String>,
        reveal: Binding<Bool>,
        placeholder: String,
        isSaved: Bool,
        savedLabel: String,
        unsavedLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.body.bold())
                .foregroundStyle(OperaChromeTheme.textPrimary)

            HStack(spacing: 8) {
                Group {
                    if reveal.wrappedValue {
                        TextField(placeholder, text: draft)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(placeholder, text: draft)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .font(.callout)

                Button(reveal.wrappedValue ? "Hide" : "Show") {
                    reveal.wrappedValue.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Image(systemName: isSaved ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isSaved ? .green : .orange)
                Text(isSaved ? savedLabel : unsavedLabel)
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Clear Keys", role: .destructive) {
                switch selectedTab {
                case .gemini:
                    geminiKeyDraft = ""
                    store.clearGeminiAPIKey()
                case .meshy:
                    meshyKeyDraft = ""
                    store.clearMeshyAPIKey()
                }
            }
            .buttonStyle(.bordered)
            .disabled(currentKeyIsEmpty)

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .buttonStyle(.bordered)

            Button("Save") {
                store.setGeminiAPIKey(geminiKeyDraft)
                store.setMeshyAPIKey(meshyKeyDraft)
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var currentKeyIsEmpty: Bool {
        switch selectedTab {
        case .gemini: store.geminiAPIKey.isEmpty && geminiKeyDraft.isEmpty
        case .meshy: store.meshyAPIKey.isEmpty && meshyKeyDraft.isEmpty
        }
    }
}

// Keep backward-compatible typealias during transition
@available(macOS 26.0, *)
typealias GeminiSettingsSheet = APISettingsSheet
```

- [ ] **Step 2: Update ContentView reference**

In `Sources/AnimateUI/Views/ContentView.swift`, line 80-84, the sheet already uses `GeminiSettingsSheet` which is now a typealias. The code compiles without changes. However, update the state variable name for clarity:

Find in `ContentView.swift` (line 15):
```swift
    @State private var showGeminiSettings: Bool = false
```
Replace with:
```swift
    @State private var showAPISettings: Bool = false
```

Then update all references to `showGeminiSettings` in the same file to `showAPISettings` (lines 80, 138, 140):

Line 80: `$showAPISettings`
Line 138: `showAPISettings`
Line 140: `showAPISettings = true`

- [ ] **Step 3: Verify the project compiles**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/Views/GeminiSettingsSheet.swift Packages/Animate/Sources/AnimateUI/Views/ContentView.swift
git commit -m "feat: expand GeminiSettingsSheet into unified APISettingsSheet with Meshy section"
```

---

### Task 6: Crop Adjustment on Reference Workflow Thumbnails

**Files:**
- Modify: `Sources/AnimateUI/Views/CharacterReferenceWorkflowSheet.swift`

The existing `ImageCropperView` in `CharactersPageView.swift` already provides a full crop editor with drag-to-reposition. We add a "Adjust Crop" context menu item to the pose variant thumbnails that triggers it.

- [ ] **Step 1: Add "Adjust Crop" to MiniVariantChip context menu**

In `CharacterReferenceWorkflowSheet.swift`, the `MiniVariantChip` struct (line 2044) currently has callbacks for quickLook, copy, edit, showPrompt, approve, delete. Add a new callback:

After the existing `let onDelete: () -> Void` (around line 2053), add:
```swift
    let onAdjustCrop: () -> Void
```

In the context menu block (around line 2064-2082), add after the "Copy Image" button:
```swift
                        Divider()
                        Button("Adjust Crop", systemImage: "crop") {
                            onAdjustCrop()
                        }
```

- [ ] **Step 2: Add "Adjust Crop" to approvedVariantThumbnail context menu**

In the `approvedVariantThumbnail` function (line 975), add an `onAdjustCrop` parameter:

Change the signature to:
```swift
    private func approvedVariantThumbnail(
        _ variant: CharacterLookDevelopmentVariant?,
        isGenerating: Bool,
        statusText: String,
        onEdit: @escaping () -> Void,
        onShowPrompt: @escaping () -> Void,
        onAdjustCrop: @escaping () -> Void
    ) -> some View {
```

In the context menu block (around line 990-1005), add after "Quick Look":
```swift
                    Divider()
                    Button("Adjust Crop", systemImage: "crop") {
                        onAdjustCrop()
                    }
```

- [ ] **Step 3: Wire up the crop callback at call sites**

Find all call sites of `MiniVariantChip` and `approvedVariantThumbnail` in the file. For each, add the `onAdjustCrop` parameter that triggers the store's image cropper:

```swift
onAdjustCrop: {
    if let url = store.resolvedCharacterAssetURL(for: variant.imagePath) {
        store.pendingCropImagePath = url.path
        store.pendingCropCharacterID = characterID
        store.showImageCropper = true
    }
}
```

Search for all `MiniVariantChip(` and `approvedVariantThumbnail(` occurrences in the file and add this parameter at each call site.

- [ ] **Step 4: Verify the project compiles**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/Views/CharacterReferenceWorkflowSheet.swift
git commit -m "feat: add Adjust Crop context menu to reference workflow pose thumbnails"
```

---

### Task 7: Meshy 3D Generation Pane

**Files:**
- Create: `Sources/AnimateUI/Views/Meshy3DGenerationPane.swift`
- Modify: `Sources/AnimateUI/Views/CharactersPageView.swift`

- [ ] **Step 1: Create the Meshy3DGenerationPane view**

Create `Sources/AnimateUI/Views/Meshy3DGenerationPane.swift`:

```swift
import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct Meshy3DGenerationPane: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    @State private var targetPolycount: Int = 100_000
    @State private var topology: String = "triangle"
    @State private var shouldTexture: Bool = true
    @State private var removeLighting: Bool = true
    @State private var enablePBR: Bool = false
    @State private var aiModel: String = "latest"
    @State private var symmetryMode: String = "auto"
    @State private var selectedFormats: Set<String> = ["glb", "usdz"]

    private let allFormats = ["glb", "usdz", "fbx", "obj", "stl"]
    private let poseOrder: [CharacterReferencePose] = [.frontNeutral, .leftProfile, .rightProfile, .back]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.meshyAPIKey.isEmpty {
                noAPIKeyBanner
            } else {
                imageSelectionSection
                Divider()
                configurationSection
                Divider()
                actionSection
            }
        }
    }

    // MARK: - No API Key

    private var noAPIKeyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            Text("No Meshy API key configured. Open Settings (gear icon) to add one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Image Selection

    private var imageSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reference Images")
                .font(.subheadline.weight(.semibold))

            let selectedImages = availablePoseImages()

            if selectedImages.isEmpty {
                Text("No approved pose images found. Approve poses in the Reference Workflow above first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                HStack(spacing: 12) {
                    ForEach(selectedImages, id: \.pose) { item in
                        VStack(spacing: 4) {
                            if let image = store.thumbnailImage(for: item.imagePath, maxSize: 120) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary.opacity(0.2))
                                    .frame(width: 80, height: 80)
                            }
                            Text(item.pose.gridLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if item.pose == .frontNeutral {
                                Text("Primary")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Text("\(selectedImages.count) image\(selectedImages.count == 1 ? "" : "s") will be sent to Meshy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generation Settings")
                .font(.subheadline.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Polycount")
                        .font(.callout)
                    TextField("Polycount", value: $targetPolycount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("(100 – 300,000)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GridRow {
                    Text("Topology")
                        .font(.callout)
                    Picker("", selection: $topology) {
                        Text("Triangle").tag("triangle")
                        Text("Quad").tag("quad")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    EmptyView()
                }

                GridRow {
                    Text("AI Model")
                        .font(.callout)
                    Picker("", selection: $aiModel) {
                        Text("Latest").tag("latest")
                        Text("Meshy-6").tag("meshy-6")
                        Text("Meshy-5").tag("meshy-5")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    EmptyView()
                }

                GridRow {
                    Text("Symmetry")
                        .font(.callout)
                    Picker("", selection: $symmetryMode) {
                        Text("Auto").tag("auto")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    EmptyView()
                }
            }

            HStack(spacing: 20) {
                Toggle("Texture", isOn: $shouldTexture)
                Toggle("Remove Lighting", isOn: $removeLighting)
                    .disabled(!shouldTexture)
                Toggle("PBR Maps", isOn: $enablePBR)
                    .disabled(!shouldTexture)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("Output Formats")
                    .font(.callout)
                HStack(spacing: 12) {
                    ForEach(allFormats, id: \.self) { fmt in
                        Toggle(fmt.uppercased(), isOn: Binding(
                            get: { selectedFormats.contains(fmt) },
                            set: { isOn in
                                if isOn { selectedFormats.insert(fmt) }
                                else if selectedFormats.count > 1 { selectedFormats.remove(fmt) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Action / Progress

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                let images = availablePoseImages()
                let request = buildRequest()

                Button {
                    Task {
                        let imageDataURLs = await encodeImages(images)
                        let textureURL = imageDataURLs.first
                        await store.generateMeshy3DModel(
                            for: character.id,
                            imageURLs: imageDataURLs,
                            textureImageURL: shouldTexture ? textureURL : nil,
                            config: request
                        )
                    }
                } label: {
                    Label("Generate 3D Model", systemImage: "cube.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(images.isEmpty || store.isGeneratingMeshy3D)

                Text("Est. \(request.estimatedCredits) credits")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let balance = store.meshyBalance {
                    Text("(\(balance) available)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Progress
            if store.isGeneratingMeshy3D, store.meshyGeneratingCharacterID == character.id {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(store.meshyGenerationProgress), total: 100)
                        .progressViewStyle(.linear)
                }
                .padding(10)
                .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            // Error
            if let error = store.meshyGenerationError, store.meshyGeneratingCharacterID == character.id {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(10)
                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            // Success
            if store.meshyGenerationStatus == .succeeded, store.meshyGeneratingCharacterID == character.id, !store.isGeneratingMeshy3D {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("3D model generated and downloaded. Check the 3D Models section below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Helpers

    private struct PoseImage: Sendable {
        let pose: CharacterReferencePose
        let imagePath: String
    }

    private func availablePoseImages() -> [PoseImage] {
        var results: [PoseImage] = []
        for pose in poseOrder {
            if let slot = character.headTurnaroundSlots.first(where: { $0.pose == pose }),
               let variant = slot.approvedVariant {
                results.append(PoseImage(pose: pose, imagePath: variant.imagePath))
            }
        }
        return results
    }

    private func buildRequest() -> MeshyMultiImageRequest {
        MeshyMultiImageRequest(
            imageURLs: [],  // filled at send time
            aiModel: aiModel,
            topology: topology,
            targetPolycount: max(100, min(300_000, targetPolycount)),
            shouldRemesh: true,
            shouldTexture: shouldTexture,
            enablePBR: enablePBR,
            removeLighting: removeLighting,
            targetFormats: Array(selectedFormats),
            symmetryMode: symmetryMode
        )
    }

    private func encodeImages(_ items: [PoseImage]) async -> [String] {
        items.compactMap { item -> String? in
            guard let url = store.resolvedCharacterAssetURL(for: item.imagePath),
                  let data = try? Data(contentsOf: url) else { return nil }
            let ext = url.pathExtension.lowercased()
            let mime = ext == "png" ? "image/png" : "image/jpeg"
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
    }

    private var statusLabel: String {
        switch store.meshyGenerationStatus {
        case .pending: "Queued..."
        case .inProgress: "Generating... \(store.meshyGenerationProgress)%"
        case .succeeded: "Complete"
        case .failed: "Failed"
        case .canceled: "Cancelled"
        case nil: "Preparing..."
        }
    }
}
```

- [ ] **Step 2: Add the pane to CharactersPageView**

In `Sources/AnimateUI/Views/CharactersPageView.swift`, add an AppStorage property near the other pane toggles (around line 24):

```swift
    @AppStorage("charactersPage.showMeshy3DGenerationPane") private var showMeshy3DGenerationPane: Bool = false
```

In the `characterDetail` computed property (around line 395, after the Reference Workflow pane closure), insert the new pane:

```swift
                    collapsiblePane(
                        title: "3D Model Generation",
                        icon: "cube.transparent",
                        isExpanded: $showMeshy3DGenerationPane
                    ) {
                        if showMeshy3DGenerationPane {
                            Meshy3DGenerationPane(store: store, character: character)
                        }
                    }
```

This goes between the "Character Reference Workflow" pane (ending around line 395) and the "Animated Images" pane (starting around line 397).

- [ ] **Step 3: Verify the project compiles**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/Views/Meshy3DGenerationPane.swift Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift
git commit -m "feat: add Meshy 3D Generation collapsible pane to character page"
```

---

### Task 8: Laptop Layout Fixes

**Files:**
- Modify: `Sources/AnimateUI/Views/CharactersPageView.swift`

- [ ] **Step 1: Audit and fix layout constraints**

In `CharactersPageView.swift`, check the following potential overflow sources:

1. **Sidebar width** (line 51): `min(geo.size.width * 0.3, 280)` — this is fine.

2. **Collapsible pane trailing button clusters** — the Inspiration Images pane (line 356-373) has a `Menu` + `Button` in an `HStack` in the trailing slot. On narrow widths these can overflow.

   Fix: Wrap trailing buttons in menus when space is tight. For the inspiration section, combine the "Generate" and "Import" buttons into a single `Menu` with a `+` icon at narrow widths. Use `ViewThatFits` (macOS 26):

   Replace the `trailing:` block of the Inspiration Images pane with:
   ```swift
   trailing: {
       ViewThatFits {
           // Full layout for wide screens
           HStack(spacing: 8) {
               Menu {
                   inspirationGenerationMenuItems(for: character, wardrobe: character.defaultWardrobeType)
               } label: {
                   Label("Generate", systemImage: "sparkles")
               }
               .menuStyle(.button)
               .buttonStyle(.borderedProminent)
               .controlSize(.small)
               .disabled(store.geminiAPIKey.isEmpty || isGeneratingInspiration || isSubmittingInspirationBatch)

               Button("Import") {
                   store.importInspirationImages(for: character.id)
               }
               .buttonStyle(.bordered)
               .controlSize(.small)
           }

           // Compact layout for narrow screens
           Menu {
               Section("Generate") {
                   inspirationGenerationMenuItems(for: character, wardrobe: character.defaultWardrobeType)
               }
               Section {
                   Button("Import Images", systemImage: "square.and.arrow.down") {
                       store.importInspirationImages(for: character.id)
                   }
               }
           } label: {
               Image(systemName: "plus.circle.fill")
           }
           .menuStyle(.button)
           .buttonStyle(.borderedProminent)
           .controlSize(.small)
           .disabled(store.geminiAPIKey.isEmpty || isGeneratingInspiration || isSubmittingInspirationBatch)
       }
   }
   ```

3. **Character Packages trailing button** — similar pattern. The "Import Package..." button text is long. Change to compact form using `ViewThatFits`:

   Replace the trailing block of the Character Packages pane with:
   ```swift
   trailing: {
       ViewThatFits {
           Button("Import Package...") {
               openCharacterPackagePicker()
           }
           .buttonStyle(.bordered)
           .controlSize(.small)
           .disabled(store.animateURL == nil)

           Button {
               openCharacterPackagePicker()
           } label: {
               Image(systemName: "square.and.arrow.down")
           }
           .buttonStyle(.bordered)
           .controlSize(.small)
           .disabled(store.animateURL == nil)
       }
   }
   ```

4. **MiniVariantChip buttons** — the vertical stack of buttons (Use, Edit, eye, trash) at 72px wide can overflow on narrow panes. These are already in a VStack at controlSize(.mini) which should be fine.

- [ ] **Step 2: Verify the project compiles**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git add Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift
git commit -m "fix: improve character page layout for narrow/laptop screens"
```

---

### Task 9: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift test 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 2: Verify all new files exist**

Run:
```bash
ls -la "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Models/MeshyModels.swift"
ls -la "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/MeshyCredentialStore.swift"
ls -la "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/MeshyService.swift"
ls -la "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Views/Meshy3DGenerationPane.swift"
ls -la "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Tests/AnimateTests/MeshyServiceTests.swift"
```

- [ ] **Step 3: Verify build succeeds**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate" && swift build 2>&1 | tail -10`
Expected: Build succeeds with no warnings related to new code.

- [ ] **Step 4: Final commit if any fixups needed**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
git status
# If clean, skip. If fixups needed, add and commit.
```
