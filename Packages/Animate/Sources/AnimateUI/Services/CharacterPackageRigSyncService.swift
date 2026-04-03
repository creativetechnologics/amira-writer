import Foundation

struct CharacterPackageRigSyncCoverage: Sendable {
    var packageDisplayName: String
    var totalPartAssets: Int
    var matchedRigParts: Int
    var missingRigPartTypes: [PartType]
}

struct CharacterPackageRigSyncReport: Sendable {
    var packageDisplayName: String
    var createdDefaultRig: Bool
    var importedVariants: Int
    var skippedExistingVariants: Int
    var matchedPartAssets: Int
    var missingRigPartTypes: [PartType]
}

struct CharacterPackageRigSyncResult: Sendable {
    var parts: [RigPart]
    var report: CharacterPackageRigSyncReport
}

struct CharacterPackageRigSyncService: Sendable {
    func coverage(
        for character: AnimationCharacter,
        package: InstalledCharacterPackage
    ) -> CharacterPackageRigSyncCoverage {
        let partAssets = syncableAssets(in: package)
        let availablePartTypes = Set(partAssets.compactMap(\.partType))
        let rigPartTypes = Set(character.parts.map(\.partType))
        let matched = availablePartTypes.filter { rigPartTypes.contains($0) }
        let missing = availablePartTypes.filter { !rigPartTypes.contains($0) }.sorted { $0.rawValue < $1.rawValue }

        return CharacterPackageRigSyncCoverage(
            packageDisplayName: package.manifest.displayName,
            totalPartAssets: partAssets.count,
            matchedRigParts: matched.count,
            missingRigPartTypes: missing
        )
    }

    func partAssets(
        for partType: PartType,
        in package: InstalledCharacterPackage
    ) -> [CharacterPackageAsset] {
        package.manifest.assets
            .filter {
                $0.partType == partType &&
                isRenderableImage(path: $0.normalizedRelativePath)
            }
            .sorted { lhs, rhs in
                score(lhs, package: package) > score(rhs, package: package)
            }
    }

