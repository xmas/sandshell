import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Malformed, unusual or boundary input from an agent's question.
    @Tag static var agentQuestionEdgeCase: Self
}

// MARK: - Fixtures

/// Collects what a form hands back through `onAnswer`.
fileprivate final class AQAnswerLog {
    var answers: [AgentQuestion.Answer] = []
}

/// Builders for the questions, fields and options the suites below use.
fileprivate enum AQFixture {
    static func option(_ value: String, title: String? = nil, detail: String? = nil,
                       preview: String? = nil) -> AgentQuestion.Option {
        AgentQuestion.Option(value: value, title: title ?? value, detail: detail, preview: preview)
    }

    static let colors: [AgentQuestion.Option] = [option("Red"), option("Blue", preview: "#00f"), option("Green")]
    static let sizes: [AgentQuestion.Option] = [option("S"), option("M"), option("L")]

    static func field(_ id: String, title: String? = nil, detail: String? = nil,
                      kind: AgentQuestion.Field.Kind = .text(secret: false), required: Bool = false,
                      companionOf: String? = nil, defaultValue: JSONValue? = nil) -> AgentQuestion.Field {
        AgentQuestion.Field(id: id, title: title, detail: detail, kind: kind, required: required,
                            companionOf: companionOf, defaultValue: defaultValue)
    }

    static func form(_ fields: [AgentQuestion.Field], message: String = "Pick one.") -> AgentQuestion {
        AgentQuestion(rpcID: 1, message: message, mode: .form, fields: fields, toolCallID: nil)
    }

    static func link(_ url: URL, message: String = "Sign in") -> AgentQuestion {
        AgentQuestion(rpcID: 1, message: message, mode: .url(url, elicitationID: nil), fields: [], toolCallID: nil)
    }

    /// Parses a form question whose schema has these properties and required keys.
    static func parseForm(_ properties: [String: JSONValue], required: [String] = []) -> AgentQuestion? {
        let requiredKeys: [JSONValue] = required.map { JSONValue.string($0) }
        let schema: JSONValue = ["type": "object", "properties": .object(properties), "required": .array(requiredKeys)]
        return AgentQuestion.parse(id: 1, params: ["mode": "form", "message": "Pick one.", "requestedSchema": schema])
    }

    /// Claude's AskUserQuestion shape: question_<n> plus question_<n>_custom, keys out of order.
    static func claudeQuestion() -> AgentQuestion? {
        AgentQuestion.parse(id: 7, params: [
            "mode": "form", "sessionId": "s", "toolCallId": "t1", "message": "Please answer the following questions.",
            "requestedSchema": ["type": "object", "properties": [
                "question_1_custom": ["type": "string", "title": "Other"],
                "question_0": ["type": "string", "title": "Color", "description": "Which color?",
                               "oneOf": [["const": "Red", "title": "Red", "description": "Warm"],
                                         ["const": "Blue", "title": "Blue",
                                          "_meta": ["_claude/askUserQuestionOption": ["preview": "#00f"]]]]],
                "question_1": ["type": "array", "title": "Sizes", "description": "Which sizes?",
                               "items": ["anyOf": [["const": "S", "title": "S"], ["const": "L", "title": "L"]]]],
                "question_0_custom": ["type": "string", "title": "Other"],
            ]]])
    }

    /// Codex's request_user_input shape: a required order, a secret field, a note box marked by questionId.
    static func codexQuestion() -> AgentQuestion? {
        AgentQuestion.parse(id: "c1", params: [
            "mode": "form", "sessionId": "s", "message": "Codex needs your input to continue.",
            "requestedSchema": ["type": "object", "required": ["zeta", "alpha"], "properties": [
                "alpha": ["type": "string", "title": "API token?", "_meta": ["codex": ["isSecret": true]]],
                "zeta": ["type": "string", "title": "Proceed?",
                         "oneOf": [["const": "Yes", "title": "Yes"], ["const": "No", "title": "No"]]],
                "zeta_note": ["type": "string", "title": "Additional answer or note",
                              "_meta": ["codex": ["questionId": "zeta", "role": "user_note"]]],
            ]]])
    }

    @MainActor
    static func makeForm(_ question: AgentQuestion) -> (form: AgentQuestionForm, log: AQAnswerLog) {
        let log = AQAnswerLog()
        let form = AgentQuestionForm(question) { log.answers.append($0) }
        return (form, log)
    }

    // MARK: Parameterized cases

    static let rpcIDs: [(JSONValue, String)] = [(7, "7"), ("c1", "\"c1\"")]

    static let kindCases: [(JSONValue, AgentQuestion.Field.Kind)] = [
        (["type": "string"], .text(secret: false)),
        (["type": "string", "format": "password"], .text(secret: true)),
        (["type": "string", "_meta": ["codex": ["isSecret": true]]], .text(secret: true)),
        (["type": "string", "_meta": ["codex": ["isSecret": false]]], .text(secret: false)),
        (["type": "number"], .number(integer: false)),
        (["type": "integer"], .number(integer: true)),
        (["type": "boolean"], .toggle),
        (["type": "string", "enum": ["a", "b"]], .choice([option("a"), option("b")])),
        (["type": "array", "items": ["enum": ["a", "b"]]], .multiChoice([option("a"), option("b")])),
    ]

    static let unsupportedSpecs: [JSONValue] = [
        ["type": "object"],
        ["type": "null"],
        ["title": "No type at all"],
        ["type": 3],
        ["type": "array"],
        ["type": "array", "items": ["type": "string"]],
    ]

    /// `_meta` that marks a field as the custom answer ("Other" box) of `pick`.
    static let customAnswerMetas: [JSONValue] = [
        ["codex": ["questionId": "pick"]],
        ["questionId": "pick", "isCustomAnswer": true],
        ["air": ["questionId": "pick", "isCustomAnswer": true]],
        ["vendor": ["nested": ["questionId": "pick", "isCustomAnswer": true]]],
    ]

    /// `_meta` that names `pick` but doesn't make the field its custom answer.
    static let notCustomAnswerMetas: [JSONValue] = [
        ["questionId": "pick"],
        ["questionId": "pick", "isCustomAnswer": false],
        ["air": ["questionId": "pick", "isCustomAnswer": "yes"]],
    ]

    /// Skip and Stop, and the transcript line each leaves for a "Pick one." question.
    static let closingAnswers: [(AgentQuestion.Answer, String)] = [
        (.decline, "Skipped: Pick one."),
        (.cancel, "Dismissed: Pick one."),
    ]

    /// A single untitled question: its detail, the answer, and the summary of "Your answer?".
    static let singleUntitledAnswers: [(String?, String, String)] = [
        (nil, "Red", "Your answer? — Red"),
        ("Which color do you like?", "Red", "Your answer? — Red"),
        (nil, "10:30", "Your answer? — 10:30"),
        ("Pick a time", "10:30", "Your answer? — 10:30"),
    ]

    /// Answers to a titled "Color" choice and its Other box, and the summary they make.
    static let otherBoxAnswers: [([String: JSONValue], String)] = [
        (["color": "Red", "color_custom": "Maroon"], "Q?\n• Color: Red, Maroon"),
        (["color": "Red", "color_custom": ""], "Q?\n• Color: Red"),
        (["color_custom": "Maroon"], "Q?\n• Color: Maroon"),
    ]

    /// A required typed field's kind, text that doesn't answer it, and text that does.
    static let requiredTypedFields: [(AgentQuestion.Field.Kind, String, String)] = [
        (.text(secret: false), "  ", "Ada"),
        (.text(secret: true), "\n", "hunter2"),
        (.number(integer: true), "2.5", "3"),
        (.number(integer: false), "abc", "2.5"),
    ]

    static let answerResults: [(AgentQuestion.Answer, JSONValue)] = [
        (.accept(["color": "Red"]), ["action": "accept", "content": ["color": "Red"]]),
        (.accept([:]), ["action": "accept", "content": [:]]),
        (.decline, ["action": "decline"]),
        (.cancel, ["action": "cancel"]),
    ]

    static let renderedValues: [(JSONValue, String)] = [
        ("hi", "hi"),
        (3, "3"),
        (.number(2.5), "2.5"),
        (-4, "-4"),
        (.number(1e20), "1e+20"),
        (.number(-1e300), "-1e+300"),
        (true, "Yes"),
        (false, "No"),
        (["a", 1, "b"], "a, b"),
    ]

    static let unrenderableValues: [JSONValue] = [.null, [:], [], [1, 2]]

    static let notSingleChoiceForms: [[AgentQuestion.Field]] = [
        [],
        [field("sizes", kind: .multiChoice(sizes))],
        [field("name")],
        [field("color", kind: .choice(colors)), field("name")],
        [field("color", kind: .choice(colors)), field("shade", kind: .choice(colors))],
    ]

    static let numberCases: [(String, Bool, JSONValue?)] = [
        ("42", true, 42),
        ("42", false, 42),
        (" 7 ", true, 7),
        ("-3", true, -3),
        ("4.0", true, 4),
        ("2.5", false, .number(2.5)),
        ("2.5", true, nil),
        ("abc", false, nil),
        ("", true, nil),
        ("1,000", false, nil),
    ]
}

