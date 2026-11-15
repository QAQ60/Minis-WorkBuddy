// [T-workbuddy-catalog] WorkBuddy's `/v3/config` is not an OpenAI `/models`
// page: the plan's model list lives under an agent surface, and the numbers a
// picker needs (credit multiple, context window, whether thinking can be
// turned off) hang off each model's detail record. The parser reads five of
// those fields; before this file nothing pinned any of them, so a field
// renamed upstream would have silently degraded to "no rate, no window" —
// which is exactly the "why is my balance not moving" question a user asks.
//
// The reference implementation is kwwk's `WorkBuddyModelCatalog`
// (EYHN/kwwk), which Apelin's worker links. Each case below restates one of
// its behaviours in this app's terms.
//
// Standalone (`swift WorkBuddyCatalogTests.swift`, needs swiftc): like its
// neighbours, so the shipped parsing code is compiled as-is with a stub
// `LLMModel` rather than duplicated here.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
func checkEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

// MARK: - The sources under test

/// Point this at the repository root: `swift WorkBuddyCatalogTests.swift` from
/// the repo, or pass an explicit path as argv[1].
let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func source(_ relative: String) -> String {
    let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

let modelsAPI = source("src/ios/Providers/WorkBuddy/WorkBuddyModelsAPI.swift")
let support = source("src/ios/Providers/WorkBuddy/WorkBuddySupport.swift")

check("WorkBuddyModelsAPI.swift found", !modelsAPI.isEmpty)
check("WorkBuddySupport.swift found", !support.isEmpty)

// MARK: - Harness

// `WorkBuddyModelsAPI` only needs Foundation plus four names from the app:
// the site enum (shipped, in WorkBuddySupport), `LLMModel`, `ModelModality`
// and `LLMError`. The stubs below mirror the real declarations' ARGUMENT
// ORDER, because `LLMModel` is built with a labelled call that relies on it.
let stubs = #"""
import Foundation

struct ModelModality: OptionSet {
    let rawValue: Int
    static let textInput = ModelModality(rawValue: 1)
    static let imageInput = ModelModality(rawValue: 2)
    static let fullMultimodal = ModelModality(rawValue: 3)
}

/// Declared in the same order as the app's `LLMModel.init`, defaults included.
struct LLMModel {
    var id: String
    var displayName: String
    var provider: String
    var modalityOverride: ModelModality? = nil
    var contextWindow: Int? = nil
    var maxOutputTokens: Int? = nil
    var supportsReasoning: Bool? = nil
    var interleavedReasoningField: String? = nil
    var reasoningEffortValues: [String]? = nil
    var declaresNoEffortTiers: Bool? = nil
}

enum LLMError: Error { case providerError(message: String) }
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

// ── Credit multiple ───────────────────────────────────────────────────
// WorkBuddy's picker shows the plan's own multiple: "x0.03", "x0.00" (free),
// or a bare number. This is the field that answers "is this chat costing me
// anything", so every spelling the config has been seen to use is pinned.
print("— Credit multiple")
t("x0.03 → 0.03", WorkBuddyModelsAPI.creditRate("x0.03") == 0.03)
t("x0.00 (free) → 0.00, not nil", WorkBuddyModelsAPI.creditRate("x0.00") == 0.0)
t("X0.11 (upper-case X) → 0.11", WorkBuddyModelsAPI.creditRate("X0.11") == 0.11)
t("bare \"0\" → 0", WorkBuddyModelsAPI.creditRate("0") == 0.0)
t("a number, not a string (NSNumber) → read anyway", WorkBuddyModelsAPI.creditRate(NSNumber(value: 0.79)) == 0.79)
t("whitespace tolerated", WorkBuddyModelsAPI.creditRate("  x0.5  ") == 0.5)
t("junk → nil (never a made-up 0)", WorkBuddyModelsAPI.creditRate("cheap") == nil)
t("missing → nil", WorkBuddyModelsAPI.creditRate(nil) == nil)
t("negative → nil", WorkBuddyModelsAPI.creditRate("x-1") == nil)

// ── Display name ──────────────────────────────────────────────────────
// The rate rides in the display name because that is what the picker, the
// quota card and the agent all read; a separate field would have to be
// plumbed through each of them.
print("— Display name")
eq("a rate is appended", WorkBuddyModelsAPI.displayedName("GLM-5.3", rate: 0.03), "GLM-5.3 · x0.03")
eq("free reads as x0", WorkBuddyModelsAPI.displayedName("DeepSeek-V4.1-Flash", rate: 0), "DeepSeek-V4.1-Flash · x0")
eq("a whole rate keeps no decimals", WorkBuddyModelsAPI.displayedName("Hy3", rate: 1), "Hy3 · x1")
eq("0.11 keeps both decimals", WorkBuddyModelsAPI.displayedName("DeepSeek", rate: 0.11), "DeepSeek · x0.11")
eq("no rate → the name is left alone", WorkBuddyModelsAPI.displayedName("GLM-5.3", rate: nil), "GLM-5.3")

// ── Colliding names ───────────────────────────────────────────────────
// The international build lists `deepseek-v4.1-flash` (free) and
// `deepseek-v4.1-flash-sg` (paid) BOTH as "Deepseek-V4.1-Flash". Two rows
// with one name leaves no way to know which one is free.
print("— Colliding names")
eq("a repeated name gains what its id adds",
   WorkBuddyModelsAPI.distinctNames([
       (id: "deepseek-v4.1-flash", name: "Deepseek-V4.1-Flash"),
       (id: "deepseek-v4.1-flash-sg", name: "Deepseek-V4.1-Flash"),
   ]),
   ["Deepseek-V4.1-Flash", "Deepseek-V4.1-Flash (SG)"])
eq("an id unrelated to the first falls back to itself",
   WorkBuddyModelsAPI.distinctNames([
       (id: "glm-5.3", name: "GLM"),
       (id: "hy3", name: "GLM"),
   ]),
   ["GLM", "GLM (HY3)"])
eq("distinct names are untouched, in order",
   WorkBuddyModelsAPI.distinctNames([
       (id: "a", name: "A"), (id: "b", name: "B"),
   ]),
   ["A", "B"])
eq("three of one name: the second and third both tagged",
   WorkBuddyModelsAPI.distinctNames([
       (id: "m", name: "M"), (id: "m-sg", name: "M"), (id: "m-jp", name: "M"),
   ]),
   ["M", "M (SG)", "M (JP)"])

// ── Images ────────────────────────────────────────────────────────────
// The international config marks EVERY model `supportsImages`, but a picture
// sent to its GLM models is dropped server-side. Listing them as vision makes
// the user attach something that never arrives.
print("— Images")
t("international GLM is text-only whatever the config says",
   WorkBuddyModelsAPI.textOnly(site: .international, id: "glm-5.3-flash"))
t("international non-GLM keeps its images",
   !WorkBuddyModelsAPI.textOnly(site: .international, id: "deepseek-v4.1-flash"))
t("the China build's GLM reads images",
   !WorkBuddyModelsAPI.textOnly(site: .china, id: "glm-5.3"))

// ── Reasoning tiers ───────────────────────────────────────────────────
print("— Reasoning tiers")
eq("declared tiers are kept, lower-cased, with \"none\" prepended",
   WorkBuddyModelsAPI.effortTiers(from: [
       "reasoning": ["supportedEfforts": ["LOW", "HIGH"]],
   ]),
   ["none", "low", "high"])
eq("onlyReasoning → no \"none\"", 
   WorkBuddyModelsAPI.effortTiers(from: [
       "onlyReasoning": true,
       "reasoning": ["supportedEfforts": ["low", "high"]],
   ]),
   ["low", "high"])
eq("canDisableThinking:false → no \"none\"",
   WorkBuddyModelsAPI.effortTiers(from: [
       "reasoning": ["supportedEfforts": ["low", "high"], "canDisableThinking": false],
   ]),
   ["low", "high"])
// The short form several fast models use: no `supportedEfforts`, only a flag
// and a default effort. kwwk's authors measured each of these answering with
// reasoning, so the ladder is low/high/max plus whatever it named.
eq("supportsReasoning alone → low/high/max",
   WorkBuddyModelsAPI.effortTiers(from: ["supportsReasoning": true]),
   ["none", "low", "high", "max"])
eq("a declared default joins the ladder",
   WorkBuddyModelsAPI.effortTiers(from: [
       "supportsReasoning": true, "reasoning": ["effort": "medium"],
   ]),
   ["none", "low", "medium", "high", "max"])
eq("no reasoning at all → nil (no tiers offered)",
   WorkBuddyModelsAPI.effortTiers(from: ["id": "x"]), nil)
eq("an empty declared list falls through to the flag",
   WorkBuddyModelsAPI.effortTiers(from: [
       "supportsReasoning": true, "reasoning": ["supportedEfforts": []],
   ]),
   ["none", "low", "high", "max"])

print("HARNESS failures=\(failures)")
exit(failures == 0 ? 0 : 1)
"""#

do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("workbuddy-catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let sources = [modelsAPI, support, stubs]
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
    check("the shipped parser compiles standalone", cc == 0)
    if cc != 0 { print(ccOut) }

    let (rc, out) = run(bin.path, [])
    print(out, terminator: "")
    check("all catalogue scenarios pass", rc == 0 && out.contains("HARNESS failures=0"))
} catch {
    check("harness setup: \(error)", false)
}

print(failures == 0 ? "ALL PASS" : "FAILURES=\(failures)")
exit(failures == 0 ? 0 : 1)
