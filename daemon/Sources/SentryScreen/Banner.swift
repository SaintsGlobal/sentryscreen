import AppKit
import SwiftUI

/// SPEC §8's core safety property in one place, for every window this app
/// puts on screen (2026-09-07). Two rules:
///
/// 1. A window is click-through (`ignoresMouseEvents = true`) unless it
///    carries a control the family must be able to click. Covers
///    (`Overlay.swift`), the repair dim (`FixSpotlight.swift`) and the
///    informational toasts (`StatusToast`, the license notice) carry none,
///    so a click lands in the app behind them — the worst failure is
///    "cannot see", never "cannot act".
/// 2. A window that IS interactive is never larger than the pixels it draws.
///    The capture-loss toast and the dunning toast used a panel that spanned
///    from the card's top edge up to the menu bar, to clip a slide-in: the
///    extra 12 pt (`CaptureLossBanner.topGapPt`) drew nothing and swallowed
///    every click that landed in it, on every display, for as long as
///    capture was down. An invisible window that eats clicks is the same
///    defect as a cover that eats them.
///
/// Scope: every borderless always-on-top surface this app creates — the
/// region covers, the repair dim, the three menu-bar toasts, and the
/// Detection view (click-through, checked in `--ui-selftest`
/// group `detection-view`). Ordinary
/// titled windows the parent can move and close (the Setup window,
/// `FixSpotlight`'s "Add SentryScreen" panel) are app windows, not overlays,
/// and are outside it.
///
/// The rules are functions, not comments, so `--ui-selftest` can falsify
/// them (`UISelfTest.caseCaptureAlertAndOverlayWindows`) and every
/// construction site reads its answer from here.
enum UIOverlayWindow {
    /// Rule 1. `hasControls`: the window hosts a button, a ✕, or anything
    /// else a click must reach.
    static func ignoresMouseEvents(hasControls: Bool) -> Bool { !hasControls }

    /// Rule 2. Frame for a menu-bar toast: `card` is the drawn card, at its
    /// settled position; `screenTopY` is the menu bar's bottom edge
    /// (`NSScreen.visibleFrame.maxY`). A click-through toast gets the taller
    /// clip box, so its content can slide down out of the menu bar; an
    /// interactive one gets exactly its card and slides in from its own top
    /// edge. Either way the content starts one frame-height up and animates
    /// to `.zero` inside the clip.
    static func toastFrame(card: NSRect, screenTopY: CGFloat, hasControls: Bool) -> NSRect {
        guard !hasControls else { return card }
        return NSRect(x: card.minX, y: card.minY,
            width: card.width, height: max(card.height, screenTopY - card.minY))
    }
}

// MARK: - Toast model

/// One toast, as data. Boards: Notices-Toasts and Notices-Toasts-Night.
///
/// - `.problem`: stays until it is fixed (`ToastArbiter.withdraw`), acted on,
///   or closed with the ✕.
/// - `.notice`: good news or an FYI; hides after `StatusToast.showSecs`, has no
///   ✕, and is click-through unless it carries an action.
/// The ✕ is never counted as the action.
struct ToastSpec {
    enum Kind { case problem, notice }
    enum Tone { case danger, accent, quiet }
    enum Icon {
        /// The app icon, used only by "Protection is on" and "Key added".
        case appIcon
        case symbol(String, Tone)
    }
    struct Action {
        let label: String
        let accessibilityLabel: String
        let run: () -> Void
    }

    /// Stable per toast kind ("capture-loss"). The arbiter shows one toast per
    /// id and treats a second `present` of the same id as the same toast.
    let id: String
    let kind: Kind
    let icon: Icon
    let title: String
    var action: Action?
    var onDismiss: (() -> Void)?

    var dismissible: Bool { kind == .problem }
    /// UIOverlayWindow rule 1: a toast is click-through unless it has a control.
    var hasControls: Bool { action != nil || dismissible }
    var autoHideSecs: TimeInterval? { kind == .notice ? StatusToast.showSecs : nil }
}

