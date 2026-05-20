import Foundation

/// Compatibility bridge for the canonical `Scenes/<slug>/` package layout.
///
/// Older Write/Score/Mix/Animate code still presents scenes as legacy
/// `Songs/*.ows` entries.  The active Amira project has already moved the real
/// scene data into per-scene packages:
///
///     Scenes/scene-index.json
///     Scenes/<slug>/scene.json
///     Scenes/<slug>/versions/<version-id>/{manuscript.md,score.playback.json,shots.json}
///
/// This reader exposes those scene packages through a lightweight legacy-OWS
/// shape so the existing workspaces can load the canonical project without
/// requiring a destructive re-materialization of `Songs/*.ows` files.
public enum ScenePackageReader {
    public static let scenesDirectoryName = "Scenes"
    public static let sceneIndexFileName = "scene-index.json"
    public static let sceneFileName = "scene.json"

    public struct Descriptor: Sendable, Hashable {
        public let id: UUID
        public let title: String
        public let canonicalTitle: String
        public let legacySongPath: String
        public let order: Int
        public let sceneDirectoryURL: URL
        public let sceneJSONURL: URL
        public let fileSize: Int64
        public let updatedAt: String?

        public init(
            id: UUID,
            title: String,
            canonicalTitle: String,
            legacySongPath: String,
            order: Int,
            sceneDirectoryURL: URL,
            sceneJSONURL: URL,
            fileSize: Int64,
            updatedAt: String?
        ) {
            self.id = id
            self.title = title
            self.canonicalTitle = canonicalTitle
            self.legacySongPath = legacySongPath
            self.order = order
            self.sceneDirectoryURL = sceneDirectoryURL
            self.sceneJSONURL = sceneJSONURL
            self.fileSize = fileSize
            self.updatedAt = updatedAt
        }
    }

    public static func scenesRoot(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(scenesDirectoryName, isDirectory: true)
    }

    public static func sceneIndexURL(in projectURL: URL) -> URL {
        scenesRoot(in: projectURL).appendingPathComponent(sceneIndexFileName)
    }

    public static func isScenePackageSceneJSON(_ url: URL) -> Bool {
        url.lastPathComponent == sceneFileName
            && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == scenesDirectoryName
    }

    public static func discover(
        in projectURL: URL,
        fileManager fm: FileManager = .default
    ) -> [Descriptor] {
        let scenesRoot = scenesRoot(in: projectURL)
        var descriptors: [Descriptor] = []
        var seenSceneJSONPaths: Set<String> = []

        if let indexObject = jsonObject(at: sceneIndexURL(in: projectURL)) as? [String: Any],
           let entries = indexObject["scenes"] as? [[String: Any]] {
            for (index, entry) in entries.enumerated() {
                guard let sceneJSONURL = resolveSceneJSONURL(
                    scenesRoot: scenesRoot,
                    indexEntry: entry,
                    fileManager: fm
                ) else {
                    continue
                }
                guard seenSceneJSONPaths.insert(sceneJSONURL.standardizedFileURL.path).inserted else { continue }
                let root = jsonObject(at: sceneJSONURL) as? [String: Any]
                if let descriptor = makeDescriptor(
                    sceneJSONURL: sceneJSONURL,
                    sceneRoot: root,
                    indexEntry: entry,
                    fallbackOrder: index
                ) {
                    descriptors.append(descriptor)
                }
            }
        }

        if let enumerator = fm.enumerator(
            at: scenesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.lastPathComponent == sceneFileName else { continue }
                guard seenSceneJSONPaths.insert(fileURL.standardizedFileURL.path).inserted else { continue }
                let root = jsonObject(at: fileURL) as? [String: Any]
                if let descriptor = makeDescriptor(
                    sceneJSONURL: fileURL,
                    sceneRoot: root,
                    indexEntry: nil,
                    fallbackOrder: descriptors.count
                ) {
                    descriptors.append(descriptor)
                }
            }
        }

