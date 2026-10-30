import AppKit
import QuartzCore

/// Overlay rendering (SPEC §5.5, revised): ONE persistent full-screen
/// click-through NSWindow hosting a black CALayer per tracked region.
///
/// Why not one NSWindow per region (previous design): during scroll the
/// tracker churns region ids, and every id churn created a brand-new NSWindow
/// and destroyed the old one. NSWindow creation allocates a window server
/// surface whose first paint is not synchronized with the death of the old
/// window, which the user saw as flashing and momentary show-through. With a
/// single persistent window, per-region layers appear, move, and disappear
/// inside one CATransaction — the compositor applies the whole frame
/// atomically, so a replacement layer is guaranteed to be up in the same
/// display frame its predecessor goes away (or earlier: see linger).
///
/// The persistent window also fixes a capture-exclusion race (invariant 3):
/// the window is created and excluded from capture on the FIRST sync (before
/// any region ever paints), and its windowNumber never changes afterwards, so
/// exclusion is set up exactly once instead of racing window churn.
///
/// Main thread only.
final class OverlayManager {
    // Tripwire (SPEC §8.1): normal pages yield a handful of regions; more
    // than 20 means a runaway tracker bug. Fail loudly, stop spawning.
    // (Receipt unchanged from the per-window design; the cap now counts
    // region layers, including lingering ones.)
    // Receipt updated 2026-08-17: nav-test (--block-faces, face-dense pages)
    // peaked at 19 ACTIVE regions, and the cap now also counts lingering
    // layers, so 20 sat inside the measured healthy range (replay hit it
    // silently). 30 = measured peak 19 + linger headroom, beyond healthy
    // range; production exposed-only classes run far sparser.
    static let maxRegions = 30

    private var window: NSWindow?
    private var hostLayer: CALayer?
    private var active: [Int: RegionLayer] = [:]
    /// Display-rate advance of the painted rects between 30 Hz pipeline updates
    /// (receipts in PaintExtrapolator). nil-safe: with no window tracker and no
    /// media-held regions it returns every rect unchanged.
    let extrapolator = PaintExtrapolator()
    weak var windowTracker: WindowTracker?
    /// Dev/test hook (`--display`): the specific NSScreen to render on. nil
    /// reproduces the exact prior selection, `NSScreen.screens.first`.
    var targetScreen: NSScreen?
    /// `targetScreen`'s origin in CG-global space (see DisplayTarget in
    /// main.swift). nil means "assume screen-local == global" — the prior,
    /// main-display-only assumption baked into PaintExtrapolator's clamp.
    var targetScreenOrigin: CGPoint?
    private var resolvedScreen: NSScreen? { targetScreen ?? NSScreen.screens.first }
    /// `--window-track off`: paint exactly the rects the pipeline hands over, at
    /// the pipeline's own rate. The pre-v3 behavior, byte for byte.
    var extrapolate = false
    /// This frame's regions + rects, replayed by the display-link tick.
    private var lastRegions: [TrackedRegion] = []
    private var lastPainted: [CGRect] = []
    /// Set by clearAll (panic), cleared by the next sync: a 60 Hz tick that
    /// fires after a panic must not repaint from state the panic just retired.
    private var cleared = true
    private var displayLink: Any?
    // Dead layers held at their last position so a replacement (usually a new
    // tracker id for the same on-screen content) paints before they vanish.
    private var lingering: [(id: Int, layer: RegionLayer, syncsLeft: Int)] = []
    // Curtain layers (Curtain.swift), keyed by CGWindowID. Managed at the end
    // of sync(); cleared by clearAll() like every other black rectangle.
    private var curtainLayers: [UInt32: RegionLayer] = [:]
    // Last pipeline-provided layer frame per curtain (carries Curtain's
    // expansions); unioned with the live ring frame in both paint paths.
    private var curtainPipeFrames: [UInt32: CGRect] = [:]
    private static let padFraction: CGFloat = 0.10  // SPEC §5.3 box padding
    // Media-held regions are latched with zero velocity, so the 10% lag pad
    // does not apply, and since media-cover v2 the rect they carry is the
    // snapped media boundary (pixel-exact) plus MotionBoxes' explicit
    // one-cell publish margin, which is where grid quantization and the
    // snap's one-cell-per-update inward limit are already accounted for.
    // What remains for this pad to cover is the detection box the region is
    // unioned with, which the detector places to a few px. Receipt: 2% was
    // sized for v1's dilated, grid-quantized box; carrying it on top of the
    // v2 margin pushed painted area to 1.21x of truth on steady frames, over
    // the 1.20x tightness budget (iter2-b). 1% measures 1.12x worst case with
    // a 12 px edge error and still covers 5.6 x 3.2 px of detector slack.
    private static let mediaPadFraction: CGFloat = 0.01
    var onTripwire: ((String) -> Void)?

    /// PAINT TRUTH sink: `(committedAt, regionID, layerFrame, source)`, called
    /// once for every rect actually handed to a CALayer. Screen points,
    /// bottom-left origin — the layer's own space, unconverted.
    ///
    /// Installed only by a live Pipeline (see FrameLogger.paints for the source
    /// codes and the receipt). nil headless, nil under `--no-overlays`, and
    /// `--process` never constructs an OverlayManager at all, so this is a
    /// measurement-only addition that no `--process` log can observe.
    var paintLog: ((CFAbsoluteTime, Int, CGRect, Int) -> Void)?

    var windowNumbers: [Int] { window.map { [$0.windowNumber] } ?? [] }
    var count: Int { active.count }

    // MARK: Fullscreen Space transition — a documented OS-level gap

    /// Loud line for the one curtain exposure nothing we paint can close.
    /// MEASURED 2026-09-09 on a test Mac:
    /// when a
    /// curtained Chrome window enters or leaves native fullscreen the page is
    /// composited for ~0.5 s (first page pixels +0.1 s after the command,
    /// covered again by +0.6 s; 20/20 transitions in the control arm) while
    /// this window logs full-display paints throughout. The frames show WHY:
    /// the window server draws the transitioning window in its own layer
    /// ABOVE every app window — on exit our full-display curtain is visible
    /// around the animating window; on enter the finished fullscreen page
    /// sits over everything for 0.4 s. Four arms tried and all measured the
    /// same ~0.5 s: `.stationary` removed, a per-Space `.moveToActiveSpace`
    /// window flashed on the transition, Accessibility Reduce Motion, and
    /// `CGDisplayFade` (which returns kCGErrorNotImplemented on 26.5.2). The
    /// arm code is in this PR's first commit (bd272c2) for re-runs.
    ///
    /// What ships is therefore the trigger only: the moment the set of
    /// display-sized curtains changes — a curtained window becoming the
    /// display or ceasing to be it — a named `"event":"curtain"` line
    /// records the transition so the ~0.5 s exposure is counted in every
    /// live log instead of being invisible. A geometry/union fix does not
    /// apply (nothing we paint is composited); the owner decides whether the
    /// gap is acceptable (SPEC §7).
    private var displaySizedCurtains = Set<UInt32>()
    var onCurtainEvent: ((String) -> Void)?

    /// Pure: updates the display-sized set for `id` and names the transition
    /// it implies ("enter" = became the display, "exit" = stopped being it,
    /// including an unlisted id), nil when nothing changed. `--ui-selftest`
    /// asserts the four cases.
    static func spaceTransition(
        displaySized: inout Set<UInt32>, id: UInt32, frame: CGRect?, screenSize: CGSize
    ) -> String? {
        let isDisplay = frame.map {
            Curtain.coversDisplay($0, display: CGRect(origin: .zero, size: screenSize))
        } ?? false
        let was = displaySized.contains(id)
        guard was != isDisplay else { return nil }
        if isDisplay { displaySized.insert(id) } else { displaySized.remove(id) }
        return isDisplay ? "enter" : "exit"
    }

    private func noteSpaceState(id: UInt32, frame: CGRect?, screenSize: CGSize) {
        guard let kind = Self.spaceTransition(
            displaySized: &displaySizedCurtains, id: id, frame: frame, screenSize: screenSize)
        else { return }
        onCurtainEvent?("space-transition window \(id) kind=\(kind) — the OS composites "
            + "the transition above every window; ~0.5 s uncovered (MEASURED 2026-09-09, "
            + "documented gap, see OverlayManager.spaceTransition)")
    }

    // Linger receipt (measured 2026-08-17, replays of scroll-v3 / nav-test /
    // video-test2 through the current tracker; churn_tail.py next to this
    // workspace): when a region id dies mid-scroll, its same-content
    // successor id appears 1-4 frames LATER (scroll-v3: 94 of 112 successor
    // gaps are <=4 frames; the k=3 mode alone is 56). Those 1-3 uncovered
    // frames were the user-visible show-through. Holding the dead layer for
    // 3 extra syncs bridges every gap <=4. Gaps >=5 are dominated by page
    // navigation (nav-test bump at k=8-12) where content genuinely left the
    // screen; lingering across those would black out unrelated new content,
    // so they are deliberately not bridged. Cost when content is truly gone:
    // 150 ms of residual black at 20 fps — fail-safe direction.
    private let lingerSyncs = 3

