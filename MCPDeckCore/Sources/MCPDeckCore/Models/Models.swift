import Foundation

// MARK: - Clients

public enum ClientID: String, CaseIterable, Codable, Sendable {
    case claudeDesktop
    case claudeCode
    case cursor

    public var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }
}

// MARK: - Transport

public enum HTTPTransportKind: String, Sendable {
    case http
    case sse
}

public enum Transport: Equatable, Hashable, Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(url: URL, kind: HTTPTransportKind)

    public var kindLabel: String {
        switch self {
        case .stdio: return "stdio"
        case .http(_, let kind): return kind.rawValue
        }
    }

    /// The full launch command for stdio servers, e.g. "npx -y @foo/bar".
    public var commandLine: String? {
        guard case .stdio(let command, let args, _) = self else { return nil }
        return ([command] + args).joined(separator: " ")
    }

    public var urlString: String? {
        guard case .http(let url, _) = self else { return nil }
        return url.absoluteString
    }

    public var environment: [String: String] {
        guard case .stdio(_, _, let env) = self else { return [:] }
        return env
    }
}

// MARK: - Config location

/// Points at the JSON object that owns a `mcpServers` map: which file, and the
/// key path of the containing object within that file (empty for top level,
/// ["projects", "/path"] for a Claude Code project section). Enable/disable is
/// implemented generically on top of this, so new client providers get it for free.
public struct ConfigLocation: Hashable, Sendable {
    public let fileURL: URL
    public let containerKeyPath: [String]
    public let scopeDescription: String

    public init(fileURL: URL, containerKeyPath: [String] = [], scopeDescription: String) {
        self.fileURL = fileURL
        self.containerKeyPath = containerKeyPath
        self.scopeDescription = scopeDescription
    }
}

// MARK: - Servers

public struct ServerEntry: Identifiable, Equatable, Hashable, Sendable {
    public let name: String
    public let transport: Transport
    public let client: ClientID
    public let location: ConfigLocation
    public let isEnabled: Bool

    public init(name: String, transport: Transport, client: ClientID, location: ConfigLocation, isEnabled: Bool) {
        self.name = name
        self.transport = transport
        self.client = client
        self.location = location
        self.isEnabled = isEnabled
    }

    public var id: String {
        "\(client.rawValue)|\(location.fileURL.path)|\(location.containerKeyPath.joined(separator: "."))|\(name)"
    }
}

// MARK: - Health

public enum HealthStatus: Equatable, Sendable {
    case unknown
    case checking
    case ok(latency: TimeInterval)
    case authRequired
    case error(message: String)
    case timeout

    public var isProblem: Bool {
        switch self {
        case .error, .timeout: return true
        case .unknown, .checking, .ok, .authRequired: return false
        }
    }
}

public struct MCPTool: Equatable, Hashable, Sendable {
    public let name: String
    public let summary: String?

    public init(name: String, summary: String?) {
        self.name = name
        self.summary = summary
    }
}

/// Everything a successful (or failed) health check learned about a server.
public struct HealthReport: Equatable, Sendable {
    public let status: HealthStatus
    public let serverInfo: ServerInfo?
    public let tools: [MCPTool]
    public let checkedAt: Date

    public struct ServerInfo: Equatable, Sendable {
        public let name: String
        public let version: String?
        public let protocolVersion: String?

        public init(name: String, version: String?, protocolVersion: String?) {
            self.name = name
            self.version = version
            self.protocolVersion = protocolVersion
        }
    }

    public init(status: HealthStatus, serverInfo: ServerInfo? = nil, tools: [MCPTool] = [], checkedAt: Date) {
        self.status = status
        self.serverInfo = serverInfo
        self.tools = tools
        self.checkedAt = checkedAt
    }
}

// MARK: - Scanning

public struct ScanIssue: Equatable, Sendable {
    public let fileURL: URL
    public let message: String

    public init(fileURL: URL, message: String) {
        self.fileURL = fileURL
        self.message = message
    }
}

public struct ScanResult: Sendable {
    public var servers: [ServerEntry]
    public var issues: [ScanIssue]

    public init(servers: [ServerEntry] = [], issues: [ScanIssue] = []) {
        self.servers = servers
        self.issues = issues
    }

    public mutating func merge(_ other: ScanResult) {
        servers.append(contentsOf: other.servers)
        issues.append(contentsOf: other.issues)
    }
}
