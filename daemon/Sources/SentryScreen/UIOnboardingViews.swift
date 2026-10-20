import AppKit
import Combine
import SwiftUI

// This file deliberately owns presentation state instead of installation,
// permission, capture, or PIN persistence. UIOnboardingCoordinator owns those
// decisions. It can project its current step into UIOnboardingPresentation and
// receive the explicit actions below. Keeping that boundary small prevents a
// SwiftUI view from treating a System Settings toggle or a cached permission
// result as proof that protection is healthy.

/// Stable Accessibility identifiers for the onboarding window and its
/// controls. The production views use native Accessibility identifiers only;
/// the script registry is an integration concern and must not become the UI's
/// source of truth.
enum UIOnboardingControlID {
    static let window = "onboarding.window"
    static let shield = "onboarding.shield"
    static let stage = "onboarding.stage"
    static let title = "onboarding.title"
    static let body = "onboarding.body"
    static let uninstall = "onboarding.uninstall"

    static let pinField = "onboarding.pin.field"
    static let pinConfirmation = "onboarding.pin.confirm"
    static let pinError = "onboarding.pin.error"
    static let pinSave = "onboarding.pin.save"

    static let permissionOpenSettings = "onboarding.permission.open-settings"
    static let permissionOpenSettingsManual = "onboarding.permission.open-settings-manual"
    /// Update-required: the download button and the line under it.
    static let updateDownload = "onboarding.update.download"
    static let updateDownloadDetail = "onboarding.update.download-detail"
    static let permissionConfirmEnabled = "onboarding.permission.confirm-enabled"
    static let verificationStatus = "onboarding.verification.status"
    static let completionClose = "onboarding.complete.close"

    static let unsupportedMessage = "onboarding.unsupported.message"
    static let failureMessage = "onboarding.failure.message"
    static let serviceRetry = "onboarding.service.retry"

    /// The account requirement, and the accounts on THIS Mac that break it.
    static let standardAccountMessage = "onboarding.standard-account.message"
    static let standardAccountAdmins = "onboarding.standard-account.admins"

    static let repairOpenSettings = "onboarding.repair.open-settings"

    static let recoveryStart = "onboarding.recovery.start"
    static let recoveryAuthenticate = "onboarding.recovery.authenticate"
    static let recoveryPIN = "onboarding.recovery.pin"
    static let recoveryPINConfirmation = "onboarding.recovery.pin.confirm"
    static let recoveryPINError = "onboarding.recovery.pin.error"
    static let recoveryPINSave = "onboarding.recovery.pin.save"
    static let recoveryCancel = "onboarding.recovery.cancel"
    static let recoveryComplete = "onboarding.recovery.complete"

    /// The hold card's Close (owner 2026-09-07); exists only while the
    /// window is closable (UIOnboardingWindowController.closable).
    static let close = "onboarding.close"
    /// Welcome (O11): the Start button.
    static let welcomeStart = "onboarding.welcome.start"
    /// All set: "Look for this face at the top right."
    static let completionLook = "onboarding.completion.look"

    static let all: Set<String> = [
        welcomeStart,
        window, shield, stage, title, body,
        pinField, pinConfirmation, pinError, pinSave,
        permissionOpenSettings, permissionOpenSettingsManual, permissionConfirmEnabled,
        verificationStatus, completionClose, completionLook,
        unsupportedMessage, failureMessage, serviceRetry,
        standardAccountMessage, standardAccountAdmins,
        repairOpenSettings,
        recoveryStart, recoveryAuthenticate, recoveryPIN, recoveryPINConfirmation,
        recoveryPINError, recoveryPINSave, recoveryCancel,
        recoveryComplete,
    ]
}

enum UIOnboardingPermissionContext: Equatable, Sendable {
    case initialSetup
    case repair
}

/// View-only states. Operational truth remains in UIOnboardingCoordinator.
/// Associated errors are display copy, never raw logs or plain PIN values.
enum UIOnboardingSurface: Equatable, Sendable {
    case preparing(detail: String)
    /// O11: first-run Welcome.
    case welcome
    case createPIN(isSaving: Bool, error: String?)
    case allowScreenRecording
    case verifying(detail: String)
    /// Initial setup, System Settings handoff in flight. Distinct from
    /// `.verifying` because it carries the manual fallback button.
    case awaitingScreenRecording(context: UIOnboardingPermissionContext)

    /// Shown while System Settings is open. macOS offers "Quit & Reopen" after
    /// the toggle; either answer ends here (Quit & Reopen: the process is
    /// replaced and setup resumes from the durable request; Later: the
    /// parent comes back to this window and the handoff runs then). The parent
    /// must not be left wondering why the window vanished (fi-reset-01).
    static func waitingForReturnDetail(_ context: UIOnboardingPermissionContext) -> String {
        // Board Setup-3-Waiting / Setup-Repair: one line. "Later" needs no
        // words: the return to this window runs the same handoff.
        "Switch on SentryScreen, then choose Quit & Reopen."
    }

    /// "Download" and not "Update": the parent installs the package
    /// themselves here, which is exactly what `UpdateState.manualRequired`
    /// means in Settings.
    static let downloadAction = "Download the latest version"
    static let downloadDetail = "Download it from the SentryScreen releases page. Your settings and PIN are kept."
    /// Where a new version comes from: GitHub Releases. Opened in the browser.
    static let releasesURL = URL(string: "https://github.com/SaintsGlobal/sentryscreen/releases")!

    /// Stage 2's two instructions (boards Setup-3-ScreenRecording). Initial
    /// setup only; the first also covers the native prompt's password ask.
    static let screenRecordingSteps: [(title: String, detail: String)] = screenRecordingSteps(.initialSetup)
    /// The repair window is not setup, so its second step names the window
    /// that returns (review 2026-09-29, item 3).
    static func screenRecordingSteps(_ context: UIOnboardingPermissionContext) -> [(title: String, detail: String)] {
        [
            ("Switch on SentryScreen.", "Your Mac may ask for its password."),
            ("Choose Quit & Reopen.",
             context == .initialSetup ? "Setup comes right back." : "This window comes right back."),
        ]
    }
    static let notInTheList = "Not in the list?"
    /// Shown when the parent came back from System Settings and preflight is
    /// still false. An upgrade of an ad-hoc signed app can leave a row that
    /// shows "on" but names the old build's code hash, so macOS ignores it
    /// (0.3.0 -> 0.4.0 on the Mac Studio, 2026-10-16). Removing and re-adding
    /// the row writes one for the installed build.
    static let stillOffAfterSettings =
        "Already switched on? Select SentryScreen in the list, remove it with the minus button, then add it again or press Open System Settings here again."