    /// Motion lead: extend the overlay along the region's velocity so the
    /// leading edge stays covered while detection lags. Velocity is in
    /// per-frame units, so this is a frame count — but what it has to cover is
    /// a DURATION, which is what its receipt always reasoned about ("frame
    /// interval plus inference").
    ///
    /// RESTATED AS A DURATION 2026-09-08. This is the first of the six
    /// live-paint constants the receipt audit left as a KNOWN GAP
    /// and the only one of the six in the EXPOSURE
    /// direction. The lag a lead has to cover is
    ///     1/fps                sampling — the pixels are already one frame old
    ///   + inferP95Ms/1000      inference, the tier's OWN measured p95
    /// = 33.3 + 12.8 = 46.1 ms at the default tier (1.384 frames)
    /// = 66.7 + 51.0 = 117.7 ms at the no-ane tier (1.765 frames — the "~1.77
    ///   frames" the audit named). As a fixed 1.5 the lead UNDER-covered the
    ///   no-ane tier by 0.27 frames of velocity, and it was falsified by a
    ///   number measured inside the change that introduced that tier.
    ///
    /// `leadMargin` is the margin the shipped 30 fps value already carries over
    /// its own derivation: 1.5 / 1.384 = 1.0838, taken as 1.08. Carrying the
    /// shipped margin forward, rather than inventing a new one, is what makes
    /// every tier's lead stand in the same relationship to its own measured
    /// lag. At 15 fps: 1.765 x 1.08 = 1.9062 frames = 127.1 ms, i.e. 9.4 ms
    /// (0.14 frames) of lead beyond the measured lag — an 8.0% margin, the same
    /// 8% the default tier ships with.
    ///
    /// WHY IT ROUNDS DOWN, in a receipt that otherwise calls this the exposure
    /// direction: 1.08 is the LARGEST two-decimal margin that leaves the 1.5
    /// floor binding at 30 fps. 1.384 x 1.08 = 1.4947 (floor wins, lead is
    /// exactly 1.5); 1.384 x 1.09 = 1.5086 (floor stops binding, lead becomes
    /// 1.5086), and `--process` logs `paintRect`'s output as `painted`, so
    /// that third decimal moves every replay. Rounding up is not available
    /// here; it is a
    /// baseline change wearing a safety argument. The cost of rounding down is
    /// 0.0071 frames of lead at 15 fps (0.5 ms of velocity), against a 9.4 ms
    /// margin. `PerfTier.selftest` pins `leadMargin == 1.08` AND asserts the
    /// floor is still binding at 30 fps, so raising it fails loudly here rather
    /// than as a RED gate.
    ///
    /// FLOOR AT THE PRE-TIER VALUE, load-bearing twice. (1) A lead may never
    /// SHRINK below what shipped: this is the exposure direction, and every
    /// fixture receipt in this repo was taken at 1.5. (2) 30 fps therefore
    /// returns the literal `leadFramesAt30` by construction rather than by a
    /// floating-point coincidence — `--process` runs through `paintRect` and
    /// logs its output as `painted`, so the frozen gate baseline depends on
    /// this being EXACTLY 1.5 and not 1.4947. Pinned in `PerfTier.selftest`.
    static let leadFramesAt30: CGFloat = 1.5
    static let leadMargin: CGFloat = 1.08
    static func leadFrames(fps: Int, inferP95Ms: Double) -> CGFloat {
        max(leadFramesAt30,
            CGFloat(1.0 + inferP95Ms * Double(fps) / 1000.0) * leadMargin)
    }

    // Visibility floor for a painted cover, normalized. Receipt at the use
    // site in paintRect.
    static let minPaintedSide: CGFloat = 0.10

    /// The rect the overlay paints for a region, in NORMALIZED bottom-left
    /// coordinates: velocity lead + pad, clamped to the unit square. The one
    /// definition of that math, so the live path and the headless `painted` log
    /// field cannot diverge. Touches no AppKit and no screen.
    ///
    /// `leadFrames` has no default: it is fps-derived (receipt above), and a
    /// default here would be the pre-tier value hiding where the sweep in
    /// `PerfTier.selftest` could not find it. The one caller is
    /// `PaintSmoother.rects`, which carries the pipeline's resolved value.
    static func paintRect(for region: TrackedRegion, leadFrames: CGFloat) -> CGRect {
        var normalized = region.rect
        let lead = CGVector(
            dx: region.velocity.dx * leadFrames, dy: region.velocity.dy * leadFrames)
        if lead.dx < 0 { normalized.origin.x += lead.dx }
        normalized.size.width += abs(lead.dx)
        if lead.dy < 0 { normalized.origin.y += lead.dy }
        normalized.size.height += abs(lead.dy)
        let pad = region.mediaHeld ? mediaPadFraction : padFraction
        var padded = normalized.insetBy(
            dx: -normalized.width * pad, dy: -normalized.height * pad)
        // Minimum painted size. Receipt (live spot run 2026-08-19,
        // daemon/testdata/livespot-2026-08-19.jsonl): median blocked box on an
        // image-search grid is 0.02–0.06 normalized — a 40–115 pt fleck the
        // user reported as "barely worked, if anything at all". 0.10 per
        // side (~192×108 pt on this screen) is unmistakably a cover and
        // still region-scale. Over-cover is the fail-safe direction. Edge
        // clamp below may shrink it at screen borders; the content sits at
        // the border there too.
        if padded.width < Self.minPaintedSide {
            padded = padded.insetBy(dx: (padded.width - Self.minPaintedSide) / 2, dy: 0)
        }
        if padded.height < Self.minPaintedSide {
            padded = padded.insetBy(dx: 0, dy: (padded.height - Self.minPaintedSide) / 2)
        }
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        // A rect entirely off the unit square intersects to CGRect.null, whose
        // origin is infinite: that would paint garbage and, in the logger,
        // make JSONEncoder throw and silently drop the whole frame record.
        return clamped.isNull ? .zero : clamped
    }

    /// Returns true when the persistent window was just created (capture
    /// exclusion must then refresh — a once-per-process event; layer changes
    /// never alter window identity).
    ///
    /// `painted` is the smoothed painted rect per region, in the same order —
    /// produced once per frame by PaintSmoother so the live overlay and the
    /// `--process` log's `painted` field are the same rects, not two
    /// recomputations of the same math over different state.
    ///
    /// `anchors` (parallel to `regions`) carry each media-held region's owning
    /// window and that window's frame at capture time; `capturedAt` is the
    /// frame's presentation timestamp. Together they let the display-link tick
    /// advance the painted rects between pipeline updates — see
    /// PaintExtrapolator. Both default to "nothing known", which is exactly what
    /// a headless or region-mode caller has, and which makes the advance a no-op.
    @discardableResult
    func sync(
        _ regions: [TrackedRegion], painted: [CGRect],
        anchors: [PaintExtrapolator.Anchor] = [],
        capturedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        curtains: [(id: UInt32, rect: CGRect, attr: CGRect)] = [],
        curtainOwners: [Int: UInt32] = [:]
    ) -> Bool {
        self.curtainOwners = curtainOwners
        guard let screen = resolvedScreen else { return false }
        let created = ensureWindow(on: screen)
        guard let window, let hostLayer else { return created }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        cleared = false
        extrapolator.setScreenSize(screen.frame.size, origin: targetScreenOrigin ?? .zero)
        // The maxRegions tripwire caps EVERYTHING downstream, including the
        // extrapolator — not just rendering. A runaway tracker (the exact
        // failure this cap exists for, receipt at maxRegions) previously did
        // O(N) ingest work and held O(N) extrapolator state with N unbounded
        // while the tripwire fired for the render path only (audit
        // 2026-08-21). Cap once, before anything consumes the lists.
        var regions = regions, painted = painted, anchors = anchors
        if regions.count > Self.maxRegions {
            onTripwire?(
                "overlay-count: limit \(Self.maxRegions), observed \(regions.count) "
                + "(fix: OverlayManager.maxRegions)")
            regions = Array(regions.prefix(Self.maxRegions))
            painted = Array(painted.prefix(Self.maxRegions))
            if anchors.count > Self.maxRegions {
                anchors = Array(anchors.prefix(Self.maxRegions))
            }
        }
        extrapolator.ingest(
            regions: regions, painted: painted, anchors: anchors, capturedAt: capturedAt)
        lastRegions = regions
        lastPainted = painted

        let shown = Array(zip(regions, painted))

        // All layer mutations in one transaction with implicit animations
        // off: the default 0.25 s implicit animation would trail a moving
        // region and uncover its leading edge (the tracker's velocity lead
        // assumes the layer snaps to the commanded frame). Disabling actions
        // also makes add/move/remove land in the same compositor frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let size = screen.frame.size
        let now = CFAbsoluteTimeGetCurrent()
        // Curtain layers FIRST: the region loop below clamps its frames
        // against the curtain clamp bounds refreshed in this same
        // transaction (ownerClamped receipt), so curtains must be current
        // before any region layer is placed.
        syncCurtains(curtains, screenSize: size, at: now, scale: window.backingScaleFactor,
                     hostLayer: hostLayer)

        // Age lingering layers BEFORE processing this frame's deaths, so a
        // layer that dies now survives `lingerSyncs` further sync calls.
        lingering = lingering.filter { entry in
            if entry.syncsLeft <= 0 {
                entry.layer.shape.removeFromSuperlayer()
                return false
            }
            return true
        }
        for i in lingering.indices { lingering[i].syncsLeft -= 1 }

        var seen = Set<Int>()
        for (region, paintedRect) in shown {
            seen.insert(region.id)
            let advanced = extrapolate
                ? extrapolator.rect(
                    for: region, fallback: paintedRect, at: now, tracker: windowTracker)
                : paintedRect
            let frame = ownerClamped(layerFrame(advanced, screenSize: size), regionID: region.id)
            paintLog?(now, region.id, frame, 0)
            if let layer = active[region.id] {
                layer.update(frame: frame)
            } else if let i = lingering.firstIndex(where: { $0.id == region.id }) {
                // Defensive: tracker ids are monotonic and never reused, but
                // resurrecting is strictly safer than a duplicate layer.
                let layer = lingering.remove(at: i).layer
                layer.update(frame: frame)
                active[region.id] = layer
            } else {
                let layer = RegionLayer(scale: window.backingScaleFactor)
                hostLayer.addSublayer(layer.shape)
                layer.update(frame: frame)
                active[region.id] = layer
            }
        }
        for (id, layer) in active where !seen.contains(id) {
            active.removeValue(forKey: id)
            lingering.append((id: id, layer: layer, syncsLeft: lingerSyncs))
        }
        // Lingering layers respect the same tripwire cap; drop oldest first —
        // loudly, never silently (limits must fail visibly).
        var lingerDropped = 0
        while active.count + lingering.count > Self.maxRegions, !lingering.isEmpty {
            lingering.removeFirst().layer.shape.removeFromSuperlayer()
            lingerDropped += 1
        }
        if lingerDropped > 0 {
            onTripwire?(
                "overlay-count: limit \(Self.maxRegions), dropped \(lingerDropped) "
                + "lingering layer(s) (fix: OverlayManager.maxRegions)")
        }
        // Lingering layers are not repainted, but they ARE still black on the
        // screen. Report them too, or the census sees an unexplained rectangle
        // and has to guess whether it is a cover or dark content. Owned
        // lingerers do get re-clamped: a trail behind a moving curtain is
        // the ownerClamped defect wearing a linger hat.
        for entry in lingering {
            let current = entry.layer.shape.frame
            let frame = ownerClamped(current, regionID: entry.id)
            if frame != current { entry.layer.update(frame: frame) }
            paintLog?(now, entry.id, frame, 2)
        }
        return created
    }

