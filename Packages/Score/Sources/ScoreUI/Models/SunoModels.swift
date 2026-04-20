import Foundation

// MARK: - Suno Generation Tracking

/// Status of a locally-tracked Suno generation.
enum SunoGenerationStatus: String {
    case exporting
    case submitting
    case polling
    case generating    // suno_generate_track in progress
    case submitted     // request accepted in Suno, waiting/manual follow-up
    case ready         // generation complete, can download
    case downloading   // suno_download_track in progress
    case downloaded    // file saved locally
    case error

    var title: String {
        switch self {
        case .exporting: return "Exporting"
        case .submitting: return "Submitting"
        case .polling: return "Waiting"
        case .generating: return "Generating"
        case .submitted: return "Submitted"
        case .ready: return "Ready"
        case .downloading: return "Downloading"
        case .downloaded: return "Downloaded"
        case .error: return "Error"
        }
    }
}

enum SunoCoverPreset: String, Codable, CaseIterable, Identifiable {
    case orchestralInstrumental
    case orchestralVocal
    case chamberInstrumental
    case chamberVocal
    case chamberHybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orchestralInstrumental:
            return "Orchestral Instrumental"
        case .orchestralVocal:
            return "Orchestral Vocal"
        case .chamberInstrumental:
            return "Chamber Instrumental"
        case .chamberVocal:
            return "Chamber Vocal"
        case .chamberHybrid:
            return "Chamber Hybrid"
        }
    }

    var prompt: String {
        switch self {
        case .orchestralInstrumental:
            return "orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
        case .orchestralVocal:
            return "orchestra, classical voice, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
        case .chamberInstrumental:
            return "chamber music, adagio for strings, lyrical woodwinds, instrumental, same tempo, same structure, restrained dynamics"
        case .chamberVocal:
            return "chamber music, adagio for strings, lyrical woodwinds, classical voice, same tempo, same structure, restrained dynamics"
        case .chamberHybrid:
            return "chamber music, orchestra, adagio for strings, lyrical woodwinds, classical voice, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
        }
    }

    var requiresLyrics: Bool {
        switch self {
        case .orchestralInstrumental, .chamberInstrumental:
            return false
        case .orchestralVocal, .chamberVocal, .chamberHybrid:
            return true
        }
    }

    var isVocal: Bool {
        requiresLyrics
    }
}

enum SunoRequestMode: String, Codable, CaseIterable, Identifiable {
    case cover
    case originalSong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cover: return "Cover"
        case .originalSong: return "Original Song"
        }
    }
}

/// A locally-tracked Suno generation result.
/// Unlike the old REST-based SunoTrack, this model is managed entirely
/// client-side since suno-mcp returns string results, not structured JSON.
struct SunoGeneration: Identifiable {
    let id: UUID
    var songPath: String?
    var trackID: String?
    var songIDs: [String]
    var baseTitle: String?
    var version: Int?
    var coverTitle: String?
    var prompt: String
    var style: String?
    var excludeStyles: String?
    var lyrics: String?
    var status: SunoGenerationStatus
    var resultMessage: String?       // Raw response string from suno-mcp
    var downloadedFilePath: String?  // Local file path after download
    var downloadedFilePaths: [String]
    var errorMessage: String?
    var createdAt: Date

    init(
        songPath: String? = nil,
        trackID: String? = nil,
        songIDs: [String] = [],
        baseTitle: String? = nil,
        version: Int? = nil,
        coverTitle: String? = nil,
        prompt: String,
        style: String? = nil,
        excludeStyles: String? = nil,
        lyrics: String? = nil,
        status: SunoGenerationStatus = .generating,
        resultMessage: String? = nil,
        downloadedFilePath: String? = nil,
        downloadedFilePaths: [String] = [],
        errorMessage: String? = nil
    ) {
        self.id = UUID()
        self.songPath = songPath
        self.trackID = trackID
        self.songIDs = songIDs
        self.baseTitle = baseTitle
        self.version = version
        self.coverTitle = coverTitle
        self.prompt = prompt
        self.style = style
        self.excludeStyles = excludeStyles
        self.lyrics = lyrics
        self.status = status
        self.resultMessage = resultMessage
        self.downloadedFilePath = downloadedFilePath
        self.downloadedFilePaths = downloadedFilePaths
        self.errorMessage = errorMessage
        self.createdAt = Date()
    }

    /// Whether this generation is still in progress.
    var isProcessing: Bool {
        switch status {
        case .exporting, .submitting, .polling, .generating, .downloading:
            return true
        case .submitted, .ready, .downloaded, .error:
            return false
        }
    }

    /// Whether the track is ready for download.
    var isReady: Bool {
        status == .ready && (!songIDs.isEmpty || trackID != nil)
    }

    /// Whether the track has been downloaded locally.
    var isDownloaded: Bool {
        status == .downloaded
    }

    /// Whether generation or download failed.
    var isFailed: Bool {
        status == .error
    }

    var canDownload: Bool {
        isReady
    }

    var resolvedSongIDs: [String] {
        if !songIDs.isEmpty { return songIDs }
        if let trackID { return [trackID] }
        return []
    }

    var resolvedDownloadedFilePaths: [String] {
        if !downloadedFilePaths.isEmpty { return downloadedFilePaths }
        if let downloadedFilePath { return [downloadedFilePath] }
        return []
    }

    /// Short display title: first ~40 chars of prompt.
    var displayTitle: String {
        if let coverTitle, !coverTitle.isEmpty {
            return coverTitle
        }
        if let baseTitle, let version {
            return String(format: "%@ v%03d", baseTitle, version)
        }
        let text = prompt.prefix(40)
        return text.count < prompt.count ? "\(text)..." : String(text)
    }
}