    case protectionOn(showConfirmation: Bool)
    case permissionMissing(
        context: UIOnboardingPermissionContext,
        reason: String,
        error: String?
    )
    case serviceFailure(component: String, detail: String)
    /// Read-only recovery for a Standard session. It names the failed
    /// component without offering parent controls in the child account.
    case administratorRepairRequired(component: String, detail: String)
    case pinRecoveryRequired(reason: String)
    case updateRequired(detail: String, protectionPaused: Bool)
    /// O8. `administrators` are the OTHER administrator accounts on this Mac
    /// (`AdminAccounts.otherAdministrators`), carried on the surface so the
    /// view stays pure and the demo and the selftest can script the list.
    case parentAdministratorRequired(administrators: [String])
    case unsupportedHost(required: String, observed: String)
    case recoveryAuthentication(isAuthenticating: Bool, error: String?)
    case recoveryNewPIN(isSaving: Bool, error: String?)
    case recoveryComplete

    /// O8, owner 2026-09-07. The one sentence the wizard never said: the
    /// default first account on a Mac is an administrator, and an
    /// administrator child can reset the parent PIN with their own password
    /// (`UIPinRecovery`) and remove the app. Names the consequence, not the
    /// mechanism — a parent decides on "can turn SentryScreen off".
    static let standardAccountRequirement = "Your child's account must be a Standard account. "
        + "An administrator account can turn SentryScreen off."

    /// The accounts on THIS Mac that are administrators, by name, so the
    /// parent can check the child's against them.
    static func standardAccountAdmins(_ names: [String]) -> String {
        "Administrator accounts on this Mac: \(names.joined(separator: ", ")). "
            + "If your child uses one of them, change it to Standard in System Settings, "
            + "under Users & Groups."
    }

}

extension UIOnboardingSurface {
    /// Default projection from the durable O0-O9 domain. Busy and recovery
    /// errors are temporary UI concerns and can replace this surface without
    /// changing the coordinator's durable step.
    init(step: UIOnboardingStep) {
        switch step {
        case .preparing:
            self = .preparing(detail: "Checking the installed components and services…")
        case .welcome:
            self = .welcome
        case .createPIN:
            self = .createPIN(isSaving: false, error: nil)
        case .allowScreenRecording:
            self = .allowScreenRecording
        case .waitingForReturn:
            self = .awaitingScreenRecording(context: .initialSetup)
        case .verifyingFreshProcess:
            self = .verifying(detail: "Starting protection…")
        case let .protectionOn(showConfirmation):
            self = .protectionOn(showConfirmation: showConfirmation)
        case let .permissionRepair(reason):
            self = .permissionMissing(
                context: .repair,
                reason: reason,
                error: nil)
        case let .serviceRepair(reason):
            self = .serviceFailure(component: "Required service", detail: reason)
        case let .pinRecoveryRequired(reason):
            self = .pinRecoveryRequired(reason: reason)
        case .parentAdministratorRequired:
            self = .parentAdministratorRequired(
                administrators: AdminAccounts.otherAdministrators())
        case let .unsupportedHost(required, observed):
            self = .unsupportedHost(required: required, observed: observed)
        }
    }

    /// Spoken result for state changes that would otherwise replace visible
    /// SwiftUI content without moving VoiceOver focus. Module-visible so
    /// `--onboarding-selftest` can assert what a surface says.
    var accessibilityAnnouncement: String? {
        switch self {
        case let .preparing(detail):
            return "Preparing SentryScreen. \(detail)"
        case .welcome:
            return "Welcome to SentryScreen setup. Two steps: parent PIN, then Screen Recording."
        case .createPIN:
            return nil
        case .allowScreenRecording:
            return "Step 2 of 2. Turn on Screen Recording."
        case let .verifying(detail):
            return "Checking protection. \(detail)"
        case let .awaitingScreenRecording(context):
            let prefix = context == .initialSetup
                ? "Step 2 of 2. Waiting for Screen Recording. "
                : "Protection repair. Waiting for Screen Recording. "
            return prefix + Self.waitingForReturnDetail(context)
        case .protectionOn(showConfirmation: true):
            return "Protection is on. SentryScreen is protecting this Mac now. "
                + "SentryScreen stays active after you close this message. "
                + "The app alerts you if protection needs a parent."
        case .protectionOn(showConfirmation: false):
            return nil
        case .permissionMissing, .serviceFailure, .administratorRepairRequired, .pinRecoveryRequired:
            // UIOnboardingErrorView announces these messages when it appears
            // or when its text changes.
            return nil
        case let .updateRequired(detail, protectionPaused):
            return protectionPaused
                ? "Protection is off. SentryScreen must be updated. \(detail)"
                : "Screen access is verified. SentryScreen must be updated before parent settings change. \(detail)"
        case let .parentAdministratorRequired(administrators):
            return "A parent must finish setup from an administrator account. "
                + Self.standardAccountRequirement
                + (administrators.isEmpty ? "" : " " + Self.standardAccountAdmins(administrators))
        case let .unsupportedHost(required, observed):
            return "This Mac is not supported. Required: \(required). This Mac: \(observed)."
        case let .recoveryAuthentication(isAuthenticating, error):
            if error != nil { return nil }
            return isAuthenticating ? "Waiting for Mac authentication." : nil
        case .recoveryNewPIN:
            return nil
        case .recoveryComplete:
            return "Parent PIN reset. The new parent PIN is ready to use."
        }
    }
}

/// The only events the view sends to the onboarding domain. Callers must not
/// log these values because the PIN actions contain plain PIN input.
enum UIOnboardingAction: Equatable {
    case saveInitialPIN(String)
    case openScreenRecordingSettings
    case openScreenRecordingSettingsManually
    case returnedFromScreenRecordingSettings
    case confirmScreenRecordingEnabled
    case closeCompletion
    case retryServiceHealth
    case beginPINRecovery
    case authenticatePINRecovery
    case saveRecoveredPIN(String)
    case cancelPINRecovery
    case finishPINRecovery
    case dismissWindow
    /// opens the site's download page for a manual install.
    case openDownloadPage
    /// Welcome's Start: the runtime marks Welcome passed for this process and presents the next step.
    case startSetup
    /// The footer link, in every surface (owner 2026-10-16).
    case uninstall
}

/// Main-actor callback bundle so a coordinator, demo, or test harness can
/// consume the same explicit action stream without the views importing domain
/// services. The default is inert for SwiftUI previews and structural tests.
struct UIOnboardingCallbacks {
    var handle: @MainActor (UIOnboardingAction) -> Void

    init(handle: @escaping @MainActor (UIOnboardingAction) -> Void = { _ in }) {
        self.handle = handle
    }
}

