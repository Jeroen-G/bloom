import Foundation
import Synchronization
import os

/// Supervises one `opencode acp` connection for one Bloom chat.
///
/// The shape is `GrokRunner`'s, deliberately: a long-lived process, the session id persisted the
/// moment it arrives so a crashed app can resume, every event written to the store before it
/// reaches the UI, and the same permission bookkeeping. What it is not is a second code path
/// inside `GrokRunner`. The two backends share the same ACP protocol, only the CLI differs.
public actor OpenCodeRunner: SessionRunner {
    public nonisolated let agentKind = AgentKind.openCode
    public nonisolated let workspacePath: String
    public nonisolated let sessionID: SessionID

    private let store: Store
    private let makeClient: @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient

    private var session: Session
    private var client: OpenCodeClient?
    private var pumpTask: Task<Void, Never>?
    private var translation: OpenCodeTranslation
    private var opencodeSessionID: String?
    /// Invalidates in-flight pump events when the client is replaced. A late `.closed` from a
    /// dead process must not drop the replacement.
    private var connectionGeneration: UInt64 = 0
    private var permissionConnectionID = UUID()

    private let grants: SessionGrants
    private var wireModel: String { ModelIdentifier.resolve(session.model).model }

    private var approvals: [String: OpenCodeServerRequest] = [:]

    private let connection = LiveConnection()
    private let pending = PendingAsks()
    private let handle = CodexTurnHandle()
    private let sink = EventFanout<AgentEvent>()
    private var trouble = PersistenceTrouble()
    private let bridge: BridgeAttachment?

    public init(
        workspacePath: String,
        session: Session,
        store: Store,
        bridge: BridgeAttachment? = nil,
        makeClient: @escaping @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient = OpenCodeRunner.spawn
    ) {
        self.workspacePath = workspacePath
        self.sessionID = session.id
        self.session = session
        self.store = store
        self.bridge = bridge
        self.makeClient = makeClient
        self.grants = SessionGrants(store: store, workspaceID: session.workspaceID)
        self.translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(
            model: ModelIdentifier.resolve(session.model).model,
            cwd: workspacePath,
            permissionMode: session.permissionMode.cliValue
        ))
    }

    public static let spawn: @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient = { configuration in
        OpenCodeClient(configuration: configuration)
    }

    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }

    public var isProcessAlive: Bool { connection.current?.isProcessAlive ?? false }

    public var currentSession: Session { session }

    public var lastPersistenceFailure: String? { trouble.lastSentence }

    public var persistenceFailureCount: Int { trouble.failures }

    static let clientVersion = "1.0"

    // MARK: - SessionRunner

    public func send(_ text: String, recording: Data? = nil) async throws {
        let generation = handle.generation
        let replacement = handle.prepareReplacement()
        defer { handle.finishReplacement(replacement) }
        try handle.check(generation)
        if handle.wasCancelled {
            for event in translation.finishInterruptedTurn() { await emit(event) }
            try handle.check(generation)
        }
        let client = try await connected()
        try handle.check(generation)
        let opencodeSessionID = try await openSession(on: client)
        try handle.check(generation)

        if let recording {
            await persist(kind: .crew, payload: recording)
        } else {
            await persist(kind: .user, payload: Self.userPayload(text))
        }
        try handle.check(generation)

        let promptID = try await client.beginPrompt(sessionID: opencodeSessionID, text: text)
        guard handle.begin(turnID: promptID.turnID, generation: generation) else {
            await client.cancel(sessionID: opencodeSessionID)
            throw CancellationError()
        }

        session.apply(.turnStarted)
        await save(session)
    }

    public nonisolated func cancelNow() {
        let stopped = handle.markCancelled()
        Task { await self.stopTurn(stopped) }
    }

    private func stopTurn(_ stopped: CodexTurnHandle.Stopped) async {
        if handle.generation == stopped.generation, handle.wasCancelled {
            for event in translation.finishInterruptedTurn() { await emit(event) }
            await filePendingAsks()
        }
        if handle.generation == stopped.generation, handle.wasCancelled,
           session.apply(.cancelled).moves { await save(session) }
        if handle.generation == stopped.generation, handle.wasCancelled, let opencodeSessionID {
            await client?.cancel(sessionID: opencodeSessionID)
        }
    }

    public nonisolated func terminateNow() {
        handle.markCancelled()
        connection.current?.terminateNow()
        Task { await self.shutdown() }
    }

    public func answer(requestID: String, decision: PermissionDecision) async {
        guard let ask = pending.take(requestID) else { return }
        let request = approvals[requestID]
        await write(answerTo: ask, decision: decision, request: request)
        await close(ask, as: decision.storedName, note: "")
        await grants.record(decision, from: ask)
    }

    public func shutdown() async {
        await filePendingAsks()
        if session.apply(.cancelled).moves { await save(session) }
        await dropConnection()
    }

    private func dropConnection() async {
        connectionGeneration += 1
        let closing = client
        let sessionToClose = opencodeSessionID
        client = nil
        opencodeSessionID = nil
        pumpTask?.cancel()
        pumpTask = nil
        handle.end()
        approvals.removeAll()
        for event in translation.finishInterruptedTurn() { await emit(event) }
        if let sessionToClose {
            await closing?.closeSession(sessionToClose)
        }
        await closing?.stop()
    }

    // MARK: - Connecting

    private func connected() async throws -> OpenCodeClient {
        if let client {
            if client.isProcessAlive, await client.isClosed == false {
                return client
            }
            await dropConnection()
        }

        let stored = try? await store.setting(AgentCatalog.executablePathSettingKey(.openCode))
        let client = makeClient(OpenCodeClient.Configuration(
            executable: AgentCatalog.executable(for: .openCode, override: stored),
            cwd: workspacePath,
            clientName: "Bloom",
            clientVersion: Self.clientVersion,
            model: wireModel,
            effort: session.effort,
            bridge: bridge
        ))
        self.client = client
        permissionConnectionID = UUID()
        connection.attach(client)
        let events = client.events
        let generation = connectionGeneration
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, from: generation)
            }
        }
        try await client.start()
        return client
    }

    private func openSession(on client: OpenCodeClient) async throws -> String {
        if let opencodeSessionID { return opencodeSessionID }

        let servers = BridgeRegistration.opencodeServers(bridge)
        let opened: OpenCodeSession
        if let stored = session.agentSessionID, !stored.isEmpty {
            do {
                opened = try await client.resumeSession(
                    stored,
                    cwd: workspacePath,
                    mcpServers: servers,
                    permissionMode: session.permissionMode
                )
            } catch {
                opened = try await client.newSession(
                    cwd: workspacePath,
                    mcpServers: servers,
                    permissionMode: session.permissionMode
                )
            }
        } else {
            opened = try await client.newSession(
                cwd: workspacePath,
                mcpServers: servers,
                permissionMode: session.permissionMode
            )
        }

        opencodeSessionID = opened.id
        translation.context.permissionMode = session.permissionMode.cliValue
        for event in translation.translateSessionReady(opened) {
            await emit(event)
        }
        if session.agentSessionID != opened.id {
            session = session.with {
                $0.agentSessionID = opened.id
                $0.updatedAt = Date()
            }
            await save(session)
        }
        return opened.id
    }

    // MARK: - Events

    private func handle(_ event: OpenCodeEvent, from generation: UInt64) async {
        guard generation == connectionGeneration else { return }

        if case .sessionEnded = event, handle.wasCancelled || trouble.hasStopped { return }

        if case .permissionRequest(let request) = event {
            if handle.wasCancelled {
                await client?.answer(request.id, with: OpenCodePermission.cancelledResult)
                return
            }
            await ask(request)
            return
        }

        if case .sessionUpdate = event, handle.wasCancelled { return }

        let ending: String? = switch event {
        case .promptResponse(let result): result.requestID.turnID
        default: nil
        }
        if let ending, !handle.acceptsTerminal(turnID: ending) { return }

        for translated in translation.translate(event) {
            await emit(translated, endingTurn: ending)
        }
    }

    private func emit(_ event: AgentEvent, endingTurn: String? = nil) async {
        let intent = handle.intent
        if event.isTranscriptRow {
            await persist(
                kind: event.kind,
                payload: event.raw.isEmpty ? Data("{}".utf8) : event.raw,
                refID: event.refID
            )
        }

        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn, intent: intent) { return }

        switch event {
        case .result(let result):
            handle.end()
            session.apply(.turnFinished(isError: result.isError))
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                if result.usage.contextTokens > 0 { $0.contextTokens = result.usage.contextTokens }
            }
            await save(session)

        case .error:
            handle.end()
            session.apply(.turnFinished(isError: true))
            await save(session)

        default:
            break
        }

        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn, intent: intent) { return }
        sink.yield(event)
    }

    // MARK: - Asking

    private func ask(_ request: OpenCodeServerRequest) async {
        let ask = OpenCodePermission.ask(for: request, connectionID: permissionConnectionID)
        pending.add(ask)
        approvals[ask.requestID] = request

        do {
            try await store.appendPermissionAsk(sessionID: session.id, ask: ask)
        } catch {
            await report("could not store a permission question", error)
        }
        await persist(kind: .permissionAsk, payload: ask.raw, refID: ask.toolUseID)
        sink.yield(.permissionAsk(ask))

        let matched = await grants.matching(ask)
        if let matched, let claimed = pending.take(ask.requestID) {
            await write(answerTo: claimed, decision: .allow(scope: .session), request: request)
            await close(claimed, as: PermissionAskOutcome.auto, note: PermissionGrantIndex.note(for: matched))
            await grants.recordUse(of: matched)
            return
        }

        guard matched == nil, pending.contains(ask.requestID) else { return }
        session.apply(.blocked)
        await save(session)
    }

    /// Stop and quit answer pending asks as ACP `cancelled`, not `reject_always`.
    private func filePendingAsks() async {
        for ask in pending.drain() {
            if let request = approvals[ask.requestID] {
                await client?.answer(request.id, with: OpenCodePermission.cancelledResult)
            }
            await close(ask, as: PermissionAskOutcome.stopped, note: "")
        }
        if session.apply(.unblocked).moves { await save(session) }
    }

    private func write(
        answerTo ask: PermissionAsk,
        decision: PermissionDecision,
        request: OpenCodeServerRequest?
    ) async {
        if let request {
            if let optionID = OpenCodePermission.optionID(for: decision, in: request) {
                await client?.answer(request.id, with: OpenCodePermission.selectedResult(optionID: optionID))
            } else {
                await client?.answer(request.id, with: OpenCodePermission.cancelledResult)
            }
        }
        approvals[ask.requestID] = nil
        guard pending.isEmpty else { return }
        guard session.apply(.unblocked).moves else { return }
        await save(session)
    }

    private func close(_ ask: PermissionAsk, as decision: String, note: String) async {
        pending.remove(ask.requestID)
        approvals[ask.requestID] = nil
        do {
            try await store.resolvePermissionAsk(id: ask.requestID, decision: decision)
        } catch {
            await report("could not record a permission decision", error)
        }
        sink.yield(.permissionDecided(PermissionResolution(
            requestID: ask.requestID,
            toolUseID: ask.toolUseID,
            decision: decision,
            note: note
        )))
    }

    // MARK: - Storage

    static func userPayload(_ text: String) -> Data {
        let json = JSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    private func persist(kind: MessageKind, payload: Data, refID: String? = nil) async {
        do {
            try await store.appendNext(
                sessionID: session.id,
                kind: kind,
                payload: payload,
                refID: refID
            )
        } catch {
            await report("could not store a \(kind.rawValue) row", error)
        }
    }

    private func save(_ session: Session) async {
        do {
            try await store.update(sessionID: session.id) {
                $0.agentSessionID = session.agentSessionID
                $0.state = session.state
                $0.inputTokens = session.inputTokens
                $0.outputTokens = session.outputTokens
                $0.contextTokens = session.contextTokens
                $0.updatedAt = session.updatedAt
            }
        } catch {
            await report("could not save the session", error)
        }
    }

    private func report(_ what: String, _ error: Error) async {
        Self.log.error("\(what, privacy: .public): \(error.readableMessage, privacy: .public)")

        let standing = await TranscriptStanding.of(sessionID: session.id, in: store)
        switch trouble.record(WorkspaceTrouble.recording(
            transcript: standing, complaint: TranscriptStanding.complaint(about: error)
        )) {
        case .tell(let sentence):
            sink.yield(.error(.storage(message: sentence)))
        case .stop:
            Self.log.info("the transcript for \(self.session.id.rawValue, privacy: .public) has been removed, so this run is being stopped without a word")
            terminateNow()
        case .alreadyStopped:
            break
        }
    }

    var transcriptWasRemoved: Bool { trouble.hasStopped }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.spatie.bloom",
        category: "opencode-runner"
    )
}

