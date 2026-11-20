import Foundation
import CryptoKit

/// Stable WorkBuddy conversation identifiers, mirroring kwwk's
/// `WorkBuddyWire.conversationHeaders` (the engine Apelin uses, and which does
/// NOT trip WorkBuddy's rate limit the way Minis did).
///
/// [T-workbuddy-stable-conversation-id] Minis used to send a BRAND-NEW random
/// `X-Conversation-ID` on every request. WorkBuddy then treats every request
/// as a different conversation: the usage detail fills with one
/// "用户请求数据处理" row per request, and the account-level rate limit is
/// hit almost immediately. kwwk's own comment says it exactly — a made-up id
/// "is what splits one conversation into many in the usage detail".
///
/// The fix is to derive the ids from the chat itself:
///   - conversation id  ← the FIRST user message (same for the whole chat),
///   - turn id          ← the LAST user message (same across retries of one
///                        turn, different for the next turn).
/// A per-process random salt keeps the ids opaque and stops one user's ids
/// from revealing their message text to another. Hashing is 16 bytes → 32 hex
/// digits, the shape WorkBuddy's own ids use.
enum WorkBuddyConversationID {
    /// 32 lowercase hex digits from SHA256(salt | kind | key), or nil when
    /// `key` is empty (so we never send a stable id for an empty chat).
    private static let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private static func hex32(kind: String, key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(salt)|\(kind)|\(key)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Flatten a `content` value (String or the multimodal [[String:Any]] array)
    /// into the text WorkBuddy would sign. Only user text matters for identity;
    /// images would need a digest of their own, which Minis does not pass here.
    private static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }.joined()
        }
        return ""
    }

    /// The first user message's text — stable for every turn of the chat.
    private static func firstUserKey(_ messages: [[String: Any]]) -> String? {
        for m in messages where (m["role"] as? String) == "user" {
            let t = text(of: m["content"])
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// The last user message's text — stable across retries of one turn.
    private static func lastUserKey(_ messages: [[String: Any]]) -> String? {
        for m in messages.reversed() where (m["role"] as? String) == "user" {
            let t = text(of: m["content"])
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Build the four ids for a chat request. `request` ids stay random per
    /// call (they name a single HTTP request); conversation/turn ids are
    /// derived from the chat so WorkBuddy sees one conversation.
    ///
    /// [T-workbuddy-session-conversation-id] kwwk (the Apelin engine) keys the
    /// conversation on the REAL session id first (`session:<id>`), and only
    /// falls back to the first user message when there is no session. Its own
    /// comment warns that a made-up id "is what splits one conversation into
    /// many in the usage detail". A real session id — the one WorkBuddy's own
    /// client would send — is what a server-side conversation check expects;
    /// a hash of the first message is not a conversation WorkBuddy knows. Pass
    /// the session id whenever the chat has one.
    static func headers(forBody body: [String: Any], sessionId: String? = nil) -> [String: String] {
        let request = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var headers = [
            "X-Conversation-Message-ID": request,
            "X-Request-ID": request,
        ]
        let messages = body["messages"] as? [[String: Any]] ?? []

        // The conversation key: the real session id when present, else the
        // first user message (kwwk's exact precedence).
        let conversation: String?
        if let sid = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sid.isEmpty, !sid.hasPrefix("__new__") {
            conversation = "session:\(String(sid.prefix(128)))"
        } else if let first = firstUserKey(messages) {
            conversation = "first:\(first)"
        } else {
            conversation = nil
        }

        if let conversation, let cid = hex32(kind: "conversation", key: conversation) {
            headers["X-Conversation-ID"] = cid
        }
        // [T-workbuddy-no-madeup-conversation] Nothing names the conversation
        // (no session yet, and no user text to derive one from) ⇒ send NO
        // conversation id at all, exactly as kwwk does. A made-up one is "a
        // conversation of the request's own", which is what splits one chat
        // into many "用户请求数据处理" rows and spends the account's request
        // budget N times over.
        if let last = lastUserKey(messages),
           let tid = hex32(kind: "turn", key: "\(conversation ?? "")|\(last)") {
            headers["X-Conversation-Request-ID"] = tid
        } else {
            headers["X-Conversation-Request-ID"] = request
        }
        return headers
    }
}

/// WorkBuddy (CodeBuddy plan) OAuth: official sign-in with an external
/// authorization page, then credential polling — NOT an RFC 8628 device flow,
/// even though the UX shape (open a page, poll until the user approves) looks
/// like one.
///
/// Flow (mirrors the official client and the kwwk reference implementation):
///   1. POST `/v2/plugin/auth/state?platform=<site.platform>` → `{state, authUrl}`.
///   2. The user opens `authUrl` in any browser and signs in (QR / password).
///   3. Poll GET `/v2/plugin/auth/token?state=…` every second — the gateway
///      answers a pending business code (11217) until the user approves.
///   4. Poll GET `/v2/plugin/login/account?state=…` (pending code 12151) for
///      the account identifiers the chat headers carry.
///   5. Renewal: POST `/v2/plugin/auth/token/refresh` with `X-Refresh-Token`.
///
/// Structure mirrors `KimiOAuthManager` (per-instance Keychain via
/// `ProviderKeychainHelper`, single-flight refresh with a 5-minute buffer).
@MainActor
final class WorkBuddyOAuthManager: ObservableObject {
    static let shared = WorkBuddyOAuthManager()
    private init() {}

    private let logger = AppLogger(category: "WorkBuddyOAuth")
    private let refreshBuffer: TimeInterval = 5 * 60
    /// The login window: the state stays valid for a few minutes upstream.
    private let loginTimeout: TimeInterval = 5 * 60

    /// Business codes the poll endpoints answer while the login is not done.
    private let tokenPendingCode = 11217
    private let accountPendingCode = 12151

    private var inFlightRefresh: [String: Task<WorkBuddyTokenStorage, Error>] = [:]

    // MARK: - Site selection

    /// The site an instance talks to. Persisted at sign-in under
    /// "workbuddy-site"; falls back to the custom base URL's host, then China.
    func site(instanceId: String, customBaseURL: String? = nil) -> WorkBuddySite {
        let raw = ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: "workbuddy-site")
        return WorkBuddySite.resolved(siteRaw: raw, customBaseURL: customBaseURL)
    }

    // MARK: - Status accessors (never log token material)

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self)?.accessToken != nil
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self)?.accessToken,
              token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func logout(instanceId: String) {
        inFlightRefresh[instanceId]?.cancel()
        inFlightRefresh[instanceId] = nil
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
        ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: "workbuddy-site")
    }

    // MARK: - Login

    /// What the sign-in sheet shows while the user authorizes in a browser.
    struct LoginPagePresentation {
        let authURL: URL
        let site: WorkBuddySite
    }

    /// Start the login: request a state, hand the authorization URL to the
    /// caller (UI), then poll until success/failure. On success the
    /// credentials are persisted to the Keychain for `instanceId`.
    func login(
        instanceId: String,
        site: WorkBuddySite,
        present: @escaping (LoginPagePresentation) -> Void
    ) async throws {
        logger.info("WorkBuddy login START (instance: \(instanceId), site: \(site.rawValue))")
        ProviderKeychainHelper.saveOAuthString(site.rawValue, instanceId: instanceId, account: "workbuddy-site")

        // 1. Request the login state.
        let started = try await call(
            url: URL(string: "\(site.endpoint)/v2/plugin/auth/state?platform=\(site.platform)")!,
            method: "POST",
            headers: WorkBuddySite.jsonHeaders,
            body: [:]
        )
        guard let data = started.data,
              let state = data["state"] as? String, !state.isEmpty,
              let authURLString = data["authUrl"] as? String,
              let authURL = URL(string: authURLString) else {
            throw LLMError.providerError(message: "WorkBuddy: 登录页申请失败（\(started.errorDescription ?? "未知错误")）")
        }
        // [T-workbuddy-login-version] Tell the page which client is signing in,
        // and give it a session of its own — byte-for-byte what kwwk does.
        //
        // The page decides what kind of token to issue from these two. Without
        // `version` it signs in the WEB build, and that token is billed against
        // the CodeBuddy plan's monthly pool (500 credits) rather than
        // WorkBuddy's own. Once those 500 are spent the gateway answers
        // `code 14018 "额度已用尽…购买加量包"` on every chat, even though the
        // account still shows a large bonus-credit balance — the exact split
        // in codebuddy.cn's 套餐与用量 page (基础积分 500/500 已用，平台奖励积分
        // 仍有余额). Apelin, which sends `version`, keeps working on the bonus
        // pool, and so does a relay key: neither lands in the plan's pool.
        //
        // The rest of the query is left as WorkBuddy encoded it: read decoded
        // and written back, a `%2B` in `state` would go out as `+`, which the
        // page reads as a space.
        var pageURL = authURL
        if var page = URLComponents(url: authURL, resolvingAgainstBaseURL: false) {
            let ours = [
                URLQueryItem(name: "version", value: WorkBuddySite.appVersion),
                URLQueryItem(
                    name: "loginSessionId",
                    value: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                ),
            ]
            page.percentEncodedQueryItems = (page.percentEncodedQueryItems ?? [])
                .filter { item in !ours.contains { $0.name == item.name } } + ours
            pageURL = page.url ?? authURL
        }
        present(LoginPagePresentation(authURL: pageURL, site: site))

        // 2. Poll the token until the user approves in the browser.
        let deadline = Date().addingTimeInterval(loginTimeout)
        let tokenData = try await poll(
            site: site,
            path: "/v2/plugin/auth/token?state=\(Self.formValue(state))",
            headers: [:],
            pendingCode: tokenPendingCode,
            deadline: deadline
        )
        guard let access = tokenData["accessToken"] as? String, !access.isEmpty else {
            throw LLMError.providerError(message: "WorkBuddy: 登录响应缺少 accessToken")
        }

        // 3. Poll the account identifiers (uid / domain / enterpriseId).
        var storage = WorkBuddyTokenStorage(
            accessToken: access,
            refreshToken: tokenData["refreshToken"] as? String,
            expireDate: Self.expiry(from: tokenData),
            refreshExpireDate: nil,
            uid: nil, domain: nil, enterpriseId: nil, accountName: nil,
            siteRaw: site.rawValue
        )
        if let refreshExpire = Self.refreshExpiry(from: tokenData) { storage.refreshExpireDate = refreshExpire }
        if let account = try? await poll(
            site: site,
            path: "/v2/plugin/login/account?state=\(Self.formValue(state))",
            headers: site.accountHeaders(uid: nil, domain: nil, enterpriseId: nil)
                .merging(["Authorization": "Bearer \(access)"]) { _, new in new },
            pendingCode: accountPendingCode,
            deadline: deadline
        ) {
            storage.uid = account["uid"] as? String
            storage.domain = account["domain"] as? String
            storage.enterpriseId = account["enterpriseId"] as? String
            storage.accountName = (account["accountName"] as? String) ?? (account["username"] as? String)
        }

        ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
        logger.info("WorkBuddy login complete (instance: \(instanceId), site: \(site.rawValue))")
    }

    // MARK: - On-demand access token (with single-flight refresh)

    func validAccessToken(instanceId: String) async throws -> String {
        guard let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self) else {
            throw LLMError.invalidAPIKey(detail: "WorkBuddy: no OAuth token found for instance \(instanceId)")
        }
        let needsRefresh = storage.refreshToken != nil
            && (storage.expireDate.map { $0.timeIntervalSinceNow <= refreshBuffer } ?? false)
        guard needsRefresh else {
            guard !storage.accessToken.isEmpty else {
                throw LLMError.invalidAPIKey(detail: "WorkBuddy: access token is empty for instance \(instanceId)")
            }
            return storage.accessToken
        }
        return try await refreshSingleFlight(instanceId: instanceId, current: storage).accessToken
    }

    /// Dedup concurrent refreshes for the same instance to a single Task.
    private func refreshSingleFlight(instanceId: String, current: WorkBuddyTokenStorage) async throws -> WorkBuddyTokenStorage {
        if let existing = inFlightRefresh[instanceId] {
            return try await existing.value
        }
        let task = Task<WorkBuddyTokenStorage, Error> { [weak self] in
            guard let self else { throw LLMError.cancelled }
            return try await self.performRefresh(instanceId: instanceId, current: current)
        }
        inFlightRefresh[instanceId] = task
        defer { inFlightRefresh[instanceId] = nil }
        return try await task.value
    }

    private func performRefresh(instanceId: String, current: WorkBuddyTokenStorage) async throws -> WorkBuddyTokenStorage {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw LLMError.invalidAPIKey(detail: "WorkBuddy: 授权已过期且无续期凭据，请重新登录")
        }
        let site = current.site
        let refreshed = try await call(
            url: URL(string: "\(site.endpoint)/v2/plugin/auth/token/refresh")!,
            method: "POST",
            headers: site.clientHeaders.merging([
                "X-Refresh-Token": refreshToken,
                // [T-workbuddy-refresh-source] kwwk sends this on every renewal;
                // Minis did not. The source decides which client the renewed
                // token is issued to, and with it which credit pool the token's
                // chats are billed against — the plugin's own, or the CodeBuddy
                // plan's monthly 500 (which answers 14018 once spent). A token
                // first issued without it keeps that fault across renewals, so
                // fixing this only helps an account that signs in again.
                "X-Auth-Refresh-Source": "plugin",
                "Content-Type": "application/json",
            ]) { _, new in new },
            body: [:]
        )
        guard let data = refreshed.data,
              let access = data["accessToken"] as? String, !access.isEmpty else {
            throw LLMError.providerError(message: "WorkBuddy: 续期失败（\(refreshed.errorDescription ?? "未知错误")），请重新登录")
        }
        var next = current
        next.accessToken = access
        if let rotated = data["refreshToken"] as? String, !rotated.isEmpty { next.refreshToken = rotated }
        if let expiry = Self.expiry(from: data) { next.expireDate = expiry }
        if let refreshExpiry = Self.refreshExpiry(from: data) { next.refreshExpireDate = refreshExpiry }
        ProviderKeychainHelper.saveOAuthToken(next, instanceId: instanceId)
        return next
    }

    // MARK: - Wire helpers

    /// One WorkBuddy JSON call. Returns the unwrapped `data` object, or an
    /// error carrying the gateway's business code + message.
    private func call(
        url: URL,
        method: String,
        headers: [String: String],
        body: [String: Any]?
    ) async throws -> (data: [String: Any]?, errorDescription: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if method == "POST" {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body ?? [:])
        }
        let (raw, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        let code = (json["code"] as? NSNumber)?.intValue ?? ((json["code"] as? String).flatMap(Int.init) ?? 0)
        let message = (json["msg"] as? String) ?? (json["message"] as? String) ?? ""
        if status == 401 || status == 403 {
            return (nil, "HTTP \(status)，认证被拒")
        }
        if code != 0 {
            return (nil, "错误码 \(code)\(message.isEmpty ? "" : "：\(message)")")
        }
        return (json["data"] as? [String: Any], nil)
    }

    /// Poll a GET endpoint once a second until it returns data. Pending
    /// business codes and transient HTTP states keep polling; the login
    /// window bounds the wait.
    private func poll(
        site: WorkBuddySite,
        path: String,
        headers: [String: String],
        pendingCode: Int,
        deadline: Date
    ) async throws -> [String: Any] {
        while true {
            if Date() >= deadline {
                throw LLMError.providerError(message: "WorkBuddy: 登录等待超时，请重试")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            // Transient network failures are tolerated until the deadline —
            // the login window bounds them, and the state outlives a blip.
            guard let result = try? await call(
                url: URL(string: site.endpoint + path)!,
                method: "GET",
                headers: headers.merging(WorkBuddySite.jsonHeaders) { _, new in new },
                body: nil
            ) else { continue }
            if let data = result.data, !data.isEmpty { return data }
            let description = result.errorDescription ?? ""
            if description.contains("错误码 \(pendingCode)")
                || description.contains("HTTP 408") || description.contains("HTTP 429") {
                continue
            }
            if description.hasPrefix("错误码") {
                // Any other business code is a hard refusal — surface it.
                throw LLMError.providerError(message: "WorkBuddy: \(description)")
            }
        }
    }

    // MARK: - Conversation headers

    /// The four ids WorkBuddy's client names a chat by. The international
    /// gateway refuses chats without them (HTTP 400), so every Chat
    /// Completions request carries a full set.
    ///
    /// [T-workbuddy-stable-conversation-id] `body` is the outgoing request;
    /// the conversation/turn ids are derived from its messages so the whole
    /// chat is ONE conversation to WorkBuddy (see WorkBuddyConversationID).
    func conversationHeaders(instanceId: String, site: WorkBuddySite,
                             body: [String: Any], sessionId: String? = nil) -> [String: String] {
        Self.makeConversationHeaders(instanceId: instanceId, site: site, body: body, sessionId: sessionId)
    }

    /// Nonisolated core so per-request header callbacks (invoked on arbitrary
    /// executors inside the networking layer) can build the header set
    /// without hopping to the main actor.
    nonisolated static func makeConversationHeaders(instanceId: String, site: WorkBuddySite,
                                                     body: [String: Any] = [:],
                                                     sessionId: String? = nil) -> [String: String] {
        // [T-workbuddy-stable-conversation-id] Swap the all-random ids for ids
        // derived from the chat. Message/request ids stay per-call random;
        // conversation/turn ids are stable, which is what stops WorkBuddy from
        // splitting one chat into many "用户请求数据处理" rows and rate-limiting
        // us after a handful of requests (as the Apelin/kwwk client does not).
        var headers = WorkBuddyConversationID.headers(forBody: body, sessionId: sessionId)
        if let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self) {
            for (key, value) in site.accountHeaders(
                uid: storage.uid, domain: storage.domain, enterpriseId: storage.enterpriseId
            ) { headers[key] = value }
        }
        return headers
    }

    // MARK: - Parsing helpers

    /// Upstream expiry arrives as epoch milliseconds (`expiresAt`) or seconds
    /// (`expiresIn`); normalize to a Date, defaulting to one hour.
    private static func expiry(from data: [String: Any]) -> Date? {
        if let ms = (data["expiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        if let seconds = (data["expiresIn"] as? NSNumber)?.doubleValue, seconds > 0 {
            return Date().addingTimeInterval(seconds)
        }
        return Date().addingTimeInterval(60 * 60)
    }

    private static func refreshExpiry(from data: [String: Any]) -> Date? {
        if let ms = (data["refreshExpiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        if let seconds = (data["refreshExpiresIn"] as? NSNumber)?.doubleValue, seconds > 0 {
            return Date().addingTimeInterval(seconds)
        }
        return nil
    }

    /// Percent-encode one query value (unreserved characters only).
    private static func formValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
