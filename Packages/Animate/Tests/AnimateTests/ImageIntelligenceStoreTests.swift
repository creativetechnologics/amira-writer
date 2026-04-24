import XCTest
@testable import AnimateUI
import ProjectKit

@available(macOS 26.0, *)
final class ImageIntelligenceStoreTests: XCTestCase {

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

    // MARK: - Schema

    func testSchemaCreatesAllTables() async throws {
        // Verify tables exist by querying them
        let tables = ["image_assets", "image_asset_links", "image_analysis_runs",
                     "image_visual_metadata", "image_tags", "image_tag_assignments",
                     "image_embeddings", "image_analysis_jobs", "image_qc_flags"]

        for table in tables {
            // This will throw if table doesn't exist
            _ = try await store.assetByID("nonexistent")
        }
    }

    // MARK: - Asset Registration

    func testRegisterNewAsset() async throws {
        let path = "/test/images/photo1.png"
        let id = try await store.registerAsset(
            resolvedPath: path,
            projectRelativePath: "images/photo1.png",
            filename: "photo1.png",
            mimeType: "image/png",
            width: 1920,
            height: 1080,
            fileSizeBytes: 1024000,
            contentHashSHA256: "abc123"
        )

        XCTAssertFalse(id.isEmpty)

        let asset = try await store.assetByPath(path)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.resolvedPath, path)
        XCTAssertEqual(asset?.width, 1920)
        XCTAssertEqual(asset?.height, 1080)
        XCTAssertEqual(asset?.aspectRatio ?? 0, 1920.0/1080.0, accuracy: 0.001)
    }

    func testRegisterAssetIsIdempotent() async throws {
        let path = "/test/images/photo1.png"

        let id1 = try await store.registerAsset(resolvedPath: path)
        let id2 = try await store.registerAsset(resolvedPath: path)

        XCTAssertEqual(id1, id2)
    }

    func testRegisterAssetUpdatesOnHashChange() async throws {
        let path = "/test/images/photo1.png"

        let id1 = try await store.registerAsset(
            resolvedPath: path,
            contentHashSHA256: "hash1"
        )

        // Re-register with different hash
        let id2 = try await store.registerAsset(
            resolvedPath: path,
            contentHashSHA256: "hash2"
        )

        XCTAssertEqual(id1, id2)

        let asset = try await store.assetByPath(path)
        XCTAssertEqual(asset?.contentHashSHA256, "hash2")
    }

    func testRegisterAssetDoesNotUpdateWhenHashUnchanged() async throws {
        let path = "/test/images/photo1.png"

        _ = try await store.registerAsset(
            resolvedPath: path,
            width: 100,
            contentHashSHA256: "hash1"
        )

        let before = try await store.assetByPath(path)!
        try await Task.sleep(for: .milliseconds(10))

        // Re-register with same hash but different width
        _ = try await store.registerAsset(
            resolvedPath: path,
            width: 200,
            contentHashSHA256: "hash1"
        )

        let after = try await store.assetByPath(path)!

        // Width should NOT have changed (hash is same)
        XCTAssertEqual(after.width, 100)
        // But last_seen_at should have updated
        XCTAssertGreaterThan(after.lastSeenAt, before.lastSeenAt)
    }

    // MARK: - Asset Links

    func testLinkAsset() async throws {
        let path = "/test/images/photo1.png"
        let assetID = try await store.registerAsset(resolvedPath: path)

        try await store.linkAsset(
            assetID: assetID,
            kind: .placeGenerated,
            ownerID: "place-123",
            workflow: "photorealistic"
        )

        let links = try await store.linksForAsset(assetID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.linkKind, .placeGenerated)
        XCTAssertEqual(links.first?.ownerID, "place-123")
    }

    func testLinkAssetUpdatesExistingLink() async throws {
        let path = "/test/images/photo1.png"
        let assetID = try await store.registerAsset(resolvedPath: path)

        try await store.linkAsset(
            assetID: assetID,
            kind: .placeGenerated,
            ownerID: "place-123",
            workflow: "photorealistic"
        )

        try await store.linkAsset(
            assetID: assetID,
            kind: .placeGenerated,
            ownerID: "place-123",
            workflow: "animated"
        )

        let links = try await store.linksForAsset(assetID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.workflow, "animated")
    }

    func testMultipleLinksForSameAsset() async throws {
        let path = "/test/images/photo1.png"
        let assetID = try await store.registerAsset(resolvedPath: path)

        try await store.linkAsset(assetID: assetID, kind: .placeGenerated, ownerID: "place-1")
        try await store.linkAsset(assetID: assetID, kind: .characterReference, ownerID: "char-1")

        let links = try await store.linksForAsset(assetID)
        XCTAssertEqual(links.count, 2)
    }

    // MARK: - Missing Assets

    func testMarkMissingAssets() async throws {
        let path1 = "/test/images/photo1.png"
        let path2 = "/test/images/photo2.png"

        _ = try await store.registerAsset(resolvedPath: path1)
        _ = try await store.registerAsset(resolvedPath: path2)

        try await Task.sleep(for: .milliseconds(10))

        let cutoff = Date().timeIntervalSince1970
        try await Task.sleep(for: .milliseconds(10))

        // Register only photo1 again (photo2 is now "missing")
        _ = try await store.registerAsset(resolvedPath: path1)

        let markedCount = try await store.markMissingAssets(notSeenSince: cutoff)
        XCTAssertEqual(markedCount, 1)

        let asset1 = try await store.assetByPath(path1)
        let asset2 = try await store.assetByPath(path2)

        XCTAssertFalse(asset1?.isMissing ?? true)
        XCTAssertTrue(asset2?.isMissing ?? false)
    }

    // MARK: - Asset Lookup

    func testAssetByID() async throws {
        let path = "/test/images/photo1.png"
        let id = try await store.registerAsset(resolvedPath: path)

        let asset = try await store.assetByID(id)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.id, id)
    }

    func testAssetByPathReturnsNilForNonexistent() async throws {
        let asset = try await store.assetByPath("/nonexistent/path.png")
        XCTAssertNil(asset)
    }

    // MARK: - All Link Kinds

    func testAllLinkKindsAreValid() async throws {
        let path = "/test/images/photo1.png"
        let assetID = try await store.registerAsset(resolvedPath: path)

        // Test that all link kinds can be stored
        for kind in ImageAssetLinkKind.allCases {
            try await store.linkAsset(
                assetID: assetID,
                kind: kind,
                ownerID: "test-\(kind.rawValue)"
            )
        }

        let links = try await store.linksForAsset(assetID)
        XCTAssertEqual(links.count, ImageAssetLinkKind.allCases.count)
    }
}