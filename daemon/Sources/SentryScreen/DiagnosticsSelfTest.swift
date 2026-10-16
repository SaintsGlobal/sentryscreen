import Foundation

// `--ui-selftest` — diagnostic reports (docs/diagnostics.md): the redaction
// table against daemon/testdata/diagnostics/redaction.json; the allowlists and the
// actor/role replacement against the log fixtures; the size cap's named
// truncation. Nothing here touches the network.

extension UISelfTest {
    static func caseDiagnostics(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let fixtures = fixture("daemon/testdata/diagnostics") else { return }
        let fm = FileManager.default

        // 1. Redaction table.
        let cases = try! JSONSerialization.jsonObject(with: fm.contents(atPath: fixtures + "/redaction.json")!) as! [[String: String]]
        for c in cases {
            let got = DiagnosticsRedaction.redact(c["in"]!)
            check("diagnostics: redact \(c["in"]!.prefix(40))…", got == c["out"]!, "got \(got)")
        }
        // Tripwire: the table must stay linear on a long run of word
        // characters. MEASURED 2026-09-10: 12 ms per rule after the run-head
        // guards; the unguarded rules were quadratic (minutes). 2 s is ~100×.
        let runStart = Date()
        _ = DiagnosticsRedaction.redact(String(repeating: "y", count: 100_000))
        let runS = Date().timeIntervalSince(runStart)
        check("diagnostics: redact stays linear on a 100 K word-character run (< 2 s)", runS < 2, String(format: "took %.2f s", runS))
        let nested = DiagnosticsRedaction.redact(json: ["a": ["parent(501)", ["k": "x@y.io"]], "/Users/parent": 1]) as! [String: Any]
        check("diagnostics: redact(json:) walks arrays, objects and keys",
            (nested["a"] as? [Any])?.first as? String == "user(501)"
                && ((nested["a"] as? [Any])?.last as? [String: String])?["k"] == "<email>"
                && nested["/Users/…"] as? Int == 1, "\(nested)")

        // 2. A report from the fixture logs.
        let root = dir + "/state"
        let logDir = dir + "/logs"
        let support = dir + "/support"
        let crashDir = dir + "/crashes"
        for d in [root, logDir, support, crashDir] { try! fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        for name in ["agent.err", "run.jsonl", "alerts.log"] { try! fm.copyItem(atPath: fixtures + "/" + name, toPath: logDir + "/" + name) }
        for name in ["build-metadata.tsv", "model-identity.tsv"] { try! fm.copyItem(atPath: fixtures + "/" + name, toPath: support + "/" + name) }
        try! fm.copyItem(atPath: fixtures + "/settings.json", toPath: root + "/settings.json")
        try! fm.copyItem(atPath: fixtures + "/sentry-screen-2026-09-03-062514.ips", toPath: crashDir + "/sentry-screen-2026-09-03-062514.ips")
        let launchctlAgent = try! String(contentsOfFile: fixtures + "/launchctl-agent.txt", encoding: .utf8)
        var sources = DiagnosticsSources(supportDir: support, logDir: logDir, crashReportsDir: crashDir, settingsPath: root + "/settings.json")
        sources.launchctl = { $0.hasSuffix("com.sentryscreen.agent") ? launchctlAgent : nil }
        sources.isAdminUID = { $0 == 501 }
        let clock = 1_757_500_000
        let report = DiagnosticsReport.build(sources.gather(now: clock, uid: getuid(), isAdmin: true))
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)

        check("diagnostics: report v=1 reason=manual created_at=now", report["v"] as? Int == 1 && report["reason"] as? String == "manual" && report["created_at"] as? Int == clock)
        let app = report["app"] as? [String: Any]
        check("diagnostics: app from build-metadata.tsv", app?["version"] as? String == "0.3.0" && app?["build"] as? String == "7", "\(String(describing: app))")
        check("diagnostics: model from model-identity.tsv", (report["model"] as? [String: String])?["model_id"] == "yolox-s-v8-ep50-fp16")
        let session = report["session"] as? [String: Any]
        check("diagnostics: session carries uid/is_admin/console flag and never a name",
            session?["uid"] as? Int == Int(getuid()) && session?["is_admin"] as? Bool == true && session?["console_user_present"] is Bool && session?.count == 3)
        let settings = report["settings"] as? [String: Any]
        check("diagnostics: settings updatedBy → role, unlisted keys dropped",
            settings?["updatedBy"] as? String == "admin" && settings?["retiredState"] == nil && settings?["unknownState"] == nil, "\(String(describing: settings))")
        check("diagnostics: settings never carries the retired pin fields", {
            let o = DiagnosticsReport.settingsObject(Data("{\"version\":2,\"pin\":{\"hash\":\"abc\"},\"pinFailures\":3}".utf8), isAdminUID: { _ in true })
            return o["pin"] == nil && o["pinFailures"] == nil && o["version"] as? Int == 2
        }())
        let launchd = report["launchd"] as? [String: [String: Any]]
        let agentJob = launchd?["com.sentryscreen.agent"]
        check("diagnostics: launchd has the two labels", launchd?.count == 2, "\(String(describing: launchd?.keys.sorted()))")
        check("diagnostics: launchctl output → state/pid_present/last_exit only",
            agentJob?["state"] as? String == "running" && agentJob?["pid_present"] as? Bool == true && agentJob?["last_exit"] as? Int == 7 && agentJob?.count == 3, "\(String(describing: agentJob))")
        check("diagnostics: alerts_log is the alerts.log tail", (report["alerts_log"] as? [String])?.count == 2)
        let err = report["agent_err"] as? [String] ?? []
        check("diagnostics: agent_err keeps allowlisted prefixes only",
            !err.isEmpty && err.allSatisfy { DiagnosticsAllowlist.agentErrPrefixes.contains(DiagnosticsAllowlist.agentErrPrefix($0)) })
        let events = Set((report["run_events"] as? [[String: Any]] ?? []).compactMap { $0["event"] as? String })
        check("diagnostics: run_events are allowlisted events only", !events.isEmpty && events.isSubset(of: DiagnosticsAllowlist.runEvents), "\(events)")
        check("diagnostics: curtain records counted, lines absent",
            (report["curtain_counts"] as? [String: Int])?["drop"] == 2 && !text.contains("28331") && !text.contains("Safari"))
        check("diagnostics: the newest crash log is included", (report["crash"] as? [String: Any])?["file"] as? String == "sentry-screen-2026-09-03-062514.ips")
        check("diagnostics: no username, e-mail, key or home path anywhere",
            !text.contains("parent(") && !text.contains("@") && !text.contains("TKN-") && !text.contains("/Users/p"), String(text.prefix(300)))
        check("diagnostics: no detection class or box reaches the report", !text.contains("EXPOSED") && !text.contains("box="))

        // 3. Size cap: the largest section is halved and named.
        var big = sources.gather(now: clock, uid: 501, isAdmin: true)
        big.agentErr = Array(repeating: "onboarding: " + String(repeating: "x", count: 2_000), count: 300).joined(separator: "\n")
        big.crash = ("sentry-screen-big.ips", String(repeating: "y", count: 100_000))
        let (capped, final) = try! DiagnosticsReport.encode(DiagnosticsReport.build(big))
        let truncated = final["truncated"] as? [String] ?? []
        check("diagnostics: oversize report truncated under \(DiagnosticsReport.maxReportBytes) B, agent_err named first",
            capped.count <= DiagnosticsReport.maxReportBytes && truncated.first == "agent_err", "bytes=\(capped.count) truncated=\(truncated)")
        check("diagnostics: a report under the cap carries no truncated key", (try! DiagnosticsReport.encode(report)).report["truncated"] == nil)

        // 4. Actor role helper.
        check("diagnostics: actorRole admin/standard/unknown",
            DiagnosticsReport.actorRole("parent(501)", isAdminUID: { $0 == 501 }) == "admin"
                && DiagnosticsReport.actorRole("kid(502)", isAdminUID: { $0 == 501 }) == "standard"
                && DiagnosticsReport.actorRole("uid 502", isAdminUID: { _ in true }) == "unknown")
    }
}

