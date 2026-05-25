import CoreFoundation
import Darwin
import Foundation
import ProjectKit

private enum CLIError: LocalizedError {
    case usage
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return """
            usage:
              project-cli serve [--port <port>]
            project-cli server-ping
            project-cli server-info
            project-cli server-mcp
            project-cli server-endpoints
            project-cli server-list
              project-cli server-add <project.owp>
              project-cli server-remove <project-id>
              project-cli ensure <project.owp>
              project-cli export <project.owp>
              project-cli scenes <project.owp>
              project-cli get-scene <project.owp> <relative/song/path.ows>
              project-cli set-song-text <project.owp> <relative/song/path.ows> <text-file>
              project-cli get-song-playback <project.owp> <relative/song/path.ows>
              project-cli set-song-playback <project.owp> <relative/song/path.ows> <json-file>
              project-cli get-animation-scene <project.owp> <relative/song/path.ows>
              project-cli set-animation-scene <project.owp> <relative/song/path.ows> <json-file>
              project-cli get-project-file <project.owp> <relative/path>
              project-cli set-project-file <project.owp> <relative/path> <file>
            """
        case let .invalid(message):
            return message
        }
    }
}

private final class CLIServiceRuntime: @unchecked Sendable {
    private let host: ProjectServiceHost
    private var signalSources: [DispatchSourceSignal] = []

    init(host: ProjectServiceHost) {
        self.host = host
    }

