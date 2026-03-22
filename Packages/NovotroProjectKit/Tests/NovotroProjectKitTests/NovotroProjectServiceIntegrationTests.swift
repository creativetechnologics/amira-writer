import Darwin
import Foundation
import Network
import XCTest
@testable import NovotroProjectKit

final class NovotroProjectServiceIntegrationTests: XCTestCase {
    func testRemoteConnectionLoadsProjectWithoutInliningHeavyProjectFiles() async throws {
        let fixture = try makeServiceFixtureProject()
        let songPath = "Songs/01 Opening.ows"
        let versionID = UUID()
        let authToken = "integration-token"
        try writeServiceFixtureSong(
            in: fixture,
            relativePath: songPath,
            title: "Opening",
            versionID: versionID,
            lyrics: "Remote lyrics"
        )

        let metadataBytes = Data("{\"name\":\"Remote Fixture\"}".utf8)
        let soundFontBytes = Data([0x53, 0x46, 0x32, 0x10, 0x20, 0x30])
        try writeServiceFixtureFile(in: fixture, relativePath: "Metadata/project.json", data: metadataBytes)
        try writeServiceFixtureFile(in: fixture, relativePath: "SoundFonts/remote.sf2", data: soundFontBytes)

        let database = NovotroProjectDatabase(projectURL: fixture)
        try await database.ensureCurrentIndex(forceRebuild: true)

        let (host, port) = try makeIntegrationServiceHost(
            authToken: authToken,
            allowedRoots: [fixture.deletingLastPathComponent()]
        )
        let ready = expectation(description: "service ready")
        let readyBox = ExpectationBox(ready)
        host.stateHandler = { state in
            if case .ready = state {
                readyBox.fulfill()
            }
        }
        host.start()
        defer {
            host.stop()
            unsetenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT")
            unsetenv("NOVOTRO_FORCE_PROJECT_SERVICE")
            unsetenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey)
        }
        await fulfillment(of: [ready], timeout: 5)

        setenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT", "127.0.0.1:\(port)", 1)
        setenv("NOVOTRO_FORCE_PROJECT_SERVICE", "1", 1)
        setenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey, authToken, 1)

        let connection = try await NovotroProjectConnection.open(projectURL: fixture)
        let mode = await connection.mode
        XCTAssertEqual(mode, .remoteService)

        let summary = try await connection.loadProjectSummary()
        XCTAssertEqual(summary.scenes.count, 1)

        let scenes = try await connection.loadProjectScenes(
            includeVersions: true,
            includeRootJSON: false,
            includeAnimateSceneJSON: false,
            includeVersionJSON: false,
            includePlaybackJSON: false
        )
        XCTAssertEqual(scenes.count, 1)
        XCTAssertNil(scenes.first?.rootJSON)
        XCTAssertNil(scenes.first?.animateSceneJSON)
        XCTAssertEqual(scenes.first?.activeVersion?.lyrics, "Remote lyrics")
        XCTAssertNil(scenes.first?.activeVersion?.versionJSON)
        XCTAssertNil(scenes.first?.activeVersion?.playbackJSON)

        let project = try await connection.loadProject()
        XCTAssertEqual(project.scenes.first?.relativePath, songPath)
        XCTAssertNotNil(project.projectFile(at: "Metadata/project.json"))
        XCTAssertNil(project.projectFile(at: "SoundFonts/remote.sf2"))

        let loadedSoundFont = try await connection.loadProjectFile(path: "SoundFonts/remote.sf2")
        XCTAssertEqual(loadedSoundFont?.jsonData, soundFontBytes)
    }

    func testRemoteMutationRebuildsColdDatabaseBeforeWriting() async throws {
        let fixture = try makeServiceFixtureProject()
        let songPath = "Songs/01 Opening.ows"
        let versionID = UUID()
        let authToken = "integration-token"
        try writeServiceFixtureSong(
            in: fixture,
            relativePath: songPath,
            title: "Opening",
            versionID: versionID,
            lyrics: "Initial lyrics"
        )

        let (host, port) = try makeIntegrationServiceHost(
            authToken: authToken,
            allowedRoots: [fixture.deletingLastPathComponent()]
        )
        let ready = expectation(description: "cold-service-ready")
        let readyBox = ExpectationBox(ready)
        host.stateHandler = { state in
            if case .ready = state {
                readyBox.fulfill()
            }
        }
        host.start()
        defer {
            host.stop()
        }
        await fulfillment(of: [ready], timeout: 5)

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return XCTFail("Invalid test port")
        }

        let client = NovotroProjectRemoteClient.connect(
            endpoint: .hostPort(host: .ipv4(.loopback), port: endpointPort),
            projectURL: fixture,
            authToken: authToken
        )

        try await client.updateSongText(
            relativePath: songPath,
            lyrics: "Updated after cold rebuild",
            versionID: versionID,
            actorID: "integration-test"
        )

        let scene = try await client.loadScene(relativePath: songPath)
        XCTAssertEqual(scene?.activeVersion?.lyrics, "Updated after cold rebuild")
    }

    func testRemoteConnectionRejectsWrongAuthToken() async throws {
        let fixture = try makeServiceFixtureProject()
        let songPath = "Songs/01 Opening.ows"
        let versionID = UUID()
        try writeServiceFixtureSong(
            in: fixture,
            relativePath: songPath,
            title: "Opening",
            versionID: versionID,
            lyrics: "Remote lyrics"
        )

        let (host, port) = try makeIntegrationServiceHost(
            authToken: "expected-token",
            allowedRoots: [fixture.deletingLastPathComponent()]
        )
        let ready = expectation(description: "auth-ready")
        let readyBox = ExpectationBox(ready)
        host.stateHandler = { state in
            if case .ready = state {
                readyBox.fulfill()
            }
        }
        host.start()
        defer {
            host.stop()
            unsetenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT")
            unsetenv("NOVOTRO_FORCE_PROJECT_SERVICE")
            unsetenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey)
        }
        await fulfillment(of: [ready], timeout: 5)

        setenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT", "127.0.0.1:\(port)", 1)
        setenv("NOVOTRO_FORCE_PROJECT_SERVICE", "1", 1)
        setenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey, "wrong-token", 1)

        do {
            _ = try await NovotroProjectConnection.open(projectURL: fixture)
            XCTFail("Expected remote open to fail with the wrong auth token")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testPathsReferToSameProjectAcceptsProgrammingMirrorPaths() {
        let laptopPath = URL(fileURLWithPath: "/Volumes/Programming/Amira - A Modern Opera/Amira.owp")
        let serverPath = "/Volumes/Storage VIII/Programming/Amira - A Modern Opera/Amira.owp"
        let wrongServerPath = "/Volumes/Storage VIII/Programming/Another Opera/Another.owp"

        XCTAssertTrue(
            NovotroProjectRemoteClient.pathsReferToSameProject(
                requestedProjectURL: laptopPath,
                resolvedProjectPath: serverPath
            )
        )
        XCTAssertFalse(
            NovotroProjectRemoteClient.pathsReferToSameProject(
                requestedProjectURL: laptopPath,
                resolvedProjectPath: wrongServerPath
            )
        )
    }

    func testResponseAcceptsManagedProjectIdentityWhenRequestedSignatureIsRegisteredAlias() {
        let requestedPath = URL(fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira - A Modern Opera/Amira.owp")
        let resolvedManagedPath = "/Volumes/Storage VIII/Users/gary/Documents/Novotro Project Server/Projects/Amira.owp"
        let acceptedSignatures = [
            "Programming/Amira - A Modern Opera/Amira.owp",
            "Documents/Novotro Project Server/Projects/Amira.owp",
        ]

        XCTAssertTrue(
            NovotroProjectRemoteClient.responseAcceptsProjectIdentity(
                requestedProjectURL: requestedPath,
                resolvedProjectPath: resolvedManagedPath,
                acceptedProjectSignatures: acceptedSignatures
            )
        )
    }

    func testServerClientCanListCreateRenameAndRemoveProjects() async throws {
        let fixture = try makeServiceFixtureProject()
        let authToken = "integration-token"
        let registryRoot = fixture.deletingLastPathComponent().appendingPathComponent("ServerRoot", isDirectory: true)
        let registry = NovotroProjectServerRegistry(rootURL: registryRoot)
        try registry.ensureStorageDirectories()
        _ = try registry.addProject(from: fixture, displayName: "Fixture")

        let (host, port) = try makeIntegrationServiceHost(
            authToken: authToken,
            allowedRoots: [registryRoot, fixture.deletingLastPathComponent()],
            registry: registry
        )
        let ready = expectation(description: "server-browser-ready")
        let readyBox = ExpectationBox(ready)
        host.stateHandler = { state in
            if case .ready = state {
                readyBox.fulfill()
            }
        }
        host.start()
        defer {
            host.stop()
            unsetenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT")
            unsetenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey)
        }
        await fulfillment(of: [ready], timeout: 5)

        setenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT", "127.0.0.1:\(port)", 1)
        setenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey, authToken, 1)

        let client = try await NovotroProjectServerClient.discover()
        let listed = try await client.listProjects()
        XCTAssertEqual(listed.count, 1)

        let created = try await client.createProject(named: "Atlas")
        XCTAssertEqual(created.displayName, "Atlas")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.managedProjectURL.path))

        let renamed = try await client.renameProject(id: created.id, to: "Atlas Revised")
        XCTAssertEqual(renamed.displayName, "Atlas Revised")

        try await client.removeProject(id: renamed.id, deleteManagedProject: true)
        let refreshed = try await client.listProjects()
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.displayName, "Fixture")
    }

    func testServerClientCanFetchServiceInfoAndMCPTools() async throws {
        let fixture = try makeServiceFixtureProject()
        let authToken = "integration-token"
        let (host, port) = try makeIntegrationServiceHost(
            authToken: authToken,
            allowedRoots: [fixture.deletingLastPathComponent()]
        )
        let ready = expectation(description: "service-info-ready")
        let readyBox = ExpectationBox(ready)
        host.stateHandler = { state in
            if case .ready = state {
                readyBox.fulfill()
            }
        }
        host.start()
        defer {
            host.stop()
            unsetenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT")
            unsetenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey)
        }
        await fulfillment(of: [ready], timeout: 5)

        setenv("NOVOTRO_PROJECT_SERVICE_ENDPOINT", "127.0.0.1:\(port)", 1)
        setenv(NovotroProjectServiceConfiguration.authTokenEnvironmentKey, authToken, 1)

        let client = try await NovotroProjectServerClient.discover()
        let info = try await client.serviceInfo()
        XCTAssertFalse(info.supportedOperations.isEmpty)
        XCTAssertTrue(info.supportsManagedProjects)
        XCTAssertTrue(info.supportsProjectOperations)

        let tools = try await client.mcpTools()
        let toolNames = Set(tools.map(\.name))
        XCTAssertTrue(toolNames.contains("service_ping"))
        XCTAssertTrue(toolNames.contains("service_info"))
        XCTAssertFalse(toolNames.isEmpty)
    }
}

