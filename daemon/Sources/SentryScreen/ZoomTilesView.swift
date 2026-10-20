import AppKit
import CoreImage
import Foundation
import SwiftUI

// TUNING TOOL — Settings › Developer › "Tiles": what the zoom pass
// (`ZoomTiles`, `TuningPolicy.zoomTiles`) is doing, shown only while
// zoomTiles is on and collapsed by default.
//
// Outline mode (the default) shows NO PIXELS: a 2 × 2 diagram at the main
// display's aspect ratio, the tile the detector ran most recently
// highlighted, and each tile's latest-pass boxes as outlines with class code
// and score; a box the full-frame pass missed (`ZoomTilePass.Box.tileOnly`)
// is drawn solid, one both passes found dashed.
//
// "Show blurred preview" (off by default) adds a heavily blurred thumbnail
// per tile with every policy-passing box filled solid cover black. Safety
// rails, all tested by `--ui-selftest` group `zoom`:
//   * Behind the parent PIN to turn on (UIActions.setTilesPreview); in
//     memory only, so every agent start is off.
//   * Capture exclusion FIRST, the Detection view's handshake
//     (DetectionViewController.swift): the popover's window joins
//     `Pipeline.exclusionWindowNumbers`, and no thumbnail is produced or
//     drawn until the LATEST exclusion result names that window. A result
//     without it, or a stream rebuild, drops every thumbnail and stops
//     production until capture reconfirms; unconfirmed after Capture's own
//     retry budget → off by name. Without this the detector would see its own
//     crops in the popover (a feedback loop and false curtains).
//   * Off on: every pause, the panic hold, shutdown (which the `--ttl` exit
//     runs), a pipeline rebuild, its own TTL, zoomTiles turned off, the popover
//     closing, and the UI.
//   * Pixels are copied on detectQueue, downscaled, blurred and blacked out
//     there (`TilePreview.render`); the latest image per tile is kept (four
//     slots, no history), throttled (`TilePreview.minIntervalSecs`), never
//     written to disk.

/// detectQueue writes, main reads: the latest pass per tile, the tile that
/// ran last, and (preview on and confirmed only) the latest thumbnail per
/// tile. Four slots each, replaced in place: no growth, no history.
final class ZoomTilesMonitor {
    struct Snapshot: Equatable {
        var tiles: [ZoomTilePass?] = Array(repeating: nil, count: ZoomTiles.count)
        /// The tile the detector ran most recently.
        var active: Int?
        var passes = 0
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var thumbs: [CGImage?] = Array(repeating: nil, count: ZoomTiles.count)
    private var wanted = false

    /// detectQueue, once per tile pass.
    func record(_ pass: ZoomTilePass) {
        guard snap.tiles.indices.contains(pass.index) else { return }
        lock.lock()
        defer { lock.unlock() }
        snap.tiles[pass.index] = pass
        snap.active = pass.index
        snap.passes += 1
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snap
    }

    /// Thumbnails are produced only while this is true, and it is true only
    /// while capture has confirmed the popover's exclusion (`UIDevTiles`).
    var previewWanted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wanted
    }

    /// Main. Turning it off drops every stored thumbnail in the same step.
    func setPreviewWanted(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        wanted = on
        if !on { thumbs = Array(repeating: nil, count: ZoomTiles.count) }
    }

    /// detectQueue. Refused (dropped) unless the preview is still wanted, so
    /// a thumbnail rendered just before a turn-off can never land after it.
    func store(_ image: CGImage, tile: Int) {
        guard thumbs.indices.contains(tile) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard wanted else { return }
        thumbs[tile] = image
    }

    func images() -> [CGImage?] {
        lock.lock()
        defer { lock.unlock() }
        return thumbs
    }
}

/// The preview's pixel work, detectQueue only. Pure apart from the
/// CIContext the caller owns.
enum TilePreview {
    /// Thumbnail width in pixels. The plan's "about 160 px wide": a 2 × 2
    /// diagram in the ~300 pt Developer column at 2x is ~150 px per tile,
    /// so more pixels would only be more detail to blur away. DERIVED.
    static let widthPx = 160

