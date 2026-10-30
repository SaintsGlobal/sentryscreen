import Foundation

// Diagnostic reports, the pure half (docs/diagnostics.md): the redaction
// function, the allowlists, and the report builder that turns already-read
// inputs into the JSON object the owner reviews and may send. Nothing here
// touches the disk, launchd or the network; Diagnostics.swift gathers the
// inputs and sends. `--ui-selftest` (DiagnosticsSelfTest.swift) drives this
// file against the fixtures under daemon/testdata/diagnostics/. A report is built
// from allowlists, never from a raw log dump: a line whose prefix or event is
// not named below is not in it.

/// Redaction pass over every string that enters a report: ONE function,
/// applied last (`DiagnosticsReport.build` walks the finished object), so a
/// new section cannot forget it.
enum DiagnosticsRedaction {
    // Order matters: e-mail before the `name(uid)` rule so `a@b.c(501)`
    // cannot leave the address behind.
    static let rules: [(pattern: String, replacement: String)] = [
        // U+0000 first: a NUL survives lossy UTF-8 decoding into JSON as
        // `\u0000`, which the receiver's jsonb column refuses.
        ("\\x{0}", ""),
        // Stable device identifiers a macOS `.ips` carries.
        ("\"crashReporterKey\"\\s*:\\s*\"[^\"]*\"", "\"crashReporterKey\" : \"<redacted>\""),
        ("\"bootSessionUUID\"\\s*:\\s*\"[^\"]*\"", "\"bootSessionUUID\" : \"<redacted>\""),
        // `/Users/<x>/…` → `/Users/…/…` (home paths name the account), and
        // the JSON-escaped `\/Users\/<x>` form a macOS `.ips` file uses.
        ("/Users/[^/\\s\"'\\\\]+", "/Users/…"),
        ("\\\\/Users\\\\/[^/\\s\"'\\\\]+", "\\\\/Users\\\\/…"),
        // E-mail addresses. The lookbehind starts a match only at the head
        // of a run (the leftmost match would start there anyway, so the
        // match set is unchanged) and the possessive `++` never backtracks
        // into the run: without both, a 100 KB run of word characters —
        // the oversize self-test fixture — cost minutes (MEASURED 2026-09-10:
        // 5.8 s per 20 K chars, quadratic) instead of milliseconds.
        ("(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]++@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
        // `name(uid)` — AdminCheck.currentUserLabel's form in `by`,
        // `updatedBy` and the `ui` session line → `user(uid)`.
        // Same run-head guard and possessive `*+` as the e-mail rule.
        ("(?<![A-Za-z_])[A-Za-z_][A-Za-z0-9._-]*+\\((\\d{3,6})\\)", "user($1)"),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.map {
        // The table is a compile-time literal; a pattern that does not
        // compile is a build defect, so a crash here is the loud failure.
        (try! NSRegularExpression(pattern: $0.pattern), $0.replacement)
    }

    static func redact(_ text: String) -> String {
        var out = text
        for (regex, replacement) in compiled {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        return out
    }

    /// Every string anywhere in a JSON value, keys included (a settings key
    /// is never a name today; the walk covers it so a future one cannot leak).
    static func redact(json value: Any) -> Any {
        switch value {
        case let s as String: return redact(s)
        case let a as [Any]: return a.map(redact(json:))
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[redact(k)] = redact(json: v) }
            return out
        default: return value
        }
    }
}

/// The allowlists: the ONLY lines and records a report may carry.
/// Detection results never appear: `curtain` is deliberately absent from
/// both lists (its records are COUNTED, `DiagnosticsReport.curtainCounts`),
/// and so are `region`, `detect`, `policy`, `summary`'s neighbours and the
/// per-window `hold`/`parole` lines.
enum DiagnosticsAllowlist {
    /// agent.err line prefixes (the text before the first `:` or space —
    /// `config /Library/…/config.json: …` is prefix `config`).
    static let agentErrPrefixes: Set<String> = [
        "onboarding", "capture", "config", "ui", "ui-state", "ui-queue",
        "uninstall", "WARNING", "sentry-screen", "pin-recovery", "pin-authority",
    ]
    /// run.jsonl `event` values shipped whole.
    static let runEvents: Set<String> = [
        "capture", "onboarding", "uninstall", "tier", "pause", "resume", "held", "ui",
        "tuning",
        // 2026-09-11 (review): the two "detector" records are the
        // only ones carrying the streak budget, its limit, the observed streak
        // and the fix, and a support report about "it said interrupted" needs
        // exactly those. The alerts.log ALERT reaches a report already; this is
        // the engineer-readable half. No content, no window titles — the
        // messages are written in full at their two `logger.event` sites.
        "detector",
    ]
    /// Curtain record prefixes counted (info's first word; `ghost-ban` in
    /// the log is `ghost_ban` in the report).
    static let curtainCounts: [(prefix: String, key: String)] = [
        ("drop", "drop"), ("lift", "lift"), ("handoff", "handoff"), ("ghost-ban", "ghost_ban"),
    ]
    /// settings.json keys whose value is a `name(uid)` label, replaced by
    /// the account's role (never the username).
    static let actorKeys: Set<String> = ["by", "updatedBy"]

    /// Line and record budgets. DERIVED from the same receipt as
    /// the size cap: alerts.log after a normal day is ~2.5 KB (~30 lines),
    /// agent.err ~22 KB (~220 lines, MEASURED 2026-09-09 on an M1 Mac: 223
    /// lines, 89 of them `curtain` and therefore excluded); 200/300 cover a
    /// whole bad day, and the size cap below is the backstop.
    static let alertsLogLines = 200
    static let agentErrLines = 300
    static let runSummaries = 20
    static let runEventRecords = 50

    static func agentErrPrefix(_ line: String) -> String {
        var end = line.startIndex
        while end < line.endIndex, line[end] != ":", line[end] != " " { end = line.index(after: end) }
        return String(line[..<end])
    }
}

/// Inputs already read from disk (Diagnostics.swift gathers them; the
/// selftest builds them from fixtures). Strings are raw file contents; nil
/// means the file was absent or unreadable, which the report says by name
/// (`"missing"` sections are facts support wants, not silent gaps).
struct DiagnosticsInputs {
    var createdAt: Int
    var buildMetadataTSV: String?
    var modelIdentityTSV: String?
    var osVersion: String
    var arch: String
    var hwModel: String
    var uptimeS: Int
    var uid: uid_t
    var isAdmin: Bool
    var consoleUserPresent: Bool
    var settingsJSON: Data?
    var launchd: [String: [String: Any]]
    /// Per-uid alerts.log (agent + watchdog).
    var alertsLog: String?
    var agentErr: String?
    var runJSONL: String?
    var crash: (file: String, ips: String)?
    /// uid → is that account an administrator (AdminCheck.isAdminSession).
    var isAdminUID: (uid_t) -> Bool
    /// Extra `app` fields the process adds about itself (launch tuning, active
    /// dev overrides).
    var appExtras: [String: Any] = [:]
}

enum DiagnosticsReport {
    static let version = 1

    /// Size cap, before gzip. Receipt (MEASURED 2026-09-09): alerts.log after
    /// a normal day ≈ 2.5 KB, agent.err ≈ 22 KB, a sentry-screen `.ips` ≈
    /// 7–100 KB; 256 KiB is ~2× the worst case seen and under the receiver's
    /// DIAGNOSTICS_BODY_BYTES (393,216) with the envelope. Oversize ⇒ the
    /// largest section is halved (oldest half dropped) until it fits, named
    /// in `truncated`.
    static let maxReportBytes = 256 * 1024

    /// The sections `enforceCap` may shrink, largest first. Everything else
    /// is fixed-size metadata a cap could not meaningfully cut.
    static let truncatableSections = ["alerts_log", "agent_err", "run_events", "run_summaries", "crash"]

    static func build(_ input: DiagnosticsInputs) -> [String: Any] {
        var report: [String: Any] = [
            "v": version,
            "reason": "manual",
            "created_at": input.createdAt,
            "app": app(from: input.buildMetadataTSV).merging(input.appExtras) { _, extra in extra },
            "model": input.modelIdentityTSV.map { tsv($0) } ?? ["missing": true],
            "os": [
                "version": input.osVersion, "arch": input.arch,
                "hw_model": input.hwModel, "uptime_s": input.uptimeS,
            ] as [String: Any],
            "session": [
                "uid": Int(input.uid), "is_admin": input.isAdmin,
                "console_user_present": input.consoleUserPresent,
            ] as [String: Any],
            "launchd": input.launchd,
        ]
        let settings = settingsObject(input.settingsJSON, isAdminUID: input.isAdminUID)
        report["settings"] = settings
        report["alerts_log"] = alertsLog(input.alertsLog)
        report["agent_err"] = agentErr(input.agentErr)
        let run = runRecords(input.runJSONL)
        report["run_summaries"] = run.summaries
        report["run_events"] = run.events
        report["curtain_counts"] = run.curtainCounts
        if let crash = input.crash {
            report["crash"] = ["file": crash.file, "ips": crash.ips]
        }
        // Last, over the whole object: one pass no section can skip.
        return DiagnosticsRedaction.redact(json: report) as! [String: Any]
    }

    /// Serialise, enforcing `maxReportBytes`. Returns the bytes and the
    /// final object (with `truncated` filled in when a cut was needed).
    static func encode(_ report: [String: Any]) throws -> (data: Data, report: [String: Any]) {
        var current = report
        var truncated: [String] = (report["truncated"] as? [String]) ?? []
        while true {
            let data = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
            if data.count <= maxReportBytes { return (data, current) }
            guard let (name, shrunk) = shrinkLargest(current) else {
                // Nothing left to cut and still over: say so in the report
                // itself rather than silently shipping or dropping it.
                current["truncated"] = truncated + ["unshrinkable"]
                current["truncation_failed"] = "budget DiagnosticsReport.maxReportBytes limit=\(maxReportBytes) observed=\(data.count) (fix: DiagnosticsReport.truncatableSections)"
                let last = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
                return (last, current)
            }
            current = shrunk
            if !truncated.contains(name) { truncated.append(name) }
            current["truncated"] = truncated
        }
    }

    /// Halve the largest truncatable section (dropping its OLDEST half — the
    /// newest lines are the ones that explain the trigger). nil when no
    /// section can shrink further.
    private static func shrinkLargest(_ report: [String: Any]) -> (String, [String: Any])? {
        func size(_ value: Any) -> Int {
            (try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]).count) ?? 0
        }
        var best: (name: String, bytes: Int)?
        for name in truncatableSections {
            guard let value = report[name] else { continue }
            let bytes: Int
            if let list = value as? [Any] { bytes = list.count > 1 ? size(value) : 0 }
            else if let crash = value as? [String: Any], let ips = crash["ips"] as? String { bytes = ips.count > 1 ? ips.utf8.count : 0 }
            else { bytes = 0 }
            if bytes > 0, bytes > (best?.bytes ?? 0) { best = (name, bytes) }
        }
        guard let best else { return nil }
        var out = report
        if let list = out[best.name] as? [Any] {
            out[best.name] = Array(list.suffix(list.count / 2))
        } else if var crash = out[best.name] as? [String: Any], let ips = crash["ips"] as? String {
            crash["ips"] = String(ips.suffix(ips.count / 2))
            out[best.name] = crash
        }
        return (best.name, out)
    }

