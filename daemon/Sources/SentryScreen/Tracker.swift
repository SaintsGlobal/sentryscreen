import CoreGraphics
import Foundation

// `PolicyMode` and the per-class thresholds live in TuningPolicy.swift
// (2026-09-10): `TuningPolicy.defaults` and `ClassRule.threshold` carry the
// receipts for the block floors that used to sit here.

struct TrackedRegion {
    let id: Int
    var rect: CGRect  // normalized, bottom-left origin (Vision/Cocoa)
    var missed: Int
    var velocity = CGVector.zero  // normalized units per frame, smoothed
    // Highest detection confidence seen while alive (see Tracker.holdFrames).
    var peakConf: Float = 0
    // Cover mode `media`: this region ever matched a media-expanded detection,
    // so it holds mediaHoldFrames of misses. Latches for the region's life —
    // the point of media mode is surviving detection dropouts.
    var mediaHeld = false
}

/// IoU tracking + hysteresis (SPEC §5.4): appear on first detection (on the
/// second consecutive one in curtain mode — receipt at `curtainEntryFrames`),
/// clear after N consecutive clean frames, lerp position updates.
final class Tracker {
    /// DEV observer. The callback runs at the exact append that creates a
    /// tracked region. It receives the current frame's representative source
    /// detection and cannot change the tracker result.
    var onBirth: ((TrackedRegion, Detection, Int) -> Void)?
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

    private var regions: [TrackedRegion] = []
    private var nextId = 1
    private(set) var clearAfter: Int
    private(set) var stickyHold: Int
    private let mediaHoldFrames: Int  // 0 = region mode (never applies)
    /// The tuning in force (TuningPolicy.swift). A value copy, swapped whole
    /// by `setTuning` on the caller's queue (detectQueue in the pipeline);
    /// every per-frame read below goes through it, so nothing here is a
    /// compile-time constant any more.
    private(set) var tuning = TuningPolicy.defaults
    private var matchIoU: CGFloat { CGFloat(tuning.tracker.matchIoU) }  // SPEC §5.4

    /// Hysteresis default: 8 frames. Receipt (replay sweep, 4 fixtures,
    /// 2026-08-17): region deaths with a replacement id born in-reach within
    /// 2 frames ("handoff deaths" — each one is a visible overlay flash) at
    /// clearAfter 4 → 8: nav10 49→1, scroll20 35→0, scroll10 2→0, video 2→0.
    /// The knee is 7-8 frames at both 10 and 20 fps (frames, not wall time:
    /// detector miss-gaps span a similar frame count at either rate). Cost:
    /// ghost region-frames roughly double (scroll20 1045→1822 over 1256
    /// frames, mean regions 1.92→2.54), max simultaneous regions 13 < the
    /// 20-region tripwire. Beyond 8 (tested to 16) buys nothing and keeps
    /// inflating ghost cost. Never go below 8; scale up for fps > 20 to hold
    /// the 400 ms floor measured at 20 fps.
    ///
    /// TWO TERMS, TWO KINDS OF RECEIPT (restated 2026-09-02 for the performance
    /// tiers, PerfTier.swift — behaviour unchanged, this formula is exactly
    /// what it was):
    ///  * `clearAfterSecs` is a DURATION and scales with fps, as everything
    ///    downstream assumes when it says "0.4 s".
    ///  * `clearAfterFrameFloor` is genuinely a FRAME count and deliberately
    ///    does NOT scale — the sweep above measured the knee at 7-8 frames at
    ///    both 10 and 20 fps, "frames, not wall time", because detector
    ///    miss-gaps span a similar frame count at either rate.
    /// So below 20 fps the floor takes over and the effective duration grows:
    /// 0.4 s at 30 fps (12 frames), 0.53 s at the no-ane tier's 15 fps (8
    /// frames). That is the measured-correct behaviour, not a bug — but it was
    /// undocumented, and "0.4 s" appears in receipts in three other files, so
    /// it is written down here now. Fail-safe direction: covers linger.
    /// The duration itself is `TuningPolicy.TrackerRules.clearAfterSecs`
    /// (0.4 by default); the floor stays here because it is a measured frame
    /// count, not a tunable.
    static let clearAfterFrameFloor = 8
    static func clearAfter(secs: Double, fps: Int) -> Int {
        max(clearAfterFrameFloor, Int((secs * Double(fps)).rounded()))
    }
    /// The default-tuning value (PerfTier.Derived's pin, tests).
    static func defaultClearAfter(fps: Int) -> Int {
        clearAfter(secs: TuningPolicy.defaults.tracker.clearAfterSecs, fps: fps)
    }

