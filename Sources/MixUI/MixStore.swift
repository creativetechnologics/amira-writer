import AppKit
import Foundation
import Observation
@preconcurrency import AVFoundation
import ProjectKit
import QuartzCore

@available(macOS 26.0, *)
struct MixSceneSummary: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var relativePath: String
    var title: String
    var orderIndex: Int
    var updatedAt: Date
    var lengthTicks: Int
    var noteCount: Int

    init(
        id: UUID,
        relativePath: String,
        title: String,
        orderIndex: Int,
        updatedAt: Date,
        lengthTicks: Int,
        noteCount: Int
    ) {
        self.id = id
        self.relativePath = relativePath
        self.title = title
        self.orderIndex = orderIndex
        self.updatedAt = updatedAt
        self.lengthTicks = lengthTicks
        self.noteCount = noteCount
    }

    init(summary: NPSceneSummary) {
        id = summary.id
        relativePath = summary.relativePath
        title = summary.title
        orderIndex = summary.orderIndex
        updatedAt = summary.updatedAt
        lengthTicks = summary.lengthTicks
        noteCount = summary.noteCount
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var stemSafeName: String {
        let raw = displayTitle.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "_")).isEmpty ? "Untitled" : raw
    }

    /// Last two path components of the relative path. Shows enough context to be useful
    /// without filling the sidebar row with deeply-nested path strings.
    var shortRelativePath: String {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count > 2 else { return relativePath }
        return components.suffix(2).joined(separator: "/")
    }
}

@available(macOS 26.0, *)
struct MixTrack: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var accentHex: String
    var volumeDB: Double
    var pan: Double
    var isMuted: Bool
    var isSolo: Bool
    var isRecordArmed: Bool
    var inputName: String?
    var fxChainNames: [String]
    var notes: String
    var volumeAutomation: [MixAutomationPoint]

    init(
        id: UUID = UUID(),
        name: String,
        accentHex: String,
        volumeDB: Double = 0,
        pan: Double = 0,
        isMuted: Bool = false,
        isSolo: Bool = false,
        isRecordArmed: Bool = false,
        inputName: String? = nil,
        fxChainNames: [String] = [],
        notes: String = "",
        volumeAutomation: [MixAutomationPoint] = []
    ) {
        self.id = id
        self.name = name
        self.accentHex = accentHex
        self.volumeDB = volumeDB
        self.pan = pan
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.isRecordArmed = isRecordArmed
        self.inputName = inputName
        self.fxChainNames = fxChainNames
        self.notes = notes
        self.volumeAutomation = volumeAutomation
    }

    // Custom decoder provides backwards-compatible defaults for fields added after
    // the initial schema so that older saved documents load without keyNotFound crashes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        accentHex = (try? c.decodeIfPresent(String.self, forKey: .accentHex)) ?? "#76B041"
        volumeDB = (try? c.decodeIfPresent(Double.self, forKey: .volumeDB)) ?? 0
        pan = (try? c.decodeIfPresent(Double.self, forKey: .pan)) ?? 0
        isMuted = (try? c.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? false
        isSolo = (try? c.decodeIfPresent(Bool.self, forKey: .isSolo)) ?? false
        isRecordArmed = (try? c.decodeIfPresent(Bool.self, forKey: .isRecordArmed)) ?? false
        inputName = try? c.decodeIfPresent(String.self, forKey: .inputName)
        fxChainNames = (try? c.decodeIfPresent([String].self, forKey: .fxChainNames)) ?? []
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        volumeAutomation = (try? c.decodeIfPresent([MixAutomationPoint].self, forKey: .volumeAutomation)) ?? []
    }
}

@available(macOS 26.0, *)
struct MixAutomationPoint: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timeSeconds: Double
    var value: Double

    init(id: UUID = UUID(), timeSeconds: Double, value: Double) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.value = value
    }
}

@available(macOS 26.0, *)
struct MixClip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var trackID: UUID
    var name: String
    var filePath: String
    var sourceGroup: String
    var startSeconds: Double
    var sourceDurationSeconds: Double
    var sourceInSeconds: Double
    var durationSeconds: Double
    var colorHex: String
    var gainDB: Double
    var fadeInSeconds: Double
    var fadeOutSeconds: Double
    var isRecordedTake: Bool

    init(
        id: UUID = UUID(),
        trackID: UUID,
        name: String,
        filePath: String,
        sourceGroup: String,
        startSeconds: Double,
        sourceDurationSeconds: Double,
        sourceInSeconds: Double = 0,
        durationSeconds: Double,
        colorHex: String,
        gainDB: Double = 0,
        fadeInSeconds: Double = 0.08,
        fadeOutSeconds: Double = 0.08,
        isRecordedTake: Bool = false
    ) {
        self.id = id
        self.trackID = trackID
        self.name = name
        self.filePath = filePath
        self.sourceGroup = sourceGroup
        self.startSeconds = startSeconds
        self.sourceDurationSeconds = sourceDurationSeconds
        self.sourceInSeconds = sourceInSeconds
        self.durationSeconds = durationSeconds
        self.colorHex = colorHex
        self.gainDB = gainDB
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.isRecordedTake = isRecordedTake
    }

    // Custom decoder provides backwards-compatible defaults for fields added after
    // the initial schema (e.g. isRecordedTake, sourceInSeconds) so that loading an
    // older saved document does not crash with a keyNotFound error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        trackID = try c.decode(UUID.self, forKey: .trackID)
        name = try c.decode(String.self, forKey: .name)
        filePath = try c.decode(String.self, forKey: .filePath)
        sourceGroup = (try? c.decodeIfPresent(String.self, forKey: .sourceGroup)) ?? "Project"
        startSeconds = try c.decode(Double.self, forKey: .startSeconds)
        sourceDurationSeconds = try c.decode(Double.self, forKey: .sourceDurationSeconds)
        sourceInSeconds = (try? c.decodeIfPresent(Double.self, forKey: .sourceInSeconds)) ?? 0
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        colorHex = (try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? "#76B041"
        gainDB = (try? c.decodeIfPresent(Double.self, forKey: .gainDB)) ?? 0
        fadeInSeconds = (try? c.decodeIfPresent(Double.self, forKey: .fadeInSeconds)) ?? 0.08
        fadeOutSeconds = (try? c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds)) ?? 0.08
        isRecordedTake = (try? c.decodeIfPresent(Bool.self, forKey: .isRecordedTake)) ?? false
    }
}

@available(macOS 26.0, *)
enum MixEditTool: String, CaseIterable, Identifiable, Sendable {
    case pointer
    case split
    case automation
    case fade

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .pointer:
            return "cursorarrow"
        case .split:
            return "scissors"
        case .automation:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .fade:
            return "chart.line.uptrend.xyaxis"
        }
    }

    var shortLabel: String {
        switch self {
        case .pointer:
            return "Move"
        case .split:
            return "Cut"
        case .automation:
            return "Auto"
        case .fade:
            return "Fade"
        }
    }
}

@available(macOS 26.0, *)
struct MixSceneSession: Codable, Hashable, Sendable {
    var sceneRelativePath: String
    var tracks: [MixTrack]
    var clips: [MixClip]
    var selectedTrackID: UUID?
    var selectedClipID: UUID?
    var zoomSecondsPerScreen: Double
    var notes: String
    var nextTrackOrdinal: Int
    var bpm: Double

    init(sceneRelativePath: String, tracks: [MixTrack], clips: [MixClip],
         selectedTrackID: UUID?, selectedClipID: UUID?,
         zoomSecondsPerScreen: Double, notes: String, nextTrackOrdinal: Int,
         bpm: Double = 120) {
        self.sceneRelativePath = sceneRelativePath
        self.tracks = tracks
        self.clips = clips
        self.selectedTrackID = selectedTrackID
        self.selectedClipID = selectedClipID
        self.zoomSecondsPerScreen = zoomSecondsPerScreen
        self.notes = notes
        self.nextTrackOrdinal = nextTrackOrdinal
        self.bpm = bpm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneRelativePath = try c.decode(String.self, forKey: .sceneRelativePath)
        // Decode tracks and clips per-element so that one corrupt entry does not wipe
        // the entire array — we skip bad entries and preserve the rest.
        if let allTracks = try? c.decodeIfPresent([MixTrack].self, forKey: .tracks) {
            tracks = allTracks
        } else if c.contains(.tracks),
                  var tracksContainer = try? c.nestedUnkeyedContainer(forKey: .tracks) {
            var recovered: [MixTrack] = []
            while !tracksContainer.isAtEnd {
                if let track = try? tracksContainer.decode(MixTrack.self) {
                    recovered.append(track)
                } else {
                    _ = try? tracksContainer.decode(EmptyDecodable.self)
                }
            }
            tracks = recovered
        } else {
            tracks = []
        }
        if let allClips = try? c.decodeIfPresent([MixClip].self, forKey: .clips) {
            clips = allClips
        } else if c.contains(.clips),
                  var clipsContainer = try? c.nestedUnkeyedContainer(forKey: .clips) {
            var recovered: [MixClip] = []
            while !clipsContainer.isAtEnd {
                if let clip = try? clipsContainer.decode(MixClip.self) {
                    recovered.append(clip)
                } else {
                    _ = try? clipsContainer.decode(EmptyDecodable.self)
                }
            }
            clips = recovered
        } else {
            clips = []
        }
        selectedTrackID = try? c.decodeIfPresent(UUID.self, forKey: .selectedTrackID)
        selectedClipID = try? c.decodeIfPresent(UUID.self, forKey: .selectedClipID)
        zoomSecondsPerScreen = (try? c.decodeIfPresent(Double.self, forKey: .zoomSecondsPerScreen)) ?? 26
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        nextTrackOrdinal = (try? c.decodeIfPresent(Int.self, forKey: .nextTrackOrdinal)) ?? 1
        bpm = (try? c.decodeIfPresent(Double.self, forKey: .bpm)) ?? 120
    }

    static func `default`(for scene: MixSceneSummary) -> MixSceneSession {
        return MixSceneSession(
            sceneRelativePath: scene.relativePath,
            tracks: [], clips: [],
            selectedTrackID: nil, selectedClipID: nil,
            zoomSecondsPerScreen: 26, notes: "", nextTrackOrdinal: 1
        )
    }
}

@available(macOS 26.0, *)
struct MixProjectDocument: Codable, Sendable {
    var schemaVersion: Int
    var lastSelectedScenePath: String?
    var sceneSessions: [String: MixSceneSession]

    init(schemaVersion: Int = 1, lastSelectedScenePath: String? = nil, sceneSessions: [String: MixSceneSession] = [:]) {
        self.schemaVersion = schemaVersion
        self.lastSelectedScenePath = lastSelectedScenePath
        self.sceneSessions = sceneSessions
    }

    // Custom decoder provides backwards-compatible defaults so that a document
    // saved by an older schema version (or a partially-written/corrupt file) does
    // not throw a keyNotFound crash on load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        lastSelectedScenePath = try? c.decodeIfPresent(String.self, forKey: .lastSelectedScenePath)

        // Decode scene sessions individually so that one corrupt session does not
        // cause the entire dictionary to fall back to empty — other scenes' work is preserved.
        if let rawSessions = try? c.decodeIfPresent([String: MixSceneSession].self, forKey: .sceneSessions) {
            sceneSessions = rawSessions
        } else if c.contains(.sceneSessions),
                  let sessionsContainer = try? c.nestedContainer(keyedBy: DynamicStringKey.self, forKey: .sceneSessions) {
            var recovered: [String: MixSceneSession] = [:]
            for key in sessionsContainer.allKeys {
                if let session = try? sessionsContainer.decode(MixSceneSession.self, forKey: key) {
                    recovered[key.stringValue] = session
                }
                // Silently skip corrupt sessions — they will be re-created empty by merge().
            }
            sceneSessions = recovered
        } else {
            sceneSessions = [:]
        }
    }
}

@available(macOS 26.0, *)
private struct MixSceneSelectionOverride {
    var trackID: UUID?
    var clipID: UUID?
    var hasTrackOverride = false
    var hasClipOverride = false
}

/// Dynamic coding key for decoding arbitrary string-keyed dictionaries.
private struct DynamicStringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Throwaway Decodable that accepts any JSON object — used to advance the decode cursor
/// past a corrupt element in an unkeyed container.  Track/clip elements are always objects,
/// so we consume them as a keyed container (discarding the values) to advance the cursor.
private struct EmptyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        // Try object first (tracks and clips are always JSON objects)
        if (try? decoder.container(keyedBy: DynamicStringKey.self)) != nil {
            return
        }
        // Fall back to single-value (scalar) to handle any other corrupt shapes.
        _ = try decoder.singleValueContainer()
    }
}

@available(macOS 26.0, *)
struct MixBrowserNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case root
        case folder
        case audio
    }

    var id: String { path }
    var name: String
    var path: String
    var kind: Kind
    var children: [MixBrowserNode]
    var fileSize: Int64?

    var isDirectory: Bool {
        kind != .audio
    }
}

@available(macOS 26.0, *)
struct MixPluginInfo: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturerName: String
    var formatLabel: String
    var hasCustomView: Bool
}

@available(macOS 26.0, *)
struct MixInputDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var uniqueID: String?
    var isConnected: Bool
}

@available(macOS 26.0, *)
enum MixMicrophonePermissionState: String, Sendable {
    case unknown
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// Thin NSObject wrapper for CADisplayLink callbacks — MixStore is not an NSObject
/// so it can't be a CADisplayLink target directly.
@available(macOS 26.0, *)
private final class MixDisplayLinkTarget: NSObject {
    var onFrame: (() -> Void)?

    @objc func displayLinkFired(_ link: CADisplayLink) {
        onFrame?()
    }
}

@available(macOS 26.0, *)
private final class MixPreviewDelegate: NSObject, AVAudioPlayerDelegate {
    var didFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        didFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        didFinish?()
    }
}

private struct MixDocumentLoadOutcome {
    let document: MixProjectDocument
    let warningMessage: String?
}

private struct MixSaveSnapshot {
    let generation: UInt64
    let projectURL: URL
    let document: MixProjectDocument
    let projectPath: String
}

/// Simple reference-type box for passing browser scan results across a DispatchQueue boundary.
/// Using a class (not actor) is intentional: it's written once on the scan queue before the
/// semaphore signals, then read on the wait queue after the signal — there is no concurrent access.
@available(macOS 26.0, *)
private final class MixBrowserScanBox: @unchecked Sendable {
    var nodes: [MixBrowserNode] = []
}

