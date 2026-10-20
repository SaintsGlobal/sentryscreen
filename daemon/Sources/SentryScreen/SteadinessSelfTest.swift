import CoreGraphics
import Foundation

// `--ui-selftest` cases for the detector steadiness
// (SENTRY_UI_SELFTEST_CASE=steadiness runs this group alone; it is also in
// the "tuning" group). Pure: no window, no detector, no network.
//  - score hysteresis (`TuningPolicy.keepGap`): keep and drop at each
//    boundary for region/media; curtain mode gets no hysteresis input;
//  - the settle trigger (`SettleWatch`) and its merge (`Pipeline.mergeRecheck`);
//  - weak boxes: trace-only, never in the policy's input.
extension UISelfTest {
    static func caseSteadiness() {
        steadinessHysteresis()
        steadinessSettleWatch()
        steadinessMerge()
        steadinessWeakTrace()
    }

    private static func steadinessHysteresis() {
        // Shipped off (owner 2026-09-25); the cases below test the rule at
        // its receipted 0.15.
        let shipped = TuningPolicy.defaults
        check("steadiness: shipped defaults are off — keepGap 0 and settleRecheck false",
            shipped.keepGap == 0 && !shipped.settleRecheck)
        var d = shipped
        d.keepGap = 0.15
        let screen = CGSize(width: 1920, height: 1080)
        let box = CGRect(x: 0.40, y: 0.40, width: 0.10, height: 0.10)
        func fbe(_ c: Float, _ b: CGRect = box) -> Detection {
            Detection(label: "FEMALE_BREAST_EXPOSED", confidence: c, box: b)
        }
        typealias Covered = TuningPolicy.CoveredInput
        func blocks(_ t: TuningPolicy, _ c: Float, tracked: Covered, mode: PolicyMode = .standard) -> (Bool, Int) {
            let f = t.filter([fbe(c)], mode: mode, blockFaces: false, screen: screen, tracked: tracked)
            return (f.blocked.count == 1, f.kept)
        }
        let start = d.rule(for: "FEMALE_BREAST_EXPOSED")!.threshold
        let keep = d.keepFloor(start)
        check("steadiness: keepGap 0.15 → FEMALE_BREAST_EXPOSED keep floor \(keep) under start \(start)",
            d.keepGap == 0.15 && abs(keep - (start - 0.15)) < 1e-6)
        // Last frame blocked the same label here.
        let covered = Covered(boxes: [fbe(0.6, box.offsetBy(dx: 0.01, dy: 0))])
        check("steadiness: an UNTRACKED box under its start floor is dropped (hysteresis needs a cover)",
            blocks(d, start - 0.01, tracked: Covered()) == (false, 0))
        check("steadiness: a tracked box AT the keep floor stays covered and is counted kept",
            blocks(d, keep, tracked: covered) == (true, 1))
        check("steadiness: a tracked box just under the keep floor is dropped",
            blocks(d, keep - 0.001, tracked: covered) == (false, 0))
        check("steadiness: a tracked box at its start floor passes and is not counted kept",
            blocks(d, start, tracked: covered) == (true, 0))
        var off = d
        off.keepGap = 0
        check("steadiness: keepGap 0 is off — a tracked box under the start floor is dropped",
            blocks(off, start - 0.01, tracked: covered) == (false, 0))
        let elsewhere = Covered(boxes: [fbe(0.6, CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1))])
        check("steadiness: a cover somewhere else does not keep the box",
            blocks(d, start - 0.01, tracked: elsewhere) == (false, 0))
        // The gate's RED on the first cut: a different class covered here
        // (a face region under --block-faces) must not keep this box.
        let face = Covered(boxes: [Detection(label: "FACE_FEMALE", confidence: 0.9, box: box)])
        check("steadiness: a DIFFERENT label covered at the same place does not keep the box",
            blocks(d, start - 0.05, tracked: face) == (false, 0))
        // Region and media only (owner): curtain mode gets no
        // hysteresis input, so a curtain sees exactly the pre-hysteresis boxes.
        let prev = [fbe(0.9, box)]
        check("steadiness: curtain mode — no hysteresis input, the box under its start floor is dropped",
            Covered.forCover(curtain: true, lastBlocked: prev).boxes.isEmpty
                && blocks(d, start - 0.05, tracked: .forCover(curtain: true, lastBlocked: prev)) == (false, 0))
        check("steadiness: region/media mode — last frame's blocked boxes are the input, the box is kept",
            blocks(d, start - 0.05, tracked: .forCover(curtain: false, lastBlocked: prev)) == (true, 1))
        // A class the policy does not block in this mode is never kept.
        let fbc = Detection(label: "FEMALE_BREAST_COVERED", confidence: 0.45, box: box)
        check("steadiness: a covered class under Standard is never kept, tracked or not",
            d.filter([fbc], mode: .standard, blockFaces: false, screen: screen, tracked: covered).blocked.isEmpty)
        // The size staircase keeps against its own floor. 0.95: a step above
        // the shipped 0.90 FBE base (2026-10-20), so the step's keep floor
        // (0.80) and the base's (0.75) are different numbers.
        var stepped = d
        stepped.standard["FEMALE_BREAST_EXPOSED"]?.thresholdSteps = [.init(minPt: 64, threshold: 0.95)]
        let stepKeep = stepped.keepFloor(0.95)
        check("steadiness: a tracked box under a size step's floor is kept down to that step's keep floor",
            blocks(stepped, stepKeep, tracked: covered) == (true, 1)
                && blocks(stepped, stepKeep - 0.001, tracked: covered) == (false, 0))
        // Parse: refused by name outside the range. Through JSONSerialization,
        // as tuning.json is read, so a 1 arrives as the NSNumber it really is.
        func json(_ s: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
        }
        let bad = TuningPolicy.parse(json(#"{"keepGap": 0.3}"#), base: d)
        if case let .failure(e) = bad {
            check("steadiness: keepGap 0.3 is refused by name", e.text.contains("keepGap"), e.text)
        } else {
            check("steadiness: keepGap 0.3 is refused", false)
        }
        let flag = TuningPolicy.parse(json(#"{"settleRecheck": 1}"#), base: d)
        if case let .failure(e) = flag {
            check("steadiness: settleRecheck must be a bool, refused by name", e.text.contains("settleRecheck"), e.text)
        } else {
            check("steadiness: settleRecheck 1 is refused", false)
        }
        if case let .success(p) = TuningPolicy.parse(json(#"{"keepGap": 0.1, "settleRecheck": true}"#), base: shipped) {
            check("steadiness: keepGap and settleRecheck parse (how a tuning turns them on)", p.keepGap == 0.1 && p.settleRecheck)
        } else {
            check("steadiness: keepGap and settleRecheck parse", false)
        }
    }

    private static func steadinessSettleWatch() {
        let th = 0.02, n = 3
        var w = SettleWatch()
        for _ in 0..<5 { w.observe(changed: 0, threshold: th, stillFrames: n) }
        check("steadiness: settle — a screen that never moved never settles", !w.take())
        w.observe(changed: 0.5, threshold: th, stillFrames: n)
        w.observe(changed: 0, threshold: th, stillFrames: n)
        w.observe(changed: 0, threshold: th, stillFrames: n)
        check("steadiness: settle — two still frames after motion are not yet a settle", !w.pending)
        w.observe(changed: 0, threshold: th, stillFrames: n)
        check("steadiness: settle — the third still frame after motion is", w.pending)
        check("steadiness: settle — take() answers once", w.take() && !w.take())
        for _ in 0..<10 { w.observe(changed: 0, threshold: th, stillFrames: n) }
        check("steadiness: settle — staying still does not re-trigger", !w.take())
        var alt = SettleWatch()
        var fired = 0
        for i in 0..<60 {
            alt.observe(changed: i % 2 == 0 ? 0.3 : 0, threshold: th, stillFrames: n)
            if alt.take() { fired += 1 }
        }
        check("steadiness: settle — video-like changed/still alternation never settles", fired == 0, "\(fired)")
        var cancel = SettleWatch()
        cancel.observe(changed: 0.5, threshold: th, stillFrames: n)
        for _ in 0..<3 { cancel.observe(changed: 0, threshold: th, stillFrames: n) }
        cancel.observe(changed: 0.5, threshold: th, stillFrames: n)
        check("steadiness: settle — motion before the re-check runs cancels it", !cancel.take())
    }

    private static func steadinessMerge() {
        let a = CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
        let b = CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1)
        let shiftedA = a.offsetBy(dx: 0.003, dy: 0)
        let first = Detector.Pass(
            kept: [Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.45, box: a),
                   Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.70, box: b)],
            weak: [Detection(label: "ANUS_EXPOSED", confidence: 0.12, box: CGRect(x: 0.8, y: 0.1, width: 0.05, height: 0.05))])
        let shifted = [
            Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.58, box: shiftedA),  // raises a
            Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.60, box: b),               // lower: ignored
            Detection(label: "ANUS_EXPOSED", confidence: 0.30, box: CGRect(x: 0.8, y: 0.1, width: 0.05, height: 0.05)),
        ]
        let m = Pipeline.mergeRecheck(first, shifted)
        let k = m.pass.kept
        check("steadiness: merge — a higher shifted score raises the box, keeping its own geometry",
            k[0].confidence == 0.58 && k[0].box == a && k[0].recheckFrom == 0.45)
        check("steadiness: merge — a lower shifted score never lowers a box",
            k[1].confidence == 0.70 && k[1].recheckFrom == nil)
        check("steadiness: merge — a weak box the shift lifted over --conf joins the pass and leaves the weak list",
            k.count == 3 && k[2].label == "ANUS_EXPOSED" && k[2].recheckFrom == 0.12 && m.pass.weak.isEmpty)
        check("steadiness: merge — raised counts the raise and the addition", m.raised == 2, "\(m.raised)")
        let alone = Pipeline.mergeRecheck(Detector.Pass(kept: []), [Detection(label: "X", confidence: 0.4, box: a)])
        check("steadiness: merge — a box only the shift saw is added with recheckFrom 0",
            alone.pass.kept.first?.recheckFrom == 0 && alone.raised == 1)
        check("steadiness: shift receipt — 4 px at the 1280 capture width", Pipeline.settleShiftPx == 4)
    }

    private static func steadinessWeakTrace() {
        let screen = CGSize(width: 1920, height: 1080)
        // 0.95: above the shipped 0.90 FBE floor, so the policy box blocks.
        let kept = [Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.95, box: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))]
        let weak = [Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.2, box: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)),
                    Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.07, box: CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1))]
        var input = DetectionTraceBuilder.Inputs(
            seq: 1, capturedAt: 0, screenPt: screen, display: CGRect(origin: .zero, size: screen),
            policy: .standard, coverMode: "region", tuning: .defaults, tuningSource: "defaults",
            blockFaces: false, roi: nil,
            stats: .init(evaluatedFps: 0, detectMs: 0, stepMs: 0, idleSkipped: 0, traceMs: 0))
        input.raw = kept
        input.weak = weak
        input.conf = 0.25
        let out = DetectionTraceBuilder.build(input, builtAt: 0, appName: { _ in nil })
        let w = out.trace.boxes.filter(\.isWeak)
        check("steadiness: weak — the trace carries weak boxes after the policy's boxes",
            out.trace.boxes.count == 3 && w.count == 2 && !out.trace.boxes[0].isWeak)
        check("steadiness: weak — the mirror never counts a weak box as blocked", out.mirrorBlocked == 1)
        check("steadiness: weak — a weak box never has a region or curtain outcome",
            w.allSatisfy { $0.region == nil && $0.curtain == nil })
        let e = DetectionViewCopy.explain(w[0], trace: out.trace, mode: .outlineOverCovers)
        check("steadiness: weak — explained as under the detector floor, never covered",
            e.style == .weak && e.lines.last?.hasPrefix("weak: 0.20 < detector floor 0.25") == true, "\(e.lines)")
        // Everything the policy sees is `raw`: the same raw with and without
        // weak boxes filters identically.
        let f = TuningPolicy.defaults.filter(kept, mode: .standard, blockFaces: false, screen: screen)
        check("steadiness: weak — filter's blocked list is the raw list's, whatever weak holds",
            f.blocked.count == out.mirrorBlocked)
        // Drawing cap: weak boxes are cut first.
        input.raw = Array(repeating: kept[0], count: DetectionTraceBuilder.maxBoxes)
        let capped = DetectionTraceBuilder.build(input, builtAt: 0, appName: { _ in nil })
        check("steadiness: weak — the drawing cap cuts weak boxes before policy boxes, and counts them",
            capped.trace.boxes.allSatisfy { !$0.isWeak } && capped.trace.boxesOverflow == weak.count)
        // Kept outcome text (hysteresis).
        let at = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        var k = input
        // Under the shipped 0.90 FBE start floor, over its 0.75 keep floor.
        k.raw = [Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.78, box: at)]
        k.weak = []
        k.tuning.keepGap = 0.15  // shipped off; the receipted value to enable
        k.tracked = .init(boxes: [Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.92, box: at)])
        let kt = DetectionTraceBuilder.build(k, builtAt: 0, appName: { _ in nil })
        let ke = DetectionViewCopy.explain(kt.trace.boxes[0], trace: kt.trace, mode: .outlineOverCovers)
        check("steadiness: kept — explained with its keep floor and start floor",
            ke.lines.contains("kept: 0.78 ≥ keep 0.75 (tracked; starts at 0.90)"), "\(ke.lines)")
        check("steadiness: kept — the mirror counts the kept box as blocked", kt.mirrorBlocked == 1)
    }
}
