import AppKit
import Foundation

// Scripted UI driver and --ui-demo fake state
// (§10.1). Enabled by SENTRY_UI_SCRIPT=<file>. The whole file is parsed
// before any UI appears; actions then run on the main thread as a chain of
// DispatchQueue.main continuations — never a busy wait, which would freeze
// the popover being tested.

// MARK: - Demo state

/// Fake state injected by `--ui-demo-state key=value` or a `state` script
/// line. Values are validated at parse time so a typo exits 64 before any
/// window appears.
struct DemoState: Equatable {
    enum Health: String { case starting, protecting, lost }
    enum Pin: String { case unset, set, locked }
    /// Remaining lockout for `pin locked` (default the real budget) or `locked:<secs>`.
    var lockSecs: TimeInterval = PinGate.lockoutSecs
    enum Policy: String { case standard, strict, pinnedStrict = "pinned:strict" }
    enum Paused: Equatable {
        case none, m15, h1, restart
        case until(Date)
    }

    var health = Health.protecting
    var paused = Paused.none
    var policy = Policy.standard
    var pin = Pin.set
    var activity = 3
    var admin = true
    /// Writes the LEGACY `showMenuBarIcon` into the demo's settings.json.
    /// Since 2026-10-20 nothing hides the icon, so `icon false` is the
    /// "older file says hide" case and the icon must still be there.
    var icon = true
    var devstate = false
    /// `diagnostics` key: the send status on the review layer (2026-10-20; it was under the review button).
    var sendNotice: DiagnosticsSendState? = nil
    /// `readout sample|empty`: fills the Developer
    /// tab's 60 s readout with injected detections and a curtain drop so a
    /// render shows the panel populated. Ignored by a production demo.
    var readoutSample = false
    /// `screenrecording off`: what CGPreflightScreenCaptureAccess reports in
    /// production (AppDelegate publishes it on every health change). Its own
    /// axis, not a `health` value, because it only picks which sentence the
    /// persistent capture row shows — the row itself exists for every lost
    /// cause. Default on: a demo run must not claim the grant is missing.
    var screenRecordingOff = false
    /// `detector ok|failing` (2026-09-11): the detector stopped
    /// answering while capture is healthy. Its own axis, not a `health` value,
    /// because the two compose (ProtectionHealth.compose) — and because a
    /// capture loss OUTRANKS it, which a script must be able to set up.
    var detectorFailing = false
    /// `displays <n>`: how many displays are connected. 1 = the
    /// single-display norm, which draws no warning; >1 draws the persistent
    /// scope row naming the one protected screen.
    var displays = 1
    /// Private demo projections of the production scope and resume acknowledgement.
    var displayConnected = true
    var resuming = false

    /// Display name a demo shows in the scope row. A FIXED string, never this
    /// Mac's real `NSScreen.localizedName`: a demo screenshot must carry no
    /// hardware detail from the machine it was shot on.
    static let demoDisplayName = "Built-in Retina Display"
    /// `displays <n>` accepts 1…this. DERIVED: macOS's own documented limit on
    /// the machines this app supports is well under it, and the row's copy only
    /// has two shapes (one other screen / N others), so a bigger number tests
    /// nothing new.
    static let maxDisplays = 8

    /// PIN a demo run sets when `pin` is `set`/`locked` — the value every
    /// E2E script types (spec §11 pause-15m.txt).
    static let demoPin = "4821"
    /// Activity rows the popover can show (spec §13 `UIActivity.rows`,
    /// OWNER): the `activity` key accepts 0…rows.
    static let maxActivity = 10

    /// nil on success, else the reason.
    mutating func set(_ key: String, _ value: String) -> String? {
        switch key {
        case "health":
            guard let h = Health(rawValue: value) else { return "health must be starting|protecting|lost" }
            health = h
        case "paused":
            switch value {
            case "none": paused = .none
            case "15m": paused = .m15
            case "1h": paused = .h1
            case "restart": paused = .restart
            default:
                // `until:+<seconds>` as well as an absolute ISO 8601: a
                // static E2E script cannot know the wall clock, and the
                // pause-expiry regression (status-pause-expiry.txt) needs a
                // deadline a few seconds out.
                guard value.hasPrefix("until:") else {
                    return "paused must be none|15m|1h|restart|until:<ISO 8601>|until:+<seconds>"
                }
                let arg = String(value.dropFirst("until:".count))
                if arg.hasPrefix("+"), let secs = Double(arg.dropFirst()), secs > 0 {
                    paused = .until(Date().addingTimeInterval(secs))
                } else if let d = UISettings.iso.date(from: arg) {
                    paused = .until(d)
                } else {
                    return "paused must be none|15m|1h|restart|until:<ISO 8601>|until:+<seconds>"
                }
            }
        case "policy":
            guard let p = Policy(rawValue: value) else { return "policy must be standard|strict|pinned:strict" }
            policy = p
        case "pin":
            // `locked:<secs>` models a lockout about to end (owner-found bug:
            // the countdown stalled at 0:01 after expiry).
            if value.hasPrefix("locked:") {
                guard let s = Double(value.dropFirst("locked:".count)), s > 0 else {
                    return "pin locked:<secs> needs a positive number"
                }
                pin = .locked; lockSecs = s
            } else {
                guard let p = Pin(rawValue: value) else { return "pin must be unset|set|locked|locked:<secs>" }
                pin = p
            }
        case "activity":
            guard let n = Int(value), (0...Self.maxActivity).contains(n) else {
                return "activity must be 0…\(Self.maxActivity)"
            }
            activity = n
        case "admin", "icon", "devstate":
            guard let b = Bool(value) else { return "\(key) must be true|false" }
            switch key {
            case "admin": admin = b
            case "icon": icon = b
            default: devstate = b
            }
        case "hotkey":
            // Refused by name, not as an unknown key: a script still passing
            // it was written for the removed hide-icon path.
            return "hotkey was removed 2026-10-20 with the reveal hotkey (the menu bar icon can no longer be hidden)"
        case "screenrecording":
            guard value == "on" || value == "off" else { return "screenrecording must be on|off" }
            screenRecordingOff = value == "off"
        case "detector":
            guard value == "ok" || value == "failing" else { return "detector must be ok|failing" }
            detectorFailing = value == "failing"
        case "displays":
            guard let n = Int(value), (1...Self.maxDisplays).contains(n) else {
                return "displays must be 1…\(Self.maxDisplays)"
            }
            displays = n
        case "displayconnected":
            guard value == "on" || value == "off" else { return "displayconnected must be on|off" }
            displayConnected = value == "on"
        case "resuming":
            guard value == "on" || value == "off" else { return "resuming must be on|off" }
            resuming = value == "on"
        case "diagnostics":
            // The send notice (DiagnosticsSendState); a demo has no agent,
            // so the states are set directly.
            switch value {
            case "none": sendNotice = nil
            case "sending": sendNotice = .sending
            case "sent": sendNotice = .sent(at: Int(Date().timeIntervalSince1970))
            case "refused": sendNotice = .failed(DiagnosticsCopy.refused(status: 400))
            case "unreachable": sendNotice = .failed(DiagnosticsCopy.unreachable)
            default: return "diagnostics must be none|sending|sent|refused|unreachable"
            }
        case "readout":
            guard value == "sample" || value == "empty" else { return "readout must be sample|empty" }
            readoutSample = value == "sample"
        default:
            return "unknown state key '\(key)' "
                + "(health|paused|policy|pin|activity|admin|icon|devstate|hotkey|screenrecording|detector|displays|displayconnected|resuming|diagnostics|readout)"
        }
        return nil
    }

