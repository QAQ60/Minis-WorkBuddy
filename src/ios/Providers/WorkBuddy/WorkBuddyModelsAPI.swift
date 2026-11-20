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

    /// WorkBuddy models the official client treats as non-reasoning: it sends
    /// NO thinking/reasoning field for them, even where the live config claims
    /// `supportsReasoning: true` and lists effort tiers. Mirrors kwwk's bundled
    /// `workbuddy-models.json` / `workbuddy-ai-models.json` rows with
    /// `"reasoning": false`. New models default to the config's claim (nil →
    /// resolver treats as reasoning), same as kwwk's "usable fallback" row.
    static let nonReasoningModelIDs: Set<String> = [
        // China plan (workbuddy-models.json)
        "auto", "deepseek-v4.1-flash", "glm-5.1", "glm-5v-turbo",
        "minimax-m3", "kimi-k2.7", "kimi-k2.6",
        // International plan (workbuddy-ai-models.json)
        "default-model", "fast-model", "balanced-model", "primary-model",
        "deep-model", "gpt-5.5", "gpt-5.4", "gpt-5.3-codex",
        "gemini-3.1-pro", "gemini-3.5-flash", "kimi-k3",
    ]

    /// [T-workbuddy-flash-id-alias] Whether WorkBuddy treats this model as
    /// non-reasoning — the question the exact set above can no longer answer
    /// on its own.
    ///
    /// The plan renamed DeepSeek's cheapest paid model from
    /// `deepseek-v4.1-flash` to the bare `deepseek-flash` (kwwk's
    /// T-deepseek-flash-scope records the same rename: "DeepSeek now
    /// recommends the bare `deepseek-flash`; `deepseek-v4-flash` is kept only
    /// as a legacy alias"). A config answering the new id matched NOTHING in
    /// the set, so `supportsReasoning` stayed nil, the thinking resolver read
    /// nil as "allowed", injected `thinking:{"type":"disabled"}`, and the
    /// gateway answered the paid request with its bodyless 429 — the exact
    /// failure the set was added to prevent, reached through a different id.
    ///
    /// The prefix therefore carries the family: every `deepseek-flash*` is the
    /// same non-reasoning model under whichever name the plan is using today.
    static func isNonReasoning(_ id: String) -> Bool {
        let lid = id.lowercased()
        if nonReasoningModelIDs.contains(lid) { return true }
        if lid.hasPrefix("deepseek-flash") { return true }
        // The legacy id plus any tier suffix the plan appends to it
        // (`deepseek-v4.1-flash-high` and friends) is the same model.
        if lid.hasPrefix("deepseek-v4.1-flash") { return true }
        return false
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
        // "CLI/<app> WorkBuddy/<client>", and a BARE "WorkBuddy/<client>"
        // gets CodeBuddy IDE's config, which carries no `cli` agent — so the
        // model list silently degraded to whatever `data.models` held, a
        // subset that drops models added to the plan (the DeepSeek V4.1
        // tier among them). Verified against kwwk's WorkBuddyModels.fetch,
        // which overrides the client headers for exactly this request.
        request.setValue(WorkBuddySite.cliUserAgent, forHTTPHeaderField: "User-Agent")
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

        // Two passes: a name with the plan's credit multiple appended, then
        // the de-duplication that needs every name before any model is built
        // (`LLMModel.displayName` is a `let`).
        var entries: [(id: String, name: String)] = []
        var detailsByID: [String: [String: Any]] = [:]
        var seen = Set<String>()
        for id in ids where !id.isEmpty && seen.insert(id).inserted {
            let detail = details[id] ?? [:]
            let base = (detail["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            detailsByID[id] = detail
            entries.append((id, displayedName(base, rate: creditRate(detail["credits"]))))
        }
        let names = distinctNames(entries)

        var models: [LLMModel] = []
        for (index, entry) in entries.enumerated() {
            let detail = detailsByID[entry.id] ?? [:]
            // The config marks every model `supportsImages`, but the
            // international build strips an image sent to its GLM models
            // server-side and tells the model it was filtered. Listing them
            // as vision would let the user attach a picture that is silently
            // discarded — say text-only instead, so the UI can leave it out.
            //
            // `.vision`, not `.fullMultimodal`: the config's one boolean says
            // nothing about audio, video or PDF, and the wider set put an
            // `audio`/`video` badge on every row. `.textOnly` rather than nil
            // for the rest, because nil falls back to the PROVIDER default
            // (`.vision`) — the same wrong claim by a different route.
            let declaresImages = (detail["supportsImages"] as? NSNumber)?.boolValue ?? false
            let images = declaresImages && !textOnly(site: site, id: entry.id)
            // [T-workbuddy-non-reasoning-models] WorkBuddy's live config marks
            // several models `supportsReasoning: true` (and offers effort tiers)
            // even though the official client treats them as NON-reasoning and
            // sends NO thinking/reasoning field at all — kwwk's bundled catalog
            // (the engine Apelin uses) has `reasoning: false` for them. Minis
            // trusted the config, left `supportsReasoning` nil, and the thinking
            // resolver defaults nil→true — so it injected `thinking:{...}` into
            // exactly these models. WorkBuddy's gateway answers those paid
            // requests with a bodyless 429; the same model without the field
            // (as the official app sends it) works. Set the capability from the
            // SAME list kwwk uses so the resolver skips injection for them.
            let nonReasoning = Self.isNonReasoning(entry.id)
            var model = LLMModel(
                id: entry.id,
                displayName: names[index],
                provider: "WorkBuddy",
                modalityOverride: modality(images: images),
                contextWindow: positiveInt(detail["maxInputTokens"]),
                maxOutputTokens: positiveInt(detail["maxOutputTokens"]),
                supportsReasoning: nonReasoning ? false : nil,
                reasoningEffortValues: nonReasoning ? nil : effortTiers(from: detail)
            )
            // The config is this endpoint's own statement about this account,
            // which is what `limitsReportedByEndpoint` exists to mark: the
            // catalog may only fill the limits it left out, never overwrite
            // them. Without it models.dev put 1M back on a plan that throttles
            // far below that.
            model.limitsReportedByEndpoint = model.contextWindow != nil || model.maxOutputTokens != nil
            // Same authority for the modality: one boolean from the plan, and
            // models.dev must not broaden it to audio/video/pdf.
            model.modalityReportedByEndpoint = true
            models.append(model)
        }
        guard !models.isEmpty else {
            return Catalog(models: [], detail: "WorkBuddy 站点未列出可用模型，可手动填写模型 ID")
        }
        return Catalog(models: models, detail: nil)
    }

    // MARK: - Field parsing

    /// A model's credits, the multiple WorkBuddy's own picker shows by it:
    /// "x0.03", "0" or 0. A rate that cannot be read is none.
    ///
    /// `x0.00` is the one worth reading aloud — the plan is not charging for
    /// that model at all, which is why a chat can finish without the balance
    /// moving.
    static func creditRate(_ raw: Any?) -> Double? {
        let text: String
        switch raw {
        case let string as String: text = string
        case let number as NSNumber: text = number.stringValue
        default: return nil
        }
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if digits.hasPrefix("x") { digits = digits.dropFirst() }
        guard let rate = Double(digits), rate.isFinite, rate >= 0 else { return nil }
        return rate
    }

    /// The modality a config detail describes.
    ///
    /// `supportsImages` is one boolean. Mapping it to `.fullMultimodal` (the
    /// first cut) claimed audio, video and PDF support the plan never
    /// mentioned, and every row in the picker wore those badges. `.vision` is
    /// the most it may mean; `.textOnly` — never nil — is the little it may
    /// mean, because nil falls through to the provider default (`.vision`).
    static func modality(images: Bool) -> ModelModality {
        images ? .vision : .textOnly
    }

    /// Whether a parsed model carries the "this endpoint described me" stamps,
    /// which stop models.dev from overwriting what the plan itself said.
    static func stampsModalityAuthority(_ model: LLMModel) -> Bool {
        model.modalityReportedByEndpoint == true
    }

    static func stampsLimitAuthority(_ model: LLMModel) -> Bool {
        model.limitsReportedByEndpoint == true
    }

    /// A count the config gave, when it gave a usable one.
    private static func positiveInt(_ raw: Any?) -> Int? {
        guard let value = (raw as? NSNumber)?.intValue, value > 0 else { return nil }
        return value
    }

    /// `name` with the plan's credit multiple appended, as WorkBuddy's own
    /// model menu shows it. A free model says so outright.
    ///
    /// Kept in the display name rather than a field of its own because the
    /// rate belongs to a catalog row, not to a request, and the name is what
    /// the picker, the quota card and the agent all read. The user's own
    /// rename still wins (it is an override, not this string).
    static func displayedName(_ name: String, rate: Double?) -> String {
        guard let rate else { return name }
        // Two decimals keep x0.03 and x0.00 apart; x1 stays "x1".
        var text = String(format: "%.2f", rate)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(name) · x\(text)"
    }

    /// The names to show, with each repeated one distinguished by what its id
    /// adds to the first holder's ("… (SG)"), or else by its id.
    static func distinctNames(_ entries: [(id: String, name: String)]) -> [String] {
        var first: [String: String] = [:]
        return entries.map { entry in
            guard let kept = first[entry.name] else {
                first[entry.name] = entry.id
                return entry.name
            }
            var tag = entry.id
            if entry.id.hasPrefix(kept + "-"), entry.id.count > kept.count + 1 {
                tag = String(entry.id.dropFirst(kept.count + 1)).uppercased()
            }
            return "\(entry.name) (\(tag))"
        }
    }

    /// Whether `site` drops the images sent to a model whatever its config
    /// says. The international build marks every model `supportsImages`, but
    /// an image sent to its GLM models is taken out by the server and the
    /// model is told the content was filtered (verified by kwwk against a
    /// real account, 2026-10-13). Its other models read images, and so does
    /// the China build's GLM.
    static func textOnly(site: WorkBuddySite, id: String) -> Bool {
        site == .international && id.hasPrefix("glm-")
    }

    /// Effort tiers a model accepts.
    ///
    /// Most configs list them in `reasoning.supportedEfforts`. Some — the fast
    /// models, deepseek-v4.1-flash, kimi-k3, gemini-3.5-flash — say only
    /// `supportsReasoning` plus a default `reasoning.effort`; those take low,
    /// high and max, and their own declared default is added to that ladder
    /// when it is one of the wider tiers. "none" (thinking off) is offered
    /// only where the plan allows it: a model marked `onlyReasoning` cannot
    /// turn thinking off at all, and one whose reasoning block says
    /// `canDisableThinking: false` refuses it too.
    static func effortTiers(from detail: [String: Any]) -> [String]? {
        let reasoning = detail["reasoning"] as? [String: Any]
        var tiers: [String]
        // An EMPTY declared list is not an answer — several configs ship
        // `supportedEfforts: []` beside `supportsReasoning: true`, and the
        // flag is the only thing that says anything there.
        if let said = reasoning?["supportedEfforts"] as? [String], !said.isEmpty {
            tiers = said.map { $0.lowercased() }.filter { !$0.isEmpty }
        } else if (detail["supportsReasoning"] as? NSNumber)?.boolValue == true {
            let ladder = ["low", "medium", "high", "xhigh", "max"]
            var taken: Set<String> = ["low", "high", "max"]
            if let own = reasoning?["effort"] as? String, ladder.contains(own.lowercased()) {
                taken.insert(own.lowercased())
            }
            tiers = ladder.filter { taken.contains($0) }
        } else {
            return nil
        }
        guard !tiers.isEmpty else { return nil }
        let onlyReasoning = (detail["onlyReasoning"] as? NSNumber)?.boolValue == true
        let canDisable = (reasoning?["canDisableThinking"] as? NSNumber)?.boolValue ?? true
        if !onlyReasoning, canDisable, !tiers.contains("none") {
            tiers.insert("none", at: 0)
        }
        return tiers
    }
}
