import CoreML
import Foundation

/// Performance tiers (owner decision 2026-09-02, "implement it — ONE tier keyed
/// to the Neural Engine's absence, nothing more").
///
/// WHAT THIS DOES. Exactly one thing at launch: decide whether an Apple Neural
/// Engine is reachable, and if it is not, run at a lower frame rate. There is
/// no runtime controller, no step-down, no second knob. Capture width, memory,
/// core count and thermal state are NOT inputs — width was measured to be a
/// non-lever (halving it moved inference p50 by -1%/+2%), and the rest are
/// either momentary or have no measurement behind any threshold.
///
/// WHY fps IS THE ONLY KNOB. MEASURED 2026-09-02 (an M1 Mac, headless
/// `--process` over the `steady` gate fixture, 1800 frames at 1280x720,
/// student v8 ep50 fp16 — the shipped model): inference p50/p95 is 10.0/12.8 ms
/// with `MLComputeUnits.all` and 42.4/51.0 ms with `.cpuOnly`. 42.4 ms does not
/// fit the 33.3 ms frame interval that 30 fps demands, so a machine with no ANE
/// cannot run the shipped default at all — it would fall behind on every frame,
/// permanently.
enum PerfTier {
    /// Tier names as they appear in `--tier`, `config.json` and the `startup`
    /// record. The Swift case is `standard` because `default` is a keyword.
    enum TierName: String {
        case standard = "default"
        case noAne = "no-ane"
    }

    /// Whether an ANE is reachable BY THIS PROCESS. Three states, not two: a
    /// query that failed is not the same fact as a machine without an ANE, and
    /// the difference is worth a warning even though both land on the same
    /// tier (see `tier(forANE:)`).
    enum ANE: String {
        case present, absent, unknown
    }

    struct Tier {
        let name: TierName
        let fps: Int
        /// Inference p95 this tier is sized against, ms. MEASURED 2026-09-02
        /// (student v8 ep50 fp16 over `steady`): `.all` for `default`,
        /// `.cpuOnly` for `no-ane`.
        let inferP95Ms: Double
        let why: String
    }

    /// Today's values, unchanged.
    /// `PerfTier.selftest` pins every derived constant at this tier's
    /// fps to its pre-tier value — the nine of 2026-09-02, `Curtain.walkEvery`,
    /// and the six live-paint constants of 2026-09-08.
    static let standard = Tier(
        name: .standard, fps: 30, inferP95Ms: 12.8,
        why: "an Apple Neural Engine is reachable")

    /// ASSUMED FOR INTEL HARDWARE — the one number here that is not measured on
    /// the hardware it is for.
    ///
    /// DERIVED from the M1 `.cpuOnly` stand-in: p95 51.0 ms must fit inside one
    /// frame interval. 30 fps gives 33.3 ms (no), 20 fps gives 50.0 ms (no —
    /// 51.0 > 50.0, though that is a 2% margin and inside the measurement's own
    /// noise), 15 fps gives 66.7 ms (yes, 1.3x margin), 10 fps gives 100 ms
    /// (yes, but 10 is the latency floor, see `fpsFloor`).
    ///
    /// WHY IT IS ASSUMED: a 2018-2020 Intel Mac's CPU is slower than an M1's,
    /// so 51.0 ms is a LOWER bound on what Intel will cost, and 15 fps may
    /// prove optimistic. A real Intel receipt comes from the Intel-testing
    /// track and may move this to 10 fps. Do not treat 15 as measured.
    ///
    /// The owner's decision this encodes: a machine with no ANE gets this
    /// trade — a measurably thinner filter
    /// — rather than no protection at all.
    static let noAne = Tier(
        name: .noAne, fps: 15, inferP95Ms: 51.0,
        why: "no Apple Neural Engine reachable; CPU-only inference measured "
            + "4.2x slower, which does not fit a 33.3 ms frame interval")

    static let all = [standard, noAne]

    static func tier(named name: TierName) -> Tier {
        all.first { $0.name == name } ?? standard
    }

    /// SPEC §6: detection-to-overlay <= 400 ms worst case.
    static let latencyBudgetMs = 400.0

    /// The lowest fps any tier may name. DERIVED from `Curtain.triggerHits` (3)
    /// inside `Curtain.windowSecs` (1.0 s), which is unreachable below 3 fps
    /// and has no margin near it — a curtain that can never earn its trigger is
    /// a silent loss of the flagship cover — and from the SPEC §6 latency
    /// budget, which `latencyEstimateMs` blows at 5 fps. 10 satisfies both with
    /// no room to spare, so it is a floor rather than a tier anyone should
    /// ship. Asserted in `selftest`.
    static let fpsFloor = 10

    /// Worst-case detection-to-overlay latency a tier implies. DERIVED, never
    /// measured (`--process` builds no `Curtain`, so this repo cannot time a
    /// curtain drop headlessly):
    ///   1/fps                          sampling floor
    /// + (idleDetectEvery-1)/fps        idle-gate worst case — now itself
    ///                                  fps-derived, so this term is a
    ///                                  CONSTANT ~66.7 ms at every tier
    ///                                  (receipt at Pipeline.idleDetectEvery)
    /// + inferP95Ms                     inference
    /// + paintMs                        capture->glass paint (24 ms, receipt in
    ///                                  WindowTracker's header, track-d §1)
    static func latencyEstimateMs(_ t: Tier) -> Double {
        let interval = 1000.0 / Double(t.fps)
        return interval
            + interval * Double(Pipeline.idleDetectEvery(fps: t.fps) - 1)
            + t.inferP95Ms
            + paintMs
    }
    static let paintMs = 24.0

