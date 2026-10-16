import AppKit
import QuartzCore

// TUNING TOOL — the Detection view's renderer. One
// borderless, click-through window at the cover window's level, ordered just
// above it; pooled CAShapeLayer/CATextLayer; no implicit animations. The
// words come from DetectionViewCopy (UIDetectionView.swift); WHEN the window
// may draw is the controller's call (DetectionViewController.swift: nothing
// is drawn until capture has confirmed it excludes this window).
//
// Layout is a pure function (`DetectionViewLayout.make`) so the self-test can
// check what would be drawn — chip text, styles, collisions, legend, badge —
// without putting a window on screen, and render the same layers to a PNG.

/// Colour, width and dash of one decision. Colour, line style and words
/// each carry it on their own.
struct DetectionViewInk: Equatable {
    let color: CGColor
    let width: CGFloat
    /// Empty = solid.
    let dash: [CGFloat]
    let faint: Bool

    static func of(_ style: DetectionViewStyle) -> DetectionViewInk {
        switch style {
        case .covered: return .init(color: rgb(48, 209, 88), width: 3, dash: [], faint: false)
        case .pending: return .init(color: rgb(255, 214, 10), width: 2.5, dash: [9, 5], faint: false)
        case .dropped: return .init(color: rgb(255, 64, 200), width: 2.5, dash: [1, 5], faint: false)
        case .belowThreshold: return .init(color: rgb(210, 210, 216, 0.8), width: 1, dash: [], faint: true)
        case .nonPolicy: return .init(color: rgb(160, 160, 170, 0.7), width: 1, dash: [1, 4], faint: true)
        // Violet, thin, long-short dash: faint like the two above, but a
        // colour and dash nothing else uses, so a weak box never reads as a
        // threshold miss.
        case .weak: return .init(color: rgb(175, 140, 255, 0.7), width: 1, dash: [6, 3, 1, 3], faint: true)
        }
    }

    enum WindowState { case curtained, pending, leaving }

    /// Curtain windows share one colour; the dash says the state.
    static func window(_ s: WindowState) -> DetectionViewInk {
        let cyan = rgb(100, 210, 255)
        switch s {
        case .curtained: return .init(color: cyan, width: 2, dash: [], faint: false)
        case .pending: return .init(color: cyan, width: 2, dash: [9, 5], faint: false)
        case .leaving: return .init(color: cyan, width: 1.5, dash: [1, 5], faint: false)
        }
    }

