import Foundation

final class RecentProjectsStore: @unchecked Sendable {
    static let shared = RecentProjectsStore()

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let storageKey: String
    private let maxProjects: Int

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        storageKey: String = "recentProjectPaths",
        maxProjects: Int = 20
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.storageKey = storageKey
        self.maxProjects = maxProjects
    }

    @discardableResult
    func noteProject(_ url: URL) -> [URL] {
        let normalizedURL = Self.normalize(url)
        guard isSupportedProjectURL(normalizedURL) else {
            return recentProjects()
        }

        var paths = storedPaths()
        paths.removeAll { $0 == normalizedURL.path }
        paths.insert(normalizedURL.path, at: 0)
        persist(Array(paths.prefix(maxProjects)))
        return recentProjects()
    }

    func recentProjects() -> [URL] {
        let paths = storedPaths()
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if urls.map(\.path) != paths {
            persist(urls.map(\.path))
        }
        return urls
    }

    private func storedPaths() -> [String] {
        let stored = userDefaults.array(forKey: storageKey) as? [String] ?? []
        var seen: Set<String> = []
        var normalized: [String] = []

        for path in stored {
            let url = Self.normalize(URL(fileURLWithPath: path))
            guard isSupportedProjectURL(url) else { continue }
            guard seen.insert(url.path).inserted else { continue }
            normalized.append(url.path)
        }

        return normalized
    }

    private func persist(_ paths: [String]) {
        userDefaults.set(paths, forKey: storageKey)
    }

    private func isSupportedProjectURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "owp" || ext == "ows" else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private static func normalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
