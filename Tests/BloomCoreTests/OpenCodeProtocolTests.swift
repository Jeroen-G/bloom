import Testing
import Foundation
@testable import BloomCore

// MARK: - OpenCodeProtocolTests

/// Tests for the OpenCode ACP protocol parsing and frame classification.
/// These tests verify that we can correctly parse and classify all ACP message types
/// that OpenCode v2 sends via its `opencode acp` command.
@Suite struct OpenCodeProtocolTests {

    // MARK: - Request ID Tests

    @Test func requestIDDecodesInteger() throws {
        let json = JSONValue.integer(42)
        let id = try #require(OpenCodeRequestID(json))
        #expect(id == .number(42))
    }

    @Test func requestIDDecodesString() throws {
        let json = JSONValue.string("req-123")
        let id = try #require(OpenCodeRequestID(json))
        #expect(id == .text("req-123"))
    }

    @Test func requestIDDecodesNil() throws {
        let id = OpenCodeRequestID(nil)
        #expect(id == nil)
    }

    @Test func requestIDEncodesInteger() throws {
        let id = OpenCodeRequestID.number(42)
        let data = try JSONEncoder().encode(id)
        let string = String(decoding: data, as: UTF8.self)
        #expect(string == "42")
    }

    @Test func requestIDEncodesString() throws {
        let id = OpenCodeRequestID.text("req-123")
        let data = try JSONEncoder().encode(id)
        let string = String(decoding: data, as: UTF8.self)
        #expect(string == "\"req-123\"")
    }

    @Test func requestIDJsonLiteralInteger() throws {
        let id = OpenCodeRequestID.number(42)
        #expect(id.jsonLiteral == "42")
    }

    @Test func requestIDJsonLiteralString() throws {
        let id = OpenCodeRequestID.text("req-123")
        #expect(id.jsonLiteral == "\"req-123\"")
    }

    @Test func requestIDTurnID() throws {
        let id1 = OpenCodeRequestID.number(42)
        #expect(id1.turnID == "42")
        
        let id2 = OpenCodeRequestID.text("req-123")
        #expect(id2.turnID == "req-123")
    }

    // MARK: - RPC Error Tests

    @Test func rpcErrorInit() throws {
        let error = OpenCodeRPCError(code: -32601, message: "Method not found", data: nil)
        #expect(error.code == -32601)
        #expect(error.message == "Method not found")
        #expect(error.data == nil)
    }

    @Test func rpcErrorWithData() throws {
        let data: JSONValue = .object(["details": .string("more info")])
        let error = OpenCodeRPCError(code: -32602, message: "Invalid params", data: data)
        #expect(error.code == -32602)
        #expect(error.message == "Invalid params")
        #expect(error.data != nil)
    }

    // MARK: - Client Error Tests

    @Test func clientErrorConnectionClosed() throws {
        let error = OpenCodeClientError.connectionClosed("Process died")
        #expect(error.description == "The connection to OpenCode closed: Process died")
    }

    @Test func clientErrorConnectionClosedEmpty() throws {
        let error = OpenCodeClientError.connectionClosed("")
        #expect(error.description == "The connection to OpenCode closed")
    }

    @Test func clientErrorUnexpectedResult() throws {
        let error = OpenCodeClientError.unexpectedResult(method: "session/new")
        #expect(error.description == "OpenCode returned a response Bloom could not read")
    }

    @Test func clientErrorNotInitialized() throws {
        let error = OpenCodeClientError.notInitialized
        #expect(error.description == "Bloom could not connect to OpenCode")
    }

    @Test func clientErrorTimedOutSessionLoad() throws {
        let error = OpenCodeClientError.timedOut(method: "session/load", seconds: 120)
        #expect(error.description == "OpenCode did not respond while reopening this conversation")
    }

    @Test func clientErrorTimedOutSessionNew() throws {
        let error = OpenCodeClientError.timedOut(method: "session/new", seconds: 120)
        #expect(error.description == "OpenCode did not respond while starting this conversation")
    }

    @Test func clientErrorTimedOutSessionPrompt() throws {
        let error = OpenCodeClientError.timedOut(method: "session/prompt", seconds: 120)
        #expect(error.description == "OpenCode did not accept the message in time")
    }

