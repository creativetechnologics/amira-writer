import Foundation

@available(macOS 26.0, *)
struct Animate3DCharacterAssetService {
    func inventory(
        for characterSlug: String,
        in animateURL: URL?
    ) -> Animate3DCharacterAssetInventory {
        guard let animateURL else {
            return Animate3DCharacterAssetInventory(characterSlug: characterSlug)
        }

        var assetsByCategory: [Animate3DCharacterAssetCategory: [Animate3DCharacterAssetFile]] = [:]
        for category in Animate3DCharacterAssetCategory.allCases {
            let folderURL = categoryFolderURL(for: characterSlug, category: category, in: animateURL)
            assetsByCategory[category] = scanFiles(in: folderURL, category: category)
        }

        return Animate3DCharacterAssetInventory(
            characterSlug: characterSlug,
            assetsByCategory: assetsByCategory
        )
    }

    func ensureFolders(
        for characterSlug: String,
        in animateURL: URL?
    ) throws {
        guard let animateURL else { return }
        let fm = FileManager.default
        let characterRoot = characterRootURL(for: characterSlug, in: animateURL)
        try fm.createDirectory(at: characterRoot, withIntermediateDirectories: true)
        for category in Animate3DCharacterAssetCategory.allCases {
            let folderURL = categoryFolderURL(for: characterSlug, category: category, in: animateURL)
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
    }

    func importFiles(
        for characterSlug: String,
        category: Animate3DCharacterAssetCategory,
        from sourceURLs: [URL],
        in animateURL: URL?
    ) throws -> [URL] {
        guard let animateURL else { return [] }

        try ensureFolders(for: characterSlug, in: animateURL)
        let folderURL = categoryFolderURL(for: characterSlug, category: category, in: animateURL)
        let fm = FileManager.default
        var imported: [URL] = []

        for sourceURL in sourceURLs {
            let destinationURL = uniqueDestinationURL(for: sourceURL, in: folderURL)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: sourceURL, to: destinationURL)
            imported.append(destinationURL)
        }

        return imported
    }

    func removeFile(
        for characterSlug: String,
        category: Animate3DCharacterAssetCategory,
        relativePath: String,
        in animateURL: URL?
    ) throws {
        guard let animateURL else { return }

        let fileURL = categoryFolderURL(for: characterSlug, category: category, in: animateURL)
            .appendingPathComponent(relativePath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func fileURL(
        for characterSlug: String,
        category: Animate3DCharacterAssetCategory,
        relativePath: String,
        in animateURL: URL?
    ) -> URL? {
        guard let animateURL else { return nil }
        let url = categoryFolderURL(for: characterSlug, category: category, in: animateURL)
            .appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func characterRootURL(
        for characterSlug: String,
        in animateURL: URL
    ) -> URL {
        animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(characterSlug)
    }

    func categoryFolderURL(
        for characterSlug: String,
        category: Animate3DCharacterAssetCategory,
        in animateURL: URL
    ) -> URL {
        characterRootURL(for: characterSlug, in: animateURL)
            .appendingPathComponent(category.folderName)
    }

    private func scanFiles(
        in folderURL: URL,
        category: Animate3DCharacterAssetCategory
    ) -> [Animate3DCharacterAssetFile] {
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }

        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [Animate3DCharacterAssetFile] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true else { continue }

            let relativePath = relativePath(for: url, baseURL: folderURL)
            files.append(
                Animate3DCharacterAssetFile(
                    category: category,
                    relativePath: relativePath,
                    fileName: url.lastPathComponent,
                    fileSize: Int64(values?.fileSize ?? 0),
                    modificationDate: values?.contentModificationDate
                )
            )
        }

        return files.sorted { lhs, rhs in
            let lhsDate = lhs.modificationDate ?? .distantPast
            let rhsDate = rhs.modificationDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private func relativePath(for url: URL, baseURL: URL) -> String {
        let base = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard url.path.hasPrefix(base) else { return url.lastPathComponent }
        return String(url.path.dropFirst(base.count))
    }

    private func uniqueDestinationURL(for sourceURL: URL, in folderURL: URL) -> URL {
        let fm = FileManager.default
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        var candidate = folderURL.appendingPathComponent(sourceURL.lastPathComponent)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let suffix = "-\(index)"
            let filename = ext.isEmpty ? originalName + suffix : "\(originalName)\(suffix).\(ext)"
            candidate = folderURL.appendingPathComponent(filename)
            index += 1
        }
        return candidate
    }
}
