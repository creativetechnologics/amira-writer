import Foundation

// MARK: - LORA File Logger
//
// Writes lifecycle + command output to `~/Library/Logs/Amira/runpod-lora.log`
// so you can `tail -f` it while training runs. Before this existed, all
// RunPod failures happened silently and the only signal was a generic
// "Failed to upload images to pod" message with no cause — now every ssh /
// scp invocation, every error, and every state transition is on disk.
//
// Thread-safe via a serial dispatch queue; safe to call from any actor.
final class LORALogger: @unchecked Sendable {
    static let shared = LORALogger()

    let logFileURL: URL
    private let queue = DispatchQueue(label: "amira.lora.logger")
    private let formatter: DateFormatter

    private init() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        self.logFileURL = logDir.appendingPathComponent("runpod-lora.log")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = df
    }

    func log(_ message: String, level: String = "INFO") {
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] [\(level)] \(message)\n"
        queue.async { [logFileURL] in
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path),
                   let handle = try? FileHandle(forWritingTo: logFileURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: logFileURL, options: .atomic)
                }
            }
            NSLog("[LORA] \(message)")
        }
    }

    func logSection(_ title: String) {
        log("═══ \(title) ═══")
    }
}

@available(macOS 26.0, *)
@MainActor
final class RunPodLORAService: ObservableObject {
    static let shared = RunPodLORAService()
    private let runPodAccountService = RunPodAccountService()

    @Published var currentJob: LORATrainingModels.TrainingJob? {
        didSet {
            if let currentJob {
                podStatus = currentJob.status
            } else if podStatus != .inactive {
                podStatus = .inactive
            }
            persistCurrentJobSnapshot()
        }
    }
    @Published var queuedJobs: [LORATrainingModels.QueuedTrainingJob] = [] {
        didSet { persistQueuedJobsSnapshot() }
    }
    @Published var recentJobs: [LORATrainingModels.TrainingJob] = [] {
        didSet { persistRecentJobsSnapshot() }
    }
    @Published var podStatus: LORATrainingModels.PodStatus = .inactive

    /// Path to the on-disk log file — surfaced to the UI so Gary can open/tail it.
    var logFilePath: String { LORALogger.shared.logFileURL.path }
    var hasHuggingFaceToken: Bool { (try? Self.loadLocalHuggingFaceToken()) != nil }

    private var apiKey: String = ""
    private var watchdogTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var queueRunnerTask: Task<Void, Never>?
    private var activeAnimateURL: URL?
    private let baseURL = "https://api.runpod.io/v2"
    private let graphqlURL = "https://api.runpod.io/graphql"

    private struct LocalSSHKeyPair: Sendable {
        let privateKeyPath: String
        let publicKey: String
        let publicKeyPath: String
    }

    private struct LocalToken: Sendable {
        let value: String
        let sourceDescription: String
    }

    private struct RemoteTrainingSnapshot: Sendable {
        enum ProcessStatus: Sendable {
            case running
            case exited(exitCode: String?)
            case missingPID
            case notStarted
        }

        var processStatus: ProcessStatus
        var progressLines: [String]
        var outputPaths: [String]
    }

    private init() {
        loadAPIKey()
        queuedJobs = loadQueuedJobsFromDisk()
        recentJobs = loadRecentJobsFromDisk()
        if let restoredJob = loadPersistedJobFromDisk() {
            currentJob = restoredJob
            podStatus = restoredJob.status
            if restoredJob.status.isActive {
                restoreTask = Task { @MainActor in
                    await resumePersistedJobIfNeeded()
                }
            }
        } else if let heartbeatJob = loadHeartbeatRecoveryJobFromDisk() {
            currentJob = heartbeatJob
            podStatus = heartbeatJob.status
            restoreTask = Task { @MainActor in
                await resumePersistedJobIfNeeded()
            }
        }
        Task { @MainActor in
            self.scheduleQueuedJobLaunchIfNeeded()
        }
    }