    /// The public settings.json values this state implies. PIN material is
    /// produced separately by `parentPINState` and never enters this value.
    func settings(now: Date = Date()) -> UISettings {
        var s = UISettings.defaults
        switch paused {
        case .none: break
        case .m15: s.pause = timed(now, 15 * 60)
        case .h1: s.pause = timed(now, 60 * 60)
        case .until(let d): s.pause = timed(now, d.timeIntervalSince(now))
        case .restart:
            s.pause = .untilRestart(bootSession: BootSession.uuid ?? "demo", by: "demo", at: now)
        }
        switch policy {
        case .standard: s.policyOverride = nil
        case .strict: s.policyOverride = .strict
        // `pinned:strict` models a run started with `--policy strict`: the
        // FLAG is what pins it (UIState.policyPinned/basePolicy), so
        // settings.json carries no override — writing one here would test
        // the wrong precedence branch (spec §6).
        case .pinnedStrict: s.policyOverride = nil
        }
        s.showMenuBarIcon = icon
        return s
    }

    /// Protected authority values for the real PIN path used by UI demos.
    func parentPINState(now: Date = Date()) -> ParentPINState {
        var state = ParentPINState.empty
        if pin != .unset { state.pin = UIPin.make(Self.demoPin) }
        if pin == .locked {
            state.failures = PinFailures(
                count: PinGate.maxAttempts,
                lastAt: now,
                lockedUntil: now.addingTimeInterval(lockSecs))
        }
        return state
    }

    /// Fake apps for `activity N`, newest first, 3 min apart. Row 0 is
    /// Safari (spec §11 activity-10.txt asserts it). Names only — a demo
    /// screenshot must carry no personal content.
    static let demoApps = ["Safari", "Google Chrome", "Photos", "Messages", "Firefox",
        "Finder", "Preview", "Notes", "Mail", "Music"]

    func activityItems(now: Date = Date()) -> [ActivityItem] {
        (0..<activity).map { i in
            ActivityItem(app: Self.demoApps[i % Self.demoApps.count],
                at: now.addingTimeInterval(-Double(i + 1) * 180), uid: getuid())
        }
    }

    private func timed(_ now: Date, _ secs: TimeInterval) -> PauseState {
        .timed(until: now.addingTimeInterval(secs), untilUptime: BootSession.uptime() + secs,
            by: "demo", at: now)
    }

    var captureHealth: CaptureHealth {
        switch health {
        case .starting: return .starting
        case .protecting: return .protecting
        case .lost: return .lost(since: Self.lostSince, reason: "capture stream lost")
        }
    }

    /// Same frozen clock as `captureHealth`, so a demo screenshot is diffable.
    var detectorHealth: DetectorHealth {
        detectorFailing ? .failing(since: Self.lostSince) : .healthy
    }

    var displayScopeValue: DisplayScope {
        guard displays > 1 || !displayConnected else { return .single }
        return DisplayScope(
            displayCount: displays, protectedDisplayID: 1, protectedName: Self.demoDisplayName,
            protectedDisplayConnected: displayConnected)
    }

    /// Frozen "lost since" so the degraded screenshot is diffable across runs
    /// (spec §10.1: synthetic state is generated from a fixed base date, never
    /// from `Date()`). The reason string above is a real one — main.swift
    /// hook 2's — so a demo screenshot shows what the family would see.
    static let lostSince: Date = {
        var c = DateComponents()
        c.year = 2026
        c.month = 8
        c.day = 22
        c.hour = 14
        c.minute = 32
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }()
}

// MARK: - Script

enum UIAction: Equatable {
    case open, close
    case tap(String)
    case type(String, String)
    case wait(Int)
    case waitfor(String, Int)
    case waituntil(String, String, Int)
    case screenshot(String)
    case assert(String, String)
    case assertcontains(String, String)
    case assertmissing(String)
    case assertenabled(String, Bool)
    case state(String, String)
    case appearance(String)
    case textsize(String)
    case assertfits
    case scrollto(String)

}

/// `display` is the ONLY rendering of a script line, and the only thing a
/// log line or a failure message may echo. For `type` the argument is
/// redacted: a script may carry the parent PIN, and echoing the raw line
/// would put it into the queue result file. The raw text is deliberately not
/// kept on the line.
struct UIScriptLine {
    let number: Int
    let display: String
    let action: UIAction
}

/// What the driver needs from the app. Closures so the driver never owns UI.
struct UIDriverHost {
    enum OpenResult { case shown, notYet(String), failed(String) }
    let open: () -> OpenResult
    let close: () -> Void
    let isShown: () -> Bool
    let windowNumber: () -> Int
    let contentView: () -> NSView?
    let setState: (String, String) -> String?
    let setAppearance: (String) -> Void
    /// nil on success, else why the text size could not be applied. The scale
    /// is read when the surface is BUILT, so applying one to a popover that is
    /// already open would silently do nothing — the host refuses instead.
    let setTextSize: (String) -> String?
}

final class UIDriver {
    /// Exit codes (spec §10.2).
    enum Exit: Int32 {
        case usage = 64          // parse error: unknown action, arity, quoting
        case assertFailed = 70
        case waitforTimeout = 71
        case screenshotFailed = 72
        case globalTimeout = 73
    }

