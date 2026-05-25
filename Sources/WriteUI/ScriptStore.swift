import Foundation
import ProjectKit
import SwiftUI

// MARK: - Write-Only Models (not shared via ProjectKit)

struct SongLyricIterationFile: Identifiable, Hashable, Sendable {
    let id: UUID
    var songRelativePath: String
    var slot: Int
    var relativePath: String
    var content: String

    var hasContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ScriptMarkupPalette {
    static let defaultDirectionHex = "#59C7CC"
    static let defaultStoryboardingHex = "#F2A640"
    static let defaultAnimateHex = "#D973B3"
    static let defaultScriptBackgroundHex = "#121314"

    static func color(from hex: String, fallback fallbackHex: String) -> Color {
        let resolvedHex = normalizedHex(hex) ?? fallbackHex
        let raw = resolvedHex.hasPrefix("#") ? String(resolvedHex.dropFirst()) : resolvedHex
        guard raw.count == 6, let value = Int(raw, radix: 16) else {
            return .white
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    static func hex(from color: Color, fallback fallbackHex: String) -> String {
#if canImport(AppKit)
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return String(
            format: "#%02X%02X%02X",
            Int(round(nsColor.redComponent * 255)),
            Int(round(nsColor.greenComponent * 255)),
            Int(round(nsColor.blueComponent * 255))
        )
#else
        return fallbackHex
#endif
    }

    static func normalizedHex(_ hex: String) -> String? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, raw.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "#\(raw.uppercased())"
    }
}

// MARK: - Model Types (shared types are now in ProjectKit/OWPModels.swift)
// SongLyricIterationFile is WriteUI-only — kept here.
// All other shared types (ProjectMetadata, SongStub, OPWCharacter, etc.)
// are imported from ProjectKit.

// MARK: - OWS Lightweight Types (ScriptWriter only holds what it needs)

/// Lightweight version — only the fields ScriptWriter reads/writes.
/// Heavy data (music, playback, instrumentMappings) stays on disk.
struct OWSVersionPayload: Identifiable, Hashable, Sendable {
    var id: UUID
    var label: String
    var createdAt: Date
    var updatedAt: Date
    var lyrics: String
    var saveType: VersionSaveType
    var userLabel: String?
    var isBookmarked: Bool

    var displayName: String {
        let baseName = userLabel ?? label
        switch saveType {
        case .autosave:
            return baseName
                .replacingOccurrences(of: "Auto-save", with: "Revision")
                .replacingOccurrences(of: "Autosave", with: "Revision")
        default: return baseName
        }
    }
}

/// Lightweight song document — only holds fields ScriptWriter reads/writes.
/// Heavy data (music, playback, instrumentMappings) stays on disk.
/// Parsed from raw JSON via JSONSerialization, not Codable (avoids decoding heavy fields).
struct OWSSongDocument: Identifiable, Hashable, Sendable {
    var songID: UUID
    var title: String
    var canonicalTitle: String
    var notes: String
    var updatedAt: Date
    var activeVersionID: UUID?
    var versions: [OWSVersionPayload]

    var id: UUID { songID }

    mutating func normalize() {
        versions.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        if versions.isEmpty { activeVersionID = nil; return }
        if let activeVersionID, versions.contains(where: { $0.id == activeVersionID }) { return }
        activeVersionID = versions.first?.id
    }

    func activeVersion() -> OWSVersionPayload? {
        if let activeVersionID, let match = versions.first(where: { $0.id == activeVersionID }) {
            return match
        }
        return versions.first
    }

    // MARK: - Parse from raw JSON (extracts only lightweight fields)

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ value: Any?) -> Date {
        guard let str = value as? String else { return Date() }
        return isoFormatter.date(from: str) ?? isoFormatterBasic.date(from: str) ?? Date()
    }

    static func parseUUID(_ value: Any?) -> UUID? {
        guard let str = value as? String else { return nil }
        return UUID(uuidString: str)
    }

    /// Parses a lightweight OWSSongDocument from raw JSON data.
    /// Only extracts title, notes, version lyrics, and IDs.
    /// Music/playback data is NOT loaded into memory.
    static func fromJSON(data: Data) throws -> OWSSongDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OWSSongDocument", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON root"])
        }

        let songID = parseUUID(root["songID"]) ?? UUID()
        let title = root["title"] as? String ?? "Untitled Song"
        let canonicalTitle = root["canonicalTitle"] as? String ?? title.lowercased()
        let notes = root["notes"] as? String ?? ""
        let updatedAt = parseDate(root["updatedAt"])
        let activeVersionID = parseUUID(root["activeVersionID"])

        var versions: [OWSVersionPayload] = []
        if let versionArray = root["versions"] as? [[String: Any]] {
            for vDict in versionArray {
                let vID = parseUUID(vDict["id"]) ?? UUID()
                let label = vDict["label"] as? String ?? "Version"
                let lyrics = vDict["lyrics"] as? String ?? ""
                let vUpdatedAt = parseDate(vDict["updatedAt"])
                let vCreatedAt = parseDate(vDict["createdAt"])
                let saveTypeRaw = vDict["saveType"] as? String ?? "manual"
                let saveType = VersionSaveType(rawValue: saveTypeRaw) ?? .manual
                let userLabel = vDict["userLabel"] as? String
                let isBookmarked = vDict["isBookmarked"] as? Bool ?? false

                versions.append(OWSVersionPayload(
                    id: vID, label: label, createdAt: vCreatedAt, updatedAt: vUpdatedAt,
                    lyrics: lyrics, saveType: saveType, userLabel: userLabel, isBookmarked: isBookmarked
                ))
            }
        }

        var doc = OWSSongDocument(
            songID: songID, title: title, canonicalTitle: canonicalTitle,
            notes: notes, updatedAt: updatedAt, activeVersionID: activeVersionID,
            versions: versions
        )
        doc.normalize()
        return doc
    }

    /// Patches an existing OWS file on disk with the lightweight changes from this document.
    /// Reads the full file, updates only title/notes/lyrics, writes it back. Heavy data is untouched.
    static func patchFile(at url: URL, with doc: OWSSongDocument) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OWSSongDocument", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot parse OWS for patching"])
        }

        root["title"] = doc.title
        root["canonicalTitle"] = doc.canonicalTitle
        root["notes"] = doc.notes
        root["updatedAt"] = isoFormatter.string(from: doc.updatedAt)

        // Patch activeVersionID
        root["activeVersionID"] = doc.activeVersionID?.uuidString

        // Patch version lyrics + persist new versions + prune removed ones
        if var versionArray = root["versions"] as? [[String: Any]] {
            // Update existing versions
            for docVersion in doc.versions {
                if let idx = versionArray.firstIndex(where: {
                    ($0["id"] as? String) == docVersion.id.uuidString
                }) {
                    versionArray[idx]["lyrics"] = docVersion.lyrics
                    versionArray[idx]["updatedAt"] = isoFormatter.string(from: docVersion.updatedAt)
                }
            }

            // Append new versions that don't exist on disk yet
            let existingIDs = Set(versionArray.compactMap { $0["id"] as? String })
            for docVersion in doc.versions where !existingIDs.contains(docVersion.id.uuidString) {
                var newVersionDict: [String: Any] = [
                    "id": docVersion.id.uuidString,
                    "label": docVersion.label,
                    "createdAt": isoFormatter.string(from: docVersion.createdAt),
                    "updatedAt": isoFormatter.string(from: docVersion.updatedAt),
                    "lyrics": docVersion.lyrics,
                    "saveType": docVersion.saveType.rawValue,
                    "isBookmarked": docVersion.isBookmarked,
                ]
                if let userLabel = docVersion.userLabel {
                    newVersionDict["userLabel"] = userLabel
                }
                versionArray.append(newVersionDict)
            }

            // Remove pruned versions (no longer in doc.versions)
            let currentIDs = Set(doc.versions.map { $0.id.uuidString })
            versionArray.removeAll { entry in
                guard let entryID = entry["id"] as? String else { return false }
                return !currentIDs.contains(entryID)
            }

            root["versions"] = versionArray
        }

        let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try patched.write(to: url, options: .atomic)
    }

    static func patchTitle(
        at url: URL,
        title: String,
        canonicalTitle: String,
        updatedAt: Date
    ) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OWSSongDocument", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot parse OWS for patching"])
        }

        root["title"] = title
        root["canonicalTitle"] = canonicalTitle
        root["updatedAt"] = isoFormatter.string(from: updatedAt)

        let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try patched.write(to: url, options: .atomic)
    }
}

struct OWSSongAsset: Identifiable, @unchecked Sendable {
    var relativePath: String
    var document: OWSSongDocument

    var id: UUID { document.songID }

    var displayName: String {
        // Prefer explicitly set title over filename-derived name
        let docTitle = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        let fileBasedName = (withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension).toTitleCase()
        if !docTitle.isEmpty && docTitle != "Untitled Song" && docTitle.lowercased() != fileBasedName.lowercased() {
            return docTitle
        }
        return fileBasedName
    }
}

// MARK: - Console Types

struct ConsoleMessage: Identifiable, Sendable {
    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    var snapshotID: UUID?

    enum Role: Sendable {
        case user
        case agent
        case system
    }

    init(role: Role, text: String, snapshotID: UUID? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = Date()
        self.snapshotID = snapshotID
    }
}

struct ConsoleSnapshot: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let metadata: ProjectMetadata
    let librettoFiles: [ProjectTextFile]
    let characters: [OPWCharacter]

    init(metadata: ProjectMetadata, librettoFiles: [ProjectTextFile], characters: [OPWCharacter]) {
        self.id = UUID()
        self.timestamp = Date()
        self.metadata = metadata
        self.librettoFiles = librettoFiles
        self.characters = characters
    }
}

// ConsoleAgentType, ConsoleAgentModel, and AgentProcessManager are provided by ProjectKit.

enum SaveConflictError: LocalizedError {
    case externalChanges(paths: [String])

    var conflictPaths: [String] {
        switch self {
        case .externalChanges(let paths):
            return paths
        }
    }

    var errorDescription: String? {
        switch self {
        case .externalChanges(let paths):
            let joined = paths.joined(separator: ", ")
            return "Newer disk changes were detected for \(joined)."
        }
    }
}

// MARK: - OWP Project I/O (self-contained subset)

enum OWPProjectIO {
    static let metadataDir = "Metadata"
    static let projectMetadataFile = "Metadata/project.json"
    static let songsDir = "Songs"
    static let charactersDir = "Characters"
    static let charactersFile = "Characters/characters.json"

    // MARK: - Load Phase 1 (metadata + stubs)

    static func loadPhase1(from url: URL) async throws -> (metadata: ProjectMetadata, stubs: [SongStub], isStandalone: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if url.pathExtension.lowercased() == "ows" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let stub = SongStub(id: UUID(), fileURL: url, relativePath: url.lastPathComponent, fileSize: size)
            let metadata = ProjectMetadata.fresh(named: URL(fileURLWithPath: url.lastPathComponent).deletingPathExtension().lastPathComponent)
            return (metadata, [stub], true)
        }