    private var persistedJobURL: URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        return baseDirectory.appendingPathComponent("active-runpod-lora-job.json")
    }

    private var watchdogHeartbeatURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("amira-runpod-watchdog.json")
    }

    private var queuedJobsURL: URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        return baseDirectory.appendingPathComponent("queued-runpod-lora-jobs.json")
    }

    private var recentJobsURL: URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        return baseDirectory.appendingPathComponent("recent-runpod-lora-jobs.json")
    }

    private func loadPersistedJobFromDisk() -> LORATrainingModels.TrainingJob? {
        guard FileManager.default.fileExists(atPath: persistedJobURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: persistedJobURL)
            return try JSONDecoder().decode(LORATrainingModels.TrainingJob.self, from: data)
        } catch {
            LORALogger.shared.log("Failed to load persisted RunPod job: \(error.localizedDescription)", level: "WARN")
            return nil
        }
    }

    private func loadHeartbeatRecoveryJobFromDisk() -> LORATrainingModels.TrainingJob? {
        guard FileManager.default.fileExists(atPath: watchdogHeartbeatURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: watchdogHeartbeatURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let podID = json["podID"] as? String,
                  !podID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            var config = LORATrainingModels.TrainingConfig()
            config.preset = .high
            return LORATrainingModels.TrainingJob(
                characterName: "Recovered RunPod Training",
                characterSlug: "",
                triggerWord: "",
                config: config,
                animateDirectoryPath: activeAnimateURL?.path,
                podID: podID,
                status: .training,
                currentStep: 0,
                totalSteps: LORATrainingModels.TrainingPreset.enforcedSteps,
                errorMessage: "Recovered from watchdog heartbeat",
                startedAt: nil,
                completedAt: nil,
                outputLORAPath: nil
            )
        } catch {
            LORALogger.shared.log("Failed to load RunPod watchdog heartbeat: \(error.localizedDescription)", level: "WARN")
            return nil
        }
    }

    private func loadQueuedJobsFromDisk() -> [LORATrainingModels.QueuedTrainingJob] {
        guard FileManager.default.fileExists(atPath: queuedJobsURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: queuedJobsURL)
            return try JSONDecoder().decode([LORATrainingModels.QueuedTrainingJob].self, from: data)
        } catch {
            LORALogger.shared.log("Failed to load queued LoRA jobs: \(error.localizedDescription)", level: "WARN")
            return []
        }
    }

    private func loadRecentJobsFromDisk() -> [LORATrainingModels.TrainingJob] {
        guard FileManager.default.fileExists(atPath: recentJobsURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: recentJobsURL)
            return try JSONDecoder().decode([LORATrainingModels.TrainingJob].self, from: data)
        } catch {
            LORALogger.shared.log("Failed to load recent LoRA jobs: \(error.localizedDescription)", level: "WARN")
            return []
        }
    }

    private func persistCurrentJobSnapshot() {
        guard let currentJob else {
            try? FileManager.default.removeItem(at: persistedJobURL)
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(currentJob)
            try data.write(to: persistedJobURL, options: .atomic)
        } catch {
            LORALogger.shared.log("Failed to persist RunPod job: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func persistQueuedJobsSnapshot() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(queuedJobs)
            try data.write(to: queuedJobsURL, options: .atomic)
        } catch {
            LORALogger.shared.log("Failed to persist queued LoRA jobs: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func persistRecentJobsSnapshot() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recentJobs)
            try data.write(to: recentJobsURL, options: .atomic)
        } catch {
            LORALogger.shared.log("Failed to persist recent LoRA jobs: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func mutateCurrentJob(_ mutate: (inout LORATrainingModels.TrainingJob) -> Void) {
        guard var job = currentJob else { return }
        mutate(&job)
        currentJob = job
    }

    private func appendRecentJob(_ job: LORATrainingModels.TrainingJob) {
        recentJobs.removeAll { $0.id == job.id }
        recentJobs.insert(job, at: 0)
    }

    private func archiveCurrentJobIfNeeded() {
        guard let job = currentJob, !job.status.isActive else { return }
        appendRecentJob(job)
        currentJob = nil
    }

    private var canAdvanceQueuePastCurrentJob: Bool {
        guard let job = currentJob else { return true }
        guard !job.status.isActive else { return false }
        guard job.status != .error else { return false }
        guard job.errorMessage == nil else { return false }
        return job.outputLORAPath != nil
    }

    private func scheduleQueuedJobLaunchIfNeeded() {
        guard queueRunnerTask == nil else { return }
        guard !queuedJobs.isEmpty else { return }
        guard canAdvanceQueuePastCurrentJob else { return }

        archiveCurrentJobIfNeeded()
        guard let nextJob = queuedJobs.first else { return }

        queueRunnerTask = Task { @MainActor in
            defer { queueRunnerTask = nil }
            queuedJobs.removeFirst()
            do {
                try await startTraining(
                    config: nextJob.config,
                    characterName: nextJob.characterName,
                    characterSlug: nextJob.characterSlug,
                    imagePaths: nextJob.imagePaths,
                    animateURL: URL(fileURLWithPath: nextJob.animateDirectoryPath, isDirectory: true),
                    autoStartQueuedJobsAfterSuccess: true,
                    existingJobID: nextJob.id,
                    onProgress: { _ in }
                )
            } catch {
                // The failed run is already surfaced through currentJob; leave the queue paused.
            }
        }
    }

    func clearCurrentJob() {
        restoreTask?.cancel()
        restoreTask = nil
        stopWatchdog()
        currentJob = nil
        scheduleQueuedJobLaunchIfNeeded()
    }

    func clearRecentJob(_ jobID: UUID) {
        recentJobs.removeAll { $0.id == jobID }
    }

    func removeQueuedJob(_ jobID: UUID) {
        queuedJobs.removeAll { $0.id == jobID }
    }

    var hasActiveJob: Bool { currentJob?.status.isActive == true }

    func enqueueTraining(
        config: LORATrainingModels.TrainingConfig,
        characterName: String,
        characterSlug: String,
        imagePaths: [String],
        animateURL: URL
    ) throws {
        for path in imagePaths where !FileManager.default.fileExists(atPath: path) {
            throw LORAError.imagePathMissing(path: path)
        }

        var persistedConfig = config
        persistedConfig.selectedImagePaths = imagePaths
        let queuedJob = LORATrainingModels.QueuedTrainingJob(
            characterName: characterName,
            characterSlug: characterSlug,
            triggerWord: config.triggerWord.isEmpty
                ? LORATrainingModels.generateTriggerWord(for: characterName)
                : config.triggerWord,
            config: persistedConfig,
            imagePaths: imagePaths,
            animateDirectoryPath: animateURL.path
        )
        queuedJobs.append(queuedJob)
        LORALogger.shared.log(
            "Queued training: \(characterName) trigger=\(queuedJob.triggerWord) model=\(persistedConfig.baseModel.rawValue) images=\(imagePaths.count)",
            level: "INFO"
        )
        scheduleQueuedJobLaunchIfNeeded()
    }

    func setActiveAnimateURL(_ url: URL?) {
        activeAnimateURL = url
        guard let url else { return }
        mutateCurrentJob { job in
            if job.animateDirectoryPath == nil || job.animateDirectoryPath?.isEmpty == true {
                job.animateDirectoryPath = url.path
            }
            enrichRecoveredJobMetadata(&job, animateURL: url)
        }
        if restoreTask == nil, currentJob?.status.isActive == true {
            restoreTask = Task { @MainActor in
                await resumePersistedJobIfNeeded()
            }
        }
    }

    // MARK: - API Key (Keychain-based, works on any machine)

    func loadAPIKey() {
        apiKey = RunPodCredentialStore().loadAPIKey()
    }

    func setAPIKey(_ key: String) {
        RunPodCredentialStore().saveAPIKey(key)
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    // MARK: - Pod Lifecycle

    /// Resolves the local SSH keypair used by both LORA Maker and Amira Writer.
    /// We must inject the public key into RunPod *and* force ssh/scp to use the
    /// matching private key; otherwise the pod authorizes one key while macOS may
    /// offer a different identity and fail authentication.
    private static func loadLocalSSHKeyPair() throws -> LocalSSHKeyPair {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            (
                privateURL: home.appendingPathComponent(".ssh/id_ed25519"),
                publicURL: home.appendingPathComponent(".ssh/id_ed25519.pub")
            ),
            (
                privateURL: home.appendingPathComponent(".ssh/id_rsa"),
                publicURL: home.appendingPathComponent(".ssh/id_rsa.pub")
            )
        ]
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.privateURL.path) else { continue }
            if let data = try? Data(contentsOf: candidate.publicURL),
               let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return LocalSSHKeyPair(
                    privateKeyPath: candidate.privateURL.path,
                    publicKey: text,
                    publicKeyPath: candidate.publicURL.path
                )
            }
        }
        throw LORAError.podCreationFailed(detail: "No SSH public key found at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub — cannot launch a RunPod pod without one (the pytorch image requires PUBLIC_KEY env var to start sshd).")
    }

    private static func loadLocalHuggingFaceToken() throws -> LocalToken {
        let env = ProcessInfo.processInfo.environment
        let envCandidates = [
            "HF_TOKEN",
            "HUGGINGFACE_HUB_TOKEN",
            "HUGGINGFACE_TOKEN",
            "HUGGING_FACE_HUB_TOKEN"
        ]
        for key in envCandidates {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return LocalToken(value: value, sourceDescription: "env:\(key)")
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let fileCandidates = [
            home.appendingPathComponent(".lora-maker/hf_token"),
            home.appendingPathComponent(".cache/huggingface/token"),
            home.appendingPathComponent(".huggingface/token")
        ]
        for url in fileCandidates {
            if let text = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return LocalToken(value: text, sourceDescription: url.path)
            }
        }

        let locations = fileCandidates.map(\.path).joined(separator: ", ")
        throw LORAError.missingHuggingFaceToken(detail: "FLUX.2 model downloads require a HuggingFace token. Set HF_TOKEN in the environment or place a token at one of: \(locations)")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func pythonListQuoted(_ values: [String]) -> String {
        "[" + values.map(Self.pythonQuoted).joined(separator: ", ") + "]"
    }

    private nonisolated static func robustHFHubDownloadCommand(
        shellSafeToken: String,
        repoID: String,
        filenames: [String],
        localDir: String,
        retries: Int = 5
    ) -> String {
        let repoLiteral = pythonQuoted(repoID)
        let filenamesLiteral = pythonListQuoted(filenames)
        let localDirLiteral = pythonQuoted(localDir)
        return """
        HF_TOKEN=\(shellSafeToken) /workspace/venv/bin/python - <<'PY'
        import os
        import time
        from huggingface_hub import hf_hub_download

        repo_id = \(repoLiteral)
        filenames = \(filenamesLiteral)
        local_dir = \(localDirLiteral)
        token = os.environ['HF_TOKEN']
        retries = \(retries)

        for filename in filenames:
            last_error = None
            for attempt in range(1, retries + 1):
                try:
                    local_path = hf_hub_download(
                        repo_id=repo_id,
                        filename=filename,
                        local_dir=local_dir,
                        token=token,
                    )
                    expected_path = os.path.join(local_dir, filename)
                    check_path = expected_path if os.path.exists(expected_path) else local_path
                    if not os.path.exists(check_path):
                        raise RuntimeError(f"downloaded file missing after fetch: {filename}")
                    if os.path.getsize(check_path) <= 0:
                        raise RuntimeError(f"downloaded file is empty: {filename}")
                    print(f"DOWNLOADED:{filename}", flush=True)
                    break
                except Exception as exc:
                    last_error = exc
                    if attempt >= retries:
                        raise
                    wait_seconds = min(20, attempt * 5)
                    print(f"RETRY:{filename}:{attempt}:{exc}", flush=True)
                    time.sleep(wait_seconds)
            else:
                raise last_error
        PY
        """
    }

    private static func validateHuggingFaceAccess(
        for baseModel: LORATrainingModels.BaseModel,
        token: LocalToken
    ) async throws {
        let targets: [(label: String, repoID: String, filename: String)] = [
            ("DiT", baseModel.modelRepoID, baseModel.modelFilename),
            ("Text encoder", baseModel.textEncoderRepoID, baseModel.primaryTextEncoderShard),
            ("Autoencoder", "black-forest-labs/FLUX.2-dev", "ae.safetensors")
        ]

        for target in targets {
            try await validateHuggingFaceAccess(
                label: target.label,
                repoID: target.repoID,
                filename: target.filename,
                token: token
            )
        }
    }

    private static func validateHuggingFaceAccess(
        label: String,
        repoID: String,
        filename: String,
        token: LocalToken
    ) async throws {
        let encodedRepo = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoID
        let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        guard let url = URL(string: "https://huggingface.co/\(encodedRepo)/resolve/main/\(encodedFilename)") else {
            throw LORAError.missingHuggingFaceAccess(detail: "Invalid Hugging Face URL for \(repoID)/\(filename)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LORAError.missingHuggingFaceAccess(detail: "Unexpected response while checking \(label) access for \(repoID)")
            }
            switch http.statusCode {
            case 200 ... 399:
                return
            case 401, 403:
                throw LORAError.missingHuggingFaceAccess(detail: "The Hugging Face token from \(token.sourceDescription) does not currently have access to \(repoID). Accept the model terms for that repo on Hugging Face, then retry the 9B run.")
            case 404:
                throw LORAError.trainingFailed(detail: "Configured Hugging Face file missing: \(repoID)/\(filename)")
            default:
                throw LORAError.trainingFailed(detail: "Hugging Face access check for \(repoID)/\(filename) returned HTTP \(http.statusCode)")
            }
        } catch let error as LORAError {
            throw error
        } catch {
            throw LORAError.trainingFailed(detail: "Unable to verify Hugging Face access for \(repoID)/\(filename): \(error.localizedDescription)")
        }
    }

    func createPod(
        gpuType: String = "NVIDIA RTX A6000",
        name: String = "amira-lora-training",
        sshPublicKey: String,
        containerDiskGB: Int = 80
    ) async throws -> String {
        podStatus = .creating

        LORALogger.shared.logSection("Creating pod gpu=\(gpuType) name=\(name)")

        // NOTE: Do NOT set volumeInGb > 0 without also setting volumeMountPath —
        // RunPod's daemon rejects it with "invalid mount config for type volume:
        // field Target must not be empty". The working LORA Maker uses
        // volumeInGb=0 with everything on the container disk. We match that
        // and bump containerDiskInGb so the FLUX.2 models + venv fit.
        LORALogger.shared.log("Injecting PUBLIC_KEY env var (len=\(sshPublicKey.count)) so sshd starts on the pod", level: "POD")

        let query = """
        mutation {
            podFindAndDeployOnDemand(input: {
                name: "\(name)"
                imageName: "runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"
                gpuTypeId: "\(gpuType)"
                gpuCount: 1
                volumeInGb: 0
                containerDiskInGb: \(containerDiskGB)
                minVcpuCount: 4
                minMemoryInGb: 16
                ports: "22/tcp,8888/http"
                dockerArgs: ""
                env: [{ key: "PUBLIC_KEY", value: "\(sshPublicKey)" }]
            }) { id machineId }
        }
        """

        let result = try await graphqlRequest(query: query)
        guard let data = result["data"] as? [String: Any],
              let pod = data["podFindAndDeployOnDemand"] as? [String: Any],
              let podID = pod["id"] as? String else {
            throw LORAError.podCreationFailed(detail: "GraphQL response missing pod id: \(result)")
        }

        LORALogger.shared.log("Pod created: \(podID)", level: "POD")

        podStatus = .starting
        startWatchdog(podID: podID)
        return podID
    }

    func getPodStatus(podID: String) async throws -> (status: String, sshHost: String?, sshPort: Int?) {
        let query = """
        query { pod(input: { podId: "\(podID)" }) { id desiredStatus runtime { uptimeInSeconds ports { ip isIpPublic privatePort publicPort type } } } }
        """
        let result = try await graphqlRequest(query: query)
        guard let data = result["data"] as? [String: Any],
              let pod = data["pod"] as? [String: Any] else {
            throw LORAError.podNotFound
        }

        let status = pod["desiredStatus"] as? String ?? "UNKNOWN"
        var sshHost: String?
        var sshPort: Int?

        if let runtime = pod["runtime"] as? [String: Any],
           let ports = runtime["ports"] as? [[String: Any]] {
            for port in ports {
                if port["privatePort"] as? Int == 22 {
                    sshHost = port["ip"] as? String
                    sshPort = port["publicPort"] as? Int
                }
            }
        }

        return (status, sshHost, sshPort)
    }

    func terminatePod(podID: String) async {
        podStatus = .stopping
        let query = """
        mutation { podTerminate(input: { podId: "\(podID)" }) }
        """
        _ = try? await graphqlRequest(query: query)
        podStatus = .inactive
        mutateCurrentJob {
            if $0.status != .error {
                $0.status = .inactive
            }
            $0.completedAt = $0.completedAt ?? Date()
            $0.podID = nil
        }
        stopWatchdog()
    }

    // MARK: - Training Orchestration

    func startTraining(
        config: LORATrainingModels.TrainingConfig,
        characterName: String,
        characterSlug: String,
        imagePaths: [String],
        animateURL: URL,
        autoStartQueuedJobsAfterSuccess: Bool = false,
        existingJobID: UUID? = nil,
        onProgress: @escaping @MainActor (LORATrainingModels.TrainingJob) -> Void
    ) async throws {
        restoreTask?.cancel()
        restoreTask = nil
        loadAPIKey()

        var persistedConfig = config
        persistedConfig.selectedImagePaths = imagePaths

        guard hasAPIKey else { throw LORAError.noAPIKey }

        var job = LORATrainingModels.TrainingJob(
            id: existingJobID ?? UUID(),
            characterName: characterName,
            characterSlug: characterSlug,
            triggerWord: config.triggerWord.isEmpty
                ? LORATrainingModels.generateTriggerWord(for: characterName)
                : config.triggerWord,
            config: persistedConfig
        )
        job.animateDirectoryPath = animateURL.path
        job.startedAt = Date()
        job.totalSteps = persistedConfig.steps
        job.resolvedGPUHourlyRateUSD = await resolveLiveCommunityHourlyRate(for: persistedConfig.baseModel)
        job.status = .creating
        currentJob = job
        onProgress(job)

        LORALogger.shared.logSection(
            "Training start: \(characterName) trigger=\(job.triggerWord) model=\(persistedConfig.baseModel.rawValue) images=\(imagePaths.count)"
        )

        do {
            // Validate all local image paths exist before we spend money spinning up a pod.
            for path in imagePaths {
                if !FileManager.default.fileExists(atPath: path) {
                    LORALogger.shared.log("Missing image: \(path)", level: "ERROR")
                    throw LORAError.imagePathMissing(path: path)
                }
            }
            LORALogger.shared.log("All \(imagePaths.count) images verified on local disk", level: "INFO")

            await ensureWatchdogMonitorRunning(projectURL: animateURL.deletingLastPathComponent())
            let sshKeyPair = try Self.loadLocalSSHKeyPair()
            let huggingFaceToken = try Self.loadLocalHuggingFaceToken()
            LORALogger.shared.log("Using SSH identity \(URL(fileURLWithPath: sshKeyPair.privateKeyPath).lastPathComponent) / \(URL(fileURLWithPath: sshKeyPair.publicKeyPath).lastPathComponent)", level: "INFO")
            LORALogger.shared.log("Using HuggingFace token from \(huggingFaceToken.sourceDescription)", level: "INFO")
            try await Self.validateHuggingFaceAccess(for: persistedConfig.baseModel, token: huggingFaceToken)

            // 1. Create pod
            let podID = try await createPod(
                gpuType: persistedConfig.baseModel.gpuType,
                sshPublicKey: sshKeyPair.publicKey,
                containerDiskGB: persistedConfig.baseModel.containerDiskGB
            )
            job.podID = podID
            job.status = .starting
            currentJob = job
            onProgress(job)

            // 2. Wait for pod to be ready (SSH available)
            let (host, port) = try await waitForPodConnectionDetails(podID: podID)
            try await waitForSSHReady(host: host, port: port, identityFile: sshKeyPair.privateKeyPath)

            job.status = .running
            currentJob = job
            onProgress(job)

            // 3. Upload images via SCP
            job.status = .uploading
            currentJob = job
            onProgress(job)

            LORALogger.shared.log("Uploading \(imagePaths.count) images to pod dataset dir", level: "UPLOAD")
            try await uploadImages(
                imagePaths: imagePaths,
                sshHost: host,
                sshPort: port,
                identityFile: sshKeyPair.privateKeyPath,
                triggerWord: job.triggerWord,
                subjectClassNoun: persistedConfig.subjectClassNoun
            )
            LORALogger.shared.log("All images uploaded", level: "UPLOAD")

            // 4. Run training script
            job.status = .training
            currentJob = job
            onProgress(job)

            LORALogger.shared.log("Kicking off training script", level: "TRAIN")
            try await runTraining(
                sshHost: host,
                sshPort: port,
                identityFile: sshKeyPair.privateKeyPath,
                huggingFaceToken: huggingFaceToken.value,
                job: &job,
                onProgress: onProgress
            )
            LORALogger.shared.log("Training finished, downloading LORA", level: "TRAIN")

            try await finalizeCompletedTraining(
                job: &job,
                sshHost: host,
                sshPort: port,
                identityFile: sshKeyPair.privateKeyPath,
                animateURL: animateURL,
                onProgress: onProgress
            )

            // 6. Terminate pod
            await terminatePod(podID: podID)
            if autoStartQueuedJobsAfterSuccess {
                scheduleQueuedJobLaunchIfNeeded()
            }

        } catch {
            LORALogger.shared.log("startTraining failed: \(error.localizedDescription)", level: "ERROR")
            if await preserveActivePodForAutomaticRecoveryIfPossible(after: error, job: &job, onProgress: onProgress) {
                return
            }
            job.status = .error
            job.errorMessage = error.localizedDescription
            currentJob = job
            onProgress(job)

            // ALWAYS terminate pod on error
            if let podID = job.podID {
                await terminatePod(podID: podID)
            }
            throw error
        }
    }

    private func preserveActivePodForAutomaticRecoveryIfPossible(
        after error: Error,
        job: inout LORATrainingModels.TrainingJob,
        onProgress: @escaping @MainActor (LORATrainingModels.TrainingJob) -> Void
    ) async -> Bool {
        let shouldPreserveForRecovery =
            isLikelySSHTransportFailure(error) ||
            isRecoverableCompletedArtifactFailure(error, job: job)

        guard shouldPreserveForRecovery,
              let podID = job.podID,
              !podID.isEmpty else {
            return false
        }

        do {
            let _ = try await waitForPodConnectionDetails(podID: podID, maxAttempts: 3)
            let isArtifactFailure = isRecoverableCompletedArtifactFailure(error, job: job)
            job.status = isArtifactFailure ? .downloading : .training
            job.errorMessage = isArtifactFailure
                ? "Final LoRA download failed, but the trained file should still be on the pod. Keeping the pod alive and retrying automatically."
                : "Connection to RunPod dropped, but the pod is still running. Keeping it alive and resuming automatically."
            currentJob = job
            onProgress(job)
            startWatchdog(podID: podID)
            restoreTask?.cancel()
            restoreTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(isArtifactFailure ? 10 : 3))
                await resumePersistedJobIfNeeded()
            }
            LORALogger.shared.log(
                isArtifactFailure
                    ? "Preserved completed pod \(podID) after final artifact download failure; queued automatic recovery"
                    : "Preserved active pod \(podID) after transport failure; queued automatic recovery",
                level: "WARN"
            )
            return true
        } catch {
            LORALogger.shared.log(
                "Unable to preserve pod \(podID) after transport failure: \(error.localizedDescription)",
                level: "WARN"
            )
            return false
        }
    }

    private func isRecoverableCompletedArtifactFailure(
        _ error: Error,
        job: LORATrainingModels.TrainingJob
    ) -> Bool {
        guard job.status == .downloading || job.currentStep >= job.totalSteps else { return false }
        if case LORAError.downloadFailed = error {
            return true
        }
        let description = error.localizedDescription.lowercased()
        return description.contains("download failed") || description.contains("scp download failed")
    }

    private func uploadDatasetFileWithRetries(
        localPath: String,
        remotePath: String,
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        maxAttempts: Int = 3
    ) async throws {
        for attempt in 1...maxAttempts {
            do {
                try await scpUpload(
                    localPath: localPath,
                    remotePath: remotePath,
                    host: sshHost,
                    port: sshPort,
                    identityFile: identityFile
                )
                try await verifyRemoteFileExists(
                    remotePath: remotePath,
                    sshHost: sshHost,
                    sshPort: sshPort,
                    identityFile: identityFile
                )
                return
            } catch {
                guard attempt < maxAttempts, isLikelySSHTransportFailure(error) else {
                    throw error
                }
                LORALogger.shared.log(
                    "Retrying upload for \(URL(fileURLWithPath: localPath).lastPathComponent) after transport error: \(error.localizedDescription)",
                    level: "WARN"
                )
                try await waitForSSHReady(host: sshHost, port: sshPort, identityFile: identityFile)
                try await Task.sleep(for: .seconds(min(attempt * 2, 6)))
            }
        }
    }

    private func verifyRemoteFileExists(
        remotePath: String,
        sshHost: String,
        sshPort: Int,
        identityFile: String
    ) async throws {
        let command = "test -s \(Self.shellSingleQuoted(remotePath)) && echo OK"
        let output = try await sshCommandChecked(
            host: sshHost,
            port: sshPort,
            identityFile: identityFile,
            command: command,
            failureContext: "Failed to verify uploaded file \(remotePath)"
        )
        guard output.contains("OK") else {
            throw LORAError.trainingFailed(detail: "Remote file verification failed for \(remotePath)")
        }
    }

    private func runSetupCommandWithRetries(
        description: String,
        command: String,
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        podID: String?,
        maxAttempts: Int = 3
    ) async throws -> (host: String, port: Int) {
        var activeHost = sshHost
        var activePort = sshPort
        let shouldRetryNonTransportFailures = description.hasPrefix("Download") || description.hasPrefix("Preload")

        for attempt in 1...maxAttempts {
            do {
                _ = try await sshCommandChecked(
                    host: activeHost,
                    port: activePort,
                    identityFile: identityFile,
                    command: command,
                    failureContext: "Setup '\(description)' failed"
                )
                return (activeHost, activePort)
            } catch {
                let isTransportFailure = isLikelySSHTransportFailure(error)
                guard attempt < maxAttempts,
                      isTransportFailure || shouldRetryNonTransportFailures else {
                    throw error
                }

                if isTransportFailure,
                   let podID,
                   !podID.isEmpty {
                    LORALogger.shared.log(
                        "Setup '\(description)' hit a transport error; reconnecting to pod \(podID) (attempt \(attempt + 1)/\(maxAttempts))",
                        level: "WARN"
                    )
                    let (recoveredHost, recoveredPort) = try await waitForPodConnectionDetails(podID: podID)
                    try await waitForSSHReady(host: recoveredHost, port: recoveredPort, identityFile: identityFile)
                    activeHost = recoveredHost
                    activePort = recoveredPort
                } else {
                    LORALogger.shared.log(
                        "Setup '\(description)' failed with a retryable download/setup error; retrying (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)",
                        level: "WARN"
                    )
                    try await Task.sleep(nanoseconds: UInt64(attempt * 5) * 1_000_000_000)
                }
            }
        }

        return (activeHost, activePort)
    }

    private func ensureRemoteWorkspaceCapacity(
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        minimumFreeGB: Int,
        context: String
    ) async throws {
        let command = """
        python3 - <<'PY'
        import os
        usage = os.statvfs('/workspace')
        free_bytes = usage.f_bavail * usage.f_frsize
        print(free_bytes)
        PY
        """
        let output = try await sshCommandChecked(
            host: sshHost,
            port: sshPort,
            identityFile: identityFile,
            command: command,
            failureContext: "Failed to check RunPod disk space \(context)"
        )
        let freeBytes = Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let freeGB = Double(freeBytes) / 1_000_000_000.0
        LORALogger.shared.log(
            String(format: "RunPod free disk %@: %.1f GB", context, freeGB),
            level: "INFO"
        )
        guard freeGB >= Double(minimumFreeGB) else {
            throw LORAError.trainingFailed(
                detail: String(
                    format: "RunPod ran too low on disk %@ (%.1f GB free, need at least %d GB). Aborting before more money is spent.",
                    context,
                    freeGB,
                    minimumFreeGB
                )
            )
        }
    }

    private func salvageLatestCheckpointIfNeeded(
        from snapshot: RemoteTrainingSnapshot,
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        job: inout LORATrainingModels.TrainingJob
    ) async {
        guard let remotePath = snapshot.outputPaths
            .sorted(by: { checkpointSortKey(for: $0) > checkpointSortKey(for: $1) })
            .first else {
            return
        }
        guard job.latestRecoveredCheckpointRemotePath != remotePath else { return }

        do {
            let recoveryDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Amira/Recovered-LoRAs/in-progress", isDirectory: true)
            try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
            let localURL = recoveryDir.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
            try await scpDownload(
                remotePath: remotePath,
                localPath: localURL.path,
                host: sshHost,
                port: sshPort,
                identityFile: identityFile
            )
            job.latestRecoveredCheckpointRemotePath = remotePath
            job.latestRecoveredCheckpointLocalPath = localURL.path
            LORALogger.shared.log("Recovered checkpoint backup: \(remotePath) → \(localURL.path)", level: "DONE")
        } catch {
            LORALogger.shared.log(
                "Failed to recover checkpoint \(remotePath): \(error.localizedDescription)",
                level: "WARN"
            )
        }
    }

    private func checkpointSortKey(for path: String) -> Int {
        if let step = Int(firstRegexCapture(#"-step(\d+)\.safetensors"#, in: path) ?? "") {
            return step
        }
        if path.hasSuffix(".safetensors") {
            return Int.max
        }
        return 0
    }

    // MARK: - SSH Operations

    private func uploadImages(
        imagePaths: [String],
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        triggerWord: String,
        subjectClassNoun: String
    ) async throws {
        LORALogger.shared.log("uploadImages: creating /workspace/dataset", level: "UPLOAD")
        // Create dataset directory
        try await sshCommandChecked(
            host: sshHost,
            port: sshPort,
            identityFile: identityFile,
            command: "mkdir -p /workspace/dataset",
            failureContext: "Failed to create remote dataset directory"
        )
        LORALogger.shared.log("uploadImages: dataset dir ready, starting per-file upload", level: "UPLOAD")

        // Upload each image and create caption with trigger word
        for path in imagePaths {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            try await uploadDatasetFileWithRetries(
                localPath: path,
                remotePath: "/workspace/dataset/\(filename)",
                sshHost: sshHost,
                sshPort: sshPort,
                identityFile: identityFile
            )

            // Create caption file with trigger word
            let captionFilename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".txt"
            let captionContent = resolvedTrainingCaption(
                for: path,
                triggerWord: triggerWord,
                subjectClassNoun: subjectClassNoun
            )
            let tmpCaption = FileManager.default.temporaryDirectory.appendingPathComponent(captionFilename)
            try captionContent.write(to: tmpCaption, atomically: true, encoding: .utf8)
            try await uploadDatasetFileWithRetries(
                localPath: tmpCaption.path,
                remotePath: "/workspace/dataset/\(captionFilename)",
                sshHost: sshHost,
                sshPort: sshPort,
                identityFile: identityFile
            )
            try? FileManager.default.removeItem(at: tmpCaption)
        }
    }

    private func resolvedTrainingCaption(
        for imagePath: String,
        triggerWord: String,
        subjectClassNoun: String
    ) -> String {
        if let template = recommendedLORACaptionTemplate(for: imagePath) {
            return interpolateLORACaptionTemplate(
                template,
                triggerWord: triggerWord,
                subjectClassNoun: subjectClassNoun
            )
        }

        let promptText = trainingImagePrompt(for: imagePath) ?? ""
        let haystack = "\(URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent) \(promptText)"
            .lowercased()

        var descriptors: [String] = []

        if haystack.contains("full-body") || haystack.contains("full body") {
            descriptors.append("full-body portrait")
        } else if haystack.contains("waist-up") || haystack.contains("waist up") {
            descriptors.append("waist-up portrait")
        } else if haystack.contains("chest-up") || haystack.contains("chest up") {
            descriptors.append("chest-up portrait")
        } else if haystack.contains("headshot")
            || haystack.contains("head-and-shoulders")
            || haystack.contains("head and shoulders")
            || haystack.contains("close-up")
            || haystack.contains("close up")
            || haystack.contains("head only") {
            descriptors.append("head-and-shoulders portrait")
        } else {
            descriptors.append("photoreal portrait")
        }

        if haystack.contains("left profile") || haystack.contains("profile left") {
            descriptors.append("left profile")
        } else if haystack.contains("right profile") || haystack.contains("profile right") {
            descriptors.append("right profile")
        } else if haystack.contains("three-quarter left") || haystack.contains("three quarter left") {
            descriptors.append("three-quarter left view")
        } else if haystack.contains("three-quarter right") || haystack.contains("three quarter right") {
            descriptors.append("three-quarter right view")
        } else if haystack.contains("front view")
            || haystack.contains("looking directly at camera")
            || haystack.contains("looking toward camera") {
            descriptors.append("front view")
        }

        if haystack.contains("studio") {
            descriptors.append("studio lighting")
        } else if haystack.contains("window light") || haystack.contains("window-lit") || haystack.contains("window lit") {
            descriptors.append("window light")
        } else if haystack.contains("open shade") || haystack.contains("shade") {
            descriptors.append("open shade")
        } else if haystack.contains("daylight") || haystack.contains("outdoors") || haystack.contains("street") {
            descriptors.append("outdoors in daylight")
        }

        let uniqueDescriptors = descriptors.reduce(into: [String]()) { partial, descriptor in
            if !partial.contains(descriptor) {
                partial.append(descriptor)
            }
        }

        let suffix = uniqueDescriptors.joined(separator: ", ")
        return suffix.isEmpty
            ? "photo of \(triggerWord) \(subjectClassNoun)"
            : "photo of \(triggerWord) \(subjectClassNoun), \(suffix)"
    }

    private func recommendedLORACaptionTemplate(for imagePath: String) -> String? {
        guard let request = trainingImageMetadataRequest(for: imagePath) else { return nil }
        return (request["recommended_lora_caption"] as? String)
            ?? (request["recommendedLORACaption"] as? String)
    }

    private func trainingImagePrompt(for imagePath: String) -> String? {
        trainingImageMetadataRequest(for: imagePath)?["prompt"] as? String
    }

    private func trainingImageMetadataRequest(for imagePath: String) -> [String: Any]? {
        let sidecarURL = URL(fileURLWithPath: imagePath)
            .deletingPathExtension()
            .appendingPathExtension("json")
        guard let data = try? Data(contentsOf: sidecarURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = json["request"] as? [String: Any] else {
            return nil
        }
        return request
    }

    private func interpolateLORACaptionTemplate(
        _ template: String,
        triggerWord: String,
        subjectClassNoun: String
    ) -> String {
        template
            .replacingOccurrences(of: "{trigger}", with: triggerWord)
            .replacingOccurrences(of: "{subject_class}", with: subjectClassNoun)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runTraining(
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        huggingFaceToken: String,
        job: inout LORATrainingModels.TrainingJob,
        onProgress: @escaping @MainActor (LORATrainingModels.TrainingJob) -> Void
    ) async throws {
        var activeSSHHost = sshHost
        var activeSSHPort = sshPort

        // Step A: Install environment (venv, PyTorch, musubi-tuner, download models)
        let safeHFToken = Self.shellSingleQuoted(huggingFaceToken)
        let baseModel = job.config.baseModel
        let setupCommands: [(String, String)] = [
            ("Create venv", "python3 -m venv /workspace/venv"),
            ("Upgrade pip", "/workspace/venv/bin/pip install -q --upgrade pip"),
            ("Install PyTorch", "/workspace/venv/bin/pip install -q torch==2.5.1 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124"),
            ("Validate GPU", "/workspace/venv/bin/python -c \"import torch; print(f'GPU: {torch.cuda.get_device_name(0)}, VRAM: {torch.cuda.get_device_properties(0).total_memory/1e9:.1f} GB')\""),
            ("Save GPU info", "/workspace/venv/bin/python -c \"import torch, json; p=torch.cuda.get_device_properties(0); json.dump({'supports_bf16': p.major >= 8, 'name': torch.cuda.get_device_name(0), 'vram_gb': p.total_memory/1e9}, open('/workspace/gpu_info.json','w'))\""),
            ("Clone musubi-tuner", "if [ -d /workspace/musubi-tuner/.git ]; then git -C /workspace/musubi-tuner fetch --depth 1 origin && git -C /workspace/musubi-tuner reset --hard origin/HEAD; else rm -rf /workspace/musubi-tuner && git clone --depth 1 https://github.com/kohya-ss/musubi-tuner.git /workspace/musubi-tuner; fi"),
            ("Install musubi-tuner", "/workspace/venv/bin/pip install -q -e /workspace/musubi-tuner"),
            ("Install accelerate and peft", "/workspace/venv/bin/pip install -q accelerate==1.6.0 peft"),
            ("Authenticate HuggingFace", "HF_TOKEN=\(safeHFToken) /workspace/venv/bin/python -c \"from huggingface_hub import login; import os; login(token=os.environ['HF_TOKEN'], add_to_git_credential=False)\""),
            ("Create model dirs", "mkdir -p /workspace/models /workspace/models/text_encoder /workspace/output"),
            ("Download DiT", Self.robustHFHubDownloadCommand(shellSafeToken: safeHFToken, repoID: baseModel.modelRepoID, filenames: [baseModel.modelFilename], localDir: "/workspace/models")),
            ("Download AE", Self.robustHFHubDownloadCommand(shellSafeToken: safeHFToken, repoID: "black-forest-labs/FLUX.2-dev", filenames: ["ae.safetensors"], localDir: "/workspace/models")),
            ("Download text encoder bundle", Self.robustHFHubDownloadCommand(shellSafeToken: safeHFToken, repoID: baseModel.textEncoderRepoID, filenames: baseModel.textEncoderFilenames, localDir: "/workspace/models")),
            ("Preload Qwen tokenizer cache", "HF_TOKEN=\(safeHFToken) /workspace/venv/bin/python -c \"from huggingface_hub import snapshot_download; import os; snapshot_download(repo_id='\(baseModel.qwenTokenizerRepoID)', allow_patterns=['tokenizer*', 'special_tokens_map.json', 'vocab.json', 'merges.txt', 'chat_template.jinja'], token=os.environ['HF_TOKEN'])\""),
        ]

        for (desc, cmd) in setupCommands {
            job.errorMessage = "Setup: \(desc)"
            currentJob = job
            onProgress(job)
            let recoveredConnection = try await runSetupCommandWithRetries(
                description: desc,
                command: cmd,
                sshHost: activeSSHHost,
                sshPort: activeSSHPort,
                identityFile: identityFile,
                podID: job.podID
            )
            activeSSHHost = recoveredConnection.host
            activeSSHPort = recoveredConnection.port
        }

        try await ensureRemoteWorkspaceCapacity(
            sshHost: activeSSHHost,
            sshPort: activeSSHPort,
            identityFile: identityFile,
            minimumFreeGB: 18,
            context: "after environment setup"
        )

        // Step B: Generate and upload the training script
        let trainingScript = Self.generateTrainingScript(
            baseModel: job.config.baseModel,
            triggerWord: job.triggerWord,
            steps: job.config.steps,
            networkDim: job.config.networkDim,
            networkAlpha: job.config.networkAlpha,
            learningRate: job.config.learningRate,
            resolution: job.config.resolution
        )
        let tmpScript = FileManager.default.temporaryDirectory.appendingPathComponent("train_lora.py")
        try trainingScript.write(to: tmpScript, atomically: true, encoding: .utf8)
        try await uploadDatasetFileWithRetries(
            localPath: tmpScript.path,
            remotePath: "/workspace/train_lora.py",
            sshHost: activeSSHHost,
            sshPort: activeSSHPort,
            identityFile: identityFile
        )
        try? FileManager.default.removeItem(at: tmpScript)

        let selectedImageBytes = job.config.selectedImagePaths.reduce(Int64(0)) { partial, path in
            partial + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let minimumTrainingFreeGB = max(12, Int((Double(selectedImageBytes) / 1_000_000_000.0).rounded(.up)) + 8)
        try await ensureRemoteWorkspaceCapacity(
            sshHost: activeSSHHost,
            sshPort: activeSSHPort,
            identityFile: identityFile,
            minimumFreeGB: minimumTrainingFreeGB,
            context: "before starting training"
        )

        // Step C: Run training in background
        job.errorMessage = nil
        do {
            try await launchRemoteTrainingDetached(
                sshHost: activeSSHHost,
                sshPort: activeSSHPort,
                identityFile: identityFile,
                job: &job,
                onProgress: onProgress
            )
        } catch {
            if isLikelySSHTransportFailure(error),
               let podID = job.podID,
               !podID.isEmpty {
                LORALogger.shared.log(
                    "Launch transport failed (\(error.localizedDescription)). Reconnecting to pod \(podID) before giving up.",
                    level: "WARN"
                )
                let (recoveredHost, recoveredPort) = try await waitForPodConnectionDetails(podID: podID)
                try await waitForSSHReady(host: recoveredHost, port: recoveredPort, identityFile: identityFile)
                activeSSHHost = recoveredHost
                activeSSHPort = recoveredPort
                try await confirmRemoteTrainingLaunch(
                    sshHost: recoveredHost,
                    sshPort: recoveredPort,
                    identityFile: identityFile,
                    job: &job,
                    onProgress: onProgress
                )
            } else {
                throw error
            }
        }

        try await monitorTrainingUntilDone(
            sshHost: activeSSHHost,
            sshPort: activeSSHPort,
            identityFile: identityFile,
            job: &job,
            onProgress: onProgress
        )
    }

    private func launchRemoteTrainingDetached(
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        job: inout LORATrainingModels.TrainingJob,
        onProgress: @escaping @MainActor (LORATrainingModels.TrainingJob) -> Void
    ) async throws {
        let launchCommand = """
        python3 - <<'PY'
        import os
        import pathlib
        import subprocess

        workspace = "/workspace"
        pid_path = pathlib.Path("/workspace/train_lora.pid")
        exit_path = pathlib.Path("/workspace/train_lora.exitcode")
        log_path = pathlib.Path("/workspace/training.log")

        for path in (pid_path, exit_path):
            try:
                path.unlink()
            except FileNotFoundError:
                pass

        log_path.write_text("", encoding="utf-8")

        shell_command = "/workspace/venv/bin/python -u /workspace/train_lora.py >> /workspace/training.log 2>&1; printf '%s' $? > /workspace/train_lora.exitcode"
        process = subprocess.Popen(
            ["/bin/bash", "-lc", shell_command],
            cwd=workspace,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        pid_path.write_text(str(process.pid), encoding="utf-8")
        print(f"LAUNCHED_PID:{process.pid}", flush=True)
        PY
        """

        _ = try await sshCommandChecked(
            host: sshHost,
            port: sshPort,
            identityFile: identityFile,
            command: launchCommand,
            failureContext: "Failed to launch remote training"
        )

        try await confirmRemoteTrainingLaunch(
            sshHost: sshHost,
            sshPort: sshPort,
            identityFile: identityFile,
            job: &job,
            onProgress: onProgress
        )
    }

    private func confirmRemoteTrainingLaunch(
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        job: inout LORATrainingModels.TrainingJob,
        onProgress: @escaping @MainActor (LORATrainingModels.TrainingJob) -> Void
    ) async throws {
        let maxAttempts = 12

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(5))
            }

            do {
                let snapshot = try await fetchRemoteTrainingSnapshot(
                    sshHost: sshHost,
                    sshPort: sshPort,
                    identityFile: identityFile
                )
                let outcome = updateJobFromRemoteSnapshot(snapshot, job: &job)
                currentJob = job
                onProgress(job)

                switch snapshot.processStatus {
                case .running:
                    return
                case .exited(let exitCode):
                    let tail = (try? await remoteTrainingLogTail(
                        sshHost: sshHost,
                        sshPort: sshPort,
                        identityFile: identityFile,
                        maxLines: 40
                    )) ?? "training.log unavailable"
                    let suffix = exitCode.map { " (exit \($0))" } ?? ""
                    throw LORAError.trainingFailed(detail: "Remote training exited during launch verification\(suffix).\n\(tail)")
                case .missingPID:
                    if case .success = outcome {
                        return
                    }
                case .notStarted:
                    if case .success = outcome {
                        return
                    }
                }
            } catch {
                if isLikelySSHTransportFailure(error) {
                    LORALogger.shared.log(
                        "Training launch verification attempt \(attempt + 1)/\(maxAttempts) hit a transport error: \(error.localizedDescription)",
                        level: "WARN"
                    )
                    continue
                }
                throw error
            }
        }

        let logTail = (try? await remoteTrainingLogTail(
            sshHost: sshHost,
            sshPort: sshPort,
            identityFile: identityFile,
            maxLines: 40
        )) ?? "training.log unavailable"
        throw LORAError.trainingFailed(detail: "Remote training never reported a running PID after launch.\n\(logTail)")
    }

    private func remoteTrainingLogTail(
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        maxLines: Int
    ) async throws -> String {
        let command = """
        if [ -f /workspace/training.log ]; then
          tail -\(maxLines) /workspace/training.log
        else
          echo "training.log missing"
        fi
        """
        return try await sshCommandChecked(
            host: sshHost,
            port: sshPort,
            identityFile: identityFile,
            command: command,
            failureContext: "Failed to read remote training log"
        )
    }

    private func waitForPodConnectionDetails(
        podID: String,
        maxAttempts: Int = 60
    ) async throws -> (host: String, port: Int) {
        LORALogger.shared.log("Waiting for pod to become RUNNING on pod \(podID)", level: "POD")
        for attempt in 1...maxAttempts {
            do {
                let (status, host, port) = try await getPodStatus(podID: podID)
                let normalizedStatus = status.uppercased()
                if normalizedStatus == "TERMINATED" || normalizedStatus == "EXITED" {
                    throw LORAError.trainingFailed(detail: "RunPod pod \(podID) is no longer running (\(status)).")
                }
                if status == "RUNNING", let host, let port {
                    return (host, port)
                }
            } catch let error as LORAError {
                throw error
            } catch {
                LORALogger.shared.log("Transient pod status check failure (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription)", level: "WARN")
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw LORAError.podStartTimeout
    }

    private func fetchRemoteTrainingSnapshot(
        sshHost: String,
        sshPort: Int,
        identityFile: String
    ) async throws -> RemoteTrainingSnapshot {
        let statusCommand = """
        if [ -f /workspace/train_lora.exitcode ]; then
          printf 'STATUS:EXITED\\n'
          printf 'EXITCODE:%s\\n' "$(cat /workspace/train_lora.exitcode)"
        elif [ -s /workspace/train_lora.pid ]; then
          pid="$(cat /workspace/train_lora.pid)"
          if kill -0 "$pid" 2>/dev/null; then
            printf 'STATUS:RUNNING\\n'
          else
            printf 'STATUS:MISSING_PID\\n'
          fi
        else
          printf 'STATUS:NOT_STARTED\\n'
        fi
        if [ -f /workspace/training.log ]; then
          tail -80 /workspace/training.log || true
        fi
        if [ -d /workspace/output ]; then
          ls -1 /workspace/output/*.safetensors 2>/dev/null | sed 's#^#OUTPUT:#' || true
        fi
        """

        let output = try await sshCommandChecked(
            host: sshHost,
            port: sshPort,
            identityFile: identityFile,
            command: statusCommand,
            failureContext: "Failed to poll remote training status"
        )

        var processStatus: RemoteTrainingSnapshot.ProcessStatus = .notStarted
        var exitCode: String?
        var progressLines: [String] = []
        var outputPaths: [String] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("STATUS:RUNNING") {
                processStatus = .running
            } else if line.hasPrefix("STATUS:EXITED") {
                processStatus = .exited(exitCode: exitCode)
            } else if line.hasPrefix("STATUS:MISSING_PID") {
                processStatus = .missingPID
            } else if line.hasPrefix("STATUS:NOT_STARTED") {
                processStatus = .notStarted
            } else if line.hasPrefix("EXITCODE:") {
                exitCode = String(line.dropFirst("EXITCODE:".count))
                if case .exited = processStatus {
                    processStatus = .exited(exitCode: exitCode)
                }
            } else if line.hasPrefix("OUTPUT:") {
                outputPaths.append(String(line.dropFirst("OUTPUT:".count)))
            } else {
                progressLines.append(line)
            }
        }

        if case .exited = processStatus {
            processStatus = .exited(exitCode: exitCode)
        }

        return RemoteTrainingSnapshot(
            processStatus: processStatus,
            progressLines: progressLines,
            outputPaths: outputPaths
        )
    }

    private func monitorTrainingUntilDone(
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        job: inout LORATrainingModels.TrainingJob,
        onProgress: @escaping @MainActor (LORATrainingModels.TrainingJob) -> Void
    ) async throws {
        let pollIntervalSeconds = 10
        let maxPolls = max(1, job.config.preset.timeoutSeconds / pollIntervalSeconds)
        var activeSSHHost = sshHost
        var activeSSHPort = sshPort
        var consecutiveTransportFailures = 0

        for attempt in 0..<maxPolls {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(pollIntervalSeconds))
            }

            let snapshot: RemoteTrainingSnapshot
            do {
                snapshot = try await fetchRemoteTrainingSnapshot(
                    sshHost: activeSSHHost,
                    sshPort: activeSSHPort,
                    identityFile: identityFile
                )
                consecutiveTransportFailures = 0
            } catch {
                guard isLikelySSHTransportFailure(error),
                      let podID = job.podID,
                      !podID.isEmpty else {
                    throw error
                }

                consecutiveTransportFailures += 1
                LORALogger.shared.log(
                    "Training monitor transport failure \(consecutiveTransportFailures)/6 for pod \(podID): \(error.localizedDescription)",
                    level: "WARN"
                )

                let (recoveredHost, recoveredPort) = try await waitForPodConnectionDetails(podID: podID)
                try await waitForSSHReady(host: recoveredHost, port: recoveredPort, identityFile: identityFile)
                activeSSHHost = recoveredHost
                activeSSHPort = recoveredPort

                if consecutiveTransportFailures >= 6 {
                    let snapshotAfterReconnect = try await fetchRemoteTrainingSnapshot(
                        sshHost: activeSSHHost,
                        sshPort: activeSSHPort,
                        identityFile: identityFile
                    )
                    if case .running = snapshotAfterReconnect.processStatus {
                        consecutiveTransportFailures = 0
                        continue
                    }
                    let logTail = (try? await remoteTrainingLogTail(
                        sshHost: activeSSHHost,
                        sshPort: activeSSHPort,
                        identityFile: identityFile,
                        maxLines: 40
                    )) ?? "training.log unavailable"
                    throw LORAError.trainingFailed(detail: "Lost contact with remote training after repeated reconnect attempts.\n\(logTail)")
                }

                continue
            }
            let outcome = updateJobFromRemoteSnapshot(snapshot, job: &job)
            if attempt == 0 || attempt % 18 == 0 {
                do {
                    try await ensureRemoteWorkspaceCapacity(
                        sshHost: activeSSHHost,
                        sshPort: activeSSHPort,
                        identityFile: identityFile,
                        minimumFreeGB: 6,
                        context: "while training"
                    )
                } catch {
                    throw error
                }
            }
            await salvageLatestCheckpointIfNeeded(
                from: snapshot,
                sshHost: activeSSHHost,
                sshPort: activeSSHPort,
                identityFile: identityFile,
                job: &job
            )
            currentJob = job
            onProgress(job)

            switch outcome {
            case .success:
                return
            case .continueMonitoring:
                continue
            case .failure(let detail):
                let logTail = (try? await remoteTrainingLogTail(
                    sshHost: activeSSHHost,
                    sshPort: activeSSHPort,
                    identityFile: identityFile,
                    maxLines: 40
                )) ?? "training.log unavailable"
                throw LORAError.trainingFailed(detail: "\(detail)\n\(logTail)")
            }
        }

        let timeoutLog = (try? await remoteTrainingLogTail(
            sshHost: activeSSHHost,
            sshPort: activeSSHPort,
            identityFile: identityFile,
            maxLines: 40
        )) ?? "training.log unavailable"
        throw LORAError.trainingFailed(detail: "Timed out after \(job.config.preset.timeoutSeconds)s.\n\(timeoutLog)")
    }

    private enum RemoteMonitorOutcome {
        case success
        case continueMonitoring
        case failure(String)
    }

    private func updateJobFromRemoteSnapshot(
        _ snapshot: RemoteTrainingSnapshot,
        job: inout LORATrainingModels.TrainingJob
    ) -> RemoteMonitorOutcome {
        var sawDone = false

        for line in snapshot.progressLines {
            if line.contains("phase=done") {
                sawDone = true
                continue
            }
            if let stepStr = firstRegexCapture(#"step=(\d+)"#, in: line)
                ?? firstRegexCapture(#"\b(\d{1,6})/(\d{1,6})\b"#, in: line),
               let step = Int(stepStr) {
                job.currentStep = max(job.currentStep, step)
            }
            if let totalStr = firstRegexCapture(#"total=(\d+)"#, in: line)
                ?? secondRegexCapture(#"\b(\d{1,6})/(\d{1,6})\b"#, in: line),
               let total = Int(totalStr) {
                job.totalSteps = max(job.totalSteps, total)
            }
            if let lossStr = firstRegexCapture(#"avr_loss=([0-9.eE+-]+|nan|inf|-inf)"#, in: line)
                ?? firstRegexCapture(#"\bloss=([0-9.eE+-]+|nan|inf|-inf)"#, in: line),
               lossStr.lowercased() != "n/a" {
                job.errorMessage = "Loss: \(lossStr)"
            }
            if job.triggerWord.isEmpty,
               let inferredTrigger = firstRegexCapture(#"OUTPUT:.*?/([^/\s]+?)-step\d+\.safetensors"#, in: line)
                ?? firstRegexCapture(#"[/ ]([A-Za-z0-9_-]+)-step\d+\.safetensors"#, in: line) {
                applyRecoveredTrigger(inferredTrigger, to: &job)
            }
        }

        if job.triggerWord.isEmpty,
           let inferredTrigger = snapshot.outputPaths.compactMap(inferTriggerWord).first {
            applyRecoveredTrigger(inferredTrigger, to: &job)
        }
        if let activeAnimateURL {
            enrichRecoveredJobMetadata(&job, animateURL: activeAnimateURL)
        }

        if sawDone {
            job.currentStep = max(job.currentStep, job.totalSteps)
            job.errorMessage = nil
            return .success
        }

        switch snapshot.processStatus {
        case .running:
            return .continueMonitoring
        case .exited(let exitCode):
            if (exitCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "0",
               snapshot.outputPaths.contains(where: { $0.hasSuffix("\(job.triggerWord).safetensors") }) {
                job.currentStep = max(job.currentStep, job.totalSteps)
                job.errorMessage = nil
                return .success
            }
            let suffix = exitCode.map { " (exit \($0))" } ?? ""
            return .failure("Remote training process exited without reporting success\(suffix).")
        case .missingPID:
            return .failure("Remote training process disappeared before reporting success.")
        case .notStarted:
            return snapshot.outputPaths.contains(where: { $0.hasSuffix("\(job.triggerWord).safetensors") })
                ? .success
                : .continueMonitoring
        }
    }

    private func firstRegexCapture(
        _ pattern: String,
        in text: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func secondRegexCapture(
        _ pattern: String,
        in text: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 2,
              let captureRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func inferTriggerWord(from outputPath: String) -> String? {
        let filename = URL(fileURLWithPath: outputPath).lastPathComponent
        if let match = firstRegexCapture(#"^(.+)-step\d+\.safetensors$"#, in: filename) {
            return match
        }
        if filename.hasSuffix(".safetensors") {
            return URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        }
        return nil
    }

    private func applyRecoveredTrigger(
        _ triggerWord: String,
        to job: inout LORATrainingModels.TrainingJob
    ) {
        let cleaned = triggerWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if job.triggerWord.isEmpty {
            job.triggerWord = cleaned
        }
        if job.characterName == "Recovered RunPod Training" || job.characterName.isEmpty {
            job.characterName = cleaned
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private func enrichRecoveredJobMetadata(
        _ job: inout LORATrainingModels.TrainingJob,
        animateURL: URL
    ) {
        guard !job.triggerWord.isEmpty || !job.characterSlug.isEmpty else { return }
        guard let match = findCharacterMatch(
            animateURL: animateURL,
            triggerWord: job.triggerWord,
            fallbackCharacterName: job.characterName
        ) else { return }
        job.characterName = match.name
        job.characterSlug = match.assetFolderSlug
        job.animateDirectoryPath = animateURL.path
    }

    private func findCharacterMatch(
        animateURL: URL,
        triggerWord: String,
        fallbackCharacterName: String
    ) -> AnimationCharacter? {
        let charactersDir = animateURL.appendingPathComponent("characters", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: charactersDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let normalizedTrigger = triggerWord.lowercased()
        let normalizedName = fallbackCharacterName.lowercased()

        for directory in directories {
            let rigURL = directory.appendingPathComponent("rig.json")
            guard let data = try? Data(contentsOf: rigURL),
                  let character = try? JSONDecoder().decode(AnimationCharacter.self, from: data) else {
                continue
            }
            let firstName = character.name.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            let storedTrigger = character.activeLORATriggerWord?.lowercased() ?? ""
            if !normalizedTrigger.isEmpty,
               (storedTrigger == normalizedTrigger ||
                firstName == normalizedTrigger ||
                character.assetFolderSlug.lowercased() == normalizedTrigger) {
                return character
            }
            if !normalizedName.isEmpty,
               character.name.lowercased() == normalizedName ||
                firstName == normalizedName {
                return character
            }
        }
        return nil
    }

    private func finalizeCompletedTraining(
        job: inout LORATrainingModels.TrainingJob,
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        animateURL: URL,
        onProgress: @escaping @MainActor (LORATrainingModels.TrainingJob) -> Void
    ) async throws {
        job.status = .downloading
        if let activeAnimateURL {
            enrichRecoveredJobMetadata(&job, animateURL: activeAnimateURL)
        }
        currentJob = job
        onProgress(job)

        let localPath = try resolvedLocalLoRAPath(for: job, animateURL: animateURL)
        try await downloadLORA(
            sshHost: sshHost,
            sshPort: sshPort,
            identityFile: identityFile,
            triggerWord: job.triggerWord,
            localPath: localPath,
            podID: job.podID
        )

        job.outputLORAPath = localPath.path
        job.status = .inactive
        job.completedAt = Date()
        job.currentStep = max(job.currentStep, job.totalSteps)
        job.errorMessage = nil
        try updateCharacterRigAfterTraining(job: job, animateURL: animateURL)
        currentJob = job
        onProgress(job)

        LORALogger.shared.log("LORA saved to \(localPath.path)", level: "DONE")
    }

    private func updateCharacterRigAfterTraining(
        job: LORATrainingModels.TrainingJob,
        animateURL: URL
    ) throws {
        guard !job.characterSlug.isEmpty else {
            LORALogger.shared.log("Skipping rig update for recovered job because character slug is unknown", level: "WARN")
            return
        }
        let rigURL = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(job.characterSlug)
            .appendingPathComponent("rig.json")
        guard FileManager.default.fileExists(atPath: rigURL.path) else {
            LORALogger.shared.log("No rig.json found for \(job.characterSlug) while finalizing LoRA", level: "WARN")
            return
        }

        let data = try Data(contentsOf: rigURL)
        var character = try JSONDecoder().decode(AnimationCharacter.self, from: data)
        character.activeLORAFilename = URL(
            fileURLWithPath: job.outputLORAPath
                ?? job.config.baseModel.outputFilename(for: job.triggerWord)
        ).lastPathComponent
        character.activeLORATriggerWord = job.triggerWord
        if character.activeLORAWeight <= 0 {
            character.activeLORAWeight = 1.0
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(character)
        try encoded.write(to: rigURL, options: .atomic)
    }

    private func resolvedLocalLoRAPath(
        for job: LORATrainingModels.TrainingJob,
        animateURL: URL
    ) throws -> URL {
        if !job.characterSlug.isEmpty {
            let loraDir = animateURL
                .appendingPathComponent("characters")
                .appendingPathComponent(job.characterSlug)
                .appendingPathComponent("lora")
            try FileManager.default.createDirectory(at: loraDir, withIntermediateDirectories: true)
            return loraDir.appendingPathComponent(job.config.baseModel.outputFilename(for: job.triggerWord))
        }

        let recoveryDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amira/Recovered-LoRAs", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
        return recoveryDir.appendingPathComponent(job.config.baseModel.outputFilename(for: job.triggerWord))
    }

    @discardableResult
    private func archiveExistingLoRAIfNeeded(at localPath: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: localPath.path) else { return nil }

        let archiveDirectory = localPath
            .deletingLastPathComponent()
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let baseName = localPath.deletingPathExtension().lastPathComponent
        let ext = localPath.pathExtension.isEmpty ? "" : ".\(localPath.pathExtension)"

        var candidate = archiveDirectory.appendingPathComponent("\(baseName)-\(timestamp)\(ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = archiveDirectory.appendingPathComponent("\(baseName)-\(timestamp)-\(suffix)\(ext)")
            suffix += 1
        }

        try FileManager.default.moveItem(at: localPath, to: candidate)
        LORALogger.shared.log("Archived existing LORA \(localPath.lastPathComponent) → \(candidate.path)", level: "DONE")
        return candidate
    }

    private func ensureWatchdogMonitorRunning(projectURL: URL) async {
        let scriptURL = projectURL.appendingPathComponent("Scripts/runpod_pod_monitor.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            LORALogger.shared.log("RunPod watchdog script not found at \(scriptURL.path)", level: "WARN")
            return
        }

        do {
            let result = try await runProcess(
                executable: "/usr/bin/python3",
                arguments: [scriptURL.path, "ensure-monitor"]
            )
            let output = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                LORALogger.shared.log("RunPod watchdog: \(output)", level: "POD")
            }
        } catch {
            LORALogger.shared.log("Failed to ensure RunPod watchdog monitor: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func resumePersistedJobIfNeeded() async {
        defer { restoreTask = nil }
        guard var job = currentJob, job.status.isActive else { return }
        let animateDirectoryPath =
            job.animateDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? job.animateDirectoryPath
            : activeAnimateURL?.path
        if let animateDirectoryPath {
            job.animateDirectoryPath = animateDirectoryPath
        }

        loadAPIKey()
        guard hasAPIKey else {
            job.status = .error
            job.errorMessage = "RunPod API key missing. Re-enter it to resume the LoRA run."
            currentJob = job
            return
        }

        guard let podID = job.podID, !podID.isEmpty else {
            job.status = .error
            job.errorMessage = "The app restarted before the RunPod pod ID was recorded."
            currentJob = job
            return
        }

        let animateURL = animateDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }

        do {
            if let animateURL {
                await ensureWatchdogMonitorRunning(projectURL: animateURL.deletingLastPathComponent())
            }
            let sshKeyPair = try Self.loadLocalSSHKeyPair()
            let (host, port) = try await waitForPodConnectionDetails(podID: podID)
            startWatchdog(podID: podID)
            try await waitForSSHReady(host: host, port: port, identityFile: sshKeyPair.privateKeyPath)

            let snapshot = try await fetchRemoteTrainingSnapshot(
                sshHost: host,
                sshPort: port,
                identityFile: sshKeyPair.privateKeyPath
            )
            let hasRemoteTrainingState =
                !snapshot.progressLines.isEmpty ||
                !snapshot.outputPaths.isEmpty ||
                {
                    switch snapshot.processStatus {
                    case .running, .exited, .missingPID:
                        return true
                    case .notStarted:
                        return false
                    }
                }()

            if hasRemoteTrainingState {
                if let animateURL {
                    enrichRecoveredJobMetadata(&job, animateURL: animateURL)
                }
                job.status = .training
                currentJob = job
                try await monitorTrainingUntilDone(
                    sshHost: host,
                    sshPort: port,
                    identityFile: sshKeyPair.privateKeyPath,
                    job: &job,
                    onProgress: { _ in }
                )
                if let animateURL {
                    try await finalizeCompletedTraining(
                        job: &job,
                        sshHost: host,
                        sshPort: port,
                        identityFile: sshKeyPair.privateKeyPath,
                        animateURL: animateURL,
                        onProgress: { _ in }
                    )
                    await terminatePod(podID: podID)
                    scheduleQueuedJobLaunchIfNeeded()
                } else {
                    job.errorMessage = "Training progress recovered. Open the matching project to capture the finished LoRA file automatically."
                    currentJob = job
                }
                return
            }

            guard !job.config.selectedImagePaths.isEmpty else {
                job.errorMessage = "Recovered the running pod. Progress will stay visible, but automatic re-upload/finalization needs the matching project open."
                currentJob = job
                return
            }

            let huggingFaceToken = try Self.loadLocalHuggingFaceToken()
            job.status = .uploading
            currentJob = job
            try await uploadImages(
                imagePaths: job.config.selectedImagePaths,
                sshHost: host,
                sshPort: port,
                identityFile: sshKeyPair.privateKeyPath,
                triggerWord: job.triggerWord,
                subjectClassNoun: job.config.subjectClassNoun
            )
            job.status = .training
            currentJob = job
            try await runTraining(
                sshHost: host,
                sshPort: port,
                identityFile: sshKeyPair.privateKeyPath,
                huggingFaceToken: huggingFaceToken.value,
                job: &job,
                onProgress: { _ in }
            )
            if let animateURL {
                try await finalizeCompletedTraining(
                    job: &job,
                    sshHost: host,
                    sshPort: port,
                    identityFile: sshKeyPair.privateKeyPath,
                    animateURL: animateURL,
                    onProgress: { _ in }
                )
                await terminatePod(podID: podID)
                scheduleQueuedJobLaunchIfNeeded()
            } else {
                job.errorMessage = "Training recovered, but automatic file capture still needs the matching project open."
                currentJob = job
            }
        } catch {
            LORALogger.shared.log("Failed to resume persisted RunPod job: \(error.localizedDescription)", level: "ERROR")
            if await preserveActivePodForAutomaticRecoveryIfPossible(after: error, job: &job, onProgress: { _ in }) {
                return
            }
            job.status = .error
            job.errorMessage = "Failed to resume persisted training: \(error.localizedDescription)"
            currentJob = job
        }
    }

    /// Generate the Python training script to upload to the pod.
    private static func generateTrainingScript(
        baseModel: LORATrainingModels.BaseModel,
        triggerWord: String,
        steps: Int,
        networkDim: Int,
        networkAlpha: Int,
        learningRate: Double,
        resolution: Int
    ) -> String {
        let saveEvery = max(steps / 4, 100)
        let triggerWordLiteral = Self.pythonQuoted(triggerWord)
        let modelVersionLiteral = Self.pythonQuoted(baseModel.modelVersion)
        let ditFilenameLiteral = Self.pythonQuoted(baseModel.modelFilename)
        let textEncoderShardLiteral = Self.pythonQuoted(baseModel.primaryTextEncoderShard)
        return """
        import glob
        import json
        import os
        import re
        import shutil
        import subprocess
        import sys

        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)

        def emit_progress(message: str) -> None:
            print(message, flush=True)

        emit_progress("PROGRESS:phase=training,status=starting")

        dataset_dir = "/workspace/dataset"
        output_dir = "/workspace/output"
        trigger_word = \(triggerWordLiteral)
        steps = \(steps)
        network_dim = \(networkDim)
        network_alpha = \(networkAlpha)
        learning_rate = \(learningRate)
        resolution = \(resolution)
        save_every = \(saveEvery)

        os.makedirs(output_dir, exist_ok=True)
        cache_dir = "/workspace/cache"
        os.makedirs(cache_dir, exist_ok=True)

        with open("/workspace/gpu_info.json", encoding="utf-8") as f:
            gpu_info = json.load(f)
        supports_bf16 = gpu_info["supports_bf16"]
        mixed_prec = "bf16" if supports_bf16 else "fp16"

        model_version = \(modelVersionLiteral)
        latent_cache_vae_dtype = "fp16" if model_version == "klein-base-9b" else mixed_prec
        dit_filename = \(ditFilenameLiteral)
        text_encoder_shard = \(textEncoderShardLiteral)

        dit_path = f"/workspace/models/{dit_filename}"
        vae_path = "/workspace/models/ae.safetensors"
        te_path = f"/workspace/models/{text_encoder_shard}"

        def require_file(path: str, label: str) -> None:
            if not os.path.isfile(path):
                raise RuntimeError(f"{label} not found at {path}")

        require_file(dit_path, "DiT")
        require_file(vae_path, "AE")
        require_file(te_path, "Text encoder shard 1")

        image_patterns = ("*.png", "*.jpg", "*.jpeg", "*.webp")
        images = sorted(
            image_path
            for pattern in image_patterns
            for image_path in glob.glob(os.path.join(dataset_dir, pattern))
        )
        print(f"Dataset: {len(images)} images")
        if not images:
            raise RuntimeError(f"No images found in {dataset_dir}")

        config_path = "/workspace/dataset.toml"
        with open(config_path, "w", encoding="utf-8") as f:
            f.write(f'''[general]
        resolution = [{resolution}, {resolution}]
        caption_extension = ".txt"
        batch_size = 1
        enable_bucket = true

        [[datasets]]
        image_directory = "{dataset_dir}"
        cache_directory = "{cache_dir}"
        num_repeats = 10
        ''')

        def run_cache_latents(vae_dtype: str) -> None:
            shutil.rmtree(cache_dir, ignore_errors=True)
            os.makedirs(cache_dir, exist_ok=True)
            subprocess.run([sys.executable, "/workspace/musubi-tuner/src/musubi_tuner/flux_2_cache_latents.py",
                "--dataset_config", config_path, "--vae", vae_path,
                "--model_version", model_version, "--vae_dtype", vae_dtype], check=True)

        def run_cache_text_encoder(use_fp8: bool) -> None:
            te_cmd = [sys.executable, "/workspace/musubi-tuner/src/musubi_tuner/flux_2_cache_text_encoder_outputs.py",
                "--dataset_config", config_path, "--text_encoder", te_path,
                "--batch_size", "4", "--model_version", model_version]
            if use_fp8:
                te_cmd.append("--fp8_text_encoder")
            subprocess.run(te_cmd, check=True)

        emit_progress("PROGRESS:phase=training,status=caching_latents")
        emit_progress(f"PROGRESS:phase=training,cache_vae_dtype={latent_cache_vae_dtype}")
        try:
            run_cache_latents(latent_cache_vae_dtype)
        except subprocess.CalledProcessError:
            if latent_cache_vae_dtype == "fp16":
                raise
            emit_progress("PROGRESS:phase=training,status=caching_latents_retry_fp16")
            run_cache_latents("fp16")

        emit_progress("PROGRESS:phase=training,status=caching_text_encoder")
        use_fp8_text_encoder = supports_bf16
        try:
            run_cache_text_encoder(use_fp8_text_encoder)
        except subprocess.CalledProcessError:
            if not use_fp8_text_encoder:
                raise
            emit_progress("PROGRESS:phase=training,status=caching_text_encoder_retry_no_fp8")
            use_fp8_text_encoder = False
            run_cache_text_encoder(use_fp8_text_encoder)

        emit_progress("PROGRESS:phase=training,status=training_started")
        train_cmd = ["/workspace/venv/bin/accelerate", "launch", "--num_cpu_threads_per_process", "1",
            "--mixed_precision", mixed_prec,
            "/workspace/musubi-tuner/src/musubi_tuner/flux_2_train_network.py",
            "--model_version", model_version,
            "--dit", dit_path, "--vae", vae_path, "--text_encoder", te_path,
            "--dataset_config", config_path, "--sdpa",
            "--mixed_precision", mixed_prec,
            "--timestep_sampling", "flux2_shift", "--weighting_scheme", "none",
            "--optimizer_type", "adamw8bit", "--learning_rate", str(learning_rate),
            "--gradient_checkpointing", "--max_data_loader_n_workers", "2",
            "--persistent_data_loader_workers",
            "--network_module", "networks.lora_flux_2",
            "--network_dim", str(network_dim), "--network_alpha", str(network_alpha),
            "--max_train_steps", str(steps), "--save_every_n_steps", str(save_every),
            "--seed", "42", "--output_dir", output_dir, "--output_name", trigger_word]
        if use_fp8_text_encoder and supports_bf16:
            train_cmd.extend(["--fp8_base", "--fp8_scaled", "--fp8_text_encoder"])

        process = subprocess.Popen(train_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        if process.stdout is None:
            raise RuntimeError("Training process did not expose stdout")
        step_pat = re.compile("steps?[:\\\\s]+(\\\\d+)/(\\\\d+)", re.IGNORECASE)
        loss_pat = re.compile("loss[=:\\\\s]+([0-9.eE+-]+|nan|inf|-inf)", re.IGNORECASE)
        for line in process.stdout:
            line = line.rstrip()
            print(line, flush=True)
            sm = step_pat.search(line)
            lm = loss_pat.search(line)
            if sm:
                emit_progress(f"PROGRESS:phase=training,step={sm.group(1)},total={sm.group(2)},loss={lm.group(1) if lm else 'n/a'}")
        process.wait()
        if process.returncode != 0:
            raise RuntimeError(f"Training failed (exit {process.returncode})")

        safetensors = glob.glob(os.path.join(output_dir, "*.safetensors"))
        if not safetensors:
            raise RuntimeError(f"No .safetensors output found in {output_dir}")
        safetensors.sort(key=os.path.getmtime)
        final = safetensors[-1]
        expected = os.path.join(output_dir, f"{trigger_word}.safetensors")
        if final != expected:
            shutil.copy2(final, expected)

        emit_progress("PROGRESS:phase=done")
        """
    }

    private nonisolated static func pythonQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func downloadLORA(
        sshHost: String,
        sshPort: Int,
        identityFile: String,
        triggerWord: String,
        localPath: URL,
        podID: String?
    ) async throws {
        let remotePath = "/workspace/output/\(triggerWord).safetensors"
        let tempURL = localPath.deletingLastPathComponent()
            .appendingPathComponent(localPath.lastPathComponent + ".downloading")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        var activeHost = sshHost
        var activePort = sshPort
        var lastError: Error?
        let maxAttempts = 5

        for attempt in 1...maxAttempts {
            do {
                let remoteSize = try await remoteFileSize(
                    host: activeHost,
                    port: activePort,
                    identityFile: identityFile,
                    remotePath: remotePath
                )
                guard remoteSize > 0 else {
                    throw LORAError.downloadFailed(detail: "Remote LORA file exists but has size 0 bytes: \(remotePath)")
                }

                try await scpDownload(
                    remotePath: remotePath,
                    localPath: tempURL.path,
                    host: activeHost,
                    port: activePort,
                    identityFile: identityFile
                )

                let localAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let localSize = (localAttributes[.size] as? NSNumber)?.int64Value ?? 0
                guard localSize == remoteSize else {
                    throw LORAError.downloadFailed(detail: "Downloaded LORA size mismatch (local \(localSize) bytes vs remote \(remoteSize) bytes)")
                }

                _ = try archiveExistingLoRAIfNeeded(at: localPath)
                if FileManager.default.fileExists(atPath: localPath.path) {
                    try? FileManager.default.removeItem(at: localPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: localPath)
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: tempURL)
                guard attempt < maxAttempts else { break }

                LORALogger.shared.log(
                    "Final LORA download attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)",
                    level: "WARN"
                )

                if let podID, !podID.isEmpty {
                    do {
                        let (recoveredHost, recoveredPort) = try await waitForPodConnectionDetails(podID: podID)
                        try await waitForSSHReady(host: recoveredHost, port: recoveredPort, identityFile: identityFile)
                        activeHost = recoveredHost
                        activePort = recoveredPort
                    } catch {
                        lastError = error
                    }
                }

                try? await Task.sleep(for: .seconds(attempt * 4))
            }
        }

        throw lastError ?? LORAError.downloadFailed(detail: "Unknown final LORA download failure")
    }

    private func remoteFileSize(
        host: String,
        port: Int,
        identityFile: String,
        remotePath: String
    ) async throws -> Int64 {
        let command = """
        python3 - <<'PY'
        import os
        path = \(Self.pythonQuoted(remotePath))
        if not os.path.isfile(path):
            raise SystemExit(2)
        print(os.path.getsize(path))
        PY
        """
        let output = try await sshCommandChecked(
            host: host,
            port: port,
            identityFile: identityFile,
            command: command,
            failureContext: "Failed to inspect remote LORA output"
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int64(trimmed) else {
            throw LORAError.downloadFailed(detail: "Could not parse remote file size for \(remotePath): \(trimmed)")
        }
        return size
    }

    private func resolveLiveCommunityHourlyRate(
        for baseModel: LORATrainingModels.BaseModel
    ) async -> Double? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let prices = try await runPodAccountService.fetchGPUPrices(apiKey: apiKey)
            return prices.first(where: { $0.displayName == baseModel.gpuType })?.communityPrice
        } catch {
            return nil
        }
    }

    // MARK: - Shell Helpers
    //
    // All ssh/scp invocations capture BOTH stdout and stderr and feed them
    // into the LORA log file so failures are never silent. scp uses `-O` to
    // force the legacy SCP protocol — modern macOS scp defaults to SFTP,
    // which fails against RunPod pytorch images that don't ship sftp-server
    // (this was the actual cause of "Failed to upload images to pod").

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var combined: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private nonisolated func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            environment.forEach { merged[$0.key] = $0.value }
            process.environment = merged
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        async let stdoutData: Data = Task.detached(priority: .utility) {
            outPipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let stderrData: Data = Task.detached(priority: .utility) {
            errPipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        process.waitUntilExit()
        let out = String(data: await stdoutData, encoding: .utf8) ?? ""
        let err = String(data: await stderrData, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    @discardableResult
    private nonisolated func sshCommand(host: String, port: Int, identityFile: String, command: String) async throws -> String {
        LORALogger.shared.log("ssh root@\(host):\(port) › \(Self.redactedForLogs(command).prefix(200))", level: "SSH")
        let result = try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "IdentitiesOnly=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=6",
                "-o", "ConnectTimeout=15",
                "-i", identityFile,
                "-p", "\(port)",
                "root@\(host)",
                command
            ]
        )
        if result.exitCode != 0 {
            LORALogger.shared.log("ssh exit=\(result.exitCode) stderr=\(Self.redactedForLogs(result.stderr).prefix(500))", level: "ERROR")
        } else if !result.stderr.isEmpty {
            LORALogger.shared.log("ssh stderr (non-fatal): \(Self.redactedForLogs(result.stderr).prefix(300))", level: "WARN")
        }
        if !result.stdout.isEmpty {
            LORALogger.shared.log("ssh stdout: \(Self.redactedForLogs(result.stdout).prefix(500))", level: "SSH")
        }
        // Merge stderr into returned output so callers that only check stdout
        // still see the failure context.
        return result.combined
    }

    @discardableResult
    private nonisolated func sshCommandChecked(
        host: String,
        port: Int,
        identityFile: String,
        command: String,
        failureContext: String
    ) async throws -> String {
        LORALogger.shared.log("ssh root@\(host):\(port) › \(Self.redactedForLogs(command).prefix(200))", level: "SSH")
        let result = try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "IdentitiesOnly=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=6",
                "-o", "ConnectTimeout=15",
                "-i", identityFile,
                "-p", "\(port)",
                "root@\(host)",
                command
            ]
        )
        if result.exitCode != 0 {
            let rawDetail = result.stderr.isEmpty ? result.stdout : result.stderr
            let detail = Self.redactedForLogs(Self.trimmedRemoteError(rawDetail))
            LORALogger.shared.log("ssh exit=\(result.exitCode) stderr=\(Self.redactedForLogs(detail))", level: "ERROR")
            throw LORAError.trainingFailed(detail: "\(failureContext) (exit \(result.exitCode)): \(detail)")
        }
        if !result.stderr.isEmpty {
            LORALogger.shared.log("ssh stderr (non-fatal): \(Self.redactedForLogs(result.stderr).prefix(300))", level: "WARN")
        }
        if !result.stdout.isEmpty {
            LORALogger.shared.log("ssh stdout: \(Self.redactedForLogs(result.stdout).prefix(500))", level: "SSH")
        }
        return result.combined
    }

    private nonisolated static func trimmedRemoteError(_ text: String, maxLength: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No stderr output." }
        return String(trimmed.prefix(maxLength))
    }

    private nonisolated func isLikelySSHTransportFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let needles = [
            "broken pipe",
            "operation timed out",
            "connection refused",
            "connection reset",
            "connection closed",
            "no route to host",
            "network is unreachable",
            "ssh exit=255"
        ]
        return needles.contains(where: message.contains)
    }

    private nonisolated static func redactedForLogs(_ text: String) -> String {
        var redacted = text
        let patterns = [
            #"(?<=HF_TOKEN=')[^']+"#,
            #"(?<=HF_TOKEN=")[^"]+"#,
            #"(?<=HF_TOKEN=)[^\s]+"#,
            #"hf_[A-Za-z0-9]{20,}"#,
            #"(?<=Authorization:\sBearer\s)[A-Za-z0-9._\-]+"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
        return redacted
    }

    private nonisolated func waitForSSHReady(
        host: String,
        port: Int,
        identityFile: String,
        maxAttempts: Int = 24
    ) async throws {
        LORALogger.shared.log("Probing sshd on \(host):\(port) (up to \(maxAttempts * 5)s)", level: "POD")
        for attempt in 1...maxAttempts {
            let result = try await runProcess(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "LogLevel=ERROR",
                    "-o", "IdentitiesOnly=yes",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=4",
                    "-o", "ConnectTimeout=5",
                    "-o", "BatchMode=yes",
                    "-i", identityFile,
                    "-p", "\(port)",
                    "root@\(host)",
                    "echo ready"
                ]
            )
            if result.exitCode == 0 && result.stdout.contains("ready") {
                LORALogger.shared.log("sshd accepting connections after \(attempt) attempt(s)", level: "POD")
                return
            }
            LORALogger.shared.log("sshd not ready yet (attempt \(attempt)/\(maxAttempts)): \(result.stderr.prefix(120))", level: "POD")
            try await Task.sleep(for: .seconds(5))
        }
        throw LORAError.sshNotAvailable
    }

    private nonisolated func scpUpload(
        localPath: String,
        remotePath: String,
        host: String,
        port: Int,
        identityFile: String
    ) async throws {
        // Verify the local file actually exists — gallery paths are a mix of
        // absolute and relative, and this is the single most common cause of
        // a silent scp failure we've seen in the wild.
        guard FileManager.default.fileExists(atPath: localPath) else {
            let detail = "Local file does not exist: \(localPath)"
            LORALogger.shared.log(detail, level: "ERROR")
            throw LORAError.uploadFailed(detail: detail)
        }

        LORALogger.shared.log("scp ↑ \(localPath) → root@\(host):\(remotePath)", level: "SCP")
        let result = try await runProcess(
            executable: "/usr/bin/scp",
            arguments: [
                "-O",                              // force legacy SCP protocol (macOS 13+ defaults to SFTP)
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "IdentitiesOnly=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=6",
                "-o", "ConnectTimeout=15",
                "-i", identityFile,
                "-P", "\(port)",
                localPath,
                "root@\(host):\(remotePath)"
            ]
        )
        if result.exitCode != 0 {
            let detail = "scp upload failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)"
            LORALogger.shared.log(detail, level: "ERROR")
            throw LORAError.uploadFailed(detail: detail)
        }
        LORALogger.shared.log("scp ↑ OK \(URL(fileURLWithPath: localPath).lastPathComponent)", level: "SCP")
    }

    private nonisolated func scpDownload(
        remotePath: String,
        localPath: String,
        host: String,
        port: Int,
        identityFile: String
    ) async throws {
        LORALogger.shared.log("scp ↓ root@\(host):\(remotePath) → \(localPath)", level: "SCP")
        let result = try await runProcess(
            executable: "/usr/bin/scp",
            arguments: [
                "-O",                              // force legacy SCP protocol
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "IdentitiesOnly=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=6",
                "-o", "ConnectTimeout=15",
                "-i", identityFile,
                "-P", "\(port)",
                "root@\(host):\(remotePath)",
                localPath
            ]
        )
        if result.exitCode != 0 {
            let detail = "scp download failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)"
            LORALogger.shared.log(detail, level: "ERROR")
            throw LORAError.downloadFailed(detail: detail)
        }
        LORALogger.shared.log("scp ↓ OK \(URL(fileURLWithPath: localPath).lastPathComponent)", level: "SCP")
    }

    // MARK: - GraphQL

    private func graphqlRequest(query: String) async throws -> [String: Any] {
        let maxAttempts = 4
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                var request = URLRequest(url: URL(string: graphqlURL)!)
                request.httpMethod = "POST"
                request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
                let (data, _) = try await URLSession.shared.data(for: request)
                let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if let errors = payload["errors"] as? [[String: Any]], !errors.isEmpty {
                    let message = errors.compactMap { $0["message"] as? String }.joined(separator: " | ")
                    throw LORAError.trainingFailed(detail: "RunPod API error: \(message)")
                }
                return payload
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                LORALogger.shared.log(
                    "RunPod GraphQL request failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription)",
                    level: "WARN"
                )
                try? await Task.sleep(for: .seconds(attempt * 2))
            }
        }

        throw lastError ?? LORAError.trainingFailed(detail: "RunPod GraphQL request failed with an unknown error.")
    }

    // MARK: - Watchdog (Safety)

    private func startWatchdog(podID: String) {
        watchdogTask?.cancel()
        watchdogTask = Task {
            // Heartbeat every 60s. If the app dies, no heartbeat = pod stays running.
            // We write a watchdog file; an external process or next launch can reap it.
            let watchdogPath = FileManager.default.temporaryDirectory.appendingPathComponent("amira-runpod-watchdog.json")
            while !Task.isCancelled {
                let info: [String: Any] = [
                    "podID": podID,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "pid": ProcessInfo.processInfo.processIdentifier
                ]
                if let data = try? JSONSerialization.data(withJSONObject: info) {
                    try? data.write(to: watchdogPath, options: .atomic)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        let watchdogPath = FileManager.default.temporaryDirectory.appendingPathComponent("amira-runpod-watchdog.json")
        try? FileManager.default.removeItem(at: watchdogPath)
    }

    /// Manual cancel requested from the UI.
    func terminateAllPods() {
        restoreTask?.cancel()
        restoreTask = nil
        if let podID = currentJob?.podID {
            mutateCurrentJob { $0.status = .stopping }
            Task { await terminatePod(podID: podID) }
        } else {
            mutateCurrentJob {
                $0.status = .inactive
                $0.completedAt = $0.completedAt ?? Date()
            }
        }
        stopWatchdog()
    }

    // MARK: - Errors

    enum LORAError: LocalizedError {
        case noAPIKey, podCreationFailed(detail: String), podNotFound, podStartTimeout
        case missingHuggingFaceToken(detail: String)
        case missingHuggingFaceAccess(detail: String)
        case sshNotAvailable
        case uploadFailed(detail: String)
        case downloadFailed(detail: String)
        case trainingFailed(detail: String)
        case imagePathMissing(path: String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "RunPod API key not set. Go to API Settings → RunPod tab."
            case .podCreationFailed(let detail): "Failed to create RunPod instance: \(detail)"
            case .podNotFound: "RunPod instance not found."
            case .podStartTimeout: "Pod failed to start within 5 minutes."
            case .missingHuggingFaceToken(let detail): "HuggingFace token missing: \(detail)"
            case .missingHuggingFaceAccess(let detail): "HuggingFace access missing: \(detail)"
            case .sshNotAvailable: "SSH connection not available on pod."
            case .uploadFailed(let detail): "Upload failed: \(detail)"
            case .downloadFailed(let detail): "Download failed: \(detail)"
            case .trainingFailed(let detail): "Training failed: \(detail)"
            case .imagePathMissing(let path): "Image path missing on disk: \(path)"
            }
        }
    }
}
