import CoreGraphics
import Foundation

/// Where a media-held cover should be painted RIGHT NOW, given where the pixel
/// pipeline last said it was.
///
/// WHY. The pixel pipeline publishes at 30 Hz and every rect it publishes is
/// already old when it lands. Measured on this machine:
///
///     capture (change -> frame in hand)        31 ms   §5
///     detect + media + tracker                 17 ms   640m@30 p50
///     commit -> glass                          24 ms   §1
///     30 Hz sample-and-hold                  +~17 ms mean
///     ------------------------------------------------------
///     end-to-end effective lag         95.7 ms p50 / 104.9 p95  (measured A/B)
///
/// track-d §7's decisive A/B at that measured upstream delay: repainting at
/// 60 Hz and advancing the rect between pipeline updates takes the effective
/// lag to 17.8 ms p50 / 52.8 p95. 60 Hz alone (no advance) buys only 7 ms, so
/// the advance is the whole mechanism, and the repaint rate is what lets it
/// land. Costs ~0.4% of one core (§6).
///
/// TWO SOURCES, in priority order:
///   a. **The owning window's live frame.** A dragged window's position is
///      known to the window server at >160 commits/s and readable at 0.089 ms
///      (WindowTracker). This is a MEASUREMENT, not a prediction, and it
///      explains the entire drag defect. Used whenever the region's cover is
///      owned by a window (containment + no floaters).
///   b. **2-tap velocity of the painted rect itself.** For a media element that
///      moves without its window moving (a player scrolling inside a page, a
///      window straddling the screen edge so containment fails). track-d §7:
///      2 taps, never 4 — a 4-tap window lags through reversals and measured
///      WORSE (p90 77.8 vs 26.6 ms).
///
/// SCOPE: media-held regions only. Region-mode regions are painted exactly as
/// before, byte for byte. Two reasons, both receipts: (1) `paintRect`'s
/// leadFrames=1.5 already EXPANDS a region-mode rect along the tracker's
/// velocity, and track-d's tightness arithmetic says stacking a translation on
/// top of that lead double-counts the same lag and blows the 1.20x painted-area
/// budget (a prior margin add blew it at 1.21x, iter2-b); (2) media-held regions
/// have `velocity == .zero` by construction (`Tracker.update` zeroes it in both
/// `mediaHeld` branches — the matched one and the missed one — with its own
/// ratchet receipt at the first of them), so the lead is inert for exactly the
/// regions this advance serves. Nothing here touches leadFrames.
final class PaintExtrapolator {
    /// Commit -> glass on this panel. Receipt (track-d §1, warm 60 Hz layer,
    /// setDisableActions(true), n=30): p50 23.9 ms from position-ready, p90
    /// 31.8, quantized to the 16.7 ms refresh. The horizon has to include it or
    /// the cover is painted where the content WAS when we committed, not where
    /// it is when the pixels land — 22 pt of permanent under-cover at 900 pt/s.
    /// A 120 Hz display would roughly halve it; re-measure with paintlat.swift
    /// before running this on one.
    static let commitToGlassSecs = 0.024

    /// Hard cap on how far ahead of the last pipeline sample the velocity path
    /// (b) will advance a rect. 3 capture frames: past that the detector has
    /// stalled and an advance is guessing, not extrapolating.
    /// The window path (a) is not subject to it — a window frame is measured,
    /// however old the pipeline sample is.
    ///
    /// RESTATED AS A FRAME COUNT 2026-09-02 (PerfTier.swift): the receipt has
    /// always reasoned in "3 capture frames" — detector staleness, which scales
    /// with the frame interval — while the constant was a fixed 0.100 s. At the
    /// no-ane tier's 15 fps that fixed value is 1.5 frames, so a rect would
    /// stop coasting before the NEXT sample was even due and drag covers would
    /// lag exactly where the extrapolator exists to stop them. 0.100 s at
    /// 30 fps (bit-identical to the old literal), 0.200 s at 15 fps.
    /// Live paint path only; `--process` never runs it.
    static let maxVelocityHorizonFrames = 3.0
    static func maxVelocityHorizon(fps: Int) -> Double {
        maxVelocityHorizonFrames / Double(fps)
    }
    /// Set once by `Pipeline` from the effective fps, before any paint runs.
    /// The default is the 30 fps value, so a path that never sets it behaves
    /// exactly as this class did before tiers existed.
    var maxVelocityHorizon = PaintExtrapolator.maxVelocityHorizon(fps: 30)

