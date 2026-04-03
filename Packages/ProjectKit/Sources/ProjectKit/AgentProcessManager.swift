import Foundation

// MARK: - Agent Types

public enum ConsoleAgentType: String, CaseIterable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
}

public enum ConsoleAgentModel: String, CaseIterable, Sendable {
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"
    case gpt5Codex = "gpt-5-codex"

    public var displayName: String {
        switch self {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        case .gpt5Codex: return "GPT-5 Codex"
        }
    }

    public static func available(for agent: ConsoleAgentType) -> [ConsoleAgentModel] {
        switch agent {
        case .claudeCode: return [.sonnet, .opus, .haiku]
        case .codex: return [.gpt5Codex]
        }
    }
}

// MARK: - Agent Error

public enum AgentError: LocalizedError {
    case processExited(code: Int32, stderr: String)
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .processExited(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Agent exited with code \(code)." : "Agent exited (\(code)): \(trimmed)"
        case .notInstalled(let name):
            return "\(name) CLI not found in PATH."
        }
    }
}

// MARK: - Agent Process Manager

@MainActor
public final class AgentProcessManager: Sendable {
    private var currentProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    public var isRunning: Bool { currentProcess?.isRunning ?? false }

    public init() {}

    public func sendMessage(
        _ message: String,
        agent: ConsoleAgentType,
        model: ConsoleAgentModel,
        workingDirectory: URL,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Result<Void, AgentError>) -> Void
    ) {
        cancelCurrentProcess()

        let executableName: String
        let arguments: [String]
        let useStdin: Bool

        switch agent {
        case .claudeCode:
            executableName = "claude"
            arguments = [
                "-p", "--continue",
                "--output-format", "text",
                "--model", model.rawValue,
                "--allowedTools", "Read,Edit,Write",
            ]
            useStdin = true
        case .codex:
            executableName = "codex"
            arguments = [
                "exec",
                "--model", model.rawValue,
                "--sandbox", "workspace-write",
                "--ask-for-approval", "never",
                "--output-last-message",
                message,
            ]
            useStdin = false
        }

        guard let executablePath = Self.resolveExecutablePath(executableName) else {
            onComplete(.failure(.notInstalled(agent.rawValue)))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        // Inherit the full parent environment so the CLI can find auth credentials,
        // keychain access, config directories, etc. Only override PATH and TERM.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["PATH"] = Self.fullShellPath()
        // Ensure HOME is always set (GUI apps launched from Finder may not have it)
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        process.environment = env

        // Pipe prompt through stdin for Claude Code (more reliable than positional arg)
        let stdinPipe: Pipe? = useStdin ? Pipe() : nil
        if useStdin {
            process.standardInput = stdinPipe
        }

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let stderrLock = NSLock()
        nonisolated(unsafe) var stderrData = Data()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { onChunk(text) }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrLock.lock()
            stderrData.append(data)
            stderrLock.unlock()
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            stderrLock.lock()
            let errText = String(data: stderrData, encoding: .utf8) ?? ""
            stderrLock.unlock()
            DispatchQueue.main.async {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                if status == 0 {
                    onComplete(.success(()))
                } else {
                    onComplete(.failure(.processExited(code: status, stderr: errText)))
                }
            }
        }

        self.currentProcess = process
        self.outputPipe = stdoutPipe
        self.errorPipe = stderrPipe

        do {
            try process.run()
            // Write prompt to stdin and close to signal EOF
            if let stdinPipe, let data = message.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
                stdinPipe.fileHandleForWriting.closeFile()
            }
        } catch {
            self.currentProcess = nil
            self.outputPipe = nil
            self.errorPipe = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            onComplete(.failure(.processExited(code: -1, stderr: error.localizedDescription)))
        }
    }

    public func cancelCurrentProcess() {
        guard let process = currentProcess else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        currentProcess = nil
        outputPipe = nil
        errorPipe = nil
    }

    public static func isAgentAvailable(_ agent: ConsoleAgentType) -> Bool {
        let name: String
        switch agent {
        case .claudeCode: name = "claude"
        case .codex: name = "codex"
        }
        return resolveExecutablePath(name) != nil
    }

    // MARK: - Path Resolution

    private static var cachedShellPath: String?
    private static var shellPathResolved = false

    public static func fullShellPath() -> String {
        if shellPathResolved, let cached = cachedShellPath { return cached }
        shellPathResolved = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-i", "-c", "echo $PATH"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let resolved = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !resolved.isEmpty {
                    cachedShellPath = resolved
                    return resolved
                }
            }
        } catch {}

        let appPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var extras = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.cargo/bin",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let nvmVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for ver in nvmVersions.sorted().reversed() {
                extras.append("\(nvmDir)/\(ver)/bin")
            }
        }
        let augmented = (extras + appPath.split(separator: ":").map(String.init)).joined(separator: ":")
        cachedShellPath = augmented
        return augmented
    }

    private static func resolveExecutablePath(_ name: String) -> String? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var searchPaths = [
            "\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)",
            "\(home)/.cargo/bin/\(name)",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let nvmVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for ver in nvmVersions.sorted().reversed() {
                searchPaths.append("\(nvmDir)/\(ver)/bin/\(name)")
            }
        }
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }

        let shellProc = Process()
        shellProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shellProc.arguments = ["-l", "-i", "-c", "which \(name)"]
        let shellPipe = Pipe()
        shellProc.standardOutput = shellPipe
        shellProc.standardError = Pipe()
        do {
            try shellProc.run()
            shellProc.waitUntilExit()
            if shellProc.terminationStatus == 0 {
                let data = shellPipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {}

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        proc.environment = ["PATH": fullShellPath()]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
