import AppKit

struct SpotlightHole: Equatable {
    let rect: NSRect
    let cornerRadius: CGFloat
}

/// The guide surface is selected by the caller that knows whether the app
/// entry is missing. Presentation stays separate from the TCC request that
/// creates the entry, so opening a guide can never raise a second system
/// prompt as a side effect.
enum ScreenRecordingGuideMode: Equatable, Sendable {
    case spotlight
    case spotlightWithAddHelper
}

/// Walkthrough-style dim while the parent fixes Screen Recording (OWNER
/// 2026-08-26): after Fix…, everything on every screen dims except the
/// System Settings window, so the eye lands on the pane. Click-through by
/// construction, so it never gets in the way of the toggle.
///
/// What it deliberately does NOT do: highlight the SentryScreen ROW inside
/// the list. Reading row positions inside another app's window needs the
/// Accessibility API — a second TCC grant, itself revocable by the kid, and
/// brittle across macOS versions — whereas window geometry comes free from
/// `CGWindowListCopyWindowInfo` (bounds + owner PID need no permission at
/// all; only window NAMES need Screen Recording, and we may not have it).
final class FixSpotlight {
    static let shared = FixSpotlight()

    private var windows: [NSWindow] = []
    private var dims: [DimView] = []
    private var timer: Timer?
    private var startedAt: CFAbsoluteTime = 0
    private var everSaw = false
    private var guideMode: ScreenRecordingGuideMode?
    private var mainSettingsWindowID: CGWindowID?
    private var securePromptOverlayVisible = false

    /// Dim strength. DERIVED: macOS's own permission-sheet backdrop reads
    /// ~45–55 % black; 0.5 keeps the desktop legible so it reads as a
    /// guide, not a lock.
    static let dimAlpha: CGFloat = 0.5
    /// Cutout tracking rate. MEASURED live 2026-08-26: at 20 Hz the hole
    /// visibly chased a dragged Settings window. 60 Hz matches the display.
    /// Affordable on the MEASURED cost of the API this file actually uses
    /// (receipt at `rects(of:)`, corrected 2026-08-28 — the earlier version
    /// of this comment still cited `CGWindowListCreateDescriptionFromArray`,
    /// which returned an EMPTY array and was removed): one
    /// `CGWindowListCopyWindowInfo(.optionIncludingWindow, id)` per CACHED id
    /// at 0.26 ms/id, over the handful of ids a cutout set holds (System
    /// Settings + the auth/alert passthroughs + the frontmost app), so a tick
    /// stays well inside the 16.7 ms frame. The full on-screen walk —
    /// MEASURED 1.0 ms on an M1 Mac, the same probe — runs only every
    /// `discoverEvery` ticks (10 Hz).
    static let pollHz: Double = 60
    static let discoverEvery = 6
    /// Window-shape profiles. RECEIPT 2026-09-04: the live 2x render showed
    /// the old 16-point hole leaving a bright crescent outside the 24-point
    /// macOS 26 System Settings corner. System dialogs remain tighter. The
    /// half-point inset keeps the dim on the antialiased outer edge instead
    /// of exposing wallpaper through a fractional WindowServer bound.
    static let settingsCornerRadius: CGFloat = 24
    static let auxiliaryCornerRadius: CGFloat = 18
    static let cutoutInset: CGFloat = 0.5
    private var tickCount = 0
    private var cutoutIDs: [CGWindowID] = []
    private var settingsIDs: [CGWindowID] = []
    /// Give-up budgets, both fail loudly to stderr/ui log via `onEnd`:
    /// System Settings never appeared (the URL handler stalled) — 10 s; the
    /// parent walked away — 120 s, after which a dimmed desktop is a bug.
    /// RE-DERIVED 2026-08-28: the 120 s used to be justified as "the same
    /// worst case as `captureLossRelaunchSecs`", which the merge cut to 30 s,
    /// so that derivation is dead. The value stands on its own budget instead
    /// — the walkthrough must outlast the whole fix (open the pane, unlock
    /// with the admin password, find the row, toggle, answer "Quit & Reopen"),
    /// ASSUMED at well under two minutes for a parent who is at the machine,
    /// while a parent who walked away gets the desktop back inside the two
    /// minutes it takes to notice. Value unchanged: nothing here is measured,
    /// so there is no ground to move it.
    static let appearSecs: TimeInterval = 10
    static let maxSecs: TimeInterval = 120
    static let settingsBundleID = "com.apple.systempreferences"
    static let loginWindowBundleID = "com.apple.loginwindow"
    /// Windows that must never be dimmed even though System Settings does
    /// not own them. MEASURED live 2026-08-26: toggling the switch on
    /// raises the admin-password sheet (SecurityAgent / LocalAuthentication
    /// UI agent), then the "Quit & Reopen" alert (UserNotificationCenter,
    /// on behalf of tccd) — both were under the dim. The FRONTMOST app's
    /// windows are also cut out, as a catch-all for whichever process a
    /// future macOS uses for these.
    static let passthroughBundleIDs: Set<String> = [
        settingsBundleID,
        "com.apple.SecurityAgent",
        "com.apple.coreautha",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.UserNotificationCenter",
        // MEASURED 2026-09-04, macOS 26: CGRequestScreenCaptureAccess uses
        // this owner for its Open System Settings / Deny warning and places
        // a secure loginwindow layer behind it.
        "com.apple.accessibility.universalAccessAuthWarn",
    ]

