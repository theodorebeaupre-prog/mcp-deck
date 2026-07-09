# Architecture

MCP Deck is two layers:

```
MCPDeckCore/            Swift package — all logic, no UI imports, tested with `swift test`
  Models/               ServerEntry, Transport, HealthStatus, HealthReport, ScanResult
  Providers/            MCPClientProvider + one implementation per AI client
  Config/               JSONValue (order-preserving JSON), JSONConfigStore, ConfigMutator
  HealthCheck/          JSONRPC, StdioHealthCheck, HTTPHealthCheck, ProcessRegistry
  Logs/                 LogDiscovery, LogTailer

MCPDeck/                SwiftUI app — MenuBarExtra, dashboard, detail, logs, settings
```

The app target only *presents* what the package computes. If you can't test a behavior in `MCPDeckCoreTests`, it probably belongs in the package, not the app.

## `MCPClientProvider` — adding a client

Every supported AI client is one implementation of:

```swift
public protocol MCPClientProvider: Sendable {
    var id: ClientID { get }
    var isInstalled: Bool { get }
    func scan() -> ScanResult
}
```

`scan()` returns `ServerEntry` values. The important field is `location`:

```swift
public struct ConfigLocation {
    public let fileURL: URL            // which JSON file owns this server
    public let containerKeyPath: [String]  // path to the object holding "mcpServers"
    public let scopeDescription: String    // "Global", "Project foo", …
}
```

That's the whole trick: providers only describe **where** servers live. The generic
`ConfigMutator` uses the location to enable/disable any server — moving its
definition between `mcpServers` and `_disabled_mcpServers` inside the container
object — so **new providers get config writing, backups, and the round-trip
guarantee for free**. No client-specific write code exists anywhere.

To add Windsurf/Zed/…:

1. Create `Providers/WindsurfProvider.swift`, point it at the client's config file(s), and reuse `ServerConfigParser.entries(in:client:location:)` for the standard `mcpServers` shape.
2. Add the case to `ClientID` (display name comes from there).
3. Register the provider in `AppModel.init`.
4. Add a fixture + a `ProviderTests` case proving your parsing, and run the existing `ConfigMutatorTests` against your fixture if the shape deviates.

Scan failures must never throw: return them as `ScanIssue` values so one broken config can't hide the other clients' servers.

## Why a custom `JSONValue`

`JSONSerialization`/`Codable` reorder keys and normalize numbers — rewriting a user's config would produce a giant diff and could break tooling. `JSONValue` keeps object members in an ordered array and stores numbers as raw text (`1.50` stays `1.50`, 20-digit IDs don't overflow), so a disable→enable round-trip is semantically lossless and unrelated keys are byte-stable. Every write goes through `JSONConfigStore`, which backs the file up to `<name>.bak` first and writes atomically.

## Health checks

`HealthChecker.check(_:timeout:)` routes by transport:

- **stdio** (`StdioHealthCheck`): spawn via `/usr/bin/env` (honors PATH, augmented with Homebrew paths GUI apps don't inherit), newline-delimited JSON-RPC `initialize` → `notifications/initialized` → `tools/list`, then stdin close → SIGTERM → SIGKILL on the **process group** (kills `npx` children). Every PID is tracked in `ProcessRegistry`, drained on app termination and via `atexit` — the "no leaked processes" guarantee.
- **http/sse** (`HTTPHealthCheck`): POST `initialize` with `Accept: application/json, text/event-stream`; 401/403 map to `.authRequired`; SSE-framed responses are unwrapped; legacy SSE endpoints that reject POST get a GET stream probe.

Both produce a `HealthReport` (status + serverInfo + tools + timestamp). Status interpretation is pure-function and unit-tested; only the plumbing touches the network or processes.

## Testing

`swift test --package-path MCPDeckCore` runs everything: JSON round-trips, all three config formats (fixtures modeled on real files), the enable/disable round-trip (byte-identical for last-position servers, semantically identical otherwise), JSON-RPC parsing, and end-to-end stdio checks against a fake Python MCP server (happy path, stdout noise, crash, timeout — including the no-leaked-process assertion).
