import XCTest
@testable import MCPDeckCore

final class JSONValueTests: XCTestCase {
    func testRoundTripPreservesKeyOrderAndFormatting() throws {
        let source = """
        {
          "zebra": 1,
          "alpha": {
            "nested_z": true,
            "nested_a": null
          },
          "list": [
            "one",
            2,
            {
              "three": 3.0
            }
          ]
        }

        """
        let parsed = try JSONValue.parse(source)
        XCTAssertEqual(parsed.serialized(), source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        XCTAssertEqual(parsed.objectValue?.keys, ["zebra", "alpha", "list"])
    }

    func testNumberRepresentationIsPreserved() throws {
        let source = #"{"a": 1.50, "b": 3e10, "c": -0.001, "d": 12345678901234567890}"#
        let parsed = try JSONValue.parse(source)
        let object = try XCTUnwrap(parsed.objectValue)
        XCTAssertEqual(object["a"], .number("1.50"))
        XCTAssertEqual(object["b"], .number("3e10"))
        XCTAssertEqual(object["c"], .number("-0.001"))
        // 20-digit integers overflow Double/Int64; raw storage keeps them intact.
        XCTAssertEqual(object["d"], .number("12345678901234567890"))
        XCTAssertEqual(try JSONValue.parse(parsed.serialized()), parsed)
    }

    func testStringEscapes() throws {
        let source = #"{"text": "line\nbreak \"quoted\" \\ tab\t é 😀"}"#
        let parsed = try JSONValue.parse(source)
        XCTAssertEqual(parsed.objectValue?["text"]?.stringValue, "line\nbreak \"quoted\" \\ tab\t é 😀")
        // Serialized form must parse back to the identical value.
        XCTAssertEqual(try JSONValue.parse(parsed.serialized()), parsed)
    }

    func testParseErrorsCarryLineAndColumn() {
        XCTAssertThrowsError(try JSONValue.parse("{\n  \"a\": ,\n}")) { error in
            guard let parseError = error as? JSONParseError else {
                return XCTFail("Expected JSONParseError, got \(error)")
            }
            XCTAssertEqual(parseError.line, 2)
        }
        XCTAssertThrowsError(try JSONValue.parse("{} trailing"))
        XCTAssertThrowsError(try JSONValue.parse(""))
        XCTAssertThrowsError(try JSONValue.parse("{\"a\": 01}"))
    }

    func testSubscriptEditingPreservesOrder() throws {
        var object = try XCTUnwrap(JSONValue.parse(#"{"a": 1, "b": 2, "c": 3}"#).objectValue)
        object["b"] = .string("updated")
        XCTAssertEqual(object.keys, ["a", "b", "c"])
        object["b"] = nil
        XCTAssertEqual(object.keys, ["a", "c"])
        object["d"] = .bool(true)
        XCTAssertEqual(object.keys, ["a", "c", "d"])
    }

    func testEmptyContainers() throws {
        XCTAssertEqual(try JSONValue.parse("{}").serialized(), "{}\n")
        XCTAssertEqual(try JSONValue.parse("[]").serialized(), "[]\n")
        XCTAssertEqual(try JSONValue.parse(#"{"a": {}, "b": []}"#).serialized(), "{\n  \"a\": {},\n  \"b\": []\n}\n")
    }
}
