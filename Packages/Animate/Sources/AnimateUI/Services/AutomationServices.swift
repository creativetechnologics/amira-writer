import Foundation
import ProjectKit

@available(macOS 26.0, *)
enum AutomationSourceResolver {
    @MainActor
    static func projectSummary(store: AnimateStore, projectRoot: URL) -> AutomationProjectSummary {
        let scenes = store.scenes
        let shots = scenes.flatMap(\.shots)
        let songsCount = countFiles(in: projectRoot.appendingPathComponent("Songs"), extension: "ows")
        let characterRigCount = countRigJSON(in: projectRoot.appendingPathComponent("Characters"))
        var warnings: [String] = []
        let world = worldContext(projectRoot: projectRoot, warnings: &warnings)
        if let period = world?.timePeriod.lowercased(), period.contains("mid-2020s") {
            warnings.append("Canonical Places/places-world-context.json contains mid-2020s language; automation will not use stale duplicates, but the canonical file should be corrected.")
        }
        return AutomationProjectSummary(
            projectRoot: projectRoot.path,
            scenesCount: scenes.count,
            shotsCount: shots.count,
            placesCount: store.backgrounds.count,
            songsCount: songsCount,
            characterRigCount: characterRigCount,
            scenesWithBackgroundID: scenes.filter { $0.backgroundID != nil }.count,
            shotsWithPopulatedShotFrameGeneration: shots.filter { $0.shotFrameGeneration != nil }.count,
            shotsWithPopulatedShotBackgroundPlate: shots.filter { $0.shotBackgroundPlate != nil }.count,
            worldContext: world,
            warnings: warnings
        )
    }

    static func worldContext(projectRoot: URL, warnings: inout [String]) -> AutomationWorldContext? {
        let paths = ProjectPaths(root: projectRoot)
        let canonical = paths.placesWorldContextJSON
        let ignored = duplicateWorldContextPaths(projectRoot: projectRoot, canonical: canonical)
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            warnings.append("Missing canonical Places/places-world-context.json; refusing to silently fall back to stale duplicates/default mid-2020s context.")
            return nil
        }
        do {
            let data = try Data(contentsOf: canonical)
            let blocks = try JSONDecoder().decode(PlacesWorldContextBlocks.self, from: data)
            return AutomationWorldContext(
                sourcePath: canonical.path,
                timePeriod: blocks.timePeriod,
                environmental: blocks.environmental,
                aesthetic: blocks.aesthetic,
                ignoredDuplicatePaths: ignored
            )
        } catch {
            warnings.append("Could not read canonical Places/places-world-context.json: \(error.localizedDescription)")
            return nil
        }
    }

    static func automationDirectory(projectRoot: URL, component: String) -> URL {
        ProjectPaths(root: projectRoot).animate.appendingPathComponent(component, isDirectory: true)
    }

    private static func duplicateWorldContextPaths(projectRoot: URL, canonical: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "places-world-context.json",
                  url.standardizedFileURL.path != canonical.standardizedFileURL.path else { continue }
            paths.append(url.path)
        }
        return paths.sorted()
    }

    private static func countFiles(in directory: URL, extension ext: String) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        return urls.filter { $0.pathExtension.lowercased() == ext.lowercased() }.count
    }

    private static func countRigJSON(in directory: URL) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        return urls.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("rig.json").path) }.count
    }
}

@available(macOS 26.0, *)
@MainActor
struct EffectiveShotSpecBuilder {
    var store: AnimateStore