    // MARK: Sections

    /// `key\tvalue` lines, `#` comments skipped (build-metadata.tsv,
    /// model-identity.tsv — packaging/build-pkg.sh writes both).
    static func tsv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            out[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return out
    }

    static func app(from tsvText: String?) -> [String: Any] {
        guard let tsvText else { return ["missing": true] }
        let t = tsv(tsvText)
        return [
            "version": t["version"] ?? NSNull(),
            "build": t["build"] ?? NSNull(),
            "flavor": t["build_flavor"] ?? NSNull(),
            "source_commit": t["source_commit"] ?? NSNull(),
            "signing_mode": t["app_signing_mode_requested"] ?? NSNull(),
        ]
    }

    /// The settings.json top-level keys a report may carry: an allowlist, so
    /// a retired or future key (the old `pin` / `pinFailures` verifier bytes
    /// above all) never ships. `showMenuBarIcon` STAYS (2026-10-20): the
    /// setting is gone but the key is still read and preserved in
    /// settings.json (`UISettings.showMenuBarIcon`), it is a plain bool with
    /// nothing to redact, and a report that shows `false` explains an older
    /// install that once hid the icon.
    static let settingsKeys: Set<String> = [
        "version", "pause", "policyOverride", "showMenuBarIcon", "onboarding",
        "updatedAt", "updatedBy",
    ]

