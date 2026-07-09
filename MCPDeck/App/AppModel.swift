import SwiftUI
import Observation
import MCPDeckCore

/// A server's name+transport pair, shared across clients: two clients pointing
/// at the same server get one health check and one merged dashboard row.
extension ServerEntry {
    var healthKey: String {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(transport)
        return "\(name)-\(hasher.finalize())"
    }
}

struct ClientInfo: Identifiable, Equatable {
    let id: ClientID
    let isInstalled: Bool
    let serverCount: Int
}

enum GlobalHealth {
    case allGood
    case authNeeded
    case problems
    case idle

    var menuBarSymbol: String {
        switch self {
        case .idle, .allGood: return "square.stack.3d.up"
        case .authNeeded: return "square.stack.3d.up.badge.automatic"
        case .problems: return "square.stack.3d.up.trianglebadge.exclamationmark"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Discovery state

    private(set) var servers: [ServerEntry] = []
    private(set) var issues: [ScanIssue] = []
    private(set) var clients: [ClientInfo] = []

    // MARK: Health state

    private(set) var reports: [String: HealthReport] = [:]
    private(set) var checkingKeys: Set<String> = []
    var lastActionError: String?

    // MARK: Settings (persisted)

    var autoCheckOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoCheckOnLaunch, forKey: "autoCheckOnLaunch") }
    }
    var checkTimeout: Double {
        didSet { UserDefaults.standard.set(checkTimeout, forKey: "checkTimeout") }
    }
    var excludedFromAutoCheck: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedFromAutoCheck), forKey: "excludedFromAutoCheck") }
    }
    var groupByServer: Bool {
        didSet { UserDefaults.standard.set(groupByServer, forKey: "groupByServer") }
    }

    private let providers: [any MCPClientProvider]

    init(providers: [any MCPClientProvider] = [
        ClaudeDesktopProvider(),
        ClaudeCodeProvider(),
        CursorProvider()
    ]) {
        self.providers = providers
        let defaults = UserDefaults.standard
        autoCheckOnLaunch = defaults.object(forKey: "autoCheckOnLaunch") as? Bool ?? true
        checkTimeout = defaults.object(forKey: "checkTimeout") as? Double ?? HealthChecker.defaultTimeout
        excludedFromAutoCheck = Set(defaults.stringArray(forKey: "excludedFromAutoCheck") ?? [])
        groupByServer = defaults.object(forKey: "groupByServer") as? Bool ?? true

        rescan()
        if autoCheckOnLaunch {
            Task { await checkAll(respectingExclusions: true) }
        }
    }

    // MARK: Scanning

    func rescan() {
        var allServers: [ServerEntry] = []
        var allIssues: [ScanIssue] = []
        var infos: [ClientInfo] = []
        for provider in providers {
            let result = provider.scan()
            allServers.append(contentsOf: result.servers)
            allIssues.append(contentsOf: result.issues)
            infos.append(ClientInfo(
                id: provider.id,
                isInstalled: provider.isInstalled,
                serverCount: result.servers.count
            ))
        }
        servers = allServers
        issues = allIssues
        clients = infos
    }

    // MARK: Health checks

    func status(for entry: ServerEntry) -> HealthStatus {
        if checkingKeys.contains(entry.healthKey) { return .checking }
        return reports[entry.healthKey]?.status ?? .unknown
    }

    func report(for entry: ServerEntry) -> HealthReport? {
        reports[entry.healthKey]
    }

    var globalHealth: GlobalHealth {
        let statuses = servers.filter(\.isEnabled).map { status(for: $0) }
        if statuses.contains(where: \.isProblem) { return .problems }
        if statuses.contains(.authRequired) { return .authNeeded }
        if statuses.contains(where: { if case .ok = $0 { return true } else { return false } }) {
            return .allGood
        }
        return .idle
    }

    func checkAll(respectingExclusions: Bool = false) async {
        var seen = Set<String>()
        var toCheck: [ServerEntry] = []
        for entry in servers where entry.isEnabled {
            if respectingExclusions && excludedFromAutoCheck.contains(entry.healthKey) { continue }
            if seen.insert(entry.healthKey).inserted {
                toCheck.append(entry)
            }
        }

        let timeout = checkTimeout
        checkingKeys.formUnion(toCheck.map(\.healthKey))
        // Window of 4 concurrent checks: enough parallelism to feel instant,
        // few enough spawned processes to stay polite.
        await withTaskGroup(of: (String, HealthReport).self) { group in
            var pending = toCheck[...]
            var active = 0
            func enqueueNext(_ group: inout TaskGroup<(String, HealthReport)>) {
                guard let entry = pending.popFirst() else { return }
                active += 1
                let key = entry.healthKey
                let transport = entry.transport
                group.addTask {
                    (key, await HealthChecker.check(transport, timeout: timeout))
                }
            }
            for _ in 0..<4 { enqueueNext(&group) }
            while active > 0 {
                guard let (key, report) = await group.next() else { break }
                active -= 1
                reports[key] = report
                checkingKeys.remove(key)
                enqueueNext(&group)
            }
        }
        checkingKeys.subtract(toCheck.map(\.healthKey))
    }

    func check(_ entry: ServerEntry) async {
        let key = entry.healthKey
        guard !checkingKeys.contains(key) else { return }
        checkingKeys.insert(key)
        reports[key] = await HealthChecker.check(entry.transport, timeout: checkTimeout)
        checkingKeys.remove(key)
    }

    // MARK: Enable / disable

    func setEnabled(_ enabled: Bool, entry: ServerEntry) {
        do {
            try ConfigMutator.setEnabled(enabled, serverName: entry.name, at: entry.location)
            rescan()
        } catch {
            lastActionError = String(describing: error)
            rescan()
        }
    }

    // MARK: Grouping helpers

    /// All entries sharing one dashboard row (same name+transport).
    func entries(forHealthKey key: String) -> [ServerEntry] {
        servers.filter { $0.healthKey == key }
    }

    /// One representative entry per health key, dashboard order.
    var uniqueServers: [ServerEntry] {
        var seen = Set<String>()
        return servers.filter { seen.insert($0.healthKey).inserted }
    }

    func servers(for client: ClientID) -> [ServerEntry] {
        servers.filter { $0.client == client }
    }
}
