import CoreGraphics
import Foundation

// `--ui-selftest` cases for TuningPolicy.swift (SENTRY_UI_SELFTEST_CASE=tuning
// runs this group alone). Plain executable asserts, same harness as
// UISelfTest: the defaults must equal the constants they replaced, every
// source must refuse by key, and the two new rules must move only what they
// say they move.
extension UISelfTest {
    static func caseTuningPolicy(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let d = TuningPolicy.defaults
        func det(_ label: String, _ conf: Float, _ box: CGRect) -> Detection {
            Detection(label: label, confidence: conf, box: box)
        }
        let big = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        let small = CGRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02)

        // --- 0. rejections / withheld (the withheld tripwire's stage names) ---
        do {
            // 0.92: above the shipped 0.90 FBE floor (2026-10-20), under the
            // raised 0.95 one — the same gap the 0.85/0.9 pair had at 0.5.
            let fbe = det("FEMALE_BREAST_EXPOSED", 0.92, big)
            let fbc = det("FEMALE_BREAST_COVERED", 0.7, big)
            let face = det("FACE_FEMALE", 0.9, big)
            let screen = CGSize(width: 1920, height: 1080)
            var raised = d
            raised.standard["FEMALE_BREAST_EXPOSED"]?.threshold = 0.95
            let r = raised.rejections([fbe, face], mode: .standard, blockFaces: false, screen: screen)
            check("tuning: rejections — FBE 0.92 under a 0.95 floor is stage=threshold; a benign class is not listed",
                r.count == 1 && r[0].index == 0 && r[0].stage == "threshold", "\(r)")
            let w = raised.withheld([fbe, face], mode: .standard, blockFaces: false, screen: screen, baseline: d)
            check("tuning: withheld — the raised floor withholds the box the defaults block",
                w.count == 1 && w[0].index == 0 && w[0].stage == "threshold", "\(w)")
            check("tuning: withheld — the defaults withhold nothing against themselves",
                d.withheld([fbe, fbc, face], mode: .standard, blockFaces: false, screen: screen, baseline: d).isEmpty)
            check("tuning: rejections — a demoted box under standard is stage=coveredBeatsExposed",
                d.rejections([fbe, fbc], mode: .standard, blockFaces: false, screen: screen)
                    .contains { $0.index == 0 && $0.stage == "coveredBeatsExposed" })
            var floored = d
            floored.standard["FEMALE_BREAST_EXPOSED"]?.minBoxPt = 100
            let m = floored.withheld([det("FEMALE_BREAST_EXPOSED", 0.92, small)], mode: .standard,
                                     blockFaces: false, screen: screen, baseline: d)
            check("tuning: withheld — a size floor the defaults lack is stage=minBox",
                m.count == 1 && m[0].stage == "minBox", "\(m)")
            check("tuning: withheld — a box below the DEFAULT floor is not withheld (defaults reject it too)",
                raised.withheld([det("FEMALE_BREAST_EXPOSED", 0.89, big)], mode: .standard,
                                blockFaces: false, screen: screen, baseline: d).isEmpty)
        }