    /// Whole-script deadline unless SENTRY_UI_SCRIPT_TIMEOUT overrides.
    /// DERIVED: the longest planned script is 14 actions including one
    /// ~100 ms PBKDF2 derivation; 60 s is >40x that, so hitting it means a
    /// hang, not a slow step.
    static let defaultTimeoutSecs: TimeInterval = 60
    /// `waitfor` poll cadence. DERIVED: SwiftUI registers a control on the
    /// run-loop turn after the popover shows, so a 50 ms poll adds at most
    /// 50 ms to a wait and costs nothing while idle; finer would just burn
    /// the run loop a test is trying to observe.
    static let waitforPollMs = 50
    /// How long `open` retries before the status item's menu-bar window
    /// exists. MEASURED 2026-08-22 (an M1 Mac, 6 runs): shown after
    /// 81-227 ms. 2 s is a tripwire ~10x past that; hitting it means the
    /// item never landed (e.g. a menu bar with no room), which the failure
    /// text names.
    static let openTimeoutMs = 2000
    /// How long `close` waits for the popover's animated dismissal to
    /// complete (NSPopoverDelegate.popoverDidClose, which is what clears
    /// the registry). MEASURED 2026-08-22 (an M1 Mac, 9 closes across 3
    /// E2E runs): closed after 564-573 ms. 3 s is a tripwire ~5x past that;
    /// hitting it means the close never finished and any later assert would
    /// run on a phantom.
    static let closeTimeoutMs = 3000
    /// Smallest PNG a real popover capture may produce. Spec §10.2 floor;
    /// MEASURED 2026-08-22 (an M1 Mac): the slice-3 header-only popover
    /// (320 pt) captures at 11.9-18.4 KB, so 4 KB catches only "nothing was
    /// written" or a flat frame — which is what it exists for; the
    /// uniformity check below does the rest.
    static let minShotBytes = 4096
    /// Pixel-uniformity sample grid. DERIVED: 64x64 = 4,096 samples reads
    /// any visible text or glyph on a 320 pt popover while keeping the check
    /// sub-millisecond; a TCC-denied capture is uniform black everywhere.
    static let uniformGrid = 64
    /// `assertfits` containment slack. DERIVED: `UITypography.points` rounds a
    /// scaled metric to a whole point and SwiftUI lays out on half-points, so
    /// a control's frame can sit half a point past a container edge with
    /// nothing visibly clipped. Anything larger is a real overflow.
    static let fitTolerancePt: CGFloat = 0.5
    /// Named budget for the Settings fold check in `fitFailure`.
    static let foldBudget = "UIDriver.settingsFoldAtDefaultText"
    /// Lets one run keep a deliberate fold (a layout experiment, a page being
    /// measured on purpose).
    static var allowsSettingsFold: Bool {
        ProcessInfo.processInfo.environment["SENTRY_UI_ALLOW_FOLD"] == "1"
    }

    static var scriptPath: String? {
        DevEnv.knob("SENTRY_UI_SCRIPT")
    }

    /// Explicit headless-safe capture mode for app-owned synthetic demo UI.
    /// It renders only the live popover content view and cannot reach the
    /// desktop. Production and unspecified test runs keep window capture.
    static var usesAppOwnedCapture: Bool {
        DevEnv.knob("SENTRY_UI_CAPTURE") == "app-owned"
    }

    let path: String
    let lines: [UIScriptLine]
    private var host: UIDriverHost!
    private var shots = 0
    /// Every PNG this script wrote, in order — the queue's result file
    /// (UIScriptQueue) lists them so the harness can collect exactly those.
    private(set) var shotPaths: [String] = []
    private var lastLine: UIScriptLine?
    private let shotsDir: String
    /// Set by the queue: a script that ends (OK or failed) reports here
    /// instead of exiting the process. nil (the --ui-demo default) keeps the
    /// process-exit contract every ui-qa suite asserts on.
    var onFinish: ((_ code: Int32, _ message: String, _ shots: [String]) -> Void)?
    /// Capture mode for `screenshot`: app-owned render (the queue's only
    /// mode — the installed agent must never spawn screencapture) or the
    /// env-selected mode under --ui-demo.
    var appOwnedCapture = UIDriver.usesAppOwnedCapture
    /// Set once by `finish`; a late timeout or a continuation queued before
    /// a failure must not report twice or keep stepping.
    private var finished = false

    // MARK: Parse

    struct ParseError: Error, CustomStringConvertible {
        let line: Int
        let message: String
        var description: String { "line \(line): \(message)" }
    }

