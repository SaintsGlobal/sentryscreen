import CoreGraphics
import Foundation

/// Rectangle arithmetic both cover pipelines use, owned by neither.
///
/// WHY THIS FILE EXISTS (2026-09-11). `merge` and `iou` lived on
/// `Tracker` — the REGION pipeline's state machine — and `Curtain` called them
/// statically. The coupling was one-way and harmless, but it meant the two
/// deliberately separate cover pipelines (.github/CONTRIBUTING.md, "Keep
/// curtain and region separate") shared a type, and the next person to add state or a
/// tuning read to `Tracker` would not see that the curtain was reaching into
/// it. These two functions are pure geometry with no pipeline in them, so they
/// moved here rather than being duplicated. A pure move: the bodies are byte
/// identical to what `Tracker` shipped.
enum Geometry {
    /// Union boxes that overlap with IoU above the limit (SPEC §5.3).
    /// Two callers, both verified 2026-09-11: `Curtain.update`'s
    /// one-evidence-per-window merge, and `--ui-selftest`, which cross-checks
    /// `Curtain.mergeAttributed` — the payload-carrying twin — against this
    /// function on random inputs. The first version of this list named two that
    /// do not call it: `Tracker.mergeDetections` calls `iou`, not this, and
    /// main.swift's coverage tripwire has used `paintedArea`/`paintedCoverage`,
    /// a slab sweep, since 2026-09-08.
    /// `iou` below has the wider caller set (`Tracker`, `MotionBoxes`,
    /// `Curtain`) — deliberately not listed, it would rot the same way.
    static func merge(_ boxes: [CGRect], iouOver: CGFloat) -> [CGRect] {
        var merged = boxes
        var changed = true
        while changed {
            changed = false
            outer: for i in merged.indices {
                for j in merged.indices where j > i {
                    if iou(merged[i], merged[j]) > iouOver {
                        merged[i] = merged[i].union(merged[j])
                        merged.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return merged
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