/// Observable adapter between UIOnboardingCoordinator and SwiftUI.
///
/// `openScreenRecordingSettings` arms exactly one application-return event.
/// UIOnboardingWindowController delivers that event when this accessory app
/// becomes active again. The coordinator still decides whether to start a
/// fresh-process verification; the view cannot claim success.
@MainActor
final class UIOnboardingPresentation: ObservableObject {
    @Published var surface: UIOnboardingSurface
    /// Mirrors UIOnboardingWindowController.closable for the current surface
    /// (set by the controller; false with no controller, so a preview or
    /// structural test never draws a Close that closes nothing).
    @Published var closable = false
    /// Text scale for this window (UIAccessibility.swift). `standard` in
    /// production; the onboarding test driver's `textsize` action is the only
    /// writer. It lives on the presentation, not on the static
    /// `UITextScale.current` the popover reads, because the setup window is
    /// built ONCE and reused for the whole session — a published property
    /// re-renders it, a static read would not.
    @Published var textScale: CGFloat = UITextScale.standard
    /// Draws the "Remove SentryScreen…" link. Set by the runtime when an
    /// administrator session wires the removal path.
    @Published var uninstallAvailable = false
    /// The card's Close button → the controller's performClose, so the one
    /// `windowShouldClose` decides every close request alike.
    var requestClose: () -> Void = {}
    private let callbacks: UIOnboardingCallbacks
    private var waitingForSettingsReturn = false

    init(
        surface: UIOnboardingSurface = .preparing(detail: "Checking this Mac…"),
        callbacks: UIOnboardingCallbacks = UIOnboardingCallbacks()
    ) {
        self.surface = surface
        self.callbacks = callbacks
    }

    func send(_ action: UIOnboardingAction) {
        callbacks.handle(action)
    }

    func armExpectedSettingsReturn() {
        waitingForSettingsReturn = true
    }

    /// Returns false when durable state says the one-time success message was
    /// already shown. Callers that own a window must hide it in that case.
    func apply(_ step: UIOnboardingStep) -> Bool {
        surface = UIOnboardingSurface(step: step)
        if case .protectionOn(showConfirmation: false) = surface { return false }
        return true
    }

    /// Called by the window controller for NSApplication.didBecomeActive.
    /// The armed bit makes this a one-shot handoff instead of a restart loop.
    func applicationDidReturnFromExternalSettings() {
        guard waitingForSettingsReturn else { return }
        waitingForSettingsReturn = false
        callbacks.handle(.returnedFromScreenRecordingSettings)
    }

    /// Integration calls this if macOS refuses to open the requested pane.
    /// A later unrelated app activation must not look like a settings return.
    func cancelExpectedSettingsReturn() {
        waitingForSettingsReturn = false
    }
}

private enum UIOnboardingMetrics {
    /// MEASURED Receipt: 496 points uses the selected concept's strong left
    /// alignment while retaining 32-point window gutters at 560 points wide.
    static let contentWidth: CGFloat = 496
    /// DERIVED Receipt: 32 points keeps task content separate from window
    /// chrome; with `contentWidth` it spans the 560-point window
    /// (496 + 2 × 32).
    static let horizontalPadding: CGFloat = 32
    /// ASSUMED Receipt: 24 points of top and bottom inset. It was MEASURED
    /// under the 164-point steel brand header, which the redesign dropped
    /// (code removed 2026-10-06); no render has re-measured it against the
    /// current header-less 560-by-520 setup window.
    static let verticalPadding: CGFloat = 24
    /// DERIVED Receipt: 16 points separates copy from the active task without
    /// producing the loose, generic center stack in the baseline.
    static let majorSpacing: CGFloat = 16
    /// DERIVED Receipt: 16 points groups related copy and controls.
    static let contentSpacing: CGFloat = 16
    /// DERIVED Receipt: 10 points keeps paired PIN fields visually connected.
    static let fieldSpacing: CGFloat = 10
    /// DERIVED Receipt: 20 points keeps panel copy clear of its border.
    static let panelPadding: CGFloat = 20
    /// DERIVED Receipt: 14 points matches the accepted parent-panel shape.
    static let panelCornerRadius: CGFloat = 14
    /// ASSUMED Receipt: state symbols are supporting information. 26 points
    /// keeps semantic failure/success visible without competing with the
    /// 28-point editorial title (`titleSize`).
    static let stateSymbolSize: CGFloat = 26
    /// The editorial title of each step. Named rather than inline because it
    /// is one of the two explicit point sizes in the wizard that scale with
    /// `\.uiTextScale` (UIAccessibility.swift); the other is the state
    /// symbol above.
    /// Setup boards: Shantell 28 pt (was 30 pt system).
    static let titleSize: CGFloat = 28
}

@MainActor
private enum UIOnboardingAccessibility {
    static func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard NSApplication.shared.isActive else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue,
            ])
    }
}

/// Internal, not private, since 2026-09-11: `--ui-selftest` asserts the titles
/// a parent reads (that a permission or update loss is never called
/// a "pause"). Still a pure value type; nothing but the view builds one.
struct UIOnboardingChrome {
    let stage: String?
    let symbol: String
    let symbolLabel: String
    let symbolColor: Color
    let title: String
    let body: String
    /// Repair and result surfaces' status line above the title (boards
    /// Setup-Repair, Setup-PinRecovery, Setup-ActivationRepair). Setup steps
    /// use `stage` instead.
    let eyebrow: String?

    var activeStep: Int? {
        guard let stage,
              let value = stage.split(separator: " ").dropFirst().first,
              let step = Int(value) else { return nil }
        return step
    }

    /// "Protection is off" and its kin: the eyebrow is drawn in `--danger`.
    var eyebrowIsDanger: Bool { eyebrow == "Protection is off" }

    var showsStateSymbol: Bool {
        symbol != "shield.fill" || stage == nil
    }

    private static func eyebrow(for surface: UIOnboardingSurface) -> String? {
        switch surface {
        case .protectionOn: return "Protection is on"
        case .permissionMissing(.repair, _, _): return "Protection is off"
        case .serviceFailure: return "Needs repair"
        case .administratorRepairRequired: return "Protection needs a parent"
        case .pinRecoveryRequired: return "Setup can\u{2019}t continue"
        case let .updateRequired(_, protectionPaused):
            return protectionPaused ? "Protection is off" : "Settings locked"
        case .parentAdministratorRequired: return "Setup on hold"
        case .unsupportedHost: return "Can\u{2019}t set up"
        case .recoveryAuthentication: return "Reset PIN \u{00B7} 1 of 2"
        case .recoveryNewPIN: return "Reset PIN \u{00B7} 2 of 2"
        case .recoveryComplete: return "Saved"
        default: return nil
        }
    }

