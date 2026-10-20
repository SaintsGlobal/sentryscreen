import AppKit
import SwiftUI

// TUNING TOOL — the Detection view's words and its two UI surfaces.
// Every string a person reads on the overlay, in
// Settings › Developer and in the popover row is in `DetectionViewCopy`, so
// the chips, the legend, the tab and the snapshot can never describe the same
// decision in two different ways. The overlay (DetectionViewOverlay.swift)
// draws what this file says; the controller (DetectionViewController.swift)
// decides when.

/// How a box is drawn. Colour, line style AND words all carry the decision,
/// so it reads without colour vision and in a screenshot.
enum DetectionViewStyle: String, CaseIterable {
    /// Covered (Outline over covers), or would be (Detections only).
    case covered
    /// Passed the policy, not covered yet: entry frames, curtain hits, a
    /// skipped curtain walk, no region cover this frame.
    case pending
    /// Not covered, and the label names what stopped it: a tuning key (min
    /// box, size step, demotion), the sensitivity, `--roi`, or a curtain
    /// walk check (orphan, straddle, size floor, ghost ban, not held at
    /// capture). `DetectionViewExplanation.ruleKind` says which kind.
    case dropped
    /// Under its class threshold: the common, boring case, drawn faintly.
    case belowThreshold = "below-threshold"
    /// Not a policy class (faces, covered classes in Standard…): hidden
    /// unless "Show non-policy classes" is on.
    case nonPolicy = "non-policy"
    /// Under the detector's `--conf` floor: shown only while "Show weak
    /// detections" is on, never covered.
    case weak

    /// Which decision wins when a box has two (region and curtain).
    var rank: Int {
        switch self {
        case .weak: return -1
        case .covered: return 4
        case .pending: return 3
        case .dropped: return 2
        case .belowThreshold: return 1
        case .nonPolicy: return 0
        }
    }
}

/// One box's decision in words, plus the tuning handle behind it. The chip
/// draws `lines`; the snapshot carries every field.
struct DetectionViewExplanation: Equatable {
    /// What kind of handle `ruleKey` is, so a snapshot reader knows where a
    /// change would go: tuning.json, the Sensitivity setting, a launch
    /// flag, or a receipted constant in code (not tunable at run time).
    enum RuleKind: String {
        case tuning, sensitivity, flag, constant
    }

    var style: DetectionViewStyle
    /// Machine name for the snapshot ("covered", "min-box", "orphan", …).
    var outcome: String
    /// The chip's lines under the "CLASS 0.83" title.
    var lines: [String]
    /// The setting or check that decided it: a tuning file key, `policy`,
    /// a flag (`--roi`), or a code constant.
    var ruleKey: String?
    var ruleKind: RuleKind?
    var inForce: String?
    var observed: String?
    /// The change that would flip this box's outcome.
    var flipsAt: String?
}

enum DetectionViewCopy {
    // MARK: Numbers

