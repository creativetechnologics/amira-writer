import Foundation
import Network

public actor ProjectServerClient {
    private let endpoint: NWEndpoint
    private let authToken: String

    private init(endpoint: NWEndpoint, authToken: String) {
        self.endpoint = endpoint
        self.authToken = authToken
    }

    public static func discover() async throws -> ProjectServerClient {
        guard let authToken = ProjectServiceConfiguration.loadAuthToken(),
              !authToken.isEmpty else {
            throw ProjectRemoteClientError.missingAuthToken
        }

        var lastError: Error?
        for endpoint in ProjectServiceEndpointDiscovery.candidateEndpoints() {
            let client = ProjectServerClient(endpoint: endpoint, authToken: authToken)
            do {
                try await ProjectAsyncTimeout.withTimeout(
                    seconds: 2.5,
                    description: "connecting to \(endpointDescription(endpoint))"
                ) {
                    try await client.confirmAccess()
                }
                ProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(endpoint)
                return client
            } catch {
                lastError = error
            }
        }

        if let bonjourEndpoints = try? await discoverBonjourEndpoints() {
            for endpoint in bonjourEndpoints {
                let client = ProjectServerClient(endpoint: endpoint, authToken: authToken)
                do {
                    try await ProjectAsyncTimeout.withTimeout(
                        seconds: 2.5,
                        description: "connecting to \(endpointDescription(endpoint))"
                    ) {
                        try await client.confirmAccess()
                    }
                    ProjectServiceEndpointDiscovery.recordSuccessfulEndpoint(endpoint)
                    return client
                } catch {
                    lastError = error
                }
            }
        }

        throw lastError ?? ProjectRemoteClientError.noCompatibleServiceFound("Project Service")
    }

    public func listProjects() async throws -> [ProjectServerRegistration] {
        let response = try await send(
            ProjectServiceRequest(
                operation: .listServerProjects,
                projectPath: ""
            )
        )
        return response.serverProjects ?? []
    }

    public func createProject(named displayName: String) async throws -> ProjectServerRegistration {
        let response = try await send(
            ProjectServiceRequest(
                operation: .createServerProject,
                projectPath: "",
                displayName: displayName
            )
        )
        guard let project = response.serverProject else {
            throw ProjectRemoteClientError.invalidResponse("Missing created project.")
        }
        return project
    }

    public func renameProject(id: UUID, to displayName: String) async throws -> ProjectServerRegistration {
        let response = try await send(
            ProjectServiceRequest(
                operation: .renameServerProject,
                projectPath: "",
                projectID: id,
                displayName: displayName
            )
        )
        guard let project = response.serverProject else {
            throw ProjectRemoteClientError.invalidResponse("Missing renamed project.")
        }
        return project
    }

    public func removeProject(id: UUID, deleteManagedProject: Bool = true) async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .removeServerProject,
                projectPath: "",
                projectID: id,
                deleteManagedProject: deleteManagedProject
            )
        )
    }

    public func serviceInfo() async throws -> ProjectServiceInfo {
        let response = try await send(
            ProjectServiceRequest(
                operation: .serviceInfo,
                projectPath: ""
            )
        )
        guard let serviceInfo = response.serviceInfo else {
            throw ProjectRemoteClientError.invalidResponse("Missing serviceInfo response.")
        }
        return serviceInfo
    }

    public func mcpTools() async throws -> [ProjectServiceMCPCapability] {
        let response = try await send(
            ProjectServiceRequest(
                operation: .mcpTools,
                projectPath: ""
            )
        )
        return response.mcpTools ?? []
    }

    public func ping() async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .ping,
                projectPath: ""
            )
        )
    }

    private func confirmAccess() async throws {
        _ = try await send(
            ProjectServiceRequest(
                operation: .ping,
                projectPath: ""
            )
        )
    }

    private func send(_ request: ProjectServiceRequest) async throws -> ProjectServiceResponse {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.opera.project.server-client.\(UUID().uuidString)")
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
            try await waitUntilReady(connection, queue: queue)
            var request = request
            request.authToken = authToken
            request.requestID = request.requestID ?? UUID()
            request.issuedAt = request.issuedAt ?? Date()

            let payload = try ProjectServiceCodec.encoder.encode(request)
            let envelope = try ProjectTransportSecurity.seal(payload, authToken: authToken)
            let envelopeData = try ProjectServiceCodec.encoder.encode(envelope)
            try await sendMessage(envelopeData, over: connection)

            let responseEnvelopeData = try await receiveMessage(over: connection)
            let responseEnvelope = try ProjectServiceCodec.decoder.decode(ProjectServiceEnvelope.self, from: responseEnvelopeData)
            let responseData = try ProjectTransportSecurity.open(responseEnvelope, authToken: authToken)
            let response = try ProjectServiceCodec.decoder.decode(ProjectServiceResponse.self, from: responseData)
            if response.success == false {
                throw ProjectRemoteClientError.remote(response.errorMessage ?? "Remote request failed")
            }
            return response
        } onCancel: {
            connection.cancel()
        }
    }

    private static func discoverBonjourEndpoints(timeout: TimeInterval = 2.5) async throws -> [NWEndpoint] {
        let browser = NWBrowser(
            for: .bonjour(type: ProjectRemoteClient.bonjourServiceType, domain: nil),
            using: .tcp
        )
        let queue = DispatchQueue(label: "com.opera.project.server-discovery")

        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NWEndpoint], Error>) in
                let box = ProjectOneShotContinuation(continuation)
                let discovered = ProjectServerEndpointAccumulator()
                browser.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        browser.cancel()
                        box.fail(error)
                    } else if case .cancelled = state {
                        box.fail(ProjectRemoteClientError.connectionCancelled)
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        discovered.record(result.endpoint)
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    browser.cancel()
                    let endpoints = discovered.snapshot()
                    if endpoints.isEmpty {
                        box.fail(ProjectRemoteClientError.discoveryTimedOut)
                    } else {
                        box.succeed(endpoints)
                    }
                }

                browser.start(queue: queue)
            }
        } onCancel: {
            browser.cancel()
        }
    }

    private static func endpointDescription(_ endpoint: NWEndpoint) -> String {
        ProjectServiceEndpointDiscovery.serializedEndpointString(endpoint)
            ?? String(describing: endpoint)
    }

    private func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ProjectOneShotContinuation(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.succeed(())
                case let .failed(error):
                    box.fail(error)
                case .cancelled:
                    box.fail(ProjectRemoteClientError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func sendMessage(_ data: Data, over connection: NWConnection) async throws {
        var length = UInt64(data.count).bigEndian
        let prefix = Data(bytes: &length, count: MemoryLayout<UInt64>.size)
        try await sendData(prefix + data, over: connection)
    }

    private func sendData(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func receiveMessage(over connection: NWConnection) async throws -> Data {
        let prefix = try await receiveExactly(count: MemoryLayout<UInt64>.size, over: connection)
        let length = prefix.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        guard length <= 256 * 1024 * 1024 else {
            throw ProjectRemoteClientError.invalidResponse("Response too large: \(length) bytes")
        }
        return try await receiveExactly(count: Int(length), over: connection)
    }

    private func receiveExactly(count: Int, over connection: NWConnection) async throws -> Data {
        var remaining = count
        var data = Data()
        while remaining > 0 {
            let chunk = try await receiveChunk(maximumLength: remaining, over: connection)
            guard !chunk.isEmpty else {
                throw ProjectRemoteClientError.invalidResponse("Connection closed before response completed")
            }
            data.append(chunk)
            remaining -= chunk.count
        }
        return data
    }

    private func receiveChunk(maximumLength: Int, over connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximumLength)) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }
}

private final class ProjectServerEndpointAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [String: NWEndpoint] = [:]

    func record(_ endpoint: NWEndpoint) {
        lock.lock()
        endpoints[String(describing: endpoint)] = endpoint
        lock.unlock()
    }

    func snapshot() -> [NWEndpoint] {
        lock.lock()
        let snapshot = Array(endpoints.values)
        lock.unlock()
        return snapshot
    }
}

public typealias NovotroProjectServerClient = ProjectServerClient