    @Test func clientErrorTimedOutUnknown() throws {
        let error = OpenCodeClientError.timedOut(method: "unknown/method", seconds: 120)
        #expect(error.description == "OpenCode did not respond in time")
    }

    // MARK: - Frame Decoding Tests

    @Test func decodeEmptyLine() throws {
        let frame = OpenCodeFrame.decode(line: "")
        #expect(frame == nil)
    }

    @Test func decodeWhitespaceLine() throws {
        let frame = OpenCodeFrame.decode(line: "   \n  ")
        #expect(frame == nil)
    }

    @Test func decodeMalformedJSON() throws {
        let frame = OpenCodeFrame.decode(line: "not json at all")
        if case .malformed = frame {
            // Expected
        } else {
            Issue.record("Expected malformed frame")
        }
    }

    @Test func decodeResponseFrame() throws {
        let line = """
        {"jsonrpc":"2.0","id":1,"result":{"sessionId":"sess-123"}}
        """
        guard case .response(let id, let result, _) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected response frame")
            return
        }
        #expect(id == .number(1))
        #expect(result["sessionId"]?.stringValue == "sess-123")
    }

    @Test func decodeResponseFrameWithStringID() throws {
        let line = """
        {"jsonrpc":"2.0","id":"req-1","result":{"sessionId":"sess-123"}}
        """
        guard case .response(let id, let result, _) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected response frame")
            return
        }
        #expect(id == .text("req-1"))
        #expect(result["sessionId"]?.stringValue == "sess-123")
    }

    @Test func decodeResponseFrameWithNullResult() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"result":null}"#
        guard case .response(let id, let result, _) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected response frame")
            return
        }
        #expect(id == .number(1))
        #expect(result == .null)
    }

    @Test func decodeFailureFrame() throws {
        let line = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
        """
        guard case .failure(let id, let error, _) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected failure frame")
            return
        }
        #expect(id == .number(2))
        #expect(error.code == -32601)
        #expect(error.message == "Method not found")
    }

    @Test func decodeFailureFrameWithData() throws {
        let line = """
        {"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Invalid params","data":{"field":"model"}}}
        """
        guard case .failure(let id, let error, _) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected failure frame")
            return
        }
        #expect(id == .number(3))
        #expect(error.code == -32602)
        #expect(error.message == "Invalid params")
        #expect(error.data?["field"]?.stringValue == "model")
    }

    @Test func decodeRequestFrame() throws {
        // Server-to-client request (e.g., permission request)
        let line = """
        {"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"action":"edit","path":"/file.txt"}}
        """
        guard case .request(let request) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected request frame")
            return
        }
        #expect(request.id == .number(0))
        #expect(request.method == "session/request_permission")
        #expect(request.params["action"]?.stringValue == "edit")
        #expect(request.params["path"]?.stringValue == "/file.txt")
    }

    @Test func decodeRequestFrameWithStringID() throws {
        let line = """
        {"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{}}
        """
        guard case .request(let request) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected request frame")
            return
        }
        #expect(request.id == .text("perm-1"))
        #expect(request.method == "session/request_permission")
    }

    @Test func decodeNotificationFrame() throws {
        // Session update notification, in the verified OpenCode v2 shape: the `update` object
        // discriminates on `sessionUpdate`, and content is `{ type: "text", text: ... }`.
        let line = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-123","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}
        """
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/update")
        #expect(notification.params["sessionId"]?.stringValue == "sess-123")
        // The typed decode reads the same shape the translation consumes.
        let update = OpenCodeSessionUpdate.decode(params: notification.params)
        guard case .text("hello") = update?.kind else {
            Issue.record("Expected a text chunk update")
            return
        }
    }

    @Test func decodeNotificationFrameWithoutParams() throws {
        let line = #"{"jsonrpc":"2.0","method":"initialized"}"#
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "initialized")
        #expect(notification.params == .object([:]))
    }

    @Test func decodeNotificationFrameWithoutJSONRPC() throws {
        // ACP spec says jsonrpc member is optional, test without it
        let line = #"{"method":"session/update","params":{}}"#
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/update")
    }

    // MARK: - Frame Classification Tests

    @Test func classifyRequestFrame() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#
        guard case .request(let request) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected request frame")
            return
        }
        #expect(request.method == "session/new")
        #expect(request.id == .number(1))
    }

    @Test func classifyNotificationFrame() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{}}"#
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/update")
    }

    @Test func classifyResponseFrame() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        guard case .response = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected response frame")
            return
        }
    }

    @Test func classifyFailureFrame() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"error"}}"#
        guard case .failure = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected failure frame")
            return
        }
    }

    // MARK: - Outgoing Frame Building Tests

    @Test func buildRequestFrame() throws {
        let line = OpenCodeOutgoing.request(
            id: .number(1),
            method: "initialize",
            params: .object(["protocolVersion": .integer(1)])
        )
        #expect(line.contains("\"jsonrpc\":\"2.0\""))
        #expect(line.contains("\"id\":1"))
        #expect(line.contains("\"method\":\"initialize\""))
        // A number, not a string: OpenCode v2 rejects `"1"` with "expected number".
        #expect(line.contains("\"protocolVersion\":1"))
    }

    @Test func buildRequestFrameWithStringID() throws {
        let line = OpenCodeOutgoing.request(
            id: .text("req-1"),
            method: "session/new",
            params: .object(["cwd": .string("/tmp")])
        )
        #expect(line.contains("\"id\":\"req-1\""))
        #expect(line.contains("\"method\":\"session/new\""))
        #expect(line.contains("\"cwd\":\"/tmp\""))
    }

    @Test func buildRequestFrameWithoutParams() throws {
        let line = OpenCodeOutgoing.request(id: .number(1), method: "initialized", params: nil)
        #expect(line.contains("\"method\":\"initialized\""))
        // Should not contain "params"
        #expect(!line.contains("\"params\":"))
    }

    @Test func buildNotificationFrame() throws {
        let line = OpenCodeOutgoing.notification(
            method: "initialized",
            params: .object([:]) 
        )
        #expect(line.contains("\"jsonrpc\":\"2.0\""))
        #expect(line.contains("\"method\":\"initialized\""))
        // Should not contain "id"
        #expect(!line.contains("\"id\":"))
    }

    @Test func buildResponseFrame() throws {
        let line = OpenCodeOutgoing.response(
            id: .number(0),
            result: .object(["decision": .string("allow_once")])
        )
        #expect(line.contains("\"jsonrpc\":\"2.0\""))
        #expect(line.contains("\"id\":0"))
        #expect(line.contains("\"result\":{\"decision\":\"allow_once\"}"))
    }

    @Test func buildFailureFrame() throws {
        let line = OpenCodeOutgoing.failure(
            id: .number(0),
            code: -32600,
            message: "Rejected"
        )
        #expect(line.contains("\"jsonrpc\":\"2.0\""))
        #expect(line.contains("\"id\":0"))
        #expect(line.contains("\"error\":"))
        #expect(line.contains("\"code\":-32600"))
        #expect(line.contains("\"message\":\"Rejected\""))
    }

    // MARK: - JSONValue Helper Tests

    @Test func jsonValueCompactJSONString() throws {
        let value = JSONValue.string("hello world")
        #expect(value.compactJSON == "\"hello world\"")
    }

    @Test func jsonValueCompactJSONNumber() throws {
        let value = JSONValue.integer(42)
        #expect(value.compactJSON == "42")
    }

    @Test func jsonValueCompactJSONObject() throws {
        let value = JSONValue.object(["key": .string("value")])
        #expect(value.compactJSON == "{\"key\":\"value\"}")
    }

    @Test func jsonValueObjectOmittingNil() throws {
        let value = JSONValue.object(omittingNil: [
            "present": .string("value"),
            "absent": nil,
            "another": .integer(42)
        ])
        #expect(value["present"]?.stringValue == "value")
        #expect(value["absent"] == nil)
        #expect(value["another"]?.intValue == 42)
    }

    @Test func jsonValueObjectOmittingNilAllNil() throws {
        let value = JSONValue.object(omittingNil: [
            "a": nil,
            "b": nil
        ])
        #expect(value == .object([:]))
    }
}

