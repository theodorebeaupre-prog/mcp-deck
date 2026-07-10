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
    /// Collects tailed lines and reports each new snapshot; expectations
    /// give every wait a timeout so a broken tailer fails instead of hanging.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        private let onChange: ([String]) -> Void

        init(onChange: @escaping ([String]) -> Void) {
            self.onChange = onChange
        }

        func add(_ line: String) {
            lock.lock()
            storage.append(line)
            let snapshot = storage
            lock.unlock()
            onChange(snapshot)
        }
    }

    func testBackfillAndLiveAppend() async throws {
        let home = try FakeHome()
        defer { home.destroy() }
        let url = try home.writeFile(at: "test.log", contents: "old-1\nold-2\n")

        let backfillRead = expectation(description: "backfill lines read")
        backfillRead.assertForOverFulfill = false
        let liveRead = expectation(description: "live line read")
        liveRead.assertForOverFulfill = false
        let collector = LineCollector { lines in
            if Array(lines.prefix(2)) == ["old-1", "old-2"] { backfillRead.fulfill() }
            if lines.contains("live-1") { liveRead.fulfill() }
        }

        let tailer = LogTailer(url: url)
        let pump = Task {
            for await line in tailer.lines() { collector.add(line) }
        }
        defer { pump.cancel() }

        await fulfillment(of: [backfillRead], timeout: 10)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("live-1\n".utf8))
        try handle.close()

        await fulfillment(of: [liveRead], timeout: 10)
    }

    /// Rotation via atomic replace: new inode, and the new file is *larger*
    /// than the old one, so size-based rotation detection alone would miss it.
    func testRotationReopensFile() async throws {
        let home = try FakeHome()
        defer { home.destroy() }
        let url = try home.writeFile(at: "rotating.log", contents: "before\n")

        let beforeRead = expectation(description: "pre-rotation line read")
        beforeRead.assertForOverFulfill = false
        let afterRead = expectation(description: "post-rotation line read")
        afterRead.assertForOverFulfill = false
        let collector = LineCollector { lines in
            if lines.contains("before") { beforeRead.fulfill() }
            if lines.contains("after-rotation is longer") { afterRead.fulfill() }
        }

        let tailer = LogTailer(url: url)
        let pump = Task {
            for await line in tailer.lines() { collector.add(line) }
        }
        defer { pump.cancel() }

        await fulfillment(of: [beforeRead], timeout: 10)
        try "after-rotation is longer\n".write(to: url, atomically: true, encoding: .utf8)
        await fulfillment(of: [afterRead], timeout: 10)
    }
}