    static func f2(_ x: Double) -> String { String(format: "%.2f", x) }
    static func f2(_ x: Float) -> String { f2(Double(x)) }
    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }
    static func pt(_ x: Double) -> String { String(format: "%.0f", x) }
    /// Box-area fractions are tiny (0.0005); four decimals keep them honest.
    static func area(_ x: Double) -> String { String(format: "%.4f", x) }

    /// "4:12" — the time left before the view turns itself off.
    static func countdown(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs.rounded(.up)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: Chips

    /// Chip line 1: the class the detector said and its score.
    static func title(_ b: DetectionTrace.Box) -> String {
        "\(b.rawLabel) \(f2(b.confidence))" + (b.synthetic ? " · synthetic" : "")
    }

    /// Chip line 1 for a curtain window.
    static func windowTitle(_ w: DetectionTrace.CurtainWindow) -> String {
        "\(w.app ?? "Window") · window \(w.id)"
    }

    /// The decision for one box, naming the rule and its value.
    static func explain(
        _ b: DetectionTrace.Box, trace: DetectionTrace, mode: DetectionViewMode
    ) -> DetectionViewExplanation {
        let conf = f2(b.confidence)
        let classKey = "classes.\(b.label)"
        var lines: [String] = []
        if let d = b.demotion {
            lines.append("demoted → \(d.to) (overlap \(f2(d.overlap)) ≥ \(f2(d.minOverlap)))")
        }
        if let from = b.recheckFrom {
            lines.append(from == 0
                ? "found by the settle re-check (\(Pipeline.settleShiftPx) px shift)"
                : "settle re-check raised \(f2(from)) → \(conf)")
        }
        func out(_ style: DetectionViewStyle, _ outcome: String, _ line: String, key: String? = nil,
            kind: DetectionViewExplanation.RuleKind = .tuning, inForce: String? = nil, observed: String? = nil,
            flipsAt: String? = nil) -> DetectionViewExplanation
        {
            DetectionViewExplanation(style: style, outcome: outcome, lines: lines + [line],
                ruleKey: key, ruleKind: key == nil ? nil : kind, inForce: inForce, observed: observed,
                flipsAt: flipsAt)
        }
        switch b.policy {
        case .notPolicyClass:
            return out(.nonPolicy, "not-policy-class", "not a policy class — never covered")
        case let .belowThreshold(threshold):
            return out(.belowThreshold, "below-threshold", "below threshold \(conf) < \(f2(threshold))",
                key: "\(classKey).threshold", inForce: f2(threshold), observed: conf,
                flipsAt: "threshold ≤ \(conf)")
        case let .classOffInPolicy(policy):
            // `strict` holds exactly the covered classes (TuningPolicy.defaults).
            let line = "covered-class boxes block only in Strict (now \(policy.displayName))"
            if let d = b.demotion {
                return out(.dropped, "demoted", line, key: "coveredOverlap", inForce: f2(d.minOverlap),
                    observed: f2(d.overlap),
                    flipsAt: "coveredOverlap > \(f2(d.overlap)), or coveredBeatsExposed off")
            }
            return out(.dropped, "class-off", line, key: "policy", kind: .sensitivity, inForce: policy.rawValue,
                flipsAt: "Strict sensitivity")
        case let .minBox(sidePt, minBoxPt, minBoxFraction):
            let boxArea = Double(b.rect.width * b.rect.height)
            if minBoxFraction > 0, boxArea < minBoxFraction {
                return out(.dropped, "min-box",
                    "min box area \(area(boxArea)) < \(area(minBoxFraction)) (minBoxFraction)",
                    key: "\(classKey).minBoxFraction", inForce: area(minBoxFraction),
                    observed: area(boxArea), flipsAt: "minBoxFraction ≤ \(area(boxArea))")
            }
            guard let side = sidePt else {
                return out(.dropped, "min-box", "min box: size unknown (minBoxPt \(pt(minBoxPt)))",
                    key: "\(classKey).minBoxPt", inForce: pt(minBoxPt))
            }
            return out(.dropped, "min-box", "min box \(pt(side)) < \(pt(minBoxPt)) pt (minBoxPt)",
                key: "\(classKey).minBoxPt", inForce: pt(minBoxPt), observed: pt(side),
                flipsAt: "minBoxPt ≤ \(pt(side))")
        case let .thresholdStep(floor, stepMinPt, _):
            return out(.dropped, "threshold-step",
                "size step \(conf) < \(f2(floor)) from \(pt(stepMinPt)) pt (thresholdSteps)",
                key: "\(classKey).thresholdSteps", inForce: "\(pt(stepMinPt)):\(f2(floor))",
                observed: conf, flipsAt: "that step's threshold ≤ \(conf)")
        case .outsideROI:
            return out(.dropped, "outside-roi", "outside the --roi rectangle", key: "--roi", kind: .flag)
        case let .weak(detectorConf):
            return out(.weak, "weak", "weak: \(conf) < detector floor \(f2(detectorConf)) — shown only, never covered",
                key: "--conf", kind: .flag, inForce: f2(detectorConf), observed: conf)
        case let .kept(start, keep, _):
            // Passed by hysteresis (region/media only); the region line follows.
            lines.append("kept: \(conf) ≥ keep \(f2(keep)) (tracked; starts at \(f2(start)))")
        case .passes:
            break
        }
        // Under a painted curtain (its centre is inside one, so it never
        // reached the region tracker): covered, whatever this frame's walk
        // said. The walk's result rides along as a secondary line, so a
        // skipped walk never makes a covered box look pending.
        if b.region == .underCurtain {
            let centre = CGPoint(x: b.rect.midX, y: b.rect.midY)
            let holder = trace.windows.first { w in
                if case .curtained = w.state { return w.frame.contains(centre) }
                return false
            }
            let verdict = "\(coverWord(mode)) by a curtain" + (holder.map { " (window \($0.id))" } ?? "")
            var walk = b.curtain.map { walkFacts($0, trace: trace) } ?? []
            if !walk.isEmpty { walk[0] = "walk: " + walk[0] }
            return DetectionViewExplanation(style: .covered, outcome: "under-curtain",
                lines: lines + [verdict] + walk)
        }
        // Passed the policy: the region tracker and the curtain decide.
        var decisions: [DetectionViewExplanation] = []
        if let r = b.region { decisions.append(region(r, label: b.label, mode: mode)) }
        if let c = b.curtain { decisions.append(curtain(c, trace: trace, mode: mode)) }
        guard let decisive = decisions.max(by: { $0.style.rank < $1.style.rank }) else {
            return out(.pending, "passes", "passes the policy — no cover decision this frame")
        }
        var e = decisive
        e.lines = lines + decisions.flatMap(\.lines)
        return e
    }

    private static func coverWord(_ mode: DetectionViewMode) -> String {
        mode == .detectionsOnly ? "would be covered" : "covered"
    }

    private static func region(
        _ r: DetectionTrace.RegionOutcome, label: String, mode: DetectionViewMode
    ) -> DetectionViewExplanation {
        switch r {
        case let .covered(id):
            return .init(style: .covered, outcome: "covered", lines: ["\(coverWord(mode)) · region \(id)"])
        case let .entryPending(seen, needed):
            return .init(style: .pending, outcome: "entry-pending",
                lines: ["entry \(seen)/\(needed) frames (entryFrames)"],
                ruleKey: "classes.\(label).entryFrames", ruleKind: .tuning, inForce: "\(needed)",
                observed: "\(seen)", flipsAt: "entryFrames ≤ \(seen)")
        case .underCurtain:
            // `explain` decides this case itself (covered by the curtain).
            return .init(style: .covered, outcome: "under-curtain", lines: ["\(coverWord(mode)) by a curtain"])
        case .notCovered:
            return .init(style: .pending, outcome: "not-covered", lines: ["passed — no region cover this frame"])
        }
    }

    /// What the curtain walk found for a box, as plain facts (no verdict):
    /// the chip's walk lines, and the secondary line under "covered by a
    /// curtain".
    static func walkFacts(_ c: DetectionTrace.CurtainOutcome, trace: DetectionTrace) -> [String] {
        let gate = f2(WindowTracker.minContainedFraction)
        func holder(_ to: CGWindowID?) -> [String] {
            to.map { ["credited to window \($0) (its content holds the box)"] } ?? []
        }
        switch c {
        case let .credited(id): return ["credited to window \(id)"]
        case let .trailRedirect(from, to): return ["redirected from window \(from) to \(to) (drag trail)"]
        case .orphan: return ["no window under it (orphan)"]
        case let .straddle(front, held, to):
            return ["straddles window \(front): \(f2(held)) inside < \(gate)"] + holder(to)
        case let .windowBelowFloor(id): return ["window \(id) is under the curtain size floor"]
        case let .ghostBanned(id): return ["window \(id) ignored (ghost ban)"]
        case let .notHeldAtCapture(id, ringYoung, to):
            return ["window \(id) did not hold it at capture" + (ringYoung ? " (ring too young)" : "")] + holder(to)
        case .walkSkipped:
            if case let .skipped(every) = trace.walk { return ["curtain walk skipped (runs every \(every) frames)"] }
            return ["curtain walk skipped this frame"]
        }
    }

    private static func curtain(
        _ c: DetectionTrace.CurtainOutcome, trace: DetectionTrace, mode: DetectionViewMode
    ) -> DetectionViewExplanation {
        let facts = walkFacts(c, trace: trace)
        /// `lead`: the lines that explain HOW the box reached this window
        /// (a trail redirect, a holder's content), above the verdict.
        func credited(_ id: CGWindowID, lead: [String] = []) -> DetectionViewExplanation {
            switch trace.windows.first(where: { $0.id == id })?.state {
            case .curtained:
                return .init(style: .covered, outcome: "covered",
                    lines: lead + ["\(coverWord(mode)) · window \(id) curtained"])
            case let .pending(hits, required, bar):
                return .init(style: .pending, outcome: "curtain-pending",
                    lines: lead + ["window \(id) · \(hits)/\(required) hits (\(bar.rawValue))"],
                    ruleKey: "curtain.\(bar.rawValue)", ruleKind: .tuning, inForce: "\(required)",
                    observed: "\(hits)", flipsAt: "\(bar.rawValue) ≤ \(hits)")
            default:
                return .init(style: .pending, outcome: "credited", lines: lead + ["credited to window \(id)"])
            }
        }
        /// Not covered by a walk check: a receipted constant in code, not a
        /// tuning key.
        func check(_ outcome: String, _ key: String, inForce: String? = nil, observed: String? = nil)
            -> DetectionViewExplanation
        {
            .init(style: .dropped, outcome: outcome, lines: facts, ruleKey: key, ruleKind: .constant,
                inForce: inForce, observed: observed)
        }
        let gate = f2(WindowTracker.minContainedFraction)
        switch c {
        case let .credited(id):
            return credited(id)
        case let .trailRedirect(_, to):
            return credited(to, lead: facts)
        case .orphan:
            return check("orphan", "curtain walk: no window holds the box")
        case let .straddle(_, held, rewoundTo):
            if let to = rewoundTo { return credited(to, lead: facts) }
            return check("straddle", "WindowTracker.minContainedFraction", inForce: gate, observed: f2(held))
        case .windowBelowFloor:
            return check("window-below-floor", "Curtain.minCurtainSize")
        case .ghostBanned:
            return check("ghost-banned", "Curtain.ghostBanSecs")
        case let .notHeldAtCapture(_, _, rewoundTo):
            if let to = rewoundTo { return credited(to, lead: facts) }
            return check("not-held-at-capture", "WindowTracker.minContainedFraction", inForce: gate)
        case .walkSkipped:
            return .init(style: .pending, outcome: "walk-skipped", lines: facts,
                ruleKey: "curtain walk cadence (Curtain walkEvery)", ruleKind: .constant)
        }
    }

    /// A curtain window's state line.
    static func windowState(_ w: DetectionTrace.CurtainWindow, mode: DetectionViewMode) -> String {
        switch w.state {
        case let .pending(hits, required, bar):
            return "\(hits)/\(required) hits (\(bar.rawValue)) · no curtain yet"
        case let .curtained(holdLeft, clean, needed):
            let word = mode == .detectionsOnly ? "would be curtained" : "curtained"
            return "\(word) · lifts in \(f1(holdLeft)) s (holdSecs) · clean \(clean)/\(needed) (holdCleanFrames)"
        case let .leaving(kind, forSecs):
            return "leaving (\(kind)) · \(f1(forSecs)) s"
        case .lingering:
            return "lingering after its curtain lifted"
        }
    }

    // MARK: Badge (top centre, always drawn while the view is visible)

    /// D4: the popover header in Detections only, and the badge's lead.
    static let protectionOffHeader = "Protection off · Detection view"
    static let protectionOffDetailPrefix = "Covers are hidden until it turns off at "
    static let badgeOffSubtitle = "Covers are hidden. Turn it off from the menu bar."
    static let badgeOverCovers = "Detection view · outlines over covers"

    static func badgeLines(mode: DetectionViewMode, remaining: TimeInterval) -> [String] {
        let left = countdown(remaining)
        switch mode {
        case .detectionsOnly: return ["\(protectionOffHeader) · \(left)", badgeOffSubtitle]
        case .outlineOverCovers: return ["\(badgeOverCovers) · \(left)"]
        case .off: return []
        }
    }

    // MARK: Legend (bottom left)

    static let legendTitle = "What the lines mean"

    static func legendText(_ style: DetectionViewStyle, mode: DetectionViewMode) -> String {
        switch style {
        case .covered:
            return mode == .detectionsOnly
                ? "Would be covered (covers are hidden)" : "Covered — by a region cover or a curtain"
        case .pending: return "Passed, not covered yet — the label says what it waits for"
        case .dropped: return "Not covered — the label names the rule or check"
        case .belowThreshold: return "Below its class threshold"
        case .nonPolicy: return "Not a policy class — never covered"
        case .weak: return "Weak — under the detector floor, shown only, never covered"
        }
    }

    static let legendWindow = "Curtain window — solid: curtained · dashed: building hits · dotted: leaving or lingering"
    static let legendLabels = "Label: class and score, then the decision with its rule and value"
    static let legendLabelsHidden = "Labels hidden — hover a box to see why"

    // MARK: HUD (top right)

    struct HUDLine: Equatable {
        let text: String
        let warning: Bool
    }

    static let hudWaiting = "waiting for the first detector frame — nothing to explain yet"

    static func hud(
        _ trace: DetectionTrace?, now: CFAbsoluteTime, drawMs: Double?, overBudgetMs: Double?,
        hiddenNonPolicy: Int, synthetic: Bool, crowded: Int = 0
    ) -> [HUDLine] {
        var lines: [HUDLine] = []
        func info(_ s: String) { lines.append(HUDLine(text: s, warning: false)) }
        func warn(_ s: String) { lines.append(HUDLine(text: s, warning: true)) }
        guard let t = trace else {
            info(hudWaiting)
            if synthetic { warn(syntheticWarning) }
            return lines
        }
        let s = t.stats
        info("frame \(t.seq) · \(f1(max(0, now - t.builtAt))) s ago · \(f1(s.evaluatedFps)) fps evaluated · \(s.idleSkipped) idle-skipped")
        info("detect \(f1(s.detectMs)) ms · step \(f1(s.stepMs)) ms · trace \(f1(s.traceMs)) ms"
            + (drawMs.map { " · draw \(f1($0)) ms" } ?? ""))
        if s.budgetedMs > DetectionTraceBuilder.traceBudgetMs {
            warn("trace \(f1(s.budgetedMs)) ms without app-name lookups > "
                + "\(f1(DetectionTraceBuilder.traceBudgetMs)) ms (DetectionTraceBuilder.traceBudgetMs)")
        }
        info("\(t.policy.displayName) · cover \(t.coverMode) · tuning: \(t.tuningSource)")
        let changed = nonDefaults(t.tuning)
        info(changed.isEmpty ? "every rule at its default" : "changed: " + changed.joined(separator: ", "))
        info(entryAndBars(t.tuning, curtain: t.coverMode == "curtain"))
        if t.coverMode == "curtain" { info("curtain walk: " + walkText(t.walk)) }
        let weak = t.boxes.filter(\.isWeak).count
        info("\(t.boxes.count - weak) boxes" + (hiddenNonPolicy > 0 ? " · \(hiddenNonPolicy) non-policy hidden" : "")
            + (weak > 0 ? " · \(weak) weak (view only)" : ""))
        if t.detectorFailed { warn("detector failed this frame — covers held, no boxes") }
        if crowded > 0 {
            warn("\(crowded) label(s) overlap others: no free spot within DetectionViewLayout.scanSteps "
                + "\(DetectionViewLayout.scanSteps) × \(Int(DetectionViewLayout.scanStep)) pt")
        }
        if t.boxesOverflow > 0 {
            warn("+\(t.boxesOverflow) not drawn (DetectionTraceBuilder.maxBoxes \(DetectionTraceBuilder.maxBoxes))")
        }
        if t.walkUnattributed > 0 {
            warn("\(t.walkUnattributed) blocked box(es) got no curtain walk outcome — recorder and walk "
                + "disagree (fix: CurtainTraceRecorder.note sites in Curtain.update)")
        }
        if let ms = overBudgetMs {
            warn("draw \(f1(ms)) ms > \(f1(DetectionViewOverlay.renderBudgetMs)) ms (DetectionViewOverlay.renderBudgetMs)")
        }
        if synthetic { warn(syntheticWarning) }
        return lines
    }

    static let syntheticWarning = "synthetic test boxes on — the covers they trigger are real"

    static func walkText(_ w: DetectionTrace.CurtainWalk) -> String {
        switch w {
        case .ran: return "ran"
        case let .skipped(every): return "skipped (runs every \(every) frames)"
        case .noBlockedBoxes: return "nothing blocked"
        case .notCurtainMode: return "not curtain mode"
        }
    }

    /// entryFrames (one value when every class agrees) and the curtain bars.
    static func entryAndBars(_ p: TuningPolicy, curtain: Bool) -> String {
        let entries = Set(p.standard.values.map(\.entryFrames) + p.strict.values.map(\.entryFrames))
        let entry = "entryFrames " + entries.sorted().map(String.init).joined(separator: "/")
        guard curtain else { return entry }
        let c = p.curtain
        return "\(entry) · triggerHits \(c.triggerHits) · handoffHits \(c.handoffHits) · "
            + "paroleHits \(c.paroleHits) · holdSecs \(f1(c.holdSecs))"
    }

    /// Every rule that differs from `TuningPolicy.defaults`, as `key value`.
    static func nonDefaults(_ p: TuningPolicy) -> [String] {
        let d = TuningPolicy.defaults
        var out: [String] = []
        let labels = Set(p.standard.keys).union(p.strict.keys).subtracting([TuningPolicy.injectLabel]).sorted()
        for label in labels {
            guard let r = p.rule(for: label) else { continue }
            let base = d.rule(for: label) ?? TuningPolicy.ClassRule(threshold: -1)
            if r.threshold != base.threshold { out.append("\(label).threshold \(f2(r.threshold))") }
            if r.minBoxPt != base.minBoxPt { out.append("\(label).minBoxPt \(pt(r.minBoxPt))") }
            if r.minBoxFraction != base.minBoxFraction { out.append("\(label).minBoxFraction \(area(r.minBoxFraction))") }
            if r.entryFrames != base.entryFrames { out.append("\(label).entryFrames \(r.entryFrames)") }
            if r.thresholdSteps != base.thresholdSteps {
                out.append("\(label).thresholdSteps \(TuningPolicy.stepsText(r.thresholdSteps))")
            }
        }
        if p.coveredBeatsExposed != d.coveredBeatsExposed { out.append("coveredBeatsExposed \(p.coveredBeatsExposed)") }
        if p.coveredOverlap != d.coveredOverlap { out.append("coveredOverlap \(f2(p.coveredOverlap))") }
        if p.keepGap != d.keepGap { out.append("keepGap \(f2(p.keepGap))") }
        if p.settleRecheck != d.settleRecheck { out.append("settleRecheck \(p.settleRecheck)") }
        if p.zoomTiles != d.zoomTiles { out.append("zoomTiles \(p.zoomTiles)") }
        let c = p.curtain, dc = d.curtain
        if c.triggerHits != dc.triggerHits { out.append("curtain.triggerHits \(c.triggerHits)") }
        if c.windowSecs != dc.windowSecs { out.append("curtain.windowSecs \(f2(c.windowSecs))") }
        if c.handoffHits != dc.handoffHits { out.append("curtain.handoffHits \(c.handoffHits)") }
        if c.paroleHits != dc.paroleHits { out.append("curtain.paroleHits \(c.paroleHits)") }
        if c.holdSecs != dc.holdSecs { out.append("curtain.holdSecs \(f1(c.holdSecs))") }
        if c.holdCleanFrames != dc.holdCleanFrames { out.append("curtain.holdCleanFrames \(c.holdCleanFrames)") }
        if p.tracker != d.tracker { out.append("tracker rules changed") }
        return out
    }

    // MARK: Settings › Developer

    static let sectionTitle = "Detection view"
    static let sectionCaption = "Draws what the detector sees on each frame and why each box was or wasn't covered. Turns itself off after 5 minutes."

    static func modeName(_ m: DetectionViewMode) -> String {
        switch m {
        case .off: return "Off"
        case .detectionsOnly: return "Detections only"
        case .outlineOverCovers: return "Outline over covers"
        }
    }

    static func modeCaption(_ m: DetectionViewMode) -> String {
        switch m {
        case .off: return "Nothing is drawn. Protection works normally."
        case .detectionsOnly: return "Covers and curtains are hidden so you can see what is under them. Protection is off while this is on."
        case .outlineOverCovers: return "Protection stays on. Outlines draw over the covers; hover a box to see its label."
        }
    }

    static let syntheticLabel = "Synthetic test boxes"
    static let syntheticCaption = "Adds fixed fake detections — no real content. They run through the whole pipeline, so real covers appear over them."
    static let nonPolicyLabel = "Show non-policy classes"
    static let nonPolicyCaption = "Also outlines faces and other classes the policy never covers."
    static let labelsLabel = "Show box labels"
    static let labelsCaption = "Off: outlines only — hover a box to see its label."
    static let weakLabel = "Show weak detections"
    static let weakCaption = "Also outlines boxes the detector scored under 0.25. View only: they never reach a cover or curtain."
    static func weakFloorText(_ f: Float) -> String { "From score \(f2(f))" }
    static let renewLabel = "Renew"
    static let snapshotLabel = "Snapshot this frame"
    static let legendDisclosure = "What the colors mean"
    static let statusOff = "Off"
    static let optionsDisclosure = "Options"
    /// The closed Options fold's note: which options are on ("2 on"), nil
    /// when none is.
    static func optionsOn(synthetic: Bool, nonPolicy: Bool, labels: Bool, weak: Bool) -> String? {
        let n = [synthetic, nonPolicy, labels, weak].filter { $0 }.count
        return n == 0 ? nil : "\(n) on"
    }
    static let statusWaiting = "On — waiting for capture to hide the view from the detector…"

    static func statusOn(until: Date) -> String { "On — turns off at \(UIState.clockTime.string(from: until))" }

    static func snapshotStamp(at: Date, boxes: Int) -> String {
        "Copied at \(snapshotClock.string(from: at)) · \(boxes) box\(boxes == 1 ? "" : "es") · also in run.jsonl"
    }

    static let snapshotClock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    // MARK: PIN prompts (UIActions)

    static func pinTurnOn(_ m: DetectionViewMode) -> String { "Turn on the Detection view: \(modeName(m))." }
    static let pinTurnOnNote = "Covers are hidden while it is on. It turns off by itself after 5 minutes."
    static let pinRenew = "Keep the Detection view on for 5 more minutes."
    static let pinSynthetic = "Add synthetic test boxes to the detector."

    // MARK: Popover row

    static let rowSnapshot = "Snapshot"
    static let rowTurnOff = "Turn off"

    static func rowText(mode: DetectionViewMode, remaining: TimeInterval) -> String {
        "Detection view · \(modeName(mode)) · \(countdown(remaining)) left"
    }

    // MARK: Refusals (named, with the fix location)

    static let refusedNoPipeline = "The Detection view needs protection running — nothing to show yet (fix: start capture; DetectionViewController.attach)."
    static let refusedHeadless = "The Detection view is refused under --process or --replay: the gate's logs must not move (Pipeline.setDetectionTrace)."
    static let refusedNoScreen = "No display to draw the Detection view on (fix: DetectionViewHost.detectionViewScreen)."
    static let refusedNotOn = "Turn the Detection view on first."
    static let refusedNoFrame = "No detector frame yet — try again in a moment."
    static let refusedPaused = "Protection is paused — the Detection view stays off until it resumes (Pipeline.enterPause)."
    static let refusedNoCapture = "Capture is not running — nothing to show (fix: start capture; DetectionViewHost.detectionViewUnavailable)."
    static let refusedSynthetic = "Synthetic test boxes refused: a crop writer is attached and they would become crops (fix: run without the crop flag; Pipeline.setSyntheticDetections)."

    static func refusedExclusion(budget: Int) -> String {
        "Turned off: capture could not hide the Detection view from the detector after \(budget) attempts (fix: Capture.refreshExclusion)."
    }
}

