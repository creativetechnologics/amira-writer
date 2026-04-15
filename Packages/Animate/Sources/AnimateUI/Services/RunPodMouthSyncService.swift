import Combine
import Foundation

final class RunPodMouthSyncLogger: @unchecked Sendable {
    static let shared = RunPodMouthSyncLogger()

    let logFileURL: URL
    private let queue = DispatchQueue(label: "amira.runpod.mouthsync.logger")
    private let formatter: DateFormatter

    private init() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        self.logFileURL = logDir.appendingPathComponent("runpod-mouth-sync.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = formatter
    }

    func log(_ message: String, level: String = "INFO") {
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] [\(level)] \(message)\n"
        queue.async { [logFileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logFileURL.path),
               let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
            NSLog("[RunPodMouthSync] \(message)")
        }
    }

    func logSection(_ title: String) {
        log("═══ \(title) ═══")
    }
}

@available(macOS 26.0, *)
@MainActor
final class RunPodMouthSyncService: ObservableObject {
    static let shared = RunPodMouthSyncService()

    @Published var currentJob: RunPodMouthSyncModels.InferenceJob? {
        didSet {
            if let currentJob {
                podStatus = currentJob.status
            } else if podStatus != .inactive {
                podStatus = .inactive
            }
            persistCurrentJobSnapshot()
        }
    }

    @Published var recentJobs: [RunPodMouthSyncModels.InferenceJob] = [] {
        didSet { persistRecentJobsSnapshot() }
    }

    @Published var podStatus: RunPodMouthSyncModels.PodStatus = .inactive

    var logFilePath: String { RunPodMouthSyncLogger.shared.logFileURL.path }
    var hasAPIKey: Bool { !apiKey.isEmpty }
    var hasActiveJob: Bool { currentJob?.status.isActive == true }

    private var apiKey: String = ""
    private var watchdogTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var activeAnimateURL: URL?
    private let graphqlURL = "https://api.runpod.io/graphql"

    private struct LocalSSHKeyPair: Sendable {
        let privateKeyPath: String
        let publicKey: String
        let publicKeyPath: String
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var combined: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private init() {
        loadAPIKey()
        recentJobs = loadRecentJobsFromDisk()

        if let restoredJob = loadPersistedJobFromDisk() {
            currentJob = restoredJob
            podStatus = restoredJob.status
            if restoredJob.status.isActive {
                restoreTask = Task { @MainActor in
                    await terminateRecoveredJobIfNeeded()
                }
            }
        }
    }

    func setActiveAnimateURL(_ url: URL?) {
        activeAnimateURL = url
    }

    func loadAPIKey() {
        apiKey = RunPodCredentialStore().loadAPIKey()
    }

