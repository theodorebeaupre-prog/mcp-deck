import Foundation

/// A source of MCP server configuration — one per supported AI client.
///
/// Implementing `scan()` is all a new client needs: each returned `ServerEntry`
/// carries a `ConfigLocation`, and the generic `ConfigMutator` uses it to
/// enable/disable servers without any client-specific write code.
public protocol MCPClientProvider: Sendable {
    var id: ClientID { get }
    /// Whether the client appears to be installed on this machine.
    /// Uninstalled clients are shown differently and produce no scan issues.
    var isInstalled: Bool { get }
    func scan() -> ScanResult
}

extension MCPClientProvider {
    public var displayName: String { id.displayName }
}

/// The key MCP Deck moves disabled servers under. Kept alongside `mcpServers`
/// in the same file so re-enabling restores the exact original entry.
public let disabledServersKey = "_disabled_mcpServers"

/// Shared parsing of a `mcpServers`-style JSON object into `ServerEntry` values.
enum ServerConfigParser {
    /// Parses one server definition. Recognizes:
    /// - `{"command": ..., "args": [...], "env": {...}}` → stdio
    /// - `{"url": ..., "type": "http"|"sse"}` → http/sse
    /// The optional `type` field (as written by Claude Code) is honored but not required.
    static func transport(from object: JSONObject) -> Transport? {
        if let urlString = object["url"]?.stringValue {
            guard let url = URL(string: urlString) else { return nil }
            let kind: HTTPTransportKind = object["type"]?.stringValue == "sse" ? .sse : .http
            return .http(url: url, kind: kind)
        }
        if let command = object["command"]?.stringValue {
            let args = (object["args"]?.arrayValue ?? []).compactMap(\.stringValue)
            var env: [String: String] = [:]
            for member in object["env"]?.objectValue?.members ?? [] {
                env[member.key] = member.value.stringValue ?? ""
            }
            return .stdio(command: command, args: args, env: env)
        }
        return nil
    }

    /// Collects entries from a container object holding `mcpServers` and/or
    /// `_disabled_mcpServers`. Unparseable individual servers become issues,
    /// never crashes, and never abort the rest of the scan.
    static func entries(
        in container: JSONObject,
        client: ClientID,
        location: ConfigLocation
    ) -> ScanResult {
        var result = ScanResult()
        for (key, isEnabled) in [("mcpServers", true), (disabledServersKey, false)] {
            guard let servers = container[key]?.objectValue else { continue }
            for member in servers.members {
                guard let definition = member.value.objectValue,
                      let transport = transport(from: definition) else {
                    result.issues.append(ScanIssue(
                        fileURL: location.fileURL,
                        message: "Server \"\(member.key)\" has no recognizable command or url; skipped."
                    ))
                    continue
                }
                result.servers.append(ServerEntry(
                    name: member.key,
                    transport: transport,
                    client: client,
                    location: location,
                    isEnabled: isEnabled
                ))
            }
        }
        return result
    }

    /// Reads and parses a JSON config file, converting all failure modes
    /// (unreadable, invalid JSON, non-object root) into a `ScanIssue`.
    static func loadRootObject(at url: URL, issues: inout [ScanIssue]) -> JSONObject? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONValue.parse(data: data).objectValue else {
                issues.append(ScanIssue(fileURL: url, message: "Top-level JSON value is not an object."))
                return nil
            }
            return object
        } catch let parseError as JSONParseError {
            issues.append(ScanIssue(fileURL: url, message: "Invalid JSON: \(parseError)"))
            return nil
        } catch {
            issues.append(ScanIssue(fileURL: url, message: "Could not read file: \(error.localizedDescription)"))
            return nil
        }
    }
}
