import AppKit
import SceneKit

@available(macOS 26.0, *)
struct CharacterPerformanceExpressionPreset: Codable, Sendable, Hashable {
    var browLift: Double = 0
    var browTilt: Double = 0
    var eyeOpen: Double = 1
    var smile: Double = 0
    var headPitch: Double = 0
    var morphWeights: [String: Double] = [:]
}

@available(macOS 26.0, *)
struct CharacterPerformanceMouthPreset: Codable, Sendable, Hashable {
    var jawOpen: Double = 0
    var mouthWidth: Double = 0.46
    var mouthHeight: Double = 0.16
    var pucker: Double = 0
    var smileBlend: Double = 0
    var morphWeights: [String: Double] = [:]
}

@available(macOS 26.0, *)
struct Character3DPerformanceProfile: Codable, Sendable, Hashable {
    var headNodeName: String?
    var faceNodeName: String?
    var jawNodeName: String?
    var mouthNodeName: String?
    var leftEyeNodeName: String?
    var rightEyeNodeName: String?
    var leftBrowNodeName: String?
    var rightBrowNodeName: String?
    var mouthProfileID: String?
    var expressionPresets: [String: CharacterPerformanceExpressionPreset] = [:]
    var visemePresets: [String: CharacterPerformanceMouthPreset] = [:]

    static let `default` = Character3DPerformanceProfile()
}

@available(macOS 26.0, *)
enum CharacterPerformanceDriverMode: String, Sendable, Hashable {
    case profileMapped = "profile_mapped"
    case hybridFallback = "hybrid_fallback"
    case generatedOverlay = "generated_overlay"