    /// Gaussian sigma in THUMBNAIL pixels. DERIVED 2026-10-20, not measured
    /// on real content (live content is the owner's to check): a tile is
    /// 674 px of the 1280 px capture (`ZoomTiles.overlap` receipt), so one
    /// thumbnail pixel is ~4.2 capture px; the capture is ~1.5 screen points
    /// per pixel on the 1920 pt displays every tuning receipt uses, so one
    /// thumbnail pixel is ~6.3 pt and sigma 10 is ~63 pt on screen. The
    /// exposed-class boxes of the owner's 2026-09-11 session run 13–181 pt
    /// (`TuningPolicy.parse` receipt), so every one of them is at most ~3
    /// sigma across: smeared into a shapeless blob. And every box the policy
    /// passes is filled solid black on top (`render`), blur or not.
    /// `--ui-selftest` "zoom: preview blur" asserts a 2 px checkerboard keeps
    /// under 2 % of its contrast.
    static let blurSigmaPx: Double = 10

    /// At most one thumbnail per this many seconds, across all four tiles
    /// (each tile refreshes every ~2 s). RECEIPT: the plan's "2 Hz or less";
    /// the cost bound is what matters — one crop, scale, blur and render on
    /// detectQueue per 15 frames at 30 fps. A pass the throttle refuses is
    /// counted (`tilePreviewThrottled` in the 60 s summary), never silent.
    static let minIntervalSecs: Double = 0.5

    /// Admits at most one render per `minIntervalSecs`.
    struct Throttle {
        private(set) var lastAt: CFAbsoluteTime = -.infinity
        mutating func admit(_ now: CFAbsoluteTime) -> Bool {
            guard now - lastAt >= TilePreview.minIntervalSecs else { return false }
            lastAt = now
            return true
        }
    }

    /// The tile `region` (Vision bottom-left, normalized) of `buffer`,
    /// `widthPx` wide, blurred by `blurSigmaPx`, with every `blackout` box
    /// (frame bottom-left, normalized: the frame's policy-passing boxes)
    /// filled solid black — before the blur, so nothing bleeds out of it, and
    /// again after, so the fill stays solid. nil if the region is empty.
    static func render(
        _ buffer: CVPixelBuffer, region: CGRect, blackout: [CGRect], context: CIContext
    ) -> CGImage? {
        let W = CGFloat(CVPixelBufferGetWidth(buffer)), H = CGFloat(CVPixelBufferGetHeight(buffer))
        let px = CGRect(x: region.minX * W, y: region.minY * H, width: region.width * W, height: region.height * H)
            .integral
        guard px.width > 0, px.height > 0 else { return nil }
        let scale = CGFloat(widthPx) / px.width
        let out = CGRect(x: 0, y: 0, width: CGFloat(widthPx), height: (px.height * scale).rounded())
        // CIImage's origin is bottom-left, like Vision's.
        var img = CIImage(cvPixelBuffer: buffer).cropped(to: px)
            .transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY).concatenating(
                CGAffineTransform(scaleX: scale, y: scale)))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        let holes = blackout.map { b -> CGRect in
            CGRect(x: (b.minX * W - px.minX) * scale, y: (b.minY * H - px.minY) * scale,
                width: b.width * W * scale, height: b.height * H * scale).intersection(out)
        }.filter { !$0.isNull && !$0.isEmpty }
        func fill(_ i: CIImage) -> CIImage { holes.reduce(i) { black.cropped(to: $1).composited(over: $0) } }
        img = fill(img).clampedToExtent().applyingGaussianBlur(sigma: blurSigmaPx).cropped(to: out)
        return context.createCGImage(fill(img), from: out)
    }
}