// MARK: - OpenCodeModel Tests

@Suite struct OpenCodeModelTests {
    @Test func modelInit() throws {
        let model = OpenCodeModel(
            id: "anthropic/claude-3-sonnet",
            displayName: "claude-3-sonnet",
            provider: "anthropic"
        )
        #expect(model.id == "anthropic/claude-3-sonnet")
        #expect(model.name == "claude-3-sonnet")
        #expect(model.provider == "anthropic")
    }

    @Test func decodeModelListFromArray() throws {
        let json: JSONValue = .array([
            .string("anthropic/claude-3-sonnet"),
            .string("openai/gpt-4"),
            .string("invalid-model")  // Will be skipped
        ])
        let models = OpenCodeModel.decodeList(json)
        #expect(models.count == 2)
        #expect(models[0].id == "anthropic/claude-3-sonnet")
        #expect(models[0].provider == "anthropic")
        #expect(models[1].id == "openai/gpt-4")
        #expect(models[1].provider == "openai")
    }

    @Test func decodeModelListFromNonArray() throws {
        let json: JSONValue = .object([:])
        let models = OpenCodeModel.decodeList(json)
        #expect(models.isEmpty)
    }

    @Test func decodeModelListSkipsInvalid() throws {
        let json: JSONValue = .array([
            .string("valid/model"),
            .integer(123),  // Invalid
            .string("no-slash"),  // Invalid
            .string("also/valid")
        ])
        let models = OpenCodeModel.decodeList(json)
        #expect(models.count == 2)
        #expect(models[0].id == "valid/model")
        #expect(models[1].id == "also/valid")
    }

