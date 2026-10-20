import AppKit
import CoreImage
import CoreVideo

// `--ui-demo --ui-demo-state tiles=sample`: the Tiles row on fake data, so
// its drawing, the zoomed tile and the preview can be rendered and checked
// without a capture. The thumbnails go through the REAL crop, blur and
// blackout (`ZoomTiles.region`, `TilePreview.render`) of a benign test
// pattern, so a render shows whether each tile is the part of the screen it
// should be. The preview still turns on through the PIN and the exclusion
// handshake; `ZoomTilesDemoHost` stands in for capture and confirms it.

enum ZoomTilesDemo {
    /// The pattern's size: the capture size every tiling receipt uses.
    static let width = 1280, height = 720

    /// Four solid quadrants, each with its tile's number large in the
    /// middle and a light grid, so a thumbnail shows which quadrant it is
    /// and the 10 % overlap shows as a sliver of the neighbour's colour.
    /// Nothing but colour, lines and digits.
    static let quadrantColors: [NSColor] = [
        NSColor(srgbRed: 0.80, green: 0.22, blue: 0.18, alpha: 1),  // 1 top-left: red
        NSColor(srgbRed: 0.20, green: 0.62, blue: 0.30, alpha: 1),  // 2 top-right: green
        NSColor(srgbRed: 0.18, green: 0.36, blue: 0.78, alpha: 1),  // 3 bottom-left: blue
        NSColor(srgbRed: 0.90, green: 0.74, blue: 0.16, alpha: 1),  // 4 bottom-right: yellow
    ]

    static func pattern() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
            == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for i in 0..<4 {
            // CoreGraphics is bottom-left: row 0 (tiles 1, 2) is the top half.
            let r = CGRect(x: CGFloat(i % 2) * w / 2, y: i < 2 ? h / 2 : 0, width: w / 2, height: h / 2)
            ctx.setFillColor(quadrantColors[i].cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(2)
            for k in stride(from: r.minX, through: r.maxX, by: 40) {
                ctx.move(to: CGPoint(x: k, y: r.minY)); ctx.addLine(to: CGPoint(x: k, y: r.maxY))
            }
            for k in stride(from: r.minY, through: r.maxY, by: 40) {
                ctx.move(to: CGPoint(x: r.minX, y: k)); ctx.addLine(to: CGPoint(x: r.maxX, y: k))
            }
            ctx.strokePath()
            let digit = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 220, weight: .heavy), .foregroundColor: NSColor.white,
            ])
            let s = digit.size()
            digit.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
        return buffer
    }

    /// One pass per tile, ending on tile 1 (index 0) so the zoomed view
    /// shows boxes: a box only the tile found, one the full frame found
    /// too, and one cut by the seam (counted, not drawn). Every tile has a
    /// box, so a gold label is drawn over each colour (yellow included),
    /// and one sits in tile 2's top-right corner, where a label above it
    /// would leave the canvas. Synthetic labels and scores only. Returns the
    /// full-frame boxes the preview blacks out.
    @discardableResult
    static func seed(_ monitor: ZoomTilesMonitor, at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [CGRect] {
        func det(_ l: String, _ c: Float, _ r: CGRect) -> Detection { Detection(label: l, confidence: c, box: r) }
        func region(_ i: Int) -> CGRect { ZoomTiles.region(index: i, width: width, height: height) }
        // Frame coordinates, Vision's bottom-left, inside each tile's region.
        let seen = CGRect(x: 0.14, y: 0.70, width: 0.08, height: 0.10)
        let full = [det("FEMALE_BREAST_EXPOSED", 0.86, seen)]
        let passes: [(Int, [Detection])] = [
            (1, [det("BUTTOCKS_EXPOSED", 0.74, CGRect(x: 0.70, y: 0.62, width: 0.05, height: 0.06)),
                 det("FEMALE_BREAST_EXPOSED", 0.72, CGRect(x: 0.93, y: 0.95, width: 0.05, height: 0.04))]),
            (2, [det("MALE_GENITALIA_EXPOSED", 0.93, CGRect(x: 0.30, y: 0.18, width: 0.03, height: 0.04))]),
            (3, [det("FEMALE_GENITALIA_EXPOSED", 0.76, CGRect(x: 0.72, y: 0.20, width: 0.04, height: 0.05))]),
            (0, [det("FEMALE_BREAST_EXPOSED", 0.91, seen.offsetBy(dx: 0.003, dy: 0)),
                 det("ANUS_EXPOSED", 0.78, CGRect(x: 0.32, y: 0.84, width: 0.03, height: 0.04)),
                 // Ends 0.001 short of tile 1's right edge (0.5266): cut.
                 det("BUTTOCKS_EXPOSED", 0.81, CGRect(x: 0.49, y: 0.60, width: 0.0355, height: 0.05))]),
        ]
        for (k, (i, tile)) in passes.enumerated() {
            let m = ZoomTiles.merge(full: full, tile: tile, tileIndex: i, region: region(i))
            monitor.record(ZoomTiles.passView(m, index: i, region: region(i), at: now - Double(passes.count - k) / 30))
        }
        return full.map(\.box)
    }
}

/// Capture's stand-in for the demo: every exclusion request is answered
/// "applied, popover excluded" on the next main-loop turn, and once the
/// monitor wants thumbnails it gets the four tiles of the test pattern.
final class ZoomTilesDemoHost: TilesPreviewHost {
    var tilesPreview: UIDevTiles?
    private var handler: ((CaptureStream.ExclusionResult) -> Void)?
    private(set) var newestExclusionRequest = 0
    var tilesPreviewUnavailable: String? { nil }
    private let blackout: [CGRect]
    private let context = CIContext()

    init(blackout: [CGRect]) { self.blackout = blackout }

    func setTilesPreviewExclusionHandler(_ h: ((CaptureStream.ExclusionResult) -> Void)?) { handler = h }

    /// No frames arrive here, so a Blur change renders the four tiles again.
    func tilesPreviewBlurChanged() { DispatchQueue.main.async { [weak self] in self?.renderThumbnails() } }

    func refreshTilesPreviewExclusion() {
        newestExclusionRequest += 1
        let request = newestExclusionRequest
        let ids = tilesPreview?.excludedWindowNumber.map { Set([$0]) } ?? []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            handler?(.init(applied: true, ids: ids, request: request))
            renderThumbnails()
        }
    }

    /// The real render, into the real monitor: refused there unless the
    /// handshake has confirmed (`ZoomTilesMonitor.store`).
    private func renderThumbnails() {
        guard let tiles = tilesPreview, let blur = tiles.monitor.previewBlur, let buffer = ZoomTilesDemo.pattern()
        else { return }
        for i in 0..<ZoomTiles.count {
            let region = ZoomTiles.region(index: i, width: ZoomTilesDemo.width, height: ZoomTilesDemo.height)
            if let image = TilePreview.render(buffer, region: region, blackout: blackout, blur: blur, context: context) {
                tiles.monitor.store(image, tile: i, blurred: blur)
            }
        }
        tiles.poll()
    }
}