    /// Update only curtain layers from a geometry-only tick. Region state is
    /// intentionally untouched: a timer must not age region linger, ingest
    /// extrapolator inputs, or change the independent region pipeline.
    @discardableResult
    func syncCurtainState(
        _ curtains: [(id: UInt32, rect: CGRect, attr: CGRect)],
        at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        guard let screen = resolvedScreen else { return false }
        let created = ensureWindow(on: screen)
        guard let window, let hostLayer else { return created }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        cleared = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        syncCurtains(
            curtains, screenSize: screen.frame.size, at: now,
            scale: window.backingScaleFactor, hostLayer: hostLayer)
        return created
    }

    /// Curtain layers (Curtain.swift): painted exactly as handed — no pad,
    /// no velocity lead, no minimum size — because the rect IS the window's
    /// OS-reported frame minus the chrome strip. Not capped by maxRegions:
    /// curtain count is bounded by the number of flagged on-screen windows
    /// (the tripwire below is what makes that bound fail loudly instead of
    /// silently, 2026-08-21: every other per-cover structure here has a
    /// cap+tripwire, this had only the assumption).
    /// MEASURED 2026-09-08, test Mac, source main 3ae5a64, ten shielded runs:
    /// distinct curtain ids in one sync = 1 in every single-window mode and 2
    /// in `twowin` (counted from each run's own curtain paint records, log
    /// sources 3/4), against the 30 threshold — 15x of headroom, and the
    /// tripwire below never fired. The bound is no longer ASSUMED for one and
    /// two flagged windows; it is still unmeasured for a desktop that flags
    /// many, which is exactly what the tripwire is for.
    /// Removal is immediate here once an id leaves the pipeline's output —
    /// but dead-flavor lifts stay IN that output for Curtain.curtainLingerSecs
    /// (pipeline-side linger), and hold-expiry lifts leave at once with the
    /// region covers beneath repainting the same content in the same sync.
    private func syncCurtains(
        _ curtains: [(id: UInt32, rect: CGRect, attr: CGRect)], screenSize size: CGSize,
        at now: CFAbsoluteTime, scale: CGFloat, hostLayer: CALayer
    ) {
        // Tripwire only — no cap: dropping a curtain here would uncover a
        // flagged window, which is never an acceptable trade for memory. If
        // this ever fires, the "bounded by flagged windows" assumption above
        // broke upstream; fix it there. maxRegions=30 reused as the
        // threshold: an order of magnitude above any observed flagged-window
        // count (live sessions saw 1-3 concurrent curtains).
        if curtains.count > Self.maxRegions {
            onTripwire?(
                "curtain-count: limit \(Self.maxRegions), observed \(curtains.count) "
                + "— all still painted, fail-safe (fix: upstream Curtain state, "
                + "see Overlay.syncCurtains)")
        }
        var seenCurtains = Set<UInt32>()
        for entry in curtains {
            seenCurtains.insert(entry.id)
            curtainStripDelta[entry.id] =
                max(0, layerFrame(entry.attr, screenSize: size).height
                    - layerFrame(entry.rect, screenSize: size).height)
            // UNION of the freshest 120 Hz window frame and the pipeline's
            // rect. The live frame kills the stale-rect drag flash (228
            // measured snap-backs, 2026-08-20); the pipeline rect carries
            // the Curtain expansions (bridge/shield), which the ring knows
            // nothing about — preferring the live frame alone silently
            // discarded every expansion the moment the ring had a sample
            // (review 2026-08-20, P2). Union only ever over-covers.
            let pipeFrame = layerFrame(entry.rect, screenSize: size)
            curtainPipeFrames[entry.id] = pipeFrame
            let live = liveCurtainFrame(id: CGWindowID(entry.id), screenSize: size)
            let frame = live.map { $0.union(pipeFrame) } ?? pipeFrame
            curtainClampFrames[entry.id] = stripGrown(frame, id: entry.id)
            noteSpaceState(id: entry.id, frame: frame, screenSize: size)
            paintLog?(now, Int(entry.id), frame, 3)
            let titleBarBare = (curtainStripDelta[entry.id] ?? 0) > 0
            if let layer = curtainLayers[entry.id] {
                layer.titleBarBare = titleBarBare
                layer.update(frame: frame)
            } else {
                let layer = RegionLayer(scale: scale, curtain: true)
                layer.titleBarBare = titleBarBare
                hostLayer.addSublayer(layer.shape)
                layer.update(frame: frame)
                curtainLayers[entry.id] = layer
            }
        }
        for (id, layer) in curtainLayers where !seenCurtains.contains(id) {
            noteSpaceState(id: id, frame: nil, screenSize: size)
            layer.shape.removeFromSuperlayer()
            curtainLayers.removeValue(forKey: id)
            curtainMotion.removeValue(forKey: CGWindowID(id))
            curtainPipeFrames.removeValue(forKey: id)
            curtainStripDelta.removeValue(forKey: id)
            curtainClampFrames.removeValue(forKey: id)
        }
    }

    /// Region-cover hygiene against active curtains (owner report
    /// 2026-08-20: individual blocks trail outside a scrolling/dragging
    /// curtained window — live-sanity receipt: 3,214 region paints spilled
    /// past the curtained window, worst 565 pt total overhang; sources are
    /// the extrapolator advance, the display-link tick, and linger).
    ///
    /// Ownership comes from the PIPELINE (main.swift regionCurtainOwners):
    /// at sync time the region rect and the curtain rect are from the same
    /// instant, so a majority-overlap test there is real attribution. A
    /// share test at PAINT time was tried first and failed under motion
    /// (drag run: 529 spilling paints — a trailing box drops below any
    /// share threshold as the window moves away, which is exactly when it
    /// spills). An owned region frame is clipped to its owner's clamp
    /// bound regardless of present overlap: the remainder is hidden under
    /// the curtain (black under black — the curtain covers that window's
    /// content, so no cover is lost), and a fully-departed trailing box
    /// collapses to zero and paints nothing. Unowned regions are
    /// untouched: another window's content keeps its own cover.
    ///
    /// The clamp bound is the curtain frame painted this pass with its TOP
    /// edge raised by the strip delta — the full window extent at the
    /// window's CURRENT position (altitude review 2026-08-20: the strip
    /// band's region backstop must survive the clamp). Unioning the stale
    /// full-frame rect was tried and REVERTED (drag-clamp6: 868 boxes
    /// painted at the window's old position — the union let trails
    /// through). Cached so neither paint path re-reads CALayer frames per
    /// region (efficiency review, same date); refreshed by syncCurtains
    /// and advanceCurtains before any region layer is placed.
    private var curtainOwners: [Int: UInt32] = [:]
    private var curtainStripDelta: [UInt32: CGFloat] = [:]
    private var curtainClampFrames: [UInt32: CGRect] = [:]
    private func ownerClamped(_ frame: CGRect, regionID: Int) -> CGRect {
        guard let cid = curtainOwners[regionID],
            let bound = curtainClampFrames[cid] else { return frame }
        let inter = frame.intersection(bound)
        return inter.isNull ? .zero : inter
    }

