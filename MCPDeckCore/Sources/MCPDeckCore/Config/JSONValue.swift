import Foundation

/// A JSON document model that, unlike `JSONSerialization`, preserves object key
/// order and the exact textual representation of numbers. MCP Deck rewrites
/// user-owned config files, so round-tripping must never reorder keys or turn
/// `1.0` into `1`.
public indirect enum JSONValue: Equatable, Sendable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    /// The raw number token exactly as it appeared in the source (e.g. "1.50", "3e10").
    case number(String)
    case bool(Bool)
    case null
}

/// An ordered collection of key/value members. Lookups are linear scans, which
/// is fine for config-sized objects and keeps insertion/removal trivially correct.
public struct JSONObject: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let key: String
        public var value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var members: [Member]

    public init(_ members: [Member] = []) {
        self.members = members
    }

    public var keys: [String] { members.map(\.key) }
    public var isEmpty: Bool { members.isEmpty }
    public var count: Int { members.count }

    /// Setting a new key appends it; setting an existing key updates it in place;
    /// setting nil removes it. Order of untouched members is always preserved.
    public subscript(key: String) -> JSONValue? {
        get { members.first { $0.key == key }?.value }
        set {
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    members[index].value = newValue
                } else {
                    members.remove(at: index)
                }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    public var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let line: Int
    public let column: Int

    public var description: String { "\(message) (line \(line), column \(column))" }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(text: text)
        let value = try parser.parseValue()
        try parser.expectEnd()
        return value
    }

    public static func parse(data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONParseError(message: "File is not valid UTF-8", line: 0, column: 0)
        }
        return try parse(text)
    }
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var position = 0

    init(text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let scalar = peek() else { throw error("Unexpected end of input") }
        switch scalar {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return try parseBool()
        case "n": return try parseNull()
        case "-", "0"..."9": return try parseNumber()
        default: throw error("Unexpected character '\(scalar)'")
        }
    }

    mutating func expectEnd() throws {
        skipWhitespace()
        if position < scalars.count {
            throw error("Trailing content after JSON value")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try consume("{")
        var object = JSONObject()
        skipWhitespace()
        if peek() == "}" {
            position += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek() == "\"" else { throw error("Expected object key") }
            let key = try parseString()
            skipWhitespace()
            try consume(":")
            let value = try parseValue()
            if object[key] != nil {
                // Last occurrence wins, matching JSONDecoder behavior.
                object[key] = nil
            }
            object[key] = value
            skipWhitespace()
            guard let separator = peek() else { throw error("Unterminated object") }
            position += 1
            if separator == "}" { return .object(object) }
            guard separator == "," else { throw error("Expected ',' or '}' in object") }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try consume("[")
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" {
            position += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard let separator = peek() else { throw error("Unterminated array") }
            position += 1
            if separator == "]" { return .array(items) }
            guard separator == "," else { throw error("Expected ',' or ']' in array") }
        }
    }

    private mutating func parseString() throws -> String {
        try consume("\"")
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = peek() else { throw error("Unterminated string") }
            position += 1
            switch scalar {
            case "\"":
                return String(result)
            case "\\":
                result.append(try parseEscape())
            default:
                if scalar.value < 0x20 { throw error("Unescaped control character in string") }
                result.append(scalar)
            }
        }
    }

    private mutating func parseEscape() throws -> Unicode.Scalar {
        guard let scalar = peek() else { throw error("Unterminated escape sequence") }
        position += 1
        switch scalar {
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u":
            let unit = try parseHexUnit()
            if unit >= 0xD800 && unit <= 0xDBFF {
                // High surrogate: a low surrogate escape must follow.
                guard peek() == "\\" else { throw error("Unpaired surrogate in string") }
                position += 1
                guard peek() == "u" else { throw error("Unpaired surrogate in string") }
                position += 1
                let low = try parseHexUnit()
                guard low >= 0xDC00 && low <= 0xDFFF else { throw error("Invalid low surrogate") }
                let code = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                guard let combined = Unicode.Scalar(code) else { throw error("Invalid surrogate pair") }
                return combined
            }
            guard let single = Unicode.Scalar(unit) else { throw error("Invalid \\u escape") }
            return single
        default:
            throw error("Invalid escape character '\(scalar)'")
        }
    }

    private mutating func parseHexUnit() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = peek(), let digit = scalar.hexDigitValue else {
                throw error("Invalid \\u escape")
            }
            value = value * 16 + UInt32(digit)
            position += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = position
        if peek() == "-" { position += 1 }
        guard let first = peek(), first.isASCIIDigit else { throw error("Invalid number") }
        position += 1
        if first != "0" {
            while let scalar = peek(), scalar.isASCIIDigit { position += 1 }
        } else if let scalar = peek(), scalar.isASCIIDigit {
            throw error("Leading zeros are not allowed in numbers")
        }
        if peek() == "." {
            position += 1
            guard let scalar = peek(), scalar.isASCIIDigit else { throw error("Invalid number") }
            while let scalar = peek(), scalar.isASCIIDigit { position += 1 }
        }
        if peek() == "e" || peek() == "E" {
            position += 1
            if peek() == "+" || peek() == "-" { position += 1 }
            guard let scalar = peek(), scalar.isASCIIDigit else { throw error("Invalid number") }
            while let scalar = peek(), scalar.isASCIIDigit { position += 1 }
        }
        return .number(String(String.UnicodeScalarView(scalars[start..<position])))
    }

    private mutating func parseBool() throws -> JSONValue {
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        throw error("Invalid literal")
    }

    private mutating func parseNull() throws -> JSONValue {
        if match("null") { return .null }
        throw error("Invalid literal")
    }

    private mutating func match(_ literal: String) -> Bool {
        let literalScalars = Array(literal.unicodeScalars)
        guard position + literalScalars.count <= scalars.count else { return false }
        guard Array(scalars[position..<position + literalScalars.count]) == literalScalars else { return false }
        position += literalScalars.count
        return true
    }

    private func peek() -> Unicode.Scalar? {
        position < scalars.count ? scalars[position] : nil
    }

    private mutating func consume(_ expected: Unicode.Scalar) throws {
        guard peek() == expected else { throw error("Expected '\(expected)'") }
        position += 1
    }

    private mutating func skipWhitespace() {
        while let scalar = peek(), scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            position += 1
        }
    }

    private func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        for scalar in scalars[0..<min(position, scalars.count)] {
            if scalar == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return JSONParseError(message: message, line: line, column: column)
    }
}

