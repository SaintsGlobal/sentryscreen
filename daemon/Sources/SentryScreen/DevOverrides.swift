import Foundation

// Developer limit overrides: every limit that can block iterative testing
// has a bypass, and development never waits on a budget.
//
// ONE file, `<state>/dev-overrides.json`, read once at start by the agent
// (main.swift startSettings). Malformed ⇒ refused by name, nothing applied:
// a half-read file would be a limit nobody can see.
//
// Schema (v1; every key optional, unknown keys refused):
//   { "version": 1,
//     "log":         { "mode": "full" | "lean" },
//     "detector":    { "hangS": N } }
//
// `log.mode` replaces config.json's `logMode` (an installed config.json is
// root-owned; on a test Mac `sudo` asks for a password, so a developer could
// not switch the installed agent to full-fidelity records without this).
// Applied where the Pipeline's FrameLogger is built (main.swift
// startPipeline), so it is read before the first frame record.
struct DevOverrides: Equatable {
    static let fileName = "dev-overrides.json"
    /// The log event of every line this file produces.
    static let event = "dev-override"
    static let version = 1

    static let topKeys: Set<String> = ["version", "log", "detector"]
    static let logKeys: Set<String> = ["mode"]
    static let logModes: Set<String> = ["full", "lean"]
    static let detectorKeys: Set<String> = ["hangS"]

    /// `log.mode`: the FrameLogger fidelity (LogMode, Logger.swift) in place
    /// of config.json's `logMode`. The agent alone consumes it.
    var logMode: LogMode?
    /// `detector.hangS`: the first `detector.detect` call of this agent run
    /// sleeps this many seconds (`DetectorWatch.injectedHangSecs`, the same
    /// one-shot as `SENTRY_FAKE_DETECTOR_HANG`). The environment knob cannot
    /// reach an INSTALLED agent (agent-launch.sh launches it through `env -i`,
    /// tripwire ENV_SCRUB), so this file is the only way to drive the
    /// DetectDeadline stall on an installed build.
    /// Every agent start re-reads the file, so each start hangs once until
    /// the file is removed.
    var detectorHangS: Int?

    enum Outcome: Equatable {
        case absent
        case refused(String)
        case loaded(DevOverrides)
    }

    static func read(stateRoot: String) -> Outcome {
        let path = stateRoot + "/" + fileName
        guard let data = FileManager.default.contents(atPath: path) else { return .absent }
        switch parse(data) {
        case let .success(o): return .loaded(o)
        case let .failure(why): return .refused("\(path): \(why.text)")
        }
    }

    struct ParseError: Error, Equatable { let text: String }

    /// JSONSerialization hands back NSNumber for `true`, `1` and `0` alike,
    /// and `0 as? Bool` succeeds — so `0` for a seconds field would read as
    /// a bool and `1` for a bool as a number. Only a CFBoolean is a bool.
    static func isJSONBool(_ raw: Any) -> Bool {
        guard let n = raw as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func parse(_ data: Data) -> Result<DevOverrides, ParseError> {
        guard let any = try? JSONSerialization.jsonObject(with: data), let obj = any as? [String: Any] else {
            return .failure(ParseError(text: "not a JSON object"))
        }
        guard let v = obj["version"], !isJSONBool(v), v as? Int == version else {
            return .failure(ParseError(text: "version must be \(version) (got \(obj["version"] ?? "absent"))"))
        }
        if let unknown = obj.keys.first(where: { !topKeys.contains($0) }) {
            return .failure(ParseError(text: "unknown key \"\(unknown)\" (known: \(topKeys.sorted().joined(separator: ", ")))"))
        }
        var o = DevOverrides()
        func section(_ name: String, _ keys: Set<String>) -> Result<[String: Any], ParseError> {
            guard let raw = obj[name] else { return .success([:]) }
            guard let d = raw as? [String: Any] else { return .failure(ParseError(text: "\"\(name)\" must be an object")) }
            if let unknown = d.keys.first(where: { !keys.contains($0) }) {
                return .failure(ParseError(text: "unknown key \"\(name).\(unknown)\" (known: \(keys.sorted().joined(separator: ", ")))"))
            }
            return .success(d)
        }
        func int(_ d: [String: Any], _ section: String, _ key: String, min: Int) -> Result<Int?, ParseError> {
            guard let raw = d[key] else { return .success(nil) }
            // JSONSerialization decodes a JSON `true` as NSNumber too; refuse it.
            guard let n = raw as? Int, !isJSONBool(raw), n >= min else {
                return .failure(ParseError(text: "\"\(section).\(key)\" must be an integer >= \(min) (got \(raw))"))
            }
            return .success(n)
        }
        do {
            let l = try section("log", logKeys).get()
            if let raw = l["mode"] {
                guard let s = raw as? String, logModes.contains(s), let mode = LogMode(rawValue: s) else {
                    return .failure(ParseError(text: "\"log.mode\" must be one of \(logModes.sorted().joined(separator: ", ")) (got \(raw))"))
                }
                o.logMode = mode
            }
            let dt = try section("detector", detectorKeys).get()
            o.detectorHangS = try int(dt, "detector", "hangS", min: 1).get()
        } catch let e as ParseError {
            return .failure(e)
        } catch {
            return .failure(ParseError(text: "\(error)"))
        }
        return .success(o)
    }

    /// `key=value (default D)` for every override the file sets — one log
    /// line each at start, and the report's `app.dev_overrides`.
    var active: [(key: String, value: String, `default`: String)] {
        var out: [(String, String, String)] = []
        if let m = logMode { out.append(("log.mode", m.rawValue, "\(LogMode.full.rawValue), or config.json logMode")) }
        if let n = detectorHangS { out.append(("detector.hangS", "\(n)", "0, no injected hang")) }
        return out.map { (key: $0.0, value: $0.1, default: $0.2) }
    }

    /// What a diagnostic report carries (`app.dev_overrides`), so a report
    /// from a bypassed Mac is recognisable at a glance.
    var reportObject: [String: String] {
        Dictionary(uniqueKeysWithValues: active.map { ($0.key, $0.value) })
    }

    /// Reads the file, logs the outcome (one `dev-override` line per active
    /// override; one REFUSED line for a malformed file; nothing when absent)
    /// and returns the overrides to apply — `nil` for absent or refused.
    static func load(stateRoot: String, log: (String, String) -> Void) -> DevOverrides? {
        switch read(stateRoot: stateRoot) {
        case .absent:
            return nil
        case let .refused(why):
            log(event, "REFUSED \(why) — no overrides applied (fix: correct the file, or remove it)")
            return nil
        case let .loaded(o):
            let path = stateRoot + "/" + fileName
            if o.active.isEmpty {
                log(event, "\(path) sets no overrides (defaults in effect)")
            }
            for a in o.active {
                log(event, "\(a.key)=\(a.value) (default \(a.default)) file=\(path) — a diagnostic report carries app.dev_overrides")
            }
            return o
        }
    }
}
