import CoreGraphics
import Foundation

// `--ui-selftest` group `zoom` (SENTRY_UI_SELFTEST_CASE=zoom): the zoom
// (tiling) prototype, `ZoomTiles.swift`. Pure, synthetic detections only: no
// window, no detector, no image.
//  - both flavors: production refuses the `zoomTiles` key by name, so
//    neither config.json nor tuning.json can turn it on; the default dump
//    never carries it;
//  - off by default, parse/dump, tile geometry and mapping back to
//    the frame, rotation, the cut-box drop and the merge.
extension UISelfTest {
    static func caseZoomTiles() {
        func json(_ s: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
        }
        let d = TuningPolicy.defaults
        check("zoom: the default tuning dump has no zoomTiles key", !d.jsonString().contains("zoomTiles"))
        let on = TuningPolicy.parse(json(#"{"zoomTiles": true}"#), base: d)
        zoomTuning(d, on, json)
    }

    private static func zoomTuning(
        _ d: TuningPolicy, _ on: Result<TuningPolicy, TuningPolicy.ParseError>,
        _ json: (String) -> [String: Any]
    ) {
        check("zoom: off by default", !d.zoomTiles)
        if case let .success(p) = on {
            check("zoom: tuning.json turns it on and the dump says so",
                p.zoomTiles && p.jsonString().contains("\"zoomTiles\":true"), p.jsonString())
        } else {
            check("zoom: zoomTiles true parses", false, "\(on)")
        }
        if case let .failure(e) = TuningPolicy.parse(json(#"{"zoomTiles": 1}"#), base: d) {
            check("zoom: zoomTiles must be a bool, refused by name", e.text.contains("zoomTiles"), e.text)
        } else {
            check("zoom: zoomTiles 1 is refused", false)
        }

        // Geometry on a 1280 × 720 capture: the tiling experiment's 674 × 379 px
        // tiles (receipt at `ZoomTiles.overlap`), row-major from the top left.
        let W = 1280, H = 720
        let r = (0..<ZoomTiles.count).map { ZoomTiles.region(index: $0, width: W, height: H) }
        func px(_ c: CGRect) -> [Int] {
            [Int((c.minX * CGFloat(W)).rounded()), Int(((1 - c.maxY) * CGFloat(H)).rounded()),
             Int((c.width * CGFloat(W)).rounded()), Int((c.height * CGFloat(H)).rounded())]
        }
        check("zoom: 2 × 2 grid, four tiles", ZoomTiles.count == 4 && r.count == 4)
        check("zoom: tile 0 is the top-left 674 × 379 px (top-left pixel origin)",
            px(r[0]) == [0, 0, 674, 379], "\(px(r[0]))")
        check("zoom: tile 1 is top-right, ends at the frame edge", px(r[1]) == [606, 0, 674, 379], "\(px(r[1]))")
        check("zoom: tile 2 is bottom-left", px(r[2]) == [0, 341, 674, 379], "\(px(r[2]))")
        check("zoom: tile 3 is bottom-right", px(r[3]) == [606, 341, 674, 379], "\(px(r[3]))")
        check("zoom: tile 0 sits at the TOP in Vision's bottom-left space",
            r[0].maxY == 1 && r[2].minY == 0)
        let union = r.dropFirst().reduce(r[0]) { $0.union($1) }
        check("zoom: the tiles cover the whole frame",
            abs(union.minX) < 1e-9 && abs(union.minY) < 1e-9
                && abs(union.maxX - 1) < 1e-9 && abs(union.maxY - 1) < 1e-9, "\(union)")
        // Mapping back: a box at the middle of tile 3 (Vision reports it
        // relative to the region) lands at the middle of tile 3 in the frame.
        let mid = Detector.toFrame(CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), roi: r[3])
        check("zoom: a tile-relative box maps back into its tile on the frame",
            abs(mid.midX - r[3].midX) < 1e-9 && abs(mid.midY - r[3].midY) < 1e-9
                && abs(mid.width - 0.1 * r[3].width) < 1e-9, "\(mid)")

        // Rotation: one tile per frame, all four in four frames, then again.
        var seq: [Int] = []
        var i = 0
        for _ in 0..<8 { seq.append(i); i = ZoomTiles.next(after: i) }
        check("zoom: rotation visits every tile once per four frames", seq == [0, 1, 2, 3, 0, 1, 2, 3], "\(seq)")

        // Cut-box drop on tile 0 (top-left): its right and bottom edges are
        // interior seams, its left and top are the frame's edges.
        let t0 = r[0]
        func inTile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            Detector.toFrame(CGRect(x: x, y: y, width: w, height: h), roi: t0)
        }
        check("zoom: a box touching tile 0's right seam is cut", ZoomTiles.isCut(inTile(0.9, 0.5, 0.095, 0.1), tile: t0))
        check("zoom: a box touching tile 0's bottom seam is cut", ZoomTiles.isCut(inTile(0.5, 0.005, 0.1, 0.1), tile: t0))
        check("zoom: a box touching the FRAME's left edge is not cut", !ZoomTiles.isCut(inTile(0.0, 0.5, 0.1, 0.1), tile: t0))
        check("zoom: a box touching the FRAME's top edge is not cut", !ZoomTiles.isCut(inTile(0.5, 0.9, 0.1, 0.1), tile: t0))
        check("zoom: a box just inside the margin is kept", !ZoomTiles.isCut(inTile(0.5, 0.5, 0.48, 0.1), tile: t0))

        // Merge (synthetic detections): same-class IoU ≥ 0.5 keeps the higher
        // score; a tile box that wins is marked with its tile.
        let a = CGRect(x: 0.10, y: 0.60, width: 0.05, height: 0.05)
        func det(_ l: String, _ c: Float, _ b: CGRect) -> Detection { Detection(label: l, confidence: c, box: b) }
        let full = [det("FEMALE_BREAST_EXPOSED", 0.40, a), det("FACE_FEMALE", 0.70, a)]
        let near = a.offsetBy(dx: 0.002, dy: 0)
        let small = CGRect(x: 0.20, y: 0.70, width: 0.02, height: 0.02)
        let tile = [
            det("FEMALE_BREAST_EXPOSED", 0.80, near),  // same box, higher: replaces the full one
            det("FACE_FEMALE", 0.30, near),  // same box, lower: dropped
            det("BUTTOCKS_EXPOSED", 0.60, small),  // new small box: added
            det("ANUS_EXPOSED", 0.90, inTile(0.95, 0.5, 0.05, 0.05)),  // cut by the seam
        ]
        let m = ZoomTiles.merge(full: full, tile: tile, tileIndex: 0, region: t0)
        func find(_ l: String) -> [Detection] { m.merged.filter { $0.label == l } }
        check("zoom: the cut box is dropped and counted", m.dropped == 1 && find("ANUS_EXPOSED").isEmpty, "\(m.dropped)")
        check("zoom: a higher-scoring tile duplicate replaces the full box and is marked",
            find("FEMALE_BREAST_EXPOSED").map { "\($0.confidence)/\($0.tile ?? -1)" } == ["0.8/0"])
        check("zoom: a lower-scoring tile duplicate is dropped; the full box keeps no tile mark",
            find("FACE_FEMALE").map { "\($0.confidence)/\($0.tile ?? -1)" } == ["0.7/-1"])
        check("zoom: a new small tile box is added with its tile",
            find("BUTTOCKS_EXPOSED").map { $0.tile } == [0])
        check("zoom: merge output has three boxes", m.merged.count == 3, "\(m.merged.count)")
        let tie = ZoomTiles.merge(
            full: [det("FEMALE_BREAST_EXPOSED", 0.5, a)], tile: [det("FEMALE_BREAST_EXPOSED", 0.5, near)],
            tileIndex: 0, region: t0)
        check("zoom: a score tie keeps the full-frame box",
            tie.merged.count == 1 && tie.merged[0].tile == nil, "\(tie.merged.map(\.tile))")
        let otherClass = ZoomTiles.merge(
            full: [det("FEMALE_BREAST_EXPOSED", 0.5, a)], tile: [det("FEMALE_BREAST_COVERED", 0.6, near)],
            tileIndex: 0, region: t0)
        check("zoom: NMS is per class (an overlapping other-class box stays)", otherClass.merged.count == 2)
        let none = ZoomTiles.merge(full: full, tile: [], tileIndex: 3, region: r[3])
        check("zoom: an empty tile pass leaves the full boxes", none.merged.count == 2 && none.dropped == 0)
    }
}
