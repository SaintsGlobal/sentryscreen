import AppKit
import SwiftUI

// TUNING TOOL — the Settings › Developer tab (curtain false-positive batch
// 3/3, 2026-09-10): the UI over the `parent/tuning.json` bypass.
//
// Two halves, one file:
//   * `TuningReadout` — the pipeline side. detectQueue records every raw
//     detection of a policy class, every box a tuning rule removed, and every
//     curtain event; the UI reads a 60 s snapshot on the settings tick. The
//     UI and the pipeline are one process (main.swift), so nothing tails a
//     file. Since 2026-10-20 the snapshot leads with one ROW PER TRACK (a
//     class in one window at one coarse place on screen), ranked by peak
//     score decayed by age, each row saying what happened to it (curtain,
//     cover, which rule removed it, or under its floor).
//   * `UIDevTuning` — the UI side (main thread). Holds the draft policy the
//     sliders edit, writes the tuning file atomically with the parent/ file
//     contract (0660, the directory's group), and shows the agent's echo:
//     `AppDelegate.pollTuningFile` hands every outcome of its 1 Hz poll to
//     `noteOutcome`, so "applied HH:MM:SS" is the same record the
//     `"event":"tuning"` line was written from, never a guess.

/// The pipeline's ring of tuning-relevant events. Writers: detectQueue
/// (`record`, `recordCurtain`); reader: the main thread (`snapshot`). One
/// lock, held for microseconds.
final class TuningReadout {
    /// One raw detection of a policy class. `sidePt` is the shorter side in
    /// screen points (nil when the screen size is unknown, `--replay`).
    struct Hit {
        let at: Double
        let label: String
        let conf: Float
        let sidePt: Double?
        /// The window the curtain CREDITED this box to on this frame
        /// (`Curtain.onAttribution`); nil when it was not credited (not
        /// blocked, a walk-skipped frame, no curtain in this cover mode).
        var windowID: CGWindowID? = nil
        /// What the policy did with the box (never `.curtain`: a drop is a
        /// track's fate, not one box's). nil: a box no row shows.
        var status: TrackRow.Status? = nil
        /// Capture time of the box's frame (`at` is when it was recorded,
        /// which is what the 60 s window is measured in).
        var frameAt: Double? = nil
    }

    /// ONE ROW PER TRACK (2026-10-20): a policy class in one window at one
    /// coarse place on screen (`TrackKey`), alive while hits keep arriving,
    /// gone `windowSecs` after its last hit. Rows hold labels, numbers and
    /// the app name only — no window title, no pixels.
    struct TrackRow: Equatable, Identifiable {
        /// What happened to the track, most consequential first.
        enum Status: Equatable {
            /// A curtain drop's evidence included this track's boxes
            /// (`Curtain.onDrop` source indices). Sticky for the track's life.
            case curtain
            /// At least one box blocked (region / media cover, or a curtain hit).
            case covered
            /// Never blocked; the LAST rule that removed a box, in the words a
            /// person edits: "covered-beats-exposed", "minBoxPt",
            /// "minBoxFraction", "size step", "outside ROI".
            case removed(String)
            /// Never blocked, never removed by a rule: under its floor.
            case below

            var symbol: String {
                switch self {
                case .curtain: return "✓"
                case .covered: return "◼"
                case .removed: return "⊘"
                case .below: return "○"
                }
            }

            var text: String {
                switch self {
                case .curtain: return "curtain dropped"
                case .covered: return "covered"
                case let .removed(rule): return "removed by \(rule)"
                case .below: return "below floor"
                }
            }

            /// Merging a box into its track: a later box only raises it.
            var weight: Int {
                switch self {
                case .curtain: return 3
                case .covered: return 2
                case .removed: return 1
                case .below: return 0
                }
            }
        }

        let id: String
        let label: String
        let windowID: CGWindowID?
        let app: String?
        let peak: Float
        let latest: Float
        /// The floor the latest box had to clear (flat threshold or its size
        /// step): the mark on the score bar.
        let floor: Float
        let sidePt: Double?
        let status: Status
        let hits: Int
        let ageSecs: Double
        /// `peak × 0.5^(age / rankHalfLifeSecs)`, the sort key.
        let rank: Double

        var code: String { TuningReadout.classCode(label) }
        /// NEAR MISS: the peak sat under its floor by at most `nearMissBand`.
        var nearMiss: Bool { peak < floor && peak >= floor - TuningReadout.nearMissBand }
    }

    /// A curtain drop for the readout: the dropped window and the indices,
    /// into the frame's blocked list, of the boxes that tripped it.
    struct Drop: Equatable {
        let windowID: CGWindowID
        let indices: [Int]
    }

    /// How a box finds its track. Window nil = not credited this frame; such
    /// a box joins a track with the same label and cell in any window
    /// (`mergeTrack`), so the curtain's 1-in-3 walk does not split a subject.
    struct TrackKey: Hashable {
        let label: String
        let windowID: CGWindowID?
        let cellX: Int
        let cellY: Int
        var id: String { "\(label)|\(windowID.map { String($0) } ?? "-")|\(cellX),\(cellY)" }
    }

    struct Track {
        var key: TrackKey
        var app: String?
        var lastAt: Double
        var peak: Float
        var latest: Float
        var floor: Float
        var sidePt: Double?
        var status: TrackRow.Status
        var hits: Int
    }

    /// A box a tuning rule removed or relabelled, with the rule that did it.
    struct Suppression: Equatable {
        enum Rule: String {
            case minBox = "min box"
            case coveredBeatsExposed = "covered-beats-exposed"
            /// `ClassRule.thresholdSteps`: the box cleared the flat
            /// `threshold` and the size floor but not its bracket's floor.
            case thresholdStep = "threshold step"
        }
        let at: Double
        let label: String
        let rule: Rule
        let detail: String
    }

    /// One detector frame's staircase outcome, straight from
    /// `TuningPolicy.Filtered` — kept PER FRAME because a box is not a frame
    /// and a frame is not a curtain drop (receipt at
    /// `TuningPolicy.ClassRule.thresholdSteps`: 898 boxes cut → 40 frames
    /// emptied → 0 drops moved).
    ///
    /// A frame is kept exactly when it blocked something UNDER THE FLAT
    /// POLICY — `blocked` non-empty, or emptied by the staircase — because
    /// `blocked + stepDropped` is the flat policy's blocked set
    /// (`TuningPolicy.filter`). So the kept frames are the denominator of
    /// "N of M blocked frames emptied", and the emptied ones are a subset of
    /// them. Every other frame contributes 0 to all three numbers.
    struct FrameStat {
        let at: Double
        let stepCut: Int
        let emptied: Bool
        /// Blocked under the FLAT policy (`blocked + stepDropped` non-empty).
        let blockedFlat: Bool
        /// `Filtered.minBoxDropped` / `.demoted` for the frame: the
        /// authoritative per-rule totals, summed like `stepCut`.
        let minBoxCut: Int
        let coveredCut: Int
    }

    struct CurtainEvent: Equatable {
        let at: Double
        let action: String
        let windowID: CGWindowID
        let app: String?
    }

    struct ClassStat: Equatable {
        let label: String
        let hits: Int
        let minPt: Double?
        let maxPt: Double?
        let maxConf: Float
    }

    struct Snapshot: Equatable {
        /// Every live track, ranked (`rankHalfLifeSecs`), strongest first.
        var rows: [TrackRow] = []
        /// Tracks lost to `trackCapacity` since launch or the last `reset`.
        var tracksEvicted = 0
        /// Frames whose credited windows / drop indices could not be mapped
        /// back to boxes, because the policy mirror disagreed with the
        /// pipeline's blocked count (`record`). Those boxes still count,
        /// without window or ✓. Shown, never silent.
        var attributionSkipped = 0
        var classes: [ClassStat] = []
        var lastDrop: CurtainEvent?
        var lastCurtain: CurtainEvent?
        var lastSuppression: Suppression?
        var suppressedMinBox = 0
        var suppressedCovered = 0
        /// THE THREE STAIRCASE NUMBERS, never collapsed into one: boxes the
        /// staircase cut, frames it emptied, and the frames that blocked
        /// under the FLAT policy those came out of (`FrameStat`). Only an
        /// EMPTIED frame can change what the curtain sees (it counts frames
        /// with ≥ 1 blocked box), so "boxes cut" alone reads as "the curtain
        /// changed" when it did not. `stepBoxesCut` is `Filtered.stepDropped`
        /// summed over the window — the authoritative count, not the
        /// (episode-capped) suppression ring's — and so are
        /// `suppressedMinBox` / `suppressedCovered` (`minBoxCut` /
        /// `coveredCut` summed): the ring keeps only the LAST suppression's
        /// wording.
        var stepBoxesCut = 0
        var stepFramesEmptied = 0
        var blockedFrames = 0
        /// Hits still inside the window that the ring could not keep
        /// (`capacity`), since launch or the last `reset`; shown, never silent. A hit that aged
        /// out of the window first is pruned, not counted.
        var overflow = 0
        /// The same for the frame ring (`frameCapacity`); shown too.
        var framesOverflow = 0
        var isEmpty: Bool { rows.isEmpty && classes.isEmpty && lastCurtain == nil && lastSuppression == nil }
    }

