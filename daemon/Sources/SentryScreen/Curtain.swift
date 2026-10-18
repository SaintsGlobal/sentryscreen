import CoreGraphics
import Foundation

/// Curtain mode (`--cover curtain`, owner-named 2026-08-19).
///
/// When one OS window keeps producing blocked detections, drop ONE solid
/// cover over that window's content area, anchored to the window's
/// OS-reported frame instead of to pixel tracking. The window's top chrome
/// strip stays visible so the user can see back / address bar / close
/// controls (clicks pass through every overlay regardless — SPEC §8).
///
/// DELIBERATELY A SEPARATE PIPELINE (owner directive, 2026-08-19): this
/// class consumes the same blocked detections and the same WindowTracker the
/// existing paths use, but shares no state with Tracker, MotionBoxes, or
/// CoverOwnership, and is constructed only when `--cover curtain` is set.
/// Region covers still paint underneath as the first response — since
/// 2026-09-02 on the second consecutive detector frame, so a single-frame
/// false positive paints nothing (receipt at `Tracker.curtainEntryFrames`);
/// the curtain is the escalation.
///
/// The full-coverage tripwire (SPEC §8.1(2)) intentionally does not count
/// curtains, and its release leaves them up: a curtain is bounded by one
/// window's frame by construction (the transition shield is the bounded,
/// logged exception).
final class Curtain {
    /// Hits inside `windowSecs` needed to drop the curtain. Basis: the live
    /// strict run (daemon/testdata/livestrict-bing-2026-08-19.jsonl) shows on-screen
    /// flagged content producing 20+ blocked detections/s, while a
    /// single-frame false positive produces 1-2 hits. Was 5 (4x separation);
    /// 3 keeps a 1.5x margin over the worst single-frame FP and takes two
    /// detector frames off the curtain's arrival. MEASURED 2026-08-25 (A/B
    /// rig, benign faces + --block-faces, region paint as the reference):
    /// with 5 the curtain painted ~200 ms after the region cover (curtain
    /// 349-417 ms from content-shown vs region 143-160); the region cover
    /// is already on glass for that whole interval, so the curtain's extra
    /// hits buy FP margin on the whole-window paint only. Owner QA
    /// 2026-08-25 called the curtain arrival slow; the 3-day soak recorded
    /// no false curtain at 5 to calibrate against, so re-receipt from the
    /// first soak at 3 (health_report: curtain drops with no flagged frames).
    /// SINCE 2026-09-10 the six evidence-bar / hold numbers below are
    /// `TuningPolicy.CurtainRules` (config.json `tuning.curtain`,
    /// tuning.json), read per update from `tuning`; the receipts moved with
    /// them. These statics are the DEFAULT-tuning aliases for tests and
    /// `PerfTier.selftest`, which reason about the shipped defaults.
    static var triggerHits: Int { TuningPolicy.defaults.curtain.triggerHits }
    static var windowSecs: CFTimeInterval { TuningPolicy.defaults.curtain.windowSecs }
    /// The tuning in force — a value copy swapped whole by the pipeline on
    /// detectQueue (`Pipeline.setTuning`), the queue `update` runs on.
    var tuning = TuningPolicy.defaults
    /// TUNING TOOL (DetectionTrace.swift): the Detection view's per-update
    /// decision record. nil unless the view is on; attached and detached by
    /// `Pipeline.setDetectionTrace` on detectQueue, the queue `update` runs on.
    var traceRecorder: CurtainTraceRecorder?
    /// Lift after this long with no blocked detection inside the window.
    /// Mirrors mediaHoldSecs: measured 2.5 s detector dropouts inside
    /// playing content, 2x margin (receipt at Options.mediaHoldSecs).
    static var holdSecs: CFTimeInterval { TuningPolicy.defaults.curtain.holdSecs }
    /// A hold lift also needs this many detector-evaluated clean frames.
    /// MEASURED 2026-08-26: a static screen left 18.7 s between capture
    /// frames, and thin evidence let wall time lift a curtain before the
    /// detector proved the content was clean. DERIVED: 20 is two thirds of
    /// the 30 frames that a starved 6 fps stream produces in holdSecs. A
    /// frame-less geometry tick never increments this counter.
    ///
    /// DELIBERATELY NOT fps-DERIVED (audited 2026-09-02 for the performance
    /// tiers, PerfTier.swift — this is the one member of the fps landmine list
    /// that stays a fixed frame count). It is not a duration in disguise: the
    /// receipt above reasons about a STARVED stream (2/3 of the 30 frames a
    /// 6 fps stream produces in `holdSecs`), which is a property of capture
    /// starvation, not of the configured frame rate. Deriving it from the
    /// configured fps would make it demand MORE evidence on the machines
    /// least able to produce it.
    /// TWO TIME SCALES, do not confuse them (2026-09-02): the
    /// receipt above sizes 20 against a STARVED stream, where 20 frames span
    /// ~3.3 s — that is the span it is protecting against. The tier arithmetic
    /// below is the HEALTHY case, where 20 frames arrive far faster. A reader
    /// who takes 0.67 s as what the receipt sizes against will conclude the
    /// constant is 5x too small; it is not.
    /// Tier effect, so it is written down rather than assumed: at a healthy
    /// frame rate 20 frames is 0.67 s at 30 fps and 1.33 s at the no-ane
    /// tier's 15 fps, both well inside `holdSecs` = 5.0 s — so at every shipped tier wall time is still
    /// the binding constraint on a lift and this counter is only the evidence
    /// floor it was written to be. It would not bind until below 4 fps, which
    /// is under `PerfTier.fpsFloor`. Asserted per tier in `PerfTier.selftest`.
    ///
    /// IT DOES BIND LIVE — RE-RECEIPTED 2026-09-09 (owner: "try it and see").
    /// MEASURED on a test Mac's installed agent:
    /// the
    /// tier arithmetic above is about the CONFIGURED rate, but the EVALUATED
    /// rate on a static desktop is what the capture delivers, and
    /// ScreenCaptureKit delivers ~2 fps when nothing changes — whole-minute
    /// `summary` records read fps 1.9 / 1.9 / 2.0 / 2.1 / 2.1 / 2.0 with one
    /// or two curtains up, and per-second evaluated-frame counts inside the
    /// two hold episodes ran 1-30. Two lifts landed at EXACTLY the floor —
    /// `lift (hold 5.0s, 20 clean frames)` at 06:56:17Z and 06:59:32Z — i.e.
    /// wall time had long passed and the 20th frame was the trigger. So the
    /// sentence "would not bind until below 4 fps" is true of the configured
    /// rate and FALSE of the rate that counts: the floor binds routinely, and
    /// at ~2 fps a benign hold lift takes 20/2 = 10 s, not 5 s. Both bound
    /// lifts followed an `evaluated-frame gap 2.1/2.2 s` capture stall, the
    /// starved-stream case the value was sized for.
    /// VALUE KEPT AT 20, deliberately: the cost of binding is up to ~5 s
    /// more over-cover of a window whose content turned benign (fail-safe
    /// direction), and the benefit is unchanged — 20 evaluated frames are
    /// 20 detector verdicts whatever the wall clock says, which is the
    /// evidence the 2026-08-26 static-screen lift lacked. Lowering it trades
    /// that evidence for lift speed on benign windows only; measure a
    /// household soak's `lift (hold …, 20 clean frames)` share and the
    /// re-drop rate that follows before doing so. The per-tier assertion
    /// above still holds for the configured rate and is not evidence about
    /// this regime.
    static var holdCleanFrames: Int { TuningPolicy.defaults.curtain.holdCleanFrames }
    /// Top strip of a curtained window left visible, in points, so the user
    /// can see back / address bar / close (owner requirement). History:
    /// 2026-08-19 Chrome toolbar measured ≈ 87 pt ⇒ 96 "with margin",
    /// superseded by the measurement below. MEASURED TRADE (drag test
    /// 2026-08-19): a window with less chrome — an `--app` window's ~28 pt
    /// title bar — shows (strip − chrome) pt of content through the cutout;
    /// region covers backstop it. `--curtain-strip` overrides (0 = cover the
    /// whole window; clicks pass through anyway).
    /// Was 96. MEASURED 2026-08-26 (an M1 Mac, luminance-row probe on a
    /// 1410x829 Chrome window): tab strip + toolbar end ~100 pt below the
    /// window top, bookmarks bar to ~139. OWNER (a Standard test account, no
    /// bookmarks bar): at 96 a band of page content showed under the
    /// toolbar. 80 keeps back / address bar / close visible and puts the
    /// curtain edge inside the toolbar's bottom ~20 pt on every Chrome
    /// layout seen. DERIVED consequence: `contentRect`'s
    /// `height > 2 * chromeStripPt` bail moves with the constant
    /// (192 → 160 pt), so windows 160–192 pt tall are now strip-cut instead
    /// of covered whole; region covers backstop that band exactly as they
    /// do for any window shorter than the bail.
    ///
    /// SOURCE DEFAULT, immutable — this is what `--ui-selftest` asserts.
    /// `chromeStripPt` below is a `var` that `--curtain-strip` and config
    /// `curtainStrip` have ALREADY applied to by the time the selftest runs
    /// (main.swift: config at ~263, flag loop at ~344, both before the
    /// `opts.uiSelfTest` dispatch at ~2016), so asserting the var would only
    /// assert the operator's override.
    static let defaultChromeStripPt: CGFloat = 80

    /// The live strip. Overridable by `--curtain-strip` / config
    /// `curtainStrip` (both validated 0-200 in main.swift); receipt for the
    /// value is the `defaultChromeStripPt` block above.
    static var chromeStripPt: CGFloat = defaultChromeStripPt

    /// Loud on every drop, lift, and budget event: a whole-window cover is a
    /// visible behavior change and must be explainable from the run's own
    /// output. Budget events use window id 0.
    var onChange: ((String, CGWindowID) -> Void)?
    /// DEV crop observer. Hit-driven `drop`, `drop (parole)`, and
    /// `drop (handoff)` actions call it. The source-index list can be empty
    /// when a drop is decided on a tick that did not run an ownership walk;
    /// the observer then uses the current window rect as attribution.
    /// Geometry-only parole-return drops have no detector frame and do not
    /// call it. The frame is the window rect used by the drop decision, and
    /// source indices refer to this update's `blockedScreenRects`.
    var onDrop: ((String, CGWindowID, CGRect?, [Int]) -> Void)?
    /// DEV crop contract failures use their own named log event.
    var onCropEvent: ((String) -> Void)?

    /// Attribution walk cadence, in update() calls. Receipt: a full
    /// CGWindowList snapshot is 1.2-1.4 ms (Pipeline.ownershipResolveEvery);
    /// every 3rd frame = ~10 Hz, which the trigger tolerates. (The wording was
    /// "the 5-in-1s trigger" until 2026-09-08: `triggerHits` has been 3, not 5,
    /// since 2026-08-25 — the arithmetic below already used 3 and only this
    /// sentence was stale.)
    ///
    /// THE TENTH fps-DERIVED CONSTANT, found 2026-09-02
    /// after the other nine were restated (PerfTier.swift). The receipt reasons
    /// in Hz — "~10 Hz, which the trigger tolerates" — but the constant was a
    /// fixed frame count, so at the no-ane tier's 15 fps it would have walked at
    /// 5 Hz. This gates the walk that ATTRIBUTES hits, so it also caps how many
    /// hits a second can be earned: against `triggerHits` = 3 in `windowSecs` =
    /// 1.0 s the margin would have fallen from 3.3x to 1.67x — not broken, but
    /// quietly halved on the machines with the least headroom, which is exactly
    /// the failure mode this whole change exists to stop.
    /// Derived from the rate instead: 3 at 30 fps (unchanged, exact integer
    /// division), 1 at 15 fps. The cost at 15 fps is walking every frame —
    /// 1.2-1.4 ms x 15/s ≈ 2% of one core, against the same budget that already
    /// prices the walk at 30 fps. `PerfTier.selftest` asserts the trigger margin
    /// per tier rather than trusting this comment.
    ///
    /// FLOOR OF 2, not 1 (2026-09-02). At `walkEvery == 1` the
    /// `tick % walkEvery == 0` test is always true, so the walk runs every
    /// frame whatever `wantBypass` says — and `bypassBudgetSecs`, whose entire
    /// job is to fall back to this cadence and bound the ~4%-of-one-core
    /// full-rate walk, would log "reverting to 1/1 cadence": a limit announcing
    /// a remediation it cannot perform. 2 keeps the fallback real at every
    /// tier. Cost at 15 fps is a 7.5 Hz walk instead of 10 Hz, which still
    /// clears `triggerHits`/`windowSecs` by 2.5x (asserted in
    /// `PerfTier.selftest`).
    static let walkHz = 10.0
    static let walkEveryFloor = 2
    static func walkEvery(fps: Int) -> Int {
        max(walkEveryFloor, fps / Int(walkHz))
    }
    /// Set once by `Pipeline` from the effective fps, before the first update.
    /// The default is the 30 fps value, so a path that never sets it behaves
    /// exactly as this class did before tiers existed.
    var walkEvery = Curtain.walkEvery(fps: 30)
    /// The configured detector rate, set by `Pipeline` next to `walkEvery`.
    /// Only `windowFrames` reads it.
    var fps = 30
    /// HIT RETENTION IN EVALUATED FRAMES. A hit stays trigger evidence while
    /// it is inside `windowSecs` of wall clock OR inside `windowSecs` worth
    /// of evaluated frames at the configured rate (30 at 30 fps / 1.0 s).
    /// The two arms agree at full cadence; the frame arm exists for
    /// capture starvation. Receipt:
    /// ScreenCaptureKit delivers a static screen at ~1
    /// frame/s (owner session 08:21:15–19Z: five consecutive seconds of one
    /// evaluated frame each, blocked boxes on every one), and `triggerHits`
    /// = 3 evaluated frames cannot fit inside a 1.0 s wall-clock window at
    /// ≤ 2 frames/s — with the wall-clock arm alone a static explicit page
    /// that arrives with no repaint never earns a curtain, whatever the
    /// tuning says (`--ui-selftest` "curtain: static cadence"). The
    /// evidence bar is unchanged: `triggerHits` DISTINCT evaluated frames,
    /// which is what the 2026-08-19 receipt at `triggerHits` counts (20+
    /// hits/s of content vs 1–2 for a single-frame false positive); the
    /// frame arm only stops the clock from expiring frames the detector
    /// never had. Bounded like the wall-clock arm: three hits 31 evaluated
    /// frames apart never accumulate.
    func windowFrames() -> Int {
        max(1, Int((tuning.curtain.windowSecs * Double(fps)).rounded()))
    }
    /// Continuous full-rate walking longer than this trips the budget: fall
    /// back to walkEvery and say so once (review 2026-08-20, P2: the orphan
    /// bypass self-latches on persistent unattributable content, e.g.
    /// desktop-level detections — ~4% of one core with no bound). 5 s covers
    /// every measured transition; persistence beyond it is steady state.
    static let bypassBudgetSecs: CFTimeInterval = 5.0
    private var tick = 0
    private var bypassSince: CFAbsoluteTime?
    private var bypassMuted = false

    /// A curtained window must stay DEAD (per WindowTracker.isDead) this
    /// long before its curtain lifts. Receipts: fullscreen transitions
    /// passed the 25 ms ring debounce repeatedly (six flaps in 5 s,
    /// user-test2 log); the RESTORE transition exceeded 0.75 s (fs-h3
    /// lift+re-drop pair). Cost: a really-closed window's curtain floats up
    /// to 1.5 s — and its dead lift then LINGERS another curtainLingerSecs,
    /// so the total black-rectangle time over whatever is behind a closed
    /// window is deadLiftSecs + curtainLingerSecs = 3.0 s (both receipted
    /// budgets; over-cover, fail-safe). While unlisted the paint falls
    /// back to the last known frame.
    static let deadLiftSecs: CFTimeInterval = 1.5
    private var deadSince: [CGWindowID: CFAbsoluteTime] = [:]
    /// The tracker's verdict for each dead-pending curtain, kept so the
    /// classification is announced once per episode, not per tick.
    private var deadKinds: [CGWindowID: WindowTracker.DeadKind] = [:]