/// What the preview needs from the pipeline. `Pipeline` conforms in
/// main.swift; the self-test uses a fake with a real `CaptureStream`.
protocol TilesPreviewHost: AnyObject {
    var tilesPreview: UIDevTiles? { get set }
    /// `capture.refreshExclusion(windowNumbers: exclusionWindowNumbers)`.
    func refreshTilesPreviewExclusion()
    var newestExclusionRequest: Int { get }
    func setTilesPreviewExclusionHandler(_ handler: ((CaptureStream.ExclusionResult) -> Void)?)
    /// Why the preview cannot turn on now (a pause, no capture); nil if it can.
    var tilesPreviewUnavailable: String? { get }
}

/// Main thread. The Tiles row's model: the outline poll and the preview's
/// state machine. Owned by `UIDevTuning` (one per agent, like its readout).
final class UIDevTiles: ObservableObject {
    /// Outline refresh while the row is open and on screen. DERIVED: at 30
    /// fps a tile pass lasts 33 ms, so no UI rate shows every pass; 4 Hz
    /// shows the rotation moving and costs one locked copy of four small
    /// structs per tick. Off while the row is closed or the popover is.
    static let pollSecs: TimeInterval = 0.25
    /// The preview's own TTL: the Detection view's (receipt at
    /// `DetectionViewController.ttlSecs`), so a forgotten preview is bounded
    /// the same way.
    static let ttlSecs = DetectionViewController.ttlSecs

    enum OffReason: String {
        case user = "turned-off"
        case ttl = "ttl-expired"
        case panicHotkey = "panic-hotkey"
        case panicPause = "panic-pause"
        case parentPause = "parent-pause"
        case shutdown
        case pipelineRebuild = "pipeline-rebuild"
        case popoverClosed = "popover-closed"
        case zoomTilesOff = "zoomtiles-off"
        case exclusionUnconfirmed = "exclusion-unconfirmed"
        case exclusionFailed = "exclusion-failed"
    }

    enum Exclusion: String { case off, awaiting, confirmed }

    let monitor: ZoomTilesMonitor
    @Published var expanded = false { didSet { updatePolling() } }
    @Published private(set) var snapshot = ZoomTilesMonitor.Snapshot()
    @Published private(set) var preview = false
    @Published private(set) var exclusion: Exclusion = .off
    @Published private(set) var images: [CGImage?] = Array(repeating: nil, count: ZoomTiles.count)
    @Published private(set) var refusal: String?
    /// stderr + run.jsonl (AppDelegate's UI log), event `tiles-preview`.
    var log: (String, String) -> Void = { _, _ in }
    let clock: () -> Date

    private(set) weak var host: TilesPreviewHost?
    /// The popover window the thumbnails draw in, fixed at turn-on.
    private var previewWindow: Int?
    private var acceptResultsFrom = 0
    private var unconfirmedResults = 0
    private(set) var offAt: Date?
    private var visible = false
    private var timer: Timer?

    init(monitor: ZoomTilesMonitor = ZoomTilesMonitor(), clock: @escaping () -> Date = Date.init) {
        self.monitor = monitor
        self.clock = clock
    }

    /// `Pipeline.exclusionWindowNumbers` appends this while the preview is
    /// on, nil the moment it turns off.
    var excludedWindowNumber: Int? { preview ? previewWindow : nil }

    var isPolling: Bool { timer != nil }

    // MARK: Pipeline attachment

    func attach(_ host: TilesPreviewHost) {
        if let old = self.host, old !== host { detach(reason: .pipelineRebuild) }
        self.host = host
        host.tilesPreview = self
        host.setTilesPreviewExclusionHandler { [weak self] result in self?.exclusionResult(result) }
    }

    func detach(reason: OffReason) {
        turnOffPreview(reason: reason)
        guard let host else { return }
        host.setTilesPreviewExclusionHandler(nil)
        if host.tilesPreview === self { host.tilesPreview = nil }
        self.host = nil
    }

    // MARK: Preview on / off

