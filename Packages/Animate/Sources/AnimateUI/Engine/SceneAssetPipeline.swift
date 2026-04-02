import AppKit
import SceneKit
import simd

// MARK: - Scene Assembly

/// Output of `SceneAssetPipeline.assembleScene(compiledScene:frame:camera:)`.
/// Contains all positioned SceneKit nodes and metadata the renderer needs
/// to build a complete frame. Used exclusively on `@MainActor`.
@available(macOS 26.0, *)
struct SceneAssembly {
    var backgroundNode: SCNNode?
    var characterNodes: [(name: String, node: SCNNode, position: SIMD3<Double>)]
    var propNodes: [(name: String, node: SCNNode, position: SIMD3<Double>)]
    var cameraState: AnimationCamera
    var depthLayers: [SceneDepthLayer]
}

// MARK: - Scene Asset Pipeline

/// Loads, caches, and assembles 3D assets for the animation engine.
///
/// Handles character models (from Meshi.ai GLB exports or USDZ/OBJ),
/// prop geometry, and background plates. All loaded models are cached
/// by key so repeated frame renders avoid redundant I/O.
///
/// SceneKit requires main-thread access, hence `@MainActor`.
@available(macOS 26.0, *)
@MainActor
final class SceneAssetPipeline {

    /// Loaded character models keyed by character slug.
    private var characterModels: [String: SCNNode] = [:]
    private var characterPerformanceProfiles: [String: Character3DPerformanceProfile?] = [:]
    private var characterPerformanceProfileSources: [String: [URL]] = [:]
    private var registryProjectURL: URL?
    private var assetRegistry = Animate3DAssetRegistry()
    private var characterRegistry = Animate3DCharacterRegistry()
    private var motionRegistry = Animate3DMotionRegistry()

    /// Loaded prop models keyed by object name.
    private var propModels: [String: SCNNode] = [:]
    private var projectRelativeModels: [String: SCNNode] = [:]

    /// Background plates keyed by background name.
    private var backgroundPlates: [String: NSImage] = [:]

    /// The store reference for resolving paths and querying project data.
    private weak var store: AnimateStore?

    /// Supported 3D model file extensions, ordered by preference.
    /// GLB is primary (Meshi.ai default), followed by USDZ and OBJ.
    private static let supportedModelExtensions = ["glb", "usdz", "obj"]
    private static let performanceProfileFileNames = [
        "performance-profile.json",
        "face-performance.json"
    ]

    init(store: AnimateStore) {
        self.store = store
    }
}

// MARK: - Character Model Loading

@available(macOS 26.0, *)
extension SceneAssetPipeline {
    func invalidateRegistryDrivenCaches() {
        registryProjectURL = nil
        assetRegistry = Animate3DAssetRegistry()
        characterRegistry = Animate3DCharacterRegistry()
        motionRegistry = Animate3DMotionRegistry()
        characterModels.removeAll()
        characterPerformanceProfiles.removeAll()
        characterPerformanceProfileSources.removeAll()
        projectRelativeModels.removeAll()
    }

    /// Loads a character's 3D model from their character package on disk.
    ///
    /// Search order:
    /// 1. Check the in-memory cache.
    /// 2. If a `costumeName` is provided, look for a matching `Character3DModel`
    ///    entry on the character; otherwise use the first available model.
    /// 3. Resolve the file at `Animate/characters/<slug>/models/<filename>`.
    /// 4. Fall back to scanning the models directory for any supported file.
    /// 5. Load via `Animate3DModelFactory.loadModel(from:)`.
    /// 6. Apply anime-style materials and normalise to standard height.
    /// 7. Cache and return.
    ///
    /// Returns `nil` if no model file is found or loading fails.
    func loadCharacterModel(slug: String, costumeName: String? = nil) -> SCNNode? {
        let cacheKey = costumeName.map { "\(slug)/\($0)" } ?? slug
        if let cached = characterModels[cacheKey] {
            return cached
        }

        guard let store else { return nil }
        ensureRegistriesLoaded()

        // Find the character record.
        guard let character = store.characters.first(where: {
            $0.assetFolderSlug == slug || $0.owpSlug == slug
        }) else {
            return nil
        }

        // Resolve the model file URL.
        let modelURL: URL? = resolveModelURL(
            for: character,
            slug: slug,
            costumeName: costumeName
        )

        guard let url = modelURL else { return nil }

        guard let node = Animate3DModelFactory.loadModel(from: url) else {
            NSLog("[SceneAssetPipeline] Failed to load model for '\(slug)' at \(url.path)")
            return nil
        }

        applyAnimeMaterials(to: node)
        normalizeScale(node: node)

        characterModels[cacheKey] = node
        return node
    }

