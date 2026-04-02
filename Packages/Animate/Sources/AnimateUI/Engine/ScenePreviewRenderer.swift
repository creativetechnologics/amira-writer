import AppKit
import SceneKit
import simd

// MARK: - Scene Preview Renderer

/// Central coordinator that takes a `SceneProductionPlan` and drives a SceneKit
/// scene graph for the 3D test harness preview.
///
/// Integrates:
/// - `AnimationCamera` / `CameraRig` for physically-based camera control
/// - Per-element frame rate quantization (Spider-Verse style variable rates)
/// - `SceneDepthManager` for parallax depth layers and atmospheric perspective
/// - `SceneAssetPipeline` for loading character / prop geometry
///
/// The renderer owns the `SCNScene` and exposes `sceneKitScene` and `pointOfView`
/// for embedding in an `SCNView` (via `Animate3DTestHarnessView`).
@available(macOS 26.0, *)
@MainActor
final class ScenePreviewRenderer {

    // MARK: Sub-systems

    private let assetPipeline: SceneAssetPipeline
    private weak var store: AnimateStore?
    private let expressionEngine = CharacterExpressionEngine()
    private let mouthEngine = CharacterMouthEngine()
    private var depthManager = SceneDepthManager()
    private var currentPlan: SceneProductionPlan?
    private var characterPerformanceStatusesByName: [String: Animate3DCharacterPerformanceStatus] = [:]
    private var characterPerformanceProfilesByName: [String: Character3DPerformanceProfile] = [:]

    /// Per-character hold multipliers (character name -> hold frames).
    /// Camera always runs on ones (multiplier 1).
    private var characterHoldMultipliers: [String: Int] = [:]
    private var cameraHoldMultiplier: Int = 1

    private struct MotionContext {
        var actionCue: String?
        var poseCue: String?
        var resolvedMotion: (descriptor: Animate3DMotionSetDescriptor, provenance: String)?
    }

    private struct HoldResolution {
        var multiplier: Int
        var provenance: String?
    }

    // MARK: Scene Graph

    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let stageNode = SCNNode()
    private var characterNodes: [String: SCNNode] = [:]
    private var characterPerformanceDrivers: [String: CharacterPerformanceDriver] = [:]
    private var propNodes: [String: SCNNode] = [:]
    private var worldNode: SCNNode?
    private var backgroundNode: SCNNode?

    // MARK: Lighting Rig

    private let keyLightNode = SCNNode()
    private let fillLightNode = SCNNode()
    private let rimLightNode = SCNNode()
    private let ambientLightNode = SCNNode()
    private var currentCelShadingSettings: CelShadingSettings = .default

    // MARK: Init

    init(store: AnimateStore) {
        self.store = store
        self.assetPipeline = SceneAssetPipeline(store: store)
        setupScene()
        setupLighting()
        setupCamera()
    }

    /// The SCNScene to display in an SCNView.
    var sceneKitScene: SCNScene { scene }

    /// The camera node for the SCNView's pointOfView.
    var pointOfView: SCNNode { cameraNode }
}

// MARK: - Scene Setup

@available(macOS 26.0, *)
extension ScenePreviewRenderer {

    private func setupScene() {
        scene.rootNode.addChildNode(stageNode)
        scene.rootNode.addChildNode(cameraNode)

        // Ground reference plane for shadow receiving.
        let ground = SCNFloor()
        ground.reflectivity = 0
        let groundMat = SCNMaterial()
        groundMat.diffuse.contents = NSColor(white: 0.15, alpha: 1)
        groundMat.lightingModel = .constant
        ground.materials = [groundMat]
        let groundNode = SCNNode(geometry: ground)
        groundNode.name = "ground"
        stageNode.addChildNode(groundNode)
    }

    private func setupLighting() {
        // Three-point lighting for cinematic look.

        // Key light: warm, bright, slightly above and to the right.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1000
        key.color = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.9, alpha: 1)
        key.castsShadow = true
        key.shadowRadius = 3
        key.shadowSampleCount = 8
        key.shadowMode = .forward
        keyLightNode.light = key
        keyLightNode.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(keyLightNode)

