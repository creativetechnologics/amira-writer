#if canImport(MLXLLM)
import Foundation
import MLXLLM
@preconcurrency import MLXLMCommon

// MARK: - LLMClient

/// Manages local LLM model lifecycle and text generation via MLX.
///
/// Unlike other MusicEngine modules (stateless enums), `LLMClient` is a class
/// because it owns mutable GPU model state and manages download/load lifecycle.
/// Uses `ChatSession` from MLXLMCommon for conversation-aware generation.
@available(macOS 26.0, *)
@MainActor
final class LLMClient: ObservableObject {

    // MARK: - Types

    /// Current state of the LLM model.
    enum ModelState: Sendable {
        case idle
        case downloading(Double)   // fraction 0.0–1.0
        case loading
        case ready
        case error(String)
    }

    /// Pre-configured models available for download.
    enum DefaultModel: String, CaseIterable, Sendable {
        case qwen2_5_05B = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        case llama3_2_1B = "mlx-community/Llama-3.2-1B-Instruct-4bit"
        case llama3_2_3B = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        case qwen3_4B    = "mlx-community/Qwen3-4B-4bit"
        case mistral_7B  = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"

        var displayName: String {
            switch self {
            case .qwen2_5_05B: return "Qwen2.5 0.5B"
            case .llama3_2_1B: return "Llama 3.2 1B"
            case .llama3_2_3B: return "Llama 3.2 3B"
            case .qwen3_4B:    return "Qwen3 4B"
            case .mistral_7B:  return "Mistral 7B"
            }
        }

        var estimatedMemoryGB: Double {
            switch self {
            case .qwen2_5_05B: return 0.4
            case .llama3_2_1B: return 0.8
            case .llama3_2_3B: return 2.0
            case .qwen3_4B:    return 2.5
            case .mistral_7B:  return 4.0
            }
        }
    }

    // MARK: - Published State

    @Published var modelState: ModelState = .idle
    @Published var currentModelID: String?

    // MARK: - Private State

    private var modelContainer: ModelContainer?
    nonisolated(unsafe) private var chatSession: ChatSession?

    // MARK: - Model Lifecycle

    /// Load a model by HuggingFace ID (e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit").
    ///
    /// Downloads model weights from HuggingFace Hub on first use (cached thereafter).
    /// Sets `modelState` through downloading → loading → ready states.
    func loadModel(id: String) async {
        // Only allow loading from idle or error states.
        switch modelState {
        case .idle, .error: break
        default:
            print("[LLM] loadModel: already in state \(modelState), skipping")
            return
        }

        // Memory safety check
        let required = DefaultModel(rawValue: id)?.estimatedMemoryGB ?? 4.0
        let available = Self.availableMemoryGB()
        print("[LLM] loadModel: id=\(id), required=\(required)GB, available=\(String(format: "%.1f", available))GB")
        guard available > required * 1.5 else {
            let msg = "Insufficient memory: \(String(format: "%.1f", available))GB available, "
                + "\(String(format: "%.1f", required * 1.5))GB recommended"
            print("[LLM] loadModel: \(msg)")
            modelState = .error(msg)
            return
        }

        modelState = .downloading(0)
        print("[LLM] loadModel: starting download/load for \(id)...")

        do {
            let config = ModelConfiguration(id: id)
            print("[LLM] loadModel: ModelConfiguration created, calling loadContainer...")

            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    // Throttle UI updates — only update every 2%
                    if case .downloading(let prev) = self?.modelState,
                       abs(fraction - prev) < 0.02, fraction < 1.0 {
                        return
                    }
                    self?.modelState = .downloading(fraction)
                }
            }

            print("[LLM] loadModel: container loaded, creating ChatSession...")
            modelState = .loading
            self.modelContainer = container
            self.chatSession = ChatSession(container)
            self.currentModelID = id
            modelState = .ready
            print("[LLM] loadModel: model ready!")
        } catch {
            let msg = error.localizedDescription
            print("[LLM] loadModel: ERROR — \(msg)")
            modelState = .error(msg)
        }
    }

    /// Unload the current model and free GPU memory.
    func unloadModel() {
        chatSession = nil
        modelContainer = nil
        currentModelID = nil
        modelState = .idle
    }

    // MARK: - Generation

    /// Generate a complete response for the given prompt.
    ///
    /// - Parameters:
    ///   - prompt: User message text.
    ///   - systemPrompt: System instructions for the model.
    ///   - maxTokens: Maximum tokens to generate (default: 1024).
    /// - Returns: The complete generated text.
    func generate(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int = 1024
    ) async throws -> String {
        guard let session = chatSession else {
            throw LLMError.modelNotLoaded
        }

        session.instructions = systemPrompt
        return try await session.respond(to: prompt)
    }

    /// Stream a response token by token.
    ///
    /// - Parameters:
    ///   - prompt: User message text.
    ///   - systemPrompt: System instructions for the model.
    ///   - maxTokens: Maximum tokens to generate (default: 1024).
    /// - Returns: An async stream of text chunks.
    func generateStreaming(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let session = self.chatSession else {
                    continuation.finish(throwing: LLMError.modelNotLoaded)
                    return
                }

                session.instructions = systemPrompt

                do {
                    for try await text in session.streamResponse(to: prompt) {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Clear the chat session history while keeping the model loaded.
    func clearHistory() async {
        await chatSession?.clear()
    }

    // MARK: - Memory

    /// Available system memory in gigabytes.
    static func availableMemoryGB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    }

    // MARK: - Errors

    enum LLMError: LocalizedError {
        case modelNotLoaded
        case insufficientMemory(available: Double, required: Double)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "No LLM model is loaded. Load a model first."
            case .insufficientMemory(let available, let required):
                return "Insufficient memory: \(String(format: "%.1f", available))GB available, "
                    + "\(String(format: "%.1f", required))GB required."
            }
        }
    }
}
#endif