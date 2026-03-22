import Foundation

/// Wrapper for the Rhubarb Lip Sync command-line tool.
///
/// Rhubarb analyzes audio files and produces timed phoneme/viseme data.
/// Input: WAV/FLAC audio file
/// Output: JSON with timed mouth shape data
///
/// Expected Rhubarb output format:
/// ```json
/// {
///   "metadata": { "soundFile": "...", "duration": 5.2 },
///   "mouthCues": [
///     { "start": 0.0, "end": 0.5, "value": "X" },
///     { "start": 0.5, "end": 0.8, "value": "D" },
///     ...
///   ]
/// }
/// ```
@available(macOS 26.0, *)
@MainActor
final class RhubarbLipSync {

    // MARK: - Types

    struct RhubarbOutput: Codable, Sendable {
        var metadata: Metadata
        var mouthCues: [MouthCue]

        struct Metadata: Codable, Sendable {
            var soundFile: String
            var duration: Double
        }

        struct MouthCue: Codable, Sendable {
            var start: Double
            var end: Double
            var value: String  // A-H, X
        }
    }

    enum RhubarbError: LocalizedError {
        case notInstalled
        case processFailed(String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Rhubarb Lip Sync is not installed. Install via Homebrew: brew install rhubarb-lip-sync"
            case .processFailed(let msg):
                "Rhubarb failed: \(msg)"
            case .invalidOutput:
                "Could not parse Rhubarb output."
            }
        }
    }

    // MARK: - Properties

    /// Path to the rhubarb binary. Searches common locations.
    private var rhubarbPath: String? {
        let candidates = [
            "/opt/homebrew/bin/rhubarb",
            "/usr/local/bin/rhubarb",
            Bundle.main.resourcePath.map { "\($0)/rhubarb" },
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Check if Rhubarb is available.
    var isAvailable: Bool {
        rhubarbPath != nil
    }

    // MARK: - Analysis

    /// Analyze an audio file and return timed mouth cues.
    func analyze(audioURL: URL, dialogueText: String? = nil) async throws -> RhubarbOutput {
        guard let rhubarb = rhubarbPath else {
            throw RhubarbError.notInstalled
        }

        var arguments = [
            rhubarb,
            audioURL.path,
            "--exportFormat", "json",
            "--machineReadable",
        ]

        // If dialogue text is provided, write it to a temp file for Rhubarb
        var tempDialogueURL: URL?
        if let text = dialogueText, !text.isEmpty {
            let tempDir = FileManager.default.temporaryDirectory
            let dialogueFile = tempDir.appendingPathComponent("rhubarb_dialogue_\(UUID().uuidString).txt")
            try text.write(to: dialogueFile, atomically: true, encoding: .utf8)
            arguments.append(contentsOf: ["--dialogFile", dialogueFile.path])
            tempDialogueURL = dialogueFile
        }

        defer {
            if let url = tempDialogueURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rhubarb)
        process.arguments = Array(arguments.dropFirst()) // first element is the executable
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw RhubarbError.processFailed(errorStr)
        }

        guard let output = try? JSONDecoder().decode(RhubarbOutput.self, from: outputData) else {
            throw RhubarbError.invalidOutput
        }

        return output
    }

    /// Analyze audio and directly produce viseme keyframes.
    func analyzeToVisemes(audioURL: URL, fps: Int, dialogueText: String? = nil) async throws -> [LipSyncEngine.VisemeKeyframe] {
        let output = try await analyze(audioURL: audioURL, dialogueText: dialogueText)

        return output.mouthCues.map { cue in
            let frame = Int((cue.start * Double(fps)).rounded())
            let endFrame = Int((cue.end * Double(fps)).rounded())
            let duration = max(1, endFrame - frame)
            let viseme = LipSyncEngine.rhubarbShapeToViseme(cue.value)

            return LipSyncEngine.VisemeKeyframe(
                frame: frame,
                viseme: viseme,
                duration: duration
            )
        }
    }
}