/// The arbiter's decisions with no windows attached, so `--ui-selftest` can
/// falsify "one at a time". Size bound: entries are keyed by `ToastSpec.id`,
/// so `waiting` holds at most one entry per toast id the app can raise
/// (`capture-loss`, `protection-on`, `license-activation`, `panic` today);
/// there is no numeric cap to receipt or to overflow.
struct ToastQueue {
    private(set) var current: ToastSpec?
    private(set) var waiting: [ToastSpec] = []

    /// True when `spec` should be drawn now. Rules: nothing showing shows it;
    /// the same id and title as the one showing is that toast (no replay, so
    /// a repeated `CaptureLossBanner.show()` does not re-slide it); the same
    /// id with a new title is newer news about the same thing ("Key added",
    /// then a refusal) and replaces it; a problem replaces a notice, which is
    /// dropped because it is only news; everything else waits its turn,
    /// problems ahead of notices.
    mutating func offer(_ spec: ToastSpec) -> Bool {
        guard let shown = current else {
            current = spec
            return true
        }
        if shown.id == spec.id {
            guard shown.title != spec.title else { return false }
            current = spec
            return true
        }
        waiting.removeAll { $0.id == spec.id }
        if spec.kind == .problem && shown.kind == .notice {
            // Intended drop (a notice is only news), but never silent.
            FileHandle.standardError.write(Data(
                "{\"event\":\"toast\",\"reason\":\"notice-preempted\",\"dropped\":\"\(shown.id)\",\"by\":\"\(spec.id)\"}\n".utf8))
            current = spec
            return true
        }
        waiting.append(spec)
        return false
    }

    /// The showing toast is gone. Returns the next one to draw, problems first.
    mutating func finishCurrent() -> ToastSpec? {
        current = nil
        let index = waiting.firstIndex(where: { $0.kind == .problem }) ?? (waiting.isEmpty ? nil : 0)
        guard let index else { return nil }
        current = waiting.remove(at: index)
        return current
    }

    /// True when `id` was the showing toast and the caller must take it down.
    mutating func withdraw(id: String) -> Bool {
        waiting.removeAll { $0.id == id }
        guard current?.id == id else { return false }
        current = nil
        return true
    }
}

/// Where a toast is drawn. Boards: top right, just under the menu bar, on
/// every screen (was a 520-wide banner centred on each screen).
enum ToastGeometry {
    /// Board: the desktop pads the toast column 12 pt from the menu bar
    /// (`CaptureLossBanner.topGapPt`) and 14 pt from the right edge.
    static let rightMarginPt: CGFloat = 14
    /// Board: 3 pt ink edge and a 4-by-5 pt offset shadow with no blur.
    static let borderWidthPt: CGFloat = 3
    static let shadowOffset = CGSize(width: 4, height: 5)

    /// The rect the toast draws, card plus its offset shadow. An interactive
    /// panel is exactly this rect (UIOverlayWindow rule 2), and the shadow is
    /// pixels the toast draws, so no invisible click-eating strip remains.
    static func drawnFrame(visibleFrame v: NSRect) -> NSRect {
        let width = CaptureLossBanner.widthPt + shadowOffset.width
        let height = CaptureLossBanner.heightPt + shadowOffset.height
        return NSRect(
            x: v.maxX - rightMarginPt - CaptureLossBanner.widthPt,
            y: v.maxY - CaptureLossBanner.topGapPt - height,
            width: width, height: height)
    }
}

// MARK: - Arbiter

/// One toast on screen at a time, on every display. Owns the panels; the
/// capture-loss banner, the "Protection is on" toast and (once
/// `LicenseToast` moves onto it) the billing and activation toasts hand it a
/// `ToastSpec`. Main thread only.
///
/// Rules live in `ToastQueue`. Retiring a toast slides it out and only then
/// draws the next, so two never overlap. A stale slide-out completion is
/// ignored through `generation`.
final class ToastArbiter {
    static let shared = ToastArbiter()

    private var queue = ToastQueue()
    private var panels: ToastPanels?
    private var hideTimer: Timer?
    private var generation = 0

    /// The showing toast's id, for `--ui-selftest` and logs.
    var shownID: String? { queue.current?.id }

    func present(_ spec: ToastSpec) {
        if queue.offer(spec) { display(spec) }
    }