    /// Repeated pipeline samples to coast the last velocity across before
    /// zeroing it. Receipt (track-d §7b): the daemon drops ~6% of frames
    /// (28.2 of 30 achieved) and a held region republishes its last rect, which
    /// reads as velocity 0 and collapses the advance, then snaps when a fresh
    /// sample lands. Coasting <= 2 repeats cut the modelled p90 at a 25% drop
    /// rate from 108.9 ms to 66.4 ms; at the daemon's real ~6% it is the tail
    /// guard, not the common path.
    private static let coastSamples = 2

    /// Most of the future the window projection will ever cover. 50 ms = 6 poll
    /// periods at 120 Hz; past that the projection is guessing at a window that
    /// has probably stopped, which is what `maxCommitGap` decides.
    ///
    /// This is a CLAMP on the horizon, not a cutoff on it (tk2 T1). It used to
    /// be a cutoff — `guard horizon <= maxWindowProjection else { use the
    /// measured frame }` — and a window that moves in COMMITS with a dwell
    /// between them then loses its lead for the tail of every dwell: at the
    /// 30-40 ms commit cadence these drags run at, the projection covered only
    /// the first ~26 ms of each dwell and was off for the rest. Receipt
    /// (runs/ipad-tk2a-flick6 f382, paint log t=13.555 -> 13.569): the projected
    /// lead collapsed from 34.1 pt to 0 while the tracker's freshest sample was
    /// still one commit (29 pt) behind the window, and the LEADING edge of the
    /// cover fell 8 px short of the player's edge for one frame. Clamping is
    /// only safe because `pinnedAdvance` now unions the projection with the
    /// measured rect, so a horizon that runs long can no longer take cover off
    /// the trailing edge — it can only hold margin ahead.
    private static let maxWindowProjection = 0.050

    /// How long after the last OBSERVED position commit the projection keeps
    /// running. Past this the window has stopped and a stopped window must not
    /// carry a standing lead.
    ///
    /// 100 ms = 2.5-3 missed commits at the 30-40 ms cadence measured on the
    /// v3-flick/tk2a-flick drag legs, and 12 poll periods at 120 Hz — far
    /// outside a healthy dwell, so a real dwell never trips it. The cost when a
    /// drag really does end is `speed x maxWindowProjection` of extra cover
    /// (36 pt at 725 pt/s) held for at most 100 ms = 3 capture frames, which is
    /// over-cover and expires long before the >= 2 s steady window every
    /// tightness criterion is scored on.
    private static let maxCommitGap = 0.100

    /// Distinct window positions the projection is fitted over. 3, i.e. a TWO
    /// STEP baseline, so one bad first-observed timestamp cannot set the speed
    /// on its own (see `projectedFrame`). Also the number the direction guard
    /// has always needed.
    private static let projectionSamples = 3

