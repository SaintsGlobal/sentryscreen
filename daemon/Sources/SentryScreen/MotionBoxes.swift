import CoreGraphics
import CoreVideo
import Foundation

/// Pixel-side "media box" inference for cover mode `media` (SPEC §5.5): finds
/// screen rectangles that keep changing — a playing video — so a detection
/// inside one can be expanded to the whole player.
///
/// Revised 2026-08-17 after the first live media-mode run (runs/media-video)
/// produced no box on a real pan video: a smooth pan only changes
/// high-gradient cells each frame, so per-frame changed-cell components are
/// fragmented and their bounding boxes jump, and the consecutive-match chain
/// never completed. Two changes, both tuned against recorded frames (receipts
/// at each constant, sweep in the media-mode report):
///   1. a per-cell HEAT accumulator — a cell stays "hot" for heatMax updates
///      after it changes, so a panning player turns solid within ~0.3 s;
///   2. a scroll guard — a page scrolling through a viewport is also a
///      continuously changing rectangle and is otherwise indistinguishable
///      from a video (measured: fill, area, hot fraction and bbox stability
///      all overlap), so translating content is rejected explicitly.
///
/// Detect queue only. Pipeline calls this from `sentryscreen.detect` and
/// nowhere else, so all state here is single-threaded by construction and
/// carries no locking. All working buffers are allocated once and reused.
final class MotionBoxes {
    /// Diagnostic sink (2026-08-21): media-mode debug lines previously
    /// went to bare stdout only — invisible to log tooling and uncapped if a
    /// launchd plist ever redirects stdout to a file. Live runs wire this to
    /// the pipeline's rate-limited "media-diag" event path (main.swift);
    /// unwired (fixture replay, tests) falls back to stdout so gate
    /// fixtures' stdout stays exactly as before.
    var onDiagnostic: ((String) -> Void)?
    private func diag(_ line: String) {
        if let onDiagnostic { onDiagnostic(line) } else { print(line) }
    }

    /// One tracked changing area. `rect` is normalized with a BOTTOM-LEFT
    /// origin — the same space as Detection.box.
    private struct Box {
        var rect: CGRect
        var hits: Int
        var missed: Int
        var stable: Bool
        var fill: CGFloat  // hot cells / bbox cells at the last match
        // v2: this box was moved by the rigid-translation estimator on this
        // update. Read by the SENTRY_MEDIA_DEBUG trace only — the geometry
        // effect is already applied to `rect` — and kept because whether the
        // rigid path fired is the first question any drag investigation asks.
        var movedRigidly = false
        /// Previous update's evidence rect, for the motion (trail) estimate
        /// the edge snap needs — see EdgeSnap.evidenceSlackCells.
        var lastEvidence: CGRect?
        /// This box's rect `motionLookback` updates ago, and the last tick at
        /// which the rect had moved a cell from it — see `movingRecently`.
        var rectHistory: [CGRect] = []
        var lastMoveTick = 0
    }

    /// Updates the box rect is compared against to decide it is MOVING. 3
    /// updates = 100 ms: the slowest scripted motion in the fixtures (the 1.3x
    /// grow, ~4 px/frame per edge) clears a cell in 2 updates, and one update
    /// alone cannot, because the snapped rect is pixel-exact and the slow
    /// phases move it well under a cell per frame.
    private static let motionLookback = 3
    /// How long after its last move a box still counts as moving.
    ///
    /// RESTATED 2026-09-08 (one of the six live-paint constants the receipt
    /// audit left as a KNOWN GAP). Two terms, because the original receipt has
    /// two and they carry DIFFERENT units — that is exactly why a single fixed
    /// frame count could not represent it:
    ///
    ///   A DURATION. "30 updates = 1 s = the spec's tightness-recovery budget:
    ///   an edge stranded by motion must be allowed to converge for as long as
    ///   recovery is allowed to take." Held fixed at 30 that budget doubles to
    ///   2 s at the no-ane tier — over-cover, and past the scorer's own 2 s
    ///   steady guard, so a converging edge could start being scored as steady
    ///   jitter. `motionMemoryUpdatesAt30` x fps / 30 keeps it at 1.0 s.
    ///
    ///   AN UPDATE COUNT, and it does NOT scale. "The worst measured strand
    ///   (135 px, i3-d drag 3) needs 17 updates at the snap's 1 cell/update
    ///   inward rate" — the edge snap moves one cell PER UPDATE whatever the
    ///   frame rate (`EdgeSnap.inwardCellsPerUpdate` is a per-update visual
    ///   limit, not a rate), so 135 px / 8 px-per-cell = 17 updates is a floor
    ///   in UPDATES, not in seconds. 1.0 s at 15 fps is only 15 updates and
    ///   would cut the worst measured strand off two updates before it
    ///   converges.
    ///
    /// Same two-term shape as `Tracker.defaultStickyHold` (duration, floored by
    /// a measured frame count): 30 at 30 fps — exactly the pre-tier value, by
    /// integer arithmetic — and 17 at 15 fps, which is 1.13 s and still ends
    /// before the scorer's 2 s steady guard. `PerfTier.selftest` asserts both
    /// bounds at every fps the floor admits.
    static let motionMemoryUpdatesAt30 = 30
    static let motionMemoryStrandFloor = 17
    static func motionMemoryUpdates(fps: Int) -> Int {
        max(motionMemoryStrandFloor, (motionMemoryUpdatesAt30 * fps) / 30)
    }
    /// The scorer's steady guard, seconds: motion memory must always end before
    /// it, or a converging edge is scored as steady jitter. Read by
    /// `PerfTier.selftest`.
    static let scorerSteadyGuardSecs = 2.0

    // Coarse sampling grid width in cells. 160 resolves a player (the 2% area
    // floor below is ~23x23 cells at 16:9) while costing ~14k byte reads per
    // frame. Verified in the media-mode tuning run: the 1120x630 player in
    // runs/media-video spans 94x53 cells at this grid.
    static let gridWidth = 160
    // Per-cell 8-bit green-channel abs diff that counts as "changed".
    // Receipt (sweep over the three recorded runs at 30 fps, media-mode
    // report): 8 is under the codec/AA noise floor — the slow-v5 scroll then
    // promotes stable boxes (2 events, must be 0) and the media box grows
    // 15 cells past the player; 15 and 20 cost video coverage (90% and 87% of
    // frames vs 96% at 12) because a smooth pan's flat areas fall under the
    // threshold. 12 holds 96% coverage with both scroll fixtures at zero.
    private static let diffThreshold = 12
    // Hot fraction of ALL cells above this means the whole screen is moving
    // (window drag, full-screen transition); form nothing. The scroll guard
    // below, not this one, is what rejects windowed scrolling.
    //
    // ORIGINAL RECEIPT (0.5): "measured healthy range on the three runs: max
    // 0.42 (media), 0.17 (slow-v5), 0.34 (fast-v3), so 0.5 sits beyond every
    // measured scene."
    //
    // TRIPWIRE HIT BY HEALTHY BEHAVIOR — REMEASURED, tk4 stream R (D1 cold
    // start). The 0.42 came from a 560x315 player in a 1280x720 frame: 19% of
    // the screen. The product's real target is a player that fills most of the
    // window, and `hot` is the heat map (heatMax updates of tail) DILATED by a
    // cell, so a big player alone runs the fraction past 0.5 with nothing else
    // on screen. Measured per-frame hot fraction, `SENTRY_GUARD_DEBUG=1`,
    // p50/max (scratchpad/d1r/hot/*.txt):
    //     steady 0.168/0.210   drag 0.161/0.410    resize 0.163/0.316
    //     controls 0.158/0.206 vanish-return 0.113/0.208
    //     wideplay 0.507/0.641 widequiet 0.473/0.687   <- a PLAYER, nothing else
    //     scroll-slow 0.694/0.787  scroll-after-still 0.675/0.787
    //     scroll-fast 0.839/0.875
    // wideplay/widequiet (scratchpad/d1r/gen_wide.py) are fx_steady content in
    // a 1050x590 player — the live iPad ratio (player 0.57 of the capture
    // area). They tripped the 0.5 limit on 43-51% of frames, which is D1: the
    // branch ages every box (destroying candidate hit chains, which need
    // `stableHits` CONSECUTIVE matches) and stamps `lastGlobalHotTick`, which
    // disables the acquisition's candidate union for 2*heatMax after. Measured
    // cost at 0.5: full player coverage first reached at frame 78 (2.60 s) /
    // 114 (3.80 s), matching the live 2.7-3.0 s cold-start block.
    //
    // RAISING IT WAS TRIED AND REJECTED — gate tk4R-a, MEASURED, do not retry
    // without a new discriminator. 0.80 (above every measured player scene,
    // below scroll-fast) reasoning: "the normal path evaluates the SAME scroll
    // guard and ages instead of matching whenever it says translating, so the
    // scroll fixtures lose nothing." FALSE. The guard is only intermittently
    // right on a real scroll (its own receipt: max TESTED-translating run 90 of
    // scroll-slow's 754 frames), and 15 consecutive not-translating frames are
    // all a candidate needs. Measured at 0.80: scroll-after-still
    // scroll_stable_media_boxes 0 -> 447 (budget ==0) and page_cover_painted
    // union 0.9994 of the frame (budget <=0.4); scroll-slow ballooned the
    // region to [0.056 0 0.875 1] and the replay SEGFAULTED (rc=139). This
    // early return, not the scroll guard, is what actually rejects a
    // full-viewport scroll. It is load-bearing at 0.5.
    //
    // So D1 is NOT fixed here and the tripwire stands as a KNOWN LANDMINE: a
    // player that fills most of the screen — the product's own target case —
    // trips a guard meant for whole-screen events, and pays for it in
    // acquisition latency. What the next iteration needs is a discriminator
    // that separates a large playing video from a sliding page. Three were
    // measured and all three failed (see below and the tk4 stream R report);
    // the collateral, not the threshold, may be the better lever: the branch
    // calls ageAll(), and expireStale drops any NON-stable box at missed>=1,
    // so one global-hot frame destroys every candidate hit chain — which is
    // why promotion took 78 frames instead of 15 on wideplay.
    //
    // MEASURED AND REJECTED as extra discriminators (same run, same file):
    // hot-cell BOUNDING-BOX span — player 0.681-0.707 vs scroll 0.631-0.875,
    // overlapping; and this frame's FRESH (undilated, no heat tail) fraction —
    // player p50 0.176 vs scroll-slow p50 0.172, overlapping. Neither
    // separates a large playing video from a slowly scrolling page; only the
    // translation test does, and that is the scroll guard's job already.
    private static let globalHotFraction: CGFloat = 0.5
    // Component bounding boxes below 2% of the screen are cursor blinks, text
    // carets and spinners, not players. Provisional; unchanged from the first
    // implementation and not stressed by the tuning runs.
    private static let minAreaFraction: CGFloat = 0.02
    // Same-box match test between updates. Receipt: consecutive-frame IoU of
    // the largest candidate is p10 0.92 / p50 1.00 on the media run, so 0.5
    // has ample margin; tightening it does NOT help reject scroll (slow-v5
    // measures p10 0.97 — a scrolling column's bbox is *more* stable than a
    // video's).
    private static let matchIoU: CGFloat = 0.5

