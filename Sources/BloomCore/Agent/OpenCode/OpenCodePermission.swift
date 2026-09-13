import Foundation

/// Permission request from OpenCode ACP.
///
/// This is sent by OpenCode when it needs approval for an action (file read, command execution, etc.).
public struct OpenCodePermissionRequest: Sendable, Hashable {
    public let id: OpenCodeRequestID
    public let sessionID: String
    public let action: String
    public let description: String
    public let toolUseId: String?
    public let raw: JSONValue

    public init(
        id: OpenCodeRequestID,
        sessionID: String = "",
        action: String = "",
        description: String = "",
        toolUseId: String? = nil,
        raw: JSONValue = .null
    ) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.description = description
        self.toolUseId = toolUseId
        self.raw = raw
    }

    /// Decode a permission request from JSON.
    public static func decode(_ json: JSONValue) -> OpenCodePermissionRequest? {
        guard case .object(let object) = json else { return nil }
        
        let id = OpenCodeRequestID(json["id"])
        let sessionID = object["sessionId"]?.stringValue ?? ""
        let action = object["action"]?.stringValue ?? ""
        let description = object["description"]?.stringValue ?? ""
        let toolUseId = object["toolUseId"]?.stringValue
        
        return OpenCodePermissionRequest(
            id: id ?? .number(0),
            sessionID: sessionID,
            action: action,
            description: description,
            toolUseId: toolUseId,
            raw: json
        )
    }
}

/// OpenCode's `session/request_permission`, in the vocabulary Bloom's permission prompt already
/// speaks.
///
/// ACP sends an action plus a description and a set of booleans (`allow_once`, `allow_always`,
/// `reject_once`, `reject_always`). Bloom's prompt is allow once / session / project and deny, so
/// the options are matched onto that rather than drawn as a fourth UI. An `allow_always` option is
/// what makes the persistent grant available; without one, `suppressesAlwaysAllow` is set and the
/// prompt will not offer a rule Bloom could not honour on the wire.
public enum OpenCodePermission {
    /// Builds a Bloom PermissionAsk from an OpenCode permission request.
    public static func ask(for request: OpenCodeServerRequest, connectionID: UUID = UUID()) -> PermissionAsk {
        let decoded = OpenCodePermissionRequest.decode(request.params)
        let permissionRequest = OpenCodePermissionRequest(
            id: OpenCodeRequestID(request.params["id"]) ?? request.id,
            sessionID: decoded?.sessionID ?? request.params["sessionId"]?.stringValue ?? "",
            action: decoded?.action ?? request.params["action"]?.stringValue ?? "",
            description: decoded?.description ?? request.params["description"]?.stringValue ?? "",
            toolUseId: decoded?.toolUseId ?? request.params["toolUseId"]?.stringValue,
            raw: request.params
        )

        let toolUseID = permissionRequest.toolUseId ?? permissionRequest.id.turnID
        let toolCall = OpenCodeToolCall(
            id: toolUseID,
            title: permissionRequest.action,
            kind: "",
            status: "pending",
            toolName: permissionRequest.action,
            rawInput: request.params,
            rawOutput: .null,
            contentText: permissionRequest.description,
            path: request.params["path"]?.stringValue ?? "",
            json: request.params
        )
        let name = OpenCodeTranslation.toolName(for: toolCall)
        let input = OpenCodeTranslation.input(for: toolCall)
        let allowsAlways = options(in: request.params)["allow_always"] ?? false

        let ask = PermissionAsk(
            requestID: permissionRequest.id.turnID,
            toolName: name,
            displayName: permissionRequest.action,
            toolUseID: toolUseID,
            input: input,
            summary: permissionRequest.description.isEmpty
                ? permissionRequest.action
                : permissionRequest.description,
            reason: "",
            reasonType: "permissionPromptTool",
            blockedPath: request.params["path"]?.stringValue,
            suggestions: allowsAlways ? [PermissionSuggestion(
                type: "addRules",
                behavior: "allow",
                destination: PermissionDestination.session.rawValue,
                rules: [PermissionRule(toolName: name, ruleContent: ruleContent(for: toolCall))],
                raw: .object([:])
            )] : [],
            suppressesAlwaysAllow: !allowsAlways,
            raw: Data()
        )
        // Rebuilt with its own bytes, because those bytes are what the database keeps and what a
        // workspace reopened mid question is redrawn from. The envelope has to be in the shape
        // `PermissionAsk.decode(payload:)` reads, which is a `control_request`, not a JSON-RPC
        // request: one vocabulary in the store, whichever backend wrote the row.
        return ask.with(raw: envelope(for: ask))
    }

