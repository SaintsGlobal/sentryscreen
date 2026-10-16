import CoreGraphics
import Foundation

/// Which window owns each media cover, and where that cover sits INSIDE that
/// window.
///
/// v3 answered "which window" with a stateless containment test per frame and
/// rode whatever came back. The adversarial pass measured three failures of
/// that design, and all three are failures of statelessness:
///
///   1. **Ownership jump (safety).** An occluder dragged over the covered
///      player satisfied the containment test better than the player's own
///      window did, became the owner for 138 log frames, and carried the cover
///      away on its 1520 pt/s retreat — 300 ms of fully bare player face.
///   2. **Fast-path self-disable.** The test ran against the MOTION-EXPANDED
///      cover, which the heat field smears past the window's own width at
///      speed (p90 1.37x the window at 600-1000 pt/s), so ownership was refused
///      on 88% of the fastest frames — the fast path switched itself off
///      exactly when it was needed.
///   3. **Erratic-drag box collapse.** With no window-relative memory, the
///      cover is whatever the detector says this frame, and on an erratic walk
///      the detector says nothing on ~82% of frames (mediaBoxes=0).
///
/// The state this class keeps is what fixes all three:
///   * an INCUMBENT that is not displaced while it still exists and still holds
///     the cover, whatever the z-order says (defect 1b);
///   * a sticky OCCLUSION latch that freezes the cover instead of riding the
///     window in front of it (defect 1c);
///   * a window-relative PIN — the cover as fractions of the owner's frame,
///     measured from pixels while the window was still — which is what the
///     overlay rides during motion (defects 2, 3, 4, 5);
///   * a DISAGREEMENT timer that drops ownership loudly when the pin and the
///     pixels stop describing the same thing for more than a second (1d).
///
/// Detect queue only, like the rest of the pipeline's mutable state. Live only:
/// `--process` never constructs one, so no headless log can observe it.
final class CoverOwnership {
    /// What one region's ownership resolves to on one capture frame. Copied
    /// into `PaintExtrapolator.Anchor` and carried to the overlay.
    struct Verdict {
        var windowID: CGWindowID?
        var ownerFrame: CGRect?
        var pin: CGRect?
        var frozen = false
    }

    /// How long that disagreement must persist before ownership is dropped.
    /// 1.0 s = 30 capture frames, and the longest legitimate blind stretch the
    /// pixel path has ever shown is the media latch riding out detector
    /// dropouts, which `Tracker.defaultStickyHold` sizes at exactly 1.0 s.
    /// Shorter would drop ownership on a dropout; longer is a second of riding
    /// something that is not the player.
    private static let disagreeSecs = 1.0

    /// Consecutive REGISTERED updates an outward move must be asked for before
    /// any of it is applied. Same rule, same reason and the same size as
    /// `PaintSmoother.outwardPersist`: 2 is the smallest number that can tell a
    /// one-frame smear peak from a real grow, and it is bought with one update
    /// (33 ms) of margin lag at the start of a genuine one. The pin can only
    /// grow (see `Held.remeasureUpdates`), so every transient peak it swallows is
    /// permanent until the window resizes — which makes this cheaper here than
    /// it is in the smoother, not more expensive.
    private static let pinGrowPersist = 2

    /// Most an edge may move OUTWARD in one pin update, in grid cells of the
    /// owner window (one cell = 1/160 of the frame, the media grid's own
    /// quantum — see `pinShrinkPerSecond`).
    ///
    /// Growth used to be unlimited, on the grounds that over-cover is the safe
    /// direction. It is the safe direction and it is also the whole T7 defect:
    /// unbounded `pin.union(candidate)` is what turns one mis-registered
    /// candidate into a permanent 1.33-1.375x pin (tk2 receipts; the mechanism
    /// is at `registrationDebt`). A cap is what makes the two compatible.
    ///
    /// Sized from both ends, and RESTATED 2026-09-08 so each end keeps the
    /// unit it was actually measured in (one of the six live-paint constants
    /// the receipt audit left as a KNOWN GAP; an update is a frame, this class
    /// resolves every frame).
    ///
    ///   LOWER — A RATE, so it is fps-derived. "A pin that has to recover from
    ///   a bad measurement must do so in about a second": 2 cells per update at
    ///   the 30 Hz capture rate is 15.625 pt x 30 = 469 pt/s on this scene's
    ///   1250 pt window, and the worst pin collapse on record
    ///   (runs/ipad-v3-flick4's cold start, 809 pt of under-cover) closes in
    ///   1.7 s. Held fixed at 2 cells/update that rate HALVES at the no-ane
    ///   tier — 235 pt/s, 3.4 s to close the same collapse.
    ///   `pinGrowCellsPerSec` = 60 keeps 469 pt/s at every fps.
    ///
    ///   UPPER — A PER-STEP LIMIT, so it is fps-INVARIANT and clamps the rate.
    ///   The acceptance bar is "no single pin step above +0.05 area". One cell
    ///   is 7.8 pt on the 1250 pt window, +0.7% of one dimension on a ~1150 pt
    ///   pin, i.e. +0.0075 area at 1.10x per edge; both edges of an axis can
    ///   move in the same step, so n cells costs 0.015n and the bar is reached
    ///   at n = 3.33. `pinGrowCellsStepCap` = 3 is the largest whole cell count
    ///   under it (0.045 against 0.05). The pre-tier 2 sat at 0.030, and 60/15
    ///   = 4 would sit at 0.060 — OVER the bar, which is why this clamp exists
    ///   rather than the bare rate.
    ///
    /// At 15 fps the clamp binds: 3 cells/update = 351 pt/s, closing the 809 pt
    /// collapse in 2.3 s instead of 3.4 s. That is the honest cost of the tier,
    /// not a number chosen to look better. At 30 fps the rate binds and returns
    /// exactly 2 (60.0/30.0 is 1:1 exact in IEEE double).
    ///
    /// The third half of the old receipt still holds by construction: this must
    /// stay above `PaintSmoother.capCells`, so the pin can always keep up with
    /// the pixel path it is measuring and never outrun it. 2 > 1 at 30 fps,
    /// 3 > 2 at 15 fps. Asserted per tier in `PerfTier.selftest`.
    static let pinGrowCellsPerSec: CGFloat = 60
    static let pinGrowCellsStepCap: CGFloat = 3
    static func pinGrowCells(fps: Int) -> CGFloat {
        min(pinGrowCellsStepCap, pinGrowCellsPerSec / CGFloat(fps))
    }
    /// The receipt's own measurements, named so `PerfTier.selftest` can assert
    /// both ends of the derivation instead of trusting the prose above.
    /// `worstPinCollapsePt` is runs/ipad-v3-flick4's cold start on a
    /// `receiptWindowPt`-wide window; `pinStepAreaPerCell` is the +0.015 area
    /// that 2 cells measured at 1.10x, halved to one cell, per edge; both edges
    /// of an axis can move in one step, and `pinStepAreaBar` is the acceptance
    /// bar they must stay under together.
    static let worstPinCollapsePt: CGFloat = 809
    static let receiptWindowPt: CGFloat = 1250
    static let pinStepAreaPerCell: CGFloat = 0.0075
    static let pinStepAreaBar: CGFloat = 0.05

    /// Set once by `Pipeline` from the effective fps, before the first resolve.
    /// The defaults are the 30 fps values, so a path that never sets them (the
    /// algorithm loop) behaves exactly as this class did before they were
    /// derived.
    /// NAME NOTE: this instance value deliberately shares its name with the
    /// static derivation it is set from. They are in different scopes, so
    /// this compiles and a mistaken `Self.pinGrowCells` would be a type error
    /// rather than a silent wrong value — but inside these state machines
    /// read the bare name as "the resolved value for THIS run".
    var pinGrowCells = CoverOwnership.pinGrowCells(fps: 30)
    var pinRemeasureUpdates = CoverOwnership.pinRemeasureUpdates(fps: 30)

    /// How long a pin is remembered after its region stops being media-held,
    /// so that a momentary latch loss does not force a cold re-acquisition.
    ///
    /// Receipt (tk2, streamA-vfy VERDICT, ipad-vfyA2-flick1): a 238 ms
    /// `windows[]` dropout mid-drag ended ownership, the pipeline rect
    /// collapsed to 1063.4 x 670.4 pt, and the next walk re-acquired straight
    /// onto the collapsed rect (pin 0.8507 x 0.8380 = exactly those points on a
    /// 1250 x 800 window). 2904 ms / 88 consecutive exposed frames followed.
    /// Nothing about that acquisition was wrong under the old rule — a fresh
    /// acquisition has no prior and must believe the pixels. Giving it a prior
    /// is the fix. 1.0 s covers the measured 238 ms dropout with 4x margin and
    /// matches `disagreeSecs`, the other "how long may this layer disbelieve
    /// the pixels" constant.
    private static let pinLapseSecs = 1.0

