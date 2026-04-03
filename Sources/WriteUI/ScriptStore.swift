import Foundation
import ProjectKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Debug Logging

private func novotroDebugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] [Write] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/write-debug.log")
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

enum ScriptMarkupPalette {
    static let defaultDirectionHex = "#59C7CC"
    static let defaultStoryboardingHex = "#F2A640"
    static let defaultAnimateHex = "#D973B3"

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

// MARK: - Model Types (self-contained, matching OperaWriter formats)

struct ProjectMetadata: Codable, Sendable {
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var notes: String
    var projectVersions: [ProjectVersionEntry]

    private enum CodingKeys: String, CodingKey {
        case name, createdAt, updatedAt, notes, projectVersions
    }

    init(name: String = "Untitled", createdAt: Date = Date(), updatedAt: Date = Date(), notes: String = "", projectVersions: [ProjectVersionEntry] = []) {
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notes = notes
        self.projectVersions = projectVersions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        projectVersions = try container.decodeIfPresent([ProjectVersionEntry].self, forKey: .projectVersions) ?? []
    }

    static func fresh(named name: String) -> ProjectMetadata {
        .init(name: name, createdAt: Date(), updatedAt: Date(), notes: "")
    }
}

struct ProjectVersionEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var label: String
    var userLabel: String?
    var saveType: VersionSaveType
    var isBookmarked: Bool
    var createdAt: Date
    var updatedAt: Date
    var songVersionMap: [String: UUID]

    private enum CodingKeys: String, CodingKey {
        case id, label, userLabel, saveType, isBookmarked, createdAt, updatedAt, songVersionMap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? "Version"
        userLabel = try container.decodeIfPresent(String.self, forKey: .userLabel)
        saveType = try container.decodeIfPresent(VersionSaveType.self, forKey: .saveType) ?? .manual
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
        songVersionMap = try container.decodeIfPresent([String: UUID].self, forKey: .songVersionMap) ?? [:]
    }
}

enum VersionSaveType: String, Codable, Sendable {
    case manual
    case autosave
    case snapshot
    case imported
}

struct ProjectTextFile: Identifiable, Hashable, Sendable {
    let id: UUID
    var relativePath: String
    var content: String

    var displayName: String {
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        return withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
    }
}

struct MidiAsset: Identifiable, Hashable, Sendable {
    let id: UUID
    var relativePath: String
    var data: Data

    var displayName: String {
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        let name = withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
        return name.toTitleCase()
    }
}

struct SongStub: Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let relativePath: String
    let fileSize: Int64

    var displayName: String {
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        return withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
    }
}

struct OPWCharacterImage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var filename: String
    var category: String

    init(id: UUID = UUID(), filename: String, category: String) {
        self.id = id
        self.filename = filename
        self.category = category
    }
}

struct OPWCharacter: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var description: String
    var associatedChannelKeys: [String]
    var galleryCategories: [String]
    var images: [OPWCharacterImage]
    var colorHex: String?
    var loraFilename: String?
    var loraWeight: Double?
    var loraTriggerWord: String?

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        associatedChannelKeys: [String] = [],
        galleryCategories: [String] = [],
        images: [OPWCharacterImage] = [],
        colorHex: String? = nil,
        loraFilename: String? = nil,
        loraWeight: Double? = nil,
        loraTriggerWord: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.associatedChannelKeys = associatedChannelKeys
        self.galleryCategories = galleryCategories
        self.images = images
        self.colorHex = colorHex
        self.loraFilename = loraFilename
        self.loraWeight = loraWeight
        self.loraTriggerWord = loraTriggerWord
    }

    var directoryName: String {
        let safe = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? id.uuidString : safe
    }
}

struct OPWCharactersFile: Codable, Sendable {
    var version: Int
    var characters: [OPWCharacter]

    init(version: Int = 1, characters: [OPWCharacter] = []) {
        self.version = version
        self.characters = characters
    }
}

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

// MARK: - String Extension

