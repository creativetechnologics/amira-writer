import Foundation

struct CharacterPackageValidationReport: Sendable {
    var issues: [CharacterPackageValidationIssue]

    var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }
}

struct CharacterPackageValidationIssue: Identifiable, Sendable, Hashable {
    enum Severity: String, Codable, Sendable, Hashable {
        case warning
        case error
    }

    enum Code: String, Codable, Sendable, Hashable {
        case emptySlug
        case invalidSlug
        case emptyDisplayName
        case unsupportedSchemaVersion
        case noAssets
        case duplicateAssetID
        case duplicateRelativePath
        case invalidRelativePath
        case noReferenceAssets
        case noBasePoseAssets
        case emptyBlueprintPrompt
        case emptyBlueprintOutputs
        case missingBlueprintReference
        case invalidOutputCount
        case missingPreferredAngleAsset
        case missingPreferredPoseAsset
        case invalidCanvasSize
        case invalidPlacementCenter
        case invalidPlacementSize
        case invalidPlacementPivot
        case invalidPlacementZOrderOverride
        case conflictingPlacementMode
    }

    var id: UUID
    var severity: Severity
    var code: Code
    var message: String
    var assetID: UUID?
    var blueprintID: UUID?

    init(
        id: UUID = UUID(),
        severity: Severity,
        code: Code,
        message: String,
        assetID: UUID? = nil,
        blueprintID: UUID? = nil
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.assetID = assetID
        self.blueprintID = blueprintID
    }
}

