import Testing
import Foundation
@testable import BloomCore

/// Tests for OpenCode ACP protocol implementation.
struct OpenCodeWireTests {
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
            mcpServers: [],
            permissionMode: .auto
        )
        
        #expect(params["cwd"]?.stringValue == "/test/path")
    }

    @Test
    func sessionParamsIncludesSessionID() {
        let params = OpenCodeClient.sessionParams(
            sessionID: "test-session",
            cwd: "/test/path",
            mcpServers: [],
            permissionMode: .auto
        )
        
        #expect(params["sessionId"]?.stringValue == "test-session")
    }

    @Test
    func sessionParamsIncludesPermissionMode() {
        let params = OpenCodeClient.sessionParams(
            sessionID: nil,
            cwd: "/test/path",
            mcpServers: [],
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
            mcpServers: [.object(["name": .string("mcp"), "command": .string("test")])],
            permissionMode: .auto
        )
        
        let mcp = params["mcpServers"]?.arrayValue ?? []
        #expect(mcp.count == 1)
        #expect(mcp[0]["name"]?.stringValue == "mcp")
    }

    @Test
    func v2SessionNewAdvertisesModelsFromConfigOptions() async throws {
        // OpenCode v2 names no models in `initialize`; the `session/new` response carries the
        // model list in `configOptions`. Regression test: before this shape was read, the
        // composer's OpenCode section was empty and only Claude Code's built-in list showed.
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([
            "protocolVersion": .integer(1),
            "agentCapabilities": .object([:]),
            "agentInfo": .object(["name": .string("OpenCode"), "version": .string("2.0.3")]),
            "authMethods": .array([]),
        ]))
        box.reply(to: "session/new", with: .object([
            "sessionId": .string("sess-v2"),
            "configOptions": .array([
                .object([
                    "id": .string("model"),
                    "name": .string("Model"),
                    "type": .string("select"),
                    "currentValue": .string("opencode/gpt-5.6-sol"),
                    "options": .array([
                        .object([
                            "value": .string("opencode/gpt-5.6-sol"),
                            "name": .string("opencode/GPT-5.6 Sol (50% Off)"),
                        ]),
                        .object([
                            "value": .string("opencode/gpt-5.5"),
                            "name": .string("opencode/GPT-5.5"),
                        ]),
                    ]),
                ]),
                .object([
                    "id": .string("effort"),
                    "name": .string("Effort"),
                    "type": .string("select"),
                    "currentValue": .string("default"),
                    "options": .array([
                        .object(["value": .string("low"), "name": .string("Low")]),
                        .object(["value": .string("default"), "name": .string("Default")]),
                    ]),
                ]),
            ]),
        ]))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w"),
            makeProcess: box.factory
        )
        try await client.start()
        // v2's initialize response carries no modelState, so nothing is advertised yet.
        #expect(await client.advertisedModels().isEmpty)

        let session = try await client.newSession(cwd: "/tmp/w")
        #expect(session.id == "sess-v2")

        let models = await client.advertisedModels()
        #expect(models.map(\.id) == ["opencode/gpt-5.6-sol", "opencode/gpt-5.5"])
        #expect(models[0].isDefault)
        #expect(models[0].displayName == "GPT-5.6 Sol (50% Off)")
        #expect(models[0].supportedEfforts.map(\.id) == ["low", "default"])
        #expect(models[0].defaultEffort == "default")
        #expect(box.process.sentMethods.contains("session/new"))
        await client.stop()
    }
}

// MARK: - OpenCodeSession Tests

/// Tests for OpenCodeSession.
struct OpenCodeSessionTests {
    @Test
    func sessionDecode() {
        let json: JSONValue = .object([
            "sessionId": .string("test-session"),
            "currentModelId": .string("openai/gpt-4")
        ])
        
        let session = OpenCodeSession.decode(json)
        
        #expect(session?.id == "test-session")
        #expect(session?.currentModelID == "openai/gpt-4")
    }

    @Test
    func sessionDecodeMissingID() {
        let json: JSONValue = .object([
            "currentModelId": .string("openai/gpt-4")
        ])
        
        let session = OpenCodeSession.decode(json)
        
        #expect(session == nil)
    }

