#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@preconcurrency import AVFoundation
import Foundation
import NovotroProjectKit
import os
import UniformTypeIdentifiers

// MARK: - Debug Logging

private func novotroDebugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] [Score] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/novotro-debug.log")
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

// MARK: - Supporting Enums

enum InstrumentProfileScope: String, CaseIterable, Identifiable, Sendable {
    case selectedSong, allSongs
    var id: String { rawValue }
}

enum SongInsertPosition { case above, below }

// MARK: - Types Not in OPWModels

enum VersionSaveType: String, Codable, Sendable {
    case manual, autosave, snapshot, imported
}

struct TimeSignatureEvent: Codable, Hashable, Sendable {
    var tick: Int
    var numerator: Int
    var denominator: Int
}

struct KeySignatureEvent: Codable, Hashable, Sendable {
    var tick: Int
    var sharpsFlats: Int
    var isMinor: Bool
}

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    var id: UInt32
    var name: String
}

struct SF2Preset: Identifiable, Hashable, Sendable {
    var id: String { "\(bankMSB)-\(bankLSB)-\(program)" }
    var bankMSB: Int
    var bankLSB: Int
    var program: Int
    var name: String

    var displayName: String { "\(program): \(name)" }
    var bankDisplayName: String { "Bank \(bankMSB)/\(bankLSB)" }
}

struct SampleBrowserEntry: Identifiable, Hashable, Sendable {
    var id: String { relativePath }
    var relativePath: String
    var fileName: String
    var isDirectory: Bool
    var fileSize: Int64

    var path: String { relativePath }

    var displayName: String {
        (fileName as NSString).deletingPathExtension
    }

    var fileExtension: String {
        (fileName as NSString).pathExtension
    }
}

struct MixMarker: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var tick: Int
    var name: String
    var colorHex: String?
}

@available(macOS 26.0, *)
struct ChordMarker: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var tick: Int
    var name: String
}

private struct ExternalProjectFileSnapshot: Equatable, Sendable {
    let modificationDate: Date
    let fileSize: Int64
}

// MARK: - OWS Playback Snapshot (Codable for hybrid JSON loading)

struct OWSPlaybackSnapshot: Codable, Hashable {
    var notes: [PianoRollNote]
    var trackNames: [Int: String]
    var channelPrograms: [Int: Int]
    var trackChannelPrograms: [Int: [Int: Int]]
    var lyricCues: [LyricCue]
    var audioClips: [AudioClip]
    var tempoEvents: [TempoPoint]
    var ticksPerQuarter: Int
    var lengthTicks: Int
    var initialTempoBPM: Double
    var tempoMapSource: String?
    var timeSignatureEvents: [TimeSignatureEvent]?
    var keySignatureEvents: [KeySignatureEvent]?
    var lyricAlignments: [LyricAlignment]?
    var markers: [MixMarker]?
    var channelPan: [String: Double]?
    var automationData: PianoRollAutomationData?
    var scoreAnnotations: [ScoreAnnotation]?

    private enum CodingKeys: String, CodingKey {
        case notes, trackNames, channelPrograms, trackChannelPrograms
        case lyricCues, audioClips, tempoEvents, ticksPerQuarter, lengthTicks
        case initialTempoBPM, tempoMapSource, timeSignatureEvents, keySignatureEvents
        case lyricAlignments, markers, channelPan, automationData, scoreAnnotations
    }

    init(
        notes: [PianoRollNote] = [],
        trackNames: [Int: String] = [:],
        channelPrograms: [Int: Int] = [:],
        trackChannelPrograms: [Int: [Int: Int]] = [:],
        lyricCues: [LyricCue] = [],
        audioClips: [AudioClip] = [],
        tempoEvents: [TempoPoint] = [],
        ticksPerQuarter: Int = 480,
        lengthTicks: Int = 3840,
        initialTempoBPM: Double = 120,
        tempoMapSource: String? = nil,
        timeSignatureEvents: [TimeSignatureEvent]? = nil,
        keySignatureEvents: [KeySignatureEvent]? = nil,
        lyricAlignments: [LyricAlignment]? = nil,
        markers: [MixMarker]? = nil,
        channelPan: [String: Double]? = nil,
        automationData: PianoRollAutomationData? = nil,
        scoreAnnotations: [ScoreAnnotation]? = nil
    ) {
        self.notes = notes
        self.trackNames = trackNames
        self.channelPrograms = channelPrograms
        self.trackChannelPrograms = trackChannelPrograms
        self.lyricCues = lyricCues
        self.audioClips = audioClips
        self.tempoEvents = tempoEvents
        self.ticksPerQuarter = ticksPerQuarter
        self.lengthTicks = lengthTicks
        self.initialTempoBPM = initialTempoBPM
        self.tempoMapSource = tempoMapSource
        self.timeSignatureEvents = timeSignatureEvents
        self.keySignatureEvents = keySignatureEvents
        self.lyricAlignments = lyricAlignments
        self.markers = markers
        self.channelPan = channelPan
        self.automationData = automationData
        self.scoreAnnotations = scoreAnnotations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = try c.decodeIfPresent([PianoRollNote].self, forKey: .notes) ?? []
        trackNames = try c.decodeIfPresent([Int: String].self, forKey: .trackNames) ?? [:]
        channelPrograms = try c.decodeIfPresent([Int: Int].self, forKey: .channelPrograms) ?? [:]
        trackChannelPrograms = try c.decodeIfPresent([Int: [Int: Int]].self, forKey: .trackChannelPrograms) ?? [:]
        lyricCues = try c.decodeIfPresent([LyricCue].self, forKey: .lyricCues) ?? []
        audioClips = try c.decodeIfPresent([AudioClip].self, forKey: .audioClips) ?? []
        let rawTPQ = try c.decodeIfPresent(Int.self, forKey: .ticksPerQuarter) ?? 480
        ticksPerQuarter = max(1, rawTPQ)
        let rawLength = try c.decodeIfPresent(Int.self, forKey: .lengthTicks) ?? (ticksPerQuarter * 8)
        lengthTicks = min(max(rawLength, ticksPerQuarter * 8), 40_000_000)
        let rawTempo = try c.decodeIfPresent(Double.self, forKey: .initialTempoBPM) ?? 120
        initialTempoBPM = max(10, min(rawTempo, 500))
        var events = (try c.decodeIfPresent([TempoPoint].self, forKey: .tempoEvents) ?? [])
            .map { TempoPoint(tick: max(0, $0.tick), bpm: max(10, min($0.bpm, 500))) }
            .sorted { $0.tick < $1.tick }
        if events.isEmpty { events = [TempoPoint(tick: 0, bpm: initialTempoBPM)] }
        else if events[0].tick != 0 { events.insert(TempoPoint(tick: 0, bpm: events[0].bpm), at: 0) }
        tempoEvents = events
        tempoMapSource = try c.decodeIfPresent(String.self, forKey: .tempoMapSource)
        timeSignatureEvents = try c.decodeIfPresent([TimeSignatureEvent].self, forKey: .timeSignatureEvents)
        keySignatureEvents = try c.decodeIfPresent([KeySignatureEvent].self, forKey: .keySignatureEvents)
        lyricAlignments = try c.decodeIfPresent([LyricAlignment].self, forKey: .lyricAlignments)
        markers = try c.decodeIfPresent([MixMarker].self, forKey: .markers)
        channelPan = try c.decodeIfPresent([String: Double].self, forKey: .channelPan)
        automationData = try c.decodeIfPresent(PianoRollAutomationData.self, forKey: .automationData)
        scoreAnnotations = try c.decodeIfPresent([ScoreAnnotation].self, forKey: .scoreAnnotations)
    }
}

// MARK: - OWS Song Document (Novotro Score: loads music + lyrics via JSONSerialization)

struct OWSVersionPayload: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var label: String
    var createdAt: Date
    var updatedAt: Date
    var lyrics: String
    var saveType: VersionSaveType
    var userLabel: String?
    var isBookmarked: Bool
    var playback: OWSPlaybackSnapshot?

    var displayName: String {
        let baseName = userLabel ?? label
        switch saveType {
        case .autosave: return "\(baseName) - Autosave"
        default: return baseName
        }
    }
}

struct OWSSongDocument: Identifiable, Codable, @unchecked Sendable {
    var songID: UUID
    var title: String
    var canonicalTitle: String
    var notes: String
    var updatedAt: Date
    var activeVersionID: UUID?
    var versions: [OWSVersionPayload]
    var instrumentMappings: [String: InstrumentMapping]

    var id: UUID { songID }

    func activeVersion() -> OWSVersionPayload? {
        if let activeVersionID, let match = versions.first(where: { $0.id == activeVersionID }) {
            return match
        }
        return versions.first
    }

    mutating func normalize() {
        versions.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        if versions.isEmpty { activeVersionID = nil; return }
        if let activeVersionID, versions.contains(where: { $0.id == activeVersionID }) { return }
        activeVersionID = versions.first?.id
    }

    // MARK: - JSON Parsing Helpers

    private nonisolated(unsafe) static let iso8601Full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ value: Any?) -> Date {
        guard let str = value as? String else { return Date() }
        if let d = iso8601Full.date(from: str) { return d }
        return iso8601Basic.date(from: str) ?? Date()
    }

    static func parseUUID(_ value: Any?) -> UUID? {
        guard let str = value as? String else { return nil }
        return UUID(uuidString: str)
    }

    // MARK: - Load from OWS JSON (hybrid: JSONSerialization top-level, Codable for playback)

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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Parse instrument mappings from top-level
        var instrumentMappings: [String: InstrumentMapping] = [:]
        if let mappingsDict = root["instrumentMappings"] {
            if let mappingsData = try? JSONSerialization.data(withJSONObject: mappingsDict) {
                do {
                    instrumentMappings = try decoder.decode([String: InstrumentMapping].self, from: mappingsData)
                } catch {
                    NSLog("[OWS] Failed to decode instrument mappings: %@", error.localizedDescription)
                }
            }
        }

        // Parse versions with playback data
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

                // Decode playback snapshot via Codable (the heavy music data)
                var playback: OWSPlaybackSnapshot?
                if let playbackDict = vDict["playback"] {
                    if let playbackData = try? JSONSerialization.data(withJSONObject: playbackDict) {
                        do {
                            playback = try decoder.decode(OWSPlaybackSnapshot.self, from: playbackData)
                        } catch {
                            NSLog("[OWS] Failed to decode playback snapshot for version %@: %@", vID.uuidString, error.localizedDescription)
                        }
                    }
                }

                // Merge version-level instrument mappings
                if let vMappingsDict = vDict["instrumentMappings"] {
                    if let vMappingsData = try? JSONSerialization.data(withJSONObject: vMappingsDict),
                       let vDecoded = try? decoder.decode([String: InstrumentMapping].self, from: vMappingsData) {
                        for (k, v) in vDecoded { instrumentMappings[k] = v }
                    }
                }

                versions.append(OWSVersionPayload(
                    id: vID, label: label, createdAt: vCreatedAt, updatedAt: vUpdatedAt,
                    lyrics: lyrics, saveType: saveType, userLabel: userLabel,
                    isBookmarked: isBookmarked, playback: playback
                ))
            }
        }

        var doc = OWSSongDocument(
            songID: songID, title: title, canonicalTitle: canonicalTitle,
            notes: notes, updatedAt: updatedAt, activeVersionID: activeVersionID,
            versions: versions, instrumentMappings: instrumentMappings
        )
        doc.normalize()
        return doc
    }

    // MARK: - Patch File (surgical update: reads full JSON, patches changed fields, writes back)

    static func patchFile(at url: URL, with doc: OWSSongDocument, playback: OWSPlaybackSnapshot?) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OWSSongDocument", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot parse OWS for patching"])
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        root["title"] = doc.title
        root["canonicalTitle"] = doc.canonicalTitle
        root["notes"] = doc.notes
        root["updatedAt"] = iso8601Basic.string(from: doc.updatedAt)

        // Patch instrument mappings
        if !doc.instrumentMappings.isEmpty,
           let mappingsData = try? encoder.encode(doc.instrumentMappings),
           let mappingsObj = try? JSONSerialization.jsonObject(with: mappingsData) {
            root["instrumentMappings"] = mappingsObj
        }

        // Patch version lyrics and playback
        var versionArray = root["versions"] as? [[String: Any]] ?? []
        for docVersion in doc.versions {
            if let idx = versionArray.firstIndex(where: {
                ($0["id"] as? String) == docVersion.id.uuidString
            }) {
                // Update existing version
                versionArray[idx]["lyrics"] = docVersion.lyrics
                versionArray[idx]["updatedAt"] = iso8601Basic.string(from: docVersion.updatedAt)

                // Patch playback snapshot if provided and this is the active version
                if let playback, docVersion.id == doc.activeVersionID {
                    if let pbData = try? encoder.encode(playback),
                       let pbObj = try? JSONSerialization.jsonObject(with: pbData) {
                        versionArray[idx]["playback"] = pbObj
                    }
                }
            } else {
                // NEW version not yet on disk — serialize and append
                if let vData = try? encoder.encode(docVersion),
                   let vObj = try? JSONSerialization.jsonObject(with: vData) as? [String: Any] {
                    versionArray.insert(vObj, at: 0) // newest first
                }
            }
        }
        root["versions"] = versionArray

        let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try patched.write(to: url, options: .atomic)
    }
}

struct OWSSongAsset: Identifiable, @unchecked Sendable {
    var relativePath: String
    var document: OWSSongDocument

    var id: UUID { document.songID }

    var displayName: String {
        let trimmedTitle = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        let name = withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
        return name.toTitleCase()
    }
}

// MARK: - OWP Project I/O

enum OWPProjectIO {
    static let metadataDir = "Metadata"
    static let projectMetadataFile = "Metadata/project.json"
    static let projectInstrumentsFile = "Instruments.json"
    static let songsDir = "Songs"