// MARK: - Parsing

struct AgentQuestionParsingTests {
    @Test func linkQuestionKeepsItsURLElicitationAndToolCall() throws {
        let url = try #require(URL(string: "https://linear.app/oauth"))
        let question = try #require(AgentQuestion.parse(id: 9, params: [
            "mode": "url", "message": "Sign in to Linear", "url": "https://linear.app/oauth",
            "elicitationId": "e1", "toolCallId": "t9",
        ]))
        #expect(question.mode == .url(url, elicitationID: "e1"))
        #expect(question.message == "Sign in to Linear")
        #expect(question.toolCallID == "t9")
        #expect(question.fields.isEmpty, "A link question has no form fields")
    }

    @Test(arguments: ["https://example.com", "http://example.com/path?q=1", "HTTPS://EXAMPLE.COM/"])
    func webLinksAreOffered(link: String) throws {
        let url = try #require(URL(string: link))
        let question = AgentQuestion.parse(id: 1, params: ["mode": "url", "url": .string(link)])
        #expect(question?.mode == .url(url, elicitationID: nil),
                "\(link) should be offered as a link, with no elicitation id when none is sent")
    }

    @Test(.tags(.agentQuestionEdgeCase),
          arguments: ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/file", "sandshell://open",
                      "example.com/no-scheme", ""])
    func nonWebLinksAreRefused(link: String) {
        #expect(AgentQuestion.parse(id: 1, params: ["mode": "url", "url": .string(link)]) == nil,
                "Only http(s) links are offered, not \(link)")
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: [.null, 42, true, ["https://example.com"]] as [JSONValue])
    func linkThatIsNotAStringIsRefused(raw: JSONValue) {
        #expect(AgentQuestion.parse(id: 1, params: ["mode": "url", "url": raw]) == nil,
                "A url of \(raw) is not a link")
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func linkQuestionWithoutALinkIsRefused() {
        #expect(AgentQuestion.parse(id: 1, params: ["mode": "url", "message": "Sign in"]) == nil,
                "A link question with no url is refused rather than shown as a form")
    }

    @Test func missingMessageGetsAGenericOne() throws {
        let question = try #require(AgentQuestion.parse(id: 1, params: ["mode": "form"]))
        #expect(question.message == "The agent has a question.")
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: [[:], "nonsense", ["mode": "weird", "message": 5]] as [JSONValue])
    func paramsWithoutASchemaParseAsAnEmptyForm(params: JSONValue) throws {
        let question = try #require(AgentQuestion.parse(id: 1, params: params))
        #expect(question.mode == .form)
        #expect(question.fields.isEmpty)
        #expect(question.message == "The agent has a question.")
        #expect(question.toolCallID == nil)
    }

    @Test(arguments: AQFixture.rpcIDs)
    func idIsTheCompactJSONOfTheRPCID(rpcID: JSONValue, expected: String) throws {
        let question = try #require(AgentQuestion.parse(id: rpcID, params: ["message": "Hi"]))
        #expect(question.rpcID == rpcID)
        #expect(question.id == expected)
    }

    @Test(arguments: AQFixture.kindCases)
    func fieldKindFollowsTheSchema(spec: JSONValue, kind: AgentQuestion.Field.Kind) throws {
        let question = try #require(AQFixture.parseForm(["answer": spec]))
        try #require(question.fields.count == 1, "\(spec) should make exactly one field")
        #expect(question.fields[0].kind == kind)
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: AQFixture.unsupportedSpecs)
    func unsupportedFieldsAreLeftOut(spec: JSONValue) throws {
        let question = try #require(AQFixture.parseForm(["answer": spec, "name": ["type": "string"]]))
        #expect(question.fields.map(\.id) == ["name"], "\(spec) should not make a field")
    }

    @Test func fieldCarriesTitleDetailRequiredAndDefault() throws {
        let question = try #require(AQFixture.parseForm([
            "name": ["type": "string", "title": "Name", "description": "Your name", "default": "Ada"],
            "age": ["type": "integer"],
        ], required: ["name"]))
        let name = try #require(question.fields.first { $0.id == "name" })
        let age = try #require(question.fields.first { $0.id == "age" })
        #expect(name.title == "Name")
        #expect(name.detail == "Your name")
        #expect(name.required)
        #expect(name.defaultValue == .string("Ada"))
        #expect(name.companionOf == nil)
        #expect(age.title == nil)
        #expect(age.detail == nil)
        #expect(age.required == false)
        #expect(age.defaultValue == nil)
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func nonStringRequiredEntriesAreIgnored() throws {
        let schema: JSONValue = [
            "properties": ["a": ["type": "string"], "b": ["type": "string"]],
            "required": [1, "b", .null],
        ]
        let question = try #require(AgentQuestion.parse(id: 1, params: ["requestedSchema": schema]))
        #expect(question.fields.map(\.id) == ["b", "a"], "Only the string entry orders the fields")
        #expect(question.fields.map(\.required) == [true, false], "Only the string entry makes a field required")
    }

    @Test func oneOfOptionsKeepTheirTitleDetailAndPreview() throws {
        let question = try #require(AQFixture.parseForm(["color": ["type": "string", "oneOf": [
            ["const": "red", "title": "Red", "description": "Warm"],
            ["const": "blue", "_meta": ["_claude/askUserQuestionOption": ["preview": "#00f"]]],
        ]]]))
        let field = try #require(question.fields.first)
        #expect(field.kind == .choice([
            AgentQuestion.Option(value: "red", title: "Red", detail: "Warm", preview: nil),
            AgentQuestion.Option(value: "blue", title: "blue", detail: nil, preview: "#00f"),
        ]), "An option without a title is titled by its value")
    }

    @Test func anyOfIsReadWhenThereIsNoOneOf() throws {
        let question = try #require(AQFixture.parseForm(["size": ["type": "string", "anyOf": [
            ["const": "s", "title": "Small"], ["const": "l", "title": "Large"],
        ]]]))
        let field = try #require(question.fields.first)
        #expect(field.kind == .choice([AQFixture.option("s", title: "Small"), AQFixture.option("l", title: "Large")]))
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func nonStringConstsBecomeTheirJSONTextAndMissingConstsAreDropped() throws {
        let question = try #require(AQFixture.parseForm(["pick": ["type": "string", "oneOf": [
            ["const": 1, "title": "One"], ["const": true], ["title": "No const"],
        ]]]))
        let field = try #require(question.fields.first)
        #expect(field.kind == .choice([AQFixture.option("1", title: "One"), AQFixture.option("true")]))
    }

    @Test func enumNamesTitleTheEnumValues() throws {
        let question = try #require(AQFixture.parseForm(["size": [
            "type": "string", "enum": ["s", "m", "l"], "enumNames": ["Small", "Medium"],
        ]]))
        let field = try #require(question.fields.first)
        #expect(field.kind == .choice([AQFixture.option("s", title: "Small"), AQFixture.option("m", title: "Medium"),
                                       AQFixture.option("l")]), "A value without a name is titled by itself")
    }

    @Test func claudeQuestionsComeInOrderEachFollowedByItsOtherBox() throws {
        let question = try #require(AQFixture.claudeQuestion())
        #expect(question.fields.map(\.id) == ["question_0", "question_0_custom", "question_1", "question_1_custom"],
                "Keys arrive out of order; each question is followed by its Other box")
        #expect(question.questions.map(\.id) == ["question_0", "question_1"])
        #expect(question.id == "7")
        #expect(question.toolCallID == "t1")
        #expect(question.mode == .form)

        try #require(question.questions.count == 2)
        let color = question.questions[0]
        #expect(color.title == "Color")
        #expect(color.detail == "Which color?")
        #expect(color.kind == .choice([AQFixture.option("Red", detail: "Warm"), AQFixture.option("Blue", preview: "#00f")]))
        #expect(question.companion(of: color)?.id == "question_0_custom")

        let sizes = question.questions[1]
        #expect(sizes.kind == .multiChoice([AQFixture.option("S"), AQFixture.option("L")]))
        #expect(question.companion(of: sizes)?.id == "question_1_custom")
    }

    @Test func codexQuestionsFollowTheRequiredOrder() throws {
        let question = try #require(AQFixture.codexQuestion())
        #expect(question.fields.map(\.id) == ["zeta", "zeta_note", "alpha"],
                "The required list orders the questions, not their keys; the note box follows its question")
        #expect(question.questions.map(\.id) == ["zeta", "alpha"])
        #expect(question.questions.allSatisfy { $0.required })
        #expect(question.id == "\"c1\"")

        try #require(question.questions.count == 2)
        let zeta = question.questions[0]
        let alpha = question.questions[1]
        #expect(zeta.kind == .choice([AQFixture.option("Yes"), AQFixture.option("No")]))
        #expect(alpha.kind == .text(secret: true))
        #expect(question.companion(of: zeta)?.id == "zeta_note")
        #expect(question.companion(of: zeta)?.required == false)
        #expect(question.companion(of: alpha) == nil)
    }

    @Test func requiredKeysComeFirstThenTheRestInNaturalOrder() throws {
        let question = try #require(AQFixture.parseForm([
            "beta": ["type": "string"], "alpha": ["type": "string"], "zeta": ["type": "string"],
            "aardvark": ["type": "boolean"],
        ], required: ["zeta", "alpha"]))
        #expect(question.fields.map(\.id) == ["zeta", "alpha", "aardvark", "beta"],
                "Required keys in their listed order, then the rest alphabetically")
    }

    @Test func numberedKeysSortNumerically() throws {
        let question = try #require(AQFixture.parseForm([
            "question_10": ["type": "string"], "question_2": ["type": "string"],
            "question_1": ["type": "string"], "question_2_custom": ["type": "string"],
        ]))
        #expect(question.fields.map(\.id) == ["question_1", "question_2", "question_2_custom", "question_10"],
                "question_10 sorts after question_2, and each Other box follows its question")
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func customSuffixWithoutItsQuestionIsAQuestionOfItsOwn() throws {
        let question = try #require(AQFixture.parseForm(["notes_custom": ["type": "string"]]))
        let field = try #require(question.fields.first)
        #expect(field.companionOf == nil)
        #expect(question.questions.map(\.id) == ["notes_custom"])
    }

    @Test(arguments: AQFixture.customAnswerMetas)
    func customAnswerMarkersMakeAnOtherBox(meta: JSONValue) throws {
        let question = try #require(AQFixture.parseForm([
            "pick": ["type": "string", "enum": ["a", "b"]],
            "extra": ["type": "string", "_meta": meta],
        ]))
        let pick = try #require(question.questions.first)
        #expect(question.questions.map(\.id) == ["pick"], "\(meta) should hide the box from the questions")
        #expect(question.companion(of: pick)?.id == "extra")
        #expect(question.fields.map(\.id) == ["pick", "extra"])
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: AQFixture.notCustomAnswerMetas)
    func incompleteCustomAnswerMarkersAreIgnored(meta: JSONValue) throws {
        let question = try #require(AQFixture.parseForm([
            "pick": ["type": "string", "enum": ["a", "b"]],
            "extra": ["type": "string", "_meta": meta],
        ]))
        #expect(question.questions.map(\.id) == ["extra", "pick"], "\(meta) should not make an Other box")
        #expect(question.fields.allSatisfy { $0.companionOf == nil })
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func codexQuestionIDWinsOverTheCustomSuffix() throws {
        let question = try #require(AQFixture.parseForm([
            "pick": ["type": "string"], "other": ["type": "string"],
            "pick_custom": ["type": "string", "_meta": ["codex": ["questionId": "other"]]],
        ]))
        let box = try #require(question.fields.first { $0.id == "pick_custom" })
        #expect(box.companionOf == "other")
        #expect(question.fields.map(\.id) == ["other", "pick_custom", "pick"])
    }
}

