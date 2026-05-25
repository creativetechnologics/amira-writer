import Foundation
import Network
import ProjectKit

// MARK: - APIServer

/// Lightweight HTTP JSON API server using Network.framework (NWListener).
/// Listens on localhost only, dispatches requests to APIRouter on @MainActor.
/// All mutable state (connections dict) is confined to `queue`.
@available(macOS 26.0, *)
final class APIServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.amira.score.api", qos: .userInitiated)
    /// Guarded by `queue` — only access from queue or via queue.sync.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Per-connection receive buffers for handling TCP fragmentation.
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private let router: APIRouter
    private(set) var port: UInt16

    /// Called after each request is processed: (method, path, status, responseSummary).
    var logHandler: (@Sendable (String, String, Int, String) -> Void)?

    @MainActor
    init(store: ScoreStore, port: UInt16 = 19847) throws {
        self.port = port
        self.router = APIRouter(store: store)

        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "APIServer", code: 1,
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

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener.port?.rawValue {
                    self?.port = port
                    NSLog("[APIServer] Listening on localhost:%d", port)
                }
            case .failed(let error):
                NSLog("[APIServer] Listener failed: %@", error.localizedDescription)
                self?.listener.cancel()
            case .cancelled:
                NSLog("[APIServer] Listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    /// Stop the server. Safe to call from any thread (including `queue` itself).
    func stop() {
        listener.cancel()
        // Use async to avoid deadlock if called from within `queue`
        // (e.g. from a stateUpdateHandler callback).
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections.values {
                conn.cancel()
            }
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
        }
    }

    // MARK: - Connection Handling

    /// Called on `queue` (from newConnectionHandler).
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

    /// Remove connection from tracking (idempotent). Called on `queue`.
    private func cleanupConnection(_ id: ObjectIdentifier) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        receiveBuffers.removeValue(forKey: id)
        conn.cancel()
    }

    /// Issue a receive call to accumulate data until a complete HTTP request is available.
    private func receiveMore(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // If this connection was already removed (e.g. by stop()), bail out.
            guard self.connections[id] != nil else { return }

            if let data, !data.isEmpty {
                self.receiveBuffers[id, default: Data()].append(data)
            }

            let buffer = self.receiveBuffers[id] ?? Data()

            // Check if we have a complete HTTP request
            if let request = HTTPRequest.parse(buffer) {
                self.receiveBuffers[id] = nil
                self.processRequest(request, connection: connection, id: id)
            } else if isComplete || error != nil {
                // Connection closed or errored before we got a complete request
                self.cleanupConnection(id)
            } else if buffer.count > 4_194_304 {
                // Safety: reject requests > 4 MB
                self.sendResponse(HTTPResponse.error(413, "Request too large"), on: connection, id: id)
            } else {
                // Need more data — keep receiving
                self.receiveMore(on: connection, id: id)
            }
        }
    }

    private func processRequest(_ request: HTTPRequest, connection: NWConnection, id: ObjectIdentifier) {
        Task { @MainActor [weak self, router] in
            let response = await router.handle(request)
            guard let self else {
                // Server was deallocated during request handling — clean up the connection
                connection.cancel()
                return
            }
            // Log the request/response
            let summary = String(response.body.prefix(120))
            self.logHandler?(request.method, request.path, response.status, summary)
            self.queue.async { [weak self] in
                self?.sendResponse(response, on: connection, id: id)
            }
        }
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection, id: ObjectIdentifier) {
        let httpData = response.serialize()
        connection.send(content: httpData, completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[APIServer] Send error: %@", error.localizedDescription)
            }
            self?.cleanupConnection(id)
        })
    }
}

// MARK: - HTTPRequest

struct HTTPRequest {
    var method: String
    var path: String
    var queryParams: [String: String]
    var headers: [String: String]
    var body: Data?

    /// Parse raw HTTP data. Returns nil if the data does not yet contain a complete request.
    static func parse(_ data: Data) -> HTTPRequest? {
        // Find \r\n\r\n boundary in raw bytes to split headers from body
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let separatorRange = data.range(of: Data(separator)) else {
            return nil  // Headers not yet complete
        }

        let headerData = data[data.startIndex..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line: "GET /path HTTP/1.1"
        let requestLine = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }

        let method = String(requestLine[0])
        let rawPath = String(requestLine[1])

        // Split path and query string
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

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                let key = String(headerParts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body using Content-Length if available
        let bodyStart = separatorRange.upperBound
        let availableBody = data[bodyStart...]

        if let contentLengthStr = headers["content-length"],
           let contentLength = Int(contentLengthStr),
           contentLength >= 0 {
            guard availableBody.count >= contentLength else {
                return nil  // Body not yet fully received
            }
            let body = availableBody.prefix(contentLength)
            return HTTPRequest(method: method, path: path, queryParams: queryParams, headers: headers,
                             body: body.isEmpty ? nil : Data(body))
        } else {
            // No Content-Length — treat whatever is after headers as the body
            let body = Data(availableBody)
            return HTTPRequest(method: method, path: path, queryParams: queryParams, headers: headers,
                             body: body.isEmpty ? nil : body)
        }
    }

    /// Decode the JSON body into a Decodable type.
    func decodeBody<T: Decodable>(_ type: T.Type) -> T? {
        guard let body else { return nil }
        return try? JSONCoders.makeDecoder().decode(type, from: body)
    }

    /// Decode body, returning a descriptive error message on failure.
    func decodeBodyWithError<T: Decodable>(_ type: T.Type) -> (value: T?, errorMessage: String?) {
        guard let body else { return (nil, "Empty request body") }
        do {
            return (try JSONCoders.makeDecoder().decode(type, from: body), nil)
        } catch let error as DecodingError {
            let msg: String
            switch error {
            case .keyNotFound(let key, _):
                msg = "Missing required field: '\(key.stringValue)'"
            case .typeMismatch(let expectedType, let ctx):
                let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
                msg = "Type mismatch at '\(path)': expected \(expectedType)"
            case .valueNotFound(let expectedType, let ctx):
                let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
                msg = "Null value at '\(path)': expected \(expectedType)"
            case .dataCorrupted(let ctx):
                msg = "Malformed JSON: \(ctx.debugDescription)"
            @unknown default:
                msg = "Decode error: \(error.localizedDescription)"
            }
            return (nil, msg)
        } catch {
            return (nil, "JSON parse error: \(error.localizedDescription)")
        }
    }

    /// Decode body with error reporting.
    func decodeBodyThrowing<T: Decodable>(_ type: T.Type) throws -> T {
        guard let body else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Empty request body"))
        }
        return try JSONCoders.makeDecoder().decode(type, from: body)
    }

    /// Parse body as raw JSON dictionary.
    func jsonBody() -> [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

// MARK: - HTTPResponse

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]
    var body: String

    static func ok(_ json: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: json)
    }

    static func ok<T: Encodable>(_ value: T) -> HTTPResponse {
        let encoder = JSONCoders.makeEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return HTTPResponse(status: 200, body: json)
        } catch {
            NSLog("[APIServer] Encoding error: %@", error.localizedDescription)
            return self.error(500, "Failed to encode response: \(error.localizedDescription)")
        }
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        // Use JSONEncoder to ensure proper escaping of all special characters
        let payload = ["error": message]
        if let data = try? JSONCoders.makeEncoder().encode(payload), let json = String(data: data, encoding: .utf8) {
            return HTTPResponse(status: status, body: json)
        }
        // Ultimate fallback — should never happen for a simple String dict
        return HTTPResponse(status: status, body: #"{"error":"internal error"}"#)
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
