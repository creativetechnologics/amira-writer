import Foundation
import Network
import XCTest
@testable import NovotroProjectKit

final class NovotroProjectServiceEndpointDiscoveryTests: XCTestCase {
    func testCandidateEndpointsPreferExplicitThenRememberedThenFallbackHosts() async {
        let suiteName = "NovotroProjectServiceEndpointDiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let emptyEndpointFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovotroProjectServiceEndpointDiscoveryTests-Empty-\(UUID().uuidString).txt")
        try! "".write(to: emptyEndpointFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: emptyEndpointFile)
        }

        let port = NWEndpoint.Port(rawValue: NovotroProjectServiceConfiguration.defaultPort)!
        let remembered = NWEndpoint.hostPort(host: .name("remembered.local", nil), port: port)
        NovotroProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(remembered, defaults: defaults)

        let endpoints = NovotroProjectServiceEndpointDiscovery.candidateEndpoints(
            environment: [
                NovotroProjectServiceEndpointDiscovery.endpointEnvironmentKey: "explicit.local:\(NovotroProjectServiceConfiguration.defaultPort)",
                NovotroProjectServiceConfiguration.endpointFileEnvironmentKey: emptyEndpointFile.path
            ],
            defaults: defaults
        )

        let serialized = endpoints.compactMap(NovotroProjectServiceEndpointDiscovery.serializedEndpointString)
        XCTAssertGreaterThanOrEqual(serialized.count, 5)
        XCTAssertEqual(serialized[0], "explicit.local:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[1], "remembered.local:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[2], "garys-server.local:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[3], "127.0.0.1:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[4], "localhost:\(NovotroProjectServiceConfiguration.defaultPort)")
    }

    func testCandidateEndpointsLoadFromEndpointFile() async {
        let suiteName = "NovotroProjectServiceEndpointDiscoveryTests.EndpointFile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovotroProjectServiceEndpointDiscoveryTests-\(UUID().uuidString).txt")
        try! "custom.server.local:\(NovotroProjectServiceConfiguration.defaultPort)".write(
            to: tempFile,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let port = NWEndpoint.Port(rawValue: NovotroProjectServiceConfiguration.defaultPort)!
        let remembered = NWEndpoint.hostPort(host: .name("remembered.local", nil), port: port)
        NovotroProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(remembered, defaults: defaults)

        let endpoints = NovotroProjectServiceEndpointDiscovery.candidateEndpoints(
            environment: [
                NovotroProjectServiceEndpointDiscovery.endpointEnvironmentKey: "explicit.local:\(NovotroProjectServiceConfiguration.defaultPort)",
                NovotroProjectServiceConfiguration.endpointFileEnvironmentKey: tempFile.path
            ],
            defaults: defaults
        )

        let serialized = endpoints.compactMap(NovotroProjectServiceEndpointDiscovery.serializedEndpointString)
        XCTAssertEqual(serialized.count, 6)
        XCTAssertEqual(serialized[0], "explicit.local:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[1], "custom.server.local:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[2], "remembered.local:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[3], "garys-server.local:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[4], "127.0.0.1:\(NovotroProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[5], "localhost:\(NovotroProjectServiceConfiguration.defaultPort)")
    }
}
