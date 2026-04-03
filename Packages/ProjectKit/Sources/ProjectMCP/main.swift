import Foundation
import Network
import ProjectKit

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
}

// MARK: - AnyCodableValue

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
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodableValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var objectValue: [String: AnyCodableValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var object: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.object)
        case let .object(values):
            return values.mapValues(\.object)
        }
    }

    static func from(_ any: Any) -> AnyCodableValue {
        if any is NSNull {
            return .null
        }
        if let value = any as? Bool {
            return .bool(value)
        }
        if let value = any as? Int {
            return .int(value)
        }
        if let value = any as? Double {
            return .double(value)
        }
        if let value = any as? String {
            return .string(value)
        }
        if let values = any as? [Any] {
            return .array(values.map(from(_:)))
        }
        if let values = any as? [String: Any] {
            return .object(values.mapValues(from(_:)))
        }
        return .null
    }
}

// MARK: - Tool Definitions

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: AnyCodableValue
}

let mcpTools: [MCPToolDefinition] = [
    MCPToolDefinition(
        name: "service_ping",
        description: "Verify connectivity and authentication against the project service.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "service_info",
        description: "Fetch service metadata and supported operations.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "service_mcp_tools",
        description: "List MCP tools surfaced by the service.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "service_endpoints",
        description: "List candidate service endpoints visible to this MCP bridge.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
    MCPToolDefinition(
        name: "service_list_projects",
        description: "List managed projects registered on the service.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    ),
]

// MARK: - MCP Helpers

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

func handleMCPRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse {
    guard request.jsonrpc == "2.0" else {
        return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32600, message: "Invalid JSON-RPC version"))
    }

    switch request.method {
    case "initialize":
        return JSONRPCResponse(
            id: request.id,
            result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("project-service"),
                    "version": .string("1.0.0"),
                ]),
            ])
        )

    case "tools/list":
        let tools = mcpTools.map {
            AnyCodableValue.object([
                "name": .string($0.name),
                "description": .string($0.description),
                "inputSchema": $0.inputSchema,
            ])
        }
        return JSONRPCResponse(id: request.id, result: .object(["tools": .array(tools)]))

    case "tools/call":
        guard let params = request.params?.objectValue else {
            return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32602, message: "Missing params"))
        }
        guard let toolName = params["name"]?.stringValue else {
            return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32602, message: "Missing tool name"))
        }

        do {
            let content = try await executeMCPTool(named: toolName)
            return JSONRPCResponse(
                id: request.id,
                result: .object([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(content),
                        ])
                    ]),
                    "isError": .bool(false),
                ])
            )
        } catch {
            return JSONRPCResponse(
                id: request.id,
                result: .object([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(error.localizedDescription),
                        ])
                    ]),
                    "isError": .bool(true),
                ])
            )
        }

    case "ping":
        return JSONRPCResponse(id: request.id, result: .object([:]))

    default:
        return JSONRPCResponse(
            id: request.id,
            error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)")
        )
    }
}

func executeMCPTool(named name: String) async throws -> String {
    let client = try await ProjectServerClient.discover()

    switch name {
    case "service_ping":
        try await client.ping()
        return #"{\"status\":\"ok\",\"message\":\"pong\"}"#

    case "service_info":
        let info = try await client.serviceInfo()
        let payload = (try? jsonEncoder.encode(info)) ?? Data(#"{}"#.utf8)
        return String(data: payload, encoding: .utf8) ?? "{}"

    case "service_mcp_tools":
        let tools = try await client.mcpTools()
        let payload = (try? jsonEncoder.encode(tools)) ?? Data("[]".utf8)
        return String(data: payload, encoding: .utf8) ?? "[]"

    case "service_endpoints":
        let endpointPayload = try? jsonEncoder.encode(activeServiceEndpoints())
        return String(data: endpointPayload ?? Data("[]".utf8), encoding: .utf8) ?? "[]"

    case "service_list_projects":
        let projects = try await client.listProjects()
        let payload = (try? jsonEncoder.encode(projects)) ?? Data("[]".utf8)
        return String(data: payload, encoding: .utf8) ?? "[]"

    default:
        throw NSError(
            domain: "ProjectMCPBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"]
        )
    }
}

func activeServiceEndpoints() -> [String] {
    ProjectServiceEndpointDiscovery.candidateEndpoints()
        .compactMap(ProjectServiceEndpointDiscovery.serializedEndpointString)
}

func sendResponse(_ response: JSONRPCResponse) {
    guard let data = try? jsonEncoder.encode(response),
          var json = String(data: data, encoding: .utf8) else {
        let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal encoding error"}}"#
        FileHandle.standardOutput.write((fallback + "\n").data(using: .utf8)!)
        return
    }
    json.append("\n")
    FileHandle.standardOutput.write(json.data(using: .utf8) ?? Data())
}

@main
struct ProjectMCP {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let requestData = trimmed.data(using: .utf8) else { continue }

            let decoder = JSONDecoder()
            guard let request = try? decoder.decode(JSONRPCRequest.self, from: requestData) else {
                sendResponse(
                    JSONRPCResponse(
                        id: nil,
                        error: JSONRPCError(code: -32700, message: "Parse error")
                    )
                )
                continue
            }

            if request.method.hasPrefix("notifications/") && request.id == nil {
                continue
            }

            let response = await handleMCPRequest(request)
            sendResponse(response)
        }
    }
}
