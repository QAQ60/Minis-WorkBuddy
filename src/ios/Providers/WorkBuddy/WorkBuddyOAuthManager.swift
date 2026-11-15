import Foundation

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
        present(LoginPagePresentation(authURL: authURL, site: site))

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
    /// Completions request carries a fresh set.
    func conversationHeaders(instanceId: String, site: WorkBuddySite) -> [String: String] {
        func hex32() -> String {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        let request = hex32()
        var headers = [
            "X-Conversation-Message-ID": request,
            "X-Request-ID": request,
            "X-Conversation-Request-ID": hex32(),
            "X-Conversation-ID": hex32(),
        ]
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
