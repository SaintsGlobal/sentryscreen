import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreVideo
import Foundation

if ["--uninstall-clean-home", "--uninstall-clean-cache"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    exit(UninstallFileOps.rootCommand(Array(CommandLine.arguments.dropFirst())))
}

// The signed nested app is opened through LaunchServices, not agent-launch.sh.
// Dispatch before any capture, licence, settings, or onboarding initialization.
if Bundle.main.bundleIdentifier == "com.sentryscreen.uninstaller" {
    UninstallWorker.run()
    exit(0)
}

// SentryScreen Milestone 2: capture -> detect -> track -> overlay.
//
// Usage:
//   sentry-screen --model <path.mlpackage> [--fps 30] [--width 1280]
//                 [--conf 0.25] [--ttl 300] [--log frames.jsonl]
//                 [--log-mode full|lean] [--quiet]
//                 [--clear-frames N] [--block-faces] [--no-overlays]
//                 [--cover region|media|curtain] [--media-hold 5.0]
//                 [--policy strict|standard] [--curtain-strip 80]
//                 [--window-track on|off] [--display <CGDirectDisplayID>]
//                 [--capture-loss exit|banner] [--config <path.json>]
//                 [--dev-crop-dir <dir>]
//   sentry-screen --hotkey-test          (no capture; verifies the panic hotkey hold)
//   sentry-screen --ui-demo [--ui-demo-state key=value]...
//                                        (parent popover on fake state; no capture)
//   sentry-screen --ui-onboarding-demo <scenario>
//                                        (setup window on fake state; no capture)
//   sentry-screen --onboarding-selftest  (domain tests; no UI or capture)
//   sentry-screen --probe                (machine diagnostic + the perf tier it
//                                        WOULD choose; changes nothing)
//   sentry-screen --probe-selftest       (tier-rule + pipeline invariants)
//   sentry-screen --resilience-selftest  (compiled-model cache recovery + startup
//                                        log roll; no weights, no UI, no capture)
//   sentry-screen --print-tuning [--config <path.json>]
//                                        (effective TuningPolicy as JSON; exit 0)
//   sentry-screen --process <video> --log out.jsonl [--cover media]
//                                        (headless pixel replay; no window)
//
// Hotkeys (SPEC §8): Cmd+Opt+Ctrl+X held 1 s = panic (administrator password, then clear overlays, pause 5 min),
//                    Cmd+Opt+Ctrl+I = inject fake detection boxes for 3 s (only with --dev-inject).
//                    A registration failure never exits: it logs a named
//                    "hotkey" event (+ an alerts.log line for the panic key).

/// What a blocked detection paints. `region` (default) covers the detected
/// box only; `media` covers the whole continuously-changing area it sits in
/// (SPEC §5.5); `curtain` escalates to one window-anchored cover over the
/// whole flagged window (Curtain.swift), with region covers as the first
/// response underneath (on the second consecutive detector frame since
/// 2026-09-02 — receipt at `Tracker.curtainEntryFrames`).
enum CoverMode: String {
    case region
    case media
    case curtain
}

struct Options {
    var model = ""
    // Receipt:
    // 30 fps achieved
    // 28.2 fps at 18.6% avg / 22.5% max CPU (ps 2 s sampling), infer p50
    // 16.9 ms / p95 23.0 ms — both under the 33.3 ms interval, so the
    // detector keeps up; the ~5% fps shortfall is capture/timer-side and
    // identical at 20 fps. Cuts the sampling-latency floor 50 → 33 ms vs
    // 20 fps. SPEC §6 CPU budget renegotiated 15% → 25% of one core under
    // sustained motion on this receipt. 60 fps would NOT fit (16.7 ms
    // interval < infer p50).
    // 2026-09-02: this is now the DEFAULT TIER's fps rather than a hard-coded
    // launch value. `PerfTier.resolve` picks a tier at startup and writes its
    // fps here unless `--fps`/`config.json fps` set one explicitly, in which
    // case the explicit value wins and the startup record says so. On every
    // machine with a reachable Neural Engine the tier is `default` and this
    // stays exactly 30 — which is what keeps the gate byte-identical.
    var fps = 30
    /// True when `--fps` or `config.json`'s `fps` named a value. An explicit
    /// number must beat the tier: the tier is a fallback for machines nobody
    /// configured, never an override of someone who did.
    var fpsExplicit = false
    /// `--tier default|no-ane` / `config.json` `tier`. Forces a tier instead of
    /// detecting one — the only way a fixture run or a test can exercise the
    /// no-ane tier on a machine that has an ANE. nil = detect (production).
    var tierOverride: PerfTier.TierName?
    /// Resolved at the end of `parse()` and carried so the `startup` record can
    /// state which tier ran, why, and what the ANE query answered — a tier that
    /// nothing logs is a tier nobody can debug.
    var tier = PerfTier.standard
    var ane = PerfTier.ANE.present
    var tierWhy = ""
    var width = 1280  // SPEC §5.1 downscale target
    var conf: Float = 0.25  // detector floor; block decisions in Policy
    var ttl = 300  // dev dead-man switch, SPEC §8.1(3); 0 = run forever
    /// Upper bound on `--ttl` / config `ttl`, in seconds. 0 stays special,
    /// so the accepted set is {0} ∪ 1...ttlMaxSecs and everything else
    /// exits 64 by name (2026-09-11: `Int(v) ?? opts.ttl` used
    /// to swallow `--ttl banana` and run with the default as if it had been
    /// asked for, and a negative value silently disarmed the switch).
    ///
    /// Receipt: DERIVED, not measured. The longest BOUNDED run this repo has
    /// actually started is the 8 h overnight soak, `--cover curtain --ttl
    /// 28800`, so the honest margin is 3x the longest bounded run, not two
    /// orders of magnitude. This is a typo tripwire, not a
    /// working limit: 86,401 in a seconds field is a mistyped millisecond
    /// value, and a genuinely longer attended run is what `--ttl 0` is for. If
    /// a real run needs a BOUNDED TTL past a day, re-measure against it and
    /// raise this with that run named — do not raise it to get past the error.
    static let ttlMaxSecs = 86_400
    // Hysteresis N, SPEC §5.4. Default derives from fps (receipt at
    // Tracker.defaultClearAfter); --clear-frames overrides for testing.
    var clearFramesOverride: Int?
    /// `--exclude-windows id,...`: extra CGWindowIDs the capture excludes
    /// (Capture.extraExcluded — shielded harness only, never a user setting).
    var excludeWindows: [Int] = []
    var clearFrames: Int { clearFramesOverride ?? Tracker.defaultClearAfter(fps: fps) }
    var logPath: String?
    // Per-frame logging fidelity (LogMode in Logger.swift). `full` is the
    // default and must stay the default.
    // `lean` is opt-in for 24/7 production runs, where per-frame records for
    // clean frames are the whole disk bill.
    var logMode = LogMode.full
    // Silence the per-detection stdout line (2026-08-21: it fires up
    // to fps times/sec with any detection on screen and, under a launchd
    // plist that redirects stdout to a file, becomes a second unbounded log
    // additive to --log; the 60 s `-- summary:` line still prints). For
    // 24/7 runs pair with --log-mode lean.
    var quiet = false
    // C1 (milestone-3-plan.md): what capture loss does to the PROCESS.
    // `exit` (default) preserves dev behavior — missing permission at launch
    // exits 3, an exhausted re-arm budget exits 2, and --ttl plus the
    // operator are the recovery. `banner` is for the launchd agent: the
    // process stays up, shows the "parent needed" capture-loss toast
    // (Banner.swift; a full-width strip until owner 2026-08-26) and polls
    // preflight until the permission comes back —
    // exiting under KeepAlive would be a relaunch loop, and exiting without
    // it leaves the machine silently unfiltered (spike A1, 2026-08-21:
    // launchd-launched ungranted agent exits 3 in ~1 s; that shape cannot
    // ship).
    var captureLossBanner = false
    var hotkeyTest = false
    var uiSelfTest = false
    var onboardingSelfTest = false
    /// Machine diagnostic (PerfTier.swift, investigation 2026-09-02): print
    /// what this machine looks like and which performance tier the rule WOULD
    /// choose, then exit. Reads nothing, writes nothing, applies nothing —
    /// `fps` above is still whatever config/flags set.
    var probe = false
    var probeSelfTest = false
    /// `--resilience-selftest`: model-cache recovery + startup log roll
    /// (ResilienceSelfTest.swift). Headless like the other selftests.
    var resilienceSelfTest = false
    /// `--compile-model-cache <package>`: compile the trusted entry next to
    /// an installed model, as root, at install time (configure-install.sh;
    /// security review 2026-09-28 T3). Headless; exits.
    var compileModelCache: String?
    /// `--check-model-cache <package>`: print whether the trusted entry the
    /// agent would load is present and passes its trust rule (watchdog.sh,
    /// as root). Headless; exits 0.
    var checkModelCache: String?
    /// `--print-tuning`: dump the effective `TuningPolicy` (defaults +
    /// config.json `tuning`, + the tuning.json when present) as
    /// pretty JSON on stdout and exit 0. For the harness and the dev tab.
    var printTuning = false
    /// The tracker / curtain tuning in force at launch (TuningPolicy.swift):
    /// the receipted defaults, layered with config.json's `tuning` object.
    var tuning = TuningPolicy.defaults
    /// Where `tuning` came from, for the `tuning` log record.
    var tuningSource = "defaults"
    // Parent popover on injected fake state:
    // no model, no capture, no overlay, no panic hotkey.
    var uiDemo = false
    var uiDemoState = DemoState()
    // Dedicated setup window on injected fake state. This path must return
    // before settings, model, capture, permission, and overlay setup.
    var uiOnboardingDemoScenario: String?
    var blockFaces = false
    var overlays = true
    // Headless replay: re-run logged raw detections through the real Policy +
    // Tracker (no capture, no screen). Any past session log is a test fixture.
    var replay: String?
    // Headless PIXEL replay: decode this video
    // and run the full pipeline (real detector + MotionBoxes + Tracker) over
    // its frames. No capture, no overlay window, no display.
    var process: String?
    // Test-only region of interest (normalized, bottom-left origin, same
    // space as detection boxes). Blocked detections whose center falls
    // outside are dropped BEFORE the tracker, so automated tests on a shared
    // desktop only paint overlays inside the test window. Never set in
    // production: it is an under-blocking filter.
    var roi: CGRect?
    var cover = CoverMode.region
    // Class-blocking policy (Policy in Tracker.swift). nil = mode default:
    // strict in region/media (SPEC §5.2 "bias aggressive"), standard when a
    // live curtain actually exists (owner decision 2026-08-19 — the
    // whole-window cover makes covered-swimwear flags an annoyance, so
    // curtain triggers on the explicit-exposure classes only). Resolution
    // happens where curtain construction is known (Pipeline.effectivePolicy;
    // replay resolves to strict): a DEGRADED curtain run — headless or
    // window tracking off — must not silently keep the weaker standard
    // policy while painting region covers (review 2026-08-19, P2).
    // `--policy` overrides everything.
    var policy: PolicyMode?
    // Miss tolerance for a media-held region, in seconds. Receipt: the
    // video-v2 visual-verification run
    // had a 2.5 s content-absence gap inside the media box —
    // the detector emitted nothing while a partial face panned back in, a
    // 1.33 s exposure. 5 s = 2x that measured gap. Re-checked against the
    // first media-mode run (runs/media-video daemon.jsonl, 1373 frames /
    // 48 s): longest gap with no blocked detection is 75 frames ≈ 2.6 s at
    // that run's 28.6 fps, so 5 s keeps a 1.9x margin on a second fixture.
    // Over-hold blacks the player longer, which is the fail-safe direction.
    var mediaHoldSecs = 5.0
    var mediaHoldFrames: Int { Int(mediaHoldSecs * Double(fps)) }
    // Debug injection shape/duration (SPEC §8.2); full-screen rect + long
    // duration lets automated tests exercise the coverage tripwire's release.
    var injectRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    var injectSecs = 3.0
    /// `--dev-inject`: register the test-only inject hotkey
    /// (`HotkeyCenter.injectKey`, receipt there). Off by default and NOT a
    /// config.json key, so an installed build can never arm it. Since
    /// 2026-09-07 the same flag also arms the dev SIGNAL triggers — SIGUSR1
    /// (inject) and SIGUSR2 (panic), which need no registration at all and
    /// were therefore reachable from any Terminal in the session
    /// (DevSignals.swift, SPEC §8.1(8)).
    var devInject = false
    /// DEV-only trigger crop capture. Off by default and deliberately absent
    /// from ConfigFile/configKeys, so an installed config cannot enable pixel
    /// persistence. The shielded harness passes a per-run directory.
    var devCropDir: String?
    // OS-assisted window tracking + display-rate extrapolated painting.
    // On by default; `--window-track off`
    // restores the pre-v3 paint path exactly — the pipeline still runs
    // unchanged, the overlay just paints the rects it is handed at 30 Hz.
    // This exists as a kill switch and as the A/B control: the before/after
    // live drag scores are two runs of THIS binary on the same desktop, which
    // is the only way to compare them without the desktop itself being a
    // variable.
    var windowTrack = true
    // Dev/test hook (iPad-Sidecar lab, SPEC "Multi-display" open item): capture
    // and overlay a SPECIFIC display instead of the default. nil reproduces
    // prior behavior byte for byte -- SCShareableContent.displays.first /
    // NSScreen.screens.first -- with display-local (0,0) treated as global
    // (0,0) everywhere downstream, which is only true for the main display.
    // Given, every display-relative computation switches to that display's
    // real CGDisplayBounds origin (nonzero for e.g. a Sidecar iPad placed to
    // the left of main) -- see resolveDisplayTarget, Pipeline.screenRect, and
    // PaintExtrapolator's pinned-rect clamp, none of which carried an origin
    // before this flag existed because only one display was ever addressable.
    var displayID: CGDirectDisplayID?

    /// Production config file (D1, milestone-3-plan.md). The launchd agent
    /// runs with `--config /Library/Application Support/SentryScreen/
    /// config.json` (root-owned, so a standard account cannot edit policy)
    /// instead of a flag list baked into the plist. Applied BEFORE the flag
    /// loop, so every explicit CLI flag overrides its config value and the
    /// dev flag surface keeps working unchanged. Unknown keys fail loudly —
    /// a typo like "polcy" silently ignored would ship the default policy
    /// as if it were the configured one.
    private struct ConfigFile: Decodable {
        var model: String?
        var cover: String?
        var policy: String?
        var fps: Int?
        /// Performance tier (PerfTier.swift). Present so an installer that
        /// pins a tier has a landing place; absent means "detect", which is
        /// the production path.
        var tier: String?
        var curtainStrip: Double?
        var logMode: String?
        var quiet: Bool?
        var log: String?
        var ttl: Int?
        var captureLoss: String?
        var windowTrack: Bool?
    }
    private static let configKeys: Set<String> = [
        "model", "cover", "policy", "fps", "tier", "curtainStrip", "logMode",
        "quiet", "log", "ttl", "captureLoss", "windowTrack", "tuning",
    ]

    private static func applyConfig(_ path: String, to opts: inout Options) {
        func fail(_ message: String, code: Int32) -> Never {
            FileHandle.standardError.write(Data(("config \(path): " + message + "\n").utf8))
            exit(code)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            fail("cannot read file", code: 66)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("not a JSON object", code: 65)
        }
        let unknown = Set(raw.keys).subtracting(configKeys)
        guard unknown.isEmpty else {
            fail("unknown keys \(unknown.sorted()) (known: \(configKeys.sorted()))", code: 64)
        }
        guard let cfg = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            fail("key has wrong value type", code: 65)
        }
        // Same validation as the corresponding flags — a config file must
        // never accept a value the CLI would refuse.
        if let v = cfg.model { opts.model = v }
        if let v = cfg.cover {
            guard let mode = CoverMode(rawValue: v) else {
                fail("unknown cover \(v) (expected region|media|curtain)", code: 64)
            }
            opts.cover = mode
        }
        if let v = cfg.policy {
            guard let mode = PolicyMode(rawValue: v) else {
                fail("unknown policy \(v)", code: 64)
            }
            opts.policy = mode
        }
        if let v = cfg.fps { opts.fps = v; opts.fpsExplicit = true }
        if let v = cfg.tier {
            guard let name = PerfTier.TierName(rawValue: v) else {
                fail("unknown tier \(v) (expected default|no-ane)", code: 64)
            }
            opts.tierOverride = name
        }
        if let v = cfg.curtainStrip {
            guard v >= 0, v <= 200 else { fail("curtainStrip \(v) out of range 0-200", code: 64) }
            Curtain.chromeStripPt = CGFloat(v)
        }
        if let v = cfg.logMode {
            guard let mode = LogMode(rawValue: v) else {
                fail("unknown logMode \(v) (expected full|lean)", code: 64)
            }
            opts.logMode = mode
        }
        if let v = cfg.quiet { opts.quiet = v }
        if let v = cfg.log { opts.logPath = v }
        if let v = cfg.ttl {
            guard v >= 0, v <= Options.ttlMaxSecs else {
                fail(
                    "ttl \(v) out of range: budget=Options.ttlMaxSecs configured=0-"
                        + "\(Options.ttlMaxSecs) s (0 = run forever) observed=\(v) "
                        + "remediation=Options.ttlMaxSecs",
                    code: 64)
            }
            opts.ttl = v
        }
        // Tracker / curtain tuning (TuningPolicy.swift). Read from the raw
        // object: the schema is validated by name there, and a wrong key or
        // an out-of-range value must exit 64 like any other config key —
        // a silently ignored `"treshold"` would ship the default as if it
        // were the configured one.
        if let raw = raw["tuning"] {
            guard let obj = raw as? [String: Any] else { fail("tuning must be an object", code: 64) }
            switch TuningPolicy.parse(obj, base: opts.tuning) {
            case let .success(p):
                opts.tuning = p
                // `"tuning": {}` (the shipped sample) sets nothing: the
                // record must not claim a source that supplied no value.
                if !obj.isEmpty { opts.tuningSource = "config.json" }
            case let .failure(why):
                fail("tuning: \(why.text)", code: 64)
            }
        }
        if let v = cfg.captureLoss {
            guard v == "exit" || v == "banner" else {
                fail("unknown captureLoss \(v) (expected exit|banner)", code: 64)
            }
            opts.captureLossBanner = v == "banner"
        }
        if let v = cfg.windowTrack { opts.windowTrack = v }
    }

    static func parse() -> Options {
        var opts = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        var ttlGiven = false
        func value(_ flag: String) -> String {
            guard !args.isEmpty else {
                FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
                exit(64)
            }
            return args.removeFirst()
        }
        // Config first, flags after: the loop below naturally overrides.
        if let i = args.firstIndex(of: "--config") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("missing value for --config\n".utf8))
                exit(64)
            }
            // Two configs would mean one silently wins; refuse instead of
            // guessing which one the operator meant.
            guard args.lastIndex(of: "--config") == i else {
                FileHandle.standardError.write(
                    Data("duplicate --config: give exactly one config file\n".utf8))
                exit(64)
            }
            applyConfig(args[i + 1], to: &opts)
        }
        while !args.isEmpty {
            let flag = args.removeFirst()
            switch flag {
            case "--config": _ = value(flag)  // consumed above, before the loop
            case "--hotkey-test": opts.hotkeyTest = true
            case "--ui-selftest": opts.uiSelfTest = true
            case "--onboarding-selftest": opts.onboardingSelfTest = true
            case "--probe": opts.probe = true
            case "--probe-selftest": opts.probeSelfTest = true
            case "--resilience-selftest": opts.resilienceSelfTest = true
            case "--compile-model-cache": opts.compileModelCache = value(flag)
            case "--check-model-cache": opts.checkModelCache = value(flag)
            case "--print-tuning": opts.printTuning = true
            case "--ui-demo": opts.uiDemo = true
            case "--ui-onboarding-demo": opts.uiOnboardingDemoScenario = value(flag)
            case "--ui-demo-state":
                let raw = value(flag)
                let kv = raw.split(separator: "=", maxSplits: 1).map(String.init)
                let why = kv.count == 2 ? opts.uiDemoState.set(kv[0], kv[1]) : "want key=value"
                if let why {
                    FileHandle.standardError.write(Data("--ui-demo-state \(raw): \(why)\n".utf8))
                    exit(64)
                }
            case "--block-faces": opts.blockFaces = true
            case "--no-overlays": opts.overlays = false
            case "--model": opts.model = value(flag)
            case "--fps": opts.fps = Int(value(flag)) ?? opts.fps; opts.fpsExplicit = true
            case "--tier":
                let raw = value(flag)
                guard let name = PerfTier.TierName(rawValue: raw) else {
                    FileHandle.standardError.write(Data(
                        "unknown --tier \(raw) (expected default|no-ane)\n".utf8))
                    exit(64)
                }
                opts.tierOverride = name
            case "--width": opts.width = Int(value(flag)) ?? opts.width
            case "--conf": opts.conf = Float(value(flag)) ?? opts.conf
            case "--ttl":
                // Parsed, not coerced: a bad --ttl must never leave the dev
                // dead-man switch at a value nobody asked for.
                let raw = value(flag)
                guard let secs = Int(raw), secs >= 0, secs <= Options.ttlMaxSecs else {
                    FileHandle.standardError.write(Data(
                        ("--ttl \(raw): budget=Options.ttlMaxSecs configured=integer 0-"
                            + "\(Options.ttlMaxSecs) s (0 = run forever) observed=\"\(raw)\" "
                            + "remediation=Options.ttlMaxSecs\n").utf8))
                    exit(64)
                }
                opts.ttl = secs
                ttlGiven = true
            case "--clear-frames": opts.clearFramesOverride = Int(value(flag))
            case "--exclude-windows":
                let raw = value(flag)
                let ids = raw.split(separator: ",").map { Int($0) }
                guard !ids.isEmpty, !ids.contains(nil) else {
                    FileHandle.standardError.write(
                        Data("--exclude-windows: expected id,id,... got \"\(raw)\"\n".utf8))
                    exit(64)
                }
                opts.excludeWindows = ids.compactMap { $0 }
            case "--log": opts.logPath = value(flag)
            case "--log-mode":
                let raw = value(flag)
                guard let mode = LogMode(rawValue: raw) else {
                    FileHandle.standardError.write(
                        Data("unknown --log-mode value: \(raw) (expected full|lean)\n".utf8))
                    exit(64)
                }
                opts.logMode = mode
            case "--quiet": opts.quiet = true
            case "--capture-loss":
                let raw = value(flag)
                guard raw == "exit" || raw == "banner" else {
                    FileHandle.standardError.write(Data(
                        "unknown --capture-loss value: \(raw) (expected exit|banner)\n".utf8))
                    exit(64)
                }
                opts.captureLossBanner = raw == "banner"
            case "--replay": opts.replay = value(flag)
            case "--process": opts.process = value(flag)
            case "--inject-secs": opts.injectSecs = Double(value(flag)) ?? opts.injectSecs
            case "--dev-inject": opts.devInject = true
            case "--dev-crop-dir": opts.devCropDir = value(flag)
            case "--media-hold": opts.mediaHoldSecs = Double(value(flag)) ?? opts.mediaHoldSecs
            case "--window-track":
                let raw = value(flag)
                guard raw == "on" || raw == "off" else {
                    FileHandle.standardError.write(
                        Data("unknown --window-track value: \(raw) (expected on|off)\n".utf8))
                    exit(64)
                }
                opts.windowTrack = raw == "on"
            case "--display":
                let raw = value(flag)
                guard let id = UInt32(raw) else {
                    FileHandle.standardError.write(Data((
                        "invalid --display value: \(raw) (expected a CGDirectDisplayID integer, "
                        + "e.g. from scratchpad/displaycount)\n").utf8))
                    exit(64)
                }
                opts.displayID = id
            case "--cover":
                let raw = value(flag)
                guard let mode = CoverMode(rawValue: raw) else {
                    FileHandle.standardError.write(
                        Data("unknown --cover value: \(raw) (expected region|media|curtain)\n".utf8))
                    exit(64)
                }
                opts.cover = mode
            case "--curtain-strip":
                let raw = value(flag)
                guard let pt = Double(raw), pt >= 0, pt <= 200 else {
                    FileHandle.standardError.write(
                        Data("invalid --curtain-strip value: \(raw) (points, 0-200)\n".utf8))
                    exit(64)
                }
                Curtain.chromeStripPt = CGFloat(pt)
            case "--policy":
                let raw = value(flag)
                guard let mode = PolicyMode(rawValue: raw) else {
                    FileHandle.standardError.write(
                        Data("unknown --policy value: \(raw) (expected strict|standard)\n".utf8))
                    exit(64)
                }
                opts.policy = mode
            case "--roi":
                let parts = value(flag).split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    opts.roi = CGRect(
                        x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
            case "--inject-rect":
                let parts = value(flag).split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    opts.injectRect = CGRect(
                        x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
            default:
                FileHandle.standardError.write(Data("unknown flag: \(flag)\n".utf8))
                exit(64)
            }
        }
        // Pixel replay needs the real model but is run dozens of times a day
        // from test scripts: default to the repo's weights, resolved from the
        // binary's own location (daemon/.build/sentry-screen).
        if opts.process != nil && opts.model.isEmpty {
            opts.model = Self.repoModelPath
        }
        if opts.uiOnboardingDemoScenario != nil
            && (opts.uiDemo || opts.process != nil || opts.replay != nil
                || opts.hotkeyTest || opts.uiSelfTest || opts.onboardingSelfTest)
        {
            FileHandle.standardError.write(Data(
                ("--ui-onboarding-demo must run by itself; do not combine it with "
                    + "--ui-demo, --process, --replay, --hotkey-test, --ui-selftest, "
                    + "or --onboarding-selftest\n").utf8))
            exit(64)
        }
        if opts.uiDemo && !ttlGiven { opts.ttl = UIDemoController.defaultTTL }
        if opts.uiOnboardingDemoScenario != nil && !ttlGiven {
            opts.ttl = UIOnboardingDemoEntrypoint.defaultTTL
        }
        var runsWithoutModel = opts.probe || opts.printTuning || opts.compileModelCache != nil
            || opts.checkModelCache != nil
        runsWithoutModel = runsWithoutModel || opts.hotkeyTest || opts.uiSelfTest
            || opts.onboardingSelfTest || opts.uiDemo || opts.probeSelfTest
            || opts.resilienceSelfTest || opts.uiOnboardingDemoScenario != nil || opts.replay != nil
        if !runsWithoutModel && opts.model.isEmpty {
            FileHandle.standardError.write(Data("required: --model <path.mlpackage>\n".utf8))
            exit(64)
        }
        // PERFORMANCE TIER (PerfTier.swift, owner decision 2026-09-02). Last
        // step of parsing, so an explicit --fps/config fps still wins: the tier
        // is the fallback for a machine nobody configured, not an override of
        // someone who did. On any machine with a reachable Neural Engine this
        // resolves to `default` / fps 30, i.e. exactly the pre-tier value —
        // which is what makes the frozen gate baseline still valid.
        // `PerfTier.fpsFloor` is a named budget the moment tiers exist, so an
        // fps under it must fail by name rather than silently rewrite the nine
        // derived constants through their `max(...)` clamps (receipt audit
        // 2026-09-02: the config/flag parse validated `tier` and `curtainStrip`
        // but let any integer through here). The ceiling is the 30 fps every
        // receipt in this repo was measured at — above it nothing is receipted
        // and 60 fps is already documented as not fitting inference.
        if opts.fpsExplicit
            && (opts.fps < PerfTier.fpsFloor || opts.fps > PerfTier.standard.fps) {
            FileHandle.standardError.write(Data(
                ("fps: budget PerfTier.fpsFloor..PerfTier.standard.fps, limit "
                + "\(PerfTier.fpsFloor)...\(PerfTier.standard.fps), observed "
                + "\(opts.fps) (fix: --fps / config.json fps)\n").utf8))
            exit(64)
        }
        let resolved = PerfTier.resolve(override: opts.tierOverride)
        opts.tier = resolved.tier
        opts.ane = resolved.ane
        opts.tierWhy = resolved.why
        if !opts.fpsExplicit { opts.fps = resolved.tier.fps }
        return opts
    }

    static var repoModelPath: String {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()  // .build
            .deletingLastPathComponent()  // daemon
            .deletingLastPathComponent()  // repo root
            // Development default: the committed model.
            .appendingPathComponent("model/weights/yolox_50ep_v8_ep50_fp16.mlpackage")
            .path
    }
}