    static func loadPhase1(from url: URL) async throws -> (metadata: ProjectMetadata, stubs: [SongStub], isStandalone: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }

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
            throw NSError(domain: "NovotroScore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid project: \(url.lastPathComponent)"])
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
        let enumerator = fm.enumerator(at: songsRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var stubs: [SongStub] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "ows" else { continue }
            let relativeWithinFolder = fileURL.path.replacingOccurrences(of: songsRoot.path + "/", with: "")
            let relativePath = "\(songsDir)/\(relativeWithinFolder)"
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            stubs.append(SongStub(id: UUID(), fileURL: fileURL, relativePath: relativePath, fileSize: size))
        }
        return stubs.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    nonisolated static func loadSongAsync(stub: SongStub) async throws -> OWSSongAsset {
        let data = try Data(contentsOf: stub.fileURL, options: .mappedIfSafe)
        let document = try OWSSongDocument.fromJSON(data: data)
        return OWSSongAsset(relativePath: stub.relativePath, document: document)
    }

    static func loadProjectInstrumentMappings(from packageURL: URL) -> [String: InstrumentMapping] {
        let fileURL = packageURL.appendingPathComponent(projectInstrumentsFile)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return [:] }

        let decoder = configuredDecoder()
        if let decoded = try? decoder.decode([String: InstrumentMapping].self, from: data) {
            return normalizeProjectInstrumentMappings(decoded)
        }
        if let decoded = try? decoder.decode([InstrumentMapping].self, from: data) {
            return normalizedProjectInstrumentMappings(decoded)
        }

        NSLog("[OWP] Failed to decode project instruments at %@", fileURL.path)
        return [:]
    }

    static func savePackage(
        packageURL: URL,
        metadata: ProjectMetadata,
        songs: [OWSSongAsset],
        playbackByPath: [String: OWSPlaybackSnapshot],
        projectInstrumentMappings: [String: InstrumentMapping]
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let metaDir = packageURL.appendingPathComponent(metadataDir)
        try fm.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let metaURL = packageURL.appendingPathComponent(projectMetadataFile)
        try configuredEncoder().encode(metadata).write(to: metaURL, options: .atomic)
        try saveProjectInstrumentMappings(to: packageURL, mappings: projectInstrumentMappings)

        for song in songs {
            let destination = packageURL.appendingPathComponent(song.relativePath)
            guard fm.fileExists(atPath: destination.path) else { continue }
            let playback = playbackByPath[song.relativePath]
            try OWSSongDocument.patchFile(at: destination, with: song.document, playback: playback)
        }

        writeCLAUDEmd(to: packageURL)
    }

    static func saveStandaloneSong(songURL: URL, song: OWSSongAsset, playback: OWSPlaybackSnapshot?) throws {
        try OWSSongDocument.patchFile(at: songURL, with: song.document, playback: playback)
    }

    static func saveProjectInstrumentMappings(to packageURL: URL, mappings: [String: InstrumentMapping]) throws {
        let normalized = normalizeProjectInstrumentMappings(mappings)
        let sorted = normalized.values.sorted { lhs, rhs in
            let lhsOrder = lhs.effectiveSortOrder
            let rhsOrder = rhs.effectiveSortOrder
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsName = lhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if lhsName != rhsName {
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
            return lhs.channelKey.localizedStandardCompare(rhs.channelKey) == .orderedAscending
        }
        let data = try configuredEncoder().encode(sorted)
        let fileURL = packageURL.appendingPathComponent(projectInstrumentsFile)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - SoundFont Embedding

    /// Copy an SF2 file into the OWP bundle's SoundFonts/ directory.
    /// Returns the relative path within the bundle. Deduplicates by filename.
    static func embedSoundFont(absolutePath: String, in owpBundleURL: URL) throws -> String {
        let sfDir = owpBundleURL.appendingPathComponent("SoundFonts")
        if !FileManager.default.fileExists(atPath: sfDir.path) {
            try FileManager.default.createDirectory(at: sfDir, withIntermediateDirectories: true)
        }

        let fileName = URL(fileURLWithPath: absolutePath).lastPathComponent
        let destURL = sfDir.appendingPathComponent(fileName)
        let relativePath = "SoundFonts/\(fileName)"

        // Skip if already embedded (dedup)
        if FileManager.default.fileExists(atPath: destURL.path) {
            return relativePath
        }

        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: absolutePath),
            to: destURL
        )
        return relativePath
    }

    /// Embed all SoundFont files referenced by instrument mappings into the OWP bundle.
    /// Returns updated mappings with sf2RelativePath set.
    static func embedSoundFonts(
        mappings: [String: InstrumentMapping],
        in owpBundleURL: URL
    ) -> [String: InstrumentMapping] {
        var updated = mappings
        for (key, mapping) in updated {
            guard let sf = mapping.soundFont else { continue }
            // Already has a relative path
            if sf.sf2RelativePath != nil { continue }
            // Try to get absolute path from resolvedPath or legacy sf2Path
            guard let absPath = sf.resolvedPath ?? mapping.sf2Path,
                  FileManager.default.fileExists(atPath: absPath) else { continue }
            do {
                let relativePath = try embedSoundFont(absolutePath: absPath, in: owpBundleURL)
                updated[key]?.soundFont?.sf2RelativePath = relativePath
            } catch {
                NSLog("[OWP] Failed to embed SF2 for %@: %@", key, error.localizedDescription)
            }
        }
        return updated
    }

    // MARK: - SoundFont Resolution

    /// Resolve embedded SoundFont paths in instrument mappings after loading an OWP bundle.
    /// Sets resolvedPath on each SoundFontAssignment from its sf2RelativePath.
    static func resolveSoundFonts(
        mappings: inout [String: InstrumentMapping],
        in owpBundleURL: URL
    ) {
        for (key, var mapping) in mappings {
            let relativePath = mapping.soundFont?.sf2RelativePath
                ?? {
                    guard let legacyPath = mapping.sf2Path?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !legacyPath.isEmpty,
                          !legacyPath.hasPrefix("/") else {
                        return nil
                    }
                    return legacyPath
                }()
            guard let relativePath else { continue }

            if mapping.soundFont == nil {
                mapping.soundFont = SoundFontAssignment(
                    sf2RelativePath: relativePath,
                    sf2FileName: mapping.sf2FileName ?? (relativePath as NSString).lastPathComponent,
                    resolvedPath: nil,
                    bankMSB: mapping.bankMSB,
                    bankLSB: mapping.bankLSB,
                    program: mapping.program
                )
            } else if mapping.soundFont?.sf2RelativePath == nil {
                mapping.soundFont?.sf2RelativePath = relativePath
            }

            let resolvedURL = owpBundleURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: resolvedURL.path) {
                mapping.soundFont?.resolvedPath = resolvedURL.path
                // Always hydrate the runtime path from the embedded bundle path so
                // playback works immediately after load while the saved document
                // still remains portable via sf2RelativePath.
                mapping.sf2Path = resolvedURL.path
                mapping.sf2FileName = resolvedURL.lastPathComponent
            } else if let fileName = mapping.soundFont?.sf2FileName ?? mapping.sf2FileName {
                // Fallback: search by filename in SoundFonts/
                let fallbackURL = owpBundleURL
                    .appendingPathComponent("SoundFonts")
                    .appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: fallbackURL.path) {
                    mapping.soundFont?.resolvedPath = fallbackURL.path
                    mapping.sf2Path = fallbackURL.path
                    mapping.sf2FileName = fallbackURL.lastPathComponent
                }
            }
            mappings[key] = mapping
        }
    }

    static func normalizeProjectInstrumentMappings(_ mappings: [String: InstrumentMapping]) -> [String: InstrumentMapping] {
        normalizedProjectInstrumentMappings(
            mappings.map { key, value in
                var mapping = value
                if mapping.channelKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mapping.channelKey = key
                }
                return mapping
            }
        )
    }

    private static func normalizedProjectInstrumentMappings(_ mappings: [InstrumentMapping]) -> [String: InstrumentMapping] {
        var normalized: [String: InstrumentMapping] = [:]
        for mapping in mappings {
            let baseKey = baseInstrumentChannelKey(from: mapping.channelKey, displayName: mapping.displayName)
            guard !baseKey.isEmpty else { continue }
            var canonical = mapping
            canonical.channelKey = baseKey
            canonical.songPath = nil
            if canonical.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                canonical.displayName = baseKey
            }

            if var existing = normalized[baseKey] {
                if existing.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !canonical.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    existing.displayName = canonical.displayName
                }
                if existing.trackRoleRaw == nil { existing.trackRoleRaw = canonical.trackRoleRaw }
                if existing.sortOrder == nil { existing.sortOrder = canonical.sortOrder }
                if existing.colorHex == nil { existing.colorHex = canonical.colorHex }
                if existing.builtInInstrumentID == nil { existing.builtInInstrumentID = canonical.builtInInstrumentID }
                if existing.sf2Path == nil { existing.sf2Path = canonical.sf2Path }
                if existing.sf2FileName == nil { existing.sf2FileName = canonical.sf2FileName }
                if existing.soundFont == nil { existing.soundFont = canonical.soundFont }
                if existing.audioUnit == nil { existing.audioUnit = canonical.audioUnit }
                if existing.auComponentType == nil { existing.auComponentType = canonical.auComponentType }
                if existing.auComponentSubType == nil { existing.auComponentSubType = canonical.auComponentSubType }
                if existing.auComponentManufacturer == nil { existing.auComponentManufacturer = canonical.auComponentManufacturer }
                if existing.auPresetData == nil { existing.auPresetData = canonical.auPresetData }
                if existing.instrumentSourceType == nil { existing.instrumentSourceType = canonical.instrumentSourceType }
                if existing.activeSource == .soundFont,
                   canonical.activeSource == .audioUnit,
                   existing.audioUnit == nil,
                   existing.auComponentType == nil {
                    existing.activeSource = canonical.activeSource
                }
                normalized[baseKey] = existing
            } else {
                normalized[baseKey] = canonical
            }
        }
        return normalized
    }

    private static func baseInstrumentChannelKey(from rawKey: String, displayName: String) -> String {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("song|"), let lastPipe = trimmed.lastIndex(of: "|") {
            let suffix = String(trimmed[trimmed.index(after: lastPipe)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty { return suffix }
        }
        if !trimmed.isEmpty { return trimmed }
        return normalizedDisplayNameAsChannelKey(displayName)
    }

    private static func normalizedDisplayNameAsChannelKey(_ displayName: String) -> String {
        let preprocessed = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\((copy|instance|alt|take)\s*\d*\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(copy|instance|alt|take)\s*\d*$"#, with: "", options: .regularExpression)

        let normalized = preprocessed
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)

        return normalized
    }

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

    // MARK: - CLAUDE.md Writer

    static func writeCLAUDEmd(to packageURL: URL) {
        let content = claudeMDContent
        let fileURL = packageURL.appendingPathComponent("CLAUDE.md")
        // Only write if content changed (avoid touching mtime unnecessarily)
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8), existing == content {
            return
        }
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static let claudeMDContent = """
    # Novotro Score Project

    This directory contains a Novotro Score project (.owp package). Novotro Score is a MIDI composition app with an embedded HTTP API and MCP (Model Context Protocol) bridge for AI agent integration.

    ## Connecting to Novotro Score

    The app runs an embedded HTTP API on `localhost:19847` whenever it is open. Use the MCP bridge for Claude Code integration — it auto-discovers via `.mcp.json` at the Novotro Score source root.

    ## MCP Tools Reference

    | Tool | Description | Key Parameters |
    |------|-------------|----------------|
    | `get_status` | App status, project info, selected song | — |
    | `list_songs` | All songs with metadata (note count, track count) | — |
    | `get_notes` | MIDI notes for selected song | `trackIndex`, `channel` (optional filters) |
    | `edit_notes` | Add, delete, update, or replace notes | `add`, `delete`, `update`, or `replaceAll` (use exactly one) |
    | `get_instruments` | Current instrument mappings and channel key map | — |
    | `set_instrument` | Change instrument for a mapping key | `mappingKey` (required), `sf2Path`, `program`, `bankMSB`, `bankLSB`, `gainDB`, `muted`, `displayName` |
    | `export_wav` | Render song to WAV file | `outputPath` (required), `startTick`, `endTick`, `overrideSF2Path` |
    | `export_suno_chunks` | Export Suno-format WAV chunks from split points | — |
    | `snapshot_version` | Create a version snapshot | `label` (optional) |
    | `rollback_version` | Restore a previous version | `versionID` (required, UUID) |
    | `get_versions` | List version history for selected song | — |
    | `playback_control` | Play, stop, or seek | `action` (required: play/stop/seek), `tick` (for play/seek) |

    ## HTTP API Endpoints

    Base URL: `http://localhost:19847`

    ### Read (GET)
    - `/api/status` — App status and selected song
    - `/api/songs` — List all songs
    - `/api/song/notes?trackIndex=N&channel=N` — MIDI notes (filters optional)
    - `/api/song/tracks` — Track list
    - `/api/song/instruments` — Instrument mappings
    - `/api/song/tempo` — Tempo map
    - `/api/song/lyrics` — Lyrics/text events
    - `/api/song/markers` — Marker events
    - `/api/song/audio-clips` — Audio clip references
    - `/api/song/suno-splits` — Suno split points
    - `/api/song/versions` — Version history
    - `/api/soundfonts` — Available soundfont files

    ### Write (POST, JSON body)
    - `/api/song/notes/add` — Add notes: `{"notes": [{"trackIndex":0, "channel":0, "pitch":60, "velocity":80, "startTick":0, "duration":480}]}`
    - `/api/song/notes/delete` — Delete notes: `{"ids": ["uuid1", "uuid2"]}`
    - `/api/song/notes/update` — Update notes: `{"notes": [{"id":"uuid", "pitch":62}]}`
    - `/api/song/notes/replace-all` — Replace all notes: `{"notes": [...]}`
    - `/api/song/tracks/rename` — Rename track: `{"trackIndex":0, "name":"Lead"}`
    - `/api/song/instruments/set` — Set instrument: `{"mappingKey":"tr0-ch0", "program":1}`
    - `/api/song/tempo/set` — Set tempo: `{"bpm":120}`
    - `/api/song/suno-splits/set` — Set Suno splits: `{"ticks":[1920, 3840]}`
    - `/api/song/select` — Select song: `{"id":"uuid"}`

    ### Actions (POST)
    - `/api/playback/play` — Start playback: `{"tick":0}` (optional)
    - `/api/playback/stop` — Stop playback
    - `/api/playback/seek` — Seek: `{"tick":960}`
    - `/api/export/wav` — Export WAV: `{"outputPath":"/path/to/out.wav"}`
    - `/api/export/suno-chunks` — Export Suno chunks
    - `/api/project/save` — Save project
    - `/api/project/open` — Open project: `{"path":"/path/to/project.owp"}`

    ### Versions (POST)
    - `/api/song/versions/snapshot` — Create snapshot: `{"label":"before edits"}`
    - `/api/song/versions/rollback` — Rollback: `{"versionID":"uuid"}`
    - `/api/song/versions/delete` — Delete version: `{"versionID":"uuid"}`
    - `/api/song/versions/rename` — Rename version: `{"versionID":"uuid", "label":"new name"}`

    ## Common Workflows

    ### Read and edit notes
    1. `get_status` → check which song is selected
    2. `get_notes` → read current notes (optionally filter by track/channel)
    3. `edit_notes` with `add`/`update`/`delete` → modify notes
    4. `snapshot_version` → save a checkpoint

    ### Change an instrument
    1. `get_instruments` → see current mappings and available keys
    2. `set_instrument` with `mappingKey` and desired `program`/`sf2Path`

    ### Export audio
    1. `export_wav` with `outputPath` → render to WAV
    2. Or `export_suno_chunks` → render split-based chunks for Suno

    ## File Structure

    - `Metadata/project.json` — Project metadata (name, tempo, time sig, etc.)
    - `Songs/*.ows` — Individual song files (JSON format, contain MIDI tracks/notes/events)
    - `CLAUDE.md` — This file (auto-generated, do not edit manually)
    """
}

// MARK: - ScoreStore

@available(macOS 26.0, *)
@MainActor
@Observable
final class ScoreStore {

    // MARK: - Project State

    var projectURL: URL?
    var workingProjectURL: URL?
    var metadata = ProjectMetadata.fresh(named: "Untitled")
    var songAssets: [OWSSongAsset] = []
    var songStubs: [SongStub] = []
    var isStandaloneSongWorkspace: Bool = false
    var librettoFiles: [ProjectTextFile] = []

    private var fileProjectURL: URL? {
        workingProjectURL ?? projectURL
    }

    // MARK: - Selection

    var selectedLibrettoID: ProjectTextFile.ID?
    var selectedMidiID: MidiAsset.ID?
    var selectedTrackFilter: Set<Int> = []
    var mutedTracks: Set<Int> = []
    var soloedTracks: Set<Int> = []

    // MARK: - Note Selection

    var selectedNoteIDs: Set<UUID> = []

    func selectAllNotes() {
        if selectedTrackFilter.isEmpty {
            selectedNoteIDs = Set(pianoRollNotes.map(\.id))
        } else {
            selectedNoteIDs = Set(pianoRollNotes.filter { selectedTrackFilter.contains($0.trackIndex) }.map(\.id))
        }
    }

    func deleteSelectedNotes() {
        guard !selectedNoteIDs.isEmpty else { return }
        pushUndoState(label: "Delete Notes")
        pianoRollNotes.removeAll { selectedNoteIDs.contains($0.id) }
        selectedNoteIDs.removeAll()
        isDirty = true
    }

    func quantizeSelectedNotes(gridTicks: Int? = nil) {
        let grid = gridTicks ?? (ticksPerQuarter / 4) // default: 16th note
        guard grid > 0 else { return }
        let ids = selectedNoteIDs.isEmpty ? Set(pianoRollNotes.map(\.id)) : selectedNoteIDs
        guard !ids.isEmpty else { return }
        pushUndoState(label: "Quantize")
        for i in pianoRollNotes.indices {
            guard ids.contains(pianoRollNotes[i].id) else { continue }
            let tick = pianoRollNotes[i].startTick
            let quantized = ((tick + grid / 2) / grid) * grid
            pianoRollNotes[i].startTick = max(0, quantized)
        }
        isDirty = true
    }

    // MARK: - Piano Roll Data

    var pianoRollNotes: [PianoRollNote] = []
    var pianoRollLyricCues: [LyricCue] = []
    var pianoRollLyricAlignments: [LyricAlignment] = []
    var pianoRollAudioClips: [AudioClip] = []
    var pianoRollTrackNames: [Int: String] = [:]
    var pianoRollChannelPrograms: [Int: Int] = [:]
    var pianoRollTrackChannelPrograms: [Int: [Int: Int]] = [:]
    var pianoRollChannelNames: [Int: String] = [:]
    var pianoRollChannelKeyByTrackChannel: [String: String] = [:]
    var ticksPerQuarter: Int = 480
    var pianoRollLengthTicks: Int = 3840
    var pianoRollTempoEvents: [TempoPoint] = [TempoPoint(tick: 0, bpm: 112)]
    var pianoRollTimeSignatures: [TimeSignatureEvent] = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
    var pianoRollKeySignatures: [KeySignatureEvent] = [KeySignatureEvent(tick: 0, sharpsFlats: 0, isMinor: false)]
    var pianoRollMarkers: [MixMarker] = []
    var scoreAnnotations: [ScoreAnnotation] = []
    var chordMarkers: [ChordMarker] = []
    var pianoRollAutomation: PianoRollAutomationData = PianoRollAutomationData()
    var pianoRollNoteGroups: [NoteGroup] = []
    var expressionMaps: [ExpressionMap] = [.orchestralDefault]
    var activeExpressionMapID: UUID? = ExpressionMap.orchestralDefault.id
    var pianoRollOverrides: [String: PianoRollOverride] = [:]

    // MARK: - Instrument Mappings

    var instrumentMappings: [String: InstrumentMapping] = [:]

    /// Master toggle: lightweight (SF2) vs heavyweight (AU) playback
    var masterInstrumentMode: InstrumentSourceType = .soundFont

    /// Toggle master instrument mode and update all unpinned mappings.
    func setMasterInstrumentMode(_ mode: InstrumentSourceType) {
        guard mode != masterInstrumentMode else { return }

        // Stop playback if active
        if isPlaying {
            stopPlayback()
        }

        masterInstrumentMode = mode
        InstrumentMapping.applyMasterToggle(to: &instrumentMappings, mode: mode)
        playbackEngine.reloadAllInstruments(mappings: instrumentMappings)
    }
    var projectChannelProfiles: [ProjectChannelProfile] = []
    var cueMappings: [CueMapping] = []

    // MARK: - Playback

    var tempoBPM: Double = 112
    var loopPlayback: Bool = false {
        didSet {
            if loopPlayback != oldValue {
                playbackEngine.setLoopEnabled(loopPlayback)
            }
        }
    }
    /// A/B loop region (nil = loop entire song). Both are tick positions.
    var loopRegionStart: Int? = nil
    var loopRegionEnd: Int? = nil

    /// Whether an A/B loop region is active.
    var hasLoopRegion: Bool { loopRegionStart != nil && loopRegionEnd != nil }

    /// Set the A/B loop region. Pass nil to clear.
    func setLoopRegion(start: Int?, end: Int?) {
        loopRegionStart = start
        loopRegionEnd = end
        // If currently looping, restart playback to apply the new region
        if loopPlayback && isPlaying {
            let tick = loopRegionStart ?? 0
            seekPlayback(to: tick)
        }
    }

    /// Practice tempo scale factor (0.25–2.0). Scales all tempo events during playback
    /// without modifying the stored tempo map. 1.0 = normal speed.
    var practiceTempoScale: Double = 1.0

    var continuousPlay: Bool = false
    var playbackRenderMode: PlaybackRenderMode = .midi
    var masterVolume: Double = 0.92
    var isPlaying: Bool = false
    var livePlayheadTick: Int = 0
    var liveTempoAtPlayhead: Double = 112

    // MARK: - Undo / Redo

    struct NoteSnapshot: Sendable {
        let notes: [PianoRollNote]
        let label: String
    }
    private var undoStack: [NoteSnapshot] = []
    private var redoStack: [NoteSnapshot] = []
    private let maxUndoLevels = 50
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Push the current note state onto the undo stack before a mutation.
    func pushUndoState(label: String = "Edit Notes") {
        undoStack.append(NoteSnapshot(notes: pianoRollNotes, label: label))
        if undoStack.count > maxUndoLevels { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(NoteSnapshot(notes: pianoRollNotes, label: snapshot.label))
        pianoRollNotes = snapshot.notes
        liveRecordingHeldNotes.removeAll()
        isDirty = true
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(NoteSnapshot(notes: pianoRollNotes, label: snapshot.label))
        pianoRollNotes = snapshot.notes
        isDirty = true
    }

    /// Discard the most recent undo entry (e.g., when a drag turned out to be a click).
    func popLastUndo() {
        _ = undoStack.popLast()
    }

    // MARK: - Freeze / Bounce

    var frozenTracks: [Int: URL] = [:]

    // MARK: - Audio Devices

    var audioOutputDevices: [AudioOutputDevice] = []
    var selectedAudioOutputID: UInt32?
    var audioBufferFrameOptions: [UInt32] = [128, 256, 512, 1024, 2048]
    var selectedAudioBufferFrames: UInt32 = 512

    // MARK: - Music Intelligence Engine

    var currentStructuralAnalysis: StructuralAnalysis?
    var smartAlignmentPreview: SmartAlignmentResult?
    var proposedMelodicMutation: MelodicMutation?
    var currentChordProgression: ChordProgressionResult?
    var currentHarmonization: HarmonizationResult?
    var generatedPart: GeneratedPart?
    var musicEngineStatus: String = ""

    // MARK: - Full Mix Export
    var isExportingFullMix: Bool = false
    var fullMixExportStatus: String = ""
    /// Export progress from 0.0 to 1.0 — updated during real-time render exports.
    var fullMixExportProgress: Double = 0

    // MARK: - Suno Export
    var sunoSplitTicks: [Int] = []
    var sunoExportProgress: Double = 0
    var sunoExportStatus: String = ""
    var isExportingSunoChunks: Bool = false
    var sunoSingleSFOverride: Bool = false
    var sunoSingleSFPath: String = ""      // relative path into sample library

    // MARK: - Suno API Integration (suno-mcp / Playwright)
    @ObservationIgnored let sunoClient = SunoAPIClient()
    @ObservationIgnored let sunoServerManager = SunoServerManager()

    // Bridging properties for SunoServerManager (which is @ObservationIgnored)
    var sunoServerState: SunoServerManager.ServerState = .stopped
    var sunoBootstrapStep: SunoServerManager.BootstrapStep?
    var sunoServerIsBootstrapped: Bool { sunoServerManager.isBootstrapped }
    var sunoServerIsBootstrapping: Bool { sunoBootstrapStep != nil && sunoBootstrapStep != .done }
    var sunoServerErrorMessage: String?
    var sunoLoginState: SunoServerManager.LoginState = .notLoggedIn

    var sunoRequestMode: SunoRequestMode = {
        let raw = UserDefaults.standard.string(forKey: "sunoRequestMode") ?? SunoRequestMode.cover.rawValue
        return SunoRequestMode(rawValue: raw) ?? .cover
    }() {
        didSet { UserDefaults.standard.set(sunoRequestMode.rawValue, forKey: "sunoRequestMode") }
    }
    var sunoCoverPreset: SunoCoverPreset = {
        let raw = UserDefaults.standard.string(forKey: "sunoCoverPreset") ?? SunoCoverPreset.orchestralInstrumental.rawValue
        return SunoCoverPreset(rawValue: raw) ?? .orchestralInstrumental
    }() {
        didSet { UserDefaults.standard.set(sunoCoverPreset.rawValue, forKey: "sunoCoverPreset") }
    }
    var sunoGenerations: [SunoGeneration] = []
    var sunoIsGenerating: Bool = false
    var sunoGenerateStatus: String = ""
    var sunoSongPrompt: String = UserDefaults.standard.string(forKey: "sunoSongPrompt") ?? "" {
        didSet { UserDefaults.standard.set(sunoSongPrompt, forKey: "sunoSongPrompt") }
    }
    var sunoBrowserOpen: Bool = false
    var sunoLoggedIn: Bool = false
    var sunoPreviewingGenerationID: UUID?
    private var sunoPreviewPlayer: AVAudioPlayer?

    // MARK: - Suno Pipeline State

    /// Current chunk plan (nil until user generates one)
    var activeChunkPlan: SunoChunkPlan?
    /// Active render session
    var activeRenderSession: SunoRenderSession?
    /// All completed render sessions
    var sunoRenderSessions: [SunoRenderSession] = []
    /// Generation config
    var sunoConfig = SunoChunkConfig()
    /// How Suno planning should split the song before rendering.
    var sunoSplitMode: SunoSplitMode = {
        let raw = UserDefaults.standard.string(forKey: "sunoSplitMode") ?? SunoSplitMode.structural.rawValue
        return SunoSplitMode(rawValue: raw) ?? .structural
    }() {
        didSet { UserDefaults.standard.set(sunoSplitMode.rawValue, forKey: "sunoSplitMode") }
    }
    /// Suno audio render layer (initialized lazily when first render completes)
    var sunoRenderLayer: SunoRenderLayer?
    /// Whether the chunk plan is stale (score edited after planning)
    var isChunkPlanStale: Bool = false
    /// Selected preset for the editable Suno style template.
    var sunoStylePreset: SunoStylePreset = {
        let raw = UserDefaults.standard.string(forKey: "sunoStylePreset") ?? SunoStylePreset.orchestraFidelity.rawValue
        return SunoStylePreset(rawValue: raw) ?? .orchestraFidelity
    }() {
        didSet { UserDefaults.standard.set(sunoStylePreset.rawValue, forKey: "sunoStylePreset") }
    }
    /// Global style template for Suno prompts (user-editable per song)
    var sunoStyleTemplate: String = UserDefaults.standard.string(forKey: "sunoStyleTemplate")
        ?? "orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies" {
        didSet {
            UserDefaults.standard.set(sunoStyleTemplate, forKey: "sunoStyleTemplate")
            syncSunoStylePresetFromTemplate()
        }
    }
    /// Default exclude styles for Suno Cover mode.
    var sunoExcludeStyles: String = UserDefaults.standard.string(forKey: "sunoExcludeStyles")
        ?? "-drums, -percussion, -cymbals, -snare, -kick" {
        didSet { UserDefaults.standard.set(sunoExcludeStyles, forKey: "sunoExcludeStyles") }
    }
    /// Default Suno Cover mode weirdness slider (0-100).
    var sunoCoverWeirdness: Int = {
        let stored = UserDefaults.standard.object(forKey: "sunoCoverWeirdness") as? Int
        return min(100, max(0, stored ?? 0))
    }() {
        didSet { UserDefaults.standard.set(sunoCoverWeirdness, forKey: "sunoCoverWeirdness") }
    }
    /// Default Suno Cover mode style influence slider (0-100).
    var sunoCoverStyleInfluence: Int = {
        let stored = UserDefaults.standard.object(forKey: "sunoCoverStyleInfluence") as? Int
        return min(100, max(0, stored ?? 30))
    }() {
        didSet { UserDefaults.standard.set(sunoCoverStyleInfluence, forKey: "sunoCoverStyleInfluence") }
    }
    /// Default Suno Cover mode audio influence slider (0-100).
    var sunoCoverAudioInfluence: Int = {
        let stored = UserDefaults.standard.object(forKey: "sunoCoverAudioInfluence") as? Int
        return min(100, max(0, stored ?? 95))
    }() {
        didSet { UserDefaults.standard.set(sunoCoverAudioInfluence, forKey: "sunoCoverAudioInfluence") }
    }

    var formattedSunoLyrics: String {
        SunoLyricsFormatter.format(
            librettoText: selectedLibrettoFile?.content,
            speakerGenderHints: sunoSpeakerGenderHints
        ).formattedText
    }

    var hasFormattedSunoLyrics: Bool {
        !formattedSunoLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedSunoGenerations: [SunoGeneration] {
        guard let selectedPath = selectedMidiAsset?.relativePath else { return [] }
        return sunoGenerations.filter { $0.songPath == selectedPath }
    }

    var sunoResolvedCoverPrompt: String {
        sunoCoverPreset.prompt
    }

    var sunoCoverRequiresLyrics: Bool {
        sunoCoverPreset.requiresLyrics
    }

    var sunoHasVocalTracks: Bool {
        instrumentMappings.values.contains { $0.trackRole == .vocal }
    }

    var sunoResolvedVocalGenderArgument: String {
        guard sunoCoverPreset.isVocal else { return "" }
        let genders = Set(
            instrumentMappings.values
                .filter { $0.trackRole == .vocal }
                .map { $0.resolvedVocalGender.rawValue }
        )
        guard genders.count == 1, let gender = genders.first else { return "" }
        return gender
    }

    var selectedSunoBaseTitle: String? {
        guard let relativePath = selectedMidiAsset?.relativePath else { return nil }
        return Self.sunoBaseTitle(from: relativePath)
    }

    private var sunoSpeakerGenderHints: [String: SunoLyricsFormatter.SpeakerGender] {
        var hints: [String: SunoLyricsFormatter.SpeakerGender] = [:]

        for mapping in instrumentMappings.values where mapping.trackRole == .vocal {
            let name = mapping.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let gender: SunoLyricsFormatter.SpeakerGender
            switch mapping.inferredVocalGender {
            case .male?:
                gender = .male
            case .female?:
                gender = .female
            case nil:
                gender = .unknown
            }

            let normalized = name
                .lowercased()
                .replacingOccurrences(of: #"[^\p{L}\p{N} ]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalized.isEmpty else { continue }
            hints[normalized] = gender

            if let firstToken = normalized.split(separator: " ").first {
                hints[String(firstToken)] = gender
            }
        }

        return hints
    }
    /// UI flag for prompt editor sheet
    var showInstrumentPromptEditor: Bool = false
    /// Suno pipeline status log (newest first, capped at 100 entries)
    var sunoStatusLog: [SunoLogEntry] = []

    struct SunoLogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        let level: Level
        enum Level: String { case info, warning, error, success }
    }

    func appendSunoLog(_ message: String, level: SunoLogEntry.Level = .info) {
        sunoStatusLog.insert(SunoLogEntry(message: message, level: level), at: 0)
        if sunoStatusLog.count > 100 { sunoStatusLog.removeLast(sunoStatusLog.count - 100) }
    }

    // MARK: - API Server

    @ObservationIgnored private(set) var apiServer: APIServer?
    var apiServerEnabled: Bool = true
    var apiServerPort: UInt16 = 19847
    @ObservationIgnored private var lastAutoSnapshotDate: Date?
    private static let autoSnapshotCooldown: TimeInterval = 300  // 5 minutes

    func startAPIServer() {
        novotroDebugLog("startAPIServer: enabled=\(apiServerEnabled) existing=\(apiServer != nil) port=\(apiServerPort)")
        guard apiServerEnabled, apiServer == nil else { return }
        do {
            let server = try APIServer(store: self, port: apiServerPort)
            server.logHandler = { method, path, status, _ in
                NSLog("[APIServer] %@ %@ → %d", method, path, status)
            }
            server.start()
            apiServer = server
            novotroDebugLog("startAPIServer: OK on port \(apiServerPort)")
        } catch {
            novotroDebugLog("startAPIServer: FAILED — \(error.localizedDescription)")
            statusMessage = "API server failed to start: \(error.localizedDescription)"
        }
    }

    func stopAPIServer() {
        apiServer?.stop()
        apiServer = nil
    }

    // MARK: - LLM

    #if canImport(MLXLLM)
    private var _llmClient: Any?
    var llmResponse: String = ""
    var llmGenerating: Bool = false

    var preferredLLMModelID: String {
        get { UserDefaults.standard.string(forKey: "preferredLLMModelID") ?? "mlx-community/Llama-3.2-3B-Instruct-4bit" }
        set { UserDefaults.standard.set(newValue, forKey: "preferredLLMModelID") }
    }

    @available(macOS 26.0, *)
    var llmClient: LLMClient {
        if let existing = _llmClient as? LLMClient { return existing }
        let client = LLMClient()
        _llmClient = client
        return client
    }
    #endif

    // MARK: - Style & Composition

    var detectedStyle: MusicalStyleProfile?
    var composedMelody: [PianoRollNote]?
    var leitmotifs: [Leitmotif] = []

    // MARK: - MidiAI

    var isMidiAIGenerating: Bool = false
    var midiAIStatusMessage: String = ""
    var midiAIServerURL: String {
        get { UserDefaults.standard.string(forKey: "midiAIServerURL") ?? "http://127.0.0.1:8421" }
        set { UserDefaults.standard.set(newValue, forKey: "midiAIServerURL") }
    }

    // MARK: - MIDI Input

    var midiInputRecordEnabled = false
    var midiInputStepMode = false
    var midiInputMonitorEnabled = false
    var stepInputTick: Int = 0
    var stepInputDuration: Int = 480
    var stepInputTrackIndex: Int = 0
    var stepInputChannel: Int = 0
    @ObservationIgnored var midiInputManager = MIDIInputManager()

    // MARK: - Track Reordering

    func reorderTrack(from sourceKey: String, before targetKey: String) {
        let sorted = instrumentMappings.keys.sorted { lhs, rhs in
            let lo = instrumentMappings[lhs]?.sortOrder ?? Int.max
            let ro = instrumentMappings[rhs]?.sortOrder ?? Int.max
            if lo != ro { return lo < ro }
            return lhs < rhs
        }
        var order = sorted
        order.removeAll { $0 == sourceKey }
        if let idx = order.firstIndex(of: targetKey) {
            order.insert(sourceKey, at: idx)
        } else {
            order.append(sourceKey)
        }
        for (i, key) in order.enumerated() {
            instrumentMappings[key]?.sortOrder = i
        }
        isDirty = true
    }

    // MARK: - Per-channel Pan

    var channelPan: [String: Double] = [:]

    func setChannelPan(key: String, pan: Double) {
        let clamped = min(max(pan, -1), 1)
        channelPan[key] = clamped
        playbackEngine.setSamplerPan(mappingKey: key, pan: clamped)
        // Record automation if armed for pan on this channel
        if automationRecordArmed && automationRecordChannelKey == key && automationRecordLaneType == .cc10Pan {
            recordAutomationPoint(value: (clamped + 1) / 2) // map -1..1 to 0..1
        }
    }

    // MARK: - Metering

    var masterMeterLevels: MeterLevels = .zero
    var trackMeterLevels: [UUID: MeterLevels] = [:]

    // MARK: - Automation Recording

    /// When true, fader/pan changes during playback are recorded as automation points.
    var automationRecordArmed = false
    /// The channel key currently armed for automation recording.
    var automationRecordChannelKey: String?
    /// The automation lane type being recorded.
    var automationRecordLaneType: AutomationLaneType = .cc7Volume

    /// Record a single automation point at the current playhead position.
    func recordAutomationPoint(value: Double) {
        guard automationRecordArmed, isPlaying,
              let _ = automationRecordChannelKey else { return }
        let tick = livePlayheadTick
        let point = PianoRollAutoPoint(tick: tick, value: value)
        var data = pianoRollAutomation
        var points = data.points(for: automationRecordLaneType)
        // Remove any existing points within ±10 ticks to avoid duplicates
        points.removeAll { abs($0.tick - tick) < 10 }
        points.append(point)
        data.setPoints(points, for: automationRecordLaneType)
        pianoRollAutomation = data
        isDirty = true
    }

    // MARK: - SoundFont Cache

    var sf2PresetCache: [String: [SF2Preset]] = [:]

    // MARK: - Sample Browser

    var sampleRootDirectoryPath: String = ""
    var sampleBrowserEntries: [SampleBrowserEntry] = []
    var isScanningSampleBrowser: Bool = false

    // MARK: - Audio Unit Discovery

    @ObservationIgnored lazy var audioUnitManager = AudioUnitManager()

    // MARK: - Status & Dirty

    var statusMessage: String = "Open a local OWP/OWS project to begin."
    var isDirty: Bool = false {
        didSet {
            if isDirty {
                changeGeneration &+= 1
                if saveIndicator != .saving {
                    saveIndicator = .unsavedChanges
                }
                scheduleAutoSaveIfNeeded()
                scheduleDatabaseSyncIfNeeded()
            } else if saveIndicator != .saving {
                saveIndicator = projectURL == nil ? .idle : .saved
            }
        }
    }

    var autoSaveEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(false, forKey: "autoSaveEnabled")
            autoSaveWorkItem?.cancel()
            autoSaveWorkItem = nil
        }
    }

    var saveIndicator: SaveIndicatorState = .idle
    var toolbarAvailableWidth: CGFloat = 0
    var showInspector: Bool = true
    var externalChangeTimes: [String: Date] = [:]
    var isAgentSyncInProgress: Bool = false
    var hasPendingAgentChanges: Bool = false
    var showsRecentAgentUpdate: Bool = false

    var collaborationBadgeLabel: String? {
        if isAgentSyncInProgress {
            return "Agent Syncing"
        }
        if hasPendingAgentChanges {
            return "Agent Changes Waiting"
        }
        if showsRecentAgentUpdate {
            return "Agent Updated"
        }
        return nil
    }

    var collaborationBadgeSystemImage: String {
        if hasPendingAgentChanges {
            return "exclamationmark.arrow.triangle.2.circlepath"
        }
        return showsRecentAgentUpdate ? "sparkles" : "arrow.triangle.2.circlepath"
    }

    // MARK: - Derived

    var activeExpressionMap: ExpressionMap? {
        expressionMaps.first { $0.id == activeExpressionMapID }
    }

    var midiAssets: [MidiAsset] {
        songAssets.map {
            MidiAsset(id: $0.id, relativePath: $0.relativePath, data: Data(), title: $0.document.title)
        }
    }

    var selectedMidiAsset: MidiAsset? {
        guard let selectedMidiID else { return nil }
        return midiAssets.first { $0.id == selectedMidiID }
    }

    var selectedLibrettoFile: ProjectTextFile? {
        guard let selectedLibrettoID else { return nil }
        return librettoFiles.first { $0.id == selectedLibrettoID }
    }

    private(set) var changeGeneration: UInt64 = 0

    private var _cachedAvailableTrackIndices: [Int]?
    private var _trackIndicesGeneration: UInt64 = UInt64.max

    var availableTrackIndices: [Int] {
        if let cached = _cachedAvailableTrackIndices, _trackIndicesGeneration == changeGeneration {
            return cached
        }
        var indices = Set(pianoRollNotes.map(\.trackIndex))
        indices.formUnion(pianoRollTrackNames.keys)
        indices.formUnion(pianoRollTrackChannelPrograms.keys)
        for pairKey in pianoRollChannelKeyByTrackChannel.keys {
            let pieces = pairKey.split(separator: ":")
            if pieces.count == 2, let trackIndex = Int(pieces[0]) { indices.insert(trackIndex) }
        }
        let result = indices.sorted()
        _cachedAvailableTrackIndices = result
        _trackIndicesGeneration = changeGeneration
        return result
    }

    // MARK: - Playback Engine

    private(set) var playbackEngine = MIDIPlaybackEngine()
    var playbackPositionInBeats: Double { playbackEngine.currentPositionInBeats }

    // MARK: - Auto-Save

    private var autoSaveWorkItem: DispatchWorkItem?
    private static let autoSaveCooldown: TimeInterval = 18
    private static let databaseWatchInterval: TimeInterval = 0.45
    private static let externalWatchInterval: TimeInterval = 0.55
    private var dirtySongPaths: Set<String> = []
    private var isSavingInternal: Bool = false
    private var lastSelectedMidiID: UUID?
    private var loadedMidiCache: [UUID: ParsedPianoRoll] = [:]
    private var projectDatabase: NovotroProjectConnection?
    private var databaseWatchWorkItem: DispatchWorkItem?
    private var databaseChangeToken: Int64 = 0
    private var pendingDatabaseSongSyncs: [String: DispatchWorkItem] = [:]
    private var suppressDatabaseSyncPaths: Set<String> = []
    private var backgroundIndexRefreshTask: Task<Void, Never>?
    private var hydratedSongPaths: Set<String> = []
    private var pendingPlaybackStartTask: Task<Void, Never>?
    private var externalFileWatchWorkItem: DispatchWorkItem?
    private var lastKnownExternalSnapshots: [String: ExternalProjectFileSnapshot] = [:]
    private static let autoSaveDefaultsKey = "autoSaveEnabled"

    // MARK: - Lyric Alignment Computed Properties

    var lyricAlignmentWordIndices: Set<Int> {
        guard let songPath = selectedMidiAsset?.relativePath else { return [] }
        var result = Set<Int>()
        for alignment in pianoRollLyricAlignments where alignment.songPath == songPath {
            for entry in alignment.entries { result.insert(entry.wordIndex) }
        }
        return result
    }

    var lyricAlignmentCoverage: Double {
        guard !pianoRollNotes.isEmpty else { return 0 }
        guard let songPath = selectedMidiAsset?.relativePath else { return 0 }
        let alignedNoteIDs = Set(pianoRollLyricAlignments.filter { $0.songPath == songPath }.flatMap { $0.entries.map(\.noteID) })
        return Double(alignedNoteIDs.count) / Double(pianoRollNotes.count)
    }

    var lyricAlignmentCount: Int {
        guard let songPath = selectedMidiAsset?.relativePath else { return 0 }
        return pianoRollLyricAlignments.filter { $0.songPath == songPath }.reduce(0) { $0 + $1.entries.count }
    }

    // Parsed lyric lines from the selected song's libretto
    var parsedLyricLines: [(tick: Int, line: String, lineIndex: Int)] {
        guard let file = selectedLibrettoFile else { return [] }
        // Only return lines that have embedded [t:TICK] positioning tags.
        // Lines without tags have no meaningful tick position and would all
        // render at x=0 (crammed against the left edge).
        return file.content.components(separatedBy: .newlines).enumerated().compactMap { idx, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            // Parse [t:TICK] tag if present
            if let range = trimmed.range(of: #"\[t:(\d+)\]"#, options: .regularExpression),
               let tickStr = trimmed[range].split(separator: ":").last?.dropLast(),
               let tick = Int(tickStr) {
                let text = trimmed.replacingOccurrences(of: #"\[t:\d+\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return (tick: tick, line: text, lineIndex: idx)
            }
            return nil  // No tick tag — don't display in the lane
        }
    }

    // MARK: - Init

    init() {
        autoSaveEnabled = false
        UserDefaults.standard.set(false, forKey: Self.autoSaveDefaultsKey)
        setupPlaybackCallbacks()
        sunoServerManager.onStateChange = { [weak self] state, step, error in
            self?.sunoServerState = state
            self?.sunoBootstrapStep = step
            self?.sunoServerErrorMessage = error
        }
        sunoServerManager.onLoginStateChange = { [weak self] loginState in
            self?.sunoLoginState = loginState
            if loginState == .loggedIn {
                self?.sunoLoggedIn = true
            }
        }
        setupAppTerminationHandler()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            self.setupMIDIInput()
            self.sunoServerManager.checkExistingLogin()
            self.sunoServerManager.autoStartIfNeeded()
            await self.audioUnitManager.scanInstalledAudioUnits()
        }
    }

    private func setupMIDIInput() {
        midiInputManager.onNote = { [weak self] pitch, velocity, channel in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handleMIDINoteInput(pitch: pitch, velocity: velocity, channel: channel)
            }
        }
        midiInputManager.connectToAll()
    }

    /// Timestamp of last step-record undo push (for batching chords)
    private var lastStepUndoPushTime: Date = .distantPast
    /// Live recording state: notes currently held (pitch -> start info)
    private var liveRecordingHeldNotes: [Int: (startTick: Int, velocity: Int)] = [:]
    /// Whether live (real-time) MIDI recording is active
    var midiInputLiveRecord = false

    /// Handle incoming MIDI note for step/live recording or preview
    private func handleMIDINoteInput(pitch: Int, velocity: Int, channel: Int) {
        // Live recording: note-off completes the note
        if midiInputLiveRecord && isPlaying {
            if velocity == 0 {
                // Note off — complete held note
                if let held = liveRecordingHeldNotes.removeValue(forKey: pitch) {
                    let endTick = livePlayheadTick
                    let duration = max(1, endTick - held.startTick)
                    let note = PianoRollNote(
                        trackIndex: stepInputTrackIndex,
                        channel: stepInputChannel,
                        pitch: pitch,
                        velocity: held.velocity,
                        startTick: held.startTick,
                        duration: duration
                    )
                    pianoRollNotes.append(note)
                    isDirty = true
                }
                return
            } else {
                // Note on — start holding
                if liveRecordingHeldNotes.isEmpty {
                    pushUndoState(label: "Live Record")
                }
                liveRecordingHeldNotes[pitch] = (startTick: livePlayheadTick, velocity: velocity)
                // Preview the note
                if midiInputMonitorEnabled {
                    playbackEngine.previewNote(pitch: pitch, velocity: velocity)
                }
                return
            }
        }

        guard velocity > 0 else { return } // ignore note-off outside live record

        // Always preview the note
        if midiInputMonitorEnabled {
            playbackEngine.previewNote(pitch: pitch, velocity: velocity)
        }

        // Step record mode: insert note at cursor and advance
        guard midiInputRecordEnabled, midiInputStepMode else { return }

        // Batch chord notes (within 50ms) into a single undo entry
        let now = Date()
        if now.timeIntervalSince(lastStepUndoPushTime) > 0.05 {
            pushUndoState(label: "Step Input")
            lastStepUndoPushTime = now
        }

        let note = PianoRollNote(
            trackIndex: stepInputTrackIndex,
            channel: stepInputChannel,
            pitch: pitch,
            velocity: velocity,
            startTick: stepInputTick,
            duration: stepInputDuration
        )
        pianoRollNotes.append(note)
        // Only advance cursor after a gap (next note outside chord window will advance)
        // For now, advance on every note — chord handling requires a timer-based approach
        stepInputTick += stepInputDuration
        isDirty = true
    }

    /// Stop the Suno server when the app terminates to prevent orphaned processes.
    private var terminationObserver: (any NSObjectProtocol)?

    private func setupAppTerminationHandler() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Must run synchronously — Task won't complete before process exits.
            // queue: .main guarantees we're on main thread, so assumeIsolated is safe.
            MainActor.assumeIsolated {
                self?.sunoServerManager.stop()
                self?.stopAPIServer()
            }
        }
    }

    private func setupPlaybackCallbacks() {
        playbackEngine.onPlaybackStateChange = { [weak self] playing in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = playing
                NSLog("[ScoreStore] onPlaybackStateChange: playing=%d wasPlaying=%d userInitiatedStop=%d pendingAdvance=%d continuousPlay=%d",
                      playing ? 1 : 0, wasPlaying ? 1 : 0, self.userInitiatedStop ? 1 : 0, self.pendingAdvance ? 1 : 0, self.continuousPlay ? 1 : 0)
                if playing {
                    // Song actually started playing — clear transition flags so natural end
                    // of THIS song triggers the next advance correctly. Without this, if the
                    // engine was already stopped when transition started (so the internal
                    // stopOnAudioQueue never fired setPlaying(false) to clear userInitiatedStop),
                    // the flag would remain true through the song and block the natural-end advance.
                    self.userInitiatedStop = false
                    self.pendingAdvanceWorkItem = nil
                    self.pendingAdvance = false
                }
                if wasPlaying && !playing {
                    if self.userInitiatedStop {
                        // User pressed stop — do NOT advance to next song
                        self.userInitiatedStop = false
                    } else if self.continuousPlay && !self.pendingAdvance {
                        // Natural end of playback — advance to next song.
                        // Guard pendingAdvance: stopOnAudioQueue(keepReconfiguring:true) inside
                        // playOnAudioQueue fires setPlaying(false) during transition setup when
                        // the engine was already playing. Without this guard that callback
                        // re-enters here and triggers a double-advance (double-start bug).
                        self.advanceToNextSongAndPlay()
                    }
                }
            }
        }
        playbackEngine.onPlaybackError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.statusMessage = message
            }
        }
        playbackEngine.onAUDisconnected = { [weak self] mappingKey in
            Task { @MainActor [weak self] in
                guard let self,
                      let mapping = self.instrumentMappings[mappingKey],
                      mapping.audioComponentDescription != nil else { return }
                NSLog("[ScoreStore] Auto-reloading crashed AU for '%@'", mappingKey)
                // Clear the patch signature so loadAudioUnitIfNeeded will reload
                self.playbackEngine.reloadAudioUnit(for: mappingKey, mapping: mapping)
            }
        }
        playbackEngine.onMeterUpdate = { [weak self] trackLevels, masterLevel in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackMeterLevels = trackLevels
                self.masterMeterLevels = masterLevel
            }
        }
        playbackEngine.onNeedsPlaybackRestart = { [weak self] savedBeats in
            Task { @MainActor [weak self] in
                guard let self else { return }
                NSLog("[ScoreStore] onNeedsPlaybackRestart: isPlaying=%d pendingAdvance=%d beat=%.2f",
                      self.isPlaying ? 1 : 0, self.pendingAdvance ? 1 : 0, savedBeats)
                // Guard: if playback already stopped (e.g. natural song end raced with
                // AVAudioEngineConfigurationChange), do not restart — we're not playing.
                // Also skip if advanceToNextSongAndPlay already has a playPianoRoll call
                // scheduled — the pending advance will start the next song momentarily.
                guard self.isPlaying, !self.pendingAdvance else {
                    // Clear isReconfiguring so the health-check timer isn't permanently suppressed
                    self.playbackEngine.clearReconfiguring()
                    return
                }
                let tick = Int(savedBeats * Double(self.ticksPerQuarter))
                NSLog("[ScoreStore] Restarting playback after engine interruption at tick %d", tick)
                // Set userInitiatedStop so the internal stopOnAudioQueue() inside
                // playOnAudioQueue() doesn't trigger a continuous-play advance when
                // it calls setPlaying(false) during setup.
                self.userInitiatedStop = true
                self.playPianoRoll(startTick: tick)
            }
        }
    }

    /// Advance to the next song in the list and start playback. Wraps to the first song.
    private func advanceToNextSongAndPlay() {
        NSLog("[ScoreStore] advanceToNextSongAndPlay called — song=%@ userInitiatedStop=%d isPlaying=%d",
              selectedMidiAsset?.relativePath ?? "nil", userInitiatedStop ? 1 : 0, isPlaying ? 1 : 0)
        let assets = midiAssets
        guard !assets.isEmpty else { return }
        guard let current = selectedMidiID,
              let idx = assets.firstIndex(where: { $0.id == current }) else { return }

        let nextIdx = (idx + 1) % assets.count
        let nextSong = assets[nextIdx]
        setSelectedMidi(id: nextSong.id, stopPlaybackBeforeSelect: false)
        // setSelectedMidi calls stopPlayback() which sets userInitiatedStop=true.
        // But the engine was already stopped (end-of-song work item fired), so
        // stopOnAudioQueue's guard prevents the state-change callback from firing,
        // leaving userInitiatedStop stuck as true. setSelectedMidi clears it when
        // engine is not playing, so continuous play works for the next song too.
        userInitiatedStop = false

        // Block onNeedsPlaybackRestart from firing during the 0.3s window between
        // song selection and the scheduled playPianoRoll call. Without this guard,
        // the optimistic isPlaying=true below causes onNeedsPlaybackRestart (which
        // checks self.isPlaying) to call playPianoRoll() a second time ~120ms early,
        // producing a double-start that causes the second song to play silently.
        pendingAdvanceWorkItem?.cancel()
        pendingAdvance = true
        NSLog("[ScoreStore] pendingAdvance=true set for %@", nextSong.relativePath)

        // Set isPlaying optimistically so the UI doesn't flash "stopped" during the
        // brief delay before the engine starts the next song.
        isPlaying = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingAdvance, self.selectedMidiID == nextSong.id else { return }
            self.pendingAdvanceWorkItem = nil
            // pendingAdvance stays true until setPlaying(true) fires for the new song.
            // This guards against:
            // 1. Spurious double-advance from stopOnAudioQueue(kR:true) firing setPlaying(false)
            //    during transition setup (when engine was already playing).
            // 2. onNeedsPlaybackRestart racing with the pending playPianoRoll call.
            // Both clear when onPlaybackStateChange(playing=true) fires.
            NSLog("[ScoreStore] asyncAfter fired: calling playPianoRoll (pendingAdvance clears on start)")
            self.playPianoRoll(cancelPendingAdvance: false)
        }
        pendingAdvanceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Load Project

    func loadProject(url: URL, preferService: Bool? = nil) async {
        novotroDebugLog("loadProject START url=\(url.path)")
        statusMessage = "Loading \(url.lastPathComponent)..."
        saveIndicator = .idle
        backgroundIndexRefreshTask?.cancel()
        stopExternalFileWatch()
        loadedMidiCache.removeAll()
        sf2PresetCache.removeAll()
        pianoRollOverrides.removeAll()
        instrumentMappings.removeAll()
        dirtySongPaths.removeAll()
        lastSelectedMidiID = nil
        hydratedSongPaths.removeAll()
        cancelPendingPlaybackStart()
        externalChangeTimes.removeAll()
        hasPendingAgentChanges = false
        showsRecentAgentUpdate = false
        stopDatabaseWatch()
        projectDatabase = nil
        databaseChangeToken = 0

        do {
            let loaded = try await ProjectDatabaseBridge.loadScoreProject(url: url, preferService: preferService)
            let meta = loaded.metadata
            let stubs = loaded.stubs
            let isStandalone = url.pathExtension.lowercased() == "ows"
            self.projectURL = url
            self.workingProjectURL = loaded.workingProjectURL
            self.projectDatabase = loaded.database
            self.metadata = meta
            self.songStubs = stubs
            self.isStandaloneSongWorkspace = isStandalone
            self.songAssets = loaded.songAssets
            self.librettoFiles = loaded.librettoFiles
            self.databaseChangeToken = (try? await ProjectDatabaseBridge.currentChangeToken(database: loaded.database)) ?? 0
            self.hydratedSongPaths = loaded.hydratedSongPaths

            UserDefaults.standard.set(url.path, forKey: "lastProjectPath")

            if !isStandalone {
                instrumentMappings = loaded.projectInstrumentMappings
            } else {
                instrumentMappings = [:]
            }

            for asset in songAssets {
                for (k, v) in OWPProjectIO.normalizeProjectInstrumentMappings(asset.document.instrumentMappings) {
                    if instrumentMappings[k] == nil { instrumentMappings[k] = v }
                }
            }

            // Resolve embedded SoundFont paths for OWP bundles
            if !isStandalone {
                OWPProjectIO.resolveSoundFonts(mappings: &instrumentMappings, in: loaded.workingProjectURL)
            }

            isDirty = false
            statusMessage = "\(meta.name) — \(songAssets.count) songs loaded"
            novotroDebugLog("loadProject LOADED \(songAssets.count) songs, hydratedPaths=\(hydratedSongPaths.count)")

            // Auto-select first song
            if let first = songAssets.first {
                novotroDebugLog("loadProject auto-selecting first song: \(first.relativePath)")
                setSelectedMidi(id: first.id)
            }

            startDatabaseWatch()
            recordExternalFileSnapshots()
            startExternalFileWatch()
        } catch {
            statusMessage = "Failed to load: \(error.localizedDescription)"
        }
    }

    func restoreLastProject() {
        guard let path = UserDefaults.standard.string(forKey: "lastProjectPath") else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Task { await loadProject(url: url) }
    }

    // MARK: - Save

    func save() {
        checkForExternalProjectChanges()
        guard !isAgentSyncInProgress, !hasPendingAgentChanges else {
            statusMessage = "Detected newer agent changes. Reloading them before saving."
            return
        }
        guard let url = fileProjectURL, !isSavingInternal else { return }
        isSavingInternal = true
        saveIndicator = .saving

        // Persist current MIDI state first so the snapshot captures the latest data
        persistCurrentMidiOverrideIfNeeded()

        // Auto-snapshot after persisting (throttled to once per 5 minutes).
        // Use markDirty: false to avoid re-triggering the auto-save cycle.
        if let midiID = selectedMidiID {
            let now = Date()
            if lastAutoSnapshotDate == nil || now.timeIntervalSince(lastAutoSnapshotDate!) >= Self.autoSnapshotCooldown {
                snapshotSongVersion(for: midiID, saveType: .autosave, markDirty: false)
                lastAutoSnapshotDate = now
            }
        }

        let isStandalone = url.pathExtension.lowercased() == "ows"
        let songsToSave: [OWSSongAsset]
        if isStandalone {
            songsToSave = Array(songAssets.prefix(1))
        } else {
            songsToSave = songAssets.filter { dirtySongPaths.contains($0.relativePath) }
        }
        let capturedMetadata = metadata
        let dirtyPaths = dirtySongPaths
        // Note: do NOT clear dirtySongPaths here — only subtract successfully-saved paths after completion

        // Build playback snapshots for dirty songs
        var playbackByPath: [String: OWSPlaybackSnapshot] = [:]
        for song in songsToSave {
            if song.relativePath == selectedMidiAsset?.relativePath {
                playbackByPath[song.relativePath] = buildCurrentPlaybackSnapshot()
            }
        }

        // Embed SoundFonts into OWP bundle before saving
        if !isStandalone {
            instrumentMappings = OWPProjectIO.embedSoundFonts(
                mappings: instrumentMappings,
                in: url
            )
            instrumentMappings = OWPProjectIO.normalizeProjectInstrumentMappings(instrumentMappings)
        }

        let capturedInstrumentMappings = isStandalone ? [:] : instrumentMappings

        Task.detached { [store = self] in
            var errorMessage: String?
            do {
                if isStandalone, let song = songsToSave.first {
                    try OWPProjectIO.saveStandaloneSong(songURL: url, song: song, playback: playbackByPath[song.relativePath])
                } else {
                    try OWPProjectIO.savePackage(
                        packageURL: url,
                        metadata: capturedMetadata,
                        songs: songsToSave,
                        playbackByPath: playbackByPath,
                        projectInstrumentMappings: capturedInstrumentMappings
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            await MainActor.run {
                store.isSavingInternal = false
                if let errorMessage {
                    store.saveIndicator = .unsavedChanges
                    store.statusMessage = "Save failed: \(errorMessage)"
                    // dirtyPaths were never cleared — they remain in dirtySongPaths
                } else {
                    store.dirtySongPaths.subtract(dirtyPaths)
                    store.metadata.updatedAt = Date()
                    if !store.isStandaloneSongWorkspace {
                        Task {
                            try? await ProjectDatabaseBridge.upsertProjectState(
                                database: store.projectDatabase,
                                metadata: capturedMetadata,
                                instrumentMappings: capturedInstrumentMappings,
                                actorID: ProjectDatabaseBridge.scoreActorID
                            )
                        }
                    }
                    store.syncSongsToDatabase(paths: dirtyPaths)
                    if store.dirtySongPaths.isEmpty {
                        store.isDirty = false
                        store.saveIndicator = .saved
                    } else {
                        store.isDirty = true
                        store.saveIndicator = .unsavedChanges
                    }
                    store.recordExternalFileSnapshots()
                }
            }
        }
    }

    private func buildCurrentPlaybackSnapshot() -> OWSPlaybackSnapshot {
        OWSPlaybackSnapshot(
            notes: pianoRollNotes,
            trackNames: pianoRollTrackNames,
            channelPrograms: pianoRollChannelPrograms,
            trackChannelPrograms: pianoRollTrackChannelPrograms,
            lyricCues: pianoRollLyricCues,
            audioClips: pianoRollAudioClips,
            tempoEvents: pianoRollTempoEvents,
            ticksPerQuarter: ticksPerQuarter,
            lengthTicks: pianoRollLengthTicks,
            initialTempoBPM: tempoBPM,
            timeSignatureEvents: pianoRollTimeSignatures.isEmpty ? nil : pianoRollTimeSignatures,
            keySignatureEvents: pianoRollKeySignatures.isEmpty ? nil : pianoRollKeySignatures,
            lyricAlignments: pianoRollLyricAlignments.isEmpty ? nil : pianoRollLyricAlignments,
            markers: pianoRollMarkers.isEmpty ? nil : pianoRollMarkers,
            channelPan: channelPan.isEmpty ? nil : channelPan,
            automationData: pianoRollAutomation.lanes.isEmpty ? nil : pianoRollAutomation,
            scoreAnnotations: scoreAnnotations.isEmpty ? nil : scoreAnnotations
        )
    }

    private func scheduleAutoSaveIfNeeded() {
        autoSaveWorkItem?.cancel()
        autoSaveWorkItem?.cancel()
        autoSaveWorkItem = nil
    }

    private func beginAgentSync() {
        isAgentSyncInProgress = true
        hasPendingAgentChanges = false
    }

    private func markAgentUpdated(paths: [String] = []) {
        isAgentSyncInProgress = false
        hasPendingAgentChanges = false
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

    private func startExternalFileWatch() {
        stopExternalFileWatch()
        guard fileProjectURL != nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.checkForExternalProjectChanges()
            self.startExternalFileWatch()
        }
        externalFileWatchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalWatchInterval, execute: workItem)
    }

    private func stopExternalFileWatch() {
        externalFileWatchWorkItem?.cancel()
        externalFileWatchWorkItem = nil
        // Note: intentionally NOT clearing lastKnownExternalSnapshots here.
        // Clearing them causes the next startExternalFileWatch() to detect
        // ALL files as "changed", spawning massive concurrent reload Tasks.
    }

    private func recordExternalFileSnapshots() {
        guard let projectURL = fileProjectURL else { return }
        lastKnownExternalSnapshots = monitoredExternalFileSnapshots(for: projectURL)
    }

    private func monitoredExternalFileSnapshots(for projectURL: URL) -> [String: ExternalProjectFileSnapshot] {
        var snapshots: [String: ExternalProjectFileSnapshot] = [:]

        if projectURL.pathExtension.lowercased() == "ows" {
            if let snapshot = fileSnapshot(for: projectURL) {
                snapshots[projectURL.lastPathComponent] = snapshot
            }
            return snapshots
        }

        let songsRoot = projectURL.appendingPathComponent(OWPProjectIO.songsDir)
        for stub in OWPProjectIO.enumerateSongStubs(in: songsRoot) {
            if let snapshot = fileSnapshot(for: stub.fileURL) {
                snapshots[stub.relativePath] = snapshot
            }
        }

        for path in [OWPProjectIO.projectMetadataFile, ProjectDatabaseBridge.legacyMetadataPath, OWPProjectIO.projectInstrumentsFile] {
            let fileURL = projectURL.appendingPathComponent(path)
            if let snapshot = fileSnapshot(for: fileURL) {
                snapshots[path] = snapshot
            }
        }

        return snapshots
    }

    private func fileSnapshot(for fileURL: URL) -> ExternalProjectFileSnapshot? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate else {
            return nil
        }

        return ExternalProjectFileSnapshot(
            modificationDate: modificationDate,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    private func checkForExternalProjectChanges() {
        guard let projectURL = fileProjectURL, !isSavingInternal else { return }

        let currentSnapshots = monitoredExternalFileSnapshots(for: projectURL)
        let changedPaths = Set(currentSnapshots.keys).union(lastKnownExternalSnapshots.keys)
            .filter { currentSnapshots[$0] != lastKnownExternalSnapshots[$0] }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !changedPaths.isEmpty else { return }
        novotroDebugLog("checkForExternalProjectChanges: \(changedPaths.count) changed: \(changedPaths.joined(separator: ", "))")
        lastKnownExternalSnapshots = currentSnapshots

        let currentSongPaths = Set(currentSnapshots.keys.filter { $0.hasSuffix(".ows") })
        let knownSongPaths = Set(songStubs.map(\.relativePath))
        if currentSongPaths != knownSongPaths {
            novotroDebugLog("checkForExternalProjectChanges: song paths changed, full rescan triggered")
            handleExternalProjectRescan(projectURL: projectURL, changedPaths: changedPaths)
            return
        }

        for path in changedPaths {
            if path.hasSuffix(".ows") {
                handleExternalSongChange(relativePath: path, projectURL: projectURL)
            } else {
                handleExternalProjectStateChange(path: path, projectURL: projectURL)
            }
        }
    }

    private func handleExternalProjectRescan(projectURL: URL, changedPaths: [String]) {
        let sourceProjectURL = self.projectURL ?? projectURL
        novotroDebugLog("handleExternalProjectRescan: \(changedPaths.count) changed paths")

        guard !isDirty else {
            hasPendingAgentChanges = true
            statusMessage = "Newer agent changes were detected. Save or reload before continuing."
            return
        }

        beginAgentSync()
        Task { [weak self, sourceProjectURL] in
            guard let self else { return }
            if let database = self.projectDatabase, sourceProjectURL.pathExtension.lowercased() != "ows" {
                novotroDebugLog("handleExternalProjectRescan: calling ensureCurrentIndex(forceRebuild: true)")
                try? await database.ensureCurrentIndex(forceRebuild: true)
                novotroDebugLog("handleExternalProjectRescan: ensureCurrentIndex done")
            }
            await self.loadProject(url: sourceProjectURL, preferService: false)
            await MainActor.run {
                self.markAgentUpdated(paths: changedPaths.filter { $0.hasSuffix(".ows") })
                self.statusMessage = "Reloaded external project changes"
            }
        }
    }

    private func handleExternalSongChange(relativePath: String, projectURL: URL) {
        let stub: SongStub?
        if projectURL.pathExtension.lowercased() == "ows" {
            stub = songStubs.first
        } else if let existing = songStubs.first(where: { $0.relativePath == relativePath }) {
            stub = existing
        } else {
            let songsRoot = projectURL.appendingPathComponent(OWPProjectIO.songsDir)
            stub = OWPProjectIO.enumerateSongStubs(in: songsRoot).first(where: { $0.relativePath == relativePath })
        }

        guard let stub else {
            handleExternalProjectRescan(projectURL: projectURL, changedPaths: [relativePath])
            return
        }

        if dirtySongPaths.contains(relativePath),
           let midiID = songAssets.first(where: { $0.relativePath == relativePath })?.id {
            snapshotSongVersion(
                for: midiID,
                label: "Local Draft Before Agent Update",
                saveType: .snapshot,
                markDirty: false
            )
            dirtySongPaths.remove(relativePath)
            if dirtySongPaths.isEmpty {
                isDirty = false
            }
        }

        beginAgentSync()
        Task { [weak self, stub] in
            guard let self else { return }
            do {
                let asset = try await OWPProjectIO.loadSongAsync(stub: stub)
                await MainActor.run {
                    if let songIndex = self.songAssets.firstIndex(where: { $0.relativePath == relativePath }) {
                        self.songAssets[songIndex] = asset
                    } else {
                        self.songAssets.append(asset)
                    }

                    if let librettoIndex = self.librettoFiles.firstIndex(where: { $0.relativePath == relativePath }) {
                        self.librettoFiles[librettoIndex].content = asset.document.activeVersion()?.lyrics ?? ""
                    } else {
                        self.librettoFiles.append(
                            ProjectTextFile(
                                id: UUID(),
                                relativePath: relativePath,
                                content: asset.document.activeVersion()?.lyrics ?? ""
                            )
                        )
                    }

                    if let stubIndex = self.songStubs.firstIndex(where: { $0.relativePath == relativePath }) {
                        self.songStubs[stubIndex] = stub
                    }

                    self.hydratedSongPaths.insert(relativePath)
                    self.markAgentUpdated(paths: [relativePath])
                    self.statusMessage = "Reloaded \(asset.displayName) from disk"

                    if self.selectedMidiAsset?.relativePath == relativePath {
                        self.loadSelectedMidiIfPossible()
                    }
                }

                try? await ProjectDatabaseBridge.syncSong(
                    database: self.projectDatabase,
                    asset: asset,
                    playbackOverride: nil,
                    actorID: ProjectDatabaseBridge.scoreActorID
                )
            } catch {
                await MainActor.run {
                    self.isAgentSyncInProgress = false
                    self.hasPendingAgentChanges = true
                    self.statusMessage = "Failed to reload external song changes"
                }
            }
        }
    }

    private func handleExternalProjectStateChange(path: String, projectURL: URL) {
        beginAgentSync()

        if path == OWPProjectIO.projectMetadataFile || path == ProjectDatabaseBridge.legacyMetadataPath {
            if let metadata = loadProjectMetadataFromDisk(projectURL: projectURL) {
                self.metadata = metadata
                let currentMappings = instrumentMappings
                Task { [projectDatabase, metadata, currentMappings] in
                    try? await ProjectDatabaseBridge.upsertProjectState(
                        database: projectDatabase,
                        metadata: metadata,
                        instrumentMappings: currentMappings,
                        actorID: ProjectDatabaseBridge.scoreActorID
                    )
                }
            }
        } else if path == OWPProjectIO.projectInstrumentsFile {
            instrumentMappings = OWPProjectIO.loadProjectInstrumentMappings(from: projectURL)
            for asset in songAssets {
                for (key, mapping) in OWPProjectIO.normalizeProjectInstrumentMappings(asset.document.instrumentMappings)
                    where instrumentMappings[key] == nil {
                    instrumentMappings[key] = mapping
                }
            }
            OWPProjectIO.resolveSoundFonts(mappings: &instrumentMappings, in: projectURL)
            rebuildProjectChannelRegistry()
            playbackEngine.reloadAllInstruments(mappings: instrumentMappings)
            let currentMetadata = metadata
            let currentMappings = instrumentMappings
            Task { [projectDatabase, currentMetadata, currentMappings] in
                try? await ProjectDatabaseBridge.upsertProjectState(
                    database: projectDatabase,
                    metadata: currentMetadata,
                    instrumentMappings: currentMappings,
                    actorID: ProjectDatabaseBridge.scoreActorID
                )
            }
        }

        markAgentUpdated()
        statusMessage = "Reloaded external project settings"
    }

    private func loadProjectMetadataFromDisk(projectURL: URL) -> ProjectMetadata? {
        for path in [OWPProjectIO.projectMetadataFile, ProjectDatabaseBridge.legacyMetadataPath] {
            let fileURL = projectURL.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                  let metadata = try? OWPProjectIO.configuredDecoder().decode(ProjectMetadata.self, from: data) else {
                continue
            }
            return metadata
        }
        return nil
    }

    // MARK: - Song Selection

    func setSelectedMidi(id: MidiAsset.ID?, stopPlaybackBeforeSelect: Bool = true) {
        cancelPendingPlaybackStart()
        if stopPlaybackBeforeSelect {
            stopPlayback()
        }
        // If the engine wasn't playing when the song was selected, stopPlayback() was a
        // no-op from a playback perspective — but it still set userInitiatedStop=true.
        // Clear it so that the new song's natural end can still trigger continuous play.
        if !isPlaying || !stopPlaybackBeforeSelect {
            userInitiatedStop = false
        }
        persistCurrentMidiOverrideIfNeeded()
        selectedMidiID = id
        deferredPlaybackAttempted.removeAll()
        if let selectedPath = selectedMidiAsset?.relativePath,
           let libretto = librettoFiles.first(where: { $0.relativePath == selectedPath }) {
            selectedLibrettoID = libretto.id
        }
        loadSelectedMidiIfPossible()
    }

    func setSelectedLibretto(id: ProjectTextFile.ID?) {
        selectedLibrettoID = id
    }

    private func loadSelectedMidiIfPossible() {
        guard let selectedMidiID,
              let songAsset = songAssets.first(where: { $0.id == selectedMidiID }) else {
            clearPianoRollData()
            lastSelectedMidiID = nil
            return
        }

        let playback = songAsset.document.activeVersion()?.playback
        novotroDebugLog("loadSelectedMidiIfPossible: \(songAsset.relativePath) playback=\(playback != nil ? "YES (\(playback!.notes.count) notes)" : "nil")")
        if let playback {
            // Load from playback snapshot (most common path for OWS files)
            pianoRollNotes = playback.notes.sorted {
                if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
                if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
                return $0.pitch < $1.pitch
            }
            pianoRollTrackNames = playback.trackNames
            pianoRollChannelPrograms = playback.channelPrograms
            pianoRollTrackChannelPrograms = playback.trackChannelPrograms
            pianoRollLyricCues = playback.lyricCues
            pianoRollLyricAlignments = playback.lyricAlignments ?? []
            pianoRollAudioClips = playback.audioClips
            ticksPerQuarter = max(1, playback.ticksPerQuarter)
            pianoRollLengthTicks = max(playback.lengthTicks, ticksPerQuarter * 8)
            pianoRollTempoEvents = playback.tempoEvents
            pianoRollTimeSignatures = playback.timeSignatureEvents ?? [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
            pianoRollKeySignatures = playback.keySignatureEvents ?? [KeySignatureEvent(tick: 0, sharpsFlats: 0, isMinor: false)]
            tempoBPM = pianoRollTempoEvents.first?.bpm ?? 112
            pianoRollMarkers = playback.markers ?? []
            channelPan = playback.channelPan ?? [:]
            pianoRollAutomation = playback.automationData ?? PianoRollAutomationData()
            scoreAnnotations = playback.scoreAnnotations ?? []
        } else {
            clearPianoRollData()
            let selectedID = selectedMidiID
            let alreadyAttempted = hydratedSongPaths.contains(songAsset.relativePath)
            if alreadyAttempted {
                // Hydration already ran but produced no playback data — song has no MIDI.
                NSLog("[ScoreStore] loadSelectedMidiIfPossible: %@ already hydrated but has no playback", songAsset.relativePath)
                statusMessage = "No MIDI data in \(songAsset.displayName)."
            } else {
                Task { [weak self, selectedID] in
                    guard let self else { return }
                    _ = await self.hydrateSongDetailsIfNeeded(id: selectedID, includePlayback: true)
                }
            }
        }

        // Build channel key mapping from track names
        pianoRollChannelKeyByTrackChannel = [:]
        pianoRollChannelNames = [:]
        for (trackIndex, name) in pianoRollTrackNames {
            var channels = Set(pianoRollNotes.filter { $0.trackIndex == trackIndex }.map(\.channel))
            // Ensure every named track has at least one entry (channel 0) even if it has no notes,
            // so the track appears in the instrument panel and is selectable.
            if channels.isEmpty { channels.insert(0) }
            for ch in channels {
                let pairKey = "\(trackIndex):\(ch)"
                let baseKey = normalizedChannelKey(from: name, fallbackTrack: trackIndex, fallbackChannel: ch)
                pianoRollChannelKeyByTrackChannel[pairKey] = baseKey
                pianoRollChannelNames[ch] = name
            }
        }

        let currentChannelKeys = Set(pianoRollChannelKeyByTrackChannel.values)
        let documentMappings = OWPProjectIO.normalizeProjectInstrumentMappings(songAsset.document.instrumentMappings)
        if isStandaloneSongWorkspace {
            for key in currentChannelKeys {
                if let docMapping = documentMappings[key] {
                    instrumentMappings[key] = docMapping
                }
            }
            for (k, v) in documentMappings {
                if instrumentMappings[k] == nil {
                    instrumentMappings[k] = v
                }
            }
        } else {
            for key in currentChannelKeys where instrumentMappings[key] == nil {
                if let docMapping = documentMappings[key] {
                    instrumentMappings[key] = docMapping
                }
            }
        }

        lastSelectedMidiID = selectedMidiID
        undoStack.removeAll()
        redoStack.removeAll()
        selectedNoteIDs.removeAll()
        midiInputLiveRecord = false
        liveRecordingHeldNotes.removeAll()
        automationRecordArmed = false
        automationRecordChannelKey = nil
        _cachedAvailableTrackIndices = nil // invalidate stale track index cache
        statusMessage = "Loaded \(songAsset.displayName)."
        rebuildProjectChannelRegistry()

        // Preload project AU mappings while idle so continuous-play transitions do not have
        // to instantiate plugins on the render boundary.
        playbackEngine.prewarmAudioUnits(for: instrumentMappings)
    }

    func hydrateSongPlaybackIfNeeded(id: MidiAsset.ID) async -> Bool {
        guard await hydrateSongDetailsIfNeeded(id: id, includePlayback: true),
              let songIndex = songAssets.firstIndex(where: { $0.id == id }),
              let playback = songAssets[songIndex].document.activeVersion()?.playback else {
            return false
        }
        return !playback.notes.isEmpty
    }

    private func hydrateSongDetailsIfNeeded(id: MidiAsset.ID, includePlayback: Bool) async -> Bool {
        guard let songIndex = songAssets.firstIndex(where: { $0.id == id }) else {
            novotroDebugLog("hydrateSongDetailsIfNeeded: song id not found")
            return false
        }

        let relativePath = songAssets[songIndex].relativePath
        novotroDebugLog("hydrateSongDetailsIfNeeded START: \(relativePath) includePlayback=\(includePlayback)")
        let hasPlayback = songAssets[songIndex].document.activeVersion()?.playback != nil
        if hydratedSongPaths.contains(relativePath) && (!includePlayback || hasPlayback) {
            return true
        }

        var hydratedAsset: OWSSongAsset?
        if let database = projectDatabase {
            do {
                let dbAsset = try await ProjectDatabaseBridge.loadSceneAsset(
                    database: database,
                    relativePath: relativePath,
                    includePlayback: includePlayback
                )
                if includePlayback && dbAsset?.document.activeVersion()?.playback == nil {
                    NSLog("[ScoreStore] hydrateSongDetailsIfNeeded: DB has scene for %@ but playback_json is NULL — falling through to disk", relativePath)
                } else {
                    hydratedAsset = dbAsset
                }
            } catch {
                NSLog("[ScoreStore] hydrateSongDetailsIfNeeded: DB load failed for %@: %@", relativePath, error.localizedDescription)
            }
        }
        if hydratedAsset == nil,
           let stub = songStubs.first(where: { $0.relativePath == relativePath }) {
            do {
                hydratedAsset = try await OWPProjectIO.loadSongAsync(stub: stub)
            } catch {
                NSLog("[ScoreStore] hydrateSongDetailsIfNeeded: disk load failed for %@: %@", relativePath, error.localizedDescription)
            }
        }

        guard let hydratedAsset else {
            novotroDebugLog("hydrateSongDetailsIfNeeded FAILED: no asset loaded for \(relativePath)")
            return false
        }
        let hydPlayback = hydratedAsset.document.activeVersion()?.playback
        novotroDebugLog("hydrateSongDetailsIfNeeded OK: \(relativePath) playback=\(hydPlayback != nil ? "YES (\(hydPlayback!.notes.count) notes)" : "nil")")

        if let latestIndex = songAssets.firstIndex(where: { $0.relativePath == relativePath }) {
            songAssets[latestIndex] = hydratedAsset
        } else {
            songAssets.append(hydratedAsset)
        }

        if let activeLyrics = hydratedAsset.document.activeVersion()?.lyrics {
            if let librettoIndex = librettoFiles.firstIndex(where: { $0.relativePath == relativePath }) {
                librettoFiles[librettoIndex].content = activeLyrics
            } else {
                librettoFiles.append(
                    ProjectTextFile(id: UUID(), relativePath: relativePath, content: activeLyrics)
                )
            }
        }

        hydratedSongPaths.insert(relativePath)
        if selectedMidiID == id {
            loadSelectedMidiIfPossible()
        }
        return true
    }

    private func scheduleDatabaseSyncIfNeeded() {
        guard !isStandaloneSongWorkspace,
              let relativePath = selectedMidiAsset?.relativePath else {
            return
        }
        scheduleDatabaseSync(for: relativePath)
    }

    private func scheduleDatabaseSync(for path: String, delay: TimeInterval = 0.28) {
        guard projectDatabase != nil, !isStandaloneSongWorkspace else { return }

        pendingDatabaseSongSyncs[path]?.cancel()
        suppressDatabaseSyncPaths.insert(path)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let (asset, playbackOverride) = self.prepareSongForDatabaseSync(path: path) else {
                self.pendingDatabaseSongSyncs.removeValue(forKey: path)
                self.suppressDatabaseSyncPaths.remove(path)
                return
            }

            Task {
                try? await ProjectDatabaseBridge.syncSong(
                    database: self.projectDatabase,
                    asset: asset,
                    playbackOverride: playbackOverride,
                    actorID: ProjectDatabaseBridge.scoreActorID
                )
                await MainActor.run {
                    self.pendingDatabaseSongSyncs.removeValue(forKey: path)
                    self.suppressDatabaseSyncPaths.remove(path)
                }
            }
        }

        pendingDatabaseSongSyncs[path] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func prepareSongForDatabaseSync(path: String) -> (OWSSongAsset, OWSPlaybackSnapshot?)? {
        guard let songIndex = songAssets.firstIndex(where: { $0.relativePath == path }) else {
            return nil
        }

        var asset = songAssets[songIndex]
        var playbackOverride: OWSPlaybackSnapshot?
        if selectedMidiAsset?.relativePath == path,
           let activeVersionID = asset.document.activeVersionID,
           let versionIndex = asset.document.versions.firstIndex(where: { $0.id == activeVersionID }) {
            let snapshot = buildCurrentPlaybackSnapshot()
            let now = Date()
            asset.document.versions[versionIndex].playback = snapshot
            asset.document.versions[versionIndex].updatedAt = now
            asset.document.updatedAt = now
            songAssets[songIndex] = asset
            playbackOverride = snapshot
        }

        return (asset, playbackOverride)
    }

    private func syncSongsToDatabase(paths: Set<String>) {
        guard projectDatabase != nil, !paths.isEmpty else { return }
        for path in paths {
            scheduleDatabaseSync(for: path, delay: 0)
        }
    }

    private func startDatabaseWatch() {
        stopDatabaseWatch()
        guard projectDatabase != nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pollDatabaseChanges()
            self.startDatabaseWatch()
        }
        databaseWatchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.databaseWatchInterval, execute: workItem)
    }

    private func stopDatabaseWatch() {
        databaseWatchWorkItem?.cancel()
        databaseWatchWorkItem = nil
        for workItem in pendingDatabaseSongSyncs.values {
            workItem.cancel()
        }
        pendingDatabaseSongSyncs.removeAll()
        suppressDatabaseSyncPaths.removeAll()
        backgroundIndexRefreshTask?.cancel()
        backgroundIndexRefreshTask = nil
    }

    func suspendBackgroundWork() {
        stopDatabaseWatch()
        stopExternalFileWatch()
    }

    func resumeBackgroundWork() {
        startDatabaseWatch()
        startExternalFileWatch()
    }

    private func pollDatabaseChanges() {
        let database = projectDatabase
        let currentToken = databaseChangeToken
        Task { [weak self, database, currentToken] in
            guard let self else { return }
            do {
                let changes = try await ProjectDatabaseBridge.listChanges(
                    database: database,
                    since: currentToken
                )
                guard !changes.isEmpty else { return }
                await MainActor.run {
                    self.databaseChangeToken = changes.last?.changeID ?? self.databaseChangeToken
                    for change in changes {
                        self.applyDatabaseChange(change)
                    }
                }
            } catch {
                NSLog("[ScoreStore] Database poll error: %@", error.localizedDescription)
            }
        }
    }

    private func applyDatabaseChange(_ change: ChangeEvent) {
        guard change.actorID != ProjectDatabaseBridge.scoreActorID else {
            return
        }

        switch change.entityType {
        case "scene":
            let relativePath = change.entityKey
            guard !dirtySongPaths.contains(relativePath),
                  !suppressDatabaseSyncPaths.contains(relativePath) else {
                return
            }

            let includePlayback = selectedMidiAsset?.relativePath == relativePath
            Task {
                do {
                    guard let asset = try await ProjectDatabaseBridge.loadSceneAsset(
                        database: projectDatabase,
                        relativePath: relativePath,
                        includePlayback: includePlayback
                    ) else {
                        return
                    }

                    await MainActor.run {
                        guard !self.dirtySongPaths.contains(relativePath),
                              !self.suppressDatabaseSyncPaths.contains(relativePath) else {
                            return
                        }

                        if let index = self.songAssets.firstIndex(where: { $0.relativePath == relativePath }) {
                            self.songAssets[index] = asset
                        } else {
                            self.songAssets.append(asset)
                        }
                        self.hydratedSongPaths.insert(relativePath)

                        if let activeLyrics = asset.document.activeVersion()?.lyrics {
                            if let librettoIndex = self.librettoFiles.firstIndex(where: { $0.relativePath == relativePath }) {
                                self.librettoFiles[librettoIndex].content = activeLyrics
                            } else {
                                self.librettoFiles.append(
                                    ProjectTextFile(id: UUID(), relativePath: relativePath, content: activeLyrics)
                                )
                            }
                        }

                        if includePlayback {
                            self.loadSelectedMidiIfPossible()
                        }
                        self.markAgentUpdated(paths: [relativePath])
                    }
                } catch {
                    NSLog("[ScoreStore] Scene load error: %@", error.localizedDescription)
                }
            }
        case "project_file":
            guard !isDirty else { return }
            switch change.entityKey {
            case ProjectDatabaseBridge.metadataPath, ProjectDatabaseBridge.legacyMetadataPath:
                Task {
                    let metadata = try? await ProjectDatabaseBridge.loadProjectMetadata(database: projectDatabase)
                    await MainActor.run {
                        guard !self.isDirty, let metadata else { return }
                        self.metadata = metadata
                    }
                }
            case ProjectDatabaseBridge.projectInstrumentsPath:
                Task {
                    let mappings = try? await ProjectDatabaseBridge.loadProjectInstrumentMappings(database: projectDatabase)
                    await MainActor.run {
                        guard !self.isDirty,
                              let loadedMappings = mappings else { return }
                        var mergedMappings = loadedMappings

                        for asset in self.songAssets {
                            for (key, mapping) in OWPProjectIO.normalizeProjectInstrumentMappings(asset.document.instrumentMappings)
                                where mergedMappings[key] == nil {
                                mergedMappings[key] = mapping
                            }
                        }

                        self.instrumentMappings = mergedMappings
                        if let projectURL = self.fileProjectURL, !self.isStandaloneSongWorkspace {
                            OWPProjectIO.resolveSoundFonts(mappings: &self.instrumentMappings, in: projectURL)
                        }

                        self.rebuildProjectChannelRegistry()
                        self.playbackEngine.reloadAllInstruments(mappings: self.instrumentMappings)
                        self.markAgentUpdated()
                    }
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func startBackgroundIndexRefresh(projectURL: URL, database: NovotroProjectConnection) {
        novotroDebugLog("⚠️ startBackgroundIndexRefresh CALLED — this should NOT happen on initial load!")
        backgroundIndexRefreshTask?.cancel()
        backgroundIndexRefreshTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else { return }
                let previousToken = (try? await database.currentChangeToken()) ?? 0
                guard !Task.isCancelled else { return }
                try await database.ensureCurrentIndex()
                guard !Task.isCancelled else { return }
                let refreshedToken = (try? await database.currentChangeToken()) ?? previousToken
                guard refreshedToken != previousToken else { return }
                guard let self else { return }
                guard !self.isDirty else {
                    await MainActor.run {
                        self.hasPendingAgentChanges = true
                    }
                    return
                }
                await self.loadProject(url: projectURL, preferService: false)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.markAgentUpdated()
                    self.statusMessage = "Loaded latest disk changes"
                }
            } catch {
                await MainActor.run {
                    guard let self, self.projectURL == projectURL else { return }
                    if self.statusMessage.isEmpty {
                        self.statusMessage = "Background index refresh failed"
                    }
                }
            }
        }
    }

    // MARK: - Dynamics Application

    /// Scale note velocities based on active dynamic annotations at each note's tick position.
    /// Notes retain their relative velocity differences — dynamics act as a multiplier.
    private func applyDynamicsToNotes(_ notes: [PianoRollNote]) -> [PianoRollNote] {
        let dynamicAnnotations = scoreAnnotations
            .filter { $0.kind == .dynamic }
            .sorted(by: { $0.tick < $1.tick })

        guard !dynamicAnnotations.isEmpty else { return notes }

        return notes.map { note in
            // Find the active dynamic at this note's tick
            guard let active = dynamicAnnotations.last(where: { $0.tick <= note.startTick }) else {
                return note
            }

            let scale = Self.dynamicVelocityScale(active.text)
            guard scale != 1.0 else { return note }

            var modified = note
            modified.velocity = max(1, min(127, Int(Double(note.velocity) * scale)))
            return modified
        }
    }

    /// Map dynamic marking text to a velocity scale factor (1.0 = no change).
    private static func dynamicVelocityScale(_ text: String) -> Double {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "ppp":  return 0.25
        case "pp":   return 0.40
        case "p":    return 0.55
        case "mp":   return 0.70
        case "mf":   return 0.85
        case "f":    return 1.0
        case "ff":   return 1.15
        case "fff":  return 1.30
        case "sfz":  return 1.25
        case "fp":   return 0.55  // forte-piano: attack at f then immediately p
        default:     return 1.0   // unknown marking, no change
        }
    }

    // MARK: - MusicXML Import

    /// Import a MusicXML file, replacing the current piano roll data.
    func importMusicXML(url: URL) {
        do {
            let result = try MusicXMLImporter.importFile(at: url)

            pushUndoState(label: "Import MusicXML")
            pianoRollNotes = result.notes
            pianoRollTrackNames = result.trackNames
            pianoRollTempoEvents = result.tempoEvents
            pianoRollTimeSignatures = result.timeSignatures
            pianoRollKeySignatures = result.keySignatures
            ticksPerQuarter = result.ticksPerQuarter
            tempoBPM = result.tempoEvents.first?.bpm ?? 120

            // Compute length from notes
            let maxTick = result.notes.map { $0.startTick + $0.duration }.max() ?? 0
            pianoRollLengthTicks = max(maxTick + ticksPerQuarter * 4, ticksPerQuarter * 8)

            // Build channel key mappings
            let trackIndices = Set(result.notes.map(\.trackIndex)).sorted()
            pianoRollChannelKeyByTrackChannel = [:]
            for idx in trackIndices {
                let key = "\(idx):0"
                pianoRollChannelKeyByTrackChannel[key] = key
            }

            isDirty = true
            statusMessage = "Imported \(result.notes.count) notes from \(url.lastPathComponent)"
            NSLog("[MusicXML] Imported %d notes, %d tracks from %@",
                  result.notes.count, result.trackNames.count, url.lastPathComponent)
        } catch {
            statusMessage = "MusicXML import failed: \(error.localizedDescription)"
            NSLog("[MusicXML] Import failed: %@", error.localizedDescription)
        }
    }

    /// Present an open panel for MusicXML files and import the selected file.
    #if canImport(AppKit)
    func importMusicXMLWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import MusicXML"
        panel.allowedContentTypes = [
            .xml,
            UTType(filenameExtension: "musicxml") ?? .xml,
        ]
        panel.allowsMultipleSelection = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.importMusicXML(url: url)
        }
    }
    #endif

    private func clearPianoRollData() {
        pianoRollNotes = []
        pianoRollLyricCues = []
        pianoRollLyricAlignments = []
        pianoRollAudioClips = []
        pianoRollTrackNames = [:]
        pianoRollChannelPrograms = [:]
        pianoRollTrackChannelPrograms = [:]
        pianoRollChannelNames = [:]
        pianoRollChannelKeyByTrackChannel = [:]
        ticksPerQuarter = 480
        pianoRollLengthTicks = 3840
        pianoRollTempoEvents = [TempoPoint(tick: 0, bpm: tempoBPM)]
        pianoRollTimeSignatures = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
        pianoRollKeySignatures = [KeySignatureEvent(tick: 0, sharpsFlats: 0, isMinor: false)]
    }

    private func persistCurrentMidiOverrideIfNeeded() {
        guard let lastSelectedMidiID,
              let midi = midiAssets.first(where: { $0.id == lastSelectedMidiID }) else { return }

        pianoRollOverrides[midi.relativePath] = PianoRollOverride(
            midiPath: midi.relativePath,
            notes: pianoRollNotes,
            lengthTicks: max(pianoRollLengthTicks, ticksPerQuarter * 8),
            ticksPerQuarter: max(1, ticksPerQuarter)
        )

        // Update the song asset's playback snapshot + instrument mappings
        if let songIdx = songAssets.firstIndex(where: { $0.relativePath == midi.relativePath }),
           let activeID = songAssets[songIdx].document.activeVersionID,
           let vIdx = songAssets[songIdx].document.versions.firstIndex(where: { $0.id == activeID }) {
            songAssets[songIdx].document.versions[vIdx].playback = buildCurrentPlaybackSnapshot()
            songAssets[songIdx].document.versions[vIdx].updatedAt = Date()
            songAssets[songIdx].document.updatedAt = Date()
        }

        // Standalone songs keep their instrument mappings in the document itself.
        if isStandaloneSongWorkspace,
           let songIdx = songAssets.firstIndex(where: { $0.relativePath == midi.relativePath }) {
            let songChannelKeys = Set(pianoRollChannelKeyByTrackChannel.values)
            var songMappings = songAssets[songIdx].document.instrumentMappings
            for key in songChannelKeys {
                if let mapping = instrumentMappings[key] {
                    songMappings[key] = mapping
                }
            }
            songAssets[songIdx].document.instrumentMappings = OWPProjectIO.normalizeProjectInstrumentMappings(songMappings)
        }

        dirtySongPaths.insert(midi.relativePath)
    }

    // MARK: - Note Editing

    func setPianoRollNotesFromEditor(_ updated: [PianoRollNote]) {
        pianoRollNotes = updated.sorted {
            if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            return $0.pitch < $1.pitch
        }
        let furthestEndTick = pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? 0
        let minimumLength = max(ticksPerQuarter * 8, furthestEndTick + ticksPerQuarter * 2)
        pianoRollLengthTicks = max(pianoRollLengthTicks, minimumLength)
        isDirty = true
    }

    func updatePianoRollNote(id: UUID, update: (inout PianoRollNote) -> Void) {
        guard let index = pianoRollNotes.firstIndex(where: { $0.id == id }) else { return }
        update(&pianoRollNotes[index])
        isDirty = true
    }

    func renamePianoRollTrack(index: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { pianoRollTrackNames.removeValue(forKey: index) }
        else { pianoRollTrackNames[index] = trimmed }
        isDirty = true
    }

    func setPianoRollLyricCuesFromEditor(_ updated: [LyricCue]) {
        pianoRollLyricCues = updated
            .map { LyricCue(id: $0.id, trackKey: $0.trackKey, tick: max(0, $0.tick), durationTicks: max(1, $0.durationTicks), text: $0.text) }
            .sorted { $0.tick != $1.tick ? $0.tick < $1.tick : $0.text.localizedStandardCompare($1.text) == .orderedAscending }
        isDirty = true
    }

    func setPianoRollAudioClipsFromEditor(_ updated: [AudioClip]) {
        pianoRollAudioClips = updated
            .map {
                AudioClip(
                    id: $0.id,
                    displayName: $0.displayName,
                    filePath: $0.filePath,
                    trackKey: $0.trackKey,
                    trackID: $0.trackID,
                    startTick: max(0, $0.startTick),
                    durationTicks: max(1, $0.durationTicks),
                    offsetTicks: $0.offsetTicks,
                    gainDB: min(max($0.gainDB, -24), 12),
                    pan: $0.pan,
                    muted: $0.muted,
                    fadeInTicks: $0.fadeInTicks,
                    fadeOutTicks: $0.fadeOutTicks,
                    fadeInExponent: $0.fadeInExponent,
                    fadeOutExponent: $0.fadeOutExponent,
                    stretchRatio: $0.stretchRatio,
                    pitchCents: $0.pitchCents
                )
            }
            .sorted { $0.startTick != $1.startTick ? $0.startTick < $1.startTick : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        isDirty = true
    }

    // MARK: - Track Mute/Solo

    func toggleTrackMute(_ trackIndex: Int) {
        if mutedTracks.contains(trackIndex) { mutedTracks.remove(trackIndex) }
        else { mutedTracks.insert(trackIndex) }
    }

    func toggleTrackSolo(_ trackIndex: Int) {
        if soloedTracks.contains(trackIndex) { soloedTracks.remove(trackIndex) }
        else { soloedTracks = [trackIndex] }
    }

    func clearSolo() { soloedTracks.removeAll() }

    // MARK: - Playback

    // MARK: - API Diagnostics

    struct PlaybackDiagnostics: Encodable {
        var selectedMidiID: String?
        var selectedMidiAssetPath: String?
        var pianoRollNotesCount: Int
        var pianoRollAudioClipsCount: Int
        var isPlaying: Bool
        var selectedSongHasPlayback: Bool
        var hydratedSongPaths: [String]
        var deferredPlaybackAttempted: [String]
        var songAssetsCount: Int
        var songAssetPlaybackStates: [String: SongAssetPlaybackState]
        var statusMessage: String

        struct SongAssetPlaybackState: Encodable {
            var hasPlayback: Bool
            var noteCount: Int
        }
    }

    func playbackDiagnostics() -> PlaybackDiagnostics {
        let assetStates = Dictionary(uniqueKeysWithValues: songAssets.map { asset in
            let playback = asset.document.activeVersion()?.playback
            return (asset.relativePath, PlaybackDiagnostics.SongAssetPlaybackState(
                hasPlayback: playback != nil,
                noteCount: playback?.notes.count ?? 0
            ))
        })
        return PlaybackDiagnostics(
            selectedMidiID: selectedMidiID?.uuidString,
            selectedMidiAssetPath: selectedMidiAsset?.relativePath,
            pianoRollNotesCount: pianoRollNotes.count,
            pianoRollAudioClipsCount: pianoRollAudioClips.count,
            isPlaying: isPlaying,
            selectedSongHasPlayback: selectedMidiID.flatMap { id in songAssets.first(where: { $0.id == id }) }?.document.activeVersion()?.playback != nil,
            hydratedSongPaths: Array(hydratedSongPaths).sorted(),
            deferredPlaybackAttempted: deferredPlaybackAttempted.map(\.uuidString).sorted(),
            songAssetsCount: songAssets.count,
            songAssetPlaybackStates: assetStates,
            statusMessage: statusMessage
        )
    }

    func playPianoRoll(startTick: Int = 0, trackFilter: Set<Int>? = nil, cancelPendingAdvance: Bool = true) {
        if cancelPendingAdvance {
            cancelPendingAdvanceStart()
        }
        novotroDebugLog("playPianoRoll: song=\(selectedMidiAsset?.relativePath ?? "nil") notes=\(pianoRollNotes.count) clips=\(pianoRollAudioClips.count)")
        NSLog("[ScoreStore] playPianoRoll — song=%@ notes=%d clips=%d startTick=%d",
              selectedMidiAsset?.relativePath ?? "nil", pianoRollNotes.count, pianoRollAudioClips.count, startTick)
        let unmuted = pianoRollNotes.filter { !$0.muted }
        let filteredNotes: [PianoRollNote]
        if let filter = trackFilter, !filter.isEmpty {
            filteredNotes = unmuted.filter { filter.contains($0.trackIndex) }
        } else {
            filteredNotes = unmuted
        }
        // Apply dynamics annotations to note velocities
        let playbackNotes = applyDynamicsToNotes(filteredNotes)
        let playableAudioClips = pianoRollAudioClips.filter { !$0.muted && !$0.filePath.isEmpty }
        guard !playbackNotes.isEmpty || !playableAudioClips.isEmpty else {
            if queueDeferredPlaybackStartIfNeeded(
                startTick: startTick,
                trackFilter: trackFilter,
                cancelPendingAdvance: cancelPendingAdvance
            ) {
                return
            }
            statusMessage = "No MIDI notes to play."
            isPlaying = false
            pendingAdvance = false
            return
        }

        persistCurrentMidiOverrideIfNeeded()

        var effectiveMutedTracks = mutedTracks
        if !soloedTracks.isEmpty {
            let allTracks = Set(pianoRollNotes.map(\.trackIndex))
            effectiveMutedTracks.formUnion(allTracks.subtracting(soloedTracks))
        }

        // Resolve any relative SF2 paths to absolute paths using the sample root directory.
        let resolvedMappings = resolvedInstrumentMappings()

        // Debug: log mapping state to help diagnose silent playback
        novotroDebugLog("playPianoRoll mappings: \(pianoRollChannelKeyByTrackChannel.count) entries, sampleRoot=\(sampleRootDirectoryPath)")
        for (pairKey, mappingKey) in pianoRollChannelKeyByTrackChannel.sorted(by: { $0.key < $1.key }) {
            let mapping = resolvedMappings[mappingKey]
            let sf2 = mapping?.sf2Path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let exists = !sf2.isEmpty && FileManager.default.fileExists(atPath: sf2)
            let status = sf2.isEmpty ? "NO SF2" : "\(URL(fileURLWithPath: sf2).lastPathComponent) exists=\(exists)"
            novotroDebugLog("  mapping \(pairKey) → \(mappingKey) [\(status)] muted=\(mapping?.muted ?? false) sourceType=\(String(describing: mapping?.effectiveSourceType))")
        }

        playbackEngine.metronomeTimeSignatures = pianoRollTimeSignatures
        playbackEngine.loopRegionStartTick = loopRegionStart
        playbackEngine.loopRegionEndTick = loopRegionEnd
        // Apply practice tempo scale to tempo events (does not modify stored events)
        let scale = max(0.25, min(2.0, practiceTempoScale))
        let scaledTempoEvents = pianoRollTempoEvents.map { TempoPoint(tick: $0.tick, bpm: $0.bpm * scale) }
        let scaledTempoBPM = tempoBPM * scale
        playbackEngine.play(
            notes: playbackNotes,
            lengthTicks: pianoRollLengthTicks,
            ticksPerQuarter: ticksPerQuarter,
            tempoBPM: scaledTempoBPM,
            tempoEvents: scaledTempoEvents,
            loop: loopPlayback,
            startTick: startTick,
            trackChannelToMappingKey: pianoRollChannelKeyByTrackChannel,
            instrumentMappings: resolvedMappings,
            audioClips: playableAudioClips,
            renderMode: playbackRenderMode,
            mutedTracks: effectiveMutedTracks
        )
        statusMessage = ""
    }

    /// When true, the next playback-stopped callback will NOT trigger continuous play advance.
    private var userInitiatedStop = false

    /// Set while advanceToNextSongAndPlay is in progress (song selected, 0.3s delay pending).
    /// Suppresses onNeedsPlaybackRestart so it doesn't race with the scheduled playPianoRoll call.
    private var pendingAdvance = false
    private var pendingAdvanceWorkItem: DispatchWorkItem?

    private func cancelPendingPlaybackStart() {
        pendingPlaybackStartTask?.cancel()
        pendingPlaybackStartTask = nil
    }

    // Tracks song IDs for which a deferred playback start has already been attempted this
    // selection. Cleared when selectedMidiID changes. Prevents infinite retry when a song
    // has been hydrated but genuinely contains no MIDI data.
    private var deferredPlaybackAttempted: Set<MidiAsset.ID> = []

    private func queueDeferredPlaybackStartIfNeeded(
        startTick: Int,
        trackFilter: Set<Int>?,
        cancelPendingAdvance: Bool
    ) -> Bool {
        guard let selectedMidiID,
              let songAsset = songAssets.first(where: { $0.id == selectedMidiID }),
              songAsset.document.activeVersion()?.playback == nil,
              !deferredPlaybackAttempted.contains(selectedMidiID) else {
            return false
        }

        deferredPlaybackAttempted.insert(selectedMidiID)
        cancelPendingPlaybackStart()
        statusMessage = "Loading playback for \(songAsset.displayName)..."

        pendingPlaybackStartTask = Task { @MainActor [weak self, selectedMidiID] in
            guard let self else { return }
            let didHydrate = await self.hydrateSongDetailsIfNeeded(id: selectedMidiID, includePlayback: true)
            guard !Task.isCancelled else { return }
            self.pendingPlaybackStartTask = nil

            guard didHydrate, self.selectedMidiID == selectedMidiID else {
                if self.selectedMidiID == selectedMidiID,
                   self.statusMessage.hasPrefix("Loading playback for") {
                    self.statusMessage = "No MIDI notes to play."
                }
                return
            }

            self.playPianoRoll(
                startTick: startTick,
                trackFilter: trackFilter,
                cancelPendingAdvance: cancelPendingAdvance
            )
        }

        return true
    }

    private func cancelPendingAdvanceStart() {
        let hadPendingAdvance = pendingAdvance || pendingAdvanceWorkItem != nil
        pendingAdvanceWorkItem?.cancel()
        pendingAdvanceWorkItem = nil
        pendingAdvance = false
        // `advanceToNextSongAndPlay()` sets `isPlaying = true` optimistically while a
        // delayed start is pending. If that pending start is canceled while the engine is
        // already stopped, no playback-state callback may arrive to clear the flag.
        if hadPendingAdvance && !playbackEngine.isPlaying {
            isPlaying = false
        }
    }

    func stopPlayback() {
        cancelPendingAdvanceStart()
        cancelPendingPlaybackStart()
        userInitiatedStop = true
        // Keep UI state honest even when engine transport is already idle.
        // In that case stopOnAudioQueue() may not emit a state-change callback.
        if !playbackEngine.isPlaying {
            isPlaying = false
        }
        playbackEngine.stop()
    }

    func seekPlayback(to tick: Int, trackFilter: Set<Int>? = nil) {
        guard isPlaying else { return }
        playPianoRoll(startTick: tick, trackFilter: trackFilter)
    }

    /// Seek to a specific tick (works whether playing or not).
    func seekToMarkerTick(_ tick: Int) {
        livePlayheadTick = tick
        if isPlaying {
            playPianoRoll(startTick: tick)
        }
    }

    /// Jump to the next rehearsal marker after the current playhead position.
    func jumpToNextMarker() {
        let sorted = pianoRollMarkers.sorted { $0.tick < $1.tick }
        if let next = sorted.first(where: { $0.tick > livePlayheadTick }) {
            seekToMarkerTick(next.tick)
        }
    }

    /// Jump to the previous rehearsal marker before the current playhead position.
    func jumpToPreviousMarker() {
        let sorted = pianoRollMarkers.sorted { $0.tick < $1.tick }
        if let prev = sorted.last(where: { $0.tick < livePlayheadTick }) {
            seekToMarkerTick(prev.tick)
        }
    }

    func previewPitch(_ pitch: Int) {
        playbackEngine.previewNote(pitch: pitch)
    }

    func startPreviewPitch(_ pitch: Int) {
        playbackEngine.startLivePreview(pitch: pitch)
    }

    func updatePreviewPitch(_ pitch: Int) {
        playbackEngine.updateLivePreview(pitch: pitch)
    }

    func stopPreviewPitch() {
        playbackEngine.stopLivePreview()
    }

    func updatePreviewMappingForTrackFilter() {
        // Resolve preview instrument: use the solo'd track if exactly one is
        // selected, otherwise fall back to track 0 so the user always hears
        // the assigned instrument instead of the default sine-wave tone.
        let trackIndex: Int
        if selectedTrackFilter.count == 1, let soloTrack = selectedTrackFilter.first {
            trackIndex = soloTrack
        } else {
            trackIndex = 0
        }
        let mapping = resolveInstrumentMapping(forTrackIndex: trackIndex)
        playbackEngine.setPreviewMapping(mapping)
    }

    private func resolveInstrumentMapping(forTrackIndex trackIndex: Int) -> InstrumentMapping? {
        for (pairKey, mappingKey) in pianoRollChannelKeyByTrackChannel {
            let parts = pairKey.split(separator: ":")
            guard parts.count == 2, let idx = Int(parts[0]), idx == trackIndex else { continue }
            if let mapping = instrumentMappings[mappingKey] { return mapping }
            if mappingKey.hasPrefix("song|") {
                let segments = mappingKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                if segments.count == 3, let mapping = instrumentMappings[String(segments[2])] { return mapping }
            }
        }
        return nil
    }

    func setMasterVolume(_ value: Double) {
        masterVolume = min(max(value, 0), 1)
        playbackEngine.setMasterVolume(masterVolume)
    }

    func setPlaybackRenderMode(_ mode: PlaybackRenderMode) {
        playbackRenderMode = mode
    }

    func setAutoSaveEnabled(_ enabled: Bool) {
        autoSaveEnabled = enabled
    }

    // MARK: - Audio Devices

    func setAudioBufferFrames(_ frames: UInt32) {
        selectedAudioBufferFrames = frames
        playbackEngine.setPreferredBufferFrames(frames)
    }

    // MARK: - Instrument Mapping Methods

    func mapping(for profile: ProjectChannelProfile) -> InstrumentMapping {
        instrumentMappings[profile.baseKey] ?? InstrumentMapping(channelKey: profile.baseKey, displayName: profile.displayName)
    }

    func mappingKeysForBaseKey(_ baseKey: String) -> [String] {
        let suffix = "|\(baseKey)"
        let matches = instrumentMappings.keys
            .filter { $0 == baseKey || $0.hasSuffix(suffix) }
            .sorted {
                if $0 == baseKey { return true }
                if $1 == baseKey { return false }
                return $0.localizedStandardCompare($1) == .orderedAscending
            }

        return matches.isEmpty ? [baseKey] : matches
    }

    func channelProfiles(scope: InstrumentProfileScope, forSongPath songPath: String?) -> [ProjectChannelProfile] {
        switch scope {
        case .allSongs:
            return projectChannelProfiles
        case .selectedSong:
            let activeKeys = Set(pianoRollChannelKeyByTrackChannel.values)
            return projectChannelProfiles.filter { activeKeys.contains($0.baseKey) }
        }
    }

    func rebuildProjectChannelRegistry() {
        var profiles: [ProjectChannelProfile] = []
        var seen = Set<String>()
        for (pairKey, mappingKey) in pianoRollChannelKeyByTrackChannel {
            guard !seen.contains(mappingKey) else { continue }
            seen.insert(mappingKey)
            let parts = pairKey.split(separator: ":")
            let trackIndex = parts.count == 2 ? Int(parts[0]) ?? 0 : 0
            let channel = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            let existingMapping = instrumentMappings[mappingKey]
            let name = existingMapping?.displayName ?? pianoRollTrackNames[trackIndex] ?? "Track \(trackIndex)"
            profiles.append(ProjectChannelProfile(
                id: UUID(), key: mappingKey, baseKey: mappingKey,
                displayName: name, aliases: [], songPaths: [],
                midiChannels: [channel], sortOrder: existingMapping?.sortOrder ?? trackIndex
            ))
        }

        var existingBaseKeys = Set(profiles.map(\.baseKey))
        for key in instrumentMappings.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard !existingBaseKeys.contains(key),
                  let mapping = instrumentMappings[key] else { continue }

            let displayName = mapping.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? key
                : mapping.displayName

            profiles.append(ProjectChannelProfile(
                id: UUID(),
                key: key,
                baseKey: key,
                displayName: displayName,
                aliases: [displayName],
                songPaths: [],
                midiChannels: [],
                defaultProgram: nil,
                sortOrder: mapping.sortOrder
            ))
            existingBaseKeys.insert(key)
        }

        // Inject canonical instruments that aren't already present.
        // All instruments are global — every song shows the full set.
        for (displayName, canonicalIndex) in InstrumentMapping.canonicalOrder {
            let baseKey = normalizedChannelKey(from: displayName, fallbackTrack: canonicalIndex, fallbackChannel: 0)
            guard !existingBaseKeys.contains(baseKey) else { continue }
            let existingMapping = instrumentMappings[baseKey]
            profiles.append(ProjectChannelProfile(
                id: UUID(), key: baseKey, baseKey: baseKey,
                displayName: existingMapping?.displayName ?? displayName, aliases: [displayName],
                songPaths: [], midiChannels: [],
                defaultProgram: nil, sortOrder: existingMapping?.sortOrder ?? canonicalIndex
            ))
            existingBaseKeys.insert(baseKey)
        }

        profiles.sort {
            let aRole = (instrumentMappings[$0.baseKey]?.trackRole ?? .instrument) == .vocal ? 0 : 1
            let bRole = (instrumentMappings[$1.baseKey]?.trackRole ?? .instrument) == .vocal ? 0 : 1
            if aRole != bRole { return aRole < bRole }

            let a = instrumentMappings[$0.baseKey]?.effectiveSortOrder ?? $0.effectiveSortOrder
            let b = instrumentMappings[$1.baseKey]?.effectiveSortOrder ?? $1.effectiveSortOrder
            if a != b { return a < b }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        projectChannelProfiles = profiles

        // Ensure an InstrumentMapping exists for every profile
        for profile in profiles {
            if instrumentMappings[profile.baseKey] == nil {
                instrumentMappings[profile.baseKey] = InstrumentMapping(
                    channelKey: profile.baseKey,
                    displayName: profile.displayName
                )
            }
        }
    }

    func setMappingDisplayName(for channelKey: String, name: String) {
        instrumentMappings[channelKey, default: InstrumentMapping(channelKey: channelKey, displayName: channelKey)].displayName = name
        isDirty = true
    }

    func setMappingDisplayName(for channelKeys: [String], name: String) {
        for k in channelKeys { setMappingDisplayName(for: k, name: name) }
    }

    func setMappingProgram(for channelKey: String, program: Int) {
        instrumentMappings[channelKey, default: InstrumentMapping(channelKey: channelKey, displayName: channelKey)].program = program
        isDirty = true
    }

    func setMappingProgram(for channelKeys: [String], program: Int) {
        for k in channelKeys { setMappingProgram(for: k, program: program) }
    }

    func setMappingBankMSB(for channelKey: String, bankMSB: Int) {
        instrumentMappings[channelKey, default: InstrumentMapping(channelKey: channelKey, displayName: channelKey)].bankMSB = bankMSB
        isDirty = true
    }

    func setMappingBankMSB(for channelKeys: [String], bankMSB: Int) {
        for k in channelKeys { setMappingBankMSB(for: k, bankMSB: bankMSB) }
    }

    func setMappingBankLSB(for channelKey: String, bankLSB: Int) {
        instrumentMappings[channelKey, default: InstrumentMapping(channelKey: channelKey, displayName: channelKey)].bankLSB = bankLSB
        isDirty = true
    }

    func setMappingBankLSB(for channelKeys: [String], bankLSB: Int) {
        for k in channelKeys { setMappingBankLSB(for: k, bankLSB: bankLSB) }
    }

    func setMappingGain(for channelKey: String, gainDB: Double) {
        instrumentMappings[channelKey, default: InstrumentMapping(channelKey: channelKey, displayName: channelKey)].gainDB = gainDB
        isDirty = true
    }

    func setMappingGain(for channelKeys: [String], gainDB: Double) {
        for k in channelKeys { setMappingGain(for: k, gainDB: gainDB) }
    }

    func setMappingMuted(for channelKey: String, muted: Bool) {
        instrumentMappings[channelKey, default: InstrumentMapping(channelKey: channelKey, displayName: channelKey)].muted = muted
        isDirty = true
    }

    func setMappingMuted(for channelKeys: [String], muted: Bool) {
        for k in channelKeys { setMappingMuted(for: k, muted: muted) }
    }

    func setMappingColorHex(for channelKey: String, colorHex: String?) {
        instrumentMappings[channelKey, default: InstrumentMapping(channelKey: channelKey, displayName: channelKey)].colorHex = colorHex
        isDirty = true
    }

    func setMappingColorHex(for channelKeys: [String], colorHex: String?) {
        for k in channelKeys { setMappingColorHex(for: k, colorHex: colorHex) }
    }

    func setMappingTrackRole(for channelKeys: [String], trackRole: TrackRole) {
        for k in channelKeys {
            instrumentMappings[k, default: InstrumentMapping(channelKey: k, displayName: k)].trackRole = trackRole
        }
        isDirty = true
    }

    func setMappingVoiceType(for channelKeys: [String], voiceType: VoicePart?) {
        for k in channelKeys {
            instrumentMappings[k, default: InstrumentMapping(channelKey: k, displayName: k)].voiceType = voiceType
        }
        isDirty = true
    }

    func setMappingVocalGender(for channelKeys: [String], gender: VocalGender) {
        for k in channelKeys {
            instrumentMappings[k, default: InstrumentMapping(channelKey: k, displayName: k)].vocalGender = gender
        }
        isDirty = true
    }

    func setMappingVoiceID(for channelKeys: [String], voiceID: String?) {
        for k in channelKeys {
            instrumentMappings[k, default: InstrumentMapping(channelKey: k, displayName: k)].voiceID = voiceID
        }
        isDirty = true
    }

    func setMappingVibratoDepth(for channelKeys: [String], depth: Double) {
        for k in channelKeys {
            instrumentMappings[k, default: InstrumentMapping(channelKey: k, displayName: k)].vibratoDepth = depth
        }
        isDirty = true
    }

    func setMappingVibratoRate(for channelKeys: [String], rate: Double) {
        for k in channelKeys {
            instrumentMappings[k, default: InstrumentMapping(channelKey: k, displayName: k)].vibratoRate = rate
        }
        isDirty = true
    }

    func setMappingVoiceGainDB(for channelKeys: [String], gainDB: Double) {
        for k in channelKeys {
            instrumentMappings[k, default: InstrumentMapping(channelKey: k, displayName: k)].voiceGainDB = gainDB
        }
        isDirty = true
    }

    func portableSoundFontReference(for path: String?) -> (runtimePath: String?, relativePath: String?, fileName: String?) {
        guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return (nil, nil, nil)
        }

        let fileName = (rawPath as NSString).lastPathComponent
        guard let projectURL = fileProjectURL, projectURL.pathExtension.lowercased() != "ows" else {
            return (rawPath, nil, fileName)
        }

        let fm = FileManager.default
        if rawPath.hasPrefix("/") {
            let projectPath = projectURL.standardizedFileURL.path
            let normalizedRawPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            let soundFontsRoot = projectURL.appendingPathComponent("SoundFonts").standardizedFileURL.path + "/"
            if normalizedRawPath.hasPrefix(soundFontsRoot) || normalizedRawPath.hasPrefix(projectPath + "/SoundFonts/") {
                let relativePath = "SoundFonts/\(fileName)"
                return (normalizedRawPath, relativePath, fileName)
            }

            if fm.fileExists(atPath: normalizedRawPath) {
                do {
                    let relativePath = try OWPProjectIO.embedSoundFont(absolutePath: normalizedRawPath, in: projectURL)
                    let embeddedPath = projectURL.appendingPathComponent(relativePath).path
                    return (embeddedPath, relativePath, fileName)
                } catch {
                    NSLog("[SF2 Embed] Failed to embed %@ into %@: %@", normalizedRawPath, projectURL.path, error.localizedDescription)
                }
            }

            return (normalizedRawPath, nil, fileName)
        }

        let embeddedURL = projectURL.appendingPathComponent(rawPath)
        if fm.fileExists(atPath: embeddedURL.path) {
            return (embeddedURL.path, rawPath, fileName)
        }

        return (rawPath, rawPath, fileName)
    }

    func setMappingSoundFontPath(for channelKeys: [String], path: String?) {
        let portable = portableSoundFontReference(for: path)
        for k in channelKeys {
            var m = instrumentMappings[k] ?? InstrumentMapping(channelKey: k, displayName: k)
            m.instrumentSourceType = (path != nil) ? .soundFont : nil
            m.sf2Path = portable.runtimePath
            m.sf2FileName = portable.fileName
            if let runtimePath = portable.runtimePath {
                var sf = m.soundFont ?? SoundFontAssignment()
                sf.sf2RelativePath = portable.relativePath
                sf.sf2FileName = portable.fileName
                sf.resolvedPath = runtimePath
                sf.bankMSB = m.bankMSB
                sf.bankLSB = m.bankLSB
                sf.program = m.program
                m.soundFont = sf
            } else {
                m.soundFont = nil
            }
            instrumentMappings[k] = m
            NSLog("[SF2 Assign] key=%@ runtime=%@ relative=%@ exists=%@",
                  k,
                  portable.runtimePath ?? "nil",
                  portable.relativePath ?? "nil",
                  String(describing: portable.runtimePath.map { FileManager.default.fileExists(atPath: $0) }))
        }
        isDirty = true
    }

    #if canImport(AppKit)
    func pickSoundFont(for channelKey: String) { pickSoundFont(for: [channelKey]) }
    #endif

    #if canImport(AppKit)
    func pickSoundFont(for channelKeys: [String]) {
        let panel = NSOpenPanel()
        panel.title = "Choose SoundFont"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "sf2") ?? .data,
            UTType(filenameExtension: "sf3") ?? .data,
            UTType(filenameExtension: "dls") ?? .data,
        ]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            NSLog("[SF2 Pick] url=%@ path=%@", url.absoluteString, url.path)
            self?.setMappingSoundFontPath(for: channelKeys, path: url.path)
        }
    }
    #endif

    func clearSoundFont(for channelKey: String) { clearSoundFont(for: [channelKey]) }

    func clearSoundFont(for channelKeys: [String]) {
        setMappingSoundFontPath(for: channelKeys, path: nil)
    }

    // MARK: - Sample Browser

    #if canImport(AppKit)
    func pickSampleRootDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setSampleRootDirectory(path: url.path)
        }
    }
    #endif

    func setSampleRootDirectory(path: String?) {
        let p = path ?? ""
        sampleRootDirectoryPath = p
        UserDefaults.standard.set(p, forKey: "sampleRootDirectoryPath")
        if !p.isEmpty { rescanSampleBrowser() }
    }

    func rescanSampleBrowser() {
        guard !sampleRootDirectoryPath.isEmpty else { return }
        isScanningSampleBrowser = true
        let root = sampleRootDirectoryPath
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let rootURL = URL(fileURLWithPath: root)
            var entries: [SampleBrowserEntry] = []
            if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                while let url = enumerator.nextObject() as? URL {
                    let ext = url.pathExtension.lowercased()
                    guard ext == "sf2" || ext == "sf3" || ext == "sfz" else { continue }
                    let rel = url.path
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    entries.append(SampleBrowserEntry(relativePath: rel, fileName: url.lastPathComponent, isDirectory: false, fileSize: size))
                }
            }
            await MainActor.run { [weak self] in
                self?.sampleBrowserEntries = entries.sorted { $0.relativePath < $1.relativePath }
                self?.isScanningSampleBrowser = false
            }
        }
    }

    // MARK: - Audio Unit Instrument Assignment

    func setMappingAudioUnit(for channelKeys: [String], description: AudioComponentDescription, name: String) {
        for k in channelKeys {
            var m = instrumentMappings[k] ?? InstrumentMapping(channelKey: k, displayName: k)
            m.instrumentSourceType = .audioUnit
            m.auComponentType = description.componentType
            m.auComponentSubType = description.componentSubType
            m.auComponentManufacturer = description.componentManufacturer
            m.sf2Path = nil
            m.sf2FileName = nil
            instrumentMappings[k] = m
        }
        isDirty = true
    }

    func clearAudioUnit(for channelKeys: [String]) {
        for k in channelKeys {
            guard var m = instrumentMappings[k] else { continue }
            m.auComponentType = nil
            m.auComponentSubType = nil
            m.auComponentManufacturer = nil
            m.auPresetData = nil
            m.audioUnit = nil
            // If this was the active source, fall back to soundFont
            if m.effectiveSourceType == .audioUnit {
                m.instrumentSourceType = .soundFont
            }
            if m.activeSource == .audioUnit {
                m.activeSource = .soundFont
            }
            instrumentMappings[k] = m
        }
        isDirty = true
    }

    func setMappingActiveSource(for channelKeys: [String], source: InstrumentSourceType) {
        for k in channelKeys {
            guard var m = instrumentMappings[k] else { continue }
            m.activeSource = source
            m.instrumentSourceType = source
            instrumentMappings[k] = m
        }
        isDirty = true
    }

    func setMappingPinnedSource(for channelKeys: [String], pinned: InstrumentSourceType?) {
        for k in channelKeys {
            guard var m = instrumentMappings[k] else { continue }
            m.pinnedSource = pinned
            // Sync legacy field so the engine respects the pin
            m.instrumentSourceType = m.effectiveSource
            instrumentMappings[k] = m
        }
        isDirty = true
    }

    /// Open the Audio Unit plugin UI for a given mapping key.
    /// Instantiates the AU if needed, starts the engine, and shows the floating panel.
    func openAudioUnitUI(for mappingKey: String) {
        guard let mapping = instrumentMappings[mappingKey],
              mapping.audioComponentDescription != nil else { return }
        let title = mapping.displayName.isEmpty ? "Audio Unit" : mapping.displayName
        playbackEngine.ensureAudioUnit(for: mappingKey, mapping: mapping) { [weak self] auAudioUnit in
            if let auAudioUnit {
                showAudioUnitPluginPanel(audioUnit: auAudioUnit, title: title) {
                    self?.saveAUPreset(for: mappingKey)
                }
            }
        }
    }

    /// Save the current AU preset state for a mapping key.
    /// Call this after the user configures the AU plugin (e.g. when the plugin panel closes).
    /// Uses PropertyListSerialization since AU fullState may contain Data values
    /// that are not valid JSON.
    func saveAUPreset(for mappingKey: String) {
        playbackEngine.getAudioUnit(for: mappingKey) { [weak self] auAudioUnit in
            guard let self, let auAudioUnit else { return }
            guard let fullState = auAudioUnit.fullState else { return }
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: fullState, format: .binary, options: 0)
                self.instrumentMappings[mappingKey]?.auPresetData = data
                self.isDirty = true
                NSLog("[Store] Saved AU preset for %@ (%d bytes)", mappingKey, data.count)
            } catch {
                NSLog("[Store] Failed to save AU preset for %@: %@", mappingKey, error.localizedDescription)
            }
        }
    }

    #if canImport(AppKit)
    func addAudioClipFromPanel(trackKey: String?, startTick: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .aiff, .mp3]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importAudioClipFromDrop(url: url, atTick: startTick)
        }
    }
    #endif

    /// Import an audio file dropped or selected into the WAV arrangement pane.
    /// Computes duration from the audio file and creates an AudioClip at the given tick.
    @discardableResult
    func importAudioClipFromDrop(url: URL, atTick tick: Int) -> AudioClip? {
        // Read audio file to determine duration
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            statusMessage = "Could not read audio file: \(url.lastPathComponent)"
            return nil
        }
        let sampleRate = audioFile.processingFormat.sampleRate
        let durationSeconds = Double(audioFile.length) / max(1, sampleRate)

        // Convert seconds to ticks using the tempo at the insertion point
        let tpq = max(1, ticksPerQuarter)
        let bpm = max(20, tempoBPM)
        let durationTicks = max(tpq, Int(durationSeconds * Double(tpq) * (bpm / 60.0)))

        let clip = AudioClip(
            displayName: url.deletingPathExtension().lastPathComponent,
            filePath: url.path,
            startTick: tick,
            durationTicks: durationTicks
        )
        pianoRollAudioClips.append(clip)
        isDirty = true
        statusMessage = "Imported: \(url.lastPathComponent)"
        return clip
    }

    /// Remove an audio clip by ID.
    func removeAudioClip(id: UUID) {
        pianoRollAudioClips.removeAll { $0.id == id }
        isDirty = true
    }

    /// Duplicate an audio clip, placing the copy immediately after the original.
    func duplicateAudioClip(id: UUID) {
        guard let clip = pianoRollAudioClips.first(where: { $0.id == id }) else { return }
        var copy = clip
        copy.id = UUID()
        copy.displayName = clip.displayName + " copy"
        copy.startTick = clip.startTick + clip.durationTicks  // place right after original
        pianoRollAudioClips.append(copy)
        isDirty = true
    }

    /// Mute all MIDI tracks that have notes overlapping with the given audio clip's time range.
    func muteOverlappingMIDI(for clipID: UUID) {
        guard let clip = pianoRollAudioClips.first(where: { $0.id == clipID }) else { return }
        let clipStart = clip.startTick
        let clipEnd = clip.startTick + clip.durationTicks

        // Find all track indices with notes that overlap
        var overlappingTracks = Set<Int>()
        for note in pianoRollNotes {
            let noteEnd = note.startTick + note.duration
            // Check overlap: note starts before clip ends AND note ends after clip starts
            if note.startTick < clipEnd && noteEnd > clipStart {
                overlappingTracks.insert(note.trackIndex)
            }
        }

        // Mute those tracks
        for trackIdx in overlappingTracks {
            mutedTracks.insert(trackIdx)
        }

        let count = overlappingTracks.count
        statusMessage = "Muted \(count) track\(count == 1 ? "" : "s") overlapping with \(clip.displayName)"
        isDirty = true
    }

    // MARK: - Lyric Alignment

    func updateSelectedLibrettoContent(_ newContent: String) {
        guard let selectedLibrettoID,
              let idx = librettoFiles.firstIndex(where: { $0.id == selectedLibrettoID }) else { return }
        librettoFiles[idx].content = newContent
        let songPath = librettoFiles[idx].relativePath
        updateLyricsForSong(atPath: songPath, lyrics: newContent)
        isDirty = true
    }

    func updateLyricsForSong(atPath path: String, lyrics: String) {
        if let idx = librettoFiles.firstIndex(where: { $0.relativePath == path }) {
            librettoFiles[idx].content = lyrics
        }
        if let songIdx = songAssets.firstIndex(where: { $0.relativePath == path }),
           let activeID = songAssets[songIdx].document.activeVersionID,
           let vIdx = songAssets[songIdx].document.versions.firstIndex(where: { $0.id == activeID }) {
            songAssets[songIdx].document.versions[vIdx].lyrics = lyrics
            songAssets[songIdx].document.versions[vIdx].updatedAt = Date()
            songAssets[songIdx].document.updatedAt = Date()
        }
        dirtySongPaths.insert(path)
        scheduleDatabaseSync(for: path)
        scheduleAutoSaveIfNeeded()
    }

    func removeLyricAlignment(noteID: UUID) {
        for i in pianoRollLyricAlignments.indices {
            pianoRollLyricAlignments[i].entries.removeAll { $0.noteID == noteID }
        }
        isDirty = true
    }

    func remapLyricAlignments(noteRemap: [UUID: UUID], removedNoteIDs: Set<UUID> = []) {
        for i in pianoRollLyricAlignments.indices {
            pianoRollLyricAlignments[i].entries.removeAll { removedNoteIDs.contains($0.noteID) }
            for j in pianoRollLyricAlignments[i].entries.indices {
                if let newID = noteRemap[pianoRollLyricAlignments[i].entries[j].noteID] {
                    pianoRollLyricAlignments[i].entries[j].noteID = newID
                }
            }
        }
    }

    func updateLibrettoFromSyllableEdit(noteID: UUID, newSyllable: String, oldSyllable: String? = nil) {
        // Stub: updates libretto text when user edits a syllable on the piano roll
    }

    func buildLyricAlignmentsFromNotes(trackKey: String, syllabifiedWords: [(word: String, syllables: [String])]) {
        // Stub: builds alignment from syllable list
    }

    // MARK: - Music Intelligence Engine

    func analyzeCurrentSongStructure() {
        guard !pianoRollNotes.isEmpty else { musicEngineStatus = "No notes to analyze."; return }
        musicEngineStatus = "Analyzing structure..."
        let capturedSongID = selectedMidiID
        Task {
            let phrases = PhraseDetector.detectPhrases(
                notes: pianoRollNotes, tempoEvents: pianoRollTempoEvents,
                timeSignatures: pianoRollTimeSignatures, ticksPerQuarter: ticksPerQuarter
            )
            let sections = StructureAnalyzer.analyze(
                phrases: phrases, notes: pianoRollNotes,
                tempoEvents: pianoRollTempoEvents, timeSignatures: pianoRollTimeSignatures,
                ticksPerQuarter: ticksPerQuarter
            )
            let key = KeyDetector.detectKeyWithFallback(
                notes: pianoRollNotes, keySignatures: pianoRollKeySignatures
            )
            let chords = ChordProgressionAnalyzer.analyze(
                notes: pianoRollNotes, timeSignatures: pianoRollTimeSignatures,
                ticksPerQuarter: ticksPerQuarter, key: key
            )
            guard selectedMidiID == capturedSongID else { return }
            currentStructuralAnalysis = StructuralAnalysis(phrases: phrases, sections: sections, detectedKey: key)
            currentChordProgression = chords
            musicEngineStatus = "Analysis complete: \(phrases.count) phrases, \(sections.count) sections, key: \(key?.displayName ?? "Unknown")"
        }
    }

    func performSmartAlignment() {
        guard !pianoRollNotes.isEmpty else { musicEngineStatus = "No notes for alignment."; return }
        guard let lyrics = selectedLibrettoFile?.content, !lyrics.isEmpty else {
            musicEngineStatus = "No lyrics for alignment."; return
        }
        musicEngineStatus = "Aligning lyrics..."
        let capturedSongID = selectedMidiID
        Task {
            let syllabified = SyllabificationService.syllabify(lyrics)
            let result = SmartLyricAligner.align(
                syllabifiedWords: syllabified, notes: pianoRollNotes,
                tempoEvents: pianoRollTempoEvents, timeSignatures: pianoRollTimeSignatures,
                ticksPerQuarter: ticksPerQuarter, lyricText: lyrics
            )
            guard selectedMidiID == capturedSongID else { return }
            smartAlignmentPreview = result
            musicEngineStatus = "Alignment preview ready (\(result.assignments.count) assignments)."
        }
    }

    #if canImport(MLXLLM)
    func performLLMAlignment() {
        guard !pianoRollNotes.isEmpty else { musicEngineStatus = "No notes for LLM alignment."; return }
        guard let lyrics = selectedLibrettoFile?.content, !lyrics.isEmpty else {
            musicEngineStatus = "No lyrics for LLM alignment."; return
        }
        musicEngineStatus = "LLM aligning lyrics..."
        Task {
            guard await ensureLLMModelReady() else {
                musicEngineStatus = "LLM model not available."
                return
            }
            let vocalIndices = resolveVocalTrackIndices()
            let notesForAlignment = pianoRollNotes.filter { vocalIndices.isEmpty || vocalIndices.contains($0.trackIndex) }
            let syllabified = SyllabificationService.syllabify(lyrics)
            let prompt = LLMLyricAligner.buildAlignmentPrompt(
                syllabifiedWords: syllabified, notes: notesForAlignment, ticksPerQuarter: ticksPerQuarter
            )
            llmGenerating = true
            do {
                let response = try await llmClient.generate(prompt: prompt.user, systemPrompt: prompt.system)
                let parsed = LLMLyricAligner.parseAlignmentResponse(response, syllabifiedWords: syllabified, noteCount: notesForAlignment.count)
                let result = LLMLyricAligner.toSmartAlignmentResult(parsed, notes: notesForAlignment)
                smartAlignmentPreview = result
                musicEngineStatus = "LLM alignment preview ready."
            } catch {
                musicEngineStatus = "LLM alignment failed: \(error.localizedDescription)"
            }
            llmGenerating = false
        }
    }
    #endif

    func acceptSmartAlignmentPreview() {
        guard let preview = smartAlignmentPreview else { return }
        pushUndoState(label: "Apply Lyric Alignment")
        // Apply syllable assignments to notes via lyric alignment entries
        for assignment in preview.assignments {
            if let noteIdx = pianoRollNotes.firstIndex(where: { $0.id == assignment.noteID }) {
                pianoRollNotes[noteIdx].lyricSyllable = assignment.syllable
            }
        }
        smartAlignmentPreview = nil
        isDirty = true
        musicEngineStatus = "Alignment applied."
    }

    func rejectSmartAlignmentPreview() {
        smartAlignmentPreview = nil
        musicEngineStatus = "Alignment discarded."
    }

    func acceptMelodicMutation() {
        guard let mutation = proposedMelodicMutation else { return }
        pushUndoState(label: "Apply Melodic Mutation")
        var notes = pianoRollNotes
        notes.append(contentsOf: mutation.notesToInsert)
        notes.removeAll { mutation.notesToRemove.contains($0.id) }
        pianoRollNotes = notes.sorted {
            if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            return $0.pitch < $1.pitch
        }
        proposedMelodicMutation = nil
        isDirty = true
        musicEngineStatus = "Melodic mutation applied."
    }

    func rejectMelodicMutation() {
        proposedMelodicMutation = nil
        musicEngineStatus = "Melodic mutation discarded."
    }

    func fitMIDIToLyrics() {
        guard !pianoRollNotes.isEmpty, let lyrics = selectedLibrettoFile?.content, !lyrics.isEmpty else { return }
        let syllables = SyllabificationService.syllabify(lyrics)
        let totalSyllables = syllables.reduce(0) { $0 + $1.syllables.count }
        let vocalIndices = resolveVocalTrackIndices()
        let vocalNotes = pianoRollNotes.filter { vocalIndices.isEmpty || vocalIndices.contains($0.trackIndex) }
        if totalSyllables != vocalNotes.count {
            proposedMelodicMutation = MelodicMutator.propose(
                currentNotes: vocalNotes, targetSyllableCount: totalSyllables,
                timeSignatures: pianoRollTimeSignatures, ticksPerQuarter: ticksPerQuarter
            )
            musicEngineStatus = "Melodic mutation proposed: \(vocalNotes.count) notes → \(totalSyllables) syllables."
        }
    }

    func generateHarmonization() {
        guard !pianoRollNotes.isEmpty else { musicEngineStatus = "No notes to harmonize."; return }
        let key = currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
        musicEngineStatus = "Generating harmonization..."
        let capturedSongID = selectedMidiID
        Task {
            let result = HarmonyEngine.harmonize(
                melody: pianoRollNotes, key: key,
                chords: currentChordProgression?.chords,
                ticksPerQuarter: ticksPerQuarter
            )
            guard selectedMidiID == capturedSongID else { return }
            currentHarmonization = result
            musicEngineStatus = "Harmonization ready (\(result.voicings.count) voicings, score: \(String(format: "%.0f%%", result.score * 100)))."
        }
    }

    func acceptHarmonization() {
        guard let harm = currentHarmonization else { return }
        pushUndoState(label: "Apply Harmonization")
        var notes = pianoRollNotes
        let maxTrack = (pianoRollNotes.map(\.trackIndex).max() ?? 0) + 1
        for voicing in harm.voicings {
            for (partIdx, pitch) in voicing.pitches.enumerated() {
                notes.append(PianoRollNote(
                    trackIndex: maxTrack + partIdx, channel: 0,
                    pitch: pitch, velocity: 80,
                    startTick: voicing.tick, duration: voicing.durationTicks
                ))
            }
        }
        pianoRollNotes = notes.sorted {
            if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            return $0.pitch < $1.pitch
        }
        currentHarmonization = nil
        isDirty = true
        musicEngineStatus = "Harmonization applied."
    }

    func rejectHarmonization() {
        currentHarmonization = nil
        musicEngineStatus = "Harmonization discarded."
    }

    func generateInstrumentPart(instrument: String, style: InstrumentPartGenerator.GenerationStyle) {
        guard !pianoRollNotes.isEmpty else { musicEngineStatus = "No notes for part generation."; return }
        let key = currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
        musicEngineStatus = "Generating \(instrument) part..."
        let capturedSongID = selectedMidiID
        Task {
            let chords = currentChordProgression?.chords ?? []
            let maxTrack = (pianoRollNotes.map(\.trackIndex).max() ?? 0) + 1
            let partNotes = InstrumentPartGenerator.generate(
                melody: pianoRollNotes, chords: chords, key: key,
                instrument: instrument, style: style,
                trackIndex: maxTrack, channel: 0, ticksPerQuarter: ticksPerQuarter
            )
            guard selectedMidiID == capturedSongID else { return }
            generatedPart = GeneratedPart(instrumentName: instrument, style: style.rawValue, notes: partNotes, trackIndex: maxTrack, channel: 0)
            musicEngineStatus = "Part ready: \(partNotes.count) notes for \(instrument)."
        }
    }

    func acceptGeneratedPart() {
        guard let part = generatedPart else { return }
        pushUndoState(label: "Apply Generated Part")
        pianoRollNotes.append(contentsOf: part.notes)
        pianoRollNotes.sort {
            if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            return $0.pitch < $1.pitch
        }
        generatedPart = nil
        isDirty = true
        musicEngineStatus = "Part applied."
    }

    func rejectGeneratedPart() {
        generatedPart = nil
        musicEngineStatus = "Part discarded."
    }

    func resolveVocalTrackIndices() -> Set<Int> {
        var result = Set<Int>()
        for (pairKey, mappingKey) in pianoRollChannelKeyByTrackChannel {
            guard let mapping = instrumentMappings[mappingKey], mapping.trackRole == .vocal else { continue }
            let parts = pairKey.split(separator: ":")
            if parts.count == 2, let trackIndex = Int(parts[0]) { result.insert(trackIndex) }
        }
        return result
    }

    // MARK: - LLM Methods

    #if canImport(MLXLLM)
    func loadLLMModel(id: String) {
        Task { await llmClient.loadModel(id: id) }
    }

    func unloadLLMModel() {
        llmClient.unloadModel()
    }

    func ensureLLMModelReady() async -> Bool {
        if case .ready = llmClient.modelState { return true }
        await llmClient.loadModel(id: preferredLLMModelID)
        if case .ready = llmClient.modelState { return true }
        return false
    }

    func evaluateLyricMelodyFit() {
        guard !pianoRollNotes.isEmpty, let lyrics = selectedLibrettoFile?.content else { return }
        llmGenerating = true
        Task {
            defer { llmGenerating = false }
            guard await ensureLLMModelReady() else { return }
            do {
                let key = currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
                let summary = LLMMusicalReasoner.buildMelodySummary(notes: pianoRollNotes, key: key, ticksPerQuarter: ticksPerQuarter)
                let prompt = LLMMusicalReasoner.evaluateLyricMelodyFitPrompt(lyrics: lyrics, melodySummary: summary, key: key)
                llmResponse = try await llmClient.generate(prompt: prompt.user, systemPrompt: prompt.system)
            } catch {
                llmResponse = "Error: \(error.localizedDescription)"
            }
        }
    }

    func suggestChordsWithLLM() {
        guard !pianoRollNotes.isEmpty else { return }
        llmGenerating = true
        Task {
            defer { llmGenerating = false }
            guard await ensureLLMModelReady() else { return }
            do {
                let key = currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
                let summary = LLMMusicalReasoner.buildMelodySummary(notes: pianoRollNotes, key: key, ticksPerQuarter: ticksPerQuarter)
                let prompt = LLMMusicalReasoner.suggestChordProgressionPrompt(melodySummary: summary, key: key, style: "")
                llmResponse = try await llmClient.generate(prompt: prompt.user, systemPrompt: prompt.system)
            } catch {
                llmResponse = "Error: \(error.localizedDescription)"
            }
        }
    }

    func describeStyleWithLLM() {
        guard !pianoRollNotes.isEmpty else { return }
        llmGenerating = true
        Task {
            defer { llmGenerating = false }
            guard await ensureLLMModelReady() else { return }
            do {
                let key = currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
                let chords = currentChordProgression?.chords ?? []
                let prompt = LLMMusicalReasoner.describeMusicalStylePrompt(key: key, chords: chords, tempoRange: tempoBPM...tempoBPM)
                llmResponse = try await llmClient.generate(prompt: prompt.user, systemPrompt: prompt.system)
            } catch {
                llmResponse = "Error: \(error.localizedDescription)"
            }
        }
    }

    func suggestArrangementWithLLM() {
        guard !pianoRollNotes.isEmpty else { return }
        llmGenerating = true
        Task {
            defer { llmGenerating = false }
            guard await ensureLLMModelReady() else { return }
            do {
                let key = currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
                let chords = currentChordProgression?.chords ?? []
                let summary = LLMMusicalReasoner.buildMelodySummary(notes: pianoRollNotes, key: key, ticksPerQuarter: ticksPerQuarter)
                let prompt = LLMMusicalReasoner.suggestArrangementPrompt(melodySummary: summary, chords: chords, key: key, availableInstruments: [])
                llmResponse = try await llmClient.generate(prompt: prompt.user, systemPrompt: prompt.system)
            } catch {
                llmResponse = "Error: \(error.localizedDescription)"
            }
        }
    }

    func askLLMFreeform(prompt userQuery: String) {
        llmGenerating = true
        Task {
            defer { llmGenerating = false }
            guard await ensureLLMModelReady() else { return }
            do {
                var contextParts: [String] = []
                if let key = currentStructuralAnalysis?.detectedKey { contextParts.append("Key: \(key.displayName)") }
                if let chords = currentChordProgression { contextParts.append("Chords: \(chords.chords.prefix(8).map(\.displayName).joined(separator: ", "))") }
                contextParts.append("Tempo: \(Int(tempoBPM)) BPM")
                contextParts.append("Notes: \(pianoRollNotes.count)")
                let context = contextParts.joined(separator: ". ")
                let fullPrompt = "Musical context: \(context)\n\nQuestion: \(userQuery)"
                llmResponse = try await llmClient.generate(prompt: fullPrompt, systemPrompt: "You are a knowledgeable music theory expert.")
            } catch {
                llmResponse = "Error: \(error.localizedDescription)"
            }
        }
    }
    #endif

    // MARK: - Style & Composition

    func analyzeMusicalStyle() {
        guard !pianoRollNotes.isEmpty else { return }
        let key = currentStructuralAnalysis?.detectedKey ?? KeyDetector.detectKey(notes: pianoRollNotes) ?? DetectedKey(root: 0, isMinor: false, confidence: 0)
        let melodic = StyleAnalyzer.analyzeMelodicProfile(notes: pianoRollNotes, ticksPerQuarter: ticksPerQuarter)
        let rhythmic = StyleAnalyzer.analyzeRhythmicProfile(notes: pianoRollNotes, ticksPerQuarter: ticksPerQuarter)
        let harmonic = StyleAnalyzer.analyzeHarmonicComplexity(chords: currentChordProgression?.chords ?? [], key: key)
        detectedStyle = MusicalStyleProfile(melodicProfile: melodic, rhythmicProfile: rhythmic, harmonicComplexity: harmonic, genreHints: [])
    }

    func composeMelody(constraints: MelodyConstraints) {
        let melody = CompositionEngine.generateMelody(constraints: constraints)
        composedMelody = melody
    }

    func registerLeitmotif(name: String, noteIDs: [UUID]) {
        let selectedNotes = pianoRollNotes.filter { noteIDs.contains($0.id) }.sorted { $0.startTick < $1.startTick }
        guard !selectedNotes.isEmpty else { return }
        // Extract pitch/rhythm patterns from selected notes
        let pitchPattern = selectedNotes.map(\.pitch)
        let rhythmPattern = selectedNotes.map(\.duration)
        let intervals = zip(pitchPattern.dropFirst(), pitchPattern).map { $0 - $1 }
        let motif = Leitmotif(id: UUID(), name: name, noteIDs: noteIDs, pitchPattern: pitchPattern, rhythmPattern: rhythmPattern, intervalPattern: intervals)
        leitmotifs.append(motif)
    }

    func generateLeitmotifVariation(id: UUID, type: VariationType, semitones: Int = 0) {
        guard let motif = leitmotifs.first(where: { $0.id == id }) else { return }
        // Convert motif to notes for transformation
        var motifNotes: [PianoRollNote] = []
        var tick = 0
        for (i, pitch) in motif.pitchPattern.enumerated() {
            let dur = i < motif.rhythmPattern.count ? motif.rhythmPattern[i] : ticksPerQuarter
            motifNotes.append(PianoRollNote(trackIndex: 0, channel: 0, pitch: pitch, velocity: 80, startTick: tick, duration: dur))
            tick += dur
        }
        let variation = CompositionEngine.transformMotif(notes: motifNotes, type: type, semitones: semitones, ticksPerQuarter: ticksPerQuarter)
        composedMelody = variation
    }

    func acceptComposedMelody() {
        guard let melody = composedMelody else { return }
        pushUndoState(label: "Accept Composed Melody")
        pianoRollNotes.append(contentsOf: melody)
        pianoRollNotes.sort {
            if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            return $0.pitch < $1.pitch
        }
        composedMelody = nil
        isDirty = true
    }

    func rejectComposedMelody() {
        composedMelody = nil
    }

    // MARK: - MidiAI (Stubs)

    func midiAIGenerateFromText(_ prompt: String, maxTokens: Int = 1024, temperature: Double = 0.95) {
        midiAIStatusMessage = "MidiAI not available in Novotro Score."
    }

    func midiAIGenerateContinuation(maxTokens: Int = 512, temperature: Double = 0.95) {
        midiAIStatusMessage = "MidiAI not available in Novotro Score."
    }

    func midiAIGenerateAccompaniment(maxTokens: Int = 512, temperature: Double = 0.95) {
        midiAIStatusMessage = "MidiAI not available in Novotro Score."
    }

    func midiAIGenerateMelody(lyrics: String, tempoBPM: Int? = nil, key: String? = nil) {
        midiAIStatusMessage = "MidiAI not available in Novotro Score."
    }

    // MARK: - Version Management

    func selectPreviousMidi() {
        guard let current = selectedMidiID, let idx = midiAssets.firstIndex(where: { $0.id == current }), idx > 0 else { return }
        setSelectedMidi(id: midiAssets[idx - 1].id)
    }

    func selectNextMidi() {
        guard let current = selectedMidiID, let idx = midiAssets.firstIndex(where: { $0.id == current }), idx < midiAssets.count - 1 else { return }
        setSelectedMidi(id: midiAssets[idx + 1].id)
    }

    func addSong(relativeTo referenceID: MidiAsset.ID?, position: SongInsertPosition) {
        // Stub
    }

    func deleteSong(midiID: MidiAsset.ID) {
        if let asset = songAssets.first(where: { $0.id == midiID }) {
            dirtySongPaths.remove(asset.relativePath)
        }
        songAssets.removeAll { $0.id == midiID }
        librettoFiles.removeAll { file in songAssets.allSatisfy { $0.relativePath != file.relativePath } }
        if selectedMidiID == midiID { setSelectedMidi(id: songAssets.first?.id) }
        isDirty = true
    }

    func snapshotSongVersion(for midiID: MidiAsset.ID, label: String? = nil, saveType: VersionSaveType = .snapshot, markDirty: Bool = true) {
        guard let idx = songAssets.firstIndex(where: { $0.id == midiID }) else { return }
        let songPath = songAssets[idx].relativePath

        // Build a snapshot from current live state if this is the selected song
        let playback: OWSPlaybackSnapshot?
        if midiID == selectedMidiID {
            playback = buildCurrentPlaybackSnapshot()
        } else {
            playback = songAssets[idx].document.activeVersion()?.playback
        }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let defaultLabel = label ?? "\(saveType == .autosave ? "Autosave" : "Snapshot") \(formatter.string(from: now))"

        let lyrics = librettoFiles.first(where: { $0.relativePath == songPath })?.content ?? ""

        let version = OWSVersionPayload(
            id: UUID(),
            label: defaultLabel,
            createdAt: now,
            updatedAt: now,
            lyrics: lyrics,
            saveType: saveType,
            userLabel: label,
            isBookmarked: false,
            playback: playback
        )

        songAssets[idx].document.versions.insert(version, at: 0)
        songAssets[idx].document.normalize()
        dirtySongPaths.insert(songPath)
        if markDirty { isDirty = true }
    }

    func versions(for midiID: MidiAsset.ID) -> [MidiAsset] {
        return []
    }

    func switchSongVersion(for midiID: MidiAsset.ID, to targetVersionID: MidiAsset.ID) {
        // Stub — use rollbackToVersion for version switching
    }

    func versionHistory(for songPath: String) -> [OWSVersionPayload] {
        songAssets.first(where: { $0.relativePath == songPath })?.document.versions ?? []
    }

    func renameVersion(songPath: String, versionID: UUID, newLabel: String) {
        guard let songIdx = songAssets.firstIndex(where: { $0.relativePath == songPath }),
              let vIdx = songAssets[songIdx].document.versions.firstIndex(where: { $0.id == versionID }) else { return }
        songAssets[songIdx].document.versions[vIdx].userLabel = newLabel
        songAssets[songIdx].document.versions[vIdx].updatedAt = Date()
        dirtySongPaths.insert(songPath)
        isDirty = true
    }

    func toggleVersionBookmark(songPath: String, versionID: UUID) {
        guard let songIdx = songAssets.firstIndex(where: { $0.relativePath == songPath }),
              let vIdx = songAssets[songIdx].document.versions.firstIndex(where: { $0.id == versionID }) else { return }
        songAssets[songIdx].document.versions[vIdx].isBookmarked.toggle()
        dirtySongPaths.insert(songPath)
        isDirty = true
    }

    func rollbackToVersion(songPath: String, versionID: UUID) {
        guard let songIdx = songAssets.firstIndex(where: { $0.relativePath == songPath }),
              let version = songAssets[songIdx].document.versions.first(where: { $0.id == versionID }),
              let playback = version.playback else { return }

        // If this is the currently selected song, restore live state
        if songAssets[songIdx].id == selectedMidiID {
            // Stop any active playback before mutating state
            if isPlaying { stopPlayback() }

            pianoRollNotes = playback.notes
            pianoRollTrackNames = playback.trackNames
            pianoRollChannelPrograms = playback.channelPrograms
            pianoRollTrackChannelPrograms = playback.trackChannelPrograms
            pianoRollLyricCues = playback.lyricCues
            pianoRollLyricAlignments = playback.lyricAlignments ?? []
            pianoRollAudioClips = playback.audioClips
            pianoRollTempoEvents = playback.tempoEvents
            ticksPerQuarter = max(1, playback.ticksPerQuarter)
            pianoRollLengthTicks = max(playback.lengthTicks, ticksPerQuarter * 8)
            tempoBPM = pianoRollTempoEvents.first?.bpm ?? 112
            pianoRollTimeSignatures = playback.timeSignatureEvents ?? [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
            pianoRollKeySignatures = playback.keySignatureEvents ?? [KeySignatureEvent(tick: 0, sharpsFlats: 0, isMinor: false)]
            pianoRollMarkers = playback.markers ?? []
            channelPan = playback.channelPan ?? [:]
            pianoRollAutomation = playback.automationData ?? PianoRollAutomationData()
            scoreAnnotations = playback.scoreAnnotations ?? []

            // Restore lyrics
            if let libIdx = librettoFiles.firstIndex(where: { $0.relativePath == songPath }) {
                librettoFiles[libIdx].content = version.lyrics
            }

            // Rebuild channel key mapping from restored track names and notes
            pianoRollChannelKeyByTrackChannel = [:]
            pianoRollChannelNames = [:]
            for (trackIndex, name) in pianoRollTrackNames {
                var channels = Set(pianoRollNotes.filter { $0.trackIndex == trackIndex }.map(\.channel))
                // Ensure every named track has at least one entry even when empty
                if channels.isEmpty { channels.insert(0) }
                for ch in channels {
                    let pairKey = "\(trackIndex):\(ch)"
                    let baseKey = normalizedChannelKey(from: name, fallbackTrack: trackIndex, fallbackChannel: ch)
                    pianoRollChannelKeyByTrackChannel[pairKey] = baseKey
                    pianoRollChannelNames[ch] = name
                }
            }

            // Merge document-level instrument mappings
            if let songIdx = songAssets.firstIndex(where: { $0.relativePath == songPath }) {
                for (k, v) in OWPProjectIO.normalizeProjectInstrumentMappings(songAssets[songIdx].document.instrumentMappings) {
                    instrumentMappings[k] = v
                }
            }

            // Clear stale override so persistCurrentMidiOverrideIfNeeded writes fresh data
            pianoRollOverrides.removeValue(forKey: songPath)

            // Clear undo stack — snapshots belong to the pre-rollback state
            undoStack.removeAll()
            redoStack.removeAll()
            selectedNoteIDs.removeAll()

            // Rebuild project channel registry with correct channel key mapping
            rebuildProjectChannelRegistry()
        }

        // Update active version ID
        songAssets[songIdx].document.activeVersionID = versionID
        dirtySongPaths.insert(songPath)
        isDirty = true
    }

    func deleteVersion(songPath: String, versionID: UUID) {
        guard let songIdx = songAssets.firstIndex(where: { $0.relativePath == songPath }) else { return }

        let wasActive = songAssets[songIdx].document.activeVersionID == versionID
        let isSelectedSong = songAssets[songIdx].id == selectedMidiID

        // If deleting the active version, switch to the next available version first
        if wasActive {
            let others = songAssets[songIdx].document.versions.filter { $0.id != versionID }
            if let nextActive = others.first {
                songAssets[songIdx].document.activeVersionID = nextActive.id
            }
        }

        songAssets[songIdx].document.versions.removeAll { $0.id == versionID }
        songAssets[songIdx].document.normalize()

        // If the deleted version was active for the selected song, restore live state
        // from the new active version so the UI doesn't show stale data.
        if wasActive && isSelectedSong {
            if let newActiveID = songAssets[songIdx].document.activeVersionID {
                rollbackToVersion(songPath: songPath, versionID: newActiveID)
            } else {
                // No versions left — clear live state to avoid showing deleted data
                pianoRollNotes.removeAll()
                pianoRollTrackNames.removeAll()
            }
        }

        dirtySongPaths.insert(songPath)
        isDirty = true
    }

    var hasPreviousVersionForSelectedSong: Bool {
        guard let path = selectedMidiAsset?.relativePath else { return false }
        return versionHistory(for: path).count > 1
    }

    func restorePreviousVersionForSelectedSong() {
        guard let path = selectedMidiAsset?.relativePath else { return }
        let versions = versionHistory(for: path)
        guard versions.count > 1 else { return }
        // Rollback to the second version (previous)
        rollbackToVersion(songPath: path, versionID: versions[1].id)
    }

    var selectedSongVersionLabel: String? {
        guard let path = selectedMidiAsset?.relativePath,
              let songAsset = songAssets.first(where: { $0.relativePath == path }),
              let activeID = songAsset.document.activeVersionID,
              let version = songAsset.document.versions.first(where: { $0.id == activeID }) else { return nil }
        return version.displayName
    }

    // MARK: - Step Input

    func insertStepNote(pitch: Int, velocity: Int = 100) {
        // Batch rapid step inputs into a single undo entry (same pattern as handleMIDINoteInput)
        let now = Date()
        if now.timeIntervalSince(lastStepUndoPushTime) > 0.05 {
            pushUndoState(label: "Step Input")
            lastStepUndoPushTime = now
        }
        let note = PianoRollNote(
            trackIndex: stepInputTrackIndex, channel: stepInputChannel,
            pitch: pitch, velocity: velocity,
            startTick: stepInputTick, duration: stepInputDuration
        )
        pianoRollNotes.append(note)
        stepInputTick += stepInputDuration
        isDirty = true
    }

    // MARK: - Misc Helpers

    func cueNotesForSelectedSection() -> String {
        guard let section = selectedLibrettoFile else { return "" }
        return cueMappings.first(where: { $0.sectionPath == section.relativePath })?.notes ?? ""
    }

    func mappedMidiForSelectedSection() -> MidiAsset? {
        guard let section = selectedLibrettoFile else { return nil }
        let midiPath = cueMappings.first(where: { $0.sectionPath == section.relativePath })?.midiPath
        return midiAssets.first(where: { $0.relativePath == midiPath })
    }

    // Track filter change notification (called from SwiftUI .onChange)
    func trackFilterDidChange() {
        updatePreviewMappingForTrackFilter()
    }

    // Vocal track rendered clip check (stub)
    func renderedVocalClipExists(for trackKey: String) -> Bool { false }

    // Voice synthesis service (stub for toolbar rendering state)
    @ObservationIgnored var voiceSynthesisService = VoiceSynthesisService()

    // Auto-render vocal tracks (stub)
    func autoRenderVocalTracksIfNeeded() async {}

    // MARK: - Normalized Channel Key

    func normalizedChannelKey(from displayName: String, fallbackTrack: Int, fallbackChannel: Int) -> String {
        let preprocessed = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\((copy|instance|alt|take)\s*\d*\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(copy|instance|alt|take)\s*\d*$"#, with: "", options: .regularExpression)

        let normalized = preprocessed
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)

        if normalized.isEmpty {
            return "track-\(fallbackTrack + 1)-channel-\(fallbackChannel + 1)"
        }
        return normalized
    }

    /// Returns a copy of `instrumentMappings` with any broken SF2 paths resolved.
    /// Fast path only: (1) check absolute path, (2) try relative to sampleRootDirectoryPath.
    /// The slow fallback search runs in the background and fixes mappings asynchronously.
    private func resolvedInstrumentMappings() -> [String: InstrumentMapping] {
        let fm = FileManager.default
        let root = sampleRootDirectoryPath
        var resolved = instrumentMappings
        var needsPersist = false
        var brokenMappings: [(key: String, fileName: String)] = []

        for (key, var mapping) in resolved {
            guard mapping.effectiveSourceType == .soundFont else { continue }
            guard let sf2 = mapping.sf2Path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sf2.isEmpty else { continue }

            // (1) Absolute path exists — all good
            if sf2.hasPrefix("/"), fm.fileExists(atPath: sf2) { continue }

            // (2) Relative path — resolve against sample root
            if !sf2.hasPrefix("/"), !root.isEmpty {
                let absolutePath = (root as NSString).appendingPathComponent(sf2)
                if fm.fileExists(atPath: absolutePath) {
                    mapping.sf2Path = absolutePath
                    mapping.sf2FileName = (absolutePath as NSString).lastPathComponent
                    resolved[key] = mapping
                    needsPersist = true
                    continue
                }
            }

            // (3) Queue for background search — don't block main thread
            let fileName = mapping.sf2FileName ?? (sf2 as NSString).lastPathComponent
            if !fileName.isEmpty {
                brokenMappings.append((key: key, fileName: fileName))
            }
        }

        // Auto-fix persisted mappings so they don't break again
        if needsPersist {
            for (key, mapping) in resolved {
                instrumentMappings[key] = mapping
            }
            isDirty = true
        }

        // Launch background search for broken paths (won't block playback)
        if !brokenMappings.isEmpty {
            let searchRoot = sampleRootDirectoryPath
            Task { @MainActor [weak self] in
                let results = await Task.detached(priority: .utility) {
                    brokenMappings.compactMap { broken -> (key: String, path: String)? in
                        guard let found = ScoreStore.findSF2ByFilename(broken.fileName, searchRoot: searchRoot) else {
                            NSLog("[SF2 Recovery] FAILED to find %@ for mapping %@", broken.fileName, broken.key)
                            return nil
                        }
                        NSLog("[SF2 Recovery] Resolved broken path for %@: %@", broken.key, found)
                        return (key: broken.key, path: found)
                    }
                }.value
                guard let self else { return }
                for result in results {
                    self.instrumentMappings[result.key]?.sf2Path = result.path
                    self.instrumentMappings[result.key]?.sf2FileName = (result.path as NSString).lastPathComponent
                }
                if !results.isEmpty { self.isDirty = true }
            }
        }

        return resolved
    }

    /// Search known SoundFont directories for a file by name. Thread-safe (pure function).
    nonisolated private static func findSF2ByFilename(_ fileName: String, searchRoot: String) -> String? {
        let searchPaths = [
            searchRoot,
            NSHomeDirectory() + "/Library/Audio/Sounds/Banks",
            "/Library/Audio/Sounds/Banks",
        ].filter { !$0.isEmpty }

        let fm = FileManager.default
        for base in searchPaths {
            if let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: base),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                while let url = enumerator.nextObject() as? URL {
                    if url.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame {
                        return url.path
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Tick-to-Seconds Conversion

    /// Convert a tick position to seconds, respecting tempo changes.
    func ticksToSeconds(_ tick: Int) -> Double {
        let tpq = max(1, ticksPerQuarter)
        let sorted = pianoRollTempoEvents.sorted { $0.tick < $1.tick }
        guard !sorted.isEmpty else {
            // Fallback: constant 120 BPM
            return Double(tick) / Double(tpq) * 0.5
        }

        var seconds = 0.0
        var currentTick = 0

        for i in 0..<sorted.count {
            let bpm = max(20, sorted[i].bpm)
            let nextTick: Int
            if i + 1 < sorted.count {
                nextTick = min(sorted[i + 1].tick, tick)
            } else {
                nextTick = tick
            }

            if nextTick > currentTick {
                let ticks = nextTick - currentTick
                seconds += Double(ticks) / Double(tpq) / (bpm / 60.0)
            }

            currentTick = nextTick
            if currentTick >= tick { break }
        }
        return seconds
    }

    // MARK: - Suno Chunk Grouping

    /// Legacy compatibility: compute chunks using the new SunoChunkPlanner.
    /// Returns simplified chunk data for API endpoints.
    func computeSunoChunks() -> [(startTick: Int, endTick: Int)] {
        let trackChannelMap = buildTrackChannelToMappingKey()
        guard let songID = selectedMidiID else { return [] }
        let plan = SunoChunkPlanner.plan(
            notes: pianoRollNotes,
            mappings: instrumentMappings,
            trackChannelToMappingKey: trackChannelMap,
            tempoEvents: pianoRollTempoEvents,
            timeSignatures: pianoRollTimeSignatures,
            markers: pianoRollMarkers,
            autoDetectedSections: currentStructuralAnalysis?.sections ?? [],
            manualSplitTicks: sunoSplitTicks,
            ticksPerQuarter: ticksPerQuarter,
            songLengthTicks: pianoRollLengthTicks,
            songID: songID,
            config: sunoConfig,
            splitMode: sunoSplitMode,
            styleTemplate: sunoStyleTemplate
        )
        return plan.chunks.map { (startTick: $0.tickStart, endTick: $0.tickEnd) }
    }

    // MARK: - Offline WAV Renderer

    enum ChunkExportError: LocalizedError {
        case bufferCreationFailed
        case noNotes
        case audioUnitLoadFailed([String])
        case realtimeRenderTimedOut

        var errorDescription: String? {
            switch self {
            case .bufferCreationFailed: return "Failed to create audio buffer"
            case .noNotes: return "No notes in the specified range"
            case .audioUnitLoadFailed(let mappingKeys):
                let joined = mappingKeys.joined(separator: ", ")
                return "Failed to load requested Audio Unit mappings: \(joined)"
            case .realtimeRenderTimedOut:
                return "Timed out while capturing the live audio render"
            }
        }
    }

    /// Render MIDI notes in a tick range to a WAV file using offline AVAudioEngine.
    /// - Parameter gainOverrides: Optional per-mapping-key gain in dB. Overrides the mapping's own gainDB.
    func renderChunkToWav(
        notes: [PianoRollNote],
        startTick: Int,
        endTick: Int,
        outputURL: URL,
        overrideSF2Path: String? = nil,
        gainOverrides: [String: Double]? = nil
    ) async throws {
        // Snapshot all data from main actor before dispatching to background
        let chunkNotes = notes.filter {
            $0.startTick < endTick && ($0.startTick + $0.duration) > startTick
        }
        guard !chunkNotes.isEmpty else { throw ChunkExportError.noNotes }

        let dynamicsApplied = applyDynamicsToNotes(chunkNotes)
        let channelKeyMap = pianoRollChannelKeyByTrackChannel
        let resolvedMappings = resolvedInstrumentMappings()
        let volume = masterVolume
        let panMap = channelPan
        let baseTempoBPM = tempoBPM
        let tempoEvents = pianoRollTempoEvents
        let tpq = ticksPerQuarter
        let preferredBufferFrames = selectedAudioBufferFrames
        let timeSignatures = pianoRollTimeSignatures

        // Progress callback — bounces to main actor
        let reportStatus: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.statusMessage = msg }
        }
        let reportWarning: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.appendSunoLog(msg, level: .warning) }
        }

        let neededMappingKeys = Set(dynamicsApplied.map { note in
            let pairKey = "\(note.trackIndex):\(note.channel)"
            return channelKeyMap[pairKey] ?? "__default__"
        })
        let needsRealtimePlaybackRender = overrideSF2Path == nil && neededMappingKeys.contains { key in
            guard let mapping = resolvedMappings[key], !mapping.muted else { return false }
            return mapping.effectiveSourceType == .audioUnit && mapping.audioComponentDescription != nil
        }

        if needsRealtimePlaybackRender {
            try await renderChunkToWavViaPlaybackEngine(
                notes: dynamicsApplied,
                startTick: startTick,
                endTick: endTick,
                outputURL: outputURL,
                gainOverrides: gainOverrides,
                channelKeyMap: channelKeyMap,
                resolvedMappings: resolvedMappings,
                masterVolume: volume,
                panMap: panMap,
                tempoBPM: baseTempoBPM,
                tempoEvents: tempoEvents,
                ticksPerQuarter: tpq,
                preferredBufferFrames: preferredBufferFrames,
                timeSignatures: timeSignatures,
                reportStatus: reportStatus
            )
            return
        }

        // Tick-to-seconds conversion as a pure function (captures snapshot)
        let ticksToSec: @Sendable (Int) -> Double = { tick in
            Self.ticksToSecondsStatic(tick, ticksPerQuarter: tpq, tempoEvents: tempoEvents)
        }

        // Run ALL heavy work off the main thread
        try await Task.detached(priority: .userInitiated) {
            try await Self.renderChunkToWavBackground(
                chunkNotes: dynamicsApplied,
                startTick: startTick,
                endTick: endTick,
                outputURL: outputURL,
                overrideSF2Path: overrideSF2Path,
                gainOverrides: gainOverrides,
                channelKeyMap: channelKeyMap,
                resolvedMappings: resolvedMappings,
                masterVolume: volume,
                panMap: panMap,
                ticksToSec: ticksToSec,
                reportStatus: reportStatus,
                reportWarning: reportWarning
            )
        }.value
    }

    private func renderChunkToWavViaPlaybackEngine(
        notes: [PianoRollNote],
        startTick: Int,
        endTick: Int,
        outputURL: URL,
        gainOverrides: [String: Double]?,
        channelKeyMap: [String: String],
        resolvedMappings: [String: InstrumentMapping],
        masterVolume: Double,
        panMap: [String: Double],
        tempoBPM: Double,
        tempoEvents: [TempoPoint],
        ticksPerQuarter: Int,
        preferredBufferFrames: UInt32,
        timeSignatures: [TimeSignatureEvent],
        reportStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let clippedNotes = notes.compactMap { note -> PianoRollNote? in
            let clippedStart = max(note.startTick, startTick)
            let clippedEnd = min(note.startTick + note.duration, endTick)
            guard clippedEnd > clippedStart else { return nil }
            var adjusted = note
            adjusted.startTick = clippedStart - startTick
            adjusted.duration = max(1, clippedEnd - clippedStart)
            return adjusted
        }
        guard !clippedNotes.isEmpty else { throw ChunkExportError.noNotes }

        var effectiveMappings = resolvedMappings
        if let gainOverrides {
            for (key, gain) in gainOverrides {
                guard var mapping = effectiveMappings[key] else { continue }
                mapping.gainDB = gain
                effectiveMappings[key] = mapping
            }
        }

        let shiftedTempoEvents = Self.shiftedTempoEventsForRealtimeRender(
            startTick: startTick,
            endTick: endTick,
            tempoEvents: tempoEvents,
            fallbackTempo: tempoBPM
        )
        let shiftedTempoBPM = shiftedTempoEvents.first?.bpm ?? max(20, tempoBPM)
        let contentLengthTicks = max(
            clippedNotes.map { $0.startTick + $0.duration }.max() ?? 0,
            endTick - startTick
        )
        let tailTicks = max(ticksPerQuarter * 2, 1)
        let playbackLengthTicks = contentLengthTicks + tailTicks

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let exportEngine = MIDIPlaybackEngine()
        exportEngine.muteHardwareOutput = true  // Silent export: don't play through speakers
        exportEngine.metronomeTimeSignatures = timeSignatures
        exportEngine.configureMetronome(enabled: false, volume: 0, countInBars: 0)
        exportEngine.setPreferredBufferFrames(preferredBufferFrames)
        exportEngine.setMasterVolume(masterVolume)
        let estimatedSeconds = Self.ticksToSecondsStatic(
            playbackLengthTicks,
            ticksPerQuarter: ticksPerQuarter,
            tempoEvents: shiftedTempoEvents
        )
        let scheduledStopSeconds = max(estimatedSeconds + 2.0, 4.0)
        let hardTimeoutSeconds = max(scheduledStopSeconds + 30.0, 45.0)

        reportStatus("Loading live instruments...")
        await withCheckedContinuation { continuation in
            exportEngine.prewarmAudioUnits(for: effectiveMappings) {
                continuation.resume()
            }
        }

        let finishedLock = OSAllocatedUnfairLock(initialState: false)
        let playbackErrorLock = OSAllocatedUnfairLock(initialState: Optional<String>.none)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            func resumeOnce(_ result: Result<Void, Error>) {
                let alreadyResumed = finishedLock.withLock { state in
                    let wasFinished = state
                    if !state { state = true }
                    return wasFinished
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }

            exportEngine.onPlaybackError = { message in
                playbackErrorLock.withLock { state in state = message }
            }
            exportEngine.onMainMixRecordingComplete = { url in
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if fileSize <= 4096 {
                    let message = playbackErrorLock.withLock { $0 } ?? ChunkExportError.bufferCreationFailed.localizedDescription
                    resumeOnce(.failure(NSError(domain: "RealtimeExport", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: message
                    ])))
                    return
                }
                resumeOnce(.success(()))
            }

            reportStatus("Capturing live BBC render...")
            exportEngine.startMainMixRecording(outputURL: outputURL)
            exportEngine.play(
                notes: clippedNotes,
                lengthTicks: playbackLengthTicks,
                ticksPerQuarter: ticksPerQuarter,
                tempoBPM: shiftedTempoBPM,
                tempoEvents: shiftedTempoEvents,
                loop: false,
                startTick: 0,
                trackChannelToMappingKey: channelKeyMap,
                instrumentMappings: effectiveMappings,
                audioClips: [],
                renderMode: .midi,
                mutedTracks: []
            )
            for (mappingKey, pan) in panMap {
                exportEngine.setSamplerPan(mappingKey: mappingKey, pan: pan)
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(scheduledStopSeconds * 1_000_000_000))
                exportEngine.stop()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(hardTimeoutSeconds * 1_000_000_000))
                exportEngine.stopMainMixRecording()
                exportEngine.stop()
                resumeOnce(.failure(ChunkExportError.realtimeRenderTimedOut))
            }
        }
    }

    /// Pure static helper — runs entirely off the main thread.
    /// All ScoreStore data is passed in as parameters (no self access).
    @Sendable
    private nonisolated static func renderChunkToWavBackground(
        chunkNotes: [PianoRollNote],
        startTick: Int,
        endTick: Int,
        outputURL: URL,
        overrideSF2Path: String?,
        gainOverrides: [String: Double]?,
        channelKeyMap: [String: String],
        resolvedMappings: [String: InstrumentMapping],
        masterVolume: Double,
        panMap: [String: Double],
        ticksToSec: @Sendable (Int) -> Double,
        reportStatus: @Sendable (String) -> Void,
        reportWarning: @Sendable (String) -> Void
    ) async throws {
        let sampleRate: Double = 44100
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else { throw ChunkExportError.bufferCreationFailed }

        // Compute total duration
        let startSeconds = ticksToSec(startTick)
        let endSeconds = ticksToSec(endTick)
        let totalSeconds = endSeconds - startSeconds
        let totalFrames = AVAudioFrameCount(totalSeconds * sampleRate) + 44100 // 1s tail for release
        guard totalFrames > 0 else { return }
        // Match the live engine's default max render sizing (preferred 512 * 4).
        // 4096-sample offline chunks have been producing audible discontinuities
        // at exact render boundaries in exported BBC AU material.
        let renderBlockSize: AVAudioFrameCount = 2048

        // Resolve mapping keys
        var neededMappingKeys = Set<String>()
        for note in chunkNotes {
            let pairKey = "\(note.trackIndex):\(note.channel)"
            let mappingKey = channelKeyMap[pairKey] ?? "__default__"
            neededMappingKeys.insert(mappingKey)
        }

        // Phase 1: Create engine, attach samplers and AU instruments
        let offlineEngine = AVAudioEngine()
        let mainMixer = offlineEngine.mainMixerNode
        mainMixer.outputVolume = Float(max(masterVolume, 0.001))
        if !mainMixer.auAudioUnit.renderResourcesAllocated {
            mainMixer.auAudioUnit.maximumFramesToRender = UInt32(renderBlockSize)
        }
        let outputNode = offlineEngine.outputNode
        if !outputNode.auAudioUnit.renderResourcesAllocated {
            outputNode.auAudioUnit.maximumFramesToRender = UInt32(renderBlockSize)
        }

        var samplers: [String: AVAudioUnitSampler] = [:]
        var auNodes: [String: AVAudioUnit] = [:]
        var auMixers: [String: AVAudioMixerNode] = [:]

        if overrideSF2Path != nil {
            // Single override sampler for all notes — skip AU instantiation
            let sampler = AVAudioUnitSampler()
            offlineEngine.attach(sampler)
            offlineEngine.connect(sampler, to: mainMixer, format: nil)
            sampler.auAudioUnit.maximumFramesToRender = UInt32(renderBlockSize)
            samplers["__override__"] = sampler
        } else {
            // Count AU mappings for progress reporting
            let requestedAUMappingKeys = neededMappingKeys.filter { key in
                guard let m = resolvedMappings[key], !m.muted else { return false }
                return m.effectiveSourceType == .audioUnit
            }
            let auMappingKeys = requestedAUMappingKeys.filter { key in
                resolvedMappings[key]?.audioComponentDescription != nil
            }
            var auLoadedCount = 0
            let auTotalCount = auMappingKeys.count
            var failedAUMappingKeys: [String] = []

            for mappingKey in neededMappingKeys {
                let mapping = resolvedMappings[mappingKey]
                if mapping?.muted == true { continue }

                // AU instrument path
                if let mapping, mapping.effectiveSourceType == .audioUnit {
                    guard let desc = mapping.audioComponentDescription else {
                        failedAUMappingKeys.append(mappingKey)
                        reportWarning("Warning: AU mapping missing component description for \(mappingKey)")
                        NSLog("[OfflineExport] AU mapping missing component description for %@", mappingKey)
                        continue
                    }

                    auLoadedCount += 1
                    if auTotalCount > 0 {
                        reportStatus("Loading instruments... (\(auLoadedCount)/\(auTotalCount))")
                    }

                    do {
                        let audioUnit = try await instantiateAUForOfflineRenderStatic(
                            description: desc, mapping: mapping
                        )
                        audioUnit.auAudioUnit.maximumFramesToRender = UInt32(renderBlockSize)
                        offlineEngine.attach(audioUnit)

                        let perAUMixer = AVAudioMixerNode()
                        offlineEngine.attach(perAUMixer)
                        offlineEngine.connect(audioUnit, to: perAUMixer, format: nil)
                        offlineEngine.connect(perAUMixer, to: mainMixer, format: nil)

                        let effectiveGain = gainOverrides?[mappingKey] ?? mapping.gainDB
                        let clampedDB = min(max(effectiveGain, -96.0), 24.0)
                        let linear = clampedDB <= -96.0 ? Float(0) : Float(pow(10.0, clampedDB / 20.0))
                        perAUMixer.outputVolume = linear

                        if let pan = panMap[mappingKey] {
                            perAUMixer.pan = Float(pan)
                        }

                        auNodes[mappingKey] = audioUnit
                        auMixers[mappingKey] = perAUMixer
                        NSLog("[OfflineExport] Loaded AU instrument for %@", mappingKey)
                    } catch {
                        failedAUMappingKeys.append(mappingKey)
                        reportWarning("Warning: AU instantiation failed for \(mappingKey): \(error.localizedDescription)")
                        NSLog("[OfflineExport] AU instantiation failed for %@: %@", mappingKey, error.localizedDescription)
                    }
                    continue
                }

                // SF2 sampler path (existing behavior)
                let sampler = AVAudioUnitSampler()
                offlineEngine.attach(sampler)
                offlineEngine.connect(sampler, to: mainMixer, format: nil)
                sampler.auAudioUnit.maximumFramesToRender = UInt32(renderBlockSize)
                samplers[mappingKey] = sampler
            }

            if !failedAUMappingKeys.isEmpty {
                throw ChunkExportError.audioUnitLoadFailed(failedAUMappingKeys.sorted())
            }

            if requestedAUMappingKeys.isEmpty && samplers.isEmpty && auNodes.isEmpty && !chunkNotes.isEmpty {
                let sampler = AVAudioUnitSampler()
                offlineEngine.attach(sampler)
                offlineEngine.connect(sampler, to: mainMixer, format: nil)
                sampler.auAudioUnit.maximumFramesToRender = UInt32(renderBlockSize)
                samplers["__default__"] = sampler
            }
        }

        // Phase 2: Enable manual rendering
        try offlineEngine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: renderBlockSize
        )
        try offlineEngine.start()
        defer { offlineEngine.stop() }

        // Phase 3: Load instruments
        if let overridePath = overrideSF2Path, let sampler = samplers["__override__"] {
            let sf2URL = URL(fileURLWithPath: overridePath)
            var loaded = false

            if FileManager.default.fileExists(atPath: sf2URL.path) {
                NSLog("[SunoExport] Loading override SF2: %@", sf2URL.lastPathComponent)

                do {
                    try sampler.loadSoundBankInstrument(at: sf2URL, program: 0, bankMSB: 0, bankLSB: 0)
                    loaded = true
                } catch {
                    NSLog("[SF2] Override SF2 prog 0 bank 0/0 attempt failed for __override__: %@", error.localizedDescription)
                }

                if !loaded {
                    let defaultMelodicMSB = UInt8(kAUSampler_DefaultMelodicBankMSB)
                    do {
                        try sampler.loadSoundBankInstrument(at: sf2URL, program: 0, bankMSB: defaultMelodicMSB, bankLSB: 0)
                        loaded = true
                    } catch {
                        NSLog("[SF2] Override SF2 Apple default melodic bank attempt failed for __override__: %@", error.localizedDescription)
                    }
                }
            } else {
                NSLog("[SunoExport] Override SF2 not found: %@", overridePath)
            }

            if !loaded {
                NSLog("[SunoExport] FAILED to load override SF2 — sampler will use default sound")
            }
        } else {
            for (mappingKey, sampler) in samplers {
                guard let mapping = resolvedMappings[mappingKey] else {
                    NSLog("[SunoExport] No mapping for key: %@", mappingKey)
                    continue
                }

                let resolvedProgram = UInt8(min(max(mapping.program, 0), 127))
                let resolvedBankMSB = UInt8(min(max(mapping.bankMSB, 0), 127))
                let bankLSB = UInt8(min(max(mapping.bankLSB, 0), 127))

                guard let sf2Path = mapping.sf2Path?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sf2Path.isEmpty else {
                    NSLog("[SunoExport] No sf2Path for %@", mappingKey)
                    continue
                }
                let sf2URL = URL(fileURLWithPath: sf2Path)
                guard FileManager.default.fileExists(atPath: sf2URL.path) else {
                    NSLog("[SunoExport] SF2 not found: %@", sf2Path)
                    continue
                }

                NSLog("[SunoExport] Loading %@ for %@ (prog=%d bank=%d/%d)",
                      sf2URL.lastPathComponent, mappingKey, resolvedProgram, resolvedBankMSB, bankLSB)

                var loaded = false

                do {
                    try sampler.loadSoundBankInstrument(
                        at: sf2URL, program: resolvedProgram, bankMSB: resolvedBankMSB, bankLSB: bankLSB
                    )
                    loaded = true
                } catch {
                    NSLog("[SF2] Exact program/bank attempt failed for %@ (prog=%d bank=%d/%d): %@", mappingKey, resolvedProgram, resolvedBankMSB, bankLSB, error.localizedDescription)
                }

                if !loaded && (resolvedBankMSB != 0 || bankLSB != 0) {
                    do {
                        try sampler.loadSoundBankInstrument(
                            at: sf2URL, program: resolvedProgram, bankMSB: 0, bankLSB: 0
                        )
                        loaded = true
                    } catch {
                        NSLog("[SF2] Bank 0/0 fallback failed for %@ (prog=%d): %@", mappingKey, resolvedProgram, error.localizedDescription)
                    }
                }

                if !loaded && resolvedProgram != 0 {
                    do {
                        try sampler.loadSoundBankInstrument(
                            at: sf2URL, program: 0, bankMSB: 0, bankLSB: 0
                        )
                        loaded = true
                    } catch {
                        NSLog("[SF2] Program 0 bank 0/0 fallback failed for %@: %@", mappingKey, error.localizedDescription)
                    }
                }

                if !loaded {
                    let defaultMelodicMSB = UInt8(kAUSampler_DefaultMelodicBankMSB)
                    do {
                        try sampler.loadSoundBankInstrument(
                            at: sf2URL, program: resolvedProgram, bankMSB: defaultMelodicMSB, bankLSB: 0
                        )
                        loaded = true
                    } catch {
                        if resolvedProgram != 0 {
                            do {
                                try sampler.loadSoundBankInstrument(
                                    at: sf2URL, program: 0, bankMSB: defaultMelodicMSB, bankLSB: 0
                                )
                                loaded = true
                            } catch {
                                NSLog("[SF2] Apple default melodic bank prog 0 fallback failed for %@: %@", mappingKey, error.localizedDescription)
                            }
                        }
                    }
                }

                if loaded {
                    NSLog("[SunoExport] Loaded instrument for %@", mappingKey)
                    let effectiveGain = gainOverrides?[mappingKey] ?? mapping.gainDB
                    if let gainParam = sampler.auAudioUnit.parameterTree?.parameter(
                        withAddress: AUParameterAddress(kAUSamplerParam_Gain)
                    ) {
                        gainParam.value = Float(effectiveGain)
                    }
                } else {
                    NSLog("[SunoExport] FAILED to load instrument for %@ — muting", mappingKey)
                    sampler.volume = 0
                }
            }
        }

        // Phase 4: Build sorted event list
        struct MidiEvent: Comparable {
            let framePosition: AVAudioFramePosition
            let pitch: UInt8
            let velocity: UInt8
            let isNoteOn: Bool
            let mappingKey: String

            static func < (lhs: MidiEvent, rhs: MidiEvent) -> Bool {
                lhs.framePosition < rhs.framePosition
            }
        }

        var events: [MidiEvent] = []
        for note in chunkNotes {
            let trackChannel = "\(note.trackIndex):\(note.channel)"
            let mappingKey = overrideSF2Path != nil
                ? "__override__"
                : (channelKeyMap[trackChannel] ?? "__default__")

            let noteStartSec = ticksToSec(max(note.startTick, startTick)) - startSeconds
            let noteEndTick = min(note.startTick + note.duration, endTick)
            let noteEndSec = ticksToSec(noteEndTick) - startSeconds

            let startFrame = AVAudioFramePosition(max(0, noteStartSec) * sampleRate)
            let endFrame = AVAudioFramePosition(max(0, noteEndSec) * sampleRate)

            events.append(MidiEvent(
                framePosition: startFrame,
                pitch: UInt8(min(max(note.pitch, 0), 127)),
                velocity: UInt8(min(max(note.velocity, 1), 127)),
                isNoteOn: true,
                mappingKey: mappingKey
            ))
            events.append(MidiEvent(
                framePosition: endFrame,
                pitch: UInt8(min(max(note.pitch, 0), 127)),
                velocity: 0,
                isNoteOn: false,
                mappingKey: mappingKey
            ))
        }
        events.sort()

        // Phase 5: Render offline — stream directly to file
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: renderBlockSize) else {
            throw ChunkExportError.bufferCreationFailed
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var currentFrame: AVAudioFramePosition = 0
        var eventIndex = 0

        var retryCount = 0
        while currentFrame < AVAudioFramePosition(totalFrames) {
            let framesToRender = min(renderBlockSize, AVAudioFrameCount(AVAudioFramePosition(totalFrames) - currentFrame))

            let blockEnd = currentFrame + AVAudioFramePosition(framesToRender)
            while eventIndex < events.count && events[eventIndex].framePosition < blockEnd {
                let event = events[eventIndex]

                if let auUnit = auNodes[event.mappingKey] {
                    if let scheduleMIDI = auUnit.auAudioUnit.scheduleMIDIEventBlock {
                        let sampleOffset = AUEventSampleTime(event.framePosition - currentFrame)
                        if event.isNoteOn {
                            let noteOn: [UInt8] = [0x90, event.pitch, event.velocity]
                            noteOn.withUnsafeBufferPointer { buf in
                                if let ptr = buf.baseAddress {
                                    scheduleMIDI(sampleOffset, 0, 3, ptr)
                                }
                            }
                        } else {
                            let noteOff: [UInt8] = [0x80, event.pitch, 0]
                            noteOff.withUnsafeBufferPointer { buf in
                                if let ptr = buf.baseAddress {
                                    scheduleMIDI(sampleOffset, 0, 3, ptr)
                                }
                            }
                        }
                    }
                } else if let sampler = samplers[event.mappingKey] {
                    if event.isNoteOn {
                        sampler.startNote(event.pitch, withVelocity: event.velocity, onChannel: 0)
                    } else {
                        sampler.stopNote(event.pitch, onChannel: 0)
                    }
                }
                eventIndex += 1
            }

            let status = try offlineEngine.renderOffline(framesToRender, to: outputBuffer)

            switch status {
            case .success:
                try outputFile.write(from: outputBuffer)
                currentFrame += AVAudioFramePosition(outputBuffer.frameLength)
                retryCount = 0
            case .insufficientDataFromInputNode:
                currentFrame += AVAudioFramePosition(framesToRender)
                retryCount = 0
            case .cannotDoInCurrentContext:
                retryCount += 1
                guard retryCount < 1000 else {
                    throw ChunkExportError.bufferCreationFailed
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            case .error:
                throw ChunkExportError.bufferCreationFailed
            @unknown default:
                currentFrame += AVAudioFramePosition(framesToRender)
                retryCount = 0
            }
        }

        // Cleanup: detach AU nodes from offline engine (in-process AUs share address space)
        for (key, auUnit) in auNodes {
            offlineEngine.disconnectNodeOutput(auUnit)
            offlineEngine.detach(auUnit)
            if let mixer = auMixers[key] {
                offlineEngine.disconnectNodeOutput(mixer)
                offlineEngine.detach(mixer)
            }
        }
    }

    private nonisolated static func shiftedTempoEventsForRealtimeRender(
        startTick: Int,
        endTick: Int,
        tempoEvents: [TempoPoint],
        fallbackTempo: Double
    ) -> [TempoPoint] {
        let sorted = tempoEvents.sorted { $0.tick < $1.tick }
        var currentTempo = max(20, fallbackTempo)

        for event in sorted where event.tick <= startTick {
            currentTempo = max(20, event.bpm)
        }

        var shifted = [TempoPoint(tick: 0, bpm: currentTempo)]
        for event in sorted where event.tick > startTick && event.tick < endTick {
            shifted.append(TempoPoint(tick: event.tick - startTick, bpm: max(20, event.bpm)))
        }
        return shifted
    }

    /// Static tick-to-seconds conversion (no self access, safe for background use).
    nonisolated static func ticksToSecondsStatic(
        _ tick: Int,
        ticksPerQuarter tpq: Int,
        tempoEvents: [TempoPoint]
    ) -> Double {
        let tpq = max(1, tpq)
        let sorted = tempoEvents.sorted { $0.tick < $1.tick }
        guard !sorted.isEmpty else {
            return Double(tick) / Double(tpq) * 0.5
        }

        var seconds = 0.0
        var currentTick = 0

        for i in 0..<sorted.count {
            let bpm = max(20, sorted[i].bpm)
            let nextTick: Int
            if i + 1 < sorted.count {
                nextTick = min(sorted[i + 1].tick, tick)
            } else {
                nextTick = tick
            }

            if nextTick > currentTick {
                let ticks = nextTick - currentTick
                seconds += Double(ticks) / Double(tpq) / (bpm / 60.0)
            }

            currentTick = nextTick
            if currentTick >= tick { break }
        }
        return seconds
    }

    /// Instantiate an Audio Unit instrument for offline (manual-rendering) export.
    /// Uses `.loadInProcess` — safe because the offline engine is disposable and
    /// in-process avoids XPC round-trip overhead per render block.
    private nonisolated static func instantiateAUForOfflineRenderStatic(
        description: AudioComponentDescription,
        mapping: InstrumentMapping
    ) async throws -> AVAudioUnit {
        final class AUBox: @unchecked Sendable {
            let unit: AVAudioUnit
            init(_ unit: AVAudioUnit) { self.unit = unit }
        }

        let box: AUBox = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                if resumed.withLock({ old in let was = old; old = true; return was }) == false {
                    continuation.resume(throwing: ChunkExportError.bufferCreationFailed)
                }
            }
            // Match the live playback engine for large third-party instruments like
            // BBC Symphony Orchestra. In-process loading can resolve to incorrect
            // behavior or generic fallback timbres in offline export sessions.
            AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { unit, error in
                timeoutTask.cancel()
                if resumed.withLock({ old in let was = old; old = true; return was }) == false {
                    if let unit {
                        continuation.resume(returning: AUBox(unit))
                    } else {
                        continuation.resume(throwing: error ?? ChunkExportError.bufferCreationFailed)
                    }
                }
            }
        }
        let audioUnit = box.unit

        // Restore preset state (try plist first, fall back to JSON — matches MIDIPlaybackEngine)
        if let presetData = mapping.auPresetData {
            do {
                if let preset = try PropertyListSerialization.propertyList(from: presetData, format: nil) as? [String: Any] {
                    audioUnit.auAudioUnit.fullState = preset
                } else if let preset = try JSONSerialization.jsonObject(with: presetData) as? [String: Any] {
                    audioUnit.auAudioUnit.fullState = preset
                }
            } catch {
                NSLog("[OfflineExport] Failed to restore AU preset: %@", error.localizedDescription)
            }
        }

        return audioUnit
    }

    // MARK: - Full Mix Export

    /// Present a save panel and render the entire song to a single WAV file.
    #if canImport(AppKit)
    func exportFullMixToWavWithPanel() {
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }
        guard !isExportingFullMix else {
            fullMixExportStatus = "Export already in progress."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Full Mix to WAV"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(selectedMidiAsset?.displayName ?? "untitled").wav"
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                await self.exportFullMixToWav(outputURL: url)
            }
        }
    }
    #endif

    /// Render the full song to a WAV file at the given URL.
    func exportFullMixToWav(outputURL: URL) async {
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }

        isExportingFullMix = true
        fullMixExportProgress = 0
        fullMixExportStatus = "Rendering full mix..."

        let endTick = pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? pianoRollLengthTicks
        guard endTick > 0 else {
            fullMixExportStatus = "Song has zero length."
            isExportingFullMix = false
            return
        }

        // Estimate total duration for progress tracking
        let estimatedSeconds = Self.ticksToSecondsStatic(
            endTick,
            ticksPerQuarter: ticksPerQuarter,
            tempoEvents: pianoRollTempoEvents
        )
        let exportStartTime = Date()

        // Progress timer — updates every 0.25s during the export
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self, self.isExportingFullMix else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(exportStartTime)
            let progress = estimatedSeconds > 0 ? min(elapsed / (estimatedSeconds + 2), 0.99) : 0
            Task { @MainActor in
                self.fullMixExportProgress = progress
            }
        }

        do {
            try await renderChunkToWav(
                notes: pianoRollNotes,
                startTick: 0,
                endTick: endTick,
                outputURL: outputURL
            )
            fullMixExportProgress = 1.0
            fullMixExportStatus = "Exported to \(outputURL.lastPathComponent)"
            NSLog("[FullMix] Exported full mix to %@", outputURL.path)
        } catch {
            fullMixExportStatus = "Export failed: \(error.localizedDescription)"
            NSLog("[FullMix] Export failed: %@", error.localizedDescription)
        }

        progressTimer.invalidate()
        isExportingFullMix = false
        fullMixExportProgress = 0
    }

    // MARK: - Rehearsal Track Export

    /// Present a save panel and render a rehearsal track:
    /// vocal parts at full volume, accompaniment attenuated by the given dB offset.
    #if canImport(AppKit)
    func exportRehearsalTrackWithPanel() {
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }
        guard !isExportingFullMix else {
            fullMixExportStatus = "Export already in progress."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Rehearsal Track"
        panel.allowedContentTypes = [.wav]
        let baseName = selectedMidiAsset?.displayName ?? "untitled"
        panel.nameFieldStringValue = "\(baseName) - Rehearsal.wav"
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                await self.exportRehearsalTrack(outputURL: url)
            }
        }
    }
    #endif

    /// Render a rehearsal track: vocal tracks at original gain, accompaniment at -12dB.
    func exportRehearsalTrack(outputURL: URL, accompanimentAttenuationDB: Double = -12.0) async {
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }

        isExportingFullMix = true
        fullMixExportStatus = "Rendering rehearsal track..."

        // Build gain overrides: vocal mappings keep their gain, others get attenuated
        var gainOverrides: [String: Double] = [:]
        let resolvedMappings = resolvedInstrumentMappings()
        for (key, mapping) in resolvedMappings {
            if mapping.trackRole == .vocal {
                gainOverrides[key] = mapping.gainDB  // keep original
            } else {
                gainOverrides[key] = mapping.gainDB + accompanimentAttenuationDB
            }
        }

        let endTick = pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? pianoRollLengthTicks
        guard endTick > 0 else {
            fullMixExportStatus = "Song has zero length."
            isExportingFullMix = false
            return
        }

        do {
            try await renderChunkToWav(
                notes: pianoRollNotes,
                startTick: 0,
                endTick: endTick,
                outputURL: outputURL,
                gainOverrides: gainOverrides
            )
            fullMixExportStatus = "Rehearsal track exported to \(outputURL.lastPathComponent)"
            NSLog("[Rehearsal] Exported rehearsal track to %@", outputURL.path)
        } catch {
            fullMixExportStatus = "Export failed: \(error.localizedDescription)"
            NSLog("[Rehearsal] Export failed: %@", error.localizedDescription)
        }

        isExportingFullMix = false
    }

    // MARK: - Stem Export

    /// Present a folder chooser and render each track to a separate WAV file.
    #if canImport(AppKit)
    func exportStemsWithPanel() {
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }
        guard !isExportingFullMix else {
            fullMixExportStatus = "Export already in progress."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Folder for Stems"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                await self.exportStems(outputDir: url)
            }
        }
    }
    #endif

    /// Render each unique track to a separate WAV in the given directory.
    func exportStems(outputDir: URL) async {
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }

        isExportingFullMix = true

        // Group notes by trackIndex
        let trackIndices = Set(pianoRollNotes.map(\.trackIndex)).sorted()
        let endTick = pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? pianoRollLengthTicks
        guard endTick > 0 else {
            fullMixExportStatus = "Song has zero length."
            isExportingFullMix = false
            return
        }

        let baseName = selectedMidiAsset?.displayName ?? "untitled"
        var exported = 0

        for trackIdx in trackIndices {
            let trackNotes = pianoRollNotes.filter { $0.trackIndex == trackIdx }
            guard !trackNotes.isEmpty else { continue }

            let trackName = pianoRollTrackNames[trackIdx] ?? "Track \(trackIdx)"
            let safeName = trackName.replacingOccurrences(of: "/", with: "-")
            let fileName = "\(baseName) - \(safeName).wav"
            let outputURL = outputDir.appendingPathComponent(fileName)

            fullMixExportStatus = "Rendering stem: \(trackName)..."

            do {
                try await renderChunkToWav(
                    notes: trackNotes,
                    startTick: 0,
                    endTick: endTick,
                    outputURL: outputURL
                )
                exported += 1
            } catch {
                NSLog("[Stems] Failed to export stem for %@: %@", trackName, error.localizedDescription)
            }
        }

        fullMixExportStatus = "Exported \(exported) stems to \(outputDir.lastPathComponent)/"
        NSLog("[Stems] Exported %d stems to %@", exported, outputDir.path)
        isExportingFullMix = false
    }

    // MARK: - Suno Export Pipeline

    /// Export song in chunks as WAV files for Suno cover input.
    /// Chunks are defined by manual Suno split points placed on the ruler.
    func exportSunoChunks() async {
        guard !pianoRollNotes.isEmpty else {
            sunoExportStatus = "No notes to export."
            return
        }

        var chunks = computeSunoChunks()
        if chunks.isEmpty {
            // No splits — export the entire song as a single chunk
            let songEnd = pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? 0
            guard songEnd > 0 else {
                sunoExportStatus = "No notes to export."
                return
            }
            chunks = [(startTick: 0, endTick: songEnd)]
        }

        isExportingSunoChunks = true
        sunoExportProgress = 0
        sunoExportStatus = "Preparing export..."

        let songName = selectedMidiAsset?.displayName ?? "Untitled"
        let safeName = songName.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)

        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            sunoExportStatus = "Could not locate Desktop directory"
            isExportingSunoChunks = false
            return
        }
        let exportDir = desktop
            .appendingPathComponent("Novotro Score Export")
            .appendingPathComponent(safeName)

        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        } catch {
            sunoExportStatus = "Failed to create export directory: \(error.localizedDescription)"
            isExportingSunoChunks = false
            return
        }

        let overridePath: String? = sunoSingleSFOverride ? resolvedSunoOverrideSF2Path() : nil

        for (idx, chunk) in chunks.enumerated() {
            let filename = String(format: "%@_Chunk%02d.wav", safeName, idx + 1)
            let outputURL = exportDir.appendingPathComponent(filename)

            sunoExportStatus = "Rendering chunk \(idx + 1)/\(chunks.count)..."
            sunoExportProgress = Double(idx) / Double(chunks.count)

            do {
                try await renderChunkToWav(
                    notes: pianoRollNotes,
                    startTick: chunk.startTick,
                    endTick: chunk.endTick,
                    outputURL: outputURL,
                    overrideSF2Path: overridePath
                )
                NSLog("[SunoExport] Exported: %@", filename)
            } catch {
                NSLog("[SunoExport] Failed chunk %d: %@", idx + 1, error.localizedDescription)
                sunoExportStatus = "Failed chunk \(idx + 1): \(error.localizedDescription)"
            }
        }

        sunoExportProgress = 1.0
        sunoExportStatus = "Exported \(chunks.count) chunks to Desktop/Novotro Score Export/\(safeName)"
        isExportingSunoChunks = false

        // Open in Finder
        #if canImport(AppKit)
        NSWorkspace.shared.open(exportDir)
        #endif
    }

    private func resolvedSunoOverrideSF2Path() -> String? {
        let path = sunoSingleSFPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return path }
        guard !sampleRootDirectoryPath.isEmpty else { return nil }
        return (sampleRootDirectoryPath as NSString).appendingPathComponent(path)
    }

    // MARK: - Suno MCP Methods

    /// Deprecated legacy login path. Canonical workflow uses Chrome session import.
    func sunoOpenBrowserAndLogin() async {
        sunoGenerateStatus = "Visible-browser Suno login is deprecated. Use Settings -> Import from Chrome."
    }

    /// Called by the UI after the user has completed their Google/OAuth login in the browser.
    func sunoMarkLoggedIn() {
        sunoLoggedIn = true
        sunoGenerateStatus = "Logged in to Suno"
        NSLog("[SunoMCP] User confirmed login.")
    }

    func sunoGenerateOriginalSong() async {
        sunoGenerateStatus = "Original-song Suno generation is deprecated. Use the canonical cover workflow instead."
    }

    /// Generate a track via suno-mcp Playwright automation.
    /// This blocks until the track is generated (can take 30-120+ seconds).
    func sunoGenerateTrack(
        prompt: String,
        style: String? = nil,
        excludeStyles: String? = nil,
        lyrics: String? = nil
    ) async {
        guard sunoClient.isConfigured else {
            sunoGenerateStatus = "Configure Suno in settings first."
            return
        }

        // Require the user to open the browser and log in manually first (Google OAuth)
        guard sunoLoggedIn else {
            sunoGenerateStatus = "Please open the browser and sign in first (Suno Settings → Open Browser)."
            return
        }

        sunoIsGenerating = true
        sunoGenerateStatus = "Generating track..."
        defer { sunoIsGenerating = false }
        let songPath = selectedMidiAsset?.relativePath

        // Create a local generation entry
        let generation = SunoGeneration(
            songPath: songPath,
            prompt: prompt,
            style: style,
            excludeStyles: excludeStyles,
            lyrics: lyrics,
            status: .generating
        )
        sunoGenerations.insert(generation, at: 0)
        let genID = generation.id

        do {
            let result = try await sunoClient.generateTrack(
                prompt: prompt,
                style: style,
                excludeStyles: excludeStyles,
                lyrics: lyrics
            )
            // Update generation with result
            if let idx = sunoGenerations.firstIndex(where: { $0.id == genID }) {
                let trackID = parsedSunoTrackID(from: result)
                sunoGenerations[idx].trackID = trackID
                sunoGenerations[idx].status = trackID == nil ? .submitted : .ready
                sunoGenerations[idx].resultMessage = result
            }
            sunoGenerateStatus = parsedSunoTrackID(from: result) == nil
                ? "Track submitted in Suno"
                : "Track ready"
            NSLog("[SunoMCP] Generate succeeded: %@", String(result.prefix(200)))
        } catch {
            if let idx = sunoGenerations.firstIndex(where: { $0.id == genID }) {
                sunoGenerations[idx].status = .error
                sunoGenerations[idx].errorMessage = error.localizedDescription
            }
            sunoGenerateStatus = "Generation failed: \(error.localizedDescription)"
            NSLog("[SunoMCP] Generate failed: %@", error.localizedDescription)
        }
    }

    private func parsedSunoTrackID(from resultMessage: String?) -> String? {
        guard let resultMessage, !resultMessage.isEmpty else { return nil }
        if let uuidRange = resultMessage.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ) {
            return String(resultMessage[uuidRange])
        }
        return nil
    }

    /// Download a generated track to disk and optionally add to Audio pane.
    func sunoDownloadTrack(_ generationID: UUID) async {
        guard let idx = sunoGenerations.firstIndex(where: { $0.id == generationID }) else {
            sunoGenerateStatus = "Generation not found."
            return
        }

        sunoStopPreview()
        sunoGenerations[idx].status = .downloading
        sunoGenerateStatus = "Downloading..."
        let downloadStartedAt = Date()

        do {
            guard let trackID = sunoGenerations[idx].trackID ?? parsedSunoTrackID(from: sunoGenerations[idx].resultMessage) else {
                throw SunoAPIError.toolFailed("No Suno track ID found in generation result.")
            }
            sunoGenerations[idx].trackID = trackID
            let downloadDir = sunoDownloadDirectory()
            let result = try await sunoClient.downloadTrack(
                trackID: trackID,
                downloadPath: downloadDir.path
            )

            NSLog("[SunoMCP] Download result: %@", String(result.prefix(300)))

            // Find the downloaded file — look for the newest file in the download directory
            let files = try FileManager.default.contentsOfDirectory(
                at: downloadDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
            let audioFiles = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mp3" || ext == "wav" || ext == "m4a"
            }
            .filter { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return created >= downloadStartedAt.addingTimeInterval(-2)
            }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return dateA > dateB
            }

            guard let downloadedFile = audioFiles.first else {
                throw SunoAPIError.toolFailed("No audio file found in downloads directory.")
            }

            // Convert to WAV if not already
            let wavURL: URL
            if downloadedFile.pathExtension.lowercased() == "wav" {
                wavURL = downloadedFile
            } else {
                let safeName = sunoGenerations[idx].displayTitle
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                wavURL = downloadDir.appendingPathComponent("\(safeName).wav")
                try convertAudioToWAV(input: downloadedFile, output: wavURL)
            }

            // Compute duration in ticks
            let audioFile = try AVAudioFile(forReading: wavURL)
            let durationSec = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            let tpq = max(1, ticksPerQuarter)
            let bpm = max(20, tempoBPM)
            let durationTicks = max(tpq, Int(durationSec * Double(tpq) * (bpm / 60.0)))

            // Create AudioClip at playhead
            let startTick = max(0, livePlayheadTick)
            let clip = AudioClip(
                displayName: sunoGenerations[idx].displayTitle,
                filePath: wavURL.path,
                startTick: startTick,
                durationTicks: durationTicks
            )
            pianoRollAudioClips.append(clip)
            pianoRollAudioClips.sort { $0.startTick < $1.startTick }
            isDirty = true

            // Update generation
            sunoGenerations[idx].status = .downloaded
            sunoGenerations[idx].downloadedFilePath = wavURL.path
            sunoGenerateStatus = "Added '\(clip.displayName)' to Audio pane"
            statusMessage = "Downloaded Suno track to Audio pane"
            NSLog("[SunoMCP] Downloaded and added clip: %@ (%d ticks)", clip.displayName, durationTicks)
        } catch {
            if sunoGenerations.indices.contains(idx) {
                sunoGenerations[idx].status = .error
                sunoGenerations[idx].errorMessage = error.localizedDescription
            }
            sunoGenerateStatus = "Download failed: \(error.localizedDescription)"
            NSLog("[SunoMCP] Download failed: %@", error.localizedDescription)
        }
    }

    /// Preview a downloaded Suno track by playing its audio file.
    func sunoPreviewTrack(_ generationID: UUID) {
        sunoStopPreview()

        guard let gen = sunoGenerations.first(where: { $0.id == generationID }),
              let filePath = gen.resolvedDownloadedFilePaths.first else {
            sunoGenerateStatus = "No downloaded file to preview."
            return
        }

        previewSunoFile(at: filePath, generationID: generationID)
    }

    func sunoPreviewDownloadedFile(_ filePath: String, generationID: UUID? = nil) {
        previewSunoFile(at: filePath, generationID: generationID)
    }

    private func previewSunoFile(at filePath: String, generationID: UUID?) {
        sunoStopPreview()

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            sunoGenerateStatus = "File not found: \(filePath)"
            return
        }

        do {
            sunoPreviewingGenerationID = generationID
            sunoPreviewPlayer = try AVAudioPlayer(contentsOf: fileURL)
            sunoPreviewPlayer?.play()
            sunoGenerateStatus = "Playing preview..."
            if let generationID {
                NSLog("[SunoMCP] Playing preview for %@", generationID.uuidString)
            } else {
                NSLog("[SunoMCP] Playing preview for %@", filePath)
            }
        } catch {
            sunoPreviewingGenerationID = nil
            sunoGenerateStatus = "Preview failed: \(error.localizedDescription)"
        }
    }

    /// Stop any currently playing Suno preview.
    func sunoStopPreview() {
        sunoPreviewPlayer?.stop()
        sunoPreviewPlayer = nil
        sunoPreviewingGenerationID = nil
    }

    /// Remove a generation from the list.
    func sunoRemoveGeneration(_ generationID: UUID) {
        sunoGenerations.removeAll { $0.id == generationID }
    }

    /// Close the Playwright browser on shutdown.
    func sunoCloseBrowser() async {
        guard sunoBrowserOpen else { return }
        do {
            _ = try await sunoClient.closeBrowser()
            sunoBrowserOpen = false
            sunoLoggedIn = false
            NSLog("[SunoMCP] Browser closed.")
        } catch {
            NSLog("[SunoMCP] Failed to close browser: %@", error.localizedDescription)
        }
    }

    // MARK: - Suno Pipeline

    /// Generate a chunk plan from the current song data.
    func generateSunoChunkPlan() {
        guard let songID = selectedMidiID else {
            appendSunoLog("No song selected — cannot generate chunk plan", level: .warning)
            return
        }
        appendSunoLog("Generating chunk plan for \(pianoRollNotes.count) notes...")
        let trackChannelMap = buildTrackChannelToMappingKey()
        appendSunoLog("Track-channel map: \(trackChannelMap.count) entries, \(instrumentMappings.count) mappings")
        activeChunkPlan = SunoChunkPlanner.plan(
            notes: pianoRollNotes,
            mappings: instrumentMappings,
            trackChannelToMappingKey: trackChannelMap,
            tempoEvents: pianoRollTempoEvents,
            timeSignatures: pianoRollTimeSignatures,
            markers: pianoRollMarkers,
            autoDetectedSections: currentStructuralAnalysis?.sections ?? [],
            manualSplitTicks: sunoSplitTicks,
            ticksPerQuarter: ticksPerQuarter,
            songLengthTicks: pianoRollLengthTicks,
            songID: songID,
            config: sunoConfig,
            splitMode: sunoSplitMode,
            styleTemplate: sunoStyleTemplate
        )
        isChunkPlanStale = false
        if let plan = activeChunkPlan {
            appendSunoLog("Plan ready: \(plan.chunks.count) chunks", level: .success)
            for (i, chunk) in plan.chunks.enumerated() {
                appendSunoLog("  Chunk \(i+1): \(chunk.groupLabel) [\(String(format: "%.1f", chunk.timeStart))s–\(String(format: "%.1f", chunk.timeEnd))s] \(chunk.density.rawValue)")
            }
        } else {
            appendSunoLog("Plan generation produced no chunks", level: .warning)
        }
    }

    /// Build mapping from "TrackNChM" format (used by SunoChunkPlanner) to instrument mapping key.
    private func buildTrackChannelToMappingKey() -> [String: String] {
        var map: [String: String] = [:]
        for (pairKey, mappingKey) in pianoRollChannelKeyByTrackChannel {
            // pairKey is "trackIndex:channel", convert to "TrackNChM" format
            let parts = pairKey.split(separator: ":")
            if parts.count == 2 {
                let tcKey = "Track\(parts[0])Ch\(parts[1])"
                map[tcKey] = mappingKey
            }
        }
        return map
    }

    func applySunoStylePreset(_ preset: SunoStylePreset) {
        sunoStylePreset = preset
        if let template = preset.template {
            sunoStyleTemplate = template
        }
    }

    private func syncSunoStylePresetFromTemplate() {
        if sunoStyleTemplate == SunoStylePreset.orchestraFidelity.template {
            sunoStylePreset = .orchestraFidelity
        } else if sunoStyleTemplate == SunoStylePreset.chamberFidelity.template {
            sunoStylePreset = .chamberFidelity
        } else {
            sunoStylePreset = .custom
        }
    }

    /// Start an automated Suno render session.
    func startSunoRender() async {
        guard let plan = activeChunkPlan else {
            appendSunoLog("No chunk plan — generate one first", level: .warning)
            return
        }
        // Auto-start server if bootstrapped but not running
        if !sunoClient.isConfigured || sunoServerManager.state != .running {
            if sunoServerManager.isBootstrapped {
                appendSunoLog("Server not running — auto-starting...")
                statusMessage = "Starting Suno server..."
                do {
                    try await sunoServerManager.startAndWaitForReady()
                    appendSunoLog("Server started successfully", level: .success)
                } catch {
                    appendSunoLog("Failed to auto-start server: \(error.localizedDescription)", level: .error)
                    statusMessage = "Failed to start Suno server"
                    return
                }
            } else {
                appendSunoLog("Suno server not set up — go to Suno > Settings tab and click 'Set Up Suno'", level: .error)
                statusMessage = "Set up Suno server in Settings tab first"
                return
            }
        }
        appendSunoLog("Starting render session with \(plan.chunks.count) chunks...")
        let session = SunoRenderSession(plan: plan, qcMode: .curated)
        activeRenderSession = session
        let orchestrator = SunoRenderOrchestrator(store: self, session: session)
        await orchestrator.setProgressCallback { [weak self] completed, total, msg in
            Task { @MainActor in
                self?.appendSunoLog("[\(completed)/\(total)] \(msg)")
            }
        }
        await orchestrator.setErrorCallback { [weak self] chunk, error in
            Task { @MainActor in
                self?.appendSunoLog("Chunk \(chunk.groupLabel) failed: \(error.localizedDescription)", level: .error)
            }
        }
        do {
            let result = try await orchestrator.execute()
            activeRenderSession = result
            sunoRenderSessions.append(result)
            appendSunoLog("Render session complete — \(result.status.rawValue)", level: .success)
        } catch {
            appendSunoLog("Render failed: \(error.localizedDescription)", level: .error)
            statusMessage = "Suno render failed: \(error.localizedDescription)"
        }
    }

    /// Export for manual Suno generation.
    func exportForManualSuno() {
        guard let plan = activeChunkPlan else {
            appendSunoLog("No chunk plan — generate one first", level: .warning)
            return
        }
        appendSunoLog("Exporting \(plan.chunks.count) chunks for manual generation...")
        let session = SunoRenderSession(plan: plan, qcMode: .curated)
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suno-manual-\(UUID().uuidString)")
        do {
            try SunoManualFallback.exportForManualGeneration(
                session: session, outputDirectory: outputDir
            )
            appendSunoLog("Exported to \(outputDir.path)", level: .success)
            statusMessage = "Exported \(plan.chunks.count) chunks for manual generation"
        } catch {
            appendSunoLog("Export failed: \(error.localizedDescription)", level: .error)
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Re-roll a specific chunk (generate new take).
    func rerollChunk(_ chunkID: UUID) async {
        statusMessage = "Re-roll not yet implemented"
    }

    /// Cycle through Suno A/B playback modes.
    func cycleSunoPlaybackMode() {
        guard let layer = sunoRenderLayer else { return }
        switch layer.playbackMode {
        case .midiOnly: layer.playbackMode = .sunoOnly
        case .sunoOnly: layer.playbackMode = .blended
        case .blended: layer.playbackMode = .midiOnly
        }
    }

    /// Apply a Suno-extracted tempo map to the MIDI timeline.
    func applySunoTempoMap(_ tempoMap: [TempoPoint]) {
        pushUndoState()
        pianoRollTempoEvents = tempoMap
        isDirty = true
    }

    /// Save a Suno render session to the OWP bundle.
    func saveSunoRenderSession(_ session: SunoRenderSession, owpURL: URL) throws {
        let renderDir = owpURL
            .appendingPathComponent("SunoRenders")
            .appendingPathComponent("render-\(session.id.uuidString)")
        try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: renderDir.appendingPathComponent("manifest.json"))
    }

    /// Import downloaded Suno takes from a render session into the Audio pane.
    /// This gives the user a clip-based review surface aligned to the original
    /// chunk structure while we build richer multi-take editing tools.
    func importSunoSessionToAudioPane(_ sessionID: UUID, selectedOnly: Bool) {
        let session: SunoRenderSession? = {
            if activeRenderSession?.id == sessionID { return activeRenderSession }
            return sunoRenderSessions.first(where: { $0.id == sessionID })
        }()

        guard let session else {
            appendSunoLog("Import failed: render session not found", level: .error)
            statusMessage = "Suno session not found"
            return
        }

        var imported = 0
        for (chunkIndex, chunk) in session.plan.chunks.enumerated() {
            let takeIndices: [Int]
            if selectedOnly {
                takeIndices = chunk.selectedTakeIndex.map { [$0] } ?? []
            } else {
                takeIndices = Array(chunk.takes.indices)
            }

            for takeIndex in takeIndices {
                guard chunk.takes.indices.contains(takeIndex) else { continue }
                let take = chunk.takes[takeIndex]
                guard let path = take.alignedFilePath ?? take.downloadedFilePath,
                      !path.isEmpty,
                      FileManager.default.fileExists(atPath: path)
                else { continue }

                let durationTicks = max(1, chunk.tickEnd - chunk.tickStart)
                let scoreSuffix = take.similarityScore.map { String(format: " %.3f", $0) } ?? ""
                let namePrefix = selectedOnly ? "Selected" : "Take \(takeIndex + 1)"
                let clipName = "Suno C\(chunkIndex + 1) \(namePrefix)\(scoreSuffix)"

                let clip = AudioClip(
                    displayName: clipName,
                    filePath: path,
                    startTick: chunk.tickStart,
                    durationTicks: durationTicks
                )
                pianoRollAudioClips.append(clip)
                imported += 1
            }
        }

        guard imported > 0 else {
            appendSunoLog("No Suno takes were available to import", level: .warning)
            statusMessage = "No Suno takes available to import"
            return
        }

        pianoRollAudioClips.sort { $0.startTick < $1.startTick }
        isDirty = true
        appendSunoLog(
            "Imported \(imported) \(selectedOnly ? "selected" : "all") Suno takes into Audio Clips",
            level: .success
        )
        statusMessage = "Imported \(imported) Suno takes into Audio pane"
    }

    // MARK: - Suno Audio Helpers

    /// Directory for downloaded Suno WAV files.
    private func sunoDownloadDirectory() -> URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("Novotro Score Export")
            .appendingPathComponent("Suno Downloads")
        try? FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        return desktop
    }

    /// Convert an audio file (MP3, M4A, etc.) to 44.1kHz 16-bit stereo WAV.
    private func convertAudioToWAV(input: URL, output: URL) throws {
        let inputFile = try AVAudioFile(forReading: input)
        let inputFormat = inputFile.processingFormat

        // Target format: 44.1kHz, 16-bit, stereo, interleaved
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44100,
            channels: 2,
            interleaved: true
        ) else {
            throw SunoAPIError.serverError("Cannot create output audio format")
        }

        let outputFile = try AVAudioFile(forWriting: output, settings: outputFormat.settings)

        // Read in chunks and write — use the processing format for the buffer
        let bufferSize: AVAudioFrameCount = 65536
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferSize) else {
            throw SunoAPIError.serverError("Cannot create read buffer")
        }

        // Always use converter — inputFormat is float32 (AVAudioFile processingFormat)
        // but output is int16, so direct copy would write wrong sample format.
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SunoAPIError.serverError("Cannot create audio converter")
        }
        guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else {
            throw SunoAPIError.serverError("Cannot create write buffer")
        }

        while true {
            writeBuffer.frameLength = 0
            let status = converter.convert(to: writeBuffer, error: nil) { _, outStatus in
                do {
                    try inputFile.read(into: readBuffer)
                    outStatus.pointee = readBuffer.frameLength > 0 ? .haveData : .endOfStream
                    return readBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            if writeBuffer.frameLength == 0 || status == .endOfStream || status == .error {
                break
            }
            try outputFile.write(from: writeBuffer)
        }
    }
}

