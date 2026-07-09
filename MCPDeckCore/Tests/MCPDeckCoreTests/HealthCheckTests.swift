import XCTest
@testable import MCPDeckCore

final class JSONRPCTests: XCTestCase {
    func testInitializeRequestShape() throws {
        let request = JSONRPC.initializeRequest(id: 1)
        XCTAssertFalse(request.contains("\n"), "stdio messages must be single-line")
        let object = try XCTUnwrap(JSONValue.parse(request).objectValue)
        XCTAssertEqual(object["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(object["id"], .number("1"))
        XCTAssertEqual(object["method"]?.stringValue, "initialize")
        let params = try XCTUnwrap(object["params"]?.objectValue)
        XCTAssertEqual(params["protocolVersion"]?.stringValue, JSONRPC.mcpProtocolVersion)
        XCTAssertEqual(params["clientInfo"]?.objectValue?["name"]?.stringValue, "MCP Deck")
    }

    func testParseInitializeResponse() throws {
        let line = """
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18",\
        "capabilities":{"tools":{}},"serverInfo":{"name":"demo","version":"2.1.0"}}}
        """
        let response = try XCTUnwrap(JSONRPC.parseResponse(line))
        XCTAssertTrue(JSONRPC.matches(response, id: 1))
        XCTAssertNil(response.error)
        let info = try XCTUnwrap(response.result.flatMap(JSONRPC.serverInfo(fromInitializeResult:)))
        XCTAssertEqual(info.name, "demo")
        XCTAssertEqual(info.version, "2.1.0")
        XCTAssertEqual(info.protocolVersion, "2025-06-18")
    }

    func testParseErrorResponse() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Bad request"}}"#
        let response = try XCTUnwrap(JSONRPC.parseResponse(line))
        XCTAssertEqual(response.error, JSONRPC.RPCError(code: -32600, message: "Bad request"))
    }

    func testNonResponsesAreIgnored() {
        XCTAssertNil(JSONRPC.parseResponse("Starting server on port 3000..."))
        XCTAssertNil(JSONRPC.parseResponse(#"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#))
        XCTAssertNil(JSONRPC.parseResponse(#"{"jsonrpc":"2.0","id":9}"#))
    }

    func testParseToolsList() throws {
        let line = """
        {"jsonrpc":"2.0","id":2,"result":{"tools":[\
        {"name":"search","description":"Searches things","inputSchema":{"type":"object"}},\
        {"name":"no-description"}]}}
        """
        let response = try XCTUnwrap(JSONRPC.parseResponse(line))
        let tools = JSONRPC.tools(fromToolsListResult: try XCTUnwrap(response.result))
        XCTAssertEqual(tools, [
            MCPTool(name: "search", summary: "Searches things"),
            MCPTool(name: "no-description", summary: nil)
        ])
    }
}

final class HTTPHealthCheckTests: XCTestCase {
    private func httpResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://mcp.example.com/mcp")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func test401MapsToAuthRequired() {
        for status in [401, 403] {
            let report = HTTPHealthCheck.interpretInitializeResponse(
                response: httpResponse(status: status),
                body: Data(),
                latency: 0.1
            )
            XCTAssertEqual(report.status, .authRequired)
        }
    }

    func testJSONBodyMapsToOK() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"remote","version":"3.0"}}}"#
        let report = HTTPHealthCheck.interpretInitializeResponse(
            response: httpResponse(status: 200, headers: ["Content-Type": "application/json"]),
            body: Data(body.utf8),
            latency: 0.25
        )
        XCTAssertEqual(report.status, .ok(latency: 0.25))
        XCTAssertEqual(report.serverInfo?.name, "remote")
    }

    func testSSEBodyMapsToOK() throws {
        let body = """
        event: message\r
        data: {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"sse-server"}}}\r
        \r

        """
        let report = HTTPHealthCheck.interpretInitializeResponse(
            response: httpResponse(status: 200, headers: ["Content-Type": "text/event-stream"]),
            body: Data(body.utf8),
            latency: 0.5
        )
        XCTAssertEqual(report.status, .ok(latency: 0.5))
        XCTAssertEqual(report.serverInfo?.name, "sse-server")
    }

