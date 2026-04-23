import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Error Type

enum SunoCLIError: Error, LocalizedError {
    case notInstalled(path: String)
    case captcha(message: String)       // exit code 2
    case authFailure(message: String)   // exit code 3
    case uiDrift(message: String)       // exit code 4
    case runtime(message: String)       // exit code 1 OR {"ok": false}
    case invalidJSON(raw: String)
    case processLaunchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let path):
            return "Suno CLI not found at \(path). Rebuild and redeploy the app bundle so it includes the bundled Suno runtime, or rebuild the external dev venv with bash \"/Volumes/Programming/Amira Writer/Scripts/setup-suno-cli.sh\"."
        case .captcha(let message):
            return "Suno CAPTCHA required: \(message)"
        case .authFailure(let message):
            return "Suno auth failure — re-login required: \(message)"
        case .uiDrift(let message):
            return "Suno UI changed (selector drift): \(message)"
        case .runtime(let message):
            return "Suno CLI error: \(message)"
        case .invalidJSON(let raw):
            return "Suno CLI returned invalid JSON: \(raw.prefix(200))"
        case .processLaunchFailed(let error):
            return "Failed to launch Suno CLI: \(error.localizedDescription)"
        }
    }
}

// MARK: - Result Types

struct SunoSelftestResult: Sendable {
    let ok: Bool
    let loggedIn: Bool
    let formFieldsVisible: Bool
    let raw: [String: String]   // serialisable subset of the top-level dict
}

struct SunoGenerateResult: Sendable {
    let songIDs: [String]       // Preferred A + B variants
    let allCapturedSongIDs: [String]
    let title: String?
    let message: String
}

struct SunoDownloadResult: Sendable {
    let path: String
    let message: String
}

// MARK: - Runner

@available(macOS 26.0, *)
@MainActor
final class SunoCLIRunner {

    // MARK: - Config (UserDefaults)

    static let bundledCLIRelativePath = "SunoCLI/suno_cli/.venv/bin/suno"
    static let bundledPlaywrightBrowsersRelativePath = "SunoCLI/.ms-playwright"
    static let localMountedCLIPath = "/Volumes/Programming/SunoSkill/suno_cli/.venv/bin/suno"
    static let sharedMountedCLIPath = "/Volumes/Storage VIII/Programming/SunoSkill/suno_cli/.venv/bin/suno"

    /// Bundled-or-mounted Playwright browser cache candidates. The app prefers
    /// the bundle-local copy, then falls back to the device-local/shared mounts.
    /// Corresponds to `PLAYWRIGHT_BROWSERS_PATH` consumed by Playwright.
    static let localMountedPlaywrightBrowsersPath = "/Volumes/Programming/SunoSkill/.ms-playwright"
    static let sharedMountedPlaywrightBrowsersPath = "/Volumes/Storage VIII/Programming/SunoSkill/.ms-playwright"

