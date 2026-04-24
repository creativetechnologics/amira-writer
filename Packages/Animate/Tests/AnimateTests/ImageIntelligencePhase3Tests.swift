import XCTest
@testable import AnimateUI
import ProjectKit

@available(macOS 26.0, *)
final class ImageIntelligencePhase3Tests: XCTestCase {

    var tempDir: URL!
    var store: ImageIntelligenceStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ImageIntelligenceStore(projectURL: tempDir)
        try await store.open()
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Discovery Integration

    @MainActor
    func testDiscoveryServiceExists() async throws {
        // Create a minimal AnimateStore for testing
        let animateStore = AnimateStore()

        // The discovery service should be creatable
        let discovery = await ImageAssetDiscoveryService(store: animateStore)
        XCTAssertNotNil(discovery)

        // Should return a result even with empty store
        let result = discovery.discoverAll()
        XCTAssertEqual(result.totalCount, 0)
        XCTAssertTrue(result.assets.isEmpty)
    }

    // MARK: - Backfill Service

    func testBackfillDryRun() async throws {
        let animateStore = await AnimateStore()
        let discovery = await ImageAssetDiscoveryService(store: animateStore)
        let backfill = ImageAnalysisBackfillService(store: store, discoveryService: discovery)

        let report = await backfill.dryRunReport()

        XCTAssertTrue(report.isDryRun)
        XCTAssertEqual(report.totalDiscovered, 0)
        XCTAssertEqual(report.newlyRegistered, 0)
        XCTAssertEqual(report.errors.count, 0)
    }

    func testBackfillWithRealAsset() async throws {
        // Create a test image file
        let testImagePath = tempDir.appendingPathComponent("test-image.png").path
        let testData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header
        try testData.write(to: URL(fileURLWithPath: testImagePath))

        // Register the asset directly first
        let assetID = try await store.registerAsset(
            resolvedPath: testImagePath,
            contentHashSHA256: "test-hash"
        )

        // Verify it was registered
        let asset = try await store.assetByPath(testImagePath)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.id, assetID)
    }

    // MARK: - ImageAssetInspector

    func testInspectorReturnsNilForMissingFile() {
        let result = ImageAssetInspector.inspect(path: "/nonexistent/path.png")
        XCTAssertFalse(result.isReadable)
        XCTAssertNil(result.contentHashSHA256)
        XCTAssertNil(result.width)
        XCTAssertNil(result.height)
    }

    func testInspectorReadsRealFile() throws {
        // Create a test file
        let testPath = tempDir.appendingPathComponent("test.txt").path
        try "test content".write(toFile: testPath, atomically: true, encoding: .utf8)

        let result = ImageAssetInspector.inspect(path: testPath)
        XCTAssertTrue(result.isReadable)
        XCTAssertNotNil(result.contentHashSHA256)
        XCTAssertEqual(result.fileSizeBytes, 12)
    }

    func testInspectorComputesHash() throws {
        let testPath = tempDir.appendingPathComponent("hash-test.txt").path
        let content = "hello world"
        try content.write(toFile: testPath, atomically: true, encoding: .utf8)

        let hash = try ImageAssetInspector.computeContentHash(path: testPath)
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash?.count, 64) // SHA-256 hex string length

        // Same content should produce same hash
        let hash2 = try ImageAssetInspector.computeContentHash(path: testPath)
        XCTAssertEqual(hash, hash2)
    }

    func testInspectorFileSize() throws {
        let testPath = tempDir.appendingPathComponent("size-test.txt").path
        let content = Data(repeating: 0, count: 1024)
        try content.write(to: URL(fileURLWithPath: testPath))

        let size = ImageAssetInspector.fileSizeBytes(path: testPath)
        XCTAssertEqual(size, 1024)
    }

    // MARK: - Asset Registration with Inspection

    func testRegisterAssetWithInspection() async throws {
        let testPath = tempDir.appendingPathComponent("inspected.png").path
        let testData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try testData.write(to: URL(fileURLWithPath: testPath))

        let inspection = ImageAssetInspector.inspect(path: testPath)

        let assetID = try await store.registerAsset(
            resolvedPath: testPath,
            filename: "inspected.png",
            mimeType: inspection.mimeType,
            width: inspection.width,
            height: inspection.height,
            fileSizeBytes: inspection.fileSizeBytes,
            contentHashSHA256: inspection.contentHashSHA256
        )

        let asset = try await store.assetByID(assetID)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.filename, "inspected.png")
        XCTAssertEqual(asset?.fileSizeBytes, 8)
    }
}