        let ext = url.pathExtension.lowercased()
        let isOWP = ext == "owp" || ext == "opw"
        let hasMetadata = fm.fileExists(atPath: url.appendingPathComponent(projectMetadataFile).path)
        let hasScenePackages = !ScenePackageStore.discover(in: url, fileManager: fm).isEmpty
        guard isOWP || hasMetadata || hasScenePackages else {
            throw NSError(domain: "ScriptWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid project: \(url.lastPathComponent)"])
        }

        let metadata: ProjectMetadata = {
            let metaURL = url.appendingPathComponent(projectMetadataFile)
            if let data = try? Data(contentsOf: metaURL, options: .mappedIfSafe),
               let decoded = try? JSONCoders.makeDecoder().decode(ProjectMetadata.self, from: data) {
                return decoded
            }
            return ProjectMetadata.fresh(named: url.deletingPathExtension().lastPathComponent)
        }()

        let stubs = enumerateProjectSongStubs(in: url)
        return (metadata, stubs, false)
    }

    static func enumerateProjectSongStubs(in projectURL: URL) -> [SongStub] {
        enumerateScenePackageStubs(in: projectURL)
    }

    static func enumerateScenePackageStubs(in projectURL: URL) -> [SongStub] {
        ScenePackageStore.discover(in: projectURL).map { descriptor in
            SongStub(
                id: descriptor.id,
                fileURL: descriptor.sceneJSONURL,
                relativePath: descriptor.projectRelativePath,
                fileSize: descriptor.fileSize,
                title: descriptor.title,
                canonicalTitle: descriptor.canonicalTitle
            )
        }
    }

    static func enumerateSongStubs(in songsRoot: URL) -> [SongStub] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: songsRoot.path) else { return [] }
        let normalizedSongsRoot = songsRoot.resolvingSymlinksInPath().standardizedFileURL

        let enumerator = fm.enumerator(
            at: songsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var stubs: [SongStub] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "ows" else { continue }
            // Skip SyncThing conflict files
            if fileURL.lastPathComponent.contains(".sync-conflict-") { continue }
            let normalizedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            let relativeWithinFolder = normalizedFileURL.path.replacingOccurrences(
                of: normalizedSongsRoot.path + "/",
                with: ""
            )
            let relativePath = "\(songsDir)/\(relativeWithinFolder)"
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            stubs.append(SongStub(id: UUID(), fileURL: fileURL, relativePath: relativePath, fileSize: size))
        }

        return stubs.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    // MARK: - Load Song

    nonisolated static func loadSongAsync(stub: SongStub) async throws -> OWSSongAsset {
        let data: Data
        if ScenePackageStore.isScenePackageSceneJSON(stub.fileURL) {
            data = try ScenePackageStore.makeWorkspaceSceneDocumentData(sceneJSONURL: stub.fileURL)
        } else {
            data = try Data(contentsOf: stub.fileURL, options: .mappedIfSafe)
        }
        let document = try OWSSongDocument.fromJSON(data: data)
        return OWSSongAsset(relativePath: stub.relativePath, document: document)
    }

    // MARK: - Load Characters

    nonisolated static func loadCharacterManifestAsync(from packageURL: URL) async throws -> [OPWCharacter] {
        let jsonURL = packageURL.appendingPathComponent(charactersFile)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return [] }
        let data = try Data(contentsOf: jsonURL, options: .mappedIfSafe)
        let file = try JSONCoders.makeDecoder().decode(OPWCharactersFile.self, from: data)
        return file.characters
    }

    // MARK: - Save

    /// ScriptWriter only patches libretto data (title, notes, lyrics) in existing .ows files.
    /// It never writes project metadata, characters, MIDI, or any other OWP data.
    static func savePackage(
        packageURL: URL,
        songs: [OWSSongAsset],
        expectedSnapshots: [String: ProjectFileSnapshot] = [:]
    ) throws {
        let fm = FileManager.default
        var conflicts: [String] = []

        for song in songs {
            let destination = packageURL.appendingPathComponent(song.relativePath)
            if fm.fileExists(atPath: destination.path) {
                if let expectedSnapshot = expectedSnapshots[song.relativePath],
                   let currentSnapshot = fileSnapshot(for: destination),
                   currentSnapshot != expectedSnapshot {
                    conflicts.append(song.relativePath)
                }
            } else if let sceneJSONURL = ScenePackageStore.sceneJSONURL(forProjectRelativePath: song.relativePath, in: packageURL),
                      let expectedSnapshot = expectedSnapshots[song.relativePath],
                      let currentSnapshot = fileSnapshot(for: sceneJSONURL),
                      currentSnapshot != expectedSnapshot {
                conflicts.append(song.relativePath)
            }
        }

        if !conflicts.isEmpty {
            throw SaveConflictError.externalChanges(paths: conflicts)
        }

        // Scene packages — patch canonical scene/version files in-place.
        for song in songs {
            let destination = packageURL.appendingPathComponent(song.relativePath)
            if let sceneJSONURL = ScenePackageStore.sceneJSONURL(forProjectRelativePath: song.relativePath, in: packageURL) {
                try ScenePackageStore.patchScenePackageFromWorkspaceSceneDocumentObject(
                    sceneJSONURL: sceneJSONURL,
                    sceneDocumentRoot: workspaceSceneDocumentObject(from: song.document)
                )
            } else if fm.fileExists(atPath: destination.path) {
                try OWSSongDocument.patchFile(at: destination, with: song.document)
            }
            // If the canonical scene package is missing, skip instead of inventing data.
        }
    }

    private static func workspaceSceneDocumentObject(from document: OWSSongDocument) -> [String: Any] {
        var root: [String: Any] = [
            "songID": document.songID.uuidString,
            "title": document.title,
            "canonicalTitle": document.canonicalTitle,
            "notes": document.notes,
            "updatedAt": OWSSongDocument.isoFormatter.string(from: document.updatedAt),
            "versions": document.versions.map { version in
                var result: [String: Any] = [
                    "id": version.id.uuidString,
                    "label": version.label,
                    "createdAt": OWSSongDocument.isoFormatter.string(from: version.createdAt),
                    "updatedAt": OWSSongDocument.isoFormatter.string(from: version.updatedAt),
                    "lyrics": version.lyrics,
                    "saveType": version.saveType.rawValue,
                    "isBookmarked": version.isBookmarked,
                ]
                if let userLabel = version.userLabel {
                    result["userLabel"] = userLabel
                }
                return result
            },
        ]
        if let activeVersionID = document.activeVersionID?.uuidString {
            root["activeVersionID"] = activeVersionID
        }
        return root
    }

    static func saveStandaloneSong(
        songURL: URL,
        song: OWSSongAsset,
        expectedSnapshot: ProjectFileSnapshot? = nil
    ) throws {
        if let expectedSnapshot,
           let currentSnapshot = fileSnapshot(for: songURL),
           currentSnapshot != expectedSnapshot {
            throw SaveConflictError.externalChanges(paths: [song.relativePath])
        }
        try OWSSongDocument.patchFile(at: songURL, with: song.document)
    }

    private static func fileSnapshot(for fileURL: URL) -> ProjectFileSnapshot? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate else {
            return nil
        }

        // Truncate to integer seconds so snapshots round-trip through ISO 8601
        // encoding without false-positive diffs from sub-second precision loss.
        let truncated = Date(timeIntervalSinceReferenceDate: modificationDate.timeIntervalSinceReferenceDate.rounded(.down))

        return ProjectFileSnapshot(
            modificationDate: truncated,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

}

// MARK: - ScriptStore

@available(macOS 26.0, *)
@MainActor
@Observable
final class ScriptStore {
    private let projectHistoryStore: ProjectHistoryStore
    private let gitHistoryService: GitHistoryService

    // MARK: - Project State

    var projectURL: URL?
    var workingProjectURL: URL?
    var metadata = ProjectMetadata()
    var songAssets: [OWSSongAsset] = []
    var songStubs: [SongStub] = []
    var librettoFiles: [ProjectTextFile] = []
    var librettoContentRevisionByPath: [String: Int] = [:]
    var characters: [OPWCharacter] = []
    var isDirty: Bool { hasUnsavedChanges }
    var metadataDirty = false
    var statusMessage: String = "No project loaded"
    var presentedLoadError: String?
    var projectHistoryEntries: [ProjectHistoryEntry] = []
    var gitHistoryEntries: [GitCommitEntry] = []

    // MARK: - Script UI State

    var selectedSongPath: String?
    var scrollTargetRequest: (path: String, version: UInt64)?
    private var scrollTargetVersion: UInt64 = 0

    func requestScrollTarget(_ path: String) {
        scrollTargetVersion += 1
        scrollTargetRequest = (path, scrollTargetVersion)
    }
    var activeSongPath: String?
    var isLibrettoEditMode: Bool = UserDefaults.standard.object(forKey: "amira.write.librettoEditMode") as? Bool ?? false {
        didSet { UserDefaults.standard.set(isLibrettoEditMode, forKey: "amira.write.librettoEditMode") }
    }
    var directionMarkupColorHex: String = UserDefaults.standard.string(forKey: "amira.write.directionMarkupColorHex") ?? ScriptMarkupPalette.defaultDirectionHex {
        didSet {
            let normalized = ScriptMarkupPalette.normalizedHex(directionMarkupColorHex) ?? ScriptMarkupPalette.defaultDirectionHex
            guard normalized == directionMarkupColorHex else {
                directionMarkupColorHex = normalized
                return
            }
            UserDefaults.standard.set(directionMarkupColorHex, forKey: "amira.write.directionMarkupColorHex")
            saveProjectSettings()
        }
    }
    var storyboardingMarkupColorHex: String = UserDefaults.standard.string(forKey: "amira.write.storyboardingMarkupColorHex") ?? ScriptMarkupPalette.defaultStoryboardingHex {
        didSet {
            let normalized = ScriptMarkupPalette.normalizedHex(storyboardingMarkupColorHex) ?? ScriptMarkupPalette.defaultStoryboardingHex
            guard normalized == storyboardingMarkupColorHex else {
                storyboardingMarkupColorHex = normalized
                return
            }
            UserDefaults.standard.set(storyboardingMarkupColorHex, forKey: "amira.write.storyboardingMarkupColorHex")
            saveProjectSettings()
        }
    }
    var animateMarkupColorHex: String = UserDefaults.standard.string(forKey: "amira.write.animateMarkupColorHex") ?? ScriptMarkupPalette.defaultAnimateHex {
        didSet {
            let normalized = ScriptMarkupPalette.normalizedHex(animateMarkupColorHex) ?? ScriptMarkupPalette.defaultAnimateHex
            guard normalized == animateMarkupColorHex else {
                animateMarkupColorHex = normalized
                return
            }
            UserDefaults.standard.set(animateMarkupColorHex, forKey: "amira.write.animateMarkupColorHex")
            saveProjectSettings()
        }
    }
    var scriptBackgroundColorHex: String = UserDefaults.standard.string(forKey: "amira.write.scriptBackgroundColorHex") ?? ScriptMarkupPalette.defaultScriptBackgroundHex {
        didSet {
            let normalized = ScriptMarkupPalette.normalizedHex(scriptBackgroundColorHex) ?? ScriptMarkupPalette.defaultScriptBackgroundHex
            guard normalized == scriptBackgroundColorHex else {
                scriptBackgroundColorHex = normalized
                return
            }
            UserDefaults.standard.set(scriptBackgroundColorHex, forKey: "amira.write.scriptBackgroundColorHex")
            saveProjectSettings()
        }
    }
    var saveIndicator: SaveIndicatorState = .idle
    var isAgentSyncInProgress: Bool = false
    var showsRecentAgentUpdate: Bool = false

    var directionMarkupColor: Color {
        ScriptMarkupPalette.color(from: directionMarkupColorHex, fallback: ScriptMarkupPalette.defaultDirectionHex)
    }

    var storyboardingMarkupColor: Color {
        ScriptMarkupPalette.color(from: storyboardingMarkupColorHex, fallback: ScriptMarkupPalette.defaultStoryboardingHex)
    }

    var animateMarkupColor: Color {
        ScriptMarkupPalette.color(from: animateMarkupColorHex, fallback: ScriptMarkupPalette.defaultAnimateHex)
    }

    var scriptBackgroundColor: Color {
        ScriptMarkupPalette.color(from: scriptBackgroundColorHex, fallback: ScriptMarkupPalette.defaultScriptBackgroundHex)
    }

