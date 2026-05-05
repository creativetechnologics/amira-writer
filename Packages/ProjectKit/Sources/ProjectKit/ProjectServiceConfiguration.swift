import Foundation

public enum ProjectServiceConfiguration {
    public static let defaultPort: UInt16 = 19847

    public static let authTokenEnvironmentKey = "PROJECT_SERVICE_TOKEN"
    public static let authTokenFileEnvironmentKey = "PROJECT_SERVICE_TOKEN_FILE"
    public static let allowedRootsEnvironmentKey = "PROJECT_SERVICE_ALLOWED_ROOTS"
    public static let endpointFileEnvironmentKey = "PROJECT_SERVICE_ENDPOINT_FILE"

    private static let legacyAuthTokenEnvironmentKey = "AMIRA_PROJECT_SERVICE_TOKEN"
    private static let legacyAuthTokenFileEnvironmentKey = "AMIRA_PROJECT_SERVICE_TOKEN_FILE"
    private static let legacyAllowedRootsEnvironmentKey = "AMIRA_PROJECT_SERVICE_ALLOWED_ROOTS"
    private static let legacyEndpointFileEnvironmentKey = "AMIRA_PROJECT_SERVICE_ENDPOINT_FILE"

    private static let deprecatedAuthTokenEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_TOKEN"
    private static let deprecatedAuthTokenFileEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_TOKEN_FILE"
    private static let deprecatedAllowedRootsEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_ALLOWED_ROOTS"
    private static let deprecatedEndpointFileEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_ENDPOINT_FILE"

    public static func loadAuthToken(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicit = firstEnvironmentValue(
            keys: [authTokenEnvironmentKey, legacyAuthTokenEnvironmentKey, deprecatedAuthTokenEnvironmentKey],
            environment: environment
        ) {
            return explicit
        }

        let tokenURL: URL
        if let explicitPath = firstEnvironmentValue(
            keys: [authTokenFileEnvironmentKey, legacyAuthTokenFileEnvironmentKey, deprecatedAuthTokenFileEnvironmentKey],
            environment: environment
        ) {
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
        let supportDirectory = preferredSupportDirectory(fileManager: fileManager)
        return supportDirectory.appendingPathComponent("project-service-token", isDirectory: false)
    }

    public static func defaultEndpointFileURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = preferredSupportDirectory(fileManager: fileManager)
        return supportDirectory.appendingPathComponent("project-service-endpoint", isDirectory: false)
    }

    public static func allowedProjectRoots(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let explicit = firstEnvironmentValue(
            keys: [allowedRootsEnvironmentKey, legacyAllowedRootsEnvironmentKey, deprecatedAllowedRootsEnvironmentKey],
            environment: environment
        ) {
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
            return normalizedAllowedProjectRoots(candidates: configured, fileManager: fileManager)
        }

        let managedProjectsRoot = ProjectServerRegistry.defaultProjectsRootURL(fileManager: fileManager)
        var candidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Programming", isDirectory: true),
            managedProjectsRoot,
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

        return normalizedAllowedProjectRoots(
            candidates: candidates,
            requiredRoots: [managedProjectsRoot],
            fileManager: fileManager
        )
    }

    public static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let normalizedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        return normalizedCandidate == normalizedRoot || normalizedCandidate.hasPrefix(normalizedRoot + "/")
    }

    static func normalizedAllowedProjectRoots(
        candidates: [URL],
        requiredRoots: [URL] = [],
        fileManager: FileManager = .default
    ) -> [URL] {
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

        for root in requiredRoots {
            let normalized = root.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(normalized.path).inserted else { continue }
            result.append(normalized)
        }

        return result
    }

    private static func preferredSupportDirectory(fileManager: FileManager) -> URL {
        let appSupportRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let preferred = appSupportRoot.appendingPathComponent("Opera", isDirectory: true)
        let legacy = appSupportRoot.appendingPathComponent("Novotro", isDirectory: true)
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        if fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return preferred
    }

    private static func firstEnvironmentValue(
        keys: [String],
        environment: [String: String]
    ) -> String? {
        for key in keys {
            if let value = trimmed(environment[key]) {
                return value
            }
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
