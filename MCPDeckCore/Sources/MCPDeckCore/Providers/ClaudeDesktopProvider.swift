import Foundation

/// Claude Desktop keeps a single global config:
/// `~/Library/Application Support/Claude/claude_desktop_config.json`.
public struct ClaudeDesktopProvider: MCPClientProvider {
    public let id = ClientID.claudeDesktop
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private var supportDirectory: URL {
        home.appending(path: "Library/Application Support/Claude")
    }

    private var configURL: URL {
        supportDirectory.appending(path: "claude_desktop_config.json")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: supportDirectory.path)
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
