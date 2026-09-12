# OpenCode v2 Integration Requirements

**Status**: Draft - Ready for Review  
**Target**: Bloom Integration for OpenCode v2 (ACP-based)  
**Author**: Vibe Code Analysis  
**Date**: 2026-XX-XX  

---

## Executive Summary

OpenCode v2 **fully supports ACP (Agent Client Protocol)** via the `opencode acp` command, using **JSON-RPC 2.0 over stdio with newline-delimited JSON**. This is the **same protocol class** that Codex (app-server) and Grok (ACP) already implement in Bloom. This means:

1. **No custom protocol development needed** - Reuse existing ACP infrastructure
2. **Reduced implementation scope** - Can leverage `GrokRunner` patterns heavily
3. **Faster path to production** - Protocol is verified and documented

---

## 1. Protocol Confirmation

### Command
```bash
opencode acp --cwd /path/to/project
```

### Transport
- **Protocol**: Agent Client Protocol (ACP) v1 (stable)
- **Transport**: JSON-RPC 2.0 over stdio
- **Encoding**: Newline-delimited JSON (ND-JSON)
- **Direction**: Bidirectional (client ↔ agent)

### Verified Sources
- [OpenCode ACP Docs](https://opencode.ai/docs/acp/) - Official documentation
- [DeepWiki sst/opencode](https://deepwiki.com/sst/opencode/7.4-agent-client-protocol-(acp)) - Implementation details
- [ACP Specification](https://agentclientprotocol.com/protocol/v1/overview) - Protocol standard

---

## 2. Capability Matrix

### ✅ Confirmed Capabilities

| Capability | Status | Details | Source |
|-----------|--------|---------|--------|
| **Session Persistence** | ✅ Supported | `session/load` and `session/resume` | [ACP Spec](https://agentclientprotocol.com), [DeepWiki](https://deepwiki.com/sst/opencode/7.4-agent-client-protocol-(acp)) |
| **Session Fork** | ✅ Supported | `session/fork` (draft/unstable in ACP) | [GitHub Issue #7978](https://github.com/anomalyco/opencode/issues/7978) |
| **Session List** | ✅ Supported | `session/list` with pagination | [GitHub Issue #7978](https://github.com/anomalyco/opencode/issues/7978) |
| **Event Streaming** | ✅ Supported | `session/update` notifications | [ACP Spec](https://agentclientprotocol.com) |
| **Permission Requests** | ✅ Supported | `session/request_permission` | [ACP Spec](https://agentclientprotocol.com) |
| **Model Discovery** | ✅ Supported | `opencode models` CLI command | [CLI Docs](https://opencode.ai/docs/cli/) |
| **MCP Integration** | ✅ Supported | MCP servers passed via `session/new` | [DeepWiki](https://deepwiki.com/sst/opencode/7.4-agent-client-protocol-(acp)) |
| **Context Replay** | ✅ Supported | Replays last 20 messages on resume | [GitHub Issue #2838](https://github.com/pingdotgg/t3code/issues/2838) |

### ⚠️ Unknown Capabilities

| Capability | Status | Notes |
|-----------|--------|-------|
| **Mid-turn Messages** | ⚠️ Unknown | Not explicitly verified for OpenCode v2 |
| **Session Compaction** | ⚠️ Unknown | Not explicitly verified |

### ✅ Bloom Infrastructure Already Exists

| Component | Existing | Reusable |
|-----------|----------|----------|
| JSON-RPC 2.0 parser | ✅ CodexProtocol.swift | Yes, with minor adjustments |
| ACP session management | ✅ GrokRunner.swift | Yes, template for OpenCodeRunner |
| Permission handling | ✅ CodexRunner/SessionGrants | Yes, ACP pattern |
| Event translation | ✅ CodexTranslation.swift | Yes, ACP event patterns |
| Model catalog | ✅ AgentModelSource | Yes, add OpenCode source |

---

## 3. Implementation Architecture

### File Structure (New/Modified)

```
Sources/BloomCore/Agent/
├── OpenCode/
│   ├── OpenCodeProtocol.swift    # ACP JSON-RPC types for OpenCode
│   ├── OpenCodeClient.swift       # JSON-RPC client wrapper
│   ├── OpenCodeTranslation.swift  # Event → AgentEvent conversion
│   ├── OpenCodeRunner.swift       # Main session runner
│   └── OpenCodeModelCatalog.swift # Model discovery
├── SessionRunner.swift             # Add OpenCode case

Sources/BloomCore/Model/
├── Models.swift                   # Update AgentKind.openCode

Tests/BloomCoreTests/
├── OpenCodeRunnerTests.swift      # Runner tests
├── OpenCodeProtocolTests.swift    # Protocol parsing tests
└── OpenCodeTranslationTests.swift # Translation tests

docs/
├── OPENCODE-V2-INTEGRATION.md     # This document
└── OPENCODE-PROTOCOL.md           # Captured transcripts (TBD)
```

### Integration Points

#### AgentKind Extension
```swift
// In Models.swift
extension AgentKind {
    // Already exists:
    case openCode: "OpenCode"
    
    // Update:
    var canRunWorkspaces: Bool {
        switch self {
        case .claudeCode, .codex, .grok, .openCode: true  // ADD .openCode
        case .cursor: false
        }
    }
}
```

#### SessionRunner Construction
```swift
// In SessionRunner.swift or factory
public static func forAgent(
    kind: AgentKind,
    workspacePath: String,
    session: Session,
    store: Store,
    bridge: BridgeAttachment?
) -> any SessionRunner {
    switch kind {
    case .claudeCode: AgentRunner(...)
    case .codex: CodexRunner(...)
    case .grok: GrokRunner(...)
    case .openCode: OpenCodeRunner(...)  // NEW
    case .cursor: fatalError("Cursor has no runner")
    }
}
```

---

## 4. Protocol Details

### Lifecycle

```
1. Bloom launches: opencode acp --cwd /workspace/path
2. Handshake:
   - Bloom → OpenCode: initialize (protocolVersion: "1")
   - OpenCode → Bloom: capabilities (loadSession: true, fork: true, resume: true, mcpCapabilities)
   - Bloom → OpenCode: initialized
3. Session Setup:
   - Bloom → OpenCode: session/new (cwd, mcpServers, _meta)
   - OpenCode → Bloom: sessionId
   - Bloom persists: Session.agentSessionID
4. Turn:
   - Bloom → OpenCode: session/prompt (message)
   - OpenCode → Bloom: session/update (streaming chunks)
   - OpenCode → Bloom: session/update (tool calls)
   - OpenCode → Bloom: session/update (completion)
5. Permission:
   - OpenCode → Bloom: request_permission (server-to-client request)
   - Bloom → OpenCode: response (allow/deny)
6. Resume:
   - Bloom → OpenCode: session/load (sessionId)
   - OpenCode → Bloom: session/update (replay history)
```

### ACP Methods Supported by OpenCode v2

| Method | Direction | Description |
|--------|-----------|-------------|
| `initialize` | Client → Agent | Negotiate protocol version, exchange capabilities |
| `initialized` | Client → Agent | Signal handshake complete |
| `session/new` | Client → Agent | Create new session |
| `session/load` | Client → Agent | Resume existing session |
| `session/prompt` | Client → Agent | Send user message, start turn |
| `session/cancel` | Client → Agent | Interrupt current turn |
| `session/update` | Agent → Client | Streaming updates (notification) |
| `request_permission` | Agent → Client | Permission request (server-to-client) |
| `shutdown` | Client → Agent | Graceful shutdown |
| `exit` | Agent → Client | Process termination notice |

### ACP Notifications from OpenCode

| Notification | Description |
|--------------|-------------|
| `session/update` | Streaming content chunks |
| `session/status` | Session state changes |
| `session/ended` | Turn completion |

### Session Update Types

From [ACP Spec](https://agentclientprotocol.com/protocol/v1/overview) and verified:

- `agent_message_chunk` - Assistant text delta
- `agent_thought_chunk` - Reasoning/thinking delta
- `tool_call` - Tool invocation request
- `tool_call_update` - Tool execution progress
- `tool_call_result` - Tool execution result
- `usage_update` - Token usage information
- `available_commands_update` - Available commands changed

---

## 5. Model Discovery

### CLI Command
```bash
opencode models [provider]
```

### Output Format
```
provider/model-1
provider/model-2
provider/model-3
```

### Example
```bash
$ opencode models anthropic
anthropic/claude-3-7-sonnet-20250219
anthropic/claude-3-5-sonnet-20241022
anthropic/claude-3-haiku-20240307

$ opencode models --refresh
# Refreshes cached model list from models.dev
```

### Integration Approach

Add to `AgentModelSource.live`:

```swift
// In AgentModelCatalog.swift or similar
struct OpenCodeModelSource: AgentModelSource {
    func fetchModels() async throws -> [AgentModel] {
        // Execute: opencode models --format json (if supported)
        // Or parse text output
        // Map to AgentModel
    }
}
```

**Note**: Need to verify if `opencode models` supports `--format json` output. If not, parse text output or use the HTTP API via `opencode serve`.

---

## 6. Authentication

### Auth File Location
- Primary: `~/.local/share/opencode/auth.json`
- Also reads from: Environment variables, `.env` files in project

### Auth Command
```bash
opencode auth login
```

### Login Flow
- Interactive: Prompts for provider selection and API key
- Non-interactive: `opencode auth login --provider <id> --method <label>`

### Credentials Storage
- JSON file with provider → API key mappings
- Supports multiple providers simultaneously

### Bloom Integration

Update `AgentKind.openCode`:

```swift
// In Models.swift
extension AgentKind {
    // Already exists:
    case openCode: "OpenCode"
    
    var loginCommand: String {
        switch self {
        case .openCode: "opencode auth login"
        // ...
        }
    }
    
    var configPath: String {
        let home = NSHomeDirectory()
        switch self {
        case .openCode: "\(home)/.config/opencode/opencode.json"
        // ...
        }
    }
}
```

---

## 7. Configuration

### Config Files
- User: `~/.config/opencode/opencode.json`
- Project: `.opencode.json` (at repo root)
- Project overrides user config

### Config Command
```bash
opencode debug config
```

### Relevant Config Sections
- `providers` - Model provider configurations
- `models` - Model aliases and defaults
- `permissions` - Permission rules
- `agents` - Agent definitions
- `mcp` - MCP server configurations

---

## 8. Permission System (v2)

### Key Change from v1
> **V1 uses `permission`, `bash`, `task`**  
> **V2 uses `permissions`, `shell`, `subagent`**

Source: [OpenCode v2 Permissions Docs](https://opencode.ai/v2/docs/permissions/)

### Permission Actions (v2)
- `read` - File read access
- `edit` - File write access
- `shell` - Shell/bash command execution
- `glob` - Glob pattern matching
- `grep` - Grep search
- `webfetch` - Web fetching
- `task` - Task execution (legacy)
- `todowrite` - Todo list writing
- `websearch` - Web search
- `lsp` - LSP operations
- `skill` - Skill execution
- `subagent` - Subagent delegation

### Permission Flow
1. OpenCode → Bloom: `request_permission` (server-to-client request)
2. Bloom displays permission prompt to user
3. User allows/denies
4. Bloom → OpenCode: Response with decision

### ACP Request Shape
```json
{
  "jsonrpc": "2.0",
  "method": "request_permission",
  "params": {
    "requestId": "uuid",
    "action": "edit",
    "path": "/path/to/file",
    "options": {
      "allow_once": true,
      "allow_always": true,
      "reject_once": true,
      "reject_always": true
    }
  },
  "id": 1
}
```

---

## 9. Session Management

### Session Creation
```swift
// In OpenCodeRunner
func startNewSession() async throws -> String {
    let request = ACPRequest(
        method: "session/new",
        params: [
            "cwd": workspacePath,
            "mcpServers": mcpConfig?.acpServers ?? [],
            "_meta": [
                "yoloMode": false,
                "autoMode": false,
                "permissionMode": session.permissionMode.rawValue
            ]
        ]
    )
    let response = try await client.send(request)
    let sessionId = response.result.sessionId
    // Persist sessionId to Session.agentSessionID
    return sessionId
}
```

### Session Resume
```swift
func resumeSession(_ sessionId: String) async throws {
    let request = ACPRequest(
        method: "session/load",
        params: ["sessionId": sessionId]
    )
    let response = try await client.send(request)
    // OpenCode will replay history via session/update notifications
}
```

### Session Fork
```swift
func forkSession(_ sessionId: String, title: String?) async throws -> String {
    let request = ACPRequest(
        method: "session/fork",
        params: [
            "sessionId": sessionId,
            "title": title
        ]
    )
    let response = try await client.send(request)
    return response.result.sessionId
}
```

---

## 10. Event Translation

### Incoming ACP Events → Bloom AgentEvents

| ACP Event | Bloom AgentEvent | Notes |
|-----------|------------------|-------|
| `session/update` with `agent_message_chunk` | `.textDelta(text, turnID)` | Text streaming |
| `session/update` with `agent_thought_chunk` | `.thinkingDelta(text, turnID)` | Reasoning streaming |
| `session/update` with `tool_call` | `.toolCall(request, turnID)` | Tool request |
| `session/update` with `tool_call_update` | `.toolCallProgress(id, delta)` | Tool progress |
| `session/update` with `tool_call_result` | `.toolCallResult(id, result)` | Tool completion |
| `session/update` with `usage_update` | `.usageUpdate(usage)` | Token usage |
| `session/status` | `.sessionStateChanged(state)` | Session state |
| `request_permission` | `.ask(.permission(request))` | Permission prompt |
| `session/ended` | `.turnEnded(turnID)` | Turn completion |

### Outgoing Bloom Actions → ACP Requests

| Bloom Action | ACP Request | Notes |
|--------------|--------------|-------|
| Send message | `session/prompt` | Start turn |
| Cancel turn | `session/cancel` | Interrupt |
| Allow permission | Response to `request_permission` | id from request |
| Deny permission | Response to `request_permission` | id from request |
| Resume session | `session/load` | Pass sessionId |

---

## 11. Mid-Turn Message Support

### Status: ⚠️ Unknown - Needs Verification

**Hypothesis**: OpenCode v2 ACP likely supports mid-turn messages via:
- `session/prompt` while a turn is active (similar to Codex's `turn/steer`)
- OR automatic queuing for next turn

**Verification Needed**:
1. Start OpenCode ACP server
2. Send `session/prompt` message A
3. While processing, send `session/prompt` message B
4. Observe: Is B accepted mid-turn or queued?

**Expected Behavior** (based on ACP spec):
- Mid-turn messages should be supported as per ACP contract
- Need to verify OpenCode's specific implementation

### Bloom Integration

Update `AgentKind.openCode`:

```swift
var acceptsMidTurnMessage: Bool {
    switch self {
    case .claudeCode, .codex, .openCode: true  // Likely true
    case .grok, .cursor: false
    }
}
```

---

## 12. MCP Integration

### MCP Server Registration

OpenCode ACP accepts MCP servers during `session/new`:

```json
{
  "method": "session/new",
  "params": {
    "cwd": "/workspace/path",
    "mcpServers": [
      {
        "name": "bloom-workspace-bridge",
        "command": "bloom-bridge",
        "args": [],
        "env": {
          "BLOOM_BRIDGE_SOCKET": "/tmp/bloom-...",
          "BLOOM_BRIDGE_TOKEN": "..."
        }
      }
    ]
  }
}
```

### Bloom Bridge Registration

Reuse existing `BridgeRegistration` from Grok integration:

```swift
// In OpenCodeRunner initialization
let mcpConfig = BridgeRegistration.workspaceConfig(
    workspacePath: workspacePath,
    token: bridgeToken
)
// Pass mcpConfig.acpServers to session/new
```

---

## 13. Error Handling

### ACP Error Codes

From [ACP Spec](https://agentclientprotocol.com/protocol/v1/overview):

| Code | Meaning |
|------|---------|
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32603` | Internal error |
| `-32000` | Server error (generic) |

### OpenCode-Specific Errors

Need to capture from real transcripts:
- Session not found
- Permission denied
- Model not available
- Rate limit exceeded

---

## 14. Testing Strategy

### Unit Tests

1. **Protocol Parsing**
   - Parse ACP JSON-RPC frames
   - Handle requests, responses, notifications
   - Verify id handling (number vs string)

2. **Event Translation**
   - Convert all ACP event types to AgentEvent
   - Verify turn ID propagation
   - Verify session ID handling

3. **Runner Lifecycle**
   - Start/stop process
   - Handle crashes
   - Session persistence

### Integration Tests

1. **Basic Session**
   - Start OpenCode ACP
   - Create session
   - Send message
   - Receive response

2. **Permission Flow**
   - Trigger permission request
   - Approve/deny
   - Verify agent continues/aborts

3. **Session Resume**
   - Create session with message
   - Stop and resume
   - Verify history replay

4. **Model Discovery**
   - List available models
   - Select model
   - Verify session uses model

### Manual Verification

```bash
# Start OpenCode ACP in one terminal
opencode acp --cwd /tmp/test

# In another terminal, send test messages
echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"1"}}' | nc -U /tmp/opencode.sock
```

---

## 15. Implementation Checklist

### Phase 1: Core Protocol (1-2 days)
- [ ] Create `OpenCodeProtocol.swift` with ACP types
- [ ] Create `OpenCodeClient.swift` JSON-RPC client
- [ ] Add ACP request/response/notification parsing
- [ ] Add ACP error handling

### Phase 2: Runner (2-3 days)
- [ ] Create `OpenCodeRunner.swift` skeleton
- [ ] Implement handshake (initialize → capabilities → initialized)
- [ ] Implement session/new
- [ ] Implement session/prompt
- [ ] Implement session/cancel

### Phase 3: Event Translation (1-2 days)
- [ ] Create `OpenCodeTranslation.swift`
- [ ] Map ACP session/update → AgentEvent
- [ ] Map ACP request_permission → AgentEvent.ask
- [ ] Handle all update types

### Phase 4: Integration (1-2 days)
- [ ] Update `AgentKind.openCode.canRunWorkspaces = true`
- [ ] Add OpenCodeRunner to SessionRunner factory
- [ ] Update model catalog with OpenCode source
- [ ] Add OpenCode to AgentModelSource.live

### Phase 5: Features (1-2 days)
- [ ] Implement session/load (resume)
- [ ] Implement permission handling
- [ ] Add MCP bridge registration
- [ ] Verify mid-turn message support

### Phase 6: Testing (1-2 days)
- [ ] Unit tests for protocol parsing
- [ ] Unit tests for translation
- [ ] Integration test with real OpenCode ACP
- [ ] Test session resume

### Phase 7: Polish (1 day)
- [ ] Update AGENTS-INTEGRATION.md
- [ ] Add OpenCode to README
- [ ] Update tests in AgentCatalogTests.swift
- [ ] Final review and cleanup

**Total Estimated Effort**: 9-14 days

---

## 16. Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| ACP protocol differences | Low | High | Use existing GrokRunner as template, test early |
| OpenCode v2 API changes | Medium | Medium | Pin to specific version in tests |
| Mid-turn message not supported | Medium | Medium | Default to queuing, verify with real CLI |
| Model discovery format | Low | Low | Parse text output if JSON not available |
| Permission system differences | Low | Medium | Map OpenCode v2 actions to Bloom's model |

---

## 17. Dependencies

### External
- OpenCode CLI v2 installed and in PATH
- At least one model provider configured

### Internal (Bloom)
- `CodexProtocol.swift` - JSON-RPC patterns
- `GrokRunner.swift` - ACP runner template
- `CodexTranslation.swift` - Event translation patterns
- `SessionRunner.swift` - Base protocol
- `AgentModelSource.swift` - Model discovery

---

## 18. References

### Official Documentation
- [OpenCode CLI Docs](https://opencode.ai/docs/cli/)
- [OpenCode ACP Docs](https://opencode.ai/docs/acp/)
- [ACP Specification](https://agentclientprotocol.com/protocol/v1/overview)

### Implementation References
- [sst/opencode DeepWiki](https://deepwiki.com/sst/opencode/7.4-agent-client-protocol-(acp))
- [OpenCode GitHub](https://github.com/anomalyco/opencode)

### Related Issues
- [OpenCode ACP session resume](https://github.com/pingdotgg/t3code/issues/2838)
- [ACP session/fork support](https://github.com/anomalyco/opencode/issues/7978)

---

## 19. Appendix: ACP Message Examples

### Initialize Request
```json
{
  "jsonrpc": "2.0",
  "method": "initialize",
  "id": 1,
  "params": {
    "protocolVersion": "1",
    "clientInfo": {
      "name": "Bloom",
      "version": "x.x.x"
    },
    "capabilities": {
      "fileSystem": {"read": true, "write": true},
      "terminal": true
    }
  }
}
```

### Initialize Response (OpenCode)
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "1",
    "capabilities": {
      "loadSession": true,
      "fork": true,
      "resume": true,
      "mcpCapabilities": {"serverVariables": true}
    },
    "agentInfo": {
      "name": "OpenCode",
      "version": "0.x.x"
    }
  }
}
```

### Session/New Request
```json
{
  "jsonrpc": "2.0",
  "method": "session/new",
  "id": 2,
  "params": {
    "cwd": "/workspace/project",
    "mcpServers": [
      {
        "name": "bloom-bridge",
        "command": "bloom-bridge",
        "args": [],
        "env": {
          "BLOOM_BRIDGE_SOCKET": "/tmp/bloom-sock",
          "BLOOM_BRIDGE_TOKEN": "secret"
        }
      }
    ],
    "_meta": {
      "permissionMode": "ask"
    }
  }
}
```

### Session/New Response
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "sessionId": "sess_abc123"
  }
}
```

### Session/Prompt Request
```json
{
  "jsonrpc": "2.0",
  "method": "session/prompt",
  "id": 3,
  "params": {
    "sessionId": "sess_abc123",
    "message": {
      "role": "user",
      "content": [
        {"type": "text", "text": "Hello, OpenCode!"}
      ]
    }
  }
}
```

### Session/Update Notification (streaming)
```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123",
    "update": {
      "type": "agent_message_chunk",
      "chunk": {
        "type": "text",
        "text": "Hello"
      }
    }
  }
}
```

### Request Permission (server-to-client)
```json
{
  "jsonrpc": "2.0",
  "method": "request_permission",
  "id": 4,
  "params": {
    "requestId": "req_456",
    "action": "edit",
    "path": "/workspace/project/file.swift",
    "options": {
      "allow_once": true,
      "allow_always": true,
      "reject_once": true,
      "reject_always": true
    }
  }
}
```

### Permission Response
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "decision": "allow_once"
  }
}
```

---

## 20. Next Steps

1. **Review this document** - Verify accuracy and completeness
2. **Create discovery script** - Test real OpenCode v2 ACP capabilities
3. **Implement Phase 1** - Core protocol layer
4. **Capture real transcripts** - Document actual message shapes
5. **Iterate on implementation** - Based on real CLI behavior

---

*Document generated by Vibe Code analysis of OpenCode v2 capabilities*
