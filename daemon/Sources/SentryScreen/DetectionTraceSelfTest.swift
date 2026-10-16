import CoreGraphics
import Foundation

// `--ui-selftest` group "detection-trace" (SENTRY_UI_SELFTEST_CASE=
// detection-trace runs it alone): the Detection view's trace types, bus and
// curtain recorder (DetectionTrace.swift), and — from workstream A — the
// trace builder, the synthetic fixture, and the proof that the curtain and
// tracker trace hooks change nothing. Headless: no window, no capture, no
// install.
extension UISelfTest {
    static func caseDetectionTrace(_ dir: String) {
        func trace(_ seq: UInt64) -> DetectionTrace {
            DetectionTrace(
                seq: seq, capturedAt: 0, builtAt: 0, screenPt: CGSize(width: 1920, height: 1080),
                policy: .standard, coverMode: "curtain", tuning: .defaults, tuningSource: "defaults",
                detectorFailed: false, boxes: [], boxesOverflow: 0, walkUnattributed: 0, walk: .notCurtainMode,
                windows: [],
                stats: .init(evaluatedFps: 0, detectMs: 0, stepMs: 0, idleSkipped: 0, traceMs: 0))
        }
        let bus = DetectionTraceBus()
        var delivered: [UInt64] = []
        bus.onTrace = { delivered.append($0.seq) }
        bus.publish(trace(1))
        bus.publish(trace(2))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        check("detection-trace: bus — two publishes before main runs deliver only the newest, once",
            delivered == [2] && bus.newest()?.seq == 2, "delivered=\(delivered)")
        bus.publish(trace(3))
        bus.clear()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        check("detection-trace: bus — clear before delivery delivers nothing",
            delivered == [2] && bus.newest() == nil, "delivered=\(delivered)")

        let recorder = CurtainTraceRecorder()
        recorder.begin(.ran)
        recorder.note([0, 2], .credited(window: 7))
        recorder.begin(.skipped(every: 2))
        check("detection-trace: recorder — begin resets the outcomes and sets the walk",
            recorder.walk == .skipped(every: 2) && recorder.outcomes.isEmpty,
            "walk=\(recorder.walk) outcomes=\(recorder.outcomes.count)")
        recorder.walk(queries: [[0, 2], [1]])
        recorder.note(query: 1, .orphan)
        recorder.note(query: 5, .orphan)
        check("detection-trace: recorder — note(query:) maps to the query's blocked indices, "
            + "an unknown query to none",
            recorder.outcomes.map(\.blockedIndices) == [[1], []], "outcomes=\(recorder.outcomes)")
        recorder.note(query: 0, { Thread.sleep(forTimeInterval: 0.002); return .orphan }())
        let timed = recorder.costMs
        recorder.begin(.ran)
        check("detection-trace: recorder — note arguments are timed into costMs; begin resets it",
            timed >= 1.5 && recorder.costMs == 0, String(format: "costMs %.2f", timed))
        var unattributed = traceInput([
            Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.9, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.9, box: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)),
        ])
        unattributed.curtainWalk = .ran
        unattributed.curtainOutcomes = [(blockedIndices: [0], outcome: .credited(window: 9))]
        let ua = DetectionTraceBuilder.build(unattributed, builtAt: 0, appName: { _ in nil }).trace
        unattributed.curtainWalk = .skipped(every: 3)
        let skippedUA = DetectionTraceBuilder.build(unattributed, builtAt: 0, appName: { _ in nil }).trace
        check("detection-trace: a ran walk that left a blocked box without an outcome is counted "
            + "(walkUnattributed), a skipped walk is not",
            ua.walkUnattributed == 1 && skippedUA.walkUnattributed == 0,
            "ran=\(ua.walkUnattributed) skipped=\(skippedUA.walkUnattributed)")

        traceVerdictMirror()
        traceBuilderUnits()
        traceFixtureOutcomes()
        traceScriptedPipeline()
        traceBuildTiming()
        let marker = ["Detection", "Trace", "Builder"].joined()
        let bytes = Bundle.main.executablePath.flatMap { FileManager.default.contents(atPath: $0) }
        check("detection-trace: the binary carries the trace builder (marker present)",
            bytes?.range(of: Data(marker.utf8)) != nil)
    }

    // MARK: verdicts == filter

    /// `TuningPolicy.verdicts` is a mirror of `filter` + the ROI test:
    /// elementwise over seeded random sets under every lever that changes
    /// the decision.
    private static func traceVerdictMirror() {
        var seed: UInt64 = 0xD37EC7
        func unit() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Double((seed >> 33) & 0xffff) / Double(0xffff)
        }
        let labels = TuningPolicy.exposedLabels + TuningPolicy.coveredLabels
            + [TuningPolicy.injectLabel, "FACE_FEMALE", "FACE_MALE", "ARMPITS_EXPOSED"]
        var stepped = TuningPolicy.defaults
        stepped.standard["FEMALE_BREAST_EXPOSED"]?.thresholdSteps = [.init(minPt: 48, threshold: 0.7), .init(minPt: 96, threshold: 0.9)]
        stepped.strict["FEMALE_BREAST_COVERED"]?.thresholdSteps = [.init(minPt: 64, threshold: 0.8)]
        var floored = TuningPolicy.defaults
        for l in TuningPolicy.exposedLabels { floored.standard[l]?.minBoxPt = 32 }
        floored.strict["BUTTOCKS_COVERED"]?.minBoxFraction = 0.004
        var noDemote = TuningPolicy.defaults
        noDemote.coveredBeatsExposed = false
        var both = stepped
        both.standard["ANUS_EXPOSED"]?.minBoxPt = 24
        both.coveredOverlap = 0.5
        var noKeep = TuningPolicy.defaults
        noKeep.keepGap = 0
        var wideKeep = stepped
        wideKeep.keepGap = 0.25
        let tunings = [("defaults", TuningPolicy.defaults), ("steps", stepped), ("minBox", floored),
                       ("coveredBeatsExposed off", noDemote), ("steps+minBox+overlap 0.5", both),
                       ("keepGap 0", noKeep), ("steps+keepGap 0.25", wideKeep)]
        var keptSeen = 0
        let screens = [CGSize(width: 1920, height: 1080), .zero]
        let rois: [CGRect?] = [nil, CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)]
        var sets = 0
        var failure: String?
        outer: for (name, tuning) in tunings {
            for mode in [PolicyMode.standard, .strict] {
                for blockFaces in [false, true] {
                    for screen in screens {
                        for roi in rois {
                            for _ in 0..<40 {
                                sets += 1
                                var raw: [Detection] = []
                                for _ in 0..<Int(unit() * 14) {
                                    let w = 0.005 + unit() * 0.3, h = 0.005 + unit() * 0.3
                                    raw.append(Detection(
                                        label: labels[Int(unit() * Double(labels.count)) % labels.count],
                                        confidence: Float(unit()),
                                        box: CGRect(x: unit() * (1 - w), y: unit() * (1 - h), width: w, height: h)))
                                    // Nest an exposed box inside a covered one of the same part
                                    // often enough for the demotion arm to run.
                                    if let last = raw.last, let exposed = TuningPolicy.coveredPairs
                                        .first(where: { $0.value == last.label })?.key, unit() < 0.5 {
                                        raw.append(Detection(
                                            label: exposed, confidence: Float(unit()),
                                            box: last.box.insetBy(dx: last.box.width * 0.2, dy: last.box.height * 0.2)))
                                    }
                                }
                                // Hysteresis input: some raw boxes nudged (so a keep can
                                // happen).
                                var tracked = TuningPolicy.CoveredInput()
                                tracked.boxes = raw.filter { _ in unit() < 0.4 }.map {
                                    // Sometimes the same label, sometimes another.
                                    Detection(label: unit() < 0.7 ? $0.label : labels[Int(unit() * Double(labels.count)) % labels.count],
                                        confidence: 0.9, box: $0.box.offsetBy(dx: 0.01, dy: -0.01))
                                }
                                let filtered = tuning.filter(
                                    raw, mode: mode, blockFaces: blockFaces, screen: screen, tracked: tracked)
                                var blocked = filtered.blocked
                                if let roi { blocked = blocked.filter { roi.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) } }
                                let verdicts = tuning.verdicts(
                                    raw, mode: mode, blockFaces: blockFaces, screen: screen, roi: roi, tracked: tracked)
                                let keptVerdicts = verdicts.filter { if case .kept = $0.policy { return true }; return false }.count
                                keptSeen += keptVerdicts
                                let passed = zip(raw, verdicts).filter { $0.1.passes }
                                let same = passed.count == blocked.count
                                    && zip(passed, blocked).allSatisfy { p, b in
                                        p.1.label == b.label && p.0.confidence == b.confidence && p.0.box == b.box
                                    }
                                let counts = (
                                    verdicts.filter { $0.demotion != nil }.count == filtered.demoted,
                                    verdicts.filter { if case .minBox = $0.policy { return true }; return false }.count
                                        == filtered.minBoxDropped,
                                    verdicts.filter { if case .thresholdStep = $0.policy { return true }; return false }.count
                                        == filtered.stepDropped,
                                    // The ROI can only remove a kept box.
                                    roi == nil ? keptVerdicts == filtered.kept : keptVerdicts <= filtered.kept)
                                if !same || !counts.0 || !counts.1 || !counts.2 || !counts.3 {
                                    failure = "tuning=\(name) mode=\(mode) faces=\(blockFaces) screen=\(screen) "
                                        + "roi=\(String(describing: roi)) passed=\(passed.count) blocked=\(blocked.count) "
                                        + "counts=\(counts) raw=\(raw.map { "\($0.label)@\($0.confidence)" })"
                                    break outer
                                }
                            }
                        }
                    }
                }
            }
        }
        check("detection-trace: verdicts pass exactly filter's blocked list (+ROI), elementwise, and "
            + "count the same demotions / size drops / step drops / hysteresis keeps over \(sets) seeded sets",
            failure == nil, failure ?? "")
        check("detection-trace: the seeded sets exercise hysteresis keeps (\(keptSeen) kept verdicts)", keptSeen > 50)
    }

    // MARK: builder units

    private static func traceStats() -> DetectionTrace.Stats {
        .init(evaluatedFps: 30, detectMs: 10, stepMs: 12, idleSkipped: 0, traceMs: 0)
    }

    private static func traceInput(
        _ raw: [Detection], tuning: TuningPolicy = .defaults, policy: PolicyMode = .standard
    ) -> DetectionTraceBuilder.Inputs {
        DetectionTraceBuilder.Inputs(
            seq: 1, capturedAt: 0, screenPt: CGSize(width: 1920, height: 1080),
            display: CGRect(x: 0, y: 0, width: 1920, height: 1080), policy: policy,
            coverMode: "curtain", tuning: tuning, tuningSource: "defaults", blockFaces: false,
            roi: nil, raw: raw, syntheticFrom: 0, stats: traceStats())
    }

    private static func traceBuilderUnits() {
        let screen = CGSize(width: 1920, height: 1080)
        // Overflow: the stress pattern is exactly maxBoxes + 5 boxes.
        let stress = DetectionFixture.detections(frame: 0, screen: screen, pattern: .stress)
        let out = DetectionTraceBuilder.build(traceInput(stress), builtAt: 0, appName: { _ in nil })
        check("detection-trace: stress pattern — \(DetectionTraceBuilder.maxBoxes) boxes kept, "
            + "5 counted in boxesOverflow, none dropped silently",
            stress.count == DetectionTraceBuilder.maxBoxes + 5
                && out.trace.boxes.count == DetectionTraceBuilder.maxBoxes && out.trace.boxesOverflow == 5,
            "raw=\(stress.count) kept=\(out.trace.boxes.count) overflow=\(out.trace.boxesOverflow)")

        // Region outcomes by position; one box of each.
        let a = DetectionFixture.detection("FEMALE_BREAST_EXPOSED", 0.9, centre: CGPoint(x: 0.2, y: 0.2), sidePt: 100, screen: screen)
        let b = DetectionFixture.detection("FEMALE_BREAST_EXPOSED", 0.9, centre: CGPoint(x: 0.5, y: 0.5), sidePt: 100, screen: screen)
        let c = DetectionFixture.detection("FEMALE_BREAST_EXPOSED", 0.9, centre: CGPoint(x: 0.8, y: 0.8), sidePt: 100, screen: screen)
        let d = DetectionFixture.detection("FEMALE_BREAST_EXPOSED", 0.9, centre: CGPoint(x: 0.8, y: 0.2), sidePt: 100, screen: screen)
        var input = traceInput([a, b, c, d])
        input.syntheticFrom = 3
        input.regionSourceIndices = [0, 1, 2]
        input.regions = [TrackedRegion(id: 41, rect: a.box, missed: 0)]
        input.painted = [a.box.insetBy(dx: -0.01, dy: -0.01)]
        input.pending = [(rect: b.box, label: b.label, seen: 1, needed: 2)]
        input.curtainWalk = .ran
        input.curtainOutcomes = [([0, 1], .credited(window: 9)), ([3], .orphan)]
        input.windows = [(id: 9, frame: CGRect(x: 960, y: 540, width: 960, height: 1080), state: .lingering)]
        let units = DetectionTraceBuilder.build(input, builtAt: 0, appName: { $0 == 9 ? "Safari" : nil })
        let boxes = units.trace.boxes
        check("detection-trace: region outcome — covered / entry 1/2 / not covered / under curtain",
            boxes.map(\.region) == [.covered(regionID: 41), .entryPending(seen: 1, needed: 2), .notCovered, .underCurtain],
            "\(boxes.map(\.region))")
        check("detection-trace: curtain outcome follows the note's blocked indices",
            boxes.map(\.curtain) == [.credited(window: 9), .credited(window: 9), nil, .orphan],
            "\(boxes.map(\.curtain))")
        check("detection-trace: synthetic flag starts at syntheticFrom; rects flip to top-left",
            boxes.map(\.synthetic) == [false, false, false, true]
                && abs(boxes[0].rect.midY - 0.2) < 1e-9 && abs(boxes[2].rect.midY - 0.8) < 1e-9,
            "\(boxes.map(\.rect))")
        check("detection-trace: window frame normalized top-left and clamped, app from the memo",
            units.trace.windows == [.init(id: 9, app: "Safari", frame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), state: .lingering)],
            "\(units.trace.windows)")
        input.curtainWalk = .skipped(every: 3)
        check("detection-trace: a skipped walk marks every blocked box walkSkipped",
            DetectionTraceBuilder.build(input, builtAt: 0, appName: { _ in nil }).trace.boxes
                .allSatisfy { $0.curtain == .walkSkipped })
        input.curtainWalk = nil
        let region = DetectionTraceBuilder.build(input, builtAt: 0, appName: { _ in nil }).trace
        check("detection-trace: outside curtain mode no box carries a curtain outcome",
            region.walk == .notCurtainMode && region.boxes.allSatisfy { $0.curtain == nil })

        // App-name memo: one lookup per id, bounded by WindowOwner.cacheLimit, loud when full.
        var lookups = 0
        var fullLines: [String] = []
        let names = DetectionTraceAppNames(lookup: { lookups += 1; return "App\($0)" })
        names.onFull = { fullLines.append($0) }
        _ = names.name(1)
        _ = names.name(1)
        for id in 2...CGWindowID(WindowOwner.cacheLimit + 1) { _ = names.name(id) }
        check("detection-trace: app-name memo — one lookup per id, cleared loudly at WindowOwner.cacheLimit",
            lookups == WindowOwner.cacheLimit + 1 && fullLines.count == 1
                && fullLines[0].contains("WindowOwner.cacheLimit=\(WindowOwner.cacheLimit)") && names.count == 1,
            "lookups=\(lookups) full=\(fullLines) count=\(names.count)")
    }

    // MARK: fixture policy outcomes

    /// The fixture reaches every `PolicyOutcome`: five at the defaults, the
    /// size floor and the staircase once they are set, the ROI with one set.
    private static func traceFixtureOutcomes() {
        let screen = CGSize(width: 1920, height: 1080)
        let raw = DetectionFixture.detections(frame: 0, screen: screen, pattern: .standard)
        func kinds(_ t: TuningPolicy, _ mode: PolicyMode = .standard, roi: CGRect? = nil) -> [String] {
            t.verdicts(raw, mode: mode, blockFaces: false, screen: screen, roi: roi).map { v in
                switch v.policy {
                case .passes: return "passes"
                case .belowThreshold: return "below"
                case .classOffInPolicy: return "classOff"
                case .minBox: return "minBox"
                case .thresholdStep: return "step"
                case .outsideROI: return "roi"
                case .notPolicyClass: return "notPolicy"
                case .kept: return "kept"
                case .weak: return "weak"
                }
            }
        }
        let defaults = kinds(.defaults)
        check("detection-trace: fixture at the defaults — passes, below 0.50, class off (covered + "
            + "demoted), entry box passes, 16 pt passes, face not a policy class, orphan box passes",
            defaults == ["passes", "below", "classOff", "classOff", "passes", "passes", "notPolicy", "passes"],
            "\(defaults)")
        let demotion = TuningPolicy.defaults.verdicts(raw, mode: .standard, blockFaces: false, screen: screen, roi: nil)[3].demotion
        check("detection-trace: fixture's inner FEMALE_BREAST_EXPOSED is demoted at overlap 1.00 ≥ 0.90",
            demotion?.to == "FEMALE_BREAST_COVERED" && abs((demotion?.overlap ?? 0) - 1) < 1e-9
                && demotion?.minOverlap == 0.9, "\(String(describing: demotion))")
        check("detection-trace: fixture under strict — the demoted pair blocks at the covered floor",
            kinds(.defaults, .strict)[2...3] == ["passes", "passes"], "\(kinds(.defaults, .strict))")
        var tuned = TuningPolicy.defaults
        tuned.standard["ANUS_EXPOSED"]?.minBoxPt = 24
        tuned.standard["FEMALE_BREAST_EXPOSED"]?.thresholdSteps = [.init(minPt: 128, threshold: 0.9)]
        let withTuning = kinds(tuned)
        check("detection-trace: fixture with minBoxPt 24 and a {128 pt, 0.90} step — 16 pt box hits "
            + "the size floor, the 140 pt 0.83 box the step, the 100 pt orphan box stays under the step",
            withTuning[5] == "minBox" && withTuning[0] == "step" && withTuning[7] == "passes", "\(withTuning)")
        let roi = kinds(.defaults, roi: CGRect(x: 0, y: 0, width: 0.9, height: 1))
        check("detection-trace: fixture with an ROI that excludes the top-right corner — orphan box outside ROI",
            roi[7] == "roi" && roi[0] == "passes", "\(roi)")
        check("detection-trace: fixture's entry box is present on even evaluated frames only",
            DetectionFixture.detections(frame: 1, screen: screen, pattern: .standard).count == raw.count - 1
                && !DetectionFixture.detections(frame: 1, screen: screen, pattern: .standard)
                    .contains { $0.label == "BUTTOCKS_EXPOSED" })
        let zero = DetectionFixture.detections(frame: 0, screen: .zero, pattern: .standard)
        check("detection-trace: fixture on a 0×0 screen sizes against the fallback screen",
            zero.map(\.box) == DetectionFixture.detections(frame: 0, screen: DetectionFixture.fallbackScreen, pattern: .standard).map(\.box))
    }

    // MARK: scripted pipeline — trace hooks change nothing

    /// Two identical mini-pipelines (policy filter → region tracker in
    /// curtain mode → curtain) fed the fixture frame by frame against one
    /// fake window list. Twin A has the curtain recorder attached and reads
    /// `traceWindows` and `pendingEntriesForTrace` between frames; twin B
    /// has none of it. Every frame: identical region output, curtain
    /// output, curtain events and watch set. Twin A's traces must reach
    /// credited / orphan / straddle, covered / entry pending / under curtain,
    /// a pending window and a curtained one.
    private static func traceScriptedPipeline() {
        struct Win { let id: CGWindowID; let rect: CGRect }
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = DisplayGeometry(size: screen.size, origin: .zero)
        let main = Win(id: 7101, rect: CGRect(x: 200, y: 150, width: 1000, height: 750))
        let side = Win(id: 7102, rect: CGRect(x: 1000, y: 300, width: 500, height: 400))
        let wt = WindowTracker()
        wt.windowSource = {
            [side, main].map { w in  // front to back
                [
                    "kCGWindowNumber": w.id, "kCGWindowOwnerName": "Google Chrome",
                    "kCGWindowLayer": 0, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": pid_t(1),
                    "kCGWindowBounds": ["X": w.rect.minX, "Y": w.rect.minY, "Width": w.rect.width, "Height": w.rect.height],
                ] as [String: Any]
            }
        }
        wt.screenFrame = screen
        wt.onReceipt = { _ in }
        wt.start()
        defer { wt.stop() }

        final class Twin {
            let tracker = Tracker(clearAfter: Tracker.defaultClearAfter(fps: 30))
            let curtain = Curtain()
            var events: [String] = []
            var curtainPainted: [CGRect] = []
            init(traced: Bool) {
                tracker.curtainEntry = true
                curtain.onChange = { [unowned self] in self.events.append("\($0) window \($1)") }
                if traced { curtain.traceRecorder = CurtainTraceRecorder() }
            }
        }
        let a = Twin(traced: true), b = Twin(traced: false)
        // A box half on the front window 7102, inside the main window's content.
        let straddle = Detection(
            label: "FEMALE_GENITALIA_EXPOSED", confidence: 0.9,
            box: geometry.normalized(CGRect(x: 940, y: 450, width: 120, height: 120)))
        var t = CFAbsoluteTimeGetCurrent()
        var mismatch: String?
        var policy = Set<String>(), region = Set<String>(), curtainSeen = Set<String>(), windows = Set<String>()
        var rewoundOK = true
        var traceWorkMs: [Double] = []
        Thread.sleep(forTimeInterval: 0.05)
        for frame in 0..<40 {
            t += 1.0 / 30
            let raw = DetectionFixture.detections(frame: frame, screen: screen.size, pattern: .standard)
                + (frame >= 6 ? [straddle] : [])
            var outs: [(regions: [TrackedRegion], frames: [(id: CGWindowID, frame: CGRect)])] = []
            var trace: DetectionTrace?
            for twin in [a, b] {
                let blocked = TuningPolicy.defaults.filter(raw, mode: .standard, blockFaces: false, screen: screen.size).blocked
                let regionIdx = Pipeline.regionInputIndices(blocked, underCurtains: twin.curtainPainted)
                let regions = twin.tracker.update(detections: regionIdx.map { blocked[$0] })
                let pending = twin === a ? twin.tracker.pendingEntriesForTrace : []
                let frames = twin.curtain.update(
                    blockedScreenRects: blocked.map { geometry.screenRect($0.box) },
                    tracker: wt, display: screen, at: t)
                twin.curtainPainted = frames.map {
                    geometry.normalized(Curtain.contentRect(window: $0.frame, display: screen))
                }
                outs.append((regions, frames))
                guard twin === a, let recorder = twin.curtain.traceRecorder else { continue }
                var input = traceInput(raw)
                input.syntheticFrom = 0
                input.regionSourceIndices = regionIdx
                input.regions = regions
                input.painted = regions.map(\.rect)
                input.pending = pending
                input.curtainWalk = recorder.walk
                input.curtainOutcomes = recorder.outcomes
                // The whole trace work the pipeline times (Stats.traceMs):
                // the recorder's share of update, traceWindows, the build.
                let w0 = CFAbsoluteTimeGetCurrent()
                input.windows = twin.curtain.traceWindows(tracker: wt, display: screen, at: t)
                let out = DetectionTraceBuilder.build(input, builtAt: t, appName: { _ in nil })
                traceWorkMs.append((CFAbsoluteTimeGetCurrent() - w0) * 1000 + recorder.costMs)
                if out.mirrorBlocked != blocked.count { mismatch = "frame \(frame): mirror \(out.mirrorBlocked) vs \(blocked.count)" }
                trace = out.trace
            }
            let (ra, rb) = (outs[0], outs[1])
            if ra.regions.map(\.id) != rb.regions.map(\.id) || ra.regions.map(\.rect) != rb.regions.map(\.rect)
                || ra.frames.map(\.id) != rb.frames.map(\.id) || ra.frames.map(\.frame) != rb.frames.map(\.frame)
                || a.events != b.events || a.curtain.watchIDs != b.curtain.watchIDs {
                mismatch = mismatch ?? "frame \(frame): A regions=\(ra.regions.map(\.id)) frames=\(ra.frames.map(\.id)) "
                    + "events=\(a.events.suffix(3)) | B regions=\(rb.regions.map(\.id)) frames=\(rb.frames.map(\.id)) "
                    + "events=\(b.events.suffix(3))"
            }
            wt.setTracked(a.curtain.watchIDs)
            // Let the poll thread sample a newly tracked id before the next
            // frame, so both twins read the same rings.
            Thread.sleep(forTimeInterval: 0.012)
            guard let trace else { continue }
            for box in trace.boxes {
                policy.insert("\(box.policy)".components(separatedBy: "(")[0])
                if let r = box.region { region.insert("\(r)".components(separatedBy: "(")[0]) }
                if let c = box.curtain {
                    curtainSeen.insert("\(c)".components(separatedBy: "(")[0])
                    if case let .straddle(front, _, rewoundTo?) = c {
                        rewoundOK = rewoundOK && front == side.id
                            && a.events.contains { $0.contains("belonged to curtain \(rewoundTo)") }
                    }
                }
            }
            for w in trace.windows { windows.insert("\(w.state)".components(separatedBy: "(")[0]) }
        }
        traceWorkMs.sort()
        if !traceWorkMs.isEmpty {
            let p95 = traceWorkMs[Int(Double(traceWorkMs.count - 1) * 0.95)]
            print(String(format: "# detection-trace whole trace work per frame (recorder notes + traceWindows + "
                + "build), scripted 2-window curtain, %d frames: p50 %.4f p95 %.4f max %.4f ms",
                traceWorkMs.count, traceWorkMs[traceWorkMs.count / 2], p95, traceWorkMs.last ?? 0))
            check("detection-trace: whole trace work p95 is under DetectionTraceBuilder.traceBudgetMs",
                p95 < DetectionTraceBuilder.traceBudgetMs,
                String(format: "p95 %.3f ms, budget %.1f ms", p95, DetectionTraceBuilder.traceBudgetMs))
        }
        check("detection-trace: recorder + traceWindows + pendingEntriesForTrace attached vs detached — "
            + "identical regions, curtain frames, curtain events and watch set on every frame",
            mismatch == nil && !a.events.isEmpty, mismatch ?? "no events: \(a.events)")
        check("detection-trace: scripted fixture reaches passes / belowThreshold / classOffInPolicy / notPolicyClass",
            policy.isSuperset(of: ["passes", "belowThreshold", "classOffInPolicy", "notPolicyClass"]), "\(policy)")
        check("detection-trace: scripted fixture reaches region covered / entryPending / underCurtain",
            region.isSuperset(of: ["covered", "entryPending", "underCurtain"]), "\(region)")
        check("detection-trace: scripted fixture reaches curtain credited / orphan / straddle",
            curtainSeen.isSuperset(of: ["credited", "orphan", "straddle"]), "\(curtainSeen)")
        check("detection-trace: straddle's rewoundTo names the curtain the rewind event credited",
            rewoundOK && a.events.contains { $0.contains("attribution-rewind") })
        check("detection-trace: scripted fixture shows a pending window and a curtained one",
            windows.isSuperset(of: ["pending", "curtained"]) && a.events.contains { $0.hasPrefix("drop") },
            "\(windows) events=\(a.events)")
    }

    // MARK: build cost

    /// Measures one build at fixture scale and at the stress scale (kept
    /// boxes = maxBoxes) and prints the numbers the budget's receipt quotes.
    private static func traceBuildTiming() {
        let screen = CGSize(width: 1920, height: 1080)
        func measure(_ raw: [Detection]) -> (p50: Double, p95: Double, max: Double) {
            var input = traceInput(raw)
            input.curtainWalk = .ran
            input.regionSourceIndices = Array(raw.indices)
            var ms: [Double] = []
            for _ in 0..<500 {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = DetectionTraceBuilder.build(input, builtAt: t0, appName: { _ in nil })
                ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            ms.sort()
            return (ms[ms.count / 2], ms[Int(Double(ms.count - 1) * 0.95)], ms[ms.count - 1])
        }
        let fixture = measure(DetectionFixture.detections(frame: 0, screen: screen, pattern: .standard))
        let stress = measure(DetectionFixture.detections(frame: 0, screen: screen, pattern: .stress))
        print(String(format: "# detection-trace build timing (500 builds each): fixture 8 boxes "
            + "p50 %.4f p95 %.4f max %.4f ms; stress %d boxes p50 %.4f p95 %.4f max %.4f ms",
            fixture.p50, fixture.p95, fixture.max, DetectionTraceBuilder.maxBoxes + 5,
            stress.p50, stress.p95, stress.max))
        check("detection-trace: p95 build at the stress scale is under DetectionTraceBuilder.traceBudgetMs",
            stress.p95 < DetectionTraceBuilder.traceBudgetMs,
            String(format: "p95 %.3f ms, budget %.1f ms", stress.p95, DetectionTraceBuilder.traceBudgetMs))
    }
}