    func startInference(
        sourceVideoURL: URL,
        audioURL: URL,
        outputVideoURL: URL,
        config: RunPodMouthSyncModels.InferenceConfig,
        onProgress: @escaping @MainActor (RunPodMouthSyncModels.InferenceJob) -> Void = { _ in }
    ) async throws {
        restoreTask?.cancel()
        restoreTask = nil
        loadAPIKey()

        guard hasAPIKey else {
            throw RunPodMouthSyncError.noAPIKey
        }
        guard FileManager.default.fileExists(atPath: sourceVideoURL.path) else {
            throw RunPodMouthSyncError.localInputMissing(path: sourceVideoURL.path)
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw RunPodMouthSyncError.localInputMissing(path: audioURL.path)
        }

        let sshKeyPair = try Self.loadLocalSSHKeyPair()
        let sourceExt = sourceVideoURL.pathExtension.isEmpty ? "mp4" : sourceVideoURL.pathExtension
        let audioExt = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
        let remoteVideoPath = "/workspace/input/source.\(sourceExt)"
        let remoteAudioPath = "/workspace/input/audio.\(audioExt)"
        let remoteOutputPath = "/workspace/output/v15/amira_musetalk_output.mp4"

        var job = RunPodMouthSyncModels.InferenceJob(
            sourceVideoPath: sourceVideoURL.path,
            audioPath: audioURL.path,
            outputVideoPath: outputVideoURL.path,
            config: config,
            status: .creating,
            statusMessage: "Preparing MuseTalk RunPod job",
            remoteOutputPath: remoteOutputPath,
            startedAt: Date()
        )
        currentJob = job
        onProgress(job)

        RunPodMouthSyncLogger.shared.logSection(
            "MuseTalk inference start video=\(sourceVideoURL.lastPathComponent) audio=\(audioURL.lastPathComponent) gpu=\(config.gpuProfile.displayName)"
        )

        do {
            await ensureWatchdogMonitorRunning()

            let podID = try await createPod(
                gpuType: config.gpuProfile.gpuType,
                name: "amira-musetalk-\(job.id.uuidString.prefix(8))",
                sshPublicKey: sshKeyPair.publicKey,
                containerDiskGB: config.gpuProfile.containerDiskGB
            )
            job.podID = podID
            job.status = .starting
            job.statusMessage = "Waiting for RunPod SSH"
            currentJob = job
            onProgress(job)

            let (host, port) = try await waitForPodConnectionDetails(podID: podID)
            try await waitForSSHReady(host: host, port: port, identityFile: sshKeyPair.privateKeyPath)

            job.status = .uploading
            job.statusMessage = "Uploading source video and audio"
            currentJob = job
            onProgress(job)

            try await sshCommandChecked(
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath,
                command: "mkdir -p /workspace/input /workspace/output /workspace/AmiraMuseTalk",
                failureContext: "Failed to create MuseTalk workspace on pod"
            )

            try await scpUpload(
                localPath: sourceVideoURL.path,
                remotePath: remoteVideoPath,
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath
            )
            try await scpUpload(
                localPath: audioURL.path,
                remotePath: remoteAudioPath,
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath
            )

            let bootstrapScriptURL = try writeTemporaryScript(
                prefix: "bootstrap-musetalk",
                contents: Self.generateBootstrapScript(repoURL: config.modelVersion.repoURL)
            )
            defer { try? FileManager.default.removeItem(at: bootstrapScriptURL) }

            let inferenceScriptURL = try writeTemporaryScript(
                prefix: "run-musetalk",
                contents: Self.generateInferenceScript(
                    remoteVideoPath: remoteVideoPath,
                    remoteAudioPath: remoteAudioPath,
                    remoteOutputFilename: "amira_musetalk_output.mp4",
                    config: config
                )
            )
            defer { try? FileManager.default.removeItem(at: inferenceScriptURL) }

            try await scpUpload(
                localPath: bootstrapScriptURL.path,
                remotePath: "/workspace/AmiraMuseTalk/bootstrap_musetalk.sh",
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath
            )
            try await scpUpload(
                localPath: inferenceScriptURL.path,
                remotePath: "/workspace/AmiraMuseTalk/run_musetalk.sh",
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath
            )

            job.status = .settingUp
            job.statusMessage = config.downloadModelsEachRun
                ? "Bootstrapping MuseTalk and downloading weights"
                : "Bootstrapping MuseTalk"
            currentJob = job
            onProgress(job)

            _ = try await sshCommandChecked(
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath,
                command: "chmod +x /workspace/AmiraMuseTalk/bootstrap_musetalk.sh /workspace/AmiraMuseTalk/run_musetalk.sh && /workspace/AmiraMuseTalk/bootstrap_musetalk.sh",
                failureContext: "MuseTalk environment setup failed"
            )

            job.status = .inferencing
            job.statusMessage = "Running MuseTalk inference"
            currentJob = job
            onProgress(job)

            _ = try await sshCommandChecked(
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath,
                command: "/workspace/AmiraMuseTalk/run_musetalk.sh",
                failureContext: "MuseTalk inference failed"
            )

            job.status = .downloading
            job.statusMessage = "Downloading rendered video"
            currentJob = job
            onProgress(job)

            try await downloadRenderedVideo(
                remotePath: remoteOutputPath,
                localOutputURL: outputVideoURL,
                host: host,
                port: port,
                identityFile: sshKeyPair.privateKeyPath
            )

            job.status = .inactive
            job.statusMessage = "MuseTalk render complete"
            job.completedAt = Date()
            currentJob = job
            appendRecentJob(job)
            onProgress(job)

            await terminatePod(podID: podID)
        } catch {
            RunPodMouthSyncLogger.shared.log("MuseTalk inference failed: \(error.localizedDescription)", level: "ERROR")
            job.status = .error
            job.errorMessage = error.localizedDescription
            job.completedAt = Date()
            currentJob = job
            appendRecentJob(job)
            onProgress(job)

            if let podID = job.podID {
                await terminatePod(podID: podID)
            } else {
                stopWatchdog()
            }
            throw error
        }
    }

