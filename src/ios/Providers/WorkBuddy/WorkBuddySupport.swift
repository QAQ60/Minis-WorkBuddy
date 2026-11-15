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
