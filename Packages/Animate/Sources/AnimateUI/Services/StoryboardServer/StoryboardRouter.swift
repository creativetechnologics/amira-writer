import Foundation
import ProjectKit

// MARK: - StoryboardRouter
//
// HTTP/1.1 router for the storyboard web API. Accepts a weak reference to
// AnimateWorkspaceController so the router never extends the controller's
// lifetime. All route handlers run on @MainActor (called from processRequest).

@available(macOS 26.0, *)
@MainActor
final class StoryboardRouter {

    private weak var workspace: AnimateWorkspaceController?
    private let diskStore = StoryboardStore()

    init(workspace: AnimateWorkspaceController) {
        self.workspace = workspace
    }

    func handle(_ request: SBHTTPRequest) async -> SBHTTPResponse {
        let method = request.method
        let path = request.path

        // Static asset routes
        if method == "GET" && (path == "/" || path.hasPrefix("/static/")) {
            if let (data, mime) = StoryboardAssets.serve(path: path) {
                return SBHTTPResponse(status: 200, contentType: mime, body: data)
            }
            return .notFound("Asset not found: \(path)")
        }

        // API routes
        switch (method, path) {
        case ("GET", "/api/project"):
            return projectResponse()
        case ("GET", "/api/shots"):
            return shotsResponse()
        case _ where method == "PUT" && path.hasPrefix("/api/shots/") && path.hasSuffix("/summary"):
            let shotIDStr = extractPathComponent(from: path, prefix: "/api/shots/", suffix: "/summary")
            return await putSummaryResponse(shotIDStr: shotIDStr, request: request)
        case _ where method == "GET" && path.hasPrefix("/api/storyboard/"):
            let parts = path.dropFirst("/api/storyboard/".count).split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return .badRequest("Malformed storyboard path") }
            return getStoryboardResponse(shotIDStr: String(parts[0]), frameStr: String(parts[1]))
        case _ where method == "PUT" && path.hasPrefix("/api/storyboard/"):
            let parts = path.dropFirst("/api/storyboard/".count).split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return .badRequest("Malformed storyboard path") }
            return await putStoryboardResponse(shotIDStr: String(parts[0]), frameStr: String(parts[1]), request: request)
        case ("OPTIONS", _):
            return SBHTTPResponse(status: 204, contentType: "text/plain", body: Data())
        default:
            return .notFound("Unknown route: \(method) \(path)")
        }
    }

    // MARK: - Route Handlers

    private func projectResponse() -> SBHTTPResponse {
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        let projectName = root.lastPathComponent
        let projectID = projectName
        return .okJSON(["name": projectName, "id": projectID])
    }

    private func shotsResponse() -> SBHTTPResponse {
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        let scenes = ws.store.scenes
        var payload: [[String: Any]] = []
        for (sceneOrder, scene) in scenes.enumerated() {
            for (shotOrder, shot) in scene.shots.enumerated() {
                let has = diskStore.hasFrames(projectRoot: root, sceneID: scene.id, shotID: shot.id)
                let entry: [String: Any] = [
                    "sceneId": scene.id.uuidString,
                    "sceneName": scene.name,
                    "sceneOrder": sceneOrder,
                    "shotId": shot.id.uuidString,
                    "shotName": shot.name,
                    "shotOrder": shotOrder,
                    "startFrame": shot.startFrame,
                    "summary": shot.notes,
                    "hasFrames": has
                ]
                payload.append(entry)
            }
        }
        payload.sort {
            let s0 = $0["sceneOrder"] as? Int ?? 0
            let s1 = $1["sceneOrder"] as? Int ?? 0
            if s0 != s1 { return s0 < s1 }
            return ($0["shotOrder"] as? Int ?? 0) < ($1["shotOrder"] as? Int ?? 0)
        }
        return .okJSONArray(payload)
    }

    private func putSummaryResponse(shotIDStr: String?, request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let shotIDStr, let shotID = UUID(uuidString: shotIDStr) else {
            return .badRequest("Invalid shotId")
        }
        guard let body = request.jsonBody(), let summary = body["summary"] as? String else {
            return .badRequest("Missing 'summary' field in JSON body")
        }
        guard let ws = workspace else { return .serviceUnavailable("no project open") }

        let found = ws.store.updateShotNotes(shotID: shotID, notes: summary)
        guard found else { return .notFound("Shot not found: \(shotIDStr)") }
        return SBHTTPResponse(status: 204, contentType: "application/json", body: Data())
    }

    private func getStoryboardResponse(shotIDStr: String, frameStr: String) -> SBHTTPResponse {
        guard let frame = StoryboardFrame(rawValue: frameStr) else {
            return .badRequest("Invalid frame: \(frameStr). Must be begin, middle, or end.")
        }
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        guard let (sceneID, _) = ws.store.findShot(by: UUID(uuidString: shotIDStr)) else {
            return .notFound("Shot not found: \(shotIDStr)")
        }
        guard let shotID = UUID(uuidString: shotIDStr) else {
            return .badRequest("Invalid shotId")
        }
        guard let data = diskStore.read(projectRoot: root, sceneID: sceneID, shotID: shotID, frame: frame) else {
            return .notFound("No \(frameStr) frame for shot \(shotIDStr)")
        }
        return SBHTTPResponse(status: 200, contentType: "image/png", body: data)
    }

    private func putStoryboardResponse(shotIDStr: String, frameStr: String, request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let frame = StoryboardFrame(rawValue: frameStr) else {
            return .badRequest("Invalid frame: \(frameStr). Must be begin, middle, or end.")
        }
        guard let shotID = UUID(uuidString: shotIDStr) else {
            return .badRequest("Invalid shotId")
        }
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        guard let (sceneID, _) = ws.store.findShot(by: shotID) else {
            return .notFound("Shot not found: \(shotIDStr)")
        }
        guard let body = request.body, !body.isEmpty else {
            return .badRequest("Empty request body")
        }
        do {
            try diskStore.write(data: body, projectRoot: root, sceneID: sceneID, shotID: shotID, frame: frame)
        } catch {
            return SBHTTPResponse.error(500, "Failed to save image: \(error.localizedDescription)")
        }
        return SBHTTPResponse(status: 204, contentType: "application/json", body: Data())
    }

    // MARK: - Helpers

    private func projectRoot(_ ws: AnimateWorkspaceController) -> URL? {
        guard let path = ws.activeProjectPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func extractPathComponent(from path: String, prefix: String, suffix: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(path[start..<end])
    }
}