struct CharacterPackageValidator: Sendable {
    func validate(_ manifest: CharacterPackageManifest) -> CharacterPackageValidationReport {
        var issues: [CharacterPackageValidationIssue] = []

        if manifest.schemaVersion > CharacterPackageManifest.currentSchemaVersion {
            issues.append(.init(
                severity: .error,
                code: .unsupportedSchemaVersion,
                message: "Schema version \(manifest.schemaVersion) is newer than supported version \(CharacterPackageManifest.currentSchemaVersion)."
            ))
        }

        if manifest.normalizedSlug.isEmpty {
            issues.append(.init(
                severity: .error,
                code: .emptySlug,
                message: "Character packages need a non-empty slug."
            ))
        } else if manifest.slug.contains("/") || manifest.slug.contains("\\") || manifest.slug.contains("..") {
            issues.append(.init(
                severity: .error,
                code: .invalidSlug,
                message: "Character package slugs must not contain path separators or traversal markers."
            ))
        }

        if manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .error,
                code: .emptyDisplayName,
                message: "Character packages need a display name."
            ))
        }

        if manifest.assets.isEmpty {
            issues.append(.init(
                severity: .warning,
                code: .noAssets,
                message: "This package has no assets yet."
            ))
        }

        issues.append(contentsOf: validateAssets(manifest.assets))
        issues.append(contentsOf: validateDefaults(manifest))
        issues.append(contentsOf: validateBlueprints(manifest.blueprints, assetIDs: Set(manifest.assets.map(\.id))))

        if !manifest.assets.contains(where: { $0.role == .reference }) {
            issues.append(.init(
                severity: .warning,
                code: .noReferenceAssets,
                message: "Include at least one reference asset to anchor future generation passes."
            ))
        }

        if !manifest.assets.contains(where: { $0.role == .basePose || $0.role == .turnaround }) {
            issues.append(.init(
                severity: .warning,
                code: .noBasePoseAssets,
                message: "Include at least one base pose or turnaround asset for runtime assembly."
            ))
        }

        return CharacterPackageValidationReport(issues: issues)
    }

    private func validateAssets(_ assets: [CharacterPackageAsset]) -> [CharacterPackageValidationIssue] {
        var issues: [CharacterPackageValidationIssue] = []
        var seenIDs = Set<UUID>()
        var seenPaths = Set<String>()

        for asset in assets {
            if !seenIDs.insert(asset.id).inserted {
                issues.append(.init(
                    severity: .error,
                    code: .duplicateAssetID,
                    message: "Duplicate asset id \(asset.id.uuidString).",
                    assetID: asset.id
                ))
            }

            let normalizedPath = asset.normalizedRelativePath
            if !seenPaths.insert(normalizedPath).inserted {
                issues.append(.init(
                    severity: .error,
                    code: .duplicateRelativePath,
                    message: "Duplicate asset path \(normalizedPath).",
                    assetID: asset.id
                ))
            }

            if !isSafeRelativePath(normalizedPath) {
                issues.append(.init(
                    severity: .error,
                    code: .invalidRelativePath,
                    message: "Asset path \(normalizedPath) must stay inside the package root.",
                    assetID: asset.id
                ))
            }

            if let placement = asset.placement {
                let allowedPlacementRange = (-0.5)...1.5
                if let center = placement.normalizedCenter,
                   (!allowedPlacementRange.contains(center.x) || !allowedPlacementRange.contains(center.y)) {
                    issues.append(.init(
                        severity: .error,
                        code: .invalidPlacementCenter,
                        message: "Asset placement center for \(asset.name) must stay within a reasonable padded range of -0.5...1.5 on both axes.",
                        assetID: asset.id
                    ))
                }

                if let size = placement.normalizedSize,
                   size.width <= 0 || size.height <= 0 || size.width > 2 || size.height > 2 {
                    issues.append(.init(
                        severity: .error,
                        code: .invalidPlacementSize,
                        message: "Asset placement size for \(asset.name) must be positive and reasonably normalized.",
                        assetID: asset.id
                    ))
                }

                if let pivot = placement.normalizedPivot,
                   (!allowedPlacementRange.contains(pivot.x) || !allowedPlacementRange.contains(pivot.y)) {
                    issues.append(.init(
                        severity: .error,
                        code: .invalidPlacementPivot,
                        message: "Asset placement pivot for \(asset.name) must stay within a reasonable padded range of -0.5...1.5 on both axes.",
                        assetID: asset.id
                    ))
                }

                if let zOrderOverride = placement.zOrderOverride,
                   !(-1024...1024).contains(zOrderOverride) {
                    issues.append(.init(
                        severity: .error,
                        code: .invalidPlacementZOrderOverride,
                        message: "Asset z-order override for \(asset.name) must stay within a sane runtime layer range of -1024...1024.",
                        assetID: asset.id
                    ))
                }

                if let mode = placement.mode {
                    let expectsFullCanvasPlacement = mode == .fullCanvasAligned
                    if placement.usesFullCanvasPlacement != expectsFullCanvasPlacement {
                        issues.append(.init(
                            severity: .warning,
                            code: .conflictingPlacementMode,
                            message: "Asset placement mode for \(asset.name) conflicts with the legacy usesFullCanvasPlacement flag. Keep them aligned while older runtimes still read the boolean flag.",
                            assetID: asset.id
                        ))
                    }
                }
            }
        }

        return issues
    }

    private func validateDefaults(_ manifest: CharacterPackageManifest) -> [CharacterPackageValidationIssue] {
        var issues: [CharacterPackageValidationIssue] = []

        if let canvasSize = manifest.defaults.defaultCanvasSize,
           canvasSize.width <= 0 || canvasSize.height <= 0 {
            issues.append(.init(
                severity: .error,
                code: .invalidCanvasSize,
                message: "Default canvas sizes must be positive."
            ))
        }

        if let preferredAngle = manifest.defaults.preferredAngle,
           !manifest.assets.contains(where: { $0.angle == preferredAngle }) {
            issues.append(.init(
                severity: .warning,
                code: .missingPreferredAngleAsset,
                message: "Preferred angle \(preferredAngle.rawValue) has no matching asset."
            ))
        }

        if let preferredPose = manifest.defaults.preferredPose,
           !manifest.assets.contains(where: { $0.pose == preferredPose }) {
            issues.append(.init(
                severity: .warning,
                code: .missingPreferredPoseAsset,
                message: "Preferred pose \(preferredPose.rawValue) has no matching asset."
            ))
        }

        return issues
    }

    private func validateBlueprints(
        _ blueprints: [CharacterGenerationBlueprint],
        assetIDs: Set<UUID>
    ) -> [CharacterPackageValidationIssue] {
        var issues: [CharacterPackageValidationIssue] = []

        for blueprint in blueprints {
            if blueprint.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    severity: .error,
                    code: .emptyBlueprintPrompt,
                    message: "Blueprint \(blueprint.name) has an empty prompt.",
                    blueprintID: blueprint.id
                ))
            }

            if blueprint.outputSpecs.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    code: .emptyBlueprintOutputs,
                    message: "Blueprint \(blueprint.name) does not declare any outputs.",
                    blueprintID: blueprint.id
                ))
            }

            if let canvasSize = blueprint.canvasSize,
               canvasSize.width <= 0 || canvasSize.height <= 0 {
                issues.append(.init(
                    severity: .error,
                    code: .invalidCanvasSize,
                    message: "Blueprint \(blueprint.name) has an invalid canvas size.",
                    blueprintID: blueprint.id
                ))
            }

            for referenceID in blueprint.referenceAssetIDs where !assetIDs.contains(referenceID) {
                issues.append(.init(
                    severity: .error,
                    code: .missingBlueprintReference,
                    message: "Blueprint \(blueprint.name) references unknown asset \(referenceID.uuidString).",
                    blueprintID: blueprint.id
                ))
            }

            for outputSpec in blueprint.outputSpecs where outputSpec.count <= 0 {
                issues.append(.init(
                    severity: .error,
                    code: .invalidOutputCount,
                    message: "Blueprint \(blueprint.name) must request at least one output per spec.",
                    blueprintID: blueprint.id
                ))
            }
        }

        return issues
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard !path.hasPrefix("/") else { return false }

        let components = path.split(separator: "/")
        guard !components.isEmpty else { return false }

        for component in components {
            if component == "." || component == ".." || component.isEmpty {
                return false
            }
        }

        return true
    }
}