    /// How many REGISTERED updates after an acquisition or a window resize the
    /// pin may still be re-measured outright (receipt at `Held.remeasureUpdates`).
    ///
    /// RESTATED AS A DURATION 2026-09-08 (one of the six live-paint constants
    /// the receipt audit left as a KNOWN GAP). The receipt was already written
    /// in seconds and the constant was not: "30 = 1.0 s at the 30 Hz capture
    /// rate: the same 'how long may this layer act on unconfirmed evidence'
    /// figure `disagreeSecs` and `pinLapseSecs` carry". Those two are
    /// `CFTimeInterval` constants that do not move with fps, so a fixed 30 was
    /// the one of the three that silently drifted to 2.0 s at the no-ane tier.
    /// `pinRemeasureSecs` x fps keeps all three at 1.0 s: 30 updates at 30 fps
    /// (exactly the pre-tier value, integer arithmetic), 15 at 15 fps.
    ///
    /// SECOND TERM, an UPDATE FLOOR, and it is not decoration — the fps sweep in
    /// `PerfTier.selftest` falsified the one-term version at the 10 fps floor.
    /// The other half of the receipt is "2x the 0.5 s PaintSmoother needs to
    /// walk its worst measured stale edge out after a size change, so a real
    /// resize is fully converged before the window closes", and that was true at
    /// 30 fps by arithmetic accident. `PaintSmoother.capCells` is now derived to
    /// hold that convergence at 0.479 s wherever its RATE binds (fps 15..30), so
    /// the 1.0 s term stays 2x it there. Below 15 fps the smoother's no-pop
    /// clamp binds instead: the cap sticks at 2 cells/frame, so the worst stale
    /// edge takes a FIXED 7.19 updates to walk out however slow the frame rate
    /// is, and 2x that is 15 updates — an update count, not a duration, which is
    /// exactly why it cannot be folded into the 1.0 s term. At 10 fps the
    /// one-term version gave 10 updates against a 14.4-update settle: a
    /// re-measure window that closed before the resize it exists to cover had
    /// finished.
    ///
    /// The floor is written here rather than read from
    /// `PaintSmoother.convergeSecs` because Overlay.swift is not in the
    /// algorithm-loop target's source list (scripts/build.sh) and this file is.
    /// `PerfTier.selftest`, which sees both, asserts the >= 2x relationship at
    /// every fps rather than leaving this paragraph to be believed.
    ///
    /// 30 updates at 30 fps (the duration wins — exactly the pre-tier value),
    /// 15 at 15 fps (the two terms tie at 1.0 s), 15 at the 10 fps floor (the
    /// settle floor wins, 1.5 s).
    ///
    /// Integer arithmetic in the same two-term shape as
    /// `Tracker.defaultStickyHold`, not `(secs * fps).rounded()`:
    /// `pinRemeasureUpdatesAt30` IS the 1.0 s the receipt names, at the fps
    /// every receipt in this repo was measured at, and `(30 * 30) / 30` is
    /// exactly 30 with no floating point anywhere near it.
    static let pinRemeasureSecs = 1.0
    static let pinRemeasureUpdatesAt30 = 30
    static let pinRemeasureSettleFloor = 15
    static func pinRemeasureUpdates(fps: Int) -> Int {
        max(pinRemeasureSettleFloor, (pinRemeasureUpdatesAt30 * fps) / 30)
    }

    /// WHY THERE IS NO STEADY-STATE SHRINK ANY MORE (iteration tk3).
    ///
    /// Every rule below this line used to describe how fast the pin may follow
    /// a candidate INWARD. tk3 measured what that candidate actually is in a
    /// quiet tail and the answer removes the question. On
    /// runs/ipad-tk3P2-flick1 and -flick3, t >= 24 s, the candidate's right
    /// edge sits at 858-1093 recording px against a true player edge of 1171.9
    /// — 80 to 314 px INSIDE the player, continuously, for the whole 14 s tail,
    /// with no excursion above it at any point. Any rate, any sustained-
    /// evidence bar and any trailing-maximum envelope therefore converge to the
    /// same place: the pin walks off the player's right edge. Measured on those
    /// two runs with a 2 s bar at 1/160 window/s — the pin's 18 px margin was
    /// gone in 6 s and 5.2-5.6 s of real exposure followed (161 and 172 flagged
    /// frames, threshold 0).
    ///
    /// So the pin does not shrink while the owner window's SIZE is unchanged.
    /// A media element is a fixed-size thing in a fixed-size window; the one
    /// event that is positive evidence its window-relative geometry changed is
    /// a window resize, and that path re-measures outright (`remeasureUpdates`)
    /// rather than creeping. What is given up is the small legitimate
    /// correction iteration 9 measured — 0.0138 of the window, 16-17 pt, three
    /// times in a 95 s run — i.e. at most ~0.02 of area ratio in over-cover.
    /// That is the trade, taken deliberately: an over-cover of 17 pt costs
    /// nothing, and this iteration has the receipt that the evidence which
    /// would buy it back is wrong by an order of magnitude more.
    ///
    /// THE REAL DEFECT IS UPSTREAM and is NOT fixed by this class: MotionBoxes'
    /// box estimate loses 80-314 px of the player's right edge in a quiet tail
    /// (tk2 §3). Until that is fixed, this rule is what keeps the pin off it.
    ///
    /// Kept below for the resize path only: how fast a RE-MEASURE may pull an
    /// edge inward, as a fraction of the owner window per second per edge.
    ///
    /// Receipt, from the cycle-i8e pin traces (`SENTRY_WINDOW_DEBUG` on
    /// runs/i8e-multi1) and runs/i8e-drag1's aligned record table. Every
    /// LEGITIMATE re-pin shrink measured in a 95 s multi-window run is small —
    /// 0.0138, 0.0134 and 0.0138 of the window (rows 89->160, 1248->1319,
    /// 2421->2491), i.e. 16-17 pt on a 1200 pt window. Every shrink that was a
    /// DEFECT is an order of magnitude bigger and lasts for seconds: 0.353 of
    /// the window on i8e-drag1 (the fragment split, pin width 0.9876 -> 0.6181,
    /// held for 4.1 s) and 0.157 on i8e-multi1 (rows 557-616, 60 frames).
    ///
    /// A time-based "sustained evidence" gate cannot separate them — the
    /// collapsed candidate on i8e-drag1 is stable from t=1.81 s to t=5.89 s, so
    /// any threshold under 4 s adopts it and any threshold over 4 s stops the
    /// pin working at all. A RATE separates them: at 1/160 of the window per
    /// second the legitimate corrections above complete in 2.2 s (over-covering
    /// meanwhile, which costs nothing), while a 4 s collapse can only move an
    /// edge 0.025 of the window — 30 pt instead of 424.
    ///
    /// 1/160 is the media grid's own quantum expressed against the window
    /// (MotionBoxes.gridWidth = 160 over the frame): the estimator cannot
    /// resolve a smaller step, so nothing legitimate is being slowed below the
    /// resolution of the thing measuring it.
    ///
    /// This is a TRIPWIRE on the pixel path, not a model of it. If it is ever
    /// the thing keeping a cover honest for seconds at a time, MotionBoxes lost
    /// the player and THAT is what to fix — the limit only buys time.
    private static let pinShrinkPerSecond: CGFloat = 1.0 / 160.0