    /// Sticky-hold default: a region that ever matched a confident detection
    /// survives longer detector dropouts before its overlay clears. Receipt
    /// (video-test2 replay, 2026-08-17, 20 fps): during continuous video
    /// playback the detector's miss runs at a persisting subject position are
    /// ≤5 frames, and an intermittently-detected second subject recurs after
    /// 13-18-frame gaps (0.65-0.9 s); the shortest genuine content absence
    /// observed is 100 frames (5 s). clearAfter=4 sat inside the healthy
    /// dropout range, so overlays died mid-playback and respawned (7 cover
    /// drops / 1109 frames; 134/1256 on scroll-v3); hold 20 (= 1.0 s at
    /// 20 fps) took both to 0. The dropouts are playback-timing events, i.e.
    /// temporal, so hold 1.0 s worth of frames at higher fps (extrapolated
    /// above 20 fps — no 30 fps fixture yet); never below the measured
    /// 20-frame floor. Worst case an overlay lingers 1 s after content
    /// leaves — fail-safe direction.
    ///
    /// Same two-term shape as `defaultClearAfter` above, and restated the same
    /// way 2026-09-02 (behaviour unchanged): `stickyHoldSecs` is the duration
    /// the dropout receipt actually reasons about, `stickyHoldFrameFloor` is
    /// the measured 20-frame floor from the 20 fps fixture and does not scale.
    /// 1.0 s at 30 fps (30 frames), 1.33 s at the no-ane tier's 15 fps (20
    /// frames, the floor). Longer than nominal, i.e. fail-safe.
    /// Duration: `TuningPolicy.TrackerRules.stickyHoldSecs` (1.0 by default).
    static let stickyHoldFrameFloor = 20
    static func stickyHold(secs: Double, fps: Int) -> Int {
        max(stickyHoldFrameFloor, Int((secs * Double(fps)).rounded()))
    }
    static func defaultStickyHold(fps: Int) -> Int {
        stickyHold(secs: TuningPolicy.defaults.tracker.stickyHoldSecs, fps: fps)
    }

    /// Position gain: how far a matched region snaps toward the new
    /// detection. Receipt (replay sweep 2026-08-17): at 0.5 the painted rect
    /// trails fast-scrolling content — 233/182/360/23 detection boxes per
    /// fixture were <80% covered by the tracked rect; at 0.85 those drop to
    /// 53/48/82/5, and the *painted* overlay (rect + velocity lead + 10% pad,
    /// Overlay.layerFrame) covers every blocked detection on all four
    /// fixtures (paintedUncovered 0). Jitter cost on near-static content is
    /// detector noise only (video fixture: step p95 8.3→8.7 px at 1080p).
    /// 1.0 also measures clean but removes all damping; 0.85 keeps a margin
    /// against single-frame box outliers. The cover-first union below makes
    /// raw-box coverage structural at any lerp; 0.85 additionally keeps the
    /// smoothed rect itself close to the box.
    private let lerpFactor: CGFloat = 0.85

    /// `stickyHold` defaults to the measured FRAME FLOOR rather than a repeated
    /// literal 20 (2026-09-02): every production call site passes
    /// `defaultStickyHold(fps:)` explicitly, but a bare 20 in this signature is
    /// the pre-tier value hiding where the fps-derived-constant sweep would not
    /// find it, free to drift from the floor it was copied from.
    init(clearAfter: Int, stickyHold: Int = Tracker.stickyHoldFrameFloor,
         mediaHoldFrames: Int = 0) {
        self.clearAfter = clearAfter
        self.stickyHold = max(stickyHold, clearAfter)
        self.mediaHoldFrames = mediaHoldFrames
    }

    /// Swap the tuning and re-derive the two fps-scaled holds from it.
    /// `clearAfterOverride` is `--clear-frames` (a test flag) and wins over
    /// the duration, exactly as it did at construction. Region ages and
    /// pending candidates are untouched: a lower hold applies on the next
    /// frame, a higher one simply lets current regions live longer.
    func setTuning(_ t: TuningPolicy, fps: Int, clearAfterOverride: Int? = nil) {
        tuning = t
        clearAfter = clearAfterOverride ?? Self.clearAfter(secs: t.tracker.clearAfterSecs, fps: fps)
        stickyHold = max(Self.stickyHold(secs: t.tracker.stickyHoldSecs, fps: fps), clearAfter)
    }

    /// A new box matches an existing region on IoU, or on center distance
    /// within one region dimension. IoU alone loses scrolled content: at
    /// 10 fps a moderate scroll moves content more than a face-box height per
    /// frame, so overlap hits zero and regions churn (measured 2026-08-17:
    /// 252 ids, zero followers in a 929-frame scroll test).
    private func matches(_ box: CGRect, _ region: CGRect) -> Bool {
        if Geometry.iou(box, region) >= matchIoU { return true }
        let dx = box.midX - region.midX
        let dy = box.midY - region.midY
        let reach = Self.reachFactor * max(region.width, region.height)
        return dx * dx + dy * dy <= reach * reach
    }

