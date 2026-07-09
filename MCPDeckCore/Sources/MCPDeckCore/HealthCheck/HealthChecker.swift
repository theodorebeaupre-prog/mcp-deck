import Foundation

/// Entry point for health checks: routes a transport to the right strategy.
public enum HealthChecker {
    public static let defaultTimeout: TimeInterval = 10

    public static func check(_ transport: Transport, timeout: TimeInterval = defaultTimeout) async -> HealthReport {
        switch transport {
        case .stdio(let command, let args, let env):
            return await StdioHealthCheck.run(command: command, args: args, env: env, timeout: timeout)
        case .http(let url, let kind):
            return await HTTPHealthCheck.run(url: url, kind: kind, timeout: timeout)
        }
    }
}
