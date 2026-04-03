import CoreFoundation
import Darwin
import Foundation
import ProjectKit

private enum ServiceError: LocalizedError {
    case invalidPort(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(value):
            return "Invalid port: \(value)"
        }
    }
}

private final class ServiceRuntime: @unchecked Sendable {
    private let host: ProjectServiceHost
    private var signalSources: [DispatchSourceSignal] = []

    init(host: ProjectServiceHost) {
        self.host = host
    }

    func start() {
        host.stateHandler = { state in
            switch state {
            case .ready:
                fputs("Project Service listening on port \(self.host.port)\n", stderr)
            case let .failed(error):
                fputs("Project Service failed: \(error.localizedDescription)\n", stderr)
                self.stop()
            case .cancelled:
                self.stop()
            default:
                break
            }
        }
        host.start()
        installSignalHandlers()
    }

    func stop() {
        host.stop()
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        CFRunLoopStop(CFRunLoopGetMain())
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
}

@main
struct ProjectService {
    static func main() {
        do {
            try run()
        } catch {
            fputs("project-service: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let port = try parsePort(arguments: Array(CommandLine.arguments.dropFirst()))
        let host = try ProjectServiceHost(port: port)
        let runtime = ServiceRuntime(host: host)
        runtime.start()
        RunLoop.main.run()
        withExtendedLifetime(runtime) {}
    }

    private static func parsePort(arguments: [String]) throws -> UInt16 {
        if let explicit = ProcessInfo.processInfo.environment["PROJECT_SERVICE_PORT"]
            ?? ProcessInfo.processInfo.environment["NOVOTRO_PROJECT_SERVICE_PORT"],
           !explicit.isEmpty {
            guard let port = UInt16(explicit) else {
                throw ServiceError.invalidPort(explicit)
            }
            return port
        }

        guard let flagIndex = arguments.firstIndex(of: "--port") else {
            return 19847
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex),
              let port = UInt16(arguments[valueIndex]) else {
            throw ServiceError.invalidPort(arguments.indices.contains(valueIndex) ? arguments[valueIndex] : "")
        }
        return port
    }
}