    // Receipt: tuned via headless replay of recorded sessions (scroll-test /
    // nav-test fixtures, 2026-08-17). 2.5 trims churn further (scroll20
    // 145→123 ids) but risks overlay sliding; 2.0 stays the choice until live
    // runs demand more.
    static let reachFactor: CGFloat = 2.0

    // Velocity model (dead reckoning): regions predict their next position,
    // match against the prediction, and coast along their velocity on missed
    // frames instead of standing still. Smoothing and decay guard against one
    // bad match launching a region across the screen.
    // Receipt (replay sweep 2026-08-17 around the final point): smoothing
    // 0.3/0.5/0.7 and decay 0.6/0.7/0.85 are flat on every metric
    // (paintedUncovered 0 throughout, ids within ±5%); keep the originals.
    private let velocitySmoothing: CGFloat = 0.5
    private let velocityDecay: CGFloat = 0.7  // per missed frame while coasting

    // A region whose peak confidence reached stickyConf holds stickyHold
    // frames of misses instead of clearAfter (receipt at defaultStickyHold).
    // Compared against the RAW score since 2026-09-02 (note at
    // TuningPolicy.defaults): before, the Σ=1 label share made nearly every
    // region "confident", so every region got the sticky hold; now only a
    // region whose peak raw score reached 0.6 does — the fail-safe direction
    // is unchanged (a region below it still holds clearAfter).
    private var stickyConf: Float { tuning.tracker.stickyConf }  // above every block threshold

    // A media-held region uses the media hold INSTEAD of sticky/clearAfter
    // (--media-hold, receipt at Options.mediaHoldSecs): the whole point is to
    // survive content-absence gaps longer than the detector's dropout range.
    private func holdFrames(_ r: TrackedRegion) -> Int {
        if r.mediaHeld && mediaHoldFrames > 0 { return mediaHoldFrames }
        return r.peakConf >= stickyConf ? stickyHold : clearAfter
    }