    /// Returns a character node — the loaded 3D model if available, otherwise
    /// a mannequin placeholder coloured to match the character.
    func characterNode(
        slug: String,
        costumeName: String? = nil,
        color: NSColor
    ) -> SCNNode {
        if let loaded = loadCharacterModel(slug: slug, costumeName: costumeName) {
            return loaded.clone()
        }
        return Animate3DModelFactory.makeHumanoidPlaceholder(color: color)
    }

    func loadCharacterPerformanceProfile(
        slug: String,
        costumeName: String? = nil
    ) -> Character3DPerformanceProfile? {
        let cacheKey = costumeName.map { "\(slug)/\($0)" } ?? slug
        if let cached = characterPerformanceProfiles[cacheKey] {
            return cached
        }

        guard let store,
              let character = store.characters.first(where: {
                  $0.assetFolderSlug == slug || $0.owpSlug == slug
              }) else {
            characterPerformanceProfiles[cacheKey] = nil
            characterPerformanceProfileSources[cacheKey] = []
            return nil
        }
        ensureRegistriesLoaded()

        let urls = resolvePerformanceProfileURLs(for: character, slug: slug, costumeName: costumeName)
        let profiles = urls.compactMap { url -> Character3DPerformanceProfile? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Character3DPerformanceProfile.self, from: data)
        }

        let mergedProfile = profiles.reduce(Character3DPerformanceProfile?.none) {
            (partial: Character3DPerformanceProfile?, next: Character3DPerformanceProfile) in
            if let partial {
                return partial.merging(next)
            }
            return next
        }

        guard let profile = mergedProfile else {
            characterPerformanceProfiles[cacheKey] = nil
            characterPerformanceProfileSources[cacheKey] = []
            return nil
        }