    func build(scene: AnimationScene, shotIndex: Int, projectRoot: URL) -> EffectiveShotSpec {
        let shot = scene.shots[shotIndex]
        var warnings: [String] = []
        let world = AutomationSourceResolver.worldContext(projectRoot: projectRoot, warnings: &warnings)
        let background = scene.backgroundID.flatMap { id in store.backgrounds.first { $0.id == id } }
        let focus = focusedCharacter(for: shot, scene: scene)
        let sceneCharacters = characters(for: scene, focus: focus)
        let action = firstNonEmpty(shot.sourceLyricExcerpt, shot.notes, shot.name) ?? shot.name
        let region = firstNonEmpty(world?.environmental, background?.geographicPlacement, background?.geographicPosition) ?? "Persian-Afghan highland valley world context must be supplied by Places/places-world-context.json."
        let materials = joinedNonEmpty([
            background?.visualBrief,
            background?.physicalDescription,
            background?.physicalLayoutAndTopography,
            background?.coreIdentity,
            background?.keyPropsSetDressing
        ], separator: "\n")
        let lighting = firstNonEmpty(background?.visualPaletteLighting, background?.timeOfDay, background?.dayLabel, world?.aesthetic) ?? "Natural cinematic light; keep time of day consistent with the scene."
        let camera = joinedNonEmpty([
            shot.cameraShot?.displayName,
            background?.cameraFramingNotes,
            shot.shotIntent?.displayName
        ], separator: "; ")
        let styleLock = animatedLookPrompt(projectRoot: projectRoot)
        let visualTone = joinedNonEmpty([
            world?.aesthetic,
            styleLock.map { "Animated style lock from Settings/animated-look-prompt.json:\n\($0)" }
        ], separator: "\n\n")
        let resolvedVisualTone = visualTone.isEmpty ? "Grounded cinematic visual tone." : visualTone
        var blockers: [AutomationBlocker] = []
        if scene.backgroundID == nil {
            blockers.append(.init(code: .blockedMissingPlace, message: "Scene has no backgroundID; automation cannot resolve a canonical place.", field: "backgroundID"))
        } else if background == nil {
            blockers.append(.init(code: .blockedMissingPlace, message: "Scene backgroundID does not match a loaded place/background.", field: "backgroundID"))
        }
        if (shot.focusCharacterID != nil || shot.focusCharacterSlug != nil), focus == nil {
            blockers.append(.init(code: .blockedMissingCharacter, message: "Shot focus character does not match a loaded character package.", field: "focusCharacter"))
        }
        if world == nil {
            blockers.append(.init(code: .blockedMissingReferenceRole, message: "Missing canonical world context from Places/places-world-context.json.", field: "worldContext"))
        }
        let negativeGuardrails = guardrails(world: world, background: background)
        let prompt = Self.prompt(
            scene: scene,
            shot: shot,
            background: background,
            focus: focus,
            characters: sceneCharacters,
            action: action,
            worldPeriod: world?.timePeriod ?? "UNKNOWN — read Places/places-world-context.json before executing paid generation.",
            region: region,
            materials: materials,
            lighting: lighting,
            camera: camera,
            visualTone: resolvedVisualTone,
            negativeGuardrails: negativeGuardrails
        )
        return EffectiveShotSpec(
            id: shot.id,
            createdAt: Date(),
            source: "Scenes/scenes.json",
            sceneID: scene.id,
            sceneName: scene.name,
            shotID: shot.id,
            shotIndex: shotIndex,
            shotName: shot.name,
            startFrame: shot.startFrame,
            endFrame: shot.endFrame,
            backgroundID: scene.backgroundID,
            backgroundName: background?.name,
            approvedPlaceImagePath: resolvedPath(background?.approvedImagePath, projectRoot: projectRoot),
            focusCharacterID: shot.focusCharacterID ?? focus?.id,
            focusCharacterSlug: shot.focusCharacterSlug ?? focus?.owpSlug,
            focusCharacterName: focus?.name,
            characterIDs: sceneCharacters.map(\.id),
            characterSlugs: sceneCharacters.map { characterSlug($0) },
            characterNames: sceneCharacters.map(\.name),
            cameraShot: shot.cameraShot?.rawValue,
            shotIntent: shot.shotIntent?.rawValue,
            action: action,
            notes: shot.notes,
            lyricExcerpt: shot.sourceLyricExcerpt,
            worldPeriod: world?.timePeriod ?? "",
            regionalWorldCues: region,
            architectureMaterials: materials,
            lighting: lighting,
            cameraFraming: camera,
            visualTone: resolvedVisualTone,
            negativeGuardrails: negativeGuardrails,
            prompt: prompt,
            blockers: blockers
        )
    }

    func write(_ spec: EffectiveShotSpec, projectRoot: URL) throws -> URL {
        let dir = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "shot-specs")
            .appendingPathComponent(spec.sceneID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(spec.shotID.uuidString).json")
        try writeCodable(spec, to: url)
        return url
    }

    private func focusedCharacter(for shot: AnimationSceneShot, scene: AnimationScene) -> AnimationCharacter? {
        if let id = shot.focusCharacterID,
           let match = store.characters.first(where: { $0.id == id }) { return match }
        if let slug = shot.focusCharacterSlug?.lowercased(), !slug.isEmpty,
           let match = store.characters.first(where: { characterSlug($0).lowercased() == slug || $0.owpSlug.lowercased() == slug }) { return match }
        if let id = scene.characterIDs.first,
           let match = store.characters.first(where: { $0.id == id }) { return match }
        if let slug = scene.characterSlugs.first?.lowercased(),
           let match = store.characters.first(where: { characterSlug($0).lowercased() == slug || $0.owpSlug.lowercased() == slug }) { return match }
        return nil
    }

    private func characters(for scene: AnimationScene, focus: AnimationCharacter?) -> [AnimationCharacter] {
        var result: [AnimationCharacter] = []
        if let focus { result.append(focus) }
        for id in scene.characterIDs {
            if let c = store.characters.first(where: { $0.id == id }), !result.contains(where: { $0.id == c.id }) { result.append(c) }
        }
        for slug in scene.characterSlugs.map({ $0.lowercased() }) {
            if let c = store.characters.first(where: { characterSlug($0).lowercased() == slug || $0.owpSlug.lowercased() == slug }), !result.contains(where: { $0.id == c.id }) { result.append(c) }
        }
        return result
    }

