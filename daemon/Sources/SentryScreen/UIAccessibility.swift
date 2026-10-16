import AppKit
import SwiftUI

// Accessibility primitives shared by the popover, the Settings pages and the
// setup wizard.
//
// WHY THIS FILE EXISTS AT ALL — MEASURED 2026-09-07 on an M1 Mac (macOS 26.6,
// swiftc 6.3.3, target arm64-apple-macosx14.0):
//
//   * A `.callout` `Text` inside an `NSHostingController` in a real `NSWindow`
//     measured 176.5 x 15.0 pt at EVERY `DynamicTypeSize` from `.large`
//     through `.accessibility5`. The environment value propagated (the view
//     read back `accessibility5`); the rendered size never moved.
//   * `@ScaledMetric(relativeTo: .callout) var h: CGFloat = 30` read back
//     exactly 30.0 at every one of those sizes.
//   * AppKit publishes five accessibility display options and none of them is
//     a text size (`NSAccessibility.h`: increase contrast, differentiate
//     without color, reduce transparency, reduce motion, invert colors).
//
// So macOS has no Dynamic Type: `dynamicTypeSize` and `@ScaledMetric` are
// inert here, and sprinkling them through this UI would have been a receipt
// for an accessibility behavior that does not exist. The app therefore owns
// ONE scale, `\.uiTextScale`, which is 1.0 in production and is raised only by
// the `textsize` script verb so the UI E2E suite can prove the layout reflows
// instead of clipping. Every font in the parent UI goes through `.uiFont`, so
// there is one code path at 1.0 and at 1.65.
/// A live-region announcement for text that changes under a control the
/// user is still on (the diagnostic-report notice: sending → sent).
/// SwiftUI on macOS has no `accessibilityLiveRegion`; AppKit's
/// `announcementRequested` is what VoiceOver reads. A no-op before
/// `NSApplication` exists (`--ui-selftest`) and under no assistive client
/// (the post is cheap; VoiceOver decides whether to speak).
enum UIAccessibilityAnnouncement {
    static func post(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

enum UITextScale {
    /// Production, and every pre-existing E2E render: the scaled path is not
    /// taken at all (see `UITypography.font`), so a default-size screenshot is
    /// byte-identical to one from before this file existed.
    static let standard: CGFloat = 1
    /// DERIVED from iOS Dynamic Type, which is the only shipped ratio table
    /// Apple publishes for these steps: body is 17 pt at the default `large`
    /// and 23 pt at `xxxLarge`, the largest NON-accessibility size — 23/17 =
    /// 1.353.
    static let large: CGFloat = 23.0 / 17.0
    /// DERIVED the same way: body is 28 pt at `accessibility1`, the first
    /// accessibility size — 28/17 = 1.647. Two steps are enough to prove
    /// reflow; the popover is 320 pt wide by spec §9.2 and the iOS AX5 ratio
    /// (53/17 = 3.1) would not describe any macOS surface.
    static let xl: CGFloat = 28.0 / 17.0

    /// Script/verb spelling → scale. The parser rejects anything else at parse
    /// time, before a window exists.
    static let named: [String: CGFloat] = ["standard": standard, "large": large, "xl": xl]
    static var acceptedValues: String { "standard|large|xl" }

    /// Test-only lever, read by the two surface hosts (`UIStatusItem.open`,
    /// `UIOnboardingWindowController`) when they build their root view. It is
    /// only ever written by the `textsize` script action, which is refused
    /// outside `--ui-demo` / the onboarding test driver exactly as `state` and
    /// `appearance` are, and which refuses to run while the surface it would
    /// change is already on screen (a live SwiftUI tree does not re-read it).
    /// Main thread only, like UIRegistry beside it.
    static var current: CGFloat = standard

    /// `1.35x` — for a log line or a failure message, never for a layout.
    static func describe(_ scale: CGFloat) -> String {
        String(format: "%.2fx", scale)
    }
}

private struct UITextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = UITextScale.standard
}

extension EnvironmentValues {
    /// Multiplier applied to every `.uiFont` and to the metrics that carry
    /// text or a control's height. 1.0 everywhere in production.
    var uiTextScale: CGFloat {
        get { self[UITextScaleKey.self] }
        set { self[UITextScaleKey.self] = newValue }
    }
}

/// The one place a `Font` is built from a text style.
enum UITypography {
    /// The static `Font` for a style, so the scale-1 path is the exact value
    /// the call site used before `.uiFont` existed. `Font.system(_:)` is
    /// documented to be the same font, but "documented to be the same" is not
    /// the guarantee a byte-compared render needs.
    static func base(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    /// The AppKit style whose point size macOS actually resolves for a
    /// SwiftUI text style. MEASURED 2026-09-07 (macOS 26.6):
    /// largeTitle 26, title1 22, title2 17, title3 15, headline 13 (bold),
    /// subheadline 11, body 13, callout 12, footnote 10, caption1 10,
    /// caption2 10 (medium). The sizes are read at runtime rather than copied
    /// into a table here so a future macOS that changes them scales from its
    /// own values, not from this measurement.
    static func appKitStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    /// The font a `.uiFont` call site draws with.
    ///
    /// At `UITextScale.standard` this returns the static style font (plus the
    /// caller's weight, exactly as `.font(.callout.weight(.medium))` did), so
    /// the default-size design is unchanged by construction. Above it, the
    /// style's measured macOS point size is multiplied and rounded to a whole
    /// point — SF Symbols and text both snap to whole points, and a fractional
    /// size makes two adjacent rows disagree by a hairline.
    static func font(
        _ style: Font.TextStyle, scale: CGFloat, weight: Font.Weight? = nil
    ) -> Font {
        guard scale != UITextScale.standard else {
            let font = base(style)
            return weight.map { font.weight($0) } ?? font
        }
        let system = NSFont.preferredFont(forTextStyle: appKitStyle(style))
        let size = (system.pointSize * scale).rounded()
        if let weight { return .system(size: size, weight: weight) }
        // No caller weight: keep the STYLE's own weight (headline is bold,
        // caption2 medium — MEASURED above), which only the descriptor knows.
        let scaled = NSFont(descriptor: system.fontDescriptor, size: size)
            ?? NSFont.systemFont(ofSize: size)
        return Font(scaled)
    }

    /// An explicit point size that must scale with the text around it — the
    /// popover's header glyph, the wizard's editorial title and state symbol.
    /// Same rounding rule as `font`.
    static func points(_ base: CGFloat, scale: CGFloat) -> CGFloat {
        scale == UITextScale.standard ? base : (base * scale).rounded()
    }
}

private struct UIScaledFont: ViewModifier {
    @Environment(\.uiTextScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let monospacedDigit: Bool
    let monospaced: Bool

    func body(content: Content) -> some View {
        var font = UITypography.font(style, scale: scale, weight: weight)
        if monospacedDigit { font = font.monospacedDigit() }
        if monospaced { font = font.monospaced() }
        return content.font(font)
    }
}

private struct UIScaledPointFont: ViewModifier {
    @Environment(\.uiTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(
            size: UITypography.points(size, scale: scale), weight: weight, design: design))
    }
}

extension View {
    /// `.font(.callout)` with the app's text scale applied. Use this instead
    /// of `.font(...)` everywhere in the parent UI: a raw `.font` call is a
    /// control that will not grow with the rest of the surface, which is the
    /// clipping the `textsize` E2E scripts exist to catch.
    func uiFont(
        _ style: Font.TextStyle, weight: Font.Weight? = nil,
        monospacedDigit: Bool = false, monospaced: Bool = false
    ) -> some View {
        modifier(UIScaledFont(
            style: style, weight: weight,
            monospacedDigit: monospacedDigit, monospaced: monospaced))
    }