    /// Layer space is bottom-left origin, so the chrome strip (window top)
    /// is the frame's maxY side: raise the top edge by the strip delta to
    /// get the full window extent at the frame's CURRENT position.
    private func stripGrown(_ frame: CGRect, id: UInt32) -> CGRect {
        let delta = curtainStripDelta[id] ?? 0
        return delta > 0
            ? CGRect(x: frame.minX, y: frame.minY,
                     width: frame.width, height: frame.height + delta)
            : frame
    }

    /// Panic path (SPEC §8.1(1)): removes every layer immediately. The
    /// persistent window intentionally stays ordered in — it is transparent
    /// and click-through, and keeping it alive keeps its windowNumber (and
    /// therefore the capture exclusion, invariant 3) valid across the pause;
    /// ordering out can invalidate the window's device and change the number.
    func clearAll() {
        clearPaint()
        windowTracker?.reset()
    }

    /// Every cover layer and the paint state the display-link tick replays,
    /// and nothing else: `WindowTracker` (shared with the curtain) is left
    /// alone. `clearAll` is this plus the tracker reset the panic path needs.
    func clearPaint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in active.values { layer.shape.removeFromSuperlayer() }
        for entry in lingering { entry.layer.shape.removeFromSuperlayer() }
        for layer in curtainLayers.values { layer.shape.removeFromSuperlayer() }
        active.removeAll()
        lingering.removeAll()
        curtainLayers.removeAll()
        curtainMotion.removeAll()
        curtainPipeFrames.removeAll()
        curtainStripDelta.removeAll()
        curtainClampFrames.removeAll()
        curtainOwners.removeAll()
        displaySizedCurtains.removeAll()
        CATransaction.commit()
        // The display link keeps ticking (it is cheap and the window survives a
        // panic on purpose), so the tick has to be told there is nothing left to
        // advance. Without this a tick queued behind the clear repaints from the
        // rects the panic just retired.
        cleared = true
        lastRegions.removeAll()
        lastPainted.removeAll()
        extrapolator.reset()
    }

    /// Region covers only, at once, for the full-coverage release
    /// (`Pipeline.releaseRegionCovers`): active and lingering layers go now,
    /// not after `lingerSyncs`, and the display-link tick has no region rects
    /// left to replay. Curtains, their clamp state and the window tracker are
    /// untouched. Main thread.
    func clearRegions() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in active.values { layer.shape.removeFromSuperlayer() }
        for entry in lingering { entry.layer.shape.removeFromSuperlayer() }
        active.removeAll()
        lingering.removeAll()
        CATransaction.commit()
        lastRegions.removeAll()
        lastPainted.removeAll()
    }

    /// Display topology changed. Main thread.
    ///
    /// `sync` re-reads the screen and re-sets the extrapolator's size on every
    /// frame, so the only thing that needs dropping here is the state CARRIED
    /// between frames: per-region velocities and window deltas measured in the
    /// OLD point space, and this frame's rects, which the 60 Hz tick would keep
    /// advancing against the new screen — arithmetic over two different
    /// geometries.
    ///
    /// Existing layers are deliberately LEFT ON SCREEN (`cleared` stops the
    /// tick from moving them, it does not remove them). A frozen cover
    /// over-covers until the first frame of the new geometry replaces it;
    /// removing it here would uncover content for the whole stream rebuild.
    /// Over-covering beats uncovering — that choice is made HERE, on its own
    /// merits, and NOT by analogy with the suspend path: that path's reason
    /// ("an inactive session's overlay is off-screen anyway") does not transfer,
    /// because a hot-plug happens with someone watching the screen.
    func displayGeometryChanged(size: CGSize, origin: CGPoint) {
        extrapolator.setScreenSize(size, origin: origin)
        extrapolator.reset()
        lastRegions.removeAll()
        lastPainted.removeAll()
        cleared = true
    }

    /// One display-rate repaint BETWEEN pipeline updates: re-place the layers
    /// that already exist at their advanced positions. Adds nothing, removes
    /// nothing, ages nothing — birth, death and linger are the pipeline's
    /// business and stay on the 30 Hz path.
    ///
    /// Clock: CADisplayLink, i.e. the display's own cadence. track-d §8 tested
    /// and REJECTED phase-locking a fresh position's commit to vsync (28.7 ms
    /// p50 to glass vs 23.9 committing immediately — the wait costs more than
    /// the alignment saves), which is why `sync` still commits the moment a
    /// result arrives. The display link is used only as the CLOCK for these
    /// interstitial repaints, which is what §7 measured the 95.7 -> 17.8 ms
    /// improvement with. Cost: ~0.4% of one core over the 30 Hz baseline (§6).
    @objc func tick() {
        guard extrapolate, !cleared,
            !(lastRegions.isEmpty && curtainLayers.isEmpty),
            let screen = resolvedScreen
        else { return }
        let size = screen.frame.size
        let now = CFAbsoluteTimeGetCurrent()
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // worth 88 ms, track-d §2
        defer { CATransaction.commit() }
        // Curtains first, same reason as sync: the region clamp below reads
        // the curtain frames this very tick just placed.
        advanceCurtains(screenSize: size, at: now)
        for (i, region) in lastRegions.enumerated() {
            guard let layer = active[region.id], i < lastPainted.count else { continue }
            let advanced = extrapolator.rect(
                for: region, fallback: lastPainted[i], at: now, tracker: windowTracker)
            let frame = ownerClamped(layerFrame(advanced, screenSize: size), regionID: region.id)
            paintLog?(now, region.id, frame, 1)
            layer.update(frame: frame)
        }
    }

    /// Display-link advance for curtains: re-read each curtained window's
    /// latest 120 Hz frame so a dragged window never outruns its curtain.
    /// This is the safe alternative to locking the window in place — a lock
    /// needs the Accessibility permission and fights the user's own drag,
    /// which breaks SPEC §8's "worst failure is cannot see, never cannot
    /// act" property.
    /// A window whose ring has no fresh frame keeps its
    /// last painted rect — over-cover at a stale position, fail-safe.
    private func advanceCurtains(screenSize: CGSize, at now: CFAbsoluteTime) {
        guard !curtainLayers.isEmpty else { return }
        for (id, layer) in curtainLayers {
            // Same union rule as sync (review 2026-08-20, P2): the live ring
            // frame rides drags, the pipeline frame carries expansions.
            let live = liveCurtainFrame(id: CGWindowID(id), screenSize: screenSize)
            let pipe = curtainPipeFrames[id]
            let frame: CGRect
            switch (live, pipe) {
            case let (l?, p?): frame = l.union(p)
            case let (l?, nil): frame = l
            case let (nil, p?): frame = p
            case (nil, nil): continue
            }
            curtainClampFrames[id] = stripGrown(frame, id: id)
            noteSpaceState(id: id, frame: frame, screenSize: screenSize)
            paintLog?(now, Int(id), frame, 4)
            layer.update(frame: frame)
        }
    }

    // Swept-lead bookkeeping per curtained window: the last two DISTINCT
    // ring frames and their observation times, in content-rect space (strip
    // already removed). Main thread only (both liveCurtainFrame callers).
    private var curtainMotion:
        [CGWindowID: (prev: CGRect, prevT: CFAbsoluteTime, last: CGRect, lastT: CFAbsoluteTime)] = [:]

    /// Lead horizon for the swept union. Receipt: ring staleness p95 17.9 ms
    /// during a 900 pt/s drag (WindowTracker.pollHz receipt) + one display
    /// link period 8.3 ms + margin. Owner-reported flashes on very fast
    /// drags and jump-resizes (2026-08-20) are this latency showing content
    /// at the leading edges.
    private static let curtainLeadSecs: CFTimeInterval = 0.030
    /// Per-edge extension cap. 0.030 s x a 4000 pt/s flick = 120 pt; beyond
    /// that a projection is guessing, and over-cover from a wrong guess is
    /// bounded here.
    ///
    /// MEASURED 2026-09-08, test Mac, shielded `fast` mode (`sched_fast.txt`: a
    /// 1500 pt/s scripted translation, a 380 pt jump-resize at t=8.5 s, then a
    /// 1000 pt/s sweep), source main 3ae5a64, three-arm A/B of THIS constant,
    /// 3 runs per arm. Metric: per-edge over-extension of every curtain paint
    /// (log sources 3/4) past the commanded content rect, split moving/parked,
    /// screen-clamped edges excluded. It is an UPPER BOUND on the lead, not the lead alone: the
    /// painted rect is `live.union(pipeFrame)`, and a commanded move the ring
    /// has not observed yet also reads as over-extension.
    ///
    /// THE CAP BINDS HERE, AND 120 IS THE RIGHT PLACE FOR IT. Moving-paint
    /// over-extension per arm, the three runs' max / p99 / p95 in pt:
    ///   * cap 8   max 154.0 154.0 154.0 | p99 144 144 154 | p95  96  72  96
    ///   * cap 120 max 216.0 154.0 168.0 | p99 154 154 154 | p95 110 120 120
    ///   * cap 480 max 258.9 357.8 160.5 | p99 235 280 154 | p95 154 163 120
    /// The cap-8 arm is the floor this metric cannot go below — 154.0 pt in
    /// all three runs, the part of the over-extension that is NOT lead (paint
    /// still on the pre-move rect, plus the pipeline union; that same 154.0
    /// recurs as a right-edge maximum in EVERY arm, so one run's max is not a
    /// clean ordering statistic — read the tail, not the max). What carries
    /// the result: cap 8's whole distribution sits below the others (p95 72-96
    /// vs 110-120 vs 120-163), and cap 480 produces p99s of 235 and 280 pt and
    /// a 357.8 pt max that the 120 arm never reaches — the 120 arm's p99 is
    /// 154.0 in all three runs. Requests the 480 cap lets through are being
    /// truncated at 120: the clamp is doing work at these speeds.
    /// WHY it binds at 1500 pt/s when the 120 was derived for 4000: the lead
    /// is velocity x (sample age + `curtainLeadSecs`), and on a test Mac the
    /// ring advances at 33.6-40.5 Hz, not 120 (WindowTracker receipt at
    /// `lateTolerance`), so the age term reaches ~0.09 s and the REQUEST
    /// reaches 200-350 pt. On a healthy 120 Hz ring the same drag asks for
    /// ~57 pt. This A/B is therefore as much a stale-ring test as a speed test.
    /// WHAT THE CAP BOUGHT, `score_fast` exposed area (pt2*s): every cap-8 run
    /// (1 119 787 / 1 129 873 / 1 126 489) is worse than every 120- and 480-pt
    /// run (1 108 130 / 1 099 090 / 1 104 091 and 1 107 671 / 1 108 898 /
    /// 1 105 157) — a clean 3-vs-6 split, p = 1/C(9,3) = 0.012 under
    /// exchangeability, mean penalty 1.8%. Crushing the lead costs real
    /// exposure; quadrupling it to 480 buys none of that back (arm means 0.3%
    /// apart, inside the 0.8% run-to-run spread) and paints up to 358 pt of
    /// over-cover. 120 sits where exposure has flattened and over-cover is
    /// still bounded. RECOMMENDATION: keep it.
    /// UNMOVED BY ANY CAP, same nine runs: `score_fast` peak edge gap 380.0 pt
    /// and peak exposed fraction 0.578, identical in all of them. That peak is
    /// the jump-resize's ring latency — the paint sits on the old rect while
    /// the truth is already at the new one — not a clamped projection. Raising
    /// this constant to chase it is the wrong lever; ring staleness is.
    /// STILL UNTESTED: translation faster than 1500 pt/s. The 4000 pt/s flick
    /// this value was derived from is in no harness schedule; what these runs
    /// exercise instead is a comparable lead REQUEST produced by a slow ring.
    private static let curtainLeadCapPt: CGFloat = 120
    /// A window whose ring frame has not changed for this long is treated as
    /// still (velocity zeroed): keeps a stopped drag from wearing a stale
    /// lead. One ring commit gap during real motion is ~8 ms; 150 ms is 18x.
    /// MEASURED 2026-09-08 (WindowTracker receipt at `lateTolerance`, same ten
    /// shielded runs): on a test Mac the loop advances every ~29 ms, so the real
    /// margin there is ~5x, not 18x. Still comfortable, and the parked-paint
    /// control holds — 10,486 parked curtain paints carried 0.0 pt of lead
    /// (receipt at `Curtain.trailMotionPt`) — but a machine three times slower
    /// again would start wearing stale leads, which is what to look for.
    private static let curtainStillSecs: CFTimeInterval = 0.15

    /// The one conversion from a curtained window's freshest 120 Hz ring
    /// frame to a layer frame: chrome strip removed, SWEPT LEAD applied
    /// (union of the current content rect and its ~30 ms per-edge velocity
    /// projection — never smaller than current, so a still window is
    /// byte-identical and a wrong projection only over-covers), CGWindowList
    /// global top-left points -> this screen's local bottom-left points,
    /// clamped to the screen (review 2026-08-19, P3). Both the pipeline sync
    /// and the display-link tick call this, so they cannot diverge (the
    /// divergence WAS the drag-release flash — receipt at the sync call
    /// site).
    private func liveCurtainFrame(id: CGWindowID, screenSize: CGSize) -> CGRect? {
        guard let tracker = windowTracker, let raw = tracker.latestFrame(of: id)
        else { return nil }
        // Strip logic shared with the pipeline path (Curtain.contentRect):
        // fullscreen windows get no strip.
        let display = CGRect(origin: targetScreenOrigin ?? .zero, size: screenSize)
        let f = Curtain.contentRect(window: raw, display: display, quickLook: tracker.isQuickLookWindow(id))
        let now = CFAbsoluteTimeGetCurrent()
        var m = curtainMotion[id] ?? (prev: f, prevT: now, last: f, lastT: now)
        if f != m.last {
            m = (prev: m.last, prevT: m.lastT, last: f, lastT: now)
        }
        curtainMotion[id] = m
        var swept = f
        let dt = m.lastT - m.prevT
        if dt > 0, now - m.lastT < Self.curtainStillSecs {
            // Project each edge by its own velocity over (age + lead) and
            // union with the current rect: translation extends the leading
            // edge, growth extends the growing edges, shrink is ignored
            // (over-cover, fail-safe).
            let horizon = CGFloat((now - m.lastT) + Self.curtainLeadSecs)
            func lead(_ last: CGFloat, _ prev: CGFloat) -> CGFloat {
                let v = (last - prev) / CGFloat(dt)
                return max(-Self.curtainLeadCapPt, min(Self.curtainLeadCapPt, v * horizon))
            }
            let minX = f.minX + min(0, lead(m.last.minX, m.prev.minX))
            let minY = f.minY + min(0, lead(m.last.minY, m.prev.minY))
            let maxX = f.maxX + max(0, lead(m.last.maxX, m.prev.maxX))
            let maxY = f.maxY + max(0, lead(m.last.maxY, m.prev.maxY))
            swept = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let origin = targetScreenOrigin ?? .zero
        let frame = CGRect(
            x: swept.minX - origin.x,
            y: screenSize.height - (swept.minY - origin.y) - swept.height,
            width: swept.width, height: swept.height
        ).intersection(CGRect(origin: .zero, size: screenSize))
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    /// Starts the interstitial repaint clock. macOS 14+ only; on anything older
    /// the overlay simply keeps the 30 Hz behavior it has always had, loudly.
    private func startDisplayLink(on view: NSView) {
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            FileHandle.standardError.write(Data(
                ("WARNING: macOS < 14, no CADisplayLink — the overlay repaints at the "
                + "pipeline's 30 Hz and drags will lag ~95 ms (fix: "
                + "OverlayManager.startDisplayLink)\n").utf8))
        }
    }

    /// Creates the persistent window lazily on first sync (so --no-overlays
    /// runs truly windowless). Returns true only on the creating call.
    private func ensureWindow(on screen: NSScreen) -> Bool {
        guard window == nil else { return false }
        let win = NSWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
            defer: false)
        win.isReleasedWhenClosed = false
        win.level = .screenSaver  // above normal app windows (SPEC §5.5)
        // Click-through: the core safety property (SPEC §8), read from the
        // one rule every window in this app answers to (UIOverlayWindow).
        win.ignoresMouseEvents = UIOverlayWindow.ignoresMouseEvents(hasControls: false)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        // Layer-hosting (set layer BEFORE wantsLayer): we own the layer tree,
        // and the root layer keeps macOS's bottom-left origin — the same
        // convention as the tracker's normalized Vision rects.
        let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        win.contentView = host
        win.orderFrontRegardless()
        window = win
        hostLayer = root
        startDisplayLink(on: host)
        return true
    }

    /// Normalized -> screen pixels only; the rect math lives in paintRect.
    private func layerFrame(_ clamped: CGRect, screenSize: CGSize) -> CGRect {
        // Vision boxes and the (non-flipped) layer tree share a bottom-left origin.
        return CGRect(
            x: clamped.origin.x * screenSize.width,
            y: clamped.origin.y * screenSize.height,
            width: clamped.width * screenSize.width,
            height: clamped.height * screenSize.height)
    }
}

