import SwiftUI

/// Inline error: plain words first, the technical line behind "Details".
/// Board: Notices-Inline. Shown in
/// Settings just above Done when a change cannot be saved; the caller passes
/// the plain sentence as `message` and today's technical text as `details`.
///
/// The caller sets the width (the board draws 390 pt). `details == nil` draws
/// no Details button, so a message with nothing more to say has no dead
/// control.
struct UIDetailsNotice: View {
    let message: String
    let details: String?
    @State private var isOpen = false

    static let detailsLabel = "Details"

    /// CSS `border-radius: 12px 10px 13px 9px` is top-left, top-right,
    /// bottom-right, bottom-left.
    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 12, bottomLeadingRadius: 9,
        bottomTrailingRadius: 13, topTrailingRadius: 10, style: .continuous)

    var body: some View {
        let shape = Self.shape
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .uiFont(size: 15, weight: .semibold)
                    .foregroundStyle(SentryColor.danger)
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(message)
                    .uiFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(SentryColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if details != nil {
                    Button(Self.detailsLabel) { isOpen.toggle() }
                        .buttonStyle(.sentryQuiet)
                        .accessibilityValue(isOpen ? "expanded" : "collapsed")
                }
            }
            if isOpen, let details {
                Text(details)
                    .uiFont(.caption, monospaced: true)
                    .foregroundStyle(SentryColor.slipInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(SentryColor.slip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(SentryColor.line, lineWidth: 1.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(SentryColor.paper, in: shape)
        .overlay(shape.strokeBorder(SentryColor.controlBorder, lineWidth: 2.5))
    }
}
