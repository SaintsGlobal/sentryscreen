import AppKit
import Foundation

/// Synthetic states rendered by `--ui-onboarding-demo`. Each case is safe:
/// it owns no detector, capture stream, overlay, workspace action, or owner
/// authenticator. The demo presents the production onboarding views over
/// fixed, non-personal state.
enum UIOnboardingDemoScenario: String, CaseIterable {
    /// O11 Welcome (boards Setup-1-Welcome, -Night); `welcome-dark` renders
    /// the night variant.
    case welcome
    case welcomeDark = "welcome-dark"
    case pinLight = "pin-light"
    case pinDark = "pin-dark"
    case pinMismatch = "pin-mismatch"
    case pinFormatError = "pin-format-error"
    case pinRecoveryRequired = "pin-recovery-required"
    case preparing
    case permissionExplanation = "permission-explanation"
    case waitingForReturn = "waiting-for-return"
    case verifying
    case permissionMissing = "permission-missing"
    case complete
    case componentRecoveredNoPIN = "component-recovered-no-pin"
    case standardAccount = "standard-account"
    case serviceFailure = "service-failure"
    case serviceRecovered = "service-recovered"
    case unsupportedHost = "unsupported-host"
    case updateRequired = "update-required"
    case updateRequiredHealthy = "update-required-healthy"
    case repair
    case recoveryPrompt = "recovery-prompt"
    case recoveryBusy = "recovery-busy"
    case recoveryCancelled = "recovery-cancelled"
    case recoveryFailure = "recovery-failure"
    case recoverySuccess = "recovery-success"
    static var acceptedValues: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }

    var initialSurface: UIOnboardingSurface {
        switch self {
        case .welcome, .welcomeDark:
            return .welcome
        case .pinLight, .pinDark, .pinMismatch, .pinFormatError:
            return .createPIN(isSaving: false, error: nil)
        case .pinRecoveryRequired:
            return .pinRecoveryRequired(
                reason: "The parent PIN data needs recovery before setup can continue.")
        case .preparing:
            return .preparing(detail: "Checking the installed components and services…")
        case .permissionExplanation:
            return .allowScreenRecording
        case .waitingForReturn:
            return .awaitingScreenRecording(context: .initialSetup)
        case .verifying:
            return .verifying(detail: "Starting protection…")
        case .permissionMissing:
            return .permissionMissing(
                context: .initialSetup,
                reason: "SentryScreen is not enabled in Screen Recording.",
                error: nil)
        case .complete:
            return .protectionOn(showConfirmation: true)
        case .standardAccount:
            // Scripted, never this Mac's directory: a demo renders fixed,
            // non-personal state (and the E2E render must not put a real
            // account name in a committed screenshot).
            return .parentAdministratorRequired(administrators: ["Alex Rivera", "Sam Chen"])
        case .serviceFailure, .serviceRecovered, .componentRecoveredNoPIN:
            return .serviceFailure(
                component: "SentryScreen watchdog",
                detail: "The required service is not responding.")
        case .unsupportedHost:
            return .unsupportedHost(required: "macOS 14 or later", observed: "macOS 13.7")
        case .updateRequired:
            return .updateRequired(
                detail: "Install the latest SentryScreen before you change parent setup or settings.",
                protectionPaused: true)
        case .updateRequiredHealthy:
            return .updateRequired(
                detail: "Install the latest SentryScreen before you change parent setup or settings.",
                protectionPaused: false)
        case .repair:
            return Self.repairSurface()
        case .recoveryBusy:
            return .recoveryAuthentication(isAuthenticating: true, error: nil)
        case .recoveryPrompt, .recoveryCancelled, .recoveryFailure, .recoverySuccess:
            return .recoveryAuthentication(isAuthenticating: false, error: nil)
        }
    }

    /// The demo mirrors production's close invariant: a repair-dress surface
    /// exists only on a completed install, whose menu-bar icon is shown; an
    /// initial-setup surface runs before the icon exists. Pure.
    var menuBarIconVisible: Bool {
        switch initialSurface {
        case .permissionMissing(context: .repair, reason: _, error: _),
            .awaitingScreenRecording(context: .repair):
            return true
        default:
            return false
        }
    }

    static func repairSurface(
        error: String? = nil
    ) -> UIOnboardingSurface
    {
        .permissionMissing(
            context: .repair,
            reason: "Screen Recording is off. A parent must turn it on to restore protection.",
            error: error)
    }
}

/// State-root guard for the onboarding demo. The production settings root and
/// any non-empty directory are refused before an NSWindow exists.
enum UIOnboardingDemoStateRoot {
    enum RootError: Error, CustomStringConvertible {
        case production(String)
        case notDirectory(String)
        case notEmpty(String)
        case createFailed(String, Error)
        case inspectFailed(String, Error)

        var description: String {
            switch self {
            case let .production(path):
                return "state root \(path) is the production root"
            case let .notDirectory(path):
                return "state root \(path) exists but is not a directory"
            case let .notEmpty(path):
                return "state root \(path) is not empty"
            case let .createFailed(path, error):
                return "cannot create state root \(path): \(error)"
            case let .inspectFailed(path, error):
                return "cannot inspect state root \(path): \(error)"
            }
        }
    }