        // Fill light: cool, softer, opposite side.
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 400
        fill.color = NSColor(calibratedRed: 0.85, green: 0.9, blue: 1.0, alpha: 1)
        fill.castsShadow = false
        fillLightNode.light = fill
        fillLightNode.eulerAngles = SCNVector3(-0.4, -0.8, 0)
        scene.rootNode.addChildNode(fillLightNode)

        // Rim light: accent from behind.
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 300
        rim.color = NSColor(calibratedRed: 0.9, green: 0.95, blue: 1.0, alpha: 1)
        rim.castsShadow = false
        rimLightNode.light = rim
        rimLightNode.eulerAngles = SCNVector3(-0.3, 3.14, 0)
        scene.rootNode.addChildNode(rimLightNode)

        // Ambient fill.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 350
        ambient.color = NSColor(white: 0.85, alpha: 1)
        ambientLightNode.light = ambient
        scene.rootNode.addChildNode(ambientLightNode)
    }

    private func setupCamera() {
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 200
        camera.fieldOfView = 50
        camera.wantsDepthOfField = false
        cameraNode.camera = camera
        cameraNode.name = "mainCamera"
    }
}

// MARK: - Loading a Production Plan

@available(macOS 26.0, *)
extension ScenePreviewRenderer {

    /// Loads a production plan and sets up all scene elements.
    func loadPlan(_ plan: SceneProductionPlan) async {
        currentPlan = plan
        assetPipeline.invalidateRegistryDrivenCaches()
        depthManager.layers = SceneDepthManager.defaultLayers

        // Build per-character hold multipliers from the blocking plans.
        // The holdStyle on each CharacterBlockingPlan carries the multiplier.
        characterHoldMultipliers.removeAll()
        for blocking in plan.characterBlocking {
            characterHoldMultipliers[blocking.characterName] = blocking.holdStyle.holdFrames
        }
        // Camera defaults to on-ones (multiplier 1)
        cameraHoldMultiplier = 1

        // Clear existing scene elements
        characterNodes.values.forEach { $0.removeFromParentNode() }
        propNodes.values.forEach { $0.removeFromParentNode() }
        worldNode?.removeFromParentNode()
        backgroundNode?.removeFromParentNode()
        characterNodes.removeAll()
        characterPerformanceDrivers.removeAll()
        characterPerformanceStatusesByName.removeAll()
        characterPerformanceProfilesByName.removeAll()
        propNodes.removeAll()
        worldNode = nil
        backgroundNode = nil

        // Load characters
        let palette: [NSColor] = [
            .systemPink, .systemTeal, .systemOrange,
            .systemMint, .systemPurple, .systemYellow
        ]
        for (index, blocking) in plan.characterBlocking.enumerated() {
            let bundleInfo = store.map { Animate3DRegistryBundleService(store: $0) }?
                .resolvedBundleInfo(for: blocking.characterSlug, costumeName: blocking.preferredCostumeName)
            let node = assetPipeline.characterNode(
                slug: blocking.characterSlug,
                costumeName: blocking.preferredCostumeName,
                color: palette[index % palette.count]
            )
            node.name = "character_\(blocking.characterSlug)"
            stageNode.addChildNode(node)
            characterNodes[blocking.characterName] = node
            let performanceProfile = assetPipeline.loadCharacterPerformanceProfile(
                slug: blocking.characterSlug,
                costumeName: blocking.preferredCostumeName
            )
            if let performanceProfile {
                characterPerformanceProfilesByName[blocking.characterName] = performanceProfile
            }
            let driver = CharacterPerformanceDriver(
                rootNode: node,
                profile: performanceProfile
            )
            let profileSourcePaths = assetPipeline.characterPerformanceProfileSourceRelativePaths(
                slug: blocking.characterSlug,
                costumeName: blocking.preferredCostumeName
            )
            characterPerformanceDrivers[blocking.characterName] = driver
            characterPerformanceStatusesByName[blocking.characterName] = Animate3DCharacterPerformanceStatus(
                characterName: blocking.characterName,
                characterSlug: blocking.characterSlug,
                preferredCostumeName: blocking.preferredCostumeName,
                resolvedBundleCostumeName: bundleInfo?.descriptor.costumeName,
                resolvedBundleSourcePath: bundleInfo?.sourceManifestPath,
                resolvedBundleAssetPaths: bundleInfo?.resolvedAssetPaths ?? [],
                modelFileName: assetPipeline.characterModelFileName(
                    slug: blocking.characterSlug,
                    costumeName: blocking.preferredCostumeName
                ),
                modelSourcePath: assetPipeline.characterModelSourceRelativePath(
                    slug: blocking.characterSlug,
                    costumeName: blocking.preferredCostumeName
                ),
                driverMode: driver.driverMode,
                profileSourceFileName: assetPipeline.characterPerformanceProfileSourceFileName(
                    slug: blocking.characterSlug,
                    costumeName: blocking.preferredCostumeName
                ),
                profileSourcePath: assetPipeline.characterPerformanceProfileSourceRelativePath(
                    slug: blocking.characterSlug,
                    costumeName: blocking.preferredCostumeName
                ),
                profileSourceCount: profileSourcePaths.count,
                profileSourcePaths: profileSourcePaths,
                mouthProfileID: performanceProfile?.mouthProfileID,
                expressionPresetCount: performanceProfile?.expressionPresets.count ?? 0,
                visemePresetCount: performanceProfile?.visemePresets.count ?? 0,
                usingExpressionPreset: false,
                usingVisemePreset: false,
                resolvedExpressionPresetCue: nil,
                resolvedVisemePresetCue: nil,
                sourceExpressionCue: performanceProfile == nil ? "fallback:neutral" : "neutral",
                sourceVisemeCue: performanceProfile == nil ? "fallback:rest" : "rest",
                expressionBehaviorCue: nil,
                expressionCueProvenance: nil,
                visemeCueProvenance: nil,
                sourceActionCue: nil,
                sourcePoseCue: nil,
                resolvedMotionID: nil,
                resolvedMotionTitle: nil,
                motionProvenance: nil,
                resolvedHoldMultiplier: blocking.holdStyle.holdFrames,
                holdProvenance: "blocking:x\(blocking.holdStyle.holdFrames)",
                activeExpressionCue: performanceProfile == nil ? "fallback:neutral" : "neutral",
                activeVisemeCue: performanceProfile == nil ? "fallback:rest" : "rest",
                isVisible: false
            )
        }

        // Load props
        for placement in plan.objectPlacements {
            let node = assetPipeline.propNode(name: placement.objectName)
            node.name = "prop_\(placement.objectName)"
            stageNode.addChildNode(node)
            propNodes[placement.objectName] = node
        }

        if let worldChunk = plan.worldChunk,
           let chunkNode = assetPipeline.worldChunkNode(descriptor: worldChunk) {
            chunkNode.name = "worldChunk_\(worldChunk.worldID)_\(worldChunk.zoneID)"
            chunkNode.position = SCNVector3(0, 0, -8)
            stageNode.addChildNode(chunkNode)
            worldNode = chunkNode
        }

        // Load background
        if let previewImagePath = plan.worldChunk?.previewImagePath {
            let cam = AnimationCamera()
            if let bgNode = assetPipeline.backgroundNode(relativePath: previewImagePath, camera: cam) {
                bgNode.name = "background"
                bgNode.position = SCNVector3(0, 0, -20)
                stageNode.addChildNode(bgNode)
                backgroundNode = bgNode
            }
        } else if let backgroundName = plan.backgroundName ?? plan.sceneName.nilIfEmpty {
            let cam = AnimationCamera()
            if let bgNode = assetPipeline.backgroundNode(name: backgroundName, camera: cam) {
                bgNode.name = "background"
                bgNode.position = SCNVector3(0, 0, -20)
                stageNode.addChildNode(bgNode)
                backgroundNode = bgNode
            }
        }

        applyLightRig(plan.lightRig)
        applyAtmosphere(plan.atmospherePreset)
        currentCelShadingSettings = celShadingSettings(for: plan.styleProfile)
    }
}

