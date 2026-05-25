import Foundation

// MARK: - API Response Wrappers

struct APIStatusResponse: Codable {
    var app: String
    var version: String
    var apiPort: UInt16
    var projectPath: String?
    var projectName: String?
    var selectedSongPath: String?
    var selectedSongTitle: String?
    var isPlaying: Bool
    var songCount: Int
}

struct APISongSummary: Codable {
    var id: String
    var relativePath: String
    var title: String
    var noteCount: Int
    var trackCount: Int
    var versionCount: Int
    var hasLyrics: Bool
}

struct APISongListResponse: Codable {
    var songs: [APISongSummary]
}

struct APINotesResponse: Codable {
    var notes: [PianoRollNote]
    var totalCount: Int
}

struct APITracksResponse: Codable {
    var tracks: [APITrackInfo]
}

struct APITrackInfo: Codable {
    var trackIndex: Int
    var name: String?
    var channels: [Int]
    var noteCount: Int
}

struct APIInstrumentsResponse: Codable {
    var mappings: [String: InstrumentMapping]
    var channelKeyMap: [String: String]
}

struct APITempoResponse: Codable {
    var tempoBPM: Double
    var ticksPerQuarter: Int
    var lengthTicks: Int
    var tempoEvents: [TempoPoint]
    var timeSignatures: [TimeSignatureEvent]
    var keySignatures: [KeySignatureEvent]
}

struct APILyricsResponse: Codable {
    var lyricCues: [LyricCue]
    var alignments: [LyricAlignment]
    var librettoText: String?
}

struct APIMarkersResponse: Codable {
    var markers: [MixMarker]
}

struct APIAudioClipsResponse: Codable {
    var clips: [AudioClip]
}

struct APIVersionsResponse: Codable {
    var versions: [APIVersionInfo]
    var activeVersionID: String?
}

struct APIVersionInfo: Codable {
    var id: String
    var label: String
    var userLabel: String?
    var saveType: String
    var isBookmarked: Bool
    var createdAt: Date
    var updatedAt: Date
}

struct APISoundfontsResponse: Codable {
    var entries: [APISoundfontEntry]
}

struct APISoundfontEntry: Codable {
    var relativePath: String
    var fileName: String
    var fileSize: Int64
}

// MARK: - Audio Unit Models

struct APIAudioUnitsResponse: Codable {
    var isScanning: Bool
    var audioUnits: [APIAudioUnitInfo]
}

struct APIAudioUnitInfo: Codable {
    var name: String
    var manufacturerName: String
    var componentType: UInt32
    var componentSubType: UInt32
    var manufacturer: UInt32
}

struct APISetAudioUnitRequest: Codable {
    var name: String
    var componentType: UInt32
    var componentSubType: UInt32
    var manufacturer: UInt32
    var mappingKeys: [String]
}

// MARK: - API Request Bodies

struct APIAddNotesRequest: Codable {
    var notes: [APINewNote]
}

struct APINewNote: Codable {
    var trackIndex: Int
    var channel: Int
    var pitch: Int
    var velocity: Int
    var startTick: Int
    var duration: Int
    var muted: Bool?
    var lyricSyllable: String?
}

struct APIDeleteNotesRequest: Codable {
    var noteIDs: [String]
}

struct APIUpdateNotesRequest: Codable {
    var updates: [APINotePatch]
}

struct APINotePatch: Codable {
    var id: String
    var trackIndex: Int?
    var channel: Int?
    var pitch: Int?
    var velocity: Int?
    var startTick: Int?
    var duration: Int?
    var muted: Bool?
    var lyricSyllable: String?
}

struct APIReplaceAllNotesRequest: Codable {
    var notes: [APINewNote]
}

struct APIRenameTrackRequest: Codable {
    var trackIndex: Int
    var name: String
}

struct APISetInstrumentRequest: Codable {
    var mappingKey: String
    var displayName: String?
    var sf2Path: String?
    var bankMSB: Int?
    var bankLSB: Int?
    var program: Int?
    var gainDB: Double?
    var muted: Bool?
    var trackRole: String?
}

struct APISetTempoRequest: Codable {
    var tempoEvents: [TempoPoint]?
    var initialTempoBPM: Double?
    var ticksPerQuarter: Int?
    var timeSignatures: [TimeSignatureEvent]?
    var keySignatures: [KeySignatureEvent]?
}

struct APISelectSongRequest: Codable {
    var index: Int?
    var relativePath: String?
}

struct APIPlaybackPlayRequest: Codable {
    var startTick: Int?
}

struct APIPlaybackSeekRequest: Codable {
    var tick: Int
}

struct APIExportWavRequest: Codable {
    var outputPath: String
    var startTick: Int?
    var endTick: Int?
    var overrideSF2Path: String?
}

struct APIExportRehearsalRequest: Codable {
    var outputPath: String
    var accompanimentAttenuationDB: Double?
}

struct APIAnnotationsResponse: Codable {
    var annotations: [ScoreAnnotation]
}

struct APIAddAnnotationRequest: Codable {
    var tick: Int
    var text: String
    var kind: String?  // "dynamic", "tempo", "expression", "rehearsal"
    var trackIndex: Int?
}

struct APIDeleteAnnotationRequest: Codable {
    var annotationID: String
}

struct APIExportStemsRequest: Codable {
    var outputDir: String
}

struct APIOpenProjectRequest: Codable {
    var path: String
}

struct APISnapshotVersionRequest: Codable {
    var label: String?
}

struct APIRollbackVersionRequest: Codable {
    var versionID: String
}

struct APIDeleteVersionRequest: Codable {
    var versionID: String
}

struct APIRenameVersionRequest: Codable {
    var versionID: String
    var newLabel: String
}

// MARK: - Track Mixer Requests

struct APITrackMuteRequest: Codable {
    var trackIndex: Int
}

struct APITrackSoloRequest: Codable {
    var trackIndex: Int
}

struct APITrackPanRequest: Codable {
    var mappingKey: String
    var pan: Double
}

struct APIMasterVolumeRequest: Codable {
    var volume: Double
}

struct APIDeleteSongRequest: Codable {
    var songID: String
}

struct APISetContinuousPlayRequest: Codable {
    var enabled: Bool
}

struct APISetLoopRequest: Codable {
    var enabled: Bool
    var regionStartTick: Int?
    var regionEndTick: Int?
    var clearRegion: Bool?
}

// MARK: - Generic Success Response

struct APISuccessResponse: Codable {
    var ok: Bool = true
    var message: String?

    init(_ message: String? = nil) {
        self.message = message
    }
}

struct APINoteIDsResponse: Codable {
    var ok: Bool = true
    var noteIDs: [String]
}