// `--ui-selftest` — dev overrides (DevOverrides.swift): absent ⇒ nil,
// malformed ⇒ refused by name with nothing applied, applied ⇒ one line each.
extension UISelfTest {
    static func caseDevOverrides(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var logs: [String] = []
        let log: (String, String) -> Void = { logs.append("\($0): \($1)") }
        let path = dir + "/" + DevOverrides.fileName
        func write(_ text: String) { try! text.write(toFile: path, atomically: true, encoding: .utf8) }

        check("dev-overrides: absent file ⇒ nil, no log line",
            DevOverrides.load(stateRoot: dir, log: log) == nil && logs.isEmpty, "\(logs)")

        let bad: [(String, String)] = [
            ("{not json", "not a JSON object"),
            ("[1,2]", "not a JSON object"),
            ("{\"version\":2}", "version must be 1"),
            ("{\"version\":true}", "version must be 1"),
            ("{\"version\":1,\"diagnostics\":{}}", "unknown key \"diagnostics\""),
            ("{\"version\":1,\"log\":{\"mode\":\"verbose\"}}", "\"log.mode\" must be one of full, lean"),
            ("{\"version\":1,\"log\":{\"level\":\"full\"}}", "unknown key \"log.level\""),
            ("{\"version\":1,\"log\":\"full\"}", "\"log\" must be an object"),
            ("{\"version\":1,\"detector\":{\"hangS\":0}}", "\"detector.hangS\" must be an integer >= 1"),
            ("{\"version\":1,\"detector\":{\"hangS\":true}}", "\"detector.hangS\" must be an integer >= 1"),
        ]
        for (text, why) in bad {
            logs.removeAll()
            write(text)
            let got = DevOverrides.load(stateRoot: dir, log: log)
            check("dev-overrides: malformed \(text.prefix(40)) ⇒ refused by name",
                got == nil && logs.count == 1 && logs[0].hasPrefix("dev-override: REFUSED \(path): \(why)")
                    && logs[0].contains("no overrides applied"), "\(logs)")
        }

        logs.removeAll()
        write("{\"version\":1}")
        let empty = DevOverrides.load(stateRoot: dir, log: log)
        check("dev-overrides: {version:1} ⇒ loaded, no active overrides, one line",
            empty != nil && empty!.active.isEmpty && logs.count == 1 && logs[0].contains("sets no overrides"), "\(logs)")

        for mode in [LogMode.full, LogMode.lean] {
            logs.removeAll()
            write("{\"version\":1,\"log\":{\"mode\":\"\(mode.rawValue)\"}}")
            let l = DevOverrides.load(stateRoot: dir, log: log)
            check("dev-overrides: log.mode=\(mode.rawValue) loads, one line naming key/value/default",
                l?.logMode == mode && l?.active.count == 1 && logs.count == 1
                    && logs[0].hasPrefix("dev-override: log.mode=\(mode.rawValue) (default full")
                    && l?.reportObject == ["log.mode": mode.rawValue], "\(String(describing: l)) \(logs)")
        }

        logs.removeAll()
        write("{\"version\":1,\"detector\":{\"hangS\":45}}")
        let h = DevOverrides.load(stateRoot: dir, log: log)
        check("dev-overrides: detector.hangS=45 loads, one line naming key/value/default",
            h?.detectorHangS == 45 && h?.logMode == nil && h?.active.count == 1
                && logs.count == 1 && logs[0].hasPrefix("dev-override: detector.hangS=45 (default 0, no injected hang)")
                && h?.reportObject == ["detector.hangS": "45"], "\(String(describing: h)) \(logs)")
    }
}