    static func window(_ w: DetectionTrace.CurtainWindow) -> DetectionViewInk {
        switch w.state {
        case .curtained: return window(.curtained)
        case .pending: return window(.pending)
        case .leaving, .lingering: return window(.leaving)
        }
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

/// Everything one frame draws, in TOP-LEFT screen points (the detector's
/// orientation). `DetectionViewOverlay.apply` flips it for the layer tree.
struct DetectionViewLayout {
    struct Chip: Equatable {
        var frame: CGRect
        let lines: [String]
        let ink: DetectionViewInk
        /// From the chip's nearest edge to its outline, when the chip had to
        /// move away from the box to stay readable.
        var leader: [CGPoint]?
    }

    struct Item: Equatable {
        enum Kind: Equatable { case box(index: Int), window(id: CGWindowID) }
        let kind: Kind
        let outline: CGRect
        let ink: DetectionViewInk
        var chip: Chip
        let explanation: DetectionViewExplanation?
        /// Labels on, or this is the hovered item. A hidden chip is still
        /// placed, so hovering shows it exactly where labels-on would.
        var chipShown = true
    }

    struct Panel: Equatable {
        var frame: CGRect
        let lines: [String]
    }

    var items: [Item] = []
    var hud = Panel(frame: .zero, lines: [])
    var hudWarnings: Set<Int> = []
    var legend = Panel(frame: .zero, lines: [])
    var legendInks: [DetectionViewInk] = []
    var badge = Panel(frame: .zero, lines: [])
    var badgeDanger = false
    var hiddenNonPolicy = 0
    /// Chips that found no free spot and were placed over another label.
    var crowded = 0

    struct Options {
        var mode: DetectionViewMode
        var now: CFAbsoluteTime
        var remaining: TimeInterval
        var showNonPolicy: Bool
        /// "Show weak detections": draws boxes under `--conf` (the trace
        /// carries them only while it is on; this also hides a late one).
        var showWeak = false
        var synthetic: Bool
        /// "Show box labels" (off by default): off draws outlines only, plus
        /// the chip of `hovered`.
        var showLabels = true
        var hovered: Item.Kind?
        var drawMs: Double?
        var overBudgetMs: Double?
        /// Chips the previous draw placed over another (`crowded`): the HUD
        /// is laid out before the chips, so it names the last draw's count.
        var crowded = 0
        /// Menu bar height: nothing is placed under it.
        var topInset: CGFloat = 28
    }

    // Type and spacing. DERIVED, not tuning: 11 pt monospaced reads at arm's
    // length on a Retina display and keeps a 40-character outcome line under
    // ~300 pt, so a chip rarely covers more than the box it describes.
    static let chipFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let chipTitleFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    static let panelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let legendFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let legendTitleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Legend row pitch, shared by the text rows and their swatches.
    static let legendRow: CGFloat = 17
    static let badgeFont = NSFont.systemFont(ofSize: 14, weight: .bold)
    static let badgeSubFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let lineHeight: CGFloat = 14
    static let chipPad = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 6)
    static let hudWidth: CGFloat = 460
    static let margin: CGFloat = 12
    static let swatchWidth: CGFloat = 28

    static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    }

