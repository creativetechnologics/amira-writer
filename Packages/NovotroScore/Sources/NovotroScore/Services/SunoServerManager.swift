import Foundation

/// Manages the lifecycle of a local sandraschi/suno-mcp Python server process.
/// Allows Novotro Score to start, stop, and monitor the server without leaving the app.
@available(macOS 26.0, *)
@MainActor
final class SunoServerManager: @unchecked Sendable {

    // MARK: - Server State

    enum ServerState: String, Sendable {
        case stopped
        case starting
        case running
        case error
    }

    enum BootstrapStep: String, Sendable {
        case checking = "Checking installation..."
        case cloning = "Cloning suno-mcp..."
        case creatingVenv = "Creating Python virtual environment..."
        case installingDeps = "Installing Python dependencies..."
        case installingPlaywright = "Installing Chromium browser..."
        case configuring = "Configuring server..."
        case starting = "Starting server..."
        case done = "Setup complete!"
    }

    enum LoginState: String, Sendable {
        case notLoggedIn = "Not logged in"
        case loggingIn = "Logging in..."
        case loggedIn = "Logged in"
    }

    // MARK: - Published State

    var state: ServerState = .stopped
    var loginState: LoginState = .notLoggedIn
    var logs: [String] = []
    var errorMessage: String?
    var bootstrapStep: BootstrapStep?
    var isBootstrapping: Bool { bootstrapStep != nil && bootstrapStep != .done }

    /// Callback for state changes — used to bridge to @Observable ScoreStore
    var onStateChange: (@MainActor (ServerState, BootstrapStep?, String?) -> Void)?
    var onLoginStateChange: (@MainActor (LoginState) -> Void)?

    // MARK: - Configuration (persisted via UserDefaults)