    /// Parses the whole file; any problem exits 64 before a window exists
    /// (call this before constructing any UI).
    static func load(path: String, isDemo: Bool) -> UIDriver {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            die("ui-script: cannot read \(path)", code: Exit.usage.rawValue)
        }
        do {
            return UIDriver(path: path, lines: try parse(text, isDemo: isDemo))
        } catch let error as ParseError {
            die("ui-script: \(error)", code: Exit.usage.rawValue)
        } catch {
            die("ui-script: \(error)", code: Exit.usage.rawValue)
        }
    }

    /// The parser behind `load`, throwing instead of dying so the queue can
    /// report a bad script through its result file (spec §3.3) while the
    /// process keeps running.
    static func parse(_ text: String, isDemo: Bool) throws -> [UIScriptLine] {
        var out: [UIScriptLine] = []
        var probe = DemoState()
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fail = { (msg: String) -> ParseError in ParseError(line: n, message: msg) }
            guard let args = tokenize(trimmed) else { throw fail("unbalanced quotes") }
            let action = args[0]
            let rest = Array(args.dropFirst())
            func arity(_ k: Int) throws {
                if rest.count != k { throw fail("'\(action)' takes \(k) argument\(k == 1 ? "" : "s"), got \(rest.count)") }
            }
            func int(_ s: String, _ what: String) throws -> Int {
                guard let v = Int(s), v >= 0 else { throw fail("\(what) must be a non-negative integer, got '\(s)'") }
                return v
            }
            let parsed: UIAction
            switch action {
            case "open": try arity(0); parsed = .open
            case "close": try arity(0); parsed = .close
            case "tap": try arity(1); parsed = .tap(rest[0])
            case "type": try arity(2); parsed = .type(rest[0], rest[1])
            case "wait": try arity(1); parsed = .wait(try int(rest[0], "ms"))
            case "waitfor": try arity(2); parsed = .waitfor(rest[0], try int(rest[1], "ms"))
            // `waitfor <id>` proves a control EXISTS; a value that arrives a
            // moment later (the license verdict repainting the header, a PIN
            // unlock landing) was asserted after a fixed `wait`, which is a
            // guess on both sides: too short flakes, too long wastes the run.
            // `waituntil <id> <text> <ms>` polls the same read() `assert`
            // uses until it matches exactly, and names expected/actual/last
            // read on timeout (exit 71).
            case "waituntil": try arity(3); parsed = .waituntil(rest[0], rest[1], try int(rest[2], "ms"))
            case "screenshot": try arity(1); parsed = .screenshot(rest[0])
            // The settings panel is taller than its viewport
            // (UIMetrics.settingsViewportMaxHeight), so the rows at the
            // bottom — the removal row, SPEC §8.1(7) — could be asserted but
            // never CAPTURED: every screenshot showed the top of the sheet.
            // `scrollto <id>` brings a section into view so the evidence is
            // of what a parent actually sees. Anchors on ids the views
            // publish (`.uiScrollAnchor`), which are the control ids.
            case "scrollto": try arity(1); parsed = .scrollto(rest[0])
            case "assert": try arity(2); parsed = .assert(rest[0], rest[1])
            case "assertcontains": try arity(2); parsed = .assertcontains(rest[0], rest[1])
            case "assertmissing": try arity(1); parsed = .assertmissing(rest[0])
            case "assertenabled":
                try arity(2)
                guard let b = Bool(rest[1]) else { throw fail("assertenabled wants true|false, got '\(rest[1])'") }
                parsed = .assertenabled(rest[0], b)
            case "state":
                try arity(2)
                if !isDemo { throw fail("'state' is only allowed under --ui-demo (refused on a live run)") }
                if let err = probe.set(rest[0], rest[1]) { throw fail(err) }
                parsed = .state(rest[0], rest[1])
            case "appearance":
                try arity(1)
                if !isDemo { throw fail("'appearance' is only allowed under --ui-demo (refused on a live run)") }
                guard UIAppearanceOption.names.contains(rest[0]) else {
                    throw fail("appearance wants \(UIAppearanceOption.acceptedValues), got '\(rest[0])'")
                }
                parsed = .appearance(rest[0])
            case "textsize":
                try arity(1)
                if !isDemo { throw fail("'textsize' is only allowed under --ui-demo (refused on a live run)") }
                guard UITextScale.named[rest[0]] != nil else {
                    throw fail("textsize wants \(UITextScale.acceptedValues), got '\(rest[0])'")
                }
                parsed = .textsize(rest[0])
            // Layout Tripwire for the larger text sizes: every registered
            // control must lie inside the popover surface. Takes no argument
            // — a clipping check that names one control is a check someone has
            // to remember to extend.
            case "assertfits": try arity(0); parsed = .assertfits
            default:
                throw fail("unknown action '\(action)'")
            }
            let display: String
            if case .type(let id, _) = parsed {
                // Never echo a typed value (mirror of UIOnboardingTestScript).
                display = "type \(id) <redacted>"
            } else {
                display = trimmed
            }
            out.append(UIScriptLine(number: n, display: display, action: parsed))
        }
        return out
    }

    /// Space-separated with "double quotes" for arguments containing
    /// spaces. nil on an unterminated quote.
    static func tokenize(_ s: String) -> [String]? {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var hasToken = false
        for ch in s {
            if inQuote {
                if ch == "\"" { inQuote = false } else { cur.append(ch) }
            } else if ch == "\"" {
                inQuote = true
                hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken { out.append(cur); cur = ""; hasToken = false }
            } else {
                cur.append(ch)
                hasToken = true
            }
        }
        if inQuote { return nil }
        if hasToken { out.append(cur) }
        return out.isEmpty ? nil : out
    }

    /// `shotsDir` nil ⇒ SENTRY_UI_SHOTS, else the script's directory (the
    /// --ui-demo contract). The queue passes its own shots/ directory.
    init(path: String, lines: [UIScriptLine], shotsDir: String? = nil) {
        self.path = path
        self.lines = lines
        self.shotsDir = shotsDir
            ?? DevEnv.knob("SENTRY_UI_SHOTS")
            ?? (path as NSString).deletingLastPathComponent
    }

    // MARK: Run

    func run(host: UIDriverHost) {
        self.host = host
        // Queue mode does not read env (spec §3.3): the tripwire is the
        // receipted default, whatever the launchd environment carries.
        let timeout = onFinish == nil
            ? (DevEnv.knob("SENTRY_UI_SCRIPT_TIMEOUT").flatMap(Double.init) ?? Self.defaultTimeoutSecs)
            : Self.defaultTimeoutSecs
        print("ui-script: \(path) (\(lines.count) actions, timeout \(Int(timeout))s)")
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
            let last = lastLine.map { "line \($0.number): \($0.display)" } ?? "(none)"
            fail(.globalTimeout, "global timeout \(Int(timeout))s (budget SENTRY_UI_SCRIPT_TIMEOUT) "
                + "— last action run: \(last)")
        }
        DispatchQueue.main.async { self.step(0) }
    }

    private func step(_ i: Int) {
        guard !finished else { return }
        guard i < lines.count else {
            let summary = "UI-SCRIPT OK (\(lines.count) actions, \(shots) screenshots)"
            print(summary)
            finish(0, summary)
            return
        }
        let line = lines[i]
        lastLine = line
        let next = { DispatchQueue.main.async { self.step(i + 1) } }
        let ok = { print("ui-script: [\(line.number)] \(line.display) OK") }
        switch line.action {
        case .open:
            // The status item gets its menu-bar window a few run-loop turns
            // after construction; retry until it is there.
            let deadline = DispatchTime.now() + .milliseconds(Self.openTimeoutMs)
            let started = DispatchTime.now()
            func attempt() {
                guard !finished else { return }
                let why: String
                switch host.open() {
                case .shown:
                    let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    print("ui-script: [\(line.number)] \(line.display) OK (shown after \(ms) ms)")
                    next()
                    return
                case .failed(let reason):
                    fail(.assertFailed, line, "cannot open popover: \(reason)")
                    return
                case .notYet(let reason):
                    why = reason
                }
                if DispatchTime.now() >= deadline {
                    fail(.assertFailed, line, "cannot open popover within \(Self.openTimeoutMs) ms "
                        + "(budget UIDriver.openTimeoutMs): \(why)")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.waitforPollMs), execute: attempt)
            }
            attempt()
        case .close:
            // Returning before the close completes would let the next
            // assert/tap pass on a control that is no longer on screen.
            host.close()
            let deadline = DispatchTime.now() + .milliseconds(Self.closeTimeoutMs)
            let started = DispatchTime.now()
            func poll() {
                guard !finished else { return }
                if !host.isShown() {
                    let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    print("ui-script: [\(line.number)] \(line.display) OK (closed after \(ms) ms)")
                    next()
                    return
                }
                if DispatchTime.now() >= deadline {
                    fail(.assertFailed, line, "popover still shown after \(Self.closeTimeoutMs) ms "
                        + "(budget UIDriver.closeTimeoutMs); registered: \(UIRegistry.shared.ids.sorted())")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.waitforPollMs), execute: poll)
            }
            poll()
        case .tap(let id):
            guard let c = need(id, line) else { return }
            guard c.enabled() else { fail(.assertFailed, line, "\(id) is disabled"); return }
            guard let act = c.activate else { fail(.assertFailed, line, "\(id) is not activatable (\(c.kind))"); return }
            act(); ok(); next()
        case .type(let id, let text):
            guard let c = need(id, line) else { return }
            guard c.enabled() else { fail(.assertFailed, line, "\(id) is disabled"); return }
            guard let set = c.setText else { fail(.assertFailed, line, "\(id) is not a text field (\(c.kind))"); return }
            set(text); ok(); next()
        case .wait(let ms):
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { ok(); next() }
        case .waitfor(let id, let ms):
            let deadline = DispatchTime.now() + .milliseconds(ms)
            func poll() {
                guard !finished else { return }
                if UIRegistry.shared.control(id) != nil { ok(); next(); return }
                if DispatchTime.now() >= deadline {
                    fail(.waitforTimeout, line, "\(id) not registered within \(ms) ms; "
                        + "registered: \(UIRegistry.shared.ids.sorted())")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.waitforPollMs), execute: poll)
            }
            poll()
        case .waituntil(let id, let want, let ms):
            let deadline = DispatchTime.now() + .milliseconds(ms)
            func poll() {
                guard !finished else { return }
                let got = UIRegistry.shared.control(id)?.read()
                if got == want { ok(); next(); return }
                if DispatchTime.now() >= deadline {
                    // Names which of the two failures it was: the control
                    // never registered, or it registered and kept reading
                    // something else (the value `assert` would have printed).
                    fail(.waitforTimeout, line, "\(id) did not read \"\(want)\" within \(ms) ms; "
                        + (got.map { "last read \"\($0)\"" }
                            ?? "not registered (registered: \(UIRegistry.shared.ids.sorted()))"))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.waitforPollMs), execute: poll)
            }
            poll()
        case .screenshot(let rel):
            guard screenshot(rel, line) else { return }
            shots += 1; ok(); next()
        case .assert(let id, let want):
            guard let c = need(id, line) else { return }
            let got = c.read()
            if got != want { fail(.assertFailed, line, expected: want, actual: got); return }
            ok(); next()
        case .assertcontains(let id, let want):
            guard let c = need(id, line) else { return }
            let got = c.read()
            if !got.contains(want) { fail(.assertFailed, line, expected: "…\(want)…", actual: got); return }
            ok(); next()
        case .assertmissing(let id):
            if UIRegistry.shared.control(id) != nil {
                fail(.assertFailed, line, expected: "\(id) not registered", actual: "registered")
                return
            }
            ok(); next()
        case .assertenabled(let id, let want):
            guard let c = need(id, line) else { return }
            let got = c.enabled()
            if got != want { fail(.assertFailed, line, expected: "enabled=\(want)", actual: "enabled=\(got)"); return }
            ok(); next()
        case .state(let k, let v):
            if let err = host.setState(k, v) { fail(.assertFailed, line, err); return }
            ok(); next()
        case .appearance(let a):
            host.setAppearance(a); ok(); next()
        case .textsize(let size):
            if let err = host.setTextSize(size) { fail(.assertFailed, line, err); return }
            ok(); next()
        case .assertfits:
            if let why = Self.fitFailure() { fail(.assertFailed, line, why); return }
            let probe = UILayoutProbe.shared
            let surfaceW = Int(probe.surface.width.rounded())
            let surfaceH = Int(probe.surface.height.rounded())
            let scroll = UIScrollAnchors.shared.proxy == nil ? "no scroll view" : "scroll view on screen"
            let textScale = UITextScale.describe(UITextScale.current)
            let frames = probe.frames.count
            let summary = "surface \(surfaceW)x\(surfaceH) pt, \(frames) control frames, "
                + "text \(textScale), \(scroll)\(Self.foldSummary())"
            print("ui-script: [\(line.number)] \(line.display) OK (\(summary))")
            next()
        case .scrollto(let id):
            guard UIScrollAnchors.shared.scroll(to: id) else {
                fail(.assertFailed, line, "no scrollable view is on screen with anchor '\(id)'; "
                    + "anchors: \(UIScrollAnchors.shared.anchors.sorted())")
                return
            }
            ok(); next()
        }
    }

    // MARK: assertfits

    /// nil when every registered control lies inside the popover surface and
    /// the surface itself is within `UIMetrics.popoverMaxHeight`; else the
    /// named budget, its configured value, what was observed, and where to
    /// fix it.
    ///
    /// Horizontal containment is checked always: the popover is a fixed 320 pt
    /// (spec §9.2), so a control wider than its surface at a larger text size
    /// is clipped with no way for a parent to reach it. Vertical containment
    /// is checked only when NO scroll view is on screen — inside the Settings
    /// viewport a control below the fold is reachable by scrolling, which is
    /// the whole point of that viewport, and calling it clipped would make the
    /// check lie. The line the driver prints says which mode ran.
    static func fitFailure() -> String? {
        let probe = UILayoutProbe.shared
        guard probe.surface.width > 0, probe.surface.height > 0 else {
            return "no popover surface was measured (open the popover first); "
                + "registered controls: \(UIRegistry.shared.ids.sorted())"
        }
        guard !probe.frames.isEmpty else {
            return "no control frames were measured for a \(Int(probe.surface.width))x"
                + "\(Int(probe.surface.height)) pt surface — the layout probe in "
                + "UIRegistry.UIControlModifier is not publishing"
        }
        let tolerance = fitTolerancePt
        let scrolls = UIScrollAnchors.shared.proxy != nil
        var offenders: [String] = []
        for (id, frame) in probe.frames.sorted(by: { $0.key < $1.key }) {
            var why: [String] = []
            // The Settings tabs must fit the content column, not merely the
            // outer popover. The four-tab macOS 27 control reached the right
            // edge while the previous surface-only check still passed.
            if id == "ui.settings.tab" {
                let inset = UIMetrics.popoverPadding
                if frame.minX < inset - tolerance || frame.maxX > probe.surface.width - inset + tolerance {
                    why.append("Settings tabs span \(pt(frame.minX))...\(pt(frame.maxX)); "
                        + "content bounds \(pt(inset))...\(pt(probe.surface.width - inset)); "
                        + "fix UISettingsPanelView.tabs")
                }
            }
            if frame.minX < -tolerance { why.append("left \(pt(frame.minX)) < 0") }
            if frame.maxX > probe.surface.width + tolerance {
                why.append("right \(pt(frame.maxX)) > \(pt(probe.surface.width))")
            }
            if !scrolls {
                if frame.minY < -tolerance { why.append("top \(pt(frame.minY)) < 0") }
                if frame.maxY > probe.surface.height + tolerance {
                    why.append("bottom \(pt(frame.maxY)) > \(pt(probe.surface.height))")
                }
            }
            if !why.isEmpty { offenders.append("\(id) (\(why.joined(separator: ", ")))") }
        }
        if !offenders.isEmpty {
            return "budget UIDriver.fitTolerancePt; configured \(pt(tolerance)) pt slack inside a "
                + "\(pt(probe.surface.width))x\(pt(probe.surface.height)) pt surface at text "
                + "\(UITextScale.describe(UITextScale.current)); observed "
                + "\(offenders.count) control(s) outside it: \(offenders.joined(separator: "; ")). "
                + "Fix the layout in the view that draws them (a fixed .frame(height:) that should "
                + "be .frame(minHeight:), or a Text without "
                + ".fixedSize(horizontal: false, vertical: true))"
        }
        // The Settings sheet's contract (owner 2026-09-06): at the DEFAULT
        // text size every control of the selected page is on screen without
        // scrolling. The viewport exists for the two larger accessibility
        // sizes, where a scaled page genuinely cannot fit — not as a place a
        // row can quietly end up.
        //
        // RECEIPT: the paged sheet was built BECAUSE a one-page sheet hid
        // Remove and Done below a 410 pt viewport with no scroll
        // cue, and the owner read a page ending at "Version" as work that had
        // not shipped (UISettingsSheet.UISettingsTab). A page that folds again
        // at the default size reproduces that failure, so it fails here by
        // name instead of going unnoticed.
        // The Developer page is EXEMPT: it is a wall of tuning
        // sliders for whoever is tuning the curtain, not a page a parent
        // reads, and it scrolls on purpose (UIDevTuning.swift). MEASURED
        // 2026-09-11: 1404-1718 pt against a 410 pt viewport. The page is
        // read from the same control a script reads, so the two cannot
        // disagree about which page is on screen.
        //
        // An OPEN disclosure is exempt too: "More settings" (OWNER 2026-09-28, two tabs;
        // Settings-General board: "Opening More settings scrolls, as the App
        // page does today"). Closed, its row names what is inside ("PIN, menu
        // bar icon, updates, remove"), so nothing is below a fold without a
        // cue, and the 0 pt rule still holds for the closed page.
        let selected = UIRegistry.shared.control("ui.settings.tab")?.read() ?? ""
        let disclosure = selected == "general" ? "ui.settings.more" : ""
        let moreOpen = UIRegistry.shared.control(disclosure)?.read() == "open"
        if UITextScale.current == UITextScale.standard,
            selected != "developer",
            !moreOpen,
            probe.scrollOverflow > tolerance,
            !allowsSettingsFold
        {
            return "budget \(foldBudget); configured 0 pt of fold on a parent Settings page at the "
                + "default text size; observed \(pt(probe.scrollOverflow)) pt of the "
                + "'\(selected)' page below a \(pt(probe.scrollViewport.height)) pt viewport "
                + "(page is \(pt(probe.scrollDocument.height)) pt). Fix: shorten that page, or move "
                + "a section to another page, in UISettingsSheet.UISettingsPanelView — then "
                + "re-measure the receipt on UIMetrics.settingsViewportMaxHeight. To keep a "
                + "deliberate fold for one run: SENTRY_UI_ALLOW_FOLD=1"
        }
        let cap = UIMetrics.popoverMaxHeight
        if probe.surface.height > cap {
            return "budget UIMetrics.popoverMaxHeight; configured \(pt(cap)) pt "
                + "(this screen's visibleFrame less UIMetrics.popoverScreenInset); observed "
                + "\(pt(probe.surface.height)) pt at text "
                + "\(UITextScale.describe(UITextScale.current)). Fix: move the overflowing section "
                + "into a scroll viewport in UIPopoverView, then re-measure the receipt"
        }
        return nil
    }

    /// The fold numbers for the `assertfits` OK line: nothing when no
    /// Settings viewport is on screen, else the page and viewport heights and
    /// how much of the page sits below the fold.
    static func foldSummary() -> String {
        let probe = UILayoutProbe.shared
        guard probe.scrollViewport.height > 0, probe.scrollDocument.height > 0 else { return "" }
        return ", page \(pt(probe.scrollDocument.height)) pt in a "
            + "\(pt(probe.scrollViewport.height)) pt viewport, fold \(pt(probe.scrollOverflow)) pt"
    }

    private static func pt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    /// nil after reporting the failure (the caller returns).
    private func need(_ id: String, _ line: UIScriptLine) -> UIControl? {
        guard let c = UIRegistry.shared.control(id) else {
            fail(.assertFailed, line, "\(id) is not registered (registered: "
                + "\(UIRegistry.shared.ids.sorted()))")
            return nil
        }
        return c
    }

    // MARK: Screenshot (shared personal desktop: popover window ONLY)

    /// false after reporting the failure (the caller returns).
    private func screenshot(_ rel: String, _ line: UIScriptLine) -> Bool {
        let out = rel.hasPrefix("/") ? rel : shotsDir + "/" + rel
        let win = host.windowNumber()
        // The only capture form in this process is -l<popover window>. No
        // window ⇒ refuse; there is deliberately no full-screen fallback.
        guard win > 0 else {
            fail(.screenshotFailed, line, "no popover window to capture (open it first); "
                + "full-screen capture is not a supported path")
            return false
        }
        try? FileManager.default.createDirectory(
            atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: out)
        if appOwnedCapture {
            guard renderView(to: out) else {
                fail(.screenshotFailed, line, "app-owned popover render failed: \(out) "
                    + "(mode SENTRY_UI_CAPTURE=app-owned)")
                return false
            }
            if let why = Self.verify(png: out) {
                fail(.screenshotFailed, line, "app-owned popover render verification failed: \(why)")
                return false
            }
            print("ui-script: WROTE APP-OWNED POPOVER RENDER \(out)")
            shotPaths.append(out)
            return true
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(win)", out]
        do { try p.run() } catch {
            fail(.screenshotFailed, line, "screencapture failed to launch: \(error)")
            return false
        }
        p.waitUntilExit()
        if let why = Self.verify(png: out) {
            let fallback = renderFallback(out)
            fail(.screenshotFailed, line, "\(why) — likely cause: Screen Recording permission for the "
                + "launching process (screencapture rc=\(p.terminationStatus) window=\(win)). "
                + (fallback.map { "Diagnostic VIEW RENDER (no vibrancy, NOT the requested artifact): \($0)" }
                    ?? "view-render fallback also failed"))
            return false
        }
        shotPaths.append(out)
        return true
    }

    /// nil if the file is a real, non-uniform image; else the reason. A
    /// TCC-denied screencapture writes nothing or a black frame, and a test
    /// that passes on garbage is worse than no test.
    static func verify(png path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? Int
        else { return "screenshot not written: \(path)" }
        guard size > minShotBytes else {
            return "screenshot \(path) is \(size) B ≤ UIDriver.minShotBytes (\(minShotBytes))"
        }
        guard let img = NSImage(contentsOfFile: path),
            let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return "screenshot \(path) does not decode as an image" }
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
            return "screenshot \(path): no pixel data"
        }
        let bpp = cg.bitsPerPixel / 8, bpr = cg.bytesPerRow
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, bpp >= 3 else { return "screenshot \(path): \(w)x\(h) \(cg.bitsPerPixel) bpp" }
        let n = uniformGrid
        var first: [UInt8]?
        for gy in 0..<n {
            for gx in 0..<n {
                let x = gx * (w - 1) / (n - 1), y = gy * (h - 1) / (n - 1)
                let o = y * bpr + x * bpp
                let px = [ptr[o], ptr[o + 1], ptr[o + 2]]
                if first == nil { first = px } else if first! != px { return nil }
            }
        }
        return "screenshot \(path) is uniformly one color (\(w)x\(h))"
    }

    /// Draws only the app-owned popover content view. This path cannot capture
    /// another app or any part of the desktop.
    private func renderView(to path: String) -> Bool {
        guard let view = host.contentView(),
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return false }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: png)
    }

    /// Diagnostic-only copy when requested window capture fails.
    private func renderFallback(_ out: String) -> String? {
        let path = out + ".viewrender.png"
        guard renderView(to: path) else { return nil }
        FileHandle.standardError.write(Data(
            "ui-script: WROTE VIEW RENDER \(path) — no vibrancy, not a screencapture; diagnostic only\n".utf8))
        return path
    }

    // MARK: Failure / finish

    /// The one exit: process exit under --ui-demo (the ui-qa contract), the
    /// queue's callback otherwise. Idempotent — the global-timeout timer and
    /// a continuation queued just before a failure both land here.
    private func finish(_ code: Int32, _ message: String) {
        guard !finished else { return }
        finished = true
        if let onFinish {
            onFinish(code, message, shotPaths)
        } else {
            exit(code)
        }
    }

    private func fail(_ code: Exit, _ line: UIScriptLine, _ reason: String) {
        let message = "UI-SCRIPT FAILED at line \(line.number): \(line.display)\n  reason:   \(reason)"
        FileHandle.standardError.write(Data((message + "\n  script:   \(path)\n\n").utf8))
        finish(code.rawValue, message)
    }

    private func fail(_ code: Exit, _ line: UIScriptLine, expected: String, actual: String) {
        let message = "UI-SCRIPT FAILED at line \(line.number): \(line.display)\n"
            + "  expected: \"\(expected)\"\n  actual:   \"\(actual)\""
        FileHandle.standardError.write(Data((message + "\n  script:   \(path)\n\n").utf8))
        finish(code.rawValue, message)
    }

    private func fail(_ code: Exit, _ reason: String) {
        let message = "UI-SCRIPT FAILED: \(reason)"
        FileHandle.standardError.write(Data((message + "\n  script:   \(path)\n").utf8))
        finish(code.rawValue, message)
    }
}

