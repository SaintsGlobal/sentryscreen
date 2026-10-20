import SwiftUI

// Diagnostic reports (docs/diagnostics.md): the Settings section's one
// "Review Report" link, and the review layer that states what is and is never
// sent, shows the whole report, and carries Send, Cancel and the send status.
// Copy lives in DiagnosticsCopy (Diagnostics.swift).

enum UIDiagnosticsControlID {
    static let settingsReview = "ui.settings.diagnostics.review"
    /// The promise at the top of the review (what is sent, what never is).
    static let reviewPromise = "ui.diagnostics.review.promise"
    /// The send notice text, on the review since 2026-10-20 (it was
    /// `ui.settings.diagnostics.notice` under the section's button).
    static let reviewNotice = "ui.diagnostics.review.notice"
    /// `DiagnosticsSendState.name` (`sending|sent|failed`).
    static let reviewNoticeState = "ui.diagnostics.review.notice.state"
    static let reviewText = "ui.diagnostics.review.text"
    static let reviewSend = "ui.diagnostics.review.send"
    static let reviewCancel = "ui.diagnostics.review.cancel"
}

/// Settings › General: one link, "Review Report" (owner 2026-10-20). It
/// opens the review behind the parent PIN, exactly as the old button did.
/// Disabled while a report is sending.
struct UIDiagnosticsSettingsSection: View {
    @ObservedObject var actions: UIActions

    var body: some View {
        UISection {
            Button(DiagnosticsCopy.review) { actions.reviewDiagnosticReport() }
                .buttonStyle(.sentryQuiet)
                .uiFont(.callout)
                .disabled(actions.diagnosticsSend == .sending)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(UIDiagnosticsControlID.settingsReview)
                .uiControl(UIDiagnosticsControlID.settingsReview, kind: .button,
                    read: { DiagnosticsCopy.review },
                    activate: { actions.reviewDiagnosticReport() },
                    enabled: { actions.diagnosticsSend != .sending })
        }
        .uiScrollAnchor(UIDiagnosticsControlID.settingsReview)
    }
}

/// The review layer: what is sent and what never is, the whole report exactly
/// as it will be sent, then Cancel or Send, and the send status. Send is the
/// only path to the network. Since 2026-10-20 the layer stays up after Send
/// and says sending / sent / failed itself (the section has no notice any
/// more); Send is then disabled and Cancel reads Close.
struct UIDiagnosticsReviewView: View {
    @ObservedObject var actions: UIActions
    @Environment(\.uiTextScale) private var textScale

    /// Report viewport height. ASSUMED: tall enough to read a screenful of
    /// JSON, short enough that Send and Cancel stay inside the popover.
    /// 2026-10-20: 320 → 220. DERIVED: the promise moved above it is seven
    /// caption lines, about 100 pt at the default text size, so the layer
    /// keeps roughly its old height. Not re-measured at larger text sizes.
    static let textHeight: CGFloat = 220

    var body: some View {
        let sent = actions.diagnosticsSend != nil
        VStack(alignment: .leading, spacing: 10) {
            Text(DiagnosticsCopy.reviewTitle)
                .uiFont(.headline)
            Text(DiagnosticsCopy.reviewIntro)
                .uiFont(.callout)
                .foregroundStyle(SentryColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            promise
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
            if let send = actions.diagnosticsSend { notice(send) }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(sent ? DiagnosticsCopy.close : "Cancel") { actions.cancelDiagnosticReview() }
                    .buttonStyle(UISettingsOutlineButtonStyle(
                        minHeight: UISettingsLook.doneHeight, horizontalPadding: 16))
                    .keyboardShortcut(.cancelAction)
                    .uiControl(UIDiagnosticsControlID.reviewCancel, kind: .button,
                        read: { actions.diagnosticsSend != nil ? DiagnosticsCopy.close : "Cancel" },
                        activate: { actions.cancelDiagnosticReview() })
                Button(DiagnosticsCopy.send) { actions.sendDiagnosticReport() }
                    .buttonStyle(UISettingsOutlineButtonStyle(
                        minHeight: UISettingsLook.doneHeight, horizontalPadding: 16))
                    .disabled(!UIActions.diagnosticsCanSend(draft: actions.diagnosticsDraft != nil,
                        send: actions.diagnosticsSend))
                    .uiControl(UIDiagnosticsControlID.reviewSend, kind: .button, read: { DiagnosticsCopy.send },
                        activate: { actions.sendDiagnosticReport() },
                        enabled: { UIActions.diagnosticsCanSend(draft: actions.diagnosticsDraft != nil,
                            send: actions.diagnosticsSend) })
                Spacer(minLength: 0)
            }
        }
    }

    /// The privacy promise, before the report and before Send (it was the
    /// section's "What is sent" disclosure until 2026-10-20).
    private var promise: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DiagnosticsCopy.disclosureTitle)
                .uiFont(.caption)
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
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .foregroundStyle(SentryColor.ink2)
        .accessibilityElement(children: .combine)
        .uiControl(UIDiagnosticsControlID.reviewPromise, kind: .text,
            read: { DiagnosticsCopy.reviewPromise.joined(separator: "\n") })
    }

    /// The agent's `DiagnosticsSendState`: a spinner while sending, then
    /// sent / failed. A live region (`UIActions` posts the announcement).
    private func notice(_ send: DiagnosticsSendState) -> some View {
        let text = DiagnosticsCopy.notice(for: send)
        return HStack(alignment: .center, spacing: 6) {
            if send == .sending {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(textScale)
                    .accessibilityHidden(true)
            }
            Text(text)
                .uiFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier(UIDiagnosticsControlID.reviewNotice)
        .uiControl(UIDiagnosticsControlID.reviewNotice, kind: .text,
            read: { actions.diagnosticsSend.map(DiagnosticsCopy.notice(for:)) ?? "" })
        .uiControl(UIDiagnosticsControlID.reviewNoticeState, kind: .text,
            read: { actions.diagnosticsSend?.name ?? "" })
    }
}