        // --- 1. defaults: the receipted constants (explicit floors per class
        // since 2026-10-20, receipt at `TuningPolicy.defaults`) ---
        let shippedFloors: [String: Float] = [
            "FEMALE_BREAST_EXPOSED": 0.9, "FEMALE_GENITALIA_EXPOSED": 0.7,
            "MALE_GENITALIA_EXPOSED": 0.9, "BUTTOCKS_EXPOSED": 0.8, "ANUS_EXPOSED": 0.7,
        ]
        check("tuning: defaults — FBE 0.90, FGE 0.70, MGE 0.90, BE 0.80, AE 0.70, INJECT_TEST at 0, covered at 0.6",
            TuningPolicy.exposedLabels.allSatisfy { d.standard[$0]?.threshold == shippedFloors[$0] }
                && shippedFloors.count == TuningPolicy.exposedLabels.count
                && d.standard["INJECT_TEST"]?.threshold == 0
                && TuningPolicy.coveredLabels.allSatisfy { d.strict[$0]?.threshold == 0.6 }
                && d.standard.count == 6 && d.strict.count == 3)
        // Covered-beats-exposed ON at 0.9 since PR 2/3 (receipt at the field).
        check("tuning: defaults — no size floor, entryFrames 2, covered-beats-exposed on at 0.9",
            d.standard.values.allSatisfy { $0.minBoxFraction == 0 && $0.minBoxPt == 0 && $0.entryFrames == 2 }
                && d.strict.values.allSatisfy { $0.minBoxFraction == 0 && $0.minBoxPt == 0 && $0.entryFrames == 2 }
                && d.coveredBeatsExposed && d.coveredOverlap == 0.9)
        // Kept on through the 2026-10-20 floor change (owner decision): an
        // exposed box ABOVE its new floor, inside a covered box of the same
        // part, is still demoted and so does not block under standard.
        let demotedAtNewFloor = d.filter(
            [det("FEMALE_BREAST_EXPOSED", 0.95, small), det("FEMALE_BREAST_COVERED", 0.7, big)],
            mode: .standard, blockFaces: false, screen: .zero)
        check("tuning: defaults — covered-beats-exposed still demotes an FBE 0.95 box (above its 0.90 floor) inside FBC",
            demotedAtNewFloor.blocked.isEmpty && demotedAtNewFloor.demoted == 1,
            "blocked=\(demotedAtNewFloor.blocked.count) demoted=\(demotedAtNewFloor.demoted)")
        check("tuning: defaults — curtain 3 hits / 1.0 s, handoff 2, parole 2, hold 5.0 s / 20 clean frames",
            d.curtain == TuningPolicy.CurtainRules(
                triggerHits: 3, windowSecs: 1.0, handoffHits: 2, paroleHits: 2, holdSecs: 5.0, holdCleanFrames: 20))
        check("tuning: defaults — tracker 0.4 s clear, 1.0 s sticky, stickyConf 0.6, matchIoU 0.3",
            d.tracker == TuningPolicy.TrackerRules(
                clearAfterSecs: 0.4, stickyHoldSecs: 1.0, stickyConf: 0.6, matchIoU: 0.3))
        check("tuning: the Curtain / Tracker default aliases read the struct",
            Curtain.triggerHits == 3 && Curtain.windowSecs == 1.0 && Curtain.handoffHits == 2
                && Curtain.paroleHits == 2 && Curtain.holdSecs == 5.0 && Curtain.holdCleanFrames == 20
                && Tracker.defaultClearAfter(fps: 30) == 12 && Tracker.defaultStickyHold(fps: 30) == 30)
        // Every shipped floor is inclusive: the floor itself blocks, 0.01
        // under it does not.
        check("tuning: blocks() is the old Policy.blocks — each explicit floor inclusive, standard ignores covered, strict takes it at 0.6, faces only with the flag",
            shippedFloors.allSatisfy { label, t in
                d.blocks(det(label, t, big), mode: .standard, blockFaces: false)
                    && !d.blocks(det(label, t - 0.01, big), mode: .standard, blockFaces: false)
            }
                && !d.blocks(det("FEMALE_BREAST_EXPOSED", 0.5, big), mode: .standard, blockFaces: false)
                && !d.blocks(det("BUTTOCKS_COVERED", 0.9, big), mode: .standard, blockFaces: false)
                && d.blocks(det("BUTTOCKS_COVERED", 0.6, big), mode: .strict, blockFaces: false)
                && !d.blocks(det("BUTTOCKS_COVERED", 0.59, big), mode: .strict, blockFaces: false)
                && !d.blocks(det("FACE_FEMALE", 0.9, big), mode: .strict, blockFaces: false)
                && d.blocks(det("FACE_FEMALE", 0.25, big), mode: .strict, blockFaces: true)
                && d.blocks(det("INJECT_TEST", 0, big), mode: .standard, blockFaces: false))
        switch TuningPolicy.parse(d.jsonObject.filter { $0.key != "classes" }, base: d) {
        case let .success(p): check("tuning: the JSON dump (minus classes) re-parses to the defaults", p == d)
        case let .failure(e): check("tuning: the JSON dump (minus classes) re-parses", false, e.text)
        }
        var classesOnly = d.jsonObject["classes"] as! [String: Any]
        classesOnly.removeValue(forKey: "INJECT_TEST")
        switch TuningPolicy.parse(["classes": classesOnly], base: d) {
        case let .success(p): check("tuning: the dumped classes re-parse to the defaults", p == d)
        case let .failure(e): check("tuning: the dumped classes re-parse", false, e.text)
        }
        check("tuning: jsonString is one sorted line",
            !d.jsonString().contains("\n") && d.jsonString().hasPrefix("{\"classes\":"), d.jsonString())
        // Shortest decimals (2026-10-20): 0.7, never 0.69999999999999996.
        let dumped = d.jsonString()
        check("tuning: the dump writes floats as short decimals",
            dumped.contains("\"threshold\":0.7") && dumped.contains("\"coveredOverlap\":0.9")
                && !dumped.contains("99999") && !dumped.contains("00000000"), dumped)
        // INJECT_TEST is dumped but refused by the parser by design; the
        // Developer tab strips it the same way (`UIDevTuning.configObject`).
        var obj = (try? JSONSerialization.jsonObject(with: Data(dumped.utf8))) as? [String: Any] ?? [:]
        if var classes = obj["classes"] as? [String: Any] {
            classes.removeValue(forKey: TuningPolicy.injectLabel)
            obj["classes"] = classes
        }
        if case let .success(back) = TuningPolicy.parse(obj, base: d) {
            check("tuning: the short-decimal dump parses back to the same policy",
                back.jsonString() == dumped && back.standard["ANUS_EXPOSED"]?.threshold == d.standard["ANUS_EXPOSED"]?.threshold)
        } else {
            check("tuning: the short-decimal dump parses back to the same policy", false, dumped)
        }