    /// SETTLED GEOMETRY STEP (iteration tk4, defect D5) — the pin follows an
    /// IN-WINDOW media resize outward, on evidence that a standing estimator
    /// bias cannot fake.
    ///
    /// THE DEFECT. An in-window geometry change — a page zoom, a control bar
    /// appearing, an aspect switch — moves the player inside an UNCHANGED
    /// window, so the window-resize re-measure never fires. Measured on
    /// scenes/zoom.html (media 1120x630 <-> 896x504 on a 15 s timetable in a
    /// fixed 1250x800 window): when the pin is acquired while the media is
    /// small and the media then GROWS, the ordinary growth path below cannot
    /// close the gap. runs/ipad-S-zoom-fix1: 80 px inside the player's right
    /// edge for 374 consecutive frames, 14.8 s, peak 55 443 exposed px, on the
    /// tk3 policy with no change of mine reachable. runs/ipad-S-zoom-fix4:
    /// 136 of 376 frames, 6.9 s. The cause is `pinGrowPersist` — growth needs
    /// two CONSECUTIVE registered asks, and on a quiet tail the region's right
    /// edge only reaches the player intermittently (tk2 §3's collapse, D4), so
    /// two in a row never arrive.
    ///
    /// THE RULE. The candidate is never used as a target — only for the DELTA
    /// between two SETTLED levels of itself:
    ///
    ///   1. `settleWindow` keeps `stepSettleSecs` of REGISTERED candidates;
    ///      the candidate is SETTLED when every edge's spread over that window
    ///      is inside `stepBandCells`.
    ///   2. The first settled level becomes `settledRef`.
    ///   3. A later settled level at least `stepMinCells` OUTSIDE the
    ///      reference on BOTH edges of an axis is a geometry change on that
    ///      axis, and each of those two edges is granted a budget of exactly
    ///      its own measured travel (`stepOwed`).
    ///   4. The budget is spent at `pinGrowCells` per update — the same rate
    ///      growth uses — and the episode is then OVER.
    ///
    /// Both edges of the axis, together: a one-sided bite is the measured
    /// signature of the estimator losing an edge (tk2 §3, and i8e-drag1's left
    /// third), never of a page laying the media out differently.
    ///
    /// MEASURED LIVE, runs/ipad-S-zoom-trace1: episodes open with 113.0/115.7
    /// pt of travel on x and 65.4/66.7 pt on y, against a scene that demands
    /// 112 pt and 63 pt per side. The mechanism measures what the media did.
    ///
    /// THIS DIRECTION ONLY ADDS COVER, which is why it can ship on its own
    /// evidence: it is strictly more conservative than the growth path it
    /// backstops (2 s of settled evidence instead of two frames) and moves at
    /// the same capped rate.
    ///
    /// THE INWARD HALF IS BUILT, GATED, AND DELIBERATELY NOT HERE. Same
    /// machinery, same constants, one extra branch; it evades the tk3
    /// abandonment receipt above because a standing bias contributes zero to a
    /// delta (offline, streamS/pinsim_tk4.py over all twelve tk3P2/tk3P4 runs:
    /// 0.0 pt of inward travel on 12 of 12, against 67.6-192.0 pt for the
    /// variant that block retired). It is out because it costs exposure it
    /// cannot pay for yet: runs/ipad-S-zoom-fix5 followed the 0.8x shrink to
    /// 1.371x with zero exposure and then, when the media grew back, sat 64 px
    /// inside the player for 72 of 72 frames — while the control on the same
    /// scene (runs/ipad-S-zoom-ctl1, no inward path) had zero exposed frames
    /// in the entire run. Until the pin can follow a GROW reliably, an inward
    /// path trades a harmless 1.75x over-cover for real exposure. The tree,
    /// its gate receipt and the re-run instructions are in
    /// scratchpad/streamS/tree_candidate/; the blocker is D4.
    private static let stepSettleSecs: CFAbsoluteTime = 2.0

    /// How much a candidate edge may wander over `stepSettleSecs` and still
    /// count as SETTLED, in grid cells of the owner window.
    ///
    /// 2 cells = one update's worth of movement at `pinGrowCells`: an edge
    /// that moves less than the pin itself could follow is not moving. Sized
    /// against the thing it has to reject as well as the thing it has to
    /// accept: in the tk2 §3 quiet tail the region's right edge wanders
    /// 0.686-0.896 of the window (measured, runs/ipad-tk3P2-flick1, t=24-36 s)
    /// — 34 cells, seventeen times this band — so a starved tail cannot look
    /// settled however long it is watched.
    private static let stepBandCells: CGFloat = 2

    /// The smallest step worth adopting, in grid cells, per edge.
    ///
    /// Sized between the two measured populations. BELOW it: the legitimate
    /// re-pin corrections iteration 9 measured, 0.0134-0.0138 of the window
    /// (~2.2 cells) — left to the ordinary growth path, which handles them.
    /// ABOVE it: D5's own case, a 0.8x page zoom on this scene's 1120 px
    /// media, which demands 112 px per side edge = 14.3 cells, six times this
    /// floor (scenes/zoom.html). 4 cells is also 2x `stepBandCells`, so a step
    /// cannot be manufactured by an edge drifting within the band.
    private static let stepMinCells: CGFloat = 4

    /// Fewest samples that may be called a settled window, however long the
    /// span. `stepSettleSecs` at the 30 Hz capture rate is 60 registered
    /// updates; measured under Sidecar the pipeline delivers ~19 Hz, so 30
    /// accepts the rate this lab actually runs at (~38 samples per window) and
    /// still refuses to call four samples spread over two seconds "settled".
    private static let stepSettleMinUpdates = 30

    private struct Held {
        var wid: CGWindowID
        /// The cover as fractions of the owner window's frame (top-left origin).
        var pin: CGRect
        /// Last walk's verdict: something else is in front of this cover.
        /// Sticky between walks — the cheap re-validation cannot see z-order,
        /// and un-freezing on the two frames out of three that skip the walk
        /// would make the freeze useless.
        var occluded = false
        /// When this cover last stopped being occluded. Together with the
        /// window's own stillness it is how long the pixels have been
        /// trustworthy.
        var unoccludedSince: CFAbsoluteTime
        var disagreeSince: CFAbsoluteTime?
        /// When the pin was last written. The shrink limit is a RATE, so it
        /// needs the interval, not the frame count — the pipeline drops ~6% of
        /// frames and a per-frame budget would silently speed up under load.
        var pinnedAt: CFAbsoluteTime
        /// REGISTRATION DEBT, per axis, in screen points: how much of the owner
        /// window's movement the pixel cover still has not followed.
        ///
        /// This is the T7 mechanism, and the reason the old `stillSeconds`
        /// gate could not see it. Measured, runs/ipad-v3-flick1: the tracked
        /// region's SCREEN rect is frozen at (-1215.7, 181.6, 1058.7, 703.8)
        /// from t=19.57 to t=22.5 while the window moves 112 pt left (and has
        /// already moved 66 pt down at t=18.6-19.1). `fractions(of:in:)` then
        /// reads that stale rect against the NEW frame, so the candidate is the
        /// player displaced by everything the cover did not follow —
        /// and `pin.union(candidate)` turns a displacement into growth. It
        /// fires 0.28-0.34 s after every motion leg ends (= `stillSecs`), in
        /// 6/6 runs, and the direction always opposes the window's move: after
        /// a 66 pt move DOWN the pin grows 56 pt UP (t=20.6, area 1.196 ->
        /// 1.292); after a move up+right it grows down (t=23.8); after a move
        /// right it grows left (t=5.5).
        ///
        /// Stillness says the WINDOW stopped. Registration says the COVER
        /// caught up. The debt measures the second: every point the frame moves
        /// is a point the cover owes, every point the cover's CENTRE moves in
        /// that direction pays it back, and the balance is settled the moment
        /// it is inside one grid cell. Centre, not origin: an edge growing
        /// outward is a size change, not a failure to follow, and charging it
        /// as debt froze the pin through the whole cold-start grow of
        /// runs/ipad-v3-flick4 in replay (pin stuck at 0.168x, 809 pt of
        /// under-cover). Cumulative, not a trailing-window velocity test: a
        /// velocity test reads "registered" the instant the window stops, which
        /// is exactly the frame the defect fires on.
        var registrationDebt = CGVector.zero
        var lastCoverCentre: CGPoint?
        /// The frame the last update was measured against. Also what a STALE
        /// poll ring rides (see `ride`).
        var lastFrame = CGRect.null
        /// Per edge (minX, minY, maxX, maxY): consecutive REGISTERED updates
        /// this edge has asked to move outward without getting it. Reset by any
        /// unregistered frame, so a smear peak seen across a motion boundary
        /// cannot accumulate credit. See `pinGrowPersist`.
        var growAsked = [0, 0, 0, 0]
        /// The last `stepSettleSecs` of REGISTERED candidate edge positions,
        /// oldest first. Cleared by any unregistered update, for the same
        /// reason `growAsked` is: evidence from across a motion boundary is
        /// evidence about a different geometry.
        var settleWindow: [(at: CFAbsoluteTime, edges: [CGFloat])] = []
        /// The last level the candidate SETTLED at, per edge. This is the only
        /// state a shrink is ever measured against — never the live candidate.
        /// Survives an unregistered stretch (a window that merely MOVED has
        /// the same window-relative geometry it had before), and is destroyed
        /// by a window resize, which is the one event that invalidates it.
        var settledRef: [CGFloat]?
        /// Travel this edge has been granted by a settled geometry step and
        /// not yet spent, in fractions of the owner window. POSITIVE is
        /// inward, negative is outward. Set only by a qualifying step; spent
        /// at `pinGrowCells` per update; never topped up by anything else.
        var stepOwed: [CGFloat] = [0, 0, 0, 0]
        /// Registered updates still allowed to RE-MEASURE the pin outright
        /// (both directions, unclamped outward). Set at acquisition and by a
        /// window RESIZE, counted down per registered update, and it is the
        /// only thing that ever lets the pin move inward — receipt in the block
        /// above `pinShrinkPerSecond`.
        ///
        /// A COUNT, not "until the pin reaches the candidate". Convergence was
        /// the first cut and it never happens while the candidate is still
        /// moving: on runs/ipad-tk3P3-flick1 the pixel path's cold start grows
        /// the region 0.41 -> 1.08 area over 3.6 s, the candidate moved every
        /// frame, the window stayed open for all of it, and the pin took a
        /// single +0.074 area step at t=-0.3 s — above the +0.05 bar, in the
        /// one place the bound was switched off.
        var remeasureUpdates = 0
    }