        characterPerformanceProfiles[cacheKey] = profile
        characterPerformanceProfileSources[cacheKey] = urls
        return profile
    }

    func hasCharacterPerformanceProfile(
        slug: String,
        costumeName: String? = nil
    ) -> Bool {
        loadCharacterPerformanceProfile(slug: slug, costumeName: costumeName) != nil
    }

    func characterPerformanceProfileSourceFileName(
        slug: String,
        costumeName: String? = nil
    ) -> String? {
        let cacheKey = costumeName.map { "\(slug)/\($0)" } ?? slug
        if characterPerformanceProfiles[cacheKey] == nil,
           characterPerformanceProfileSources[cacheKey] == nil {
            _ = loadCharacterPerformanceProfile(slug: slug, costumeName: costumeName)
        }
        let sourceURLs = characterPerformanceProfileSources[cacheKey] ?? []
        guard !sourceURLs.isEmpty else {
            return nil
        }
        return sourceURLs.map(\.lastPathComponent).joined(separator: ", ")
    }

    func characterPerformanceProfileSourceRelativePath(
        slug: String,
        costumeName: String? = nil
    ) -> String? {
        let relativePaths = characterPerformanceProfileSourceRelativePaths(
            slug: slug,
            costumeName: costumeName
        )
        guard !relativePaths.isEmpty else { return nil }
        return relativePaths.joined(separator: ", ")
    }

    func characterPerformanceProfileSourceRelativePaths(
        slug: String,
        costumeName: String? = nil
    ) -> [String] {
        guard let store,
              let animateURL = store.animateURL else {
            return []
        }
        let cacheKey = costumeName.map { "\(slug)/\($0)" } ?? slug
        if characterPerformanceProfiles[cacheKey] == nil,
           characterPerformanceProfileSources[cacheKey] == nil {
            _ = loadCharacterPerformanceProfile(slug: slug, costumeName: costumeName)
        }
        let sourceURLs = characterPerformanceProfileSources[cacheKey] ?? []
        guard !sourceURLs.isEmpty else { return [] }
        let basePath = animateURL.path.hasSuffix("/") ? animateURL.path : animateURL.path + "/"
        return sourceURLs.map { sourceURL in
            let sourcePath = sourceURL.path
            guard sourcePath.hasPrefix(basePath) else {
                return sourceURL.lastPathComponent
            }
            return "Animate/" + String(sourcePath.dropFirst(basePath.count))
        }
    }

    func characterPerformanceProfileSourceCount(
        slug: String,
        costumeName: String? = nil
    ) -> Int {
        characterPerformanceProfileSourceRelativePaths(
            slug: slug,
            costumeName: costumeName
        ).count
    }

    func resolveMotionSet(
        actionCue: String?,
        poseCue: String?
    ) -> (descriptor: Animate3DMotionSetDescriptor, provenance: String)? {
        ensureRegistriesLoaded()

        let candidates = [actionCue, poseCue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { value in
                let parts = value
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
                return [value] + parts
            }

        let orderedCandidates = Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
        for candidate in orderedCandidates where !candidate.isEmpty {
            if let tagMatch = motionRegistry.motions.first(where: { descriptor in
                descriptor.tags.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }) {
                return (descriptor: tagMatch, provenance: "tag:\(candidate)")
            }
            if let idMatch = motionRegistry.motions.first(where: { descriptor in
                descriptor.motionID.caseInsensitiveCompare(candidate) == .orderedSame
            }) {
                return (descriptor: idMatch, provenance: "id:\(candidate)")
            }
            if let titleMatch = motionRegistry.motions.first(where: { descriptor in
                descriptor.title.lowercased().contains(candidate)
            }) {
                return (descriptor: titleMatch, provenance: "title:\(candidate)")
            }
        }

        return nil
    }

    func characterModelFileName(
        slug: String,
        costumeName: String? = nil
    ) -> String? {
        ensureRegistriesLoaded()
        if let bundle = bundleDescriptor(for: slug, costumeName: costumeName),
           let registryFileName = normalizedRegistryPath(bundle.bodyModelPath).map({
               URL(fileURLWithPath: $0).lastPathComponent
           }),
           !registryFileName.isEmpty {
            return registryFileName
        }
        guard let store,
              let character = store.characters.first(where: {
                  $0.assetFolderSlug == slug || $0.owpSlug == slug
              }) else {
            return nil
        }
        if let costumeName {
            return character.models3D.first(where: { $0.costumeName == costumeName })?.modelFileName
        }
        return character.models3D.first?.modelFileName
    }

    func resolvedBundleDescriptor(
        slug: String,
        costumeName: String? = nil
    ) -> Animate3DCharacterBundleDescriptor? {
        ensureRegistriesLoaded()
        return bundleDescriptor(for: slug, costumeName: costumeName)
    }

    func characterModelSourceRelativePath(
        slug: String,
        costumeName: String? = nil
    ) -> String? {
        ensureRegistriesLoaded()
        guard let store,
              let character = store.characters.first(where: {
                  $0.assetFolderSlug == slug || $0.owpSlug == slug
              }),
              let sourceURL = resolveModelURL(for: character, slug: slug, costumeName: costumeName) else {
            return nil
        }
        return relativePath(for: sourceURL)
    }

    // MARK: Private — Model File Resolution

    /// Resolves the on-disk URL for a character's 3D model file.
    private func resolveModelURL(
        for character: AnimationCharacter,
        slug: String,
        costumeName: String?
    ) -> URL? {
        if let bundle = bundleDescriptor(for: slug, costumeName: costumeName),
           let registryURL = registryRelativeURL(for: bundle.bodyModelPath) {
            return registryURL
        }
        guard let animateURL = store?.animateURL else { return nil }
        let modelsDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("models")

        // Try the specific Character3DModel entry first.
        let model3D: Character3DModel? = {
            if let costume = costumeName {
                return character.models3D.first { $0.costumeName == costume }
            }
            return character.models3D.first
        }()

        if let entry = model3D {
            let url = modelsDir.appendingPathComponent(entry.modelFileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Fall back: scan the directory for any supported file.
        return scanDirectoryForModel(at: modelsDir)
    }

    private func resolvePerformanceProfileURLs(
        for character: AnimationCharacter,
        slug: String,
        costumeName: String?
    ) -> [URL] {
        var urls: [URL] = []

        func appendIfExists(_ candidate: URL?) {
            guard let candidate,
                  FileManager.default.fileExists(atPath: candidate.path),
                  !urls.contains(candidate) else {
                return
            }
            urls.append(candidate)
        }

        if let bundle = bundleDescriptor(for: slug, costumeName: costumeName) {
            appendIfExists(registryRelativeURL(for: bundle.faceRigPath))
            appendIfExists(registryRelativeURL(for: bundle.mouthProfilePath))
            appendIfExists(registryRelativeURL(for: bundle.expressionLibraryPath))
        }
        guard let animateURL = store?.animateURL else { return urls }
        let modelsDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("models")

        let model3D: Character3DModel? = {
            if let costumeName {
                return character.models3D.first(where: { $0.costumeName == costumeName })
            }
            return character.models3D.first
        }()

        if let model3D {
            let baseName = URL(fileURLWithPath: model3D.modelFileName)
                .deletingPathExtension()
                .lastPathComponent
            let exact = modelsDir.appendingPathComponent("\(baseName).performance.json")
            appendIfExists(exact)
        }

        for fileName in Self.performanceProfileFileNames {
            appendIfExists(modelsDir.appendingPathComponent(fileName))
        }

        let faceRigDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("face-rigs")
        for fileName in Self.performanceProfileFileNames {
            appendIfExists(faceRigDir.appendingPathComponent(fileName))
        }

        let mouthProfileDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("mouth-profiles")
        for fileName in Self.performanceProfileFileNames + ["default.performance.json"] {
            appendIfExists(mouthProfileDir.appendingPathComponent(fileName))
        }

        let expressionsDir = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("expressions")
        for fileName in Self.performanceProfileFileNames + ["default.performance.json"] {
            appendIfExists(expressionsDir.appendingPathComponent(fileName))
        }

        return urls
    }

    /// Scans a directory for the first supported 3D model file.
    private func scanDirectoryForModel(at directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for ext in Self.supportedModelExtensions {
            if let match = contents.first(where: {
                $0.pathExtension.lowercased() == ext
            }) {
                return match
            }
        }
        return nil
    }

    private func ensureRegistriesLoaded() {
        guard let store else { return }
        let projectURL = store.workingOWPURL ?? store.owpURL
        guard registryProjectURL != projectURL else { return }
        registryProjectURL = projectURL

        if let projectURL {
            ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
            assetRegistry = ProjectDatabaseBridge.loadAnimate3DAssetRegistryFromDisk(projectURL: projectURL) ?? Animate3DAssetRegistry()
            characterRegistry = ProjectDatabaseBridge.loadAnimate3DCharacterRegistryFromDisk(projectURL: projectURL) ?? Animate3DCharacterRegistry()
            motionRegistry = ProjectDatabaseBridge.loadAnimate3DMotionRegistryFromDisk(projectURL: projectURL) ?? Animate3DMotionRegistry()
        } else {
            assetRegistry = Animate3DAssetRegistry()
            characterRegistry = Animate3DCharacterRegistry()
            motionRegistry = Animate3DMotionRegistry()
        }
    }

    private func bundleDescriptor(
        for slug: String,
        costumeName: String?
    ) -> Animate3DCharacterBundleDescriptor? {
        let registries = [characterRegistry.bundles, assetRegistry.bundles]
        for bundles in registries {
            if let costumeName,
               let exact = bundles.first(where: {
                   $0.characterSlug.caseInsensitiveCompare(slug) == .orderedSame &&
                   $0.costumeName.caseInsensitiveCompare(costumeName) == .orderedSame
               }) {
                return exact
            }
            if let `default` = bundles.first(where: {
                $0.characterSlug.caseInsensitiveCompare(slug) == .orderedSame &&
                $0.costumeName.caseInsensitiveCompare("default") == .orderedSame
            }) {
                return `default`
            }
            if let first = bundles.first(where: {
                $0.characterSlug.caseInsensitiveCompare(slug) == .orderedSame
            }) {
                return first
            }
        }
        return nil
    }

    private func registryRelativeURL(for relativePath: String?) -> URL? {
        guard let trimmed = normalizedRegistryPath(relativePath) else {
            return nil
        }
        if let url = projectRelativeURL(for: trimmed) {
            return url
        }
        guard let animateURL = store?.animateURL else { return nil }
        let normalized = trimmed.hasPrefix("Animate/")
            ? String(trimmed.dropFirst("Animate/".count))
            : trimmed
        let candidate = animateURL.appendingPathComponent(normalized)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func normalizedRegistryPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func relativePath(for sourceURL: URL) -> String? {
        if let animateURL = store?.animateURL {
            let basePath = animateURL.path.hasSuffix("/") ? animateURL.path : animateURL.path + "/"
            if sourceURL.path.hasPrefix(basePath) {
                return "Animate/" + String(sourceURL.path.dropFirst(basePath.count))
            }
        }
        if let projectURL = store?.workingOWPURL ?? store?.owpURL {
            let basePath = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
            if sourceURL.path.hasPrefix(basePath) {
                return String(sourceURL.path.dropFirst(basePath.count))
            }
        }
        return sourceURL.lastPathComponent
    }

    // MARK: Private — Material & Scale

    /// Applies anime-style material settings to a loaded model.
    ///
    /// Keeps the original diffuse texture but flattens specular response
    /// for a matte, cel-shaded look with hard-edge shadows.
    private func applyAnimeMaterials(to node: SCNNode) {
        node.enumerateChildNodes { child, _ in
            guard let geometry = child.geometry else { return }
            for material in geometry.materials {
                material.specular.contents = NSColor.black
                material.roughness.contents = NSNumber(value: 0.9)
                material.metalness.contents = NSNumber(value: 0.0)
                material.lightingModel = .physicallyBased
            }
        }
    }

    /// Normalises a loaded model to a standard height (default 2.0 world units)
    /// and positions it so the feet sit on the ground plane (y = 0).
    private func normalizeScale(node: SCNNode, targetHeight: Float = 2.0) {
        let (minBound, maxBound) = node.boundingBox
        let height = maxBound.y - minBound.y
        guard height > 0 else { return }
        let scale = targetHeight / Float(height)
        node.scale = SCNVector3(scale, scale, scale)
        // Place feet on the ground plane.
        node.position.y = CGFloat(-Float(minBound.y) * scale)
    }
}

// MARK: - Prop Loading

@available(macOS 26.0, *)
extension SceneAssetPipeline {

    /// Returns a prop node for the given object name.
    ///
    /// Resolution order:
    /// 1. Return a cached clone if already loaded.
    /// 2. Check the project's `Animate/objects/<name>/` directory for a 3D file.
    /// 3. Fall back to `Animate3DModelFactory.propForObjectName(_:)` which
    ///    tries bundled models, then programmatic geometry, then a labelled box.
    func propNode(name: String) -> SCNNode {
        if let cached = propModels[name] {
            return cached.clone()
        }

        // Try project-local object model.
        if let node = loadProjectProp(name: name) {
            propModels[name] = node
            return node.clone()
        }

        // Fall back to factory (bundled + programmatic).
        let node = Animate3DModelFactory.propForObjectName(name)
        propModels[name] = node
        return node.clone()
    }

    /// Attempts to load a prop model from `Animate/objects/<name>/`.
    private func loadProjectProp(name: String) -> SCNNode? {
        guard let animateURL = store?.animateURL else { return nil }

        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")

        // Try directory first: Animate/objects/<slug>/<file>
        let objectDir = animateURL
            .appendingPathComponent("objects")
            .appendingPathComponent(slug)
        if let url = scanDirectoryForModel(at: objectDir) {
            return Animate3DModelFactory.loadModel(from: url)
        }

        // Try flat file: Animate/objects/<slug>.glb (etc.)
        let objectsDir = animateURL.appendingPathComponent("objects")
        for ext in Self.supportedModelExtensions {
            let url = objectsDir.appendingPathComponent("\(slug).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return Animate3DModelFactory.loadModel(from: url)
            }
        }

        return nil
    }

    func worldChunkNode(descriptor: Animate3DWorldChunkDescriptor) -> SCNNode? {
        guard let meshPath = descriptor.meshPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !meshPath.isEmpty else {
            return nil
        }
        if let cached = projectRelativeModels[meshPath] {
            return cached.clone()
        }
        guard let url = projectRelativeURL(for: meshPath),
              let node = Animate3DModelFactory.loadModel(from: url) else {
            return nil
        }
        applyAnimeMaterials(to: node)
        projectRelativeModels[meshPath] = node
        return node.clone()
    }

    private func projectRelativeURL(for relativePath: String) -> URL? {
        guard let store,
              let projectURL = store.workingOWPURL ?? store.owpURL else {
            return nil
        }
        let url = projectURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Background Loading

@available(macOS 26.0, *)
extension SceneAssetPipeline {

    /// Loads the background image for a scene by name.
    ///
    /// Looks up the `BackgroundPlate` in the store's backgrounds array,
    /// resolves the approved image path, and caches the result.
    func backgroundImage(name: String) -> NSImage? {
        if let cached = backgroundPlates[name] {
            return cached
        }

        guard let store else { return nil }

        guard let plate = store.backgrounds.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            return nil
        }

        // Resolve the approved or first available image path.
        let imagePath = plate.approvedImagePath ?? plate.imagePaths.first
        guard let path = imagePath,
              let url = store.resolvedCharacterAssetURL(for: path),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        backgroundPlates[name] = image
        return image
    }

    /// Creates a SceneKit background plane node from the named background,
    /// sized to fill the camera's field of view at the given depth.
    func backgroundNode(name: String, camera: AnimationCamera) -> SCNNode? {
        guard let image = backgroundImage(name: name) else { return nil }
        return backgroundNode(image: image, camera: camera)
    }

    func backgroundImage(relativePath: String) -> NSImage? {
        if let cached = backgroundPlates[relativePath] {
            return cached
        }

        guard let store,
              let url = store.resolvedCharacterAssetURL(for: relativePath),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        backgroundPlates[relativePath] = image
        return image
    }

    func backgroundNode(relativePath: String, camera: AnimationCamera) -> SCNNode? {
        guard let image = backgroundImage(relativePath: relativePath) else { return nil }
        return backgroundNode(image: image, camera: camera)
    }

    private func backgroundNode(image: NSImage, camera: AnimationCamera) -> SCNNode? {
        let depth: Float = 20.0
        let halfFOVRad = Float(camera.horizontalFOV / 2.0) * (.pi / 180.0)
        let width = 2.0 * depth * tan(halfFOVRad)
        let aspectRatio = Float(image.size.width / image.size.height)
        let height = width / aspectRatio

        return Animate3DModelFactory.makeBackgroundPlane(
            image: image,
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }
}

// MARK: - Scene Assembly

@available(macOS 26.0, *)
extension SceneAssetPipeline {

    /// Assembles a complete SceneKit scene from a compiled scene definition.
    ///
    /// - Parameters:
    ///   - compiledScene: The fully resolved scene with frame-based keyframes.
    ///   - frame: The frame number to evaluate positions at.
    ///   - camera: The camera state for background sizing and depth layers.
    /// - Returns: A `SceneAssembly` with all nodes positioned and ready to render.
    func assembleScene(
        compiledScene: CompiledScene,
        frame: Int,
        camera: AnimationCamera
    ) -> SceneAssembly {
        // Background
        let bgNode: SCNNode? = {
            guard let bgName = compiledScene.backgroundName else { return nil }
            return backgroundNode(name: bgName, camera: camera)
        }()

        // Characters
        let palette = defaultCharacterColors()
        var charNodes: [(name: String, node: SCNNode, position: SIMD3<Double>)] = []

        for (index, setup) in compiledScene.characterSetups.enumerated() {
            let color = palette[index % palette.count]
            let slug = setup.characterName.lowercased()
                .replacingOccurrences(of: " ", with: "-")

            // Skip characters not yet entered or already exited.
            if frame < setup.enterFrame { continue }
            if let exit = setup.exitFrame, frame > exit { continue }

            let node = characterNode(slug: slug, color: color)
            let position = evaluateCharacterPosition(
                setup: setup,
                tracks: compiledScene.tracks[setup.characterName],
                frame: frame
            )
            charNodes.append((name: setup.characterName, node: node, position: position))
        }

        // Props / objects
        var objNodes: [(name: String, node: SCNNode, position: SIMD3<Double>)] = []

        for setup in compiledScene.objectSetups {
            if frame < setup.enterFrame { continue }
            if let exit = setup.exitFrame, frame > exit { continue }

            let node = propNode(name: setup.objectName)
            let position = SIMD3<Double>(setup.initialX, 0, setup.initialY)
            objNodes.append((name: setup.objectName, node: node, position: position))
        }

        // Depth layers
        var depthManager = SceneDepthManager.default
        depthManager.updateBlurRadii(camera: camera)

        return SceneAssembly(
            backgroundNode: bgNode,
            characterNodes: charNodes,
            propNodes: objNodes,
            cameraState: camera,
            depthLayers: depthManager.layers
        )
    }

    // MARK: Private — Position Evaluation

    /// Evaluates a character's world position at a given frame by interpolating
    /// between timeline keyframes. Falls back to the initial setup position.
    private func evaluateCharacterPosition(
        setup: CharacterSetup,
        tracks: [TimelineKeyframe]?,
        frame: Int
    ) -> SIMD3<Double> {
        // Default from setup: initialPosition is normalised X (0...1),
        // map to world-space X range (-5...5), Y = 0 (ground), Z = 0.
        let defaultX = (setup.initialPosition - 0.5) * 10.0
        let defaultPos = SIMD3<Double>(defaultX, 0, 0)

        // Filter to transform keyframes only.
        guard let keyframes = tracks?.filter({ $0.kind == .transform }),
              !keyframes.isEmpty else {
            return defaultPos
        }

        let sorted = keyframes.sorted { $0.frame < $1.frame }

        // Before first keyframe — use first position or default.
        guard let first = sorted.first else { return defaultPos }
        if frame <= first.frame {
            return positionFromKeyframe(first) ?? defaultPos
        }

        // After last keyframe — hold last position.
        guard let last = sorted.last else { return defaultPos }
        if frame >= last.frame {
            return positionFromKeyframe(last) ?? defaultPos
        }

        // Between keyframes — linear interpolation.
        for i in 0..<(sorted.count - 1) {
            let kf0 = sorted[i]
            let kf1 = sorted[i + 1]
            if frame >= kf0.frame && frame <= kf1.frame {
                let span = kf1.frame - kf0.frame
                guard span > 0 else {
                    return positionFromKeyframe(kf0) ?? defaultPos
                }
                let t = Double(frame - kf0.frame) / Double(span)
                let p0 = positionFromKeyframe(kf0) ?? defaultPos
                let p1 = positionFromKeyframe(kf1) ?? defaultPos
                return simd_mix(p0, p1, SIMD3<Double>(repeating: t))
            }
        }

        return defaultPos
    }

    /// Extracts a world position from a transform keyframe.
    ///
    /// `CharacterTransform.x` and `.y` are normalised stage coordinates.
    /// Maps X to world-space range -5...5, Y stays at ground (0), Z = 0.
    private func positionFromKeyframe(_ kf: TimelineKeyframe) -> SIMD3<Double>? {
        guard case .transform(let xform) = kf.value else { return nil }
        let worldX = (xform.x - 0.5) * 10.0
        return SIMD3<Double>(worldX, 0, 0)
    }

    /// A basic palette for distinguishing characters when using placeholders.
    private func defaultCharacterColors() -> [NSColor] {
        [
            .systemBlue, .systemRed, .systemGreen,
            .systemOrange, .systemPurple, .systemTeal,
            .systemPink, .systemYellow, .systemIndigo,
        ]
    }
}

// MARK: - Cache Management

@available(macOS 26.0, *)
extension SceneAssetPipeline {

    /// Clears all cached assets. Call when switching scenes or when the
    /// underlying project data changes.
    func clearCache() {
        characterModels.removeAll()
        propModels.removeAll()
        projectRelativeModels.removeAll()
        backgroundPlates.removeAll()
    }

    /// Preloads assets for a scene so the first render doesn't stall.
    ///
    /// Loads characters, objects, and the background concurrently on the
    /// main actor (SceneKit requires main-thread model loading).
    func preload(
        characterSlugs: [String],
        objectNames: [String],
        backgroundName: String?
    ) {
        for slug in characterSlugs {
            _ = loadCharacterModel(slug: slug)
        }
        for name in objectNames {
            _ = propNode(name: name)
        }
        if let bg = backgroundName {
            _ = backgroundImage(name: bg)
        }
    }
}
