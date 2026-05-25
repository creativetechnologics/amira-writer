import Foundation

// MARK: - Amira Score MCP Bridge
//
// A JSON-RPC 2.0 stdio bridge that translates MCP protocol messages
// into HTTP calls against the Amira Score embedded API server.
//
// Usage: amira-score-mcp [--port 19847]

// MARK: - Configuration

var apiPort: UInt16 = 19847

// Parse --port argument
let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--port"), idx + 1 < args.count, let port = UInt16(args[idx + 1]) {
    apiPort = port
}

let baseURL = "http://localhost:\(apiPort)"

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable {
    var jsonrpc: String
    var id: AnyCodableValue?
    var method: String
    var params: AnyCodableValue?
}

struct JSONRPCResponse: Codable {
    var jsonrpc: String = "2.0"
    var id: AnyCodableValue?
    var result: AnyCodableValue?
    var error: JSONRPCError?
}

struct JSONRPCError: Codable {
    var code: Int
    var message: String
    var data: AnyCodableValue?
}

// MARK: - AnyCodableValue (flexible JSON value wrapper)

enum AnyCodableValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([AnyCodableValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: AnyCodableValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }

    var objectValue: [String: AnyCodableValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [AnyCodableValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Convert to a JSON-compatible Any for JSONSerialization
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    static func from(_ any: Any) -> AnyCodableValue {
        if any is NSNull { return .null }
        // Check CFBoolean/NSNumber boolean before Int/Double to avoid NSNumber type ambiguity.
        // NSNumber wrapping a Bool also matches `as? Int`, so we must check Bool first.
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            if let i = any as? Int, Double(i) == n.doubleValue { return .int(i) }
            if let d = any as? Double { return .double(d) }
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map { from($0) }) }
        if let o = any as? [String: Any] { return .object(o.mapValues { from($0) }) }
        return .null
    }
}

// MARK: - MCP Tool Definitions

struct MCPToolDefinition: Sendable {
    var name: String
    var description: String
    var inputSchema: AnyCodableValue
}

