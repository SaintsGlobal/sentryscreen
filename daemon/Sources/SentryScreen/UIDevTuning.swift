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
//     file.
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
        var isEmpty: Bool { classes.isEmpty && lastCurtain == nil && lastSuppression == nil }
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
    func record(
        raw: [Detection], filtered: TuningPolicy.Filtered, tuning: TuningPolicy,
        mode: PolicyMode, blockFaces: Bool, screen: CGSize, now: Double
    ) {
        guard !raw.isEmpty else { return }
        let measurable = screen.width > 0 && screen.height > 0
        var newHits: [Hit] = []
        var newSuppressions: [Suppression] = []
        let (demoted, _) = tuning.demoteCovered(raw)
        for (i, d) in raw.enumerated() {
            guard tuning.rule(for: d.label) != nil, d.label != TuningPolicy.injectLabel else { continue }
            let side: Double? = measurable
                ? Double(min(d.box.width * screen.width, d.box.height * screen.height)) : nil
            newHits.append(Hit(at: now, label: d.label, conf: d.confidence, sidePt: side))
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
        guard !newHits.isEmpty || !newSuppressions.isEmpty || keepFrame else { return }
        lock.lock()
        defer { lock.unlock() }
        let since = now - Self.windowSecs
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

    /// Demo / selftest only: back to empty.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
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

    /// The settings tick (1 Hz): refresh the 60 s readout.
    func tick(now: Double = CFAbsoluteTimeGetCurrent()) {
        let s = readout.snapshot(now: now)
        if s != snapshot { snapshot = s }
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
            ForEach(s.classes, id: \.label) { c in
                Text(Self.classLine(c))
                    .uiFont(.caption2)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .uiControl("\(Self.idPrefix).readout.\(c.label)", kind: .text,
                        read: { [tuning] in tuning.snapshot.classes.first { $0.label == c.label }.map(Self.classLine) ?? "" })
            }
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
        }
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