// MARK: - Per-Frame Rendering

@available(macOS 26.0, *)
extension ScenePreviewRenderer {

    /// Updates the scene to reflect the given raw frame number.
    ///
    /// Camera always runs smooth (on ones). Characters and objects use their
    /// individual hold rates from the production plan's blocking data
    /// (Spider-Verse style variable rates).
    func renderFrame(_ rawFrame: Int) {
        guard let plan = currentPlan else { return }

        // Camera is always smooth (on ones)
        let cameraFrame = quantize(rawFrame, holdMultiplier: cameraHoldMultiplier)
        updateCamera(plan: plan, frame: cameraFrame)

        // Characters at their individual hold rates
        for blocking in plan.characterBlocking {
            let motionContext = motionContext(for: blocking, frame: rawFrame)
            let holdResolution = resolveHoldMultiplier(
                for: blocking,
                motionContext: motionContext
            )
            let charFrame = quantize(rawFrame, holdMultiplier: holdResolution.multiplier)
            updateCharacter(
                blocking: blocking,
                frame: charFrame,
                motionContext: motionContext,
                holdResolution: holdResolution
            )
        }

        // Objects
        for placement in plan.objectPlacements {
            updateProp(placement: placement, frame: rawFrame)
        }

        // Update depth-of-field blur radii based on current camera state
        if let cam = currentAnimationCamera(plan: plan, frame: cameraFrame) {
            depthManager.updateBlurRadii(camera: cam)
        }
    }