let mcpTools: [MCPToolDefinition] = [
    MCPToolDefinition(
        name: "get_status",
        description: "Get current app status, project info, and selected song",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "list_songs",
        description: "List all songs in the current project with metadata (note count, track count, etc.)",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "get_notes",
        description: "Get all MIDI notes for the selected song, with optional track/channel filters",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "trackIndex": .object(["type": .string("integer"), "description": .string("Filter by track index")]),
                "channel": .object(["type": .string("integer"), "description": .string("Filter by MIDI channel")]),
            ]),
        ])
    ),
    MCPToolDefinition(
        name: "edit_notes",
        description: "Add, delete, or update MIDI notes. Specify exactly one of: add, delete, update, or replaceAll",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "add": .object([
                    "type": .string("array"),
                    "description": .string("Notes to add. Each: {trackIndex, channel, pitch, velocity, startTick, duration}"),
                    "items": .object(["type": .string("object")]),
                ]),
                "delete": .object([
                    "type": .string("array"),
                    "description": .string("Note UUIDs to delete"),
                    "items": .object(["type": .string("string")]),
                ]),
                "update": .object([
                    "type": .string("array"),
                    "description": .string("Partial note updates. Each must have id, plus optional: pitch, velocity, startTick, duration, muted"),
                    "items": .object(["type": .string("object")]),
                ]),
                "replaceAll": .object([
                    "type": .string("array"),
                    "description": .string("Replace ALL notes. Each: {trackIndex, channel, pitch, velocity, startTick, duration}"),
                    "items": .object(["type": .string("object")]),
                ]),
            ]),
        ])
    ),
    MCPToolDefinition(
        name: "get_instruments",
        description: "Get current instrument mappings and channel key map",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "set_instrument",
        description: "Set instrument properties for a mapping key (sf2Path, program, bank, gain, mute, etc.)",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "mappingKey": .object(["type": .string("string"), "description": .string("The instrument mapping key")]),
                "displayName": .object(["type": .string("string")]),
                "sf2Path": .object(["type": .string("string"), "description": .string("Path to SF2 soundfont file")]),
                "bankMSB": .object(["type": .string("integer")]),
                "bankLSB": .object(["type": .string("integer")]),
                "program": .object(["type": .string("integer"), "description": .string("MIDI program 0-127")]),
                "gainDB": .object(["type": .string("number")]),
                "muted": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("mappingKey")]),
        ])
    ),
    MCPToolDefinition(
        name: "export_wav",
        description: "Export the selected song (or a tick range) to a WAV file",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "outputPath": .object(["type": .string("string"), "description": .string("Absolute path for the output WAV file")]),
                "startTick": .object(["type": .string("integer"), "description": .string("Start tick (default: 0)")]),
                "endTick": .object(["type": .string("integer"), "description": .string("End tick (default: end of song)")]),
                "overrideSF2Path": .object(["type": .string("string"), "description": .string("Use this SF2 for all instruments")]),
            ]),
            "required": .array([.string("outputPath")]),
        ])
    ),
    MCPToolDefinition(
        name: "snapshot_version",
        description: "Create a version snapshot of the current song state",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "label": .object(["type": .string("string"), "description": .string("Optional label for the snapshot")]),
            ]),
        ])
    ),
    MCPToolDefinition(
        name: "rollback_version",
        description: "Rollback to a previous version by its ID",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "versionID": .object(["type": .string("string"), "description": .string("UUID of the version to restore")]),
            ]),
            "required": .array([.string("versionID")]),
        ])
    ),
    MCPToolDefinition(
        name: "get_versions",
        description: "List version history for the selected song",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "playback_control",
        description: "Control playback: play, stop, or seek",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"), "enum": .array([.string("play"), .string("stop"), .string("seek")]), "description": .string("Playback action")]),
                "tick": .object(["type": .string("integer"), "description": .string("Tick position for play/seek")]),
            ]),
            "required": .array([.string("action")]),
        ])
    ),
    MCPToolDefinition(
        name: "get_tracks",
        description: "Get track list with names, channels, and note counts",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "get_tempo",
        description: "Get tempo map, time signatures, key signatures, and song length",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "select_song",
        description: "Select a song by index or relative path",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "index": .object(["type": .string("integer"), "description": .string("Song index (0-based)")]),
                "relativePath": .object(["type": .string("string"), "description": .string("Relative path of the song")]),
            ]),
        ])
    ),
    MCPToolDefinition(
        name: "undo",
        description: "Undo the last edit operation",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "redo",
        description: "Redo the last undone operation",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "quantize_notes",
        description: "Quantize selected notes to the current grid",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "save_project",
        description: "Save the current project to disk",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "set_mixer",
        description: "Control mixer: mute, solo, pan, or master volume",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"), "enum": .array([.string("mute"), .string("solo"), .string("clear_solo"), .string("pan"), .string("master_volume")]), "description": .string("Mixer action")]),
                "trackIndex": .object(["type": .string("integer"), "description": .string("Track index (for mute/solo)")]),
                "mappingKey": .object(["type": .string("string"), "description": .string("Mapping key (for pan)")]),
                "value": .object(["type": .string("number"), "description": .string("Pan (-1 to 1) or volume (0 to 1)")]),
            ]),
            "required": .array([.string("action")]),
        ])
    ),
    MCPToolDefinition(
        name: "rename_track",
        description: "Rename a track by index",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "trackIndex": .object(["type": .string("integer"), "description": .string("Track index (0-based)")]),
                "name": .object(["type": .string("string"), "description": .string("New track name")]),
            ]),
            "required": .array([.string("trackIndex"), .string("name")]),
        ])
    ),
    MCPToolDefinition(
        name: "set_tempo",
        description: "Set tempo, time signatures, and key signatures",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "initialTempoBPM": .object(["type": .string("number"), "description": .string("Initial tempo in BPM (10-500)")]),
                "ticksPerQuarter": .object(["type": .string("integer"), "description": .string("Ticks per quarter note")]),
                "tempoEvents": .object(["type": .string("array"), "description": .string("Array of {tick, bpm} tempo events")]),
                "timeSignatures": .object(["type": .string("array"), "description": .string("Array of {tick, numerator, denominator} events")]),
                "keySignatures": .object(["type": .string("array"), "description": .string("Array of {tick, sharpsFlats, isMinor} events")]),
            ]),
        ])
    ),
    MCPToolDefinition(
        name: "get_lyrics",
        description: "Get lyric cues, alignments, and libretto text for the selected song",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "get_markers",
        description: "Get mix markers (rehearsal marks, section labels) for the selected song",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "continuous_play",
        description: "Get or set continuous playback mode (auto-advance to next song). Omit enabled to query current state.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "enabled": .object(["type": .string("boolean"), "description": .string("Set true/false to enable/disable. Omit to query current state.")]),
            ]),
        ])
    ),
    MCPToolDefinition(
        name: "loop_playback",
        description: "Get or set loop playback mode. Omit enabled to query current state.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "enabled": .object(["type": .string("boolean"), "description": .string("Set true/false to enable/disable. Omit to query current state.")]),
            ]),
        ])
    ),
]