    static let defaultProfileDir: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Novotro Score/suno-browser-data").path
    }()

    private var configuredCLIPathOverride: String? {
        let stored = (UserDefaults.standard.string(forKey: "sunoCLIPath") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? nil : stored
    }

    private static func bundledResourcePath(_ relativePath: String) -> String? {
        Bundle.main.resourceURL?.appendingPathComponent(relativePath).path
    }

    private static func firstExistingExecutable(in candidates: [String?]) -> String? {
        let fileManager = FileManager.default
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func firstExistingDirectory(in candidates: [String?]) -> String? {
        let fileManager = FileManager.default
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private var bundledCLIPath: String? {
        Self.bundledResourcePath(Self.bundledCLIRelativePath)
    }

    private var bundledPlaywrightBrowsersPath: String? {
        Self.bundledResourcePath(Self.bundledPlaywrightBrowsersRelativePath)
    }

    private var fallbackCLIPathCandidates: [String?] {
        [
            Self.localMountedCLIPath,
            Self.sharedMountedCLIPath,
        ]
    }

    private var fallbackPlaywrightPathCandidates: [String?] {
        [
            Self.localMountedPlaywrightBrowsersPath,
            Self.sharedMountedPlaywrightBrowsersPath,
        ]
    }

    var cliPath: String {
        get {
            let resolved = Self.firstExistingExecutable(
                in: [configuredCLIPathOverride, bundledCLIPath] + fallbackCLIPathCandidates
            )
            return resolved
                ?? configuredCLIPathOverride
                ?? bundledCLIPath
                ?? fallbackCLIPathCandidates.compactMap { $0 }.first
                ?? Self.localMountedCLIPath
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: "sunoCLIPath")
            } else {
                UserDefaults.standard.set(trimmed, forKey: "sunoCLIPath")
            }
        }
    }

    var playwrightBrowsersPath: String {
        let resolved = Self.firstExistingDirectory(
            in: [bundledPlaywrightBrowsersPath] + fallbackPlaywrightPathCandidates
        )
        return resolved
            ?? bundledPlaywrightBrowsersPath
            ?? fallbackPlaywrightPathCandidates.compactMap { $0 }.first
            ?? Self.localMountedPlaywrightBrowsersPath
    }

    var profileDir: String {
        get {
            let stored = (UserDefaults.standard.string(forKey: "sunoProfileDir") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? Self.defaultProfileDir : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "sunoProfileDir") }
    }

    // MARK: - Observable UI State

    var isRunningCommand = false
    private(set) var logs: [String] = []    // stderr tail, last 200 lines, rolling
    var lastSelftestResult: SunoSelftestResult?

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: cliPath)
    }

    // MARK: - High-level verbs

    func generateCover(
        source: String,
        style: String,
        title: String? = nil,
        lyrics: String? = nil,
        excludeStyles: String? = nil,
        weirdness: Int = 30,
        styleInfluence: Int = 0,
        audioInfluence: Int = 95,
        headless: Bool = true,
        wait: Bool = true
    ) async throws -> SunoGenerateResult {
        var args: [String] = ["generate", "cover", "--source", source, "--style", style]
        if let title, !title.isEmpty { args += ["--title", title] }
        if let lyrics, !lyrics.isEmpty { args += ["--lyrics-text", lyrics] }
        if let excludeStyles, !excludeStyles.isEmpty { args += ["--negative", excludeStyles] }
        args += [headless ? "--headless" : "--visible"]
        args += ["--weirdness", "\(weirdness)"]
        args += ["--style-influence", "\(styleInfluence)"]
        args += ["--audio-influence", "\(audioInfluence)"]
        args += [wait ? "--wait" : "--no-wait"]

        let timeout: TimeInterval = wait ? 1800 : 300
        let json = try await runJSON(args, timeoutSeconds: timeout)
        return try parseGenerateResult(from: json)
    }

    func generateOriginal(
        prompt: String,
        style: String,
        title: String? = nil,
        instrumental: Bool = false,
        lyrics: String? = nil,
        headless: Bool = true,
        wait: Bool = true
    ) async throws -> SunoGenerateResult {
        var args: [String] = ["generate", "original", "--prompt", prompt, "--style", style]
        if let title, !title.isEmpty { args += ["--title", title] }
        if instrumental { args += ["--instrumental"] }
        if let lyrics, !lyrics.isEmpty { args += ["--lyrics-text", lyrics] }
        args += [headless ? "--headless" : "--visible"]
        args += [wait ? "--wait" : "--no-wait"]

        let timeout: TimeInterval = wait ? 1800 : 300
        let json = try await runJSON(args, timeoutSeconds: timeout)
        return try parseGenerateResult(from: json)
    }

    func downloadSong(
        songID: String,
        format: String,
        out: String
    ) async throws -> SunoDownloadResult {
        let args: [String] = ["download", "song", "--song-id", songID, "--format", format, "--out", out]
        let json = try await runJSON(args, timeoutSeconds: 300)
        guard let path = json["path"] as? String else {
            throw SunoCLIError.runtime(message: "download response missing 'path' field")
        }
        let message = (json["message"] as? String) ?? "Downloaded"
        return SunoDownloadResult(path: path, message: message)
    }

    func waitForSongs(_ songIDs: [String], timeoutSeconds: Int = 600) async throws {
        var args: [String] = ["wait"]
        for id in songIDs { args += ["--song-id", id] }
        args += ["--timeout", "\(timeoutSeconds)"]
        let json = try await runJSON(args, timeoutSeconds: TimeInterval(timeoutSeconds + 60))
        if let results = json["results"] as? [[String: Any]] {
            let failed = results.filter { ($0["ok"] as? Bool) == false }
            if !failed.isEmpty {
                let ids = failed.compactMap { $0["song_id"] as? String }.joined(separator: ", ")
                throw SunoCLIError.runtime(message: "Songs failed to complete: \(ids)")
            }
        }
    }

    func browserOpen(headless: Bool = true) async throws {
        let args: [String] = ["browser", "open", headless ? "--headless" : "--visible"]
        _ = try await runJSON(args, timeoutSeconds: 60)
    }

    func browserClose() async throws {
        _ = try await runJSON(["browser", "close"], timeoutSeconds: 60)
    }

    func browserStatus() async throws -> [String: Any] {
        return try await runJSON(["browser", "status"], timeoutSeconds: 60)
    }

    func openLoginBrowser() async throws -> String {
        #if canImport(AppKit)
        let browserAppURL = try resolvedLoginBrowserAppURL()
        let profileURL = URL(fileURLWithPath: profileDir, isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true, attributes: nil)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [
            "--user-data-dir=\(profileURL.path)",
            "--no-first-run",
            "--new-window",
            "https://suno.com/create",
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: browserAppURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return browserAppURL.deletingPathExtension().lastPathComponent
        #else
        throw SunoCLIError.runtime(message: "Visible Suno login browser is only available on macOS.")
        #endif
    }

    func selftest() async throws -> SunoSelftestResult {
        let json = try await runJSON(["selftest"], timeoutSeconds: 60)
        let result = parseSelftestResult(from: json)
        lastSelftestResult = result
        return result
    }

    private func resolvedLoginBrowserAppURL() throws -> URL {
        // Prefer a user-installed browser for visible login flows. On macOS 26.4.1
        // the bundled Playwright Chrome-for-Testing build can launch and then crash,
        // while a normal system Chrome/Chromium app remains stable with the same
        // `--user-data-dir` persistent profile.
        let candidates = systemLoginBrowserAppURLs + bundledLoginBrowserAppURLs
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw SunoCLIError.runtime(message: "Could not locate a Chromium-compatible browser bundle for Suno login.")
    }

    private var bundledLoginBrowserAppURLs: [URL] {
        let fileManager = FileManager.default
        let browserRoots = [bundledPlaywrightBrowsersPath].compactMap { $0 } + fallbackPlaywrightPathCandidates.compactMap { $0 }
        var seen: Set<String> = []
        var results: [URL] = []

        for browserRoot in browserRoots {
            let rootURL = URL(fileURLWithPath: browserRoot, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name == "Google Chrome for Testing.app" || name == "Chromium.app" else { continue }
                if seen.insert(url.path).inserted {
                    results.append(url)
                }
            }
        }

        return results
    }

    private var systemLoginBrowserAppURLs: [URL] {
        [
            "/Applications/Google Chrome.app",
            "/Applications/Chromium.app",
            "/Applications/Brave Browser.app",
            "/Applications/Microsoft Edge.app",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Private: Result Parsers

    private func parseGenerateResult(from json: [String: Any]) throws -> SunoGenerateResult {
        let songIDs = (json["song_ids"] as? [String]) ?? []
        let allCapturedSongIDs = (json["all_captured_ids"] as? [String])
            ?? (json["allCapturedSongIDs"] as? [String])
            ?? songIDs
        let title = json["title"] as? String
        let message = (json["message"] as? String) ?? ""
        return SunoGenerateResult(
            songIDs: songIDs,
            allCapturedSongIDs: allCapturedSongIDs,
            title: title,
            message: message
        )
    }

    private func parseSelftestResult(from json: [String: Any]) -> SunoSelftestResult {
        let ok = (json["ok"] as? Bool) ?? false
        var loggedIn = false
        var formFieldsVisible = false
        if let checks = json["checks"] as? [[String: Any]] {
            for check in checks {
                let name = check["name"] as? String ?? ""
                let checkOK = (check["ok"] as? Bool) ?? false
                if name == "logged_in" { loggedIn = checkOK }
                if name == "form_fields_visible" { formFieldsVisible = checkOK }
            }
        }
        // Distill into a string-safe dict for the Sendable requirement
        var raw: [String: String] = [:]
        for (k, v) in json { raw[k] = "\(v)" }
        return SunoSelftestResult(ok: ok, loggedIn: loggedIn, formFieldsVisible: formFieldsVisible, raw: raw)
    }

    // MARK: - Core subprocess runner

    /// Spawn `cliPath --profile-dir <profileDir> --json <args...>`, capture stdout + stderr,
    /// parse the LAST JSON line of stdout, map exit code to SunoCLIError.
    private func runJSON(
        _ args: [String],
        timeoutSeconds: TimeInterval = 1200
    ) async throws -> [String: Any] {
        guard isInstalled else {
            throw SunoCLIError.notInstalled(path: cliPath)
        }

        isRunningCommand = true
        defer { isRunningCommand = false }

        let resolvedCLIPath = cliPath
        let resolvedProfileDir = profileDir

        // Capture for nonisolated use in the continuation
        let capturedLogAppender: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor [weak self] in
                self?.appendLog(line)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedCLIPath)
            // Global flags first: --profile-dir and --json, then subcommand args
            process.arguments = ["--profile-dir", resolvedProfileDir, "--json"] + args

            var env = ProcessInfo.processInfo.environment
            let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            let currentPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
            env["NOVOTRO_SCORE"] = "1"
            // Point Playwright at the bundled browser cache first, then at the
            // available mounted SunoSkill cache, so the synced app copy works
            // on both Gary's Macs without a server-only absolute path.
            if env["PLAYWRIGHT_BROWSERS_PATH"] == nil {
                env["PLAYWRIGHT_BROWSERS_PATH"] = playwrightBrowsersPath
            }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Collect stdout
            final class OutputBox: @unchecked Sendable {
                let lock = NSLock()
                var stdoutLines: [String] = []
                var stderrLines: [String] = []
                var resumed = false
            }
            let box = OutputBox()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                box.lock.withLock {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        box.stdoutLines.append(line)
                    }
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                box.lock.withLock {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        box.stderrLines.append(line)
                    }
                }
                // Stream stderr to UI logs
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    capturedLogAppender(line)
                }
            }

            process.terminationHandler = { terminated in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let shouldResume = box.lock.withLock {
                    if box.resumed { return false }
                    box.resumed = true
                    return true
                }
                guard shouldResume else { return }

                let exitCode = Int(terminated.terminationStatus)
                let stdoutLines = box.lock.withLock { box.stdoutLines }
                let stderrLines = box.lock.withLock { box.stderrLines }

                // Find last non-empty line that parses as JSON
                let jsonLine = stdoutLines.reversed().first { line in
                    guard let data = line.data(using: .utf8),
                          let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return false }
                    return true
                }

                let parsed: [String: Any]?
                if let jsonLine,
                   let data = jsonLine.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    parsed = obj
                } else {
                    parsed = nil
                }

                let okFlag = parsed?["ok"] as? Bool
                let cliMessage = (parsed?["message"] as? String)
                    ?? stderrLines.suffix(5).joined(separator: " ")

                // Map exit code → error
                switch exitCode {
                case 0:
                    if okFlag == false {
                        continuation.resume(throwing: SunoCLIError.runtime(message: cliMessage))
                    } else if let parsed {
                        continuation.resume(returning: parsed)
                    } else {
                        let raw = stdoutLines.joined(separator: "\n")
                        continuation.resume(throwing: SunoCLIError.invalidJSON(raw: raw))
                    }
                case 2:
                    continuation.resume(throwing: SunoCLIError.captcha(message: cliMessage))
                case 3:
                    continuation.resume(throwing: SunoCLIError.authFailure(message: cliMessage))
                case 4:
                    continuation.resume(throwing: SunoCLIError.uiDrift(message: cliMessage))
                default:
                    // exit 1 or anything else
                    continuation.resume(throwing: SunoCLIError.runtime(message: cliMessage))
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let shouldResume = box.lock.withLock {
                    if box.resumed { return false }
                    box.resumed = true
                    return true
                }
                if shouldResume {
                    continuation.resume(throwing: SunoCLIError.processLaunchFailed(error))
                }
                return
            }

            // Timeout watchdog
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                    let shouldResume = box.lock.withLock {
                        if box.resumed { return false }
                        box.resumed = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(throwing: SunoCLIError.runtime(
                            message: "Timed out after \(Int(timeoutSeconds))s"
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Private: Logging

    private static let maxLogLines = 200

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > Self.maxLogLines {
            logs.removeFirst(logs.count - Self.maxLogLines)
        }
    }
}

// MARK: - NSLock convenience (local to this file)

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
