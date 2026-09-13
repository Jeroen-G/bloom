import Foundation

/// Turns OpenCode's ACP updates into the vocabulary Bloom already stores and draws.
public struct OpenCodeTranslation: Sendable {
    public struct Context: Sendable, Hashable {
        public var model: String
        public var cwd: String
        public var permissionMode: String
        public var version: String

        public init(model: String = "", cwd: String = "", permissionMode: String = "", version: String = "") {
            self.model = model
            self.cwd = cwd
            self.permissionMode = permissionMode
            self.version = version
        }
    }

    public var context: Context
    public private(set) var usage = AgentUsage()
    public private(set) var sessionID = ""

    private var text = ""
    private var thought = ""
    private var tools: [String: OpenCodeToolCall] = [:]
    private var textMessageID = ""
    private var thoughtMessageID = ""

    public init(context: Context = Context()) {
        self.context = context
    }

    /// The key the raw ACP tool call is carried under, and the marker that says a row is an OpenCode one.
    public static let itemKey = "opencodeItem"

    public static func isOpenCodeCall(_ input: JSONValue) -> Bool {
        input[itemKey] != nil
    }

    /// The name an OpenCode tool is filed under in Bloom's existing presenters.
    public static func toolName(for call: OpenCodeToolCall) -> String {
        let raw = call.toolName.isEmpty ? call.title : call.toolName
        switch raw {
        case "read_file", "Read": return "Read"
        case "write_file", "Write": return "Write"
        case "search_replace", "str_replace", "Edit": return "Edit"
        case "run_terminal_cmd", "bash", "shell", "Bash": return "Bash"
        case "grep", "Grep": return "Grep"
        case "glob_file_search", "glob", "Glob": return "Glob"
        case "list_dir": return "Glob"
        case "web_search", "WebSearch": return "WebSearch"
        case "web_fetch", "WebFetch": return "WebFetch"
        case "todo_write", "TodoWrite": return "TodoWrite"
        case "spawn_subagent", "Agent", "Task": return "Task"
        default:
            if raw.hasPrefix("mcp__") { return raw }
            return raw.isEmpty ? "OpenCode.\(call.kind.isEmpty ? "tool" : call.kind)" : raw
        }
    }

    /// Lift OpenCode's `path` onto `file_path` so `PermissionAsk.subject` and `AgentToolUse.filePath` work.
    public static func input(for call: OpenCodeToolCall) -> JSONValue {
        var members = call.rawInput.objectValue ?? [:]
        if members["file_path"] == nil {
            if let path = members["path"] {
                members["file_path"] = path
            } else if !call.path.isEmpty {
                members["file_path"] = .string(call.path)
            }
        }
        if members["command"] == nil, let command = members["cmd"] {
            members["command"] = command
        }
        if members["query"] == nil, let query = members["search_term"] ?? members["pattern"] {
            members["query"] = query
        }
        members[itemKey] = call.json
        return .object(members)
    }

    // MARK: - Translating

    public mutating func translate(_ event: OpenCodeEvent) -> [AgentEvent] {
        switch event {
        case .sessionUpdate(let update):
            let updateSessionID = update.params["sessionId"]?.stringValue ?? ""
            if !updateSessionID.isEmpty { sessionID = updateSessionID }
            return updateEvents(update)

        case .promptResponse(let result):
            if !result.sessionID.isEmpty { sessionID = result.sessionID }
            var events = flushOpenBlocks()
            events.append(.result(self.result(for: result)))
            tools.removeAll()
            return events

        case .promptError(_, let error):
            return finishInterruptedTurn()
                + [.error(AgentError(message: error.message, raw: Self.errorLine(message: error.message)))]

        case .permissionRequest, .unknownServerRequest, .sessionStatus, .sessionEnded, .unknownNotification:
            return []
        }
    }

    /// Translate a session ready event (from newSession/resumeSession).
    public mutating func translateSessionReady(_ session: OpenCodeSession) -> [AgentEvent] {
        sessionID = session.id
        if !session.currentModelID.isEmpty { context.model = session.currentModelID }
        return [.initialized(AgentInit(
            sessionID: session.id,
            cwd: context.cwd,
            model: context.model,
            permissionMode: context.permissionMode,
            agentKind: .openCode,
            version: context.version,
            raw: Self.initLine(sessionID: session.id, context: context)
        ))]
    }

