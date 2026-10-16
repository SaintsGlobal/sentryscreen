import CoreGraphics
import Foundation

/// Edge snap: turn a coarse motion-derived seed
/// rect into the EXACT media rect by pulling each of its four edges onto the
/// strongest straight image edge near it, measured on the full-res captured
/// frame (green channel of BGRA).
///
/// A rendered media element has a crisp rectangular boundary, so the media rect
/// is a real image edge; the heat bbox only ever gets within a cell or two of
/// it. Snapping is what makes the cover tight (tightness/edge-stddev budgets)
/// AND what makes interior changes — the player's control bar fading in and out
/// — invisible to the cover: the bar is 60 px inside the boundary, well past
/// the ±4-cell search window, so the bottom edge cannot see it.
///
/// Pure function of (rect, pixels, hot map). No state, no allocation beyond one
/// score buffer per edge. Media path only.
enum EdgeSnap {
    /// Per-edge decision trace for headless tuning runs. Off unless
    /// SENTRY_MEDIA_DEBUG is set in the environment; never on in production.
    static let debug = DevEnv.knob("SENTRY_MEDIA_DEBUG") != nil
    /// Frame counter for debug lines only.
    nonisolated(unsafe) static var debugFrame = 0

    /// Search radius per edge, in grid cells (spec §1.1: "within ±4 grid
    /// cells"). At the 160-cell grid on a 1280-wide frame that is ±32 px.
    /// It is also the rate limit on every edge move (MotionBoxes bounds growth
    /// by the same number), so a wrong edge can always be walked back at the
    /// same speed it was walked out.
    static let searchCells = 4

    /// Mean |Δgreen| across the edge span that counts as a real image edge.
    /// Receipt (scratch tool edgecal.py, 19 fixture frames x 4 edges, sampled
    /// across steady/controls/resize/drag/vanish-return): the true player
    /// boundary measures 29.5-136 (min 29.5, median 76), the background inside
    /// the ±4-cell window measures 0.85-6.3 (median 2.2), and the one place
    /// with NO boundary (the drag that ends 40% offscreen right, where the
    /// player edge is past the screen) measures 8.7-9.9. 15 sits 1.5x above
    /// that no-edge case and 2x below the weakest true edge, so the offscreen
    /// edge correctly keeps its seed instead of snapping to noise.
    static let minStrength = 15.0

    /// The band just inside a candidate edge must contain changing content:
    /// the media rect is the boundary of the CHANGING region, and this is what
    /// separates it from an ordinary static background edge that happens to
    /// sit within the search window. Receipt: without it, edgecal.py measured
    /// the desktop window title-bar edge at y=503 beating the true player
    /// bottom at y=455 on the 0.6x resize settle (+48 px, a 1.25x tightness
    /// miss that never recovers because the true edge then sits outside the
    /// next frame's search window); the band under 503 is static background,
    /// so the hot test rejects it. A failed test keeps the seed edge — the
    /// over-cover direction.
    static let minHotFraction = 0.25
    /// Depth of the "inside" band, in grid cells. One cell was too thin:
    /// measured (iter1-b) the two ways a real media edge has a QUIET first
    /// cell — the player's own outermost pixels can be a static border (the
    /// resize fixture's top edge, which then never snapped and sat 7 px out),
    /// and a control bar's flat area changes by ~7 levels/frame while it fades
    /// (the controls fixture's bottom edge, which jumped 9 px inward onto the
    /// bar's icon row). Two cells reach past both while still leaving the
    /// 48 px-away false edge that motivated the test entirely in background.
    static let hotBandCells = 2
    /// Preferred (strict) band depth: candidates whose FIRST cell inside is
    /// changing are considered before the looser hotBandCells pass runs at
    /// all. Receipt (iter2-b, steady): at acquisition the seed sits one cell
    /// outside the player, and the desktop title-bar edge 12 px below the
    /// player's bottom is nearer to that seed than the true boundary is — with
    /// a single 2-cell test it wins (it sees the player's last 4 px inside its
    /// band), parks the bottom edge 12 px out for the whole run and pushes
    /// painted area to 1.21x, over the 1.20x tightness budget. Its 1-cell band
    /// is pure background, so the strict pass rejects it and the true boundary
    /// wins; the loose pass still exists for boundaries whose own first cell
    /// is quiet.
    static let strictBandCells = 1
    /// Slack, in grid cells, between the recently-changing region and how far
    /// inward an edge may move (see `evidence`). One cell absorbs the grid
    /// quantization of that region's own bounding box; measured (iter3-d) at
    /// zero the drag and resize motion phases lose ~0.2x of area ratio and
    /// drag recovery goes from passing to 1.6 s, because every edge then
    /// tracks a cell-quantized bound instead of the image edge. While the
    /// media is
    /// MOVING the evidence also trails it — a vacated band keeps counting as
    /// changed for the whole evidence window — so the caller adds that trail
    /// (`evidenceLag`) on top; without it the bound sits outside the real
    /// boundary and the trailing edge of a drag can never tighten onto it
    /// (iter3-a: right edge frozen 25 px out for a whole 1.5 s drag with the
    /// bound 17 px outside the true edge).
    static let evidenceSlackCells = 1
    /// Most an edge may move INWARD in one update, in grid cells, on a box that
    /// is not moving. Outward moves are unrestricted (over-cover is the safe
    /// direction). 1 cell/frame = 8 px at the 160-cell grid on a 1280-wide
    /// frame, which bounds the cost of a single wrong inward decision to one
    /// cell — which the media box's one-cell publish margin already covers.
    static let inwardCellsPerUpdate = 1
    /// Most an edge may move inward in one update while the box is MOVING (see
    /// MotionBoxes.movingRecently). Receipt: the fastest per-edge inward motion
    /// any fixture scripts is the 0.6x resize shrink at 10.0 px/frame (measured
    /// on resize.truth.jsonl, peak at f375) = 1.25 cells, and at the 1-cell cap
    /// the snap found the correct pixel-exact edge every frame and was then
    /// clipped back to 8 px/frame — a 6-frame (200 ms) fitted lag on the right
    /// edge against a 150 ms budget (i3-g). 2 cells clears the measured rate by
    /// 60%. It does not widen the standing risk: what stops an edge moving
    /// inward past the media is the evidence bound, not this cap, and a box
    /// that is not moving keeps the 1-cell limit.
    static let movingInwardCellsPerUpdate = 2
    /// A candidate — including the seed's own position, which is what "hold
    /// where you are" means — must score at least this fraction of the
    /// STRONGEST qualifying candidate in the same search window. Nearest-to-seed
    /// decides between the survivors.
    ///
    /// Receipts (all measured in the debug trace of iter2-final's drag fixture,
    /// where the cover chased the player instead of riding it):
    ///   * f626 left: the player's boundary sits at x=400 scoring 99; a desktop
    ///     background edge at x=388 scores 41. Nearest took 388, and on f627
    ///     the seed at 388 still scored 42 so the hold guard kept it — the left
    ///     edge painted 0.0 px on 6 scored frames while truth moved 11-12 px,
    ///     and over-cover reached 118 px.
    ///   * f626 top: boundary at y=159 scores 77, the stale seed at y=157
    ///     scores 25. That is the 14-frame frozen top edge.
    ///   * drag settle (steady_edge_offset, 97 frames): the bottom edge held a
    ///     background gradient row measuring ~0.1x the player boundary, 28.7 px
    ///     below it.
    /// The false edges measure 0.25-0.45x the true boundary; the one measured
    /// case where a genuine competitor must survive is iteration-1's steady
    /// f659 (true boundary 117, desktop text line 79 = 0.68x, resolved by the
    /// evidence-consistency rule instead). 0.5 sits in the empty band between.
    static let dominanceFraction = 0.5
    /// Sample points along an edge for the hot test. 16 is enough to resolve
    /// the fraction against the 0.25 bar and costs 16 grid lookups per
    /// candidate.
    static let hotSamples = 16
    /// Every other pixel along the edge span. Halves the gradient cost; a
    /// straight boundary is by definition redundant along its length.
    static let spanStride = 2

