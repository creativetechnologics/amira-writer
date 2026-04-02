import AppKit
import SceneKit

@available(macOS 26.0, *)
struct CharacterExpressionCueResolution: Sendable, Hashable {
    var canonicalCue: String?
    var behaviorCue: String
    var provenance: String?
}

@available(macOS 26.0, *)
struct CharacterPerformanceExpressionPreset: Codable, Sendable, Hashable {
    var aliases: [String] = []
    var baseCue: String?
    var browLift: Double = 0
    var browTilt: Double = 0
    var eyeOpen: Double = 1
    var smile: Double = 0
    var headPitch: Double = 0
    var morphWeights: [String: Double] = [:]
}

@available(macOS 26.0, *)
struct CharacterPerformanceMouthPreset: Codable, Sendable, Hashable {
    var aliases: [String] = []
    var baseVisemeToken: String?
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

    func merging(_ overlay: Character3DPerformanceProfile) -> Character3DPerformanceProfile {
        var merged = self
        merged.headNodeName = overlay.headNodeName ?? merged.headNodeName
        merged.faceNodeName = overlay.faceNodeName ?? merged.faceNodeName
        merged.jawNodeName = overlay.jawNodeName ?? merged.jawNodeName
        merged.mouthNodeName = overlay.mouthNodeName ?? merged.mouthNodeName
        merged.leftEyeNodeName = overlay.leftEyeNodeName ?? merged.leftEyeNodeName
        merged.rightEyeNodeName = overlay.rightEyeNodeName ?? merged.rightEyeNodeName
        merged.leftBrowNodeName = overlay.leftBrowNodeName ?? merged.leftBrowNodeName
        merged.rightBrowNodeName = overlay.rightBrowNodeName ?? merged.rightBrowNodeName
        merged.mouthProfileID = overlay.mouthProfileID ?? merged.mouthProfileID
        merged.expressionPresets.merge(overlay.expressionPresets) { _, new in new }
        merged.visemePresets.merge(overlay.visemePresets) { _, new in new }
        return merged
    }

    func resolvedExpressionPreset(
        for cue: String
    ) -> (key: String, preset: CharacterPerformanceExpressionPreset)? {
        let normalizedCue = cue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCue.isEmpty else { return nil }

        if let exact = expressionPresets.first(where: { entry in
            expressionSearchTerms(for: entry).contains { term in
                term.caseInsensitiveCompare(normalizedCue) == .orderedSame
            }
        }) {
            return (key: exact.key, preset: exact.value)
        }

        for family in Self.expressionCueFamilies {
            guard family.contains(where: { normalizedCue.contains($0) }) else { continue }
            if let matched = expressionPresets.first(where: { entry in
                expressionSearchTerms(for: entry).contains { term in
                    family.contains { alias in
                        term.contains(alias)
                    }
                }
            }) {
                return (key: matched.key, preset: matched.value)
            }
        }

        return nil
    }

    func expressionCueResolution(for cue: String) -> CharacterExpressionCueResolution? {
        guard let normalizedCue = Self.normalizedToken(cue) else { return nil }

        if let resolved = resolvedExpressionPreset(for: normalizedCue) {
            let searchTerms = expressionSearchTerms(for: (key: resolved.key, value: resolved.preset))
            if let baseCue = Self.normalizedToken(resolved.preset.baseCue) {
                return CharacterExpressionCueResolution(
                    canonicalCue: resolved.key,
                    behaviorCue: baseCue,
                    provenance: "baseCue:\(baseCue)"
                )
            }
            if let semanticCue = searchTerms.first(where: { Self.isSemanticExpressionCue($0) }) {
                let aliasMatch = searchTerms.first(where: {
                    $0.caseInsensitiveCompare(normalizedCue) == .orderedSame &&
                    $0.caseInsensitiveCompare(resolved.key) != .orderedSame
                })
                let provenance = aliasMatch.map { "alias:\($0)" }
                return CharacterExpressionCueResolution(
                    canonicalCue: resolved.key,
                    behaviorCue: semanticCue,
                    provenance: provenance
                )
            }
            return CharacterExpressionCueResolution(
                canonicalCue: resolved.key,
                behaviorCue: normalizedCue,
                provenance: nil
            )
        }

        let available = availableExpressionBehaviorCues()
        guard !available.isEmpty else { return nil }

        if let family = Self.expressionCueFamilies.first(where: { family in
            family.contains { normalizedCue.contains($0) }
        }) {
            if let familyCue = available.first(where: { cue in
                family.contains { cue.contains($0) }
            }) {
                return CharacterExpressionCueResolution(
                    canonicalCue: nil,
                    behaviorCue: familyCue,
                    provenance: "familyFallback:\(familyCue)"
                )
            }
        }

        if let neutralCue = available.first(where: { $0.contains("neutral") || $0.contains("rest") || $0.contains("default") }) {
            return CharacterExpressionCueResolution(
                canonicalCue: nil,
                behaviorCue: neutralCue,
                provenance: "neutralFallback:\(neutralCue)"
            )
        }

        if let first = available.first {
            return CharacterExpressionCueResolution(
                canonicalCue: nil,
                behaviorCue: first,
                provenance: "poolFallback:\(first)"
            )
        }

        return nil
    }