/// The painted rect over TIME: OverlayManager.paintRect says where a region
/// wants to be painted this frame; this says where it is actually painted,
/// given where it was painted last frame.
///
/// The update is decomposed per axis into TRANSLATION + SIZE change (spec
/// iteration-3 "Paint smoother requirement"), and only the size part is
/// rate-limited. Media-held regions only — a region-mode region gets paintRect
/// unchanged, byte for byte:
///
///  1. **Translation is uncapped.** When both edges of an axis want to move the
///     same way, the smaller of the two moves is the translation and it applies
///     in full to both edges. A cover translating with its target never
///     uncovers it. Receipt (iter2-final, drag 3 at 10-12 px/frame): capping
///     the total move at `max(1 cell, translation)` starved the trailing edge
///     of the size budget it also needed — the left edge painted 0.0 px on 6
///     scored frames while truth moved 11-12 px (motion_smoothness p95 1.295
///     cells, limit 1.0), over-cover grew to 118 px and the top edge froze for
///     14 consecutive frames.
///  2. **Size change is capped at `capCells` per frame, per edge**, in both
///     directions. Receipt (iteration-1): the cover collapsed 138 px (drag) and
///     115 px (resize) in ONE frame after a stale rect was released — the
///     spec's no-pops criterion allows 1 cell on steady content, 2 during
///     post-motion recovery. Keeping the cap on outward size moves too is what
///     turns a box re-acquisition that jumps the target into a settle instead
///     of a pop; the fixtures' fastest outward size motion (the 1.3x grow) is
///     4 px/frame per edge, half the cap, so it costs no coverage.
///  3. **Sub-cell deadband on INWARD reversals (monotone convergence).** A size
///     move that continues the edge's last direction applies at any size; a
///     move that reverses it INWARD must be at least one grid cell. Jitter is by
///     definition a reversal, so it is fully suppressed; a settle is by
///     definition monotone, so it completes exactly. Receipts, the three rules
///     this replaces:
///       * periodic leak (iter2-final): letting the inward deadband through
///         every 15 frames round-tripped 1.28 px on pixel-static truth — 7
///         steady_stillness cycles on steady, 4 on controls, 1 each on drag and
///         resize, against a limit of 0.
///       * plain inward deadband with no convergence (i3-a): the resize
///         shrink's last target steps are sub-cell (2.58 px on left, 2.98 px on
///         top, measured f386-f394), so all four edges stranded there —
///         tightness_steady 53.5% of frames within 1.20x against a 95% budget.
///       * inward-completion latched on the PAINTED edge's own last step
///         (i3-b): the painted edge reaches the target before the target stops
///         moving, which clears the latch one frame too early and strands the
///         same 2.6-3.0 px.
///     Iteration-5 amendment: this deadband used to apply to OUTWARD reversals
///     too, which contradicted spec §1 item 7 ("outward moves always apply")
///     and was measured doing exactly the damage that sentence forbids. Live
///     video census, runs/v2-live-video/daemon.jsonl: at three content cuts the
///     TRACKED right edge retracted 7.68 px (0.96 cell) for 1-2 log frames and
///     came straight back — but the return is a sub-cell reversal, so the
///     PAINTED edge stranded 7.68 px inward and stayed there until the target
///     next moved a full cell outward. The census measured the asymmetry from
///     pixels: 64 log-frames painted-retracted against 8 tracked-retracted, an
///     8x hold the tracker never asked for. Outward reversals now go through
///     rule 4 instead, which suppresses the flick without stranding the return.
///
///  4. **Outward persistence (2 frames) on non-required moves.** An outward size
///     move that safety does not require applies only after `outwardPersist`
///     consecutive frames of asking. A one-frame outward-and-back flick never
///     reaches two frames, so it is killed by construction. Receipt (live video
///     census): the tracked LEFT edge flicks 8.96 px outward and back within
///     1-2 log frames 8 times in 60 s, correlated with the video's hard cut and
///     loop wrap; that is above the one-cell gate, so rule 3 never touched it
///     and the painted edge flicked 8.06 px out and back each time. "Required"
///     is measured against the raw blocked DETECTIONS (`mustCover`), the spec
///     invariant, not against the target: the target additionally carries
///     MotionBoxes' one-cell publish margin and the 1% paint pad, and margin is
///     exactly the thing that is allowed to lag one frame. Cost when a real
///     grow starts: one frame (33 ms) of size lag, absorbed by that same
///     margin — the fastest scripted outward size motion is the 1.3x grow at
///     4 px/frame per edge against ~15 px of standing margin.
///
///  5. **Cover-first backstop.** Whatever rules 1-4 decide, the result is
///     unioned with `mustCover`. Smoothing may cost margin; it may never cost
///     coverage. Receipt (i5-a, scroll-after-still f146): with the detection
///     clipped by the top of the frame the paint pad has nowhere to go, so the
///     target edge IS the detection edge and the rule-0 sub-pixel deadband held
///     the painted edge 0.072 px inside it — 37 frames of (microscopic, but
///     real) uncovered detection against a 100% criterion. The union is a no-op
///     on every frame where the painted rect already contains the detection,
///     which is every frame of all seven pre-existing fixtures: their
///     detection_coverage was 100% before this rule and is 100% after it, and
///     the `painted` differences those logs do show (i5-c vs i5-base: steady
///     max 0.77 px, drag and vanish-return max 14.2 px, scroll-slow/fast zero)
///     are rules 3 and 4 changing when a MARGIN move lands, not this backstop.
///     `tracked` is byte-identical on all seven, so nothing upstream moved.
///
/// The output is quantized onto the same 1e-3 normalized lattice the log
/// records, so the per-frame edge move a scorer measures is exactly the move
/// commanded here. Without it the log's rounding adds up to 0.32 cells to a
/// 1-cell step (two rounded coordinates per edge, two frames) and reports a
/// compliant settle as a pop. At the pipeline's 1280-wide working resolution
/// one lattice step is 1.28 px — under a single grid cell (8 px) and under one
/// screen point at every display size this daemon runs at.
final class PaintSmoother {
    /// Most an edge's SIZE component may move per frame, in grid cells.
    /// Translation is not subject to it (rule 1).
    ///
    /// RESTATED AS A RATE 2026-09-08 (one of the six live-paint constants the
    /// receipt audit left as a KNOWN GAP). Both halves of the original receipt
    /// reasoned in seconds or in cells-per-second, and neither survived a
    /// change of fps as a fixed per-frame count:
    ///
    ///   LOWER (a rate): "at 8 px/frame a 115 px stale edge — the worst
    ///   iteration-1 case, 14.375 cells — converges in 15 frames = 0.5 s,
    ///   inside the 1.0 s tightness-recovery budget". 1 cell/frame at 30 fps IS
    ///   30 cells/s = 240 px/s, and it is the RATE that buys the 0.5 s, not the
    ///   1. Held fixed at 1 cell/frame the same edge takes 0.96 s at 15 fps —
    ///   inside the 1.0 s budget by 4%, i.e. no margin at all.
    ///
    ///   UPPER (a per-frame visual limit, so genuinely fps-invariant): the
    ///   spec's no-pops criterion allows 1 cell on steady content and 2 during
    ///   post-motion recovery. Everything this cap governs is a recovery — a
    ///   stale edge walking back to its target — so 2 cells/frame is the
    ///   ceiling, and it is a ceiling on the FRAME, not on the second.
    ///
    /// `capCellsPerSec / fps` clamped by `capCellsPopLimit` therefore keeps the
    /// convergence at 0.48 s at every fps from 15 up (exactly 1 cell/frame at
    /// 30, exactly 2 at 15) and 0.72 s at the 10 fps floor, where the pop limit
    /// binds first. 30.0/30.0 is 1.0 exactly in IEEE double, so the frozen gate
    /// baseline — which runs through this smoother — cannot move. Pinned and
    /// swept in `PerfTier.selftest`.
    static let capCellsPerSec: CGFloat = 30
    static let capCellsPopLimit: CGFloat = 2
    static func capCells(fps: Int) -> CGFloat {
        min(capCellsPopLimit, capCellsPerSec / CGFloat(fps))
    }
    /// The worst stale edge on record, in grid cells (115 px at the 8 px cell
    /// this scene's grid resolves to), and how long the cap above takes to walk
    /// it back to target. Named rather than left in prose because two other
    /// receipts are written against this number — `CoverOwnership`'s
    /// `pinRemeasureUpdates` derives its second term from it, and
    /// `PerfTier.selftest` asserts the 1.0 s tightness-recovery budget with it.
    /// 0.479 s at every fps from 15 up (the rate binds); 0.719 s at the 10 fps
    /// floor, where the no-pop clamp binds instead.
    static let worstStaleCells: CGFloat = 115.0 / 8.0
    static func convergeSecs(fps: Int) -> Double {
        Double(worstStaleCells / capCells(fps: fps)) / Double(fps)
    }
    /// Log/paint lattice. Must match FrameLogger.paintedQuantum (1e-4 since
    /// iteration 4, 0.128 px in x): the smoother is the last thing to touch a
    /// media rect before it is both painted and logged, so a coarser lattice
    /// here would silently cap the log's resolution at its own.
    private static let quantum: CGFloat = 0.0001
    /// Sub-pixel deadband, in frame pixels: a target edge closer than this to
    /// where the edge already is is not a move, it is noise, and the edge
    /// holds. Compared against the CURRENT painted edge, not against the last
    /// move, so real sub-pixel drift accumulates and fires the frame it
    /// crosses the band (the same structure as rule 3).
    ///
    /// Receipt: EdgeSnap returns integer pixel positions, so the smallest edge
    /// move a real media-rect change can produce is 1 px (1.01 px after the
    /// overlay's 1% media pad) — 0.5 px is half of the smallest thing there is
    /// to see, and nothing real can hide under it. What it removes is measured:
    /// on drag-media f538, pixel-static truth, the tracked rect wobbles 0.07 px
    /// out and back in one frame (detection-box noise reaching the region rect),
    /// which the scorer's zero-tolerance steady_stillness counts as a full
    /// reversal cycle. Until iteration 4 the 1e-3 paint lattice hid it by
    /// accident; the finer lattice this criterion needs makes an explicit
    /// deadband the honest way to keep it suppressed.
    private static let deadbandPx: CGFloat = 0.5
    /// Consecutive frames an outward size move must be asked for before it
    /// applies, when safety does not require it this frame (rule 4). 2 is the
    /// smallest number that can tell a flick from a move at all, and it is
    /// bought with exactly one frame (33 ms) of margin lag at the start of a
    /// real grow.
    ///
    /// What it actually removes, counted from the live evidence rather than
    /// asserted (runs/v2-live-video/daemon.jsonl, 1811 rows / 60 s, tracked
    /// left edge): eight outward-and-back excursions of 8.96 px, of widths
    /// 1, 1, 2, 2, 2, 3, 4 and 2 log rows. Derived from the rule, NOT measured
    /// against those pixels (no fixture reproduces the flick, and the live
    /// recording already has the cover painted into it, so it cannot be
    /// replayed): the two 1-row excursions cannot move the painted edge at all,
    /// because the target is back where it started before the second frame of
    /// demand, and each of the rest loses its first frame. It does NOT remove
    /// the multi-row ones, which is why this needs a live run to confirm; a
    /// 3-frame gate would (six of the eight), at 100 ms of margin lag and
    /// ~12 px of the ~15 px standing margin on a 4 px/frame grow, which is too
    /// much to spend without a live re-run to confirm the trade. Raise it only
    /// with that measurement.
    private static let outwardPersist = 2

