import SwiftUI

// Diagnostic reports (docs/diagnostics.md): the Settings › App section with
// its "What is sent" disclosure and the review button, and the review layer
// that shows the whole report with Send and Cancel. Copy lives in
// DiagnosticsCopy (Diagnostics.swift).

enum UIDiagnosticsControlID {
    static let settingsDisclosure = "ui.settings.diagnostics.disclosure"
    static let settingsDetails = "ui.settings.diagnostics.details"
    static let settingsReview = "ui.settings.diagnostics.review"
    /// The notice text (what the parent reads).
    static let settingsNotice = "ui.settings.diagnostics.notice"
    /// `DiagnosticsSendState.name` (`sending|sent|failed`).
    static let settingsNoticeState = "ui.settings.diagnostics.notice.state"
    static let reviewText = "ui.diagnostics.review.text"
    static let reviewSend = "ui.diagnostics.review.send"
    static let reviewCancel = "ui.diagnostics.review.cancel"
}

/// "What is sent": a link-styled button whose popover lists the report's
/// sections in plain words.
struct UIDiagnosticsDisclosureButton: View {
    @State private var shown = false

    private var lines: [String] {
        DiagnosticsCopy.disclosureLines + [DiagnosticsCopy.disclosureNever, DiagnosticsCopy.disclosureOnce]
    }

    var body: some View {
        Button(DiagnosticsCopy.disclosureTitle) { shown.toggle() }
            .buttonStyle(.sentryQuiet)
            .uiFont(.caption)
            .accessibilityIdentifier(UIDiagnosticsControlID.settingsDisclosure)
            .uiControl(UIDiagnosticsControlID.settingsDisclosure, kind: .button,
                read: { DiagnosticsCopy.disclosureTitle }, activate: { shown.toggle() })
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(DiagnosticsCopy.disclosureTitle)
                        .uiFont(.callout)
                        .fontWeight(.semibold)
                    ForEach(DiagnosticsCopy.disclosureLines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").accessibilityHidden(true)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                        .uiFont(.caption)
                    }
                    Text(DiagnosticsCopy.disclosureNever)
                        .uiFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Text(DiagnosticsCopy.disclosureOnce)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 360, alignment: .leading)
                .accessibilityIdentifier(UIDiagnosticsControlID.settingsDetails)
                .uiControl(UIDiagnosticsControlID.settingsDetails, kind: .text,
                    read: { lines.joined(separator: "\n") })
            }
    }
}

/// Settings › App: what a report is, what is in it, and the review button.
/// The notice under the button is the agent's `DiagnosticsSendState`.
struct UIDiagnosticsSettingsSection: View {
    @ObservedObject var actions: UIActions
    @Environment(\.uiTextScale) private var textScale

    var body: some View {
        let sending = actions.diagnosticsSend == .sending
        UISection {
            VStack(alignment: .leading, spacing: 6) {
                Text(DiagnosticsCopy.explanation)
                    .uiFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UIDiagnosticsDisclosureButton()
                    Spacer(minLength: 8)
                    Button(DiagnosticsCopy.review) { actions.reviewDiagnosticReport() }
                        .controlSize(.small)
                        .disabled(sending)
                        .accessibilityIdentifier(UIDiagnosticsControlID.settingsReview)
                        .uiControl(UIDiagnosticsControlID.settingsReview, kind: .button,
                            read: { DiagnosticsCopy.review },
                            activate: { actions.reviewDiagnosticReport() },
                            enabled: { actions.diagnosticsSend != .sending })
                }
                if let send = actions.diagnosticsSend {
                    let notice = DiagnosticsCopy.notice(for: send)
                    HStack(alignment: .center, spacing: 6) {
                        if send == .sending {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(textScale)
                                .accessibilityHidden(true)
                        }
                        Text(notice)
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(notice)
                    .accessibilityIdentifier(UIDiagnosticsControlID.settingsNotice)
                    .uiControl(UIDiagnosticsControlID.settingsNotice, kind: .text,
                        read: { actions.diagnosticsSend.map(DiagnosticsCopy.notice(for:)) ?? "" })
                    .uiControl(UIDiagnosticsControlID.settingsNoticeState, kind: .text,
                        read: { actions.diagnosticsSend?.name ?? "" })
                }
            }
        }
        .uiScrollAnchor(UIDiagnosticsControlID.settingsReview)
    }
}

/// The review layer: the whole report exactly as it will be sent, then
/// Cancel or Send. Send is the only path to the network.
struct UIDiagnosticsReviewView: View {
    @ObservedObject var actions: UIActions

    /// Report viewport height. ASSUMED: tall enough to read a screenful of
    /// JSON, short enough that Send and Cancel stay inside the popover.
    static let textHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DiagnosticsCopy.reviewTitle)
                .uiFont(.headline)
            Text(DiagnosticsCopy.reviewIntro)
                .uiFont(.callout)
                .foregroundStyle(SentryColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(actions.diagnosticsDraft?.text ?? DiagnosticsCopy.reviewBuilding)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: Self.textHeight)
            .background(SentryColor.paper2)
            .uiControl(UIDiagnosticsControlID.reviewText, kind: .text,
                read: { actions.diagnosticsDraft?.text ?? "" })
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { actions.cancelDiagnosticReview() }
                    .buttonStyle(UISettingsOutlineButtonStyle(
                        minHeight: UISettingsLook.doneHeight, horizontalPadding: 16))
                    .keyboardShortcut(.cancelAction)
                    .uiControl(UIDiagnosticsControlID.reviewCancel, kind: .button, read: { "Cancel" },
                        activate: { actions.cancelDiagnosticReview() })
                Button(DiagnosticsCopy.send) { actions.sendDiagnosticReport() }
                    .buttonStyle(UISettingsOutlineButtonStyle(
                        minHeight: UISettingsLook.doneHeight, horizontalPadding: 16))
                    .disabled(actions.diagnosticsDraft == nil)
                    .uiControl(UIDiagnosticsControlID.reviewSend, kind: .button, read: { DiagnosticsCopy.send },
                        activate: { actions.sendDiagnosticReport() },
                        enabled: { actions.diagnosticsDraft != nil })
                Spacer(minLength: 0)
            }
        }
    }
}
