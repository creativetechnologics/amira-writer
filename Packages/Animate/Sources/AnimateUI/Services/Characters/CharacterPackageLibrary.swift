import Foundation
import ProjectKit

struct InstalledCharacterPackage: Identifiable, Sendable {
    var manifest: CharacterPackageManifest
    var manifestURL: URL
    var packageDirectoryURL: URL
    var validationReport: CharacterPackageValidationReport
    var importedAt: Date?

    var id: UUID { manifest.id }
}

struct CharacterPackageLibrary: Sendable {
    private let validator = CharacterPackageValidator()
    private let selectionStore = CharacterPackageSelectionStore()
    private let manifestFilenames = [
        "character-package.json",
        "manifest.json"
    ]

    func installedPackages(
        for characterSlug: String,
        in animateURL: URL,
        preferredActivePackageID: UUID? = nil
    ) -> [InstalledCharacterPackage] {
        let packagesDirectory = ProjectPaths(root: animateURL.deletingLastPathComponent())
            .characterPackages(slug: characterSlug)

        guard let packageDirectories = try? FileManager.default.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let packages = packageDirectories.compactMap { packageDirectoryURL -> InstalledCharacterPackage? in
            let isDirectory = (try? packageDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return nil }

            guard let manifestURL = resolveManifestURL(in: packageDirectoryURL) else { return nil }
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            guard let manifest = try? JSONDecoder().decode(CharacterPackageManifest.self, from: data) else {
                return nil
            }

            let importedAt = try? packageDirectoryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

            return InstalledCharacterPackage(
                manifest: manifest,
                manifestURL: manifestURL,
                packageDirectoryURL: packageDirectoryURL,
                validationReport: validator.validate(manifest),
                importedAt: importedAt ?? nil
            )
        }

        let activePackageID = resolvedActivePackageID(
            from: packages,
            preferredActivePackageID: preferredActivePackageID ?? selectionStore.activePackageID(for: characterSlug, in: animateURL)
        )

        return packages.sorted { lhs, rhs in
            let lhsIsActive = lhs.id == activePackageID
            let rhsIsActive = rhs.id == activePackageID
            if lhsIsActive != rhsIsActive {
                return lhsIsActive
            }

            let lhsIsValid = lhs.validationReport.isValid
            let rhsIsValid = rhs.validationReport.isValid
            if lhsIsValid != rhsIsValid {
                return lhsIsValid
            }

            let lhsDate = lhs.importedAt ?? .distantPast
            let rhsDate = rhs.importedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.manifest.displayName.localizedCaseInsensitiveCompare(rhs.manifest.displayName) == .orderedAscending
        }
    }

    func activePackage(
        for characterSlug: String,
        in animateURL: URL,
        preferredActivePackageID: UUID? = nil
    ) -> InstalledCharacterPackage? {
        installedPackages(
            for: characterSlug,
            in: animateURL,
            preferredActivePackageID: preferredActivePackageID
        ).first
    }

    func deletePackage(_ packageID: UUID, for characterSlug: String, in animateURL: URL) -> Bool {
        let packages = installedPackages(
            for: characterSlug,
            in: animateURL,
            preferredActivePackageID: nil
        )

        guard let package = packages.first(where: { $0.id == packageID }) else {
            NSLog("[CharacterPackageLibrary] Package not found: \(packageID)")
            return false
        }

        do {
            try FileManager.default.removeItem(at: package.packageDirectoryURL)
            NSLog("[CharacterPackageLibrary] Deleted package at: \(package.packageDirectoryURL.path)")
            return true
        } catch {
            NSLog("[CharacterPackageLibrary] Failed to delete: \(error)")
            return false
        }
    }

    func primaryAsset(for package: InstalledCharacterPackage) -> CharacterPackageAsset? {
        package.manifest.assets
            .filter { asset in
                isRenderableImage(path: asset.normalizedRelativePath) &&
                asset.role != .backgroundPlate
            }
            .max { lhs, rhs in
                score(lhs, manifest: package.manifest) < score(rhs, manifest: package.manifest)
            }
    }

    func primaryAssetURL(for package: InstalledCharacterPackage) -> URL? {
        guard let asset = primaryAsset(for: package) else { return nil }
        let assetURL = package.packageDirectoryURL.appendingPathComponent(asset.normalizedRelativePath)
        guard FileManager.default.fileExists(atPath: assetURL.path) else { return nil }
        return assetURL
    }

    private func resolveManifestURL(in packageDirectoryURL: URL) -> URL? {
        let fm = FileManager.default

        for manifestFilename in manifestFilenames {
            let manifestURL = packageDirectoryURL.appendingPathComponent(manifestFilename)
            if fm.fileExists(atPath: manifestURL.path) {
                return manifestURL
            }
        }

        return nil
    }

    private func resolvedActivePackageID(
        from packages: [InstalledCharacterPackage],
        preferredActivePackageID: UUID?
    ) -> UUID? {
        if let preferredActivePackageID,
           packages.contains(where: { $0.id == preferredActivePackageID }) {
            return preferredActivePackageID
        }

        if let newestValid = packages
            .filter({ $0.validationReport.isValid })
            .sorted(by: sortByNewestImportThenName)
            .first {
            return newestValid.id
        }

        return packages.sorted(by: sortByNewestImportThenName).first?.id
    }

    private func sortByNewestImportThenName(
        _ lhs: InstalledCharacterPackage,
        _ rhs: InstalledCharacterPackage
    ) -> Bool {
        let lhsDate = lhs.importedAt ?? .distantPast
        let rhsDate = rhs.importedAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.manifest.displayName.localizedCaseInsensitiveCompare(rhs.manifest.displayName) == .orderedAscending
    }

    private func score(_ asset: CharacterPackageAsset, manifest: CharacterPackageManifest) -> Int {
        var score = 0

        switch asset.role {
        case .basePose:
            score += 120
        case .turnaround:
            score += 100
        case .heroPose:
            score += 80
        case .reference:
            score += 40
        case .expression, .viseme, .handPose, .costumeOverlay, .propOverlay, .backgroundPlate:
            score += 10
        }

        if asset.angle == manifest.defaults.preferredAngle {
            score += 35
        }
        if asset.pose == manifest.defaults.preferredPose {
            score += 35
        }

        if asset.angle == .front {
            score += 24
        }
        if asset.angle == .threeQuarterFront {
            score += 18
        }
        if asset.pose == .frontal {
            score += 24
        }
        if asset.pose == .neutral {
            score += 18
        }

        let tags = asset.tags.joined(separator: " ").lowercased()
        if tags.contains("default") { score += 20 }
        if tags.contains("hero") { score += 12 }
        if tags.contains("render") { score += 10 }

        score += fallbackScore(for: asset.normalizedRelativePath)
        return score
    }

    private func fallbackScore(for path: String) -> Int {
        let lowercased = path.lowercased()
        var score = 0

        if lowercased.contains("base") { score += 80 }
        if lowercased.contains("turnaround") { score += 70 }
        if lowercased.contains("frontal") { score += 60 }
        if lowercased.contains("front") { score += 40 }
        if lowercased.contains("neutral") { score += 32 }
        if lowercased.contains("hero") { score += 24 }
        if lowercased.contains("pose") { score += 18 }
        if lowercased.contains("action") { score += 14 }
        if lowercased.contains("reference") { score += 10 }
        if lowercased.contains("sheet") { score -= 20 }
        if lowercased.contains("comparison") { score -= 30 }
        if lowercased.contains("contact-sheet") { score -= 30 }

        return score
    }

    private func isRenderableImage(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "heic"].contains(ext)
    }
}