    /// The measured inference p95 a run at this fps must budget for, ms.
    ///
    /// Keyed on FPS, never on the machine this process happens to be on, and
    /// that is the whole point. `OverlayManager.leadFrames` needs an inference
    /// cost, and the obvious source — the RESOLVED tier's `inferP95Ms` — would
    /// have made `--process` output machine-dependent: `PixelReplay` takes fps
    /// from the video track, so a machine with no ANE replaying a 30 fps
    /// fixture would resolve to `no-ane` (51.0 ms), run at the track's 30 fps
    /// anyway, and paint a different `painted` rect than an M1 does.
    ///
    /// The rule instead: the SLOWEST shipped tier that can actually run this
    /// frame rate, i.e. the largest measured p95 that still fits one frame
    /// interval — the same criterion `selftest` holds each tier to. 12.8 ms at
    /// 30 fps (51.0 does not fit 33.3), 51.0 ms at 15 fps (66.7 fits it), and
    /// 12.8 ms at 20 fps, where 51.0 > 50.0 is exactly why `no-ane` is 15 and
    /// not 20. A machine whose real inference is slower than the fps it is
    /// running at is already falling behind on every frame; a longer paint lead
    /// is not the mechanism that saves it.
    static func inferP95Ms(forFps fps: Int) -> Double {
        let interval = 1000.0 / Double(fps)
        return all.filter { $0.inferP95Ms < interval }.map(\.inferP95Ms).max()
            ?? standard.inferP95Ms
    }

    /// Loud when the machine cannot afford the frame rate it was configured to
    /// run at. Returns nil when there is nothing to say.
    ///
    /// `--fps` and `config.json`'s fps are parsed independently of the resolved
    /// tier, so a no-ANE machine can be configured at 20-30 fps. Every
    /// fps-derived paint constant then budgets for `inferP95Ms(forFps:)` —
    /// 12.8 ms at 20 fps — while this machine's own MEASURED p95 is 51.0. The
    /// motion lead comes out at its 1.5-frame floor (75 ms at 20 fps) against a
    /// real 1/fps + 51.0 = 101 ms lag: 26 ms of velocity uncovered on the
    /// leading edge, which is the exact defect the fps-derived lead exists to
    /// close. Found 2026-09-08; the fixed 1.5 had the same
    /// hole, silently, so this is a new warning and not a new limit.
    ///
    /// A longer lead is NOT the remedy, which is why nothing here stretches a
    /// constant: a machine whose inference does not fit its frame interval is
    /// behind on every frame, and painting further ahead of a stale detection
    /// covers empty screen rather than content. The remedy is running at the
    /// tier's own fps. Per CONTRIBUTING.md's loud-limits rule this names the budget,
    /// the configured value, the observed value and where to fix it.
    /// `PixelReplay` REFUSES the analogous `--tier` vs track-fps disagreement,
    /// because there a mislabelled measurement would enter the record; here an
    /// operator forcing fps is a deliberate, reversible choice, so the live
    /// path warns instead of exiting.
    static func fpsBudgetWarning(tier: Tier, fps: Int) -> String? {
        let budgeted = inferP95Ms(forFps: fps)
        guard tier.inferP95Ms > budgeted else { return nil }
        let interval = 1000.0 / Double(fps)
        let leadMs = Double(
            OverlayManager.leadFrames(fps: fps, inferP95Ms: budgeted)) * interval
        let lagMs = interval + tier.inferP95Ms
        return String(
            format: "fps budget: at fps=%d the paint constants budget %.1f ms "
            + "of inference (PerfTier.inferP95Ms(forFps:)), but tier %@ "
            + "MEASURED %.1f ms — the motion lead paints %.0f ms ahead against "
            + "a %.0f ms lag, so ~%.0f ms of leading-edge velocity is "
            + "uncovered. A longer lead is not the fix: this machine is behind "
            + "on every frame. (fix: fps=%d, this tier's own rate — drop the "
            + "--fps flag or config.json fps)",
            fps, budgeted, tier.name.rawValue, tier.inferP95Ms,
            leadMs, lagMs, lagMs - leadMs, tier.fps)
    }

    // MARK: - ANE detection

    /// Is an ANE reachable by THIS process?
    ///
    /// TWO SIGNALS, because one is not enough. MEASURED 2026-09-02, and this is
    /// the finding that shaped this function:
    ///
    ///   * `MLComputeDevice.allComputeDevices` is a HARDWARE INVENTORY, not a
    ///     reachability query. Run under `arch -x86_64` on this M1 it still
    ///     reports `.neuralEngine` with `totalCoreCount=16`.
    ///     `MLModel.availableComputeDevices` returns exactly the same list.
    ///     Neither can see through translation.
    ///   * The ANE is genuinely NOT reachable from a translated process. Same
    ///     fixture, same model, x86_64 slice under Rosetta:
    ///     `.cpuAndNeuralEngine` measured p50 353.8 ms (vs 10.6 ms native
    ///     `.all`) — a 33x collapse, i.e. Core ML silently fell back off the
    ///     ANE. `.cpuOnly` under Rosetta measured 323.9 ms, so the `.ane`
    ///     request was simply paying translated-CPU cost.
    ///
    /// So: Core ML answers "does this machine have one" and
    /// `sysctl.proc_translated` answers "can this process use it". The tier
    /// needs both.
    ///
    /// This is NOT keying on CPU architecture. On real Intel hardware the
    /// universal binary runs the x86_64 slice NATIVELY, `allComputeDevices`
    /// genuinely omits `.neuralEngine`, and the first signal alone decides it.
    /// The translation check exists for a misconfiguration the API cannot see
    /// (an Apple Silicon Mac running the x86_64 slice), which the universal
    /// binary makes unnecessary in the first place.
    ///
    /// CALIBRATION NOTE, so nobody reads more into the Rosetta case than is
    /// there: under Rosetta the SHIPPED `.all` placement measured p50 32.9 /
    /// p95 35.5 ms — GPU-backed, ~10x faster than the translated CPU path. That
    /// almost fits 30 fps and fits 15 fps comfortably. Applying `no-ane` to a
    /// translated process is CONSERVATIVE, not necessary.
    ///
    /// A failed query returns `.unknown`, which takes the same tier as
    /// `.absent` (fail-safe: a slower filter that works beats a fast one that
    /// falls behind) but says so by name in the `startup` record and on stderr.
    static func detectANE() -> (state: ANE, why: String) {
        // Translation state comes from HostArch (the universal build, 2026-09-02)
        // rather than a second sysctl read here: it already implements the exact
        // ENOENT-means-not-translated contract this needs, and two sources of
        // truth for one fact is how they drift.
        if HostArch.translated == "unknown" {
            return (.unknown, "sysctl.proc_translated unreadable "
                + "(fix: HostArch.translated)")
        }
        if HostArch.isTranslated {
            return (.absent, "process is translated (Rosetta): MEASURED "
                + "2026-09-02, .cpuAndNeuralEngine under translation costs "
                + "353.8 ms p50 vs 10.6 ms native — the ANE is not reachable, "
                + "even though MLComputeDevice.allComputeDevices still lists it")
        }
        let devices = MLComputeDevice.allComputeDevices
        guard !devices.isEmpty else {
            return (.unknown, "MLComputeDevice.allComputeDevices returned an "
                + "empty list, which no supported machine should")
        }
        let hasANE = devices.contains { if case .neuralEngine = $0 { return true }
            return false }
        return hasANE
            ? (.present, "MLComputeDevice.allComputeDevices lists a neural engine")
            : (.absent, "MLComputeDevice.allComputeDevices lists no neural engine")
    }