    /// Log hook (reason string); set by main.swift.
    var onEnd: ((String) -> Void)?
    private let helper = AddEntryHelper()

    func begin(mode: ScreenRecordingGuideMode) {
        // A second caller may refine the presentation while the same guide
        // is open. In particular, spotlight-only must remove a helper that
        // an earlier missing-entry route showed.
        guard windows.isEmpty else {
            guideMode = mode
            if mode == .spotlight { helper.hide() }
            return
        }
        guideMode = mode
        mainSettingsWindowID = nil
        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Just under the toast/status-bar level: menu bar, toast and the
            // popover (screenSaver+1) all stay bright and clickable.
            win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            // Click-through (SPEC §8, UIOverlayWindow): the dim carries no
            // control — the helper card is its own window.
            win.ignoresMouseEvents = UIOverlayWindow.ignoresMouseEvents(hasControls: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let view = DimView(frame: NSRect(origin: .zero, size: screen.frame.size))
            win.contentView = view
            win.orderFrontRegardless()
            windows.append(win)
            dims.append(view)
        }
        startedAt = CFAbsoluteTimeGetCurrent()
        everSaw = false
        tickCount = 0
        tick()
        let trackingTimer = Timer(timeInterval: 1 / Self.pollHz, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(trackingTimer, forMode: .common)
        timer = trackingTimer
    }

    func end(_ reason: String) {
        guard !windows.isEmpty else { return }
        timer?.invalidate(); timer = nil
        helper.hide()
        for win in windows { win.orderOut(nil) }
        windows = []; dims = []
        guideMode = nil
        mainSettingsWindowID = nil
        settingsIDs = []
        cutoutIDs = []
        securePromptOverlayVisible = false
        onEnd?(reason)
    }

    private func tick() {
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        if tickCount % Self.discoverEvery == 0 {
            securePromptOverlayVisible = Self.securePromptOverlayIsVisible()
            settingsIDs = Self.windowIDs(ofBundleIDs: [Self.settingsBundleID])
            cutoutIDs = Self.windowIDs(ofBundleIDs: cutoutBundleIDs())
        }
        tickCount += 1
        let settings = Self.windowBounds(of: settingsIDs)
        if !settings.isEmpty { everSaw = true }
        if everSaw && settings.isEmpty { end("System Settings closed"); return }
        let bounds = Self.windowBounds(of: cutoutIDs)
        let settingsIDSet = Set(settingsIDs)

        // Track one concrete WindowServer id, not one captured CGRect. The
        // Quit & Reopen alert can add another Settings-owned window, while
        // the main Settings window can move and resize throughout the flow.
        if let tracked = mainSettingsWindowID,
            !settings.contains(where: { $0.id == tracked }) {
            mainSettingsWindowID = nil
        }
        if mainSettingsWindowID == nil {
            mainSettingsWindowID = settings.max(by: {
                $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height
            })?.id
        }
        if guideMode == .spotlightWithAddHelper,
            let mainSettingsWindowID,
            let main = settings.first(where: { $0.id == mainSettingsWindowID }) {
            if helperMayBeVisibleForFrontmostApp() {
                helper.place(anchor: main.rect)
            } else {
                helper.suspend()
            }
        } else {
            helper.hide()
        }
        if !everSaw && elapsed > Self.appearSecs {
            end("System Settings did not appear within budget FixSpotlight.appearSecs=\(Int(Self.appearSecs))s")
            return
        }
        if elapsed > Self.maxSecs {
            end("budget FixSpotlight.maxSecs=\(Int(Self.maxSecs))s reached")
            return
        }
        // Cut the holes. CG window bounds are top-left origin in global
        // screen space; each overlay view is bottom-left origin in its own
        // screen — convert per screen. Holes are punched with destinationOut
        // so OVERLAPPING windows (an alert over its parent) stay clear — an
        // even-odd mask re-dimmed the overlap (MEASURED live 2026-08-26).
        for (i, win) in windows.enumerated() {
            guard let screen = NSScreen.screens.first(where: { $0.frame == win.frame }) ?? win.screen
            else { continue }
            let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
            dims[i].holes = bounds.map { item in
                let r = item.rect
                let local = NSRect(x: r.minX - screen.frame.minX,
                    y: (mainH - r.maxY) - screen.frame.minY,
                    width: r.width, height: r.height)
                    .insetBy(dx: Self.cutoutInset, dy: Self.cutoutInset)
                return SpotlightHole(
                    rect: local,
                    cornerRadius: settingsIDSet.contains(item.id)
                        ? Self.settingsCornerRadius
                        : Self.auxiliaryCornerRadius)
            }
        }
    }

    /// Cutout set: System Settings, the active auth/alert agents, and the
    /// frontmost app (catch-all). Some prompt owners keep an invisible window
    /// after dismissal, so they remain cutouts only while the secure overlay
    /// proves that a prompt still controls the desktop.
    private func cutoutBundleIDs() -> Set<String> {
        var ids: Set<String> = [Self.settingsBundleID]
        if securePromptOverlayVisible {
            ids.formUnion(Self.passthroughBundleIDs)
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            front != Bundle.main.bundleIdentifier { ids.insert(front) }
        return ids
    }

    /// Show the helper only when Settings is frontmost and no secure prompt
    /// controls the desktop. Showing our helper beside the native warning
    /// creates two competing calls to action. After the parent selects Open
    /// System Settings, the secure overlay clears and the helper appears.
    private func helperMayBeVisibleForFrontmostApp() -> Bool {
        return Self.helperMayBeVisible(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            securePromptOverlayVisible: securePromptOverlayVisible)
    }

    nonisolated static func helperMayBeVisible(
        frontmostBundleID: String?,
        securePromptOverlayVisible: Bool
    ) -> Bool {
        frontmostBundleID == settingsBundleID && !securePromptOverlayVisible
    }

    /// macOS 26 places a full-screen, high-layer loginwindow surface behind
    /// the Screen Recording warning. The prompt owner's ordinary window can
    /// remain on-screen after dismissal, but this secure overlay does not.
    static func securePromptOverlayIsVisible() -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: loginWindowBundleID).map(\.processIdentifier))
        guard !pids.isEmpty,
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                pids.contains(pid),
                let layer = window[kCGWindowLayer as String] as? Int,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            return layer >= 24 && width > 100 && height > 100
        }
    }

    /// On-screen window ids of the given apps, any layer below the menu
    /// bar (24; dialogs sit above 0), skipping tooltip-sized helpers.
    static func windowIDs(ofBundleIDs ids: Set<String>) -> [CGWindowID] {
        windowIDs(ofPIDs: Set(ids.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        }))
    }

    static func windowIDs(ofPIDs pids: Set<pid_t>) -> [CGWindowID] {
        guard !pids.isEmpty,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 24,
                let id = w[kCGWindowNumber as String] as? CGWindowID,
                let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                let wd = b["Width"], let ht = b["Height"], wd > 100, ht > 100
            else { return nil }
            return id
        }
    }

    /// Current bounds of known ids (global CG coords); ids that vanished
    /// between discoveries simply drop out. One `.optionIncludingWindow`
    /// call per id — MEASURED 2026-08-26 (scratch probe, an M1 Mac):
    /// 0.26 ms/id; `CGWindowListCreateDescriptionFromArray` returned an
    /// EMPTY array for the same ids (both CGWindowID and NSNumber arrays),
    /// which is the regression that left the dim with no hole.
    struct WindowBounds {
        let id: CGWindowID
        let rect: CGRect
    }

    static func windowBounds(of ids: [CGWindowID]) -> [WindowBounds] {
        ids.compactMap { id in
            guard let w = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
                (w[kCGWindowIsOnscreen as String] as? Bool) ?? true,
                let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"]
            else { return nil }
            return WindowBounds(id: id, rect: CGRect(x: x, y: y, width: wd, height: ht))
        }
    }

    static func rects(of ids: [CGWindowID]) -> [CGRect] {
        windowBounds(of: ids).map(\.rect)
    }
}

