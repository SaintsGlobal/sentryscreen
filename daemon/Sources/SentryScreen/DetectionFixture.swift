import CoreGraphics
import Foundation

// DETECTION VIEW synthetic source (tuning tool). A fixed, deterministic set
// of detections appended to the detector's output (beside the INJECT_TEST
// hotkey box) while `Pipeline.setSyntheticDetections` is on, so the view can
// be exercised with no real detectable content on screen. The boxes are
// chosen so that, under the default tuning and the standard policy, each one
// reaches a different decision. They are real pipeline input: they cover,
// log in run.jsonl and can drop a curtain (owner decision D3, 2026-09-24;
// bracketed by `detection-view` lifecycle records). A crop writer refuses to
// run beside them (`setSyntheticDetections`).

final class DetectionFixture {
    enum Pattern {
        /// One box per decision (the table below).
        case standard
        /// Exactly `DetectionTraceBuilder.maxBoxes + 5` boxes, all below the
        /// threshold (no cover, no curtain): exercises the overflow count.
        case stress
    }

    /// One fixture box: class, raw score, centre (normalized, TOP-LEFT, so
    /// the table reads like the screen) and short side in screen points.
    struct Spec: Equatable {
        let label: String
        let confidence: Float
        let centre: CGPoint
        let sidePt: Double
        /// Present only on evaluated frames where `frame % 2 == 0`.
        let everyOtherFrame: Bool
    }

    /// Default tuning, standard policy — what each box reaches (scores
    /// raised 2026-10-20 with the shipped floors, FBE 0.90 / BE 0.80, so
    /// boxes 1, 4 and 7 still pass):
    ///  1. FEMALE_BREAST_EXPOSED 0.93, 140 pt: passes → region cover (after
    ///     entryFrames in curtain mode) and curtain hits on the window under it.
    ///  2. MALE_GENITALIA_EXPOSED 0.41: below the 0.90 threshold.
    ///  3. FEMALE_BREAST_COVERED 0.72, 200 pt, with FEMALE_BREAST_EXPOSED 0.88
    ///     100 pt fully inside it: the exposed box is demoted (overlap 1.00 ≥
    ///     coveredOverlap 0.90) and, like the covered box, is a class the
    ///     standard policy does not block.
    ///  4. BUTTOCKS_EXPOSED 0.85 on every other evaluated frame: never two
    ///     consecutive sightings, so in curtain mode it sits at entry 1/2.
    ///  5. ANUS_EXPOSED 0.90, 16 pt: passes at the defaults; reaches the size
    ///     floor once `minBoxPt` > 16 (or a staircase step) is set.
    ///  6. FACE_FEMALE 0.90: not a policy class (hidden by default).
    ///  7. FEMALE_BREAST_EXPOSED 0.92, 100 pt, in the top-right corner below
    ///     the menu bar — usually bare desktop, so the walk finds no window
    ///     (orphan). Whatever is really there is what the trace reports.
    static let standard: [Spec] = [
        Spec(label: "FEMALE_BREAST_EXPOSED", confidence: 0.93, centre: CGPoint(x: 0.30, y: 0.40), sidePt: 140, everyOtherFrame: false),
        Spec(label: "MALE_GENITALIA_EXPOSED", confidence: 0.41, centre: CGPoint(x: 0.50, y: 0.40), sidePt: 120, everyOtherFrame: false),
        Spec(label: "FEMALE_BREAST_COVERED", confidence: 0.72, centre: CGPoint(x: 0.70, y: 0.40), sidePt: 200, everyOtherFrame: false),
        Spec(label: "FEMALE_BREAST_EXPOSED", confidence: 0.88, centre: CGPoint(x: 0.70, y: 0.40), sidePt: 100, everyOtherFrame: false),
        Spec(label: "BUTTOCKS_EXPOSED", confidence: 0.85, centre: CGPoint(x: 0.30, y: 0.70), sidePt: 120, everyOtherFrame: true),
        Spec(label: "ANUS_EXPOSED", confidence: 0.90, centre: CGPoint(x: 0.50, y: 0.70), sidePt: 16, everyOtherFrame: false),
        Spec(label: "FACE_FEMALE", confidence: 0.90, centre: CGPoint(x: 0.70, y: 0.70), sidePt: 120, everyOtherFrame: false),
        Spec(label: "FEMALE_BREAST_EXPOSED", confidence: 0.92, centre: CGPoint(x: 0.96, y: 0.10), sidePt: 100, everyOtherFrame: false),
    ]

    /// Point sizes need a screen; a 0×0 screen (unmeasured display) sizes
    /// the boxes against this one instead. DERIVED: the owner's displays are
    /// 1920×1080 pt (the size every tuning receipt in TuningPolicy.swift is
    /// measured on).
    static let fallbackScreen = CGSize(width: 1920, height: 1080)

    /// Evaluated frames since the source was turned on. detectQueue only.
    private(set) var frame = 0

    func reset() { frame = 0 }

    /// This evaluated frame's boxes; advances the frame counter.
    func next(screen: CGSize, pattern: Pattern = .standard) -> [Detection] {
        defer { frame += 1 }
        return Self.detections(frame: frame, screen: screen, pattern: pattern)
    }

    static func detections(frame: Int, screen: CGSize, pattern: Pattern) -> [Detection] {
        let s = screen.width > 0 && screen.height > 0 ? screen : fallbackScreen
        switch pattern {
        case .standard:
            return standard
                .filter { !$0.everyOtherFrame || frame % 2 == 0 }
                .map { detection($0.label, $0.confidence, centre: $0.centre, sidePt: $0.sidePt, screen: s) }
        case .stress:
            // A 10-column grid of 40 pt boxes at 0.20 (below every
            // threshold), exactly maxBoxes + 5 of them.
            let count = DetectionTraceBuilder.maxBoxes + 5
            let columns = 10
            let rows = (count + columns - 1) / columns
            return (0..<count).map { i in
                let centre = CGPoint(
                    x: (Double(i % columns) + 0.5) / Double(columns),
                    y: (Double(i / columns) + 0.5) / Double(rows))
                return detection("FEMALE_BREAST_EXPOSED", 0.20, centre: centre, sidePt: 40, screen: s)
            }
        }
    }

    /// A square box of `sidePt` points centred at a top-left normalized
    /// point, as a Vision (bottom-left) normalized `Detection`.
    static func detection(
        _ label: String, _ confidence: Float, centre: CGPoint, sidePt: Double, screen: CGSize
    ) -> Detection {
        let w = CGFloat(sidePt) / screen.width
        let h = CGFloat(sidePt) / screen.height
        return Detection(
            label: label, confidence: confidence,
            box: CGRect(x: centre.x - w / 2, y: 1 - (centre.y + h / 2), width: w, height: h))
    }
}