    private struct State {
        var rect: CGRect
        /// Per edge (left, right, bottom, top — the order `advance` is called
        /// in): direction of this edge's last size move, +1 inward, -1 outward,
        /// 0 for an edge that has not moved yet. See rule 3.
        var lastDir: [Int] = [0, 0, 0, 0]
        /// Per edge: consecutive frames this edge has asked for a non-required
        /// outward move without getting it. See rule 4.
        var outHeld: [Int] = [0, 0, 0, 0]
    }

    /// Set once by `Pipeline` from the effective fps, before the first frame.
    /// The defaults are the 30 fps values, so a path that never sets them —
    /// `--process`, the algorithm loop — behaves exactly as this class did
    /// before these two were derived.
    /// NAME NOTE: this instance value deliberately shares its name with the
    /// static derivation it is set from. They are in different scopes, so
    /// this compiles and a mistaken `Self.capCells` would be a type error
    /// rather than a silent wrong value — but inside these state machines
    /// read the bare name as "the resolved value for THIS run".
    var capCells = PaintSmoother.capCells(fps: 30)
    var leadFrames = OverlayManager.leadFrames(
        fps: 30, inferP95Ms: PerfTier.standard.inferP95Ms)

    private var last: [Int: State] = [:]
    private var cellX: CGFloat = 1.0 / 160
    private var cellY: CGFloat = 1.0 / 160
    /// `deadbandPx` in normalized units on each axis.
    private var deadX: CGFloat = 0
    private var deadY: CGFloat = 0