    /// Two window-relative rects that are the same rect for pinning purposes.
    /// One grid cell is 1/160 of the frame width and the smoother moves an edge
    /// at most one cell per frame, so half a cell is under the smallest step a
    /// converging edge can take — a settle can never hide inside this band.
    private static let pinEpsilon: CGFloat = 0.5 / 160

    private var held: [Int: Held] = [:]
    /// Pins whose region stopped being media-held, kept for `pinLapseSecs` so a
    /// momentary latch loss is not a cold restart. Keyed by WINDOW id, not
    /// region id: the region id churns across a latch loss (a new latch is a new
    /// region), the window does not.
    private var lapsed: [CGWindowID: (pin: CGRect, at: CFAbsoluteTime)] = [:]
    /// Loud channel for a dropped ownership. Never silent: a cover that stops
    /// riding its window is a visible behavior change and has to be explainable
    /// from the run's own output.
    var onDrop: ((String) -> Void)?
    /// Loud channel for a LIMIT that actually clipped an update. Separate from
    /// `onDrop` because it is not a behavior change, it is a budget report:
    /// project rule, a limit a developer can hit must name itself, its value,
    /// what was observed and where to change it. Rate-limited to once per
    /// episode by the caller-side state in `noteLimit`.
    var onLimit: ((String) -> Void)?
    private var limitNoted: [String: CFAbsoluteTime] = [:]

    private func noteLimit(_ key: String, _ now: CFAbsoluteTime, _ message: @autoclosure () -> String) {
        // One report per limit per second: the cap fires on consecutive frames
        // while a real recovery walks out, and 30 identical lines a second is
        // not a report, it is noise.
        if let last = limitNoted[key], now - last < 1.0 { return }
        limitNoted[key] = now
        onLimit?(message())
    }

    /// PANIC/PAUSE ONLY: forget everything, including the lapse memory, so a
    /// resumed run cannot ride a pin measured before the pause. "No media-held
    /// regions this frame" is NOT this — see `lapse(at:)`.
    func reset() {
        held.removeAll()
        lapsed.removeAll()
        limitNoted.removeAll()
    }

    /// No media-held regions this frame. The pins stop being maintained, but
    /// they are REMEMBERED for `pinLapseSecs` (receipt there): a media latch
    /// that blinks — a demote under a translating occluder, a detector dropout,
    /// a 238 ms window-poll stall — used to destroy the pin and force the next
    /// acquisition to believe whatever collapsed rect the pixel path was
    /// holding at that instant.
    func lapse(at now: CFAbsoluteTime) {
        for h in held.values { lapsed[h.wid] = (h.pin, now) }
        held.removeAll()
        lapsed = lapsed.filter { now - $0.value.at <= Self.pinLapseSecs }
    }

    /// One capture frame. `covers` are the PIXEL-DERIVED painted rects, in
    /// CGWindowList space (screen points, top-left origin), parallel to
    /// `regionIDs`. `walk` asks for a full z-order snapshot; on the other frames
    /// the incumbent is re-validated from the poll ring for free.
    /// `floors` are this frame's BLOCKED DETECTION rects in the same space and
    /// order, or `.null` where a region has no live detection. They are a
    /// safety floor on the answer, never on the stored pin — see `ride`.
    func resolve(
        regionIDs: [Int], covers: [CGRect], floors: [CGRect], walk: Bool,
        tracker: WindowTracker, at now: CFAbsoluteTime
    ) -> [Verdict] {
        // A region that went away lapses like a whole-frame latch loss does:
        // same failure (the next acquisition has no prior), same cure.
        for (id, h) in held where !regionIDs.contains(id) { lapsed[h.wid] = (h.pin, now) }
        held = held.filter { regionIDs.contains($0.key) }
        lapsed = lapsed.filter { now - $0.value.at <= Self.pinLapseSecs }
        // The rect each region is CURRENTLY painting: the pin on the owner's
        // freshest polled frame while it rides, else the pipeline's own cover.
        // Occlusion and incumbent-still-holds are questions about this rect.
        var authority: [CGRect] = []
        for (i, id) in regionIDs.enumerated() {
            var rect = covers[i]
            if let h = held[id], let frame = tracker.latestFrame(of: h.wid) {
                rect = place(h.pin, on: frame)
            }
            authority.append(rect)
        }

        var resolutions: [WindowTracker.Resolution?] =
            Array(repeating: nil, count: regionIDs.count)
        if walk {
            let queries = regionIDs.enumerated().map { i, id in
                WindowTracker.Query(
                    authority: authority[i], gate: covers[i], incumbent: held[id]?.wid)
            }
            for (i, r) in tracker.resolveOwners(queries).enumerated() { resolutions[i] = r }
        }

        var out: [Verdict] = []
        for (i, id) in regionIDs.enumerated() {
            out.append(
                step(
                    id: id, cover: covers[i], floor: floors[i], authority: authority[i],
                    resolution: resolutions[i], tracker: tracker, at: now))
        }
        return out
    }

    // MARK: - one region

