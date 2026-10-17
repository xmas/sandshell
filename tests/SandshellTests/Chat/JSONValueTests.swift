import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundary and coercion cases for JSONValue (fileprivate so it can't clash with other suites' tags).
    @Tag fileprivate static var jsonValueEdgeCase: Self
}

/// Encode/decode helpers shared by the JSONValue suites in this file.
fileprivate enum JSONValueFixture {
    static func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    static func roundTrip(_ value: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// JSONEncoder output with sorted keys, so multi-key objects can be compared as text.
    static func sortedJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// A message shape that carries an open-ended JSONValue payload, like ACP's `params`.
fileprivate struct JSONValueEnvelope: Codable, Equatable {
    var id: Int
    var params: JSONValue
}

// MARK: - Decoding

struct JSONValueDecodingTests {
    @Test(arguments: [
        ("null", JSONValue.null),
        ("true", .bool(true)),
        ("false", .bool(false)),
        ("0", .number(0)),
        ("42", .number(42)),
        ("-7", .number(-7)),
        ("3.5", .number(3.5)),
        ("-1.5e-3", .number(-0.0015)),
        ("\"hi\"", .string("hi")),
        ("\"\"", .string("")),
        ("  42  ", .number(42)),
    ] as [(String, JSONValue)])
    func decodesTopLevelScalars(json: String, expected: JSONValue) throws {
        #expect(try JSONValueFixture.decode(json) == expected)
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: ["1", "3.5", "true", "false", "null", ""])
    func quotedLiteralsStayStrings(text: String) throws {
        let decoded = try JSONValueFixture.decode("\"\(text)\"")
        #expect(decoded == .string(text), "A quoted \(text) must not be coerced to another type")
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: [0, 1])
    func zeroAndOneDecodeAsNumbersNotBools(number: Int) throws {
        let decoded = try JSONValueFixture.decode(String(number))
        #expect(decoded == .number(Double(number)))
        #expect(decoded.bool == nil, "JSON \(number) is a number, not a boolean")
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: [
        ("[]", JSONValue.array([])),
        ("{}", .object([:])),
    ] as [(String, JSONValue)])
    func decodesEmptyContainers(json: String, expected: JSONValue) throws {
        #expect(try JSONValueFixture.decode(json) == expected)
    }

    @Test func decodesNestedMessage() throws {
        let json = #"{"jsonrpc":"2.0","id":7,"params":{"tags":["a",null,false,2.5],"_meta":{}}}"#
        let expected: JSONValue = [
            "jsonrpc": "2.0",
            "id": 7,
            "params": [
                "tags": ["a", .null, false, .number(2.5)],
                "_meta": [:],
            ],
        ]
        #expect(try JSONValueFixture.decode(json) == expected)
    }

    @Test func keepsNullMembersAsNull() throws {
        let decoded = try JSONValueFixture.decode(#"{"k":null}"#)
        #expect(decoded == .object(["k": .null]))
    }

    @Test func decodesAsPropertyOfCodableType() throws {
        let data = Data(#"{"id":3,"params":{"x":[1,"y"]}}"#.utf8)
        let envelope = try JSONDecoder().decode(JSONValueEnvelope.self, from: data)
        #expect(envelope == JSONValueEnvelope(id: 3, params: ["x": [1, "y"]]))
    }

    @Test(.tags(.jsonValueEdgeCase))
    func nullPropertyDecodesAsNullCase() throws {
        let data = Data(#"{"id":3,"params":null}"#.utf8)
        let envelope = try JSONDecoder().decode(JSONValueEnvelope.self, from: data)
        #expect(envelope.params == .null)
    }

    @Test(.tags(.jsonValueEdgeCase))
    func integersBeyondDoublePrecisionAreRounded() throws {
        let decoded = try JSONValueFixture.decode("9007199254740993")
        #expect(decoded == .number(9_007_199_254_740_992), "JSON numbers are carried as Double, so 2^53 + 1 rounds to 2^53")
    }

    @Test(arguments: ["", "{", "nul", "tru", "[1, 2", #"{"a" 1}"#, #"{"a":}"#, #""unterminated"#])
    func rejectsMalformedJSON(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONValueFixture.decode(json)
        }
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: ["1e400", "-1e400"])
    func rejectsNumbersOutsideDoubleRange(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONValueFixture.decode(json)
        }
    }
}

// MARK: - Encoding

struct JSONValueEncodingTests {
    enum NonFiniteNumber: String, CaseIterable, Sendable {
        case nan, infinity, negativeInfinity

        var value: Double {
            switch self {
            case .nan: .nan
            case .infinity: .infinity
            case .negativeInfinity: -.infinity
            }
        }
    }

    @Test(arguments: [
        (JSONValue.null, "null"),
        (.bool(true), "true"),
        (.bool(false), "false"),
        (.string("hi"), "\"hi\""),
        (.string(""), "\"\""),
    ] as [(JSONValue, String)])
    func encodesScalars(value: JSONValue, expected: String) {
        #expect(value.compactString == expected)
    }

    @Test(arguments: [
        (0, "0"),
        (42, "42"),
        (-7, "-7"),
        (1e14, "100000000000000"),
        (999_999_999_999_999, "999999999999999"),
        (-999_999_999_999_999, "-999999999999999"),
    ] as [(Double, String)])
    func integralNumbersEncodeWithoutFraction(number: Double, expected: String) {
        #expect(JSONValue.number(number).compactString == expected, "Integral numbers below 1e15 go out as Int64")
    }

    @Test(.tags(.jsonValueEdgeCase))
    func negativeZeroEncodesAsZero() {
        #expect(JSONValue.number(-0.0).compactString == "0", "-0 is integral, so it goes out through Int64 and loses its sign")
    }

    @Test(arguments: [
        (2.5, "2.5"),
        (-0.25, "-0.25"),
        (0.1, "0.1"),
        (1.0000000000000002, "1.0000000000000002"),
    ] as [(Double, String)])
    func fractionalNumbersKeepTheirFraction(number: Double, expected: String) {
        #expect(JSONValue.number(number).compactString == expected)
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: [1e15, -1e15, 4.5e15, 1e16, 1e300, -1e300])
    func numbersPastTheIntegerCutoffRoundTrip(number: Double) throws {
        #expect(try JSONValueFixture.roundTrip(.number(number)) == .number(number))
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: JSONValueEncodingTests.NonFiniteNumber.allCases)
    func nonFiniteNumbersCannotBeEncoded(_ number: NonFiniteNumber) {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(JSONValue.number(number.value))
        }
        #expect(JSONValue.number(number.value).compactString == "", "compactString falls back to an empty string")
    }

    @Test(.tags(.jsonValueEdgeCase))
    func nonFiniteNumberAnywhereEmptiesCompactString() {
        let value: JSONValue = ["result": ["values": [1, .number(.infinity)]]]
        #expect(value.compactString == "", "One bad leaf fails the whole encode")
    }

    @Test func escapesQuotesBackslashesAndWhitespace() {
        let value = JSONValue.string("say \"hi\"\n\\ \t")
        #expect(value.compactString == #""say \"hi\"\n\\ \t""#)
    }

    @Test(.tags(.jsonValueEdgeCase))
    func escapesControlCharactersAsUnicode() {
        #expect(JSONValue.string("\u{01}").compactString == #""\u0001""#)
    }

    @Test func keepsNonASCIIUnescaped() {
        #expect(JSONValue.string("café ☕").compactString == "\"café ☕\"")
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: [
        (JSONValue.array([]), "[]"),
        (.object([:]), "{}"),
    ] as [(JSONValue, String)])
    func encodesEmptyContainers(value: JSONValue, expected: String) {
        #expect(value.compactString == expected)
    }

    @Test func encodesArraysCompactlyInOrder() {
        let value: JSONValue = [1, "a", true, .null, [.number(2.5)]]
        #expect(value.compactString == #"[1,"a",true,null,[2.5]]"#)
    }

    @Test func encodesNestedObjects() {
        let value: JSONValue = ["a": ["b": [1, 2]]]
        #expect(value.compactString == #"{"a":{"b":[1,2]}}"#)
    }

    @Test func encodesMultiKeyObjectsThroughJSONEncoder() throws {
        let request: JSONValue = [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "initialize",
            "params": ["b": .number(1.5), "a": [true, .null]],
        ]
        let json = try JSONValueFixture.sortedJSON(request)
        #expect(json == #"{"id":7,"jsonrpc":"2.0","method":"initialize","params":{"a":[true,null],"b":1.5}}"#)
    }

    @Test func encodesAsPropertyOfCodableType() throws {
        let envelope = JSONValueEnvelope(id: 3, params: ["x": .null])
        #expect(try JSONValueFixture.sortedJSON(envelope) == #"{"id":3,"params":{"x":null}}"#)
    }

    @Test(arguments: [
        JSONValue.null,
        .bool(false),
        .number(-12.75),
        .string("café ☕"),
        .string("42"),
        .array([]),
        .object([:]),
        ["b": 2, "a": [1, "x", .null], "c": ["deep": [true]]],
        [[[]], [:], ""],
    ] as [JSONValue])
    func roundTripPreservesValue(value: JSONValue) throws {
        #expect(try JSONValueFixture.roundTrip(value) == value)
    }
}

// MARK: - Subscript

struct JSONValueSubscriptTests {
    let message: JSONValue = [
        "name": "read_file",
        "meta": .null,
        "input": ["path": ["components": ["src", "main.swift"]]],
    ]

    @Test func returnsMemberOfObject() {
        #expect(message["name"] == .string("read_file"))
    }

    @Test func returnsNilForMissingKey() {
        #expect(message["missing"] == nil)
    }

    @Test(.tags(.jsonValueEdgeCase))
    func keysAreCaseSensitive() {
        #expect(message["Name"] == nil)
    }

    @Test(.tags(.jsonValueEdgeCase))
    func distinguishesNullMemberFromMissingKey() throws {
        let member = try #require(message["meta"], "A key holding null is present, not missing")
        #expect(member == .null)
    }

    @Test func chainsThroughNestedObjects() {
        #expect(message["input"]?["path"]?["components"] == .array(["src", "main.swift"]))
        #expect(message["input"]?["nope"]?["components"] == nil)
    }

    @Test(arguments: [
        JSONValue.null,
        .bool(true),
        .number(1),
        .string("name"),
        .array(["name"]),
    ] as [JSONValue])
    func nonObjectsHaveNoMembers(value: JSONValue) {
        #expect(value["name"] == nil)
    }
}

// MARK: - Typed accessors

struct JSONValueAccessorTests {
    /// One value and what each typed accessor should return for it (nil unless set).
    struct AccessorCase: Sendable, CustomTestStringConvertible {
        var value: JSONValue
        var string: String? = nil
        var int: Int? = nil
        var double: Double? = nil
        var bool: Bool? = nil
        var array: [JSONValue]? = nil
        var object: [String: JSONValue]? = nil

        var testDescription: String { "\(value)" }
    }

    static let cases: [AccessorCase] = [
        AccessorCase(value: .null),
        AccessorCase(value: .bool(true), bool: true),
        AccessorCase(value: .bool(false), bool: false),
        AccessorCase(value: .number(42), int: 42, double: 42),
        AccessorCase(value: .number(-2.5), int: -2, double: -2.5),
        AccessorCase(value: .string("42"), string: "42"),
        AccessorCase(value: .string(""), string: ""),
        AccessorCase(value: .array([1, "a"]), array: [1, "a"]),
        AccessorCase(value: .array([]), array: []),
        AccessorCase(value: .object(["k": "v"]), object: ["k": "v"]),
        AccessorCase(value: .object([:]), object: [:]),
    ]

    @Test(arguments: JSONValueAccessorTests.cases)
    func accessorsMatchOnlyTheirOwnCase(_ testCase: AccessorCase) {
        let value = testCase.value
        #expect(value.string == testCase.string)
        #expect(value.int == testCase.int)
        #expect(value.double == testCase.double)
        #expect(value.bool == testCase.bool)
        #expect(value.array == testCase.array)
        #expect(value.object == testCase.object)
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: [
        (3.7, 3),
        (-3.7, -3),
        (-0.5, 0),
        (0.999, 0),
    ] as [(Double, Int)])
    func intTruncatesTowardZero(number: Double, expected: Int) {
        #expect(JSONValue.number(number).int == expected)
    }

    @Test(.tags(.jsonValueEdgeCase), arguments: [
        (9_223_372_036_854_774_784, 9_223_372_036_854_774_784),
        (-9_223_372_036_854_775_808, Int.min),
    ] as [(Double, Int)])
    func intConvertsLargestRepresentableNumbers(number: Double, expected: Int) {
        #expect(JSONValue.number(number).int == expected)
    }

    // Can't be wrapped in withKnownIssue: Int(_: Double) traps, which would take down
    // the whole test host rather than record an issue. An exit test isn't safe either:
    // its child process relaunches the host app with the XCTest variables removed, so
    // AppDelegate.isHostingTests would be false and the app would start for real.
    // Enable once `int` uses Int(exactly:) or otherwise checks the range.
    @Test(
        .tags(.jsonValueEdgeCase),
        .disabled("BUG (JSONValue.swift:44): JSONValue.int calls Int(_: Double), which traps for NaN, infinity and out-of-range numbers instead of returning nil"),
        arguments: [Double.nan, .infinity, -.infinity, 1e300, -1e300, Double(Int.max)]
    )
    func intIsNilWhenNumberDoesNotFitInInt(number: Double) {
        #expect(JSONValue.number(number).int == nil, "\(number) does not fit in Int")
    }
}

// MARK: - Literals

struct JSONValueLiteralTests {
    @Test func stringLiteralMakesString() {
        let value: JSONValue = "hello"
        #expect(value == .string("hello"))
    }

    @Test func negativeIntegerLiteralMakesNumber() {
        let value: JSONValue = -3
        #expect(value == .number(-3))
    }

    @Test(arguments: [0, 42, -3, Int.max, Int.min])
    func integerLiteralInitMakesNumber(integer: Int) {
        #expect(JSONValue(integerLiteral: integer) == .number(Double(integer)))
    }

    @Test(arguments: [true, false])
    func booleanLiteralMakesBool(flag: Bool) {
        #expect(JSONValue(booleanLiteral: flag) == .bool(flag))
    }

    @Test func arrayLiteralKeepsOrderAndMixesTypes() {
        let value: JSONValue = [1, "two", false, .null, [3]]
        #expect(value == .array([.number(1), .string("two"), .bool(false), .null, .array([.number(3)])]))
    }

    @Test func dictionaryLiteralMakesObject() {
        let value: JSONValue = ["id": 1, "ok": true]
        #expect(value == .object(["id": .number(1), "ok": .bool(true)]))
    }

    @Test(.tags(.jsonValueEdgeCase))
    func dictionaryLiteralLastDuplicateKeyWins() {
        let value = JSONValue(dictionaryLiteral: ("a", 1), ("a", 2))
        #expect(value == .object(["a": .number(2)]))
    }

    @Test(.tags(.jsonValueEdgeCase))
    func emptyLiteralsMakeEmptyContainers() {
        let array: JSONValue = []
        let object: JSONValue = [:]
        #expect(array == .array([]))
        #expect(object == .object([:]))
    }
}

// MARK: - Equatable

struct JSONValueEquatableTests {
    @Test(.tags(.jsonValueEdgeCase), arguments: [
        (JSONValue.number(1), JSONValue.bool(true)),
        (.number(0), .bool(false)),
        (.string("1"), .number(1)),
        (.null, .string("null")),
        (.null, .array([])),
        (.array([]), .object([:])),
        (.array([1, 2]), .array([2, 1])),
    ] as [(JSONValue, JSONValue)])
    func differentValuesAreNotEqual(lhs: JSONValue, rhs: JSONValue) {
        #expect(lhs != rhs)
    }

    @Test func objectEqualityIgnoresKeyOrder() {
        let first: JSONValue = ["a": 1, "b": 2]
        let second: JSONValue = ["b": 2, "a": 1]
        #expect(first == second)
    }

    @Test(.tags(.jsonValueEdgeCase))
    func zeroEqualsNegativeZero() {
        #expect(JSONValue.number(0) == .number(-0.0))
    }
}
