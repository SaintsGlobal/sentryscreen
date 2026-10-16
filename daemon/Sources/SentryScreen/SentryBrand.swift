import AppKit
import SwiftUI

/// App-owned presentation primitives shared by onboarding and the parent UI.
/// Operational state stays in the existing coordinators and stores.
enum SentryBrand {
    static let productName = "SentryScreen"

    /// "One primary per state".
    /// Slices call this from their own self-tests with the ids of
    /// every `.sentryPrimary` control a state shows. Returns nil when the
    /// state has at most one, else a failure line naming the budget, the
    /// limit, the observed count, the ids and where to fix it.
    static let primaryButtonsPerStateLimit = 1

    static func primaryButtonBudgetFailure(state: String, primaryIDs: [String]) -> String? {
        guard primaryIDs.count > primaryButtonsPerStateLimit else { return nil }
        return "budget=primary-buttons-per-state limit=\(primaryButtonsPerStateLimit)"
            + " observed=\(primaryIDs.count) state=\(state) ids=\(primaryIDs)"
            + " fix=make all but one of these .sentryQuiet in the view that draws '\(state)'"
    }
}

/// The paper-and-ink interface tokens of the website, with the night room
/// following the system's dark mode. Receipt: every value below is copied
/// from sentryscreen-web DESIGN.md (design/theme.mjs), paper value first, night value
/// second. The night `controlBorder` is DESIGN.md's warm sand `#cdb994`
/// (owner approved 2026-09-29, plan §6 item 6); it was the favicon's
/// `#f3e6cc` while that was open.
///
/// Each token is one dynamic `NSColor` that resolves against the drawing
/// appearance, so a view never switches on `colorScheme` itself. `SentryColor`
/// is the SwiftUI side; `SentryColor.NS` is the AppKit side.
enum SentryColor {
    enum NS {
        static let wall = room("wall", 0xf0e2c4, 0x2a1f18)
        static let paper = room("paper", 0xf6ecd5, 0x1f1712)
        static let paper2 = room("paper2", 0xecdcbb, 0x261c16)
        static let slip = room("slip", 0xfbf5e6, 0xe9dcc0)
        static let slipInk = room("slipInk", 0x2b1d16, 0x2b1d16)
        static let ink = room("ink", 0x2b1d16, 0xf3e6cc)
        static let ink2 = room("ink2", 0x4a3326, 0xdccbaa)
        static let muted = room("muted", 0x6b5140, 0xb8a384)
        /// Ink at 20% by day, cream at 16% at night.
        static let line = room("line", 0x2b1d16, 0xf3e6cc, dayAlpha: 0.20, nightAlpha: 0.16)
        static let controlBorder = room("controlBorder", 0x2b1d16, 0xcdb994)
        static let accent = room("accent", 0x8e3b22, 0xe9b949)
        static let accentSoft = room("accentSoft", 0xf1dcb4, 0x3a2b1c)
        /// Mustard: the one primary button.
        static let primary = room("primary", 0xd6a53a, 0xe2ae45)
        static let primaryHover = room("primaryHover", 0xe3b44d, 0xefbf5c)
        static let primaryInk = room("primaryInk", 0x2b1d16, 0x2b1d16)
        /// The offset shadow and the primary button's edge: ink by day,
        /// black at 55% at night.
        static let buttonShadow = room("buttonShadow", 0x2b1d16, 0x000000, nightAlpha: 0.55)
        /// The strong (ink-filled) button's offset shadow. By day its fill is
        /// the same ink as `buttonShadow`, so the shadow merged with the fill
        /// and notched its trailing edge (light mode); DESIGN.md
        /// does not cover an ink-on-ink shadow, so by day it has none. At
        /// night the fill is cream and the shadow is `buttonShadow`.
        static let strongShadow = room("strongShadow", 0x2b1d16, 0x000000, dayAlpha: 0, nightAlpha: 0.55)
        static let focus = room("focus", 0x2458c6, 0x86b0ff)
        static let danger = room("danger", 0xa3311e, 0xff9d8a)
        static let ok = room("ok", 0x3d6b30, 0x8fd69a)
        static let cover = room("cover", 0x2b1d16, 0x140d09)
        static let coverInk = room("coverInk", 0xf6ecd5, 0xf6ecd5)

