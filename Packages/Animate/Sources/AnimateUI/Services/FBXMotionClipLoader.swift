import Foundation
import SceneKit
import ModelIO

/// Loads FBX/DAE motion clips and extracts joint animation data for SceneKit playback
@available(macOS 26.0, *)
struct FBXMotionClipLoader: Sendable {

    /// A single frame of joint transforms extracted from a motion clip
    struct MotionFrame: Sendable {
        let frame: Int
        let rootPosition: SIMD3<Float>
        let rootRotation: simd_quatf
        let jointRotations: [String: simd_quatf]  // joint name → rotation
    }

    /// A loaded motion clip ready for playback
    struct MotionClip: Sendable {
        let name: String
        let sourceURL: URL
        let fps: Double
        let frameCount: Int
        let duration: TimeInterval
        let frames: [MotionFrame]
        let jointNames: [String]

        /// Get the interpolated motion state at a fractional frame
        func sample(at time: TimeInterval) -> MotionFrame? {
            guard !frames.isEmpty, duration > 0 else { return nil }
            let normalizedTime = max(0, min(duration, time))
            let frameIndex = normalizedTime / duration * Double(frameCount - 1)
            let lowFrame = Int(frameIndex)
            let highFrame = min(lowFrame + 1, frameCount - 1)
            let t = Float(frameIndex - Double(lowFrame))

            guard lowFrame < frames.count, highFrame < frames.count else { return nil }
            let a = frames[lowFrame]
            let b = frames[highFrame]

            // Interpolate root
            let pos = a.rootPosition + (b.rootPosition - a.rootPosition) * t
            let rot = simd_slerp(a.rootRotation, b.rootRotation, t)

            // Interpolate joints
            var joints: [String: simd_quatf] = [:]
            for name in jointNames {
                if let ra = a.jointRotations[name], let rb = b.jointRotations[name] {
                    joints[name] = simd_slerp(ra, rb, t)
                } else if let ra = a.jointRotations[name] {
                    joints[name] = ra
                }
            }

            return MotionFrame(
                frame: lowFrame,
                rootPosition: pos,
                rootRotation: rot,
                jointRotations: joints
            )
        }
    }

    // MARK: - SMPL-H Joint Mapping

    /// Standard SMPL-H joint names (22 body joints, excluding hands)
    static let smplhJointNames: [String] = [
        "Pelvis", "L_Hip", "R_Hip", "Spine1", "L_Knee", "R_Knee",
        "Spine2", "L_Ankle", "R_Ankle", "Spine3", "L_Foot", "R_Foot",
        "Neck", "L_Collar", "R_Collar", "Head", "L_Shoulder", "R_Shoulder",
        "L_Elbow", "R_Elbow", "L_Wrist", "R_Wrist"
    ]

    /// Map SMPL-H joint names to common SceneKit/Mixamo joint names
    static let jointNameMapping: [String: [String]] = [
        "Pelvis": ["Hips", "pelvis", "root", "mixamorig:Hips"],
        "L_Hip": ["LeftUpLeg", "left_hip", "mixamorig:LeftUpLeg"],
        "R_Hip": ["RightUpLeg", "right_hip", "mixamorig:RightUpLeg"],
        "Spine1": ["Spine", "spine1", "mixamorig:Spine"],
        "L_Knee": ["LeftLeg", "left_knee", "mixamorig:LeftLeg"],
        "R_Knee": ["RightLeg", "right_knee", "mixamorig:RightLeg"],
        "Spine2": ["Spine1", "spine2", "mixamorig:Spine1"],
        "L_Ankle": ["LeftFoot", "left_ankle", "mixamorig:LeftFoot"],
        "R_Ankle": ["RightFoot", "right_ankle", "mixamorig:RightFoot"],
        "Spine3": ["Spine2", "spine3", "chest", "mixamorig:Spine2"],
        "L_Foot": ["LeftToeBase", "left_foot", "mixamorig:LeftToeBase"],
        "R_Foot": ["RightToeBase", "right_foot", "mixamorig:RightToeBase"],
        "Neck": ["Neck", "neck", "mixamorig:Neck"],
        "L_Collar": ["LeftShoulder", "left_collar", "mixamorig:LeftShoulder"],
        "R_Collar": ["RightShoulder", "right_collar", "mixamorig:RightShoulder"],
        "Head": ["Head", "head", "mixamorig:Head"],
        "L_Shoulder": ["LeftArm", "left_shoulder", "mixamorig:LeftArm"],
        "R_Shoulder": ["RightArm", "right_shoulder", "mixamorig:RightArm"],
        "L_Elbow": ["LeftForeArm", "left_elbow", "mixamorig:LeftForeArm"],
        "R_Elbow": ["RightForeArm", "right_elbow", "mixamorig:RightForeArm"],
        "L_Wrist": ["LeftHand", "left_wrist", "mixamorig:LeftHand"],
        "R_Wrist": ["RightHand", "right_wrist", "mixamorig:RightHand"]
    ]

