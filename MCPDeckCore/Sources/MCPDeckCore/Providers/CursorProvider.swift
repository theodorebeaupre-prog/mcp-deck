import Foundation

/// Cursor keeps a single global config: `~/.cursor/mcp.json`.
public struct CursorProvider: MCPClientProvider {
    public let id = ClientID.cursor
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private var cursorDirectory: URL {
        home.appending(path: ".cursor")
    }

    private var configURL: URL {
        cursorDirectory.appending(path: "mcp.json")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: cursorDirectory.path)
    }

    public func scan() -> ScanResult {
        var issues: [ScanIssue] = []
        guard let root = ServerConfigParser.loadRootObject(at: configURL, issues: &issues) else {
            return ScanResult(issues: issues)
        }
        let location = ConfigLocation(fileURL: configURL, scopeDescription: "Global")
        var result = ServerConfigParser.entries(in: root, client: id, location: location)
        result.issues.append(contentsOf: issues)
        return result
    }
}
