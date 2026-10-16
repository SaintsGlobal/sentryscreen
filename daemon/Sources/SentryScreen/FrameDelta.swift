import CoreVideo
import Foundation

/// Measured changed-area fraction between consecutive delivered frames, for
/// Pipeline's idle-frame gate (receipt at Pipeline.idleDirtyFraction).
///
/// Why not SCK's `dirtyRects`: MEASURED 2026-08-25 (live, an M1 Mac, a
/// terminal window streaming text): the attachment is one rect per frame at
/// WINDOW granularity — dirtyPct p50 = p90 = 68% for the whole run, i.e. the
/// terminal's bounds, while the pixels that actually changed were a cursor
/// and a spinner. A gate keyed on it never closed (8 skips in 966 frames).
///
/// Method: the green channel is sampled on a `stride`-pixel grid (160
/// columns at the 1280-wide default — the same grid MotionBoxes uses for
/// media detection, SPEC §5 "cover mode") and compared to the previous
/// frame's samples; a sample whose value moved by more than `threshold`
/// (MotionBoxes' own >12 "cell is hot" bar) counts as changed. Cost is one
/// byte read per sample, ~14k samples per 1280x720 frame: well under 0.1 ms
/// against a 17 ms inference, no allocation after the first frame.
///
/// 1.0 (everything changed) on the first frame, on any size/format change,
/// and on a non-BGRA buffer — unknown must read as "run the detector".
struct FrameDelta {
    /// Grid pitch: max(1, width/160) — the SAME rule as MotionBoxes
    /// (gridWidth = 160), not a fixed 8: the old constant matched MotionBoxes
    /// only at the 1280-wide default and silently diverged under --width
    /// (review 2026-08-25). 8 at 1280 — behavior unchanged at the default.
    static func stride(forWidth width: Int) -> Int { max(1, width / 160) }
    static let threshold = 12
    private var previous: [UInt8] = []
    private var shape: (Int, Int) = (0, 0)

    mutating func changedFraction(_ buffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return 1 }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 1 }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let stride = Self.stride(forWidth: width)
        let cols = width / stride, rows = height / stride
        let n = cols * rows
        guard n > 0 else { return 1 }
        var changed = 0
        let fresh = shape != (cols, rows) || previous.count != n
        if fresh { previous = [UInt8](repeating: 0, count: n); shape = (cols, rows) }
        var i = 0
        for r in 0..<rows {
            let row = src + r * stride * bpr + 1  // +1: G of BGRA
            for c in 0..<cols {
                let g = row[c * stride * 4]
                if abs(Int(g) - Int(previous[i])) > Self.threshold { changed += 1 }
                previous[i] = g
                i += 1
            }
        }
        return fresh ? 1 : Double(changed) / Double(n)
    }
}

/// SETTLE: the screen went still after motion — the frame the settle
/// re-check runs on (`TuningPolicy.settleRecheck`, `Pipeline.settleShiftPx`).
/// Fed every delivered frame's `FrameDelta` fraction, gated or not.
///
/// A settle is `stillFrames` consecutive frames under the idle gate's own
/// `Pipeline.idleDirtyFraction` after at least one frame at or above it.
/// `stillFrames` is the gate's `idleDetectEvery`, so on a gated desktop the
/// frame that completes the run is exactly the frame the gate evaluates
/// (the first two still frames are skipped, the third runs), and the
/// re-check adds work only to a frame that was running anyway. Requiring a
/// RUN of still frames, not one, is what keeps content that alternates
/// changed/unchanged frames (a 15 fps video in a 30 fps stream) from reading
/// as a settle every other frame. One re-check per settle: `take` clears it,
/// and motion before it is taken cancels it.
struct SettleWatch {
    private var sawMotion = false
    private var stillStreak = 0
    private(set) var pending = false

    mutating func observe(changed: Double, threshold: Double, stillFrames: Int) {
        if changed >= threshold {
            sawMotion = true
            stillStreak = 0
            pending = false
            return
        }
        stillStreak += 1
        if sawMotion, stillStreak >= stillFrames {
            pending = true
            sawMotion = false
        }
    }

    /// True once per settle, on the first evaluated frame that asks.
    mutating func take() -> Bool {
        defer { pending = false }
        return pending
    }
}