    @Test func decodeConfigOptionsReturnsNilWithoutConfigOptions() throws {
        let json: JSONValue = .object(["sessionId": .string("sess-1")])
        #expect(OpenCodeModel.decodeConfigOptions(json) == nil)
    }

    @Test func decodeConfigOptionsReadsModelAndEffortSelects() throws {
        // Shape copied from a real `opencode acp` v2.0.3 `session/new` response.
        let json: JSONValue = .object([
            "sessionId": .string("sess-1"),
            "configOptions": .array([
                .object([
                    "id": .string("model"),
                    "name": .string("Model"),
                    "category": .string("model"),
                    "type": .string("select"),
                    "currentValue": .string("opencode/gpt-5.6-sol"),
                    "options": .array([
                        .object([
                            "value": .string("google/gemini-3.5-flash"),
                            "name": .string("google/Gemini 3.5 Flash"),
                        ]),
                        .object([
                            "value": .string("opencode/gpt-5.6-sol"),
                            "name": .string("opencode/GPT-5.6 Sol (50% Off)"),
                        ]),
                        .object([
                            "value": .string("llama.cpp/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_1"),
                            "name": .string("llama.cpp/Qwen3.6 (local)"),
                        ]),
                    ]),
                ]),
                .object([
                    "id": .string("effort"),
                    "name": .string("Effort"),
                    "category": .string("thought_level"),
                    "type": .string("select"),
                    "currentValue": .string("default"),
                    "options": .array([
                        .object(["value": .string("low"), "name": .string("Low")]),
                        .object(["value": .string("high"), "name": .string("High")]),
                        .object(["value": .string("max"), "name": .string("Max")]),
                        .object(["value": .string("default"), "name": .string("Default")]),
                    ]),
                ]),
            ]),
        ])

        let models = try #require(OpenCodeModel.decodeConfigOptions(json))
        #expect(models.count == 3)

        // The current model is marked default, its label loses the provider prefix.
        let current = try #require(models.first { $0.id == "opencode/gpt-5.6-sol" })
        #expect(current.isDefault)
        #expect(current.displayName == "GPT-5.6 Sol (50% Off)")
        #expect(current.provider == "opencode")

        // A label that does not repeat the provider prefix survives untouched.
        let local = try #require(models.first { $0.id == "llama.cpp/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_1" })
        #expect(local.displayName == "Qwen3.6 (local)")

        // The effort select is shared by every model.
        #expect(models.allSatisfy { $0.supportedEfforts.map(\.id) == ["low", "high", "max", "default"] })
        #expect(models.allSatisfy { $0.defaultEffort == "default" })
    }