    /// REGION-ENTRY DEBOUNCE (owner decision 2026-09-02, curtain mode only):
    /// a detection must be seen on this many CONSECUTIVE detector frames
    /// before it births a region. `entryFrames` = 1 is SPEC §5.4's "appear on
    /// first detection" and stays the region/media-mode value — `Pipeline`
    /// sets `curtainEntryFrames` only when `--cover curtain` is configured
    /// (keyed on the configured mode, not on a live curtain existing, so a
    /// headless `--process --cover curtain` replay measures the cost on the
    /// synthetic fixtures; a degraded curtain run pays the same one frame).
    /// The gate's `--cover region|media` fixtures therefore cannot move.
    /// Receipt:
    /// every drop came
    /// from 1–6-frame explicit-class false positives, and the region covers
    /// painting on the first blocked detection were the flicker the owner saw
    /// — a one-frame false positive paints for the whole `clearAfter` /
    /// `stickyHold` (0.4 / 1.0 s at 30 fps). With 2 a single-frame false
    /// positive never paints. A real subject is detected on nearly every frame
    /// it is on screen (the `defaultStickyHold` receipt: miss runs ≤ 5 frames
    /// at a persisting subject), so its second sighting is the next frame; a
    /// subject the detector misses on the frame after its first sighting
    /// starts over — more first-paint delay, never a lost cover.
    /// COST:
    /// 20 of
    /// the 25 region births paint exactly one detector frame later — 1000/fps
    /// ms: 33 ms at the default tier's 30 fps, 67 ms at no-ane's 15 fps. The
    /// other 5 are appearance edges where the detector MISSED the frame after
    /// the first sighting (D.DD ×4 → 3 frames; D.....DD ×1 → 7 frames, 233 ms
    /// at 30 fps): the candidate starts over, exactly as written above — the
    /// debounce cannot tell a lone real detection at an intermittent edge from
    /// a single-frame false positive, and that is the trade. After a delayed
    /// birth the smoothed rect converges over a 0–17-frame lerp tail (worst
    /// edge 5.3 px on seven fixtures, 18.6 px on the 1500 px/s scroll-fast
    /// one) and is then identical to the log's last decimal; 38 of 5,602
    /// painted frames (0.7 %) are lost, all of them the delay frames. The
    /// counter above is therefore an UPPER bound on false positives: those 5
    /// intermittent real appearances count too. DELIBERATELY NOT
    /// fps-DERIVED: a single-frame false positive is one frame at every tier,
    /// so the margin is a frame count (same reasoning as
    /// `Curtain.holdCleanFrames` / `Curtain.paroleHits`).
    /// MECHANICS: an unmatched box becomes a pending candidate instead of a
    /// region; the next frame's unmatched boxes are tested against pending
    /// candidates with `matches()` — the same IoU / centre-distance rule a
    /// region uses to claim a box — so a box that moved between the two frames
    /// still confirms, and the born region takes the higher confidence of the
    /// two sightings as its `peakConf`. A candidate the next frame does NOT
    /// re-see is dropped and COUNTED (`takeDebouncedEntries`; Pipeline logs it
    /// as `regionEntriesDebounced` in the 60 s summary) — work this pipeline
    /// drops is never dropped silently. (A candidate whose next-frame box an
    /// existing region claimed first is counted too: that region covers it,
    /// and the count is a summary statistic, not a tripwire.) Nothing is
    /// painted for a pending candidate: PaintSmoother's `mustCover` floor only
    /// widens regions that exist and whose rect holds the box's centre, and a
    /// box whose centre a region holds is matched, never pending. Under the
    /// standard policy a curtain run's blocked detections are exactly the
    /// explicit classes; the debounce keys on the MODE, not the label, so
    /// `--policy strict --cover curtain` debounces the covered classes too and
    /// `--block-faces` test detections the same way (which is what lets the
    /// benign-face fixtures measure it).
    /// The value is per class since 2026-09-10 (`TuningPolicy.ClassRule.
    /// entryFrames`, default 2 for every class); this switch selects the
    /// MODE. `false` is SPEC §5.4's "appear on first detection".
    var curtainEntry = false
    /// Consecutive sightings a candidate of this label needs (1 outside
    /// curtain mode). The label is the merged entry's highest-confidence
    /// source detection.
    private func entryFrames(for label: String) -> Int {
        curtainEntry ? tuning.entryFrames(for: label) : 1
    }
    private struct Entry {
        var rect: CGRect
        var conf: Float
        var media: Bool
        /// Highest-confidence current-frame detection represented by `rect`.
        /// Its original box, label and confidence are the crop receipt; the
        /// merged rect remains the tracker's unchanged geometry input.
        var source: Detection
        /// Index of `source` in this update's detections array.
        var sourceIndex: Int
    }
    private var pending: [(entry: Entry, seen: Int)] = []
    private var debouncedEntries = 0
    /// TUNING TOOL (Detection view): the entry debounce's candidates after
    /// the last `update`, read-only — each merged candidate's rect
    /// (normalized, bottom-left), its label, the consecutive frames it has
    /// been seen and the frames its class needs. Empty outside curtain mode.
    var pendingEntriesForTrace: [(rect: CGRect, label: String, seen: Int, needed: Int)] {
        pending.map { p in
            (rect: p.entry.rect, label: p.entry.source.label, seen: p.seen,
             needed: entryFrames(for: p.entry.source.label))
        }
    }

    /// Pending candidates dropped unconfirmed since the last call (receipt at
    /// `confirmedEntries`). Always 0 while `curtainEntry` is false.
    func takeDebouncedEntries() -> Int {
        defer { debouncedEntries = 0 }
        return debouncedEntries
    }

    /// Region-entry debounce (receipt above, at the former
    /// `curtainEntryFrames`). Outside curtain mode the boxes come back
    /// untouched — the pre-2026-09-02 birth path.
    private func confirmedEntries(
        _ boxes: [Entry]
    ) -> [Entry] {
        guard curtainEntry else { return boxes }
        var confirmed: [Entry] = []
        var next: [(entry: Entry, seen: Int)] = []
        for var box in boxes {
            var seen = 1
            if let j = pending.firstIndex(where: { matches(box.rect, $0.entry.rect) }) {
                let p = pending.remove(at: j)
                seen = p.seen + 1
                box.conf = max(box.conf, p.entry.conf)
                box.media = box.media || p.entry.media
            }
            if seen >= entryFrames(for: box.source.label) {
                confirmed.append(box)
            } else {
                next.append((entry: box, seen: seen))
            }
        }
        // Consecutive means consecutive: a candidate this frame did not
        // re-see is dropped, and counted (receipt at curtainEntryFrames).
        debouncedEntries += pending.count
        pending = next
        return confirmed
    }