    init(surface: UIOnboardingSurface) {
        eyebrow = Self.eyebrow(for: surface)
        switch surface {
        case .preparing:
            stage = nil
            symbol = "shield.fill"
            symbolLabel = "Setup is being prepared"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "Preparing SentryScreen"
            body = "SentryScreen is checking this Mac before setup starts."
        case .welcome:
            stage = nil
            symbol = "shield.fill"
            symbolLabel = "Welcome to SentryScreen setup"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "Hi! Let\u{2019}s protect this Mac."
            body = "Two quick steps. Keep your Mac password close."
        case .createPIN:
            stage = "Step 1 of 2"
            symbol = "shield.fill"
            symbolLabel = "Setup is incomplete"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "Create a parent PIN"
            // No "Create a parent PIN." prefix: the title already says it
            // (review 2026-09-29, item 11).
            body = UIPin.purpose
        case .allowScreenRecording:
            stage = "Step 2 of 2"
            symbol = "shield.fill"
            symbolLabel = "Screen Recording is not yet allowed"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "Turn on Screen Recording"
            body = "macOS needs your OK before SentryScreen can protect this Mac."
        case let .awaitingScreenRecording(context):
            stage = context == .initialSetup ? "Step 2 of 2" : nil
            symbol = "shield.fill"
            symbolLabel = "Waiting for Screen Recording"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = context == .initialSetup ? "Turn on Screen Recording" : "Waiting for Screen Recording"
            body = UIOnboardingSurface.waitingForReturnDetail(context)
        case .verifying:
            stage = "Step 2 of 2"
            symbol = "shield.fill"
            symbolLabel = "Protection verification is in progress"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "Checking protection"
            body = "SentryScreen is checking that protection works."
        case .protectionOn:
            // Setup's last screen sits outside the 3-step rail (board
            // Setup-5-AllSet: eyebrow "Protection is on", no step count).
            stage = nil
            // Board: a plain ink-green tick, no shield (Lantern replaced the shield).
            symbol = "checkmark"
            symbolLabel = "Protection is on"
            symbolColor = SentryColor.ok
            title = "You\u{2019}re all set!"
            body = "It keeps running after you close this window."
        case let .permissionMissing(context, _, _):
            stage = context == .initialSetup ? "Step 2 of 2" : nil
            symbol = "exclamationmark.shield.fill"
            symbolLabel = "Screen Recording needs attention"
            symbolColor = SentryColor.danger
            // (2026-09-11): "paused" is reserved for the pause the
            // parent asked for (Banner.swift carries the same receipt). This
            // state is not one they can Resume.
            title = context == .initialSetup
                ? "Screen Recording is still off"
                : "Turn Screen Recording back on"
            // Repair: the eyebrow is the one "off" (review 2026-09-29, item 3).
            body = context == .initialSetup
                ? "SentryScreen needs Screen Recording before it can protect this Mac."
                : "Switch SentryScreen back on in System Settings."
        case .serviceFailure:
            stage = nil
            symbol = "exclamationmark.shield.fill"
            symbolLabel = "SentryScreen needs repair"
            symbolColor = Color(nsColor: .systemRed)
            title = "Part of SentryScreen stopped working"
            body = "A required part of SentryScreen is not healthy."
        case let .administratorRepairRequired(component, _):
            stage = nil
            symbol = "lock.shield.fill"
            symbolLabel = "A parent administrator must repair \(component)"
            symbolColor = Color(nsColor: .systemRed)
            title = "A parent needs to fix this"
            body = "Sign in to an administrator account to repair SentryScreen."
        case .pinRecoveryRequired:
            stage = nil
            symbol = "lock.shield.fill"
            symbolLabel = "The parent PIN needs recovery"
            symbolColor = Color(nsColor: .systemRed)
            title = "Reset your parent PIN"
            body = "The saved PIN can\u{2019}t be used. Reset it to keep going."
        case let .updateRequired(_, protectionPaused):
            stage = nil
            symbol = "exclamationmark.shield.fill"
            // Same rule as the repair title above: protection is
            // OFF here, not paused — nothing the parent can resume.
            symbolLabel = protectionPaused
                ? "Protection is off until SentryScreen is updated"
                : "Screen access is verified; update SentryScreen before changing parent settings"
            symbolColor = Color(nsColor: protectionPaused ? .systemRed : .systemOrange)
            // never "paused" here (nothing to Resume).
            title = "Update SentryScreen"
            body = "This Mac needs the latest version. Your settings and PIN are kept."
        case .parentAdministratorRequired:
            stage = nil
            symbol = "lock.shield.fill"
            symbolLabel = "A parent administrator is required"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            // Board says "Setup paused"; the copy reserves "pause" for the
            // parent's own pause, so the eyebrow reads "Setup on hold".
            title = "Finish setup as a parent"
            body = "Sign in to an administrator account to finish."
        case .unsupportedHost:
            stage = nil
            symbol = "exclamationmark.shield.fill"
            symbolLabel = "This Mac is not supported"
            symbolColor = Color(nsColor: .systemRed)
            title = "This Mac isn\u{2019}t supported"
            body = "SentryScreen cannot finish setup on this Mac."
        case .recoveryAuthentication:
            stage = nil
            symbol = "lock.shield.fill"
            symbolLabel = "Parent PIN recovery"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "Reset your parent PIN"
            body = "Confirm it\u{2019}s you with Touch ID or your Mac password."
        case .recoveryNewPIN:
            stage = nil
            symbol = "lock.shield.fill"
            symbolLabel = "Create a new parent PIN"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "Pick a new PIN"
            body = "Choose a new PIN for parent controls on this Mac."
        case .recoveryComplete:
            stage = nil
            symbol = "key.fill"
            symbolLabel = "Parent PIN reset"
            symbolColor = Color(nsColor: .secondaryLabelColor)
            title = "PIN reset"
            body = "Use your new PIN from now on."
        }
    }
}

