import Foundation
import Synchronization

/// One `opencode acp` process, spoken to in ACP JSON-RPC.
///
/// The process is long lived: stdin stays open, a follow-up turn is another `session/prompt`,
/// and the session id survives so a restarted app can `session/load`. `StreamingProcess`
/// already does line-delimited JSON over a held-open stdin.
///
/// Three things separate this from `AgentRunner`'s reader, and all three come from JSON-RPC:
///
///   1. **Requests have replies.** `session/new` returns a session id instead of a notification
///      arriving later that somebody has to correlate by hand.
///   2. **The server asks too.** `session/request_permission` is a server-to-client request, and
///      a client that cannot answer would leave every one hanging until the turn timed out.
///   3. **`session/prompt` is the turn.** Unlike Codex's `turn/start`, which returns immediately,
///      ACP holds the prompt request open until the turn ends. Bloom therefore must not wait on
///      it inside `send`: the reply is an event, and a timeout would kill a real turn.
///
/// This client is heavily based on `GrokClient` since both speak ACP JSON-RPC over stdio.
public actor OpenCodeClient {
    // MARK: Configuration

    public struct Configuration: Sendable {
        public var executable: String
        /// The directory the agent works in.
        public var cwd: String
        /// `OPENCODE_CONFIG_DIR`, when it must not be the user's. Absent means the real one.
        public var opencodeConfigDir: String?
        public var clientName: String
        public var clientVersion: String
        public var environment: [String: String]
        public var model: String
        public var effort: String
        /// The workspace bridge this process should register, or nil for none.
        public var bridge: BridgeAttachment?

        public init(
            executable: String = OpenCodeClient.executable,
            cwd: String,
            opencodeConfigDir: String? = nil,
            clientName: String = "Bloom",
            clientVersion: String = "0.0.0",
            environment: [String: String] = Shell.environment(),
            model: String = "",
            effort: String = "",
            bridge: BridgeAttachment? = nil
        ) {
            self.executable = executable
            self.cwd = cwd
            self.opencodeConfigDir = opencodeConfigDir
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.environment = environment
            self.model = model
            self.effort = effort
            self.bridge = bridge
        }
    }

    public static let executable = "opencode"
    public static let arguments = ["acp"]

    /// Build the launch configuration for the OpenCode ACP process.
    public static func launch(_ configuration: Configuration) -> AgentLaunch {
        var environment = configuration.environment
        // Disable auto-updater to prevent banners on stdout
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        if let configDir = configuration.opencodeConfigDir, !configDir.isEmpty {
            environment["OPENCODE_CONFIG_DIR"] = configDir
        }

        var arguments: [String] = ["acp"]
        arguments.append("--cwd")
        arguments.append(configuration.cwd)

        // Register MCP bridge if available
        if let bridge = configuration.bridge {
            arguments += BridgeRegistration.opencodeArguments(bridge)
        }

        // Model and effort selection
        if !configuration.model.isEmpty {
            arguments += ["--model", configuration.model]
        }
        // Note: OpenCode v2 uses --variant for reasoning effort, not --effort
        // This may need adjustment based on actual CLI behavior
        if !configuration.effort.isEmpty {
            arguments += ["--variant", configuration.effort]
        }

        return AgentLaunch(
            executable: configuration.executable,
            arguments: arguments,
            cwd: configuration.cwd,
            environment: environment
        )
    }

    // MARK: State

    private let configuration: Configuration
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing
    private var process: (any AgentProcessing)?
    /// The same process again, held outside the actor so it can be signalled without waiting for
    /// a turn on one.
    private let live = LiveProcess()
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    private var nextRequestID = 1
    private var pending: [OpenCodeRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    /// Prompt requests are not waited on. Their ids live here so the reply becomes an event
    /// rather than resuming a continuation that would pin `send` to the whole turn.
    private var promptIDs: Set<OpenCodeRequestID> = []
    private var handshakeCompleted = false
    private var closedReason: String?
    private var advertised: [OpenCodeModel] = []
    private var currentModelID = ""

    /// stderr, kept short. It only ever surfaces when the process dies without answering, which is
    /// the one moment a tracing line is worth reading.
    private var stderrTail: [String] = []
    private static let stderrTailLimit = 40

    private let sink = EventFanout<OpenCodeEvent>()

    public init(
        configuration: Configuration,
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = OpenCodeClient.spawn
    ) {
        self.configuration = configuration
        self.makeProcess = makeProcess
    }

    public static let spawn: @Sendable (AgentLaunch) -> any AgentProcessing = { launch in
        StreamingProcess(
            executable: launch.executable,
            arguments: launch.arguments,
            cwd: launch.cwd,
            environment: launch.environment,
            mergeStderr: false
        )
    }

    /// Decoded events, as a fresh stream per caller. See `EventFanout`.
    public nonisolated var events: AsyncStream<OpenCodeEvent> { sink.stream() }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// The same answer, readable without the actor, which is what a quit path polling for the
    /// process to actually be gone needs.
    public nonisolated var isProcessAlive: Bool { live.current?.isRunning ?? false }

    public var isClosed: Bool { closedReason != nil }

    public var isReady: Bool { handshakeCompleted }

    public var diagnostics: [String] { stderrTail }

    /// Models advertised by OpenCode during initialize handshake.
    public func advertisedModels() -> [OpenCodeModel] { advertised }

    public static let requestTimeout = Duration.seconds(120)

    // MARK: Lifecycle

    /// Launches the OpenCode ACP server and completes the handshake.
    ///
    /// `initialize` is a request and `initialized` is a notification, in that order. Nothing else
    /// may be sent in between: the server rejects work before the handshake, and sending
    /// `initialized` without waiting for the reply races the connection's own setup.
    public func start() async throws {
        guard process == nil else { return }

        let process = makeProcess(Self.launch(configuration))
        self.process = process
        live.attach(process)

        let errors = process.errorLines
        let lines = process.lines
        readTask = Task { [weak self] in await self?.readLines(from: lines) }
        stderrTask = Task { [weak self] in await self?.readErrors(from: errors) }

        // Send initialize request
        let result = try await send(
            "initialize",
            params: .object([
                "protocolVersion": .string("1"),
                "clientInfo": .object([
                    "name": .string(configuration.clientName),
                    "version": .string(configuration.clientVersion),
                ]),
                // Empty on purpose. Advertising capabilities makes the agent ask Bloom to
                // perform actions; Bloom is not that client. OpenCode has its own tools.
                "capabilities": .object([:]),
            ])
        )

        // Parse capabilities from initialize response
        // OpenCode v2 advertises: loadSession, fork, resume, mcpCapabilities
        let capabilities = result["capabilities"] ?? .object([:])
        let sessionCapabilities = capabilities["sessionCapabilities"] ?? .object([:]) 
        let loadSession = capabilities["loadSession"]?.boolValue ?? false
        let fork = capabilities["fork"]?.boolValue ?? false
        let resume = sessionCapabilities["resume"]?.boolValue ?? false

        // Parse model information if available
        // OpenCode may include model info in initialize response or via separate call
        // For now, we'll fetch models via CLI if needed

        // Notify that handshake is complete
        notify("initialized", params: .object([:]))
        handshakeCompleted = true
    }

    public func stop() {
        terminateNow()
        finish(reason: "The OpenCode connection was closed")
    }

    public nonisolated func terminateNow() {
        guard let process = live.claimForSignal() else { return }
        process.closeStdin()
        process.terminate()
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, process.isRunning else { return }
            process.kill()
        }
    }

    // MARK: Sending

    /// Send a request and wait for the response.
    ///
    /// Used for requests that expect a synchronous response, like `initialize`, `session/new`,
    /// `session/load`. Not used for `session/prompt` which streams via notifications.
    @discardableResult
    public func send(
        _ method: String, params: JSONValue?, timeout: Duration = OpenCodeClient.requestTimeout
    ) async throws -> JSONValue {
        if let closedReason { throw OpenCodeClientError.connectionClosed(closedReason) }
        guard process != nil else { throw OpenCodeClientError.notInitialized }

        let id = OpenCodeRequestID.number(nextRequestID)
        nextRequestID += 1

        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.abandon(id, method: method, after: timeout)
        }

        // For session/prompt, we don't wait for a response - it streams via notifications
        // So we track it separately and don't add to pending
        if method == "session/prompt" {
            promptIDs.insert(id)
            let line = OpenCodeOutgoing.request(id: id, method: method, params: params)
            process?.writeLine(line)
            watchdog.cancel()
            return .null  // Return null since we don't wait for response
        }

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    pending[id] = continuation
                    let line = OpenCodeOutgoing.request(id: id, method: method, params: params)
                    process?.writeLine(line)
                }
            },
            onCancel: { [weak self] in
                watchdog.cancel()
                Task { [weak self] in
                    await self?.abandon(id, method: method, after: .zero)
                }
            }
        ) { _ in
            watchdog.cancel()
        }
    }

    /// Send a notification (no response expected).
    public func notify(_ method: String, params: JSONValue?) {
        guard !isClosed else { return }
        let line = OpenCodeOutgoing.notification(method: method, params: params)
        process?.writeLine(line)
    }

    /// Send a response to a server-to-client request (e.g., permission approval).
    public func answer(_ id: OpenCodeRequestID, with result: JSONValue) {
        guard !isClosed else { return }
        let line = OpenCodeOutgoing.response(id: id, result: result)
        process?.writeLine(line)
    }

    /// Send an error response to a server-to-client request.
    public func answer(_ id: OpenCodeRequestID, withError code: Int, message: String) {
        guard !isClosed else { return }
        let line = OpenCodeOutgoing.failure(id: id, code: code, message: message)
        process?.writeLine(line)
    }

    // MARK: Typed calls

    /// Creates a new OpenCode session.
    ///
    /// - Parameters:
    ///   - cwd: Working directory for the session
    ///   - mcpServers: MCP server configurations
    ///   - permissionMode: Permission mode for the session
    /// - Returns: OpenCodeSession with session ID and model info
    public func newSession(
        cwd: String? = nil,
        mcpServers: [String: JSONValue]? = nil,
        permissionMode: PermissionMode = .auto
    ) async throws -> OpenCodeSession {
        let result = try await send("session/new", params: sessionParams(
            sessionID: nil,
            cwd: cwd,
            mcpServers: mcpServers,
            permissionMode: permissionMode
        ))
        guard let session = OpenCodeSession.decode(result) else {
            throw OpenCodeClientError.unexpectedResult(method: "session/new")
        }
        return session
    }

    /// Resumes an existing OpenCode session.
    ///
    /// - Parameters:
    ///   - sessionID: The session ID to resume
    ///   - cwd: Working directory for the session
    ///   - mcpServers: MCP server configurations
    ///   - permissionMode: Permission mode for the session
    /// - Returns: OpenCodeSession with session ID and model info
    public func resumeSession(
        _ sessionID: String,
        cwd: String? = nil,
        mcpServers: [String: JSONValue]? = nil,
        permissionMode: PermissionMode = .auto
    ) async throws -> OpenCodeSession {
        let result = try await send("session/load", params: sessionParams(
            sessionID: sessionID,
            cwd: cwd,
            mcpServers: mcpServers,
            permissionMode: permissionMode
        ))
        if let session = OpenCodeSession.decode(result) {
            return session
        }
        return OpenCodeSession(id: sessionID, currentModelID: currentModelID)
    }

    /// Starts a turn without waiting for it. The `session/prompt` reply arrives later as
    /// `.promptResponse` or `.promptError`.
    ///
    /// - Parameters:
    ///   - sessionID: The session ID to send the prompt to
    ///   - text: The prompt text
    /// - Returns: The request ID for tracking
    @discardableResult
    public func beginPrompt(sessionID: String, text: String) throws -> OpenCodeRequestID {
        if let closedReason { throw OpenCodeClientError.connectionClosed(closedReason) }
        guard process != nil else { throw OpenCodeClientError.notInitialized }
        let id = OpenCodeRequestID.number(nextRequestID)
        nextRequestID += 1
        promptIDs.insert(id)
        let line = OpenCodeOutgoing.request(
            id: id,
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ])
        )
        process?.writeLine(line)
        return id
    }

    /// Cancels the current turn in the session.
    public func cancel(sessionID: String) {
        notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
    }

    /// Closes the session gracefully.
    public func closeSession(_ sessionID: String) async {
        _ = try? await send("session/close", params: .object(["sessionId": .string(sessionID)]))
    }

    /// Builds session parameters for new/resume session calls.
    private func sessionParams(
        sessionID: String?,
        cwd: String?,
        mcpServers: [String: JSONValue]?,
        permissionMode: PermissionMode
    ) -> JSONValue {
        var members: [String: JSONValue?] = [
            "cwd": .string(cwd ?? configuration.cwd),
            "_meta": .object([
                "yoloMode": .bool(permissionMode == .bypassPermissions),
                "autoMode": .bool(permissionMode == .auto || permissionMode == .autoReview),
                "permissionMode": .string(permissionMode.cliValue),
            ]),
        ]
        if let sessionID { members["sessionId"] = .string(sessionID) }
        if let mcpServers, !mcpServers.isEmpty {
            members["mcpServers"] = .object(mcpServers)
        }
        return .object(omittingNil: members)
    }

    // MARK: Reading

    /// Read and decode lines from the process stdout.
    private func readLines(from lines: AsyncThrowingStream<String, Error>) async {
        do {
            for try await line in lines {
                await decodeAndRoute(line)
            }
        } catch {
            finish(reason: "Read error: \(error.localizedDescription)")
        }
        finish(reason: "stdout closed")
    }

    /// Read stderr for diagnostics.
    private func readErrors(from lines: AsyncStream<String>) async {
        for await line in lines {
            await appendStderr(line)
        }
    }

    /// Decode a line and route it to the appropriate handler.
    private func decodeAndRoute(_ line: String) async {
        guard let frame = OpenCodeFrame.decode(line: line) else {
            await appendStderr("Malformed frame: \(line.prefix(100))")
            return
        }

        switch frame {
        case .response(let id, let result, _):
            await handleResponse(id: id, result: result)

        case .failure(let id, let error, _):
            await handleFailure(id: id, error: error)

        case .request(let request):
            await handleServerRequest(request)

        case .notification(let notification):
            await handleNotification(notification)

        case .malformed(let data):
            await appendStderr("Malformed: \(String(decoding: data.prefix(100), as: UTF8.self))")
        }
    }

    private func handleResponse(id: OpenCodeRequestID, result: JSONValue) async {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: result)
        } else if promptIDs.remove(id) != nil {
            // This is a response to a session/prompt we sent
            // We don't wait on these, so just emit as event
            sink.yield(.promptResponse(id: id, result: result))
        } else {
            // Unexpected response - might be from a previous session
            // Log and ignore
        }
    }

    private func handleFailure(id: OpenCodeRequestID, error: OpenCodeRPCError) async {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: OpenCodeClientError.unexpectedResult(method: ""))
        } else if promptIDs.remove(id) != nil {
            sink.yield(.promptError(id: id, error: error))
        } else {
            // Unexpected failure
        }
    }

    private func handleServerRequest(_ request: OpenCodeServerRequest) async {
        // Server-to-client request, most commonly permission requests
        switch request.method {
        case "session/request_permission":
            sink.yield(.permissionRequest(request))
        default:
            // Unknown server request - log and emit
            sink.yield(.unknownServerRequest(request))
        }
    }

    private func handleNotification(_ notification: OpenCodeServerNotification) async {
        switch notification.method {
        case "session/update":
            sink.yield(.sessionUpdate(notification))
        case "session/status":
            sink.yield(.sessionStatus(notification))
        case "session/ended":
            sink.yield(.sessionEnded(notification))
        default:
            // Unknown notification - emit for potential handling
            sink.yield(.unknownNotification(notification))
        }
    }

    private func appendStderr(_ line: String) async {
        stderrTail.append(line)
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit)
        }
    }

    private func abandon(id: OpenCodeRequestID, method: String, after timeout: Duration) async {
        guard pending.removeValue(forKey: id) != nil else { return }
        finish(reason: "OpenCode did not respond to \(method) in time")
    }

    private func finish(reason: String) {
        closedReason = reason
        for continuation in pending.values {
            continuation.resume(throwing: OpenCodeClientError.connectionClosed(reason))
        }
        pending.removeAll()
        promptIDs.removeAll()
    }
}

