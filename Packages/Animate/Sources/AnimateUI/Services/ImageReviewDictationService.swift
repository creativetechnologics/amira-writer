import AVFoundation
import Foundation
import Observation
import ProjectKit

@available(macOS 26.0, *)
struct ParakeetReviewDictationConfig: Codable, Sendable, Hashable {
    var command: String?
    var arguments: [String]?
    var commandTemplate: String?

    static func load(projectRoot: URL) -> ParakeetReviewDictationConfig? {
        let urls = [
            ProjectPaths(root: projectRoot).settings.appendingPathComponent("parakeet-review-dictation.json"),
            projectRoot.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("parakeet-review-dictation.json")
        ]
        let decoder = JSONDecoder()
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let config = try? decoder.decode(ParakeetReviewDictationConfig.self, from: data) {
                return config
            }
        }
        return nil
    }
}

@available(macOS 26.0, *)
@MainActor
@Observable
final class ImageReviewDictationSession {
    var isEnabled = false
    var isRecording = false
    var statusMessage: String = "Dictation off"
    var lastAudioPath: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var segmentURL: URL?

    func toggle(projectRoot: URL?) {
        guard let projectRoot else {
            statusMessage = "Open a project before starting review dictation."
            return
        }
        if isEnabled {
            Task { await stopAndTranscribe(projectRoot: projectRoot) }
            isEnabled = false
            statusMessage = "Dictation off"
        } else {
            isEnabled = true
            startSegment(projectRoot: projectRoot)
        }
    }

    func cycleForReviewCommand(projectRoot: URL?) async -> String? {
        guard isEnabled, let projectRoot else { return nil }
        let transcript = await stopAndTranscribe(projectRoot: projectRoot)
        if isEnabled {
            startSegment(projectRoot: projectRoot)
        }
        return transcript
    }

    func startSegment(projectRoot: URL) {
        guard isEnabled else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startAuthorizedSegment(projectRoot: projectRoot)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.startAuthorizedSegment(projectRoot: projectRoot) }
                    else {
                        self.isEnabled = false
                        self.statusMessage = "Microphone permission denied."
                    }
                }
            }
        case .denied, .restricted:
            isEnabled = false
            statusMessage = "Microphone permission is required for review dictation."
        @unknown default:
            isEnabled = false
            statusMessage = "Microphone permission state is unknown."
        }
    }

    @discardableResult
    func stopAndTranscribe(projectRoot: URL) async -> String? {
        guard isRecording || recorder != nil else { return nil }
        let url = segmentURL
        recorder?.stop()
        recorder = nil
        segmentURL = nil
        isRecording = false
        guard let url else { return nil }
        lastAudioPath = url.path
        statusMessage = "Transcribing review note…"
        do {
            let transcript = try await ParakeetReviewTranscriber.transcribe(audioURL: url, projectRoot: projectRoot)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.isEmpty {
                statusMessage = "No speech detected."
                return nil
            }
            statusMessage = "Transcribed note."
            return transcript
        } catch {
            statusMessage = "Dictation saved audio, but transcription is not configured: \(error.localizedDescription)"
            return nil
        }
    }

    private func startAuthorizedSegment(projectRoot: URL) {
        do {
            let dir = ProjectPaths(root: projectRoot).metadata
                .appendingPathComponent("automation", isDirectory: true)
                .appendingPathComponent("review-dictation", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("review-note-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                statusMessage = "Could not start microphone recording."
                isEnabled = false
                return
            }
            self.recorder = recorder
            self.segmentURL = url
            self.isRecording = true
            self.lastAudioPath = url.path
            self.statusMessage = "Recording review note… use ], [, /, or ; to commit and advance."
        } catch {
            isEnabled = false
            isRecording = false
            statusMessage = "Could not start review dictation: \(error.localizedDescription)"
        }
    }
}

@available(macOS 26.0, *)
enum ParakeetReviewTranscriber {
    enum TranscriptionError: LocalizedError {
        case missingConfiguration
        case failed(status: Int32, output: String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Add Settings/parakeet-review-dictation.json with commandTemplate or command/arguments."
            case .failed(let status, let output):
                return "Parakeet command exited \(status): \(output.prefix(300))"
            case .emptyOutput:
                return "Parakeet command returned no text."
            }
        }
    }

    static func transcribe(audioURL: URL, projectRoot: URL) async throws -> String {
        let invocation = try invocation(audioURL: audioURL, projectRoot: projectRoot)
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.arguments
            process.currentDirectoryURL = projectRoot
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw TranscriptionError.failed(status: process.terminationStatus, output: out + err)
            }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.emptyOutput }
            return text
        }.value
    }

    private static func invocation(audioURL: URL, projectRoot: URL) throws -> (executable: String, arguments: [String]) {
        if let config = ParakeetReviewDictationConfig.load(projectRoot: projectRoot) {
            if let template = config.commandTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty {
                let command = template.replacingOccurrences(of: "{audio}", with: shellEscaped(audioURL.path))
                return ("/bin/zsh", ["-lc", command])
            }
            if let command = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
                let args = (config.arguments ?? []).map {
                    $0.replacingOccurrences(of: "{audio}", with: audioURL.path)
                        .replacingOccurrences(of: "{project}", with: projectRoot.path)
                }
                return (command, args)
            }
        }
        let fallback = projectRoot.appendingPathComponent("Scripts/parakeet-transcribe.sh").path
        if FileManager.default.isExecutableFile(atPath: fallback) {
            return (fallback, [audioURL.path])
        }
        let userFallback = "/Users/gary/bin/parakeet-transcribe"
        if FileManager.default.isExecutableFile(atPath: userFallback) {
            return (userFallback, [audioURL.path])
        }
        throw TranscriptionError.missingConfiguration
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