    private func step(
        id: Int, cover: CGRect, floor: CGRect, authority: CGRect,
        resolution: WindowTracker.Resolution?, tracker: WindowTracker,
        at now: CFAbsoluteTime
    ) -> Verdict {
        // --- 1. does the incumbent survive this frame? ---
        if var h = held[id] {
            var keep = true
            var why = ""
            if tracker.isDead(h.wid) {
                keep = false
                why = "owner window \(h.wid) is gone"
            } else if let r = resolution {
                // Walk frame: the snapshot is the authority on existence and
                // z-order both.
                if r.incumbentFrame == nil {
                    keep = false
                    why = "owner window \(h.wid) left the on-screen window list"
                } else if !r.incumbentHoldsAuthority {
                    keep = false
                    why = "owner window \(h.wid) no longer holds the cover"
                } else {
                    // DEFECT 1b/1c: the incumbent exists and still holds the
                    // cover, so nothing takes it away — not even the window
                    // that is now in front. A different front window means an
                    // occlusion is in progress, and the answer to that is to
                    // stop moving, not to change owner.
                    h.occluded = r.frontID != nil && r.frontID != h.wid
                    if h.occluded { h.unoccludedSince = now }
                }
            } else {
                // Cheap frame: no syscall, no z-order. Existence + hold only,
                // from the poll ring. The occlusion latch keeps the last walk's
                // verdict (receipt at `Held.occluded`).
                //
                // POLL FAILED vs WINDOW GONE (tk3, stream W interface, consumed
                // defensively here). `latestFrame == nil` conflates "the ring
                // has nothing for this window right now" with "the window is
                // gone", and only `isDead` is evidence of the second. A stale
                // ring is a reason to FREEZE on the last known frame, never to
                // drop: dropping is what turned a 238 ms poll stall into a
                // cold re-acquisition onto a collapsed rect and 2904 ms of
                // exposure (streamA-vfy, ipad-vfyA2-flick1).
                guard let live = tracker.latestFrame(of: h.wid) else {
                    held[id] = h
                    return frozenVerdict(h, floor: floor, at: now)
                }
                guard WindowTracker.heldFraction(authority, in: live)
                    >= WindowTracker.minContainedFraction
                else {
                    held[id] = nil
                    lapsed[h.wid] = (h.pin, now)
                    onDrop?("cover \(id): dropped window \(h.wid) — cover moved out of it")
                    return Verdict()
                }
                held[id] = h
                return ride(
                    id: id, cover: cover, floor: floor, hint: live, tracker: tracker, at: now)
            }
            if !keep {
                held[id] = nil
                lapsed[h.wid] = (h.pin, now)
                onDrop?("cover \(id): dropped window \(h.wid) — \(why)")
            } else {
                held[id] = h
                return ride(
                    id: id, cover: cover, floor: floor, hint: resolution?.incumbentFrame,
                    tracker: tracker, at: now)
            }
        }

        // --- 2. no incumbent: may we acquire one? ---
        // Only on a walk, and only when the frontmost layer-0 window holds the
        // PIXEL-DERIVED cover. That is the "pixel path re-anchors" half of
        // defect 1b's transfer rule: a window inherits a cover by holding the
        // evidence, never by being in front of it.
        guard let r = resolution, let front = r.frontID, let frame = r.frontFrame,
            r.frontHoldsGate
        else { return Verdict() }
        // ACQUISITION OBEYS THE SAME CLIP RULE AS RE-PINNING (iteration 9,
        // miss A). `ride` already refuses to RE-measure a pin from a cover that
        // touches the screen edge, because the capture holds only the on-screen
        // part of the player and pinning that writes the CLIP into the
        // window-relative rect. A fresh acquisition was measuring exactly the
        // same lie and nothing stopped it: on all three cycle-i8e drag runs the
        // watchdog dropped ownership during the offscreen leg and the very next
        // walk re-acquired with pin=[0.0000, 0.4333] — 520 pt of a 1200 pt
        // window, precisely the width still on screen with the window at
        // x=1400 — and the cover rode that half-width rect all the way home
        // (runs/i9c-probe1 t=36.81-42.0; 59 exposed frames / 1967 ms of S5 in
        // 3 of 3 i8e runs). Refusing leaves the pixel path in charge, which is
        // the pre-ownership behavior and cannot be worse than pinning a clip.
        guard onScreen(cover, tracker) else { return Verdict() }
        // LAPSE MEMORY (receipt at `pinLapseSecs`). A fresh acquisition has no
        // prior and must believe the pixels — unless this very window had a pin
        // moments ago, in which case the pixels are the thing that just
        // blinked and the remembered pin is the better evidence. Only for the
        // SAME window id, and only inside the lapse window; anything else is a
        // genuinely new cover and measures fresh.
        var pin = fractions(of: cover, in: frame)
        // A freshly measured acquisition is PROVISIONAL: it was measured from
        // whatever the pixel path happened to be holding, with no registration
        // history behind it, so the first registered update is allowed to
        // re-measure it outright. A restored one is not — see below.
        var remeasure = pinRemeasureUpdates
        if let remembered = lapsed[front], now - remembered.at <= Self.pinLapseSecs {
            // REPLACE, not union. Union was the first cut and it reintroduced
            // the whole T7 defect through the one unbounded path left in the
            // class: measured on runs/ipad-tk3P-flick1, a latch demote at
            // t=19.2 (three frames with no window record) was followed by a
            // re-acquisition whose FRESH candidate was the mid-blink,
            // unregistered cover — pin top 0.1022 -> 0.0360, a +0.089 area step
            // in one update, and the run's p95 went 1.16 -> 1.218.
            //
            // The remembered pin is better evidence than the fresh candidate by
            // construction: it was measured under the registration gate, and
            // the candidate is being measured at the exact instant the pixel
            // path blinked. If the player really did change while the latch was
            // down, the normal registered-growth path walks the pin back out at
            // `pinGrowCells`, and the detection floor covers the interim.
            pin = remembered.pin
            lapsed[front] = nil
            // NOT provisional: a restored pin was measured under the
            // registration gate and is better evidence than anything measured
            // during the blink that lost it. Letting the re-measure path touch
            // it would throw it away on the very next frame and put the
            // collapsed-rect acquisition back.
            remeasure = 0
        }
        held[id] = Held(
            wid: front, pin: pin, unoccludedSince: now, pinnedAt: now,
            lastFrame: frame, remeasureUpdates: remeasure)
        return ride(id: id, cover: cover, floor: floor, hint: frame, tracker: tracker, at: now)
    }

    /// The answer for a frame on which nothing may be learned: keep riding the
    /// last frame this cover was measured against, do not touch the pin, do not
    /// touch the debt, and report the region as frozen so the tracker does not
    /// age it out underneath us (`Tracker.update(frozen:)`).
    private func frozenVerdict(_ h: Held, floor: CGRect, at now: CFAbsoluteTime) -> Verdict {
        guard !h.lastFrame.isNull else { return Verdict() }
        return Verdict(
            windowID: h.wid, ownerFrame: h.lastFrame,
            pin: floored(h.pin, floor: floor, frame: h.lastFrame), frozen: true)
    }