    /// The whole tier rule. Pure function, so `selftest` can falsify it for
    /// machines this binary is not running on.
    static func tier(forANE ane: ANE) -> Tier {
        ane == .present ? standard : noAne
    }

    /// Resolve the tier for a launch: an explicit `--tier` / `config.json`
    /// `tier` wins, otherwise detection decides. Returns everything the
    /// `startup` record needs to say what happened and why.
    static func resolve(override: TierName?) -> (tier: Tier, ane: ANE, why: String) {
        let (ane, why) = detectANE()
        if let override {
            return (tier(named: override), ane,
                    "forced by --tier/config (detection said \(ane.rawValue): \(why))")
        }
        return (tier(forANE: ane), ane, why)
    }

    // MARK: - Derived values (the landmine list, doc §4)

    /// Every constant whose meaning moves with fps, resolved for one tier.
    ///
    /// THIS TYPE IS THE POINT OF THE WHOLE CHANGE. Before it, nine constants
    /// were written as frame counts whose receipts reasoned "at 30 fps" (and a
    /// receipt audit then found seven more — `Curtain.walkEvery` and the six
    /// live-paint constants restated 2026-09-08), and
    /// changing fps silently changed what each one MEANT — two of them
    /// tripwires. Each is now either derived from a duration at the effective
    /// fps, or explicitly documented as fps-invariant with a receipt. It reads
    /// the real symbols rather than copying their formulas, so `selftest` pins
    /// the shipping constants and not a duplicate of them.
    struct Derived {
        let fps: Int
        /// The inference p95 this fps must budget for (`inferP95Ms(forFps:)`).
        /// Only `leadFrames` reads it. Derived from the fps rather than from
        /// the resolved tier, so a headless replay paints the same rects on
        /// every machine — receipt at `PerfTier.inferP95Ms(forFps:)`.
        let inferP95Ms: Double
        let clearAfterFrames: Int
        let stickyHoldFrames: Int
        let idleDetectEvery: Int
        let exposureFrames: Int
        let holdCleanFrames: Int
        let transparentWarmupFrames: Int
        let scrollLagFrames: Int
        let scrollShiftRange: Int
        let velocityHorizonSecs: Double
        // The six live-paint / ownership values (2026-09-08). They live on the
        // path `--process` exercises only for the first two, which is why they
        // were the last to be restated — see each symbol's receipt.
        let leadFrames: CGFloat
        let capCells: CGFloat
        let pinGrowCells: CGFloat
        let pinRemeasureUpdates: Int
        let ownershipResolveEvery: Int
        let motionMemoryUpdates: Int

        init(fps: Int) {
            self.fps = fps
            self.inferP95Ms = PerfTier.inferP95Ms(forFps: fps)
            clearAfterFrames = Tracker.defaultClearAfter(fps: fps)
            stickyHoldFrames = Tracker.defaultStickyHold(fps: fps)
            idleDetectEvery = Pipeline.idleDetectEvery(fps: fps)
            exposureFrames = Pipeline.exposureFrames(fps: fps)
            holdCleanFrames = Curtain.holdCleanFrames
            transparentWarmupFrames = CaptureContentCrop.transparentWarmup(fps: fps)
            scrollLagFrames = MotionBoxes.scrollLagFrames(fps: fps)
            scrollShiftRange = MotionBoxes.scrollShiftRange
            velocityHorizonSecs = PaintExtrapolator.maxVelocityHorizon(fps: fps)
            leadFrames = OverlayManager.leadFrames(
                fps: fps, inferP95Ms: PerfTier.inferP95Ms(forFps: fps))
            capCells = PaintSmoother.capCells(fps: fps)
            pinGrowCells = CoverOwnership.pinGrowCells(fps: fps)
            pinRemeasureUpdates = CoverOwnership.pinRemeasureUpdates(fps: fps)
            ownershipResolveEvery = Pipeline.ownershipResolveEvery(fps: fps)
            motionMemoryUpdates = MotionBoxes.motionMemoryUpdates(fps: fps)
        }

        /// One line for the `startup` record and `--probe`. Not compared by any
        /// gate: `logcmp.py` only reads records that carry a `frame` field, and
        /// the `startup` record does not.
        var summary: String {
            String(
                format: "clearAfter=%d stickyHold=%d idleEvery=%d exposure=%d "
                + "holdClean=%d warmup=%d scrollLag=%d scrollShift=%d "
                + "velHorizonMs=%.0f lead=%.3f cap=%.2f pinGrow=%.2f "
                + "pinRemeasure=%d ownerEvery=%d motionMemory=%d",
                clearAfterFrames, stickyHoldFrames, idleDetectEvery,
                exposureFrames, holdCleanFrames, transparentWarmupFrames,
                scrollLagFrames, scrollShiftRange, velocityHorizonSecs * 1000,
                Double(leadFrames), Double(capCells), Double(pinGrowCells),
                pinRemeasureUpdates, ownershipResolveEvery, motionMemoryUpdates)
        }
    }

    // MARK: - Machine probe (`--probe`)

    struct Machine {
        var cpuBrand: String
        var arch: String
        /// HostArch's tri-state: "1", "0", or "unknown". An ABSENT sysctl is
        /// the documented signal for "not translated", so only a different
        /// errno is genuinely unknown.
        var translated: String
        var aneState: ANE
        var aneWhy: String
        var physicalCores: Int?
        var performanceCores: Int?
        var efficiencyCores: Int?
        var memoryBytes: UInt64
        var macOS: String
        var diskFreeBytes: Int64?
        /// Reported, never a tier input: both are momentary, and a probe taken
        /// while the machine happened to be hot would otherwise pin an install
        /// to a slower tier for good.
        var thermalState: String
        var lowPowerMode: Bool
    }