// MARK: - Track Freeze / Bounce

@available(macOS 26.0, *)
extension ScoreStore {

    /// Renders a single track to WAV using offline AVAudioEngine, creates an AudioClip, and mutes the MIDI track.
    func freezeTrack(trackIndex: Int) async throws {
        guard frozenTracks[trackIndex] == nil else {
            NSLog("[Freeze] Track %d is already frozen", trackIndex)
            return
        }

        let trackNotes = pianoRollNotes.filter { $0.trackIndex == trackIndex && !$0.muted }
        guard !trackNotes.isEmpty else {
            NSLog("[Freeze] No notes on track %d to freeze", trackIndex)
            return
        }

        // Determine tick range
        let minTick = trackNotes.map(\.startTick).min() ?? 0
        let maxTick = trackNotes.map { $0.startTick + $0.duration }.max() ?? 0
        guard maxTick > minTick else { return }

        // Create output directory
        let freezeDir: URL
        if let projectURL = fileProjectURL {
            freezeDir = projectURL.appendingPathComponent("Frozen")
        } else {
            freezeDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Novotro Score")
                .appendingPathComponent("Frozen")
        }
        try FileManager.default.createDirectory(at: freezeDir, withIntermediateDirectories: true)

        let trackName = pianoRollTrackNames[trackIndex] ?? "Track \(trackIndex)"
        let safeTrackName = trackName.replacingOccurrences(of: "/", with: "_")
        let outputURL = freezeDir.appendingPathComponent("frozen_\(safeTrackName)_\(trackIndex).wav")

        // Render using existing renderChunkToWav
        try await renderChunkToWav(
            notes: trackNotes,
            startTick: minTick,
            endTick: maxTick,
            outputURL: outputURL
        )

        // Create audio clip for the frozen audio
        let durationTicks = maxTick - minTick
        let clip = AudioClip(
            displayName: "\(trackName) (Frozen)",
            filePath: outputURL.path,
            trackKey: "\(trackIndex):0",
            startTick: minTick,
            durationTicks: durationTicks
        )
        pianoRollAudioClips.append(clip)

        // Mute the MIDI track
        mutedTracks.insert(trackIndex)

        // Record frozen state
        frozenTracks[trackIndex] = outputURL

        NSLog("[Freeze] Track %d (%@) frozen to %@", trackIndex, trackName, outputURL.lastPathComponent)
    }

