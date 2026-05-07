import Foundation

@available(macOS 26.0, *)
struct GenerationReferenceImageItem: Identifiable, Hashable, Sendable {
    var id: String { "\(resolvedPath)|\(role ?? "")" }
    var rawPath: String
    var resolvedPath: String
    var role: String?
    var label: String?
}

@available(macOS 26.0, *)
enum GenerationReferenceImageResolver {
    static func referenceItems(forImagePath imagePath: String, projectRoot: URL?) -> [GenerationReferenceImageItem] {
        let imageURL = URL(fileURLWithPath: imagePath)
        let sidecars = [
            imageURL.deletingPathExtension().appendingPathExtension("continuity.json"),
            imageURL.deletingPathExtension().appendingPathExtension("plan.json"),
            imageURL.deletingPathExtension().appendingPathExtension("json")
        ]
        var items: [GenerationReferenceImageItem] = []
        var seen = Set<String>()

        func appendUnique(_ extracted: [GenerationReferenceImageItem]) {
            for item in extracted {
                guard seen.insert(item.resolvedPath).inserted else { continue }
                items.append(item)
            }
        }

        for url in sidecars {
            guard let object = jsonObject(at: url) else { continue }
            appendUnique(referenceItems(in: object, imageURL: imageURL, projectRoot: projectRoot))
        }

        appendUnique(manifestReferenceItems(for: imageURL, projectRoot: projectRoot))

        return items
    }

    static func resolveReferencePath(_ rawPath: String, imageURL: URL? = nil, projectRoot: URL?) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fm = FileManager.default