    /// The reason for a problem toast is gone (capture is back). Also removes
    /// it from the waiting line.
    func withdraw(id: String) {
        if queue.withdraw(id: id) { retire() }
    }

    private func display(_ spec: ToastSpec) {
        hideTimer?.invalidate()
        hideTimer = nil
        generation += 1
        panels?.removeNow()
        panels = nil
        guard let made = ToastPanels.make(
            spec: spec,
            onAction: { [weak self] in self?.acted(spec) },
            onClose: { [weak self] in self?.closed(spec) })
        else {
            // The screen list was empty (already reported on stderr). Drop
            // this toast and move on rather than block the line behind it.
            FileHandle.standardError.write(Data(
                "{\"event\":\"toast\",\"reason\":\"no-screens\",\"dropped\":\"\(spec.id)\"}\n".utf8))
            if let next = queue.finishCurrent() { display(next) }
            return
        }
        panels = made
        if let secs = spec.autoHideSecs {
            hideTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
                guard let self, self.queue.current?.id == spec.id else { return }
                self.retire()
            }
        }
    }

    /// Slides the showing toast out, then draws the next. False when it was
    /// already on its way out, which makes a double click run its action once.
    @discardableResult
    private func retire() -> Bool {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let shown = panels else { return false }
        panels = nil
        let gen = generation
        shown.slideOut { [weak self] in
            guard let self, gen == self.generation else { return }
            if let next = self.queue.finishCurrent() { self.display(next) }
        }
        return true
    }

    private func acted(_ spec: ToastSpec) {
        // The toast leaves once acted on. The action owns the one next
        // surface; the toast must not also open anything.
        guard queue.current?.id == spec.id, retire() else { return }
        spec.action?.run()
    }

    private func closed(_ spec: ToastSpec) {
        guard queue.current?.id == spec.id, retire() else { return }
        spec.onDismiss?()
    }
}

/// The panels for one toast, one per screen.
final class ToastPanels {
    private let panels: [NSPanel]

    private init(panels: [NSPanel]) { self.panels = panels }

    static func make(
        spec: ToastSpec, onAction: @escaping () -> Void, onClose: @escaping () -> Void
    ) -> ToastPanels? {
        // Every screen, not just main: capture can be lost EVERYWHERE, and the
        // person who needs to read this may be looking at any display.
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            // The fail-loud rail must not itself fail silently: no screens
            // means the toast cannot exist — say so where the log reader
            // and launchd stderr will both see it.
            let warning = "WARNING: toast '\(spec.id)' could not be shown — "
                + "NSScreen.screens is empty (fix: ToastPanels.make)\n"
            FileHandle.standardError.write(Data(warning.utf8))
            return nil
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var built: [NSPanel] = []
        for screen in screens {
            // visibleFrame.maxY is the menu bar's bottom edge.
            let drawn = ToastGeometry.drawnFrame(visibleFrame: screen.visibleFrame)
            let box = UIOverlayWindow.toastFrame(
                card: drawn, screenTopY: screen.visibleFrame.maxY, hasControls: spec.hasControls)
            let panel = NSPanel(
                contentRect: box,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // The card draws its own offset shadow; the system shadow would
            // outline the transparent corners of the panel.
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = UIOverlayWindow.ignoresMouseEvents(hasControls: spec.hasControls)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let clip = NSView(frame: NSRect(origin: .zero, size: box.size))
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            let content = ToastHostingView(
                rootView: ToastCardView(spec: spec, onAction: onAction, onClose: onClose))
            // The content starts one frame-height up and slides down into the clip.
            content.frame = NSRect(x: 0, y: reduceMotion ? 0 : box.height,
                width: drawn.width, height: drawn.height)
            clip.addSubview(content)
            panel.contentView = clip
            panel.orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = CaptureLossBanner.slideSecs
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    content.animator().setFrameOrigin(.zero)
                }
            }
            built.append(panel)
        }
        return ToastPanels(panels: built)
    }

    func removeNow() {
        for p in panels { p.orderOut(nil) }
    }

    /// Reverse of the slide-in, then order out and call `completion`.
    func slideOut(completion: @escaping () -> Void) {
        let out = panels
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for p in out { p.orderOut(nil) }
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = CaptureLossBanner.slideSecs
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for p in out {
                guard let clip = p.contentView, let content = clip.subviews.first else { continue }
                content.animator().setFrameOrigin(NSPoint(x: 0, y: clip.bounds.height))
            }
        }, completionHandler: {
            for p in out { p.orderOut(nil) }
            completion()
        })
    }
}