    /// The readout's window. Requirement (owner brief 2026-09-10): "the last
    /// 60 s" — the same span as the run log's 60 s summary, so a number on
    /// the tab can be checked against the `-- summary:` record.
    static let windowSecs: Double = 60
    /// Hit-ring bound: policy-class RAW detections inside one 60 s window
    /// (every raw box of a policy class is a hit, blocked or not). Both
    /// rings drop entries older than `windowSecs` before they append, so a
    /// long session never fills them with history.
    /// MEASURED 2026-09-25 from the repo's region-mode strict image-grid
    /// logs:
    /// daemon/testdata/livestrict-bing-2026-08-19 holds
    /// 8 policy-class boxes on every frame (10,048 over 1,259 frames);
    /// daemon/testdata/livespot-2026-08-19 peaks at 14 (p95 9) over 1,649 frames;
    /// both reach 29–30 frames in one second. DERIVED: the old 4,096 is
    /// 2.3 boxes/frame at 30 fps (`PerfTier`'s fastest tier), so a busy grid
    /// overflows it in ~17 s; the measured peak held for the whole window is
    /// 14 × 30 × 60 = 25,200, and 32,768 holds that with 30 % headroom.
    /// ASSUMED: those logs are from the NudeNet-era detector, and the YOLOX
    /// student fires at a similar density on the same grids (the detector
    /// has no output cap; receipt at `DetectionTraceBuilder.maxBoxes`).
    /// Cost: ~48 bytes a hit, at most 2 × capacity before a compaction,
    /// tuning tools. An in-window eviction is COUNTED into
    /// `Snapshot.overflow` and printed with this symbol's name and limit.
    static let capacity = 32_768
    /// Frame-ring bound. DERIVED from the same tier: 30 fps × 60 s = 1,800
    /// frames is the most a window can hold (the logs above peak at 30
    /// frames in one second), and only frames that blocked or lost a box to
    /// the staircase are kept, so 2,048 covers the window with 13 % headroom
    /// over the worst case. In-window eviction is COUNTED into
    /// `Snapshot.framesOverflow` and printed, like the hit ring's.
    static let frameCapacity = 2048
    /// RANKING HALF-LIFE: rows sort by `peak × 0.5^(age / this)`, age =
    /// seconds since the track's last hit. 15 s (owner design 2026-10-20).
    /// DERIVED from the 60 s window: four half-lives, so a row about to age
    /// out weighs a sixteenth of its peak, and a fresh 0.75 outranks a 0.95
    /// from 6 s ago (0.95 × 0.76 = 0.72) — strong fresh hits on top, older
    /// ones drifting down. ASSUMED as a reading pace: nothing measured how
    /// fast a person reads the list.
    static let rankHalfLifeSecs: Double = 15
    /// NEAR-MISS band under a class floor. 0.05 (owner design 2026-10-20),
    /// DERIVED from the jitter receipt at `TuningPolicy.keepGap`: the same
    /// content's score moves p50 0.03 / p75 0.09 on a small shift, so a
    /// peak within 0.05 under its floor is one an ordinary jitter can carry
    /// over it — the rows that matter while tuning a floor.
    static let nearMissBand: Float = 0.05
    /// Track cell grid per display axis: a box's centre picks one of 4 × 4
    /// cells, so two subjects in one window are two rows when they sit in
    /// different quarters of the screen. ASSUMED (2026-10-20): coarse on
    /// purpose, because a subject that scrolls across a cell boundary starts
    /// a new row and a finer grid would make that the common case.
    static let trackGrid = 4
    /// TRACK-TABLE CAP. DERIVED (2026-10-20): a key is class × window ×
    /// cell, so one window holds at most 8 policy classes × 16 cells = 128
    /// tracks however long it scrolls; 512 is four windows saturated at once.
    /// Full: the LOWEST-RANKED track is evicted, COUNTED into
    /// `Snapshot.tracksEvicted`, shown on the tab, and logged once per
    /// episode through `onLimit` with this name, the limit and the count.
    static let trackCapacity = 512

    /// A time-ordered ring for one window: entries older than the window
    /// are pruned before each append, and only entries still inside the
    /// window count as evicted when `capacity` is exceeded. `start` marks
    /// the first live entry; the array is compacted once `start` reaches
    /// `capacity`, so an append is amortised O(1). Assumes appends arrive in
    /// time order (one writer, detectQueue).
    struct WindowRing<Element> {
        let capacity: Int
        let time: (Element) -> Double
        private(set) var items: [Element] = []
        private var start = 0
        /// In-window entries lost to `capacity` since the last `reset`.
        private(set) var evicted = 0

        init(capacity: Int, time: @escaping (Element) -> Double) {
            self.capacity = capacity
            self.time = time
        }

        var live: ArraySlice<Element> { items[start...] }

        mutating func append(contentsOf new: [Element], since: Double) {
            while start < items.count && time(items[start]) < since { start += 1 }
            items.append(contentsOf: new)
            let excess = items.count - start - capacity
            if excess > 0 {
                start += excess
                evicted += excess
            }
            if start >= capacity {
                items.removeFirst(start)
                start = 0
            }
        }

        mutating func reset() {
            items.removeAll()
            start = 0
            evicted = 0
        }
    }

    private let lock = NSLock()
    /// `trackCapacity` and attribution-mismatch reports, edge-triggered (one
    /// line per episode), called outside the lock. The pipeline wires it to
    /// the run log (`"event":"tuning-readout"`); unwired in tests and the demo.
    var onLimit: ((String) -> Void)?
    private var tracks: [TrackKey: Track] = [:]
    private var tracksEvicted = 0
    private var trackCapFull = false
    private var attributionSkipped = 0
    private var attributionMismatch = false
    private var hits = WindowRing<Hit>(capacity: TuningReadout.capacity, time: { $0.at })
    private var frames = WindowRing<FrameStat>(capacity: TuningReadout.frameCapacity, time: { $0.at })
    private var suppressions: [Suppression] = []
    private var curtain: [CurtainEvent] = []
    private var lastDrop: CurtainEvent?
    /// Curtain events are episode-rate (a handful per minute at most), so a
    /// trimmed array is enough. Suppressions are NOT (a live staircase cuts
    /// boxes every frame): the ring is kept only for `lastSuppression`'s
    /// wording; every count comes from the frame ring (`FrameStat`).
    private let episodeCap = 256

