import AppKit
import Foundation
import ProjectKit

@MainActor
final class WriteObsidianSyncService {
    let sourceURL: URL
    let destinationURL: URL
    private var isActive = false
    private var workItem: DispatchWorkItem?
    private var activeObserver: NSObjectProtocol?

    static let syncInterval: TimeInterval = 5

    init?(projectURL: URL) {
        let resolvedProject = projectURL.resolvingSymlinksInPath()
        let projectName = resolvedProject.lastPathComponent
        let writeURL = resolvedProject.appendingPathComponent("Write", isDirectory: true)

        guard FileManager.default.fileExists(atPath: writeURL.path) else {
            AmiraLogger.log(.write, "Obsidian sync: Write/ directory not found at \(writeURL.path)")
            return nil
        }

        guard let obsidianBase = Self.findObsidianVaultWriteDir(for: resolvedProject) else {
            AmiraLogger.log(.write, "Obsidian sync: no matching Obsidian vault found for project '\(projectName)'")
            return nil
        }

        self.sourceURL = writeURL
        self.destinationURL = obsidianBase
        AmiraLogger.log(.write, "Obsidian sync: \(writeURL.path) ↔ \(obsidianBase.path)")
    }

    /// Search for an Obsidian iCloud vault whose folder name matches the project name.
    /// Tries exact match first, then prefix (before first " - "), then falls back to
    /// any vault whose name is a prefix of the project name.
    private static func findObsidianVaultWriteDir(for projectURL: URL) -> URL? {
        let projectName = projectURL.lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser
        let obsidianDocs = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Mobile Documents")
            .appendingPathComponent("iCloud~md~obsidian")
            .appendingPathComponent("Documents")

        let namesToTry: [String] = {
            var seen = Set<String>()
            return [
                projectName,
                projectName.components(separatedBy: " - ").first,
            ].compactMap { name in
                guard let name, !seen.contains(name) else { return nil }
                seen.insert(name)
                return name
            }
        }()

        // Try exact name matches first
        for name in namesToTry {
            let candidate = obsidianDocs
                .appendingPathComponent(name)
                .appendingPathComponent("Write")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Fallback: scan all vaults for one whose name is a prefix of the project name
        guard let vaults = try? FileManager.default.contentsOfDirectory(
            at: obsidianDocs,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return nil }

        let projectLower = projectName.lowercased()
        for vault in vaults {
            let vaultName = vault.lastPathComponent
            if vaultName.lowercased() == projectLower { continue } // already tried exact
            if projectLower.hasPrefix(vaultName.lowercased()) {
                let candidate = vault.appendingPathComponent("Write")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
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
        addActiveObserver()
    }

    func stop() {
        isActive = false
        workItem?.cancel()
        workItem = nil
        removeActiveObserver()
    }

    private func addActiveObserver() {
        removeActiveObserver()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncNow()
        }
    }

    private func removeActiveObserver() {
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
            activeObserver = nil
        }
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
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            AmiraLogger.log(.write, "Obsidian sync copy failed: \(error.localizedDescription) from=\(source.lastPathComponent) to=\(destination.path)")
        }
    }
}