    /// Shortest baseline a projection velocity may be fitted over. One poll
    /// period: `WindowTracker` samples at 120 Hz, so two distinct positions
    /// CANNOT be first observed closer together than that unless the poll loop
    /// re-phased after a stall and polled twice back to back — which is a clock
    /// artifact, not a speed.
    ///
    /// tk3 Stream W removed that artifact at its source: the poll loop now skips
    /// ahead on the 120 Hz phase grid instead of re-phasing to now, and stamps
    /// each sample at its own read time (WindowTracker.pollLoop). This guard is
    /// KEPT as defence in depth — it is free, and it is the only thing standing
    /// between a future scheduling change and a 44x velocity.
    ///
    /// SKIP-AHEAD'S LEADING COST IS ACCEPTED (tk4 D6 decision, stream A2). vfyW
    /// tableD measured skip-ahead equal-or-worse than the old rephase scheduler
    /// in 30/30 cells: +0.0 pt at stall 0 (the two schedulers coincide) and
    /// +0.5 to +3.6 pt of LEADING exposure at every nonzero stall, because
    /// skip-ahead declines the post-stall catch-up sample and leaves the freshest
    /// ring sample up to one poll period staler. Leading exposure UNCOVERS
    /// content, so this is a real cost, not over-cover. Accepted, four reasons:
    ///   1. BOUNDED AND DERIVABLE. The whole cost is one poll period of staleness:
    ///      8.33 ms x speed = 7.5 pt at 900 pt/s, 6.0 pt at 725. tableD's 3.6 pt
    ///      worst cell sits inside that, so the bound is not an empirical hope.
    ///   2. MAGNITUDE. It is 1-7% of the 44-52 pt structural leading term vfyW
    ///      itself identified as dominant (three distinct samples plus the
    ///      direction guard), which is reached under BOTH schedulers at many
    ///      phases including stall = 0.
    ///   3. IT IS THE PRICE OF THE FIX ABOVE. Read-time stamps + skip-ahead are
    ///      what killed the close-pair minting (94 -> 20 ring pairs / 30 s) and
    ///      with it the 436 pt overshoot class. Reverting to rephase to recover
    ///      3.6 pt would buy back a 436 pt defect.
    ///   4. THE STRUCTURAL TERM IS WHAT MOVED. The fresh-axis continuation below
    ///      attacks that 44-52 pt term directly; the scheduler term is noise
    ///      against it.
    /// The alternative on the table was read-time `lateBy` compensation — stamp
    /// each sample with how late its read was against the phase grid and subtract
    /// it here. NOT IMPLEMENTED, and the reason is structural, not preference:
    /// `WindowTracker.Sample` carries `t` and `frame` only, so the compensation
    /// cannot be computed inside this file, and WindowTracker is outside stream
    /// A2's territory. Anything doable here — adding a constant half-period to
    /// `sinceCommit` — is a blind fudge applied to every sample, stalled or not,
    /// with no measurement behind it. If a future stream owns both files, tableD
    /// is the A/B to re-run.
    ///
    /// Receipt (runs/ipad-v3-flick1, paints t=4.338/4.340/4.354): the window was
    /// crossing the screen at 240 pt/s in 4 pt steps and the two newest distinct
    /// samples were stamped 0.38 ms apart, so the 2-tap velocity read
    /// 10 650 pt/s and threw the painted cover 436 pt PAST the window — 117 870
    /// exposed video pixels on recorded frame f110. The same shape, smaller, in
    /// two more runs: 93.5 pt (flick4 t=8.517) and 50.1 pt (flick3 t=8.243,
    /// frame f234). Those three are MEASURED, from the daemon's own `paints`
    /// against `window_truth`. DERIVED, not measured: fitted over the two-step
    /// baseline the same three instants project 5.5, 1.0 and 0.9 pt — a
    /// counterfactual computed from the window_truth transitions as a proxy for
    /// the poll ring, which is not recorded. The shipped-code receipt is the
    /// headless probe (scratchpad/streamA/probe_main.swift, probe_output.txt),
    /// which drives THIS function with synthetic poll rings and measures
    /// 3328.9 pt of trailing exposure on the 2-tap formula against 0.0 here.
    private static let minVelocityBaseline = 1.0 / WindowTracker.pollHz

    /// Shortest PAIR interval the fresh-axis continuation (see `projectedFrame`)
    /// will fit a velocity over. HALF a poll period, and deliberately not
    /// `minVelocityBaseline` itself.
    ///
    /// What has to be rejected is the rephase close pair: two distinct positions
    /// first observed 0.38 ms apart (measured, receipt at `minVelocityBaseline`).
    /// What has to be ACCEPTED is the honest minimum, one poll period — and a
    /// floor set exactly AT one poll period rejects half of those. MEASURED (tk4
    /// A2, scratchpad/streamA2/pdt.swift): accumulating a 1/120 s grid in double
    /// precision puts 50 of 83 consecutive gaps strictly BELOW 1.0/pollHz by one
    /// ulp, and real poll stamps are wall-clock reads with genuine jitter on both
    /// sides of the period, so `pairDt >= minVelocityBaseline` is a coin flip on
    /// exactly the fast-cadence drags this fix is for. 4.17 ms sits 11x above the
    /// artifact and below every honest pair.
    ///
    /// Defence in depth, not the load-bearing guard: at a rephase the close pair
    /// holds two DISTINCT positions, so the fresh axis's `prevStep` is nonzero and
    /// it is not a fresh axis at all. `freshLeadCap` is what bounds the damage.
    private static let freshPairFloor = 0.5 / WindowTracker.pollHz