/// The 2-step rail of the setup boards (Parent PIN, Screen Recording), in DESIGN.md "Step numbers" (review 2026-09-29, item 2): paper-2
/// circles with a line edge and ink-2 numerals, no mustard or accent fill.
/// A finished step shows a check in the same circle; the connector after a
/// finished step is ink-2, later ones the line colour.
private struct UIOnboardingRail: View {
    static let stepCount = 2
    static let labels = ["Parent PIN", "Screen Recording"]
    let activeStep: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...Self.stepCount, id: \.self) { step in
                Group {
                    if step < activeStep {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SentryColor.ink2)
                            .frame(width: SentryStepNumber.diameter, height: SentryStepNumber.diameter)
                            .background(Circle().fill(SentryColor.paper2))
                            .overlay(Circle().strokeBorder(SentryColor.line, lineWidth: SentryStepNumber.edgeWidth))
                    } else {
                        SentryStepNumber(number: step)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(step), \(Self.labels[step - 1])"
                    + (step < activeStep ? ", done" : step == activeStep ? ", current" : ""))
                if step < Self.stepCount {
                    Rectangle()
                        .fill(step < activeStep ? SentryColor.ink2 : SentryColor.line)
                        .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// The complete dedicated-window surface. It stays vertically scrollable so
/// larger Accessibility text and smaller displays do not clip an action.
struct UIOnboardingRootView: View {
    @ObservedObject var presentation: UIOnboardingPresentation
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let chrome = UIOnboardingChrome(surface: presentation.surface)
        VStack(spacing: 0) {
            if let step = chrome.activeStep {
                UIOnboardingRail(activeStep: step)
                    .padding(.horizontal, UIOnboardingMetrics.horizontalPadding)
                    .padding(.top, UIOnboardingMetrics.verticalPadding)
                    .frame(maxWidth: UIOnboardingMetrics.contentWidth + 2 * UIOnboardingMetrics.horizontalPadding)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: UIOnboardingMetrics.majorSpacing) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 9) {
                            if presentation.surface == .welcome {
                                // Setup-1-Welcome: Lantern greets, no shield
                                // (plan §2: Lantern replaced the shield).
                                SentryLanternFigure(height: 96)
                                    .accessibilityIdentifier(UIOnboardingControlID.shield)
                            } else if chrome.showsStateSymbol {
                                Image(systemName: chrome.symbol)
                                    .uiFont(size: UIOnboardingMetrics.stateSymbolSize, weight: .medium)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(chrome.symbolColor)
                                    .accessibilityIdentifier(UIOnboardingControlID.shield)
                                    .accessibilityLabel(chrome.symbolLabel)
                            }
                            if let eyebrow = chrome.eyebrow {
                                Text(eyebrow)
                                    .uiFont(.callout, weight: .semibold)
                                    .textCase(.uppercase)
                                    // Danger colour on the label alone, never
                                    // on a sentence (review 2026-09-29, item 3).
                                    .foregroundStyle(chrome.eyebrowIsDanger ? SentryColor.danger : SentryColor.muted)
                                    .accessibilityIdentifier(UIOnboardingControlID.stage)
                                    .uiControl(UIOnboardingControlID.stage, kind: .text,
                                        read: {
                                            UIOnboardingChrome(surface: presentation.surface).eyebrow ?? ""
                                        })
                            } else if let stage = chrome.stage {
                                Text(stage)
                                    .textCase(.uppercase)
                                    .uiFont(.callout, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier(UIOnboardingControlID.stage)
                                    .uiControl(UIOnboardingControlID.stage, kind: .text,
                                        read: {
                                            UIOnboardingChrome(surface: presentation.surface).stage ?? ""
                                        })
                            }
                        }
                        Text(chrome.title)
                            .uiDisplayFont(size: UIOnboardingMetrics.titleSize)
                            .tracking(-0.35)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(UIOnboardingControlID.title)
                            .uiControl(UIOnboardingControlID.title, kind: .text,
                                read: { UIOnboardingChrome(surface: presentation.surface).title })
                        Text(chrome.body)
                            .uiFont(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(UIOnboardingControlID.body)
                            .uiControl(UIOnboardingControlID.body, kind: .text,
                                read: { UIOnboardingChrome(surface: presentation.surface).body })
                    }

                    UIOnboardingPanel(highContrast: contrast == .increased) {
                        surfaceContent
                    }

                    if presentation.uninstallAvailable {
                        HStack {
                            Spacer(minLength: 0)
                            UIFooterButton(label: UninstallCopy.anywhereLabel, muted: true) {
                                presentation.send(.uninstall)
                            }
                            .uiControl(UIOnboardingControlID.uninstall, kind: .button,
                                read: { UninstallCopy.anywhereLabel },
                                activate: { presentation.send(.uninstall) })
                        }
                    }
                }
                .frame(maxWidth: UIOnboardingMetrics.contentWidth, alignment: .leading)
                .padding(.horizontal, UIOnboardingMetrics.horizontalPadding)
                .padding(.vertical, UIOnboardingMetrics.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SentryColor.paper)
        .environment(\.uiTextScale, presentation.textScale)
        .accessibilityIdentifier(UIOnboardingControlID.window)
        .uiControl(UIOnboardingControlID.window, kind: .text,
            read: { "SentryScreen Setup" })
        .onChange(of: presentation.surface) { _, surface in
            guard let announcement = surface.accessibilityAnnouncement else { return }
            UIOnboardingAccessibility.announce(announcement)
        }
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch presentation.surface {
        case let .preparing(detail):
            UIOnboardingProgressView(
                detail: detail,
                accessibilityID: UIOnboardingControlID.verificationStatus)
        case .welcome:
            UIOnboardingWelcomeView(presentation: presentation)
        case let .createPIN(isSaving, error):
            UIOnboardingPINSetupView(
                isSaving: isSaving,
                domainError: error,
                onSave: { presentation.send(.saveInitialPIN($0)) })
        case .allowScreenRecording:
            UIOnboardingPermissionView(
                context: .initialSetup,
                buttonID: UIOnboardingControlID.permissionOpenSettings,
                onOpen: { presentation.send(.openScreenRecordingSettings) })
        case let .verifying(detail):
            UIOnboardingProgressView(
                detail: detail,
                accessibilityID: UIOnboardingControlID.verificationStatus)
        case let .awaitingScreenRecording(context):
            UIOnboardingAwaitingPermissionView(
                context: context,
                buttonID: UIOnboardingControlID.permissionOpenSettingsManual,
                onOpen: { presentation.send(.openScreenRecordingSettingsManually) },
                onConfirm: { presentation.send(.confirmScreenRecordingEnabled) },
                onReopen: { presentation.send(.openScreenRecordingSettings) })
        case .protectionOn(showConfirmation: true):
            UIOnboardingCompletionView {
                presentation.send(.closeCompletion)
            }
        case .protectionOn(showConfirmation: false):
            EmptyView()
        case let .permissionMissing(context, reason, error):
            UIOnboardingPermissionMissingView(
                context: context,
                reason: reason,
                domainError: error,
                onOpen: { presentation.send(.openScreenRecordingSettings) })
        case let .serviceFailure(component, detail):
            UIOnboardingServiceFailureView(component: component, detail: detail) {
                presentation.send(.retryServiceHealth)
            }
        case let .administratorRepairRequired(component, detail):
            UIOnboardingAdministratorRepairView(component: component, detail: detail)
        case let .pinRecoveryRequired(reason):
            VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
                UIOnboardingErrorView(
                    text: reason, id: UIOnboardingControlID.failureMessage)
                HStack {
                    Spacer(minLength: 0)
                    Button("Reset PIN") {
                        presentation.send(.beginPINRecovery)
                    }
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryStart)
                    .uiControl(UIOnboardingControlID.recoveryStart, kind: .button,
                        read: { "Reset PIN" },
                        activate: { presentation.send(.beginPINRecovery) })
                }
            }
        case let .updateRequired(detail, _):
            UIOnboardingUpdateRequiredView(detail: detail) {
                presentation.send(.openDownloadPage)
            }
        case let .parentAdministratorRequired(administrators):
            UIOnboardingStandardAccountView(administrators: administrators)
        case let .unsupportedHost(required, observed):
            UIOnboardingUnsupportedView(required: required, observed: observed)
        case let .recoveryAuthentication(isAuthenticating, error):
            UIOnboardingRecoveryAuthenticationView(
                isAuthenticating: isAuthenticating,
                error: error,
                onAuthenticate: { presentation.send(.authenticatePINRecovery) },
                onCancel: { presentation.send(.cancelPINRecovery) })
        case let .recoveryNewPIN(isSaving, error):
            UIOnboardingRecoveryPINView(
                isSaving: isSaving,
                domainError: error,
                onSave: { presentation.send(.saveRecoveredPIN($0)) },
                onCancel: { presentation.send(.cancelPINRecovery) })
        case .recoveryComplete:
            HStack {
                Spacer(minLength: 0)
                Button("Done") { presentation.send(.finishPINRecovery) }
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryComplete)
                    .uiControl(UIOnboardingControlID.recoveryComplete, kind: .button,
                        read: { "Done" },
                        activate: { presentation.send(.finishPINRecovery) })
            }
        }
    }
}