        // --- 2. config override: accepted by key, refused by key ---
        let over: [String: Any] = [
            "classes": [
                "MALE_GENITALIA_EXPOSED": ["threshold": 0.7, "minBoxPt": 24, "entryFrames": 3],
                "BUTTOCKS_COVERED": ["minBoxFraction": 0.001],
            ],
            "coveredBeatsExposed": true, "coveredOverlap": 0.8,
            "curtain": ["triggerHits": 5, "handoffHits": 3, "holdSecs": 2.5],
            "tracker": ["clearAfterSecs": 1.0, "stickyConf": 0.9],
        ]
        var p = d
        switch TuningPolicy.parse(over, base: d) {
        case let .success(x): p = x
        case let .failure(e): check("tuning: a valid override parses", false, e.text)
        }
        check("tuning: override — only the named fields moved",
            p.standard["MALE_GENITALIA_EXPOSED"] == TuningPolicy.ClassRule(threshold: 0.7, minBoxFraction: 0, minBoxPt: 24, entryFrames: 3)
                && p.standard["FEMALE_BREAST_EXPOSED"] == d.standard["FEMALE_BREAST_EXPOSED"]
                && p.strict["BUTTOCKS_COVERED"] == TuningPolicy.ClassRule(threshold: 0.6, minBoxFraction: 0.001, minBoxPt: 0, entryFrames: 2)
                && p.coveredBeatsExposed && p.coveredOverlap == 0.8
                && p.curtain == TuningPolicy.CurtainRules(triggerHits: 5, windowSecs: 1.0, handoffHits: 3, paroleHits: 2, holdSecs: 2.5, holdCleanFrames: 20)
                && p.tracker == TuningPolicy.TrackerRules(clearAfterSecs: 1.0, stickyHoldSecs: 1.0, stickyConf: 0.9, matchIoU: 0.3),
            p.jsonString())
        check("tuning: {} over an override keeps it (layering is field by field)",
            (try? TuningPolicy.parse([:], base: p).get()) == p)
        // One `classes.FEMALE_BREAST_EXPOSED.thresholdSteps` config, so the
        // refusal rows below stay readable (and type-check fast).
        func stepCfg(_ steps: Any) -> [String: Any] {
            ["classes": ["FEMALE_BREAST_EXPOSED": ["thresholdSteps": steps]]]
        }
        let bad: [([String: Any], String)] = [
            (["treshold": 1], "unknown key \"treshold\""),
            (["classes": ["INJECT_TEST": ["threshold": 0.5]]], "unknown key \"classes.INJECT_TEST\""),
            (["classes": ["FACE_MALE": ["threshold": 0.5]]], "unknown key \"classes.FACE_MALE\""),
            (["classes": ["FEMALE_BREAST_EXPOSED": ["thresh": 0.5]]], "unknown key \"classes.FEMALE_BREAST_EXPOSED.thresh\""),
            (["classes": ["FEMALE_BREAST_EXPOSED": ["threshold": 1.5]]], "\"classes.FEMALE_BREAST_EXPOSED.threshold\" must be a number in 0.0...1.0"),
            (["classes": ["FEMALE_BREAST_EXPOSED": ["threshold": true]]], "\"classes.FEMALE_BREAST_EXPOSED.threshold\" must be a number"),
            (["classes": ["FEMALE_BREAST_EXPOSED": ["minBoxPt": 201]]], "\"classes.FEMALE_BREAST_EXPOSED.minBoxPt\" must be a number in 0.0...200.0"),
            (["classes": ["FEMALE_BREAST_EXPOSED": ["entryFrames": 0]]], "\"classes.FEMALE_BREAST_EXPOSED.entryFrames\" must be an integer in 1...10"),
            (["classes": ["FEMALE_BREAST_EXPOSED": ["entryFrames": 2.5]]], "\"classes.FEMALE_BREAST_EXPOSED.entryFrames\" must be an integer"),
            (["classes": ["FEMALE_BREAST_EXPOSED": 3]], "\"classes.FEMALE_BREAST_EXPOSED\" must be an object"),
            (["classes": []], "\"classes\" must be an object"),
            (["coveredBeatsExposed": 1], "\"coveredBeatsExposed\" must be true or false"),
            (["coveredOverlap": 0.4], "\"coveredOverlap\" must be a number in 0.5...1.0"),
            (["curtain": ["triggerHits": 31]], "\"curtain.triggerHits\" must be an integer in 1...30"),
            (["curtain": ["paroleHits": 4]], "\"curtain.paroleHits\" 4 must not exceed curtain.triggerHits 3"),
            (["curtain": ["handoffHits": 5, "triggerHits": 4]], "\"curtain.handoffHits\" 5 must not exceed curtain.triggerHits 4"),
            (["curtain": ["holdSecs": 61]], "\"curtain.holdSecs\" must be a number in 0.5...60.0"),
            (["curtain": ["holdCleanFrames": 601]], "\"curtain.holdCleanFrames\" must be an integer in 1...600"),
            (["tracker": ["matchIoU": 0.96]], "\"tracker.matchIoU\" must be a number in 0.05...0.95"),
            (["tracker": ["stickyHoldSecs": -1]], "\"tracker.stickyHoldSecs\" must be a number in 0.0...30.0"),
            // thresholdSteps: one row per tripwire (receipts in TuningPolicy.parse).
            (stepCfg([["mimPt": 64, "threshold": 0.9] as [String: Any]]),
                "unknown key \"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].mimPt\" (known: minPt, threshold)"),
            (stepCfg(64), "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps\" must be an array of {minPt, threshold} objects"),
            (stepCfg([64]), "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps\" must be an array of {minPt, threshold} objects"),
            (stepCfg([["minPt": 16, "threshold": 0.6], ["minPt": 32, "threshold": 0.7],
                      ["minPt": 48, "threshold": 0.8], ["minPt": 64, "threshold": 0.9],
                      ["minPt": 96, "threshold": 0.95]]),
                "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps\" has 5 entries, at most 4 (TuningPolicy.ClassRule.maxSteps)"),
            (stepCfg([["minPt": 0, "threshold": 0.9]]),
                "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].minPt\" must be a number in 1.0...2000.0"),
            (stepCfg([["minPt": 2001, "threshold": 0.9]]),
                "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].minPt\" must be a number in 1.0...2000.0"),
            (stepCfg([["minPt": 64, "threshold": 0.95], ["minPt": 32, "threshold": 0.97]]),
                "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[1].minPt\" 32 must be greater than [0].minPt 64 (steps must be in increasing order)"),
            (stepCfg([["minPt": 64, "threshold": 1.5]]),
                "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].threshold\" must be a number in 0.0...1.0"),
            (stepCfg([["minPt": 64, "threshold": true] as [String: Any]]),
                "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].threshold\" must be a number"),
            (stepCfg([["minPt": 64]]), "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].threshold\" is required"),
            (stepCfg([["threshold": 0.9]]), "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].minPt\" is required"),
            // Below the class's flat threshold (0.90 here): the flat floor is applied first, so the
            // step could never fire — refused by name, never accepted as a no-op.
            (stepCfg([["minPt": 64, "threshold": 0.8]]),
                "\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].threshold\" 0.80 is below the class threshold 0.90"),
        ]
        for (obj, why) in bad {
            switch TuningPolicy.parse(obj, base: d) {
            case .success: check("tuning: \(why) refused", false, "accepted \(obj)")
            case let .failure(e): check("tuning: refused by key — \(why)", e.text.hasPrefix(why), e.text)
            }
        }