        return descriptors.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.legacySongPath.localizedStandardCompare(rhs.legacySongPath) == .orderedAscending
        }
    }

    public static func sceneJSONURL(
        forLegacySongPath legacySongPath: String,
        in projectURL: URL,
        fileManager fm: FileManager = .default
    ) -> URL? {
        let normalized = normalizeLegacySongPath(legacySongPath)
        return discover(in: projectURL, fileManager: fm).first {
            normalizeLegacySongPath($0.legacySongPath) == normalized
        }?.sceneJSONURL
    }

    public static func makeLegacyOWSData(sceneJSONURL: URL) throws -> Data {
        let object = try makeLegacyOWSObject(sceneJSONURL: sceneJSONURL)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    public static func makeLegacyOWSObject(sceneJSONURL: URL) throws -> [String: Any] {
        guard let sceneRoot = jsonObject(at: sceneJSONURL) as? [String: Any] else {
            throw NSError(
                domain: "ScenePackageReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode scene package root at \(sceneJSONURL.path)"]
            )
        }

        let sceneID = string(sceneRoot["id"]) ?? UUID().uuidString
        let songID = string(sceneRoot["songID"]) ?? sceneID
        let title = string(sceneRoot["title"]) ?? sceneJSONURL.deletingLastPathComponent().lastPathComponent
        let canonicalTitle = string(sceneRoot["canonicalTitle"])
            ?? string(sceneRoot["slug"])
            ?? slugify(title)
        let updatedAt = string(sceneRoot["updatedAt"]) ?? ISO8601DateFormatter().string(from: Date())
        let activeVersionID = string(sceneRoot["activeVersionID"])
        let versionMetas = sceneRoot["versions"] as? [[String: Any]] ?? []
        let versionOrder = sceneRoot["versionOrder"] as? [String] ?? []

        var versions: [[String: Any]] = []
        if versionMetas.isEmpty {
            let versionID = activeVersionID ?? UUID().uuidString
            versions.append(legacyVersionObject(
                sceneDirectoryURL: sceneJSONURL.deletingLastPathComponent(),
                sceneID: sceneID,
                metadata: [
                    "id": versionID,
                    "label": "Current Draft",
                    "saveType": "imported",
                    "createdAt": updatedAt,
                    "updatedAt": updatedAt,
                    "isBookmarked": false,
                ]
            ))
        } else {
            for metadata in sortedVersionMetas(versionMetas, activeVersionID: activeVersionID, versionOrder: versionOrder) {
                versions.append(legacyVersionObject(
                    sceneDirectoryURL: sceneJSONURL.deletingLastPathComponent(),
                    sceneID: sceneID,
                    metadata: metadata
                ))
            }
        }

        var root: [String: Any] = [
            "songID": songID,
            "title": title,
            "canonicalTitle": canonicalTitle,
            "notes": string(sceneRoot["notes"]) ?? string(sceneRoot["synopsis"]) ?? "",
            "updatedAt": updatedAt,
            "versions": versions,
        ]
        if let activeVersionID {
            root["activeVersionID"] = activeVersionID
        }
        return root
    }

    public static func patchScenePackageFromLegacyOWSObject(
        sceneJSONURL: URL,
        legacyRoot: [String: Any]
    ) throws {
        guard var sceneRoot = jsonObject(at: sceneJSONURL) as? [String: Any] else {
            throw NSError(
                domain: "ScenePackageReader",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode scene package root at \(sceneJSONURL.path)"]
            )
        }

        let sceneID = string(sceneRoot["id"]) ?? string(legacyRoot["songID"]) ?? UUID().uuidString
        if let title = string(legacyRoot["title"]) { sceneRoot["title"] = title }
        if let canonicalTitle = string(legacyRoot["canonicalTitle"]) { sceneRoot["canonicalTitle"] = canonicalTitle }
        if let notes = string(legacyRoot["notes"]) { sceneRoot["notes"] = notes }
        if let updatedAt = string(legacyRoot["updatedAt"]) { sceneRoot["updatedAt"] = updatedAt }
        if let activeVersionID = string(legacyRoot["activeVersionID"]) { sceneRoot["activeVersionID"] = activeVersionID }

        let sceneDirectoryURL = sceneJSONURL.deletingLastPathComponent()
        let versionObjects = legacyRoot["versions"] as? [[String: Any]] ?? []
        var sceneVersionMetas: [[String: Any]] = []
        var versionOrder: [String] = []

        for version in versionObjects {
            guard let versionID = string(version["id"]) else { continue }
            versionOrder.append(versionID)
            sceneVersionMetas.append(sceneVersionMetadata(from: version))

            let versionDirectoryURL = sceneDirectoryURL
                .appendingPathComponent("versions", isDirectory: true)
                .appendingPathComponent(versionID, isDirectory: true)
            try FileManager.default.createDirectory(at: versionDirectoryURL, withIntermediateDirectories: true)

            if let lyrics = string(version["lyrics"]) {
                try Data(lyrics.utf8).write(
                    to: versionDirectoryURL.appendingPathComponent("manuscript.md"),
                    options: .atomic
                )
            }

            let playbackObject = version["playback"] ?? version["playbackSnapshot"]
            if let playbackObject,
               JSONSerialization.isValidJSONObject(playbackObject) {
                let payload: [String: Any] = [
                    "schemaVersion": 1,
                    "sceneID": sceneID,
                    "versionID": versionID,
                    "playback": playbackObject,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: versionDirectoryURL.appendingPathComponent("score.playback.json"), options: .atomic)
            }
        }

        if !sceneVersionMetas.isEmpty {
            sceneRoot["versions"] = sceneVersionMetas
            sceneRoot["versionOrder"] = versionOrder
        }

        let data = try JSONSerialization.data(withJSONObject: sceneRoot, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sceneJSONURL, options: .atomic)
    }

    public static func activeVersionDirectory(sceneJSONURL: URL) -> URL? {
        guard let sceneRoot = jsonObject(at: sceneJSONURL) as? [String: Any] else { return nil }
        let activeID = string(sceneRoot["activeVersionID"])
            ?? (sceneRoot["versionOrder"] as? [String])?.last
            ?? (sceneRoot["versions"] as? [[String: Any]])?.compactMap { string($0["id"]) }.last
        guard let activeID else { return nil }
        let versionURL = sceneJSONURL.deletingLastPathComponent()
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(activeID, isDirectory: true)
        return FileManager.default.fileExists(atPath: versionURL.path) ? versionURL : nil
    }

    public static func normalizeLegacySongPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
    }

    // MARK: - Private helpers

    private static func resolveSceneJSONURL(
        scenesRoot: URL,
        indexEntry: [String: Any],
        fileManager fm: FileManager
    ) -> URL? {
        var candidateNames: [String] = []
        for key in ["slug", "canonicalTitle", "folderName", "packagePath"] {
            if let value = string(indexEntry[key]), !value.isEmpty {
                let name = value.split(separator: "/").last.map(String.init) ?? value
                candidateNames.append(name)
            }
        }
        if let title = string(indexEntry["title"]) { candidateNames.append(slugify(title)) }
        if let id = string(indexEntry["id"]) {
            candidateNames.append(id)
            candidateNames.append(id.uppercased())
            candidateNames.append(id.lowercased())
        }

        var seen: Set<String> = []
        for name in candidateNames where seen.insert(name).inserted {
            let url = scenesRoot.appendingPathComponent(name, isDirectory: true).appendingPathComponent(sceneFileName)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func makeDescriptor(
        sceneJSONURL: URL,
        sceneRoot: [String: Any]?,
        indexEntry: [String: Any]?,
        fallbackOrder: Int
    ) -> Descriptor? {
        let root = sceneRoot ?? [:]
        let entry = indexEntry ?? [:]
        let title = string(root["title"]) ?? string(entry["title"]) ?? sceneJSONURL.deletingLastPathComponent().lastPathComponent
        let canonicalTitle = string(root["canonicalTitle"])
            ?? string(entry["canonicalTitle"])
            ?? string(root["slug"])
            ?? string(entry["slug"])
            ?? slugify(title)
        let id = uuid(root["id"]) ?? uuid(entry["id"]) ?? uuid(root["songID"]) ?? UUID()
        let legacy = legacySongPath(sceneRoot: root, indexEntry: entry, title: title)
        let order = int(root["order"]) ?? int(entry["order"]) ?? fallbackOrder
        let fileSize = (try? sceneJSONURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return Descriptor(
            id: id,
            title: title,
            canonicalTitle: canonicalTitle,
            legacySongPath: legacy,
            order: order,
            sceneDirectoryURL: sceneJSONURL.deletingLastPathComponent(),
            sceneJSONURL: sceneJSONURL,
            fileSize: fileSize,
            updatedAt: string(root["updatedAt"]) ?? string(entry["updatedAt"])
        )
    }

    private static func legacySongPath(sceneRoot: [String: Any], indexEntry: [String: Any], title: String) -> String {
        if let legacy = sceneRoot["legacy"] as? [String: Any],
           let path = string(legacy["owsPath"]),
           !path.isEmpty {
            return path
        }
        for key in ["legacySongPath", "owsPath", "relativePath"] {
            if let path = string(indexEntry[key]), !path.isEmpty { return path }
            if let path = string(sceneRoot[key]), !path.isEmpty { return path }
        }
        return "Songs/\(title).ows"
    }

    private static func sortedVersionMetas(
        _ metas: [[String: Any]],
        activeVersionID: String?,
        versionOrder: [String]
    ) -> [[String: Any]] {
        if !versionOrder.isEmpty {
            let order = Dictionary(uniqueKeysWithValues: versionOrder.enumerated().map { ($0.element, $0.offset) })
            return metas.sorted {
                let lhsID = string($0["id"]) ?? ""
                let rhsID = string($1["id"]) ?? ""
                return (order[lhsID] ?? Int.max) < (order[rhsID] ?? Int.max)
            }
        }
        if let activeVersionID,
           let activeIndex = metas.firstIndex(where: { string($0["id"]) == activeVersionID }) {
            var ordered = metas
            let active = ordered.remove(at: activeIndex)
            ordered.append(active)
            return ordered
        }
        return metas
    }

    private static func legacyVersionObject(
        sceneDirectoryURL: URL,
        sceneID: String,
        metadata: [String: Any]
    ) -> [String: Any] {
        let versionID = string(metadata["id"]) ?? UUID().uuidString
        let versionDirectoryURL = sceneDirectoryURL
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(versionID, isDirectory: true)

        var version = metadata
        version["id"] = versionID
        version["label"] = string(version["label"]) ?? "Current Draft"
        version["saveType"] = string(version["saveType"]) ?? "imported"
        version["isBookmarked"] = bool(version["isBookmarked"]) ?? false

        let now = ISO8601DateFormatter().string(from: Date())
        version["createdAt"] = string(version["createdAt"]) ?? now
        version["updatedAt"] = string(version["updatedAt"]) ?? string(metadata["createdAt"]) ?? now
        version["lyrics"] = readManuscript(in: versionDirectoryURL) ?? scriptBlocksText(in: versionDirectoryURL) ?? ""

        if let playbackObject = playbackObject(in: versionDirectoryURL) {
            version["playback"] = playbackObject
            version["playbackSnapshot"] = playbackObject
        }

        return version
    }

    private static func sceneVersionMetadata(from legacyVersion: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["id", "label", "createdAt", "updatedAt", "saveType", "userLabel", "isBookmarked"] {
            if let value = legacyVersion[key] { result[key] = value }
        }
        if result["label"] == nil { result["label"] = "Current Draft" }
        if result["saveType"] == nil { result["saveType"] = "imported" }
        if result["isBookmarked"] == nil { result["isBookmarked"] = false }
        return result
    }

    private static func readManuscript(in versionDirectoryURL: URL) -> String? {
        let url = versionDirectoryURL.appendingPathComponent("manuscript.md")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func scriptBlocksText(in versionDirectoryURL: URL) -> String? {
        let url = versionDirectoryURL.appendingPathComponent("script.json")
        guard let root = jsonObject(at: url) as? [String: Any],
              let blocks = root["blocks"] as? [[String: Any]] else {
            return nil
        }
        let lines = blocks.compactMap { block -> String? in
            guard let text = string(block["text"]), !text.isEmpty else { return nil }
            if let speaker = string(block["speaker"]), !speaker.isEmpty {
                return "## \(speaker.uppercased())\n\(text)"
            }
            if string(block["type"]) == "action" {
                return "[Action]\n\(text)"
            }
            return text
        }
        return lines.joined(separator: "\n\n")
    }

    private static func playbackObject(in versionDirectoryURL: URL) -> Any? {
        let url = versionDirectoryURL.appendingPathComponent("score.playback.json")
        guard let root = jsonObject(at: url) as? [String: Any] else { return nil }
        return root["playback"] ?? root["playbackSnapshot"]
    }

    private static func jsonObject(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as UUID:
            return value.uuidString
        default:
            return nil
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let raw = string(value) else { return nil }
        return UUID(uuidString: raw)
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            return ["true", "yes", "1"].contains(value.lowercased())
        default:
            return nil
        }
    }

    private static func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let replaced = lower.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
