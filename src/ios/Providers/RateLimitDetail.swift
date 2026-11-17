import Foundation

/// Turns a gateway's HTTP 429 body into words a person can act on.
///
/// Why this exists: `mapHTTPError` used to answer every 429 with a bare
/// `.rateLimited`, discarding the body. But 429 covers at least three
/// different conditions — a spent credit pool, a concurrency cap, a
/// per-minute request cap — and only the body distinguishes them. A user
/// told "Rate limited — please try again later" cannot tell whether to wait
/// thirty seconds or top up their plan.
///
/// The shapes handled here, in order:
///
///   1. `{"error":{"message":…,"code":…}}` — the OpenAI-compatible envelope,
///      which every relay in this app speaks.
///   2. `{"code":10012,"msg":"…"}` — the WorkBuddy/CodeBuddy business
///      envelope, whose `code` is an INTEGER that must survive into the
///      message (the numbers are the only stable identifier the provider
///      documents; the prose is localized and changes).
///   3. Anything else — a trimmed excerpt, so a plain-text or HTML gateway
///      (Cloudflare interstitial, nginx 429 page) still yields its reason
///      instead of nothing.
///
/// Pure and synchronous on purpose: `mapHTTPError` is called on the streaming
/// path, where there is no second chance to format anything, and this makes
/// the behaviour testable without a server.
enum RateLimitDetail {

    /// Longest excerpt kept from a non-JSON body. Enough for a real sentence or
    /// a business code, short enough to live in an error banner. Bodies on this
    /// path are already drained fully by the caller, so this only bounds what
    /// is DISPLAYED.
    static let maxExcerpt = 160

    /// Describe `body` for a 429.
    ///
    /// - Parameter body: the raw response body, possibly empty.
    /// - Returns: a non-empty, single-line, human-readable reason. Never empty:
    ///   an unparseable body degrades to a generic sentence rather than to "".
    ///
    /// `Retry-After` is parsed separately (`parseRetryAfter`) and carried on the
    /// error alongside this text, so the banner can show a countdown without
    /// this function having to know the clock.
    static func describe(body: String) -> String {
        let parsed = parseBody(body)
        if !parsed.isEmpty { return parsed }
        return "no reason given by the gateway"
    }

    /// The vendor's own reason, or "" when the body carries none.
    static func parseBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let data = trimmed.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // 1. OpenAI-compatible: error is an object with message/code/type.
            if let error = root["error"] as? [String: Any] {
                var pieces: [String] = []
                if let message = error["message"] as? String, !message.isEmpty {
                    pieces.append(message)
                }
                // `code` and `type` are sometimes integers, sometimes strings,
                // and carry the only stable identifier the provider documents.
                for key in ["code", "type"] {
                    if let value = error[key], let text = codeText(value) {
                        // Do not repeat a code that the message already contains
                        // — "insufficient_quota (insufficient_quota)" reads as a
                        // bug rather than a diagnostic.
                        if !pieces.contains(where: { $0.contains(text) }) {
                            pieces.append(text)
                        }
                    }
                }
                if !pieces.isEmpty { return join(pieces) }
                return ""
            }

            // 2. WorkBuddy / CodeBuddy business envelope: {code, msg|message}.
            //    `code` here is numeric and MUST survive; `code == 0` means
            //    success, so a non-zero code is the refusal.
            if let code = root["code"], let text = codeText(code), !text.isEmpty, text != "0" {
                let message = (root["msg"] as? String)
                    ?? (root["message"] as? String)
                    ?? ""
                var pieces: [String] = []
                if !message.isEmpty { pieces.append(message) }
                if !pieces.contains(where: { $0.contains(text) }) {
                    pieces.append("code \(text)")
                }
                return join(pieces)
            }
        }

        // 3. Not JSON, or JSON with no recognisable reason. Strip markup and
        //    collapse whitespace so an HTML interstitial does not paste tags
        //    into the banner.
        let plain = collapseWhitespace(strippingTags(trimmed))
        guard !plain.isEmpty else { return "" }
        return String(plain.prefix(maxExcerpt))
    }

    /// Parse an RFC 7231 `Retry-After` value into seconds from now.
    ///
    /// Returns nil when absent or unparseable — a wrong countdown is worse than
    /// no countdown, so anything ambiguous is discarded rather than guessed.
    static func parseRetryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // delta-seconds, the common form.
        if let seconds = TimeInterval(raw) {
            // Negative is nonsense; clamp rather than reject, since a gateway
            // that sends "-1" still means "go away for a moment".
            return max(0, seconds)
        }
        // HTTP-date, the other form the RFC allows.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func join(_ pieces: [String]) -> String {
        let merged = pieces.filter { !$0.isEmpty }.joined(separator: " · ")
        return String(collapseWhitespace(merged).prefix(maxExcerpt * 2))
    }

    /// Render a JSON code/type that may be a string, an Int or a Double.
    /// `NSNumber` bridging means a JSON `true` arrives here too — a boolean is
    /// not a code, so it is refused.
    private static func codeText(_ value: Any) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        // Check Bool BEFORE NSNumber: CFBoolean bridges to NSNumber, and
        // "code true" is meaningless. `is Bool` is the plain-Swift test that
        // does not need CoreFoundation's type IDs.
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let d = number.doubleValue
            if d == d.rounded() { return String(number.int64Value) }
            return String(d)
        }
        return nil
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// Drop HTML tags. Deliberately not a parser: the only job is to keep a
    /// gateway's error page from putting `<html><head>…` into a banner.
    private static func strippingTags(_ text: String) -> String {
        var out = ""
        var depth = 0
        for ch in text {
            if ch == "<" { depth += 1; continue }
            if ch == ">" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