// MARK: - Supporting Types

/// Session information returned by OpenCode ACP.
public struct OpenCodeSession: Sendable, Hashable {
    public let id: String
    public let currentModelID: String

    public init(id: String, currentModelID: String = "") {
        self.id = id
        self.currentModelID = currentModelID
    }
}

/// Permission handling for OpenCode.
public enum OpenCodePermission {
    /// Build a permission ask from a server request.
    public static func ask(for request: OpenCodeServerRequest, connectionID: UUID) -> PermissionAsk {
        let action = request.params["action"]?.stringValue ?? ""
        let description = request.params["description"]?.stringValue ?? ""
        let toolUseID = request.params["toolUseId"]?.stringValue ?? request.id.turnID
        
        return PermissionAsk(
            requestID: request.id.turnID,
            toolUseID: toolUseID,
            kind: .openCodePermission,
            subject: description,
            raw: request.raw,
            connectionID: connectionID
        )
    }

    /// Result for cancelled permission requests.
    public static var cancelledResult: JSONValue {
        .object(["status": .string("cancelled")])
    }

    /// Result for selected permission option.
    public static func selectedResult(optionID: String) -> JSONValue {
        .object(["status": .string("approved"), "optionId": .string(optionID)])
    }

    /// Extract option ID for a decision from a permission request.
    public static func optionID(for decision: PermissionDecision, in request: OpenCodeServerRequest) -> String? {
        // Map Bloom's PermissionDecision to OpenCode's permission options
        // This may need adjustment based on actual OpenCode ACP behavior
        switch decision {
        case .allow:
            return "allow"
        case .deny:
            return "deny"
        case .answer:
            // For input requests, the answer is in the decision
            return "provide"
        default:
            return nil
        }
    }
}

