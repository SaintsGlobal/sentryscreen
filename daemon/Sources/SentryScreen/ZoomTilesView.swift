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
// "Show preview" (off by default) adds a thumbnail per tile. With "Blur"
// (on by default, and on again every time the preview turns off) it is
// heavily blurred with every policy-passing box filled solid cover black.
// Blur off draws the tile's real, sharp pixels with nothing filled: the
// preview is for whoever tunes the zoom pass, to see what it was given
// (owner 2026-10-20: the content is already on the screen, and seeing it
// is the point). Safety rails, all tested by `--ui-selftest` group `zoom`:
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
//   * Pixels are copied on detectQueue, downscaled (and with Blur, blurred
//     and blacked out) there (`TilePreview.render`); the latest image per
//     tile is kept (four slots, no history), throttled
//     (`TilePreview.minIntervalSecs`), never written to disk.
//   * Nothing costs a frame while nobody looks: a tile pass is built and
//     recorded for the row only while the row is open on screen
//     (`ZoomTilesMonitor.isRecording`), and thumbnails are rendered only
//     while the preview is on and confirmed (`previewBlur`).

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
    private var blurred = true
    private var recording = false

    /// The pipeline builds and records a pass only while this is true: the
    /// Tiles row is open and on screen (`UIDevTiles.updatePolling`). The
    /// merge itself runs either way; it is detection.
    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    func setRecording(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        recording = on
    }

    /// detectQueue, once per tile pass.
    func record(_ pass: ZoomTilePass) {
        lock.lock()
        defer { lock.unlock() }
        guard snap.tiles.indices.contains(pass.index) else { return }
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

    /// What detectQueue renders: nil while no thumbnail is wanted, else
    /// whether to blur. One read, so the two cannot disagree.
    var previewBlur: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return wanted ? blurred : nil
    }

    /// Main. Turning it off drops every stored thumbnail in the same step.
    func setPreviewWanted(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        wanted = on
        if !on { thumbs = Array(repeating: nil, count: ZoomTiles.count) }
    }

    /// Main. Drops every stored thumbnail, so a sharp one never shows after
    /// Blur is back on (nor a blurred one after it is off).
    func setBlur(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard blurred != on else { return }
        blurred = on
        thumbs = Array(repeating: nil, count: ZoomTiles.count)
    }

    /// detectQueue. Refused (dropped) unless the preview is still wanted at
    /// the blur it was rendered with, so a thumbnail rendered just before a
    /// turn-off or a Blur change can never land after it.
    func store(_ image: CGImage, tile: Int, blurred: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        // Under the lock: `setPreviewWanted(false)` replaces `thumbs` on main.
        guard wanted, blurred == self.blurred, thumbs.indices.contains(tile) else { return }
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

    /// With Blur off. The zoomed view is the column's full width (~300 pt,
    /// ~600 px at 2x) and the point is to read what the tile holds, so the
    /// thumbnail carries about that many pixels. DERIVED. Four slots of
    /// 640 × ~360 × 4 bytes is under 4 MB, still one render per
    /// `minIntervalSecs`.
    static let sharpWidthPx = 640

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

    /// At most one thumbnail per this many seconds, across all four tiles,
    /// stalest tile first (`Throttle`), so each tile refreshes about every
    /// 4 × this. RECEIPT: the plan's "2 Hz or less";
    /// the cost bound is what matters — one crop, scale, blur and render on
    /// detectQueue per 15 frames at 30 fps. A pass the throttle refuses is
    /// counted (`tilePreviewThrottled` in the 60 s summary), never silent.
    static let minIntervalSecs: Double = 0.5

    /// Admits at most one render per `minIntervalSecs`, and only for the
    /// tile rendered longest ago. A gap alone beat against the rotation:
    /// at 15 fps the first frame past 0.5 s is 8 frames on, 8 mod 4 = 0, so
    /// it admitted the same tile every time and three slots stayed empty.
    /// The rotation brings every tile round within `ZoomTiles.count` frames,
    /// so the stalest one waits at most that long past the gap.
    struct Throttle {
        private(set) var lastAt: CFAbsoluteTime = -.infinity
        private var tileAt = Array(repeating: -Double.infinity, count: ZoomTiles.count)
        mutating func admit(_ now: CFAbsoluteTime, tile: Int) -> Bool {
            guard tileAt.indices.contains(tile), now - lastAt >= TilePreview.minIntervalSecs,
                tileAt[tile] == tileAt.min() else { return false }
            lastAt = now
            tileAt[tile] = now
            return true
        }
    }

    /// The tile `region` (Vision bottom-left, normalized) of `buffer`.
    /// Blurred (the default): `widthPx` wide, blurred by `blurSigmaPx`, with
    /// every `blackout` box (frame bottom-left, normalized: the frame's
    /// policy-passing boxes) filled solid black — before the blur, so
    /// nothing bleeds out of it, and again after, so the fill stays solid.
    /// `blur: false`: `sharpWidthPx` wide, the pixels as captured, nothing
    /// filled. nil if the region is empty.
    static func render(
        _ buffer: CVPixelBuffer, region: CGRect, blackout: [CGRect], blur: Bool = true, context: CIContext
    ) -> CGImage? {
        let W = CGFloat(CVPixelBufferGetWidth(buffer)), H = CGFloat(CVPixelBufferGetHeight(buffer))
        let px = CGRect(x: region.minX * W, y: region.minY * H, width: region.width * W, height: region.height * H)
            .integral
        guard px.width > 0, px.height > 0 else { return nil }
        let width = CGFloat(blur ? widthPx : sharpWidthPx)
        let scale = width / px.width
        let out = CGRect(x: 0, y: 0, width: width, height: (px.height * scale).rounded())
        // CIImage's origin is bottom-left, like Vision's.
        var img = CIImage(cvPixelBuffer: buffer).cropped(to: px)
            .transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY).concatenating(
                CGAffineTransform(scaleX: scale, y: scale)))
        guard blur else { return context.createCGImage(img.cropped(to: out), from: out) }
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
    /// Blur was switched. The pipeline needs nothing (the next tile pass
    /// renders at the new setting); the demo, with no frames, renders again.
    func tilesPreviewBlurChanged()
}

