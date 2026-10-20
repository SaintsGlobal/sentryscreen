import CoreGraphics
import Foundation

/// TUNING TOOL — the zoom (tiling) prototype, behind the Developer tab's
/// `zoomTiles` toggle (tuning.json `"zoomTiles": true`, off by default; a
/// production build has no field, no parser key and none of this file).
///
/// The detector sees the whole capture `.scaleFill`-ed to 640 × 640, so
/// small content on a 1280 × 720 frame gets few model pixels. With the
/// toggle on, `Pipeline.step` runs the full frame EVERY frame as before, plus
/// ONE tile of a 2 × 2 grid per frame in rotation (four frames cover the
/// screen), as a second request on the full pass's Vision handler
/// (`Detector.detect(tile:)`). The tile's boxes that a tile seam cut are dropped, the rest join
/// the full-frame boxes, and a per-class greedy NMS keeps the highest score.
/// Region and curtain pipelines see the merged list unchanged in shape.
///
/// Port of the tiling experiment's arm B.
/// Offline, v8 on captures, eval v10:
/// explicit boxes found 107 → 162 (+55 [+31, +82]), false alarms +2 [−2, +6];
/// the owner judged 71 of the 74 tile "false alarms" real (2026-10-07).
enum ZoomTiles {
    /// Tiles per axis. RECEIPT: the experiment's arm B (2 × 2) is the arm the owner
    /// approved; a 674 × 379 px tile on 1280 × 720 is 1.9× zoom per axis.
    /// Arm C (3 × 3) found more but costs a tile re-check every 9 frames
    /// (300 ms) instead of 4 (133 ms) at the same per-frame cost.
    static let grid = 2
    static var count: Int { grid * grid }

    /// Fraction of a tile shared with its neighbour. RECEIPT: the experiment's
    /// `OVERLAP = 0.1` (the brief's "about 10 %"), the value every tiling
    /// number was measured with. A box narrower than ≈ 9 % of a tile
    /// lies whole inside a neighbour; larger boxes are the full pass's job.
    static let overlap = 0.1

    /// A tile box within this fraction of the tile of an INTERIOR tile edge
    /// (not the frame edge) is treated as cut by the seam and dropped.
    /// RECEIPT: the experiment's `EDGE_MARGIN = 0.01` (≈ 6 model px), ASSUMED there and
    /// checked by its no-drop `B_keep` arm; ported unchanged so the daemon
    /// runs the measured rule.
    static let edgeMargin: CGFloat = 0.01

    /// Same-class IoU at which two boxes are one box; the higher score
    /// survives. RECEIPT: the experiment merges at the eval's matching IoU (0.5,
    /// `evaluate.IOU_MATCH`); the same 0.5 as `Pipeline.settleMatchIoU`.
    static let mergeIoU: CGFloat = 0.5

    /// Tile `index` (row-major from the TOP left: 0 top-left, 1 top-right,
    /// 2 bottom-left, 3 bottom-right) of a `width` × `height` frame, as a
    /// Vision region of interest (bottom-left normalized). Pixel spans are
    /// The experiment's tile_probe.swift `tiles()`: tile t = L / (1 + (n − 1)(1 −
    /// overlap)), step t (1 − overlap), rounded to whole pixels, the last
    /// tile ends at the edge.
    static func region(index: Int, width: Int, height: Int) -> CGRect {
        func span(_ L: Int, _ i: Int) -> (Int, Int) {
            let t = Double(L) / (1 + Double(grid - 1) * (1 - overlap)), s = t * (1 - overlap)
            let a = Int((Double(i) * s).rounded())
            return (a, i == grid - 1 ? L : min(L, Int((Double(i) * s + t).rounded())))
        }
        let (x0, x1) = span(width, index % grid)
        let (y0, y1) = span(height, index / grid)  // top-left origin
        let W = CGFloat(width), H = CGFloat(height)
        return CGRect(x: CGFloat(x0) / W, y: 1 - CGFloat(y1) / H,
            width: CGFloat(x1 - x0) / W, height: CGFloat(y1 - y0) / H)
    }

    /// The tile after `index` in the rotation: one tile per evaluated frame,
    /// every tile once per `count` frames. RECEIPT: the owner-approved shape
    /// (2026-10-07). The experiment's "Time" (offline estimate): B every frame is 5
    /// passes, one tile per frame is 2. MEASURED in the daemon:
    /// the
    /// detect call with the toggle on costs 1.59–1.67× the toggle-off cost at
    /// p50 (13.0–13.5 ms against 8.1–8.2 ms), under the 2-pass budget.
    static func next(after index: Int) -> Int { (index + 1) % count }

