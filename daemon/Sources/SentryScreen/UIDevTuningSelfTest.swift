import CoreGraphics
import Foundation

// `--ui-selftest` group "devtab" (UIDevTuning.swift): the Settings ›
// Developer tab. This file proves the model — slider write → tuning.json bytes, the agent's echo,
// reset, the PIN gate, and the readout filling from injected events.
extension UISelfTest {
    static func caseDeveloperTab(_ dir: String) {
        let fm = FileManager.default
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // FileManager, not Data(contentsOf:): the egress audit reads the
        // latter as a network API.
        let exe = FileManager.default.contents(atPath: CommandLine.arguments[0]) ?? Data()
        // Assembled at run time: a literal here would put the marker into
        // the production binary through this very test.
        let markerText = ["ui", "settings", "developer"].joined(separator: ".")
        let marker = exe.range(of: Data(markerText.utf8)) != nil
        let tabs = UISettingsTab.allCases.map(\.rawValue)
        check("devtab: the Developer tab is the second page",
            tabs == ["general", "developer"]
                && UISettingsTab.developer.label == "Developer"
                && UISettingsTab.developer.controlID == "ui.settings.tab.developer",
            "\(tabs)")
        check("devtab: the binary carries the ui.settings.developer ids", marker,
            "exe bytes \(exe.count)")
        caseDeveloperTabModel(dir)
    }