    /// One detector frame. `raw` is the detector's list BEFORE the policy
    /// filter; the per-box rule decisions are re-derived here from the same
    /// `TuningPolicy` the filter used (`minBox`, `demoteCovered`,
    /// `thresholdStep`), so the tab names the rule that removed a box without
    /// the filter having to return per-box detail. `filtered` is that same
    /// frame's `TuningPolicy.filter` result: the FRAME-level numbers come
    /// from it rather than being re-derived, so the tab and the run log's
    /// counters can never disagree.
    ///
    /// TRACKS (2026-10-20): every policy-class box also lands in its track.
    /// Its fate comes from `TuningPolicy.verdicts`, the Detection view's
    /// per-box mirror of `filter`, given the same `tracked` and `roi`, so a
    /// row and the trace never tell one box two ways. `windows` (credited
    /// window per box) and `drops` index the pipeline's BLOCKED list —
    /// `filter`'s blocked narrowed by the ROI, what `Curtain.update` saw —
    /// which is the raw boxes whose verdict passes, in raw order. When the
    /// mirror's count is not `blockedCount`, the frame's boxes still count
    /// but carry no window or ✓, and the mismatch is counted and logged.
    /// `appName` (memoized by the caller) runs outside the lock.
    func record(
        raw: [Detection], filtered: TuningPolicy.Filtered, tuning: TuningPolicy,
        mode: PolicyMode, blockFaces: Bool, screen: CGSize, now: Double,
        tracked: TuningPolicy.CoveredInput = .init(), roi: CGRect? = nil, blockedCount: Int? = nil,
        windows: [Int: CGWindowID] = [:], drops: [Drop] = [],
        appName: (CGWindowID) -> String? = { _ in nil }, frameAt: Double? = nil
    ) {
        guard !raw.isEmpty else { return }
        let measurable = screen.width > 0 && screen.height > 0
        var newHits: [Hit] = []
        var newSuppressions: [Suppression] = []
        let (demoted, _) = tuning.demoteCovered(raw)
        let verdicts = tuning.verdicts(
            raw, mode: mode, blockFaces: blockFaces, screen: screen, roi: roi, tracked: tracked)
        // Blocked-list index → raw index: the mirror's passing boxes, in order.
        let rawOfBlocked = verdicts.indices.filter { verdicts[$0].passes }
        let expected = blockedCount ?? filtered.blocked.count
        let mapped = rawOfBlocked.count == expected
        var windowOfRaw: [Int: CGWindowID] = [:]
        var droppedRaw: [Int: CGWindowID] = [:]
        if mapped {
            for (b, w) in windows where rawOfBlocked.indices.contains(b) { windowOfRaw[rawOfBlocked[b]] = w }
            for drop in drops {
                for b in drop.indices where rawOfBlocked.indices.contains(b) { droppedRaw[rawOfBlocked[b]] = drop.windowID }
            }
        }
        var apps: [CGWindowID: String] = [:]
        for w in Set(windowOfRaw.values).union(droppedRaw.values) { apps[w] = appName(w) }
        var trackHits: [(box: CGRect, hit: Hit, floor: Float, dropped: Bool)] = []
        for (i, d) in raw.enumerated() {
            guard tuning.rule(for: d.label) != nil, d.label != TuningPolicy.injectLabel else { continue }
            let side: Double? = measurable
                ? Double(min(d.box.width * screen.width, d.box.height * screen.height)) : nil
            var hit = Hit(at: now, label: d.label, conf: d.confidence, sidePt: side)
            hit.windowID = droppedRaw[i] ?? windowOfRaw[i]
            hit.frameAt = frameAt
            if let (status, floor) = Self.fate(verdicts[i], raw: d, tuning: tuning, mode: mode, blockFaces: blockFaces) {
                hit.status = status
                trackHits.append((d.box, hit, floor, droppedRaw[i] != nil))
            }
            newHits.append(hit)
            let after = demoted[i]
            if after.label != d.label {
                newSuppressions.append(Suppression(
                    at: now, label: d.label, rule: .coveredBeatsExposed,
                    detail: "\(d.label) → \(after.label) (inside a covered box ≥ \(Self.fmt(tuning.coveredOverlap)) of its area)"))
                continue
            }
            guard tuning.blocks(after, mode: mode, blockFaces: blockFaces) else { continue }
            let sideText = side.map { "\(Self.fmt($0)) pt" } ?? "unmeasured"
            // The size floor first, and it OWNS the box: the order the filter
            // applies (`TuningPolicy.filter`), so a box the size floor
            // removes is a size drop and never also a step drop.
            if tuning.minBox(after, screen: screen) == .dropped, let r = tuning.rule(for: after.label) {
                let floor = r.minBoxPt > 0 && side.map({ $0 < r.minBoxPt }) == true
                    ? "minBoxPt \(Self.fmt(r.minBoxPt))"
                    : "minBoxFraction \(Self.fmt(r.minBoxFraction))"
                newSuppressions.append(Suppression(
                    at: now, label: after.label, rule: .minBox,
                    detail: "\(after.label) \(sideText) conf \(Self.fmt(Double(after.confidence))) < \(floor)"))
                continue
            }
            // Then the staircase. The line names the STEP that fired and the
            // base it raised.
            if let r = tuning.rule(for: after.label), let side,
                let step = r.thresholdSteps.last(where: { side >= $0.minPt }),
                after.confidence < step.threshold
            {
                newSuppressions.append(Suppression(
                    at: now, label: after.label, rule: .thresholdStep,
                    detail: "\(after.label) \(sideText) conf \(Self.conf(after.confidence)) "
                        + "< \(Self.conf(step.threshold)) "
                        + "(step ≥ \(TuningPolicy.stepPtText(step.minPt)) pt; base \(Self.conf(r.threshold)))"))
            }
        }
        // Blocked under the FLAT policy: `blocked + stepDropped` is that set.
        // Frames outside it contribute 0 to all three numbers, so they are
        // not kept.
        let blockedFlat = !filtered.blocked.isEmpty || filtered.stepDropped > 0
        let keepFrame = blockedFlat || filtered.minBoxDropped > 0 || filtered.demoted > 0
        guard !newHits.isEmpty || !newSuppressions.isEmpty || keepFrame || !mapped else { return }
        var limitLines: [String] = []
        lock.lock()
        defer {
            lock.unlock()
            for line in limitLines { onLimit?(line) }
        }
        let since = now - Self.windowSecs
        if !mapped {
            attributionSkipped += 1
            if !attributionMismatch {
                attributionMismatch = true
                limitLines.append(
                    "attribution skipped: policy mirror passes \(rawOfBlocked.count) boxes, pipeline "
                        + "blocked \(expected); such frames' boxes are counted without window or curtain mark "
                        + "(fix: TuningReadout.record / TuningPolicy.verdicts)")
            }
        } else {
            attributionMismatch = false
        }
        for t in trackHits {
            mergeTrack(t.box, hit: t.hit, floor: t.floor, dropped: t.dropped,
                app: t.hit.windowID.flatMap { apps[$0] }, now: now, limitLines: &limitLines)
        }
        hits.append(contentsOf: newHits, since: since)
        if keepFrame {
            let f = FrameStat(
                at: now, stepCut: filtered.stepDropped, emptied: filtered.stepEmptiedFrame,
                blockedFlat: blockedFlat, minBoxCut: filtered.minBoxDropped, coveredCut: filtered.demoted)
            frames.append(contentsOf: [f], since: since)
        }
        suppressions.append(contentsOf: newSuppressions)
        if suppressions.count > episodeCap { suppressions.removeFirst(suppressions.count - episodeCap) }
    }

    /// The curtain's `onChange` (drop / lift / handoff / ghost-ban …), as
    /// the run log records it.
    func recordCurtain(action: String, windowID: CGWindowID, app: String?, now: Double) {
        let e = CurtainEvent(at: now, action: action, windowID: windowID, app: app)
        lock.lock()
        defer { lock.unlock() }
        curtain.append(e)
        if curtain.count > episodeCap { curtain.removeFirst(curtain.count - episodeCap) }
        if action.hasPrefix("drop") { lastDrop = e }
    }

    /// The box's status and the floor its bar is drawn against, from its
    /// verdict; nil for a box no row shows (a covered class the current
    /// policy does not block, a class with no rule). A demoted box keeps
    /// its RAW label's row and floor, so an exposed box the rule relabelled
    /// reads as removed BY that rule, not as a covered-class box.
    static func fate(
        _ v: TuningPolicy.Verdict, raw d: Detection, tuning: TuningPolicy, mode: PolicyMode, blockFaces: Bool
    ) -> (TrackRow.Status, Float)? {
        let rawFloor = tuning.startThreshold(d.label, mode: mode, blockFaces: blockFaces)
        let ownFloor = tuning.startThreshold(v.label, mode: mode, blockFaces: blockFaces) ?? 0
        switch v.policy {
        case let .passes(floor, _): return (.covered, floor)
        case let .kept(start, _, _): return (.covered, start)
        case let .belowThreshold(t):
            return v.demotion != nil ? (.removed("covered-beats-exposed"), rawFloor ?? t) : (.below, t)
        case .classOffInPolicy:
            guard v.demotion != nil, let rawFloor else { return nil }
            return (.removed("covered-beats-exposed"), rawFloor)
        case let .minBox(_, minBoxPt, _): return (.removed(minBoxPt > 0 ? "minBoxPt" : "minBoxFraction"), ownFloor)
        case let .thresholdStep(floor, _, _): return (.removed("size step"), floor)
        case .outsideROI: return (.removed("outside ROI"), ownFloor)
        case .weak, .notPolicyClass: return nil
        }
    }

    /// Lock held. One box into its track (see `TrackKey` for how a box with
    /// no credited window finds one); a new track past `trackCapacity`
    /// evicts the lowest-ranked one, counted and reported.
    private func mergeTrack(
        _ box: CGRect, hit: Hit, floor: Float, dropped: Bool, app: String?, now: Double,
        limitLines: inout [String]
    ) {
        let g = Self.trackGrid
        let cx = min(g - 1, max(0, Int(box.midX * CGFloat(g))))
        let cy = min(g - 1, max(0, Int((1 - box.midY) * CGFloat(g))))  // row 0 at the top, like the screen
        let since = now - Self.windowSecs
        var key = TrackKey(label: hit.label, windowID: hit.windowID, cellX: cx, cellY: cy)
        if tracks[key].map({ $0.lastAt < since }) ?? true {
            // The other side of the window rule: an uncredited box joins the
            // most recently hit live track of its label and cell in any
            // window; a credited box adopts a live uncredited one (re-keyed).
            let sibling = tracks.values
                .filter { $0.key.label == hit.label && $0.key.cellX == cx && $0.key.cellY == cy }
                .filter { $0.lastAt >= since && (hit.windowID == nil || $0.key.windowID == nil) }
                .max { $0.lastAt < $1.lastAt }
            if let sibling {
                if hit.windowID != nil {
                    var t = tracks.removeValue(forKey: sibling.key)!
                    t.key = key
                    tracks[key] = t
                } else {
                    key = sibling.key
                }
            }
        }
        let status: TrackRow.Status = dropped ? .curtain : (hit.status ?? .below)
        if var t = tracks[key], t.lastAt >= since {
            t.lastAt = now
            t.peak = max(t.peak, hit.conf)
            t.latest = hit.conf
            t.floor = floor
            t.sidePt = hit.sidePt
            t.hits += 1
            if status.weight >= t.status.weight { t.status = status }
            if t.app == nil { t.app = app }
            tracks[key] = t
            return
        }
        tracks.removeValue(forKey: key)  // aged out: a new row, not a resurrection
        if tracks.count >= Self.trackCapacity { tracks = tracks.filter { $0.value.lastAt >= since } }
        if tracks.count >= Self.trackCapacity {
            let victim = tracks.values.min { Self.rank($0, now: now) < Self.rank($1, now: now) }!
            tracks.removeValue(forKey: victim.key)
            tracksEvicted += 1
            if !trackCapFull {
                trackCapFull = true
                limitLines.append(
                    "track table full: budget=TuningReadout.trackCapacity configured=\(Self.trackCapacity) "
                        + "observed=\(Self.trackCapacity + 1) live tracks; the lowest-ranked row is evicted "
                        + "and counted on the Developer tab (fix: TuningReadout.trackCapacity)")
            }
        } else {
            trackCapFull = false
        }
        tracks[key] = Track(
            key: key, app: app, lastAt: now, peak: hit.conf, latest: hit.conf, floor: floor,
            sidePt: hit.sidePt, status: status, hits: 1)
    }