    /// TWO DEAD SHAPES since 2026-09-09 (receipt at `WindowTracker.DeadKind`):
    /// `deadLiftSecs` above is the OFFSTAGE ceiling — the id is unpollable but
    /// an `.optionAll` snapshot still lists it, which is what a fullscreen
    /// exit looks like for 0.57 s, and that path is unchanged: wall clock
    /// only, because a transition's frames are animating and a clean-frame
    /// lift there would re-open the fs-h3 lift/re-drop flap. This is the
    /// DESTROYED ceiling — unpollable AND absent from `.optionAll`, which the
    /// probe saw only for a real close and never saw come back. A destroyed
    /// curtain lifts on EVIDENCE first (`lingerCleanFrames` evaluated frames
    /// with no blocked detection inside its rect ⇒ "lift (closed, N clean
    /// frames)", no linger) and on this wall clock only when the frames keep
    /// showing blocked content where the window was — i.e. a close revealed
    /// explicit content behind it, and the cover is over-cover, fail-safe,
    /// until the successor's own drop (handoff at 2 hits: the dead-pending
    /// curtain is in transition). Value: EQUAL to `deadLiftSecs` on purpose —
    /// the probe (n=1 close, plus the 45 000-poll probe's zero resurrections)
    /// says nothing resurrects, so this number prices only over-cover of
    /// content behind a close, and the 3.0 s worst case
    /// (destroyedLiftSecs + curtainLingerSecs) a test Mac measured close at
    /// (3.19-4.02 s last paint, CLOSE_LIFT_S receipt) is kept as the ceiling
    /// the owner asked to keep. Lower it only with a live measurement of a
    /// close over explicit content; a separate name so that measurement does
    /// not touch the offstage path.
    static let destroyedLiftSecs: CFTimeInterval = 1.5
    /// Consecutive EVALUATED frames with no blocked detection intersecting a
    /// departed window's rect that end a destroyed dead-lift or a linger
    /// early. Geometry ticks never count; a `gapGuardSecs` re-stamp resets
    /// it, so a capture outage cannot become a fast lift.
    /// DERIVED 2026-09-09: 2 = the same bar `Tracker.curtainEntryFrames` puts
    /// on a region's FIRST paint — one frame is a single-frame detector
    /// event in either direction. Wall time at a test Mac's evaluated rates:
    /// 130-260 ms at the shielded suite's 7.7-15.3 fps; on a static desktop
    /// the capture itself idles to ~2 fps (MEASURED on the installed agent,
    /// receipt at `holdCleanFrames`), so a close there ends ~1 s after the
    /// window is gone instead of the 3.0 s ceiling. COST, named: the region
    /// tracker's own receipt (`Tracker.defaultClearAfter`) says healthy
    /// detector miss-gaps reach several frames, so a 2-frame miss over
    /// explicit content revealed by a close ends the linger early; the
    /// revealed window's region covers (2 consecutive frames) and its
    /// handoff curtain (2 hits) are the backstop, and the exposure tripwire
    /// counts whatever slips through.
    /// MEASURED on a test Mac 2026-09-09:
    /// a benign close is off glass in
    /// 0.213-0.239 s of last curtain paint at 11.0-11.6 evaluated fps, down
    /// from 3.37-3.42 s on the same machine and harness with the pre-change
    /// binary — so the 130-260 ms estimate above holds and CLOSE_LIFT_S was
    /// re-receipted 4.5 → 1.0 s from these runs.
    /// THE BACKSTOP IS NOT AIRTIGHT — MEASURED, not a worry: in the shielded
    /// `restore_late` reveal leg (a display-scale predecessor CLOSES over a
    /// successor that is showing explicit content) the departed rect read
    /// clean for the 2 frames the detector needed to re-acquire the
    /// successor, the curtain lifted at ~0.2 s, and the successor's own
    /// `drop (handoff restore)` did not land until +0.317-0.338 s, leaving
    /// 2 / 0 / 1 blocking detector frames (n=3, 0-0.14 s at 14.1-14.6 fps)
    /// with NO cover of any kind, against 0/0 in 4/4 runs before this change.
    /// The two runs whose predecessor took the linger path read 0. The
    /// shielded band does not gate that counter, so it is reported and not a
    /// verdict; it is an open owner decision, not an accepted cost.
    static let lingerCleanFrames = 2
    /// Clean evaluated frames over each dead-pending curtain's rect.
    private var deadClean: [CGWindowID: Int] = [:]

    /// SUCCESSOR LINGER (owner decision 2026-09-09, after the measured
    /// `restore_late` regression recorded at `lingerCleanFrames`). A destroyed
    /// window's rect can be empty desktop — nothing to cover, lift now — or it
    /// can have another window behind it that the close just REVEALED, and
    /// that window's content has not been looked at yet. The two cases are
    /// distinguishable without a timer: ask the WindowServer whether any
    /// listed layer-0 window overlaps the departed rect at the moment of the
    /// lift decision (`WindowTracker.contentWindowIDs(intersecting:)`). None ⇒
    /// `lift (closed, N clean frames)`, unchanged. One or more ⇒ hold the
    /// departed rect until the FIRST of three signals, never a fixed wait:
    ///   1. the successor gets its own curtain (any drop on that id) — the
    ///      cover it needs now exists, so ours is redundant;
    ///   2. the successor has actually been LOOKED AT — one evaluated frame
    ///      after entry, which is the frame that first carries its pixels —
    ///      and the rect then reads clean for `lingerCleanFrames` more
    ///      consecutive evaluated frames;
    ///   3. `successorLingerSecs`, the ceiling.
    /// This is the whole fix for the measured 2 / 0 / 1 exposed frames: the
    /// gap was the detector needing a frame or two to re-acquire the revealed
    /// window while nothing covered it, and signal 2 is exactly "do not lift
    /// on frames that predate looking at it".
    ///
    /// Only the FRONTMOST overlapping id is remembered for signal 1, and that
    /// is deliberate: a window behind the frontmost shows no pixels in that
    /// rect, so its curtain would say nothing about what is visible there. A
    /// rect split between two windows front-to-back is a KNOWN BOUND — signal
    /// 1 then waits for the frontmost only, and signals 2 and 3 still bound
    /// the hold. It has never been observed; the shielded `restore_late`
    /// reveal is one successor.
    private var successorLinger: [CGWindowID: (
        frame: CGRect, successor: CGWindowID, until: CFAbsoluteTime,
        seen: Bool, clean: Int)] = [:]

    /// Ceiling for the successor linger — a bound, never a wait: every run
    /// below left on signal 1 or 2 well inside it.
    /// MEASURED 2026-09-09 on a test Mac: the revealed successor's own
    /// `drop (handoff restore)` landed at 0.317 / 0.336 / 0.338 / 0.368 /
    /// 0.387 s after the reveal mark.
    /// Ceiling =
    /// that worst case 0.387 s + one detector frame at a test Mac's measured
    /// 14.1-14.6 evaluated fps (0.071 s) = 0.458 s, rounded up to 0.5 s. So a
    /// successor that is going to be curtained at all is curtained before this
    /// fires, and a benign one costs at most half a second of over-cover on a
    /// rect the user just closed a window out of.
    /// A `gapGuardSecs` capture outage resets signals 1 and 2's evidence but
    /// NOT this clock, on purpose: with no frames arriving there is nothing to
    /// re-earn a lift with, and a stalled capture must not be able to hold a
    /// black rect for longer than a window with healthy frames could.
    static let successorLingerSecs: CFTimeInterval = 0.5
    /// When each active curtain dropped — the transient rule's clock — and
    /// which active curtains rode the contain-arm handoff, the only drops
    /// the rule applies to (receipt at the rule).
    private var dropAt: [CGWindowID: CFAbsoluteTime] = [:]
    private var handoffDrops: Set<CGWindowID> = []
    /// Transient lifts inside `ghostWindowSecs`, for the churn counter event.
    private var transientLifts: [CFAbsoluteTime] = []

    /// How long a miss streak must last to count as "currently unlisted".
    /// 50 ms — well past one dropped poll, well inside the ~0.5 s transition
    /// animation. NOTE (review 2026-08-20 P1): `latestFrame == nil` alone
    /// means "never polled this episode", not "unlisted now" — the ring keeps
    /// its last sample through misses by design. The miss streak is the true
    /// signal; both are checked.
    ///
    /// WALL CLOCK since 2026-09-11: this was
    /// `unlistedPolls = 6`, receipted as "50 ms at 120 Hz", on a poll loop
    /// MEASURED at 33.6-40.5 Hz on a test Mac — so the real threshold was
    /// ~176 ms, 3.4x what this receipt claimed. `WindowTracker.missSeconds`
    /// keeps the 50 ms (and keeps the one-dropped-poll floor explicitly; the
    /// whole argument is at `WindowTracker.deadSecs`).
    ///
    /// WHICH WAY THAT MOVED THE PRODUCT (review 2026-09-11): earlier, for every
    /// consumer. Two are visible on the glass — the transition SHIELD (a
    /// deliberate full-display black blink) and `inheritsTrust` (the contain and
    /// restore handoff arms, which drop a successor at `handoffHits` instead of
    /// `triggerHits`) — so restoring the receipt's own 50 ms means MORE blinks
    /// and EARLIER inheritance than yesterday's build, in the FP territory the
    /// owner is tuning by hand. DERIVED from the cadence, never observed: the
    /// 13-fixture gate builds no `Curtain`, so only a live or shielded session
    /// can price it.
    static let unlistedSecs: CFTimeInterval = 0.05

    /// Minimum window size a curtain will cover. Receipt (owner two-window
    /// session 2026-08-20): Stage Manager relegated the curtained window to
    /// a ~92x129 pt strip thumbnail, and ~100x110 pt WindowManager strip
    /// overlays then passed the containment handoff against that tiny
    /// curtain — a minute of drop/lift churn on window ids 185/211/98.
    /// Thumbnail-scale content is region-cover territory (the painted
    /// minimum keeps those visible); real content windows are far larger.
    /// Sub-floor windows accumulate no hits, and an active curtain whose
    /// window shrinks below the floor lifts (hysteresis receipt at
    /// subFloorLiftSecs).
    ///
    /// CORRECTED 2026-08-28 — the lift is NOT a handoff onto region covers
    /// that are already on glass. Since region suppression landed (receipt at
    /// `Pipeline.regionInput`) the blocked detections centred in the curtain's
    /// painted rect are withheld from the region tracker, so the layers under
    /// it age out while the curtain is up: non-sticky after `clearAfter`
    /// (Tracker.defaultClearAfter — 12 frames = 0.4 s at the default 30 fps),
    /// sticky (peakConf >= Tracker.stickyConf 0.6) after `stickyHold`
    /// (Tracker.defaultStickyHold — 30 frames = 1.0 s at 30 fps). The
    /// sub-floor lift's own 0.5 s hysteresis runs on top of however long the
    /// curtain had already been painted, so any curtain older than ~1 s at
    /// the shrink has outlived both holds and coverage RESTARTS from the next
    /// detector frame. Same correction for the dead-lift and ghost-ban lifts:
    /// they call `dropCurtainState` on the identical path.
    /// DERIVED upper bound on that restart: the 2026-08-25 A/B rig measured
    /// the region cover reaching glass 143-160 ms after content-shown
    /// (receipt at `triggerHits`), 112-118 ms median after the detectQueue
    /// QoS change in the same session.
    /// Upper bound, not a measurement of
    /// this gap: that rig timed content appearing with a cold detector and
    /// Chrome's paint burst in the way; a lift has neither.
    /// BOUNDED, never silent: `noteExposure` is fed the UNFILTERED blocked
    /// list (main.swift, inside `curtainRects`), so the exposure tripwire
    /// still fires on the uncovered frames, and the idle gate stands down
    /// while `uncoveredStreak > 0` so the detector keeps full rate through
    /// the gap instead of stretching it.
    static let minCurtainSize = CGSize(width: 200, height: 150)

