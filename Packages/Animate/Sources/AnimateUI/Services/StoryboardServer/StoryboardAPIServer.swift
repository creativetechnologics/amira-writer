import Foundation
import Network

// MARK: - StoryboardAPIServer
//
// LAN HTTP server for the iPad storyboard drawing tool. Binds to 0.0.0.0 on a
// configurable port so any device on the local network can reach it. Port 19849
// is already taken by AnimateAPIServer (loopback), so the default remains 19850.
//
// Pattern mirrors AnimateAPIServer.swift (loopback variant in the same package).

@available(macOS 26.0, *)
final class StoryboardAPIServer: @unchecked Sendable {

    static let defaultPort: UInt16 = 19850
    static let portDefaultsKey = "animate.storyboard.server.port"
    static let allowedPortRange = 1024...65535

    @MainActor
    static var shared: StoryboardAPIServer?

    @MainActor
    private static weak var activeWorkspace: AnimateWorkspaceController?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.amira.storyboard.api", qos: .userInitiated)
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private let router: StoryboardRouter
    private let configuredPort: UInt16
    private(set) var boundPort: UInt16

    @MainActor
    init(workspace: AnimateWorkspaceController, port: UInt16) throws {
        self.configuredPort = port
        self.boundPort = port
        self.router = StoryboardRouter(workspace: workspace)

        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "StoryboardAPIServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
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
        startOrRestart(workspace: workspace, forceRestart: false)
    }

    @MainActor
    static func setConfiguredPort(_ value: Int) {
        let port = sanitizedPort(value)
        UserDefaults.standard.set(Int(port), forKey: portDefaultsKey)
        if let workspace = activeWorkspace {
            startOrRestart(workspace: workspace, forceRestart: true)
        } else {
            StoryboardServerStatusModel.shared.setStopped(
                port: port,
                url: currentConfiguredURL()
            )
        }
    }

    static var configuredPortValue: UInt16 {
        sanitizedPort(UserDefaults.standard.integer(forKey: portDefaultsKey))
    }

    static func currentConfiguredURL() -> URL {
        url(for: sanitizedPort(UserDefaults.standard.integer(forKey: portDefaultsKey)))
    }

    private static func sanitizedPort(_ value: Int) -> UInt16 {
        guard allowedPortRange.contains(value), let port = UInt16(exactly: value) else {
            return defaultPort
        }
        return port
    }

    @MainActor
    private static func startOrRestart(workspace: AnimateWorkspaceController, forceRestart: Bool) {
        activeWorkspace = workspace
        let desiredPort = configuredPortValue

        if let server = shared {
            if !forceRestart, server.configuredPort == desiredPort {
                server.router.updateWorkspace(workspace)
                StoryboardServerStatusModel.shared.setLive(
                    port: server.boundPort,
                    url: server.currentURL()
                )
                return
            }
            server.stop()
            shared = nil
        }

        StoryboardServerStatusModel.shared.setStarting(
            port: desiredPort,
            url: url(for: desiredPort)
        )
        do {
            let server = try StoryboardAPIServer(workspace: workspace, port: desiredPort)
            shared = server
            server.start()
            NSLog("[StoryboardServer] Starting on port %d", desiredPort)
        } catch {
            StoryboardServerStatusModel.shared.setFailed(
                error.localizedDescription,
                port: desiredPort,
                url: url(for: desiredPort)
            )
            NSLog("[StoryboardServer] Failed to start: %@", error.localizedDescription)
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let self, let p = self.listener.port?.rawValue {
                    self.boundPort = p
                    let url = StoryboardAPIServer.url(for: p)
                    Task { @MainActor [weak self] in
                        guard let self, StoryboardAPIServer.shared === self else { return }
                        StoryboardServerStatusModel.shared.setLive(port: p, url: url)
                    }
                    NSLog("[StoryboardServer] Listening on 0.0.0.0:%d", p)
                }
            case .failed(let error):
                let port = self?.configuredPort ?? StoryboardAPIServer.configuredPortValue
                Task { @MainActor [weak self] in
                    guard let self, StoryboardAPIServer.shared === self else { return }
                    StoryboardServerStatusModel.shared.setFailed(
                        error.localizedDescription,
                        port: port,
                        url: StoryboardAPIServer.url(for: port)
                    )
                    StoryboardAPIServer.shared = nil
                }
                NSLog("[StoryboardServer] Listener failed: %@", error.localizedDescription)
                self?.listener.cancel()
            case .cancelled:
                let port = self?.configuredPort ?? StoryboardAPIServer.configuredPortValue
                Task { @MainActor [weak self] in
                    guard let self, StoryboardAPIServer.shared === self else { return }
                    StoryboardServerStatusModel.shared.setStopped(
                        port: port,
                        url: StoryboardAPIServer.url(for: port)
                    )
                }
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
        Self.url(for: boundPort)
    }

    static func url(for port: UInt16) -> URL {
        if let lan = primaryLANIPv4() {
            return URL(string: "http://\(lan):\(port)")!
        }
        return URL(string: "http://127.0.0.1:\(port)")!
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

    private static func primaryLANIPv4() -> String? {
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
