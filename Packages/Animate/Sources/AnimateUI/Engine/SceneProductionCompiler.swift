import Foundation
import simd

// MARK: - Scene Production Compiler
// Compiles parsed scene directions + shot data into a deterministic 3D production plan
// with camera choreography, character blocking, object placement, and depth assignments.

// MARK: - Input / Output Types

@available(macOS 26.0, *)
struct SceneProductionCharacterInput: Sendable, Hashable {
    var name: String
    var slug: String
    var preferredCostumeName: String?
}

@available(macOS 26.0, *)
struct SceneProductionInput: Sendable {
    var sceneName: String
    var sceneID: UUID
    var lyrics: String
    var directions: [SceneDirection]
    var shots: [AnimationSceneShot]
    var characterSlugs: [String]
    var characterCast: [SceneProductionCharacterInput] = []
    var objectSetups: [ObjectSetup]
    var backgroundName: String?
    // 3D pipeline fields archived — were: worldChunk, styleProfile, cameraPresets, lightRig, atmospherePreset
    var availableCameraPresetCount: Int = 0
    var baseFPS: Int
    var totalBeats: Int
    var bpm: Double
}

@available(macOS 26.0, *)
struct SceneProductionPlan: Sendable {
    var sceneID: UUID, sceneName: String, backgroundName: String?, totalFrames: Int, baseFPS: Int
    // 3D pipeline fields archived — were: worldChunk, styleProfile, lightRig, atmospherePreset
    var availableCameraPresetCount: Int
    var characterBlocking: [CharacterBlockingPlan]
    var cameraChoreography: CameraChoreographyPlan
    var objectPlacements: [ObjectPlacementPlan]
    var depthAssignments: [DepthAssignment]
    var frameRateProfile: VariableFrameRateProfile
}

@available(macOS 26.0, *)
struct CharacterBlockingPlan: Sendable {
    var characterName: String, characterSlug: String, preferredCostumeName: String?
    var entranceFrame: Int, exitFrame: Int?
    var keyPositions: [BlockingKeyframe]
    var actingBeats: [ActingBeat]
    var lipsyncBeats: [CharacterLipsyncBeat]
    var holdStyle: AnimationHoldStyle
}

@available(macOS 26.0, *)
struct BlockingKeyframe: Sendable {
    var frame: Int, position: SIMD3<Double>, facing: FacingDirection
    var pose: String, emotion: String, easing: EasingCurve
}

@available(macOS 26.0, *)
struct ActingBeat: Sendable {
    var startFrame: Int, endFrame: Int, action: String, intensity: Double
}

@available(macOS 26.0, *)
struct CameraChoreographyPlan: Sendable {
    var keyframes: [CameraKeyframe]
    struct CameraKeyframe: Sendable {
        var frame: Int, focalLength: Double
        var position: SIMD3<Double>, lookAt: SIMD3<Double>, roll: Double
        var movement: CameraMovement, easing: EasingCurve, shotType: CameraShot
        var shotIntent: ShotIntent?, focusCharacter: String?
    }
}

@available(macOS 26.0, *)
struct ObjectPlacementPlan: Sendable {
    var objectName: String, position: SIMD3<Double>, scale: Double
    var depthLayer: String, attachedTo: String?, visibleFrameRange: ClosedRange<Int>?
}

@available(macOS 26.0, *)
struct DepthAssignment: Sendable {
    var elementName: String, elementType: ElementType, depthLayer: String, zPosition: Double
    enum ElementType: String, Sendable { case character, object, background }
}

// MARK: - Stage Coordinate System
// Width: -5..+5, Depth: 0..-10 (0=front), Height: 0=floor, 2.0=head

@available(macOS 26.0, *)
private enum Stage {
    static let width: Double = 10.0, minX: Double = -5.0
    static let actionZ: Double = -3.0, fgZ: Double = -1.0
    static let nearBgZ: Double = -6.0, farBgZ: Double = -9.0
    static let centerY: Double = 1.0, camY: Double = 1.5

    static func worldX(_ n: Double) -> Double { minX + n * width }
    static func charPos(_ sp: StagePosition) -> SIMD3<Double> {
        SIMD3<Double>(worldX(sp.normalizedX), 0, actionZ)
    }
    static func lookAtChar(_ p: SIMD3<Double>) -> SIMD3<Double> { SIMD3<Double>(p.x, centerY, p.z) }
    static func lookAtCenter() -> SIMD3<Double> { SIMD3<Double>(0, centerY, actionZ) }