    private func guardrails(world: AutomationWorldContext?, background: BackgroundPlate?) -> [String] {
        var values: [String] = []
        if let world {
            values += world.timePeriod.components(separatedBy: .newlines).dropFirst().map { String($0) }
        }
        values.append(background?.imageGenerationGuardrails ?? "")
        values.append("No text overlays, no captions, no logos, no collage panels.")
        values.append("Do not rely on the project title as shorthand; use only the explicit world, place, character, camera, and action details in this spec.")
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func prompt(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        background: BackgroundPlate?,
        focus: AnimationCharacter?,
        characters: [AnimationCharacter],
        action: String,
        worldPeriod: String,
        region: String,
        materials: String,
        lighting: String,
        camera: String,
        visualTone: String,
        negativeGuardrails: [String]
    ) -> String {
        let characterText = characters.isEmpty
            ? "No named focus character resolved for this shot."
            : characters.map { "\($0.name) (slug: \(characterSlug($0))) — \($0.description)" }.joined(separator: "\n")
        return [
            "Create a single animation pipeline frame for Amira Writer automation.",
            "Scene: \(scene.name)",
            "Shot: \(shot.name)",
            "Action beat: \(action)",
            "World period / technology rules: \(worldPeriod)",
            "Regional/world cues: \(region)",
            "Place: \(background?.name ?? "UNRESOLVED PLACE")",
            "Architecture/materials/topography: \(materials.isEmpty ? "Use the resolved place record; do not invent a generic setting." : materials)",
            "Characters: \(characterText)",
            "Camera/framing: \(camera.isEmpty ? "Use the shot's existing camera metadata and keep geography readable." : camera)",
            "Lighting: \(lighting)",
            "Visual tone: \(visualTone)",
            "Negative guardrails: \(negativeGuardrails.joined(separator: " | "))"
        ].joined(separator: "\n")
    }
}

@available(macOS 26.0, *)
struct ShotSpecValidationService {
    func validate(_ spec: EffectiveShotSpec) -> [AutomationBlocker] {
        spec.blockers
    }
}

@available(macOS 26.0, *)
@MainActor
struct ReferenceContractResolver {
    var store: AnimateStore

    func resolve(spec: EffectiveShotSpec, projectRoot: URL, write: Bool = true) throws -> (contract: ReferenceContract, url: URL?) {
        let existing = readExisting(sceneID: spec.sceneID, shotID: spec.shotID, projectRoot: projectRoot)
        let rejectedKeys = Set((existing?.references ?? [])
            .filter { $0.status == .rejected }
            .map(referenceKey))
        var candidates: [ReferenceContractItem] = []
        candidates.append(contentsOf: (existing?.references ?? []).filter { $0.status == .pinned })
        candidates.append(contentsOf: storyboardReferences(spec: spec, projectRoot: projectRoot))
        candidates.append(contentsOf: generatedContinuityReferences(spec: spec))
        candidates.append(contentsOf: placeReferences(spec: spec, projectRoot: projectRoot))
        candidates.append(contentsOf: registryReferences(spec: spec, projectRoot: projectRoot))
        candidates.append(contentsOf: characterReferences(spec: spec, projectRoot: projectRoot))
        // Style text is embedded directly in EffectiveShotSpec.prompt from
        // Settings/animated-look-prompt.json. Do not add that JSON file as an
        // image reference, or later paid phases could try to upload a non-image.
        candidates = deduplicated(candidates).filter { item in
            item.status == .pinned || !rejectedKeys.contains(referenceKey(item))
        }
        let selected = quotaLimited(candidates, maxReferences: 8, quotas: ReferenceContract.defaultRoleQuotas)
        let rejectedAudit = (existing?.references ?? []).filter { $0.status == .rejected }
        var contract = ReferenceContract(
            sceneID: spec.sceneID,
            shotID: spec.shotID,
            shotIndex: spec.shotIndex,
            references: deduplicated(selected + rejectedAudit),
            blockers: spec.blockers
        )
        if !contract.usableReferences.contains(where: { $0.role == .locationIdentity }) {
            contract.blockers.append(.init(code: .blockedMissingReferenceRole, message: "No location_identity reference resolved for this shot.", field: "references.location_identity"))
        }
        let url = write ? try writeContract(contract, projectRoot: projectRoot) : nil
        return (contract, url)
    }

    func contractURL(sceneID: UUID, shotID: UUID, projectRoot: URL) -> URL {
        AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "reference-contracts")
            .appendingPathComponent(sceneID.uuidString, isDirectory: true)
            .appendingPathComponent("\(shotID.uuidString).json")
    }

