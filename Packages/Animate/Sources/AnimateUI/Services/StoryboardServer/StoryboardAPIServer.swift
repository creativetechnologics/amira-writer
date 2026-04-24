import Foundation
import Network

// MARK: - StoryboardAPIServer
//
// LAN HTTP server for the iPad storyboard drawing tool. Binds to 0.0.0.0:19850
// so any device on the local network can reach it. Port 19849 is already taken
// by AnimateAPIServer (loopback). The frontend contract uses 19850.
//
// Pattern mirrors AnimateAPIServer.swift (loopback variant in the same package).

@available(macOS 26.0, *)
final class StoryboardAPIServer: @unchecked Sendable {

    static let port: UInt16 = 19850

    @MainActor
    static var shared: StoryboardAPIServer?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.amira.storyboard.api", qos: .userInitiated)
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private let router: StoryboardRouter
    private(set) var boundPort: UInt16

    @MainActor
    init(workspace: AnimateWorkspaceController) throws {
        self.boundPort = Self.port
        self.router = StoryboardRouter(workspace: workspace)

        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else {
            throw NSError(domain: "StoryboardAPIServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(Self.port)"])
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: nwPort)
        params.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: params)
    }

    deinit {
        listener.cancel()
        queue.async { [connections = self.connections] in
            for conn in connections.values { conn.cancel() }
        }
    }

    @MainActor
    static func startIfNeeded(workspace: AnimateWorkspaceController) {
        guard shared == nil else { return }
        do {
            let server = try StoryboardAPIServer(workspace: workspace)
            server.start()
            shared = server
            NSLog("[StoryboardServer] Started on port %d", Self.port)
        } catch {
            NSLog("[StoryboardServer] Failed to start: %@", error.localizedDescription)
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = self?.listener.port?.rawValue {
                    self?.boundPort = p
                    NSLog("[StoryboardServer] Listening on 0.0.0.0:%d", p)
                }
            case .failed(let error):
                NSLog("[StoryboardServer] Listener failed: %@", error.localizedDescription)
                self?.listener.cancel()
            case .cancelled:
                NSLog("[StoryboardServer] Listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections.values { conn.cancel() }
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
        }
    }

    /// Returns the LAN URL an iPad should open. Prefers en0/en1; falls back to loopback.
    func currentURL() -> URL {
        if let lan = primaryLANIPv4() {
            return URL(string: "http://\(lan):\(boundPort)")!
        }
        return URL(string: "http://127.0.0.1:\(boundPort)")!
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        receiveBuffers[id] = Data()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cleanupConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMore(on: connection, id: id)
    }

    private func cleanupConnection(_ id: ObjectIdentifier) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        receiveBuffers.removeValue(forKey: id)
        conn.cancel()
    }

    private func receiveMore(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 10_485_760) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.connections[id] != nil else { return }

            if let data, !data.isEmpty {
                self.receiveBuffers[id, default: Data()].append(data)
            }
            let buffer = self.receiveBuffers[id] ?? Data()

            if let request = SBHTTPRequest.parse(buffer) {
                self.receiveBuffers[id] = nil
                self.processRequest(request, connection: connection, id: id)
            } else if isComplete || error != nil {
                self.cleanupConnection(id)
            } else if buffer.count > 20_971_520 {
                self.sendResponse(SBHTTPResponse.error(413, "Request too large"), on: connection, id: id)
            } else {
                self.receiveMore(on: connection, id: id)
            }
        }
    }

    private func processRequest(_ request: SBHTTPRequest, connection: NWConnection, id: ObjectIdentifier) {
        Task { @MainActor [weak self, router] in
            let response = await router.handle(request)
            guard let self else { connection.cancel(); return }
            self.queue.async { [weak self] in
                self?.sendResponse(response, on: connection, id: id)
            }
        }
    }

    private func sendResponse(_ response: SBHTTPResponse, on connection: NWConnection, id: ObjectIdentifier) {
        let httpData = response.serialize()
        connection.send(content: httpData, completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[StoryboardServer] Send error: %@", error.localizedDescription)
            }
            self?.cleanupConnection(id)
        })
    }

    // MARK: - LAN IP detection

    private func primaryLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let ifa_addr = current.pointee.ifa_addr,
                  ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }

            var addr = ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)

            if name.hasPrefix("en") {
                preferred = ip
                break
            } else if !name.hasPrefix("utun") {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }
}