    /// `t` nil: no detector frame yet — the badge, legend and a waiting HUD
    /// are still drawn, so the view never looks off while it is on.
    static func make(_ t: DetectionTrace?, size: CGSize, options o: Options) -> DetectionViewLayout {
        var L = DetectionViewLayout()
        let top = o.topInset + margin

        // Chrome first: the badge, HUD and legend are reserved space.
        let badgeLines = DetectionViewCopy.badgeLines(mode: o.mode, remaining: o.remaining)
        L.badgeDanger = o.mode == .detectionsOnly
        if !badgeLines.isEmpty {
            let w = (badgeLines.enumerated().map { textWidth($1, $0 == 0 ? badgeFont : badgeSubFont) }.max() ?? 0) + 32
            let h: CGFloat = badgeLines.count == 1 ? 30 : 48
            L.badge = Panel(frame: CGRect(x: ((size.width - w) / 2).rounded(), y: top, width: w, height: h),
                lines: badgeLines)
        }

        let boxes = t?.boxes ?? []
        let visible = boxes.filter { ($0.isWeak ? o.showWeak : o.showNonPolicy || !isNonPolicy($0)) }
        L.hiddenNonPolicy = boxes.filter { !$0.isWeak }.count - visible.filter { !$0.isWeak }.count
        let hud = DetectionViewCopy.hud(t, now: o.now, drawMs: o.drawMs, overBudgetMs: o.overBudgetMs,
            hiddenNonPolicy: L.hiddenNonPolicy, synthetic: o.synthetic, crowded: o.crowded)
        L.hudWarnings = Set(hud.indices.filter { hud[$0].warning })
        let hudText = hud.map(\.text)
        let hudHeight = wrappedHeight(hudText, width: hudWidth - 16, font: panelFont) + 10
        L.hud = Panel(frame: CGRect(x: size.width - hudWidth - margin, y: top, width: hudWidth, height: hudHeight),
            lines: hudText)

        let styles = DetectionViewStyle.allCases.filter {
            ($0 != .nonPolicy || o.showNonPolicy) && ($0 != .weak || o.showWeak)
        }
        var legendLines = [DetectionViewCopy.legendTitle]
        legendLines += styles.map { DetectionViewCopy.legendText($0, mode: o.mode) }
        legendLines += [DetectionViewCopy.legendWindow, DetectionViewCopy.legendLabels]
        if !o.showLabels { legendLines.append(DetectionViewCopy.legendLabelsHidden) }
        L.legendInks = styles.map(DetectionViewInk.of) + [DetectionViewInk.window(.curtained)]
        let legendW = (legendLines.enumerated().map { i, s in
            textWidth(s, i == 0 ? legendTitleFont : legendFont) + swatchWidth + 8
        }.max() ?? 0) + 20
        let legendH = CGFloat(legendLines.count) * legendRow + 12
        L.legend = Panel(frame: CGRect(x: margin, y: size.height - legendH - margin, width: legendW, height: legendH),
            lines: legendLines)

        var taken: [CGRect] = [L.badge.frame, L.hud.frame, L.legend.frame].filter { !$0.isEmpty }
        let screen = CGRect(origin: .zero, size: size)
        guard let t else { return L }
        // Every drawn box's outline and interior: a chip avoids them when it
        // can, so it never hides another box or its line.
        let boxOutlines = visible.map { points($0.rect, size) }

        // Windows first (their header is anchored inside the window), then
        // boxes by importance: covered, pending, dropped, below, non-policy;
        // stronger scores first within a style.
        for w in t.windows {
            let r = points(w.frame, size)
            let ink = DetectionViewInk.window(w)
            let lines = [DetectionViewCopy.windowTitle(w), DetectionViewCopy.windowState(w, mode: o.mode)]
            var chip = Chip(frame: CGRect(origin: .zero, size: chipSize(lines)), lines: lines, ink: ink, leader: nil)
            L.crowded += place(&chip, outline: r, insideFirst: true, taken: &taken, avoid: boxOutlines,
                screen: screen, top: top)
            L.items.append(Item(kind: .window(id: w.id), outline: r, ink: ink, chip: chip, explanation: nil))
        }
        let explained: [(DetectionTrace.Box, DetectionViewExplanation)] = visible
            .map { ($0, DetectionViewCopy.explain($0, trace: t, mode: o.mode)) }
            .sorted(by: drawsFirst)
        for (b, e) in explained {
            let r = points(b.rect, size)
            let ink = DetectionViewInk.of(e.style)
            let lines = [DetectionViewCopy.title(b)] + e.lines
            var chip = Chip(frame: CGRect(origin: .zero, size: chipSize(lines)), lines: lines, ink: ink, leader: nil)
            L.crowded += place(&chip, outline: r, insideFirst: false, taken: &taken,
                avoid: boxOutlines.filter { $0 != r }, screen: screen, top: top)
            L.items.append(Item(kind: .box(index: b.index), outline: r, ink: ink, chip: chip, explanation: e))
        }
        if !o.showLabels {
            for i in L.items.indices { L.items[i].chipShown = L.items[i].kind == o.hovered }
        }
        return L
    }

    /// The item under `p` (top-left layout points): the smallest box that
    /// contains it, else the smallest curtain window that does, else nil.
    static func hitTest(_ items: [Item], at p: CGPoint) -> Item.Kind? {
        func smallest(_ window: Bool) -> Item? {
            items.filter { item in
                if case .window = item.kind { return window && item.outline.contains(p) }
                return !window && item.outline.contains(p)
            }.min { $0.outline.width * $0.outline.height < $1.outline.width * $1.outline.height }
        }
        return (smallest(false) ?? smallest(true))?.kind
    }

    /// `NSEvent.mouseLocation` (AppKit global points, bottom-left origin)
    /// → this display's top-left layout points. Points, not pixels: the
    /// backing scale never enters.
    static func layoutPoint(mouse m: CGPoint, screenFrame f: CGRect) -> CGPoint {
        CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
    }

