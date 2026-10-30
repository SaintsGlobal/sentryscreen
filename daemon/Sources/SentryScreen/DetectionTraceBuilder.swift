import CoreGraphics
import Foundation

// DETECTION VIEW trace builder (tuning tool). Turns one `Pipeline.step`'s
// locals into a `DetectionTrace` (DetectionTrace.swift): per raw box, the
// policy stage that decided it (`TuningPolicy.verdicts`, a mirror of
// `TuningPolicy.filter`), what the region tracker did with it, and what the
// curtain walk did with it (`CurtainTraceRecorder`). Pure and static: every
// input is passed in, nothing is read from the pipeline, and no detector or
// window-server work happens here except the memoized app-name lookup.

extension TuningPolicy {
    /// One raw box's policy decision, in `filter`'s stage order.
    struct Verdict: Equatable {
        /// After covered-beats-exposed demotion.
        let label: String
        let demotion: DetectionTrace.Demotion?
        /// Short side in screen points; nil when the screen is 0×0.
        let sidePt: Double?
        let policy: DetectionTrace.PolicyOutcome

        var passes: Bool {
            switch policy {
            case .passes, .kept: return true
            default: return false
            }
        }
    }

    /// The per-box mirror of `filter` followed by the step's ROI predicate:
    /// demotion on the raw list, then the flat threshold (`blocks`), then the
    /// size floor (`minBox`), then the staircase (`thresholdStep`), then the
    /// ROI centre test. The boxes whose verdict `passes`, in order, are
    /// exactly `filter(...).blocked` narrowed by the ROI — asserted
    /// elementwise over seeded random sets by `--ui-selftest`
    /// "detection-trace". A class with no rule (a benign label, or a face
    /// outside `--block-faces`) is `notPolicyClass`; a covered class under
    /// the standard policy is `classOffInPolicy`, not a threshold miss.
    func verdicts(
        _ raw: [Detection], mode: PolicyMode, blockFaces: Bool, screen: CGSize, roi: CGRect?,
        tracked: CoveredInput = .init()
    ) -> [Verdict] {
        let (detections, _) = demoteCovered(raw)
        return detections.indices.map { i in
            let d = detections[i]
            var demotion: DetectionTrace.Demotion?
            if d.label != raw[i].label {
                let overlap = raw.filter { $0.label == d.label }
                    .map { Self.overlapOfSmaller(raw[i].box, $0.box) }.max() ?? 0
                demotion = .init(to: d.label, overlap: overlap, minOverlap: coveredOverlap)
            }
            let side = Self.sidePt(d.box, screen: screen)
            return Verdict(
                label: d.label, demotion: demotion, sidePt: side,
                policy: outcome(
                    d, side: side, mode: mode, blockFaces: blockFaces, screen: screen, roi: roi,
                    tracked: tracked))
        }
    }

    private func outcome(
        _ d: Detection, side: Double?, mode: PolicyMode, blockFaces: Bool, screen: CGSize, roi: CGRect?,
        tracked: CoveredInput
    ) -> DetectionTrace.PolicyOutcome {
        // The highest start floor a hysteresis keep let this box under.
        var keptUnder: Float?
        if !blocks(d, mode: mode, blockFaces: blockFaces) {
            if let t = startThreshold(d.label, mode: mode, blockFaces: blockFaces),
                keeps(d, floor: t, tracked: tracked) {
                keptUnder = t
            }
        }
        guard keptUnder != nil || blocks(d, mode: mode, blockFaces: blockFaces) else {
            if let r = standard[d.label] { return .belowThreshold(threshold: r.threshold) }
            if let r = strict[d.label] {
                return mode == .strict ? .belowThreshold(threshold: r.threshold) : .classOffInPolicy(mode: mode)
            }
            if blockFaces, let t = Self.faceThresholds[d.label] { return .belowThreshold(threshold: t) }
            return .notPolicyClass
        }
        var unmeasured = false
        switch minBox(d, screen: screen) {
        case .passes: break
        case .unmeasured: unmeasured = true
        case .dropped:
            let r = rule(for: d.label)
            return .minBox(sidePt: side, minBoxPt: r?.minBoxPt ?? 0, minBoxFraction: r?.minBoxFraction ?? 0)
        }
        // The floor that decided: the flat threshold `blocks` used, or the
        // staircase bracket above it.
        var floor = standard[d.label]?.threshold ?? strict[d.label]?.threshold
            ?? Self.faceThresholds[d.label] ?? 0
        switch thresholdStep(for: d.label, sidePt: side) {
        case .none: break
        case .unmeasured: unmeasured = true
        case let .floor(t):
            if d.confidence < t, keeps(d, floor: t, tracked: tracked) {
                keptUnder = t
            } else if d.confidence < t {
                let r = rule(for: d.label)
                let step = r?.thresholdSteps.last { (side ?? 0) >= $0.minPt }
                return .thresholdStep(floor: t, stepMinPt: step?.minPt ?? 0, base: r?.threshold ?? 0)
            }
            floor = t
        }
        if let roi, !roi.contains(CGPoint(x: d.box.midX, y: d.box.midY)) { return .outsideROI }
        if let k = keptUnder { return .kept(start: k, keep: keepFloor(k), sizeUnmeasured: unmeasured) }
        return .passes(floor: floor, sizeUnmeasured: unmeasured)
    }
}

