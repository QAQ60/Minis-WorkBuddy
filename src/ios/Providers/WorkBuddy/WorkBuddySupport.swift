import Foundation

// MARK: - Site

/// WorkBuddy (the Tencent CodeBuddy plan) is served on two independent
/// endpoints with their own accounts and models:
///
/// • China build  — `https://copilot.tencent.com`, login platform "workbuddy".
/// • International — `https://www.workbuddy.ai`, login platform "workbuddy-ai".
///
/// The chat surface is OpenAI's Chat Completions under `<endpoint>/v2`, with
/// the account's access token and a set of client headers the official
/// desktop app sends. The wire details (mandatory streaming, conversation id
/// headers, system-first messages, string tool_choice) mirror the observed
/// behaviour of the official client and the kwwk reference implementation.
enum WorkBuddySite: String, Codable, CaseIterable, Sendable {
    case china
    case international

    /// Site root — login and config endpoints hang directly off this.
    var endpoint: String {
        switch self {
        case .china: return "https://copilot.tencent.com"
        case .international: return "https://www.workbuddy.ai"
        }
    }

    /// Chat Completions base: `<endpoint>/v2` (no `/v1` — never append one).
    var chatBaseURL: String { endpoint + "/v2" }

    /// The `platform` query parameter the sign-in state endpoint requires.
    var platform: String {
        switch self {
        case .china: return "workbuddy"
        case .international: return "workbuddy-ai"
        }
    }

    var displayName: String {
        switch self {
        case .china: return "WorkBuddy · CodeBuddy 中国区"
        case .international: return "WorkBuddy AI · 国际版"
        }
    }

    /// Resolve the site for an instance: the Keychain-persisted choice made at
    /// sign-in wins; a user-supplied custom base URL maps by host; otherwise
    /// the China build (the original plan endpoint).
    static func resolved(siteRaw: String?, customBaseURL: String?) -> WorkBuddySite {
        if let raw = siteRaw, let site = WorkBuddySite(rawValue: raw) { return site }
        if let base = customBaseURL?.lowercased() {
            if base.contains("workbuddy.ai") { return .international }
            if base.contains("copilot.tencent.com") { return .china }
        }
        return .china
    }

    // MARK: - Headers

    /// JSON body headers every WorkBuddy API call carries.
    static let jsonHeaders: [String: String] = [
        "Content-Type": "application/json",
        "Accept": "application/json",
    ]

    // MARK: - Client identity

    /// The versions the official WorkBuddy clients report. The gateway
    /// refuses a chat whose User-Agent is not a known client (error 10085),
    /// so these are load-bearing, not cosmetic — and they must stay in ONE
    /// place: the model catalog overrides the UA to `CLI/<app> WorkBuddy/<client>`
    /// (a bare `WorkBuddy/<client>` gets CodeBuddy IDE's config, which carries
    /// no `cli` agent), so a version bump used to need two coordinated edits.
    /// Mirrors kwwk's `WorkBuddyOAuth.appVersion` / `clientVersion`.
    static let appVersion = "2.0.0"
    static let clientVersion = "5.5.6"
    static let userAgent = "WorkBuddy/\(clientVersion)"
    /// The UA that makes `/v3/config` answer with WorkBuddy's own `cli`
    /// agent (rather than CodeBuddy IDE's config).
    static let cliUserAgent = "CLI/\(appVersion) \(userAgent)"

    /// Client headers the official WorkBuddy desktop app sends on every
    /// request. The gateway refuses a chat whose User-Agent is not a known
    /// client (error 10085), so these are load-bearing, not cosmetic.
    var clientHeaders: [String: String] {
        var headers: [String: String] = [
            "X-Product": "SaaS",
            "X-IDE-Type": "WorkBuddy",
            "User-Agent": WorkBuddySite.userAgent,
            "X-Requested-With": "XMLHttpRequest",
            "X-Agent-Intent": "craft",
            "X-Agent-Purpose": "conversation",
            "X-IDE-Name": "WorkBuddy",
            "X-IDE-Version": WorkBuddySite.clientVersion,
        ]
        // Observed only on the international build.
        if self == .international { headers["X-Agent-Type"] = "main" }
        return headers
    }