// MARK: - --ui-demo

/// `sentry-screen --ui-demo` (spec §10.1): the popover on fake state. No
/// capture, no model, no overlay, no panic hotkey. The state root is forced
/// to a fresh temp dir (main.swift, before the store exists) so a demo can
/// never read or clobber the family's real PIN.
final class UIDemoController {
    /// Default --ttl under --ui-demo. DERIVED: the E2E runner gives every
    /// script a fresh process and the driver's own 60 s timeout ends a hung
    /// script first; 120 s leaves an attended demo time to look, and still
    /// bounds a forgotten one.
    static let defaultTTL = 120

    private var demo: DemoState
    /// Last `appearance` action, re-applied whenever the status item is
    /// rebuilt (`state icon false` then true) so a script's appearance is
    /// not silently lost mid-run.
    private var appearance: NSAppearance?
    private let store: UISettingsStore
    let state: UIState
    private let actions: UIActions
    private let activity: UIActivity
    private var statusItem: UIStatusItem?

    init(initial: DemoState, log: @escaping (String, String) -> Void) {
        demo = initial
        store = UISettingsStore(log: log)
        state = UIState(
            settings: store.settings,
            hasParentPIN: store.parentPIN != nil,
            devStateRoot: initial.devstate,
            isAdmin: initial.admin)
        // The demo runs the real mutation path (spec §10.1): the same store,
        // the same PinGate, the same PBKDF2. Only the pipeline behind it is
        // absent, so a policy write lands in settings.json and stops there.
        actions = UIActions(store: store, log: log)
        actions.removalAllowed = { [weak state] in state?.isAdmin ?? false }
        // No real logs unless SENTRY_LOG_DIR says so (UIActivity.resolveRoot).
        activity = UIActivity(state: state, root: UIActivity.resolveRoot(demo: true))
        store.onChange = { [weak self] s in
            self?.state.settings = s
            self?.state.hasParentPIN = self?.store.parentPIN != nil
            // Production's UISettingsStore.onChange → AppDelegate.syncStatusItem:
            // the demo re-derives the item on every write too, or the slice's
            // own acceptance script asserts a path that exists only here
            // (spec §10.1: the real popover on fake state, not a mock).
            self?.syncItem()
        }
        // The demo runs the production tick too (spec §10.1: --ui-demo is the
        // real popover on fake state, not a mock). Without it a
        // `paused until:+N` demo state would expire silently and
        // status-pause-expiry.txt would prove nothing about the live path.
        store.onTick = { [weak self] in
            guard let self else { return }
            self.state.republishIfPauseChanged()
            // The demo has no AppDelegate poll: echo the file the way the
            // agent would, so the tab's "applied" stamp exercises the real
            // parser (TuningFile.read) on the real file the sliders wrote.
            if let t = self.devTuning {
                let sig = TuningFile.signature(stateRoot: self.store.root)
                if !TuningFile.sameSignature(sig, self.devTuningSignature) {
                    self.devTuningSignature = sig
                    t.noteOutcome(TuningFile.read(stateRoot: self.store.root, base: t.base))
                }
                t.tick()
            }
        }
        // The Developer tab on fake state (spec §10.1: the real sheet, the
        // real writer, the demo's own parent/ dir — 2770 with this
        // process's group, so 0660 + getegid() is the parent/ contract here).
        let devTuning = UIDevTuning(
            stateRoot: store.root, groupID: getegid(),
            base: TuningPolicy.defaults, baseSource: "defaults")
        self.devTuning = devTuning
        actions.devTuning = devTuning
        apply()
        store.startPolling()
    }