    func terminateAllPods() {
        restoreTask?.cancel()
        restoreTask = nil
        if let podID = currentJob?.podID {
            mutateCurrentJob {
                $0.status = .stopping
                $0.statusMessage = "Terminating RunPod pod"
            }
            Task { await terminatePod(podID: podID) }
        } else {
            mutateCurrentJob {
                $0.status = .inactive
                $0.completedAt = $0.completedAt ?? Date()
            }
            stopWatchdog()
        }
    }

    private func terminateRecoveredJobIfNeeded() async {
        defer { restoreTask = nil }
        loadAPIKey()
        guard var job = currentJob, job.status.isActive else { return }
        guard let podID = job.podID, !podID.isEmpty else {
            job.status = .error
            job.errorMessage = "Recovered a stale MuseTalk RunPod job without a pod ID."
            currentJob = job
            return
        }

        guard hasAPIKey else {
            job.status = .error
            job.errorMessage = "Recovered a MuseTalk RunPod job but RunPod API key is missing. Re-enter it so the pod can be terminated."
            currentJob = job
            return
        }

        RunPodMouthSyncLogger.shared.log("Recovered active MuseTalk pod \(podID); terminating it for safety", level: "WARN")
        await terminatePod(podID: podID)
        job.status = .error
        job.errorMessage = "Recovered an in-flight MuseTalk RunPod job after app relaunch and terminated the pod for safety."
        job.completedAt = Date()
        currentJob = job
        appendRecentJob(job)
    }

    private func appendRecentJob(_ job: RunPodMouthSyncModels.InferenceJob) {
        recentJobs.removeAll { $0.id == job.id }
        recentJobs.insert(job, at: 0)
        if recentJobs.count > 20 {
            recentJobs = Array(recentJobs.prefix(20))
        }
    }

    private func mutateCurrentJob(_ mutate: (inout RunPodMouthSyncModels.InferenceJob) -> Void) {
        guard var currentJob else { return }
        mutate(&currentJob)
        self.currentJob = currentJob
    }

    private var persistedJobURL: URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("active-runpod-mouth-sync-job.json")
    }