    var title: String {
        switch self {
        case .profileMapped: "Profile"
        case .hybridFallback: "Hybrid"
        case .generatedOverlay: "Fallback"
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class CharacterPerformanceDriver {
    private let rootNode: SCNNode
    private let headNode: SCNNode
    private let faceAnchorNode: SCNNode
    private let jawNode: SCNNode?
    private let mouthNode: SCNNode
    private let leftEyeNode: SCNNode
    private let rightEyeNode: SCNNode
    private let leftBrowNode: SCNNode
    private let rightBrowNode: SCNNode
    private let profile: Character3DPerformanceProfile?
    private let usesGeneratedFeatures: Bool

    private let baseHeadEulerAngles: SCNVector3
    private let baseJawEulerAngles: SCNVector3
    private let baseMouthPosition: SCNVector3
    private let baseMouthScale: SCNVector3
    private let baseLeftEyeScale: SCNVector3
    private let baseRightEyeScale: SCNVector3
    private let baseLeftBrowPosition: SCNVector3
    private let baseRightBrowPosition: SCNVector3
    private let baseLeftBrowEulerAngles: SCNVector3
    private let baseRightBrowEulerAngles: SCNVector3

    init(rootNode: SCNNode, profile: Character3DPerformanceProfile?) {
        self.rootNode = rootNode
        self.profile = profile

        let resolvedHead = Self.resolveNode(
            named: profile?.headNodeName,
            fallbackFragments: ["head", "face"],
            in: rootNode
        ) ?? rootNode
        headNode = resolvedHead
        faceAnchorNode = Self.resolveNode(
            named: profile?.faceNodeName,
            fallbackFragments: ["face", "head"],
            in: resolvedHead
        ) ?? resolvedHead
        jawNode = Self.resolveNode(
            named: profile?.jawNodeName,
            fallbackFragments: ["jaw", "mouth"],
            in: faceAnchorNode
        )

        let mouthResolution = Self.resolveOrCreateFeatureNode(
            named: profile?.mouthNodeName,
            fallbackFragments: ["mouth", "lip"],
            in: faceAnchorNode,
            created: Self.makeMouthNode
        )
        mouthNode = mouthResolution.node
        let leftEyeResolution = Self.resolveOrCreateFeatureNode(
            named: profile?.leftEyeNodeName,
            fallbackFragments: ["eye_l", "eye.l", "lefteye", "left_eye"],
            in: faceAnchorNode,
            created: { Self.makeEyeNode(name: "perf_eye_left") }
        )
        leftEyeNode = leftEyeResolution.node
        let rightEyeResolution = Self.resolveOrCreateFeatureNode(
            named: profile?.rightEyeNodeName,
            fallbackFragments: ["eye_r", "eye.r", "righteye", "right_eye"],
            in: faceAnchorNode,
            created: { Self.makeEyeNode(name: "perf_eye_right") }
        )
        rightEyeNode = rightEyeResolution.node
        let leftBrowResolution = Self.resolveOrCreateFeatureNode(
            named: profile?.leftBrowNodeName,
            fallbackFragments: ["brow_l", "brow.l", "leftbrow", "left_brow", "eyebrow_l"],
            in: faceAnchorNode,
            created: { Self.makeBrowNode(name: "perf_brow_left") }
        )
        leftBrowNode = leftBrowResolution.node
        let rightBrowResolution = Self.resolveOrCreateFeatureNode(
            named: profile?.rightBrowNodeName,
            fallbackFragments: ["brow_r", "brow.r", "rightbrow", "right_brow", "eyebrow_r"],
            in: faceAnchorNode,
            created: { Self.makeBrowNode(name: "perf_brow_right") }
        )
        rightBrowNode = rightBrowResolution.node
        usesGeneratedFeatures = [
            mouthResolution.createdFallback,
            leftEyeResolution.createdFallback,
            rightEyeResolution.createdFallback,
            leftBrowResolution.createdFallback,
            rightBrowResolution.createdFallback
        ].contains(true)

        baseHeadEulerAngles = headNode.eulerAngles
        baseJawEulerAngles = jawNode?.eulerAngles ?? SCNVector3(0, 0, 0)
        baseMouthPosition = mouthNode.position
        baseMouthScale = mouthNode.scale
        baseLeftEyeScale = leftEyeNode.scale
        baseRightEyeScale = rightEyeNode.scale
        baseLeftBrowPosition = leftBrowNode.position
        baseRightBrowPosition = rightBrowNode.position
        baseLeftBrowEulerAngles = leftBrowNode.eulerAngles
        baseRightBrowEulerAngles = rightBrowNode.eulerAngles
    }

    func apply(
        expression rawExpression: CharacterExpressionState,
        mouth rawMouth: CharacterMouthState
    ) {
        let expressionPreset = profile?.expressionPresets[rawExpression.cue]
        let mouthPreset = profile?.visemePresets[rawMouth.viseme.token]
            ?? profile?.visemePresets[rawMouth.cue]

        let expression = expressionPreset.map { rawExpression.applying($0) } ?? rawExpression
        let mouth = mouthPreset.map { rawMouth.applying($0) } ?? rawMouth

        let eyeScale = CGFloat(max(0.08, 0.2 + expression.eyeOpen * 0.8))
        leftEyeNode.scale = SCNVector3(baseLeftEyeScale.x, baseLeftEyeScale.y * eyeScale, baseLeftEyeScale.z)
        rightEyeNode.scale = SCNVector3(baseRightEyeScale.x, baseRightEyeScale.y * eyeScale, baseRightEyeScale.z)

        let browLiftOffset = CGFloat(expression.browLift * 0.12)
        let browTilt = CGFloat(expression.browTilt * 0.35)
        leftBrowNode.position = SCNVector3(
            baseLeftBrowPosition.x,
            baseLeftBrowPosition.y + browLiftOffset,
            baseLeftBrowPosition.z
        )
        rightBrowNode.position = SCNVector3(
            baseRightBrowPosition.x,
            baseRightBrowPosition.y + browLiftOffset,
            baseRightBrowPosition.z
        )
        leftBrowNode.eulerAngles = SCNVector3(
            baseLeftBrowEulerAngles.x,
            baseLeftBrowEulerAngles.y,
            baseLeftBrowEulerAngles.z + browTilt
        )
        rightBrowNode.eulerAngles = SCNVector3(
            baseRightBrowEulerAngles.x,
            baseRightBrowEulerAngles.y,
            baseRightBrowEulerAngles.z - browTilt
        )

        let headPitch = CGFloat(expression.headPitch * 0.22)
        headNode.eulerAngles = SCNVector3(
            baseHeadEulerAngles.x + headPitch,
            baseHeadEulerAngles.y,
            baseHeadEulerAngles.z
        )

        let smile = CGFloat(max(-1, min(1, expression.smile + mouth.smileBlend * 0.6)))
        let mouthWidth = CGFloat(max(0.16, mouth.mouthWidth + Double(smile) * 0.08))
        let mouthHeight = CGFloat(max(0.06, mouth.mouthHeight + mouth.jawOpen * 0.32))
        mouthNode.scale = SCNVector3(
            baseMouthScale.x * mouthWidth,
            baseMouthScale.y * mouthHeight,
            baseMouthScale.z
        )
        mouthNode.position = SCNVector3(
            baseMouthPosition.x,
            baseMouthPosition.y - CGFloat(mouth.jawOpen * 0.05),
            baseMouthPosition.z + CGFloat(mouth.pucker * 0.005)
        )

        if let jawNode {
            jawNode.eulerAngles = SCNVector3(
                baseJawEulerAngles.x - CGFloat(mouth.jawOpen * 0.45),
                baseJawEulerAngles.y,
                baseJawEulerAngles.z
            )
        }

        var morphWeights: [String: Double] = [:]
        expressionPreset?.morphWeights.forEach { morphWeights[$0.key] = $0.value }
        mouthPreset?.morphWeights.forEach { morphWeights[$0.key] = $0.value }
        if !morphWeights.isEmpty {
            applyMorphWeights(morphWeights)
        }
    }

    var driverMode: CharacterPerformanceDriverMode {
        if profile != nil, !usesGeneratedFeatures {
            return .profileMapped
        }
        if profile != nil {
            return .hybridFallback
        }
        return .generatedOverlay
    }

    var isProfileBacked: Bool {
        profile != nil
    }

    private func applyMorphWeights(_ weights: [String: Double]) {
        rootNode.enumerateChildNodes { node, _ in
            guard let morpher = node.morpher else { return }
            for (index, target) in morpher.targets.enumerated() {
                let name = target.name ?? ""
                guard let weight = weights.first(where: { key, _ in
                    key.caseInsensitiveCompare(name) == .orderedSame
                })?.value else { continue }
                morpher.setWeight(CGFloat(weight), forTargetAt: index)
            }
        }
    }
}

@available(macOS 26.0, *)
private extension CharacterPerformanceDriver {
    struct FeatureNodeResolution {
        let node: SCNNode
        let createdFallback: Bool
    }

    static func resolveNode(named explicitName: String?, fallbackFragments: [String], in root: SCNNode) -> SCNNode? {
        if let explicitName,
           let direct = root.childNode(withName: explicitName, recursively: true) {
            return direct
        }

        let loweredFragments = fallbackFragments.map { $0.lowercased() }
        var resolved: SCNNode?
        root.enumerateChildNodes { node, stop in
            let name = (node.name ?? "").lowercased()
            guard !name.isEmpty else { return }
            if loweredFragments.contains(where: { name.contains($0) }) {
                resolved = node
                stop.pointee = true
            }
        }
        return resolved
    }

    static func resolveOrCreateFeatureNode(
        named explicitName: String?,
        fallbackFragments: [String],
        in root: SCNNode,
        created: () -> SCNNode
    ) -> FeatureNodeResolution {
        if let resolved = resolveNode(named: explicitName, fallbackFragments: fallbackFragments, in: root) {
            return FeatureNodeResolution(node: resolved, createdFallback: false)
        }
        let node = created()
        root.addChildNode(node)
        return FeatureNodeResolution(node: node, createdFallback: true)
    }

    static func makeFeatureMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.black
        material.emission.contents = NSColor.black
        material.lightingModel = .constant
        material.isDoubleSided = true
        return material
    }

    static func makeEyeNode(name: String) -> SCNNode {
        let geometry = SCNPlane(width: 0.12, height: 0.04)
        geometry.cornerRadius = 0.02
        geometry.materials = [makeFeatureMaterial()]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = SCNVector3(name.contains("left") ? -0.14 : 0.14, 0.18, 0.08)
        return node
    }

    static func makeBrowNode(name: String) -> SCNNode {
        let geometry = SCNPlane(width: 0.15, height: 0.02)
        geometry.cornerRadius = 0.01
        geometry.materials = [makeFeatureMaterial()]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = SCNVector3(name.contains("left") ? -0.14 : 0.14, 0.28, 0.081)
        return node
    }

    static func makeMouthNode() -> SCNNode {
        let geometry = SCNPlane(width: 0.16, height: 0.06)
        geometry.cornerRadius = 0.03
        geometry.materials = [makeFeatureMaterial()]
        let node = SCNNode(geometry: geometry)
        node.name = "perf_mouth"
        node.position = SCNVector3(0, 0.02, 0.082)
        return node
    }
}
