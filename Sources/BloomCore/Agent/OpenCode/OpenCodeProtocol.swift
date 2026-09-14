import Foundation

/// The wire vocabulary of `opencode acp`, which speaks ACP as JSON-RPC 2.0 over stdio.
///
/// ## Why this protocol
///
/// OpenCode v2 supports the Agent Client Protocol (ACP) via `opencode acp`,
/// which is JSON-RPC 2.0 over stdio with newline-delimited JSON. This is the same protocol
/// class as Grok's `grok agent --no-leader stdio` and Codex's `codex app-server --listen stdio://`.
///
/// ACP standardizes communication between code editors and AI coding agents, providing:
///   * Session management (new, load, resume, fork)
///   * Streaming updates via notifications
///   * Permission requests (server-to-client)
///   * Tool execution tracking
///   * MCP server integration
///
/// ## Frame classification
///
/// Frame classification is the JSON-RPC one, never by id: `method` plus `id` is a request,
/// `method` alone a notification, `result` or `error` a response. Request ids on this wire can be
/// numbers or strings, and both must be supported.
///
/// ## OpenCode v2 specifics
///
/// OpenCode v2 implements ACP v1 (stable). Key capabilities advertised:
///   * loadSession: true - supports session resume
///   * fork: true - supports session forking
///   * resume: true - supports session resumption
///   * mcpCapabilities: serverVariables support
///
/// Reference: https://opencode.ai/docs/acp/
public enum OpenCodeRequestID: Sendable, Hashable, Codable {
    case number(Int)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    /// The JSON literal for this id, ready to drop into a hand-built frame.
    var jsonLiteral: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): JSONValue.string(value).compactJSON
        }
    }

    /// The turn handle's id for this request. Distinct from the ACP session id, which is stable
    /// across turns and must not be reused as a turn id.
    var turnID: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): value
        }
    }

    init?(_ json: JSONValue?) {
        switch json {
        case .integer(let value): self = .number(value)
        case .string(let value): self = .text(value)
        default: return nil
        }
    }
}

/// The `error` member of a failed response. `data` is kept whole because the server puts
/// structured detail there that no Bloom release has to understand in advance.
public struct OpenCodeRPCError: Sendable, Hashable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Everything that can go wrong on this connection that is not the server saying no.
public enum OpenCodeClientError: Sendable, Error, Equatable {
    /// The process ended, or was told to end, while requests were still outstanding.
    case connectionClosed(String)
    /// A reply arrived in a shape the caller could not use.
    case unexpectedResult(method: String)
    /// The handshake did not complete, so nothing else may be sent.
    case notInitialized
    /// The server accepted a request and never answered it.
    case timedOut(method: String, seconds: Int)
}

extension OpenCodeClientError: CustomStringConvertible {
    /// A person-facing account of a transport failure. RPC method names remain in diagnostics,
    /// where they are useful, rather than leaking into the transcript as implementation detail.
    public var description: String {
        switch self {
        case .connectionClosed(let reason):
            reason.isEmpty
                ? "The connection to OpenCode closed"
                : "The connection to OpenCode closed: \(reason)"
        case .unexpectedResult:
            "OpenCode returned a response Bloom could not read"
        case .notInitialized:
            "Bloom could not connect to OpenCode"
        case .timedOut(let method, _):
            switch method {
            case "session/load":
                "OpenCode did not respond while reopening this conversation"
            case "session/new":
                "OpenCode did not respond while starting this conversation"
            case "session/prompt":
                "OpenCode did not accept the message in time"
            default:
                "OpenCode did not respond in time"
            }
        }
    }
}

/// Server-to-client request from OpenCode. These are requests that OpenCode sends to Bloom
/// and expects a response to, such as permission requests.
public struct OpenCodeServerRequest: Sendable, Hashable {
    public let id: OpenCodeRequestID
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(id: OpenCodeRequestID, method: String, params: JSONValue, raw: Data = Data()) {
        self.id = id
        self.method = method
        self.params = params
        self.raw = raw
    }
}