        static func room(
            _ name: String, _ paper: UInt32, _ night: UInt32,
            dayAlpha: CGFloat = 1, nightAlpha: CGFloat = 1
        ) -> NSColor {
            NSColor(name: NSColor.Name("SentryScreen." + name)) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? rgb(night, alpha: nightAlpha)
                    : rgb(paper, alpha: dayAlpha)
            }
        }

        static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
    }

    static let wall = Color(nsColor: NS.wall)
    static let paper = Color(nsColor: NS.paper)
    static let paper2 = Color(nsColor: NS.paper2)
    static let slip = Color(nsColor: NS.slip)
    static let slipInk = Color(nsColor: NS.slipInk)
    static let ink = Color(nsColor: NS.ink)
    static let ink2 = Color(nsColor: NS.ink2)
    static let muted = Color(nsColor: NS.muted)
    static let line = Color(nsColor: NS.line)
    static let controlBorder = Color(nsColor: NS.controlBorder)
    static let accent = Color(nsColor: NS.accent)
    static let accentSoft = Color(nsColor: NS.accentSoft)
    static let primary = Color(nsColor: NS.primary)
    static let primaryHover = Color(nsColor: NS.primaryHover)
    static let primaryInk = Color(nsColor: NS.primaryInk)
    static let buttonShadow = Color(nsColor: NS.buttonShadow)
    static let strongShadow = Color(nsColor: NS.strongShadow)
    static let focus = Color(nsColor: NS.focus)
    static let danger = Color(nsColor: NS.danger)
    static let ok = Color(nsColor: NS.ok)
    static let cover = Color(nsColor: NS.cover)
    static let coverInk = Color(nsColor: NS.coverInk)
}

/// The mustard primary button. Geometry is copied from the approved boards'
/// primary (Popover-Main, Setup-1-Welcome, Uninstall-App): a 3 pt edge
/// in `buttonShadow`, hand-cut radii 14/11/15/12, and a 3-by-4 pt offset
/// shadow with no blur. The label uses the system face (Shantell Sans is an
/// open decision, plan §2) at `.headline`, because ui-mvp-spec §9.3 allows
/// only headline/subheadline/callout/caption; the boards draw 16-18 px, an
/// open decision against that rule. Pressing drops the button onto its
/// shadow. The shadow is an offset, not layout: callers leave 3 pt free on
/// the trailing side and 4 pt below or it clips. Callers set width; one per
/// state (see `SentryBrand.primaryButtonBudgetFailure`).
struct SentryPrimaryButtonStyle: ButtonStyle {
    /// DESIGN.md "Strong": the same button with a neutral fill (`--ink`
    /// behind `--paper`, lettering in paper). The recommended choice inside
    /// a group, the Yearly plan. Never mustard, so a plan screen has no
    /// mustard button (DESIGN.md "Plan emphasis"; owner 2026-09-29).
    var strong = false
    /// Board values: Popover-Main's primary is 46 pt tall (Setup's
    /// is 50, set by its caller); Setup-1-Welcome pads the label 28 pt.
    static let minHeight: CGFloat = 46
    static let horizontalPadding: CGFloat = 28
    static let edgeWidth: CGFloat = 3
    static let shadowOffset = CGSize(width: 3, height: 4)
    /// DESIGN.md button states, "disabled": 55% opacity (the site's value).
    static let disabledOpacity: Double = 0.55
    static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 14, bottomLeadingRadius: 12,
        bottomTrailingRadius: 15, topTrailingRadius: 11, style: .continuous)

    func makeBody(configuration: Configuration) -> some View {
        SentryPrimaryButton(configuration: configuration, strong: strong)
    }
}

