import XCTest
@testable import MCPDeckCore

/// Opt-in harness: point MCPDECK_REAL_CONFIG at a *copy* of a real config file
/// to verify the disable/enable round-trip against it. Skipped otherwise, so
/// CI and normal runs are unaffected.
///
///   cp ~/.claude.json /tmp/claude-copy.json
///   MCPDECK_REAL_CONFIG=/tmp/claude-copy.json swift test --filter RealConfig
final class RealConfigRoundTripTests: XCTestCase {
    func testRoundTripOnRealConfigCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["MCPDECK_REAL_CONFIG"] else {
            throw XCTSkip("Set MCPDECK_REAL_CONFIG to a copy of a real config file to run this test.")
        }
        let url = URL(filePath: path)
        let original = try JSONConfigStore.read(url)
        let servers = try XCTUnwrap(
            original.objectValue?["mcpServers"]?.objectValue,
            "No top-level mcpServers in \(path)"
        )
        let names = servers.keys
        try XCTSkipIf(names.isEmpty, "No servers to round-trip in \(path)")

        let location = ConfigLocation(fileURL: url, scopeDescription: "Global")
        for name in names {
            try ConfigMutator.setEnabled(false, serverName: name, at: location)
            try ConfigMutator.setEnabled(true, serverName: name, at: location)
        }

        let roundTripped = try JSONConfigStore.read(url)
        XCTAssertEqual(canonicalized(roundTripped), canonicalized(original),
                       "Round-trip altered the file semantically")
        XCTAssertEqual(roundTripped.objectValue?.keys, original.objectValue?.keys,
                       "Round-trip reordered top-level keys")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
            "No .bak backup was created"
        )
    }
}
