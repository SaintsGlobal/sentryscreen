import CoreGraphics
import Foundation

/// Which class set blocks. `strict` is the default (SPEC §5.2: "bias
/// aggressive for a kids' machine"); `standard` is exposure-only, the
/// pre-2026-08-19 behavior. Per-class thresholds are `TuningPolicy` (the
/// "M3" per-class config, delivered 2026-09-10).
enum PolicyMode: String {
    case strict
    case standard
}

/// TUNING POLICY (curtain false-positive batch 1/3, 2026-09-10). Every
/// consequential tracker / curtain number that used to be a compile-time
/// `static let` lives here as ONE value, with its receipt at the field.
///
/// Sources, in precedence order (later wins, field by field):
///   1. `TuningPolicy.defaults` — the receipted constants. Every value is
///      the pre-2026-09-10 constant except `coveredBeatsExposed` /
///      `coveredOverlap`, switched on by PR 2/3 of the false-positive batch
///      after the offline sweep (receipt at the fields; the synthetic gate
///      stayed GREEN because no fixture carries an exposed box inside a
///      covered one).
///   2. `config.json` `"tuning": {…}` (`parse`, applied by
///      `Options.applyConfig`; an unknown key or an out-of-range value exits
///      64 by name, like every other config key).
///   3. `<state>/parent/tuning.json` — the tuning file (`TuningFile`,
///      like DevOverrides): hot-reloaded on the
///      settings store's 1 Hz tick; a rejected file is logged by key and the
///      previous policy stays in force.
///
/// Tracker and Curtain hold a value copy and read it per frame on
/// detectQueue; `Pipeline.setTuning` swaps it the way `setPolicy` swaps the
/// mode. Every swap logs one `"event":"tuning"` record with the effective
/// values and the source. `--print-tuning` dumps the effective policy.
///
/// WHAT IS NOT HERE, on purpose: `--conf` (the detector floor, a flag /
/// export constant, not a policy), the curtain geometry constants (parole
/// horizons, ghost bans, lift timers — none of them implicated in the false
/// positives this batch targets), and `--block-faces` (a benign test mode).
struct TuningPolicy: Equatable {
    /// One detection class.
    struct ClassRule: Equatable {
        /// Block floor on the model's RAW obj·cls score (receipt at
        /// `TuningPolicy.defaults`: explicit 0.7–0.9 per class since
        /// 2026-10-20, covered 0.6).
        var threshold: Float
        /// One step of the staircase: from `minPt` UP (shorter side in screen
        /// points, inclusive) the block floor is this `threshold` instead of
        /// the flat one.
        struct SizeStep: Equatable {
            var minPt: Double
            var threshold: Float
        }
        /// THRESHOLD STEPS: a per-class staircase layered ON TOP of
        /// `threshold`, never replacing it — below the first step the flat
        /// `threshold` applies, at or above a step's `minPt` that step's
        /// threshold does (last match wins). Empty = today's behaviour, and
        /// the defaults ship empty: this PR delivers the MECHANISM, no step.
        ///
        /// WHY A STAIRCASE AND NOT A HIGHER FLAT FLOOR:
        /// the model's score tracks box size — 16–32 pt median 0.64 with
        /// 0.0 % at ≥ 0.9, 32–48 pt 0.79 / 1.0 %, 48–64 pt 0.86 / 17.7 %,
        /// 64–80 pt 0.90 / 51.3 %, 96–144 pt 0.91 / 74.3 %. A flat raise
        /// therefore costs true boxes wherever the content is small (the
        /// 2026-09-10 composite receipt: every flat raise loses more true
        /// boxes than false), while the remaining false boxes (hands,
        /// objects) are small. A size-keyed floor is the only lever that can
        /// be strict on big boxes and lenient on small ones.
        ///
        /// MEASURED on the same log:
        /// `FEMALE_BREAST_EXPOSED` at 0.8 flat plus one step {64, 0.9} cuts
        /// 898 boxes but empties only 40 of 1,552 blocked frames and changes
        /// 0 of 3 modeled curtain drops — A BOX COUNT IS NOT A FRAME COUNT
        /// AND NEITHER IS A DROP. The curtain counts FRAMES with ≥ 1 blocked
        /// box, so a per-box step moves a drop only when it removes the LAST
        /// blocked box of a frame.
        ///
        /// CURTAIN *AND* REGION: one `filter` runs per frame (main.swift) and
        /// feeds both pipelines — the curtain (`curtainRects(blocked, …)`)
        /// and the region/media path, which runs the STRICT policy. A step on
        /// a covered class bites there too. There is deliberately no
        /// curtain-only second policy struct (it would be a second source for
        /// every number, with no receipt).
        ///
        /// SCHEMA, and what was rejected: the wire form is
        /// `"thresholdSteps": [{"minPt": 64, "threshold": 0.9}]`. Rejected:
        /// a `thresholdBySize` list carrying a `minPt: 0` row (it restates
        /// `threshold`, giving one number two sources and making the dev
        /// tab's `threshold` slider a silent no-op) and the `[[64, 0.9]]`
        /// pair form (unreadable in a config file). The array REPLACES the
        /// whole list when layered — arrays never merge per index; `[]`
        /// clears the staircase.
        ///
        /// A step can only RAISE the floor: `filter` applies the flat
        /// `threshold` (`blocks`) before the staircase, so a step below it
        /// could never fire — such a step is refused BY NAME at load and in
        /// the Developer tab (`validateSteps`), never accepted as a no-op.
        /// That is also what makes the unmeasured-screen fallback fail-safe:
        /// see `thresholdStep`.
        var thresholdSteps: [SizeStep] = []
        /// TRIPWIRE, not a capacity limit: at most this many steps (5
        /// brackets). Receipt (MEASURED 2026-09-11, the score-vs-size table
        /// above): three score regimes — under 32 pt, 32–64 pt, 64 pt and up
        /// — so 2 boundaries meet the measured need and 4 is 2× it. The cap
        /// exists so a fitted 40-entry curve fails BY NAME at load instead of
        /// quietly becoming a 40-row table.
        static let maxSteps = 4
        /// MIN BOX FRACTION: a box whose area is below this fraction of the
        /// CAPTURED DISPLAY's area does not block (0 = off, today's
        /// behaviour). Display-relative, not window-relative: the policy
        /// filter runs before any box is attributed to a window, and the
        /// receipt is measured against the capture. Receipt for the knob:
        /// the explicit-class false positives
        /// on the owner's desktop are 15–68 px on a side at 1920 px capture
        /// width (0.8–3.6 % of the side, i.e. 0.0001–0.002 of the area) —
        /// hands, fingers and swimsuit thumbnails — while the boxes the
        /// curtain exists for are whole-image regions. DEFAULT 0 (OFF) BY
        /// MEASUREMENT, not caution:
        /// the smallest floor that removes
        /// ONE of the 11 exposed-class drops on the owner's desktop (0.001 of
        /// the area / 32 pt) deletes 48 / 29 true boxes on the display-exact
        /// eval-v8 captures (MGE, FGE, ANUS among them) and both true drops of
        /// the thumbnail-scale live log; at 0.0005 / 24 pt it removes no drop
        /// and already loses 22 / 11 true boxes. The false boxes (36–140 px)
        /// are the size of true ones. A per-machine override stays available.
        /// Re-receipted on 4,000 held-out desktop composites:
        /// every floor that
        /// removes a false box loses 2–3× as many true ones (16 pt: 16 / 46;
        /// 0.0002: 7 / 20); a quarter of the FGE truth is under 32 px.
        var minBoxFraction: Double = 0
        /// MIN BOX SIDE in screen POINTS: a box whose shorter side is below
        /// this does not block (0 = off). Same receipt as `minBoxFraction`
        /// (the 17–32 px thumbnail-scale FBE boxes of gap 7); the points
        /// form is what a person reasons about at a given screen size. Not
        /// applicable when the screen size is unknown (`--replay` carries no
        /// screen; a live run whose display size resolves to 0×0): every box
        /// that reached the floor unmeasured is counted in
        /// `Filtered.minBoxPtUnmeasured` (`tuningMinBoxPtUnmeasured` in the
        /// 60 s summary; `--replay` prints it) — never skipped silently.
        var minBoxPt: Double = 0
        /// CURTAIN-MODE ENTRY DEBOUNCE, per class: consecutive detector
        /// frames a detection must be seen on before it births a region.
        /// Receipt at `Tracker.confirmedEntries` (the owner decision of
        /// 2026-09-02: 2 frames, so a single-frame false positive never
        /// paints). Region/media modes always use 1 (SPEC §5.4).
        var entryFrames: Int = ClassRule.defaultEntryFrames
        /// The curtain-mode default for every class, including classes with
        /// no rule of their own (`INJECT_TEST`, the `--block-faces` faces):
        /// receipt at `Tracker.confirmedEntries`.
        static let defaultEntryFrames = 2
    }