    /// Returns `rect` with each edge snapped, in the same normalized
    /// bottom-left space. Any edge with no qualifying image edge in range keeps
    /// its seed position (fail toward over-cover, never under-cover).
    ///
    /// `changingNow(x, yTop)` answers "did the motion-grid cell containing this
    /// pixel change between the last two frames?", in TOP-LEFT pixel
    /// coordinates. Deliberately the raw per-frame change and never heat:
    /// heat's tail is the trail a moving player leaves behind, and it makes
    /// background edges outside the media rect look qualified (iter1-d: the
    /// resize left edge locked onto a desktop window border 84 px out).
    /// `evidence` is the bounding box of content that has changed in the last
    /// few frames — where the media demonstrably still is. It does two jobs
    /// that nothing else can do:
    ///
    ///  1. It is the span the per-edge tests measure ALONG. Measuring a left
    ///     edge down rows where the media is not present dilutes both the
    ///     gradient and the changing-content fraction by exactly the fraction
    ///     of the span that misses the media. Receipt (iter2-a, resize
    ///     shrink): with the box's own stale 412 px span around a 190 px
    ///     player, the true left edge scored 0.46x its real strength, fell
    ///     under the test bars, stopped tracking, left the ±4-cell window and
    ///     locked 84 px out for the rest of the run — and being stuck made the
    ///     span staler still.
    ///  2. It bounds how far INWARD any edge may move: never past the evidence
    ///     edge (plus evidenceSlackCells). This is what lets the cover tighten
    ///     onto a shrinking or dragging player while refusing to walk inward
    ///     onto interior video edges when the player's own border pixels go
    ///     quiet for a few frames. Receipts, both measured: keying that
    ///     decision on the heat map instead froze the resize shrink's top and
    ///     bottom edges for its whole 1 s (heat holds a vacated cell for
    ///     heatMax frames, so the edge still looked occupied); keying it on
    ///     the per-frame change instead walked the steady cover 8 px/frame
    ///     inward through a 9-frame quiet stretch in the video (uncovered
    ///     frames 44-52 of every player fixture).
    ///
    /// nil evidence means nothing has changed near this box at all: no inward
    /// movement is permitted and the box's own extents are used as the span.
    /// Updates the box must have been still before the exposed (under-cover)
    /// test may fire. The fresh grid is a this-frame-vs-last diff, so on the
    /// FIRST still update it still holds the residue of the box's final move —
    /// the whole window body reads fresh — and the test yanked all four edges
    /// out to the motion-smear evidence bbox (ipad-v2-flick4, 2026-08-19: the
    /// cover ballooned over the full window for 7.6 s at a drag-leg boundary).
    /// The residue is gone one update later by construction; 2 adds ~66 ms of
    /// latency to stranding recovery against an 8+ s defect.
    static let exposedStillUpdates = 2

