import XCTest
@testable import MCPDeckCore

final class ProviderTests: XCTestCase {
    private var home: FakeHome!

    override func setUpWithError() throws {
        home = try FakeHome()
    }

    override func tearDown() {
        home.destroy()
    }

    // MARK: Claude Desktop

    func testClaudeDesktopScan() throws {
        try home.writeFile(
            at: "Library/Application Support/Claude/claude_desktop_config.json",
            contents: try fixtureText("claude_desktop_config")
        )
        let provider = ClaudeDesktopProvider(home: home.root)
        XCTAssertTrue(provider.isInstalled)

        let result = provider.scan()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.servers.map(\.name), ["automation-tool", "local-files"])

        let automation = result.servers[0]
        XCTAssertEqual(automation.client, .claudeDesktop)
        XCTAssertTrue(automation.isEnabled)
        XCTAssertEqual(automation.transport, .stdio(
            command: "npx",
            args: ["-y", "@example/automation-mcp"],
            env: ["API_URL": "https://automation.example.com", "API_KEY": "sk-test-1234"]
        ))
    }

    func testClaudeDesktopNotInstalled() {
        let provider = ClaudeDesktopProvider(home: home.root)
        XCTAssertFalse(provider.isInstalled)
        let result = provider.scan()
        XCTAssertTrue(result.servers.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testInvalidJSONProducesIssueNotCrash() throws {
        try home.writeFile(
            at: "Library/Application Support/Claude/claude_desktop_config.json",
            contents: try fixtureText("invalid")
        )
        let result = ClaudeDesktopProvider(home: home.root).scan()
        XCTAssertTrue(result.servers.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("Invalid JSON"))
    }

    // MARK: Claude Code

    func testClaudeCodeScanGlobalProjectAndMCPJSON() throws {
        let projectPath = home.root.appending(path: "my-project").path
        try home.createDirectory(at: "my-project")
        try home.writeFile(at: "my-project/.mcp.json", contents: try fixtureText("project_mcp"))
        try home.writeFile(
            at: ".claude.json",
            contents: try fixtureText("claude_code")
                .replacingOccurrences(of: "__PROJECT_PATH__", with: projectPath)
        )

        let provider = ClaudeCodeProvider(home: home.root)
        XCTAssertTrue(provider.isInstalled)
        let result = provider.scan()
        XCTAssertTrue(result.issues.isEmpty)

        XCTAssertEqual(
            result.servers.map(\.name),
            ["remote-http", "legacy-sse", "research-agent", "project-linter", "team-database"]
        )

        let remote = result.servers[0]
        XCTAssertEqual(remote.transport, .http(
            url: URL(string: "https://mcp.example.com/api/mcp/sse/a1b2c3")!,
            kind: .http
        ))
        XCTAssertEqual(remote.location.containerKeyPath, [])

        let sse = result.servers[1]
        XCTAssertEqual(sse.transport.kindLabel, "sse")

        let projectLinter = result.servers[3]
        XCTAssertEqual(projectLinter.location.containerKeyPath, ["projects", projectPath])
        XCTAssertEqual(projectLinter.location.scopeDescription, "Project my-project")

        let teamDatabase = result.servers[4]
        XCTAssertEqual(teamDatabase.location.fileURL.lastPathComponent, ".mcp.json")
        XCTAssertEqual(teamDatabase.location.containerKeyPath, [])
    }

    func testClaudeCodeDisabledServersAreScanned() throws {
        try home.writeFile(at: ".claude.json", contents: """
        {
          "mcpServers": {
            "active": {"command": "a"}
          },
          "_disabled_mcpServers": {
            "sleeping": {"command": "b"}
          }
        }
        """)
        let result = ClaudeCodeProvider(home: home.root).scan()
        XCTAssertEqual(result.servers.count, 2)
        XCTAssertTrue(result.servers[0].isEnabled)
        XCTAssertFalse(result.servers[1].isEnabled)
        XCTAssertEqual(result.servers[1].name, "sleeping")
    }

    func testUnrecognizableServerBecomesIssue() throws {
        try home.writeFile(at: ".claude.json", contents: """
        {
          "mcpServers": {
            "no-command-no-url": {"note": "what is this"},
            "fine": {"command": "ok"}
          }
        }
        """)
        let result = ClaudeCodeProvider(home: home.root).scan()
        XCTAssertEqual(result.servers.map(\.name), ["fine"])
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("no-command-no-url"))
    }

    // MARK: Cursor

    func testCursorScan() throws {
        try home.writeFile(at: ".cursor/mcp.json", contents: try fixtureText("cursor_mcp"))
        let provider = CursorProvider(home: home.root)
        XCTAssertTrue(provider.isInstalled)
        let result = provider.scan()
        XCTAssertEqual(result.servers.map(\.name), ["docs-search", "shell"])
        // A bare "url" with no "type" defaults to streamable http.
        XCTAssertEqual(result.servers[0].transport.kindLabel, "http")
    }

    func testCursorNotInstalled() {
        let provider = CursorProvider(home: home.root)
        XCTAssertFalse(provider.isInstalled)
        XCTAssertTrue(provider.scan().servers.isEmpty)
    }
}
