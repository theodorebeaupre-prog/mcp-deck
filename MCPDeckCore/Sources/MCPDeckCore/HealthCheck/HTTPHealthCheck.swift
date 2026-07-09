import Foundation

/// Health-checks an HTTP MCP server by POSTing `initialize` to the endpoint.
/// Handles both Streamable HTTP (plain JSON response) and servers that answer
/// in SSE framing. Legacy SSE-only servers that reject POST get a GET probe
/// fallback: enough to distinguish "reachable" from "auth required" from "down".
enum HTTPHealthCheck {
    static func run(url: URL, kind: HTTPTransportKind, timeout: TimeInterval) async -> HealthReport {
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let start = ContinuousClock.now

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await post(JSONRPC.initializeRequest(id: 1), to: url, session: session)
        } catch {
            return HealthReport(status: statusForTransportError(error), checkedAt: Date())
        }
        let latency = TimeInterval(duration: start.duration(to: .now))

        var report = interpretInitializeResponse(response: response, body: data, latency: latency)

        // Some legacy SSE deployments only accept GET on the stream endpoint.
        if case .error = report.status, kind == .sse, [404, 405, 406].contains(response.statusCode) {
            report = await probeSSEStream(url: url, session: session, timeout: timeout, start: start)
        }

        // Handshake succeeded: try to fetch tools over the same session.
        if case .ok = report.status {
            let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
            let tools = await fetchTools(url: url, sessionID: sessionID, session: session)
            report = HealthReport(
                status: report.status,
                serverInfo: report.serverInfo,
                tools: tools,
                checkedAt: report.checkedAt
            )
        }
        return report
    }

    // MARK: Pure interpretation (unit-tested without network)

    static func interpretInitializeResponse(
        response: HTTPURLResponse,
        body: Data,
        latency: TimeInterval
    ) -> HealthReport {
        switch response.statusCode {
        case 401, 403:
            return HealthReport(status: .authRequired, checkedAt: Date())
        case 200..<300:
            break
        default:
            return HealthReport(
                status: .error(message: "HTTP \(response.statusCode)"),
                checkedAt: Date()
            )
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let jsonText: String
        if contentType.contains("text/event-stream") {
            guard let eventData = firstEventData(fromSSE: String(decoding: body, as: UTF8.self)) else {
                return HealthReport(
                    status: .error(message: "Empty SSE response to initialize"),
                    checkedAt: Date()
                )
            }
            jsonText = eventData
        } else {
            jsonText = String(decoding: body, as: UTF8.self)
        }

        guard let rpcResponse = JSONRPC.parseResponse(jsonText) else {
            return HealthReport(
                status: .error(message: "Response is not a JSON-RPC message"),
                checkedAt: Date()
            )
        }
        if let error = rpcResponse.error {
            return HealthReport(
                status: .error(message: "initialize failed: \(error.message)"),
                checkedAt: Date()
            )
        }
        return HealthReport(
            status: .ok(latency: latency),
            serverInfo: rpcResponse.result.flatMap(JSONRPC.serverInfo(fromInitializeResult:)),
            checkedAt: Date()
        )
    }

    /// Extracts the first event's `data:` payload from an SSE body
    /// (concatenating multi-line data fields per the SSE spec).
    static func firstEventData(fromSSE text: String) -> String? {
        var dataLines: [String] = []
        // "\r\n" is a single Character in Swift, so match all newline flavors explicitly.
        let rawLines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        )
        for rawLine in rawLines {
            let line = String(rawLine)
            if line.isEmpty {
                if !dataLines.isEmpty { break }
                continue
            }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
        }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }

    static func statusForTransportError(_ error: Error) -> HealthStatus {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timeout
        }
        return .error(message: error.localizedDescription)
    }

    // MARK: Network plumbing

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private static func post(
        _ message: String,
        to url: URL,
        session: URLSession,
        sessionID: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(message.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(JSONRPC.mcpProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }

    private static func probeSSEStream(
        url: URL,
        session: URLSession,
        timeout: TimeInterval,
        start: ContinuousClock.Instant
    ) async -> HealthReport {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let httpResponse = response as? HTTPURLResponse else {
                return HealthReport(status: .error(message: "Not an HTTP response"), checkedAt: Date())
            }
            switch httpResponse.statusCode {
            case 401, 403:
                return HealthReport(status: .authRequired, checkedAt: Date())
            case 200..<300:
                return HealthReport(
                    status: .ok(latency: TimeInterval(duration: start.duration(to: .now))),
                    checkedAt: Date()
                )
            default:
                return HealthReport(
                    status: .error(message: "HTTP \(httpResponse.statusCode)"),
                    checkedAt: Date()
                )
            }
        } catch {
            return HealthReport(status: statusForTransportError(error), checkedAt: Date())
        }
    }

    private static func fetchTools(url: URL, sessionID: String?, session: URLSession) async -> [MCPTool] {
        do {
            _ = try? await post(JSONRPC.initializedNotification(), to: url, session: session, sessionID: sessionID)
            let (data, response) = try await post(
                JSONRPC.toolsListRequest(id: 2),
                to: url,
                session: session,
                sessionID: sessionID
            )
            guard (200..<300).contains(response.statusCode) else { return [] }
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            let text: String
            if contentType.contains("text/event-stream") {
                guard let eventData = firstEventData(fromSSE: String(decoding: data, as: UTF8.self)) else {
                    return []
                }
                text = eventData
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
            guard let rpcResponse = JSONRPC.parseResponse(text), let result = rpcResponse.result else {
                return []
            }
            return JSONRPC.tools(fromToolsListResult: result)
        } catch {
            return []
        }
    }
}
