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

        // Collect the site's model ids from everywhere it may list them. The
        // live config nests the agent surfaces under `data.agent.agents`
        // (verified against copilot.tencent.com/v3/config), not `data.agents`
        // as an earlier build assumed — reading only the wrong key left the
        // catalog with whatever `data.models` happened to carry, which is a
        // subset and drops models such as the DeepSeek V4.1 tier.
        //
        // Order matters: the agent lists are curated (they lead the picker),
        // the per-model details fill in anything they omit.
        var ids: [String] = []

        func modelIDs(_ value: Any?) -> [String] {
            if let plain = value as? [String] { return plain }
            if let objects = value as? [[String: Any]] { return objects.compactMap { $0["id"] as? String } }
            return []
        }

        // Current shape: data.agent.agents[].models
        if let agentBlock = data["agent"] as? [String: Any] {
            for surfaces in [agentBlock["agents"], agentBlock["surfaces"]] {
                if let agents = surfaces as? [[String: Any]] {
                    for agent in agents { ids.append(contentsOf: modelIDs(agent["models"])) }
                }
            }
        }
        // Older shape: data.agents[].models
        if let agents = data["agents"] as? [[String: Any]] {
            for agent in agents { ids.append(contentsOf: modelIDs(agent["models"])) }
        }
        // Anything else the site declares as available.
        ids.append(contentsOf: modelIDs(data["availableModels"]))
        ids.append(contentsOf: modelIDs(data["modelList"]))
        // Finally every model that carries a detail record.
        ids.append(contentsOf: details.keys.sorted())

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
