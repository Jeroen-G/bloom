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

/// Permission options for OpenCode.
public enum OpenCodePermissionOption: String, Sendable, Hashable, CaseIterable {
    case allow
    case deny
    case allowOnce
    case allowSession
    case cancel

    public var label: String {
        switch self {
        case .allow: "Allow"
        case .deny: "Deny"
        case .allowOnce: "Allow once"
        case .allowSession: "Allow for this session"
        case .cancel: "Cancel"
        }
    }
}

public enum OpenCodePermission {
    /// Builds a Bloom PermissionAsk from an OpenCode permission request.
    public static func ask(for request: OpenCodeServerRequest, connectionID: UUID) -> PermissionAsk {
        let permissionRequest = OpenCodePermissionRequest.decode(request.params) ?? 
            OpenCodePermissionRequest(
                id: request.id,
                sessionID: request.params["sessionId"]?.stringValue ?? "",
                action: request.params["action"]?.stringValue ?? "",
                description: request.params["description"]?.stringValue ?? "",
                toolUseId: request.params["toolUseId"]?.stringValue,
                raw: request.params
            )
        
        let subject: String
        if !permissionRequest.description.isEmpty {
            subject = permissionRequest.description
        } else if !permissionRequest.action.isEmpty {
            subject = permissionRequest.action
        } else {
            subject = "OpenCode permission request"
        }
        
        return PermissionAsk(
            requestID: permissionRequest.id.turnID,
            toolUseID: permissionRequest.toolUseId ?? permissionRequest.id.turnID,
            kind: .openCodePermission,
            subject: subject,
            raw: request.raw,
            connectionID: connectionID
        )
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
            case .always:
                return .object(["status": .string("allowed"), "scope": .string("always")])
            }
        case .deny:
            return deniedResult
        case .answer:
            // For input requests, include the answer
            return .object(["status": .string("provided")])
        case .cancel:
            return cancelledResult
        }
    }

    /// Extract option ID for a decision from a permission request.
    public static func optionID(for decision: PermissionDecision, in request: OpenCodeServerRequest) -> String? {
        // Map Bloom's PermissionDecision to OpenCode's permission options
        switch decision {
        case .allow:
            return "allow"
        case .deny:
            return "deny"
        case .answer:
            return "provide"
        case .cancel:
            return "cancel"
        }
    }
}

/// Extensions for PermissionAsk to support OpenCode.
public extension PermissionAsk {
    /// Whether this is an OpenCode permission request.
    var isOpenCodePermission: Bool {
        kind == .openCodePermission
    }
}

public extension PermissionAskKind {
    static var openCodePermission: PermissionAskKind {
        PermissionAskKind(rawValue: "opencode") ?? .unknown
    }
}