    /// Quantizes a raw frame number using a hold multiplier.
    /// E.g. holdMultiplier=2 gives "on twos": frames 0,1 -> 0, frames 2,3 -> 2, etc.
    private func quantize(_ frame: Int, holdMultiplier: Int) -> Int {
        let h = max(1, holdMultiplier)
        return (frame / h) * h
    }

    // MARK: Camera

    private func updateCamera(plan: SceneProductionPlan, frame: Int) {
        let choreography = plan.cameraChoreography
        guard !choreography.keyframes.isEmpty else { return }

        let sorted = choreography.keyframes.sorted { $0.frame < $1.frame }

        guard let first = sorted.first, let last = sorted.last else { return }
        if frame <= first.frame {
            applyCameraKeyframe(first)
            return
        }
        if frame >= last.frame {
            applyCameraKeyframe(last)
            return
        }

        // Find surrounding keyframes
        var before = first
        var after = last
        for i in 0..<sorted.count - 1 {
            if sorted[i].frame <= frame && sorted[i + 1].frame > frame {
                before = sorted[i]
                after = sorted[i + 1]
                break
            }
        }

        let span = max(1, after.frame - before.frame)
        let t = Double(frame - before.frame) / Double(span)
        let easedT = AnimationEngine.applyEasing(t, curve: before.easing)

        // Interpolate camera properties
        let pos = simdMix(before.position, after.position, t: easedT)
        let lookAt = simdMix(before.lookAt, after.lookAt, t: easedT)
        let focalLength = scalarMix(before.focalLength, after.focalLength, t: easedT)
        let roll = scalarMix(before.roll, after.roll, t: easedT)

        // Build an AnimationCamera and apply it to the SceneKit node,
        // which handles FOV, DOF, position, look-at, and Dutch angle.
        var cam = AnimationCamera()
        cam.position = pos
        cam.lookAt = lookAt
        cam.focalLength = focalLength
        cam.roll = roll
        cam.apply(to: cameraNode)
    }

    private func applyCameraKeyframe(_ kf: CameraChoreographyPlan.CameraKeyframe) {
        var cam = AnimationCamera()
        cam.position = kf.position
        cam.lookAt = kf.lookAt
        cam.focalLength = kf.focalLength
        cam.roll = kf.roll
        cam.apply(to: cameraNode)
    }

