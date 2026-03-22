import Foundation

public struct NPProjectServerRegistration: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var managedProjectURL: URL
    public var sourceProjectURL: URL?
    public var pathAliases: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        managedProjectURL: URL,
        sourceProjectURL: URL?,
        pathAliases: [String],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.managedProjectURL = managedProjectURL
        self.sourceProjectURL = sourceProjectURL
        self.pathAliases = pathAliases
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct NPProjectServerManifest: Codable, Sendable {
    var projects: [NPProjectServerRegistration]
}

public enum NovotroProjectPathIdentity {
    public static func normalizedProjectURL(from path: String) -> URL {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    public static func signature(for projectURL: URL) -> String {
        let normalized = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let components = normalized.pathComponents.filter { $0 != "/" }
        if let programmingIndex = components.lastIndex(of: "Programming") {
            return components[programmingIndex...].joined(separator: "/")
        }
        if let documentsIndex = components.lastIndex(of: "Documents") {
            return components[documentsIndex...].joined(separator: "/")
        }
        return components.suffix(2).joined(separator: "/")
    }

    public static func matches(requestedProjectURL: URL, resolvedProjectURL: URL) -> Bool {
        let requested = requestedProjectURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = resolvedProjectURL.resolvingSymlinksInPath().standardizedFileURL
        if requested.path == resolved.path {
            return true
        }
        guard requested.pathExtension.lowercased() == "owp",
              resolved.pathExtension.lowercased() == "owp" else {
            return false
        }
        return signature(for: requested) == signature(for: resolved)
    }
}

public final class NovotroProjectServerRegistry: @unchecked Sendable {
    public let rootURL: URL
    public let projectsRootURL: URL
    public let manifestURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        rootURL: URL = NovotroProjectServerRegistry.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.projectsRootURL = self.rootURL.appendingPathComponent("Projects", isDirectory: true)
        self.manifestURL = self.rootURL.appendingPathComponent("server-projects.json", isDirectory: false)
        self.fileManager = fileManager
    }

    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Novotro Project Server", isDirectory: true)
    }

    public static func defaultProjectsRootURL(fileManager: FileManager = .default) -> URL {
        defaultRootURL(fileManager: fileManager).appendingPathComponent("Projects", isDirectory: true)
    }

    public func ensureStorageDirectories() throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: manifestURL.path) {
            try saveManifest(NPProjectServerManifest(projects: []))
        }
    }

    public func listProjects() throws -> [NPProjectServerRegistration] {
        lock.lock()
        defer { lock.unlock() }
        return try loadManifest().projects.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func project(id: UUID) throws -> NPProjectServerRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return try loadManifest().projects.first(where: { $0.id == id })
    }

    public func managedProjectURL(forProjectURL projectURL: URL) throws -> URL? {
        try registration(forProjectURL: projectURL)?.managedProjectURL
    }

    public func managedProjectURL(forClientProjectPath clientProjectPath: String) throws -> URL? {
        try registration(forProjectURL: NovotroProjectPathIdentity.normalizedProjectURL(from: clientProjectPath))?.managedProjectURL
    }

    public func registration(forProjectURL projectURL: URL) throws -> NPProjectServerRegistration? {
        lock.lock()
        defer { lock.unlock() }

        let normalized = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let requestedSignature = NovotroProjectPathIdentity.signature(for: normalized)
        let manifest = try loadManifest()

        return manifest.projects.first { registration in
            registration.managedProjectURL.resolvingSymlinksInPath().standardizedFileURL.path == normalized.path
                || registration.pathAliases.contains(requestedSignature)
        }
    }

    @discardableResult
    public func addProject(from sourceURL: URL, displayName: String? = nil) throws -> NPProjectServerRegistration {
        let normalizedSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard normalizedSource.pathExtension.lowercased() == "owp" else {
            throw NSError(
                domain: "NovotroProjectServerRegistry",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Novotro Project Server can only import .owp projects."]
            )
        }

        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        var manifest = try loadManifest()
        let now = Date()
        let aliasSignature = NovotroProjectPathIdentity.signature(for: normalizedSource)
        let projectName = displayName ?? normalizedSource.deletingPathExtension().lastPathComponent

        if let index = manifest.projects.firstIndex(where: { registration in
            registration.pathAliases.contains(aliasSignature)
                || registration.sourceProjectURL?.resolvingSymlinksInPath().standardizedFileURL.path == normalizedSource.path
        }) {
            var registration = manifest.projects[index]
            try replaceManagedProjectCopy(from: normalizedSource, to: registration.managedProjectURL)
            registration.displayName = projectName
            registration.sourceProjectURL = normalizedSource
            var signatures = Set(registration.pathAliases)
            signatures.insert(aliasSignature)
            signatures.insert(NovotroProjectPathIdentity.signature(for: registration.managedProjectURL))
            registration.pathAliases = signatures.sorted()
            registration.updatedAt = now
            manifest.projects[index] = registration
            try saveManifest(manifest)
            return registration
        }

        let managedProjectURL = try uniqueManagedProjectURL(for: projectName)
        try replaceManagedProjectCopy(from: normalizedSource, to: managedProjectURL)

        let registration = NPProjectServerRegistration(
            displayName: projectName,
            managedProjectURL: managedProjectURL,
            sourceProjectURL: normalizedSource,
            pathAliases: [
                aliasSignature,
                NovotroProjectPathIdentity.signature(for: managedProjectURL),
            ].sorted(),
            createdAt: now,
            updatedAt: now
        )
        manifest.projects.append(registration)
        manifest.projects.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        try saveManifest(manifest)
        return registration
    }

    @discardableResult
    public func createProject(named displayName: String) throws -> NPProjectServerRegistration {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(
                domain: "NovotroProjectServerRegistry",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Project name cannot be empty."]
            )
        }

        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        var manifest = try loadManifest()
        let now = Date()
        let managedProjectURL = try uniqueManagedProjectURL(for: trimmedName)
        try createManagedProjectSkeleton(at: managedProjectURL)

        let registration = NPProjectServerRegistration(
            displayName: trimmedName,
            managedProjectURL: managedProjectURL,
            sourceProjectURL: nil,
            pathAliases: [NovotroProjectPathIdentity.signature(for: managedProjectURL)],
            createdAt: now,
            updatedAt: now
        )
        manifest.projects.append(registration)
        manifest.projects.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        try saveManifest(manifest)
        return registration
    }

    @discardableResult
    public func renameProject(id: UUID, to displayName: String) throws -> NPProjectServerRegistration {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(
                domain: "NovotroProjectServerRegistry",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Project name cannot be empty."]
            )
        }

        lock.lock()
        defer { lock.unlock() }

        var manifest = try loadManifest()
        guard let index = manifest.projects.firstIndex(where: { $0.id == id }) else {
            throw NSError(
                domain: "NovotroProjectServerRegistry",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not find that project on Novotro Project Server."]
            )
        }

        var registration = manifest.projects[index]
        let previousManagedURL = registration.managedProjectURL
        let nextManagedURL = try uniqueManagedProjectURL(for: trimmedName, excluding: previousManagedURL)
        if nextManagedURL.standardizedFileURL.path != previousManagedURL.standardizedFileURL.path {
            try fileManager.moveItem(at: previousManagedURL, to: nextManagedURL)
            registration.managedProjectURL = nextManagedURL
        }

        var signatures = Set(registration.pathAliases)
        signatures.insert(NovotroProjectPathIdentity.signature(for: previousManagedURL))
        signatures.insert(NovotroProjectPathIdentity.signature(for: registration.managedProjectURL))
        if let sourceProjectURL = registration.sourceProjectURL {
            signatures.insert(NovotroProjectPathIdentity.signature(for: sourceProjectURL))
        }

        registration.displayName = trimmedName
        registration.pathAliases = signatures.sorted()
        registration.updatedAt = Date()
        manifest.projects[index] = registration
        manifest.projects.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        try saveManifest(manifest)
        return registration
    }

    public func removeProject(id: UUID, deleteManagedProject: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }

        var manifest = try loadManifest()
        guard let index = manifest.projects.firstIndex(where: { $0.id == id }) else { return }
        let registration = manifest.projects.remove(at: index)
        try saveManifest(manifest)

        guard deleteManagedProject,
              fileManager.fileExists(atPath: registration.managedProjectURL.path) else {
            return
        }

        var trashedURL: NSURL?
        _ = try fileManager.trashItem(at: registration.managedProjectURL, resultingItemURL: &trashedURL)
    }

    private func loadManifest() throws -> NPProjectServerManifest {
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? Self.decoder.decode(NPProjectServerManifest.self, from: data) {
            return manifest
        }
        return NPProjectServerManifest(projects: [])
    }

    private func saveManifest(_ manifest: NPProjectServerManifest) throws {
        let data = try Self.encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func uniqueManagedProjectURL(for displayName: String, excluding excludedURL: URL? = nil) throws -> URL {
        let baseName = sanitizedProjectFolderName(displayName)
        var candidate = projectsRootURL.appendingPathComponent(baseName + ".owp", isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path),
              candidate.standardizedFileURL.path != excludedURL?.standardizedFileURL.path {
            candidate = projectsRootURL.appendingPathComponent("\(baseName) \(suffix).owp", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func replaceManagedProjectCopy(from sourceURL: URL, to destinationURL: URL) throws {
        let stagingURL = projectsRootURL.appendingPathComponent(".staging-\(UUID().uuidString).owp", isDirectory: true)
        try? fileManager.removeItem(at: stagingURL)
        try fileManager.copyItem(at: sourceURL, to: stagingURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    private func createManagedProjectSkeleton(at destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let requiredDirectories = [
            "Songs",
            "Metadata",
            "Characters",
            "Synopsis",
            "Animate",
        ]
        for relativePath in requiredDirectories {
            try fileManager.createDirectory(
                at: destinationURL.appendingPathComponent(relativePath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func sanitizedProjectFolderName(_ rawValue: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let parts = rawValue.components(separatedBy: invalid).filter { !$0.isEmpty }
        let normalized = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Project" : normalized
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