    /// Headers that say which signed-in account is speaking. Absent fields
    /// are sent as the "no value" markers the official client uses, matching
    /// its traffic shape.
    func accountHeaders(uid: String?, domain: String?, enterpriseId: String?) -> [String: String] {
        let resolvedDomain = (domain?.isEmpty == false ? domain : URL(string: endpoint)?.host) ?? ""
        var headers: [String: String] = [
            "X-Domain": resolvedDomain,
            "X-No-User-Id": "true",
            "X-No-Enterprise-Id": "true",
        ]
        if let uid, !uid.isEmpty {
            headers["X-User-Id"] = uid
            headers.removeValue(forKey: "X-No-User-Id")
        }
        if let enterpriseId, !enterpriseId.isEmpty {
            headers["X-Enterprise-Id"] = enterpriseId
            headers["X-Tenant-Id"] = enterpriseId
            headers.removeValue(forKey: "X-No-Enterprise-Id")
        }
        return headers
    }
}

// MARK: - Token storage

/// The WorkBuddy OAuth credential as persisted in the instance's Keychain.
/// `expireDate` is the access token's expiry; the refresh token carries its
/// own longer expiry (`refreshExpireDate`) tracked in milliseconds upstream.
struct WorkBuddyTokenStorage: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expireDate: Date?
    var refreshExpireDate: Date?
    /// Account identifiers the account endpoint returns — they feed the
    /// account headers (`X-User-Id`, `X-Domain`, `X-Enterprise-Id`).
    var uid: String?
    var domain: String?
    var enterpriseId: String?
    var accountName: String?
    /// Which endpoint these credentials belong to.
    var siteRaw: String?

    var site: WorkBuddySite { WorkBuddySite.resolved(siteRaw: siteRaw, customBaseURL: nil) }
}

// MARK: - Body mends

/// Request-body mends the WorkBuddy gateway requires on Chat Completions.
/// Applied via `OpenAIProvider.chatBodyDecorator` for WorkBuddy instances.
enum WorkBuddyBodyMend {
    /// The system message a chat that has none is sent with: the gateway
    /// refuses one whose first message isn't a system prompt
    /// ("first message is not system prompt").
    static let defaultSystemPrompt = "You are a helpful assistant."

    static func apply(to body: inout [String: Any]) {
        mendMessages(&body)
        mendToolChoice(&body)
        stripUnmodelledFields(&body)
    }

    /// OpenAI keys WorkBuddy's gateway does not model. The official client
    /// sends none of them, and the gateway's admission layer reads the body
    /// before the model does — an unknown key has been enough to turn a chat
    /// the same account serves from the official app into a bare refusal.
    /// `stream_options` is already removed by `requiresStreaming`; the list
    /// here is everything else Minis can attach that the reference client
    /// (kwwk) never sends.
    ///
    /// Deliberately NOT stripped: `reasoning` / `thinking` / `reasoning_effort`
    /// (reasoning models need them — the non-reasoning case is handled by the
    /// `stripsThinking` flag at the call site) and `response_format` (title
    /// generation asks for JSON with it).
    private static let unmodelledFields: [String] = [
        "store", "metadata", "service_tier", "prompt_cache_key",
        "parallel_tool_calls", "user", "logprobs", "top_logprobs",
        "logit_bias", "n", "seed", "prediction", "modalities", "audio",
    ]

    private static func stripUnmodelledFields(_ body: inout [String: Any]) {
        for field in unmodelledFields { body.removeValue(forKey: field) }
    }

    /// Ensure the first message is a system prompt.
    private static func mendMessages(_ body: inout [String: Any]) {
        guard var messages = body["messages"] as? [[String: Any]] else { return }
        if let first = messages.first, (first["role"] as? String) == "system" { return }
        messages.insert(["role": "system", "content": defaultSystemPrompt], at: 0)
        body["messages"] = messages
    }