    /// Most a fresh axis may lead by, as a multiple of its own newest step.
    ///
    /// A fresh axis has exactly ONE observed step of evidence, and the traced
    /// deficit is one commit of travel — "the margin absorbs one commit, not two"
    /// (D2 trace, ipad-vfyM-flick3). Leading by more than the step just observed
    /// is not extrapolation, it is guessing: with a fixed-size commit delivered on
    /// a jittery timer (the live shape — vfyW cadence_analysis.txt, 80 commits:
    /// consecutive gap ratio p50 1.60, p90 3.44, max 5.68, 32.9% of pairs
    /// differing more than 2x) a short interval reads as a speed-up and the raw
    /// pair fit projects several steps ahead. MEASURED (probe section 2, the
    /// 40/12 ms jitter stream): uncapped 100.1 pt of lead for a 20.5 pt step;
    /// capped, 20.5 pt. On uniform cadences the cap can still bind: fast small
    /// steps (900 pt/s @6.25 ms — the row below) and late ticks of a long
    /// horizon (725 pt/s @40 ms: horizon 0.050 s wants 25.6 pt against a
    /// 20.5 pt step) both hit it. That is the cap working, not an anomaly
    /// (vfyA2 VERDICT discrepancy 6 corrected the earlier claim here).
    ///
    /// Cost of the cap: at commit cadences fast enough that one step is small
    /// (a real titlebar drag, 4 pt at 6.25 ms) the fresh axis gets only that 4 pt
    /// of lead, so the cap binds there and the fix helps least. MEASURED, not
    /// argued (probe section 2, the 900 pt/s @6.25 ms stream): Y leading exposure
    /// over the 120 ms after the turn is 19.9 pt uncapped-and-unfixed, 15.9 pt
    /// with this fix. The 20-29 pt commits of the flick legs — where D2 was
    /// traced — are the case the cap leaves untouched.
    private static let freshLeadCap: CGFloat = 1.0

    /// What the pipeline published for one region on one capture frame.
    struct Anchor {
        /// The owning window and its frame AT CAPTURE TIME, in CGWindowList
        /// space (screen points, top-left origin). nil when the region has no
        /// owned window this frame — ownership loss lets the pixel path
        /// re-anchor (existing semantics).
        var windowID: CGWindowID?
        var windowFrameAtCapture: CGRect?
        /// The PINNED media rect, as fractions of the owner window's frame
        /// (x, y, w, h all in 0...1 of the frame, top-left origin). Set by
        /// `CoverPin` in main.swift; nil means "no pin, do not ride".
        ///
        /// Fractions rather than an offset+size pair because that makes a
        /// window RESIZE the same operation as a window MOVE — defect 4's
        /// proportional rescale falls out of the representation instead of
        /// needing its own scale term to get right.
        var pin: CGRect?
        /// Occlusion in progress: some other layer-0 window is in front of this
        /// cover (defect 1c). The cover is painted exactly where the pipeline
        /// put it and is advanced by NOTHING — not the window, not the
        /// velocity. Freeze has to be its own state rather than "no window",
        /// because "no window" falls through to the velocity path, and that
        /// velocity is computed from the painted rect's own midpoint deltas,
        /// i.e. precisely the box churn an occlusion produces.
        var frozen = false
    }

    private struct State {
        var painted: CGRect
        var t: CFAbsoluteTime
        /// Normalized units per second, from the last two DISTINCT samples.
        var velocity: CGVector = .zero
        /// Per axis: this sample's velocity reversed against the previous one,
        /// so the advance is suppressed on that axis for this sample only.
        var reversed: (x: Bool, y: Bool) = (false, false)
        /// Consecutive repeated samples the current velocity has coasted.
        var coasted = 0
        var anchor = Anchor()
    }

    private var states: [Int: State] = [:]
    /// Screen size in points; the space window frames live in.
    private var screen = CGSize(width: 1, height: 1)
    /// This screen's origin in CG-global space (top-left origin, Y down —
    /// the same space window frames are reported in). (0,0) for the main
    /// display; a real offset for any other (`--display`, main.swift). The
    /// pinned-rect clamp below is the one place this class touches absolute
    /// screen coordinates, and it was silently main-display-only before this
    /// existed — a window at global x -1300 (left of a display placed to the
    /// main display's left) clamped straight to x=0.
    private var screenOrigin = CGPoint.zero

    func setScreenSize(_ size: CGSize, origin: CGPoint = .zero) {
        guard size.width > 0, size.height > 0 else { return }
        screen = size
        screenOrigin = origin
    }

    /// Panic/reset: forget every region, so a resumed run cannot advance a rect
    /// with a velocity or a window delta from before the pause.
    func reset() {
        states.removeAll()
    }