/// A toast's first click must act, not just focus: the panel is
/// non-activating and never becomes the key window.
private final class ToastHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Toast card

/// The card, drawn from the boards: paper fill, 3 pt ink edge, hand-cut radii
/// 16/13/17/12, 4-by-5 pt offset shadow, 13.5 pt semibold line, at most one
/// mustard action and a quiet ✕. Colors are `SentryColor` tokens, so the
/// night board (Notices-Toasts-Night) is the same view in dark mode.
struct ToastCardView: View {
    let spec: ToastSpec
    let onAction: () -> Void
    let onClose: () -> Void

    /// CSS `border-radius: 16px 13px 17px 12px` is top-left, top-right,
    /// bottom-right, bottom-left.
    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 16, bottomLeadingRadius: 12,
        bottomTrailingRadius: 17, topTrailingRadius: 13, style: .continuous)

    var body: some View {
        let shape = Self.shape
        let shadow = ToastGeometry.shadowOffset
        let edge = ToastGeometry.borderWidthPt
        let isAppIcon: Bool = { if case .appIcon = spec.icon { return true } else { return false } }()
        HStack(spacing: 12) {
            icon
            Text(spec.title)
                .uiFont(size: 13.5, weight: .semibold)
                .foregroundStyle(SentryColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = spec.action {
                Button(action.label, action: onAction)
                    .buttonStyle(ToastActionButtonStyle())
                    .accessibilityLabel(action.accessibilityLabel)
            }
            if spec.dismissible {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(SentryColor.muted)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        // Board padding is measured inside the edge: 12 (app icon) or 14 on
        // the left, 8 when the right side ends in a control, else 12.
        .padding(.leading, edge + (isAppIcon ? 12 : 14))
        .padding(.trailing, edge + (spec.hasControls ? 8 : 12))
        .frame(width: CaptureLossBanner.widthPt, height: CaptureLossBanner.heightPt)
        .background(SentryColor.paper, in: shape)
        .overlay(shape.strokeBorder(SentryColor.controlBorder, lineWidth: edge))
        .background(shape.fill(SentryColor.buttonShadow).offset(x: shadow.width, y: shadow.height))
        .frame(width: CaptureLossBanner.widthPt + shadow.width,
            height: CaptureLossBanner.heightPt + shadow.height, alignment: .topLeading)
    }

    @ViewBuilder private var icon: some View {
        switch spec.icon {
        case .appIcon:
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        case let .symbol(name, tone):
            Image(systemName: name)
                .uiFont(size: 22, weight: .semibold)
                .foregroundStyle(Self.color(tone))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
    }

    private static func color(_ tone: ToastSpec.Tone) -> Color {
        switch tone {
        case .danger: return SentryColor.danger
        case .accent: return SentryColor.accent
        case .quiet: return SentryColor.ink2
        }
    }
}

/// The toast's one mustard button. Same look as `SentryPrimaryButtonStyle`
/// at the toast board's size: 34 pt tall, 14 pt side padding, 2.5 pt edge,
/// radii 11/9/12/9, 2-by-3 pt offset shadow. The shared style is not used
/// because its 46 pt height and 28 pt padding are the popover/setup size
/// (its own doc says callers set width; height and padding are constants).
/// One per toast, so the one-primary rule holds by construction.
private struct ToastActionButtonStyle: ButtonStyle {
    static let height: CGFloat = 34
    static let horizontalPadding: CGFloat = 14
    static let edgeWidth: CGFloat = 2.5
    static let shadowOffset = CGSize(width: 2, height: 3)
    static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 11, bottomLeadingRadius: 9,
        bottomTrailingRadius: 12, topTrailingRadius: 9, style: .continuous)

    func makeBody(configuration: Configuration) -> some View {
        ToastActionButton(configuration: configuration)
    }
}

private struct ToastActionButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        let shape = ToastActionButtonStyle.shape
        let offset = ToastActionButtonStyle.shadowOffset
        let pressed = configuration.isPressed
        configuration.label
            .uiFont(size: 14, weight: .bold)
            .foregroundStyle(SentryColor.primaryInk)
            .padding(.horizontal, ToastActionButtonStyle.horizontalPadding)
            .frame(height: ToastActionButtonStyle.height)
            .background(hovering ? SentryColor.primaryHover : SentryColor.primary, in: shape)
            .overlay(shape.strokeBorder(SentryColor.buttonShadow,
                lineWidth: ToastActionButtonStyle.edgeWidth))
            .background(shape.fill(SentryColor.buttonShadow)
                .offset(pressed ? .zero : offset))
            .offset(pressed ? offset : .zero)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

// MARK: - Toasts

/// The fail-loud face of capture loss (SPEC §8 direction: worst failure is
/// "cannot see", never "cannot act"; installer-plan.md §1.4: a banner
/// suffices, click-through-off is NOT needed).
///
/// A toast at the top right, under the menu bar, telling whoever is at the
/// machine that protection is off and a parent has to re-approve Screen
/// Recording. Shown only in `--capture-loss banner` mode, on permission loss
/// at launch or after the re-arm budget is exhausted. It goes through
/// `ToastArbiter`, so it never shares the screen with another toast.
///
/// OWNER 2026-08-26 (replaces the full-width menu-bar strip): the strip
/// covered the very status icon that reports the state and every other
/// app's menus. The toast is dismissible with one click; in an ADMIN session
/// the durable signal is the red menu-bar shield plus the popover's "Not
/// protecting" + `Open repair…`, which stay until the grant returns
/// (UIStatusItem.swift).
///
/// `Turn on` reports one intent through `onFix`; AppDelegate then lets the
/// onboarding runtime classify the failure and arbitrate whether a repair
/// surface or System Settings owns the next step. Keeping that routing
/// outside this view prevents one click from opening two surfaces or calling
/// a generic failure a Screen Recording failure. A dismissal is logged as a
/// `ui` record through `onDismiss` so it shows in the health report. It
/// survives Spaces/fullscreen switches (canJoinAllSpaces, stationary).
///
/// 2026-09-07: the toast is interactive, so its panel
/// is exactly the pixels it draws (UIOverlayWindow rule 2). The signals that
/// outlive it are the durable ones: the red shield, the popover's persistent
/// capture row (`UIPopoverView.captureRow`), and the `alerts.log` ALERT/INFO
/// pair (`CaptureAlert`).
final class CaptureLossBanner {
    /// Set by ✕ for the CURRENT outage; cleared by `hide()` (capture back),
    /// so the next outage gets a fresh toast and this one does not nag.
    private var dismissed = false

    /// Called on ✕ / Turn on so main.swift can log a `ui` record. The banner
    /// has no logger of its own (it can be up before the pipeline exists).
    var onDismiss: (() -> Void)?
    var onFix: (() -> Void)?
    /// Board "Capture lost · child account": a child cannot approve Screen
    /// Recording, so their toast has no action. Default true keeps today's
    /// behavior until the caller (main.swift) says the session is a child's.
    var offersFix = true

    static let toastID = "capture-loss"

    /// Toast geometry. Legacy names: `LicenseToast` (UILicenseViews.swift)
    /// still reads these until it moves onto `ToastArbiter`.
    ///
    /// RECEIPT (DERIVED 2026-09-28): 470-by-56 is the Notices-Toasts board's
    /// toast, with the 3 pt edge and 4-by-5 pt shadow in `ToastGeometry`.
    /// Superseded receipt 2026-09-04: 480-by-66 read as disabled and 520-by-72
    /// fit `Open Settings` plus a two-line instruction; the copy is now one
    /// line and the action `Turn on`, so that basis is gone. MEASURED
    /// 2026-09-29 on the installed app (desktop shots):
    /// toasts draw top-right at this size at the default text size. NOT run:
    /// the largest-text-size check (the UI driver suppresses toasts, so
    /// ui-qa cannot cover it). The owed Tripwire is the longest title with
    /// the widest action ("Protection
    /// is off: Screen Recording is off" + "Turn on", scaled to 85 % before it
    /// truncates) staying whole at the largest text size.
    static let widthPt: CGFloat = 470
    static let heightPt: CGFloat = 56
    /// Gap below the menu bar (DERIVED: the board pads the toast column
    /// 12 pt, and Notification Center uses ~12 pt on macOS 26).
    static let topGapPt: CGFloat = 12
    /// Legacy: only `LicenseToast` reads this; the card draws board radii.
    static let cornerRadiusPt: CGFloat = 14
    /// Slide duration. DERIVED: matches SwiftUI `.snappy` (~0.3 s) that
    /// Notification Center toasts use; 0 under Reduce Motion.
    static let slideSecs: TimeInterval = 0.3

    /// (2026-09-11): "paused" is the parent's own word for the pause
    /// THEY asked for ("Paused until 3:45 PM", and Resume is how they undo
    /// it). A lost permission is not that, and a parent who never paused
    /// anything went hunting for a Resume button. "off" is what the popover
    /// header already says for this state ("Not protecting").
    /// Copy: Notices-Toasts board, "Capture lost" rows.
    static let title = "Protection is off: Screen Recording is off"
    static let childTitle = "Protection is off. A parent needs to fix it."
    static let fixLabel = "Turn on"
    static let fixAccessibilityLabel = "Open Screen Recording settings"

    func show() {
        // Main thread only (AppKit); idempotent — capture loss can repeat.
        guard !dismissed else { return }
        ToastArbiter.shared.present(ToastSpec(
            id: Self.toastID, kind: .problem,
            icon: .symbol("shield.slash", .danger),
            title: offersFix ? Self.title : Self.childTitle,
            action: offersFix
                ? ToastSpec.Action(
                    label: Self.fixLabel, accessibilityLabel: Self.fixAccessibilityLabel,
                    run: { [weak self] in self?.onFix?() })
                : nil,
            onDismiss: { [weak self] in
                self?.dismissed = true
                self?.onDismiss?()
            }))
    }

    func hide() {
        ToastArbiter.shared.withdraw(id: Self.toastID)
        dismissed = false
    }
}

/// Transient "Protection is on" toast (OWNER 2026-08-26): shown for
/// `showSecs` when capture becomes live — at launch and after a permission
/// fix — so the parent sees the state flip without opening the popover.
/// No buttons, so it is click-through; a problem toast outranks it.
final class StatusToast {
    /// OWNER: 3 s — long enough to read one line, short enough not to nag.
    /// Board: "good news hides after 3 s".
    static let showSecs: TimeInterval = 3
    static let title = "Protection is on"
    static let toastID = "protection-on"

    /// The status sentence the popover shows is no longer repeated here (one
    /// line per toast). The parameter stays so the call in main.swift compiles;
    /// remove both together.
    func show(status _: String = "") {
        ToastArbiter.shared.present(ToastSpec(
            id: Self.toastID, kind: .notice, icon: .appIcon, title: Self.title))
    }
}

/// "Covers cleared. Paused until 3:45 PM." (owner 2026-09-29, plan §6
/// item 3, option B): after the emergency keys and the administrator
/// password, the parent sees that it worked and when protection comes back.
/// A `.notice`: no controls, so click-through, and it hides after
/// `StatusToast.showSecs`. The popover's Paused state carries the rest.
enum PanicToast {
    static let toastID = "panic"

    static func title(until: Date) -> String {
        "Covers cleared. Paused until \(UIState.clockTime.string(from: until))."
    }

    /// The toast for a panic-pause change, or nil. Shown once per panic
    /// the keys started: not for an expiry or an early resume (next nil),
    /// not for the coverage tripwire (no one pressed anything), and not
    /// again for a republish of the same deadline.
    static func spec(previous: PanicPause?, next: PanicPause?) -> ToastSpec? {
        guard let next, next.fromEmergencyKeys, next.until != previous?.until else { return nil }
        return ToastSpec(id: toastID, kind: .notice, icon: .symbol(UISymbol.pause, .quiet),
            title: title(until: next.until))
    }
}