// MARK: - Answers

struct AgentQuestionAnswerTests {
    @Test(arguments: AQFixture.answerResults)
    func answerResultIsTheElicitationReply(answer: AgentQuestion.Answer, expected: JSONValue) {
        #expect(answer.result == expected)
    }
}

// MARK: - Summary

struct AgentQuestionSummaryTests {
    @Test(arguments: AQFixture.closingAnswers)
    func skippingOrDismissingNamesTheQuestion(answer: AgentQuestion.Answer, expected: String) {
        let question = AQFixture.form([AQFixture.field("q")], message: "Pick one.")
        #expect(question.summary(of: answer) == expected)
    }

    @Test func openingALinkNamesItsHost() throws {
        let url = try #require(URL(string: "https://linear.app/oauth?state=x"))
        let question = AQFixture.link(url, message: "Sign in to Linear")
        #expect(question.summary(of: .accept([:])) == "Opened linear.app — Sign in to Linear")
        #expect(question.summary(of: .accept(["ignored": "x"])) == "Opened linear.app — Sign in to Linear",
                "A link's summary doesn't depend on content")
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func linkWithoutAHostShowsTheWholeLink() throws {
        let url = try #require(URL(string: "mailto:someone@example.com"))
        let question = AQFixture.link(url, message: "Write to us")
        #expect(question.summary(of: .accept([:])) == "Opened mailto:someone@example.com — Write to us")
    }