    func readExisting(sceneID: UUID, shotID: UUID, projectRoot: URL) -> ReferenceContract? {
        let url = contractURL(sceneID: sceneID, shotID: shotID, projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReferenceContract.self, from: data)
    }

    private func writeContract(_ contract: ReferenceContract, projectRoot: URL) throws -> URL {
        let url = contractURL(sceneID: contract.sceneID, shotID: contract.shotID, projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeCodable(contract, to: url)
        return url
    }

    private func storyboardReferences(spec: EffectiveShotSpec, projectRoot: URL) -> [ReferenceContractItem] {
        let paths = ProjectPaths(root: projectRoot)
        return StoryboardFrame.allCases.compactMap { frame in
            let url = paths.shotStoryboardImage(sceneID: spec.sceneID, shotID: spec.shotID, frame: frame)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ReferenceContractItem(role: .storyboardLayout, path: url.path, label: "Storyboard \(frame.rawValue)", priority: 20, source: "same-shot storyboard")
        }
    }

    private func generatedContinuityReferences(spec: EffectiveShotSpec) -> [ReferenceContractItem] {
        guard let gallery = store.imagineGallery(for: spec.sceneID, shotIndex: spec.shotIndex) else { return [] }
        return ImagineShotMoment.allCases.flatMap { moment in
            gallery.paths(for: moment).compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? ReferenceContractItem(role: .shotContinuity, path: path, label: "Approved/generated \(moment.rawValue) frame", priority: 30, source: "same-shot generated frame")
                    : nil
            }
        }
    }

    private func placeReferences(spec: EffectiveShotSpec, projectRoot: URL) -> [ReferenceContractItem] {
        guard let id = spec.backgroundID,
              let bg = store.backgrounds.first(where: { $0.id == id }) else { return [] }
        var refs: [ReferenceContractItem] = []
        for path in [bg.approvedImagePath, bg.animatedApprovedImagePath].compactMap({ $0 }) {
            if let resolved = resolvedPath(path, projectRoot: projectRoot) {
                refs.append(.init(role: .locationIdentity, path: resolved, label: bg.name, priority: 40, source: "approved place image"))
            }
        }
        for ref in bg.referenceImages.prefix(3) {
            if let resolved = resolvedPath(ref.imagePath, projectRoot: projectRoot) {
                refs.append(.init(role: .locationIdentity, path: resolved, label: ref.title.isEmpty ? bg.name : ref.title, priority: 45, source: "place reference image", guidance: ref.notes))
            }
        }
        return refs
    }

