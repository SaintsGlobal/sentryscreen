import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

// `--ui-selftest` group `zoom`, part 2: the Developer tab's Tiles row
// (ZoomTilesView.swift). Synthetic detections and a synthetic checkerboard
// buffer only: no capture, no detector, no window on screen.
//  - outline data: tile-only marking, the seam drop, top-left geometry;
//  - the preview: off by default, the PIN gate, the exclusion handshake
//    (nothing produced or drawn before capture names the window), every
//    turn-off trigger, the throttle, the blur and the black fill.

/// The pipeline side of the handshake, recorded.
private final class FakeTilesHost: TilesPreviewHost {
    var tilesPreview: UIDevTiles?
    var unavailable: String?
    var handler: ((CaptureStream.ExclusionResult) -> Void)?
    /// The window list of every exclusion request, in order.
    var refreshes: [[Int]] = []
    var newestExclusionRequest: Int { refreshes.count }
    let cover = 7

    func refreshTilesPreviewExclusion() {
        refreshes.append(Pipeline.exclusionWindowNumbers(
            covers: [cover], detectionView: nil, tilesPreview: tilesPreview?.excludedWindowNumber))
    }

    func setTilesPreviewExclusionHandler(_ h: ((CaptureStream.ExclusionResult) -> Void)?) { handler = h }
    var tilesPreviewUnavailable: String? { unavailable }

    /// Capture's answer to the newest request.
    func answer(_ ids: Set<Int>, applied: Bool = true, request: Int? = nil) {
        handler?(.init(applied: applied, ids: ids, request: request ?? newestExclusionRequest))
    }
}

extension UISelfTest {
    static func caseZoomTilesView(_ dir: String) {
        zoomTilesOutlines()
        zoomTilesPreviewGate()
        zoomTilesPreviewPIN(dir)
        zoomTilesPreviewPixels()
    }

    private static func zoomTilesOutlines() {
        func det(_ l: String, _ c: Float, _ b: CGRect) -> Detection { Detection(label: l, confidence: c, box: b) }
        let r0 = ZoomTiles.region(index: 0, width: 1280, height: 720)
        let seen = CGRect(x: 0.10, y: 0.70, width: 0.05, height: 0.05)
        let fresh = CGRect(x: 0.20, y: 0.80, width: 0.03, height: 0.03)
        let cutBox = Detector.toFrame(CGRect(x: 0.95, y: 0.5, width: 0.05, height: 0.05), roi: r0)
        let p = ZoomTiles.passView(
            full: [det("FEMALE_BREAST_EXPOSED", 0.80, seen)],
            tile: [det("FEMALE_BREAST_EXPOSED", 0.90, seen.offsetBy(dx: 0.002, dy: 0)),
                   det("BUTTOCKS_EXPOSED", 0.70, fresh), det("ANUS_EXPOSED", 0.90, cutBox)],
            index: 0, region: r0, at: 1)
        check("zoom tiles: a tile box the full pass also found is not tile-only; a new one is; a seam-cut one is counted, not drawn",
            p.boxes.map(\.tileOnly) == [false, true] && p.cut == 1 && p.boxes.map(\.label)
                == ["FEMALE_BREAST_EXPOSED", "BUTTOCKS_EXPOSED"], "\(p.boxes) cut=\(p.cut)")
        check("zoom tiles: tile-only is per class (an other-class full box does not count)",
            ZoomTiles.passView(full: [det("FEMALE_BREAST_COVERED", 0.9, fresh)], tile: [det("BUTTOCKS_EXPOSED", 0.7, fresh)],
                index: 0, region: r0, at: 1).boxes.first?.tileOnly == true)
        check("zoom tiles: geometry is top-left (tile 0 at the top, boxes flipped)",
            p.region.minY == 0 && abs(p.boxes[1].rect.minY - (1 - fresh.maxY)) < 1e-9, "\(p.region)")
        check("zoom tiles: class codes and the box label",
            ZoomTiles.classCode("MALE_GENITALIA_EXPOSED") == "MGE" && ZoomTiles.classCode("FACE_FEMALE") == "FACE_FEMALE"
                && ZoomTilesCopy.boxLabel(p.boxes[0]) == "FBE 0.90")
        check("zoom tiles: the registry line names the tile, its boxes, tile-only finds and the cut",
            ZoomTilesCopy.tileLine(0, p, active: true) == "Tile 1 (now): 2 boxes, 1 tile-only, 1 cut — FBE 0.90, +BE 0.70"
                && ZoomTilesCopy.tileLine(3, nil, active: false) == "Tile 4: no pass yet",
            ZoomTilesCopy.tileLine(0, p, active: true))
        let m = ZoomTilesMonitor()
        m.record(p)
        m.record(ZoomTilePass(index: 2, region: .zero, boxes: [], cut: 0, at: 2))
        let s = m.snapshot()
        check("zoom tiles: the monitor keeps the latest pass per tile (4 slots) and the tile that ran last",
            s.tiles.count == 4 && s.tiles[0] == p && s.tiles[2] != nil && s.tiles[1] == nil && s.active == 2
                && s.passes == 2)
        // The Detection view outlines the tile this frame ran.
        let screen = CGSize(width: 1920, height: 1080)
        var input = DetectionTraceBuilder.Inputs(
            seq: 1, capturedAt: 0, screenPt: screen, display: CGRect(origin: .zero, size: screen),
            policy: .standard, coverMode: "region", tuning: .defaults, tuningSource: "defaults",
            blockFaces: false, roi: nil,
            stats: .init(evaluatedFps: 0, detectMs: 0, stepMs: 0, idleSkipped: 0, traceMs: 0))
        input.zoomTile = ZoomTiles.region(index: 3, width: 1280, height: 720)
        let traced = DetectionTraceBuilder.build(input, builtAt: 0, appName: { _ in nil }).trace
        let opts = DetectionViewLayout.Options(mode: .outlineOverCovers, now: 0, remaining: 60, showNonPolicy: false,
            synthetic: false)
        let L = DetectionViewLayout.make(traced, size: screen, options: opts)
        input.zoomTile = nil
        let none = DetectionViewLayout.make(
            DetectionTraceBuilder.build(input, builtAt: 0, appName: { _ in nil }).trace, size: screen, options: opts)
        check("zoom tiles: the Detection view outlines the frame's tile (tile 3 = bottom-right, top-left points); none with zoom off",
            L.zoomTile.map { abs($0.maxX - 1920) < 1 && abs($0.maxY - 1080) < 1 && $0.minX > 900 } == true
                && none.zoomTile == nil, "\(String(describing: L.zoomTile))")
        check("zoom tiles: the Tiles row's events never ship in a diagnostics report",
            !DiagnosticsAllowlist.runEvents.contains(ZoomTilesCopy.event))
    }

