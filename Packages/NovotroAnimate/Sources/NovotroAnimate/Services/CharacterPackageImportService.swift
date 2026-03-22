import Foundation

struct CharacterPackageImportBundle: Sendable {
    var packageURL: URL
    var manifestURL: URL
    var manifest: CharacterPackageManifest
    var validationReport: CharacterPackageValidationReport
}

struct CharacterPackageImportPlan: Sendable {
    struct CopyOperation: Identifiable, Sendable, Hashable {
        var id: UUID
        var assetID: UUID
        var role: CharacterPackageAssetRole
        var sourceURL: URL
        var destinationURL: URL

        init(
            id: UUID = UUID(),
            assetID: UUID,
            role: CharacterPackageAssetRole,
            sourceURL: URL,
            destinationURL: URL
        ) {
            self.id = id
            self.assetID = assetID
            self.role = role
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
        }
    }

    var packageURL: URL
    var manifestURL: URL
    var manifest: CharacterPackageManifest
    var validationReport: CharacterPackageValidationReport
    var targetCharacterSlug: String
    var stagingDirectoryURL: URL
    var copyOperations: [CopyOperation]
}

enum CharacterPackageImportError: LocalizedError, Sendable {
    case manifestNotFound(packageURL: URL)
    case invalidManifest([CharacterPackageValidationIssue])
    case missingAsset(relativePath: String)
    case unsafeRelativePath(String)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound(let packageURL):
            return "No character package manifest was found in \(packageURL.lastPathComponent)."
        case .invalidManifest(let issues):
            let summary = issues
                .filter { $0.severity == .error }
                .prefix(3)
                .map(\.message)
                .joined(separator: " ")
            return summary.isEmpty ? "The character package manifest is invalid." : summary
        case .missingAsset(let relativePath):
            return "Missing package asset at \(relativePath)."
        case .unsafeRelativePath(let path):
            return "Asset path \(path) cannot be imported outside the package root."
        }
    }
}

struct CharacterPackageImportService: Sendable {
    static let manifestFilenames = [
        "character-package.json",
        "manifest.json"
    ]

    private let validator = CharacterPackageValidator()

    func loadPackage(from packageURL: URL) throws -> CharacterPackageImportBundle {
        let manifestURL = try resolveManifestURL(in: packageURL)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CharacterPackageManifest.self, from: data)
        let validationReport = validator.validate(manifest)

        return CharacterPackageImportBundle(
            packageURL: packageURL,
            manifestURL: manifestURL,
            manifest: manifest,
            validationReport: validationReport
        )
    }

    func makeImportPlan(
        from packageURL: URL,
        into animateURL: URL,
        targetCharacterSlug: String? = nil
    ) throws -> CharacterPackageImportPlan {
        let bundle = try loadPackage(from: packageURL)
        let blockingIssues = bundle.validationReport.issues.filter { $0.severity == .error }
        guard blockingIssues.isEmpty else {
            throw CharacterPackageImportError.invalidManifest(blockingIssues)
        }

        let resolvedTargetSlug = normalizeTargetSlug(targetCharacterSlug ?? bundle.manifest.normalizedSlug)
        var stagedManifest = bundle.manifest
        stagedManifest.slug = resolvedTargetSlug

        let stagingDirectoryURL = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(resolvedTargetSlug)
            .appendingPathComponent("packages")
            .appendingPathComponent(stagedManifest.id.uuidString)

        let copyOperations = try stagedManifest.assets.map { asset in
            let relativePath = try validatedRelativePath(for: asset)

            let sourceURL = packageURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw CharacterPackageImportError.missingAsset(relativePath: relativePath)
            }

            return CharacterPackageImportPlan.CopyOperation(
                assetID: asset.id,
                role: asset.role,
                sourceURL: sourceURL,
                destinationURL: stagingDirectoryURL.appendingPathComponent(relativePath)
            )
        }

        return CharacterPackageImportPlan(
            packageURL: bundle.packageURL,
            manifestURL: bundle.manifestURL,
            manifest: stagedManifest,
            validationReport: bundle.validationReport,
            targetCharacterSlug: resolvedTargetSlug,
            stagingDirectoryURL: stagingDirectoryURL,
            copyOperations: copyOperations
        )
    }

    func execute(_ plan: CharacterPackageImportPlan) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plan.stagingDirectoryURL, withIntermediateDirectories: true)

        for operation in plan.copyOperations {
            let directory = operation.destinationURL.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            if fm.fileExists(atPath: operation.destinationURL.path) {
                try fm.removeItem(at: operation.destinationURL)
            }

            try fm.copyItem(at: operation.sourceURL, to: operation.destinationURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(plan.manifest)
        try manifestData.write(to: plan.stagingDirectoryURL.appendingPathComponent("character-package.json"))
    }

    private func resolveManifestURL(in packageURL: URL) throws -> URL {
        let fm = FileManager.default

        for filename in Self.manifestFilenames {
            let candidate = packageURL.appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw CharacterPackageImportError.manifestNotFound(packageURL: packageURL)
    }

    private func validatedRelativePath(for asset: CharacterPackageAsset) throws -> String {
        let relativePath = asset.normalizedRelativePath
        let report = validator.validate(CharacterPackageManifest(
            slug: "validation",
            displayName: "Validation",
            assets: [asset]
        ))

        if report.issues.contains(where: {
            $0.severity == .error && $0.code == .invalidRelativePath
        }) {
            throw CharacterPackageImportError.unsafeRelativePath(relativePath)
        }

        return relativePath
    }

    private func normalizeTargetSlug(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var normalized = String(normalizedScalars)

        while normalized.contains("--") {
            normalized = normalized.replacingOccurrences(of: "--", with: "-")
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