// MARK: - HTTP Client

func httpRequest(method: String, path: String, body: Data? = nil) -> (statusCode: Int, data: Data)? {
    let urlString = "\(baseURL)\(path)"
    guard let url = URL(string: urlString) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 120

    let semaphore = DispatchSemaphore(value: 0)
    // Thread-safe box: URLSession callback writes on its delegate queue,
    // main thread reads after semaphore or timeout.
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _data: Data?
        private var _status: Int?
        var data: Data? { lock.withLock { _data } }
        var status: Int? { lock.withLock { _status } }
        func set(data: Data?, status: Int?) {
            lock.withLock { _data = data; _status = status }
        }
    }
    let box = ResultBox()

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        box.set(data: data, status: statusCode)
        semaphore.signal()
    }
    task.resume()
    let waitResult = semaphore.wait(timeout: .now() + 120)
    if waitResult == .timedOut {
        task.cancel()
    }

    guard let data = box.data, let status = box.status else { return nil }
    return (status, data)
}

func httpGET(_ path: String) -> (Int, Data)? {
    httpRequest(method: "GET", path: path)
}

func httpPOST(_ path: String, json: [String: Any]? = nil) -> (Int, Data)? {
    let body: Data?
    if let json {
        guard let serialized = try? JSONSerialization.data(withJSONObject: json) else {
            return nil  // Propagate as connection failure so callers return isError: true
        }
        body = serialized
    } else {
        body = nil
    }
    return httpRequest(method: "POST", path: path, body: body)
}

// MARK: - Tool Handlers

/// Result from a tool call, carrying both the response data and whether it's an error.
struct ToolCallResult {
    var value: AnyCodableValue
    var isError: Bool
}

