import Foundation

/// Minimal JSON-RPC 2.0 message building and parsing — just enough for the
/// MCP handshake (`initialize` → `notifications/initialized` → `tools/list`).
public enum JSONRPC {
    public static let mcpProtocolVersion = "2025-06-18"

    public struct RPCError: Equatable, Sendable {
        public let code: Int
        public let message: String
    }

    public struct Response: Equatable, Sendable {
        public let id: JSONValue?
        public let result: JSONValue?
        public let error: RPCError?
    }

    // MARK: Requests

    public static func initializeRequest(id: Int) -> String {
        request(id: id, method: "initialize", params: .object(JSONObject([
            .init(key: "protocolVersion", value: .string(mcpProtocolVersion)),
            .init(key: "capabilities", value: .object(JSONObject())),
            .init(key: "clientInfo", value: .object(JSONObject([
                .init(key: "name", value: .string("MCP Deck")),
                .init(key: "version", value: .string(MCPDeckCoreInfo.version))
            ])))
        ])))
    }

    public static func initializedNotification() -> String {
        request(id: nil, method: "notifications/initialized", params: nil)
    }

    public static func toolsListRequest(id: Int) -> String {
        request(id: id, method: "tools/list", params: nil)
    }

    static func request(id: Int?, method: String, params: JSONValue?) -> String {
        var object = JSONObject([.init(key: "jsonrpc", value: .string("2.0"))])
        if let id {
            object["id"] = .number(String(id))
        }
        object["method"] = .string(method)
        if let params {
            object["params"] = params
        }
        return JSONValue.object(object).serializedCompact()
    }

    // MARK: Responses

    /// Parses one line/message. Returns nil for non-JSON lines (servers
    /// sometimes leak banners to stdout) and for requests/notifications sent
    /// by the server (e.g. log notifications), which health checks ignore.
    public static func parseResponse(_ text: String) -> Response? {
        guard let value = try? JSONValue.parse(text), let object = value.objectValue else {
            return nil
        }
        guard object["method"] == nil else { return nil }

        var error: RPCError?
        if let errorObject = object["error"]?.objectValue {
            let code: Int
            if case .number(let raw)? = errorObject["code"], let parsed = Int(raw) {
                code = parsed
            } else {
                code = 0
            }
            error = RPCError(code: code, message: errorObject["message"]?.stringValue ?? "Unknown error")
        }
        guard object["result"] != nil || error != nil else { return nil }
        return Response(id: object["id"], result: object["result"], error: error)
    }

    public static func matches(_ response: Response, id: Int) -> Bool {
        if case .number(let raw)? = response.id, Int(raw) == id { return true }
        return false
    }

    // MARK: MCP result payloads

    public static func serverInfo(fromInitializeResult result: JSONValue) -> HealthReport.ServerInfo? {
        guard let object = result.objectValue else { return nil }
        let info = object["serverInfo"]?.objectValue
        guard let name = info?["name"]?.stringValue else {
            // A result without serverInfo is still a valid handshake; report what we have.
            return HealthReport.ServerInfo(
                name: "Unknown",
                version: nil,
                protocolVersion: object["protocolVersion"]?.stringValue
            )
        }
        return HealthReport.ServerInfo(
            name: name,
            version: info?["version"]?.stringValue,
            protocolVersion: object["protocolVersion"]?.stringValue
        )
    }

    public static func tools(fromToolsListResult result: JSONValue) -> [MCPTool] {
        guard let items = result.objectValue?["tools"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let object = item.objectValue, let name = object["name"]?.stringValue else {
                return nil
            }
            return MCPTool(name: name, summary: object["description"]?.stringValue)
        }
    }
}