    /// PAROLE (owner idea, 2026-08-20): a window whose curtain lifted is a
    /// known offender for paroleSecs (RETURN flavor) or hitParoleSecs (HIT
    /// flavor, split 2026-09-09 — receipt there). Every lift arms it; the
    /// `away` flag records HOW it lifted and picks the re-drop evidence bar:
    ///  - hit parole (any flavor): `paroleHits` attributed hits inside
    ///    `windowSecs` (by id; a RETURN entry also matches any window whose
    ///    frame lands within paroleMatchPt) re-drop instead of re-earning
    ///    the full trigger, and the bar climbs toward `triggerHits` on every
    ///    further hold-expiry lift inside the episode (`hitParoleBar`).
    ///    Was ONE hit — an instant re-drop — until 2026-09-02 (receipt at
    ///    `paroleHits`). Receipt for the lower bar: owner session measured
    ///    5-6 s re-drop gaps after restore (18:23:07/18:23:20, user-test2).
    ///  - RETURN parole (`away` == true: the window left the stage at lift —
    ///    dead-lift or sub-floor, i.e. relegation-shaped): the same id
    ///    coming back above the floor re-drops on GEOMETRY ALONE, no
    ///    detector evidence. Receipt (live-sanity 2026-08-20 20:56:18-27):
    ///    a window restored from the Stage Manager strip rendered a stale
    ///    upscaled snapshot Chrome only repainted on scroll — the detector
    ///    was blind for ~9 s (0-2 dets/s at 30 fps) while the content was
    ///    humanly recognizable, then 53 dets/frame and a same-second drop
    ///    once the user scrolled. A hold-expiry lift on a still-listed,
    ///    above-floor window is content-turned-benign-shaped and gets
    ///    `away` == false: geometry return there would re-cover benign
    ///    windows on every restore — and since 2026-09-09 it STAYS
    ///    `away` == false when the window later leaves the stage (the
    ///    promotion that used to flip it is gone; note at the former site
    ///    in `update`, and the hard cap at `paroleHardCapSecs`).
    /// Cost of hit parole: a window whose content turned benign while
    /// relegated is re-covered until the 5 s quiet lift — over-cover,
    /// fail-safe. Cost of return parole: if the restored content stays
    /// detector-blind AND explicit past the drop's holdSecs, the re-lift
    /// arms hit parole only (no drop/lift flap); residual exposure accepted.
    /// Magnitude receipt (2026-08-21): ASSUMED. The two measurements in
    /// the comment above give re-drop gaps of 5-6 s (hit parole,
    /// 18:23:07/18:23:20, user-test2) and a ~9 s detector-blind window
    /// (RETURN parole, live-sanity 2026-08-20 20:56:18-27, quoted as measured
    /// above). 300 s clears the larger of those (~9 s) by >30x while also
    /// bounding two other things that reuse this constant as their horizon:
    /// known-offender memory (idle-eviction receipt above, "reuses
    /// paroleSecs as the retention horizon") and the sweep's eviction
    /// interval. Remeasure from live parole-return telemetry (the
    /// `"drop (parole return)"` event) before changing either direction —
    /// down risks expiring parole inside a still-relegated window's gap
    /// (re-cover lost early) for any id NOT currently strip-covered (a
    /// strip-covered RETURN parolee does not age at all while its thumbnail
    /// stays listed — receipt at the strip-cover block below — until
    /// `paroleHardCapSecs` ends it regardless); up only costs
    /// the already-bounded per-id memory and the tracker watch-budget
    /// documented at `watchBudgetIDs` below.
    static let paroleSecs: CFTimeInterval = 300
    /// HIT-parole horizon, split from `paroleSecs` 2026-09-09 (`paroleSecs`
    /// stays the RETURN / known-offender horizon). MEASURED, owner session
    /// 2026-09-09 on a test Mac:
    /// window 11499 cycled `lift (hold 5.0s, N clean frames)` -> `drop
    /// (parole)` eight times in 134 s (N = 20-146) on a page the owner calls
    /// clean, ~36 % painted duty cycle; every re-drop rode on exactly 2
    /// blocked detector frames of 1-2 small explicit-class boxes (conf
    /// 0.55-0.85), and 13 of 14 lift->re-drop gaps in the session were 1-17 s
    /// (median 4 s), one was 38 s. Three things made 300 s the wrong horizon
    /// for this flavor: every lift re-stamped the clock, so a cycling window
    /// never left parole; the re-drop discarded the clean-frame evidence the
    /// lift had just earned; and the 2-hit bar sat exactly at the measured
    /// 2-frame false-positive burst. 30 s clears the 5-6 s re-drop gaps the
    /// original hit-parole receipt measured (18:23:07/18:23:20, user-test2)
    /// by 5x and the session's median by 7x, and is short enough that a
    /// window proven clean stops being a known offender inside a minute.
    /// Three rules ride on it: (1) the horizon runs from the episode's FIRST
    /// hold-expiry lift (`hitParoleEpisode`) and a re-lift never re-stamps
    /// it; (2) each further hold-expiry lift inside the horizon raises the
    /// bar by one toward `triggerHits` and logs `parole-churn` with the count
    /// — at today's values the second lift already puts the window back on
    /// the full trigger, so a 2-frame burst re-drops a clean window at most
    /// once per episode; (3) hit parole matches by id only (receipt at
    /// `paroleMatches`). Owner-accepted trade: past this horizon a return to
    /// explicit content costs `triggerHits` = 3 frames instead of 2 — one
    /// detector frame (`paroleExtraDelayMs`), the region cover is on glass
    /// throughout. Consecutive-frame gating (the other candidate) was NOT
    /// adopted: the 2-frame bursts in the table are consecutive detector
    /// frames, so it would have filtered nothing.
    static let hitParoleSecs: CFTimeInterval = 30
    /// Absolute lifetime of any parole entry from its lift, whatever refreshes
    /// its aging clock. Closes the hole where a strip-covered RETURN parolee
    /// never aged while its thumbnail stayed listed (the strip block below
    /// re-stamps `at` every tick), so a window parked in the Stage Manager
    /// strip stayed a geometry-return offender indefinitely. DERIVED from the
    /// return-parole receipt at `paroleSecs`: the measured detector-blind
    /// restore is ~9 s (live-sanity 2026-08-20 20:56:18-27), and 300 s is
    /// >30x that — the same margin `paroleSecs` already claims, now enforced
    /// from a clock nothing can move. Cost, written down: a window that sits
    /// in the strip longer than this and then returns is covered by the
    /// trigger (3 hits) instead of geometry; the ~9 s blind restore is then
    /// exposed once. Not measured live; the `parole hard cap` event is the
    /// number to watch.
    static let paroleHardCapSecs: CFTimeInterval = 300
    static let paroleMatchPt: CGFloat = 32
    /// Attributed hits inside `windowSecs` that re-drop a HIT parolee. Owner
    /// decision 2026-09-02; was 1 (an instant re-drop on a single attributed
    /// hit). Receipt: the `triggerHits` margin, applied to parole — the walk
    /// credits one hit per window per frame, so a single-frame false positive
    /// yields exactly one attributed hit, and a bar of 1 gave parole no
    /// margin over it at all. Evidence:
    /// 7 drops = 2 fresh + 4 hit-parole re-drops
    /// on explicit-class false positives of 6 / 2 / 2 / 3 frames + 1 geometry
    /// `parole return` (no detector hits; untouched here). DERIVED effect of
    /// the bar: only an episode that yields exactly ONE attributed hit inside
    /// `windowSecs` stops re-dropping — at most the two 2-frame episodes
    /// above (the log records frames, not attributed hits); the 6- and
    /// 3-frame ones still re-drop, and the fresh trigger keeps 3 for its
    /// 1.5x margin. Next-soak target, MEASURABLE: parole re-drops preceded by
    /// a single attributed hit → 0 (every `drop (parole)` must show ≥ 2
    /// blocked frames inside the prior second); the total `drop (parole)`
    /// count is NOT the target. `--ui-selftest` scripts both cases.
    /// COST, DERIVED (fps arithmetic; the parole path cannot run headless and
    /// no live run was made): the re-drop waits for one more attributed hit.
    /// When the detector re-attributes on the very next frame — the fixtures
    /// measured that continuity on 20 of 25 appearance edges — and the walk
    /// bypass is not muted (`pendingUncurtained` puts the walk at full rate
    /// after the first hit), that is one detector frame: `paroleExtraDelayMs`
    /// = 1000/fps = 33 ms at the default tier's 30 fps, 67 ms at no-ane's
    /// 15 fps (asserted per tier in `--ui-selftest`, reading `PerfTier.all`).
    /// Otherwise it is the next attributed frame inside `windowSecs` (up to
    /// `walkEvery` frames while `bypassMuted`), and past `windowSecs` the
    /// first hit ages out and the bar restarts.
    /// DELIBERATELY NOT fps-DERIVED (same reasoning as `holdCleanFrames`):
    /// this is a count of detector frames of evidence, and a single-frame
    /// false positive is one frame at every tier — deriving 2 from a duration
    /// would hand the no-ane tier a bar of 1 and no margin at all. Equal to
    /// `handoffHits` by value, not by definition: a handoff-eligible parolee
    /// is labelled "drop (handoff)" (the trigger loop tests handoff first).
    /// `paroleSecs` (the 300 s known-offender memory) is unchanged, and
    /// RETURN parole (`away`: a relegated window coming back above the floor
    /// re-drops on geometry alone) takes no detector hits — also unchanged.
    /// Consequence written down: the parole drop now runs through the trigger
    /// loop's `pollable` guard, so the loud ghost-ban of an unpollable parole
    /// candidate fires at 2 hits instead of 3 (before, the in-walk parole
    /// path skipped it and the hit fell through to the trigger loop's ban at
    /// `triggerHits`).
    static var paroleHits: Int { TuningPolicy.defaults.curtain.paroleHits }
    /// The wall-clock cost of `paroleHits` over the old single-hit re-drop at
    /// one tier's fps: one detector frame per extra hit (receipt above).
    static func paroleExtraDelayMs(fps: Int) -> Double {
        Double(paroleHits - 1) * 1000.0 / Double(fps)
    }
    /// Concurrent tracker-watched ids (active curtains + every parolee)
    /// beyond which the watch-budget tripwire fires. Every parolee is
    /// watched (receipt at `watchIDs`). Derived from the record's own poll-load math
    /// (WindowTracker header receipt: 1.26%/core per id against 25% budget
    /// with 18.6% spent), which exhausts tracker headroom near 5 concurrent
    /// ids; this tripwire is what turns that into a loud signal instead of
    /// silent sched-telemetry degradation (2026-08-21).
    ///
    /// MEASURED 2026-09-08, test Mac, source main 3ae5a64, ten shielded runs:
    /// 5 WAS NEVER APPROACHED. `watchIDs` = active curtains + parolees, and
    /// the largest population any run produced was 2 — `twowin`
    /// (tag rmr-twowin-1: window A drops, is relegated to the strip and
    /// paroles while B drops, so both ids are watched at once). Every other
    /// mode watched 1. Zero `watch-budget` events in any run.
    /// Per-id cost on that hardware is NOT separable at this n: mean wall
    /// time per poll was 1.629 ms with two ids and 1.051-1.716 ms with one,
    /// i.e. the CGWindowList IPC round trip dominates the per-id work — so
    /// the "1.26%/core per id" figure is still the only per-id receipt, and
    /// a 5-id desktop remains unmeasured. Do not raise this on the strength
    /// of these runs; they prove only that the ceiling is far above the
    /// observed load. If a healthy desktop trips it, remeasure the per-id
    /// cost and re-receipt before raising.
    /// 2026-09-09: `watchIDs` grew by the pending-hit ids and the topmost
    /// candidate (receipt at `frontCandidateSecs`), so the twowin-shaped
    /// population is now up to 4 (A on parole, B active, B's pending hits
    /// before its drop, the topmost = B itself once raised — usually the
    /// same id twice). Still under 5; if the tripwire fires on a healthy
    /// desktop, remeasure the per-id cost first, as above.
    static let watchBudgetIDs = 5
    private var watchOverBudget = false
    /// `at` is the aging clock (re-stamped only by the strip cover, for RETURN
    /// entries); `armedAt` is when the lift armed it and never moves, so the
    /// hard cap and the hit-parole episode both have a clock that cannot be
    /// refreshed.
    private var parole:
        [CGWindowID: (frame: CGRect, at: CFAbsoluteTime, armedAt: CFAbsoluteTime, away: Bool)] =
            [:]
    /// HIT-PAROLE EPISODE per id: the first hold-expiry lift's time and how
    /// many hold-expiry lifts have happened since, inside `hitParoleSecs`.
    /// Survives the re-drop (an active curtain owns no parole entry) so the
    /// next lift can keep the episode's clock instead of restarting it.
    private var hitParoleEpisode: [CGWindowID: (armedAt: CFAbsoluteTime, lifts: Int)] = [:]

    /// Re-drop bar for a hit parolee: `paroleHits` on the episode's first
    /// lift, one more per further hold-expiry lift inside `hitParoleSecs`,
    /// never above `triggerHits` (receipt at hitParoleSecs). A cross-id match
    /// on a RETURN entry has no episode and gets `paroleHits`.
    private func hitParoleBar(_ id: CGWindowID) -> Int {
        min(tuning.curtain.triggerHits,
            tuning.curtain.paroleHits + max(0, (hitParoleEpisode[id]?.lifts ?? 1) - 1))
    }
    /// Last above-floor frame per active curtain — the frame parole stores.
    private var lastBigFrame: [CGWindowID: CGRect] = [:]

    /// Sub-floor geometry must persist this long before it lifts a curtain.
    /// Receipt (owner session 2026-08-20): relegation geometry can be
    /// reported while the window is visually in place; a blip must not
    /// lift. 0.5 s is ~60 polls — far past any transient, well inside a
    /// real relegation.
    static let subFloorLiftSecs: CFTimeInterval = 0.5
    private var subFloorSince: [CGWindowID: CFAbsoluteTime] = [:]

    /// Ghost-breaker (owner session 2026-08-20: window 98): a candidate
    /// must pass a direct per-id poll to be curtained, and two dead-lifts
    /// inside ghostWindowSecs blacklist the id for ghostBanSecs — a surface
    /// the snapshot lists but polls kill would otherwise churn 2 s
    /// drop/dead-lift cycles and steal attribution from real windows.
    static let ghostWindowSecs: CFTimeInterval = 10
    static let ghostBanSecs: CFTimeInterval = 30
    private var deadLiftTimes: [CGWindowID: [CFAbsoluteTime]] = [:]
    private var ghostBanUntil: [CGWindowID: CFAbsoluteTime] = [:]

    /// IDLE EVICTION (2026-08-21): ghostBanUntil, deadLiftTimes,
    /// lastTrailEvent, and frames are per-id caches that otherwise only
    /// clear in reset() (panic). On a 24/7 run, ids for windows that closed
    /// hours ago (~50-150 B/entry) accumulate forever. Reuses paroleSecs as
    /// the retention horizon — not a new number: it is already this file's
    /// "known-offender memory window" (receipt at paroleSecs), so an id
    /// evicted here could not still be on parole, ghost-banned, or
    /// trail-throttled. GATE SAFETY: PixelReplay always sets opts.process,
    /// so main.swift's `live && opts.windowTrack` gate is false and `curtain`
    /// is never constructed for --process runs — sweepIdle (like the rest of
    /// this class) cannot execute during the gate regardless of fixture
    /// length or cadence.
    ///
    /// Sweep at most once per sweepEverySecs. DERIVED: a sweep is O(entries)
    /// and none of these caches grow fast enough to need finer resolution
    /// than paroleSecs itself, so a plain timestamp compare is the only
    /// per-tick cost between sweeps.
    static let sweepEverySecs: CFTimeInterval = 60
    /// Capture-gap guard. update() is frame-driven, so a capture outage
    /// (display sleep, stream re-arm) advances wall-clock while no evidence
    /// CAN arrive; without a guard, the first frame after a gap > holdSecs
    /// would lift every active curtain at once (t - lastHit > holdSecs) —
    /// the exact fail-open the sleep/wake re-arm must not introduce. Hold
    /// clocks are re-stamped across a gap instead; lift is then re-earned
    /// by live evidence. DERIVED: 2.0 s sits an order of magnitude above
    /// the slowest organic frame cadence
    /// and below holdSecs = 5.0, so
    /// a real outage is caught before it can lift anything and no organic
    /// gap can trigger it. Gate-safe: fixtures replay at fixture cadence
    /// with no multi-second stamp jumps, and curtain never runs under
    /// --process anyway (see sweepIdle gate-safety receipt above).
    static let gapGuardSecs: CFTimeInterval = 2.0
    private var lastUpdateT: CFAbsoluteTime?
    /// Loud only when a sweep evicts more than this many entries in one
    /// pass. ASSUMED: ordinary id churn (windows opened/closed through
    /// normal use) is single digits per sweep; 100+ points at the leak this
    /// sweep exists to fix, not routine use — remeasure from a live
    /// "event":"curtain" sweep record before raising this.
    static let sweepLogThreshold = 100
    private var lastSweepAt: CFAbsoluteTime = 0

    /// Curtain handoff: a window whose frame CONTAINS an active (or just
    /// lifted, see liftGraceSecs) curtain's frame — `handoffTolerancePt`
    /// tolerance — inherits its trust and drops after this many hits instead
    /// of triggerHits. Receipt (fs-h1/h2): the fullscreen successor otherwise
    /// earns a curtain from zero, 2.7 s exposed. Containment, not overlap:
    /// the owner's live cycle showed five bystander windows behind the
    /// action earning handoff curtains under the overlap rule.
    ///
    /// The RESTORE direction (a successor that is contained BY the departing
    /// curtain — fullscreen exit) was the documented "review P3" gap here
    /// until 2026-09-08; `restoreShaped` below is its narrow rule, and its
    /// drops are labelled `drop (handoff restore)` so the two trust paths are
    /// countable apart in a log.
    static var handoffHits: Int { TuningPolicy.defaults.curtain.handoffHits }
    /// Containment tolerance for BOTH handoff arms and the transition bridge —
    /// R1 specified them as one rule.
    /// Unchanged in value since;
    /// naming it only stops the three call sites drifting apart. It absorbs
    /// the 1-2 pt rounding between the walk snapshot's rect and the 120 Hz
    /// ring's without admitting a window that merely abuts.
    static let handoffTolerancePt: CGFloat = 8
    /// A lifted curtain's frame stays handoff-eligible this long, so a
    /// successor mid-accumulation does not silently revert to the full
    /// trigger the moment its predecessor lifts (review 2026-08-20, P2).
    /// `away` mirrors parole's flag: true when the lift meant the window LEFT
    /// the stage (dead / sub-floor), false for a hold-expiry lift on a listed
    /// window. Only the restore arm reads it (receipt at `restoreShaped`).
    static let liftGraceSecs: CFTimeInterval = 2.0
    private var recentLifted:
        [CGWindowID: (frame: CGRect, at: CFAbsoluteTime, away: Bool)] = [:]

    /// The frame at which each ACTIVE curtain first read as leaving this
    /// episode; cleared the moment it reads healthy again. Only the restore
    /// arm reads it, and it is what BOUNDS that arm (receipt at
    /// `restoreShaped`) — without it "leaving" has no clock of its own.
    private var leavingSince: [CGWindowID: CFAbsoluteTime] = [:]
    /// One restore inheritance per departing predecessor: predecessor id ->
    /// the successor that spent it (receipt at `restoreShaped`). Self-expiring
    /// on the arm's own bound, the same (value, time) idiom as parole,
    /// recentLifted and linger.
    private var restoreGranted:
        [CGWindowID: (successor: CGWindowID, at: CFAbsoluteTime)] = [:]