    /// Removes the frozen audio clip, unmutes the MIDI track, and deletes the frozen WAV file.
    func unfreezeTrack(trackIndex: Int) {
        guard let frozenURL = frozenTracks[trackIndex] else {
            NSLog("[Freeze] Track %d is not frozen", trackIndex)
            return
        }

        // Remove the audio clip
        pianoRollAudioClips.removeAll { $0.filePath == frozenURL.path }

        // Unmute the MIDI track
        mutedTracks.remove(trackIndex)

        // Delete the frozen WAV file
        try? FileManager.default.removeItem(at: frozenURL)

        // Clear frozen state
        frozenTracks.removeValue(forKey: trackIndex)

        let trackName = pianoRollTrackNames[trackIndex] ?? "Track \(trackIndex)"
        NSLog("[Freeze] Track %d (%@) unfrozen", trackIndex, trackName)
    }
}

// MARK: - App Support Directory

@available(macOS 26.0, *)
extension ScoreStore {
    /// Ensures ~/Library/Application Support/Novotro Score/ exists (for lessons.md, etc.)
    static func ensureAppSupportDirectory() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Novotro Score")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - Canonical Suno Cover Workflow

@available(macOS 26.0, *)
extension ScoreStore {

    func sunoRunCanonicalCover() async {
        guard let selectedSong = selectedMidiAsset else {
            sunoGenerateStatus = "Select a song before running Suno."
            appendSunoLog("No song selected for Suno cover generation", level: .warning)
            return
        }
        guard let projectRoot = resolvedSunoProjectRoot() else {
            sunoGenerateStatus = "Open the full opera project before running Suno."
            appendSunoLog("Could not resolve the opera project root for Suno export", level: .error)
            return
        }

        let relativePath = selectedSong.relativePath
        let baseTitle = Self.sunoBaseTitle(from: relativePath)
        let outputRoot = projectRoot.appendingPathComponent("Suno", isDirectory: true)
        let version = nextSunoVersion(for: baseTitle, outputRoot: outputRoot)
        let songDir = outputRoot.appendingPathComponent(baseTitle, isDirectory: true)
        let uploadURL = songDir.appendingPathComponent(String(format: "%@ v%03d-Upload.wav", baseTitle, version))
        let lyrics = resolvedSunoLyricsForCurrentPreset()

        guard lyrics != nil else {
            sunoGenerateStatus = "This preset needs real lyrics from the Lyrics tab."
            appendSunoLog("Preset \(sunoCoverPreset.title) requires real lyrics", level: .warning)
            return
        }

        sunoStopPreview()
        sunoIsGenerating = true
        sunoGenerateStatus = "Preparing canonical Suno cover run..."

        let generation = SunoGeneration(
            songPath: relativePath,
            baseTitle: baseTitle,
            version: version,
            prompt: sunoResolvedCoverPrompt,
            style: sunoResolvedCoverPrompt,
            excludeStyles: sunoExcludeStyles,
            lyrics: lyrics,
            status: .exporting
        )
        sunoGenerations.insert(generation, at: 0)
        let generationID = generation.id

        defer { sunoIsGenerating = false }

        do {
            appendSunoLog("Preparing Suno MCP server at 127.0.0.1:3001")
            try await ensureSunoServerReady()

            appendSunoLog("Exporting fresh upload WAV to \(uploadURL.path)")
            updateSunoGeneration(generationID, status: .exporting)
            sunoGenerateStatus = "Exporting fresh upload WAV..."
            try await exportCurrentSongForSuno(projectRoot: projectRoot, relativePath: relativePath, uploadURL: uploadURL)

            appendSunoLog("Opening headless Suno browser session")
            _ = try await sunoClient.openBrowser(headless: true)

            updateSunoGeneration(generationID, status: .submitting)
            sunoGenerateStatus = "Submitting cover request..."
            appendSunoLog("Submitting canonical cover request for \(baseTitle)")

            let result = try await sunoClient.createCover(
                filePath: uploadURL.path,
                style: sunoResolvedCoverPrompt,
                lyrics: lyrics ?? "[Instrumental]",
                excludeStyles: normalizedSunoExcludeStyles(),
                weirdness: sunoCoverWeirdness,
                styleInfluence: sunoCoverStyleInfluence,
                audioInfluence: sunoCoverAudioInfluence,
                vocalGender: sunoResolvedVocalGenderArgument,
                title: ""
            )

            let resolvedTitle = Self.extractSunoTitle(from: result) ?? baseTitle
            var songIDs = Self.extractSunoSongIDs(from: result)
            if songIDs.count < 2 {
                appendSunoLog("Primary response returned \(songIDs.count) song IDs; querying visible song list")
                let queriedIDs = try await queryVisibleSunoSongIDs(titleText: resolvedTitle)
                for songID in queriedIDs where !songIDs.contains(songID) {
                    songIDs.append(songID)
                }
            }

            guard songIDs.count >= 2 else {
                throw SunoAPIError.toolFailed("Suno did not return two cover song IDs for \(resolvedTitle).")
            }

            let finalSongIDs = Array(songIDs.prefix(2))
            updateSunoGeneration(
                generationID,
                status: .polling,
                songIDs: finalSongIDs,
                coverTitle: resolvedTitle,
                resultMessage: result,
                trackID: finalSongIDs.first
            )
            appendSunoLog("Cover submitted as \(resolvedTitle) with song IDs \(finalSongIDs.joined(separator: ", "))", level: .success)

            sunoGenerateStatus = "Waiting for Suno outputs to finish..."
            for songID in finalSongIDs {
                try await waitForSunoSongComplete(songID: songID)
            }

            updateSunoGeneration(generationID, status: .downloading)
            sunoGenerateStatus = "Downloading WAV outputs..."
            appendSunoLog("Downloading both Suno WAV outputs into \(outputRoot.path)")

            var downloadedPaths: [String] = []
            for (index, songID) in finalSongIDs.enumerated() {
                let suffix = index == 0 ? "A" : "B"
                _ = try await sunoClient.downloadCover(songID: songID, downloadPath: outputRoot.path)
                if let path = locateDownloadedCover(baseTitle: baseTitle, version: version, songID: songID, suffix: suffix, outputRoot: outputRoot) {
                    downloadedPaths.append(path)
                }
            }

            updateSunoGeneration(
                generationID,
                status: .downloaded,
                songIDs: finalSongIDs,
                coverTitle: resolvedTitle,
                downloadedFilePaths: downloadedPaths,
                downloadedFilePath: downloadedPaths.first,
                trackID: finalSongIDs.first
            )
            sunoGenerateStatus = downloadedPaths.isEmpty
                ? "Cover finished; verify downloads in the project Suno folder."
                : "Downloaded \(downloadedPaths.count) Suno cover WAVs"
            appendSunoLog("Canonical Suno cover run finished for \(resolvedTitle)", level: .success)
        } catch {
            updateSunoGeneration(generationID, status: .error, errorMessage: error.localizedDescription)
            sunoGenerateStatus = "Suno cover failed: \(error.localizedDescription)"
            appendSunoLog("Canonical Suno cover failed: \(error.localizedDescription)", level: .error)
        }
    }

