import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class SceneAssetPipelineRegistryTests: XCTestCase {
    func testCharacterRegistryProvidesModelFileNameAndPerformanceProfile() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let profile = Character3DPerformanceProfile(
            headNodeName: "Head",
            faceNodeName: "Face",
            jawNodeName: "Jaw",
            mouthNodeName: "Mouth",
            leftEyeNodeName: "Eye_L",
            rightEyeNodeName: "Eye_R",
            leftBrowNodeName: "Brow_L",
            rightBrowNodeName: "Brow_R",
            mouthProfileID: "default-mouth"
        )

        let faceRigPath = "Animate/characters/luke/face-rigs/performance-profile.json"
        try createJSONFile(profile, at: projectURL.appendingPathComponent(faceRigPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent("Animate/characters/luke/models/luke.glb"))

        let characterRegistry = Animate3DCharacterRegistry(
            bundles: [
                Animate3DCharacterBundleDescriptor(
                    characterSlug: "luke",
                    costumeName: "default",
                    bodyModelPath: "Animate/characters/luke/models/luke.glb",
                    faceRigPath: faceRigPath,
                    mouthProfilePath: nil,
                    expressionLibraryPath: nil,
                    motionSetPaths: ["Animate/characters/luke/motions/idle.json"],
                    materialProfilePath: "Animate/characters/luke/materials/lookdev.json"
                )
            ]
        )
        try ProjectDatabaseBridge.saveAnimate3DCharacterRegistryToDisk(characterRegistry, projectURL: projectURL)

        let store = AnimateStore()
        store.owpURL = projectURL
        store.characters = [
            AnimationCharacter(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "Luke",
                description: "Pilot",
                owpSlug: "luke",
                parts: []
            )
        ]

        let pipeline = SceneAssetPipeline(store: store)

        XCTAssertEqual(pipeline.characterModelFileName(slug: "luke"), "luke.glb")
        XCTAssertEqual(pipeline.characterPerformanceProfileSourceRelativePath(slug: "luke"), faceRigPath)
        XCTAssertEqual(pipeline.loadCharacterPerformanceProfile(slug: "luke"), profile)
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneAssetPipelineRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createJSONFile<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    private func createDataFile(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