    static func probe() -> Machine {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        var free: Int64? = nil
        if let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            free = values.volumeAvailableCapacityForImportantUsage
        }
        let (ane, why) = detectANE()
        return Machine(
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "?",
            arch: HostArch.compiled,
            translated: HostArch.translated,
            aneState: ane, aneWhy: why,
            physicalCores: sysctlInt("hw.physicalcpu"),
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
            memoryBytes: info.physicalMemory,
            macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            diskFreeBytes: free,
            thermalState: thermalName(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled)
    }

    static func runProbe(opts: Options) -> Int32 {
        let m = probe()
        let t = tier(forANE: m.aneState)
        var out = [
            "probe: cpu=\"\(m.cpuBrand)\" arch=\(m.arch) translated=\(m.translated)"
                + " host=\(HostArch.description)",
            "probe: ane=\(m.aneState.rawValue) — \(m.aneWhy)",
            "probe: cores=\(m.physicalCores.map(String.init) ?? "?")"
                + " perf=\(m.performanceCores.map(String.init) ?? "?")"
                + " eff=\(m.efficiencyCores.map(String.init) ?? "?")",
            "probe: memoryGB=\(String(format: "%.1f", Double(m.memoryBytes) / 1e9))"
                + " diskFreeGB=" + (m.diskFreeBytes.map {
                    String(format: "%.1f", Double($0) / 1e9) } ?? "?"),
            "probe: macOS=\(m.macOS)",
            "probe: thermalState=\(m.thermalState) lowPowerMode=\(m.lowPowerMode)"
                + "  (observations only — neither is a tier input)",
            "tier: would_choose=\(t.name.rawValue) fps=\(t.fps)"
                + " inferP95Ms=\(t.inferP95Ms)"
                + " latencyEstimateMs=\(String(format: "%.1f", latencyEstimateMs(t)))"
                + " (SPEC §6 budget \(Int(latencyBudgetMs)))",
            "tier: why=\(t.why)",
            "tier: derived \(Derived(fps: t.fps).summary)",
        ]
        if m.aneState == .unknown {
            out.append(
                "tier: WARNING — ANE detection did not answer, so this falls back to "
                + "the slower tier. \(m.aneWhy)")
        }
        if t.name == .noAne {
            out.append(
                "tier: WARNING — no-ane's fps is ASSUMED for Intel hardware; it is "
                + "DERIVED from `.cpuOnly` measurements on Apple Silicon and no Intel "
                + "Mac has run this daemon")
        }
        if let w = fpsBudgetWarning(tier: t, fps: opts.fps) {
            out.append("tier: WARNING — " + w)
        }
        out.append(
            "tier: this invocation would run at fps=\(opts.fps)"
            + (opts.tierOverride != nil ? " (--tier/config override in effect)" : ""))
        print(out.joined(separator: "\n"))
        return 0
    }

    // MARK: - `--probe-selftest`