private extension Unicode.Scalar {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }

    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61 + 10)
        case "A"..."F": return Int(value - 0x41 + 10)
        default: return nil
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Pretty-prints with two-space indentation and a trailing newline —
    /// the style Claude Desktop and Cursor write themselves.
    public func serialized() -> String {
        var output = ""
        write(to: &output, indent: 0)
        output.append("\n")
        return output
    }

    private func write(to output: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let object):
            if object.isEmpty {
                output.append("{}")
                return
            }
            output.append("{\n")
            for (index, member) in object.members.enumerated() {
                output.append(childPad)
                JSONValue.writeEscapedString(member.key, to: &output)
                output.append(": ")
                member.value.write(to: &output, indent: indent + 1)
                output.append(index == object.members.count - 1 ? "\n" : ",\n")
            }
            output.append(pad)
            output.append("}")
        case .array(let items):
            if items.isEmpty {
                output.append("[]")
                return
            }
            output.append("[\n")
            for (index, item) in items.enumerated() {
                output.append(childPad)
                item.write(to: &output, indent: indent + 1)
                output.append(index == items.count - 1 ? "\n" : ",\n")
            }
            output.append(pad)
            output.append("]")
        case .string(let string):
            JSONValue.writeEscapedString(string, to: &output)
        case .number(let raw):
            output.append(raw)
        case .bool(let bool):
            output.append(bool ? "true" : "false")
        case .null:
            output.append("null")
        }
    }

    private static func writeEscapedString(_ string: String, to output: inout String) {
        output.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            case "\u{08}": output.append("\\b")
            case "\u{0C}": output.append("\\f")
            default:
                if scalar.value < 0x20 {
                    output.append(String(format: "\\u%04x", scalar.value))
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append("\"")
    }
}