private struct UIOnboardingPanel<Content: View>: View {
    let highContrast: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(UIOnboardingMetrics.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: UIOnboardingMetrics.panelCornerRadius,
                    style: .continuous)
                    .fill(SentryColor.paper2))
            .overlay(
                // Paper-and-ink card (Setup boards): a paper2 slip with a
                // hairline ink edge; the full ink edge under Increase Contrast.
                RoundedRectangle(
                    cornerRadius: UIOnboardingMetrics.panelCornerRadius,
                    style: .continuous)
                    .stroke(
                        highContrast ? SentryColor.controlBorder : SentryColor.line,
                        lineWidth: highContrast ? 2 : 1))
    }
}

private struct UIOnboardingPINSetupView: View {
    let isSaving: Bool
    let domainError: String?
    let onSave: (String) -> Void

    private enum Field: Hashable { case pin, confirmation }
    @FocusState private var focused: Field?
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            VStack(alignment: .leading, spacing: UIOnboardingMetrics.fieldSpacing) {
                Text("PIN")
                    .uiFont(.callout, weight: .medium)
                SecureField("4 to 8 digits", text: $pin)
                    .modifier(UIOnboardingPaperField())
                    .focused($focused, equals: .pin)
                    .disabled(isSaving)
                    .onSubmit { focused = .confirmation }
                    .accessibilityLabel("Parent PIN")
                    .accessibilityIdentifier(UIOnboardingControlID.pinField)
                    .uiControl(UIOnboardingControlID.pinField, kind: .field,
                        read: { pin }, setText: { pin = $0 },
                        enabled: { !isSaving })

                Text("Type it again")
                    .uiFont(.callout, weight: .medium)
                SecureField("Same PIN", text: $confirmation)
                    .modifier(UIOnboardingPaperField())
                    .focused($focused, equals: .confirmation)
                    .disabled(isSaving)
                    .onSubmit(save)
                    .accessibilityLabel("Confirm parent PIN")
                    .accessibilityIdentifier(UIOnboardingControlID.pinConfirmation)
                    .uiControl(UIOnboardingControlID.pinConfirmation, kind: .field,
                        read: { confirmation }, setText: { confirmation = $0 },
                        enabled: { !isSaving })

                Text("4 to 8 digits. Pick one your child won\u{2019}t guess.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: pin) { _, _ in localError = nil }
            .onChange(of: confirmation) { _, _ in localError = nil }

            if let error = localError ?? domainError {
                UIOnboardingErrorView(text: error, id: UIOnboardingControlID.pinError)
            }

            HStack(spacing: 10) {
                if isSaving {
                    UIOnboardingBusyIndicator(label: "Saving your parent PIN")
                }
                Spacer(minLength: 0)
                Button("Save PIN", action: save)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || pin.isEmpty || confirmation.isEmpty)
                    .accessibilityIdentifier(UIOnboardingControlID.pinSave)
                    .uiControl(UIOnboardingControlID.pinSave, kind: .button,
                        read: { "Save PIN" }, activate: save,
                        enabled: { !isSaving && !pin.isEmpty && !confirmation.isEmpty })
            }
        }
        .onAppear { focused = .pin }
    }

    private func save() {
        guard UIPin.isValidFormat(pin) else {
            localError = "PIN must contain 4 to 8 digits."
            return
        }
        guard pin == confirmation else {
            localError = "The PINs do not match."
            return
        }
        localError = nil
        onSave(pin)
    }
}

private struct UIOnboardingPermissionView: View {
    let context: UIOnboardingPermissionContext
    let buttonID: String
    let onOpen: () -> Void

    var body: some View {
        let buttonTitle = "Open System Settings"
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            ForEach(Array(UIOnboardingSurface.screenRecordingSteps(context).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    SentryStepNumber(number: index + 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).uiFont(.body, weight: .semibold)
                        Text(step.detail).uiFont(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer(minLength: 0)
                Button(buttonTitle, action: onOpen)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(buttonID)
                    .uiControl(buttonID, kind: .button,
                        read: { buttonTitle }, activate: onOpen)
            }
        }
    }
}

/// Board Setup-1-Welcome: the three steps and the one primary Start.
private struct UIOnboardingWelcomeView: View {
    @ObservedObject var presentation: UIOnboardingPresentation

    private static let steps = ["Parent PIN", "Screen Recording"]

    @ViewBuilder private var stepItems: some View {
        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, name in
            HStack(spacing: 8) {
                SentryStepNumber(number: index + 1)
                Text(name).uiFont(.body, weight: .semibold).fixedSize()
            }
            .accessibilityElement(children: .combine)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            // One numbered row (review 2026-09-29, item 11), not a list.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { stepItems }
                VStack(alignment: .leading, spacing: 8) { stepItems }
            }
            HStack {
                Spacer(minLength: 0)
                Button("Start") { presentation.send(.startSetup) }
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UIOnboardingControlID.welcomeStart)
                    .uiControl(UIOnboardingControlID.welcomeStart, kind: .button,
                        read: { "Start" }, activate: { presentation.send(.startSetup) })
            }
        }
    }
}

/// The update-required dead end, with a way out (2026-09-11): this
/// surface said "Install the latest SentryScreen before you change parent
/// setup or settings" and drew no button and no address, on a window a parent
/// can only close when the status icon exists. The download line and
/// destination are `UIOnboardingSurface.downloadDetail` and `releasesURL`.
private struct UIOnboardingUpdateRequiredView: View {
    let detail: String
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            UIOnboardingErrorView(
                text: detail, id: UIOnboardingControlID.failureMessage)
            Text(UIOnboardingSurface.downloadDetail)
                .uiFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(UIOnboardingControlID.updateDownloadDetail)
                .uiControl(UIOnboardingControlID.updateDownloadDetail, kind: .text,
                    read: { UIOnboardingSurface.downloadDetail })
            HStack {
                Spacer(minLength: 0)
                Button(UIOnboardingSurface.downloadAction, action: onDownload)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UIOnboardingControlID.updateDownload)
                    .uiControl(UIOnboardingControlID.updateDownload, kind: .button,
                        read: { UIOnboardingSurface.downloadAction },
                        activate: onDownload)
            }
        }
    }
}