extension TilesPreviewHost {
    func tilesPreviewBlurChanged() {}
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
        case rowHidden = "row-hidden"
        case zoomTilesOff = "zoomtiles-off"
        case exclusionUnconfirmed = "exclusion-unconfirmed"
        case exclusionFailed = "exclusion-failed"
    }

    enum Exclusion: String { case off, awaiting, confirmed }

    let monitor: ZoomTilesMonitor
    @Published var expanded = false { didSet { updatePolling() } }
    @Published private(set) var snapshot = ZoomTilesMonitor.Snapshot()
    @Published private(set) var preview = false
    /// "Blur": on by default and on again whenever the preview turns off,
    /// so every preview starts blurred.
    @Published private(set) var blur = true
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
        blur = true
        monitor.setBlur(true)
        images = Array(repeating: nil, count: ZoomTiles.count)
        // Id out first (excludedWindowNumber is nil now), then the request.
        host?.refreshTilesPreviewExclusion()
        previewWindow = nil
        offAt = nil
        self.refusal = refusal
        record("state=off reason=\(reason.rawValue)")
    }

    /// Main. Blur off shows the tiles' sharp pixels with nothing filled. No
    /// PIN of its own: the preview, and the Developer tab, are behind it.
    func setBlur(_ on: Bool) {
        guard preview, blur != on else { return }
        blur = on
        monitor.setBlur(on)
        images = Array(repeating: nil, count: ZoomTiles.count)
        host?.tilesPreviewBlurChanged()
        record("blur=\(on ? "on" : "off")")
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

    /// The row collapsed or left the screen (another tab, a PIN prompt over
    /// the sheet): the outline poll stops and so does the preview, which
    /// would otherwise keep cropping and blurring at 2 Hz for nobody until
    /// its TTL (code review 2026-10-29).
    private func updatePolling() {
        let want = visible && expanded
        if !want {
            turnOffPreview(reason: .rowHidden)
            monitor.setRecording(false)
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        monitor.setRecording(true)
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
    /// With the preview showing thumbnails, "no pixels" is no longer true.
    static let rowCaptionPreview = "What the zoom pass ran and found, over blurred tiles of the screen."
    static let rowCaptionSharp = "What the zoom pass ran and found, over the tiles as the detector saw them."
    static func caption(previewShowing: Bool, blur: Bool = true) -> String {
        previewShowing ? (blur ? rowCaptionPreview : rowCaptionSharp) : rowCaption
    }
    static let previewLabel = "Show preview"
    static let previewCaption = "Thumbnails of each tile, in memory only. Off when the popover closes."
    static let blurLabel = "Blur"
    static let blurCaption = "On: blurred, every blocked box filled black. Off: the tile's real pixels, "
        + "sharp and unfilled, to check what the zoom pass looks at."
    static let pinPreview = "Show tile previews in the Developer tab."
    /// The four-up beside the zoomed tile: the full legend no longer fits
    /// under a half-width drawing, so the tile part moves into it.
    static let pickHint = "Tap a tile, or pick one:"
    static let waiting = "Waiting for capture to exclude this window…"
    static let noPass = "No tile pass yet."
    static let legend = "Solid box: found by the tile only. Dashed box: the full frame found it too. "
        + "Solid tile: the one that ran last; dashed tile: the one zoomed."
    static let zoomTitle = "Zoomed tile"
    static let tileNames = ["top left", "top right", "bottom left", "bottom right"]

    /// "Tile 1, top left · 1.9× zoom · 2 boxes, 1 tile-only". Zoom is per
    /// axis against the full pass, which sees the whole frame at the same
    /// model size (`ZoomTiles.grid` receipt: 674 px of 1280 is 1.9×).
    static func zoomLine(_ i: Int, _ p: ZoomTilePass?) -> String {
        let name = tileNames.indices.contains(i) ? tileNames[i] : "tile"
        let head = "Tile \(i + 1), \(name)"
        guard let p, p.region.width > 0 else { return head + ": no pass yet" }
        let only = p.boxes.filter(\.tileOnly).count
        let boxes = p.boxes.isEmpty
            ? "no boxes" : "\(p.boxes.count) box\(p.boxes.count == 1 ? "" : "es"), \(only) tile-only"
        return head + " · \(String(format: "%.1f", 1 / Double(p.region.width)))× zoom · " + boxes
            + (p.cut > 0 ? ", \(p.cut) cut at the seam" : "")
    }
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
    /// The tile the zoomed view shows (index; the picker reads 1–4).
    @State private var zoomTile = 0

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
        Text(ZoomTilesCopy.caption(previewShowing: tiles.preview && tiles.exclusion == .confirmed, blur: tiles.blur))
            .uiFont(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if tiles.snapshot.passes == 0 {
            Text(ZoomTilesCopy.noPass).uiFont(.caption2).foregroundStyle(.secondary)
                .uiControl("\(Self.idPrefix).nopass", kind: .text, read: { ZoomTilesCopy.noPass })
        } else {
            // Preview and Blur on one row ABOVE the drawings: under them
            // they sat at the viewport's bottom edge, Blur under the
            // "More below" fade (VM render 2026-10-20).
            HStack(spacing: 14) {
                Toggle(isOn: Binding(get: { tiles.preview }, set: { actions.setTilesPreview($0) })) {
                    Text(ZoomTilesCopy.previewLabel).uiFont(.caption)
                }
                .toggleStyle(.checkbox)
                .help(ZoomTilesCopy.previewCaption)
                .uiControl("\(Self.idPrefix).preview", kind: .toggle,
                    read: { tiles.preview ? "on" : "off" }, activate: { actions.setTilesPreview(!tiles.preview) })
                // Its own view: a second id on the toggle replaced the toggle's
                // accessibility identifier (live VM run, 2026-10-20).
                .background(Color.clear.uiControl("\(Self.idPrefix).preview.state", kind: .text,
                    read: { tiles.exclusion.rawValue }))
                if tiles.preview {
                    Toggle(isOn: Binding(get: { tiles.blur }, set: { tiles.setBlur($0) })) {
                        Text(ZoomTilesCopy.blurLabel).uiFont(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help(ZoomTilesCopy.blurCaption)
                    .uiControl("\(Self.idPrefix).blur", kind: .toggle,
                        read: { tiles.blur ? "on" : "off" }, activate: { tiles.setBlur(!tiles.blur) })
                }
                Spacer(minLength: 0)
            }
            if tiles.preview && tiles.exclusion != .confirmed {
                Text(ZoomTilesCopy.waiting)
                    .uiFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // The four-up beside the picker, the zoomed tile under both: one
            // above the other at full width did not fit the popover's
            // viewport together, so checking a tile meant scrolling between
            // where it is and what is in it (VM render 2026-10-20).
            HStack(alignment: .top, spacing: 10) {
                drawing
                picker.frame(width: Self.sideWidth)
            }
            // A frame for scripts to measure the pair by (`assert … frame`).
            .background(Color.clear.uiControl("\(Self.idPrefix).fourup", kind: .text, read: { "" }))
            zoomed
            Text(ZoomTilesCopy.legend).uiFont(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let why = tiles.refusal {
            UIInlineMessage(text: why, symbol: UISymbol.warning, tint: .systemOrange)
                .uiControl("\(Self.idPrefix).refusal", kind: .text, read: { tiles.refusal ?? "" })
        }
    }

    /// One tile at the column's full width: what the detector was given
    /// for it, at the tile's own aspect, with its boxes in tile space and,
    /// with the preview on, its thumbnail. The four-up drawing shows WHERE
    /// each tile is; this shows WHAT is in it, large enough to check that
    /// the zoom landed on the part of the screen it should (owner
    /// 2026-10-20). A chosen tile, not the live one: the rotation moves on
    /// every evaluated frame, faster than anyone reads.
    /// The column beside the four-up. DERIVED: four small segments of one
    /// digit are ~96 pt; at 104 pt the four-up keeps ~140 pt of the ~250 pt
    /// card column, and the pair plus the full-width zoomed tile stay
    /// inside the ~390 pt Settings viewport even on a 4:3 display.
    static let sideWidth: CGFloat = 104

    /// "Zoomed tile", the 1–4 picker and the tile's line, beside the four-up.
    private var picker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ZoomTilesCopy.zoomTitle).uiFont(.caption).fontWeight(.semibold)
            Picker(ZoomTilesCopy.zoomTitle, selection: $zoomTile) {
                ForEach(0..<ZoomTiles.count, id: \.self) { Text("\($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .uiControl("\(Self.idPrefix).zoom", kind: .picker, read: { "\(zoomTile + 1)" },
                setText: { raw in if let n = Int(raw), (1...ZoomTiles.count).contains(n) { zoomTile = n - 1 } })
            Text(ZoomTilesCopy.zoomLine(zoomTile, tiles.snapshot.tiles[zoomTile]))
                .uiFont(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .uiControl("\(Self.idPrefix).zoom.line", kind: .text, read: {
                    ZoomTilesCopy.zoomLine(zoomTile, tiles.snapshot.tiles[zoomTile])
                })
        }
    }

    private var zoomed: some View {
        let i = zoomTile
        let pass = tiles.snapshot.tiles[i]
        let region = pass?.region ?? Self.quadrant(i)
        return GeometryReader { g in
            Canvas { ctx, size in drawZoom(&ctx, size, tile: i) }
                .frame(width: g.size.width, height: g.size.width * Self.tileAspect(region, screen: aspect))
        }
        .aspectRatio(1 / Self.tileAspect(region, screen: aspect), contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(ZoomTilesCopy.zoomLine(i, pass))
        .background(Color.clear.uiControl("\(Self.idPrefix).zoom.view", kind: .text, read: { "" }))
        .padding(.top, 2)
    }

    /// Which tile a tap on the four-up picks: the quadrant under it (the
    /// 10 % overlaps go to the nearer tile's own half).
    static func tileAt(_ p: CGPoint, size: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return 0 }
        let n = ZoomTiles.grid
        let col = min(n - 1, max(0, Int(p.x / size.width * CGFloat(n))))
        let row = min(n - 1, max(0, Int(p.y / size.height * CGFloat(n))))
        return row * n + col
    }

    /// Height / width of a tile on screen: its normalized region times the
    /// screen's own aspect.
    static func tileAspect(_ region: CGRect, screen: CGFloat) -> CGFloat {
        region.width > 0 ? region.height * screen / region.width : screen
    }

    private func drawZoom(_ ctx: inout GraphicsContext, _ size: CGSize, tile i: Int) {
        let frame = CGRect(origin: .zero, size: size)
        ctx.fill(Path(frame), with: .color(SentryColor.paper))
        guard let p = tiles.snapshot.tiles[i] else {
            ctx.draw(Text(ZoomTilesCopy.noPass).font(.caption2).foregroundColor(.secondary),
                at: CGPoint(x: size.width / 2, y: size.height / 2))
            ctx.stroke(Path(frame), with: .color(.secondary), lineWidth: 1)
            return
        }
        if tiles.exclusion == .confirmed, let image = tiles.images[i] {
            ctx.draw(Image(decorative: image, scale: 1), in: frame)
        }
        let r0 = p.region
        for b in p.boxes {
            let r = CGRect(x: (b.rect.minX - r0.minX) / r0.width * size.width,
                y: (b.rect.minY - r0.minY) / r0.height * size.height,
                width: b.rect.width / r0.width * size.width, height: b.rect.height / r0.height * size.height)
            let ink = b.tileOnly ? SentryColor.primary : Color.secondary
            ctx.stroke(Path(r), with: .color(ink), style: StrokeStyle(lineWidth: 2, dash: b.tileOnly ? [] : [4, 3]))
            Self.label(&ctx, ZoomTilesCopy.boxLabel(b), size: 10, ink: ink, box: r, in: frame)
        }
        ctx.stroke(Path(frame), with: .color(SentryColor.accent), lineWidth: 2)
    }

    private var drawing: some View {
        GeometryReader { g in
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: g.size.width, height: g.size.width * aspect)
                .contentShape(Rectangle())
                .onTapGesture { p in
                    zoomTile = Self.tileAt(p, size: CGSize(width: g.size.width, height: g.size.width * aspect))
                }
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
        // The tile the zoomed view shows, dashed: the solid outline is the
        // tile that ran last, which moves on every frame.
        let picked = s.tiles[zoomTile]?.region ?? Self.quadrant(zoomTile)
        ctx.stroke(Path(pts(picked).insetBy(dx: 1.5, dy: 1.5)), with: .color(SentryColor.ink),
            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        for p in s.tiles.compactMap({ $0 }) {
            for b in p.boxes {
                let r = pts(b.rect)
                let ink = b.tileOnly ? SentryColor.primary : Color.secondary
                ctx.stroke(Path(r), with: .color(ink),
                    style: StrokeStyle(lineWidth: 1.5, dash: b.tileOnly ? [] : [3, 2]))
                Self.label(&ctx, ZoomTilesCopy.boxLabel(b), size: 8, ink: ink, box: r, in: frame)
            }
        }
        ctx.stroke(Path(frame), with: .color(.secondary), lineWidth: 1)
    }

    /// A box label on a paper backing, so it reads over any thumbnail
    /// colour (gold on the yellow quadrant was all but invisible).
    static func label(_ ctx: inout GraphicsContext, _ text: String, size: CGFloat, ink: Color, box: CGRect,
        in frame: CGRect)
    {
        let t = ctx.resolve(Text(text).font(.system(size: size, weight: .semibold, design: .monospaced))
            .foregroundColor(ink))
        let s = t.measure(in: CGSize(width: 400, height: 100))
        let back = labelRect(CGSize(width: s.width + 4, height: s.height), box: box, in: frame)
        ctx.fill(Path(roundedRect: back, cornerRadius: 2), with: .color(SentryColor.paper.opacity(0.85)))
        ctx.draw(t, at: CGPoint(x: back.minX + 2, y: back.maxY), anchor: .bottomLeading)
    }

    /// Where a label of `size` goes: just above `box`, left edges aligned,
    /// moved inside `frame` wherever that would cut it — under the box when
    /// there is no room above (a box at a tile's top edge drew its label off
    /// the canvas, so it had none), and left from the right edge. Every
    /// drawn box gets a label that is wholly on the canvas (owner
    /// 2026-10-20).
    static func labelRect(_ size: CGSize, box: CGRect, in frame: CGRect) -> CGRect {
        var r = CGRect(x: box.minX, y: box.minY - 1 - size.height, width: size.width, height: size.height)
        if r.minY < frame.minY { r.origin.y = min(box.maxY + 1, frame.maxY - size.height) }
        r.origin.y = max(frame.minY, r.minY)
        r.origin.x = max(frame.minX, min(r.minX, frame.maxX - size.width))
        return r
    }

    /// Before the first pass: the plain quadrant, top-left origin.
    static func quadrant(_ i: Int) -> CGRect {
        let n = CGFloat(ZoomTiles.grid)
        return CGRect(x: CGFloat(i % ZoomTiles.grid) / n, y: CGFloat(i / ZoomTiles.grid) / n,
            width: 1 / n, height: 1 / n)
    }
}