@available(macOS 26.0, *)
@MainActor
@Observable
final class MixStore {
    static let mixProjectFile = "Metadata/mix_session.json"
    private nonisolated static let legacyMixActorID = ProjectClientIdentity.actorID(for: "novotro-mix")
    private nonisolated static let mixActorID = ProjectClientIdentity.actorID(for: "mix")
    private nonisolated static let mixActorIDs: Set<String> = [mixActorID, legacyMixActorID]
    nonisolated private static let audioExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf", "flac"]
    nonisolated private static let minimumTimelinePixelsPerSecond = 12.0
    nonisolated private static let maximumTimelinePixelsPerSecond = 48.0

    var projectURL: URL?
    var workingProjectURL: URL?
    var projectTitle: String = "Untitled Opera"
    var scenes: [MixSceneSummary] = []
    var selectedSceneID: UUID?
    var showInspector = true
    var statusMessage = "Open a project to start a mix session."
    var saveIndicator: SaveIndicatorState = .idle
    var browserSearchText = ""
    var selectedBrowserPath: String?
    var browserRoots: [MixBrowserNode] = []
    var availablePlugins: [MixPluginInfo] = []
    var inputDevices: [MixInputDevice] = []
    var microphonePermission: MixMicrophonePermissionState = .unknown
    var isRefreshingBrowser = false
    var isScanningPlugins = false
    var isScanningInputs = false
    var previewingPath: String?
    var selectedTool: MixEditTool = .pointer
    var playheadSeconds: Double = 0
    var isPlaying = false
    var isRecording = false
    var toolbarAvailableWidth: Double = 1000
    let waveformCache = MixWaveformCache()

    // Snap-to-grid (0 = disabled)
    var snapSeconds: Double = 0

    /// Track ID of the lane currently containing a dragged clip — used by the
    /// arrangement view to elevate that lane's zIndex so the clip renders above
    /// adjacent lanes during cross-track drag.
    var draggingClipTrackID: UUID? = nil

    // Drag-over preview ghost clip
    var dropPreviewTime: Double? = nil
    var dropPreviewTrackID: UUID? = nil
    var dropPreviewName: String? = nil
    var dropPreviewFilePath: String? = nil
    var dropPreviewDurationSeconds: Double? = nil
    var cachedDropURLs: [URL] = []
    @ObservationIgnored private var dropPreviewGeneration: UInt64 = 0

    // Undo / redo stacks (observable so toolbar buttons enable/disable)
    var undoStack: [MixSceneSession] = []
    var redoStack: [MixSceneSession] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private static let maxUndoDepth = 50

    @ObservationIgnored private var loadedProjectPath: String?
    @ObservationIgnored private var document = MixProjectDocument()
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?
    @ObservationIgnored private var activeSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveGeneration: UInt64 = 0
    @ObservationIgnored private var projectLoadGeneration: UInt64 = 0
    @ObservationIgnored private var browserRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pluginScanTask: Task<Void, Never>?
    @ObservationIgnored private var previewPlayer: AVAudioPlayer?
    @ObservationIgnored private var transportPlayers: [UUID: AVAudioPlayer] = [:]
    @ObservationIgnored private var transportStopWorkItems: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var transportDisplayLink: CADisplayLink?
    @ObservationIgnored private var transportFallbackTimer: Timer?
    @ObservationIgnored private let displayLinkTarget = MixDisplayLinkTarget()
    @ObservationIgnored private var transportStartedAt: Date?
    @ObservationIgnored private var transportStartedPlayheadSeconds: Double = 0
    /// Debounce work-item for ruler-drag scrubbing — coalesces rapid seekPlayhead calls
    /// into a single playback restart to avoid creating one AVAudioPlayer set per frame.
    @ObservationIgnored private var seekRestartWorkItem: DispatchWorkItem?
    @ObservationIgnored private var activeRecorder: AVAudioRecorder?
    @ObservationIgnored private var activeRecordingURL: URL?
    @ObservationIgnored private var activeRecordingTrackID: UUID?
    @ObservationIgnored private var activeRecordingStartSeconds: Double = 0
    @ObservationIgnored private let previewDelegate = MixPreviewDelegate()
    @ObservationIgnored private var pendingCorruptDocumentBackup: Data?
    @ObservationIgnored private var pendingCorruptDocumentBackupPath: String?
    @ObservationIgnored private var pendingCorruptDocumentBackupProjectPath: String?
    @ObservationIgnored private var stickyProjectWarning: String?
    @ObservationIgnored private var backgroundStartupTask: Task<Void, Never>?
    private var selectionOverrides: [String: MixSceneSelectionOverride] = [:]

    init() {
        previewDelegate.didFinish = { [weak self] in
            Task { @MainActor in
                self?.handlePreviewFinished()
            }
        }
    }