    /// The curtain state machine's evidence bars and hold (receipts were at
    /// the `Curtain` statics they replace; restated here).
    struct CurtainRules: Equatable {
        /// Hits inside `windowSecs` needed to drop the curtain. Basis: the
        /// live strict run (daemon/testdata/livestrict-bing-2026-08-19.jsonl) shows
        /// on-screen flagged content producing 20+ blocked detections/s,
        /// while a single-frame false positive produces 1-2 hits. Was 5 (4x
        /// separation); 3 keeps a 1.5x margin over the worst single-frame FP
        /// and takes two detector frames off the curtain's arrival. MEASURED
        /// 2026-08-25 (A/B rig, benign faces + --block-faces): with 5 the
        /// curtain painted ~200 ms after the region cover. Owner QA
        /// 2026-08-25 called the arrival slow.
        var triggerHits = 3
        var windowSecs: Double = 1.0
        /// A window whose frame CONTAINS an active (or just lifted) curtain's
        /// frame inherits its trust and drops after this many hits instead
        /// of `triggerHits`. Receipt (fs-h1/h2): the fullscreen successor
        /// otherwise earns a curtain from zero, 2.7 s exposed.
        var handoffHits = 2
        /// Attributed hits inside `windowSecs` that re-drop a HIT parolee
        /// (owner decision 2026-09-02: one hit — a single-frame false
        /// positive — no longer re-drops a known offender). Receipt: the
        /// `triggerHits` margin, applied to parole; the bar climbs by one per
        /// further hold-expiry lift inside `Curtain.hitParoleSecs`, never
        /// above `triggerHits` (`Curtain.hitParoleBar`).
        var paroleHits = 2
        /// Lift after this long with no blocked detection inside the window.
        /// Mirrors mediaHoldSecs: measured 2.5 s detector dropouts inside
        /// playing content, 2x margin (receipt at Options.mediaHoldSecs).
        var holdSecs: Double = 5.0
        /// A hold lift also needs this many detector-evaluated clean frames.
        /// MEASURED 2026-08-26: a static screen left 18.7 s between capture
        /// frames, and thin evidence let wall time lift a curtain before the
        /// detector proved the content was clean. DERIVED: 20 is two thirds
        /// of the 30 frames a starved 6 fps stream produces in `holdSecs`.
        /// Deliberately NOT fps-derived (a property of capture starvation,
        /// not of the configured rate); it DOES bind live on a static
        /// desktop, where ScreenCaptureKit delivers ~2 fps.
        /// Full history at
        /// `Curtain.holdCleanFrames`' former site in git.
        var holdCleanFrames = 20
    }

    /// The region tracker's hysteresis (receipts restated from the `Tracker`
    /// statics they replace; the frame FLOORS stay on `Tracker` — they are
    /// measured frame counts that do not scale, and they are not tunable).
    struct TrackerRules: Equatable {
        /// Hysteresis as a DURATION (scales with fps; `Tracker.clearAfter`
        /// applies the 8-frame floor). Receipt (replay sweep, 4 fixtures,
        /// 2026-08-17): handoff deaths at clearAfter 4 → 8: nav10 49→1,
        /// scroll20 35→0; the knee is 7-8 frames at 10 and 20 fps; 0.4 s is
        /// 12 frames at 30 fps. Fail-safe direction: covers linger.
        var clearAfterSecs = 0.4
        /// Sticky hold as a duration (`Tracker.stickyHoldFrameFloor` = 20
        /// applies). Receipt (video-test2 replay, 2026-08-17, 20 fps):
        /// detector miss runs ≤5 frames at a persisting subject, an
        /// intermittent second subject recurs after 13-18-frame gaps; hold 20
        /// (= 1.0 s at 20 fps) took cover drops 7/1109 and 134/1256 to 0.
        var stickyHoldSecs = 1.0
        /// A region whose peak RAW confidence reached this holds
        /// `stickyHold` frames of misses instead of `clearAfter`.
        ///
        /// THE INVARIANT, restated 2026-10-20 (value unchanged, 0.6). Until
        /// then this said "above every block threshold" (it sat at or above
        /// the 0.5 explicit and 0.6 covered floors), so a region needed a
        /// score above its blocking floor to earn the long hold, and an
        /// explicit region that only ever scored 0.5–0.6 cleared after
        /// `clearAfter`. The 2026-10-20 explicit floors (0.7–0.9) are above
        /// 0.6, so that is no longer true. What the tracker actually
        /// guarantees, and what it is FOR (`Tracker.holdFrames`): a region
        /// BELOW stickyConf never gets the sticky hold; a region at or above
        /// it does. The fail-safe direction is "covers linger".
        ///
        /// DECISION: keep 0.6 and keep the comparison as it is; do NOT make it
        /// per-class `max(stickyConf, threshold)`. Reasons:
        ///  1. No tracker timing changes for any box that blocks under both
        ///     the old and the new floors. Regions are born only from boxes
        ///     the policy blocked (`Pipeline.step` feeds `filtered.blocked`),
        ///     so at the new defaults every explicit region peaks at ≥ 0.7
        ///     and gets the sticky hold, exactly as every such box (≥ 0.6)
        ///     did before. The boxes that used to get the short hold
        ///     (explicit 0.5–0.6) no longer block at all.
        ///  2. `max(stickyConf, threshold)` would be a no-op: a region is
        ///     born at or above its class floor, so it always clears
        ///     max(0.6, floor) whenever floor ≥ 0.6. It would also need a
        ///     label on `TrackedRegion`, which has none on purpose
        ///     (`Tracker.mergeDetections` unions boxes across labels).
        ///  3. Raising stickyConf to ≥ 0.9 to restore "above every floor"
        ///     would shorten the hold of every covered (0.6) region and of
        ///     every FGE/AE (0.7) and BE (0.8) region, from `stickyHold`
        ///     to `clearAfter`: a tracker retune in the unsafe direction.
        /// So: stickyConf ≤ every shipped floor means every region of a
        /// shipped class gets the sticky hold. `--ui-selftest` "tuning:
        /// stickyConf …" asserts both halves (no shipped floor below it; a
        /// region under it still clears at `clearAfter`, via a
        /// `--block-faces` 0.25-floor box). Receipt for the value at the
        /// former `Tracker.stickyConf` (git history).
        var stickyConf: Float = 0.6
        /// IoU at which a new box matches an existing region (SPEC §5.4) and
        /// at which overlapping detections merge (`Tracker.mergeDetections`).
        var matchIoU: Double = 0.3
    }