func die(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// A validated `--display` target: the display's own NSScreen (for placing
/// the overlay window, which wants AppKit's bottom-left-of-main space) and
/// its bounds in CG global space -- top-left origin, Y down, the same space
/// CGWindowListCopyWindowInfo and the Accessibility API report window frames
/// in (CoverOwnership's doc comment: "CGWindowList space"). `bounds.origin`
/// is (0,0) only for the main display; every other display in an arrangement
/// has a real offset -- the iPad-Sidecar lab's display sits at x < 0 (left of
/// main) -- and that offset is exactly what screenRect() and
/// PaintExtrapolator's pinned-rect clamp were missing before this flag
/// existed: both assumed screen-local (0,0) was also global (0,0).
struct DisplayTarget {
    let id: CGDirectDisplayID
    let screen: NSScreen
    let bounds: CGRect
}

/// Main-thread acknowledgement for an asynchronous detector-queue resume.
/// A new pause invalidates the queued acknowledgement before it can publish a
/// healthy UI state. Tests inject both queues so they can hold the detector
/// operation without blocking AppKit.
final class PauseResumeAcknowledger {
    typealias Enqueue = (@escaping () -> Void) -> Void

    private let enqueueBehavior: Enqueue
    private let enqueueMain: Enqueue
    private let canAcknowledge: () -> Bool
    private let onPendingChange: (Bool) -> Void
    private(set) var isPending = false
    private var generation: UInt = 0

    init(
        enqueueBehavior: @escaping Enqueue,
        enqueueMain: @escaping Enqueue,
        canAcknowledge: @escaping () -> Bool,
        onPendingChange: @escaping (Bool) -> Void
    ) {
        self.enqueueBehavior = enqueueBehavior
        self.enqueueMain = enqueueMain
        self.canAcknowledge = canAcknowledge
        self.onPendingChange = onPendingChange
    }

    func requestResume(
        applyBehavior: @escaping () -> Void,
        onAcknowledged: @escaping () -> Void
    ) {
        generation &+= 1
        let requestGeneration = generation
        setPending(true)
        let enqueueMain = self.enqueueMain
        enqueueBehavior {
            applyBehavior()
            enqueueMain { [weak self] in
                guard let self,
                    self.generation == requestGeneration,
                    self.canAcknowledge()
                else { return }
                onAcknowledged()
                self.setPending(false)
            }
        }
    }

    func cancelPendingResume() {
        generation &+= 1
        setPending(false)
    }

    private func setPending(_ pending: Bool) {
        guard pending != isPending else { return }
        isPending = pending
        onPendingChange(pending)
    }
}

/// Validates `--display <id>` against the CURRENTLY ACTIVE display list and
/// resolves it to both coordinate representations `DisplayTarget` needs.
/// Synchronous (CGGetActiveDisplayList needs no permission), so an unknown id
/// is refused loudly -- with the list of what IS active -- before the app
/// requests Screen Recording access or opens any window; there is no silent
/// fall-through to the main display.
func resolveDisplayTarget(_ requested: CGDirectDisplayID) -> DisplayTarget {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    func describe(_ id: CGDirectDisplayID) -> String {
        let b = CGDisplayBounds(id)
        return "  \(id): \(Int(b.width))x\(Int(b.height)) at (\(Int(b.origin.x)),\(Int(b.origin.y)))"
            + (CGDisplayIsMain(id) != 0 ? " [main]" : "")
    }
    guard ids.contains(requested) else {
        die(
            "--display \(requested) is not an active display. Available displays:\n"
            + ids.map(describe).joined(separator: "\n"), code: 64)
    }
    guard let screen = DisplayGeometry.screen(displayID: requested) else {
        die(
            "--display \(requested) is active but has no matching NSScreen "
            + "(fix: resolveDisplayTarget)", code: 64)
    }
    return DisplayTarget(id: requested, screen: screen, bounds: CGDisplayBounds(requested))
}

final class Pipeline {
    let opts: Options
    let detector: Detector
    let logger: FrameLogger
    let tracker: Tracker
    let overlays = OverlayManager()
    /// The painted rect over time. One instance per process, so the live
    /// overlay and the `--process` log's `painted` field are literally the
    /// same rects.
    let paintSmoother = PaintSmoother()
    var capture: CaptureStream!
    /// Live-capture geometry guard: see CaptureContentCrop. Constructed always,
    /// used only from `process`, which `--process` never calls.
    private lazy var contentCrop = CaptureContentCrop(fps: opts.fps) { [weak self] info in
        FileHandle.standardError.write(Data("\(info)\n".utf8))
        self?.logger.event("capture-geometry", info)
    }
    /// Capture-health hook 5: fires on the main
    /// thread after the first valid frame reaches the processing queue. A
    /// successful stream start alone is not proof that capture delivered.
    var onCaptureHealth: ((CaptureHealth) -> Void)?
    /// Separate first-frame Receipt for parent onboarding. It has the same
    /// edge as `onCaptureHealth`, but keeps onboarding out of Pipeline.
    var onFirstCaptureFrame: (() -> Void)?
    /// Installed onboarding keeps a named pre-frame failure visible instead
    /// of exiting into a watchdog restart cycle. Other modes retain their
    /// existing fatal behavior when this callback is nil.
    var onCaptureStartFailure: ((String) -> Void)?
    /// Every curtain drop, for the parent UI's own-session ring (spec §7.2).
    /// Called on detectQueue; the receiver hops to main.
    var onCurtainDrop: ((ActivityItem) -> Void)?
    /// Detector health EDGES only (2026-09-11): the frame that
    /// crosses `DetectorWatch.failingStreak`, and the frame that recovers.
    /// Called on detectQueue; the receiver hops to main. Edges, not per-frame
    /// state, because the value is `@Published` — see DetectorHealth.
    var onDetectorHealth: ((DetectorHealth) -> Void)?
    /// The display scope capture resolved. Called on the main thread.
    var onDisplayScope: ((DisplayScope) -> Void)?
    /// True while an expired pause is waiting for detectQueue to apply resume.
    /// Called on the main thread, after the behavior acknowledgement changes.
    var onPauseResumePending: ((Bool) -> Void)?
    /// The panic-class pause as the UI shows it (owner 2026-09-29, plan §6
    /// item 3): fired on the main thread on every change only — a new or
    /// extended panic, an early resume, an expiry — never per tick.
    var onPanicPause: ((PanicPause?) -> Void)?
    /// nil in region mode: no pixel work, no behavior change.
    private let motionBoxes: MotionBoxes?
    /// nil unless this process actually paints on a real screen. `--process`
    /// (pixel replay) and `--no-overlays` must not poll the window server: there
    /// are no windows to own a fixture's rects, the poll thread would perturb
    /// the mediaMs measurements, and the headless logs must stay byte-identical
    /// to the pre-v3 baseline. The OS-assisted paths no-op by being absent, not
    /// by branching deep inside themselves.
    let windowTracker: WindowTracker?
    /// Incumbency, occlusion freeze and the window-relative pin.
    /// nil exactly when
    /// `windowTracker` is nil, so `--process` never constructs one.
    private let coverOwnership: CoverOwnership?
    /// Region ids the ownership layer froze under an occluder on the PREVIOUS
    /// frame — ownership is resolved after the tracker runs, so this is the
    /// freshest verdict available when the tracker needs it. Always empty
    /// headless (`coverOwnership` is nil there).
    private var frozenRegions: Set<Int> = []
    /// Sticky region-id -> curtain-id ownership (receipt at the attribution
    /// loop in step()); read by Overlay.ownerClamped via sync.
    private var regionCurtainOwners: [Int: UInt32] = [:]
    /// Previous sync's curtain rects, for swept-path attribution (receipt
    /// at the attribution loop).
    private var prevCurtainRects: [UInt32: CGRect] = [:]
    /// Region ids the ownership layer held a window PIN for on the PREVIOUS
    /// frame — same provenance and same one-frame lag as `frozenRegions`, and
    /// empty for every headless caller. `Tracker.update(owned:)` uses it to
    /// decide whether the settled-tail union of overlapping media boxes is
    /// taken raw (owned: "one window, one player" may be assumed) or CLAMPED
    /// to the region's previous rect (unowned). It no longer selects WHETHER
    /// that union is taken — receipt at the Tracker call site.
    private var ownedRegions: Set<Int> = []
    /// Region ids whose OWNER WINDOW was moving on the previous frame. The
    /// media latch's sustained-translation demote must not fire on these.
    ///
    /// Receipt (tk3, runs/ipad-tk3P-flick1 t=19.2): during the vertical+left
    /// drag MotionBoxes reads the window's own motion as sustained translation,
    /// `media latch demoted (region 1)` fires, the region stops being
    /// media-held, ownership lapses and the pin has to be re-acquired mid-drag
    /// — the exact sequence tk2 stream C fixed for OCCLUDERS and left open for
    /// window drags. Same argument, same authority: a window being dragged IS
    /// translating pixels, the window server has already said so, and reading
    /// them as "the page is scrolling, there is no media element here" destroys
    /// the cover precisely when it is hardest to rebuild.
    ///
    /// Deliberately narrow. Not "every owned region" — an owned window that is
    /// STILL and whose page genuinely scrolls still demotes, so the documented
    /// degrade-to-region-mode behaviour (media-cover-v2 §1) is intact. The
    /// exemption lasts exactly as long as `WindowTracker.stillSecs` after the
    /// last window movement.
    private var draggingRegions: Set<Int> = []
    private var frameOrdinal = 0
    /// The captured display's geometry (size in points + CG-global origin).
    ///
    /// A `var`, not a `let`: this used to be read once in `init` and
    /// frozen for the process's life, so a resolution change, a hot-plug, a
    /// Sidecar attach or a main-display reassignment left every
    /// normalized-to-point conversion below computing against geometry that no
    /// longer existed — covers painted in the wrong place, silently.
    ///
    /// THREAD: seeded in `init` and written only inside `applyDisplayChange`'s
    /// `detectQueue` block — the same queue every conversion below reads it
    /// from, so no detect thread can observe a half-updated size/origin pair.
    /// The main thread keeps its own copy for the comparison
    /// (`DisplayTopologyWatcher.geometry`) and never re-reads this one after
    /// `start()`.
    private var geometry: DisplayGeometry
    /// Screen size in points. Every conversion below divides or multiplies by
    /// it; `geometry` is what keeps it current.
    private var screenSize: CGSize { geometry.size }
    /// The last detector-frame time. Geometry-only maintenance starts only
    /// after this much quiet time.
    private var lastFrameAt: CFAbsoluteTime = 0
    private var curtainTickTimer: DispatchSourceTimer?
    /// MEASURED 2026-08-26: static capture gaps reached 18.7 s, so close and
    /// minimize state could not advance. DERIVED: 250 ms adds at most half
    /// of subFloorLiftSecs to a geometry decision and runs no detector.
    static let curtainTickSecs: TimeInterval = 0.25
    /// nil unless `--display` was given: the resolved capture/overlay target
    /// and its CG-global origin, threaded into every place that used to
    /// assume the screen's own (0,0) was also the desktop's (0,0).
    ///
    /// LAUNCH SNAPSHOT. Only its `id` survives a display reconfiguration —
    /// `screen` and `bounds` are read here at init and nowhere after it;
    /// everything live re-resolves from the id through `DisplayGeometry`,
    /// because a reconfiguration can hand out a different `NSScreen`
    /// object and a different origin for the same display.
    private let displayTarget: DisplayTarget?
    /// Capture frames between full z-order ownership walks.
    ///
    /// Receipt (trackA): a full CGWindowList snapshot + parse is 1.2-1.4 ms and
    /// resolving a rect against it is 0.005 ms. Every frame at 30 fps costs
    /// 3.6-4.2% of one core, which does not fit — the daemon measures 18.6% avg
    /// against a 25% budget and the 120 Hz poll (1.26%) and 60 Hz repaint (0.4%)
    /// are already spending most of what is left. Every 3rd frame is 1.2-1.4% and
    /// fits.
    ///
    /// What this buys and what it costs, explicitly: on the other two frames the
    /// incumbent owner is re-validated from the poll ring for free (no syscall) —
    /// the window must still exist and must still HOLD the cover rect, and
    /// failing either drops ownership on that frame. So ownership is LOST
    /// immediately and GAINED at most 100 ms late, which is the safe asymmetry:
    /// losing it hands authority back to the pixel path, gaining it is only an
    /// optimization.
    ///
    /// The cheap check cannot see z-order, so a window newly moving in FRONT of
    /// the player is seen at most 100 ms late. v3 called that safe because "the
    /// error is over-block"; the adversarial pass falsified that (the occluder
    /// took ownership and dragged the cover off the player). What bounds it now
    /// is `CoverOwnership`: the occlusion latch is sticky between walks, and an
    /// occluder cannot take ownership from a live incumbent at all, so the
    /// 100 ms buys at most 100 ms of riding a window that has just been covered
    /// up — the cover is still on the player, which is over-block.
    ///
    /// RESTATED AS A DURATION 2026-09-08 (one of the six live-paint constants
    /// the receipt audit left as a KNOWN GAP). Every number in the paragraphs
    /// above is a millisecond figure — "GAINED at most 100 ms late", "the
    /// 100 ms buys at most 100 ms of riding a window that has just been covered
    /// up" — and the constant was a fixed frame count, so at the no-ane tier's
    /// 15 fps the z-order blind spot this bounds would have been 200 ms, twice
    /// what the adversarial pass signed off on and half a SPEC §6 latency
    /// budget. Derived from the duration instead: 3 at 30 fps (exactly the
    /// pre-tier value, integer arithmetic), 1 at 15 fps.
    ///
    /// INTEGER FLOOR, not rounding, in the same shape as
    /// `MotionBoxes.scrollLagFrames`: flooring can only make the walk MORE
    /// frequent than 100 ms, never less, so `lag <= resolveLagSecs` holds at
    /// every fps rather than only where the division comes out exact. The cost
    /// at 15 fps is walking every frame — the same trade `Curtain.walkEvery`
    /// already takes at that tier, and at the same price: the CGWindowList
    /// snapshot is 1.2-1.4 ms, so 15/s is ~2% of one core, against the same
    /// budget that already prices this walk at 30 fps.
    static let ownershipResolveLagSecs = 0.100
    static let ownershipResolveEveryAt30 = 3
    static func ownershipResolveEvery(fps: Int) -> Int {
        max(1, (ownershipResolveEveryAt30 * fps) / 30)
    }
    /// Ownership-resolution accounting, for the perf receipt.
    private var ownerMsTotal = 0.0
    private var ownerWalks = 0

    // All mutable pipeline state is confined to detectQueue.
    /// Detect-queue QoS. `.userInteractive`: the detector is the latency
    /// path between pixels and a cover, and it must not queue behind the
    /// very render work that put the pixels there. MEASURED 2026-08-25 (A/B
    /// rig, benign faces window opened by Chrome, 4 trials each): at the
    /// default QoS the model call spiked to 56-156 ms on the frames where
    /// Chrome painted the images (steady 19 ms); at userInteractive it stayed
    /// 16-25 ms through the same burst. Region cover 139 → 112 ms, curtain
    /// 233 → 204 ms from content-shown. Same class of receipt as
    /// WindowTracker's poll thread. `SENTRY_DETECT_QOS=default` restores the
    /// old value for measurement.
    static let detectQoS: DispatchQoS = DevEnv.knob("SENTRY_DETECT_QOS") == "default"
        ? .default : .userInteractive
    private let detectQueue = DispatchQueue(label: "sentryscreen.detect", qos: Pipeline.detectQoS)

    /// Re-attempt cadence while start() has no display to capture. DERIVED:
    /// the same 5 s as AppDelegate.captureLossPollSecs and for the same
    /// reason — both poll a cheap check (there CGPreflight, here
    /// SCShareableContent) for a condition only an external change clears
    /// (permission granted / a display appearing). 5 s bounds the gap when a
    /// remote session connects or a display wakes without spinning a core.
    static let displayWaitPollSecs: TimeInterval =
        DevEnv.knob("SENTRY_DISPLAY_POLL_SECS").flatMap(Double.init) ?? 5
    /// Log the wait every N polls (~once a minute at 5 s) so an indefinitely
    /// display-less launch stays visible in the log without flooding it.
    static let displayWaitLogEvery = 12
    /// Exactly ONE in-flight inference slot. DERIVED: a second slot would
    /// QUEUE a frame behind a slow inference and paint its result late —
    /// stale covers on a moving screen — while the drop-not-queue design
    /// (SPEC latency target; frame drops counted via recordDrop) means the
    /// next accepted frame is always the freshest available. More slots buy
    /// throughput only if inference parallelizes on-device, which a single
    /// ANE does not. Remeasure before changing (2026-08-21).
    private let busy = DispatchSemaphore(value: 1)
    // Busy-gate frame drops are counted via logger.recordDrop() — the
    // FrameLogger's existing lock-guarded off-thread buffer (same shape as
    // recordPaint), drained into the summary counters on detectQueue.
    // Counted for visibility only: no threshold/alert, because no receipt
    // yet exists for what a healthy drop rate is. Add one once a live run
    // has measured it.
    /// Detector-error loud-record throttle (main.swift step(), the
    /// `detector.detect` catch branch). detectQueue-confined, same as every
    /// other per-run counter here — no lock needed.
    ///
    /// Receipt (DERIVED): at 30 fps a persistent CoreML failure hitting this
    /// catch on every frame would otherwise write 30 * 86400 = 2.6M
    /// "detector-error" records/day. One loud record per window is enough to notice and
    /// diagnose the failure; the per-window failure count still reaches the
    /// summary every tick via `logger.count`, uncapped.
    private static let detectorErrorEventInterval: CFAbsoluteTime = 60
    private var lastDetectorErrorEventAt: CFAbsoluteTime = -.infinity

    /// Detector health (2026-09-11). detectQueue-confined like
    /// every other counter here. Receipt for the threshold at
    /// `DetectorWatch.failingStreak`.
    private var detectorWatch = DetectorWatch()
    /// The deadline on one `detect` bracket (receipt at
    /// `DetectDeadline.limitSecs`). Bracketed on detectQueue, read by
    /// `detectDeadlineTimer` on main.
    private let detectDeadline = DetectDeadline()
    private var detectDeadlineTimer: DispatchSourceTimer?
    /// The covers this pipeline painted on the last frame the detector ANSWERED.
    ///
    /// FAIL CLOSED (reversing the old `detections = []` fail-open): a
    /// frame the detector could not answer is not evidence that the screen
    /// became clean, so the pipeline re-paints the last known-good covers and
    /// does not tick the tracker, the media path or the curtain at all. Hysteresis
    /// therefore cannot count a failing frame toward a lift, and Curtain is
    /// untouched — it is simply not asked, which is why this needed no change
    /// there (its state machine holds whatever it last decided). The 250 ms
    /// geometry tick cannot undo that either: `lastFrameAt` still advances on
    /// every held frame so the tick does not fire above 4 fps, and when it does
    /// it calls `curtain.update(evaluated: false)`, which by its own contract
    /// never counts a clean frame toward a lift.
    ///
    /// Held from the FIRST failing frame, not from the `failingStreak`-th: the
    /// streak exists to debounce what the PARENT is told, not to license three
    /// frames of fail-open. At 30 fps three uncovered frames is 100 ms of
    /// exposed content.
    private var heldStep: StepResult = Pipeline.emptyStep

    // MARK: - Idle-frame gate (detectQueue-confined)

    /// A delivered frame whose MEASURED changed area (FrameDelta: green
    /// channel sampled on an 8 px grid, a sample counts as changed above a
    /// delta of 12) is below this fraction of the frame — and that arrives
    /// while nothing is tracked or curtained — runs the detector only every
    /// `idleDetectEvery`-th time. SCK's `dirtyRects` was tried first and
    /// rejected: it is window-granular (receipt in FrameDelta.swift), and it
    /// is still logged per window as `dirtyPct*` for that reason.
    /// DERIVED: 2% is SPEC §5 media mode's floor for "a component worth
    /// covering" (a stable media box must be ≥2% of the screen), so change
    /// smaller than that is cursor, caret, clock, typing, a spinner, a
    /// progress bar — never a playing video. Content CAN still appear inside
    /// a small change (a thumbnail loading in a chat), which is why this
    /// gates the cadence and never the detector outright: worst-case added
    /// latency is (idleDetectEvery-1)/fps = 67 ms at 30 fps, inside SPEC §6's
    /// ≤400 ms detection-to-overlay budget, and the moment anything is
    /// tracked or curtained the gate is off (a paroled/ghost-banned window
    /// with no curtain up re-drops on detection, so it pays the same 67 ms
    /// at most). MEASURED 2026-08-25:
    /// same terminal-busy desktop, same binary — without the gate 28.7-29.2
    /// fps at 19.8-20.0% CPU; with it 1,102/1,691 frames skipped (65%),
    /// detector 9.8 fps, 8.9% CPU, changePct p50/p90 <0.5%. Before any
    /// change the 3-day soak ran 28 fps at CPU p50 21% / p90 31%, over the
    /// 30% tripwire in 14% of active windows.
    static let idleDirtyFraction = 0.02
    /// Added latency the gate is ALLOWED to cost, as a duration. The receipt
    /// above reasons in exactly this quantity — "(idleDetectEvery-1)/fps =
    /// 67 ms at 30 fps, inside SPEC §6's ≤400 ms" — but before the performance
    /// tiers (PerfTier.swift, 2026-09-02) the constant was a fixed frame count,
    /// so the latency it bought silently grew with any lower fps: 133 ms at
    /// 15 fps, 200 ms at 10. Deriving the cadence from the duration keeps the
    /// receipt true at every tier instead of only at 30 fps.
    ///
    /// Integer arithmetic on purpose: `2 * fps / 30` is exact, where
    /// `Int(0.0667 * Double(fps))` is one floating-point rounding away from
    /// returning 2 instead of 3 at 30 fps and silently changing the frozen
    /// baseline. 2 skipped frames at the 30 fps reference = 66.7 ms.
    static let idleAddedLatencyFramesAt30 = 2
    /// The floor is 2, not 1: at 1 the gate never skips anything and the
    /// MEASURED 65% frame saving (receipt above: 1,102/1,691 frames skipped,
    /// CPU 19.8% → 8.9%) silently disappears. A tier at 10 fps would compute 1
    /// from the duration alone, so the floor is what keeps the gate switched
    /// on — and turning the gate OFF is a decision that needs its own receipt,
    /// not a rounding side effect. At the floor the added latency is 1/fps
    /// (100 ms at 10 fps), still inside SPEC §6.
    static let idleDetectEveryFloor = 2
    static func idleDetectEvery(fps: Int) -> Int {
        max(idleDetectEveryFloor, 1 + (idleAddedLatencyFramesAt30 * fps) / 30)
    }
    /// `SENTRY_IDLE_GATE=0` disables the gate for A/B latency measurement
    /// (the only honest way to price what it costs a first detection). Env,
    /// not a flag: a config key would be one more thing a parent could set
    /// wrong; this is for the harness, and it is logged in "startup".
    static let idleGateEnabled = DevEnv.knob("SENTRY_IDLE_GATE") != "0"
    private var idleSkipStreak = 0
    private var frameDelta = FrameDelta()
    private var settleWatch = SettleWatch()
    /// Weak boxes returned this run (always 0 in a production build), for
    /// the `--process` end line: the proof run must show weak boxes existed
    /// while the logs did not move.
    private(set) var weakBoxesSeen = 0
    /// Zoom prototype rotation (`ZoomTiles.next`): the tile the next
    /// evaluated frame runs. detectQueue only.
    private var zoomNextTile = 0

    // MARK: - Settle re-check (detectQueue-confined)

    /// How far the settle re-check shifts the frame, in capture-buffer
    /// pixels (left and top edge; `Detector.detect(shiftPx:)`). MEASURED
    /// 2026-09-25 on an M1 Mac, benign only (the public-domain
    /// daemon/testdata/portrait.jpg pasted at 40–270 px wide onto a white canvas the
    /// size of the default 1280×720 capture, 165 canvases, 158 face boxes
    /// with the NMS floor at 0.05, shipped v8 student): the score change
    /// against the unshifted pass is |Δ| p50 0.056 at 1 px, 0.073 at 2,
    /// 0.091 at 3, 0.125 at 4, 0.130 at 6, 0.129 at 8, 0.141 at 12, and the
    /// share of boxes the shift RAISES by ≥ 0.05 peaks at 4 px (0.39; 1 px
    /// 0.29, 8 px 0.33). 4 px is where the second sample stops being a copy
    /// of the first, with the least cropped away. Same order of change as
    /// the jitter a test Mac log shows while content moves (receipt at
    /// `TuningPolicy.keepGap`: p50 0.03, p90 0.18).
    ///
    /// COST: one more detector pass per settle — MEASURED 9.9 ms p50 at
    /// 1280×720 on an M1 Mac in the same probe; a test Mac's summaries show
    /// `inferP50` 7.9–11.5 ms (2026-09-25 09:26–09:47 UTC). Settles per
    /// minute are counted live (`settleRechecks`, with `settleRecheckMs`, in
    /// the 60 s summary). DERIVED bound: a settle needs an evaluated motion
    /// frame and `idleDetectEvery` still frames, two of them skipped, so at
    /// most `framesSkippedIdle` / 2 per window — 234 in the busiest test Mac
    /// window that day (469 skipped), ≈ 2.3 s of detector time a minute,
    /// ≈ 4 % of one core, at the worst.
    static let settleShiftPx = 4

    /// IoU at which a shifted-pass box is the same box as a first-pass one
    /// (same label). 0.5, the pairing rule the `keepGap` jitter receipt was
    /// measured with; the shift is 4 px, so a real pair overlaps far more.
    static let settleMatchIoU: CGFloat = 0.5

    /// Settle re-check merge: every first-pass box keeps its own geometry and
    /// takes the higher of its two scores; a shifted box with no first-pass
    /// partner is added (`recheckFrom` 0). A weak box the shift lifted to
    /// `--conf` leaves the weak list. Returns the merged pass and how many
    /// boxes the shift raised or added (`settleRecheckRaised`).
    static func mergeRecheck(_ first: Detector.Pass, _ shifted: [Detection]) -> (pass: Detector.Pass, raised: Int) {
        var out = first
        var raised = 0
        for s in shifted {
            let partner = out.kept.indices
                .filter { out.kept[$0].label == s.label && Geometry.iou(out.kept[$0].box, s.box) >= settleMatchIoU }
                .max { Geometry.iou(out.kept[$0].box, s.box) < Geometry.iou(out.kept[$1].box, s.box) }
            if let i = partner {
                guard s.confidence > out.kept[i].confidence else { continue }
                let d = out.kept[i]
                out.kept[i] = Detection(
                    label: d.label, confidence: s.confidence, box: d.box, recheckFrom: d.confidence)
            } else {
                var added = s
                let weakPartner = out.weak.firstIndex {
                    $0.label == s.label && Geometry.iou($0.box, s.box) >= settleMatchIoU
                }
                added.recheckFrom = weakPartner.map { out.weak[$0].confidence } ?? 0
                if let w = weakPartner { out.weak.remove(at: w) }
                out.kept.append(added)
            }
            raised += 1
        }
        return (out, raised)
    }
    /// True when the last `step` returned any region or curtain — the gate
    /// must not thin detections while a cover's hysteresis is running.
    private var lastStepHadCover = false
    /// The rects PAINTED by the most recent curtain update, normalized
    /// bottom-left — the region-suppression input (receipt at `regionInput`).
    /// Written by both `step` and `curtainTick`, so a lift that happens with
    /// no frame in flight cannot leave a stale rect suppressing detections.
    /// detectQueue only, like every path that touches it. NOT the same state
    /// as `prevCurtainRects`, which holds the full-frame ATTRIBUTION rects
    /// (`attr`, strip included) for the drag-sweep union and is written only
    /// on a frame with curtains: the suppression must key on the PAINTED
    /// content rect so the visible chrome strip keeps its region covers.
    private var lastCurtainPainted: [CGRect] = []
    /// The previous evaluated frame's policy-blocked boxes (before `--roi`):
    /// the score hysteresis input (`TuningPolicy.keepGap`; unused in curtain
    /// mode).
    /// detectQueue only; cleared with `lastCurtainPainted`.
    private var lastBlocked: [Detection] = []
    /// `capturedAt` of the frame currently inside `step` — read by the
    /// curtain onChange (same thread, synchronous inside `curtain.update`)
    /// to stamp `latencyMs` on drop records: pixels-on-glass to cover
    /// decision, the SPEC §6 number, per episode instead of per benchmark.
    private var currentFrameAt: CFAbsoluteTime = 0

    // MARK: - Exposure tripwire (detectQueue-confined, curtain mode)

    /// Consecutive frames with ≥1 policy-relevant detection whose center no
    /// active curtain covers. At `exposureFrames` one loud "exposure"
    /// record fires for the episode (re-armed when the streak breaks). The
    /// log could not answer "did anything go un-curtained?" before this
    /// (health review 2026-08-25, "Not checked"); healthy count is 0.
    /// DERIVED: 12 frames = Tracker.defaultClearAfter at 30 fps = 0.4 s, the
    /// pipeline's own "it's really there" hysteresis — shorter would fire
    /// on the single-frame window between detection and drop that every
    /// episode has by construction. Curtain's deliberate refusals
    /// (ghost-ban, sub-floor lift) count as exposure on purpose: they are
    /// policy, and policy leaving content visible is the thing to know.
    ///
    /// RESTATED AS A DURATION 2026-09-02 (PerfTier.swift). This is a TRIPWIRE,
    /// and a tripwire that loosens itself when a config knob moves is the worst
    /// entry on the fps landmine list: as a fixed 12 frames it meant 0.4 s at
    /// 30 fps but 0.8 s at 15 and 1.2 s at 10 — a third of the sensitivity, on
    /// the exact machines that need it most, with no message anywhere. The
    /// duration is what the receipt above reasons about, so the duration is
    /// what is preserved: 12 frames at 30 fps, 6 at the no-ane tier's 15 fps.
    ///
    /// NOTE for a future reader: the "12 frames = Tracker.defaultClearAfter at
    /// 30 fps" identity in the receipt above holds ONLY at 30 fps. `clearAfter`
    /// has a measured 8-frame floor that this deliberately does not copy
    /// (receipt at `Tracker.clearAfterFrameFloor`), so at 15 fps this is 6
    /// frames against clearAfter's 8. That makes the tripwire fire slightly
    /// SOONER than the hysteresis it was originally pinned to — the safe
    /// direction for a tripwire. Do not "restore" the identity.
    static let exposureSecs = 0.4
    /// Floor, receipted because it clamps a TRIPWIRE and an unreceipted magic
    /// number guarding one is exactly what this change exists to remove: at 1
    /// the tripwire would fire on the single-frame window between detection and
    /// drop that every episode has by construction (receipt above), making it
    /// useless. It binds only below 4 fps, under `PerfTier.fpsFloor`, so no
    /// shipped tier reaches it — `--fps` validation carries the real guarantee
    /// and this is the backstop.
    static let exposureFramesFloor = 2
    static func exposureFrames(fps: Int) -> Int {
        max(exposureFramesFloor, Int((exposureSecs * Double(fps)).rounded()))
    }
    private var uncoveredStreak = 0
    private var uncoveredSince: CFAbsoluteTime = 0
    private var uncoveredLabels: Set<String> = []
    private var exposureEpisodes = 0
    /// stderr copy of the exposure WARNING: at most one per this interval
    /// (same shape and receipt as detectorErrorEventInterval — agent.err is
    /// not rotated, and a detection flickering at the 12-frame cadence could
    /// otherwise write ~2.5 lines/s). The JSON records stay per episode.
    private var lastExposureStderrAt: CFAbsoluteTime = -.infinity

    /// WITHHELD TRIPWIRE. The exposure tripwire above is fed `blocked`, so a
    /// tuning that rejects what the shipped defaults would block leaves it
    /// blind: MEASURED
    /// 08:13:06–08:21:08Z FEMALE_BREAST_EXPOSED sat at
    /// 0.82–0.88 on 1,102 boxes / 93 s with tuning.json's floor at 0.9 —
    /// `blocked` was empty, `regions` 0, no curtain, no tripwire, and the
    /// per-frame record (RAW detections only) could not say which stage
    /// rejected them. This record can. Fires after `withheldSecs` of
    /// continuous withheld-and-uncovered content, then every
    /// `withheldEventSecs` while it persists, and once more when it ends.
    /// Deliberately NOT fed to the exposure tripwire: a raised floor is an
    /// owner decision the exposure count must not score as a curtain miss.
    ///
    /// withheldSecs 5.0 s, DERIVED: the trigger needs `triggerHits` = 3
    /// evaluated frames, which at the 1 frame/s starvation cadence MEASURED
    /// in the same session (08:21:15–19Z) is 3 s; 5 s is that plus one
    /// walk-cadence frame of margin, so a page the curtain is still earning
    /// never reads as withheld. withheldEventSecs 10 s, ASSUMED: the record
    /// exists to be read next to the `event=tuning` record that caused it,
    /// and a dev-tab edit-and-look cycle is seconds, not the 60 s of
    /// detectorErrorEventInterval; cost is ≤ 6 records/min while withheld.
    static let withheldSecs: CFTimeInterval = 5.0
    static let withheldEventSecs: CFTimeInterval = 10.0
    private var withheldSince: CFAbsoluteTime?
    private var lastWithheldEventAt: CFAbsoluteTime = -.infinity
    private var withheldFired = false
    private var withheldEpisodes = 0

    /// detectQueue. `covered` is this frame's painted region rects plus the
    /// painted curtain rects (normalized, bottom-left — the same space as a
    /// detection box); a withheld box whose centre one of them contains is
    /// not bare. `TuningPolicy.defaults` is the baseline: only a box the
    /// shipped policy would block counts, so the default tuning (and the
    /// synthetic gate) never fires this.
    private func noteWithheld(_ raw: [Detection], covered: [CGRect], at t: CFAbsoluteTime) {
        var withheld = tuning.withheld(
            raw, mode: effectivePolicy, blockFaces: opts.blockFaces, screen: screenSize,
            baseline: .defaults)
        if !withheld.isEmpty, !covered.isEmpty {
            let bare = Set(Self.regionInputIndices(raw, underCurtains: covered))
            withheld = withheld.filter { bare.contains($0.index) }
        }
        guard !withheld.isEmpty else {
            if withheldFired {
                logger.event("withheld-end", String(
                    format: "blocked or covered after %.0f ms withheld episode=%d",
                    (t - (withheldSince ?? t)) * 1000, withheldEpisodes))
            }
            withheldSince = nil
            withheldFired = false
            return
        }
        logger.count("tuningWithheld", withheld.count)
        let since = withheldSince ?? t
        withheldSince = since
        guard t - since >= Self.withheldSecs, t - lastWithheldEventAt >= Self.withheldEventSecs
        else { return }
        if !withheldFired { withheldEpisodes += 1 }
        withheldFired = true
        lastWithheldEventAt = t
        var stages: [String: Int] = [:]
        var labels: [String: Float] = [:]
        for w in withheld {
            stages[w.stage, default: 0] += 1
            let d = raw[w.index]
            labels[d.label] = max(labels[d.label] ?? 0, d.confidence)
        }
        let stageText = stages.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let labelText = labels.sorted { $0.key < $1.key }.map { label, conf in
            let floor = tuning.rule(for: label)?.threshold
            return String(format: "%@@%.2f(floor %@)", label, conf,
                          floor.map { String(format: "%.2f", $0) } ?? "-")
        }.joined(separator: ",")
        let info = "budget withheldSecs, limit \(Int(Self.withheldSecs)) s, observed "
            + String(format: "%.0f ms", (t - since) * 1000)
            + " of \(withheld.count) box(es) the default policy blocks and this tuning rejects,"
            + " uncovered; stage=\(stageText) labels=\(labelText) episode=\(withheldEpisodes)"
            + " (fix: tuning classes.<LABEL>.threshold / coveredBeatsExposed / minBox —"
            + " see the last event=tuning record)"
        logger.event("withheld", info)
    }
    /// Launch-to-first-frame for the "startup" record (2.3): the moment the
    /// pipeline genuinely started seeing pixels, measured from Pipeline init.
    private let initAt = CFAbsoluteTimeGetCurrent()
    private var startupLogged = false
    /// detectQueue-confined one-shot. This is independent of `startupLogged`
    /// because a persisted parent pause can suppress detector work while a
    /// valid capture frame still proves that ScreenCaptureKit is live.
    private var firstCaptureFrameReported = false
    /// A geometry-only tick is valid only after this capture generation has
    /// supplied a real, cropped frame. Capture loss clears the receipt.
    private var captureFrameReceiptValid = false
    private var curtainCaptureGeneration: UInt64?

    /// Called when the stream is lost. The next stream generation must earn
    /// a new first-frame Receipt before any UI can return to green.
    func requireNewCaptureFrameReceipt() {
        detectQueue.async { [weak self] in
            self?.firstCaptureFrameReported = false
            self?.captureFrameReceiptValid = false
            self?.curtainCaptureGeneration = nil
            self?.contentCrop.resetMeasurement()
        }
    }
    /// Media-diag event budget per 60 s window (live only; replay keeps
    /// bare stdout). Receipt (DERIVED): the worst measured diagnostic
    /// stream is the media-mode per-frame demote line at ~150-200 B up to
    /// 30/s ≈ 2-4 MB/hour (2026-08-21); 30 lines/min caps that at
    /// ~<0.3 MB/day of structured records while keeping the first bursts
    /// of any episode. Over budget: lines are counted, one loud
    /// "media-diag suppressed N" record closes each window — never a
    /// silent drop. detectQueue-confined, no lock needed.
    private static let mediaDiagPerWindow = 30
    private var mediaDiagWindowStart: CFAbsoluteTime = 0
    private var mediaDiagCount = 0
    private var mediaDiagSuppressed = 0

    /// detectQueue only (Tracker/MotionBoxes run inside step()).
    private func mediaDiag(_ line: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - mediaDiagWindowStart >= 60 {
            if mediaDiagSuppressed > 0 {
                logger.event(
                    "media-diag",
                    "suppressed \(mediaDiagSuppressed) lines — budget "
                    + "mediaDiagPerWindow, limit \(Self.mediaDiagPerWindow)/60s "
                    + "(fix: Pipeline.mediaDiagPerWindow)")
            }
            mediaDiagWindowStart = now
            mediaDiagCount = 0
            mediaDiagSuppressed = 0
        }
        mediaDiagCount += 1
        if mediaDiagCount <= Self.mediaDiagPerWindow {
            logger.event("media-diag", line)
        } else {
            mediaDiagSuppressed += 1
        }
    }
    private var paused = false
    /// detectQueue-confined. Set on the capture suspend⇄active edge so
    /// `process()` skips frames (and their tracker repopulation) while the
    /// session is inactive — pairs with the setTracked([]) clear above (E2 /
    /// idle-CPU, 2026-08-22).
    private var captureSuspended = false
    private var injectUntil: CFAbsoluteTime = 0
    private let pauseSeconds = 300.0  // panic pause, SPEC §8.1(1)
    // Pause ownership: two deadlines, one state.
    // Main-thread only.
    /// Panic hotkey, dev SIGUSR2. Every change goes through
    /// `setPanic` so the UI sees the same deadline the pipeline obeys.
    private var panic: PanicPause?
    private var panicUntil: Date? { panic?.until }
    /// The panic deadline that last ended, kept until the resume is
    /// acknowledged so the `resume` wording can still say which pause ended.
    private var lastPanicUntil: Date?
    private var settingsPause: PauseState = .none  // machine-wide state file
    private var appliedPause = false
    private lazy var pauseResumeAcknowledger = PauseResumeAcknowledger(
        enqueueBehavior: { [weak self] body in self?.detectQueue.async { body() } },
        enqueueMain: { body in DispatchQueue.main.async { body() } },
        canAcknowledge: { [weak self] in self?.appliedPause == false },
        onPendingChange: { [weak self] pending in self?.onPauseResumePending?(pending) })
    private var pauseTimer: Timer?
    private var idleTimer: Timer?
    /// Main-thread tick that ends a pause once `now` passes
    /// `effectivePauseUntil`. DERIVED: the resume request lands up to 1 s late,
    /// the fail-safe direction (more protection, not less); detectQueue then
    /// acknowledges the applied change without blocking AppKit. Matches
    /// UISettingsStore.pollSecs so a state-file change and its expiry are
    /// observed at the same cadence. Replaces the asyncAfter+generation pair,
    /// which let a 5-minute panic's resume cut a 1-hour parent pause short.
    static let pauseTickSecs: TimeInterval = 1.0
    /// While paused, one `event=pause-tick` per this interval so a log read
    /// months later can tell "quiet because nothing happened" from "quiet
    /// because protection was off" (spec §5). DERIVED: same 60 s cadence as
    /// the Logger summary the marker stands in for — that summary only fires
    /// from the frame path, which a paused frame never reaches. `event`
    /// records are never suppressed in lean mode and are excluded from logcmp.
    private static let pauseMarkerSecs: TimeInterval = 60.0
    private var lastPauseMarker: Date?
    /// The single source of truth. Fail-safe by construction: the LATER
    /// deadline wins, so a short panic can never end a long parent pause and
    /// vice versa.
    var effectivePauseUntil: Date? {
        PauseState.compose(panic: panicUntil, settings: settingsPause.effectiveUntil())
    }
    // Main-thread flag. Panic sets it BEFORE clearAll so an overlay sync from
    // an in-flight frame (queued behind the clear) cannot resurrect windows.
    private var suppressed = false
    // Full-coverage tripwire (SPEC §8.1(2)): >90% of screen covered by REGION
    // covers for >60 s logs loudly and lifts the REGION covers alone for
    // `regionReleaseSecs`, in every build, installed included. Curtains and
    // detection stay on (owner 2026-10-18, security review): until then the
    // trip went through the panic path — every cover off, detection paused
    // 5 min — so a screen deliberately tiled with flagged close-ups bought a
    // repeatable five unprotected minutes with no prompt. What the release
    // still guarantees is the 2026-09-02 intent: nobody stays behind a screen
    // of runaway REGION covers (see the scope note below for what it does
    // not watch).
    //
    // SCOPE, stated exactly (review 2026-09-09): this tripwire measures REGION
    // COVERS ONLY. `painted` is `PaintSmoother.rects(for: regions …)`; curtains
    // travel in `curtains` and are never summed here, so no curtain — not a
    // window-sized one, not the FULL-DISPLAY transition shield — can trip it.
    // The 2026-08-19 note called the exclusion safe because a curtain is
    // "window-bounded by construction"; the shield expansion is not, and its
    // bound is its own (Curtain.expansionCapSecs + expansionRearmCooldownSecs),
    // not this one. So do not read the number below as "how much of the screen
    // the user is trapped behind" — read it as "how much of the screen the
    // REGION pipeline is painting".
    //
    // The MEASURED QUANTITY changed 2026-09-08 (receipt at checkCoverage): the
    // sum is now the exact union of the PAINTED region rects, not of the
    // tracker rects. Both numbers stand unchanged, because both were always
    // about what the region pipeline puts on glass: 0.9 is "the region covers
    // have effectively taken the display" and 60 s is "longer than any
    // legitimate full-screen block", and painting is what takes the display.
    // Headroom re-measured on the 13 gate fixtures
    // against the frozen baseline logs: the busiest
    // frame of the busiest fixture (resize-media) paints 0.363 of the screen
    // where the old sum read 0.346, and the largest correction anywhere is
    // steady-region 0.086 -> 0.179 (more than double). Still 2.5x below the
    // limit, and no fixture ever spends a single frame above it.
    private let coverageLimit: CGFloat = 0.9
    private let coverageSeconds = 60.0
    private var coverageSince: CFAbsoluteTime?
    /// How long a full-coverage trip lifts the region covers. ASSUMED
    /// (owner 2026-10-18): long enough to see the screen and close or move
    /// what is under the covers, short enough that a deliberate trip buys
    /// little — the covers are click-through throughout, so the release is
    /// for seeing, not for regaining input. The tracker keeps tracking, so
    /// covers still owed come straight back when it ends.
    static let regionReleaseSecs: CFTimeInterval = 10
    /// Main thread. Region covers are not painted before this time.
    private var regionReleaseUntil: CFAbsoluteTime = 0
    /// At most one alerts.log line per this interval for releases; the ones
    /// in between are counted into the next line. DERIVED: a screen that
    /// stays fully covered trips once per `coverageSeconds`, which would
    /// otherwise write ~1,400 lines a day into the 5 MiB alerts budget a
    /// parent reads; one line per 10 min still dates every episode.
    static let releaseAlertGapSecs: CFTimeInterval = 600
    /// Main thread: the last release line written, and releases since.
    private var lastReleaseAlertAt: CFAbsoluteTime?
    private var releasesSinceAlert = 0
    private var regionsReleased: Bool { CFAbsoluteTimeGetCurrent() < regionReleaseUntil }
    // Media-path pixel-work accounting. Written on
    // detectQueue, read once at the end of a --process run.
    private var mediaMsTotal = 0.0
    private var mediaMsFrames = 0
    /// Average media-path wall time over the run, nil in region mode.
    var mediaMsAverage: Double? {
        mediaMsFrames > 0 ? mediaMsTotal / Double(mediaMsFrames) : nil
    }
    // Curtain pipeline (Curtain.swift), `--cover curtain` live only.
    private let curtain: Curtain?
    /// nil unless the explicit DEV flag is present. Callback payloads collect
    /// on detectQueue and are submitted once after both pipelines finish the
    /// current frame. No crop result feeds back into a decision.
    private let cropWriter: CropWriter?
    private var cropRequestsThisFrame: [CropWriter.Request] = []
    private var cropBlockedThisFrame: [Detection] = []
    // Resolved once curtain construction is known; receipt at Options.policy.
    // `private(set) var` rather than `let` so the parent UI can switch
    // sensitivity mid-run (spec §6). The INITIAL value and its one read site
    // (Policy.blocks on detectQueue) are unchanged — spec §12 rule 5, the
    // rule that keeps the gate byte-identical. Written only from
    // `setPolicy`, and only on detectQueue.
    private(set) var effectivePolicy: PolicyMode
    /// The tracker / curtain tuning in force (TuningPolicy.swift). Same
    /// confinement contract as `effectivePolicy`: read on detectQueue by the
    /// policy filter, written only by `setTuning`, and only on detectQueue;
    /// `tuningOnRecord` is the main-thread mirror that decides whether a
    /// swap is a change worth logging.
    private(set) var tuning: TuningPolicy
    private var tuningOnRecord: TuningPolicy
    /// TUNING TOOL (UIDevTuning.swift): the Developer tab's 60 s readout.
    /// Set by AppDelegate.startPipeline before `start()`, read on
    /// detectQueue per frame; nil in every headless mode.
    var tuningReadout: TuningReadout?
    /// TUNING TOOL (DetectionTrace.swift): the Detection view seam. The
    /// trace is built on detectQueue at the end of `step` and published
    /// here; the overlay subscribes on main through `onTrace`.
    let detectionTraceBus = DetectionTraceBus()
    /// Main thread. True in "Detections only" mode: the two overlay sync
    /// sites skip painting covers and curtains; the pipeline still runs.
    var detectionViewSuppressesCovers = false
    /// Main thread. The newest paint each overlay sync site handed over,
    /// suppressed or not, so covers come back the moment Detections only
    /// ends: a static screen sends no frame that would repaint them
    /// (`restoreCoversForDetectionView`).
    private var detectionViewHeldPaint = DetectionViewHeldPaint()
    /// detectQueue-confined, like `effectivePolicy`; written only by the two
    /// setters below.
    private(set) var traceEnabled = false
    private(set) var syntheticDetectionsEnabled = false
    /// A trace never runs under `--process` / `--replay`: the gate's logs
    /// must not move.
    private var detectionViewAllowed: Bool { opts.process == nil && opts.replay == nil }
    /// Main thread. Applied on detectQueue; attaches a fresh curtain
    /// recorder on enable and detaches it (and clears the bus) on disable.
    /// Returns false, and changes nothing, in a headless replay.
    @discardableResult
    func setDetectionTrace(enabled: Bool) -> Bool {
        guard detectionViewAllowed else { return false }
        detectQueue.async { [self] in
            traceEnabled = enabled
            curtain?.traceRecorder = enabled ? CurtainTraceRecorder() : nil
            if !enabled { detectionTraceBus.clear() }
            traceIdleSkipped = 0
            traceEvaluatedAt.removeAll()
            traceBuildOverBudget = false
            traceMirrorMismatch = false
        }
        return true
    }
    /// Main thread. Applied on detectQueue. Same headless refusal, and
    /// refused BY NAME while a crop writer is attached: a synthetic box must
    /// never become a crop (owner decision D3, 2026-09-24).
    @discardableResult
    func setSyntheticDetections(enabled: Bool) -> Bool {
        guard detectionViewAllowed else { return false }
        if enabled, cropWriter != nil {
            logger.event(
                DetectionViewEvent.lifecycle,
                "synthetic=refused reason=crop-writer-attached — synthetic boxes would reach "
                + "CropWriter (fix: run without the crop flag, Pipeline.setSyntheticDetections)")
            return false
        }
        detectQueue.async { [self] in
            syntheticDetectionsEnabled = enabled
            detectionFixture.reset()
        }
        return true
    }
    /// detectQueue-confined. "Show weak detections" (Detection view): the
    /// detector's NMS floor while the toggle is on, nil otherwise. Boxes
    /// between it and `--conf` come back as `Detector.Pass.weak`, which only
    /// the trace reads; `--conf` still decides every box protection sees.
    /// `SENTRY_WEAK_FLOOR` sets it at launch, in any mode, so a headless
    /// `--process` run can prove protection's logs do not move with it.
    private var weakFloor: Float? = Pipeline.weakFloorFromEnvironment()
    /// `SENTRY_WEAK_FLOOR`, refused by name (never clamped) unless it is a
    /// number in [`weakFloorMin`, `DetectionViewController.weakMax`).
    static func weakFloorFromEnvironment() -> Float? {
        guard let raw = DevEnv.knob("SENTRY_WEAK_FLOOR") else { return nil }
        let max = DetectionViewController.weakMax
        guard let v = Float(raw), v >= weakFloorMin, v < max else {
            FileHandle.standardError.write(Data(("sentry-screen: SENTRY_WEAK_FLOOR refused: configured=\(raw) "
                + "allowed=[\(weakFloorMin), \(max)) — weak detections stay off (fix: the environment)\n").utf8))
            return nil
        }
        return v
    }
    /// The lowest floor the toggle may set. 0.05: where the floor-vs-count
    /// probe was run (2026-09-25, M1 Mac, benign daemon/testdata/portrait.jpg,
    /// landscape.jpg and the gate's background.png: at most 2 boxes each even
    /// at 0.001, no measurable time cost); the model's NMS has no top-k or
    /// max-output field (checked with coremltools), so a lower floor adds
    /// boxes without evicting any. Below 0.05 the view is noise.
    static let weakFloorMin: Float = 0.05
    /// Main thread. Applied on detectQueue. nil turns weak boxes off; a
    /// value is clamped up to `weakFloorMin`. A floor at or over `--conf`
    /// (only when a dev run lowers `--conf` under the slider's 0.25 top)
    /// leaves nothing between the two: weak boxes go off and the refusal is
    /// logged by name. Same headless refusal as the trace.
    @discardableResult
    func setWeakDetections(floor: Float?) -> Bool {
        guard detectionViewAllowed else { return false }
        let conf = opts.conf
        let clamped = floor.map { max($0, Self.weakFloorMin) }
        if let f = clamped, f >= conf {
            logger.event("detection-view", "weak floor refused: configured=\(f) must be under --conf "
                + "observed=\(conf) — weak boxes off (fix: lower the slider or raise --conf)")
        }
        detectQueue.async { [self] in
            weakFloor = clamped.flatMap { $0 < conf ? $0 : nil }
        }
        return true
    }
    /// detectQueue. Trace bookkeeping between builds.
    /// Idle-gate skips since the last evaluated frame (the HUD's
    /// `idleSkipped`).
    private var traceIdleSkipped = 0
    /// Evaluated-frame times inside `traceFpsWindowSecs`, for the HUD's
    /// evaluated fps. Bounded by the capture rate × that window.
    private var traceEvaluatedAt: [CFAbsoluteTime] = []
    /// The HUD's evaluated-fps window. DERIVED: the overlay's clock ticks at
    /// 1 Hz, so a 1 s window is exactly what one HUD refresh can show.
    static let traceFpsWindowSecs: CFTimeInterval = 1.0
    private var traceSeq: UInt64 = 0
    /// The previous trace's whole cost (a trace cannot time itself);
    /// `DetectionTrace.Stats.traceMs`.
    private var traceLastMs = 0.0
    /// The previous trace's app-name lookup share (`Stats.lookupMs`).
    private var traceLastLookupMs = 0.0
    private var traceBuildOverBudget = false
    private var traceMirrorMismatch = false
    private let detectionFixture = DetectionFixture()
    private lazy var traceAppNames: DetectionTraceAppNames = {
        let names = DetectionTraceAppNames()
        names.onFull = { [logger = self.logger] in logger.event(DetectionViewEvent.lifecycle, $0) }
        return names
    }()

    /// detectQueue, from `step` and `holdCovers` while the trace is on:
    /// build this frame's trace from the step's own locals and publish it.
    /// Two tripwires, both loud once per episode and neither turns the view
    /// off: the whole trace's cost (`DetectionTraceBuilder.traceBudgetMs`:
    /// `startedAt` is before `traceInputs`, so `Curtain.traceWindows` is
    /// inside it; `walkCostMs` is the recorder's share of `Curtain.update`),
    /// and the policy mirror disagreeing with the step's `blocked` count.
    private func publishTrace(
        _ input: DetectionTraceBuilder.Inputs, blockedCount: Int?, startedAt: CFAbsoluteTime,
        walkCostMs: Double
    ) {
        // One memoized CGWindowList lookup per new window. A new window's first lookup can be cold (4-5 ms, MEASURED; receipt
        // at WindowOwner.p95BudgetMs, which governs it): shown in traceMs,
        // kept out of the trace tripwire.
        var apps: [CGWindowID: String] = [:]
        let lookupsStart = CFAbsoluteTimeGetCurrent()
        for w in input.windows { apps[w.id] = traceAppNames.name(w.id) }
        let lookupMs = (CFAbsoluteTimeGetCurrent() - lookupsStart) * 1000
        let out = DetectionTraceBuilder.build(input, builtAt: CFAbsoluteTimeGetCurrent(), appName: { apps[$0] })
        traceLastMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000 + walkCostMs
        traceLastLookupMs = lookupMs
        detectionTraceBus.publish(out.trace)
        if traceLastMs - lookupMs > DetectionTraceBuilder.traceBudgetMs {
            if !traceBuildOverBudget {
                traceBuildOverBudget = true
                logger.event(
                    DetectionViewEvent.lifecycle,
                    String(format: "trace-budget budget DetectionTraceBuilder.traceBudgetMs limit %.1f ms "
                        + "observed %.2f ms (curtain walk notes %.2f ms; app-name lookups %.2f ms not counted) "
                        + "boxes=%d windows=%d — the view "
                        + "stays on (fix: remeasure and re-receipt DetectionTraceBuilder.traceBudgetMs, "
                        + "or cheapen the trace)",
                        DetectionTraceBuilder.traceBudgetMs, traceLastMs - lookupMs, walkCostMs, lookupMs,
                        input.raw.count,
                        input.windows.count))
            }
        } else {
            traceBuildOverBudget = false
        }
        if let blockedCount, out.mirrorBlocked != blockedCount {
            if !traceMirrorMismatch {
                traceMirrorMismatch = true
                logger.event(
                    DetectionViewEvent.lifecycle,
                    "trace-mirror mismatch TuningPolicy.verdicts passes \(out.mirrorBlocked) boxes, "
                    + "the step blocked \(blockedCount) — region and curtain outcomes on this trace "
                    + "are unreliable (fix: TuningPolicy.verdicts must mirror TuningPolicy.filter)")
            }
        } else {
            traceMirrorMismatch = false
        }
    }

    /// detectQueue. The trace inputs every build shares.
    private func traceInputs(
        capturedAt: CFAbsoluteTime, inferStart: CFAbsoluteTime, detectEnd: CFAbsoluteTime
    ) -> DetectionTraceBuilder.Inputs {
        traceSeq &+= 1
        let now = CFAbsoluteTimeGetCurrent()
        traceEvaluatedAt.append(capturedAt)
        traceEvaluatedAt.removeAll { capturedAt - $0 > Self.traceFpsWindowSecs }
        let stats = DetectionTrace.Stats(
            evaluatedFps: Double(traceEvaluatedAt.count) / Self.traceFpsWindowSecs,
            detectMs: (detectEnd - inferStart) * 1000, stepMs: (now - inferStart) * 1000,
            idleSkipped: traceIdleSkipped, traceMs: traceLastMs, lookupMs: traceLastLookupMs)
        traceIdleSkipped = 0
        var windows: [(id: CGWindowID, frame: CGRect, state: DetectionTrace.CurtainWindow.State)] = []
        if let curtain, let windowTracker {
            windows = curtain.traceWindows(tracker: windowTracker, display: geometry.bounds, at: capturedAt)
        }
        return DetectionTraceBuilder.Inputs(
            seq: traceSeq, capturedAt: capturedAt, screenPt: screenSize, display: geometry.bounds,
            policy: effectivePolicy, coverMode: opts.cover.rawValue, tuning: tuning,
            // The launch policy's source, or the hot-reload tuning file when
            // the policy in force differs from it (the only other writer).
            tuningSource: tuning == opts.tuning ? opts.tuningSource : "tuning.json",
            blockFaces: opts.blockFaces, roi: opts.roi, conf: opts.conf, windows: windows, stats: stats)
    }
    /// Main thread. The Detection view's controller while it is attached to
    /// this pipeline (AppDelegate.startPipeline); weak, the UI owns it. The
    /// exclusion sites, the panic hold, `enterPause` and `shutdown` reach the
    /// view through it.
    weak var detectionView: DetectionViewController?
    /// Main thread. Every window capture must not see: the cover window and,
    /// while the Detection view is on, its window. All
    /// three `refreshExclusion` call sites pass this, so a turned-off view's
    /// id is gone from the very next request (a dead id would fail every
    /// later refresh's all-ids-present check). Production: exactly
    /// `overlays.windowNumbers`.
    var exclusionWindowNumbers: [Int] {
        return Self.exclusionWindowNumbers(
            covers: overlays.windowNumbers, detectionView: detectionView?.excludedWindowNumber)
    }
    /// Pure, so the Detection view's self-test checks the same rule.
    static func exclusionWindowNumbers(covers: [Int], detectionView: Int?) -> [Int] {
        covers + (detectionView.map { [$0] } ?? [])
    }
    /// Main thread. A pause (panic, parent, SIGUSR2) turns the
    /// Detection view off and refuses turning it on.
    var isPausedForDetectionView: Bool { suppressed }
    /// Main thread, synchronous: repaint the newest held covers now that
    /// Detections only has handed painting back. The same two sync calls
    /// the frame and curtain-tick sites make, behind the same guards (a
    /// pause still wins; a frame from a rebuilt stream is not replayed).
    func restoreCoversForDetectionView() {
        guard opts.overlays, !suppressed, !detectionViewSuppressesCovers else { return }
        let created = detectionViewHeldPaint.replay(
            isCurrent: { capture?.isCurrentGeneration($0) ?? false },
            sync: { [regionsReleased] f in
                overlays.sync(
                    regionsReleased ? [] : f.regions, painted: regionsReleased ? [] : f.painted,
                    anchors: regionsReleased ? [] : f.anchors, capturedAt: f.capturedAt,
                    curtains: f.curtains, curtainOwners: regionsReleased ? [:] : f.owners)
            },
            syncCurtains: { overlays.syncCurtainState($0.curtains, at: $0.at) })
        if created {
            capture.refreshExclusion(windowNumbers: exclusionWindowNumbers)
            detectionView?.coverWindowCreated(overlays.windowNumbers.first)
        }
    }
    /// Sensitivity with no settings override in force: the tail of the §6
    /// precedence chain. Same expression `effectivePolicy` starts from, kept
    /// as one stored value so the picker and the detector cannot drift.
    let basePolicy: PolicyMode
    /// Main-thread mirror of `effectivePolicy` for change detection.
    /// `effectivePolicy` itself is detectQueue-confined, so reading it from
    /// main to decide whether to log would be a race.
    private var policyOnRecord: PolicyMode
    /// True when `--policy` pinned this run (spec §6: flags win, D1).
    var policyPinnedByFlag: Bool { opts.policy != nil }
    private var warnedPinnedOverride = false

    /// Every fps-derived value this pipeline uses, resolved ONCE from the
    /// effective fps at construction (PerfTier.Derived). Resolving once rather
    /// than per frame is not an optimisation — it is what makes "this run used
    /// these numbers" a fact the `startup` record can state, instead of
    /// something recomputed on a path nobody logs.
    let derived: PerfTier.Derived

    /// `quiet` silences the per-detection stdout line (pixel replay logs
    /// thousands of frames as fast as inference allows).
    init(opts: Options, displayTarget: DisplayTarget? = nil, quiet: Bool = false) throws {
        self.opts = opts
        self.displayTarget = displayTarget
        self.derived = PerfTier.Derived(fps: opts.fps)
        self.detector = try Detector(modelPath: opts.model)
        // Real live run only: `--process` (pixel replay, incl. the gate) and
        // `--replay` never construct a Pipeline through this initializer path
        // with capture/overlays live.
        let live = opts.process == nil && opts.replay == nil && opts.overlays
        // Deliberately NOT `live`: the memory tripwire only needs "not a
        // fixture replay", unlike windowTracker/curtain/paintLog below, which
        // genuinely need a real overlay on a real screen and so also require
        // opts.overlays. A `--no-overlays` live run — the shape a headless
        // soak-test or a perf measurement run typically takes — still has
        // real process memory worth watching; gating it on `live` would
        // silently turn the tripwire off exactly where a leak matters most.
        // Still false for every `--process`/`--replay` run, so the gate
        // baseline is untouched either way.
        let liveProcess = opts.process == nil && opts.replay == nil
        // ORDER IS LOAD-BEARING (2026-09-11; re-stated after the
        // 2026-09-12 fix, which satisfied the old wording and then removed it).
        // `try Detector(...)` above is the ONLY throwing call that can escape
        // this initializer (the `try CropWriter` below is inside a do/catch),
        // so it runs BEFORE this logger exists and a failed Pipeline init
        // writes nothing from here itself.
        //
        // That used to be the whole protection: `packaging/watchdog.sh` skipped
        // freshness judgement while `mtime < started`. A later fix deleted that
        // exemption — an absent run.jsonl is now judged as `observed=missing`,
        // and a completed install does not park under `waiting_for_parent` — so
        // the protection is ACTIVE now, not passive: `startPipeline`'s catch
        // arms `HoldHeartbeat.pipelineFailed`, whose own FrameLogger keeps
        // mtime moving while a parent looks at the repair UI.
        //
        // STILL A TRIPWIRE, for the opposite reason it was before: do NOT add a
        // throwing call BELOW this line without revisiting that catch. Past
        // this point the process HAS opened run.jsonl, and the catch's
        // `existing ?? FrameLogger(...)` sees `holdHeartbeat == nil` on a first
        // launch, so it would roll and truncate the same path a SECOND time in
        // one process — spending a generation on a run that never started.
        let frameLogger = FrameLogger(
            path: opts.logPath, quiet: quiet || opts.quiet, mode: opts.logMode,
            live: liveProcess)
        self.logger = frameLogger
        var cropWriter: CropWriter?
        if let path = opts.devCropDir {
            do {
                cropWriter = try CropWriter(directory: path) {
                    info in frameLogger.event("cropDump", info)
                }
            } catch {
                frameLogger.event(
                    "cropDump", "disabled=true reason=\(error.localizedDescription)")
            }
        }
        self.cropWriter = cropWriter
        if let path = opts.devCropDir, cropWriter != nil {
            frameLogger.event(
                "cropDump",
                "enabled dir=\(path) maxFiles=\(CropWriter.maxFiles) "
                    + "maxBytes=\(CropWriter.maxBytes) maxPendingJobs=\(CropWriter.maxPendingJobs)")
        }
        // Budget for the OFF-by-default performance-tier tripwire (receipt at
        // FrameLogger.perfTripwireEnabled). Gated on `liveProcess` so a
        // `--process`/`--replay` logger never carries a budget at all, on top
        // of the tripwire's own `live` and env gates.
        if liveProcess {
            self.logger.perfInferBudgetMs = 1000.0 / Double(opts.fps)
            self.logger.tierName = opts.tier.name.rawValue
        }
        self.tracker = Tracker(
            clearAfter: opts.clearFrames,
            stickyHold: Tracker.defaultStickyHold(fps: opts.fps),
            mediaHoldFrames: opts.cover == .media ? opts.mediaHoldFrames : 0)
        self.tuning = opts.tuning
        self.tuningOnRecord = opts.tuning
        // The launch tuning (defaults, or config.json's `tuning`): the two
        // fps-scaled holds come from its durations, `--clear-frames` still
        // pins clearAfter. At the default tuning this is exactly the
        // constructor's own arithmetic.
        self.tracker.setTuning(opts.tuning, fps: opts.fps, clearAfterOverride: opts.clearFramesOverride)
        // Curtain mode's region covers wait for a second consecutive detector
        // frame (owner decision 2026-09-02, receipt at
        // Tracker.confirmedEntries; per class since 2026-09-10). Keyed on the
        // CONFIGURED cover, so a headless `--process --cover curtain` replay
        // measures the cost.
        if opts.cover == .curtain { self.tracker.curtainEntry = true }
        self.motionBoxes = opts.cover == .media ? MotionBoxes(fps: opts.fps) : nil
        self.windowTracker = live && opts.windowTrack ? WindowTracker() : nil
        // Curtain needs live OS window geometry; headless or with tracking
        // off it degrades to plain region behavior, loudly (same contract as
        // media mode under --replay).
        if opts.cover == .curtain {
            if live && opts.windowTrack {
                self.curtain = Curtain()
                // Attribution-walk cadence in the tier's own frame interval
                // (receipt at Curtain.walkHz): 3 at 30 fps, unchanged.
                self.curtain?.walkEvery = Curtain.walkEvery(fps: opts.fps)
                self.curtain?.fps = opts.fps
                self.curtain?.tuning = opts.tuning
            } else {
                self.curtain = nil
                let warning = "curtain mode needs a live run with window tracking on; "
                    + "degrading to region covers\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
        } else {
            self.curtain = nil
        }
        self.basePolicy = opts.policy ?? (self.curtain != nil ? .standard : .strict)
        self.effectivePolicy = self.basePolicy
        self.policyOnRecord = self.basePolicy
        // The effective policy varies by mode, flag, and degradation; a run's
        // log must be able to answer "which classes were blocking" (review
        // 2026-08-19, P3).
        logger.event("policy", "effective=\(effectivePolicy.rawValue) cover=\(opts.cover.rawValue)")
        // One `tuning` record per launch AND per swap (setTuning): a log must
        // be able to answer "which numbers were in force" without the
        // config file it was run against.
        logger.event("tuning", "source=\(opts.tuningSource) effective=\(opts.tuning.jsonString())")
        self.coverOwnership = live && opts.windowTrack ? CoverOwnership() : nil
        // Pin growth and re-measure window in the tier's own frame interval
        // (receipts at CoverOwnership.pinGrowCells / pinRemeasureUpdates):
        // at 30 fps these are bit-identical to the old literals.
        self.coverOwnership?.pinGrowCells = derived.pinGrowCells
        self.coverOwnership?.pinRemeasureUpdates = derived.pinRemeasureUpdates
        // Motion lead and the smoother's size cap, likewise (receipts at
        // OverlayManager.leadFrames / PaintSmoother.capCells). Set on EVERY
        // run, not just live ones: `--process` logs `painted`, which is this
        // smoother's output, so a headless replay at a non-default fps must
        // use that fps's values too.
        self.paintSmoother.leadFrames = derived.leadFrames
        self.paintSmoother.capCells = derived.capCells
        self.overlays.extrapolate = live && opts.windowTrack
        // Velocity horizon in the tier's own frame interval (receipt at
        // PaintExtrapolator.maxVelocityHorizonFrames). Set here, once, before
        // any paint: at 30 fps this is bit-identical to the old literal.
        self.overlays.extrapolator.maxVelocityHorizon = derived.velocityHorizonSecs
        // Same expression as before, now in one place that can be re-read:
        // `--display`'s screen, else NSScreen.screens.first, else nothing.
        self.geometry = DisplayGeometry.current(displayID: displayTarget?.id)
        self.overlays.onTripwire = { [logger] info in logger.event("tripwire", info) }
        self.overlays.onCurtainEvent = { [logger] info in logger.event("curtain", info) }
        // Paint truth, live only: the census must verify the rects the overlay
        // actually painted rather than extract them from pixels.
        // Measurement only — nothing reads
        // it back, and `--process` exits before this line is ever reached.
        if live {
            self.overlays.paintLog = { [logger] t, id, rect, source in
                logger.recordPaint(at: t, regionID: id, frame: rect, source: source)
            }
        }
        self.windowTracker?.onQuickLookIdentity = { [logger] id, pid in
            logger.event("quick-look", "outer-window=\(id) owner-pid=\(pid)")
        }
        self.overlays.windowTracker = windowTracker
        // nil when displayTarget is nil, which is exactly "use
        // NSScreen.screens.first / assume local origin == global origin" --
        // the prior, single-display-only behavior, unchanged.
        self.overlays.targetScreen = displayTarget?.screen
        self.overlays.targetScreenOrigin = displayTarget?.bounds.origin
        // Ownership changes are loud, on stderr and in the log: a cover that
        // stops riding its window is a visible behavior change and must be
        // explainable from the run's own output, never inferred.
        self.coverOwnership?.onDrop = { [logger] info in
            FileHandle.standardError.write(Data("cover-ownership: \(info)\n".utf8))
            logger.event("cover-ownership", info)
        }
        // Curtain drops and lifts are loud for the same reason ownership
        // changes are: a whole-window cover must be explainable from the
        // run's own output.
        // The lookup runs here on detectQueue, on drop only; lift reads
        // the memo. Its cost is receipted at WindowOwner.p95BudgetMs.
        self.curtain?.onChange = { [logger, weak self] action, id in
            let app = WindowOwner.name(of: id, action: action) { logger.event("curtain-app", $0) }
            FileHandle.standardError.write(Data("curtain: \(action) window \(id)\n".utf8))
            // Drops carry pixels-on-glass → decision latency (currentFrameAt
            // is stamped by curtainRects on this same thread just before
            // curtain.update fires this).
            let latency = action.hasPrefix("drop") && (self?.currentFrameAt ?? 0) > 0
                ? String(format: " latencyMs=%.0f",
                         (CFAbsoluteTimeGetCurrent() - self!.currentFrameAt) * 1000)
                : ""
            logger.event("curtain", "\(action) window \(id)" + (app.map { " app=\($0)" } ?? "") + latency)
            self?.tuningReadout?.recordCurtain(action: action, windowID: id, app: app, now: CFAbsoluteTimeGetCurrent())
            if action.hasPrefix("drop") {
                self?.onCurtainDrop?(ActivityItem(app: app ?? ActivityItem.unknownApp, at: Date(), uid: getuid()))
            }
            // Successor-linger accounting (receipt at `Curtain.successorLinger`)
            // so a run's `-- summary:` line says how often a close revealed a
            // window and WHICH signal ended the hold — the share that leaves on
            // the ceiling is the number that says whether 0.5 s still fits.
            // Prefix-keyed like the `drop` branch above; the labels are asserted
            // in `--ui-selftest`.
            switch true {
            case action.hasPrefix("linger (successor"):
                logger.count("curtainSuccessorLinger")
            case action.hasPrefix("lift (successor curtained"):
                logger.count("curtainSuccessorLiftCurtained")
            case action.hasPrefix("lift (successor clean"):
                logger.count("curtainSuccessorLiftClean")
            case action.hasPrefix("lift (successor ceiling"):
                logger.count("curtainSuccessorLiftCeiling")
            default: break
            }
        }
        if cropWriter != nil {
            tracker.onBirth = { [weak self] region, _, sourceIndex in
                guard let self else { return }
                guard cropBlockedThisFrame.indices.contains(sourceIndex) else {
                    logger.event(
                        "cropDump",
                        "attribution=region-index skipped=true index=\(sourceIndex) "
                            + "count=\(cropBlockedThisFrame.count)")
                    return
                }
                cropRequestsThisFrame.append(CropWriter.Request(
                    kind: .regionBirth, detection: cropBlockedThisFrame[sourceIndex],
                    regionID: region.id, windowID: nil))
            }
            curtain?.onDrop = { [weak self] _, id, window, sourceIndices in
                guard let self else { return }
                var indices = sourceIndices
                if indices.isEmpty {
                    indices = cropBlockedThisFrame.indices.filter { index in
                        guard let window else { return false }
                        let rect = self.screenRect(self.cropBlockedThisFrame[index].box)
                        return window.contains(CGPoint(x: rect.midX, y: rect.midY))
                    }
                    logger.event(
                        "cropDump",
                        "attribution=window-rect window=\(id) detections=\(indices.count)")
                }
                for index in indices where cropBlockedThisFrame.indices.contains(index) {
                    cropRequestsThisFrame.append(CropWriter.Request(
                        kind: .curtainDrop, detection: cropBlockedThisFrame[index],
                        regionID: nil, windowID: id))
                }
            }
            curtain?.onCropEvent = { [logger] info in logger.event("cropDump", info) }
        }
        // A pin limit that actually clipped an update reports itself the same
        // way: budget name, configured value, observed value, where to change
        // it. Same channel as a drop — a run's own output has to explain both.
        self.coverOwnership?.onLimit = { [logger] info in
            FileHandle.standardError.write(Data("cover-ownership: \(info)\n".utf8))
            logger.event("cover-ownership", info)
        }
        self.capture = CaptureStream { [weak self] frame in self?.process(frame) }
        // Capture lifecycle — sleep, wake, an unexpected stop, a re-arm — is
        // loud for the same reason a curtain drop is: a run that lost its eyes
        // for a while has to say so in its own output. CaptureStream only ever
        // calls this from a started stream, which `--process` never has.
        self.capture.onState = { [logger] info in logger.event("capture", info) }
        // Display scope (2026-09-11): the tripwire record, the
        // coordinate-space check, and the parent UI's copy of the scope. Was a
        // stderr WARNING and nothing else.
        self.capture.onDisplayScope = { [weak self] scope in
            guard let self else { return }
            self.acceptCapturedDisplayScope(scope)
        }
        // E2 / idle-CPU (MEASURED 2026-08-22): capture stops on suspend but
        // the WindowTracker is frame-driven, so while suspended it keeps
        // polling its last set at 120 Hz — wasted CPU on an inactive user's
        // session and a frozen stale cover (apiFailed tripwire). Drop the
        // tracked set on suspend; the first frame after resume repopulates it
        // via curtainRects/setTracked. Covers stay as painted (fail-safe) —
        // an inactive session's overlay is off-screen anyway.
        self.capture.onSuspendedChange = { [weak self] suspended in
            guard let self else { return }
            // Serialize on detectQueue so this lands AFTER any in-flight
            // frame's `curtainRects → setTracked(ids)` (both run on detectQueue),
            // else a late frame would repopulate the stale set we just cleared
            // and the 120 Hz poll would resume (2026-08-22).
            // `captureSuspended` then early-returns `process()` for as long as
            // the session is inactive, so nothing re-adds until resume.
            self.detectQueue.async {
                self.captureSuspended = suspended
                if suspended {
                    self.captureFrameReceiptValid = false
                    self.curtainCaptureGeneration = nil
                    self.windowTracker?.setTracked([])
                }
            }
        }
        // CG-global (top-left origin) bounds, NOT the AppKit frame: this feeds
        // CoverOwnership.onScreen()'s containment test against covers that are
        // also in CG-global space (screenRect below). For the main display the
        // two numerically coincide (both (0,0,W,H)); for anything else they do
        // not, and using the AppKit frame here would make onScreen() reject
        // everything on a display like the iPad-Sidecar lab's, whose global
        // origin is negative.
        windowTracker?.screenFrame = geometry.bounds
        // Live: the poll-cadence receipt goes into the rotated log as a
        // "sched" record, on change only (receipt at WindowTracker.liveReceiptEvery).
        windowTracker?.onReceipt = { [logger] line in logger.event("sched", line) }
        windowTracker?.onTripwire = { [logger] line in logger.event("tripwire", line) }
        windowTracker?.start()
        startDetectDeadlineTimer()
        // Diagnostic prints reach the structured, rate-limited "media-diag"
        // path only on a real live run; fixture replay/--replay stay on bare
        // stdout so the gate's environment is untouched (receipt at
        // mediaDiagPerWindow). Last in init: the closures capture self.
        if liveProcess {
            tracker.onDiagnostic = { [weak self] line in self?.mediaDiag(line) }
            motionBoxes?.onDiagnostic = { [weak self] line in self?.mediaDiag(line) }
        }
    }

    func start() {
        registerHotkeys()
        // display geometry would otherwise be frozen at init for the
        // whole process lifetime. Live only — `--process` never reaches here,
        // so no headless log can move.
        let watcher = DisplayTopologyWatcher(
            geometry: geometry,
            read: { [displayTarget] in DisplayGeometry.current(displayID: displayTarget?.id) },
            onDecision: { [weak self] decision in self?.applyDisplayChange(decision) })
        watcher.start()
        displayWatcher = watcher
        // Create and own the timer synchronously with the rest of Pipeline
        // lifecycle. Its event cannot act until a valid capture receipt and
        // active curtain state both exist.
        startCurtainTick()
        // Live only (never on --process/--replay): the main run loop is what
        // drives it, and headless runs never pause.
        pauseTimer = Self.schedulePauseTimer { [weak self] in
            self?.refreshPauseState()
        }
        // Idle summary tick (FrameLogger.idleTick): closes a 60 s window
        // that saw no frames so paused/suspended/static minutes still get a
        // summary with the process's RSS/CPU. Same cadence as the summary
        // itself; the logger drops it when the window is not due.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = self.appliedPause ? "paused"
                : self.capture?.isLive == false ? "suspended" : "idle"
            self.detectQueue.async { self.logger.idleTick(state: state) }
        }
        // Self-describing paint truth: `paints` rects are in screen points, and
        // a census scoring a 1280-wide recording of a 1920-pt screen needs the
        // divisor from the run itself rather than from a constant in a script.
        logger.event(
            "screen",
            String(format: "points=%.1fx%.1f", screenSize.width, screenSize.height))
        Task {
            // Display-wait loop (receipt at displayWaitPollSecs): start() throws
            // NoDisplayAvailable when SCShareableContent vends nothing yet — a
            // headless boot, every display asleep, or a remote-desktop session
            // (Jump Desktop) not connected at launch. Before this the launch
            // exited 2 and leaned on the watchdog's next pass to relaunch (up
            // to a 60 s gap, MEASURED 2026-08-25); now the process stays
            // resident and re-attempts until a display appears, then
            // seedSuspendState decides active vs park. Any OTHER start error
            // stays fatal.
            var displayPolls = 0
            capture.extraExcluded = opts.excludeWindows
            waitForDisplay: while true {
                do {
                    try await capture.start(
                        fps: opts.fps, width: opts.width, requestedDisplayID: displayTarget?.id)
                    break waitForDisplay
                } catch is CaptureStream.NoDisplayAvailable {
                    if capture.isStopping { return }
                    if displayPolls % Self.displayWaitLogEvery == 0 {
                        logger.event("capture", "state=waiting no display to capture yet — "
                            + "re-attempting every \(Int(Self.displayWaitPollSecs))s until one "
                            + "appears (remote session not connected, or displays asleep) "
                            + "(fix: Pipeline.displayWaitPollSecs)")
                    }
                    displayPolls += 1
                    try? await Task.sleep(for: .seconds(Self.displayWaitPollSecs))
                    // Re-check after the sleep: a shutdown landing mid-sleep
                    // must not be followed by a successful start() — a stream
                    // half-started during teardown (review 2026-08-25).
                    if capture.isStopping { return }
                } catch {
                    let reason = "capture start failed: \(error)"
                    if let onCaptureStartFailure {
                        DispatchQueue.main.async { onCaptureStartFailure(reason) }
                        return
                    }
                    die(reason, code: 2)
                }
            }
            if displayPolls > 0 {
                logger.event("capture", "state=restored a display appeared after "
                    + "\(displayPolls) poll(s) — capture starting")
            }
            // Shielded harness: apply the extra exclusion NOW, before the first
            // frame reaches the detector, not lazily on overlay creation.
            if !opts.excludeWindows.isEmpty {
                capture.refreshExclusion(windowNumbers: exclusionWindowNumbers)
            }
            // Hook 5 (.protecting) fires on the first valid FRAME — see
            // captureProducedFirstFrame / the frame-delivery hook — not here.
            print(
                "running: fps=\(opts.fps) width=\(opts.width) conf=\(opts.conf) "
                + "clearFrames=\(opts.clearFrames) overlays=\(opts.overlays) "
                + "cover=\(opts.cover.rawValue)"
                + (opts.cover == .media
                    ? " mediaHold=\(opts.mediaHoldSecs)s (\(opts.mediaHoldFrames) frames)"
                    : "")
                + " ttl=\(opts.ttl == 0 ? "off" : "\(opts.ttl)s") model=\(opts.model)"
                + (displayTarget.map { " display=\($0.id)@\(Int($0.bounds.origin.x)),"
                    + "\(Int($0.bounds.origin.y))+\(Int($0.bounds.width))x"
                    + "\(Int($0.bounds.height))" } ?? ""))
            print("panic: \(HotkeyCenter.panicKey.label)  "
                + "inject: \(opts.devInject ? HotkeyCenter.injectKey.label : "off (\(DevSignals.flag))")  "
                // So "does SIGUSR2 do anything here?" is answerable from the
                // banner instead of by sending one (DevSignals.swift).
                + "dev signals: \(DevSignals.armed(devInject: opts.devInject) ? "armed" : "inert (\(DevSignals.flag))")")
        }
    }

    /// What one pass hands back to the caller — named so the held copy
    /// (`heldStep`) can be stored in a field.
    typealias StepResult = (
        regions: [TrackedRegion], painted: [CGRect],
        anchors: [PaintExtrapolator.Anchor], curtains: [(id: UInt32, rect: CGRect, attr: CGRect)],
        curtainOwners: [Int: UInt32]
    )
    static let emptyStep: StepResult = ([], [], [], [], [:])

    /// Development detector fault injection (receipt at
    /// `DetectorWatch.injectedFault`).
    private static func injectDetectorFaultIfRequested() throws {
        if DetectorWatch.injectedFault.skipLeft > 0 {
            DetectorWatch.injectedFault.skipLeft -= 1
            return
        }
        if DetectorWatch.injectedHangSecs > 0 {
            let secs = DetectorWatch.injectedHangSecs
            DetectorWatch.injectedHangSecs = 0
            Thread.sleep(forTimeInterval: secs)
        }
        guard DetectorWatch.injectedFault.errorsLeft > 0 else { return }
        DetectorWatch.injectedFault.errorsLeft -= 1
        throw SentryError(
            "SENTRY_FAKE_DETECTOR_ERRORS: injected detector fault "
            + "(\(DetectorWatch.injectedFault.errorsLeft) left)")
    }

    /// detectQueue. One frame the detector could not answer: keep the covers
    /// that were on screen, and say so by name. Never silent — the per-frame
    /// `detectorHoldFrames` counter reaches every 60 s summary, the loud record
    /// fires on the edge, and the parent UI turns once the streak is past the
    /// threshold.
    private func holdCovers(
        at now: CFAbsoluteTime, capturedAt: CFAbsoluteTime, inferStart: CFAbsoluteTime,
        frameIndex: Int?
    ) -> StepResult {
        logger.count("detectorHoldFrames")
        // One ordinary frame record, carrying the HELD covers and `held: 1`
        // (receipt at FrameRecord.held). Early-returning without it would drop
        // the frame from the log entirely — a silent gap exactly where the
        // evidence matters, and the one thing the repo's rules forbid.
        //
        // One exception, ACCEPTED (review 2026-09-11): in `lean` mode a held
        // frame with nothing to hold — a detector broken from launch, so empty
        // `regions`/`curtains` and a live `painted: nil` — still meets the
        // mode's `clean` test and is collapsed into the 60 s summary past the
        // linger. Making `held` force full fidelity would log every frame of a
        // permanent outage at 30 fps with no measured bound, to add a marker
        // whose information is already loud three other ways: the
        // `detectorHoldFrames` count in every summary, the `state=failing`
        // event (events are never suppressed), and the alerts.log ALERT.
        logger.log(
            detections: [], regions: heldStep.regions,
            inferMs: (now - inferStart) * 1000, totalMs: (now - capturedAt) * 1000,
            frame: frameIndex,
            painted: frameIndex == nil ? nil : heldStep.painted,
            curtains: heldStep.curtains.isEmpty
                ? nil
                : heldStep.curtains.map { entry in
                    FrameLogger.CurtainRecord(
                        wid: Int(entry.id),
                        box: [entry.rect.minX, entry.rect.minY, entry.rect.width, entry.rect.height]
                            .map { (Double($0) * 1000).rounded() / 1000 })
                },
            held: true)
        if traceEnabled {
            let traceStart = CFAbsoluteTimeGetCurrent()
            var input = traceInputs(capturedAt: capturedAt, inferStart: inferStart, detectEnd: now)
            input.detectorFailed = true
            publishTrace(input, blockedCount: nil, startedAt: traceStart, walkCostMs: 0)
        }
        // Only the frame that CROSSES the threshold is loud; the rest of a
        // failure is the `detectorHoldFrames` counter above.
        if case let .began(since, errors) = detectorWatch.noteError(at: Date()) {
            logger.event(
                "detector",
                "state=failing budget DetectorWatch.failingStreak, limit "
                + "\(DetectorWatch.failingStreak) consecutive frames, observed \(errors) — "
                + "covers on screen are HELD and new content is NOT being checked since "
                + "\(UISettings.iso.string(from: since))"
                + (frameIndex.map { " frame=\($0)" } ?? "")
                + " (fix: the detector model — config.json `model` — or "
                + "DetectorWatch.failingStreak if a healthy run reaches this)")
            let health = detectorWatch.health
            if let onDetectorHealth { DispatchQueue.main.async { onDetectorHealth(health) } }
        }
        return heldStep
    }

    /// detectQueue. The bracket closed (the call returned or threw). If the
    /// watchdog published a stall for it, say the detector is answering again
    /// and republish the streak verdict; if the call overran without a tick
    /// catching it (a late timer), still leave the named record — a breach is
    /// never silent.
    private func endDetectDeadline(at now: CFAbsoluteTime) {
        let fin = detectDeadline.end(at: now)
        if fin.stallWasPublished {
            logger.event(
                "detector",
                "state=stall-cleared the detect call returned after "
                + "\(String(format: "%.1f", fin.elapsedSecs)) s")
            let health = detectorWatch.health
            if let onDetectorHealth { DispatchQueue.main.async { onDetectorHealth(health) } }
        } else if fin.elapsedSecs > DetectDeadline.limitSecs {
            logger.event("detector", Self.stallText(observed: fin.elapsedSecs, since: nil))
        }
    }

    private static func stallText(observed: Double, since: CFAbsoluteTime?) -> String {
        "state=stalled budget DetectDeadline.limitSecs, limit "
            + "\(String(format: "%.0f", DetectDeadline.limitSecs)) s, observed "
            + "\(String(format: "%.2f", observed)) s"
            + (since.map { " since \(UISettings.iso.string(from: Date(timeIntervalSinceReferenceDate: $0)))" } ?? "")
            + " — one detector call has not returned; new content is NOT being checked "
            + "(fix: the detector model — config.json `model` — or DetectDeadline.limitSecs "
            + "if a healthy run reaches this)"
    }

    /// Every mode (`--process` runs `step` on the main thread, so the timer
    /// cannot live there). Its own queue: `detectQueue` is what a hung call
    /// blocks. The publish hops to main and re-checks `isStalled` there, so a
    /// recovery that already queued its own republish is never overwritten by
    /// a late `.failing`.
    private func startDetectDeadlineTimer() {
        guard detectDeadlineTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: Self.detectDeadlineQueue)
        timer.schedule(
            deadline: .now() + DetectDeadline.tickSecs, repeating: DetectDeadline.tickSecs)
        timer.setEventHandler { [weak self] in self?.detectDeadlineTick() }
        timer.resume()
        detectDeadlineTimer = timer
    }

    private static let detectDeadlineQueue =
        DispatchQueue(label: "sentryscreen.detect-deadline", qos: .utility)

    private func detectDeadlineTick() {
        guard let stall = detectDeadline.check(at: CFAbsoluteTimeGetCurrent()) else { return }
        logger.event("detector", Self.stallText(observed: stall.observedSecs, since: stall.since))
        let health = DetectorHealth.failing(
            since: Date(timeIntervalSinceReferenceDate: stall.since))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.detectDeadline.isStalled else { return }
            self.onDetectorHealth?(health)
        }
    }

    /// detectQueue. The detector answered: clear the streak, and publish the
    /// recovery edge if there was one. Recovery is immediate by receipt — see
    /// `DetectorWatch.noteSuccess`.
    private func noteDetectorSuccess() {
        switch detectorWatch.noteSuccess() {
        case .ready:
            logger.event("detector", "state=healthy source=first-result — the detector answered")
        case let .recovered(afterErrors):
            logger.event("detector", "state=recovered observed \(afterErrors) consecutive failing frames — the detector is answering again; covers resume tracking this frame")
        default:
            return
        }
        let health = detectorWatch.health
        if let onDetectorHealth { DispatchQueue.main.async { onDetectorHealth(health) } }
    }

    /// Main thread. TRIPWIRE: does the display capture actually chose match the
    /// display this pipeline's geometry is expressed in? (2026-09-11,
    /// SUSPECTED, and NOT closed: detected and reported,
    /// closure deferred with multi-display capture itself.)
    ///
    /// `Capture.start` picks `SCShareableContent.displays.first`; everything
    /// downstream — `screenSize`, `screenRect`, `normalizeCurtains`, the curtain
    /// display rect, `WindowTracker.screenFrame` and the overlay window — is
    /// expressed against `NSScreen.screens.first` when there is no `--display`.
    /// Neither order is documented and nothing checked that they agree.
    ///
    /// Deliberately reports instead of pinning (review 2026-09-11). Moving the
    /// overlay window alone onto the captured display — the first version of
    /// this method — would have left the overlay painting in one display's
    /// coordinate space while the pipeline normalized window frames in the
    /// other's, so `Overlay.syncCurtains` would union a correctly placed live
    /// rect with one displaced by the whole inter-display offset. A mixed
    /// coordinate space on the cover path is worse than a consistent one, and
    /// making the pipeline follow means resolving `screenSize`, the curtain
    /// display rect and the tracker's screen frame from the captured display on
    /// `detectQueue` — multi-display work, explicitly out of this PR's scope
    /// (MVP = accurate status, not multi-display support). So: one named record,
    /// no silent half-move.
    ///
    /// Writes nothing in any configuration that works today: `--display` pins
    /// both sides to the same id, and on a single-display Mac the captured
    /// display IS `NSScreen.screens.first`.
    private func reportCapturedDisplayScope(_ scope: DisplayScope) {
        guard displayTarget == nil else { return }
        let pipelineScreen = NSScreen.screens.first
        guard let captured = CaptureStream.screen(for: scope.protectedDisplayID) else {
            logger.event(
                "capture",
                "state=display-unidentified protected=\(scope.protectedDisplayID) has no matching "
                + "NSScreen — the pipeline and the overlay are working in "
                + "NSScreen.screens.first's coordinate space, which may be a different display "
                + "(fix: Pipeline.reportCapturedDisplayScope)")
            return
        }
        guard captured != pipelineScreen else { return }
        logger.event(
            "capture",
            "state=display-space-mismatch captured=\(scope.protectedDisplayID) "
            + "pipeline=\(Self.displayID(of: pipelineScreen).map(String.init) ?? "none") — capture "
            + "is analysing one display while every cover rect is normalized against another; "
            + "covers on this Mac are displaced by the inter-display offset "
            + "(fix: resolve Pipeline.screenSize and the curtain display rect from the captured "
            + "display — deferred with multi-display capture)")
    }

    /// The `CGDirectDisplayID` behind an `NSScreen`, the inverse of
    /// `CaptureStream.screen(for:)`. nil only if AppKit vends a screen with no
    /// `NSScreenNumber`, which is not a documented state — hence Optional
    /// rather than a fabricated 0.
    static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// One full pipeline pass over one frame: detect -> media boxes -> policy
    /// -> tracker -> log. Synchronous and self-contained, so live capture runs
    /// it on detectQueue and `--process` (pixel replay) runs it straight from
    /// the decode loop — the same code path, no capture and no overlay.
    /// `frameIndex` non-nil marks replay: the record then carries `frame` and
    /// `painted`. Returns the tracked regions for the caller to paint — or, for
    /// a frame the detector could not answer, the previous answered frame's
    /// (`holdCovers`).
    /// `recheck`: this is the frame the screen settled on (`SettleWatch`),
    /// so the detector also runs on a shifted copy (`settleShiftPx`).
    @discardableResult
    func step(
        _ pixelBuffer: CVPixelBuffer, capturedAt: CFAbsoluteTime, frameIndex: Int? = nil,
        recheck: Bool = false
    ) -> StepResult {
        let inferStart = CFAbsoluteTimeGetCurrent()
        var detections: [Detection]
        // Boxes under `--conf` (Detection view): the trace
        // draws them, and nothing else in this step ever reads them.
        var weak: [Detection] = []
        var detectEnd = inferStart
        var zoomRecord: FrameLogger.ZoomRecord?
        let nmsFloor = weakFloor
        // Zoom (tiling) prototype, Developer tab `zoomTiles` (receipts at
        // `ZoomTiles`): one tile of the 2 × 2 grid per evaluated frame, in
        // rotation, run on the full pass's handler (`Detector.detect(tile:)`).
        var zoomTile: (index: Int, region: CGRect)?
        if tuning.zoomTiles {
            let index = zoomNextTile
            zoomNextTile = ZoomTiles.next(after: index)
            zoomTile = (index, ZoomTiles.region(
                index: index, width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)))
        }
        detectDeadline.begin(at: inferStart)
        do {
            try Self.injectDetectorFaultIfRequested()
            var pass = try detector.detect(
                pixelBuffer, minConfidence: opts.conf, nmsFloor: nmsFloor, tile: zoomTile?.region)
            let passMs = (CFAbsoluteTimeGetCurrent() - inferStart) * 1000
            if recheck {
                // Settle re-check (receipt at `settleShiftPx`): one more pass
                // on the same frame, shifted, higher score per box. No weak
                // pass: the merge reads only `kept`, so the cost stays one
                // detector pass with "Show weak detections" on too.
                let recheckStart = CFAbsoluteTimeGetCurrent()
                let shifted = try detector.detect(
                    pixelBuffer, minConfidence: opts.conf, nmsFloor: nil, shiftPx: Self.settleShiftPx)
                let merged = Self.mergeRecheck(pass, shifted.kept)
                pass = merged.pass
                logger.count("settleRechecks")
                if merged.raised > 0 { logger.count("settleRecheckRaised", merged.raised) }
                logger.sample("settleRecheckMs", (CFAbsoluteTimeGetCurrent() - recheckStart) * 1000)
            }
            if let zoomTile {
                // Tile boxes merge into this frame's boxes before policy; the
                // full pass's own boxes are kept for the record.
                let merged = ZoomTiles.merge(
                    full: pass.kept, tile: pass.tile, tileIndex: zoomTile.index, region: zoomTile.region)
                zoomRecord = FrameLogger.ZoomRecord(
                    tile: zoomTile.index, ms: (passMs * 10).rounded() / 10, cut: merged.dropped,
                    full: pass.kept.map(FrameLogger.DetectionRecord.init))
                pass.kept = merged.merged
                logger.count("zoomTilePasses")
                logger.sample("zoomPassMs", passMs)
                let added = merged.merged.filter { $0.tile != nil }.count
                if added > 0 { logger.count("zoomTileBoxesAdded", added) }
                if merged.dropped > 0 { logger.count("zoomTileBoxesDropped", merged.dropped) }
            }
            detections = pass.kept
            weak = pass.weak
            if !weak.isEmpty {
                logger.count("weakBoxesTraceOnly", weak.count)
                weakBoxesSeen += weak.count
            }
            detectEnd = CFAbsoluteTimeGetCurrent()
            endDetectDeadline(at: detectEnd)
            noteDetectorSuccess()
        } catch {
            // Stamp the end here too: leaving it at inferStart made detectMs
            // read 0 ms exactly when the detector failed after doing real
            // work (review 2026-08-25).
            detectEnd = CFAbsoluteTimeGetCurrent()
            let now = CFAbsoluteTimeGetCurrent()
            endDetectDeadline(at: now)
            if now - lastDetectorErrorEventAt >= Self.detectorErrorEventInterval {
                lastDetectorErrorEventAt = now
                logger.event("detector-error", "\(error)")
            }
            logger.count("detectorErrors")
            // FAIL CLOSED (2026-09-11 — this branch used to set
            // `detections = []`, which let hysteresis clear every cover on
            // screen while the UI still read "Protected"). Receipt at
            // `heldStep`.
            return holdCovers(
                at: now, capturedAt: capturedAt, inferStart: inferStart, frameIndex: frameIndex)
        }
        // Media cover mode: same frame the detector just saw. Costed
        // inside the inferMs window, which already spans tracking too.
        // mediaHeldRects must be read BEFORE tracker.update: MotionBoxes uses
        // this frame's held rects to suppress fragments of a covered player.
        if CFAbsoluteTimeGetCurrent() < injectUntil {
            detections.append(Detection(
                label: "INJECT_TEST", confidence: 1.0, box: opts.injectRect))
        }
        // Detection view synthetic source (DetectionFixture.swift): real
        // pipeline input from here on, marked synthetic in the trace only.
        let syntheticFrom = detections.count
        if syntheticDetectionsEnabled {
            detections += detectionFixture.next(screen: screenSize)
        }
        // The acquisition snap needs to know which detections BLOCK, so the
        // policy filter (and the debug injection it must see) runs before the
        // media path rather than after it. Both still run inside the mediaMs
        // window: the acquisition snap is media pixel work and its cost belongs
        // in the media budget.
        // The whole policy decision (TuningPolicy.filter): covered-beats-
        // exposed demotion on the RAW list, then the per-class threshold,
        // then the size floor. Both removals are counted into the 60 s
        // summary — at the default tuning both counters stay 0 and the
        // record is byte-identical.
        // Score hysteresis (`TuningPolicy.keepGap`): the boxes the last
        // evaluated frame blocked — region and media covers only; curtain
        // mode sees exactly the pre-hysteresis boxes.
        let tracked = TuningPolicy.CoveredInput.forCover(
            curtain: opts.cover == .curtain, lastBlocked: lastBlocked)
        let filtered = tuning.filter(
            detections, mode: effectivePolicy, blockFaces: opts.blockFaces, screen: screenSize,
            tracked: tracked)
        lastBlocked = filtered.blocked
        if filtered.kept > 0 { logger.count("tuningKeptTracked", filtered.kept) }
        if filtered.minBoxDropped > 0 { logger.count("tuningMinBoxDropped", filtered.minBoxDropped) }
        if filtered.minBoxPtUnmeasured > 0 {
            logger.count("tuningMinBoxPtUnmeasured", filtered.minBoxPtUnmeasured)
        }
        if filtered.demoted > 0 { logger.count("tuningCoveredDemoted", filtered.demoted) }
        // The threshold staircase (ClassRule.thresholdSteps), three counters
        // because a box is not a frame and a frame is not a drop: only an
        // EMPTIED frame can change what the curtain sees. At the default
        // tuning all three stay 0, no record is written, and the synthetic
        // gate stays byte-identical.
        if filtered.stepDropped > 0 { logger.count("tuningThresholdStepDropped", filtered.stepDropped) }
        if filtered.stepUnmeasured > 0 {
            logger.count("tuningThresholdStepUnmeasured", filtered.stepUnmeasured)
        }
        if filtered.stepEmptiedFrame { logger.count("tuningThresholdStepFramesEmptied", 1) }
        tuningReadout?.record(
            raw: detections, filtered: filtered, tuning: tuning, mode: effectivePolicy,
            blockFaces: opts.blockFaces, screen: screenSize, now: CFAbsoluteTimeGetCurrent())
        var blocked = filtered.blocked
        if let roi = opts.roi {
            blocked = blocked.filter { roi.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        }
        cropRequestsThisFrame.removeAll(keepingCapacity: true)
        cropBlockedThisFrame = blocked
        let mediaStart = CFAbsoluteTimeGetCurrent()
        let media =
            motionBoxes?.update(
                pixelBuffer, heldRects: tracker.mediaHeldRects,
                detections: blocked.map(\.box)) ?? MotionBoxes.Result()
        // Media-path pixel work only.
        // nil in region mode, where the path does not run.
        let mediaMs: Double? =
            motionBoxes == nil ? nil : (CFAbsoluteTimeGetCurrent() - mediaStart) * 1000
        if let mediaMs {
            mediaMsTotal += mediaMs
            mediaMsFrames += 1
        }
        // Cover the whole media box a blocked detection sits in, and hold
        // it (Tracker.holdFrames) across the detector dropouts measured
        // inside playing video. Over-blocks by the player's extent (no
        // size cap); an unchanging screen area is never covered.
        let mediaBoxes = media.all
        // The spec invariant the paint smoother may never smooth away
        // ("detection always covered"), captured BEFORE the media expansion:
        // what must be covered is the detection, and the media rect around it
        // is margin. See PaintSmoother rules 4 and 5.
        let mustCover = blocked.map(\.box)
        if !mediaBoxes.isEmpty {
            blocked = blocked.map { detection in
                let center = CGPoint(x: detection.box.midX, y: detection.box.midY)
                // EVERY box containing the detection, not the first: a player
                // can be covered by a promoted fragment and the provisional
                // that still spans the rest of it, and picking one of the two
                // uncovers whatever the other was holding.
                let containing = mediaBoxes.filter { $0.contains(center) }
                guard !containing.isEmpty else { return detection }
                let expanded = containing.reduce(detection.box) { $0.union($1) }
                return Detection(
                    label: detection.label, confidence: detection.confidence,
                    box: expanded, mediaExpanded: true)
            }
        }
        // Region suppression under a painted curtain (receipt at
        // `regionInput`). One-step lag is deliberate: the rects are the
        // previous curtain update's, which makes the decision sticky and
        // coherent with `regionCurtainOwners` below. ONLY the region
        // tracker's input is filtered — `mustCover`, `curtainRects` and the
        // exposure tripwire inside it all keep the full `blocked` list.
        let regionSourceIndices = Self.regionInputIndices(
            blocked, underCurtains: lastCurtainPainted)
        let regionDets = regionSourceIndices.map { blocked[$0] }
        if regionDets.count != blocked.count {
            // Named in the 60 s summary and printed by health_report.py:
            // work this pipeline drops is never dropped silently.
            logger.count("detsSuppressedUnderCurtain", blocked.count - regionDets.count)
        }
        let regions = tracker.update(
            detections: regionDets, mediaBoxes: mediaBoxes,
            sustainedTranslation: media.sustainedTranslation,
            frozen: frozenRegions.union(draggingRegions), owned: ownedRegions,
            sourceIndices: cropWriter == nil ? nil : regionSourceIndices)
        // Single-frame candidates the curtain-mode entry debounce dropped
        // (receipt at Tracker.curtainEntryFrames): named in the 60 s summary
        // like detsSuppressedUnderCurtain — work this pipeline drops is never
        // dropped silently. Always 0 in region/media mode.
        let debounced = tracker.takeDebouncedEntries()
        if debounced > 0 { logger.count("regionEntriesDebounced", debounced) }
        paintSmoother.setFrameSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer))
        // REGION covers only. Curtains are `curtains` below and are deliberately
        // NOT in this array — which is also why the full-coverage tripwire
        // (`checkCoverage`, fed from here) cannot see one, shield included.
        let painted = paintSmoother.rects(for: regions, mustCover: mustCover)
        // OS-assisted window tracking. Absent
        // headless, so `anchors` is empty and every downstream path no-ops.
        let anchors = resolveOwnership(
            regions, painted: painted, mustCover: mustCover, at: capturedAt)
        let curtainStart = CFAbsoluteTimeGetCurrent()
        let curtains = curtainRects(blocked, at: capturedAt)
        let curtainMs = (CFAbsoluteTimeGetCurrent() - curtainStart) * 1000
        lastCurtainPainted = curtains.map(\.rect)
        noteWithheld(detections, covered: painted + lastCurtainPainted, at: capturedAt)
        // Region -> curtain ownership, decided HERE because sync-time rects
        // are the closest thing to a coherent instant this pipeline has
        // (receipt: Overlay.ownerClamped — a paint-time share test failed
        // under motion, 529 spilling paints in the drag run). Majority share
        // 0.5 (DERIVED): a box half-inside the curtained window's content
        // rect is that window's content. STICKY: once owned, a region stays
        // owned until its curtain lifts — during a drag the stale pixel rect
        // falls outside the fresh window frame, which is exactly when the
        // clamp must keep holding. Entries are dropped when their curtain
        // lifts (bounded by region births during one curtain's lifetime).
        let activeCurtainIDs = Set(curtains.map(\.id))
        regionCurtainOwners = regionCurtainOwners.filter { activeCurtainIDs.contains($0.value) }
        if curtains.isEmpty {
            // Curtain-free modes and frames pay nothing here (efficiency
            // review 2026-08-20: the always-on shape allocated three
            // collections per frame for a guaranteed no-op).
            if !regionCurtainOwners.isEmpty { regionCurtainOwners.removeAll() }
            if !prevCurtainRects.isEmpty { prevCurtainRects.removeAll() }
        } else {
            // Attribution rect = UNION of this sync's full frame and the
            // previous sync's — the swept path. A region BORN mid-fast-drag
            // has a pixel rect one capture behind the window frame and
            // misses the current rect alone (fast run clamp2: 14
            // unattributed spilling paints, worst 201 pt).
            let attrRects = curtains.map { c in
                (id: c.id, rect: prevCurtainRects[c.id].map { $0.union(c.attr) } ?? c.attr)
            }
            for (region, r) in zip(regions, painted) {
                guard r.width > 0, r.height > 0 else { continue }
                var best: (share: CGFloat, id: UInt32)?
                for a in attrRects {
                    let inter = r.intersection(a.rect)
                    guard !inter.isNull else { continue }
                    let share = (inter.width * inter.height) / (r.width * r.height)
                    if share >= 0.5, share > (best?.share ?? 0) { best = (share, a.id) }
                }
                if let best { regionCurtainOwners[region.id] = best.id }
                // Evidence-based RELEASE (altitude review 2026-08-20): a
                // fresh blocked detection inside this region but outside its
                // owner's swept rect is a second window's live content, not
                // a trail — a trail has no fresh detection by construction.
                // Without this, the sticky clamp would suppress the region
                // cover's first response over that content until it earns its own
                // curtain. MEASURED harmless to the clamp itself: drag runs
                // with and without it both score 0 boxes outside the full
                // window frame, fast runs 13-14 either way (clamp6/7 vs
                // clamp8, 2026-08-20; an earlier 861-spill reading against
                // it was a scorer bug — the strip band was grown on the
                // wrong edge).
                if let owner = regionCurtainOwners[region.id],
                    let attr = attrRects.first(where: { $0.id == owner })?.rect {
                    for m in mustCover {
                        let mid = CGPoint(x: m.midX, y: m.midY)
                        if r.contains(mid), !attr.contains(mid) {
                            regionCurtainOwners.removeValue(forKey: region.id)
                            break
                        }
                    }
                }
            }
            // uniquing, not uniqueKeys: update()'s output contract is one
            // entry per id, but a contract violation must not trap the
            // daemon and drop every cover on screen (altitude review
            // 2026-08-20).
            prevCurtainRects = Dictionary(
                curtains.map { ($0.id, $0.attr) }, uniquingKeysWith: { a, _ in a })
        }
        if let cropWriter {
            cropWriter.submit(
                pixelBuffer, frameDetections: detections,
                requests: cropRequestsThisFrame)
        }
        cropRequestsThisFrame.removeAll(keepingCapacity: true)
        cropBlockedThisFrame.removeAll(keepingCapacity: true)
        let now = CFAbsoluteTimeGetCurrent()
        logger.log(
            detections: detections, regions: regions, mediaBoxes: media.stable.count,
            inferMs: (now - inferStart) * 1000, totalMs: (now - capturedAt) * 1000,
            mediaMs: mediaMs,
            // Stage split, live curtain runs only (absent headless, so the
            // gate baseline never sees it): the model alone, and the curtain
            // attribution's window-server work — measured 2026-08-25 because
            // `inferMs` spans both and the first-detection spike had to be
            // placed.
            detectMs: curtain == nil ? nil : (detectEnd - inferStart) * 1000,
            curtainMs: curtain == nil ? nil : curtainMs,
            blockedCount: blocked.count,
            frame: frameIndex,
            painted: frameIndex == nil ? nil : painted,
            windows: windowRecords(regions, anchors),
            curtains: curtains.isEmpty
                ? nil
                : curtains.map({ entry in
                    FrameLogger.CurtainRecord(
                        wid: Int(entry.id),
                        box: [entry.rect.minX, entry.rect.minY, entry.rect.width, entry.rect.height]
                            .map { (Double($0) * 1000).rounded() / 1000 })
                }),
            zoom: zoomRecord)
        checkCoverage(painted, at: now)
        if traceEnabled {
            let traceStart = CFAbsoluteTimeGetCurrent()
            var walkCostMs = 0.0
            var input = traceInputs(capturedAt: capturedAt, inferStart: inferStart, detectEnd: detectEnd)
            input.raw = detections
            input.weak = weak
            input.tracked = tracked
            input.syntheticFrom = syntheticFrom
            input.regionSourceIndices = regionSourceIndices
            input.regions = regions
            input.painted = painted
            input.pending = tracker.pendingEntriesForTrace
            // The same guard `curtainRects` returns early on: no update, no
            // walk this frame.
            if let recorder = curtain?.traceRecorder, windowTracker != nil, screenSize.width > 0 {
                input.curtainWalk = recorder.walk
                input.curtainOutcomes = recorder.outcomes
                walkCostMs = recorder.costMs
            }
            publishTrace(input, blockedCount: blocked.count, startedAt: traceStart, walkCostMs: walkCostMs)
        }
        let result: StepResult = (regions, painted, anchors, curtains, regionCurtainOwners)
        // The last answered frame, for the fail-closed hold (receipt at
        // `heldStep`). Written on every answered frame, so a hold can only ever
        // re-paint covers the detector genuinely asked for.
        heldStep = result
        return result
    }

    /// detectQueue. The curtain pipeline's one step: attribute this frame's
    /// blocked detections to OS windows, advance drop/lift state, and return
    /// the active curtains as normalized bottom-left paint rects with the
    /// chrome strip removed. Empty in every mode but live `--cover curtain`.
    /// `attr` is the FULL window frame normalized (no chrome-strip cut) —
    /// the ownership attribution rect. Receipt (fast-clamp3): top-row boxes
    /// sit mostly inside the strip, so testing against the painted content
    /// rect left them unowned and they spilled at drag start (57 paints).
    private func curtainRects(
        _ blocked: [Detection], at t: CFAbsoluteTime
    ) -> [(id: UInt32, rect: CGRect, attr: CGRect)] {
        guard let curtain, let windowTracker, screenSize.width > 0 else { return [] }
        let display = geometry.bounds
        currentFrameAt = t
        let blockedRects = blocked.map { screenRect($0.box) }
        let frames = curtain.update(
            blockedScreenRects: blockedRects,
            tracker: windowTracker, display: display, at: t,
            sourceIndices: cropWriter == nil ? nil : Array(blocked.indices))
        noteExposure(blocked, rects: blockedRects, covered: frames.map(\.frame), at: t)
        // Capture-time attribution fallbacks (receipt at
        // Curtain.frontCandidateSecs): named in the 60 s summary like
        // detsSuppressedUnderCurtain — a hit the walk could not place at
        // capture time is never handled silently.
        let attribution = curtain.takeAttributionCounters()
        if attribution.ringYoungCredited > 0 {
            logger.count("curtainRingYoungCredited", attribution.ringYoungCredited)
        }
        if attribution.ringYoungMoved > 0 {
            logger.count("curtainRingYoungMoved", attribution.ringYoungMoved)
        }
        // In curtain mode nothing is media-held, so resolveOwnership tracked
        // nothing — the curtains' windows, their pending successors and the
        // topmost candidate are the tracked set (Curtain.watchIDs).
        windowTracker.setTracked(curtain.watchIDs)
        logger.setActiveCovers(frames.count)  // §4.7 gauge for the updater's summary read
        return normalizeCurtains(frames, display: display)
    }

    /// REGION SUPPRESSION UNDER A PAINTED CURTAIN (owner 2026-08-26): a
    /// blocked detection whose centre lies inside a curtain's PAINTED rect is
    /// already covered by that curtain, and feeding it to the region tracker
    /// only births redundant layers under an opaque cover. MEASURED live
    /// 2026-08-26 09:00:08–35Z (uid 501): 8–10 dets/frame inside one
    /// curtained Chrome window bred 5–19 new region ids/s, regions peaked at
    /// 34 layers, the overlay-count tripwire fired 14×, and CPU reached 35%
    /// (WindowTracker poll 60% late, worst 564 ms behind).
    ///
    /// PAINTED rect, not the full window frame: the visible chrome strip
    /// stays region-cover territory, and a drag's lagging pixels fall outside
    /// the painted rect and still earn regions exactly as before.
    ///
    /// PIPELINE BOUNDARY — the two cover pipelines stay decoupled. This is a
    /// ONE-WAY read: the region pipeline consumes rects the curtain pipeline
    /// already painted. Nothing flows back into `Curtain`, no curtain
    /// decision depends on regions, and every other consumer of the blocked
    /// list is deliberately left unfiltered — `mustCover` (PaintSmoother's
    /// safety floor, which only floors regions that exist and never
    /// synthesises one), `curtainRects`, and the exposure tripwire inside it.
    ///
    /// COST AT LIFT (2026-08-28, receipt at `Curtain.minCurtainSize`): the
    /// region layers under a curtain age out while it is up — 12 frames /
    /// 0.4 s non-sticky, 30 / 1.0 s sticky at the default 30 fps — so a
    /// curtain lift (sub-floor, dead-lift or ghost-ban) restarts region
    /// coverage from the NEXT DETECTOR FRAME rather than settling onto covers
    /// that are already painted. Accepted, and bounded on both sides:
    /// `noteExposure` gets the unfiltered list so the exposure tripwire fires
    /// on the gap, and the idle gate stands down while `uncoveredStreak > 0`
    /// so the detector runs at full rate through it.
    ///
    /// Both inputs are in the same space: normalized, bottom-left origin
    /// (`Detection.box`, and `normalizeCurtains`' inverse of `screenRect`).
    static func regionInput(
        _ blocked: [Detection], underCurtains painted: [CGRect]
    ) -> [Detection] {
        regionInputIndices(blocked, underCurtains: painted).map { blocked[$0] }
    }

    static func regionInputIndices(
        _ blocked: [Detection], underCurtains painted: [CGRect]
    ) -> [Int] {
        guard !painted.isEmpty else { return Array(blocked.indices) }
        return blocked.indices.filter { index in
            let detection = blocked[index]
            let centre = CGPoint(x: detection.box.midX, y: detection.box.midY)
            return !painted.contains { $0.contains(centre) }
        }
    }

    /// Geometry-only curtain maintenance on detectQueue. This path never
    /// supplies detections and Curtain.update(evaluated: false) cannot add
    /// clean-frame evidence or expire a hold.
    private func curtainTick() {
        guard captureFrameReceiptValid, let generation = curtainCaptureGeneration,
            capture.isCurrentGeneration(generation), !captureSuspended, !paused
        else { return }
        guard let curtain, let windowTracker, screenSize.width > 0 else { return }
        let t = CFAbsoluteTimeGetCurrent()
        guard t - lastFrameAt >= Self.curtainTickSecs,
            !curtain.watchIDs.isEmpty || curtain.hasLinger
        else { return }
        let display = geometry.bounds
        // Geometry-only drops have no detector-frame latency. Clear the
        // detector timestamp so the shared event logger does not attach an
        // old frame's latency to a parole-return drop.
        currentFrameAt = 0
        let frames = curtain.update(
            blockedScreenRects: [], tracker: windowTracker,
            display: display, at: t, evaluated: false)
        windowTracker.setTracked(curtain.watchIDs)
        logger.setActiveCovers(frames.count)  // §4.7 gauge for the updater's summary read
        let curtains = normalizeCurtains(frames, display: display)
        // Keep the suppression input coherent with what is actually painted:
        // this tick can lift a curtain with no frame in flight, and a stale
        // rect would keep suppressing regions over uncovered pixels.
        lastCurtainPainted = curtains.map(\.rect)
        if !curtains.isEmpty { lastStepHadCover = true }
        if opts.overlays {
            DispatchQueue.main.async { [self] in
                guard capture.isCurrentGeneration(generation) else { return }
                detectionViewHeldPaint.tick = .init(generation: generation, curtains: curtains, at: t)
                guard !suppressed else { return }
                guard !detectionViewSuppressesCovers else { return }
                if overlays.syncCurtainState(curtains, at: t) {
                    capture.refreshExclusion(windowNumbers: exclusionWindowNumbers)
                    detectionView?.coverWindowCreated(overlays.windowNumbers.first)
                }
            }
        }
    }

    private func startCurtainTick() {
        guard curtain != nil, curtainTickTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: detectQueue)
        timer.schedule(
            deadline: .now() + Self.curtainTickSecs,
            repeating: Self.curtainTickSecs)
        timer.setEventHandler { [weak self] in self?.curtainTick() }
        timer.resume()
        curtainTickTimer = timer
        logger.event(
            "curtain",
            "frame-less geometry tick started every \(Int(Self.curtainTickSecs * 1000)) ms window 0")
    }

    private func normalizeCurtains(
        _ frames: [(id: CGWindowID, frame: CGRect)], display: CGRect
    ) -> [(id: UInt32, rect: CGRect, attr: CGRect)] {
        // Inverse of screenRect, against the CURRENT geometry: both
        // directions live at DisplayGeometry so a topology change moves them
        // together and `--ui-selftest` can script one.
        let geometry = self.geometry
        func norm(_ f: CGRect) -> CGRect { geometry.normalized(f) }
        return frames.compactMap { entry in
            // Chrome strip (or none, fullscreen): one definition,
            // Curtain.contentRect — the overlay's live path uses the same.
            let painted = norm(Curtain.contentRect(window: entry.frame, display: display,
                quickLook: windowTracker?.isQuickLookWindow(entry.id) == true))
            let full = norm(entry.frame)
            return painted.isNull || painted.isEmpty
                ? nil : (id: UInt32(entry.id), rect: painted, attr: full)
        }
    }

    /// detectQueue. The exposure tripwire (receipt at exposureFrames): a
    /// blocked detection is covered when some active curtain frame contains
    /// its center (the same attribution rule Curtain uses to own it).
    private func noteExposure(
        _ blocked: [Detection], rects: [CGRect], covered: [CGRect], at t: CFAbsoluteTime
    ) {
        let uncovered = rects.indices.filter { i in
            let c = CGPoint(x: rects[i].midX, y: rects[i].midY)
            return !covered.contains { $0.contains(c) }
        }
        guard !uncovered.isEmpty else {
            if uncoveredStreak >= derived.exposureFrames {
                logger.event("exposure-end", String(
                    format: "covered after %.0f ms uncovered=%d frames",
                    (t - uncoveredSince) * 1000, uncoveredStreak))
            }
            uncoveredStreak = 0
            uncoveredLabels.removeAll()
            return
        }
        if uncoveredStreak == 0 { uncoveredSince = t }
        uncoveredStreak += 1
        for i in uncovered { uncoveredLabels.insert(blocked[i].label) }
        // Fires exactly once per streak: the streak increments by 1 and is
        // never clamped, so it crosses exposureFrames exactly once (the
        // exposureReported latch was redundant — review 2026-08-25).
        if uncoveredStreak == derived.exposureFrames {
            exposureEpisodes += 1
            let info = "budget exposureFrames, limit \(derived.exposureFrames) frames, "
                + "observed \(uncoveredStreak) uncovered frames over "
                + String(format: "%.0f ms", (t - uncoveredSince) * 1000)
                + " labels=\(uncoveredLabels.sorted().joined(separator: ","))"
                + " episode=\(exposureEpisodes) (fix: Pipeline.exposureFrames / Curtain policy)"
            if t - lastExposureStderrAt >= Self.detectorErrorEventInterval {
                lastExposureStderrAt = t
                FileHandle.standardError.write(Data(("WARNING: exposure: " + info + "\n").utf8))
            }
            logger.event("exposure", info)
        }
    }

    /// mtime+size of the running binary, the only build identity a swiftc
    /// build has (no bundle version). Lets a "startup" record be tied to the
    /// binary that wrote it after a redeploy.
    static let executableStamp: String = {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let m = a[.modificationDate] as? Date, let n = a[.size] as? Int
        else { return "unknown" }
        return "\(Int(m.timeIntervalSince1970))/\(n)"
    }()

    /// detectQueue. Which window (if any) owns each region's cover, where that
    /// cover sits inside it, and whether an occlusion is in progress.
    ///
    /// Only media-held regions are resolved: the safety invariant is about
    /// translating a media-held cover, and a region-mode rect is painted exactly
    /// as it always was (receipt in PaintExtrapolator's SCOPE note).
    ///
    /// `painted` is the PIXEL-DERIVED cover the pipeline published this frame —
    /// the same rects the overlay would paint with tracking off — and it, not
    /// the pinned rect the overlay is riding, is what a window must hold to
    /// ACQUIRE ownership (defect 1a). The decision itself lives in
    /// `CoverOwnership`, which is where the incumbency, freeze and pin state is.
    private func resolveOwnership(
        _ regions: [TrackedRegion], painted: [CGRect], mustCover: [CGRect],
        at capturedAt: CFAbsoluteTime
    ) -> [PaintExtrapolator.Anchor] {
        guard let tracker = windowTracker, let ownership = coverOwnership,
            screenSize.width > 0
        else { return [] }
        frameOrdinal += 1
        var anchors = [PaintExtrapolator.Anchor](
            repeating: PaintExtrapolator.Anchor(), count: regions.count)
        let held = regions.enumerated().filter { $0.element.mediaHeld }
        guard !held.isEmpty else {
            // LAPSE, not reset (iteration tk3). This branch fires on a media
            // latch BLINK as well as on a real end of media: a demote under
            // translating pixels, a detector dropout, a poll stall. `reset()`
            // destroyed the pin on all four, so the next acquisition had to
            // believe whatever collapsed rect the pixel path held at that
            // instant — receipts at `CoverOwnership.pinLapseSecs`. `reset()`
            // now belongs to panic/pause alone.
            ownership.lapse(at: capturedAt)
            // Keep the curtains' windows tracked (review 2026-08-19, P1):
            // this branch runs EVERY frame in curtain mode (nothing is ever
            // media-held there), and a plain setTracked([]) wiped the 120 Hz
            // ring one line before Curtain.update read it — latestFrame
            // always nil, isDead always false, the window-closed lift dead.
            tracker.setTracked(curtain?.watchIDs ?? [])
            return anchors
        }
        let walk = frameOrdinal % derived.ownershipResolveEvery == 0
        let start = CFAbsoluteTimeGetCurrent()
        // The FLOOR the ownership layer may never publish under: this region's
        // own raw blocked detections, in screen space. Same centre-ownership
        // test PaintSmoother.requirement uses, for the same reason — the region
        // that HOLDS a detection is the one responsible for covering it.
        let floors = held.map { entry -> CGRect in
            var need = CGRect.null
            for box in mustCover
            where entry.element.rect.contains(CGPoint(x: box.midX, y: box.midY)) {
                need = need.isNull ? box : need.union(box)
            }
            return need.isNull ? .null : screenRect(need)
        }
        let verdicts = ownership.resolve(
            regionIDs: held.map(\.element.id),
            covers: held.map { screenRect(painted[$0.offset]) },
            floors: floors,
            walk: walk, tracker: tracker, at: capturedAt)
        if walk {
            ownerMsTotal += (CFAbsoluteTimeGetCurrent() - start) * 1000
            ownerWalks += 1
        }
        tracker.setTracked(Set(verdicts.compactMap(\.windowID)))
        frozenRegions = Set(
            zip(held, verdicts).filter { $0.1.frozen }.map { $0.0.element.id })
        ownedRegions = Set(
            zip(held, verdicts).filter { $0.1.windowID != nil }.map { $0.0.element.id })
        draggingRegions = Set(
            zip(held, verdicts).compactMap { entry, verdict -> Int? in
                guard let wid = verdict.windowID else { return nil }
                let still = tracker.stillSeconds(of: wid, at: capturedAt) ?? .infinity
                return still < WindowTracker.stillSecs ? entry.element.id : nil
            })
        for (k, entry) in held.enumerated() {
            let v = verdicts[k]
            guard let id = v.windowID else { continue }
            anchors[entry.offset] = PaintExtrapolator.Anchor(
                windowID: id,
                windowFrameAtCapture: tracker.frame(of: id, at: capturedAt),
                pin: v.pin, frozen: v.frozen)
        }
        return anchors
    }

    /// Normalized bottom-left (detection space) -> screen points, TOP-LEFT
    /// origin: the space CGWindowList reports window frames in. The maths, the
    /// `+ origin` term `--display` needed, and the inverse all live at
    /// `DisplayGeometry`; what this wrapper adds is "against the CURRENT
    /// geometry".
    private func screenRect(_ r: CGRect) -> CGRect { geometry.screenRect(r) }

    /// The window anchors, for the log. The `painted` field records what the
    /// PIPELINE decided; on a live run the overlay then advances those rects by
    /// the owning window's motion between capture and glass, so without this the
    /// log no longer explains the frames a census scores.
    private func windowRecords(
        _ regions: [TrackedRegion], _ anchors: [PaintExtrapolator.Anchor]
    ) -> [FrameLogger.WindowRecord]? {
        guard windowTracker != nil, !anchors.isEmpty else { return nil }
        var out: [FrameLogger.WindowRecord] = []
        for (i, region) in regions.enumerated() where i < anchors.count {
            guard let id = anchors[i].windowID, let frame = anchors[i].windowFrameAtCapture
            else { continue }
            let pin = anchors[i].pin
            out.append(
                FrameLogger.WindowRecord(
                    id: region.id, wid: Int(id),
                    frame: [frame.minX, frame.minY, frame.width, frame.height]
                        .map { (Double($0) * 10).rounded() / 10 },
                    pin: pin.map { p in
                        [p.minX, p.minY, p.width, p.height]
                            .map { (Double($0) * 10000).rounded() / 10000 }
                    },
                    frozen: anchors[i].frozen ? true : nil))
        }
        return out.isEmpty ? nil : out
    }

    private func process(_ frame: CaptureStream.Frame) {
        guard busy.wait(timeout: .now()) == .success else {
            logger.recordDrop()
            return
        }
        detectQueue.async { [self] in
            defer { busy.signal() }
            guard capture.isCurrentGeneration(frame.generation) else { return }
            guard !captureSuspended else { return }
            // Validate actual display content before any pause or idle gate.
            // A transparent SCK warm-up frame is not a health Receipt, while
            // a valid frame still proves capture during a parent pause.
            guard let buffer = contentCrop.apply(
                frame.pixelBuffer, displaySize: screenSize)
            else { return }
            captureFrameReceiptValid = true
            curtainCaptureGeneration = frame.generation
            if !firstCaptureFrameReported {
                firstCaptureFrameReported = true
                DispatchQueue.main.async {
                    [weak self, onCaptureHealth, onFirstCaptureFrame] in
                    guard self?.capture.isCurrentGeneration(frame.generation) == true else {
                        return
                    }
                    if let onFirstCaptureFrame {
                        onFirstCaptureFrame()
                    } else {
                        onCaptureHealth?(.protecting)
                    }
                }
            }
            // Nothing is counted here: the 60 s summary only fires from
            // Logger.log(), which a paused frame never reaches, so a counter
            // would be silent for the whole pause and lost on a paused exit.
            // The in-pause marker is the main-thread pause-tick event instead.
            guard !paused else { return }
            if !startupLogged {
                startupLogged = true
                // `tier=/ane=/fps=` sit next to HostArch's `arch=/translated=`
                // on purpose: on a translated process all five are the same
                // story, and a support reader should not have to join two
                // records to see it. `derived=` carries every fps-derived value
                // this run actually used (PerfTier.Derived) — a tier that only
                // names itself cannot be debugged, because the whole point of a
                // tier is the nine numbers it moves.
                // Limits fail loudly (CONTRIBUTING.md): resolving to a tier other
                // than `default` measurably thins the filter,
                // and `ane == .unknown` means the query FAILED
                // and we fell back. Neither may live only as a field inside
                // the generic startup line — `--probe` already WARNs on both,
                // and the daemon must too.
                // Third trigger (2026-09-08): the machine cannot afford the
                // fps it was CONFIGURED to run — `--fps`/config fps is parsed
                // independently of the tier, and the paint constants then
                // budget for a p95 this machine does not meet. Receipt and the
                // numbers are in PerfTier.fpsBudgetWarning.
                let fpsBudget = PerfTier.fpsBudgetWarning(
                    tier: opts.tier, fps: opts.fps)
                if opts.tier.name != .standard || opts.ane == .unknown
                    || fpsBudget != nil {
                    let info = "tier=\(opts.tier.name.rawValue) "
                        + "ane=\(opts.ane.rawValue) fps=\(opts.fps) "
                        + "derived=[\(derived.summary)] why=\(opts.tierWhy) "
                        + (opts.ane == .unknown
                            ? "(ANE DETECTION FAILED — fell back to the slower tier) "
                            : "")
                        + (fpsBudget.map { $0 + " " } ?? "")
                        + "(fix: PerfTier.swift / config.json tier; the no-ane "
                        + "fps is ASSUMED for Intel hardware)"
                    FileHandle.standardError.write(
                        Data(("WARNING: tier: " + info + "\n").utf8))
                    logger.event("tier", info)
                }
                logger.event("startup", String(
                    format: "firstFrameMs=%.0f %@ exe=%@ arch=%@ translated=%@ "
                        + "tier=%@ ane=%@ fps=%d fpsSource=%@ "
                        + "dirtyRects=%@ idleGate=%@ %@ derived=[%@] tierWhy=%@",
                    (CFAbsoluteTimeGetCurrent() - initAt) * 1000, detector.loadInfo,
                    Self.executableStamp, HostArch.compiled, HostArch.translated,
                    opts.tier.name.rawValue, opts.ane.rawValue, opts.fps,
                    opts.fpsExplicit ? "explicit"
                        : (opts.tierOverride != nil ? "tier-forced" : "tier"),
                    capture.dirtyAttachmentShape ?? "?",
                    Self.idleGateEnabled ? "on" : "off",
                    // An installed agent shows `envKnobs=0` (DevEnv.swift).
                    DevEnv.launchSummary,
                    derived.summary, opts.tierWhy))
                // The LOG half of the Rosetta warning; the stderr half is
                // emitted once from main, before any mode branch.
                if HostArch.isTranslated {
                    logger.event("rosetta", HostArch.translationWarning)
                }
            }
            // Dirty-area receipt per window: how much of the delivered stream
            // the gate could even consider (under idleDirtyFraction), vs
            // frames reporting a full/unknown change. If `framesDirtyFull`
            // dominates on a visibly static desktop, the attachment is not
            // parsing and the gate is silently off.
            logger.count(frame.dirtyFraction >= 1 ? "framesDirtyFull"
                : frame.dirtyFraction < Self.idleDirtyFraction ? "framesDirtySmall"
                : "framesDirtyMid")
            logger.sample("dirtyPct", frame.dirtyFraction * 100)
            // Idle-frame gate (receipt at idleDirtyFraction): a barely-changed
            // frame with nothing covered runs the detector every Nth time.
            // Change is MEASURED from pixels (FrameDelta); SCK's dirtyRects is
            // window-granular and only logged (dirtyPct) as the receipt for
            // why.
            let changed = frameDelta.changedFraction(frame.pixelBuffer)
            logger.sample("changePct", changed * 100)
            settleWatch.observe(
                changed: changed, threshold: Self.idleDirtyFraction, stillFrames: derived.idleDetectEvery)
            // uncoveredStreak == 0: skipped frames never reach noteExposure,
            // so gating during an uncovered streak silently stretched the
            // exposure tripwire's 12-frame/0.4 s receipt to ~1.2 s wall clock
            // on a static exposure (review 2026-08-25) — the gate stands down
            // while the tripwire is counting.
            if Self.idleGateEnabled, changed < Self.idleDirtyFraction, !lastStepHadCover,
                uncoveredStreak == 0 {
                idleSkipStreak += 1
                if idleSkipStreak < derived.idleDetectEvery {
                    logger.skipIdle()
                    if traceEnabled { traceIdleSkipped += 1 }
                    return
                }
            }
            idleSkipStreak = 0
            // Live capture only, and only inside the busy gate: the crop
            // target is reused, and the gate is what guarantees one frame in
            // flight. See CaptureContentCrop for why a display capture buffer
            // cannot be trusted to be a tight render of the display.
            let recheck = settleWatch.take() && tuning.settleRecheck
            let (regions, painted, anchors, curtains, owners) = step(
                buffer, capturedAt: frame.capturedAt, recheck: recheck)
            lastStepHadCover = !regions.isEmpty || !curtains.isEmpty
            lastFrameAt = CFAbsoluteTimeGetCurrent()
            if opts.overlays {
                DispatchQueue.main.async { [self] in
                    guard capture.isCurrentGeneration(frame.generation) else { return }
                    detectionViewHeldPaint.frame = .init(
                        generation: frame.generation, regions: regions, painted: painted, anchors: anchors,
                        capturedAt: frame.capturedAt, curtains: curtains, owners: owners)
                    guard !suppressed else { return }
                    guard !detectionViewSuppressesCovers else { return }
                    // A full-coverage release paints curtains only.
                    let released = regionsReleased
                    if overlays.sync(
                        released ? [] : regions, painted: released ? [] : painted,
                        anchors: released ? [] : anchors,
                        capturedAt: frame.capturedAt, curtains: curtains,
                        curtainOwners: released ? [:] : owners) {
                        capture.refreshExclusion(windowNumbers: exclusionWindowNumbers)
                        detectionView?.coverWindowCreated(overlays.windowNumbers.first)
                    }
                }
            }
        }
    }

    /// Exact union area of a set of normalized rects (1.0 = the whole
    /// screen). Sweeps the unique x edges and unions the y intervals of the
    /// rects that span each slab, so overlap is counted once and — unlike a
    /// bounding-box merge — the empty space between two rects that merely
    /// touch is never counted as painted. Pure; `--ui-selftest` calls it.
    /// O(n^2) in the rect count; its production caller (`paintedCoverage`)
    /// hands it at most `OverlayManager.maxRegions` (30) rects.
    static func paintedArea(_ rects: [CGRect]) -> CGFloat {
        let boxes = rects.filter { $0.width > 0 && $0.height > 0 }
        guard !boxes.isEmpty else { return 0 }
        var edges = boxes.flatMap { [$0.minX, $0.maxX] }
        edges.sort()
        var total: CGFloat = 0
        for i in 0..<(edges.count - 1) {
            let x0 = edges[i], x1 = edges[i + 1]
            guard x1 > x0 else { continue }
            var spans = boxes.filter { $0.minX <= x0 && $0.maxX >= x1 }
                .map { (low: $0.minY, high: $0.maxY) }
            guard !spans.isEmpty else { continue }  // a gap between two rects
            spans.sort { $0.low < $1.low }
            var covered: CGFloat = 0
            var start = spans[0].low, end = spans[0].high
            for span in spans.dropFirst() {
                if span.low > end {
                    covered += end - start
                    start = span.low
                    end = span.high
                } else {
                    end = max(end, span.high)
                }
            }
            covered += end - start
            total += (x1 - x0) * covered
        }
        return total
    }

    /// The number the tripwire compares against `coverageLimit`: the union
    /// area of the painted rects that actually reach glass.
    ///
    /// Capped the way `Overlay.sync` caps it — `prefix(maxRegions)`, same
    /// order, same count — so the union is over the rects the overlay will
    /// paint and no others. The detection count feeding the tracker is not
    /// structurally bounded (audit at `Tracker.mergeDetections`: up to 8,400
    /// surviving detections in the pathological case), so without the cap the
    /// runaway the overlay-count tripwire exists for could read >0.9 here
    /// while the overlay paints at most 30 covers — a no-prompt auto-panic
    /// (covers cleared, 5 min) over area that was never on screen. Headless
    /// `--process` paints nothing and applies the same cap, so the number in
    /// the log means the same thing in both modes. The cap is silent here on
    /// purpose: live, the same frame's `Overlay.sync` already logs the
    /// `overlay-count` tripwire by name and a second record per frame would
    /// bury it; headless there is no overlay and no cover to lose.
    /// Pure; `--ui-selftest` calls it.
    static func paintedCoverage(_ painted: [CGRect]) -> CGFloat {
        paintedArea(Array(painted.prefix(OverlayManager.maxRegions)))
    }

    /// detectQueue. REGION COVERS ONLY — `painted` is
    /// `PaintSmoother.rects(for: regions …)`, and curtains travel in a separate
    /// array that is never summed here, so this number is what the REGION
    /// pipeline paints, not the fraction of the display the user is behind
    /// (review 2026-09-09; scope receipt at `coverageLimit`).
    ///
    /// PAINTED rects, not tracker rects (fix 2026-09-08): the overlay paints
    /// `paintRect`'s velocity lead + pad + `minPaintedSide` floor, smoothed by
    /// PaintSmoother, so the tracker rects this summed are strictly smaller
    /// than what those covers put on glass and the tripwire under-measured its
    /// own quantity. `painted` is the very array handed to `Overlay.sync` and
    /// logged as the `painted` field — one computation, no second copy of the
    /// math.
    ///
    /// Still not exactly the pixels, and deliberately so: live, `Overlay.sync`
    /// paints `ownerClamped(layerFrame(extrapolator.rect(...)))` and keeps up
    /// to `lingerSyncs` dead-but-still-black layers, so the extrapolator's
    /// between-update advance and the lingerers add painted area this array
    /// does not carry, while `ownerClamped` shrinks an owned region cover to
    /// its curtain. Those are per-frame deltas on individual covers, not the
    /// order-of-magnitude gap the tracker rects were, and reading the
    /// overlay's live layer frames from the detect queue would mean sampling
    /// main-thread state mid-transaction. The cap receipt is at
    /// `paintedCoverage`.
    private func checkCoverage(_ painted: [CGRect], at now: CFAbsoluteTime) {
        let coverage = Self.paintedCoverage(painted)
        guard coverage > coverageLimit else {
            coverageSince = nil
            return
        }
        guard let since = coverageSince else {
            coverageSince = now
            return
        }
        if now - since > coverageSeconds {
            coverageSince = nil
            logger.event(
                "tripwire",
                "full-coverage: limit \(coverageLimit) painted for \(Int(coverageSeconds))s, "
                + "observed \(String(format: "%.2f", coverage)) (fix: Pipeline.coverageLimit); "
                + "region covers lifted \(Int(Self.regionReleaseSecs))s, curtains and detection on")
            DispatchQueue.main.async { self.releaseRegionCovers(observed: coverage) }
        }
    }

    /// Pure; `--ui-selftest` checks both.
    static func releaseAlertDue(now: CFAbsoluteTime, last: CFAbsoluteTime?) -> Bool {
        last.map { now - $0 >= releaseAlertGapSecs } ?? true
    }

    static func releaseAlertMessage(observed: CGFloat, count: Int) -> String {
        "covers lifted for safety — small covers filled "
            + "\(Int((observed * 100).rounded()))% of the screen for over a minute, so they were "
            + "lifted for \(Int(regionReleaseSecs)) s; window covers and detection stayed on"
            + (count > 1 ? " (\(count) times since the last line)" : "")
            + ". Repeats can mean someone is trying to get around SentryScreen "
            + "(budget Pipeline.releaseAlertGapSecs)"
    }

    /// Main thread. Lifts the region covers for `regionReleaseSecs` and
    /// records it where a parent reads (alerts.log), coalesced by
    /// `releaseAlertGapSecs`.
    private func releaseRegionCovers(observed: CGFloat) {
        let now = CFAbsoluteTimeGetCurrent()
        regionReleaseUntil = now + Self.regionReleaseSecs
        // Both edges on a clock, not on the next frame: lifting or restoring
        // a cover changes no captured pixel (the overlay is excluded), so on
        // a still screen no frame would come to do either.
        if opts.overlays { overlays.clearRegions() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.regionReleaseSecs) { [weak self] in
            // A later trip moved the deadline; its own timer ends it.
            guard let self, !self.regionsReleased else { return }
            self.restoreCoversForDetectionView()  // replays the newest held covers
        }
        releasesSinceAlert += 1
        guard Self.releaseAlertDue(now: now, last: lastReleaseAlertAt) else { return }
        let message = Self.releaseAlertMessage(observed: observed, count: releasesSinceAlert)
        lastReleaseAlertAt = now
        releasesSinceAlert = 0
        let path = AlertsLog.resolvePath(logPath: opts.logPath)
        if let failure = AlertsLog.append(level: "ALERT", message: message, path: path) {
            logger.event("tripwire", "alerts.log append FAILED: \(failure) — the full-coverage "
                + "record above (run.jsonl) is the only copy; fix: make the file appendable by this uid")
        }
    }

    /// Main thread. Also reachable via SIGUSR2 on a dev run (`--dev-inject`
    /// — DevSignals.swift, SPEC §8.1(8)).
    func panic(source: String = "unknown") {
        pause(until: Date().addingTimeInterval(pauseSeconds), source: source)
    }

    /// Panic-class pause: the deadline only ever extends (a second panic
    /// during a longer one does not shorten it), and the clear body runs
    /// every time — panic is the escape hatch and clearing twice is harmless.
    func pause(until: Date, source: String) {
        expirePanicIfDue(now: Date())
        let deadline = max(panicUntil ?? .distantPast, until)
        lastPanicUntil = deadline
        // The source is the trigger that set the deadline: a shorter panic
        // inside a longer one leaves both unchanged, so the chip never names
        // a trigger whose pause is not the one running.
        let owner = panic.flatMap { $0.until >= until ? $0.source : nil } ?? source
        setPanic(PanicPause(until: deadline, source: owner))
        enterPause()
        logger.event(
            "panic",
            "source=\(source): overlays cleared, detection paused \(Int(pauseSeconds))s")
    }

    /// "Resume now" during a panic pause (owner 2026-09-29, plan §6 item 3):
    /// ends the panic deadline early. No PIN, like every Resume: turning
    /// protection back on is the safe direction, and the administrator
    /// password already proved the parent at the start. A settings pause
    /// that is still running keeps protection paused (the later deadline
    /// wins, `effectivePauseUntil`). Main thread.
    func endPanicPause(by user: String) {
        // A deadline that passed before the next 1 s tick ended by expiry,
        // not by this click.
        expirePanicIfDue(now: Date())
        guard panic != nil else { return }
        setPanic(nil)
        lastPanicUntil = nil
        logger.event("panic-end", "reason=resumed user=\(user)")
        applyPauseState(resumeInfo: "panic pause ended early by \(user)")
    }

    /// The one place a panic deadline ends by expiry. Called before every
    /// panic edge and on each pause tick, so an expiry is a named record even
    /// when a longer settings pause keeps protection off, and a click or a
    /// new panic in the up-to-1 s window before the tick cannot hide it.
    private func expirePanicIfDue(now: Date) {
        guard let until = panicUntil, until <= now else { return }
        setPanic(nil)
        logger.event("panic-end", "reason=expired")
    }

    private func setPanic(_ next: PanicPause?) {
        guard next != panic else { return }
        panic = next
        onPanicPause?(next)
    }

    /// Live sensitivity switch (spec §6). `override` is settings.json's
    /// `policyOverride` (nil = none). Precedence, in one expression:
    /// `--policy` flag > settings override > `basePolicy`. Hops detectQueue
    /// to assign, then logs the same `policy` event name the run already
    /// emits at startup, with the source appended.
    ///
    /// Never called on a `--process`/`--replay` path: the only call sites are
    /// AppDelegate.startPipeline and the settings observer, both live-only
    /// (spec §12 rule 5).
    ///
    /// `by` is WHO made the change (settings.json's `updatedBy`), not who is
    /// running this session: the observer fires in EVERY session, so a
    /// sensitivity change the parent makes in the admin session would
    /// otherwise be recorded in the child's log as `user=child(502)` — a
    /// false forensic record in exactly the cross-session case spec §15
    /// slice 5 lists as an acceptance item. Same idiom as `PauseState.logInfo`
    /// (`by.map { "user=..." }`), so nil omits the field rather than falling
    /// back to the local user; startup passes nil because `source=settings`
    /// has no actor.
    func setPolicy(_ override: PolicyMode?, by: String?, source: String) {
        if let pinned = opts.policy, let override, override != pinned, !warnedPinnedOverride {
            // Loud once: the parent changed a control and the run ignored it.
            warnedPinnedOverride = true
            logger.event(
                "policy",
                "override=\(override.rawValue) IGNORED: --policy \(pinned.rawValue) pinned this "
                + "run (spec §6 precedence: flags win)")
        }
        let want = opts.policy ?? override ?? basePolicy
        guard want != policyOnRecord else { return }
        policyOnRecord = want
        detectQueue.async { [self] in effectivePolicy = want }
        logger.event(
            "policy",
            "effective=\(want.rawValue) cover=\(opts.cover.rawValue) source=\(source)"
            + (by.map { " user=\($0)" } ?? ""))
    }

    /// Swap the tracker / curtain tuning (TuningPolicy.swift) — the
    /// tuning.json hot reload, and its removal (back to the launch policy).
    /// Same shape as `setPolicy`: decided on main against the mirror,
    /// applied on detectQueue where every reader lives, logged once as a
    /// `tuning` record with the effective values and the source.
    func setTuning(_ t: TuningPolicy, source: String) {
        guard t != tuningOnRecord else { return }
        tuningOnRecord = t
        detectQueue.async { [self] in
            tuning = t
            tracker.setTuning(t, fps: opts.fps, clearAfterOverride: opts.clearFramesOverride)
            curtain?.tuning = t
        }
        logger.event("tuning", "source=\(source) effective=\(t.jsonString())")
    }

    /// Machine-wide pause from settings.json (UISettingsStore observer).
    /// `info` is the `event=pause` text for this state; a transition OUT of a
    /// settings pause by an explicit edit logs `event=resume` with
    /// `<info> (resumed early by <session user>)`. Resume needs no PIN
    /// (review 2026-09-29), so the log names the session that resumed; the
    /// daemon runs in the console user's session, the only one that can
    /// click Resume.
    func setSettingsPause(_ state: PauseState) {
        guard state != settingsPause else { return }
        let wasActive = settingsPause.effectiveUntil() != nil
        settingsPause = state
        if state.effectiveUntil() != nil {
            logger.event("pause", state.logInfo)
        }
        applyPauseState(
            resumeInfo: wasActive
                ? state.logInfo + " (resumed early by \(AdminCheck.currentUserLabel()))" : nil)
    }

    /// Idempotent enter/exit against `effectivePauseUntil`.
    private func applyPauseState(resumeInfo: String?) {
        let now = Date()
        if let d = settingsPause.effectiveUntil() { lastSettingsUntil = d }
        expirePanicIfDue(now: now)
        let shouldPause = effectivePauseUntil.map { $0 > now } ?? false
        if shouldPause, !appliedPause {
            enterPause()
        } else if shouldPause, let last = lastPauseMarker,
            now.timeIntervalSince(last) >= Self.pauseMarkerSecs
        {
            lastPauseMarker = now
            let until = effectivePauseUntil ?? now
            let remaining = until == .distantFuture
                ? "untilRestart" : "\(Int(until.timeIntervalSince(now)))s"
            logger.event("pause-tick", "paused=1 remaining=\(remaining)")
        } else if !shouldPause, appliedPause {
            appliedPause = false
            lastPauseMarker = nil
            // Whichever deadline was later is the one that just ended; the
            // panic wording is unchanged from before the generalization.
            let panicEnded = (lastPanicUntil ?? .distantPast) >= (lastSettingsUntil ?? .distantPast)
            let info = resumeInfo
                ?? (panicEnded ? "detection resumed after panic pause" : "source=ui-expiry")
            // Keep suppression and the UI's pending state until the serial
            // detector queue applies `paused = false`. No main-thread wait: a
            // blocked detector remains an honest Starting state and cannot
            // freeze the menu. A later pause invalidates this acknowledgement.
            pauseResumeAcknowledger.requestResume(
                applyBehavior: { [weak self] in self?.paused = false },
                onAcknowledged: { [weak self] in
                    guard let self else { return }
                    self.suppressed = false
                    self.setPanic(nil)
                    self.lastPanicUntil = nil
                    self.lastSettingsUntil = nil
                    self.logger.event("resume", info)
                })
        }
    }

    /// Queue a clock-driven pause expiry before any UI derived from that clock
    /// republishes. Main thread; also called by the settings poll.
    func refreshPauseState() {
        applyPauseState(resumeInfo: nil)
    }

    /// The pause expiry must keep running while AppKit tracks a menu or modal
    /// control. `Timer.scheduledTimer` installs only in the default mode, which
    /// let the common-mode UI poll publish "Protected" while behavior was
    /// still paused. Uses the existing receipted one-second cadence.
    static func schedulePauseTimer(onTick: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: pauseTickSecs, repeats: true) { _ in onTick() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    /// Latest settings-pause deadline seen while it was active, so the resume
    /// wording can tell a panic expiry from a parent-pause expiry.
    private var lastSettingsUntil: Date?

    /// The pause body, unchanged from the original panic(): suppress first so
    /// an in-flight overlay sync cannot resurrect windows, clear, then reset
    /// every detect-side state on detectQueue.
    private func enterPause() {
        // Every pause (granted panic, parent pause, SIGUSR2) turns the
        // Detection view off first. `panicUntil` is set before a panic-class
        // pause reaches here, so it names which.
        detectionView?.turnOff(
            reason: (panicUntil ?? .distantPast) > Date() ? .panicPause : .parentPause)
        pauseResumeAcknowledger.cancelPendingResume()
        if !appliedPause { lastPauseMarker = Date() }  // a repeat panic keeps the cadence
        appliedPause = true
        suppressed = true
        overlays.clearAll()
        detectQueue.async { [self] in
            paused = true
            resetDetectState()
            // Deliberately NOT inside `resetDetectState()` (2026-09-12: the
            // rest of this block is a helper also called from
            // `applyDisplayChange`). Both lines are correct for a
            // PANIC and wrong for a geometry change:
            //   - `heldStep`: panic takes every cover down, so a held frame
            //     must not re-paint pre-panic covers on resume. A hot-plug is
            //     the opposite case — `applyDisplayChange`'s own receipt says
            //     covers are NOT cleared there, because clearing would uncover
            //     content for the whole ~1 s stream rebuild. Emptying the
            //     fail-closed hold there would open exactly that window.
            //   - `clearStreak()`: its receipt argues from the pause ("the
            //     header says Paused, which outranks everything, and the first
            //     answered frame after the resume publishes the real
            //     recovery"). A geometry change pauses nothing, so clearing
            //     the streak there would silently hide an ONGOING detector
            //     failure from the parent until it rebuilt.
            heldStep = Pipeline.emptyStep
            detectorWatch.clearStreak()
        }
    }

    /// Every piece of detect-side state a DISCONTINUITY invalidates, in one
    /// place. detectQueue.
    ///
    /// Two callers, one body (asked for reuse, not a second reset):
    /// `enterPause`, which sets `paused` around it, and `applyDisplayChange`,
    /// which must invalidate exactly the same state WITHOUT pausing — every
    /// item below was measured, latched or attributed in the old display's
    /// point space.
    private func resetDetectState() {
        tracker.reset()
        coverOwnership?.reset()
        frozenRegions.removeAll()
        ownedRegions.removeAll()
        draggingRegions.removeAll()
        regionCurtainOwners.removeAll()
        prevCurtainRects.removeAll()
        // Panic takes every cover down, so nothing is painted: a stale
        // suppression rect must not survive into the resumed run. Same
        // reasoning for a geometry change — the rect it would suppress
        // against is in the previous display's coordinates.
        lastCurtainPainted.removeAll()
        lastBlocked.removeAll()
        // Drops the detect-side incumbency and pin state so a resumed run
        // cannot re-validate an incumbent, or ride a pin, from before the
        // pause. (Under `enterPause` the tracker's samples were already reset
        // on the main thread by `clearAll()`.)
        windowTracker?.setTracked([])
        // process() returns early while paused, so without this the media
        // boxes (and the diff baseline) would be minutes stale on resume.
        motionBoxes?.reset()
        Self.resetCurtain(curtain, gauge: logger)
        paintSmoother.reset()
    }

    /// The curtain's frames and the `activeCovers` gauge
    /// change together: the curtain tick writes the gauge after every
    /// `update`, and this is the one place the frames are discarded without
    /// one. (MEASURED 2026-09-23, production Build 15 on an M1 Mac):
    /// `reset()` alone left the gauge at its last value, and while paused
    /// nothing ticks, so every summary for about 95 min read `activeCovers 1` with
    /// nothing painted.
    /// Both callers take the curtain down: `enterPause` clears the overlay
    /// first; `applyDisplayChange` leaves the old layers frozen until the
    /// next overlay sync, which paints no curtain because none survives
    /// here. Static so `--ui-selftest` checks the same pairing.
    static func resetCurtain(_ curtain: Curtain?, gauge logger: FrameLogger) {
        curtain?.reset()
        logger.setActiveCovers(0)
    }

    // MARK: - Display topology

    /// Live only; nil under `--process`, which never reaches `start()`.
    private var displayWatcher: DisplayTopologyWatcher?
    /// The identity comes from the SCStream that started. Display-parameter
    /// notifications update only its inventory/name on the main thread.
    private var capturedDisplayScope: DisplayScope?

    /// One coalesced `didChangeScreenParameters` decision. Main thread.
    ///
    /// COVERS ARE NOT CLEARED HERE, deliberately: between this instant and the
    /// first frame of the new geometry a frozen black rectangle over-covers,
    /// while clearing would uncover content for the whole stream rebuild. That
    /// is decided on its own merits — NOT by analogy with the suspend path,
    /// whose own reason ("an inactive session's overlay is off-screen anyway")
    /// does not transfer: a hot-plug happens with someone watching. What IS
    /// stopped is the 60 Hz extrapolated repaint, which would otherwise advance
    /// rects measured in the old point space against the new screen — see
    /// `OverlayManager.displayGeometryChanged`.
    ///
    /// ACCEPTED COST, stated plainly: `resetDetectState()` calls
    /// `curtain.reset()`, so a curtain that was up must be re-earned after this
    /// — a new detector frame from the rebuilt stream PLUS the curtain entry
    /// debounce (`Curtain.triggerHits` = 3 hits inside `windowSecs` = 1 s) on
    /// top of the ~1 s rebuild. Region covers stay frozen on glass meanwhile.
    private func applyDisplayChange(_ decision: DisplayChangeDecision) {
        refreshDisplayScope(decision.inventory)
        // Off console, a burst can add or remove the session's only live
        // display even when the geometry we normalize against is unchanged,
        // so this runs on every burst. It logs only a park⇄protect edge.
        let resumedForChange =
            capture?.displaysChanged(geometryChanged: decision.changed) ?? false
        guard decision.changed else {
            // `didChangeScreenParameters` also fires for menu-bar, Dock and
            // colour-profile changes that move no geometry we normalize
            // against. Counted so the 60 s summary still shows the rate, not
            // logged per burst: acting would spend a stream rebuild (~1 s
            // blind, MEASURED — receipt at DisplayChangeGate.coalesceSecs) plus
            // a detect-state reset that re-pays the curtain entry debounce, for
            // nothing.
            detectQueue.async { [self] in
                logger.count("displayParamsNoChange", decision.coalesced)
            }
            return
        }
        if let info = decision.logInfo(source: "didChangeScreenParameters") {
            FileHandle.standardError.write(Data("capture: \(info)\n".utf8))
            logger.event("capture", info)
        }
        // Self-describing paint truth: a census divides the `paints` rects by
        // the screen size this record carries, so a changed screen re-states it
        // (the launch record is written by `start()`).
        logger.event(
            "screen",
            String(format: "points=%.1fx%.1f", decision.to.size.width, decision.to.size.height))
        if let target = displayTarget, !decision.to.isValid {
            // `--display` named a display that is no longer attached. REFUSED
            // LOUDLY rather than re-pointed: setting `targetScreen = nil` would
            // make `OverlayManager.resolvedScreen` fall back to
            // `NSScreen.screens.first` and paint this run's covers onto a
            // display it was told not to touch — the silent fall-back
            // `resolveDisplayTarget` promises never happens. The covers come
            // down because the content they guarded is on a display nobody is
            // being shown.
            let gone = "state=display-gone source=didChangeScreenParameters --display "
                + "\(target.id) is no longer attached — this run now protects NOTHING and "
                + "covers are withdrawn; the overlay is NOT re-pointed at another display "
                + "(fix: re-attach that display, or relaunch without --display)"
            FileHandle.standardError.write(Data("capture: \(gone)\n".utf8))
            logger.event("capture", gone)
            overlays.clearAll()
        } else {
            // Re-point the overlay at the display that now exists. `sync`
            // re-reads the screen's own frame every frame, so only the identity
            // and the global origin need pushing; a nil origin means
            // "screen-local == global", which is what no `--display` has always
            // meant. Main-thread state, set here on the main thread.
            overlays.targetScreen = DisplayGeometry.screen(displayID: displayTarget?.id)
            overlays.targetScreenOrigin = displayTarget.map { _ in decision.to.origin }
        }
        overlays.displayGeometryChanged(size: decision.to.size, origin: decision.to.origin)
        // BEFORE the geometry swap below, and synchronously: `beginRearm`
        // invalidates the capture generation gate on this thread, so a frame
        // from the OLD stream that is already queued early-returns in
        // `process()` instead of being normalized against the new geometry.
        // The stream must be rebuilt because its `config.width/height` are
        // derived from the display's size at `start()` (Capture.start) — a
        // stream built for the old geometry describes a display that is gone.
        // Skipped when an off-console resume above already re-armed for this
        // change (see `CaptureStream.displaysChanged`).
        if !resumedForChange {
            capture?.rebuildForDisplayChange("display geometry changed to \(decision.to.logText)")
        }
        // The new stream's first frame must earn fresh pixel-content and health
        // Receipts. Reuses the generation-gate path a re-arm already takes (and
        // is idempotent with the `onStreamGenerationInvalidated` callback the
        // rebuild above fires).
        requireNewCaptureFrameReceipt()
        let next = decision.to
        detectQueue.async { [self] in
            // Both writes land on the queue that READS them — `geometry` from
            // every conversion in `step`, `screenFrame` from `resolveOwners` —
            // so no detect thread can observe a half-updated pair. The
            // main-thread copy used to decide this change is the watcher's own.
            geometry = next
            windowTracker?.screenFrame = next.bounds
            resetDetectState()
        }
    }

    /// Main thread. A second display can appear while the captured display's
    /// geometry stays byte-for-byte identical. Refresh the persistent UI scope
    /// on that inventory-only transition without resetting detector state or
    /// rebuilding the stream.
    private func refreshDisplayScope(_ inventory: DisplayInventory) {
        guard let captured = capturedDisplayScope else { return }
        let refreshed = inventory.refreshing(captured)
        guard refreshed != captured else { return }
        capturedDisplayScope = refreshed
        if refreshed.hasUnprotectedDisplays {
            logger.event("capture", refreshed.logInfo)
        } else if captured.hasUnprotectedDisplays {
            logger.event(
                "capture",
                "state=display-scope displays=\(refreshed.displayCount) "
                    + "protected=\(refreshed.protectedDisplayID) unprotected=0 — "
                    + "no other AppKit display remains connected "
                    + "(fix: Pipeline.refreshDisplayScope)")
        }
        reportCapturedDisplayScope(refreshed)
        onDisplayScope?(refreshed)
    }

    /// Main thread. Capture owns the protected SCDisplay id. A fresh AppKit
    /// read reconciles any event that arrived while Capture.start was waiting;
    /// the watcher publishes later inventory changes.
    private func acceptCapturedDisplayScope(_ captured: DisplayScope) {
        // Capture can resolve after a display change whose notification raced
        // startup. Reconcile against a fresh main-thread AppKit inventory and
        // keep Capture's actual SCDisplay identity.
        let inventory = DisplayInventory.current()
        let current = inventory.refreshing(captured)
        capturedDisplayScope = current
        // TRIPWIRE: only a Mac this build cannot fully cover writes it, so a
        // grep finds exactly the installs where the multi-display gap is real.
        if current.hasUnprotectedDisplays { logger.event("capture", current.logInfo) }
        reportCapturedDisplayScope(current)
        onDisplayScope?(current)
    }

    /// Main thread. Also reachable via SIGUSR1 on a dev run (`--dev-inject`
    /// — DevSignals.swift, SPEC §8.1(8)).
    func inject() {
        detectQueue.async { [self] in injectUntil = CFAbsoluteTimeGetCurrent() + opts.injectSecs }
        logger.event(
            "inject",
            "fake box \(opts.injectRect) for \(opts.injectSecs)s")
    }

    /// SPEC §8.1(1): the chord must be held for `PanicHold.holdSecs` (owner
    /// 2026-09-02) before the hotkey asks for an administrator's password
    /// (PanicAuth.swift, owner 2026-09-01). Only a granted prompt reaches
    /// `panic(source: "hotkey")`, whose log strings are unchanged.
    private lazy var panicGate = PanicGate(
        log: { [weak self] event, info in self?.logger.event(event, info) },
        onGranted: { [weak self] in self?.panic(source: "hotkey") })
    private lazy var panicHold = PanicHold(
        log: { [weak self] event, info in self?.logger.event(event, info) },
        onFire: { [weak self] in
            // Before the administrator prompt: the panic path must never
            // leave a detections-only view (covers hidden) up behind it.
            self?.detectionView?.turnOff(reason: .panicHotkey)
            self?.panicGate.press()
        })

    /// Never fatal (2026-09-02; receipt at `HotkeyCenter.panicKey`): a failed
    /// `RegisterEventHotKey` used to `die(code: 6)` here, and 6 is passed
    /// through by agent-launch.sh, so the failure meant protection OFF with
    /// the watchdog kickstarting a doomed daemon every ~60 s. Now every
    /// outcome is a named `hotkey` record carrying the status, and a failed
    /// panic key also goes to alerts.log (AlertsLog.swift; a refused write is
    /// itself logged by name, never swallowed). The in-process Pipeline
    /// restart (onboarding `retryCaptureStartup`) re-binds the chord to this
    /// pipeline (`HotkeyRegistration.rebound`) — the old pipeline's closures
    /// are dropped, so the key drives the live overlays. The inject hotkey is
    /// registered only with `--dev-inject` (SPEC §8.2).
    private func registerHotkeys() {
        let panic = HotkeyCenter.shared.register(
            keyCode: HotkeyCenter.panicKey.code,
            onPress: { [self] in panicHold.press() },
            onRelease: { [self] in panicHold.release() })
        let injectResult: HotkeyRegistration? = opts.devInject
            ? HotkeyCenter.shared.register(keyCode: HotkeyCenter.injectKey.code) { [self] in inject() }
            : nil
        let outcome = HotkeyStartup.outcome(panic: panic, inject: injectResult)
        for record in outcome.records { logger.event(record.event, record.info) }
        guard let alert = outcome.alert else { return }
        let path = AlertsLog.resolvePath(logPath: opts.logPath)
        if let failure = AlertsLog.append(level: "ALERT", message: alert, path: path) {
            // Logger.event prints to stdout, which agent-launch.sh redirects
            // to agent.out (stderr → agent.err carries Logger.log only).
            logger.event("hotkey", "alerts.log append FAILED: \(failure) — the record above "
                + "(run.jsonl, agent.out) is the only copy; fix: make the file appendable by "
                + "this uid or relay it from run.jsonl (watchdog.sh)")
        } else {
            logger.event("hotkey", "alerts.log line written: \(path)")
        }
    }

    func shutdown() {
        // SPEC §8.1(1): every panic edge is a named record, including the
        // pipeline stopping under a running panic pause.
        if panic != nil { logger.event("panic-end", "reason=pipeline-stopped") }
        detectionView?.turnOff(reason: .shutdown)
        // A drained resume operation can still have its main acknowledgement
        // queued. Invalidate it before shutdown drains the detector queue, so
        // it cannot clear suppression or report resume after capture stops.
        pauseResumeAcknowledger.cancelPendingResume()
        // A tick already queued on main must not repaint after clearAll().
        suppressed = true
        displayWatcher?.stop()
        displayWatcher = nil
        curtainTickTimer?.cancel()
        curtainTickTimer = nil
        detectDeadlineTimer?.cancel()
        detectDeadlineTimer = nil
        // Before anything else: drop the sleep/wake observers and latch the
        // capture stream closed, so a stop produced by our own exit cannot
        // start a re-arm on the way out.
        capture?.shutdown()
        pauseTimer?.invalidate()
        idleTimer?.invalidate()
        overlays.clearAll()
        // On detectQueue, not main: the summary reads counters/frameCount/
        // inferenceMs that log()/count() mutate on detectQueue, and Dictionary
        // is not safe to sort while another thread inserts. A sync hop drains
        // any in-flight frame first and serializes the read with the writers.
        // Deadlock-safe: nothing on the detect path syncs back to main
        // (verified: no DispatchQueue.main.sync anywhere in the daemon).
        detectQueue.sync {
            self.cropWriter?.finish()
            // `clearAll()` above took every curtain down; the exit summary
            // must not report one as still painted.
            self.logger.setActiveCovers(0)
            self.logger.printSummary(elapsed: CFAbsoluteTimeGetCurrent() - startedAt)
        }
        if let tracker = windowTracker {
            let (polls, meanMs) = tracker.pollStats
            let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startedAt)
            // WALL time per call, not CPU: CGWindowListCopyWindowInfo is a
            // synchronous IPC round trip to WindowServer and the thread is
            // blocked, not running, for most of it. Measured in-process it is
            // ~1.0 ms/call against 0.093 ms for the same call in an idle
            // standalone probe on this machine (scratchpad/pollcost.swift) —
            // a 10x IPC-latency difference, not a 10x CPU difference. The CPU
            // receipt is the process A/B: 25.1% of one core with tracking on vs
            // 24.9% off, same scene, 20 s each (scratchpad/cpu_ab.sh).
            print(String(
                format: "-- windowTracker: %d polls (%.1f Hz), %.3f ms wall/poll (IPC-blocked); "
                + "%d ownership walks, %.3f ms wall/walk",
                polls, Double(polls) / elapsed, meanMs,
                ownerWalks, ownerWalks > 0 ? ownerMsTotal / Double(ownerWalks) : 0))
            tracker.stop()
        }
    }
}