    /// One pipeline update. `painted` and `anchors` are parallel to `regions`.
    /// Regions absent from this update are dropped (tracker ids never repeat).
    func ingest(
        regions: [TrackedRegion], painted: [CGRect], anchors: [Anchor],
        capturedAt: CFAbsoluteTime
    ) {
        var live: [Int: State] = [:]
        live.reserveCapacity(regions.count)
        for (i, region) in regions.enumerated() {
            let rect = painted[i]
            let anchor = i < anchors.count ? anchors[i] : Anchor()
            guard var state = states[region.id] else {
                live[region.id] = State(painted: rect, t: capturedAt, anchor: anchor)
                continue
            }
            let dt = capturedAt - state.t
            let moved = rect.midX != state.painted.midX || rect.midY != state.painted.midY
            if moved, dt > 0 {
                let next = CGVector(
                    dx: (rect.midX - state.painted.midX) / CGFloat(dt),
                    dy: (rect.midY - state.painted.midY) / CGFloat(dt))
                state.reversed = (
                    x: flipped(state.velocity.dx, next.dx),
                    y: flipped(state.velocity.dy, next.dy))
                state.velocity = next
                state.coasted = 0
            } else if dt > 0 {
                // Repeated sample: coast, then give up (receipt at coastSamples).
                state.coasted += 1
                if state.coasted > Self.coastSamples { state.velocity = .zero }
            }
            state.painted = rect
            state.t = capturedAt
            state.anchor = anchor
            live[region.id] = state
        }
        states = live
    }

    /// Where region `id` should be painted at `now`, normalized bottom-left.
    /// Returns `fallback` unchanged for anything this cannot improve on — an
    /// unknown region, a region-mode region, or a window whose frame is gone.
    func rect(
        for region: TrackedRegion, fallback: CGRect, at now: CFAbsoluteTime,
        tracker: WindowTracker?
    ) -> CGRect {
        guard region.mediaHeld, var state = states[region.id] else { return fallback }
        // The pipeline's rect for THIS frame is the authority; the state's own
        // copy can be one commit behind when sync and the tick race.
        state.painted = fallback
        // PRECEDENCE, in one place (iteration 8):
        //   1. pinned to a live owner window   -> ride the pin
        //   2. frozen (occlusion in progress)  -> the pipeline's own rect, and
        //      explicitly NOT the velocity path. `frozen` has to be its own
        //      state rather than "no window", because the velocity is computed
        //      from the painted rect's own midpoint deltas — i.e. precisely the
        //      box churn an occluder dragging across the player produces.
        //   3. otherwise                       -> 2-tap velocity coast
        let glass = now + Self.commitToGlassSecs
        if let ridden = pinnedAdvance(state, at: glass, tracker: tracker) { return ridden }
        if state.anchor.frozen { return fallback }
        return velocityAdvance(state, fallback: fallback, at: glass)
    }

    // MARK: - (a) window path

    /// Place the PINNED media rect on the owner window's projected frame.
    ///
    /// This is a TRANSLATION (plus a proportional rescale on a resize) of a
    /// rect that was measured from pixels while the window was still — not a
    /// transform of whatever the detector published this frame. That is defect
    /// 3: a media element does not move inside its own window during a drag, so
    /// while the window moves the window-relative rect is a stronger claim
    /// about where the player is than the heat field is, and the heat field is
    /// measured collapsing (mediaBoxes=0 on ~82% of erratic-walk frames, cover
    /// falling back to detection size). main.swift hands authority back to the
    /// pixel path after `WindowTracker.stillSecs` of stillness by re-pinning
    /// every frame, so this cannot drift: it is only ever as old as the last
    /// still frame.
    ///
    /// OFF-SCREEN (defect 5): the result is CLAMPED to the screen, and an
    /// entirely off-screen rect clamps to an empty rect at the screen edge —
    /// which paints nothing — rather than falling back to the pipeline's rect.
    /// Falling back is what left a cover stranded at x 513-960 while its window
    /// sat at 1400 (S4 receipt).
    ///
    /// SWEPT PATH, not predicted point (tk2 T1). The ridden rect is the UNION of
    /// the pin placed on the window's LAST MEASURED frame and the pin placed on
    /// its PROJECTED frame, so an extrapolation can only ever add cover ahead of
    /// the window, never take cover off behind it. The projection is a
    /// prediction and a prediction that runs long uncovers the TRAILING edge —
    /// which is the one direction the spec never allows.
    ///
    /// Receipt for needing this on top of `minVelocityBaseline` (tk2 stream A,
    /// runs/ipad-v3-flick4): on the return legs the window travels at ~700 pt/s
    /// and dwells 30-40 ms between commits, so `horizon` reaches its 50 ms guard
    /// with a CORRECT velocity and the honest projection is 34-37 pt. The
    /// standing margin between the painted cover and the video's own edge
    /// measures 25 px = 27 pt (median cover-minus-marker over the four v3-flick
    /// runs), so a correct 35 pt projection still eats the margin and exposes
    /// the trailing edge: f362 (+35.8 pt lead, 3658 px exposed) and f659
    /// (+42.0 pt, 771 px). Fitting the velocity better does NOT close those —
    /// the two-step baseline projects 34.5 and 36.7 pt at the same instants.
    /// Cost of the union, bounded by the same guard: at most `speed x 50 ms` of
    /// extra cover on the trailing side WHILE the window is moving (37 pt on a
    /// 1220 pt media rect = 3% of area, against the 1.6x drag budget), and it
    /// collapses to the measured rect the moment `horizon` passes the guard.
    private func pinnedAdvance(
        _ state: State, at glass: CFAbsoluteTime, tracker: WindowTracker?
    ) -> CGRect? {
        guard let tracker, let id = state.anchor.windowID, let pin = state.anchor.pin,
            !tracker.isDead(id)
        else { return nil }
        let recent = tracker.recentDistinctSamples(of: id, count: Self.projectionSamples)
        guard let latest = recent.first, let measured = place(pin, on: latest.frame)
        else { return nil }
        guard let projected = Self.projectedFrame(from: recent, at: glass),
            let lead = place(pin, on: projected)
        else { return measured }
        if measured.isEmpty { return lead }
        if lead.isEmpty { return measured }
        return measured.union(lead)
    }

