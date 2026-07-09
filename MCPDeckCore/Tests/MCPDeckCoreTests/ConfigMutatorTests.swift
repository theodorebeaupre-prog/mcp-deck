import XCTest
@testable import MCPDeckCore

final class ConfigMutatorTests: XCTestCase {
    private var home: FakeHome!

    override func setUpWithError() throws {
        home = try FakeHome()
    }

    override func tearDown() {
        home.destroy()
    }

    /// Disabling then re-enabling the *last* server must reproduce the original
    /// file byte for byte (after one normalization pass through our serializer).
    func testRoundTripLastServerIsByteIdentical() throws {
        let normalized = try JSONValue.parse(fixtureText("claude_desktop_config")).serialized()
        let url = try home.writeFile(at: "config.json", contents: normalized)
        let location = ConfigLocation(fileURL: url, scopeDescription: "Global")

        try ConfigMutator.setEnabled(false, serverName: "local-files", at: location)
        try ConfigMutator.setEnabled(true, serverName: "local-files", at: location)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), normalized)
    }

    /// Re-enabling a non-last server appends it at the end of `mcpServers`
    /// (position within a JSON object is meaningless to clients), but the file
    /// must stay semantically identical: same servers, same definitions, and
    /// every unrelated key byte-identical and in its original order.
    func testRoundTripMiddleServerIsSemanticallyIdentical() throws {
        let originalText = try fixtureText("claude_code")
            .replacingOccurrences(of: "__PROJECT_PATH__", with: "/tmp/project-a")
        let url = try home.writeFile(at: ".claude.json", contents: originalText)
        let original = try JSONValue.parse(originalText)
        let location = ConfigLocation(fileURL: url, scopeDescription: "Global")

        try ConfigMutator.setEnabled(false, serverName: "remote-http", at: location)
        try ConfigMutator.setEnabled(true, serverName: "remote-http", at: location)

        let roundTripped = try JSONConfigStore.read(url)
        XCTAssertEqual(canonicalized(roundTripped), canonicalized(original))

        // Unrelated top-level keys keep their exact positions.
        XCTAssertEqual(roundTripped.objectValue?.keys, original.objectValue?.keys)
    }

    func testDisableMovesEntryAndCreatesBackup() throws {
        let url = try home.writeFile(
            at: "config.json",
            contents: try fixtureText("claude_desktop_config")
        )
        let location = ConfigLocation(fileURL: url, scopeDescription: "Global")

        try ConfigMutator.setEnabled(false, serverName: "automation-tool", at: location)

        let root = try XCTUnwrap(JSONConfigStore.read(url).objectValue)
        XCTAssertEqual(root["mcpServers"]?.objectValue?.keys, ["local-files"])
        XCTAssertEqual(root[disabledServersKey]?.objectValue?.keys, ["automation-tool"])
        // Definition moved intact, including env values.
        let moved = root[disabledServersKey]?.objectValue?["automation-tool"]?.objectValue
        XCTAssertEqual(moved?["env"]?.objectValue?["API_KEY"]?.stringValue, "sk-test-1234")
        // Unrelated keys untouched.
        XCTAssertEqual(root["preferences"]?.objectValue?["fontScale"], .number("1.50"))

        // Backup contains the pre-write content.
        let backup = url.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let backupRoot = try XCTUnwrap(JSONConfigStore.read(backup).objectValue)
        XCTAssertEqual(backupRoot["mcpServers"]?.objectValue?.keys, ["automation-tool", "local-files"])
    }

    func testEmptiedDisabledKeyIsRemoved() throws {
        let url = try home.writeFile(at: "config.json", contents: """
        {
          "mcpServers": {},
          "_disabled_mcpServers": {
            "only-one": {"command": "x"}
          }
        }
        """)
        let location = ConfigLocation(fileURL: url, scopeDescription: "Global")
        try ConfigMutator.setEnabled(true, serverName: "only-one", at: location)

        let root = try XCTUnwrap(JSONConfigStore.read(url).objectValue)
        XCTAssertNil(root[disabledServersKey])
        XCTAssertEqual(root["mcpServers"]?.objectValue?.keys, ["only-one"])
    }

    func testNestedContainerKeyPath() throws {
        let url = try home.writeFile(at: ".claude.json", contents: """
        {
          "projects": {
            "/tmp/demo": {
              "trusted": true,
              "mcpServers": {
                "proj-server": {"command": "p"}
              }
            }
          },
          "other": 1
        }
        """)
        let location = ConfigLocation(
            fileURL: url,
            containerKeyPath: ["projects", "/tmp/demo"],
            scopeDescription: "Project demo"
        )
        try ConfigMutator.setEnabled(false, serverName: "proj-server", at: location)

        let root = try XCTUnwrap(JSONConfigStore.read(url).objectValue)
        let project = root["projects"]?.objectValue?["/tmp/demo"]?.objectValue
        XCTAssertEqual(project?["mcpServers"]?.objectValue?.isEmpty, true)
        XCTAssertEqual(project?[disabledServersKey]?.objectValue?.keys, ["proj-server"])
        XCTAssertEqual(project?["trusted"], .bool(true))
        XCTAssertEqual(root["other"], .number("1"))
    }

    func testMissingServerThrows() throws {
        let url = try home.writeFile(at: "config.json", contents: #"{"mcpServers": {}}"#)
        let location = ConfigLocation(fileURL: url, scopeDescription: "Global")
        XCTAssertThrowsError(try ConfigMutator.setEnabled(false, serverName: "ghost", at: location)) { error in
            XCTAssertEqual(
                error as? ConfigStoreError,
                .serverNotFound(name: "ghost", file: url.path)
            )
        }
        // A failed mutation must not touch the file or create a backup.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
}