    static func refine(
        _ rect: CGRect, evidence: CGRect?, evidenceLag: CGFloat = 0,
        moving: Bool = false, movedRecently: Bool = false,
        stillUpdates: Int = Int.max,
        pixels: UnsafePointer<UInt8>, width: Int, height: Int,
        bytesPerRow: Int, cellPx: Int,
        changingNow: (Int, Int) -> Bool
    ) -> CGRect {
        let w = CGFloat(width)
        let h = CGFloat(height)
        var left = clampInt(Int((rect.minX * w).rounded()), 0, width)
        var right = clampInt(Int((rect.maxX * w).rounded()), 0, width)
        var top = clampInt(Int(((1 - rect.maxY) * h).rounded()), 0, height)
        var bottom = clampInt(Int(((1 - rect.minY) * h).rounded()), 0, height)
        // Too small to have four distinct edges (or degenerate after clamping):
        // nothing to snap to.
        guard right - left >= 2 * cellPx, bottom - top >= 2 * cellPx else {
            return rect
        }

        // Test extents (see `evidence`), clamped into the seed rect so
        // evidence larger than the box cannot drag the tests off the media.
        let span = evidence ?? rect
        var spanTop = clampInt(Int(((1 - span.maxY) * h).rounded()), top, bottom)
        var spanBottom = clampInt(Int(((1 - span.minY) * h).rounded()), top, bottom)
        var spanLeft = clampInt(Int((span.minX * w).rounded()), left, right)
        var spanRight = clampInt(Int((span.maxX * w).rounded()), left, right)
        if spanBottom - spanTop < cellPx {
            spanTop = top
            spanBottom = bottom
        }
        if spanRight - spanLeft < cellPx {
            spanLeft = left
            spanRight = right
        }

        let radius = searchCells * cellPx
        let half = max(1, cellPx / 2)

        func green(_ x: Int, _ y: Int) -> Int { Int(pixels[y * bytesPerRow + x * 4 + 1]) }

        // Vertical edge at column c: the discontinuity between pixel columns
        // c-1 and c. The same definition for both sides makes `left` the first
        // interior column and `right` the first exterior one, i.e. exactly the
        // half-open rect the seed already is.
        func columnScore(_ c: Int) -> Double {
            var total = 0
            var count = 0
            var y = spanTop
            while y < spanBottom {
                total += abs(green(c, y) - green(c - 1, y))
                count += 1
                y += spanStride
            }
            return count > 0 ? Double(total) / Double(count) : 0
        }
        func rowScore(_ r: Int) -> Double {
            var total = 0
            var count = 0
            var x = spanLeft
            while x < spanRight {
                total += abs(green(x, r) - green(x, r - 1))
                count += 1
                x += spanStride
            }
            return count > 0 ? Double(total) / Double(count) : 0
        }
        /// Fraction of sample points along the edge that have changing content
        /// somewhere in the `hotBandCells` band just inside the candidate.
        /// `sign` is +1 when "inside" means increasing coordinate.
        func hotFractionColumn(
            _ c: Int, sign: Int, bands: Int = hotBandCells, _ test: (Int, Int) -> Bool
        ) -> Double {
            var hits = 0
            for i in 0..<hotSamples {
                let y = clampInt(spanTop + (spanBottom - spanTop) * i / hotSamples, 0, height - 1)
                for band in 0..<bands where test(
                    clampInt(c + sign * (band * cellPx + half), 0, width - 1), y) {
                    hits += 1
                    break
                }
            }
            return Double(hits) / Double(hotSamples)
        }
        func hotFractionRow(
            _ r: Int, sign: Int, bands: Int = hotBandCells, _ test: (Int, Int) -> Bool
        ) -> Double {
            var hits = 0
            for i in 0..<hotSamples {
                let x = clampInt(spanLeft + (spanRight - spanLeft) * i / hotSamples, 0, width - 1)
                for band in 0..<bands where test(
                    x, clampInt(r + sign * (band * cellPx + half), 0, height - 1)) {
                    hits += 1
                    break
                }
            }
            return Double(hits) / Double(hotSamples)
        }

        // How far inward each edge may go: the evidence edge plus slack, or
        // the seed itself when there is no evidence (freeze).
        let slack = evidenceSlackCells * cellPx + Int(evidenceLag.rounded())
        let inLeft = evidence.map { clampInt(Int(($0.minX * w).rounded()) + slack, 0, width) } ?? left
        let inRight = evidence.map {
            clampInt(Int(($0.maxX * w).rounded()) - slack, 0, width)
        } ?? right
        let inTop = evidence.map {
            clampInt(Int(((1 - $0.maxY) * h).rounded()) + slack, 0, height)
        } ?? top
        let inBottom = evidence.map {
            clampInt(Int(((1 - $0.minY) * h).rounded()) - slack, 0, height)
        } ?? bottom

        // Where the evidence says each edge of the media actually is, with NO
        // slack: the evidence rect is the bounding box of cells that changed
        // recently, quantized to the cell grid, so its bound always sits at or
        // OUTSIDE the true boundary (the boundary falls inside the outermost
        // changed cell). A snap candidate further out than this is therefore
        // background, not media — see `pick`'s outwardBound.
        let evLeft = evidence.map { clampInt(Int(($0.minX * w).rounded()), 0, width) }
        let evRight = evidence.map { clampInt(Int(($0.maxX * w).rounded()), 0, width) }
        let evTop = evidence.map { clampInt(Int(((1 - $0.maxY) * h).rounded()), 0, height) }
        let evBottom = evidence.map { clampInt(Int(((1 - $0.minY) * h).rounded()), 0, height) }
        // An edge is STALE when it sits more than the snap's own reach outside
        // where the evidence says the media is: the media has moved or shrunk
        // out from under it and no single snap step can catch up (spec item 5).
        func stale(_ seed: Int, _ bound: Int?, _ inwardSign: Int) -> Bool {
            guard let bound else { return false }
            return (seed - bound) * inwardSign < -radius
        }
        let staleEdges = [
            stale(left, evLeft, 1), stale(right, evRight, -1),
            stale(top, evTop, 1), stale(bottom, evBottom, -1),
        ].filter { $0 }.count
        // Converge only when at least TWO edges are stale. Receipt, the two
        // fixtures that pull in opposite directions:
        //   * resize 0.6x shrink — left, right and bottom all end up 34, 49
        //     and 113 px outside the evidence; the media really did shrink and
        //     every stale edge must converge (iteration-1: the bottom held its
        //     pre-shrink position for 3.3 s and then popped 115 px).
        //   * controls — the player's own bottom 60 px is a static control bar
        //     for 78 frames at a time, so the bottom edge alone reads as 60 px
        //     (7.5 cells) outside the evidence while the media has not moved.
        //     Converging it would walk the cover onto the bar's top edge and
        //     uncover the player, the exact failure the hold guard was added
        //     for. Only its bottom is stale, so it holds.
        // A geometry change moves at least two edges; an interior band going
        // still shortens the evidence on one side only. A single-edge resize
        // (dragging one window border) therefore over-covers until the box
        // re-acquires — the safe direction, and a live watch item.
        // ...EXCEPT while the box is `moving` (MotionBoxes.movingRecently: its
        // own rect changed by a cell within the last second). Motion is the
        // other way one edge alone goes stale, and it has no controls-style
        // false positive because a static player cannot move the box. Receipt
        // (i3-d, drag 3, which ends with the player 40% offscreen): at f633 the
        // top edge snapped to a desktop card edge that the descending player
        // was passing over, so it qualified that frame; the player then left it
        // behind and the edge — a genuine strong image edge, score rising 45 ->
        // 109 as the player cleared it — held 135 px above the settled player
        // for the rest of the run (96 steady_edge_offset violations). Only that
        // one edge was stale, so the two-edge rule never opened.
        // Once started, convergence LATCHES until every edge is back within a
        // cell of its evidence bound. Receipt (iter2-a, resize): stopping the
        // moment no edge is more than the 4-cell reach out left all four edges
        // parked 13-19 px outside the shrunk player on the first background
        // edge they met — steady tightness 53% of frames within 1.20x (needs
        // 95%) and recovery never completed. The last stretch is exactly where
        // the hold guard has to stay open for the true boundary to win.
        let converge = staleEdges >= 2 || (movedRecently && staleEdges >= 1)
        // The MIRROR of stale: an edge more than one cell INSIDE its evidence
        // bound, with FRESH (per-frame, not heat-trail) content in the band
        // just OUTSIDE it, is wrong in the UNDER-cover direction — live media
        // is changing beyond the cover's edge right now. stale() cannot see
        // this (it only measures the over-cover side), and the hold guard
        // actively preserves it: the stranded edge sits on strong video-
        // interior edges with hot content inside, so it reads as anchored
        // forever. Receipt:
        // after the S2 flick the trailing edge froze 239 px inside
        // the player for 3.5 s and the pin adopted the collapse; reproduced
        // on the iPad 3/4 runs (ipad-fix-flick2/3/4, 2026-08-19) as a static
        // exposed strip lasting 8+ s to end of run. Requiring FRESH outside
        // (changingNow, not heat) keeps a flick's decaying heat trail from
        // opening this path onto background; requiring the evidence bound
        // outside by > one cell ties it to what the box tracker already
        // believes. Exposure is the one direction the spec never allows, so
        // this opens per-edge without the two-stale-edge quorum.
        // `!moving` gate: while the box is moving, the band outside a CORRECT
        // edge is full of freshly-changed background (the player just passed
        // over it), so this test cannot distinguish stranding from ordinary
        // motion lag there — and firing it mid-motion yanked well-placed edges
        // out to the evidence bound (first gate run of this change: drag-media
        // coverage 100 -> 99.28, motion_smoothness p95 1.0 -> 1.375). Motion
        // lag already has its own machinery (rigid translate + the moving
        // gate); stranding is by definition a post-motion state — the box
        // reads still while the strip stays exposed.
        func exposed(
            _ seed: Int, _ bound: Int?, _ inwardSign: Int, _ freshOutside: () -> Bool
        ) -> Bool {
            guard !moving, stillUpdates >= Self.exposedStillUpdates, let bound
            else { return false }
            return (seed - bound) * inwardSign > cellPx && freshOutside()
        }
        let exposedLeft = exposed(left, evLeft, 1) {
            hotFractionColumn(left, sign: -1, changingNow) >= minHotFraction
        }
        let exposedRight = exposed(right, evRight, -1) {
            hotFractionColumn(right, sign: 1, changingNow) >= minHotFraction
        }
        let exposedTop = exposed(top, evTop, 1) {
            hotFractionRow(top, sign: -1, changingNow) >= minHotFraction
        }
        let exposedBottom = exposed(bottom, evBottom, -1) {
            hotFractionRow(bottom, sign: 1, changingNow) >= minHotFraction
        }
        // An exposed edge searches OUTWARD only (inwardBound = its own seed):
        // the window between the seed and the evidence bound is where the true
        // boundary is, and video-interior edges inside the seed must not win
        // nearest-to-seed while the cover is short.
        let foundLeft = pick(
            seed: left, radius: radius, limit: width - 1, score: columnScore,
            focus: evLeft, inwardBound: exposedLeft ? left : max(left, inLeft), inwardSign: 1,
            outwardBound: evLeft, cellPx: cellPx, moving: moving,
            converge: (converge && stale(left, evLeft, 1)) || exposedLeft,
            strictHotOK: { hotFractionColumn($0, sign: 1, bands: strictBandCells, changingNow)
                >= minHotFraction },
            looseHotOK: { hotFractionColumn($0, sign: 1, changingNow) >= minHotFraction })
        let foundRight = pick(
            seed: right, radius: radius, limit: width - 1, score: columnScore,
            focus: evRight, inwardBound: exposedRight ? right : min(right, inRight),
            inwardSign: -1,
            outwardBound: evRight, cellPx: cellPx, moving: moving,
            converge: (converge && stale(right, evRight, -1)) || exposedRight,
            strictHotOK: { hotFractionColumn($0, sign: -1, bands: strictBandCells, changingNow)
                >= minHotFraction },
            looseHotOK: { hotFractionColumn($0, sign: -1, changingNow) >= minHotFraction })
        let foundTop = pick(
            seed: top, radius: radius, limit: height - 1, score: rowScore,
            focus: evTop, inwardBound: exposedTop ? top : max(top, inTop), inwardSign: 1,
            outwardBound: evTop, cellPx: cellPx, moving: moving,
            converge: (converge && stale(top, evTop, 1)) || exposedTop,
            strictHotOK: { hotFractionRow($0, sign: 1, bands: strictBandCells, changingNow)
                >= minHotFraction },
            looseHotOK: { hotFractionRow($0, sign: 1, changingNow) >= minHotFraction })
        let foundBottom = pick(
            seed: bottom, radius: radius, limit: height - 1, score: rowScore,
            focus: evBottom, inwardBound: exposedBottom ? bottom : min(bottom, inBottom),
            inwardSign: -1,
            outwardBound: evBottom, cellPx: cellPx, moving: moving,
            converge: (converge && stale(bottom, evBottom, -1)) || exposedBottom,
            strictHotOK: { hotFractionRow($0, sign: -1, bands: strictBandCells, changingNow)
                >= minHotFraction },
            looseHotOK: { hotFractionRow($0, sign: -1, changingNow) >= minHotFraction })
        // Inward moves are rate-limited (see inwardCellsPerUpdate); outward
        // moves are not. An edge with no qualifying image edge in range holds
        // still — it is NOT dragged toward the evidence bound. Receipt
        // (iter3-b): pulling unanchored edges toward the evidence at 1
        // cell/update fixed stranding but uncovered the player whenever the
        // video went quiet and the evidence bbox shrank inside it — steady
        // coverage 99.2% -> 49%. Stranding is recovered at the box level
        // instead (MotionBoxes re-anchor), where the decision can be made on
        // several frames of evidence rather than one.
        let inwardLimit = (moving ? movingInwardCellsPerUpdate : inwardCellsPerUpdate) * cellPx
        let newLeft = min(foundLeft.position, left + inwardLimit)
        let newRight = max(foundRight.position, right - inwardLimit)
        let newTop = min(foundTop.position, top + inwardLimit)
        let newBottom = max(foundBottom.position, bottom - inwardLimit)

        // A pair that crossed or collapsed means the snap disagreed with
        // itself; keep the seed pair rather than paint a sliver.
        if debug {
            func tag(_ name: String, _ seed: Int, _ found: (position: Int, anchored: Bool),
                     _ score: Double, _ bound: Int, _ hotNow: Double) -> String {
                String(format: "%@ %d->%d s%.0f in<=%d fresh=%.2f anch=%@",
                    name, seed, found.position, score, bound, hotNow,
                    found.anchored ? "Y" : "n")
            }
            print("snap f\(debugFrame) span=[\(spanLeft),\(spanRight)]x[\(spanTop),\(spanBottom)] "
                + tag("L", left, foundLeft, columnScore(left), inLeft,
                      hotFractionColumn(left, sign: 1, changingNow))
                + " " + tag("R", right, foundRight, columnScore(right), inRight,
                      hotFractionColumn(right, sign: -1, changingNow))
                + " " + tag("T", top, foundTop, rowScore(top), inTop,
                      hotFractionRow(top, sign: 1, changingNow))
                + " " + tag("B", bottom, foundBottom, rowScore(bottom), inBottom,
                      hotFractionRow(bottom, sign: -1, changingNow)))
        }
        if newRight - newLeft >= cellPx {
            left = newLeft
            right = newRight
        }
        if newBottom - newTop >= cellPx {
            top = newTop
            bottom = newBottom
        }
        return CGRect(
            x: CGFloat(left) / w, y: 1 - CGFloat(bottom) / h,
            width: CGFloat(right - left) / w, height: CGFloat(bottom - top) / h)
    }

