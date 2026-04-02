import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class Animate3DRegistryBundleServiceTests: XCTestCase {
    func testRegistryBundleProvidesOutOfBandPaths() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let customModelPath = "Animate/3d/generated-assets/luke/default/luke.glb"
        let customFaceRigPath = "Animate/3d/generated-assets/luke/default/face.json"
        let customMouthPath = "Animate/3d/generated-assets/luke/default/mouth.json"
        let customExpressionPath = "Animate/3d/generated-assets/luke/default/expressions.json"
        let customMotionPath = "Animate/3d/generated-assets/luke/default/motions/idle.json"
        let customMaterialPath = "Animate/3d/generated-assets/luke/default/lookdev.json"

        try createDataFile(Data(), at: projectURL.appendingPathComponent(customModelPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(customFaceRigPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(customMouthPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(customExpressionPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(customMotionPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(customMaterialPath))

        let service = Animate3DRegistryBundleService(
            projectURL: projectURL,
            animateURL: projectURL.appendingPathComponent("Animate"),
            assetRegistry: Animate3DAssetRegistry(),
            characterRegistry: Animate3DCharacterRegistry(
                bundles: [
                    Animate3DCharacterBundleDescriptor(
                        characterSlug: "luke",
                        costumeName: "default",
                        bodyModelPath: customModelPath,
                        faceRigPath: customFaceRigPath,
                        mouthProfilePath: customMouthPath,
                        expressionLibraryPath: customExpressionPath,
                        motionSetPaths: [customMotionPath],
                        materialProfilePath: customMaterialPath
                    )
                ]
            )
        )

        XCTAssertTrue(service.provides(.models, for: "luke"))
        XCTAssertTrue(service.provides(.faceRigs, for: "luke"))
        XCTAssertTrue(service.provides(.mouthProfiles, for: "luke"))
        XCTAssertTrue(service.provides(.expressions, for: "luke"))
        XCTAssertTrue(service.provides(.motions, for: "luke"))
        XCTAssertTrue(service.provides(.materials, for: "luke"))
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DRegistryBundleServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDataFile(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