    func testServerErrorStatusMapsToError() {
        let report = HTTPHealthCheck.interpretInitializeResponse(
            response: httpResponse(status: 500),
            body: Data(),
            latency: 0
        )
        XCTAssertEqual(report.status, .error(message: "HTTP 500"))
    }

    func testRPCErrorBodyMapsToError() {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Session expired"}}"#
        let report = HTTPHealthCheck.interpretInitializeResponse(
            response: httpResponse(status: 200, headers: ["Content-Type": "application/json"]),
            body: Data(body.utf8),
            latency: 0
        )
        XCTAssertEqual(report.status, .error(message: "initialize failed: Session expired"))
    }

    func testFirstEventDataHandlesMultilineAndCR() {
        XCTAssertEqual(
            HTTPHealthCheck.firstEventData(fromSSE: "data: {\"a\":\r\ndata: 1}\r\n\r\ndata: second\r\n"),
            "{\"a\":\n1}"
        )
        XCTAssertNil(HTTPHealthCheck.firstEventData(fromSSE: ": keepalive\n\n"))
    }

    func testTimeoutErrorMapsToTimeoutStatus() {
        XCTAssertEqual(
            HTTPHealthCheck.statusForTransportError(URLError(.timedOut)),
            .timeout
        )
        if case .error = HTTPHealthCheck.statusForTransportError(URLError(.cannotConnectToHost)) {
        } else {
            XCTFail("Expected .error for connection failures")
        }
    }
}

/// End-to-end stdio checks against a real spawned process (a tiny Python
/// fake server), covering the happy path, stdout noise, crashes, and timeouts.
final class StdioHealthCheckTests: XCTestCase {
    private var serverScript: String!

    override func setUpWithError() throws {
        serverScript = try XCTUnwrap(
            Bundle.module.url(forResource: "fake_mcp_server", withExtension: "py", subdirectory: "Fixtures")
        ).path
    }

    private func check(mode: String, timeout: TimeInterval = 10) async -> HealthReport {
        await HealthChecker.check(
            .stdio(command: "python3", args: [serverScript, mode], env: [:]),
            timeout: timeout
        )
    }

    func testHealthyServer() async {
        let report = await check(mode: "ok")
        guard case .ok(let latency) = report.status else {
            return XCTFail("Expected .ok, got \(report.status)")
        }
        XCTAssertGreaterThan(latency, 0)
        XCTAssertEqual(report.serverInfo?.name, "fake-server")
        XCTAssertEqual(report.tools.map(\.name), ["echo", "add"])
        XCTAssertEqual(ProcessRegistry.shared.activeCount, 0, "No process may outlive its check")
    }

    func testNoisyStdoutIsTolerated() async {
        let report = await check(mode: "noisy")
        guard case .ok = report.status else {
            return XCTFail("Expected .ok despite stdout banner, got \(report.status)")
        }
    }

    func testCrashingServerReportsStderr() async {
        let report = await check(mode: "crash")
        guard case .error(let message) = report.status else {
            return XCTFail("Expected .error, got \(report.status)")
        }
        XCTAssertTrue(message.contains("missing API key"), "stderr should surface in the message: \(message)")
        XCTAssertEqual(ProcessRegistry.shared.activeCount, 0)
    }

    func testUnresponsiveServerTimesOutAndIsKilled() async {
        let report = await check(mode: "silent", timeout: 1)
        XCTAssertEqual(report.status, .timeout)
        XCTAssertEqual(ProcessRegistry.shared.activeCount, 0, "Timed-out process must be killed")
    }

    func testNonexistentCommandReportsError() async {
        let report = await HealthChecker.check(
            .stdio(command: "definitely-not-a-real-command-xyz", args: [], env: [:]),
            timeout: 5
        )
        guard case .error = report.status else {
            return XCTFail("Expected .error, got \(report.status)")
        }
    }
}