// MARK: - Event types

/// Events emitted by the OpenCodeClient to its consumers.
public enum OpenCodeEvent: Sendable {
    /// Response to a session/prompt request (we don't wait on these)
    case promptResponse(id: OpenCodeRequestID, result: JSONValue)
    /// Error response to a session/prompt request
    case promptError(id: OpenCodeRequestID, error: OpenCodeRPCError)
    /// Server-to-client permission request
    case permissionRequest(OpenCodeServerRequest)
    /// Unknown server-to-client request
    case unknownServerRequest(OpenCodeServerRequest)
    /// Session update notification (streaming content)
    case sessionUpdate(OpenCodeServerNotification)
    /// Session status notification
    case sessionStatus(OpenCodeServerNotification)
    /// Session ended notification
    case sessionEnded(OpenCodeServerNotification)
    /// Unknown notification
    case unknownNotification(OpenCodeServerNotification)
}

// MARK: - Session representation

/// Session information returned by OpenCode ACP.
public struct OpenCodeSession: Sendable {
    public let id: String
    public let currentModelID: String

    public init(id: String, currentModelID: String = "") {
        self.id = id
        self.currentModelID = currentModelID
    }

    /// Decode session from JSON response.
    public static func decode(_ value: JSONValue) -> OpenCodeSession? {
        guard case .object(let object) = value else { return nil }
        let id = object["id"]?.stringValue ?? object["sessionId"]?.stringValue ?? ""
        let currentModelID = object["currentModelId"]?.stringValue ?? ""
        guard !id.isEmpty else { return nil }
        return OpenCodeSession(id: id, currentModelID: currentModelID)
    }
}

