import Foundation

@MainActor
final class WriteObsidianSyncService {
    let sourceURL: URL
    let destinationURL: URL
    private var isActive = false
    private var workItem: DispatchWorkItem?

    static let syncInterval: TimeInterval = 5

    init?(projectURL: URL) {
        let resolvedProject = projectURL.resolvingSymlinksInPath()
        let projectName = resolvedProject.lastPathComponent
        let writeURL = resolvedProject.appendingPathComponent("Write", isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let obsidianBase = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Mobile Documents")
            .appendingPathComponent("iCloud~md~obsidian")
            .appendingPathComponent("Documents")
            .appendingPathComponent(projectName)
            .appendingPathComponent("Write")

        guard FileManager.default.fileExists(atPath: writeURL.path),
              FileManager.default.fileExists(atPath: obsidianBase.path) else { return nil }

        self.sourceURL = writeURL
        self.destinationURL = obsidianBase
    }

    /// Testing initializer — inject arbitrary source/destination URLs directly.
    init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = sourceURL.resolvingSymlinksInPath()
        self.destinationURL = destinationURL.resolvingSymlinksInPath()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        scheduleSync()
    }

    func stop() {
        isActive = false
        workItem?.cancel()
        workItem = nil
    }

    func syncNow() {
        syncFiles()
    }

    private func scheduleSync() {
        guard isActive else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.syncFiles()
            self.scheduleSync()
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.syncInterval, execute: item)
    }

    private func syncFiles() {
        let sourceEntries = enumerateFiles(at: sourceURL)
        let destEntries = enumerateFiles(at: destinationURL)

        let sourceByRel: [String: (url: URL, date: Date)] = Dictionary(
            uniqueKeysWithValues: sourceEntries.map { ($0.relPath, ($0.url, $0.date)) }
        )
        let destByRel: [String: (url: URL, date: Date)] = Dictionary(
            uniqueKeysWithValues: destEntries.map { ($0.relPath, ($0.url, $0.date)) }
        )

        let sourcePaths = Set(sourceByRel.keys)
        let destPaths = Set(destByRel.keys)

        for (relPath, src) in sourceByRel where !destPaths.contains(relPath) {
            copyFile(from: src.url, to: destinationURL.appendingPathComponent(relPath))
        }

        for (relPath, dst) in destByRel where !sourcePaths.contains(relPath) {
            copyFile(from: dst.url, to: sourceURL.appendingPathComponent(relPath))
        }

        for relPath in sourcePaths.intersection(destPaths) {
            guard let src = sourceByRel[relPath], let dst = destByRel[relPath] else { continue }
            if src.date > dst.date {
                copyFile(from: src.url, to: dst.url)
            } else if dst.date > src.date {
                copyFile(from: dst.url, to: src.url)
            }
        }
    }

    /// Exposed for testing only.
    func enumerateForTesting(url: URL) -> [(relPath: String, date: Date)] {
        enumerateFiles(at: url).map { ($0.relPath, $0.date) }
    }

    private struct FileEntry {
        let url: URL
        let relPath: String
        let date: Date
    }

    private func enumerateFiles(at baseURL: URL) -> [FileEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [FileEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  let isDir = values.isDirectory, !isDir,
                  let modDate = values.contentModificationDate else { continue }
            result.append(FileEntry(url: url, relPath: relPath(from: baseURL, to: url), date: modDate))
        }
        return result
    }

    private func relPath(from base: URL, to url: URL) -> String {
        var basePath = base.resolvingSymlinksInPath().path
        if !basePath.hasSuffix("/") { basePath += "/" }
        var filePath = url.resolvingSymlinksInPath().path
        if filePath.hasPrefix(basePath) {
            return String(filePath.dropFirst(basePath.count))
        }
        // Fallback: try without symlink resolution if matching failed
        filePath = url.path
        if filePath.hasPrefix(basePath) {
            return String(filePath.dropFirst(basePath.count))
        }
        return url.lastPathComponent
    }

    private func copyFile(from source: URL, to destination: URL) {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
    }
}
