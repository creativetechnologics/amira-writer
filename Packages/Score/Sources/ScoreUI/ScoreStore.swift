#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@preconcurrency import AVFoundation
import Accelerate
import Foundation
import ProjectKit
import os
import UniformTypeIdentifiers

// MARK: - Debug Logging

/// Reuse a single formatter to avoid allocating ISO8601DateFormatter on every log call.
private nonisolated(unsafe) let novotroDebugDateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

private func novotroDebugLog(_ message: String) {
    let ts = novotroDebugDateFormatter.string(from: Date())
    let line = "[\(ts)] [Score] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/score-debug.log")
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

private enum HostedAudioUnitExportMode: String {
    case auto
    case realtime
    case offline

    static func current() -> HostedAudioUnitExportMode {
        let environment = ProcessInfo.processInfo.environment
        // AMIRA_HEADLESS_FORCE_OFFLINE=1 — skip qualification entirely, go straight to
        // offline render. Use this for BBC SO headless export where qualification always
        // rejects due to XPC shared-state interference.
        if environment["AMIRA_HEADLESS_FORCE_OFFLINE"] == "1" {
            return .offline
        }
        if environment["AMIRA_PREFER_OFFLINE_AU_EXPORT"] == "1" {
            return .offline
        }
        if let raw = environment["AMIRA_AU_EXPORT_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let parsed = HostedAudioUnitExportMode(rawValue: raw) {
            return parsed
        }
        return .auto
    }
}

private enum HostedAudioUnitOfflineRenderProfile: String, Codable, CaseIterable, Sendable {
    case standard
    case conservative
}

private struct HostedAudioUnitOfflineQualification: Codable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case qualified
        case rejected
    }

    let verdict: Verdict
    let similarity: Double
    let envelopeSimilarity: Double
    let durationDeltaSeconds: Double
    let renderProfile: HostedAudioUnitOfflineRenderProfile
    let leadingAlignmentSeconds: Double?
    let checkedAt: Date
    let detail: String

    // Custom encoder: JSONEncoder's default strategy throws on non-finite Double values
    // (NaN, +infinity, -infinity). durationDeltaSeconds is initialised to .infinity when
    // no profile has completed, so we clamp non-finite values to Double.greatestFiniteMagnitude
    // with the sign preserved, and NaN to 0, rather than letting the write fail.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(verdict, forKey: .verdict)
        try container.encode(Self.finiteDouble(similarity), forKey: .similarity)
        try container.encode(Self.finiteDouble(envelopeSimilarity), forKey: .envelopeSimilarity)
        try container.encode(Self.finiteDouble(durationDeltaSeconds), forKey: .durationDeltaSeconds)
        try container.encode(renderProfile, forKey: .renderProfile)
        try container.encodeIfPresent(leadingAlignmentSeconds.map(Self.finiteDouble), forKey: .leadingAlignmentSeconds)
        try container.encode(checkedAt, forKey: .checkedAt)
        try container.encode(detail, forKey: .detail)
    }

    private static func finiteDouble(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        if value.isInfinite { return value > 0 ? Double.greatestFiniteMagnitude : -Double.greatestFiniteMagnitude }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case verdict, similarity, envelopeSimilarity, durationDeltaSeconds
        case renderProfile, leadingAlignmentSeconds, checkedAt, detail
    }
}

