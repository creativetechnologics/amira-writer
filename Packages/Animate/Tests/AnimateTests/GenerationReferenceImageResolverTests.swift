import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class GenerationReferenceImageResolverTests: XCTestCase {
    func testResolvesContinuityReferenceDetails() throws {
        let projectRoot = try makeTemporaryProjectRoot()
        let canvasDir = projectRoot.appendingPathComponent("Animate/Canvas", isDirectory: true)
        let mapURL = projectRoot.appendingPathComponent("Animate/reference-map.png")
        let candidateURL = canvasDir.appendingPathComponent("candidate.png")
        try FileManager.default.createDirectory(at: canvasDir, withIntermediateDirectories: true)
        try Data("map".utf8).write(to: mapURL)
        try Data("candidate".utf8).write(to: candidateURL)

        try writeJSON(
            [
                "referenceDetails": [
                    ["path": "Animate/reference-map.png", "role": "spatial_map", "label": "Master map"]
                ],
                "referencePaths": ["Animate/reference-map.png"]
            ],
            to: candidateURL.deletingPathExtension().appendingPathExtension("continuity.json")
        )

        let items = GenerationReferenceImageResolver.referenceItems(
            forImagePath: candidateURL.path,
            projectRoot: projectRoot
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.resolvedPath, mapURL.path)
        XCTAssertEqual(items.first?.role, "spatial_map")
        XCTAssertEqual(items.first?.label, "Master map")
    }

    func testResolvesShotPlanSourceImageAndReferenceImagePaths() throws {
        let projectRoot = try makeTemporaryProjectRoot()
        let shotDir = projectRoot.appendingPathComponent("Animate/generated-frames", isDirectory: true)
        let generatedURL = shotDir.appendingPathComponent("generated.png")
        let editSourceURL = projectRoot.appendingPathComponent("Animate/source-frame.png")
        let characterURL = projectRoot.appendingPathComponent("Characters/johnny/ref.png")
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: characterURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: generatedURL)
        try Data("edit".utf8).write(to: editSourceURL)
        try Data("character".utf8).write(to: characterURL)

        try writeJSON(
            [
                "sourceImage": [
                    "path": "Animate/source-frame.png",
                    "source": "previousApprovedFrame"
                ],
                "referenceImagePaths": [
                    "Characters/johnny/ref.png"
                ]
            ],
            to: generatedURL.deletingPathExtension().appendingPathExtension("plan.json")
        )

        let items = GenerationReferenceImageResolver.referenceItems(
            forImagePath: generatedURL.path,
            projectRoot: projectRoot
        )

        XCTAssertEqual(items.map(\.resolvedPath), [editSourceURL.path, characterURL.path])
        XCTAssertEqual(items.first?.role, "edit_source")
    }

    private func makeTemporaryProjectRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GenerationReferenceImageResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