    /// The rare explicit point size (a glyph or the wizard's editorial title),
    /// scaled by the same factor.
    func uiFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default)
        -> some View
    {
        modifier(UIScaledPointFont(size: size, weight: weight, design: design))
    }
}

/// The `appearance` script action's values (spec §10.2, `--ui-demo` only), in
/// one place: the popover driver, the onboarding driver and the onboarding
/// demo each used to spell the same `name == "dark"` ternary.
///
/// There are deliberately only two. A `light-contrast` value that rendered
/// Increase Contrast would have been the obvious way to make that setting
/// testable, and macOS does not offer one: MEASURED 2026-09-07 on macOS 26,
/// `NSAppearance(named: .accessibilityHighContrastAqua)`
/// returns an appearance whose own `name` is `NSAppearanceNameAqua`, and the
/// dark variant collapses to `NSAppearanceNameDarkAqua` — the high-contrast
/// appearances follow the SYSTEM setting and are not something an app can put
/// on one window. Increase Contrast is therefore asserted the way Reduce
/// Transparency is: as a pure mapping in `UISurface`, checked by
/// `--ui-selftest`.
enum UIAppearanceOption {
    static let names = ["light", "dark"]
    static var acceptedValues: String { names.joined(separator: "|") }

    static func appearance(_ name: String) -> NSAppearance? {
        NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
    }
}

/// Reduce Transparency and Increase Contrast, as pure functions of the two
/// accessibility settings, so `--ui-selftest` can assert the mapping without a
/// window and without changing the owner's own system settings.
///
/// Reduce Transparency cannot be faked: SwiftUI's
/// `\.accessibilityReduceTransparency` has no setter (MEASURED 2026-09-07: the
/// key path is `KeyPath`, not `WritableKeyPath`, so `.environment(...)` does
/// not compile) and the real flag is system-wide. Increase Contrast cannot be
/// faked either — see the receipt on `UIAppearanceOption`: macOS collapses the
/// high-contrast appearances onto the plain ones, so a window cannot wear one.
/// Both settings are therefore evidenced here rather than in a render.
enum UISurface {
    /// The grouped card's fill (spec §9.3: `controlBackgroundColor` at half
    /// strength so the popover's own vibrancy shows through — never a second
    /// material). Reduce Transparency means "window backgrounds should not be
    /// semi-transparent" (NSAccessibility.h), and this half-strength fill is
    /// exactly such a background, so it goes solid.
    static func cardFillOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : 0.5
    }

    /// The card's separator stroke. Increase Contrast already darkened it;
    /// Reduce Transparency needs the same treatment, because a solid card on a
    /// solid popover loses the vibrancy edge that used to separate them.
    static func cardStrokeOpacity(increasedContrast: Bool, reduceTransparency: Bool) -> Double {
        increasedContrast || reduceTransparency ? 0.95 : 0.42
    }
}
