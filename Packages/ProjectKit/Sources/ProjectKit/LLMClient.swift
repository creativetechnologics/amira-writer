import Foundation

// MARK: - API Request / Response (private)

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [LLMMessage]
    let temperature: Double
    let stream: Bool
    let max_completion_tokens: Int?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
        }
        let message: Message?
        let delta: Message?
        let finish_reason: String?
    }
    let choices: [Choice]?
}

// MARK: - LLMClient

/// Async client for chat completions via any OpenAI-compatible endpoint (MiniMax, OpenRouter, etc.)
/// or the Claude CLI. This is the shared infrastructure layer; module-specific features like
/// suggestion parsing live in their respective modules.
@available(macOS 14.0, *)
@MainActor
@Observable
public final class LLMClient {

    // MARK: - Configuration (reads from shared LLMProviderConfig)

    private var config: LLMProviderConfig { LLMProviderConfig.shared }

    // MARK: - State

    private static let maxMessages = 200

    public var messages: [LLMMessage] = []
    public var isGenerating: Bool = false
    public var errorMessage: String?

    /// Current streaming partial response (appended token-by-token).
    public var streamingContent: String = ""

    public init() {}

    /// Trims messages to prevent unbounded memory growth.
    private func trimHistory() {
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    // MARK: - System Prompt

    /// Builds a context-aware system prompt incorporating the current song and project info.
    public func buildSystemPrompt(
        projectName: String?,
        songName: String?,
        librettoText: String?,
        trackNames: [String]
    ) -> String {
        var parts: [String] = []

        let modelName = config.activeModelDisplayName
        parts.append("""
        You are a creative writing assistant (\(modelName)) embedded in a musical theater / opera composition tool called Amira Writer. \
        You help the composer with lyrics, libretto text, scene directions, storyboard descriptions, and character dialogue. \
        If asked what model you are, say you are \(modelName) running inside Amira Writer.
        """)

        parts.append("""
        When the user asks you to rewrite or suggest changes to specific lines, format your suggestions clearly. \
        Use this exact format for line replacements so the tool can parse them:

        [SUGGEST]
        ORIGINAL: <the exact original line>
        REPLACEMENT: <your suggested replacement>
        [/SUGGEST]

        You can include multiple [SUGGEST] blocks. Always quote the original line exactly as it appears.
        """)

        parts.append("""
        Keep responses concise and focused. You're in a narrow inspector panel, so avoid walls of text. \
        Use bullet points and short paragraphs. Be direct and creative.
        """)

        if let name = projectName, !name.isEmpty {
            parts.append("The current project/show is: \"\(name)\".")
        }

        if let song = songName, !song.isEmpty {
            parts.append("The user is currently working on the song: \"\(song)\".")
        }

        if !trackNames.isEmpty {
            parts.append("The song has these instrument/vocal tracks: \(trackNames.joined(separator: ", ")).")
        }

        if let text = librettoText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("""
            Here are the current lyrics/libretto for this song:
            ---
            \(text)
            ---
            Reference these lyrics when the user asks about specific lines or wants changes.
            """)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Chat

    /// Send a message and get a streaming response. Appends both user and assistant messages.
    public func send(
        _ userText: String,
        projectName: String?,
        songName: String?,
        librettoText: String?,
        trackNames: [String]
    ) async {
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isGenerating else { return }

        errorMessage = nil
        isGenerating = true
        streamingContent = ""

        // Append user message
        let userMessage = LLMMessage(role: "user", content: userText)
        messages.append(userMessage)

        // Build the full message list with system prompt
        let systemPrompt = buildSystemPrompt(
            projectName: projectName,
            songName: songName,
            librettoText: librettoText,
            trackNames: trackNames
        )

        var apiMessages: [LLMMessage] = [LLMMessage(role: "system", content: systemPrompt)]
        // Include recent conversation history (last 20 messages to stay within context)
        let recentMessages = messages.suffix(20)
        apiMessages.append(contentsOf: recentMessages)

        NSLog("[LLMSend] provider=%@ endpoint=%@ model=%@ usesCLI=%d",
              config.activeProvider.rawValue, config.currentEndpoint.absoluteString,
              config.currentModelID, config.usesCLI ? 1 : 0)

        do {
            let response: String
            if config.usesCLI {
                response = try await claudeCLICompletion(
                    systemPrompt: systemPrompt,
                    userMessage: userText,
                    conversationHistory: Array(recentMessages.dropLast()) // exclude the just-added user message
                )
            } else {
                response = try await streamCompletion(messages: apiMessages)
            }
            let assistantMessage = LLMMessage(role: "assistant", content: response)
            messages.append(assistantMessage)
            streamingContent = ""
        } catch {
            errorMessage = error.localizedDescription
            // Keep the user message so they don't lose their prompt.
            // If there was partial streaming content, save it as the assistant response.
            if !streamingContent.isEmpty {
                let partialMessage = LLMMessage(role: "assistant", content: streamingContent)
                messages.append(partialMessage)
            }
            streamingContent = ""
        }

        trimHistory()
        isGenerating = false
    }

    /// Send a message with a caller-provided system prompt (for modules that build their own context).
    /// Appends user and assistant messages, streams the response, and handles errors identically to `send(...)`.
    public func sendWithSystemPrompt(
        _ userText: String,
        systemPrompt: String
    ) async {
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isGenerating else { return }

        errorMessage = nil
        isGenerating = true
        streamingContent = ""

        let userMessage = LLMMessage(role: "user", content: userText)
        messages.append(userMessage)

        var apiMessages: [LLMMessage] = [LLMMessage(role: "system", content: systemPrompt)]
        let recentMessages = messages.suffix(20)
        apiMessages.append(contentsOf: recentMessages)

        NSLog("[LLMSend] provider=%@ endpoint=%@ model=%@ usesCLI=%d",
              config.activeProvider.rawValue, config.currentEndpoint.absoluteString,
              config.currentModelID, config.usesCLI ? 1 : 0)

        do {
            let response: String
            if config.usesCLI {
                response = try await claudeCLICompletion(
                    systemPrompt: systemPrompt,
                    userMessage: userText,
                    conversationHistory: Array(recentMessages.dropLast())
                )
            } else {
                response = try await streamCompletion(messages: apiMessages)
            }
            let assistantMessage = LLMMessage(role: "assistant", content: response)
            messages.append(assistantMessage)
            streamingContent = ""
        } catch {
            errorMessage = error.localizedDescription
            if !streamingContent.isEmpty {
                let partialMessage = LLMMessage(role: "assistant", content: streamingContent)
                messages.append(partialMessage)
            }
            streamingContent = ""
        }

        trimHistory()
        isGenerating = false
    }

    /// Load messages from a persisted session.
    public func loadSession(_ session: LLMChatSession) {
        messages = session.messages
        streamingContent = ""
        errorMessage = nil
    }

    /// Clear chat history.
    public func clearHistory() {
        messages.removeAll()
        streamingContent = ""
        errorMessage = nil
    }

    // MARK: - Streaming HTTP

    private func streamCompletion(messages: [LLMMessage]) async throws -> String {
        let endpoint = config.currentEndpoint
        let apiKey = config.currentAPIKey
        let modelID = config.currentModelID
        NSLog("[LLMChat] Provider: %@ | Endpoint: %@ | Model: %@", config.activeProvider.rawValue, endpoint.absoluteString, modelID)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            model: modelID,
            messages: messages,
            temperature: 0.7,
            stream: true,
            max_completion_tokens: 4096
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            // Try to read the error body
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw LLMClientError.apiError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var fullContent = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if jsonStr.trimmingCharacters(in: .whitespaces) == "[DONE]" { break }

            guard let data = jsonStr.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
               let delta = chunk.choices?.first?.delta,
               let content = delta.content {
                fullContent += content
                // Strip <think> blocks from the live display so the user only
                // sees the actual response, not the model's reasoning trace.
                streamingContent = Self.stripThinkTags(fullContent)
            }
        }

        // Store the full content (with think tags stripped) as the final message
        return Self.stripThinkTags(fullContent)
    }

    // MARK: - Claude CLI

    /// Execute a completion via the `claude` CLI using `-p` (print mode).
    /// Builds a single prompt that includes the system context and conversation history.
    private func claudeCLICompletion(
        systemPrompt: String,
        userMessage: String,
        conversationHistory: [LLMMessage]
    ) async throws -> String {
        guard let cliPath = config.claudeCLIPath else {
            throw LLMClientError.cliError(message: "Claude CLI not found. Install from code.claude.com")
        }

        // Build the full prompt with system context and recent history
        var fullPrompt = ""

        // Include recent conversation for context (compact format)
        if !conversationHistory.isEmpty {
            fullPrompt += "Previous conversation:\n"
            for msg in conversationHistory.suffix(10) {
                let role = msg.role == "user" ? "User" : "Assistant"
                // Truncate long messages in history to save tokens
                let content = msg.content.count > 500 ? String(msg.content.prefix(500)) + "..." : msg.content
                fullPrompt += "[\(role)]: \(content)\n\n"
            }
            fullPrompt += "---\n\n"
        }

        fullPrompt += userMessage

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "-p", fullPrompt,
            "--output-format", "json",
            "--model", config.currentModelID,
            "--append-system-prompt", systemPrompt
        ]

        // Ensure HOME and PATH are set correctly for the CLI to find its auth and dependencies.
        // GUI apps launched from Finder may not have the full shell environment.
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        env["HOME"] = home
        // Ensure PATH includes common locations for node, npm, etc. that claude may need
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: home)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Provide stdin even though we don't write to it (prevents hangs)
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        stdinPipe.fileHandleForWriting.closeFile()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                // Parse JSON output even on non-zero exit -- claude -p returns JSON with is_error flag
                struct ClaudeCLIResponse: Decodable {
                    let result: String?
                    let is_error: Bool?
                    let session_id: String?
                }

