import XCTest
@testable import MCPDeckCore

final class LogDiscoveryTests: XCTestCase {
    func testServerNameExtraction() {
        XCTAssertEqual(LogDiscovery.serverName(fromLogFileName: "mcp-server-n8n.log"), "n8n")
        XCTAssertEqual(
            LogDiscovery.serverName(fromLogFileName: "mcp-server-Palmier Pro.log"),
            "Palmier Pro"
        )
        XCTAssertNil(LogDiscovery.serverName(fromLogFileName: "mcp.log"))
        XCTAssertNil(LogDiscovery.serverName(fromLogFileName: "main.log"))
    }

    func testDiscoveryFiltersAndSorts() throws {
        let home = try FakeHome()
        defer { home.destroy() }
        try home.writeFile(at: "Library/Logs/Claude/mcp.log", contents: "x\n")
        try home.writeFile(at: "Library/Logs/Claude/mcp-server-zeta.log", contents: "x\n")
        try home.writeFile(at: "Library/Logs/Claude/mcp-server-Alpha.log", contents: "x\n")
        try home.writeFile(at: "Library/Logs/Claude/main.log", contents: "not mcp\n")
        try home.writeFile(at: "Library/Logs/Claude/mcp.log.old", contents: "not .log\n")

        let logs = LogDiscovery.claudeDesktopLogs(home: home.root)
        XCTAssertEqual(
            logs.map(\.url.lastPathComponent),
            ["mcp-server-Alpha.log", "mcp-server-zeta.log", "mcp.log"]
        )
        XCTAssertEqual(logs.map(\.serverName), ["Alpha", "zeta", nil])
    }

    func testDiscoveryHandlesMissingDirectory() throws {
        let home = try FakeHome()
        defer { home.destroy() }
        XCTAssertEqual(LogDiscovery.claudeDesktopLogs(home: home.root), [])
    }
}

final class LogTailerTests: XCTestCase {
    func testBackfillAndLiveAppend() async throws {
        let home = try FakeHome()
        defer { home.destroy() }
        let url = try home.writeFile(at: "test.log", contents: "old-1\nold-2\n")

        let tailer = LogTailer(url: url)
        var iterator = tailer.lines().makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual([first, second], ["old-1", "old-2"])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("live-1\n".utf8))
        try handle.close()

        let third = await iterator.next()
        XCTAssertEqual(third, "live-1")
    }

    func testRotationReopensFile() async throws {
        let home = try FakeHome()
        defer { home.destroy() }
        let url = try home.writeFile(at: "rotating.log", contents: "before\n")

        let tailer = LogTailer(url: url)
        var iterator = tailer.lines().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, "before")

        // Simulate logrotate: replace with a smaller file.
        try "after-rotation\n".write(to: url, atomically: true, encoding: .utf8)

        let next = await iterator.next()
        XCTAssertEqual(next, "after-rotation")
    }
}