/// Full-screen dim with punched-out windows.
final class DimView: NSView {
    var holes: [SpotlightHole] = [] { didSet { if holes != oldValue { needsDisplay = true } } }
    /// CG `.clear` blend, not NSBezierPath + `.destinationOut`: MEASURED
    /// 2026-08-26 (offscreen cacheDisplay probe) the latter left the hole
    /// at alpha 0.50 — no hole at all, which is the "dims but no cutout"
    /// regression the owner saw. `.clear` verified on-screen (pixel probe: hole
    /// luminance unchanged, outside halved).
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(FixSpotlight.dimAlpha).cgColor)
        ctx.fill(bounds)
        ctx.setBlendMode(.clear)
        for hole in holes {
            ctx.addPath(CGPath(roundedRect: hole.rect,
                cornerWidth: hole.cornerRadius,
                cornerHeight: hole.cornerRadius,
                transform: nil))
        }
        ctx.fillPath()
        ctx.setBlendMode(.normal)
    }
}

/// "Not in the list?" drag helper (OWNER 2026-08-26, modelled on Codex's
/// add-permission flow): a small panel beside System Settings holding the
/// app icon; dragging it onto the Screen Recording list adds the
/// SentryScreen.app row, after which the parent flips the switch. The
/// pasteboard item is the bundle's file URL — exactly what the "+" button's
/// open panel would produce. Shown only when running from the installed
/// bundle (a bare dev binary has no .app to drag).
final class AddEntryHelper: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    /// RECEIPT 2026-09-04: the live 220-by-150 helper compressed the icon and
    /// two text lines into an old utility-panel stack. This size fits one
    /// horizontal transfer demonstration plus two short copy lines.
    static let sizePt = NSSize(width: 320, height: 200)
    static let gapPt: CGFloat = 12
    static let title = "Can’t find SentryScreen?"
    static let instruction = "Drag the large SentryScreen icon into the open Settings list."

    static var bundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// The panel's close box was used; stays closed for this guide.
    private var closedByUser = false

    func place(anchor settings: CGRect) {
        guard let url = Self.bundleURL, !closedByUser else { return }
        if panel == nil {
            panel = Self.make(url: url)
            panel?.delegate = self
        }
        guard let panel else { return }
        // CG (top-left) → AppKit (bottom-left, main screen height).
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let settingsAK = NSRect(x: settings.minX, y: mainH - settings.maxY,
            width: settings.width, height: settings.height)
        var x = settingsAK.maxX + Self.gapPt
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(settingsAK) }),
            x + Self.sizePt.width > screen.visibleFrame.maxX {
            x = settingsAK.minX - Self.gapPt - Self.sizePt.width
        }
        let origin = NSPoint(x: x, y: settingsAK.maxY - Self.sizePt.height)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Temporarily remove the status-level panel without treating the action
    /// as a user dismissal. It can return when Settings or an authorization
    /// prompt becomes frontmost again.
    func suspend() {
        panel?.orderOut(nil)
    }

    func hide() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        closedByUser = false
    }

    func windowWillClose(_ notification: Notification) {
        closedByUser = true
    }

    /// Read the installed bundle's own resource first. LaunchServices can
    /// retain an older file icon after an in-place install; the .icns
    /// resource is authoritative and preserves its transparent background.
    static func iconImage(forBundleURL url: URL) -> NSImage {
        if let bundle = Bundle(url: url),
            let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
            let resources = bundle.resourceURL {
            let iconPath = iconName.hasSuffix(".icns") ? iconName : iconName + ".icns"
            if let image = NSImage(contentsOf: resources.appendingPathComponent(iconPath)) {
                image.isTemplate = false
                return image
            }
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.isTemplate = false
        return image
    }

    private static func make(url: URL) -> NSPanel {
        // Keep the native utility title bar and close behavior, then use the
        // app's dark surface and amber transfer cue inside it. The panel stays
        // visually related to System Settings without becoming an unbranded
        // default stack.
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: sizePt),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Add SentryScreen"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: NSRect(origin: .zero, size: sizePt))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(
            srgbRed: 17 / 255, green: 19 / 255, blue: 21 / 255, alpha: 1).cgColor

        let guide = TransferGuideView(url: url)
        let title = NSTextField(labelWithString: Self.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = NSColor(
            srgbRed: 241 / 255, green: 242 / 255, blue: 243 / 255, alpha: 1)
        title.alignment = .center
        let body = NSTextField(wrappingLabelWithString: Self.instruction)
        body.font = .systemFont(ofSize: 12)
        body.textColor = NSColor(
            srgbRed: 194 / 255, green: 198 / 255, blue: 202 / 255, alpha: 1)
        body.alignment = .center
        body.maximumNumberOfLines = 2
        body.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [guide, title, body])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            guide.widthAnchor.constraint(equalToConstant: TransferGuideView.sizePt.width),
            guide.heightAnchor.constraint(equalToConstant: TransferGuideView.sizePt.height),
        ])
        panel.contentView = content
        return panel
    }
}