extension String {
    func toTitleCase() -> String {
        let words = self.split(separator: " ")
        return words.map { word in
            let s = String(word)
            if s.allSatisfy(\.isNumber) { return s }
            // Preserve all-uppercase words (Roman numerals, acronyms like II, III, ACT)
            if s.count > 1 && s == s.uppercased() && s.allSatisfy(\.isLetter) { return s }
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

// MARK: - OWP Project I/O (self-contained subset)

enum OWPProjectIO {
    static let metadataDir = "Metadata"
    static let projectMetadataFile = "Metadata/project.json"
    static let songsDir = "Songs"
    static let charactersDir = "Characters"
    static let charactersFile = "Characters/characters.json"
    static let synopsisDir = "Synopsis"
    static let synopsisFile = "Synopsis/synopsis.txt"

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
        let hasSongs = fm.fileExists(atPath: url.appendingPathComponent(songsDir).path)
        guard isOWP || hasMetadata || hasSongs else {
            throw NSError(domain: "ScriptWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid project: \(url.lastPathComponent)"])
        }

        let metadata: ProjectMetadata = {
            let metaURL = url.appendingPathComponent(projectMetadataFile)
            if let data = try? Data(contentsOf: metaURL, options: .mappedIfSafe),
               let decoded = try? configuredDecoder().decode(ProjectMetadata.self, from: data) {
                return decoded
            }
            return ProjectMetadata.fresh(named: url.deletingPathExtension().lastPathComponent)
        }()

        let stubs = enumerateSongStubs(in: url.appendingPathComponent(songsDir))
        return (metadata, stubs, false)
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
        let data = try Data(contentsOf: stub.fileURL, options: .mappedIfSafe)
        let document = try OWSSongDocument.fromJSON(data: data)
        return OWSSongAsset(relativePath: stub.relativePath, document: document)
    }

    // MARK: - Load Characters

    nonisolated static func loadCharacterManifestAsync(from packageURL: URL) async throws -> [OPWCharacter] {
        let jsonURL = packageURL.appendingPathComponent(charactersFile)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return [] }
        let data = try Data(contentsOf: jsonURL, options: .mappedIfSafe)
        let file = try configuredDecoder().decode(OPWCharactersFile.self, from: data)
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
            }
        }

        if !conflicts.isEmpty {
            throw SaveConflictError.externalChanges(paths: conflicts)
        }

        // Songs — patch files in-place (only update title/notes/lyrics, preserve heavy data)
        for song in songs {
            let destination = packageURL.appendingPathComponent(song.relativePath)
            if fm.fileExists(atPath: destination.path) {
                try OWSSongDocument.patchFile(at: destination, with: song.document)
            }
            // If the file doesn't exist, we can't create it without the heavy data — skip it
        }
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

    // MARK: - JSON Coders

    static func configuredEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func configuredDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
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
    var characters: [OPWCharacter] = []
    var isDirty: Bool = false
    var statusMessage: String = "No project loaded"
    var presentedLoadError: String?
    var projectHistoryEntries: [ProjectHistoryEntry] = []
    var gitHistoryEntries: [GitCommitEntry] = []

    // MARK: - Script UI State

    var selectedSongPath: String?
    var scrollTarget: String?
    var activeSongPath: String?
    var isLibrettoEditMode: Bool = UserDefaults.standard.object(forKey: "novotro.write.librettoEditMode") as? Bool ?? false {
        didSet { UserDefaults.standard.set(isLibrettoEditMode, forKey: "novotro.write.librettoEditMode") }
    }
    var showDirections: Bool = UserDefaults.standard.object(forKey: "showDirections") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showDirections, forKey: "showDirections"); saveProjectSettings() }
    }
    var showStoryboarding: Bool = UserDefaults.standard.object(forKey: "showStoryboarding") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showStoryboarding, forKey: "showStoryboarding"); saveProjectSettings() }
    }
    var showAnimateDirections: Bool = UserDefaults.standard.object(forKey: "showAnimateDirections") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showAnimateDirections, forKey: "showAnimateDirections"); saveProjectSettings() }
    }
    var directionMarkupColorHex: String = UserDefaults.standard.string(forKey: "novotro.write.directionMarkupColorHex") ?? ScriptMarkupPalette.defaultDirectionHex {
        didSet {
            let normalized = ScriptMarkupPalette.normalizedHex(directionMarkupColorHex) ?? ScriptMarkupPalette.defaultDirectionHex
            guard normalized == directionMarkupColorHex else {
                directionMarkupColorHex = normalized
                return
            }
            UserDefaults.standard.set(directionMarkupColorHex, forKey: "novotro.write.directionMarkupColorHex")
            saveProjectSettings()
        }
    }
    var storyboardingMarkupColorHex: String = UserDefaults.standard.string(forKey: "novotro.write.storyboardingMarkupColorHex") ?? ScriptMarkupPalette.defaultStoryboardingHex {
        didSet {
            let normalized = ScriptMarkupPalette.normalizedHex(storyboardingMarkupColorHex) ?? ScriptMarkupPalette.defaultStoryboardingHex
            guard normalized == storyboardingMarkupColorHex else {
                storyboardingMarkupColorHex = normalized
                return
            }
            UserDefaults.standard.set(storyboardingMarkupColorHex, forKey: "novotro.write.storyboardingMarkupColorHex")
            saveProjectSettings()
        }
    }
    var animateMarkupColorHex: String = UserDefaults.standard.string(forKey: "novotro.write.animateMarkupColorHex") ?? ScriptMarkupPalette.defaultAnimateHex {
        didSet {
            let normalized = ScriptMarkupPalette.normalizedHex(animateMarkupColorHex) ?? ScriptMarkupPalette.defaultAnimateHex
            guard normalized == animateMarkupColorHex else {
                animateMarkupColorHex = normalized
                return
            }
            UserDefaults.standard.set(animateMarkupColorHex, forKey: "novotro.write.animateMarkupColorHex")
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

    // MARK: - Synopsis State

    var synopsisText: String = ""
    var scratchpadFiles: [ProjectTextFile] = []
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
        novotroDebugLog("loadProject START url=\(url.path)")
        guard !isLoadingProject else {
            novotroDebugLog("loadProject SKIPPED: already loading")
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
            self.scratchpadFiles = []
            self.scratchpadDocumentText = ""
            self.isScratchpadDirty = false
            self.projectHistoryEntries = filteredProjectHistoryEntries(previousHistoryState.entries)
            self.hydratedScenePaths = loaded?.hydratedScenePaths ?? []

            // Persist last opened path
            UserDefaults.standard.set(url.path, forKey: "lastProjectPath")

            if isSwitchingProjects {
                selectedSongPath = nil
                scrollTarget = nil
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

            loadSynopsis(from: effectiveProjectURL)

            await loadScratchpad(from: effectiveProjectURL)

            // Ensure CLAUDE.md exists with synopsis instructions
            ensureClaudeMD(in: effectiveProjectURL)

            if !externallyChangedPaths.isEmpty {
                let changedSongPaths = externallyChangedPaths.filter {
                    $0 != OWPProjectIO.synopsisFile && $0 != ProjectDatabaseBridge.scratchpadPath
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

            isDirty = false
            refreshSaveIndicator()

            // Migrate legacy synopsis (Synopsis/synopsis.txt with {{{SCENE:...}}} markers)
            // into per-scene embedded {{{SYNOPSIS}}} blocks in each libretto file.
            migrateLegacySynopsisIfNeeded()

            statusMessage = "\(meta.name) - \(songAssets.count) songs loaded"
            persistProjectHistoryState()
            refreshGitHistory(for: url)
            loadProjectSettings()
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
                    if self.dirtySongPaths.isEmpty {
                        self.isDirty = false
                    }
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

    /// Migrate legacy Synopsis/synopsis.txt content (with {{{SCENE:path}}} markers)
    /// into per-scene embedded {{{SYNOPSIS}}} blocks within each libretto file.
    /// Only runs if the old synopsisText has scene markers AND no libretto files
    /// have embedded synopsis blocks yet.
    private func migrateLegacySynopsisIfNeeded() {
        guard !synopsisText.isEmpty else { return }

        // Check if any libretto already has embedded synopsis — skip if so
        let alreadyMigrated = librettoFiles.contains { SynopsisEmbedding.extract(from: $0.content).isEmpty == false }
        guard !alreadyMigrated else { return }

        // Parse the legacy format
        let sections = LegacySynopsisParser.parse(synopsisText)
        let availablePaths = librettoFiles.map(\.relativePath)
        var migrated = false

        for section in sections {
            guard let scenePath = section.scenePath else { continue }
            let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Resolve the scene path
            guard let resolvedPath = LegacySynopsisParser.resolvePath(
                scenePath,
                availablePaths: availablePaths
            ) else { continue }

            guard let idx = librettoFiles.firstIndex(where: { $0.relativePath == resolvedPath }) else { continue }
            let updated = SynopsisEmbedding.update(content: librettoFiles[idx].content, synopsis: text)
            librettoFiles[idx].content = updated
            migrated = true
        }

        if migrated {
            // Mark all migrated files dirty so they get saved
            for file in librettoFiles {
                if SynopsisEmbedding.extract(from: file.content).isEmpty == false {
                    markDirty(path: file.relativePath)
                }
            }
        }
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
        scrollTarget = relativePath
        ensureSceneHydrated(path: relativePath)
        return true
    }

    // MARK: - Add Scene

    func addScene() {
        guard let url = fileProjectURL else { return }
        let isStandalone = url.pathExtension.lowercased() == "ows"
        guard !isStandalone else { return }

        // Determine next scene number based on existing files
        let existingNumbers = songAssets.compactMap { asset -> Int? in
            let filename = URL(fileURLWithPath: asset.relativePath).deletingPathExtension().lastPathComponent
            let parts = filename.components(separatedBy: " ")
            return Int(parts.first ?? "")
        }
        let nextNumber = (existingNumbers.max() ?? 0) + 1
        let paddedNumber = String(format: "%02d", nextNumber)
        let filename = "\(paddedNumber) New Scene.ows"
        let relativePath = "\(OWPProjectIO.songsDir)/\(filename)"

        let versionID = UUID()
        let songID = UUID()
        let now = Date()

        let newDoc = OWSSongDocument(
            songID: songID,
            title: "\(paddedNumber) New Scene",
            canonicalTitle: "\(paddedNumber) new scene",
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

        // Write minimal .ows JSON file to disk
        let fileURL = url.appendingPathComponent(relativePath)
        let jsonDict: [String: Any] = [
            "songID": songID.uuidString,
            "title": newDoc.title,
            "canonicalTitle": newDoc.canonicalTitle,
            "notes": "",
            "updatedAt": OWSSongDocument.isoFormatter.string(from: now),
            "activeVersionID": versionID.uuidString,
            "versions": [[
                "id": versionID.uuidString,
                "label": "Initial",
                "createdAt": OWSSongDocument.isoFormatter.string(from: now),
                "updatedAt": OWSSongDocument.isoFormatter.string(from: now),
                "lyrics": "",
                "saveType": "manual",
                "isBookmarked": false,
            ] as [String: Any]],
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted, .sortedKeys])
            let songsDir = url.appendingPathComponent(OWPProjectIO.songsDir)
            try FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
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
        normalizeScratchpadFiles()

        scrollTarget = relativePath
        statusMessage = "Created \(filename)"
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

        // MARK: - Synopsis

    func loadSynopsis(from projectURL: URL) {
        let synopsisURL = projectURL.appendingPathComponent(OWPProjectIO.synopsisFile)
        if let data = try? Data(contentsOf: synopsisURL),
           let text = String(data: data, encoding: .utf8) {
            synopsisText = text
            if let snapshot = fileSnapshot(for: synopsisURL) {
                lastKnownModDates["__synopsis__"] = snapshot.modificationDate
                lastKnownFileSnapshots[OWPProjectIO.synopsisFile] = snapshot
            }
        } else {
            synopsisText = ""
        }
    }

    func refreshSynopsisFromProjectFile() {
        guard let url = fileProjectURL,
              url.pathExtension.lowercased() != "ows" else {
            return
        }

        let synopsisURL = url.appendingPathComponent(OWPProjectIO.synopsisFile)
        let nextText: String
        if let data = try? Data(contentsOf: synopsisURL),
           let text = String(data: data, encoding: .utf8) {
            nextText = text
        } else {
            nextText = ""
        }

        guard nextText != synopsisText else {
            if let snapshot = fileSnapshot(for: synopsisURL) {
                lastKnownModDates["__synopsis__"] = snapshot.modificationDate
                lastKnownFileSnapshots[OWPProjectIO.synopsisFile] = snapshot
            }
            return
        }

        synopsisText = nextText
        if let snapshot = fileSnapshot(for: synopsisURL) {
            lastKnownModDates["__synopsis__"] = snapshot.modificationDate
            lastKnownFileSnapshots[OWPProjectIO.synopsisFile] = snapshot
        }
    }

    func saveSynopsis() {
        guard let url = fileProjectURL else { return }
        let synopsisURL = url.appendingPathComponent(OWPProjectIO.synopsisFile)
        let dirURL = url.appendingPathComponent(OWPProjectIO.synopsisDir)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try synopsisText.write(to: synopsisURL, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "Failed to save synopsis: \(error.localizedDescription)"
        }
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

            All scene files, synopsis, metadata, and markup rules are documented there.
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
        - `Synopsis/synopsis.txt` — The project synopsis. A prose summary of the story.
        - `Metadata/project.json` — Project metadata.

        ## Synopsis

        The synopsis file at `Synopsis/synopsis.txt` is a thorough, multi-page prose summary of the entire story.

        **Scene markers:** The synopsis contains hidden navigation markers in the format:
        ```
        {{{SCENE:Songs/filename.ows}}}
        ```
        These markers appear on their own line before the synopsis text for that scene. They are used by the Write workspace \
        for navigation — clicking on a section of the synopsis jumps to the corresponding scene.

        **When you modify scenes:** After making changes to any scene's lyrics/libretto, you MUST update the synopsis \
        to reflect those changes. Regenerate or edit `Synopsis/synopsis.txt` to keep it in sync with the current script.

        When updating the synopsis:
        1. Read all scene files from `Songs/` in filename order
        2. Write a thorough prose synopsis capturing the full narrative
        3. Include a `{{{SCENE:Songs/filename.ows}}}` marker before each scene's section
        4. Save to `Synopsis/synopsis.txt`

        ## Scene Files (.ows)

        Each .ows file is JSON. The relevant fields for the libretto are:
        - `title` — Scene title
        - `versions` — Array of version objects, each with `lyrics` (the script text)
        - `activeVersionID` — Which version is current
        - `notes` — Scene-specific notes

        ## Markup Syntax in Lyrics

        Four bracket levels are used, each for a different purpose:

        1. **Direction markup** — double brackets: `[[1.01.0.001 - Description]]`
           Numbered storyboard directions with act.scene.subsection.direction addresses.

        2. **Narrative storyboarding** — single brackets: `[The mountains press in from all sides...]`
           Prose atmosphere/staging descriptions that add to the reading experience.

        3. **Animate instructions** — canonical single brackets: `[camera: zoom_in | from=wide | to=close | bars=17-24]`
           Technical instructions for Animate. Keywords include: scene, camera, enter, exit, move, emotion, action, gesture, object, object_move, object_state, object_visibility, lipsync, pause, sfx, transition.
           Legacy single-curly animate blocks may still appear in older files, but new authoring should use the canonical single-bracket Animate DSL.

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

        // Apply markup settings (project values override UserDefaults)
        if let v = settings.showDirections { showDirections = v }
        if let v = settings.showStoryboarding { showStoryboarding = v }
        if let v = settings.showAnimateDirections { showAnimateDirections = v }
        if let v = settings.directionMarkupColorHex { directionMarkupColorHex = v }
        if let v = settings.storyboardingMarkupColorHex { storyboardingMarkupColorHex = v }
        if let v = settings.animateMarkupColorHex { animateMarkupColorHex = v }

        // Apply LLM settings
        let config = LLMProviderConfig.shared
        if let provider = settings.llmProvider.flatMap({ LLMProviderType(rawValue: $0) }) {
            config.activeProvider = provider
        }
        if let key = settings.llmMiniMaxKey, !key.isEmpty {
            config.setAPIKey(key, for: .minimax)
        }
        if let key = settings.llmOpenCodeKey, !key.isEmpty {
            config.setAPIKey(key, for: .opencode)
        }
        if let model = settings.llmMiniMaxModel { config.setModelID(model, for: .minimax) }
        if let model = settings.llmOpenCodeModel { config.setModelID(model, for: .opencode) }
        if let model = settings.llmClaudeModel { config.setModelID(model, for: .claude) }
    }

    /// Save project-level settings to the OWP bundle.
    func saveProjectSettings() {
        guard let url = fileProjectURL else { return }
        let config = LLMProviderConfig.shared
        let settings = ProjectSettingsData(
            showDirections: showDirections,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections,
            directionMarkupColorHex: directionMarkupColorHex,
            storyboardingMarkupColorHex: storyboardingMarkupColorHex,
            animateMarkupColorHex: animateMarkupColorHex,
            llmProvider: config.activeProvider.rawValue,
            llmMiniMaxKey: config.apiKey(for: .minimax),
            llmOpenCodeKey: config.apiKey(for: .opencode),
            llmMiniMaxModel: config.modelID(for: .minimax),
            llmOpenCodeModel: config.modelID(for: .opencode),
            llmClaudeModel: config.modelID(for: .claude)
        )
        ProjectSettingsPersistence.save(settings, to: url)
    }

    func startFileWatching() {
        stopFileWatching()
        guard fileProjectURL != nil else { return }
        recordModDates()
        scheduleFileCheck()
    }

    func processExternalChangesNow() {
        checkForExternalChanges()
    }

    func stopFileWatching() {
        fileWatchWorkItem?.cancel()
        fileWatchWorkItem = nil
    }

    private func scheduleFileCheck() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.checkForExternalChanges()
            self.scheduleFileCheck()
        }
        fileWatchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalWatchInterval, execute: item)
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
        if projectURL.pathExtension.lowercased() != "ows" {
            let synopsisURL = projectURL.appendingPathComponent(OWPProjectIO.synopsisFile)
            if let snapshot = fileSnapshot(for: synopsisURL) {
                lastKnownModDates["__synopsis__"] = snapshot.modificationDate
                lastKnownFileSnapshots[OWPProjectIO.synopsisFile] = snapshot
            }
        }

        let scratchpadURL = scratchpadFileURL(for: projectURL)
        if let snapshot = fileSnapshot(for: scratchpadURL) {
            lastKnownModDates["__scratchpad__"] = snapshot.modificationDate
            lastKnownFileSnapshots[ProjectDatabaseBridge.scratchpadPath] = snapshot
        }
    }

    private func currentSongStubs(for projectURL: URL) -> [SongStub] {
        guard projectURL.pathExtension.lowercased() != "ows" else {
            return songStubs
        }
        return OWPProjectIO.enumerateSongStubs(in: projectURL.appendingPathComponent(OWPProjectIO.songsDir))
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

        hydratedScenePaths.formIntersection(currentPathSet)
        hydratingScenePaths.formIntersection(currentPathSet)
        dirtySongPaths.formIntersection(currentPathSet)

        if let selectedSongPath, !currentPathSet.contains(selectedSongPath) {
            self.selectedSongPath = songAssets.first?.relativePath
        }
        if let activeSongPath, !currentPathSet.contains(activeSongPath) {
            self.activeSongPath = songAssets.first?.relativePath
        }
        if let scrollTarget, !currentPathSet.contains(scrollTarget) {
            self.scrollTarget = nil
        }

        normalizeScratchpadFiles()
        resetTrackedFileSnapshots()
        isDirty = hasUnsavedChanges
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

        // Check synopsis file for external changes
        let synopsisURL = url.appendingPathComponent(OWPProjectIO.synopsisFile)
        if let snapshot = fileSnapshot(for: synopsisURL) {
            let lastKnown = lastKnownFileSnapshots[OWPProjectIO.synopsisFile]
            if lastKnown == nil {
                lastKnownModDates["__synopsis__"] = snapshot.modificationDate
                lastKnownFileSnapshots[OWPProjectIO.synopsisFile] = snapshot
            } else if snapshot != lastKnown! {
                lastKnownModDates["__synopsis__"] = snapshot.modificationDate
                lastKnownFileSnapshots[OWPProjectIO.synopsisFile] = snapshot
                if let data = try? Data(contentsOf: synopsisURL),
                   let text = String(data: data, encoding: .utf8),
                   text != synopsisText {
                    beginAgentSync()
                    synopsisText = text
                    appendProjectHistory(
                        kind: .externalReload,
                        title: "Reloaded synopsis from disk",
                        message: OWPProjectIO.synopsisFile,
                        relativePaths: [OWPProjectIO.synopsisFile]
                    )
                    refreshGitHistory()
                    markAgentUpdated()
                    statusMessage = "Synopsis reloaded (external change)"
                }
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
    }

    private func reloadExternallyChanged(stub: SongStub, modDate: Date) {
        let path = stub.relativePath
        beginAgentSync()

        // External change wins for this file.
        dirtySongPaths.remove(path)
        if dirtySongPaths.isEmpty {
            isDirty = false
        }

        // Update mod date immediately to avoid re-triggering
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

                if let idx = songAssets.firstIndex(where: { $0.relativePath == path }) {
                    songAssets[idx] = asset
                }

                if let version = asset.document.activeVersion(),
                   let libIdx = librettoFiles.firstIndex(where: { $0.relativePath == path }) {
                    librettoFiles[libIdx].content = version.lyrics
                }
                normalizeScratchpadFiles()

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
        isDirty = true
        dirtySongPaths.insert(path)
        refreshSaveIndicator()
        if status != "Unsaved changes" {
            statusMessage = status
        }
    }

    var hasUnsavedChanges: Bool {
        !dirtySongPaths.isEmpty || isScratchpadDirty
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

        isDirty = !dirtySongPaths.isEmpty
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

        if projectURL.pathExtension.lowercased() != "ows" {
            let synopsisURL = projectURL.appendingPathComponent(OWPProjectIO.synopsisFile)
            if let snapshot = fileSnapshot(for: synopsisURL) {
                snapshots[OWPProjectIO.synopsisFile] = snapshot
            }
        }

        let scratchpadURL = scratchpadFileURL(for: projectURL)
        if let snapshot = fileSnapshot(for: scratchpadURL) {
            snapshots[ProjectDatabaseBridge.scratchpadPath] = snapshot
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
        }

        hydratedScenePaths.insert(path)
        normalizeScratchpadFiles()
    }

    private func prioritizedHydrationPaths(
        primaryPath: String?,
        externallyChangedPaths: [String]
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for path in [primaryPath].compactMap({ $0 }) + externallyChangedPaths where seen.insert(path).inserted {
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
                isDirty = hasUnsavedChanges
                refreshSaveIndicator()
            }

            return true
        } catch {
            statusMessage = "Rename failed: \(error.localizedDescription)"
            return false
        }
    }
}