        if trimmed.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            return fm.fileExists(atPath: absolute) ? absolute : nil
        }

        var candidates: [URL] = []
        if let projectRoot {
            candidates.append(projectRoot.appendingPathComponent(trimmed))
            if !trimmed.hasPrefix("Animate/") {
                candidates.append(projectRoot.appendingPathComponent("Animate").appendingPathComponent(trimmed))
            }
            if trimmed.hasPrefix("characters/") {
                candidates.append(projectRoot.appendingPathComponent("Animate").appendingPathComponent(trimmed))
                candidates.append(projectRoot.appendingPathComponent("Characters").appendingPathComponent(String(trimmed.dropFirst("characters/".count))))
            }
            if trimmed.hasPrefix("backgrounds/") || trimmed.hasPrefix("Canvas/") {
                candidates.append(projectRoot.appendingPathComponent("Animate").appendingPathComponent(trimmed))
            }
        }
        if let imageURL {
            candidates.append(imageURL.deletingLastPathComponent().appendingPathComponent(trimmed))
        }

        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if fm.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func manifestReferenceItems(
        for imageURL: URL,
        projectRoot: URL?
    ) -> [GenerationReferenceImageItem] {
        guard let projectRoot else { return [] }
        var items: [GenerationReferenceImageItem] = []
        for manifestURL in manifestCandidateURLs(for: imageURL, projectRoot: projectRoot) {
            guard let object = jsonObject(at: manifestURL) else { continue }
            for output in matchingOutputDictionaries(in: object, imageURL: imageURL, projectRoot: projectRoot) {
                items.append(contentsOf: referenceItems(in: output, imageURL: imageURL, projectRoot: projectRoot))
            }
        }
        return items
    }

    private static func manifestCandidateURLs(for imageURL: URL, projectRoot: URL) -> [URL] {
        var candidates: [URL] = [
            imageURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        ]

        let components = imageURL.standardizedFileURL.pathComponents
        if let studiesIndex = components.firstIndex(of: "costume-studies"),
           components.indices.contains(studiesIndex + 1) {
            let runID = components[studiesIndex + 1]
            candidates.append(
                projectRoot
                    .appendingPathComponent("Metadata", isDirectory: true)
                    .appendingPathComponent("automation", isDirectory: true)
                    .appendingPathComponent("vertex-character-costumes", isDirectory: true)
                    .appendingPathComponent(runID, isDirectory: true)
                    .appendingPathComponent("manifest.json")
            )
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert(candidate.standardizedFileURL.path).inserted
        }
    }

    private static func matchingOutputDictionaries(
        in object: [String: Any],
        imageURL: URL,
        projectRoot: URL
    ) -> [[String: Any]] {
        guard let outputs = object["outputs"] as? [[String: Any]] else {
            return manifestOutputMatches(object, imageURL: imageURL, projectRoot: projectRoot) ? [object] : []
        }
        return outputs.filter { manifestOutputMatches($0, imageURL: imageURL, projectRoot: projectRoot) }
    }

    private static func manifestOutputMatches(
        _ output: [String: Any],
        imageURL: URL,
        projectRoot: URL
    ) -> Bool {
        let imagePath = imageURL.standardizedFileURL.path
        let projectRootPath = projectRoot.standardizedFileURL.path
        let relativePath: String? = imagePath.hasPrefix(projectRootPath + "/")
            ? String(imagePath.dropFirst(projectRootPath.count + 1))
            : nil
        let filename = imageURL.lastPathComponent
        let pathKeys = ["path", "imagePath", "image_path", "outputPath", "output_path", "absolutePath", "absolute_path"]

        for key in pathKeys {
            guard let rawPath = stringValue(output[key]) else { continue }
            let slashNormalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            if rawPath.hasPrefix("/"),
               URL(fileURLWithPath: rawPath).standardizedFileURL.path == imagePath {
                return true
            }
            if let relativePath, slashNormalized == relativePath {
                return true
            }
            if slashNormalized.hasSuffix("/\(filename)") {
                return true
            }
        }

        return false
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func referenceItems(
        in object: [String: Any],
        imageURL: URL,
        projectRoot: URL?
    ) -> [GenerationReferenceImageItem] {
        var items: [GenerationReferenceImageItem] = []

        for detail in detailDictionaries(in: object) {
            guard let rawPath = stringValue(detail["path"] ?? detail["imagePath"] ?? detail["referencePath"]),
                  let resolved = resolveReferencePath(rawPath, imageURL: imageURL, projectRoot: projectRoot) else { continue }
            items.append(
                GenerationReferenceImageItem(
                    rawPath: rawPath,
                    resolvedPath: resolved,
                    role: stringValue(detail["role"] ?? detail["referenceRole"] ?? detail["kind"]),
                    label: stringValue(detail["label"] ?? detail["title"] ?? detail["name"])
                )
            )
        }

        for sourceImage in sourceImageDictionaries(in: object) {
            guard let rawPath = stringValue(sourceImage["path"] ?? sourceImage["imagePath"] ?? sourceImage["referencePath"]),
                  !items.contains(where: { $0.rawPath == rawPath }),
                  let resolved = resolveReferencePath(rawPath, imageURL: imageURL, projectRoot: projectRoot) else { continue }
            items.append(
                GenerationReferenceImageItem(
                    rawPath: rawPath,
                    resolvedPath: resolved,
                    role: "edit_source",
                    label: stringValue(sourceImage["source"] ?? sourceImage["moment"] ?? sourceImage["note"]) ?? "Edit source"
                )
            )
        }

        let existingRawPaths = Set(items.map(\.rawPath))
        for rawPath in referencePaths(in: object) where !existingRawPaths.contains(rawPath) {
            guard let resolved = resolveReferencePath(rawPath, imageURL: imageURL, projectRoot: projectRoot) else { continue }
            items.append(
                GenerationReferenceImageItem(
                    rawPath: rawPath,
                    resolvedPath: resolved,
                    role: nil,
                    label: nil
                )
            )
        }

        if let request = object["request"] as? [String: Any] {
            let nestedExisting = Set(items.map(\.rawPath))
            for rawPath in referencePaths(in: request) where !nestedExisting.contains(rawPath) {
                guard let resolved = resolveReferencePath(rawPath, imageURL: imageURL, projectRoot: projectRoot) else { continue }
                items.append(
                    GenerationReferenceImageItem(
                        rawPath: rawPath,
                        resolvedPath: resolved,
                        role: nil,
                        label: nil
                    )
                )
            }
            for detail in detailDictionaries(in: request) {
                guard let rawPath = stringValue(detail["path"] ?? detail["imagePath"] ?? detail["referencePath"]),
                      !items.contains(where: { $0.rawPath == rawPath }),
                      let resolved = resolveReferencePath(rawPath, imageURL: imageURL, projectRoot: projectRoot) else { continue }
                items.append(
                    GenerationReferenceImageItem(
                        rawPath: rawPath,
                        resolvedPath: resolved,
                        role: stringValue(detail["role"] ?? detail["referenceRole"] ?? detail["kind"]),
                        label: stringValue(detail["label"] ?? detail["title"] ?? detail["name"])
                    )
                )
            }
        }

        return items
    }

    private static func detailDictionaries(in object: [String: Any]) -> [[String: Any]] {
        (object["referenceDetails"] as? [[String: Any]])
            ?? (object["reference_details"] as? [[String: Any]])
            ?? []
    }

    private static func sourceImageDictionaries(in object: [String: Any]) -> [[String: Any]] {
        var dictionaries: [[String: Any]] = []
        if let sourceImage = object["sourceImage"] as? [String: Any] {
            dictionaries.append(sourceImage)
        }
        if let sourceImage = object["source_image"] as? [String: Any] {
            dictionaries.append(sourceImage)
        }
        if let request = object["request"] as? [String: Any] {
            dictionaries.append(contentsOf: sourceImageDictionaries(in: request))
        }
        return dictionaries
    }

    private static func referencePaths(in object: [String: Any]) -> [String] {
        let candidates: [Any?] = [
            object["referencePaths"],
            object["reference_paths"],
            object["referenceImagePaths"],
            object["reference_image_paths"],
            object["automaticReferenceImagePaths"],
            object["automatic_reference_image_paths"]
        ]
        return candidates
            .compactMap { $0 as? [String] }
            .flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
