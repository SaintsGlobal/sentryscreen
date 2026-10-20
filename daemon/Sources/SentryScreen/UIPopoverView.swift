import AppKit
import SwiftUI

// Popover content. The root has one current
// status, pause or recovery action, then the footer with its wordmark.
// Sensitivity and activity remain available in the inline Settings panel.

/// Layout metrics, all from spec §9.2/§9.3 (OWNER: they are the drawn
/// design, not tunables). Named rather than sprinkled so a later slice's
/// section lines up with this one by construction.
enum UIMetrics {
    /// Popover width (spec §9.2 diagram).
    static let popoverWidth: CGFloat = 320
    /// DERIVED 2026-09-28 from the boards (Popover-Protected: 16 pt gutter,
    /// 14 pt between blocks); was 14 / 10 on the system chrome. The Settings
    /// fold receipts below were taken at 14 / 10 and are STALE until
    /// re-measured on a test Mac (`assertfits` is the tripwire).
    static let popoverPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let sectionPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 10
    /// The one explicit point size §9.3 allows: the header glyph. Everything
    /// else is a semantic text style, drawn through `.uiFont`, so one code
    /// path covers the default size and the two larger accessibility sizes
    /// the `textsize` script verb renders (UIAccessibility.swift).
    static let headerSymbol: CGFloat = 34
    /// The header badge (the Lantern face, or the state tile). DERIVED from
    /// the boards' 32 px badge; the text scale grows it with the text.
    static let headerBadge: CGFloat = 32
    /// Tappable list row (spec §9.2 diagram: "row 30 pt"). Also the height
    /// the section's dividers are spaced by. A MINIMUM since 2026-09-07, not
    /// a fixed height: `.callout` is 12 pt at the default size and 20 pt at
    /// `textsize xl` (MEASURED, UITypography), and a fixed 30 pt box has no
    /// room for a 20 pt label plus its line spacing.
    static let rowHeight: CGFloat = 30
    /// Gap between a section's caption label and its card.
    static let labelGap: CGFloat = 5
    /// Activity row (spec §9.2 diagram: "10 rows max, 26 pt each"); text
    /// only, so shorter than a tappable row. Also a minimum.
    static let activityRowHeight: CGFloat = 26
    /// MEASURED 2026-09-04 in the Mac Mini app-owned matrix: a 520-point
    /// Settings viewport produced a 630-point full popover, so fixed chrome
    /// costs 110 points. A 410-point viewport caps the full surface at 520
    /// points while every lower control remains in the scroll document. If a
    /// control is not reachable, change the structure and measure again.
    ///
    /// RE-MEASURED 2026-09-07 for larger text. The
    /// 2026-09-04 receipt was taken at the default text size only, and the
    /// three-page sheet (2026-09-06) shortened every page since.
    ///
    /// The viewport SCALES with the text (`settingsViewportMaxHeight(scale:)`)
    /// because one that did not would be a smaller window onto bigger rows —
    /// the same scrolling, on a surface that got harder to read.
    ///
    /// RE-MEASURED 2026-09-11 after the page
    /// switcher, a write error and Done came OUT of the scroll document and
    /// became pinned chrome (`UISettingsPanelView`): the scrolling page is now
    /// 229 / 283 / 384 pt for its three pages at the default
    /// size, 296 / 361.5 / 523 pt at `textsize large` and
    /// 353.5 / 454.5 / 617 pt at `textsize xl` — every one inside its own
    /// scaled cap, so NO page folds at any of the three sizes and the cap is
    /// headroom rather than a fold. Full popover with it: 413 / 467 / 568,
    /// 502 / 568 / 729, 576 / 677 / 839 pt. `UIDriver.foldBudget` is the
    /// tripwire; if a control is not reachable, change the structure and
    /// measure again.
    static let settingsViewportMaxHeight: CGFloat = 410

    /// Scaled metrics. `scale` is `\.uiTextScale`; at 1.0 each returns its
    /// constant unchanged, so the default-size design is untouched.
    static func rowHeight(scale: CGFloat) -> CGFloat {
        UITypography.points(rowHeight, scale: scale)
    }
    static func activityRowHeight(scale: CGFloat) -> CGFloat {
        UITypography.points(activityRowHeight, scale: scale)
    }
    static func headerBadge(scale: CGFloat) -> CGFloat {
        UITypography.points(headerBadge, scale: scale)
    }
    static func headerSymbol(scale: CGFloat) -> CGFloat {
        UITypography.points(headerSymbol, scale: scale)
    }
    static func settingsViewportMaxHeight(scale: CGFloat) -> CGFloat {
        UITypography.points(settingsViewportMaxHeight, scale: scale)
    }

    /// The tallest popover a Mac can show without running off its screen. The
    /// `assertfits` Tripwire (UIDriver) fails loudly on it; nothing silently
    /// truncates.
    ///
    /// DERIVED from the display rather than pinned: `NSScreen.visibleFrame`
    /// already excludes the menu bar and the Dock, and the popover hangs from
    /// the menu-bar item at the top of it. 24 pt is the arrow plus the shadow
    /// inset AppKit draws around a popover.
    ///
    /// MEASURED 2026-09-07 on an M1 Mac: `visibleFrame` is 1920 x 975 pt, so
    /// the budget here is 951 pt. RE-MEASURED 2026-09-11: the
    /// tallest surface any text size produces is still Settings → App at
    /// `textsize xl`, now **839 pt** (813 pt before that change; the 52 pt it
    /// used to hide below a fold is on screen). 112 pt of headroom here, which
    /// is why the root does NOT scroll: adding a scroll view the product never
    /// uses would change the default-size design for a case that does not
    /// exist.
    ///
    /// KNOWN GAP, untested: 839 pt is above the 800 pt `fallback` below, so on
    /// a display as small as that fallback describes, Settings → App at
    /// `textsize xl` would exceed this budget. 813 pt already did before this
    /// change, so the gap is older than it; nobody has run the app on a
    /// 13-inch display. `assertfits` fails by name there, and the fix would be
    /// to cap `settingsViewportMaxHeight(scale:)` by what is left of this
    /// budget after chrome — measure on the machine first.
    ///
    /// `fallback` is only for a run with no screen at all. DERIVED, not
    /// measured: the smallest display this app supports is the 13-inch
    /// MacBook Air, whose default scaled resolution is 1470 x 956 pt (Apple's
    /// published spec); its menu bar and Dock leave roughly 850 pt, so 800 pt
    /// is under any real display and still 116 pt above the tallest measured
    /// surface. If a real machine ever trips this, re-measure on it.
    static let popoverScreenInset: CGFloat = 24
    static let popoverMaxHeightFallback: CGFloat = 800
    /// Main thread only (it reads NSScreen).
    static var popoverMaxHeight: CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height, visible > popoverScreenInset else {
            return popoverMaxHeightFallback
        }
        return visible - popoverScreenInset
    }

    static func sectionStrokeWidth(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 2 : 1
    }
}

/// Every SF Symbol the popover draws, in one place.
/// MEASURED 2026-08-22 (an M1 Mac, macOS 26.6): an SF Symbol name AppKit
/// does not know renders as an EMPTY slot with no error — `lock.badge.plus`
/// did exactly that in the first slice-5 build, indenting a section title
/// with nothing in front of it. `--ui-selftest` resolves every name here, so
/// a typo fails a headless test instead of surviving a screenshot review.
enum UISymbol {
    static let lock = "lock.fill"
    static let lockedOut = "lock.trianglebadge.exclamationmark.fill"
    static let setPin = "key.fill"
    static let warning = "exclamationmark.triangle.fill"
    static let error = "exclamationmark.circle.fill"
    static let writeError = "exclamationmark.octagon.fill"
    static let devState = "hammer.fill"
    static let commandLine = "terminal"
    static let disclosure = "chevron.right"
    /// Settings §9.4: a managed row states its owner with a checkmark, and
    /// the two confirmations carry the shape of what they do.
    static let managed = "checkmark"
    static let turnOff = "shield.slash.fill"
    /// "Remove SentryScreen…" (SPEC §8.1(7)): the row and its confirmation.
    static let remove = "trash.fill"
    /// Pause chooser button, the paused tile, Resume, the plans layer's Back,
    /// the protected check, and the keypad's Delete (boards Popover-*).
    static let pause = "pause.fill"
    static let resume = "play.fill"
    static let back = "chevron.left"
    static let check = "checkmark.circle.fill"
    static let deleteDigit = "delete.left"