    static func rank(_ t: Track, now: Double) -> Double {
        Double(t.peak) * pow(0.5, max(0, now - t.lastAt) / rankHalfLifeSecs)
    }

    /// FBE / FGE / MGE / BE / AE for the exposed classes, "covered" for the
    /// covered ones (Copy carries the full label).
    static func classCode(_ label: String) -> String {
        switch label {
        case "FEMALE_BREAST_EXPOSED": return "FBE"
        case "FEMALE_GENITALIA_EXPOSED": return "FGE"
        case "MALE_GENITALIA_EXPOSED": return "MGE"
        case "BUTTOCKS_EXPOSED": return "BE"
        case "ANUS_EXPOSED": return "AE"
        default: return TuningPolicy.coveredLabels.contains(label) ? "covered" : label
        }
    }

    /// The tab's Clear, the demo and the selftest: back to empty.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        tracks.removeAll()
        tracksEvicted = 0
        trackCapFull = false
        attributionSkipped = 0
        attributionMismatch = false
        hits.reset()
        frames.reset()
        suppressions.removeAll()
        curtain.removeAll()
        lastDrop = nil
    }

    func snapshot(now: Double) -> Snapshot {
        lock.lock()
        let hits = self.hits
        let frames = self.frames
        let suppressions = self.suppressions
        let curtain = self.curtain
        let lastDrop = self.lastDrop
        let tracks = self.tracks
        let tracksEvicted = self.tracksEvicted
        let attributionSkipped = self.attributionSkipped
        lock.unlock()
        let since = now - Self.windowSecs
        var byLabel: [String: (hits: Int, minPt: Double?, maxPt: Double?, maxConf: Float)] = [:]
        for h in hits.live where h.at >= since {
            var s = byLabel[h.label] ?? (0, nil, nil, 0)
            s.hits += 1
            if let pt = h.sidePt {
                s.minPt = s.minPt.map { min($0, pt) } ?? pt
                s.maxPt = s.maxPt.map { max($0, pt) } ?? pt
            }
            s.maxConf = max(s.maxConf, h.conf)
            byLabel[h.label] = s
        }
        var out = Snapshot()
        // Ranked HERE, on the 1 Hz settings tick, never per frame: a row
        // moves at most once a second, and the view animates the move.
        out.rows = tracks.values.filter { $0.lastAt >= since }.map { t in
            TrackRow(
                id: t.key.id, label: t.key.label, windowID: t.key.windowID, app: t.app, peak: t.peak,
                latest: t.latest, floor: t.floor, sidePt: t.sidePt, status: t.status, hits: t.hits,
                ageSecs: max(0, now - t.lastAt), rank: Self.rank(t, now: now))
        }.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.id < $1.id }
        out.tracksEvicted = tracksEvicted
        out.attributionSkipped = attributionSkipped
        let order = TuningPolicy.exposedLabels + TuningPolicy.coveredLabels
        out.classes = order.compactMap { label in
            byLabel[label].map { ClassStat(label: label, hits: $0.hits, minPt: $0.minPt, maxPt: $0.maxPt, maxConf: $0.maxConf) }
        }
        for f in frames.live where f.at >= since {
            out.stepBoxesCut += f.stepCut
            out.suppressedMinBox += f.minBoxCut
            out.suppressedCovered += f.coveredCut
            if f.emptied { out.stepFramesEmptied += 1 }
            if f.blockedFlat { out.blockedFrames += 1 }
        }
        out.lastSuppression = suppressions.last { $0.at >= since }
        out.lastCurtain = curtain.last { $0.at >= since }
        out.lastDrop = lastDrop.flatMap { $0.at >= since ? $0 : nil }
        out.overflow = hits.evicted
        out.framesOverflow = frames.evicted
        return out
    }

    static func fmt(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.2f", x)
    }

    /// A score, always two decimals — `1.00`, never `1`, so a threshold
    /// comparison reads as one.
    static func conf(_ x: Float) -> String { String(format: "%.2f", Double(x)) }
}

/// The Developer tab's model. Main thread only, like `UIActions` that owns it.
final class UIDevTuning: ObservableObject {
    /// What the tab says under the sliders (`ui.settings.developer.applied`,
    /// plus the clock-free `…applied.state` for scripts).
    enum Applied: Equatable {
        /// No tuning file: the launch policy (`source`) is in force.
        case none(source: String)
        /// This session wrote the file; the agent's 1 Hz poll has not echoed yet.
        case written(Date)
        /// The agent loaded the file (the `"event":"tuning"` record's moment).
        case applied(Date)
        /// The agent refused it; the previous policy stays in force.
        case refused(String)

        var stateName: String {
            switch self {
            case .none: return "none"
            case .written: return "written"
            case .applied: return "applied"
            case .refused: return "refused"
            }
        }
    }

    let readout: TuningReadout
    let stateRoot: String
    /// The launch policy the file layers over (`Options.tuning`) and its
    /// source name — what Reset returns to.
    let base: TuningPolicy
    let baseSource: String
    /// The parent/ directory's group: `admin` on the production root
    /// (`AdminCheck.adminGID`), this process's group elsewhere — the same
    /// rule `UISettingsStore` hands the PIN authority.
    private let groupID: gid_t

    @Published var draft: TuningPolicy
    @Published private(set) var applied: Applied
    /// A failed write names the path and the errno (§3.4 rule); never dropped silently.
    @Published private(set) var writeError: String?
    /// A REFUSED EDIT, in the parser's own wording (`TuningPolicy.parseStepsText`
    /// → `validateSteps`, the same validator config.json and tuning.json go
    /// through). Shown in the same inline row as `writeError`: the tab can
    /// never write a file the agent would then refuse, so the refusal has to
    /// land here instead.
    @Published private(set) var editError: String?
    /// What a `thresholdSteps` field is holding WHILE it is being typed, per
    /// class. nil = the field renders the draft (`TuningPolicy.stepsText`).
    /// A refused edit keeps the typed text on screen beside the error; a
    /// commit, a reset and the agent's echo clear it.
    @Published private(set) var stepsEntry: [String: String] = [:]
    @Published private(set) var snapshot = TuningReadout.Snapshot()
    /// True while a slider is being dragged: an echo from the agent must not
    /// snap the thumb back under the parent's finger (the echo is of the
    /// LAST commit, which the drag is about to replace).
    var editing = false

    var filePath: String { stateRoot + "/" + TuningFile.fileName }

    init(stateRoot: String, groupID: gid_t, base: TuningPolicy, baseSource: String,
        readout: TuningReadout = TuningReadout())
    {
        self.stateRoot = stateRoot
        self.groupID = groupID
        self.base = base
        self.baseSource = baseSource
        self.readout = readout
        draft = base
        applied = .none(source: baseSource)
    }

    // MARK: Draft edits (the view's bindings)

    func setClass(_ label: String, _ change: (inout TuningPolicy.ClassRule) -> Void) {
        guard var r = draft.rule(for: label) else { return }
        change(&r)
        if draft.standard[label] != nil { draft.standard[label] = r } else { draft.strict[label] = r }
    }

    /// The text one class's `thresholdSteps` field shows: what is being
    /// typed, else the draft's canonical rendering.
    func stepsFieldText(_ label: String) -> String {
        stepsEntry[label] ?? TuningPolicy.stepsText(draft.rule(for: label)?.thresholdSteps ?? [])
    }

    func setStepsEntry(_ label: String, _ text: String?) {
        if let text { stepsEntry[label] = text } else { stepsEntry.removeValue(forKey: label) }
    }