    /// Maintain the pin and answer for an owned region.
    ///
    /// `hint` is the owner's frame from THIS frame's z-order snapshot, used
    /// when the poll ring has nothing yet. Without it the first frame of a new
    /// ownership deadlocks: the poll thread is only told to track a window once
    /// a verdict names it, and a verdict cannot name a window whose frame is
    /// unknown, so the ring stays empty forever and the feature never starts.
    private func ride(
        id: Int, cover: CGRect, floor: CGRect, hint: CGRect?, tracker: WindowTracker,
        at now: CFAbsoluteTime
    ) -> Verdict {
        guard var h = held[id] else { return Verdict() }
        guard let frame = tracker.latestFrame(of: h.wid) ?? hint else {
            // Stale poll ring, not a dead window (see the cheap-frame path).
            return frozenVerdict(h, floor: floor, at: now)
        }
        // DEFECT 3: while the window MOVES the pin is held in window-relative
        // coordinates and the detector's geometry churn is ignored; once the
        // window has been still for `stillSecs` the pixel path is authority
        // again and the pin is re-measured every frame, so it re-snaps exactly.
        //
        // An OCCLUDED cover never re-pins, however still its window is: the
        // pixels under an occluder are the occluder's, so re-measuring from
        // them would write the thing in front of the player into the pin. That
        // is defect 1c's freeze — the cover still rides its own window, it just
        // stops learning from pixels it cannot trust.
        //
        // How long the pixels have been trustworthy is the SMALLER of "the
        // window has not moved" and "nothing has been in front of the cover":
        // both a drag and an occluder make the published cover an unreliable
        // measurement of the player, in the same direction.
        let trusted = min(
            tracker.stillSeconds(of: h.wid, at: now) ?? 0, now - h.unoccludedSince)
        // The pin is only ever measured from a cover this window actually
        // HOLDS — the same gate acquisition uses. Without it a smeared cover
        // that swallows the whole window re-pins as [0,0,1,1] and the overlay
        // blacks out the entire browser window until the pixel path converges
        // back: measured on runs/i8-p1, rows 1250-1363 of the offscreen leg.
        // Refusing to re-pin keeps the last rect the window did hold, which is
        // the whole point of having a pin.
        let holdsCover =
            WindowTracker.heldFraction(cover, in: frame) >= WindowTracker.minContainedFraction
        // Clipping by the SCREEN is the third way the pixel evidence lies,
        // alongside motion and occlusion — and the one that bites hardest,
        // because it is silent. The capture contains only the on-screen part of
        // the player, so a clipped cover is the player CUT DOWN TO THE SCREEN,
        // and pinning that writes the cut into the window-relative rect.
        // Measured on runs/i8b-drag1: during the offscreen leg the pin became
        // [0, 0.008, 0.449, 0.871] — the left 539 pt of a 1200 pt window, i.e.
        // exactly the sliver still on screen — and the cover rode that
        // half-width rect all the way home: a 56-frame / 1133 ms S5 exposure
        // with 383 px of under-cover, plus six loud ownership drops when the
        // watchdog noticed. Holding the pin instead costs nothing, because the
        // player does not move inside its window while the window is off the
        // edge.
        //
        // The test is on the COVER, not on the window frame. Testing the frame
        // was the first cut and it was wrong in a way that cost a whole live
        // cycle: this scene's window is 975 pt tall at y=120, so its bottom
        // sits 15 pt under a 1080 pt screen for the entire post-drag half of
        // the schedule, `onScreen` read false for 2000 consecutive frames, the
        // pin never re-measured, and whatever it happened to hold at the end of
        // the last drag became permanent — 120 px of under-cover for 60 s on
        // runs/i8c-drag2 and drag3, and pure luck that runs/i8c-drag1 froze on
        // a good value. What matters is not whether the window is fully
        // visible; it is whether the EVIDENCE is complete, and evidence that
        // does not touch the screen edge is complete.
        //
        // The margin is one grid cell, not one point. A point was the second
        // wrong cut: a cover clipped flush to a 1920 pt screen is published at
        // maxX 1919.x — the media pad, the smoother's 1e-4 lattice and the
        // published rect's own rounding all pull it a fraction inside — so a
        // 1 pt inset still called it "on screen" and pinned it. Measured on
        // runs/i8d-drag1: the pin became [0, 0.4325], a 519 pt remnant of a
        // 1200 pt window, exactly the width left on screen, and S5 scored 58 of
        // 58 frames exposed with 455 px of under-cover. One cell is the
        // resolution the box estimator itself works at (MotionBoxes.gridWidth
        // 160 over 1280 px = 8 px = 12 screen pt here, the same figure
        // `containTolerance` carries), so an edge nearer than that to the
        // boundary cannot be told apart from an edge made BY the boundary.
        let coverOnScreen = onScreen(cover, tracker)
        // A window RESIZE is the one event that is positive evidence the
        // player's window-relative geometry really changed, so it clears both
        // the registration debt (which is denominated against the old frame)
        // and every step clock (which was counting evidence about the old
        // geometry). Checked before `lastFrame` is overwritten below.
        if !h.lastFrame.isNull && h.lastFrame.size != frame.size {
            h.registrationDebt = .zero
            h.growAsked = [0, 0, 0, 0]
            h.remeasureUpdates = pinRemeasureUpdates
            // The settled reference is a window-RELATIVE level, so a resize is
            // the one event that makes it describe geometry that no longer
            // exists. Everything about the step episode goes with it.
            h.settleWindow.removeAll()
            h.settledRef = nil
            h.stepOwed = [0, 0, 0, 0]
        }
        updateRegistrationDebt(&h, cover: cover, frame: frame)
        // REGISTERED, not merely still. `trusted >= stillSecs` says the window
        // stopped moving 0.3 s ago; it says nothing about whether the pixel
        // cover has caught up, and the whole T7 ratchet lives in that gap
        // (receipt at `Held.registrationDebt`). The debt closes it: while the
        // cover still owes the window a displacement, nothing is learned.
        let registered = !h.occluded && holdsCover && coverOnScreen
            && trusted >= WindowTracker.stillSecs
            && h.registrationDebt.dx == 0 && h.registrationDebt.dy == 0
        let candidate = fractions(of: cover, in: frame)
        if WindowTracker.debug {
            print(String(
                format: "pin r%d wid=%u trusted=%.2f reg=%d holds=%d onscreen=%d "
                + "debt=(%.1f,%.1f) occl=%d pin=[%.4f %.4f %.4f %.4f] "
                + "cand=[%.4f %.4f %.4f %.4f]",
                id, h.wid, trusted, registered ? 1 : 0, holdsCover ? 1 : 0,
                coverOnScreen ? 1 : 0, h.registrationDebt.dx, h.registrationDebt.dy,
                h.occluded ? 1 : 0,
                h.pin.minX, h.pin.minY, h.pin.width, h.pin.height,
                candidate.minX, candidate.minY, candidate.width, candidate.height))
        }
        if registered {
            h.pin = updatedPin(&h, toward: candidate, frame: frame, id: id, at: now)
            h.pinnedAt = now
        } else {
            // Unregistered evidence is not weak evidence, it is evidence about
            // a different geometry: an outward ask part-way to its persist
            // count does not carry across the boundary.
            h.growAsked = [0, 0, 0, 0]
            // Same rule for the settle window. A part-spent step budget is
            // abandoned rather than carried: it was measured against evidence
            // that has just stopped being trustworthy. Abandoning it leaves
            // the pin SMALLER than the episode intended, so the ordinary
            // growth path — which is still running — has to finish the job,
            // exactly as it did before this mechanism existed.
            h.settleWindow.removeAll()
            h.stepOwed = [0, 0, 0, 0]
        }
        // DEFECT 1d: riding is only legitimate while the window frame and the
        // pixels still describe the same rectangle. They are allowed to
        // disagree by the pipeline's lag; they are not allowed to disagree for
        // a second. Evaluated on every unoccluded frame, including the ones
        // where the pin is deliberately holding — "the pin is stale" is exactly
        // the condition a hold can create, so exempting held frames would
        // switch the backstop off precisely where it is needed. (Not evaluated
        // while occluded: an occluder makes the pixel evidence wrong on
        // purpose.)
        // Not evaluated when the evidence is screen-clipped, for the same
        // reason the pin is not re-measured there: the cover the pipeline
        // publishes is the screen-clipped player, so its centre is displaced by
        // the clip and the watchdog would fire on the clip rather than on a
        // fault. (It did: six drops in runs/i8b-drag1, all inside the offscreen
        // legs.)
        //
        // TWO rects have to be unclipped for the comparison to be fair, not one
        // (iteration 9, miss A). Testing only the COVER switched the exemption
        // off exactly where it was needed: once the player is mostly past the
        // screen edge the pixel path stops describing it at all and latches some
        // small on-screen remnant, and that remnant is comfortably inside the
        // screen — so `coverOnScreen` read TRUE, the watchdog fired on a pin
        // that was RIGHT, and ownership was dropped. Measured, same message and
        // same shape on i8e-drag1/2/3 and i8e-torture1: pinned rect
        // (1416,370,1168,655) against pixel cover (815,170,389,373), dropped
        // after 1.02 s. The pin extends to x=2584 on a 1920 pt screen; the
        // capture cannot contain the player it describes, so there is nothing to
        // compare against and the honest answer is to keep riding.
        let expectedRect = place(h.pin, on: frame)
        if !h.occluded && coverOnScreen && onScreen(expectedRect, tracker) {
            // The test is on POSITION, not on shape: the pixel cover's centre
            // must still fall inside what we are painting.
            //
            // Receipt for choosing it over an area/IoU test. Two things make
            // the pin and the published cover differ, and only one of them is a
            // fault. (a) The pixel path lags 95.7 ms p50 (track-d), which at the
            // 1500 pt/s torture burst is ~143 pt of position error against a
            // ~1130 pt wide pin — comfortably inside. (b) The box COLLAPSES: on
            // an erratic walk MotionBoxes publishes nothing on ~82% of frames
            // and the cover falls back to the face box, ~370x654 inside a
            // 1130x670 pin. That is IoU 0.32 — an area test set anywhere useful
            // fires on it and drops ownership, which is the exact opposite of
            // the right response, because the collapse is what the pin is FOR.
            // A concentric collapse does not move the centre at all. Riding the
            // wrong window does: the occluder retreat that started all of this
            // put the two hundreds of points apart within a few frames.
            let expected = expectedRect
            if expected.contains(CGPoint(x: cover.midX, y: cover.midY)) {
                h.disagreeSince = nil
            } else {
                let since = h.disagreeSince ?? now
                h.disagreeSince = since
                if now - since > Self.disagreeSecs {
                    held[id] = nil
                    lapsed[h.wid] = (h.pin, now)
                    onDrop?(
                        "cover \(id): dropped window \(h.wid) — pinned rect "
                        + "\(rounded(expected)) and pixel cover \(rounded(cover)) have "
                        + "disagreed for \(String(format: "%.2f", now - since)) s "
                        + "(limit \(Self.disagreeSecs) s, fix: CoverOwnership.disagreeSecs)")
                    return Verdict()
                }
            }
        }
        held[id] = h
        return Verdict(
            windowID: h.wid, ownerFrame: frame,
            pin: floored(h.pin, floor: floor, frame: frame), frozen: h.occluded)
    }

    // MARK: - the pin update