    /// `tool_choice` only reaches the gateway as a string: `auto`,
    /// `required` or a tool name. Object shapes are reworded; `none` drops
    /// the tools entirely.
    private static func mendToolChoice(_ body: inout [String: Any]) {
        guard let choice = body["tool_choice"] else { return }
        if let word = choice as? String {
            if word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" {
                withoutTools(&body)
            }
            return
        }
        guard let object = choice as? [String: Any] else {
            body.removeValue(forKey: "tool_choice")
            return
        }
        switch (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none":
            withoutTools(&body)
        case "auto", "required":
            body["tool_choice"] = (object["type"] as! String).lowercased()
        case "function":
            let name = ((object["function"] as? [String: Any])?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            body["tool_choice"] = name.isEmpty ? "auto" : name
        default:
            body.removeValue(forKey: "tool_choice")
        }
    }

    private static func withoutTools(_ body: inout [String: Any]) {
        for field in ["tool_choice", "tools", "functions", "parallel_tool_calls"] {
            body.removeValue(forKey: field)
        }
    }
}

// MARK: - Refusals that a mended body answers

/// WorkBuddy's gateway refuses some chats for what they SAY, not for who is
/// asking: a system prompt it reads as another agent's, or a conversation that
/// breaks an ordering rule. Those refusals carry a business code, and the same
/// chat sent again a different way is served — so the client gets one retry on
/// a mended body rather than the user getting a 400.
///
/// This mirrors the reference client (kwwk's `WorkBuddyWire`), which is where
/// every code and wording below was measured against real accounts. Only the
/// cases that apply to a general-purpose agent are carried over: kwwk's list
/// also rewords DeepSeek Harness's and Claude Desktop's prompts, and neither
/// speaks for this app — `flagged` here names what this app's own prompts could
/// contain if a user's SKILL.md or a pasted transcript mentions them.
enum WorkBuddyRefusalMend {
    static let defaultSystemPrompt = WorkBuddyBodyMend.defaultSystemPrompt

    /// The tags a moved system prompt is read to the model in. They name no one
    /// — the point is that the words arrive as the user's, not as a system
    /// prompt the channel check reads.
    static let instructionTags = ("<instructions>\n", "\n</instructions>")

    /// The entry point wired to `OpenAIProvider.refusableBodyMender`.
    ///
    /// Returns true when `body` was changed and the attempt is worth repeating.
    static func mend(_ body: inout [String: Any], refusal: String) -> Bool {
        guard let said = parseRefusal(refusal) else { return false }

        // 11153 — the conversation must end with a user message. Tool results
        // followed by the user's message(s) trip it; an empty assistant reply
        // between them is served (kwwk, plugin 0.1.20).
        if said.code == "11153" {
            return replyAfterTools(&body)
        }

        // 11101 / 11128 — "Illegal API invocation from an unapproved channel".
        // The code alone is not enough: the gateway gives 11128 to
        // "first message is not system prompt" too, and no rewording mends that
        // — so the message is matched as well, exactly as kwwk does.
        if said.code == "11101" || said.code == "11128" {
            guard matchesRefusedChannel(said.message) else { return false }
            // Reword the known lines first: they may sit in an ASSISTANT
            // message, which `systemAsUser` cannot move.
            if unflagged(&body) { return true }
            // Then move the system prompt into the conversation.
            return systemAsUser(&body)
        }
        return false
    }

    // MARK: - Refusal parsing

    /// A refusal's code and words, wherever this gateway puts them: its own
    /// `{code, msg}`, nested under `data` or `error` on some endpoints, or
    /// OpenAI's `{"error": {"message"}}`. Nil for a body that is not JSON.
    static func parseRefusal(_ body: String) -> (code: String?, message: String?)? {
        guard let data = body.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let error = root["error"] as? [String: Any] ?? root
        let errorData = error["data"] as? [String: Any]
        let rootData = root["data"] as? [String: Any]

        let code = [errorData?["code"], error["code"], root["code"], rootData?["code"]]
            .lazy.compactMap(text).first
        let message = [error["message"], errorData?["msg"], root["error"], root["msg"], rootData?["msg"]]
            .lazy.compactMap { value -> String? in
                guard let words = value as? String, !words.isEmpty else { return nil }
                return words
            }.first
        return (code, message)
    }

    private static func text(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let words = value as? String, !words.isEmpty { return words }
        return nil
    }

    // MARK: - Known refusals