    var isDarkBackground: Bool {
        let hex = scriptBackgroundColorHex.hasPrefix("#") ? String(scriptBackgroundColorHex.dropFirst()) : scriptBackgroundColorHex
        let r = CGFloat(Int(hex.prefix(2), radix: 16) ?? 0) / 255.0
        let g = CGFloat(Int(hex.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255.0
        let b = CGFloat(Int(hex.suffix(2), radix: 16) ?? 0) / 255.0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 0.5
    }

    var collaborationBadgeLabel: String? {
        if isAgentSyncInProgress {
            return "Agent Syncing"
        }
        if showsRecentAgentUpdate {
            return "Agent Updated"
        }
        return nil
    }

    var collaborationBadgeSystemImage: String {
        showsRecentAgentUpdate ? "sparkles" : "arrow.triangle.2.circlepath"
    }

    // MARK: - Script Cards (structured sidecar)

    /// Structured projection of bracket markup, persisted at
    /// `<project>/Metadata/script-cards.json`. Slowly replacing the
    /// wall-of-text DSL the lyrics used to carry inline. See
    /// `ScriptCardImporter` for the projection rules and
    /// `ScriptCardSidecarStore` for disk I/O.
    var scriptCards: ScriptDocumentCards = ScriptDocumentCards()

    // MARK: - Scratchpad / Derived Text State

    var scratchpadFiles: [ProjectTextFile] = []
    var lyricIterationFiles: [SongLyricIterationFile] = []
    private(set) var scratchpadDocumentText: String = ""

    private var fileProjectURL: URL? {
        workingProjectURL ?? projectURL
    }

    var scratchpadFilledSceneCount: Int {
        scratchpadFiles.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    // MARK: - Agent Edit Preview State

    /// Pending agent edits keyed by relativePath → new content.
    /// Non-empty means an agent session produced changes awaiting accept/reject.
    var pendingAgentEdits: [String: String] = [:]

    /// The snapshot ID associated with the current pending edits (for reject/undo).
    var pendingAgentSnapshotID: UUID?

    // MARK: - Version History State

    var previewingVersionID: UUID?
    var previewingSongPath: String?
    private static let maxProjectHistoryEntries: Int = 120
    private static let externalWatchInterval: TimeInterval = 0.5
    private static let lyricIterationSlots = 1...10
    private static let lyricIterationFolderSuffix = ".lyric-iterations"
    private static let scratchpadMarkerPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?m)^\{\{\{SCENE:(.+?)\}\}\}\s*$"#)
    }()

    private static let versionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    // MARK: - Derived

    var midiAssets: [MidiAsset] {
        songAssets.map {
            MidiAsset(id: $0.id, relativePath: $0.relativePath, data: Data())
        }
    }

    // MARK: - Dirty Song Tracking

    private var dirtySongPaths: Set<String> = []
    private var isScratchpadDirty: Bool = false
    private var isSaving: Bool = false
    private(set) var isLoadingProject: Bool = false

    // MARK: - File Watching

    /// Timestamps of externally-detected changes per song path (for glow UI).
    var externalChangeTimes: [String: Date] = [:]
    private var lastKnownModDates: [String: Date] = [:]
    private var lastKnownFileSnapshots: [String: ProjectFileSnapshot] = [:]
    private var fileWatchWorkItem: DispatchWorkItem?
    private var isFileWatchingActive = false
    private var fileWatchGeneration: UInt64 = 0
    private var scratchpadSaveWorkItem: DispatchWorkItem?
    private var hydratedScenePaths: Set<String> = []
    private var hydratingScenePaths: Set<String> = []

    init(
        projectHistoryStore: ProjectHistoryStore = .shared,
        gitHistoryService: GitHistoryService = .live
    ) {
        self.projectHistoryStore = projectHistoryStore
        self.gitHistoryService = gitHistoryService
    }

    // MARK: - Load Project

    func loadProject(url: URL) async {
        AmiraLogger.log(.write, "loadProject START url=\(url.path)")
        guard !isLoadingProject else {
            AmiraLogger.log(.write, "loadProject SKIPPED: already loading")
            return
        }

        let isSwitchingProjects = projectURL?.standardizedFileURL.path != nil
            && projectURL?.standardizedFileURL.path != url.standardizedFileURL.path

        scratchpadSaveWorkItem?.cancel()
        isLoadingProject = true
        saveIndicator = .idle
        statusMessage = "Loading \(url.lastPathComponent)..."
        presentedLoadError = nil
        gitHistoryEntries = []
        hydratedScenePaths.removeAll()
        hydratingScenePaths.removeAll()

        defer {
            isLoadingProject = false
        }

        do {
            let isStandalone = url.pathExtension.lowercased() == "ows"
            let loaded: ProjectLoadResult?
            let meta: ProjectMetadata
            let stubs: [SongStub]

            stopFileWatching()
            if isStandalone {
                let phase1 = try await OWPProjectIO.loadPhase1(from: url)
                meta = phase1.metadata
                stubs = phase1.stubs
                loaded = nil
            } else {
                let result = try await ProjectDatabaseBridge.loadWriterProject(url: url)
                loaded = result
                meta = result.metadata
                stubs = result.stubs
            }

            let effectiveProjectURL = loaded?.workingProjectURL ?? url
            let previousHistoryState = projectHistoryStore.loadState(for: url)
            let currentSnapshot = trackedFileSnapshots(for: effectiveProjectURL, stubs: stubs)
            let externallyChangedPaths = previousHistoryState.fileSnapshots.isEmpty
                ? []
                : changedTrackedPaths(
                    from: previousHistoryState.fileSnapshots,
                    to: currentSnapshot
                )
            let externallyChangedPathSet = Set(externallyChangedPaths)

            self.projectURL = url
            self.workingProjectURL = effectiveProjectURL
            self.metadata = meta
            self.songStubs = stubs
            self.songAssets = []
            self.librettoFiles = []
            self.librettoContentRevisionByPath = [:]
            self.scratchpadFiles = []
            self.lyricIterationFiles = []
            self.scratchpadDocumentText = ""
            self.isScratchpadDirty = false
            self.projectHistoryEntries = filteredProjectHistoryEntries(previousHistoryState.entries)
            self.hydratedScenePaths = loaded?.hydratedScenePaths ?? []

            // Persist last opened path
            UserDefaults.standard.set(url.path, forKey: "lastProjectPath")

            if isSwitchingProjects {
                selectedSongPath = nil
                scrollTargetRequest = nil
                activeSongPath = nil
            }

            if let loaded {
                for var asset in loaded.assets {
                    if externallyChangedPathSet.contains(asset.relativePath) {
                        _ = preferMostRecentlyUpdatedVersionIfNeeded(in: &asset.document)
                    }
                    songAssets.append(asset)

                    if let version = asset.document.activeVersion() {
                        librettoFiles.append(ProjectTextFile(
                            id: UUID(),
                            relativePath: asset.relativePath,
                            content: version.lyrics
                        ))
                        bumpLibrettoRevision(for: asset.relativePath)
                    }
                }
                characters = loaded.characters
            } else {
                for stub in stubs {
                    do {
                        var asset = try await OWPProjectIO.loadSongAsync(stub: stub)
                        if externallyChangedPathSet.contains(stub.relativePath) {
                            _ = preferMostRecentlyUpdatedVersionIfNeeded(in: &asset.document)
                        }
                        songAssets.append(asset)

                        if let version = asset.document.activeVersion() {
                            librettoFiles.append(ProjectTextFile(
                                id: UUID(),
                                relativePath: asset.relativePath,
                                content: version.lyrics
                            ))
                            bumpLibrettoRevision(for: stub.relativePath)
                        }
                        hydratedScenePaths.insert(stub.relativePath)
                    } catch {
                        statusMessage = "Failed to load song: \(stub.displayName)"
                    }
                }
                if !isStandalone {
                    characters = (try? await OWPProjectIO.loadCharacterManifestAsync(from: effectiveProjectURL)) ?? []
                }
            }

            let eagerHydrationPaths = prioritizedHydrationPaths(
                allPaths: stubs.map(\.relativePath),
                primaryPath: songAssets.first?.relativePath,
                externallyChangedPaths: externallyChangedPaths
            )
            for path in eagerHydrationPaths {
                guard let hydratedAsset = await hydrateScene(path: path) else { continue }
                if externallyChangedPathSet.contains(path) {
                    var promotedAsset = hydratedAsset
                    _ = preferMostRecentlyUpdatedVersionIfNeeded(in: &promotedAsset.document)
                    applyHydratedAsset(promotedAsset, forPath: path)
                } else {
                    applyHydratedAsset(hydratedAsset, forPath: path)
                }
            }

            await loadScratchpad(from: effectiveProjectURL)
            await loadLyricIterations(from: effectiveProjectURL)

            // Ensure CLAUDE.md exists with embedded-synopsis instructions
            ensureClaudeMD(in: effectiveProjectURL)

            if !externallyChangedPaths.isEmpty {
                let changedSongPaths = externallyChangedPaths.filter {
                    $0 != ProjectDatabaseBridge.scratchpadPath
                        && !Self.isLyricIterationRelativePath($0)
                }
                for path in changedSongPaths {
                    externalChangeTimes[path] = Date()
                }
                appendProjectHistory(
                    kind: .openedWithExternalChanges,
                    title: "Loaded newer disk changes",
                    message: summarizeTrackedPaths(externallyChangedPaths),
                    relativePaths: externallyChangedPaths
                )
            }

            metadataDirty = false
            refreshSaveIndicator()

            statusMessage = "\(meta.name) - \(songAssets.count) songs loaded"
            persistProjectHistoryState()
            refreshGitHistory(for: url)
            loadProjectSettings()
            loadAndImportScriptCards()
            startFileWatching()
        } catch {
            statusMessage = "Failed to load: \(error.localizedDescription)"
            presentedLoadError = error.localizedDescription
        }
    }

    // MARK: - Save

    func save() {
        guard let url = fileProjectURL, !isSaving else { return }
        guard !dirtySongPaths.isEmpty || isScratchpadDirty else { return }

        if dirtySongPaths.isEmpty {
            isSaving = true
            saveScratchpad()
            isSaving = false
            refreshSaveIndicator()
            return
        }

        isSaving = true
        saveIndicator = .saving
        saveScratchpad()

        // Capture only dirty songs (or all if standalone .ows)
        let isStandalone = url.pathExtension.lowercased() == "ows"
        let songsToSave: [OWSSongAsset]
        if isStandalone {
            songsToSave = songAssets.prefix(1).map { $0 }
        } else {
            songsToSave = songAssets.filter { dirtySongPaths.contains($0.relativePath) }
        }
        let dirtyPaths = dirtySongPaths
        let expectedSnapshots = songsToSave.reduce(into: [String: ProjectFileSnapshot]()) { partialResult, song in
            if let snapshot = lastKnownFileSnapshots[song.relativePath] {
                partialResult[song.relativePath] = snapshot
            } else {
                let fileURL = isStandalone ? url : url.appendingPathComponent(song.relativePath)
                if let snapshot = fileSnapshot(for: fileURL) {
                    partialResult[song.relativePath] = snapshot
                }
            }
        }

        // Clear dirty tracking before async work (new edits during save will re-dirty)
        dirtySongPaths.removeAll()

        Task.detached { [weak self] in
            var saveError: Error?
            do {
                if isStandalone, let song = songsToSave.first {
                    try OWPProjectIO.saveStandaloneSong(
                        songURL: url,
                        song: song,
                        expectedSnapshot: expectedSnapshots[song.relativePath]
                    )
                } else if !songsToSave.isEmpty || !dirtyPaths.isEmpty {
                    try OWPProjectIO.savePackage(
                        packageURL: url,
                        songs: songsToSave,
                        expectedSnapshots: expectedSnapshots
                    )
                }
            } catch {
                saveError = error
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isSaving = false
                if let saveError {
                    // Re-mark songs as dirty since save failed
                    self.dirtySongPaths.formUnion(dirtyPaths)
                    self.refreshSaveIndicator()
                    if let conflict = saveError as? SaveConflictError {
                        self.handleSaveConflict(conflictPaths: conflict.conflictPaths)
                    } else {
                        self.statusMessage = "Save failed: \(saveError.localizedDescription)"
                    }
                } else {
                    self.refreshSaveIndicator()
                    let historyPaths = isStandalone
                        ? Array(dirtyPaths)
                        : songsToSave.map(\.relativePath)

                    // Update mod dates so we don't detect our own save as external
                    for song in songsToSave {
                        let fileURL = isStandalone ? url : url.appendingPathComponent(song.relativePath)
                        if let snapshot = self.fileSnapshot(for: fileURL) {
                            self.lastKnownModDates[song.relativePath] = snapshot.modificationDate
                            self.lastKnownFileSnapshots[song.relativePath] = snapshot
                        }
                    }

                    if !historyPaths.isEmpty {
                        self.appendProjectHistory(
                            kind: .manualSave,
                            title: "Saved \(self.sceneCountLabel(for: historyPaths.count))",
                            message: self.summarizeTrackedPaths(historyPaths),
                            relativePaths: historyPaths
                        )
                    } else {
                        self.persistProjectHistoryState()
                    }
                }
            }
        }
    }

    // MARK: - Lyrics Updates

    func updateLyricsForSong(atPath path: String, lyrics: String) {
        // Update librettoFiles
        if let idx = librettoFiles.firstIndex(where: { $0.relativePath == path }) {
            librettoFiles[idx].content = lyrics
            bumpLibrettoRevision(for: path)
        }

        // Update the song asset's active version lyrics
        if let songIdx = songAssets.firstIndex(where: { $0.relativePath == path }),
           let activeID = songAssets[songIdx].document.activeVersionID,
           let versionIdx = songAssets[songIdx].document.versions.firstIndex(where: { $0.id == activeID }) {
            songAssets[songIdx].document.versions[versionIdx].lyrics = lyrics
            songAssets[songIdx].document.versions[versionIdx].updatedAt = Date()
            songAssets[songIdx].document.updatedAt = Date()
        }

        markDirty(path: path)
    }

    private func bumpLibrettoRevision(for path: String) {
        librettoContentRevisionByPath[path, default: 0] += 1
    }

    // MARK: - Per-Scene Synopsis (embedded in libretto)

    /// Extract synopsis text from a libretto file's content.
    /// Synopsis is stored as {{{SYNOPSIS}}}...{{{/SYNOPSIS}}} at the start of the file.
    func synopsis(forScenePath path: String) -> String {
        guard let file = librettoFiles.first(where: { $0.relativePath == path }) else { return "" }
        return SynopsisEmbedding.extract(from: file.content)
    }

    /// Update the embedded synopsis for a specific scene.
    func updateSynopsis(forScenePath path: String, text: String) {
        guard let idx = librettoFiles.firstIndex(where: { $0.relativePath == path }) else { return }
        let updated = SynopsisEmbedding.update(content: librettoFiles[idx].content, synopsis: text)
        updateLyricsForSong(atPath: path, lyrics: updated)
    }

    // MARK: - Rename Song

    func renameSong(atPath path: String, newTitle: String) {
        guard let idx = songAssets.firstIndex(where: { $0.relativePath == path }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let wasDirty = dirtySongPaths.contains(path)
        songAssets[idx].document.title = trimmed
        songAssets[idx].document.canonicalTitle = trimmed.lowercased()
        songAssets[idx].document.updatedAt = Date()
        markDirty(path: path)
        guard persistRenamedSongTitle(path: path, preserveDirtyState: wasDirty) else { return }
    }

    @discardableResult
    func selectScene(relativePath: String) -> Bool {
        guard songAssets.contains(where: { $0.relativePath == relativePath }) else { return false }
        selectedSongPath = relativePath
        activeSongPath = relativePath
        requestScrollTarget(relativePath)
        ensureSceneHydrated(path: relativePath)
        return true
    }

    // MARK: - Add Scene

    func addScene() {
        guard let url = fileProjectURL else { return }
        let isStandalone = url.pathExtension.lowercased() == "ows"
        guard !isStandalone else { return }

        // Determine next scene number based on existing canonical scene packages.
        let existingNumbers = songAssets.compactMap { asset -> Int? in
            let parts = asset.document.title.components(separatedBy: " ")
            return Int(parts.first ?? "")
        }
        let nextNumber = (existingNumbers.max() ?? 0) + 1
        let paddedNumber = String(format: "%02d", nextNumber)
        let title = "\(paddedNumber) New Scene"
        let slug = Self.slugifySceneTitle(title)
        let relativePath = "Scenes/\(slug)/scene.json"

        let versionID = UUID()
        let sceneID = UUID()
        let now = Date()
        let isoNow = OWSSongDocument.isoFormatter.string(from: now)

        let newDoc = OWSSongDocument(
            songID: sceneID,
            title: title,
            canonicalTitle: slug,
            notes: "",
            updatedAt: now,
            activeVersionID: versionID,
            versions: [OWSVersionPayload(
                id: versionID,
                label: "Initial",
                createdAt: now,
                updatedAt: now,
                lyrics: "",
                saveType: .manual,
                userLabel: nil,
                isBookmarked: false
            )]
        )

        let scenesDir = url.appendingPathComponent("Scenes", isDirectory: true)
        let sceneDir = scenesDir.appendingPathComponent(slug, isDirectory: true)
        let versionDir = sceneDir
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(versionID.uuidString.lowercased(), isDirectory: true)
        let fileURL = sceneDir.appendingPathComponent("scene.json")
        let sceneJSON: [String: Any] = [
            "schemaVersion": 1,
            "id": sceneID.uuidString,
            "slug": slug,
            "canonicalTitle": slug,
            "title": newDoc.title,
            "notes": "",
            "order": nextNumber * 1_000,
            "updatedAt": isoNow,
            "activeVersionID": versionID.uuidString.lowercased(),
            "versionOrder": [versionID.uuidString.lowercased()],
            "versions": [[
                "id": versionID.uuidString.lowercased(),
                "label": "Initial",
                "createdAt": isoNow,
                "updatedAt": isoNow,
                "saveType": "manual",
                "isBookmarked": false,
            ] as [String: Any]],
        ]

        do {
            try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
            let sceneData = try JSONSerialization.data(withJSONObject: sceneJSON, options: [.prettyPrinted, .sortedKeys])
            try sceneData.write(to: fileURL, options: .atomic)
            try Data("".utf8).write(to: versionDir.appendingPathComponent("manuscript.md"), options: .atomic)
            let playbackJSON: [String: Any] = [
                "schemaVersion": 1,
                "sceneID": sceneID.uuidString,
                "versionID": versionID.uuidString.lowercased(),
                "playback": [
                    "ticksPerQuarter": 480,
                    "tempoEvents": [["tick": 0, "bpm": 120]],
                    "notes": [],
                    "trackNames": [:],
                    "lyrics": "",
                ],
            ]
            let playbackData = try JSONSerialization.data(withJSONObject: playbackJSON, options: [.prettyPrinted, .sortedKeys])
            try playbackData.write(to: versionDir.appendingPathComponent("score.playback.json"), options: .atomic)
            try Self.upsertSceneIndexEntry(
                projectURL: url,
                sceneID: sceneID,
                slug: slug,
                title: title,
                activeVersionID: versionID,
                order: nextNumber * 1_000,
                updatedAt: isoNow
            )
        } catch {
            statusMessage = "Failed to create scene: \(error.localizedDescription)"
            return
        }

        let asset = OWSSongAsset(relativePath: relativePath, document: newDoc)
        songAssets.append(asset)
        librettoFiles.append(ProjectTextFile(
            id: UUID(),
            relativePath: relativePath,
            content: ""
        ))
        bumpLibrettoRevision(for: relativePath)
        normalizeScratchpadFiles()

        requestScrollTarget(relativePath)
        statusMessage = "Created \(title)"
    }

    func deleteScene(path: String) {
        guard let url = fileProjectURL else { return }
        let isStandalone = url.pathExtension.lowercased() == "ows"
        guard !isStandalone else { return }

        guard songAssets.contains(where: { $0.relativePath == path }) else { return }

        let fileURL = url.appendingPathComponent(path)
        let lyricIterDir = fileURL
            .deletingPathExtension()
            .appendingPathExtension(Self.lyricIterationFolderSuffix)

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            statusMessage = "Failed to delete scene file: \(error.localizedDescription)"
        }

        do {
            if FileManager.default.fileExists(atPath: lyricIterDir.path) {
                try FileManager.default.removeItem(at: lyricIterDir)
            }
        } catch {
            statusMessage = "Failed to delete lyric iterations: \(error.localizedDescription)"
        }

        songAssets.removeAll { $0.relativePath == path }
        songStubs.removeAll { $0.relativePath == path }
        librettoFiles.removeAll { $0.relativePath == path }
        librettoContentRevisionByPath.removeValue(forKey: path)
        dirtySongPaths.remove(path)
        hydratedScenePaths.remove(path)
        hydratingScenePaths.remove(path)

        lastKnownModDates.removeValue(forKey: path)
        lastKnownFileSnapshots.removeValue(forKey: path)
        for slot in Self.lyricIterationSlots {
            let iterPath = Self.lyricIterationRelativePath(forSongPath: path, slot: slot)
            lastKnownModDates.removeValue(forKey: iterPath)
            lastKnownFileSnapshots.removeValue(forKey: iterPath)
        }

        if selectedSongPath == path { selectedSongPath = songAssets.first?.relativePath }
        if activeSongPath == path { activeSongPath = songAssets.first?.relativePath }
        if scrollTargetRequest?.path == path { scrollTargetRequest = nil }

        normalizeScratchpadFiles()
        normalizeLyricIterationFiles()
        refreshSaveIndicator()
        statusMessage = "Deleted scene"
    }

    // MARK: - Version History

    func createManualVersion(forPath path: String, label: String? = nil) {
        guard let songIdx = songAssets.firstIndex(where: { $0.relativePath == path }),
              let activeID = songAssets[songIdx].document.activeVersionID,
              let activeVIdx = songAssets[songIdx].document.versions.firstIndex(where: { $0.id == activeID })
        else { return }

        let now = Date()
        let currentLyrics = songAssets[songIdx].document.versions[activeVIdx].lyrics
        let versionLabel = label ?? "Save \(Self.versionDateFormatter.string(from: now))"
        let newVersion = OWSVersionPayload(
            id: UUID(),
            label: versionLabel,
            createdAt: now,
            updatedAt: now,
            lyrics: currentLyrics,
            saveType: .manual,
            userLabel: label,
            isBookmarked: false
        )
        songAssets[songIdx].document.versions.append(newVersion)
        markDirty(path: path, status: "Created local revision")
    }

    func previewVersion(id: UUID, forPath path: String) {
        previewingVersionID = id
        previewingSongPath = path
    }

    func cancelVersionPreview() {
        previewingVersionID = nil
        previewingSongPath = nil
    }

    func rollbackToVersion(id: UUID, forPath path: String) {
        guard let songIdx = songAssets.firstIndex(where: { $0.relativePath == path }),
              let versionIdx = songAssets[songIdx].document.versions.firstIndex(where: { $0.id == id })
        else { return }

        let versionLyrics = songAssets[songIdx].document.versions[versionIdx].lyrics
        songAssets[songIdx].document.activeVersionID = id
        if let libIdx = librettoFiles.firstIndex(where: { $0.relativePath == path }) {
            librettoFiles[libIdx].content = versionLyrics
            bumpLibrettoRevision(for: path)
        }
        previewingVersionID = nil
        previewingSongPath = nil
        markDirty(path: path, status: "Restored local revision")
    }

    // MARK: - Song Notes

    func songNotes(forPath path: String) -> String {
        songAssets.first(where: { $0.relativePath == path })?.document.notes ?? ""
    }

    func updateSongNotes(forPath path: String, notes: String) {
        guard let idx = songAssets.firstIndex(where: { $0.relativePath == path }) else { return }
        songAssets[idx].document.notes = notes
        songAssets[idx].document.updatedAt = Date()
        markDirty(path: path)
    }

    // MARK: - Scratchpad

    func scratchpadText(forPath path: String) -> String {
        scratchpadFiles.first(where: { $0.relativePath == path })?.content ?? ""
    }

    func scratchpadMarker(forPath path: String) -> String {
        Self.scratchpadMarker(forPath: path)
    }

    func updateScratchpadText(forPath path: String, text: String) {
        guard librettoFiles.contains(where: { $0.relativePath == path }) else { return }

        if let idx = scratchpadFiles.firstIndex(where: { $0.relativePath == path }) {
            guard scratchpadFiles[idx].content != text else { return }
            scratchpadFiles[idx].content = text
        } else {
            scratchpadFiles.append(ProjectTextFile(
                id: UUID(),
                relativePath: path,
                content: text
            ))
            normalizeScratchpadFiles()
        }

        rebuildScratchpadDocument()
        isScratchpadDirty = true
        refreshSaveIndicator()
    }

    static func scratchpadMarker(forPath path: String) -> String {
        "{{{SCENE:\(path)}}}"
    }

    static func serializeScratchpadSections(_ files: [ProjectTextFile]) -> String {
        files
            .map { file in
                let marker = scratchpadMarker(forPath: file.relativePath)
                guard !file.content.isEmpty else { return marker }
                return "\(marker)\n\(file.content)"
            }
            .joined(separator: "\n\n")
    }

    static func parseScratchpadSections(
        from text: String,
        orderedPaths: [String]
    ) -> [ProjectTextFile] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let nsText = normalized as NSString
        let matches = scratchpadMarkerPattern.matches(
            in: normalized,
            range: NSRange(location: 0, length: nsText.length)
        )

        var sectionsByPath: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges > 1 else { continue }
            let path = nsText.substring(with: match.range(at: 1))
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count
                ? matches[index + 1].range.location
                : nsText.length
            guard end >= start else { continue }

            var content = nsText.substring(with: NSRange(location: start, length: end - start))
            if content.hasPrefix("\n") {
                content.removeFirst()
            }
            while content.hasSuffix("\n\n") {
                content.removeLast()
            }
            if content.hasSuffix("\n") {
                content.removeLast()
            }
            sectionsByPath[path] = content
        }