    @Test func acceptingNothingSaysAnswered() {
        let question = AQFixture.form([AQFixture.field("q", kind: .choice(AQFixture.colors))], message: "Pick one.")
        #expect(question.summary(of: .accept([:])) == "Answered: Pick one.")
    }

    @Test(arguments: AQFixture.singleUntitledAnswers)
    func singleUntitledQuestionReadsAsMessageAndAnswer(detail: String?, answer: String, expected: String) {
        let question = AQFixture.form([AQFixture.field("q", detail: detail)], message: "Your answer?")
        #expect(question.summary(of: .accept(["q": .string(answer)])) == expected,
                "The label (detail or message) is left out, and colons in the answer survive")
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func colonInTheLabelDoesNotLeakIntoASingleAnswer() {
        let question = AQFixture.form([AQFixture.field("q", detail: "Which one: red or blue?",
                                                       kind: .choice(AQFixture.colors))], message: "Pick a color.")
        withKnownIssue("summary(of:) strips the label off a single untitled question by splitting the line at its first colon, so a colon in the question's detail (or message) leaks part of the label into the answer: \"Pick a color. — red or blue?: Red\"") {
            #expect(question.summary(of: .accept(["q": "Red"])) == "Pick a color. — Red")
        }
    }

    @Test func titledQuestionIsListed() {
        let question = AQFixture.form([AQFixture.field("q", title: "Color", kind: .choice(AQFixture.colors))],
                                      message: "Pick a color.")
        #expect(question.summary(of: .accept(["q": "Red"])) == "Pick a color.\n• Color: Red")
    }

