import Foundation

/// Claude Code stores MCP servers in three places:
/// 1. `~/.claude.json` → top-level `mcpServers` (global scope)
/// 2. `~/.claude.json` → `projects.<path>.mcpServers` (per-project scope)
/// 3. `<project>/.mcp.json` → `mcpServers` (shared project config, committed to repos)
///
/// `~/.claude.json` also contains a large amount of unrelated state
/// (onboarding flags, tips history…) that must survive rewrites untouched —
/// which is why all writing goes through the order-preserving `JSONValue`.
public struct ClaudeCodeProvider: MCPClientProvider {
    public let id = ClientID.claudeCode
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private var configURL: URL {
        home.appending(path: ".claude.json")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    public func scan() -> ScanResult {
        var result = ScanResult()
        guard let root = ServerConfigParser.loadRootObject(at: configURL, issues: &result.issues) else {
            return result
        }

        // Global scope.
        result.merge(ServerConfigParser.entries(
            in: root,
            client: id,
            location: ConfigLocation(fileURL: configURL, scopeDescription: "Global")
        ))

        // Per-project scopes, plus each project's optional .mcp.json.
        var visitedProjectRoots = Set<String>()
        for project in root["projects"]?.objectValue?.members ?? [] {
            let projectPath = project.key
            let shortName = (projectPath as NSString).lastPathComponent

            if let projectObject = project.value.objectValue,
               projectObject["mcpServers"] != nil || projectObject[disabledServersKey] != nil {
                result.merge(ServerConfigParser.entries(
                    in: projectObject,
                    client: id,
                    location: ConfigLocation(
                        fileURL: configURL,
                        containerKeyPath: ["projects", projectPath],
                        scopeDescription: "Project \(shortName)"
                    )
                ))
            }

            guard visitedProjectRoots.insert(projectPath).inserted else { continue }
            let mcpJSONURL = URL(filePath: projectPath).appending(path: ".mcp.json")
            guard FileManager.default.fileExists(atPath: mcpJSONURL.path) else { continue }
            var fileIssues: [ScanIssue] = []
            if let fileRoot = ServerConfigParser.loadRootObject(at: mcpJSONURL, issues: &fileIssues) {
                result.merge(ServerConfigParser.entries(
                    in: fileRoot,
                    client: id,
                    location: ConfigLocation(
                        fileURL: mcpJSONURL,
                        scopeDescription: "Project \(shortName) (.mcp.json)"
                    )
                ))
            }
            result.issues.append(contentsOf: fileIssues)
        }
        return result
    }
}