    /// The pinned media rect placed on one window frame: normalized, BOTTOM-LEFT
    /// origin, clamped to THIS screen. Empty is a legal answer (defect 5).
    private func place(_ pin: CGRect, on live: CGRect) -> CGRect? {
        guard live.width > 0, live.height > 0 else { return nil }
        // Window-frame space: screen points, TOP-LEFT origin.
        let x = live.minX + pin.minX * live.width
        let y = live.minY + pin.minY * live.height
        let w = pin.width * live.width
        let h = pin.height * live.height
        guard w > 0, h > 0 else { return nil }
        let W = screen.width, H = screen.height
        let ox = screenOrigin.x, oy = screenOrigin.y
        let x0 = min(max(x, ox), ox + W), x1 = min(max(x + w, ox), ox + W)
        let y0 = min(max(y, oy), oy + H), y1 = min(max(y + h, oy), oy + H)
        // Back to normalized, BOTTOM-LEFT origin, relative to THIS screen
        // (subtract the origin before dividing).
        return CGRect(
            x: (x0 - ox) / W, y: (H - (y1 - oy)) / H,
            width: (x1 - x0) / W, height: (y1 - y0) / H)
    }

    /// The owning window's frame at `glass`, projected forward from the poll
    /// ring, or nil when there is nothing honest to project. The freshest 120 Hz
    /// sample is p95 17.9 ms old during a 900 pt/s drag (trackA) and glass is
    /// another 24 ms out, so using it raw would still trail ~35 pt. Projection
    /// only applies on an axis whose direction is unchanged, so the frame a drag
    /// stops or reverses on gets no projection at all — the reversal overshoot
    /// track-d §7 flags is a trailing-edge exposure, i.e. safety-relevant.
    ///
    /// SIZE is projected under the SAME reversal/agrees guard as position
    /// (iteration 8, defect 4). v3 projected the origin and copied the size
    /// verbatim, so on a resize+move leg the cover rode the projected origin
    /// while carrying the size the window had a frame ago; the trailing edge
    /// measured 140 px of exposure lasting ~1 s past the end of motion (stress
    /// F3). Projecting width/height off the same samples closes that, and the
    /// agrees guard is what stops it overshooting through the moment a grow
    /// turns into a shrink — which is the direction that uncovers.
    ///
    /// VELOCITY IS FITTED OVER THE WHOLE BASELINE (oldest to newest of the three
    /// distinct samples), not over the newest PAIR (tk2 stream A). Receipt at
    /// `minVelocityBaseline`: the pair's `dt` is the gap between two
    /// first-observed stamps and the poll loop can emit two of those 0.38 ms
    /// apart, which made the 2-tap velocity 44x the truth and the cover overshot
    /// 436 pt. The direction guard is unchanged — both steps must agree — so
    /// this still refuses to project through a reversal or a standstill.
    ///
    /// FRESH-AXIS CONTINUATION (tk4 stream A2, defect D2). A diagonal leg is not
    /// a first move — it is a turn made by a window that is already travelling.
    ///
    /// The defect. Entering an up+right leg, X carries the velocity it
    /// established on the previous leg and Y starts from a standstill, so on the
    /// FIRST commit of the leg Y's `prevStep` is 0, the two-step direction guard
    /// refuses, and the cover gets a horizontal lead with no vertical one. Traced
    /// on glass (runs/ipad-vfyM-flick3, the 23.30-23.50 s diagonal leg, paint
    /// coords bottom-origin): at t=23.452 the X edge tracks with its extrapolated
    /// lead while the TOP edge holds the previous commit, and at t=23.468 the
    /// cover top sits 4.8 pt BELOW the player top — the 3-4 recording-px band
    /// (x0.937 glass scale) seen on ~6/10 tk3 flicks at 1.5-22 k px for 33-99 ms.
    /// The ~20 pt standing top margin absorbs one commit, not two.
    ///
    /// The rule. An axis whose PREVIOUS step was zero and whose CURRENT step is
    /// nonzero projects if and only if the OTHER position axis's two steps agree
    /// in direction — i.e. something is already moving and this axis is joining
    /// it, which is a turn, not a start.
    ///
    /// PAIR FIT, and only here. The whole-baseline fit (above) averages the fresh
    /// axis's one real step against a zero step, which is why the guard-only form
    /// of this change is worthless: it restores 0.26 pt of lead (d2sim, replaying
    /// the tk3 window_truth commit streams), against a 4.8 pt shortfall. Fitted
    /// over its OWN newest step and interval the same commit gets ~20 pt.
    ///
    /// The pair fit divides by the quantity that read 0.38 ms on
    /// runs/ipad-v3-flick1 and made the old 2-tap velocity 44x the truth, so it
    /// carries two bounds of its own — `freshPairFloor` and `freshLeadCap` below.
    /// Between them the fresh-axis lead can never exceed one observed step, which
    /// is the entire evidence the axis has.
    ///
    /// REVERSALS ARE UNTOUCHED, structurally, not empirically: a reversal has
    /// both steps nonzero, so `prevStep == 0` is false and it falls through to
    /// the unchanged `agrees` refusal. Same for a standstill (`step == 0`) and
    /// for a leg that starts from a full stop — with no already-moving axis to
    /// agree with, BOTH axes stay refused, so this fix is diagonal-specific by
    /// construction and does nothing for a cold start. Probe receipt
    /// (scratchpad/streamA/probe_main.swift section 2, PRE/POST in
    /// scratchpad/streamA2): 4/4 reversal boundaries and 2/2 standstill-start
    /// boundaries project 0.0 pt before AND after; 4/4 fresh-Y boundaries go
    /// 0.0 -> 4.0-20.5 pt of lead, dropping Y leading exposure over the 120 ms
    /// after the turn from 19.9-41.0 pt to 0.5-20.5 pt, with Y over-cover
    /// unchanged to the tenth (5.2/15.6/15.9/26.5 pt) and trailing 0.0 pt
    /// throughout. Section 1's six X-only streams stay byte-identical.
    /// The two axes can never both take this branch — `prevStep == 0` on one axis
    /// is precisely what makes `agrees` false for the other's eligibility test.
    ///
    /// SIZE IS EXCLUDED (`freshOK: false` on width/height). The iteration-8
    /// receipt above says the size guard "is what stops it overshooting through
    /// the moment a grow turns into a shrink — which is the direction that
    /// uncovers"; pairing width's freshness to height's direction is invented
    /// policy with no measurement behind it, so the size axes keep the shipped
    /// behaviour exactly.
    ///
    /// Pure and static so it can be probed headlessly: `--process` builds no
    /// WindowTracker, so this math has no other way to be tested off-screen.
    static func projectedFrame(
        from recent: [WindowTracker.Sample], at glass: CFAbsoluteTime
    ) -> CGRect? {
        guard recent.count >= 3 else { return nil }
        let latest = recent[0], prev = recent[1], older = recent[2]
        let span = latest.t - older.t
        /// The fresh-axis fit's own baseline: the newest step's interval.
        let pairDt = latest.t - prev.t
        // `latest.t` is when this position was FIRST seen, so this is measured
        // from the commit, not from the last poll that echoed it.
        let sinceCommit = glass - latest.t
        guard span >= minVelocityBaseline, sinceCommit > 0, sinceCommit <= maxCommitGap
        else { return nil }
        let horizon = min(sinceCommit, maxWindowProjection)
        let f = latest.frame, p = prev.frame, o = older.frame
        // "Already travelling" per POSITION axis, for the other axis's test.
        let xTravelling = agrees(f.minX - p.minX, p.minX - o.minX)
        let yTravelling = agrees(f.minY - p.minY, p.minY - o.minY)
        /// One axis: project only when this step and the one before it agree in
        /// direction. Returns 0 on a reversal or a standstill — and on a first
        /// move too, unless `freshOK` says the other axis is already travelling,
        /// in which case this is a turn and the axis fits over its own newest
        /// step (see FRESH-AXIS CONTINUATION above).
        func project(
            _ now: CGFloat, _ was: CGFloat, _ before: CGFloat, freshOK: Bool
        ) -> CGFloat {
            let step = now - was, prevStep = was - before
            if agrees(step, prevStep) {
                return (now - before) / CGFloat(span) * CGFloat(horizon)
            }
            guard freshOK, prevStep == 0, step != 0, pairDt >= freshPairFloor
            else { return 0 }
            let lead = step / CGFloat(pairDt) * CGFloat(horizon)
            return min(abs(lead), abs(step) * freshLeadCap) * (step < 0 ? -1 : 1)
        }
        let dx = project(f.minX, p.minX, o.minX, freshOK: yTravelling)
        let dy = project(f.minY, p.minY, o.minY, freshOK: xTravelling)
        let dw = project(f.width, p.width, o.width, freshOK: false)
        let dh = project(f.height, p.height, o.height, freshOK: false)
        guard dx != 0 || dy != 0 || dw != 0 || dh != 0 else { return nil }
        return CGRect(
            x: f.minX + dx, y: f.minY + dy,
            width: max(1, f.width + dw), height: max(1, f.height + dh))
    }

