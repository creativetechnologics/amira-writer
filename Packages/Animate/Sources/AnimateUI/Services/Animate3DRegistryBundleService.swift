import Foundation

@available(macOS 26.0, *)
struct Animate3DResolvedBundleInfo: Hashable, Sendable {
    var descriptor: Animate3DCharacterBundleDescriptor
    var sourceManifestPath: String
    var resolvedAssetPaths: [String]
}

@available(macOS 26.0, *)
struct Animate3DRegistryBundleService {
    let projectURL: URL?
    let animateURL: URL?
    let assetRegistry: Animate3DAssetRegistry
    let characterRegistry: Animate3DCharacterRegistry

    @MainActor
    init(store: AnimateStore) {
        let projectURL = store.workingOWPURL ?? store.owpURL
        self.projectURL = projectURL
        self.animateURL = store.animateURL

        if let projectURL {
            ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
            self.assetRegistry = ProjectDatabaseBridge.loadAnimate3DAssetRegistryFromDisk(projectURL: projectURL) ?? Animate3DAssetRegistry()
            self.characterRegistry = ProjectDatabaseBridge.loadAnimate3DCharacterRegistryFromDisk(projectURL: projectURL) ?? Animate3DCharacterRegistry()
        } else {
            self.assetRegistry = Animate3DAssetRegistry()
            self.characterRegistry = Animate3DCharacterRegistry()
        }
    }

    init(
        projectURL: URL?,
        animateURL: URL?,
        assetRegistry: Animate3DAssetRegistry,
        characterRegistry: Animate3DCharacterRegistry
    ) {
        self.projectURL = projectURL
        self.animateURL = animateURL
        self.assetRegistry = assetRegistry
        self.characterRegistry = characterRegistry
    }

    func bundleDescriptor(
        for slug: String,
        costumeName: String? = nil
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

    func resolvedBundleInfo(
        for slug: String,
        costumeName: String? = nil
    ) -> Animate3DResolvedBundleInfo? {
        guard let (descriptor, sourceManifestPath) = resolveBundleDescriptorAndSource(
            for: slug,
            costumeName: costumeName
        ) else {
            return nil
        }

        return Animate3DResolvedBundleInfo(
            descriptor: descriptor,
            sourceManifestPath: sourceManifestPath,
            resolvedAssetPaths: resolvedAssetPaths(for: descriptor)
        )
    }

    func provides(
        _ category: Animate3DCharacterAssetCategory,
        for slug: String,
        costumeName: String? = nil
    ) -> Bool {
        guard let bundle = bundleDescriptor(for: slug, costumeName: costumeName) else {
            return false
        }

        switch category {
        case .models:
            return resolvedURL(for: bundle.bodyModelPath) != nil
        case .faceRigs:
            return resolvedURL(for: bundle.faceRigPath) != nil
        case .mouthProfiles:
            return resolvedURL(for: bundle.mouthProfilePath) != nil
        case .expressions:
            return resolvedURL(for: bundle.expressionLibraryPath) != nil
        case .motions:
            return bundle.motionSetPaths.contains { resolvedURL(for: $0) != nil }
        case .materials:
            return resolvedURL(for: bundle.materialProfilePath) != nil
        }
    }

    func signature(
        for slug: String,
        costumeName: String? = nil
    ) -> String {
        guard let bundle = bundleDescriptor(for: slug, costumeName: costumeName) else {
            return "\(slug):registry:none"
        }

        let scalarPaths: [(String, String?)] = [
            ("body", bundle.bodyModelPath),
            ("face", bundle.faceRigPath),
            ("mouth", bundle.mouthProfilePath),
            ("expr", bundle.expressionLibraryPath),
            ("material", bundle.materialProfilePath)
        ]

        let scalarParts = scalarPaths.map { label, relativePath in
            signaturePart(label: label, relativePath: relativePath)
        }
        let motionParts = bundle.motionSetPaths.sorted().map {
            signaturePart(label: "motion", relativePath: $0)
        }

        return ([ "\(slug):\(bundle.costumeName)" ] + scalarParts + motionParts).joined(separator: "|")
    }

    private func resolvedURL(for relativePath: String?) -> URL? {
        guard let trimmed = normalized(relativePath) else {
            return nil
        }
        if let projectURL {
            let candidate = projectURL.appendingPathComponent(trimmed)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let animateURL {
            let normalizedPath = trimmed.hasPrefix("Animate/")
                ? String(trimmed.dropFirst("Animate/".count))
                : trimmed
            let candidate = animateURL.appendingPathComponent(normalizedPath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func normalized(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolveBundleDescriptorAndSource(
        for slug: String,
        costumeName: String?
    ) -> (Animate3DCharacterBundleDescriptor, String)? {
        let index = (projectURL.flatMap(ProjectDatabaseBridge.loadAnimate3DRegistryIndexFromDisk(projectURL:))) ?? Animate3DRegistryIndex()
        let registries: [([Animate3DCharacterBundleDescriptor], String)] = [
            (characterRegistry.bundles, index.characterRegistryPath),
            (assetRegistry.bundles, index.assetRegistryPath)
        ]

        for (bundles, sourceManifestPath) in registries {
            if let costumeName,
               let exact = bundles.first(where: {
                   $0.characterSlug.caseInsensitiveCompare(slug) == .orderedSame &&
                   $0.costumeName.caseInsensitiveCompare(costumeName) == .orderedSame
               }) {
                return (exact, sourceManifestPath)
            }
            if let `default` = bundles.first(where: {
                $0.characterSlug.caseInsensitiveCompare(slug) == .orderedSame &&
                $0.costumeName.caseInsensitiveCompare("default") == .orderedSame
            }) {
                return (`default`, sourceManifestPath)
            }
            if let first = bundles.first(where: {
                $0.characterSlug.caseInsensitiveCompare(slug) == .orderedSame
            }) {
                return (first, sourceManifestPath)
            }
        }
        return nil
    }

    private func resolvedAssetPaths(for descriptor: Animate3DCharacterBundleDescriptor) -> [String] {
        var paths: [String] = []
        if let path = normalized(descriptor.bodyModelPath) {
            paths.append(path)
        }
        if let path = normalized(descriptor.faceRigPath) {
            paths.append(path)
        }
        if let path = normalized(descriptor.mouthProfilePath) {
            paths.append(path)
        }
        if let path = normalized(descriptor.expressionLibraryPath) {
            paths.append(path)
        }
        paths.append(contentsOf: descriptor.motionSetPaths.compactMap(normalized))
        if let path = normalized(descriptor.materialProfilePath) {
            paths.append(path)
        }
        return paths
    }

    private func signaturePart(label: String, relativePath: String?) -> String {
        guard let normalizedPath = normalized(relativePath) else {
            return "\(label):nil"
        }
        guard let url = resolvedURL(for: normalizedPath) else {
            return "\(label):\(normalizedPath):missing"
        }
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(label):\(normalizedPath):\(Int(modificationDate))"
    }
}