        // Layering: raising `threshold` over an inherited step must not leave the step below it.
        do {
            let stepped = try! TuningPolicy.parse(stepCfg([["minPt": 64, "threshold": 0.9]]), base: d).get()
            let raised = TuningPolicy.parse(["classes": ["FEMALE_BREAST_EXPOSED": ["threshold": 0.95]]], base: stepped)
            var why = ""
            if case let .failure(e) = raised { why = e.text }
            check("tuning: a threshold raised above an inherited step is refused by name (a step can only raise the floor)",
                why.hasPrefix("\"classes.FEMALE_BREAST_EXPOSED.thresholdSteps[0].threshold\" 0.90 is below the class threshold 0.95"), why)
            let ok = TuningPolicy.parse(["classes": ["FEMALE_BREAST_EXPOSED": ["threshold": 0.9]]], base: stepped)
            check("tuning: … and one raised exactly to the step is accepted",
                (try? ok.get())?.standard["FEMALE_BREAST_EXPOSED"]?.threshold == 0.9, "\(ok)")
        }

        // --- 3. min box: drops a small box, keeps a large one, counted ---
        var floor = d
        floor.standard["FEMALE_BREAST_EXPOSED"]!.minBoxFraction = 0.001  // small is 0.0004, big 0.09
        let screen = CGSize(width: 1920, height: 1080)
        var f = floor.filter(
            [det("FEMALE_BREAST_EXPOSED", 0.9, small), det("FEMALE_BREAST_EXPOSED", 0.9, big),
             det("BUTTOCKS_EXPOSED", 0.9, small)],
            mode: .standard, blockFaces: false, screen: screen)
        check("tuning: minBoxFraction drops the small box of ITS class, keeps the large one and other classes, and counts",
            f.blocked.count == 2 && f.blocked.allSatisfy { $0.box != small || $0.label == "BUTTOCKS_EXPOSED" }
                && f.minBoxDropped == 1 && f.minBoxPtUnmeasured == 0 && f.demoted == 0,
            "\(f.blocked.map(\.label)) dropped=\(f.minBoxDropped)")
        check("tuning: at the default tuning nothing is dropped",
            d.filter([det("FEMALE_BREAST_EXPOSED", 0.9, small)], mode: .standard, blockFaces: false, screen: screen)
                .blocked.count == 1)
        var pt = d
        pt.standard["FEMALE_BREAST_EXPOSED"]!.minBoxPt = 24
        let thin = CGRect(x: 0.4, y: 0.4, width: 0.01, height: 0.1)  // 19.2 × 108 pt at 1920×1080
        f = pt.filter([det("FEMALE_BREAST_EXPOSED", 0.9, thin)], mode: .standard, blockFaces: false, screen: screen)
        check("tuning: minBoxPt keys on the SHORTER side in points (19 pt < 24 drops)",
            f.blocked.isEmpty && f.minBoxDropped == 1)
        f = pt.filter([det("FEMALE_BREAST_EXPOSED", 0.9, thin)], mode: .standard, blockFaces: false, screen: .zero)
        check("tuning: minBoxPt at an unknown (0×0) screen passes the box AND counts it unmeasured — never silent",
            f.blocked.count == 1 && f.minBoxPtUnmeasured == 1 && f.minBoxDropped == 0)
        check("tuning: with no point floor configured nothing is 'unmeasured' at 0×0",
            floor.filter([det("FEMALE_BREAST_EXPOSED", 0.9, big)], mode: .standard, blockFaces: false, screen: .zero)
                .minBoxPtUnmeasured == 0)
        check("tuning: a box under threshold is not counted as a size drop",
            floor.filter([det("FEMALE_BREAST_EXPOSED", 0.3, small)], mode: .standard, blockFaces: false, screen: screen)
                .minBoxDropped == 0)