    /// An interrupted turn might never send its completion. Keep its partial answer in its own
    /// row before another prompt arrives, and discard tool state belonging to that turn.
    public mutating func finishInterruptedTurn() -> [AgentEvent] {
        let events = flushOpenBlocks()
        tools.removeAll()
        return events
    }

    private mutating func updateEvents(_ update: OpenCodeServerNotification) -> [AgentEvent] {
        let params = update.params
        
        // Check for text content
        if let content = params["content"] {
            if let textChunk = content.stringValue, !textChunk.isEmpty {
                var events = flushThought()
                if text.isEmpty { textMessageID = UUID().uuidString }
                text += textChunk
                events.append(.streamDelta(.text(textChunk)))
                return events
            }
        }
        
        // Check for thinking content
        if let thinking = params["thinking"] {
            if let thoughtChunk = thinking.stringValue, !thoughtChunk.isEmpty {
                if thought.isEmpty { thoughtMessageID = UUID().uuidString }
                thought += thoughtChunk
                return [.streamDelta(.thinking(thoughtChunk))]
            }
        }
        
        // Check for tool calls
        if let toolCalls = params["toolCalls"]?.arrayValue {
            var events: [AgentEvent] = []
            for toolCallValue in toolCalls {
                if let toolCall = OpenCodeToolCall.decode(toolCallValue) {
                    tools[toolCall.id] = merged(toolCall, onto: tools[toolCall.id])
                    let stored = tools[toolCall.id] ?? toolCall
                    let input = Self.input(for: stored)
                    let name = Self.toolName(for: stored)
                    let block = JSONValue.object([
                        "type": .string("tool_use"),
                        "id": .string(stored.id),
                        "name": .string(name),
                        "input": input,
                    ])
                    events.append(.toolUse(AgentToolUse(
                        id: stored.id,
                        name: name,
                        input: input,
                        raw: Self.assistantLine(
                            blocks: [block],
                            messageID: stored.id,
                            model: context.model,
                            usage: usage,
                            sessionID: sessionID
                        ),
                        messageID: stored.id,
                        sessionID: sessionID
                    )))
                    if stored.isFinished {
                        events.append(contentsOf: toolResult(for: stored))
                    }
                }
            }
            return events
        }
        
        // Check for usage updates
        if let usageUpdate = params["usage"] {
            if let inputTokens = usageUpdate["inputTokens"]?.intValue {
                usage.inputTokens = inputTokens
            }
            if let outputTokens = usageUpdate["outputTokens"]?.intValue {
                usage.outputTokens = outputTokens
            }
            if let contextTokens = usageUpdate["contextTokens"]?.intValue {
                usage.contextTokens = contextTokens
            }
        }
        
        return []
    }

    private mutating func flushOpenBlocks() -> [AgentEvent] {
        flushThought() + flushText()
    }

    private mutating func flushText() -> [AgentEvent] {
        let finished = text
        text = ""
        guard !finished.isEmpty else { return [] }
        let messageID = textMessageID
        textMessageID = ""
        return [.assistantText(AgentTextBlock(
            text: finished,
            raw: Self.assistantLine(
                blocks: [.object(["type": .string("text"), "text": .string(finished)])],
                messageID: messageID,
                model: context.model,
                usage: usage,
                sessionID: sessionID
            ),
            messageID: messageID,
            model: context.model,
            usage: usage,
            sessionID: sessionID
        ))]
    }

    private mutating func flushThought() -> [AgentEvent] {
        let finished = thought
        thought = ""
        guard !finished.isEmpty else { return [] }
        let messageID = thoughtMessageID
        thoughtMessageID = ""
        return [.thinking(AgentTextBlock(
            text: finished,
            raw: Self.assistantLine(
                blocks: [.object(["type": .string("thinking"), "thinking": .string(finished)])],
                messageID: messageID,
                model: context.model,
                usage: usage,
                sessionID: sessionID
            ),
            messageID: messageID,
            model: context.model,
            usage: usage,
            sessionID: sessionID
        ))]
    }