/// Headless replay: feed logged raw detections through Policy + Tracker and
/// write a fresh tracking log. Deterministic; runs in milliseconds; needs no
/// screen, model, or permissions.
func runReplay(_ path: String, opts: Options) -> Never {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        die("cannot read replay file: \(path)", code: 66)
    }
    if opts.cover == .media {
        print("WARNING: --cover media has no effect with --replay "
            + "(logs carry no pixels, so no media boxes); replaying as region mode")
    }
    let tracker = Tracker(
        clearAfter: opts.clearFrames,
        stickyHold: Tracker.defaultStickyHold(fps: opts.fps))
    tracker.setTuning(opts.tuning, fps: opts.fps, clearAfterOverride: opts.clearFramesOverride)
    // Same curtain-mode region-entry debounce as the live pipeline (receipt
    // at Tracker.confirmedEntries).
    if opts.cover == .curtain { tracker.curtainEntry = true }
    let logger = FrameLogger(path: opts.logPath, quiet: true, mode: opts.logMode)
    var frames = 0
    var minBoxPtUnmeasured = 0
    var stepUnmeasured = 0
    var replayBlocked: [Detection] = []  // score hysteresis input, as `Pipeline.lastBlocked`
    for line in text.split(separator: "\n") {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any],
            let rawDetections = obj["detections"] as? [[String: Any]]
        else { continue }  // skip event records
        let detections: [Detection] = rawDetections.compactMap { d in
            guard let label = d["label"] as? String,
                let conf = d["conf"] as? Double,
                let box = d["box"] as? [Double], box.count == 4
            else { return nil }
            return Detection(
                label: label, confidence: Float(conf),
                box: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]))
        }
        // Replay never constructs a curtain, so nil policy resolves strict —
        // the same rule Pipeline.effectivePolicy applies (review P2: a
        // curtain-mode replay must not score against the weaker policy).
        // A log carries no screen size, so a configured point floor is
        // unmeasurable here (TuningPolicy.minBox `.unmeasured`): counted and
        // printed below, never skipped silently.
        let filtered = opts.tuning.filter(
            detections, mode: opts.policy ?? .strict, blockFaces: opts.blockFaces, screen: .zero,
            tracked: .forCover(curtain: opts.cover == .curtain, lastBlocked: replayBlocked))
        replayBlocked = filtered.blocked
        minBoxPtUnmeasured += filtered.minBoxPtUnmeasured
        stepUnmeasured += filtered.stepUnmeasured
        let regions = tracker.update(detections: filtered.blocked)
        logger.log(detections: detections, regions: regions, inferMs: 0, totalMs: 0)
        frames += 1
    }
    print("replayed \(frames) frames from \(path)")
    if minBoxPtUnmeasured > 0 {
        print("WARNING: tuning minBoxPt is configured but --replay carries no screen size; "
            + "\(minBoxPtUnmeasured) boxes passed the point floor unmeasured (tuningMinBoxPtUnmeasured)")
    }
    if stepUnmeasured > 0 {
        print("WARNING: tuning thresholdSteps are configured but --replay carries no screen size; "
            + "\(stepUnmeasured) boxes were judged by the flat threshold instead "
            + "(tuningThresholdStepUnmeasured)")
    }
    exit(0)
}