    /// Expansion entries: extra cover unioned into an active curtain's
    /// painted frame — the transition bridge (union with a handoff
    /// candidate's frame) and the transition shield (full display). Each
    /// entry expires expansionSecs after its last refresh AND hard-caps at
    /// expansionCapSecs after first arming (review 2026-08-20, P2: refresh
    /// ratcheting otherwise keeps a full-display entry alive forever).
    static let expansionSecs: CFTimeInterval = 1.5
    static let expansionCapSecs: CFTimeInterval = 4.5
    /// Which caller asked for an expansion. The two are priced differently:
    /// the SHIELD is a full-display cover for evidence nobody can name, the
    /// BRIDGE is cover continuity over one named successor window. Only the
    /// shield is subject to the re-arm cooldown (receipt below).
    private enum ExpansionKind: String {
        case bridge
        case shield
    }
    /// After the cap fires for a curtain, no SHIELD expansion may re-arm for
    /// that curtain until this long has passed. Receipt (curtain-loop finding,
    /// scenario curtain-expansion-cap): the cap alone bounded
    /// NOTHING while orphan/shield-grade evidence persisted —
    /// `extendExpansion` removed the capped entry and the very next walk
    /// recreated it with a fresh `firstAt`, so a persistent orphan held a
    /// FULL-DISPLAY shield ~99% of the time with a one-frame blink every
    /// expansionCapSecs. DERIVED from receipts already in this file: every
    /// measured successor gap is 0.1-0.7 s (fs-h1/h2) and `liftGraceSecs`
    /// = 2.0 s is this file's already-measured "a transition can still be
    /// in flight" interval, so 2.0 s is the smallest value here that
    /// outlasts any measured transition — if the shield comes down for a
    /// whole cooldown and the evidence is STILL orphan-shaped, the
    /// ambiguity is not a transition and a full-display shield is not the
    /// answer to it. Smaller candidates do not bound the shield in any
    /// useful sense: 0.7 s (the slowest measured gap) leaves it up 87% of
    /// the time. EXPOSURE TRADED, written down rather than hidden: under
    /// sustained orphan evidence the display OUTSIDE the curtained
    /// window's own frame is uncovered for up to 2.0 s of every 6.5 s
    /// (31%) instead of ~1%; the curtain over the named window keeps
    /// painting throughout. The cooldown is per curtain episode — a lift
    /// clears it with the rest of the id's state (`dropCurtainState`).
    /// SHIELD ONLY (review 2026-09-09): `extendExpansion` has two callers and
    /// the measurement above priced only one of them. Refusing the transition
    /// BRIDGE for a cooldown would leave a named successor window uncovered
    /// while it accumulates its hits — an exposure this receipt never
    /// measured and the cap's own receipt never priced — so a bridge is
    /// granted throughout the cooldown. BRIDGE COST THAT REMAINS, named
    /// rather than implied: (a) the bridge is still cap-only, so persistent
    /// successor evidence still drops its entry for one walk every
    /// expansionCapSecs and re-arms on the next — the pre-existing one-frame
    /// blink, unchanged by this branch and bounded by one successor window's
    /// frame, never the display; (b) a bridge that re-arms DURING a cooldown
    /// gives the shared entry a fresh `firstAt`, so the shield's next cap is
    /// measured from that bridge, shifting the duty cycle's phase — the
    /// bound (expansionCapSecs on, expansionRearmCooldownSecs off) still
    /// holds because the shield can never union the display in before the
    /// cooldown expires.
    static let expansionRearmCooldownSecs: CFTimeInterval = 2.0
    private var expansion:
        [CGWindowID: (rect: CGRect, until: CFAbsoluteTime, firstAt: CFAbsoluteTime)] = [:]
    /// Cap cooldowns: `until` is when a shield may re-arm again, `logged`
    /// records which expansion kinds have already announced a refusal in
    /// this cooldown — every refused kind is loud at least once per cooldown
    /// (never silenced by another kind having spoken first), and none is
    /// loud once per walk.
    private var expansionCooldown:
        [CGWindowID: (until: CFAbsoluteTime, logged: Set<ExpansionKind>)] = [:]
    /// Last time the walk produced shield-grade orphan evidence.
    private var lastOrphanAt: CFAbsoluteTime = 0

    /// Fullscreen windows get NO chrome strip: the strip exists to keep the
    /// toolbar visible, and a fullscreen browser hides its toolbar
    /// (2026-08-20 owner test: the cutout showed a full-width content band).
    /// "Fullscreen" = the window covers >= 95% of its display's area.
    ///
    /// One definition, two readers (2026-09-08): the strip bail here and the
    /// restore-direction handoff arm (`restoreShaped`). Both mean the same
    /// thing — "this window IS the display" — and must not drift apart.
    static let fullscreenCoverage: CGFloat = 0.95
    static func coversDisplay(_ f: CGRect, display: CGRect) -> Bool {
        (f.width * f.height) / max(display.width * display.height, 1) >= fullscreenCoverage
    }

    static func contentRect(window f: CGRect, display: CGRect, quickLook: Bool = false) -> CGRect {
        // Receipt: test Mac Quick Look title bar is 38 pt; Chrome's 80 pt strip
        // does not apply. Cover the complete click-through preview panel.
        if quickLook { return f }
        if coversDisplay(f, display: display) { return f }
        guard f.height > 2 * chromeStripPt else { return f }
        var c = f
        c.origin.y += chromeStripPt
        c.size.height -= chromeStripPt
        return c
    }

    /// Pending trigger evidence per window: one entry per attributed
    /// evaluated frame, stamped with wall time AND the evaluated-frame tick
    /// it landed on (retention receipt at `windowFrames`).
    private var hits: [CGWindowID: [(t: CFAbsoluteTime, tick: Int)]] = [:]
    /// Active curtains: window id -> last blocked hit inside it.
    private var lastHit: [CGWindowID: CFAbsoluteTime] = [:]
    /// Detector-evaluated frames since each active curtain's last hit.
    /// Geometry-only ticks do not change this evidence.
    private var cleanFrames: [CGWindowID: Int] = [:]
    /// Last known frame per active curtain, from the attribution walk or the
    /// tracker ring — kept so the drop frame (before the id is tracked at
    /// 120 Hz) still has a frame to paint. `at` is sweepIdle's "has not been
    /// touched" clock (receipt there). One dictionary holding (value, time),
    /// the same idiom as parole/recentLifted/linger — an entry cannot exist
    /// without its clock (simplify pass 2026-08-21: replaced a parallel
    /// framesTouchedAt dictionary kept in lockstep by convention).
    private var frames: [CGWindowID: (rect: CGRect, at: CFAbsoluteTime)] = [:]

    /// The single write path — sweepIdle only evicts entries this call has
    /// stopped refreshing.
    private func touchFrame(_ id: CGWindowID, _ f: CGRect, at t: CFAbsoluteTime) {
        frames[id] = (rect: f, at: t)
    }

    var activeIDs: Set<CGWindowID> { Set(lastHit.keys) }

    /// IDs the WindowTracker must poll: active curtains plus every parole
    /// window — a RETURN parolee for its geometry-return drop and strip cover,
    /// a hit parolee for at most `hitParoleSecs` (its frame is only read by
    /// `paroleMatches`; the 2026-09-09 change shortened this population's
    /// life from 300 s to 30 s). Poll cost is one
    /// CGWindowList entry per id at 120 Hz (WindowTracker header receipt:
    /// 1.26%/core per window against the 25% budget, 18.6% spent) — so ~5
    /// concurrent parolees exhaust the headroom. MEASURED 2026-09-08 on the
    /// test Mac (receipt at `watchBudgetIDs`, source main 3ae5a64): the largest
    /// watched population any shielded run produced was 2, in `twowin`. That
    /// the household case stays at one or two explicit windows is still
    /// ASSUMED — ten scripted runs are not a household. If the assumption
    /// breaks, the tracker's sched telemetry (late-poll lines) is the visible
    /// failure; remeasure there before raising any budget.
    /// Since 2026-09-09 (capture-time attribution, receipt at
    /// `frontCandidateSecs`) the set also holds every window with PENDING
    /// hits and the topmost window the last walk saw, so their rings exist
    /// before the walk asks where they were at capture time. Bounded: hits
    /// live `windowSecs`, the candidate `frontCandidateSecs`, and the
    /// sub-floor filter keeps thumbnails out of `hits`. Expected population
    /// is therefore the measured 2 plus at most ~2, still under
    /// `watchBudgetIDs`; the tripwire there stays the visible failure.
    var watchIDs: Set<CGWindowID> {
        var ids = Set(lastHit.keys).union(parole.keys).union(hits.keys)
        if let c = frontCandidate { ids.insert(c.id) }
        return ids
    }

    /// "Currently unlisted": never polled this episode, OR a live miss
    /// streak (receipt at unlistedSecs).
    private func unlisted(_ id: CGWindowID, _ tracker: WindowTracker) -> Bool {
        tracker.latestFrame(of: id) == nil
            || tracker.missSeconds(of: id) >= Self.unlistedSecs
    }