enum DetectionTraceBuilder {
    /// TRIPWIRE on boxes per trace (the overlay draws at most this many and
    /// says "+N not drawn"). MEASURED 2026-09-24 from run.jsonl text only
    /// (per-frame `detections` arrays; no image opened): an M1 Mac's own log
    /// peaked at 24 raw boxes/frame over 1,980 logged frames (19–23 in 381 of
    /// them); the repo's live logs peak at 26 (daemon/testdata/livespot-2026-08-19,
    /// 1,649 frames) and 17 (livestrict-bing, 1,259 frames); a test Mac's logs
    /// held no frame records (rollout reset). CAVEAT: lean logging writes a
    /// frame only when something policy-relevant is on it, so benign-only
    /// frames (faces) are not in the sample. 64 is ~2.5× the measured peak.
    /// The detector itself has no output cap (receipt at
    /// `Tracker.mergeDetections`), so this is a drawing budget, not a
    /// detector bound. Exceeding it is counted in `boxesOverflow`, never
    /// dropped silently.
    static let maxBoxes = 64

    /// TRIPWIRE on one frame's trace work on detectQueue, ms: the curtain
    /// recorder's note arguments (`CurtainTraceRecorder.costMs`),
    /// `Curtain.traceWindows` and `build`. `Stats.traceMs` (the HUD's
    /// "trace" figure) also includes the app-name lookups; the tripwire
    /// does not, because a new window's first lookup is cold — MEASURED
    /// 4.97 ms live on a test Mac 2026-09-24 (4.0–4.2 ms in the 2026-08-22
    /// microbenchmark) — and has its own budget, `WindowOwner.p95BudgetMs`.
    /// MEASURED on an M1 Mac, -O build
    /// arm64, `--ui-selftest` "detection-trace": `build` alone, 500 builds
    /// x five runs under load 7.9–9.5, stress (maxBoxes + 5) p95
    /// 0.055–0.211 / max 0.079–0.664 ms; the whole work per frame of the
    /// scripted two-window curtain pipeline (recorder notes + traceWindows
    /// + build, 40 frames, two runs, load 6.3–7.3) p95 0.019–0.024 / max
    /// 0.031–0.062 ms. A warm
    /// app-name lookup is p95 0.16 ms, once per new window (receipt at
    /// `WindowOwner.p95BudgetMs`). DERIVED: 2 ms is 3x the worst single
    /// measurement and 6 % of the 33 ms detector frame at 30 fps. Over
    /// budget is loud — the HUD shows `traceMs` and the pipeline writes one
    /// `detection-view` record per episode — and never turns the view off.
    static let traceBudgetMs = 2.0