let opts = Options.parse()
// Before any mode branch, so --process, --ui-selftest, a scenario script and a
// live run all shout equally. One-shot; silent unless actually translated.
HostArch.warnIfTranslatedOnce()
if let replayPath = opts.replay {
    runReplay(replayPath, opts: opts)
}
// Before NSApplication: pixel replay never touches AppKit, the window server,
// or the capture permission.
if let videoPath = opts.process {
    runPixelReplay(videoPath, opts: opts)
}
// Machine diagnostic and its checks (PerfTier.swift). Same placement rule as
// the selftests below: after the two headless returns, before AppKit. Neither
// mode loads the model, opens a window, or asks for capture permission, and
// the gate never invokes either — `--process` is the gate's only entry point.
// Effective tuning as JSON (TuningPolicy.swift), for the harness and the dev
// tab. Same placement rule as the selftests: after the headless returns,
// before AppKit. The state root's tuning.json is layered the way
// the running agent would.
if opts.printTuning {
    var policy = opts.tuning
    var sources = [opts.tuningSource]
    switch TuningFile.read(stateRoot: UISettingsStore.resolveRoot().root, base: policy) {
    case .absent: break
    case let .refused(why):
        FileHandle.standardError.write(Data("tuning: REFUSED \(why) — not applied\n".utf8))
    case let .loaded(p):
        policy = p
        sources.append(TuningFile.fileName)
    }
    var object = policy.jsonObject
    object["sources"] = sources
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}
if opts.probeSelfTest {
    exit(PerfTier.selftest())
}
if opts.resilienceSelfTest {
    exit(ResilienceSelfTest.run())
}
if let package = opts.compileModelCache {
    exit(Detector.installCompiledCacheCommand(packagePath: package))
}
if let package = opts.checkModelCache {
    exit(Detector.checkCompiledCacheCommand(packagePath: package))
}
if opts.probe {
    exit(PerfTier.runProbe(opts: opts))
}
// Executable asserts for the parent-UI code (spec §10.3). After the two
// headless returns (spec §12 rule 2, so their order is untouched) and before
// AppKit: it must never touch the family's real settings.json.
if opts.uiSelfTest {
    exit(UISelfTest.run())
}
if opts.onboardingSelfTest {
    exit(MainActor.assumeIsolated { UIOnboardingSelfTest.run() })
}
let startedAt = CFAbsoluteTimeGetCurrent()
let processStartedAt = Date()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Resolve --display (if given) before anything else touches a screen or asks
// for Screen Recording permission: an unknown id must fail loudly right here,
// not fall through to the main display three log lines later.
let displayTarget: DisplayTarget? = opts.displayID.map(resolveDisplayTarget)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pipeline: Pipeline?
    /// TUNING TOOL: the tuning.json
    /// policy in force, nil when the file is absent or was refused. Polled
    /// on the settings store's 1 Hz tick by (ino, mtime, size) — the same
    /// cost the license monitor pays per file per tick.
    private var tuningFilePolicy: TuningPolicy?
    private var tuningFileSignature: TuningFile.Signature?
    /// The Settings › Developer model (UIDevTuning.swift); built with the
    /// UI in startSettings, so it exists before any pipeline.
    private var devTuning: UIDevTuning?
    /// `dev-overrides.json` `log.mode` (DevOverrides.swift), read in
    /// startSettings — before startPipeline builds the FrameLogger — so it
    /// replaces config.json's `logMode` for every record of the run.
    private var devLogMode: LogMode?
    private var tuningFilePolled = false
    /// The file existed at the last poll (loaded OR refused), so its removal
    /// is logged either way — a REFUSED record must have a resolution.
    private var tuningFilePresent = false

    private func pollTuningFile(stateRoot: String, log: (String, String) -> Void) {
        let sig = TuningFile.signature(stateRoot: stateRoot)
        guard !tuningFilePolled || !TuningFile.sameSignature(sig, tuningFileSignature) else { return }
        tuningFilePolled = true
        tuningFileSignature = sig
        let path = stateRoot + "/" + TuningFile.fileName
        let outcome = TuningFile.read(stateRoot: stateRoot, base: opts.tuning)
        defer { tuningFilePresent = outcome != .absent }
        // The Developer tab's "applied HH:MM:SS" is this same outcome, at
        // this same moment (UIDevTuning.noteOutcome) — the stamp is the
        // `tuning` record's time, not a guess from the write.
        devTuning?.noteOutcome(outcome)
        switch outcome {
        case .absent:
            guard tuningFilePresent else { return }
            let hadPolicy = tuningFilePolicy != nil
            tuningFilePolicy = nil
            log("tuning", "\(path) removed — "
                + (hadPolicy ? "back to the launch policy (\(opts.tuningSource))"
                    : "the refused file is gone; the launch policy (\(opts.tuningSource)) was in force throughout"))
            if hadPolicy { pipeline?.setTuning(opts.tuning, source: opts.tuningSource) }
        case let .refused(why):
            // Loud, by key, and the previous policy stays in force — a
            // half-applied file would be a number nobody can see.
            log("tuning", "REFUSED \(why) — keeping the previous policy "
                + "(fix: correct the file, or remove it to return to \(opts.tuningSource))")
        case let .loaded(p):
            tuningFilePolicy = p
            if let pipeline {
                pipeline.setTuning(p, source: TuningFile.fileName)
            } else {
                log("tuning", "\(path) loaded before capture started; applied when the pipeline starts")
            }
        }
    }
    /// Alive only while this process has no Pipeline (see HoldHeartbeat.swift).
    /// Stopped by `startPipeline`.
    private var holdHeartbeat: HoldHeartbeat?
    private let banner = CaptureLossBanner()
    private let statusToast = StatusToast()
    private var pollTimer: Timer?
    /// Preflight poll cadence while in the capture-lost state. DERIVED: the
    /// preflight is a local TCC lookup (no IPC to the capture stack), so the
    /// cost is negligible at any sane cadence; 5 s means a parent's re-grant
    /// restores the filter within two poll periods, which reads as
    /// "immediately" next to the trip to System Settings it follows.
    /// CAVEAT (MEASURED 2026-08-21, macOS 26.6): a running process's
    /// preflight is SOMETIMES CACHED — 60+ s of polling never saw a re-grant
    /// that a fresh launch honored instantly. Downgraded from "always" by a
    /// second MEASURED live reading (owner, 2026-08-26): with the Quit &
    /// Reopen alert left open the poll DID see the re-grant and
    /// `retryAfterCaptureLoss` re-armed capture with no relaunch. Both
    /// readings stand; which one a given outage gets is not ours to choose.
    /// CORRECTED 2026-08-28 (review): the old closing sentence — "recovery
    /// actually rides on `captureLossRelaunchSecs` below" — was FALSE. Exit 7
    /// is gated on this same preflight reading TRUE (poll body below), so in
    /// the cached-FALSE case neither this poll nor exit 7 can fire and there
    /// is NO in-process self-heal. What covers that case is outside this
    /// process: macOS's own "Quit & Reopen" after the Screen Recording toggle
    /// (SIGKILL ⇒ exit 137 ⇒ packaging/agent-launch.sh relaunches, and the
    /// fresh process reads TCC correctly), and the owner's 2026-08-26 live
    /// measurement that the cached read is not the only outcome. The poll is
    /// kept (free, and a future macOS may drop the staleness).
    static let captureLossPollSecs: TimeInterval = 5
    /// How long a SEEN re-grant (preflight true) may go without capture
    /// coming back live before the process EXITS 7 so a fresh launch can
    /// re-evaluate TCC. OWNER 2026-08-26: this used to fire on plain time in
    /// the lost state (120 s), which blinked the icon + toast and re-showed a
    /// dismissed toast every 2 min while a parent was still walking to
    /// Settings. MEASURED live 2026-08-26: the in-process poll DID see the
    /// re-grant and `retryAfterCaptureLoss` restored capture with no
    /// relaunch, so this relaunch is the SECOND line for that same path.
    /// SCOPE, corrected 2026-08-28 (review): it covers exactly
    /// preflight-TRUE-but-capture-stuck-for-30 s.
    /// With preflight cached-false there is no in-process self-heal at all;
    /// see the caveat at captureLossPollSecs for what covers it (exit 137 via
    /// Quit & Reopen, plus the owner's live measurement).
    /// DERIVED: 30 s = 6 polls, well past the ≤3.4 s re-arm the
    /// startup receipt shows. Exit code 7 = "grant seen, capture stuck".
    /// COUPLED (2026-08-28): this value sets the exit-7 relaunch cadence
    /// (≈3.4 s start + captureLossPollSecs + this, rounded up to a poll tick),
    /// and that cadence is an input to `RELAUNCH_BURST` in
    /// packaging/agent-launch.sh. Cutting it again without re-deriving that
    /// budget takes protection down: the 120→30 cut already drove the old
    /// budget's margin to zero.
    static let captureLossRelaunchSecs: TimeInterval = 30

    /// How long a capture loss must PERSIST before the parent-visible
    /// `alerts.log` ALERT is written (2026-09-11).
    ///
    /// Deliberately the SAME CONSTANT as `captureLossRelaunchSecs`, not a
    /// second number: 30 s is already the line this process draws between
    /// "capture is slow to come back" and "capture is stuck", and the exit-7
    /// rule is derived against it. Before this, the ALERT was written the
    /// instant `.lost` was published, so a wake that outlasted the DERIVED
    /// 5 x 1 s re-arm budget (`CaptureStream.rearmAttempts`, still with no live
    /// sleep/wake run behind it) put "protection is NOT running" in front of a
    /// parent for a machine that recovered a second later.
    ///
    /// ORDERING, why the real failure still alarms: exit 7 cannot fire until
    /// `captureLossRelaunchSecs` after the FIRST POLL that saw the grant, which
    /// is at least one `captureLossPollSecs` period after the loss — so this
    /// deadline always lands first and a genuinely stuck capture still writes
    /// its ALERT before the relaunch.
    ///
    /// THE HELD ALERT IS LOST IF THIS PROCESS DIES INSIDE THE WINDOW, and that
    /// is correct — do not "fix" it by flushing `pendingCaptureAlert` on the way
    /// out, which would undo this whole mechanism (a TTL exit during a 30 s
    /// re-arm is exactly the slow wake the hold exists to swallow). Every branch
    /// is already answered, by a different rail in two of the three cases:
    ///   - died once, relaunched, capture works  -> the outage WAS transient.
    ///     Nothing should have been written.
    ///   - died once, relaunched, capture still lost -> a new hold arms on the
    ///     new process and writes its ALERT 30 s later. Only the timestamp moves.
    ///   - dies repeatedly, protection stays off -> `agent-launch.sh` trips
    ///     RELAUNCH_BURST and `watchdog.sh` writes the parent-visible ALERT for
    ///     the marker itself (agent-launch.sh "2026-09-02 watchdog.sh reports the
    ///     marker"). That is the rail for "the daemon is gone", and it is a
    ///     better signal than a capture-health line would be.
    /// Written down because the hole looks open at this symbol and is closed
    /// somewhere else (review, 2026-09-11).
    ///
    /// DEV BYPASS: `SENTRY_CAPTURE_ALERT_DELAY_S=0`
    /// restores the immediate write, so a harness asserting the ALERT line does
    /// not wait 30 s. The installed LaunchAgent line carries no environment,
    /// so production runs the receipt.
    /// A value that is not a number >= 0 is REFUSED BY NAME on stderr and the
    /// receipt stands — never a silent fall-back.
    static let captureAlertDelaySecs: TimeInterval = {
        let name = "SENTRY_CAPTURE_ALERT_DELAY_S"
        guard let raw = DevEnv.knob(name) else {
            return captureLossRelaunchSecs
        }
        guard let secs = TimeInterval(raw), secs >= 0, secs.isFinite else {
            FileHandle.standardError.write(Data((
                "capture: \(name)=\(raw) REFUSED — must be a number >= 0; the receipt stands "
                + "(\(Int(captureLossRelaunchSecs))s, fix: AppDelegate.captureAlertDelaySecs)\n"
            ).utf8))
            return captureLossRelaunchSecs
        }
        return secs
    }()

    /// TTL expiry exit status: 75 (EX_TEMPFAIL, "try again"), distinct from
    /// the 0 a SIGTERM/shutdown returns. packaging/agent-launch.sh relaunches
    /// 75 for the periodic TTL and 7 for the one-shot TCC/onboarding handoff,
    /// both under its RELAUNCH_BURST Tripwire. Other exits, including config
    /// error 64, are not relaunched. This closes the daily dead-man gap
    /// (MEASURED 2026-08-25: 14-61 s a day with no process). Dev harnesses
    /// that check for a clean TTL exit read this constant, not 0.
    static let ttlExitCode: Int32 = 75

    /// Quit & Reopen from the Screen Recording prompt is a Quit AppleEvent,
    /// not a signal (MEASURED fi-reset-02, 2026-08-29: no TERM logged by the
    /// daemon or the wrapper, job last exit 0, 60 s watchdog gap). NSApp's
    /// default answer exits 0 — "launchd stopped us" to agent-launch.sh. With
    /// the handoff armed, answer with the handoff exit instead so the wrapper
    /// relaunches at once and the wizard resumes from its durable request.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let code = Self.terminationExitCode(handoffArmed: onboardingHandoffArmed)
        FileHandle.standardError.write(Data(
            (code == 7
                ? "onboarding: quit request during armed handoff (Quit & Reopen) — exiting 7 for relaunch\n"
                : "app: quit AppleEvent outside a handoff (Quit & Reopen, osascript, logout) — exiting \(code) for relaunch\n").utf8))
        pipeline?.shutdown()
        exit(code)
    }

    /// Quit AppleEvents never mean "stop protecting". Armed handoff → 7 (the
    /// PID-paired onboarding/repair relaunch). Anything else → 137, the
    /// wrapper's quit-reopen relaunch code: MEASURED 2026-08-29 07:54-07:58Z,
    /// three Quit & Reopen clicks outside an armed handoff each exited 0 and
    /// waited ~60 s for the watchdog (kickstarts 07:54:56/07:56:56/07:57:56).
    /// The same event is what `osascript -e 'quit app "SentryScreen"'` sends,
    /// so a child's quit is now a ≤3 s relaunch under RELAUNCH_BURST (10/120 s)
    /// instead of a 60 s gap. Logout/shutdown also send this event; the one
    /// relaunch it causes is killed with the session and stays within budget.
    /// Only launchd's SIGTERM (bootout/uninstall) exits 0.
    static let quitReopenExitCode: Int32 = 137
    nonisolated static func terminationExitCode(handoffArmed: Bool) -> Int32 {
        handoffArmed ? 7 : quitReopenExitCode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, in every mode: an accessory app has no main menu, and
        // without one AppKit has no Edit menu to route Cmd-X/C/V/A through,
        // so a text field could not be pasted into. The menu is never shown; it exists for the key
        // equivalents. Cmd-W closes the Setup window through the same route
        // (UIOnboardingWindowController.windowShouldClose decides).
        NSApp.mainMenu = Self.makeMainMenu()
        if opts.hotkeyTest {
            runHotkeyTest()
            return
        }
        // TTL is the dead-man rail and must arm even when launch stalls in
        // the banner-wait state below — a wedged permission wait is exactly
        // the kind of run it exists to bound.
        if opts.ttl > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(opts.ttl)) {
                self.pipeline?.shutdown()
                print("ttl reached, exiting \(Self.ttlExitCode)")
                exit(Self.ttlExitCode)
            }
        }
        if opts.uiDemo {
            runUIDemo()
            return
        }
        if let scenario = opts.uiOnboardingDemoScenario {
            uiOnboardingDemo = UIOnboardingDemoEntrypoint.start(scenario: scenario)
            return
        }
        // Machine-wide state + the parent UI, before the preflight (spec §2:
        // "constructed last in applicationDidFinishLaunching"). It must exist
        // in the banner-wait path below too. Degraded health and banner
        // visibility are separate: a runtime-owned repair surface suppresses
        // the duplicate banner while the status state remains degraded.
        startSettings()
        let permissionApproved = CGPreflightScreenCaptureAccess()
        if let onboardingRuntime {
            switch MainActor.assumeIsolated({
                onboardingRuntime.start(screenRecordingApproved: permissionApproved)
            }) {
            case .startCapture:
                startPipeline()
            case let .waitForParent(showCaptureLoss):
                if showCaptureLoss {
                    setCaptureHealth(
                        .lost(since: Date(), reason: "parent onboarding or permission repair required"),
                        showBanner: true)
                }
            }
            return
        }
        if !permissionApproved {
            // Registers the bundle in the Screen Recording pane and (first
            // time) triggers the system prompt — without this call the app
            // never appears in Settings at all (spike A1, 2026-08-21).
            CGRequestScreenCaptureAccess()
            guard opts.captureLossBanner else {
                die("""
                    Screen Recording permission missing. Grant it in System Settings >
                    Privacy & Security > Screen & System Audio Recording, then rerun.
                    (The permission attaches to whichever identity launched this: the
                    SentryScreen.app bundle under launchd, or your terminal app when
                    run from a shell.)
                    """, code: 3)
            }
            FileHandle.standardError.write(Data(
                ("capture: state=lost permission missing at launch — banner up, polling "
                + "preflight every \(Self.captureLossPollSecs)s\n").utf8))
            // Panic hotkey is DELIBERATELY not armed in this state: it exists
            // to clear detection covers, and none exist yet — the only window
            // is the informational toast (Banner.swift), and TTL bounds the wait.
            // Revisit if the toast ever grows beyond an informational panel
            // with its ✕ and Open Settings (a kid cannot pause or disable from it).
            // Hook 1 (spec §8): banner up ⇒ the UI says Degraded.
            setCaptureHealth(
                .lost(since: Date(), reason: "Screen Recording permission missing at launch"),
                showBanner: true)
            startCaptureLossPoll()
            return
        }
        startPipeline()
    }

    /// The hidden main menu (see applicationDidFinishLaunching). Nil targets:
    /// the responder chain — the focused text field for Edit, the key
    /// window for Close. The UI selftest checks the Edit selectors.
    static let editMenuSelectors: [Selector] = [
        NSSelectorFromString("undo:"), NSSelectorFromString("redo:"),
        #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
        #selector(NSText.selectAll(_:)),
    ]
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String)] = [
            ("Undo", editMenuSelectors[0], "z"), ("Redo", editMenuSelectors[1], "Z"),
            ("Cut", editMenuSelectors[2], "x"), ("Copy", editMenuSelectors[3], "c"),
            ("Paste", editMenuSelectors[4], "v"), ("Select All", editMenuSelectors[5], "a"),
        ]
        for (title, action, key) in items { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        for sub in [file, edit] {
            let item = NSMenuItem()
            item.submenu = sub
            main.addItem(item)
        }
        return main
    }

    /// Model load + pipeline start, shared by the granted-at-launch path and
    /// the banner-wait path's first successful poll.
    private func startPipeline() {
        // A rebuilt pipeline starts with the Detection view off: the old
        // pipeline's window, trace and exclusion go with it.
        uiActions?.detectionView.detach(reason: .pipelineRebuild)
        do {
            var pipelineOpts = opts
            // dev-overrides.json `log.mode` beats config.json's
            // `logMode`; logged as a `dev-override`
            // line by startSettings before this point.
            if let mode = devLogMode { pipelineOpts.logMode = mode }
            pipeline = try Pipeline(opts: pipelineOpts, displayTarget: displayTarget)
        } catch {
            // A trusted model that will not load is repaired by the root
            // watchdog, which acts on this marker (Detector.TrustedLoadFailed).
            if error is Detector.TrustedLoadFailed, let logPath = opts.logPath {
                let marker = URL(fileURLWithPath: logPath).deletingLastPathComponent()
                    .appendingPathComponent(Detector.loadFailedMarker).path
                if !FileManager.default.createFile(atPath: marker, contents: Data("\(error)\n".utf8)) {
                    FileHandle.standardError.write(Data(("model: could not write \(marker) — the watchdog "
                        + "will not see that the trusted model failed to load (fix: reinstall the package)\n").utf8))
                }
            }
            // The initial model failure can precede FrameLogger construction.
            // Keep the repair UI alive on the first launch and on retries.
            holdHeartbeat = HoldHeartbeat.pipelineFailed(
                existing: holdHeartbeat, path: opts.logPath,
                quiet: opts.quiet, mode: opts.logMode)
            if let onboardingRuntime {
                MainActor.assumeIsolated {
                    onboardingRuntime.captureFailed(
                        component: "Detector model", reason: "The detector could not start: \(error)")
                }
                return
            }
            die("model load failed: \(error)", code: 4)
        }
        // Only now: the rebuilt Pipeline brings its own idle tick and a fresh
        // logger (which rolled run.jsonl); the hold heartbeat must not
        // outlive it. Stopped AFTER init succeeds, never before (see catch).
        holdHeartbeat?.stop()
        holdHeartbeat = nil
        // A rebuilt pipeline starts from the launch tuning; re-apply a
        // tuning.json that is already in force so a capture restart cannot
        // silently revert a developer's override.
        if let t = tuningFilePolicy { pipeline?.setTuning(t, source: TuningFile.fileName) }
        // The Developer tab's readout rides this pipeline (set before
        // `start()` below, so no frame is missed).
        pipeline?.tuningReadout = devTuning?.readout
        // The Detection view attaches off; the UI turns it on (PIN).
        if let pipeline { uiActions?.detectionView.attach(pipeline) }
        pipeline?.capture.onStreamGenerationInvalidated = { [weak self] in
            self?.pipeline?.requireNewCaptureFrameReceipt()
            // A rebuilt stream carries a fresh content filter: the view hides
            // until the re-arm's exclusion refresh names its window again.
            self?.uiActions?.detectionView.streamInvalidated()
            if let runtime = self?.onboardingRuntime {
                MainActor.assumeIsolated {
                    runtime.captureGenerationInvalidated()
                }
            } else {
                self?.setCaptureHealth(.starting)
            }
        }
        if opts.captureLossBanner {
            pipeline?.capture.onCaptureLost = { [weak self] in
                self?.pipeline?.requireNewCaptureFrameReceipt()
                if let runtime = self?.onboardingRuntime {
                    // Let the runtime establish the one parent-owned repair
                    // surface before AppDelegate decides whether the fallback
                    // banner is needed. reportHealth performs that decision.
                    MainActor.assumeIsolated {
                        runtime.captureWasLost(reason: "The screen capture stream stopped.")
                    }
                } else {
                    // Development and non-onboarding sessions have no parent
                    // repair surface, so the banner remains their fail-loud UI.
                    self?.setCaptureHealth(
                        .lost(since: Date(), reason: "capture stream lost"),
                        showBanner: true)
                }
                self?.startCaptureLossPoll()
            }
        }
        // Non-onboarding runs report protecting on the first valid frame.
        pipeline?.onCaptureHealth = { [weak self] health in self?.setCaptureHealth(health) }
        if onboardingRuntime != nil {
            pipeline?.onFirstCaptureFrame = { [weak self] in
                MainActor.assumeIsolated {
                    self?.onboardingRuntime?.captureProducedFirstFrame()
                }
            }
            pipeline?.onCaptureStartFailure = { [weak self] reason in
                MainActor.assumeIsolated {
                    self?.onboardingRuntime?.captureFailed(
                        component: "Screen capture", reason: reason)
                }
            }
        }
        pipeline?.onCurtainDrop = { [weak self] item in
            DispatchQueue.main.async { self?.uiState?.recordDrop(item) }
        }
        // 2026-09-11: the two inputs the status surface
        // could not represent. Both arrive on the main thread already (the
        // Pipeline hops for them), and both are plain state pushes — nothing
        // here touches capture or the pipeline back.
        if let activePipeline = pipeline {
            activePipeline.onDetectorHealth = { [weak self, weak activePipeline] health in
                guard let self, let activePipeline, self.pipeline === activePipeline else { return }
                self.applyDetectorHealth(health)
            }
        }
        pipeline?.onDisplayScope = { [weak self] scope in self?.uiState?.displayScope = scope }
        if let activePipeline = pipeline {
            // A replaced pipeline cannot complete its pending acknowledgement.
            // Seed the new pipeline's UI before installing its callback.
            uiState?.pauseResumePending = false
            activePipeline.onPauseResumePending = { [weak self, weak activePipeline] pending in
                guard let self, let activePipeline, self.pipeline === activePipeline else { return }
                self.uiState?.pauseResumePending = pending
            }
            // Panic pause → the popover's Paused state and the one toast
            // (owner 2026-09-29, plan §6 item 3). A replaced pipeline's
            // panic died with it, so seed nil first.
            uiState?.panicPause = nil
            activePipeline.onPanicPause = { [weak self, weak activePipeline] panic in
                guard let self, let activePipeline, self.pipeline === activePipeline else { return }
                let previous = self.uiState?.panicPause
                self.uiState?.panicPause = panic
                // An early resume or expiry takes back a "Paused until"
                // toast still queued or showing.
                if panic == nil { ToastArbiter.shared.withdraw(id: PanicToast.toastID) }
                if UIDriver.scriptPath == nil,
                    let spec = PanicToast.spec(previous: previous, next: panic) {
                    ToastArbiter.shared.present(spec)
                }
            }
            uiActions?.endPanicPause = { [weak self, weak activePipeline] in
                guard let self else { return }
                guard let activePipeline, self.pipeline === activePipeline else {
                    // Not silent: the click reached no pipeline (its panic
                    // pause ended with it).
                    let info = "panic-end ignored: no live pipeline"
                    FileHandle.standardError.write(Data("pause: \(info)\n".utf8))
                    self.holdHeartbeat?.logger.event("pause", info)
                    return
                }
                activePipeline.endPanicPause(by: AdminCheck.currentUserLabel())
            }
        }
        // The logger exists now: replay whatever the UI logged before it did.
        if let logger = pipeline?.logger {
            for (event, info) in pendingUIRecords { logger.event(event, info) }
            pendingUIRecords.removeAll()
        }
        // Spec §5: the machine-wide pause is applied BEFORE capture starts, so
        // a machine paused at 3 pm is still paused after a 3:05 pm watchdog
        // kickstart. (The store itself started earlier, in
        // applicationDidFinishLaunching, when there was no pipeline to tell.)
        if let settings = settingsStore?.settings {
            pipeline?.setSettingsPause(settings.pause)
            // Spec §6 precedence, resolved in one place: Pipeline owns the
            // tail of the chain and pushes it to the picker, so the two
            // cannot disagree about what "Standard" means for this run.
            uiState?.basePolicy = pipeline?.basePolicy ?? .standard
            uiState?.policyPinned = pipeline?.policyPinnedByFlag ?? false
            // No actor: this is the file as found at launch, not an edit.
            pipeline?.setPolicy(settings.policyOverride, by: nil, source: "settings")
        }
        pipeline?.start()
    }

    // Machine-wide UI state. Every session —
    // admin or not — observes it, so a parent's pause reaches the child's
    // session. Started BEFORE capture so a machine paused at 3 pm is still
    // paused after a 3:05 pm watchdog kickstart.
    private var settingsStore: UISettingsStore?
    private(set) var uiState: UIState?
    /// Mutations + the PIN gate behind them (spec §4, §6). Admin or not, the
    /// object is cheap and stateless until something calls it; the status
    /// item — which only an admin session has — is what puts it on screen.
    private var uiActions: UIActions?
    /// Present only for the installed `--capture-loss banner` application.
    /// Development and replay modes preserve their existing behavior.
    private var onboardingRuntime: UIOnboardingRuntime?
    /// True between "Open System Settings" and the fresh-process handoff. The
    /// SIGTERM handler reads it: macOS's Quit & Reopen after a Screen Recording
    /// toggle terminates this process with a plain TERM, and exiting 0 there
    /// told agent-launch.sh "launchd stopped us" — no relaunch until the
    /// watchdog's next pass (MEASURED fi-reset-01, 2026-08-29: window gone,
    /// nothing for up to 60 s). Exit 7 is the handoff code the wrapper
    /// relaunches with a PID-paired receipt.
    var onboardingHandoffArmed: Bool {
        MainActor.assumeIsolated { onboardingRuntime?.captureLossPollIsSuperseded == true }
    }
    /// The activity feed (spec §7); reads only while the popover is open.
    private var uiActivity: UIActivity?
    /// The parent's menu-bar item, in admin sessions only (spec §9.1).
    private var statusItem: UIStatusItem?
    /// stderr + run.jsonl, set by startSettings so syncStatusItem can say
    /// why an icon does or does not exist.
    private var uiLog: ((String, String) -> Void)?
    /// UI records emitted before the pipeline (and its FrameLogger) exists.
    /// startSettings now runs first — it must, or the §8 Degraded invariant
    /// is false in the banner-wait path — so the session/admin line and the
    /// status item's creation would be stderr-only and never reach run.jsonl,
    /// which is where §9.1 says that answer lives. Buffered, then flushed the
    /// moment the logger appears.
    private var pendingUIRecords: [(String, String)] = []
    /// Cap on that buffer. DERIVED: launch emits 2-4 records (dev fallback,
    /// session/admin, status item); the only other pre-pipeline source is a
    /// settings change during a permission wait, which is episode-rate. 64 is
    /// ~15x the expected worst case, so hitting it means something is logging
    /// in a loop — which it then says once, loudly, instead of growing without
    /// bound.
    static let pendingUIRecordCap = 64

    private func startSettings() {
        // Reachable twice: the launch-wait poll calls startPipeline() after
        // this already ran. One store, one poll timer, one status item.
        guard settingsStore == nil else { return }
        // The logger is resolved lazily: this now runs before the pipeline
        // exists, so records go to stderr immediately and are buffered for
        // run.jsonl until there is a logger to take them.
        let log: (String, String) -> Void = { [weak self] event, info in
            FileHandle.standardError.write(Data("\(event): \(info)\n".utf8))
            guard let self else { return }
            if let logger = self.pipeline?.logger ?? self.holdHeartbeat?.logger {
                // During a hold the pipeline's logger lives on in the
                // heartbeat, so license/UI records keep reaching run.jsonl
                // instead of a 64-record buffer over a hold that can last
                // days.
                logger.event(event, info)
            } else if self.pendingUIRecords.count < Self.pendingUIRecordCap {
                self.pendingUIRecords.append((event, info))
                if self.pendingUIRecords.count == Self.pendingUIRecordCap {
                    FileHandle.standardError.write(Data((
                        "ui: pre-pipeline log buffer full at budget "
                        + "AppDelegate.pendingUIRecordCap=\(Self.pendingUIRecordCap); further "
                        + "UI records are stderr-only until capture starts\n").utf8))
                }
            }
        }
        uiLog = log
        // Toast buttons (Banner.swift): the dismissal is free but on the
        // record, so the health report shows who closed it and when.
        banner.onDismiss = { log("ui", "capture-loss banner dismissed by click "
            + "(menu-bar shield stays red; popover keeps Fix until the grant returns)") }
        banner.onFix = { [weak self] in
            guard let self else { return }
            if let runtime = self.onboardingRuntime {
                log("ui", "capture-loss banner Fix clicked — routing through classified repair")
                MainActor.assumeIsolated {
                    runtime.beginRepairFromCaptureLossBanner()
                }
                return
            }
            // Development agents do not construct the installed onboarding
            // runtime. Keep their established direct Settings fallback.
            log("ui", "capture-loss banner Fix clicked — opening Screen Recording pane")
            UIPopoverView.openScreenRecordingSettings(guideMode: .spotlight)
        }
        FixSpotlight.shared.onEnd = { log("ui", "fix spotlight ended: \($0)") }
        // Admin gate (spec §9.1): the reason an icon is missing must be
        // answerable from the log. A lookup failure is not-admin and loud.
        // Resolved BEFORE the store so the PIN authority knows an unreadable
        // parent directory is expected in a Standard session.
        let admin = AdminCheck.isAdminSession()
        let store = UISettingsStore(standardSession: !admin.admin, log: log)
        settingsStore = store
        let user = AdminCheck.currentUserLabel()
        if let err = admin.error {
            log("ui", "admin check FAILED (\(err)) — treating session as non-admin")
        }
        // One `env` record per launch, BEFORE the pipeline exists, because the
        // states a state-root attack produces (a repointed state root, a blocked license
        // gate, a parked capture) never reach the `startup` record. An
        // installed agent must read `devEnv=inert envKnobs=0`: anything else
        // is either a dev run or an attempt to reach the knobs through the gui
        // domain's environment (DevEnv.swift, packaging/agent-launch.sh).
        log("env", DevEnv.launchSummary)
        log("ui", "session uid=\(getuid()) user=\(user) admin=\(admin.admin) — "
            + (admin.admin
                ? "parent controls eligible after onboarding"
                : "no parent controls (curtain only)"))
        let state = UIState(
            settings: store.settings,
            hasParentPIN: store.parentPIN != nil,
            devStateRoot: store.devFallback,
            isAdmin: admin.admin,
            // Settings' Model row (owner 2026-09-02) reads the SAME resolved
            // path the detector loads and the health check verifies below —
            // `opts.model` from config.json's "model", --model, or the dev
            // default — reduced to a basename here so no path reaches the UI.
            modelID: UIVersion.modelID(path: opts.model))
        uiState = state
        uiActions = UIActions(store: store, log: log)
        uiActions?.removalAllowed = { [weak state] in state?.isAdmin ?? false }
        uiActions?.detectionView.log = log
        // Settings › Developer (UIDevTuning.swift): the tuning.json bypass's
        // UI. The file's group follows the parent/ rule the PIN authority
        // and the license files use.
        let tuning = UIDevTuning(
            stateRoot: store.root,
            groupID: store.isProductionRoot ? AdminCheck.adminGID : getegid(),
            base: opts.tuning, baseSource: opts.tuningSource)
        devTuning = tuning
        uiActions?.devTuning = tuning
        // Diagnostic reports (Diagnostics.swift, docs/diagnostics.md): built
        // and sent only when the owner reviews one in Settings and presses Send.
        // The per-uid log dir is where agent-launch.sh sends stderr; the
        // support dir is the state root's parent on an install
        // (build-metadata.tsv, model-identity.tsv).
        var diagnosticsSources = DiagnosticsSources(
            supportDir: (store.root as NSString).deletingLastPathComponent,
            logDir: (AlertsLog.resolvePath(logPath: opts.logPath) as NSString).deletingLastPathComponent,
            crashReportsDir: NSHomeDirectory() + "/Library/Logs/DiagnosticReports",
            settingsPath: store.path)
        // Launch-effective tuning (TuningPolicy.swift) into the report's
        // `app.tuning`, so a reader sees which numbers this Mac runs.
        diagnosticsSources.appExtras["tuning"] = [
            "source": opts.tuningSource, "policy": opts.tuning.jsonObject,
        ] as [String: Any]
        // DevOverrides.swift: every active override is logged here once and
        // stamped into the report's `app.dev_overrides`.
        if let overrides = DevOverrides.load(stateRoot: store.root, log: log), !overrides.active.isEmpty {
            diagnosticsSources.appExtras["dev_overrides"] = overrides.reportObject
            devLogMode = overrides.logMode
            // Before startPipeline, so the run's first detect call takes it.
            if let hang = overrides.detectorHangS { DetectorWatch.injectedHangSecs = Double(hang) }
        }
        uiActions?.diagnostics = DiagnosticsAgent(sources: diagnosticsSources, isAdmin: admin.admin, log: log)
        if opts.captureLossBanner && store.root == UISettingsStore.productionRoot {
            let runtime = MainActor.assumeIsolated {
                UIOnboardingRuntime(
                    store: store,
                    installedMode: store.root == UISettingsStore.productionRoot,
                    // The health check must verify the detector this process
                    // will load, resolved from config.json's "model" key or
                    // --model, not a hardcoded package name.
                    modelPath: opts.model,
                    processStartedAt: processStartedAt,
                    log: log,
                    requestScreenRecording: { _ = CGRequestScreenCaptureAccess() },
                    openScreenRecordingSettings: { guideMode in
                        let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        let opened = NSWorkspace.shared.open(url)
                        if opened && UIDriver.scriptPath == nil {
                            FixSpotlight.shared.begin(mode: guideMode)
                        }
                        return opened
                    },
                    restartForVerification: { [weak self] in
                        self?.pipeline?.shutdown()
                        exit(7)
                    },
                    retryCaptureStartup: { [weak self] in
                        guard let self else { return }
                        self.pipeline?.shutdown()
                        // ARM THE SAME LIVENESS HEARTBEAT `stopCapture` ARMS
                        // (2026-09-11). This route
                        // tears a RUNNING Pipeline down and builds a new one,
                        // and the old one HAS written run.jsonl — so unlike the
                        // launch path (order receipt in `Pipeline.init`),
                        // `watchdog.sh`'s `mtime >= started` guard does NOT
                        // skip this process. If the rebuild then throws (an
                        // unreadable model file mid-update is the shape to
                        // expect — DERIVED, never observed live; health-retry
                        // and passive-recovery both reach here after a Pipeline
                        // has already run), the process parks in
                        // the repair UI with no Pipeline and nothing writing
                        // the log, and `SUMMARY_STALE_SECS` earns a
                        // `kickstart -k` 600 s later — under the parent. The
                        // heartbeat keeps the file moving; `startPipeline`
                        // stops it the moment a Pipeline exists again, so a
                        // successful retry costs exactly one `held` record.
                        if self.holdHeartbeat == nil, let logger = self.pipeline?.logger {
                            let heartbeat = HoldHeartbeat(
                                logger: logger, reason: "capture-restart")
                            self.holdHeartbeat = heartbeat
                            heartbeat.start()
                        }
                        self.pipeline = nil
                        self.uiState?.pauseResumePending = false
                        // The panic pause ended with the pipeline
                        // (`shutdown` logs panic-end); the popover must not
                        // keep offering a Resume that reaches nothing.
                        self.uiState?.panicPause = nil
                        self.startPipeline()
                    },
                    captureIsLive: { [weak self] in
                        self?.pipeline?.capture.isLive == true
                    },
                    captureIsSuspended: { [weak self] in
                        self?.pipeline?.capture.isSuspended == true
                    },
                    reportHealth: { [weak self] health in
                        guard let self else { return }
                        switch health {
                        case .protecting:
                            self.banner.hide()
                            // Same review as the poll's isLive branch: when
                            // captureLossPollIsSuperseded mutes that poll, this
                            // closure is the ONLY thing that can take the Fix
                            // spotlight's dim down before maxSecs.
                            FixSpotlight.shared.end("capture live again")
                        case .lost:
                            // The banner rides the same UI grace as the glyph
                            // (setCaptureHealth); showing it here would flash
                            // it for a restore that lands within the second.
                            break
                        case .starting:
                            break
                        }
                        self.setCaptureHealth(health, showBanner: true)
                    },
                    // The Setup window may be closed only while the menu-bar
                    // icon is there to reopen it (UIOnboardingWindowController.closable).
                    menuBarIconVisible: { [weak self] in self?.statusItem != nil })
            }
            onboardingRuntime = runtime
            if admin.admin, let actions = uiActions {
                MainActor.assumeIsolated {
                    runtime.onUninstall = { [weak actions] in actions?.uninstallFromSetupWindow() }
                }
            }
            uiActions?.onForgotPIN = { [weak runtime] in
                MainActor.assumeIsolated {
                    runtime?.beginRecoveryFromParentControls()
                }
            }
            uiActions?.onRepairProtection = { [weak runtime] in
                MainActor.assumeIsolated {
                    runtime?.beginRepairFromParentControls()
                }
            }
        } else if opts.captureLossBanner {
            // Development agents keep their established direct repair
            // action. Production uses the classified onboarding runtime so
            // only Screen Recording permission loss opens this pane.
            uiActions?.onRepairProtection = {
                let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                if !NSWorkspace.shared.open(url) {
                    log("ui", "FAILED to open Screen Recording settings for development agent")
                }
            }
        }
        uiActivity = UIActivity(state: state, root: UIActivity.resolveRoot(demo: false),
            log: { log("ui", $0) })
        // §4.3: once per launch, so a log read months later answers "why was
        // nothing ever paused".
        if store.parentPIN == nil {
            if admin.admin {
                log("ui", "no PIN set — protection cannot be paused")
            } else {
                // A Standard session cannot read state/parent (root:admin 2770)
                // by the tamper model; "no PIN set" here was a false statement
                // (child login 2026-08-29: a PIN existed).
                log("ui", "Standard session — parent PIN not readable here; "
                    + "pause/settings require an administrator account")
            }
        }
        syncStatusItem()
        store.onChange = { [weak self] settings in
            self?.uiState?.settings = settings
            self?.uiState?.hasParentPIN = store.parentPIN != nil
            self?.pipeline?.setSettingsPause(settings.pause)
            // Spec §6: every session's poll picks the override up, so a
            // parent switching to Strict changes the child's session too —
            // which is why the record is attributed to the writer
            // (`updatedBy`), not to the session reading the file.
            self?.pipeline?.setPolicy(
                settings.policyOverride, by: settings.updatedBy, source: "ui")
            MainActor.assumeIsolated {
                self?.onboardingRuntime?.settingsDidChange()
            }
            // Onboarding completion may have been written by the other admin
            // session; the icon follows within one poll tick.
            self?.syncStatusItem()
        }
        store.onTick = { [weak self] in
            guard let self, let state = self.uiState else { return }
            MainActor.assumeIsolated {
                self.onboardingRuntime?.settingsFileHealthDidChange()
            }
            // Request behavior first. Both timers are in common run-loop
            // modes. Pipeline keeps the UI in Starting until detectQueue
            // acknowledges resume. It does not block AppKit.
            self.pipeline?.refreshPauseState()
            // A timed pause EXPIRES with no settings write behind it, so
            // nothing else on this side would repaint: see
            // UIState.republishIfPauseChanged.
            state.republishIfPauseChanged()
            self.pollTuningFile(stateRoot: store.root, log: log)
            self.devTuning?.tick()
            // Menu-bar green check (UIState.setupHealthy): published only on
            // a change, so the 1 Hz tick does not repaint the status item.
            let healthy = MainActor.assumeIsolated { () -> Bool in
                self.onboardingRuntime?.recheckServicesIfDue()
                return self.onboardingRuntime?.setupHealthy ?? false
            }
            if state.setupHealthy != healthy { state.setupHealthy = healthy }
            // Detection view TTL and countdown (1 Hz is the countdown's own
            // resolution; the TTL can land up to one tick late).
            self.uiActions?.detectionView.tick()
            // Addendum 5: re-check admin on the poll tick until it reads true
            // once — a transient directory failure at login must not leave the
            // parent icon-less for the process lifetime.
            guard !state.isAdmin else { return }
            if AdminCheck.isAdminSession().admin {
                state.isAdmin = true
                log("ui", "session uid=\(getuid()) user=\(user) admin=true (on re-check)")
                self.syncStatusItem()
            }
        }
        store.startPolling()
    }

    /// One owner for the menu-bar item (spec §9.1): an admin session with the
    /// icon enabled gets exactly one, everyone else gets none. Called at
    /// launch, on every settings change, and on the admin re-check that flips
    /// true (Addendum 5), so an icon that could not exist at login appears
    /// within one poll tick instead of never.
    /// Owner 2026-08-29: a Standard (child) session gets the shield too, so a
    /// parent glancing at the child's menu bar sees protection is on. Its
    /// popover is read-only (UIPopoverView.parentControlsAvailable) — the PIN
    /// directory and settings.json are unwritable there by the tamper model,
    /// so no control that could reach store.mutate or the PIN gate is drawn.
    /// The green toast keeps its own admin gate (statusToastIsShown, ASSUMED).
    /// The icon CANNOT be hidden since 2026-10-20 (owner): the "Show menu bar
    /// icon" setting, and with it the ⌘⌥⌃S reveal hotkey that brought a
    /// hidden icon back, are gone. A `showMenuBarIcon: false` left in an
    /// older settings.json still loads (`UISettingsStore`) and is ignored
    /// here on purpose.
    static func statusItemWanted(isAdmin: Bool, onboardingComplete: Bool) -> Bool {
        _ = isAdmin
        return onboardingComplete
    }

    private func syncStatusItem() {
        // Both are set together in startSettings; a missing one is a wiring
        // bug, and an icon that silently never appears is exactly the failure
        // §9.1 says must be answerable from the log.
        guard let state = uiState, let actions = uiActions, let activity = uiActivity else {
            uiLog?("ui", "status item SKIPPED: uiState/uiActions not constructed yet")
            return
        }
        // The dedicated first-install window is the only parent surface until
        // its health Receipt is durable. This prevents the full settings
        // popover from competing with setup.
        let onboardingComplete = onboardingRuntime == nil
            || state.settings.onboarding.completedAt != nil
            || state.settings.readOnly
        let want = Self.statusItemWanted(
            isAdmin: state.isAdmin, onboardingComplete: onboardingComplete)
        if want, statusItem == nil {
            statusItem = UIStatusItem(state: state, actions: actions, activity: activity)
            // §9.1: the reason an icon is or is not there must be answerable
            // from the log, not from someone squinting at the menu bar.
            uiLog?("ui", "status item created (glyph=\(state.glyph.rawValue))")
        } else if !want, let item = statusItem {
            item.remove()
            statusItem = nil
            uiLog?("ui", "status item removed (admin=\(state.isAdmin) "
                + "onboardingComplete=\(onboardingComplete))")
        }
    }

    /// The five capture-health hooks (spec §8) funnel through here. Health
    /// and surface visibility are separate: the shield turns red for every
    /// accepted `.lost` state, while one visible runtime repair surface
    /// replaces the fallback capture-loss banner in either account type.
    ///
    /// Lost → lost keeps the ORIGINAL `since`, whatever the reason. Same
    /// reason repeated is a bouncing capture; a different reason is the same
    /// outage being re-described (hook 1's "permission missing at launch"
    /// becomes hook 2's "capture stream lost" the moment the pipeline finally
    /// tries). Either way the parent has been unprotected since the first
    /// one, and "Since 2:32 PM" must not restart at the newest event.
    /// Whether a transition INTO `.protecting` gets the green 3 s
    /// "SentryScreen is on" toast (StatusToast). Static so `--ui-selftest`
    /// can falsify the truth table.
    ///
    /// - `bannerMode` / `underUIDriver`: the original OWNER 2026-08-26 gates —
    ///   the toast belongs to `--capture-loss banner`, and the UI driver's
    ///   screenshots must stay byte-stable.
    /// - `isAdmin`: ADDED 2026-08-28 (review). ASSUMED, pending owner
    ///   confirmation (the owner tested the toast in an admin session only):
    ///   a Standard session already has its durable shield, so a transient
    ///   green good-news panel adds interruption without adding state.
    ///   The 2026-08-28 `showMenuBarIcon` gate went with the setting
    ///   (2026-10-20): the icon can no longer be hidden, and a stored
    ///   `false` from an older settings.json must not keep suppressing it.
    /// `successConfirmationPending` prevents the short green toast from
    /// competing with the one-time completion window. Also: `isAdmin` is
    /// resolved in `startSettings()` (called before `startPipeline()`), so it
    /// is populated for the launch transition — but if `AdminCheck` fails
    /// transiently at login, Addendum 5's re-check flips the icon on later and
    /// the one-shot launch toast is simply lost, not replayed.
    /// INVARIANT this predicate must never break: suppressing the toast must
    /// NOT suppress the `state.captureHealth = next` assignment. A false
    /// reading falls past the early return to the normal assignment below;
    /// moving that assignment inside the branch would leave a Standard
    /// session never reaching `.protecting` at all.
    /// Neither this selftest nor the gate would see that — they check the
    /// predicate and the pixels, not the state machine's exit path.
    static func statusToastIsShown(
        bannerMode: Bool,
        underUIDriver: Bool,
        isAdmin: Bool,
        successConfirmationPending: Bool
    ) -> Bool {
        bannerMode && !underUIDriver && isAdmin && !successConfirmationPending
    }

    /// Pure surface-arbitration policy. Standard sessions and development
    /// sessions retain the fail-loud banner until they open the read-only
    /// permission window. Any visible runtime repair surface then owns the
    /// issue and suppresses the duplicate banner.
    static func captureLossBannerIsShown(
        bannerMode: Bool,
        runtimeOwnsCaptureLossSurface: Bool
    ) -> Bool {
        bannerMode && !runtimeOwnsCaptureLossSurface
    }

    /// UI-only grace before a `.lost` replaces `.protecting` while
    /// CaptureStream is already re-arming. ASSUMED 1 s: the one measured case
    /// (2026-08-29 07:33:09Z, sessionDidBecomeActive) went down → restored
    /// within the same second, so any restore that takes longer than this
    /// still turns the shield red on time. The `captureHealth` log records are
    /// untouched — only the glyph/toast/banner wait.
    static let restoreGraceSecs: TimeInterval = 1.0
    private var pendingLost: DispatchWorkItem?

    /// Pure gate for the grace (selftest): only a protecting→lost edge with a
    /// restore in flight is deferred. Starting→lost and lost→lost never are.
    static func lostIsDeferred(previous: CaptureHealth, restoreInFlight: Bool) -> Bool {
        previous == .protecting && restoreInFlight
    }

    private func setCaptureHealth(_ next: CaptureHealth, showBanner: Bool = false) {
        guard let state = uiState else { return }
        // Any newer health verdict supersedes a lost that is still on grace.
        pendingLost?.cancel()
        pendingLost = nil
        if case .lost = next,
            Self.lostIsDeferred(
                previous: state.captureHealth,
                restoreInFlight: pipeline?.capture.isRestoring == true)
        {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingLost = nil
                self.applyCaptureHealth(next)
                // Ownership may change while capture is inside the grace.
                // Read it now, not when the work item is created.
                if showBanner { self.reconcileCaptureLossBanner() }
            }
            pendingLost = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreGraceSecs, execute: work)
            return
        }
        applyCaptureHealth(next)
        if showBanner, case .lost = next {
            // Runtime failure handling can call reportHealth before its
            // repair window is on screen. Reconcile on the next main-loop
            // turn so that one completed runtime action owns the decision.
            DispatchQueue.main.async { [weak self] in
                guard let self, let state = self.uiState,
                    case .lost = state.captureHealth
                else { return }
                self.reconcileCaptureLossBanner()
            }
        }
    }

    private func reconcileCaptureLossBanner() {
        let runtimeOwnsSurface = MainActor.assumeIsolated {
            onboardingRuntime?.ownsCaptureLossSurface == true
        }
        if Self.captureLossBannerIsShown(
            bannerMode: opts.captureLossBanner,
            runtimeOwnsCaptureLossSurface: runtimeOwnsSurface)
        {
            banner.show()
        } else {
            banner.hide()
        }
    }

    /// True while an outage has an `alerts.log` ALERT that has not been
    /// answered by a restore INFO. Owned here, not derived from
    /// `state.captureHealth`, because a re-arm publishes `.starting` between
    /// the two (`CaptureAlert.record`). Seeded from the file on first use,
    /// because the way back from a lost grant is usually a relaunch
    /// (`CaptureAlert.outageOpen(at:)`).
    private lazy var captureOutageOpen: Bool =
        CaptureAlert.outageOpen(at: AlertsLog.resolvePath(logPath: opts.logPath))

    /// Main thread only (every detector edge arrives through
    /// `applyDetectorHealth`, and the settle close is scheduled back onto it).
    /// Pairing plus the time floor that keeps a flapping detector from eating
    /// `AlertsLog.capBytes` — receipts on `DetectorAlertGate`.
    private var detectorAlertGate = DetectorAlertGate()

    /// Durable half of the capture-loss signal (2026-09-07).
    /// The glyph, the toast and the popover row are all
    /// session UI: a parent reading the health report the next day saw an
    /// outage that left the family unprotected as a silent gap. Every entry
    /// into and exit from the lost state now also appends one line to
    /// `alerts.log`, the file `scripts/health_report.py` already prints,
    /// in the watchdog's format. A refused write is logged by name — never
    /// swallowed — exactly like the hotkey alert.
    /// The armed-but-not-yet-written ALERT. nil when nothing is
    /// waiting out `captureAlertDelaySecs`.
    private var pendingCaptureAlert: DispatchWorkItem?

    private func recordCaptureAlert(_ next: CaptureHealth) {
        guard let step = CaptureAlert.durable(
            outageOpen: captureOutageOpen,
            alertPending: pendingCaptureAlert != nil,
            next: next,
            delay: Self.captureAlertDelaySecs)
        else { return }
        captureOutageOpen = step.outageOpen
        switch step.action {
        case let .hold(after, level, message):
            // Loud in run.jsonl, quiet in the parent's file: the budget is
            // named here so a deferred alert is never an unexplained silence.
            uiLog?("capture", "alerts.log \(level) HELD \(Int(after))s before writing — "
                + "budget captureAlertDelaySecs, so a slow wake does not tell a parent "
                + "protection stopped (fix: AppDelegate.captureAlertDelaySecs, or "
                + "SENTRY_CAPTURE_ALERT_DELAY_S=0 on a dev run): \(message)")
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingCaptureAlert = nil
                // Belt and braces: a restore cancels this item AND clears the
                // outage flag, so either alone is enough.
                guard self.captureOutageOpen else { return }
                self.appendCaptureAlert(level: level, message: message)
            }
            pendingCaptureAlert?.cancel()
            pendingCaptureAlert = work
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        case .drop:
            pendingCaptureAlert?.cancel()
            pendingCaptureAlert = nil
            uiLog?("capture", "capture restored inside the "
                + "\(Int(Self.captureAlertDelaySecs))s captureAlertDelaySecs window — no "
                + "alerts.log line written for either edge (a slow wake, not an outage); the "
                + "run.jsonl capture records are the full account")
        case let .write(level, message):
            appendCaptureAlert(level: level, message: message)
        }
    }

    private func appendCaptureAlert(level: String, message: String) {
        let path = AlertsLog.resolvePath(logPath: opts.logPath)
        if let failure = AlertsLog.append(level: level, message: message, path: path) {
            uiLog?("capture", "alerts.log append FAILED: \(failure) — the capture record "
                + "(run.jsonl, agent.err) is the only copy; fix: make the file appendable by "
                + "this uid (agent-launch.sh creates the per-uid log dir) or relay it from "
                + "run.jsonl (watchdog.sh)")
        } else {
            uiLog?("capture", "alerts.log \(level) line written: \(path)")
        }
    }

    /// Main thread. Detector health edges (2026-09-11): publish
    /// the state the popover and the glyph read, and append the same durable
    /// ALERT/INFO pair to `alerts.log` that a capture outage gets — the file
    /// `scripts/health_report.py` prints and the watchdog already writes to.
    /// Without that line a detector outage that left a family's new content
    /// unchecked would be invisible to a parent reading the report the next day.
    /// The pair is rate-floored by `DetectorAlertGate` (the published state is
    /// not): these edges are frame-paced and one pair per edge emptied the
    /// parent's whole alert history inside 80 minutes of a flapping detector.
    ///
    /// Deliberately does NOT restart or exit the agent. A broken model file is
    /// broken on the next launch too, so exiting would trade a held-cover
    /// degraded state for a restart loop that flaps every cover on screen. The
    /// existing restart levers stay the only ones: launchd KeepAlive for a
    /// crash, and the watchdog for a stopped process or a stalled log
    /// (`packaging/watchdog.sh`) — neither of which a detector fault trips,
    /// because the process is alive and still writing summaries. Recovery is
    /// therefore either the detector answering again (published here) or a
    /// parent restarting the Mac, which is what the copy asks for.
    private func applyDetectorHealth(_ next: DetectorHealth) {
        guard let state = uiState, state.detectorHealth != next else { return }
        state.detectorHealth = next
        // The durable pair is RATE-FLOORED, unlike the published state: the
        // reason, the arithmetic and the asymmetry with the capture alert are
        // all in `DetectorAlertGate`. The published state above is free and
        // stays frame-paced.
        switch detectorAlertGate.health(failing: next != .healthy) {
        case .nothing:
            return
        case .open:
            writeDetectorAlert(level: "ALERT", message: ProtectionCopy.detectorAlert)
        case let .armClose(generation):
            scheduleDetectorClose(generation)
        }
    }

    /// The settle window for one detector outage (receipt at
    /// `DetectorAlertGate.recoverySettleSecs`). At most one of these is ever in
    /// flight — `rearm` is how a longer wait is expressed, so a flapping
    /// detector cannot accumulate timers.
    private func scheduleDetectorClose(_ generation: Int) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DetectorAlertGate.recoverySettleSecs
        ) { [weak self] in
            guard let self else { return }
            switch self.detectorAlertGate.close(generation: generation) {
            case .nothing:
                return
            case .write:
                self.writeDetectorAlert(
                    level: "INFO", message: ProtectionCopy.detectorAlertCleared)
            case let .rearm(next):
                self.scheduleDetectorClose(next)
            }
        }
    }

    /// One line into `alerts.log`, refusal logged by name — never swallowed,
    /// exactly like the capture and hotkey alerts.
    private func writeDetectorAlert(level: String, message: String) {
        let path = AlertsLog.resolvePath(logPath: opts.logPath)
        if let failure = AlertsLog.append(level: level, message: message, path: path) {
            uiLog?("detector", "alerts.log append FAILED: \(failure) — the detector record "
                + "(run.jsonl) is the only copy; fix: make the file appendable by this uid "
                + "(agent-launch.sh creates the per-uid log dir)")
        } else {
            uiLog?("detector", "alerts.log \(level) line written: \(path)")
        }
    }

    private func applyCaptureHealth(_ next: CaptureHealth) {
        guard let state = uiState else { return }
        recordCaptureAlert(next)
        // Which failure this is, for the popover's persistent capture row:
        // ask macOS rather than parse a reason string (the reasons that reach
        // here are written by five call sites and the runtime's classifier).
        // Cheap enough to read on a health change — the capture-loss poll
        // already calls it every 5 s.
        if case .lost = next {
            state.screenRecordingOff = !CGPreflightScreenCaptureAccess()
        } else {
            state.screenRecordingOff = false
        }
        // Owner 2026-08-26: any transition INTO protecting (launch, fix)
        // gets the 3 s "SentryScreen is on" toast. Predicate in
        // `statusToastIsShown` so the selftest can falsify it.
        if next == .protecting, state.captureHealth != .protecting,
            Self.statusToastIsShown(
                bannerMode: opts.captureLossBanner,
                underUIDriver: UIDriver.scriptPath != nil,
                isAdmin: state.isAdmin,
                successConfirmationPending: MainActor.assumeIsolated {
                    onboardingRuntime?.successConfirmationPending == true
                })
        {
            state.captureHealth = next
            statusToast.show(status: state.statusSummary)
            uiLog?("ui", "status toast shown: \(state.statusSummary)")
            return
        }
        if case let .lost(since, reason) = state.captureHealth,
            case let .lost(_, newReason) = next {
            if reason == newReason { return }
            state.captureHealth = .lost(since: since, reason: newReason)
            return
        }
        state.captureHealth = next
    }

    /// Main-thread timer driving the capture-lost state: hide the banner the
    /// moment capture is live again; until then, nudge a fresh re-arm chain
    /// whenever preflight says the permission is back. Deliberately dumb —
    /// state lives in CaptureStream, this only polls and pokes.
    /// First poll at which preflight read true while capture was still down.
    /// The merge (2026-08-28) retired the old `lostSince` clock along with
    /// the plain-time exit-7 rule it fed: exit 7 now keys off a SEEN re-grant
    /// that fails to restore capture, so time in the lost state on its own is
    /// no longer a trigger and nothing else read that clock.
    private var grantSeenAt: CFAbsoluteTime = 0

    private func startCaptureLossPoll() {
        guard pollTimer == nil else { return }
        grantSeenAt = 0
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.captureLossPollSecs, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            let parentHandoffOwnsRelaunch = MainActor.assumeIsolated {
                self.onboardingRuntime?.captureLossPollIsSuperseded == true
            }
            // The parent or macOS now owns one explicit relaunch. Do not let
            // this older poll retry the stale stream or issue a second exit.
            guard !parentHandoffOwnsRelaunch else { return }
            if let capture = self.pipeline?.capture {
                if capture.isLive {
                    // Merge 2026-08-28, gated the same way the launch-wait
                    // branch below is: WITHOUT onboarding the
                    // toast comes down and the UI goes green here, which is
                    // what the owner tested live. WITH onboarding the
                    // first delivered frame owns Hook 3 — `isLive` means only
                    // that startCapture returned; it is not pixel proof, and
                    // the setup window must not claim success before pixels.
                    // NOT gated (review 2026-08-28): the dim is a modal-looking
                    // 0.5-alpha sheet over every screen and its only other owner
                    // is "System Settings closed" / maxSecs. Leaving it up under
                    // onboarding parked it over the setup window.
                    FixSpotlight.shared.end("capture live again")
                    if self.onboardingRuntime == nil {
                        self.banner.hide()
                        // Hook 3 (spec §8): toast down ⇒ the UI says Protected.
                        self.setCaptureHealth(.protecting)
                    }
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    return
                }
                if !CGPreflightScreenCaptureAccess() {
                    // The grant went away again (a parent toggling off, or the
                    // "sometimes cached" preflight flapping — see
                    // captureLossPollSecs). Restart the clock: exit 7's receipt
                    // says it fires after a re-grant has been SEEN for
                    // captureLossRelaunchSecs without capture returning, and a
                    // stale grantSeenAt would fire it on the first tick after
                    // the next re-grant, before retryAfterCaptureLoss() has had
                    // one chance. (Review 2026-08-28; verified by reading — no
                    // fixture drives a preflight flap.)
                    self.grantSeenAt = 0
                } else {
                    if self.grantSeenAt == 0 { self.grantSeenAt = CFAbsoluteTimeGetCurrent() }
                    capture.retryAfterCaptureLoss()
                    if CFAbsoluteTimeGetCurrent() - self.grantSeenAt > Self.captureLossRelaunchSecs {
                        FileHandle.standardError.write(Data(
                            ("capture: state=lost re-grant seen \(Int(Self.captureLossRelaunchSecs))s "
                            + "ago but capture still down — exiting 7 for TCC re-evaluation on "
                            + "relaunch (agent-launch.sh relaunches)\n").utf8))
                        self.pipeline?.shutdown()
                        exit(7)
                    }
                    return
                }
            } else if CGPreflightScreenCaptureAccess() {
                // Launch-wait: no pipeline yet, permission was missing at
                // start. (Reachable only if the in-process preflight ever
                // un-caches — see captureLossPollSecs caveat.)
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                if self.onboardingRuntime == nil {
                    self.banner.hide()
                    // Hook 4 (spec §8): banner down ⇒ the UI says Protected.
                    self.setCaptureHealth(.protecting)
                }
                FileHandle.standardError.write(Data(
                    "capture: state=granted at launch-wait — starting pipeline\n".utf8))
                self.startPipeline()
                return
            }
        }
    }

    // Parent popover on fake state. Placed after
    // the TTL arm and before the capture preflight: a demo never asks for
    // Screen Recording and never loads a model.
    private var uiDemo: UIDemoController?
    private var uiDriver: UIDriver?
    private var uiOnboardingDemo: UIOnboardingDemoController?

    private func runUIDemo() {
        let env = ProcessInfo.processInfo.environment
        if env["SENTRY_STATE_DIR"]?.isEmpty ?? true {
            // A demo must never read or clobber the family's real PIN.
            let dir = NSTemporaryDirectory() + "sentry-ui-demo-\(getpid())"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            setenv("SENTRY_STATE_DIR", dir, 1)
            atexit { try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "sentry-ui-demo-\(getpid())") }
        }
        // Spec §17 landmine 14: a demo writes fake public settings and a fake
        // protected PIN authority wholesale. So a demo may only run in an
        // EMPTY state dir: never the production root, never a dir that already
        // holds settings.json — whatever SENTRY_STATE_DIR says.
        let root = UISettingsStore.resolveRoot().root
        let existingEntries: [String]
        do {
            existingEntries = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            FileHandle.standardError.write(Data((
                "ui-demo: REFUSED — cannot inspect state root \(root): \(error). "
                + "Fix: unset SENTRY_STATE_DIR or point it at an empty directory.\n").utf8))
            exit(64)
        }
        if root == UISettingsStore.productionRoot || !existingEntries.isEmpty {
            FileHandle.standardError.write(Data((
                "ui-demo: REFUSED — state root \(root) "
                + (root == UISettingsStore.productionRoot ? "is the production root" : "is not empty")
                + "; a demo overwrites public settings and protected PIN state. "
                + "Fix: unset SENTRY_STATE_DIR or point it at an empty directory.\n").utf8))
            exit(64)
        }
        let banner = "ui-demo: FAKE STATE — no capture, no detection, protection is NOT running"
        print(banner)
        FileHandle.standardError.write(Data((banner + " (state dir \(ProcessInfo.processInfo.environment["SENTRY_STATE_DIR"]!))\n").utf8))
        // Parse the whole script before any UI exists: a typo exits 64
        // before a window appears.
        let driver = UIDriver.scriptPath.map { UIDriver.load(path: $0, isDemo: true) }
        let demo = UIDemoController(initial: opts.uiDemoState) { event, info in
            FileHandle.standardError.write(Data("\(event): \(info)\n".utf8))
        }
        uiDemo = demo
        if let driver {
            uiDriver = driver
            driver.run(host: demo.driverHost)
        } else {
            print("ui-demo: no SENTRY_UI_SCRIPT — popover is interactive until ttl (\(opts.ttl)s)")
        }
    }

    // Verifies panic hotkey delivery with a physical key before any overlay
    // work runs (SPEC §8 test order) — press, release and the 1-s hold. Every
    // `panic-hold` record is printed: a tap shows start + cancel and the test
    // keeps waiting; a full hold prints RECEIVED and exits 0.
    private func runHotkeyTest() {
        let deadline = 180
        print("hotkey test: hold \(HotkeyCenter.panicKey.label) for \(PanicHold.holdSecs) s "
            + "within \(deadline)s (a shorter tap prints its cancel and keeps waiting)")
        let stamp = { ISO8601DateFormatter().string(from: .now) }
        let hold = PanicHold(
            log: { event, info in print("\(event) \(info) \(stamp())") },
            onFire: {
                print("PANIC HOTKEY RECEIVED \(stamp())")
                exit(0)
            })
        let result = HotkeyCenter.shared.register(
            keyCode: HotkeyCenter.panicKey.code,
            onPress: { hold.press() }, onRelease: { hold.release() })
        // The one remaining exit 6: this is a test TOOL, and "the key could not
        // be registered" is exactly the verdict it exists to deliver. The
        // daemon itself never exits on a hotkey failure (Pipeline.registerHotkeys).
        if case .failed(let status) = result {
            die("hotkey registration failed (RegisterEventHotKey status "
                + "\(HotkeyRegistration.describe(status)))", code: 6)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(deadline)) {
            print("hotkey test timeout: no \(PanicHold.holdSecs) s hold within \(deadline)s")
            exit(5)
        }
    }
}