        return orderedPaths.map { path in
            ProjectTextFile(
                id: UUID(),
                relativePath: path,
                content: sectionsByPath[path] ?? ""
            )
        }
    }

    private func normalizeScratchpadFiles() {
        let idsByPath = Dictionary(uniqueKeysWithValues: scratchpadFiles.map { ($0.relativePath, $0.id) })
        let contentByPath = Dictionary(uniqueKeysWithValues: scratchpadFiles.map { ($0.relativePath, $0.content) })

        scratchpadFiles = librettoFiles.map { file in
            ProjectTextFile(
                id: idsByPath[file.relativePath] ?? UUID(),
                relativePath: file.relativePath,
                content: contentByPath[file.relativePath] ?? ""
            )
        }
        rebuildScratchpadDocument()
    }

    private func rebuildScratchpadDocument() {
        scratchpadDocumentText = Self.serializeScratchpadSections(scratchpadFiles)
    }

    private func scratchpadFileURL(for projectURL: URL) -> URL {
        if projectURL.pathExtension.lowercased() == "ows" {
            return projectURL
                .deletingPathExtension()
                .appendingPathExtension("scratchpad.txt")
        }
        return projectURL.appendingPathComponent(ProjectDatabaseBridge.scratchpadPath)
    }

    private func loadScratchpad(from projectURL: URL) async {
        let loadedText: String
        let fileURL = scratchpadFileURL(for: projectURL)
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) {
            loadedText = text
        } else {
            loadedText = ""
        }

        scratchpadFiles = Self.parseScratchpadSections(
            from: loadedText,
            orderedPaths: librettoFiles.map(\.relativePath)
        )
        normalizeScratchpadFiles()
        isScratchpadDirty = false
    }

    private func saveScratchpad() {
        guard let url = fileProjectURL else { return }

        scratchpadSaveWorkItem?.cancel()
        normalizeScratchpadFiles()

        let fileURL = scratchpadFileURL(for: url)
        do {
            if url.pathExtension.lowercased() != "ows" {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            try scratchpadDocumentText.write(to: fileURL, atomically: true, encoding: .utf8)
            if let snapshot = fileSnapshot(for: fileURL) {
                lastKnownModDates["__scratchpad__"] = snapshot.modificationDate
                lastKnownFileSnapshots[ProjectDatabaseBridge.scratchpadPath] = snapshot
            }
            isScratchpadDirty = false
            refreshSaveIndicator()
        } catch {
            statusMessage = "Failed to save scratchpad: \(error.localizedDescription)"
        }
    }

    func lyricIterationText(forPath path: String, slot: Int) -> String {
        let normalizedSlot = Self.clampedLyricIterationSlot(slot)
        return lyricIterationFiles.first(where: {
            $0.songRelativePath == path && $0.slot == normalizedSlot
        })?.content ?? ""
    }

    func lyricIterationRelativePath(forPath path: String, slot: Int) -> String {
        Self.lyricIterationRelativePath(forSongPath: path, slot: slot)
    }

    private static func clampedLyricIterationSlot(_ slot: Int) -> Int {
        min(max(slot, lyricIterationSlots.lowerBound), lyricIterationSlots.upperBound)
    }

    private static func lyricIterationKey(forSongPath path: String, slot: Int) -> String {
        "\(path)#\(clampedLyricIterationSlot(slot))"
    }

    static func lyricIterationRelativePath(forSongPath songPath: String, slot: Int) -> String {
        let normalizedSlot = clampedLyricIterationSlot(slot)
        let nsPath = songPath as NSString
        let directory = nsPath.deletingLastPathComponent
        let songName = (nsPath.lastPathComponent as NSString).deletingPathExtension
        let folderName = "\(songName)\(lyricIterationFolderSuffix)"

        if directory.isEmpty || directory == "." {
            return "\(folderName)/iteration-\(normalizedSlot).txt"
        }
        return "\(directory)/\(folderName)/iteration-\(normalizedSlot).txt"
    }

    static func isLyricIterationRelativePath(_ path: String) -> Bool {
        path.contains("\(lyricIterationFolderSuffix)/iteration-") && path.hasSuffix(".txt")
    }

    private func lyricIterationFileURL(forSongPath songPath: String, slot: Int, projectURL: URL) -> URL {
        let normalizedSlot = Self.clampedLyricIterationSlot(slot)
        if projectURL.pathExtension.lowercased() == "ows" {
            let songName = projectURL.deletingPathExtension().lastPathComponent
            return projectURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(songName)\(Self.lyricIterationFolderSuffix)")
                .appendingPathComponent("iteration-\(normalizedSlot).txt")
        }

        return projectURL.appendingPathComponent(
            Self.lyricIterationRelativePath(forSongPath: songPath, slot: normalizedSlot)
        )
    }

    private func normalizeLyricIterationFiles() {
        let idsByKey = Dictionary(uniqueKeysWithValues: lyricIterationFiles.map {
            (Self.lyricIterationKey(forSongPath: $0.songRelativePath, slot: $0.slot), $0.id)
        })
        let contentByKey = Dictionary(uniqueKeysWithValues: lyricIterationFiles.map {
            (Self.lyricIterationKey(forSongPath: $0.songRelativePath, slot: $0.slot), $0.content)
        })

        lyricIterationFiles = librettoFiles.flatMap { file in
            Self.lyricIterationSlots.map { slot in
                let key = Self.lyricIterationKey(forSongPath: file.relativePath, slot: slot)
                return SongLyricIterationFile(
                    id: idsByKey[key] ?? UUID(),
                    songRelativePath: file.relativePath,
                    slot: slot,
                    relativePath: Self.lyricIterationRelativePath(forSongPath: file.relativePath, slot: slot),
                    content: contentByKey[key] ?? ""
                )
            }
        }
    }

    private func loadLyricIterations(from projectURL: URL) async {
        normalizeLyricIterationFiles()

        for index in lyricIterationFiles.indices {
            let fileURL = lyricIterationFileURL(
                forSongPath: lyricIterationFiles[index].songRelativePath,
                slot: lyricIterationFiles[index].slot,
                projectURL: projectURL
            )
            if let data = try? Data(contentsOf: fileURL),
               let text = String(data: data, encoding: .utf8) {
                lyricIterationFiles[index].content = text
            } else {
                lyricIterationFiles[index].content = ""
            }
        }
    }

    /// Write a CLAUDE.md in the project directory and its parent so external
    /// Claude sessions know how to find and follow the project instructions.
    private func ensureClaudeMD(in projectURL: URL) {
        // Ensure redirect CLAUDE.md exists in the parent directory (independent check)
        let owpName = projectURL.lastPathComponent
        let parentClaudeMD = projectURL.deletingLastPathComponent().appendingPathComponent("CLAUDE.md")
        if !FileManager.default.fileExists(atPath: parentClaudeMD.path) {
            let parentContent = """
            # \(projectURL.deletingLastPathComponent().deletingPathExtension().lastPathComponent)

            This project uses the Write OWP package format. All project files live inside the `\(owpName)/` directory.

            **IMPORTANT:** The authoritative project instructions are in `\(owpName)/CLAUDE.md`. You MUST read and follow \
            that file. If you opened this session from outside the .owp folder, run:

            ```
            cat \(owpName)/CLAUDE.md
            ```

            All scene files, embedded synopsis blocks, metadata, and markup rules are documented there.
            """
            try? parentContent.write(to: parentClaudeMD, atomically: true, encoding: .utf8)
        }

        // Only write in-project CLAUDE.md if it doesn't exist — don't overwrite customizations
        let claudeMD = projectURL.appendingPathComponent("CLAUDE.md")
        guard !FileManager.default.fileExists(atPath: claudeMD.path) else { return }

        let content = """
        # Project Instructions for Claude

        This is a Write opera/musical project.

        > **NOTE:** If a Claude Code session is opened from within this .owp folder, this file is the \
        authoritative source of project instructions. If opened from the parent directory, a redirect \
        CLAUDE.md there will point you here.

        ## Project Structure

        - `Songs/` — Scene files (.ows JSON). Each contains a libretto (script/lyrics) with version history.
        - `Metadata/project.json` — Project metadata.

        ## Synopsis

        Each scene's synopsis lives inside that scene's `.ows` file as a hidden block in the active lyrics:
        ```
        {{{SYNOPSIS}}}
        Summary text here
        {{{/SYNOPSIS}}}
        ```
        The Write workspace reads these embedded synopsis blocks directly from `Songs/*.ows` at startup. \
        Do not create or rely on a separate `Synopsis/` folder or `Synopsis/synopsis.txt`.

        **When you modify scenes:** After making changes to any scene's lyrics/libretto, update that scene's embedded \
        `{{{SYNOPSIS}}}` block so it stays in sync with the current script.

        When updating synopsis content:
        1. Read the relevant scene file(s) from `Songs/`
        2. Update the embedded `{{{SYNOPSIS}}}` block(s) inside the relevant `.ows` file(s)
        3. Keep the synopsis text hidden from normal libretto display by preserving the block markup

        ## Scene Files (.ows)

        Each .ows file is JSON. The relevant fields for the libretto are:
        - `title` — Scene title
        - `versions` — Array of version objects, each with `lyrics` (the script text)
        - `activeVersionID` — Which version is current
        - `notes` — Scene-specific notes

        ## Markup Syntax in Lyrics

        Four bracket levels are used, each for a different purpose:

        1. **Direction** — double brackets: `[[1.01.0.001 - Description]]`
           Numbered direction shots with act.scene.subsection.direction addresses.

        2. **Action** — single brackets: `[The mountains press in from all sides...]`
           Prose action atmosphere/staging descriptions that add to the reading experience.

        3. **Camera** — canonical single brackets: `[camera: zoom_in | from=wide | to=close | bars=17-24]`
           Technical instructions for Camera. Keywords include: scene, camera, enter, exit, move, emotion, action, gesture, object, object_move, object_state, object_visibility, lipsync, pause, sfx, transition.
           Legacy single-curly camera blocks may still appear in older files, but new authoring should use the canonical single-bracket Camera DSL.

        4. **Summary blocks** — triple curly braces: `{{{SUMMARY}}}...{{{/SUMMARY}}}`
           Scene summary blocks displayed in the sidebar.

        Only modify the `lyrics`, `title`, and `notes` fields. Do not modify music/MIDI data.
        """

        try? content.write(to: claudeMD, atomically: true, encoding: .utf8)
    }

    // MARK: - Agent Edit Accept / Reject

    func acceptAgentEdits() {
        for (path, content) in pendingAgentEdits {
            updateLyricsForSong(atPath: path, lyrics: content)
        }
        // Clear pending state
        pendingAgentEdits.removeAll()
        pendingAgentSnapshotID = nil
    }

    func rejectAgentEdits() {
        // librettoFiles were never modified, so just clear pending state
        pendingAgentEdits.removeAll()
        pendingAgentSnapshotID = nil
    }

    // MARK: - Local Revision Tracking

    func applyEditorChange(path: String, lyrics: String) {
        updateLyricsForSong(atPath: path, lyrics: lyrics)
    }

    // MARK: - Restore Last Project

    func restoreLastProject() {
        guard let path = UserDefaults.standard.string(forKey: "lastProjectPath") else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Task {
            await loadProject(url: url)
        }
    }


    // MARK: - File Watching (poll-based)

    // MARK: - Project Settings (synced via project bundle)

    /// Load project-level settings from the OWP bundle. Called after project load.
    func loadProjectSettings() {
        guard let url = fileProjectURL else { return }
        let settings = ProjectSettingsPersistence.load(from: url)

        // Apply page and metadata styling settings (project values override UserDefaults)
        if let v = settings.directionMarkupColorHex { directionMarkupColorHex = v }
        if let v = settings.storyboardingMarkupColorHex { storyboardingMarkupColorHex = v }
        if let v = settings.animateMarkupColorHex { animateMarkupColorHex = v }
        if let v = settings.scriptBackgroundColorHex { scriptBackgroundColorHex = v }

        // Apply LLM settings
        let config = LLMProviderConfig.shared
        if let provider = settings.llmProvider.flatMap({ LLMProviderType(rawValue: $0) }) {
            config.activeProvider = provider
        }
        if let key = settings.llmMiniMaxKey, !key.isEmpty {
            config.setAPIKey(key, for: .minimax)
        }
        if let key = settings.llmDeepSeekKey, !key.isEmpty {
            config.setAPIKey(key, for: .deepseek)
        }
        if let key = settings.llmOpenCodeKey, !key.isEmpty {
            config.setAPIKey(key, for: .opencode)
        }
        if let model = settings.llmMiniMaxModel { config.setModelID(model, for: .minimax) }
        if let model = settings.llmDeepSeekModel { config.setModelID(model, for: .deepseek) }
        if let model = settings.llmOpenCodeModel { config.setModelID(model, for: .opencode) }
        if let model = settings.llmClaudeModel { config.setModelID(model, for: .claude) }
    }

    // MARK: - Script Cards Sidecar

    /// Load the script-cards sidecar from `Metadata/script-cards.json`.
    /// For any song that has no cards entry yet (legacy projects), import
    /// the cards from the song's bracket markup and persist back so the
    /// migration only happens once. Lyrics are never modified.
    func loadAndImportScriptCards() {
        guard let url = fileProjectURL else {
            scriptCards = ScriptDocumentCards()
            return
        }
        var working = (try? ScriptCardSidecarStore.load(projectURL: url)) ?? ScriptDocumentCards()
        var didImport = false
        for file in librettoFiles where working.songs[file.relativePath] == nil {
            let imported = ScriptCardImporter.importLyrics(
                file.content,
                songRelativePath: file.relativePath
            )
            guard !imported.scenes.isEmpty else { continue }
            working.songs[file.relativePath] = imported
            didImport = true
        }
        scriptCards = working
        if didImport {
            try? ScriptCardSidecarStore.save(working, projectURL: url)
        }
    }

    /// Persist `scriptCards` to disk. Called after card edits / Director
    /// Pass acceptances; cheap enough to call eagerly.
    func saveScriptCards() {
        guard let url = fileProjectURL else { return }
        try? ScriptCardSidecarStore.save(scriptCards, projectURL: url)
    }

    /// Re-run the legacy markup importer for a single song, replacing the
    /// in-memory entry. Used by debug tooling and the future "Reimport
    /// from markup" action — does not auto-save.
    func reimportScriptCards(forSongAt path: String) {
        guard let file = librettoFiles.first(where: { $0.relativePath == path }) else {
            scriptCards.songs.removeValue(forKey: path)
            return
        }
        let imported = ScriptCardImporter.importLyrics(file.content, songRelativePath: path)
        if imported.scenes.isEmpty {
            scriptCards.songs.removeValue(forKey: path)
        } else {
            scriptCards.songs[path] = imported
        }
    }

    /// Save project-level settings to the OWP bundle.
    func saveProjectSettings() {
        guard let url = fileProjectURL else { return }
        let config = LLMProviderConfig.shared
        let settings = ProjectSettingsData(
            directionMarkupColorHex: directionMarkupColorHex,
            storyboardingMarkupColorHex: storyboardingMarkupColorHex,
            animateMarkupColorHex: animateMarkupColorHex,
            scriptBackgroundColorHex: scriptBackgroundColorHex,
            llmProvider: config.activeProvider.rawValue,
            llmMiniMaxKey: config.apiKey(for: .minimax),
            llmDeepSeekKey: config.apiKey(for: .deepseek),
            llmOpenCodeKey: config.apiKey(for: .opencode),
            llmMiniMaxModel: config.modelID(for: .minimax),
            llmDeepSeekModel: config.modelID(for: .deepseek),
            llmOpenCodeModel: config.modelID(for: .opencode),
            llmClaudeModel: config.modelID(for: .claude)
        )
        ProjectSettingsPersistence.save(settings, to: url)
    }

    func startFileWatching() {
        stopFileWatching()
        guard fileProjectURL != nil else { return }
        isFileWatchingActive = true
        fileWatchGeneration &+= 1
        let generation = fileWatchGeneration
        recordModDates()
        scheduleFileCheck(generation: generation)
    }

    func processExternalChangesNow() {
        checkForExternalChanges()
    }

    func stopFileWatching() {
        isFileWatchingActive = false
        fileWatchGeneration &+= 1
        fileWatchWorkItem?.cancel()
        fileWatchWorkItem = nil
    }

    private func scheduleFileCheck(generation: UInt64) {
        guard isFileWatchingActive,
              fileWatchGeneration == generation,
              fileProjectURL != nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isFileWatchingActive,
                  self.fileWatchGeneration == generation else { return }
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                await self.checkForExternalChangesIfNeeded()
            }
            guard self.isFileWatchingActive,
                  self.fileWatchGeneration == generation else { return }
            self.scheduleFileCheck(generation: generation)
        }
        fileWatchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalWatchInterval, execute: item)
    }

    private func checkForExternalChangesIfNeeded() async {
        guard let url = fileProjectURL, !isSaving, !isLoadingProject else { return }

        let currentStubs = nonisolatedCurrentSongStubs(for: url)
        let currentPaths = currentStubs.map(\.relativePath)
        let existingPaths = songStubs.map(\.relativePath)

        var changedStubs: [(SongStub, Date, ProjectFileSnapshot)] = []

        if currentPaths != existingPaths {
            for stub in currentStubs {
                if let snapshot = await nonisolatedFileSnapshot(for: stub.fileURL) {
                    let lastKnown = lastKnownFileSnapshots[stub.relativePath]
                    if lastKnown == nil || snapshot != lastKnown! {
                        changedStubs.append((stub, snapshot.modificationDate, snapshot))
                    }
                }
            }
        } else {
            for stub in songStubs {
                if let snapshot = await nonisolatedFileSnapshot(for: stub.fileURL) {
                    let lastKnown = lastKnownFileSnapshots[stub.relativePath]
                    if let lastKnown, snapshot != lastKnown {
                        changedStubs.append((stub, snapshot.modificationDate, snapshot))
                    }
                }
            }
        }

        guard !changedStubs.isEmpty || currentPaths != existingPaths else { return }

        await MainActor.run { [weak self] in
            guard let self else { return }
            if currentPaths != songStubs.map(\.relativePath) {
                self.reloadSongMembershipFromDisk(stubs: currentStubs, projectURL: url)
            }
            for (stub, modDate, snapshot) in changedStubs {
                self.lastKnownModDates[stub.relativePath] = snapshot.modificationDate
                self.lastKnownFileSnapshots[stub.relativePath] = snapshot
                self.reloadExternallyChanged(stub: stub, modDate: modDate)
            }
        }
    }

    private nonisolated func nonisolatedCurrentSongStubs(for projectURL: URL) -> [SongStub] {
        guard projectURL.pathExtension.lowercased() != "ows" else { return [] }
        return OWPProjectIO.enumerateProjectSongStubs(in: projectURL)
    }

    private nonisolated func nonisolatedFileSnapshot(for url: URL) async -> ProjectFileSnapshot? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modDate = values.contentModificationDate,
              let fileSize = values.fileSize else { return nil }
        let truncated = Date(timeIntervalSinceReferenceDate: modDate.timeIntervalSinceReferenceDate.rounded(.down))
        return ProjectFileSnapshot(modificationDate: truncated, fileSize: Int64(fileSize))
    }

    /// Wait for a file's size to stop changing (SyncThing writes are not atomic).
    /// Returns the stable size, or 0 if the file vanished or stayed unstable.
    private nonisolated static func waitForStableFileSize(url: URL, maxAttempts: Int = 5) async -> Int64 {
        var previousSize: Int64 = -1
        for _ in 0..<maxAttempts {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if size > 0 && size == previousSize { return size }
            previousSize = size
            try? await Task.sleep(for: .milliseconds(200))
        }
        return previousSize > 0 ? previousSize : 0
    }

    private func recordModDates() {
        for stub in songStubs {
            if let snapshot = fileSnapshot(for: stub.fileURL) {
                lastKnownModDates[stub.relativePath] = snapshot.modificationDate
                lastKnownFileSnapshots[stub.relativePath] = snapshot
            }
        }

        guard let projectURL = fileProjectURL else { return }

        let scratchpadURL = scratchpadFileURL(for: projectURL)
        if let snapshot = fileSnapshot(for: scratchpadURL) {
            lastKnownModDates["__scratchpad__"] = snapshot.modificationDate
            lastKnownFileSnapshots[ProjectDatabaseBridge.scratchpadPath] = snapshot
        }

        for file in lyricIterationFiles {
            let fileURL = lyricIterationFileURL(
                forSongPath: file.songRelativePath,
                slot: file.slot,
                projectURL: projectURL
            )
            if let snapshot = fileSnapshot(for: fileURL) {
                lastKnownModDates[file.relativePath] = snapshot.modificationDate
                lastKnownFileSnapshots[file.relativePath] = snapshot
            }
        }
    }

    private func currentSongStubs(for projectURL: URL) -> [SongStub] {
        guard projectURL.pathExtension.lowercased() != "ows" else {
            return songStubs
        }
        return OWPProjectIO.enumerateProjectSongStubs(in: projectURL)
    }

    private func resetTrackedFileSnapshots() {
        lastKnownModDates.removeAll()
        lastKnownFileSnapshots.removeAll()
        recordModDates()
    }

    private func reloadSongMembershipFromDisk(stubs: [SongStub], projectURL: URL) {
        let previousPaths = songStubs.map(\.relativePath)
        let currentPaths = stubs.map(\.relativePath)
        guard previousPaths != currentPaths else { return }

        let previousPathSet = Set(previousPaths)
        let currentPathSet = Set(currentPaths)
        let removedPaths = previousPaths.filter { !currentPathSet.contains($0) }
        let addedPaths = currentPaths.filter { !previousPathSet.contains($0) }
        let changedExistingStubs: [(SongStub, Date)] = stubs.compactMap { stub in
            guard previousPathSet.contains(stub.relativePath),
                  let snapshot = fileSnapshot(for: stub.fileURL),
                  snapshot != lastKnownFileSnapshots[stub.relativePath] else {
                return nil
            }
            return (stub, snapshot.modificationDate)
        }

        let assetsByPath = Dictionary(uniqueKeysWithValues: songAssets.map { ($0.relativePath, $0) })
        let librettoByPath = Dictionary(uniqueKeysWithValues: librettoFiles.map { ($0.relativePath, $0) })

        songStubs = stubs
        songAssets = stubs.map { stub in
            assetsByPath[stub.relativePath]
                ?? OWSSongAsset(
                    relativePath: stub.relativePath,
                    document: ProjectDatabaseBridge.makePlaceholderDocument(from: stub)
                )
        }
        librettoFiles = stubs.map { stub in
            librettoByPath[stub.relativePath]
                ?? ProjectTextFile(id: UUID(), relativePath: stub.relativePath, content: "")
        }
        for path in stubs.map(\.relativePath) {
            bumpLibrettoRevision(for: path)
        }

        hydratedScenePaths.formIntersection(currentPathSet)
        hydratingScenePaths.formIntersection(currentPathSet)
        dirtySongPaths.formIntersection(currentPathSet)

        if let selectedSongPath, !currentPathSet.contains(selectedSongPath) {
            self.selectedSongPath = songAssets.first?.relativePath
        }
        if let activeSongPath, !currentPathSet.contains(activeSongPath) {
            self.activeSongPath = songAssets.first?.relativePath
        }
        if let targetRequest = scrollTargetRequest, !currentPathSet.contains(targetRequest.path) {
            self.scrollTargetRequest = nil
        }

        normalizeScratchpadFiles()
        normalizeLyricIterationFiles()
        resetTrackedFileSnapshots()
        refreshSaveIndicator()

        for (stub, modDate) in changedExistingStubs {
            reloadExternallyChanged(stub: stub, modDate: modDate)
        }
        for path in addedPaths {
            ensureSceneHydrated(path: path)
        }

        let changedPaths = Array(Set(addedPaths + removedPaths)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        guard !changedPaths.isEmpty else { return }

        beginAgentSync()
        appendProjectHistory(
            kind: .externalReload,
            title: "Reloaded external project changes",
            message: summarizeTrackedPaths(changedPaths),
            relativePaths: changedPaths
        )
        refreshGitHistory()
        markAgentUpdated(paths: changedPaths)
        statusMessage = "Reloaded external project changes"
    }

    private func checkForExternalChanges() {
        guard let url = fileProjectURL, !isSaving, !isLoadingProject else { return }

        let currentStubs = currentSongStubs(for: url)
        if currentStubs.map(\.relativePath) != songStubs.map(\.relativePath) {
            reloadSongMembershipFromDisk(stubs: currentStubs, projectURL: url)
        }

        for stub in songStubs {
            guard let snapshot = fileSnapshot(for: stub.fileURL) else { continue }
            guard let lastKnown = lastKnownFileSnapshots[stub.relativePath] else {
                lastKnownModDates[stub.relativePath] = snapshot.modificationDate
                lastKnownFileSnapshots[stub.relativePath] = snapshot
                continue
            }
            if snapshot != lastKnown {
                reloadExternallyChanged(stub: stub, modDate: snapshot.modificationDate)
            }
        }

        let scratchpadURL = scratchpadFileURL(for: url)
        if let snapshot = fileSnapshot(for: scratchpadURL) {
            let lastKnown = lastKnownFileSnapshots[ProjectDatabaseBridge.scratchpadPath]
            if lastKnown == nil {
                lastKnownModDates["__scratchpad__"] = snapshot.modificationDate
                lastKnownFileSnapshots[ProjectDatabaseBridge.scratchpadPath] = snapshot
            } else if snapshot != lastKnown! {
                lastKnownModDates["__scratchpad__"] = snapshot.modificationDate
                lastKnownFileSnapshots[ProjectDatabaseBridge.scratchpadPath] = snapshot
                if let data = try? Data(contentsOf: scratchpadURL),
                   let text = String(data: data, encoding: .utf8),
                   text != scratchpadDocumentText {
                    beginAgentSync()
                    scratchpadFiles = Self.parseScratchpadSections(
                        from: text,
                        orderedPaths: librettoFiles.map(\.relativePath)
                    )
                    normalizeScratchpadFiles()
                    isScratchpadDirty = false
                    appendProjectHistory(
                        kind: .externalReload,
                        title: "Reloaded scratchpad from disk",
                        message: ProjectDatabaseBridge.scratchpadPath,
                        relativePaths: [ProjectDatabaseBridge.scratchpadPath]
                    )
                    refreshGitHistory()
                    markAgentUpdated()
                    statusMessage = "Scratchpad reloaded (external change)"
                }
            }
        }

        checkLyricIterationExternalChanges(for: url)
    }

    private func checkLyricIterationExternalChanges(for projectURL: URL) {
        var changedRelativePaths: [String] = []
        var startedSync = false

        for index in lyricIterationFiles.indices {
            let relativePath = lyricIterationFiles[index].relativePath
            let fileURL = lyricIterationFileURL(
                forSongPath: lyricIterationFiles[index].songRelativePath,
                slot: lyricIterationFiles[index].slot,
                projectURL: projectURL
            )
            let snapshot = fileSnapshot(for: fileURL)
            let lastKnown = lastKnownFileSnapshots[relativePath]

            guard snapshot != lastKnown else { continue }

            if let snapshot {
                lastKnownModDates[relativePath] = snapshot.modificationDate
                lastKnownFileSnapshots[relativePath] = snapshot
            } else {
                lastKnownModDates.removeValue(forKey: relativePath)
                lastKnownFileSnapshots.removeValue(forKey: relativePath)
            }

            let newText: String
            if let data = try? Data(contentsOf: fileURL),
               let text = String(data: data, encoding: .utf8) {
                newText = text
            } else {
                newText = ""
            }

            guard newText != lyricIterationFiles[index].content else { continue }

            if !startedSync {
                beginAgentSync()
                startedSync = true
            }

            lyricIterationFiles[index].content = newText
            changedRelativePaths.append(relativePath)
        }

        guard !changedRelativePaths.isEmpty else { return }

        appendProjectHistory(
            kind: .externalReload,
            title: "Reloaded lyric iterations from disk",
            message: summarizeTrackedPaths(changedRelativePaths),
            relativePaths: changedRelativePaths
        )
        refreshGitHistory()
        markAgentUpdated()
        statusMessage = changedRelativePaths.count == 1
            ? "Lyric iteration reloaded (external change)"
            : "Lyric iterations reloaded (external changes)"
    }

    private func reloadExternallyChanged(stub: SongStub, modDate: Date) {
        let path = stub.relativePath
        beginAgentSync()
        let hadLocalDraft = dirtySongPaths.contains(path)
        let localDraftLyrics = hadLocalDraft
            ? librettoFiles.first(where: { $0.relativePath == path })?.content
            : nil

        // External change wins for this file.
        dirtySongPaths.remove(path)

        lastKnownModDates[path] = modDate
        if let snapshot = fileSnapshot(for: stub.fileURL) {
            lastKnownFileSnapshots[path] = snapshot
        }

        Task {
            do {
                // Wait for the file to stabilize (SyncThing may still be writing)
                let stableSize = await Self.waitForStableFileSize(url: stub.fileURL)
                guard stableSize > 0 else {
                    NSLog("[ExternalReload] Skipping %@ — file empty or unstable", path)
                    return
                }
                let previousLyrics = librettoFiles.first(where: { $0.relativePath == path })?.content ?? ""
                var asset = try await OWPProjectIO.loadSongAsync(stub: stub)
                let promotedLatestVersion = preferMostRecentlyUpdatedVersionIfNeeded(in: &asset.document)
                let externalLyrics = asset.document.activeVersion()?.lyrics ?? ""
                preserveLocalDraftIfNeeded(
                    path: path,
                    localDraftLyrics: localDraftLyrics,
                    externalLyrics: externalLyrics,
                    in: &asset.document
                )

                if let idx = songAssets.firstIndex(where: { $0.relativePath == path }) {
                    songAssets[idx] = asset
                }

                if let version = asset.document.activeVersion(),
                   let libIdx = librettoFiles.firstIndex(where: { $0.relativePath == path }) {
                    librettoFiles[libIdx].content = version.lyrics
                    bumpLibrettoRevision(for: path)
                }
                normalizeScratchpadFiles()
                normalizeLyricIterationFiles()

                let latestLyrics = asset.document.activeVersion()?.lyrics ?? ""
                let detail = promotedLatestVersion
                    ? "\(path) (promoted latest version)"
                    : path
                if latestLyrics != previousLyrics || promotedLatestVersion {
                    appendProjectHistory(
                        kind: .externalReload,
                        title: "Reloaded external scene change",
                        message: detail,
                        relativePaths: [path]
                    )
                } else {
                    persistProjectHistoryState()
                }
                refreshGitHistory()
                markAgentUpdated(paths: [path])
                statusMessage = "Reloaded: \(asset.displayName) (external change)"
            } catch {
                isAgentSyncInProgress = false
                statusMessage = "Failed to reload: \(stub.displayName)"
            }
        }
    }

    private func preserveLocalDraftIfNeeded(
        path: String,
        localDraftLyrics: String?,
        externalLyrics: String,
        in document: inout OWSSongDocument
    ) {
        guard let localDraftLyrics, localDraftLyrics != externalLyrics else { return }
        let now = Date()
        let autosave = OWSVersionPayload(
            id: UUID(),
            label: "Auto-save before external reload",
            createdAt: now,
            updatedAt: now,
            lyrics: localDraftLyrics,
            saveType: .autosave,
            userLabel: "Preserved local draft",
            isBookmarked: false
        )
        document.versions.append(autosave)
        document.normalize()

        projectHistoryEntries.insert(
            ProjectHistoryEntry(
                kind: .autosave,
                title: "Preserved local draft",
                message: path,
                relativePaths: [path]
            ),
            at: 0
        )
        projectHistoryEntries = Array(projectHistoryEntries.prefix(Self.maxProjectHistoryEntries))
    }

    private static func slugifySceneTitle(_ title: String) -> String {
        let replaced = title.lowercased().replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func upsertSceneIndexEntry(
        projectURL: URL,
        sceneID: UUID,
        slug: String,
        title: String,
        activeVersionID: UUID,
        order: Int,
        updatedAt: String
    ) throws {
        let indexURL = projectURL.appendingPathComponent("Scenes/scene-index.json")
        var root: [String: Any] = [
            "schemaVersion": 1,
            "projectID": UUID().uuidString,
            "updatedAt": updatedAt,
            "scenes": [],
        ]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = decoded
        }

        var scenes = root["scenes"] as? [[String: Any]] ?? []
        scenes.removeAll { ($0["slug"] as? String) == slug || ($0["id"] as? String) == sceneID.uuidString }
        scenes.append([
            "id": sceneID.uuidString,
            "slug": slug,
            "scenePath": "Scenes/\(slug)/scene.json",
            "title": title,
            "canonicalTitle": slug,
            "activeVersionID": activeVersionID.uuidString.lowercased(),
            "order": order,
            "updatedAt": updatedAt,
        ])
        scenes.sort {
            let lhs = ($0["order"] as? Int) ?? 0
            let rhs = ($1["order"] as? Int) ?? 0
            if lhs != rhs { return lhs < rhs }
            return (($0["slug"] as? String) ?? "") < (($1["slug"] as? String) ?? "")
        }
        root["scenes"] = scenes
        root["updatedAt"] = updatedAt

        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: indexURL, options: .atomic)
    }

    func applySyncedLyricsChange(atPath path: String, lyrics: String, sourceTitle: String = "Applied synced AI change") {
        let currentLyrics = librettoFiles.first(where: { $0.relativePath == path })?.content ?? ""
        guard currentLyrics != lyrics else { return }

        updateLyricsForSong(atPath: path, lyrics: lyrics)
        markAgentUpdated(paths: [path])
        appendProjectHistory(
            kind: .agentSync,
            title: sourceTitle,
            message: summarizeTrackedPaths([path]),
            relativePaths: [path]
        )
    }

    private func markDirty(path: String, status: String = "Unsaved changes") {
        dirtySongPaths.insert(path)
        refreshSaveIndicator()
        if status != "Unsaved changes" {
            statusMessage = status
        }
    }

    var hasUnsavedChanges: Bool {
        !dirtySongPaths.isEmpty || isScratchpadDirty || metadataDirty
    }

    var canSave: Bool {
        fileProjectURL != nil && !isSaving && hasUnsavedChanges
    }

    private func refreshSaveIndicator() {
        if isSaving {
            saveIndicator = .saving
            return
        }
        guard projectURL != nil else {
            saveIndicator = .idle
            return
        }
        saveIndicator = hasUnsavedChanges ? .unsavedChanges : .saved
    }

    private func beginAgentSync() {
        isAgentSyncInProgress = true
    }

    private func markAgentUpdated(paths: [String] = []) {
        isAgentSyncInProgress = false
        showsRecentAgentUpdate = true
        let marker = Date()

        for path in paths where !path.isEmpty {
            externalChangeTimes[path] = marker
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                guard let self else { return }
                if self.externalChangeTimes[path] == marker {
                    self.externalChangeTimes.removeValue(forKey: path)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            if self.showsRecentAgentUpdate {
                self.showsRecentAgentUpdate = false
            }
        }
    }

    private func handleSaveConflict(conflictPaths: [String]) {
        let uniquePaths = Array(Set(conflictPaths)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        for path in uniquePaths {
            guard let stub = songStubs.first(where: { $0.relativePath == path }),
                  let snapshot = fileSnapshot(for: stub.fileURL) else {
                dirtySongPaths.remove(path)
                continue
            }
            reloadExternallyChanged(stub: stub, modDate: snapshot.modificationDate)
        }

        statusMessage = "Detected newer agent/disk changes. Reloaded them instead of saving."
    }

    private func preferMostRecentlyUpdatedVersionIfNeeded(in document: inout OWSSongDocument) -> Bool {
        guard let latestVersion = document.versions.max(by: { $0.updatedAt < $1.updatedAt }) else { return false }
        guard latestVersion.id != document.activeVersionID else { return false }
        if let activeVersion = document.activeVersion(),
           latestVersion.updatedAt <= activeVersion.updatedAt {
            return false
        }
        document.activeVersionID = latestVersion.id
        document.updatedAt = max(document.updatedAt, latestVersion.updatedAt)
        return true
    }

    private func trackedFileSnapshots(for projectURL: URL, stubs: [SongStub]) -> [String: ProjectFileSnapshot] {
        var snapshots: [String: ProjectFileSnapshot] = [:]

        for stub in stubs {
            if let snapshot = fileSnapshot(for: stub.fileURL) {
                snapshots[stub.relativePath] = snapshot
            }
        }

        let scratchpadURL = scratchpadFileURL(for: projectURL)
        if let snapshot = fileSnapshot(for: scratchpadURL) {
            snapshots[ProjectDatabaseBridge.scratchpadPath] = snapshot
        }

        for stub in stubs {
            for slot in Self.lyricIterationSlots {
                let relativePath = Self.lyricIterationRelativePath(forSongPath: stub.relativePath, slot: slot)
                let fileURL = lyricIterationFileURL(
                    forSongPath: stub.relativePath,
                    slot: slot,
                    projectURL: projectURL
                )
                if let snapshot = fileSnapshot(for: fileURL) {
                    snapshots[relativePath] = snapshot
                }
            }
        }

        return snapshots
    }

    private func fileSnapshot(for fileURL: URL) -> ProjectFileSnapshot? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate else {
            return nil
        }

        // Truncate to integer seconds so snapshots round-trip through ISO 8601
        // encoding without false-positive diffs from sub-second precision loss.
        let truncated = Date(timeIntervalSinceReferenceDate: modificationDate.timeIntervalSinceReferenceDate.rounded(.down))

        return ProjectFileSnapshot(
            modificationDate: truncated,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    private func changedTrackedPaths(
        from previous: [String: ProjectFileSnapshot],
        to current: [String: ProjectFileSnapshot]
    ) -> [String] {
        let allKeys = Set(previous.keys).union(current.keys)
        return allKeys
            .filter { previous[$0] != current[$0] }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func appendProjectHistory(
        kind: ProjectHistoryEntryKind,
        title: String,
        message: String,
        relativePaths: [String]
    ) {
        guard kind != .autosave else { return }
        let entry = ProjectHistoryEntry(
            kind: kind,
            title: title,
            message: message,
            relativePaths: Array(Set(relativePaths)).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        )
        projectHistoryEntries.insert(entry, at: 0)
        projectHistoryEntries = Array(projectHistoryEntries.prefix(Self.maxProjectHistoryEntries))
        persistProjectHistoryState()
    }

    private func filteredProjectHistoryEntries(_ entries: [ProjectHistoryEntry]) -> [ProjectHistoryEntry] {
        entries.filter { $0.kind != .autosave }
    }

    private func persistProjectHistoryState() {
        guard let projectURL else { return }
        let state = PersistedProjectHistoryState(
            fileSnapshots: trackedFileSnapshots(for: projectURL, stubs: songStubs),
            entries: filteredProjectHistoryEntries(projectHistoryEntries)
        )
        projectHistoryStore.saveState(state, for: projectURL)
    }

    private func refreshGitHistory(for url: URL? = nil) {
        let projectURL = (url ?? projectURL)?.standardizedFileURL
        guard let projectURL else {
            gitHistoryEntries = []
            return
        }

        Task.detached { [gitHistoryService] in
            let commits = gitHistoryService.loadCommits(projectURL)
            await MainActor.run { [weak self] in
                guard let self, self.projectURL?.standardizedFileURL == projectURL else { return }
                self.gitHistoryEntries = commits
            }
        }
    }

    private func summarizeTrackedPaths(_ paths: [String]) -> String {
        let uniquePaths = Array(Set(paths)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        switch uniquePaths.count {
        case 0:
            return "No tracked files changed"
        case 1:
            return uniquePaths[0]
        case 2:
            return "\(uniquePaths[0]) and \(uniquePaths[1])"
        default:
            return "\(uniquePaths[0]), \(uniquePaths[1]), and \(uniquePaths.count - 2) more"
        }
    }

    private func sceneCountLabel(for count: Int) -> String {
        count == 1 ? "1 scene" : "\(count) scenes"
    }

    func suspendBackgroundWork() {
        stopFileWatching()
    }

    func resumeBackgroundWork() {
        startFileWatching()
    }

    func ensureSceneHydrated(path: String) {
        guard !hydratedScenePaths.contains(path),
              !hydratingScenePaths.contains(path) else {
            return
        }

        hydratingScenePaths.insert(path)
        let stub = songStubs.first(where: { $0.relativePath == path })

        Task { [weak self, stub, path] in
            guard let self else { return }

            let hydratedAsset = await self.hydrateScene(path: path, stub: stub)

            await MainActor.run {
                self.hydratingScenePaths.remove(path)
                guard let hydratedAsset else { return }
                self.applyHydratedAsset(hydratedAsset, forPath: path)
            }
        }
    }

    private func hydrateScene(path: String) async -> OWSSongAsset? {
        await hydrateScene(
            path: path,
            stub: songStubs.first(where: { $0.relativePath == path })
        )
    }

    private func hydrateScene(
        path: String,
        stub: SongStub?
    ) async -> OWSSongAsset? {
        if let stub {
            return try? await OWPProjectIO.loadSongAsync(stub: stub)
        }
        return nil
    }

    private func applyHydratedAsset(_ hydratedAsset: OWSSongAsset, forPath path: String) {
        if let songIndex = songAssets.firstIndex(where: { $0.relativePath == path }) {
            songAssets[songIndex] = hydratedAsset
        } else {
            songAssets.append(hydratedAsset)
        }

        if let activeLyrics = hydratedAsset.document.activeVersion()?.lyrics {
            if let librettoIndex = librettoFiles.firstIndex(where: { $0.relativePath == path }) {
                librettoFiles[librettoIndex].content = activeLyrics
            } else {
                librettoFiles.append(
                    ProjectTextFile(id: UUID(), relativePath: path, content: activeLyrics)
                )
            }
            bumpLibrettoRevision(for: path)
        }

        hydratedScenePaths.insert(path)
        normalizeScratchpadFiles()
    }

    private func prioritizedHydrationPaths(
        allPaths: [String],
        primaryPath: String?,
        externallyChangedPaths: [String]
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for path in [primaryPath].compactMap({ $0 }) + externallyChangedPaths + allPaths
        where seen.insert(path).inserted {
            ordered.append(path)
        }

        return ordered
    }

    private func persistRenamedSongTitle(path: String, preserveDirtyState wasDirty: Bool) -> Bool {
        guard let projectURL = fileProjectURL,
              let asset = songAssets.first(where: { $0.relativePath == path }) else {
            return false
        }

        let fileURL: URL
        if projectURL.pathExtension.lowercased() == "ows" {
            fileURL = projectURL
        } else {
            fileURL = projectURL.appendingPathComponent(path)
        }

        do {
            try OWSSongDocument.patchTitle(
                at: fileURL,
                title: asset.document.title,
                canonicalTitle: asset.document.canonicalTitle,
                updatedAt: asset.document.updatedAt
            )

            if let snapshot = fileSnapshot(for: fileURL) {
                lastKnownModDates[path] = snapshot.modificationDate
                lastKnownFileSnapshots[path] = snapshot
            }

            if !wasDirty {
                dirtySongPaths.remove(path)
                refreshSaveIndicator()
            }

            return true
        } catch {
            statusMessage = "Rename failed: \(error.localizedDescription)"
            return false
        }
    }
}