    /// Everything one build reads, passed explicitly. Rects are in the
    /// pipeline's own spaces: detections, painted rects and pending rects
    /// normalized bottom-left (Vision); curtain window frames in CGWindowList
    /// points (top-left) against `display`.
    struct Inputs {
        var seq: UInt64
        var capturedAt: CFAbsoluteTime
        var screenPt: CGSize
        var display: CGRect
        var policy: PolicyMode
        var coverMode: String
        var tuning: TuningPolicy
        var tuningSource: String
        var blockFaces: Bool
        var roi: CGRect?
        var detectorFailed = false
        /// Detector order; boxes at `syntheticFrom` and after are synthetic.
        var raw: [Detection] = []
        var syntheticFrom = Int.max
        /// "Show weak detections": boxes under `conf`, after raw and
        /// synthetic in the trace. Never in `raw`, so never in the mirror.
        var weak: [Detection] = []
        /// The detector floor the weak boxes are under (`--conf`).
        var conf: Float = 0.25
        /// What was covered going into the frame (`TuningPolicy.keepGap`).
        var tracked = TuningPolicy.CoveredInput()
        /// Indices into the step's `blocked` list that reached the region
        /// tracker (`Pipeline.regionInputIndices`); the rest sat under a
        /// painted curtain.
        var regionSourceIndices: [Int] = []
        var regions: [TrackedRegion] = []
        /// `painted[i]` is `regions[i]`'s paint rect.
        var painted: [CGRect] = []
        var pending: [(rect: CGRect, label: String, seen: Int, needed: Int)] = []
        /// nil outside curtain mode, and on a frame whose curtain update did
        /// not run (`Pipeline.curtainRects`' early return).
        var curtainWalk: DetectionTrace.CurtainWalk?
        var curtainOutcomes: [(blockedIndices: [Int], outcome: DetectionTrace.CurtainOutcome)] = []
        var windows: [(id: CGWindowID, frame: CGRect, state: DetectionTrace.CurtainWindow.State)] = []
        var stats: DetectionTrace.Stats
        /// The zoom tile this frame ran (`ZoomTiles.region`, Vision
        /// bottom-left); nil with zoomTiles off.
        var zoomTile: CGRect?
    }

    struct Output {
        let trace: DetectionTrace
        /// Boxes the mirror says pass, against the step's own `blocked`
        /// count. They differ only if `verdicts` drifted from `filter`; the
        /// pipeline reports it by name.
        let mirrorBlocked: Int
    }

    static func build(
        _ input: Inputs, builtAt: CFAbsoluteTime, appName: (CGWindowID) -> String?
    ) -> Output {
        let verdicts = input.tuning.verdicts(
            input.raw, mode: input.policy, blockFaces: input.blockFaces,
            screen: input.screenPt, roi: input.roi, tracked: input.tracked)
        // raw index -> index in the step's blocked list.
        var blockedIndex: [Int?] = Array(repeating: nil, count: verdicts.count)
        var blocked = 0
        for (i, v) in verdicts.enumerated() where v.passes {
            blockedIndex[i] = blocked
            blocked += 1
        }
        let reachedRegion = Set(input.regionSourceIndices)
        var curtainOf: [Int: DetectionTrace.CurtainOutcome] = [:]
        for note in input.curtainOutcomes {
            for b in note.blockedIndices { curtainOf[b] = note.outcome }
        }
        var unattributed = 0
        if input.curtainWalk == .ran {
            for b in blockedIndex.compactMap({ $0 }) where curtainOf[b] == nil { unattributed += 1 }
        }
        let kept = min(input.raw.count, maxBoxes)
        var boxes: [DetectionTrace.Box] = []
        boxes.reserveCapacity(kept)
        for i in 0..<kept {
            let d = input.raw[i]
            let v = verdicts[i]
            var region: DetectionTrace.RegionOutcome?
            var curtain: DetectionTrace.CurtainOutcome?
            if let b = blockedIndex[i] {
                region = regionOutcome(d.box, reached: reachedRegion.contains(b), input: input)
                switch input.curtainWalk {
                case .ran?: curtain = curtainOf[b]
                case .skipped?: curtain = .walkSkipped
                default: break
                }
            }
            boxes.append(DetectionTrace.Box(
                index: i, synthetic: i >= input.syntheticFrom, rawLabel: d.label, label: v.label,
                confidence: d.confidence, rect: topLeft(d.box), sidePt: v.sidePt,
                demotion: v.demotion, policy: v.policy, region: region, curtain: curtain,
                recheckFrom: d.recheckFrom))
        }
        // Weak boxes last, so the drawing cap cuts them before any box the
        // policy saw.
        let keptWeak = min(input.weak.count, maxBoxes - kept)
        for (j, d) in input.weak.prefix(keptWeak).enumerated() {
            boxes.append(DetectionTrace.Box(
                index: input.raw.count + j, synthetic: false, rawLabel: d.label, label: d.label,
                confidence: d.confidence, rect: topLeft(d.box),
                sidePt: TuningPolicy.sidePt(d.box, screen: input.screenPt),
                demotion: nil, policy: .weak(conf: input.conf), region: nil, curtain: nil))
        }
        let windows: [DetectionTrace.CurtainWindow] = input.windows.compactMap { w in
            guard let frame = normalizedTopLeft(w.frame, display: input.display) else { return nil }
            return DetectionTrace.CurtainWindow(id: w.id, app: appName(w.id), frame: frame, state: w.state)
        }
        let trace = DetectionTrace(
            seq: input.seq, capturedAt: input.capturedAt, builtAt: builtAt, screenPt: input.screenPt,
            policy: input.policy, coverMode: input.coverMode, tuning: input.tuning,
            tuningSource: input.tuningSource, detectorFailed: input.detectorFailed, boxes: boxes,
            boxesOverflow: input.raw.count - kept + input.weak.count - keptWeak, walkUnattributed: unattributed,
            walk: input.curtainWalk ?? .notCurtainMode, windows: windows, stats: input.stats,
            zoomTile: input.zoomTile.map(topLeft))
        return Output(trace: trace, mirrorBlocked: blocked)
    }