    static func camPos(_ shot: CameraShot, lookX: Double = 0) -> SIMD3<Double> {
        let d: Double = switch shot {
        case .extremeWide: 12; case .wide: 10; case .medium: 8
        case .mediumClose: 6; case .close: 4.5; case .extremeClose: 3
        }
        return SIMD3<Double>(lookX * 0.3, camY, d)
    }
    static func layerZ(_ l: String) -> Double {
        switch l {
        case "foreground": fgZ; case "actionPlane": actionZ
        case "nearBackground": nearBgZ; default: farBgZ
        }
    }
}

// MARK: - Compiler

@available(macOS 26.0, *)
enum SceneProductionCompiler {
    static func compile(_ input: SceneProductionInput) -> SceneProductionPlan {
        let total = computeTotalFrames(input)
        let t = TC(bpm: input.bpm, fps: input.baseFPS, total: total)
        let blocking = compileBlocking(input, t)
        let cam = compileCameraChoreography(input, blocking, t)
        let obj = compileObjects(input)
        let depth = compileDepth(blocking, obj, input)
        let fr = compileFrameRate(blocking)
        return SceneProductionPlan(
            sceneID: input.sceneID,
            sceneName: input.sceneName,
            backgroundName: input.backgroundName,
            totalFrames: total, baseFPS: input.baseFPS,
            availableCameraPresetCount: input.availableCameraPresetCount,
            characterBlocking: blocking, cameraChoreography: cam,
            objectPlacements: obj, depthAssignments: depth, frameRateProfile: fr)
    }

    // MARK: Timing Context

    private struct TC: Sendable {
        var bpm: Double, fps: Int, total: Int
        var fpBeat: Double { Double(fps) * 60.0 / max(1, bpm) }
        var fpBar: Double { fpBeat * 4.0 }
        func barF(_ b: Int) -> Int { Int(Double(max(0, b - 1)) * fpBar) }

        func range(_ d: SceneDirection) -> (start: Int, end: Int)? {
            if let v = d.parameters["bars"] { return DirectionTiming.parse(v).toFrameRange(fps: fps, bpm: bpm) }
            if let v = d.parameters["bar"], let b = Int(v) { let s = barF(b); return (s, s + Int(fpBar)) }
            if let v = d.parameters["beats"] { return DirectionTiming.parse("beats:\(v)").toFrameRange(fps: fps, bpm: bpm) }
            if let v = d.parameters["frames"] { return DirectionTiming.parse("frames:\(v)").toFrameRange(fps: fps, bpm: bpm) }
            return nil
        }
    }

    private static func computeTotalFrames(_ input: SceneProductionInput) -> Int {
        let fpBeat = Double(input.baseFPS) * 60.0 / max(1, input.bpm)
        return max(Int(Double(input.totalBeats) * fpBeat), input.shots.map(\.endFrame).max() ?? 0, input.baseFPS)
    }

    // MARK: Character Blocking

    private static func compileBlocking(_ input: SceneProductionInput, _ t: TC) -> [CharacterBlockingPlan] {
        var charactersByCanonicalKey: [String: SceneProductionCharacterInput] = [:]
        for character in input.characterCast {
            charactersByCanonicalKey[canonicalCharacterKey(character.slug)] = character
        }
        for slug in input.characterSlugs where charactersByCanonicalKey[canonicalCharacterKey(slug)] == nil {
            let cleaned = cleanedCharacterIdentifier(slug)
            let fallback = SceneProductionCharacterInput(
                name: cleaned,
                slug: normalizedFallbackSlug(cleaned),
                preferredCostumeName: nil
            )
            charactersByCanonicalKey[canonicalCharacterKey(fallback.slug)] = fallback
        }
        for d in input.directions where [.enter,.exit,.move,.emotion,.action,.gesture,.lipsync].contains(d.tag) {
            let raw = cleanedCharacterIdentifier(d.primaryValue)
            guard !raw.isEmpty else { continue }
            let resolved = resolveCharacter(raw, from: input.characterCast) ?? SceneProductionCharacterInput(
                name: raw,
                slug: normalizedFallbackSlug(raw),
                preferredCostumeName: nil
            )
            charactersByCanonicalKey[canonicalCharacterKey(resolved.slug)] = resolved
        }
        return charactersByCanonicalKey.values
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .enumerated()
            .map { i, character in
                blocking(for: character, input.directions, t, i)
            }
    }

