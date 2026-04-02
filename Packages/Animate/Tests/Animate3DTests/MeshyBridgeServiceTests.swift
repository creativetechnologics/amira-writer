import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class MeshyBridgeServiceTests: XCTestCase {

    func testNeedsMeshyConversion() {
        XCTAssertTrue(MeshyBridgeService.needsMeshyConversion("bodyModel"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("faceRig"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("mouthProfile"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("expressionLibrary"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("motionSet"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("materialProfile"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("worldChunk"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("worldMesh"))
        XCTAssertFalse(MeshyBridgeService.needsMeshyConversion("lightRig"))
    }

    func testBridgeJobCreation() {
        let job = MeshyBridgeService.BridgeJob(
            characterID: UUID(),
            characterSlug: "luke",
            costumeName: "military-medic",
            sourceImagePaths: ["/tmp/front.png", "/tmp/side.png"],
            meshyConfig: MeshyMultiImageRequest(
                imageURLs: [],
                targetPolycount: 100_000,
                targetFormats: ["glb", "usdz"]
            )
        )

        XCTAssertEqual(job.characterSlug, "luke")
        XCTAssertEqual(job.costumeName, "military-medic")
        XCTAssertEqual(job.sourceImagePaths.count, 2)
        XCTAssertEqual(job.meshyConfig.targetPolycount, 100_000)
    }
}
