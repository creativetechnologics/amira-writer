import Foundation
import Network

// MARK: - AnimateAPIServer
//
// Loopback HTTP JSON API server for Animate. Lets an external tool (e.g. a
// Claude / Codex CLI session) enqueue place image generations as if the user
// had clicked the UI button: results appear in the Gemini activity queue and
// are attached to the correct BackgroundPlate record.
//
// This is loopback-only (127.0.0.1) — the listener binds to the IPv4 loopback
// interface, so it is unreachable from any other machine. No auth is enforced
// beyond that boundary; anything already running on Gary's machine is trusted.
//
// Vendored `AnimateHTTPRequest` / `AnimateHTTPResponse` types mirror the ones
// in Score's APIServer.swift so we don't take a cross-package dependency.

@available(macOS 26.0, *)
final class AnimateAPIServer: @unchecked Sendable {

    /// Idempotent singleton. Prevents a second WindowGroup `.task` or a hot
    /// reload from spawning a duplicate listener on the same port.
    @MainActor
    static var shared: AnimateAPIServer?

    /// Optional hook the host (e.g. Opera shell / Animate bootstrap) sets so the
    /// API can eagerly hydrate the bound AnimateStore when a request arrives
    /// before any UI has triggered a project load. Returns once the load is
    /// complete (or has failed); the router polls `store.owpURL` afterwards.
    @MainActor
    static var projectActivator: (@MainActor () async -> Void)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.amira.animate.api", qos: .userInitiated)
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private let router: AnimateAPIRouter
    private(set) var port: UInt16

    var logHandler: (@Sendable (String, String, Int, String) -> Void)?

    @MainActor
    init(store: AnimateStore, port: UInt16 = 19849) throws {
        self.port = port
        self.router = AnimateAPIRouter(store: store)

        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "AnimateAPIServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: params)
    }

    deinit {
        listener.cancel()
        queue.async { [connections = self.connections] in
            for conn in connections.values { conn.cancel() }
        }
    }

    /// Starts the server. Idempotent at the shared-singleton level: if
    /// `shared` is already non-nil, callers should skip creating a new one.
    @MainActor
    static func startIfNeeded(store: AnimateStore, port: UInt16 = 19849) {
        guard shared == nil else { return }
        do {
            let server = try AnimateAPIServer(store: store, port: port)
            server.logHandler = { method, path, status, summary in
                NSLog("[AnimateAPI] %@ %@ -> %d %@", method, path, status, summary)
            }
            server.start()
            shared = server
        } catch {
            NSLog("[AnimateAPI] Failed to start: %@", error.localizedDescription)
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener.port?.rawValue {
                    self?.port = port
                    NSLog("[AnimateAPI] Listening on localhost:%d", port)
                }
            case .failed(let error):
                NSLog("[AnimateAPI] Listener failed: %@", error.localizedDescription)
                self?.listener.cancel()
            case .cancelled:
                NSLog("[AnimateAPI] Listener cancelled")
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.connections[id] != nil else { return }

            if let data, !data.isEmpty {
                self.receiveBuffers[id, default: Data()].append(data)
            }
            let buffer = self.receiveBuffers[id] ?? Data()

            if let request = AnimateHTTPRequest.parse(buffer) {
                self.receiveBuffers[id] = nil
                self.processRequest(request, connection: connection, id: id)
            } else if isComplete || error != nil {
                self.cleanupConnection(id)
            } else if buffer.count > 4_194_304 {
                self.sendResponse(AnimateHTTPResponse.error(413, "Request too large"),
                                  on: connection, id: id)
            } else {
                self.receiveMore(on: connection, id: id)
            }
        }
    }

    private func processRequest(_ request: AnimateHTTPRequest,
                                connection: NWConnection,
                                id: ObjectIdentifier) {
        Task { @MainActor [weak self, router] in
            let response = await router.handle(request)
            guard let self else {
                connection.cancel()
                return
            }
            let summary = String(response.body.prefix(120))
            self.logHandler?(request.method, request.path, response.status, summary)
            self.queue.async { [weak self] in
                self?.sendResponse(response, on: connection, id: id)
            }
        }
    }

