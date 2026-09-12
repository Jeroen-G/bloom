import Testing
import BloomCore

/// Tests for OpenCode ACP protocol implementation.
struct OpenCodeProtocolTests {
    @Test
    func requestIDNumberEncoding() {
        let id = OpenCodeRequestID.number(42)
        #expect(id.jsonLiteral == "42")
        #expect(id.turnID == "42")
    }

    @Test
    func requestIDTextEncoding() {
        let id = OpenCodeRequestID.text("abc-123")
        #expect(id.jsonLiteral == "\"abc-123\"")
        #expect(id.turnID == "abc-123")
    }

    @Test
    func requestIDDecodingFromInt() throws {
        let json = "42"
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let id = try decoder.decode(OpenCodeRequestID.self, from: data)
        #expect(id == .number(42))
    }

    @Test
    func requestIDDecodingFromString() throws {
        let json = "\"test-id\""
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let id = try decoder.decode(OpenCodeRequestID.self, from: data)
        #expect(id == .text("test-id"))
    }

    @Test
    func frameDecodingResponse() {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"test"}}"#
        let frame = OpenCodeFrame.decode(line: json)
        
        switch frame {
        case .response(let id, let result, _):
            #expect(id == .number(1))
            #expect(result["sessionId"]?.stringValue == "test")
        default:
            Issue.record("Expected response frame")
        }
    }

    @Test
    func frameDecodingNotification() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"content":"test"}}"#
        let frame = OpenCodeFrame.decode(line: json)
        
        switch frame {
        case .notification(let notification):
            #expect(notification.method == "session/update")
            #expect(notification.params["content"]?.stringValue == "test")
        default:
            Issue.record("Expected notification frame")
        }
    }

    @Test
    func frameDecodingRequest() {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{}}"#
        let frame = OpenCodeFrame.decode(line: json)
        
        switch frame {
        case .request(let request):
            #expect(request.id == .number(1))
            #expect(request.method == "session/request_permission")
        default:
            Issue.record("Expected request frame")
        }
    }

    @Test
    func frameDecodingError() {
        let json = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#
        let frame = OpenCodeFrame.decode(line: json)
        
        switch frame {
        case .failure(let id, let error, _):
            #expect(id == .number(1))
            #expect(error.code == -32601)
            #expect(error.message == "Method not found")
        default:
            Issue.record("Expected failure frame")
        }
    }

    @Test
    func frameDecodingMalformed() {
        let json = "not valid json"
        let frame = OpenCodeFrame.decode(line: json)
        
        switch frame {
        case .malformed:
            // Expected
            break
        default:
            Issue.record("Expected malformed frame")
        }
    }

    @Test
    func outgoingRequest() {
        let request = OpenCodeOutgoing.request(
            id: .number(1),
            method: "session/new",
            params: .object(["cwd": .string("/test")])
        )
        
        #expect(request.contains("\"jsonrpc\":\"2.0\""))
        #expect(request.contains("\"id\":1"))
        #expect(request.contains("\"method\":\"session/new\""))
        #expect(request.contains("\"cwd\":\"/test\""))
    }

    @Test
    func outgoingNotification() {
        let notification = OpenCodeOutgoing.notification(
            method: "initialized",
            params: .object([:])
        )
        
        #expect(notification.contains("\"jsonrpc\":\"2.0\""))
        #expect(notification.contains("\"method\":\"initialized\""))
    }

    @Test
    func outgoingResponse() {
        let response = OpenCodeOutgoing.response(
            id: .number(1),
            result: .object(["status": .string("ok")])
        )
        
        #expect(response.contains("\"id\":1"))
        #expect(response.contains("\"result\""))
    }

    @Test
    func outgoingFailure() {
        let failure = OpenCodeOutgoing.failure(
            id: .number(1),
            code: -32601,
            message: "Method not found"
        )
        
        #expect(failure.contains("\"id\":1"))
        #expect(failure.contains("\"error\""))
        #expect(failure.contains("\"code\":-32601"))
    }
}