    @Test
    func sessionDecodeFromIDField() {
        let json: JSONValue = .object([
            "id": .string("test-session"),
            "currentModelId": .string("openai/gpt-4")
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

    @Test
    func textChunksStreamAndFlushAsAssistantRow() {
        // Regression: OpenCode v2 streams `session/update` notifications with an `update` object
        // discriminating on `sessionUpdate`. Before the typed decode, the translation read flat
        // `params["content"]` and produced nothing, so chat worked but the reply never appeared.
        var translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(model: "gpt-4"))
        let first = translation.translate(.sessionUpdate(OpenCodeSessionUpdate(
            sessionID: "sess-1",
            kind: .text("Hel"),
            raw: .object([:])
        )))
        #expect(first.contains { if case .streamDelta(.text("Hel")) = $0 { return true }; return false })
        let second = translation.translate(.sessionUpdate(OpenCodeSessionUpdate(
            sessionID: "sess-1",
            kind: .text("lo"),
            raw: .object([:])
        )))
        #expect(second.contains { if case .streamDelta(.text("lo")) = $0 { return true }; return false })
        let done = translation.translate(.promptResponse(OpenCodePromptResult(
            requestID: .number(1),
            sessionID: "sess-1",
            stopReason: "end_turn",
            raw: .object(["usage": .object([
                "inputTokens": .integer(9160),
                "outputTokens": .integer(2),
                "totalTokens": .integer(9162),
            ])])
        )))
        let flushed = done.compactMap { event -> String? in
            if case .assistantText(let block) = event { return block.text }
            return nil
        }.first
        #expect(flushed == "Hello")
        #expect(done.contains { if case .result(let result) = $0 { return !result.isError }; return false })
    }

    @Test
    func thoughtChunksStreamAsThinking() {
        var translation = OpenCodeTranslation()
        let events = translation.translate(.sessionUpdate(OpenCodeSessionUpdate(
            sessionID: "sess-1",
            kind: .thought("Let me reason"),
            raw: .object([:])
        )))
        #expect(events.contains { if case .streamDelta(.thinking("Let me reason")) = $0 { return true }; return false })
    }

    @Test
    func toolCallStreamMapsToRead() {
        // The verified v2 wire names the tool under `toolCallId` and `title`, carries input in
        // `rawInput`, and locates the file under `rawInput.path` / `locations`.
        var translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(model: "gpt-4"))
        _ = translation.translate(.sessionUpdate(OpenCodeSessionUpdate(
            sessionID: "sess-1",
            kind: .toolCall(OpenCodeToolCall.decode(.object([
                "toolCallId": .string("call_1"),
                "title": .string("read"),
                "kind": .string("read"),
                "status": .string("pending"),
                "rawInput": .object(["path": .string("src/main.rs")]),
            ]), isUpdate: false)),
            raw: .object([:])
        )))
        // The completed update emits a tool result row whose text comes from the content blocks.
        let completed = translation.translate(.sessionUpdate(OpenCodeSessionUpdate(
            sessionID: "sess-1",
            kind: .toolCallUpdate(OpenCodeToolCall.decode(.object([
                "toolCallId": .string("call_1"),
                "status": .string("completed"),
                "content": .array([
                    .object([
                        "type": .string("content"),
                        "content": .object(["type": .string("text"), "text": .string("11 lines")]),
                    ]),
                ]),
            ]), isUpdate: true)),
            raw: .object([:])
        )))
        let toolRows = completed.compactMap { event -> AgentToolResult? in
            if case .toolResult(let row) = event { return row }
            return nil
        }
        #expect(toolRows.count == 1)
        #expect(toolRows[0].toolUseID == "call_1")
        #expect(toolRows[0].text.contains("11 lines"))
    }

    @Test
    func usageUpdateSetsContextThenResponseOverridesTokens() {
        var translation = OpenCodeTranslation()
        _ = translation.translate(.sessionUpdate(OpenCodeSessionUpdate(
            sessionID: "sess-1",
            kind: .usage(used: 9162, size: 1000000),
            raw: .object([:])
        )))
        #expect(translation.usage.contextTokens == 1000000)
        #expect(translation.usage.inputTokens == 9162)
        // The prompt response carries the definitive per-turn split and replaces the streaming sum.
        _ = translation.translate(.promptResponse(OpenCodePromptResult(
            requestID: .number(1),
            sessionID: "sess-1",
            stopReason: "end_turn",
            raw: .object(["usage": .object([
                "inputTokens": .integer(9160),
                "outputTokens": .integer(2),
                "totalTokens": .integer(9162),
            ])])
        )))
        #expect(translation.usage.inputTokens == 9160)
        #expect(translation.usage.outputTokens == 2)
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
        #expect(ask.summary.contains("Read /test/file.txt"))
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
}
