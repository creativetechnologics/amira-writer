import Foundation

public enum NovotroProjectServiceConfiguration {
    public static let defaultPort: UInt16 = 19847

    public static let authTokenEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_TOKEN"
    public static let authTokenFileEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_TOKEN_FILE"
    public static let allowedRootsEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_ALLOWED_ROOTS"
    public static let endpointFileEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_ENDPOINT_FILE"

    public static func loadAuthToken(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicit = trimmed(environment[authTokenEnvironmentKey]) {
            return explicit
        }

        let tokenURL: URL
        if let explicitPath = trimmed(environment[authTokenFileEnvironmentKey]) {
            tokenURL = URL(fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath)
        } else {
            tokenURL = defaultAuthTokenFileURL(fileManager: fileManager)
        }

        guard let contents = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            return nil
        }
        return trimmed(contents)
    }

    public static func defaultAuthTokenFileURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Novotro", isDirectory: true)
        return supportDirectory.appendingPathComponent("project-service-token", isDirectory: false)
    }

    public static func defaultEndpointFileURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Novotro", isDirectory: true)
        return supportDirectory.appendingPathComponent("project-service-endpoint", isDirectory: false)
    }

    public static func allowedProjectRoots(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let explicit = trimmed(environment[allowedRootsEnvironmentKey]) {
            let configured = explicit
                .split(separator: ":")
                .map { entry in
                    URL(
                        fileURLWithPath: NSString(string: String(entry)).expandingTildeInPath,
                        isDirectory: true
                    )
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                }
            return uniqueExistingDirectories(configured, fileManager: fileManager)
        }

        var candidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Programming", isDirectory: true),
            NovotroProjectServerRegistry.defaultProjectsRootURL(fileManager: fileManager),
        ]

        let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if let volumes = try? fileManager.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for volume in volumes {
                candidates.append(volume.appendingPathComponent("Programming", isDirectory: true))
            }
        }

        return uniqueExistingDirectories(candidates, fileManager: fileManager)
    }

    public static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let normalizedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        return normalizedCandidate == normalizedRoot || normalizedCandidate.hasPrefix(normalizedRoot + "/")
    }

    private static func uniqueExistingDirectories(_ candidates: [URL], fileManager: FileManager) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for candidate in candidates {
            let normalized = candidate.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(normalized.path).inserted else {
                continue
            }
            result.append(normalized)
        }

        return result
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