    private static func drawsFirst(_ a: (DetectionTrace.Box, DetectionViewExplanation),
        _ b: (DetectionTrace.Box, DetectionViewExplanation)) -> Bool
    {
        let ra: Int = a.1.style.rank, rb: Int = b.1.style.rank
        if ra != rb { return ra > rb }
        if a.0.confidence != b.0.confidence { return a.0.confidence > b.0.confidence }
        return a.0.index < b.0.index
    }

    /// Box rects and curtain window frames share one space: normalized 0–1
    /// over the captured display, top-left origin.
    static func points(_ n: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: n.minX * size.width, y: n.minY * size.height,
            width: n.width * size.width, height: n.height * size.height)
    }

    static func isNonPolicy(_ b: DetectionTrace.Box) -> Bool {
        if case .notPolicyClass = b.policy { return true }
        return false
    }

    static func chipSize(_ lines: [String]) -> CGSize {
        let w = lines.enumerated().map { textWidth($1, $0 == 0 ? chipTitleFont : chipFont) }.max() ?? 0
        return CGSize(width: w + chipPad.left + chipPad.right,
            height: CGFloat(lines.count) * lineHeight + chipPad.top + chipPad.bottom)
    }

    static func wrappedHeight(_ lines: [String], width: CGFloat, font: NSFont) -> CGFloat {
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: font])
        return ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).height)
    }

    /// Scan step and reach for a chip that found no free candidate spot.
    /// DERIVED from the chip geometry, not tuned: 6 pt is under half a text
    /// line, so no free gap a chip fits in is stepped over; 60 steps (360 pt)
    /// reach past a dozen stacked two-line chips, beyond which a leader line
    /// would be too long to follow and the chip is placed over another one
    /// and COUNTED (`crowded`, named in the HUD on the next draw) rather
    /// than dropped.
    static let scanStep: CGFloat = 6
    static let scanSteps = 60

    /// Puts `chip` at the first free spot next to `outline`; returns 1 when
    /// no spot was free (the chip then overlaps, and the caller counts it).
    /// Two passes: first clear of every other label AND of `avoid` (the
    /// other boxes' outlines and interiors), outside its own box before
    /// inside it; then clear of labels only.
    static func place(
        _ chip: inout Chip, outline r: CGRect, insideFirst: Bool, taken: inout [CGRect], avoid: [CGRect],
        screen: CGRect, top: CGFloat
    ) -> Int {
        let s = chip.frame.size
        let above = CGPoint(x: r.minX, y: r.minY - s.height - 2)
        let inside = CGPoint(x: r.minX + 3, y: r.minY + 3)
        let below = CGPoint(x: r.minX, y: r.maxY + 2)
        let aboveRight = CGPoint(x: r.maxX - s.width, y: r.minY - s.height - 2)
        let belowRight = CGPoint(x: r.maxX - s.width, y: r.maxY + 2)
        let right = CGPoint(x: r.maxX + 3, y: r.minY)
        let left = CGPoint(x: r.minX - s.width - 3, y: r.minY)
        let candidates = insideFirst
            ? [inside, above, below]
            : [above, below, aboveRight, belowRight, right, left, inside]
        func fit(_ p: CGPoint, _ blockers: [CGRect]) -> CGRect? {
            let x = min(max(p.x, margin), screen.width - s.width - margin)
            let f = CGRect(x: x, y: p.y, width: s.width, height: s.height)
            guard f.minY >= top, f.maxY <= screen.height - margin else { return nil }
            return blockers.contains(where: { $0.intersects(f.insetBy(dx: 1, dy: 1)) }) ? nil : f
        }
        var spot: CGRect?
        for blockers in [taken + avoid, taken] {
            for c in candidates {
                if let f = fit(c, blockers) { spot = f; break }
            }
            if spot == nil {
                let start = max(inside.y, top)
                for step in 1...scanSteps {
                    let dy = CGFloat(step) * scanStep
                    if let f = fit(CGPoint(x: r.minX, y: start + dy), blockers)
                        ?? fit(CGPoint(x: r.minX, y: start - dy), blockers)
                    {
                        spot = f
                        break
                    }
                }
            }
            if spot != nil { break }
        }
        var crowded = 0
        let frame: CGRect
        if let spot {
            frame = spot
        } else {
            crowded = 1
            let x = min(max(inside.x, margin), screen.width - s.width - margin)
            let y = min(max(inside.y, top), screen.height - s.height - margin)
            frame = CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        chip.frame = frame
        taken.append(frame)
        // A leader only when the chip left its box's edge.
        if !frame.intersects(r.insetBy(dx: -4, dy: -4)) {
            let from = CGPoint(x: frame.minX + 4, y: frame.midY < r.midY ? frame.maxY : frame.minY)
            let to = CGPoint(x: min(max(from.x, r.minX), r.maxX), y: frame.midY < r.midY ? r.minY : r.maxY)
            chip.leader = [from, to]
        }
        return crowded
    }
}

