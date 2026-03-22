#if canImport(MLXLLM)
import Foundation
import MLXLLM
@preconcurrency import MLXLMCommon

// MARK: - LLMLoadTest

/// CLI diagnostic for testing LLM model download and loading.
///
/// Invoked via: NovotroScore --test-llm-load [model-id]
///
/// Tests each stage of the LLM loading pipeline:
/// 1. Memory check
/// 2. ModelConfiguration creation
/// 3. Model download from HuggingFace Hub
/// 4. Model weight loading into GPU memory
/// 5. ChatSession creation
/// 6. Simple text generation
/// 7. Model unload + cleanup
///
/// If no model-id is provided, tests the smallest available model (Qwen2.5 0.5B).
@available(macOS 26.0, *)
@MainActor
enum LLMLoadTest {

    static func run() -> Int32 {
        // Parse optional model ID from arguments
        let args = CommandLine.arguments
        let modelID: String
        if let idx = args.firstIndex(of: "--test-llm-load"),
           idx + 1 < args.count, !args[idx + 1].hasPrefix("--") {
            modelID = args[idx + 1]
        } else {
            modelID = LLMClient.DefaultModel.qwen2_5_05B.rawValue
        }

        let displayName = LLMClient.DefaultModel(rawValue: modelID)?.displayName ?? modelID
        let estimatedMem = LLMClient.DefaultModel(rawValue: modelID)?.estimatedMemoryGB ?? 0

        log("LLM Load Diagnostic")
        log("================================================")
        log("Model: \(displayName)")
        log("HuggingFace ID: \(modelID)")
        if estimatedMem > 0 {
            log("Estimated memory: \(String(format: "%.1f", estimatedMem))GB")
        }
        log("")

        // Run the async test on the main run loop
        var exitCode: Int32 = 0
        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor in
            exitCode = await runAsync(modelID: modelID)
            semaphore.signal()
        }

        // Pump the run loop while waiting for async work
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        log("")
        log("================================================")
        if exitCode == 0 {
            log("RESULT: ALL STAGES PASSED")
        } else {
            log("RESULT: FAILED (see errors above)")
        }

        return exitCode
    }

    private static func runAsync(modelID: String) async -> Int32 {
        // ── Stage 1: Memory Check ───────────────────────────
        log("── Stage 1: Memory Check ──────────────────────────")
        let totalMemGB = LLMClient.availableMemoryGB()
        log("  Total system memory: \(String(format: "%.1f", totalMemGB))GB")

        let required = LLMClient.DefaultModel(rawValue: modelID)?.estimatedMemoryGB ?? 4.0
        let needed = required * 1.5
        log("  Required (with 1.5x margin): \(String(format: "%.1f", needed))GB")

        if totalMemGB > needed {
            log("  ✓ Memory check passed")
        } else {
            log("  ✗ INSUFFICIENT MEMORY")
            return 1
        }

        // ── Stage 2: ModelConfiguration ─────────────────────
        log("")
        log("── Stage 2: ModelConfiguration ────────────────────")
        let config = ModelConfiguration(id: modelID)
        log("  ✓ ModelConfiguration created: id=\(config.id)")

        // ── Stage 3: Download + Load ────────────────────────
        log("")
        log("── Stage 3: Download + Load (LLMModelFactory) ────")
        log("  Starting download (this may take a while on first run)...")

        let startTime = CFAbsoluteTimeGetCurrent()
        nonisolated(unsafe) var lastReportedPct = -1

        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { progress in
                let pct = Int(progress.fractionCompleted * 100)
                // Report every 10%
                if pct / 10 > lastReportedPct / 10 {
                    lastReportedPct = pct
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    print("[LLM-TEST]   ... \(pct)% downloaded (\(String(format: "%.1f", elapsed))s)")
                    fflush(stdout)
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            log("  ✓ Model loaded in \(String(format: "%.1f", elapsed))s")
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            log("  ✗ LOAD FAILED after \(String(format: "%.1f", elapsed))s")
            log("  Error type: \(type(of: error))")
            log("  Error: \(error)")
            log("  Localized: \(error.localizedDescription)")
            return 1
        }

        // ── Stage 4: ChatSession ────────────────────────────
        log("")
        log("── Stage 4: ChatSession Creation ──────────────────")
        let session = ChatSession(container)
        log("  ✓ ChatSession created")

        // ── Stage 5: Text Generation ────────────────────────
        log("")
        log("── Stage 5: Simple Text Generation ────────────────")
        do {
            session.instructions = "You are a helpful assistant. Reply in 10 words or fewer."
            let genStart = CFAbsoluteTimeGetCurrent()
            let response = try await session.respond(to: "Say hello")
            let genElapsed = CFAbsoluteTimeGetCurrent() - genStart
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            log("  Response: \"\(trimmed)\"")
            log("  ✓ Generation completed in \(String(format: "%.1f", genElapsed))s")
        } catch {
            log("  ✗ GENERATION FAILED: \(error)")
            log("  Error type: \(type(of: error))")
            return 1
        }

        // ── Stage 6: Cleanup ────────────────────────────────
        log("")
        log("── Stage 6: Cleanup ───────────────────────────────")
        // Just let it go out of scope
        _ = session
        _ = container
        log("  ✓ Cleanup complete")

        return 0
    }

    private static func log(_ message: String) {
        print("[LLM-TEST] \(message)")
    }
}
#endif