    /// `mediaBoxes` are this frame's media rects (stable + provisional). A
    /// media-held region with no fresh detection FOLLOWS the one it overlaps
    /// instead of freezing: the box is live pixel evidence of where the player
    /// is, and freezing on it was the iteration-1 resize failure — the
    /// detector went 19 frames without a blocked detection while the 0.6x
    /// shrink completed, the region held its pre-shrink rect the whole time
    /// (2.0x the truth area, 300 ms of fitted lag) and then jumped 52 px the
    /// frame a detection came back. Freeze still applies when there is no box
    /// at all, which is the hard-cut case the freeze was written for. Empty in
    /// region mode, so nothing there changes.
    /// `sustainedTranslation` is MotionBoxes' scroll guard reporting a sustained
    /// run of translating content (receipt at `MotionBoxes.Result`). Media mode
    /// then degrades EXACTLY to region mode: the
    /// latch clears, so hold, velocity and lerp all revert to region semantics
    /// and the rect converges back onto the detection instead of standing still
    /// while the page slides under it. A latch is a claim that a media ELEMENT
    /// is there; a sustained translation is pixel evidence that it is not.
    /// `frozen` are the region ids whose cover the live ownership layer is
    /// holding under an OCCLUDER (`CoverOwnership`, defect 1c). They do not age
    /// while frozen, and — iteration tk2, stream C — they are not demoted by
    /// `sustainedTranslation` either: an occluder crossing the player IS
    /// translating pixels, and reading them as "the page is scrolling, there is
    /// no media element here" destroys the cover exactly when it is needed.
    /// Receipt inline at the demote.
    ///
    /// WHY this is not "just extend the hold": the media hold exists to survive
    /// DETECTOR dropouts, and it is sized (5 s) against the longest gap
    /// measured inside playing video. An occluder parked over the player is a
    /// different thing — the content is not absent, it is hidden, and there is
    /// positive evidence of that from the window server. Measured on
    /// runs/i8-m1: an occluder sat over the player for 157 capture frames, the
    /// 150-frame media hold expired underneath a perfectly good frozen cover,
    /// the region died, and the replacement region was born as a small box that
    /// then had to grow — a 4567 ms exposure episode (f00944-01080), the worst
    /// in that run. Ageing a region out because something is standing in front
    /// of it is the one dropout the hold should never count.
    ///
    /// Empty for every headless caller (`--process` constructs no
    /// CoverOwnership), so no fixture log can move — the byte-compare gate is
    /// the receipt.
    /// `owned` are the region ids the live ownership layer holds a window PIN
    /// for (previous frame, same provenance as `frozen`). Empty for every
    /// headless caller. NOTE: since the settled-tail union was extended to
    /// unowned regions it no longer follows that this input can never move a
    /// fixture log — ownership now selects only whether that union is CLAMPED
    /// to the region's previous rect (receipt at the call site), and the
    /// clamped branch is the one `--process` takes.
    func update(
        detections: [Detection], mediaBoxes: [CGRect] = [],
        sustainedTranslation: Bool = false, frozen: Set<Int> = [],
        owned: Set<Int> = [], sourceIndices: [Int]? = nil
    ) -> [TrackedRegion] {
        if sustainedTranslation {
            for i in regions.indices where regions[i].mediaHeld {
                // ...unless the ownership layer says this region is FROZEN
                // under an occluder. The exemption is the same one the ageing
                // rule below already has, for the same reason and with the same
                // authority behind it: a window sliding across the player is
                // not the page translating, and the window server has already
                // said so. The demote reads pixel translation as "there is no
                // media element here", which is exactly the inference an
                // occluder invalidates.
                //
                // Receipt (iteration tk2, stream C, runs/ipad-probeC2-multi).
                // The occluder crosses the player at 1480 pt/s; MotionBoxes
                // reads that sweep as sustained translation and the latch
                // demotes — `media latch demoted (region 1)`, stdout line 821,
                // one frame after the log's last `frozen: true` record (976).
                // Losing the latch loses the media-held region, `main.swift`
                // then calls `CoverOwnership.reset()` ("no media-held regions
                // this frame") and the PIN IS DESTROYED. On the reveal
                // everything re-acquires cold: `media provisional acquired`
                // from a half-width detection, a fresh pin of [0.481 .. 0.958]
                // measured off that remnant, and 9467 ms with the whole player
                // bare (peak 319,758 exposed px, f01221-f01507). The two
                // retreats in the same run where the demote did NOT fire were
                // 0 ms / 0 px.
                //
                // Bounded: the exemption lasts exactly as long as the freeze,
                // which the ownership layer clears the walk after the occluder
                // leaves the cover. A genuine scroll under a departed occluder
                // demotes on the next frame, at region-mode semantics, as
                // before. While it holds, the cost is over-block.
                if frozen.contains(regions[i].id) {
                    diag("media latch demote SKIPPED (region \(regions[i].id)) — "
                        + "the cover is frozen under an occluder, so translating "
                        + "pixels are the occluder, not the page")
                    continue
                }
                diag("media latch demoted (region \(regions[i].id)) — "
                    + "content is translating, reverting to region mode")
                regions[i].mediaHeld = false
            }
        }
        var unmatched = Self.mergeDetections(
            detections, sourceIndices: sourceIndices, iouOver: matchIoU)
        for i in regions.indices {
            let predicted = regions[i].rect.offsetBy(
                dx: regions[i].velocity.dx, dy: regions[i].velocity.dy)
            if let j = unmatched.firstIndex(where: { matches($0.rect, predicted) }) {
                let entry = unmatched[j]
                let box = entry.rect
                let conf = entry.conf
                let media = entry.media
                let measured = CGVector(
                    dx: box.midX - regions[i].rect.midX, dy: box.midY - regions[i].rect.midY)
                regions[i].velocity = CGVector(
                    dx: regions[i].velocity.dx * (1 - velocitySmoothing)
                        + measured.dx * velocitySmoothing,
                    dy: regions[i].velocity.dy * (1 - velocitySmoothing)
                        + measured.dy * velocitySmoothing)
                // A demote that only cleared the flag would re-latch on the same
                // frame if a media box still reached this detection, so the
                // latch is closed for as long as the translation is sustained.
                if media && !sustainedTranslation { regions[i].mediaHeld = true }
                // Cover-first: the smoothed rect must still contain the raw
                // detection box, so a moving subject is never part-uncovered
                // by lerp lag. Receipt (2026-08-17 replays): plain lerp left
                // 13.9% of video and 41.9% of scroll-v3 detections <95%
                // covered; union drops both to 0 with no size runaway (the
                // union converges to the box once motion stops).
                let updated = Self.lerp(predicted, box, lerpFactor).union(box)
                // Media-held rect: FOLLOW the fresh expanded box when one
                // exists, FREEZE when none does. Freeze is the hard-cut fix
                // (live census: box expiry once let lerp shrink the cover to
                // face size for 1.37 s — a frozen rect cannot shrink, and
                // only the media hold clears it). Follow replaced a
                // union-only latch that ratcheted a window drag's motion
                // smear into a 0.86x0.98 permanent cover (media-demo2/3):
                // the box level now owns stability (slow-lerp shrink,
                // delayed promotion inside held rects), so the tracker can
                // trust and track it, moving AND shrinking with the player.
                // `box` is detection ∪ media box, so follow never uncovers
                // the detection itself. Accepted cost unchanged: a paused or
                // ended video that still shows blocked content keeps
                // full-player cover — over-block, fail-safe direction.
                if regions[i].mediaHeld {
                    // Cover-first on the frozen path too (i5, live scroll
                    // census): freeze may not cost coverage. A matched
                    // detection with no fresh media box used to leave the rect
                    // exactly where it was while the center-distance match
                    // (reach 2x a large rect) kept feeding it detections that
                    // had slid clean out of it — 284 of 1083 logged detections
                    // COMPLETELY disjoint from the painted rect, faces fully
                    // exposed 12.9 s in a 45 s live scroll run. Union is
                    // grow-only, so freeze semantics survive verbatim where
                    // they were written for: on a hard cut the detection is
                    // already inside the frozen rect and the union is a no-op
                    // (verified — all SEVEN pre-existing media logs, hard cut
                    // and loop wrap included, are byte-identical across this
                    // change and the demote below: i5-a vs i5-base).
                    if media {
                        // SETTLED-TAIL COLLAPSE (tk2 §3; closed for OWNED
                        // regions in tk3, extended to UNOWNED ones here).
                        //
                        // `box` is the detection unioned with the media boxes
                        // that contain its CENTRE (main.swift). Replacing the
                        // region with it throws away every media box that does
                        // NOT contain the face — and in a quiet tail that is
                        // the box describing the rest of the player. Measured,
                        // runs/ipad-v3-flick1/3: on frames with a detection the
                        // region's right edge sits at 830-1100 recording px
                        // against a player edge of 1172, while on the very next
                        // frame WITHOUT one (which takes the union branch
                        // below) it reads 1188 — i.e. the correct evidence was
                        // present the whole time and the matched path discarded
                        // it. Worst under-cover 200-341 px in 5/5 runs, and the
                        // only thing covering it was the ratcheted pin.
                        //
                        // So take the same evidence the unmatched path takes,
                        // unioned with `box` so a matched detection can never
                        // be uncovered. This is a fresh measurement every
                        // frame, not a latch: when the media boxes shrink, so
                        // does this — which is what separates it from the
                        // union-only latch reverted in media-demo2/3 (that one
                        // unioned against its OWN previous rect and could only
                        // ever grow).
                        //
                        // tk3 restricted this to OWNED regions for two
                        // reasons. Reason (b) — "it keeps every headless log
                        // byte-identical, so the regression gate stays a real regression
                        // test" — is a gate-convenience argument, not a
                        // behaviour one, and it is not a reason to leave a
                        // cover collapsed. Reason (a) is real and is kept: the
                        // "one window, one player" reading that makes unioning
                        // every overlapping box safe is exactly what ownership
                        // establishes, and without it a region can straddle two
                        // players and this would fuse them.
                        //
                        // So an UNOWNED region gets the same union, CLAMPED to
                        // what it already covered (`previous ∪ box`). That is
                        // the whole defect — the matched path throwing away
                        // evidence for area the region was already holding —
                        // and the clamp makes fusing structurally impossible:
                        // a second player can only be reached by GROWING past
                        // the previous rect, which this can never do. No
                        // constant, so no tripwire to drift. The clamp always
                        // contains `box`, so a matched detection is still never
                        // uncovered, and the union still SHRINKS with the media
                        // boxes — it is a bound, not a floor.
                        //
                        // THE COST, named because no gate fixture reaches
                        // it. For an UNOWNED region the matched path was the
                        // ONLY place the rect was reset to fresh evidence
                        // (`rect = box`), and that reset was also the only
                        // thing that walked back a rect the UNMATCHED branch
                        // below had ballooned — that branch replaces the rect
                        // with the UNCLAMPED union of the overlapping boxes,
                        // and a provisional can legitimately offer a whole
                        // sliding page (receipt at
                        // `MotionBoxes.Provisional.bornTick`: 0.748 painted
                        // union against a 0.4 page_cover_bound budget). After
                        // this change such a rect STAYS ballooned across
                        // matched frames instead of snapping back on the next
                        // one. Bounded, not unbounded: the value is still
                        // `overlapping(mediaBoxes) ∪ box` intersected with
                        // `previous ∪ box`, so it collapses on the first frame
                        // the wide box shrinks or stops overlapping — MEASURED
                        // in the algorithm loop, scenario
                        // `media-unowned-clamp-balloon`, asserted in
                        // `check_trace.py`. Over-block direction, never under.
                        //
                        // Second-order, same direction: the rect is published
                        // back to MotionBoxes as `tracker.mediaHeldRects`
                        // (main.swift, read BEFORE this update), where
                        // `coveredByHeldRegion` raises a candidate's promotion
                        // bar 4x inside a held rect (`requiredHits`). This line
                        // adds no constant of its own, but it does move that
                        // existing threshold's INPUT. Confined to area the
                        // region already covers, so the only effect is "do not
                        // promote a fragment of something already covered",
                        // which is what the bar is for.
                        //
                        // NOT the tk4 settled-tail collapse:
                        // MEASURED on the
                        // rebuilt widetail2 repro, this is a byte-for-byte
                        // no-op there, because on that scene the single stable
                        // media box itself shrinks 0.820x0.822 -> 0.298x0.492
                        // (EdgeSnap.refine convergence) and there is no second
                        // box to union. That half is still open and still
                        // belongs to the D5 shrink policy.
                        let overlapping = mediaBoxes.filter { $0.intersects(regions[i].rect) }
                        let unioned = overlapping.reduce(box) { $0.union($1) }
                        regions[i].rect = owned.contains(regions[i].id)
                            ? unioned
                            : unioned.intersection(regions[i].rect.union(box))
                    } else {
                        regions[i].rect = regions[i].rect.union(box)
                    }
                } else {
                    regions[i].rect = updated
                }
                if regions[i].mediaHeld {
                    // No dead reckoning for a latched region, on match either:
                    // a face box sitting off-centre in a big player rect
                    // produces a persistent, meaningless "velocity" that the
                    // overlay's motion lead then extends the painted rect
                    // along, and that lead also ratchets the union. Measured
                    // on the live-run replay: max latched rect area
                    // 0.417 -> 0.362 (the media box itself is 0.360) and max
                    // painted area 0.748 -> 0.521, with zero effect on
                    // coverage. Matching still works via the center-distance
                    // fallback, whose reach is 2x the (large) rect.
                    regions[i].velocity = .zero
                }
                regions[i].missed = 0
                regions[i].peakConf = max(regions[i].peakConf, conf)
                unmatched.remove(at: j)
            } else {
                if regions[i].mediaHeld {
                    // Union-only also means no dead reckoning: coasting both
                    // moves and (after clamping) can shrink the latched rect.
                    regions[i].velocity = .zero
                    let overlapping = mediaBoxes.filter { $0.intersects(regions[i].rect) }
                    if !overlapping.isEmpty {
                        regions[i].rect = overlapping.dropFirst().reduce(overlapping[0]) {
                            $0.union($1)
                        }
                    }
                } else if regions[i].missed < clearAfter {
                    // Coast along velocity only through the normal hysteresis
                    // window. Beyond it (sticky hold), freeze: visual QA
                    // 2026-08-17 caught held boxes drifting off-content
                    // (id 22: x 0.44→0.21 over ~1 s) — "wandering black boxes".
                    regions[i].rect = predicted.intersection(
                        CGRect(x: 0, y: 0, width: 1, height: 1))
                    regions[i].velocity = CGVector(
                        dx: regions[i].velocity.dx * velocityDecay,
                        dy: regions[i].velocity.dy * velocityDecay)
                } else {
                    regions[i].velocity = .zero
                }
                if !frozen.contains(regions[i].id) { regions[i].missed += 1 }
            }
        }
        regions.removeAll { $0.missed >= holdFrames($0) || $0.rect.isEmpty }
        for entry in confirmedEntries(unmatched) {
            let born = TrackedRegion(
                id: nextId, rect: entry.rect, missed: 0, peakConf: entry.conf,
                mediaHeld: entry.media && !sustainedTranslation)
            regions.append(born)
            onBirth?(born, entry.source, entry.sourceIndex)
            nextId += 1
        }
        return regions
    }

