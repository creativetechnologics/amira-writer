import Foundation
import XCTest
import SceneKit
@testable import AnimateUI

@available(macOS 26.0, *)
final class FBXMotionClipLoaderTests: XCTestCase {

    func testSMPLHJointCount() {
        XCTAssertEqual(FBXMotionClipLoader.smplhJointNames.count, 22)
    }

    func testJointNameMappingCoversAllSMPLH() {
        for joint in FBXMotionClipLoader.smplhJointNames {
            XCTAssertNotNil(
                FBXMotionClipLoader.jointNameMapping[joint],
                "Missing mapping for SMPL-H joint: \(joint)"
            )
        }
    }

    func testMotionClipSampleClampsToRange() {
        let frame0 = FBXMotionClipLoader.MotionFrame(
            frame: 0,
            rootPosition: .zero,
            rootRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            jointRotations: [:]
        )
        let frame1 = FBXMotionClipLoader.MotionFrame(
            frame: 1,
            rootPosition: SIMD3<Float>(1, 0, 0),
            rootRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            jointRotations: [:]
        )

        let clip = FBXMotionClipLoader.MotionClip(
            name: "test",
            sourceURL: URL(fileURLWithPath: "/tmp/test.fbx"),
            fps: 30,
            frameCount: 2,
            duration: 1.0 / 30.0,
            frames: [frame0, frame1],
            jointNames: []
        )

        // Sample before start should clamp to frame 0
        let before = clip.sample(at: -1.0)
        XCTAssertNotNil(before)
        XCTAssertEqual(before?.rootPosition.x ?? 999, 0, accuracy: 0.01)

        // Sample after end should clamp to last frame
        let after = clip.sample(at: 999.0)
        XCTAssertNotNil(after)
        XCTAssertEqual(after?.rootPosition.x ?? 0, 1, accuracy: 0.01)
    }

    func testBuildRetargetMapFindsNodes() {
        let root = SCNNode()
        let hips = SCNNode()
        hips.name = "Hips"
        let spine = SCNNode()
        spine.name = "Spine"
        let head = SCNNode()
        head.name = "Head"

        root.addChildNode(hips)
        hips.addChildNode(spine)
        spine.addChildNode(head)

        let map = FBXMotionClipLoader.buildRetargetMap(targetRoot: root)

        XCTAssertEqual(map["Pelvis"], "Hips")
        XCTAssertEqual(map["Head"], "Head")
        XCTAssertEqual(map["Spine1"], "Spine")
    }

    func testRetargetMapHandlesMixamoPrefix() {
        let root = SCNNode()
        let hips = SCNNode()
        hips.name = "mixamorig:Hips"
        root.addChildNode(hips)

        let map = FBXMotionClipLoader.buildRetargetMap(targetRoot: root)
        XCTAssertEqual(map["Pelvis"], "mixamorig:Hips")
    }

    func testEmptyClipSampleReturnsNil() {
        let clip = FBXMotionClipLoader.MotionClip(
            name: "empty",
            sourceURL: URL(fileURLWithPath: "/tmp/empty.fbx"),
            fps: 30,
            frameCount: 0,
            duration: 0,
            frames: [],
            jointNames: []
        )
        XCTAssertNil(clip.sample(at: 0))
    }
}
