import Foundation
import Network
import XCTest
@testable import ProjectKit

final class ProjectServiceEndpointDiscoveryTests: XCTestCase {
    func testCandidateEndpointsPreferExplicitThenRememberedThenFallbackHosts() async {
        let suiteName = "ProjectServiceEndpointDiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let emptyEndpointFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectServiceEndpointDiscoveryTests-Empty-\(UUID().uuidString).txt")
        try! "".write(to: emptyEndpointFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: emptyEndpointFile)
        }

        let port = NWEndpoint.Port(rawValue: ProjectServiceConfiguration.defaultPort)!
        let remembered = NWEndpoint.hostPort(host: .name("remembered.local", nil), port: port)
        ProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(remembered, defaults: defaults)

        let endpoints = ProjectServiceEndpointDiscovery.candidateEndpoints(
            environment: [
                ProjectServiceEndpointDiscovery.endpointEnvironmentKey: "explicit.local:\(ProjectServiceConfiguration.defaultPort)",
                ProjectServiceConfiguration.endpointFileEnvironmentKey: emptyEndpointFile.path
            ],
            defaults: defaults
        )

        let serialized = endpoints.compactMap(ProjectServiceEndpointDiscovery.serializedEndpointString)
        XCTAssertGreaterThanOrEqual(serialized.count, 5)
        XCTAssertEqual(serialized[0], "explicit.local:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[1], "remembered.local:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[2], "garys-server.local:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[3], "127.0.0.1:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[4], "localhost:\(ProjectServiceConfiguration.defaultPort)")
    }

    func testCandidateEndpointsLoadFromEndpointFile() async {
        let suiteName = "ProjectServiceEndpointDiscoveryTests.EndpointFile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectServiceEndpointDiscoveryTests-\(UUID().uuidString).txt")
        try! "custom.server.local:\(ProjectServiceConfiguration.defaultPort)".write(
            to: tempFile,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let port = NWEndpoint.Port(rawValue: ProjectServiceConfiguration.defaultPort)!
        let remembered = NWEndpoint.hostPort(host: .name("remembered.local", nil), port: port)
        ProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(remembered, defaults: defaults)

        let endpoints = ProjectServiceEndpointDiscovery.candidateEndpoints(
            environment: [
                ProjectServiceEndpointDiscovery.endpointEnvironmentKey: "explicit.local:\(ProjectServiceConfiguration.defaultPort)",
                ProjectServiceConfiguration.endpointFileEnvironmentKey: tempFile.path
            ],
            defaults: defaults
        )

        let serialized = endpoints.compactMap(ProjectServiceEndpointDiscovery.serializedEndpointString)
        XCTAssertEqual(serialized.count, 6)
        XCTAssertEqual(serialized[0], "explicit.local:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[1], "custom.server.local:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[2], "remembered.local:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[3], "garys-server.local:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[4], "127.0.0.1:\(ProjectServiceConfiguration.defaultPort)")
        XCTAssertEqual(serialized[5], "localhost:\(ProjectServiceConfiguration.defaultPort)")
    }
}