    @Test func severalQuestionsAreListedInOrderWithTheirOtherBoxes() throws {
        let question = try #require(AQFixture.claudeQuestion())
        let summary = question.summary(of: .accept(["question_0": "Blue", "question_1": ["S", "L"], "question_1_custom": "XL"]))
        #expect(summary == "Please answer the following questions.\n• Color: Blue\n• Sizes: S, L, XL")
    }

    @Test func labelsFallBackToDetailThenKey() {
        let question = AQFixture.form([AQFixture.field("first", detail: "First thing?"), AQFixture.field("second")],
                                      message: "Two things.")
        #expect(question.summary(of: .accept(["first": "a", "second": "b"])) == "Two things.\n• First thing?: a\n• second: b")
    }

    @Test func unansweredQuestionsAreLeftOutOfTheList() {
        let question = AQFixture.form([AQFixture.field("first", title: "First"), AQFixture.field("second", title: "Second")],
                                      message: "Two things.")
        #expect(question.summary(of: .accept(["second": "b"])) == "Two things.\n• Second: b")
    }

    @Test(arguments: AQFixture.renderedValues)
    func answerValuesAreRendered(value: JSONValue, rendered: String) {
        let question = AQFixture.form([AQFixture.field("q", title: "Answer")], message: "Q?")
        #expect(question.summary(of: .accept(["q": value])) == "Q?\n• Answer: \(rendered)")
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: AQFixture.unrenderableValues)
    func valuesWithNothingToShowAreLeftOut(value: JSONValue) {
        let question = AQFixture.form([AQFixture.field("q", title: "Answer")], message: "Q?")
        #expect(question.summary(of: .accept(["q": value])) == "Answered: Q?")
    }