    private static func zoomTilesPreviewGate() {
        let tiles = UIDevTiles()
        let host = FakeTilesHost()
        check("zoom preview: off by default — no preview, no exclusion, no window excluded, no pixels wanted",
            !tiles.preview && tiles.exclusion == .off && tiles.excludedWindowNumber == nil
                && !tiles.monitor.previewWanted && !tiles.expanded)
        check("zoom preview: refused with no pipeline", !tiles.turnOnPreview(window: 42) && tiles.refusal != nil)
        tiles.attach(host)
        host.unavailable = DetectionViewCopy.refusedPaused
        check("zoom preview: refused while paused", !tiles.turnOnPreview(window: 42) && !tiles.preview)
        host.unavailable = nil
        check("zoom preview: refused with no popover window", !tiles.turnOnPreview(window: nil) && !tiles.preview)

        // The handshake.
        check("zoom preview: turning on asks capture to exclude the popover window, beside the cover",
            tiles.turnOnPreview(window: 42) && tiles.exclusion == .awaiting && host.refreshes.last == [7, 42])
        let img = Self.oneByOne()
        tiles.monitor.store(img, tile: 0)
        tiles.poll()
        check("zoom preview: before confirmation nothing is produced, stored or drawn",
            !tiles.monitor.previewWanted && tiles.monitor.images().allSatisfy { $0 == nil }
                && tiles.images.allSatisfy { $0 == nil })
        host.answer([7, 42], request: host.newestExclusionRequest - 1)
        check("zoom preview: an answer to an OLDER request is ignored", tiles.exclusion == .awaiting)
        let before = host.refreshes.count
        host.answer([7])
        check("zoom preview: an answer without the window keeps it hidden and asks again",
            tiles.exclusion == .awaiting && host.refreshes.count == before + 1 && !tiles.monitor.previewWanted)
        host.answer([7, 42])
        tiles.monitor.store(img, tile: 1)
        tiles.poll()
        check("zoom preview: the answer naming the window confirms; only then do thumbnails land and draw",
            tiles.exclusion == .confirmed && tiles.monitor.previewWanted && tiles.images[1] != nil && tiles.images[0] == nil)
        tiles.streamInvalidated()
        tiles.poll()
        check("zoom preview: a stream rebuild hides it and drops every thumbnail",
            tiles.exclusion == .awaiting && !tiles.monitor.previewWanted && tiles.images.allSatisfy { $0 == nil }
                && tiles.monitor.images().allSatisfy { $0 == nil })
        host.answer([7, 42])
        check("zoom preview: an answer from before the rebuild does not reconfirm", tiles.exclusion == .awaiting)
        host.refreshTilesPreviewExclusion()
        host.answer([7, 42])
        check("zoom preview: the re-arm's own answer reconfirms", tiles.exclusion == .confirmed)
        tiles.turnOffPreview(reason: .user)
        check("zoom preview: turning off drops the window from the very next request and every thumbnail",
            !tiles.preview && host.refreshes.last == [7] && !tiles.monitor.previewWanted
                && tiles.monitor.images().allSatisfy { $0 == nil } && tiles.excludedWindowNumber == nil)
        tiles.monitor.store(img, tile: 2)
        check("zoom preview: a thumbnail rendered after turn-off is refused", tiles.monitor.images()[2] == nil)

        // Capture never confirms: off by name after Capture's retry budget.
        _ = tiles.turnOnPreview(window: 42)
        for _ in 0..<CaptureStream.exclusionAttemptBudget { host.answer([7]) }
        check("zoom preview: unconfirmed after the retry budget → off, named",
            !tiles.preview && tiles.refusal?.contains("\(CaptureStream.exclusionAttemptBudget) tries") == true)
        _ = tiles.turnOnPreview(window: 42)
        host.answer([], applied: false)
        check("zoom preview: a failed exclusion → off", !tiles.preview && tiles.refusal != nil)

        // Every other turn-off trigger.
        func onAndConfirmed() { _ = tiles.turnOnPreview(window: 42); host.answer([7, 42]) }
        for reason: UIDevTiles.OffReason in [.panicHotkey, .panicPause, .parentPause, .shutdown, .popoverClosed] {
            onAndConfirmed()
            tiles.turnOffPreview(reason: reason)
            check("zoom preview: \(reason.rawValue) turns it off", !tiles.preview && !tiles.monitor.previewWanted)
        }
        onAndConfirmed()
        tiles.tick(zoomTiles: false)
        check("zoom preview: zoomTiles turned off turns it off", !tiles.preview)
        var now = Date(timeIntervalSince1970: 1_000)
        let timed = UIDevTiles(clock: { now })
        timed.attach(host)
        _ = timed.turnOnPreview(window: 42)
        now += UIDevTiles.ttlSecs - 1
        timed.tick(zoomTiles: true)
        let stillOn = timed.preview
        now += 1
        timed.tick(zoomTiles: true)
        check("zoom preview: its own TTL (\(Int(UIDevTiles.ttlSecs)) s) turns it off", stillOn && !timed.preview)
        _ = timed.turnOnPreview(window: 42)
        timed.detach(reason: .pipelineRebuild)
        check("zoom preview: a pipeline rebuild (detach) turns it off and clears the host's slot",
            !timed.preview && host.handler == nil && host.tilesPreview == nil)
        check("zoom preview: a fresh model (every agent start) is off", !UIDevTiles().preview)

        // Outline polling only while the row is open AND on screen.
        let row = UIDevTiles()
        row.expanded = true
        let hiddenPolls = row.isPolling
        row.setVisible(true)
        let open = row.isPolling
        row.expanded = false
        check("zoom tiles: the row polls only while open and on screen", !hiddenPolls && open && !row.isPolling)
        row.setVisible(false)
    }