    static let all = [lock, lockedOut, setPin, warning, error, writeError, devState,
        commandLine, disclosure, managed, turnOff, remove, pause, resume, back, check, deleteDigit]
}

/// Animations (spec §9.3).
enum UIAnim {
    /// State transitions (protecting ⇄ paused ⇄ degraded, section collapse).
    /// ASSUMED 0.22 s (Control Center toggle feel, under the ~250 ms bar at
    /// which a control stops feeling instant); OWNER eyeball 2026-08-22 live
    /// rounds 1–2 raised no sluggish/twitchy finding. Re-receipt before tuning
    /// — do not tune it silently.
    static var state: Animation { disabled ? .linear(duration: 0) : .snappy(duration: 0.22, extraBounce: 0.08) }
    /// Row hover/press feedback. ASSUMED, same basis: 0.12 s is fast enough
    /// to read as the control's own weight rather than as an animation.
    static var row: Animation { disabled ? .linear(duration: 0) : .easeOut(duration: 0.12) }
    /// Zero under a UI script (deterministic screenshots) and under Reduce
    /// Motion (accessibility).
    static var disabled: Bool {
        disabled(scripted: UIDriver.scriptPath != nil,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    static func disabled(scripted: Bool, reduceMotion: Bool) -> Bool {
        scripted || reduceMotion
    }
}

/// Grouped section card (boards): `paper2` fill, a `line` edge and the card's
/// hand-cut corners, opaque like the rest of the paper-ink popover. `padding:
/// 0` is for row lists, whose rows pad themselves so a hover highlight and a
/// divider can reach the card's edges.
struct UISection<Content: View>: View {
    var padding: CGFloat = UIMetrics.sectionPadding
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UIPopoverShape.card.fill(SentryColor.paper2))
            .overlay(UIPopoverShape.card.strokeBorder(SentryColor.line,
                lineWidth: UIMetrics.sectionStrokeWidth(increasedContrast: contrast == .increased)))
    }
}

/// A small caption label above a card (spec §9.2), in the `muted` token.
struct UISectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .uiFont(.caption)
            .foregroundStyle(SentryColor.muted)
            .padding(.leading, 4)
    }
}

/// One tappable row inside a card: label, optional chevron, hover highlight
/// (spec §9.2, 30 pt). `.plain` button style so the row — not a bordered
/// rectangle inside it — is the control, which is how Control Center and
/// Settings draw a list.
struct UIListRow: View {
    let label: String
    var chevron = true
    var isDisabled = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiTextScale) private var textScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .uiFont(.callout)
                    // A row label wraps rather than truncating once the text
                    // is larger than the 320 pt popover's one line.
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isDisabled ? SentryColor.muted : SentryColor.ink)
                Spacer(minLength: 0)
                if chevron {
                    Image(systemName: UISymbol.disclosure)
                        .uiFont(.caption, weight: .semibold)
                        .foregroundStyle(SentryColor.muted)
                }
            }
            .padding(.horizontal, UIMetrics.sectionPadding)
            // minHeight, not height: the row keeps its 30 pt rhythm at the
            // default size and GROWS with the label instead of clipping it.
            .frame(minHeight: UIMetrics.rowHeight(scale: textScale))
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && !isDisabled ? SentryColor.accentSoft : Color.clear)
                    .padding(.horizontal, 4))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { h in withAnimation(UIAnim.row) { hovering = h } }
    }
}

/// Footer text button (spec §9.2 bottom row): no border, `.callout`, and the
/// same hover wash `UIListRow` uses so the two read as one family. Sized to
/// its label rather than stretched — the footer has two of them and a
/// full-width control would claim to be the popover's primary action.
struct UIFooterButton: View {
    let label: String
    var isDisabled = false
    /// Secondary ink, for a link that must be there but not compete.
    var muted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .uiFont(.callout)
                .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary)
                    : muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlAccentColor)
                            .opacity(hovering && !isDisabled ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { h in withAnimation(UIAnim.row) { hovering = h } }
    }
}

// MARK: - Paper-ink pieces

/// The hand-cut corner radii the boards draw (CSS "TL TR BR BL"). A fixed set
/// of shapes, not a tunable: each surface keeps its own so two neighbours
/// never look stamped from one mould.
enum UIPopoverShape {
    static func hand(_ tl: CGFloat, _ tr: CGFloat, _ br: CGFloat, _ bl: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: tl, bottomLeadingRadius: bl,
            bottomTrailingRadius: br, topTrailingRadius: tr, style: .continuous)
    }
    static let card = hand(12, 10, 13, 9)
    static let hold = hand(12, 10, 13, 11)
    static let outline = hand(12, 10, 13, 9)
    static let outlineSmall = hand(10, 8, 11, 7)
    static let field = hand(9, 8, 10, 7)
    static let fieldAlt = hand(8, 10, 7, 9)
    static let keys = [hand(10, 8, 11, 9), hand(9, 11, 8, 10), hand(11, 9, 10, 8), hand(8, 10, 9, 11)]
}

/// A dashed rule in the `line` token.
struct UIPopoverRule: View {
    var width: CGFloat = 1

    var body: some View {
        UIPopoverRuleLine()
            .stroke(SentryColor.line, style: StrokeStyle(lineWidth: width, dash: [4, 3]))
            .frame(height: width)
            .accessibilityHidden(true)
    }
}

private struct UIPopoverRuleLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// The secondary button: no fill, ink edge, ink label. Never mustard, so a
/// state keeps its one primary (`SentryBrand.primaryButtonBudgetFailure`).
struct UIPopoverOutlineButtonStyle: ButtonStyle {
    /// The small outline button that sits inside an info card beside a line
    /// of text. ASSUMED: 34 pt, not a board value.
    static let smallHeight: CGFloat = 34
    var height: CGFloat = SentryPrimaryButtonStyle.minHeight
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        UIPopoverOutlineButton(configuration: configuration, height: height, small: small)
    }
}

private struct UIPopoverOutlineButton: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let small: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = small ? UIPopoverShape.outlineSmall : UIPopoverShape.outline
        configuration.label
            .uiFont(small ? .callout : .headline, weight: .semibold)
            .foregroundStyle(SentryColor.ink)
            .padding(.horizontal, small ? 12 : 16)
            .frame(minHeight: height)
            .background(shape.fill(configuration.isPressed ? SentryColor.accentSoft : Color.clear))
            .overlay(shape.strokeBorder(SentryColor.controlBorder, lineWidth: 2))
            .opacity(isEnabled ? 1 : SentryPrimaryButtonStyle.disabledOpacity)
            .contentShape(shape)
    }
}

/// A hand-cut card with the caller's content. `fill` defaults to `paper2`;
/// the paused card passes `accentSoft`.
struct UIPopoverInfoCard<Content: View>: View {
    let shape: UnevenRoundedRectangle
    let fill: Color
    let horizontal: CGFloat
    let vertical: CGFloat
    let content: Content

    init(shape: UnevenRoundedRectangle = UIPopoverShape.card, fill: Color = SentryColor.paper2,
        horizontal: CGFloat = 12, vertical: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.fill = fill
        self.horizontal = horizontal
        self.vertical = vertical
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(SentryColor.line, lineWidth: 1))
    }
}