    /// Builds a transient `AnimationCamera` for the current interpolated state
    /// so the depth manager can compute blur radii.
    private func currentAnimationCamera(
        plan: SceneProductionPlan, frame: Int
    ) -> AnimationCamera? {
        let choreography = plan.cameraChoreography
        guard !choreography.keyframes.isEmpty else { return nil }

        let sorted = choreography.keyframes.sorted { $0.frame < $1.frame }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        if frame <= first.frame {
            return cameraFromKeyframe(first)
        }
        if frame >= last.frame {
            return cameraFromKeyframe(last)
        }

        var before = first
        var after = last
        for i in 0..<sorted.count - 1 {
            if sorted[i].frame <= frame && sorted[i + 1].frame > frame {
                before = sorted[i]
                after = sorted[i + 1]
                break
            }
        }

        let span = max(1, after.frame - before.frame)
        let t = Double(frame - before.frame) / Double(span)
        let easedT = AnimationEngine.applyEasing(t, curve: before.easing)

        var cam = AnimationCamera()
        cam.position = simdMix(before.position, after.position, t: easedT)
        cam.lookAt = simdMix(before.lookAt, after.lookAt, t: easedT)
        cam.focalLength = scalarMix(before.focalLength, after.focalLength, t: easedT)
        cam.roll = scalarMix(before.roll, after.roll, t: easedT)
        return cam
    }

    private func cameraFromKeyframe(
        _ kf: CameraChoreographyPlan.CameraKeyframe
    ) -> AnimationCamera {
        var cam = AnimationCamera()
        cam.position = kf.position
        cam.lookAt = kf.lookAt
        cam.focalLength = kf.focalLength
        cam.roll = kf.roll
        return cam
    }

    // MARK: Characters

    private func updateCharacter(
        blocking: CharacterBlockingPlan,
        frame: Int,
        motionContext: MotionContext,
        holdResolution: HoldResolution
    ) {
        guard let node = characterNodes[blocking.characterName] else { return }
        let resolvedMotion = motionContext.resolvedMotion

        // Visibility: respect entrance/exit frames
        let visible = frame >= blocking.entranceFrame
            && (blocking.exitFrame == nil || frame <= blocking.exitFrame!)
        node.isHidden = !visible
        characterPerformanceStatusesByName[blocking.characterName]?.isVisible = visible
        guard visible else { return }

        // Interpolate position between surrounding blocking keyframes
        let sorted = blocking.keyPositions.sorted { $0.frame < $1.frame }
        guard !sorted.isEmpty else { return }

        guard let first = sorted.first, let last = sorted.last else { return }
        if frame <= first.frame {
            node.position = scnPosition(first.position)
            applyFacing(node: node, facing: first.facing)
            applyResolvedMotion(
                node: node,
                frame: frame,
                basePosition: first.position,
                movementDelta: SIMD3<Double>(0, 0, 0),
                motion: resolvedMotion
            )
            applyPerformance(
                blocking: blocking,
                frame: frame,
                motionContext: motionContext,
                holdResolution: holdResolution
            )
            return
        }
        if frame >= last.frame {
            node.position = scnPosition(last.position)
            applyFacing(node: node, facing: last.facing)
            applyResolvedMotion(
                node: node,
                frame: frame,
                basePosition: last.position,
                movementDelta: SIMD3<Double>(0, 0, 0),
                motion: resolvedMotion
            )
            applyPerformance(
                blocking: blocking,
                frame: frame,
                motionContext: motionContext,
                holdResolution: holdResolution
            )
            return
        }

        var before = first
        var after = last
        for i in 0..<sorted.count - 1 {
            if sorted[i].frame <= frame && sorted[i + 1].frame > frame {
                before = sorted[i]
                after = sorted[i + 1]
                break
            }
        }

        let span = max(1, after.frame - before.frame)
        let t = Double(frame - before.frame) / Double(span)
        let easedT = AnimationEngine.applyEasing(t, curve: before.easing)

        let pos = simdMix(before.position, after.position, t: easedT)
        node.position = scnPosition(pos)

        // Face movement direction when moving laterally, otherwise use keyframe facing
        let delta = after.position - before.position
        if abs(delta.x) > 0.01 {
            node.eulerAngles.y = CGFloat(delta.x > 0 ? 0 : Double.pi)
        } else {
            applyFacing(node: node, facing: before.facing)
        }
        applyResolvedMotion(
            node: node,
            frame: frame,
            basePosition: pos,
            movementDelta: delta,
            motion: resolvedMotion
        )

        applyPerformance(
            blocking: blocking,
            frame: frame,
            motionContext: motionContext,
            holdResolution: holdResolution
        )
    }