    /// One step. `blockedScreenRects` are this frame's blocked detections in
    /// CGWindowList space (screen points, TOP-LEFT origin — the caller's
    /// screenRect conversion). Returns the active curtains' painted frames
    /// (window frame unioned with any live expansion) in that same space.
    /// `evaluated == false` is a geometry-only tick. It can process death,
    /// sub-floor, parole-return, strip-cover, and linger state, but it cannot
    /// add detector hits, add clean-frame evidence, or expire a hold.
    func update(
        blockedScreenRects: [CGRect], tracker: WindowTracker,
        display: CGRect, at t: CFAbsoluteTime, evaluated: Bool = true,
        sourceIndices: [Int]? = nil
    ) -> [(id: CGWindowID, frame: CGRect)] {
        var source: [Int]?
        if onDrop != nil, !blockedScreenRects.isEmpty {
            if let sourceIndices, sourceIndices.count == blockedScreenRects.count {
                source = sourceIndices
            } else {
                onCropEvent?(
                    "attribution=source-index skipped=true expected=\(blockedScreenRects.count) "
                        + "observed=\(sourceIndices?.count ?? 0)")
            }
        }
        var attributedThisFrame: [CGWindowID: [Int]]? = source == nil ? nil : [:]
        if evaluated {
            tick += 1
            // Capture-gap guard (receipt at gapGuardSecs): covers fail safe
            // through an outage. Geometry-only ticks are not capture
            // evidence and must not hide this gap.
            // PENDING EVIDENCE DIES WITH THE OUTAGE TOO
            // (2026-09-11). The guard used to require `!lastHit.isEmpty`, so a
            // gap with no active curtain did nothing at all, and it never
            // touched `hits`. `hits` is pruned by `windowSecs` OR by
            // `windowFrames` of `tick`, and `tick` does not advance while no
            // frames arrive — so a hit observed before a sleep stayed "recent"
            // across the whole outage and ONE post-wake hit could reach
            // `paroleHits`/`handoffHits` and drop a curtain on pre-sleep
            // pixels. Drop the pending rings instead: a drop must be earned by
            // evidence from the same side of the outage as the frame that
            // triggers it. Over-cover is never the cost here — a real offender
            // still drops `triggerHits` frames (~0.1 s at 30 fps) later.
            let gapped = !lastHit.isEmpty || !hits.isEmpty || frontCandidate != nil
            if let prev = lastUpdateT, t - prev > Self.gapGuardSecs, gapped {
                let droppedRings = hits.count
                let droppedHits = hits.values.reduce(0) { $0 + $1.count }
                let droppedCandidate = frontCandidate != nil
                for id in lastHit.keys { lastHit[id] = t }
                // The clean-frame counters are evidence gathered before the
                // outage; a fast lift must be re-earned after it too.
                for id in deadClean.keys { deadClean[id] = 0 }
                for id in linger.keys { linger[id]?.clean = 0 }
                // The successor linger re-earns BOTH its evidence signals:
                // `seen` too, because the frame that was going to carry the
                // revealed window's pixels is the one the outage ate. Its
                // ceiling is deliberately not pushed (receipt at
                // `successorLingerSecs`).
                for id in successorLinger.keys {
                    successorLinger[id]?.seen = false
                    successorLinger[id]?.clean = 0
                }
                hits.removeAll()
                // Also pre-outage evidence: the candidate is "who was in front
                // when the last walk ran", and after a sleep nobody knows.
                // `frontCandidateSecs` (2.0 s) EQUALS `gapGuardSecs`, so the
                // prune below already expires any candidate a gap this guard
                // trips on — this clear is explicit, not load-bearing, and it
                // stops the two constants' equality from being load-bearing.
                frontCandidate = nil
                // The discarded evidence is named only when there WAS some:
                // a line that always ends in "0 pending hit ring(s)" is noise,
                // and this event is read frame-by-frame by the algorithm-loop
                // harness.
                var dropped: [String] = []
                if droppedHits > 0 {
                    dropped.append("\(droppedHits) pending hit(s) across \(droppedRings) window(s)")
                }
                if droppedCandidate { dropped.append("the front candidate") }
                onChange?(
                    String(
                        format: "evaluated-frame gap %.1fs — hold re-stamped for %d curtain(s)%@",
                        t - prev, lastHit.count,
                        dropped.isEmpty ? "" : "; discarded " + dropped.joined(separator: " and ")),
                    0)
            }
            lastUpdateT = t
        }
        sweepIdle(tracker: tracker, at: t)
        if let c = frontCandidate, t - c.at > Self.frontCandidateSecs || lastHit[c.id] != nil {
            frontCandidate = nil
        }
        // LEAVING CLOCK for the restore arm (receipt at `restoreShaped`).
        // `unlisted` counts misses of ANY cause, but only an `.unknownID`
        // streak ever becomes `WindowTracker.isDead` (WindowTracker's own
        // receipt at `isDead`), so an `.apiFailed`/`.malformed` streak can
        // read leaving indefinitely and never reach the dead lift that would
        // end it. Stamping the first leaving frame gives the arm a clock that
        // does not depend on the miss cause; a curtain that reads healthy
        // again clears the stamp and a later departure is a new episode.
        for id in Set(lastHit.keys).union(leavingSince.keys) {
            let leaving = lastHit[id] != nil
                && (unlisted(id, tracker) || deadSince[id] != nil)
            if leaving {
                if leavingSince[id] == nil { leavingSince[id] = t }
            } else {
                leavingSince.removeValue(forKey: id)
            }
        }
        restoreGranted = restoreGranted.filter {
            t - $0.value.at <= Self.deadLiftSecs + Self.liftGraceSecs
        }
        // Two horizons (receipts at paroleSecs / hitParoleSecs) and one hard
        // cap over both (receipt at paroleHardCapSecs). The cap is the only
        // way a strip-listed RETURN parolee ever expires, so it is loud — and
        // loud ONLY when the cap is what ended the entry. A RETURN parolee
        // that was never strip-covered has `at` == `armedAt`, so both clocks
        // run out on the same tick and an unconditional event would fire on
        // every routine 300 s expiry — which is exactly the count this event
        // exists to make readable (receipt at paroleHardCapSecs: "the
        // `parole hard cap` event is the number to watch").
        for (id, p) in parole
        where t - p.armedAt > Self.paroleHardCapSecs
            && t - p.at <= (p.away ? Self.paroleSecs : Self.hitParoleSecs) {
            onChange?(
                "parole hard cap: paroleHardCapSecs \(Int(Self.paroleHardCapSecs)) s since the "
                + "lift, entry released\(stripActive.contains(id) ? " (was strip-covered)" : "") "
                + "(fix: Curtain.paroleHardCapSecs)", id)
        }
        parole = parole.filter {
            t - $0.value.at <= ($0.value.away ? Self.paroleSecs : Self.hitParoleSecs)
                && t - $0.value.armedAt <= Self.paroleHardCapSecs
        }
        hitParoleEpisode = hitParoleEpisode.filter { t - $0.value.armedAt <= Self.hitParoleSecs }
        // PAROLE RETURN (receipt at paroleSecs): a relegated offender back
        // above the floor re-drops on geometry alone — the restored window
        // can render a stale snapshot the detector cannot see until the app
        // repaints (live-sanity 2026-08-20: ~9 s blind). Same id is the
        // identity; pollable() keeps ghosts out.
        for (id, p) in parole where p.away && lastHit[id] == nil {
            guard ghostBanUntil[id] == nil || t >= ghostBanUntil[id]! else { continue }
            guard let f = tracker.latestFrame(of: id),
                tracker.missStreak(of: id) == 0, !belowFloor(f)
            else { continue }
            // Same rule as the trigger drop: an unpollable candidate is
            // ghost-banned LOUDLY, never skipped silently (receipt-audit
            // 2026-08-20: a silent continue here would leave a real restored
            // offender uncovered for up to paroleSecs with no trace, and
            // re-pay the per-id probe every tick).
            guard tracker.pollable(id) else {
                ghostBanUntil[id] = t + Self.ghostBanSecs
                parole.removeValue(forKey: id)
                onChange?("ghost-ban (unpollable at parole return)", id)
                continue
            }
            touchFrame(id, f, at: t)
            lastHit[id] = t
            dropAt[id] = t
            cleanFrames[id] = 0
            parole.removeValue(forKey: id)
            onChange?("drop (parole return)", id)
        }
        if evaluated {
        // Full-rate walk conditions — attribution latency is the critical
        // path in all three: no curtain exists yet (first-drop latency IS
        // walk latency, measured 1.0 s at 10 Hz); an active curtain's window
        // is currently unlisted (space transition); or orphan evidence
        // appeared in the last 0.5 s (transition content whose window nobody
        // can name yet). Budgeted: continuous bypass beyond bypassBudgetSecs
        // reverts to the throttle, loudly.
        let transitionActive = lastHit.keys.contains { unlisted($0, tracker) }
        let noCurtainYet = lastHit.isEmpty
        let orphansRecent = t - lastOrphanAt < 0.5
        // Any window with pending hits and no curtain keeps the walk at full
        // rate (owner two-window session 2026-08-20: with one curtain active
        // the fast walk stopped applying, and the SECOND explicit window
        // waited ~1 min on the 10 Hz path for its trigger). Same budget as
        // the other bypasses.
        let pendingUncurtained = hits.keys.contains { lastHit[$0] == nil }
        var wantBypass = !blockedScreenRects.isEmpty
            && (noCurtainYet || transitionActive || orphansRecent || pendingUncurtained)
        if wantBypass {
            let since = bypassSince ?? t
            bypassSince = since
            if t - since > Self.bypassBudgetSecs {
                if !bypassMuted {
                    bypassMuted = true
                    onChange?(
                        "walk-budget: bypass held \(Int(Self.bypassBudgetSecs)) s, "
                        + "reverting to 1/\(walkEvery) cadence", 0)
                }
                wantBypass = false
            }
        } else {
            bypassSince = nil
            bypassMuted = false
        }
        traceRecorder?.begin(
            blockedScreenRects.isEmpty
                ? .noBlockedBoxes
                : wantBypass || tick % walkEvery == 0 ? .ran : .skipped(every: walkEvery))
        if !blockedScreenRects.isEmpty, wantBypass || tick % walkEvery == 0 {
            // Merge overlapping boxes first: one thumbnail's part-boxes are
            // one piece of evidence about the window, not three.
            let merged: [AttributedRect]
            if let source {
                merged = Self.mergeAttributed(
                    blockedScreenRects, sourceIndices: source, iouOver: 0.001)
            } else {
                merged = Geometry.merge(blockedScreenRects, iouOver: 0.001).map {
                    AttributedRect(rect: $0, sourceIndices: nil)
                }
            }
            traceRecorder?.walk(queries: Self.mergeAttributed(
                blockedScreenRects, sourceIndices: Array(blockedScreenRects.indices), iouOver: 0.001
            ).map { $0.sourceIndices ?? [] })
            let trails = movingTrails(tracker: tracker, at: t)
            let queries = merged.map {
                WindowTracker.Query(authority: $0.rect, gate: $0.rect, incumbent: nil)
            }
            var seenThisFrame = Set<CGWindowID>()
            var shieldOrphans = CGRect.null
            var topmost: CGWindowID?
            let resolved = tracker.resolveOwners(
                queries, transparentOwners: [WindowTracker.curtainTransparentOwner],
                topmost: &topmost)
            // Topmost listed window -> polled from now (receipt at
            // frontCandidateSecs): a raised or dragged window is the
            // topmost, so its ring is mature before it reaches a box.
            if let topmost, lastHit[topmost] == nil {
                frontCandidate = (id: topmost, at: t)
            }
            for (qi, r) in resolved.enumerated() {
                // Hits need frontHoldsGate (review 2026-08-19 P2): a window
                // must HOLD >=75% of the box, or the curtain drops on a
                // bystander while the flagged window stays uncovered.
                guard let id = r.frontID, r.frontHoldsGate else {
                    traceRecorder?.note(query: qi, r.frontID.map { front in
                        DetectionTrace.CurtainOutcome.straddle(
                            front: front,
                            held: Double(WindowTracker.heldFraction(merged[qi].rect, in: r.frontFrame ?? .null)),
                            rewoundTo: lastHit[front] == nil
                                ? traceRewindHolder(merged[qi].rect, display: display, tracker: tracker) : nil)
                    } ?? .orphan)
                    // Shield-grade orphan = NO listed window even intersects
                    // it (frontID nil). A box a window partially holds is a
                    // straddle, not a transition signature (review
                    // 2026-08-20, P2: the broad gate let one straddling box
                    // black out the display).
                    if r.frontID == nil {
                        shieldOrphans =
                            shieldOrphans.isNull
                                ? merged[qi].rect : shieldOrphans.union(merged[qi].rect)
                    } else if let front = r.frontID, lastHit[front] == nil {
                        // STRADDLE (2026-09-09, the mirror of the rewind
                        // below): a box an uncurtained front window only
                        // partly covers, sitting inside an active curtain's
                        // content, is that curtain's exposed content — it
                        // used to be dropped here and starve the curtain's
                        // hold (hold expiry mid-drag).
                        _ = rewind(
                            merged[qi].rect, from: front, reason: "straddle at",
                            display: display, tracker: tracker, at: t)
                    }
                    continue
                }
                // Previous walk's frame, read BEFORE this walk overwrites it:
                // the ring-young fallback below compares the two.
                let prevWalkFrame = lastHit[id] == nil ? frames[id]?.rect : nil
                if let f = r.frontFrame { touchFrame(id, f, at: t) }
                // Ghost ban (receipt at ghostWindowSecs).
                if let until = ghostBanUntil[id], t < until {
                    traceRecorder?.note(query: qi, .ghostBanned(window: id))
                }
                if let until = ghostBanUntil[id] {
                    if t < until { continue }
                    ghostBanUntil.removeValue(forKey: id)
                }
                // Size floor (receipt at minCurtainSize): thumbnail-scale
                // windows never accumulate hits; strip covers (parole) and
                // region covers own them.
                if let f = frames[id]?.rect, lastHit[id] == nil, belowFloor(f) {
                    traceRecorder?.note(query: qi, .windowBelowFloor(window: id))
                    continue
                }
                // TRAIL REDIRECTION (owner drag session 2026-08-20 23:00,
                // window 9184): during a fast drag, detection pixels lag the
                // window by up to ~100 ms, so blocked boxes land where the
                // dragged window WAS and attribute to whatever is behind.
                // Those hits starved the dragged curtain (hold expiry
                // mid-drag at 23:00:16), handed its containment trust to the
                // bystander (drop (handoff) 9184), and parole re-painted the
                // bystander for minutes afterward. A box attributed to an
                // UNCURTAINED window whose center sits inside the recent
                // swept path of a MOVING active curtain is that curtain's
                // trail evidence: it refreshes the curtain's hold and is not
                // credited to the bystander. A stationary curtain redirects
                // nothing (its path is its frame); the window in front of it
                // is handled by the capture-time check below (2026-09-09).
                if lastHit[id] == nil, !trails.isEmpty {
                    let c = CGPoint(x: merged[qi].rect.midX, y: merged[qi].rect.midY)
                    // DETERMINISTIC among overlapping trails
                    // (2026-09-11): `trails` is built by iterating `lastHit`, a
                    // Dictionary, so `first` picked an arbitrary curtain when a
                    // box's centre sat in two swept paths — the same run could
                    // credit either one. Most held first, ties by id: the
                    // curtain whose path holds more of the box is the better
                    // claim, and the id is the only total order available when
                    // two hold it equally.
                    //
                    // HONEST ABOUT WHICH LEG DOES THE WORK (review 2026-09-11):
                    // each candidate is scored on the UNION BOUNDING BOX of its
                    // swept frames, not on the path, so for any real drag —
                    // where the swept box is much larger than a detection — both
                    // candidates score heldFraction 1.0 and the decision is the
                    // id tie-break. Deliberate: the point of this fix was a
                    // REPRODUCIBLE answer, and a strict total order gives one
                    // either way. A path-exact score (union the per-frame
                    // intersections) would make the held-fraction leg mean
                    // something here; nothing has asked for it, and it would
                    // cost a per-frame sweep per candidate per box.
                    if let y = Self.bestHolder(
                        of: merged[qi].rect,
                        among: trails.filter { trail in
                            trail.frames.contains { $0.contains(c) }
                        }.map { (id: $0.id, rect: $0.frames.reduce(CGRect.null) { $0.union($1) }) })
                    {
                        traceRecorder?.note(query: qi, .trailRedirect(from: id, to: y))
                        lastHit[y] = t
                        // Loud (throttled at trailEventSecs): a redirect
                        // suppresses a window's attributed evidence — that
                        // must be explainable from the run's own output.
                        if t - (lastTrailEvent[id] ?? 0) > Self.trailEventSecs {
                            lastTrailEvent[id] = t
                            onChange?("trail-redirect (hit inside moving curtain \(y)'s path)", id)
                        }
                        continue
                    }
                }
                // CAPTURE-TIME ATTRIBUTION (owner report 2026-09-09; receipt
                // at frontCandidateSecs): the pixels behind this box were
                // captured ~70-100 ms before this walk, so the question is
                // "did this window hold the box THEN", asked of the ring —
                // not "who is in front NOW". A clean window dragged or
                // raised across a curtained window used to earn the
                // curtain's boxes and drop within triggerHits frames.
                if lastHit[id] == nil {
                    let box = merged[qi].rect
                    if let then = tracker.frameStrict(of: id, at: t) {
                        if WindowTracker.heldFraction(box, in: then)
                            < WindowTracker.minContainedFraction {
                            traceRecorder?.note(query: qi, .notHeldAtCapture(
                                window: id, ringYoung: false,
                                rewoundTo: traceRewindHolder(box, display: display, tracker: tracker)))
                            _ = rewind(box, from: id, reason: "hit at capture",
                                       display: display, tracker: tracker, at: t)
                            continue
                        }
                    } else if let prev = prevWalkFrame, let live = r.frontFrame, prev != live {
                        // Ring too young to reach back to `t`, but the window
                        // moved since the last walk: its capture-time frame
                        // is unknowable and the live one is exactly the skew
                        // this block removes. Not credited.
                        traceRecorder?.note(query: qi, .notHeldAtCapture(
                            window: id, ringYoung: true,
                            rewoundTo: traceRewindHolder(box, display: display, tracker: tracker)))
                        attributionCounters.ringYoungMoved += 1
                        _ = rewind(box, from: id, reason: "hit at capture (ring young)",
                                   display: display, tracker: tracker, at: t)
                        continue
                    } else {
                        // First sighting, or still between walks: today's
                        // behavior, counted so the fallback is visible in
                        // the 60 s summary.
                        attributionCounters.ringYoungCredited += 1
                    }
                }
                // PAROLE no longer drops here on a single attributed hit
                // (2026-09-02): a known offender's lower bar, `paroleHits`,
                // is applied in the trigger loop below with everyone else's.
                // One hit per window per frame: the trigger counts frames of
                // evidence, not boxes.
                traceRecorder?.note(query: qi, .credited(window: id))
                if let indices = merged[qi].sourceIndices {
                    var attributed = attributedThisFrame?[id] ?? []
                    attributed.append(contentsOf: indices)
                    attributedThisFrame?[id] = attributed
                }
                guard seenThisFrame.insert(id).inserted else { continue }
                hits[id, default: []].append((t, tick))
                if lastHit[id] != nil { lastHit[id] = t }
                // Transition bridge: a hit on a not-yet-curtained SUCCESSOR
                // (same containment rule as handoff — intersects readmitted
                // the bystanders round 1 evicted) expands the active curtain
                // it contains, so cover is continuous while the successor
                // accumulates its hits.
                if lastHit[id] == nil, let nf = frames[id]?.rect {
                    let tolerant = nf.insetBy(
                        dx: -Self.handoffTolerancePt, dy: -Self.handoffTolerancePt)
                    for (act, _) in lastHit {
                        // Same transition scoping as inheritsTrust (owner
                        // drag session 2026-08-20): a healthy curtain's
                        // containing bystander must not expand it either.
                        let inTransition = unlisted(act, tracker)
                            || deadSince[act] != nil || subFloorSince[act] != nil
                        guard inTransition, act != id, let af = frames[act]?.rect,
                            tolerant.contains(af)
                        else { continue }
                        extendExpansion(of: act, with: nf, kind: .bridge, at: t)
                    }
                }
            }
            // Transition SHIELD: shield-grade orphan evidence while an
            // active curtain's window is currently unlisted — the space
            // transition is animating content whose window nobody can name —
            // covers the whole display until the ambiguity clears.
            // Deliberate full-display blink; bounded by expansionSecs /
            // expansionCapSecs and, once a cap fires, held down for
            // expansionRearmCooldownSecs; maximally fail-safe.
            if !shieldOrphans.isNull {
                lastOrphanAt = t
                for (act, _) in lastHit where unlisted(act, tracker) {
                    extendExpansion(of: act, with: display, kind: .shield, at: t)
                }
            }
        }
        let windowFrames = windowFrames()
        for (id, times) in hits {
            // The frame arm counts only for a window WITHOUT a curtain — the
            // only state the trigger reads. An active curtain's ring stays
            // wall-clock pruned, so a lift never inherits starved-cadence
            // hits that would re-drop a parolee on one new hit
            // (`--ui-selftest` "parole: the first of two hits").
            let pending = lastHit[id] == nil
            let recent = times.filter {
                t - $0.t <= tuning.curtain.windowSecs || (pending && tick - $0.tick < windowFrames)
            }
            if recent.isEmpty {
                hits.removeValue(forKey: id)
                continue
            }
            hits[id] = recent
            let frame = frames[id]?.rect
            // Trigger-side floor (mw round 3): a stale hit ring must not
            // re-drop a window whose frame is sub-floor — without this, the
            // sub-floor lift and the <=1 s-old hits flapped drop/lift up to
            // five times a second (mw-2/mw-3 receipts).
            if let f = frame, belowFloor(f) {
                continue
            }
            // Evidence bar, lowest trust first: a handoff successor inherits
            // its predecessor's trust (handoffHits); a hit parolee is a known
            // offender (paroleHits, receipt there); anyone else earns the full
            // trigger. Handoff is tested first so the label names the trust a
            // 2-hit drop rode on — the two bars are equal by value only.
            let handoff = inheritsTrust(id, tracker: tracker, display: display, at: t)
            let onParole =
                handoff == nil && (frame.map { paroleMatches(id, $0, at: t) } ?? false)
            let required =
                handoff != nil
                    ? tuning.curtain.handoffHits : onParole ? hitParoleBar(id) : tuning.curtain.triggerHits
            if lastHit[id] == nil, recent.count >= required {
                // Ghost-breaker: a window the server cannot answer a direct
                // poll for must not be curtained. LOUD, and the id is banned
                // immediately (round 3: the silent `continue` here blocked a
                // REAL window's curtain forever in prw-2 with no trace —
                // limits must fail visibly).
                guard tracker.pollable(id) else {
                    ghostBanUntil[id] = t + Self.ghostBanSecs
                    hits.removeValue(forKey: id)
                    onChange?("ghost-ban (unpollable at drop)", id)
                    continue
                }
                lastHit[id] = t
                dropAt[id] = t
                cleanFrames[id] = 0
                // An active curtain is not on parole; its next lift re-arms it.
                parole.removeValue(forKey: id)
                let action: String
                switch handoff {
                case .contain:
                    action = "drop (handoff)"
                    handoffDrops.insert(id)
                case .restore(let predecessor):
                    // Spend the predecessor's one restore grant.
                    restoreGranted[predecessor] = (successor: id, at: t)
                    action = "drop (handoff restore)"
                case nil: action = onParole ? "drop (parole)" : "drop"
                }
                onDrop?(action, id, frame, attributedThisFrame?[id] ?? [])
                onChange?(action, id)
            }
        }
        }
        recentLifted = recentLifted.filter { t - $0.value.at <= Self.liftGraceSecs }
        // An overlapping window can hide unchanged Quick Look content.
        // Owner requirement 2026-09-16: focus/overlap does not release its
        // curtain. Reuse the hold and clean-frame state; death still runs below.
        let previewIDs = Set(lastHit.keys.filter { tracker.isQuickLookWindow($0) })
        let previewHolds = evaluated ? tracker.quickLookHolds(previewIDs) : []
        if evaluated {
            for id in lastHit.keys {
                if previewHolds.contains(id) {
                    lastHit[id] = t
                    cleanFrames[id] = 0
                } else if lastHit[id] == t {
                    cleanFrames[id] = 0
                } else if blockedScreenRects.isEmpty {
                    // A throttled ownership walk cannot prove which window a
                    // blocked detection belongs to. Count only globally clean
                    // detector frames; blocked non-walk frames are neutral.
                    cleanFrames[id] = (cleanFrames[id] ?? 0) + 1
                }
            }
            // Linger evidence (receipt at lingerCleanFrames; the dead-pending
            // counterpart is stamped in the lift loop below).
            for (id, l) in linger {
                linger[id]?.clean = cleanOver(l.frame) ? l.clean + 1 : 0
            }
            // Successor-linger evidence (receipt at `successorLinger`). The
            // FIRST evaluated frame after entry only sets `seen` — it is the
            // frame that first carries the revealed window's pixels, and
            // counting it would be the same mistake this rule exists to fix.
            for (id, l) in successorLinger {
                if !l.seen {
                    successorLinger[id]?.seen = true
                    successorLinger[id]?.clean = 0
                } else {
                    successorLinger[id]?.clean = cleanOver(l.frame) ? l.clean + 1 : 0
                }
            }
        }
        // NO PROMOTION of a hold-expiry parolee to return-shaped when its
        // window later leaves the stage.
        // Live (owner session
        // 2026-09-09, window 11405): `lift (hold 5.0s, 41 clean frames)` ->
        // relegated -> `strip-cover on` -> `drop (parole return)` on the
        // restore, four times — a window PROVEN clean by 41-79 detector frames
        // re-covered from geometry alone. A hold-expiry lift now stays hit
        // parole for its whole life (it is still watched via `watchIDs`), and
        // only a lift that itself saw the window leave (dead / sub-floor)
        // arms the geometry return.
        // Departed-rect evidence (receipt at lingerCleanFrames): a detector
        // frame with nothing blocked INSIDE the departed window's rect is one
        // clean frame for that rect; any intersecting box resets it. No
        // attribution needed — the window is gone, so the question is only
        // what the pixels where it was now show.
        func cleanOver(_ r: CGRect) -> Bool {
            !blockedScreenRects.contains { $0.intersects(r) }
        }
        var out: [(id: CGWindowID, frame: CGRect)] = []
        for (id, last) in lastHit {
            // Death debounce (receipt at deadLiftSecs): a transient
            // unlisting — the fullscreen space transition — must not lift.
            var deadLongEnough = false
            // Destroyed + clean evidence (receipt at destroyedLiftSecs).
            var closedClean = false
            if let kind = tracker.deadKind(id) {
                let since = deadSince[id] ?? t
                deadSince[id] = since
                if deadKinds[id] != kind {
                    deadKinds[id] = kind
                    onChange?("dead (\(kind.rawValue))", id)
                }
                if evaluated, let r = frames[id]?.rect {
                    deadClean[id] = cleanOver(r) ? (deadClean[id] ?? 0) + 1 : 0
                }
                let ceiling = kind == .destroyed ? Self.destroyedLiftSecs : Self.deadLiftSecs
                deadLongEnough = t - since >= ceiling
                closedClean = kind == .destroyed
                    && (deadClean[id] ?? 0) >= Self.lingerCleanFrames
            } else {
                deadSince.removeValue(forKey: id)
                deadKinds.removeValue(forKey: id)
                deadClean.removeValue(forKey: id)
            }
            let holdExpired = evaluated
                && t - last > tuning.curtain.holdSecs
                && (cleanFrames[id] ?? 0) >= tuning.curtain.holdCleanFrames
            if deadLongEnough || closedClean || holdExpired {
                let away = deadLongEnough || closedClean
                if let f = frames[id]?.rect {
                    recentLifted[id] = (frame: f, at: t, away: away)
                }
                if away {
                    // Ghost accounting (receipt at ghostWindowSecs).
                    var times = (deadLiftTimes[id] ?? []).filter {
                        t - $0 <= Self.ghostWindowSecs
                    }
                    times.append(t)
                    deadLiftTimes[id] = times
                    if times.count >= 2 {
                        ghostBanUntil[id] = t + Self.ghostBanSecs
                        onChange?("ghost-ban \(Int(Self.ghostBanSecs)) s", id)
                    }
                }
                // Arm parole (receipt at paroleSecs): a lift that saw the
                // window leave — the wall-clock dead lift or the destroyed +
                // clean-evidence close lift, i.e. `away` — is
                // relegation-shaped -> RETURN parole; hold expiry on a listed
                // window = content turned benign -> hit parole only, on the
                // EPISODE's clock (receipt at hitParoleSecs): a re-lift inside
                // the horizon keeps the first lift's arm time and raises the
                // bar, loudly.
                if let remembered = lastBigFrame[id] ?? frames[id]?.rect {
                    if away {
                        parole[id] = (frame: remembered, at: t, armedAt: t, away: true)
                    } else {
                        var episode = hitParoleEpisode[id] ?? (armedAt: t, lifts: 0)
                        episode.lifts += 1
                        hitParoleEpisode[id] = episode
                        parole[id] = (
                            frame: remembered, at: episode.armedAt, armedAt: episode.armedAt,
                            away: false)
                        if episode.lifts > 1 {
                            onChange?(
                                "parole-churn: \(episode.lifts) hold-expiry lifts inside "
                                + "hitParoleSecs \(Int(Self.hitParoleSecs)) s, re-drop bar "
                                + "\(hitParoleBar(id)) hits (fix: Curtain.hitParoleSecs)", id)
                        }
                    }
                }
                // Dead lifts LINGER (receipt at curtainLingerSecs); benign
                // hold-expiry lifts do not, and neither do the two
                // evidence-backed dead lifts below. Coalescing order differs
                // from parole's on purpose: parole wants the last ABOVE-floor
                // frame; linger wants where the window actually last was.
                var label = "lift (hold \(tuning.curtain.holdSecs)s, \(cleanFrames[id] ?? 0) clean frames)"
                if closedClean {
                    // The frames already proved the departed rect clean — but
                    // "clean" only means the DETECTOR saw nothing there, and
                    // if the close revealed another window those frames may
                    // predate its pixels. Receipt at `successorLinger`.
                    let departed = frames[id]?.rect ?? lastBigFrame[id]
                    let successor = departed.flatMap {
                        tracker.contentWindowIDs(
                            intersecting: $0, except: id,
                            transparentOwners: [WindowTracker.curtainTransparentOwner]
                        ).first
                    }
                    if let f = departed, let s = successor {
                        successorLinger[id] = (
                            frame: f, successor: s,
                            until: t + Self.successorLingerSecs, seen: false, clean: 0)
                        label = "linger (successor \(s))"
                    } else {
                        label = "lift (closed, \(deadClean[id] ?? 0) clean frames)"
                    }
                } else if deadLongEnough {
                    // TRANSIENT-HANDOFF RULE:
                    // six
                    // `drop (handoff)` → `lift (linger)` pairs 2-3 s apart on
                    // fresh ids that inherited a curtain through the contain
                    // arm and died within ~0.5 s — five inside 46 s, a ~33%
                    // black duty cycle over the desktop. A curtain that was
                    // ALIVE for less than deadLiftSecs before it went dead
                    // was itself the transient, and there is no successor
                    // gap for a linger to bridge; the handoff drop stays
                    // (the cover while it lived was right). Lifetime is
                    // drop → first dead poll, not drop → lift, so the dead
                    // wait itself cannot age a transient past the bar.
                    // CONTAIN-ARM HANDOFF DROPS ONLY: a fresh 3-hit curtain
                    // that leaves the stage inside 1.5 s is the fullscreen
                    // ENTER predecessor the linger exists to bridge, and a
                    // restore-arm successor is the restored window itself.
                    let lifetime = (deadSince[id] ?? t) - (dropAt[id] ?? t)
                    if handoffDrops.contains(id), lifetime < Self.deadLiftSecs {
                        label = String(format: "lift (transient, lived %.2f s)", lifetime)
                        transientLifts = transientLifts.filter { t - $0 <= Self.ghostWindowSecs }
                        transientLifts.append(t)
                        onChange?(
                            "transient-handoff churn: \(transientLifts.count) transient "
                            + "curtain(s) lifted in \(Int(Self.ghostWindowSecs)) s", 0)
                    } else if let f = frames[id]?.rect ?? lastBigFrame[id] {
                        linger[id] = (frame: f, until: t + Self.curtainLingerSecs, clean: 0)
                        label = "lift (linger)"
                    }
                }
                dropCurtainState(id, at: t)
                onChange?(label, id)
                continue
            }
            if let f = tracker.latestFrame(of: id) { touchFrame(id, f, at: t) }
            // Sub-floor lift with HYSTERESIS (receipts at minCurtainSize and
            // subFloorLiftSecs): the tiny geometry must persist before the
            // curtain hands off to region covers — a geometry blip on a
            // visually stationary window must not lift. The lift records
            // PAROLE with the last above-floor frame (owner idea).
            if let f = frames[id]?.rect, belowFloor(f) {
                let since = subFloorSince[id] ?? t
                subFloorSince[id] = since
                if t - since >= Self.subFloorLiftSecs {
                    // Relegation-shaped: the window left the stage (same flag
                    // parole arms with). The restore arm reads it but can
                    // never match a sub-floor frame — it is below the display
                    // scale gate by construction.
                    recentLifted[id] = (frame: f, at: t, away: true)
                    if let big = lastBigFrame[id] {
                        parole[id] = (frame: big, at: t, armedAt: t, away: true)
                    }
                    dropCurtainState(id, at: t)
                    onChange?("lift (sub-floor)", id)
                    continue
                }
            } else {
                subFloorSince.removeValue(forKey: id)
                if let f = frames[id]?.rect { lastBigFrame[id] = f }
            }
            var outFrame = frames[id]?.rect
            if let e = expansion[id] {
                if t < e.until {
                    outFrame = outFrame.map { $0.union(e.rect) } ?? e.rect
                } else {
                    expansion.removeValue(forKey: id)
                }
            }
            if let f = outFrame { out.append((id, f)) }
        }
        // STRIP COVERS (owner request 2026-08-20 "the stage manager region
        // paint should remain as long as that window is there"): a RETURN
        // parolee visible at thumbnail scale keeps a deterministic,
        // id-tracked cover on its strip thumbnail — the detector cannot see
        // thumbnail-scale content (the accepted strip blind spot), but the
        // 120 Hz tracker can. While the thumbnail stays listed, the parole
        // entry does not age; it resumes aging the moment the window
        // unlists, so a closed window still expires at paroleSecs — and
        // whatever happens, `paroleHardCapSecs` from the arm ends it. Runs
        // BEFORE the linger emit and supersedes the id's linger entry —
        // one id must appear once in the output (altitude review
        // 2026-08-20: a dead lift can arm linger AND parole, and the
        // duplicate id trapped downstream).
        var stripNow = Set<CGWindowID>()
        for (id, p) in parole where p.away && lastHit[id] == nil {
            guard let f = tracker.latestFrame(of: id),
                tracker.missStreak(of: id) == 0, belowFloor(f)
            else { continue }
            parole[id]?.at = t
            linger.removeValue(forKey: id)
            stripNow.insert(id)
            if !stripActive.contains(id) { onChange?("strip-cover on", id) }
            out.append((id, f))
        }
        for id in stripActive.subtracting(stripNow) {
            onChange?("strip-cover off (parole aging resumes)", id)
        }
        stripActive = stripNow
        // LIFT-LINGER output (receipt at curtainLingerSecs): pruned on
        // expiry or when the id re-drops (the live curtain supersedes it).
        for (id, l) in linger where l.clean >= Self.lingerCleanFrames {
            linger.removeValue(forKey: id)
            onChange?("linger off (\(l.clean) clean frames)", id)
        }
        linger = linger.filter { t < $0.value.until && lastHit[$0.key] == nil }
        for (id, l) in linger { out.append((id, l.frame)) }
        // SUCCESSOR-LINGER exits (receipt at `successorLinger`), in signal
        // order. Signal 1 is tested first and this block runs AFTER the drop
        // loop, so a successor that drops on this very frame ends the hold on
        // this very frame — its own curtain is already in `out`.
        for (id, l) in successorLinger {
            let label: String
            if lastHit[l.successor] != nil {
                label = "lift (successor curtained)"
            } else if l.seen, l.clean >= Self.lingerCleanFrames {
                label = "lift (successor clean, \(l.clean) frames)"
            } else if t >= l.until {
                label = "lift (successor ceiling)"
            } else {
                continue
            }
            successorLinger.removeValue(forKey: id)
            onChange?(label, id)
        }
        // Same guard as the linger above: a departed id that somehow re-drops
        // is covered by the live curtain, not by this.
        successorLinger = successorLinger.filter { lastHit[$0.key] == nil }
        for (id, l) in successorLinger { out.append((id, l.frame)) }
        // Watch-budget tripwire (receipt at watchBudgetIDs). Edge-triggered
        // both ways so a sustained breach logs once, not per tick.
        let watching = watchIDs.count
        if watching > Self.watchBudgetIDs, !watchOverBudget {
            watchOverBudget = true
            onChange?(
                "watch-budget: limit \(Self.watchBudgetIDs) ids, observed \(watching) "
                + "(~1.26%/core each, tracker headroom exhausted near 5 — "
                + "ASSUMED math; remeasure via sched telemetry, "
                + "fix: Curtain.watchBudgetIDs)", 0)
        } else if watching <= Self.watchBudgetIDs, watchOverBudget {
            watchOverBudget = false
            onChange?("watch-budget: back under limit (\(watching) ids)", 0)
        }
        return out.sorted { $0.id < $1.id }
    }

