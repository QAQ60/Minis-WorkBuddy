import Foundation

enum LLMError: LocalizedError {
    case invalidAPIKey(detail: String = "")
    case networkError(underlying: Error)
    case providerError(message: String)
    /// Transient server-side errors (HTTP 500/502/503/504/529) that should be
    /// retried on the same model rather than triggering a group fallback.
    ///
    /// [T-fallback-503-budget] `statusCode` is the HTTP status the mapping site
    /// actually saw, and is nil for transient conditions with no HTTP response
    /// of their own (stall/TTFB timeouts, empty responses, compaction breaches).
    /// It exists so the fallback planner can tell "the upstream answered 503,
    /// this model has no capacity" from "our link/stream misbehaved" WITHOUT
    /// substring-matching a body that may legitimately contain "503".
    case transientError(message: String, statusCode: Int? = nil)
    case decodingError(underlying: Error)
    /// HTTP 429. Carries what the gateway actually said.
    ///
    /// [T-rate-limit-detail] A bare `.rateLimited` printed "Rate limited —
    /// please try again later" for every 429, which is true and useless: the
    /// same status is used for a spent credit pool, a concurrency cap and a
    /// per-minute request cap, and only the body says which. The mapping site
    /// used to throw the body away — see `OpenAIProvider.mapHTTPError`.
    ///
    /// `detail` is the vendor's own words (its `code`/`message` where the body
    /// is a JSON envelope, else a trimmed excerpt), empty when the gateway said
    /// nothing. `retryAfter` is the `Retry-After` header in seconds when the
    /// server sent one, which is the only figure that can drive a countdown.
    ///
    /// Both default so `.rateLimited` remains a valid spelling — older call
    /// sites and the standalone test stubs compile unchanged.
    case rateLimited(detail: String = "", retryAfter: TimeInterval? = nil)
    case cancelled
    case unknown(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let detail):
            return detail.isEmpty ? "Invalid API key" : "Invalid API key: \(detail)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .providerError(let message):
            return "Provider error: \(message)"
        case .transientError(let message, _):
            return "Service temporarily unavailable: \(message)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .rateLimited(let detail, let retryAfter):
            // [T-rate-limit-detail] Name the cause when the gateway named one,
            // and say how long when it said — "please try again later" alone
            // was the whole message for a spent credit pool AND a concurrency
            // cap AND a per-minute cap.
            var text = "Rate limited"
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { text += ": \(trimmed)" }
            if let retryAfter, retryAfter > 0 {
                text += String(format: " (retry in %ds)", Int(retryAfter.rounded()))
            } else if trimmed.isEmpty {
                text += " — please try again later"
            }
            return text
        case .cancelled:
            return "Request was cancelled"
        case .unknown(let error):
            return "Unknown error: \(error?.localizedDescription ?? "no details")"
        }
    }

    var isNetworkError: Bool {
        if case .networkError = self { return true }
        return false
    }

    /// Errors that should be retried with countdown on the same provider.
    /// Includes both network errors and transient server-side errors (5xx).
    var isRetryable: Bool {
        switch self {
        case .networkError, .transientError:
            return true
        case .invalidAPIKey, .providerError, .decodingError, .rateLimited, .cancelled, .unknown:
            return false
        }
    }

    /// Whether the gateway's refusal is about rate/credit pressure, which is the
    /// case a countdown or "come back later" can address.
    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    /// Errors that indicate the provider itself cannot serve this request
    /// (rate limit, invalid key, permanent provider-side rejection). These trigger
    /// an immediate fallback to the next model in a group, without retry countdown.
    ///
    /// Note: transientError and networkError are also fallbackable — after
    /// auto-retry is exhausted on the current model, group fallback kicks in.
    var fallbackReason: String {
        switch self {
        // [T-rate-limit-detail] Say WHY in the fallback trail too; a group of
        // ten WorkBuddy models all reporting bare "Rate limited" tells a user
        // nothing about which limit was hit.
        case .rateLimited(let detail, _):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Rate limited" : "Rate limited: \(String(trimmed.prefix(60)))"
        case .invalidAPIKey: return "Invalid API key"
        case .providerError(let msg): return "Provider error: \(String(msg.prefix(60)))"
        default: return "Error"
        }
    }

    var isFallbackable: Bool {
        switch self {
        case .rateLimited, .invalidAPIKey, .providerError:
            return true
        case .transientError, .networkError, .decodingError, .cancelled, .unknown:
            return false
        }
    }

    /// [T-fallback-503-budget] The HTTP status this error was mapped from, when
    /// the mapping site had one. nil for every non-HTTP condition.
    var httpStatusCode: Int? {
        if case .transientError(_, let code) = self { return code }
        return nil
    }

    /// A transient error the SERVER produced with a 5xx status — i.e. this
    /// model/deployment has no capacity right now, which another group member
    /// may well have. Distinct from a local/link transient (nil status), where
    /// switching models fixes nothing.
    var isServerCapacityTransient: Bool {
        guard let code = httpStatusCode else { return false }
        return (500...599).contains(code)
    }
}