/// Bridge registration for OpenCode.
extension BridgeRegistration {
    /// Build OpenCode-specific MCP server configuration.
    public static func opencodeServers(_ bridge: BridgeAttachment?) -> [String: JSONValue]? {
        guard let bridge else { return nil }
        var servers: [String: JSONValue] = [:]
        
        if let config = bridge.mcpConfig {
            servers["config"] = .string(config)
        }
        
        if !bridge.environment.isEmpty {
            servers["env"] = .object(bridge.environment.mapValues { .string($0) })
        }
        
        return servers.isEmpty ? nil : servers
    }
}

/// The live connection, where synchronous code can reach it.
private final class LiveConnection: Sendable {
    private let client = Mutex<OpenCodeClient?>(nil)

    var current: OpenCodeClient? { client.withLock { $0 } }

    func attach(_ client: OpenCodeClient) {
        self.client.withLock { $0 = client }
    }
}

// MARK: - OpenCodeEvent Extensions

extension OpenCodeEvent {
    /// Whether this event represents a closed connection.
    var isClosed: Bool {
        switch self {
        case .sessionEnded: true
        default: false
        }
    }

    /// Whether this event represents a prompt completion.
    var isPromptCompleted: Bool {
        switch self {
        case .promptResponse: true
        default: false
        }
    }
}
