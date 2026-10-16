import AppKit
import CoreText
import SwiftUI

// Shantell Sans Bold for titles, the primary button and the wordmark.
// The site's lettering face
// (sentryscreen-server DESIGN.md "Shantell Sans Bold").
//
// Receipt: SentryFontData.swift holds the TTF, converted on a test Mac with
// fontTools 4.60.2 (flavor=None) from sentryscreen-server
// site/fonts/shantell-sans-700.woff2, sha256
// f7e25716f7da1d461996fa14050e92b6b7b9f271e7ef3d0d8b67872fc7aa7112 (the
// file the website serves). The result's name table: family "Shantell Sans
// Light", style "Bold", 226 code points (Latin, curly quotes, ellipsis,
// middle dot, dashes).
//
// Registered once, process-scoped, on first use. A failure is loud (one
// named stderr line, the self-test checks it) and falls back to the system
// font, so text never disappears.
enum SentryFont {
    /// The registered PostScript name, or nil when registration failed.
    static let displayName: String? = register()

    /// Why registration failed, for the self-test; nil on success.
    private(set) static var failure: String?

    private static func register() -> String? {
        func fail(_ reason: String) -> String? {
            failure = reason
            FileHandle.standardError.write(Data(
                ("{\"event\":\"font\",\"reason\":\"\(reason)\",\"font\":\"ShantellSans-Bold\","
                    + "\"fix\":\"daemon/Sources/SentryScreen/SentryFontData.swift\"}\n").utf8))
            return nil
        }
        guard let data = Data(base64Encoded: SentryFontData.shantellBoldBase64,
            options: .ignoreUnknownCharacters)
        else { return fail("base64-decode") }
        guard let provider = CGDataProvider(data: data as CFData),
            let font = CGFont(provider),
            let name = font.postScriptName as String?
        else { return fail("cgfont-create") }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(font, &error) {
            // Already registered in this process is fine (a second demo run).
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            if code != CTFontManagerError.alreadyRegistered.rawValue {
                return fail("register-\(code)")
            }
        }
        return name
    }

    /// The display face at `size` points, or the system's bold face when the
    /// embedded font did not register.
    static func display(size: CGFloat) -> Font {
        if let name = displayName { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: .bold, design: .rounded)
    }
}

private struct UIDisplayFont: ViewModifier {
    @Environment(\.uiTextScale) private var scale
    let size: CGFloat

    func body(content: Content) -> some View {
        content.font(SentryFont.display(size: UITypography.points(size, scale: scale)))
    }
}

extension View {
    /// Shantell Sans Bold at `size` points (board value), scaled with the
    /// app's text size like `uiFont(size:)`.
    func uiDisplayFont(size: CGFloat) -> some View {
        modifier(UIDisplayFont(size: size))
    }
}