                if let response = try? JSONDecoder().decode(ClaudeCLIResponse.self, from: data) {
                    if response.is_error == true {
                        let msg = response.result ?? "Unknown error"
                        continuation.resume(throwing: LLMClientError.cliError(message: msg))
                    } else if let result = response.result, !result.isEmpty {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: LLMClientError.cliError(message: "Empty response"))
                    }
                    return
                }

                guard process.terminationStatus == 0 else {
                    let errorText = String(data: stderrData, encoding: .utf8) ?? "Exited with code \(process.terminationStatus)"
                    continuation.resume(throwing: LLMClientError.cliError(message: errorText))
                    return
                }

                if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: LLMClientError.cliError(message: "Empty response"))
                }
            }

            do {
                try process.run()
                // Update streaming content with a placeholder while waiting
                Task { @MainActor in
                    self.streamingContent = "Thinking..."
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Non-streaming fallback

    public func sendNonStreaming(messages apiMessages: [LLMMessage]) async throws -> String {
        var request = URLRequest(url: config.currentEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.currentAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            model: config.currentModelID,
            messages: apiMessages,
            temperature: 0.7,
            stream: false,
            max_completion_tokens: 4096
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw LLMClientError.apiError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return decoded.choices?.first?.message?.content ?? ""
    }

    // MARK: - Suggest-Pair Extraction (shared utility)

    /// Extract raw (original, replacement) pairs from [SUGGEST] blocks.
    /// Module-specific suggestion resolution (matching to libretto lines, scenes, etc.)
    /// should be implemented in the consuming module.
    public static func extractSuggestPairs(from text: String) -> [(original: String, replacement: String)] {
        let pattern = #"\[SUGGEST\]\s*ORIGINAL:\s*(.+?)\s*REPLACEMENT:\s*(.+?)\s*\[/SUGGEST\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let original = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return (original, replacement)
        }
    }

    // MARK: - Think-Tag Stripping

    /// Strip `<think>...</think>` reasoning blocks that MiniMax M2.7 includes.
    /// Handles both complete blocks (including nested) and in-progress blocks during streaming.
    public static func stripThinkTags(_ text: String) -> String {
        var result = text
        // Loop to handle nested <think> tags
        if let regex = try? NSRegularExpression(pattern: #"<think>[\s\S]*?</think>\s*"#, options: []) {
            var previous = ""
            while result != previous {
                previous = result
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(location: 0, length: (result as NSString).length),
                    withTemplate: ""
                )
            }
        }
        // Strip in-progress <think> block (no closing tag yet -- happens during streaming)
        if let openRange = result.range(of: "<think>") {
            let afterOpen = result[openRange.upperBound...]
            if !afterOpen.contains("</think>") {
                result = String(result[..<openRange.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

public enum LLMClientError: LocalizedError {
    case apiError(statusCode: Int, body: String)
    case cliError(message: String)

    public var errorDescription: String? {
        switch self {
        case .apiError(let code, let body):
            return "API error (\(code)): \(body.prefix(200))"
        case .cliError(let message):
            return "Claude CLI: \(message)"
        }
    }
}