    /// The experiment's `cut`: `box` (frame coordinates, bottom-left normalized) has
    /// an edge within `edgeMargin` of an interior edge of `tile`. The test is
    /// symmetric in y, so Vision's flipped axis reads the same as the probe's.
    static func isCut(_ box: CGRect, tile: CGRect) -> Bool {
        let eps: CGFloat = 1e-6
        let b = CGRect(x: (box.minX - tile.minX) / tile.width, y: (box.minY - tile.minY) / tile.height,
            width: box.width / tile.width, height: box.height / tile.height)
        return (tile.minX > eps && b.minX < edgeMargin)
            || (tile.minY > eps && b.minY < edgeMargin)
            || (tile.maxX < 1 - eps && b.maxX > 1 - edgeMargin)
            || (tile.maxY < 1 - eps && b.maxY > 1 - edgeMargin)
    }

    /// The experiment's `arm_dets`: drop the cut tile boxes, mark the rest with
    /// `tileIndex`, then per-class greedy NMS over full + tile boxes at
    /// `mergeIoU`, highest score first (a tie keeps the full-frame box).
    static func merge(full: [Detection], tile: [Detection], tileIndex: Int, region: CGRect)
        -> (merged: [Detection], dropped: Int)
    {
        var candidates = full
        var dropped = 0
        for var d in tile {
            if isCut(d.box, tile: region) { dropped += 1; continue }
            d.tile = tileIndex
            candidates.append(d)
        }
        let order = candidates.indices.sorted {
            candidates[$0].confidence != candidates[$1].confidence
                ? candidates[$0].confidence > candidates[$1].confidence : $0 < $1
        }
        var out: [Detection] = []
        for i in order {
            let d = candidates[i]
            if out.allSatisfy({ $0.label != d.label || Geometry.iou($0.box, d.box) < mergeIoU }) {
                out.append(d)
            }
        }
        return (out, dropped)
    }

    /// What the Developer tab's Tiles row draws for one tile pass
    /// (`ZoomTilesMonitor`): every tile box the seam rule kept, in frame
    /// coordinates (top-left, the way the row draws), each marked
    /// `tileOnly` when the full-frame pass has no same-class box at
    /// `mergeIoU` — the boxes the zoom found and the full pass missed, by the
    /// same rule `merge` uses to call two boxes one. Labels and numbers only.
    static func passView(
        full: [Detection], tile: [Detection], index: Int, region: CGRect, at: CFAbsoluteTime
    ) -> ZoomTilePass {
        func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
        var cut = 0
        var boxes: [ZoomTilePass.Box] = []
        for d in tile {
            if isCut(d.box, tile: region) { cut += 1; continue }
            let seen = full.contains { $0.label == d.label && Geometry.iou($0.box, d.box) >= mergeIoU }
            boxes.append(.init(label: d.label, confidence: d.confidence, rect: topLeft(d.box), tileOnly: !seen))
        }
        return ZoomTilePass(index: index, region: topLeft(region), boxes: boxes, cut: cut, at: at)
    }

    /// The row's short class codes (FBE, FGE, MGE, BE, AE; the covered
    /// classes FBC, FGC, BC); any other label prints as itself.
    static func classCode(_ label: String) -> String {
        [
            "FEMALE_BREAST_EXPOSED": "FBE", "FEMALE_GENITALIA_EXPOSED": "FGE", "MALE_GENITALIA_EXPOSED": "MGE",
            "BUTTOCKS_EXPOSED": "BE", "ANUS_EXPOSED": "AE", "FEMALE_BREAST_COVERED": "FBC",
            "FEMALE_GENITALIA_COVERED": "FGC", "BUTTOCKS_COVERED": "BC",
        ][label] ?? label
    }
}

/// One tile pass, as the Tiles row draws it (`ZoomTiles.passView`). No pixels.
struct ZoomTilePass: Equatable {
    struct Box: Equatable {
        let label: String
        let confidence: Float
        /// Frame coordinates, normalized, TOP-LEFT origin.
        let rect: CGRect
        /// The full-frame pass had no same-class box at IoU ≥ `ZoomTiles.mergeIoU`.
        let tileOnly: Bool
    }
    let index: Int
    /// The tile, frame coordinates, normalized, top-left origin.
    let region: CGRect
    let boxes: [Box]
    /// Tile boxes dropped as cut by a seam (`ZoomTiles.isCut`).
    let cut: Int
    let at: CFAbsoluteTime
}
