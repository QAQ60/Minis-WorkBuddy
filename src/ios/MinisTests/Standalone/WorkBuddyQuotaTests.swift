// [T-workbuddy-quota] WorkBuddy's credit meter, and the refusal mends that
// keep a chat from failing for a reason the client can fix.
//
// Reference implementation: kwwk (EYHN/kwwk), whose `WorkBuddyUsageReader` and
// `WorkBuddyWire` this restates in this app's terms. Every claim below is one
// kwwk measured against a real account — the code numbers, which shape answers
// them, and the fact that the plan's capacities arrive as strings.
//
// Standalone (`swift WorkBuddyQuotaTests.swift`, needs swiftc): the shipped
// adapters are compiled as-is, with the same stub surface `ProviderQuotaTests`
// uses.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func source(_ relative: String) -> String {
    let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

let models = source("src/ios/Providers/Quota/QuotaModels.swift")
let rules = source("src/ios/Providers/Quota/QuotaRules.swift")
let adapters = source("src/ios/Providers/Quota/QuotaAdapters.swift")
let support = source("src/ios/Providers/WorkBuddy/WorkBuddySupport.swift")

check("QuotaModels.swift found", !models.isEmpty)
check("QuotaAdapters.swift found", !adapters.isEmpty)
check("WorkBuddySupport.swift found", !support.isEmpty)

// MARK: - Harness

// The shipped files carry a lot of surface this test does not exercise. Rather
// than stub each dependency, the harness compiles the two WorkBuddy-only
// members — the meter parser and the refusal mends — from source that is
// EXTRACTED by marker. The extraction is checked, so a rename fails here
// instead of silently testing a stale copy.
func section(_ text: String, from start: String, to end: String) -> String? {
    guard let s = text.range(of: start) else { return nil }
    guard let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return nil }
    return String(text[s.lowerBound..<e.lowerBound])
}

/// The real QuotaAmounts, read only so the harness's stub can be checked
/// against it (see "Stub drift" in the harness).
let amountsSource = section(models, from: "struct QuotaAmounts", to: "// MARK: - Pools") ?? ""

guard let meter = section(adapters, from: "struct WorkBuddyQuotaAdapter", to: "// MARK: - Relays"),
      let mends = section(support, from: "enum WorkBuddyRefusalMend", to: "\n}\n")
else {
    print("❌ could not extract the sources under test")
    exit(1)
}

// `QuotaPool` / `UpstreamQuotaSnapshot` are wide; the harness builds only what
// the parser touches, with the same member names and order.
let stubs = #"""
import Foundation

struct QuotaSubjectID: Hashable { let vendor: String; let accountKey: String }

struct QuotaPoolKey: Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(subject: QuotaSubjectID, family: String, qualifier: String? = nil) {
        var s = "\(subject.vendor):\(subject.accountKey):\(family)"
        if let qualifier, !qualifier.isEmpty { s += ":\(qualifier)" }
        self.rawValue = s
    }
}

enum QuotaSource { case officialQuery }
enum QuotaConfidence { case documented }
struct QuotaProvenance {
    var source: QuotaSource
    var confidence: QuotaConfidence
    var adapterId: String
    var endpoint: String?
    var relayHost: String?
}

struct QuotaPool {
    enum Kind { case prepaidBalance, spendCap, allowance, usageWindow, rateLimit }
    enum Verdict { case allowed, warning, rejected }
    var id: QuotaPoolKey
    var kind: Kind
    var unit: QuotaUnit
    var vendorLabel: String?
    var amounts: QuotaAmounts?
    var windows: [Int] = []
    var verdict: Verdict?
}

struct QuotaPoolBinding {
    enum Target { case subject }
    enum Evidence { case assumedSubjectWide, vendorDocumented, explicitUpstream }
    var poolKey: QuotaPoolKey
    var target: Target
    var evidence: Evidence
}

struct UpstreamQuotaSnapshot {
    var capturedAt: Date
    var provenance: QuotaProvenance
    var subjectId: QuotaSubjectID
    var pools: [QuotaPool]
    var bindings: [QuotaPoolBinding]
    var accountAvailable: Bool?
}

enum QuotaUnit { case credits(name: String?) }

struct QuotaAmounts {
    var total: Decimal?
    var used: Decimal?
    var remaining: Decimal?
    var breakdown: [Part] = []