    private static func blocking(
        for character: SceneProductionCharacterInput,
        _ dirs: [SceneDirection],
        _ t: TC,
        _ idx: Int
    ) -> CharacterBlockingPlan {
        let name = character.name
        let slug = character.slug
        let relevant = dirs.filter {
            matchesCharacter($0.primaryValue, character: character)
        }
        var kps: [BlockingKeyframe] = [], beats: [ActingBeat] = [], lipsyncBeats: [CharacterLipsyncBeat] = []
        var eFrame = 0, xFrame: Int?, curPos = defaultPos(idx), curFace: FacingDirection = .camera, curEmo = "neutral"

        func inferF(_ d: SceneDirection) -> Int {
            guard !dirs.isEmpty else { return 0 }
            let i = dirs.firstIndex(where: { $0.id == d.id }) ?? 0
            return min(Int(Double(i) / Double(max(1, dirs.count)) * Double(t.total)), max(0, t.total - 1))
        }
        func kf(_ frame: Int, _ pos: SIMD3<Double>, _ pose: String, _ ease: EasingCurve) {
            kps.append(BlockingKeyframe(frame: frame, position: pos, facing: curFace, pose: pose, emotion: curEmo, easing: ease))
        }
        func easing(_ s: String?) -> EasingCurve { resolveEasing(s) }

        for d in relevant {
            switch d.tag {
            case .enter:
                curPos = stagePos(d.parameters["position"]) ?? curPos
                curFace = facing(d.parameters["facing"]) ?? .camera
                curEmo = d.parameters["emotion"] ?? "neutral"
                eFrame = t.range(d)?.start ?? 0
                kf(eFrame, Stage.charPos(curPos), "standing", .easeOut)
            case .exit:
                let r = t.range(d); xFrame = r?.start ?? t.total
                let off: StagePosition = d.parameters["direction"] == "left" ? .offscreenLeft : .offscreenRight
                kf(xFrame!, Stage.charPos(off), "walking", .easeIn)
            case .move:
                let from = stagePos(d.parameters["from"]) ?? curPos
                let to = stagePos(d.parameters["to"]) ?? curPos; curPos = to
                let e = easing(d.parameters["easing"])
                if let r = t.range(d) {
                    kf(r.start, Stage.charPos(from), "walking", e)
                    kf(r.end, Stage.charPos(to), "standing", e)
                } else {
                    kf(inferF(d), Stage.charPos(to), "standing", e)
                }
            case .emotion:
                let expr = d.parameters["expression"] ?? d.primaryValue.trimmingCharacters(in: .init(charactersIn: "\""))
                if !expr.isEmpty { curEmo = expr }
                let f = t.range(d)?.start ?? inferF(d)
                if let last = kps.last {
                    kps.append(BlockingKeyframe(frame: f, position: last.position, facing: last.facing,
                                                pose: last.pose, emotion: curEmo, easing: .easeInOut))
                }
            case .action:
                let desc = d.parameters["description"] ?? d.primaryValue.trimmingCharacters(in: .init(charactersIn: "\""))
                if let r = t.range(d) {
                    beats.append(ActingBeat(startFrame: r.start, endFrame: r.end, action: desc, intensity: actionIntensity(desc)))
                } else {
                    let f = inferF(d)
                    beats.append(ActingBeat(startFrame: f, endFrame: f + Int(t.fpBar), action: desc, intensity: actionIntensity(desc)))
                }
            case .gesture:
                let gt = d.parameters["type"] ?? "gesture"
                let f = t.range(d)?.start ?? inferF(d)
                let ef = t.range(d)?.end ?? (f + Int(t.fpBeat * 2))
                beats.append(ActingBeat(startFrame: f, endFrame: ef, action: gt, intensity: 0.6))
            case .lipsync:
                let mode = d.parameters["mode"] ?? "speech"
                let songName = d.parameters["song"]
                let f = t.range(d)?.start ?? inferF(d)
                let ef = max(f + 1, t.range(d)?.end ?? (f + Int(t.fpBar)))
                lipsyncBeats.append(
                    CharacterLipsyncBeat(
                        startFrame: f,
                        endFrame: ef,
                        mode: mode,
                        songName: songName
                    )
                )
            default: break
            }
        }
        kps.sort { $0.frame < $1.frame }
        beats.sort { $0.startFrame < $1.startFrame }
        lipsyncBeats.sort { $0.startFrame < $1.startFrame }
        if kps.isEmpty { kf(0, Stage.charPos(defaultPos(idx)), "standing", .linear) }
        return CharacterBlockingPlan(characterName: name, characterSlug: slug, preferredCostumeName: character.preferredCostumeName,
            entranceFrame: eFrame, exitFrame: xFrame, keyPositions: kps,
            actingBeats: beats, lipsyncBeats: lipsyncBeats, holdStyle: .onTwos)
    }