let delegate = AppDelegate()
app.delegate = delegate

// Dev-only signal triggers (DevSignals.swift, SPEC §8.1(8)): armed by
// `--dev-inject`, inert and logged by name everywhere
// else. A refusal goes to run.jsonl when a pipeline exists (that is the log
// the parent UI reads) and to stderr — agent.err — before one does.
let devSignalsArmed = DevSignals.armed(devInject: opts.devInject)
let devSignalRefusals = DevSignalRefusals { event, info in
    if let logger = delegate.pipeline?.logger {
        logger.event(event, info)
    } else {
        FileHandle.standardError.write(Data("\(event): \(info)\n".utf8))
    }
}

// SIGINT (interactive ^C) and SIGTERM (launchd's normal stop, sent again
// before SIGKILL) get the identical graceful path: without this, SIGTERM's
// default disposition kills the process outright, skipping overlay
// teardown, the run summary and the window-tracker stop.
let terminationSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        devSignalRefusals.flush()
        delegate.pipeline?.shutdown()
        if sig == SIGTERM, delegate.onboardingHandoffArmed {
            FileHandle.standardError.write(Data(
                "onboarding: SIGTERM during armed handoff (Quit & Reopen) — exiting 7 for relaunch\n".utf8))
            exit(7)
        }
        exit(0)
    }
    source.resume()
    return source
}

// Scripted test triggers: SIGUSR1 = inject, SIGUSR2 = panic (same code paths
// as the hotkeys, so automated tests exercise the real behavior).
//
// DEV-ONLY since 2026-09-07 (SPEC §8.1(8), receipt in DevSignals.swift): the
// agent runs as the session uid, so on an installed build these were a
// `kill -USR2 $(pgrep -x sentry-screen)` away from clearing every cover for
// 300 s from a child's own Terminal, with none of the authorization the panic
// hotkey asks for. `signal(..., SIG_IGN)` is what makes an unarmed build
// inert — the source stays so the ATTEMPT is still logged by name.
signal(SIGUSR1, SIG_IGN)
let sigusr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
sigusr1.setEventHandler {
    DevSignals.deliver(DevSignals.inject, armed: devSignalsArmed, refusals: devSignalRefusals) {
        delegate.pipeline?.inject()
    }
}
sigusr1.resume()

signal(SIGUSR2, SIG_IGN)
let sigusr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
sigusr2.setEventHandler {
    DevSignals.deliver(DevSignals.panic, armed: devSignalsArmed, refusals: devSignalRefusals) {
        delegate.pipeline?.panic(source: "SIGUSR2")
    }
}
sigusr2.resume()

app.run()