    /// One class's staircase from the tab's text field. THE ONLY WRITER:
    /// parse (which validates) → draft, or refuse and leave the draft
    /// alone. Returns true when the caller should commit the file.
    func applyStepsText(_ label: String, _ raw: String) -> Bool {
        // A fresh edit decision replaces any earlier write failure in the
        // error row; otherwise a stale errno masks the refusal.
        writeError = nil
        let base = draft.rule(for: label)?.threshold ?? 0
        switch TuningPolicy.parseStepsText(raw, base: base, at: "classes.\(label).") {
        case let .success(steps):
            setClass(label) { $0.thresholdSteps = steps }
            setStepsEntry(label, nil)
            editError = nil
            return true
        case let .failure(e):
            // The typed text stays on screen next to the refusal; nothing is
            // written, so the agent never sees a file it would refuse.
            setStepsEntry(label, raw)
            editError = e.text
            return false
        }
    }

    /// The `threshold` slider: refused (with the file parser's wording) when
    /// it would climb above one of the class's steps, since a step below the
    /// base could never fire. Returns true when applied.
    func applyThreshold(_ label: String, _ v: Float) -> Bool {
        guard let r = draft.rule(for: label) else { return false }
        writeError = nil
        if let e = TuningPolicy.validateSteps(r.thresholdSteps, base: v, at: "classes.\(label).") {
            editError = e.text
            return false
        }
        setClass(label) { $0.threshold = v }
        editError = nil
        return true
    }

    /// `curtain.triggerHits`, keeping the two lower bars at or under it —
    /// `TuningPolicy.parse` refuses a file where they exceed it.
    func setTriggerHits(_ n: Int) {
        draft.curtain.triggerHits = n
        draft.curtain.handoffHits = min(draft.curtain.handoffHits, n)
        draft.curtain.paroleHits = min(draft.curtain.paroleHits, n)
    }

    // MARK: The file

    /// `{ "version": 1, "tuning": {…} }`, the schema `TuningFile.parse`
    /// reads. `INJECT_TEST` (printed by `jsonObject`) is not a class the
    /// parser accepts, so it is stripped here.
    static func fileObject(_ p: TuningPolicy) -> [String: Any] {
        ["version": TuningFile.version, "tuning": configObject(p)]
    }

    /// The `tuning` value for config.json (the Copy button).
    static func configObject(_ p: TuningPolicy) -> [String: Any] {
        var o = p.jsonObject
        if var classes = o["classes"] as? [String: Any] {
            classes.removeValue(forKey: TuningPolicy.injectLabel)
            o["classes"] = classes
        }
        return o
    }

    static func json(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted])
    }

    /// Writes the draft as `parent/tuning.json`: temp file in the same
    /// directory, 0660, the directory's group, fsync, rename — the contract
    /// every parent/ file follows (`LicenseFileStore.write`,
    /// `ParentPINFileAuthority`). The agent's poll picks it up within one
    /// tick (`UISettingsStore.pollSecs`).
    func writeFile() {
        writeError = nil
        // The draft is about to become the truth on disk, so every field goes
        // back to rendering it: a refused edit must not be left on screen
        // with its error cleared out from under it.
        editError = nil
        stepsEntry.removeAll()
        let dir = stateRoot + "/" + ParentPINFileAuthority.directoryName
        let data = Self.json(Self.fileObject(draft)) + Data("\n".utf8)
        let dirFD = open(dir, O_RDONLY | O_DIRECTORY)
        guard dirFD >= 0 else {
            writeError = "\(dir): open errno=\(errno) \(String(cString: strerror(errno)))"
            return
        }
        defer { close(dirFD) }
        let name = "tuning.json"
        let tmp = ".\(name).tmp.\(getpid()).\(UUID().uuidString)"
        let fd = openat(dirFD, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, ParentPINFileAuthority.fileMode)
        guard fd >= 0 else {
            writeError = "\(dir)/\(tmp): openat errno=\(errno) \(String(cString: strerror(errno)))"
            return
        }
        var failure: String?
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count, failure == nil {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { failure = "write errno=\(errno)" } else { off += n }
            }
        }
        if failure == nil, fchmod(fd, ParentPINFileAuthority.fileMode) != 0 { failure = "fchmod errno=\(errno)" }
        if failure == nil, fchown(fd, uid_t.max, groupID) != 0 { failure = "fchown errno=\(errno)" }
        if failure == nil, fsync(fd) != 0 { failure = "fsync errno=\(errno)" }
        close(fd)
        if failure == nil, renameat(dirFD, tmp, dirFD, name) != 0 { failure = "renameat errno=\(errno)" }
        if let failure {
            unlinkat(dirFD, tmp, 0)
            writeError = "\(filePath): \(failure)"
            return
        }
        applied = .written(Date())
    }

    /// Reset: the draft returns to the launch policy and the file goes,
    /// which the agent logs as "removed — back to the launch policy".
    func reset() {
        writeError = nil
        editError = nil
        stepsEntry.removeAll()
        draft = base
        if unlink(filePath) != 0, errno != ENOENT {
            writeError = "\(filePath): unlink errno=\(errno) \(String(cString: strerror(errno)))"
            return
        }
        applied = .none(source: baseSource)
    }

    /// The Copy button: `"tuning": {…}` on the general pasteboard, ready to
    /// paste into config.json.
    func copyConfigJSON() {
        let body = String(decoding: Self.json(["tuning": Self.configObject(draft)]), as: UTF8.self)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)
    }

    // MARK: The agent's echo and the readout

    /// Every outcome of `AppDelegate.pollTuningFile` (the 1 Hz poll), in
    /// order. `.loaded` is the moment the `"event":"tuning"` record is
    /// written, so the stamp is that record's time.
    func noteOutcome(_ outcome: TuningFile.Outcome, at: Date = Date()) {
        switch outcome {
        case .absent:
            applied = .none(source: baseSource)
        case let .refused(why):
            applied = .refused(why)
        case let .loaded(p):
            applied = .applied(at)
            if !editing {
                draft = p
                // The fields follow the policy that is actually in force.
                stepsEntry.removeAll()
            }
        }
    }

    /// The settings tick (1 Hz): refresh the 60 s readout. While frozen the
    /// ROWS stay exactly as they were (order and values, so they can be
    /// read); the footer keeps updating. A freeze ends on its own after
    /// `freezeSecs`.
    func tick(now: Double = CFAbsoluteTimeGetCurrent()) {
        if let at = frozenAt, now - at >= Self.freezeSecs { frozenAt = nil }
        var s = readout.snapshot(now: now)
        if frozenAt != nil { s.rows = snapshot.rows }
        if s != snapshot { snapshot = s }
    }

    /// FREEZE TIMEOUT: a frozen readout unfreezes by itself after this long.
    /// 30 s (owner design 2026-10-20): half the 60 s window, so a frozen
    /// list never hides more than half a window of re-ranking from someone
    /// who walked away; DERIVED from `TuningReadout.windowSecs`, ASSUMED as
    /// enough time to read a dozen rows.
    static let freezeSecs: Double = 30
    /// When Freeze was pressed; nil = live. Main thread.
    @Published private(set) var frozenAt: Double?

    func freeze(now: Double = CFAbsoluteTimeGetCurrent()) { frozenAt = now }
    func unfreeze(now: Double = CFAbsoluteTimeGetCurrent()) {
        frozenAt = nil
        tick(now: now)
    }

    /// Seconds until a freeze ends by itself (0 when live).
    func freezeRemaining(now: Double = CFAbsoluteTimeGetCurrent()) -> Int {
        guard let at = frozenAt else { return 0 }
        return max(0, Int((Self.freezeSecs - (now - at)).rounded(.up)))
    }

    /// Clear: every row, count and footer line goes; a freeze ends.
    func clearReadout(now: Double = CFAbsoluteTimeGetCurrent()) {
        readout.reset()
        frozenAt = nil
        tick(now: now)
    }

    /// Copy (the readout's): every row, then the footer, as text.
    func copyReadout() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(UIDeveloperSettingsSection.readoutText(snapshot), forType: .string)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var appliedText: String {
        switch applied {
        case let .none(source): return "No tuning.json — launch policy in force (\(source))"
        case let .written(at): return "Written \(Self.clock.string(from: at)) — waiting for the agent's 1 Hz reload"
        case let .applied(at): return "Applied \(Self.clock.string(from: at)) (parent/tuning.json)"
        case let .refused(why): return "Refused — \(why)"
        }
    }
}

// MARK: - Views

/// Settings › Developer. Ids: `ui.settings.developer.*`.
struct UIDeveloperSettingsSection: View {
    @ObservedObject var state: UIState
    @ObservedObject var actions: UIActions
    @ObservedObject var tuning: UIDevTuning

    static let idPrefix = "ui.settings.developer"
    static let sectionCaption = "Curtain tuning. Every change writes parent/tuning.json; the agent reloads it within 1 s."
    static let resetLabel = "Reset to shipped defaults"
    static let copyLabel = "Copy as config.json tuning"

