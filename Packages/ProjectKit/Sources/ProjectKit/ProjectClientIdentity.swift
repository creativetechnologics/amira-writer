import Foundation
import CryptoKit

public enum ProjectClientIdentity {
    private static let clientIDFileName = "project-client-id"
    private static let preferredSupportDirectoryName = "Opera"
    private static let legacySupportDirectoryName = "Novotro"
    private static let projectCacheDirectoryName = "Project Databases"

    public static func sharedClientID(fileManager: FileManager = .default) -> String {
        let fileURL = clientIDFileURL(fileManager: fileManager)
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.isEmpty == false {
            return existing
        }

        let identifier = UUID().uuidString.lowercased()
        try? fileManager.createDirectory(
            at: supportDirectory(fileManager: fileManager),
            withIntermediateDirectories: true
        )
        try? identifier.write(to: fileURL, atomically: true, encoding: .utf8)
        return identifier
    }

    public static func actorID(for base: String, fileManager: FileManager = .default) -> String {
        "\(base)@\(sharedClientID(fileManager: fileManager))"
    }

    public static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let preferred = appSupport.appendingPathComponent(preferredSupportDirectoryName, isDirectory: true)
        let legacy = appSupport.appendingPathComponent(legacySupportDirectoryName, isDirectory: true)

        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        if fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return preferred
    }

    public static func projectMirrorRootURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent("Project Mirrors", isDirectory: true)
    }

    public static func projectCacheRootURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent(projectCacheDirectoryName, isDirectory: true)
    }

    public static func projectDatabaseDirectoryURL(for sourceProjectURL: URL, fileManager: FileManager = .default) -> URL {
        let normalized = sourceProjectURL.resolvingSymlinksInPath().standardizedFileURL
        let baseName = normalized.deletingPathExtension().lastPathComponent
        let safeBaseName = baseName.replacingOccurrences(of: "/", with: "-")
        let digest = SHA256.hash(data: Data(normalized.path.utf8)).hexString
        return projectCacheRootURL(fileManager: fileManager)
            .appendingPathComponent("\(safeBaseName)-\(String(digest.prefix(12)))", isDirectory: true)
    }

    public static func mirrorProjectURL(for sourceProjectURL: URL, fileManager: FileManager = .default) -> URL {
        let normalized = sourceProjectURL.resolvingSymlinksInPath().standardizedFileURL
        let baseName = normalized.deletingPathExtension().lastPathComponent
        let safeBaseName = baseName.replacingOccurrences(of: "/", with: "-")
        let digest = SHA256.hash(data: Data(normalized.path.utf8)).hexString
        return projectMirrorRootURL(fileManager: fileManager)
            .appendingPathComponent("\(safeBaseName)-\(String(digest.prefix(12))).owp", isDirectory: true)
    }

    private static func clientIDFileURL(fileManager: FileManager) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent(clientIDFileName, isDirectory: false)
    }
}

public typealias NovotroProjectClientIdentity = ProjectClientIdentity

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