/// One purposeful motion: a small duplicate of the app icon travels toward a
/// compact representation of the Screen Recording list. The real 56-point
/// icon stays still and draggable. Reduce Motion keeps the same instruction
/// visible without the loop.
final class TransferGuideView: NSView {
    static let sizePt = NSSize(width: 284, height: 78)

    private let ghost = CALayer()

    init(url: URL) {
        super.init(frame: NSRect(origin: .zero, size: Self.sizePt))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 12

        let iconImage = AddEntryHelper.iconImage(forBundleURL: url)
        let icon = DraggableAppIcon(url: url)
        icon.frame = NSRect(x: 14, y: 11, width: 56, height: 56)
        addSubview(icon)

        let target = SettingsListTargetView(frame: NSRect(x: 214, y: 11, width: 56, height: 56))
        addSubview(target)

        let arrow = NSTextField(labelWithString: "›   ›   ›")
        arrow.font = .systemFont(ofSize: 18, weight: .semibold)
        arrow.textColor = NSColor(
            srgbRed: 226 / 255, green: 180 / 255, blue: 92 / 255, alpha: 1)
        arrow.alignment = .center
        arrow.frame = NSRect(x: 83, y: 7, width: 118, height: 25)
        addSubview(arrow)

        ghost.contents = iconImage
        ghost.contentsGravity = .resizeAspect
        ghost.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ghost.frame = NSRect(x: 82, y: 38, width: 28, height: 28)
        layer?.addSublayer(ghost)
        startMotion()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drag SentryScreen toward the Screen Recording list")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func startMotion() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ghost.position.x = 184
            ghost.opacity = 0.9
            return
        }
        let position = CAKeyframeAnimation(keyPath: "position.x")
        position.values = [96, 176, 194]
        position.keyTimes = [0, 0.72, 1]
        position.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
        ]
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.2, 1, 0]
        opacity.keyTimes = [0, 0.72, 1]
        let group = CAAnimationGroup()
        group.animations = [position, opacity]
        group.duration = 1.8
        group.beginTime = CACurrentMediaTime() + 0.35
        group.repeatCount = .infinity
        ghost.add(group, forKey: "transfer")
    }
}