/// One notice: symbol, title, optional detail, an optional trailing control
/// (a quiet button) or a chevron for a tappable card.
struct UIPopoverNoticeCard<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    let chevron: Bool
    let trailing: Trailing

    init(symbol: String, tint: Color, title: String, detail: String? = nil, chevron: Bool = false,
        @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.chevron = chevron
        self.trailing = trailing()
    }

    var body: some View {
        UIPopoverInfoCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .uiFont(.callout, weight: .semibold)
                        .foregroundStyle(SentryColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .uiFont(.caption)
                            .foregroundStyle(SentryColor.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                trailing
                if chevron {
                    Image(systemName: UISymbol.disclosure)
                        .uiFont(.caption, weight: .semibold)
                        .foregroundStyle(SentryColor.muted)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

extension UIPopoverNoticeCard where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String? = nil, chevron: Bool = false) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, chevron: chevron) { EmptyView() }
    }
}

/// A one-line fact on a card: caption text on paper with an ink edge, the
/// shape of the Settings plan chip.
struct UIPopoverChip: View {
    let text: String

    var body: some View {
        Text(text)
            .uiFont(.caption, weight: .semibold)
            .foregroundStyle(SentryColor.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SentryColor.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SentryColor.controlBorder, lineWidth: 1.5))
    }
}

// MARK: - Copy and rules

/// Popover copy from the approved boards. One place, so the self-test pins it
/// and a copy change is one edit.
enum UIPopoverCopy {
    static let pauseTitle = "Pause for…"
    static let pauseOpenLabel = "Pause protection…"
    static let pauseChooserNote = "Off for everyone on this Mac. Asks for your PIN."
    static let pausedTitle = "Off for everyone on this Mac"
    static let resumeLabel = "Resume now"
    /// Owner 2026-09-29 (plan §6 item 3, option B): the paused card after the
    /// emergency keys, the only panic source left on an installed build (the
    /// full-coverage tripwire lifts region covers without pausing since
    /// 2026-10-18).
    static let panicKeysChip = "Emergency keys used. Every cover was cleared."
    static func panicChip(_ panic: PanicPause) -> String { panicKeysChip }
    static let back = "Back"
    static let cancel = "Cancel"
    static let screenRecordingOffLine = "Screen Recording is off."
    static let screenRecordingOffButton = "Turn on Screen Recording"
    static let stoppedLine = "Protection stopped."
    static let repairButton = "Repair"
    static let childManagedTitle = "Managed by a parent"
    static let childManagedDetail = "Changes need an administrator login"
    static let childDegradedTitle = "A parent needs to fix this"
    static let childDegradedDetail = "From an administrator login"
    static let detectorTitle = "New content isn’t being checked"
    static let detectorDetail = "Restart this Mac to fix it. Covers already showing stay."
    static let noPinTitle = "Set a PIN"
    static let noPinDetail = "Needed to pause or change settings."
}

/// The pause countdown the header and the paused card show. Cadence and
/// rounding below are the owner-delegated decision of 2026-09-28 (plan §2a):
/// kept as built — minutes, rounded up, redrawn every 5 s.
/// A 5 s redraw on a minute display is late by at most 5 s at a minute
/// boundary, invisible in practice, and costs nothing while the popover is
/// closed (the timeline runs only while it is shown).
///
/// Cadence receipt: the header re-reads it every `UIActivity.refreshSecs`
/// (5 s, DERIVED there from the capture-loss poll) inside a `TimelineView`
/// that wraps only the detail Text, because `republishIfPauseChanged`
/// publishes on the paused flip only and nothing else would redraw it. Only a
/// timed pause runs a timeline; "until restart" is static.
/// Rounding receipt: minutes round UP, floor 1, so it never reads "0 min left"
/// while protection is still off (the same rule as `PinGate.lockoutMessage`
/// and the trial's days left). Presets cap at 1 h (`PausePreset`), so a
/// minutes-only count needs no hours form.
enum UIPauseCountdown {
    static func minutesLeft(until: Date, now: Date) -> Int {
        max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
    }

    static func detail(until: Date, now: Date) -> String {
        if until == .distantFuture { return "Back on when this Mac restarts" }
        let at = UIState.clockTime.string(from: until)
        if until <= now { return "Back on at \(at)" }
        return "Back on at \(at) · \(minutesLeft(until: until, now: now)) min left"
    }
}

/// The notices the root can draw, in the order they stack. Every kind draws
/// at most once and none is capped, so no fact is ever dropped.
///
/// Urgency order, most urgent first (owner delegated 2026-09-28; plan §2a).
/// The rule: first what leaves this Mac unprotected now,
/// then what lets someone other than the parent turn protection off, then
/// what stops protection later, then upkeep.
///   1 detector   covers cannot be drawn at all
///   2 displays   a screen is not covered
///   3 noPin      no PIN: anyone at the keyboard can pause or change it
///   4 devState   developer state
/// Board evidence: Popover-Notices stacks displays above Set PIN (kept).
enum UIPopoverNotice: Hashable {
    case detector, displays, noPin, devState

    static let urgencyOrder: [UIPopoverNotice] = [.detector, .displays, .noPin, .devState]

    struct Facts {
        var detector = false, displays = false, noPin = false, devState = false

        func has(_ notice: UIPopoverNotice) -> Bool {
            switch notice {
            case .detector: return detector
            case .displays: return displays
            case .noPin: return noPin
            case .devState: return devState
            }
        }
    }

    static func active(_ facts: Facts) -> [UIPopoverNotice] {
        urgencyOrder.filter { facts.has($0) }
    }
}

struct UIPopoverView: View {
    @ObservedObject var state: UIState
    @ObservedObject var actions: UIActions
    @ObservedObject var activity: UIActivity
    @Environment(\.uiTextScale) private var textScale
    @FocusState private var focus: Focus?

    /// The two root layers that are not a `UIActions.Layer`: the pause
    /// chooser. View-local, because `UIActions.Layer`
    /// lives in UISettingsSheet.swift. `UIStatusItem` builds a fresh hosting
    /// controller per open (UIStatusItem.swift), so each open starts at the
    /// root (UNVERIFIED at runtime).
    enum Sheet: Equatable { case pause }
    @State private var sheet: Sheet?

    /// Where the keyboard lands when the popover opens (spec §9.7: an
    /// accessory app's popover is made key on show, but nothing inside it was
    /// focused, so Tab and Space had nowhere to start).
    ///
    /// Deliberately NOT a pause control: the first thing a keyboard reaches
    /// must not be a control that turns protection off. It is the way back
    /// when the machine needs one, and `Settings…` — the non-destructive
    /// entry point — otherwise. `nil` is a popover with no parent controls at
    /// all (a standard session, §9.2 read-only).
    enum Focus: Hashable { case repair, settings }

    static func initialFocus(isAdmin: Bool, isDegraded: Bool) -> Focus? {
        guard parentControlsAvailable(isAdmin: isAdmin) else { return nil }
        if isDegraded { return .repair }
        return .settings
    }

    /// Initial focus is suppressed under a UI script, for the same reason
    /// `FixSpotlight` and the dunning toast are: a focus ring is drawn, and
    /// every app-owned E2E render would change. Production is `nil` script
    /// path, so a parent always gets it. MEASURED 2026-09-07:
    /// over three interleaved passes of 13 default-size ui-qa
    /// scripts against both main@da306d1 and this build, the candidate never
    /// produced a render the baseline did not.
    static func takesInitialFocus(scripted: Bool) -> Bool { !scripted }

    /// The control that takes the keyboard on this open, or nil for none.
    private var initialFocusTarget: Focus? {
        guard Self.takesInitialFocus(scripted: UIDriver.scriptPath != nil) else { return nil }
        return Self.initialFocus(isAdmin: state.isAdmin, isDegraded: state.isDegraded)
    }