// MARK: - Settings › Developer section

/// The Detection view block of Settings › Developer. Ids:
/// `ui.settings.developer.detectionview.*`.
struct UIDetectionViewSection: View {
    @ObservedObject var actions: UIActions
    @ObservedObject var view: DetectionViewController
    @State private var legendOpen = false
    /// The four drawing options, folded (VM render 2026-10-20: with their
    /// captions they were half the card). Closed, the fold names the ones
    /// that are on.
    @State private var optionsOpen = false

    static let idPrefix = "ui.settings.developer.detectionview"

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.labelGap) {
            UISectionLabel(text: DetectionViewCopy.sectionTitle)
            UISection {
                VStack(alignment: .leading, spacing: 8) {
                    Text(DetectionViewCopy.sectionCaption)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    modePicker
                    Text(DetectionViewCopy.modeCaption(view.mode))
                        .uiFont(.caption2)
                        .foregroundStyle(view.mode == .detectionsOnly ? Color(nsColor: .systemRed) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiControl("\(Self.idPrefix).mode.caption", kind: .text,
                            read: { [view] in DetectionViewCopy.modeCaption(view.mode) })
                    // Off, the radio and its caption already say so; the
                    // status line ("Off" a third time) shows only while on.
                    if view.isOn { statusRow }
                    Divider()
                    optionsToggle
                    if optionsOpen {
                        toggleRow(DetectionViewCopy.syntheticLabel, caption: DetectionViewCopy.syntheticCaption,
                            id: "synthetic", isOn: { [view] in view.synthetic }) { actions.setDetectionViewSynthetic($0) }
                        toggleRow(DetectionViewCopy.nonPolicyLabel, caption: DetectionViewCopy.nonPolicyCaption,
                            id: "nonpolicy", isOn: { [view] in view.showNonPolicy }) { view.setShowNonPolicy($0) }
                        // No PIN: labels change what the view draws, never protection.
                        toggleRow(DetectionViewCopy.labelsLabel, caption: DetectionViewCopy.labelsCaption,
                            id: "labels", isOn: { [view] in view.showLabels }) { view.setShowLabels($0) }
                        // No PIN: weak boxes reach the trace only, never protection.
                        toggleRow(DetectionViewCopy.weakLabel, caption: DetectionViewCopy.weakCaption,
                            id: "weak", isOn: { [view] in view.showWeak }) { view.setShowWeak($0) }
                        if view.showWeak { weakSlider }
                    }
                    Divider()
                    // The snapshot block has its own rule under it only when
                    // something is in it (off and unrefused, it is empty).
                    if view.isOn || view.refusal != nil {
                        if view.isOn { snapshotRow }
                        if let refusal = view.refusal {
                            UIInlineMessage(text: refusal, symbol: UISymbol.warning, tint: .systemRed)
                                .uiControl("\(Self.idPrefix).refusal", kind: .text, read: { [view] in view.refusal ?? "" })
                        }
                        Divider()
                    }
                    legend
                }
            }
        }
    }

    /// `.radioGroup`, NOT `.segmented` (the same finding as
    /// `UISettingsSheet.settingsChoice`): MEASURED 2026-09-24 on a test Mac,
    /// the segmented "Off | Detections only | Outline over covers" pushed
    /// every Developer-tab control to right 330 pt in the 320 pt sheet
    /// and clipped the section's copy.
    private var modePicker: some View {
        Picker(DetectionViewCopy.sectionTitle, selection: Binding(
            get: { view.mode }, set: { actions.selectDetectionViewMode($0, returnTo: .settings) }))
        {
            ForEach(DetectionViewMode.allCases, id: \.self) { m in
                Text(DetectionViewCopy.modeName(m)).tag(m)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .uiFont(.caption)
        .uiControl("\(Self.idPrefix).mode", kind: .picker, read: { [view] in view.mode.rawValue },
            setText: { raw in
                guard let m = DetectionViewMode(rawValue: raw) else { return }
                actions.selectDetectionViewMode(m, returnTo: .settings)
            })
    }

    private var optionsToggle: some View {
        let toggle = { optionsOpen.toggle() }
        let on = DetectionViewCopy.optionsOn(synthetic: view.synthetic, nonPolicy: view.showNonPolicy,
            labels: view.showLabels, weak: view.showWeak)
        return Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: UISymbol.disclosure)
                    .uiFont(.caption2, weight: .semibold)
                    .rotationEffect(.degrees(optionsOpen ? 90 : 0))
                Text(DetectionViewCopy.optionsDisclosure).uiFont(.caption)
                if !optionsOpen, let on {
                    Text(on).uiFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(optionsOpen ? "Expanded" : "Collapsed")
        .uiControl("\(Self.idPrefix).options", kind: .button, read: { optionsOpen ? "open" : "closed" },
            activate: toggle)
    }

    private var statusText: String {
        guard view.isOn, let until = view.offAt else { return DetectionViewCopy.statusOff }
        return view.exclusion == .confirmed ? DetectionViewCopy.statusOn(until: until) : DetectionViewCopy.statusWaiting
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .uiFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .uiControl("\(Self.idPrefix).status", kind: .text, read: { [view] in
                    guard view.isOn, let until = view.offAt else { return DetectionViewCopy.statusOff }
                    return view.exclusion == .confirmed
                        ? DetectionViewCopy.statusOn(until: until) : DetectionViewCopy.statusWaiting
                })
            Spacer(minLength: 0)
            if view.isOn {
                Button(DetectionViewCopy.renewLabel) { actions.renewDetectionView(returnTo: .settings) }
                    .controlSize(.small)
                    .uiControl("\(Self.idPrefix).renew", kind: .button, read: { DetectionViewCopy.renewLabel },
                        activate: { actions.renewDetectionView(returnTo: .settings) })
            }
        }
    }

    private func toggleRow(
        _ label: String, caption: String, id: String, isOn: @escaping () -> Bool, set: @escaping (Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: isOn, set: set)) { Text(label).uiFont(.caption) }
                .toggleStyle(.checkbox)
                .uiControl("\(Self.idPrefix).\(id)", kind: .toggle, read: { isOn() ? "on" : "off" },
                    activate: { set(!isOn()) })
            Text(caption)
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var weakSlider: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { Double(view.weakFloor) }, set: { view.setWeakFloor(Float($0)) }),
                in: Double(Pipeline.weakFloorMin)...Double(DetectionViewController.weakMax - 0.01), step: 0.01)
                .controlSize(.small)
                .uiControl("\(Self.idPrefix).weak.floor", kind: .field,
                    read: { [view] in DetectionViewCopy.f2(view.weakFloor) },
                    setText: { [view] raw in if let f = Float(raw) { view.setWeakFloor(f) } })
            Text(DetectionViewCopy.weakFloorText(view.weakFloor))
                .uiFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 20)
        // The UI scripts scroll here to show the slider (devtab-steadiness).
        .uiScrollAnchor("\(Self.idPrefix).weak.floor")
    }

    private var snapshotRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(DetectionViewCopy.snapshotLabel) { actions.snapshotDetectionView() }
                .controlSize(.small)
                .disabled(!view.isOn)
                .uiControl("\(Self.idPrefix).snapshot", kind: .button, read: { DetectionViewCopy.snapshotLabel },
                    activate: { actions.snapshotDetectionView() }, enabled: { [view] in view.isOn })
            if let s = view.lastSnapshot {
                Text(DetectionViewCopy.snapshotStamp(at: s.at, boxes: s.boxes))
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                    .uiControl("\(Self.idPrefix).snapshot.stamp", kind: .text, read: { [view] in
                        view.lastSnapshot.map { DetectionViewCopy.snapshotStamp(at: $0.at, boxes: $0.boxes) } ?? ""
                    })
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                legendOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: UISymbol.disclosure)
                        .uiFont(.caption2, weight: .semibold)
                        .rotationEffect(.degrees(legendOpen ? 90 : 0))
                    Text(DetectionViewCopy.legendDisclosure).uiFont(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .uiControl("\(Self.idPrefix).legend", kind: .button, read: { DetectionViewCopy.legendDisclosure },
                activate: { legendOpen.toggle() })
            if legendOpen {
                ForEach(DetectionViewStyle.allCases, id: \.self) { style in
                    HStack(spacing: 8) {
                        UIDetectionViewSwatch(style: style)
                        Text(DetectionViewCopy.legendText(style, mode: view.mode == .off ? .outlineOverCovers : view.mode))
                            .uiFont(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    UIDetectionViewSwatch(style: nil)
                    Text(DetectionViewCopy.legendWindow).uiFont(.caption2).fixedSize(horizontal: false, vertical: true)
                }
                Text(DetectionViewCopy.legendLabels)
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A 28 pt line sample in the overlay's own colour and dash (nil = window).
struct UIDetectionViewSwatch: View {
    let style: DetectionViewStyle?

    var body: some View {
        let ink = style.map(DetectionViewInk.of) ?? DetectionViewInk.window(DetectionViewInk.WindowState.curtained)
        Path { p in
            p.move(to: CGPoint(x: 0, y: 5))
            p.addLine(to: CGPoint(x: 28, y: 5))
        }
        .stroke(Color(cgColor: ink.color),
            style: StrokeStyle(lineWidth: min(ink.width, 3), lineCap: ink.dash.isEmpty ? .butt : .round,
                dash: ink.dash))
        .frame(width: 28, height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Popover

/// The popover row while the view is on (admin sessions only — the popover's
/// parent-controls branch). Ids: `ui.status.detectionview.*`.
struct UIDetectionViewPopoverRow: View {
    @ObservedObject var actions: UIActions
    @ObservedObject var view: DetectionViewController

    static let idPrefix = "ui.status.detectionview"

    var body: some View {
        if view.isOn {
            VStack(alignment: .leading, spacing: 4) {
                UIInlineMessage(
                    text: DetectionViewCopy.rowText(mode: view.mode, remaining: view.remaining),
                    symbol: view.mode == .detectionsOnly ? UISymbol.turnOff : "viewfinder",
                    tint: view.mode == .detectionsOnly ? .systemRed : .systemBlue)
                    .uiControl(Self.idPrefix, kind: .text, read: { [view] in
                        DetectionViewCopy.rowText(mode: view.mode, remaining: view.remaining)
                    })
                HStack(spacing: 8) {
                    UIFooterButton(label: DetectionViewCopy.rowSnapshot) { actions.snapshotDetectionView() }
                        .uiControl("\(Self.idPrefix).snapshot", kind: .button,
                            read: { DetectionViewCopy.rowSnapshot }, activate: { actions.snapshotDetectionView() })
                    UIFooterButton(label: DetectionViewCopy.rowTurnOff) { actions.turnOffDetectionView() }
                        .uiControl("\(Self.idPrefix).turnoff", kind: .button,
                            read: { DetectionViewCopy.rowTurnOff }, activate: { actions.turnOffDetectionView() })
                }
                .padding(.horizontal, -4)
            }
        }
    }
}

/// The popover header's words. D4: in Detections only the header says
/// protection is off, whatever the capture health says — covers are not
/// being drawn. A pause still wins (it turns the view off anyway).
struct UIDetectionViewHeader {
    static func header(state: UIState, view: DetectionViewController) -> String {
        guard state.pauseUntil == nil, view.mode == .detectionsOnly else { return state.headerText }
        return DetectionViewCopy.protectionOffHeader
    }

    static func detail(state: UIState, view: DetectionViewController) -> String {
        guard state.pauseUntil == nil, view.mode == .detectionsOnly, let until = view.offAt else {
            return state.detailText
        }
        return DetectionViewCopy.protectionOffDetailPrefix + UIState.clockTime.string(from: until)
    }

    static func overridesGlyph(state: UIState, view: DetectionViewController) -> Bool {
        state.pauseUntil == nil && view.mode == .detectionsOnly
    }
}