    var serverDirectory: String {
        get { UserDefaults.standard.string(forKey: "sunoServerDirectory") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sunoServerDirectory") }
    }

    var autoStart: Bool {
        get { UserDefaults.standard.bool(forKey: "sunoAutoStart") }
        set { UserDefaults.standard.set(newValue, forKey: "sunoAutoStart") }
    }

    /// Optional explicit path to the python3 executable to use.
    /// When empty, auto-detection is used (checks venv, homebrew, system, pyenv, `which`).
    var pythonExecutablePath: String {
        get { UserDefaults.standard.string(forKey: "sunoPythonPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sunoPythonPath") }
    }

    /// The base URL to poll for readiness (read from the API client's setting).
    private var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "sunoServerURL") ?? "http://localhost:3000"
        let trimmed = stored
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "http://localhost:3000" : trimmed
    }

    /// Human-readable host:port for the currently configured local Suno server.
    var serverAddressDisplay: String {
        guard let components = URLComponents(string: baseURL) else {
            return "localhost:\(configuredServerPort)"
        }
        let host = components.host ?? "localhost"
        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }

    private var configuredServerPort: Int {
        guard let components = URLComponents(string: baseURL),
              let port = components.port,
              (1...65535).contains(port)
        else {
            return 3000
        }
        return port
    }

    // MARK: - Browser Data

    /// Persistent Playwright browser data directory — shared between login and suno-mcp server.
    var browserDataDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Novotro Score/suno-browser-data").path
    }

    /// Path to the extracted cookie JSON file used by the suno-mcp server.
    var cookieJarPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Novotro Score/suno-cookies.json").path
    }

    /// Whether extracted cookies exist on disk.
    var hasSavedCookies: Bool {
        FileManager.default.fileExists(atPath: cookieJarPath)
    }

    // MARK: - Private

    private static let maxLogLines = 200
    private var process: Process?
    private var loginProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readinessTask: Task<Void, Never>?

    // MARK: - Public API

    /// Whether the server directory is configured and looks like a suno-mcp clone.
    var isDirectoryConfigured: Bool {
        let dir = serverDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return false }
        // Check for requirements.txt or src/suno_mcp/ directory
        let hasRequirements = FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("requirements.txt"))
        let hasSunoMCP = FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("src/suno_mcp"))
        return hasRequirements || hasSunoMCP
    }

    /// Whether the suno-mcp server has been fully bootstrapped (cloned + dependencies installed).
    var isBootstrapped: Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sunoDir = appSupport.appendingPathComponent("Novotro Score/suno-mcp")
        let dir = serverDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let checkDir = dir.isEmpty ? sunoDir.path : dir
        return FileManager.default.fileExists(
            atPath: (checkDir as NSString).appendingPathComponent("src/suno_mcp")
        )
    }

    /// Start the suno-api server process.
    func start() {
        guard state == .stopped || state == .error else {
            NSLog("[SunoServer] Cannot start — already in state: %@", state.rawValue)
            return
        }

        // Validate directory
        let dir = serverDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else {
            errorMessage = "Server directory not set."
            state = .error
            onStateChange?(state, bootstrapStep, errorMessage)
            return
        }

        let hasSunoMCP = FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("src/suno_mcp"))
        let hasRequirements = FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("requirements.txt"))
        guard hasSunoMCP || hasRequirements else {
            errorMessage = "No suno-mcp project found in \(dir)"
            state = .error
            onStateChange?(state, bootstrapStep, errorMessage)
            return
        }

        // Find python3 executable — prefer user-specified path, then venv, then system
        let customPython = pythonExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pythonPath = resolvedPythonPath(customPath: customPython, serverDirectory: dir) else {
            errorMessage = "python3 not found. Set the Python Executable path in Suno settings, or install Python 3.10+."
            state = .error
            onStateChange?(state, bootstrapStep, errorMessage)
            return
        }

        // First, check if server is already running externally
        Task {
            if await checkServerReachable() {
                state = .running
                onStateChange?(state, bootstrapStep, errorMessage)
                appendLog("[Novotro Score] Server already running at \(baseURL)")
                return
            }

            // Start the process
            launchProcess(pythonPath: pythonPath, directory: dir)
        }
    }

    /// Stop the suno-api server process.
    func stop() {
        readinessTask?.cancel()
        readinessTask = nil

        guard let proc = process, proc.isRunning else {
            state = .stopped
            process = nil
            return
        }

        appendLog("[Novotro Score] Stopping server...")
        // Clear pipe handlers immediately to prevent stale reads during shutdown
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        proc.terminate()  // SIGTERM

        // Give it 3 seconds to exit gracefully, then SIGKILL
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if proc.isRunning {
                proc.interrupt()  // SIGINT as fallback
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    if proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                }
            }
            Task { @MainActor [weak self] in
                self?.state = .stopped
                self?.onStateChange?(self?.state ?? .stopped, self?.bootstrapStep, self?.errorMessage)
                self?.process = nil
                self?.appendLog("[Novotro Score] Server stopped.")
            }
        }
    }

    /// Restart the server (stop then start).
    func restart() {
        stop()
        // Wait long enough for stop()'s 3-second SIGTERM grace + SIGKILL to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.start()
        }
    }

    /// Clear the log buffer.
    func clearLogs() {
        logs.removeAll()
    }

    /// Auto-start if configured and enabled. Call from ScoreStore init.
    func autoStartIfNeeded() {
        guard autoStart, isDirectoryConfigured else { return }
        NSLog("[SunoServer] Auto-starting server...")
        start()
    }

    // MARK: - Login

    /// Import Suno login cookies from the user's Chrome browser.
    /// Uses only system Python + openssl (no pip packages required).
    /// Saves cookies as JSON for the suno-mcp server to load later.
    func importLoginFromChrome() {
        guard loginState != .loggingIn else { return }

        // Find any available python3
        guard let pythonPath = findExecutable("python3") ?? findExecutable("python") else {
            errorMessage = "python3 not found."
            appendLog("[Login] Cannot find Python executable.")
            return
        }

        let cookieOutputPath = cookieJarPath
        // Ensure parent directory exists
        let parentDir = (cookieOutputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let script = #"""
        import sqlite3, os, subprocess, shutil, tempfile, hashlib, json, sys

        def get_chrome_key():
            result = subprocess.run(
                ["security", "find-generic-password", "-w", "-s", "Chrome Safe Storage", "-a", "Chrome"],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                print("ERROR: Could not access Chrome Keychain. Approve the prompt and try again.", flush=True)
                return None
            password = result.stdout.strip().encode("utf-8")
            return hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, dklen=16)

        def decrypt_value(encrypted_value, key):
            if not encrypted_value or len(encrypted_value) < 4:
                return ""
            if encrypted_value[:3] != b"v10":
                return encrypted_value.decode("utf-8", errors="ignore")
            # AES-128-CBC via openssl (no pip packages needed)
            data = encrypted_value[3:]
            key_hex = key.hex()
            iv_hex = ("20" * 16)  # space character repeated
            proc = subprocess.run(
                ["openssl", "enc", "-aes-128-cbc", "-d", "-K", key_hex, "-iv", iv_hex, "-nopad"],
                input=data, capture_output=True
            )
            if proc.returncode != 0:
                return ""
            decrypted = proc.stdout
            if not decrypted:
                return ""
            # Remove PKCS7 padding
            padding = decrypted[-1]
            if isinstance(padding, int) and 0 < padding <= 16:
                decrypted = decrypted[:-padding]
            return decrypted.decode("utf-8", errors="ignore")

        def find_chrome_cookies():
            chrome_dir = os.path.expanduser("~/Library/Application Support/Google/Chrome")
            candidates = [os.path.join(chrome_dir, "Default", "Cookies")]
            for i in range(1, 10):
                candidates.append(os.path.join(chrome_dir, f"Profile {i}", "Cookies"))
            for path in candidates:
                if os.path.exists(path):
                    return path
            return None

        def extract_cookies(cookies_path, key):
            tmp = tempfile.mktemp(suffix=".db")
            shutil.copy2(cookies_path, tmp)
            conn = sqlite3.connect(tmp)
            cursor = conn.cursor()
            cursor.execute(
                "SELECT host_key, name, path, encrypted_value, expires_utc, is_secure, is_httponly "
                "FROM cookies WHERE host_key LIKE '%suno%' OR host_key LIKE '%clerk%'"
            )
            cookies = []
            for host, name, path, enc_val, expires, secure, httponly in cursor.fetchall():
                value = decrypt_value(enc_val, key)
                if value:
                    cookie = {
                        "domain": host, "name": name, "value": value, "path": path,
                        "secure": bool(secure), "httpOnly": bool(httponly),
                    }
                    if expires:
                        unix_ts = (expires / 1000000) - 11644473600
                        if unix_ts > 0:
                            cookie["expires"] = unix_ts
                    cookies.append(cookie)
            conn.close()
            os.unlink(tmp)
            return cookies

        def main():
            output_path = sys.argv[1]
            print("STEP: Getting Chrome encryption key (approve Keychain prompt if shown)...", flush=True)
            key = get_chrome_key()
            if key is None:
                return

            print("STEP: Finding Chrome cookies database...", flush=True)
            cookies_path = find_chrome_cookies()
            if not cookies_path:
                print("ERROR: Chrome cookies not found. Is Google Chrome installed?", flush=True)
                return

            profile = os.path.basename(os.path.dirname(cookies_path))
            print(f"STEP: Extracting Suno cookies from Chrome ({profile})...", flush=True)
            cookies = extract_cookies(cookies_path, key)
            if not cookies:
                print("ERROR: No Suno cookies found. Log into suno.com in Chrome first.", flush=True)
                return

            # Save cookies to JSON file
            with open(output_path, "w") as f:
                json.dump(cookies, f, indent=2)

            # List what we found
            domains = set(c["domain"] for c in cookies)
            print(f"LOGIN_SUCCESS: Extracted {len(cookies)} cookies from {', '.join(sorted(domains))}", flush=True)

        main()
        """#

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("novotro-suno-chrome-import.py")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)

        loginState = .loggingIn
        onLoginStateChange?(.loggingIn)
        appendLog("[Login] Importing login from Chrome...")

        launchLoginScript(
            pythonPath: pythonPath,
            scriptURL: scriptURL,
            browserData: cookieOutputPath,
            effectiveDir: FileManager.default.temporaryDirectory.path
        )
    }

    /// Shared helper for launching a login Python script and monitoring its output.
    private func launchLoginScript(
        pythonPath: String,
        scriptURL: URL,
        browserData: String,
        effectiveDir: String
    ) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptURL.path, browserData]
        proc.currentDirectoryURL = URL(fileURLWithPath: effectiveDir)

        var env = ProcessInfo.processInfo.environment
        let srcDir = (effectiveDir as NSString).appendingPathComponent("src")
        let existingPythonPath = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = existingPythonPath.isEmpty ? srcDir : "\(srcDir):\(existingPythonPath)"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    if line.contains("LOGIN_SUCCESS") {
                        self.loginState = .loggedIn
                        self.onLoginStateChange?(.loggedIn)
                        self.appendLog("[Login] Chrome login imported successfully!")
                        UserDefaults.standard.set(true, forKey: "sunoLoggedIn")
                    } else if line.hasPrefix("COOKIES_IMPORTED") {
                        self.loginState = .loggedIn
                        self.onLoginStateChange?(.loggedIn)
                        self.appendLog("[Login] \(line)")
                        UserDefaults.standard.set(true, forKey: "sunoLoggedIn")
                    } else if line.hasPrefix("ERROR:") {
                        self.appendLog("[Login] \(line)")
                        self.errorMessage = String(line.dropFirst(7))
                    } else if line.hasPrefix("STEP:") {
                        self.appendLog("[Login] \(line.dropFirst(6))")
                    } else if line.hasPrefix("PAGE_URL:") {
                        self.appendLog("[Login] Verified URL: \(line.dropFirst(10))")
                    }
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    self?.appendLog("[Login stderr] \(line)")
                }
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loginProcess = nil
                if self.loginState == .loggingIn {
                    self.loginState = .notLoggedIn
                    self.onLoginStateChange?(.notLoggedIn)
                    if terminated.terminationStatus != 0 {
                        self.appendLog("[Login] Import process exited with code \(terminated.terminationStatus)")
                    }
                }
                try? FileManager.default.removeItem(at: scriptURL)
            }
        }

        do {
            try proc.run()
            loginProcess = proc
        } catch {
            loginState = .notLoggedIn
            onLoginStateChange?(.notLoggedIn)
            appendLog("[Login] Failed to launch import: \(error.localizedDescription)")
        }
    }

    /// Open a visible Playwright browser to suno.com for OAuth login.
    /// Detects successful login (URL navigates to /create, /feed, etc.) and auto-closes.
    /// Browser data persists in `browserDataDirectory` so the suno-mcp server reuses the session.
    func loginToSuno() {
        guard isBootstrapped else {
            errorMessage = "Set up Suno first (bootstrap required)."
            appendLog("[Login] Cannot login — not bootstrapped.")
            return
        }
        guard loginState != .loggingIn else {
            appendLog("[Login] Already logging in...")
            return
        }

        let dir = serverDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDir: String
        if dir.isEmpty {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            effectiveDir = appSupport.appendingPathComponent("Novotro Score/suno-mcp").path
        } else {
            effectiveDir = dir
        }

        let customPython = pythonExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pythonPath = resolvedPythonPath(customPath: customPython, serverDirectory: effectiveDir) else {
            errorMessage = "python3 not found."
            appendLog("[Login] Cannot find Python executable.")
            return
        }

        let browserData = browserDataDirectory
        // Ensure browser data directory exists
        try? FileManager.default.createDirectory(
            atPath: browserData,
            withIntermediateDirectories: true
        )

        let script = #"""
        import asyncio, sys, signal

        async def main():
            user_data_dir = sys.argv[1]
            try:
                from playwright.async_api import async_playwright
            except ImportError as e:
                print(f"ERROR: {e}", flush=True)
                return

            browser_context = None
            try:
                pw = await async_playwright().start()
                browser_context = await pw.chromium.launch_persistent_context(
                    user_data_dir=user_data_dir,
                    headless=False,
                    viewport={"width": 1200, "height": 800},
                    args=[
                        "--no-first-run",
                        "--disable-blink-features=AutomationControlled",
                        "--disable-infobars",
                    ],
                )
            except Exception as e:
                print(f"ERROR: Failed to launch browser: {e}", flush=True)
                return

            page = browser_context.pages[0] if browser_context.pages else await browser_context.new_page()

            # Navigate to Suno - use try/except so browser stays open on failure
            try:
                await page.goto("https://suno.com", wait_until="domcontentloaded", timeout=30000)
            except Exception as e:
                print(f"ERROR: Navigation failed: {e}", flush=True)
                print("BROWSER_OPEN", flush=True)
                # Don't return — leave browser open so user can navigate manually

            print(f"BROWSER_OPEN", flush=True)
            print(f"PAGE_URL: {page.url}", flush=True)

            # Monitor for login success or browser close
            # The browser stays open until login is detected or user closes it
            logged_in = False
            try:
                while True:
                    # Check if browser/page was closed by user
                    try:
                        all_pages = browser_context.pages
                        if not all_pages:
                            print("BROWSER_CLOSED", flush=True)
                            break
                        current_page = all_pages[-1]  # Use the most recent page
                        url = current_page.url
                    except Exception:
                        print("BROWSER_CLOSED", flush=True)
                        break

                    # Check for logged-in URLs
                    logged_in_indicators = ["/create", "/feed", "/library", "/playlist/"]
                    # Exclude signin/signup pages that might contain these as subpaths
                    is_auth_page = "/signin" in url or "/signup" in url or "accounts.google" in url or "clerk" in url
                    if not is_auth_page and any(ind in url for ind in logged_in_indicators):
                        print("LOGIN_SUCCESS", flush=True)
                        logged_in = True
                        await asyncio.sleep(3)  # Brief pause so user sees it worked
                        break

                    await asyncio.sleep(1)

            except asyncio.CancelledError:
                pass
            except Exception as e:
                print(f"ERROR: Poll loop: {e}", flush=True)

            # Clean up
            try:
                if browser_context:
                    await browser_context.close()
            except Exception:
                pass
            try:
                await pw.stop()
            except Exception:
                pass

            if not logged_in:
                print("BROWSER_CLOSED", flush=True)

        asyncio.run(main())
        """#

        // Write script to temp file
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("novotro-suno-login.py")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)

        loginState = .loggingIn
        onLoginStateChange?(.loggingIn)
        appendLog("[Login] Opening browser for Suno login...")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptURL.path, browserData]
        proc.currentDirectoryURL = URL(fileURLWithPath: effectiveDir)

        // Set PYTHONPATH so Playwright can be found from the venv
        var env = ProcessInfo.processInfo.environment
        let srcDir = (effectiveDir as NSString).appendingPathComponent("src")
        let existingPythonPath = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = existingPythonPath.isEmpty ? srcDir : "\(srcDir):\(existingPythonPath)"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    if line.contains("LOGIN_SUCCESS") {
                        self.loginState = .loggedIn
                        self.onLoginStateChange?(.loggedIn)
                        self.appendLog("[Login] Login successful! Browser closing automatically.")
                        UserDefaults.standard.set(true, forKey: "sunoLoggedIn")
                    } else if line.contains("BROWSER_CLOSED") {
                        if self.loginState != .loggedIn {
                            self.loginState = .notLoggedIn
                            self.onLoginStateChange?(.notLoggedIn)
                            self.appendLog("[Login] Browser closed without completing login.")
                        }
                    } else if line.hasPrefix("BROWSER_OPEN") {
                        self.appendLog("[Login] Browser opened — please sign in to Suno.")
                    } else if line.hasPrefix("PAGE_URL:") {
                        self.appendLog("[Login] Navigated to: \(line.dropFirst(10))")
                    } else if line.hasPrefix("ERROR:") {
                        self.appendLog("[Login] \(line)")
                        self.errorMessage = String(line.dropFirst(7))
                    }
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    // Filter out noisy Playwright/Chromium stderr
                    if !line.contains("DevTools") && !line.contains("gpu_") {
                        self?.appendLog("[Login stderr] \(line)")
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loginProcess = nil
                if self.loginState == .loggingIn {
                    // Process exited without LOGIN_SUCCESS
                    self.loginState = .notLoggedIn
                    self.onLoginStateChange?(.notLoggedIn)
                    if terminated.terminationStatus != 0 {
                        self.appendLog("[Login] Login process exited with code \(terminated.terminationStatus)")
                    }
                }
                // Clean up temp script
                try? FileManager.default.removeItem(at: scriptURL)
            }
        }

        do {
            try proc.run()
            loginProcess = proc
        } catch {
            loginState = .notLoggedIn
            onLoginStateChange?(.notLoggedIn)
            appendLog("[Login] Failed to launch browser: \(error.localizedDescription)")
        }
    }

    /// Check if a previous login session exists (cookie jar or persistent browser data).
    func checkExistingLogin() {
        let hasCookieJar = hasSavedCookies
        let hasBrowserCookies = FileManager.default.fileExists(
            atPath: (browserDataDirectory as NSString).appendingPathComponent("Default/Cookies"))
        if (hasCookieJar || hasBrowserCookies) && UserDefaults.standard.bool(forKey: "sunoLoggedIn") {
            loginState = .loggedIn
            onLoginStateChange?(.loggedIn)
        }
    }

    // MARK: - Bootstrap

    /// First-run bootstrap: clone suno-mcp, create venv, install deps, install Playwright, configure, start.
    func bootstrap(progress: @escaping @Sendable (BootstrapStep) -> Void) async throws {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let novotroDir = appSupport.appendingPathComponent("Novotro Score")
        let sunoDir = novotroDir.appendingPathComponent("suno-mcp")

        // Step 1: Check existing
        bootstrapStep = .checking
        onStateChange?(state, bootstrapStep, errorMessage)
        progress(.checking)
        if fm.fileExists(atPath: sunoDir.appendingPathComponent("src/suno_mcp").path) {
            appendLog("[Bootstrap] Existing installation found, skipping clone/install")
        } else {
            // Step 2: Clone
            bootstrapStep = .cloning
            onStateChange?(state, bootstrapStep, errorMessage)
            progress(.cloning)
            try fm.createDirectory(at: novotroDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: sunoDir.path) {
                try fm.removeItem(at: sunoDir)
            }
            do {
                try await runProcess(
                    executable: "/usr/bin/git",
                    arguments: ["clone", "--depth", "1", "https://github.com/sandraschi/suno-mcp.git", sunoDir.path],
                    directory: novotroDir.path
                )
            } catch {
                try? fm.removeItem(at: sunoDir)
                throw error
            }

            // Step 3: Create venv
            bootstrapStep = .creatingVenv
            onStateChange?(state, bootstrapStep, errorMessage)
            progress(.creatingVenv)
            guard let python3 = findExecutable("python3") else {
                throw NSError(domain: "SunoBootstrap", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "python3 not found. Install Python 3.10+."])
            }
            try await runProcess(
                executable: python3,
                arguments: ["-m", "venv", "venv"],
                directory: sunoDir.path
            )

            // Step 4: Install deps
            bootstrapStep = .installingDeps
            onStateChange?(state, bootstrapStep, errorMessage)
            progress(.installingDeps)
            let pipPath = sunoDir.appendingPathComponent("venv/bin/pip").path
            try await runProcess(
                executable: pipPath,
                arguments: ["install", "-r", "requirements.txt"],
                directory: sunoDir.path
            )

            // Step 5: Install Playwright Chromium (large download, no timeout)
            bootstrapStep = .installingPlaywright
            onStateChange?(state, bootstrapStep, errorMessage)
            progress(.installingPlaywright)
            let venvPython = sunoDir.appendingPathComponent("venv/bin/python").path
            try await runProcess(
                executable: venvPython,
                arguments: ["-m", "playwright", "install", "chromium"],
                directory: sunoDir.path,
                timeout: nil
            )
        }

        // Step 6: Configure UserDefaults
        bootstrapStep = .configuring
        onStateChange?(state, bootstrapStep, errorMessage)
        progress(.configuring)
        serverDirectory = sunoDir.path
        autoStart = true
        UserDefaults.standard.set("http://localhost:3000", forKey: "sunoServerURL")

        // Step 7: Start server
        bootstrapStep = .starting
        onStateChange?(state, bootstrapStep, errorMessage)
        progress(.starting)
        start()
        try await waitForReady()

        bootstrapStep = .done
        onStateChange?(state, bootstrapStep, errorMessage)
        progress(.done)
    }

    /// Wait for the server to transition to `.running` state.
    /// Polls every 500ms, up to 30 seconds.
    private func waitForReady() async throws {
        for _ in 1...60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if state == .running { return }
            if state == .error {
                throw NSError(domain: "SunoServer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Server failed to start"])
            }
        }
        throw NSError(domain: "SunoServer", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Server did not become ready within 30 seconds"])
    }

    /// Start the server and wait for it to become ready (async bridge).
    func startAndWaitForReady() async throws {
        guard state != .running else { return }
        start()
        try await waitForReady()
    }

    /// Run a subprocess and throw on non-zero exit.
    private func runProcess(
        executable: String,
        arguments: [String],
        directory: String,
        timeout: TimeInterval? = 300
    ) async throws {
        // Use a class box so Swift 6 closures can safely mutate shared state across concurrent contexts.
        final class State: @unchecked Sendable {
            var stderrOutput = ""
            var resumed = false
            let lock = NSLock()
        }
        let sharedState = State()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.currentDirectoryURL = URL(fileURLWithPath: directory)

            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice

            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                sharedState.lock.withLock { sharedState.stderrOutput += text }
                Task { @MainActor [weak self] in
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        self?.appendLog("[Bootstrap] \(line)")
                    }
                }
            }

            proc.terminationHandler = { terminated in
                errPipe.fileHandleForReading.readabilityHandler = nil
                let alreadyResumed = sharedState.lock.withLock {
                    let r = sharedState.resumed
                    if !r { sharedState.resumed = true }
                    return r
                }
                guard !alreadyResumed else { return }
                if terminated.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let msg = sharedState.lock.withLock {
                        sharedState.stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    continuation.resume(throwing: NSError(
                        domain: "SunoBootstrap", code: Int(terminated.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Process '\(executable)' exited with code \(terminated.terminationStatus): \(msg.prefix(500))"]
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                let alreadyResumed = sharedState.lock.withLock {
                    let r = sharedState.resumed
                    if !r { sharedState.resumed = true }
                    return r
                }
                if !alreadyResumed {
                    continuation.resume(throwing: error)
                }
                return
            }

            if let timeout {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if proc.isRunning {
                        proc.terminate()
                        let alreadyResumed = sharedState.lock.withLock {
                            let r = sharedState.resumed
                            if !r { sharedState.resumed = true }
                            return r
                        }
                        if !alreadyResumed {
                            continuation.resume(throwing: NSError(
                                domain: "SunoBootstrap", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Process timed out after \(Int(timeout))s"]
                            ))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private: Process Launch

    private func launchProcess(pythonPath: String, directory: String) {
        state = .starting
        errorMessage = nil
        onStateChange?(state, bootstrapStep, errorMessage)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        // Launch the FastAPI HTTP server (main_api), not the stdio MCP server (main).
        // Using -c is reliable whether or not the package is pip-installed.
        proc.arguments = ["-c", "from suno_mcp.server import main_api; main_api()"]
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)

        // Inherit environment + set PYTHONPATH to include src/ directory
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        // suno-mcp's source is in src/ subdirectory
        let srcDir = (directory as NSString).appendingPathComponent("src")
        let existingPythonPath = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = existingPythonPath.isEmpty ? srcDir : "\(srcDir):\(existingPythonPath)"
        // Pass persistent browser data directory so suno-mcp reuses login session
        env["SUNO_BROWSER_DATA"] = browserDataDirectory
        env["SUNO_PORT"] = String(configuredServerPort)
        proc.environment = env

        // Set up pipes for stdout and stderr
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.outputPipe = outPipe
        self.errorPipe = errPipe

        // Read stdout asynchronously
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    self?.appendLog(line)
                }
            }
        }

        // Read stderr asynchronously
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    self?.appendLog("[stderr] \(line)")
                }
            }
        }

        // Handle process termination
        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.readinessTask?.cancel()
                self.readinessTask = nil
                let code = terminated.terminationStatus
                if self.state != .stopped {
                    // Unexpected termination
                    self.state = .error
                    self.errorMessage = "Server exited with code \(code)"
                    self.onStateChange?(self.state, self.bootstrapStep, self.errorMessage)
                    self.appendLog("[Novotro Score] Server exited (code \(code))")
                }
                self.process = nil
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.errorPipe?.fileHandleForReading.readabilityHandler = nil
            }
        }

        do {
            try proc.run()
            self.process = proc
            appendLog("[Novotro Score] Starting server (PID \(proc.processIdentifier))...")

            // Poll for readiness
            startReadinessPolling()
        } catch {
            state = .error
            errorMessage = "Failed to launch: \(error.localizedDescription)"
            onStateChange?(state, bootstrapStep, errorMessage)
            appendLog("[Novotro Score] Launch error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Readiness Polling

    /// Poll the baseURL every second until we get a response (up to 30 attempts).
    private func startReadinessPolling() {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            for attempt in 1...30 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

                guard let self else { return }
                if await self.checkServerReachable() {
                    await MainActor.run {
                        self.state = .running
                        self.onStateChange?(self.state, self.bootstrapStep, self.errorMessage)
                        UserDefaults.standard.set(self.baseURL, forKey: "sunoServerURL")
                        self.appendLog("[Novotro Score] Server is ready!")
                    }
                    return
                }

                // Check if process died during startup
                if let proc = await MainActor.run(body: { self.process }), !proc.isRunning {
                    return  // terminationHandler will set the error state
                }

                if attempt == 30 {
                    await MainActor.run {
                        self.state = .error
                        self.errorMessage = "Server did not become ready within 30 seconds."
                        self.onStateChange?(self.state, self.bootstrapStep, self.errorMessage)
                        self.appendLog("[Novotro Score] Timed out waiting for server readiness.")
                    }
                }
            }
        }
    }

    /// Check if the server responds at the base URL.
    private nonisolated func checkServerReachable() async -> Bool {
        let urlString = await MainActor.run { self.baseURL }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 200, http.statusCode < 500 {
                return true  // Server is responding (4xx means it's up; 5xx means broken)
            }
        } catch {
            // Connection refused, timeout, etc. — server not ready
        }
        return false
    }

    // MARK: - Private: Python Detection

    /// Resolve which python executable to use.
    /// Priority: (1) user-specified custom path, (2) venv inside server directory, (3) system auto-detection.
    private func resolvedPythonPath(customPath: String, serverDirectory: String) -> String? {
        // 1. User-specified path
        if !customPath.isEmpty && FileManager.default.isExecutableFile(atPath: customPath) {
            NSLog("[SunoServer] Using custom Python: %@", customPath)
            return customPath
        }

        // 2. Virtual environment inside the server directory (most reliable for package isolation)
        for venvName in ["venv", ".venv"] {
            for execName in ["python3", "python"] {
                let venvPath = (serverDirectory as NSString)
                    .appendingPathComponent("\(venvName)/bin/\(execName)")
                if FileManager.default.isExecutableFile(atPath: venvPath) {
                    NSLog("[SunoServer] Using venv Python: %@", venvPath)
                    return venvPath
                }
            }
        }

        // 3. System-wide auto-detection
        return findExecutable("python3") ?? findExecutable("python")
    }

    /// Search common system paths for a given executable name.
    private func findExecutable(_ name: String) -> String? {
        let searchPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try pyenv paths
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let pyenvBase = (homeDir as NSString).appendingPathComponent(".pyenv/shims")
        let pyenvPath = (pyenvBase as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: pyenvPath) {
            return pyenvPath
        }

        // Fallback: try `which` via a quick Process call
        return whichExecutable(name)
    }

    /// Run `which <name>` to find an executable on PATH.
    private func whichExecutable(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = result, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // which not available or failed
        }
        return nil
    }

    // MARK: - Private: Logging

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > Self.maxLogLines {
            logs.removeFirst(logs.count - Self.maxLogLines)
        }
    }
}
