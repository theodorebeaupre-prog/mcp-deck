import Foundation

public struct LogFile: Identifiable, Equatable, Hashable, Sendable {
    public let url: URL
    /// Server name extracted from `mcp-server-<Name>.log`; nil for the
    /// general `mcp.log`.
    public let serverName: String?

    public var id: URL { url }

    public var displayName: String { serverName ?? "General (mcp.log)" }

    public init(url: URL, serverName: String?) {
        self.url = url
        self.serverName = serverName
    }
}

/// Finds Claude Desktop's MCP logs (`~/Library/Logs/Claude/mcp*.log`).
public enum LogDiscovery {
    public static func claudeDesktopLogs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [LogFile] {
        let directory = home.appending(path: "Library/Logs/Claude")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("mcp") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { LogFile(url: $0, serverName: serverName(fromLogFileName: $0.lastPathComponent)) }
    }

    /// "mcp-server-Palmier Pro.log" → "Palmier Pro"; "mcp.log" → nil.
    static func serverName(fromLogFileName name: String) -> String? {
        guard name.hasPrefix("mcp-server-"), name.hasSuffix(".log") else { return nil }
        let base = name.dropFirst("mcp-server-".count).dropLast(".log".count)
        return base.isEmpty ? nil : String(base)
    }
}