    // MARK: Camera Choreography

    private static func compileCameraChoreography(
        _ input: SceneProductionInput, _ blocking: [CharacterBlockingPlan], _ t: TC
    ) -> CameraChoreographyPlan {
        typealias CKF = CameraChoreographyPlan.CameraKeyframe
        var kfs: [CKF] = []

        for shot in input.shots.sorted(by: { $0.startFrame < $1.startFrame }) {
            let st = shot.cameraShot ?? shot.shotIntent?.recommendedCameraShot ?? .medium
            let intent = shot.shotIntent; let mv = intent?.recommendedCameraMovement ?? .hold
            let fc = focusChar(shot.focusCharacterSlug, blocking, shot.startFrame)
            let la = charLookAt(fc, shot.startFrame, blocking)
            let cp = Stage.camPos(st, lookX: la.x)
            let fl = focalLength(for: st, input: input)
            kfs.append(CKF(frame: shot.startFrame, focalLength: fl, position: cp, lookAt: la,
                           roll: 0, movement: mv, easing: .easeInOut, shotType: st,
                           shotIntent: intent, focusCharacter: fc))
            if mv != .hold {
                let ela = charLookAt(fc, shot.endFrame, blocking)
                let ecp = movedCamPos(mv, cp, ela)
                kfs.append(CKF(frame: shot.endFrame, focalLength: focalAfter(mv, fl), position: ecp,
                               lookAt: ela, roll: 0, movement: .hold, easing: .easeInOut,
                               shotType: st, shotIntent: intent, focusCharacter: fc))
            }
        }
        for d in input.directions where d.tag == .camera {
            if let pair = compileCamDir(d, t, input) { kfs.append(contentsOf: pair) }
        }
        if kfs.isEmpty {
            let fl = AnimationCamera.focalRange(for: .wide).mid
            kfs.append(CKF(frame: 0, focalLength: fl, position: Stage.camPos(.wide),
                           lookAt: Stage.lookAtCenter(), roll: 0, movement: .hold,
                           easing: .easeInOut, shotType: .wide, shotIntent: .establishing, focusCharacter: nil))
        }
        kfs.sort { $0.frame < $1.frame }
        // Deduplicate: keep last-written per frame
        var seen = Set<Int>(); var deduped: [CKF] = []
        for kf in kfs.reversed() { if seen.insert(kf.frame).inserted { deduped.append(kf) } }
        return CameraChoreographyPlan(keyframes: deduped.reversed())
    }

    private static func compileCamDir(
        _ d: SceneDirection,
        _ t: TC,
        _ input: SceneProductionInput
    ) -> [CameraChoreographyPlan.CameraKeyframe]? {
        typealias CKF = CameraChoreographyPlan.CameraKeyframe
        let mv = CameraMovement(rawValue: d.primaryValue.trimmingCharacters(in: .init(charactersIn: "\"")).lowercased()) ?? .hold
        let from = CameraShot(rawValue: d.parameters["from"] ?? "") ?? .medium
        let to = CameraShot(rawValue: d.parameters["to"] ?? "") ?? from
        guard let r = t.range(d) else { return nil }
        let la = Stage.lookAtCenter(); let e = resolveEasing(d.parameters["easing"])
        return [
            CKF(frame: r.start, focalLength: focalLength(for: from, input: input),
                position: Stage.camPos(from), lookAt: la, roll: 0, movement: mv,
                easing: e, shotType: from, shotIntent: nil, focusCharacter: nil),
            CKF(frame: r.end, focalLength: focalLength(for: to, input: input),
                position: Stage.camPos(to), lookAt: la, roll: 0, movement: .hold,
                easing: e, shotType: to, shotIntent: nil, focusCharacter: nil),
        ]
    }