    private func toolResult(for call: OpenCodeToolCall) -> [AgentEvent] {
        let text = call.contentText.isEmpty
            ? (call.rawOutput.stringValue ?? call.rawOutput.prettyPrinted)
            : call.contentText
        let display = text == "null" ? "" : text
        return [.toolResult(AgentToolResult(
            toolUseID: call.id,
            text: display,
            isError: call.isError,
            refusal: call.status == "cancelled" ? .denied : nil,
            raw: Self.toolResultLine(
                toolUseID: call.id,
                text: display,
                isError: call.isError,
                refusalKind: call.status == "cancelled" ? "user-rejected" : nil,
                sessionID: sessionID
            ),
            sessionID: sessionID
        ))]
    }

    private func merged(_ incoming: OpenCodeToolCall, onto existing: OpenCodeToolCall?) -> OpenCodeToolCall {
        guard let existing else { return incoming }
        return OpenCodeToolCall(
            id: incoming.id.isEmpty ? existing.id : incoming.id,
            title: incoming.title.isEmpty ? existing.title : incoming.title,
            kind: incoming.kind.isEmpty ? existing.kind : incoming.kind,
            status: incoming.status.isEmpty ? existing.status : incoming.status,
            toolName: incoming.toolName.isEmpty ? existing.toolName : incoming.toolName,
            rawInput: incoming.rawInput.objectValue?.isEmpty == false ? incoming.rawInput : existing.rawInput,
            rawOutput: incoming.rawOutput.isNull ? existing.rawOutput : incoming.rawOutput,
            contentText: incoming.contentText.isEmpty ? existing.contentText : incoming.contentText,
            path: incoming.path.isEmpty ? existing.path : incoming.path,
            json: incoming.json
        )
    }

    private func result(for prompt: OpenCodePromptResult) -> AgentResult {
        let summary = prompt.isError ? prompt.raw["message"]?.stringValue ?? "" : ""
        let subtype = prompt.wasCancelled ? "error_during_execution"
            : prompt.isError ? prompt.stopReason
            : "success"
        return AgentResult(
            usage: usage,
            summary: summary,
            isError: prompt.isError,
            subtype: subtype,
            durationMS: 0,
            numTurns: 1,
            stopReason: prompt.stopReason,
            raw: Self.resultLine(
                subtype: subtype,
                isError: prompt.isError,
                summary: summary,
                durationMS: 0,
                usage: usage,
                model: context.model,
                sessionID: sessionID
            ),
            sessionID: sessionID
        )
    }

    // MARK: - Envelopes

    static func assistantLine(
        blocks: [JSONValue],
        messageID: String,
        model: String,
        usage: AgentUsage,
        sessionID: String
    ) -> Data {
        line(.object([
            "type": .string("assistant"),
            "session_id": .string(sessionID),
            "message": .object([
                "id": .string(messageID),
                "model": .string(model),
                "role": .string("assistant"),
                "content": .array(blocks),
                "usage": encode(usage),
            ]),
        ]))
    }

    static func toolResultLine(
        toolUseID: String,
        text: String,
        isError: Bool,
        refusalKind: String?,
        sessionID: String
    ) -> Data {
        var members: [String: JSONValue] = [
            "type": .string("user"),
            "session_id": .string(sessionID),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(toolUseID),
                    "content": .string(text),
                    "is_error": .bool(isError),
                ])]),
            ]),
        ]
        if let refusalKind {
            members["tool_result_meta"] = .array([.object([
                "id": .string(toolUseID),
                "non_execution_kind": .string(refusalKind),
            ])])
        }
        return line(.object(members))
    }

    static func resultLine(
        subtype: String,
        isError: Bool,
        summary: String,
        durationMS: Int,
        usage: AgentUsage,
        model: String,
        sessionID: String
    ) -> Data {
        var result: [String: JSONValue] = [
            "type": .string("result"),
            "subtype": .string(subtype),
            "is_error": .bool(isError),
            "result": .string(summary),
            "duration_ms": .integer(durationMS),
            "num_turns": .integer(1),
            "session_id": .string(sessionID),
            "usage": encode(usage),
        ]
        if usage.contextTokens > 0 {
            result["modelUsage"] = .object([
                model: .object(["contextWindow": .integer(usage.contextTokens)]),
            ])
        }
        return line(.object(result))
    }

    static func initLine(sessionID: String, context: Context) -> Data {
        line(.object([
            "type": .string("system"),
            "subtype": .string("init"),
            "session_id": .string(sessionID),
            "cwd": .string(context.cwd),
            "model": .string(context.model),
            "permissionMode": .string(context.permissionMode),
            "agent_kind": .string(AgentKind.openCode.rawValue),
        ]))
    }

    static func errorLine(message: String) -> Data {
        line(.object([
            "type": .string("error"),
            "subtype": .string("opencode"),
            "stderr": .string(message),
        ]))
    }

    static func encode(_ usage: AgentUsage) -> JSONValue {
        .object([
            "input_tokens": .integer(usage.inputTokens),
            "output_tokens": .integer(usage.outputTokens),
            "cache_read_input_tokens": .integer(usage.cacheReadTokens),
            "cache_creation_input_tokens": .integer(usage.cacheCreationTokens),
            "output_tokens_details": .object(["thinking_tokens": .integer(usage.thinkingTokens)]),
        ])
    }

    static func line(_ json: JSONValue) -> Data {
        Data(json.compactJSON.utf8)
    }
}