    func sync(
        character: AnimationCharacter,
        package: InstalledCharacterPackage,
        animateURL: URL,
        createdDefaultRig: Bool
    ) throws -> CharacterPackageRigSyncResult {
        var updatedParts = character.parts
        var importedVariants = 0
        var skippedExistingVariants = 0

        let partAssets = syncableAssets(in: package)
        let availablePartTypes = Set(partAssets.compactMap(\.partType))
        let missingRigPartTypes = availablePartTypes.filter { partType in
            !updatedParts.contains(where: { $0.partType == partType })
        }.sorted { $0.rawValue < $1.rawValue }

        let partsDirectoryURL = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(character.assetFolderSlug)
            .appendingPathComponent("parts")

        try FileManager.default.createDirectory(at: partsDirectoryURL, withIntermediateDirectories: true)
        let packagePrefix = String(package.manifest.id.uuidString.prefix(8))

        for asset in partAssets {
            guard let partType = asset.partType,
                  let partIndex = updatedParts.firstIndex(where: { $0.partType == partType })
            else {
                continue
            }

            let sourceURL = package.packageDirectoryURL.appendingPathComponent(asset.normalizedRelativePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let assetPrefix = String(asset.id.uuidString.prefix(8))
            let destinationFilename = "\(packagePrefix)-\(assetPrefix)-\(sourceURL.lastPathComponent)"
            let destinationURL = partsDirectoryURL.appendingPathComponent(destinationFilename)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let angle = asset.angle ?? package.manifest.defaults.preferredAngle ?? .front
            var drawingSet = updatedParts[partIndex].drawingSets[angle] ?? DrawingSet(angle: angle)

            if let existingIndex = drawingSet.variants.firstIndex(where: { $0.filename == destinationFilename }) {
                let existingVariant = drawingSet.variants[existingIndex]
                let refreshedVariant = packageVariant(
                    from: asset,
                    package: package,
                    sourceURL: sourceURL,
                    destinationFilename: destinationFilename,
                    preservingID: existingVariant.id
                )
                drawingSet.variants[existingIndex] = refreshedVariant
                if drawingSet.activeVariantID == nil || drawingSet.activeVariantID == existingVariant.id {
                    drawingSet.activeVariantID = refreshedVariant.id
                }
                skippedExistingVariants += 1
            } else {
                let newVariant = packageVariant(
                    from: asset,
                    package: package,
                    sourceURL: sourceURL,
                    destinationFilename: destinationFilename
                )
                drawingSet.variants.append(newVariant)
                if drawingSet.activeVariantID == nil {
                    drawingSet.activeVariantID = newVariant.id
                }
                importedVariants += 1
            }

            updatedParts[partIndex].drawingSets[angle] = drawingSet
        }

        return CharacterPackageRigSyncResult(
            parts: updatedParts,
            report: CharacterPackageRigSyncReport(
                packageDisplayName: package.manifest.displayName,
                createdDefaultRig: createdDefaultRig,
                importedVariants: importedVariants,
                skippedExistingVariants: skippedExistingVariants,
                matchedPartAssets: partAssets.filter { asset in
                    guard let partType = asset.partType else { return false }
                    return updatedParts.contains(where: { $0.partType == partType })
                }.count,
                missingRigPartTypes: missingRigPartTypes
            )
        )
    }

    private func syncableAssets(
        in package: InstalledCharacterPackage
    ) -> [CharacterPackageAsset] {
        package.manifest.assets
            .filter { asset in
                guard asset.partType != nil else { return false }
                guard isRenderableImage(path: asset.normalizedRelativePath) else { return false }

                let assetURL = package.packageDirectoryURL.appendingPathComponent(asset.normalizedRelativePath)
                return FileManager.default.fileExists(atPath: assetURL.path)
            }
            .sorted { lhs, rhs in
                guard let lhsPartType = lhs.partType, let rhsPartType = rhs.partType else {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                if lhsPartType != rhsPartType {
                    return lhsPartType.rawValue < rhsPartType.rawValue
                }

                let lhsAngle = lhs.angle?.rawValue ?? ""
                let rhsAngle = rhs.angle?.rawValue ?? ""
                if lhsAngle != rhsAngle {
                    return lhsAngle < rhsAngle
                }

                let lhsScore = score(lhs, package: package)
                let rhsScore = score(rhs, package: package)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func score(_ asset: CharacterPackageAsset, package: InstalledCharacterPackage) -> Int {
        var score = 0

        if asset.angle == package.manifest.defaults.preferredAngle { score += 50 }
        if asset.pose == package.manifest.defaults.preferredPose { score += 25 }

        switch asset.role {
        case .costumeOverlay, .propOverlay:
            score += 40
        case .basePose:
            score += 20
        case .turnaround:
            score += 10
        case .heroPose, .reference, .expression, .viseme, .handPose, .backgroundPlate:
            score += 5
        }

        let tags = asset.tags.joined(separator: " ").lowercased()
        if tags.contains("part-layer") { score += 25 }
        if tags.contains("derived-from-base") { score += 10 }
        if tags.contains("default") { score += 10 }

        return score
    }

    private func packageVariant(
        from asset: CharacterPackageAsset,
        package: InstalledCharacterPackage,
        sourceURL: URL,
        destinationFilename: String,
        preservingID id: UUID = UUID()
    ) -> DrawingVariant {
        DrawingVariant(
            id: id,
            name: "\(package.manifest.displayName) • \(asset.name)",
            filename: destinationFilename,
            sourceURL: sourceURL,
            sourcePackageSchemaVersion: package.manifest.schemaVersion,
            sourcePackageID: package.manifest.id,
            sourcePackageSlug: package.manifest.slug,
            sourcePackageDisplayName: package.manifest.displayName,
            sourceAssetID: asset.id,
            sourceAssetName: asset.name,
            sourceAssetRole: asset.role,
            sourcePartType: asset.partType,
            sourceAngle: asset.angle ?? package.manifest.defaults.preferredAngle,
            sourcePose: asset.pose,
            sourceTags: asset.tags,
            sourceNotes: asset.notes,
            sourceRelativePath: asset.normalizedRelativePath,
            placement: asset.placement
        )
    }

    private func isRenderableImage(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "heic"].contains(ext)
    }
}