    /// How far outward the acquisition snap looks for the media boundary, in
    /// grid cells. Receipt (scratch probe diag/probe0.py over frame 0 of
    /// steady/controls/drag/resize): the face detection box sits 133 px inside
    /// the player's left edge on steady and drag — the largest gap any fixture
    /// has — so 20 cells = 160 px covers it with 20% margin. Larger windows
    /// cost linearly and reach further into the desktop.
    static let acquireCells = 20
    /// Pad added to a detection edge when the acquisition snap finds no
    /// qualifying image edge on that side (spec item 4). One cell: the same
    /// unit every other bound here is expressed in, and enough that a
    /// pixel-exact detection box does not paint flush against content.
    static let acquirePadCells = 1
    /// Half-width, in grid cells, of the LOCAL ANCHOR window the acquisition
    /// scan checks before it walks outward — the acquisition twin of `pick`'s
    /// ±1-cell rule, and for the same reason: a seed that is already within a
    /// cell of a real image edge is ON that edge, whichever side of it the
    /// seed happens to have landed.
    ///
    /// Receipt (i3-final, vanish-return f420, the re-acquisition latch): the
    /// returning player's detection box is [1026,1234]x[347,458] and the
    /// player's top boundary is row 350 — the detection pokes 3 px ABOVE the
    /// media. The outward-only scan therefore starts already past the
    /// boundary, never sees it, and takes the first qualifying edge it does
    /// meet: a background desktop-window row (strength 109.4) at row 318, 32 px
    /// further out. Published, that parked the top edge 44.0 px above truth,
    /// byte-identical, for 33 frames (f420-f452) until the box promoted and
    /// `MotionBoxes.adopt`'s adoptSlackCells guard threw the same measurement
    /// out — 24.85 px outside the scorer's acquisition_settle band. Cold start
    /// (f0) never hit it because the detection there sits well inside the
    /// player on every side.
    ///
    /// One cell, not more: it is the detection's own placement error that has
    /// to be absorbed (3 px measured here), and the window is searched for the
    /// STRONGEST qualifying edge, so widening it starts letting a strong
    /// background edge outrank a boundary the seed is genuinely inside of.
    /// Cost when the window fires wrongly — an interior edge within a cell of
    /// the detection — is bounded: `updateProvisional` unions the acquired rect
    /// back with the detection, so the side can never end up inside the
    /// detection, and the result is the same as the no-qualifying-edge
    /// fallback.
    static let acquireLocalCells = 1