    /// A grid cell is SQUARE in pixels (MotionBoxes.sampleGreen steps by
    /// width/160 in both axes), so it is 1/160 of the frame width in x and
    /// aspect times that in y.
    func setFrameSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        cellX = 1.0 / CGFloat(MotionBoxes.gridWidth)
        cellY = cellX * CGFloat(width) / CGFloat(height)
        deadX = Self.deadbandPx / CGFloat(width)
        deadY = Self.deadbandPx / CGFloat(height)
    }

    /// Panic/reset: forget every region's painted position so a resumed run
    /// cannot settle from a rect that is minutes old.
    func reset() {
        last.removeAll()
    }

    /// One call per frame, in region order. Prunes state for regions that are
    /// gone (tracker ids are monotonic and never reused).
    ///
    /// `mustCover` are this frame's raw blocked detection boxes, BEFORE the
    /// media expansion — the spec invariant "detection always covered" is about
    /// those, and everything the painted rect carries beyond them is margin
    /// (rules 4 and 5). Empty is legal and means "no safety floor this frame";
    /// there is deliberately NO default, so a new call site cannot silently
    /// disable the safety floor by forgetting to pass one.
    func rects(for regions: [TrackedRegion], mustCover: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        out.reserveCapacity(regions.count)
        var live: [Int: State] = [:]
        live.reserveCapacity(regions.count)
        for region in regions {
            let target = OverlayManager.paintRect(for: region, leadFrames: leadFrames)
            guard region.mediaHeld else {
                out.append(target)
                continue
            }
            let need = requirement(for: region, mustCover: mustCover)
            var state = last[region.id] ?? State(rect: quantize(target))
            if last[region.id] != nil {
                state.rect = settle(&state, to: target, need: need)
            }
            live[region.id] = state
            out.append(state.rect)
        }
        last = live
        return out
    }

    private static let unitSquare = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The part of `mustCover` this region is responsible for: the boxes whose
    /// CENTRE its rect holds — the same ownership test main.swift uses to decide
    /// which media box expands which detection. Centre, not full containment:
    /// the tracker's cover-first union does guarantee a matched region's rect
    /// contains its detection, but only up to CGRect's origin+size rounding, and
    /// a containment test that misses by one ULP silently switches this safety
    /// floor off (measured, i5-b scroll-after-still f125: tracked top 0.872
    /// against a detection top of 0.873 in the log, `contains` false, the
    /// backstop skipped and 0.5 px of detection left uncovered). Clamped like
    /// `paintRect` does, so an off-screen detection cannot demand a rect the
    /// overlay could not paint anyway.
    private func requirement(for region: TrackedRegion, mustCover: [CGRect]) -> CGRect {
        var need = CGRect.null
        for box in mustCover
        where region.rect.contains(CGPoint(x: box.midX, y: box.midY)) {
            need = need.isNull ? box : need.union(box)
        }
        guard !need.isNull else { return .null }
        let clamped = need.intersection(Self.unitSquare)
        return clamped.isNull ? .null : clamped
    }

    private func quantize(_ rect: CGRect) -> CGRect {
        func q(_ v: CGFloat) -> CGFloat { (v / Self.quantum).rounded() * Self.quantum }
        let x = q(rect.minX), y = q(rect.minY)
        return CGRect(x: x, y: y, width: q(rect.maxX) - x, height: q(rect.maxY) - y)
    }

    /// Lattice-align a rect OUTWARD (floor the low edges, ceil the high ones).
    /// The nearest-lattice `quantize` can round an edge up to half a quantum
    /// inward, which is fine for the smoothed rect and not fine for the safety
    /// floor of rule 5.
    private func quantizeOutward(_ rect: CGRect) -> CGRect {
        func down(_ v: CGFloat) -> CGFloat { (v / Self.quantum).rounded(.down) * Self.quantum }
        func up(_ v: CGFloat) -> CGFloat { (v / Self.quantum).rounded(.up) * Self.quantum }
        let x = down(rect.minX), y = down(rect.minY)
        return CGRect(x: x, y: y, width: up(rect.maxX) - x, height: up(rect.maxY) - y)
    }

    /// Rule 5: smoothing may cost margin, never coverage.
    private func covering(_ rect: CGRect, _ need: CGRect) -> CGRect {
        need.isNull ? rect : rect.union(quantizeOutward(need))
    }

    private func settle(_ state: inout State, to raw: CGRect, need: CGRect) -> CGRect {
        let prev = state.rect
        // Sub-pixel deadband, per edge, before anything else looks at the
        // target: an edge that has not really moved must not contribute a
        // translation either (rule 1 applies translations uncapped).
        func held(_ from: CGFloat, _ to: CGFloat, _ band: CGFloat) -> CGFloat {
            abs(to - from) < band ? from : to
        }
        let tLeft = held(prev.minX, raw.minX, deadX)
        let tRight = held(prev.maxX, raw.maxX, deadX)
        let tBottom = held(prev.minY, raw.minY, deadY)
        let tTop = held(prev.maxY, raw.maxY, deadY)
        guard tRight > tLeft, tTop > tBottom else { return covering(quantize(raw), need) }
        let target = CGRect(
            x: tLeft, y: tBottom, width: tRight - tLeft, height: tTop - tBottom)
        // Split each axis into TRANSLATION (both edges moving the same way) and
        // SIZE change (whatever each edge still wants after the translation).
        // The translation is the SMALLER of the two same-direction moves, so it
        // is the part of the update that provably moves the whole rect and
        // cannot shrink it. Receipt for splitting rather than adding the
        // opposite edge's outward move to the cap (iter2-e, which added it): a
        // symmetric SHRINK then gets the opposite edge's whole inward move as
        // budget, and a box re-acquisition moved the painted edge 58.9 px in
        // one frame.
        func translation(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            guard a != 0, b != 0, (a > 0) == (b > 0) else { return 0 }
            return abs(a) < abs(b) ? a : b
        }
        let tx = translation(target.minX - prev.minX, target.maxX - prev.maxX)
        let ty = translation(target.minY - prev.minY, target.maxY - prev.maxY)
        // `shift` is this axis's translation, applied in full; what remains is
        // the size component, signed so positive `inward` means "this edge
        // wants to move toward the rect's interior".
        func advance(_ slot: Int, _ from: CGFloat, _ to: CGFloat, inwardSign: CGFloat,
                     cell: CGFloat, shift: CGFloat, required: Bool) -> CGFloat {
            let base = from + shift
            let cap = capCells * cell
            let inward = (to - base) * inwardSign
            // A frame that asks for nothing neither proves nor cancels an
            // outward run, so the counter is left exactly as it is.
            guard inward != 0 else { return base }
            let dir = inward > 0 ? 1 : -1
            if dir < 0 {
                // Outward. A required move applies AND arms the run — safety
                // never waits, and a run that safety started must not make the
                // margin behind it wait either. A non-required one has to prove
                // itself over `outwardPersist` consecutive asking frames.
                //
                // The counter is NOT cleared once it fires: "2 consecutive
                // frames" is a gate on the START of an outward run, not a rate
                // limit inside it. Clearing it on the applying frame made a
                // sustained grow alternate defer/apply — measured on i5-b's
                // drag, painted 0.0 px against truth 11 px at f631 then 23.0 px
                // against 10 px at f632, motion_smoothness p95 1.0219 cells
                // over a 1.0 limit. A deferred move is also not a move, so
                // lastDir stays where it is — writing it there would desync
                // rule 3's reversal test with a direction the edge never took.
                if required {
                    state.outHeld[slot] = Self.outwardPersist
                } else {
                    state.outHeld[slot] = min(state.outHeld[slot] + 1, Self.outwardPersist)
                    if state.outHeld[slot] < Self.outwardPersist { return base }
                }
            } else {
                state.outHeld[slot] = 0  // an inward demand ends the outward run
            }
            // INWARD reversal under one cell: jitter (rule 3). The comparison
            // is against the TARGET, not against the last move, so a real drift
            // accumulates and fires the moment it reaches a cell. Outward
            // reversals are rule 4's business, not this one's.
            if dir > 0, dir != state.lastDir[slot], state.lastDir[slot] != 0, abs(inward) < cell {
                return base
            }
            state.lastDir[slot] = dir
            return base + inwardSign * (inward > 0 ? min(inward, cap) : max(inward, -cap))
        }
        // Rule 4's "required" is per edge and measured against the PREVIOUS
        // painted rect, not against `base`: an uncapped translation has already
        // moved `base`, so an edge whose safety floor sits comfortably inside
        // the rect that was actually painted last frame can still read as
        // outward relative to `base`, and that one may wait.
        let needed = !need.isNull
        let left = advance(0, prev.minX, target.minX, inwardSign: 1, cell: cellX, shift: tx,
                           required: needed && need.minX < prev.minX)
        let right = advance(1, prev.maxX, target.maxX, inwardSign: -1, cell: cellX, shift: tx,
                            required: needed && need.maxX > prev.maxX)
        let bottom = advance(2, prev.minY, target.minY, inwardSign: 1, cell: cellY, shift: ty,
                             required: needed && need.minY < prev.minY)
        let top = advance(3, prev.maxY, target.maxY, inwardSign: -1, cell: cellY, shift: ty,
                          required: needed && need.maxY > prev.maxY)
        guard right > left, top > bottom else { return covering(quantize(target), need) }
        return covering(
            quantize(CGRect(x: left, y: bottom, width: right - left, height: top - bottom)),
            need)
    }
}