/// The Detection view window and its pooled layers. Main thread only.
final class DetectionViewOverlay {
    /// Render budget per trace (layout + layer update, main thread).
    /// MEASURED 2026-09-24 on an M1 Mac, headless offscreen layer tree,
    /// `SENTRY_UI_SELFTEST_CASE=detection-view` "render cost": a 69-box
    /// stress trace (every style, two windows, overflow HUD) costs median
    /// 2.6–3.0 ms, max 4.1–5.3 ms over 30 draws.
    /// DERIVED limit: 16 ms is one 60 Hz
    /// frame of main-thread time, ~3x the measured worst case, so healthy
    /// drawing never reaches it. MEASURED on a test Mac 2026-09-25: the same
    /// self-test median 2.03–2.07 / max 2.96–3.42 ms, and live `drawMs`
    /// max 4.9 ms over 25 snapshots.
    /// Exceeding it is a TRIPWIRE:
    /// the HUD names it and one `detection-view` record is written per
    /// episode; the view keeps drawing.
    static let renderBudgetMs: Double = 16

    let window: NSWindow?
    let root = CALayer()
    /// Everything drawn. Visibility lives here, not on `root`: AppKit owns
    /// the hidden state of a view's own layer and un-hides it on assignment.
    private let content = CALayer()
    private(set) var size: CGSize
    private let scale: CGFloat
    private let outlines = CALayer()
    private let leaders = CALayer()
    private let chips = CALayer()
    private let chrome = CALayer()
    /// One group per outline: a dark halo under the coloured stroke, so a
    /// line reads on light and dark content alike.
    private var outlinePool: [(group: CALayer, halo: CAShapeLayer, ink: CAShapeLayer)] = []
    private var leaderPool: [CAShapeLayer] = []
    private var chipPool: [ChipLayers] = []
    private let hud = ChipLayers()
    private let legend = ChipLayers()
    private var legendSwatches: [CAShapeLayer] = []
    private let badge = ChipLayers()
    private(set) var lastLayout = DetectionViewLayout()

    /// Chip layers actually on screen (the self-test reads the layer tree).
    var drawnChipCount: Int { chipPool.filter { !$0.bg.isHidden }.count }

    var windowNumber: Int? { window.map(\.windowNumber) }

    /// `window: nil` renders into `root` alone (the self-test's PNG).
    init(size: CGSize, scale: CGFloat, window: NSWindow?) {
        self.size = size
        self.scale = scale
        self.window = window
        root.frame = CGRect(origin: .zero, size: size)
        content.frame = root.bounds
        root.addSublayer(content)
        for l in [outlines, leaders, chips, chrome] {
            l.frame = root.bounds
            content.addSublayer(l)
        }
        for c in [hud, legend, badge] { chrome.addSublayer(c.bg) }
        content.isHidden = true
        if let host = window?.contentView {
            host.layer = root
            host.wantsLayer = true
        }
    }