private final class ExpectationBox: @unchecked Sendable {
    let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private func makeIntegrationServiceHost(
    authToken: String,
    allowedRoots: [URL],
    registry: NovotroProjectServerRegistry = NovotroProjectServerRegistry()
) throws -> (NovotroProjectServiceHost, UInt16) {
    for candidate in UInt16(21000)...UInt16(21032) {
        if let host = try? NovotroProjectServiceHost(
            port: candidate,
            authToken: authToken,
            allowedProjectRoots: allowedRoots,
            registry: registry
        ) {
            return (host, candidate)
        }
    }

    throw NSError(
        domain: "NovotroProjectKitTests",
        code: 99,
        userInfo: [NSLocalizedDescriptionKey: "Could not allocate a test service port"]
    )
}

private func makeServiceFixtureProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NovotroProjectServiceTests-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("Fixture.owp", isDirectory: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent("Songs"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent("Metadata"), withIntermediateDirectories: true)
    return project
}

private func writeServiceFixtureSong(
    in projectURL: URL,
    relativePath: String,
    title: String,
    versionID: UUID,
    lyrics: String
) throws {
    let now = serviceFixtureISO(Date())
    let root: [String: Any] = [
        "songID": UUID().uuidString,
        "title": title,
        "canonicalTitle": title.lowercased(),
        "notes": "",
        "updatedAt": now,
        "activeVersionID": versionID.uuidString,
        "versions": [[
            "id": versionID.uuidString,
            "label": "Initial",
            "createdAt": now,
            "updatedAt": now,
            "lyrics": lyrics,
            "saveType": "manual",
            "isBookmarked": false,
        ]],
    ]

    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try writeServiceFixtureFile(in: projectURL, relativePath: relativePath, data: data)
}

private func writeServiceFixtureFile(in projectURL: URL, relativePath: String, data: Data) throws {
    let url = projectURL.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func serviceFixtureISO(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