private struct HostedAudioUnitQualificationArtifactRecord: Codable, Sendable {
    let createdAt: Date
    let qualificationKey: String
    let excerptStartTick: Int
    let excerptEndTick: Int
    let verdict: HostedAudioUnitOfflineQualification.Verdict
    let detail: String
    let files: [String]
}

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
        case .autosave: return "\(baseName) - Revision"
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

                // Canonical score data lives in playback/playbackSnapshot. Legacy "music"
                // blobs remain opaque until they can be migrated safely.
                var playback: OWSPlaybackSnapshot?
                if let playbackObject = vDict["playback"] ?? vDict["playbackSnapshot"] {
                    if let playbackData = try? JSONSerialization.data(withJSONObject: playbackObject) {
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
                        versionArray[idx]["playbackSnapshot"] = pbObj
                    }
                }
            } else {
                // NEW version not yet on disk — serialize and append
                if let vData = try? encoder.encode(docVersion),
                   var vObj = try? JSONSerialization.jsonObject(with: vData) as? [String: Any] {
                    if let playbackObject = vObj["playback"] {
                        vObj["playbackSnapshot"] = playbackObject
                    }
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

    /// True when the active version has playable score data loaded, not just a file stub.
    var hasPlayableScoreData: Bool {
        guard let playback = document.activeVersion()?.playback else { return false }
        return !playback.notes.isEmpty || !playback.audioClips.isEmpty
    }
}

// MARK: - OWP Project I/O

enum OWPProjectIO {
    static let metadataDir = "Metadata"
    static let projectMetadataFile = "Metadata/project.json"
    static let projectInstrumentsFile = "Settings/instruments.json"
    static let legacyProjectInstrumentsFile = "Instruments.json"
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
            throw NSError(domain: "Score", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid project: \(url.lastPathComponent)"])
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
            // Skip SyncThing conflict files — they should not appear as songs
            let filename = fileURL.lastPathComponent
            if filename.contains(".sync-conflict-") { continue }
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
        let decoder = configuredDecoder()
        for relativePath in [projectInstrumentsFile, legacyProjectInstrumentsFile] {
            let fileURL = packageURL.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { continue }

            if let decoded = try? decoder.decode([String: InstrumentMapping].self, from: data) {
                return normalizeProjectInstrumentMappings(decoded)
            }
            if let decoded = try? decoder.decode([InstrumentMapping].self, from: data) {
                return normalizedProjectInstrumentMappings(decoded)
            }

            NSLog("[OWP] Failed to decode project instruments at %@", fileURL.path)
        }

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
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)

        let legacyFileURL = packageURL.appendingPathComponent(legacyProjectInstrumentsFile)
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try data.write(to: legacyFileURL, options: .atomic)
        }
    }

    // MARK: - SoundFont Embedding

    /// Copy an SF2 file into the OWP bundle's SoundFonts/ directory.
    /// Returns the relative path within the bundle. Deduplicates by filename.
    static func embedSoundFont(absolutePath: String, in owpBundleURL: URL) throws -> String {
        let sfDir = ProjectPaths(root: owpBundleURL).soundFonts
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
                let fallbackURL = ProjectPaths(root: owpBundleURL).soundFonts
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

    /// Master toggle: lightweight (SF2) vs heavyweight (AU) playback.
    /// Persisted to UserDefaults so it survives app restarts — project-wide, not per-song.
    var masterInstrumentMode: InstrumentSourceType = {
        let raw = UserDefaults.standard.string(forKey: "operawriter.masterInstrumentMode") ?? ""
        return InstrumentSourceType(rawValue: raw) ?? .soundFont
    }()

    /// Toggle master instrument mode and update all unpinned mappings.
    func setMasterInstrumentMode(_ mode: InstrumentSourceType) {
        guard mode != masterInstrumentMode else { return }

        // Stop playback if active
        if isPlaying {
            stopPlayback()
        }

        masterInstrumentMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "operawriter.masterInstrumentMode")
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
    var isPlaybackActivityActive: Bool {
        isPlaying || pendingPlaybackStartTask != nil || pendingAdvance || pendingAdvanceWorkItem != nil
    }
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
    var isPresentingFullMixExportPanel: Bool = false
    var fullMixExportStatus: String = ""
    var fullMixExportDetailStatus: String = ""
    /// Export progress from 0.0 to 1.0 — updated during real-time render exports.
    var fullMixExportProgress: Double = 0
    @ObservationIgnored private var hostedAudioUnitOfflineQualificationCache: [String: HostedAudioUnitOfflineQualification] = [:]

    // MARK: - Batch / Send-to-Mix Export
    var isBatchExporting: Bool = false
    var batchExportStatus: String = ""
    var batchExportProgress: Double = 0

    /// Posted when a song is successfully exported to Mix/exports/.
    /// UserInfo keys: "wavURL" (URL), "songRelativePath" (String).
    nonisolated static let didExportSongToMix = Notification.Name("novotro.score.didExportSongToMix")

    // MARK: - Suno Export
    var sunoSplitTicks: [Int] = []
    var sunoExportProgress: Double = 0
    var sunoExportStatus: String = ""
    var isExportingSunoChunks: Bool = false
    var sunoSingleSFOverride: Bool = false
    var sunoSingleSFPath: String = ""      // relative path into sample library

    // MARK: - Suno API Integration (CLI)
    @ObservationIgnored let sunoCLI = SunoCLIRunner()

    // Mirror for UI (SunoCLIRunner is @ObservationIgnored)
    var sunoCLIIsInstalled: Bool { sunoCLI.isInstalled }
    var sunoCLILastSelftest: SunoSelftestResult?
    var sunoCLIErrorMessage: String?
    var sunoCLIStatusMessage: String?

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
        ?? "drums, percussion, cymbals, snare, kick" {
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
    /// Whether cover generation targets the current song or a multi-song checklist.
    var sunoCoverSourceMode: SunoCoverSourceMode = {
        let raw = UserDefaults.standard.string(forKey: "sunoCoverSourceMode") ?? SunoCoverSourceMode.currentSong.rawValue
        return SunoCoverSourceMode(rawValue: raw) ?? .currentSong
    }() {
        didSet { UserDefaults.standard.set(sunoCoverSourceMode.rawValue, forKey: "sunoCoverSourceMode") }
    }
    /// Transient set of song relative paths selected for multi-song cover generation.
    var sunoCoverSelectedSongPaths: Set<String> = []
    /// Number of queued Suno cover submissions per target song.
    var sunoCoverIterations: Int = {
        let stored = UserDefaults.standard.object(forKey: "sunoCoverIterations") as? Int
        return min(12, max(1, stored ?? 1))
    }() {
        didSet { UserDefaults.standard.set(sunoCoverIterations, forKey: "sunoCoverIterations") }
    }
    /// Optional prompt override for Cover mode (empty string = use preset prompt).
    var sunoCoverPromptOverride: String = UserDefaults.standard.string(forKey: "sunoCoverPromptOverride") ?? "" {
        didSet { UserDefaults.standard.set(sunoCoverPromptOverride, forKey: "sunoCoverPromptOverride") }
    }
    /// Optional lyrics override for Cover mode (empty string = use Lyrics tab).
    var sunoCoverLyricsOverride: String = UserDefaults.standard.string(forKey: "sunoCoverLyricsOverride") ?? "" {
        didSet { UserDefaults.standard.set(sunoCoverLyricsOverride, forKey: "sunoCoverLyricsOverride") }
    }
    /// User-saved cover prompt presets.
    var sunoCoverPromptPresets: [SunoCoverPromptPreset] = {
        guard let data = UserDefaults.standard.data(forKey: "sunoCoverPromptPresets"),
              let decoded = try? JSONDecoder().decode([SunoCoverPromptPreset].self, from: data) else {
            return []
        }
        return decoded
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(sunoCoverPromptPresets) {
                UserDefaults.standard.set(data, forKey: "sunoCoverPromptPresets")
            }
        }
    }
    /// ID of the currently-selected cover prompt preset (nil = none selected).
    var sunoSelectedPromptPresetID: UUID? = {
        guard let raw = UserDefaults.standard.string(forKey: "sunoSelectedPromptPresetID") else { return nil }
        return UUID(uuidString: raw)
    }() {
        didSet {
            if let id = sunoSelectedPromptPresetID {
                UserDefaults.standard.set(id.uuidString, forKey: "sunoSelectedPromptPresetID")
            } else {
                UserDefaults.standard.removeObject(forKey: "sunoSelectedPromptPresetID")
            }
        }
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

    var sunoResolvedCoverTargetPaths: [String] {
        switch sunoCoverSourceMode {
        case .currentSong:
            guard let selectedSong = selectedMidiAsset else { return [] }
            return [selectedSong.relativePath]
        case .selectedSongs:
            return songAssets.map(\.relativePath).filter { sunoCoverSelectedSongPaths.contains($0) }
        }
    }

    var sunoCoverTargetCount: Int {
        sunoResolvedCoverTargetPaths.count
    }

    var sunoCoverTotalSubmissionCount: Int {
        sunoCoverTargetCount * max(1, sunoCoverIterations)
    }

    var sunoCoverExpectedOutputCount: Int {
        sunoCoverTotalSubmissionCount * 2
    }

    var sunoRunCanonicalCoverButtonTitle: String {
        let iterations = max(1, sunoCoverIterations)
        return iterations == 1 ? "Run Canonical Cover" : "Run Canonical Cover ×\(iterations)"
    }

    var sunoCoverQueueSummary: String {
        let targetCount = sunoCoverTargetCount
        let iterations = max(1, sunoCoverIterations)
        let submitCount = targetCount * iterations
        let expectedOutputs = submitCount * 2

        switch (targetCount, iterations) {
        case (0, _):
            return "No songs queued yet."
        case (1, 1):
            return "1 submit → about 2 outputs"
        case (1, _):
            return "\(iterations) submits → about \(expectedOutputs) outputs"
        default:
            return "\(iterations) cycles × \(targetCount) songs → \(submitCount) submits / about \(expectedOutputs) outputs"
        }
    }

    var sunoCoverQueueDelaySummary: String {
        "Queue spacing is humanized with randomized 5–10 minute cooldowns between submits."
    }

    var sunoCanRunCanonicalCover: Bool {
        effectiveSunoCoverLyrics() != nil && !sunoResolvedCoverTargetPaths.isEmpty
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

    // MARK: - Cover Prompt Preset Management

    /// Snapshot current cover-pane state into a new preset with the given name.
    func sunoSavePromptPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = SunoCoverPromptPreset(
            name: trimmed,
            promptOverride: sunoCoverPromptOverride.isEmpty ? nil : sunoCoverPromptOverride,
            lyricsOverride: sunoCoverLyricsOverride.isEmpty ? nil : sunoCoverLyricsOverride,
            excludeStyles: sunoExcludeStyles,
            weirdness: sunoCoverWeirdness,
            styleInfluence: sunoCoverStyleInfluence,
            audioInfluence: sunoCoverAudioInfluence
        )
        var presets = sunoCoverPromptPresets
        // Replace existing preset with the same name, else append.
        if let idx = presets.firstIndex(where: { $0.name == trimmed }) {
            var replacement = preset
            replacement.id = presets[idx].id
            presets[idx] = replacement
            sunoSelectedPromptPresetID = replacement.id
        } else {
            presets.append(preset)
            sunoSelectedPromptPresetID = preset.id
        }
        sunoCoverPromptPresets = presets
    }

    func sunoDeletePromptPreset(id: UUID) {
        sunoCoverPromptPresets.removeAll { $0.id == id }
        if sunoSelectedPromptPresetID == id {
            sunoSelectedPromptPresetID = nil
        }
    }

    func sunoApplyPromptPreset(id: UUID) {
        guard let preset = sunoCoverPromptPresets.first(where: { $0.id == id }) else { return }
        sunoCoverPromptOverride = preset.promptOverride ?? ""
        sunoCoverLyricsOverride = preset.lyricsOverride ?? ""
        sunoExcludeStyles = preset.excludeStyles
        sunoCoverWeirdness = preset.weirdness
        sunoCoverStyleInfluence = preset.styleInfluence
        sunoCoverAudioInfluence = preset.audioInfluence
        sunoSelectedPromptPresetID = preset.id
    }

    /// Returns the Mix export WAV URL and modification date for a song, or nil if it doesn't exist.
    /// Mirrors `mixExportURL(for:)` exactly — same project root, same `Mix/exports/` dir, same
    /// displayName-based sanitizer (`[^A-Za-z0-9_-]+` → `_`, trimmed of leading/trailing `_`).
    func sunoMixExportInfo(for relativePath: String) -> (url: URL, modifiedAt: Date)? {
        guard let projectRoot = workingProjectURL ?? projectURL else { return nil }
        guard let asset = songAssets.first(where: { $0.relativePath == relativePath }) else {
            return nil
        }
        let raw = asset.displayName
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let safeName = trimmed.isEmpty ? "untitled" : trimmed
        let wavURL = ProjectPaths(root: projectRoot).mixExports
            .appendingPathComponent("\(safeName).wav")
        let fm = FileManager.default
        guard fm.fileExists(atPath: wavURL.path),
              let attrs = try? fm.attributesOfItem(atPath: wavURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return (wavURL, modDate)
    }

    /// Returns the songs eligible for Suno batch-selection: only assets with playable score data.
    var sunoBatchSelectableSongPaths: [(relativePath: String, displayName: String)] {
        songAssets
            .filter(\.hasPlayableScoreData)
            .map { asset in
                (relativePath: asset.relativePath, displayName: asset.displayName)
            }
    }

    /// Returns every song in the current project for the multi-song picker UI.
    func sunoAvailableSongPaths() -> [(relativePath: String, displayName: String)] {
        songAssets.map { asset in
            (relativePath: asset.relativePath, displayName: asset.displayName)
        }
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
            } else if saveIndicator != .saving {
                saveIndicator = projectURL == nil ? .idle : .saved
            }
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

    // MARK: - Persistence

    private static let externalWatchInterval: TimeInterval = 0.55
    private var dirtySongPaths: Set<String> = []
    private var isSavingInternal: Bool = false
    private var lastSelectedMidiID: UUID?
    private var loadedMidiCache: [UUID: ParsedPianoRoll] = [:]
    private var hydratedSongPaths: Set<String> = []
    private var pendingPlaybackStartTask: Task<Void, Never>?
    private var deferredSelectionLoadTask: Task<Void, Never>?
    private var externalFileWatchWorkItem: DispatchWorkItem?
    private var isExternalFileWatchingActive = false
    private var externalFileWatchGeneration: UInt64 = 0
    private var lastKnownExternalSnapshots: [String: ExternalProjectFileSnapshot] = [:]
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
        hostedAudioUnitOfflineQualificationCache = Self.loadHostedAudioUnitOfflineQualificationCache()
        setupPlaybackCallbacks()
        setupAppTerminationHandler()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            self.setupMIDIInput()
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
        do {
            let loaded = try await ProjectDatabaseBridge.loadScoreProject(url: url)
            let meta = loaded.metadata
            let stubs = loaded.stubs
            let isStandalone = url.pathExtension.lowercased() == "ows"
            self.projectURL = url
            self.workingProjectURL = loaded.workingProjectURL
            self.metadata = meta
            self.songStubs = stubs
            self.isStandaloneSongWorkspace = isStandalone
            self.songAssets = loaded.songAssets
            self.librettoFiles = loaded.librettoFiles
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
                setSelectedMidi(id: first.id, deferLoading: true)
            }

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
        isExternalFileWatchingActive = true
        externalFileWatchGeneration &+= 1
        let generation = externalFileWatchGeneration

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isExternalFileWatchingActive,
                  self.externalFileWatchGeneration == generation else { return }
            self.checkForExternalProjectChanges()
            guard self.isExternalFileWatchingActive,
                  self.externalFileWatchGeneration == generation else { return }
            self.scheduleExternalFileWatch(generation: generation)
        }
        externalFileWatchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalWatchInterval, execute: workItem)
    }

    private func scheduleExternalFileWatch(generation: UInt64) {
        guard isExternalFileWatchingActive,
              externalFileWatchGeneration == generation,
              fileProjectURL != nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isExternalFileWatchingActive,
                  self.externalFileWatchGeneration == generation else { return }
            self.checkForExternalProjectChanges()
            guard self.isExternalFileWatchingActive,
                  self.externalFileWatchGeneration == generation else { return }
            self.scheduleExternalFileWatch(generation: generation)
        }
        externalFileWatchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalWatchInterval, execute: workItem)
    }

    private func stopExternalFileWatch() {
        isExternalFileWatchingActive = false
        externalFileWatchGeneration &+= 1
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

        for path in [
            OWPProjectIO.projectMetadataFile,
            ProjectDatabaseBridge.legacyMetadataPath,
            OWPProjectIO.projectInstrumentsFile,
            OWPProjectIO.legacyProjectInstrumentsFile,
        ] {
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
            await self.loadProject(url: sourceProjectURL)
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
                let asset = self.runtimeStableAsset(
                    try await OWPProjectIO.loadSongAsync(stub: stub),
                    relativePath: relativePath
                )
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
            }
        } else if [OWPProjectIO.projectInstrumentsFile, OWPProjectIO.legacyProjectInstrumentsFile].contains(path) {
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

    func setSelectedMidi(
        id: MidiAsset.ID?,
        stopPlaybackBeforeSelect: Bool = true,
        deferLoading: Bool = false
    ) {
        cancelPendingPlaybackStart()
        cancelDeferredSelectionLoad()
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
        sourcePlaybackReloadAttempted.removeAll()
        if let selectedPath = selectedMidiAsset?.relativePath,
           let libretto = librettoFiles.first(where: { $0.relativePath == selectedPath }) {
            selectedLibrettoID = libretto.id
        }
        if deferLoading {
            scheduleDeferredSelectionLoad()
        } else {
            loadSelectedMidiIfPossible()
        }
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
        let playbackNoteCount = playback?.notes.count ?? 0
        let shouldMarkLoaded = playbackNoteCount > 0 || dirtySongPaths.contains(songAsset.relativePath)
        novotroDebugLog("loadSelectedMidiIfPossible: \(songAsset.relativePath) playback=\(playback != nil ? "YES (\(playbackNoteCount) notes)" : "nil")")
        if let playback, !playback.notes.isEmpty {
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
            if dirtySongPaths.contains(songAsset.relativePath) {
                statusMessage = "Loaded \(songAsset.displayName)."
            } else if !sourcePlaybackReloadAttempted.contains(selectedID) {
                sourcePlaybackReloadAttempted.insert(selectedID)
                statusMessage = "Reloading \(songAsset.displayName) from source..."
                Task { @MainActor [weak self, selectedID] in
                    guard let self else { return }
                    let didHydrate = await self.hydrateSongDetailsIfNeeded(
                        id: selectedID,
                        includePlayback: true,
                        forceRefreshFromSource: true
                    )
                    guard !didHydrate, self.selectedMidiID == selectedID else { return }
                    if let asset = self.songAssets.first(where: { $0.id == selectedID }) {
                        self.statusMessage = "No MIDI data in \(asset.displayName)."
                    }
                }
            } else if alreadyAttempted {
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

        let selectedSongPlaybackMappings = currentChannelKeys.reduce(into: [String: InstrumentMapping]()) { result, key in
            guard let mapping = instrumentMappings[key] else { return }
            result[key] = mapping
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
        if shouldMarkLoaded {
            statusMessage = "Loaded \(songAsset.displayName)."
        }
        rebuildProjectChannelRegistry()

        // Only prewarm the current song's AU mappings, and do it as a delayed idle task so
        // an immediate Play press can jump ahead instead of sitting behind unrelated project
        // instrument instantiation work on the serial audio queue.
        playbackEngine.scheduleIdleAUPrewarm(for: selectedSongPlaybackMappings)
    }

    func reloadSelectedSongFromSource(forceRebuildIndex: Bool = true) {
        guard let selectedMidiID,
              let songAsset = songAssets.first(where: { $0.id == selectedMidiID }) else {
            statusMessage = "No song selected."
            return
        }

        guard !dirtySongPaths.contains(songAsset.relativePath) else {
            statusMessage = "Save or snapshot \(songAsset.displayName) before reloading from source."
            return
        }

        sourcePlaybackReloadAttempted.insert(selectedMidiID)
        statusMessage = "Reloading \(songAsset.displayName) from source..."

        Task { @MainActor [weak self, selectedMidiID, songName = songAsset.displayName] in
            guard let self else { return }

            let didHydrate = await self.hydrateSongDetailsIfNeeded(
                id: selectedMidiID,
                includePlayback: true,
                forceRefreshFromSource: true
            )
            guard !didHydrate, self.selectedMidiID == selectedMidiID else { return }
            self.statusMessage = "Failed to reload \(songName) from source."
        }
    }

    private enum HydratedSongSource {
        case disk
    }

    private func songStubForRuntime(relativePath: String) -> SongStub? {
        if let existing = songStubs.first(where: { $0.relativePath == relativePath }) {
            return existing
        }

        guard let projectURL = fileProjectURL,
              projectURL.pathExtension.lowercased() != "ows" else {
            return nil
        }

        let songsRoot = projectURL.appendingPathComponent(OWPProjectIO.songsDir)
        return OWPProjectIO.enumerateSongStubs(in: songsRoot).first(where: { $0.relativePath == relativePath })
    }

    private func loadHydratedAsset(
        relativePath: String,
        includePlayback: Bool,
        preferSourcePlayback: Bool
    ) async throws -> (asset: OWSSongAsset, source: HydratedSongSource)? {
        guard let stub = songStubForRuntime(relativePath: relativePath) else {
            return nil
        }
        return (try await OWPProjectIO.loadSongAsync(stub: stub), .disk)
    }

    private func runtimeStableAsset(_ loadedAsset: OWSSongAsset, relativePath: String) -> OWSSongAsset {
        guard let existing = songAssets.first(where: { $0.relativePath == relativePath }) else {
            return loadedAsset
        }

        var asset = loadedAsset
        asset.document.songID = existing.document.songID
        return asset
    }

    func hydrateSongPlaybackIfNeeded(id: MidiAsset.ID) async -> Bool {
        guard await hydrateSongDetailsIfNeeded(id: id, includePlayback: true),
              let songIndex = songAssets.firstIndex(where: { $0.id == id }),
              let playback = songAssets[songIndex].document.activeVersion()?.playback else {
            return false
        }
        return !playback.notes.isEmpty
    }

    private func hydrateSongDetailsIfNeeded(
        id: MidiAsset.ID,
        includePlayback: Bool,
        forceRefreshFromSource: Bool = false
    ) async -> Bool {
        guard let songIndex = songAssets.firstIndex(where: { $0.id == id }) else {
            novotroDebugLog("hydrateSongDetailsIfNeeded: song id not found")
            return false
        }

        let relativePath = songAssets[songIndex].relativePath
        novotroDebugLog("hydrateSongDetailsIfNeeded START: \(relativePath) includePlayback=\(includePlayback)")
        let hasPlayback = songAssets[songIndex].document.activeVersion()?.playback != nil
        if hydratedSongPaths.contains(relativePath) && !forceRefreshFromSource && (!includePlayback || hasPlayback) {
            return true
        }

        var loadedHydratedAsset: OWSSongAsset?
        let preferSourcePlayback = includePlayback && !isStandaloneSongWorkspace
        do {
            if let loaded = try await loadHydratedAsset(
                relativePath: relativePath,
                includePlayback: includePlayback,
                preferSourcePlayback: preferSourcePlayback
            ) {
                loadedHydratedAsset = loaded.asset
            }
        } catch {
            NSLog("[ScoreStore] hydrateSongDetailsIfNeeded: disk load failed for %@: %@", relativePath, error.localizedDescription)
        }

        guard let rawHydratedAsset = loadedHydratedAsset else {
            novotroDebugLog("hydrateSongDetailsIfNeeded FAILED: no asset loaded for \(relativePath)")
            return false
        }
        let hydratedAsset = runtimeStableAsset(rawHydratedAsset, relativePath: relativePath)
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

    func suspendBackgroundWork() {
        stopExternalFileWatch()
    }

    func resumeBackgroundWork() {
        startExternalFileWatch()
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
        // Assign directly — skip the O(n log n) sort on every call.
        // During 60 Hz mouse drags with 10,000+ notes the per-frame sort was costly.
        // Playback methods should sort their own snapshot when ordering matters.
        pianoRollNotes = updated
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

    private func cancelDeferredSelectionLoad() {
        deferredSelectionLoadTask?.cancel()
        deferredSelectionLoadTask = nil
    }

    private func scheduleDeferredSelectionLoad() {
        deferredSelectionLoadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.deferredSelectionLoadTask = nil
            self.loadSelectedMidiIfPossible()
        }
    }

    // Tracks song IDs for which a deferred playback start has already been attempted this
    // selection. Cleared when selectedMidiID changes. Prevents infinite retry when a song
    // has been hydrated but genuinely contains no MIDI data.
    private var deferredPlaybackAttempted: Set<MidiAsset.ID> = []
    // Tracks a one-time source-truth reload attempt for the current selection so an empty
    // in-memory/cache playback cannot permanently mask valid on-disk score data.
    private var sourcePlaybackReloadAttempted: Set<MidiAsset.ID> = []

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
        // Push to the live audio mixer so the user hears the change immediately
        // (otherwise the new gain would only take effect on next instrument load).
        playbackEngine.setLiveGain(gainDB, mappingKey: channelKey)
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
            let soundFontsRoot = ProjectPaths(root: projectURL).soundFonts.standardizedFileURL.path + "/"
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
        midiAIStatusMessage = "MidiAI not available in Score."
    }

    func midiAIGenerateContinuation(maxTokens: Int = 512, temperature: Double = 0.95) {
        midiAIStatusMessage = "MidiAI not available in Score."
    }

    func midiAIGenerateAccompaniment(maxTokens: Int = 512, temperature: Double = 0.95) {
        midiAIStatusMessage = "MidiAI not available in Score."
    }

    func midiAIGenerateMelody(lyrics: String, tempoBPM: Int? = nil, key: String? = nil) {
        midiAIStatusMessage = "MidiAI not available in Score."
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
        let defaultLabel = label ?? "\(saveType == .autosave ? "Revision" : "Snapshot") \(formatter.string(from: now))"

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
        guard let asset = songAssets.first(where: { $0.relativePath == songPath }) else { return [] }
        return asset.document.versions.filter { $0.saveType != .autosave || $0.id == asset.document.activeVersionID }
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
        case offlineRenderTimedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .bufferCreationFailed: return "Failed to create audio buffer"
            case .noNotes: return "No notes in the specified range"
            case .audioUnitLoadFailed(let mappingKeys):
                let joined = mappingKeys.joined(separator: ", ")
                return "Failed to load requested Audio Unit mappings: \(joined)"
            case .realtimeRenderTimedOut:
                return "Timed out while capturing the live audio render"
            case .offlineRenderTimedOut(let seconds):
                return "Offline render exceeded \(Int(seconds))s — likely a hosted Audio Unit hang"
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
            Task { @MainActor in
                guard let self else { return }
                if self.isExportingFullMix {
                    self.fullMixExportDetailStatus = msg
                } else {
                    self.statusMessage = msg
                }
            }
        }
        let reportWarning: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.appendSunoLog(msg, level: .warning) }
        }

        let neededMappingKeys = Set(dynamicsApplied.map { note in
            let pairKey = "\(note.trackIndex):\(note.channel)"
            return channelKeyMap[pairKey] ?? "__default__"
        })
        let containsAudioUnitMappings = overrideSF2Path == nil && neededMappingKeys.contains { key in
            guard let mapping = resolvedMappings[key], !mapping.muted else { return false }
            return mapping.effectiveSourceType == .audioUnit && mapping.audioComponentDescription != nil
        }
        NSLog("[OfflineExport] containsAudioUnitMappings=%@ neededKeys=%d",
              containsAudioUnitMappings ? "YES" : "NO", neededMappingKeys.count)
        let hostedAudioUnitExportMode = HostedAudioUnitExportMode.current()

        // Tick-to-seconds conversion as a pure function (captures snapshot)
        let ticksToSec: @Sendable (Int) -> Double = { tick in
            Self.ticksToSecondsStatic(tick, ticksPerQuarter: tpq, tempoEvents: tempoEvents)
        }

        let performOfflineRender: @Sendable (URL, HostedAudioUnitOfflineRenderProfile) async throws -> Void = { outputURLToUse, renderProfile in
            // Run ALL heavy work off the main thread
            try await Task.detached(priority: .userInitiated) {
                try await Self.renderChunkToWavBackground(
                    chunkNotes: dynamicsApplied,
                    startTick: startTick,
                    endTick: endTick,
                    outputURL: outputURLToUse,
                    overrideSF2Path: overrideSF2Path,
                    gainOverrides: gainOverrides,
                    channelKeyMap: channelKeyMap,
                    resolvedMappings: resolvedMappings,
                    masterVolume: volume,
                    panMap: panMap,
                    hostedAudioUnitRenderProfile: renderProfile,
                    ticksToSec: ticksToSec,
                    reportStatus: reportStatus,
                    reportWarning: reportWarning
                )
            }.value
        }

        let performRealtimeHostedRender: @Sendable (URL) async throws -> Void = { outputURLToUse in
            // Run off the main actor — leaveExportMode() calls audioQueue.sync which
            // would block the main thread if this ran on MainActor.
            try await Task.detached(priority: .userInitiated) {
                try await Self.renderChunkToWavViaPlaybackEngine(
                    notes: dynamicsApplied,
                    startTick: startTick,
                    endTick: endTick,
                    outputURL: outputURLToUse,
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
            }.value
        }

        if containsAudioUnitMappings {
            let qualificationProjectIdentifier = fileProjectURL?.resolvingSymlinksInPath().path
            let qualificationKey = Self.hostedAudioUnitQualificationKey(
                projectIdentifier: qualificationProjectIdentifier,
                songPath: selectedMidiAsset?.relativePath,
                startTick: startTick,
                endTick: endTick,
                mappingKeys: neededMappingKeys,
                resolvedMappings: resolvedMappings,
                panMap: panMap,
                ticksPerQuarter: tpq,
                tempoEvents: tempoEvents
            )
            let cacheQualification: (HostedAudioUnitOfflineQualification) -> Void = { [self] qualification in
                self.hostedAudioUnitOfflineQualificationCache[qualificationKey] = qualification
                self.persistHostedAudioUnitOfflineQualificationCache()
            }

            let attemptOfflineFullRender: @Sendable (HostedAudioUnitOfflineRenderProfile, Double?) async throws -> Void = { renderProfile, leadingAlignmentSeconds in
                NSLog(
                    "[OfflineExport] Attempting %@ offline hosted-instrument export for %@",
                    renderProfile.rawValue,
                    outputURL.lastPathComponent
                )
                reportStatus(
                    renderProfile == .conservative
                        ? "Rendering hosted instruments offline (conservative)..."
                        : "Rendering hosted instruments offline..."
                )
                try await performOfflineRender(outputURL, renderProfile)
                if let leadingAlignmentSeconds,
                   abs(leadingAlignmentSeconds) > 0 {
                    try Self.shiftAudioFileLeadingFrames(
                        at: outputURL,
                        frameOffset: AVAudioFramePosition(leadingAlignmentSeconds * 48_000)
                    )
                }
                let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                if Self.isLikelyIncompleteWavExport(at: outputURL, fileSize: fileSize) {
                    throw ChunkExportError.bufferCreationFailed
                }
                NSLog(
                    "[OfflineExport] %@ offline hosted-instrument export succeeded for %@",
                    renderProfile.rawValue,
                    outputURL.lastPathComponent
                )
            }

            let qualifyOfflineRender: @Sendable () async -> HostedAudioUnitOfflineQualification = {
                guard let excerpt = Self.hostedAudioUnitQualificationExcerpt(
                    from: dynamicsApplied,
                    startTick: startTick,
                    endTick: endTick,
                    ticksToSec: ticksToSec
                ) else {
                    return HostedAudioUnitOfflineQualification(
                        verdict: .rejected,
                        similarity: 0,
                        envelopeSimilarity: 0,
                        durationDeltaSeconds: .infinity,
                        renderProfile: .standard,
                        leadingAlignmentSeconds: nil,
                        checkedAt: Date(),
                        detail: "No representative note excerpt was available for qualification."
                    )
                }

                let tempRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("amira-au-export-qualification-\(UUID().uuidString)", isDirectory: true)
                let realtimeURL = tempRoot.appendingPathComponent("realtime.wav")

                do {
                    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                } catch {
                    return HostedAudioUnitOfflineQualification(
                        verdict: .rejected,
                        similarity: 0,
                        envelopeSimilarity: 0,
                        durationDeltaSeconds: .infinity,
                        renderProfile: .standard,
                        leadingAlignmentSeconds: nil,
                        checkedAt: Date(),
                        detail: "Could not create qualification directory: \(error.localizedDescription)"
                    )
                }

                var preservedArtifactDirectory: URL?
                defer {
                    if preservedArtifactDirectory == nil {
                        try? FileManager.default.removeItem(at: tempRoot)
                    }
                }

                do {
                    try await Task.detached(priority: .userInitiated) {
                        try await Self.renderChunkToWavViaPlaybackEngine(
                            notes: dynamicsApplied,
                            startTick: excerpt.startTick,
                            endTick: excerpt.endTick,
                            outputURL: realtimeURL,
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
                    }.value
                } catch {
                    Self.removeIncompleteExportFile(at: realtimeURL)
                    return HostedAudioUnitOfflineQualification(
                        verdict: .rejected,
                        similarity: 0,
                        envelopeSimilarity: 0,
                        durationDeltaSeconds: .infinity,
                        renderProfile: .standard,
                        leadingAlignmentSeconds: nil,
                        checkedAt: Date(),
                        detail: "Realtime qualification render failed: \(error.localizedDescription)"
                    )
                }

                let realtimeDuration = Self.audioDurationSeconds(at: realtimeURL) ?? 0
                var bestQualification = HostedAudioUnitOfflineQualification(
                    verdict: .rejected,
                    similarity: 0,
                    envelopeSimilarity: 0,
                    durationDeltaSeconds: .infinity,
                    renderProfile: .standard,
                    leadingAlignmentSeconds: nil,
                    checkedAt: Date(),
                    detail: "No hosted-AU offline render profile completed."
                )

                NSLog("[Phase0Bounds] querying REALTIME bounds file=%@", realtimeURL.lastPathComponent)
                let realtimeBounds = await Self.waitForQualificationAudioAudibleBounds(at: realtimeURL)
                NSLog("[Phase0Bounds] REALTIME bounds result=%@",
                      realtimeBounds.map { "first=\($0.first) last=\($0.last)" } ?? "nil")
                for renderProfile in HostedAudioUnitOfflineRenderProfile.allCases {
                    let offlineURL = tempRoot.appendingPathComponent("\(renderProfile.rawValue).wav")
                    do {
                        reportStatus(
                            renderProfile == .conservative
                                ? "Qualifying fast hosted-instrument export (conservative)..."
                                : "Qualifying fast hosted-instrument export..."
                        )
                        try await Task.detached(priority: .userInitiated) {
                            try await Self.renderChunkToWavBackground(
                                chunkNotes: dynamicsApplied,
                                startTick: excerpt.startTick,
                                endTick: excerpt.endTick,
                                outputURL: offlineURL,
                                overrideSF2Path: overrideSF2Path,
                                gainOverrides: gainOverrides,
                                channelKeyMap: channelKeyMap,
                                resolvedMappings: resolvedMappings,
                                masterVolume: volume,
                                panMap: panMap,
                                hostedAudioUnitRenderProfile: renderProfile,
                                ticksToSec: ticksToSec,
                                reportStatus: reportStatus,
                                reportWarning: reportWarning
                            )
                        }.value
                    } catch {
                        Self.removeIncompleteExportFile(at: offlineURL)
                        let failure = HostedAudioUnitOfflineQualification(
                            verdict: .rejected,
                            similarity: 0,
                            envelopeSimilarity: 0,
                            durationDeltaSeconds: .infinity,
                            renderProfile: renderProfile,
                            leadingAlignmentSeconds: nil,
                            checkedAt: Date(),
                            detail: "\(renderProfile.rawValue) offline qualification render failed: \(error.localizedDescription)"
                        )
                        if bestQualification.checkedAt <= failure.checkedAt {
                            bestQualification = failure
                        }
                        continue
                    }

                    var appliedLeadingAlignmentSeconds = 0.0
                    NSLog("[Phase0Bounds] querying OFFLINE-%@ bounds file=%@", renderProfile.rawValue, offlineURL.lastPathComponent)
                    let preAlignmentOfflineBounds = await Self.waitForQualificationAudioAudibleBounds(at: offlineURL)
                    NSLog("[Phase0Bounds] OFFLINE-%@ bounds result=%@",
                          renderProfile.rawValue,
                          preAlignmentOfflineBounds.map { "first=\($0.first) last=\($0.last)" } ?? "nil")
                    let onsetDeltaBeforeAlignment: Double?
                    let tailDeltaBeforeAlignment: Double?
                    if let realtimeBounds,
                       let offlineBounds = preAlignmentOfflineBounds {
                        onsetDeltaBeforeAlignment = Double(offlineBounds.first - realtimeBounds.first) / 48_000
                        tailDeltaBeforeAlignment = Double(offlineBounds.last - realtimeBounds.last) / 48_000
                    } else {
                        onsetDeltaBeforeAlignment = nil
                        tailDeltaBeforeAlignment = nil
                    }
                    if let realtimeBounds,
                       let offlineBounds = preAlignmentOfflineBounds {
                        let leadingOffsetFrames = offlineBounds.first - realtimeBounds.first
                        let minimumAlignmentFrames = AVAudioFramePosition(48_000 * 0.02)
                        let maximumAlignmentFrames = AVAudioFramePosition(48_000 * 0.5)
                        if abs(leadingOffsetFrames) >= minimumAlignmentFrames &&
                            abs(leadingOffsetFrames) <= maximumAlignmentFrames {
                            do {
                                try Self.shiftAudioFileLeadingFrames(at: offlineURL, frameOffset: leadingOffsetFrames)
                                appliedLeadingAlignmentSeconds = Double(leadingOffsetFrames) / 48_000
                            } catch {
                                NSLog("[OfflineExport] Failed to align %@ qualification render by %.3fs: %@", renderProfile.rawValue, Double(leadingOffsetFrames) / 48_000, error.localizedDescription)
                            }
                        }
                    }

                    // Phase 2a: Trim the offline excerpt tail to match the realtime audible end.
                    // BBC SO's reverb tail extends past the fixed realtime-engine stop timer,
                    // causing the offline file to be ~0.3s longer than the realtime file.
                    // We cap the offline file at realtimeBounds.last+1 frames before comparison
                    // so the duration gate reflects a fair like-for-like comparison.
                    // This only touches the qualification excerpt copy — full-song export is unaffected.
                    if let realtimeBounds {
                        let targetFrameCount = AVAudioFramePosition(realtimeBounds.last + 1)
                        do {
                            try Self.trimAudioFileToFrameCount(at: offlineURL, frameCount: targetFrameCount)
                        } catch {
                            NSLog("[OfflineExport] Phase2a tail trim failed for %@: %@",
                                  offlineURL.lastPathComponent, error.localizedDescription)
                        }
                    }

                    let offlineDuration = Self.audioDurationSeconds(at: offlineURL) ?? 0
                    let offlineActiveDuration = Self.audioActiveDurationSeconds(at: offlineURL) ?? offlineDuration
                    let realtimeActiveDuration = Self.audioActiveDurationSeconds(at: realtimeURL) ?? realtimeDuration
                    let durationDelta = abs(offlineActiveDuration - realtimeActiveDuration)
                    let similarity = (try? MFCCSimilarity.compareFiles(
                        fileA: offlineURL.path,
                        fileB: realtimeURL.path
                    )) ?? 0
                    let envelopeSimilarity = Self.audioEnvelopeSimilarity(
                        fileA: offlineURL,
                        fileB: realtimeURL
                    ) ?? 0
                    let qualified = durationDelta <= 0.08 && (
                        (similarity >= 0.985 && envelopeSimilarity >= 0.995) ||
                        (similarity >= 0.978 && envelopeSimilarity >= 0.999 && durationDelta <= 0.03)
                    )
                    let detail = String(
                        format: "%@ similarity=%.4f envelope=%.4f activeDelta=%.3fs fileDelta=%.3fs onsetDelta=%.3fs tailDelta=%.3fs align=%.3fs excerpt=%d→%d",
                        renderProfile.rawValue,
                        similarity,
                        envelopeSimilarity,
                        durationDelta,
                        abs(offlineDuration - realtimeDuration),
                        onsetDeltaBeforeAlignment ?? .nan,
                        tailDeltaBeforeAlignment ?? .nan,
                        appliedLeadingAlignmentSeconds,
                        excerpt.startTick,
                        excerpt.endTick
                    )
                    NSLog("[OfflineExport] Qualification %@", detail)

                    let candidate = HostedAudioUnitOfflineQualification(
                        verdict: qualified ? .qualified : .rejected,
                        similarity: similarity,
                        envelopeSimilarity: envelopeSimilarity,
                        durationDeltaSeconds: durationDelta,
                        renderProfile: renderProfile,
                        leadingAlignmentSeconds: abs(appliedLeadingAlignmentSeconds) > 0 ? appliedLeadingAlignmentSeconds : nil,
                        checkedAt: Date(),
                        detail: detail
                    )

                    if qualified {
                        return candidate
                    }

                    if candidate.similarity <= 0.5 || candidate.envelopeSimilarity <= 0.5 {
                        preservedArtifactDirectory = Self.preserveHostedAudioUnitQualificationArtifacts(
                            tempRoot: tempRoot,
                            qualificationKey: qualificationKey,
                            excerptStartTick: excerpt.startTick,
                            excerptEndTick: excerpt.endTick,
                            qualification: candidate
                        )
                    }

                    if candidate.similarity > bestQualification.similarity ||
                        (candidate.similarity == bestQualification.similarity &&
                         candidate.envelopeSimilarity > bestQualification.envelopeSimilarity) ||
                        (candidate.similarity == bestQualification.similarity &&
                         candidate.envelopeSimilarity == bestQualification.envelopeSimilarity &&
                         candidate.durationDeltaSeconds < bestQualification.durationDeltaSeconds) {
                        bestQualification = candidate
                    }
                }

                return bestQualification
            }

            switch hostedAudioUnitExportMode {
            case .offline:
                try await attemptOfflineFullRender(.standard, nil)
                return
            case .realtime:
                try await performRealtimeHostedRender(outputURL)
                return
            case .auto:
                let qualification: HostedAudioUnitOfflineQualification
                if let cached = hostedAudioUnitOfflineQualificationCache[qualificationKey] {
                    qualification = cached
                    NSLog("[OfflineExport] Reusing cached qualification for %@: %@", outputURL.lastPathComponent, cached.detail)
                } else {
                    let fresh = await qualifyOfflineRender()
                    cacheQualification(fresh)
                    qualification = fresh
                }

                if qualification.verdict == .qualified {
                    do {
                        try await attemptOfflineFullRender(qualification.renderProfile, qualification.leadingAlignmentSeconds)
                        return
                    } catch {
                        cacheQualification(HostedAudioUnitOfflineQualification(
                            verdict: .rejected,
                            similarity: qualification.similarity,
                            envelopeSimilarity: qualification.envelopeSimilarity,
                            durationDeltaSeconds: qualification.durationDeltaSeconds,
                            renderProfile: qualification.renderProfile,
                            leadingAlignmentSeconds: qualification.leadingAlignmentSeconds,
                            checkedAt: Date(),
                            detail: "\(qualification.detail); full render fallback after failure: \(error.localizedDescription)"
                        ))
                        Self.removeIncompleteExportFile(at: outputURL)
                        NSLog("[OfflineExport] Qualified offline export failed for %@: %@", outputURL.lastPathComponent, error.localizedDescription)
                        reportWarning("Fast hosted-instrument render failed (\(error.localizedDescription)); falling back to live capture.")
                        reportStatus("Falling back to live hosted-instrument capture...")
                    }
                } else {
                    reportWarning("Fast hosted-instrument export remains disabled for this mapping set (\(qualification.detail)).")
                    reportStatus("Capturing live hosted-instrument render...")
                }

                try await performRealtimeHostedRender(outputURL)
                return
            }
        }

        try await performOfflineRender(outputURL, .standard)
    }

    /// Pure static helper — all ScoreStore data is passed by value; no self access.
    /// Runs entirely off the main actor via Task.detached at call sites.
    private nonisolated static func renderChunkToWavViaPlaybackEngine(
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

        // Raise I/O buffer to 4096 frames for export — gives the render thread ~85ms
        // headroom instead of ~5ms, eliminating buffer-underrun glitches under heavy
        // BBC SO load. leaveExportMode() (sync) restores the prior value on exit.
        exportEngine.enterExportMode()
        defer { exportEngine.leaveExportMode() }

        let finishedLock = OSAllocatedUnfairLock(initialState: false)
        let playbackErrorLock = OSAllocatedUnfairLock(initialState: Optional<String>.none)

        do {
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
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    if Self.isLikelyIncompleteWavExport(at: url, fileSize: fileSize) {
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
        } catch {
            Self.removeIncompleteExportFile(at: outputURL)
            throw error
        }
    }

    nonisolated private static func isLikelyIncompleteWavExport(at url: URL, fileSize: Int64?) -> Bool {
        guard url.pathExtension.lowercased() == "wav", let fileSize else { return false }
        return fileSize > 0 && fileSize <= 4096
    }

    nonisolated private static func removeIncompleteExportFile(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            NSLog("[FullMix] Failed to remove incomplete export at %@: %@", url.path, error.localizedDescription)
        }
    }

    /// Pure static helper — runs entirely off the main thread.
    /// All ScoreStore data is passed in as parameters (no self access).
    @Sendable
    private nonisolated static func hostedAudioUnitOfflineRenderTuning(
        for profile: HostedAudioUnitOfflineRenderProfile
    ) -> AVAudioFrameCount {
        switch profile {
        case .standard:
            // 256 frames (5.3ms @ 48kHz). BBC SO polarity-flip artifacts are eliminated
            // by snapping note-on framePositions to block boundaries (see event-building
            // code in Phase 4), not by increasing block size. Larger blocks (1024, 4096)
            // produce silent output — BBC SO returns insufficientDataFromInputNode for
            // every block, advancing currentFrame without writing audio.
            return 256
        case .conservative:
            return 128
        }
    }

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
        hostedAudioUnitRenderProfile: HostedAudioUnitOfflineRenderProfile = .standard,
        ticksToSec: @Sendable (Int) -> Double,
        reportStatus: @Sendable (String) -> Void,
        reportWarning: @Sendable (String) -> Void
    ) async throws {
        let sampleRate: Double = 48_000
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else { throw ChunkExportError.bufferCreationFailed }

        // Throttle speed control: set AMIRA_EXPORT_THROTTLE_SPEED=5.0 to run at ~5x realtime.
        // Unset = no throttle (default fast path).
        let throttleSpeed: Double? = ProcessInfo.processInfo.environment["AMIRA_EXPORT_THROTTLE_SPEED"]
            .flatMap(Double.init)
        if let ts = throttleSpeed {
            NSLog("[ExportThrottle] target=%.2fx realtime", ts)
        }

        // Compute total duration
        let startSeconds = ticksToSec(startTick)
        let endSeconds = ticksToSec(endTick)
        // Resolve mapping keys
        var neededMappingKeys = Set<String>()
        for note in chunkNotes {
            let pairKey = "\(note.trackIndex):\(note.channel)"
            let mappingKey = channelKeyMap[pairKey] ?? "__default__"
            neededMappingKeys.insert(mappingKey)
        }
        let containsHostedAudioUnits = overrideSF2Path == nil && neededMappingKeys.contains { key in
            guard let mapping = resolvedMappings[key], !mapping.muted else { return false }
            return mapping.effectiveSourceType == .audioUnit && mapping.audioComponentDescription != nil
        }
        let totalSeconds = endSeconds - startSeconds
        let contentFrames = AVAudioFramePosition(max(totalSeconds, 0) * sampleRate)
        let fixedTailFrames = AVAudioFramePosition(sampleRate)
        let hostedMinimumTailFrames = AVAudioFramePosition(sampleRate * 0.20)
        let hostedMaximumTailFrames = AVAudioFramePosition(sampleRate * 2.0)
        let requiredSilentFramesToStop = AVAudioFramePosition(sampleRate * 0.15)
        let totalFramesPosition = max(
            1,
            contentFrames + (containsHostedAudioUnits ? hostedMaximumTailFrames : fixedTailFrames)
        )
        let totalFrames = AVAudioFrameCount(totalFramesPosition)
        guard totalFrames > 0 else { return }
        // Hosted Audio Units render more faithfully with smaller manual-rendering
        // blocks. A sample-caching warmup (Fix B) fires before the real render to
        // pre-load disk-streamed samples into memory.
        let renderBlockSize: AVAudioFrameCount = containsHostedAudioUnits
            ? Self.hostedAudioUnitOfflineRenderTuning(for: hostedAudioUnitRenderProfile)
            : 2048

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

            let rawStartFrame = AVAudioFramePosition(max(0, noteStartSec) * sampleRate)
            let endFrame = AVAudioFramePosition(max(0, noteEndSec) * sampleRate)

            // Fix D: For hosted AUs, snap note-on positions DOWN to the nearest block
            // boundary so that every scheduleMIDI call receives sampleOffset=0. BBC SO
            // introduces a new voice when it processes the note-on; if that happens
            // mid-block, the voice enters at an arbitrary waveform phase relative to
            // already-sounding voices, which produces a sample-level discontinuity.
            // Forcing sampleOffset=0 ensures the voice always starts at a clean block
            // edge where BBC SO's internal mix state is well-defined.
            // The timing shift is at most (renderBlockSize-1)/sampleRate ≈ 5ms — inaudible.
            let blockSzPos = AVAudioFramePosition(renderBlockSize)
            let startFrame: AVAudioFramePosition
            if containsHostedAudioUnits && auNodes[mappingKey] != nil {
                startFrame = (rawStartFrame / blockSzPos) * blockSzPos
            } else {
                startFrame = rawStartFrame
            }

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

        // Phase 4a: Enforce minimum retrigger gap for hosted AUs (Fix C — RR polarity fix).
        // BBC SO's round-robin sampler selects a new sample variant on each note-on.
        // Consecutive RR variants may have inverted polarity. When a note-on fires for
        // a (mappingKey, pitch) that is currently sounding (legato retrigger), BBC SO
        // switches to the next RR buffer 16 samples into the render block (its internal
        // processing latency). The old buffer and the new buffer may have opposite polarity,
        // producing a sharp discontinuity (Δ up to 0.34 measured in Phase 1 analysis).
        //
        // The fix: detect legato retriggers (two consecutive note-ons for the same
        // mappingKey+pitch with no intervening note-off) in hosted AU tracks, and insert
        // an explicit early note-off so the old voice has MIN_GAP frames of silence before
        // the new note-on. MIN_GAP is 2× renderBlockSize: one block to ensure the note-off
        // is processed before the note-on block, plus one block for BBC SO's 16-sample
        // internal decay. Total timing advance ≤ 10ms at 256 frames — inaudible.
        // AB_EXPERIMENT_RUN_B: Fix C re-enabled with ceil (round-UP) block alignment on note-off frame.
        // Round-up ensures sampleOffset=0 for the note-off (placed at start of a block) rather than
        // round-down which may still land 1 sample before a block boundary in some edge cases.
        if containsHostedAudioUnits {
            let minGapFrames = AVAudioFramePosition(renderBlockSize) * 2
            let blockSz = AVAudioFramePosition(renderBlockSize)

            // Pass 1: identify legato retriggers and collect early note-offs to insert.
            // Track the frame of the most recent active note-on per (mappingKey, pitch).
            var activeNoteOnFrame: [String: AVAudioFramePosition] = [:]
            var extraNoteOffs: [MidiEvent] = []

            for ev in events {
                guard auNodes[ev.mappingKey] != nil else { continue }
                let key = "\(ev.mappingKey):\(ev.pitch)"
                if ev.isNoteOn {
                    if let prevOnFrame = activeNoteOnFrame[key] {
                        // A note is still nominally sounding (no note-off seen yet).
                        // Insert a note-off snapped to a block boundary so BBC SO cuts
                        // the voice at a clean block edge. Position it minGapFrames before
                        // the new note-on, then round UP to the next block boundary
                        // (ceiling alignment) so sampleOffset is always exactly 0 —
                        // eliminates any possibility of a mid-block voice cut transient.
                        let rawOff = max(prevOnFrame + blockSz, ev.framePosition - minGapFrames)
                        let earlyOffFrame = ((rawOff + blockSz - 1) / blockSz) * blockSz
                        guard earlyOffFrame > prevOnFrame else { activeNoteOnFrame[key] = ev.framePosition; continue }
                        extraNoteOffs.append(MidiEvent(
                            framePosition: earlyOffFrame,
                            pitch: ev.pitch,
                            velocity: 0,
                            isNoteOn: false,
                            mappingKey: ev.mappingKey
                        ))
                        NSLog("[FixC] Inserted early note-off for %@ pitch=%d at frame %lld (gap before retrigger at %lld)",
                              ev.mappingKey, ev.pitch, earlyOffFrame, ev.framePosition)
                    }
                    activeNoteOnFrame[key] = ev.framePosition
                } else {
                    activeNoteOnFrame.removeValue(forKey: key)
                }
            }

            if !extraNoteOffs.isEmpty {
                events.append(contentsOf: extraNoteOffs)
                events.sort()
                NSLog("[FixC] Inserted %d early note-offs for legato BBC SO retriggers", extraNoteOffs.count)
            }
        }

        // Phase 4b: RR-exhaustion warmup for hosted Audio Units (RRExhaust Warmup)
        // BBC SO uses round-robin (RR) sample variants — 2-4 distinct recorded takes per
        // note per velocity layer. If the RR counter is at an inverted-polarity variant
        // when the real render starts, the first occurrence of that note plays with wrong
        // polarity, causing a sharp discontinuity (polarity-flip click).
        //
        // Fix: fire each (mappingKey, pitch) tuple 8 times rapidly at vel 100 so BBC SO's
        // RR counter cycles through all variants and wraps back to a predictable position
        // (typically position 0) before the real render begins.
        if containsHostedAudioUnits {
            // Collect unique (mappingKey, pitch) pairs from the event list
            struct WarmupNote: Hashable {
                let mappingKey: String
                let pitch: UInt8
            }
            var seen = Set<WarmupNote>()
            var warmupNotes: [WarmupNote] = []
            for event in events where event.isNoteOn {
                let key = WarmupNote(mappingKey: event.mappingKey, pitch: event.pitch)
                if seen.insert(key).inserted {
                    warmupNotes.append(key)
                }
            }

            // Cap at 500 unique notes; sample uniformly if over limit
            let warmupCap = 500
            let skipped = max(0, warmupNotes.count - warmupCap)
            if skipped > 0 {
                let stride = Double(warmupNotes.count) / Double(warmupCap)
                warmupNotes = (0..<warmupCap).map { i in
                    warmupNotes[min(Int(Double(i) * stride), warmupNotes.count - 1)]
                }
                NSLog("[RRExhaust Warmup] Note count %d exceeds cap %d — skipped %d notes (sampled uniformly)",
                      seen.count, warmupCap, skipped)
            }

            // RR-exhaustion warmup parameters (Round 3 — dual-velocity):
            //   - 6 iterations at vel 80 then 6 iterations at vel 100 = 12 total per tuple
            //     Alternating velocities covers both pp/mp and mf/f BBC SO velocity layers,
            //     each of which has its own independent RR counter. 6 iters per velocity
            //     guarantees wrap-around for all known articulations (max 4 RR variants).
            //   - Note duration: 100 ms (note-on then note-off 100 ms later)
            //   - Inter-iteration gap: 50 ms silence before next note-on
            //   - Per-tuple cycle: 12 × 150 ms = 1.8 s (6 vel-80 + 6 vel-100 back-to-back)
            //   - Stagger: 15 ms between tuple start times — ~10 tuples firing simultaneously
            //   - Firing phase: N × 15 ms stagger + 1.8 s last tuple tail
            //   - Then: CC 123 All Notes Off + CC 120 All Sound Off + 1 s decay silence
            //   - Then: 35 s settle window for BBC SO streaming engine to flush and stabilise
            //   - Hard cap 120 s
            let rrIterationsPerVel = 6
            let warmupVelocities: [UInt8] = [80, 100]  // two BBC SO velocity layers
            let staggerSec = 0.015          // 15 ms between tuple start times
            let noteDurSec  = 0.100         // 100 ms note duration
            let iterGapSec  = 0.050         // 50 ms gap between iterations
            let iterCycleSec = noteDurSec + iterGapSec  // 150 ms per iteration
            let settleSeconds = 35.0         // BBC SO streaming flush + RR counter stabilise (Round 3)
            let totalIters = rrIterationsPerVel * warmupVelocities.count  // 12 total

            // Per-tuple firing span: totalIters × iterCycleSec
            let tupleDurSec = Double(totalIters) * iterCycleSec
            // Total firing window: all tuples staggered + last tuple's full span
            let firingWindowSec = Double(warmupNotes.count) * staggerSec + tupleDurSec
            let rawDuration = firingWindowSec + 1.0 + settleSeconds  // +1 s decay
            let warmupDuration = min(rawDuration, 120.0)
            let warmupFramesTarget = AVAudioFramePosition(sampleRate * warmupDuration)

            NSLog("[RRExhaust Warmup] Scheduling %d tuples × %d iters (%d vels × %d) @ vels %@; stagger=15ms; settle=%.0fs; total=%.1fs",
                  warmupNotes.count, totalIters, warmupVelocities.count, rrIterationsPerVel,
                  warmupVelocities.map { String($0) }.joined(separator: "+") as NSString,
                  settleSeconds, warmupDuration)
            reportStatus("Priming BBC SO RR counter (\(warmupNotes.count) tuples × \(totalIters) iters, \(Int(warmupDuration))s)...")

            // Build per-frame warmup MIDI event schedule.
            // Each tuple fires rrIterationsPerVel note-on/off pairs at vel 80, then rrIterationsPerVel at vel 100.
            // All offsets are in frames relative to warmup-render start (frame 0).
            struct WarmupMidiEvent {
                let frameOffset: AVAudioFramePosition
                let mappingKey: String
                let midiBytes: [UInt8]
            }
            var warmupEvents: [WarmupMidiEvent] = []
            for (idx, wn) in warmupNotes.enumerated() {
                let tupleStartSec = Double(idx) * staggerSec
                var globalIter = 0
                for vel in warmupVelocities {
                    for _ in 0..<rrIterationsPerVel {
                        let iterStartSec = tupleStartSec + Double(globalIter) * iterCycleSec
                        let noteOnFrame  = AVAudioFramePosition(iterStartSec * sampleRate)
                        let noteOffFrame = AVAudioFramePosition((iterStartSec + noteDurSec) * sampleRate)
                        warmupEvents.append(WarmupMidiEvent(frameOffset: noteOnFrame,  mappingKey: wn.mappingKey, midiBytes: [0x90, wn.pitch, vel]))
                        warmupEvents.append(WarmupMidiEvent(frameOffset: noteOffFrame, mappingKey: wn.mappingKey, midiBytes: [0x80, wn.pitch, 0]))
                        globalIter += 1
                    }
                }
            }
            warmupEvents.sort { $0.frameOffset < $1.frameOffset }

            guard let warmupBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: renderBlockSize) else {
                throw ChunkExportError.bufferCreationFailed
            }

            var warmupFrame: AVAudioFramePosition = 0
            var warmupEventIndex = 0
            var warmupRetry = 0

            while warmupFrame < warmupFramesTarget {
                let framesToRender = min(
                    renderBlockSize,
                    AVAudioFrameCount(warmupFramesTarget - warmupFrame)
                )
                let blockEnd = warmupFrame + AVAudioFramePosition(framesToRender)

                // Schedule warmup MIDI events that fall in this block
                while warmupEventIndex < warmupEvents.count &&
                        warmupEvents[warmupEventIndex].frameOffset < blockEnd {
                    let wev = warmupEvents[warmupEventIndex]
                    let sampleOffset = AUEventSampleTime(wev.frameOffset - warmupFrame)
                    if let auUnit = auNodes[wev.mappingKey],
                       let scheduleMIDI = auUnit.auAudioUnit.scheduleMIDIEventBlock {
                        wev.midiBytes.withUnsafeBufferPointer { buf in
                            if let ptr = buf.baseAddress {
                                scheduleMIDI(sampleOffset, 0, 3, ptr)
                            }
                        }
                    } else if let sampler = samplers[wev.mappingKey] {
                        // SF2 sampler path — apply warmup too
                        if wev.midiBytes[0] == 0x90 {
                            sampler.startNote(wev.midiBytes[1], withVelocity: wev.midiBytes[2], onChannel: 0)
                        } else {
                            sampler.stopNote(wev.midiBytes[1], onChannel: 0)
                        }
                    }
                    warmupEventIndex += 1
                }

                let wStatus = try offlineEngine.renderOffline(framesToRender, to: warmupBuffer)
                switch wStatus {
                case .success, .insufficientDataFromInputNode:
                    warmupFrame += AVAudioFramePosition(warmupBuffer.frameLength > 0 ? warmupBuffer.frameLength : framesToRender)
                    warmupRetry = 0
                case .cannotDoInCurrentContext:
                    warmupRetry += 1
                    guard warmupRetry < 1000 else { throw ChunkExportError.bufferCreationFailed }
                    try await Task.sleep(nanoseconds: 1_000_000)
                case .error:
                    throw ChunkExportError.bufferCreationFailed
                @unknown default:
                    warmupFrame += AVAudioFramePosition(framesToRender)
                    warmupRetry = 0
                }
            }

            // Send CC 123 (All Notes Off) + CC 120 (All Sound Off) to every AU,
            // then render 1000 ms decay silence, then the remaining 25s settle window
            // (already included in warmupFramesTarget via rawDuration) flushes BBC SO streaming.
            let allNotesOff: [UInt8] = [0xB0, 123, 0]
            let allSoundOff: [UInt8] = [0xB0, 120, 0]
            for (_, auUnit) in auNodes {
                if let scheduleMIDI = auUnit.auAudioUnit.scheduleMIDIEventBlock {
                    allNotesOff.withUnsafeBufferPointer { buf in
                        if let ptr = buf.baseAddress {
                            scheduleMIDI(AUEventSampleTime(0), 0, 3, ptr)
                        }
                    }
                    allSoundOff.withUnsafeBufferPointer { buf in
                        if let ptr = buf.baseAddress {
                            scheduleMIDI(AUEventSampleTime(0), 0, 3, ptr)
                        }
                    }
                }
            }
            for (_, sampler) in samplers {
                sampler.stopNote(0xFF, onChannel: 0) // AVAudioUnitSampler does not support CC 123 directly; stopNote is sufficient
            }

            let settleFramesTarget = AVAudioFramePosition(sampleRate * 1.0) // 1000 ms — enough for all RR voices to decay
            var settleFrame: AVAudioFramePosition = 0
            while settleFrame < settleFramesTarget {
                let framesToRender = min(
                    renderBlockSize,
                    AVAudioFrameCount(settleFramesTarget - settleFrame)
                )
                let sStatus = try offlineEngine.renderOffline(framesToRender, to: warmupBuffer)
                switch sStatus {
                case .success, .insufficientDataFromInputNode:
                    settleFrame += AVAudioFramePosition(warmupBuffer.frameLength > 0 ? warmupBuffer.frameLength : framesToRender)
                case .cannotDoInCurrentContext:
                    try await Task.sleep(nanoseconds: 1_000_000)
                case .error:
                    throw ChunkExportError.bufferCreationFailed
                @unknown default:
                    settleFrame += AVAudioFramePosition(framesToRender)
                }
            }

            NSLog("[RRExhaust Warmup] Complete — %d tuples × %d iters primed, %.2f s warmup. Starting real render.",
                  warmupNotes.count, totalIters, warmupDuration)
        }

        // Phase 5: Render offline — stream directly to file
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: renderBlockSize) else {
            throw ChunkExportError.bufferCreationFailed
        }

        reportStatus("Rendering mix offline...")
        let offlineRenderWallStart = Date()
        // Declared as optional so it can be explicitly released before the Fix F
        // deglitch pass opens the same file for reading.
        var outputFile: AVAudioFile? = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var currentFrame: AVAudioFramePosition = 0
        var eventIndex = 0
        var trailingSilentFrames: AVAudioFramePosition = 0

        // Phase 1 diagnostic: count status codes across all render blocks
        var statusCounts = ["success": 0, "insufficientData": 0, "cannotDo": 0, "error": 0, "unknown": 0]

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
                statusCounts["success"]! += 1
                try outputFile!.write(from: outputBuffer)
                currentFrame += AVAudioFramePosition(outputBuffer.frameLength)
                retryCount = 0

                // Throttle: sleep to approximate targetSpeed x realtime.
                if let ts = throttleSpeed, ts > 0 {
                    let targetWallTimePerBlock = Double(framesToRender) / sampleRate / ts
                    try await Task.sleep(nanoseconds: UInt64(targetWallTimePerBlock * 1_000_000_000))
                }

                if containsHostedAudioUnits && currentFrame >= contentFrames {
                    let bufferRMS = Self.rmsLevel(of: outputBuffer)
                    if bufferRMS <= 1.0e-4 {
                        trailingSilentFrames += AVAudioFramePosition(outputBuffer.frameLength)
                    } else {
                        trailingSilentFrames = 0
                    }

                    if currentFrame >= contentFrames + hostedMinimumTailFrames &&
                        trailingSilentFrames >= requiredSilentFramesToStop &&
                        eventIndex >= events.count {
                        break
                    }
                }
            case .insufficientDataFromInputNode:
                statusCounts["insufficientData"]! += 1
                currentFrame += AVAudioFramePosition(framesToRender)
                retryCount = 0
            case .cannotDoInCurrentContext:
                statusCounts["cannotDo"]! += 1
                retryCount += 1
                guard retryCount < 1000 else {
                    throw ChunkExportError.bufferCreationFailed
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            case .error:
                statusCounts["error"]! += 1
                throw ChunkExportError.bufferCreationFailed
            @unknown default:
                statusCounts["unknown"]! += 1
                currentFrame += AVAudioFramePosition(framesToRender)
                retryCount = 0
            }
        }

        // Release the output file cleanly before returning.
        outputFile = nil

        // Phase 1 diagnostic: report how many times each renderOffline status fired
        let totalBlocks = statusCounts.values.reduce(0, +)
        NSLog("[OfflineRender] status counts: success=%d insufficientData=%d cannotDo=%d error=%d unknown=%d totalBlocks=%d",
              statusCounts["success"]!, statusCounts["insufficientData"]!, statusCounts["cannotDo"]!,
              statusCounts["error"]!, statusCounts["unknown"]!, totalBlocks)

        // Wall-clock performance log — key metric for faster-than-realtime validation
        let offlineRenderWallElapsed = Date().timeIntervalSince(offlineRenderWallStart)
        let audioDurationForLog = totalSeconds
        let speedup = audioDurationForLog > 0 ? audioDurationForLog / offlineRenderWallElapsed : 0
        NSLog("[OfflineExport] wall-clock time=%.1fs for audio duration=%.1fs, speedup=%.2fx",
              offlineRenderWallElapsed, audioDurationForLog, speedup)

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

    private nonisolated static func hostedAudioUnitQualificationExcerpt(
        from notes: [PianoRollNote],
        startTick: Int,
        endTick: Int,
        ticksToSec: @escaping @Sendable (Int) -> Double
    ) -> (startTick: Int, endTick: Int)? {
        let sortedNotes = notes.sorted { lhs, rhs in
            if lhs.startTick != rhs.startTick { return lhs.startTick < rhs.startTick }
            return lhs.pitch < rhs.pitch
        }
        guard let firstAudibleNote = sortedNotes.first else { return nil }

        let excerptStartTick = min(max(startTick, firstAudibleNote.startTick), max(startTick, endTick - 1))
        let targetDurationSeconds = 12.0
        let excerptStartSeconds = ticksToSec(excerptStartTick)

        var excerptEndTick = min(endTick, max(excerptStartTick + 1, firstAudibleNote.startTick + firstAudibleNote.duration))
        for note in sortedNotes {
            let candidateEndTick = min(endTick, max(note.startTick + 1, note.startTick + note.duration))
            excerptEndTick = max(excerptEndTick, candidateEndTick)
            if ticksToSec(candidateEndTick) - excerptStartSeconds >= targetDurationSeconds {
                break
            }
        }

        guard excerptEndTick > excerptStartTick else { return nil }
        return (excerptStartTick, excerptEndTick)
    }

    private nonisolated static func hostedAudioUnitQualificationKey(
        projectIdentifier: String?,
        songPath: String?,
        startTick: Int,
        endTick: Int,
        mappingKeys: Set<String>,
        resolvedMappings: [String: InstrumentMapping],
        panMap: [String: Double],
        ticksPerQuarter: Int,
        tempoEvents: [TempoPoint]
    ) -> String {
        let mappingSignature = mappingKeys.sorted().map { key -> String in
            guard let mapping = resolvedMappings[key] else { return "\(key):missing" }
            let desc = mapping.audioComponentDescription
            let presetSize = mapping.auPresetData?.count ?? 0
            let pan = panMap[key] ?? 0
            return [
                key,
                mapping.effectiveSourceType.rawValue,
                String(desc?.componentType ?? 0),
                String(desc?.componentSubType ?? 0),
                String(desc?.componentManufacturer ?? 0),
                String(format: "%.2f", mapping.gainDB),
                String(format: "%.3f", pan),
                "preset:\(presetSize)",
            ].joined(separator: "|")
        }.joined(separator: ";")

        let tempoSignature = tempoEvents
            .sorted { $0.tick < $1.tick }
            .map { "\($0.tick)@\($0.bpm)" }
            .joined(separator: ",")

        return [
            "hosted-au-qualification:v14",
            projectIdentifier ?? "__unknown_project__",
            songPath ?? "__unsaved__",
            "ticks:\(startTick)-\(endTick)",
            "tpq:\(ticksPerQuarter)",
            "tempo:\(tempoSignature)",
            "mappings:\(mappingSignature)",
        ].joined(separator: "||")
    }

    private nonisolated static func hostedAudioUnitOfflineQualificationCacheURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Opera", isDirectory: true)
            .appendingPathComponent("HostedAudioUnitQualificationCache.json", isDirectory: false)
    }

    private nonisolated static func hostedAudioUnitQualificationArtifactsDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = appSupport
            .appendingPathComponent("Opera", isDirectory: true)
            .appendingPathComponent("HostedAudioUnitQualificationArtifacts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            NSLog("[OfflineExport] Failed to create qualification artifacts directory: %@", error.localizedDescription)
            return nil
        }
    }

    private nonisolated static func pruneHostedAudioUnitQualificationArtifacts(maxEntries: Int = 8) {
        guard let root = hostedAudioUnitQualificationArtifactsDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        let sorted = entries.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        for stale in sorted.dropFirst(maxEntries) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private nonisolated static func preserveHostedAudioUnitQualificationArtifacts(
        tempRoot: URL,
        qualificationKey: String,
        excerptStartTick: Int,
        excerptEndTick: Int,
        qualification: HostedAudioUnitOfflineQualification
    ) -> URL? {
        guard let root = hostedAudioUnitQualificationArtifactsDirectory() else { return nil }

        let safeSlug = qualificationKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "|", with: "_")
        let destination = root.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(safeSlug.prefix(80))",
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            let sourceFiles = (try? FileManager.default.contentsOfDirectory(
                at: tempRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            var copiedFiles: [String] = []
            for source in sourceFiles {
                let destinationFile = destination.appendingPathComponent(source.lastPathComponent)
                try? FileManager.default.removeItem(at: destinationFile)
                try FileManager.default.copyItem(at: source, to: destinationFile)
                copiedFiles.append(destinationFile.lastPathComponent)
            }

            let metadata = HostedAudioUnitQualificationArtifactRecord(
                createdAt: Date(),
                qualificationKey: qualificationKey,
                excerptStartTick: excerptStartTick,
                excerptEndTick: excerptEndTick,
                verdict: qualification.verdict,
                detail: qualification.detail,
                files: copiedFiles.sorted()
            )
            let metadataURL = destination.appendingPathComponent("metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

            pruneHostedAudioUnitQualificationArtifacts()
            NSLog("[OfflineExport] Preserved qualification artifacts at %@", destination.path)
            return destination
        } catch {
            NSLog("[OfflineExport] Failed to preserve qualification artifacts: %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    private nonisolated static func prunedHostedAudioUnitOfflineQualificationCache(
        _ cache: [String: HostedAudioUnitOfflineQualification]
    ) -> [String: HostedAudioUnitOfflineQualification] {
        let freshnessCutoff = Date().addingTimeInterval(-(60 * 60 * 24 * 30))
        let freshEntries = cache.filter { _, value in
            value.checkedAt >= freshnessCutoff
        }

        guard freshEntries.count > 256 else { return freshEntries }

        let orderedKeys = freshEntries
            .sorted { lhs, rhs in lhs.value.checkedAt > rhs.value.checkedAt }
            .prefix(256)
            .map(\.key)
        let keep = Set(orderedKeys)
        return freshEntries.filter { keep.contains($0.key) }
    }

    private nonisolated static func loadHostedAudioUnitOfflineQualificationCache() -> [String: HostedAudioUnitOfflineQualification] {
        guard let cacheURL = hostedAudioUnitOfflineQualificationCacheURL(),
              let data = try? Data(contentsOf: cacheURL) else {
            return [:]
        }

        do {
            let decoded = try JSONDecoder().decode([String: HostedAudioUnitOfflineQualification].self, from: data)
            return prunedHostedAudioUnitOfflineQualificationCache(decoded)
        } catch {
            NSLog("[OfflineExport] Failed to decode hosted-AU qualification cache: %@", error.localizedDescription)
            return [:]
        }
    }

    private func persistHostedAudioUnitOfflineQualificationCache() {
        let snapshot = Self.prunedHostedAudioUnitOfflineQualificationCache(hostedAudioUnitOfflineQualificationCache)
        hostedAudioUnitOfflineQualificationCache = snapshot

        guard let cacheURL = Self.hostedAudioUnitOfflineQualificationCacheURL() else { return }
        let snapshotToWrite = snapshot

        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshotToWrite)
                let directory = cacheURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
            } catch {
                NSLog("[OfflineExport] Failed to persist hosted-AU qualification cache: %@", error.localizedDescription)
            }
        }
    }

    private nonisolated static func audioDurationSeconds(at url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    private nonisolated static func openAnalysisAudioFile(
        at url: URL,
        retries: Int = 8,
        retryDelayMicroseconds: useconds_t = 20_000
    ) -> AVAudioFile? {
        for attempt in 0...retries {
            if let file = try? AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            ) {
                return file
            }

            if attempt < retries {
                usleep(retryDelayMicroseconds * useconds_t(attempt + 1))
            }
        }
        return nil
    }

    private nonisolated static func audioActiveDurationSeconds(
        at url: URL,
        silenceThreshold: Float = 1.0e-6
    ) -> Double? {
        guard let bounds = audioAudibleBounds(at: url, silenceThreshold: silenceThreshold),
              let audioFile = openAnalysisAudioFile(at: url) else {
            return nil
        }
        return Double(bounds.last) / audioFile.processingFormat.sampleRate
    }

    private nonisolated static func waitForAudioAudibleBounds(
        at url: URL,
        silenceThreshold: Float = 1.0e-6,
        attempts: Int = 60,
        retryDelayNanoseconds: UInt64 = 50_000_000
    ) async -> (first: AVAudioFramePosition, last: AVAudioFramePosition)? {
        for attempt in 0..<max(attempts, 1) {
            if let bounds = audioAudibleBounds(at: url, silenceThreshold: silenceThreshold) {
                return bounds
            }
            guard attempt + 1 < attempts else { break }
            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
        return nil
    }

    private nonisolated static func waitForQualificationAudioAudibleBounds(
        at url: URL,
        silenceThreshold: Float = 1.0e-6
    ) async -> (first: AVAudioFramePosition, last: AVAudioFramePosition)? {
        let name = url.lastPathComponent
        NSLog("[Phase0Bounds] waitForQualificationAudioAudibleBounds BEGIN file=%@", name)

        if let bounds = await waitForAudioAudibleBounds(at: url, silenceThreshold: silenceThreshold) {
            NSLog("[Phase0Bounds] waitForAudioAudibleBounds SUCCEEDED file=%@ first=%lld last=%lld",
                  name, bounds.first, bounds.last)
            return bounds
        }

        NSLog("[Phase0Bounds] waitForAudioAudibleBounds FAILED file=%@ — attempting clone fallback", name)

        // Log file size and AVAudioFile open attempt before clone
        let fileSizeStr: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let sz = attrs[.size] as? Int64 {
            fileSizeStr = "\(sz)"
        } else {
            fileSizeStr = "unavailable"
        }
        let openResult: String
        if (try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)) != nil {
            openResult = "ok"
        } else {
            openResult = "failed"
        }
        NSLog("[Phase0Bounds] pre-clone diagnostics file=%@ fileSize=%@ AVAudioFile-open=%@",
              name, fileSizeStr, openResult)

        let cloneURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-analysis-\(UUID().uuidString).wav")

        do {
            try FileManager.default.copyItem(at: url, to: cloneURL)
            defer { try? FileManager.default.removeItem(at: cloneURL) }
            if let bounds = await waitForAudioAudibleBounds(at: cloneURL, silenceThreshold: silenceThreshold) {
                NSLog("[Phase0Bounds] clone fallback SUCCEEDED file=%@ cloneFirst=%lld cloneLast=%lld",
                      name, bounds.first, bounds.last)
                return bounds
            } else {
                NSLog("[Phase0Bounds] clone fallback FAILED file=%@ — returning nil", name)
                return nil
            }
        } catch {
            NSLog("[Phase0Bounds] clone copy THREW file=%@ error=%@", name, error.localizedDescription)
            return nil
        }
    }

    private nonisolated static func audioAudibleBounds(
        at url: URL,
        silenceThreshold: Float = 1.0e-6
    ) -> (first: AVAudioFramePosition, last: AVAudioFramePosition)? {
        guard let audioFile = openAnalysisAudioFile(at: url) else {
            return nil
        }

        // [Phase1Bounds] Force a non-interleaved Float32 read format so floatChannelData is
        // always non-nil regardless of the WAV file's native interleaved/non-interleaved layout.
        // openAnalysisAudioFile already requests commonFormat:.pcmFormatFloat32 interleaved:false,
        // so audioFile.processingFormat is already correct — but we make an explicit readFormat
        // here to guarantee the buffer contract even if the file object was opened differently.
        let sampleRate = audioFile.processingFormat.sampleRate
        let channelCount = Int(audioFile.processingFormat.channelCount)
        guard channelCount > 0 else { return nil }

        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            NSLog("[Phase1Bounds] audioAudibleBounds: failed to create non-interleaved read format for %@", url.lastPathComponent)
            return nil
        }

        let chunkCapacity = AVAudioFrameCount(min(max(audioFile.length, 1), 65_536))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkCapacity) else {
            NSLog("[Phase1Bounds] audioAudibleBounds: buffer alloc failed for %@", url.lastPathComponent)
            return nil
        }

        NSLog("[Phase1Bounds] audioAudibleBounds: opened with forced non-interleaved format file=%@ sr=%.0f ch=%d frames=%lld",
              url.lastPathComponent, sampleRate, channelCount, audioFile.length)

        var framesRead: AVAudioFramePosition = 0
        var firstAudibleFrame: AVAudioFramePosition?
        var lastAudibleFrame: AVAudioFramePosition = 0

        while true {
            do {
                try audioFile.read(into: buffer, frameCount: chunkCapacity)
            } catch {
                NSLog("[Phase1Bounds] audioAudibleBounds: read error file=%@ framesRead=%lld error=%@",
                      url.lastPathComponent, framesRead, error.localizedDescription)
                break
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }

            guard let channelData = buffer.floatChannelData else {
                // Should never happen with a non-interleaved Float32 buffer — log and bail.
                NSLog("[Phase1Bounds] audioAudibleBounds: floatChannelData nil despite non-interleaved format file=%@", url.lastPathComponent)
                break
            }

            for frame in 0..<frameLength {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    peak = max(peak, abs(channelData[channel][frame]))
                }
                if peak > silenceThreshold {
                    if firstAudibleFrame == nil {
                        firstAudibleFrame = framesRead + AVAudioFramePosition(frame)
                    }
                    lastAudibleFrame = framesRead + AVAudioFramePosition(frame + 1)
                }
            }

            framesRead += AVAudioFramePosition(frameLength)
        }

        if let firstAudibleFrame {
            NSLog("[Phase1Bounds] audioAudibleBounds: found audible region file=%@ first=%lld last=%lld totalFramesRead=%lld",
                  url.lastPathComponent, firstAudibleFrame, lastAudibleFrame, framesRead)
            return (firstAudibleFrame, lastAudibleFrame)
        }

        NSLog("[Phase1Bounds] audioAudibleBounds: no audible frames found file=%@ totalFramesRead=%lld", url.lastPathComponent, framesRead)
        return nil
    }

    private nonisolated static func shiftAudioFileLeadingFrames(
        at url: URL,
        frameOffset: AVAudioFramePosition
    ) throws {
        guard frameOffset != 0 else { return }

        guard let inputFile = openAnalysisAudioFile(at: url) else {
            throw ChunkExportError.bufferCreationFailed
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-shifted-\(UUID().uuidString).wav")
        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: inputFile.processingFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let chunkCapacity = AVAudioFrameCount(min(max(inputFile.length, 1), 65_536))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: chunkCapacity) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ChunkExportError.bufferCreationFailed
        }

        if frameOffset > 0 {
            guard frameOffset < inputFile.length else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            inputFile.framePosition = frameOffset
        } else {
            let silenceFrames = AVAudioFrameCount(-frameOffset)
            guard let silenceBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFile.processingFormat,
                frameCapacity: silenceFrames
            ) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw ChunkExportError.bufferCreationFailed
            }
            silenceBuffer.frameLength = silenceFrames
            if let channelData = silenceBuffer.floatChannelData {
                let channelCount = Int(inputFile.processingFormat.channelCount)
                for channel in 0..<channelCount {
                    channelData[channel].initialize(repeating: 0, count: Int(silenceFrames))
                }
            }
            try outputFile.write(from: silenceBuffer)
            inputFile.framePosition = 0
        }

        while true {
            try inputFile.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
        }

        _ = outputFile
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    /// Truncates a WAV file in-place to at most `frameCount` frames.
    /// If the file is already shorter or equal, this is a no-op.
    /// Used by the hosted-AU qualification path (Phase 2a) to cap the offline
    /// excerpt tail at the realtime engine's audible end frame before comparison.
    private nonisolated static func trimAudioFileToFrameCount(
        at url: URL,
        frameCount: AVAudioFramePosition
    ) throws {
        guard frameCount > 0 else { return }

        guard let inputFile = openAnalysisAudioFile(at: url) else {
            throw ChunkExportError.bufferCreationFailed
        }
        guard inputFile.length > frameCount else {
            // File is already at or within the target length — nothing to do.
            return
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-trimmed-\(UUID().uuidString).wav")
        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: inputFile.processingFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let chunkCapacity = AVAudioFrameCount(65_536)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: chunkCapacity) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ChunkExportError.bufferCreationFailed
        }

        inputFile.framePosition = 0
        var framesRemaining = frameCount
        while framesRemaining > 0 {
            let framesToRead = AVAudioFrameCount(min(framesRemaining, AVAudioFramePosition(chunkCapacity)))
            buffer.frameLength = 0
            do {
                try inputFile.read(into: buffer, frameCount: framesToRead)
            } catch {
                // EOF thrown by AVAudioFile — treat as end of data.
                if buffer.frameLength > 0 {
                    try outputFile.write(from: buffer)
                }
                break
            }
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
            framesRemaining -= AVAudioFramePosition(buffer.frameLength)
        }

        _ = outputFile
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
        NSLog("[Phase2a] trimAudioFileToFrameCount: trimmed %@ to %lld frames", url.lastPathComponent, frameCount)
    }

    private nonisolated static func audioEnvelopeSimilarity(
        fileA: URL,
        fileB: URL,
        windowFrames: AVAudioFrameCount = 2048
    ) -> Double? {
        guard let envelopeA = rmsEnvelope(at: fileA, windowFrames: windowFrames),
              let envelopeB = rmsEnvelope(at: fileB, windowFrames: windowFrames) else {
            return nil
        }

        let count = min(envelopeA.count, envelopeB.count)
        guard count > 0 else { return nil }

        var dot = 0.0
        var normA = 0.0
        var normB = 0.0

        for index in 0..<count {
            let lhs = envelopeA[index]
            let rhs = envelopeB[index]
            dot += lhs * rhs
            normA += lhs * lhs
            normB += rhs * rhs
        }

        guard normA > 0, normB > 0 else { return nil }
        return max(0, min(1, dot / (sqrt(normA) * sqrt(normB))))
    }

    private nonisolated static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return 0 }

        var sumSquares: Float = 0
        for channel in 0..<channelCount {
            var channelSquares: Float = 0
            vDSP_svesq(channelData[channel], 1, &channelSquares, vDSP_Length(frameLength))
            sumSquares += channelSquares
        }
        let sampleCount = Float(frameLength * channelCount)
        guard sampleCount > 0 else { return 0 }
        return sqrt(sumSquares / sampleCount)
    }

    private nonisolated static func rmsEnvelope(
        at url: URL,
        windowFrames: AVAudioFrameCount
    ) -> [Double]? {
        guard let audioFile = openAnalysisAudioFile(at: url) else {
            NSLog("[Phase1fEnv] rmsEnvelope: failed to open file %@", url.lastPathComponent)
            return nil
        }

        // [Phase1fEnv] Force a non-interleaved Float32 read format so floatChannelData is
        // always non-nil regardless of the WAV file's native interleaved/non-interleaved layout.
        // Mirrors the same fix applied to audioAudibleBounds in Phase 1.
        let sampleRate = audioFile.processingFormat.sampleRate
        let channelCount = Int(audioFile.processingFormat.channelCount)
        guard channelCount > 0 else {
            NSLog("[Phase1fEnv] rmsEnvelope: channelCount==0 for %@", url.lastPathComponent)
            return nil
        }

        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            NSLog("[Phase1fEnv] rmsEnvelope: failed to create non-interleaved read format for %@", url.lastPathComponent)
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: readFormat,
            frameCapacity: AVAudioFrameCount(max(1, min(audioFile.length, 65_536)))
        ) else {
            NSLog("[Phase1fEnv] rmsEnvelope: buffer alloc failed for %@", url.lastPathComponent)
            return nil
        }

        NSLog("[Phase1fEnv] rmsEnvelope: opened with forced non-interleaved format file=%@ sr=%.0f ch=%d frames=%lld",
              url.lastPathComponent, sampleRate, channelCount, audioFile.length)

        var envelope: [Double] = []
        var sumSquares = 0.0
        var sampleCount = 0
        let channels = channelCount

        while true {
            do {
                try audioFile.read(into: buffer)
            } catch {
                // AVAudioFile throws at EOF — treat as end of stream, not a fatal error.
                NSLog("[Phase1fEnv] rmsEnvelope: read error (EOF?) file=%@ error=%@", url.lastPathComponent, error.localizedDescription)
                break
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channelData = buffer.floatChannelData else {
                NSLog("[Phase1fEnv] rmsEnvelope: floatChannelData nil (interleaved?) file=%@", url.lastPathComponent)
                return nil
            }

            for frame in 0..<frameLength {
                var monoSample = 0.0
                for channel in 0..<channels {
                    monoSample += Double(channelData[channel][frame])
                }
                monoSample /= Double(max(channels, 1))
                sumSquares += monoSample * monoSample
                sampleCount += 1

                if sampleCount >= Int(windowFrames) {
                    envelope.append(sqrt(sumSquares / Double(sampleCount)))
                    sumSquares = 0
                    sampleCount = 0
                }
            }
        }

        if sampleCount > 0 {
            envelope.append(sqrt(sumSquares / Double(sampleCount)))
        }

        NSLog("[Phase1fEnv] rmsEnvelope: success file=%@ envelopeCount=%d", url.lastPathComponent, envelope.count)
        return envelope
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

    private struct SongWavExportPlan {
        let notes: [PianoRollNote]
        let endTick: Int
        let instrumentalOnly: Bool
    }

    private enum SongWavExportError: LocalizedError {
        case noNotes
        case noInstrumentalNotes
        case zeroLength

        var errorDescription: String? {
            switch self {
            case .noNotes:
                "No notes to export."
            case .noInstrumentalNotes:
                "No instrument-track notes to export."
            case .zeroLength:
                "Song has zero length."
            }
        }
    }

    private func mappingKeyForExportNote(
        _ note: PianoRollNote,
        channelKeyMap: [String: String]? = nil
    ) -> String {
        let pairKey = "\(note.trackIndex):\(note.channel)"
        return (channelKeyMap ?? pianoRollChannelKeyByTrackChannel)[pairKey] ?? "__default__"
    }

    private func mappingForExportKey(
        _ mappingKey: String,
        resolvedMappings: [String: InstrumentMapping]
    ) -> InstrumentMapping? {
        if let direct = resolvedMappings[mappingKey] {
            return direct
        }

        if mappingKey.hasPrefix("song|"),
           let lastPipe = mappingKey.lastIndex(of: "|") {
            let baseKey = String(mappingKey[mappingKey.index(after: lastPipe)...])
            return resolvedMappings[baseKey] ?? instrumentMappings[baseKey]
        }

        return nil
    }

    private func instrumentalNotesForExport(
        from notes: [PianoRollNote],
        channelKeyMap: [String: String]? = nil,
        resolvedMappings: [String: InstrumentMapping]? = nil
    ) -> [PianoRollNote] {
        let effectiveChannelKeyMap = channelKeyMap ?? pianoRollChannelKeyByTrackChannel
        let effectiveMappings = resolvedMappings ?? resolvedInstrumentMappings()

        return notes.filter { note in
            let mappingKey = mappingKeyForExportNote(note, channelKeyMap: effectiveChannelKeyMap)
            guard let mapping = mappingForExportKey(mappingKey, resolvedMappings: effectiveMappings) else {
                return true
            }
            return mapping.trackRole != .vocal
        }
    }

    private func makeCurrentSongWavExportPlan(instrumentalOnly: Bool = false) throws -> SongWavExportPlan {
        let allNotes = pianoRollNotes
        guard !allNotes.isEmpty else {
            throw SongWavExportError.noNotes
        }

        let endTick = allNotes.map { $0.startTick + $0.duration }.max() ?? pianoRollLengthTicks
        guard endTick > 0 else {
            throw SongWavExportError.zeroLength
        }

        let exportNotes = instrumentalOnly
            ? instrumentalNotesForExport(from: allNotes)
            : allNotes

        guard !exportNotes.isEmpty else {
            throw instrumentalOnly ? SongWavExportError.noInstrumentalNotes : SongWavExportError.noNotes
        }

        return SongWavExportPlan(notes: exportNotes, endTick: endTick, instrumentalOnly: instrumentalOnly)
    }

    private func performWavExport(
        _ plan: SongWavExportPlan,
        outputURL: URL,
        timeout: TimeInterval = 600
    ) async throws {
        // Prevent App Nap / automatic termination from killing a long export.
        // This matters in headless mode (no visible window) and on laptops
        // where macOS may nap inactive apps mid-render.
        let activityOptions: ProcessInfo.ActivityOptions = [
            .userInitiated,
            .latencyCritical,
            .idleSystemSleepDisabled
        ]
        let activity = ProcessInfo.processInfo.beginActivity(
            options: activityOptions,
            reason: plan.instrumentalOnly ? "Instrumental WAV export" : "WAV export"
        )
        ProcessInfo.processInfo.disableSuddenTermination()
        defer {
            ProcessInfo.processInfo.enableSuddenTermination()
            ProcessInfo.processInfo.endActivity(activity)
        }

        // Race the render against a timeout. If a hosted XPC AudioUnit wedges
        // (eventlink wait that never returns), the renderOffline call cannot be
        // cancelled cleanly — but the surrounding Task can be abandoned so the
        // batch loop continues with the next song instead of hanging forever.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await self.renderChunkToWav(
                    notes: plan.notes,
                    startTick: 0,
                    endTick: plan.endTick,
                    outputURL: outputURL
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ChunkExportError.offlineRenderTimedOut(timeout)
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

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
        guard !isPresentingFullMixExportPanel else { return }

        isPresentingFullMixExportPanel = true

        let panel = NSSavePanel()
        panel.title = "Export Full Mix to WAV"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = fullMixExportPanelDefaultFilename()
        panel.directoryURL = fullMixExportPanelDefaultDirectoryURL()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            Task { @MainActor in
                guard let self else { return }
                self.isPresentingFullMixExportPanel = false
                guard response == .OK, let url = panel.url else { return }
                await self.exportFullMixToWav(outputURL: url)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func exportInstrumentalMixToWavWithPanel() {
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }
        guard !isExportingFullMix else {
            fullMixExportStatus = "Export already in progress."
            return
        }
        guard !isPresentingFullMixExportPanel else { return }

        isPresentingFullMixExportPanel = true

        let panel = NSSavePanel()
        panel.title = "Export Instrumental Mix to WAV"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = instrumentalExportPanelDefaultFilename()
        panel.directoryURL = fullMixExportPanelDefaultDirectoryURL()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            Task { @MainActor in
                guard let self else { return }
                self.isPresentingFullMixExportPanel = false
                guard response == .OK, let url = panel.url else { return }
                await self.exportInstrumentalMixToWav(outputURL: url)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    #endif

    #if canImport(AppKit)
    private func fullMixExportPanelDefaultFilename() -> String {
        wavExportPanelDefaultFilename(suffix: nil)
    }

    private func instrumentalExportPanelDefaultFilename() -> String {
        wavExportPanelDefaultFilename(suffix: "Instrumental")
    }

    private func wavExportPanelDefaultFilename(suffix: String?) -> String {
        let rawName = selectedMidiAsset?.displayName ?? metadata.name
        let sanitized = rawName
            .components(separatedBy: Self.invalidExportFilenameCharacters)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var baseName = sanitized.isEmpty ? "untitled" : sanitized
        if baseName.lowercased().hasSuffix(".wav") {
            baseName = String(baseName.dropLast(4))
        }

        let suffixPart = suffix
            .map { " - \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            ?? ""
        return "\(baseName)\(suffixPart).wav"
    }

    private func fullMixExportPanelDefaultDirectoryURL() -> URL? {
        guard let projectRoot = fileProjectURL else { return nil }
        let paths = ProjectPaths(root: projectRoot)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: paths.mixExports,
                withIntermediateDirectories: true
            )
            return paths.mixExports
        } catch {
            NSLog("[FullMix] Could not prepare default export directory %@: %@",
                  paths.mixExports.path, error.localizedDescription)
        }

        if fileManager.fileExists(atPath: paths.mix.path) {
            return paths.mix
        }
        return projectRoot
    }

    private static var invalidExportFilenameCharacters: CharacterSet {
        var characters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        characters.formUnion(.newlines)
        characters.formUnion(.controlCharacters)
        return characters
    }
    #endif

    /// Render the full song to a WAV file at the given URL.
    func exportFullMixToWav(outputURL: URL) async {
        await exportSongWav(outputURL: outputURL, instrumentalOnly: false)
    }

    /// Render the current song to a WAV file with vocal-tagged tracks omitted.
    func exportInstrumentalMixToWav(outputURL: URL) async {
        await exportSongWav(outputURL: outputURL, instrumentalOnly: true)
    }

    private func exportSongWav(outputURL: URL, instrumentalOnly: Bool) async {
        let plan: SongWavExportPlan
        do {
            plan = try makeCurrentSongWavExportPlan(instrumentalOnly: instrumentalOnly)
        } catch {
            fullMixExportStatus = error.localizedDescription
            return
        }

        isExportingFullMix = true
        fullMixExportProgress = 0
        fullMixExportStatus = instrumentalOnly ? "Rendering instrumental mix..." : "Rendering full mix..."
        fullMixExportDetailStatus = ""

        // Estimate total duration for progress tracking
        let estimatedSeconds = Self.ticksToSecondsStatic(
            plan.endTick,
            ticksPerQuarter: ticksPerQuarter,
            tempoEvents: pianoRollTempoEvents
        )
        let exportStartTime = Date()

        // Progress timer — updates every 0.25s during the export
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            let shouldInvalidate = MainActor.assumeIsolated {
                guard let self, self.isExportingFullMix else {
                    return true
                }
                let elapsed = Date().timeIntervalSince(exportStartTime)
                let progress = estimatedSeconds > 0 ? min(elapsed / (estimatedSeconds + 2), 0.99) : 0
                self.fullMixExportProgress = progress
                return false
            }
            if shouldInvalidate {
                timer.invalidate()
            }
        }

        do {
            try await performWavExport(plan, outputURL: outputURL)
            fullMixExportProgress = 1.0
            fullMixExportStatus = instrumentalOnly
                ? "Exported instrumental mix to \(outputURL.lastPathComponent)"
                : "Exported to \(outputURL.lastPathComponent)"
            fullMixExportDetailStatus = ""
            let exportedBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            NSLog("[%@] export returning status=success bytes=%lld path=%@",
                  instrumentalOnly ? "InstrumentalMix" : "FullMix",
                  exportedBytes,
                  outputURL.path)
        } catch {
            fullMixExportStatus = "Export failed: \(error.localizedDescription)"
            fullMixExportDetailStatus = ""
            NSLog("[%@] export returning status=error reason=%@",
                  instrumentalOnly ? "InstrumentalMix" : "FullMix",
                  error.localizedDescription)
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
        fullMixExportDetailStatus = ""

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
            fullMixExportDetailStatus = ""
            NSLog("[Rehearsal] Exported rehearsal track to %@", outputURL.path)
        } catch {
            fullMixExportStatus = "Export failed: \(error.localizedDescription)"
            fullMixExportDetailStatus = ""
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
        fullMixExportDetailStatus = ""

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
        fullMixExportDetailStatus = ""
        NSLog("[Stems] Exported %d stems to %@", exported, outputDir.path)
        isExportingFullMix = false
    }

    // MARK: - Send-to-Mix / Batch Export

    private func wavExportURL(for asset: MidiAsset, in directory: URL, suffix: String? = nil) -> URL {
        let slug = asset.displayName
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let safeName = slug.isEmpty ? "untitled" : slug
        let suffixPart = suffix
            .map { "_\($0.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_")))" }
            ?? ""
        return directory.appendingPathComponent("\(safeName)\(suffixPart).wav")
    }

    /// Returns the output URL for a song's Mix export WAV.
    /// Path: <projectURL>/Mix/exports/<slug>.wav
    private func mixExportURL(for asset: MidiAsset) -> URL? {
        guard let projectURL = fileProjectURL else { return nil }
        let exportsDir = ProjectPaths(root: projectURL).mixExports
        return wavExportURL(for: asset, in: exportsDir)
    }

    /// Export the currently-loaded song to <projectURL>/Mix/exports/<slug>.wav
    /// and post `didExportSongToMix` so the Mix layer can register the clip.
    func exportCurrentSongToMix() {
        guard let asset = selectedMidiAsset else {
            fullMixExportStatus = "No song selected."
            return
        }
        guard !pianoRollNotes.isEmpty else {
            fullMixExportStatus = "No notes to export."
            return
        }
        guard !isExportingFullMix else {
            fullMixExportStatus = "Export already in progress."
            return
        }
        guard let outputURL = mixExportURL(for: asset) else {
            fullMixExportStatus = "No project open."
            return
        }
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                fullMixExportStatus = "Could not create Mix/exports/: \(error.localizedDescription)"
                return
            }
            await exportFullMixToWav(outputURL: outputURL)
            if fullMixExportStatus.hasPrefix("Exported") {
                NotificationCenter.default.post(
                    name: ScoreStore.didExportSongToMix,
                    object: nil,
                    userInfo: [
                        "wavURL": outputURL,
                        "songRelativePath": asset.relativePath
                    ]
                )
            }
        }
    }

    #if canImport(AppKit)
    func exportAllSongsToWavsWithPanel() {
        guard !midiAssets.isEmpty else {
            batchExportStatus = "No songs to export."
            return
        }
        guard !isBatchExporting, !isExportingFullMix else {
            batchExportStatus = "An export is already in progress."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Folder for WAV Exports"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                await self.exportAllSongsToWavs(outputDir: url)
            }
        }
    }

    func exportAllSongsToInstrumentalWavsWithPanel() {
        guard !midiAssets.isEmpty else {
            batchExportStatus = "No songs to export."
            return
        }
        guard !isBatchExporting, !isExportingFullMix else {
            batchExportStatus = "An export is already in progress."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Folder for Instrumental WAV Exports"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                await self.exportAllSongsToInstrumentalWavs(outputDir: url)
            }
        }
    }
    #endif

    func exportAllSongsToWavs(outputDir: URL) async {
        await exportAllSongsToWavs(outputDir: outputDir, instrumentalOnly: false)
    }

    func exportAllSongsToInstrumentalWavs(outputDir: URL) async {
        await exportAllSongsToWavs(outputDir: outputDir, instrumentalOnly: true)
    }

    private func exportAllSongsToWavs(outputDir: URL, instrumentalOnly: Bool) async {
        guard !midiAssets.isEmpty else {
            batchExportStatus = "No songs to export."
            return
        }
        guard !isBatchExporting, !isExportingFullMix else {
            batchExportStatus = "An export is already in progress."
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            batchExportStatus = "Could not create export folder: \(error.localizedDescription)"
            return
        }

        isBatchExporting = true
        batchExportProgress = 0
        batchExportStatus = instrumentalOnly
            ? "Starting instrumental WAV batch export..."
            : "Starting WAV batch export..."

        let assets = midiAssets
        var exported = 0
        var skippedExisting = 0
        var exportable = 0

        for (index, asset) in assets.enumerated() {
            let outputURL = wavExportURL(
                for: asset,
                in: outputDir,
                suffix: instrumentalOnly ? "Instrumental" : nil
            )

            // Resume support: if a non-empty WAV is already on disk for this song,
            // count it as done and move on without paying hydration / render cost.
            // Lets a re-run after a crash or hung render pick up where it left off.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
               let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 {
                NSLog("[%@] Skipping %@ — already exported (%d bytes at %@)",
                      instrumentalOnly ? "BatchInstrumentalWAV" : "BatchWAV",
                      asset.displayName,
                      size,
                      outputURL.path)
                batchExportStatus = instrumentalOnly
                    ? "Skipping instrumental \(asset.displayName) (\(index + 1)/\(assets.count)) — already on disk"
                    : "Skipping \(asset.displayName) (\(index + 1)/\(assets.count)) — already on disk"
                exportable += 1
                exported += 1
                skippedExisting += 1
                batchExportProgress = Double(index + 1) / Double(assets.count)
                continue
            }

            batchExportStatus = "Hydrating \(asset.displayName)..."

            _ = await hydrateSongPlaybackIfNeeded(id: asset.id)

            let savedSelectedID = selectedMidiID
            if selectedMidiID != asset.id {
                setSelectedMidi(id: asset.id, stopPlaybackBeforeSelect: true)
                for _ in 0..<3 { await Task.yield() }
            }

            let plan: SongWavExportPlan
            do {
                plan = try makeCurrentSongWavExportPlan(instrumentalOnly: instrumentalOnly)
            } catch {
                NSLog("[%@] Skipping %@ — %@",
                      instrumentalOnly ? "BatchInstrumentalWAV" : "BatchWAV",
                      asset.displayName,
                      error.localizedDescription)
                batchExportProgress = Double(index + 1) / Double(assets.count)
                if savedSelectedID != asset.id {
                    setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false)
                }
                continue
            }

            exportable += 1
            batchExportStatus = instrumentalOnly
                ? "Rendering instrumental \(asset.displayName) (\(index + 1)/\(assets.count))..."
                : "Rendering \(asset.displayName) (\(index + 1)/\(assets.count))..."

            do {
                try await performWavExport(plan, outputURL: outputURL)
                exported += 1
                NSLog("[%@] Exported %@ -> %@",
                      instrumentalOnly ? "BatchInstrumentalWAV" : "BatchWAV",
                      asset.displayName,
                      outputURL.path)
            } catch {
                NSLog("[%@] Failed %@: %@",
                      instrumentalOnly ? "BatchInstrumentalWAV" : "BatchWAV",
                      asset.displayName,
                      error.localizedDescription)
                // Best-effort cleanup: a timed-out / failed render may leave a
                // partial / zero-byte WAV that would fool the resume guard.
                let exists = FileManager.default.fileExists(atPath: outputURL.path)
                let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if exists && size < 1024 {
                    try? FileManager.default.removeItem(at: outputURL)
                }
            }

            batchExportProgress = Double(index + 1) / Double(assets.count)

            if savedSelectedID != asset.id {
                setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false)
                for _ in 0..<2 { await Task.yield() }
            }
        }

        batchExportProgress = 1.0
        if exportable == 0 {
            batchExportStatus = instrumentalOnly
                ? "No songs with instrument-track note data to export."
                : "No songs with note data to export."
        } else {
            let skipNote = skippedExisting > 0 ? " (\(skippedExisting) already on disk)" : ""
            batchExportStatus = instrumentalOnly
                ? "Instrumental WAV batch export done — \(exported)/\(exportable) songs\(skipNote)."
                : "WAV batch export done — \(exported)/\(exportable) songs\(skipNote)."
        }
        isBatchExporting = false
    }

    /// Export ALL songs that have MIDI note data to <projectURL>/Mix/exports/.
    /// Loads each song if not already hydrated. Posts `didExportSongToMix` per song.
    func exportAllSongsToMix() async {
        guard let projectURL = fileProjectURL else {
            batchExportStatus = "No project open."
            return
        }
        guard !isBatchExporting, !isExportingFullMix else {
            batchExportStatus = "An export is already in progress."
            return
        }

        let exportsDir = ProjectPaths(root: projectURL).mixExports
        do {
            try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        } catch {
            batchExportStatus = "Could not create Mix/exports/: \(error.localizedDescription)"
            return
        }

        isBatchExporting = true
        batchExportProgress = 0
        batchExportStatus = "Starting batch export..."

        let assets = midiAssets
        var exported = 0

        for (index, asset) in assets.enumerated() {
            batchExportStatus = "Hydrating \(asset.displayName)..."

            // Ensure song is loaded from disk (hydrateSongPlaybackIfNeeded is the public-ish entry point)
            _ = await hydrateSongPlaybackIfNeeded(id: asset.id)

            // Switch to this song so pianoRollNotes / mappings are populated
            let savedSelectedID = selectedMidiID
            if selectedMidiID != asset.id {
                setSelectedMidi(id: asset.id, stopPlaybackBeforeSelect: true)
                // Brief yield so @Observable updates propagate
                for _ in 0..<3 { await Task.yield() }
            }

            guard !pianoRollNotes.isEmpty else {
                NSLog("[BatchExport] Skipping %@ — no notes.", asset.displayName)
                batchExportProgress = Double(index + 1) / Double(assets.count)
                if savedSelectedID != asset.id { setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false) }
                continue
            }

            guard let outputURL = mixExportURL(for: asset) else { continue }

            batchExportStatus = "Rendering \(asset.displayName) (\(index + 1)/\(assets.count))..."
            let endTick = pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? 0
            guard endTick > 0 else {
                batchExportProgress = Double(index + 1) / Double(assets.count)
                if savedSelectedID != asset.id { setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false) }
                continue
            }

            do {
                try await renderChunkToWav(notes: pianoRollNotes, startTick: 0, endTick: endTick, outputURL: outputURL)
                exported += 1
                NSLog("[BatchExport] Exported %@ -> %@", asset.displayName, outputURL.path)
                let capturedPath = asset.relativePath
                NotificationCenter.default.post(
                    name: ScoreStore.didExportSongToMix,
                    object: nil,
                    userInfo: ["wavURL": outputURL, "songRelativePath": capturedPath]
                )
            } catch {
                NSLog("[BatchExport] Failed %@: %@", asset.displayName, error.localizedDescription)
            }

            batchExportProgress = Double(index + 1) / Double(assets.count)

            // Restore original selection if we changed it
            if savedSelectedID != asset.id {
                setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false)
                for _ in 0..<2 { await Task.yield() }
            }
        }

        batchExportProgress = 1.0
        batchExportStatus = "Batch export done — \(exported)/\(assets.count) songs exported."
        isBatchExporting = false
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

        let exportDir = Self.legacyDesktopExportDirectory()
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
        sunoExportStatus = "Exported \(chunks.count) chunks to Desktop/\(Self.legacyDesktopExportDirectory().lastPathComponent)/\(safeName)"
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

    func runSunoSelftest() async {
        sunoCLIErrorMessage = nil
        sunoCLIStatusMessage = nil
        do {
            let result = try await sunoCLI.selftest()
            sunoCLILastSelftest = result
            sunoCLIStatusMessage = result.loggedIn
                ? "Suno login is active for the persistent CLI profile."
                : "Suno is not logged in yet. Use Open Suno Login, sign in once, then rerun Selftest."
        } catch {
            sunoCLIErrorMessage = error.localizedDescription
        }
    }

    func openSunoLoginBrowser() async {
        sunoCLIErrorMessage = nil
        do {
            let browserName = try await sunoCLI.openLoginBrowser()
            sunoCLIStatusMessage = "Opened \(browserName) with the Suno CLI profile. Sign in once; the cookies stay in this profile until Suno expires them."
            appendSunoLog("Opened Suno login browser using persistent profile at \(sunoCLI.profileDir)")
        } catch {
            sunoCLIErrorMessage = error.localizedDescription
            sunoCLIStatusMessage = nil
        }
    }

    func revealSunoProfileDirectory() {
        #if canImport(AppKit)
        let profileURL = URL(fileURLWithPath: sunoCLI.profileDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true, attributes: nil)
        NSWorkspace.shared.activateFileViewerSelecting([profileURL])
        sunoCLIStatusMessage = "Revealed the persistent Suno profile folder in Finder."
        #else
        sunoCLIStatusMessage = "The Suno profile folder can only be revealed on macOS."
        #endif
    }

    func sunoGenerateOriginalSong() async {
        sunoGenerateStatus = "Original-song Suno generation is deprecated. Use the canonical cover workflow instead."
    }

    /// Generate a track via the Suno CLI.
    /// This blocks until the track is generated (can take several minutes).
    func sunoGenerateTrack(
        prompt: String,
        style: String? = nil,
        excludeStyles: String? = nil,
        lyrics: String? = nil
    ) async {
        let resolvedStyle = (style?.isEmpty == false ? style! : sunoStyleTemplate)
        guard !resolvedStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sunoGenerateStatus = "Set a Suno style before generating."
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
            style: resolvedStyle,
            excludeStyles: excludeStyles,
            lyrics: lyrics,
            status: .generating
        )
        sunoGenerations.insert(generation, at: 0)
        let genID = generation.id

        do {
            let result = try await sunoCLI.generateOriginal(
                prompt: prompt,
                style: resolvedStyle,
                lyrics: lyrics,
                wait: true
            )
            if let idx = sunoGenerations.firstIndex(where: { $0.id == genID }) {
                let trackID = result.songIDs.first
                sunoGenerations[idx].trackID = trackID
                sunoGenerations[idx].status = trackID == nil ? .submitted : .ready
                sunoGenerations[idx].resultMessage = result.message
            }
            sunoGenerateStatus = result.songIDs.first == nil
                ? "Track submitted in Suno"
                : "Track ready"
            NSLog("[SunoCLI] Generate succeeded: %@", result.message)
        } catch {
            if let idx = sunoGenerations.firstIndex(where: { $0.id == genID }) {
                sunoGenerations[idx].status = .error
                sunoGenerations[idx].errorMessage = error.localizedDescription
            }
            sunoGenerateStatus = "Generation failed: \(error.localizedDescription)"
            NSLog("[SunoCLI] Generate failed: %@", error.localizedDescription)
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
                throw SunoCLIError.runtime(message: "No Suno track ID found in generation result.")
            }
            sunoGenerations[idx].trackID = trackID
            let downloadDir = sunoDownloadDirectory()
            let download = try await sunoCLI.downloadSong(
                songID: trackID,
                format: "mp3",
                out: downloadDir.path
            )

            NSLog("[SunoCLI] Download result: %@", download.path)

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
                throw SunoCLIError.runtime(message: "No audio file found in downloads directory.")
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

    /// Close any orphan Playwright browsers from prior CLI invocations.
    func sunoCloseBrowser() async {
        do {
            try await sunoCLI.browserClose()
        } catch {
            NSLog("[SunoCLI] browserClose failed: %@", error.localizedDescription)
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
        guard sunoCLI.isInstalled else {
            appendSunoLog("Suno CLI not installed at \(sunoCLI.cliPath) — configure path in Suno > Settings", level: .error)
            statusMessage = "Suno CLI not installed"
            return
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
        let renderDir = ProjectPaths(root: owpURL)
            .sunoRenderDir(renderID: session.id.uuidString)
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
        let desktop = Self.legacyDesktopExportDirectory()
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
            throw SunoCLIError.runtime(message: "Cannot create output audio format")
        }

        let outputFile = try AVAudioFile(forWriting: output, settings: outputFormat.settings)

        // Read in chunks and write — use the processing format for the buffer
        let bufferSize: AVAudioFrameCount = 65536
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferSize) else {
            throw SunoCLIError.runtime(message: "Cannot create read buffer")
        }

        // Always use converter — inputFormat is float32 (AVAudioFile processingFormat)
        // but output is int16, so direct copy would write wrong sample format.
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SunoCLIError.runtime(message: "Cannot create audio converter")
        }
        guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else {
            throw SunoCLIError.runtime(message: "Cannot create write buffer")
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
            freezeDir = Self.preferredAppSupportDirectory()
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
    static func preferredAppSupportDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let preferred = appSupport.appendingPathComponent("Score", isDirectory: true)
        let legacy = appSupport.appendingPathComponent("Novotro Score", isDirectory: true)
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        if fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return preferred
    }

    /// Returns the project-local Exports directory (inside the OWP bundle) so that
    /// export discovery never touches ~/Desktop and avoids TCC permission prompts.
    /// The actual export function creates this directory on demand.
    static func preferredExportDirectory(projectURL: URL?) -> URL {
        if let projectURL {
            let dir = projectURL.appendingPathComponent("Exports", isDirectory: true)
            return dir
        }
        // Fallback: use Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Amira Writer", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    /// Legacy Desktop export directory — only called during user-initiated exports,
    /// never during discovery/startup, to avoid TCC prompts.
    static func legacyDesktopExportDirectory(fileManager: FileManager = .default) -> URL {
        let desktop = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let preferred = desktop.appendingPathComponent("Score Export", isDirectory: true)
        let legacy = desktop.appendingPathComponent("Novotro Score Export", isDirectory: true)
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        if fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return preferred
    }

    /// Ensures the Score support directory exists (for lessons.md, etc.).
    static func ensureAppSupportDirectory() {
        let dir = preferredAppSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - Canonical Suno Cover Workflow

@available(macOS 26.0, *)
extension ScoreStore {

    private static let sunoCoverQueueDelayRangeSeconds = 300...600

    /// The prompt actually sent to the CLI: user override wins, else the enum preset's prompt.
    func effectiveSunoCoverPrompt() -> String {
        let override = sunoCoverPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        return sunoResolvedCoverPrompt
    }

    /// The lyrics actually sent to the CLI. Returns nil if the preset needs vocals
    /// but no lyrics are available (caller should refuse to run).
    func effectiveSunoCoverLyrics() -> String? {
        let override = sunoCoverLyricsOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        if !sunoCoverPreset.requiresLyrics { return "[Instrumental]" }
        let fromTab = formattedSunoLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return fromTab.isEmpty ? nil : fromTab
    }

    func sunoRunCanonicalCover() async {
        guard !sunoIsGenerating else {
            sunoGenerateStatus = "Already running."
            return
        }
        guard let projectRoot = resolvedSunoProjectRoot() else {
            sunoGenerateStatus = "Open the full opera project before running Suno."
            appendSunoLog("Could not resolve the opera project root for Suno export", level: .error)
            return
        }

        let targetPaths = sunoResolvedCoverTargetPaths
        switch sunoCoverSourceMode {
        case .currentSong where targetPaths.isEmpty:
            sunoGenerateStatus = "Select a song before running Suno."
            appendSunoLog("No song selected for Suno cover generation", level: .warning)
            return
        case .selectedSongs where targetPaths.isEmpty:
            sunoGenerateStatus = "Check at least one song before running Suno."
            appendSunoLog("No songs checked for Suno cover batch", level: .warning)
            return
        default:
            break
        }

        let lyrics = effectiveSunoCoverLyrics()
        guard sunoCanRunCanonicalCover, let lyrics else {
            sunoGenerateStatus = "This preset needs real lyrics (Lyrics tab or Lyrics Override)."
            appendSunoLog("Preset \(sunoCoverPreset.title) requires real lyrics", level: .warning)
            return
        }

        let prompt = effectiveSunoCoverPrompt()
        let negativePrompt = normalizedSunoExcludeStyles()
        let iterations = max(1, sunoCoverIterations)

        var runnableTargets: [(path: String, mixInfo: (url: URL, modifiedAt: Date))] = []
        for path in targetPaths {
            let baseTitle = Self.sunoBaseTitle(from: path)
            guard let mixInfo = sunoMixExportInfo(for: path) else {
                appendSunoLog("[\(baseTitle)] No Mix flat WAV found — skipping (export song to Mix first)", level: .error)
                continue
            }
            runnableTargets.append((path: path, mixInfo: mixInfo))
        }

        guard !runnableTargets.isEmpty else {
            sunoGenerateStatus = "No Mix exports found for the queued Suno cover submissions."
            appendSunoLog("No runnable Suno cover targets had a Mix export available", level: .error)
            return
        }

        sunoStopPreview()
        sunoIsGenerating = true
        defer { sunoIsGenerating = false }

        let totalSubmissions = runnableTargets.count * iterations
        var completedSubmissions = 0
        var successfulSubmissions = 0
        var totalWAVs = 0

        for (targetIndex, target) in runnableTargets.enumerated() {
            let path = target.path
            let mixInfo = target.mixInfo
            let baseTitle = Self.sunoBaseTitle(from: path)
            let outputRoot = ProjectPaths(root: projectRoot).suno

            for iteration in 1...iterations {
                completedSubmissions += 1
                let version = nextSunoVersion(
                    for: baseTitle,
                    mixExportURL: mixInfo.url,
                    outputRoot: outputRoot
                )
                let submissionTitle = String(format: "%@ v%03d", baseTitle, version)

                let generation = SunoGeneration(
                    songPath: path,
                    baseTitle: baseTitle,
                    version: version,
                    coverTitle: submissionTitle,
                    submissionIndex: iteration,
                    submissionCount: iterations,
                    prompt: prompt,
                    style: prompt,
                    excludeStyles: negativePrompt,
                    lyrics: lyrics,
                    status: .submitting
                )
                sunoGenerations.insert(generation, at: 0)
                let generationID = generation.id

                sunoGenerateStatus = "[\(baseTitle)] Submitting cover \(completedSubmissions)/\(totalSubmissions) (song \(targetIndex + 1)/\(runnableTargets.count), iteration \(iteration)/\(iterations))..."
                appendSunoLog("[\(baseTitle)] Iteration \(iteration)/\(iterations) submitting from Mix WAV: \(mixInfo.url.lastPathComponent)")

                do {
                    let result = try await sunoCLI.generateCover(
                        source: mixInfo.url.path,
                        style: prompt,
                        title: submissionTitle,
                        lyrics: lyrics,
                        excludeStyles: negativePrompt,
                        weirdness: sunoCoverWeirdness,
                        styleInfluence: sunoCoverStyleInfluence,
                        audioInfluence: sunoCoverAudioInfluence,
                        headless: false,
                        wait: true
                    )

                    let primarySongIDs = sunoDeduplicateSongIDs(result.songIDs)
                    let fallbackSongIDs = sunoDeduplicateSongIDs(result.allCapturedSongIDs)
                    let capturedSongIDs = primarySongIDs.count >= 2 ? primarySongIDs : fallbackSongIDs
                    guard capturedSongIDs.count >= 2 else {
                        throw SunoCLIError.runtime(message: "Suno returned \(capturedSongIDs.count) cover song ID(s) for \(submissionTitle); expected 2.")
                    }
                    let resolvedTitle = result.title ?? submissionTitle

                    updateSunoGeneration(
                        generationID,
                        status: .downloading,
                        songIDs: capturedSongIDs,
                        coverTitle: resolvedTitle,
                        resultMessage: result.message,
                        trackID: capturedSongIDs.first
                    )
                    appendSunoLog("[\(baseTitle)] Captured \(capturedSongIDs.count) output IDs for \(resolvedTitle): \(capturedSongIDs.joined(separator: ", "))", level: .success)

                    sunoGenerateStatus = "[\(baseTitle)] Downloading \(capturedSongIDs.count) WAV output(s)..."
                    appendSunoLog("[\(baseTitle)] Downloading \(capturedSongIDs.count) WAV(s) into \(outputRoot.path)")

                    var downloadedPaths: [String] = []
                    for songID in capturedSongIDs {
                        let download = try await sunoCLI.downloadSong(songID: songID, format: "wav", out: outputRoot.path)
                        downloadedPaths.append(download.path)
                    }

                    for wavPath in downloadedPaths {
                        NotificationCenter.default.post(
                            name: ScoreStore.didExportSongToMix,
                            object: nil,
                            userInfo: [
                                "wavURL": URL(fileURLWithPath: wavPath),
                                "songRelativePath": path
                            ]
                        )
                    }

                    updateSunoGeneration(
                        generationID,
                        status: .downloaded,
                        songIDs: capturedSongIDs,
                        coverTitle: resolvedTitle,
                        downloadedFilePaths: downloadedPaths,
                        downloadedFilePath: downloadedPaths.first,
                        trackID: capturedSongIDs.first
                    )
                    appendSunoLog("[\(baseTitle)] Finished iteration \(iteration)/\(iterations) — \(downloadedPaths.count) WAV(s) downloaded", level: .success)
                    successfulSubmissions += 1
                    totalWAVs += downloadedPaths.count
                } catch {
                    updateSunoGeneration(generationID, status: .error, errorMessage: error.localizedDescription)
                    appendSunoLog("[\(baseTitle)] Iteration \(iteration)/\(iterations) failed: \(error.localizedDescription)", level: .error)
                }

                let remainingSubmissions = totalSubmissions - completedSubmissions
                guard remainingSubmissions > 0 else { continue }

                let delaySeconds = nextSunoQueueDelaySeconds()
                let delayDescription = formattedSunoQueueDelay(seconds: delaySeconds)
                sunoGenerateStatus = "Queue cooldown: waiting \(delayDescription) before the next Suno submit (\(remainingSubmissions) remaining)."
                appendSunoLog("Queue cooldown: waiting \(delayDescription) before the next submit", level: .info)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                } catch {
                    appendSunoLog("Queue cooldown interrupted: \(error.localizedDescription)", level: .warning)
                    sunoGenerateStatus = "Queue interrupted: \(error.localizedDescription)"
                    return
                }
            }
        }

        sunoGenerateStatus = "Completed Suno cover queue: \(successfulSubmissions)/\(totalSubmissions) submits succeeded, \(totalWAVs) WAV(s) downloaded."
    }

    func sunoRevealGenerationDownloads(_ generationID: UUID) {
        guard let generation = sunoGenerations.first(where: { $0.id == generationID }) else { return }
        let paths = generation.resolvedDownloadedFilePaths
        guard !paths.isEmpty else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting(paths.map(URL.init(fileURLWithPath:)))
        #endif
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

    private func normalizedSunoExcludeStyles() -> String {
        let trimmed = sunoExcludeStyles.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "drums, percussion, cymbals, snare, kick"
        }
        let parts = trimmed.split(separator: ",").map {
            var token = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            while token.hasPrefix("-") {
                token.removeFirst()
                token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return token
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func nextSunoVersion(for baseTitle: String, mixExportURL: URL, outputRoot: URL) -> Int {
        let candidateDirectoryNames = Set([
            baseTitle,
            mixExportURL.deletingPathExtension().lastPathComponent
        ]).filter { !$0.isEmpty }

        var highest = 0
        for directoryName in candidateDirectoryNames {
            let songDirectory = outputRoot.appendingPathComponent(directoryName, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: songDirectory, includingPropertiesForKeys: nil)) ?? []
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
        }
        return highest + 1
    }

    private func sunoDeduplicateSongIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var deduped: [String] = []
        for id in ids {
            let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            deduped.append(normalized)
        }
        return deduped
    }

    private func nextSunoQueueDelaySeconds() -> Int {
        Int.random(in: Self.sunoCoverQueueDelayRangeSeconds)
    }

    private func formattedSunoQueueDelay(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if remainingSeconds == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainingSeconds)s"
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
