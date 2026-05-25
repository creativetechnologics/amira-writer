import Foundation

// MARK: - Map3DPipelineRunner
//
// Owns one in-flight 3D-map regeneration job. The pipeline lives at
// `Scripts/3d-map-pipeline/run_all.sh`.
//
// Default flow is "terrain only" — Phases A (Depth Anything V2), B (water
// HSV segmentation), and F (compose viewer scene). Total wall time ~30s on
// M-series MPS for a 6336×2688 master map.
//
// Building / road / landmark detection (Phases C, D, E) are gated behind
// `WITH_BUILDINGS=1` and not exposed in the in-app UI. SAM 2 takes 30+ min
// and produces unreliable footprints on illustrated maps.
//
// Responsibilities:
//   - Spawn `run_all.sh` via Process() with a Pipe for stdout/stderr.
//   - Parse phase markers ("=== Phase A: …") from stdout to track progress.
//   - Maintain a tail log (last N lines) so the UI can show what's happening.
//   - Enforce a single-job guard: a second `start()` while running is a no-op
//     that returns false. The HTTP layer maps that to 409 Conflict.
//
// Concurrency model: the public surface is @MainActor so SwiftUI views and
// the API router can read/write state without bridging. The Process callback
// closures hop back to the main actor before mutating state.

@available(macOS 26.0, *)
@MainActor
final class Map3DPipelineRunner: ObservableObject {
    static let shared = Map3DPipelineRunner()

    enum State: String, Sendable {
        case idle
        case running
        case succeeded
        case failed
    }

    struct Snapshot: Sendable {
        let state: State
        let jobId: UUID?
        let currentPhase: String?       // "A".."F" while running, last seen otherwise
        let startedAt: Date?
        let finishedAt: Date?
        let tailLog: [String]
        let errorMessage: String?
    }

    @Published private(set) var state: State = .idle
    /// Mirrored as @Published so SwiftUI views animate the phase label
    /// without polling `snapshot()` in their body. Updated together with
    /// `currentPhase` when a phase marker arrives.
    @Published private(set) var currentPhaseLabel: String = ""

    private var jobId: UUID?
    private var currentPhase: String?
    private var startedAt: Date?
    private var finishedAt: Date?
    private var errorMessage: String?
    private var process: Process?
    private var logBuffer: [String] = []
    private var stdoutBuffer = Data()

    private static let maxTailLines = 60

    /// Source-of-truth for the pipeline scripts. Keeping this hard-coded keeps
    /// the runtime contract obvious; if Gary ever moves the project, this will
    /// fail loudly with "run_all.sh not found" in `errorMessage`.
    private static let pipelineDir = URL(
        fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/3d-map-pipeline"
    )
    private static var runScriptURL: URL {
        pipelineDir.appendingPathComponent("run_all.sh")
    }

    /// Path the viewer (and `Map3DResourceLocator`) reads after regen. Exposed
    /// so callers can `setenv("AMIRA_MAP3D_DIR", …)` at app startup.
    static var viewerDir: URL {
        pipelineDir.appendingPathComponent("viewer")
    }

    private init() {}

    // MARK: - Job control

