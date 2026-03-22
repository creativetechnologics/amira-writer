import Foundation

// MARK: - Suno Generation Tracking

/// Status of a locally-tracked Suno generation.
enum SunoGenerationStatus: String {
    case generating    // suno_generate_track in progress
    case submitted     // request accepted in Suno, waiting/manual follow-up
    case ready         // generation complete, can download
    case downloading   // suno_download_track in progress
    case downloaded    // file saved locally
    case error

    var title: String {
        switch self {
        case .generating: return "Generating"
        case .submitted: return "Submitted"
        case .ready: return "Ready"
        case .downloading: return "Downloading"
        case .downloaded: return "Downloaded"
        case .error: return "Error"
        }
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
    var prompt: String
    var style: String?
    var excludeStyles: String?
    var lyrics: String?
    var status: SunoGenerationStatus
    var resultMessage: String?       // Raw response string from suno-mcp
    var downloadedFilePath: String?  // Local file path after download
    var errorMessage: String?
    var createdAt: Date

    init(
        songPath: String? = nil,
        trackID: String? = nil,
        prompt: String,
        style: String? = nil,
        excludeStyles: String? = nil,
        lyrics: String? = nil,
        status: SunoGenerationStatus = .generating,
        resultMessage: String? = nil,
        downloadedFilePath: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = UUID()
        self.songPath = songPath
        self.trackID = trackID
        self.prompt = prompt
        self.style = style
        self.excludeStyles = excludeStyles
        self.lyrics = lyrics
        self.status = status
        self.resultMessage = resultMessage
        self.downloadedFilePath = downloadedFilePath
        self.errorMessage = errorMessage
        self.createdAt = Date()
    }

    /// Whether this generation is still in progress.
    var isProcessing: Bool {
        status == .generating || status == .downloading
    }

    /// Whether the track is ready for download.
    var isReady: Bool {
        status == .ready && trackID != nil
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

    /// Short display title: first ~40 chars of prompt.
    var displayTitle: String {
        let text = prompt.prefix(40)
        return text.count < prompt.count ? "\(text)..." : String(text)
    }
}

// MARK: - Suno API Errors

enum SunoAPIError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse(statusCode: Int)
    case serverError(String)
    case networkError(Error)
    case browserNotOpen
    case loginRequired
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Suno not configured. Set server URL and account in settings."
        case .invalidURL:
            return "Invalid server URL."
        case .invalidResponse(let code):
            return "Server returned status \(code)."
        case .serverError(let msg):
            return "Server error: \(msg)"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .browserNotOpen:
            return "Browser not open. Click Login in settings first."
        case .loginRequired:
            return "Not logged in to Suno. Click Login in settings."
        case .toolFailed(let msg):
            return "Tool failed: \(msg)"
        }
    }
}