    private func applyPerformance(
        blocking: CharacterBlockingPlan,
        frame: Int,
        motionContext: MotionContext,
        holdResolution: HoldResolution
    ) {
        let profile = characterPerformanceProfilesByName[blocking.characterName]
        let liveExpression = store?.evaluatedExpression(
            for: blocking.characterName,
            at: frame
        )
        let liveMouthCue = store?.evaluatedMouthCue(
            for: blocking.characterName,
            at: frame
        )
        let rawExpressionState = expressionEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveExpression
        )
        let expressionState = expressionEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveExpression,
            profile: profile
        )
        let rawMouthState = mouthEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveMouthCue,
            baseFPS: currentPlan?.baseFPS ?? 24
        )
        let mouthState = mouthEngine.state(
            for: blocking.characterName,
            blocking: blocking,
            frame: frame,
            liveCue: liveMouthCue,
            baseFPS: currentPlan?.baseFPS ?? 24,
            profile: profile
        )
        let applicationResult = characterPerformanceDrivers[blocking.characterName]?.apply(
            expression: expressionState,
            mouth: mouthState
        )
        let resolvedMotion = motionContext.resolvedMotion
        if var status = characterPerformanceStatusesByName[blocking.characterName] {
            status.sourceExpressionCue = rawExpressionState.cue
            status.sourceVisemeCue = rawMouthState.cue
            status.expressionBehaviorCue = profile?.expressionBehaviorCue(for: rawExpressionState.cue)
            status.expressionCueProvenance = profile?.expressionCueProvenance(for: rawExpressionState.cue)
            status.visemeCueProvenance = profile?.visemeCueProvenance(for: rawMouthState)
            status.sourceActionCue = motionContext.actionCue
            status.sourcePoseCue = motionContext.poseCue
            status.resolvedMotionID = resolvedMotion?.descriptor.motionID
            status.resolvedMotionTitle = resolvedMotion?.descriptor.title
            status.motionProvenance = resolvedMotion?.provenance
            status.resolvedHoldMultiplier = holdResolution.multiplier
            status.holdProvenance = holdResolution.provenance
            status.activeExpressionCue = expressionState.cue
            status.activeVisemeCue = mouthState.cue
            status.usingExpressionPreset = applicationResult?.usedExpressionPreset ?? false
            status.usingVisemePreset = applicationResult?.usedVisemePreset ?? false
            status.resolvedExpressionPresetCue = applicationResult?.resolvedExpressionPresetCue
            status.resolvedVisemePresetCue = applicationResult?.resolvedVisemePresetCue
            status.driverMode = characterPerformanceDrivers[blocking.characterName]?.driverMode ?? status.driverMode
            characterPerformanceStatusesByName[blocking.characterName] = status
        }
    }

    private func applyFacing(node: SCNNode, facing: FacingDirection) {
        switch facing {
        case .left:   node.eulerAngles.y = CGFloat.pi / 2
        case .right:  node.eulerAngles.y = -CGFloat.pi / 2
        case .camera: node.eulerAngles.y = 0
        case .away:   node.eulerAngles.y = CGFloat.pi
        }
    }

    private func applyResolvedMotion(
        node: SCNNode,
        frame: Int,
        basePosition: SIMD3<Double>,
        movementDelta: SIMD3<Double>,
        motion: (descriptor: Animate3DMotionSetDescriptor, provenance: String)?
    ) {
        guard let motion else { return }

        let tags = ([motion.descriptor.motionID, motion.descriptor.title] + motion.descriptor.tags)
            .map { $0.lowercased() }
        let cycle = Double(frame) / Double(max(currentPlan?.baseFPS ?? 24, 1))

        var verticalOffset = 0.0
        var pitch = 0.0
        var roll = 0.0

        if tags.contains(where: { ["walk", "stride", "cross", "move", "run"].contains($0) }) {
            let strideSpeed = max(0.4, simd_length(movementDelta) * 4)
            verticalOffset += sin(cycle * .pi * strideSpeed) * 0.06
            roll += sin(cycle * .pi * strideSpeed) * 0.035
        }

        if tags.contains(where: { ["listen", "wait", "think"].contains($0) }) {
            pitch += 0.03
            roll += sin(cycle * 1.6) * 0.02
        }

        if tags.contains(where: { ["present", "offer", "gesture", "point"].contains($0) }) {
            pitch -= 0.05
            roll += 0.04
        }

        if tags.contains(where: { ["determined", "resolve", "heroic", "focus"].contains($0) }) {
            pitch -= 0.07
        }

        if tags.contains(where: { ["sing", "belt", "vocal"].contains($0) }) {
            verticalOffset += sin(cycle * 2.4) * 0.04
            pitch -= 0.03
        }

        if tags.contains(where: { ["celebrate", "triumph", "jump"].contains($0) }) {
            verticalOffset += abs(sin(cycle * 3.2)) * 0.12
            roll += sin(cycle * 2.1) * 0.06
        }

        node.position = scnPosition(basePosition + SIMD3<Double>(0, verticalOffset, 0))
        node.eulerAngles.x = CGFloat(pitch)
        node.eulerAngles.z = CGFloat(roll)
    }

    private func motionContext(
        for blocking: CharacterBlockingPlan,
        frame: Int
    ) -> MotionContext {
        let actionCue = blocking.actingBeats
            .first(where: { $0.startFrame <= frame && frame <= $0.endFrame })?
            .action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let poseCue = blocking.keyPositions
            .sorted { $0.frame < $1.frame }
            .last(where: { $0.frame <= frame })?
            .pose
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return MotionContext(
            actionCue: actionCue,
            poseCue: poseCue,
            resolvedMotion: assetPipeline.resolveMotionSet(
                actionCue: actionCue,
                poseCue: poseCue
            )
        )
    }

    private func resolveHoldMultiplier(
        for blocking: CharacterBlockingPlan,
        motionContext: MotionContext
    ) -> HoldResolution {
        let baseMultiplier = characterHoldMultipliers[blocking.characterName]
            ?? blocking.holdStyle.holdFrames
        guard let resolvedMotion = motionContext.resolvedMotion else {
            return HoldResolution(
                multiplier: baseMultiplier,
                provenance: "blocking:x\(baseMultiplier)"
            )
        }

        let tags = Set(
            resolvedMotion.descriptor.tags.map { $0.lowercased() } +
            resolvedMotion.descriptor.title
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { String($0).lowercased() }
        )
        let fastTags: Set<String> = ["run", "sprint", "dash", "jump", "celebrate", "triumph", "move", "walk", "stride", "cross", "sing", "belt"]
        let slowTags: Set<String> = ["wait", "listen", "think", "idle", "observe", "hesitate", "pause"]
        let presentationalTags: Set<String> = ["present", "offer", "gesture", "point", "determined", "resolve", "heroic", "focus"]

        let adjustedMultiplier: Int
        if !tags.isDisjoint(with: slowTags) {
            adjustedMultiplier = max(baseMultiplier, 3)
        } else if !tags.isDisjoint(with: fastTags) {
            adjustedMultiplier = tags.contains("run") || tags.contains("sprint") || tags.contains("dash")
                ? 1
                : min(baseMultiplier, 2)
        } else if !tags.isDisjoint(with: presentationalTags) {
            adjustedMultiplier = 2
        } else {
            adjustedMultiplier = baseMultiplier
        }

        return HoldResolution(
            multiplier: max(1, adjustedMultiplier),
            provenance: "motion:\(resolvedMotion.provenance):x\(max(1, adjustedMultiplier))"
        )
    }

    // MARK: Props / Objects

    private func updateProp(placement: ObjectPlacementPlan, frame: Int) {
        guard let node = propNodes[placement.objectName] else { return }
        node.position = SCNVector3(
            Float(placement.position.x),
            Float(placement.position.y),
            Float(placement.position.z)
        )
        let s = Float(placement.scale)
        node.scale = SCNVector3(s, s, s)

        if let range = placement.visibleFrameRange {
            node.isHidden = !range.contains(frame)
        }
    }
}

