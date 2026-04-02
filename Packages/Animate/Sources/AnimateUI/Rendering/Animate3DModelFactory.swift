import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO

/// Factory for building mannequin-style humanoid placeholders, recognizable prop
/// geometry, background planes, and loading external 3D model files (USDZ/OBJ/SCN).
/// All geometry is assembled from SceneKit primitives — no external assets required.
@available(macOS 26.0, *)
enum Animate3DModelFactory {

    // MARK: - Humanoid Placeholder

    /// Builds a mannequin humanoid (~2.0 units tall) from SceneKit primitives.
    /// Child nodes are named for independent animation: `head`, `neck`, `torso`,
    /// `hips`, `leftUpperArm`, `leftForearm`, `rightUpperArm`, `rightForearm`,
    /// `leftThigh`, `leftShin`, `rightThigh`, `rightShin`, `leftFoot`, `rightFoot`.
    static func makeHumanoidPlaceholder(
        color: NSColor = .systemGray,
        label: String? = nil
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "humanoidPlaceholder"

        let skin = color.blended(withFraction: 0.15, of: .white) ?? color
        let joint = color.blended(withFraction: 0.10, of: .black) ?? color

        // Head (slightly elongated sphere + chin)
        let headGeo = SCNSphere(radius: 0.12)
        headGeo.segmentCount = 32
        let head = makeNode(headGeo, color: skin, name: "head")
        head.scale = SCNVector3(1.0, 1.12, 0.95)
        head.position = SCNVector3(0, 1.82, 0)
        let chinGeo = SCNCylinder(radius: 0.06, height: 0.05)
        chinGeo.radialSegmentCount = 24
        let chin = makeNode(chinGeo, color: skin, name: "chin")
        chin.scale = SCNVector3(1.0, 1.0, 0.9)
        chin.position = SCNVector3(0, -0.10, 0.02)
        head.addChildNode(chin)

        // Neck
        let neckGeo = SCNCylinder(radius: 0.045, height: 0.10)
        neckGeo.radialSegmentCount = 20
        let neck = makeNode(neckGeo, color: skin, name: "neck")
        neck.position = SCNVector3(0, 1.72, 0)

        // Upper torso (broad chest) + waist (narrower)
        let chestGeo = SCNBox(width: 0.36, height: 0.34, length: 0.18, chamferRadius: 0.06)
        let chest = makeNode(chestGeo, color: color, name: "torso")
        chest.position = SCNVector3(0, 1.48, 0)
        let waistGeo = SCNBox(width: 0.28, height: 0.14, length: 0.15, chamferRadius: 0.04)
        let waist = makeNode(waistGeo, color: color, name: "waist")
        waist.position = SCNVector3(0, 1.24, 0)

        // Hips
        let hipGeo = SCNBox(width: 0.30, height: 0.10, length: 0.16, chamferRadius: 0.04)
        let hips = makeNode(hipGeo, color: color, name: "hips")
        hips.position = SCNVector3(0, 1.12, 0)

        // Shoulder joints
        let lShoulder = makeNode(makeSphere(0.055, segs: 20), color: joint, name: "leftShoulder")
        lShoulder.position = SCNVector3(-0.22, 1.62, 0)
        let rShoulder = makeNode(makeSphere(0.055, segs: 20), color: joint, name: "rightShoulder")
        rShoulder.position = SCNVector3(0.22, 1.62, 0)

        // Arms (upper arm, elbow joint, forearm, hand)
        func makeArm(side: String, x: CGFloat) -> (upper: SCNNode, elbow: SCNNode, fore: SCNNode, hand: SCNNode) {
            let upper = makeNode(makeCyl(0.042, h: 0.28), color: color, name: "\(side)UpperArm")
            upper.position = SCNVector3(x * 0.22, 1.46, 0)
            let elbow = makeNode(makeSphere(0.038, segs: 16), color: joint, name: "\(side)Elbow")
            elbow.position = SCNVector3(x * 0.22, 1.30, 0)
            let fore = makeNode(makeCyl(0.036, h: 0.28), color: color, name: "\(side)Forearm")
            fore.position = SCNVector3(x * 0.22, 1.14, 0)
            fore.scale = SCNVector3(0.9, 1.0, 0.9)
            let hand = makeNode(SCNBox(width: 0.06, height: 0.08, length: 0.03, chamferRadius: 0.012),
                                color: skin, name: "\(side)Hand")
            hand.position = SCNVector3(x * 0.22, 0.96, 0)
            return (upper, elbow, fore, hand)
        }
        let leftArm = makeArm(side: "left", x: -1)
        let rightArm = makeArm(side: "right", x: 1)

        // Legs (thigh, knee joint, shin, foot)
        func makeLeg(side: String, x: CGFloat) -> (thigh: SCNNode, knee: SCNNode, shin: SCNNode, foot: SCNNode) {
            let thigh = makeNode(makeCyl(0.058, h: 0.38), color: color, name: "\(side)Thigh")
            thigh.position = SCNVector3(x * 0.10, 0.88, 0)
            let knee = makeNode(makeSphere(0.048, segs: 18), color: joint, name: "\(side)Knee")
            knee.position = SCNVector3(x * 0.10, 0.67, 0)
            let shin = makeNode(makeCyl(0.046, h: 0.40), color: color, name: "\(side)Shin")
            shin.position = SCNVector3(x * 0.10, 0.44, 0)
            shin.scale = SCNVector3(0.92, 1.0, 0.92)
            let foot = makeNode(SCNBox(width: 0.08, height: 0.05, length: 0.16, chamferRadius: 0.02),
                                color: joint, name: "\(side)Foot")
            foot.position = SCNVector3(x * 0.10, 0.025, 0.03)
            return (thigh, knee, shin, foot)
        }
        let leftLeg = makeLeg(side: "left", x: -1)
        let rightLeg = makeLeg(side: "right", x: 1)

        // Assemble
        let parts: [SCNNode] = [
            head, neck, chest, waist, hips, lShoulder, rShoulder,
            leftArm.upper, leftArm.elbow, leftArm.fore, leftArm.hand,
            rightArm.upper, rightArm.elbow, rightArm.fore, rightArm.hand,
            leftLeg.thigh, leftLeg.knee, leftLeg.shin, leftLeg.foot,
            rightLeg.thigh, rightLeg.knee, rightLeg.shin, rightLeg.foot,
        ]
        for part in parts { root.addChildNode(part) }

        if let label {
            let text = SCNText(string: label, extrusionDepth: 0)
            text.font = NSFont.systemFont(ofSize: 0.18, weight: .medium)
            text.flatness = 0.15
            text.materials = [makeLabelMaterial(color)]
            let labelNode = SCNNode(geometry: text)
            labelNode.name = "label"
            labelNode.position = SCNVector3(-0.3, 2.12, 0)
            labelNode.scale = SCNVector3(0.24, 0.24, 0.24)
            labelNode.constraints = [SCNBillboardConstraint()]
            root.addChildNode(labelNode)
        }

        return root
    }