    /// Explicit-exposure classes: block at ≥ threshold in every mode
    /// (SPEC §5.2). `INJECT_TEST` is the debug inject hotkey's synthetic box
    /// (threshold 0; not configurable).
    var standard: [String: ClassRule]
    /// Covered (swimwear/underwear) classes: block only under `.strict`.
    var strict: [String: ClassRule]
    /// COVERED BEATS EXPOSED: an exposed box of a body part sitting mostly
    /// inside a covered box of the SAME part is demoted to the covered label
    /// before the policy filter — so under `standard` it stops blocking, and
    /// under `strict` it blocks at the covered floor. Receipt for the rule:
    /// 3 of the 7 drops were FEMALE_BREAST_
    /// EXPOSED bursts logged in the SAME frames as FEMALE_BREAST_COVERED /
    /// FEMALE_GENITALIA_COVERED / BUTTOCKS_COVERED boxes on the owner's
    /// swimsuit video, and gap 7 counted 133 such frames. The covered box is
    /// checked on the RAW detections (standard policy drops covered boxes
    /// before anything else sees them). ON BY DEFAULT since PR 2/3:
    /// removes 3 of the 11 exposed-class curtain drops
    /// (all FEMALE_BREAST_EXPOSED 46–56 px boxes inside FEMALE_BREAST_COVERED
    /// boxes) and adds none; on the frozen eval v8 answer key it loses 0 true
    /// boxes on every subset (`tuning_rules_eval.py`: the key holds 2 such
    /// pairs in 623 frames) and the thumbnail-scale live log keeps 2/2 of its
    /// true drops. No other lever in the sweep removed a drop without losing
    /// true detections.
    var coveredBeatsExposed = true
    /// "Mostly inside": intersection area over the SMALLER box's area (not
    /// IoU — a small exposed box inside a large covered box has a tiny IoU
    /// by construction). 0.9 MEASURED (same sweep): 0.5…0.9 remove the same
    /// 3 desktop drops and demote the same 431 boxes — the overlap is
    /// binary in practice (fully inside or not) — while 1.0 removes only 1;
    /// on the true-content live log 0.5…0.8 ADD one drop by re-ordering a
    /// burst and 0.9 adds none, so 0.9 is the highest bar that keeps the full
    /// effect. Range floor 0.5 because below half "mostly" is false by
    /// definition. Composite set:
    /// 0.7 / 0.8 / 0.9 identical again — 34 false
    /// explicit boxes removed, 23 teacher-true ones demoted, of 4,881.
    var coveredOverlap = 0.9
    /// SCORE HYSTERESIS ("keep"): a box that clears the other rules, sits
    /// under its start floor (the class `threshold`, or its size step) but
    /// at or above that floor MINUS this gap, still blocks when it lies on
    /// something already covered — a box of the SAME label the previous
    /// evaluated frame blocked there (`filter`'s `tracked`, `isTracked`).
    /// REGION AND MEDIA COVERS ONLY: in curtain mode the pipeline passes an
    /// empty `tracked`, so curtain crediting and hit counting see exactly
    /// the boxes they saw before hysteresis; a curtain already has its own
    /// hold (`CurtainRules.holdCleanFrames`). Owner decision 2026-09-25,
    /// after the first version let a curtain keep any label inside
    /// it (content at 0.35 stayed curtained 66 % of frames, 9 % before).
    /// The match (centre inside, or IoU ≥
    /// `tracker.matchIoU` 0.3) is looser than the IoU ≥ 0.5 pairing the
    /// jitter below was measured on, on purpose: a box that moved with the
    /// content keeps its cover, and the same-label rule is what stops a
    /// different false box inheriting one. A
    /// box's FIRST cover still needs the full start floor; only an existing
    /// cover is kept. 0 = off.
    ///
    /// Why:
    /// the same
    /// content's score changes by p50 0.03 / p75 0.09 / p90 0.18 on a small
    /// shift (13,035 pairs, 09:25–09:59 UTC; 8,332 and 10,942 pairs in the
    /// two earlier logs agree). A box at or above its floor that fell below
    /// it on the next frame fell by p50 0.08 / p75 0.15 / p90 0.24 (417
    /// crossings). 0.15 keeps 73 % of those crossings (0.10: 56 %, 0.20:
    /// 84 %; the earlier logs 77 % and 77 %), and leaves every keep floor
    /// well above the detector's 0.25 (explicit 0.35, covered 0.45). A
    /// higher gap buys fewer crossings per point of gap while it lowers the
    /// bar a false box, once covered, must stay above.
    ///
    /// COST: region content
    /// scoring 0.35 stays covered 22 % of frames (18 % before).
    /// Default off (owner 2026-09-25): no production behaviour change; enable via tuning after owner review.
    var keepGap = 0.0
    /// SETTLE RE-CHECK: when the screen goes still after motion, the frame
    /// the idle gate evaluates is detected a second time, shifted by
    /// `Pipeline.settleShiftPx`, and each box keeps the higher of its two
    /// scores (`Pipeline.mergeRecheck`). On a still screen the same pixels
    /// give the same score every frame (MEASURED: 89,681 of 102,716
    /// same-box pairs in a test Mac log above changed by exactly 0), so a box
    /// resting just under its floor would otherwise stay under it; the
    /// shift is the only second sample. Cost and receipt at
    /// `Pipeline.settleShiftPx`.
    /// Default off (owner 2026-09-25): no production behaviour change; enable via tuning after owner review.
    var settleRecheck = false
    /// The zoom (tiling) pass (`ZoomTiles`): one 2 × 2 tile per evaluated
    /// frame in rotation on top of the full-frame pass. ON in `defaults`
    /// since 2026-10-20 (owner decision; it was an off-by-default
    /// Developer-tab prototype from 2026-10-07). The memberwise default
    /// stays `false` so a hand-built policy opts in explicitly; `defaults`
    /// sets it. RECEIPT, and its limit: the evidence is OFFLINE only —
    /// explicit boxes found 107 → 162 on captures (receipt at `ZoomTiles`)
    /// and the detect call MEASURED at 1.59–1.67× the full-frame-only cost
    /// at p50 (`ZoomTiles.next`). UNMEASURED on live screens: neither the
    /// recall gain nor the CPU cost has a live receipt yet. Frames the idle
    /// gate skips never reach `Pipeline.step`, so they run no tile pass;
    /// every frame that IS evaluated pays it (`--ui-selftest` group `zoom`).
    var zoomTiles = false
    var curtain = CurtainRules()
    var tracker = TrackerRules()

    // MARK: Labels

    static let exposedLabels = [
        "FEMALE_BREAST_EXPOSED", "FEMALE_GENITALIA_EXPOSED", "MALE_GENITALIA_EXPOSED",
        "BUTTOCKS_EXPOSED", "ANUS_EXPOSED",
    ]
    static let coveredLabels = [
        "FEMALE_BREAST_COVERED", "FEMALE_GENITALIA_COVERED", "BUTTOCKS_COVERED",
    ]
    /// exposed → covered label of the same body part (`coveredBeatsExposed`).
    static let coveredPairs: [String: String] = [
        "FEMALE_BREAST_EXPOSED": "FEMALE_BREAST_COVERED",
        "FEMALE_GENITALIA_EXPOSED": "FEMALE_GENITALIA_COVERED",
        "BUTTOCKS_EXPOSED": "BUTTOCKS_COVERED",
    ]
    static let injectLabel = "INJECT_TEST"
    /// Benign live-test mode (--block-faces): treat faces as blockable so
    /// overlay tracking can be exercised with a portrait photo on screen.
    /// A test mode, not policy — not in the struct, not configurable.
    static let faceThresholds: [String: Float] = [
        "FACE_FEMALE": 0.25, "FACE_MALE": 0.25,
    ]