// MARK: - Public Accessors

@available(macOS 26.0, *)
extension ScenePreviewRenderer {

    /// Current depth layer configuration (read-only snapshot).
    var depthLayers: [SceneDepthLayer] { depthManager.layers }

    /// Total frames in the loaded plan, or 0 if none.
    var totalFrames: Int { currentPlan?.totalFrames ?? 0 }

    /// Base FPS of the loaded plan, or 24 as default.
    var baseFPS: Int { currentPlan?.baseFPS ?? 24 }

    /// Whether a production plan is currently loaded.
    var hasPlan: Bool { currentPlan != nil }

    var celShadingSettings: CelShadingSettings { currentCelShadingSettings }

    func assetProfileExists(slug: String, costumeName: String? = nil) -> Bool {
        assetPipeline.hasCharacterPerformanceProfile(slug: slug, costumeName: costumeName)
    }

    var characterPerformanceStatuses: [Animate3DCharacterPerformanceStatus] {
        characterPerformanceStatusesByName.values.sorted {
            if $0.isVisible != $1.isVisible {
                return $0.isVisible && !$1.isVisible
            }
            return $0.characterName.localizedCaseInsensitiveCompare($1.characterName) == .orderedAscending
        }
    }
}

@available(macOS 26.0, *)
private extension ScenePreviewRenderer {
    func applyLightRig(_ lightRig: Animate3DLightRigDescriptor?) {
        let keyIntensity = lightRig.map { CGFloat($0.keyIntensity) } ?? 1000
        let fillIntensity = lightRig.map { CGFloat($0.fillIntensity) } ?? 400
        let rimIntensity = lightRig.map { CGFloat($0.rimIntensity) } ?? 300

        keyLightNode.light?.intensity = keyIntensity
        fillLightNode.light?.intensity = fillIntensity
        rimLightNode.light?.intensity = rimIntensity
        ambientLightNode.light?.intensity = max(120, fillIntensity * 0.65)
    }