    /// The window rules every overlay answers to (SPEC §8, UIOverlayWindow):
    /// click-through, the cover window's level (never the popover's, which
    /// sits one above so a prompt is never under an overlay), every Space.
    static func makeWindow(frame: CGRect) -> NSWindow {
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.level = .screenSaver
        win.ignoresMouseEvents = UIOverlayWindow.ignoresMouseEvents(hasControls: false)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        return win
    }

    /// Puts the (still hidden) window on screen just above the cover window,
    /// so SCShareableContent lists it and capture can exclude it.
    func present(above coverWindow: Int?) {
        guard let window else { return }
        if let coverWindow {
            window.order(.above, relativeTo: coverWindow)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Hidden layers draw nothing; the window stays on screen so its number
    /// (and the capture exclusion) stays valid.
    func setVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.isHidden = !visible
        CATransaction.commit()
        if !visible { CATransaction.flush() }
    }

    var isVisible: Bool { !content.isHidden }

    /// The red "Protection off" badge is drawn and visible right now — the
    /// one condition under which Detections only may hide covers.
    var showsDangerBadge: Bool { isVisible && lastLayout.badgeDanger && !lastLayout.badge.lines.isEmpty }

    func close() {
        setVisible(false)
        window?.orderOut(nil)
    }

    /// Lays out and draws one trace (nil: none yet — badge, legend and a
    /// waiting HUD); returns the milliseconds it took.
    @discardableResult
    func render(_ trace: DetectionTrace?, options: DetectionViewLayout.Options) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        let layout = DetectionViewLayout.make(trace, size: size, options: options)
        apply(layout)
        lastLayout = layout
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// Top-left layout rect → the layer tree's bottom-left space.
    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }

    private func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }

    private func apply(_ L: DetectionViewLayout) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        while outlinePool.count < L.items.count {
            let group = CALayer(), halo = CAShapeLayer(), ink = CAShapeLayer()
            group.addSublayer(halo)
            group.addSublayer(ink)
            outlines.addSublayer(group)
            outlinePool.append((group, halo, ink))
        }
        let leaderCount = L.items.filter { $0.chipShown && $0.chip.leader != nil }.count
        grow(&leaderPool, to: leaderCount, in: leaders)
        while chipPool.count < L.items.count {
            let c = ChipLayers()
            chips.addSublayer(c.bg)
            chipPool.append(c)
        }
        var leaderIndex = 0
        for (i, item) in L.items.enumerated() {
            let path = CGPath(rect: flip(item.outline), transform: nil)
            let (group, halo, ink) = outlinePool[i]
            group.isHidden = false
            stroke(halo, path: path, color: CGColor(gray: 0, alpha: item.ink.faint ? 0.3 : 0.55),
                width: item.ink.width + 2, dash: item.ink.dash)
            stroke(ink, path: path, color: item.ink.color, width: item.ink.width, dash: item.ink.dash)
            guard item.chipShown else {
                chipPool[i].bg.isHidden = true
                continue
            }
            chipPool[i].show(frame: flip(item.chip.frame), lines: item.chip.lines, accent: item.ink.color,
                faint: item.ink.faint, scale: scale, style: .chip)
            if let leader = item.chip.leader {
                let l = leaderPool[leaderIndex]
                leaderIndex += 1
                let p = CGMutablePath()
                p.move(to: flip(leader[0]))
                p.addLine(to: flip(leader[1]))
                l.isHidden = false
                stroke(l, path: p, color: item.ink.color, width: 1, dash: [])
            }
        }
        for i in L.items.count..<outlinePool.count { outlinePool[i].group.isHidden = true }
        for i in L.items.count..<chipPool.count { chipPool[i].bg.isHidden = true }
        for i in leaderIndex..<leaderPool.count { leaderPool[i].isHidden = true }

        hud.show(frame: flip(L.hud.frame), lines: L.hud.lines, accent: DetectionViewInk.rgb(100, 210, 255),
            faint: false, scale: scale, style: .panel(warnings: L.hudWarnings))
        legend.show(frame: flip(L.legend.frame), lines: L.legend.lines, accent: nil, faint: false, scale: scale,
            style: .legend(swatches: L.legendInks.count))
        grow(&legendSwatches, to: L.legendInks.count, in: legend.bg)
        let legendFrame = flip(L.legend.frame)
        for (i, ink) in L.legendInks.enumerated() {
            // Row i + 1 (row 0 is the title): the same centre as its text row.
            let y = ChipLayers.legendRowY(i + 1, panelHeight: legendFrame.height)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 10, y: y))
            p.addLine(to: CGPoint(x: 10 + DetectionViewLayout.swatchWidth, y: y))
            legendSwatches[i].isHidden = false
            stroke(legendSwatches[i], path: p, color: ink.color, width: min(ink.width, 3), dash: ink.dash)
        }
        if L.badge.lines.isEmpty {
            badge.bg.isHidden = true
        } else {
            badge.show(frame: flip(L.badge.frame), lines: L.badge.lines, accent: nil, faint: false, scale: scale,
                style: .badge(danger: L.badgeDanger))
        }
    }

    private func stroke(_ l: CAShapeLayer, path: CGPath, color: CGColor, width: CGFloat, dash: [CGFloat]) {
        l.path = path
        l.fillColor = nil
        l.strokeColor = color
        l.lineWidth = width
        l.lineDashPattern = dash.isEmpty ? nil : dash.map { NSNumber(value: Double($0)) }
        l.lineCap = dash == [1, 5] || dash == [1, 4] ? .round : .butt
        l.contentsScale = scale
    }

    private func grow(_ pool: inout [CAShapeLayer], to n: Int, in parent: CALayer) {
        while pool.count < n {
            let l = CAShapeLayer()
            parent.addSublayer(l)
            pool.append(l)
        }
    }

    /// PNG of the layer tree over `backdrop` (self-test only).
    func pngData(backdrop: (CGContext, CGSize) -> Void) -> Data? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        backdrop(ctx, size)
        let wasHidden = content.isHidden
        content.isHidden = false
        root.render(in: ctx)
        content.isHidden = wasHidden
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// One text panel: background, optional left accent bar, text.
final class ChipLayers {
    /// Centre of legend row `i` (0 = title), bottom-up inside the panel:
    /// 6 pt top padding, then `legendRow` per row. A 12 pt line is ~15 pt
    /// tall, so a row's layer holds its glyphs with room to spare.
    static func legendRowY(_ i: Int, panelHeight: CGFloat) -> CGFloat {
        panelHeight - 6 - DetectionViewLayout.legendRow * (CGFloat(i) + 0.5)
    }

    enum Style: Equatable {
        case chip
        case panel(warnings: Set<Int>)
        /// Rows after the swatch rows are notes, drawn grey.
        case legend(swatches: Int)
        case badge(danger: Bool)
    }

    let bg = CALayer()
    private let accent = CALayer()
    private let text = CATextLayer()
    /// Legend only: one layer per row, so each row sits at exactly the y its
    /// swatch is drawn at (CATextLayer does not honour a fixed line height).
    private var rows: [CATextLayer] = []

    init() {
        bg.cornerRadius = 5
        bg.masksToBounds = true
        bg.addSublayer(accent)
        bg.addSublayer(text)
        text.isWrapped = true
        text.truncationMode = .none
    }