    private func registryReferences(spec: EffectiveShotSpec, projectRoot: URL) -> [ReferenceContractItem] {
        let url = ProjectPaths(root: projectRoot).animate.appendingPathComponent("reference-registry.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backgrounds = object["backgrounds"] as? [[String: Any]] else { return [] }
        let text = [spec.shotName, spec.action, spec.backgroundName ?? "", spec.regionalWorldCues, spec.architectureMaterials].joined(separator: " ").lowercased()
        let wantsMap = text.contains("outdoor") || text.contains("valley") || text.contains("road") || text.contains("river") || text.contains("bridge") || text.contains("geography") || text.contains("ridge")
        let wantsBridge = text.contains("bridge") || (spec.backgroundName?.lowercased().contains("bridge") ?? false)
        var refs: [ReferenceContractItem] = []
        for entry in backgrounds {
            let name = (entry["name"] as? String ?? "").lowercased()
            guard (name == "map" && wantsMap) || (name == "bridge" && wantsBridge) else { continue }
            let role: ReferenceRole = name == "map" ? .spatialMap : .landmarkDesign
            let priority = name == "map" ? 50 : 55
            let guidance = entry["guidance"] as? String
            for file in (entry["files"] as? [[String: Any]] ?? []) {
                if let path = file["absolute_path"] as? String, FileManager.default.fileExists(atPath: path) {
                    refs.append(.init(role: role, path: path, label: "registry \(name)", priority: priority, source: "reference-registry.json", guidance: guidance))
                }
            }
        }
        return refs
    }

    private func characterReferences(spec: EffectiveShotSpec, projectRoot: URL) -> [ReferenceContractItem] {
        let wanted = Set((spec.characterSlugs + [spec.focusCharacterSlug].compactMap { $0 }).map { $0.lowercased() })
        guard !wanted.isEmpty else { return [] }
        var refs: [ReferenceContractItem] = []
        for character in store.characters where wanted.contains(characterSlug(character).lowercased()) || wanted.contains(character.owpSlug.lowercased()) {
            for path in ([character.profileImagePath, character.inspirationReferenceImagePath] + character.referenceImagePaths.prefix(2).map(Optional.init)).compactMap({ $0 }) {
                if let resolved = resolvedPath(path, projectRoot: projectRoot) {
                    refs.append(.init(role: .characterIdentity, path: resolved, label: character.name, priority: 60, source: "character package"))
                }
            }
            if let approved = character.masterReferenceSheetVariants.first(where: { $0.id == character.approvedMasterReferenceSheetVariantID }) ?? character.masterReferenceSheetVariants.last,
               let resolved = resolvedPath(approved.imagePath, projectRoot: projectRoot) {
                refs.append(.init(role: .characterIdentity, path: resolved, label: "\(character.name) master sheet", priority: 61, source: "character master reference sheet"))
            }
            for costume in character.costumeReferenceSets.prefix(2) {
                let approved = costume.approvedSheetVariant ?? costume.sheetVariants.last
                for path in ([approved?.imagePath] + costume.costumeReferenceImagePaths.prefix(1).map(Optional.init)).compactMap({ $0 }) {
                    if let resolved = resolvedPath(path, projectRoot: projectRoot) {
                        refs.append(.init(role: .characterCostume, path: resolved, label: "\(character.name) costume: \(costume.name)", priority: 65, source: "character costume package"))
                    }
                }
            }
        }
        return refs
    }

    private func styleReferences(projectRoot: URL) -> [ReferenceContractItem] {
        let url = ProjectPaths(root: projectRoot).animatedLookPromptJSON
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return [.init(role: .style, path: url.path, label: "Animated look prompt", priority: 90, source: "Settings/animated-look-prompt.json")]
    }

    private func quotaLimited(_ candidates: [ReferenceContractItem], maxReferences: Int, quotas: [ReferenceRole: Int]) -> [ReferenceContractItem] {
        var selected: [ReferenceContractItem] = []
        var counts: [ReferenceRole: Int] = [:]
        for item in candidates.sorted(by: { lhs, rhs in
            if lhs.status == .pinned && rhs.status != .pinned { return true }
            if lhs.status != .pinned && rhs.status == .pinned { return false }
            return lhs.priority < rhs.priority
        }) {
            if selected.count >= maxReferences { break }
            let quota = quotas[item.role] ?? 1
            if item.status != .pinned && (counts[item.role] ?? 0) >= quota { continue }
            selected.append(item)
            counts[item.role, default: 0] += 1
        }
        return selected
    }

    private func deduplicated(_ items: [ReferenceContractItem]) -> [ReferenceContractItem] {
        var seen = Set<String>()
        return items.filter { seen.insert(referenceKey($0)).inserted }
    }

    private func referenceKey(_ item: ReferenceContractItem) -> String { "\(item.role.rawValue)|\(item.path)" }
}

@available(macOS 26.0, *)
@MainActor
struct ShotFramePlanBuilder {
    var store: AnimateStore

    func buildPlans(spec: EffectiveShotSpec, contract: ReferenceContract, projectRoot: URL, imageSize: String) -> ShotFrameGenerationPlanSet {
        let references = contract.usableReferences
            .filter { $0.role != .style }
            .map(\.path)
        let gallery = store.imagineGallery(for: spec.sceneID, shotIndex: spec.shotIndex)
        let previousGallery = spec.shotIndex > 0 ? store.imagineGallery(for: spec.sceneID, shotIndex: spec.shotIndex - 1) : nil
        let cameraShot = spec.cameraShot.flatMap(CameraShot.init(rawValue:))
        let plans = ImagineShotMoment.allCases.map { moment in
            ShotFrameGenerationPlanResolver.resolve(
                input: .init(
                    projectRoot: projectRoot,
                    sceneID: spec.sceneID,
                    shotID: spec.shotID,
                    shotIndex: spec.shotIndex,
                    moment: moment,
                    prompt: spec.prompt,
                    gallery: gallery,
                    previousShotGallery: previousGallery,
                    automaticReferenceImagePaths: references,
                    manualReferenceCount: contract.usableReferences.filter { $0.status == .pinned }.count,
                    cameraShot: cameraShot,
                    cameraMovement: nil,
                    generatedImageSize: imageSize
                )
            )
        }
        return ShotFrameGenerationPlanSet(sceneID: spec.sceneID, shotID: spec.shotID, plans: plans)
    }

