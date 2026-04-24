import XCTest
@testable import AnimateUI
import ProjectKit

@available(macOS 26.0, *)
final class ImageIntelligenceCredentialTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        ProjectCredentialStore.shared.setActiveProject(nil)
        super.tearDown()
    }

    // MARK: - Credential Separation

    func testImageAnalysisKeyIsSeparateFromGenerationKey() throws {
        let store = ProjectCredentialStore.shared
        store.setActiveProject(tempDir)

        store.setGeminiAPIKey("generation-key-123")
        store.setImageAnalysisGeminiAPIKey("analysis-key-456")

        XCTAssertEqual(store.geminiAPIKey(), "generation-key-123")
        XCTAssertEqual(store.imageAnalysisGeminiAPIKey(), "analysis-key-456")
    }

    func testSettingOneKeyDoesNotAffectTheOther() throws {
        let store = ProjectCredentialStore.shared
        store.setActiveProject(tempDir)

        store.setGeminiAPIKey("generation-key")
        store.setImageAnalysisGeminiAPIKey("analysis-key")

        // Change generation key — analysis key should remain
        store.setGeminiAPIKey("new-generation-key")
        XCTAssertEqual(store.imageAnalysisGeminiAPIKey(), "analysis-key")

        // Change analysis key — generation key should remain
        store.setImageAnalysisGeminiAPIKey("new-analysis-key")
        XCTAssertEqual(store.geminiAPIKey(), "new-generation-key")
    }

    func testClearingOneKeyDoesNotAffectTheOther() throws {
        let store = ProjectCredentialStore.shared
        store.setActiveProject(tempDir)

        store.setGeminiAPIKey("generation-key")
        store.setImageAnalysisGeminiAPIKey("analysis-key")

        store.setGeminiAPIKey("")
        XCTAssertEqual(store.geminiAPIKey(), "")
        XCTAssertEqual(store.imageAnalysisGeminiAPIKey(), "analysis-key")
    }

    func testCredentialPayloadRoundTrip() throws {
        let store = ProjectCredentialStore.shared
        store.setActiveProject(tempDir)

        store.setGeminiAPIKey("gen-key")
        store.setImageAnalysisGeminiAPIKey("analysis-key")
        store.setMiniMaxAPIKey("minimax-key")

        // Simulate reload by resetting and re-setting active project
        store.setActiveProject(nil)
        store.setActiveProject(tempDir)

        XCTAssertEqual(store.geminiAPIKey(), "gen-key")
        XCTAssertEqual(store.imageAnalysisGeminiAPIKey(), "analysis-key")
        XCTAssertEqual(store.miniMaxAPIKey(), "minimax-key")
    }

    func testImageAnalysisKeyDoesNotFallBackToGenerationKey() throws {
        let store = ProjectCredentialStore.shared
        store.setActiveProject(tempDir)

        store.setGeminiAPIKey("generation-key")
        // Do NOT set image analysis key

        XCTAssertEqual(store.imageAnalysisGeminiAPIKey(), "")
        XCTAssertNotEqual(store.imageAnalysisGeminiAPIKey(), store.geminiAPIKey())
    }

    func testMaskingBehavior() throws {
        let store = ProjectCredentialStore.shared
        store.setActiveProject(tempDir)

        store.setImageAnalysisGeminiAPIKey("secret-analysis-key")

        // The raw key should be retrievable for API calls
        XCTAssertEqual(store.imageAnalysisGeminiAPIKey(), "secret-analysis-key")
    }

    // MARK: - AnimateStore Integration

    @MainActor
    func testAnimateStoreHydratesImageAnalysisKey() throws {
        let credentialStore = ProjectCredentialStore.shared
        credentialStore.setActiveProject(tempDir)
        credentialStore.setImageAnalysisGeminiAPIKey("hydrated-analysis-key")

        let animateStore = AnimateStore()
        // AnimateStore init calls hydrateImageAnalysisSettings()
        XCTAssertEqual(animateStore.imageAnalysisGeminiAPIKey, "hydrated-analysis-key")
    }

    @MainActor
    func testAnimateStoreSettingImageAnalysisKeyUpdatesCredentialStore() throws {
        let credentialStore = ProjectCredentialStore.shared
        credentialStore.setActiveProject(tempDir)

        let animateStore = AnimateStore()
        animateStore.setImageAnalysisGeminiAPIKey("new-analysis-key")

        XCTAssertEqual(credentialStore.imageAnalysisGeminiAPIKey(), "new-analysis-key")
    }

    @MainActor
    func testAnimateStoreClearingImageAnalysisKey() throws {
        let credentialStore = ProjectCredentialStore.shared
        credentialStore.setActiveProject(tempDir)
        credentialStore.setImageAnalysisGeminiAPIKey("existing-key")

        let animateStore = AnimateStore()
        animateStore.clearImageAnalysisGeminiAPIKey()

        XCTAssertEqual(credentialStore.imageAnalysisGeminiAPIKey(), "")
        XCTAssertEqual(animateStore.imageAnalysisGeminiAPIKey, "")
    }

    // MARK: - ProjectPaths

    func testImageIntelligenceSQLitePath() throws {
        let paths = ProjectPaths(root: tempDir)
        let expected = tempDir
            .appendingPathComponent(".novotro", isDirectory: true)
            .appendingPathComponent("image-intelligence.sqlite")

        XCTAssertEqual(paths.imageIntelligenceSQLite, expected)
    }

    func testImageIntelligenceSQLiteIsInNovotroDir() throws {
        let paths = ProjectPaths(root: tempDir)
        let sqlitePath = paths.imageIntelligenceSQLite
        let novotroPath = paths.novotroDir

        XCTAssertTrue(sqlitePath.path.hasPrefix(novotroPath.path))
    }
}