    // MARK: - Props

    /// Desk/table: four cylinder legs, flat top, drawer panel.
    static func makeDeskProp() -> SCNNode {
        let root = SCNNode(); root.name = "deskProp"
        let topC = NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.24, alpha: 1)
        let legC = NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.20, alpha: 1)
        let top = makeNode(SCNBox(width: 1.0, height: 0.04, length: 0.5, chamferRadius: 0.01), color: topC, name: "deskTop")
        top.position = SCNVector3(0, 0.72, 0)
        root.addChildNode(top)
        let legGeo = makeCyl(0.025, h: 0.70, segs: 12)
        for (i, off) in [(-0.44, -0.20), (0.44, -0.20), (-0.44, 0.20), (0.44, 0.20)].enumerated() {
            let leg = makeNode(legGeo.copy() as! SCNGeometry, color: legC, name: "deskLeg\(i)")
            leg.position = SCNVector3(Float(off.0), 0.35, Float(off.1))
            root.addChildNode(leg)
        }
        let drawer = makeNode(SCNBox(width: 0.4, height: 0.08, length: 0.42, chamferRadius: 0.008), color: legC, name: "deskDrawer")
        drawer.position = SCNVector3(0.15, 0.66, 0)
        root.addChildNode(drawer)
        return root
    }

    /// Chair: seat, backrest, four legs.
    static func makeChairProp() -> SCNNode {
        let root = SCNNode(); root.name = "chairProp"
        let seatC = NSColor(calibratedRed: 0.50, green: 0.35, blue: 0.22, alpha: 1)
        let legC = NSColor(calibratedRed: 0.40, green: 0.28, blue: 0.18, alpha: 1)
        let seat = makeNode(SCNBox(width: 0.40, height: 0.035, length: 0.38, chamferRadius: 0.012), color: seatC, name: "chairSeat")
        seat.position = SCNVector3(0, 0.44, 0)
        root.addChildNode(seat)
        let back = makeNode(SCNBox(width: 0.38, height: 0.40, length: 0.03, chamferRadius: 0.012), color: seatC, name: "chairBack")
        back.position = SCNVector3(0, 0.66, -0.17)
        root.addChildNode(back)
        let legGeo = makeCyl(0.02, h: 0.42, segs: 10)
        for (i, off) in [(-0.16, -0.15), (0.16, -0.15), (-0.16, 0.15), (0.16, 0.15)].enumerated() {
            let leg = makeNode(legGeo.copy() as! SCNGeometry, color: legC, name: "chairLeg\(i)")
            leg.position = SCNVector3(Float(off.0), 0.22, Float(off.1))
            root.addChildNode(leg)
        }
        return root
    }

    /// Book/notebook: cover, page block, spine ridge.
    static func makeBookProp() -> SCNNode {
        let root = SCNNode(); root.name = "bookProp"
        let coverC = NSColor(calibratedRed: 0.18, green: 0.30, blue: 0.55, alpha: 1)
        let pageC = NSColor(calibratedWhite: 0.92, alpha: 1)
        let cover = makeNode(SCNBox(width: 0.18, height: 0.24, length: 0.025, chamferRadius: 0.004), color: coverC, name: "bookCover")
        cover.position = SCNVector3(0, 0.12, 0)
        root.addChildNode(cover)
        let pages = makeNode(SCNBox(width: 0.16, height: 0.22, length: 0.018, chamferRadius: 0.002), color: pageC, name: "bookPages")
        pages.position = SCNVector3(0.005, 0.12, 0)
        root.addChildNode(pages)
        let spine = makeNode(makeCyl(0.014, h: 0.24, segs: 10), color: coverC, name: "bookSpine")
        spine.position = SCNVector3(-0.09, 0.12, 0)
        root.addChildNode(spine)
        return root
    }

    /// Handheld camera: body box, lens barrel, torus ring, viewfinder, hotshoe.
    static func makeCameraProp() -> SCNNode {
        let root = SCNNode(); root.name = "cameraProp"
        let bodyC = NSColor(calibratedWhite: 0.22, alpha: 1)
        let lensC = NSColor(calibratedWhite: 0.12, alpha: 1)
        let detailC = NSColor(calibratedWhite: 0.45, alpha: 1)
        let body = makeNode(SCNBox(width: 0.18, height: 0.10, length: 0.08, chamferRadius: 0.01), color: bodyC, name: "cameraBody")
        body.position = SCNVector3(0, 0.05, 0)
        root.addChildNode(body)
        let lens = makeNode(makeCyl(0.032, h: 0.10, segs: 20), color: lensC, name: "cameraLens")
        lens.position = SCNVector3(0, 0.05, 0.09)
        lens.eulerAngles.x = .pi / 2
        root.addChildNode(lens)
        let ringGeo = SCNTorus(ringRadius: 0.034, pipeRadius: 0.006); ringGeo.ringSegmentCount = 24
        let ring = makeNode(ringGeo, color: detailC, name: "cameraRing")
        ring.position = SCNVector3(0, 0.05, 0.14)
        ring.eulerAngles.x = .pi / 2
        root.addChildNode(ring)
        let vf = makeNode(SCNBox(width: 0.04, height: 0.03, length: 0.035, chamferRadius: 0.005), color: bodyC, name: "cameraViewfinder")
        vf.position = SCNVector3(-0.04, 0.115, -0.01)
        root.addChildNode(vf)
        let shoe = makeNode(SCNBox(width: 0.06, height: 0.008, length: 0.03, chamferRadius: 0.002), color: detailC, name: "cameraHotshoe")
        shoe.position = SCNVector3(0.02, 0.105, 0)
        root.addChildNode(shoe)
        return root
    }

    /// Fallback prop: rounded box with a floating name label.
    static func makeGenericProp(named name: String) -> SCNNode {
        let root = SCNNode(); root.name = "genericProp_\(name)"
        let box = makeNode(SCNBox(width: 0.30, height: 0.30, length: 0.30, chamferRadius: 0.03),
                           color: NSColor(calibratedWhite: 0.60, alpha: 1), name: "genericBody")
        box.position = SCNVector3(0, 0.15, 0)
        root.addChildNode(box)
        let text = SCNText(string: name, extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: 0.12, weight: .medium)
        text.flatness = 0.15
        text.materials = [makeLabelMaterial(.white)]
        let lbl = SCNNode(geometry: text); lbl.name = "label"
        lbl.position = SCNVector3(-0.12, 0.34, 0)
        lbl.scale = SCNVector3(0.2, 0.2, 0.2)
        lbl.constraints = [SCNBillboardConstraint()]
        root.addChildNode(lbl)
        return root
    }

    // MARK: - Model Loader

    /// Loads a USDZ, OBJ, GLB, GLTF, or SCN model from disk. Returns `nil` on failure.
    static func loadModel(from url: URL) -> SCNNode? {
        let ext = url.pathExtension.lowercased()

        // GLB/GLTF: load through ModelIO, then convert to SCNScene.
        if ext == "glb" || ext == "gltf" {
            return loadModelViaModelIO(from: url)
        }

        var options: [SCNSceneSource.LoadingOption: Any] = [
            .checkConsistency: true,
            .flattenScene: false,
        ]
        if ext == "obj" {
            options[.createNormalsIfAbsent] = true
        }

        do {
            let scene = try SCNScene(url: url, options: options)
            return wrapSceneRoot(scene, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            NSLog("[Animate3DModelFactory] Failed to load model at \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadModelViaModelIO(from url: URL) -> SCNNode? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("[Animate3DModelFactory] ModelIO: file not found at \(url.path)")
            return nil
        }
        let mdlAsset = MDLAsset(url: url)
        mdlAsset.loadTextures()
        let scene = SCNScene(mdlAsset: mdlAsset)
        return wrapSceneRoot(scene, name: url.deletingPathExtension().lastPathComponent)
    }

    private static func wrapSceneRoot(_ scene: SCNScene, name: String) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = "loadedModel_\(name)"
        for child in scene.rootNode.childNodes {
            wrapper.addChildNode(child)
        }
        return wrapper
    }

    /// Attempts to load a bundled GLB model by filename (without extension) from the
    /// AnimateUI module's Resources/Models3D directory.
    static func loadBundledModel(named name: String) -> SCNNode? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "glb",
            subdirectory: "Resources/Models3D"
        ) else {
            // Try without subdirectory (depends on how SPM copies resources).
            guard let url = Bundle.module.url(forResource: name, withExtension: "glb") else {
                NSLog("[Animate3DModelFactory] Bundled model '\(name).glb' not found in bundle.")
                return nil
            }
            return loadModel(from: url)
        }
        return loadModel(from: url)
    }

    /// Returns a prop node for the given object name by trying:
    /// 1. A bundled GLB model matching the name
    /// 2. A built-in factory prop (desk, chair, book, camera)
    /// 3. A generic labeled box fallback
    ///
    /// Character-cutout objects (names containing "cutout") are treated as
    /// transparent placeholders — they get a small, unobtrusive marker instead of
    /// furniture geometry, since they represent character poses, not physical props.
    static func propForObjectName(_ name: String) -> SCNNode {
        let normalized = name.lowercased()

        // Character cutout objects are pose/state markers, not physical props.
        // Render them as small translucent markers so they don't obscure the scene.
        if normalized.contains("cutout") {
            return makeCutoutMarker(named: name)
        }

        // Split the name into whole words for matching to avoid
        // false positives like "seated" matching "seat".
        let words = Set(
            normalized
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )

        // Try bundled models first (match on whole words only).
        let bundledCandidates: [(keywords: Set<String>, file: String)] = [
            (["desk"], "kenney_desk"),
            (["chair", "seat"], "kenney_chair"),
            (["book", "logbook", "notebook", "journal"], "kenney_books"),
            (["table"], "kenney_table"),
            (["computer", "screen", "monitor"], "kenney_computerScreen"),
            (["bookcase", "shelf"], "kenney_bookcase"),
            (["pencil", "pen"], "Pencil"),
        ]
        for candidate in bundledCandidates {
            if !candidate.keywords.isDisjoint(with: words),
               let node = loadBundledModel(named: candidate.file) {
                return node
            }
        }

        // Fall back to programmatic props (whole-word match).
        if words.contains("desk") { return makeDeskProp() }
        if !words.isDisjoint(with: ["chair", "seat"]) { return makeChairProp() }
        if !words.isDisjoint(with: ["book", "logbook", "notebook", "journal"]) { return makeBookProp() }
        if !words.isDisjoint(with: ["camera", "lens"]) { return makeCameraProp() }

        return makeGenericProp(named: name)
    }

    /// Creates a small, translucent marker for character-cutout objects.
    /// These represent character poses/states (e.g. "mark-cutout-seated") and should
    /// not be rendered as physical furniture.
    private static func makeCutoutMarker(named name: String) -> SCNNode {
        let marker = SCNSphere(radius: 0.08)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.3)
        material.lightingModel = .constant
        material.blendMode = .alpha
        marker.materials = [material]

        let node = SCNNode(geometry: marker)
        node.name = "cutoutMarker"
        node.opacity = 0.4
        return node
    }

    // MARK: - Background Plane

    /// Creates a flat plane textured with `image`, positioned as a scene backdrop.
    /// Uses constant lighting so scene lights do not affect the image.
    static func makeBackgroundPlane(
        image: NSImage,
        width: CGFloat,
        height: CGFloat
    ) -> SCNNode {
        let planeGeo = SCNPlane(width: width, height: height)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.isDoubleSided = true
        material.transparencyMode = .dualLayer
        material.writesToDepthBuffer = false
        planeGeo.materials = [material]

        let node = SCNNode(geometry: planeGeo)
        node.name = "backgroundPlane"
        node.renderingOrder = -100
        return node
    }

    // MARK: - Private Helpers

    private static func makeSphere(_ r: CGFloat, segs: Int) -> SCNSphere {
        let s = SCNSphere(radius: r); s.segmentCount = segs; return s
    }

    private static func makeCyl(_ r: CGFloat, h: CGFloat, segs: Int = 16) -> SCNCylinder {
        let c = SCNCylinder(radius: r, height: h); c.radialSegmentCount = segs; return c
    }

    /// Creates an SCNNode with physically-based material applied.
    private static func makeNode(
        _ geometry: SCNGeometry,
        color: NSColor,
        name: String
    ) -> SCNNode {
        geometry.materials = [makePBRMaterial(color)]
        let node = SCNNode(geometry: geometry)
        node.name = name
        return node
    }

    /// Clean physically-based material with matte finish.
    private static func makePBRMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = NSNumber(value: 0.7)
        m.metalness.contents = NSNumber(value: 0.0)
        m.ambientOcclusion.intensity = 0.3
        m.isDoubleSided = false
        return m
    }

    /// Unlit label material for floating text.
    private static func makeLabelMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color.blended(withFraction: 0.15, of: .white) ?? color
        m.emission.contents = color.withAlphaComponent(0.7)
        m.isDoubleSided = true
        return m
    }
}