    /// Main; the caller has passed the PIN. `window` is the popover's.
    @discardableResult
    func turnOnPreview(window: Int?) -> Bool {
        refusal = nil
        guard !preview else { return true }
        guard let host else { return refuse(ZoomTilesCopy.refusedNoPipeline) }
        if let why = host.tilesPreviewUnavailable { return refuse(why) }
        guard let window, window > 0 else { return refuse(ZoomTilesCopy.refusedNoWindow) }
        previewWindow = window
        preview = true
        exclusion = .awaiting
        unconfirmedResults = 0
        offAt = clock().addingTimeInterval(Self.ttlSecs)
        // Our id is in exclusionWindowNumbers from here on.
        host.refreshTilesPreviewExclusion()
        acceptResultsFrom = host.newestExclusionRequest
        record("state=on ttl=\(Int(Self.ttlSecs))s window=\(window) — no thumbnail until capture excludes the window")
        return true
    }

    /// Main, synchronous: by return no thumbnail is stored or drawn and
    /// capture has been asked for a filter without the popover's window.
    func turnOffPreview(reason: OffReason, refusal: String? = nil) {
        guard preview else { return }
        preview = false
        exclusion = .off
        monitor.setPreviewWanted(false)
        images = Array(repeating: nil, count: ZoomTiles.count)
        // Id out first (excludedWindowNumber is nil now), then the request.
        host?.refreshTilesPreviewExclusion()
        previewWindow = nil
        offAt = nil
        self.refusal = refusal
        record("state=off reason=\(reason.rawValue)")
    }

    // MARK: Exclusion handshake (the Detection view's rule)

    func exclusionResult(_ result: CaptureStream.ExclusionResult) {
        guard preview, result.request >= acceptResultsFrom, let id = previewWindow else { return }
        if result.applied, result.ids.contains(id) {
            unconfirmedResults = 0
            guard exclusion != .confirmed else { return }
            exclusion = .confirmed
            monitor.setPreviewWanted(true)
            record("state=visible exclusion=confirmed window=\(id)")
            return
        }
        hideUntilConfirmed("exclusion result without window \(id)")
        let budget = CaptureStream.exclusionAttemptBudget
        guard result.applied else {
            turnOffPreview(reason: .exclusionFailed, refusal: ZoomTilesCopy.refusedExclusion(budget: budget))
            return
        }
        unconfirmedResults += 1
        guard unconfirmedResults < budget else {
            turnOffPreview(reason: .exclusionUnconfirmed, refusal: ZoomTilesCopy.refusedExclusion(budget: budget))
            return
        }
        host?.refreshTilesPreviewExclusion()
        acceptResultsFrom = host?.newestExclusionRequest ?? acceptResultsFrom
    }

    /// A rebuilt stream carries a fresh content filter: no thumbnail until
    /// a request made after this names the window again.
    func streamInvalidated() {
        guard preview else { return }
        acceptResultsFrom = (host?.newestExclusionRequest ?? 0) + 1
        hideUntilConfirmed("capture stream rebuilt")
    }

    private func hideUntilConfirmed(_ why: String) {
        let was = exclusion == .confirmed
        exclusion = .awaiting
        monitor.setPreviewWanted(false)
        images = Array(repeating: nil, count: ZoomTiles.count)
        if was { record("state=hidden reason=\(why)") }
    }

    // MARK: Ticks

    /// The settings store's 1 Hz tick (`UIDevTuning.tick`): the preview's
    /// TTL, and off when zoomTiles is (the row is gone with it).
    func tick(zoomTiles: Bool) {
        guard preview else { return }
        if !zoomTiles { turnOffPreview(reason: .zoomTilesOff); return }
        if let offAt, clock() >= offAt { turnOffPreview(reason: .ttl) }
    }

    /// The row appeared / disappeared (the popover drops its view on close).
    func setVisible(_ on: Bool) {
        visible = on
        updatePolling()
    }