    private func sendResponse(_ response: AnimateHTTPResponse,
                              on connection: NWConnection,
                              id: ObjectIdentifier) {
        let httpData = response.serialize()
        connection.send(content: httpData, completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[AnimateAPI] Send error: %@", error.localizedDescription)
            }
            self?.cleanupConnection(id)
        })
    }
}

// MARK: - AnimateAPIRouter

@available(macOS 26.0, *)
@MainActor
final class AnimateAPIRouter {
    private let store: AnimateStore

    init(store: AnimateStore) {
        self.store = store
    }

    func handle(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            // /health reports current state without forcing a load.
            return healthResponse()
        case ("GET", "/places"):
            await ensureProjectHydrated()
            return listPlacesResponse()
        case ("POST", "/places/generate"):
            await ensureProjectHydrated()
            return await generatePlaceResponse(request)
        default:
            return AnimateHTTPResponse.error(404, "Unknown route: \(request.method) \(request.path)")
        }
    }

    /// If the bound AnimateStore has no project loaded, invoke the host's
    /// `projectActivator` (if any) and poll briefly for the load to complete.
    /// No-op when a project is already loaded.
    private func ensureProjectHydrated() async {
        guard store.owpURL == nil else { return }
        guard let activator = AnimateAPIServer.projectActivator else { return }
        await activator()
        let deadline = Date().addingTimeInterval(45)
        while store.owpURL == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Routes

    private func healthResponse() -> AnimateHTTPResponse {
        let vertex = ImageGenBackendStore.currentVertexSettings()
        let payload: [String: Any] = [
            "ok": true,
            "project": store.owpURL?.lastPathComponent ?? NSNull(),
            "placesCount": store.backgrounds.count,
            "selectedGeminiModel": store.selectedGeminiModel.rawValue,
            "selectedGeminiModelDisplayName": store.selectedGeminiModel.displayName,
            "geminiAllowed": store.isGeminiAllowed(),
            "backend": ImageGenBackendStore.currentBackend().rawValue,
            "backendDisplayName": ImageGenBackendStore.currentBackend().displayName,
            "vertexProjectID": vertex.projectID,
            "vertexRegion": vertex.region
        ]
        return AnimateHTTPResponse.okJSON(payload)
    }

    private func listPlacesResponse() -> AnimateHTTPResponse {
        let payload = store.backgrounds.map { bg -> [String: Any] in
            [
                "id": bg.id.uuidString,
                "name": bg.name,
                "locationCategory": bg.locationCategory,
                "hasVisualBrief": !bg.visualBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "photorealImageCount": bg.imagePaths.count,
                "animatedImageCount": bg.animatedImagePaths.count
            ]
        }
        return AnimateHTTPResponse.okJSON(["places": payload])
    }

    private func generatePlaceResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let body = request.jsonBody() else {
            return .error(400, "Missing or malformed JSON body")
        }
        guard let identifier = (body["place"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            return .error(400, "'place' field is required (name or UUID)")
        }

        let workflowRaw = (body["workflow"] as? String) ?? "photorealistic"
        guard let workflow = PlaceWorkflowMode(rawValue: workflowRaw) else {
            return .error(400, "Invalid workflow: \(workflowRaw) (use 'photorealistic' or 'animated')")
        }

        let modelOverride: GeminiModel?
        if let modelRaw = body["model"] as? String, !modelRaw.isEmpty {
            switch modelRaw.lowercased() {
            case "flash", "nano-banana-2", "nano_banana_2", "nanobanana2":
                modelOverride = .flash
            case "pro", "nano-banana-pro", "nano_banana_pro", "nanobananapro":
                modelOverride = .pro
            default:
                return .error(400, "Invalid model: \(modelRaw) (use 'flash' or 'pro')")
            }
        } else {
            modelOverride = nil
        }

        let count = max(1, min(4, (body["count"] as? Int) ?? 1))

        let aspectRatioOverride = (body["aspectRatio"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageSizeOverride = (body["imageSize"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let referenceMode: AnimateStore.APIReferenceMode
        switch (body["referenceMode"] as? String)?.lowercased() {
        case "curated":
            referenceMode = .curated
        case nil, "", "default", "auto":
            referenceMode = .default
        case let other?:
            return .error(400, "Invalid referenceMode: \(other) (use 'default' or 'curated')")
        }

        do {
            let result = try await store.generatePlaceImageForAPI(
                placeIdentifier: identifier,
                workflow: workflow,
                model: modelOverride,
                count: count,
                aspectRatio: (aspectRatioOverride?.isEmpty == false) ? aspectRatioOverride : nil,
                imageSize: (imageSizeOverride?.isEmpty == false) ? imageSizeOverride : nil,
                referenceMode: referenceMode
            )
            let payload: [String: Any] = [
                "ok": true,
                "placeID": result.placeID.uuidString,
                "placeName": result.placeName,
                "workflow": workflow.rawValue,
                "model": result.model.rawValue,
                "modelDisplayName": result.model.displayName,
                "aspectRatio": result.aspectRatio,
                "imageSize": result.imageSize,
                "referenceMode": referenceMode.rawValue,
                "referenceCount": result.referenceCount,
                "referencePaths": result.referencePaths,
                "backend": ImageGenBackendStore.currentBackend().rawValue,
                "activityIDs": result.activityIDs.map(\.uuidString),
                "storedPaths": result.storedPaths
            ]
            return AnimateHTTPResponse.okJSON(payload)
        } catch let error as AnimateStore.APIGenerationError {
            return .error(error.status, error.message)
        } catch {
            return .error(500, "Generation failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - AnimateHTTPRequest

struct AnimateHTTPRequest {
    var method: String
    var path: String
    var queryParams: [String: String]
    var headers: [String: String]
    var body: Data?

    static func parse(_ data: Data) -> AnimateHTTPRequest? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let separatorRange = data.range(of: Data(separator)) else { return nil }

        let headerData = data[data.startIndex..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }

        let method = String(requestLine[0])
        let rawPath = String(requestLine[1])

        let pathParts = rawPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts[0])
        var queryParams: [String: String] = [:]
        if pathParts.count > 1 {
            let queryString = String(pathParts[1])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? String(kv[0])
                    let value = String(kv[1]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? String(kv[1])
                    queryParams[key] = value
                }
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                let key = String(headerParts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyStart = separatorRange.upperBound
        let availableBody = data[bodyStart...]

        if let contentLengthStr = headers["content-length"],
           let contentLength = Int(contentLengthStr), contentLength >= 0 {
            guard availableBody.count >= contentLength else { return nil }
            let body = availableBody.prefix(contentLength)
            return AnimateHTTPRequest(method: method, path: path, queryParams: queryParams,
                                      headers: headers,
                                      body: body.isEmpty ? nil : Data(body))
        } else {
            let body = Data(availableBody)
            return AnimateHTTPRequest(method: method, path: path, queryParams: queryParams,
                                      headers: headers,
                                      body: body.isEmpty ? nil : body)
        }
    }

    func jsonBody() -> [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

// MARK: - AnimateHTTPResponse

struct AnimateHTTPResponse {
    var status: Int
    var headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]
    var body: String

    static func okJSON(_ dict: [String: Any]) -> AnimateHTTPResponse {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return AnimateHTTPResponse(status: 200, body: json)
        }
        return AnimateHTTPResponse(status: 500, body: #"{"error":"failed to encode response"}"#)
    }

    static func error(_ status: Int, _ message: String) -> AnimateHTTPResponse {
        let payload = ["error": message]
        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            return AnimateHTTPResponse(status: status, body: json)
        }
        return AnimateHTTPResponse(status: status, body: #"{"error":"internal error"}"#)
    }

    func serialize() -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 413: statusText = "Payload Too Large"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(bodyData.count)"
        allHeaders["Access-Control-Allow-Origin"] = "http://127.0.0.1"
        allHeaders["Connection"] = "close"

        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = response.data(using: .utf8) ?? Data()
        data.append(bodyData)
        return data
    }
}
