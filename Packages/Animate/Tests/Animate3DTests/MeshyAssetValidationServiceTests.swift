import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class MeshyAssetValidationServiceTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshyValidationTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testEmptyDirectoryReturnsNoResults() {
        let results = MeshyAssetValidationService.validate(assetDirectory: tempDir)
        XCTAssertTrue(results.isEmpty)
    }

    func testEmptyFileReportsInvalid() throws {
        let glbPath = tempDir.appendingPathComponent("model.glb")
        try Data().write(to: glbPath)

        let results = MeshyAssetValidationService.validate(assetDirectory: tempDir)
        XCTAssertEqual(results.count, 1)

        if case .invalid(let reason) = results["glb"] {
            XCTAssertTrue(reason.contains("empty"))
        } else {
            XCTFail("Expected invalid result for empty file")
        }
    }

    func testValidGLBHeader() throws {
        let glbPath = tempDir.appendingPathComponent("model.glb")
        // GLB header: "glTF" + version 2 + length + padding to get past size check
        var data = Data("glTF".utf8)
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // version 2
        data.append(Data(repeating: 0x00, count: 100_000)) // padding to pass size checks
        try data.write(to: glbPath)

        let results = MeshyAssetValidationService.validate(assetDirectory: tempDir)
        if case .valid(let report) = results["glb"] {
            XCTAssertEqual(report.format, "glb")
            XCTAssertTrue(report.fileSize > 0)
        } else {
            XCTFail("Expected valid GLB")
        }
    }

    func testSummaryFormatting() {
        let report = MeshyAssetValidationService.MeshValidationReport(
            fileSize: 1_000_000, format: "glb", hasTextures: true,
            thumbnailExists: true, metadataExists: true
        )
        let results: [String: MeshyAssetValidationService.ValidationResult] = [
            "glb": .valid(report),
            "fbx": .invalid("Bad header")
        ]

        let summary = MeshyAssetValidationService.summary(for: results)
        XCTAssertTrue(summary.contains("1 valid"))
        XCTAssertTrue(summary.contains("1 invalid"))
    }
}