    /// Acquisition snap: given a blocked
    /// detection that is demonstrably INSIDE some media element, find the
    /// element's rectangle on this single frame by walking each side outward
    /// to the first real image edge. No motion evidence is required, which is
    /// the whole point — it runs on the first blocked detection of an
    /// appearance, before any box can have promoted, and kills iteration-1's
    /// 15-frame cold start and 33-frame re-acquisition hole.
    ///
    /// NEAREST going outward, not strongest and not outermost. Measured on
    /// frame 0 of every player fixture (diag/probe0.py): scanning outward from
    /// the detection box with the edge score taken over the detection's own
    /// span, the FIRST local maximum at or above minStrength is the player
    /// boundary on all four sides of all four fixtures (left/right/top have
    /// exactly one qualifying candidate; the bottom has 6-11 because a desktop
    /// window with text lines sits directly below the player, and the nearest
    /// of them IS the boundary). Interior video edges do not qualify: they are
    /// not straight lines across the detection's span, so their score averages
    /// under 15. Strongest would take a desktop text line (up to 161 vs the
    /// boundary's 88-105); outermost would take the far side of the desktop
    /// window.
    ///
    /// A side with no qualifying edge falls back to the detection edge plus
    /// `acquirePadCells` — under-block on that side, bounded by the detection
    /// itself always being covered, and corrected at promotion.
    struct Acquired {
        var rect: CGRect
        /// Per side (left, right, top, bottom): this edge landed on a real
        /// image edge rather than the detection-plus-pad fallback, so it is a
        /// pixel-exact measurement of the media boundary and worth more than
        /// the cell-quantized heat bbox that later promotes.
        var anchored: [Bool] = [false, false, false, false]
    }