// MARK: - OpenCodeClient Tests

/// Tests for OpenCodeClient session management.
struct OpenCodeClientTests {
    @Test
    func sessionParamsIncludesCWD() {
        let params = OpenCodeClient.sessionParams(
            sessionID: nil,
            cwd: "/test/path",
            mcpServers: nil,
            permissionMode: .auto
        )
        
        #expect(params["cwd"]?.stringValue == "/test/path")
    }

    @Test
    func sessionParamsIncludesSessionID() {
        let params = OpenCodeClient.sessionParams(
            sessionID: "test-session",
            cwd: "/test/path",
            mcpServers: nil,
            permissionMode: .auto
        )
        
        #expect(params["sessionId"]?.stringValue == "test-session")
    }

    @Test
    func sessionParamsIncludesPermissionMode() {
        let params = OpenCodeClient.sessionParams(
            sessionID: nil,
            cwd: "/test/path",
            mcpServers: nil,
            permissionMode: .bypassPermissions
        )
        
        let meta = params["_meta"]?.objectValue ?? [:]
        #expect(meta["yoloMode"]?.boolValue == true)
        #expect(meta["permissionMode"]?.stringValue == "bypassPermissions")
    }

    @Test
    func sessionParamsIncludesMCPServers() {
        let params = OpenCodeClient.sessionParams(
            sessionID: nil,
            cwd: "/test/path",
            mcpServers: ["mcp": .string("test")],
            permissionMode: .auto
        )
        
        let mcp = params["mcpServers"]?.objectValue ?? [:]
        #expect(mcp["mcp"]?.stringValue == "test")
    }
}

// MARK: - OpenCodeSession Tests

/// Tests for OpenCodeSession.
struct OpenCodeSessionTests {
    @Test
    func sessionDecode() {
        let json: JSONValue = .object([
            "sessionId": .string("test-session"),
            "currentModelID": .string("openai/gpt-4")
        ])
        
        let session = OpenCodeSession.decode(json)
        
        #expect(session?.id == "test-session")
        #expect(session?.currentModelID == "openai/gpt-4")
    }

    @Test
    func sessionDecodeMissingID() {
        let json: JSONValue = .object([
            "currentModelID": .string("openai/gpt-4")
        ])
        
        let session = OpenCodeSession.decode(json)
        
        #expect(session == nil)
    }

    @Test
    func sessionDecodeFromIDField() {
        let json: JSONValue = .object([
            "id": .string("test-session"),
            "currentModelID": .string("openai/gpt-4")
        ])
        
        let session = OpenCodeSession.decode(json)
        
        #expect(session?.id == "test-session")
    }
}

// MARK: - OpenCodeTranslation Tests

/// Tests for OpenCodeTranslation.
struct OpenCodeTranslationTests {
    @Test
    func toolNameMapping() {
        let toolCall = OpenCodeToolCall(
            id: "1",
            title: "",
            kind: "",
            status: "",
            toolName: "read_file",
            rawInput: .null,
            rawOutput: .null,
            contentText: "",
            path: "",
            json: .null
        )
        
        let name = OpenCodeTranslation.toolName(for: toolCall)
        #expect(name == "Read")
    }

    @Test
    func toolNamePassthrough() {
        let toolCall = OpenCodeToolCall(
            id: "1",
            title: "",
            kind: "",
            status: "",
            toolName: "custom_tool",
            rawInput: .null,
            rawOutput: .null,
            contentText: "",
            path: "",
            json: .null
        )
        
        let name = OpenCodeTranslation.toolName(for: toolCall)
        #expect(name == "custom_tool")
    }

    @Test
    func toolNameFromTitle() {
        let toolCall = OpenCodeToolCall(
            id: "1",
            title: "Write",
            kind: "",
            status: "",
            toolName: "",
            rawInput: .null,
            rawOutput: .null,
            contentText: "",
            path: "",
            json: .null
        )
        
        let name = OpenCodeTranslation.toolName(for: toolCall)
        #expect(name == "Write")
    }