/// Waiting state (boards Setup-3-Waiting, Setup-Repair O6 waiting): progress,
/// the "Not in the list?" manual route, the outlined re-open and the one
/// primary "I turned it on".
private struct UIOnboardingAwaitingPermissionView: View {
    let context: UIOnboardingPermissionContext
    let buttonID: String
    let onOpen: () -> Void
    let onConfirm: () -> Void
    let onReopen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            UIOnboardingProgressView(
                detail: "Waiting for you to switch it on\u{2026}",
                accessibilityID: UIOnboardingControlID.verificationStatus)
            Button(UIOnboardingSurface.notInTheList, action: onOpen)
                .buttonStyle(.sentryQuiet)
                .accessibilityIdentifier(buttonID)
                .uiControl(buttonID, kind: .button,
                    read: { UIOnboardingSurface.notInTheList }, activate: onOpen)
            HStack {
                if context == .initialSetup {
                    Button("Open System Settings", action: onReopen)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(UIOnboardingControlID.permissionOpenSettings)
                        .uiControl(UIOnboardingControlID.permissionOpenSettings, kind: .button,
                            read: { "Open System Settings" }, activate: onReopen)
                }
                Spacer(minLength: 0)
                Button("I turned it on", action: onConfirm)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UIOnboardingControlID.permissionConfirmEnabled)
                    .uiControl(UIOnboardingControlID.permissionConfirmEnabled, kind: .button,
                        read: { "I turned it on" }, activate: onConfirm)
            }
        }
    }
}

private struct UIOnboardingProgressView: View {
    let detail: String
    let accessibilityID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
                    .accessibilityHidden(true)
            }
            Text(detail)
                .uiFont(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail)
        .accessibilityIdentifier(accessibilityID)
        .uiControl(accessibilityID, kind: .text, read: { detail })
    }
}

/// Board Setup-5-AllSet (review 2026-09-29, item 4): Lantern waves at
/// `lanternHeight`, and a small drawing of the menu bar shows where the face
/// lives, with the real protected glyph in it.
private struct UIOnboardingCompletionView: View {
    /// The review's floor for the All set Lantern: the drawn figure 120 pt or
    /// taller. This is the frame height; the figure's viewBox has headroom,
    /// so the drawing fills 0.754 of it (MEASURED: 199 px of a 264 px frame,
    /// hand to feet, in an installed 2x render).
    /// 164 (4 pt grid) draws it at about 124 pt.
    static let lanternHeight: CGFloat = 164
    static let lookLine = "Look for this face at the top right."
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            HStack(alignment: .center, spacing: 20) {
                SentryLanternFigure(height: Self.lanternHeight, waving: true)
                VStack(alignment: .leading, spacing: 10) {
                    UIOnboardingMenuBarDrawing()
                    Text(Self.lookLine)
                        .uiFont(.body, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiControl(UIOnboardingControlID.completionLook, kind: .text,
                            read: { Self.lookLine })
                    Text("We\u{2019}ll let you know if anything needs a parent.")
                        .uiFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer(minLength: 0)
                // The screen's one mustard button (Setup-5-AllSet).
                Button("Done", action: onClose)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UIOnboardingControlID.completionClose)
                    .uiControl(UIOnboardingControlID.completionClose, kind: .button,
                        read: { "Done" }, activate: onClose)
            }
        }
    }
}

/// A sketch of the right end of the menu bar: two stand-in items, the
/// Lantern glyph (the real protected image, 16 pt as in the bar) and a
/// clock-shaped bar. Drawn in the room's ink on paper-2 so it reads as a
/// drawing, not a screenshot of the parent's own bar.
///
/// Size (DERIVED from the contents): height 28 = the 16 pt glyph + 3 pt
/// padding each side (22) + the ring's 4 pt outset less its 2 pt stroke,
/// each side, rounded up to an even number; width 200 = 14 + 14 + 22 + 36 pt
/// of items + three 10 pt gaps + two 12 pt ends (140) plus a 60 pt run of bar
/// so it reads as the right end of a longer bar. It holds no text, so text
/// size does not change it. ASSUMED: the "right end of a bar" read; checked
/// only by eye on the installed All set render.
private struct UIOnboardingMenuBarDrawing: View {
    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2).fill(SentryColor.line).frame(width: 14, height: 10)
            RoundedRectangle(cornerRadius: 2).fill(SentryColor.line).frame(width: 14, height: 10)
            Image(nsImage: SentryLanternGlyph.image(for: .protecting))
                .renderingMode(.template)
                .resizable()
                .frame(width: SentryLanternGlyph.side, height: SentryLanternGlyph.side)
                .foregroundStyle(SentryColor.ink)
                .padding(3)
                .overlay(Circle().strokeBorder(SentryColor.accent, lineWidth: 2).padding(-4))
            RoundedRectangle(cornerRadius: 2).fill(SentryColor.line).frame(width: 36, height: 10)
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SentryColor.paper))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(SentryColor.line, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct UIOnboardingPermissionMissingView: View {
    let context: UIOnboardingPermissionContext
    let reason: String
    let domainError: String?
    let onOpen: () -> Void

    /// Repair: the danger eyebrow and the title already say Screen Recording
    /// is off, so a red line saying it again was the third "off" (review
    /// 2026-09-29, item 3). Any other reason (System Settings did not open, a
    /// capture failure) is news and stays. Setup keeps every line: it has no
    /// eyebrow.
    static func showsReason(_ reason: String, context: UIOnboardingPermissionContext) -> Bool {
        guard context == .repair else { return true }
        return !(reason.hasPrefix("Screen Recording is off")
            || reason.hasPrefix("SentryScreen is not enabled in Screen Recording"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            if Self.showsReason(reason, context: context) {
                UIOnboardingErrorView(text: reason, id: UIOnboardingControlID.failureMessage)
            }
            if let domainError {
                UIOnboardingErrorView(text: domainError, id: UIOnboardingControlID.pinError)
            }
            UIOnboardingPermissionView(
                context: context,
                buttonID: context == .repair
                    ? UIOnboardingControlID.repairOpenSettings
                    : UIOnboardingControlID.permissionOpenSettings,
                onOpen: onOpen)
        }
    }
}

private struct UIOnboardingServiceFailureView: View {
    let component: String
    let detail: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            UIOnboardingErrorView(
                text: "\(component): \(detail)",
                id: UIOnboardingControlID.failureMessage)
            HStack {
                Spacer(minLength: 0)
                Button("Check again", action: onRetry)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UIOnboardingControlID.serviceRetry)
                    .uiControl(UIOnboardingControlID.serviceRetry, kind: .button,
                        read: { "Check again" }, activate: onRetry)
            }
        }
    }
}