    static func acquire(
        detection: CGRect,
        pixels: UnsafePointer<UInt8>, width: Int, height: Int,
        bytesPerRow: Int, cellPx: Int
    ) -> Acquired {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let left = clampInt(Int((detection.minX * w).rounded()), 0, width - 1)
        let right = clampInt(Int((detection.maxX * w).rounded()), 1, width - 1)
        let top = clampInt(Int(((1 - detection.maxY) * h).rounded()), 1, height - 1)
        let bottom = clampInt(Int(((1 - detection.minY) * h).rounded()), 1, height - 1)
        guard right > left, bottom > top else { return Acquired(rect: detection) }
        let reach = acquireCells * cellPx
        let pad = acquirePadCells * cellPx

        func green(_ x: Int, _ y: Int) -> Int { Int(pixels[y * bytesPerRow + x * 4 + 1]) }
        func columnScore(_ c: Int) -> Double {
            var total = 0, count = 0, y = top
            while y < bottom {
                total += abs(green(c, y) - green(c - 1, y))
                count += 1
                y += spanStride
            }
            return count > 0 ? Double(total) / Double(count) : 0
        }
        func rowScore(_ r: Int) -> Double {
            var total = 0, count = 0, x = left
            while x < right {
                total += abs(green(x, r) - green(x, r - 1))
                count += 1
                x += spanStride
            }
            return count > 0 ? Double(total) / Double(count) : 0
        }
        /// The strongest qualifying image edge within `acquireLocalCells` of
        /// the seed, on EITHER side of it. See acquireLocalCells for why the
        /// inward side has to be in range.
        func localAnchor(_ seed: Int, limit: Int, score: (Int) -> Double) -> Int? {
            let span = acquireLocalCells * cellPx
            let lo = max(1, seed - span)
            let hi = min(limit, seed + span)
            guard lo <= hi else { return nil }
            var scores = [Double](repeating: 0, count: hi - lo + 1)
            for p in lo...hi { scores[p - lo] = score(p) }
            var best: Int?
            for p in lo...hi {
                let s = scores[p - lo]
                guard s >= minStrength else { continue }
                if p > lo, scores[p - lo - 1] > s { continue }
                if p < hi, scores[p - lo + 1] > s { continue }
                if best == nil || s > scores[best! - lo] { best = p }
            }
            return best
        }
        /// Walks outward from `seed` and returns the first local maximum at or
        /// above minStrength, or `seed + outward * pad` when there is none.
        var anchored = [false, false, false, false]
        func outward(
            _ slot: Int, _ seed: Int, step: Int, limit: Int, score: (Int) -> Double
        ) -> Int {
            if let local = localAnchor(seed, limit: limit, score: score) {
                anchored[slot] = true
                return local
            }
            var scanned: [Double] = []
            var positions: [Int] = []
            var p = seed
            var travelled = 0
            while travelled <= reach, p >= 1, p <= limit {
                positions.append(p)
                scanned.append(score(p))
                p += step
                travelled += 1
            }
            for i in scanned.indices {
                guard scanned[i] >= minStrength else { continue }
                if i > 0 && scanned[i - 1] > scanned[i] { continue }
                if i < scanned.count - 1 && scanned[i + 1] > scanned[i] { continue }
                anchored[slot] = true
                return positions[i]
            }
            return clampInt(seed + step * pad, 0, limit)
        }

        let l = outward(0, left, step: -1, limit: width - 1, score: columnScore)
        let r = outward(1, right, step: 1, limit: width - 1, score: columnScore)
        let t = outward(2, top, step: -1, limit: height - 1, score: rowScore)
        let b = outward(3, bottom, step: 1, limit: height - 1, score: rowScore)
        guard r > l, b > t else { return Acquired(rect: detection) }
        if debug {
            print("acquire f\(debugFrame) det=[\(left),\(right)]x[\(top),\(bottom)] "
                + "-> [\(l),\(r)]x[\(t),\(b)]")
        }
        return Acquired(
            rect: CGRect(
                x: CGFloat(l) / w, y: 1 - CGFloat(b) / h,
                width: CGFloat(r - l) / w, height: CGFloat(b - t) / h),
            anchored: anchored)
    }