    /// The PIN gate through UIActions (the same requirePIN the other
    /// Developer controls use), and the popover-close turn-off.
    private static func zoomTilesPreviewPIN(_ dir: String) {
        let fm = FileManager.default
        let root = dir + "/zoom-preview-store"
        try? fm.removeItem(atPath: root)
        try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = UISettingsStore(root: root, log: { _, _ in })
        let actions = UIActions(store: store, log: { _, _ in })
        let tuning = UIDevTuning(stateRoot: root, groupID: getegid(), base: .defaults, baseSource: "defaults")
        actions.devTuning = tuning
        let host = FakeTilesHost()
        tuning.tiles.attach(host)
        actions.popoverWindowNumber = { 42 }
        actions.openSettings()
        actions.setTilesPreview(true)
        check("zoom preview: turning on with no PIN set asks for one first, preview stays off",
            actions.layer == .setPin && !tuning.tiles.preview, "\(actions.layer)")
        actions.newPin = "4821"
        actions.confirmPin = "4821"
        actions.saveNewPin()
        spin(until: { !actions.busy })
        check("zoom preview: once the PIN is saved the preview turns on (awaiting capture)",
            tuning.tiles.preview && tuning.tiles.exclusion == .awaiting, "\(actions.layer)")
        actions.popoverClosed()
        check("zoom preview: the popover closing turns it off", !tuning.tiles.preview)
        actions.lock()
        actions.openSettings()
        actions.setTilesPreview(true)
        check("zoom preview: locked ⇒ the PIN prompt names the preview, still off",
            actions.layer == .pin && actions.pendingConfirmation == ZoomTilesCopy.pinPreview && !tuning.tiles.preview,
            "\(actions.layer) \(actions.pendingConfirmation ?? "-")")
        actions.pinEntry = "0000"
        actions.submitPIN()
        spin(until: { !actions.busy })
        check("zoom preview: a wrong PIN leaves it off", !tuning.tiles.preview)
        actions.lock()
        actions.openSettings()
        actions.setTilesPreview(true)
        actions.pinEntry = "4821"
        actions.submitPIN()
        spin(until: { !actions.busy })
        check("zoom preview: the right PIN turns it on", tuning.tiles.preview)
        actions.setTilesPreview(false)
        check("zoom preview: turning off never asks", !tuning.tiles.preview && actions.layer == .settings,
            "\(actions.layer)")
        try? fm.removeItem(atPath: root)
    }

