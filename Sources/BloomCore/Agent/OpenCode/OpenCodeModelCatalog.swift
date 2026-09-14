import Foundation

/// One model OpenCode advertises through ACP `initialize` / `session/new`.
///
/// Fetched, never hardcoded. Model lists change frequently and a hardcoded list would
/// quickly become outdated.
public struct OpenCodeModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let provider: String
    public let description: String
    public let isDefault: Bool
    public let contextTokens: Int
    public let pricing: JSONValue?
    public let supportedEfforts: [AgentModelEffort]
    public let defaultEffort: String

    public init(
        id: String,
        displayName: String,
        provider: String = "",
        description: String = "",
        isDefault: Bool = false,
        contextTokens: Int = 0,
        pricing: JSONValue? = nil,
        supportedEfforts: [AgentModelEffort] = [],
        defaultEffort: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.description = description
        self.isDefault = isDefault
        self.contextTokens = contextTokens
        self.pricing = pricing
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
    }

    public var agentModel: AgentModel {
        AgentModel(
            id: id,
            displayName: displayName,
            isDefault: isDefault,
            supportedEfforts: supportedEfforts,
            defaultEffort: defaultEffort
        )
    }

    /// The bare model name, without its provider. Read by callers that only have the id.
    public var name: String { displayName }

    /// Decode a model from JSON.
    public static func decode(_ json: JSONValue, currentModelID: String) -> OpenCodeModel? {
        let id = json["id"]?.stringValue ?? json["modelId"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        
        // Parse provider from model ID (format: provider/model-name)
        let parts = id.split(separator: "/", maxSplits: 1)
        let provider: String
        let displayName: String
        if parts.count == 2 {
            provider = String(parts[0])
            displayName = String(parts[1])
        } else {
            provider = ""
            displayName = json["name"]?.stringValue ?? json["displayName"]?.stringValue ?? id
        }
        
        return OpenCodeModel(
            id: id,
            displayName: displayName,
            provider: provider,
            description: json["description"]?.stringValue ?? "",
            isDefault: id == currentModelID,
            contextTokens: json["contextWindow"]?.intValue ?? json["maxTokens"]?.intValue ?? 0,
            pricing: json["pricing"]
        )
    }

    /// Decode a list of models from JSON.
    ///
    /// OpenCode has been seen to advertise models two ways: as objects carrying an id, and as
    /// bare `provider/model` strings. Both are accepted, because a list that silently came back
    /// empty would look like an account with no models rather than a shape Bloom did not read.
    public static func decodeList(_ json: JSONValue) -> [OpenCodeModel] {
        if let array = json.arrayValue {
            return array.compactMap { item in
                if let id = item.stringValue {
                    let parts = id.split(separator: "/", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return OpenCodeModel(
                        id: id,
                        displayName: String(parts[1]),
                        provider: String(parts[0])
                    )
                }
                return decode(item, currentModelID: "")
            }
        }

        let current = json["currentModelId"]?.stringValue ?? json["currentModel"]?.stringValue ?? ""
        let items = json["models"]?.arrayValue
            ?? json["availableModels"]?.arrayValue
            ?? json["data"]?.arrayValue
            ?? []
        return items.compactMap { decode($0, currentModelID: current) }
    }

    /// The models OpenCode v2 advertises in the `session/new` response, read from
    /// `configOptions`.
    ///
    /// v2 stopped naming models in `initialize`: the list now travels in the session response as
    /// a `select` whose `id` is `model`, with `options` of `{value, name}` and the chosen model in
    /// `currentValue`. The same response carries the session's effort levels in an `effort`
    /// select, shared by every model until a session overrides them.
    ///
    /// Returns nil when the value has no `configOptions`, so a caller can fall back to the v1
    /// `modelState` shape. Returns an empty list when the shape is present but names no models.
    public static func decodeConfigOptions(_ json: JSONValue) -> [OpenCodeModel]? {
        guard let options = json["configOptions"]?.arrayValue else { return nil }
        guard let modelSelect = options.first(where: { $0["id"]?.stringValue == "model" }) else {
            return []
        }
        let current = modelSelect["currentValue"]?.stringValue ?? ""

        // The effort select travels in the same response, once per session. Its options are the
        // levels every model takes until a session pins its own (see `OpenCodeModel.agentModel`).
        let effortSelect = options.first { $0["id"]?.stringValue == "effort" }
        let efforts = (effortSelect?["options"]?.arrayValue ?? []).compactMap { item -> AgentModelEffort? in
            guard let id = item["value"]?.stringValue, !id.isEmpty else { return nil }
            return AgentModelEffort(id: id, label: item["name"]?.stringValue ?? id)
        }
        let defaultEffort = effortSelect?["currentValue"]?.stringValue ?? ""

        return (modelSelect["options"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["value"]?.stringValue, !id.isEmpty else { return nil }
            let provider = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            // v2 labels carry the provider prefix ("opencode/GPT-5.5"); the model menu has
            // always shown the name without it.
            let name = item["name"]?.stringValue ?? id
            let displayName = (!provider.isEmpty && name.hasPrefix(provider + "/"))
                ? String(name.dropFirst(provider.count + 1))
                : name
            return OpenCodeModel(
                id: id,
                displayName: displayName,
                provider: provider,
                isDefault: id == current,
                supportedEfforts: efforts,
                defaultEffort: defaultEffort
            )
        }
    }
}

/// The models OpenCode offers, fetched once and kept.
///
/// Fetched from ACP `session/new`, whose `configOptions` carries the model list since v2, without
/// spending a turn. A short-lived `opencode acp` is spawned per fetch, the same shape as
/// `GrokModelCatalog`, so listing models is not a process the user did not ask for hanging around
/// between picker openings.
public actor OpenCodeModelCatalog {
    public static let freshness = AgentModelCache<OpenCodeModel>.freshness

    private let cache: AgentModelCache<OpenCodeModel>

    public var fetchCount: Int { get async { await cache.fetchCount } }

    public init(
        fetch: @escaping @Sendable () async throws -> [OpenCodeModel],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        cache = AgentModelCache(fetch: { Self.sorted(try await fetch()) }, now: now)
    }

    /// The catalog the app uses: one short-lived `opencode acp` connection per fetch.
    ///
    /// A connection rather than a long-lived one, because this is asked for a few times an hour
    /// and holding a subprocess open between those is a process the user did not ask for.
    /// `cwd` is an empty folder Bloom owns rather than the home directory: listing models opens no
    /// file, and a CLI rooted at `~` is one that has been pointed at everything the user owns. See
    /// `AgentScratchDirectory`.
    public static func live(
        cwd: String = AgentScratchDirectory.current(),
        store: Store? = nil,
        makeClient: @escaping @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient = OpenCodeRunner.spawn
    ) -> OpenCodeModelCatalog {
        OpenCodeModelCatalog(fetch: {
            let stored = try await store?.setting(AgentCatalog.executablePathSettingKey(.openCode))
            let client = makeClient(OpenCodeClient.Configuration(
                executable: AgentCatalog.executable(for: .openCode, override: stored),
                cwd: cwd
            ))
            defer { Task { await client.stop() } }
            try await client.start()
            // v2 stopped naming models during `initialize`; the model list now arrives in the
            // `session/new` response's `configOptions`. One scratch session is opened and torn
            // down with the short-lived process, spending no turn.
            _ = try await client.newSession(cwd: cwd)
            return await client.advertisedModels()
        })
    }

    /// Everything, in the backend's capability order.
    public func models() async throws -> [OpenCodeModel] {
        try await cache.models()
    }

    /// What a picker shows: all models, preserving their capability order.
    public func pickerModels() async throws -> [OpenCodeModel] {
        try await models()
    }

    /// Drops the cache so a Refresh button does real work.
    public func invalidate() async {
        await cache.invalidate()
    }

    /// Whatever was last fetched, without fetching. For a picker that must draw now and would
    /// rather show a stale list than an empty one.
    public var lastKnown: [OpenCodeModel] { get async { await cache.lastKnown } }

    /// Most capable first. The rules are the same as Grok: context window descending,
    /// then alphabetical by id.
    static func sorted(_ models: [OpenCodeModel]) -> [OpenCodeModel] {
        models.sorted {
            if $0.contextTokens != $1.contextTokens {
                return $0.contextTokens > $1.contextTokens
            }
            return $0.id < $1.id
        }
    }
}