    /// One edge decision: the qualifying image edge NEAREST the seed, with
    /// inward movement bounded by the evidence (see `refine`) and by
    /// `inwardCellsPerUpdate`. `inwardSign` is +1 when inward means increasing
    /// coordinate; `inwardBound` is the innermost position allowed.
    ///
    /// Nearest — not strongest, not outermost. Receipts (edgecal.py 672 seeded
    /// trials, then end to end): strongest picks a background edge up to 48 px
    /// away and lands inside the truth rect on 8 of 672 trials; outermost lets
    /// the motion trail hold a trailing edge back a few px every frame until
    /// the true edge leaves the search window (drag, iter1-e: 300 px behind).
    ///
    /// A candidate always needs a real image edge (minStrength), a local
    /// maximum, and content changing NOW just inside it — first with the
    /// strict one-cell band, then, only if nothing qualifies, with the looser
    /// hotBandCells band.
    ///
    /// Returns the seed unchanged and anchored=false when nothing qualifies.
    private static func pick(
        seed: Int, radius: Int, limit: Int, score: (Int) -> Double,
        focus: Int?, inwardBound: Int, inwardSign: Int,
        outwardBound: Int?, cellPx: Int, moving: Bool, converge: Bool,
        strictHotOK: (Int) -> Bool, looseHotOK: (Int) -> Bool
    ) -> (position: Int, anchored: Bool) {
        // An edge still sitting on a real image edge HOLDS. No motion
        // evidence moves it inward, because no motion evidence can tell "the
        // media is still here but has gone still" from "the media has left":
        // the controls fixture's player parks a static control bar over its
        // own bottom 60 px for 78 frames at a time, and every change-based
        // rule tried (per-frame, 3-frame, full heat window) eventually reads
        // that as empty and walks the cover 49 px up onto the bar's own top
        // edge — uncovering the player on ~100 frames per run. Holding is the
        // over-cover direction, which is the one the spec allows; when the
        // media really has left, the edge stops being an image edge (measured:
        // seed score drops from 60-100 to 0-9 within a frame of the boundary
        // moving off it) and this guard opens by itself. The residual risk —
        // an edge parked on a background edge that coincides — is recovered at
        // the box level (MotionBoxes re-anchor).
        // LOCAL ANCHOR. An edge within one cell of a real image edge takes it
        // — the STRONGEST one in that ±1 cell window — and then holds there.
        // No motion test: a one-cell move cannot cost more coverage than the
        // media box's own one-cell publish margin already provides, and the
        // alternative is worse in both directions. Receipts, iteration-1 and
        // iter2-g:
        //   * controls — the box's bottom seed lands on the cell boundary at
        //     512 px while the player's boundary is at 515. Three pixels off an
        //     image edge, the old "score(seed) >= minStrength" hold never
        //     fired, and with the control bar opaque the only candidate that
        //     passes the changing-content test is the BAR'S top edge 60 px
        //     inside. The bottom then walked up a cell per update for the 78
        //     frames the bar is static and snapped back when it faded: 4.95
        //     cells of bottom-edge excursion against a 2.0 budget, and 14
        //     frames with the bottom of the player uncovered.
        //   * steady frame 659 — after a box re-acquisition the seed sat at
        //     520 with the true boundary at 515 (score 117) and a desktop
        //     text-line edge at 524 (score 79). Nearest-to-seed took 524 and
        //     the hold kept the bottom 9.4 px below the player for the rest of
        //     the run; strongest-within-a-cell takes 515.
        // `converge` (spec item 5) is the one thing that opens this guard: the
        // evidence says the media is more than a full snap reach inside this
        // edge AND at least one other edge agrees, so whatever image edge the
        // seed is on is background the media used to cover (the resize shrink's
        // bottom sat on a desktop text line, score 105-107, for 3.3 s).
        // Holding is not a free pass: an edge that has been left behind by a
        // moving player still sits on SOMETHING (the background it uncovered,
        // or the ghost of the boundary), and the trace above shows that
        // something scoring 25-42 while the real boundary two cells away scores
        // 77-99. So the seed holds only while it is the DOMINANT edge in the
        // window (see dominanceFraction) — which is the "score collapse at its
        // own position" test the spec's iteration-3 resize-onset item asks for,
        // stated relative to the alternatives rather than to an absolute floor.
        // The window scan below therefore runs on every update, hold or not.
        let seedScore = score(seed)
        // The window covers the seed AND where the evidence says this edge of
        // the media now is (`focus`). Searching only around the seed strands
        // an edge for good the moment it misses a couple of frames: the media
        // walks out of its ±4-cell window and no image edge is ever in range
        // again (iter3-a, drag: the leading edge froze 200 px behind after two
        // frames where nothing qualified). Preference stays NEAREST THE SEED,
        // so covering more ground costs stability nothing.
        let center = focus ?? seed
        var lo = max(1, min(seed, center) - radius)
        var hi = min(limit, max(seed, center) + radius)
        if inwardSign > 0 { hi = min(hi, inwardBound) } else { lo = max(lo, inwardBound) }
        guard lo <= hi else { return (seed, !converge && seedScore >= minStrength) }
        var scores = [Double](repeating: 0, count: hi - lo + 1)
        for p in lo...hi { scores[p - lo] = score(p) }

        // Evidence-consistent candidates only, on the first pass (spec item 6).
        // The evidence bound sits at or outside the true boundary by
        // construction, so a candidate further out is background. Receipt
        // (iteration-1 steady, frame 659, box re-acquisition): the seed landed
        // one cell outside the player, and of the two qualifying candidates —
        // the true boundary at 515 (score 117) and a desktop text-line edge at
        // 524 (score 79, 4 px outside the evidence bound) — "nearest to the
        // seed" chose 524 by a single pixel, and the hold guard then kept the
        // bottom edge 9.4 px below the player for the rest of the run.
        func qualifying(_ hotOK: (Int) -> Bool, evidenceConsistent: Bool) -> [Int] {
            var out: [Int] = []
            for p in lo...hi {
                let s = scores[p - lo]
                guard s >= minStrength else { continue }
                // Local maximum only: the 1-2 px shoulder of a strong boundary
                // (codec ringing) must not out-rank the boundary itself.
                if p > lo && scores[p - lo - 1] > s { continue }
                if p < hi && scores[p - lo + 1] > s { continue }
                if evidenceConsistent, let outwardBound,
                    (p - outwardBound) * inwardSign < 0 { continue }
                guard hotOK(p) else { continue }
                out.append(p)
            }
            return out
        }
        var pool = qualifying(strictHotOK, evidenceConsistent: true)
        if pool.isEmpty { pool = qualifying(looseHotOK, evidenceConsistent: true) }
        if pool.isEmpty, outwardBound != nil {
            pool = qualifying(strictHotOK, evidenceConsistent: false)
            if pool.isEmpty { pool = qualifying(looseHotOK, evidenceConsistent: false) }
        }
        // Weak candidates lose to the strongest edge in the same window, seed
        // included; nearest-to-seed decides among what is left.
        let strongest = pool.reduce(0.0) { max($0, scores[$1 - lo]) }
        // While the box is MOVING, holding also requires what every candidate
        // requires: content changing just inside. A still player's own boundary
        // can go quiet behind a static control bar (the whole reason the hold
        // exists), but a MOVING player cannot — the media is by definition
        // changing everywhere it still is. Receipt (i3-e, resize 0.6x shrink):
        // the bottom edge sat on a real background edge at y=560 scoring 50-67
        // with fresh=0.00 just inside while the player shrank away from it, and
        // held for 13 frames (f362-f374) before jumping 56 px — 200 ms of the
        // 150 ms motion_lag budget, and the freeze-then-pop the spec's
        // resize-onset item is about. The evidence bound could not catch it:
        // the heat trail keeps a just-vacated band looking occupied, so the
        // edge never scored as stale.
        let seedIsEdge = seedScore >= minStrength
            && seedScore >= Self.dominanceFraction * strongest
        if !converge, seedIsEdge, !moving || looseHotOK(seed) {
            return (seed, true)
        }
        var best: Int?
        for p in pool where scores[p - lo] >= Self.dominanceFraction * strongest {
            if best == nil || abs(p - seed) < abs(best! - seed) { best = p }
        }
        // The moving-gate above opens the hold INWARD only. An edge the media
        // has moved away from needs to come IN; sending it further OUT — onto
        // whatever the evidence-inconsistent fallback pass found — is never the
        // answer, and the gate opens on exactly the frames where the content
        // just inside a real boundary happens to be quiet. Receipt (i3-f, the
        // settle after drag 1): the bottom edge, sitting on the true boundary,
        // jumped 12.24 px out and back three times in 16 frames on pixel-static
        // truth — 3 steady_stillness cycles against a limit of 0.
        if !converge, seedIsEdge, let b = best, (b - seed) * inwardSign < 0 {
            return (seed, true)
        }
        // Spec item 5, second half: a stale edge with nothing to anchor to
        // still has to come back. It walks toward the evidence bound at the
        // same one-cell-per-update rate the caller rate-limits every inward
        // move to, so recovery is a settle and never a pop. Only reachable
        // under `converge`, which needs two stale edges — the guard that keeps
        // a quiet video's shrinking evidence bbox from pulling the cover off
        // the player (iteration-1 iter3-b: steady coverage 99.2% -> 49%).
        if best == nil, converge, let outwardBound {
            // Walk TOWARD the evidence bound, whichever side of the seed it is
            // on. The bound is inward for a stale (over-cover) edge — there
            // `dir == inwardSign` and this is byte-for-byte the old walk — but
            // OUTWARD for an exposed (under-cover) edge, and hard-coding
            // inwardSign here is exactly the wrong-direction reversal walk
            // Diagnosis 2 recorded (the stranded left edge walked OUT at
            // 1 cell/update, then this line pulled it back IN, decelerating,
            // to the 3.5 s freeze).
            let dir = (outwardBound - seed).signum()
            best = seed + dir * min(
                abs(outwardBound - seed), inwardCellsPerUpdate * cellPx)
        }
        if debug {
            var parts: [String] = []
            for p in lo...hi where scores[p - lo] >= minStrength {
                if p > lo && scores[p - lo - 1] > scores[p - lo] { continue }
                if p < hi && scores[p - lo + 1] > scores[p - lo] { continue }
                parts.append(String(format: "%d(s%.0f %@%@)", p, scores[p - lo],
                    strictHotOK(p) ? "S" : "-", looseHotOK(p) ? "L" : "-"))
            }
            print("pick f\(debugFrame) seed=\(seed) range=[\(lo),\(hi)] inB=\(inwardBound) "
                + "outB=\(outwardBound.map(String.init) ?? "-") conv=\(converge) -> "
                + "\(best.map(String.init) ?? "none") cands: \(parts.joined(separator: " "))")
        }
        return (best ?? seed, best != nil)
    }

    private static func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(v, lo), hi)
    }
}
