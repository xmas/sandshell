import Foundation

/// A question an agent asks mid-turn: ACP `elicitation/create`. Claude Code's
/// AskUserQuestion, Codex's request_user_input and MCP servers' elicitations
/// all arrive this way — a form (JSON Schema of choices and text fields) or a
/// link to open (an MCP server's sign-in).
struct AgentQuestion: Equatable, Identifiable {
    struct Option: Equatable, Hashable {
        let value: String
        let title: String
        let detail: String?
        /// Claude's per-option preview (a mockup or snippet shown on focus).
        let preview: String?
    }

    struct Field: Equatable, Identifiable {
        enum Kind: Equatable {
            case choice([Option])
            case multiChoice([Option])
            case text(secret: Bool)
            case number(integer: Bool)
            case toggle
        }
        let id: String
        let title: String?
        let detail: String?
        let kind: Kind
        let required: Bool
        /// The question this free-text "Other" box belongs to (its key).
        let companionOf: String?
        let defaultValue: JSONValue?
    }

    enum Mode: Equatable {
        case form
        case url(URL, elicitationID: String?)
    }

    let rpcID: JSONValue
    let message: String
    let mode: Mode
    let fields: [Field]
    let toolCallID: String?
    var id: String { rpcID.compactString }

    /// The questions proper (not their "Other" boxes).
    var questions: [Field] { fields.filter { $0.companionOf == nil } }
    func companion(of field: Field) -> Field? { fields.first { $0.companionOf == field.id } }

    // MARK: Parsing

    static func parse(id: JSONValue, params: JSONValue) -> AgentQuestion? {
        let message = params["message"]?.string ?? "The agent has a question."
        let toolCallID = params["toolCallId"]?.string
        if params["mode"]?.string == "url" {
            guard let raw = params["url"]?.string, let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return AgentQuestion(rpcID: id, message: message, mode: .url(url, elicitationID: params["elicitationId"]?.string),
                                 fields: [], toolCallID: toolCallID)
        }
        let schema = params["requestedSchema"]
        let properties = schema?["properties"]?.object ?? [:]
        let required = (schema?["required"]?.array ?? []).compactMap(\.string)
        var fields = properties.compactMap { key, spec in field(key: key, spec: spec, required: required.contains(key),
                                                                 keys: Set(properties.keys)) }
        // JSON objects have no order: the required list does (Codex lists its
        // questions in order), then keys in natural order (question_0, question_0_custom, question_1…).
        fields.sort { a, b in
            let ra = required.firstIndex(of: a.companionOf ?? a.id) ?? .max
            let rb = required.firstIndex(of: b.companionOf ?? b.id) ?? .max
            if ra != rb { return ra < rb }
            let ka = a.companionOf ?? a.id, kb = b.companionOf ?? b.id
            if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
            return a.companionOf == nil && b.companionOf != nil
        }
        return AgentQuestion(rpcID: id, message: message, mode: .form, fields: fields, toolCallID: toolCallID)
    }

    private static func field(key: String, spec: JSONValue, required: Bool, keys: Set<String>) -> Field? {
        let title = spec["title"]?.string
        let detail = spec["description"]?.string
        let meta = spec["_meta"]
        let kind: Field.Kind
        switch spec["type"]?.string {
        case "string":
            let options = options(in: spec)
            kind = options.isEmpty ? .text(secret: meta?["codex"]?["isSecret"]?.bool == true || spec["format"]?.string == "password")
                                   : .choice(options)
        case "array":
            let options = spec["items"].map(options(in:)) ?? []
            guard !options.isEmpty else { return nil }
            kind = .multiChoice(options)
        case "number": kind = .number(integer: false)
        case "integer": kind = .number(integer: true)
        case "boolean": kind = .toggle
        default: return nil
        }
        // An "Other" box: Codex marks its note fields; Claude's are question_<n>_custom.
        var companion = meta?["codex"]?["questionId"]?.string ?? findCustomAnswerTarget(meta)
        if companion == nil, key.hasSuffix("_custom"), keys.contains(String(key.dropLast("_custom".count))) {
            companion = String(key.dropLast("_custom".count))
        }
        return Field(id: key, title: title, detail: detail, kind: kind, required: required,
                     companionOf: companion, defaultValue: spec["default"])
    }

    /// AIR's custom-answer marker, wherever a client finds it.
    private static func findCustomAnswerTarget(_ meta: JSONValue?) -> String? {
        guard let meta else { return nil }
        if let id = meta["questionId"]?.string, meta["isCustomAnswer"]?.bool == true { return id }
        for (_, value) in meta.object ?? [:] {
            if let id = findCustomAnswerTarget(value) { return id }
        }
        return nil
    }

    private static func options(in spec: JSONValue) -> [Option] {
        if let list = spec["oneOf"]?.array ?? spec["anyOf"]?.array {
            return list.compactMap { o in
                guard let value = o["const"]?.string ?? o["const"].map(\.compactString) else { return nil }
                return Option(value: value, title: o["title"]?.string ?? value, detail: o["description"]?.string,
                              preview: o["_meta"]?["_claude/askUserQuestionOption"]?["preview"]?.string)
            }
        }
        let values = (spec["enum"]?.array ?? []).compactMap(\.string)
        let names = (spec["enumNames"]?.array ?? []).compactMap(\.string)
        return values.enumerated().map { i, v in
            Option(value: v, title: names.indices.contains(i) ? names[i] : v, detail: nil, preview: nil)
        }
    }

    // MARK: Answers

    enum Answer: Equatable {
        case accept([String: JSONValue])
        /// Skip: the agent is told nothing was chosen and carries on.
        case decline
        /// Stop: the agent's tool call is abandoned.
        case cancel

        var result: JSONValue {
            switch self {
            case .accept(let content): return ["action": "accept", "content": .object(content)]
            case .decline: return ["action": "decline"]
            case .cancel: return ["action": "cancel"]
            }
        }
    }

    /// What the transcript keeps of the exchange.
    func summary(of answer: Answer) -> String {
        switch answer {
        case .decline: return "Skipped: \(message)"
        case .cancel: return "Dismissed: \(message)"
        case .accept(let content):
            if case .url(let url, _) = mode { return "Opened \(url.host ?? url.absoluteString) — \(message)" }
            let answers = questions.compactMap { q -> (label: String, parts: String)? in
                var parts: [String] = []
                switch content[q.id] {
                case .string(let s)?: parts.append(s)
                case .array(let a)?: parts.append(contentsOf: a.compactMap(\.string))
                case .number(let n)?: parts.append(Self.text(of: n))
                case .bool(let b)?: parts.append(b ? "Yes" : "No")
                default: break
                }
                if case .text(secret: true) = q.kind, !parts.isEmpty { parts = ["••••"] }
                if let other = companion(of: q), case .string(let s)? = content[other.id], !s.isEmpty { parts.append(s) }
                guard !parts.isEmpty else { return nil }
                return (q.title ?? q.detail ?? q.id, parts.joined(separator: ", "))
            }
            if answers.isEmpty { return "Answered: \(message)" }
            // One untitled question: the message says what was asked.
            if questions.count == 1, questions[0].title == nil { return "\(message) — \(answers[0].parts)" }
            return "\(message)\n" + answers.map { "• \($0.label): \($0.parts)" }.joined(separator: "\n")
        }
    }

    /// A number as it's typed: whole ones without ".0" (any size, without trapping).
    static func text(of number: Double) -> String {
        Int(exactly: number).map(String.init) ?? String(number)
    }
}