    // MARK: - Loading

    /// Load a motion clip from an FBX, DAE, or USDZ file
    /// Uses ModelIO to extract animation data, then converts to our MotionClip format
    static func load(from url: URL) throws -> MotionClip {
        let scnScene = try SCNScene(url: url)

        // Find the animation duration and frame count
        var maxDuration: TimeInterval = 0

        scnScene.rootNode.enumerateChildNodes({ node, _ in
            for key in node.animationKeys {
                if let player = node.animationPlayer(forKey: key) {
                    maxDuration = max(maxDuration, player.animation.duration)
                }
            }
        })

        // If no animations found, create a single-frame static pose
        guard maxDuration > 0 else {
            let staticFrame = extractStaticPose(from: scnScene.rootNode)
            return MotionClip(
                name: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                fps: 30,
                frameCount: 1,
                duration: 0,
                frames: [staticFrame],
                jointNames: Array(staticFrame.jointRotations.keys)
            )
        }

        // Use an offscreen SCNRenderer to evaluate animations at arbitrary times
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scnScene

        // Sample the animation at 30fps
        let fps: Double = 30
        let frameCount = Int(ceil(maxDuration * fps))
        var frames: [MotionFrame] = []
        var discoveredJoints: Set<String> = []

        for i in 0..<frameCount {
            let time = Double(i) / fps
            // Advance SceneKit's animation clock so joint transforms update.
            // snapshot(atTime:) takes the correct viewport-aware code path on Metal-backed
            // SCNRenderer (unlike render(atTime:) which requires a viewport to be set).
            _ = renderer.snapshot(atTime: time, with: CGSize(width: 1, height: 1), antialiasingMode: .none)
            let frame = sampleScene(scnScene.rootNode, at: time, frameIndex: i)
            discoveredJoints.formUnion(frame.jointRotations.keys)
            frames.append(frame)
        }

        return MotionClip(
            name: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            fps: fps,
            frameCount: frameCount,
            duration: maxDuration,
            frames: frames,
            jointNames: Array(discoveredJoints).sorted()
        )
    }

    /// Extract a static pose from a scene node hierarchy
    private static func extractStaticPose(from rootNode: SCNNode) -> MotionFrame {
        var joints: [String: simd_quatf] = [:]

        rootNode.enumerateChildNodes({ node, _ in
            if let name = node.name, !name.isEmpty {
                joints[name] = node.simdOrientation
            }
        })

        return MotionFrame(
            frame: 0,
            rootPosition: rootNode.simdPosition,
            rootRotation: rootNode.simdOrientation,
            jointRotations: joints
        )
    }

    /// Sample all joint transforms at a specific time
    private static func sampleScene(_ rootNode: SCNNode, at time: TimeInterval, frameIndex: Int) -> MotionFrame {
        var joints: [String: simd_quatf] = [:]
        var rootPos = SIMD3<Float>.zero
        var rootRot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        rootNode.enumerateChildNodes({ node, _ in
            guard let name = node.name, !name.isEmpty else { return }

            // Check if this is a root/pelvis joint
            let lowerName = name.lowercased()
            if lowerName.contains("hips") || lowerName.contains("pelvis") || lowerName.contains("root") {
                rootPos = node.simdWorldPosition
                rootRot = node.simdWorldOrientation
            }

            joints[name] = node.simdOrientation
        })

        return MotionFrame(
            frame: frameIndex,
            rootPosition: rootPos,
            rootRotation: rootRot,
            jointRotations: joints
        )
    }

    // MARK: - Retargeting

    /// Find the best matching joint in a target node hierarchy for each SMPL-H joint
    static func buildRetargetMap(targetRoot: SCNNode) -> [String: String] {
        var targetJointNames: [String] = []
        targetRoot.enumerateChildNodes({ node, _ in
            if let name = node.name, !name.isEmpty {
                targetJointNames.append(name)
            }
        })

        var mapping: [String: String] = [:]

        // Build a lowercased lookup for O(1) exact matching (avoids .contains() substring
        // collisions like "Spine" matching "Spine1")
        let lowerToOriginal = Dictionary(targetJointNames.map { ($0.lowercased(), $0) },
                                         uniquingKeysWith: { first, _ in first })

        for (smplJoint, candidates) in jointNameMapping {
            for candidate in candidates {
                if let match = lowerToOriginal[candidate.lowercased()] {
                    mapping[smplJoint] = match
                    break
                }
            }
        }

        return mapping
    }