    @Test
    func inputPathMapping() {
        let toolCall = OpenCodeToolCall(
            id: "1",
            title: "",
            kind: "",
            status: "",
            toolName: "read_file",
            rawInput: .object(["path": .string("/test/file.txt")]),
            rawOutput: .null,
            contentText: "",
            path: "",
            json: .null
        )
        
        let input = OpenCodeTranslation.input(for: toolCall)
        #expect(input["file_path"]?.stringValue == "/test/file.txt")
        #expect(input["path"]?.stringValue == "/test/file.txt")
    }

    @Test
    func initLineContainsAgentKind() {
        let context = OpenCodeTranslation.Context(
            model: "gpt-4",
            cwd: "/test",
            permissionMode: "auto",
            version: "1.0"
        )
        
        let line = OpenCodeTranslation.initLine(sessionID: "test", context: context)
        let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        
        #expect(json?["agent_kind"] as? String == "openCode")
        #expect(json?["session_id"] as? String == "test")
    }
}

// MARK: - OpenCodePermission Tests

/// Tests for OpenCodePermission handling.
struct OpenCodePermissionTests {
    @Test
    func permissionAskCreation() {
        let request = OpenCodeServerRequest(
            id: .number(1),
            method: "session/request_permission",
            params: .object([
                "action": .string("read_file"),
                "description": .string("Read /test/file.txt"),
                "toolUseId": .string("tool-1")
            ]),
            raw: Data()
        )
        
        let ask = OpenCodePermission.ask(for: request, connectionID: UUID())
        
        #expect(ask.requestID == "1")
        #expect(ask.toolUseID == "tool-1")
        #expect(ask.subject.contains("Read /test/file.txt"))
    }

    @Test
    func cancelledResult() {
        let result = OpenCodePermission.cancelledResult
        #expect(result["status"]?.stringValue == "cancelled")
    }

    @Test
    func deniedResult() {
        let result = OpenCodePermission.deniedResult
        #expect(result["status"]?.stringValue == "denied")
    }

    @Test
    func allowedResult() {
        let result = OpenCodePermission.allowedResult
        #expect(result["status"]?.stringValue == "allowed")
    }

    @Test
    func selectedResult() {
        let result = OpenCodePermission.selectedResult(optionID: "allow")
        #expect(result["status"]?.stringValue == "approved")
        #expect(result["optionId"]?.stringValue == "allow")
    }

    @Test
    func responseForAllowDecision() {
        let request = OpenCodeServerRequest(
            id: .number(1),
            method: "session/request_permission",
            params: .object(["action": .string("read_file")]),
            raw: Data()
        )
        
        let decision: PermissionDecision = .allow(scope: .session)
        let response = OpenCodePermission.response(for: decision, request: request)
        
        #expect(response["status"]?.stringValue == "allowed")
        #expect(response["scope"]?.stringValue == "session")
    }

    @Test
    func responseForDenyDecision() {
        let request = OpenCodeServerRequest(
            id: .number(1),
            method: "session/request_permission",
            params: .object(["action": .string("read_file")]),
            raw: Data()
        )
        
        let decision: PermissionDecision = .deny(message: "No", endsTurn: false)
        let response = OpenCodePermission.response(for: decision, request: request)
        
        #expect(response["status"]?.stringValue == "denied")
    }

    @Test
    func responseForCancelDecision() {
        let request = OpenCodeServerRequest(
            id: .number(1),
            method: "session/request_permission",
            params: .object(["action": .string("read_file")]),
            raw: Data()
        )
        
        let decision: PermissionDecision = .cancel
        let response = OpenCodePermission.response(for: decision, request: request)
        
        #expect(response["status"]?.stringValue == "cancelled")
    }
}