    /// settings.json reduced to `settingsKeys`, with every `by` /
    /// `updatedBy` label replaced by the role of the account it names. An
    /// unparsable file is reported as such.
    static func settingsObject(_ data: Data?, isAdminUID: (uid_t) -> Bool) -> [String: Any] {
        guard let data else { return ["missing": true] }
        guard let any = try? JSONSerialization.jsonObject(with: data), let obj = any as? [String: Any] else {
            return ["unparsable": true, "bytes": data.count]
        }
        let kept = obj.filter { settingsKeys.contains($0.key) }
        return replaceActors(kept, isAdminUID: isAdminUID) as! [String: Any]
    }

    static func actorRole(_ label: String, isAdminUID: (uid_t) -> Bool) -> String {
        guard let open = label.lastIndex(of: "("), label.hasSuffix(")"),
            let uid = UInt32(label[label.index(after: open)..<label.index(before: label.endIndex)])
        else { return "unknown" }
        return isAdminUID(uid_t(uid)) ? "admin" : "standard"
    }

    private static func replaceActors(_ value: Any, isAdminUID: (uid_t) -> Bool) -> Any {
        switch value {
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d {
                if DiagnosticsAllowlist.actorKeys.contains(k), let label = v as? String {
                    out[k] = actorRole(label, isAdminUID: isAdminUID)
                } else {
                    out[k] = replaceActors(v, isAdminUID: isAdminUID)
                }
            }
            return out
        case let a as [Any]: return a.map { replaceActors($0, isAdminUID: isAdminUID) }
        default: return value
        }
    }

