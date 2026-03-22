import Foundation

/// HTTP client for the sandraschi/suno-mcp Playwright-based server.
/// Communicates with a Python FastAPI server (typically at localhost:3000)
/// that automates Suno's web UI via Playwright browser automation.
@available(macOS 26.0, *)
final class SunoAPIClient: @unchecked Sendable {

    // MARK: - Configuration (persisted via UserDefaults)

    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "sunoServerURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sunoServerURL") }
    }

    /// Whether the client has enough configuration to attempt requests.
    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Shared Session

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // Generation can take a long time (Playwright waits for completion)
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Public API: Browser Lifecycle

    /// Launch the Playwright Chromium browser.
    func openBrowser(headless: Bool = true) async throws -> String {
        try await callTool("suno_open_browser", arguments: ["headless": headless])
    }

    /// Close the Playwright browser session.
    func closeBrowser() async throws -> String {
        try await callTool("suno_close_browser", arguments: [:])
    }

    /// Get the current system/browser status.
    func getStatus() async throws -> String {
        try await callTool("suno_get_status", arguments: [:])
    }

    // MARK: - Public API: Music Generation

    /// Generate a track via Playwright browser automation.
    /// This call blocks until the track is generated (can take 30-120+ seconds).
    func generateTrack(
        prompt: String,
        style: String? = nil,
        excludeStyles: String? = nil,
        lyrics: String? = nil,
        duration: String? = nil
    ) async throws -> String {
        var args: [String: Any] = ["prompt": prompt]
        if let style, !style.isEmpty { args["style"] = style }
        if let excludeStyles, !excludeStyles.isEmpty { args["exclude_styles"] = excludeStyles }
        if let lyrics, !lyrics.isEmpty { args["lyrics"] = lyrics }
        if let duration, !duration.isEmpty { args["duration"] = duration }
        do {
            return try await callTool("suno_generate_track", arguments: args)
        } catch {
            guard shouldRecoverBrowserSession(from: error) else { throw error }

            NSLog("[SunoMCP] Detected stale browser session during generate_track; resetting and retrying once")
            _ = try? await closeBrowser()
            _ = try? await openBrowser(headless: false)
            return try await callTool("suno_generate_track", arguments: args)
        }
    }

    /// Download a generated track to a local path.
    func downloadTrack(
        trackID: String,
        downloadPath: String,
        includeStems: Bool = false
    ) async throws -> String {
        let args: [String: Any] = [
            "track_id": trackID,
            "download_path": downloadPath,
            "include_stems": includeStems,
        ]
        do {
            return try await callTool("suno_download_track", arguments: args)
        } catch {
            guard shouldRecoverBrowserSession(from: error) else { throw error }

            NSLog("[SunoMCP] Detected stale browser session during download_track; resetting and retrying once")
            _ = try? await closeBrowser()
            _ = try? await openBrowser(headless: true)
            return try await callTool("suno_download_track", arguments: args)
        }
    }

    // MARK: - Public API: Cover Workflow (Playwright automation)

    /// Upload an audio file to Suno for cover generation.
    func uploadAudio(filePath: String) async throws -> String {
        try await callTool("suno_upload_audio", arguments: [
            "file_path": filePath,
        ])
    }

    /// Create a cover from an uploaded audio track.
    func createCover(uploadID: String, style: String) async throws -> String {
        try await callTool("suno_create_cover", arguments: [
            "upload_id": uploadID,
            "style": style,
        ])
    }

    /// Check cover generation status.
    func getCoverStatus(coverID: String) async throws -> String {
        try await callTool("suno_get_cover_status", arguments: [
            "cover_id": coverID,
        ])
    }

    /// Download a completed cover.
    func downloadCover(coverID: String, downloadPath: String) async throws -> String {
        try await callTool("suno_download_cover", arguments: [
            "cover_id": coverID,
            "download_path": downloadPath,
        ])
    }

    /// Try cover workflow, fall back to text-only generation.
    func generateWithCoverFallback(
        audioPath: String,
        prompt: String,
        style: String
    ) async throws -> String {
        do {
            let uploadResult = try await uploadAudio(filePath: audioPath)
            guard let uploadID = parseField("upload_id", from: uploadResult) else {
                throw SunoAPIError.toolFailed("No upload_id in response")
            }
            let coverResult = try await createCover(uploadID: uploadID, style: style)
            guard let coverID = parseField("cover_id", from: coverResult) else {
                throw SunoAPIError.toolFailed("No cover_id in response")
            }
            // Poll for completion
            for _ in 0..<60 {  // max 5 minutes
                try await Task.sleep(for: .seconds(5))
                let status = try await getCoverStatus(coverID: coverID)
                if status.contains("complete") || status.contains("ready") {
                    return coverID
                }
                if status.contains("error") || status.contains("failed") {
                    throw SunoAPIError.toolFailed("Cover generation failed: \(status)")
                }
            }
            throw SunoAPIError.toolFailed("Cover generation timed out")
        } catch {
            NSLog("[SunoMCP] Cover path failed (%@), falling back to text-only",
                  error.localizedDescription)
            return try await generateTrack(prompt: prompt, style: style)
        }
    }

    // MARK: - Health Check

    /// Check if the FastAPI server is responding.
    func healthCheck() async throws -> Bool {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/health") else {
            throw SunoAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
        } catch {
            throw SunoAPIError.networkError(error)
        }
        return false
    }

    // MARK: - Private: JSON Parsing

    private func parseField(_ field: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let value = obj[field] as? String { return value }
        if let nested = obj["result"] as? String { return parseField(field, from: nested) }
        return nil
    }

    private func shouldRecoverBrowserSession(from error: Error) -> Bool {
        let message: String
        if let apiError = error as? SunoAPIError {
            switch apiError {
            case .toolFailed(let msg), .serverError(let msg):
                message = msg
            case .networkError(let nested):
                message = nested.localizedDescription
            default:
                message = apiError.localizedDescription
            }
        } else {
            message = error.localizedDescription
        }

        let lower = message.lowercased()
        return lower.contains("target page, context or browser has been closed")
            || lower.contains("browser has been closed")
            || lower.contains("context has been closed")
            || lower.contains("page has been closed")
    }

    // MARK: - Private: Tool Execution

    /// Call an MCP tool via the FastAPI HTTP interface.
    /// Sends POST /api/v1/tools/{toolName} with JSON body.
    private func callTool(_ toolName: String, arguments: [String: Any]) async throws -> String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw SunoAPIError.notConfigured }

        guard let url = URL(string: "\(base)/api/v1/tools/\(toolName)") else {
            throw SunoAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Generation and download can take minutes
        if toolName == "suno_generate_track" {
            request.timeoutInterval = 300  // 5 minutes
        } else if toolName == "suno_download_track" {
            request.timeoutInterval = 120  // 2 minutes
        }

        // Encode arguments as JSON body
        let body: [String: Any] = ["name": toolName, "arguments": arguments]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        NSLog("[SunoMCP] Calling tool: %@ with args: %@", toolName, String(describing: arguments))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SunoAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SunoAPIError.invalidResponse(statusCode: 0)
        }

        let responseText = String(data: data, encoding: .utf8) ?? ""

        switch http.statusCode {
        case 200...299:
            let resultText = unwrapToolResult(from: responseText) ?? responseText
            NSLog("[SunoMCP] Tool %@ succeeded: %@", toolName, String(resultText.prefix(200)))
            return resultText
        default:
            let detail = unwrapToolError(from: responseText) ?? responseText
            NSLog("[SunoMCP] Tool %@ failed (HTTP %d): %@", toolName, http.statusCode, String(detail.prefix(500)))
            throw SunoAPIError.toolFailed("HTTP \(http.statusCode): \(detail.prefix(300))")
        }
    }

    private func unwrapToolResult(from responseText: String) -> String? {
        guard let data = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let result = json["result"] as? String { return result }
        if let result = json["result"] { return String(describing: result) }
        return nil
    }

    private func unwrapToolError(from responseText: String) -> String? {
        guard let data = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let detail = json["detail"] as? String { return detail }
        if let detail = json["detail"] { return String(describing: detail) }
        if let error = json["error"] as? String { return error }
        return nil
    }
}