    func sunoRevealGenerationDownloads(_ generationID: UUID) {
        guard let generation = sunoGenerations.first(where: { $0.id == generationID }) else { return }
        let paths = generation.resolvedDownloadedFilePaths
        guard !paths.isEmpty else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting(paths.map(URL.init(fileURLWithPath:)))
        #endif
    }

    private func ensureSunoServerReady() async throws {
        if !sunoClient.isConfigured || sunoClient.baseURL == "http://localhost:3000" {
            sunoClient.baseURL = "http://127.0.0.1:3001"
        }

        if sunoServerManager.state == .running {
            return
        }

        if sunoServerManager.isBootstrapped {
            try await sunoServerManager.startAndWaitForReady()
        } else {
            try await sunoServerManager.bootstrap { _ in }
        }
    }

    private func resolvedSunoProjectRoot() -> URL? {
        let sourceURL = workingProjectURL ?? projectURL
        guard let sourceURL else { return nil }
        if sourceURL.pathExtension.lowercased() == "ows" {
            let songsDirectory = sourceURL.deletingLastPathComponent()
            if songsDirectory.lastPathComponent == "Songs" {
                return songsDirectory.deletingLastPathComponent()
            }
            return songsDirectory
        }
        return sourceURL
    }

    private func resolvedSunoLyricsForCurrentPreset() -> String? {
        if !sunoCoverPreset.requiresLyrics {
            return "[Instrumental]"
        }
        let lyrics = formattedSunoLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return lyrics.isEmpty ? nil : lyrics
    }

