import AppKit
import CoreGraphics
import Foundation

/// Live window-frame tracking for the media cover.
///
/// WHY. The pixel pipeline sees a dragged window late: 31 ms capture + 17 ms
/// detect and paints it
/// ~24 ms later still (track-d §1). At the 900 pt/s drags measured on this
/// machine that is 60-70 pt of uncovered leading edge, which is exactly the
/// live drag defect. The window server already knows where the window is, and
/// asking it is nearly free.
///
/// RECEIPTS (trackA/RESULTS.txt, an M1 Mac, macOS 26.6, 43 on-screen windows):
///   * CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) + bounds parse:
///     n=3000 mean 0.110 ms p50 0.090 p95 0.121 p99 0.197.
///   * Polling ONE window at 120 Hz = 1.26% of one core (250 Hz = 2.62%).
///   * Staleness of the freshest sample during a real 899 pt/s titlebar drag:
///     120 Hz mean 11.3 / p95 17.9 ms; 250 Hz mean 8.5 / p95 13.1 ms.
///     4.8 ms of p95 (4 pt at 900 pt/s) costs 1.36% more of one core against a
///     25% budget already spending 18.6% — so this polls at 120 Hz. Raise it
///     only with a measurement that says 4 pt mattered.
///   * The window server commits >160 distinct positions/s during a drag, so a
///     poll is the only signal fast enough to see them.
///   * AX is DEAD for this: kAXWindowMoved notifications AND kAXPosition polling
///     both coalesce to ~10 Hz (27 events/s, max gap 101 ms = 91 pt of
///     uncorrected drift at 899 pt/s). Measured, not assumed. kAXResized was
///     never measured, so it is not used either.
///   * Ownership mapping: a full CGWindowList snapshot + parse is 1.2-1.4 ms
///     and resolving one rect against an in-hand snapshot is 0.005 ms.
///   * Containment tolerance: a cover rect poking 4 pt outside the window frame
///     resolves to NO OWNER at tol=0 and OWNED at tol=12.
///
/// THREADING. `poll` runs on its own thread; `resolveOwner` runs on the detect
/// queue; the samples are read from the display-link tick on the main thread.
/// All shared state is behind `lock`. MotionBoxes documents itself as
/// "single-threaded by construction and carries no locking" — that assumption
/// stays true because nothing here reaches into it.
final class WindowTracker {
    /// One observed window frame, in CGWindowList space: screen POINTS with a
    /// TOP-LEFT origin on the main display.
    struct Sample {
        let t: CFAbsoluteTime
        let frame: CGRect
    }

    /// One region's question for a z-order walk.
    ///
    /// TWO rects, because the two questions ownership asks are about different
    /// things:
    ///   * `authority` — what the overlay is actually painting for this region
    ///     right now (the pinned rect while the owner window moves). "Is
    ///     somebody in front of my cover" and "does the incumbent still hold my
    ///     cover" are both about this rect.
    ///   * `gate` — the PIXEL-DERIVED cover the pipeline published this frame.
    ///     ACQUIRING a window is a claim about the pixels, so it is tested
    ///     against this one, never against the pinned rect (which would be
    ///     circular: the pin came from the window we are trying to confirm).
    struct Query {
        let authority: CGRect
        let gate: CGRect
        let incumbent: CGWindowID?
    }

    /// What one z-order walk can say about one region. The DECISION is
    /// main.swift's `resolveOwnership`; this reports evidence only, because the
    /// decision needs history (the pin, the freeze latch, the disagreement
    /// timer) that a stateless walk does not have.
    struct Resolution {
        /// Frontmost layer-0 window intersecting `authority`, whatever the
        /// containment. Reported even when it is NOT the incumbent — that case
        /// is the occlusion signal defect 1c freezes on, and the old
        /// `.owned/.unowned` enum could not express it.
        var frontID: CGWindowID?
        var frontFrame: CGRect?
        /// `frontFrame` holds at least `minContainedFraction` of `gate`.
        var frontHoldsGate = false
        /// The incumbent's frame in THIS snapshot; nil when it is gone.
        var incumbentFrame: CGRect?
        /// `incumbentFrame` holds at least `minContainedFraction` of `authority`.
        var incumbentHoldsAuthority = false
    }

    /// Why a poll produced no frame for a tracked window. The three failure
    /// shapes are NOT the same claim and collapsing them into `nil` is what
    /// made "the window is gone" unfalsifiable (tk3 Stream W).
    ///
    /// MEASURED on this machine (scratchpad/streamW/pollprobe.swift, ~45 000
    /// polls across five configurations — idle, 3x concurrent `swiftc -O`, and
    /// a deterministic 45 ms stall injected every 370 ms): `apiFailed`,
    /// `unknownID` and `malformed` fired ZERO times for a window that still
    /// existed, and there were ZERO resurrections (an `ok` after a miss) in any
    /// run. The one run that produced `unknownID` was a window that had really
    /// been closed, and it never came back. So on the evidence available a miss
    /// IS a real loss — which is why `deadSecs` below is a small debounce and
    /// a tripwire, not a tuned recovery path. If `apiFailed` ever fires, that is
    /// news and the tripwire says so out loud.
    enum PollOutcome: Equatable {
        /// A frame was read.
        case ok
        /// `CGWindowListCopyWindowInfo` itself returned nothing to parse. The
        /// window server did not answer; this says nothing about the window.
        case apiFailed
        /// The window server answered and does not know this id. This is the
        /// only shape that is evidence of real closure.
        case unknownID
        /// The row came back without parseable bounds. Garbage, not absence.
        case malformed
    }

    /// How long a window must read `unknownID` before it is declared gone.
    /// WALL CLOCK, measured from that window's last SUCCESSFUL poll — not a
    /// poll count.
    ///
    /// WHY NOT A POLL COUNT ANY MORE (2026-09-11). This was
    /// `deadPolls = 3`, receipted as "25 ms at 120 Hz". The achieved loop
    /// cadence on a test Mac is MEASURED at 33.6-40.5 Hz, p50 34.9 (receipt at
    /// `lateTolerance`), so three polls there is ~86 ms — the constant was
    /// priced in milliseconds and spent in polls, and the duration its
    /// receipt defends was never the duration in force. Expressing it against
    /// sample timestamps makes the receipt true at any cadence. The
    /// alternative the audit offered — a tripwire on the achieved poll rate —
    /// was rejected HERE because `lateTolerance`'s own receipt records that
    /// such a tripwire needs a clean idle baseline (no shield harness, no
    /// second daemon) that nobody has measured yet: it would be a number with
    /// no receipt. It stays OPEN there, and this change removes this
    /// constant's dependence on it.
    ///
    /// Receipt for the SIZE, not for the existence: the pipeline consumes this
    /// verdict once per capture frame (33 ms at 30 fps), so a 25 ms debounce
    /// costs at most one extra frame of a cover held over a window that has
    /// really closed — over-cover, the fail-safe direction. Receipt for needing
    /// it at all: the asymmetry. A false "gone" destroys the pin and the
    /// measured cost of that is 2904 ms of exposed player; a late "gone" costs
    /// 33 ms of over-cover. At a transient-miss rate measured as zero in 45 000
    /// polls, 25 ms is already far past the evidence — it is priced against the
    /// asymmetry, not against an observed failure rate.
    static let deadSecs: CFTimeInterval = 0.025

    /// Consecutive misses that must be OBSERVED before any of this class's
    /// miss DURATIONS can fire, whatever the cadence.
    ///
    /// Receipt: `deadSecs` is 25 ms, which is SHORTER than one poll period on
    /// a loop running at 40 Hz or below — inside the 33.6-40.5 Hz range
    /// measured at `lateTolerance`. A pure duration would therefore let ONE
    /// dropped poll declare a window dead on that machine, which is the floor
    /// the old three-poll count provided for free. Two observations keeps it:
    /// one dropped poll is never evidence. At the 120 Hz design cadence
    /// `deadSecs` is then reached on the third consecutive miss — bit-for-bit
    /// the old `deadPolls = 3` behaviour.
    ///
    /// WHICH KNOB BINDS, because it is not the one the receipt is named after
    /// (added in review, 2026-09-11): on THIS machine the floor binds, not
    /// `deadSecs`. At 33.6-40.5 Hz two observations is 49-60 ms, already past
    /// 25 ms, so the earliest possible death is two periods — never 25 ms. The
    /// change is still the intended correction: the old three-poll count spent
    /// 74-89 ms here, so the error against the 25 ms receipt goes from ~3.4x to
    /// ~2-2.4x. It does not reach 25 ms and cannot until the poll loop is
    /// faster than 80 Hz. Anyone who measures ~55 ms and reaches for `deadSecs`
    /// is turning the wrong screw; raise the poll cadence, or lower this floor
    /// and accept that one dropped poll kills a window.
    ///
    /// AND WHICH DIRECTION THAT MOVED, said plainly (same review): "bit-for-bit"
    /// holds at 120 Hz only. Here the debounce against a FALSE death went from 3
    /// consecutive misses (74-89 ms) to 2 (49-60 ms) — and `deadSecs`'s own
    /// asymmetry receipt prices a false "gone" at 2904 ms of exposed player
    /// against 33 ms of over-cover for a late one, so the EXPENSIVE direction is
    /// the one that got shorter. Accepted on the measurement behind it: the
    /// transient-miss rate is zero in 45 000 polls across five load
    /// configurations, so a second consecutive miss has never been observed
    /// without a third. If a live log ever shows a transient double-miss, this
    /// floor is the number to raise, and it wants that observation as its
    /// receipt.
    static let missObservationFloor = 2

