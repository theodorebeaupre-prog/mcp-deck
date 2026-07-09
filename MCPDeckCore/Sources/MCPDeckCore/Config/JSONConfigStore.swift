import Foundation

public enum ConfigStoreError: Error, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case invalidRoot(String)
    case containerNotFound(keyPath: [String], file: String)
    case serverNotFound(name: String, file: String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "Config file not found: \(path)"
        case .invalidRoot(let path):
            return "Top-level JSON value is not an object in \(path)"
        case .containerNotFound(let keyPath, let file):
            return "Section \(keyPath.joined(separator: ".")) not found in \(file)"
        case .serverNotFound(let name, let file):
            return "Server \"\(name)\" not found in \(file)"
        }
    }
}

/// Reads and writes JSON config files with the safety guarantees MCP Deck
/// promises: a `.bak` copy before every write, atomic replacement, and
/// key-order/number-representation preservation via `JSONValue`.
public enum JSONConfigStore {
    public static func read(_ url: URL) throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigStoreError.fileNotFound(url.path)
        }
        return try JSONValue.parse(data: try Data(contentsOf: url))
    }

    public static func write(_ value: JSONValue, to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let backupURL = url.appendingPathExtension("bak")
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
        }
        try Data(value.serialized().utf8).write(to: url, options: .atomic)
    }
}

/// Generic enable/disable: moves a server definition between `mcpServers` and
/// `_disabled_mcpServers` inside the container object a `ConfigLocation` points
/// at. Works identically for every client because providers describe *where*
/// servers live instead of implementing their own writes.
public enum ConfigMutator {
    public static func setEnabled(_ enabled: Bool, serverName: String, at location: ConfigLocation) throws {
        let root = try JSONConfigStore.read(location.fileURL)
        guard var rootObject = root.objectValue else {
            throw ConfigStoreError.invalidRoot(location.fileURL.path)
        }

        let sourceKey = enabled ? disabledServersKey : "mcpServers"
        let targetKey = enabled ? "mcpServers" : disabledServersKey

        var container = try containerObject(in: rootObject, at: location)
        guard var source = container[sourceKey]?.objectValue,
              let definition = source[serverName] else {
            throw ConfigStoreError.serverNotFound(name: serverName, file: location.fileURL.path)
        }

        source[serverName] = nil
        var target = container[targetKey]?.objectValue ?? JSONObject()
        target[serverName] = definition

        // Drop an emptied _disabled_mcpServers so files return to their
        // pristine shape once everything is re-enabled; keep an empty
        // mcpServers since clients expect the key to exist.
        if source.isEmpty && sourceKey == disabledServersKey {
            container[sourceKey] = nil
        } else {
            container[sourceKey] = .object(source)
        }
        container[targetKey] = .object(target)

        try setContainerObject(container, in: &rootObject, at: location)
        try JSONConfigStore.write(.object(rootObject), to: location.fileURL)
    }

    private static func containerObject(in root: JSONObject, at location: ConfigLocation) throws -> JSONObject {
        var current = root
        for key in location.containerKeyPath {
            guard let next = current[key]?.objectValue else {
                throw ConfigStoreError.containerNotFound(
                    keyPath: location.containerKeyPath,
                    file: location.fileURL.path
                )
            }
            current = next
        }
        return current
    }

    private static func setContainerObject(
        _ container: JSONObject,
        in root: inout JSONObject,
        at location: ConfigLocation
    ) throws {
        guard !location.containerKeyPath.isEmpty else {
            root = container
            return
        }
        root = try replacing(
            in: root,
            keyPath: ArraySlice(location.containerKeyPath),
            with: container,
            location: location
        )
    }

    private static func replacing(
        in object: JSONObject,
        keyPath: ArraySlice<String>,
        with replacement: JSONObject,
        location: ConfigLocation
    ) throws -> JSONObject {
        var object = object
        guard let key = keyPath.first else { return replacement }
        guard let child = object[key]?.objectValue else {
            throw ConfigStoreError.containerNotFound(
                keyPath: location.containerKeyPath,
                file: location.fileURL.path
            )
        }
        object[key] = .object(try replacing(
            in: child,
            keyPath: keyPath.dropFirst(),
            with: replacement,
            location: location
        ))
        return object
    }
}