private struct SentryPrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    let strong: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var fill: Color {
        if strong { return hovering && isEnabled ? SentryColor.ink2 : SentryColor.ink }
        return hovering && isEnabled ? SentryColor.primaryHover : SentryColor.primary
    }

    var body: some View {
        let shape = SentryPrimaryButtonStyle.shape
        let offset = SentryPrimaryButtonStyle.shadowOffset
        let pressed = configuration.isPressed
        // Board primaries: Shantell 16 pt.
        configuration.label
            .uiDisplayFont(size: 16)
            .foregroundStyle(strong ? SentryColor.paper : SentryColor.primaryInk)
            .padding(.horizontal, SentryPrimaryButtonStyle.horizontalPadding)
            .frame(minHeight: SentryPrimaryButtonStyle.minHeight)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(SentryColor.buttonShadow,
                lineWidth: SentryPrimaryButtonStyle.edgeWidth))
            // DESIGN.md "disabled": no lift, no shadow, 55% opacity.
            .background(shape.fill(strong ? SentryColor.strongShadow : SentryColor.buttonShadow)
                .offset(pressed ? .zero : offset)
                .opacity(isEnabled ? 1 : 0))
            .offset(pressed && isEnabled ? offset : .zero)
            .opacity(isEnabled ? 1 : SentryPrimaryButtonStyle.disabledOpacity)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// The quiet action beside a primary: accent-coloured underlined text, as
/// the boards draw "Already paid? Check now" and "What's sent"
/// (Popover-Main, Setup-1-Welcome).
struct SentryQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SentryQuietButton(configuration: configuration)
    }
}

private struct SentryQuietButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .uiFont(.callout)
            .underline()
            .foregroundStyle(SentryColor.accent)
            .opacity(!isEnabled ? SentryPrimaryButtonStyle.disabledOpacity : configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// DESIGN.md "Inputs": a `--slip` field with a 3 pt `--btn-shadow` edge and
/// the `--r-ink-sm` hand-cut radii (10/14/9/12, CSS order TL/TR/BR/BL), at
/// least 48 pt tall. The slip stays light at night, so the field draws in the
/// light scheme in both rooms: slip ink, placeholder and caret stay readable
/// on the light slip (`--slip-ink` on `--slip` is 12.0:1 at night, DESIGN.md
/// contrast table). Used by every text and PIN field (setup, Set PIN, the
/// Settings key field) so the two rooms cannot drift apart again.
struct SentrySlipField: ViewModifier {
    static let minHeight: CGFloat = 48
    static let edgeWidth: CGFloat = 3
    static let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 12,
        bottomTrailingRadius: 9, topTrailingRadius: 14, style: .continuous)
    /// DESIGN.md "Error": the edge turns `--danger`.
    var invalid = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(SentryColor.slipInk)
            .environment(\.colorScheme, .light)
            .padding(.horizontal, 14)
            .frame(minHeight: Self.minHeight)
            .background(Self.shape.fill(SentryColor.slip))
            .overlay(Self.shape.strokeBorder(invalid ? SentryColor.danger : SentryColor.buttonShadow,
                lineWidth: Self.edgeWidth))
    }
}

extension View {
    func sentrySlipField(invalid: Bool = false) -> some View { modifier(SentrySlipField(invalid: invalid)) }
}

/// DESIGN.md "Step numbers": the numeral in the lettering at 700 in
/// `--ink-2`, centred in a 28 pt circle of `--paper-2` with a 2 pt `--line`
/// edge. No mustard, no ink edge, no shadow. The current step is told apart
/// by its label, never by a fill.
struct SentryStepNumber: View {
    static let diameter: CGFloat = 28
    static let edgeWidth: CGFloat = 2
    let number: Int

    var body: some View {
        // `--fs-base` (1rem, 16 px on the site).
        Text("\(number)")
            .uiDisplayFont(size: 16)
            .foregroundStyle(SentryColor.ink2)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Circle().fill(SentryColor.paper2))
            .overlay(Circle().strokeBorder(SentryColor.line, lineWidth: Self.edgeWidth))
            .accessibilityHidden(true)
    }
}

extension ButtonStyle where Self == SentryPrimaryButtonStyle {
    static var sentryPrimary: SentryPrimaryButtonStyle { .init() }
    static var sentryStrong: SentryPrimaryButtonStyle { .init(strong: true) }
}

extension ButtonStyle where Self == SentryQuietButtonStyle {
    static var sentryQuiet: SentryQuietButtonStyle { .init() }
}

/// The root popover has one current status, the pause control, actionable
/// notices, and the footer. Operational detail moves to Settings. These
/// constants make the information budget a self-tested contract instead of
/// an aesthetic preference that can drift one section at a time.
enum UIPopoverInformationBudget {
    static let currentStatusCount = 1
    static let nextActionCount = 1
    static let rootSections = ["status", "pause", "actionable notices", "footer"]
    static let settingsOnlySections = ["sensitivity", "recent activity"]
}