    private var devTuning: UIDevTuning?
    private var devTuningSignature: TuningFile.Signature?
    /// `state readout sample`: what a curtain-tripping screen feeds the
    /// readout in one frame, at the sizes the false-positive receipt names
    /// (`ClassRule.minBoxFraction`: 15–68 px boxes), plus one drop.
    private func applyReadout() {
        guard let t = devTuning else { return }
        t.readout.reset()
        guard demo.readoutSample else { t.tick(); return }
        let now = CFAbsoluteTimeGetCurrent()
        var policy = TuningPolicy.defaults
        policy.standard["MALE_GENITALIA_EXPOSED"]?.minBoxPt = 24
        // One staircase, so the sample shows what the readout's steps line is
        // FOR: the 324-pt BUTTOCKS box at 0.84 is cut by the ≥ 64 pt step,
        // and the frame still blocks (the covered boxes), so 12 boxes cut
        // empty 0 of 12 blocked frames — box ≠ frame ≠ drop, on screen.
        policy.standard["BUTTOCKS_EXPOSED"]?.thresholdSteps = [.init(minPt: 64, threshold: 0.9)]
        policy.coveredBeatsExposed = true
        let screen = CGSize(width: 1920, height: 1080)
        let raw = [
            Detection(label: "MALE_GENITALIA_EXPOSED", confidence: 0.62, box: CGRect(x: 0.40, y: 0.50, width: 0.009, height: 0.03)),
            Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.71, box: CGRect(x: 0.30, y: 0.30, width: 0.05, height: 0.08)),
            Detection(label: "FEMALE_BREAST_COVERED", confidence: 0.66, box: CGRect(x: 0.28, y: 0.28, width: 0.12, height: 0.16)),
            Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.84, box: CGRect(x: 0.55, y: 0.40, width: 0.20, height: 0.30)),
        ]
        let filtered = policy.filter(raw, mode: .strict, blockFaces: false, screen: screen)
        for i in 0..<12 {
            t.readout.record(
                raw: raw, filtered: filtered, tuning: policy, mode: .strict, blockFaces: false,
                screen: screen, now: now - Double(i))
        }
        t.readout.recordCurtain(action: "drop", windowID: 4242, app: "Safari", now: now - 3)
        t.tick(now: now)
    }

    /// nil on success, else the reason (a `state` line the parser accepted
    /// can still fail to write).
    func set(_ key: String, _ value: String) -> String? {
        var next = demo
        if let err = next.set(key, value) { return err }
        demo = next
        return apply()
    }

    @discardableResult
    private func apply() -> String? {
        state.captureHealth = demo.captureHealth
        state.screenRecordingOff = demo.health == .lost && demo.screenRecordingOff
        state.detectorHealth = demo.detectorHealth
        state.displayScope = demo.displayScopeValue
        state.pauseResumePending = demo.resuming
        state.devStateRoot = demo.devstate
        state.isAdmin = demo.admin
        // What the --policy flag would have pinned in a live run (spec §6);
        // production pushes these from Pipeline in AppDelegate.startPipeline.
        state.policyPinned = demo.policy == .pinnedStrict
        state.basePolicy = demo.policy == .pinnedStrict ? .strict : .standard
        state.setRecentEvents(demo.activityItems())
        actions.showDemoSendState(demo.sendNotice)
        applyReadout()
        var err: String?
        do {
            try store.parentPINAuthority.mutate { $0 = demo.parentPINState() }
            try store.mutate { $0 = demo.settings() }
            state.hasParentPIN = store.parentPIN != nil
        } catch {
            err = "demo state write failed: \(error)"
        }
        // Also on the error path: a failed write leaves the previous settings,
        // and the item must still match them.
        syncItem()
        return err
    }

    /// One owner for the demo's status item, the same predicate production
    /// uses (AppDelegate.syncStatusItem). Demo state decides the icon, not the
    /// real session (spec §10.1) — `admin false` exercises the no-icon path.
    /// The legacy `showMenuBarIcon` is ignored here as in production
    /// (2026-10-20), so `icon false` must leave the item in place.
    private func syncItem() {
        let want = state.isAdmin
        if want, statusItem == nil {
            statusItem = UIStatusItem(state: state, actions: actions, activity: activity)
            statusItem?.setAppearance(appearance)
        } else if !want, let item = statusItem {
            item.remove()
            statusItem = nil
        }
    }

    /// nil on success, else why (the script fails 70). Refuses while the
    /// popover is open: `UIStatusItem.open` reads `UITextScale.current` once,
    /// when it builds the hosting controller, so a mid-flight change would be
    /// a silent no-op and the script would prove nothing.
    func setTextSize(_ name: String) -> String? {
        guard let scale = UITextScale.named[name] else {
            return "textsize wants \(UITextScale.acceptedValues), got '\(name)'"
        }
        if statusItem?.isShown == true {
            return "textsize must come BEFORE open (budget: the popover reads "
                + "UITextScale.current once, in UIStatusItem.open); observed the popover already "
                + "shown. Fix: move the textsize line above `open`, or close and re-open"
        }
        UITextScale.current = scale
        return nil
    }

    func setAppearance(_ name: String) {
        appearance = UIAppearanceOption.appearance(name)
        NSApp.appearance = appearance
        // NSApp.appearance alone does NOT reach the popover. MEASURED
        // 2026-08-22 (system in Dark): `appearance light` left the popover
        // dark — its window inherits from the status-item (menu bar) window,
        // not from NSApp — so light-mode.png and dark-mode.png came out
        // byte-similar and the light path was never actually exercised.
        statusItem?.setAppearance(appearance)
    }

    var driverHost: UIDriverHost {
        UIDriverHost(
            open: { [self] in
                guard let item = statusItem else {
                    return .failed("no status item (demo admin=\(demo.admin) icon=\(demo.icon))")
                }
                return item.open().map { .notYet($0) } ?? .shown
            },
            close: { [self] in statusItem?.close() },
            isShown: { [self] in statusItem?.isShown ?? false },
            windowNumber: { [self] in statusItem?.windowNumber ?? 0 },
            contentView: { [self] in statusItem?.contentView },
            setState: { [self] k, v in set(k, v) },
            setAppearance: { [self] a in setAppearance(a) },
            setTextSize: { [self] s in setTextSize(s) })
    }
}