// MARK: - Supporting Types

public struct OpenCodeToolCall: Sendable, Hashable {
    public let id: String
    public let title: String
    public let kind: String
    public let status: String
    public let toolName: String
    public let rawInput: JSONValue
    public let rawOutput: JSONValue
    public let contentText: String
    public let path: String
    public let json: JSONValue

    public var isFinished: Bool {
        status == "completed" || status == "cancelled" || status == "error"
    }

    public var isError: Bool {
        status == "error"
    }

    public init(
        id: String = "",
        title: String = "",
        kind: String = "",
        status: String = "",
        toolName: String = "",
        rawInput: JSONValue = .null,
        rawOutput: JSONValue = .null,
        contentText: String = "",
        path: String = "",
        json: JSONValue = .null
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.toolName = toolName
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.contentText = contentText
        self.path = path
        self.json = json
    }

    public static func decode(_ value: JSONValue) -> OpenCodeToolCall? {
        guard case .object(let object) = value else { return nil }
        
        return OpenCodeToolCall(
            id: object["id"]?.stringValue ?? "",
            title: object["title"]?.stringValue ?? "",
            kind: object["kind"]?.stringValue ?? "",
            status: object["status"]?.stringValue ?? "",
            toolName: object["toolName"]?.stringValue ?? "",
            rawInput: object["input"] ?? .null,
            rawOutput: object["output"] ?? .null,
            contentText: object["contentText"]?.stringValue ?? "",
            path: object["path"]?.stringValue ?? "",
            json: value
        )
    }
}

public struct OpenCodePromptResult: Sendable {
    public let requestID: OpenCodeRequestID
    public let sessionID: String
    public let stopReason: String
    public let raw: JSONValue

    public var isError: Bool {
        stopReason == "refusal" || stopReason == "error"
    }

    public var wasCancelled: Bool {
        stopReason == "cancelled"
    }

    public init(
        requestID: OpenCodeRequestID,
        sessionID: String = "",
        stopReason: String = "end_turn",
        raw: JSONValue = .null
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.stopReason = stopReason
        self.raw = raw
    }
}

/// Extensions for OpenCodeEvent to support translation.
extension OpenCodeEvent {
    /// Extract session ID from the event if available.
    var sessionID: String {
        switch self {
        case .promptResponse(let result):
            return result.sessionID
        case .sessionUpdate(let notification):
            return notification.params["sessionId"]?.stringValue ?? ""
        case .sessionStatus(let notification):
            return notification.params["sessionId"]?.stringValue ?? ""
        case .sessionEnded(let notification):
            return notification.params["sessionId"]?.stringValue ?? ""
        default:
            return ""
        }
    }

    /// Whether this event contains session update content.
    var isSessionUpdate: Bool {
        switch self {
        case .sessionUpdate: true
        default: false
        }
    }

    /// Whether this event represents session readiness.
    static func sessionReady(_ session: OpenCodeSession) -> OpenCodeEvent {
        // This is a synthetic event for translation purposes
        // In practice, session readiness comes from newSession/resumeSession responses
        return .sessionUpdate(OpenCodeServerNotification(
            method: "session/ready",
            params: .object([
                "sessionId": .string(session.id),
                "currentModelID": .string(session.currentModelID),
            ])
        ))
    }
}