    func canonicalExpressionCue(for cue: String) -> String? {
        expressionCueResolution(for: cue)?.canonicalCue
    }

    func expressionBehaviorCue(for cue: String) -> String? {
        expressionCueResolution(for: cue)?.behaviorCue
    }

    func expressionCueProvenance(for cue: String) -> String? {
        expressionCueResolution(for: cue)?.provenance
    }

    func resolvedVisemePreset(
        for mouthState: CharacterMouthState
    ) -> (key: String, preset: CharacterPerformanceMouthPreset)? {
        let candidates = Self.visemeFallbacks[mouthState.viseme.token, default: [mouthState.viseme.token]]
        let extraCandidates = [mouthState.cue.lowercased(), mouthState.viseme.token.lowercased()]
        let orderedCandidates = Array(NSOrderedSet(array: candidates + extraCandidates)) as? [String] ?? (candidates + extraCandidates)

        for candidate in orderedCandidates {
            if let exact = visemePresets.first(where: { entry in
                visemeSearchTerms(for: entry).contains { term in
                    term.caseInsensitiveCompare(candidate) == .orderedSame
                }
            }) {
                return (key: exact.key, preset: exact.value)
            }
            if let tokenMatch = visemePresets.first(where: { entry in
                visemeSearchTerms(for: entry).contains(where: { Self.visemeKey($0, matches: candidate) })
            }) {
                return (key: tokenMatch.key, preset: tokenMatch.value)
            }
        }

        return nil
    }

    func resolvedVisemeCue(for mouthState: CharacterMouthState) -> String? {
        resolvedVisemePreset(for: mouthState)?.key
    }

    func canonicalVisemeToken(for mouthState: CharacterMouthState) -> PrestonBlairViseme? {
        guard let resolved = resolvedVisemePreset(for: mouthState) else { return nil }
        let searchTerms = visemeSearchTerms(for: (key: resolved.key, value: resolved.preset))
        let token = Self.normalizedToken(resolved.preset.baseVisemeToken)
            ?? searchTerms.first(where: { Self.visemeTokenSet.contains($0) })
        guard let token else { return nil }
        return PrestonBlairViseme.allCases.first {
            $0.token.caseInsensitiveCompare(token) == .orderedSame
        }
    }

    func availableVisemes() -> [PrestonBlairViseme] {
        var ordered: [PrestonBlairViseme] = []
        for entry in visemePresets {
            let viseme = Self.normalizedToken(entry.value.baseVisemeToken)
                .flatMap(Self.canonicalViseme(for:))
                ?? visemeSearchTerms(for: entry).compactMap(Self.canonicalViseme(for:)).first
            guard let viseme,
                  !ordered.contains(viseme) else {
                continue
            }
            ordered.append(viseme)
        }
        return ordered
    }

    private static let expressionCueFamilies: [[String]] = [
        ["joy", "happy", "hope", "warm", "smile"],
        ["sad", "grief", "worry", "tired"],
        ["angry", "fury", "intense", "determined"],
        ["surprised", "surprise", "shocked", "alarm"],
        ["attentive", "listen", "curious", "concern"],
        ["neutral", "rest", "default"]
    ]