    /// The popover's own coordinate space. `assertfits` (UIDriver) measures
    /// every registered control's frame in it and fails loudly if one is not
    /// inside the surface — the clipping check the `textsize` scripts run.
    static let rootSpace = "ui.popover.root"
    /// Footer wordmark size: Shantell 13 pt, muted, no mark, at the right of
    /// the Settings… row (Popover-Protected board footer; spec §9.2 bottom
    /// row). `uiDisplayFont` scales it with the text size.
    static let footerWordmarkSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.sectionSpacing) {
            header
            switch actions.layer {
            case .none: sections
            case .pin: UIPinKeypadView(actions: actions)
            case .setPin: UIPinSetView(actions: actions)
            // The sheet owns its own scroll viewport (UISettingsPanelView):
            // the page switcher, a write error and Done are pinned chrome
            // around it, not rows that can scroll away.
            case .settings:
                UISettingsPanelView(state: state, actions: actions, activity: activity)
            case .remove: UIRemoveView(actions: actions)
            case .diagnosticsReview: UIDiagnosticsReviewView(actions: actions)
            }
            // The root draws the wordmark inside its Settings… row (footer);
            // every other layer keeps it bottom-right on its own.
            if case .none = actions.layer {} else {
                HStack { Spacer(minLength: 0); UIPopoverWordmark() }
                    .padding(.top, 2)
            }
        }
        .padding(UIMetrics.popoverPadding)
        .frame(width: UIMetrics.popoverWidth, alignment: .leading)
        // Paper-ink inside the native NSPopover: its arrow and shadow stay
        // AppKit's, the paper fills the content. Opaque, so a screenshot and
        // the live popover agree (plan §2 deviation from the §9.3 vibrancy rule).
        .foregroundStyle(SentryColor.ink)
        .tint(SentryColor.accent)
        .background(SentryColor.paper)
        // Layout probe for the driver's `assertfits`. Costs one clear
        // background and one preference read; draws nothing.
        .coordinateSpace(name: Self.rootSpace)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: UISurfaceSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(UISurfaceSizeKey.self) { UILayoutProbe.shared.surface = $0 }
        .onPreferenceChange(UIControlFrameKey.self) { UILayoutProbe.shared.frames = $0 }
        .onPreferenceChange(UIScrollViewportSizeKey.self) { UILayoutProbe.shared.scrollViewport = $0 }
        .onPreferenceChange(UIScrollDocumentSizeKey.self) { UILayoutProbe.shared.scrollDocument = $0 }
        .onAppear { focus = initialFocusTarget }
        // A layer that no longer applies closes instead of waiting under a
        // state that cannot use it.
        .onChange(of: state.isDegraded) { _, _ in if sheet == .pause { sheet = nil } }
        .animation(UIAnim.state, value: state.glyph)
        .animation(UIAnim.state, value: state.headerText)
        .animation(UIAnim.state, value: actions.layer)
        .animation(UIAnim.state, value: sheet)
    }

    /// Owner 2026-08-29: the child's menu bar shows the shield, but nothing in
    /// its popover may write. Every control below `sections` ends in
    /// `actions.*` → store.mutate / PinGate, both of which the child session
    /// cannot satisfy (parent/ 2770, settings.json 664 root:admin), so they
    /// are not drawn at all rather than drawn and failing.
    static func parentControlsAvailable(isAdmin: Bool) -> Bool { isAdmin }

    static let childManagedBody =
        UIPopoverCopy.childManagedTitle + " " + UIPopoverCopy.childManagedDetail
    static let childDegradedBody =
        UIPopoverCopy.childDegradedTitle + " " + UIPopoverCopy.childDegradedDetail

    /// Everything below the header when no PIN layer is up. The header stays
    /// visible under a layer so the parent never loses sight of what the Mac
    /// is doing while they type.
    @ViewBuilder private var sections: some View {
        if !Self.parentControlsAvailable(isAdmin: state.isAdmin) {
            childReadOnly
        } else if state.isDegraded {
            // OWNER 2026-08-26: while not protecting, the popover is the
            // way back and nothing else — presets, sensitivity, activity and
            // footer are noise next to a dead capture. The one exception is
            // the resume control of a paused-and-lost machine (spec §9.2).
            needsPermission
            if state.pauseUntil != nil { pausedControls }
        } else if sheet == .pause {
            pauseChooser
        } else {
            healthy
        }
        if Self.parentControlsAvailable(isAdmin: state.isAdmin) { uninstallLink }
    }

    /// "Remove SentryScreen…" in every parent state (owner 2026-10-16), so
    /// a parent stuck in a bug can always remove the app. Its own last row:
    /// the 288 pt footer row has no room beside Settings… and the wordmark.
    private var uninstallLink: some View {
        UIFooterButton(label: UninstallCopy.anywhereLabel, muted: true) { actions.beginUninstall() }
            .uiControl("ui.uninstall", kind: .button,
                read: { UninstallCopy.anywhereLabel },
                activate: { actions.beginUninstall() })
            .padding(.horizontal, -4)
    }

    private var healthy: some View {
        // 2026-09-11: the honest-status notices sit
        // at the TOP of the healthy branch, not in place of it. Neither state
        // has a repair the popover owns, and both leave the rest useful.
        VStack(alignment: .leading, spacing: UIMetrics.sectionSpacing) {
            ForEach(UIPopoverNotice.active(noticeFacts), id: \.self) { notice in
                noticeView(notice)
            }
            UIDetectionViewPopoverRow(actions: actions, view: actions.detectionView)
            if state.pauseUntil == nil { pauseButton } else { pausedControls }
            if let error = actions.writeError {
                UIInlineMessage(text: error, symbol: UISymbol.writeError, tint: .systemRed)
            }
            footer
        }
    }

    // MARK: Footer (spec §9.2, §9.5)

    /// `Settings…`, the one thing that is not a status or a pause control
    /// (Popover-Protected). A plain text button with a hover highlight — the
    /// way Control Center draws its own footer row.
    ///
    /// "Turn off protection…" left the footer (owner delegated 2026-09-28,
    /// plan §2a): it was `confirm` + `pause(.restart)`, the
    /// same write the chooser's "Until this Mac restarts" makes behind the
    /// same PIN, so the capability keeps one path.
    private var footer: some View {
        VStack(spacing: 6) {
            UIPopoverRule()
            HStack(spacing: 8) {
                UIFooterButton(label: UIPopoverView.settingsLabel) { actions.openSettings() }
                    .focused($focus, equals: Focus.settings)
                    .uiControl("ui.settings.open", kind: .button,
                        read: { UIPopoverView.settingsLabel },
                        activate: { actions.openSettings() })
                Spacer(minLength: 8)
                UIPopoverWordmark().padding(.trailing, 4)
            }
            // Pulls the LABEL onto the same left edge as the cards above
            // it; the hover pill keeps its 8 pt and bleeds into the
            // popover's margin, which is how AppKit draws one.
            .padding(.horizontal, -4)
        }
        .padding(.top, 2)
    }

    static let settingsLabel = "Settings…"

    // MARK: Header

    /// Under a layer (PIN, Settings, a confirm card) the header shrinks to
    /// one row (review 2026-09-29, item 8): the layer is the subject, and a
    /// big "Protected ✓" above a lockout warning read as a contradiction.
    private var header: some View {
        let compact: Bool = { if case .none = actions.layer { return false }; return true }()
        return UIPopoverHeader(state: state, detectionView: actions.detectionView,
            detailOverride: nil, compact: compact)
    }

    // MARK: Standard session (read-only)

    private var childReadOnly: some View {
        let degraded = state.isDegraded
        return UIPopoverNoticeCard(symbol: UISymbol.lock, tint: degraded ? SentryColor.danger : SentryColor.muted,
            title: degraded ? UIPopoverCopy.childDegradedTitle : UIPopoverCopy.childManagedTitle,
            detail: degraded ? UIPopoverCopy.childDegradedDetail : UIPopoverCopy.childManagedDetail)
            .uiControl("ui.child.managed", kind: .text,
                read: { state.isDegraded ? UIPopoverView.childDegradedBody : UIPopoverView.childManagedBody })
    }

    // MARK: Needs permission (spec §8)

    /// One line and one button (board Popover-NeedsPermission). The runtime
    /// classifies the failure: Screen Recording permission opens the direct
    /// no-PIN handoff; model, component, and service failures keep their named
    /// repair surfaces and never open the privacy pane. The old durable
    /// capture row's sentence lives on in `captureRow` (the alerts.log ALERT
    /// carries the same words), which this card no longer draws.
    private var needsPermission: some View {
        let off = state.screenRecordingOff
        let label = off ? UIPopoverCopy.screenRecordingOffButton : UIPopoverCopy.repairButton
        let line = off ? UIPopoverCopy.screenRecordingOffLine : UIPopoverCopy.stoppedLine
        // A paused-and-lost machine has Resume as its one mustard button.
        let primary = state.pauseUntil == nil
        return UIPopoverInfoCard(shape: UIPopoverShape.hold) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Board Popover-NeedsPermission: a screen with a cross,
                    // not a second crossed shield under the header's.
                    Image(systemName: "rectangle.badge.xmark")
                        .foregroundStyle(SentryColor.ink)
                        .accessibilityHidden(true)
                    Text(line)
                        .uiFont(.callout, weight: .semibold)
                        .foregroundStyle(SentryColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .uiControl("ui.status.capture", kind: .text, read: { [state] in
                    state.screenRecordingOff ? UIPopoverCopy.screenRecordingOffLine : UIPopoverCopy.stoppedLine
                })
                Button { actions.beginProtectionRepair() } label: {
                    // One line where it fits, as the board draws it; shrinks
                    // to 0.75 then wraps, never truncates. Receipt: "Turn on
                    // Screen Recording" fits on one line at 1.00x in the 288 pt
                    // card (status-degraded render, test Mac,
                    // 2026-09-29); at 1.35x+ it wraps rather than hide words.
                    Text(label).minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .modifier(UIPopoverButtonLook(primary: primary))
                .focused($focus, equals: Focus.repair)
                .uiControl("ui.status.fix", kind: .button,
                    read: { [state] in
                        state.screenRecordingOff ? UIPopoverCopy.screenRecordingOffButton : UIPopoverCopy.repairButton
                    },
                    activate: { actions.beginProtectionRepair() })
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Exact copy from spec §8, kept for the parts that still name it: an
    /// honest instruction, not a promise. The card above uses the board's
    /// shorter line and one button.
    static let degradedBody = "SentryScreen needs a parent to restore protection. "
        + "Open repair to see the failed part and the correct next step."
    static let fixLabel = "Open repair…"

    /// The old persistent capture row (2026-09-07), two
    /// states because the popover must not name a cause it does not know.
    /// Same sentence the `alerts.log` ALERT carries, so the health report and
    /// this constant tell one story. No longer drawn: the needs-permission
    /// card says the same in the board's words.
    static let captureOffRow = "Screen Recording is off — protection is not running"
    static let captureLostRow = "Protection is not running"
    static func captureRow(screenRecordingOff: Bool) -> String {
        screenRecordingOff ? captureOffRow : captureLostRow
    }

    /// Spec §8.
    /// `guideMode`: dim everything but the System Settings window, with the
    /// add-entry helper only when the caller knows the app row is missing.
    /// Off under the UI driver so E2E screenshots stay byte-stable.
    ///
    /// Callers classify the failure and choose the guide mode before they
    /// reach this presentation wrapper. Permission-only repair needs no app
    /// PIN because macOS owns the permission change.
    static func openScreenRecordingSettings(guideMode: ScreenRecordingGuideMode? = nil) {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        let opened = NSWorkspace.shared.open(url)
        if opened, let guideMode, UIDriver.scriptPath == nil {
            FixSpotlight.shared.begin(mode: guideMode)
        }
        if !opened {
            // Loud, never silent: the button promised to open something.
            FileHandle.standardError.write(Data((
                "ui: FAILED to open \(url.absoluteString) — open System Settings > Privacy & "
                + "Security > Screen & System Audio Recording by hand\n").utf8))
        }
    }

    // MARK: Notices (one card each, urgency order)

    private var noticeFacts: UIPopoverNotice.Facts {
        UIPopoverNotice.Facts(
            detector: state.protection.detectorIsFailing,
            displays: state.displayScope.hasUnprotectedDisplays,
            // Schema v2 removed `pin` from UISettings; the PIN
            // lives in the protected store, so this keys off the state flag.
            noPin: !state.hasParentPIN,
            devState: state.devStateRoot)
    }

    @ViewBuilder private func noticeView(_ notice: UIPopoverNotice) -> some View {
        switch notice {
        case .detector: detectorFailing
        case .displays: displayScopeWarning
        case .noPin: noPin
        case .devState: devState
        }
    }

    /// A tappable notice: the whole card is the button, with a chevron.
    private func tappableNotice(
        symbol: String, tint: Color, title: String, detail: String?, id: String,
        read: @escaping () -> String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            UIPopoverNoticeCard(symbol: symbol, tint: tint, title: title, detail: detail, chevron: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .uiControl(id, kind: .button, read: read, activate: action)
    }

    /// The detector stopped answering. RED: protection is not doing what the
    /// green shield promises, which is the one thing the header reserves red
    /// for. No button: the model is loaded once per launch, so the one action
    /// a parent has is the restart the copy names.
    private var detectorFailing: some View {
        UIPopoverNoticeCard(symbol: UISymbol.warning, tint: SentryColor.danger,
            title: UIPopoverCopy.detectorTitle, detail: UIPopoverCopy.detectorDetail)
            .uiControl("ui.status.detector", kind: .text,
                read: { UIPopoverCopy.detectorTitle + " " + UIPopoverCopy.detectorDetail })
    }

    /// More displays than protection covers: "needs a parent to know", not
    /// "protection is off". Persistent (drawn from state, no dismiss).
    private var displayScopeWarning: some View {
        UIPopoverNoticeCard(symbol: UISymbol.warning, tint: SentryColor.accent,
            title: UIPopoverView.displayScopeText(state.displayScope))
            .uiControl("ui.status.displays", kind: .text,
                read: { [state] in UIPopoverView.displayScopeText(state.displayScope) })
    }

    static func displayScopeText(_ scope: DisplayScope) -> String {
        ProtectionCopy.displayRow(scope)
    }

    /// Until a PIN exists no mutation is possible, so this is the one thing
    /// worth doing. Tapping opens the same set-PIN layer a pause tap would.
    private var noPin: some View {
        tappableNotice(symbol: UISymbol.setPin, tint: SentryColor.accent,
            title: UIPopoverCopy.noPinTitle, detail: UIPopoverCopy.noPinDetail, id: "ui.status.nopin",
            read: { UIPopoverCopy.noPinTitle + " " + UIPopoverCopy.noPinDetail }) { actions.beginSetPin() }
    }

    /// Kept for its pins (UISelfTest); the notice draws `noPinTitle`.
    static let noPinText = "Set a PIN to manage protection"

    private var devState: some View {
        UIInlineMessage(text: UIPopoverView.devStateText, symbol: UISymbol.devState, tint: .systemOrange)
            .uiControl("ui.status.devstate", kind: .text, read: { UIPopoverView.devStateText })
    }

    static let devStateText = "Developer state — settings apply to this account only"

    private func layerTitle(_ title: String, buttonLabel: String, buttonID: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // Popover-Layers: Shantell 19 pt, as the Settings title.
            Text(title)
                .uiDisplayFont(size: 19)
                .foregroundStyle(SentryColor.ink)
            Spacer(minLength: 8)
            Button(buttonLabel) { sheet = nil }
                .buttonStyle(.sentryQuiet)
                .keyboardShortcut(.cancelAction)
                .uiControl(buttonID, kind: .button, read: { buttonLabel }, activate: { sheet = nil })
        }
    }

    // MARK: Pause (spec §9.2, Addendum 7)

    /// Spec §9.2: "you cannot pause what is not running". Resume is
    /// deliberately NOT gated on it — a paused-and-degraded machine still
    /// needs the way back. One predicate for both `.disabled` and the
    /// registry's `enabled` closure; written twice they drift, and the drift
    /// is invisible to the E2E suite.
    private var pauseDisabled: Bool { state.isDegraded }

    /// The one mustard button of a protecting state. It opens the chooser; the
    /// presets and their PIN prompt are unchanged behind it.
    private var pauseButton: some View {
        Button { sheet = .pause } label: {
            HStack(spacing: 8) {
                Image(systemName: UISymbol.pause).accessibilityHidden(true)
                Text(UIPopoverCopy.pauseOpenLabel)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.sentryPrimary)
        .padding(.trailing, SentryPrimaryButtonStyle.shadowOffset.width)
        .padding(.bottom, SentryPrimaryButtonStyle.shadowOffset.height)
        .disabled(pauseDisabled)
        .uiControl("ui.pause.open", kind: .button, read: { UIPopoverCopy.pauseOpenLabel },
            activate: { sheet = .pause }, enabled: { !pauseDisabled })
    }

    /// "Pause for…": the three presets, with the scope sentence Addendum 7
    /// requires where the parent reads it before choosing (the PIN prompt
    /// repeats it at the moment of confirmation).
    private var pauseChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            layerTitle(UIPopoverCopy.pauseTitle, buttonLabel: UIPopoverCopy.cancel, buttonID: "ui.pause.cancel")
            UISection(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(PausePreset.allCases.enumerated()), id: \.element) { index, preset in
                        if index > 0 {
                            UIPopoverRule().padding(.leading, UIMetrics.sectionPadding)
                        }
                        UIListRow(label: preset.label, isDisabled: pauseDisabled) {
                            sheet = nil
                            actions.pause(preset)
                        }
                        .uiControl(preset.controlID, kind: .button, read: { preset.label },
                            activate: { sheet = nil; actions.pause(preset) },
                            enabled: { !pauseDisabled })
                    }
                }
                .padding(.vertical, 4)
            }
            Text(UIPopoverCopy.pauseChooserNote)
                .uiFont(.caption)
                .foregroundStyle(SentryColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
                .uiControl("ui.pause.caption", kind: .text, read: { UIPopoverCopy.pauseChooserNote })
        }
        .transition(.opacity)
    }

    /// Paused: who paused it, and Resume now. Resume is the mustard button
    /// unless a lost capture put Repair in that place. A panic pause shows
    /// its chip instead of the machine-wide title: it paused this session
    /// only, and nobody chose it from the chooser (owner 2026-09-29).
    private var pausedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            UIPopoverInfoCard(fill: SentryColor.accentSoft) {
                VStack(alignment: .leading, spacing: 3) {
                    if let panic = state.activePanic {
                        UIPopoverChip(text: UIPopoverCopy.panicChip(panic))
                    } else {
                        Text(UIPopoverCopy.pausedTitle)
                            .uiFont(.callout, weight: .semibold)
                            .foregroundStyle(SentryColor.ink)
                        if let by = pausedByLine {
                            Text(by)
                                .uiFont(.caption)
                                .foregroundStyle(SentryColor.ink2)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .uiControl("ui.pause.caption", kind: .text, read: { pausedCaption })
            Button { actions.resume() } label: {
                Text(UIPopoverCopy.resumeLabel).frame(maxWidth: .infinity)
            }
            .modifier(UIPopoverButtonLook(primary: !state.isDegraded))
            .uiControl("ui.pause.resume", kind: .button, read: { UIPopoverCopy.resumeLabel },
                activate: { actions.resume() })
        }
    }

    private var pausedCaption: String {
        if let panic = state.activePanic { return UIPopoverCopy.panicChip(panic) }
        return [UIPopoverCopy.pausedTitle, pausedByLine].compactMap { $0 }.joined(separator: " ")
    }

    private var pausedByLine: String? {
        state.settings.pause.by.map { "Paused by " + UIPopoverView.displayName($0) }
    }

    /// `parent(501)` → the account's full name ("Parent"), or the short name
    /// when the account has none or is gone (review 2026-09-29, item 13).
    static func displayName(_ label: String, fullName: (String) -> String? = accountFullName) -> String {
        let short = shortName(label)
        guard let full = fullName(short)?.trimmingCharacters(in: .whitespaces), !full.isEmpty else { return short }
        return full
    }

    /// The account's Full Name (passwd gecos, first field), or nil.
    static func accountFullName(_ short: String) -> String? {
        guard !short.isEmpty, let pw = getpwnam(short), let gecos = pw.pointee.pw_gecos else { return nil }
        return String(cString: gecos).split(separator: ",", omittingEmptySubsequences: false).first.map(String.init)
    }

    /// `parent(501)` → `parent`. The uid belongs in the log record, not
    /// in a sentence a parent reads.
    static func shortName(_ label: String) -> String {
        String(label.prefix(while: { $0 != "(" }))
    }

    // MARK: Sensitivity (spec §6, §9.2)

    /// Spec §6 precedence: the `--policy` flag pins the run (D1 flags-win),
    /// and a control that cannot act must say why rather than pretend.
    /// Spec §9.2 copy, two lines at 320 pt.
    static let sensitivityCaption = "Standard covers explicit content. "
        + "Strict also covers swimwear and underwear."
    /// Spec §6: `Set by command line`, said as a sentence rather than a
    /// label, because the parent's next question is "then how do I change
    /// it".
    static let sensitivityPinnedText = "Set by command line for this run — "
        + "the --policy flag wins over this setting."

    // MARK: Recent activity (spec §7, §9.2)

    /// App name + relative time per row, nothing else (§7.3). Every failure
    /// mode is a visible row: an unreadable session (`ui.activity.error`), a
    /// tail that hit `LogTail.maxTailBytes` (`ui.activity.truncated`), and
    /// "nothing yet" (`ui.activity.empty`) — never a short list that looks
    /// like a quiet day.
    static let activityEmptyText = "Nothing has been covered yet"
    /// Says a limit clipped and names it in the unit a parent can act on. The
    /// developer-visible symbol and remediation location stay in this comment.
    static let activityTruncatedText = "Older activity not shown — a log is larger than the "
        + "\(LogTail.maxTailBytes / 1024 / 1024) MB SentryScreen reads"
    /// Spec §7.3, verbatim.
    static let activityFooterText = "SentryScreen never stores images of the screen."
}

/// Primary (mustard, with its shadow's room), outline, or quiet-link look for
/// a button whose weight depends on the state around it.
private struct UIPopoverButtonLook: ViewModifier {
    let primary: Bool
    var quiet = false

    func body(content: Content) -> some View {
        if quiet {
            content.buttonStyle(.sentryQuiet)
        } else if primary {
            content
                .buttonStyle(.sentryPrimary)
                .padding(.trailing, SentryPrimaryButtonStyle.shadowOffset.width)
                .padding(.bottom, SentryPrimaryButtonStyle.shadowOffset.height)
        } else {
            content
                .buttonStyle(UIPopoverOutlineButtonStyle())
                .padding(.trailing, SentryPrimaryButtonStyle.shadowOffset.width)
        }
    }
}

/// Operational sensitivity lives in Settings so the root popover can remain
/// a status-and-action surface. Control ids and PIN behavior are unchanged.
struct UISensitivitySettingsSection: View {
    @ObservedObject var state: UIState
    @ObservedObject var actions: UIActions

    private var disabled: Bool { state.policyPinned }

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.labelGap) {
            UISectionLabel(text: "Sensitivity")
            UISection {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Sensitivity", selection: Binding(
                        get: { state.policy }, set: { actions.setPolicy($0) })) {
                        Text(PolicyMode.standard.displayName).tag(PolicyMode.standard)
                        Text(PolicyMode.strict.displayName).tag(PolicyMode.strict)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(disabled)
                    .uiControl("ui.sensitivity", kind: .picker,
                        read: { state.policy.rawValue }, enabled: { !disabled })
                    .background(alignment: .topLeading) { segmentAnchors }
                    Text(UIPopoverView.sensitivityCaption)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if disabled {
                        UIInlineMessage(text: UIPopoverView.sensitivityPinnedText,
                            symbol: UISymbol.commandLine, tint: .systemOrange)
                            .uiControl("ui.sensitivity.pinned", kind: .text,
                                read: { UIPopoverView.sensitivityPinnedText })
                    }
                }
            }
        }
    }

    private var segmentAnchors: some View {
        ZStack {
            Color.clear.frame(width: 1, height: 1)
                .uiControl("ui.sensitivity.standard", kind: .button,
                    read: { PolicyMode.standard.displayName },
                    activate: { actions.setPolicy(.standard) }, enabled: { !disabled })
            Color.clear.frame(width: 1, height: 1)
                .uiControl("ui.sensitivity.strict", kind: .button,
                    read: { PolicyMode.strict.displayName },
                    activate: { actions.setPolicy(.strict) }, enabled: { !disabled })
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Recent activity is available on demand in Settings. It remains text-only
/// and keeps every explicit empty, error, truncation, and session state.
struct UIActivitySettingsSection: View {
    @ObservedObject var activity: UIActivity
    @Environment(\.uiTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.labelGap) {
            UISectionLabel(text: "Recent activity")
            UISection(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(activity.errors.enumerated()), id: \.offset) { i, error in
                        UIInlineMessage(text: error, symbol: UISymbol.error, tint: .systemRed)
                            .padding(.horizontal, UIMetrics.sectionPadding)
                            .padding(.vertical, 6)
                            .uiControl(i == 0 ? "ui.activity.error" : "ui.activity.error.\(i)",
                                kind: .text, read: { [activity] in activity.errorText(i) })
                    }
                    if activity.items.isEmpty && activity.errors.isEmpty {
                        Text(UIPopoverView.activityEmptyText)
                            .uiFont(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, UIMetrics.sectionPadding)
                            .frame(minHeight: UIMetrics.activityRowHeight(scale: textScale))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .uiControl("ui.activity.empty", kind: .text,
                                read: { UIPopoverView.activityEmptyText })
                    }
                    if !activity.items.isEmpty {
                        if !activity.errors.isEmpty {
                            Divider().padding(.leading, UIMetrics.sectionPadding)
                        }
                        itemList
                    }
                    if activity.truncated {
                        Divider().padding(.leading, UIMetrics.sectionPadding)
                        UIInlineMessage(text: UIPopoverView.activityTruncatedText,
                            symbol: UISymbol.warning, tint: .systemOrange)
                            .padding(.horizontal, UIMetrics.sectionPadding)
                            .padding(.vertical, 6)
                            .uiControl("ui.activity.truncated", kind: .text,
                                read: { UIPopoverView.activityTruncatedText })
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(Array(activity.sessions.enumerated()), id: \.offset) { i, session in
                Text("\(session.user) — \(session.text)")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .uiControl("ui.activity.session.\(i)", kind: .text,
                        read: { [activity] in activity.sessionText(i) })
            }
            Text(UIPopoverView.activityFooterText)
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
                .uiControl("ui.activity.footer", kind: .text,
                    read: { UIPopoverView.activityFooterText })
        }
    }

    /// Owner 2026-10-20: the list shows `UIActivity.visibleRows` (3) rows and
    /// scrolls to the rest; `UIActivity.rows` (10) is unchanged. Only the
    /// item rows scroll — the error, empty and truncation rows and the
    /// footer stay outside. The viewport is the visible rows' own minimum
    /// height, so it scales with the text size; the rows' dividers are
    /// overlays, so they add no height the viewport would have to guess.
    /// Every row stays in the registry (a plain VStack, not lazy), and
    /// `scrollto ui.activity.row.N` reaches the hidden ones
    /// (`UIScrollAnchors.register(_:in:container:)`).
    private var itemList: some View {
        let shown = min(activity.items.count, UIActivity.visibleRows)
        return ScrollView(.vertical) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ForEach(Array(activity.items.enumerated()), id: \.offset) { i, item in
                        activityRow(item, index: i)
                            .overlay(alignment: .top) {
                                if i > 0 { Divider().padding(.leading, UIMetrics.sectionPadding) }
                            }
                            .uiScrollAnchor("ui.activity.row.\(i)", in: proxy, container: Self.listID)
                    }
                }
            }
        }
        .scrollIndicators(activity.items.count > UIActivity.visibleRows ? .visible : .hidden)
        .frame(height: CGFloat(shown) * UIMetrics.activityRowHeight(scale: textScale))
        .uiScrollAnchor(Self.listID)
        .uiControl(Self.listID, kind: .text,
            read: { [activity] in "\(min(activity.items.count, UIActivity.visibleRows)) of \(activity.items.count) rows visible" })
    }

    static let listID = "ui.activity.list"

    private func activityRow(_ item: ActivityItem, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(item.app).uiFont(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Text(UIActivity.relative(item.at))
                .uiFont(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, UIMetrics.sectionPadding)
        .frame(minHeight: UIMetrics.activityRowHeight(scale: textScale))
        .uiControl("ui.activity.row.\(index)", kind: .text,
            read: { [activity] in activity.rowText(index) })
    }
}