    /// What a `deadSecs` streak of `unknownID` means. MEASURED 2026-09-09 on
    /// a test Mac:
    /// a real close reads
    /// `unknownID` AND absent from `.optionAll` on the same poll, +0.15 s after
    /// the close command (the window fades alpha 0.81 → 0.34 over ~110 ms
    /// first, still `ok`), and never returns; a fullscreen EXIT reads
    /// `unknownID` for 0.57 s while `.optionAll` STILL LISTS the id, then `ok`
    /// again. Minimize, Stage-Manager relegation and fullscreen enter never
    /// produced `unknownID` at all (the id stays `ok` at thumbnail / display
    /// scale). So `unknownID` alone is NOT proof of closure — the `.optionAll`
    /// snapshot is what separates the two shapes, and `deadKind` reports it.
    enum DeadKind: String {
        /// `unknownID` per id, but an `.optionAll` snapshot still lists it: a
        /// space / fullscreen transition. It can come back.
        case offstage
        /// `unknownID` per id and absent from `.optionAll`: closed. Never
        /// observed to come back (this probe and the 45 000-poll one above).
        case destroyed
    }

    /// While an `unknownID` streak lasts past `deadSecs` and the id is
    /// classified `.offstage`, the `.optionAll` classification is re-taken at
    /// most this often per id. Receipt: the snapshot cost 4.5 ms mean on the
    /// test Mac (same probe — the `.optionAll` list is every window on the
    /// system, 3-4x the 1.2-1.4 ms on-screen snapshot), and the longest an
    /// OFFSTAGE streak is waited on is `Curtain.deadLiftSecs` = 1.5 s, so
    /// 0.5 s bounds an offstage episode at ~4 snapshots (~18 ms of
    /// poll-thread time) while still catching an offstage id that is
    /// destroyed mid-transition within the fullscreen exit's own 0.57 s.
    ///
    /// `.destroyed` is TERMINAL and is never re-checked (review 2026-09-09):
    /// the streak does not end when the curtain lifts — the lift arms RETURN
    /// parole (`Curtain.paroleSecs` 300 s) and a parolee stays in
    /// `Curtain.watchIDs`, so the id is polled, and misses, for up to 300 s
    /// after the close. Re-checking for that whole streak would cost ~600
    /// snapshots (~2.7 s of poll-thread time) per closed window, 150x the
    /// receipt above; a closed id was never observed to come back (`DeadKind`
    /// receipt), so one snapshot answers it for good. Not a retry budget: the
    /// first snapshot is taken the poll the streak reaches `deadSecs`, and a
    /// successful poll clears the classification (`deadKinds[id] = nil`), so
    /// an id that genuinely returns is classified afresh on its next streak.
    static let deadRecheckSecs: CFTimeInterval = 0.5
    /// Re-checks per `.offstage` streak, after the first snapshot (receipt
    /// 2026-09-09): the offstage lift is the same `away` lift, so an
    /// offstage parolee's streak also outlives its consumer — `Curtain` reads
    /// `deadKind` only for ids in `lastHit`, i.e. until the `deadLiftSecs`
    /// ceiling at 1.5 s — and without a cap a long offstage streak would cost
    /// the 600 snapshots above. 3 re-checks at 0.5 s span exactly that 1.5 s
    /// consumer window (snapshots at +0, +0.5, +1.0, +1.5 s = the "~4" the
    /// receipt above prices). Never observed to matter — every measured
    /// offstage streak ended within 0.57 s — so this is a bound, not a
    /// budget: past it the id simply keeps its last classification until a
    /// successful poll clears it.
    static let deadRechecksPerStreak = 3

    /// A miss streak this long on a cause that can never make `isDead` true is
    /// not a glitch, it is a broken assumption, and it must not sit silent
    /// behind a frozen cover. 1 s, WALL CLOCK from the last successful poll —
    /// was `uncertainTripwire = 120` polls, receipted as "1 s" at a 120 Hz
    /// cadence the loop does not achieve (3.4 s at the measured test Mac rate; the
    /// full argument is at `deadSecs`). Printed ONCE per streak.
    private static let uncertainTripwireSecs: CFTimeInterval = 1.0

    /// `.optionAll` snapshots the window server REFUSED before one is loud.
    ///
    /// HEALTHY IS ZERO, and that is measured rather than assumed: the same
    /// API's per-id form returned `apiFailed` ZERO times in ~45 000 polls
    /// across five load configurations, including injected 45 ms stalls and
    /// three concurrent `swiftc -O` jobs (receipt at `PollOutcome`). A refusal
    /// of the `.optionAll` form has never been observed in this tree at all —
    /// neither a shielded run nor a selftest has produced one — so the
    /// tripwire sits at the first occurrence, which is the only value "beyond
    /// the healthy range" can mean when the range is a point at zero. The
    /// consequence is over-cover, not exposure: the refusing poll classifies
    /// nothing (receipt in `pollLoop`), so the curtain keeps holding and the
    /// `deadSecs`/`destroyedLiftSecs` path simply does not advance.
    ///
    /// Loud ONCE per streak (a refusal storm would otherwise write one record
    /// per poll), and the cumulative count rides every scheduling receipt so a
    /// run whose first refusal scrolled past still carries the number.
    private static let allRefusalTripwire = 1

    /// Poll period. Receipt above: 120 Hz = 1.26% of one core, p95 staleness
    /// 17.9 ms during a 900 pt/s drag.
    static let pollHz = 120.0
    /// Half one poll period. DERIVED: a wake-up later than this is closer to
    /// the next slot than to its scheduled slot. Smaller scheduler jitter is
    /// not a missed geometry sample and must not inflate the late-poll rate.
    ///
    /// HEALTHY RANGE ON THE MINI — MEASURED 2026-09-08, source main 3ae5a64,
    /// ten shielded runs,
    /// reading each run's final `sched` record.
    /// This replaces the "51.7-65.5% with no baseline" number, which had none:
    ///   * late rate 61.0 / 62.7 / 63.3 / 63.4 / 63.5 / 64.1 / 65.1 / 65.9 /
    ///     66.2 / 68.5 % — p50 63.8 (63.5 nearest-rank), p95 68.5, range
    ///     61.0-68.5.
    ///   * worst behind 54.7-90.3 ms (p50 60.7; the 90.3 ms outlier is one
    ///     run, rmr-capC-2).
    ///   * LOOP CADENCE 33.6-40.5 Hz against this 120 Hz target, p50 34.9 —
    ///     that is `pollCount / elapsed`, and it is NOT the Hz the
    ///     `-- windowTracker:` line prints (31.3-37.4). That line divides
    ///     `pollStats.count`, which is `trackedPolls` — iterations that walked
    ///     a NON-EMPTY tracked set — by the whole run's elapsed time
    ///     (main.swift's shutdown receipt), so every second before the curtain
    ///     armed dilutes it; the same denominator hazard the accounting fields
    ///     below already document. Recovered per run as
    ///     `printedHz x pollCount / trackedPolls` (both are in the run's own
    ///     logs), +/-0.2 Hz from the printed Hz's 0.1 rounding.
    /// Read the rate as a
    /// whole-run average; what makes it a RANGE rather than one artifact is
    /// ten independent runs landing inside 7.5 pp of each other.
    /// It is NOT poll cost — mean wall time per poll was 1.05-1.72 ms
    /// (`-- windowTracker:` line, same runs) against the 8.33 ms period, and
    /// adding a second tracked id did not move it — so the deficit is wake-up
    /// latency on a test Mac that is also running the installed agent, Chrome, the
    /// shield and a 13-14 fps detector: a mean iteration period of 28.7 ms,
    /// 3.4 poll slots.
    /// DERIVED, not measured directly: freshest-sample staleness is bounded by
    /// that iteration period, so on this machine it is ~3.4x the 8.33 ms design
    /// period. The 17.9 ms p95 staleness in this class's header was measured on
    /// an M1 Mac at a different cadence and by a different method — treat the
    /// test Mac number as a scaling argument, not a comparable p95. That same
    /// latency is what `Overlay.curtainLeadCapPt`'s re-measurement sees twice:
    /// as a 380 pt jump-resize gap no lead can close, and as a lead REQUEST of
    /// 200-350 pt at 1500 pt/s (velocity x an inflated horizon), which is why
    /// the 120 pt cap binds on this machine and would not on a 120 Hz ring.
    /// TWO MORE RUNS, SAME HARNESS, ABOVE THAT RANGE — MEASURED 2026-09-08,
    /// this branch, `fast` tags `rmr-close-1` / `rmr-close-2`: 73.95% and
    /// 72.50% late (worst 60.9 / 59.5 ms behind). That is 5.5 pp past the ten-run
    /// p95 above, on a test Mac carrying more background load the same day
    /// (`uptime` load average 1.9). The observed range on this machine is
    /// therefore 61.0-74.1%, not 61.0-68.5%; both new runs verdicted OK with
    /// identical peak edge gap and peak exposed fraction, so this is spread in
    /// the machine, not a regression. NOT re-receipted as a NEW range on two
    /// runs — it is recorded so the next reader does not read 68.5 as a ceiling.
    /// OPEN, and deliberately not fixed here: a tripwire on this rate needs a
    /// clean idle baseline (no shield harness, no second daemon) first, and
    /// then it belongs beyond that range, not beyond this one.
    static let lateTolerance = 0.5 / pollHz
    /// Ring length per window. 256 samples at 120 Hz = 2.13 s of history.
    /// Was 128 (1.07 s), sized for the deepest LOOKBACK anyone asks for — one
    /// capture frame plus the detect+paint path, ~73 ms. `stillSeconds` reads
    /// the ring the other way round, for how long a frame has been UNCHANGED,
    /// and saturates at the ring's span: at 128 it could not distinguish
    /// `CoverOwnership.pinRemeasureSecs` (1.0 s) from anything longer, which is
    /// the difference between "the pixel path has recovered" and "it has not".
    /// 2x that threshold, 40 bytes a sample, one or two windows tracked.
    private static let ringLength = 256
    /// Containment slack when deciding a window owns a cover rect. Receipt
    /// (trackA mapping probe): a rect 4 pt outside the frame reads NO OWNER at
    /// tol=0 and OWNED at tol=12. The published media rect carries MotionBoxes'
    /// one-cell margin (~12 screen pt at this display) plus the overlay's 1%
    /// pad, so it legitimately pokes outside the window it belongs to.
    static let containTolerance: CGFloat = 12