    func write(_ planSet: ShotFrameGenerationPlanSet, projectRoot: URL) throws -> URL {
        let dir = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "shot-frame-plans")
            .appendingPathComponent(planSet.sceneID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(planSet.shotID.uuidString).json")
        try writeCodable(planSet, to: url)
        return url
    }
}

@available(macOS 26.0, *)
struct AutomationDryRunShotResult: Codable, Sendable, Hashable {
    var effectiveShotSpec: EffectiveShotSpec
    var effectiveShotSpecPath: String?
    var referenceContract: ReferenceContract
    var referenceContractPath: String?
    var shotFrameGenerationPlanSet: ShotFrameGenerationPlanSet
    var shotFrameGenerationPlanPath: String?
    var estimatedVertexCostUSD: Double
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
struct AutomationDryRunReport: Codable, Sendable, Hashable {
    var schemaVersion: Int = 1
    var generatedAt: Date = Date()
    var mode: String = "dry_run"
    var model: String
    var imageSize: String
    var projectSummary: AutomationProjectSummary
    var shots: [AutomationDryRunShotResult]
    var estimatedVertexCostUSD: Double
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
func characterSlug(_ character: AnimationCharacter) -> String {
    (character.storageSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? character.storageSlug : nil) ?? character.owpSlug
}

@available(macOS 26.0, *)
func resolvedPath(_ raw: String?, projectRoot: URL) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if raw.hasPrefix("/") { return FileManager.default.fileExists(atPath: raw) ? raw : raw }
    return projectRoot.appendingPathComponent(raw).path
}

@available(macOS 26.0, *)
func firstNonEmpty(_ values: String?...) -> String? {
    values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
}

@available(macOS 26.0, *)
func joinedNonEmpty(_ values: [String?], separator: String) -> String {
    values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: separator)
}

@available(macOS 26.0, *)
func animatedLookPrompt(projectRoot: URL) -> String? {
    let url = ProjectPaths(root: projectRoot).animatedLookPromptJSON
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["prompt"] as? String
}

@available(macOS 26.0, *)
func writeCodable<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

@available(macOS 26.0, *)
struct AutomationFrameGenerationRunResponse: Codable, Sendable, Hashable {
    var schemaVersion: Int = 1
    var generatedAt: Date = Date()
    var ok: Bool
    var mode: String
    var isDryRun: Bool
    var model: String
    var imageSize: String
    var estimatedCostUSD: Double
    var maxCostUSD: Double?
    var records: [GeneratedFrameRecord]
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
@MainActor
struct AutomationFrameGenerationService {
    var store: AnimateStore

    func run(
        projectRoot: URL,
        sceneFilter: Set<UUID>?,
        shotFilter: UUID?,
        moments requestedMoments: [ImagineShotMoment],
        model: GeminiModel,
        imageSize: String,
        mode: String,
        maxCostUSD: Double?,
        maxFrames: Int?
    ) async -> AutomationFrameGenerationRunResponse {
        let isExecute = mode == "execute"
        let isDryRun = !isExecute
        var records: [GeneratedFrameRecord] = []
        var blockers: [AutomationBlocker] = []
        let moments = requestedMoments.isEmpty ? [.beginning] : requestedMoments
        let frameLimit = max(1, maxFrames ?? 48)

        guard !isExecute || store.isGeminiAllowed() else {
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: 0,
                maxCostUSD: maxCostUSD,
                records: [],
                blockers: [.init(code: .failedProviderError, message: "Gemini image generation is disabled. Enable it in Inspector > Tools before execute mode.", field: "geminiAllowed")]
            )
        }

        if isExecute, let configurationError = store.geminiImageGenerationAvailabilityError {
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: 0,
                maxCostUSD: maxCostUSD,
                records: [],
                blockers: [.init(code: .failedProviderError, message: configurationError.localizedDescription, field: "geminiConfiguration")]
            )
        }

        guard !isExecute || maxCostUSD != nil else {
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: 0,
                maxCostUSD: nil,
                records: [],
                blockers: [.init(code: .blockedCostCap, message: "execute mode requires maxCostUSD.", field: "maxCostUSD")]
            )
        }

        let specBuilder = EffectiveShotSpecBuilder(store: store)
        let referenceResolver = ReferenceContractResolver(store: store)
        let scenesToRun = store.scenes.filter { scene in sceneFilter?.contains(scene.id) ?? true }
        var frameInputs: [(scene: AnimationScene, shotIndex: Int, spec: EffectiveShotSpec, contract: ReferenceContract, referenceContractPath: String?)] = []
        let momentCount = max(1, moments.count)
        let shotInputLimit = max(1, Int(ceil(Double(frameLimit) / Double(momentCount))))
        var hitFrameLimit = false

        sceneLoop:
        for scene in scenesToRun {
            for index in scene.shots.indices {
                let shot = scene.shots[index]
                if let shotFilter, shot.id != shotFilter { continue }
                guard frameInputs.count < shotInputLimit else {
                    hitFrameLimit = true
                    break sceneLoop
                }
                let spec = specBuilder.build(scene: scene, shotIndex: index, projectRoot: projectRoot)
                do {
                    let resolved = try referenceResolver.resolve(spec: spec, projectRoot: projectRoot, write: true)
                    frameInputs.append((scene, index, spec, resolved.contract, resolved.url?.path))
                } catch {
                    blockers.append(.init(code: .failedProviderError, message: "Reference resolve failed for shot \(shot.name): \(error.localizedDescription)", field: "references"))
                }
            }
        }