    // MARK: Objects

    private static func compileObjects(_ input: SceneProductionInput) -> [ObjectPlacementPlan] {
        var ps = input.objectSetups.map { s -> ObjectPlacementPlan in
            let layer = s.zOrder < 0 ? "foreground" : s.zOrder > 5 ? "nearBackground" : "actionPlane"
            let vr: ClosedRange<Int>? = s.exitFrame.map { s.enterFrame...$0 }
            return ObjectPlacementPlan(objectName: s.objectName,
                position: SIMD3<Double>(Stage.worldX(s.initialX), s.initialY * 2.0, Stage.layerZ(layer)),
                scale: 1.0, depthLayer: layer, attachedTo: s.attachmentTarget, visibleFrameRange: vr)
        }
        for d in input.directions where d.tag == .object {
            let n = d.primaryValue.trimmingCharacters(in: .init(charactersIn: "\""))
            guard !ps.contains(where: { $0.objectName.lowercased() == n.lowercased() }) else { continue }
            let sp = stagePos(d.parameters["position"])
            let x = sp.map { Stage.worldX($0.normalizedX) } ?? 0
            let y = (d.parameters["y"].flatMap(Double.init) ?? 0.62) * 2.0
            let layer = d.parameters["layer"] ?? "actionPlane"
            ps.append(ObjectPlacementPlan(objectName: n,
                position: SIMD3<Double>(x, y, Stage.layerZ(layer)),
                scale: 1.0, depthLayer: layer, attachedTo: nil, visibleFrameRange: nil))
        }
        return ps
    }

    // MARK: Depth & Frame Rate

    private static func compileDepth(_ blocking: [CharacterBlockingPlan],
                                     _ objects: [ObjectPlacementPlan],
                                     _ input: SceneProductionInput) -> [DepthAssignment] {
        var a = blocking.map { DepthAssignment(elementName: $0.characterName, elementType: .character,
                                               depthLayer: "actionPlane", zPosition: Stage.actionZ) }
        a += objects.map { DepthAssignment(elementName: $0.objectName, elementType: .object,
                                           depthLayer: $0.depthLayer, zPosition: $0.position.z) }
        if let bg = input.backgroundName {
            a.append(DepthAssignment(elementName: bg, elementType: .background,
                                     depthLayer: "farBackground", zPosition: Stage.farBgZ))
        }
        return a
    }

    private static func compileFrameRate(_ blocking: [CharacterBlockingPlan]) -> VariableFrameRateProfile {
        var styles: [String: AnimationHoldStyle] = [:]
        for (i, c) in blocking.enumerated() { styles[c.characterSlug] = i < 2 ? .onTwos : .onThrees }
        return VariableFrameRateProfile(characterHoldStyles: styles, defaultCharacterHold: .onTwos,
                                        cameraHold: .onOnes, backgroundHold: .onThrees, defaultObjectHold: .onTwos)
    }

    // MARK: Helpers

    private static func stagePos(_ s: String?) -> StagePosition? {
        s.flatMap { $0.isEmpty ? nil : StagePosition.from($0) }
    }
    private static func facing(_ s: String?) -> FacingDirection? {
        s.flatMap { FacingDirection(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) }
    }
    private static func resolveEasing(_ s: String?) -> EasingCurve {
        guard let s, !s.isEmpty else { return .easeInOut }
        switch s.lowercased().trimmingCharacters(in: .whitespaces) {
        case "linear": return .linear
        case "ease_in": return .easeIn
        case "ease_out": return .easeOut
        case "ease_in_out": return .easeInOut
        case "stepped": return .stepped
        default: return .easeInOut
        }
    }