/// The popover header (boards): the Lantern badge, the state line and the
/// detail line. Its own view so it can observe the Detection view,
/// whose Detections-only mode turns the header into "Protection off" (D4)
/// without the rest of the popover re-rendering, and so a timed pause's
/// countdown redraws only this Text (see `UIPauseCountdown`).
struct UIPopoverHeader: View {
    @ObservedObject var state: UIState
    @ObservedObject var detectionView: DetectionViewController
    /// Replaces the detail line while a layer says something more useful
    /// (the plan choice shows the trial's days left).
    var detailOverride: String? = nil
    /// One row: small badge, the state in 15 pt lettering, the detail after
    /// it on the same line, no check mark.
    var compact = false
    /// Compact sizes (DERIVED): the badge is the 32 pt root badge
    /// (`UIMetrics.headerBadge`) scaled by 15/22, the same ratio as the
    /// lettering, which drops from the 22 pt root header to 15 pt so the
    /// state and its detail share one 288 pt row (`popoverWidth` 320 less
    /// two 16 pt `popoverPadding` gutters). A detail that does not fit wraps
    /// under the state (`compactBody`).
    static let compactBadge: CGFloat = 22
    static let compactTitleSize: CGFloat = 15
    @Environment(\.uiTextScale) private var textScale

    private var headerText: String {
        return UIDetectionViewHeader.header(state: state, view: detectionView)
    }