    @Test func secretAnswersAreMasked() {
        let question = AQFixture.form([AQFixture.field("token", title: "Token", kind: .text(secret: true))], message: "Q?")
        let summary = question.summary(of: .accept(["token": "hunter2"]))
        #expect(summary == "Q?\n• Token: ••••")
        #expect(summary.contains("hunter2") == false, "The secret itself must not reach the transcript")
    }

    @Test(arguments: AQFixture.otherBoxAnswers)
    func otherBoxIsAppendedToItsQuestion(content: [String: JSONValue], expected: String) {
        let question = AQFixture.form([AQFixture.field("color", title: "Color", kind: .choice(AQFixture.colors)),
                                       AQFixture.field("color_custom", companionOf: "color")], message: "Q?")
        #expect(question.summary(of: .accept(content)) == expected,
                "The Other box joins its question's line; an empty one adds nothing, and alone it still answers")
    }

    @Test func otherBoxAloneAnswersASingleUntitledQuestion() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors)),
                                       AQFixture.field("color_custom", companionOf: "color")], message: "Q?")
        #expect(question.summary(of: .accept(["color_custom": "Maroon"])) == "Q? — Maroon")
    }
}

// MARK: - Form

@MainActor
struct AgentQuestionFormTests {
    @Test func defaultsFillTheForm() {
        let question = AQFixture.form([
            AQFixture.field("color", kind: .choice(AQFixture.colors), defaultValue: "Blue"),
            AQFixture.field("sizes", kind: .multiChoice(AQFixture.sizes), defaultValue: ["S", "L"]),
            AQFixture.field("name", defaultValue: "Ada"),
            AQFixture.field("count", kind: .number(integer: true), defaultValue: 3),
            AQFixture.field("ratio", kind: .number(integer: false), defaultValue: .number(2.5)),
            AQFixture.field("agree", kind: .toggle, defaultValue: true),
        ])
        let (form, _) = AQFixture.makeForm(question)
        #expect(form.picks == ["color": "Blue"])
        #expect(form.multiPicks == ["sizes": Set(["S", "L"])])
        #expect(form.texts == ["name": "Ada", "count": "3", "ratio": "2.5"], "Whole numbers show without a decimal point")
        #expect(form.toggles == ["agree": true])
        #expect(form.previewed.isEmpty)
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: [(1e20, "1e+20"), (-1e300, "-1e+300"), (4.0, "4")])
    func numberDefaultsPastIntsRangeKeepTheirSpelling(value: Double, shown: String) {
        let question = AQFixture.form([AQFixture.field("n", kind: .number(integer: false), defaultValue: .number(value))])
        let (form, _) = AQFixture.makeForm(question)
        #expect(form.texts["n"] == shown, "A whole number Int can't hold is shown, not trapped on")
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func defaultsOfTheWrongTypeAreIgnored() {
        let question = AQFixture.form([
            AQFixture.field("color", kind: .choice(AQFixture.colors), defaultValue: 1),
            AQFixture.field("shade", kind: .choice(AQFixture.colors), defaultValue: .null),
            AQFixture.field("sizes", kind: .multiChoice(AQFixture.sizes), defaultValue: "S"),
            AQFixture.field("name", defaultValue: true),
            AQFixture.field("count", kind: .number(integer: true), defaultValue: "3"),
            AQFixture.field("agree", kind: .toggle, defaultValue: "yes"),
        ])
        let (form, _) = AQFixture.makeForm(question)
        #expect(form.picks.isEmpty)
        #expect(form.multiPicks.isEmpty)
        #expect(form.texts.isEmpty)
        #expect(form.toggles.isEmpty)
    }

    @Test func applyingDefaultsAgainRestoresThem() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors), defaultValue: "Blue")])
        let (form, _) = AQFixture.makeForm(question)
        form.picks["color"] = "Red"
        form.applyDefaults()
        #expect(form.picks["color"] == "Blue")
    }

    @Test func singleChoiceQuestionOffersItsOptions() throws {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors)),
                                       AQFixture.field("color_custom", companionOf: "color")])
        let (form, _) = AQFixture.makeForm(question)
        let (field, options) = try #require(form.singleChoice, "An Other box doesn't count as a second question")
        #expect(field.id == "color")
        #expect(options == AQFixture.colors)
    }

    @Test(arguments: AQFixture.notSingleChoiceForms)
    func otherShapesHaveNoSingleChoice(fields: [AgentQuestion.Field]) {
        let (form, _) = AQFixture.makeForm(AQFixture.form(fields))
        #expect(form.singleChoice?.0 == nil, "\(fields.map(\.id)) is not a single choice question")
    }

    @Test func pickingByNumberSelectsAndPreviewsTheOption() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors))])
        let (form, _) = AQFixture.makeForm(question)
        form.pick(1)
        #expect(form.picks["color"] == "Blue")
        #expect(form.previewed["color"] == AQFixture.colors[1])
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: [-1, 3, 99])
    func pickingOutOfRangeChangesNothing(index: Int) {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors))])
        let (form, _) = AQFixture.makeForm(question)
        form.pick(index)
        #expect(form.picks.isEmpty, "Option \(index) doesn't exist among \(AQFixture.colors.count)")
        #expect(form.previewed.isEmpty)
    }

    @Test func pickingWithSeveralQuestionsChangesNothing() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors)),
                                       AQFixture.field("shade", kind: .choice(AQFixture.colors))])
        let (form, _) = AQFixture.makeForm(question)
        form.pick(0)
        #expect(form.picks.isEmpty)
        #expect(form.previewed.isEmpty)
    }

    @Test func choiceValueIsThePick() {
        let field = AQFixture.field("color", kind: .choice(AQFixture.colors))
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        #expect(form.value(field) == nil, "Nothing picked yet")
        form.picks["color"] = "Red"
        #expect(form.value(field) == .string("Red"))
    }

    @Test func multiChoiceValueFollowsTheOptionOrder() {
        let field = AQFixture.field("sizes", kind: .multiChoice(AQFixture.sizes))
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        form.multiPicks["sizes"] = ["L", "S", "XXL"]
        #expect(form.value(field) == .array(["S", "L"]), "Picks come back in option order, unknown values dropped")
    }

    @Test func emptyMultiChoiceHasNoValue() {
        let field = AQFixture.field("sizes", kind: .multiChoice(AQFixture.sizes))
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        #expect(form.value(field) == nil)
        form.multiPicks["sizes"] = []
        #expect(form.value(field) == nil)
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func multiChoiceOfOnlyUnknownValuesIsUnanswered() {
        let field = AQFixture.field("sizes", kind: .multiChoice(AQFixture.sizes), required: true, defaultValue: ["XL"])
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        withKnownIssue("value(_:) only treats an empty pick set as unanswered: picks that match no option (e.g. a default outside the options) yield .array([]), so a required multi-choice counts as answered and submits an empty list") {
            #expect(form.value(field) == nil)
            #expect(form.canSubmit == false)
        }
    }

    @Test(arguments: [("  Ada  ", "Ada"), ("\nAda\n", "Ada"), ("Ada Lovelace", "Ada Lovelace")])
    func textValueIsTrimmed(typed: String, expected: String) {
        let field = AQFixture.field("name")
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        form.texts["name"] = typed
        #expect(form.value(field) == .string(expected))
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: ["", "   ", "\n\t "])
    func blankTextHasNoValue(typed: String) {
        let field = AQFixture.field("name")
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        form.texts["name"] = typed
        #expect(form.value(field) == nil)
    }

    @Test(arguments: AQFixture.numberCases)
    func numberValueIsParsed(typed: String, integer: Bool, expected: JSONValue?) {
        let field = AQFixture.field("n", kind: .number(integer: integer))
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        form.texts["n"] = typed
        #expect(form.value(field) == expected)
    }

    @Test(.tags(.agentQuestionEdgeCase), arguments: [("inf", false), ("-infinity", false), ("nan", false), ("inf", true)])
    func nonFiniteNumbersHaveNoValue(typed: String, integer: Bool) {
        let field = AQFixture.field("n", kind: .number(integer: integer))
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        form.texts["n"] = typed
        withKnownIssue("value(_:) accepts anything Double(_:) parses, including \"inf\" and \"nan\": JSON can't carry them (JSONEncoder throws) and summary(of:) traps on Int(Double.infinity)") {
            #expect(form.value(field) == nil)
        }
    }

    @Test func toggleValueDefaultsToOff() {
        let field = AQFixture.field("agree", kind: .toggle)
        let (form, _) = AQFixture.makeForm(AQFixture.form([field]))
        #expect(form.value(field) == .bool(false))
        form.toggles["agree"] = true
        #expect(form.value(field) == .bool(true))
    }

    @Test func linkQuestionCanAlwaysBeSubmitted() throws {
        let url = try #require(URL(string: "https://linear.app/oauth"))
        let (form, _) = AQFixture.makeForm(AQFixture.link(url))
        #expect(form.canSubmit)
    }

    @Test func optionalFieldsDoNotBlockSubmitting() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors)), AQFixture.field("name")])
        let (form, _) = AQFixture.makeForm(question)
        #expect(form.canSubmit)
    }

    @Test func requiredChoiceNeedsAPick() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors), required: true)])
        let (form, _) = AQFixture.makeForm(question)
        #expect(form.canSubmit == false)
        form.pick(0)
        #expect(form.canSubmit)
    }

    @Test func otherBoxAnswersARequiredChoice() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors), required: true),
                                       AQFixture.field("color_custom", companionOf: "color")])
        let (form, _) = AQFixture.makeForm(question)
        form.texts["color_custom"] = "Maroon"
        #expect(form.canSubmit)
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func blankOtherBoxDoesNotAnswerARequiredChoice() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors), required: true),
                                       AQFixture.field("color_custom", companionOf: "color")])
        let (form, _) = AQFixture.makeForm(question)
        form.texts["color_custom"] = "   "
        #expect(form.canSubmit == false)
    }

    @Test(arguments: AQFixture.requiredTypedFields)
    func requiredTypedFieldNeedsAUsableValue(kind: AgentQuestion.Field.Kind, unusable: String, usable: String) {
        let question = AQFixture.form([AQFixture.field("answer", kind: kind, required: true)])
        let (form, _) = AQFixture.makeForm(question)
        form.texts["answer"] = unusable
        #expect(form.canSubmit == false, "\(unusable.debugDescription) doesn't answer a required \(kind) field")
        form.texts["answer"] = usable
        #expect(form.canSubmit, "\(usable.debugDescription) answers a required \(kind) field")
    }

    @Test(.tags(.agentQuestionEdgeCase))
    func requiredToggleIsAlwaysAnswered() {
        let question = AQFixture.form([AQFixture.field("agree", kind: .toggle, required: true)])
        let (form, _) = AQFixture.makeForm(question)
        #expect(form.canSubmit, "An untouched toggle answers No")
    }

    @Test func submittingSendsEveryAnsweredField() {
        let question = AQFixture.form([
            AQFixture.field("color", kind: .choice(AQFixture.colors), required: true),
            AQFixture.field("color_custom", companionOf: "color"),
            AQFixture.field("notes"),
            AQFixture.field("count", kind: .number(integer: true)),
            AQFixture.field("agree", kind: .toggle),
        ])
        let (form, log) = AQFixture.makeForm(question)
        form.picks["color"] = "Red"
        form.texts["color_custom"] = "  Maroon "
        form.texts["notes"] = "   "
        form.texts["count"] = "many"
        form.submit()
        let expected: [AgentQuestion.Answer] = [.accept(["color": "Red", "color_custom": "Maroon", "agree": false])]
        #expect(log.answers == expected,
                "Blank text and unparseable numbers are left out; toggles always answer")
    }

    @Test func submittingAnUnfinishedFormSendsNothing() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors), required: true)])
        let (form, log) = AQFixture.makeForm(question)
        form.submit()
        #expect(log.answers.isEmpty)
    }

    @Test func submittingALinkQuestionAccepts() throws {
        let url = try #require(URL(string: "https://linear.app/oauth"))
        let (form, log) = AQFixture.makeForm(AQFixture.link(url))
        form.submit()
        #expect(log.answers == [AgentQuestion.Answer.accept([:])])
    }

    @Test func skippingDeclinesEvenWhenUnfinished() {
        let question = AQFixture.form([AQFixture.field("color", kind: .choice(AQFixture.colors), required: true)])
        let (form, log) = AQFixture.makeForm(question)
        form.skip()
        #expect(log.answers == [AgentQuestion.Answer.decline])
    }

    @Test func claudeSingleQuestionIsAnsweredByNumber() throws {
        let question = try #require(AgentQuestion.parse(id: 3, params: [
            "mode": "form", "toolCallId": "t3", "message": "Please answer the following questions.",
            "requestedSchema": ["type": "object", "properties": [
                "question_0": ["type": "string", "title": "Color", "oneOf": [["const": "Red"], ["const": "Blue"]]],
                "question_0_custom": ["type": "string", "title": "Other"],
            ]]]))
        let (form, log) = AQFixture.makeForm(question)
        form.pick(1)
        form.submit()
        let answer = try #require(log.answers.first)
        #expect(log.answers.count == 1)
        #expect(answer == AgentQuestion.Answer.accept(["question_0": "Blue"]))
        #expect(question.summary(of: answer) == "Please answer the following questions.\n• Color: Blue")
    }

    @Test func codexQuestionIsAnsweredAndSummarizedWithoutItsSecret() throws {
        let question = try #require(AQFixture.codexQuestion())
        let (form, log) = AQFixture.makeForm(question)
        #expect(form.canSubmit == false, "Both questions are required")
        form.picks["zeta"] = "Yes"
        form.texts["alpha"] = " secret-token "
        #expect(form.canSubmit)
        form.submit()
        let answer = try #require(log.answers.first)
        #expect(log.answers.count == 1)
        #expect(answer == AgentQuestion.Answer.accept(["zeta": "Yes", "alpha": "secret-token"]))
        #expect(question.summary(of: answer) == "Codex needs your input to continue.\n• Proceed?: Yes\n• API token?: ••••")
    }
}