    /// Fraction of a cover rect's AREA that must lie inside a window (inflated
    /// by `containTolerance`) for that window to hold it.
    ///
    /// WHY a fraction and not `CGRect.contains` (iteration 8, defect 2). The
    /// all-or-nothing test was measured refusing ownership exactly at speed:
    /// on runs/torture-2, aligned against window_truth, the published cover's
    /// width against the owner window's width reads p50 0.95 while the window
    /// is still or slow, but p50 1.08 / p90 1.37 in the 600-1000 pt/s bursts —
    /// MotionBoxes' heat field smears the box along the drag faster than
    /// EdgeSnap's 2-cell/update inward limit can pull it back. Ownership over
    /// those frames: 86.9% below 50 pt/s, 46.4% at 300-600, **12.0% at
    /// 600-1000**. The fast path turned itself off at speed.
    ///
    /// 0.75 is set from the same measurement: at < 300 pt/s (where acquisition
    /// happens) the contained fraction is p50 1.00 with p10 0.51, and the p10
    /// tail is the resize legs, not the drags. 0.75 sits above the ballooned
    /// bursts (which must NOT acquire a fresh owner from a smear) and below the
    /// slow-drag body. Retaining ownership THROUGH a burst is not this
    /// number's job — the window-relative pin is (see `CoverPin` in main.swift),
    /// and that is why this can stay strict.
    static let minContainedFraction: CGFloat = 0.75

    /// How long a window's frame must be unchanged for the pixel path to be
    /// handed authority back over the media rect (iteration 8, defect 3).
    /// 0.3 s = 9 capture frames at 30 fps: EdgeSnap moves an edge at most
    /// 1-2 cells (8-16 px) per update, and `MotionBoxes.motionLookback` needs
    /// 3 updates to even see that a box stopped, so anything shorter hands back
    /// to a box that is still converging out of the smear. Also 36 poll samples
    /// at 120 Hz, well inside the `ringLength` 256-sample ring (the "128-sample
    /// ring" this line used to name was the pre-2026 length; corrected
    /// 2026-09-11).
    static let stillSecs = 0.3
    /// A floating (layer > 0) window this large is system chrome that spans the
    /// screen — the Dock owns a full-screen layer-20 window — and must not be
    /// read as "something is covering the player". Receipt: trackA's mapping
    /// probe found exactly that window and the same predicate excludes it.
    private static let fullScreenishW: CGFloat = 0.98
    private static let fullScreenishH: CGFloat = 0.90

    /// Screen frame in points. NSScreen is main-thread state and
    /// `resolveOwners` runs on the detect queue, so the walk must not reach for
    /// it there.
    ///
    /// THREAD: seeded from the main thread in `Pipeline.start()` before any walk
    /// runs, and re-written ONLY inside `Pipeline.applyDisplayChange`'s
    /// detectQueue block — the same queue `resolveOwners` reads it from (note:
    /// it used to be set once and frozen, so a display change left the
    /// containment test judging against a display that was gone).
    var screenFrame = CGRect.zero
    /// Our own overlay windows. They sit at level .screenSaver (layer 1000) and
    /// the window server reports their bounds as the tight box around what is
    /// actually painted — i.e. as a small floating window sitting exactly on top
    /// of the cover. Measured in the first live smoke run: every walk after the
    /// first cover appeared reported
    /// `FLOATERS l1000@(720, 435, 480, 570)`, which is the cover itself, and
    /// ownership was refused on every frame from then on. Excluding by owner PID
    /// rather than by window number needs no plumbing and cannot go stale when
    /// the overlay window is recreated.
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private let lock = NSLock()
    // Receipt: test Mac 2026-09-16, outer panel 1752 changed layer 3 -> 0
    // behind Chrome and passed 20/20 direct queries. Its helper failed 20/20.
    // Preserve the outer ID/PID; the existing ring tracks its geometry.
    private var quickLookOwners: [CGWindowID: pid_t] = [:]
    private var reportedQuickLookAmbiguities: Set<CGWindowID> = []
    private var tracked: [CGWindowID: [Sample]] = [:]
    /// Consecutive polls that produced no frame, and why the last one didn't.
    /// Replaces the old `dead: Set<CGWindowID>`, which latched on ONE miss and
    /// could not say whether the miss meant anything.
    private var misses: [CGWindowID: Int] = [:]
    private var missCause: [CGWindowID: PollOutcome] = [:]
    /// When this id was last polled successfully, or when it entered the
    /// tracked set if it never has been. The clock every miss DURATION is
    /// measured against (receipt at `deadSecs`): a count of polls is not a
    /// duration on a loop that does not hold its cadence.
    private var lastOkAt: [CGWindowID: CFAbsoluteTime] = [:]
    /// `.optionAll` classification of a dead id (receipt at `DeadKind`) and
    /// when it was last taken; both cleared by the next `ok` poll.
    private var deadKinds: [CGWindowID: DeadKind] = [:]
    private var deadCheckedAt: [CGWindowID: CFAbsoluteTime] = [:]
    private var deadChecks: [CGWindowID: Int] = [:]  // snapshots this streak (receipt at deadRechecksPerStreak)
    /// `.optionAll` snapshots taken since start — the receipt at
    /// `deadRecheckSecs` is a per-episode count, and `--ui-selftest` asserts
    /// it against this.
    private var allSnapshots = 0
    /// `.optionAll` snapshots the window server refused: total since start, the
    /// current consecutive streak, and whether this streak has already been
    /// reported (receipt at `allRefusalTripwire`).
    private var allRefusals = 0
    private var allRefusalStreak = 0
    private var allRefusalTripwired = false
    private var tripwired: Set<CGWindowID> = []
    private var thread: Thread?
    private var running = false
    /// Poll-loop accounting, read once at shutdown for the perf receipt.
    /// Loop iterations — one per poll period, tracked set or not — so the
    /// cadence receipt's denominator is the same clock its numerator counts
    /// against. Before this it only counted iterations with a non-empty
    /// tracked set while `lateCount` counted every scheduler overshoot, so the live
    /// agent's heartbeat read "1885278/1993 polls late (94594%)" (health
    /// review 2026-08-25): an idle desktop had ~5 overshoots per second
    /// and no polls to divide them by.
    private var pollCount = 0
    /// Iterations that actually walked a tracked set; `pollWork` is their
    /// wall time, so the mean-ms-per-poll receipt divides by these.
    private var trackedPolls = 0
    private var pollWork = 0.0
    /// Scheduling accounting (tk3 Stream W). `lateCount`/`maxLate` are the
    /// receipt for how reachable a poll stall actually is on this machine
    /// (healthy range: receipt at `lateTolerance`). `closeSamples` counts ring
    /// pairs less than half a poll period apart; `closeNewPosition` counts the
    /// subset of those that carry a NEW window position. All are reported by
    /// `stop()` and by the heartbeat.
    ///
    /// WHY TWO COUNTERS — THE OLD TRIPWIRE MEASURED THE WRONG THING. The defect
    /// tk3 Stream W fixed is a CLOCK ARTIFACT REACHING A VELOCITY FIT: two
    /// DISTINCT positions stamped ~0.4 ms apart, divided, and read as
    /// 10 650 pt/s on a 240 pt/s drag (receipt at
    /// `PaintExtrapolator.minVelocityBaseline`). A close pair that repeats the
    /// SAME position is not that defect and cannot become it: every ring
    /// consumer that divides by time reads the ring through
    /// `recentDistinctSamples`, which collapses a run of equal origins into one
    /// sample stamped with the FIRST poll that saw it — so a duplicate close
    /// read is discarded before any arithmetic. `closeSamples` counted both
    /// shapes, so on a machine that wakes late it reported a number nobody could
    /// act on; `closeNewPosition` is the shape the receipt was written about,
    /// and it is the tripwire.
    ///
    /// MEASURED 2026-09-08, source main 3ae5a64, ten shielded runs of ~20-26 s:
    /// `closeSamples` 28 / 35 / 38 / 42 / 44 / 46 / 47 / 48 / 51 / 60 per run —
    /// ten runs, ten values, never 0, 4.2-7.3% of that run's poll iterations.
    /// That is the late-poll rate's fingerprint, not a defect: an iteration that
    /// wakes ~3.4 slots late reads its id, and the next — already past its own
    /// deadline — reads it again almost immediately.
    ///
    /// HEALTHY RANGE FOR THE TRIPWIRE — MEASURED 2026-09-08, this branch, two
    /// shielded `fast` runs:
    /// `closeSamples` 22 and 22,
    /// `closeNewPosition` **0 and 0**. So the healthy value for this tripwire IS
    /// 0 — on the shape it was written about — and the reason the old counter
    /// looked broken is that it also counted duplicate reads, which nothing
    /// downstream can divide by. Anything above 0 here is the tripwire firing;
    /// `closeSamples` on its own is a cadence symptom and belongs to
    /// `lateTolerance`'s receipt, not to this one. These are 1500 pt/s scripted
    /// drags, the fastest motion the harness produces, so they are the runs most
    /// likely to commit a position inside a 4 ms window. NOT CHECKED: an M1 Mac,
    /// a clean idle test Mac, and a human-speed drag.
    ///
    /// WHY A NEW-POSITION CLOSE PAIR IS STILL BOUNDED, if one does occur. Both
    /// bounds are asserted in `--probe-selftest` ("close ring pair" block), not
    /// left as prose:
    ///   * The 2-tap FRESH-AXIS fit is refused outright.
    ///     `PaintExtrapolator.freshPairFloor` is `0.5 / pollHz` — the SAME
    ///     threshold this counter uses — so a pair this counter counts can never
    ///     be a pair that fit divides by. Exact, by construction of the two
    ///     constants, not by margin.
    ///   * The 3-sample SPAN fit is bounded, not refused. A close pair can only
    ///     shorten `span`, and `minVelocityBaseline` (= one whole `1 / pollHz`)
    ///     is twice this counter's threshold, so the close pair can contribute
    ///     at most half the shortest span the fit will accept. At that floor two
    ///     4 pt commits read 952 pt/s and, over the `maxWindowProjection` 50 ms
    ///     horizon, lead by 47.6 pt — which `pinnedAdvance` UNIONS with the
    ///     measured rect, so the error direction is over-cover, never exposure.
    ///   * The curtain path does not use ring timestamps at all:
    ///     `Overlay.liveCurtainFrame` reads `latestFrame` and times its own
    ///     prev/last transitions on the display-link clock, so no ring pair,
    ///     close or not, can reach the curtain lead. `Curtain.movingTrails`
    ///     unions frames and never divides by dt.
    private var lateCount = 0
    private var maxLate = 0.0
    private var closeSamples = 0
    private var closeNewPosition = 0
    /// When the periodic scheduling receipt was last emitted. The receipt CANNOT
    /// live only in `stop()`: the live harness kills the daemon with SIGTERM
    /// (ipad_run.sh line 83, "Terminated: 15"), so `shutdown()` never runs and
    /// no end-of-run line is ever written — measured on runs/ipad-tk3W-flick1,
    /// which has no `-- windowTracker:` line at all. A 10 s heartbeat is the
    /// only way the cadence receipt survives a real run.
    ///
    /// Update: SIGTERM now runs `shutdown()` (main.swift registers it exactly
    /// like SIGINT), so a harness kill does reach `stop()`. The heartbeat stays
    /// — SIGKILL, a panic exit and a crash still bypass it, and a receipt that
    /// only prints on a clean exit is a receipt that never prints.
    private var lastReceiptAt = 0.0
    /// Magnitude receipt (2026-08-21): ASSUMED. At 10 s this heartbeat
    /// writes one line every 10 s = 8,640 lines/day; the line itself
    /// (`emitSchedulingReceipt` below) is 129-138 B measured against its own
    /// `String(format:)` template (+~35 B since 2026-09-02 for the windowed
    /// late rate, DERIVED from the template: 8,640 × 164–173 B), so ~1.4–1.5 MB/day of stderr — immaterial next
    /// to the 200 MB rotation budget (Logger.swift:324). 10 s is frequent
    /// enough to bracket the sched-telemetry anomaly window this receipt
    /// exists to catch (a stall shorter than 10 s still shows as one
    /// degraded heartbeat instead of vanishing between them) while staying
    /// two orders of magnitude below the log budget. No live run has needed
    /// finer granularity; tighten only against an observed anomaly this
    /// cadence missed.
    private static let receiptEvery = 10.0
    /// Live-agent heartbeat: the 10 s cadence above was priced for harness
    /// runs that get killed. Under launchd it wrote 8,640 lines/day into a
    /// stderr file nothing rotates — MEASURED 2026-08-25: 29,006 of 29,496
    /// agent.err lines, 3.9 MB in three days, on the production M1 Mac. When
    /// `onReceipt` is set (Pipeline, live runs) the receipt goes there as a
    /// rotated "sched" record instead, at this cadence, and ONLY when a
    /// counter moved since the last emission — a receipt that repeats the
    /// same numbers every minute is not a receipt. The final line on stop()
    /// is always emitted.
    private static let liveReceiptEvery = 60.0
    /// Sink for the periodic receipt on live runs. nil (harness/dev) keeps
    /// stderr at the 10 s cadence.
    var onReceipt: ((String) -> Void)?
    /// Structured sink for an uncertain-poll tripwire. stderr remains for a
    /// local operator; the structured record makes health budgets complete.
    var onTripwire: ((String) -> Void)?
    /// Last emitted (late-rate whole %, worst ms, close) plus the cumulative
    /// counts it was computed from. "On change" compares the RATE of late
    /// wake-ups over the window, not the cumulative count — that count grows
    /// every second on an idle desktop (~5/s MEASURED 2026-08-25) and would
    /// make the receipt unconditional. Since 2026-09-02 the same window rate
    /// is also PRINTED next to the cumulative one (receipt in
    /// `emitSchedulingReceipt`); `lastCounts` is the window's start.
    private var lastEmitted: (Int, Double, Int, Int, Int) = (-1, -1, -1, -1, -1)
    private var lastCounts: (late: Int, polls: Int) = (0, 0)