    /// The stored form of a question. A faithful `can_use_tool` control request, carrying
    /// everything the ask holds, so decoding it gives the same value back.
    public static func envelope(for ask: PermissionAsk) -> Data {
        let json = JSONValue.object(omittingNil: [
            "type": .string("control_request"),
            "request_id": .string(ask.requestID),
            // Says which backend wrote this, for anything reading rows rather than events. The
            // decoder ignores it, which is the point: an extra member costs nothing.
            "agent_kind": .string(AgentKind.openCode.rawValue),
            "request": .object(omittingNil: [
                "subtype": .string("can_use_tool"),
                "tool_name": .string(ask.toolName),
                "display_name": ask.displayName.isEmpty ? nil : .string(ask.displayName),
                "tool_use_id": .string(ask.toolUseID),
                "input": ask.input,
                "description": .string(ask.summary),
                "decision_reason_type": .string(ask.reasonType),
                "blocked_path": ask.blockedPath.map(JSONValue.string),
                "suppress_always_allow_rule": .bool(ask.suppressesAlwaysAllow),
                "permission_suggestions": .array(ask.suggestions.map { suggestion in
                    .object([
                        "type": .string(suggestion.type),
                        "behavior": .string(suggestion.behavior),
                        "destination": .string(suggestion.destination),
                        "rules": .array(suggestion.rules.map { rule in
                            .object(omittingNil: [
                                "toolName": .string(rule.toolName),
                                "ruleContent": rule.ruleContent.map(JSONValue.string),
                            ])
                        }),
                    ])
                }),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    /// The option Bloom should send back for this decision, or nil when the agent did not offer
    /// one that means that. A missing option is answered as cancelled rather than as a guessed
    /// allow: inventing an `optionId` the agent did not list is how a deny becomes an allow.
    public static func optionID(for decision: PermissionDecision, in request: OpenCodeServerRequest) -> String? {
        let options = self.options(in: request.params)
        let offered = { (kind: String) in options[kind] ?? false }
        let wanted: [String]
        switch decision {
        case .allow(.once), .answer, .approvePlan:
            wanted = ["allow_once"]
        case .allow(.session), .allow(.project):
            wanted = ["allow_always", "allow_once"]
        case .deny(_, let endsTurn):
            wanted = endsTurn ? ["reject_always", "reject_once"] : ["reject_once", "reject_always"]
        }
        for kind in wanted where offered(kind) { return kind }
        return nil
    }

    /// Result for cancelled permission requests.
    public static var cancelledResult: JSONValue {
        .object(["status": .string("cancelled")])
    }

    /// Result for denied permission requests.
    public static var deniedResult: JSONValue {
        .object(["status": .string("denied")])
    }

    /// Result for allowed permission requests.
    public static var allowedResult: JSONValue {
        .object(["status": .string("allowed")])
    }

    /// Result for selected permission option.
    public static func selectedResult(optionID: String) -> JSONValue {
        .object(["status": .string("approved"), "optionId": .string(optionID)])
    }

    /// Maps Bloom's PermissionDecision to OpenCode's permission response.
    public static func response(for decision: PermissionDecision, request: OpenCodeServerRequest) -> JSONValue {
        switch decision {
        case .allow(let scope):
            switch scope {
            case .once:
                return .object(["status": .string("allowed"), "scope": .string("once")])
            case .session:
                return .object(["status": .string("allowed"), "scope": .string("session")])
            case .project:
                return .object(["status": .string("allowed"), "scope": .string("always")])
            }
        case .deny:
            return deniedResult
        case .answer:
            // For input requests, include the answer
            return .object(["status": .string("provided")])
        case .approvePlan:
            return allowedResult
        }
    }

    /// The booleans OpenCode sent under `options`, defaulting to false when a key is missing.
    private static func options(in params: JSONValue) -> [String: Bool] {
        (params["options"]?.objectValue ?? [:]).compactMapValues { $0.boolValue }
    }

    private static func ruleContent(for call: OpenCodeToolCall) -> String? {
        let input = OpenCodeTranslation.input(for: call)
        if let command = input["command"]?.stringValue, !command.isEmpty { return command }
        if !call.path.isEmpty { return call.path }
        return nil
    }
}