        if hitFrameLimit {
            blockers.append(.init(code: .blockedCostCap, message: "Frame request was capped at maxFrames=\(frameLimit).", field: "maxFrames", severity: "warning"))
        }

        let plannedFrameCount = min(frameInputs.count * momentCount, frameLimit)
        let estimatedCost = Double(plannedFrameCount) * model.estimatedCost(for: imageSize)
        if let maxCostUSD, estimatedCost > maxCostUSD {
            blockers.append(.init(code: .blockedCostCap, message: "Estimated Vertex cost $\(String(format: "%.4f", estimatedCost)) exceeds cap $\(String(format: "%.2f", maxCostUSD)).", field: "maxCostUSD"))
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: estimatedCost,
                maxCostUSD: maxCostUSD,
                records: records,
                blockers: blockers
            )
        }

        let generator = ImagineGenerationService()
        for input in frameInputs {
            var workingGallery = store.imagineGallery(for: input.scene.id, shotIndex: input.shotIndex)
                ?? ImagineSceneShotGallery(shotID: input.scene.shots[input.shotIndex].id, sceneID: input.scene.id)
            let previousGallery = input.shotIndex > 0 ? store.imagineGallery(for: input.scene.id, shotIndex: input.shotIndex - 1) : nil
            let referencePaths = input.contract.usableReferences
                .filter { $0.role != .style }
                .map(\.path)
            let sceneSlug = sceneSlug(for: input.scene)

            for moment in moments {
                guard records.count < frameLimit else { break }
                let plan = ShotFrameGenerationPlanResolver.resolve(
                    input: .init(
                        projectRoot: projectRoot,
                        sceneID: input.scene.id,
                        shotID: input.scene.shots[input.shotIndex].id,
                        shotIndex: input.shotIndex,
                        moment: moment,
                        prompt: input.spec.prompt,
                        gallery: workingGallery,
                        previousShotGallery: previousGallery,
                        automaticReferenceImagePaths: referencePaths,
                        manualReferenceCount: input.contract.usableReferences.filter { $0.status == .pinned }.count,
                        cameraShot: input.spec.cameraShot.flatMap(CameraShot.init(rawValue:)),
                        cameraMovement: nil,
                        generatedImageSize: imageSize
                    )
                )
                var record = makeRecord(
                    sceneID: input.scene.id,
                    shotID: input.scene.shots[input.shotIndex].id,
                    shotIndex: input.shotIndex,
                    moment: moment,
                    plan: plan,
                    model: model,
                    imageSize: imageSize,
                    referenceContractPath: input.referenceContractPath,
                    estimatedCostUSD: model.estimatedCost(for: plan.openMattePlan?.generatedImageSize ?? imageSize),
                    status: isDryRun ? "planned" : "running"
                )

                let missingEditSource = moment != .beginning
                    && plan.decision.reasons.contains(.sourceImageMissing)
                    && !plan.decision.reasons.contains(.hardContinuityBreak)
                if missingEditSource || !plan.canExecute {
                    record.status = "blocked"
                    record.blockers.append(.init(code: .blockedMissingEditSource, message: "\(moment.rawValue) needs an approved/readable prior frame for edit continuity before execution.", field: "sourceImage"))
                    records.append(record)
                    if isExecute { try? writeFrameRecord(record, projectRoot: projectRoot) }
                    continue
                }

                if isDryRun {
                    records.append(record)
                    continue
                }

                var activityID: UUID?
                do {
                    try writeFrameRecord(record, projectRoot: projectRoot)
                    activityID = store.registerGeminiActivity(
                        kind: .immediate,
                        title: "\(input.scene.name) • Shot \(input.shotIndex + 1) • \(moment.rawValue)",
                        source: "Automation Frames API"
                    )
                    store.logGeminiAPICall(endpoint: "image-generation", source: "AutomationFrameGenerationService.run()")
                    let savedURL = try await generator.generateWithGemini(
                        plan: plan,
                        manualReferenceImages: [],
                        model: model,
                        apiKey: store.geminiAPIKey,
                        owpURL: projectRoot,
                        sceneSlug: sceneSlug,
                        shotIndex: input.shotIndex,
                        moment: moment
                    )
                    workingGallery.appendPath(savedURL.path, for: moment)
                    record.status = "completed"
                    record.updatedAt = Date()
                    record.outputPath = savedURL.path
                    record.promptPath = savedURL.deletingPathExtension().appendingPathExtension("prompt.txt").path
                    record.responsePath = savedURL.deletingPathExtension().appendingPathExtension("response.txt").path
                    record.planPath = savedURL.deletingPathExtension().appendingPathExtension("plan.json").path
                    try writeFrameRecord(record, projectRoot: projectRoot)
                    registerGeneratedShotImage(savedURL, scene: input.scene, shotIndex: input.shotIndex, moment: moment, mode: plan.mode.rawValue)
                    if let activityID {
                        store.updateGeminiActivity(activityID, status: .completed, outputFilename: savedURL.lastPathComponent)
                    }
                    records.append(record)
                } catch {
                    record.status = "failed_provider_error"
                    record.updatedAt = Date()
                    record.errorMessage = error.localizedDescription
                    record.blockers.append(.init(code: .failedProviderError, message: error.localizedDescription, field: "provider"))
                    try? writeFrameRecord(record, projectRoot: projectRoot)
                    if let activityID {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
                    }
                    records.append(record)
                }
                await Task.yield()
            }
            if isExecute {
                store.refreshImagineGalleryFromDisk(sceneID: input.scene.id)
            }
        }

        let hasBlockingRecords = records.contains { record in
            record.status == "blocked" || record.status.hasPrefix("failed")
        }
        return .init(
            ok: blockers.filter { $0.severity == "blocking" }.isEmpty && !hasBlockingRecords,
            mode: mode,
            isDryRun: isDryRun,
            model: model.rawValue,
            imageSize: imageSize,
            estimatedCostUSD: estimatedCost,
            maxCostUSD: maxCostUSD,
            records: records,
            blockers: blockers
        )
    }

    private func makeRecord(
        sceneID: UUID,
        shotID: UUID,
        shotIndex: Int,
        moment: ImagineShotMoment,
        plan: ShotFrameGenerationPlan,
        model: GeminiModel,
        imageSize: String,
        referenceContractPath: String?,
        estimatedCostUSD: Double,
        status: String
    ) -> GeneratedFrameRecord {
        .init(
            sceneID: sceneID,
            shotID: shotID,
            shotIndex: shotIndex,
            moment: moment.rawValue,
            provider: "gemini",
            model: model.rawValue,
            imageSize: plan.openMattePlan?.generatedImageSize ?? imageSize,
            aspectRatio: plan.openMattePlan?.generatedAspectRatio ?? ShotFrameOpenMattePlan.defaultGeneratedAspectRatio,
            generationMode: plan.mode.rawValue,
            status: status,
            estimatedCostUSD: estimatedCostUSD,
            referenceContractPath: referenceContractPath,
            referencePaths: plan.referenceImagePaths,
            blockers: plan.canExecute ? [] : [.init(code: .blockedMissingEditSource, message: "Plan cannot execute without a readable source image.", field: "sourceImage")]
        )
    }

    private func registerGeneratedShotImage(
        _ url: URL,
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment,
        mode: String
    ) {
        guard shotIndex >= 0, shotIndex < scene.shots.count else { return }
        let shot = scene.shots[shotIndex]
        store.registerImageAsset(
            path: url.standardizedFileURL.path,
            linkKind: .sceneShotImage,
            ownerID: shot.id.uuidString,
            ownerParentID: scene.id.uuidString,
            moment: moment.directoryName,
            workflow: "automation_frame_generation",
            context: [
                "sceneID": scene.id.uuidString,
                "sceneName": scene.name,
                "shotID": shot.id.uuidString,
                "shotName": shot.name,
                "shotOrder": "\(shotIndex + 1)",
                "moment": moment.directoryName,
                "generator": "gemini",
                "mode": mode
            ]
        )
    }
}

@available(macOS 26.0, *)
func generatedFrameRecordURL(projectRoot: URL, sceneID: UUID, shotID: UUID, moment: ImagineShotMoment) -> URL {
    AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "generated-frames")
        .appendingPathComponent(sceneID.uuidString, isDirectory: true)
        .appendingPathComponent(shotID.uuidString, isDirectory: true)
        .appendingPathComponent("\(moment.directoryName)-latest.json")
}

@available(macOS 26.0, *)
func writeFrameRecord(_ record: GeneratedFrameRecord, projectRoot: URL) throws {
    guard let moment = ImagineShotMoment(rawValue: record.moment) else { return }
    let url = generatedFrameRecordURL(projectRoot: projectRoot, sceneID: record.sceneID, shotID: record.shotID, moment: moment)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeCodable(record, to: url)
}

@available(macOS 26.0, *)
func readFrameRecord(projectRoot: URL, sceneID: UUID, shotID: UUID, moment: ImagineShotMoment) -> GeneratedFrameRecord? {
    let url = generatedFrameRecordURL(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, moment: moment)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(GeneratedFrameRecord.self, from: data)
}

@available(macOS 26.0, *)
func sceneSlug(for scene: AnimationScene) -> String {
    scene.name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
}
