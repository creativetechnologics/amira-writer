import XCTest
import ProjectKit
@testable import WriteUI

@available(macOS 26.0, *)
@MainActor
final class WriteObsidianSyncServiceTests: XCTestCase {

    private var cleanupDirs: [URL] = []

    override func tearDown() async throws {
        for dir in cleanupDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        cleanupDirs.removeAll()
    }

    // MARK: - Diagnostic: verify date manipulation works

    func test_diagnostic_date_manipulation() throws {
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.txt")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "content".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 500)],
            ofItemAtPath: file.path
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let modDate = attrs[.modificationDate] as? Date
        XCTAssertNotNil(modDate, "modificationDate should not be nil")
        if let d = modDate {
            let diff = d.timeIntervalSince1970
            XCTAssertEqual(diff, 500, accuracy: 1.0, "Should be ~500, got \(diff)")
        }
    }

    func test_diagnostic_enumerate_sees_correct_dates() throws {
        let (src, dst, svc) = try makeService()
        defer { svc.stop() }

        try write("src content", to: src, dateOffset: 100)
        try write("dst content", to: dst, dateOffset: 0)

        let svcSource = svc.enumerateForTesting(url: svc.sourceURL)
        let svcDest = svc.enumerateForTesting(url: svc.destinationURL)
        XCTAssertEqual(svcSource.count, 1)
        XCTAssertEqual(svcDest.count, 1)
        XCTAssertEqual(svcSource[0].relPath, "scene-alpha.md")
        XCTAssertGreaterThan(svcSource[0].date, svcDest[0].date, "src must be newer")
    }

    // MARK: - Newer timestamp always wins

    func test_source_newer_propagates_to_dest() throws {
        let (src, dst, svc) = try makeService()
        defer { svc.stop() }

        try write("hello from source", to: src, dateOffset: 100)
        try write("hello from dest", to: dst, dateOffset: 0)

        svc.syncNow()

        XCTAssertEqual(try String(contentsOf: src), "hello from source", "source must keep its content")
        XCTAssertEqual(try String(contentsOf: dst), "hello from source", "dest must receive source content")
    }

    func test_dest_newer_propagates_to_source() throws {
        let (src, dst, svc) = try makeService()
        defer { svc.stop() }

        try write("hello from source", to: src, dateOffset: 0)
        try write("hello from dest", to: dst, dateOffset: 100)

        svc.syncNow()

        XCTAssertEqual(try String(contentsOf: dst), "hello from dest", "dest must keep its content")
        XCTAssertEqual(try String(contentsOf: src), "hello from dest", "source must receive dest content")
    }

    // MARK: - Equal timestamps = no divergence, both sides keep their content

    func test_equal_timestamps_preserves_both_sides() throws {
        let (src, dst, svc) = try makeService()
        defer { svc.stop() }

        try write("source content", to: src, dateOffset: 0)
        try write("dest content", to: dst, dateOffset: 0)

        svc.syncNow()

        XCTAssertEqual(try String(contentsOf: src), "source content", "source must keep original content")
        XCTAssertEqual(try String(contentsOf: dst), "dest content", "dest must keep original content")
    }

    // MARK: - New files propagate in both directions

    func test_new_file_in_source_copied_to_dest() throws {
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let srcDir = tmp.appendingPathComponent("source/Write")
        let dstDir = tmp.appendingPathComponent("dest/Write")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let svc = WriteObsidianSyncService(sourceURL: srcDir, destinationURL: dstDir)
        defer { svc.stop() }

        // Write only to source — dest has no file yet
        try write("brand new source file", to: srcDir.appendingPathComponent("new-file.md"), dateOffset: 100)

        svc.syncNow()

        let destFile = dstDir.appendingPathComponent("new-file.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path), "dest must get the new file")
        XCTAssertEqual(try String(contentsOf: destFile), "brand new source file")
    }

    func test_new_file_in_dest_copied_to_source() throws {
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let srcDir = tmp.appendingPathComponent("source/Write")
        let dstDir = tmp.appendingPathComponent("dest/Write")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let svc = WriteObsidianSyncService(sourceURL: srcDir, destinationURL: dstDir)
        defer { svc.stop() }

        // Write only to dest — source has no file yet
        try write("brand new dest file", to: dstDir.appendingPathComponent("new-file.md"), dateOffset: 100)

        svc.syncNow()

        let sourceFile = srcDir.appendingPathComponent("new-file.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path), "source must get the new file")
        XCTAssertEqual(try String(contentsOf: sourceFile), "brand new dest file")
    }

    // MARK: - Deeply nested files

    func test_nested_file_syncs_both_directions() throws {
        let (src, dst, svc) = try makeService()
        defer { svc.stop() }

        let nestedSrc = src.deletingLastPathComponent().appendingPathComponent("sub/deep/file.md")
        let nestedDst = dst.deletingLastPathComponent().appendingPathComponent("sub/deep/file.md")

        try write("nested source", to: nestedSrc, dateOffset: 50)
        try write("nested dest", to: nestedDst, dateOffset: 0)

        svc.syncNow()

        XCTAssertEqual(try String(contentsOf: nestedSrc), "nested source")
        let nestedDestContent = try String(contentsOf: nestedDst)
        XCTAssertEqual(nestedDestContent, "nested source", "dest nested file must be overwritten")
    }

    // MARK: - Idempotency: already-synced files do not flip-flop

    func test_already_synced_files_remain_stable() throws {
        let (src, dst, svc) = try makeService()
        defer { svc.stop() }

        try write("same content", to: src, dateOffset: 100)
        try write("same content", to: dst, dateOffset: 100)

        svc.syncNow()
        svc.syncNow()
        svc.syncNow()

        XCTAssertEqual(try String(contentsOf: src), "same content")
        XCTAssertEqual(try String(contentsOf: dst), "same content")
    }

    // MARK: - Helpers

    private func tmpDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianSyncTest-\(UUID().uuidString)")
    }

    private func makeService() throws -> (sourceFile: URL, destFile: URL, service: WriteObsidianSyncService) {
        let tmp = tmpDir()
        let src = tmp.appendingPathComponent("source/Write")
        let dst = tmp.appendingPathComponent("dest/Write")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let svc = WriteObsidianSyncService(sourceURL: src, destinationURL: dst)
        cleanupDirs.append(tmp)
        return (src.appendingPathComponent("scene-alpha.md"),
                dst.appendingPathComponent("scene-alpha.md"),
                svc)
    }

    /// Write text to a file, setting its modification date to `referenceDate + dateOffset`.
    /// Write text to a file, setting its modification date to `referenceDate + dateOffset`.
    /// Uses `setResourceValues` (modern API) instead of deprecated `setAttributes`.
    private func write(_ text: String, to url: URL, dateOffset: TimeInterval) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        var resourceValues = URLResourceValues()
        resourceValues.contentModificationDate = referenceDate.addingTimeInterval(dateOffset)
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    /// Fixed reference point so timestamps are deterministic across runs.
    private let referenceDate = Date(timeIntervalSince1970: 1_000_000_000)
}