/// One black rectangle + optional centered label. Region covers and curtains
/// (including the Stage Manager strip cover) share this class.
final class RegionLayer {
    let shape = CALayer()
    /// Read by `--ui-selftest` "cover label"; written only by `update`.
    let label = CATextLayer()

    /// Longest-that-fits ladder, fixed 13 pt medium, no auto-shrink (owner
    /// report 2026-09-09: the strip thumbnail showed the black cover with no
    /// text). Text widths are MEASURED at runtime from the font, never
    /// hardcoded: "Content blocked" is ~102 pt at this size and the strip
    /// thumbnail cover is 92-101 pt wide (receipts at `Curtain.minCurtainSize`
    /// "~92x129 pt" and shielded_scenario.sh's measured 101x121), so the long
    /// form never fit there and the old single-string rule hid the label.
    /// "Blocked" (~50 pt) fits every thumbnail either receipt measured.
    static let labelLadder = ["Content blocked", "Blocked"]
    /// Curtains (whole-window covers) lead with the way out. ⌘W, not ⌘Q: it
    /// closes the covered tab or window, not the whole app and every other
    /// tab in it. A click first because the keys go to the frontmost window,
    /// which may not be the covered one.
    /// COPY 2026-10-20 (owner), replacing 2026-10-18's "click here, then
    /// press ⌘W to close": covers are click-through, so "click here" sent the
    /// click to the covered content itself (a link, a play button). The
    /// title bar is outside the curtain (`Curtain.chromeStripPt` leaves the
    /// window's top strip bare), so clicking it focuses the window and
    /// touches nothing covered. Only then: a curtain over the WHOLE window
    /// (fullscreen, a short window, Quick Look; `Curtain.contentRect`) has
    /// no title bar to click, so it falls back to the plain ladder
    /// (`titleBarBare`, code review 2026-10-29). Shorter, too: `--ui-selftest` "cover label"
    /// prints the measured width and pins its range.
    /// Region covers keep the short ladder: they sit on images, not windows.
    static let curtainHint = "Content blocked — click the title bar, then press ⌘W"
    static let curtainLadder = [curtainHint] + labelLadder
    static let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Margin the text keeps from the cover's edge, per side, both axes.
    /// DERIVED: 4 pt per side is the old `width < text + 8` rule (unchanged in
    /// value since the first overlay) — it keeps glyph antialiasing off the
    /// cover's edge and is the one number that makes the invariant below hold.
    /// INVARIANT: the label never draws outside the black rect — a string is
    /// picked only if it fits inside the frame minus this margin, else hidden.
    static let labelPadPt: CGFloat = 4
    static let labelSizes: [(text: String, size: CGSize)] = measured(labelLadder)
    static let curtainLabelSizes: [(text: String, size: CGSize)] = measured(curtainLadder)
    static func measured(_ ladder: [String]) -> [(text: String, size: CGSize)] {
        ladder.map { ($0, ($0 as NSString).size(withAttributes: [.font: labelFont])) }
    }

    /// The longest ladder entry that fits a cover of this size, nil when even
    /// the shortest does not (or the cover is shorter than one line).
    static func labelText(forWidth width: CGFloat, height: CGFloat, curtain: Bool = false) -> String? {
        let pad = 2 * labelPadPt
        return (curtain ? curtainLabelSizes : labelSizes).first {
            $0.size.width + pad <= width && $0.size.height + pad <= height
        }?.text
    }

    /// A curtain's ladder starts with `curtainHint`.
    let curtain: Bool
    /// The curtain leaves the window's title bar uncovered, so the hint's
    /// "click the title bar" names something on screen. Overlay sets it from
    /// the strip delta before each `update`.
    var titleBarBare = true

    init(scale: CGFloat, curtain: Bool = false) {
        self.curtain = curtain
        shape.backgroundColor = NSColor.black.cgColor
        label.font = Self.labelFont
        label.fontSize = Self.labelFont.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = scale  // crisp text on Retina
        shape.addSublayer(label)
    }

    func update(frame: CGRect) {
        shape.frame = frame
        guard let text = Self.labelText(forWidth: frame.width, height: frame.height,
                                        curtain: curtain && titleBarBare),
            let s = Self.curtainLabelSizes.first(where: { $0.text == text })?.size
        else {
            label.isHidden = true
            return
        }
        if label.string as? String != text { label.string = text }
        label.frame = CGRect(
            x: (frame.width - s.width) / 2, y: (frame.height - s.height) / 2,
            width: s.width, height: s.height)
        label.isHidden = false
    }
}
