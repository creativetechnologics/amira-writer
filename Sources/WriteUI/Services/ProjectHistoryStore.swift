import Foundation
import ProjectKit

struct ProjectFileSnapshot: Codable, Hashable, Sendable {
    var modificationDate: Date
    var fileSize: Int64
}

enum ProjectHistoryEntryKind: String, Codable, Hashable, Sendable {
    case autosave
    case manualSave
    case externalReload
    case openedWithExternalChanges
    case agentSync
}

struct ProjectHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: ProjectHistoryEntryKind
    var title: String
    var message: String
    var relativePaths: [String]
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        kind: ProjectHistoryEntryKind,
        title: String,
        message: String,
        relativePaths: [String],
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.relativePaths = relativePaths
        self.recordedAt = recordedAt
    }
}

struct GitCommitEntry: Identifiable, Hashable, Sendable {
    var hash: String
    var shortHash: String
    var subject: String
    var committedAt: Date

    var id: String { hash }
}

struct PersistedProjectHistoryState: Codable, Hashable, Sendable {
    var fileSnapshots: [String: ProjectFileSnapshot]
    var entries: [ProjectHistoryEntry]

    init(
        fileSnapshots: [String: ProjectFileSnapshot] = [:],
        entries: [ProjectHistoryEntry] = []
    ) {
        self.fileSnapshots = fileSnapshots
        self.entries = entries
    }
}

private struct PersistedProjectHistoryIndex: Codable, Sendable {
    var projects: [String: PersistedProjectHistoryState] = [:]
}

final class ProjectHistoryStore: @unchecked Sendable {
    static let shared = ProjectHistoryStore()

    private let fileManager: FileManager
    private let storageURL: URL

    init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let storageURL {
            self.storageURL = storageURL
            return
        }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let preferredDirectory = appSupport.appendingPathComponent("Write", isDirectory: true)
        let legacyDirectory = appSupport.appendingPathComponent("Novotro Write", isDirectory: true)
        let historyFileName = "ProjectHistory.json"
        let directory: URL
        if fileManager.fileExists(atPath: preferredDirectory.appendingPathComponent(historyFileName).path) {
            directory = preferredDirectory
        } else if fileManager.fileExists(atPath: legacyDirectory.appendingPathComponent(historyFileName).path) {
            directory = legacyDirectory
        } else {
            directory = preferredDirectory
        }
        self.storageURL = directory.appendingPathComponent("ProjectHistory.json")
    }

    func loadState(for projectURL: URL) -> PersistedProjectHistoryState {
        let index = loadIndex()
        return index.projects[projectKey(for: projectURL)] ?? PersistedProjectHistoryState()
    }

    func saveState(_ state: PersistedProjectHistoryState, for projectURL: URL) {
        var index = loadIndex()
        index.projects[projectKey(for: projectURL)] = state
        saveIndex(index)
    }

    private func projectKey(for projectURL: URL) -> String {
        projectURL.standardizedFileURL.path
    }

    private func loadIndex() -> PersistedProjectHistoryIndex {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? Self.decoder.decode(PersistedProjectHistoryIndex.self, from: data) else {
            return PersistedProjectHistoryIndex()
        }
        return decoded
    }

    private func saveIndex(_ index: PersistedProjectHistoryIndex) {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(index)
            try data.write(to: storageURL, options: .atomic)
        } catch {}
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONCoders.makeEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONCoders.makeDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct GitHistoryService: Sendable {
    var loadCommits: @Sendable (URL) -> [GitCommitEntry]

    static let live = GitHistoryService { projectURL in
        loadGitCommits(for: projectURL)
    }
}

private func loadGitCommits(for projectURL: URL, limit: Int = 40) -> [GitCommitEntry] {
    let subjectURL = projectURL.pathExtension.lowercased() == "ows"
        ? projectURL.deletingLastPathComponent()
        : projectURL
    guard let repoRootPath = runGit(arguments: ["rev-parse", "--show-toplevel"], at: subjectURL)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !repoRootPath.isEmpty
    else {
        return []
    }

    let repoRootURL = URL(fileURLWithPath: repoRootPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    let trackedURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
    let repoRootPathWithSlash = repoRootURL.path.hasSuffix("/") ? repoRootURL.path : repoRootURL.path + "/"
    let pathspec = trackedURL.path.hasPrefix(repoRootPathWithSlash)
        ? String(trackedURL.path.dropFirst(repoRootPathWithSlash.count))
        : ""

    let baseArguments = [
        "log",
        "--date=iso8601-strict",
        "--pretty=format:%H%x1f%h%x1f%cI%x1f%s%x1e",
        "-n",
        String(limit),
    ]

    if !pathspec.isEmpty {
        let scopedCommits = parseGitLogOutput(
            runGit(arguments: baseArguments + ["--", pathspec], at: repoRootURL)
        )
        if !scopedCommits.isEmpty {
            return scopedCommits
        }
    }

    return parseGitLogOutput(runGit(arguments: baseArguments, at: repoRootURL))
}

private func parseGitLogOutput(_ output: String?) -> [GitCommitEntry] {
    guard let output else { return [] }

    return output
        .split(separator: "\u{1e}")
        .compactMap { record in
            let parts = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { return nil }
            let hash = String(parts[0])
            let shortHash = String(parts[1])
            let dateString = String(parts[2])
            let subject = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let committedAt = ISO8601DateFormatter().date(from: dateString) else { return nil }
            return GitCommitEntry(
                hash: hash,
                shortHash: shortHash,
                subject: subject,
                committedAt: committedAt
            )
        }
}

private func runGit(arguments: [String], at directoryURL: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directoryURL.path] + arguments

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}