    private static var ownedRoot: String?

    /// Ensures `SENTRY_STATE_DIR` names one fresh demo-only directory. If the
    /// caller did not supply one, this process creates and owns a PID-specific
    /// directory under the system temporary directory.
    static func prepare(environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> String
    {
        let supplied = environment["SENTRY_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let raw = supplied
            ?? (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("sentry-onboarding-demo-\(getpid())")
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        let manager = FileManager.default
        let productionURL = URL(fileURLWithPath: UISettingsStore.productionRoot)
            .standardizedFileURL

        // Compare the lexical canonical paths before any directory creation.
        // If the production root does not exist, a demo must not create it and
        // only then discover that it chose a forbidden target.
        guard url.path.caseInsensitiveCompare(productionURL.path) != .orderedSame else {
            throw RootError.production(url.path)
        }

        if !manager.fileExists(atPath: url.path) {
            do {
                try manager.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                throw RootError.createFailed(url.path, error)
            }
            if supplied == nil {
                ownedRoot = url.path
                atexit {
                    guard let root = UIOnboardingDemoStateRoot.ownedRoot else { return }
                    try? FileManager.default.removeItem(atPath: root)
                }
            }
        }

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RootError.notDirectory(url.path)
        }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let production = productionURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.caseInsensitiveCompare(production) != .orderedSame else {
            throw RootError.production(resolved)
        }

        let entries: [String]
        do {
            entries = try manager.contentsOfDirectory(atPath: resolved)
        } catch {
            throw RootError.inspectFailed(resolved, error)
        }
        guard entries.isEmpty else { throw RootError.notEmpty(resolved) }

        setenv("SENTRY_STATE_DIR", resolved, 1)
        return resolved
    }
}

/// Small relay used because the presentation callback is installed before the
/// demo controller has completed initialization.
@MainActor
private final class UIOnboardingDemoActionRelay {
    weak var controller: UIOnboardingDemoController?

    func handle(_ action: UIOnboardingAction) {
        controller?.handle(action)
    }
}

/// Hosts the production onboarding window over injected state. It is the only
/// owner of demo transitions. In particular, the Screen Recording action is
/// logged and suppressed, and the recovery result is fixed by `scenario`.
@MainActor
final class UIOnboardingDemoController {
    let scenario: UIOnboardingDemoScenario
    let presentation: UIOnboardingPresentation
    let windowController: UIOnboardingWindowController

    private var driver: UIOnboardingTestDriver?

    init(scenario: UIOnboardingDemoScenario) {
        self.scenario = scenario
        let relay = UIOnboardingDemoActionRelay()
        presentation = UIOnboardingPresentation(
            surface: scenario.initialSurface,
            callbacks: UIOnboardingCallbacks { action in relay.handle(action) })
        windowController = UIOnboardingWindowController(presentation: presentation)
        windowController.menuBarIconVisible = { scenario.menuBarIconVisible }
        relay.controller = self
    }

    func start(script: UIOnboardingTestScript?) {
        if let script {
            let driver = UIOnboardingTestDriver(script: script, host: testHost)
            self.driver = driver
            driver.run()
        } else {
            windowController.setAppearance(
                NSAppearance(named: scenario == .pinDark || scenario == .welcomeDark ? .darkAqua : .aqua))
            windowController.present()
            print("onboarding-demo: no SENTRY_UI_SCRIPT — window is interactive until app ttl")
        }
    }

    fileprivate func handle(_ action: UIOnboardingAction) {
        switch action {
        case .startSetup:
            presentation.surface = .createPIN(isSaving: false, error: nil)
        case .saveInitialPIN:
            presentation.surface = .allowScreenRecording
        case .openScreenRecordingSettings:
            // Safety contract: a demo never opens System Settings. The real
            // presentation still arms its one-shot return bit, so tests can
            // exercise the production handoff without an external action.
            print("onboarding-demo: SUPPRESSED opening System Settings")
            presentation.armExpectedSettingsReturn()
            // Production updates this visible window to the waiting state
            // after System Settings opens. Mirror that state change so a
            // click-through Receipt does not show a false no-op.
            let context: UIOnboardingPermissionContext = scenario == .repair ? .repair : .initialSetup
            presentation.surface = .awaitingScreenRecording(context: context)
        case .openScreenRecordingSettingsManually:
            print("onboarding-demo: SUPPRESSED opening System Settings (manual)")
        case .returnedFromScreenRecordingSettings:
            break
        case .confirmScreenRecordingEnabled:
            presentation.surface = .verifying(detail: "Starting protection…")
        case .closeCompletion:
            windowController.dismiss()
        case .retryServiceHealth:
            if scenario == .serviceRecovered {
                windowController.present(.protectionOn(showConfirmation: false))
            } else if scenario == .componentRecoveredNoPIN {
                presentation.surface = .createPIN(isSaving: false, error: nil)
            } else {
                presentation.surface = .serviceFailure(
                    component: "SentryScreen watchdog",
                    detail: "The required service is still not responding.")
            }
        case .beginPINRecovery:
            presentation.surface = .recoveryAuthentication(isAuthenticating: false, error: nil)
        case .authenticatePINRecovery:
            switch scenario {
            case .recoveryCancelled:
                presentation.surface = .recoveryAuthentication(
                    isAuthenticating: false,
                    error: "PIN reset was canceled. The current PIN is unchanged.")
            case .recoveryFailure:
                presentation.surface = .recoveryAuthentication(
                    isAuthenticating: false,
                    error: "This Mac could not verify the parent. Try again.")
            default:
                // Fixed fake success. No LocalAuthentication object exists in
                // this controller, so an automated run cannot show a real
                // authentication prompt.
                presentation.surface = .recoveryNewPIN(isSaving: false, error: nil)
            }
        case .saveRecoveredPIN:
            presentation.surface = .recoveryComplete
        case .finishPINRecovery:
            if scenario == .pinRecoveryRequired {
                presentation.surface = .verifying(detail: "Starting protection…")
            } else {
                windowController.dismiss()
            }
        case .cancelPINRecovery:
            presentation.surface = UIOnboardingDemoScenario.repairSurface()
        case .dismissWindow:
            // windowWillClose reports this event. Do not call dismiss again.
            break
        case .openDownloadPage:
            print("onboarding-demo: SUPPRESSED opening the download page")
        case .uninstall:
            print("onboarding-demo: SUPPRESSED uninstall")
        }
    }

    /// Accepts only explicit driver events that replace an external state
    /// change. A completed-install permission repair has already shown its
    /// success once, so restored protection uses the production
    /// `showConfirmation: false` projection and closes the setup window.
    private func handleTestSignal(_ signal: UIOnboardingTestSignal) -> Bool {
        switch signal {
        case .screenRecordingRestored:
            guard scenario == .repair,
                case .awaitingScreenRecording(context: .repair) = presentation.surface
            else { return false }
            print("onboarding-demo: FAKE Screen Recording restored (no TCC or capture action)")
            windowController.present(.protectionOn(showConfirmation: false))
            return true
        }
    }

    private var testHost: UIOnboardingTestHost {
        UIOnboardingTestHost(
            present: { [windowController] in windowController.present() },
            dismiss: { [windowController] in windowController.dismiss() },
            signal: { [weak self] signal in
                self?.handleTestSignal(signal) ?? false
            },
            isVisible: { [windowController] in
                windowController.visibleWindowNumber != nil
            },
            windowNumber: { [windowController] in
                windowController.visibleWindowNumber ?? 0
            },
            windowTitle: { [windowController] in
                guard windowController.visibleWindowNumber != nil else { return nil }
                return windowController.window?.title
            },
            windowCloseButtonEnabled: { [windowController] in
                guard windowController.visibleWindowNumber != nil else { return nil }
                return windowController.window?
                    .standardWindowButton(.closeButton)?.isEnabled
            },
            attemptWindowClose: { [windowController] in
                guard let window = windowController.window else { return false }
                return windowController.windowShouldClose(window)
            },
            closeWindow: { [windowController] in
                guard let window = windowController.window else { return false }
                window.performClose(nil)
                return !window.isVisible
            },
            contentView: { [windowController] in
                windowController.window?.contentView
            },
            setAppearance: { [windowController] name in
                let appearance = UIAppearanceOption.appearance(name)
                NSApp.appearance = appearance
                windowController.setAppearance(appearance)
            },
            setTextSize: { [windowController] name in
                windowController.setTextSize(name)
            })
    }
}

/// Lead-wiring API.
@MainActor
enum UIOnboardingDemoEntrypoint {
    /// Same attended-demo backstop as the established `--ui-demo` path; its
    /// Receipt lives at `UIDemoController.defaultTTL`.
    nonisolated static let defaultTTL = UIDemoController.defaultTTL

    static func start(scenario raw: String) -> UIOnboardingDemoController {
        guard let scenario = UIOnboardingDemoScenario(rawValue: raw) else {
            die(
                "--ui-onboarding-demo \(raw): expected "
                    + UIOnboardingDemoScenario.acceptedValues,
                code: UIDriver.Exit.usage.rawValue)
        }

        let stateRoot: String
        do {
            stateRoot = try UIOnboardingDemoStateRoot.prepare()
        } catch {
            die(
                "onboarding-demo: REFUSED — \(error). Use a fresh empty SENTRY_STATE_DIR.",
                code: UIDriver.Exit.usage.rawValue)
        }

        // Parse the complete script before the window exists. A bad action
        // therefore cannot leave a partially driven setup window on screen.
        let script = UIOnboardingTestScript.path.map(UIOnboardingTestScript.load)
        let banner = "onboarding-demo: FAKE STATE — no model, capture, overlay, "
            + "System Settings action, or LocalAuthentication"
        print(banner)
        FileHandle.standardError.write(Data("\(banner) (state dir \(stateRoot))\n".utf8))

        let controller = UIOnboardingDemoController(scenario: scenario)
        controller.start(script: script)
        return controller
    }
}