    // MARK: - lifecycle

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let t = Thread { [weak self] in self?.pollLoop() }
        t.name = "sentryscreen.windowtracker"
        // Position sampling is latency work, not throughput work: it must not
        // sit behind the detector on a busy core.
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
    }

    /// Stops the poll thread AND prints the scheduling receipt.
    ///
    /// The print lives here rather than in main.swift's `shutdown()` on purpose:
    /// these counters are this class's own tripwires, `stop()` is already the
    /// one call main.swift makes at the end of a run, and keeping the line here
    /// means the receipt cannot be lost by an edit to a file this class does not
    /// own. `--process` never constructs a WindowTracker, so no headless log
    /// moves.
    func stop() {
        lock.lock()
        running = false
        tracked.removeAll()
        misses.removeAll()
        missCause.removeAll()
        lastOkAt.removeAll()
        tripwired.removeAll()
        quickLookOwners.removeAll()
        reportedQuickLookAmbiguities.removeAll()
        lock.unlock()
        emitSchedulingReceipt("-- windowTracker sched (final)")
    }

    /// The 120 Hz cadence receipt: how often the poll loop missed its deadline,
    /// the worst miss, the count of ring samples closer together than half a
    /// poll period, how many of THOSE carried a new window position — the
    /// tripwire — and how many `.optionAll` snapshots the window server refused
    /// (receipt at `allRefusalTripwire`; healthy 0, and a refusal is loud once
    /// per streak on its own). Only the second number is the artifact tk3 Stream W removed, so
    /// only it has a "want 0"; the first is a cadence symptom that tracks the
    /// late-poll rate on a slow machine (receipts at `closeSamples` and
    /// `lateTolerance`).
    ///
    /// stderr, and emitted on a 10 s heartbeat as well as at `stop()`, because
    /// the live harness KILLS the daemon (ipad_run.sh: "Terminated: 15") and
    /// `shutdown()` never runs — measured on runs/ipad-tk3W-flick1, which
    /// contains no `-- windowTracker:` line at all. A receipt that only prints
    /// on a clean exit is a receipt that never prints. (SIGTERM now reaches
    /// `shutdown()`; SIGKILL and crashes still do not, so the heartbeat stays.)
    private func emitSchedulingReceipt(_ prefix: String, force: Bool = true) {
        lock.lock()
        let (late, worst, close, polls) = (lateCount, maxLate, closeSamples, pollCount)
        let closeNew = closeNewPosition
        let refusals = allRefusals
        let dPolls = polls - lastCounts.polls
        let dLate = late - lastCounts.late
        // Whole-5% buckets suppress insignificant heartbeat churn. The old
        // any-overshoot rule measured an inactive session at ~68% late
        // (2026-08-25, uid 502). lateTolerance now excludes sub-half-period
        // jitter, and its healthy range on a test Mac is MEASURED as of
        // 2026-09-08 (receipt at lateTolerance: 61.0-68.5%, p50 63.8, worst
        // 54.7-90.3 ms behind, under the shielded harness). The M1 Mac and a
        // clean idle test Mac are both still unmeasured.
        let ratePct = dPolls > 0 ? 5 * Int((20.0 * Double(dLate) / Double(dPolls)).rounded()) : 0
        let changed = lastEmitted != (ratePct, worst, close, closeNew, refusals)
        lastEmitted = (ratePct, worst, close, closeNew, refusals)
        lastCounts = (late, polls)
        let sink = onReceipt
        lock.unlock()
        guard force || changed else { return }
        // Cumulative AND windowed (2026-09-02): the cumulative percentage
        // cannot tell "late now" from "late during warm-up, recovered since".
        // The window is the polls since this receipt was last EVALUATED:
        // liveReceiptEvery (60 s) on a live run, receiptEvery (10 s) on
        // stderr. health_report.py reads the cumulative pair by its "polls
        // late (…%), worst … ms" wording; the window is worded differently on
        // purpose so that regex keeps matching the same numbers it always did
        // (asserted in `--ui-selftest`).
        let line = String(
            format: "%@: %d/%d polls late (%.2f%%), worst %.1f ms behind; "
            + "last window %d/%d late (%.2f%%); "
            + "%d ring samples closer than half a poll period, "
            + "%d of them a new position (want 0); "
            + "%d window-list refusals (want 0)",
            prefix, late, polls,
            polls > 0 ? 100 * Double(late) / Double(polls) : 0,
            worst * 1000,
            dLate, dPolls, dPolls > 0 ? 100 * Double(dLate) / Double(dPolls) : 0,
            close, closeNew, refusals)
        if let sink {
            sink(line)
        } else {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    /// Panic (SPEC §8.1(1)): forget every window and every sample, so a resumed
    /// run cannot translate a cover by a delta from before the pause.
    func reset() {
        lock.lock()
        tracked.removeAll()
        misses.removeAll()
        missCause.removeAll()
        lastOkAt.removeAll()
        tripwired.removeAll()
        quickLookOwners.removeAll()
        reportedQuickLookAmbiguities.removeAll()
        lock.unlock()
    }

    /// Detect queue. The set of windows worth polling — the owners of this
    /// frame's media-held covers. Windows that drop out stop being polled.
    func setTracked(_ ids: Set<CGWindowID>) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        for id in ids where tracked[id] == nil {
            tracked[id] = []
            misses[id] = 0
            missCause[id] = nil
            // A window that has never been polled successfully still needs a
            // clock for the miss durations, and "since we started asking" is
            // the honest one (receipt at `deadSecs`).
            lastOkAt[id] = now
            tripwired.remove(id)
        }
        for id in tracked.keys where !ids.contains(id) {
            tracked.removeValue(forKey: id)
            misses[id] = nil
            missCause[id] = nil
            lastOkAt[id] = nil
            deadKinds[id] = nil
            deadCheckedAt[id] = nil
            deadChecks[id] = nil
            tripwired.remove(id)
        }
        lock.unlock()
    }

    // MARK: - reads

    /// The freshest frame observed for `id` at or before `t`, or the oldest
    /// sample if the ring does not reach back that far. nil when the window is
    /// not tracked or has never been sampled.
    ///
    /// "At or before" rather than interpolated: a window position is a step
    /// function committed by the window server, so the last committed value is
    /// the honest answer and an interpolation would invent positions.
    func frame(of id: CGWindowID, at t: CFAbsoluteTime) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = tracked[id], !ring.isEmpty else { return nil }
        var found: CGRect?
        for sample in ring.reversed() where sample.t <= t {
            found = sample.frame
            break
        }
        return found ?? ring.first?.frame
    }

    /// `frame(of:at:)` without the oldest-sample fallback: nil when the ring
    /// holds no sample at or before `t`, i.e. when the question "where was
    /// this window at `t`" is honestly unanswerable because tracking began
    /// after `t`. Curtain's capture-time attribution asks exactly that
    /// question about a detector frame captured ~70-100 ms before the walk
    /// (2026-09-09); a fallback to the first sample would answer it with a
    /// position from AFTER the pixels were captured, which is the skew the
    /// caller exists to remove.
    func frameStrict(of id: CGWindowID, at t: CFAbsoluteTime) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = tracked[id] else { return nil }
        for sample in ring.reversed() where sample.t <= t {
            return sample.frame
        }
        return nil
    }

    /// The most recent frame observed for `id`, whenever it was taken.
    /// Consecutive missed polls for a tracked id — the TRUE "currently
    /// unlisted" signal. `latestFrame` deliberately keeps returning the last
    /// good sample through a miss streak (paint fallback), so `== nil` there
    /// means "never successfully polled this episode", not "unlisted now"
    /// (curtain-loop review 2026-08-20, P1). 0 for untracked ids.
    func missStreak(of id: CGWindowID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return misses[id] ?? 0
    }

    /// How long `id` has been missing, in seconds since its last successful
    /// poll — the DURATION form of `missStreak`, for every consumer whose
    /// receipt is written in milliseconds (receipt at `deadSecs`). 0 for an
    /// untracked id, for an id whose last poll succeeded, and for a streak
    /// still under `missObservationFloor` observations: one dropped poll is
    /// not evidence at any cadence.
    func missSeconds(of id: CGWindowID) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard tracked[id] != nil, (misses[id] ?? 0) >= Self.missObservationFloor,
            let ok = lastOkAt[id]
        else { return 0 }
        return max(0, CFAbsoluteTimeGetCurrent() - ok)
    }

    func latestFrame(of id: CGWindowID) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return tracked[id]?.last?.frame
    }

    /// The newest `count` DISTINCT window positions, newest first, each stamped
    /// with the time it was FIRST observed.
    ///
    /// Why distinct: the poll runs at 120 Hz and the window server commits
    /// ~160 positions/s (trackA), so consecutive samples are frequently
    /// identical. A naive "last two samples" reads velocity 0 on a large share
    /// of the ticks of a real drag and collapses the projection.
    ///
    /// Why FIRST-observed: a position held across k polls is one commit, not k.
    /// Stamping it with the last poll that saw it would divide the same distance
    /// by a shorter interval and inflate the velocity — the error is unbounded
    /// as the drag slows, which is exactly when overshoot uncovers content.
    func recentDistinctSamples(of id: CGWindowID, count: Int) -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = tracked[id], !ring.isEmpty else { return [] }
        var out: [Sample] = []
        var i = ring.count - 1
        while i >= 0 && out.count < count {
            let frame = ring[i].frame
            var first = i
            while first > 0 && ring[first - 1].frame.origin == frame.origin { first -= 1 }
            out.append(Sample(t: ring[first].t, frame: frame))
            i = first - 1
        }
        return out
    }

    /// How long `id`'s frame has been unchanged at `t`, from the poll ring, or
    /// nil when the window is untracked or the ring holds only one position (so
    /// "still" cannot be distinguished from "never seen to move").
    ///
    /// Stamped with when the current frame was FIRST observed, for the same
    /// reason `recentDistinctSamples` is: a position held across k polls is one
    /// commit, and dating it from the last echo would report a moving window as
    /// still for a poll period after every commit.
    func stillSeconds(of id: CGWindowID, at t: CFAbsoluteTime) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = tracked[id], ring.count >= 2 else { return nil }
        let current = ring[ring.count - 1].frame
        var first = ring.count - 1
        while first > 0 && ring[first - 1].frame == current { first -= 1 }
        // The whole ring holds one position: the window has been still for at
        // least the ring's span, which is all this can honestly say.
        return t - ring[first].t
    }

    /// True once the poll thread is CONFIDENT the window is gone. Loss of the
    /// window is loss of ownership: the cover freezes and the pixel path
    /// re-anchors it (existing semantics).
    ///
    /// This used to latch on a SINGLE failed poll of any shape. It now requires
    /// `deadSecs` of consecutive polls whose cause was `unknownID`. A
    /// non-`unknownID` miss streak NEVER reaches "dead": an API failure is not
    /// evidence about a window. Real closure still drops promptly through the
    /// other door — `resolveOwners`' full snapshot reports
    /// `incumbentFrame == nil` on the next walk, which CoverOwnership already
    /// treats as authoritative.
    ///
    /// WHAT USED TO BE HERE, AND WHY IT IS NOT (iteration tk4, D6). tk3 also
    /// shipped a richer `Liveness` enum — `.live` / `.uncertain(misses:cause:)`
    /// / `.gone` / `.untracked` — meant to let a consumer tell "freeze" from
    /// "drop". Nothing ever read it, in this tree or any probe: it was a
    /// four-state contract with one caller, `isDead`, which only ever asked
    /// whether the state was `.gone`. The behavior it was designed to enable
    /// DID ship, by the other route — `CoverOwnership`'s cheap-frame path
    /// freezes on a stale poll ring (`latestFrame == nil`) and drops only on
    /// `isDead`, which is exactly the `.uncertain` semantics, decided from the
    /// ring rather than from a published enum.
    ///
    /// It was deleted rather than consumed. Consuming it would REPLACE a live
    /// path whose cost of being wrong is measured at 2904 ms of exposed player
    /// (runs/ipad-vfyA2-flick1) with an equivalent one, and that is a behavior
    /// change: it would need its own live evidence to ship, which is not a
    /// price a hygiene item gets to charge. `PollOutcome` stays — it is read
    /// by `missCause` and by the uncertain tripwire, both live.
    func isDead(_ id: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDeadLocked(id, at: CFAbsoluteTimeGetCurrent())
    }

    /// `isDead`'s predicate with the lock already held, so the poll loop's own
    /// dead-classification branch cannot drift from what consumers read.
    private func isDeadLocked(_ id: CGWindowID, at now: CFAbsoluteTime) -> Bool {
        guard tracked[id] != nil, let n = misses[id], n >= Self.missObservationFloor,
            (missCause[id] ?? .unknownID) == .unknownID, let ok = lastOkAt[id]
        else { return false }
        return now - ok >= Self.deadSecs
    }

    /// `isDead`, with the `.optionAll` verdict (receipt at `DeadKind`): nil
    /// while the id is alive, its streak is not `unknownID`, or the verdict
    /// is still pending — the poll loop takes it right after the poll that
    /// reaches `deadSecs`, so "pending" is at most one poll period wide and
    /// costs the curtain one poll of dead-clock, never a wrong kind.
    func deadKind(_ id: CGWindowID) -> DeadKind? {
        guard isDead(id) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return deadKinds[id]
    }

    /// Every window id the server knows, on screen or not — one `.optionAll`
    /// snapshot (cost receipt at `deadRecheckSecs`) — or nil when the window
    /// server REFUSED to answer.
    ///
    /// NIL IS NOT AN EMPTY LIST (2026-09-11). This used to read
    /// `?? []`, so a `CGWindowListCopyWindowInfo` that returned nothing to
    /// parse became "the server knows no windows at all" and every id the
    /// caller was classifying came back `.destroyed` — which is TERMINAL and
    /// is never re-checked, so one refused snapshot during a Space transition
    /// or a wake turned every offstage curtain into a closed one and lifted it
    /// on two clean frames instead of waiting `Curtain.deadLiftSecs`. "Absent
    /// from `.optionAll`" is the ONLY evidence of destruction this class has
    /// (receipt at `DeadKind`); a refusal is not that evidence, it is the
    /// absence of evidence. The caller skips the whole classification for that
    /// poll and counts a tripwire (receipt at `allRefusalTripwire`).
    ///
    /// The test seam returns `allWindowSource` rows when set, else
    /// `windowSource`'s; an `allWindowSource` that returns nil injects a
    /// refusal.
    private func allIDs() -> Set<CGWindowID>? {
        lock.lock()
        allSnapshots += 1
        lock.unlock()
        let raw: [[String: Any]]?
        if let allWindowSource {
            raw = allWindowSource()
        } else if let windowSource {
            raw = windowSource()
        } else {
            raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        }
        guard let raw else { return nil }
        return Set(raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// `.optionAll` snapshots taken since start (receipt at `deadRecheckSecs`).
    var allSnapshotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return allSnapshots
    }

    /// `.optionAll` snapshots the window server refused since start (receipt at
    /// `allRefusalTripwire`). Read by the scheduling receipt and the selftest.
    var allSnapshotRefusalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return allRefusals
    }

    /// (polls, mean ms per poll) since start — the perf receipt for the poll
    /// thread's duty cycle.
    var pollStats: (count: Int, meanMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (trackedPolls, trackedPolls > 0 ? pollWork * 1000 / Double(trackedPolls) : 0)
    }

    // MARK: - ownership

    /// Detect queue. One full z-order snapshot, then resolve every query against
    /// it (snapshot 1.2-1.4 ms, resolve 0.005 ms each — so callers batch).
    ///
    /// Rects are in CGWindowList space (screen points, top-left origin).
    /// Skipping non-layer-0 windows is load-bearing: the Dock owns a
    /// full-screen layer-20 window that would otherwise own every rect on the
    /// screen.
    func resolveOwners(
        _ queries: [Query], transparentOwners: Set<String> = []
    ) -> [Resolution] {
        var topmost: CGWindowID?
        return resolveOwners(queries, transparentOwners: transparentOwners, topmost: &topmost)
    }

    /// Curtain's walk (2026-09-09): the same resolution, plus the snapshot's
    /// TOPMOST eligible content window (front of the z-order, whatever the
    /// queries touch) so the caller can start its ring BEFORE a box lands on
    /// it. Same content eligibility filters as `resolve`, with own
    /// PID and transparent owners already dropped by `snapshot`.
    func resolveOwners(
        _ queries: [Query], transparentOwners: Set<String>, topmost: inout CGWindowID?
    ) -> [Resolution] {
        guard !queries.isEmpty else { return [] }
        let windows = snapshot(transparentOwners: transparentOwners)
        topmost = windows.first { $0.isContent }?.id
        return queries.map { resolve($0, windows, screen: screenFrame) }
    }

    /// Every LISTED eligible content window whose frame intersects `rect`, front to
    /// back, minus `except` and minus our own windows (`snapshot` already
    /// drops those). One z-order snapshot, the same 1.2-1.4 ms as
    /// `resolveOwners` — the curtain asks this once per destroyed window, at
    /// the moment it would lift, not per frame.
    ///
    /// Layer 0 or an identified Quick Look outer, for the reason `resolveOwners` gives: the Dock owns a
    /// full-screen layer-20 window that would otherwise "overlap" every rect
    /// on the screen. `alpha > 0.05` mirrors the same walk — an invisible
    /// window reveals nothing and cannot need covering. The caller passes the
    /// dead id as `except` for symmetry only: a `destroyed` id is by
    /// definition absent from this list already.
    func contentWindowIDs(
        intersecting rect: CGRect, except: CGWindowID? = nil,
        transparentOwners: Set<String> = []
    ) -> [CGWindowID] {
        snapshot(transparentOwners: transparentOwners)
            .filter {
                $0.isContent && $0.id != except
                    && $0.rect.intersects(rect)
            }
            .map { $0.id }
    }

    /// WindowManager surfaces are Stage Manager proxies. MEASURED 2026-08-26:
    /// a proxy with the same frame as a Chrome window received a duplicate
    /// curtain and caused repeated drop/lift cycles. Ownership resolution
    /// Curtain ownership resolution must continue to the real content window
    /// below it. Other cover pipelines do not request this filter.
    static let curtainTransparentOwner = "WindowManager"
    /// Test seam for the headless curtain state-machine checks. Production
    /// leaves this nil and reads the WindowServer directly.
    var windowSource: (() -> [[String: Any]])?
    /// Test seam for `deadKind`: the `.optionAll` list, when it must differ
    /// from `windowSource` (an offstage id is absent per id but listed here).
    /// Production and the default test rig leave it nil. Returning nil from the
    /// closure injects a WindowServer REFUSAL (receipt at `allIDs`), which is
    /// what `--ui-selftest`'s window-server-refusal case does.
    var allWindowSource: (() -> [[String: Any]]?)?

    /// Identity-only seams. No source capture or alternate detection path.
    var quickLookProcessSource: ((pid_t) -> (helper: Bool, host: Bool))?
    var onQuickLookIdentity: ((CGWindowID, pid_t) -> Void)?

    private struct Win {
        let id: CGWindowID
        let layer: Int
        let alpha: Double
        let rect: CGRect
        let isQuickLook: Bool
        let isHelper: Bool
        var isContent: Bool { alpha > 0.05 && !isHelper && (layer == 0 || isQuickLook) }
    }

    private func quickLookProcess(_ pid: pid_t) -> (helper: Bool, host: Bool) {
        if let quickLookProcessSource { return quickLookProcessSource(pid) }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return (false, false) }
        let helperPath = "/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService"
        let helper = app.executableURL?.path == helperPath
        return (helper, !helper && app.bundleIdentifier != nil && app.activationPolicy == .regular)
    }

    private func discoverQuickLook(in visible: [[String: Any]]) {
        let all: [[String: Any]]?
        if let allWindowSource { all = allWindowSource() }
        else if let windowSource { all = windowSource() }
        else { all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] }
        guard let all else { return }
        var processRoles: [pid_t: (helper: Bool, host: Bool)] = [:]
        func role(_ pid: pid_t) -> (helper: Bool, host: Bool) {
            if let cached = processRoles[pid] { return cached }
            let result = quickLookProcess(pid)
            processRoles[pid] = result
            return result
        }
        let present = Dictionary(all.compactMap { row -> (CGWindowID, pid_t)? in
            guard let id = row[kCGWindowNumber as String] as? CGWindowID,
                let pid = row[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return (id, pid)
        }, uniquingKeysWith: { first, _ in first })
        lock.lock()
        quickLookOwners = quickLookOwners.filter { present[$0.key] == $0.value }
        lock.unlock()
        for helper in all {
            guard let helperPID = helper[kCGWindowOwnerPID as String] as? pid_t,
                role(helperPID).helper,
                let helperID = helper[kCGWindowNumber as String] as? CGWindowID,
                let inner = Self.windowBounds(helper),
                (helper[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { continue }
            let candidates = visible.filter { row in
                guard let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                    pid != ownPID, role(pid).host,
                    (row[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                    let outer = Self.windowBounds(row) else { return false }
                return Self.isQuickLookPanelFrame(outer, enclosing: inner)
            }
            guard candidates.count == 1, let candidate = candidates.first,
                let id = candidate[kCGWindowNumber as String] as? CGWindowID,
                let pid = candidate[kCGWindowOwnerPID as String] as? pid_t else {
                if candidates.count > 1 {
                    lock.lock()
                    let first = reportedQuickLookAmbiguities.insert(helperID).inserted
                    lock.unlock()
                    if first { onReceipt?("quick-look identity ambiguous helper=\(helperID) candidates=\(candidates.count) remediation=WindowTracker.discoverQuickLook") }
                }
                continue
            }
            lock.lock()
            let alreadyKnown = quickLookOwners[id] == pid
            lock.unlock()
            guard alreadyKnown || pollable(id) else { continue }
            lock.lock()
            quickLookOwners[id] = pid
            reportedQuickLookAmbiguities.remove(helperID)
            lock.unlock()
            if !alreadyKnown { onQuickLookIdentity?(id, pid) }
        }
    }

    private static func windowBounds(_ row: [String: Any]) -> CGRect? {
        guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
            rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite,
            rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// Receipt: observed outer (1079,245,370,520), inner
    /// (1084,283,360,477): symmetric side/bottom border, larger title bar.
    /// No inset size limit. Zero-inset fullscreen geometry is not sufficient
    /// cold identity evidence; previously identified ID/PID pairs survive
    /// that transition without a new helper match.
    static func isQuickLookPanelFrame(_ outer: CGRect, enclosing inner: CGRect) -> Bool {
        guard outer.contains(inner) else { return false }
        let left = inner.minX - outer.minX
        return left > 0 && left == outer.maxX - inner.maxX
            && left == outer.maxY - inner.maxY && inner.minY - outer.minY >= left
    }

    func isQuickLookWindow(_ id: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return quickLookOwners[id] != nil
    }

    /// Hidden preview pixels are not clean-content evidence. This only
    /// retains an existing hold; it never creates or cuts an overlay.
    /// Missing metadata retains the hold; existing death handling still runs.
    func quickLookHolds(_ ids: Set<CGWindowID>) -> Set<CGWindowID> {
        guard !ids.isEmpty else { return [] }
        let windows = snapshot(transparentOwners: [Self.curtainTransparentOwner])
        return Set(ids.filter { id in
            guard let index = windows.firstIndex(where: { $0.id == id }) else { return true }
            return windows[..<index].contains {
                $0.isContent && $0.rect.intersects(windows[index].rect)
            }
        })
    }

    private func snapshot(transparentOwners: Set<String>) -> [Win] {
        let raw = windowSource?() ?? (
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? [])
        discoverQuickLook(in: raw)
        lock.lock()
        let known = quickLookOwners
        lock.unlock()
        var out: [Win] = []
        var helperRoles: [pid_t: Bool] = [:]
        out.reserveCapacity(raw.count)
        for w in raw {
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                let id = w[kCGWindowNumber as String] as? CGWindowID,
                (w[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                !transparentOwners.contains(w[kCGWindowOwnerName as String] as? String ?? "")
            else { continue }
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let helper = helperRoles[pid] ?? quickLookProcess(pid).helper
            helperRoles[pid] = helper
            out.append(Win(id: id, layer: w[kCGWindowLayer as String] as? Int ?? 0,
                           alpha: w[kCGWindowAlpha as String] as? Double ?? 1, rect: rect,
                           isQuickLook: known[id] == pid, isHelper: helper))
        }
        return out
    }

    /// Per-walk trace for ownership investigation (`SENTRY_WINDOW_DEBUG=1`).
    static let debug = DevEnv.knob("SENTRY_WINDOW_DEBUG") != nil

    /// Fraction of `rect`'s area that lies inside `window` inflated by
    /// `containTolerance`. 0 for a degenerate rect — a cover with no area is
    /// not held by anything.
    static func heldFraction(_ rect: CGRect, in window: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        let tol = Self.containTolerance
        let inter = rect.intersection(window.insetBy(dx: -tol, dy: -tol))
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        return (inter.width * inter.height) / area
    }

    private func resolve(_ q: Query, _ windows: [Win], screen: CGRect) -> Resolution {
        var out = Resolution()
        // The list is front-to-back, so the first eligible content hit is the frontmost.
        var front: Win?
        for w in windows where w.isContent {
            if w.rect.intersects(q.authority) {
                front = w
                break
            }
        }
        if let front {
            out.frontID = front.id
            out.frontFrame = front.rect
            out.frontHoldsGate =
                Self.heldFraction(q.gate, in: front.rect) >= Self.minContainedFraction
        }
        if let incumbent = q.incumbent {
            if let w = windows.first(where: { $0.id == incumbent }) {
                out.incumbentFrame = w.rect
                out.incumbentHoldsAuthority =
                    Self.heldFraction(q.authority, in: w.rect) >= Self.minContainedFraction
            }
        }
        if Self.debug {
            print("winresolve auth=\(q.authority) gate=\(q.gate) "
                + "front=\(out.frontID.map { "\($0)@\(out.frontFrame!)" } ?? "none") "
                + "frontHoldsGate=\(out.frontHoldsGate) "
                + "incumbent=\(q.incumbent.map(String.init) ?? "none") "
                + "incumbentHolds=\(out.incumbentHoldsAuthority)")
        }
        // Floating (layer > 0) windows over the cover are TRACED, not vetoed.
        //
        // trackA's mapping probe suggested vetoing on them ("OWNED but a
        // floating window overlaps — verify or fall back"). Measured on this
        // desktop, that veto disables window tracking outright: Wispr Flow (a
        // dictation utility) keeps a permanent layer-1000 "Status" window at
        // (720, 435, 480, 570) — dead centre of a 1920x1080 screen and visually
        // empty — so the first live smoke run refused ownership on 100% of
        // walks and logged zero window records. CGWindowList's `alpha` is the
        // window's alpha property, not its content opacity, so there is no way
        // to tell that window from a real occluder.
        //
        // v3 claimed dropping the veto was "safe in the over-block direction".
        // FALSIFIED: an occluder
        // dragged across the covered player BECAME the owner for 138 log frames
        // and carried the cover away with it on its 1520 pt/s retreat, leaving
        // the revealed player face bare for 300 ms fully and 600 ms+ partially.
        // The veto is still not the fix — it cannot see a real occluder — so
        // what replaced it is a LAYER-0 test that does not need transparency
        // information at all: `frontID` above is reported even when it is not
        // the incumbent, and main.swift freezes the cover rather than handing it
        // over (defects 1b/1c). An unidentified layer>0 floater still cannot take ownership.
        // Identified Quick Look panels use the same ownership rules.
        if Self.debug {
            let floaters = windows.filter { w in
                w.layer > 0 && w.alpha > 0.05 && w.rect.intersects(q.authority)
                    && !(w.rect.width >= screen.width * Self.fullScreenishW
                        && w.rect.height >= screen.height * Self.fullScreenishH)
            }
            if !floaters.isEmpty {
                print("  -> floaters (traced, not vetoed) "
                    + floaters.map { "l\($0.layer)@\($0.rect)" }.joined(separator: " "))
            }
        }
        return out
    }

    /// The frame of one already-known window, straight from the window server,
    /// WITH the reason when there isn't one. 0.089 ms/call standalone, ~1.0 ms
    /// wall in-process (trackA + the IPC note in main.swift's shutdown line).
    /// Used by the poll loop only.
    ///
    /// The three failure shapes are kept apart here because they are three
    /// different claims — see `PollOutcome`. The old version returned `nil` for
    /// all of them and the caller wrote the window off on the first one.
    /// One-shot pollability probe: does the window server answer a direct
    /// per-id query for this window right now? Curtain's ghost-breaker
    /// (2026-08-20): a surface the SNAPSHOT lists as frontmost-holding but
    /// that dies on per-id polls churned 2 s drop/dead-lift cycles (window
    /// 98, owner session) — a candidate must pass this probe to be
    /// curtained. Costs one CGWindowList per-id query (~fraction of the
    /// 1.2-1.4 ms full snapshot), paid only at drop decisions.
    func pollable(_ id: CGWindowID) -> Bool {
        let (frame, outcome) = liveFrame(id)
        return outcome == .ok && frame != nil
    }

    private func liveFrame(_ id: CGWindowID) -> (CGRect?, PollOutcome) {
        if let source = windowSource {
            let rows = source().filter {
                ($0[kCGWindowNumber as String] as? CGWindowID) == id
            }
            guard let first = rows.first else { return (nil, .unknownID) }
            guard let bounds = first[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return (nil, .malformed) }
            return (rect, .ok)
        }
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
            as? [[String: Any]]
        else { return (nil, .apiFailed) }
        guard let first = raw.first else { return (nil, .unknownID) }
        guard let bounds = first[kCGWindowBounds as String] as? [String: Any],
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return (nil, .malformed) }
        return (rect, .ok)
    }

    // MARK: - poll loop

    /// A gap this long is not a scheduling stall, it is a suspension (display
    /// sleep, a stopped process). Walking the phase grid forward across one is
    /// pointless work, and the ring's whole span is 2.13 s anyway, so every
    /// sample on the far side of a 1 s gap is already older than any lookback
    /// asks for. Re-phase instead. Either branch is safe for the defect this
    /// fixes — both leave a full poll period before the next sample.
    private static let rephaseAfter = 1.0

    /// Zero-window idle cost (2026-08-21): DERIVED. When `ids` is empty
    /// the `if !ids.isEmpty` branch below never runs — no
    /// `CGWindowListCopyWindowInfo` call, no ring write — so each iteration
    /// is just the lock/unlock snapshot of `tracked.keys` plus a sleep. That
    /// path is not separately profiled, but the 2026-08-21 baseline soak
    /// measured the WHOLE
    /// daemon at 6.3% avg CPU on an idle-ish desktop with this thread running
    /// the entire 629 s run in curtain-cover mode — i.e. that run's poll
    /// thread was doing real per-id work some of the time, not sitting in the
    /// empty-`ids` branch throughout. The empty-set path is strictly cheaper
    /// than whatever that run's poll thread actually did, so it is bounded
    /// well inside that 6.3% headline number. The header RECEIPTS block's
    /// 1.26%/core figure is priced per ACTIVE id; it says nothing about, and
    /// isn't claimed to cover, this idle floor.
    /// Idle-down (skip polling / lengthen the period while `ids` is empty)
    /// was considered and rejected: a poll thread that must wake fast when a
    /// curtain drops adds latency exactly when a cover needs fresh geometry —
    /// the whole point of this class (WHY, top of file) is beating the pixel
    /// pipeline's capture+detect latency, and a slow-to-wake idle mode would
    /// reintroduce that gap on every first drop.
    private func pollLoop() {
        let period = 1.0 / Self.pollHz
        var next = CFAbsoluteTimeGetCurrent()
        while true {
            lock.lock()
            let alive = running
            let ids = Array(tracked.keys)
            // Folded into the same critical section: a separate lock/unlock
            // pair just to bump the counter doubled lock traffic on the
            // 120 Hz tick (review 2026-08-25). Guarded so the exiting tick
            // still isn't counted, as before.
            if alive { pollCount += 1 }
            lock.unlock()
            if !alive { return }
            if !ids.isEmpty {
                let start = CFAbsoluteTimeGetCurrent()
                var observed: [(CGWindowID, CGRect?, PollOutcome, CFAbsoluteTime)] = []
                observed.reserveCapacity(ids.count)
                for id in ids {
                    // Stamp each observation with ITS OWN read time, not the
                    // time the whole batch finished (tk3 Stream W). The batch
                    // takes 0.8 ms mean but p100 18-38 ms on this machine
                    // (scratchpad/streamW/pollprobe.swift), and a batch-end
                    // stamp charges all of that to the first id read — a
                    // first-observed timestamp up to 38 ms later than the truth,
                    // straight into the velocity fit. It is also the residual
                    // source of same-instant sample pairs that survives the
                    // scheduling fix below: a slow poll stamps late, so the next
                    // (fast) poll stamps only ~1 ms after it. MEASURED: with
                    // skip-ahead alone the injected-stall probe still logged 20
                    // pairs closer than half a period in 30 s.
                    let readAt = CFAbsoluteTimeGetCurrent()
                    let (frame, outcome) = self.liveFrame(id)
                    observed.append((id, frame, outcome, readAt))
                }
                let now = CFAbsoluteTimeGetCurrent()
                var tripwire: (CGWindowID, Double, Int, PollOutcome)?
                var classify: [CGWindowID] = []
                lock.lock()
                for (id, frame, outcome, readAt) in observed {
                    guard tracked[id] != nil else { continue }  // untracked mid-poll
                    guard let frame else {
                        let n = (misses[id] ?? 0) + 1
                        misses[id] = n
                        missCause[id] = outcome
                        // Dead classification (receipt at `DeadKind`): on the
                        // poll the streak reaches deadSecs, then at most once
                        // per deadRecheckSecs while it lasts — unless it is
                        // already `.destroyed` (terminal, receipt at
                        // deadRecheckSecs) or the streak has used its
                        // re-checks (receipt at deadRechecksPerStreak).
                        if outcome == .unknownID, isDeadLocked(id, at: now),
                            deadKinds[id] != .destroyed,
                            (deadChecks[id] ?? 0) <= Self.deadRechecksPerStreak,
                            now - (deadCheckedAt[id] ?? 0) >= Self.deadRecheckSecs
                        {
                            classify.append(id)
                        }
                        // Loud, once: a miss streak on a cause that can never
                        // make `isDead` true would otherwise sit forever behind
                        // a frozen cover with nothing in the run's output to say
                        // so.
                        let missSecs = now - (lastOkAt[id] ?? now)
                        if outcome != .unknownID, n >= Self.missObservationFloor,
                            missSecs >= Self.uncertainTripwireSecs,
                            !tripwired.contains(id)
                        {
                            tripwired.insert(id)
                            tripwire = (id, missSecs, n, outcome)
                        }
                        continue
                    }
                    misses[id] = 0
                    missCause[id] = nil
                    lastOkAt[id] = readAt
                    deadKinds[id] = nil
                    deadCheckedAt[id] = nil
                    deadChecks[id] = nil
                    tripwired.remove(id)
                    if let last = tracked[id]!.last, readAt - last.t < period / 2 {
                        closeSamples += 1
                        // The ORIGIN, not the whole frame: `recentDistinctSamples`
                        // — the only ring read that divides by time — collapses on
                        // `frame.origin`, so an origin-repeat close pair is
                        // discarded before any arithmetic and a pure resize is
                        // stamped with the run's FIRST poll (a longer dt, the
                        // conservative direction). Counting anything else here
                        // would over-report the tripwire again.
                        if last.frame.origin != frame.origin { closeNewPosition += 1 }
                    }
                    tracked[id]!.append(Sample(t: readAt, frame: frame))
                    if tracked[id]!.count > Self.ringLength { tracked[id]!.removeFirst() }
                }
                trackedPolls += 1
                pollWork += now - start
                lock.unlock()
                if !classify.isEmpty {
                    // One snapshot for every id that needs it, outside the lock
                    // (4.5 ms, receipt at deadRecheckSecs).
                    let all = allIDs()
                    let at = CFAbsoluteTimeGetCurrent()
                    var refusal: (streak: Int, total: Int, pending: Int)?
                    lock.lock()
                    if let all {
                        allRefusalStreak = 0
                        allRefusalTripwired = false
                        for id in classify where tracked[id] != nil && (misses[id] ?? 0) > 0 {
                            deadKinds[id] = all.contains(id) ? .offstage : .destroyed
                            deadCheckedAt[id] = at
                            deadChecks[id] = (deadChecks[id] ?? 0) + 1
                        }
                    } else {
                        // REFUSED (receipt at `allIDs`). Classify NOTHING: the
                        // only evidence of destruction is absence from a list
                        // the server actually produced. The re-check clock and
                        // budget are still charged, so a refusal storm costs
                        // exactly what a healthy streak costs (receipts at
                        // deadRecheckSecs / deadRechecksPerStreak) instead of
                        // one 4.5 ms snapshot per poll.
                        allRefusals += 1
                        allRefusalStreak += 1
                        // SAME guard as the success branch above, to the letter
                        // (review 2026-09-11). `tracked[id] != nil` alone would
                        // charge a re-check against a FRESH streak for an id
                        // that `setTracked` removed and re-added between the
                        // unlock and this snapshot (its misses are back to 0) —
                        // which is not "costs exactly what a healthy streak
                        // costs", the claim this branch's receipt makes.
                        for id in classify where tracked[id] != nil && (misses[id] ?? 0) > 0 {
                            deadCheckedAt[id] = at
                            deadChecks[id] = (deadChecks[id] ?? 0) + 1
                        }
                        if allRefusalStreak >= Self.allRefusalTripwire, !allRefusalTripwired {
                            allRefusalTripwired = true
                            refusal = (allRefusalStreak, allRefusals, classify.count)
                        }
                    }
                    lock.unlock()
                    if let refusal {
                        let info = "window-list-refused: budget=allRefusalTripwire configured="
                            + "\(Self.allRefusalTripwire) snapshot(s) observed=\(refusal.streak) "
                            + "consecutive (\(refusal.total) since start) "
                            + "pendingIDs=\(refusal.pending); dead classification SKIPPED "
                            + "(a refusal is not evidence of destruction, so the curtain keeps "
                            + "holding); remediation=WindowTracker.allRefusalTripwire"
                        FileHandle.standardError.write(Data(("TRIPWIRE: " + info + "\n").utf8))
                        onTripwire?(info)
                    }
                }
                if let (id, secs, n, outcome) = tripwire {
                    let info = String(
                        format: "window-tracker-uncertain: budget=uncertainTripwireSecs "
                            + "configured=%.2f s observed=%.2f s (%d consecutive polls) "
                            + "window=%u cause=%@; cover frozen fail-safe; "
                            + "remediation=WindowTracker.uncertainTripwireSecs",
                        Self.uncertainTripwireSecs, secs, n, id, "\(outcome)")
                    FileHandle.standardError.write(Data(("TRIPWIRE: " + info + "\n").utf8))
                    onTripwire?(info)
                }
            }
            next += period
            var sleep = next - CFAbsoluteTimeGetCurrent()
            if sleep <= 0 {
                // FELL BEHIND. SKIP AHEAD ON THE PHASE GRID, do not re-phase to
                // now (tk3 Stream W).
                //
                // The old `next = CFAbsoluteTimeGetCurrent()` made the very next
                // iteration poll IMMEDIATELY, so a stall was always followed by
                // two samples ~0.4 ms apart. If the window server committed a
                // position inside that gap — it commits >160/s during a drag, so
                // it does, 6% of the time — those two samples hold two DISTINCT
                // positions whose first-observed stamps are 0.4 ms apart, and
                // the 2-tap velocity read 10 650 pt/s on a 240 pt/s drag
                // (receipt: PaintExtrapolator.minVelocityBaseline, 436 pt of
                // overshoot on runs/ipad-v3-flick1 f110). The span fit and
                // `minVelocityBaseline` were the tk2 mitigation; this removes
                // the artifact at its source instead of filtering it downstream.
                //
                // MEASURED (scratchpad/streamW/pollprobe.swift, deterministic
                // 45 ms stall every 370 ms, 30 s, same machine and load):
                // ring-sample pairs closer than half a poll period, 94 with the
                // old re-phase vs 20 with skip-ahead; the remaining 20 are the
                // batch-stamp effect fixed above. Real lateness is not
                // hypothetical: p100 was 11-14 ms idle and 185 ms under three
                // concurrent `swiftc -O` jobs.
                //
                // Skipping forward also keeps the 120 Hz cadence receipts
                // honest: the poll count still tracks elapsed time (measured
                // 3194 polls in 30 s under injected stalls = 106 Hz — the
                // stalled periods really are missed, and are reported as missed,
                // instead of being back-filled by a burst).
                lock.lock()
                if -sleep > Self.lateTolerance { lateCount += 1 }
                maxLate = max(maxLate, -sleep)
                lock.unlock()
                let now = CFAbsoluteTimeGetCurrent()
                if now - next > Self.rephaseAfter {
                    next = now + period
                } else {
                    while next <= now { next += period }
                }
                sleep = next - CFAbsoluteTimeGetCurrent()
            }
            let heartbeat = CFAbsoluteTimeGetCurrent()
            let every = onReceipt == nil ? Self.receiptEvery : Self.liveReceiptEvery
            if heartbeat - lastReceiptAt >= every {
                lastReceiptAt = heartbeat
                emitSchedulingReceipt("-- windowTracker sched", force: onReceipt == nil)
            }
            if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
        }
    }
}