    // --- Heat accumulator ---
    /// How many updates a cell stays hot after it changes. Receipt (sweep,
    /// media-mode report): at fps/3 (10 at 30 fps) the media box holds 96% of
    /// frames and both scroll fixtures stay at zero stable boxes; at 20, 30,
    /// 45 and 60 the scroll fixtures start promoting boxes (8-23 events)
    /// because a paused scroll region stays hot long enough to look like a
    /// player. Never raise without re-running both scroll fixtures.
    private var heatMax: Int { max(1, fps / 3) }

    // --- Scroll guard ---
    // A page scrolling through a viewport changes continuously inside a fixed
    // rectangle, exactly like a video. The one measured difference is that its
    // content TRANSLATES: one vertical shift explains most of the change.
    // Receipt (strip SAD, lag 4, ±25 cells, best/zero SAD ratio): media p50
    // 1.00 with 5% of frames under 0.6; slow-v5 p50 0.36 with 92% under 0.6;
    // fast-v3 p50 0.19 with 82% under 0.6. End to end this takes slow-v5 and
    // fast-v3 from 32 and 18 stable-box events to ZERO while the media box
    // still promotes at 0.50 s.
    private static let scrollRatio: CGFloat = 0.6
    /// Frames between the two grids compared. 133 ms, enough that a 150 px/s
    /// scroll (the slowest fixture) moves 2.5 cells — one frame apart it moves
    /// 0.6 cells and is unresolvable on this grid.
    ///
    /// RESTATED AS A DURATION 2026-09-02 (PerfTier.swift). This one is not
    /// cosmetic: SPEC §5.5 calls the scroll guard "load-bearing, not cosmetic —
    /// without it the scroll fixtures form stable boxes that would black out a
    /// whole browser viewport", and BOTH this lag and `scrollShiftRange` below
    /// were sized at 30 fps. Held at a fixed 4 frames, a 15 fps run would give
    /// the flick fixture 100 px/frame x 4 frames = 50 cells of translation to
    /// find inside a ±25 search — outside the range, so the guard would go
    /// blind. Deriving the lag from the duration keeps the product
    /// (px/frame x lag) constant, which is exactly what `scrollShiftRange` is
    /// sized against. 4 frames at 30 fps (unchanged), 2 at 15 fps.
    /// The coupling is asserted in `PerfTier.selftest`, not just described
    /// here — a comment can rot into being wrong; the assertion cannot.
    ///
    /// INTEGER FLOOR, not rounding (2026-09-02). With `.rounded()`
    /// the invariant this whole restatement rests on is only true where the
    /// division happens to be exact: at 20 fps `round(4*20/30)` = 3, and the
    /// flick fixture then translates 100 px/frame x 3 = 300 px = 37.5 cells,
    /// OUTSIDE the ±25 search — the guard would go blind at a frame rate no
    /// tier ships but nothing forbids. Integer division floors, so
    /// `lag <= 4*fps/30` holds for every fps, and therefore
    /// `pxPerFrame * lag = (1500/fps) * (4*fps/30) <= 200 px = 25 cells`
    /// ALWAYS. That is a proof rather than a coincidence, and it is exact at
    /// 30 fps (120/30 = 4) so the frozen baseline cannot move.
    /// `PerfTier.selftest` sweeps every fps from `fpsFloor` to 30 against it.
    static let scrollLagFramesAt30 = 4
    static func scrollLagFrames(fps: Int) -> Int {
        max(1, (scrollLagFramesAt30 * fps) / 30)
    }
    /// Vertical shifts searched, in cells. ±25 covers the 1500 px/s flick
    /// fixture (50 px/frame = 25 cells over the 4-frame lag at 30 fps).
    /// Deliberately NOT fps-derived: it bounds how far content moves in ONE
    /// `scrollLagFrames` span, and `scrollLagFrames` is `(4 * fps) / 30` in
    /// INTEGER arithmetic, which floors — so
    /// `pxPerFrame * lag = (1500/fps) * floor(4*fps/30) <= 200 px = 25 cells`
    /// for EVERY fps, not only where the division comes out exact. That is why
    /// the lag uses integer division rather than rounding. `PerfTier.selftest`
    /// sweeps every fps from `fpsFloor` to 30 against this bound.
    static let scrollShiftRange = 25
    /// The fixture this range is sized against (`scroll-fast`, SPEC §5.5) and
    /// the grid's cell size in pixels at the 1280-wide capture — both named so
    /// the selftest can re-derive the bound instead of trusting the comment.
    static let scrollFixturePxPerSec = 1500.0
    static let gridCellPx = 8.0
    /// Width of the sampled column strip. Scrolling is vertical, so a narrow
    /// strip through the middle of the changing area decides it; full-width
    /// SAD costs ~5x more for the same answer.
    private static let scrollStripCols = 32

    /// Consecutive TESTED-translating updates after which media mode degrades
    /// to region mode (spec §1: "media mode degrades exactly to region mode on
    /// scroll"). See `sustainedTranslation` for the receipt.
    private var scrollDemoteFrames: Int { max(1, fps / 2) }

    /// Consecutive updates on which the scroll guard RAN and said "translating".
    /// A frame that never ran the test — no candidate, no detection, no
    /// provisional riding on the answer, or a frozen no-information frame that
    /// returned before the guard — is "not tested", not "not translating", so
    /// it HOLDS the run rather than clearing it. Continuous scrolling drops in
    /// and out of the gate condition frame to frame, and a reset on an untested
    /// frame makes a sustained run unreachable.
    private var translatingRun = 0
    /// Last update on which the guard's translating run was SUSTAINED
    /// (>= scrollDemoteFrames). Read by updateProvisional: after a scroll
    /// stops, the heat field stays scroll-contaminated for the heat tail, and
    /// a candidate component drawn from it spans the page, not the media
    /// element. Receipt (scroll-after-still, i5-verify): acquire() at f696
    /// returned the photo (360x405 px) but the union with the f696 candidate
    /// ballooned the provisional to 0.650x0.978 of the screen — the scroll
    /// ended at f690, 6 updates earlier, inside heatMax = 10.
    private var lastSustainedTick = Int.min / 2
    /// Last update on which the global-hot early return fired (whole screen
    /// changing). Same contamination meaning as lastSustainedTick, but it
    /// cannot go stale: the hot test runs on every update unconditionally.
    private var lastGlobalHotTick = Int.min / 2

    /// Per-frame guard trace for threshold measurement (`SENTRY_GUARD_DEBUG=1`).
    private static let guardDebug =
        DevEnv.knob("SENTRY_GUARD_DEBUG") != nil

    private let fps: Int
    /// Resolved once from the effective fps (receipt at `scrollLagFramesAt30`). The
    /// grid ring is sized from this, so it must not change mid-run.
    /// STORED, not computed (gate tier5): as a computed property this was
    /// re-evaluated on every access inside `remember` and `translating`, both
    /// of which run per frame on the media pixel path — and that path carries a
    /// 2.0 ms wall-clock budget the gate scores (`media_path_pixel_work`). It
    /// is a launch-time constant; resolve it once.
    private let scrollLagFrames: Int
    /// Consecutive matched updates before a candidate becomes stable: ~0.5 s.
    /// Verified in the tuning run: the real player promotes at frame 15
    /// (0.50 s) and neither scroll fixture ever completes a chain.
    private var stableHits: Int { max(1, fps / 2) }
    /// Unmatched updates before a stable box expires: ~1 s, so a paused or
    /// static-scene video keeps its box across a short still stretch. The heat
    /// tail adds to this — after content stops, cells stay hot for heatMax
    /// updates before the box starts missing, so the box actually survives
    /// heatMax + expireUpdates = 40 updates (~1.33 s at 30 fps; measured in
    /// the synthetic harness). Provisional; the tuning runs never exercised a
    /// mid-run pause.
    private var expireUpdates: Int { max(1, fps) }

    /// Update counter (box liveness bookkeeping and debug traces).
    private var tick = 0
    private var cols = 0
    private var rows = 0
    private var prev: [UInt8] = []
    private var heat: [UInt8] = []
    /// Last `scrollLagFrames + 1` grids, oldest first (scroll guard input).
    private var history: [[UInt8]] = []
    private var boxes: [Box] = []
    private var heldRects: [CGRect] = []
    /// This update's blocked detections (normalized), for the expiry hold in
    /// `expireStale`. Set at the top of `update`.
    private var activeDetections: [CGRect] = []
    private var warnedFormat = false
    /// A candidate with at least this much of its area inside a media-held
    /// region is a fragment of a player that is already covered. Receipt
    /// (live media-mode run, frame census): after the hard cut the expiring
    /// box re-acquired as two spurious sub-rects ([0.138 0.200 0.237 0.600]
    /// and [0.581 0.200 0.138 0.289], both wholly inside the held player
    /// rect) that briefly went stable and drove the overlay to the wrong
    /// shape. 0.8 rather than 1.0 so a fragment poking one cell past the
    /// held rect is still suppressed.
    private static let containedFraction: CGFloat = 0.8
    /// How much bigger the union with a centre-containing candidate must make
    /// a provisional before it is taken (see updateProvisional's growth path).
    ///
    /// A provisional may NOT breathe. Its rect is painted, and an edge that
    /// walks a cell at a time across the acquisition transient is itself a
    /// defect class here: measured without this gate (gate tk4R-a and a
    /// re-score of the same five fixtures), 1-cell nibbles cost controls its
    /// bottom-edge excursion budget (4.995 cells against 2), 1.4% of its
    /// active-frame coverage and a 23.5 px steady edge offset, and produced
    /// steady_stillness direction-reversal cycles on drag (2) and
    /// vanish-return (1). So growth is for REPAIRING a badly under-measured
    /// acquisition, not for tracking.
    ///
    /// Receipt (SENTRY_GUARD_DEBUG, scratchpad/d1r/grow-*.txt — every offered
    /// union, area ratio to the provisional's current rect):
    ///     controls 1.016 (n=1)   drag 1.022 (n=1)   steady 1.016 (n=1)
    ///     resize 1.006-1.010 (n=2)  vanish-return 1.005-1.013 (n=2)
    ///     wideplay 1.017, 1.269, 1.388 (n=4)  <- the D1 repro
    /// Every offer any of the 13 gate fixtures makes is a nibble at or under
    /// 1.022; the D1 repair steps are 1.27 and 1.39. 1.10 sits 4.5x above the
    /// largest nibble and 15% below the smallest real repair — the widest knee
    /// this evidence offers, and it keeps every gate fixture byte-identical.
    private static let provisionalGrowRatio: CGFloat = 1.10
    // Reused scratch: no per-frame allocation in the steady state.
    /// Grid buffers evicted from `history`, held for reuse as the next
    /// `sampleGreen` destination instead of allocating fresh each frame.
    /// Receipt: DERIVED — `history` retains up to `scrollLagFrames + 1` = 5
    /// distinct grid snapshots at once (each update's diff and the scroll
    /// guard read several of them simultaneously), so a single shared scratch
    /// buffer would corrupt live entries; recycling only the grid `remember`
    /// just evicted is safe because that array is no longer referenced by
    /// `history`. At most one eviction happens per `remember` call, so this
    /// never holds more than one buffer in the steady state (5 in `history` +
    /// 1 in flight here matches history's own receipted cap). Cleared in
    /// `reseed` so a resolution change can't hand `sampleGreen` a
    /// wrong-sized array.
    private var recycledGrids: [[UInt8]] = []
    private var hot: [Bool] = []
    /// Cells that changed between THIS frame and the last one — the heat map
    /// before the tail is added. The edge snap tests against this, not against
    /// heat: heat deliberately holds a cell for heatMax updates, which is
    /// exactly the motion trail a shrinking or dragging player leaves behind,
    /// and a trail makes background edges outside the media rect look like
    /// they have changing content inside them (iter1-d: the resize left edge
    /// locked onto a desktop window border 84 px out and never came back).
    private var fresh: [Bool] = []
    private var mask: [Bool] = []
    private var visited: [Bool] = []
    private var queue: [Int] = []