    struct Part {
        var role: Role
        var amount: Decimal
        var expiresAt: Date?
        enum Role: Hashable { case granted, toppedUp, voucher, cash; case other(String) }
        init(role: Role, amount: Decimal, expiresAt: Date? = nil) {
            self.role = role
            self.amount = amount
            self.expiresAt = expiresAt
        }
    }
}

struct QuotaHTTPResponse { var status: Int; var body: Data; var headers: [String: String] }

struct QuotaFetchError: Error {
    enum Kind { case badResponse, unauthorized, forbidden, notFound, rateLimited, server, unsupportedResponse }
    var kind: Kind
    var detail: String
}

enum QuotaHTTP {
    static func jsonObject(_ data: Data, endpoint: String) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "not a JSON object")
        }
        return obj
    }
    static func error(for r: QuotaHTTPResponse, endpoint: String, now: Date) -> QuotaFetchError? {
        guard !(200..<300).contains(r.status) else { return nil }
        return QuotaFetchError(kind: r.status == 401 ? .unauthorized : .badResponse,
                               detail: "HTTP \(r.status)")
    }
    static func clockOffset(_ r: QuotaHTTPResponse, now: Date) -> Double? { nil }
}

struct WorkBuddySite { static let userAgent = "WorkBuddy/5.5.6" }