    private static func agrees(_ a: CGFloat, _ b: CGFloat) -> Bool {
        a != 0 && b != 0 && (a > 0) == (b > 0)
    }

    /// True when `next` reverses `prev` on an axis that was actually moving.
    private func flipped(_ prev: CGFloat, _ next: CGFloat) -> Bool {
        prev != 0 && next != 0 && (prev > 0) != (next > 0)
    }

    // MARK: - (b) velocity path

    /// SWEPT PATH here too (tk3 Stream W).
    ///
    /// tk2 gave `pinnedAdvance` a swept union — measured rect ∪ projected rect —
    /// precisely because a prediction that runs long uncovers the TRAILING edge,
    /// the one direction the spec never allows. This path never got it: it
    /// TRANSLATED the pipeline's rect, so every pt of advance was a pt taken off
    /// the trailing edge, by construction. The tk3 spec asks whether "the swept
    /// union protects" this path; it did not, because it was not here.
    ///
    /// Why it was never caught on glass: this path only runs for a media-held
    /// region with NO owned window and no freeze — ownership loss mid-motion —
    /// which was 8 of 13 637 paints in tk2, none of them at speed. The
    /// mechanism is real regardless: the headless probe
    /// (scratchpad/streamW/probe_main.swift, "ownership-loss mid-drag" streams)
    /// measures the translate-only form uncovering 33.0-36.4 pt of trailing edge
    /// at 725-900 pt/s and the union form 0.0 pt, at an over-cover cost equal to
    /// the same 33-36 pt on the trailing side while the region is moving —
    /// bounded by `maxVelocityHorizon` (100 ms) and gone the moment motion
    /// stops, exactly as in `pinnedAdvance`.
    ///
    /// The reversal guard stays. With a union it can no longer be the thing that
    /// prevents an exposure, but it still keeps the cover from ballooning
    /// through every direction change, and removing it would be a second change
    /// with no receipt.
    private func velocityAdvance(
        _ state: State, fallback: CGRect, at glass: CFAbsoluteTime
    ) -> CGRect {
        let horizon = min(glass - state.t, maxVelocityHorizon)
        guard horizon > 0, state.velocity != .zero else { return fallback }
        // Reversal guard: an axis whose velocity just flipped sign gets no
        // advance for one sample. Overshooting through a reversal uncovers the
        // TRAILING edge (track-d §7 measured 48.6 px worst case) and that is the
        // one direction of error that exposes content.
        let dx = state.reversed.x ? 0 : state.velocity.dx * CGFloat(horizon)
        let dy = state.reversed.y ? 0 : state.velocity.dy * CGFloat(horizon)
        guard dx != 0 || dy != 0 else { return fallback }
        let advanced = fallback.offsetBy(dx: dx, dy: dy)
        let out = fallback.union(advanced)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return out.isNull || out.width <= 0 || out.height <= 0 ? fallback : out
    }
}