private struct UIOnboardingAdministratorRepairView: View {
    let component: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            UIOnboardingErrorView(
                text: "\(component): \(detail)",
                id: UIOnboardingControlID.failureMessage)
            Text("A parent must sign in to an administrator account to repair this part of SentryScreen.")
                .uiFont(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UIOnboardingUnsupportedView: View {
    let required: String
    let observed: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Needs: \(required)")
            Text("This Mac: \(observed)")
        }
        .uiFont(.body)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Needs: \(required). This Mac: \(observed).")
        .accessibilityIdentifier(UIOnboardingControlID.unsupportedMessage)
        .uiControl(UIOnboardingControlID.unsupportedMessage, kind: .text,
            read: { "Needs: \(required). This Mac: \(observed)." })
    }
}


/// O8's content (owner 2026-09-07): the account requirement, and — when this
/// Mac has administrator accounts other than this session's — their names, so
/// the parent can tell at a glance whether the child holds one.
private struct UIOnboardingStandardAccountView: View {
    let administrators: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            Text(UIOnboardingSurface.standardAccountRequirement)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(UIOnboardingControlID.standardAccountMessage)
                .uiControl(UIOnboardingControlID.standardAccountMessage, kind: .text,
                    read: { UIOnboardingSurface.standardAccountRequirement })
            if !administrators.isEmpty {
                let text = UIOnboardingSurface.standardAccountAdmins(administrators)
                Label {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(UIOnboardingControlID.standardAccountAdmins)
                .uiControl(UIOnboardingControlID.standardAccountAdmins, kind: .text,
                    read: { text })
            }
        }
    }
}

private struct UIOnboardingRecoveryAuthenticationView: View {
    let isAuthenticating: Bool
    let error: String?
    let onAuthenticate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            Text("macOS can use an available owner-authentication method, such as Touch ID, Apple Watch, or your Mac login password.")
                .uiFont(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                UIOnboardingErrorView(text: error, id: UIOnboardingControlID.failureMessage)
            }
            HStack(spacing: 10) {
                if isAuthenticating {
                    UIOnboardingBusyIndicator(label: "Waiting for Mac authentication")
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAuthenticating)
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryCancel)
                    .uiControl(UIOnboardingControlID.recoveryCancel, kind: .button,
                        read: { "Cancel" }, activate: onCancel,
                        enabled: { !isAuthenticating })
                Button("Confirm it\u{2019}s me", action: onAuthenticate)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAuthenticating)
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryAuthenticate)
                    .uiControl(UIOnboardingControlID.recoveryAuthenticate, kind: .button,
                        read: { "Confirm it\u{2019}s me" }, activate: onAuthenticate,
                        enabled: { !isAuthenticating })
            }
        }
    }
}

private struct UIOnboardingRecoveryPINView: View {
    let isSaving: Bool
    let domainError: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    private enum Field: Hashable { case pin, confirmation }
    @FocusState private var focused: Field?
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIOnboardingMetrics.contentSpacing) {
            VStack(alignment: .leading, spacing: UIOnboardingMetrics.fieldSpacing) {
                Text("New PIN")
                    .uiFont(.callout, weight: .medium)
                SecureField("4 to 8 digits", text: $pin)
                    .modifier(UIOnboardingPaperField())
                    .focused($focused, equals: .pin)
                    .disabled(isSaving)
                    .onSubmit { focused = .confirmation }
                    .accessibilityLabel("New parent PIN")
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryPIN)
                    .uiControl(UIOnboardingControlID.recoveryPIN, kind: .field,
                        read: { pin }, setText: { pin = $0 },
                        enabled: { !isSaving })

                Text("Type it again")
                    .uiFont(.callout, weight: .medium)
                SecureField("Type it again", text: $confirmation)
                    .modifier(UIOnboardingPaperField())
                    .focused($focused, equals: .confirmation)
                    .disabled(isSaving)
                    .onSubmit(save)
                    .accessibilityLabel("Confirm new parent PIN")
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryPINConfirmation)
                    .uiControl(UIOnboardingControlID.recoveryPINConfirmation, kind: .field,
                        read: { confirmation }, setText: { confirmation = $0 },
                        enabled: { !isSaving })

                Text("4 to 8 digits.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: pin) { _, _ in localError = nil }
            .onChange(of: confirmation) { _, _ in localError = nil }

            if let error = localError ?? domainError {
                UIOnboardingErrorView(text: error, id: UIOnboardingControlID.recoveryPINError)
            }

            HStack(spacing: 10) {
                if isSaving {
                    UIOnboardingBusyIndicator(label: "Saving the new parent PIN")
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryCancel)
                    .uiControl(UIOnboardingControlID.recoveryCancel, kind: .button,
                        read: { "Cancel" }, activate: onCancel,
                        enabled: { !isSaving })
                Button("Save new PIN", action: save)
                    .buttonStyle(.sentryPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || pin.isEmpty || confirmation.isEmpty)
                    .accessibilityIdentifier(UIOnboardingControlID.recoveryPINSave)
                    .uiControl(UIOnboardingControlID.recoveryPINSave, kind: .button,
                        read: { "Save new PIN" }, activate: save,
                        enabled: { !isSaving && !pin.isEmpty && !confirmation.isEmpty })
            }
        }
        .onAppear { focused = .pin }
    }

    private func save() {
        guard UIPin.isValidFormat(pin) else {
            localError = "PIN must contain 4 to 8 digits."
            return
        }
        guard pin == confirmation else {
            localError = "The PINs do not match."
            return
        }
        localError = nil
        onSave(pin)
    }
}

private struct UIOnboardingErrorView: View {
    let text: String
    let id: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .accessibilityHidden(true)
        }
        .uiFont(.callout)
        // DESIGN.md `--danger` (5.1:1 / 8.3:1 on paper-2); systemRed on
        // paper-2 by day was about 3.5:1.
        .foregroundStyle(SentryColor.danger)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
        .uiControl(id, kind: .text, read: { text })
        .id(text)
        .onAppear {
            UIOnboardingAccessibility.announce(text, priority: .high)
        }
        .onChange(of: text) { _, newText in
            UIOnboardingAccessibility.announce(newText, priority: .high)
        }
    }
}

/// Reusable entry point for the existing parent PIN prompt and Settings. The
/// integration lane can place this same control there without duplicating its
/// label or Accessibility identifier.
struct UIOnboardingForgotPINButton: View {
    let action: () -> Void

    var body: some View {
        Button("Forgot PIN?", action: action)
            .buttonStyle(.sentryQuiet)
            .accessibilityIdentifier(UIOnboardingControlID.recoveryStart)
            .uiControl(UIOnboardingControlID.recoveryStart, kind: .button,
                read: { "Forgot PIN?" }, activate: action)
    }
}

private struct UIOnboardingBusyIndicator: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
            }
            Text(label)
                .uiFont(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// Setup fields: DESIGN.md "Inputs" (`SentrySlipField`), the same slip in
/// both rooms (review 2026-09-29, item 2: night used to draw paper here).
struct UIOnboardingPaperField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .uiFont(.body)
            .modifier(SentrySlipField())
    }
}