    private func updatePolling() {
        let want = visible && expanded
        if !want {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: Self.pollSecs, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One read of the monitor. Thumbnails are read only while confirmed.
    func poll() {
        let s = monitor.snapshot()
        if s != snapshot { snapshot = s }
        images = exclusion == .confirmed ? monitor.images() : Array(repeating: nil, count: ZoomTiles.count)
    }

    // MARK: Records

    private func refuse(_ why: String) -> Bool {
        refusal = why
        record("state=refused — \(why)")
        return false
    }

    private func record(_ info: String) { log(ZoomTilesCopy.event, info) }
}

enum ZoomTilesCopy {
    static let event = "tiles-preview"
    static let rowTitle = "Tiles"
    static let rowCaption = "What the zoom pass ran and found. Outlines only; no pixels."
    static let previewLabel = "Show blurred preview"
    static let previewCaption = "Blurred thumbnails with every blocked box filled black. Behind the PIN; "
        + "off when the popover closes."
    static let pinPreview = "Show blurred tile previews in the Developer tab."
    static let waiting = "Waiting for capture to exclude this window…"
    static let noPass = "No tile pass yet."
    static let legend = "Solid: found by the tile only. Dashed: the full frame found it too."
    static let refusedNoPipeline = "No capture is running."
    static let refusedNoWindow = "The popover's window is not on screen."
    static func refusedExclusion(budget: Int) -> String {
        "Capture did not exclude this window after \(budget) tries, so the preview is off."
    }

    /// "FBE 0.93", the row's box label.
    static func boxLabel(_ b: ZoomTilePass.Box) -> String {
        "\(ZoomTiles.classCode(b.label)) \(String(format: "%.2f", Double(b.confidence)))"
    }

    /// One line per tile for the registry (UI scripts) and VoiceOver.
    static func tileLine(_ i: Int, _ p: ZoomTilePass?, active: Bool) -> String {
        let head = "Tile \(i + 1)\(active ? " (now)" : "")"
        guard let p else { return head + ": no pass yet" }
        let only = p.boxes.filter(\.tileOnly).count
        let list = p.boxes.map { ($0.tileOnly ? "+" : "") + boxLabel($0) }.joined(separator: ", ")
        return head + ": \(p.boxes.count) box\(p.boxes.count == 1 ? "" : "es"), \(only) tile-only"
            + (p.cut > 0 ? ", \(p.cut) cut" : "") + (list.isEmpty ? "" : " — " + list)
    }
}

// MARK: - View

/// The collapsible Tiles row. Ids: `ui.settings.developer.tiles*`.
struct UIDevTilesRow: View {
    @ObservedObject var actions: UIActions
    @ObservedObject var tiles: UIDevTiles

    static let idPrefix = "\(UIDeveloperSettingsSection.idPrefix).tiles"

    /// The main display's aspect (height / width); 9:16 when unknown.
    private var aspect: CGFloat {
        guard let f = NSScreen.screens.first?.frame, f.width > 0 else { return 9.0 / 16.0 }
        return f.height / f.width
    }

    var body: some View {
        let toggle = { [tiles] in tiles.expanded.toggle() }
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: tiles.expanded ? "chevron.down" : "chevron.right")
                        .uiFont(.caption2, weight: .bold)
                        .accessibilityHidden(true)
                    Text(ZoomTilesCopy.rowTitle).uiFont(.caption).fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(tiles.expanded ? "Expanded" : "Collapsed")
            .uiControl(Self.idPrefix, kind: .button,
                read: { tiles.expanded ? "open" : "closed" }, activate: toggle)
            if tiles.expanded { content }
        }
        .onAppear { tiles.setVisible(true) }
        .onDisappear { tiles.setVisible(false) }
        // UI scripts scroll here to render the open row (`scrollto
        // ui.settings.developer.tiles`).
        .uiScrollAnchor(Self.idPrefix)
    }