    /// Pre-resolved node references for per-frame performance.
    /// Build once with `buildNodeCache`, then pass to `apply()` every frame.
    typealias NodeCache = [String: SCNNode]

    /// Walk the target hierarchy once and resolve every retarget-mapped joint to its SCNNode.
    static func buildNodeCache(targetRoot: SCNNode, retargetMap: [String: String]) -> NodeCache {
        var cache: NodeCache = [:]
        for (smplJoint, targetName) in retargetMap {
            if let node = targetRoot.childNode(withName: targetName, recursively: true) {
                cache[smplJoint] = node
            }
        }
        return cache
    }

    /// Apply a motion frame using a pre-built node cache (O(joints) with no tree walks).
    static func apply(
        frame: MotionFrame,
        nodeCache: NodeCache,
        rootPositionScale: Float = 1.0
    ) {
        if let pelvisNode = nodeCache["Pelvis"] {
            pelvisNode.simdPosition = frame.rootPosition * rootPositionScale
            pelvisNode.simdOrientation = frame.rootRotation
        }

        for (smplJoint, rotation) in frame.jointRotations {
            if let targetNode = nodeCache[smplJoint] {
                targetNode.simdOrientation = rotation
            }
        }
    }

    /// Convenience: apply without a cache (walks the tree each call — use for one-off poses).
    static func apply(
        frame: MotionFrame,
        to targetRoot: SCNNode,
        retargetMap: [String: String],
        rootPositionScale: Float = 1.0
    ) {
        let cache = buildNodeCache(targetRoot: targetRoot, retargetMap: retargetMap)
        apply(frame: frame, nodeCache: cache, rootPositionScale: rootPositionScale)
    }

    // MARK: - Conversion to NLA MotionClip

    /// Convert an FBX-loaded MotionClip into the NLA-compatible AnimateUI.MotionClip format.
    /// Reuses the SMPL-H joint name mapping to normalize all joint names to the
    /// standard skeleton used by the NLA pipeline.
    static func toNLAMotionClip(
        from fbxClip: FBXMotionClipLoader.MotionClip,
        source: MotionClipSource
    ) -> AnimateUI.MotionClip {
        // Build reverse mapping: any FBX joint name -> canonical SMPL-H name
        var fbxToCanonical: [String: String] = [:]
        for (canonical, variants) in jointNameMapping {
            for variant in variants {
                fbxToCanonical[variant] = canonical
                fbxToCanonical[variant.lowercased()] = canonical
            }
            fbxToCanonical[canonical] = canonical
        }

        // Collect all canonical joint names across all frames
        var allCanonicalJoints: Set<String> = []
        for fbxFrame in fbxClip.frames {
            for jointName in fbxFrame.jointRotations.keys {
                let canonical = fbxToCanonical[jointName]
                    ?? fbxToCanonical[jointName.lowercased()]
                    ?? jointName
                allCanonicalJoints.insert(canonical)
            }
        }
        let sortedJoints = allCanonicalJoints.sorted()

        // Build per-joint arrays of quaternions (SIMD4: x=ix, y=iy, z=iz, w=r)
        var jointRotations: [String: [SIMD4<Float>]] = [:]
        var rootPositions: [SIMD3<Float>] = []

        for jointName in sortedJoints {
            jointRotations[jointName] = Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: fbxClip.frameCount)
        }

        for (frameIdx, fbxFrame) in fbxClip.frames.enumerated() {
            rootPositions.append(fbxFrame.rootPosition)
            for (jointName, rotation) in fbxFrame.jointRotations {
                let canonical = fbxToCanonical[jointName]
                    ?? fbxToCanonical[jointName.lowercased()]
                    ?? jointName
                if jointRotations[canonical] != nil {
                    let q = rotation
                    jointRotations[canonical]![frameIdx] = SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real)
                }
            }
        }

        let intFPS = Int(fbxClip.fps.rounded())
        return AnimateUI.MotionClip(
            id: UUID(),
            name: fbxClip.name,
            source: source,
            fps: intFPS,
            frameCount: fbxClip.frameCount,
            duration: fbxClip.duration,
            jointRotations: jointRotations,
            rootPositions: rootPositions,
            blendShapeWeights: [:],
            createdAt: Date()
        )
    }
}