    /// THE DEFAULTS (asserted by `--ui-selftest` "tuning: defaults").
    ///
    /// EXPLICIT FLOORS, per class since 2026-10-20 (owner decision; before,
    /// every explicit class was 0.5, SPEC §5.2's minimum and the distill
    /// parity gate's `classes.CONF_FLOOR`, live on the raw score since
    /// 2026-09-02):
    ///   FEMALE_BREAST_EXPOSED 0.90, FEMALE_GENITALIA_EXPOSED 0.70,
    ///   MALE_GENITALIA_EXPOSED 0.90, BUTTOCKS_EXPOSED 0.80, ANUS_EXPOSED 0.70.
    /// SOURCE: the owner's live run on swimsuit-level video, 2026-10-20 —
    /// the 0.5 floors curtained swimsuit content; these are the floors the
    /// owner chose against that run. They are an owner decision, not a
    /// sweep optimum. KNOWN COST (MEASURED, the score-vs-size table at
    /// `ClassRule.thresholdSteps`): the model's score tracks box size, so a
    /// flat floor this high loses true boxes, small ones first — in the
    /// composite set, 16–32 pt boxes NEVER scored ≥ 0.9 (0.0 %), 32–48 pt
    /// boxes 1.0 %, 48–64 pt 17.7 %. A small or partial true
    /// FEMALE_BREAST_EXPOSED / MALE_GENITALIA_EXPOSED box is therefore now
    /// expected to go uncovered. SPEC §5.2's 0.5 is a minimum, which these
    /// stay above. `tracker.stickyConf` 0.6 is now BELOW the explicit
    /// floors: consequence and decision at `TrackerRules.stickyConf`.
    /// 0.6 for the covered classes (unchanged): RAW-SCORE RECEIPT:
    /// covered floor 0.4 / 0.5 / 0.6 / 0.7 →
    /// owner covered captures tp/fp 38/26 · 28/20 · 25/12 · 18/7, clean-screen
    /// FP 2 · 0 · 0 · 0 /250. 0.6 is the lowest floor with better than 2 tp
    /// per fp; covered recall there is .116 — the thumbnail regime the
    /// covered data round targets, not something this floor can buy back.
    static let defaultExposedThresholds: [String: Float] = [
        "FEMALE_BREAST_EXPOSED": 0.9, "FEMALE_GENITALIA_EXPOSED": 0.7,
        "MALE_GENITALIA_EXPOSED": 0.9, "BUTTOCKS_EXPOSED": 0.8, "ANUS_EXPOSED": 0.7,
    ]
    static let defaults: TuningPolicy = {
        var standard: [String: ClassRule] = [:]
        // `!`: a label missing from the table must stop the build's self-test
        // run, not ship at a floor nobody chose.
        for label in exposedLabels { standard[label] = ClassRule(threshold: defaultExposedThresholds[label]!) }
        standard[injectLabel] = ClassRule(threshold: 0.0)
        var strict: [String: ClassRule] = [:]
        for label in coveredLabels { strict[label] = ClassRule(threshold: 0.6) }
        var p = TuningPolicy(standard: standard, strict: strict)
        p.zoomTiles = true  // receipt at `zoomTiles`
        return p
    }()

    // MARK: Decisions

    func rule(for label: String) -> ClassRule? { standard[label] ?? strict[label] }

    /// Curtain-mode consecutive frames before a region is born.
    func entryFrames(for label: String) -> Int {
        rule(for: label)?.entryFrames ?? ClassRule.defaultEntryFrames
    }

    /// The threshold decision alone (the pre-2026-09-10 `Policy.blocks`).
    func blocks(_ d: Detection, mode: PolicyMode, blockFaces: Bool) -> Bool {
        if let r = standard[d.label], d.confidence >= r.threshold { return true }
        if mode == .strict, let r = strict[d.label], d.confidence >= r.threshold { return true }
        if blockFaces, let t = Self.faceThresholds[d.label], d.confidence >= t { return true }
        return false
    }

    enum MinBox: Equatable {
        case passes
        case dropped
        /// The point floor is configured but the screen size is 0×0.
        case unmeasured
    }