// MARK: - Model representation

/// Represents a model available from OpenCode.
public struct OpenCodeModel: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let provider: String
    public let contextWindow: Int?
    public let pricing: JSONValue?

    public init(id: String, name: String, provider: String, contextWindow: Int? = nil, pricing: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.contextWindow = contextWindow
        self.pricing = pricing
    }

    /// Decode a list of models from OpenCode's model listing.
    /// OpenCode models are in format: provider/model-name
    public static func decodeList(_ value: JSONValue) -> [OpenCodeModel] {
        // OpenCode may return models in different formats
        // For now, we'll handle the basic case
        // This can be expanded based on actual API response
        guard case .array(let array) = value else { return [] }
        return array.compactMap { item in
            guard case .string(let id) = item else { return nil }
            let parts = id.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return OpenCodeModel(
                id: id,
                name: String(parts[1]),
                provider: String(parts[0])
            )
        }
    }
}

// MARK: - Bridge Registration for OpenCode

extension BridgeRegistration {
    /// Build OpenCode-specific MCP server arguments for bridge registration.
    public static func opencodeArguments(_ bridge: BridgeAttachment) -> [String] {
        // OpenCode ACP accepts mcpServers as part of session/new params
        // We need to check if OpenCode acp command supports direct MCP args
        // For now, we'll pass via environment or config
        // This may need adjustment based on actual OpenCode CLI behavior
        var args: [String] = []
        
        // If OpenCode supports --mcp-config or similar, add it here
        // Based on docs, OpenCode uses config files for MCP servers
        // So we may need to write a config file instead
        
        return args
    }
}
