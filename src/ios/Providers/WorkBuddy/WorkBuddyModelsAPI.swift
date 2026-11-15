import Foundation

/// Model discovery for WorkBuddy instances.
///
/// WorkBuddy's catalog is NOT an OpenAI `/models` page: it lives in the site
/// configuration at `<endpoint>/v3/config`, whose `data.agents` array carries
/// the agent surfaces (the `cli` one lists what this client may pick) and
/// whose `data.models` array carries per-model details (display name, image
/// support, reasoning effort tiers).
enum WorkBuddyModelsAPI {
    struct Catalog {
        let models: [LLMModel]
        /// Non-fatal problem worth showing (e.g. the site listed nothing).
        let detail: String?
    }

    /// Fetch the live catalog for an authenticated instance.
    /// `accessToken` comes from `WorkBuddyOAuthManager.validAccessToken`.
    static func fetchModels(accessToken: String, site: WorkBuddySite) async throws -> Catalog {
        var request = URLRequest(url: URL(string: "\(site.endpoint)/v3/config")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        for (key, value) in site.clientHeaders { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in site.accountHeaders(uid: nil, domain: nil, enterpriseId: nil) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // The config that answers depends on this header: WorkBuddy sends
        // "CLI/<plugin> WorkBuddy/<client>", and a BARE "WorkBuddy/<client>"
        // gets CodeBuddy IDE's config, which carries no `cli` agent — so the
        // model list silently degraded to whatever `data.models` held, a
        // subset that drops models added to the plan (the DeepSeek V4.1
        // tier among them). Verified against kwwk's WorkBuddyModels.fetch,
        // which overrides the client headers for exactly this request.
        request.setValue("CLI/2.0.0 WorkBuddy/5.5.6", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (raw, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.providerError(message: "WorkBuddy: 模型清单获取失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              (json["code"] as? NSNumber)?.intValue == 0,
              let data = json["data"] as? [String: Any] else {
            throw LLMError.providerError(message: "WorkBuddy: 模型清单响应格式无法识别")
        }

        // Per-model details keyed by id.
        var details: [String: [String: Any]] = [:]
        if let models = data["models"] as? [[String: Any]] {
            for detail in models {
                if let id = detail["id"] as? String { details[id] = detail }
            }
        }

        // Collect the site's model ids. The config answers with the agent
        // surfaces under `data.agents` — but only when the request looks like
        // WorkBuddy's own CLI (see the User-Agent set above). Asked as a bare
        // WorkBuddy client, the same endpoint returns CodeBuddy IDE's config
        // (`data.agent.agents`, no "cli" agent), and the list degraded to
        // `data.models`, a subset that drops models the plan adds — the
        // DeepSeek V4.1 tier among them. Both nestings are read here so the
        // parser survives either answer.
        var ids: [String] = []

        func modelIDs(_ value: Any?) -> [String] {
            if let plain = value as? [String] { return plain }
            if let objects = value as? [[String: Any]] { return objects.compactMap { $0["id"] as? String } }
            return []
        }

        // Every agent surface the config may nest them under.
        var agentSurfaces: [[String: Any]] = []
        if let agents = data["agents"] as? [[String: Any]] { agentSurfaces += agents }
        if let agentBlock = data["agent"] as? [String: Any] {
            if let agents = agentBlock["agents"] as? [[String: Any]] { agentSurfaces += agents }
            if let surfaces = agentBlock["surfaces"] as? [[String: Any]] { agentSurfaces += surfaces }
        }

        // The "cli" agent's list is WorkBuddy's own picker and the authority
        // on what this plan may use, so when it is present nothing else is
        // mixed in. Only a config without one falls back to a union.
        let cliModels = agentSurfaces
            .first { ($0["name"] as? String) == "cli" }
            .map { modelIDs($0["models"]) } ?? []

        if !cliModels.isEmpty {
            ids = cliModels
        } else {
            for agent in agentSurfaces { ids.append(contentsOf: modelIDs(agent["models"])) }
            ids.append(contentsOf: modelIDs(data["availableModels"]))
            ids.append(contentsOf: modelIDs(data["modelList"]))
            ids.append(contentsOf: details.keys.sorted())
        }

        var models: [LLMModel] = []
        var seen = Set<String>()
        for id in ids where !id.isEmpty && seen.insert(id).inserted {
            let detail = details[id] ?? [:]
            let name = (detail["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let images = (detail["supportsImages"] as? NSNumber)?.boolValue ?? false
            let efforts = effortTiers(from: detail)
            models.append(LLMModel(
                id: id,
                displayName: name,
                provider: "WorkBuddy",
                modalityOverride: images ? .fullMultimodal : nil,
                reasoningEffortValues: efforts
            ))
        }
        guard !models.isEmpty else {
            return Catalog(models: [], detail: "WorkBuddy 站点未列出可用模型，可手动填写模型 ID")
        }
        return Catalog(models: models, detail: nil)
    }

    /// Effort tiers a model accepts: the model detail's `reasoning`
    /// dictionary carries `supportedEfforts` (or, on older builds, a plain
    /// `supportsReasoning` flag mapped onto the standard tier ladder).
    private static func effortTiers(from detail: [String: Any]) -> [String]? {
        let reasoning = detail["reasoning"] as? [String: Any]
        if let said = reasoning?["supportedEfforts"] as? [String] {
            let tiers = said.compactMap { $0.lowercased() }
            if !tiers.isEmpty { return tiers }
        }
        if (detail["supportsReasoning"] as? NSNumber)?.boolValue == true {
            return ["low", "medium", "high"]
        }
        return nil
    }
}