    /// The words both builds refuse as an unapproved channel, each with a
    /// rewording that says the same thing and passes. WorkBuddy reads every
    /// message, not only the system prompt, and ignores case.
    ///
    /// A line this list does not know yet is refused until it is added — the
    /// list is knowledge, not a rule, so it grows with what users hit.
    private static let flagged: [(NSRegularExpression, String)] = [
        // Claude Code's billing header means nothing here and goes entirely.
        (#"x-anthropic-billing-header:[^\n]*\n?"#, ""),
        (#"You are Claude Code, Anthropic['’]s official CLI for Claude"#,
         "You are Claude Code, Anthropic's CLI for Claude"),
        (#"Main branch \(you will usually use this for PRs\)"#,
         "Main branch (usually the base for PRs)"),
        (#"(?<!the )Codex CLI is an open source project led by OpenAI\."#,
         "The Codex CLI is an open source project led by OpenAI."),
    ].compactMap { rule in
        (try? NSRegularExpression(pattern: rule.0, options: .caseInsensitive)).map { ($0, rule.1) }
    }

    /// Whether a refusal's words are the channel complaint. Matched against the
    /// same lines the rewriter knows, because the gateway quotes the offending
    /// line back.
    private static func matchesRefusedChannel(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        let range = NSRange(message.startIndex..., in: message)
        return flagged.contains { $0.0.firstMatch(in: message, range: range) != nil }
    }

    // MARK: - Mends

    /// Replace the known lines in every message, wherever they sit.
    /// Returns whether anything changed.
    private static func unflagged(_ body: inout [String: Any]) -> Bool {
        guard var messages = body["messages"] as? [[String: Any]] else { return false }
        var changed = false
        for index in messages.indices {
            guard var content = messages[index]["content"] as? String else { continue }
            let before = content
            for (pattern, replacement) in flagged {
                content = pattern.stringByReplacingMatches(
                    in: content,
                    range: NSRange(content.startIndex..., in: content),
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                )
            }
            if content != before {
                messages[index]["content"] = content
                changed = true
            }
        }
        guard changed else { return false }
        body["messages"] = messages
        return true
    }

    /// A chat ending with the user's message(s) right after tool results, with
    /// an empty assistant message between them — as if the model had said
    /// nothing after the results. Nil-shaped (returns false) for any other chat,
    /// and for one ending on the assistant's message, which is a prefill the
    /// gateway refuses as it is.
    ///
    /// kwwk traced this on a real account (plugin 0.1.20, `aftertools.test.mjs`):
    /// the model follows the user's message as the user's, where folded into the
    /// tool's result it was read as the tool's output and the ask was left
    /// undone.
    static func replyAfterTools(_ body: inout [String: Any]) -> Bool {
        guard var messages = body["messages"] as? [[String: Any]] else { return false }
        var index = messages.count - 1
        while index >= 0, (messages[index]["role"] as? String) == "user" { index -= 1 }
        guard index != messages.count - 1, index >= 0,
              (messages[index]["role"] as? String) == "tool" else { return false }
        messages.insert(["role": "assistant", "content": ""], at: index + 1)
        body["messages"] = messages
        return true
    }

    /// Move the system prompt into the conversation as the user's opening
    /// words, keeping a plain default system message first (both builds want
    /// one there). A system message later in the chat becomes the user's where
    /// it stands.
    ///
    /// Returns false when there is nothing to move — the gateway's channel
    /// check reads system and assistant messages only, and every line it
    /// refused was previously served in a user message or a tool result.
    static func systemAsUser(_ body: inout [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        var lead: [String] = []
        var index = 0
        while index < messages.count, (messages[index]["role"] as? String) == "system" {
            lead.append(text(of: messages[index]["content"]))
            index += 1
        }
        let said = lead.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var laterSystem = false
        var rest = messages[index...].map { message -> [String: Any] in
            guard (message["role"] as? String) == "system" else { return message }
            laterSystem = true
            var copy = message
            copy["role"] = "user"
            return copy
        }
        let moved = !said.isEmpty && said != defaultSystemPrompt
        guard moved || laterSystem else { return false }

        if moved {
            let instructions = instructionTags.0 + said + instructionTags.1
            if let user = rest.firstIndex(where: { ($0["role"] as? String) == "user" }) {
                if let content = rest[user]["content"] as? String {
                    rest[user]["content"] = instructions + "\n\n" + content
                } else if let parts = rest[user]["content"] as? [Any] {
                    rest[user]["content"] = [["type": "text", "text": instructions] as [String: Any]] + parts
                } else {
                    rest[user]["content"] = instructions
                }
            } else {
                rest.insert(["role": "user", "content": instructions], at: 0)
            }
        }
        body["messages"] = [["role": "system", "content": defaultSystemPrompt]] + rest
        return true
    }

    /// The text of a message's content, string or parts alike.
    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}

// MARK: - Request pacing
/// Serialises WorkBuddy traffic per signed-in instance and holds a cooldown
/// after the gateway answers 429.
///
/// [T-workbuddy-pacer] Why this exists: WorkBuddy's front door (APISIX) answers
/// a paid model with a BODYLESS 429 that carries no `ratelimit-*` header — the
/// shape of a concurrency / request-rate cap, not a credit refusal. A spent
/// credit pool answers `14018` WITH a body ("Credits exhausted…"), and a
/// restricted account answers `403 11140`; neither is what Minis receives.
///
/// The same account, in the official client and in Apelin (kwwk), keeps
/// working, and Minis' own usage detail fills with one "用户请求数据处理" row
/// per upstream request. Minis sends more upstream requests per user send than
/// the reference client does: the chat itself, the session-title call right
/// after it, and an immediate re-send when the user taps 重试. Pacing them —
/// and honouring Retry-After instead of retrying into the same window — is what
/// keeps one account inside the budget the official client stays inside.
///
/// This is deliberately a client-side smoothing, not a fix for the gateway:
/// nothing here changes what the request says, only when it is sent.
actor WorkBuddyPacer {
    static let shared = WorkBuddyPacer()

    /// Minimum gap between two upstream requests of one instance. The title
    /// call that follows a chat is the case this exists for: it used to leave
    /// back-to-back with the chat's last chunk.
    static let minimumGap: TimeInterval = 1.0

    /// Cooldown used when a 429 names no Retry-After (WorkBuddy's bodyless 429
    /// never does).
    static let defaultCooldown: TimeInterval = 60

    /// A cooldown the gateway does name is honoured up to this ceiling, so a
    /// stray "reset at 23:59" cannot park the account for a day.
    static let maximumCooldown: TimeInterval = 30 * 60

    private var lastStart: [String: Date] = [:]
    private var cooldownUntil: [String: Date] = [:]

    /// Wait until this instance may send: past its cooldown, and at least
    /// `minimumGap` after the previous request started.
    /// Hold this request until `minimumGap` has passed since the previous one.
    ///
    /// Deliberately does NOT wait out a cooldown: a request that arrives during
    /// one should fail at once with a message naming the wait, not hang for a
    /// minute. The caller checks `cooldownRemaining` and throws.
    func wait(instanceId: String) async {
        // The token is read more than once on some request paths (headers and
        // body are assembled separately). Those repeats belong to the SAME
        // request, so they must not each pay the gap.
        let now = Date()
        if let last = lastStart[instanceId], now.timeIntervalSince(last) < 0.2 {
            return
        }
        if let last = lastStart[instanceId] {
            let delay = last.addingTimeInterval(Self.minimumGap).timeIntervalSince(now)
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(delay, 5) * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
        lastStart[instanceId] = Date()
    }

    /// The gateway refused with 429: hold this instance's next request until
    /// `retryAfter` seconds have passed (or the default cooldown). The longest
    /// outstanding hold wins, so concurrent refusals cannot shorten it.
    func rateLimited(instanceId: String, retryAfter: TimeInterval?) {
        let requested = retryAfter ?? Self.defaultCooldown
        let seconds = min(max(requested, 1), Self.maximumCooldown)
        let until = Date().addingTimeInterval(seconds)
        if let existing = cooldownUntil[instanceId], existing >= until { return }
        cooldownUntil[instanceId] = until
    }

    /// Seconds left before this instance may send again; 0 when it may send.
    func cooldownRemaining(instanceId: String) -> TimeInterval {
        guard let until = cooldownUntil[instanceId] else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }
}