    private static func zoomTilesPreviewPixels() {
        var t = TilePreview.Throttle()
        check("zoom preview: the throttle admits one render per \(TilePreview.minIntervalSecs) s (≤ 2 Hz)",
            TilePreview.minIntervalSecs >= 0.5 && t.admit(10, tile: 0) && !t.admit(10.49, tile: 1)
                && t.admit(10.5, tile: 1) && !t.admit(10.6, tile: 2))
        // 15 fps, one tile per frame: the first frame past each 0.5 s gap is
        // always the same tile. Stalest-first still fills all four slots.
        var r = TilePreview.Throttle()
        var rendered = Set<Int>()
        for f in 0..<120 where r.admit(Double(f) / 15, tile: f % ZoomTiles.count) { rendered.insert(f % ZoomTiles.count) }
        check("zoom preview: at 15 fps every tile still gets a thumbnail (stalest first)",
            rendered.count == ZoomTiles.count, "\(rendered.sorted())")

        // A 1280 × 720 BGRA frame: a 2 px black/white checkerboard, the
        // highest-contrast fine detail a frame can hold.
        let W = 1280, H = 720
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let buffer = pb else { check("zoom preview: synthetic buffer", false); return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<H {
            for x in 0..<W {
                let v: UInt8 = ((x / 2) + (y / 2)) % 2 == 0 ? 0 : 255
                let p = base + y * row + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let region = ZoomTiles.region(index: 0, width: W, height: H)
        // A blocked box in the middle of tile 0 (Vision bottom-left).
        let hole = CGRect(x: region.midX - 0.05, y: region.midY - 0.05, width: 0.1, height: 0.1)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let start = CFAbsoluteTimeGetCurrent()
        guard let image = TilePreview.render(buffer, region: region, blackout: [hole], context: ctx) else {
            check("zoom preview: render returns an image", false)
            return
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "# zoom preview: one 1280x720 tile thumbnail render %.1f ms (first call, CIContext warm-up)", ms))
        check("zoom preview: the thumbnail is \(TilePreview.widthPx) px wide at the tile's aspect",
            image.width == TilePreview.widthPx && abs(Double(image.height) - 160 * 379 / 674) <= 1,
            "\(image.width)x\(image.height)")
        // Read it back.
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cg = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lum(_ x: Int, _ y: Int) -> Double { Double(px[(y * w + x) * 4 + 1]) }  // top-down rows
        let centre = lum(w / 2, h / 2)
        // Away from the hole and the edges: what the blur left of the checkerboard.
        var lo = 255.0, hi = 0.0
        for y in 4..<12 { for x in 4..<40 { lo = min(lo, lum(x, y)); hi = max(hi, lum(x, y)) } }
        check("zoom preview: a blocked box is filled solid cover black", centre == 0, "centre=\(centre)")
        check("zoom preview: the blur leaves under 2 % of a 2 px checkerboard's contrast (sigma \(TilePreview.blurSigmaPx) px)",
            hi - lo < 0.02 * 255 && hi > 60, "range \(lo)…\(hi)")
    }

    private static func oneByOne() -> CGImage {
        let cg = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return cg.makeImage()!
    }
}