    struct AttributedRect {
        var rect: CGRect
        var sourceIndices: [Int]?
    }

    /// Same pairwise union and threshold as `Geometry.merge`, with source
    /// indices carried only for the DEV crop observer. The rect result stays
    /// identical to the pre-observer curtain input.
    static func mergeAttributed(
        _ rects: [CGRect], sourceIndices: [Int], iouOver: CGFloat
    ) -> [AttributedRect] {
        var merged = zip(rects, sourceIndices).map {
            AttributedRect(rect: $0.0, sourceIndices: [$0.1])
        }
        var changed = true
        while changed {
            changed = false
            outer: for i in merged.indices {
                for j in merged.indices where j > i {
                    if Geometry.iou(merged[i].rect, merged[j].rect) > iouOver {
                        let rightIndices = merged[j].sourceIndices ?? []
                        merged[i].rect = merged[i].rect.union(merged[j].rect)
                        merged[i].sourceIndices?.append(contentsOf: rightIndices)
                        merged.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return merged
    }

    /// Idle eviction for the four caches that otherwise only clear on
    /// reset() (receipt at sweepEverySecs / paroleSecs). Mirrors the same
    /// filter-by-age pattern already used per-tick for parole/recentLifted/
    /// linger/hits in this file — just gated to run at most once per
    /// sweepEverySecs instead of every tick.
    private func sweepIdle(tracker: WindowTracker, at t: CFAbsoluteTime) {
        // lastSweepAt starts at 0 (init and reset()), so a wall-clock `t`
        // makes the very first tick (and the first tick after a panic
        // reset) always sweep — harmless, since all four caches are empty
        // at both points; it just means "at most once per sweepEverySecs"
        // is really "immediately, then at most once per sweepEverySecs".
        guard t - lastSweepAt >= Self.sweepEverySecs else { return }
        lastSweepAt = t
        let before =
            ghostBanUntil.count + deadLiftTimes.count + lastTrailEvent.count + frames.count
        // ghostBanUntil: ban deadline itself passed more than paroleSecs ago
        // (receipt at paroleSecs) — an id still within paroleSecs of its ban
        // expiring could still be re-encountered as the same known offender.
        ghostBanUntil = ghostBanUntil.filter { t - $0.value <= Self.paroleSecs }
        // deadLiftTimes: ghost-accounting evidence (receipt at
        // ghostWindowSecs) older than paroleSecs — keyed on the entry's
        // freshest recorded lift, not its oldest.
        deadLiftTimes = deadLiftTimes.filter { t - ($0.value.max() ?? 0) <= Self.paroleSecs }
        // lastTrailEvent: loudness throttle timestamps (receipt at
        // trailEventSecs) older than paroleSecs.
        lastTrailEvent = lastTrailEvent.filter { t - $0.value <= Self.paroleSecs }
        lastRewindEvent = lastRewindEvent.filter { t - $0.value <= Self.paroleSecs }
        // frames: never touch an active curtain's frame (lastHit[id] != nil).
        // `unlisted(id, tracker)` only answers for ids the tracker is
        // actually polling (watchIDs = active curtains + every parolee,
        // receipt there) — for the leaking population (ids seen once in an
        // attribution walk, never curtained) it is trivially true, since
        // `latestFrame` is nil for anything untracked. That is fine here:
        // the operative safety condition is the untouched-for-paroleSecs
        // check, which alone already means no code path in this class has
        // read or refreshed the id in 300 s; `unlisted` only adds a real
        // extra guard for the (currently-curtained-adjacent) ids the
        // tracker does watch.
        frames = frames.filter { id, entry in
            lastHit[id] != nil || t - entry.at <= Self.paroleSecs || !unlisted(id, tracker)
        }
        let after =
            ghostBanUntil.count + deadLiftTimes.count + lastTrailEvent.count + frames.count
        let evicted = before - after
        // Loud only above sweepLogThreshold (receipt there): the common
        // case (single-digit churn) logs nothing.
        if evicted > Self.sweepLogThreshold {
            onChange?(
                "sweep: evicted \(evicted) idle entries (threshold "
                + "\(Self.sweepLogThreshold), retention paroleSecs=\(Int(Self.paroleSecs))s, "
                + "fix: Curtain.sweepLogThreshold)", 0)
        }
    }

    /// The one definition of "thumbnail-scale" (receipt at minCurtainSize).
    private func belowFloor(_ f: CGRect) -> Bool {
        f.width < Self.minCurtainSize.width || f.height < Self.minCurtainSize.height
    }

    /// Shared lift bookkeeping: everything an id owns except recentLifted
    /// and parole, which each lift path decides for itself.
    private func dropCurtainState(_ id: CGWindowID, at t: CFAbsoluteTime) {
        hits.removeValue(forKey: id)
        lastHit.removeValue(forKey: id)
        frames.removeValue(forKey: id)
        deadSince.removeValue(forKey: id)
        expansion.removeValue(forKey: id)
        expansionCooldown.removeValue(forKey: id)
        subFloorSince.removeValue(forKey: id)
        lastBigFrame.removeValue(forKey: id)
        cleanFrames.removeValue(forKey: id)
        deadKinds.removeValue(forKey: id)
        deadClean.removeValue(forKey: id)
        dropAt.removeValue(forKey: id)
        handoffDrops.remove(id)
    }

    /// LIFT-LINGER (owner request 2026-08-20: "keep the full screen painted
    /// with a small delay before the paint disappears"): a DEAD-flavor lift
    /// — the fullscreen enter/exit space transition, or a real close —
    /// keeps painting its last frame for this long, so the gap between the
    /// predecessor's lift and the successor's drop (enter handoff receipts
    /// 0.1-0.7 s; exit parole-return <1 s) shows curtain, not content.
    /// Cost: a genuinely closed window leaves a black rectangle for this
    /// long over whatever is behind — over-cover, fail-safe, bounded here.
    /// Hold-expiry lifts (content turned benign, window on stage) do NOT
    /// linger. 1.5 s = the slowest measured successor cover with margin.
    /// Since 2026-09-09 this is the CEILING: a linger also ends after
    /// `lingerCleanFrames` evaluated frames with nothing blocked inside its
    /// rect ("linger off"), and two dead lifts skip it altogether — a
    /// destroyed window whose rect already read clean ("lift (closed …)")
    /// and a transient ("lift (transient …)"); receipts at those symbols.
    static let curtainLingerSecs: CFTimeInterval = 1.5
    private var linger: [CGWindowID: (frame: CGRect, until: CFAbsoluteTime, clean: Int)] = [:]
    /// A frame-less tick must keep running until these geometry-only covers
    /// expire or leave the strip.
    var hasLinger: Bool { !linger.isEmpty || !successorLinger.isEmpty || !stripActive.isEmpty }
    /// Ids currently wearing a strip cover, for the on/off loudness events.
    private var stripActive: Set<CGWindowID> = []

    /// Trail window (receipt at the TRAIL REDIRECTION call site): path
    /// depth and the motion gate. 0.2 s covers the measured <=100 ms pixel
    /// lag with 2x margin. 24 pt of spread beyond the current frame
    /// separates a real drag from frame jitter.
    /// MEASURED 2026-09-08, test Mac, source main 3ae5a64, nine shielded `fast`
    /// runs:
    /// the
    /// jitter half of this receipt holds. `score_lead.py` classified 10,486
    /// curtain paints across those runs as PARKED (no commanded move within
    /// 0.5 s), and their over-extension past the window's own rect is 0.0 pt
    /// — not one parked paint carried any swept extension. A lead can only
    /// appear when the ring saw two DISTINCT frames inside
    /// `Overlay.curtainStillSecs`, so a still window's ring frames are
    /// bit-identical, not merely sub-point. 24 pt therefore sits above a
    /// jitter floor of 0, not above a measured jitter magnitude.
    /// DERIVED, and NOT simply 24 pt / 0.2 s: `movingTrails` below takes the
    /// 8 most recent DISTINCT ring samples and THEN filters by
    /// `trailPathSecs`, so the path window is min(8 distinct samples, 0.2 s)
    /// and the admitted speed is 24 pt over THAT window —
    ///   * 120 pt/s when the 0.2 s term binds, which is the case on a test Mac
    ///     today: the poll loop advances at 33.6-40.5 Hz (WindowTracker
    ///     receipt at `lateTolerance`), so 8 distinct samples cannot span
    ///     less than ~0.2 s;
    ///   * ~180 pt/s if distinct frames land at a 60 Hz display rate, and
    ///     ~360 pt/s on the healthy 120 Hz ring this class assumes, where 8
    ///     samples span ~66 ms.
    /// The floor is therefore 120-360 pt/s depending on how fast the RING is,
    /// and the optimistic 120 is a symptom of a degraded poll loop rather
    /// than a property of this gate. NOT CHECKED: the ring's actual
    /// distinct-commit rate during a drag — it is not logged, so the bound
    /// above is derived from the measured poll cadence. Either way this
    /// harness only scripts 1000-1500 pt/s, 3-12x past the gate, so the
    /// "does a slow human drag clear 24 pt" question is still open, and it is
    /// the 360 pt/s end that must be re-measured against. If slow drags move less,
    /// redirection quietly stops applying to them and the pre-redirection
    /// starvation symptoms return — remeasure from a drag log before
    /// changing. Trail frames come from
    /// the tracker's own 120 Hz ring (recentDistinctSamples) — a hand-kept
    /// 30 Hz copy duplicated it at 4x coarser fidelity (reuse review
    /// 2026-08-20). Containment tests the INDIVIDUAL path frames, not
    /// their bounding union: a diagonal drag's union contains corners the
    /// window never occupied, and a second window's evidence there must
    /// not be redirected (altitude review 2026-08-20).
    private static let trailPathSecs: CFTimeInterval = 0.2
    private static let trailMotionPt: CGFloat = 24
    /// Loudness throttle: one trail-redirect event per redirected-from id
    /// per this many seconds (a drag redirects per box per frame — per-hit
    /// events would be hundreds/s of log spam).
    private static let trailEventSecs: CFTimeInterval = 5.0
    private var lastTrailEvent: [CGWindowID: CFAbsoluteTime] = [:]

    /// CAPTURE-TIME ATTRIBUTION (owner report 2026-09-09: a clean window
    /// dragged or raised over a curtained window got its own curtain).
    /// Mechanism: the detector never sees our overlay (Capture.refreshExclusion,
    /// SPEC "self-feedback guard"), so a curtained window's content emits
    /// blocked boxes continuously; the walk resolved them against a LIVE
    /// snapshot taken ~70-100 ms after the pixels (capture -> walk latency,
    /// 13-14 fps on a test Mac; the drag receipt at trailMotionPt documents the
    /// same skew), so a window that had moved over the box by then was
    /// credited with it. Trail redirection only covers a MOVING curtain.
    /// The fix asks the ring where the candidate was AT CAPTURE
    /// (`WindowTracker.frameStrict`), which needs the candidate polled
    /// before its first box: `watchIDs` therefore adds the topmost listed
    /// window each walk sees (a dragged/raised window is the topmost) and
    /// every window with pending hits.
    /// frontCandidateSecs — how long the topmost id stays polled after the
    /// last walk that saw it. DERIVED: it must outlive any pending hit it
    /// could be asked about (`windowSecs` 1.0 s, 2x margin) and need not
    /// exceed the ring's own span (256 samples at 120 Hz = 2.13 s). Cost is
    /// one tracked id, 1.26%/core (WindowTracker header), only while blocked
    /// boxes are flowing at all — no walk, no candidate.
    /// Ring-young fallback: when the ring holds no sample at or before `t`
    /// (tracking began after the capture), a window that has NOT moved since
    /// the previous walk is credited as before and a window that HAS moved
    /// is not; both are counted (`takeAttributionCounters`, 60 s summary as
    /// curtainRingYoungCredited / curtainRingYoungMoved). The moved branch
    /// is load-bearing at 30 fps: three young walks fit inside the 100 ms
    /// lag, which is exactly `triggerHits`. Not credited is never a silent
    /// cap: a rewound box refreshes the curtain it belongs to and logs
    /// `attribution-rewind`, throttled like trail-redirect (trailEventSecs).
    static let frontCandidateSecs: CFTimeInterval = 2.0
    private var frontCandidate: (id: CGWindowID, at: CFAbsoluteTime)?
    private var lastRewindEvent: [CGWindowID: CFAbsoluteTime] = [:]
    private var attributionCounters = (ringYoungCredited: 0, ringYoungMoved: 0)

    /// Counters since the last take — the frame path reports them
    /// (Logger.count is detectQueue-only, same thread as `update`).
    func takeAttributionCounters() -> (ringYoungCredited: Int, ringYoungMoved: Int) {
        defer { attributionCounters = (0, 0) }
        return attributionCounters
    }

    /// The topmost id the last walk saw, for the selftest and the log.
    var frontCandidateID: CGWindowID? { frontCandidate?.id }

    /// Which of `candidates` has the best claim on `box`: the one holding the
    /// largest fraction of it, ties broken by the smaller window id.
    ///
    /// Receipt for existing at all (2026-09-11): both callers used
    /// to take `.first` out of a Dictionary iteration, so when a detection sat
    /// inside two overlapping curtains the attribution was whatever order the
    /// hash gave that run — unreproducible from the log, and it decides which
    /// curtain's hold is refreshed. Ranking by held fraction is the same
    /// question `minContainedFraction` already asks; the id is the tie-break
    /// because it is the only total order two equally-holding windows have.
    /// Candidates are pre-filtered by the caller: this orders, it does not
    /// judge.
    static func bestHolder(
        of box: CGRect, among candidates: [(id: CGWindowID, rect: CGRect)]
    ) -> CGWindowID? {
        var best: (id: CGWindowID, held: CGFloat)?
        for c in candidates {
            let held = WindowTracker.heldFraction(box, in: c.rect)
            guard let b = best else { best = (c.id, held); continue }
            if held > b.held || (held == b.held && c.id < b.id) { best = (c.id, held) }
        }
        return best?.id
    }

    /// A box that is NOT `id`'s evidence, refreshed onto the active curtain
    /// whose CONTENT rect holds >= minContainedFraction of it (the strip is
    /// visible and stays region territory). Returns whether a curtain took it.
    private func rewind(
        _ box: CGRect, from id: CGWindowID, reason: String, display: CGRect, tracker: WindowTracker, at t: CFAbsoluteTime
    ) -> Bool {
        // DETERMINISTIC among overlapping curtains (2026-09-11):
        // `lastHit.keys.first` is Dictionary order, so two overlapping content
        // rects that both hold the box made this a coin toss between them.
        let holder = Self.bestHolder(
            of: box,
            among: lastHit.keys.compactMap { y in
                guard let f = frames[y]?.rect else { return nil }
                let content = Self.contentRect(window: f, display: display, quickLook: tracker.isQuickLookWindow(y))
                // The bar is unchanged: only a curtain whose CONTENT rect holds
                // most of the box is a candidate at all. `bestHolder` only
                // orders the candidates.
                guard WindowTracker.heldFraction(box, in: content)
                    >= WindowTracker.minContainedFraction
                else { return nil }
                return (id: y, rect: content)
            })
        guard let y = holder else { return false }
        lastHit[y] = t
        if t - (lastRewindEvent[id] ?? 0) > Self.trailEventSecs {
            lastRewindEvent[id] = t
            onChange?("attribution-rewind (\(reason) belonged to curtain \(y))", id)
        }
        return true
    }

    /// The moving active curtains' recent path frames, computed once per
    /// walk (efficiency review 2026-08-20: per-box recomputation).
    private func movingTrails(tracker: WindowTracker, at t: CFAbsoluteTime)
        -> [(id: CGWindowID, frames: [CGRect])]
    {
        var trails: [(id: CGWindowID, frames: [CGRect])] = []
        for y in lastHit.keys {
            guard let cur = tracker.latestFrame(of: y) else { continue }
            let recent = tracker.recentDistinctSamples(of: y, count: 8)
                .filter { t - $0.t <= Self.trailPathSecs }
            guard recent.count >= 2 else { continue }
            let swept = recent.reduce(cur) { $0.union($1.frame) }
            guard swept.width - cur.width > Self.trailMotionPt
                || swept.height - cur.height > Self.trailMotionPt
            else { continue }
            trails.append((y, recent.map(\.frame)))
        }
        return trails
    }

    /// Parole match (hit flavor): same id, or any window whose returned
    /// frame lands within paroleMatchPt per edge of a RETURN parolee's
    /// remembered frame (receipt at paroleSecs). The cross-id rule is scoped
    /// to `away` entries since 2026-09-09: it was written for a window that
    /// leaves and is re-created at its old frame under a new id (receipt at
    /// `restoreShaped`, fs-pret-reg1), and applied to hit parole it let two
    /// cycling Chrome windows at matching frames share each other's lowered
    /// bar (owner session 2026-09-09, windows 11499/11641). A hit parolee
    /// matches by id only. Pruning happens once per advance().
    private func paroleMatches(_ id: CGWindowID, _ f: CGRect, at t: CFAbsoluteTime) -> Bool {
        if parole[id] != nil { return true }
        for (_, entry) in parole where entry.away {
            let p = entry.frame
            if abs(f.minX - p.minX) <= Self.paroleMatchPt,
                abs(f.minY - p.minY) <= Self.paroleMatchPt,
                abs(f.width - p.width) <= Self.paroleMatchPt,
                abs(f.height - p.height) <= Self.paroleMatchPt {
                return true
            }
        }
        return false
    }

    /// Grow (never shrink) `act`'s expansion and refresh its deadline —
    /// unless the hard cap has passed, which drops the entry loudly and
    /// starts a shield re-arm cooldown instead (review 2026-08-20, P2:
    /// refresh ratcheting; receipt at expansionRearmCooldownSecs: without
    /// the cooldown the very next walk re-armed the entry with a fresh clock
    /// and the cap bounded nothing). The cooldown refuses SHIELD expansions
    /// only — a bridge keeps a named successor covered and was never priced
    /// by either receipt.
    private func extendExpansion(
        of act: CGWindowID, with rect: CGRect, kind: ExpansionKind, at t: CFAbsoluteTime
    ) {
        if let cooldown = expansionCooldown[act] {
            if t >= cooldown.until {
                expansionCooldown.removeValue(forKey: act)
            } else if kind == .shield {
                if !cooldown.logged.contains(kind) {
                    expansionCooldown[act]?.logged.insert(kind)
                    onChange?(
                        "expansion-rearm refused: \(kind.rawValue) expansion, budget "
                        + "expansionRearmCooldownSecs "
                        + String(format: "%.1f s, %.1f s left after the ",
                            Self.expansionRearmCooldownSecs, cooldown.until - t)
                        + "\(Self.expansionCapSecs) s cap "
                        + "(fix: Curtain.expansionRearmCooldownSecs)", act)
                }
                return
            }
        }
        // No entry ⇒ firstAt == t ⇒ the cap test below is false, so this
        // branch is only ever reached with a live entry older than the cap.
        let firstAt = expansion[act]?.firstAt ?? t
        if t - firstAt > Self.expansionCapSecs {
            expansion.removeValue(forKey: act)
            // Armed whichever kind hit the cap: a bridge-fired cap that left
            // the cooldown unarmed would let the shield union the display
            // back in on the very same walk — the hole this branch closes.
            expansionCooldown[act] =
                (until: t + Self.expansionRearmCooldownSecs, logged: [])
            onChange?(
                "expansion-cap: budget expansionCapSecs \(Self.expansionCapSecs) s hit"
                + String(format: " (held %.1f s, %@ expansion) ", t - firstAt, kind.rawValue)
                + "(fix: Curtain.expansionCapSecs); shield re-arm refused for "
                + "\(Self.expansionRearmCooldownSecs) s "
                + "(fix: Curtain.expansionRearmCooldownSecs)", act)
            return
        }
        let mergedRect = expansion[act].map { $0.rect.union(rect) } ?? rect
        expansion[act] = (rect: mergedRect, until: t + Self.expansionSecs, firstAt: firstAt)
    }

    /// Which trust path a 2-hit drop rode on, so the log can name it.
    enum HandoffKind {
        /// `id` CONTAINS the predecessor — fullscreen enter, grow, respawn.
        case contain
        /// `id` is CONTAINED BY a departing display-scale predecessor —
        /// fullscreen exit (receipt at `restoreShaped`). Carries the
        /// predecessor because the drop spends its ONE restore grant.
        case restore(from: CGWindowID)
    }

    /// Handoff eligibility, two arms.
    ///
    /// CONTAIN (unchanged): `id`'s frame contains (`handoffTolerancePt`) the
    /// frame of a curtain IN TRANSITION — unlisted, dead-pending, or sub-floor-
    /// pending — or of a curtain lifted within liftGraceSecs. A HEALTHY
    /// active curtain grants no trust (owner drag session 2026-08-20,
    /// predicted by review P3-9): dragging a curtained window across a
    /// larger background window let edge-straddling hits + containment give
    /// the BACKGROUND window a 2-hit handoff curtain (the owner's Gmail
    /// window, id 9184, painted for 5 s). A real fullscreen successor still
    /// inherits — its predecessor is unlisted mid-transition.
    ///
    /// RESTORE (2026-09-08, closes the "review P3" gap): the mirror case, with
    /// two extra guards the contain arm does not need — see `restoreShaped`.
    private func inheritsTrust(
        _ id: CGWindowID, tracker: WindowTracker, display: CGRect, at t: CFAbsoluteTime
    ) -> HandoffKind? {
        guard let f = frames[id]?.rect else { return nil }
        let tolerant = f.insetBy(dx: -Self.handoffTolerancePt, dy: -Self.handoffTolerancePt)
        var restore: CGWindowID?
        for (act, _) in lastHit where act != id {
            guard let af = frames[act]?.rect else { continue }
            let leaving = unlisted(act, tracker) || deadSince[act] != nil
            let inTransition = leaving || subFloorSince[act] != nil
            if inTransition, tolerant.contains(af) { return .contain }
            if leaving, restore == nil, restoreArmed(act, at: t), restoreFree(act, for: id),
                restoreShaped(successor: f, predecessor: af, display: display) {
                restore = act
            }
        }
        for (act, entry) in recentLifted where act != id {
            if tolerant.contains(entry.frame) { return .contain }
            if entry.away, restore == nil, restoreFree(act, for: id),
                restoreShaped(successor: f, predecessor: entry.frame, display: display) {
                restore = act
            }
        }
        // CONTAIN wins the label when both match: it is the older, better
        // evidenced arm, and the two bars are equal by value (handoffHits).
        return restore.map { .restore(from: $0) }
    }

    /// The restore arm's TIME bound, enforced rather than assumed (receipt at
    /// `restoreShaped`): a still-active predecessor grants restore trust for
    /// `deadLiftSecs` after its first leaving frame. If it really is gone its
    /// dead lift fires at exactly that mark and `recentLifted` carries the
    /// grant `liftGraceSecs` further, so one departure episode arms the lower
    /// bar for at most deadLiftSecs + liftGraceSecs — whatever the miss cause.
    private func restoreArmed(_ act: CGWindowID, at t: CFAbsoluteTime) -> Bool {
        guard let since = leavingSince[act] else { return false }
        return t - since <= Self.deadLiftSecs
    }

    /// The restore arm's BREADTH bound: one successor per departing
    /// predecessor (receipt at `restoreShaped`).
    private func restoreFree(_ act: CGWindowID, for id: CGWindowID) -> Bool {
        restoreGranted[act].map { $0.successor == id } ?? true
    }

    /// RESTORE-direction trust (P3 gap, closed 2026-09-08).
    ///
    /// THE GAP: handoff trust flowed only successor-contains-predecessor, so
    /// a fullscreen EXIT — the departing curtain is the whole display, the
    /// successor is the smaller restored window inside it — could not inherit
    /// and paid `triggerHits`. The other restore shapes were never in the gap:
    /// Stage Manager restore and un-minimize keep the SAME window id, so
    /// RETURN parole re-drops them on geometry alone with no detector evidence
    /// at all (receipt at paroleSecs), and a restore that re-creates the window
    /// at its old frame is caught by cross-id parole hit-match within
    /// paroleMatchPt. What was left is
    /// exactly the exit whose windowed frame was never itself curtained.
    ///
    /// THE RULE, deliberately narrower than the contain arm in FOUR ways
    /// because reverse containment is a much wider net (every window on a
    /// display sits inside a fullscreen frame, whereas few windows contain
    /// one):
    ///  1. The predecessor must be LEAVING — unlisted or dead-pending, or
    ///     lifted `away` within liftGraceSecs. A sub-floor-pending (relegated)
    ///     predecessor grants nothing: its frame is below `minCurtainSize`, so
    ///     nothing above the floor fits inside it anyway.
    ///  2. The predecessor must BE the display (`coversDisplay`). Without this
    ///     the arm would arm on every ordinary window close or drag-off, which
    ///     is the shape that produced the Gmail false positive on the contain
    ///     side.
    ///  3. TIME (`restoreArmed`, review 2026-09-08): at most `deadLiftSecs`
    ///     from the predecessor's first leaving frame, then at most
    ///     `liftGraceSecs` more through `recentLifted` — 3.5 s per departure
    ///     episode. Without this the bound below would be a claim rather than
    ///     a fact: `unlisted` counts misses of any cause while
    ///     `WindowTracker.isDead` needs `.unknownID`, so an `.apiFailed`
    ///     streak reads leaving with no dead lift to end it, and a whole
    ///     display would sit on the lower bar for as long as the streak
    ///     lasted (the `uncertainTripwire` is loud about the streak, but a
    ///     tripwire is not a bound).
    ///  4. BREADTH (`restoreFree`, review 2026-09-08): ONE successor per
    ///     departing predecessor may SPEND the lower bar. Stated exactly,
    ///     because the cap is narrower than the sentence first reads
    ///     (review 2026-09-09): `restoreGranted[predecessor]` is written
    ///     only when a drop actually takes the grant, and `restoreFree`
    ///     answers true for everyone until then — so until that first drop,
    ///     EVERY window inside the departing frame sits on the 2-hit bar at
    ///     once. What the cap bounds is how many windows can DROP on that
    ///     bar (one per departure episode), not how many are eligible for
    ///     it. Realized risk, exactly: inside the 3.5 s episode the FIRST
    ///     window to reach `handoffHits` attributed hits drops at that bar —
    ///     restored or not — and every other window is back on `triggerHits`
    ///     the moment it does. Without the cap the whole display would stay
    ///     on the lower bar for the full 3.5 s instead. Cost of the cap: if
    ///     a false positive spends the grant first, the real restored window
    ///     pays `triggerHits` — one detector frame (33 ms at 30 fps), which
    ///     is the entire benefit this arm buys anyway.
    ///
    /// FALSE-POSITIVE COST, stated plainly. For at most 3.5 s per departure
    /// episode of a display-scale curtain, the FIRST other window revealed by
    /// that exit to earn 2 attributed hits drops at `handoffHits` instead of
    /// `triggerHits`. The 2026-09-02 live soak's false-positive episodes were
    /// 6 / 2 / 2 / 3 frames long (receipt at `paroleHits`), so a 2-frame
    /// explicit-class FP inside that window now curtains its window for
    /// holdSecs (5 s) where the 3-hit bar would have rejected it. Bounded by
    /// the same guards every drop has: frontHoldsGate >= 75%, above
    /// `minCurtainSize`, `pollable`, and trail redirection. The live count of
    /// `drop (handoff restore)` on windows that are NOT the restored one is
    /// the number that decides whether the arm stays: MEASURED 0 in 4/4 test Mac
    /// runs of the shielded `restore` / `restore_late` modes,
    /// with the caveat recorded there that
    /// those runs stage exactly one candidate successor — that number bounds
    /// the one-grant cap, not a household false-positive rate.
    ///
    /// BENEFIT, DERIVED, not measured — and small: one attributed detector
    /// frame (`Curtain.handoffSavedMs`). The transition keeps the walk at full
    /// rate (`transitionActive`), so that is 33 ms at 30 fps / 67 ms at 15 fps;
    /// with the walk bypass muted it is up to `walkEvery` frames. For the first
    /// deadLiftSecs + curtainLingerSecs = 3.0 s after the predecessor unlists,
    /// the predecessor's own floating/lingering display-sized curtain still
    /// covers the successor entirely, so this saving is only visible on an exit
    /// whose restored content stays detector-blind past that (the documented
    /// stale-snapshot restore, live-sanity 2026-08-20). MEASURED on a test Mac
    /// 2026-09-08: the successor's `drop (handoff restore)` landed +0.31-0.39 s
    /// after the display-scale predecessor left, i.e. ~1.1 s BEFORE that
    /// predecessor's own dead lift, with 0 uncovered blocking frames — so the
    /// saving is real and, in every sequence a ported test can stage, invisible.
    private func restoreShaped(
        successor f: CGRect, predecessor af: CGRect, display: CGRect
    ) -> Bool {
        guard Self.coversDisplay(af, display: display) else { return false }
        return af
            .insetBy(dx: -Self.handoffTolerancePt, dy: -Self.handoffTolerancePt)
            .contains(f)
    }

    /// What one inherited hit is worth in wall time at a tier's fps, while the
    /// transition holds the walk at full rate (receipt at `restoreShaped`).
    static func handoffSavedMs(fps: Int) -> Double {
        Double(triggerHits - handoffHits) * 1000.0 / Double(fps)
    }

    /// Panic path: everything down, immediately — and loudly, so every
    /// logged drop has a matching lift (review 2026-08-19, P3).
    func reset() {
        cleanFrames.removeAll()
        for id in lastHit.keys { onChange?("lift (panic)", id) }
        hits.removeAll()
        lastHit.removeAll()
        frames.removeAll()
        linger.removeAll()
        lastTrailEvent.removeAll()
        lastRewindEvent.removeAll()
        frontCandidate = nil
        attributionCounters = (0, 0)
        stripActive.removeAll()
        deadSince.removeAll()
        deadKinds.removeAll()
        deadClean.removeAll()
        successorLinger.removeAll()
        dropAt.removeAll()
        handoffDrops.removeAll()
        transientLifts.removeAll()
        expansion.removeAll()
        expansionCooldown.removeAll()
        recentLifted.removeAll()
        leavingSince.removeAll()
        restoreGranted.removeAll()
        parole.removeAll()
        hitParoleEpisode.removeAll()
        lastBigFrame.removeAll()
        subFloorSince.removeAll()
        deadLiftTimes.removeAll()
        ghostBanUntil.removeAll()
        lastOrphanAt = 0
        bypassSince = nil
        bypassMuted = false
        lastSweepAt = 0
        lastUpdateT = nil
        watchOverBudget = false
    }
}

/// TUNING TOOL — the Detection view's read-only window of the curtain
/// (DetectionTrace.swift). Nothing here writes curtain state or asks the
/// window server anything: every read is a dictionary this class already
/// holds or a WindowTracker ring read (`latestFrame`, `missSeconds`), never
/// `pollable` (a per-id CGWindowList IPC). `--ui-selftest` "detection-trace"
/// runs a scripted curtain with and without these calls between frames and
/// asserts identical outputs and events.
extension Curtain {
    /// The curtain `rewind` would credit with `box`, computed BEFORE the
    /// rewind runs: the same candidates (active curtains whose content rect
    /// holds `minContainedFraction` of the box) and the same `bestHolder`
    /// order. Mirrors `rewind`'s first statement; the equivalence self-test
    /// checks it against the `attribution-rewind` event.
    func traceRewindHolder(_ box: CGRect, display: CGRect, tracker: WindowTracker) -> CGWindowID? {
        Self.bestHolder(
            of: box,
            among: lastHit.keys.compactMap { y in
                guard let f = frames[y]?.rect else { return nil }
                let content = Self.contentRect(
                    window: f, display: display, quickLook: tracker.isQuickLookWindow(y))
                guard WindowTracker.heldFraction(box, in: content)
                    >= WindowTracker.minContainedFraction
                else { return nil }
                return (id: y, rect: content)
            })
    }

    /// Every window the curtain is deciding about right now, in CGWindowList
    /// space (screen points, top-left; the builder normalizes): pending
    /// windows with their hits against the bar they must reach, curtained
    /// windows with hold left and clean-frame evidence, leaving (dead /
    /// unlisted / strip-covered) curtains, and lingers. Call it after
    /// `update` on the same queue with the same `t`. Sorted by id.
    func traceWindows(
        tracker: WindowTracker, display: CGRect, at t: CFAbsoluteTime
    ) -> [(id: CGWindowID, frame: CGRect, state: DetectionTrace.CurtainWindow.State)] {
        var out: [(id: CGWindowID, frame: CGRect, state: DetectionTrace.CurtainWindow.State)] = []
        let windowFrames = windowFrames()
        for (id, times) in hits where lastHit[id] == nil {
            // The same prune `update` applies to a pending ring.
            let recent = times.filter {
                t - $0.t <= tuning.curtain.windowSecs || tick - $0.tick < windowFrames
            }
            // The trigger loop reads `frames[id]` alone: a sub-floor frame
            // never triggers (skipped there, so not listed here), and a
            // window with no curtain frame is never on parole. The ring
            // frame is only where the outline is drawn.
            let curtainFrame = frames[id]?.rect
            if let f = curtainFrame, belowFloor(f) { continue }
            guard !recent.isEmpty,
                let frame = curtainFrame ?? tracker.latestFrame(of: id)
            else { continue }
            // The trigger loop's bar, lowest trust first (see `update`).
            let handoff = inheritsTrust(id, tracker: tracker, display: display, at: t)
            let onParole = handoff == nil && (curtainFrame.map { paroleMatches(id, $0, at: t) } ?? false)
            let state: DetectionTrace.CurtainWindow.State
            if handoff != nil {
                state = .pending(hits: recent.count, required: tuning.curtain.handoffHits, bar: .handoff)
            } else if onParole {
                state = .pending(hits: recent.count, required: hitParoleBar(id), bar: .parole)
            } else {
                state = .pending(hits: recent.count, required: tuning.curtain.triggerHits, bar: .trigger)
            }
            out.append((id, frame, state))
        }
        for (id, last) in lastHit {
            guard let frame = frames[id]?.rect ?? tracker.latestFrame(of: id) else { continue }
            if let since = deadSince[id] {
                out.append((id, frame, .leaving(
                    kind: deadKinds[id]?.rawValue ?? "dead", forSecs: t - since)))
            } else if let since = leavingSince[id] {
                out.append((id, frame, .leaving(kind: "unlisted", forSecs: t - since)))
            } else {
                out.append((id, frame, .curtained(
                    holdLeftSecs: max(0, tuning.curtain.holdSecs - (t - last)),
                    cleanFrames: cleanFrames[id] ?? 0,
                    cleanNeeded: tuning.curtain.holdCleanFrames)))
            }
        }
        for id in stripActive {
            guard let frame = tracker.latestFrame(of: id), let p = parole[id] else { continue }
            out.append((id, frame, .leaving(kind: "strip-cover", forSecs: t - p.armedAt)))
        }
        for (id, l) in linger { out.append((id, l.frame, .lingering)) }
        for (id, l) in successorLinger { out.append((id, l.frame, .lingering)) }
        return out.sorted { $0.id < $1.id }
    }
}
