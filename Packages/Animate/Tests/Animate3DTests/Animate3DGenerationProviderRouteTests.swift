import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class Animate3DGenerationProviderRouteTests: XCTestCase {

    func testDefaultRoutes() {
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "bodyModel"), .meshy)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "faceRig"), .geminiOnly)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "mouthProfile"), .geminiOnly)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "expressionLibrary"), .geminiOnly)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "motionSet"), .geminiOnly)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "materialProfile"), .geminiOnly)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "worldChunk"), .externalImport)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "worldMesh"), .externalImport)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "worldPreviewImage"), .geminiOnly)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "styleProfile"), .inAppConfig)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "cameraPresetLibrary"), .inAppConfig)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "lightRig"), .inAppConfig)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "atmospherePreset"), .inAppConfig)
        XCTAssertEqual(Animate3DGenerationProviderRoute.defaultRoute(for: "unknown"), .manual)
    }

    func testAutomatableRoutes() {
        XCTAssertTrue(Animate3DGenerationProviderRoute.meshy.isAutomatable)
        XCTAssertTrue(Animate3DGenerationProviderRoute.geminiOnly.isAutomatable)
        XCTAssertFalse(Animate3DGenerationProviderRoute.externalImport.isAutomatable)
        XCTAssertFalse(Animate3DGenerationProviderRoute.inAppConfig.isAutomatable)
        XCTAssertFalse(Animate3DGenerationProviderRoute.manual.isAutomatable)
    }

    func testMeshyCredits() {
        XCTAssertEqual(Animate3DGenerationProviderRoute.meshy.estimatedMeshyCredits, 30)
        XCTAssertNil(Animate3DGenerationProviderRoute.geminiOnly.estimatedMeshyCredits)
        XCTAssertNil(Animate3DGenerationProviderRoute.externalImport.estimatedMeshyCredits)
    }

    func testCodableRoundTrip() throws {
        let route = Animate3DGenerationProviderRoute.meshy
        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(Animate3DGenerationProviderRoute.self, from: data)
        XCTAssertEqual(decoded, .meshy)
    }
}