    @Test func decodeConfigOptionsEmptyWhenShapeNamesNoModels() throws {
        let json: JSONValue = .object([
            "sessionId": .string("sess-1"),
            "configOptions": .array([
                .object([
                    "id": .string("mode"),
                    "name": .string("Session Mode"),
                    "type": .string("select"),
                    "options": .array([]),
                ]),
            ]),
        ])
        #expect(OpenCodeModel.decodeConfigOptions(json) == [])
    }
}

// MARK: - ACP Message Examples Tests

/// Tests that verify we can parse realistic ACP messages that OpenCode v2 would send.
@Suite struct OpenCodeACPMessageTests {

    @Test func parseInitializeResponse() throws {
        // Simulated OpenCode initialize response
        let line = """
        {"id":1,"result":{"protocolVersion":"1","capabilities":{"loadSession":true,"fork":true,"resume":true,"mcpCapabilities":{"serverVariables":true}},"agentInfo":{"name":"OpenCode","version":"0.1.0"}}}
        """
        guard case .response(let id, let result, _) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected response frame")
            return
        }
        #expect(id == .number(1))
        #expect(result["protocolVersion"]?.stringValue == "1")
        #expect(result["capabilities"]?["loadSession"]?.boolValue == true)
        #expect(result["capabilities"]?["fork"]?.boolValue == true)
        #expect(result["agentInfo"]?["name"]?.stringValue == "OpenCode")
    }

    @Test func parseSessionNewResponse() throws {
        let line = #"{"id":2,"result":{"sessionId":"sess_abc123"}}"#
        guard case .response(let id, let result, _) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected response frame")
            return
        }
        #expect(id == .number(2))
        #expect(result["sessionId"]?.stringValue == "sess_abc123")
    }

    @Test func parseSessionUpdateWithMessageChunk() throws {
        let line = """
        {"method":"session/update","params":{"sessionId":"sess_abc123","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}
        """
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/update")
        #expect(notification.params["sessionId"]?.stringValue == "sess_abc123")
        #expect(notification.params["update"]?["sessionUpdate"]?.stringValue == "agent_message_chunk")
    }

    @Test func parseSessionUpdateWithThoughtChunk() throws {
        let line = """
        {"method":"session/update","params":{"sessionId":"sess_abc123","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Thinking..."}}}}
        """
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/update")
        #expect(notification.params["update"]?["sessionUpdate"]?.stringValue == "agent_thought_chunk")
    }

    @Test func parsePermissionRequest() throws {
        let line = """
        {"id":0,"method":"session/request_permission","params":{"requestId":"req-1","action":"edit","path":"/file.swift","options":{"allow_once":true,"allow_always":true,"reject_once":true,"reject_always":true}}}
        """
        guard case .request(let request) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected request frame")
            return
        }
        #expect(request.method == "session/request_permission")
        #expect(request.id == .number(0))
        #expect(request.params["action"]?.stringValue == "edit")
        #expect(request.params["path"]?.stringValue == "/file.swift")
    }

    @Test func parseToolCallUpdate() throws {
        let line = """
        {"method":"session/update","params":{"sessionId":"sess_abc123","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"bash","status":"pending","rawInput":{"command":"ls -la"}}}}
        """
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/update")
        #expect(notification.params["update"]?["sessionUpdate"]?.stringValue == "tool_call")
    }

    @Test func parseUsageUpdate() throws {
        let line = """
        {"method":"session/update","params":{"sessionId":"sess_abc123","update":{"sessionUpdate":"usage_update","used":100,"size":200}}}
        """
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/update")
        #expect(notification.params["update"]?["sessionUpdate"]?.stringValue == "usage_update")
    }

    @Test func parseSessionEnded() throws {
        let line = #"{"method":"session/ended","params":{"sessionId":"sess_abc123"}}"#
        guard case .notification(let notification) = try #require(OpenCodeFrame.decode(line: line)) else {
            Issue.record("Expected notification frame")
            return
        }
        #expect(notification.method == "session/ended")
        #expect(notification.params["sessionId"]?.stringValue == "sess_abc123")
    }
}
