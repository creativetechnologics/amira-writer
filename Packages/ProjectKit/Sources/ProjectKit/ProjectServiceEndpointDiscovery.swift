import Foundation
import Network

public enum ProjectServiceEndpointDiscovery {
    public static let endpointEnvironmentKey = "PROJECT_SERVICE_ENDPOINT"

    private static let legacyEndpointEnvironmentKey = "AMIRA_PROJECT_SERVICE_ENDPOINT"
    private static let deprecatedEndpointEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_ENDPOINT"
    private static let lastSuccessfulEndpointDefaultsKey = "ProjectService.LastSuccessfulEndpoint"
    private static let legacyLastSuccessfulEndpointDefaultsKey = "AmiraProjectService.LastSuccessfulEndpoint"
    private static let deprecatedLastSuccessfulEndpointDefaultsKey = "NovotroProjectService.LastSuccessfulEndpoint"

    public static func candidateEndpoints(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> [NWEndpoint] {
        var endpoints: [NWEndpoint] = []
        var seen: Set<String> = []

        func append(_ endpoint: NWEndpoint?) {
            guard let endpoint else { return }
            let identifier = endpointIdentifier(endpoint)
            guard seen.insert(identifier).inserted else { return }
            endpoints.append(endpoint)
        }

        if let explicit = trimmed(environment[endpointEnvironmentKey] ?? environment[legacyEndpointEnvironmentKey] ?? environment[deprecatedEndpointEnvironmentKey]) {
            append(endpoint(from: explicit))
        }

        let configuredEndpointFile = trimmed(environment[ProjectServiceConfiguration.endpointFileEnvironmentKey])
        let endpointFileCandidates = readEndpointCandidates(from: configuredEndpointFile)
            ?? readEndpointCandidates(from: ProjectServiceConfiguration.defaultEndpointFileURL().path)
            ?? []
        for candidate in endpointFileCandidates {
            append(endpoint(from: candidate))
        }

        if let remembered = defaults.string(forKey: lastSuccessfulEndpointDefaultsKey)
            ?? defaults.string(forKey: legacyLastSuccessfulEndpointDefaultsKey)
            ?? defaults.string(forKey: deprecatedLastSuccessfulEndpointDefaultsKey) {
            append(endpoint(from: remembered))
        }

        for fallback in fallbackEndpointStrings() {
            append(endpoint(from: fallback))
        }

        return endpoints
    }

    static func recordSuccessfulEndpoint(_ endpoint: NWEndpoint, defaults: UserDefaults = .standard) {
        guard let serialized = serializedEndpointString(endpoint) else { return }
        defaults.set(serialized, forKey: lastSuccessfulEndpointDefaultsKey)
        defaults.removeObject(forKey: legacyLastSuccessfulEndpointDefaultsKey)
        defaults.removeObject(forKey: deprecatedLastSuccessfulEndpointDefaultsKey)
    }

    static func endpoint(from string: String) -> NWEndpoint? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let port = UInt16(parts[1]),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }
        return .hostPort(host: .name(String(parts[0]), nil), port: nwPort)
    }

    public static func serializedEndpointString(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, port) = endpoint else {
            return nil
        }
        return "\(String(describing: host)):\(port.rawValue)"
    }

    private static func endpointIdentifier(_ endpoint: NWEndpoint) -> String {
        if let serialized = serializedEndpointString(endpoint) {
            return serialized
        }
        return String(describing: endpoint)
    }

    private static func fallbackEndpointStrings() -> [String] {
        let port = ProjectServiceConfiguration.defaultPort
        return [
            "garys-server.local:\(port)",
            "127.0.0.1:\(port)",
            "localhost:\(port)",
        ]
    }

    private static func readEndpointCandidates(from path: String?) -> [String]? {
        guard let path else { return nil }

        let expanded = NSString(string: path).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return nil
        }

        let candidates = contents
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let commentStart = trimmed.firstIndex(of: "#") else {
                    return trimmed.isEmpty ? nil : trimmed
                }
                let beforeComment = String(trimmed[..<commentStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                return beforeComment.isEmpty ? nil : beforeComment
            }
            .filter { !$0.isEmpty }

        return candidates.isEmpty ? nil : candidates
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