    /// See `Held.registrationDebt`. Charges the frame's movement, credits the
    /// cover CENTRE's movement in the same direction, and settles the balance
    /// once it is inside one grid cell of the owner window.
    private func updateRegistrationDebt(_ h: inout Held, cover: CGRect, frame: CGRect) {
        defer {
            h.lastCoverCentre = CGPoint(x: cover.midX, y: cover.midY)
            h.lastFrame = frame
        }
        guard let previous = h.lastCoverCentre, !h.lastFrame.isNull else { return }
        let owed = CGVector(
            dx: frame.minX - h.lastFrame.minX, dy: frame.minY - h.lastFrame.minY)
        let paid = CGVector(dx: cover.midX - previous.x, dy: cover.midY - previous.y)
        func settle(_ debt: CGFloat, _ owed: CGFloat, _ paid: CGFloat) -> CGFloat {
            let total = debt + owed
            // Only motion in the direction of the debt counts as payment; a
            // cover drifting the other way is not "more unregistered" in any
            // way this class can act on, and charging it would make the debt
            // unpayable on a noisy tail.
            if total > 0 { return max(0, total - max(paid, 0)) }
            if total < 0 { return min(0, total - min(paid, 0)) }
            return 0
        }
        var debt = CGVector(
            dx: settle(h.registrationDebt.dx, owed.dx, paid.dx),
            dy: settle(h.registrationDebt.dy, owed.dy, paid.dy))
        // One grid cell of the owner window — the same quantum the pin's rate
        // limits are written in, and below the resolution of the thing being
        // measured, so a settled balance cannot hide a real displacement.
        let tolerance = frame.width / CGFloat(MotionBoxes.gridWidth)
        if abs(debt.dx) <= tolerance { debt.dx = 0 }
        if abs(debt.dy) <= tolerance { debt.dy = 0 }
        h.registrationDebt = debt
    }

    /// The pin, moved toward a REGISTERED candidate, per edge:
    ///   OUTWARD — after `pinGrowPersist` consecutive asks, capped at
    ///             `pinGrowCells` for this one update.
    ///   INWARD  — only inside the `remeasureUpdates` window opened by an
    ///             acquisition or a window resize,
    ///             and then straight to the candidate, rate-limited against a
    ///             collapsed one by `pinShrinkPerSecond`.
    ///
    /// Per edge, not per side-pair: a collapse eats one edge at a time (the
    /// left third on i8e-drag1, the right sixth on i8e-multi1) and a rule
    /// written on width would let an edge run while the opposite one
    /// compensated.
    private func updatedPin(
        _ h: inout Held, toward candidate: CGRect, frame: CGRect, id: Int,
        at now: CFAbsoluteTime
    ) -> CGRect {
        let cell = 1 / CGFloat(MotionBoxes.gridWidth)
        // A grid cell is square in pixels, so it is 1/160 of the frame WIDTH in
        // x and aspect times that in y (same derivation as
        // PaintSmoother.setFrameSize).
        let grow = (
            x: pinGrowCells * cell,
            y: pinGrowCells * cell * frame.width / max(frame.height, 1))
        // Edge order: minX, minY, maxX, maxY. `outward` is the sign that grows
        // the pin on that edge.
        let pinEdges = [h.pin.minX, h.pin.minY, h.pin.maxX, h.pin.maxY]
        let candEdges = [candidate.minX, candidate.minY, candidate.maxX, candidate.maxY]
        let growBy = [grow.x, grow.y, grow.x, grow.y]
        let outward: [CGFloat] = [-1, -1, 1, 1]
        let cellPerEdge = [grow.x, grow.y, grow.x, grow.y].map { $0 / pinGrowCells }
        var next = pinEdges
        var clipped: (edge: Int, wanted: CGFloat, allowed: CGFloat)?
        if h.remeasureUpdates > 0 {
            h.remeasureUpdates -= 1
            // A re-measure is already adopting the candidate outright; a
            // reference learned before or during that is about geometry the
            // re-measure is in the middle of replacing.
            h.settleWindow.removeAll()
            h.settledRef = nil
            h.stepOwed = [0, 0, 0, 0]
            // Post-resize (or post-acquisition) RE-MEASURE: the window-relative
            // geometry really did change, this is the first registered look at
            // the new one, and creeping toward it would be worse than adopting
            // it — the creep is what walks off the player's edge. Rate-limited
            // only against the pathological case of a candidate that is itself
            // a collapse, by the same `pinShrinkPerSecond` tripwire, over one
            // update's worth of budget.
            let step = Self.pinShrinkPerSecond * CGFloat(min(max(now - h.pinnedAt, 0), 0.2))
            for i in 0..<4 {
                let delta = (candEdges[i] - pinEdges[i]) * outward[i]
                next[i] = delta >= 0
                    ? candEdges[i] : pinEdges[i] - min(-delta, step) * outward[i]
            }
        } else {
            for i in 0..<4 {
                let delta = (candEdges[i] - pinEdges[i]) * outward[i]
                guard delta > Self.pinEpsilon else {
                    h.growAsked[i] = 0
                    continue
                }
                h.growAsked[i] += 1
                guard h.growAsked[i] >= Self.pinGrowPersist else { continue }
                let allowed = min(delta, growBy[i])
                if allowed < delta - Self.pinEpsilon { clipped = (i, delta, allowed) }
                next[i] = pinEdges[i] + allowed * outward[i]
            }
            // SETTLED GEOMETRY STEP, both directions (receipt at
            // `stepSettleSecs`). Grant first, then spend: an episode opened
            // by this update starts paying on it.
            openGeometryEpisode(&h, candidate: candEdges, cell: cellPerEdge, id: id, frame: frame, at: now)
            // `stepOwed` is signed the same way `moved` is (+ inward), and
            // only outward grants are made, so every live budget is negative.
            // Spend is CLAMPED to this update's candidate edge: the budget
            // exists to carry the pin through INTERMITTENT evidence of a real
            // grow (`pinGrowPersist` cannot count consecutive asks through a
            // D4-flickering edge), never past the evidence itself. Unclamped,
            // the ordinary grow loop above reaches the candidate first and the
            // whole budget is then spent beyond it — a double-count measured
            // at 1.74-2.40x of the player and 91% of the display on
            // scenes/zoom.html (vfyS VERDICT, tk4). Budget not backed by this
            // update's candidate stays owed, for an update on which the
            // flickering edge actually shows.
            for i in 0..<4 where h.stepOwed[i] < 0 {
                let room = max((candEdges[i] - next[i]) * outward[i], 0)
                let spend = min(-h.stepOwed[i], growBy[i], room)
                guard spend > Self.pinEpsilon else { continue }
                next[i] += spend * outward[i]
                h.stepOwed[i] += spend
            }
        }
        if let clipped {
            let names = ["left", "top", "right", "bottom"]
            noteLimit(
                "grow", now,
                "cover \(id): pin \(names[clipped.edge]) edge growth clipped by "
                + "CoverOwnership.pinGrowCells (limit \(pinGrowCells) cells = "
                + String(format: "%.1f", pinGrowCells * cell * frame.width)
                + " pt/update; wanted "
                + String(format: "%.1f", clipped.wanted * frame.width) + " pt, applied "
                + String(format: "%.1f", clipped.allowed * frame.width)
                + " pt) — fix: CoverOwnership.pinGrowCells")
        }
        guard next[2] > next[0], next[3] > next[1] else { return h.pin }
        return CGRect(
            x: next[0], y: next[1], width: next[2] - next[0], height: next[3] - next[1])
    }