    func show(frame: CGRect, lines: [String], accent tint: CGColor?, faint: Bool, scale: CGFloat, style: Style) {
        bg.isHidden = false
        bg.frame = frame
        text.contentsScale = scale
        let white = CGColor(gray: 1, alpha: 1)
        let soft = CGColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = DetectionViewLayout.lineHeight
        para.maximumLineHeight = DetectionViewLayout.lineHeight
        let out = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont, _ color: CGColor, _ p: NSParagraphStyle = para) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: color) ?? .white, .paragraphStyle: p,
            ]))
        }
        switch style {
        case .chip:
            bg.backgroundColor = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: faint ? 0.62 : 0.84)
            bg.borderWidth = 0
            accent.isHidden = tint == nil
            accent.backgroundColor = tint
            accent.frame = CGRect(x: 0, y: 0, width: 3, height: frame.height)
            for (i, l) in lines.enumerated() {
                add(l, i == 0 ? DetectionViewLayout.chipTitleFont : DetectionViewLayout.chipFont,
                    faint ? CGColor(gray: 0.85, alpha: 0.9) : (i == 0 ? white : soft))
            }
            let p = DetectionViewLayout.chipPad
            text.frame = CGRect(x: p.left, y: p.bottom - 1, width: frame.width - p.left - p.right + 2,
                height: frame.height - p.top - p.bottom + 1)
        case let .panel(warnings):
            bg.backgroundColor = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.86)
            bg.borderWidth = 0
            accent.isHidden = tint == nil
            accent.backgroundColor = tint
            accent.frame = CGRect(x: 0, y: 0, width: 3, height: frame.height)
            for (i, l) in lines.enumerated() {
                add(l, DetectionViewLayout.panelFont,
                    warnings.contains(i) ? DetectionViewInk.rgb(255, 184, 0) : soft)
            }
            text.frame = CGRect(x: 10, y: 4, width: frame.width - 16, height: frame.height - 8)
        case let .legend(swatches):
            bg.backgroundColor = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.86)
            bg.borderWidth = 0
            accent.isHidden = true
            // Swatches at x 10 (the overlay draws them); text starts right of
            // them. Row i's frame is the same `legendRowY` its swatch uses.
            let column = 10 + DetectionViewLayout.swatchWidth + 8
            while rows.count < lines.count {
                let r = CATextLayer()
                r.truncationMode = .none
                bg.addSublayer(r)
                rows.append(r)
            }
            for (i, r) in rows.enumerated() {
                r.isHidden = i >= lines.count
                guard i < lines.count else { continue }
                let isTitle = i == 0, isNote = i > swatches
                r.contentsScale = scale
                r.string = NSAttributedString(string: lines[i], attributes: [
                    .font: isTitle ? DetectionViewLayout.legendTitleFont : DetectionViewLayout.legendFont,
                    .foregroundColor: NSColor(cgColor: isNote ? CGColor(gray: 0.75, alpha: 1) : white) ?? .white,
                ])
                let y = ChipLayers.legendRowY(i, panelHeight: frame.height)
                r.frame = CGRect(x: column, y: y - DetectionViewLayout.legendRow / 2, width: frame.width - column - 4,
                    height: DetectionViewLayout.legendRow)
            }
            text.string = nil
            return
        case let .badge(danger):
            bg.backgroundColor = danger
                ? CGColor(srgbRed: 0.80, green: 0.04, blue: 0.10, alpha: 0.96)
                : CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.90)
            bg.borderWidth = danger ? 0 : 1
            bg.borderColor = DetectionViewInk.rgb(100, 210, 255)
            bg.cornerRadius = 8
            accent.isHidden = true
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            center.minimumLineHeight = 18
            center.maximumLineHeight = 18
            for (i, l) in lines.enumerated() {
                add(l, i == 0 ? DetectionViewLayout.badgeFont : DetectionViewLayout.badgeSubFont,
                    white, center)
            }
            text.frame = CGRect(x: 8, y: (frame.height - CGFloat(lines.count) * 18) / 2 - 1,
                width: frame.width - 16, height: CGFloat(lines.count) * 18 + 2)
        }
        text.string = out
    }
}