        // --- 3b. threshold steps (ClassRule.thresholdSteps) ---
        // A screen of powers of two so `pt / 2048` and `pt / 1024` are exact
        // binary fractions: a box asked for 64.0 pt IS 64.0 pt on the shorter
        // side, which is what the boundary cases need.
        let stepScreen = CGSize(width: 2048, height: 1024)
        func sideBox(_ pt: Double, x: Double = 0.1, y: Double = 0.1) -> CGRect {
            CGRect(x: x, y: y, width: pt / 2048, height: pt / 1024)
        }
        func step(_ minPt: Double, _ t: Float) -> TuningPolicy.ClassRule.SizeStep {
            TuningPolicy.ClassRule.SizeStep(minPt: minPt, threshold: t)
        }
        check("tuning-steps: the defaults carry no staircase and do not print one (the dump rule)",
            d.standard.values.allSatisfy { $0.thresholdSteps.isEmpty }
                && d.strict.values.allSatisfy { $0.thresholdSteps.isEmpty }
                && !d.jsonString().contains("thresholdSteps"), d.jsonString())
        var one = d
        one.standard["FEMALE_BREAST_EXPOSED"]!.threshold = 0.8
        one.standard["FEMALE_BREAST_EXPOSED"]!.thresholdSteps = [step(64, 0.9)]
        f = one.filter([det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(40))],
            mode: .standard, blockFaces: false, screen: stepScreen)
        check("tuning-steps: below the first step the BASE threshold applies (40 pt, 0.85 ≥ 0.80 blocks)",
            f.blocked.count == 1 && f.stepDropped == 0 && f.stepUnmeasured == 0 && !f.stepEmptiedFrame)
        f = one.filter([det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(64))],
            mode: .standard, blockFaces: false, screen: stepScreen)
        check("tuning-steps: a box EXACTLY at minPt takes the higher bracket (64.0 pt, 0.85 < 0.90 drops)",
            f.blocked.isEmpty && f.stepDropped == 1 && f.stepEmptiedFrame)
        // Bracket lookup, not the shipped floor: an explicit 0.7 base so both
        // steps sit above it (`validateSteps`), as they did over the old 0.5.
        var two = d
        two.standard["FEMALE_BREAST_EXPOSED"]!.threshold = 0.7
        two.standard["FEMALE_BREAST_EXPOSED"]!.thresholdSteps = [step(48, 0.8), step(96, 0.9)]
        let fifty = two.filter([det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(50))],
            mode: .standard, blockFaces: false, screen: stepScreen)
        let hundred = two.filter([det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(100))],
            mode: .standard, blockFaces: false, screen: stepScreen)
        check("tuning-steps: the LAST matching step wins (50 pt → 0.80 blocks; 100 pt → 0.90 drops)",
            fifty.blocked.count == 1 && fifty.stepDropped == 0
                && hundred.blocked.isEmpty && hundred.stepDropped == 1,
            "50pt blocked=\(fifty.blocked.count) 100pt blocked=\(hundred.blocked.count)")
        f = one.filter([det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(100))],
            mode: .standard, blockFaces: false, screen: .zero)
        check("tuning-steps: an unmeasured (0×0) screen falls back to the base AND counts it — never silent",
            f.blocked.count == 1 && f.stepUnmeasured == 1 && f.stepDropped == 0 && !f.stepEmptiedFrame)
        f = one.filter([det("FEMALE_BREAST_EXPOSED", 0.3, sideBox(100))],
            mode: .standard, blockFaces: false, screen: stepScreen)
        check("tuning-steps: a box under the FLAT threshold is not counted as a step drop",
            f.blocked.isEmpty && f.stepDropped == 0 && f.stepUnmeasured == 0 && !f.stepEmptiedFrame)
        var both = one
        both.standard["FEMALE_BREAST_EXPOSED"]!.minBoxPt = 64
        f = both.filter([det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(40))],
            mode: .standard, blockFaces: false, screen: stepScreen)
        check("tuning-steps: a box the SIZE FLOOR removes counts minBoxDropped, not stepDropped (the filter's order)",
            f.blocked.isEmpty && f.minBoxDropped == 1 && f.stepDropped == 0 && !f.stepEmptiedFrame)
        f = one.filter(
            [det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(100)), det("BUTTOCKS_EXPOSED", 0.9, big)],
            mode: .standard, blockFaces: false, screen: stepScreen)
        check("tuning-steps: stepEmptiedFrame is false while another class still blocks (a box is not a frame)",
            f.blocked.count == 1 && f.stepDropped == 1 && !f.stepEmptiedFrame)
        var coveredSteps = d
        coveredSteps.strict["FEMALE_BREAST_COVERED"]!.thresholdSteps = [step(64, 0.9)]
        let coverBox = CGRect(x: 0.05, y: 0.05, width: 0.5, height: 0.5)
        let demotee = det("FEMALE_BREAST_EXPOSED", 0.85, sideBox(100, x: 0.1, y: 0.1))
        // The container itself clears the covered class's own step (0.95 ≥ 0.90),
        // so the only step drop in the frame is the demoted box.
        f = coveredSteps.filter([demotee, det("FEMALE_BREAST_COVERED", 0.95, coverBox)],
            mode: .strict, blockFaces: false, screen: stepScreen)
        check("tuning-steps: a demoted box is judged by the COVERED class's staircase (0.85 < 0.90 at 100 pt)",
            f.demoted == 1 && f.stepDropped == 1 && f.blocked.count == 1
                && f.blocked[0].label == "FEMALE_BREAST_COVERED" && f.blocked[0].box == coverBox,
            "\(f.blocked.map(\.label)) stepDropped=\(f.stepDropped)")
        var stepped = d
        stepped.standard["FEMALE_BREAST_EXPOSED"]!.threshold = 0.8
        stepped.standard["FEMALE_BREAST_EXPOSED"]!.thresholdSteps = [step(48, 0.8), step(96, 0.9)]
        var steppedObj = stepped.jsonObject
        var steppedClasses = steppedObj["classes"] as! [String: Any]
        steppedClasses.removeValue(forKey: "INJECT_TEST")
        steppedObj["classes"] = steppedClasses
        switch TuningPolicy.parse(steppedObj, base: d) {
        case let .success(back):
            check("tuning-steps: a policy WITH steps round-trips through jsonObject → parse",
                back == stepped, stepped.jsonString())
        case let .failure(e):
            check("tuning-steps: a policy WITH steps round-trips through jsonObject → parse", false, e.text)
        }
        // Order, not exact digits: JSONSerialization prints a Double at full
        // precision (`0.80000000000000004`), which is what the pre-staircase
        // fields already do.
        let dump = stepped.jsonString()
        let firstStep = dump.range(of: "\"thresholdSteps\":[{\"minPt\":48,")
        let secondStep = dump.range(of: "{\"minPt\":96,")
        check("tuning-steps: the dump prints the steps in order, only for the class that has them",
            firstStep != nil && secondStep != nil && firstStep!.lowerBound < secondStep!.lowerBound
                && dump.components(separatedBy: "thresholdSteps").count == 2, dump)
        let text = TuningPolicy.stepsText([step(48, 0.8), step(96, 0.9)])
        let parsedText = try? TuningPolicy.parseStepsText("48:0.8, 96:0.9", base: 0.5, at: "classes.X.").get()
        let emptyText = try? TuningPolicy.parseStepsText("  ", base: 0.5, at: "classes.X.").get()
        check("tuning-steps: stepsText / parseStepsText round-trip, empty text is no staircase",
            text == "48:0.80, 96:0.90" && parsedText == [step(48, 0.8), step(96, 0.9)]
                && emptyText == [] && TuningPolicy.stepsText([]).isEmpty, text)
        let badText: [(String, String)] = [
            ("64", "\"classes.X.thresholdSteps[0]\" must be \"minPt:threshold\""),
            ("64:", "\"classes.X.thresholdSteps[0]\" must be \"minPt:threshold\""),
            ("0:0.9", "\"classes.X.thresholdSteps[0].minPt\" must be a number in 1.0...2000.0"),
            ("64:0.9, 32:0.8", "\"classes.X.thresholdSteps[1].minPt\" 32 must be greater than [0].minPt 64"),
            ("16:0.6, 32:0.7, 48:0.8, 64:0.9, 96:0.95", "\"classes.X.thresholdSteps\" has 5 entries, at most 4"),
            // Empty pieces are refused by index, never dropped or read as "clear".
            ("64:0.9,", "\"classes.X.thresholdSteps[1]\" must be \"minPt:threshold\""),
            (",", "\"classes.X.thresholdSteps[0]\" must be \"minPt:threshold\""),
            ("48:0.8,,96:0.9", "\"classes.X.thresholdSteps[1]\" must be \"minPt:threshold\""),
            // A step below the base could never fire (the flat floor is applied first): refused, not a no-op.
            ("64:0.4", "\"classes.X.thresholdSteps[0].threshold\" 0.40 is below the class threshold 0.50"),
        ]
        for (t, why) in badText {
            switch TuningPolicy.parseStepsText(t, base: 0.5, at: "classes.X.") {
            case .success: check("tuning-steps: \"\(t)\" refused", false, "accepted")
            case let .failure(e): check("tuning-steps: field text refused by name — \(why)", e.text.hasPrefix(why), e.text)
            }
        }

        // --- 4. covered-beats-exposed: same part only, mostly inside, raw list ---
        var cbe = d
        cbe.coveredBeatsExposed = true
        // Binary-exact coordinates so "half inside" is exactly 0.5.
        let coveredBox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let inside = CGRect(x: 0.375, y: 0.375, width: 0.125, height: 0.125)  // fully inside
        let straddle = CGRect(x: 0.5, y: 0.375, width: 0.5, height: 0.125)  // half inside
        let exposed = det("FEMALE_BREAST_EXPOSED", 0.9, inside)
        let covered = det("FEMALE_BREAST_COVERED", 0.4, coveredBox)  // below the strict floor, still a covered box
        f = cbe.filter([exposed, covered], mode: .standard, blockFaces: false, screen: screen)
        check("tuning: an exposed box mostly inside a covered box of the same part is demoted (standard: nothing blocks)",
            f.blocked.isEmpty && f.demoted == 1 && f.minBoxDropped == 0, "\(f.blocked.map(\.label))")
        f = cbe.filter([exposed, covered], mode: .strict, blockFaces: false, screen: screen)
        check("tuning: … and under strict the demoted box blocks as COVERED at the covered floor",
            f.blocked.count == 1 && f.blocked[0].label == "FEMALE_BREAST_COVERED" && f.blocked[0].box == inside
                && f.blocked[0].confidence == 0.9 && f.demoted == 1, "\(f.blocked.map(\.label))")
        f = cbe.filter([det("FEMALE_BREAST_EXPOSED", 0.55, inside), covered], mode: .strict, blockFaces: false, screen: screen)
        check("tuning: … so a demoted 0.55 box no longer blocks under strict either (covered floor 0.6)",
            f.blocked.isEmpty && f.demoted == 1)
        f = cbe.filter([exposed, det("BUTTOCKS_COVERED", 0.9, coveredBox)], mode: .standard, blockFaces: false, screen: screen)
        check("tuning: a covered box of ANOTHER part does not demote",
            f.blocked.count == 1 && f.blocked[0].label == "FEMALE_BREAST_EXPOSED" && f.demoted == 0)
        f = cbe.filter([det("MALE_GENITALIA_EXPOSED", 0.9, inside), det("FEMALE_GENITALIA_COVERED", 0.9, coveredBox)],
            mode: .standard, blockFaces: false, screen: screen)
        check("tuning: MALE_GENITALIA_EXPOSED has no covered pair and is never demoted",
            f.blocked.count == 1 && f.demoted == 0)
        f = cbe.filter([det("FEMALE_BREAST_EXPOSED", 0.9, straddle), covered], mode: .standard, blockFaces: false, screen: screen)
        check("tuning: a box only half inside (0.5 < coveredOverlap 0.9) is not demoted",
            f.blocked.count == 1 && f.demoted == 0)
        cbe.coveredOverlap = 0.5
        f = cbe.filter([det("FEMALE_BREAST_EXPOSED", 0.9, straddle), covered], mode: .standard, blockFaces: false, screen: screen)
        check("tuning: coveredOverlap 0.5 takes the half-inside box",
            f.blocked.isEmpty && f.demoted == 1)
        f = d.filter([exposed, covered], mode: .standard, blockFaces: false, screen: screen)
        check("tuning: on by default — the same frame demotes the exposed box",
            f.blocked.isEmpty && f.demoted == 1)
        var off = d
        off.coveredBeatsExposed = false
        f = off.filter([exposed, covered], mode: .standard, blockFaces: false, screen: screen)
        check("tuning: switched off, the same frame blocks the exposed box",
            f.blocked.count == 1 && f.blocked[0].label == "FEMALE_BREAST_EXPOSED" && f.demoted == 0)
        check("tuning: overlapOfSmaller — inside 1.0, disjoint 0, half 0.5",
            TuningPolicy.overlapOfSmaller(inside, coveredBox) == 1
                && TuningPolicy.overlapOfSmaller(small, CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1)) == 0
                && abs(TuningPolicy.overlapOfSmaller(straddle, coveredBox) - 0.5) < 1e-9)

        // --- 5. Tracker reads the struct per frame ---
        let t = Tracker(clearAfter: Tracker.defaultClearAfter(fps: 30), stickyHold: Tracker.defaultStickyHold(fps: 30))
        check("tuning: Tracker starts at the defaults (clearAfter 12, stickyHold 30 at 30 fps)",
            t.clearAfter == 12 && t.stickyHold == 30 && t.tuning == d)
        var slow = d
        slow.tracker.clearAfterSecs = 1.0
        slow.tracker.stickyHoldSecs = 0.2
        t.setTuning(slow, fps: 30)
        check("tuning: setTuning re-derives clearAfter (1.0 s → 30) and keeps stickyHold ≥ clearAfter",
            t.clearAfter == 30 && t.stickyHold == 30, "clearAfter=\(t.clearAfter) sticky=\(t.stickyHold)")
        t.setTuning(slow, fps: 30, clearAfterOverride: 4)
        check("tuning: --clear-frames still pins clearAfter", t.clearAfter == 4 && t.stickyHold == 20)
        t.setTuning(d, fps: 15)
        check("tuning: the frame floors still apply below 20 fps (8 / 20)", t.clearAfter == 8 && t.stickyHold == 20)
        // Hysteresis really changes on the next frame: with clearAfterSecs 1.0
        // a region survives 29 clean frames; at the default it dies at 12.
        func survives(_ policy: TuningPolicy, clean: Int) -> Bool {
            let tr = Tracker(clearAfter: 12, stickyHold: 30)
            tr.setTuning(policy, fps: 30)
            _ = tr.update(detections: [det("FEMALE_BREAST_EXPOSED", 0.5, big)])  // peak 0.5 < stickyConf
            for _ in 0..<clean { _ = tr.update(detections: []) }
            return !tr.update(detections: []).isEmpty
        }
        check("tuning: clearAfterSecs 1.0 holds a region through 28 clean frames; the default drops it at 12",
            survives(slow, clean: 28) && !survives(d, clean: 12) && survives(d, clean: 10))
        // stickyConf invariant (restated 2026-10-20, decision at
        // `TrackerRules.stickyConf`): no shipped floor sits below it, so a
        // region born from any box the defaults block gets the sticky hold;
        // a region under it still clears at clearAfter. Fed through the real
        // policy filter, so the region is exactly what the pipeline would birth.
        check("tuning: stickyConf — every shipped block floor is at or above stickyConf 0.6",
            TuningPolicy.exposedLabels.allSatisfy { d.standard[$0]!.threshold >= d.tracker.stickyConf }
                && TuningPolicy.coveredLabels.allSatisfy { d.strict[$0]!.threshold >= d.tracker.stickyConf })
        func holdsThrough(_ box: Detection, mode: PolicyMode, faces: Bool, clean: Int) -> Bool? {
            let blocked = d.filter([box], mode: mode, blockFaces: faces, screen: .zero).blocked
            guard blocked.count == 1 else { return nil }  // the policy must block it for the test to mean anything
            let tr = Tracker(clearAfter: 12, stickyHold: 30)
            tr.setTuning(d, fps: 30)
            _ = tr.update(detections: blocked)
            for _ in 0..<clean { _ = tr.update(detections: []) }
            return !tr.update(detections: []).isEmpty
        }
        let lowest: [(Detection, PolicyMode)] = TuningPolicy.exposedLabels.map { (det($0, d.standard[$0]!.threshold, big), .standard) }
            + TuningPolicy.coveredLabels.map { (det($0, d.strict[$0]!.threshold, big), .strict) }
        let sticky = lowest.map { holdsThrough($0.0, mode: $0.1, faces: false, clean: 28) }
        check("tuning: stickyConf — a region born AT each shipped floor holds the sticky 1.0 s (28 clean frames at 30 fps)",
            sticky.allSatisfy { $0 == true }, "\(sticky)")
        let face = holdsThrough(det("FACE_FEMALE", 0.3, big), mode: .standard, faces: true, clean: 12)
        check("tuning: stickyConf — a blocked region whose peak is under it (--block-faces 0.30) still clears at clearAfter (12)",
            face == false, "\(String(describing: face))")
        var perClass = d
        perClass.standard["FEMALE_BREAST_EXPOSED"]!.entryFrames = 3
        let ct = Tracker(clearAfter: 12, stickyHold: 30)
        ct.curtainEntry = true
        ct.setTuning(perClass, fps: 30)
        let fbe = det("FEMALE_BREAST_EXPOSED", 0.9, big)
        let be = det("BUTTOCKS_EXPOSED", 0.9, CGRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1))
        let first = ct.update(detections: [fbe, be])
        let second = ct.update(detections: [fbe, be])
        let third = ct.update(detections: [fbe, be])
        check("tuning: per-class entryFrames — BUTTOCKS_EXPOSED (2) births on frame 2, FEMALE_BREAST_EXPOSED (3) on frame 3",
            first.isEmpty && second.count == 1 && third.count == 2, "\(first.count)/\(second.count)/\(third.count)")
        let rt = Tracker(clearAfter: 12, stickyHold: 30)
        rt.setTuning(perClass, fps: 30)
        check("tuning: outside curtain mode entryFrames is 1 whatever the class says",
            rt.update(detections: [fbe]).count == 1)

        // --- 6. Curtain reads the struct: triggerHits 5 ---
        do {
            let screenRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let win = CGRect(x: 543, y: 213, width: 1172, height: 626)
            let rows: [[String: Any]] = [[
                "kCGWindowNumber": CGWindowID(6320), "kCGWindowOwnerName": "Google Chrome",
                "kCGWindowLayer": 0, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": pid_t(1),
                "kCGWindowBounds": ["X": win.minX, "Y": win.minY, "Width": win.width, "Height": win.height],
            ]]
            let windowTracker = WindowTracker()
            windowTracker.windowSource = { rows }
            windowTracker.screenFrame = screenRect
            windowTracker.onReceipt = { _ in }
            windowTracker.start()
            Thread.sleep(forTimeInterval: 0.1)
            let curtain = Curtain()
            var five = d
            five.curtain.triggerHits = 5
            curtain.tuning = five
            var events: [(String, CGWindowID)] = []
            curtain.onChange = { events.append(($0, $1)) }
            var now = CFAbsoluteTimeGetCurrent()
            let hit = CGRect(x: 900, y: 500, width: 120, height: 90)
            func step(_ n: Int) {
                for _ in 0..<n {
                    now += 1.0 / 30
                    _ = curtain.update(blockedScreenRects: [hit], tracker: windowTracker, display: screenRect, at: now)
                    windowTracker.setTracked(curtain.watchIDs)
                }
            }
            step(4)
            let noneAt4 = !events.contains { $0.0.hasPrefix("drop") }
            step(3)
            let dropped = events.contains { $0.0.hasPrefix("drop") && $0.1 == 6320 }
            check("tuning: Curtain honours triggerHits 5 — no drop after 4 hits, a drop after 7 (the default drops at 3)",
                noneAt4 && dropped, "events=\(events)")
            windowTracker.stop()
        }

        // --- 7. the tuning file: accept / reject / hot-reload signature ---
        let root = dir + "/state"
        try! FileManager.default.createDirectory(atPath: root + "/parent", withIntermediateDirectories: true)
        let filePath = root + "/parent/tuning.json"
        func write(_ text: String) { try! text.write(toFile: filePath, atomically: false, encoding: .utf8) }
        check("tuning-file: absent ⇒ .absent, nil signature",
            TuningFile.read(stateRoot: root, base: d) == .absent && TuningFile.signature(stateRoot: root) == nil)
        let badFiles: [(String, String)] = [
            ("{not json", "not a JSON object"),
            ("{\"tuning\":{}}", "version must be 1"),
            ("{\"version\":true,\"tuning\":{}}", "version must be 1"),
            ("{\"version\":1}", "\"tuning\" must be an object"),
            ("{\"version\":1,\"tuning\":{},\"extra\":1}", "unknown key \"extra\""),
            ("{\"version\":1,\"tuning\":{\"curtain\":{\"triggerHits\":0}}}", "\"curtain.triggerHits\" must be an integer in 1...30"),
        ]
        for (text, why) in badFiles {
            write(text)
            let got = TuningFile.read(stateRoot: root, base: d)
            check("tuning-file: \(text.prefix(40)) ⇒ refused by name (\(why))",
                got == .refused("\(filePath): \(why)") || {
                    if case let .refused(s) = got { return s.hasPrefix("\(filePath): \(why)") }
                    return false
                }(), "\(got)")
        }
        write("{\"version\":1,\"tuning\":{\"curtain\":{\"triggerHits\":4},\"coveredBeatsExposed\":true}}")
        var expected = p  // layered over the config-derived policy `p`, not the defaults
        expected.curtain.triggerHits = 4
        check("tuning-file: a valid file layers over the config policy",
            TuningFile.read(stateRoot: root, base: p) == .loaded(expected))
        let sig1 = TuningFile.signature(stateRoot: root)
        check("tuning-file: an unchanged file has the same (ino, mtime, size) signature",
            sig1 != nil && TuningFile.sameSignature(sig1, TuningFile.signature(stateRoot: root)))
        Thread.sleep(forTimeInterval: 0.02)
        write("{\"version\":1,\"tuning\":{\"curtain\":{\"triggerHits\":6},\"coveredBeatsExposed\":true}}")
        check("tuning-file: a rewrite changes the signature (the 1 Hz poll's reload trigger)",
            !TuningFile.sameSignature(sig1, TuningFile.signature(stateRoot: root)))

        // End to end through the binary: `--print-tuning` with the state root
        // pointed at a directory that carries a tuning.json. A build
        // lists the file as a source; a production build MUST NOT — it has
        // no reader (the flavor test proves the symbol is absent; this proves
        // the behaviour).
        write("{\"version\":1,\"tuning\":{\"curtain\":{\"triggerHits\":6}}}")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        proc.arguments = ["--print-tuning"]
        var env = ProcessInfo.processInfo.environment
        env["SENTRY_STATE_DIR"] = root
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        var printed: [String: Any] = [:]
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            printed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            check("tuning: --print-tuning exits 0 with a JSON object", proc.terminationStatus == 0 && !printed.isEmpty)
        } catch {
            check("tuning: --print-tuning runs", false, "\(error)")
        }
        let sources = printed["sources"] as? [String] ?? []
        let hits = ((printed["curtain"] as? [String: Any])?["triggerHits"] as? Int) ?? -1
        check("tuning: --print-tuning layers parent/tuning.json (sources, triggerHits 6)",
            sources == ["defaults", "parent/tuning.json"] && hits == 6, "sources=\(sources) hits=\(hits)")
    }
}