    var visibleBrowserRoots: [MixBrowserNode] {
        let query = browserSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return browserRoots }
        return filterBrowserNodes(browserRoots, query: query)
    }

    var selectedScene: MixSceneSummary? {
        guard let selectedSceneID else { return scenes.first }
        if let match = scenes.first(where: { $0.id == selectedSceneID }) {
            return match
        }
        // The previously-selected scene no longer exists (deleted or renamed).
        // Return the fallback without mutating selectedSceneID in the getter —
        // mutating a stored property inside a computed getter corrupts
        // @Observable tracking (write during a read phase).
        return scenes.first
    }

    /// Call after modifying `scenes` to clean up a stale `selectedSceneID`.
    private func repairSelectedSceneID() {
        guard let selectedSceneID else { return }
        if !scenes.contains(where: { $0.id == selectedSceneID }) {
            self.selectedSceneID = scenes.first?.id
        }
    }

    var currentSession: MixSceneSession? {
        guard let selectedScene else { return nil }
        return document.sceneSessions[selectedScene.relativePath]
    }

    /// Access the session for any scene (for sidebar display purposes).
    func sessionForScene(_ scene: MixSceneSummary) -> MixSceneSession? {
        document.sceneSessions[scene.relativePath]
    }

    /// Returns relative paths of all scenes that have Mix sessions with at least one clip.
    func scenesWithClips() -> [String] {
        document.sceneSessions.compactMap { path, session in
            session.clips.isEmpty ? nil : path
        }
    }

    var currentTracks: [MixTrack] {
        currentSession?.tracks ?? []
    }

    var currentClips: [MixClip] {
        currentSession?.clips ?? []
    }

    var currentTrackCountText: String {
        "\(currentTracks.count) tracks"
    }

    var currentClipCountText: String {
        "\(currentClips.count) clips"
    }

    var currentTimelinePixelsPerSecond: Double {
        Self.clampedTimelinePixelsPerSecond(currentSession?.zoomSecondsPerScreen ?? 26)
    }

    var currentSelectedTrackID: UUID? {
        guard let session = currentSession else { return nil }
        if let override = selectionOverrides[selectedScene?.relativePath ?? ""],
           override.hasTrackOverride {
            if let trackID = override.trackID,
               session.tracks.contains(where: { $0.id == trackID }) {
                return trackID
            }
            return session.tracks.first?.id
        }
        let resolvedID = session.selectedTrackID ?? session.tracks.first?.id
        if let resolvedID,
           session.tracks.contains(where: { $0.id == resolvedID }) {
            return resolvedID
        }
        return session.tracks.first?.id
    }

    var currentSelectedClipID: UUID? {
        guard let session = currentSession else { return nil }
        if let override = selectionOverrides[selectedScene?.relativePath ?? ""],
           override.hasClipOverride {
            guard let clipID = override.clipID else { return nil }
            return session.clips.contains(where: { $0.id == clipID }) ? clipID : nil
        }
        guard let clipID = session.selectedClipID else { return nil }
        return session.clips.contains(where: { $0.id == clipID }) ? clipID : nil
    }

    var selectedTrack: MixTrack? {
        guard let session = currentSession else { return nil }
        let resolvedID = currentSelectedTrackID
        return session.tracks.first(where: { $0.id == resolvedID })
    }

    var selectedClip: MixClip? {
        guard let session = currentSession else { return nil }
        guard let clipID = currentSelectedClipID else { return nil }
        return session.clips.first(where: { $0.id == clipID })
    }

    var activeSceneDurationSeconds: Double {
        // Guard against NaN/Infinity or degenerate clip values before feeding the result
        // into the timeline renderer.  Clips with negative or non-finite start/duration
        // values would produce a nonsensical (or crash-causing) timeline width.
        let clipEnd = currentClips.compactMap { clip -> Double? in
            let end = clip.startSeconds + clip.durationSeconds
            return end.isFinite && end >= 0 ? end : nil
        }.max() ?? 0
        let minimumFromScene = Double(selectedScene?.lengthTicks ?? 0) / 80.0
        // Cap at 36000 seconds (10 hours) — prevents the ruler/lane Canvas from
        // iterating hundreds-of-thousands of steps and freezing the UI.
        return min(max(clipEnd + 8, minimumFromScene, 45), 36_000)
    }

    var selectedBrowserNode: MixBrowserNode? {
        guard let selectedBrowserPath else { return nil }
        return Self.findBrowserNode(in: browserRoots, path: selectedBrowserPath)
    }

    var selectedClipTrackName: String? {
        guard let trackID = selectedClip?.trackID else { return nil }
        return currentTracks.first(where: { $0.id == trackID })?.name
    }

    func suspendBackgroundWork() {
        backgroundStartupTask?.cancel()
        backgroundStartupTask = nil
        browserRefreshTask?.cancel()
        browserRefreshTask = nil
        isRefreshingBrowser = false
        pluginScanTask?.cancel()
        pluginScanTask = nil
        isScanningPlugins = false
        stopPreview()
        stopTransport()
    }

    func resumeBackgroundWork() {
        scheduleDeferredBackgroundWork()
    }

    func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        if loadedProjectPath == normalizedPath, self.projectURL?.standardizedFileURL.path == normalizedPath {
            resumeBackgroundWork()
            return nil
        }

        let requestID = beginProjectLoad()
        do {
            try await loadProject(url: normalizedURL, requestID: requestID)
            guard isCurrentProjectLoad(requestID) else { return nil }
            loadedProjectPath = normalizedPath
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard isCurrentProjectLoad(requestID) else { return nil }
            statusMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    func save() {
        persistNow()
    }

    func loadProject(url: URL, requestID: UInt64) async throws {
        let normalizedURL = url.standardizedFileURL
        if let existingProjectPath = projectURL?.standardizedFileURL.path,
           existingProjectPath != normalizedURL.path {
            await flushPendingSavesIfNeeded()
        }

        clearProjectScopedWarnings()
        try ensureCurrentProjectLoad(requestID)

        // Build scene summaries from OWP song files on disk
        let sceneSummaries = Self.discoverSongSummaries(in: normalizedURL)
        try ensureCurrentProjectLoad(requestID)

        let diskSummary = NPProjectSummary(
            id: UUID(),
            name: normalizedURL.deletingPathExtension().lastPathComponent,
            notes: "",
            createdAt: Date(),
            updatedAt: Date(),
            projectURL: normalizedURL,
            scenes: sceneSummaries
        )
        try ensureCurrentProjectLoad(requestID)
        let loadOutcome = loadStoredDocumentFromDisk(projectURL: normalizedURL)
        try ensureCurrentProjectLoad(requestID)

        projectURL = normalizedURL
        workingProjectURL = normalizedURL
        applyProjectSummary(
            diskSummary,
            document: loadOutcome.document,
            preferredSelectionPath: loadOutcome.document.lastSelectedScenePath
        )
        stickyProjectWarning = loadOutcome.warningMessage
        saveIndicator = .saved
        scheduleDeferredBackgroundWork()

        statusMessage = loadOutcome.warningMessage
            ?? "Loaded \(scenes.count) scene mix sessions from local project files."
    }

    /// Discover .ows song files on disk and build NPSceneSummary entries.
    private static func discoverSongSummaries(in projectURL: URL) -> [NPSceneSummary] {
        let fm = FileManager.default
        let songsDir = ProjectPaths(root: projectURL).songs
        guard fm.fileExists(atPath: songsDir.path) else { return [] }

        let enumerator = fm.enumerator(
            at: songsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var summaries: [NPSceneSummary] = []
        var index = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "ows" else { continue }
            // Skip SyncThing conflict files
            if fileURL.lastPathComponent.contains(".sync-conflict-") { continue }
            let relativePath = "Songs/" + fileURL.path.replacingOccurrences(
                of: songsDir.path + "/",
                with: ""
            )
            let displayName = fileURL.deletingPathExtension().lastPathComponent
            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            summaries.append(NPSceneSummary(
                id: UUID(),
                relativePath: relativePath,
                title: displayName,
                orderIndex: index,
                updatedAt: modDate,
                activeVersionID: nil,
                activeLyrics: "",
                noteCount: 0,
                lengthTicks: 0,
                animateTrackCount: 0,
                animateKeyframeCount: 0
            ))
            index += 1
        }

        let sorted = summaries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return sorted.enumerated().map { index, scene in
            var s = scene
            s.orderIndex = index
            return s
        }
    }

    func selectScene(_ sceneID: UUID) {
        guard selectedSceneID != sceneID else { return }
        stopPreview()
        stopTransport()
        clearDropPreview()
        selectedBrowserPath = nil
        // Clear per-scene undo/redo stacks — they hold session snapshots keyed to the
        // previous scene, so leaving them would corrupt undo history in the new scene.
        undoStack.removeAll()
        redoStack.removeAll()
        selectedSceneID = sceneID
        if let scene = selectedScene {
            document.lastSelectedScenePath = scene.relativePath
            ensureSceneSessionExists(scene)
            refreshBrowser()
        }
    }

    private func setSelectionOverride(
        trackID: UUID?,
        clipID: UUID?,
        hasTrackOverride: Bool = true,
        hasClipOverride: Bool = true
    ) {
        guard let scenePath = selectedScene?.relativePath else { return }
        var override = selectionOverrides[scenePath] ?? MixSceneSelectionOverride()
        if hasTrackOverride {
            override.trackID = trackID
            override.hasTrackOverride = true
        }
        if hasClipOverride {
            override.clipID = clipID
            override.hasClipOverride = true
        }
        selectionOverrides[scenePath] = override
    }

    private func clearSelectionOverride(for scenePath: String? = nil) {
        guard let scenePath = scenePath ?? selectedScene?.relativePath else { return }
        selectionOverrides.removeValue(forKey: scenePath)
    }

    @discardableResult
    func beginDropPreview(trackID: UUID?, time: Double, name: String) -> UInt64 {
        dropPreviewGeneration &+= 1
        dropPreviewTrackID = trackID
        dropPreviewTime = time
        dropPreviewName = name
        dropPreviewFilePath = nil
        dropPreviewDurationSeconds = nil
        cachedDropURLs = []
        return dropPreviewGeneration
    }

    func updateDropPreview(trackID: UUID?, time: Double) {
        dropPreviewTrackID = trackID
        dropPreviewTime = time
    }

    func resolveDropPreview(
        generation: UInt64,
        urls: [URL],
        durationSeconds: Double?
    ) {
        guard generation == dropPreviewGeneration else { return }
        cachedDropURLs = urls
        guard let firstURL = urls.first else {
            dropPreviewFilePath = nil
            dropPreviewDurationSeconds = nil
            return
        }
        dropPreviewFilePath = firstURL.path
        dropPreviewDurationSeconds = durationSeconds
        let displayName = firstURL.deletingPathExtension().lastPathComponent
        if !displayName.isEmpty {
            dropPreviewName = displayName
        }
        waveformCache.request(firstURL.path)
    }

    func clearDropPreview() {
        dropPreviewGeneration &+= 1
        dropPreviewTime = nil
        dropPreviewTrackID = nil
        dropPreviewName = nil
        dropPreviewFilePath = nil
        dropPreviewDurationSeconds = nil
        cachedDropURLs = []
    }

    func selectTrack(_ trackID: UUID, clearSelectedClip: Bool = false) {
        guard let session = currentSession else { return }
        let resolvedTrackID = session.tracks.contains(where: { $0.id == trackID })
            ? trackID
            : session.tracks.first?.id
        let currentClipTrackID = currentSelectedClipID.flatMap { clipID in
            session.clips.first(where: { $0.id == clipID })?.trackID
        }
        let shouldClearClip = clearSelectedClip || (currentClipTrackID != nil && currentClipTrackID != resolvedTrackID)
        let desiredClipID = shouldClearClip ? nil : currentSelectedClipID

        if currentSelectedTrackID == resolvedTrackID,
           currentSelectedClipID == desiredClipID {
            return
        }

        setSelectionOverride(trackID: resolvedTrackID, clipID: desiredClipID)
    }

    func selectClip(_ clipID: UUID?) {
        guard let session = currentSession else { return }
        let resolvedTrackID: UUID?
        if let clipID,
           let clip = session.clips.first(where: { $0.id == clipID }) {
            resolvedTrackID = clip.trackID
        } else {
            resolvedTrackID = currentSelectedTrackID ?? session.tracks.first?.id
        }

        if currentSelectedClipID == clipID,
           currentSelectedTrackID == resolvedTrackID {
            return
        }

        setSelectionOverride(trackID: resolvedTrackID, clipID: clipID)
    }

    func selectBrowserPath(_ path: String?) {
        selectedBrowserPath = path
    }

    // MARK: - Navigation

    /// Select the next clip on the currently selected track (by start time).
    /// Wraps around to the first clip after the last.  Also seeks the playhead to
    /// the selected clip's start so the user can immediately hear it.
    func selectNextClip() {
        guard let session = currentSession else { return }
        let trackID = currentSelectedTrackID ?? session.tracks.first?.id
        guard let trackID else { return }
        let trackClips = session.clips
            .filter { $0.trackID == trackID }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !trackClips.isEmpty else { return }
        let target: MixClip
        if let selectedClipID = currentSelectedClipID,
           let currentIndex = trackClips.firstIndex(where: { $0.id == selectedClipID }) {
            let nextIndex = (currentIndex + 1) % trackClips.count
            target = trackClips[nextIndex]
        } else {
            target = trackClips[0]
        }
        selectClip(target.id)
        seekToClip(target.id)
    }

    /// Select the previous clip on the currently selected track (by start time).
    /// Wraps around to the last clip before the first.
    func selectPreviousClip() {
        guard let session = currentSession else { return }
        let trackID = currentSelectedTrackID ?? session.tracks.first?.id
        guard let trackID else { return }
        let trackClips = session.clips
            .filter { $0.trackID == trackID }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !trackClips.isEmpty else { return }
        let target: MixClip
        if let selectedClipID = currentSelectedClipID,
           let currentIndex = trackClips.firstIndex(where: { $0.id == selectedClipID }) {
            let prevIndex = currentIndex > 0 ? currentIndex - 1 : trackClips.count - 1
            target = trackClips[prevIndex]
        } else {
            target = trackClips[trackClips.count - 1]
        }
        selectClip(target.id)
        seekToClip(target.id)
    }

    /// Move track selection to the next track below.
    func selectNextTrack() {
        guard let session = currentSession, !session.tracks.isEmpty else { return }
        if let selectedTrackID = currentSelectedTrackID,
           let currentIndex = session.tracks.firstIndex(where: { $0.id == selectedTrackID }) {
            let nextIndex = min(currentIndex + 1, session.tracks.count - 1)
            selectTrack(session.tracks[nextIndex].id, clearSelectedClip: true)
        } else {
            if let firstTrack = session.tracks.first {
                selectTrack(firstTrack.id, clearSelectedClip: true)
            }
        }
    }

    /// Move track selection to the previous track above.
    func selectPreviousTrack() {
        guard let session = currentSession, !session.tracks.isEmpty else { return }
        if let selectedTrackID = currentSelectedTrackID,
           let currentIndex = session.tracks.firstIndex(where: { $0.id == selectedTrackID }) {
            let prevIndex = max(currentIndex - 1, 0)
            selectTrack(session.tracks[prevIndex].id, clearSelectedClip: true)
        } else {
            if let firstTrack = session.tracks.first {
                selectTrack(firstTrack.id, clearSelectedClip: true)
            }
        }
    }

    /// Deselect the current clip without clearing track selection.
    func deselectClip() {
        selectClip(nil)
    }

    /// Split the currently selected clip at the playhead position.
    /// A no-op if no clip is selected or the playhead is outside the clip's bounds.
    func splitSelectedClipAtPlayhead() {
        guard let clipID = currentSelectedClipID else {
            statusMessage = "Select a clip before splitting."
            return
        }
        guard let clip = currentClips.first(where: { $0.id == clipID }) else { return }
        guard playheadSeconds > clip.startSeconds + 0.05,
              playheadSeconds < clip.startSeconds + clip.durationSeconds - 0.05 else {
            statusMessage = "Move the playhead inside the clip to split it."
            return
        }
        splitClip(clipID, at: playheadSeconds)
    }

    /// Seek the playhead to the start of the given clip.
    func seekToClip(_ clipID: UUID) {
        guard let clip = currentClips.first(where: { $0.id == clipID }) else { return }
        seekPlayhead(to: clip.startSeconds)
    }

    /// Adjust gain of the selected clip by the given dB delta, clamped to [-24, +12].
    func adjustSelectedClipGain(by delta: Double) {
        guard let clipID = currentSelectedClipID else { return }
        guard let clip = currentClips.first(where: { $0.id == clipID }) else { return }
        let newGain = min(max(clip.gainDB + delta, -24), 12)
        pushUndoSnapshot()
        updateClipGain(clipID, value: newGain)
        statusMessage = String(format: "Clip gain: %+.1f dB", newGain)
    }

    // MARK: - Snap & Undo

    /// Nudge step size: matches snap grid when active, otherwise 0.25s.
    var nudgeAmount: Double {
        snapSeconds > 0 ? snapSeconds : 0.25
    }

    /// Seconds per beat at the current session's BPM — used for beat-based snapping.
    var beatSnapSeconds: Double {
        let bpm = currentSession?.bpm ?? 120
        guard bpm > 0 else { return 0.5 }
        return 60.0 / bpm
    }

    func snapToGrid(_ seconds: Double, excludingClipID: UUID? = nil) -> Double {
        // Magnetic snap to nearby clip edges takes priority over grid snap.
        // This makes end-to-end Suno WAV assembly precise and intuitive.
        let edgeSnapped = snapToNearestClipEdge(seconds, excludingClipID: excludingClipID)
        if edgeSnapped != seconds { return edgeSnapped }

        guard snapSeconds > 0 else { return seconds }
        return (seconds / snapSeconds).rounded() * snapSeconds
    }

    /// Magnetic snap: if `seconds` is within a threshold of any clip start/end on the
    /// same track (or any track), snap to that edge. Threshold is adaptive to zoom level.
    func snapToNearestClipEdge(_ seconds: Double, excludingClipID: UUID? = nil) -> Double {
        guard let session = currentSession else { return seconds }
        // Threshold in seconds — adapts to zoom: tighter at high zoom, looser at low zoom.
        // At 26 px/sec (default zoom), threshold ≈ 0.25s ≈ 6.5 pixels.
        let pps = session.zoomSecondsPerScreen > 0 ? session.zoomSecondsPerScreen : 26
        let threshold = max(4.0 / pps, 0.05) // min 50ms, scales with zoom

        var bestEdge = seconds
        var bestDistance = threshold

        for clip in session.clips {
            if clip.id == excludingClipID { continue }
            let start = clip.startSeconds
            let end = start + clip.durationSeconds

            let distStart = abs(seconds - start)
            let distEnd = abs(seconds - end)

            if distStart < bestDistance {
                bestDistance = distStart
                bestEdge = start
            }
            if distEnd < bestDistance {
                bestDistance = distEnd
                bestEdge = end
            }
        }

        // Also snap clip end to edges: check if (seconds + selectedClip.duration) aligns
        if let selectedClipID = currentSelectedClipID,
           let selectedClip = session.clips.first(where: { $0.id == selectedClipID }),
           selectedClip.id != excludingClipID {
            let clipEnd = seconds + selectedClip.durationSeconds
            for clip in session.clips where clip.id != selectedClip.id {
                let start = clip.startSeconds
                let end = start + clip.durationSeconds
                let distToStart = abs(clipEnd - start)
                let distToEnd = abs(clipEnd - end)
                if distToStart < bestDistance {
                    bestDistance = distToStart
                    bestEdge = start - selectedClip.durationSeconds
                }
                if distToEnd < bestDistance {
                    bestDistance = distToEnd
                    bestEdge = end - selectedClip.durationSeconds
                }
            }
        }

        return bestEdge
    }

    func pushUndoSnapshot() {
        guard let session = currentSession else { return }
        if undoStack.count >= Self.maxUndoDepth { undoStack.removeFirst() }
        undoStack.append(session)
        redoStack.removeAll()
    }

    func undo() {
        guard let scene = selectedScene, let previous = undoStack.last else { return }
        let priorSelectedTrackID = currentSelectedTrackID
        let priorSelectedClipID = currentSelectedClipID
        if let current = document.sceneSessions[scene.relativePath] {
            if redoStack.count >= Self.maxUndoDepth { redoStack.removeFirst() }
            redoStack.append(current)
        }
        undoStack.removeLast()
        document.sceneSessions[scene.relativePath] = previous
        let restoredClipID = previous.clips.contains(where: { $0.id == priorSelectedClipID }) ? priorSelectedClipID : nil
        let restoredTrackID: UUID?
        if let restoredClipID,
           let restoredClip = previous.clips.first(where: { $0.id == restoredClipID }) {
            restoredTrackID = restoredClip.trackID
        } else if let priorSelectedTrackID,
                  previous.tracks.contains(where: { $0.id == priorSelectedTrackID }) {
            restoredTrackID = priorSelectedTrackID
        } else {
            restoredTrackID = previous.tracks.first?.id
        }
        setSelectionOverride(trackID: restoredTrackID, clipID: restoredClipID)
        scheduleSave()
        statusMessage = "Undo."
    }

    func redo() {
        guard let scene = selectedScene, let next = redoStack.last else { return }
        let priorSelectedTrackID = currentSelectedTrackID
        let priorSelectedClipID = currentSelectedClipID
        if let current = document.sceneSessions[scene.relativePath] {
            if undoStack.count >= Self.maxUndoDepth { undoStack.removeFirst() }
            undoStack.append(current)
        }
        redoStack.removeLast()
        document.sceneSessions[scene.relativePath] = next
        let restoredClipID = next.clips.contains(where: { $0.id == priorSelectedClipID }) ? priorSelectedClipID : nil
        let restoredTrackID: UUID?
        if let restoredClipID,
           let restoredClip = next.clips.first(where: { $0.id == restoredClipID }) {
            restoredTrackID = restoredClip.trackID
        } else if let priorSelectedTrackID,
                  next.tracks.contains(where: { $0.id == priorSelectedTrackID }) {
            restoredTrackID = priorSelectedTrackID
        } else {
            restoredTrackID = next.tracks.first?.id
        }
        setSelectionOverride(trackID: restoredTrackID, clipID: restoredClipID)
        scheduleSave()
        statusMessage = "Redo."
    }

    func deleteSelectedClip() {
        guard let clipID = currentSelectedClipID else { return }
        removeClip(clipID)
    }

    func browserAncestorPaths(for path: String) -> [String] {
        Self.findBrowserAncestorPaths(in: browserRoots, path: path) ?? []
    }

    @discardableResult
    func addTrack(named customName: String? = nil, armForRecording: Bool = false) -> UUID? {
        pushUndoSnapshot()
        let trackID = createTrack(named: customName, armForRecording: armForRecording)
        statusMessage = "Added \(selectedTrack?.name ?? "track")."
        return trackID
    }

    func removeTrack(_ trackID: UUID) {
        guard currentTracks.contains(where: { $0.id == trackID }) else {
            statusMessage = "There are no tracks to remove."
            return
        }
        pushUndoSnapshot()
        var resolvedTrackID: UUID?
        mutateCurrentSession { session in
            let removedIndex = session.tracks.firstIndex(where: { $0.id == trackID })

            session.tracks.removeAll { $0.id == trackID }
            session.clips.removeAll { $0.trackID == trackID }
            if let removedIndex, session.tracks.isEmpty == false {
                let targetIndex = min(removedIndex, session.tracks.count - 1)
                resolvedTrackID = session.tracks[targetIndex].id
            } else {
                resolvedTrackID = session.tracks.first?.id
            }
        }
        let selectedClipStillExists = currentSelectedClipID.flatMap { clipID in
            currentClips.contains(where: { $0.id == clipID }) ? clipID : nil
        }
        let selectedTrackStillExists = currentSelectedTrackID.flatMap { selectedTrackID in
            currentTracks.contains(where: { $0.id == selectedTrackID }) ? selectedTrackID : nil
        }
        let trackOverride = selectedClipStillExists.flatMap { clipID in
            currentClips.first(where: { $0.id == clipID })?.trackID
        } ?? selectedTrackStillExists ?? resolvedTrackID
        setSelectionOverride(trackID: trackOverride, clipID: selectedClipStillExists)
        statusMessage = "Removed track and its clips."
    }

    func updateTrackName(_ trackID: UUID, name: String) {
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            session.tracks[index].name = trimmed.isEmpty ? "Track \(index + 1)" : trimmed
        }
    }

    func updateTrackNotes(_ trackID: UUID, notes: String) {
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].notes = notes
        }
    }

    func updateTrackVolume(_ trackID: UUID, value: Double) {
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].volumeDB = min(max(value, -60), 12)
        }
    }

    func updateTrackPan(_ trackID: UUID, value: Double) {
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].pan = min(max(value, -1), 1)
        }
    }

    func toggleTrackMute(_ trackID: UUID) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].isMuted.toggle()
        }
    }

    func toggleTrackSolo(_ trackID: UUID) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].isSolo.toggle()
        }
    }

    func toggleTrackRecordArm(_ trackID: UUID) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].isRecordArmed.toggle()
        }
    }

    func setTrackInput(_ trackID: UUID, inputName: String?) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].inputName = inputName
        }
    }

    func assignPlugin(_ pluginName: String, to trackID: UUID) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            if session.tracks[index].fxChainNames.contains(pluginName) == false {
                session.tracks[index].fxChainNames.append(pluginName)
            }
        }
        statusMessage = "Queued \(pluginName) on \(selectedTrack?.name ?? "track")."
    }

    func removePlugin(_ pluginName: String, from trackID: UUID) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.tracks[index].fxChainNames.removeAll { $0 == pluginName }
        }
    }

    func updateSessionNotes(_ notes: String) {
        mutateCurrentSession { session in
            session.notes = notes
        }
    }

    func updateTimelinePixelsPerSecond(_ value: Double) {
        let clampedValue = Self.clampedTimelinePixelsPerSecond(value)
        guard abs(currentTimelinePixelsPerSecond - clampedValue) > 0.0001 else { return }
        mutateCurrentSession { session in
            session.zoomSecondsPerScreen = clampedValue
        }
    }

    func clips(for trackID: UUID) -> [MixClip] {
        currentClips.filter { $0.trackID == trackID }.sorted { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds {
                return lhs.startSeconds < rhs.startSeconds
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func updateClipName(_ clipID: UUID, name: String) {
        mutateClip(clipID) { clip in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let fallbackName = URL(fileURLWithPath: clip.filePath)
                    .deletingPathExtension()
                    .lastPathComponent
                clip.name = fallbackName.isEmpty ? clip.name : fallbackName
            } else {
                clip.name = trimmed
            }
        }
    }

    func updateClipStartSeconds(_ clipID: UUID, value: Double) {
        mutateClip(clipID) { clip in
            clip.startSeconds = max(0, value)
        }
    }

    func updateClipGain(_ clipID: UUID, value: Double) {
        mutateClip(clipID) { clip in
            clip.gainDB = min(max(value, -24), 12)
        }
    }

    func updateClipFadeIn(_ clipID: UUID, value: Double) {
        mutateClip(clipID) { clip in
            let maximumFadeIn = Self.maximumFadeSeconds(for: clip)
            clip.fadeInSeconds = min(max(value, 0), maximumFadeIn)
        }
        // Do NOT call autoCrossfadeAroundClip here — that resets any fade
        // above the 0.08s default back to 0.08s for non-overlapping clips,
        // which would immediately wipe the user's manual adjustment.
    }

    func updateClipFadeOut(_ clipID: UUID, value: Double) {
        mutateClip(clipID) { clip in
            let maximumFadeOut = Self.maximumFadeSeconds(for: clip)
            clip.fadeOutSeconds = min(max(value, 0), maximumFadeOut)
        }
        // Do NOT call autoCrossfadeAroundClip here — same reason as above.
    }

    func addClip(from fileURL: URL, to trackID: UUID, at startSeconds: Double) {
        addClips(from: [fileURL], to: trackID, startingAt: startSeconds)
    }

    /// Register a Score-exported WAV into the Mix session for the matching scene.
    /// Finds or creates a "Score Export" track in the scene session, then appends the clip.
    /// Called by OperaShellView in response to `ScoreStore.didExportSongToMix`.
    func registerScoreExport(wavURL: URL, songRelativePath: String) {
        // Find the scene whose relativePath matches the Score song's relativePath
        guard let scene = scenes.first(where: { $0.relativePath == songRelativePath }) else {
            NSLog("[Mix] registerScoreExport: no scene found for %@", songRelativePath)
            return
        }

        // Probe audio duration — required for MixClip
        guard let duration = Self.audioDurationSync(for: wavURL), duration > 0 else {
            NSLog("[Mix] registerScoreExport: could not read duration for %@", wavURL.path)
            return
        }

        // Ensure the session exists
        ensureSceneSessionExists(scene)
        guard var session = document.sceneSessions[scene.relativePath] else { return }

        // Find or create a "Score Export" track
        let trackName = "Score Export"
        let trackID: UUID
        if let existing = session.tracks.first(where: { $0.name == trackName }) {
            trackID = existing.id
        } else {
            let ordinal = max(session.nextTrackOrdinal, 1)
            let newTrack = MixTrack(
                name: trackName,
                accentHex: "#4A90D9"   // a blue accent to distinguish from recorded takes
            )
            session.tracks.append(newTrack)
            session.nextTrackOrdinal = ordinal + 1
            trackID = newTrack.id
        }

        // Compute start position: place after the last existing clip on this track
        let lastEnd = session.clips
            .filter { $0.trackID == trackID }
            .map { $0.startSeconds + $0.durationSeconds }
            .max() ?? 0
        let startSeconds = lastEnd > 0 ? lastEnd + 0.25 : 0

        // Remove any previously exported clip with the same file path on this track
        // so re-exporting replaces the old clip rather than duplicating it
        session.clips.removeAll { $0.trackID == trackID && $0.filePath == wavURL.path }

        let clip = MixClip(
            trackID: trackID,
            name: wavURL.deletingPathExtension().lastPathComponent,
            filePath: wavURL.path,
            sourceGroup: "Score",
            startSeconds: startSeconds,
            sourceDurationSeconds: duration,
            durationSeconds: duration,
            colorHex: "#4A90D9"
        )
        session.clips.append(clip)
        Self.repairSelection(in: &session)
        document.sceneSessions[scene.relativePath] = session
        scheduleSave()
        refreshBrowser()
        statusMessage = "Score export registered: \(clip.name) in \(scene.displayTitle)."
        NSLog("[Mix] Registered score export: %@ in scene %@", clip.name, scene.relativePath)
    }

    // MARK: - Audio flatten

    enum FlattenError: Error, LocalizedError {
        case noSession
        case noProjectURL

        var errorDescription: String? {
            switch self {
            case .noSession:     return "No Mix session found for this scene."
            case .noProjectURL:  return "Project URL is not set — load a project first."
            }
        }
    }

    /// Flatten all Mix clips for a scene into a single stereo WAV in <project>/Animate/audio/.
    /// - Parameters:
    ///   - scenePath:   The scene's relativePath key in `document.sceneSessions`.
    ///   - projectURL:  Project root URL (used to create the output directory and resolve relative clip paths).
    /// - Returns: URL of the written WAV file.
    func flattenSceneAudio(scenePath: String, projectURL: URL) async throws -> URL {
        guard let session = document.sceneSessions[scenePath] else {
            throw FlattenError.noSession
        }
        let outputDir = ProjectPaths(root: projectURL).animateAudio
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let slug = scenePath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".json", with: "")
        let outputURL = outputDir.appendingPathComponent("\(slug)-flat.wav")

        let service = MixAudioFlattenService()
        try await service.flatten(session: session, projectURL: projectURL, outputURL: outputURL)
        return outputURL
    }

    /// Import all audio files from a folder (recursively) onto the specified track,
    /// auto-sequenced end-to-end. Sorts files by name for deterministic order.
    /// Use this for batch-importing Suno WAV renders from a scene folder.
    func importFolder(_ folderURL: URL, to trackID: UUID, startAt: Double = 0) {
        Task { [weak self] in
            guard let self else { return }
            let audioURLs = await Self.scanFolderForAudio(folderURL)
            guard !audioURLs.isEmpty else {
                statusMessage = "No audio files found in \(folderURL.lastPathComponent)."
                return
            }
            statusMessage = "Importing \(audioURLs.count) audio file\(audioURLs.count == 1 ? "" : "s") from \(folderURL.lastPathComponent)…"
            await addClipsAsync(from: audioURLs, to: trackID, startingAt: startAt)
        }
    }

    /// Scan a folder recursively for audio files, returning them sorted by name.
    nonisolated private static func scanFolderForAudio(_ folderURL: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            Self.scanFolderForAudioSync(folderURL)
        }.value
    }

    /// Synchronous folder scan — called from a detached task to avoid async iterator issues.
    nonisolated private static func scanFolderForAudioSync(_ folderURL: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        while let item = enumerator.nextObject() {
            guard let fileURL = item as? URL else { continue }
            let ext = fileURL.pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                results.append(fileURL)
            }
        }
        // Sort by filename for deterministic order (usually numeric for Suno renders)
        results.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return results
    }

    /// Fire-and-forget entry point used by the UI (drop delegate, inspector "Add" button, etc.).
    /// Dispatches the AVAudioFile header reads to a background thread so the main thread
    /// never blocks on disk I/O.  Use `addClipsAsync` in async contexts (e.g. tests) if you
    /// need to `await` completion.
    func addClips(from fileURLs: [URL], to trackID: UUID, startingAt startSeconds: Double) {
        Task { [weak self] in
            await self?.addClipsAsync(from: fileURLs, to: trackID, startingAt: startSeconds)
        }
    }

    /// Async variant — awaitable from tests or other async contexts.
    /// Probes audio file durations on a detached background task, then applies all mutations
    /// back on the main actor.
    func addClipsAsync(from fileURLs: [URL], to trackID: UUID, startingAt startSeconds: Double) async {
        clearDropPreview()

        // Require an active scene before doing any work — dropping files with no scene
        // selected is a no-op rather than leaving the undo stack or track list in a
        // half-mutated state.
        guard selectedScene != nil else {
            statusMessage = "Select a scene before adding clips."
            return
        }

        statusMessage = "Reading \(fileURLs.count == 1 ? "audio file" : "\(fileURLs.count) audio files")…"

        // Capture values needed on the background thread before leaving @MainActor context.
        let capturedTrackID = trackID
        let capturedStartSeconds = max(startSeconds, 0)
        let capturedSelectedSceneRelPath = selectedScene?.relativePath

        // Validate files and compute durations off the main thread — AVAudioFile header
        // reads can block for 10s of ms on spinning disks or large files.
        let (validatedFiles, unreadableFiles): ([(url: URL, duration: Double)], [String]) =
            await Task.detached(priority: .userInitiated) {
                var validated: [(url: URL, duration: Double)] = []
                var unreadable: [String] = []
                for fileURL in fileURLs {
                    if let duration = Self.audioDurationSync(for: fileURL) {
                        validated.append((url: fileURL, duration: duration))
                    } else {
                        unreadable.append(fileURL.lastPathComponent)
                    }
                }
                return (validated, unreadable)
            }.value

        // Discard if the scene changed while we were reading audio files.
        guard selectedScene?.relativePath == capturedSelectedSceneRelPath else {
            statusMessage = "Add clips canceled because the scene changed."
            clearDropPreview()
            return
        }

        guard validatedFiles.isEmpty == false else {
            if unreadableFiles.count == 1 {
                let name = unreadableFiles[0]
                statusMessage = "\"\(name)\" is not a supported audio file. Accepted formats: WAV, AIFF, MP3, M4A, CAF, FLAC."
            } else if unreadableFiles.isEmpty == false {
                statusMessage = "\(unreadableFiles.count) files could not be added — they are not recognised audio formats."
            }
            clearDropPreview()
            return
        }

        // All files are valid — now resolve/create the target track and build clip models.
        let resolvedTrackID = ensureTrackForImport(preferred: capturedTrackID)
        var preparedClips: [MixClip] = []
        var cursor = capturedStartSeconds

        for entry in validatedFiles {
            let baseName = entry.url.deletingPathExtension().lastPathComponent
            preparedClips.append(
                MixClip(
                    trackID: resolvedTrackID,
                    name: baseName,
                    filePath: entry.url.path,
                    sourceGroup: Self.sourceGroupStatic(for: entry.url),
                    startSeconds: cursor,
                    sourceDurationSeconds: entry.duration,
                    durationSeconds: entry.duration,
                    colorHex: Self.colorHexStatic(for: entry.url)
                )
            )
            cursor += entry.duration + 0.25
        }

        pushUndoSnapshot()

        mutateCurrentSession { session in
            session.clips.append(contentsOf: preparedClips)
            // Resolve overlaps so new clips don't stack on top of existing ones
            if let firstID = preparedClips.first?.id {
                Self.resolveOverlaps(in: &session, trackID: resolvedTrackID, movedClipID: firstID)
            }
            Self.applyAutomaticCrossfades(in: &session, trackID: resolvedTrackID)
        }
        setSelectionOverride(trackID: resolvedTrackID, clipID: preparedClips.last?.id)

        if preparedClips.count == 1, let clip = preparedClips.first {
            statusMessage = "Added \(clip.name) to \(selectedTrack?.name ?? "track")."
        } else if unreadableFiles.isEmpty {
            statusMessage = "Added \(preparedClips.count) clips to \(selectedTrack?.name ?? "track")."
        } else {
            statusMessage = "Added \(preparedClips.count) clips and skipped \(unreadableFiles.count) unreadable files."
        }
        clearDropPreview()
    }

    func suggestedStartSeconds(for trackID: UUID) -> Double {
        let clips = clips(for: trackID)
        guard let latestEnd = clips.map({ $0.startSeconds + $0.durationSeconds }).max() else {
            return 0
        }
        return latestEnd + 0.25
    }

    func moveClip(_ clipID: UUID, to trackID: UUID, startSeconds: Double) {
        pushUndoSnapshot()
        let snappedStart = max(snapToGrid(startSeconds), 0)
        let resolvedTrackID = ensureTrackForImport(preferred: trackID)
        let priorTrackID = currentClips.first(where: { $0.id == clipID })?.trackID
        mutateCurrentSession { session in
            guard let index = session.clips.firstIndex(where: { $0.id == clipID }) else { return }
            session.clips[index].trackID = resolvedTrackID
            session.clips[index].startSeconds = snappedStart

            // Push later clips forward to prevent overlap (masonry style)
            Self.resolveOverlaps(in: &session, trackID: resolvedTrackID, movedClipID: clipID)
            Self.applyAutomaticCrossfades(in: &session, trackID: resolvedTrackID)
            if let priorTrackID, priorTrackID != resolvedTrackID {
                Self.applyAutomaticCrossfades(in: &session, trackID: priorTrackID)
            }
        }
        setSelectionOverride(trackID: resolvedTrackID, clipID: clipID)
    }

    /// Push clips forward so nothing overlaps the clip that was just moved/placed.
    private static func resolveOverlaps(in session: inout MixSceneSession, trackID: UUID, movedClipID: UUID) {
        // Sort clips on this track by start time
        let trackClipIndices = session.clips.enumerated()
            .filter { $0.element.trackID == trackID }
            .sorted { $0.element.startSeconds < $1.element.startSeconds }
            .map(\.offset)

        // Iterate pairs: ensure each clip starts after the previous one ends
        for i in 0..<max(trackClipIndices.count - 1, 0) {
            let currentIdx = trackClipIndices[i]
            let nextIdx = trackClipIndices[i + 1]
            let currentEnd = session.clips[currentIdx].startSeconds + session.clips[currentIdx].durationSeconds
            if session.clips[nextIdx].startSeconds < currentEnd {
                session.clips[nextIdx].startSeconds = currentEnd + 0.02
            }
        }
    }

    func trimClipLeading(_ clipID: UUID, deltaSeconds: Double) {
        pushUndoSnapshot()
        mutateClip(clipID) { clip in
            // Snap the proposed absolute start position, then derive the delta
            // from it. Calling snapToGrid on a relative delta produces wrong
            // results because snapToGrid snaps to absolute clip edges/grid lines.
            let snappedDelta: Double
            if snapSeconds > 0 {
                let proposedStart = clip.startSeconds + deltaSeconds
                let snappedStart = snapToGrid(proposedStart)
                snappedDelta = snappedStart - clip.startSeconds
            } else {
                snappedDelta = deltaSeconds
            }
            let maxDelta = max(clip.durationSeconds - 0.1, 0)
            let clampedDelta = min(max(snappedDelta, -clip.sourceInSeconds), maxDelta)
            clip.startSeconds = max(0, clip.startSeconds + clampedDelta)
            clip.sourceInSeconds = max(0, clip.sourceInSeconds + clampedDelta)
            clip.durationSeconds = max(0.1, clip.durationSeconds - clampedDelta)
            clip.fadeInSeconds = min(clip.fadeInSeconds, Self.maximumFadeSeconds(for: clip))
            clip.fadeOutSeconds = min(clip.fadeOutSeconds, Self.maximumFadeSeconds(for: clip))
        }
        autoCrossfadeAroundClip(clipID)
    }

    func trimClipTrailing(_ clipID: UUID, deltaSeconds: Double) {
        pushUndoSnapshot()
        mutateClip(clipID) { clip in
            let snappedDelta: Double
            if snapSeconds > 0 {
                let proposedEnd = clip.startSeconds + clip.durationSeconds + deltaSeconds
                let snappedEnd = snapToGrid(proposedEnd)
                snappedDelta = snappedEnd - (clip.startSeconds + clip.durationSeconds)
            } else {
                snappedDelta = deltaSeconds
            }
            let maxDuration = max(clip.sourceDurationSeconds - clip.sourceInSeconds, 0.1)
            clip.durationSeconds = min(max(clip.durationSeconds + snappedDelta, 0.1), maxDuration)
            clip.fadeInSeconds = min(clip.fadeInSeconds, Self.maximumFadeSeconds(for: clip))
            clip.fadeOutSeconds = min(clip.fadeOutSeconds, Self.maximumFadeSeconds(for: clip))
        }
        autoCrossfadeAroundClip(clipID)
    }

    func splitClip(_ clipID: UUID, at timelineSeconds: Double) {
        guard let clip = currentClips.first(where: { $0.id == clipID }) else {
            statusMessage = "Cannot split: clip not found."
            return
        }
        let snapped = snapToGrid(timelineSeconds)
        let splitTime = min(max(snapped, clip.startSeconds + 0.05), clip.startSeconds + clip.durationSeconds - 0.05)
        guard splitTime > clip.startSeconds, splitTime < clip.startSeconds + clip.durationSeconds else {
            statusMessage = "Cannot split: tap closer to the middle of the clip."
            return
        }
        pushUndoSnapshot()

        let leadingDuration = splitTime - clip.startSeconds
        let trailingDuration = clip.durationSeconds - leadingDuration
        // At the split point the trailing half starts fresh, so its fadeIn is reset to
        // the default.  The trailingClip MixClip init calculates maximumFadeSeconds using
        // trailingDuration, so build a temporary clip to get the right max before clamping.
        let trailingMaxFade = Self.maximumFadeSeconds(for: MixClip(
            trackID: clip.trackID, name: "", filePath: clip.filePath,
            sourceGroup: clip.sourceGroup, startSeconds: splitTime,
            sourceDurationSeconds: clip.sourceDurationSeconds,
            sourceInSeconds: clip.sourceInSeconds + leadingDuration,
            durationSeconds: trailingDuration, colorHex: clip.colorHex
        ))
        let trailingClip = MixClip(
            trackID: clip.trackID,
            name: "\(clip.name) B",
            filePath: clip.filePath,
            sourceGroup: clip.sourceGroup,
            startSeconds: splitTime,
            sourceDurationSeconds: clip.sourceDurationSeconds,
            sourceInSeconds: clip.sourceInSeconds + leadingDuration,
            durationSeconds: trailingDuration,
            colorHex: clip.colorHex,
            gainDB: clip.gainDB,
            fadeInSeconds: min(Self.defaultFadeSeconds, trailingMaxFade),
            fadeOutSeconds: min(clip.fadeOutSeconds, trailingMaxFade),
            isRecordedTake: clip.isRecordedTake
        )

        mutateCurrentSession { session in
            guard let index = session.clips.firstIndex(where: { $0.id == clipID }) else { return }
            session.clips[index].durationSeconds = leadingDuration
            session.clips[index].fadeInSeconds = min(session.clips[index].fadeInSeconds, Self.maximumFadeSeconds(for: session.clips[index]))
            session.clips[index].fadeOutSeconds = min(session.clips[index].fadeOutSeconds, Self.maximumFadeSeconds(for: session.clips[index]))
            session.clips.append(trailingClip)
            Self.applyAutomaticCrossfades(in: &session, trackID: clip.trackID)
        }
        setSelectionOverride(trackID: trailingClip.trackID, clipID: trailingClip.id)
        statusMessage = "Split \(clip.name)."
    }

    func nudgeClip(_ clipID: UUID, by delta: Double) {
        pushUndoSnapshot()
        let trackID = currentClips.first(where: { $0.id == clipID })?.trackID
        mutateCurrentSession { session in
            guard let index = session.clips.firstIndex(where: { $0.id == clipID }) else { return }
            let raw = session.clips[index].startSeconds + delta
            session.clips[index].startSeconds = max(0, snapToGrid(raw))
            if let trackID {
                Self.resolveOverlaps(in: &session, trackID: trackID, movedClipID: clipID)
                Self.applyAutomaticCrossfades(in: &session, trackID: trackID)
            }
        }
        let resolvedTrackID = currentClips.first(where: { $0.id == clipID })?.trackID ?? trackID
        setSelectionOverride(trackID: resolvedTrackID, clipID: clipID)
    }

    func removeClip(_ clipID: UUID) {
        let trackID = currentClips.first(where: { $0.id == clipID })?.trackID
        let removedWasSelected = currentSelectedClipID == clipID
        let fallbackTrackID = trackID ?? currentSelectedTrackID
        pushUndoSnapshot()
        mutateCurrentSession { session in
            session.clips.removeAll { $0.id == clipID }
            if let trackID {
                Self.applyAutomaticCrossfades(in: &session, trackID: trackID)
            }
        }
        if removedWasSelected {
            setSelectionOverride(trackID: fallbackTrackID, clipID: nil)
        }
        statusMessage = "Removed clip."
    }

    func duplicateClip(_ clipID: UUID) {
        guard let clip = currentClips.first(where: { $0.id == clipID }) else {
            statusMessage = "Cannot duplicate: clip not found."
            return
        }
        pushUndoSnapshot()
        let duplicate = MixClip(
            trackID: clip.trackID,
            name: "\(clip.name) Copy",
            filePath: clip.filePath,
            sourceGroup: clip.sourceGroup,
            startSeconds: clip.startSeconds + max(clip.durationSeconds + 0.25, 0.5),
            sourceDurationSeconds: clip.sourceDurationSeconds,
            sourceInSeconds: clip.sourceInSeconds,
            durationSeconds: clip.durationSeconds,
            colorHex: clip.colorHex,
            gainDB: clip.gainDB,
            fadeInSeconds: clip.fadeInSeconds,
            fadeOutSeconds: clip.fadeOutSeconds,
            isRecordedTake: clip.isRecordedTake
        )
        mutateCurrentSession { session in
            session.clips.append(duplicate)
            Self.resolveOverlaps(in: &session, trackID: duplicate.trackID, movedClipID: duplicate.id)
            Self.applyAutomaticCrossfades(in: &session, trackID: duplicate.trackID)
        }
        setSelectionOverride(trackID: duplicate.trackID, clipID: duplicate.id)
        statusMessage = "Duplicated \(clip.name)."
    }

    // MARK: - Suno WAV Assembly Helpers

    /// Re-sequence all clips on the given track in their current order, with a
    /// configurable gap between them.  Use negative overlap to create crossfades.
    /// E.g. `overlapSeconds: -0.5` creates 0.5s overlap between adjacent clips.
    func autoSequenceClips(on trackID: UUID, overlapSeconds: Double = 0, startAt: Double = 0) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            let trackClipIndices = session.clips.enumerated()
                .filter { $0.element.trackID == trackID }
                .sorted { $0.element.startSeconds < $1.element.startSeconds }
                .map(\.offset)
            guard !trackClipIndices.isEmpty else { return }

            var cursor = startAt
            for idx in trackClipIndices {
                session.clips[idx].startSeconds = max(cursor, 0)
                cursor = session.clips[idx].startSeconds + session.clips[idx].durationSeconds - overlapSeconds
            }
            Self.applyAutomaticCrossfades(in: &session, trackID: trackID)
        }
        statusMessage = "Sequenced \(currentClips.filter { $0.trackID == trackID }.count) clips on track."
    }

    /// Quick-join: butt-join the selected clip to the end of the previous clip
    /// on the same track (zero gap, no overlap).
    func joinSelectedClipToPrevious() {
        guard let session = currentSession,
              let clipID = currentSelectedClipID,
              let clip = session.clips.first(where: { $0.id == clipID }) else { return }
        let sameTrackClips = session.clips
            .filter { $0.trackID == clip.trackID && $0.startSeconds < clip.startSeconds }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard let previous = sameTrackClips.last else {
            statusMessage = "No previous clip to join to."
            return
        }
        let newStart = previous.startSeconds + previous.durationSeconds
        moveClip(clipID, to: clip.trackID, startSeconds: newStart)
        statusMessage = "Joined \(clip.name) to end of \(previous.name)."
    }

    /// Sort clips on the given track by filename, then re-sequence them end-to-end.
    /// Useful when Suno renders are numbered (01-intro.wav, 02-verse.wav, etc.).
    func sortClipsByName(on trackID: UUID) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            var trackClipIndices = session.clips.enumerated()
                .filter { $0.element.trackID == trackID }
                .map(\.offset)

            // Sort the indices by clip name
            trackClipIndices.sort {
                session.clips[$0].name.localizedStandardCompare(session.clips[$1].name) == .orderedAscending
            }

            // Re-sequence with the sorted order
            var cursor = 0.0
            for idx in trackClipIndices {
                session.clips[idx].startSeconds = cursor
                cursor += session.clips[idx].durationSeconds + 0.25
            }
            Self.applyAutomaticCrossfades(in: &session, trackID: trackID)
        }
        statusMessage = "Sorted clips by name on track."
    }

    /// Preview the transition between two adjacent clips — plays a 3-second window
    /// centered on their junction point.
    func previewTransitionAtPlayhead() {
        guard let session = currentSession else { return }
        let clips = session.clips
            .sorted { $0.startSeconds < $1.startSeconds }

        // Find the clip boundary closest to the playhead
        var bestJunction: Double? = nil
        var bestDistance = Double.infinity
        for clip in clips {
            let end = clip.startSeconds + clip.durationSeconds
            let distEnd = abs(end - playheadSeconds)
            let distStart = abs(clip.startSeconds - playheadSeconds)
            if distEnd < bestDistance { bestDistance = distEnd; bestJunction = end }
            if distStart < bestDistance { bestDistance = distStart; bestJunction = clip.startSeconds }
        }
        guard let junction = bestJunction else { return }
        let previewStart = max(junction - 1.5, 0)
        seekPlayhead(to: previewStart)
        if !isPlaying { togglePlayback() }
        statusMessage = String(format: "Previewing transition at %d:%02d", Int(junction) / 60, Int(junction) % 60)
    }

    func addVolumeAutomationPoint(to trackID: UUID, timeSeconds: Double, value: Double) {
        pushUndoSnapshot()
        mutateCurrentSession { session in
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            let point = MixAutomationPoint(timeSeconds: max(0, timeSeconds), value: min(max(value, 0), 1))
            session.tracks[index].volumeAutomation.append(point)
            session.tracks[index].volumeAutomation.sort { lhs, rhs in
                lhs.timeSeconds < rhs.timeSeconds
            }
        }
        // Preserve the current clip selection — automation edits shouldn't
        // deselect the clip the user is working with.
        setSelectionOverride(trackID: trackID, clipID: currentSelectedClipID)
    }

    /// Update an automation point's position.
    /// Pass `shouldAutosave: false` during live-drag to suppress per-frame save scheduling;
    /// call again with `shouldAutosave: true` from `onEnded` to commit the final value.
    func updateVolumeAutomationPoint(
        trackID: UUID,
        pointID: UUID,
        timeSeconds: Double,
        value: Double,
        shouldAutosave: Bool = true
    ) {
        mutateCurrentSession(shouldAutosave: shouldAutosave) { session in
            guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            guard let pointIndex = session.tracks[trackIndex].volumeAutomation.firstIndex(where: { $0.id == pointID }) else { return }
            session.tracks[trackIndex].volumeAutomation[pointIndex].timeSeconds = max(0, timeSeconds)
            session.tracks[trackIndex].volumeAutomation[pointIndex].value = min(max(value, 0), 1)
            session.tracks[trackIndex].volumeAutomation.sort { lhs, rhs in
                lhs.timeSeconds < rhs.timeSeconds
            }
        }
    }

    func targetTrackID(from trackID: UUID, laneDelta: Int) -> UUID {
        guard let currentIndex = currentTracks.firstIndex(where: { $0.id == trackID }) else {
            return trackID
        }
        let targetIndex = min(max(currentIndex + laneDelta, 0), currentTracks.count - 1)
        return currentTracks[targetIndex].id
    }

    func refreshBrowser() {
        let selectedScene = selectedScene
        let workingProjectURL = workingProjectURL
        let priorSelection = selectedBrowserPath
        let baselineStatusMessage = statusMessage
        browserRefreshTask?.cancel()
        isRefreshingBrowser = true

        let task = Task { [weak self, selectedScene, workingProjectURL, priorSelection, baselineStatusMessage] in
            let roots = await Self.scanBrowserRoots(
                selectedScene: selectedScene,
                workingProjectURL: workingProjectURL
            )
            guard let self else { return }
            // If this task was cancelled and a newer browser refresh task is already queued,
            // let the successor manage isRefreshingBrowser — don't touch shared state.
            if Task.isCancelled {
                // Only clear the loading flag if no successor task is still running;
                // otherwise the successor will clear it when it finishes.
                if self.browserRefreshTask == nil || self.browserRefreshTask?.isCancelled == true {
                    self.isRefreshingBrowser = false
                }
                return
            }
            self.browserRoots = roots
            if let priorSelection,
               Self.findBrowserNode(in: roots, path: priorSelection) != nil {
                self.selectedBrowserPath = priorSelection
            } else {
                self.selectedBrowserPath = nil
            }
            self.isRefreshingBrowser = false
            let browserStatus = self.stickyProjectWarning
                ?? (roots.isEmpty
                    ? "No desktop or project audio roots found yet. Drop renders into the project's suno folder or export a Suno render to populate the browser."
                    : "Indexed \(roots.count) audio roots for drag-and-drop.")
            if self.stickyProjectWarning != nil || self.statusMessage == baselineStatusMessage {
                self.statusMessage = browserStatus
            }
            // Only clear the task handle if it is still our own task — a newer refresh
            // may have already replaced it and we must not clobber that handle.
            if self.browserRefreshTask?.isCancelled == false {
                self.browserRefreshTask = nil
            }
        }
        browserRefreshTask = task
    }

    func filteredChildren(for node: MixBrowserNode) -> [MixBrowserNode] {
        let query = browserSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return node.children }
        return filterBrowserNodes(node.children, query: query)
    }

    func revealBrowserPath(_ path: String) {
        // Use lstat (same as pathExistsNoCloud) to avoid blocking the main thread on
        // iCloud-placeholder or network-mounted paths where FileManager.fileExists stalls.
        guard Self.pathExistsNoCloud(path) else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func previewAudio(at path: String) {
        guard previewingPath != path else {
            stopPreview()
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            stopPreview()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = previewDelegate
            player.prepareToPlay()
            player.play()
            previewPlayer = player
            previewingPath = path
            statusMessage = "Previewing \(url.lastPathComponent)."
        } catch {
            previewPlayer = nil
            previewingPath = nil
            statusMessage = "Could not preview \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewingPath = nil
    }

    func previewSelectedClip() {
        guard let clip = selectedClip else { return }
        previewAudio(at: clip.filePath)
    }

    func togglePlayback() {
        isPlaying ? pausePlayback() : startPlayback()
    }

    func startPlayback() {
        guard currentClips.isEmpty == false else {
            statusMessage = "Drop audio onto the timeline to play this mix."
            return
        }

        teardownTransport(resetPlayhead: false, updateStatus: false)

        let clipsToPlay = playableClips(startingAt: playheadSeconds)
        guard clipsToPlay.isEmpty == false else {
            statusMessage = "Nothing is scheduled after the current playhead."
            return
        }

        let warmup: TimeInterval = 0.12
        transportStartedAt = Date().addingTimeInterval(warmup)
        transportStartedPlayheadSeconds = playheadSeconds
        transportPlayers = [:]
        transportStopWorkItems = [:]

        // Limit simultaneous players to prevent the AVAudioPlayer initialisation loop
        // from stalling the main thread with too many file-header reads at once.
        // 64 concurrent players is well above any realistic DAW session need.
        let maxConcurrentPlayers = 64
        for clip in clipsToPlay.prefix(maxConcurrentPlayers) {
            let url = URL(fileURLWithPath: clip.filePath)
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = clipPlaybackVolume(for: clip)
                player.pan = Float(selectedTrackPan(for: clip.trackID))
                player.prepareToPlay()

                let clipOffset = max(playheadSeconds - clip.startSeconds, 0)
                player.currentTime = min(clip.sourceInSeconds + clipOffset, max(player.duration - 0.05, 0))
                let delay = max(clip.startSeconds - playheadSeconds, 0)
                let startTime = player.deviceCurrentTime + warmup + delay
                player.play(atTime: startTime)
                transportPlayers[clip.id] = player

                let remainingDuration = max(clip.durationSeconds - clipOffset, 0.05)
                let stopItem = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.transportPlayers[clip.id]?.stop()
                        self?.transportPlayers.removeValue(forKey: clip.id)
                    }
                }
                transportStopWorkItems[clip.id] = stopItem
                DispatchQueue.main.asyncAfter(deadline: .now() + warmup + delay + remainingDuration, execute: stopItem)
            } catch {
                statusMessage = "Could not play \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }

        isPlaying = true
        if isRecording == false {
            statusMessage = "Playing mix."
        }
        startTransportTimer()
    }

    func pausePlayback() {
        guard isPlaying else { return }
        updatePlayheadFromTransportClock()
        teardownTransport(resetPlayhead: false, updateStatus: false)
        statusMessage = "Paused at \(transportTimecode(playheadSeconds))."
    }

    func stopTransport() {
        stopRecordingIfNeeded(addClipToTimeline: true)
        teardownTransport(resetPlayhead: true, updateStatus: false)
        statusMessage = "Transport stopped."
    }

    func movePlayhead(by deltaSeconds: Double) {
        playheadSeconds = min(max(playheadSeconds + deltaSeconds, 0), activeSceneDurationSeconds)
        if isPlaying {
            startPlayback()
        }
    }

    func seekPlayhead(to seconds: Double) {
        playheadSeconds = min(max(seconds, 0), activeSceneDurationSeconds)
        guard isPlaying else { return }
        // Debounce rapid seeks (ruler drag scrubbing) so we only restart the
        // transport once the user pauses dragging, rather than creating a full
        // AVAudioPlayer set on every ruler-drag frame event.
        seekRestartWorkItem?.cancel()
        // Tear down immediately so the old players stop producing audio during
        // the debounce window — otherwise clips overlap at the old position.
        teardownTransport(resetPlayhead: false, updateStatus: false)
        let item = DispatchWorkItem { [weak self] in
            self?.startPlayback()
        }
        seekRestartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    func toggleRecording() {
        isRecording ? stopRecordingIfNeeded(addClipToTimeline: true) : startRecording()
    }

    func startRecording() {
        guard microphonePermission == .authorized else {
            statusMessage = microphonePermission == .notDetermined
                ? "Allow microphone access before recording."
                : "Microphone access is required for vocal recording."
            return
        }

        guard let trackID = activeRecordTrackID() else {
            statusMessage = "Select a scene before recording."
            return
        }

        let recordingURL: URL
        do {
            recordingURL = try makeRecordingURL(for: trackID)
        } catch {
            statusMessage = "Could not prepare a recording file: \(error.localizedDescription)"
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.prepareToRecord()
            recorder.record()
            activeRecorder = recorder
            activeRecordingURL = recordingURL
            activeRecordingTrackID = trackID
            activeRecordingStartSeconds = playheadSeconds
            isRecording = true
            statusMessage = "Recording vocal take to \(recordingURL.lastPathComponent)."
            if isPlaying == false {
                startPlayback()
            }
        } catch {
            statusMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInputDevices()
            }
        }
    }

    func refreshInputDevices() {
        guard !isScanningInputs else { return }
        isScanningInputs = true

        // AVCaptureDevice.authorizationStatus and DiscoverySession can block for tens of
        // milliseconds on first call — probe them on a detached background task, then hop
        // back to @MainActor via a separate Task to avoid sending self across a Sendable
        // boundary (Swift 6 requirement).
        Task.detached(priority: .userInitiated) {
            let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            let devices = discovery.devices

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch authStatus {
                case .authorized:
                    self.microphonePermission = .authorized
                case .denied:
                    self.microphonePermission = .denied
                case .restricted:
                    self.microphonePermission = .restricted
                case .notDetermined:
                    self.microphonePermission = .notDetermined
                @unknown default:
                    self.microphonePermission = .unknown
                }

                self.inputDevices = devices.map { device in
                    MixInputDevice(
                        id: device.uniqueID,
                        name: device.localizedName,
                        uniqueID: device.uniqueID,
                        isConnected: device.isConnected
                    )
                }.sorted { lhs, rhs in
                    lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                self.isScanningInputs = false
            }
        }
    }

    /// Returns the track ID to record into. Creates a new armed track if none is armed.
    /// Returns nil if no scene is selected (no track can be created).
    private func activeRecordTrackID() -> UUID? {
        if let selectedTrack, selectedTrack.isRecordArmed {
            return selectedTrack.id
        }
        if let armedTrack = currentTracks.first(where: \.isRecordArmed) {
            selectTrack(armedTrack.id)
            return armedTrack.id
        }
        return addTrack(named: nil, armForRecording: true)
    }

    private func makeRecordingURL(for trackID: UUID) throws -> URL {
        let rootURL = workingProjectURL ?? projectURL ?? FileManager.default.temporaryDirectory
        let sceneStem = selectedScene?.stemSafeName ?? "Untitled"
        let trackName = currentTracks.first(where: { $0.id == trackID })?.name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression) ?? "Track"
        let vocalsDirectory = rootURL
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent("Vocals", isDirectory: true)
            .appendingPathComponent(sceneStem, isDirectory: true)
        try FileManager.default.createDirectory(at: vocalsDirectory, withIntermediateDirectories: true)

        // Cap at 9999 takes to avoid an infinite loop if the directory fills up
        // or becomes unwritable. Beyond this limit we throw rather than hang.
        for takeIndex in 1...9999 {
            let filename = String(format: "%@-%@-Take-%04d.wav", sceneStem, trackName, takeIndex)
            let candidate = vocalsDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) == false {
                return candidate
            }
        }
        throw CocoaError(.fileWriteNoPermission, userInfo: [
            NSLocalizedDescriptionKey: "Could not find an available take filename after 9999 attempts. Please clean up old recordings."
        ])
    }

    private func stopRecordingIfNeeded(addClipToTimeline: Bool) {
        guard isRecording else { return }

        activeRecorder?.stop()
        let recordingURL = activeRecordingURL
        let recordingTrackID = activeRecordingTrackID
        let recordingStartSeconds = activeRecordingStartSeconds
        // Capture the scene path at the moment recording stops — the scene may
        // switch before the background duration probe returns, and the clip must
        // be added to the scene that was active during recording, not the new one.
        let recordingScenePath = selectedScene?.relativePath

        activeRecorder = nil
        activeRecordingURL = nil
        activeRecordingTrackID = nil
        isRecording = false

        guard addClipToTimeline,
              let recordingURL,
              let recordingTrackID,
              let recordingScenePath else { return }

        // Probe the recorded file duration on a background thread — AVAudioFile reads
        // can block on slow media and must not run on the main thread.  Hop back via a
        // separate @MainActor Task rather than MainActor.run to avoid sending self across
        // a Sendable boundary (Swift 6 requirement).
        Task.detached(priority: .userInitiated) {
            let exists = FileManager.default.fileExists(atPath: recordingURL.path)
            let recordedDuration = exists ? Self.audioDurationSync(for: recordingURL) : nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let recordedDuration, recordedDuration > 0.05 else {
                    // Clean up a near-empty take rather than leaving an empty file on disk.
                    try? FileManager.default.removeItem(at: recordingURL)
                    if !self.isPlaying {
                        self.statusMessage = "Recording was too short and was discarded."
                    }
                    return
                }

                // Ensure the target session still exists (scene might have been deleted).
                guard self.document.sceneSessions[recordingScenePath] != nil else {
                    self.statusMessage = "Recording saved to disk but scene was removed: \(recordingURL.lastPathComponent)."
                    return
                }

                // Resolve the track within the recording's original scene.
                let resolvedTrackID: UUID
                if self.document.sceneSessions[recordingScenePath]?.tracks.contains(where: { $0.id == recordingTrackID }) == true {
                    resolvedTrackID = recordingTrackID
                } else {
                    // Track was removed; fall back to first track or create one.
                    if let firstTrack = self.document.sceneSessions[recordingScenePath]?.tracks.first {
                        resolvedTrackID = firstTrack.id
                    } else {
                        // No tracks — add one to the recording's scene by temporarily
                        // switching context, creating the track, then restoring.
                        let priorSceneID = self.selectedSceneID
                        let targetScene = self.scenes.first(where: { $0.relativePath == recordingScenePath })
                        if let targetScene {
                            self.selectedSceneID = targetScene.id
                        }
                        let newID = self.createTrack(shouldAutosave: false) ?? UUID()
                        self.selectedSceneID = priorSceneID
                        resolvedTrackID = newID
                    }
                }

                let baseName = recordingURL.deletingPathExtension().lastPathComponent
                let clip = MixClip(
                    trackID: resolvedTrackID,
                    name: baseName,
                    filePath: recordingURL.path,
                    sourceGroup: "vocals",
                    startSeconds: max(recordingStartSeconds, 0),
                    sourceDurationSeconds: recordedDuration,
                    durationSeconds: recordedDuration,
                    colorHex: "#C0588E",
                    isRecordedTake: true
                )

                // Mutate the recording's original scene directly rather than going through
                // mutateCurrentSession (which targets the currently selected scene).
                self.pushUndoSnapshot()
                guard var session = self.document.sceneSessions[recordingScenePath] else { return }
                session.clips.append(clip)
                Self.resolveOverlaps(in: &session, trackID: resolvedTrackID, movedClipID: clip.id)
                Self.applyAutomaticCrossfades(in: &session, trackID: resolvedTrackID)
                self.document.sceneSessions[recordingScenePath] = session
                if self.selectedScene?.relativePath == recordingScenePath {
                    self.setSelectionOverride(trackID: resolvedTrackID, clipID: clip.id)
                }
                self.scheduleSave()
                self.statusMessage = "Recorded \(recordingURL.lastPathComponent)."
            }
        }
    }

    private func playableClips(startingAt playheadSeconds: Double) -> [MixClip] {
        let soloTrackIDs = Set(currentTracks.filter(\.isSolo).map(\.id))
        let allowedTrackIDs = Set(currentTracks.filter { track in
            soloTrackIDs.isEmpty ? !track.isMuted : soloTrackIDs.contains(track.id)
        }.map(\.id))
        return currentClips
            .filter { clip in
                allowedTrackIDs.contains(clip.trackID) && (clip.startSeconds + clip.durationSeconds) > playheadSeconds
            }
            .sorted { lhs, rhs in
                if lhs.startSeconds != rhs.startSeconds {
                    return lhs.startSeconds < rhs.startSeconds
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func clipPlaybackVolume(for clip: MixClip) -> Float {
        guard let track = currentTracks.first(where: { $0.id == clip.trackID }) else { return 0 }
        let totalDB = track.volumeDB + clip.gainDB
        // Guard against NaN/Infinity before converting to Float — pow() can produce
        // extremely large values for high dB inputs, and NaN propagates silently through Float.
        guard totalDB.isFinite else { return totalDB > 0 ? 1.0 : 0 }
        let linear = pow(10.0, totalDB / 20.0)
        return Float(max(min(linear, 1.0), 0))
    }

    private func selectedTrackPan(for trackID: UUID) -> Double {
        currentTracks.first(where: { $0.id == trackID })?.pan ?? 0
    }

    private func startTransportTimer() {
        transportDisplayLink?.invalidate()
        // CADisplayLink via NSScreen fires at the display's native refresh rate —
        // perfectly frame-synced playhead movement with zero jitter.
        // The old 50ms Timer (20 Hz) caused visibly choppy playhead updates.
        displayLinkTarget.onFrame = { [weak self] in
            self?.updatePlayheadFromTransportClock()
        }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else {
            // Fallback: if no screen is available, use a high-frequency Timer.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updatePlayheadFromTransportClock()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            transportFallbackTimer = timer
            return
        }
        let link = screen.displayLink(
            target: displayLinkTarget,
            selector: #selector(MixDisplayLinkTarget.displayLinkFired)
        )
        // Cap at 60 fps to avoid burning CPU on 120 Hz displays for a simple
        // playhead line — 60 Hz is perceptually smooth for timeline scrolling.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        transportDisplayLink = link
    }

    private func updatePlayheadFromTransportClock() {
        guard isPlaying else { return }
        guard let transportStartedAt else { return }
        let elapsed = max(Date().timeIntervalSince(transportStartedAt), 0)
        playheadSeconds = min(transportStartedPlayheadSeconds + elapsed, activeSceneDurationSeconds)
        if playheadSeconds >= activeSceneDurationSeconds {
            teardownTransport(resetPlayhead: false, updateStatus: false)
            statusMessage = "Reached end of mix."
        }
    }

    private func teardownTransport(resetPlayhead: Bool, updateStatus: Bool) {
        seekRestartWorkItem?.cancel()
        seekRestartWorkItem = nil
        transportDisplayLink?.invalidate()
        transportDisplayLink = nil
        transportFallbackTimer?.invalidate()
        transportFallbackTimer = nil
        displayLinkTarget.onFrame = nil
        transportStopWorkItems.values.forEach { $0.cancel() }
        transportStopWorkItems.removeAll()
        transportPlayers.values.forEach { $0.stop() }
        transportPlayers.removeAll()
        transportStartedAt = nil
        isPlaying = false
        if resetPlayhead {
            playheadSeconds = 0
        }
        if updateStatus {
            statusMessage = resetPlayhead ? "Transport stopped." : "Playback stopped."
        }
    }

    private func transportTimecode(_ seconds: Double) -> String {
        let totalHundredths = Int((max(seconds, 0) * 100).rounded())
        let minutes = totalHundredths / 6000
        let remainingSeconds = (totalHundredths / 100) % 60
        let hundredths = totalHundredths % 100
        // Use MM:SS.cc format (matching MixToolbarView) so status messages are
        // consistent with what is shown in the transport LCD.
        return String(format: "%02d:%02d.%02d", minutes, remainingSeconds, hundredths)
    }

    func scanPluginsIfNeeded() async {
        schedulePluginScanIfNeeded()
        await pluginScanTask?.value
    }

    func persistNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let snapshot = makeSaveSnapshot() else { return }
        saveIndicator = .saving
        let previousSaveTask = activeSaveTask
        activeSaveTask = Task { [snapshot] in
            await previousSaveTask?.value
            await performSave(snapshot)
            await MainActor.run {
                if self.saveGeneration == snapshot.generation {
                    self.activeSaveTask = nil
                }
            }
        }
    }

    func scheduleSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if projectURL != nil, saveIndicator != .saving {
            saveIndicator = .unsavedChanges
        }
    }

    private func mutateCurrentSession(
        shouldAutosave: Bool = true,
        _ update: (inout MixSceneSession) -> Void
    ) {
        guard let scene = selectedScene else { return }
        ensureSceneSessionExists(scene)
        guard var session = document.sceneSessions[scene.relativePath] else { return }
        update(&session)
        Self.repairSelection(in: &session)
        document.sceneSessions[scene.relativePath] = session
        if shouldAutosave {
            scheduleSave()
        }
    }

    private func mutateClip(_ clipID: UUID, _ update: (inout MixClip) -> Void) {
        var resolvedTrackID: UUID?
        mutateCurrentSession { session in
            guard let index = session.clips.firstIndex(where: { $0.id == clipID }) else { return }
            update(&session.clips[index])
            resolvedTrackID = session.clips[index].trackID
        }
        setSelectionOverride(trackID: resolvedTrackID, clipID: clipID)
    }

    @discardableResult
    private func createTrack(
        named customName: String? = nil,
        armForRecording: Bool = false,
        shouldAutosave: Bool = true
    ) -> UUID? {
        guard let scene = selectedScene else { return nil }
        ensureSceneSessionExists(scene)
        guard var session = document.sceneSessions[scene.relativePath] else { return nil }

        let ordinal = max(session.nextTrackOrdinal, 1)
        let fallbackName = armForRecording ? "Vocal Track \(ordinal)" : "Track \(ordinal)"
        let trimmedName = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = MixTrack(
            name: trimmedName?.isEmpty == false ? (trimmedName ?? fallbackName) : fallbackName,
            accentHex: MixStore.trackPalette[session.tracks.count % MixStore.trackPalette.count],
            isRecordArmed: armForRecording
        )

        session.tracks.append(track)
        session.nextTrackOrdinal = ordinal + 1
        document.sceneSessions[scene.relativePath] = session
        setSelectionOverride(trackID: track.id, clipID: nil)
        if shouldAutosave {
            scheduleSave()
        }
        return track.id
    }

    private func ensureTrackForImport(preferred trackID: UUID?) -> UUID {
        if let resolvedTrackID = resolvedTrackID(preferred: trackID) {
            return resolvedTrackID
        }
        return createTrack(shouldAutosave: false) ?? UUID()
    }

    private func autoCrossfadeAroundClip(_ clipID: UUID) {
        guard let clip = currentClips.first(where: { $0.id == clipID }) else { return }
        mutateCurrentSession { session in
            Self.applyAutomaticCrossfades(in: &session, trackID: clip.trackID)
        }
    }

    private func ensureSceneSessionExists(_ scene: MixSceneSummary) {
        if document.sceneSessions[scene.relativePath] == nil {
            document.sceneSessions[scene.relativePath] = .default(for: scene)
        }
    }

    private func resolvedTrackID(preferred trackID: UUID?) -> UUID? {
        if let trackID,
           currentTracks.contains(where: { $0.id == trackID }) {
            return trackID
        }
        if let selectedTrackID = selectedTrack?.id,
           currentTracks.contains(where: { $0.id == selectedTrackID }) {
            return selectedTrackID
        }
        return currentTracks.first?.id
    }

    private func loadStoredDocumentFromDisk(projectURL: URL) -> MixDocumentLoadOutcome {
        let fileURL = projectURL.appendingPathComponent(Self.mixProjectFile)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return MixDocumentLoadOutcome(document: MixProjectDocument(), warningMessage: nil)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return MixDocumentLoadOutcome(
                document: try decoder.decode(MixProjectDocument.self, from: data),
                warningMessage: nil
            )
        } catch {
            // Back up the corrupt file to disk
            let backupPath = Self.corruptBackupPath()
            let backupURL = projectURL.appendingPathComponent(backupPath)
            let backupDir = backupURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try? data.write(to: backupURL)
            return MixDocumentLoadOutcome(
                document: MixProjectDocument(),
                warningMessage: "Recovered from an unreadable mix session file. A backup copy was written to \(backupPath)."
            )
        }
    }

    private func merge(document: MixProjectDocument, with scenes: [MixSceneSummary]) -> MixProjectDocument {
        var merged = document
        let knownPaths = Set(scenes.map(\.relativePath))

        // Remove sessions for scenes that no longer exist in the project, but only
        // if the session has no tracks — sessions with work are preserved so that
        // temporarily-missing scenes don't lose their mix data.
        let orphanedPaths = Set(merged.sceneSessions.keys).subtracting(knownPaths)
        for path in orphanedPaths {
            if merged.sceneSessions[path]?.tracks.isEmpty == true {
                merged.sceneSessions.removeValue(forKey: path)
            }
        }

        for scene in scenes {
            if merged.sceneSessions[scene.relativePath] == nil {
                merged.sceneSessions[scene.relativePath] = .default(for: scene)
            } else if var session = merged.sceneSessions[scene.relativePath] {
                session.sceneRelativePath = scene.relativePath
                session.nextTrackOrdinal = max(session.nextTrackOrdinal, session.tracks.count + 1, 1)
                Self.repairSelection(in: &session)
                session.zoomSecondsPerScreen = Self.clampedTimelinePixelsPerSecond(session.zoomSecondsPerScreen)
                merged.sceneSessions[scene.relativePath] = session
            }
        }
        return merged
    }

    private func applyProjectSummary(
        _ summary: NPProjectSummary,
        document sourceDocument: MixProjectDocument,
        preferredSelectionPath: String?,
        clearClipSelection: Bool = true
    ) {
        let updatedScenes = summary.scenes.map(MixSceneSummary.init(summary:)).sorted {
            if $0.orderIndex != $1.orderIndex {
                return $0.orderIndex < $1.orderIndex
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        projectTitle = summary.name
        scenes = updatedScenes
        document = merge(document: sourceDocument, with: updatedScenes)

        let selectionPath = preferredSelectionPath ?? document.lastSelectedScenePath ?? updatedScenes.first?.relativePath
        selectedSceneID = updatedScenes.first(where: { $0.relativePath == selectionPath })?.id ?? updatedScenes.first?.id
        document.lastSelectedScenePath = selectedScene?.relativePath

        // On initial project load, clear any persisted clip selection so clips don't
        // appear highlighted before the user interacts with the timeline.  During live
        // External refreshes (clearClipSelection: false) preserve the selection so a
        // background scene refresh doesn't interrupt active editing.
        if clearClipSelection {
            selectionOverrides.removeAll()
            if var session = currentSession, session.selectedClipID != nil {
                session.selectedClipID = nil
                if let path = selectedScene?.relativePath {
                    document.sceneSessions[path] = session
                }
            }
        }
    }

    private func handlePreviewFinished() {
        previewPlayer = nil
        previewingPath = nil
    }

    private func beginProjectLoad() -> UInt64 {
        projectLoadGeneration &+= 1
        selectionOverrides.removeAll()
        backgroundStartupTask?.cancel()
        backgroundStartupTask = nil
        stopPreview()
        stopTransport()
        selectedBrowserPath = nil
        browserRefreshTask?.cancel()
        browserRefreshTask = nil
        isRefreshingBrowser = false
        pluginScanTask?.cancel()
        pluginScanTask = nil
        isScanningPlugins = false
        return projectLoadGeneration
    }

    private func scheduleDeferredBackgroundWork() {
        backgroundStartupTask?.cancel()
        backgroundStartupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.refreshBrowser()
            self.refreshInputDevices()
            self.schedulePluginScanIfNeeded()
        }
    }

    private func ensureCurrentProjectLoad(_ requestID: UInt64) throws {
        guard isCurrentProjectLoad(requestID) else {
            throw CancellationError()
        }
    }

    private func isCurrentProjectLoad(_ requestID: UInt64) -> Bool {
        projectLoadGeneration == requestID
    }

    private func clearProjectScopedWarnings() {
        stickyProjectWarning = nil
        pendingCorruptDocumentBackup = nil
        pendingCorruptDocumentBackupPath = nil
        pendingCorruptDocumentBackupProjectPath = nil
    }

    private func makeSaveSnapshot() -> MixSaveSnapshot? {
        guard let projectURL else { return nil }
        let projectPath = projectURL.standardizedFileURL.path

        if let selectedScene {
            document.lastSelectedScenePath = selectedScene.relativePath
        }
        saveGeneration &+= 1
        return MixSaveSnapshot(
            generation: saveGeneration,
            projectURL: projectURL,
            document: document,
            projectPath: projectPath
        )
    }

    private func performSave(_ snapshot: MixSaveSnapshot) async {
        do {
            let fileURL = snapshot.projectURL.appendingPathComponent(Self.mixProjectFile)
            let dirURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot.document)
            try data.write(to: fileURL, options: .atomic)

            await MainActor.run {
                if self.projectURL?.standardizedFileURL.path == snapshot.projectPath {
                    self.stickyProjectWarning = nil
                    self.pendingCorruptDocumentBackup = nil
                    self.pendingCorruptDocumentBackupPath = nil
                    self.pendingCorruptDocumentBackupProjectPath = nil
                }

                guard self.projectURL?.standardizedFileURL.path == snapshot.projectPath else { return }
                guard snapshot.generation == self.saveGeneration else {
                    self.saveIndicator = .saving
                    return
                }
                self.saveIndicator = .saved
            }
        } catch {
            await MainActor.run {
                guard self.projectURL?.standardizedFileURL.path == snapshot.projectPath else { return }
                guard snapshot.generation == self.saveGeneration else { return }
                self.saveIndicator = .unsavedChanges
                self.statusMessage = "Failed to save mix session: \(error.localizedDescription)"
            }
        }
    }

    private func flushPendingSavesIfNeeded() async {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        await activeSaveTask?.value
    }

    private func schedulePluginScanIfNeeded() {
        guard availablePlugins.isEmpty else { return }
        guard pluginScanTask == nil else { return }

        isScanningPlugins = true
        pluginScanTask = Task { [weak self] in
            let found = await Self.discoverPlugins()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.availablePlugins = found
                self.isScanningPlugins = false
                self.pluginScanTask = nil
            }
        }
    }

    nonisolated private static func corruptBackupPath(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Metadata/mix_session.corrupt-\(formatter.string(from: date)).json"
    }

    nonisolated private static func scanBrowserRoots(
        selectedScene: MixSceneSummary?,
        workingProjectURL: URL?
    ) async -> [MixBrowserNode] {
        // Project-local paths (in /tmp, on local volumes) scan near-instantly.
        // Desktop paths may be on network mounts or iCloud-synced volumes and can block
        // for seconds or indefinitely. We race the full scan against a 3-second timeout;
        // if it completes in time we return all roots, otherwise we fall back to project-only roots.
        let scanSemaphore = DispatchSemaphore(value: 0)
        let results = MixBrowserScanBox()
        DispatchQueue(label: "com.novotro.mix.browserScan", qos: .utility).async {
            results.nodes = Self.candidateBrowserRootsSync(
                selectedScene: selectedScene,
                workingProjectURL: workingProjectURL
            )
            scanSemaphore.signal()
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.novotro.mix.browserScanWait", qos: .utility).async {
                let completed = scanSemaphore.wait(timeout: .now() + 3) == .success
                if completed {
                    continuation.resume(returning: results.nodes)
                } else {
                    // Timed out — fall back to project-only roots which are always fast.
                    let fallback = workingProjectURL.map { Self.projectBrowserRootsSync(workingProjectURL: $0) } ?? []
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    /// Fully synchronous version of the browser scan — runs on a non-Swift-concurrency thread
    /// (DispatchQueue) so that slow filesystem operations don't block the cooperative thread pool.
    /// Scans project-local paths for browser roots.
    nonisolated private static func candidateBrowserRootsSync(
        selectedScene: MixSceneSummary?,
        workingProjectURL: URL?
    ) -> [MixBrowserNode] {
        let roots = candidateBrowserRoots(selectedScene: selectedScene, workingProjectURL: workingProjectURL)
        return roots.compactMap { root in
            buildBrowserNode(at: root, kind: .root, depth: 0)
        }
    }

    /// Fast scan of project-local paths only (no Desktop traversal) for use when speed matters.
    nonisolated private static func projectBrowserRootsSync(workingProjectURL: URL) -> [MixBrowserNode] {
        let projectCandidates = [
            ProjectPaths(root: workingProjectURL).suno,
            ProjectPaths(root: workingProjectURL).mixExports,
            ProjectPaths(root: workingProjectURL).mixes,
            workingProjectURL.appendingPathComponent("Renders", isDirectory: true),
            workingProjectURL.appendingPathComponent("Exports", isDirectory: true),
        ]
        var roots: [URL] = []
        for candidate in projectCandidates where pathExistsNoCloud(candidate.path) {
            roots.append(candidate.standardizedFileURL)
        }
        return roots.compactMap { buildBrowserNode(at: $0, kind: .root, depth: 0) }
    }

    nonisolated private static func candidateBrowserRoots(
        selectedScene: MixSceneSummary?,
        workingProjectURL: URL?
    ) -> [URL] {
        var roots: [URL] = []

        // Use project-local Exports directory instead of ~/Desktop to avoid
        // TCC permission prompts on macOS.
        if let projectURL = workingProjectURL {
            let projectExports = projectURL.appendingPathComponent("Exports", isDirectory: true)
            if Self.pathExistsNoCloud(projectExports.path) {
                roots.append(projectExports)
            }
        }

        if let workingProjectURL {
            let projectCandidates = [
                ProjectPaths(root: workingProjectURL).suno,
                ProjectPaths(root: workingProjectURL).mixExports,
                ProjectPaths(root: workingProjectURL).mixes,
                workingProjectURL.appendingPathComponent("Renders", isDirectory: true),
                workingProjectURL.appendingPathComponent("Exports", isDirectory: true),
            ]
            for candidate in projectCandidates where !Task.isCancelled && Self.pathExistsNoCloud(candidate.path) {
                roots.append(candidate)
            }
        }

        var deduped: [String: URL] = [:]
        for root in roots {
            deduped[root.standardizedFileURL.path] = root.standardizedFileURL
        }
        return deduped.values.sorted { $0.path < $1.path }
    }

    /// Non-blocking existence check using `lstat` to avoid triggering iCloud Drive downloads
    /// or stalling on network-mounted paths the way `FileManager.fileExists` can.
    nonisolated private static func pathExistsNoCloud(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    nonisolated private static func buildBrowserNode(at url: URL, kind: MixBrowserNode.Kind, depth: Int) -> MixBrowserNode? {
        let fm = FileManager.default
        // Use lstat to avoid triggering iCloud Drive downloads for placeholder files.
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR

        if isDirectory {
            let displayName: String
            if url.lastPathComponent.lowercased() == "exports" && url.deletingLastPathComponent().lastPathComponent == "Mix" {
                displayName = "Score"
            } else {
                displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            }
            guard depth < 6 else {
                return MixBrowserNode(name: displayName, path: url.path, kind: kind, children: [], fileSize: nil)
            }
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let children = contents.compactMap { childURL -> MixBrowserNode? in
                guard !Task.isCancelled else { return nil }
                let childKind: MixBrowserNode.Kind = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? .folder : .audio
                if childKind == .audio, Self.audioExtensions.contains(childURL.pathExtension.lowercased()) == false {
                    return nil
                }
                return buildBrowserNode(at: childURL, kind: childKind, depth: depth + 1)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            guard kind == .root || children.isEmpty == false else { return nil }
            return MixBrowserNode(
                name: displayName,
                path: url.path,
                kind: kind,
                children: children,
                fileSize: nil
            )
        }

        guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard Self.isBrowsableAudioFile(at: url, fileSize: size) else { return nil }
        return MixBrowserNode(
            name: url.lastPathComponent,
            path: url.path,
            kind: .audio,
            children: [],
            fileSize: size
        )
    }

    nonisolated private static func isBrowsableAudioFile(at url: URL, fileSize: Int64?) -> Bool {
        guard let fileSize else { return true }
        if url.pathExtension.lowercased() == "wav", fileSize > 0, fileSize <= 4096 {
            return false
        }
        return true
    }

    private func filterBrowserNodes(_ nodes: [MixBrowserNode], query: String) -> [MixBrowserNode] {
        nodes.compactMap { node in
            let matchesNode = node.name.localizedCaseInsensitiveContains(query)
                || node.path.localizedCaseInsensitiveContains(query)
            if matchesNode {
                // The folder/file itself matches — show it with all its children so
                // the user can see the full contents of a matching folder.
                return node
            }
            let filteredChildren = filterBrowserNodes(node.children, query: query)
            if filteredChildren.isEmpty == false {
                var copy = node
                copy.children = filteredChildren
                return copy
            }
            return nil
        }
    }

    nonisolated private static func findBrowserNode(in nodes: [MixBrowserNode], path: String) -> MixBrowserNode? {
        for node in nodes {
            if node.path == path {
                return node
            }
            if let match = findBrowserNode(in: node.children, path: path) {
                return match
            }
        }
        return nil
    }

    nonisolated private static func findBrowserAncestorPaths(in nodes: [MixBrowserNode], path: String) -> [String]? {
        for node in nodes {
            if node.path == path {
                return []
            }
            if let childMatch = findBrowserAncestorPaths(in: node.children, path: path) {
                return node.isDirectory ? [node.path] + childMatch : childMatch
            }
        }
        return nil
    }

    // NOTE: This is intentionally synchronous and must only be called from a
    // nonisolated/background context.  The two call sites — addClips and
    // stopRecordingIfNeeded — are wrapped in Task.detached so this never
    // blocks the main thread.
    private nonisolated static func audioDurationSync(for url: URL) -> Double? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let seconds = Double(audioFile.length) / sampleRate
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    nonisolated static func dropPreviewDuration(for url: URL) -> Double? {
        audioDurationSync(for: url)
    }

    private func sourceGroup(for fileURL: URL) -> String {
        Self.sourceGroupStatic(for: fileURL)
    }

    private nonisolated static func sourceGroupStatic(for fileURL: URL) -> String {
        let path = fileURL.path.lowercased()
        if path.contains("suno") { return "Suno" }
        if path.contains("preview") { return "Preview" }
        if path.contains("export") { return "Export" }
        return "Project"
    }

    private func colorHex(for fileURL: URL) -> String {
        Self.colorHexStatic(for: fileURL)
    }

    private nonisolated static func colorHexStatic(for fileURL: URL) -> String {
        let path = fileURL.path.lowercased()
        if path.contains("suno") { return "#5B9BD5" }
        if path.contains("preview") { return "#4A90E2" }
        if path.contains("export") { return "#39C0BA" }
        return "#6B8E6B"
    }

    private static func maximumFadeSeconds(for clip: MixClip) -> Double {
        min(max(clip.durationSeconds * 0.5, 0), 8)
    }

    private static let defaultFadeSeconds = 0.08

    private static func applyAutomaticCrossfades(in session: inout MixSceneSession, trackID: UUID) {
        // Build a sorted (by startSeconds) list of array indices for clips on this track.
        let sortedIndices = session.clips.enumerated()
            .filter { $0.element.trackID == trackID }
            .sorted { lhs, rhs in
                if lhs.element.startSeconds != rhs.element.startSeconds {
                    return lhs.element.startSeconds < rhs.element.startSeconds
                }
                return lhs.element.name.localizedStandardCompare(rhs.element.name) == .orderedAscending
            }
            .map(\.offset)

        guard sortedIndices.count >= 2 else { return }

        // Track which clips have received an auto-crossfade so we can reset fades that
        // were auto-set in a previous arrangement but are no longer appropriate.
        var autoCrossfadeIn: Set<Int> = []
        var autoCrossfadeOut: Set<Int> = []

        for pairIndex in 0..<(sortedIndices.count - 1) {
            let currentIndex = sortedIndices[pairIndex]
            let nextIndex = sortedIndices[pairIndex + 1]

            let currentClip = session.clips[currentIndex]
            let nextClip = session.clips[nextIndex]
            let overlap = (currentClip.startSeconds + currentClip.durationSeconds) - nextClip.startSeconds

            if overlap > 0 {
                let currentFade = min(overlap, maximumFadeSeconds(for: currentClip))
                let nextFade = min(overlap, maximumFadeSeconds(for: nextClip))
                session.clips[currentIndex].fadeOutSeconds = max(session.clips[currentIndex].fadeOutSeconds, currentFade)
                session.clips[nextIndex].fadeInSeconds = max(session.clips[nextIndex].fadeInSeconds, nextFade)
                autoCrossfadeOut.insert(currentIndex)
                autoCrossfadeIn.insert(nextIndex)
            }
        }

        // Reset fades that were auto-elevated to a crossfade value but the clips are no
        // longer overlapping.  Only reset down to the default — never below it, and never
        // below a value the user may have set manually (which we don't track, so we cap
        // at the default floor to avoid wiping intentional fades).
        for idx in sortedIndices {
            if autoCrossfadeOut.contains(idx) == false {
                let maxFade = maximumFadeSeconds(for: session.clips[idx])
                // Clamp: reset to the default unless the clip's fade is <= default already
                // or the fade was set so large it exceeds the maximum (trim happened).
                if session.clips[idx].fadeOutSeconds > defaultFadeSeconds {
                    session.clips[idx].fadeOutSeconds = min(defaultFadeSeconds, maxFade)
                }
            }
            if autoCrossfadeIn.contains(idx) == false {
                let maxFade = maximumFadeSeconds(for: session.clips[idx])
                if session.clips[idx].fadeInSeconds > defaultFadeSeconds {
                    session.clips[idx].fadeInSeconds = min(defaultFadeSeconds, maxFade)
                }
            }
        }
    }

    private static func clampedTimelinePixelsPerSecond(_ value: Double) -> Double {
        min(max(value, minimumTimelinePixelsPerSecond), maximumTimelinePixelsPerSecond)
    }

    private static func repairSelection(in session: inout MixSceneSession) {
        if let selectedClipID = session.selectedClipID,
           let clip = session.clips.first(where: { $0.id == selectedClipID }),
           session.tracks.contains(where: { $0.id == clip.trackID }) {
            session.selectedTrackID = clip.trackID
        } else {
            session.selectedClipID = nil
            if session.tracks.contains(where: { $0.id == session.selectedTrackID }) == false {
                session.selectedTrackID = session.tracks.first?.id
            }
        }
    }

    nonisolated private static func discoverPlugins() async -> [MixPluginInfo] {
        await Task.detached(priority: .utility) { () -> [MixPluginInfo] in
            let manager = AVAudioUnitComponentManager.shared()
            let types: [OSType] = [kAudioUnitType_MusicDevice, kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
            var results: [MixPluginInfo] = []
            var seen: Set<String> = []

            for type in types {
                let description = AudioComponentDescription(
                    componentType: type,
                    componentSubType: 0,
                    componentManufacturer: 0,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
                for component in manager.components(matching: description) {
                    let compDesc = component.audioComponentDescription
                    let identifier = "\(compDesc.componentType)-\(compDesc.componentSubType)-\(compDesc.componentManufacturer)"
                    guard seen.insert(identifier).inserted else { continue }
                    let label: String
                    switch compDesc.componentType {
                    case kAudioUnitType_Effect:
                        label = "Effect"
                    case kAudioUnitType_MusicEffect:
                        label = "Music FX"
                    case kAudioUnitType_MusicDevice:
                        label = "Instrument"
                    default:
                        label = "Audio Unit"
                    }
                    results.append(
                        MixPluginInfo(
                            id: identifier,
                            name: component.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            manufacturerName: component.manufacturerName.trimmingCharacters(in: .whitespacesAndNewlines),
                            formatLabel: label,
                            hasCustomView: component.hasCustomView
                        )
                    )
                }
            }

            return results.sorted { lhs, rhs in
                let manufacturerOrder = lhs.manufacturerName.localizedCaseInsensitiveCompare(rhs.manufacturerName)
                if manufacturerOrder != .orderedSame {
                    return manufacturerOrder == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }.value
    }

    static let trackPalette = [
        "#8C8C8C",
    ]
}