func handleToolCall(name: String, arguments: [String: AnyCodableValue]?) -> ToolCallResult {
    let args = arguments ?? [:]

    switch name {
    case "get_status":
        guard let (status, data) = httpGET("/api/status") else { return .init(value: errorResult("Failed to connect to Novotro Score"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "list_songs":
        guard let (status, data) = httpGET("/api/songs") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "get_notes":
        var path = "/api/song/notes"
        var queryParts: [String] = []
        if let t = args["trackIndex"]?.intValue { queryParts.append("trackIndex=\(t)") }
        if let c = args["channel"]?.intValue { queryParts.append("channel=\(c)") }
        if !queryParts.isEmpty { path += "?" + queryParts.joined(separator: "&") }
        guard let (status, data) = httpGET(path) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "edit_notes":
        // Ensure exactly one operation is specified
        let opKeys: [String] = ["add", "delete", "update", "replaceAll"]
        let providedOps = opKeys.filter { args[$0] != nil }
        if providedOps.count > 1 {
            return .init(value: errorResult("Specify exactly one of: add, delete, update, or replaceAll. Got: \(providedOps.joined(separator: ", "))"), isError: true)
        }
        if let addNotes = args["add"]?.arrayValue {
            let notes = addNotes.map { $0.anyValue }
            let body: [String: Any] = ["notes": notes]
            guard let (status, data) = httpPOST("/api/song/notes/add", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        }
        if let deleteIDs = args["delete"]?.arrayValue {
            let ids = deleteIDs.compactMap { $0.stringValue }
            let body: [String: Any] = ["noteIDs": ids]
            guard let (status, data) = httpPOST("/api/song/notes/delete", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        }
        if let updates = args["update"]?.arrayValue {
            let patches = updates.map { $0.anyValue }
            let body: [String: Any] = ["updates": patches]
            guard let (status, data) = httpPOST("/api/song/notes/update", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        }
        if let replaceAll = args["replaceAll"]?.arrayValue {
            let notes = replaceAll.map { $0.anyValue }
            let body: [String: Any] = ["notes": notes]
            guard let (status, data) = httpPOST("/api/song/notes/replace-all", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        }
        return .init(value: errorResult("Specify one of: add, delete, update, or replaceAll"), isError: true)

    case "get_instruments":
        guard let (status, data) = httpGET("/api/song/instruments") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "set_instrument":
        let body = args.mapValues { $0.anyValue }
        guard let (status, data) = httpPOST("/api/song/instruments/set", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "export_wav":
        let body = args.mapValues { $0.anyValue }
        guard let (status, data) = httpPOST("/api/export/wav", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "snapshot_version":
        let body = args.mapValues { $0.anyValue }
        guard let (status, data) = httpPOST("/api/song/versions/snapshot", json: body.isEmpty ? nil : body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "rollback_version":
        let body = args.mapValues { $0.anyValue }
        guard let (status, data) = httpPOST("/api/song/versions/rollback", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "get_versions":
        guard let (status, data) = httpGET("/api/song/versions") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "playback_control":
        guard let action = args["action"]?.stringValue else { return .init(value: errorResult("Missing action"), isError: true) }
        switch action {
        case "play":
            var body: [String: Any]? = nil
            if let tick = args["tick"]?.intValue { body = ["startTick": tick] }
            guard let (status, data) = httpPOST("/api/playback/play", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        case "stop":
            guard let (status, data) = httpPOST("/api/playback/stop") else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        case "seek":
            guard let tick = args["tick"]?.intValue else { return .init(value: errorResult("Missing tick for seek"), isError: true) }
            guard let (status, data) = httpPOST("/api/playback/seek", json: ["tick": tick]) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        default:
            return .init(value: errorResult("Unknown action: \(action)"), isError: true)
        }

    case "get_tracks":
        guard let (status, data) = httpGET("/api/song/tracks") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "get_tempo":
        guard let (status, data) = httpGET("/api/song/tempo") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "select_song":
        let body = args.mapValues { $0.anyValue }
        guard let (status, data) = httpPOST("/api/song/select", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "undo":
        guard let (status, data) = httpPOST("/api/song/undo") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "redo":
        guard let (status, data) = httpPOST("/api/song/redo") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "quantize_notes":
        guard let (status, data) = httpPOST("/api/song/notes/quantize") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "save_project":
        guard let (status, data) = httpPOST("/api/project/save") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "rename_track":
        let body = args.mapValues { $0.anyValue }
        guard let (status, data) = httpPOST("/api/song/tracks/rename", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "set_tempo":
        let body = args.mapValues { $0.anyValue }
        guard let (status, data) = httpPOST("/api/song/tempo/set", json: body) else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "get_lyrics":
        guard let (status, data) = httpGET("/api/song/lyrics") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "get_markers":
        guard let (status, data) = httpGET("/api/song/markers") else { return .init(value: errorResult("Failed to connect"), isError: true) }
        return .init(value: parseJSON(data), isError: status >= 400)

    case "continuous_play":
        if let enabled = args["enabled"] {
            guard let (status, data) = httpPOST("/api/playback/continuous-play", json: ["enabled": enabled.anyValue]) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        } else {
            guard let (status, data) = httpGET("/api/playback/continuous-play") else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        }

    case "loop_playback":
        if let enabled = args["enabled"] {
            guard let (status, data) = httpPOST("/api/playback/loop", json: ["enabled": enabled.anyValue]) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        } else {
            guard let (status, data) = httpGET("/api/playback/loop") else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        }

    case "set_mixer":
        guard let action = args["action"]?.stringValue else { return .init(value: errorResult("Missing action"), isError: true) }
        switch action {
        case "mute":
            guard let trackIndex = args["trackIndex"]?.intValue else { return .init(value: errorResult("Missing trackIndex"), isError: true) }
            guard let (status, data) = httpPOST("/api/song/tracks/mute", json: ["trackIndex": trackIndex]) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        case "solo":
            guard let trackIndex = args["trackIndex"]?.intValue else { return .init(value: errorResult("Missing trackIndex"), isError: true) }
            guard let (status, data) = httpPOST("/api/song/tracks/solo", json: ["trackIndex": trackIndex]) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        case "clear_solo":
            guard let (status, data) = httpPOST("/api/song/tracks/clear-solo") else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        case "pan":
            guard let key = args["mappingKey"]?.stringValue else { return .init(value: errorResult("Missing mappingKey"), isError: true) }
            guard let val = args["value"]?.doubleValue else { return .init(value: errorResult("Missing value"), isError: true) }
            guard let (status, data) = httpPOST("/api/song/tracks/pan", json: ["mappingKey": key, "pan": val]) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        case "master_volume":
            guard let vol = args["value"]?.doubleValue else { return .init(value: errorResult("Missing value"), isError: true) }
            guard let (status, data) = httpPOST("/api/playback/volume", json: ["volume": vol]) else { return .init(value: errorResult("Failed to connect"), isError: true) }
            return .init(value: parseJSON(data), isError: status >= 400)
        default:
            return .init(value: errorResult("Unknown mixer action: \(action)"), isError: true)
        }

    default:
        return .init(value: errorResult("Unknown tool: \(name)"), isError: true)
    }
}

func parseJSON(_ data: Data) -> AnyCodableValue {
    guard let obj = try? JSONSerialization.jsonObject(with: data) else {
        return .string(String(data: data, encoding: .utf8) ?? "")
    }
    return AnyCodableValue.from(obj)
}

func errorResult(_ message: String) -> AnyCodableValue {
    .object(["error": .string(message)])
}

// MARK: - MCP Protocol Handling

func handleMCPRequest(_ request: JSONRPCRequest) -> JSONRPCResponse {
    switch request.method {
    case "initialize":
        return JSONRPCResponse(
            id: request.id,
            result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("amira-score"),
                    "version": .string("1.0.0"),
                ]),
            ])
        )

    case "tools/list":
        let toolDefs: [AnyCodableValue] = mcpTools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ])
        }
        return JSONRPCResponse(
            id: request.id,
            result: .object(["tools": .array(toolDefs)])
        )

    case "tools/call":
        guard let params = request.params?.objectValue,
              let toolName = params["name"]?.stringValue else {
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError(code: -32602, message: "Missing tool name")
            )
        }
        let arguments = params["arguments"]?.objectValue
        let callResult = handleToolCall(name: toolName, arguments: arguments)

        // Format as MCP content response
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let textContent: String
        if let data = try? encoder.encode(callResult.value), let str = String(data: data, encoding: .utf8) {
            textContent = str
        } else {
            textContent = "{}"
        }

        return JSONRPCResponse(
            id: request.id,
            result: .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(textContent),
                    ])
                ]),
                "isError": .bool(callResult.isError),
            ])
        )

    case "ping":
        return JSONRPCResponse(id: request.id, result: .object([:]))

    default:
        return JSONRPCResponse(
            id: request.id,
            error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)")
        )
    }
}

