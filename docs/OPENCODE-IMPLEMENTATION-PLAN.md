# OpenCode v2 Implementation Plan

**Status**: Active  
**Target**: Add OpenCode v2 support to Bloom via ACP protocol  
**Owner**: Engineering Team  
**Created**: 2026-XX-XX  
**Related**: [OPENCODE-V2-INTEGRATION.md](./OPENCODE-V2-INTEGRATION.md)  

---

## Overview

This plan implements **OpenCode v2 support** in Bloom using its **ACP (Agent Client Protocol)** interface. OpenCode v2 speaks **JSON-RPC 2.0 over stdio** with newline-delimited JSON, the same protocol class already implemented for Codex (app-server) and Grok (ACP).

**Key advantage**: We can reuse ~70% of existing ACP infrastructure from Grok, significantly reducing implementation effort.

---

## Phases and Tasks

### Legend
- ✅ = Ready to start
- 🔄 = In progress
- ✔️ = Complete
- ⏳ = Blocked/Waiting
- ❌ = Won't fix

---

## Phase 0: Preparation (1 day)

**Goal**: Verify OpenCode v2 CLI capabilities and set up development environment.

### Tasks

- [ ] **T0.1: Install OpenCode v2 CLI**
  - Download from [opencode.ai/download](https://opencode.ai/download)
  - Verify: `opencode --version` outputs v2.x.x
  - Verify: `opencode acp --help` shows ACP command
  - **Owner**: DevOps/Engineer
  - **Success**: CLI installed, `which opencode` works

- [ ] **T0.2: Test ACP server startup**
  - Run: `opencode acp --cwd /tmp/test`
  - Verify: Process starts and waits for stdin
  - Send: `{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"1"}}`
  - Verify: Receives capabilities response
  - **Owner**: Engineer
  - **Success**: ACP handshake works, capabilities include `loadSession: true`

- [ ] **T0.3: Test basic session flow**
  - Complete handshake (initialize → initialized)
  - Send: `session/new` with cwd
  - Verify: Receives sessionId
  - Send: `session/prompt` with message
  - Verify: Receives `session/update` notifications
  - **Owner**: Engineer
  - **Success**: Full message round-trip works

- [ ] **T0.4: Test permission flow**
  - Configure OpenCode with `permission: ask` mode
  - Send prompt that requires file write
  - Verify: Receives `request_permission` server-to-client request
  - Send: Allow response
  - Verify: Agent continues
  - **Owner**: Engineer
  - **Success**: Permission request/response works

- [ ] **T0.5: Test session resume**
  - Create session with message, get sessionId
  - Stop process
  - Restart: `opencode acp --cwd /tmp/test`
  - Send: `session/load` with sessionId
  - Verify: Receives history replay via `session/update`
  - **Owner**: Engineer
  - **Success**: Session persistence works

- [ ] **T0.6: Test model listing**
  - Run: `opencode models`
  - Verify: Lists models in `provider/model` format
  - Run: `opencode models --refresh`
  - Verify: Refreshes model cache
  - Run: `opencode models anthropic`
  - Verify: Filters by provider
  - **Owner**: Engineer
  - **Success**: Model discovery CLI works

- [ ] **T0.7: Capture protocol transcripts**
  - Save all test outputs to `Tests/fixtures/opencode-*.ndjson`
  - Document exact message shapes in `docs/OPENCODE-PROTOCOL.md`
  - **Owner**: Engineer
  - **Success**: Ground truth captured for tests

**Phase 0 Exit Criteria**
- [ ] OpenCode v2 CLI installed and working
- [ ] ACP protocol verified end-to-end
- [ ] All core capabilities tested
- [ ] Protocol transcripts captured

---

## Phase 1: Core Protocol Layer (2 days)

**Goal**: Create ACP protocol types and JSON-RPC client for OpenCode.

### Tasks

- [ ] **T1.1: Create OpenCodeProtocol.swift**
  - Location: `Sources/BloomCore/Agent/OpenCode/OpenCodeProtocol.swift`
  - Define ACP JSON-RPC envelope types:
    - `OpenCodeRequest` (method, params, id)
    - `OpenCodeResponse` (result, error, id)
    - `OpenCodeNotification` (method, params)
  - Define ACP-specific types:
    - `OpenCodeRequestID` (handles Int and String ids)
    - `OpenCodeRPCError` (code, message, data)
    - `OpenCodeClientError` (connectionClosed, unexpectedResult, etc.)
  - **Template**: Reuse patterns from `CodexProtocol.swift`
  - **Owner**: Engineer
  - **Success**: Types compile, can parse real ACP messages

- [ ] **T1.2: Create ACP message parser**
  - Parse newline-delimited JSON from stdin
  - Classify frames: request (method+id), response (result/error+id), notification (method only)
  - Handle both numeric and string request IDs
  - **Note**: ACP spec says no `jsonrpc` member on wire, but we send it for compatibility
  - **Owner**: Engineer
  - **Success**: Parser handles all frame types from T0 transcripts

- [ ] **T1.3: Create OpenCodeClient.swift**
  - Location: `Sources/BloomCore/Agent/OpenCode/OpenCodeClient.swift`
  - Wrap `AgentProcessing` (StreamingProcess) for JSON-RPC
  - Send requests and receive responses
  - Handle notifications (no response expected)
  - Track pending requests by ID
  - **Template**: Reuse `CodexClient` patterns
  - **Owner**: Engineer
  - **Success**: Client can send/receive ACP messages

- [ ] **T1.4: Add ACP error handling**
  - Map JSON-RPC error codes to Swift errors
  - Handle connection drops gracefully
  - Define `OpenCodeClientError` cases
  - **Owner**: Engineer
  - **Success**: Errors are typed and handleable

- [ ] **T1.5: Unit tests for protocol layer**
  - Location: `Tests/BloomCoreTests/OpenCodeProtocolTests.swift`
  - Test parsing of all frame types
  - Test ID handling (Int vs String)
  - Test error parsing
  - **Owner**: Engineer
  - **Success**: All protocol parsing tests pass

**Phase 1 Exit Criteria**
- [ ] `OpenCodeProtocol.swift` compiles
- [ ] `OpenCodeClient.swift` compiles
- [ ] All protocol unit tests pass
- [ ] Can parse all captured transcripts from Phase 0

---

## Phase 2: Session Runner (3 days)

**Goal**: Create the main OpenCodeRunner that manages ACP sessions.

### Tasks

- [ ] **T2.1: Create OpenCodeRunner.swift skeleton**
  - Location: `Sources/BloomCore/Agent/OpenCode/OpenCodeRunner.swift`
  - Conform to `SessionRunner` protocol
  - Define properties:
    - `agentKind = .openCode`
    - `workspacePath`
    - `sessionID`
    - `store`
    - `makeClient`
    - `session` (private)
    - `client` (private, optional)
    - `threadID` / `sessionId` tracking
    - `grants` (SessionGrants)
    - `translation` (OpenCodeTranslation)
    - `handle` (ProcessHandle)
    - `sink` (EventFanout<AgentEvent>)
  - **Template**: Copy `GrokRunner.swift` structure
  - **Owner**: Engineer
  - **Success**: Skeleton compiles

- [ ] **T2.2: Implement ACP handshake**
  - Send `initialize` on start
  - Parse capabilities from response
  - Send `initialized` notification
  - Verify: `loadSession`, `fork`, `resume` capabilities
  - **Owner**: Engineer
  - **Success**: Handshake completes, capabilities verified

- [ ] **T2.3: Implement session/new**
  - Send `session/new` with:
    - `cwd`: workspacePath
    - `mcpServers`: bridge config (if available)
    - `_meta`: permissionMode, yoloMode, autoMode
  - Parse sessionId from response
  - Persist to `Session.agentSessionID` via store
  - **Owner**: Engineer
  - **Success**: New sessions created, ID persisted

- [ ] **T2.4: Implement session/prompt**
  - Send `session/prompt` with:
    - `sessionId`: current session
    - `message`: user message (role: user, content array)
  - Handle streaming response via `session/update` notifications
  - **Owner**: Engineer
  - **Success**: Messages sent, streaming works

- [ ] **T2.5: Implement session/cancel**
  - Send `session/cancel` notification
  - Cancel pending permission requests
  - Update session state
  - **Owner**: Engineer
  - **Success**: Turns can be interrupted

- [ ] **T2.6: Implement process lifecycle**
  - Start process via `makeProcess(AgentLaunch)`
  - Read stdout lines via `readTask`
  - Read stderr lines via `stderrTask` (for debugging, not merged)
  - Handle process exit
  - **Template**: Copy from `GrokRunner`
  - **Owner**: Engineer
  - **Success**: Process starts/stops cleanly

- [ ] **T2.7: Unit tests for runner**
  - Location: `Tests/BloomCoreTests/OpenCodeRunnerTests.swift`
  - Test handshake flow
  - Test session creation
  - Test message sending
  - Test cancellation
  - **Owner**: Engineer
  - **Success**: All runner unit tests pass

**Phase 2 Exit Criteria**
- [ ] `OpenCodeRunner.swift` compiles
- [ ] Handshake works
- [ ] Session creation works
- [ ] Message sending works
- [ ] All runner unit tests pass

---

## Phase 3: Event Translation (2 days)

**Goal**: Convert ACP events to Bloom's AgentEvent types.

### Tasks

- [ ] **T3.1: Create OpenCodeTranslation.swift**
  - Location: `Sources/BloomCore/Agent/OpenCode/OpenCodeTranslation.swift`
  - Define translation context (model, cwd, permissionMode)
  - **Owner**: Engineer
  - **Success**: Skeleton compiles

- [ ] **T3.2: Translate session/update notifications**
  - Map ACP update types to AgentEvent:
    | ACP Update Type | AgentEvent |
    |---------------|------------|
    | `agent_message_chunk` | `.textDelta(text, turnID)` |
    | `agent_thought_chunk` | `.thinkingDelta(text, turnID)` |
    | `tool_call` | `.toolCall(request, turnID)` |
    | `tool_call_update` | `.toolCallProgress(id, delta)` |
    | `tool_call_result` | `.toolCallResult(id, result)` |
    | `usage_update` | `.usageUpdate(usage)` |
    | `available_commands_update` | Ignore (or log) |
  - **Owner**: Engineer
  - **Success**: All update types mapped

- [ ] **T3.3: Translate request_permission**
  - Map ACP permission request to `AgentEvent.ask(.permission(request))`
  - Extract: action, path, options
  - Build Bloom PermissionRequest
  - **Owner**: Engineer
  - **Success**: Permission requests translate correctly

- [ ] **T3.4: Translate session status**
  - Map `session/status` to `.sessionStateChanged(state)`
  - Map `session/ended` to `.turnEnded(turnID)`
  - **Owner**: Engineer
  - **Success**: Session state changes translate correctly

- [ ] **T3.5: Handle turn tracking**
  - Detect turn start from first message chunk
  - Track turn ID across chunks
  - Emit `.turnStarted` when new turn begins
  - Emit `.turnEnded` when turn completes
  - **Owner**: Engineer
  - **Success**: Turn lifecycle events work

- [ ] **T3.6: Unit tests for translation**
  - Location: `Tests/BloomCoreTests/OpenCodeTranslationTests.swift`
  - Test all ACP → AgentEvent mappings
  - Test turn ID propagation
  - Test permission request translation
  - **Owner**: Engineer
  - **Success**: All translation tests pass

**Phase 3 Exit Criteria**
- [ ] `OpenCodeTranslation.swift` compiles
- [ ] All ACP events map to AgentEvents
- [ ] All translation unit tests pass

---

## Phase 4: Integration (2 days)

**Goal**: Wire OpenCodeRunner into Bloom's existing infrastructure.

### Tasks

- [ ] **T4.1: Update AgentKind.openCode**
  - File: `Sources/BloomCore/Model/Models.swift`
  - Update `canRunWorkspaces`: Add `.openCode` to true cases
  - Update `acceptsMidTurnMessage`: Add `.openCode` (assume true, verify later)
  - Update `loginCommand`: Already correct (`opencode auth login`)
  - Update `configPath`: Already correct (`~/.opencode`)
  - **Owner**: Engineer
  - **Success**: AgentKind updated

- [ ] **T4.2: Add OpenCodeRunner to SessionRunner factory**
  - File: `Sources/BloomCore/Agent/SessionRunner.swift` or factory
  - Add case for `.openCode` → `OpenCodeRunner(...)`
  - Pass required parameters (workspacePath, session, store, bridge)
  - **Owner**: Engineer
  - **Success**: Factory returns OpenCodeRunner for .openCode

- [ ] **T4.3: Create OpenCodeModelCatalog.swift**
  - Location: `Sources/BloomCore/Agent/OpenCode/OpenCodeModelCatalog.swift`
  - Conform to `AgentModelSource`
  - Implement `fetchModels()`:
    - Execute: `opencode models` CLI
    - Parse text output (provider/model format)
    - Map to `AgentModel` array
    - Handle `--refresh` flag for cache invalidation
  - **Owner**: Engineer
  - **Success**: Model discovery works

- [ ] **T4.4: Register OpenCode model source**
  - File: `Sources/BloomCore/Agent/AgentModelCatalog.swift` or similar
  - Add `OpenCodeModelSource` to `AgentModelSource.live`
  - **Owner**: Engineer
  - **Success**: OpenCode models appear in picker

- [ ] **T4.5: Update AgentCatalogTests.swift**
  - File: `Tests/BloomCoreTests/AgentCatalogTests.swift`
  - Update `describesKinds()` test:
    - Add `.openCode` to `canRunWorkspaces` assertion
  - **Owner**: Engineer
  - **Success**: Tests pass

- [ ] **T4.6: Update AGENTS-INTEGRATION.md**
  - File: `docs/AGENTS-INTEGRATION.md`
  - Update detection table: Mark OpenCode as installed/verified
  - Update "What Bloom can actually run" section: Add OpenCode
  - **Owner**: Engineer
  - **Success**: Documentation updated

**Phase 4 Exit Criteria**
- [ ] AgentKind.openCode canRunWorkspaces = true
- [ ] SessionRunner factory returns OpenCodeRunner
- [ ] OpenCode models appear in model picker
- [ ] All integration tests pass

---

## Phase 5: Advanced Features (2 days)

**Goal**: Implement session resume, permission handling, and MCP integration.

### Tasks

- [ ] **T5.1: Implement session/load (resume)**
  - In `OpenCodeRunner`:
    - Read `Session.agentSessionID` from store
    - If exists, send `session/load` instead of `session/new`
    - Handle history replay via `session/update` notifications
    - Verify session state restored
  - **Owner**: Engineer
  - **Success**: Sessions resume correctly

- [ ] **T5.2: Implement permission handling**
  - Handle incoming `request_permission` notifications
  - Map to `AgentEvent.ask(.permission(request))`
  - Track pending permission requests by ID
  - Send response based on user decision
  - Map OpenCode v2 actions to Bloom's permission model
  - **Owner**: Engineer
  - **Success**: Permissions work end-to-end

- [ ] **T5.3: Add MCP bridge registration**
  - Reuse `BridgeRegistration` from Grok integration
  - In `OpenCodeRunner` initialization:
    - Create bridge config if workspace bridge available
    - Pass `mcpServers` to `session/new`
  - **Owner**: Engineer
  - **Success**: MCP bridge registered with OpenCode

- [ ] **T5.4: Verify mid-turn message support**
  - Test: Send `session/prompt` while turn is active
  - Observe: Is message accepted or queued?
  - Update `AgentKind.openCode.acceptsMidTurnMessage` accordingly
  - **Owner**: Engineer
  - **Success**: Mid-turn behavior documented and configured

- [ ] **T5.5: Implement session/fork**
  - Add `forkSession(_:title:)` method
  - Send `session/fork` ACP request
  - Return new sessionId
  - **Owner**: Engineer (optional, if time permits)
  - **Success**: Session forking works

**Phase 5 Exit Criteria**
- [ ] Session resume works
- [ ] Permission handling works
- [ ] MCP bridge integration works
- [ ] Mid-turn message support verified

---

## Phase 6: Testing (2 days)

**Goal**: Comprehensive testing with real OpenCode v2 CLI.

### Tasks

- [ ] **T6.1: Integration test - Basic session**
  - Location: `Tests/BloomCoreTests/OpenCodeIntegrationTests.swift`
  - Test: Start OpenCode ACP, create session, send message, receive response
  - Requires: `BLOOM_LIVE=1` flag (opt-in, spends tokens)
  - **Owner**: Engineer
  - **Success**: Basic session test passes

- [ ] **T6.2: Integration test - Permission flow**
  - Test: Trigger permission request, approve, verify agent continues
  - Test: Trigger permission request, deny, verify agent aborts
  - **Owner**: Engineer
  - **Success**: Permission tests pass

- [ ] **T6.3: Integration test - Session resume**
  - Test: Create session, stop, resume, verify history
  - **Owner**: Engineer
  - **Success**: Resume test passes

- [ ] **T6.4: Integration test - Model selection**
  - Test: List models, select model, verify session uses it
  - **Owner**: Engineer
  - **Success**: Model selection test passes

- [ ] **T6.5: Fix any failures**
  - Address issues found in integration tests
  - Update implementation as needed
  - **Owner**: Engineer
  - **Success**: All integration tests pass

**Phase 6 Exit Criteria**
- [ ] All unit tests pass
- [ ] All integration tests pass (with BLOOM_LIVE=1)
- [ ] No regressions in existing tests

---

## Phase 7: Polish and Documentation (1 day)

**Goal**: Final polish, documentation, and cleanup.

### Tasks

- [ ] **T7.1: Update README.md**
  - File: `README.md`
  - Add OpenCode to list of supported agents
  - Update feature matrix
  - **Owner**: Engineer
  - **Success**: README updated

- [ ] **T7.2: Create OPENCODE-PROTOCOL.md**
  - File: `docs/OPENCODE-PROTOCOL.md`
  - Document captured transcripts from Phase 0
  - Document exact message shapes
  - Document any OpenCode-specific quirks
  - **Owner**: Engineer
  - **Success**: Protocol documentation complete

- [ ] **T7.3: Update release notes**
  - File: `RELEASING.md` or changelog
  - Add OpenCode v2 support entry
  - **Owner**: Engineer
  - **Success**: Release notes updated

- [ ] **T7.4: Code review and cleanup**
  - Review all new code
  - Fix style issues (SwiftLint)
  - Remove debug code
  - Add missing documentation comments
  - **Owner**: Team
  - **Success**: Code review complete, all lint checks pass

- [ ] **T7.5: Final verification**
  - Run full test suite
  - Test manually with real OpenCode
  - Verify no regressions
  - **Owner**: Engineer
  - **Success**: Everything works

**Phase 7 Exit Criteria**
- [ ] All documentation updated
- [ ] Code review complete
- [ ] All lint checks pass
- [ ] Full test suite passes

---

## Task Summary by Phase

| Phase | Duration | Tasks | Key Deliverables |
|-------|----------|-------|-----------------|
| 0: Preparation | 1 day | 7 | OpenCode CLI verified, transcripts captured |
| 1: Core Protocol | 2 days | 5 | OpenCodeProtocol.swift, OpenCodeClient.swift |
| 2: Session Runner | 3 days | 7 | OpenCodeRunner.swift |
| 3: Event Translation | 2 days | 6 | OpenCodeTranslation.swift |
| 4: Integration | 2 days | 6 | Wired into Bloom infrastructure |
| 5: Advanced Features | 2 days | 5 | Resume, permissions, MCP |
| 6: Testing | 2 days | 5 | All tests passing |
| 7: Polish | 1 day | 5 | Documentation, cleanup |
| **Total** | **15 days** | **41 tasks** | OpenCode v2 support complete |

---

## Resource Requirements

### People
- **Primary Engineer**: 1 FTE for 15 days
- **Code Review**: Team members as needed
- **Testing**: Engineer + QA (optional)

### Tools
- OpenCode v2 CLI installed on development machine
- API keys for at least one provider (for integration tests)
- macOS development environment

### Dependencies
- No new external dependencies required
- Reuses existing Bloom infrastructure

---

## Risk Management

### High Priority Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| OpenCode v2 API changes during implementation | Medium | High | Pin to specific version in tests, verify before each phase | Engineer |
| ACP protocol differences from Grok | Low | High | Use GrokRunner as template, test early with real CLI | Engineer |
| Mid-turn message not supported | Medium | Medium | Default to queuing, verify with real CLI, document limitation | Engineer |

### Medium Priority Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Model discovery format issues | Low | Medium | Parse text output if JSON not available | Engineer |
| Permission system v2 differences | Low | Medium | Map OpenCode v2 actions to Bloom's model | Engineer |
| Session resume quirks | Medium | Medium | Test thoroughly, handle edge cases | Engineer |

### Low Priority Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Performance issues with ACP | Low | Low | Optimize if needed, ACP is lightweight | Engineer |
| Documentation gaps | Low | Low | Fill in as we go, review at end | Engineer |

---

## Success Criteria

### Must Have (Phase 0-6)
- [ ] OpenCode v2 CLI detected and usable
- [ ] ACP protocol implemented and working
- [ ] Basic sessions work (create, message, response)
- [ ] Permission requests work
- [ ] Session resume works
- [ ] Model discovery works
- [ ] All unit tests pass
- [ ] All integration tests pass

### Should Have (Phase 5-6)
- [ ] MCP bridge integration works
- [ ] Mid-turn message support verified
- [ ] Session forking works
- [ ] Full error handling

### Nice to Have (Phase 7+)
- [ ] Session listing via ACP
- [ ] Advanced permission modes
- [ ] Custom agent support

---

## Tracking

### Progress Metrics
- Tasks completed: [X]/41
- Phases completed: [X]/8
- Days elapsed: [X]/15

### Daily Standup Questions
1. What did you complete yesterday?
2. What will you work on today?
3. Any blockers?

### Blockers Log
| Date | Blocker | Status | Resolution |
|------|---------|--------|------------|
| - | - | - | - |

---

## Communication

### Meetings
- **Kickoff**: Before Phase 0
- **Daily Standup**: 15 minutes, async via Slack/email
- **Phase Review**: End of each phase
- **Final Demo**: End of Phase 7

### Documentation
- **This Plan**: Living document, updated as we go
- **Integration Requirements**: [OPENCODE-V2-INTEGRATION.md](./OPENCODE-V2-INTEGRATION.md)
- **Protocol Details**: [OPENCODE-PROTOCOL.md](./OPENCODE-PROTOCOL.md) (to be created)
- **Code Comments**: Inline documentation in new files

---

## Appendix A: File Changes Summary

### New Files
```
Sources/BloomCore/Agent/OpenCode/
├── OpenCodeProtocol.swift    # ACP JSON-RPC types
├── OpenCodeClient.swift       # JSON-RPC client
├── OpenCodeTranslation.swift  # ACP → AgentEvent
├── OpenCodeRunner.swift       # Main session runner
└── OpenCodeModelCatalog.swift # Model discovery

Tests/BloomCoreTests/
├── OpenCodeProtocolTests.swift    # Protocol parsing tests
├── OpenCodeClientTests.swift       # Client tests
├── OpenCodeRunnerTests.swift       # Runner tests
├── OpenCodeTranslationTests.swift # Translation tests
└── OpenCodeIntegrationTests.swift # Integration tests

docs/
├── OPENCODE-V2-INTEGRATION.md     # Requirements (existing)
├── OPENCODE-IMPLEMENTATION-PLAN.md # This document
└── OPENCODE-PROTOCOL.md           # Protocol transcripts (TBD)
```

### Modified Files
```
Sources/BloomCore/Model/Models.swift           # AgentKind.openCode updates
Sources/BloomCore/Agent/SessionRunner.swift     # Add OpenCode case
Sources/BloomCore/Agent/AgentModelCatalog.swift # Add OpenCode source
docs/AGENTS-INTEGRATION.md                   # Update OpenCode section
README.md                                        # Add OpenCode to supported agents
Tests/BloomCoreTests/AgentCatalogTests.swift   # Update canRunWorkspaces test
```

---

## Appendix B: Quick Start for Engineers

### Setting Up
```bash
# Install OpenCode v2
curl -fsSL https://opencode.ai/install | bash

# Verify
opencode --version
opencode acp --help

# Test ACP
opencode acp --cwd /tmp/test &
ACP_PID=$!
echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"1"}}' > /tmp/acp_input
# (Send to process stdin)
```

### Running Tests
```bash
# Unit tests (no OpenCode needed)
./Tools/test-core.sh

# Integration tests (requires OpenCode and API keys)
BLOOM_LIVE=1 ./Tools/test-core.sh
```

### Debugging
```bash
# Enable verbose logging
OPENCODE_PRINT_LOGS=1 opencode acp --cwd /tmp/test

# Check OpenCode logs
~/.local/share/opencode/logs/
```

---

## Appendix C: Related Work

- **Codex Integration**: [docs/CODEX.md](./CODEX.md) - JSON-RPC app-server pattern
- **Grok Integration**: [docs/GROK.md](./GROK.md) - ACP pattern (closest template)
- **Claude Code Integration**: [docs/PROTOCOL.md](./PROTOCOL.md) - Stream-JSON pattern
- **Agent Integration Guide**: [docs/AGENTS-INTEGRATION.md](./AGENTS-INTEGRATION.md)

---

*Plan generated from OPENCODE-V2-INTEGRATION.md requirements document*