/// A small, recognisable target: the rounded System Settings pane with three
/// list rows and their toggles. It avoids using another app's artwork while
/// making the destination clearer than a generic gear glyph.
final class SettingsListTargetView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        NSColor(
            srgbRed: 241 / 255, green: 242 / 255, blue: 243 / 255, alpha: 0.96).setFill()
        outer.fill()
        NSColor(
            srgbRed: 194 / 255, green: 198 / 255, blue: 202 / 255, alpha: 0.9).setStroke()
        outer.lineWidth = 1
        outer.stroke()

        for row in 0..<3 {
            let y = CGFloat(13 + row * 15)
            let line = NSBezierPath(roundedRect: NSRect(x: 8, y: y, width: 22, height: 4),
                xRadius: 2, yRadius: 2)
            NSColor(
                srgbRed: 86 / 255, green: 91 / 255, blue: 97 / 255, alpha: 0.72).setFill()
            line.fill()
            let toggle = NSBezierPath(roundedRect: NSRect(x: 35, y: y - 3, width: 14, height: 9),
                xRadius: 4.5, yRadius: 4.5)
            NSColor.systemBlue.withAlphaComponent(0.78).setFill()
            toggle.fill()
        }
    }
}

/// App icon that starts a file-URL drag of the bundle on mouse-down.
final class DraggableAppIcon: NSImageView, NSDraggingSource {
    private let url: URL
    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        image = AddEntryHelper.iconImage(forBundleURL: url)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel("SentryScreen app — drag into the Screen Recording list")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .link] : []
    }
}