struct QuotaInstanceDescriptor { var isOAuth: Bool; var customBaseURL: String? }
struct QuotaCapability {
    var isActive: Bool
    static func activeQuery() -> QuotaCapability { QuotaCapability(isActive: true) }
    static func unsupported(_ reason: String) -> QuotaCapability { QuotaCapability(isActive: false) }
}
struct QuotaFetchOutcome { var snapshot: UpstreamQuotaSnapshot; var isComplete: Bool = true }
protocol QuotaHTTPTransport: Sendable {
    func post(_ url: URL, bearer: String, headers: [String: String], body: String) async throws -> QuotaHTTPResponse
}
struct QuotaFetchContext {
    var descriptor: QuotaInstanceDescriptor
    var subjectId: QuotaSubjectID
    var credential: String
    var transport: QuotaHTTPTransport
    var now: Date
    var extraHeaders: [String: String] = [:]
}
extension ProviderQuotaAdapter {
    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability { .activeQuery() }
    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        throw QuotaFetchError(kind: .badResponse, detail: "unused")
    }
}
protocol ProviderQuotaAdapter: Sendable { var adapterId: String { get } }
"""#

let harness = #"""
import Foundation
var failures = 0
func t(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
func eq<T: Equatable>(_ label: String, _ a: T, _ b: T) {
    if a == b { print("  ✅ \(label)") } else { print("  ❌ \(label) — expected \(b), got \(a)"); failures += 1 }
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
let sub = QuotaSubjectID(vendor: "workBuddy", accountKey: "instance:abc")

// ── The meter ─────────────────────────────────────────────────────────
// The shape WorkBuddy's own 套餐与用量 page is drawn from. Two packages: the
// monthly base allowance, fully spent, and the platform bonus pool. The sum is
// what the user checks against the app.
print("— Credit meter")
let metered = #"{"code":0,"msg":"OK","data":{"Packages":[{"CycleTotalCapacity":"500","CycleUsedCapacity":"500"},{"CycleTotalCapacity":"4132","CycleUsedCapacity":"2090.97"}]}}"#
if let snap = try? WorkBuddyQuotaAdapter.parse(Data(metered.utf8), subjectId: sub, now: now) {
    let pool = snap.pools.first
    eq("total is the sum over packages", pool?.amounts?.total, Decimal(string: "4632"))
    eq("used is the sum over packages", pool?.amounts?.used, Decimal(string: "2590.97"))
    eq("remaining is total minus used",
       pool?.amounts?.remaining, Decimal(string: "4632")! - Decimal(string: "2590.97")!)
    eq("one pool, one binding", snap.pools.count == 1 && snap.bindings.count == 1)
    eq("counted as an allowance (so a percent is computed)", pool?.kind, .allowance)
    t("each package is a breakdown part", (pool?.amounts?.breakdown.count ?? 0) == 2)
    t("a partly-used plan is not rejected", pool?.verdict != .rejected)
} else {
    check("the two-package response parses", false)
}

// A spent-out plan is `rejected`, which the quota screen shows as exhausted.
let spent = #"{"code":0,"data":{"Packages":[{"CycleTotalCapacity":"500","CycleUsedCapacity":"500"}]}}"#
if let snap = try? WorkBuddyQuotaAdapter.parse(Data(spent.utf8), subjectId: sub, now: now) {
    eq("an exhausted plan is rejected", snap.pools.first?.verdict, .rejected)
    eq("remaining floors at 0, never negative", snap.pools.first?.amounts?.remaining, 0)
} else {
    check("an exhausted plan parses", false)
}

// Capacities arrive as strings; a bare number and an empty string both occur.
let mixed = #"{"code":0,"data":{"Packages":[{"CycleTotalCapacity":3300,"CycleUsedCapacity":"438.88000002"},{"CycleTotalCapacity":"","CycleUsedCapacity":""}]}}"#
if let snap = try? WorkBuddyQuotaAdapter.parse(Data(mixed.utf8), subjectId: sub, now: now) {
    eq("a bare number is read like a string", snap.pools.first?.amounts?.total, 3300)
    eq("empty capacities are 0, not a failure",
       snap.pools.first?.amounts?.used, Decimal(string: "438.88000002"))
} else {
    check("mixed number/string capacities parse", false)
}

// Refusals must not look like a balance of zero.
let refused = #"{"code":10001,"msg":"登录态已失效，请重新登录"}"#
t("a non-zero code is an error, never a zero balance",
  (try? WorkBuddyQuotaAdapter.parse(Data(refused.utf8), subjectId: sub, now: now)) == nil)
t("an empty Packages list is an error",
  (try? WorkBuddyQuotaAdapter.parse(Data(#"{"code":0,"data":{"Packages":[]}}"#.utf8),
                                    subjectId: sub, now: now)) == nil)
t("an unreadable capacity refuses the whole response",
  (try? WorkBuddyQuotaAdapter.parse(
      Data(#"{"code":0,"data":{"Packages":[{"CycleTotalCapacity":"lots","CycleUsedCapacity":"0"}]}}"#.utf8),
      subjectId: sub, now: now)) == nil)
t("every package granting 0 is an error (nothing to show)",
  (try? WorkBuddyQuotaAdapter.parse(
      Data(#"{"code":0,"data":{"Packages":[{"CycleTotalCapacity":"0","CycleUsedCapacity":"0"}]}}"#.utf8),
      subjectId: sub, now: now)) == nil)

// ── Refusal mends ─────────────────────────────────────────────────────
print("— Refusals")

// 11153: the conversation must end with a user message. Tool results followed
// by the user's message trip it; an empty assistant reply between them is served.
var afterTools: [String: Any] = ["messages": [
    ["role": "system", "content": "sys"],
    ["role": "user", "content": "hi"],
    ["role": "assistant", "content": "calling"],
    ["role": "tool", "content": "result"],
    ["role": "user", "content": "and now?"],
]]
let refusal11153 = #"{"code":11153,"msg":"the conversation must end with a user message"}"#
t("11153 is claimed", WorkBuddyRefusalMend.mend(&afterTools, refusal: refusal11153))
let msgs = (afterTools["messages"] as? [[String: Any]]) ?? []
eq("an empty assistant reply is inserted after the tool result",
   msgs.map { $0["role"] as! String },
   ["system", "user", "assistant", "tool", "assistant", "user"])
t("the inserted reply is empty",
  (msgs[4]["content"] as? String) == "")

// Not every 11153-shaped body needs mending: one already ending on the user's
// message with no tool result behind it must be left alone.
var alreadyFine: [String: Any] = ["messages": [
    ["role": "system", "content": "s"], ["role": "user", "content": "u"],
]]
t("a chat with no tool results is not claimed",
  !WorkBuddyRefusalMend.mend(&alreadyFine, refusal: refusal11153))

// 11128 with the channel wording: the system prompt is moved into the chat.
var channelled: [String: Any] = ["messages": [
    ["role": "system", "content": "You are Claude Code, Anthropic's official CLI for Claude"],
    ["role": "user", "content": "hello"],
]]
let refusal11128 = #"{"code":11128,"msg":"Illegal API invocation from an unapproved channel: You are Claude Code, Anthropic's official CLI for Claude"}"#
t("11128 with the channel wording is claimed",
  WorkBuddyRefusalMend.mend(&channelled, refusal: refusal11128))
let moved = (channelled["messages"] as? [[String: Any]]) ?? []
t("a plain system prompt is kept first",
  (moved.first?["role"] as? String) == "system"
  && (moved.first?["content"] as? String) == "You are a helpful assistant.")
let userText = moved.dropFirst().first { ($0["role"] as? String) == "user" }?["content"] as? String ?? ""
t("the refusal's own line is reworded away (it is in `flagged`)",
  !userText.lowercased().contains("official cli for claude"))
t("the instructions are wrapped in tags",
  userText.contains("<instructions>") && userText.contains("</instructions>"))
t("the user's own words survive underneath", userText.contains("hello"))

// 11128 for "first message is not system prompt" is NOT a channel refusal, and
// no rewording mends it — claiming it would burn the one retry.
var wrongShape: [String: Any] = ["messages": [["role": "user", "content": "u"]]]
t("11128 for an unrelated reason is not claimed",
  !WorkBuddyRefusalMend.mend(&wrongShape,
                             refusal: #"{"code":11128,"msg":"first message is not system prompt"}"#))

// A code we do not know must pass through untouched.
var unknown: [String: Any] = ["messages": [["role": "system", "content": "s"]]]
let before = (unknown["messages"] as? [[String: Any]])?.count
t("an unknown code is not claimed",
  !WorkBuddyRefusalMend.mend(&unknown, refusal: #"{"code":9999,"msg":"nope"}"#))
eq("...and the body is untouched", (unknown["messages"] as? [[String: Any]])?.count, before)

// The refusal envelope is found wherever the gateway puts it.
t("code under data", WorkBuddyRefusalMend.parseRefusal(#"{"data":{"code":11153,"msg":"x"}}"#)?.code == "11153")
t("code under error", WorkBuddyRefusalMend.parseRefusal(#"{"error":{"code":11101,"message":"y"}}"#)?.code == "11101")
t("OpenAI-shaped message", WorkBuddyRefusalMend.parseRefusal(#"{"error":{"message":"z"}}"#)?.message == "z")
t("a non-JSON body yields nothing", WorkBuddyRefusalMend.parseRefusal("<html>502</html>") == nil)

// ── Stub drift ────────────────────────────────────────────────────────
// The harness stubs `QuotaAmounts` rather than compiling the real one (it is
// Codable through this app's decimal codec). These catch a rename that would
// otherwise let the tests keep passing against a shape nothing writes.
print("— Stub drift")
for field in ["var total: Decimal?", "var used: Decimal?", "var remaining: Decimal?",
              "var breakdown: [Part] = []", "init(role: Role, amount: Decimal, expiresAt: Date? = nil)",
              "case other(String)"] {
    t("QuotaAmounts keeps \(field)", amountsSource.contains(field))
}

print("HARNESS failures=\(failures)")
exit(failures == 0 ? 0 : 1)
"""#

do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("workbuddy-quota-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // QuotaAmounts comes from the STUB, not from source: the real one is
    // Codable through this app's decimal codec, which is a dependency this
    // harness must not pull in. The fields and the Part initialiser are the
    // same, and `Q-Part` below fails if they drift.
    // `section(to:)` stops BEFORE the end marker, so the enum's own closing
    // brace is missing from the extraction; and the enum reads one constant
    // from the type beside it.
    let mendSource = """
    enum WorkBuddyBodyMend { static let defaultSystemPrompt = "You are a helpful assistant." }
    \(mends)
    }
    """
    var sources = [stubs, meter, mendSource]
    var paths: [String] = []
    for (i, text) in sources.enumerated() {
        let url = tmp.appendingPathComponent("src\(i).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        paths.append(url.path)
    }
    let main = tmp.appendingPathComponent("main.swift")
    try harness.write(to: main, atomically: true, encoding: .utf8)
    let bin = tmp.appendingPathComponent("t")

    func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"] + paths + [main.path, "-o", bin.path])
    check("the shipped parser and mends compile standalone", cc == 0)
    if cc != 0 { print(ccOut) }

    let (rc, out) = run(bin.path, [])
    print(out, terminator: "")
    check("all WorkBuddy quota scenarios pass", rc == 0 && out.contains("HARNESS failures=0"))
} catch {
    check("harness setup: \(error)", false)
}

print(failures == 0 ? "ALL PASS" : "FAILURES=\(failures)")
exit(failures == 0 ? 0 : 1)