/// Server-to-client notification from OpenCode. These are one-way messages that do not
/// expect a response, such as streaming session updates.
public struct OpenCodeServerNotification: Sendable, Hashable {
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(method: String, params: JSONValue, raw: Data = Data()) {
        self.method = method
        self.params = params
        self.raw = raw
    }
}

/// One decoded line off the OpenCode ACP server.
///
/// Nothing here throws. A line that is not JSON comes back as `.malformed` with its bytes intact,
/// because the server writes tracing to stderr and a future release could write something new to
/// stdout, and neither may end a session.
public enum OpenCodeFrame: Sendable, Hashable {
    /// Response to a request we sent
    case response(id: OpenCodeRequestID, result: JSONValue, raw: Data)
    /// Error response to a request we sent
    case failure(id: OpenCodeRequestID, error: OpenCodeRPCError, raw: Data)
    /// Request from server to client (e.g., permission request)
    case request(OpenCodeServerRequest)
    /// Notification from server (e.g., session/update)
    case notification(OpenCodeServerNotification)
    /// Line that could not be parsed as JSON
    case malformed(Data)

    /// Decode a single line of JSON from the ACP transport.
    ///
    /// Frame classification: `method` plus `id` is a request, `method` alone a notification,
    /// `result` or `error` a response. This matches the JSON-RPC 2.0 specification.
    public static func decode(line: String) -> OpenCodeFrame? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let raw = Data(line.utf8)
        guard let json = JSONValue.parse(raw), case .object = json else { return .malformed(raw) }

        let id = OpenCodeRequestID(json["id"])
        let params = json["params"] ?? .object([:])

        // If it has a method, it's either a request (with id) or notification (without id)
        if let method = json["method"]?.stringValue {
            if let id {
                return .request(OpenCodeServerRequest(id: id, method: method, params: params, raw: raw))
            }
            return .notification(OpenCodeServerNotification(method: method, params: params, raw: raw))
        }

        // If it has result or error, it's a response
        guard let id else { return .malformed(raw) }

        if let error = json["error"] {
            return .failure(
                id: id,
                error: OpenCodeRPCError(
                    code: error["code"]?.intValue ?? 0,
                    message: error["message"]?.stringValue ?? "",
                    data: error["data"]
                ),
                raw: raw
            )
        }

        // A `result` of JSON null is a perfectly good success
        guard case .object(let object) = json, object.keys.contains("result") else {
            return .malformed(raw)
        }
        return .response(id: id, result: object["result"] ?? .null, raw: raw)
    }
}

// MARK: - Outgoing frames

/// Builds the lines Bloom writes to the OpenCode ACP server's stdin.
public enum OpenCodeOutgoing {
    /// JSON-RPC version to send
    static let version = "2.0"

    /// Build a request from client to server
    public static func request(id: OpenCodeRequestID, method: String, params: JSONValue?) -> String {
        var members = ["\"jsonrpc\":\"\(version)\"", "\"id\":\(id.jsonLiteral)"]
        members.append("\"method\":\(JSONValue.string(method).compactJSON)")
        if let params { members.append("\"params\":\(params.compactJSON)") }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// Build a notification from client to server (no response expected)
    public static func notification(method: String, params: JSONValue?) -> String {
        var members = ["\"jsonrpc\":\"\(version)\""]
        members.append("\"method\":\(JSONValue.string(method).compactJSON)")
        if let params { members.append("\"params\":\(params.compactJSON)") }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// Build a response to a server-to-client request (e.g., permission approval)
    public static func response(id: OpenCodeRequestID, result: JSONValue) -> String {
        "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"result\":\(result.compactJSON)}"
    }

    /// Build an error response to a server-to-client request
    public static func failure(id: OpenCodeRequestID, code: Int, message: String) -> String {
        let error = JSONValue.object([
            "code": .integer(code),
            "message": .string(message),
        ])
        return "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"error\":\(error.compactJSON)}"
    }
}