// MARK: - Main Loop

func sendResponse(_ response: JSONRPCResponse) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let outputData: Data
    if let data = try? encoder.encode(response),
       let json = String(data: data, encoding: .utf8),
       let encoded = (json + "\n").data(using: .utf8) {
        outputData = encoded
    } else {
        // Fallback: send an error so the client doesn't hang waiting for a response
        let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal encoding error"}}"# + "\n"
        outputData = fallback.data(using: .utf8)!
    }

    // Write safely — if stdout is closed (SIGPIPE), just exit cleanly
    do {
        try FileHandle.standardOutput.write(contentsOf: outputData)
    } catch {
        exit(0)
    }
}

func main() {
    // Ignore SIGPIPE so broken pipe gives an error instead of crashing
    signal(SIGPIPE, SIG_IGN)

    // Read JSON-RPC messages line by line from stdin
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        guard let data = trimmed.data(using: .utf8) else { continue }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            // Try to extract an ID even from malformed requests
            let errorResp = JSONRPCResponse(
                id: nil,
                error: JSONRPCError(code: -32700, message: "Parse error")
            )
            sendResponse(errorResp)
            continue
        }

        // Skip notifications (no id) — JSON-RPC 2.0 notifications require no response
        if request.method.hasPrefix("notifications/") && request.id == nil {
            continue
        }

        let response = handleMCPRequest(request)
        sendResponse(response)
    }
}

main()