    /// Tries to start a new pipeline run. Returns `(started: false, jobId: existingId)`
    /// when a job is already in flight; otherwise `(true, newId)`.
    @discardableResult
    func start() -> (started: Bool, jobId: UUID) {
        if state == .running, let existing = jobId {
            return (false, existing)
        }

        let newId = UUID()
        jobId = newId
        state = .running
        currentPhase = nil
        currentPhaseLabel = "Starting…"
        startedAt = Date()
        finishedAt = nil
        errorMessage = nil
        logBuffer.removeAll(keepingCapacity: true)
        stdoutBuffer = Data()

        let runScript = Self.runScriptURL
        guard FileManager.default.isExecutableFile(atPath: runScript.path) else {
            state = .failed
            finishedAt = Date()
            errorMessage = "run_all.sh not found or not executable at \(runScript.path)"
            return (true, newId)   // job was "accepted" then immediately failed; UI will see failure on poll
        }

        let proc = Process()
        proc.executableURL = runScript
        proc.currentDirectoryURL = Self.pipelineDir
        proc.environment = launchEnvironment()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Stream stdout/stderr lines as they arrive so the UI can show progress.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.ingest(data)
            }
        }

        proc.terminationHandler = { [weak self] finishedProc in
            Task { @MainActor in
                self?.finish(exitStatus: finishedProc.terminationStatus, pipe: pipe)
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            state = .failed
            finishedAt = Date()
            errorMessage = "Failed to launch run_all.sh: \(error.localizedDescription)"
        }

        return (true, newId)
    }

    /// Terminates the running pipeline if any. Mostly defensive — Cancel mid-run
    /// is not exposed in the v1 UI because Phase A's torch inference does not
    /// checkpoint cleanly. Kept here so future callers (e.g. app shutdown) can
    /// reap the subprocess.
    func cancel() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            state: state,
            jobId: jobId,
            currentPhase: currentPhase,
            startedAt: startedAt,
            finishedAt: finishedAt,
            tailLog: logBuffer,
            errorMessage: errorMessage
        )
    }

    // MARK: - Internals

    private func launchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // run_all.sh defaults to /opt/miniconda3/bin/python3; ensure that path
        // is on PATH so child shell expansions resolve correctly even when the
        // app was launched from Finder (which has a minimal PATH).
        let condaBin = "/opt/miniconda3/bin"
        let existing = env["PATH", default: ""]
        if !existing.split(separator: ":").contains(Substring(condaBin)) {
            env["PATH"] = existing.isEmpty ? condaBin : "\(condaBin):\(existing)"
        }
        return env
    }

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        let newline = UInt8(0x0A)
        while let idx = stdoutBuffer.firstIndex(of: newline) {
            let lineData = stdoutBuffer.prefix(upTo: idx)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8) {
                appendLine(line)
            }
        }
    }

    private func appendLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        // Phase markers from run_all.sh look like: "=== Phase A: Depth …"
        if line.hasPrefix("=== Phase "), let letter = line.dropFirst("=== Phase ".count).first,
           letter.isLetter {
            let phase = String(letter)
            currentPhase = phase
            currentPhaseLabel = Self.phaseDescription(phase)
        }
        logBuffer.append(rawLine)
        if logBuffer.count > Self.maxTailLines {
            logBuffer.removeFirst(logBuffer.count - Self.maxTailLines)
        }
    }

    /// Human-readable label for a pipeline phase letter. Mirrors the bash
    /// banner text from `run_all.sh` so the UI says the same thing as the
    /// log. Update in lockstep when phases are added/renamed.
    private static func phaseDescription(_ letter: String) -> String {
        switch letter {
        case "A": return "Phase A · Depth (Depth Anything V2)"
        case "B": return "Phase B · Water segmentation"
        case "C": return "Phase C · Buildings (SAM 2)"
        case "D": return "Phase D · Roads"
        case "E": return "Phase E · Landmarks"
        case "F": return "Phase F · Compose viewer scene"
        default:  return "Phase \(letter)"
        }
    }

    private func finish(exitStatus: Int32, pipe: Pipe) {
        // Drain anything still sitting in the pipe.
        pipe.fileHandleForReading.readabilityHandler = nil
        let trailing = pipe.fileHandleForReading.availableData
        if !trailing.isEmpty {
            ingest(trailing)
            // Flush a final partial line if any (no trailing newline).
            if !stdoutBuffer.isEmpty,
               let line = String(data: stdoutBuffer, encoding: .utf8) {
                appendLine(line)
                stdoutBuffer.removeAll(keepingCapacity: false)
            }
        }
        finishedAt = Date()
        process = nil

        if exitStatus == 0 {
            state = .succeeded
        } else {
            state = .failed
            if errorMessage == nil {
                errorMessage = "run_all.sh exited with status \(exitStatus). See tail log for details."
            }
        }
    }
}