    private static func focalLength(for shot: CameraShot, input: SceneProductionInput) -> Double {
        // 3D camera presets archived — fall through to default focal range
        return AnimationCamera.focalRange(for: shot).mid
    }
    private static let stagePositions: [StagePosition] = [.center,.centerLeft,.centerRight,.left,.right,.stageLeft,.stageRight]
    private static func defaultPos(_ i: Int) -> StagePosition { stagePositions[i % stagePositions.count] }

    private static func actionIntensity(_ a: String) -> Double {
        let l = a.lowercased()
        if ["fight","attack","explode","scream","rage"].contains(where: l.contains) { return 1.0 }
        if ["run","chase","shout","confront","storm"].contains(where: l.contains) { return 0.8 }
        if ["walk","point","gesture","present"].contains(where: l.contains) { return 0.5 }
        if ["nod","turn","look","listen","sit"].contains(where: l.contains) { return 0.3 }
        return 0.4
    }

    private static func focusChar(_ slug: String?, _ blocking: [CharacterBlockingPlan], _ frame: Int) -> String? {
        if let s = slug, let m = blocking.first(where: { $0.characterSlug == s }) { return m.characterName }
        return blocking.first { frame >= $0.entranceFrame && ($0.exitFrame == nil || frame <= $0.exitFrame!) }?.characterName
    }

    private static func charLookAt(_ name: String?, _ frame: Int, _ blocking: [CharacterBlockingPlan]) -> SIMD3<Double> {
        guard let name, let plan = blocking.first(where: { $0.characterName == name }),
              let pos = interpPos(plan, frame) else { return Stage.lookAtCenter() }
        return Stage.lookAtChar(pos)
    }

    private static func interpPos(_ plan: CharacterBlockingPlan, _ frame: Int) -> SIMD3<Double>? {
        guard let first = plan.keyPositions.first, let last = plan.keyPositions.last else { return nil }
        if frame <= first.frame { return first.position }
        if frame >= last.frame { return last.position }
        for i in 0..<(plan.keyPositions.count - 1) {
            let a = plan.keyPositions[i], b = plan.keyPositions[i + 1]
            if frame >= a.frame && frame <= b.frame {
                let span = Double(b.frame - a.frame); guard span > 0 else { return a.position }
                return simd_mix(a.position, b.position, SIMD3<Double>(repeating: Double(frame - a.frame) / span))
            }
        }
        return last.position
    }

    private static func movedCamPos(_ mv: CameraMovement, _ cp: SIMD3<Double>, _ la: SIMD3<Double>) -> SIMD3<Double> {
        switch mv {
        case .zoomIn:  return cp + simd_normalize(la - cp) * 1.5
        case .zoomOut: return cp - simd_normalize(la - cp) * 1.5
        case .panLeft: return SIMD3<Double>(cp.x - 1, cp.y, cp.z)
        case .panRight: return SIMD3<Double>(cp.x + 1, cp.y, cp.z)
        case .panUp:   return SIMD3<Double>(cp.x, cp.y + 0.5, cp.z)
        case .panDown: return SIMD3<Double>(cp.x, cp.y - 0.5, cp.z)
        case .track:   return SIMD3<Double>(la.x * 0.3, cp.y, cp.z)
        case .shake, .hold: return cp
        }
    }
    private static func focalAfter(_ mv: CameraMovement, _ base: Double) -> Double {
        switch mv { case .zoomIn: min(135, base + 15); case .zoomOut: max(18, base - 15); default: base }
    }

    private static func resolveCharacter(
        _ raw: String,
        from cast: [SceneProductionCharacterInput]
    ) -> SceneProductionCharacterInput? {
        let target = canonicalCharacterKey(raw)
        return cast.first(where: { character in
            canonicalCharacterKey(character.name) == target || canonicalCharacterKey(character.slug) == target
        })
    }

    private static func matchesCharacter(
        _ raw: String,
        character: SceneProductionCharacterInput
    ) -> Bool {
        let target = canonicalCharacterKey(raw)
        return canonicalCharacterKey(character.name) == target
            || canonicalCharacterKey(character.slug) == target
    }

    private static func cleanedCharacterIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .init(charactersIn: "\"' "))
    }

    private static func normalizedFallbackSlug(_ value: String) -> String {
        cleanedCharacterIdentifier(value)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    private static func canonicalCharacterKey(_ value: String) -> String {
        cleanedCharacterIdentifier(value)
            .lowercased()
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}
