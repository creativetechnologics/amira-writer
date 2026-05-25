import Foundation

@available(macOS 26.0, *)
extension AllProjectImagesState {
    nonisolated static func buildRecordsIncrementally(
        from seeds: [RecordSeed],
        context: RecordBuildContext,
        previousSeedsByID: [String: RecordSeed],
        previousRecordsByID: [String: ProjectImageRecord],
        metadataCache: [String: CachedFileMetadata]
    ) -> [ProjectImageRecord] {
        var mutableMetadataCache = metadataCache
        var records = seeds.map { seed in
            if previousSeedsByID[seed.id] == seed,
               let existing = previousRecordsByID[seed.id] {
                return existing
            }
            return buildRecord(from: seed, context: context, metadataCache: &mutableMetadataCache)
        }
        var seenResolvedKeys = Set<String>()
        records = records.filter { record in
            seenResolvedKeys.insert("\(record.source.rawValue)|\(record.resolvedPath)").inserted
        }
        records.sort { (lhs, rhs) in
            (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
        return records
    }

    nonisolated static func buildRecord(
        from seed: RecordSeed,
        context: RecordBuildContext,
        metadataCache: inout [String: CachedFileMetadata]
    ) -> ProjectImageRecord {
        let resolvedPath = resolvedImagePath(for: seed.path, context: context)
        let metadata: CachedFileMetadata
        if let cached = metadataCache[resolvedPath] {
            metadata = cached
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
            metadata = CachedFileMetadata(
                createdAt: (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date),
                sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value
            )
            metadataCache[resolvedPath] = metadata
        }

        let sidecarMetadata = ImageLibraryMetadataSidecarService.load(forImagePath: resolvedPath)
        let resolvedSemanticRole = sidecarMetadata?.semanticRole ?? seed.semanticRole ?? inferredSemanticRole(for: seed.source)
        let resolvedSource = sourceAfterRecategorization(
            recordID: seed.id,
            originalSource: seed.source,
            semanticRole: sidecarMetadata?.semanticRole ?? seed.semanticRole
        )
        let mergedNotes = seed.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (sidecarMetadata?.notes ?? "")
            : seed.notes

        return ProjectImageRecord(
            id: seed.id,
            path: seed.path,
            resolvedPath: resolvedPath,
            source: resolvedSource,
            semanticRole: resolvedSemanticRole,
            originLabel: seed.originLabel,
            groupLabel: seed.groupLabel,
            sceneID: seed.sceneID,
            shotID: seed.shotID,
            searchHaystack: searchHaystack(
                path: seed.path,
                resolvedPath: resolvedPath,
                source: seed.source,
                originLabel: seed.originLabel,
                groupLabel: seed.groupLabel,
                notes: mergedNotes
            ),
            createdAt: metadata.createdAt,
            sizeBytes: metadata.sizeBytes,
            rating: seed.rating ?? sidecarMetadata?.rating,
            isRejected: seed.isRejected || (sidecarMetadata?.isRejected ?? false),
            isLiked: (seed.isLiked || (sidecarMetadata?.isLiked ?? false)) && !(seed.isRejected || (sidecarMetadata?.isRejected ?? false)),
            notes: mergedNotes,
            supportsLibraryCuration: seed.supportsLibraryCuration
        )
    }

    nonisolated static func resolvedImagePath(
        for path: String,
        context: RecordBuildContext
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }

        let fileManager = FileManager.default
        if !trimmed.hasPrefix("/"),
           let projectURL = context.projectURL {
            let projectRelativeURL = projectURL.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: projectRelativeURL.path) {
                return projectRelativeURL.path
            }
        }

        if !trimmed.hasPrefix("/"),
           let animateURL = context.animateURL,
           trimmed.hasPrefix("Animate/") {
            let animateRelativeURL = animateURL
                .deletingLastPathComponent()
                .appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: animateRelativeURL.path) {
                return animateRelativeURL.path
            }
        }

        if !trimmed.hasPrefix("/"),
           let animateURL = context.animateURL,
           (trimmed.hasPrefix("characters/") || trimmed.hasPrefix("backgrounds/")) {
            let animateRelativeURL = animateURL.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: animateRelativeURL.path) {
                return animateRelativeURL.path
            }
        }

        if let projectURL = context.projectURL,
           let projectRelativePath = projectRelativeCharacterAssetPath(from: trimmed, projectURL: projectURL) {
            let remappedURL = projectURL.appendingPathComponent(projectRelativePath)
            if fileManager.fileExists(atPath: remappedURL.path) {
                return remappedURL.path
            }
        }

        if trimmed.hasPrefix("/") {
            let candidateURL = URL(fileURLWithPath: trimmed)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL.path
            }
        }

        return trimmed
    }

    nonisolated static func projectRelativeCharacterAssetPath(
        from path: String,
        projectURL: URL
    ) -> String? {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }

        if !normalizedPath.hasPrefix("/") {
            if normalizedPath.hasPrefix("Characters/") {
                return normalizedPath
            }
            if normalizedPath.hasPrefix("Animate/") {
                if normalizedPath.hasPrefix("Animate/characters/") {
                    return "Characters/" + normalizedPath.dropFirst("Animate/characters/".count)
                }
                return normalizedPath
            }
            if normalizedPath.hasPrefix("characters/") {
                return "Characters/" + normalizedPath.dropFirst("characters/".count)
            }
            if normalizedPath.hasPrefix("backgrounds/") {
                return "Animate/" + normalizedPath
            }
            return normalizedPath
        }

        let standardizedAbsoluteURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
        if let projectRelativePath = projectRelativePath(for: standardizedAbsoluteURL, projectURL: projectURL) {
            return projectRelativePath
        }

        let standardizedAbsolutePath = standardizedAbsoluteURL.path
        if let animateRange = standardizedAbsolutePath.range(of: "/Animate/") {
            return "Animate/" + standardizedAbsolutePath[animateRange.upperBound...]
        }

        return nil
    }

    nonisolated static func projectRelativePath(for url: URL, projectURL: URL) -> String? {
        let absolutePath = url.standardizedFileURL.path
        let projectPath = projectURL.standardizedFileURL.path
        guard absolutePath == projectPath || absolutePath.hasPrefix(projectPath + "/") else {
            return nil
        }

        let suffix = absolutePath.dropFirst(projectPath.count)
        let trimmed = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func searchHaystack(
        path: String,
        resolvedPath: String,
        source: AllProjectImagesSource,
        originLabel: String,
        groupLabel: String,
        notes: String
    ) -> String {
        let pathComponents = path.split(separator: "/").map(String.init).joined(separator: " ")
        return [pathComponents, originLabel, groupLabel, notes].joined(separator: " ").lowercased()
    }

    nonisolated static func inferredSemanticRole(for source: AllProjectImagesSource) -> ImageLibrarySemanticRole? {
        switch source {
        case .characters: return .character
        case .places: return .place
        default: return nil
        }
    }

    nonisolated static func sourceAfterRecategorization(
        recordID: String,
        originalSource: AllProjectImagesSource,
        semanticRole: ImageLibrarySemanticRole?
    ) -> AllProjectImagesSource {
        if let semanticRole {
            switch semanticRole {
            case .place:
                return .places
            case .character:
                return .characters
            }
        }

        if recordID.hasPrefix("canvas-") { return .canvas }
        if recordID.hasPrefix("shot-") { return .sceneShots }
        return originalSource
    }
}