    /// The box's SHORTER SIDE IN SCREEN POINTS — the one measurement both
    /// point levers key on (`ClassRule.minBoxPt` and `thresholdSteps`), so
    /// they can never disagree about how big a box is. nil when the screen is
    /// unmeasurable (0×0: `--replay`, or a display that resolves to nothing).
    static func sidePt(_ box: CGRect, screen: CGSize) -> Double? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        return Double(min(box.width * screen.width, box.height * screen.height))
    }

    /// The size floor (`ClassRule.minBoxFraction` / `minBoxPt`). `screen` is
    /// the captured display in points.
    func minBox(_ d: Detection, screen: CGSize) -> MinBox {
        guard let r = rule(for: d.label) else { return .passes }
        if r.minBoxFraction > 0, Double(d.box.width * d.box.height) < r.minBoxFraction {
            return .dropped
        }
        if r.minBoxPt > 0 {
            guard let side = Self.sidePt(d.box, screen: screen) else { return .unmeasured }
            if side < r.minBoxPt { return .dropped }
        }
        return .passes
    }

    /// The stepped block floor for one box (`ClassRule.thresholdSteps`).
    enum StepFloor: Equatable {
        /// No staircase on this class: the flat `threshold` already decided.
        case none
        /// The floor this box must clear.
        case floor(Float)
        /// A staircase is configured but the screen is 0×0.
        case unmeasured
    }

    /// Which floor the staircase puts under one box. `sidePt` is
    /// `Self.sidePt(d.box, screen:)` — the SAME measurement `minBox` makes.
    ///
    /// A box exactly at `minPt` takes the HIGHER bracket (inclusive lower
    /// bound): the same convention as `minBoxPt`, where `side < minBoxPt`
    /// drops — one rule for both point levers.
    ///
    /// "Last match wins" is bracket lookup, because `parse` refuses steps
    /// whose `minPt` does not strictly increase; it stays correct if that
    /// ordering rule is ever relaxed.
    ///
    /// UNMEASURED SCREEN: `.unmeasured`, and the caller falls back to the
    /// flat `threshold` and COUNTS it (`Filtered.stepUnmeasured`), never
    /// silently. Every step is at or above the base (`validateSteps`), so
    /// an unmeasured screen blocks MORE, never less — the fail-safe
    /// direction (`TrackerRules.clearAfterSecs`).
    func thresholdStep(for label: String, sidePt: Double?) -> StepFloor {
        guard let r = rule(for: label), !r.thresholdSteps.isEmpty else { return .none }
        guard let side = sidePt else { return .unmeasured }
        var t = r.threshold  // below the first step: the base
        for s in r.thresholdSteps where side >= s.minPt { t = s.threshold }
        return .floor(t)
    }

    /// `coveredBeatsExposed` on the RAW detections: returns the list with
    /// every demoted box relabelled (same confidence, same geometry) and the
    /// count. A demotion pairs an exposed label with the covered label of the
    /// SAME body part only (`coveredPairs`).
    func demoteCovered(_ raw: [Detection]) -> (detections: [Detection], demoted: Int) {
        guard coveredBeatsExposed else { return (raw, 0) }
        var demoted = 0
        let out = raw.map { d -> Detection in
            guard let covered = Self.coveredPairs[d.label] else { return d }
            let inside = raw.contains { c in
                c.label == covered && Self.overlapOfSmaller(d.box, c.box) >= coveredOverlap
            }
            guard inside else { return d }
            demoted += 1
            return Detection(
                label: covered, confidence: d.confidence, box: d.box,
                mediaExpanded: d.mediaExpanded)
        }
        return (out, demoted)
    }

    /// Intersection area over the smaller box's area (1 = fully inside).
    static func overlapOfSmaller(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? Double(inter.width * inter.height / smaller) : 0
    }

    struct Filtered {
        var blocked: [Detection]
        /// Boxes the size floor removed (logged as `tuningMinBoxDropped`).
        var minBoxDropped: Int
        /// Boxes a configured `minBoxPt` could not measure (screen 0×0) and
        /// therefore passed (logged as `tuningMinBoxPtUnmeasured`).
        var minBoxPtUnmeasured: Int
        /// Exposed boxes relabelled covered (logged as `tuningCoveredDemoted`).
        var demoted: Int
        /// Boxes the threshold staircase removed — boxes that cleared the
        /// flat `threshold` and the size floor but not their bracket's floor
        /// (logged as `tuningThresholdStepDropped`).
        var stepDropped: Int = 0
        /// Boxes a configured staircase could not measure (screen 0×0) and
        /// which therefore fell back to the flat `threshold` (logged as
        /// `tuningThresholdStepUnmeasured`; `--replay` prints it).
        var stepUnmeasured: Int = 0
        /// This frame had ≥ 1 blocked box under the flat policy and none
        /// under the staircase (logged as `tuningThresholdStepFramesEmptied`).
        /// The frame-level signal the curtain can feel: it counts one hit
        /// PER WINDOW per frame (`Curtain.update`'s `seenThisFrame`), so a cut box moves a
        /// drop only when its window has no other blocked box that frame.
        /// An emptied frame is the whole-screen case of that (receipt at
        /// `ClassRule.thresholdSteps`, one Chrome window: 898 boxes cut →
        /// 40 frames emptied → 0 drops moved); on a multi-window desktop a
        /// window can be emptied while the frame is not.
        var stepEmptiedFrame: Bool = false
        /// Boxes under their start floor that blocked because they sit on
        /// something already covered (`keepGap`; logged as
        /// `tuningKeptTracked`). Always 0 at `keepGap` 0 or with nothing
        /// tracked.
        var kept: Int = 0
    }

    /// The whole policy decision for one frame: demotion on the raw list,
    /// then the flat threshold, then the size floor, then the threshold
    /// staircase. Nothing the policy removes is removed silently — the counts
    /// ride the 60 s summary.
    ///
    /// THE STAIRCASE GOES LAST, AFTER THE SIZE FLOOR: both are AND
    /// conditions, so the blocked set is the same either way, but this order
    /// leaves `minBoxDropped` / `minBoxPtUnmeasured` with exactly their
    /// pre-staircase meaning (a box the size floor removes is a SIZE drop;
    /// the staircase never takes credit for it) and needs no parallel
    /// "blocked under the base" pass. A box under the flat `threshold` is
    /// still not counted as any kind of drop, and `blocked + stepDropped` is
    /// exactly the frame's blocked set under the flat policy.
    ///
    /// `tracked` (normalized, bottom-left, like `Detection.box`): what is
    /// covered going into this frame — the previous evaluated frame's blocked
    /// boxes (`CoveredInput`; empty in curtain mode). A box on one of
    /// them is judged against its KEEP floor (`keepGap`); every other box
    /// against its start floor. Empty = the pre-hysteresis filter exactly.
    func filter(
        _ raw: [Detection], mode: PolicyMode, blockFaces: Bool, screen: CGSize,
        tracked: CoveredInput = .init()
    ) -> Filtered {
        let (detections, demoted) = demoteCovered(raw)
        var dropped = 0
        var unmeasured = 0
        var stepDropped = 0
        var stepUnmeasured = 0
        var kept = 0
        let blocked = detections.filter { d in
            // Flat floor first, exactly as before; a tracked box under it
            // goes on only if it clears the keep floor.
            var keptBox = false
            if !blocks(d, mode: mode, blockFaces: blockFaces) {
                guard let t = startThreshold(d.label, mode: mode, blockFaces: blockFaces),
                    keeps(d, floor: t, tracked: tracked)
                else { return false }
                keptBox = true
            }
            switch minBox(d, screen: screen) {
            case .passes: break
            case .dropped: dropped += 1; return false
            case .unmeasured: unmeasured += 1
            }
            switch thresholdStep(for: d.label, sidePt: Self.sidePt(d.box, screen: screen)) {
            case .none: break
            case .unmeasured: stepUnmeasured += 1  // fall back to the flat threshold
            case let .floor(t) where d.confidence < t:
                guard keeps(d, floor: t, tracked: tracked) else { stepDropped += 1; return false }
                keptBox = true
            case .floor: break
            }
            if keptBox { kept += 1 }
            return true
        }
        return Filtered(
            blocked: blocked, minBoxDropped: dropped, minBoxPtUnmeasured: unmeasured, demoted: demoted,
            stepDropped: stepDropped, stepUnmeasured: stepUnmeasured,
            stepEmptiedFrame: stepDropped > 0 && blocked.isEmpty, kept: kept)
    }

    /// The flat start floor `blocks` applies to this label under `mode`;
    /// nil when the label is not a blocking class there.
    func startThreshold(_ label: String, mode: PolicyMode, blockFaces: Bool) -> Float? {
        if let r = standard[label] { return r.threshold }
        if mode == .strict, let r = strict[label] { return r.threshold }
        if blockFaces, let t = Self.faceThresholds[label] { return t }
        return nil
    }

    /// The keep floor under a start floor (`keepGap`).
    func keepFloor(_ start: Float) -> Float { start - Float(keepGap) }

    /// What was covered going into a frame, for score hysteresis: the
    /// previous evaluated frame's blocked boxes (labels after demotion). A
    /// box is "the same thing" only with the SAME label: MEASURED
    /// 2026-09-25, the first cut keyed on any tracked region rect, and the
    /// gate went RED on scroll-slow and scroll-after-still — a 640m
    /// FEMALE_BREAST_EXPOSED 0.3–0.4 false positive inside a
    /// `--block-faces` face region was kept and covered. Empty in curtain
    /// mode (`forCover`).
    struct CoveredInput {
        var boxes: [Detection] = []

        /// The hysteresis input for a cover mode: `lastBlocked` for region
        /// and media covers, nothing for curtains (see `keepGap`).
        static func forCover(curtain: Bool, lastBlocked: [Detection]) -> CoveredInput {
            curtain ? CoveredInput() : CoveredInput(boxes: lastBlocked)
        }
    }

    /// Hysteresis: under `floor`, but at or above its keep floor, on a
    /// covered thing.
    func keeps(_ d: Detection, floor: Float, tracked: CoveredInput) -> Bool {
        keepGap > 0 && d.confidence < floor && d.confidence >= keepFloor(floor)
            && Self.isTracked(d, in: tracked, iou: tracker.matchIoU)
    }

    /// "Already covered": the same label blocked last frame with its centre
    /// inside this box's predecessor or overlapping it at the tracker's own
    /// match IoU (`TrackerRules.matchIoU`).
    static func isTracked(_ d: Detection, in tracked: CoveredInput, iou: Double) -> Bool {
        let centre = CGPoint(x: d.box.midX, y: d.box.midY)
        return tracked.boxes.contains {
            $0.label == d.label && ($0.box.contains(centre) || Geometry.iou(d.box, $0.box) >= CGFloat(iou))
        }
    }

    /// Why the policy REJECTED each raw box, by index — the per-box view of
    /// `filter` (same three stages, same order), for the withheld tripwire.
    /// A box that blocks is absent. Stage names are the config keys a person
    /// would edit: `coveredBeatsExposed`, `threshold`, `minBox`.
    func rejections(
        _ raw: [Detection], mode: PolicyMode, blockFaces: Bool, screen: CGSize
    ) -> [(index: Int, stage: String)] {
        let (detections, _) = demoteCovered(raw)
        var out: [(index: Int, stage: String)] = []
        for (i, d) in detections.enumerated() {
            // Classes the policy has no rule for (faces outside
            // `--block-faces`, benign labels) are not rejections.
            guard rule(for: d.label) != nil
                || (blockFaces && Self.faceThresholds[d.label] != nil)
            else { continue }
            if d.label != raw[i].label {
                if !blocks(d, mode: mode, blockFaces: blockFaces) {
                    out.append((i, "coveredBeatsExposed"))
                }
                continue
            }
            if !blocks(d, mode: mode, blockFaces: blockFaces) {
                out.append((i, "threshold"))
            } else if minBox(d, screen: screen) == .dropped {
                out.append((i, "minBox"))
            }
        }
        return out
    }

    /// WITHHELD: raw boxes `baseline` (the shipped `defaults`) would block
    /// that this tuning rejects — content a user of the shipped policy would
    /// see covered and this machine's tuning leaves bare. The rejecting
    /// stage rides along. Receipt:
    /// the owner's tuning.json held
    /// FEMALE_BREAST_EXPOSED at 0.9 for 8 min while 0.82–0.88 boxes sat on
    /// screen; the per-frame record carries only RAW detections, the 60 s
    /// counters go to stdout, and nothing in run.jsonl named the stage.
    func withheld(
        _ raw: [Detection], mode: PolicyMode, blockFaces: Bool, screen: CGSize,
        baseline: TuningPolicy
    ) -> [(index: Int, stage: String)] {
        let mine = rejections(raw, mode: mode, blockFaces: blockFaces, screen: screen)
        guard !mine.isEmpty else { return [] }
        let theirs = Set(
            baseline.rejections(raw, mode: mode, blockFaces: blockFaces, screen: screen)
                .map(\.index))
        return mine.filter { !theirs.contains($0.index) }
    }

    // MARK: JSON

    /// The schema every source shares (config.json `tuning`, tuning.json
    /// body, `--print-tuning` output). Class keys are the eight NudeNet
    /// labels above; `INJECT_TEST` is printed, never accepted.
    static let topKeys: Set<String> = {
        var keys: Set<String> = [
            "classes", "coveredBeatsExposed", "coveredOverlap", "keepGap", "settleRecheck", "curtain", "tracker",
        ]
        keys.insert("zoomTiles")
        return keys
    }()
    static let classKeys: Set<String> = [
        "threshold", "thresholdSteps", "minBoxFraction", "minBoxPt", "entryFrames",
    ]
    /// The keys of one `thresholdSteps` entry.
    static let stepKeys: Set<String> = ["minPt", "threshold"]
    static let curtainKeys: Set<String> = [
        "triggerHits", "windowSecs", "handoffHits", "paroleHits", "holdSecs", "holdCleanFrames",
    ]
    static let trackerKeys: Set<String> = ["clearAfterSecs", "stickyHoldSecs", "stickyConf", "matchIoU"]

    var jsonObject: [String: Any] {
        // Six decimals: a Float threshold prints as 0.6, not 0.600000023841.
        // As a decimal NUMBER (2026-10-20, owner: "fix it"): JSONSerialization
        // prints a Double with 17 significant digits (0.69999999999999996);
        // an NSDecimalNumber made from Swift's shortest round-trip text
        // prints exactly that text (0.7) and parses back to the same Double.
        func f(_ x: Double) -> NSNumber { NSDecimalNumber(string: "\((x * 1e6).rounded() / 1e6)") }
        func cls(_ r: ClassRule) -> [String: Any] {
            var o: [String: Any] = [
                "threshold": f(Double(r.threshold)), "minBoxFraction": f(r.minBoxFraction),
                "minBoxPt": f(r.minBoxPt), "entryFrames": r.entryFrames,
            ]
            // THE DUMP RULE: `thresholdSteps` is emitted ONLY when non-empty.
            // Two reasons, both load-bearing: (1) at the defaults
            // `--print-tuning`, the `"event":"tuning"` record, a diagnostic
            // report's `app.tuning` and the Developer tab's Copy button stay
            // BYTE-IDENTICAL to the pre-staircase build, so the round-trip
            // selftests and the UI scripts pass unchanged; (2) a
            // tuning.json written by a newer build at default steps is
            // still accepted by an OLDER binary — `TuningFile.parse` refuses
            // the whole file on an unknown key, and builds get rolled back on
            // a test Mac.
            if !r.thresholdSteps.isEmpty {
                o["thresholdSteps"] = r.thresholdSteps.map {
                    ["minPt": f($0.minPt), "threshold": f(Double($0.threshold))]
                }
            }
            return o
        }
        var classes: [String: Any] = [:]
        for (label, r) in standard { classes[label] = cls(r) }
        for (label, r) in strict { classes[label] = cls(r) }
        var out: [String: Any] = [
            "classes": classes,
            "coveredBeatsExposed": coveredBeatsExposed,
            "coveredOverlap": f(coveredOverlap),
            "keepGap": f(keepGap),
            "settleRecheck": settleRecheck,
            "curtain": [
                "triggerHits": curtain.triggerHits, "windowSecs": f(curtain.windowSecs),
                "handoffHits": curtain.handoffHits, "paroleHits": curtain.paroleHits,
                "holdSecs": f(curtain.holdSecs), "holdCleanFrames": curtain.holdCleanFrames,
            ],
            "tracker": [
                "clearAfterSecs": f(tracker.clearAfterSecs), "stickyHoldSecs": f(tracker.stickyHoldSecs),
                "stickyConf": f(Double(tracker.stickyConf)), "matchIoU": f(tracker.matchIoU),
            ],
        ]
        // ALWAYS emitted since 2026-10-20, when `defaults` turned it on.
        // Until then this followed THE DUMP RULE (emitted only when on);
        // with an ON default that rule would write an OFF policy without the
        // key, and the file would load back ON (`parse` layers over
        // `defaults`): the Developer tab's off switch would not survive a
        // save. Every released public build (0.4.0 on) accepts the key.
        out["zoomTiles"] = zoomTiles
        return out
    }

    /// One-line JSON, keys sorted (the `tuning` event and `--print-tuning`).
    func jsonString(pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        let data = try! JSONSerialization.data(withJSONObject: jsonObject, options: options)
        return String(decoding: data, as: UTF8.self)
    }

    struct ParseError: Error, Equatable { let text: String }

    /// JSONSerialization hands back NSNumber for `true`, `1` and `0` alike;
    /// only a CFBoolean is a bool (same trap DevOverrides documents).
    static func isJSONBool(_ raw: Any) -> Bool {
        guard let n = raw as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Layer `obj` over `base`. Every key optional; an unknown key or a value
    /// outside its range fails by key and NOTHING is applied. RANGES ARE
    /// TRIPWIRES, set beyond the measured healthy span so a typo (a
    /// threshold of 5, a hold of 5000) fails at load instead of shipping:
    ///  - threshold, stickyConf, coveredOverlap: scores, 0…1 (overlap ≥ 0.5,
    ///    receipt at `coveredOverlap`);
    ///  - keepGap 0…0.25: at 0.25 the 0.5 explicit floors of 2026-09-25
    ///    (when the gap was added) had a keep floor (0.5 − 0.25) at the
    ///    detector floor `--conf` 0.25, below which no box ever arrives.
    ///    Since the 2026-10-20 floors (0.7–0.9) that is no longer the bound
    ///    a larger gap hits; the range is kept as a tripwire (a gap past a
    ///    quarter of the score scale is a typo, not a tuning);
    ///  - thresholdSteps: at most `ClassRule.maxSteps` = 4 entries (receipt
    ///    at the field: 2 boundaries meet the measured need, 4 is 2x it), each
    ///    `{minPt, threshold}` and nothing else, `minPt` STRICTLY INCREASING —
    ///    refused BY INDEX, never silently sorted, because a reader of the
    ///    file must see the brackets in the order they fire. `minPt` 1…2000:
    ///    the lower bound is 1 because a step at 0 restates `threshold`
    ///    (one number, two sources, and a dead `threshold` slider in the
    ///    Developer tab); the upper bound is 2000 pt, above the shorter side
    ///    in points of the largest display this ships to (Pro Display XDR
    ///    6016x3384 px = 3008x1692 pt; 5K iMac 2560x1440 pt), so a boundary
    ///    past it can NEVER fire and is certainly a typo. Deliberately NOT
    ///    minBoxPt's 0…200 — that cap is receipted as "3x the largest
    ///    measured false box", a floor argument, not a bracket argument
    ///    (MEASURED context: the 14,036 FEMALE_BREAST_EXPOSED boxes of the
    ///    owner's 2026-09-11 session run 13–181 pt on a 1920x1080-pt
    ///    screen — a bracket lives among the boxes, a floor under them). Step
    ///    `threshold` 0…1, the same range and receipt as the flat
    ///    `threshold`, and AT OR ABOVE the class's flat `threshold`: the flat
    ///    floor is applied first (`filter`), so a lower step can never fire
    ///    and is refused by name instead of accepted as a no-op;
    ///  - minBoxFraction 0…0.25 and minBoxPt 0…200: the largest measured
    ///    false-positive box is 68 px / 0.002 of the area (receipt at
    ///    `ClassRule.minBoxFraction`); a floor past a quarter of the display
    ///    or 200 pt (3x the largest FP) would be deleting real content;
    ///  - entryFrames 1…10: 10 frames is 333 ms at 30 fps, most of SPEC §6's
    ///    400 ms budget (`PerfTier.latencyBudgetMs`);
    ///  - triggerHits/handoffHits/paroleHits 1…30: 30 hits is every frame of
    ///    a full 1 s window at 30 fps (`windowSecs` default), i.e. "never
    ///    drop" — a bar above it cannot be met; the two lower bars ≤
    ///    triggerHits (they are lower-trust bars by definition, `Curtain`);
    ///    windowSecs 0.1…10: 0.1 s is 3 frames at 30 fps (the trigger's own
    ///    minimum), 10 s is 10x the receipted window — past it a window
    ///    remembers hits longer than the parole horizons care about;
    ///    holdSecs 0.5…60: 0.5 s is under every measured detector dropout
    ///    (2.5 s receipt), 60 s is 3x the longest measured capture gap
    ///    (18.7 s, `holdCleanFrames` receipt); holdCleanFrames 1…600 (600 =
    ///    20 s at 30 fps, well past every measured hold);
    ///  - clearAfterSecs 0…5, stickyHoldSecs 0…30 (the media hold is 5 s;
    ///    a sticky hold past 30 s is a frozen cover); matchIoU 0.05…0.95:
    ///    ASSUMED — below 0.05 any touching box matches, above 0.95 only a
    ///    near-identical one does, and both defeat the centre-distance
    ///    fallback's purpose (`Tracker.matches`).
    /// The first key of `d` that is not in `keys`, as a refusal. Type-level
    /// so `parse` and `parseSteps` cannot word a refusal differently.
    static func unknown(_ d: [String: Any], _ keys: Set<String>, _ at: String) -> ParseError? {
        guard let k = d.keys.sorted().first(where: { !keys.contains($0) }) else { return nil }
        return ParseError(text: "unknown key \"\(at)\(k)\" (known: \(keys.sorted().joined(separator: ", ")))")
    }

    /// A finite, non-bool number inside its tripwire range (see `parse`).
    static func number(_ d: [String: Any], _ key: String, _ at: String, _ lo: Double, _ hi: Double) throws -> Double? {
        guard let raw = d[key] else { return nil }
        guard !isJSONBool(raw), let n = (raw as? NSNumber)?.doubleValue, n.isFinite, n >= lo, n <= hi else {
            throw ParseError(text: "\"\(at)\(key)\" must be a number in \(lo)...\(hi) (got \(raw))")
        }
        return n
    }

    // MARK: thresholdSteps — ONE schema, shared by config.json, tuning.json
    // and the Developer tab. These four live here and not in the tuning-only
    // UI file on purpose: the schema must exist in a production binary's
    // parser, and in exactly one place, or the tab could write a file the
    // daemon then refuses.

    /// `thresholdSteps` from its JSON array form. Refuses BY INDEX and key;
    /// never sorts, never de-duplicates.
    static func parseSteps(_ raw: Any, base: Float, at: String) -> Result<[ClassRule.SizeStep], ParseError> {
        let notArray = ParseError(
            text: "\"\(at)thresholdSteps\" must be an array of {minPt, threshold} objects")
        guard let array = raw as? [Any] else { return .failure(notArray) }
        var steps: [ClassRule.SizeStep] = []
        for (i, entry) in array.enumerated() {
            guard let o = entry as? [String: Any] else { return .failure(notArray) }
            let at = "\(at)thresholdSteps[\(i)]."
            if let e = unknown(o, stepKeys, at) { return .failure(e) }
            do {
                guard let minPt = try number(o, "minPt", at, 1, 2000) else {
                    return .failure(ParseError(text: "\"\(at)minPt\" is required"))
                }
                guard let t = try number(o, "threshold", at, 0, 1) else {
                    return .failure(ParseError(text: "\"\(at)threshold\" is required"))
                }
                steps.append(ClassRule.SizeStep(minPt: minPt, threshold: Float(t)))
            } catch let e as ParseError {
                return .failure(e)
            } catch {
                return .failure(ParseError(text: "\(error)"))
            }
        }
        if let e = validateSteps(steps, base: base, at: at) { return .failure(e) }
        return .success(steps)
    }

    /// Count, ranges and order — the tripwires that hold however the steps
    /// were built (JSON array, the Developer tab's text field, or code).
    /// Receipts for each number are in the `parse` block comment.
    static func validateSteps(_ steps: [ClassRule.SizeStep], base: Float, at: String) -> ParseError? {
        let name = "\(at)thresholdSteps"
        if steps.count > ClassRule.maxSteps {
            return ParseError(
                text: "\"\(name)\" has \(steps.count) entries, at most \(ClassRule.maxSteps) "
                    + "(TuningPolicy.ClassRule.maxSteps)")
        }
        for (i, s) in steps.enumerated() {
            guard s.minPt.isFinite, s.minPt >= 1, s.minPt <= 2000 else {
                return ParseError(text: "\"\(name)[\(i)].minPt\" must be a number in 1.0...2000.0 (got \(s.minPt))")
            }
            guard s.threshold.isFinite, s.threshold >= 0, s.threshold <= 1 else {
                return ParseError(text: "\"\(name)[\(i)].threshold\" must be a number in 0.0...1.0 (got \(s.threshold))")
            }
            if s.threshold < base {
                return ParseError(
                    text: "\"\(name)[\(i)].threshold\" \(String(format: "%.2f", Double(s.threshold))) is below the class "
                        + "threshold \(String(format: "%.2f", Double(base))) (a step can only raise the floor: the flat "
                        + "threshold is applied first)")
            }
            if i > 0, s.minPt <= steps[i - 1].minPt {
                return ParseError(
                    text: "\"\(name)[\(i)].minPt\" \(stepPtText(s.minPt)) must be greater than "
                        + "[\(i - 1)].minPt \(stepPtText(steps[i - 1].minPt)) (steps must be in increasing order)")
            }
        }
        return nil
    }

    /// `64` for a whole number of points, `64.5` otherwise.
    static func stepPtText(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%g", v)
    }

    /// The canonical one-line text form, `"48:0.80, 96:0.90"` (empty = no
    /// staircase). The Developer tab's field renders and the UI scripts
    /// assert exactly this.
    static func stepsText(_ steps: [ClassRule.SizeStep]) -> String {
        steps.map { "\(stepPtText($0.minPt)):\(String(format: "%.2f", Double($0.threshold)))" }
            .joined(separator: ", ")
    }

    /// The inverse of `stepsText`, for the Developer tab's field. Same
    /// tripwires as the JSON form — one validator, so the tab can never
    /// write a file the daemon would refuse.
    static func parseStepsText(_ text: String, base: Float, at: String) -> Result<[ClassRule.SizeStep], ParseError> {
        let name = "\(at)thresholdSteps"
        let body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return .success([]) }
        var steps: [ClassRule.SizeStep] = []
        // Empty pieces are kept so `"64:0.9,"` and `","` are refused by
        // index like the JSON form, never silently dropped or cleared.
        for (i, piece) in body.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            let parts = piece.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                let minPt = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                let t = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                minPt.isFinite, t.isFinite
            else {
                return .failure(ParseError(
                    text: "\"\(name)[\(i)]\" must be \"minPt:threshold\" (got \"\(piece.trimmingCharacters(in: .whitespaces))\"); "
                        + "the whole field is e.g. \"48:0.80, 96:0.90\", empty for none"))
            }
            steps.append(ClassRule.SizeStep(minPt: minPt, threshold: Float(t)))
        }
        if let e = validateSteps(steps, base: base, at: at) { return .failure(e) }
        return .success(steps)
    }

    static func parse(_ obj: [String: Any], base: TuningPolicy) -> Result<TuningPolicy, ParseError> {
        func integer(_ d: [String: Any], _ key: String, _ at: String, _ lo: Int, _ hi: Int) throws -> Int? {
            guard let raw = d[key] else { return nil }
            // An integral NSNumber, whichever numeric type the decoder chose.
            guard !isJSONBool(raw), let x = (raw as? NSNumber)?.doubleValue, x == x.rounded(),
                let n = Int(exactly: x), n >= lo, n <= hi
            else {
                throw ParseError(text: "\"\(at)\(key)\" must be an integer in \(lo)...\(hi) (got \(raw))")
            }
            return n
        }
        func object(_ d: [String: Any], _ key: String, _ keys: Set<String>) throws -> [String: Any] {
            guard let raw = d[key] else { return [:] }
            guard let o = raw as? [String: Any] else { throw ParseError(text: "\"\(key)\" must be an object") }
            if let e = unknown(o, keys, key + ".") { throw e }
            return o
        }
        if let e = unknown(obj, topKeys, "") { return .failure(e) }
        var p = base
        do {
            let classes = try object(obj, "classes", Set(exposedLabels + coveredLabels))
            for (label, raw) in classes {
                guard let o = raw as? [String: Any] else {
                    return .failure(ParseError(text: "\"classes.\(label)\" must be an object"))
                }
                if let e = unknown(o, classKeys, "classes.\(label).") { return .failure(e) }
                let at = "classes.\(label)."
                var r = p.rule(for: label)!
                if let v = try number(o, "threshold", at, 0, 1) { r.threshold = Float(v) }
                // The ARRAY REPLACES the whole list (arrays never merge per
                // index); `[]` clears the staircase. Everything else here
                // stays field by field.
                if let raw = o["thresholdSteps"] {
                    switch parseSteps(raw, base: r.threshold, at: at) {
                    case let .success(steps): r.thresholdSteps = steps
                    case let .failure(e): return .failure(e)
                    }
                } else if let e = validateSteps(r.thresholdSteps, base: r.threshold, at: at) {
                    // A raised `threshold` layered over inherited steps must
                    // not leave a step below the base.
                    return .failure(e)
                }
                if let v = try number(o, "minBoxFraction", at, 0, 0.25) { r.minBoxFraction = v }
                if let v = try number(o, "minBoxPt", at, 0, 200) { r.minBoxPt = v }
                if let v = try integer(o, "entryFrames", at, 1, 10) { r.entryFrames = v }
                if p.standard[label] != nil { p.standard[label] = r } else { p.strict[label] = r }
            }
            if let raw = obj["coveredBeatsExposed"] {
                guard isJSONBool(raw), let b = raw as? Bool else {
                    return .failure(ParseError(text: "\"coveredBeatsExposed\" must be true or false (got \(raw))"))
                }
                p.coveredBeatsExposed = b
            }
            if let v = try number(obj, "coveredOverlap", "", 0.5, 1) { p.coveredOverlap = v }
            if let v = try number(obj, "keepGap", "", 0, 0.25) { p.keepGap = v }
            if let raw = obj["settleRecheck"] {
                guard isJSONBool(raw), let b = raw as? Bool else {
                    return .failure(ParseError(text: "\"settleRecheck\" must be true or false (got \(raw))"))
                }
                p.settleRecheck = b
            }
            if let raw = obj["zoomTiles"] {
                guard isJSONBool(raw), let b = raw as? Bool else {
                    return .failure(ParseError(text: "\"zoomTiles\" must be true or false (got \(raw))"))
                }
                p.zoomTiles = b
            }
            let c = try object(obj, "curtain", curtainKeys)
            if let v = try integer(c, "triggerHits", "curtain.", 1, 30) { p.curtain.triggerHits = v }
            if let v = try number(c, "windowSecs", "curtain.", 0.1, 10) { p.curtain.windowSecs = v }
            if let v = try integer(c, "handoffHits", "curtain.", 1, 30) { p.curtain.handoffHits = v }
            if let v = try integer(c, "paroleHits", "curtain.", 1, 30) { p.curtain.paroleHits = v }
            if let v = try number(c, "holdSecs", "curtain.", 0.5, 60) { p.curtain.holdSecs = v }
            if let v = try integer(c, "holdCleanFrames", "curtain.", 1, 600) { p.curtain.holdCleanFrames = v }
            for (name, v) in [("handoffHits", p.curtain.handoffHits), ("paroleHits", p.curtain.paroleHits)]
            where v > p.curtain.triggerHits {
                return .failure(ParseError(text: "\"curtain.\(name)\" \(v) must not exceed curtain.triggerHits \(p.curtain.triggerHits)"))
            }
            let t = try object(obj, "tracker", trackerKeys)
            if let v = try number(t, "clearAfterSecs", "tracker.", 0, 5) { p.tracker.clearAfterSecs = v }
            if let v = try number(t, "stickyHoldSecs", "tracker.", 0, 30) { p.tracker.stickyHoldSecs = v }
            if let v = try number(t, "stickyConf", "tracker.", 0, 1) { p.tracker.stickyConf = Float(v) }
            if let v = try number(t, "matchIoU", "tracker.", 0.05, 0.95) { p.tracker.matchIoU = v }
        } catch let e as ParseError {
            return .failure(e)
        } catch {
            return .failure(ParseError(text: "\(error)"))
        }
        return .success(p)
    }
}