    private var recentJobsURL: URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("recent-runpod-mouth-sync-jobs.json")
    }

    private var watchdogHeartbeatURL: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amira-runpod-watchdogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("musetalk-inference.json")
    }

    private func loadPersistedJobFromDisk() -> RunPodMouthSyncModels.InferenceJob? {
        guard FileManager.default.fileExists(atPath: persistedJobURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: persistedJobURL)
            return try JSONDecoder().decode(RunPodMouthSyncModels.InferenceJob.self, from: data)
        } catch {
            RunPodMouthSyncLogger.shared.log("Failed to load persisted MuseTalk RunPod job: \(error.localizedDescription)", level: "WARN")
            return nil
        }
    }

    private func loadRecentJobsFromDisk() -> [RunPodMouthSyncModels.InferenceJob] {
        guard FileManager.default.fileExists(atPath: recentJobsURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: recentJobsURL)
            return try JSONDecoder().decode([RunPodMouthSyncModels.InferenceJob].self, from: data)
        } catch {
            RunPodMouthSyncLogger.shared.log("Failed to load recent MuseTalk RunPod jobs: \(error.localizedDescription)", level: "WARN")
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
            RunPodMouthSyncLogger.shared.log("Failed to persist MuseTalk RunPod job: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func persistRecentJobsSnapshot() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recentJobs)
            try data.write(to: recentJobsURL, options: .atomic)
        } catch {
            RunPodMouthSyncLogger.shared.log("Failed to persist recent MuseTalk jobs: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func ensureWatchdogMonitorRunning() async {
        guard let scriptURL = runPodMonitorScriptURL() else {
            RunPodMouthSyncLogger.shared.log("RunPod watchdog script not found in known locations", level: "WARN")
            return
        }

        do {
            let result = try await runProcess(
                executable: "/usr/bin/python3",
                arguments: [scriptURL.path, "ensure-monitor"]
            )
            let output = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                RunPodMouthSyncLogger.shared.log("RunPod watchdog: \(output)", level: "POD")
            }
        } catch {
            RunPodMouthSyncLogger.shared.log("Failed to ensure RunPod watchdog monitor: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func runPodMonitorScriptURL() -> URL? {
        let candidates: [URL] = [
            URL(fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/runpod_pod_monitor.py"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Scripts/runpod_pod_monitor.py"),
            activeAnimateURL?.deletingLastPathComponent().appendingPathComponent("Scripts/runpod_pod_monitor.py")
        ].compactMap { $0 }

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func createPod(
        gpuType: String,
        name: String,
        sshPublicKey: String,
        containerDiskGB: Int
    ) async throws -> String {
        podStatus = .creating
        RunPodMouthSyncLogger.shared.logSection("Creating pod gpu=\(gpuType) name=\(name)")

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
            throw RunPodMouthSyncError.podCreationFailed(detail: "GraphQL response missing pod id: \(result)")
        }

        RunPodMouthSyncLogger.shared.log("Pod created: \(podID)", level: "POD")
        podStatus = .starting
        startWatchdog(podID: podID)
        return podID
    }

    private func getPodStatus(podID: String) async throws -> (status: String, sshHost: String?, sshPort: Int?) {
        let query = """
        query { pod(input: { podId: "\(podID)" }) { id desiredStatus runtime { uptimeInSeconds ports { ip isIpPublic privatePort publicPort type } } } }
        """
        let result = try await graphqlRequest(query: query)
        guard let data = result["data"] as? [String: Any],
              let pod = data["pod"] as? [String: Any] else {
            throw RunPodMouthSyncError.podNotFound
        }

        let status = pod["desiredStatus"] as? String ?? "UNKNOWN"
        var sshHost: String?
        var sshPort: Int?

        if let runtime = pod["runtime"] as? [String: Any],
           let ports = runtime["ports"] as? [[String: Any]] {
            for port in ports where port["privatePort"] as? Int == 22 {
                sshHost = port["ip"] as? String
                sshPort = port["publicPort"] as? Int
            }
        }

        return (status, sshHost, sshPort)
    }

    private func terminatePod(podID: String) async {
        podStatus = .stopping
        let query = """
        mutation { podTerminate(input: { podId: "\(podID)" }) }
        """
        _ = try? await graphqlRequest(query: query)
        podStatus = .inactive
        mutateCurrentJob {
            if $0.status != .error {
                $0.status = .inactive
                $0.statusMessage = "RunPod pod terminated"
            }
            $0.completedAt = $0.completedAt ?? Date()
            $0.podID = nil
        }
        stopWatchdog()
    }

    private func waitForPodConnectionDetails(
        podID: String,
        maxAttempts: Int = 60
    ) async throws -> (host: String, port: Int) {
        RunPodMouthSyncLogger.shared.log("Waiting for pod to become RUNNING on pod \(podID)", level: "POD")
        for attempt in 1...maxAttempts {
            do {
                let (status, host, port) = try await getPodStatus(podID: podID)
                let normalizedStatus = status.uppercased()
                if normalizedStatus == "TERMINATED" || normalizedStatus == "EXITED" {
                    throw RunPodMouthSyncError.inferenceFailed(detail: "RunPod pod \(podID) is no longer running (\(status)).")
                }
                if status == "RUNNING", let host, let port {
                    return (host, port)
                }
            } catch let error as RunPodMouthSyncError {
                throw error
            } catch {
                RunPodMouthSyncLogger.shared.log("Transient pod status check failure (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription)", level: "WARN")
            }
            try? await Task.sleep(for: .seconds(5))
        }
        throw RunPodMouthSyncError.podStartTimeout
    }

    private func downloadRenderedVideo(
        remotePath: String,
        localOutputURL: URL,
        host: String,
        port: Int,
        identityFile: String
    ) async throws {
        let outputDir = localOutputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let tempURL = outputDir.appendingPathComponent(localOutputURL.lastPathComponent + ".downloading")
        try? FileManager.default.removeItem(at: tempURL)

        try await scpDownload(
            remotePath: remotePath,
            localPath: tempURL.path,
            host: host,
            port: port,
            identityFile: identityFile
        )

        if FileManager.default.fileExists(atPath: localOutputURL.path) {
            _ = try FileManager.default.replaceItemAt(localOutputURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: localOutputURL)
        }
    }

    private func writeTemporaryScript(prefix: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).sh")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func startWatchdog(podID: String) {
        watchdogTask?.cancel()
        watchdogTask = Task {
            while !Task.isCancelled {
                let info: [String: Any] = [
                    "feature": "musetalk",
                    "podID": podID,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "pid": ProcessInfo.processInfo.processIdentifier
                ]
                if let data = try? JSONSerialization.data(withJSONObject: info) {
                    try? data.write(to: watchdogHeartbeatURL, options: .atomic)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        try? FileManager.default.removeItem(at: watchdogHeartbeatURL)
    }

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
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return LocalSSHKeyPair(
                    privateKeyPath: candidate.privateURL.path,
                    publicKey: text,
                    publicKeyPath: candidate.publicURL.path
                )
            }
        }
        throw RunPodMouthSyncError.podCreationFailed(detail: "No SSH public key found at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub.")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    @discardableResult
    private nonisolated func sshCommandChecked(
        host: String,
        port: Int,
        identityFile: String,
        command: String,
        failureContext: String
    ) async throws -> String {
        RunPodMouthSyncLogger.shared.log("ssh root@\(host):\(port) › \(Self.redactedForLogs(command).prefix(200))", level: "SSH")
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
                command,
            ]
        )

        if result.exitCode != 0 {
            let rawDetail = result.stderr.isEmpty ? result.stdout : result.stderr
            let detail = Self.redactedForLogs(Self.trimmedRemoteError(rawDetail))
            RunPodMouthSyncLogger.shared.log("ssh exit=\(result.exitCode) stderr=\(detail)", level: "ERROR")
            throw RunPodMouthSyncError.inferenceFailed(detail: "\(failureContext) (exit \(result.exitCode)): \(detail)")
        }
        if !result.stderr.isEmpty {
            RunPodMouthSyncLogger.shared.log("ssh stderr (non-fatal): \(Self.redactedForLogs(result.stderr).prefix(300))", level: "WARN")
        }
        if !result.stdout.isEmpty {
            RunPodMouthSyncLogger.shared.log("ssh stdout: \(Self.redactedForLogs(result.stdout).prefix(500))", level: "SSH")
        }
        return result.combined
    }

    private nonisolated func waitForSSHReady(
        host: String,
        port: Int,
        identityFile: String,
        maxAttempts: Int = 24
    ) async throws {
        RunPodMouthSyncLogger.shared.log("Probing sshd on \(host):\(port) (up to \(maxAttempts * 5)s)", level: "POD")
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
                    "echo ready",
                ]
            )
            if result.exitCode == 0 && result.stdout.contains("ready") {
                RunPodMouthSyncLogger.shared.log("sshd accepting connections after \(attempt) attempt(s)", level: "POD")
                return
            }
            RunPodMouthSyncLogger.shared.log("sshd not ready yet (attempt \(attempt)/\(maxAttempts)): \(result.stderr.prefix(120))", level: "POD")
            try? await Task.sleep(for: .seconds(5))
        }
        throw RunPodMouthSyncError.sshNotAvailable
    }

    private nonisolated func scpUpload(
        localPath: String,
        remotePath: String,
        host: String,
        port: Int,
        identityFile: String
    ) async throws {
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw RunPodMouthSyncError.localInputMissing(path: localPath)
        }

        RunPodMouthSyncLogger.shared.log("scp ↑ \(localPath) → root@\(host):\(remotePath)", level: "SCP")
        let result = try await runProcess(
            executable: "/usr/bin/scp",
            arguments: [
                "-O",
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
                "root@\(host):\(remotePath)",
            ]
        )
        if result.exitCode != 0 {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw RunPodMouthSyncError.uploadFailed(detail: "scp upload failed (exit \(result.exitCode)): \(detail)")
        }
    }

    private nonisolated func scpDownload(
        remotePath: String,
        localPath: String,
        host: String,
        port: Int,
        identityFile: String
    ) async throws {
        RunPodMouthSyncLogger.shared.log("scp ↓ root@\(host):\(remotePath) → \(localPath)", level: "SCP")
        let result = try await runProcess(
            executable: "/usr/bin/scp",
            arguments: [
                "-O",
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
                localPath,
            ]
        )
        if result.exitCode != 0 {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw RunPodMouthSyncError.downloadFailed(detail: "scp download failed (exit \(result.exitCode)): \(detail)")
        }
    }

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
                    throw RunPodMouthSyncError.inferenceFailed(detail: "RunPod API error: \(message)")
                }
                return payload
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                RunPodMouthSyncLogger.shared.log("RunPod GraphQL request failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription)", level: "WARN")
                try? await Task.sleep(for: .seconds(2 * attempt))
            }
        }

        throw lastError ?? RunPodMouthSyncError.inferenceFailed(detail: "RunPod GraphQL request failed with an unknown error.")
    }

    private nonisolated static func trimmedRemoteError(_ text: String, maxLength: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No stderr output." }
        return String(trimmed.prefix(maxLength))
    }

    private nonisolated static func redactedForLogs(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<=Authorization:\sBearer\s)[A-Za-z0-9._\-]+"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
    }

    private static func generateBootstrapScript(repoURL: String) -> String {
        """
        #!/bin/bash
        set -euo pipefail

        ROOT=/workspace/AmiraMuseTalk
        REPO_DIR="$ROOT/MuseTalk"
        VENV_DIR="$ROOT/venv"
        CONDA_ENV=musetalk

        apt-get update -y >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y ffmpeg git curl libgl1 libglib2.0-0 libsndfile1 >/dev/null

        if command -v conda >/dev/null 2>&1; then
          CONDA_BASE="$(conda info --base)"
          source "$CONDA_BASE/etc/profile.d/conda.sh"
          if ! conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV"; then
            conda create -y -n "$CONDA_ENV" python=3.10 >/dev/null
          fi
          RUN_PREFIX="conda run -n $CONDA_ENV"
          PIP_CMD="$RUN_PREFIX python -m pip"
          MIM_CMD="$RUN_PREFIX mim"
          DOWNLOAD_CMD="$RUN_PREFIX bash ./download_weights.sh"
        else
          if [ ! -d "$VENV_DIR" ]; then
            python3 -m venv "$VENV_DIR"
          fi
          RUN_PREFIX=""
          PIP_CMD="$VENV_DIR/bin/python -m pip"
          MIM_CMD="$VENV_DIR/bin/mim"
          DOWNLOAD_CMD="PATH=$VENV_DIR/bin:$PATH bash ./download_weights.sh"
        fi

        mkdir -p "$ROOT"
        if [ ! -d "$REPO_DIR/.git" ]; then
          git clone --depth 1 \(Self.shellSingleQuoted(repoURL)) "$REPO_DIR"
        else
          git -C "$REPO_DIR" fetch --depth 1 origin
          git -C "$REPO_DIR" reset --hard origin/main
        fi

        cd "$REPO_DIR"
        eval "$PIP_CMD install -q --upgrade pip setuptools wheel"
        eval "$PIP_CMD install -q diffusers==0.30.2 accelerate==0.28.0 numpy==1.23.5 opencv-python==4.9.0.80 soundfile==0.12.1 transformers==4.39.2 huggingface_hub==0.30.2 librosa==0.11.0 einops==0.8.1 gdown requests 'imageio[ffmpeg]' omegaconf ffmpeg-python moviepy decord"
        eval "$PIP_CMD install -q --no-cache-dir -U openmim"
        eval "$MIM_CMD install mmengine"
        eval "$MIM_CMD install 'mmcv==2.0.1'"
        eval "$MIM_CMD install 'mmdet==3.1.0'"
        eval "$MIM_CMD install 'mmpose==1.1.0'"

        if [ ! -f models/musetalkV15/unet.pth ]; then
          eval "$DOWNLOAD_CMD"
        fi
        """
    }

    private static func generateInferenceScript(
        remoteVideoPath: String,
        remoteAudioPath: String,
        remoteOutputFilename: String,
        config: RunPodMouthSyncModels.InferenceConfig
    ) -> String {
        let videoPath = shellSingleQuoted(remoteVideoPath)
        let audioPath = shellSingleQuoted(remoteAudioPath)
        let outputFilename = shellSingleQuoted(remoteOutputFilename)
        let versionArgument = config.modelVersion.versionArgument
        let useFloat16Flag = config.useFloat16 ? "--use_float16" : ""

        return """
        #!/bin/bash
        set -euo pipefail

        ROOT=/workspace/AmiraMuseTalk
        REPO_DIR="$ROOT/MuseTalk"
        VENV_DIR="$ROOT/venv"
        CONDA_ENV=musetalk

        if command -v conda >/dev/null 2>&1; then
          CONDA_BASE="$(conda info --base)"
          source "$CONDA_BASE/etc/profile.d/conda.sh"
          PYTHON_RUN="conda run -n $CONDA_ENV python"
        else
          PYTHON_RUN="$VENV_DIR/bin/python"
        fi

        INPUT_VIDEO=\(videoPath)
        INPUT_AUDIO=\(audioPath)
        PREPPED_VIDEO=/workspace/input/source_25fps.mp4
        PREPPED_AUDIO=/workspace/input/audio_16k.wav
        TASK_CONFIG="$REPO_DIR/configs/inference/amira_task.yaml"

        ffmpeg -y -v warning -i "$INPUT_VIDEO" -r 25 -crf 18 -c:v libx264 -pix_fmt yuv420p "$PREPPED_VIDEO"
        ffmpeg -y -v warning -i "$INPUT_AUDIO" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$PREPPED_AUDIO"

        cat > "$TASK_CONFIG" <<EOF
        task_0:
          video_path: "$PREPPED_VIDEO"
          audio_path: "$PREPPED_AUDIO"
          result_name: \(outputFilename)
        EOF

        cd "$REPO_DIR"
        eval "$PYTHON_RUN -m scripts.inference --inference_config $TASK_CONFIG --result_dir /workspace/output --unet_model_path ./models/musetalkV15/unet.pth --unet_config ./models/musetalkV15/musetalk.json --whisper_dir ./models/whisper --version \(versionArgument) --gpu_id 0 --batch_size \(config.batchSize) --extra_margin \(config.extraMargin) --parsing_mode \(config.parsingMode) --ffmpeg_path /usr/bin \(useFloat16Flag)"
        test -s /workspace/output/v15/\(remoteOutputFilename)
        """
    }

    enum RunPodMouthSyncError: LocalizedError {
        case noAPIKey
        case podCreationFailed(detail: String)
        case podNotFound
        case podStartTimeout
        case sshNotAvailable
        case uploadFailed(detail: String)
        case downloadFailed(detail: String)
        case inferenceFailed(detail: String)
        case localInputMissing(path: String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "RunPod API key not set. Go to API Settings → RunPod tab."
            case .podCreationFailed(let detail):
                return "Failed to create RunPod instance: \(detail)"
            case .podNotFound:
                return "RunPod instance not found."
            case .podStartTimeout:
                return "Pod failed to start within 5 minutes."
            case .sshNotAvailable:
                return "SSH connection not available on pod."
            case .uploadFailed(let detail):
                return "Upload failed: \(detail)"
            case .downloadFailed(let detail):
                return "Download failed: \(detail)"
            case .inferenceFailed(let detail):
                return "MuseTalk inference failed: \(detail)"
            case .localInputMissing(let path):
                return "Local input file missing: \(path)"
            }
        }
    }
}