    func applyAtmosphere(_ preset: Animate3DAtmospherePresetDescriptor?) {
        guard let preset else {
            scene.fogColor = NSColor.black
            scene.fogStartDistance = 60
            scene.fogEndDistance = 120
            return
        }

        scene.fogColor = NSColor(hex: preset.colorHex) ?? NSColor(calibratedWhite: 0.85, alpha: 1)
        scene.fogStartDistance = max(8, CGFloat(28 - preset.haze * 8))
        scene.fogEndDistance = max(scene.fogStartDistance + 8, CGFloat(80 - preset.fogDensity * 28))
    }

    func celShadingSettings(for profile: Animate3DStyleProfileDescriptor?) -> CelShadingSettings {
        guard let profile else { return .default }

        var settings = CelShadingSettings.default
        settings.colorBands = max(2, profile.celBands)
        settings.outlineWidth = Float(max(0.2, profile.outlineWidth))
        settings.shadowThreshold = max(0.18, min(0.52, 0.18 + Float(profile.celBands) * 0.04))
        settings.highlightThreshold = max(settings.shadowThreshold + 0.18, min(0.86, 0.68 + Float(profile.outlineWidth) * 0.03))
        return settings
    }
}

// MARK: - Helpers

@inline(__always)
private func simdMix(
    _ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double
) -> SIMD3<Double> {
    a + (b - a) * t
}

@inline(__always)
private func scalarMix(_ a: Double, _ b: Double, t: Double) -> Double {
    a + (b - a) * t
}

@inline(__always)
private func scnPosition(_ v: SIMD3<Double>) -> SCNVector3 {
    SCNVector3(Float(v.x), Float(v.y), Float(v.z))
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard trimmed.count == 6 || trimmed.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return nil }

        let r, g, b, a: UInt64
        if trimmed.count == 8 {
            r = (value >> 24) & 0xFF
            g = (value >> 16) & 0xFF
            b = (value >> 8) & 0xFF
            a = value & 0xFF
        } else {
            r = (value >> 16) & 0xFF
            g = (value >> 8) & 0xFF
            b = value & 0xFF
            a = 0xFF
        }

        self.init(
            calibratedRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}