    /// merge() for detections: union overlapping rects, keep max conf. The
    /// media flag ORs, so merging a media-expanded box into a plain one keeps
    /// the union held (over-block direction).
    ///
    /// Detection-count bound feeding this O(n²) loop (2026-08-21).
    /// The exporter embeds Core ML NMS with no top-k argument.
    /// That NMS has no cap to pass — CONFIRMED against the
    /// installed `coremltools.proto.NonMaximumSuppression` message (field
    /// dump, `model/.venv`): no max-output field exists on that message at
    /// all, only threshold/label/feature-name fields
    /// (`ultralytics/utils/export/coreml.py:118-128` sets exactly those).
    /// NMS here only removes overlapping duplicates; it never truncates the
    /// surviving count. The real structural cap is therefore the pre-NMS
    /// anchor grid, and for the live default model that is MEASURED, not
    /// inferred: loading `weights/640m.mlpackage`'s spec (`ct.utils.load_spec`,
    /// `model/.venv/bin/python`) shows the pipeline's first sub-model output
    /// as `(8400, 80)` confidence / `(8400, 4)` coordinates — 8,400 anchors,
    /// 80 padded class slots (real class count 18, padded to a multiple of
    /// 80 by `IOSDetectModel.forward`,
    /// `ultralytics/utils/export/coreml.py:42-44`). ASSUMED beyond that
    /// measured shape: with `pickTop.perClass = true` (coreml.py:127) the
    /// bound is on the anchor grid, not provably on total output rows across
    /// classes; in the pathological case of zero mutual IoU overlap, up to
    /// 8,400 per-class-surviving detections could reach `detect()` and feed
    /// this loop and the regions×unmatched match loop above (`update()`) in
    /// one frame — never observed on a screen-capture frame (a real frame's
    /// boxes overlap or the confidence gate thins them), but nothing in the
    /// graph forbids it. Remeasure the live per-frame detection-count
    /// distribution before trusting a tighter bound.
    private static func mergeDetections(
        _ detections: [Detection], sourceIndices: [Int]?, iouOver: CGFloat
    ) -> [Entry] {
        let validSourceIndices = sourceIndices?.count == detections.count ? sourceIndices : nil
        var merged = detections.enumerated().map { index, detection in
            Entry(
                rect: detection.box, conf: detection.confidence,
                media: detection.mediaExpanded, source: detection,
                sourceIndex: validSourceIndices?[index] ?? index)
        }
        var changed = true
        while changed {
            changed = false
            outer: for i in merged.indices {
                for j in merged.indices where j > i {
                    if Geometry.iou(merged[i].rect, merged[j].rect) > iouOver {
                        let left = merged[i]
                        let right = merged[j]
                        merged[i] = Entry(
                            rect: left.rect.union(right.rect),
                            conf: max(left.conf, right.conf),
                            media: left.media || right.media,
                            source: right.source.confidence > left.source.confidence
                                ? right.source : left.source,
                            sourceIndex: right.source.confidence > left.source.confidence
                                ? right.sourceIndex : left.sourceIndex)
                        merged.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return merged
    }

    func reset() {
        regions.removeAll()
        pending.removeAll()
    }

    /// Rects of regions currently latched to a media box. MotionBoxes uses
    /// these to suppress promoting fragments of an already-covered player
    /// (detect queue; read before update() in the same frame).
    var mediaHeldRects: [CGRect] {
        regions.filter(\.mediaHeld).map(\.rect)
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.origin.x + (b.origin.x - a.origin.x) * t,
            y: a.origin.y + (b.origin.y - a.origin.y) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t)
    }
}