    /// Before the first pass, one line: an empty grid, four "no pass yet"
    /// lines, the legend and a preview with nothing to show said the same
    /// thing six times (VM render 2026-10-20). After it, the drawing and its
    /// legend; the per-tile lines are the drawing's VoiceOver label and the
    /// scripts' `tiles.N` reads, not more text under it.
    @ViewBuilder private var content: some View {
        Text(ZoomTilesCopy.rowCaption).uiFont(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if tiles.snapshot.passes == 0 {
            Text(ZoomTilesCopy.noPass).uiFont(.caption2).foregroundStyle(.secondary)
                .uiControl("\(Self.idPrefix).nopass", kind: .text, read: { ZoomTilesCopy.noPass })
        } else {
            drawing
            Text(ZoomTilesCopy.legend).uiFont(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { tiles.preview }, set: { actions.setTilesPreview($0) })) {
                Text(ZoomTilesCopy.previewLabel).uiFont(.caption)
            }
            .toggleStyle(.checkbox)
            .help(ZoomTilesCopy.previewCaption)
            .uiControl("\(Self.idPrefix).preview", kind: .toggle,
                read: { tiles.preview ? "on" : "off" }, activate: { actions.setTilesPreview(!tiles.preview) })
            .uiControl("\(Self.idPrefix).preview.state", kind: .text, read: { tiles.exclusion.rawValue })
            if tiles.preview && tiles.exclusion != .confirmed {
                Text(ZoomTilesCopy.waiting)
                    .uiFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let why = tiles.refusal {
            UIInlineMessage(text: why, symbol: UISymbol.warning, tint: .systemOrange)
                .uiControl("\(Self.idPrefix).refusal", kind: .text, read: { tiles.refusal ?? "" })
        }
    }

    private var drawing: some View {
        GeometryReader { g in
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: g.size.width, height: g.size.width * aspect)
        }
        .aspectRatio(1 / aspect, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(lines.joined(separator: ". "))
        // The per-tile reads ride on the drawing (no text of their own).
        .background {
            ForEach(0..<ZoomTiles.count, id: \.self) { i in
                Color.clear.uiControl("\(Self.idPrefix).\(i)", kind: .text, read: {
                    ZoomTilesCopy.tileLine(i, tiles.snapshot.tiles[i], active: tiles.snapshot.active == i)
                })
            }
        }
    }

    private var lines: [String] {
        (0..<ZoomTiles.count).map {
            ZoomTilesCopy.tileLine($0, tiles.snapshot.tiles[$0], active: tiles.snapshot.active == $0)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        func pts(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width,
                height: r.height * size.height)
        }
        let frame = CGRect(origin: .zero, size: size)
        ctx.fill(Path(frame), with: .color(SentryColor.paper))
        let s = tiles.snapshot
        // Thumbnails only while capture has confirmed the exclusion (`poll`
        // reads none otherwise), under every outline.
        if tiles.exclusion == .confirmed {
            for (i, image) in tiles.images.enumerated() {
                guard let image, let p = s.tiles[i] else { continue }
                ctx.draw(Image(decorative: image, scale: 1), in: pts(p.region))
            }
        }
        for i in 0..<ZoomTiles.count {
            let region = s.tiles[i]?.region ?? Self.quadrant(i)
            let active = s.active == i
            if active { ctx.fill(Path(pts(region)), with: .color(SentryColor.accent.opacity(0.12))) }
            ctx.stroke(Path(pts(region)), with: .color(active ? SentryColor.accent : .secondary),
                lineWidth: active ? 2 : 0.5)
        }
        for p in s.tiles.compactMap({ $0 }) {
            for b in p.boxes {
                let r = pts(b.rect)
                let ink = b.tileOnly ? SentryColor.primary : Color.secondary
                ctx.stroke(Path(r), with: .color(ink),
                    style: StrokeStyle(lineWidth: 1.5, dash: b.tileOnly ? [] : [3, 2]))
                ctx.draw(Text(ZoomTilesCopy.boxLabel(b)).font(.system(size: 8, design: .monospaced))
                    .foregroundColor(ink), at: CGPoint(x: r.minX + 1, y: r.minY - 1), anchor: .bottomLeading)
            }
        }
        ctx.stroke(Path(frame), with: .color(.secondary), lineWidth: 1)
    }

    /// Before the first pass: the plain quadrant, top-left origin.
    static func quadrant(_ i: Int) -> CGRect {
        let n = CGFloat(ZoomTiles.grid)
        return CGRect(x: CGFloat(i % ZoomTiles.grid) / n, y: CGFloat(i / ZoomTiles.grid) / n,
            width: 1 / n, height: 1 / n)
    }
}