    private static let visemeFallbacks: [String: [String]] = [
        "ai": ["ai", "e", "o", "rest"],
        "e": ["e", "ai", "consonant", "rest"],
        "o": ["o", "u", "wq", "rest"],
        "u": ["u", "o", "wq", "rest"],
        "consonant": ["consonant", "fv", "l", "mbp", "rest"],
        "fv": ["fv", "consonant", "rest"],
        "l": ["l", "consonant", "rest"],
        "mbp": ["mbp", "consonant", "rest"],
        "wq": ["wq", "u", "o", "rest"],
        "rest": ["rest", "mbp", "consonant"]
    ]

    private static let visemeTokenSet = Set(PrestonBlairViseme.allCases.map(\.token))

    static func canonicalViseme(for key: String) -> PrestonBlairViseme? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if let exact = PrestonBlairViseme.allCases.first(where: {
            $0.token.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }

        let segments = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if let segmentMatch = PrestonBlairViseme.allCases.first(where: { viseme in
            segments.contains { $0.caseInsensitiveCompare(viseme.token) == .orderedSame }
        }) {
            return segmentMatch
        }

        switch normalized {
        case _ where normalized.contains("closed") || normalized.contains("rest") || normalized.contains("neutral"):
            return .rest
        case _ where normalized.contains("speak") || normalized.contains("talk"):
            return .consonant
        case _ where normalized.contains("sing") || normalized.contains("belt"):
            return .ai
        default:
            return nil
        }
    }

    private static func visemeKey(_ key: String, matches candidate: String) -> Bool {
        if key.caseInsensitiveCompare(candidate) == .orderedSame {
            return true
        }

        let segments = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if segments.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            return true
        }

        guard let canonicalViseme = canonicalViseme(for: key) else {
            return false
        }
        let canonicalCandidates = visemeFallbacks[canonicalViseme.token, default: [canonicalViseme.token]]
        return canonicalCandidates.contains(where: {
            $0.caseInsensitiveCompare(candidate) == .orderedSame
        })
    }

    private func expressionSearchTerms(
        for entry: (key: String, value: CharacterPerformanceExpressionPreset)
    ) -> [String] {
        let tokens = [entry.key] + entry.value.aliases + [entry.value.baseCue].compactMap { $0 }
        return Self.normalizedTokens(tokens)
    }

    private func availableExpressionBehaviorCues() -> [String] {
        var ordered: [String] = []
        for entry in expressionPresets {
            let searchTerms = expressionSearchTerms(for: entry)
            let behaviorCue = Self.normalizedToken(entry.value.baseCue)
                ?? searchTerms.first(where: { Self.isSemanticExpressionCue($0) })
            guard let behaviorCue,
                  !ordered.contains(where: { $0.caseInsensitiveCompare(behaviorCue) == .orderedSame }) else {
                continue
            }
            ordered.append(behaviorCue)
        }
        return ordered
    }

    private func visemeSearchTerms(
        for entry: (key: String, value: CharacterPerformanceMouthPreset)
    ) -> [String] {
        let tokens = [entry.key] + entry.value.aliases + [entry.value.baseVisemeToken].compactMap { $0 }
        return Self.normalizedTokens(tokens)
    }

    private static func normalizedTokens(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values.compactMap(normalizedToken))) as? [String]
            ?? values.compactMap(normalizedToken)
    }

    private static func normalizedToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSemanticExpressionCue(_ cue: String) -> Bool {
        expressionCueFamilies.contains { family in
            family.contains { cue.contains($0) }
        }
    }
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
struct CharacterPerformanceApplicationResult: Sendable, Hashable {
    var resolvedExpressionPresetCue: String?
    var resolvedVisemePresetCue: String?
    var usedExpressionPreset: Bool
    var usedVisemePreset: Bool
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
    ) -> CharacterPerformanceApplicationResult {
        let expressionResolution = profile?.resolvedExpressionPreset(for: rawExpression.cue)
        let mouthResolution = profile?.resolvedVisemePreset(for: rawMouth)
        let expressionPreset = expressionResolution?.preset
        let mouthPreset = mouthResolution?.preset

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

        return CharacterPerformanceApplicationResult(
            resolvedExpressionPresetCue: expressionResolution?.key,
            resolvedVisemePresetCue: mouthResolution?.key,
            usedExpressionPreset: expressionResolution != nil,
            usedVisemePreset: mouthResolution != nil
        )
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