    private static func caseDeveloperTabModel(_ dir: String) {
        let fm = FileManager.default
        let root = dir + "/state"
        try! fm.createDirectory(atPath: root + "/parent", withIntermediateDirectories: true)
        let base = TuningPolicy.defaults
        let model = UIDevTuning(stateRoot: root, groupID: getegid(), base: base, baseSource: "defaults")
        let path = root + "/parent/tuning.json"

        // --- 1. slider write → tuning.json content ---
        check("devtab: the draft starts as the launch policy, no file, stamp says so",
            model.draft == base && !fm.fileExists(atPath: path) && model.applied == .none(source: "defaults")
                && model.appliedText.contains("launch policy"))
        model.setClass("MALE_GENITALIA_EXPOSED") { $0.minBoxPt = 40 }
        model.setClass("FEMALE_BREAST_COVERED") { $0.threshold = 0.75 }
        model.draft.coveredBeatsExposed = true
        model.setTriggerHits(1)
        check("devtab: triggerHits below the two lower bars pulls them down (parse would refuse the file otherwise)",
            model.draft.curtain.handoffHits == 1 && model.draft.curtain.paroleHits == 1)
        model.setTriggerHits(4)
        // The thresholdSteps FIELD: text → the shared parser → the draft.
        let twoSteps = [
            TuningPolicy.ClassRule.SizeStep(minPt: 48, threshold: 0.8),
            TuningPolicy.ClassRule.SizeStep(minPt: 96, threshold: 0.9),
        ]
        let stepsCommitted = model.applyStepsText("BUTTOCKS_EXPOSED", "48:0.80, 96:0.90")
        check("devtab: the steps readback states the rule in force (base under the first step, each step from its size)",
            UIDeveloperSettingsSection.stepsReadback(threshold: 0.8, steps: []) == "needs 0.80 at any size"
                && UIDeveloperSettingsSection.stepsReadback(threshold: 0.8, steps: twoSteps)
                    == "needs 0.80 under \(TuningPolicy.stepPtText(twoSteps[0].minPt)) pt, "
                    + "\(String(format: "%.2f", Double(twoSteps[0].threshold))) from \(TuningPolicy.stepPtText(twoSteps[0].minPt)) pt, "
                    + "\(String(format: "%.2f", Double(twoSteps[1].threshold))) from \(TuningPolicy.stepPtText(twoSteps[1].minPt)) pt",
            UIDeveloperSettingsSection.stepsReadback(threshold: 0.8, steps: twoSteps))
        check("devtab: a thresholdSteps field commits through the shared parser and renders back canonically",
            stepsCommitted && model.draft.rule(for: "BUTTOCKS_EXPOSED")?.thresholdSteps == twoSteps
                && model.stepsFieldText("BUTTOCKS_EXPOSED") == "48:0.80, 96:0.90" && model.editError == nil,
            "\(String(describing: model.draft.rule(for: "BUTTOCKS_EXPOSED")?.thresholdSteps)) \(model.stepsFieldText("BUTTOCKS_EXPOSED"))")
        // A refusal in the PARSER's words: nothing written, draft untouched,
        // and what was typed stays on screen beside the error.
        let refusedSteps = model.applyStepsText("BUTTOCKS_EXPOSED", "0:0.9")
        check("devtab: a refused thresholdSteps edit names the key, keeps the draft and writes no file",
            !refusedSteps && model.editError?.contains("classes.BUTTOCKS_EXPOSED.thresholdSteps[0].minPt") == true
                && model.draft.rule(for: "BUTTOCKS_EXPOSED")?.thresholdSteps == twoSteps
                && model.stepsFieldText("BUTTOCKS_EXPOSED") == "0:0.9"
                && !fm.fileExists(atPath: path),
            "\(String(describing: model.editError))")
        check("devtab: an empty field clears the staircase",
            model.applyStepsText("ANUS_EXPOSED", "  ")
                && model.draft.rule(for: "ANUS_EXPOSED")?.thresholdSteps.isEmpty == true
                && model.stepsFieldText("ANUS_EXPOSED") == "")
        model.writeFile()
        check("devtab: writeFile clears the pending edit error and the field renders the draft again",
            model.editError == nil && model.stepsFieldText("BUTTOCKS_EXPOSED") == "48:0.80, 96:0.90")
        check("devtab: writeFile ⇒ no error, stamp = written", model.writeError == nil && {
            if case .written = model.applied { return true } else { return false }
        }(), "\(String(describing: model.writeError)) \(model.applied)")
        let data = fm.contents(atPath: path) ?? Data()
        let parsed = TuningFile.parse(data, base: base)
        var expected = base
        expected.standard["MALE_GENITALIA_EXPOSED"]?.minBoxPt = 40
        expected.standard["BUTTOCKS_EXPOSED"]?.thresholdSteps = twoSteps
        expected.strict["FEMALE_BREAST_COVERED"]?.threshold = 0.75
        expected.coveredBeatsExposed = true
        expected.curtain.triggerHits = 4
        expected.curtain.handoffHits = 1
        expected.curtain.paroleHits = 1
        check("devtab: the file parses with TuningFile.parse to exactly the draft (INJECT_TEST stripped, version 1)",
            parsed == .success(expected) && !String(decoding: data, as: UTF8.self).contains("INJECT_TEST"),
            "\(parsed)")
        let mode = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        check("devtab: the file is 0660 like every parent/ file", mode == 0o660, "\(String(describing: mode))")
        check("devtab: no temp file left beside it",
            (try? fm.contentsOfDirectory(atPath: root + "/parent"))?.filter { $0.hasPrefix(".tuning.json.tmp") }.isEmpty == true)
        let copy = String(decoding: UIDevTuning.json(["tuning": UIDevTuning.configObject(model.draft)]), as: UTF8.self)
        check("devtab: Copy as config.json tuning ⇒ a `tuning` object the config parser accepts",
            copy.hasPrefix("{\n  \"tuning\"") && {
                guard let o = try? JSONSerialization.jsonObject(with: Data(copy.utf8)) as? [String: Any],
                    let t = o["tuning"] as? [String: Any] else { return false }
                return TuningPolicy.parse(t, base: base) == .success(expected)
            }())

        // --- 2. the agent's echo ---
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        model.noteOutcome(.loaded(expected), at: at)
        check("devtab: a loaded echo stamps applied HH:MM:SS and the draft follows the effective policy",
            model.applied == .applied(at) && model.applied.stateName == "applied"
                && model.appliedText.hasPrefix("Applied ") && model.appliedText.contains("parent/tuning.json")
                && model.draft == expected, model.appliedText)
        model.editing = true
        var other = expected
        other.curtain.holdSecs = 9
        model.noteOutcome(.loaded(other), at: at)
        check("devtab: an echo during a drag does not move the thumb", model.draft == expected && model.applied == .applied(at))
        model.editing = false
        model.noteOutcome(.refused("\(path): \"curtain.triggerHits\" must be an integer in 1...30 (got 0)"))
        check("devtab: a refused echo names the key and the draft is untouched",
            model.applied.stateName == "refused" && model.appliedText.contains("curtain.triggerHits") && model.draft == expected,
            model.appliedText)

        // --- 3. reset ---
        model.reset()
        check("devtab: reset removes the file, draft = launch policy, stamp = none",
            !fm.fileExists(atPath: path) && model.draft == base && model.applied == .none(source: "defaults") && model.writeError == nil)
        model.reset()
        check("devtab: reset with no file is not an error", model.writeError == nil)
        model.noteOutcome(.absent)
        check("devtab: the agent's removal echo reads none", model.applied.stateName == "none")

        // --- 4. a write that cannot land is named, never dropped ---
        let noDir = UIDevTuning(stateRoot: dir + "/missing", groupID: getegid(), base: base, baseSource: "defaults")
        noDir.writeFile()
        check("devtab: writeFile without a parent/ dir names the path and errno",
            noDir.writeError?.contains("missing/parent") == true && noDir.writeError?.contains("errno=") == true,
            "\(String(describing: noDir.writeError))")

        // --- 5. PIN gate through UIActions (the same requirePIN every parent/ write uses) ---
        let storeRoot = dir + "/store"
        try! fm.createDirectory(atPath: storeRoot, withIntermediateDirectories: true)
        let store = UISettingsStore(root: storeRoot, log: { _, _ in })
        let actions = UIActions(store: store, log: { _, _ in })
        let gated = UIDevTuning(stateRoot: storeRoot, groupID: getegid(), base: base, baseSource: "defaults")
        actions.devTuning = gated
        actions.openSettings()
        gated.setClass("ANUS_EXPOSED") { $0.entryFrames = 5 }
        actions.commitDevTuning()
        check("devtab: commit with no PIN set ⇒ set-PIN layer first, nothing written",
            actions.layer == .setPin && !fm.fileExists(atPath: storeRoot + "/parent/tuning.json"), "\(actions.layer)")
        actions.newPin = "4821"
        actions.confirmPin = "4821"
        actions.saveNewPin()
        spin(until: { !actions.busy })
        let written = fm.fileExists(atPath: storeRoot + "/parent/tuning.json")
        check("devtab: PIN saved ⇒ the file is written and the sheet is back (returnTo .settings)",
            written && actions.layer == .settings, "\(actions.layer) written=\(written)")
        actions.lock()
        actions.openSettings()
        actions.resetDevTuning()
        check("devtab: reset behind the PIN when locked — the prompt names the action, the file stays",
            actions.layer == .pin && actions.pendingConfirmation == "Reset the curtain tuning to the launch policy."
                && fm.fileExists(atPath: storeRoot + "/parent/tuning.json"),
            "\(actions.layer) \(actions.pendingConfirmation ?? "-")")
        actions.pinEntry = "4821"
        actions.submitPIN()
        spin(until: { !actions.busy })
        check("devtab: correct PIN ⇒ reset ran, file gone, sheet back",
            !fm.fileExists(atPath: storeRoot + "/parent/tuning.json") && actions.layer == .settings, "\(actions.layer)")

        // --- 6. the readout fills from injected events ---
        let readout = TuningReadout()
        let now: Double = 1000
        var policy = base
        policy.standard["MALE_GENITALIA_EXPOSED"]?.minBoxPt = 24
        policy.coveredBeatsExposed = true
        let screen = CGSize(width: 1920, height: 1080)
        let small = Detection(label: "MALE_GENITALIA_EXPOSED", confidence: 0.62, box: CGRect(x: 0.4, y: 0.5, width: 0.01, height: 0.03))
        let big = Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.84, box: CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.3))
        let exposed = Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.71, box: CGRect(x: 0.30, y: 0.30, width: 0.05, height: 0.08))
        let covered = Detection(label: "FEMALE_BREAST_COVERED", confidence: 0.66, box: CGRect(x: 0.28, y: 0.28, width: 0.12, height: 0.16))
        let inject = Detection(label: TuningPolicy.injectLabel, confidence: 1, box: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let face = Detection(label: "FACE_FEMALE", confidence: 0.9, box: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
        check("devtab: an empty readout snapshots empty", readout.snapshot(now: now).isEmpty)
        // One helper: the readout is always fed the SAME frame's filter
        // result the pipeline logs its counters from (main.swift:1570).
        func feed(_ raw: [Detection], _ r: TuningReadout = readout, policy p: TuningPolicy = policy,
            blockFaces: Bool = false, screen sc: CGSize = screen, at: Double)
        {
            r.record(
                raw: raw, filtered: p.filter(raw, mode: .strict, blockFaces: blockFaces, screen: sc),
                tuning: p, mode: .strict, blockFaces: blockFaces, screen: sc, now: at)
        }
        feed([big, exposed, covered, inject, face, small], blockFaces: true, at: now - 5)
        feed([big], at: now - 2)
        feed([Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.55, box: CGRect(x: 0.5, y: 0.4, width: 0.1, height: 0.1))], at: now - 1)
        // Outside the window: must not count.
        feed([big, small], at: now - 61)
        readout.recordCurtain(action: "lift (hold)", windowID: 7, app: "Safari", now: now - 70)
        readout.recordCurtain(action: "drop (parole)", windowID: 9, app: "Safari", now: now - 4)
        readout.recordCurtain(action: "lift (hold)", windowID: 9, app: "Safari", now: now - 1)
        let s = readout.snapshot(now: now)
        let byLabel = Dictionary(uniqueKeysWithValues: s.classes.map { ($0.label, $0) })
        check("devtab: readout counts hits per policy class only (INJECT_TEST and faces excluded), window 60 s",
            s.classes.map(\.label) == ["FEMALE_BREAST_EXPOSED", "MALE_GENITALIA_EXPOSED", "BUTTOCKS_EXPOSED", "FEMALE_BREAST_COVERED"]
                && byLabel["BUTTOCKS_EXPOSED"]?.hits == 3 && byLabel["MALE_GENITALIA_EXPOSED"]?.hits == 1,
            "\(s.classes)")
        let b = byLabel["BUTTOCKS_EXPOSED"]
        check("devtab: largest / smallest box in points and max conf",
            b?.minPt == 108 && b?.maxPt == 324 && b?.maxConf == 0.84,
            "\(String(describing: b))")
        check("devtab: the small MALE box is named as suppressed by min box with its size and floor",
            s.suppressedMinBox == 1 && s.suppressedCovered == 1
                && s.lastSuppression?.rule == .minBox && s.lastSuppression?.detail.contains("19.20 pt") == true
                && s.lastSuppression?.detail.contains("minBoxPt 24") == true,
            "\(String(describing: s.lastSuppression)) minBox=\(s.suppressedMinBox) covered=\(s.suppressedCovered)")
        check("devtab: last curtain drop is the drop (not the later lift), with reason, window and app",
            s.lastDrop?.action == "drop (parole)" && s.lastDrop?.windowID == 9 && s.lastDrop?.app == "Safari"
                && s.lastCurtain?.action == "lift (hold)" && s.overflow == 0,
            "\(String(describing: s.lastDrop))")
        check("devtab: readout lines carry the numbers",
            UIDeveloperSettingsSection.classLine(b!) == "BUTTOCKS_EXPOSED: 3 hits, 108–324 pt, max conf 0.84"
                && UIDeveloperSettingsSection.dropLine(s).hasPrefix("Last curtain drop: drop (parole) window 9 app=Safari")
                && UIDeveloperSettingsSection.suppressedLine(s).hasPrefix(
                    "Suppressed: min box 1, covered-beats-exposed 1, threshold step 0 — last: min box"),
            UIDeveloperSettingsSection.suppressedLine(s))
        let covered60 = readout.snapshot(now: now + 50)
        let expired = readout.snapshot(now: now + 62)
        check("devtab: hits and the drop age out of the 60 s window",
            !covered60.classes.isEmpty && covered60.lastDrop != nil && expired.classes.isEmpty && expired.lastDrop == nil)
        // Unmeasured screen (--replay): sizes unknown, hits still counted.
        feed([big], screen: .zero, at: now + 100)
        let un = readout.snapshot(now: now + 100).classes.first { $0.label == "BUTTOCKS_EXPOSED" }
        check("devtab: an unmeasured screen counts the hit with no size",
            un?.hits == 1 && un?.minPt == nil && UIDeveloperSettingsSection.classLine(un!).contains("size unmeasured"))
        // The ring bound is visible: overflow is counted and printed.
        let flood = TuningReadout()
        for i in 0..<(TuningReadout.capacity + 10) {
            feed([big], flood, at: Double(i) * 0.001)
        }
        let fs = flood.snapshot(now: 1)
        check("devtab: ring overflow is counted (TuningReadout.capacity), never a silent shorter window",
            fs.overflow == 10 && fs.classes.first?.hits == TuningReadout.capacity, "overflow=\(fs.overflow) hits=\(fs.classes.first?.hits ?? -1)")
        check("devtab: the FRAME ring's eviction is counted too (TuningReadout.frameCapacity)",
            fs.framesOverflow == TuningReadout.capacity + 10 - TuningReadout.frameCapacity
                && fs.blockedFrames == TuningReadout.frameCapacity,
            "framesOverflow=\(fs.framesOverflow) blockedFrames=\(fs.blockedFrames)")
        // A long session is not an overflow: 10 min at 30 fps with 3 boxes a
        // frame is 54,000 hits and 18,000 frames in total (past both
        // capacities) but 5,400 hits / 1,800 frames per 60 s window, so
        // aged-out entries are pruned and nothing is counted as evicted.
        let long = TuningReadout()
        let longFrames = 18_000
        for i in 0..<longFrames { feed([big, big, big], long, at: Double(i) / 30) }
        let ls = long.snapshot(now: Double(longFrames - 1) / 30)
        let lhits = ls.classes.first?.hits ?? -1
        check("devtab: a long session prunes by time — no eviction counted, the window still full",
            ls.overflow == 0 && ls.framesOverflow == 0 && (5_397...5_406).contains(lhits)
                && (1_799...1_802).contains(ls.blockedFrames),
            "overflow=\(ls.overflow) framesOverflow=\(ls.framesOverflow) hits=\(lhits) blockedFrames=\(ls.blockedFrames)")
        // Region strict on a busy grid (receipt at `TuningReadout.capacity`):
        // the measured 14 policy-class boxes a frame for a full 60 s at 30
        // fps fits the hit ring without an eviction.
        let busy = TuningReadout()
        let grid = Array(repeating: big, count: 14)
        for i in 0..<1_800 { feed(grid, busy, at: Double(i) / 30) }
        let bs = busy.snapshot(now: 1_799.0 / 30)
        check("devtab: 14 boxes a frame x 30 fps x 60 s fits TuningReadout.capacity",
            bs.overflow == 0 && bs.classes.first?.hits == 25_200,
            "overflow=\(bs.overflow) hits=\(bs.classes.first?.hits ?? -1)")

        // --- 6b. the threshold staircase in the readout ---
        // BUTTOCKS carries the staircase; MALE carries a size floor AND a
        // staircase, to prove the size floor owns a box the filter drops.
        let stepReadout = TuningReadout()
        var stepPolicy = base
        stepPolicy.standard["BUTTOCKS_EXPOSED"]?.thresholdSteps = [.init(minPt: 128, threshold: 0.9)]
        stepPolicy.standard["MALE_GENITALIA_EXPOSED"]?.minBoxPt = 24
        stepPolicy.standard["MALE_GENITALIA_EXPOSED"]?.thresholdSteps = [.init(minPt: 16, threshold: 0.95)]
        // Frame A: the 324-pt BUTTOCKS box is cut by the ≥ 128 pt step, the
        // FEMALE_BREAST box still blocks ⇒ a cut box, no emptied frame.
        feed([big, exposed], stepReadout, policy: stepPolicy, at: now)
        let a = stepReadout.snapshot(now: now)
        check("devtab: the readout names the step that cut a box — side, floor, the step's boundary and the base it replaced",
            a.lastSuppression?.rule == .thresholdStep
                && a.lastSuppression?.detail == "BUTTOCKS_EXPOSED 324 pt conf 0.84 < 0.90 (step ≥ 128 pt; base 0.50)"
                && a.stepBoxesCut == 1 && a.stepFramesEmptied == 0 && a.blockedFrames == 1,
            "\(String(describing: a.lastSuppression)) cut=\(a.stepBoxesCut) emptied=\(a.stepFramesEmptied) blocked=\(a.blockedFrames)")
        // Frame B: the same box alone ⇒ the frame is EMPTIED (the only
        // outcome that can move a curtain drop).
        feed([big], stepReadout, policy: stepPolicy, at: now + 1)
        // Frame C: a 108-pt BUTTOCKS box is BELOW the boundary, so the base
        // 0.50 applies and 0.55 still blocks — no cut.
        feed([Detection(label: "BUTTOCKS_EXPOSED", confidence: 0.55, box: CGRect(x: 0.5, y: 0.4, width: 0.1, height: 0.1))],
            stepReadout, policy: stepPolicy, at: now + 2)
        // Frame D: the 19.2-pt MALE box is removed by minBoxPt 24. It is over
        // the 16-pt step and under its 0.95 floor, so ONLY the ordering keeps
        // it out of the step count — and the frame never blocked at all.
        feed([small], stepReadout, policy: stepPolicy, at: now + 3)
        let st = stepReadout.snapshot(now: now + 3)
        check("devtab: boxes cut, frames emptied and blocked frames are three different numbers",
            st.stepBoxesCut == 2 && st.stepFramesEmptied == 1 && st.blockedFrames == 3,
            UIDeveloperSettingsSection.stepsLine(st))
        check("devtab: a box the size floor removes is a size drop, never a step drop",
            st.suppressedMinBox == 1 && st.lastSuppression?.rule == .minBox,
            "minBox=\(st.suppressedMinBox) last=\(String(describing: st.lastSuppression?.rule))")
        check("devtab: the steps line spells out that only an emptied frame can move a drop",
            UIDeveloperSettingsSection.stepsLine(st)
                == "Threshold steps: 2 boxes cut, 1 of 3 blocked frames emptied "
                    + "(a cut moves a curtain drop only if it empties its window that frame)",
            UIDeveloperSettingsSection.stepsLine(st))
        check("devtab: the suppressed line carries the step count beside the other two rules",
            UIDeveloperSettingsSection.suppressedLine(st)
                .hasPrefix("Suppressed: min box 1, covered-beats-exposed 0, threshold step 2 — last: min box"),
            UIDeveloperSettingsSection.suppressedLine(st))
        // An unmeasured screen (--replay) falls back to the flat threshold:
        // the box blocks, nothing is cut, and no step is named.
        feed([big], stepReadout, policy: stepPolicy, screen: .zero, at: now + 4)
        let unmeasured = stepReadout.snapshot(now: now + 4)
        check("devtab: an unmeasured screen falls back to the base — no cut, no step named, the frame still blocked",
            unmeasured.stepBoxesCut == 2 && unmeasured.blockedFrames == 4
                && unmeasured.lastSuppression?.rule == .minBox,
            "cut=\(unmeasured.stepBoxesCut) blocked=\(unmeasured.blockedFrames)")

        caseDeveloperTabTrackRows(root: root, base: base)

        // --- 7. the model's tick publishes the snapshot; reset clears it ---
        let live = UIDevTuning(stateRoot: root, groupID: getegid(), base: base, baseSource: "defaults", readout: readout)
        live.tick(now: now + 100)
        check("devtab: tick publishes the readout snapshot", live.snapshot == readout.snapshot(now: now + 100) && !live.snapshot.isEmpty)
        readout.reset()
        live.tick(now: now)
        check("devtab: readout reset empties it", live.snapshot.isEmpty)

        // --- 8. the slider ids read the live draft ---
        var p = base
        p.standard["ANUS_EXPOSED"]?.minBoxPt = 12
        p.curtain.windowSecs = 2.5
        check("devtab: UIDeveloperSettingsSection.current maps every slider id to its draft field",
            UIDeveloperSettingsSection.current(id: "ui.settings.developer.ANUS_EXPOSED.minBoxPt", in: p) == 12
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.ANUS_EXPOSED.threshold", in: p) == 0.5
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.ANUS_EXPOSED.entryFrames", in: p) == 2
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.coveredOverlap", in: p) == base.coveredOverlap
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.curtain.triggerHits", in: p) == 3
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.curtain.windowSecs", in: p) == 2.5
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.curtain.holdSecs", in: p) == 5
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.NOPE.threshold", in: p) == nil
                // thresholdSteps is TEXT, not a Double: the id map must not
                // answer for it — its row's own `read` closure does
                // (`UIDeveloperSettingsSection.stepsRow`).
                && UIDeveloperSettingsSection.current(id: "ui.settings.developer.ANUS_EXPOSED.thresholdSteps", in: p) == nil)
        try? fm.removeItem(atPath: dir)
    }

    /// --- 6c. "Last 60 s" rows (2026-10-20): one row per track, ranked by
    /// decayed peak, ✓ from the curtain's drop indices, near misses, the
    /// track cap, and the freeze timeout. Synthetic detections only.
    private static func caseDeveloperTabTrackRows(root: String, base shipped: TuningPolicy) {
        // Floors pinned to 0.5 HERE: these cases test the rows, not the
        // shipped floors, so they must not move when the defaults do.
        var base = shipped
        for l in TuningPolicy.exposedLabels { base.standard[l]?.threshold = 0.5 }
        let screen = CGSize(width: 1920, height: 1080)
        func det(_ l: String, _ c: Float, x: CGFloat, y: CGFloat, w: CGFloat = 0.06, h: CGFloat = 0.1) -> Detection {
            Detection(label: l, confidence: c, box: CGRect(x: x, y: y, width: w, height: h))
        }
        func feed(
            _ r: TuningReadout, _ raw: [Detection], policy p: TuningPolicy = base, at: Double,
            windows: [Int: CGWindowID] = [:], drops: [TuningReadout.Drop] = [], blockedCount: Int? = nil
        ) {
            let f = p.filter(raw, mode: .standard, blockFaces: false, screen: screen)
            r.record(
                raw: raw, filtered: f, tuning: p, mode: .standard, blockFaces: false, screen: screen, now: at,
                blockedCount: blockedCount ?? f.blocked.count, windows: windows, drops: drops,
                appName: { $0 == 7 ? "Safari" : ($0 == 9 ? "Preview" : nil) })
        }
        let fbeFloor = base.standard["FEMALE_BREAST_EXPOSED"]!.threshold
        let mgeFloor = base.standard["MALE_GENITALIA_EXPOSED"]!.threshold
        let r = TuningReadout()
        var limits: [String] = []
        r.onLimit = { limits.append($0) }
        let t0: Double = 5000
        // A blocked FBE credited to window 7 (blocked index 0), a blocked BE
        // nobody credited, and an MGE 0.03 under its floor.
        let fbe = det("FEMALE_BREAST_EXPOSED", fbeFloor + 0.30, x: 0.10, y: 0.70)
        let be = det("BUTTOCKS_EXPOSED", 0.60, x: 0.60, y: 0.70)
        let mge = det("MALE_GENITALIA_EXPOSED", mgeFloor - 0.03, x: 0.60, y: 0.10)
        feed(r, [fbe, be, mge], at: t0, windows: [0: 7])
        var s = r.snapshot(now: t0)
        check("rows: one row per track, ranked by peak at age 0 (FBE, BE, then the MGE near miss)",
            s.rows.map(\.code) == ["FBE", "BE", "MGE"], "\(s.rows.map(\.code))")
        let fbeRow = s.rows.first { $0.code == "FBE" }
        check("rows: the credited FBE row carries window 7, its app, size, floor and status ◼",
            fbeRow?.windowID == 7 && fbeRow?.app == "Safari" && fbeRow?.status == .covered
                && fbeRow?.floor == fbeFloor && fbeRow?.sidePt == 108, "\(String(describing: fbeRow))")
        let mgeRow = s.rows.first { $0.code == "MGE" }
        check("rows: a peak within TuningReadout.nearMissBand (0.05) under its floor is a near miss, status ○",
            mgeRow?.nearMiss == true && mgeRow?.status == .below && fbeRow?.nearMiss == false
                && TuningReadout.nearMissBand == 0.05)
        check("rows: the row text reads symbol, code, \"peak · floor\", size, app, age",
            fbeRow.map(UIDeveloperSettingsSection.rowLine)
                == "◼ FBE \(TuningReadout.conf(fbeFloor + 0.30)) · floor \(TuningReadout.conf(fbeFloor)) 108 pt Safari 0 s — covered",
            fbeRow.map(UIDeveloperSettingsSection.rowLine) ?? "nil")
        // The same subject next frame, walk skipped (no credit): it joins the
        // credited track instead of starting a window-less one.
        feed(r, [det("FEMALE_BREAST_EXPOSED", fbeFloor + 0.35, x: 0.11, y: 0.70)], at: t0 + 1)
        s = r.snapshot(now: t0 + 1)
        let joined = s.rows.filter { $0.code == "FBE" }
        check("rows: an uncredited box joins its label's track in the same cell (one row, 2 hits, window kept, peak raised)",
            joined.count == 1 && joined[0].hits == 2 && joined[0].windowID == 7
                && joined[0].peak == fbeFloor + 0.35 && joined[0].latest == fbeFloor + 0.35, "\(joined)")
        // DECAY: a fresh weaker box outranks an older stronger one.
        feed(r, [det("FEMALE_GENITALIA_EXPOSED", 0.80, x: 0.35, y: 0.40)], at: t0 + 11)
        s = r.snapshot(now: t0 + 11)
        let expectFBE = Double(fbeFloor + 0.35) * pow(0.5, 10 / TuningReadout.rankHalfLifeSecs)
        let fbeNow = s.rows.first { $0.code == "FBE" }
        check("rows: rank = peak × 0.5^(age / 15 s) (TuningReadout.rankHalfLifeSecs)",
            TuningReadout.rankHalfLifeSecs == 15 && fbeNow.map { abs($0.rank - expectFBE) < 1e-6 } == true
                && fbeNow?.ageSecs == 10, "\(String(describing: fbeNow?.rank)) vs \(expectFBE)")
        check("rows: decay re-ranks — the fresh FGE 0.80 sits above the 10 s old FBE",
            s.rows.first?.code == "FGE" && s.rows.firstIndex { $0.code == "FGE" }! < s.rows.firstIndex { $0.code == "FBE" }!,
            "\(s.rows.map { "\($0.code) \($0.rank)" })")
        check("rows: ranking happens in the snapshot (the 1 Hz tick), and a row ages out 60 s after its last hit",
            r.snapshot(now: t0 + 61).rows.map(\.code) == ["FGE", "FBE"]
                && r.snapshot(now: t0 + 72).rows.isEmpty,
            "\(r.snapshot(now: t0 + 61).rows.map(\.code))")

        // ✓ ATTRIBUTION: drop indices point into the BLOCKED list; only the
        // tracks behind those boxes get the mark.
        let cr = TuningReadout()
        let a = det("BUTTOCKS_EXPOSED", 0.70, x: 0.10, y: 0.10)
        let below = det("ANUS_EXPOSED", 0.20, x: 0.40, y: 0.40)  // not blocked: no blocked index
        let b = det("FEMALE_BREAST_EXPOSED", 0.90, x: 0.70, y: 0.70)
        feed(cr, [a, below, b], at: t0, windows: [0: 9, 1: 7], drops: [TuningReadout.Drop(windowID: 7, indices: [1])])
        let cs = cr.snapshot(now: t0)
        let bRow = cs.rows.first { $0.code == "FBE" }, aRow = cs.rows.first { $0.code == "BE" }
        check("rows: ✓ goes to the track behind the drop's blocked index (raw 2 = blocked 1), not its neighbour",
            bRow?.status == .curtain && bRow?.windowID == 7 && aRow?.status == .covered && aRow?.windowID == 9
                && aRow?.app == "Preview" && cs.rows.first { $0.code == "AE" }?.status == .below,
            "\(cs.rows.map { "\($0.code) \($0.status) \(String(describing: $0.windowID))" })")
        feed(cr, [b], at: t0 + 1, windows: [0: 7])
        check("rows: ✓ is sticky for the track's life (a later plain hit keeps it)",
            cr.snapshot(now: t0 + 1).rows.first { $0.code == "FBE" }?.status == .curtain)
        check("rows: the ✓ row reads \"curtain dropped\"",
            UIDeveloperSettingsSection.rowLine(cr.snapshot(now: t0 + 1).rows.first { $0.code == "FBE" }!)
                .hasPrefix("✓ FBE 0.90 · floor 0.50 ") == true)
        if let aRow {
            let meta = UIDeveloperSettingsSection.metaText(aRow)
            check("rows: the second line is size · app · age",
                meta.hasSuffix(" · Preview · 0 s") && meta.hasSuffix("pt · Preview · 0 s"), meta)
        }

        // ⊘: which rule removed the box.
        let rr = TuningReadout()
        var ruled = base
        ruled.standard["MALE_GENITALIA_EXPOSED"]?.minBoxPt = 24
        ruled.standard["BUTTOCKS_EXPOSED"]?.thresholdSteps = [.init(minPt: 128, threshold: 0.9)]
        feed(rr, [
            det("MALE_GENITALIA_EXPOSED", 0.9, x: 0.10, y: 0.10, w: 0.01, h: 0.01),
            det("FEMALE_BREAST_EXPOSED", 0.9, x: 0.31, y: 0.31, w: 0.04, h: 0.06),
            det("FEMALE_BREAST_COVERED", 0.7, x: 0.28, y: 0.28, w: 0.12, h: 0.16),
            det("BUTTOCKS_EXPOSED", 0.8, x: 0.60, y: 0.40, w: 0.2, h: 0.3),
        ], policy: ruled, at: t0)
        let rules = Dictionary(uniqueKeysWithValues: rr.snapshot(now: t0).rows.map { ($0.code, $0.status) })
        check("rows: ⊘ names the rule — minBoxPt, covered-beats-exposed, size step; a covered class off under Standard has no row",
            rules["MGE"] == .removed("minBoxPt") && rules["FBE"] == .removed("covered-beats-exposed")
                && rules["BE"] == .removed("size step") && rules["covered"] == nil, "\(rules)")

        // A mirror that disagrees with the pipeline is counted and said once.
        let mr = TuningReadout()
        var mlines: [String] = []
        mr.onLimit = { mlines.append($0) }
        feed(mr, [b], at: t0, windows: [0: 7], blockedCount: 2)
        feed(mr, [b], at: t0 + 1, windows: [0: 7], blockedCount: 2)
        let ms = mr.snapshot(now: t0 + 1)
        check("rows: a policy-mirror mismatch drops window and ✓ for the frame, counts it, logs once",
            ms.attributionSkipped == 2 && ms.rows.first?.windowID == nil && ms.rows.first?.hits == 2
                && mlines.count == 1 && mlines[0].contains("TuningReadout.record"), "\(mlines)")

        // TRACK CAP: one past the cap evicts the lowest-ranked row, counted and logged.
        let capped = TuningReadout()
        var clines: [String] = []
        capped.onLimit = { clines.append($0) }
        for i in 0...TuningReadout.trackCapacity {
            feed(capped, [det("FEMALE_BREAST_EXPOSED", i == 0 ? 0.55 : 0.95, x: 0.5, y: 0.5)],
                at: t0 + Double(i) * 0.001, windows: [0: CGWindowID(100 + i)])
        }
        let caps = capped.snapshot(now: t0 + 1)
        check("rows: past TuningReadout.trackCapacity (512) the lowest-ranked row is evicted, counted and logged by name",
            TuningReadout.trackCapacity == 512 && caps.rows.count == TuningReadout.trackCapacity
                && caps.tracksEvicted == 1 && !caps.rows.contains { $0.windowID == 100 }
                && clines.count == 1 && clines[0].contains("TuningReadout.trackCapacity configured=512"),
            "rows=\(caps.rows.count) evicted=\(caps.tracksEvicted) \(clines)")
        check("rows: the eviction is said on the tab", UIDeveloperSettingsSection.tracksEvictedLine(caps).contains("1 rows evicted"))

        // FREEZE: rows stop moving; after `freezeSecs` the freeze ends by itself.
        let fr = TuningReadout()
        let model = UIDevTuning(stateRoot: root, groupID: getegid(), base: base, baseSource: "defaults", readout: fr)
        feed(fr, [fbe], at: t0, windows: [0: 7])
        model.tick(now: t0)
        model.freeze(now: t0)
        feed(fr, [det("ANUS_EXPOSED", 0.99, x: 0.8, y: 0.2)], at: t0 + 1)
        model.tick(now: t0 + 1)
        let frozenRows = model.snapshot.rows.map(\.id)
        check("rows: Freeze holds the rows (no new row, no re-rank) while the footer stays live",
            model.frozenAt == t0 && frozenRows.count == 1 && model.freezeRemaining(now: t0 + 1) == 29)
        model.tick(now: t0 + UIDevTuning.freezeSecs - 0.5)
        check("rows: still frozen just before UIDevTuning.freezeSecs (30 s)",
            model.frozenAt != nil && model.snapshot.rows.count == 1 && UIDevTuning.freezeSecs == 30)
        model.tick(now: t0 + UIDevTuning.freezeSecs)
        check("rows: the freeze ends by itself at 30 s and the rows re-rank (the new AE 0.99 on top)",
            model.frozenAt == nil && model.snapshot.rows.first?.code == "AE" && model.snapshot.rows.count == 2,
            "\(model.snapshot.rows.map(\.code))")
        model.freeze(now: t0 + 31)
        model.clearReadout(now: t0 + 31)
        check("rows: Clear empties the rows and ends a freeze", model.snapshot.rows.isEmpty && model.frozenAt == nil)
        // Copy: every row plus the footer; labels, numbers and app names only.
        feed(fr, [fbe, mge], at: t0 + 40, windows: [0: 7])
        model.tick(now: t0 + 40)
        let text = UIDeveloperSettingsSection.readoutText(model.snapshot)
        check("rows: Copy readout carries every row (full label, window, hits) and the footer lines",
            text.contains("FEMALE_BREAST_EXPOSED, window 7, 1 hits") && text.contains("near miss")
                && text.contains("Last curtain drop:") && text.contains("Threshold steps:"), text)
    }
}