    /// Track how settled the candidate is and, when it settles at a new level
    /// that is displaced from the previous one on both edges of an axis, grant
    /// that axis a budget of exactly the measured travel.
    ///
    /// Everything about why this is shaped like this is at `stepSettleSecs`.
    /// Only called on REGISTERED updates, and only outside the re-measure
    /// window.
    ///
    /// BOTH DIRECTIONS, and the outward one is not symmetry for its own sake.
    /// MEASURED, runs/ipad-S-zoom-trace1 (the first live run in which the
    /// inward path worked): the pin followed the 0.8x shrink to 1.195x and
    /// 1.283x of the shrunken player with ZERO exposed frames in both 0.8x
    /// phases — and then the 1.25x GROW back left it 80 px inside the player's
    /// right edge for 374 consecutive frames, 14.8 s, peak 55 443 exposed px.
    /// The ordinary growth path could not close it: growth needs
    /// `pinGrowPersist` CONSECUTIVE registered asks, and on a quiet tail the
    /// region's right edge only reaches the player intermittently (tk2 §3, the
    /// same D4 collapse), so two in a row never happen. The same run's control
    /// (runs/ipad-S-zoom-ctl1, no inward path at all) had zero exposure only
    /// because its pin never became small enough to need growing.
    ///
    /// So an inward path without an outward one TRADES a harmless over-cover
    /// for real exposure, and must not ship that way. A settled outward step
    /// is bounded by the same measured travel, spent at the same rate, and
    /// moves the pin in the direction that can only ADD cover — strictly safer
    /// than the growth path it backstops, which is already allowed to walk to
    /// the candidate at this rate on two frames' evidence.
    private func openGeometryEpisode(
        _ h: inout Held, candidate: [CGFloat], cell: [CGFloat], id: Int,
        frame: CGRect, at now: CFAbsoluteTime
    ) {
        h.settleWindow.append((now, candidate))
        // Bounded by time, and by time alone: the buffer holds one entry per
        // registered update over a 2 s span, so ~60 entries at the capture
        // rate. There is no count cap because a cap would silently discard the
        // oldest evidence in exactly the case the window is meant to measure.
        //
        // Drop an entry only once the NEXT one is also old enough to be the
        // window's start. Pruning everything older than the span instead is an
        // off-by-one that switches the whole mechanism off: it leaves a buffer
        // that spans strictly LESS than `stepSettleSecs`, which the guard
        // below then requires to span AT LEAST that, so the two conditions can
        // only ever meet on an exact tie. Measured, before this line was
        // written this way: the offline model (which used a 5% tolerance)
        // reported two qualifying episodes on runs/ipad-S-zoom-fix1 and the
        // daemon on the same scene reported zero.
        while h.settleWindow.count >= 2,
            now - h.settleWindow[1].at >= Self.stepSettleSecs
        {
            h.settleWindow.removeFirst()
        }
        guard let first = h.settleWindow.first,
            now - first.at >= Self.stepSettleSecs,
            h.settleWindow.count >= Self.stepSettleMinUpdates
        else { return }
        var level = [CGFloat](repeating: 0, count: 4)
        for i in 0..<4 {
            var lo = CGFloat.greatestFiniteMagnitude
            var hi = -CGFloat.greatestFiniteMagnitude
            var sum: CGFloat = 0
            for s in h.settleWindow {
                lo = min(lo, s.edges[i])
                hi = max(hi, s.edges[i])
                sum += s.edges[i]
            }
            // One unsettled edge means the whole rect is unsettled. Per-axis
            // would be the tempting relaxation and it is wrong: the tk2 §3
            // collapse leaves three edges rock steady and eats the fourth, so
            // an axis-local test would call the steady axis settled and start
            // measuring steps against a rect that is coming apart.
            guard hi - lo <= Self.stepBandCells * cell[i] else { return }
            level[i] = sum / CGFloat(h.settleWindow.count)
        }
        guard let ref = h.settledRef else {
            h.settledRef = level
            return
        }
        // + = moved INWARD relative to the reference, - = outward.
        let outward: [CGFloat] = [-1, -1, 1, 1]
        let moved = (0..<4).map { (level[$0] - ref[$0]) * -outward[$0] }
        for axis in 0..<2 {
            let a = axis, b = axis + 2
            // OUTWARD ONLY, and both edges of the axis together. `moved` is
            // positive inward, so an outward step is negative on both. The
            // inward branch is the one held back — see the block at
            // `stepSettleSecs` and scratchpad/streamS/tree_candidate/.
            guard -moved[a] >= Self.stepMinCells * cell[a],
                -moved[b] >= Self.stepMinCells * cell[b]
            else { continue }
            h.stepOwed[a] = moved[a]
            h.stepOwed[b] = moved[b]
            // A budget report, not a fault: the pin is about to move on
            // evidence no other rule in this class acts on, so it names the
            // measured travel, the floor that let it through, and where to
            // change that floor.
            let span = axis == 0 ? frame.width : frame.height
            noteLimit(
                "step\(axis)", now,
                "cover \(id): adopting a settled in-window media grow on the "
                + (axis == 0 ? "x" : "y") + " axis — "
                + String(format: "%.1f", -moved[a] * span) + " pt / "
                + String(format: "%.1f", -moved[b] * span)
                + " pt of measured travel (floor "
                + String(format: "%.1f", Self.stepMinCells * cell[a] * span)
                + " pt over \(Self.stepSettleSecs) s of settled evidence) — "
                + "fix: CoverOwnership.stepMinCells")
        }
        h.settledRef = level
    }

    /// The FLOOR, applied to the ANSWER and never to the stored pin: a cover
    /// that owns a live blocked detection may not be published smaller than
    /// that detection plus one acquisition pad, whatever the pin says.
    ///
    /// Stored-pin vs answer matters. Unioning the floor INTO the pin would make
    /// every detection excursion permanent — the ratchet this iteration exists
    /// to remove, rebuilt out of detection boxes. Applied to the verdict it is
    /// a per-frame clamp that costs nothing once the pin is right and cannot
    /// accumulate.
    ///
    /// The pad is `EdgeSnap.acquirePadCells` cells, expressed in screen points
    /// as `WindowTracker.containTolerance` (which is documented as exactly one
    /// grid cell, ~12 pt at this display) — the same margin the acquisition
    /// snap gives a detection for the same reason: one cell is the resolution
    /// the box estimator works at, so an edge inside it is not resolvable.
    ///
    /// HONEST LIMIT (measured, tk3): this closes the streamA-vfy collapse class,
    /// where the pin fell to a fraction of the player around a live detection.
    /// It does NOT close the settled-tail region collapse of tk2 §3 — in those
    /// runs the detection is a face box on the LEFT of the player (right edge
    /// ~425 recording px) and the collapse is on the RIGHT (region right edge
    /// 830 vs player 1172), 400 px away. That is fixed in `Tracker`, not here.
    private func floored(_ pin: CGRect, floor: CGRect, frame: CGRect) -> CGRect {
        guard !floor.isNull, floor.width > 0, floor.height > 0 else { return pin }
        let pad = WindowTracker.containTolerance * CGFloat(EdgeSnap.acquirePadCells)
        let padded = floor.insetBy(dx: -pad, dy: -pad)
        return pin.union(fractions(of: padded, in: frame))
    }

    /// Is `rect` clear of the screen edge — i.e. is the capture's view of it
    /// COMPLETE? One grid cell of margin, not one point: a rect clipped flush to
    /// a 1920 pt screen is published at maxX 1919.x (the media pad, the
    /// smoother's 1e-4 lattice and the published rect's own rounding all pull it
    /// a fraction inside), and a 1 pt inset called that "on screen" and pinned
    /// it — runs/i8d-drag1, pin [0, 0.4325], S5 58 of 58 frames exposed.
    private func onScreen(_ rect: CGRect, _ tracker: WindowTracker) -> Bool {
        tracker.screenFrame
            .insetBy(dx: WindowTracker.containTolerance, dy: WindowTracker.containTolerance)
            .contains(rect)
    }

    // MARK: - window-relative geometry

    /// `rect` as fractions of `frame`, CLIPPED to the frame first.
    ///
    /// The clip is defect 1a's "intersected with the window frame": the
    /// published cover carries MotionBoxes' one-cell publish margin, the
    /// overlay's 1% pad and — at speed — the heat field's motion smear, and all
    /// three can hang outside the window. None of them can be part of the
    /// player, because the player is inside its own window, so clipping cannot
    /// uncover content and it keeps the smear out of the thing we then ride.
    ///
    /// Callers only reach here for a cover the window HOLDS (the
    /// `minContainedFraction` gate), so the intersection is non-degenerate by
    /// construction; the guard is the belt, not the mechanism, and it answers
    /// "the whole window" only because a pin has to be something and
    /// over-cover is the safe direction.
    private func fractions(of rect: CGRect, in frame: CGRect) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard frame.width > 0, frame.height > 0 else { return whole }
        let c = rect.intersection(frame)
        guard !c.isNull, c.width > 0, c.height > 0 else { return whole }
        return CGRect(
            x: (c.minX - frame.minX) / frame.width, y: (c.minY - frame.minY) / frame.height,
            width: c.width / frame.width, height: c.height / frame.height)
    }

    /// The inverse of `fractions`: where a pin sits on a given window frame.
    private func place(_ pin: CGRect, on frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + pin.minX * frame.width, y: frame.minY + pin.minY * frame.height,
            width: pin.width * frame.width, height: pin.height * frame.height)
    }

    private func rounded(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f,%.0f,%.0f)", r.minX, r.minY, r.width, r.height)
    }
}