    /// The classes the current sensitivity blocks: the five exposed always,
    /// the three covered under Strict.
    private var labels: [String] {
        TuningPolicy.exposedLabels + (state.policy == .strict ? TuningPolicy.coveredLabels : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.labelGap) {
            // The Detection view (UIDetectionView.swift): the live answer to
            // "why was this box covered or not", above the numbers it explains.
            UIDetectionViewSection(actions: actions, view: actions.detectionView)
                .padding(.bottom, UIMetrics.sectionSpacing - UIMetrics.labelGap)
            UISectionLabel(text: "Developer")
            UISection {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.sectionCaption)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.stepsHelp)
                        .uiFont(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiControl("\(Self.idPrefix).stepsHelp", kind: .text, read: { Self.stepsHelp })
                    appliedRow
                    ForEach(labels, id: \.self) { label in
                        Divider()
                        classRows(label)
                    }
                    Divider()
                    sharedRows
                    Divider()
                    HStack(spacing: 8) {
                        Button(Self.resetLabel) { actions.resetDevTuning() }
                            .controlSize(.small)
                            .uiControl("\(Self.idPrefix).reset", kind: .button,
                                read: { Self.resetLabel }, activate: { actions.resetDevTuning() })
                        Button(Self.copyLabel) { tuning.copyConfigJSON() }
                            .controlSize(.small)
                            .uiControl("\(Self.idPrefix).copy", kind: .button,
                                read: { Self.copyLabel }, activate: { tuning.copyConfigJSON() })
                    }
                    // ONE error row, two sources: a write that could not land
                    // and an edit the parser refused. A second row would be a
                    // second id for "what went wrong".
                    if let error = tuning.editError ?? tuning.writeError {
                        UIInlineMessage(text: error, symbol: UISymbol.writeError, tint: .systemRed)
                            .uiControl("\(Self.idPrefix).error", kind: .text,
                                read: { tuning.editError ?? tuning.writeError ?? "" })
                    }
                }
            }
            UISectionLabel(text: "Last 60 s")
            UISection { readout }
        }
        .uiScrollAnchor("\(Self.idPrefix).reset")
    }

    private var appliedRow: some View {
        let refused: Bool = { if case .refused = tuning.applied { return true } else { return false } }()
        return UIInlineMessage(
            text: tuning.appliedText,
            symbol: refused ? UISymbol.warning : UISymbol.managed,
            tint: refused ? .systemOrange : .systemGreen)
            .uiControl("\(Self.idPrefix).applied", kind: .text, read: { tuning.appliedText })
            .uiControl("\(Self.idPrefix).applied.state", kind: .text, read: { tuning.applied.stateName })
    }

    @ViewBuilder private func classRows(_ label: String) -> some View {
        let rule = tuning.draft.rule(for: label) ?? TuningPolicy.ClassRule(threshold: 0)
        Text(label)
            .uiFont(.caption)
            .fontWeight(.semibold)
            .uiControl("\(Self.idPrefix).\(label)", kind: .text, read: { label })
        sliderRow("threshold", id: "\(Self.idPrefix).\(label).threshold", value: Double(rule.threshold),
            range: 0.5...1.0, step: 0.01, decimals: 2)
        { v in _ = tuning.applyThreshold(label, Float(v)) }
        stepsRow(label)
        sliderRow("minBoxPt", id: "\(Self.idPrefix).\(label).minBoxPt", value: rule.minBoxPt,
            range: 0...200, step: 1, decimals: 0)
        { v in tuning.setClass(label) { $0.minBoxPt = v } }
        sliderRow("entryFrames", id: "\(Self.idPrefix).\(label).entryFrames", value: Double(rule.entryFrames),
            range: 1...10, step: 1, decimals: 0)
        { v in tuning.setClass(label) { $0.entryFrames = Int(v) } }
    }

    @ViewBuilder private var sharedRows: some View {
        Toggle(isOn: Binding(
            get: { tuning.draft.coveredBeatsExposed },
            set: { on in tuning.draft.coveredBeatsExposed = on; actions.commitDevTuning() }))
        {
            Text("coveredBeatsExposed").uiFont(.caption)
        }
        .toggleStyle(.checkbox)
        .uiControl("\(Self.idPrefix).coveredBeatsExposed", kind: .toggle,
            read: { tuning.draft.coveredBeatsExposed ? "on" : "off" },
            activate: {
                tuning.draft.coveredBeatsExposed.toggle()
                actions.commitDevTuning()
            })
        sliderRow("coveredOverlap", id: "\(Self.idPrefix).coveredOverlap", value: tuning.draft.coveredOverlap,
            range: 0.5...1.0, step: 0.05, decimals: 2)
        { v in tuning.draft.coveredOverlap = v }
        // Score hysteresis: a covered box stays covered down to its start
        // floor minus this (receipt at `TuningPolicy.keepGap`); 0 is off.
        sliderRow("keepGap", id: "\(Self.idPrefix).keepGap", value: tuning.draft.keepGap,
            range: 0...0.25, step: 0.01, decimals: 2)
        { v in tuning.draft.keepGap = v }
        Toggle(isOn: Binding(
            get: { tuning.draft.settleRecheck },
            set: { on in tuning.draft.settleRecheck = on; actions.commitDevTuning() }))
        {
            Text("settleRecheck").uiFont(.caption)
        }
        .toggleStyle(.checkbox)
        .uiControl("\(Self.idPrefix).settleRecheck", kind: .toggle,
            read: { tuning.draft.settleRecheck ? "on" : "off" },
            activate: {
                tuning.draft.settleRecheck.toggle()
                actions.commitDevTuning()
            })
            // The UI scripts scroll here to render the steadiness rows.
            .uiScrollAnchor("\(Self.idPrefix).settleRecheck")
        // Zoom (tiling) prototype (`ZoomTiles`): one 2 × 2 tile per frame in
        // rotation on top of the full-frame pass. Off by default.
        Toggle(isOn: Binding(
            get: { tuning.draft.zoomTiles },
            set: { on in tuning.draft.zoomTiles = on; actions.commitDevTuning() }))
        {
            Text("zoomTiles (2 × 2, one tile per frame)").uiFont(.caption)
        }
        .toggleStyle(.checkbox)
        .uiControl("\(Self.idPrefix).zoomTiles", kind: .toggle,
            read: { tuning.draft.zoomTiles ? "on" : "off" },
            activate: {
                tuning.draft.zoomTiles.toggle()
                actions.commitDevTuning()
            })
        sliderRow("curtain.triggerHits", id: "\(Self.idPrefix).curtain.triggerHits",
            value: Double(tuning.draft.curtain.triggerHits), range: 1...10, step: 1, decimals: 0)
        { v in tuning.setTriggerHits(Int(v)) }
        sliderRow("curtain.windowSecs", id: "\(Self.idPrefix).curtain.windowSecs",
            value: tuning.draft.curtain.windowSecs, range: 0.25...5, step: 0.25, decimals: 2)
        { v in tuning.draft.curtain.windowSecs = v }
        sliderRow("curtain.holdSecs", id: "\(Self.idPrefix).curtain.holdSecs",
            value: tuning.draft.curtain.holdSecs, range: 0.5...60, step: 0.5, decimals: 1)
        { v in tuning.draft.curtain.holdSecs = v }
    }

    /// One labelled slider with its value. The draft follows the thumb; the
    /// file is written once, on release (`onEditingChanged` false) — a drag
    /// must not produce a hundred tuning.json writes and reloads. A script
    /// `type`s a number into the same id (kind `.field`): parsed, clamped to
    /// the range, committed at once.
    private func sliderRow(
        _ name: String, id: String, value: Double, range: ClosedRange<Double>, step: Double,
        decimals: Int, set: @escaping (Double) -> Void
    ) -> some View {
        let text = String(format: "%.\(decimals)f", value)
        return HStack(spacing: 6) {
            Text(name)
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Slider(
                value: Binding(get: { value }, set: { set($0) }),
                in: range, step: step,
                onEditingChanged: { editing in
                    tuning.editing = editing
                    if !editing { actions.commitDevTuning() }
                })
            .controlSize(.mini)
            Text(text)
                .uiFont(.caption2)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .uiControl(id, kind: .field,
            read: { [tuning] in
                // The registry keeps the closure from the first appear; read
                // the live draft, not this body's `value`.
                String(format: "%.\(decimals)f", Self.current(id: id, in: tuning.draft) ?? value)
            },
            setText: { raw in
                guard let v = Double(raw.trimmingCharacters(in: .whitespaces)) else { return }
                set(min(max(v, range.lowerBound), range.upperBound))
                actions.commitDevTuning()
            })
    }

    /// One class's `thresholdSteps`, as a TEXT FIELD and not sliders: 8
    /// classes × `ClassRule.maxSteps` 4 steps × 2 numbers would be 64
    /// dynamic-id rows on a page that already has a layout budget,
    /// a field keeps
    /// a fixed id set at any step count, and it is how the rule is stated out
    /// loud ("0.80 under 64 pt, 0.90 above" → `64:0.90`). The `threshold`
    /// slider above still owns the base.
    ///
    /// The canonical text is `TuningPolicy.stepsText` — the same rendering
    /// the UI scripts assert. Typing does NOT commit (a keystroke must not
    /// write tuning.json, exactly as a slider drag must not); Return does,
    /// through the same PIN gate as every other edit. A script's `type` goes
    /// straight to `setText` below, which is that same commit.
    @ViewBuilder private func stepsRow(_ label: String) -> some View {
        let id = "\(Self.idPrefix).\(label).thresholdSteps"
        let rule = tuning.draft.rule(for: label) ?? TuningPolicy.ClassRule(threshold: 0)
        let commit: (String) -> Void = { raw in
            // Return on an untouched field is a no-op: the rendering is
            // 2-dp (`stepsText`), so re-committing it would silently round a
            // 3-dp value from config.json.
            let shown = TuningPolicy.stepsText(tuning.draft.rule(for: label)?.thresholdSteps ?? [])
            guard raw.trimmingCharacters(in: .whitespaces) != shown else { return }
            if tuning.applyStepsText(label, raw) { actions.commitDevTuning() }
        }
        let clear = { if tuning.applyStepsText(label, "") { actions.commitDevTuning() } }
        HStack(spacing: 6) {
            Text(Self.stepsRowLabel)
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            TextField(Self.stepsPlaceholder, text: Binding(
                get: { tuning.stepsFieldText(label) },
                set: { tuning.setStepsEntry(label, $0) }))
                .textFieldStyle(.roundedBorder)
                .uiFont(.caption2, monospacedDigit: true)
                .onSubmit { commit(tuning.stepsFieldText(label)) }
            // Clearing is the one edit a typist gets wrong (an empty field
            // plus Return reads as "nothing happened"): one button, shown
            // only while there is something to clear, same commit path.
            if !rule.thresholdSteps.isEmpty {
                Button(Self.stepsClearLabel) { clear() }
                    .controlSize(.mini)
                    .uiControl("\(id).clear", kind: .button, read: { Self.stepsClearLabel }, activate: clear)
            }
        }
        .uiControl(id, kind: .field,
            // The registry reads the DRAFT, never the half-typed buffer:
            // a script asserts what is in force, not what someone is typing.
            read: { [tuning] in
                TuningPolicy.stepsText(tuning.draft.rule(for: label)?.thresholdSteps ?? [])
            },
            setText: commit)
        // What the numbers MEAN, in force right now: the base slider and the
        // staircase read back as one sentence, so "64:0.90" never has to be
        // decoded in the reader's head. Reads the draft, like the field.
        // While THIS class's entry is refused, the refusal takes the line
        // (the shared error row sits under eight class blocks, off screen
        // from the field being typed in); the draft's rule is unchanged.
        let refused = Self.refusal(tuning.editError, for: label)
        Text(refused ?? Self.stepsReadback(threshold: rule.threshold, steps: rule.thresholdSteps))
            .uiFont(.caption2)
            .foregroundStyle(refused == nil ? Color.secondary : Color(nsColor: .systemRed))
            .padding(.leading, 98)
            .fixedSize(horizontal: false, vertical: true)
            .uiControl("\(id).reads", kind: .text, read: { [tuning] in
                if let e = Self.refusal(tuning.editError, for: label) { return e }
                let r = tuning.draft.rule(for: label) ?? TuningPolicy.ClassRule(threshold: 0)
                return Self.stepsReadback(threshold: r.threshold, steps: r.thresholdSteps)
            })
    }

    /// The edit error, if it is about this class's staircase (the parser
    /// names the key: `classes.<label>.thresholdSteps…`), with that prefix
    /// dropped — the field it sits under is the key.
    static func refusal(_ editError: String?, for label: String) -> String? {
        guard let e = editError, e.hasPrefix("\"classes.\(label).thresholdSteps") else { return nil }
        return "refused: " + e.replacingOccurrences(of: "classes.\(label).thresholdSteps", with: "steps")
    }

    /// The staircase as the rule it states: "needs 0.80 under 64 pt, 0.90
    /// from 64 pt". Sizes are the box's shorter side in points
    /// (`TuningPolicy.sidePt`), the same measure `minBoxPt` uses.
    static func stepsReadback(threshold: Float, steps: [TuningPolicy.ClassRule.SizeStep]) -> String {
        let f = { (v: Float) in String(format: "%.2f", Double(v)) }
        guard let first = steps.first else { return "needs \(f(threshold)) at any size" }
        var parts = ["needs \(f(threshold)) under \(TuningPolicy.stepPtText(first.minPt)) pt"]
        for s in steps { parts.append("\(f(s.threshold)) from \(TuningPolicy.stepPtText(s.minPt)) pt") }
        return parts.joined(separator: ", ")
    }

    static let stepsRowLabel = "size steps"
    static let stepsPlaceholder = "none — e.g. 64:0.90, 128:0.95"
    static let stepsClearLabel = "Clear"
    /// One help line for the whole tab (eight fields share the grammar):
    /// what a step is, how it is written, and the four rules the parser
    /// refuses by name (`TuningPolicy.validateSteps`).
    static let stepsHelp = "Size steps raise a class's threshold for bigger boxes. Write size:threshold pairs, comma-separated, up to \(TuningPolicy.ClassRule.maxSteps) — 64:0.90 means a box 64 pt or larger (shorter side) needs 0.90. Sizes ascending; every step at or above the class threshold. Return applies; a refused entry is named below and nothing is written."

    /// The draft value behind a slider id (for the registry's live read).
    /// `thresholdSteps` is NOT here and must not be: it is text, not a
    /// Double, and its row's own `read` closure serves it (the selftest
    /// asserts the nil).
    static func current(id: String, in p: TuningPolicy) -> Double? {
        let parts = id.dropFirst(idPrefix.count + 1).split(separator: ".").map(String.init)
        switch parts {
        case ["coveredOverlap"]: return p.coveredOverlap
        case ["keepGap"]: return p.keepGap
        case ["curtain", "triggerHits"]: return Double(p.curtain.triggerHits)
        case ["curtain", "windowSecs"]: return p.curtain.windowSecs
        case ["curtain", "holdSecs"]: return p.curtain.holdSecs
        default:
            guard parts.count == 2, let r = p.rule(for: parts[0]) else { return nil }
            switch parts[1] {
            case "threshold": return Double(r.threshold)
            case "minBoxPt": return r.minBoxPt
            case "entryFrames": return Double(r.entryFrames)
            default: return nil
            }
        }
    }

    // MARK: Readout

    static let readoutEmptyText = "No policy-class detections in the last 60 s."

    private var readout: some View {
        let s = tuning.snapshot
        return VStack(alignment: .leading, spacing: 4) {
            if s.isEmpty {
                Text(Self.readoutEmptyText)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .uiControl("\(Self.idPrefix).readout.empty", kind: .text, read: { Self.readoutEmptyText })
            }
            readoutControls
            let shown = Array(s.rows.prefix(Self.visibleRows))
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                UIDevTrackRow(row: row)
                    .uiControl("\(Self.idPrefix).readout.row.\(i)", kind: .text,
                        read: { [tuning] in
                            tuning.snapshot.rows.indices.contains(i) ? Self.rowLine(tuning.snapshot.rows[i]) : ""
                        })
            }
            .animation(.easeInOut(duration: 0.35), value: shown.map(\.id))
            if s.rows.count > shown.count {
                Text(Self.moreRowsLine(s))
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                    .uiControl("\(Self.idPrefix).readout.more", kind: .text,
                        read: { [tuning] in Self.moreRowsLine(tuning.snapshot) })
            }
            if !s.rows.isEmpty { Divider() }
            Text(Self.dropLine(s))
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .uiControl("\(Self.idPrefix).readout.drop", kind: .text, read: { [tuning] in Self.dropLine(tuning.snapshot) })
            Text(Self.suppressedLine(s))
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .uiControl("\(Self.idPrefix).readout.suppressed", kind: .text,
                    read: { [tuning] in Self.suppressedLine(tuning.snapshot) })
            Text(Self.stepsLine(s))
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .uiControl("\(Self.idPrefix).readout.steps", kind: .text,
                    read: { [tuning] in Self.stepsLine(tuning.snapshot) })
            if s.overflow > 0 {
                UIInlineMessage(
                    text: "Readout hit ring full: \(s.overflow) in-window hits evicted "
                        + "(TuningReadout.capacity \(TuningReadout.capacity), UIDevTuning.swift)",
                    symbol: UISymbol.warning, tint: .systemOrange)
            }
            if s.framesOverflow > 0 {
                UIInlineMessage(
                    text: "Readout frame ring full: \(s.framesOverflow) in-window frames evicted "
                        + "(TuningReadout.frameCapacity \(TuningReadout.frameCapacity), UIDevTuning.swift)",
                    symbol: UISymbol.warning, tint: .systemOrange)
            }
            if s.tracksEvicted > 0 {
                UIInlineMessage(text: Self.tracksEvictedLine(s), symbol: UISymbol.warning, tint: .systemOrange)
                    .uiControl("\(Self.idPrefix).readout.tracksEvicted", kind: .text,
                        read: { [tuning] in Self.tracksEvictedLine(tuning.snapshot) })
            }
            if s.attributionSkipped > 0 {
                UIInlineMessage(text: Self.attributionSkippedLine(s), symbol: UISymbol.warning, tint: .systemOrange)
            }
        }
    }

    /// ROWS SHOWN on the tab. 12 (2026-10-20), ASSUMED: about what fits the
    /// popover's Developer page without the list pushing the footer out of
    /// sight; the rest are counted below the list ("+N more") and every row
    /// is in Copy, so nothing is hidden without saying so.
    static let visibleRows = 12

    static let freezeLabel = "Freeze"
    static let clearLabel = "Clear"
    static let copyReadoutLabel = "Copy readout"

    private var readoutControls: some View {
        let frozen = tuning.frozenAt != nil
        let freezeText = frozen ? "Frozen — live in \(tuning.freezeRemaining()) s" : Self.freezeLabel
        let toggle = { [tuning] in
            if tuning.frozenAt == nil { tuning.freeze() } else { tuning.unfreeze() }
        }
        return HStack(spacing: 8) {
            Button(freezeText, action: toggle)
                .controlSize(.small)
                .uiControl("\(Self.idPrefix).readout.freeze", kind: .toggle,
                    read: { [tuning] in tuning.frozenAt == nil ? "off" : "on" }, activate: toggle)
            Button(Self.clearLabel) { tuning.clearReadout() }
                .controlSize(.small)
                .uiControl("\(Self.idPrefix).readout.clear", kind: .button,
                    read: { Self.clearLabel }, activate: { [tuning] in tuning.clearReadout() })
            Button(Self.copyReadoutLabel) { tuning.copyReadout() }
                .controlSize(.small)
                .uiControl("\(Self.idPrefix).readout.copy", kind: .button,
                    read: { Self.copyReadoutLabel }, activate: { [tuning] in tuning.copyReadout() })
            Spacer(minLength: 0)
        }
    }

    /// "0.93 · floor 0.90" — the row's score text. Latest follows when it
    /// differs from the peak.
    static func scoreText(_ r: TuningReadout.TrackRow) -> String {
        var t = "\(TuningReadout.conf(r.peak)) · floor \(TuningReadout.conf(r.floor))"
        if r.latest != r.peak { t += " (latest \(TuningReadout.conf(r.latest)))" }
        return t
    }

    static func ageText(_ secs: Double) -> String { "\(Int(secs.rounded(.down))) s" }

    /// One row as text: what the row's id reads, and one line of Copy.
    static func rowLine(_ r: TuningReadout.TrackRow) -> String {
        let size = r.sidePt.map { "\(TuningReadout.fmt($0.rounded())) pt" } ?? "size unmeasured"
        return "\(r.status.symbol) \(r.code) \(scoreText(r)) \(size) \(r.app ?? "app unknown") \(ageText(r.ageSecs))"
            + " — \(r.status.text)" + (r.nearMiss ? " · near miss" : "")
    }

    static func moreRowsLine(_ s: TuningReadout.Snapshot) -> String {
        "+\(s.rows.count - min(s.rows.count, visibleRows)) more rows (UIDeveloperSettingsSection.visibleRows "
            + "\(visibleRows)); Copy readout has all \(s.rows.count)"
    }

    static func tracksEvictedLine(_ s: TuningReadout.Snapshot) -> String {
        "Readout track table full: \(s.tracksEvicted) rows evicted, lowest-ranked first "
            + "(TuningReadout.trackCapacity \(TuningReadout.trackCapacity), UIDevTuning.swift)"
    }

    static func attributionSkippedLine(_ s: TuningReadout.Snapshot) -> String {
        "\(s.attributionSkipped) frames counted without window or curtain mark (policy mirror disagreed "
            + "with the pipeline; TuningReadout.record)"
    }

    /// Copy readout: every row, ranked, then the footer and the per-class
    /// totals. Labels, numbers and app names only.
    static func readoutText(_ s: TuningReadout.Snapshot) -> String {
        var lines = ["SentryScreen Developer readout, last \(Int(TuningReadout.windowSecs)) s "
            + "(rank = peak × 0.5^(age / \(Int(TuningReadout.rankHalfLifeSecs)) s))"]
        lines += s.rows.map { "\(rowLine($0)) [\($0.label), window \($0.windowID.map { String($0) } ?? "-"), \($0.hits) hits]" }
        if s.rows.isEmpty { lines.append(readoutEmptyText) }
        lines += [dropLine(s), suppressedLine(s), stepsLine(s)]
        lines += s.classes.map(classLine)
        if s.tracksEvicted > 0 { lines.append(tracksEvictedLine(s)) }
        if s.attributionSkipped > 0 { lines.append(attributionSkippedLine(s)) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func classLine(_ c: TuningReadout.ClassStat) -> String {
        let pts = c.minPt.map { "\(TuningReadout.fmt($0))–\(TuningReadout.fmt(c.maxPt ?? $0)) pt" } ?? "size unmeasured"
        return "\(c.label): \(c.hits) hits, \(pts), max conf \(String(format: "%.2f", c.maxConf))"
    }

    static func dropLine(_ s: TuningReadout.Snapshot) -> String {
        guard let d = s.lastDrop else { return "Last curtain drop: none in the last 60 s" }
        return "Last curtain drop: \(d.action) window \(d.windowID)" + (d.app.map { " app=\($0)" } ?? "")
            + " at \(UIDevTuning.clock.string(from: Date(timeIntervalSinceReferenceDate: d.at)))"
    }

    /// All three counts are 60 s frame-ring sums (`FrameStat`), so none can
    /// be silently evicted while its neighbour is a true total.
    static func suppressedLine(_ s: TuningReadout.Snapshot) -> String {
        var line = "Suppressed: min box \(s.suppressedMinBox), covered-beats-exposed \(s.suppressedCovered)"
            + ", threshold step \(s.stepBoxesCut)"
        if let last = s.lastSuppression { line += " — last: \(last.rule.rawValue) · \(last.detail)" }
        return line
    }

    /// THE STAIRCASE LINE, always rendered. Three numbers, deliberately not
    /// one: on the owner's 2026-09-11 log a `FEMALE_BREAST_EXPOSED` step at
    /// ≥ 64 pt → 0.90 cut 898 boxes, emptied 40 of 1,552 blocked frames and
    /// moved 0 of 3 curtain drops. An operator reading "898 boxes" alone
    /// concludes the curtain changed; the parenthesis is what stops that.
    /// The curtain counts hits PER WINDOW, so the honest statement is about
    /// windows: on that one-window log a window was emptied exactly when the
    /// frame was; with several flagged windows a cut can empty one window
    /// while the frame still blocks, which this line cannot see.
    static func stepsLine(_ s: TuningReadout.Snapshot) -> String {
        "Threshold steps: \(s.stepBoxesCut) boxes cut, \(s.stepFramesEmptied) of \(s.blockedFrames) "
            + "blocked frames emptied (a cut moves a curtain drop only if it empties its window that frame)"
    }
}

/// One "Last 60 s" row: status, class code, a score bar with the class
/// floor marked, the score text, box size, app and age. A near miss (peak
/// within `TuningReadout.nearMissBand` under its floor) is tinted, because
/// those are the rows a floor change would flip.
struct UIDevTrackRow: View {
    let row: TuningReadout.TrackRow
    @Environment(\.uiTextScale) private var textScale

    /// Bar length in points at text scale 1. DERIVED: 0.01 of score per
    /// 0.64 pt, so a 0.05 near-miss gap is 3.2 pt, visible at a glance.
    static let barWidth: CGFloat = 64

    var body: some View {
        let w = UITypography.points(Self.barWidth, scale: textScale)
        let blocked = row.status == .curtain || row.status == .covered
        return HStack(spacing: 6) {
            Text(row.status.symbol)
                .uiFont(.caption, weight: .bold)
                .foregroundStyle(row.status == .curtain ? SentryColor.ok : SentryColor.ink)
                .frame(minWidth: 12)
            Text(row.code)
                .uiFont(.caption2, weight: .semibold)
                .frame(minWidth: 44, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle().fill(SentryColor.line)
                Rectangle()
                    .fill(blocked ? SentryColor.accent : SentryColor.muted)
                    .frame(width: w * CGFloat(min(1, max(0, row.peak))))
                Rectangle()
                    .fill(SentryColor.ink)
                    .frame(width: 2)
                    .offset(x: w * CGFloat(min(1, max(0, row.floor))) - 1)
            }
            .frame(width: w, height: 6)
            .accessibilityHidden(true)
            Text(UIDeveloperSettingsSection.scoreText(row))
                .uiFont(.caption2)
                .monospacedDigit()
            Spacer(minLength: 4)
            Text(row.sidePt.map { "\(TuningReadout.fmt($0.rounded())) pt" } ?? "—")
                .uiFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(row.app ?? "—")
                .uiFont(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Text(UIDeveloperSettingsSection.ageText(row.ageSecs))
                .uiFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(row.nearMiss ? SentryColor.accentSoft : Color.clear)
        .help(row.status.text + (row.nearMiss ? " · near miss" : ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UIDeveloperSettingsSection.rowLine(row))
    }
}