    private func normalizedSunoExcludeStyles() -> String {
        let trimmed = sunoExcludeStyles.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "-drums, -percussion, -cymbals, -snare, -kick"
        }
        let parts = trimmed.split(separator: ",").map {
            let token = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return token }
            return token.hasPrefix("-") ? token : "-\(token)"
        }
        return parts.joined(separator: ", ")
    }

    private func nextSunoVersion(for baseTitle: String, outputRoot: URL) -> Int {
        let songDirectory = outputRoot.appendingPathComponent(baseTitle, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: songDirectory, includingPropertiesForKeys: nil)) ?? []
        var highest = 0
        for file in files {
            let name = file.lastPathComponent
            guard let match = name.range(of: #" v(\d{3})(?:-[A-Za-z]+)?\.wav$"#, options: .regularExpression) else {
                continue
            }
            let versionText = name[match]
                .replacingOccurrences(of: " v", with: "")
                .components(separatedBy: "-")
                .first?
                .replacingOccurrences(of: ".wav", with: "") ?? ""
            if let version = Int(versionText) {
                highest = max(highest, version)
            }
        }
        return highest + 1
    }

    private func exportCurrentSongForSuno(projectRoot: URL, relativePath: String, uploadURL: URL) async throws {
        let fm = FileManager.default
        let scriptURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/export-headless-wav.sh")
        let scoreBinaryURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira Writer/Packages/NovotroScore/.build/arm64-apple-macosx/release/NovotroScore")

        guard fm.fileExists(atPath: scriptURL.path) else {
            throw SunoAPIError.serverError("Missing export script at \(scriptURL.path)")
        }
        guard fm.fileExists(atPath: scoreBinaryURL.path) else {
            throw SunoAPIError.serverError("Missing NovotroScore export binary at \(scoreBinaryURL.path)")
        }

        try fm.createDirectory(at: uploadURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        for attempt in 1...3 {
            if fm.fileExists(atPath: uploadURL.path) {
                try? fm.removeItem(at: uploadURL)
            }

            let result = try await runSunoExportProcess(
                scriptURL: scriptURL,
                projectRoot: projectRoot,
                relativePath: relativePath,
                outputURL: uploadURL,
                scoreBinaryURL: scoreBinaryURL
            )

            if result.exitCode == 0 {
                return
            }
            if result.exitCode == 10 {
                appendSunoLog("Export returned silent-WAV warning (rc=10); continuing", level: .warning)
                return
            }

            let isRetryableSignal = result.exitCode == 133 || result.exitCode == 134 || result.exitCode == 139 || result.exitCode >= 128
            if attempt < 3 && isRetryableSignal {
                appendSunoLog("Export crashed with rc=\(result.exitCode); retrying \(attempt)/3", level: .warning)
                try await Task.sleep(for: .seconds(5))
                continue
            }

            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? "Export failed with rc=\(result.exitCode)" : stderr
            throw SunoAPIError.serverError(message)
        }
    }

    private func runSunoExportProcess(
        scriptURL: URL,
        projectRoot: URL,
        relativePath: String,
        outputURL: URL,
        scoreBinaryURL: URL
    ) async throws -> (exitCode: Int32, stderr: String) {
        final class ExportState: @unchecked Sendable {
            var stderr = ""
            var resumed = false
            let lock = NSLock()
        }

        let sharedState = ExportState()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = scriptURL
            process.arguments = [
                "--project", projectRoot.path,
                "--song-path", relativePath,
                "--output", outputURL.path,
            ]
            process.currentDirectoryURL = projectRoot

            var env = ProcessInfo.processInfo.environment
            env["NOVOTRO_ALLOW_BLUETOOTH_OUTPUT"] = "1"
            env["NOVOTRO_SCORE_BIN"] = scoreBinaryURL.path
            process.environment = env

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = FileHandle.nullDevice

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                sharedState.lock.withLock { sharedState.stderr += text }
            }

            process.terminationHandler = { terminated in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let shouldResume = sharedState.lock.withLock {
                    if sharedState.resumed { return false }
                    sharedState.resumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(returning: (terminated.terminationStatus, sharedState.stderr))
            }

            do {
                try process.run()
            } catch {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                _ = sharedState.lock.withLock {
                    if sharedState.resumed { return false }
                    sharedState.resumed = true
                    return true
                }
                continuation.resume(throwing: error)
            }
        }
    }

    private func waitForSunoSongComplete(songID: String, timeoutSeconds: TimeInterval = 1200) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let status = try await sunoClient.getCoverStatus(songID: songID)
            if status.contains("status=complete") {
                return
            }
            if status.contains("status=not_found") || status.contains("❌") {
                throw SunoAPIError.toolFailed(status)
            }
            try await Task.sleep(for: .seconds(10))
        }
        throw SunoAPIError.toolFailed("Timed out waiting for Suno song \(songID)")
    }

    private func queryVisibleSunoSongIDs(titleText: String, timeoutSeconds: TimeInterval = 240) async throws -> [String] {
        let script = #"""
        (titleText) => {
            const visible = (el) => {
                if (!el) return false;
                const rect = el.getBoundingClientRect();
                const style = getComputedStyle(el);
                return !!el.offsetParent
                    && style.display !== 'none'
                    && style.visibility !== 'hidden'
                    && rect.width > 0
                    && rect.height > 0;
            };
            const norm = (s) => (s || '').toLowerCase().replace(/\s+/g, ' ').trim();
            const hint = norm(titleText);
            const seen = new Set();
            const out = [];
            for (const anchor of document.querySelectorAll('a[href*="/song/"]')) {
                if (!visible(anchor)) continue;
                const href = anchor.href || anchor.getAttribute('href') || '';
                const match = href.match(/\/song\/([0-9a-f-]{36})/i);
                if (!match || seen.has(match[1])) continue;
                const container = anchor.closest('article, li, [role="listitem"], [data-testid], div') || anchor;
                const text = ((container && container.innerText) || anchor.innerText || '').trim();
                if (hint && norm(text).includes(hint)) {
                    seen.add(match[1]);
                    out.push(match[1]);
                }
            }
            return out;
        }
        """#

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let result = try await sunoClient.evaluateJS(script: script, titleText: titleText)
            let songIDs = Self.extractUUIDs(from: result)
            if songIDs.count >= 2 {
                return Array(songIDs.prefix(2))
            }
            try await Task.sleep(for: .seconds(5))
        }
        return []
    }

    private func locateDownloadedCover(
        baseTitle: String,
        version: Int,
        songID: String,
        suffix: String,
        outputRoot: URL
    ) -> String? {
        let expected = outputRoot
            .appendingPathComponent(baseTitle, isDirectory: true)
            .appendingPathComponent(String(format: "%@ v%03d-%@.wav", baseTitle, version, suffix))
        if FileManager.default.fileExists(atPath: expected.path) {
            return expected.path
        }

        let songDirectory = outputRoot.appendingPathComponent(baseTitle, isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(at: songDirectory, includingPropertiesForKeys: nil)) ?? []
        for candidate in candidates where candidate.pathExtension.lowercased() == "wav" {
            let name = candidate.lastPathComponent.lowercased()
            if name.contains(songID.prefix(8).lowercased()) || name.contains("-\(suffix.lowercased()).wav") {
                return candidate.path
            }
        }

        return nil
    }

    private func updateSunoGeneration(
        _ generationID: UUID,
        status: SunoGenerationStatus,
        songIDs: [String]? = nil,
        coverTitle: String? = nil,
        resultMessage: String? = nil,
        downloadedFilePaths: [String]? = nil,
        downloadedFilePath: String? = nil,
        trackID: String? = nil,
        errorMessage: String? = nil
    ) {
        guard let index = sunoGenerations.firstIndex(where: { $0.id == generationID }) else { return }
        sunoGenerations[index].status = status
        if let songIDs { sunoGenerations[index].songIDs = songIDs }
        if let coverTitle { sunoGenerations[index].coverTitle = coverTitle }
        if let resultMessage { sunoGenerations[index].resultMessage = resultMessage }
        if let downloadedFilePaths { sunoGenerations[index].downloadedFilePaths = downloadedFilePaths }
        if let downloadedFilePath { sunoGenerations[index].downloadedFilePath = downloadedFilePath }
        if let trackID { sunoGenerations[index].trackID = trackID }
        if let errorMessage { sunoGenerations[index].errorMessage = errorMessage }
    }

    private static func extractSunoSongIDs(from resultText: String) -> [String] {
        guard let match = resultText.range(of: #"Song IDs: \[.*\]"#, options: .regularExpression) else {
            return []
        }
        return extractUUIDs(from: String(resultText[match]))
    }

    private static func extractSunoTitle(from resultText: String) -> String? {
        guard let match = resultText.range(of: #"(?m)^Title: .+$"#, options: .regularExpression) else {
            return nil
        }
        let line = String(resultText[match])
        return line.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractUUIDs(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        ) else {
            return []
        }
        let nsText = text as NSString
        var seen: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let value = nsText.substring(with: match.range)
            if !seen.contains(value) {
                seen.append(value)
            }
        }
        return seen
    }

    static func sunoBaseTitle(from relativePath: String) -> String {
        let stem = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        let parts = stem.components(separatedBy: " - ")
        guard parts.count >= 2 else { return stem }
        return parts[0] + " " + parts.dropFirst().joined(separator: " - ")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
