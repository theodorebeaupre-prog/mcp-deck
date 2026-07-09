import Foundation

/// Health-checks a stdio MCP server: spawn the process, run the MCP handshake
/// over newline-delimited JSON-RPC, fetch the tool list, then tear the process
/// down without leaks (stdin close → SIGTERM → SIGKILL, on the whole process
/// group so `npx`-style wrappers can't leave orphans).
enum StdioHealthCheck {
    private enum Failure: Error {
        case processExited(stderrTail: String)
    }

    static func run(
        command: String,
        args: [String],
        env: [String: String],
        timeout: TimeInterval
    ) async -> HealthReport {
        let process = Process()
        // Resolving through /usr/bin/env honors PATH lookups for bare
        // commands like "npx", exactly as the AI clients themselves do.
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command] + args
        process.environment = augmentedEnvironment(with: env)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return HealthReport(
                status: .error(message: "Failed to launch \(command): \(error.localizedDescription)"),
                checkedAt: Date()
            )
        }

        let pid = process.processIdentifier
        ProcessRegistry.shared.register(pid)

        let stderrCollector = DataCollector(handle: stderrPipe.fileHandleForReading)
        let lines = lineStream(from: stdoutPipe.fileHandleForReading)
        let start = ContinuousClock.now

        let report: HealthReport
        do {
            let handshake = try await withDeadline(seconds: timeout) {
                try await performHandshake(
                    stdin: stdinPipe.fileHandleForWriting,
                    lines: lines,
                    start: start,
                    stderrCollector: stderrCollector
                )
            }
            if let handshake {
                report = HealthReport(
                    status: .ok(latency: handshake.latency),
                    serverInfo: handshake.serverInfo,
                    tools: handshake.tools,
                    checkedAt: Date()
                )
            } else {
                report = HealthReport(status: .timeout, checkedAt: Date())
            }
        } catch Failure.processExited(let stderrTail) {
            let detail = stderrTail.isEmpty ? "no error output" : stderrTail
            report = HealthReport(
                status: .error(message: "Process exited during handshake: \(detail)"),
                checkedAt: Date()
            )
        } catch {
            report = HealthReport(
                status: .error(message: error.localizedDescription),
                checkedAt: Date()
            )
        }

        await terminate(process, stdin: stdinPipe.fileHandleForWriting)
        return report
    }

    // MARK: Handshake

    private struct HandshakeResult: Sendable {
        let serverInfo: HealthReport.ServerInfo?
        let tools: [MCPTool]
        let latency: TimeInterval
    }

    private static func performHandshake(
        stdin: FileHandle,
        lines: AsyncStream<String>,
        start: ContinuousClock.Instant,
        stderrCollector: DataCollector
    ) async throws -> HandshakeResult {
        try write(JSONRPC.initializeRequest(id: 1), to: stdin)

        var serverInfo: HealthReport.ServerInfo?
        var latency: TimeInterval = 0
        var iterator = lines.makeAsyncIterator()

        // Phase 1: wait for the initialize response, skipping any noise the
        // server prints to stdout and any notifications it sends first.
        while true {
            guard let line = await iterator.next() else {
                throw Failure.processExited(stderrTail: stderrCollector.tail())
            }
            guard let response = JSONRPC.parseResponse(line), JSONRPC.matches(response, id: 1) else {
                continue
            }
            if let error = response.error {
                throw Failure.processExited(stderrTail: "initialize failed: \(error.message)")
            }
            latency = TimeInterval(duration: start.duration(to: .now))
            serverInfo = response.result.flatMap(JSONRPC.serverInfo(fromInitializeResult:))
            break
        }

        // Phase 2: complete the handshake and ask for tools. A server that
        // answers initialize but fails tools/list is still healthy.
        try write(JSONRPC.initializedNotification(), to: stdin)
        try write(JSONRPC.toolsListRequest(id: 2), to: stdin)

        var tools: [MCPTool] = []
        while true {
            guard let line = await iterator.next() else { break }
            guard let response = JSONRPC.parseResponse(line), JSONRPC.matches(response, id: 2) else {
                continue
            }
            if let result = response.result {
                tools = JSONRPC.tools(fromToolsListResult: result)
            }
            break
        }

        return HandshakeResult(serverInfo: serverInfo, tools: tools, latency: latency)
    }

    private static func write(_ message: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data((message + "\n").utf8))
    }

    // MARK: Process teardown

    /// stdin close asks the server to exit per the stdio transport contract;
    /// SIGTERM covers servers that ignore it; SIGKILL after a grace period
    /// covers everything else. All signals target the process group.
    private static func terminate(_ process: Process, stdin: FileHandle) async {
        let pid = process.processIdentifier
        try? stdin.close()

        if process.isRunning {
            ProcessRegistry.killTree(pid, signal: SIGTERM)
        }
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            ProcessRegistry.killTree(pid, signal: SIGKILL)
        }
        ProcessRegistry.shared.unregister(pid)
    }

    // MARK: Environment

    /// GUI apps inherit a minimal PATH that misses Homebrew and friends, so
    /// bare commands like "npx" would fail even though they work in Terminal.
    static func augmentedEnvironment(with serverEnv: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
        ]
        var path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for extra in extraPaths where !path.split(separator: ":").map(String.init).contains(extra) {
            path += ":" + extra
        }
        environment["PATH"] = path
        environment.merge(serverEnv) { _, server in server }
        return environment
    }

    // MARK: Async plumbing

    private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = LineSplitter { line in continuation.yield(line) }
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    buffer.feed(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}

/// Runs an operation with a wall-clock deadline. Returns nil on timeout;
/// the operation's task is cancelled but the caller remains responsible for
/// resource cleanup (which `terminate` handles regardless of outcome).
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Splits an incoming byte stream into UTF-8 lines. Thread-safe because
/// FileHandle readability callbacks arrive on a private queue.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        lock.unlock()
        for line in lines {
            onLine(line)
        }
    }
}

/// Accumulates stderr so failures can show the server's own error message.
private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else if let self {
                self.lock.lock()
                self.data.append(chunk)
                self.lock.unlock()
            }
        }
    }

    /// Last few lines of stderr, trimmed for display in an error status.
    func tail(maxLength: Int = 300) -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.count > maxLength ? "…" + text.suffix(maxLength) : text
    }
}

extension TimeInterval {
    init(duration: Duration) {
        self = TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }
}
