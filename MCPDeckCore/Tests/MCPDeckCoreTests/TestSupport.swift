import Foundation
import XCTest
@testable import MCPDeckCore

func fixtureText(_ name: String) throws -> String {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "Missing fixture \(name).json"
    )
    return try String(contentsOf: url, encoding: .utf8)
}

/// Builds a throwaway fake home directory laid out like a real one, so
/// providers can be pointed at it instead of the developer's actual configs.
struct FakeHome {
    let root: URL

    init() throws {
        root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "MCPDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func writeFile(at relativePath: String, contents: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func createDirectory(at relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: relativePath),
            withIntermediateDirectories: true
        )
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Recursively sorts object keys, for comparisons where member order is
/// irrelevant (JSON object semantics) but content must match exactly.
func canonicalized(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
        let sorted = object.members
            .sorted { $0.key < $1.key }
            .map { JSONObject.Member(key: $0.key, value: canonicalized($0.value)) }
        return .object(JSONObject(sorted))
    case .array(let items):
        return .array(items.map(canonicalized))
    default:
        return value
    }
}