/// TUNING TOOL: `<state>/parent/tuning.json`, hot-reloaded. The file is
/// `{ "version": 1, "tuning": { …the config.json schema… } }`, layered over
/// the config-derived policy.
/// `parent/` is root:admin 2770 on an install, so a
/// Standard (child) session cannot read it and sees "absent".
enum TuningFile {
    static let fileName = "parent/tuning.json"
    static let version = 1
    typealias Signature = (ino: UInt64, sec: Int, nsec: Int, size: Int64)

    /// (ino, mtime, size) — nil when absent or unreadable.
    static func signature(stateRoot: String) -> Signature? {
        var st = stat()
        guard stat(stateRoot + "/" + fileName, &st) == 0 else { return nil }
        return (UInt64(st.st_ino), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec, Int64(st.st_size))
    }

    static func sameSignature(_ a: Signature?, _ b: Signature?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.ino == y.ino && x.sec == y.sec && x.nsec == y.nsec && x.size == y.size
        default: return false
        }
    }

    enum Outcome: Equatable {
        case absent
        case refused(String)
        case loaded(TuningPolicy)
    }

    static func read(stateRoot: String, base: TuningPolicy) -> Outcome {
        let path = stateRoot + "/" + fileName
        guard let data = FileManager.default.contents(atPath: path) else { return .absent }
        switch parse(data, base: base) {
        case let .success(p): return .loaded(p)
        case let .failure(why): return .refused("\(path): \(why.text)")
        }
    }

    static func parse(_ data: Data, base: TuningPolicy) -> Result<TuningPolicy, TuningPolicy.ParseError> {
        guard let any = try? JSONSerialization.jsonObject(with: data), let obj = any as? [String: Any] else {
            return .failure(TuningPolicy.ParseError(text: "not a JSON object"))
        }
        guard let v = obj["version"], !TuningPolicy.isJSONBool(v), v as? Int == version else {
            return .failure(TuningPolicy.ParseError(text: "version must be \(version) (got \(obj["version"] ?? "absent"))"))
        }
        if let k = obj.keys.sorted().first(where: { $0 != "version" && $0 != "tuning" }) {
            return .failure(TuningPolicy.ParseError(text: "unknown key \"\(k)\" (known: tuning, version)"))
        }
        guard let body = obj["tuning"] as? [String: Any] else {
            return .failure(TuningPolicy.ParseError(text: "\"tuning\" must be an object"))
        }
        return TuningPolicy.parse(body, base: base)
    }
}