    /// Executable checks for the tier rule AND for every derived constant.
    ///
    /// The load-bearing block is `caseDerivedPinnedAt30`: it asserts that at
    /// 30 fps every derived value equals the exact constant this repo shipped
    /// before tiers existed. That is what makes "the default arm64 path is
    /// byte-identical" a checked claim rather than a hope, and it is why the
    /// numbers below are written as literals instead of being computed.
    static func selftest() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                passed += 1
                print("ok - \(name)")
            } else {
                failed += 1
                print("not ok - \(name)\(detail.isEmpty ? "" : "  \(detail)")")
            }
        }

        /// The lag a motion lead has to cover, in frames: one frame of sampling
        /// plus the inference p95 this fps budgets for. Receipt at
        /// OverlayManager.leadFrames. Declared up here because the leadMargin
        /// pins below need it as well as the per-tier loop further down.
        func lagFrames(_ fps: Int, _ p95: Double) -> Double {
            1.0 + p95 * Double(fps) / 1000.0
        }

        // --- tier selection ---
        check("ane present -> default tier",
              tier(forANE: .present).name == .standard)
        check("ane absent -> no-ane tier",
              tier(forANE: .absent).name == .noAne)
        check("ane unknown -> no-ane tier (fail-safe)",
              tier(forANE: .unknown).name == .noAne,
              "an unanswered query must not silently get the fast tier")
        check("--tier override wins over detection",
              resolve(override: .noAne).tier.name == .noAne
              && resolve(override: .standard).tier.name == .standard)
        check("tier names round-trip through their rawValues",
              TierName(rawValue: "default") == .standard
              && TierName(rawValue: "no-ane") == .noAne)

        // --- the live probe on this machine ---
        let live = detectANE()
        check("live ANE detection answers on this machine",
              live.state != .unknown, "state=\(live.state.rawValue) why=\(live.why)")

        // --- THE PIN: every derived value at 30 fps equals the pre-tier constant ---
        let d30 = Derived(fps: 30)
        let pinned: [(String, Int, Int)] = [
            ("Tracker.defaultClearAfter", d30.clearAfterFrames, 12),
            ("Tracker.defaultStickyHold", d30.stickyHoldFrames, 30),
            ("Pipeline.idleDetectEvery", d30.idleDetectEvery, 3),
            ("Pipeline.exposureFrames", d30.exposureFrames, 12),
            ("Curtain.holdCleanFrames", d30.holdCleanFrames, 20),
            ("Capture.transparentWarmup", d30.transparentWarmupFrames, 30),
            ("MotionBoxes.scrollLagFrames", d30.scrollLagFrames, 4),
            ("MotionBoxes.scrollShiftRange", d30.scrollShiftRange, 25),
            // The six live-paint / ownership constants (2026-09-08).
            ("CoverOwnership.pinRemeasureUpdates", d30.pinRemeasureUpdates, 30),
            ("Pipeline.ownershipResolveEvery", d30.ownershipResolveEvery, 3),
            ("MotionBoxes.motionMemoryUpdates", d30.motionMemoryUpdates, 30),
        ]
        for (name, got, want) in pinned {
            check("at 30 fps \(name) == \(want) (pre-tier value)",
                  got == want, "got \(got)")
        }
        check("at 30 fps PaintExtrapolator.maxVelocityHorizon == 0.100 s",
              d30.velocityHorizonSecs == 0.100,
              "got \(d30.velocityHorizonSecs)")
        // The three CGFloat live-paint pins. `==` against the literal is the
        // point: `--process` runs through `paintRect` and `PaintSmoother`, so
        // the frozen gate baseline moves if any of these is 1.4947 rather than
        // 1.5. Each derivation is written to return the literal by
        // construction (a `max`/`min` against the pre-tier value, or an exact
        // 1:1 IEEE division), never by rounding luck.
        check("at 30 fps OverlayManager.leadFrames == 1.5 (pre-tier value)",
              d30.leadFrames == 1.5, "got \(d30.leadFrames)")
        check("at 30 fps PaintSmoother.capCells == 1 (pre-tier value)",
              d30.capCells == 1, "got \(d30.capCells)")
        check("at 30 fps CoverOwnership.pinGrowCells == 2 (pre-tier value)",
              d30.pinGrowCells == 2, "got \(d30.pinGrowCells)")
        check("the default tier runs at 30 fps",
              standard.fps == 30)

        // --- THE SECOND PIN: the six at the no-ane tier, as NUMBERS ---
        //
        // 2026-09-08. Every other 15 fps assertion in this file is an
        // INEQUALITY, and an inequality cannot defend a constant: with only
        // those, `leadMargin` could decay 1.08 -> 1.001 and the suite would
        // still print a full pass (at 30 fps the floor returns 1.5 and the `==`
        // pins above hold; at 15 fps 1.7668 still clears the 1.765 lag). These
        // are the numbers the no-ane tier actually runs, written out, so a
        // formula change has to come here and say so.
        check("the no-ane tier runs at 15 fps (the literals below assume it)",
              noAne.fps == 15, "fps=\(noAne.fps)")
        let d15 = Derived(fps: 15)
        let pinned15: [(String, Int, Int)] = [
            ("CoverOwnership.pinRemeasureUpdates", d15.pinRemeasureUpdates, 15),
            ("Pipeline.ownershipResolveEvery", d15.ownershipResolveEvery, 1),
            ("MotionBoxes.motionMemoryUpdates", d15.motionMemoryUpdates, 17),
        ]
        for (name, got, want) in pinned15 {
            check("at 15 fps \(name) == \(want)", got == want, "got \(got)")
        }
        check("at 15 fps the budgeted inference p95 == 51.0 ms (no-ane's own)",
              d15.inferP95Ms == 51.0, "got \(d15.inferP95Ms)")
        check("at 15 fps PaintSmoother.capCells == 2.00 cells/frame",
              d15.capCells == 2, "got \(d15.capCells)")
        check("at 15 fps CoverOwnership.pinGrowCells == 3.00 cells/update",
              d15.pinGrowCells == 3, "got \(d15.pinGrowCells)")
        // 1.765 measured lag x 1.08 margin. Tolerance, not `==`: this one is a
        // product of two decimals rather than a floored literal, so pinning it
        // bit-exactly would fail on a legitimate re-association. 1e-9 frames is
        // 67 nanoseconds of velocity — it still catches any real drift.
        check("at 15 fps OverlayManager.leadFrames == 1.9062 frames (127.1 ms)",
              abs(Double(d15.leadFrames) - 1.9062) < 1e-9,
              String(format: "got %.6f frames = %.1f ms",
                     Double(d15.leadFrames), Double(d15.leadFrames) / 15 * 1000))
        // THE MARGIN ITSELF. `leadFrames > lag` in the per-tier loop below is
        // TAUTOLOGICAL for any `leadMargin > 1` — the lead IS the lag times the
        // margin — so it states the relationship and cannot defend the number.
        // The number, and the two facts that fix it at 1.08, are pinned here.
        check("OverlayManager.leadMargin == 1.08 (the margin 30 fps ships)",
              OverlayManager.leadMargin == 1.08,
              "got \(OverlayManager.leadMargin)")
        let unflooredLead30 =
            CGFloat(lagFrames(30, inferP95Ms(forFps: 30))) * OverlayManager.leadMargin
        check("the 1.5 lead floor is still BINDING at 30 fps — raising "
              + "leadMargin moves the frozen gate baseline, not just the lead",
              unflooredLead30 < OverlayManager.leadFramesAt30,
              String(format: "unfloored %.4f vs floor %.4f (1.09 gives 1.5086)",
                     Double(unflooredLead30),
                     Double(OverlayManager.leadFramesAt30)))

        // --- the no-ane tier's derived values, printed for the record ---
        let dTier = Derived(fps: noAne.fps)
        print("# no-ane tier (fps \(noAne.fps)) derived: \(dTier.summary)")

        // --- durations preserved, not frame counts ---
        func secs(_ frames: Int, _ fps: Int) -> Double { Double(frames) / Double(fps) }
        check("exposure tripwire keeps its 0.4 s sensitivity at the no-ane tier",
              abs(secs(dTier.exposureFrames, noAne.fps) - 0.4) < 0.05,
              String(format: "%.3f s", secs(dTier.exposureFrames, noAne.fps)))
        check("idle gate keeps its <=67 ms added latency at the no-ane tier",
              secs(dTier.idleDetectEvery - 1, noAne.fps) <= 0.067 + 1e-9,
              String(format: "%.1f ms", secs(dTier.idleDetectEvery - 1, noAne.fps) * 1000))
        check("capture warmup keeps its 1.0 s at the no-ane tier",
              abs(secs(dTier.transparentWarmupFrames, noAne.fps) - 1.0) < 0.05)
        check("scroll-guard lag keeps its 133 ms at the no-ane tier",
              abs(secs(dTier.scrollLagFrames, noAne.fps) - 0.133) < 0.02,
              String(format: "%.3f s", secs(dTier.scrollLagFrames, noAne.fps)))
        // The coupling that makes the scroll guard survive a lower fps: the
        // 1500 px/s flick fixture must still translate within the search range.
        // A comment cannot rot into being wrong; this can.
        // SWEEP, not just the two shipped tiers: the bound must hold at every
        // frame rate the floor admits, or `scrollLagFrames`'s integer floor is
        // not actually buying the invariant it claims (receipt audit
        // 2026-09-02 — with `.rounded()` this failed at 20 fps).
        var worstCells = 0.0, worstFps = 0
        var sweepOK = true
        for fps in fpsFloor...30 {
            let lag = MotionBoxes.scrollLagFrames(fps: fps)
            let cells = (MotionBoxes.scrollFixturePxPerSec / Double(fps))
                * Double(lag) / MotionBoxes.gridCellPx
            if cells > worstCells { worstCells = cells; worstFps = fps }
            if cells > Double(MotionBoxes.scrollShiftRange) + 1e-9 { sweepOK = false }
        }
        check("flick fixture stays inside scrollShiftRange at EVERY fps "
              + "\(fpsFloor)...30",
              sweepOK,
              String(format: "worst %.1f cells at %d fps, range +-%d",
                     worstCells, worstFps, MotionBoxes.scrollShiftRange))
        // The tenth constant: the attribution walk must still be able to feed
        // the curtain trigger, with margin, at every tier.
        for t in all {
            let walkHz = Double(t.fps) / Double(Curtain.walkEvery(fps: t.fps))
            let neededHz = Double(Curtain.triggerHits) / Curtain.windowSecs
            check("tier \(t.name.rawValue): attribution walk keeps 2x margin on "
                  + "the curtain trigger",
                  walkHz >= 2 * neededHz,
                  String(format: "walk %.1f Hz, trigger needs %.1f Hz",
                         walkHz, neededHz))
        }
        check("at 30 fps Curtain.walkEvery == 3 (pre-tier value)",
              Curtain.walkEvery(fps: 30) == 3,
              "got \(Curtain.walkEvery(fps: 30))")
        // Curtain.holdCleanFrames is deliberately NOT fps-derived; assert it is
        // not binding at any shipped tier rather than leaving that a comment.
        for t in all {
            check("tier \(t.name.rawValue): holdCleanFrames stays inside holdSecs",
                  secs(Curtain.holdCleanFrames, t.fps) < Curtain.holdSecs,
                  String(format: "%.2f s vs holdSecs %.1f s",
                         secs(Curtain.holdCleanFrames, t.fps), Curtain.holdSecs))
        }

        // --- the six live-paint / ownership constants (2026-09-08) ---
        //
        // `--process` exercises only two of these (leadFrames and capCells, via
        // the `painted` field); the other four run on the live ownership path
        // no headless replay builds. So these assertions are the ONLY
        // executable check four of the six have between here and the shielded
        // suite on real content. Each restates the receipt's own inequality —
        // never its formula, so a formula that drifts fails here.

        /// How long the smoother takes to walk its worst measured stale edge
        /// (115 px) back to target. Reads the shipping symbol rather than
        /// copying its formula. Receipt at PaintSmoother.capCells.
        func smootherConvergeSecs(_ fps: Int) -> Double {
            PaintSmoother.convergeSecs(fps: fps)
        }
        /// How long the worst pin collapse on record (809 pt) takes to close.
        /// Receipt at CoverOwnership.pinGrowCells. PRINTED, not asserted: it is
        /// a cost the tier pays (1.7 s at 30 fps, 2.3 s at 15), and the bound
        /// that IS asserted is the +0.05 area bar the rate is clamped by.
        func pinRecoverSecs(_ fps: Int) -> Double {
            let ptPerCell =
                CoverOwnership.receiptWindowPt / CGFloat(MotionBoxes.gridWidth)
            let ptPerSec =
                CoverOwnership.pinGrowCells(fps: fps) * ptPerCell * CGFloat(fps)
            return Double(CoverOwnership.worstPinCollapsePt / ptPerSec)
        }
        /// Area one pin step costs when both edges of an axis move together.
        func pinStepArea(_ fps: Int) -> CGFloat {
            2 * CoverOwnership.pinGrowCells(fps: fps)
                * CoverOwnership.pinStepAreaPerCell
        }

        for t in all {
            let d = Derived(fps: t.fps)
            let lag = lagFrames(t.fps, d.inferP95Ms)
            let leadMs = (Double(d.leadFrames) - lag) * 1000 / Double(t.fps)
            // Relationship, not a defence of the margin: `leadFrames` IS
            // `lag * leadMargin` floored at 1.5, so this can only fail if the
            // margin drops to <= 1 (or the floor is removed). The number is
            // pinned above; this line is here so the printed detail shows what
            // each tier actually pays.
            check("tier \(t.name.rawValue): motion lead stands above the tier's "
                  + "OWN measured lag (sampling + inference p95)",
                  Double(d.leadFrames) > lag,
                  String(format: "lead %.4f frames vs lag %.4f frames — "
                         + "margin %.1f%% = %.1f ms",
                         Double(d.leadFrames), lag,
                         (Double(d.leadFrames) / lag - 1) * 100, leadMs))
            check("tier \(t.name.rawValue): motion lead never shrinks below the "
                  + "shipped 1.5 frames (exposure direction)",
                  d.leadFrames >= OverlayManager.leadFramesAt30,
                  "got \(d.leadFrames)")
            check("tier \(t.name.rawValue): smoother stale-edge convergence "
                  + "stays inside the 1.0 s tightness-recovery budget",
                  smootherConvergeSecs(t.fps) <= 1.0,
                  String(format: "%.3f s at cap %.2f cells/frame",
                         smootherConvergeSecs(t.fps), Double(d.capCells)))
            check("tier \(t.name.rawValue): smoother size cap stays inside the "
                  + "spec's post-motion no-pop limit",
                  d.capCells <= PaintSmoother.capCellsPopLimit,
                  "cap \(d.capCells) limit \(PaintSmoother.capCellsPopLimit)")
            check("tier \(t.name.rawValue): one pin step stays under the "
                  + "+0.05 area acceptance bar with both edges moving",
                  pinStepArea(t.fps) <= CoverOwnership.pinStepAreaBar,
                  String(format: "%.3f area at %.2f cells/update",
                         Double(pinStepArea(t.fps)), Double(d.pinGrowCells)))
            check("tier \(t.name.rawValue): pin growth outruns the pixel path "
                  + "it measures (pinGrowCells > capCells)",
                  d.pinGrowCells > d.capCells,
                  "pin \(d.pinGrowCells) vs smoother \(d.capCells)")
            check("tier \(t.name.rawValue): pin re-measure window is >= 2x the "
                  + "smoother's convergence, so a resize settles inside it",
                  secs(d.pinRemeasureUpdates, t.fps)
                      >= 2 * smootherConvergeSecs(t.fps) - 1e-9,
                  String(format: "%.3f s vs 2 x %.3f s",
                         secs(d.pinRemeasureUpdates, t.fps),
                         smootherConvergeSecs(t.fps)))
            check("tier \(t.name.rawValue): pin re-measure window keeps its "
                  + "1.0 s, the figure disagreeSecs and pinLapseSecs carry",
                  abs(secs(d.pinRemeasureUpdates, t.fps)
                      - CoverOwnership.pinRemeasureSecs) < 0.05,
                  String(format: "%.3f s", secs(d.pinRemeasureUpdates, t.fps)))
            check("tier \(t.name.rawValue): ownership z-order blind spot stays "
                  + "inside its 100 ms bound",
                  secs(d.ownershipResolveEvery, t.fps)
                      <= Pipeline.ownershipResolveLagSecs + 1e-9,
                  String(format: "%.1f ms every %d frames",
                         secs(d.ownershipResolveEvery, t.fps) * 1000,
                         d.ownershipResolveEvery))
            check("tier \(t.name.rawValue): motion memory still covers the "
                  + "worst measured strand (17 updates at 1 cell/update)",
                  d.motionMemoryUpdates >= MotionBoxes.motionMemoryStrandFloor,
                  "got \(d.motionMemoryUpdates)")
            check("tier \(t.name.rawValue): motion memory ends before the "
                  + "scorer's 2 s steady guard",
                  secs(d.motionMemoryUpdates, t.fps)
                      < MotionBoxes.scorerSteadyGuardSecs,
                  String(format: "%.2f s", secs(d.motionMemoryUpdates, t.fps)))
        }

        // SWEEP, not just the two shipped tiers — the same standard the scroll
        // guard is held to above. An operator may force any fps the floor
        // admits with --fps (main.swift's parser takes it independently of the
        // resolved tier), so every receipt is re-checked at each of them.
        //
        // ONE p95 PER FPS, deliberately, and this sentence used to claim
        // otherwise (corrected 2026-09-08 — it described a sweep over BOTH
        // measured p95 values that the loop never performed and that could not
        // pass as written: at 20-30 fps the lead is the 1.5 floor, 50-75 ms,
        // while the 51.0 ms p95 implies an 85-101 ms lag). What the loop checks
        // is the lead the code will ACTUALLY compute at that fps, because
        // `inferP95Ms(forFps:)` is keyed on the frame rate and never on the
        // machine — the property that keeps `--process` output machine-
        // independent, receipt at that symbol.
        //
        // The configuration that gap names — a 51.0 ms machine forced to 20-30
        // fps — is real, and a longer paint lead is not its remedy: it is
        // already missing its frame budget on every frame. It is made LOUD
        // instead, by `fpsBudgetWarning`, on stderr and in the `tier` log
        // record at startup and in `--probe`.
        var sweep6OK = true
        var sweep6Worst = ""
        for fps in fpsFloor...30 {
            func fail(_ what: String) {
                sweep6OK = false
                if sweep6Worst.isEmpty { sweep6Worst = "\(what) at \(fps) fps" }
            }
            let p95 = inferP95Ms(forFps: fps)
            if Double(OverlayManager.leadFrames(fps: fps, inferP95Ms: p95))
                <= lagFrames(fps, p95) { fail("lead under-covers the lag") }
            if OverlayManager.leadFrames(fps: fps, inferP95Ms: p95)
                < OverlayManager.leadFramesAt30 { fail("lead below the shipped 1.5") }
            if p95 >= 1000.0 / Double(fps) { fail("inferP95 does not fit the frame interval") }
            if smootherConvergeSecs(fps) > 1.0 { fail("smoother convergence over 1.0 s") }
            if PaintSmoother.capCells(fps: fps) > PaintSmoother.capCellsPopLimit {
                fail("size cap over the no-pop limit")
            }
            if pinStepArea(fps) > CoverOwnership.pinStepAreaBar {
                fail("pin step over the +0.05 area bar")
            }
            if CoverOwnership.pinGrowCells(fps: fps)
                <= PaintSmoother.capCells(fps: fps) { fail("pin cannot keep up with the smoother") }
            if secs(CoverOwnership.pinRemeasureUpdates(fps: fps), fps)
                < 2 * smootherConvergeSecs(fps) - 1e-9 {
                fail("re-measure window under 2x smoother convergence")
            }
            if secs(Pipeline.ownershipResolveEvery(fps: fps), fps)
                > Pipeline.ownershipResolveLagSecs + 1e-9 {
                fail("ownership blind spot over 100 ms")
            }
            if MotionBoxes.motionMemoryUpdates(fps: fps)
                < MotionBoxes.motionMemoryStrandFloor { fail("motion memory under the strand floor") }
            if secs(MotionBoxes.motionMemoryUpdates(fps: fps), fps)
                >= MotionBoxes.scorerSteadyGuardSecs { fail("motion memory past the steady guard") }
        }
        check("all six live-paint constants hold their receipts at EVERY fps "
              + "\(fpsFloor)...30",
              sweep6OK, sweep6Worst)

        // The hole the sweep above deliberately does NOT close, and the
        // warning that makes it visible instead (receipt at fpsBudgetWarning).
        for t in all {
            check("tier \(t.name.rawValue): no fps-budget warning at its own fps",
                  fpsBudgetWarning(tier: t, fps: t.fps) == nil,
                  fpsBudgetWarning(tier: t, fps: t.fps) ?? "")
        }
        var warnedFrom = 0
        for fps in fpsFloor...30 where fpsBudgetWarning(tier: noAne, fps: fps) != nil {
            if warnedFrom == 0 { warnedFrom = fps }
        }
        check("a no-ane machine forced above its own fps is WARNED, from 20 fps "
              + "up (where 51.0 ms stops fitting the frame interval)",
              warnedFrom == 20, "first warned fps=\(warnedFrom)")
        check("the warning names the budget, the measurement and the fix",
              (fpsBudgetWarning(tier: noAne, fps: 30) ?? "").contains("MEASURED")
              && (fpsBudgetWarning(tier: noAne, fps: 30) ?? "").contains("fix:"),
              fpsBudgetWarning(tier: noAne, fps: 30) ?? "")

        // The two-sided derivations, printed so a reader sees what each tier
        // actually pays rather than only that it passed.
        for t in all {
            print(String(
                format: "# tier %@ (fps %d): lead %.4f frames, smoother "
                + "converges %.3f s, worst pin collapse closes %.2f s, "
                + "pin step %.3f area",
                t.name.rawValue, t.fps,
                Double(Derived(fps: t.fps).leadFrames),
                smootherConvergeSecs(t.fps), pinRecoverSecs(t.fps),
                Double(pinStepArea(t.fps))))
        }

        // --- tier-level invariants ---
        for t in all {
            check("tier \(t.name.rawValue) fps >= fpsFloor",
                  t.fps >= fpsFloor, "fps=\(t.fps) floor=\(fpsFloor)")
            // NOTE: this is the FRAME-SUPPLY half only — are there enough
            // capture frames in `windowSecs` to carry 3 hits? The cadence half
            // (can the attribution walk actually ATTRIBUTE that many?) is a
            // different constraint and is checked separately above; a earlier
            // draft had only this one, which passes even at a 3 Hz walk.
            check("tier \(t.name.rawValue): enough frames in windowSecs for "
                  + "triggerHits, 2x margin",
                  Double(t.fps) * Curtain.windowSecs >= 2 * Double(Curtain.triggerHits),
                  "frames in windowSecs=\(Double(t.fps) * Curtain.windowSecs)")
            check("tier \(t.name.rawValue) fits SPEC §6 latency budget",
                  latencyEstimateMs(t) <= latencyBudgetMs,
                  String(format: "estimate=%.1f ms budget=%.0f ms",
                         latencyEstimateMs(t), latencyBudgetMs))
            check("tier \(t.name.rawValue) inferP95 fits its frame interval",
                  t.inferP95Ms < 1000.0 / Double(t.fps),
                  String(format: "p95=%.1f interval=%.1f",
                         t.inferP95Ms, 1000.0 / Double(t.fps)))
        }
        check("20 fps would NOT fit the measured cpuOnly p95",
              noAne.inferP95Ms > 1000.0 / 20.0,
              "this is why the no-ane tier is 15, not 20 (2% margin — see the "
              + "caveat at PerfTier.noAne)")
        check("fps 5 would blow the SPEC §6 latency budget (the floor is real)",
              latencyEstimateMs(Tier(name: .noAne, fps: 5,
                                     inferP95Ms: noAne.inferP95Ms,
                                     why: "floor probe")) > latencyBudgetMs)

        // --- close ring pair: what WindowTracker.closeNewPosition can reach ---
        // The tripwire at `WindowTracker.closeSamples` claims two bounds on a
        // ring pair closer than half a poll period that carries a NEW position.
        // Prose cannot rot into being wrong; this can. Pure math, no window
        // server, no display — `projectedFrame` is `static` for exactly this.
        func ring(_ stamps: [Double], _ origins: [(CGFloat, CGFloat)])
            -> [WindowTracker.Sample]
        {
            // Newest first, the order `recentDistinctSamples` returns.
            zip(stamps, origins).map {
                WindowTracker.Sample(
                    t: $0.0, frame: CGRect(x: $0.1.0, y: $0.1.1, width: 100, height: 100))
            }
        }
        let closeDt = 0.5 / WindowTracker.pollHz
        // A turn: X already travelling, Y fresh, newest pair 1 ms apart — i.e. a
        // pair `closeNewPosition` would count. The fresh-axis 2-tap fit is the
        // one that read 10 650 pt/s on a 240 pt/s drag, and `freshPairFloor` is
        // the SAME 0.5/pollHz threshold, so it must refuse this outright.
        let closePair = ring([0.021, 0.020, 0.000], [(20, 5), (10, 0), (0, 0)])
        let closeProj = PaintExtrapolator.projectedFrame(from: closePair, at: 0.031)
        check("close ring pair (1 ms < \(String(format: "%.2f", closeDt * 1000)) ms): "
              + "the fresh axis is refused, so no 2-tap fit divides by it",
              closeProj.map { $0.minY == 5 } ?? false,
              "projected=\(String(describing: closeProj)) (minY must stay at the "
              + "measured 5, i.e. dy == 0)")
        // Control: the SAME shape with the pair 6 ms apart — above the floor —
        // does project, which is what makes the refusal above attributable to
        // `freshPairFloor` and not to some other guard.
        let farPair = ring([0.026, 0.020, 0.000], [(20, 5), (10, 0), (0, 0)])
        let farProj = PaintExtrapolator.projectedFrame(from: farPair, at: 0.036)
        check("control: the same turn with a 6 ms pair DOES project the fresh axis",
              farProj.map { $0.minY > 5 } ?? false,
              "projected=\(String(describing: farProj))")
        // The 3-sample span fit is bounded rather than refused: a close pair can
        // only shorten `span`, and `minVelocityBaseline` is 1/pollHz — twice the
        // close threshold — so the pair contributes at most half the shortest
        // span the fit accepts. Below that floor there is no projection at all.
        let tooShort = ring([0.006, 0.003, 0.000], [(8, 0), (4, 0), (0, 0)])
        check("a ring whose whole span is under 1/pollHz projects nothing",
              PaintExtrapolator.projectedFrame(from: tooShort, at: 0.016) == nil)
        // AT the floor, with the close pair contributing its maximum share: two
        // 4 pt commits over 8.4 ms = 952 pt/s, times the 50 ms
        // `maxWindowProjection` horizon = 47.6 pt of lead. `pinnedAdvance`
        // unions that with the measured rect, so it is over-cover, not exposure.
        let atFloor = ring([0.0084, 0.0083, 0.000], [(8, 0), (4, 0), (0, 0)])
        let floorProj = PaintExtrapolator.projectedFrame(from: atFloor, at: 0.0684)
        let floorLead = (floorProj?.minX ?? 0) - 8
        check("worst span-fit lead a close pair can buy stays under 48 pt",
              floorLead > 47 && floorLead < 48,
              String(format: "lead=%.2f pt", floorLead))

        print("PROBE SELFTEST: \(passed)/\(passed + failed) PASS")
        return failed == 0 ? 0 : 1
    }

    // MARK: - sysctl

    private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Width is read from the kernel rather than assumed: `hw.physicalcpu` is a
    /// 32-bit int and `hw.memsize` a 64-bit one, and reading either at the
    /// wrong width returns a plausible wrong number instead of an error.
    private static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<UInt32>.size {
            var v: UInt32 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        }
        if size == MemoryLayout<UInt64>.size {
            var v: UInt64 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        }
        return nil
    }
}