    func start() {
        host.stateHandler = { [runtime = self] state in
            switch state {
            case .ready:
                fputs("Project Service listening on port \(runtime.host.port)\n", stderr)
            case let .failed(error):
                fputs("Project Service failed: \(error.localizedDescription)\n", stderr)
                runtime.stop()
            case .cancelled:
                runtime.stop()
            default:
                break
            }
        }
        host.start()
        installSignalHandlers()
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stop()
            }
            source.resume()
            return source
        }
    }

    private func stop() {
        host.stop()
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

@main
struct ProjectCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            let nsError = error as NSError
            let details = [
                "type=\(String(describing: type(of: error)))",
                "debug=\(String(reflecting: error))",
                "description=\(error.localizedDescription)",
                "domain=\(nsError.domain)",
                "code=\(nsError.code)",
                "failureReason=\(nsError.localizedFailureReason ?? "nil")",
                "recoverySuggestion=\(nsError.localizedRecoverySuggestion ?? "nil")",
                "underlying=\((nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? "nil")"
            ].joined(separator: " | ")
            fputs("project-cli: \(details)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { throw CLIError.usage }

        let command = arguments[0]
        if command == "serve" {
            try runService(arguments: Array(arguments.dropFirst()))
            return
        }
        if command == "server-ping" {
            try await runServerPing()
            return
        }
        if command == "server-info" {
            try await runServerInfo()
            return
        }
        if command == "server-mcp" {
            try await runServerMCPTools()
            return
        }
        if command == "server-endpoints" {
            runServerEndpointList()
            return
        }
        if command == "server-list" {
            try runServerList()
            return
        }
        if command == "server-add" {
            guard arguments.count >= 2 else { throw CLIError.usage }
            try runServerAdd(projectPath: arguments[1])
            return
        }
        if command == "server-remove" {
            guard arguments.count >= 2 else { throw CLIError.usage }
            try runServerRemove(projectID: arguments[1])
            return
        }

        guard arguments.count >= 2 else { throw CLIError.usage }
        let projectURL = URL(fileURLWithPath: arguments[1])
        let connection = try await ProjectConnection.open(projectURL: projectURL)
        let actorID = ProjectClientIdentity.actorID(for: "project-cli")

        switch command {
        case "ensure":
            try await connection.ensureCurrentIndex()
            let mode = connection.mode
            switch mode {
            case .local:
                print(ProjectClientIdentity.projectDatabaseDirectoryURL(for: projectURL).appendingPathComponent("project.sqlite").path)
            case .remoteService:
                print("remote-service")
            }

        case "export":
            try await connection.ensureCurrentIndex()
            try await connection.exportLegacy()
            print("exported")

        case "scenes":
            try await connection.ensureCurrentIndex()
            let scenes = try await connection.loadProjectScenes(
                includeVersions: false,
                includeRootJSON: false,
                includeAnimateSceneJSON: false,
                includeVersionJSON: false,
                includePlaybackJSON: false
            )
            for scene in scenes {
                print("\(scene.relativePath)\t\(scene.title)")
            }

        case "get-scene":
            guard arguments.count >= 3 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            guard let scene = try await connection.loadScene(relativePath: arguments[2]) else {
                throw CLIError.invalid("Unknown scene: \(arguments[2])")
            }
            try emitJSON([
                "relativePath": scene.relativePath,
                "title": scene.title,
                "notes": scene.notes,
                "activeVersionID": scene.activeVersionID?.uuidString as Any,
                "versions": scene.versions.map { version in
                    [
                        "id": version.id.uuidString,
                        "label": version.label,
                        "saveType": version.saveType,
                        "userLabel": version.userLabel as Any,
                        "isBookmarked": version.isBookmarked,
                        "createdAt": isoString(version.createdAt),
                        "updatedAt": isoString(version.updatedAt),
                        "lyrics": version.lyrics,
                        "hasPlayback": version.playbackJSON != nil,
                    ] as [String: Any]
                },
            ])

        case "set-song-text":
            guard arguments.count >= 4 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            let text = try String(contentsOfFile: arguments[3], encoding: .utf8)
            try await connection.updateSongText(relativePath: arguments[2], lyrics: text, actorID: actorID)
            print("updated")

        case "get-song-playback":
            guard arguments.count >= 3 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            guard let scene = try await connection.loadScene(relativePath: arguments[2]),
                  let activeVersion = scene.versions.first(where: { $0.id == scene.activeVersionID }) ?? scene.versions.first,
                  let playbackJSON = activeVersion.playbackJSON else {
                throw CLIError.invalid("No playback JSON for \(arguments[2])")
            }
            FileHandle.standardOutput.write(playbackJSON)

        case "set-song-playback":
            guard arguments.count >= 4 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
            try await connection.updateSongPlayback(relativePath: arguments[2], playbackJSON: data, actorID: actorID)
            print("updated")

        case "get-animation-scene":
            guard arguments.count >= 3 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            guard let scene = try await connection.loadScene(relativePath: arguments[2]),
                  let json = scene.animateSceneJSON else {
                throw CLIError.invalid("No animation scene JSON for \(arguments[2])")
            }
            FileHandle.standardOutput.write(json)

        case "set-animation-scene":
            guard arguments.count >= 4 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
            try await connection.upsertAnimationScene(owsPath: arguments[2], jsonData: data, actorID: actorID)
            print("updated")

        case "get-project-file":
            guard arguments.count >= 3 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            guard let file = try await connection.loadProjectFile(path: arguments[2]) else {
                throw CLIError.invalid("No stored project file: \(arguments[2])")
            }
            FileHandle.standardOutput.write(file.jsonData)

        case "set-project-file":
            guard arguments.count >= 4 else { throw CLIError.usage }
            try await connection.ensureCurrentIndex()
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
            try await connection.upsertProjectFile(path: arguments[2], jsonData: data, actorID: actorID)
            print("updated")

        default:
            throw CLIError.usage
        }
    }

    private static func runService(arguments: [String]) throws {
        let port = try parseServicePort(arguments: arguments)
        let host = try ProjectServiceHost(port: port)
        let runtime = CLIServiceRuntime(host: host)
        runtime.start()
        RunLoop.main.run()
        withExtendedLifetime(runtime) {}
    }

    private static func parseServicePort(arguments: [String]) throws -> UInt16 {
        if let explicit = ProcessInfo.processInfo.environment["PROJECT_SERVICE_PORT"]
            ?? ProcessInfo.processInfo.environment["AMIRA_PROJECT_SERVICE_PORT"]
            ?? ProcessInfo.processInfo.environment["NOVOTRO_PROJECT_SERVICE_PORT"],
           !explicit.isEmpty {
            guard let port = UInt16(explicit) else {
                throw CLIError.invalid("Invalid port: \(explicit)")
            }
            return port
        }

        guard let flagIndex = arguments.firstIndex(of: "--port") else {
            return 19847
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex),
              let port = UInt16(arguments[valueIndex]) else {
            throw CLIError.invalid("Missing or invalid value for --port")
        }
        return port
    }

    private static func runServerList() throws {
        let registry = ProjectServerRegistry()
        try registry.ensureStorageDirectories()
        for project in try registry.listProjects() {
            print("\(project.id.uuidString)\t\(project.displayName)\t\(project.managedProjectURL.path)")
        }
    }

    private static func runServerAdd(projectPath: String) throws {
        let registry = ProjectServerRegistry()
        try registry.ensureStorageDirectories()
        let registration = try registry.addProject(from: URL(fileURLWithPath: projectPath))
        print("\(registration.id.uuidString)\t\(registration.displayName)\t\(registration.managedProjectURL.path)")
    }

    private static func runServerRemove(projectID: String) throws {
        guard let uuid = UUID(uuidString: projectID) else {
            throw CLIError.invalid("Invalid project id: \(projectID)")
        }
        let registry = ProjectServerRegistry()
        try registry.removeProject(id: uuid)
        print("removed")
    }

    private static func runServerPing() async throws {
        let client = try await ProjectServerClient.discover()
        try await client.ping()
        print("pong")
    }

    private static func runServerInfo() async throws {
        let client = try await ProjectServerClient.discover()
        let info = try await client.serviceInfo()
        try emitJSON(info)
    }

    private static func runServerMCPTools() async throws {
        let client = try await ProjectServerClient.discover()
        let tools = try await client.mcpTools()
        try emitJSON(tools)
    }

    private static func runServerEndpointList() {
        let endpoints = ProjectServiceEndpointDiscovery.candidateEndpoints()
        for endpoint in endpoints {
            if let serialized = ProjectServiceEndpointDiscovery.serializedEndpointString(endpoint) {
                print(serialized)
            }
        }
    }

    private static func emitJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
    }

    private static func emitJSON<T: Encodable>(_ object: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(object)
        FileHandle.standardOutput.write(data)
    }

    private static func isoString(_ date: Date) -> String {
        AmiraDateFormatter.iso8601Full.string(from: date)
    }
}