    /// Resolved once from the effective fps, like `scrollLagFrames`.
    /// NAME NOTE: this instance value deliberately shares its name with the
    /// static derivation it is set from. They are in different scopes, so
    /// this compiles and a mistaken `Self.motionMemoryUpdates` would be a type error
    /// rather than a silent wrong value — but inside these state machines
    /// read the bare name as "the resolved value for THIS run".
    let motionMemoryUpdates: Int

    init(fps: Int) {
        self.fps = fps
        self.scrollLagFrames = Self.scrollLagFrames(fps: fps)
        self.motionMemoryUpdates = Self.motionMemoryUpdates(fps: fps)
    }

    /// Returns the current STABLE boxes (normalized, bottom-left origin).
    /// `heldRects` are the tracker's media-held region rects: a candidate
    /// mostly inside one of them is usually a fragment of a player that is
    /// already covered, so its promotion bar is 4x (see requiredHits).
    func update(
        _ buffer: CVPixelBuffer, heldRects: [CGRect] = [], detections: [CGRect] = []
    ) -> Result {
        self.heldRects = heldRects
        self.activeDetections = detections
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            warnFormat()
            return result()
        }
        // One lock for the whole media path: the grid sample and the edge snap
        // read the same frame, and re-locking per stage would double the cost
        // of the cheapest part of the pipeline.
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return result()
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return result() }
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, width / Self.gridWidth)
        guard
            let grid = sampleGreen(
                pixels, width: width, height: height, bytesPerRow: bytesPerRow, step: step)
        else { return result() }
        // First frame, or the capture resolution changed: reseed, no diff.
        guard grid.count == prev.count, cols > 0, rows > 0 else {
            reseed(grid)
            // No diff exists yet, so no scroll guard and no changing component:
            // the acquisition snap still runs, on gradient alone. That is the
            // frame the cold start lives on — a blocked detection is already on
            // screen and the alternative is painting the detection box and
            // popping to the media rect one frame later. Anything it gets wrong
            // on a scrolling page is retracted as soon as the guard can judge
            // (`updateProvisional`), and measured (diag/probe0.py) the
            // gradient-only result is the exact player rect on every fixture
            // that has a player at frame 0.
            updateProvisional(
                detections: detections, candidates: [], translating: false,
                pixels: pixels, width: width, height: height,
                bytesPerRow: bytesPerRow, step: step)
            return result()
        }
        tick += 1
        remember(grid)
        markHot(grid)
        prev = grid

        // The scroll guard, evaluated at most once per frame and only when
        // something rides on the answer. Two callers now: the acquisition /
        // promotion gate below (unchanged), and the demote counter — which must
        // also be fed on the frames the global-hot branch returns early on.
        // Receipt for widening it there (i5-a instrumentation): a full-viewport
        // scroll IS a whole-screen change, so on scroll-after-still the hot
        // fraction passes 0.5 the frame scrolling starts and stays there for
        // 605 of 779 frames — the guard, sitting after that early return, was
        // never once evaluated on the fixture that scrolls (tested=174,
        // translating=0, all of it in the still head). The live scroll run
        // reached the guard because its scroll was windowed, and retracted 8
        // provisionals; the fixture's full-viewport scroll never did.
        var translatingMemo: Bool? = nil
        var guardTested = false
        func isTranslating() -> Bool {
            guardTested = true
            if let translatingMemo { return translatingMemo }
            let value = translating(grid)
            translatingMemo = value
            return value
        }
        func noteGuard() {
            guard guardTested else { return }
            translatingRun = (translatingMemo ?? false) ? translatingRun + 1 : 0
            if translatingRun >= scrollDemoteFrames { lastSustainedTick = tick }
            if Self.guardDebug {
                diag("guard f\(tick) tested=Y tr=\((translatingMemo ?? false) ? "Y" : "n") "
                    + "run=\(translatingRun)")
            }
        }

        let hotCount = hot.reduce(0) { $0 + ($1 ? 1 : 0) }
        let hotFraction = CGFloat(hotCount) / CGFloat(hot.count)
        if EdgeSnap.debug || Self.guardDebug {
            EdgeSnap.debugFrame = tick
            diag(String(format: "hot f%d frac=%.3f limit=%.2f boxes=%d",
                tick, hotFraction, Self.globalHotFraction, boxes.count))
        }
        if hotFraction > Self.globalHotFraction {
            // The whole screen is changing: whatever heat says for the next
            // heat-tail window is contamination, not media-element evidence.
            // (lastSustainedTick alone goes stale here — once nothing is held
            // the guard stops being evaluated and its run counter freezes;
            // measured on scroll-after-still: the f696 grab sat 576 updates
            // after the last guard evaluation but only 6 after this branch.)
            lastGlobalHotTick = tick
            // Only a media COVER that already exists rides on the answer here:
            // this branch cannot promote or acquire anything, so the only use
            // for the run counter on it is retiring a provisional and demoting
            // a latch. A bare detection is not enough — it pays for nothing.
            // Perf receipt (i5-c vs i5-d, an M1 Mac): gating on detections too
            // ran the strip SAD on ~605 of scroll-after-still's 779 frames and
            // cost that fixture avg 0.691 -> 1.033 ms with p99 1.84 -> 2.17-4.65
            // across repeats, against a 2.0 ms avg / 2.5 ms p99 budget — the
            // wrong side of a tripwire for a test that decides nothing on those
            // frames. Gating on cover state alone brings it back to avg 0.730 /
            // p99 2.045, and leaves the guard-evaluation COUNT identical to
            // i5-base on six of the eight fixtures (steady 1799, drag 839,
            // resize 539, controls 1079, scroll-slow 1, scroll-fast 0); only
            // vanish-return (369 -> 509) and scroll-after-still (174 -> 292)
            // pay anything at all, and both measure at or under their i5-base
            // average. No
            // reachability is lost: a latch can only be created on the normal
            // path below, which tests the guard on its own gate, and that path
            // resets the run to 0 whenever the content is not translating.
            if !provisionals.isEmpty || !heldRects.isEmpty {
                _ = isTranslating()
            }
            noteGuard()
            // No usable information this frame (window drag over the whole
            // screen, space switch): freeze every box exactly as it is — no
            // rigid move, no snap — and let it age. The provisional freezes
            // with them: no information this frame is no reason to retract.
            //
            // Unless the guard has been saying "translating" for a sustained
            // run: that IS information, and it says this whole-screen change is
            // a page scrolling, so the provisional cover it acquired before the
            // scroll started is covering nothing. The normal path retracts on a
            // single translating frame; this branch waits for the sustained run
            // because its whole contract is "freeze on no information" and only
            // a sustained run earns the right to overrule it.
            if translatingRun >= scrollDemoteFrames, !provisionals.isEmpty {
                diag("media provisional retracted (\(provisionals.count)) — "
                    + "sustained translation (\(translatingRun) updates)")
                provisionals.removeAll()
            }
            ageAll()
            return result()
        }
        // v2 §1.2: predict first. A stable box that can explain this frame as a
        // rigid translation of its own content moves BEFORE matching, so the
        // candidate it matches against is the predicted position.
        translateStable()
        if EdgeSnap.debug {
            EdgeSnap.debugFrame = tick
            for box in boxes where box.stable {
                diag(String(format: "post-rigid f%d rect=[%.4f %.4f %.4f %.4f] moved=%@ missed=%d",
                    tick, box.rect.origin.x, box.rect.origin.y, box.rect.width, box.rect.height,
                    box.movedRigidly ? "Y" : "n", box.missed))
            }
        }
        let candidates = components()
        // Only pay for the scroll test when something could actually form or a
        // provisional, a held cover or a blocked detection rides on the answer.
        let translatingNow =
            (!candidates.isEmpty || !detections.isEmpty || !provisionals.isEmpty
                || !heldRects.isEmpty)
            && isTranslating()
        noteGuard()
        if !candidates.isEmpty && translatingNow {
            ageAll()
        } else {
            match(candidates)
        }
        if EdgeSnap.debug {
            let desc = boxes.map {
                String(format: "[%.3f %.3f %.3f %.3f]%@h%dm%d", $0.rect.origin.x,
                    $0.rect.origin.y, $0.rect.width, $0.rect.height,
                    $0.stable ? "S" : "-", $0.hits, $0.missed)
            }.joined(separator: " ")
            let cand = candidates.map {
                String(format: "[%.3f %.3f %.3f %.3f]", $0.rect.origin.x, $0.rect.origin.y,
                    $0.rect.width, $0.rect.height)
            }.joined(separator: " ")
            diag("boxes f\(tick) \(desc) | cand \(cand)")
        }
        // v2 §1.1: the heat bbox was only ever the seed; the painted rect is
        // the snapped one.
        snapStable(pixels, width: width, height: height, bytesPerRow: bytesPerRow, step: step)
        updateProvisional(
            detections: detections, candidates: candidates.map(\.rect),
            translating: translatingNow,
            pixels: pixels, width: width, height: height,
            bytesPerRow: bytesPerRow, step: step)
        return result()
    }

    /// Panic/pause path: drop all history so a stale box cannot expand a
    /// detection after the pause with a rect from before it.
    func reset() {
        provisionals.removeAll()
        translatingRun = 0
        lastSustainedTick = Int.min / 2
        lastGlobalHotTick = Int.min / 2
        prev.removeAll()
        heat.removeAll()
        history.removeAll()
        boxes.removeAll()
        cols = 0
        rows = 0
    }

    /// Safety margin added to every published media rect, in grid cells. The
    /// snapped rect is the media boundary to the pixel; this margin is what
    /// makes a single wrong decision harmless. It covers exactly one inward
    /// snap step (EdgeSnap.inwardCellsPerUpdate) plus the half-cell rounding
    /// of the grid, and it is added in cells rather than as a fraction of the
    /// rect because both error sources are grid-sized, not media-sized.
    /// Cost at the fixtures' 560x315 player: area 1.06x before the overlay's
    /// own 2% pad, 1.10x after — inside the 1.20x tightness budget.
    ///
    /// Live receipt for keeping it at 1 (v2-live-video census, 2026-08-18): the
    /// TRACKED right edge measured 0.12 px from the player's true right edge —
    /// i.e. this margin was fully CONSUMED on that edge, not missing from it.
    /// `published` adds it unconditionally and the clamp cannot have eaten it
    /// (the edge sits at 0.732 of frame width, nowhere near the unit square),
    /// so the snap had latched an image edge ~1 cell inside the player boundary
    /// and this margin is exactly what put the cover back on it. That is the
    /// margin doing its job, not a breach: the run measured cover 1.10x, zero
    /// spill and zero flashes over 901 frames. Nothing was uncovered, so there
    /// is no measurement here that justifies a second cell — which would cost
    /// ~2% of each dimension against a 1.20x budget already at 1.10x. If a live
    /// run ever shows the player's own boundary OUTSIDE the tracked rect, that
    /// is the receipt to raise it on. NOT independently pixel-verified by this
    /// iteration: the 0.12 px figure is the census's measurement, and the
    /// "snapped an interior edge" explanation is inferred from it plus this
    /// code, not from re-reading the frames.
    private static let publishMarginCells: CGFloat = 1

    /// What one update produces. `stable` is the promoted, evidence-backed
    /// media boxes — the only ones the log counts and the only ones the scroll
    /// fixtures' "zero media boxes" receipt is about. `provisional` are
    /// single-frame acquisition snaps that cover a blocked detection's media
    /// element until its box promotes; they expand the cover exactly like a
    /// stable box but carry no evidence yet, so counting them as media boxes
    /// would misreport what the pipeline actually knows.
    struct Result {
        var stable: [CGRect] = []
        var provisional: [CGRect] = []
        /// The scroll guard has said "translating" on `scrollDemoteFrames`
        /// consecutive tested updates: this is a page scrolling through a
        /// viewport, not a media element, and every media latch built on it is
        /// wrong. The Tracker demotes its media-held regions to plain regions
        /// on this flag — spec §1, "media mode degrades exactly to region mode
        /// on scroll". Receipt for the threshold (fps/2 = 15 frames = 0.50 s at
        /// 30 fps, the same clock a candidate needs to promote to a stable
        /// media box): max consecutive tested-translating run per fixture,
        /// measured with `SENTRY_GUARD_DEBUG=1` and the guard evaluated on
        /// EVERY frame that has any cover, detection or candidate on it, so the
        /// run lengths are the content's and not the gate's — steady 0, drag 1,
        /// resize 2, vanish-return 2, controls 0, scroll-fast 36, scroll-slow
        /// 90, scroll-after-still 191. 15 sits 7.5x above the worst in-place
        /// motion and 2.4x below the weakest scroll, which is as wide a knee as
        /// this evidence offers. (With the shipped gate the scroll fixtures'
        /// runs stop growing the moment the demote fires, since a demoted run
        /// has no cover left to test for; scroll-after-still reads maxRun=15 and
        /// demotes exactly once.) A
        /// PAUSED video cannot reach it either: `translating` needs one vertical
        /// shift to explain most of the inter-frame change, and a paused frame
        /// has no change at all — the `zero >= 1` mean-abs-diff floor returns
        /// false, so the run never even starts.
        var sustainedTranslation = false
        /// Everything the cover may expand a detection to, stable first.
        var all: [CGRect] { stable + provisional }
    }

    /// One acquisition snap, alive until its evidence box promotes.
    private struct Provisional {
        var rect: CGRect
        /// left, right, top, bottom — see EdgeSnap.Acquired.anchored.
        var anchored: [Bool]
        var missedDetection = 0
        /// The update this provisional was acquired on. Growth (see
        /// updateProvisional) is a REPAIR of the acquisition frame's
        /// measurement, so it is bounded to `stableHits` updates after it —
        /// the promotion clock, i.e. exactly the gap the provisional exists to
        /// bridge. Receipt for needing the bound (gate tk4R-c): on
        /// scroll-after-still a provisional acquired during the still head and
        /// then, 85 updates later as the scroll started, was offered the whole
        /// sliding page as "the changing component the detection sits in" —
        /// it grew to 0.669x0.822 and blew page_cover_bound (0.748 painted
        /// union against a 0.4 budget). The contamination gate cannot catch
        /// that one: the translation is not SUSTAINED yet on the frame the
        /// component first appears. Within `stableHits` of acquisition the
        /// same fixture offers nothing, and the D1 repair lands on the first
        /// two updates.
        var bornTick: Int
    }
    private var provisionals: [Provisional] = []

    private func result() -> Result {
        Result(
            stable: stableRects(), provisional: provisionals.map { published($0.rect) },
            sustainedTranslation: translatingRun >= scrollDemoteFrames)
    }

    /// Acquisition, retraction and expiry of provisional covers (spec item 4).
    ///
    /// Fires on the first blocked detection that no stable box and no existing
    /// provisional already covers. Gated on the scroll guard, and RETRACTED
    /// the moment the guard says the content translates: a page scrolling
    /// through a viewport is the one thing that looks like a media element to
    /// every test available on a single frame.
    private func updateProvisional(
        detections: [CGRect], candidates: [CGRect], translating: Bool,
        pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, step: Int
    ) {
        if translating {
            if !provisionals.isEmpty {
                diag("media provisional retracted (\(provisionals.count)) — "
                    + "content is translating, not a media element")
                provisionals.removeAll()
            }
            return
        }
        let stable = boxes.filter(\.stable).map(\.rect)
        // Promotion replaces the guess with the evidence — but only once the
        // evidence actually covers the guess. Receipt (iter2-d, vanish-return):
        // the box promoted at f440 on a FRAGMENT of the returned player (left
        // edge 872 px against the player's 700 px) and retiring the provisional
        // on "a stable box contains its centre" handed the cover to that
        // fragment: 18 frames with 172 px of the player uncovered, ending in a
        // 146 px single-frame jump when the rest of the player finally merged
        // in. `containedFraction` is the same bar MotionBoxes already uses for
        // "this candidate is a fragment of something already covered".
        provisionals.removeAll { p in
            let area = p.rect.width * p.rect.height
            guard area > 0 else { return true }
            return stable.contains { box in
                let overlap = box.intersection(p.rect)
                guard !overlap.isNull else { return false }
                return overlap.width * overlap.height >= Self.containedFraction * area
            }
        }
        // The detection that justified the cover is gone: age it out on the
        // same clock a stable box uses, so a brief detector dropout inside the
        // media does not drop the cover.
        for i in provisionals.indices {
            let seen = detections.contains { provisionals[i].rect.intersects($0) }
            provisionals[i].missedDetection = seen ? 0 : provisionals[i].missedDetection + 1
        }
        provisionals.removeAll { $0.missedDetection >= expireUpdates }

        // The changing component is fresh evidence on EVERY frame, not only on
        // the acquisition frame, and the contamination gate below is the same
        // one the acquisition itself rides.
        let unionable = tick - max(lastSustainedTick, lastGlobalHotTick) > 2 * heatMax
        for detection in detections {
            let center = CGPoint(x: detection.midX, y: detection.midY)
            guard !stable.contains(where: { $0.contains(center) }) else { continue }
            if let i = provisionals.firstIndex(where: { $0.rect.contains(center) }) {
                // ACQUISITION IS NOT ONE-SHOT (tk4 stream R, D1). The rect a
                // provisional is born with is `acquired ∪ component ∪ detection`
                // measured on ONE frame, and this guard used to freeze it there
                // for the provisional's whole life — so a frame that had no
                // usable component (the player not yet playing in a fresh
                // Chrome, or the global-hot branch having stamped
                // lastGlobalHotTick) left a detection-sized cover standing
                // until a box promoted, `stableHits` updates later at best.
                // Measured (scratchpad/d1r, wideplay: a 1050x590 player, the
                // live iPad ratio): the provisional acquired 0.420 wide against
                // a 0.820-wide player and never moved; with the component union
                // available every frame the same run reaches full coverage on
                // the frame the component first spans the player.
                //
                // Grow-only, and only into the component the detection's own
                // centre sits in — the same evidence, the same gate. Bounded by
                // how long a provisional lives (a stable box covering
                // `containedFraction` of it retires it; `expireUpdates` of
                // missed detections kills it), which is why this is not the
                // ratcheting union reverted in media-demo2/3: that one was a
                // LATCH with no owner and no expiry.
                guard tick - provisionals[i].bornTick <= stableHits else { continue }
                guard unionable else {
                    // WHY, not just no: this refusal used to be
                    // silent, which made every claim about which gate blocked
                    // startup growth unfalsifiable from retained logs — the
                    // visible-failure rule applies to gates developers argue
                    // about, not only limits they hit. Bounded spam: this
                    // branch can run at most `stableHits` ticks per
                    // provisional (the age guard above). The age refusal
                    // itself stays silent by design — it is the intended
                    // lifecycle bound, derivable from the acquisition line.
                    let hotHeld = lastGlobalHotTick >= lastSustainedTick
                    diag(String(
                        format: "media provisional growth refused f%d: unionable "
                            + "shut by %@ (stamp f%d, clears %d ticks after it; "
                            + "fix: MotionBoxes.%@)",
                        tick, hotHeld ? "global-hot" : "sustained-translation",
                        max(lastSustainedTick, lastGlobalHotTick), 2 * heatMax,
                        hotHeld ? "globalHotFraction" : "translation gate"))
                    continue
                }
                let was = provisionals[i].rect
                let wasArea = was.width * was.height
                var grown = was
                var refusedMax: CGFloat = 0
                for candidate in candidates where candidate.contains(center) {
                    let merged = grown.union(candidate)
                    let ratio = wasArea > 0 ? merged.width * merged.height / wasArea : 0
                    if Self.guardDebug {
                        diag(String(format: "provgrow f%d ratio=%.3f", tick, ratio))
                    }
                    guard ratio >= Self.provisionalGrowRatio else {
                        refusedMax = max(refusedMax, ratio)
                        continue
                    }
                    grown = merged
                }
                grown = grown.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !grown.isNull, grown.width > 0, grown.height > 0 else { continue }
                if grown != was {
                    // A side the component pushed out is no longer the
                    // acquisition's pixel-exact measurement of the media
                    // boundary, so it must stop claiming to be one: `anchored`
                    // is what MotionBoxes.adopt trusts over the promoting box's
                    // own edge, and a cell-quantized component bound adopted as
                    // "measured" is exactly the latch adoptSlackCells exists to
                    // reject. Receipt: without this, gate tk4R-a's controls
                    // fixture lost coverage (98.6% of active frames, budget
                    // 100) and parked its bottom edge 23.5 px off truth — the
                    // iter2-g failure that adopt was written to prevent.
                    diag(String(
                        format: "media provisional grew rect=[%.3f %.3f %.3f %.3f] "
                            + "(was [%.3f %.3f %.3f %.3f]) — the changing component the "
                            + "detection sits in is larger than the acquisition frame's",
                        grown.origin.x, grown.origin.y, grown.width, grown.height,
                        provisionals[i].rect.origin.x, provisionals[i].rect.origin.y,
                        provisionals[i].rect.width, provisionals[i].rect.height))
                    if grown.minX < was.minX { provisionals[i].anchored[0] = false }
                    if grown.maxX > was.maxX { provisionals[i].anchored[1] = false }
                    if grown.maxY > was.maxY { provisionals[i].anchored[2] = false }
                    if grown.minY < was.minY { provisionals[i].anchored[3] = false }
                    provisionals[i].rect = grown
                } else if refusedMax > 0 {
                    // One line per frame, best refused ratio only — the other
                    // half of the attribution question.
                    diag(String(
                        format: "media provisional growth refused f%d: best "
                            + "candidate ratio %.3f under "
                            + "MotionBoxes.provisionalGrowRatio %.2f",
                        tick, refusedMax, Self.provisionalGrowRatio))
                }
                continue
            }
            let acquired = EdgeSnap.acquire(
                detection: detection, pixels: pixels, width: width, height: height,
                bytesPerRow: bytesPerRow, cellPx: step)
            var rect = acquired.rect
            // The first inter-frame diff, when there is one: the connected
            // changing component the detection sits in is direct evidence of
            // the media element's extent, and on a re-appearance (the player
            // returning at a new position) it IS the element, exactly, on the
            // very first frame. The gradient snap and the component miss in
            // opposite directions — the component is patchy from a single diff
            // (measured: 56 px short on the steady fixture's left at frame 1),
            // the gradient snap stops at the first interior edge when the
            // element has no crisp boundary near that side (measured: 325 px
            // short on vanish-return's left) — so the cover takes the union.
            // ...but NOT while the heat field is scroll-contaminated: for
            // 2x the heat tail after a sustained-translation run ends, the
            // changing component is the still-cooling page, not the element
            // (receipt at lastSustainedTick — the 0.650x0.978 grab happened
            // 6 updates after a 20 s scroll; heat cools in heatMax = 10;
            // 2x for margin). The acquired snap + detection alone carry the
            // cover through that window; the vanish-return case this union
            // exists for has no preceding translation and is unaffected.
            if unionable {
                for candidate in candidates where candidate.contains(center) {
                    rect = rect.union(candidate)
                }
            }
            rect = rect.union(detection).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            provisionals.append(
                Provisional(rect: rect, anchored: acquired.anchored, bornTick: tick))
            diag(String(
                format: "media provisional acquired rect=[%.3f %.3f %.3f %.3f] from "
                    + "detection=[%.3f %.3f %.3f %.3f]",
                rect.origin.x, rect.origin.y, rect.width, rect.height,
                detection.origin.x, detection.origin.y, detection.width, detection.height))
        }
    }

    private func stableRects() -> [CGRect] {
        return boxes.filter(\.stable).map { published($0.rect) }
    }

    /// The published form of any media rect, stable or provisional: the same
    /// safety margin on both, so promotion swaps one for the other without
    /// moving the painted edge (the no-pops criterion measures exactly that
    /// single-frame move).
    private func published(_ rect: CGRect) -> CGRect {
        guard cols > 0, rows > 0 else { return rect }
        let marginX = Self.publishMarginCells / CGFloat(cols)
        let marginY = Self.publishMarginCells / CGFloat(rows)
        return rect.insetBy(dx: -marginX, dy: -marginY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func reseed(_ grid: [UInt8]) {
        prev = grid
        heat = [UInt8](repeating: 0, count: grid.count)
        hot = [Bool](repeating: false, count: grid.count)
        mask = hot
        fresh = hot
        visited = hot
        history.removeAll()
        history.append(grid)
        boxes.removeAll()
        // Old buffers are the wrong size (or stale content) for the new
        // resolution; drop them rather than hand one to sampleGreen.
        recycledGrids.removeAll()
    }

    private func remember(_ grid: [UInt8]) {
        history.append(grid)
        if history.count > scrollLagFrames + 1 {
            recycledGrids.append(history.removeFirst())
        }
    }

    /// Heat: a changed cell is refreshed to heatMax, every other cell cools by
    /// one. Hot cells are then dilated by one cell so the patchy interior of a
    /// panning player forms a single component.
    /// Receipt for the dilation (sweep): +5 points of media frame coverage
    /// (90% -> 95%) and a third fewer box events, at the cost of one cell of
    /// over-coverage per edge — over-block direction.
    private func markHot(_ grid: [UInt8]) {
        let refresh = UInt8(clamping: heatMax)
        for i in 0..<grid.count {
            let delta = Int(grid[i]) - Int(prev[i])
            let changed = delta > Self.diffThreshold || delta < -Self.diffThreshold
            fresh[i] = changed
            if changed {
                heat[i] = refresh
            } else if heat[i] > 0 {
                heat[i] -= 1
            }
            mask[i] = heat[i] > 0
        }
        for i in 0..<mask.count { hot[i] = mask[i] }
        for row in 0..<rows {
            for col in 0..<cols where mask[row * cols + col] {
                let i = row * cols + col
                if col > 0 { hot[i - 1] = true }
                if col < cols - 1 { hot[i + 1] = true }
                if row > 0 { hot[i - cols] = true }
                if row < rows - 1 { hot[i + cols] = true }
            }
        }
    }

    private func ageAll() {
        for i in boxes.indices { boxes[i].missed += 1 }
        expireStale()
    }

    /// True when one vertical shift explains most of the change across the hot
    /// area: content sliding through a viewport (scroll), not a video playing
    /// in place. See the scrollRatio receipt above.
    private func translating(_ grid: [UInt8]) -> Bool {
        guard history.count > scrollLagFrames else { return false }
        let old = history[history.count - 1 - scrollLagFrames]
        var minRow = rows, maxRow = -1, minCol = cols, maxCol = -1
        for row in 0..<rows {
            for col in 0..<cols where hot[row * cols + col] {
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                minCol = min(minCol, col)
                maxCol = max(maxCol, col)
            }
        }
        guard maxRow - minRow >= 12 else { return false }  // too short to judge
        let mid = (minCol + maxCol) / 2
        let c0 = max(0, mid - Self.scrollStripCols / 2)
        let c1 = min(cols, mid + Self.scrollStripCols / 2)
        guard c1 > c0 else { return false }

        func meanAbsDiff(shift: Int) -> CGFloat? {
            let a0 = max(minRow, minRow + shift)
            let a1 = min(maxRow + 1, maxRow + 1 + shift)
            guard a1 - a0 >= 8 else { return nil }
            var total = 0
            for row in a0..<a1 {
                let cur = row * cols
                let ref = (row - shift) * cols
                for col in c0..<c1 {
                    total += abs(Int(grid[cur + col]) - Int(old[ref + col]))
                }
            }
            return CGFloat(total) / CGFloat((a1 - a0) * (c1 - c0))
        }

        guard let zero = meanAbsDiff(shift: 0), zero >= 1 else { return false }
        var bestShift = 0
        var best = zero
        for shift in -Self.scrollShiftRange...Self.scrollShiftRange where shift != 0 {
            if let sad = meanAbsDiff(shift: shift), sad < best {
                best = sad
                bestShift = shift
            }
        }
        return bestShift != 0 && best / zero < Self.scrollRatio
    }

    // --- Rigid translation tracking (v2 §1.2) ---
    /// Cells searched each way. 10 cells = 80 px/frame at the 160-cell grid on
    /// a 1280-wide frame. Receipt (scratch tool rigidcal.py): the fastest
    /// scripted drag (0.5 s, 435 px, smoothstep) peaks at 5.4 cells/frame, so
    /// ±10 keeps ~2x headroom over the fastest motion the fixtures contain.
    private static let rigidRange = 10
    /// Coarse pass step, refined by ±1 around the winner. 121 coarse + 8 fine
    /// SAD evaluations over a 2x-subsampled cell grid: ~60k byte compares for a
    /// player-sized box.
    private static let rigidCoarseStep = 2
    /// Best SAD must be this fraction of the zero-shift SAD or better before a
    /// box is moved. Receipt (rigidcal.py, 22 consecutive-frame pairs): frames
    /// inside a fast drag measure 0.22-0.40; static frames measure 0.65-1.00
    /// (worst static false alarm: steady 900→901 at 0.647, a one-cell content
    /// slide inside the video). 0.5 sits in the empty band between them.
    ///
    /// v3 NOTE — TWO replacements for this coarse, badly-firing search were
    /// built, measured and REVERTED. Do not rebuild either without new evidence.
    ///
    /// 1. vDSP phase correlation (track-c receipts: 100% fire rate at 0.15 px,
    ///    against this search's 23-36% at 5-14 px on real drags). It measures
    ///    CONTENT motion, and from pixels inside a player a camera pan IS a
    ///    rigid translation — identical to the player itself moving. Three
    ///    acceptance gates were measured and all three failed:
    ///      * this same best/zero ratio at full resolution, where it can
    ///        actually see the pan: the steady fixture's box walked 328 px off
    ///        the player (coverage 61.9%, 297 steady_stillness reversals);
    ///      * four interior quadrant patches, 1 px agreement tolerance: still
    ///        458 spurious translations on that fixture (still frames measure
    ///        spread p50 1.38 px — a pan is spatially coherent too);
    ///      * four edge-straddling patches: kills the true positives as well
    ///        (0 accepted on the drag fixture, spread p50 3.4 px, because half
    ///        of each edge patch is static background).
    ///    What this SAD search has that phase correlation does not is the 8 px
    ///    grid quantum: a content pan moves under one cell and is rejected by
    ///    construction. That accident is the only thing separating the two cases
    ///    from inside the box, and it is why a slow real drag is also missed.
    ///
    /// 2. Feeding WindowTracker's measured per-frame window delta in here and
    ///    translating the box by it instead of estimating. Headless was
    ///    byte-identical (no windows, so the path never runs) but the live drag
    ///    run got WORSE where it was supposed to get better: direction-change
    ///    under-cover 71 -> 128 px and exposure 167 -> 767 ms, and the
    ///    post-flick settle it was built to fix went 142 -> 205 px (runs/v3-a vs
    ///    runs/v3-c). The box is re-snapped from pixels by EdgeSnap every frame,
    ///    so a second authority on its position fights the snap instead of
    ///    seeding it. The window delta belongs where it measurably works — on
    ///    the PAINT path, between capture and glass (PaintExtrapolator).
    private static let rigidRatio: CGFloat = 0.5
    /// Below this mean abs cell diff nothing is happening inside the box
    /// (paused video, still frame) and any "best shift" is noise fitting.
    /// Receipt: still frames in the fixtures measure 0.04-0.18; live moving
    /// content measures 7-43.
    private static let rigidMinActivity: CGFloat = 4
    /// Every other cell in each axis. Quarter the compares; a player-sized box
    /// still contributes ~700 samples.
    private static let rigidSubsample = 2

    /// Move every stable box by the translation of its own content, when one
    /// explains the frame. This is what lets the cover ride a window drag
    /// instead of unioning the smear it leaves behind (v1: 4.5x area balloon,
    /// 367 ms lag, 3.2 s recovery).
    ///
    private func translateStable() {
        for i in boxes.indices { boxes[i].movedRigidly = false }
        guard history.count >= 2 else { return }
        let current = history[history.count - 1]
        let previous = history[history.count - 2]
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for i in boxes.indices where boxes[i].stable {
            let probe = rigidProbe(boxes[i].rect, current: current, previous: previous)
            if EdgeSnap.debug {
                diag(String(format: "rigid f%d zero=%.2f best=%.2f ratio=%.3f d=(%d,%d) "
                    + "clipped=%d verdict=%@",
                    tick, probe.zero, probe.best, probe.zero > 0 ? probe.best / probe.zero : -1,
                    probe.dCol, probe.dRow, probe.clipped, probe.verdict))
            }
            guard let shift = probe.shift else { continue }
            let moved = boxes[i].rect
                .offsetBy(
                    dx: CGFloat(shift.dCol) / CGFloat(cols),
                    dy: -CGFloat(shift.dRow) / CGFloat(rows))  // grid rows run downward
                .intersection(unit)
            guard !moved.isNull, moved.width > 0, moved.height > 0 else { continue }
            boxes[i].rect = moved
            boxes[i].movedRigidly = true
            // A confirmed rigid match IS evidence the box is alive. Without
            // this a dragged player's box expires mid-drag and re-acquires
            // inside the stale held rect, where requiredHits is 4x — the
            // 2 s recovery deadlock v1 already hit.
            boxes[i].missed = 0
        }
    }

    /// Everything the rigid estimator decided on one box, so a drag
    /// investigation can read the acceptance test's inputs (zero, best,
    /// activity) instead of guessing from the geometry it produced.
    struct RigidProbe {
        var shift: (dCol: Int, dRow: Int)?
        var zero: CGFloat = 0
        var best: CGFloat = 0
        var dCol = 0
        var dRow = 0
        /// Candidate shifts rejected because the shifted window fell outside
        /// the grid (box against a screen edge).
        var clipped = 0
        var verdict = "ok"
    }

    /// Grid-level SAD translation estimate for the content inside `rect`
    /// between the two most recent grids. `shift` is nil when no shift explains
    /// the change better than standing still (see rigidRatio).
    private func rigidProbe(
        _ rect: CGRect, current: [UInt8], previous: [UInt8]
    ) -> RigidProbe {
        let c0 = max(0, Int(rect.minX * CGFloat(cols)))
        let c1 = min(cols, Int((rect.maxX * CGFloat(cols)).rounded(.up)))
        let r0 = max(0, Int((1 - rect.maxY) * CGFloat(rows)))
        let r1 = min(rows, Int(((1 - rect.minY) * CGFloat(rows)).rounded(.up)))
        var probe = RigidProbe()
        // Smaller than the minimum area a box can have; nothing to correlate.
        guard c1 - c0 >= 8, r1 - r0 >= 8 else {
            probe.verdict = "too-small"
            return probe
        }
        let stride = Self.rigidSubsample
        var clipped = 0

        func sad(_ dRow: Int, _ dCol: Int) -> CGFloat? {
            guard r0 + dRow >= 0, r1 + dRow <= rows, c0 + dCol >= 0, c1 + dCol <= cols
            else {
                clipped += 1
                return nil
            }
            var total = 0
            var count = 0
            var r = r0
            while r < r1 {
                let src = r * cols
                let dst = (r + dRow) * cols + dCol
                var c = c0
                while c < c1 {
                    total += abs(Int(current[dst + c]) - Int(previous[src + c]))
                    count += 1
                    c += stride
                }
                r += stride
            }
            return count > 0 ? CGFloat(total) / CGFloat(count) : nil
        }

        guard let zero = sad(0, 0) else {
            probe.verdict = "no-zero"
            return probe
        }
        probe.zero = zero
        probe.best = zero
        guard zero >= Self.rigidMinActivity else {
            probe.verdict = "quiet"
            probe.clipped = clipped
            return probe
        }
        var best = zero
        var bestRow = 0
        var bestCol = 0
        let range = Self.rigidRange
        let coarse = Self.rigidCoarseStep
        var dRow = -range
        while dRow <= range {
            var dCol = -range
            while dCol <= range {
                if let value = sad(dRow, dCol), value < best {
                    best = value
                    bestRow = dRow
                    bestCol = dCol
                }
                dCol += coarse
            }
            dRow += coarse
        }
        for dRow in (bestRow - 1)...(bestRow + 1) {
            for dCol in (bestCol - 1)...(bestCol + 1) {
                if let value = sad(dRow, dCol), value < best {
                    best = value
                    bestRow = dRow
                    bestCol = dCol
                }
            }
        }
        probe.best = best
        probe.dCol = bestCol
        probe.dRow = bestRow
        probe.clipped = clipped
        guard bestRow != 0 || bestCol != 0 else {
            probe.verdict = "zero-shift-best"
            return probe
        }
        guard best / zero < Self.rigidRatio else {
            probe.verdict = "ratio-reject"
            return probe
        }
        probe.shift = (dCol: bestCol, dRow: bestRow)
        return probe
    }

    /// Snap every stable box onto the real media boundary (EdgeSnap). Runs
    /// after matching, so the seed is this frame's rect however it got there
    /// (rigid move or unchanged).
    private func snapStable(
        _ pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, step: Int
    ) {
        guard cols > 0, rows > 0 else { return }
        for i in boxes.indices where boxes[i].stable {
            let evidence = recentlyChangingRect(around: boxes[i].rect, step: step)
            // SETTLED-TAIL COLLAPSE (D4) is UNFIXED here — tk4 stream R.
            // MECHANISM CONFIRMED and reproduced headlessly for the first time:
            // scratchpad/d1r/widetail2.mp4 is a wide player whose outer content
            // freezes at f250 while its centre keeps playing (the live Sidecar
            // condition: the encode flattens the low-detail periphery below
            // diffThreshold while the face keeps changing). `refine` converges
            // the box onto its evidence, the evidence rect is the bbox of cells
            // that changed in the last `evidenceUpdates` updates, so a
            // periphery going quiet retreats it exactly like a real shrink
            // does: measured player coverage 1.000 -> 0.05-0.33 within 25
            // frames. `expireStale`'s detection hold keeps the box ALIVE and
            // does nothing about it SHRINKING. Live equivalent, tk3: region
            // right edge 220-435 px inside the player on 5/5 flick tails.
            //
            // MEASURED AND REJECTED (do not rebuild without new evidence): a
            // starvation hold at this call site that hands `refine` its
            // existing `evidence: nil` freeze when the band between the
            // evidence and the box carries no heat — the idea being that a real
            // shrink REVEALS background there (those cells change) while quiet
            // content leaves it pixel-identical. The band's hot fraction does
            // not separate the two cases. Measured per-frame, all stable boxes
            // (scratchpad/d1r/band-*.txt, SENTRY_GUARD_DEBUG): widetail2
            // (starvation) p50 0.000, 67% of frames under 0.10; resize (a REAL
            // 0.6x shrink) p50 0.023, 55% of frames under 0.10 — because the
            // box converges onto the evidence within a few updates, so the band
            // is small and codec-noise-dominated in BOTH cases. Built and run
            // end to end anyway: it bought tail coverage p50 0.200 -> 0.270,
            // min 0.044 -> 0.051 on widetail2, i.e. it delays the collapse ~3
            // frames and does not stop it.
            //
            // The decision that actually has to change is `refine`'s
            // convergence rule (EdgeSnap.swift `stale`/`pick`), which is
            // outside this stream's territory, and it is the SAME question as
            // tk4 D5 ("when may a cover legitimately shrink", Stream S,
            // registration-debt-gated sustained evidence). One shrink policy,
            // reconciled once — not a second one invented here.
            // How far the changing region moved since the last update, in
            // pixels: the evidence trails a moving player by that much per
            // update it looks back.
            var lag: CGFloat = 0
            if let evidence, let previous = boxes[i].lastEvidence {
                let dx = max(
                    abs(evidence.minX - previous.minX), abs(evidence.maxX - previous.maxX))
                let dy = max(
                    abs(evidence.minY - previous.minY), abs(evidence.maxY - previous.maxY))
                lag = CGFloat(evidenceUpdates) * max(dx * CGFloat(width), dy * CGFloat(height))
            }
            boxes[i].lastEvidence = evidence
            let motion = movingRecently(i)
            boxes[i].rect = EdgeSnap.refine(
                boxes[i].rect, evidence: evidence, evidenceLag: lag,
                moving: motion.now, movedRecently: motion.recently,
                stillUpdates: boxes[i].lastMoveTick > 0
                    ? tick - boxes[i].lastMoveTick : Int.max,
                pixels: pixels, width: width, height: height,
                bytesPerRow: bytesPerRow, cellPx: step,
                changingNow: { [self] x, y in
                    fresh[cellIndex(x, y, step)]
                })
        }
    }

    /// Is this box MOVING — its own rect a cell away from where it was
    /// `motionLookback` updates ago (`now`), and is it within
    /// `motionMemoryUpdates` of the last time it was (`recently`)? Both are
    /// read only by the edge snap. Keyed on the box's own geometry rather than
    /// on the rigid estimator, which fires on translation only and would miss a
    /// resize, or on the evidence rect, which jumps 60 px on the controls
    /// fixture the moment the control bar stops changing while the player has
    /// not moved at all.
    ///
    /// The two horizons do different jobs and a single one cannot do both.
    /// `now` decides per-frame tracking (whether a stale hold may open, how
    /// fast an edge may move inward) and must end the moment the media stops,
    /// or a quiet frame walks an already-correct edge off the boundary — the
    /// measured failure (i3-i, vanish-return f479): two boxes merged at f453,
    /// which counts as a move, and 26 frames later, with the box long settled,
    /// the left edge's hold opened on a frame with nothing changing just inside
    /// it and took a transient interior video edge 8 px in. `recently` decides
    /// RECOVERY (single-edge convergence), which by definition outlives the
    /// motion that caused it.
    private func movingRecently(_ i: Int) -> (now: Bool, recently: Bool) {
        let rect = boxes[i].rect
        var now = false
        if let old = boxes[i].rectHistory.first {
            let dx = max(abs(rect.minX - old.minX), abs(rect.maxX - old.maxX))
            let dy = max(abs(rect.minY - old.minY), abs(rect.maxY - old.maxY))
            now = dx >= 1 / CGFloat(cols) || dy >= 1 / CGFloat(rows)
            if now { boxes[i].lastMoveTick = tick }
        }
        boxes[i].rectHistory.append(rect)
        if boxes[i].rectHistory.count > Self.motionLookback {
            boxes[i].rectHistory.removeFirst()
        }
        let recently = boxes[i].lastMoveTick > 0
            && tick - boxes[i].lastMoveTick <= motionMemoryUpdates
        return (now, recently)
    }

    /// Updates a cell must have changed within for the edge snap to treat it
    /// as evidence that the media is still there. 3 updates = 100 ms at 30 fps.
    /// Receipt: 1 update (the raw per-frame change) loses the media through the
    /// quiet stretches real video content has — a 9-frame one in the fixtures'
    /// facevideo walked the cover inward 8 px/frame (uncovered frames 44-52 of
    /// every player fixture). The full heat window (heatMax = 10 updates) is
    /// the other failure: it keeps a just-vacated band looking occupied long
    /// enough for a 1 s resize shrink to finish, which froze the cover at the
    /// pre-shrink size. 3 bounds the lag at 3 frames of motion — 30 px at the
    /// fastest scripted inward edge speed, inside the snap's ±32 px window.
    private var evidenceUpdates: Int { 3 }

    /// Bounding box (normalized, bottom-left origin) of cells that changed
    /// within the last `evidenceUpdates` updates, searched over `rect` grown
    /// by the snap's search radius. nil when nothing near the box has changed.
    private func recentlyChangingRect(around rect: CGRect, step: Int) -> CGRect? {
        guard cols > 0, rows > 0, !heat.isEmpty else { return nil }
        let threshold = UInt8(max(1, heatMax - evidenceUpdates + 1))
        let pad = EdgeSnap.searchCells
        let c0 = max(0, Int(rect.minX * CGFloat(cols)) - pad)
        let c1 = min(cols, Int((rect.maxX * CGFloat(cols)).rounded(.up)) + pad)
        let r0 = max(0, Int((1 - rect.maxY) * CGFloat(rows)) - pad)
        let r1 = min(rows, Int(((1 - rect.minY) * CGFloat(rows)).rounded(.up)) + pad)
        guard c0 < c1, r0 < r1 else { return nil }
        var minCol = c1, maxCol = c0 - 1, minRow = r1, maxRow = r0 - 1
        for row in r0..<r1 {
            let base = row * cols
            for col in c0..<c1 where heat[base + col] >= threshold {
                if col < minCol { minCol = col }
                if col > maxCol { maxCol = col }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
        guard maxCol >= minCol, maxRow >= minRow else { return nil }
        return CGRect(
            x: CGFloat(minCol) / CGFloat(cols),
            y: 1 - CGFloat(maxRow + 1) / CGFloat(rows),
            width: CGFloat(maxCol - minCol + 1) / CGFloat(cols),
            height: CGFloat(maxRow - minRow + 1) / CGFloat(rows))
    }

    private func cellIndex(_ x: Int, _ y: Int, _ step: Int) -> Int {
        let col = min(cols - 1, max(0, x / step))
        let row = min(rows - 1, max(0, y / step))
        return row * cols + col
    }

    private func match(_ candidates: [(rect: CGRect, fill: CGFloat)]) {
        var used = [Bool](repeating: false, count: candidates.count)
        for i in boxes.indices {
            // A STABLE box matches the UNION of every candidate that sits
            // inside it, not the single best one. Receipt (iteration-1 drag
            // fixture, the worst finding in the run): during the settle before
            // drag 3 the facevideo's changing area split into a left and a
            // right component (frames 538-566, each ~0.2 wide against a 0.438
            // box), so the best single-candidate IoU fell to 0.45, under the
            // 0.5 bar, on 30 consecutive updates — the box expired at f567
            // even though the player had not moved a pixel. The cover then
            // froze (a media-held region with no box freezes) while drag 3
            // moved the player out from under it (under-cover f607-627), and
            // the replacement box promoted mid-drag from a motion smear
            // (2.26x area). The union of the same two components has IoU 0.96
            // with the box. A player whose content partly goes still is still
            // a player; a player that CLOSES leaves no candidate inside the
            // box at all, so the expiry path still works.
            let hit: Int?
            var unionExtra: [Int] = []
            if boxes[i].stable {
                let inside = candidates.indices.filter {
                    !used[$0] && boxes[i].rect.contains(
                        CGPoint(x: candidates[$0].rect.midX, y: candidates[$0].rect.midY))
                }
                let merged = inside.dropFirst().reduce(inside.first.map { candidates[$0].rect }) {
                    acc, k in acc?.union(candidates[k].rect)
                }
                if let merged, Geometry.iou(merged, boxes[i].rect) > Self.matchIoU {
                    hit = inside.first
                    unionExtra = Array(inside.dropFirst())
                } else {
                    hit = candidates.indices.first {
                        !used[$0] && Geometry.iou(candidates[$0].rect, boxes[i].rect) > Self.matchIoU
                    }
                }
            } else {
                hit = candidates.indices.first {
                    !used[$0] && Geometry.iou(candidates[$0].rect, boxes[i].rect) > Self.matchIoU
                }
            }
            guard let j = hit else {
                boxes[i].missed += 1
                continue
            }
            used[j] = true
            for k in unionExtra { used[k] = true }
            boxes[i].hits += 1
            boxes[i].missed = 0
            boxes[i].fill = candidates[j].fill
            // v2: a STABLE box's geometry comes from rigid translation + edge
            // snap ONLY. The candidate proves the box is still alive and
            // nothing more. Everything v1 did with the candidate geometry —
            // union, rolling union, lerp — and everything iter1-a..f tried
            // (union with the intersection of a still window, rate-limited,
            // restricted to edges the snap had not anchored) put the heat bbox
            // back in charge
            // of the rect and cost the same two failures every time: the drag
            // and shrink smears ballooned the cover 2.7-4.5x, and on steady
            // content the 1-cell dilation pushed edges off the boundary every
            // few frames, which then let the next snap land on an interior
            // edge (25 px uncovered, steady frames 46-51).
            //
            // Accepted cost: a box that promotes on a FRAGMENT of a player
            // (only part of it changing at promotion time) can only grow by
            // snapping to an image edge within 4 cells. If the fragment has no
            // edge to grow to, the cover stays fragment-sized until the box
            // expires and re-promotes from a fresh heat bbox. Over-block is
            // the safe direction and this is the under-block one, so it is a
            // watch item for live runs; no fixture reproduces it.
            if !boxes[i].stable {
                boxes[i].rect = candidates[j].rect
            }
            if !boxes[i].stable && boxes[i].hits >= requiredHits(boxes[i].rect) {
                boxes[i].stable = true
                // Inherit the acquisition snap's geometry. The provisional was
                // measured on real image edges from a detection known to be
                // INSIDE the element; the heat bbox that promoted is
                // cell-quantized and only as big as the part of the element
                // that happens to be changing. Receipt (iter2-g, controls):
                // the box promoted with its bottom on the cell boundary at
                // 512 while the player's boundary is at 515, three pixels away
                // — close enough that the snap's "already on an image edge"
                // hold never fired, and with the control bar opaque the only
                // candidate passing the changing-content test is the BAR's top
                // edge 60 px inside. The bottom walked a cell an update for
                // the 78 frames the bar holds still (4.95 cells of excursion
                // against a 2.0 budget, 14 frames of the player uncovered).
                // Seeded from the provisional the bottom starts ON 515, the
                // hold fires, and it never moves.
                let slack = CGPoint(
                    x: Self.adoptSlackCells / CGFloat(max(cols, 1)),
                    y: Self.adoptSlackCells / CGFloat(max(rows, 1)))
                for p in provisionals where p.rect.intersects(boxes[i].rect) {
                    boxes[i].rect = Self.adopt(boxes[i].rect, p.rect, p.anchored, slack)
                }
                diag(
                    "media box appeared \(Self.describe(boxes[i])) — "
                    + "changing for \(boxes[i].hits) consecutive updates")
            }
        }
        expireStale()
        // A fragment of an already-stable box is not a new player. Without
        // this the patchy interior of a pan spawns extra boxes that promote
        // and then immediately merge (measured: 43 box events over the 45 s
        // media run, 7 with this rule).
        let stable = boxes.filter(\.stable).map(\.rect)
        for j in candidates.indices where !used[j] {
            let center = CGPoint(x: candidates[j].rect.midX, y: candidates[j].rect.midY)
            guard !stable.contains(where: { $0.contains(center) }) else { continue }
            boxes.append(
                Box(
                    rect: candidates[j].rect, hits: 1, missed: 0, stable: false,
                    fill: candidates[j].fill))
        }
        mergeStable()
    }

    /// Consecutive hits required before this candidate promotes. Inside a
    /// media-held region the bar is 4x (~2 s at 30 fps) rather than infinite:
    /// hard-cut fragments (the case containedFraction guards) measured stable
    /// for well under 1 s before merging or expiring, but a real player that
    /// settled at a new position after a window drag persists indefinitely —
    /// and infinite suppression deadlocked drag recovery (media-demo3: the
    /// held cover stayed at drag-smear size because the settled player's box
    /// could never promote inside it, and the tracker can only re-anchor to a
    /// promoted box).
    private func requiredHits(_ rect: CGRect) -> Int {
        coveredByHeldRegion(rect) ? stableHits * 4 : stableHits
    }

    private func coveredByHeldRegion(_ rect: CGRect) -> Bool {
        let area = rect.width * rect.height
        guard area > 0 else { return false }
        // A region held by a PROVISIONAL cover is not "already covered by
        // evidence" — it is the guess this candidate is supposed to replace.
        // Applying the 4x bar to it would push promotion from 0.5 s to 2 s and
        // leave the guess in charge for four times as long as it should be.
        let evidenceHeld = heldRects.filter { held in
            !provisionals.contains { Geometry.iou($0.rect, held) > Self.matchIoU }
        }
        return evidenceHeld.contains { held in
            let overlap = held.intersection(rect)
            guard !overlap.isNull else { return false }
            return overlap.width * overlap.height >= Self.containedFraction * area
        }
    }

    /// Overlapping stable boxes are one media surface; union them so a
    /// detection inside always expands to the whole thing.
    private func mergeStable() {
        var merged = true
        while merged {
            merged = false
            outer: for i in boxes.indices where boxes[i].stable {
                for j in boxes.indices where j > i && boxes[j].stable {
                    guard boxes[i].rect.intersects(boxes[j].rect) else { continue }
                    boxes[i].rect = boxes[i].rect.union(boxes[j].rect)
                    // A merge is bookkeeping, not motion: two boxes over one
                    // player became one. Leaving the pre-merge rect in the
                    // history reads the union as a move and keeps the box
                    // "moving" for the next second, which is long enough for a
                    // quiet stretch in the video to look like a stale edge and
                    // walk a correct edge inward. Receipt (i3-j, vanish-return):
                    // boxes merged at f453 and at f479 — with the player static
                    // and the left edge exactly on its boundary (score 50) —
                    // single-edge convergence pulled that edge 8 px in, the last
                    // steady_stillness cycle in the suite.
                    boxes[i].rectHistory.removeAll()
                    boxes[i].lastMoveTick = max(
                        boxes[i].lastMoveTick, boxes[j].lastMoveTick)
                    boxes[i].hits = max(boxes[i].hits, boxes[j].hits)
                    boxes[i].missed = min(boxes[i].missed, boxes[j].missed)
                    boxes.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
    }

    /// A candidate must match on CONSECUTIVE updates, so one miss drops it; a
    /// stable box survives `expireUpdates` misses.
    private func expireStale() {
        boxes.removeAll { box in
            guard box.missed >= (box.stable ? expireUpdates : 1) else { return false }
            if box.stable,
                activeDetections.contains(
                    where: { box.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) })
            {
                // A blocked detection centered inside the box is direct
                // evidence the media region is still live, even with zero
                // pixel motion. Without this hold, a quiet stretch of video
                // expires the box and the next scene cut re-acquires it —
                // sometimes fragmented, and mid-drag the re-acquisition
                // unions with the motion smear into a full-window balloon.
                // Receipt (iPad Sidecar, 2026-08-19): Sidecar's encode
                // flattens inter-frame noise below diffThreshold during quiet
                // segments, so runs ipad-crop-hold6 / ipad-flick1..3 logged
                // repeated expire/re-appear churn on a playing video; flick3
                // ballooned the cover to the whole window for 5.8 s. Main
                // display never showed this (raw capture keeps cells warm).
                if box.missed == expireUpdates {
                    diag(
                        "media box held \(Self.describe(box)) — no motion for "
                        + "\(expireUpdates) updates but a blocked detection is inside")
                }
                return false
            }
            if box.stable {
                diag(
                    "media box expired \(Self.describe(box)) — "
                    + "no matching motion for \(expireUpdates) updates (~1 s)")
            }
            return true
        }
    }

    /// How far outside the promoting box's own (evidence-backed) edge an
    /// acquisition measurement may sit and still be adopted, in grid cells.
    /// Receipt, the two measured cases this sits between:
    ///   * controls (iter2-g) — the acquisition's bottom is 3 px (0.4 cells)
    ///     outside the heat bbox's, and adopting it is what stops the bottom
    ///     edge walking onto the control bar. Must keep.
    ///   * vanish-return (i3-h) — on the return the detection box pokes 3 px
    ///     ABOVE the player, so the acquisition's outward scan starts already
    ///     past the boundary and anchors on a desktop card edge 32 px (4 cells)
    ///     further up. Adopting it parked the top edge 44 px above the player
    ///     for 2.0 s (past the point where the scorer stops treating the
    ///     appearance as motion: 2 steady_edge_offset violations), and it took
    ///     a two-edge convergence to break out — which also dragged the LEFT
    ///     edge 8 px inward off the boundary it had measured exactly, the
    ///     steady_stillness "settle went backwards" cycle. Must reject.
    /// An unanchored side is a detection-plus-pad guess and keeps its existing
    /// outer-of-the-two rule; only a claimed pixel-exact measurement is bounded.
    private static let adoptSlackCells: CGFloat = 2

    /// Replace the sides of `rect` the acquisition snap measured on a real
    /// image edge with its measurement; keep the outer of the two elsewhere.
    /// `slack` is adoptSlackCells in normalized x/y.
    private static func adopt(
        _ rect: CGRect, _ acquired: CGRect, _ anchored: [Bool], _ slack: CGPoint
    ) -> CGRect {
        // One side: the acquisition's measurement when it is anchored and not
        // further outside the box's own edge than `slack`; the box's own edge
        // when an anchored measurement fails that test (adopting it is exactly
        // the latch); the outer of the two when the acquisition never found an
        // edge there and its value is only a detection-plus-pad guess.
        func side(
            _ anchor: Bool, _ measured: CGFloat, _ own: CGFloat,
            outward: CGFloat, slack: CGFloat
        ) -> CGFloat {
            guard anchor else { return outward > 0 ? max(own, measured) : min(own, measured) }
            return (measured - own) * outward <= slack ? measured : own
        }
        let left = side(anchored[0], acquired.minX, rect.minX, outward: -1, slack: slack.x)
        let right = side(anchored[1], acquired.maxX, rect.maxX, outward: 1, slack: slack.x)
        // Grid rows run downward, so the acquisition's "top" is maxY here.
        let top = side(anchored[2], acquired.maxY, rect.maxY, outward: 1, slack: slack.y)
        let bottom = side(anchored[3], acquired.minY, rect.minY, outward: -1, slack: slack.y)
        guard right > left, top > bottom else { return rect }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private static func describe(_ box: Box) -> String {
        String(
            format: "rect=[%.3f %.3f %.3f %.3f] area=%.3f fill=%.2f",
            box.rect.origin.x, box.rect.origin.y, box.rect.width, box.rect.height,
            box.rect.width * box.rect.height, box.fill)
    }

    /// 4-neighbor BFS over hot cells; bounding boxes at or above the area
    /// floor become candidates. Grid row 0 is the TOP pixel row, so y flips.
    private func components() -> [(rect: CGRect, fill: CGFloat)] {
        for i in visited.indices { visited[i] = false }
        var out: [(rect: CGRect, fill: CGFloat)] = []
        for start in hot.indices where hot[start] && !visited[start] {
            visited[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            var minCol = cols, maxCol = 0, minRow = rows, maxRow = 0, cells = 0
            func push(_ idx: Int) {
                guard hot[idx], !visited[idx] else { return }
                visited[idx] = true
                queue.append(idx)
            }
            while head < queue.count {
                let idx = queue[head]
                head += 1
                let row = idx / cols
                let col = idx % cols
                cells += 1
                minCol = min(minCol, col)
                maxCol = max(maxCol, col)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                if col > 0 { push(idx - 1) }
                if col < cols - 1 { push(idx + 1) }
                if row > 0 { push(idx - cols) }
                if row < rows - 1 { push(idx + cols) }
            }
            let boxCols = maxCol - minCol + 1
            let boxRows = maxRow - minRow + 1
            let width = CGFloat(boxCols) / CGFloat(cols)
            let height = CGFloat(boxRows) / CGFloat(rows)
            guard width * height >= Self.minAreaFraction else { continue }
            // Undo markHot's one-cell dilation on the reported rect. The
            // dilation exists to make a patchy interior connect; leaving it in
            // the rect biases the snap's seed a full cell outward, and the
            // snap takes the qualifying image edge NEAREST the seed. Receipt
            // (iter2-c): with the dilated seed the desktop title-bar edge 12 px
            // below the player's bottom is nearer than the true boundary, and
            // the cover parks there for the rest of the run (steady tightness
            // 82% of frames within 1.20x, needs 95%). Bounded below so a
            // component thinner than 3 cells cannot invert.
            let inset = min(1, min(boxCols - 1, boxRows - 1) / 2)
            out.append(
                (
                    rect: CGRect(
                        x: CGFloat(minCol + inset) / CGFloat(cols),
                        y: 1 - CGFloat(maxRow + 1 - inset) / CGFloat(rows),
                        width: CGFloat(boxCols - 2 * inset) / CGFloat(cols),
                        height: CGFloat(boxRows - 2 * inset) / CGFloat(rows)),
                    fill: CGFloat(cells) / CGFloat(boxCols * boxRows)
                ))
        }
        return out
    }

    private func warnFormat() {
        guard !warnedFormat else { return }
        warnedFormat = true
        let warning = "WARNING: media cover mode needs 32BGRA frames; got another "
            + "format, so no media boxes will form (fix: Capture.start pixelFormat "
            + "or MotionBoxes.sampleGreen)\n"
        FileHandle.standardError.write(Data(warning.utf8))
    }

    /// Green channel of every `step`-th pixel of every `step`-th row. The
    /// caller owns the buffer lock (update() holds one for the whole media
    /// path, snap included).
    private func sampleGreen(
        _ pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, step: Int
    ) -> [UInt8]? {
        let gridCols = width / step
        let gridRows = height / step
        guard gridCols > 0, gridRows > 0 else { return nil }
        cols = gridCols
        rows = gridRows
        let count = gridCols * gridRows
        // Reuse a buffer `remember` just evicted from history when its size
        // still matches this frame's grid; every cell below is overwritten
        // (the loop covers all gridRows * gridCols indices), so a recycled
        // buffer's stale contents never leak into the result.
        var values = recycledGrids.popLast() ?? []
        if values.count != count {
            values = [UInt8](repeating: 0, count: count)
        }
        for row in 0..<gridRows {
            let rowStart = row * step * bytesPerRow
            for col in 0..<gridCols {
                values[row * gridCols + col] = pixels[rowStart + col * step * 4 + 1]  // BGRA
            }
        }
        return values
    }
}
