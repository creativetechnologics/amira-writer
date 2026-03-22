import Foundation
import Network

public enum NovotroProjectServiceEndpointDiscovery {
    public static let endpointEnvironmentKey = "NOVOTRO_PROJECT_SERVICE_ENDPOINT"

    private static let lastSuccessfulEndpointDefaultsKey = "NovotroProjectService.LastSuccessfulEndpoint"

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

        if let explicit = environment[endpointEnvironmentKey] {
            append(endpoint(from: explicit))
        }

        let configuredEndpointFile = trimmed(environment[NovotroProjectServiceConfiguration.endpointFileEnvironmentKey])
        let endpointFileCandidates = readEndpointCandidates(from: configuredEndpointFile)
            ?? readEndpointCandidates(from: NovotroProjectServiceConfiguration.defaultEndpointFileURL().path)
            ?? []
        for candidate in endpointFileCandidates {
            append(endpoint(from: candidate))
        }

        if let remembered = defaults.string(forKey: lastSuccessfulEndpointDefaultsKey) {
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
        let port = NovotroProjectServiceConfiguration.defaultPort
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