// MARK: - SBHTTPRequest

struct SBHTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?

    static func parse(_ data: Data) -> SBHTTPRequest? {
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
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyStart = separatorRange.upperBound
        let available = data[bodyStart...]

        let body: Data?
        if let cl = headers["content-length"], let len = Int(cl), len > 0 {
            guard available.count >= len else { return nil }
            body = Data(available.prefix(len))
        } else {
            body = available.isEmpty ? nil : Data(available)
        }

        return SBHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    func jsonBody() -> [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

// MARK: - SBHTTPResponse

struct SBHTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func okJSON(_ dict: [String: Any]) -> SBHTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return error(500, "encode error")
        }
        return SBHTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data)
    }

    static func okJSONArray(_ array: [[String: Any]]) -> SBHTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: []) else {
            return error(500, "encode error")
        }
        return SBHTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data)
    }

    static func notFound(_ message: String) -> SBHTTPResponse { error(404, message) }
    static func badRequest(_ message: String) -> SBHTTPResponse { error(400, message) }
    static func serviceUnavailable(_ message: String) -> SBHTTPResponse { error(503, message) }

    static func error(_ status: Int, _ message: String) -> SBHTTPResponse {
        let dict = ["error": message]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return SBHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    func serialize() -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 413: statusText = "Payload Too Large"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default:  statusText = "Error"
        }

        var headers = [
            "Content-Type": contentType,
            "Content-Length": "\(body.count)",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, PUT, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Connection": "close"
        ]
        if status == 204 {
            headers.removeValue(forKey: "Content-Type")
            headers["Content-Length"] = "0"
        }

        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = response.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }
}