    /// The last `alertsLogLines` lines of alerts.log.
    static func alertsLog(_ text: String?) -> [String] {
        guard let text else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(DiagnosticsAllowlist.alertsLogLines))
    }

    static func agentErr(_ text: String?) -> [String] {
        guard let text else { return [] }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { DiagnosticsAllowlist.agentErrPrefixes.contains(DiagnosticsAllowlist.agentErrPrefix($0)) }
        return Array(kept.suffix(DiagnosticsAllowlist.agentErrLines))
    }

    struct RunRecords {
        var summaries: [[String: Any]] = []
        var events: [[String: Any]] = []
        var curtainCounts: [String: Int] = [:]
    }

    /// One pass over the run.jsonl tail: the last N `summary` records
    /// (counters only — the record has no strings besides `state`), the
    /// last M allowlisted events whole, and the curtain records COUNTED by
    /// prefix over the same window. A line that is not a JSON object is
    /// skipped (a torn tail's first line is always partial).
    static func runRecords(_ text: String?) -> RunRecords {
        var out = RunRecords()
        for (_, key) in DiagnosticsAllowlist.curtainCounts { out.curtainCounts[key] = 0 }
        guard let text else { return out }
        var summaries: [[String: Any]] = []
        var events: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                let any = try? JSONSerialization.jsonObject(with: data),
                let obj = any as? [String: Any],
                let event = obj["event"] as? String
            else { continue }
            if event == "summary" {
                summaries.append(obj)
            } else if event == "curtain" {
                let info = (obj["info"] as? String) ?? ""
                for (prefix, key) in DiagnosticsAllowlist.curtainCounts where info.hasPrefix(prefix) {
                    out.curtainCounts[key, default: 0] += 1
                    break
                }
            } else if DiagnosticsAllowlist.runEvents.contains(event) {
                events.append(obj)
            }
        }
        out.summaries = Array(summaries.suffix(DiagnosticsAllowlist.runSummaries))
        out.events = Array(events.suffix(DiagnosticsAllowlist.runEventRecords))
        return out
    }

    /// `launchctl print` output → three facts. `state = running`
    /// / `not running`, `pid = N`, `last exit code = N` (or `last exit reason
    /// = …`, kept as text). Anything else in the dump is dropped here. Only
    /// TOP-LEVEL lines count (indent exactly one tab): a real dump nests
    /// `state = active` inside `resource coalition = {}` / `jetsam coalition
    /// = {}` below the job's own `state = not running`, and "last wins"
    /// reported a stopped job as active (review 2026-09-09).
    static func launchdFacts(_ text: String) -> [String: Any] {
        var facts: [String: Any] = ["state": "unknown", "pid_present": false, "last_exit": NSNull()]
        for raw in text.split(separator: "\n") {
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("state = ") {
                facts["state"] = String(line.dropFirst("state = ".count))
            } else if line.hasPrefix("pid = ") {
                facts["pid_present"] = true
            } else if line.hasPrefix("last exit code = ") {
                let value = String(line.dropFirst("last exit code = ".count))
                facts["last_exit"] = Int(value.split(separator: " ").first ?? "") ?? value
            } else if line.hasPrefix("last exit reason = ") {
                facts["last_exit"] = String(line.dropFirst("last exit reason = ".count))
            }
        }
        return facts
    }
}