    private var detailText: String {
        if let detailOverride { return detailOverride }
        return UIDetectionViewHeader.detail(state: state, view: detectionView)
    }

    private var glyph: UIGlyph {
        if UIDetectionViewHeader.overridesGlyph(state: state, view: detectionView) { return .degraded }
        return state.glyph
    }

    private var detailIsOverridden: Bool {
        return UIDetectionViewHeader.overridesGlyph(state: state, view: detectionView)
    }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// One row when the state and its detail fit; otherwise the detail wraps
    /// under the state. Never truncated (the redesign's text rule): a long
    /// detail ("Only <display> is covered", a grace or trial line) or a
    /// larger text size takes a second line instead of losing its end.
    private var compactBody: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                compactBadgeView
                compactTitle
                detailLine.fixedSize()
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                compactBadgeView
                VStack(alignment: .leading, spacing: 2) {
                    compactTitle
                    detailLine.fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    private var compactBadgeView: some View {
        badgeView(size: UITypography.points(Self.compactBadge, scale: textScale))
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
    }

    private var compactTitle: some View {
        Text(headerText)
            .uiDisplayFont(size: Self.compactTitleSize)
            .foregroundStyle(SentryColor.ink)
            .fixedSize()
            .uiControl("ui.status.header", kind: .text, read: {
                return UIDetectionViewHeader.header(state: state, view: detectionView)
            })
    }

    private var fullBody: some View {
        // Top, not centre: a three-line "Protection is interrupted" title
        // left the badge floating mid-block (VM render 2026-10-20).
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Popover-Protected: Shantell 22 pt.
                    Text(headerText)
                        .uiDisplayFont(size: 22)
                        .foregroundStyle(SentryColor.ink)
                        // "Protection is off" and its neighbours can reach two
                        // lines at a larger text size.
                        .fixedSize(horizontal: false, vertical: true)
                        .uiControl("ui.status.header", kind: .text, read: {
                            return UIDetectionViewHeader.header(state: state, view: detectionView)
                        })
                    if glyph == .protecting {
                        Image(systemName: UISymbol.check)
                            .foregroundStyle(SentryColor.ok)
                            .accessibilityHidden(true)
                    }
                }
                detailLine
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    /// A timed pause redraws its countdown every `UIActivity.refreshSecs`;
    /// every other detail is static between publishes.
    @ViewBuilder private var detailLine: some View {
        if detailOverride == nil, !detailIsOverridden, let until = state.pauseUntil, until != .distantFuture {
            TimelineView(.periodic(from: .now, by: UIActivity.refreshSecs)) { context in
                detailView(UIPauseCountdown.detail(until: until, now: context.date))
            }
        } else {
            detailView(detailText)
        }
    }

    private func detailView(_ text: String) -> some View {
        Text(text)
            .uiFont(.subheadline)
            .foregroundStyle(SentryColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .uiControl("ui.status.detail", kind: .text, read: { detailText })
    }

    /// Lantern's face while protecting; otherwise a paper tile with the
    /// state's symbol (pause bars for a pause, the shield for the rest).
    private var badge: some View { badgeView(size: UIMetrics.headerBadge(scale: textScale)) }

    @ViewBuilder private func badgeView(size: CGFloat) -> some View {
        if glyph == .protecting {
            SentryLanternFace(size: size)
        } else {
            let shape = UIPopoverShape.hand(10, 8, 11, 9)
            Image(systemName: glyph.headerSymbol)
                .uiFont(.callout, weight: .semibold)
                // Degraded draws the board's full-strength red crossed
                // shield; hierarchical rendering washed it out to pink.
                .symbolRenderingMode(glyph == .degraded ? .monochrome : .hierarchical)
                .fontWeight(glyph == .degraded ? .bold : nil)
                .foregroundStyle(tileTint)
                .frame(width: size, height: size)
                .background(shape.fill(SentryColor.paper2))
                .overlay(shape.strokeBorder(SentryColor.line, lineWidth: 2))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
    }

    private var tileTint: Color {
        switch glyph {
        case .degraded: return SentryColor.danger
        case .paused: return SentryColor.ink2
        case .starting, .protecting: return SentryColor.muted
        }
    }

    private var summary: String {
        if UIDetectionViewHeader.overridesGlyph(state: state, view: detectionView) {
            return "SentryScreen — \(DetectionViewCopy.protectionOffHeader)"
        }
        return state.statusSummary
    }
}

extension UIState {
    /// The pause deadline in effect right now, or nil. One evaluation point
    /// for the header, the detail line and the menu-bar glyph, so they can
    /// never disagree about whether the machine is paused. The later of the
    /// settings pause and this session's panic pause, the same composition
    /// the pipeline obeys (`PauseState.compose`).
    var pauseUntil: Date? {
        let panic = panicPause.map(\.until).flatMap { $0 > Date() ? $0 : nil }
        return PauseState.compose(panic: panic, settings: settings.pause.effectiveUntil())
    }

    /// The panic pause while it is in effect, or nil.
    var activePanic: PanicPause? {
        guard let panicPause, panicPause.until > Date() else { return nil }
        return panicPause
    }

    /// True exactly when `CaptureLossBanner` is up (spec §8 invariant; the
    /// five call sites that set `captureHealth` live in main.swift). Keyed on
    /// CAPTURE health alone, never on pause and never on the detector: a paused
    /// machine whose screen access is gone still needs the way back, and a
    /// detector fault has no Screen Recording repair to offer — it gets its own
    /// persistent row instead (`ProtectionCopy.detectorRow`). Narrowing this
    /// to capture is what keeps the §8 banner invariant true.
    var isDegraded: Bool {
        if case .lost = captureHealth { return true }
        return false
    }

    /// The composed verdict (ProtectionHealth.swift). The header, the detail
    /// line, the glyph and the status toast all read THIS, so the green shield
    /// is no longer a function of capture health alone.
    var protection: ProtectionHealth {
        let health = ProtectionHealth.compose(capture: captureHealth, detector: detectorHealth)
        if pauseResumePending, health == .protecting { return .starting }
        return health
    }

    /// Sensitivity the picker shows (spec §6 precedence: `--policy` flag >
    /// settings.json policyOverride > config.json policy / mode default,
    /// the last two of which are `basePolicy`, resolved once by Pipeline and
    /// pushed here so the two cannot drift).
    var policy: PolicyMode { policyPinned ? basePolicy : (settings.policyOverride ?? basePolicy) }

    /// Header line (boards Popover-*, plan §2). Paused wins over health: a
    /// paused machine is the state the parent asked for. A lost capture reads
    /// "Protection is off"; the detail line and the card below say why.
    var headerText: String {
        if pauseUntil != nil { return "Paused" }
        switch protection {
        case .starting: return "Starting…"
        case .protecting: return "Protected"
        case .detectorFailing: return ProtectionCopy.detectorHeader
        case .captureLost: return "Protection is off"
        }
    }

    /// The .subheadline line under the header. A timed pause counts down (see
    /// `UIPauseCountdown`); a lost capture says since when (spec §8), and its
    /// developer reason string is NOT shown here any more (it stays in the
    /// alerts.log ALERT and the repair window).
    var detailText: String {
        if let until = pauseUntil { return UIPauseCountdown.detail(until: until, now: Date()) }
        switch protection {
        case .starting: return "Getting ready to protect this Mac"
        // "this Mac" overstated the coverage on a multi-display
        // Mac — a parent reads it as every screen.
        case .protecting: return ProtectionCopy.watchingDetail(displayScope)
        case .detectorFailing: return ProtectionCopy.detectorDetail
        case let .captureLost(since, _): return "Since \(Self.clockTime.string(from: since))"
        }
    }

    /// Short wall-clock time ("3:45 PM"), locale-formatted.
    static let clockTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

/// The footer's "SentryScreen" wordmark: decorative, so hidden from
/// accessibility (the popover already names the app).
struct UIPopoverWordmark: View {
    var body: some View {
        Text(SentryBrand.productName)
            .uiDisplayFont(size: UIPopoverView.footerWordmarkSize)
            .foregroundStyle(SentryColor.muted)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}