    /// Spatial, by the box's centre (the tracker merges and lerps, so no
    /// index survives into a region): inside a painted region rect →
    /// covered; inside a pending entry's rect → waiting for entry frames;
    /// neither → reached the tracker and is not covered this frame. A box
    /// that did not reach the tracker sat under a painted curtain
    /// (`Pipeline.regionInput`).
    static func regionOutcome(
        _ box: CGRect, reached: Bool, input: Inputs
    ) -> DetectionTrace.RegionOutcome {
        guard reached else { return .underCurtain }
        let centre = CGPoint(x: box.midX, y: box.midY)
        for (region, rect) in zip(input.regions, input.painted) where rect.contains(centre) {
            return .covered(regionID: region.id)
        }
        if let p = input.pending.first(where: { $0.rect.contains(centre) }) {
            return .entryPending(seen: p.seen, needed: p.needed)
        }
        return .notCovered
    }

    /// Vision bottom-left → top-left, both normalized.
    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// CGWindowList points (top-left, global) → normalized top-left over
    /// `display`, clamped; nil when the frame is off the display or the
    /// display is unmeasured.
    static func normalizedTopLeft(_ f: CGRect, display: CGRect) -> CGRect? {
        guard display.width > 0, display.height > 0 else { return nil }
        let r = CGRect(
            x: (f.minX - display.minX) / display.width, y: (f.minY - display.minY) / display.height,
            width: f.width / display.width, height: f.height / display.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.isNull || r.isEmpty ? nil : r
    }
}

/// App names for the trace's curtain windows, memoized per id so a window is
/// looked up (one `CGWindowListCopyWindowInfo`, `WindowOwner.lookup`) once
/// while the view is on. detectQueue only. Bounded by the same receipt as
/// the curtain's own memo, `WindowOwner.cacheLimit` (64): reaching it clears
/// the memo and says so once through `onFull`, never grows it.
final class DetectionTraceAppNames {
    private var memo: [CGWindowID: String] = [:]
    private let lookup: (CGWindowID) -> String?
    var onFull: ((String) -> Void)?

    init(lookup: @escaping (CGWindowID) -> String? = WindowOwner.lookup) {
        self.lookup = lookup
    }

    func name(_ id: CGWindowID) -> String? {
        if let m = memo[id] { return m.isEmpty ? nil : m }
        if memo.count >= WindowOwner.cacheLimit {
            onFull?(
                "app-name memo full at budget WindowOwner.cacheLimit=\(WindowOwner.cacheLimit), "
                + "observed \(memo.count) ids; cleared (fix: DetectionTraceAppNames)")
            memo.removeAll()
        }
        let name = lookup(id)
        memo[id] = name ?? ""
        return name
    }

    var count: Int { memo.count }
}

