import AppKit
import CoreGraphics
import Foundation

/// Static installation facts used before capture starts. The package
/// validator is authoritative before install; this check prevents an
/// incomplete installed payload from presenting a successful setup state.
struct UIOnboardingInstallationInspector {
    /// REQUIREMENT Receipt: packaging/release.env sets MACOS_MIN_VERSION=14.0.
    static let requiredMacOSMajor = 14
    /// REQUIREMENT Receipt: packaging/release.env ships
    /// `SENTRY_ARCHS="arm64 x86_64"` — one universal package, macOS picks the
    /// slice (owner 2026-09-02) — and the same minimum macOS version that this
    /// parent-facing failure text reports. The text names only the macOS
    /// requirement because the processor is no longer one: both shipped slices
    /// pass this gate. What is NOT proven is Intel *performance*,
    /// and that is a support
    /// and adaptation question, not a reason to refuse to start.
    static let requiredDescription = "macOS 14 or later"

    static func hostSupport() -> UIOnboardingHostSupport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // Compile-time, per slice: a slice that macOS chose to run is by
        // definition one this package ships. A third architecture would mean a
        // binary built outside packaging/release.env's contract, so it fails
        // closed and names itself.
        //
        // The LABEL comes from HostArch.description, which distinguishes a
        // translated process from a real Intel Mac. This string can surface to
        // a parent (the `.unsupported` message below), and calling a Rosetta
        // process "Intel" would send them to the wrong support answer for a
        // problem that a native relaunch fixes.
        let architectureSupported = HostArch.shipped.contains(HostArch.compiled)
        let architecture = architectureSupported
            ? HostArch.description : "unsupported processor"
        guard version.majorVersion >= requiredMacOSMajor, architectureSupported else {
            return .unsupported(
                required: requiredDescription,
                observed: "macOS \(version.majorVersion).\(version.minorVersion), \(architecture)")
        }
        return .supported
    }

    /// REQUIREMENT Receipt: packaging/install.sh and packaging/build-pkg.sh
    /// write every installed component below this root.
    static let productionSupportRoot = "/Library/Application Support/SentryScreen"

    /// The installed payload the daemon needs before it can protect anything.
    /// `modelPath` is the path the daemon will actually load — `opts.model`,
    /// resolved from `config.json`'s "model" key or `--model` — not a
    /// hardcoded filename. Receipt: the detector is a swappable file (docs/spec.md
    /// Architecture) and an M1 Mac install moved from `640m.mlpackage` to
    /// `yolox_50ep_v5_best_fp16.mlpackage` on 2026-08-28 and to
    /// `yolox_50ep_v8_ep50_fp16.mlpackage` on 2026-09-01. The previous
    /// hardcoded `640m.mlpackage` therefore checked a file the daemon does not
    /// load: it would report a healthy install as missing its detector after a
    /// model swap, and would report healthy when the configured model is the
    /// one that is actually absent. `supportRoot` is injected only so
    /// `--onboarding-selftest` can run against a temporary tree.
    static func requiredComponents(
        modelPath: String,
        supportRoot: String = productionSupportRoot
    ) -> [(name: String, path: String)] {
        [
            ("SentryScreen app", "\(supportRoot)/SentryScreen.app/Contents/MacOS/sentry-screen"),
            ("detector model", modelPath),
            ("configuration", "\(supportRoot)/config.json"),
            ("launch agent", "\(supportRoot)/agent-launch.sh"),
            ("watchdog", "\(supportRoot)/watchdog.sh"),
            ("launch agent registration", "/Library/LaunchAgents/com.sentryscreen.agent.plist"),
            ("watchdog registration", "/Library/LaunchDaemons/com.sentryscreen.watchdog.plist"),
        ]
    }

    /// An unset model path fails loudly instead of passing as healthy. Without
    /// a detector the pipeline reports every frame as clean, which is worse
    /// than a visible failure. Argument parsing already exits 64 on an empty
    /// `--model` for every mode that builds this runtime, so this is a
    /// tripwire, not an expected state.
    static let unconfiguredModelReason =
        "Required installed component is missing: detector model "
        + "(no \"model\" key in config.json and no --model flag)"

    static func componentHealth(
        installedMode: Bool,
        modelPath: String,
        supportRoot: String = productionSupportRoot
    ) -> UIOnboardingComponentHealth {
        guard installedMode else { return .healthy }
        guard !modelPath.isEmpty else { return .unhealthy(reason: unconfiguredModelReason) }
        let missing = requiredComponents(modelPath: modelPath, supportRoot: supportRoot)
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            return .unhealthy(
                reason: "Required installed component is missing: "
                    + missing.map(\.name).joined(separator: ", "))
        }
        return .healthy
    }

    static func missingComponentPaths(
        installedMode: Bool,
        modelPath: String,
        supportRoot: String = productionSupportRoot
    ) -> [String] {
        guard installedMode else { return [] }
        guard !modelPath.isEmpty else { return ["(detector model path not configured)"] }
        return requiredComponents(modelPath: modelPath, supportRoot: supportRoot)
            .map(\.path)
            .filter { !FileManager.default.fileExists(atPath: $0) }
    }
}

/// Checks the two launchd jobs after the first valid capture frame. The
/// current process proves that the agent executable is running; `launchctl
/// print` proves that both required jobs remain registered in their domains.
/// It runs off the main actor because process launch and wait are blocking.
final class UIOnboardingServiceChecker {
    struct Failure: Error, Equatable {
        let description: String
        let diagnostic: String

        init(description: String, diagnostic: String? = nil) {
            self.description = description
            self.diagnostic = diagnostic ?? description
        }
    }
    typealias ServiceResult = Result<Void, Failure>

    private let check: (@escaping @MainActor (ServiceResult) -> Void) -> Void

    init(check: ((@escaping @MainActor (ServiceResult) -> Void) -> Void)? = nil) {
        self.check = check ?? Self.checkSystemServices
    }

    func run(completion: @escaping @MainActor (ServiceResult) -> Void) {
        check(completion)
    }

    private static func checkSystemServices(
        completion: @escaping @MainActor (ServiceResult) -> Void
    ) {
        let uid = getuid()
        DispatchQueue.global(qos: .utility).async {
            let jobs = [
                "gui/\(uid)/com.sentryscreen.agent",
                "system/com.sentryscreen.watchdog",
            ]
            let results = jobs.map { ($0, launchdJobIsHealthy($0)) }
            let unhealthy = results.filter { $0.1 != .healthy }
            let timedOut = results.filter { $0.1 == .timedOut }.map(\.0)
            DispatchQueue.main.async {
                if unhealthy.isEmpty {
                    completion(.success(()))
                } else {
                    completion(.failure(Failure(
                        description: "A required background service is not running correctly.",
                        diagnostic: "launchd job is not healthy: "
                            + unhealthy.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ", ")
                            + (timedOut.isEmpty ? "" : "; " + launchctlTripwireRecord(timedOut)))))
                }
            }
        }
    }

    enum JobHealth: String, Equatable {
        case healthy
        case unhealthy
        case timedOut = "timed-out"
    }

    /// MEASURED Receipt: `/bin/launchctl print` returned in 3.6–6.7 ms across
    /// 80 invocations on the installed M1 Mac on 2026-08-28 (four targets — both
    /// SentryScreen jobs, com.apple.dock, com.apple.opendirectoryd — twenty
    /// runs each; median 3.8 ms, maximum 6.7 ms). Five seconds is about 700×
    /// that maximum, so it can only fire when launchd itself is wedged. Two
    /// sequential job checks are therefore 10 s worst case, below the 30 s
    /// `UIOnboardingRuntime.freshFrameDeadline`.
    ///
    /// That ordering does **not** mean a wedged check always reports through
    /// the main actor. `freshFrameDeadline` is one shared budget armed at
    /// `startCaptureWithDeadline()` and covering capture start, the first
    /// frame, and this service check together — `captureProducedFirstFrame`
    /// reuses the live epoch rather than re-arming — so a late first frame can
    /// leave less than 10 s for the checks. When that happens the outer
    /// deadline fires first and the epoch guard in `checkRequiredServices`
    /// drops the late completion, taking `Failure.diagnostic` with it.
    /// The tripwire still names the wedged job because `launchdJobIsHealthy`
    /// writes the record to stderr before returning `.timedOut`, on the
    /// utility queue and independent of the epoch — packaging/agent-launch.sh
    /// redirects the daemon's stderr to `agent.err`. Two channels, and only
    /// the main-actor one is swallowable.
    static let launchctlTimeout: TimeInterval = 5

    /// Limits fail loudly: budget name, configured limit, observed value, and
    /// where to change it.
    static func launchctlTripwireRecord(_ targets: [String]) -> String {
        "tripwire=UIOnboardingServiceChecker.launchctlTimeout "
            + "limit=\(launchctlTimeout)s observed=no-exit "
            + "targets=\(targets.joined(separator: ",")) "
            + "action=terminated-and-treated-as-unhealthy "
            + "fix=daemon/Sources/SentryScreen/UIOnboardingRuntime.swift"
    }

    private static func launchdJobIsHealthy(_ target: String) -> JobHealth {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .unhealthy
        }
        // A wedged launchctl must not hold this queue forever. Terminating the
        // child closes its end of the pipe, which is what releases the
        // blocking read below; `waitUntilExit` then reaps it on every path, so
        // no process is leaked whether it exits on its own or is terminated.
        // `budgetExpired` is written on a global queue and read on this one,
        // so it takes a lock: the pipe EOF is not a memory barrier for it.
        let lock = NSLock()
        var budgetExpired = false
        let watchdog = DispatchWorkItem {
            lock.lock()
            budgetExpired = true
            lock.unlock()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + launchctlTimeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Disclosed window: `cancel()` runs after `waitUntilExit()`, so a
        // child that exits within microseconds of the budget can still have an
        // already-dispatched watchdog set `budgetExpired` and call
        // `terminate()` on a reaped process. `terminate()` on a process that
        // has exited is a no-op, and the only observable effect is that such a
        // child is reported `.timedOut` (fail loud) instead of by its exit
        // status. Cancelling any earlier than this would be worse: the
        // watchdog's `terminate()` is what closes the pipe and releases the
        // blocking read above, so a cancel before it would let a genuinely
        // wedged launchctl hold this queue forever.
        watchdog.cancel()
        lock.lock()
        let exceededBudget = budgetExpired
        lock.unlock()

        // Only the watchdog's own flag reports a timeout. A launchctl killed
        // by some other signal is unhealthy too, but it did not exceed this
        // budget and must not be reported as `observed=no-exit`; it falls
        // through to the non-zero termination status below.
        if exceededBudget {
            FileHandle.standardError.write(Data(
                ("onboarding: " + launchctlTripwireRecord([target]) + "\n").utf8))
            return .timedOut
        }
        guard process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else { return .unhealthy }
        let lines = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let running = lines.contains("state = running")
        if target.hasSuffix("com.sentryscreen.agent") {
            return running ? .healthy : .unhealthy
        }
        return running || lines.contains("last exit code = 0") ? .healthy : .unhealthy
    }
}

/// Production adapter for the durable onboarding coordinator. It owns no
/// capture or launchd state. AppDelegate supplies those boundaries and calls
/// `captureProducedFirstFrame()` only for a valid frame from the new process.
@MainActor
final class UIOnboardingRuntime {
    enum LaunchDisposition: Equatable {
        case startCapture
        case waitForParent(showCaptureLoss: Bool)
    }

    /// One policy for every Screen Recording handoff. Keeping registration
    /// separate from guidance prevents two macOS/app-owned prompts from being
    /// raised together during repair.
    enum ScreenRecordingPermissionRoute: Equatable, Sendable {
        /// Fresh setup Continue: let macOS own the first prompt.
        case nativeRequest
        /// A direct Settings handoff. A user-selected missing-row fallback
        /// registers the app first and shows the drag helper.
        case settings(
            guideMode: ScreenRecordingGuideMode,
            requestsRegistration: Bool
        )
    }

    /// What a non-administrator launch does: the capture decision and whether
    /// the parent-facing onboarding step is presented on top of it.
    struct StandardSessionLaunch: Equatable {
        let disposition: LaunchDisposition
        let presentsParentStep: Bool
    }

    private let store: UISettingsStore
    private let log: (String, String) -> Void
    private let installedMode: Bool
    /// The detector the daemon will actually load (`opts.model`). The
    /// installed-component health check verifies this path, not a hardcoded
    /// filename, so a model swap cannot make a healthy install look broken.
    private let modelPath: String
    private let processStartedAt: Date
    private let requestScreenRecording: () -> Void
    private let openScreenRecordingSettings: (ScreenRecordingGuideMode) -> Bool
    private let restartForVerification: () -> Void
    private let retryCaptureStartup: () -> Void
    private let captureIsLive: () -> Bool
    /// True while CaptureStream is suspended (session inactive, screen locked,
    /// display asleep). MEASURED 2026-08-29 07:32:35Z: with the owner switched
    /// to the child account, no frame can arrive in this session, the 30 s
    /// fresh-frame deadline fired, and the shield went red until the first
    /// frame on return at 07:33:09Z. A suspended capture is not a failed one.
    private let captureIsSuspended: () -> Bool
    private let reportHealth: (CaptureHealth) -> Void
    /// UIOnboardingWindowController.menuBarIconVisible (the close invariant).
    private let menuBarIconVisible: () -> Bool
    private let serviceChecker: UIOnboardingServiceChecker

    /// The Setup window's uninstall link (`UIActions.uninstallFromSetupWindow`).
    /// nil hides the link, as in a session that cannot remove the app.
    var onUninstall: (() -> Void)? {
        didSet { presentation.uninstallAvailable = onUninstall != nil }
    }

    private let coordinator: UIOnboardingCoordinator
    private let pinGate: PinGate
    private let recovery: UIPinRecoveryController
    private let presentation: UIOnboardingPresentation
    private lazy var windowController: UIOnboardingWindowController = {
        let c = UIOnboardingWindowController(
            presentation: presentation,
            onCompletionPresented: { [weak self] in self?.completionWasPresented() })
        c.menuBarIconVisible = menuBarIconVisible
        return c
    }()

    private var screenRecordingApproved = false
    /// Welcome (O11) was passed in this process. Process-local on purpose:
    /// the step itself is derived from durable state (no PIN, never
    /// completed), so the exit-7 relaunch shows it again only if no PIN exists.
    private var welcomeAcknowledged = false
    private var componentHealth: UIOnboardingComponentHealth
    private var verification: UIOnboardingVerificationStatus = .notStarted
    private var recoveryAuthorization: UIPinRecoveryAuthorization?
    private var recoveryEpoch = 0
    private enum RecoveryOrigin {
        case onboarding(UIOnboardingStep)
        case parentControls
    }
    /// Screen Recording permission is not the same failure as a capture
    /// stream that stops while permission is still approved. Only the former
    /// may route to the macOS privacy pane.
    enum FailedHealthSource: Equatable {
        case settings, components, services, screenRecordingPermission, capture, model
    }
    private var recoveryOrigin: RecoveryOrigin?
    private var failedHealthSource: FailedHealthSource?
    private var failedComponent = "SentryScreen"
    private var failedDetail = "Protection needs repair."
    private var restartIssued = false
    private var captureHealthy = false
    private var awaitingMachineWideOnboarding = false
    private var previousCompletedAt: Date?
    private var previousVerificationPending: Bool
    private var localVerificationTransactionInProgress = false
    private var passiveRecoveryScheduled = false
    private var settingsRepairRequired = false
    private var frameDeadlineEpoch = 0
    private var captureGenerationEpoch = 0
    private var verificationDeadlineActive = false

    private var protectionVerified: Bool {
        Self.protectionIsVerified(
            captureHealthy: captureHealthy,
            captureLive: captureIsLive(),
            verification: verification)
    }

    /// True while this process already has a visible surface for its current
    /// classified failure. AppDelegate uses it to keep the hard-coded Screen
    /// Recording banner as a fallback, never as a duplicate or as the wrong
    /// explanation for a component, service, model, or settings failure.
    @MainActor var ownsCaptureLossSurface: Bool {
        let captureFailureIsActive = Self.captureLossSourceIsActive(failedHealthSource)
        let repairSurfaceIsVisible = Self.captureLossRepairSurfaceIsVisible(
            presentation.surface,
            windowVisible: windowController.window?.isVisible == true)
        return Self.captureLossSurfaceIsOwned(
            isAdministrator: AdminCheck.isAdminSession().admin,
            captureFailureIsActive: captureFailureIsActive,
            repairSurfaceIsVisible: repairSurfaceIsVisible)
    }

    /// The durable one-time completion confirmation, independent of whether
    /// AppKit has made its window key yet.
    @MainActor var successConfirmationPending: Bool {
        let onboarding = store.settings.onboarding
        return Self.successConfirmationIsPending(
            completedAt: onboarding.completedAt,
            successShownAt: onboarding.successShownAt)
    }

    /// One passive retry for a Standard account. Receipt: this reuses the
    /// measured 5-second capture-loss poll cadence in AppDelegate. It is long
    /// enough to avoid an immediate start loop, and the per-process guard
    /// makes the retry count exactly one.
    nonisolated static let passiveRecoveryDelay: TimeInterval = 5

    /// The two required
    /// `launchctl print` checks completed together in less than 0.2 seconds on
    /// 2026-08-26. Thirty seconds is more than eight times the measured frame
    /// maximum and bounds the full frame-plus-service verification.
    nonisolated static let freshFrameDeadline: TimeInterval = 30

    nonisolated static func presentsWindow(for step: UIOnboardingStep) -> Bool {
        if case .protectionOn(showConfirmation: false) = step { return false }
        return true
    }

    enum PermissionHandoffAuthority: Equatable {
        case correlated
        case local
    }

    /// Administrator sessions correlate the restart in the machine-wide
    /// onboarding record. Standard sessions can still force one fresh TCC
    /// evaluation, but they must not write that administrator-owned record.
    nonisolated static func permissionHandoffAuthority(
        isAdministrator: Bool
    ) -> PermissionHandoffAuthority {
        isAdministrator ? .correlated : .local
    }

    static let recoveryLifecycleRevocationSurface = UIOnboardingSurface
        .recoveryAuthentication(
            isAuthenticating: false,
            error: UIPinRecoveryError.authenticationCancelled.description)

    nonisolated static func settingsOpenFailureSurface(
        context: UIOnboardingPermissionContext,
        requestDisarmed: Bool
    ) -> UIOnboardingSurface {
        if !requestDisarmed {
            return .serviceFailure(
                component: "Fresh-process verification",
                detail: "System Settings did not open, and the pending verification "
                    + "request could not be cleared. Restart SentryScreen before you retry.")
        }
        return .permissionMissing(
            context: context,
            reason: "System Settings did not open. Open Privacy & Security, then Screen Recording.",
            error: nil)
    }

    /// Fresh Continue raises only the native prompt. A manual first-run
    /// fallback both registers the app and explains the drag gesture. Repair
    /// already has a registered TCC row, so it opens Settings with only the
    /// precise spotlight and never raises CGRequest at the same time.
    nonisolated static func screenRecordingPermissionRoute(
        context: UIOnboardingPermissionContext,
        manualFallback: Bool
    ) -> ScreenRecordingPermissionRoute {
        switch (context, manualFallback) {
        case (.initialSetup, false):
            return .nativeRequest
        case (.initialSetup, true):
            return .settings(
                guideMode: .spotlightWithAddHelper,
                requestsRegistration: true)
        case (.repair, false):
            return .settings(
                guideMode: .spotlight,
                requestsRegistration: false)
        case (.repair, true):
            return .settings(
                guideMode: .spotlightWithAddHelper,
                requestsRegistration: true)
        }
    }

    /// Pure projections for the banner arbiter in AppDelegate and its
    /// deterministic selftest. Account type does not decide visual ownership:
    /// a Standard permission-wait or read-only repair window is still the one
    /// app-owned explanation after the user opens it. PIN recovery is not a
    /// health-loss explanation; a health transition retires it first.
    nonisolated static func captureLossSourceIsActive(
        _ source: FailedHealthSource?
    ) -> Bool {
        source != nil
    }

    nonisolated static func launchPermissionRepairIsActive(
        completed: Bool,
        legacyMigrationPending: Bool,
        screenRecordingApproved: Bool
    ) -> Bool {
        (completed || legacyMigrationPending) && !screenRecordingApproved
    }

    nonisolated static func captureLossRepairSurfaceIsVisible(
        _ surface: UIOnboardingSurface,
        windowVisible: Bool
    ) -> Bool {
        guard windowVisible else { return false }
        switch surface {
        case let .permissionMissing(context, _, _),
             let .awaitingScreenRecording(context):
            return context == .repair
        case .serviceFailure, .administratorRepairRequired:
            return true
        default:
            return false
        }
    }

    nonisolated static func captureLossSurfaceIsOwned(
        isAdministrator: Bool,
        captureFailureIsActive: Bool,
        repairSurfaceIsVisible: Bool
    ) -> Bool {
        _ = isAdministrator
        return captureFailureIsActive && repairSurfaceIsVisible
    }

    nonisolated static func standardRepairSurface(
        source: FailedHealthSource,
        component: String,
        detail: String
    ) -> UIOnboardingSurface {
        healthLossSurface(
            source: source,
            isAdministrator: false,
            component: component,
            detail: detail)
    }

    /// The visible replacement for an active PIN-recovery transaction when
    /// protection loses health. This projection is also used for ordinary
    /// named failures, so the surface cannot drift from the transition.
    nonisolated static func healthLossSurface(
        source: FailedHealthSource,
        isAdministrator: Bool,
        component: String,
        detail: String
    ) -> UIOnboardingSurface {
        switch source {
        case .settings, .components, .services, .capture, .model:
            return isAdministrator
                ? .serviceFailure(component: component, detail: detail)
                : .administratorRepairRequired(component: component, detail: detail)
        case .screenRecordingPermission:
            return .permissionMissing(
                context: .repair,
                reason: detail,
                error: nil)
        }
    }

    /// Durable completion remains pending until the parent uses Done. The
    /// short green status toast must not compete with that one-time message.
    nonisolated static func successConfirmationIsPending(
        completedAt: Date?,
        successShownAt: Date?
    ) -> Bool {
        completedAt != nil && successShownAt == nil
    }

    /// A stream stop uses the permission journey only when permission is
    /// denied and no higher-priority settings repair is active.
    nonisolated static func captureLossUsesPermissionRepair(
        settingsRepairRequired: Bool,
        screenRecordingApproved: Bool
    ) -> Bool {
        !settingsRepairRequired && !screenRecordingApproved
    }

    /// A visible Standard recovery window must close when capture and service
    /// health are verified. It has no durable completion acknowledgment.
    nonisolated static func standardHealthyPresentationStep(
        isAdministrator: Bool
    ) -> UIOnboardingStep? {
        isAdministrator ? nil : .protectionOn(showConfirmation: false)
    }

    init(
        store: UISettingsStore,
        installedMode: Bool,
        modelPath: String,
        processStartedAt: Date = Date(),
        log: @escaping (String, String) -> Void,
        requestScreenRecording: @escaping () -> Void,
        openScreenRecordingSettings: @escaping (ScreenRecordingGuideMode) -> Bool,
        restartForVerification: @escaping () -> Void,
        retryCaptureStartup: @escaping () -> Void,
        captureIsLive: @escaping () -> Bool,
        captureIsSuspended: @escaping () -> Bool = { false },
        reportHealth: @escaping (CaptureHealth) -> Void,
        menuBarIconVisible: @escaping () -> Bool = { false },
        serviceChecker: UIOnboardingServiceChecker = UIOnboardingServiceChecker()
    ) {
        self.store = store
        self.menuBarIconVisible = menuBarIconVisible
        self.installedMode = installedMode
        self.modelPath = modelPath
        self.processStartedAt = processStartedAt
        self.log = log
        self.requestScreenRecording = requestScreenRecording
        self.openScreenRecordingSettings = openScreenRecordingSettings
        self.restartForVerification = restartForVerification
        self.retryCaptureStartup = retryCaptureStartup
        self.captureIsLive = captureIsLive
        self.captureIsSuspended = captureIsSuspended
        self.reportHealth = reportHealth
        self.serviceChecker = serviceChecker
        componentHealth = UIOnboardingInstallationInspector.componentHealth(
            installedMode: installedMode, modelPath: modelPath)
        coordinator = UIOnboardingCoordinator(store: store)
        pinGate = PinGate(store: store, log: log)
        recovery = UIPinRecoveryController(store: store, log: log)
        previousCompletedAt = store.settings.onboarding.completedAt
        previousVerificationPending = store.settings.onboarding.verificationPending

        let missingPaths = UIOnboardingInstallationInspector.missingComponentPaths(
            installedMode: installedMode, modelPath: modelPath)
        if !missingPaths.isEmpty {
            log("onboarding", "missing installed component paths: " + missingPaths.joined(separator: ", "))
        }

        var actionCallback: ((UIOnboardingAction) -> Void)?
        presentation = UIOnboardingPresentation(callbacks: UIOnboardingCallbacks(
            handle: { action in actionCallback?(action) }))
        actionCallback = { [weak self] action in self?.handle(action) }
        recovery.onLifecycleRevocation = { [weak self] in
            self?.pinRecoveryWasRevokedForSessionLifecycle()
        }
    }

    /// Evaluates the launch once. No permission request occurs here. The
    /// parent first sees the explanation and explicitly starts that action.
    func start(screenRecordingApproved: Bool) -> LaunchDisposition {
        self.screenRecordingApproved = screenRecordingApproved
        let onboarding = store.settings.onboarding
        let completed = onboarding.completedAt != nil
        let repair = completed || onboarding.isLegacyMigrationPending
        let administrator = AdminCheck.isAdminSession().admin

        if Self.launchPermissionRepairIsActive(
            completed: completed,
            legacyMigrationPending: onboarding.isLegacyMigrationPending,
            screenRecordingApproved: screenRecordingApproved)
        {
            failedHealthSource = .screenRecordingPermission
            failedComponent = "Screen Recording"
            failedDetail = "SentryScreen is not enabled in Screen Recording."
            log(
                "onboarding",
                "permission-repair state=required source=launch-preflight pid=\(getpid())")
        }

        if case .unsupported = UIOnboardingInstallationInspector.hostSupport() {
            presentCurrentStep()
            return .waitForParent(showCaptureLoss: false)
        }
        if case let .unhealthy(reason) = componentHealth {
            failedHealthSource = .components
            failedComponent = "Installed component"
            failedDetail = reason
            if administrator {
                presentCurrentStep()
            } else {
                presentStandardRepairFailure(
                    source: .components,
                    component: failedComponent,
                    detail: failedDetail)
            }
            if completed {
                reportHealth(.lost(since: Date(), reason: reason))
            }
            return .waitForParent(showCaptureLoss: completed)
        }
        if installedMode, store.fileHealth != .readable {
            let reason = store.fileHealth.repairDetail
            settingsRepairRequired = true
            failedHealthSource = .settings
            failedComponent = "Parent settings"
            failedDetail = reason
            if administrator {
                presentation.surface = .serviceFailure(
                    component: "Parent settings", detail: reason)
                windowController.present()
            } else {
                presentStandardRepairFailure(
                    source: .settings,
                    component: failedComponent,
                    detail: failedDetail)
            }
            reportHealth(.lost(since: Date(), reason: reason))
            // Damaged parent state must disable parent mutations, not screen
            // protection. Defaults remain fail-toward-protection, and capture
            // continues whenever macOS permission is already available.
            if screenRecordingApproved {
                return startCaptureWithDeadline()
            }
            return waitForMachineWideOnboarding(showCaptureLoss: true)
        }
        if store.settings.readOnly {
            // A downgrade must not replace a future schema, but it must also
            // not stop protection. Run capture when permission allows it and
            // expose an update-required failure without offering mutations.
            log("onboarding", "future onboarding schema is read-only; parent mutations disabled")
            if screenRecordingApproved {
                return startCaptureWithDeadline()
            }
            if administrator {
                presentUpdateRequired(protectionPaused: true)
            }
            return .waitForParent(showCaptureLoss: true)
        }
        guard administrator else {
            let launch = Self.standardSessionLaunch(
                completed: completed,
                screenRecordingApproved: screenRecordingApproved)
            if launch.presentsParentStep {
                presentCurrentStep()
            }
            guard case let .waitForParent(showCaptureLoss) = launch.disposition else {
                return startCaptureWithDeadline()
            }
            return waitForMachineWideOnboarding(showCaptureLoss: showCaptureLoss)
        }

        if onboarding.verificationPending {
            if let requestID = onboarding.verificationRequestID {
                log("onboarding", "handoff=resumed requestID=\(requestID.uuidString) "
                    + "newPID=\(getpid()) newStartedAt=\(Self.receiptTime(processStartedAt))")
            }
            guard screenRecordingApproved else {
                settlePendingVerificationFailure()
                verification = .failed(reason: "Screen Recording is still off.")
                presentPermissionFailure(repair: repair, returnedFromSettings: true)
                return waitForMachineWideOnboarding(showCaptureLoss: completed)
            }
            verification = .checkingFreshProcess
            presentCurrentStep()
            return startCaptureWithDeadline()
        }

        guard store.parentPIN != nil else {
            presentCurrentStep()
            if completed, screenRecordingApproved {
                return startCaptureWithDeadline()
            }
            return waitForMachineWideOnboarding(showCaptureLoss: false)
        }
        guard UIPin.isUsableRecord(store.parentPIN!) else {
            presentCurrentStep()
            // PIN recovery changes parent authorization only. A completed
            // installation with capture permission must keep protecting while
            // the parent repairs that credential.
            if completed, screenRecordingApproved {
                return startCaptureWithDeadline()
            }
            return waitForMachineWideOnboarding(showCaptureLoss: false)
        }

        if completed {
            guard screenRecordingApproved else {
                presentPermissionFailure(repair: true)
                return waitForMachineWideOnboarding(showCaptureLoss: true)
            }
            return startCaptureWithDeadline()
        }

        if onboarding.isLegacyMigrationPending, screenRecordingApproved {
            beginFreshProcessHandoff()
            return .waitForParent(showCaptureLoss: false)
        }
        guard screenRecordingApproved else {
            presentCurrentStep()
            return waitForMachineWideOnboarding(showCaptureLoss: repair)
        }

        // Permission existed before first-PIN setup. A single restart creates
        // the causal fresh-process Receipt instead of trusting this process.
        beginFreshProcessHandoff()
        return .waitForParent(showCaptureLoss: false)
    }

    /// Called from Pipeline's first valid-frame hook, not from stream start.
    /// The launchd service check is the last condition in the completion
    /// Receipt and does not block the frame-processing queue.
    func captureProducedFirstFrame() {
        screenRecordingApproved = true
        captureHealthy = true
        if settingsRepairRequired {
            finishVerificationDeadline()
            reportHealth(.lost(
                since: Date(), reason: store.fileHealth.repairDetail))
            return
        }
        verification = .checkingFreshProcess
        let epoch = verificationDeadlineActive
            ? frameDeadlineEpoch : armVerificationDeadline()
        checkRequiredServices(epoch: epoch)
    }

    /// A replacement SCStream has no right to inherit the prior stream's
    /// pixel Receipt. This invalidates any in-flight service result and keeps
    /// the end-to-end deadline active until the replacement supplies content.
    func captureGenerationInvalidated() {
        captureHealthy = false
        captureGenerationEpoch += 1
        if settingsRepairRequired {
            finishVerificationDeadline()
            reportHealth(.lost(since: Date(), reason: store.fileHealth.repairDetail))
            return
        }
        verification = .checkingFreshProcess
        if !verificationDeadlineActive {
            _ = armVerificationDeadline()
        }
        reportHealth(.starting)
    }

    /// Keeps startup and capture failures visible in this process. This also
    /// settles the one handoff, so the watchdog cannot repeat a failed pending
    /// verification without a new parent action.
    /// Parent sentence first, developer receipt on a second line
    /// (2026-09-11). A failure card is the most stressed thing a parent reads
    /// in this app, and it opened with a constant name and an instruction to
    /// inspect launchd. The receipt still reaches the card, the log and the
    /// diagnostic report — one line lower, where it belongs.
    nonisolated static func parentDetail(_ sentence: String, receipt: String?) -> String {
        guard let receipt, !receipt.isEmpty, receipt != sentence else { return sentence }
        return sentence + "\n" + receipt
    }

    func captureFailed(component: String, reason: String, receipt: String? = nil) {
        finishVerificationDeadline()
        captureHealthy = false
        if settingsRepairRequired {
            let settingsReason = store.fileHealth.repairDetail
            reportHealth(.lost(since: Date(), reason: settingsReason))
            log(
                "onboarding",
                "\(component) also failed while parent settings repair remains required: \(reason)")
            return
        }
        failedHealthSource = component == "Detector model" ? .model : .capture
        failedComponent = component
        failedDetail = Self.parentDetail(reason, receipt: receipt)
        verification = .failed(reason: reason)
        log("onboarding", "\(component) failed before verification completed: "
            + Self.parentDetail(reason, receipt: receipt).replacingOccurrences(of: "\n", with: " · "))
        let source = failedHealthSource ?? .capture
        let administrator = AdminCheck.isAdminSession().admin
        if administrator {
            settlePendingVerificationFailure()
        }
        presentHealthLoss(source: source, component: component, detail: reason)
        reportHealth(.lost(since: Date(), reason: reason))
        if !administrator {
            scheduleStandardRecovery(source: failedHealthSource ?? .capture)
        }
    }

    func captureWasLost(reason: String) {
        // A stopped stream is not proof that TCC changed. Re-arm and service
        // failures also arrive here. Keep the permission journey only for a
        // current preflight denial; otherwise preserve the service-failure
        // path and any higher-priority settings repair.
        guard Self.captureLossUsesPermissionRepair(
            settingsRepairRequired: settingsRepairRequired,
            screenRecordingApproved: CGPreflightScreenCaptureAccess())
        else {
            captureFailed(component: "Screen capture", reason: reason)
            return
        }
        finishVerificationDeadline()
        captureHealthy = false
        screenRecordingApproved = false
        failedHealthSource = .screenRecordingPermission
        failedComponent = "Screen Recording"
        failedDetail = reason
        verification = .failed(reason: reason)
        log(
            "onboarding",
            "permission-repair state=required source=capture-stream pid=\(getpid())")
        log("onboarding", "Screen capture lost permission before verification completed: \(reason)")

        if AdminCheck.isAdminSession().admin {
            settlePendingVerificationFailure()
            // Establish the direct permission surface before health is
            // reported. AppDelegate can now suppress its fallback banner
            // synchronously instead of flashing both surfaces.
            presentHealthLoss(
                source: .screenRecordingPermission,
                component: failedComponent,
                detail: "SentryScreen is not enabled in Screen Recording. "
                    + "Open Screen Recording settings and turn it on.")
        } else {
            scheduleStandardRecovery(source: .screenRecordingPermission)
        }

        reportHealth(.lost(since: Date(), reason: reason))
    }

    /// The last `UIOnboardingServiceChecker` answer this process got (both
    /// launchd jobs registered): nil until it has run. Read by `setupHealthy`.
    /// Refreshed by `recheckServicesIfDue` while the app runs, not only at
    /// launch verification.
    private(set) var servicesVerified: Bool?

    /// How often the running app re-asks launchd about both jobs, for the
    /// menu-bar green check (owner 2026-10-20: a job lost after launch must
    /// take the check away, not wait for the next launch). DERIVED: one
    /// check is two `launchctl print` calls, 3.6–6.7 ms each (MEASURED,
    /// receipt at `UIOnboardingServiceChecker.launchctlTimeout`), off the
    /// main thread; every 30 s is under 0.05 % of one core, and a lost job
    /// shows within 30 s plus the 1 Hz tick.
    nonisolated static let serviceRecheckSecs: TimeInterval = 30
    private var lastServiceRecheck: Date?
    private var serviceRecheckInFlight = false

    nonisolated static func serviceRecheckDue(installedMode: Bool, inFlight: Bool, last: Date?, now: Date) -> Bool {
        guard installedMode, !inFlight else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= serviceRecheckSecs
    }

    /// Called on the 1 Hz settings tick. Installed runs only; one check in
    /// flight at a time (a wedged launchctl is bounded by its own named
    /// timeout and logs it). A change in the answer is logged by name.
    func recheckServicesIfDue(now: Date = Date()) {
        guard Self.serviceRecheckDue(
            installedMode: installedMode, inFlight: serviceRecheckInFlight, last: lastServiceRecheck, now: now)
        else { return }
        lastServiceRecheck = now
        serviceRecheckInFlight = true
        serviceChecker.run { [weak self] result in
            guard let self else { return }
            self.serviceRecheckInFlight = false
            let ok: Bool
            switch result {
            case .success: ok = true
            case let .failure(failure):
                ok = false
                if self.servicesVerified != false { self.log("onboarding", "service recheck: " + failure.diagnostic) }
            }
            if ok, self.servicesVerified == false { self.log("onboarding", "service recheck: both launchd jobs healthy again") }
            self.servicesVerified = ok
        }
    }

    /// Everything onboarding checks before it calls setup complete, as of
    /// now, for the menu-bar green check (2026-10-20). REUSES onboarding's
    /// own checks, no new ones: Screen Recording (`CGPreflightScreenCaptureAccess`,
    /// the call `captureWasLost` uses, and this runtime's own view of it),
    /// the installed components including both launchd plists
    /// (`UIOnboardingInstallationInspector.componentHealth`, file stats,
    /// cheap enough for the 1 Hz tick), and the last launchd job check
    /// (`servicesVerified`; launchctl is re-run every `serviceRecheckSecs`,
    /// not per tick), and a live capture stream (`captureIsLive`, so a
    /// stream that died takes the check away before health notices). The
    /// detector is covered by the glyph: a failing detector is not
    /// Protecting (`UIState.menuBarBadgeOK`). A development run (not
    /// installed) is never "all good".
    var setupHealthy: Bool {
        Self.setupHealthy(
            installedMode: installedMode,
            screenRecordingApproved: screenRecordingApproved && CGPreflightScreenCaptureAccess(),
            components: UIOnboardingInstallationInspector.componentHealth(
                installedMode: installedMode, modelPath: modelPath),
            servicesVerified: servicesVerified,
            failedHealthSource: failedHealthSource != nil,
            captureLive: captureIsLive())
    }

    nonisolated static func setupHealthy(
        installedMode: Bool, screenRecordingApproved: Bool, components: UIOnboardingComponentHealth,
        servicesVerified: Bool?, failedHealthSource: Bool, captureLive: Bool
    ) -> Bool {
        installedMode && screenRecordingApproved && components == .healthy
            && servicesVerified == true && !failedHealthSource && captureLive
    }

    private func checkRequiredServices(epoch: Int) {
        let expectedCaptureGeneration = captureGenerationEpoch
        serviceChecker.run { [weak self] result in
            if let self {
                // Recorded before the staleness guard: whatever this run was
                // for, it is still the newest answer about the two jobs.
                if case .success = result { self.servicesVerified = true } else { self.servicesVerified = false }
            }
            guard let self,
                self.verificationDeadlineActive,
                self.frameDeadlineEpoch == epoch,
                self.captureGenerationEpoch == expectedCaptureGeneration
            else { return }
            switch result {
            case .success:
                guard self.captureHealthy, self.captureIsLive() else {
                    self.captureFailed(
                        component: "Screen capture",
                        reason: "SentryScreen stopped receiving the screen before verification finished.")
                    return
                }
                self.failedHealthSource = nil
                if self.store.settings.readOnly {
                    // Verify protection, but never interpret or settle a
                    // pending request owned by a newer schema.
                    self.finishVerificationDeadline()
                    self.verification = .healthy
                    if let step = Self.standardHealthyPresentationStep(
                        isAdministrator: AdminCheck.isAdminSession().admin)
                    {
                        self.presentStep(step)
                    }
                    self.reportHealth(.protecting)
                    self.logHealthyCompletedLaunch()
                    if AdminCheck.isAdminSession().admin,
                        self.windowController.window?.isVisible == true
                    {
                        self.presentUpdateRequired(protectionPaused: false)
                    }
                    return
                }
                guard AdminCheck.isAdminSession().admin else {
                    self.finishVerificationDeadline()
                    self.verification = .healthy
                    if let step = Self.standardHealthyPresentationStep(
                        isAdministrator: false)
                    {
                        self.presentStep(step)
                    }
                    self.reportHealth(.protecting)
                    self.logHealthyCompletedLaunch()
                    return
                }
                if self.store.settings.onboarding.verificationPending {
                    self.completeHealthyVerification()
                } else {
                    self.finishVerificationDeadline()
                    self.verification = .healthy
                    self.reportHealth(.protecting)
                    self.logHealthyCompletedLaunch()
                    self.showPendingSuccessIfNeeded()
                }
            case let .failure(failure):
                self.finishVerificationDeadline()
                self.log("onboarding", failure.diagnostic)
                self.requiredServicesFailed(reason: failure.description)
            }
        }
    }

    private func requiredServicesFailed(reason: String, receipt: String? = nil) {
        failedHealthSource = .services
        failedComponent = "Required background service"
        failedDetail = Self.parentDetail(reason, receipt: receipt)
        verification = .failed(reason: reason)
        if let receipt, !receipt.isEmpty {
            log("onboarding", "required background service failed: \(reason) · \(receipt)")
        }
        let administrator = AdminCheck.isAdminSession().admin
        if administrator {
            settlePendingVerificationFailure()
        }
        presentHealthLoss(
            source: .services,
            component: failedComponent,
            detail: failedDetail)
        reportHealth(.lost(since: Date(), reason: reason))
        if !administrator {
            scheduleStandardRecovery(source: .services)
        }
    }

    private func startCaptureWithDeadline() -> LaunchDisposition {
        _ = armVerificationDeadline()
        return .startCapture
    }

    @discardableResult
    private func armVerificationDeadline() -> Int {
        if verificationDeadlineActive {
            return frameDeadlineEpoch
        }
        frameDeadlineEpoch += 1
        verificationDeadlineActive = true
        let epoch = frameDeadlineEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freshFrameDeadline) {
            [weak self] in
            guard let self,
                self.verificationDeadlineActive,
                self.frameDeadlineEpoch == epoch
            else { return }
            switch Self.deadlineOutcome(
                captureHealthy: self.captureHealthy,
                captureSuspended: self.captureIsSuspended())
            {
            case .deferred:
                // Re-arm for another full deadline: the clock only counts
                // time the capture could have delivered a frame. CaptureStream
                // already records the suspension edge. Logging every deadline
                // here duplicates that Receipt and grows agent.err for the
                // whole time another login session remains locked.
                self.finishVerificationDeadline()
                _ = self.armVerificationDeadline()
            case .servicesFailed:
                self.finishVerificationDeadline()
                self.requiredServicesFailed(
                    reason: "SentryScreen's background parts did not finish starting.",
                    receipt: "Required service verification did not finish within "
                        + "UIOnboardingRuntime.freshFrameDeadline="
                        + "\(Int(Self.freshFrameDeadline)) seconds. Check launchd service "
                        + "state before changing this limit.")
            case .captureFailed:
                self.captureFailed(
                    component: "Screen capture",
                    reason: "SentryScreen did not get a picture of this Mac's screen in time.",
                    receipt: "No valid screen frame arrived within "
                        + "UIOnboardingRuntime.freshFrameDeadline="
                        + "\(Int(Self.freshFrameDeadline)) seconds. Check Screen Recording "
                        + "and capture startup logs before changing this limit.")
            }
        }
        return epoch
    }

    private func finishVerificationDeadline() {
        verificationDeadlineActive = false
        frameDeadlineEpoch += 1
    }

    enum DeadlineOutcome: Equatable { case servicesFailed, captureFailed, deferred }

    /// What the fresh-frame deadline does when it fires. Pure so the selftest
    /// can pin it: a suspended capture with no frame yet is deferred, never
    /// failed (the only way a frame cannot arrive is that nobody is looking).
    /// Services are checked regardless of suspension — they do not need a frame.
    nonisolated static func deadlineOutcome(
        captureHealthy: Bool, captureSuspended: Bool
    ) -> DeadlineOutcome {
        if captureHealthy { return .servicesFailed }
        return captureSuspended ? .deferred : .captureFailed
    }

    func settingsDidChange() {
        settingsFileHealthDidChange()
        guard !settingsRepairRequired else { return }
        if store.settings.readOnly {
            // A newer schema owns settlement. Invalidate any current-schema
            // service callback before it can attempt a forbidden completion
            // write or replace the update-required surface.
            finishVerificationDeadline()
            retirePINRecoveryIfNeeded(
                reason: "parent settings require a newer app")
            if AdminCheck.isAdminSession().admin {
                presentUpdateRequired(protectionPaused: !protectionVerified)
            }
            if captureHealthy {
                verification = .checkingFreshProcess
                checkRequiredServices(epoch: armVerificationDeadline())
            }
            return
        }
        let current = store.settings.onboarding
        let shouldRestart = Self.waitingSessionNeedsRestart(
            awaitingMachineWideOnboarding: awaitingMachineWideOnboarding,
            previousCompletedAt: previousCompletedAt,
            previousVerificationPending: previousVerificationPending,
            current: current,
            localVerificationTransactionInProgress: localVerificationTransactionInProgress)
        previousCompletedAt = current.completedAt
        previousVerificationPending = current.verificationPending
        if shouldRestart, !restartIssued {
            restartIssued = true
            log("onboarding", "machine-wide onboarding settled; waiting session exiting 7 once")
            DispatchQueue.main.async { [restartForVerification] in restartForVerification() }
            return
        }
        // Recovery owns the dedicated window until it finishes or cancels.
        // The atomic PIN write notifies this store synchronously; normal
        // onboarding projection must not dismiss the recovery result first.
        guard recoveryOrigin == nil else { return }
        guard windowController.window?.isVisible == true else { return }
        presentCurrentStep()
    }

    func settingsFileHealthDidChange() {
        if installedMode, store.fileHealth != .readable {
            guard !settingsRepairRequired else { return }
            let reason = store.fileHealth.repairDetail
            settingsRepairRequired = true
            finishVerificationDeadline()
            failedHealthSource = .settings
            failedComponent = "Parent settings"
            failedDetail = reason
            log("onboarding", "installed parent settings became unavailable: \(reason)")
            if AdminCheck.isAdminSession().admin {
                presentHealthLoss(
                    source: .settings,
                    component: "Parent settings",
                    detail: reason)
            } else {
                presentStandardRepairFailure(
                    source: .settings,
                    component: failedComponent,
                    detail: failedDetail)
            }
            reportHealth(.lost(since: Date(), reason: reason))
            return
        }
        if settingsRepairRequired, store.fileHealth == .readable {
            settingsRepairRequired = false
            failedHealthSource = nil
            log("onboarding", "installed parent settings are readable again")
            if AdminCheck.isAdminSession().admin {
                if store.settings.readOnly {
                    finishVerificationDeadline()
                    presentUpdateRequired(protectionPaused: !protectionVerified)
                } else {
                    presentCurrentStep()
                }
            }
            if captureHealthy {
                verification = .checkingFreshProcess
                checkRequiredServices(epoch: armVerificationDeadline())
            } else if screenRecordingApproved {
                retryCaptureStartup()
            }
        }
    }

    nonisolated static func waitingSessionNeedsRestart(
        awaitingMachineWideOnboarding: Bool,
        previousCompletedAt: Date?,
        previousVerificationPending: Bool,
        current: UIOnboardingRecord,
        localVerificationTransactionInProgress: Bool = false
    ) -> Bool {
        guard !localVerificationTransactionInProgress,
            awaitingMachineWideOnboarding,
            current.completedAt != nil
        else { return false }
        return previousCompletedAt == nil
            || (previousVerificationPending && !current.verificationPending)
    }

    private func waitForMachineWideOnboarding(
        showCaptureLoss: Bool
    ) -> LaunchDisposition {
        awaitingMachineWideOnboarding = true
        return .waitForParent(showCaptureLoss: showCaptureLoss)
    }

    nonisolated static func standardSessionShouldSchedulePassiveRecovery(
        isAdministrator: Bool,
        alreadyScheduled: Bool
    ) -> Bool {
        !isAdministrator && !alreadyScheduled
    }

    /// The launch disposition for a session that is not an administrator,
    /// isolated from `start`'s side effects so the table is pinned by
    /// `--onboarding-selftest`.
    ///
    /// Protection fails toward capture. A Standard session owns no parent
    /// controls and cannot settle a machine-wide verification request, but
    /// macOS Screen Recording approval is the only thing the capture pipeline
    /// needs. So approval alone starts capture; the parent-required step is
    /// still presented on top of a running pipeline whenever onboarding is
    /// unfinished.
    ///
    /// A legacy install (`schemaVersion` 0, parent PIN set,
    /// `onboarding.completedAt == nil`) enters here as `completed == false`.
    /// Before 2026-08-28 that row returned `.waitForParent` with no capture
    /// and `showCaptureLoss: false`, so the machine ran unprotected with no
    /// banner. That row now starts capture.
    ///
    /// Disclosed residue of that change: `start` routes a `.startCapture`
    /// disposition through `startCaptureWithDeadline()`, never through
    /// `waitForMachineWideOnboarding()`, so `awaitingMachineWideOnboarding`
    /// stays false for the incomplete-plus-approved row and the bounded
    /// one-shot restart in `settingsDidChange` ("machine-wide onboarding
    /// settled; waiting session exiting 7 once") no longer fires for it. Since
    /// 2026-08-28 that restart is armed only for a session that is actually
    /// waiting, which requires that Screen Recording is not yet approved
    /// (other waiting rows — unsupported host, unhealthy components — return
    /// `.waitForParent` without arming it either). This is not a protection
    /// regression: capture is already running, and `settingsDidChange` still
    /// falls through to `presentCurrentStep()`, so the surface re-projects
    /// against the settled record rather than going stale. What the row loses
    /// is the fresh-process re-run of the launch path: no second evaluation of
    /// `start`, and `logHealthyCompletedLaunch` keeps
    /// `source=onboarding-incomplete-launch` for the life of the process
    /// instead of flipping to `source=completed-launch`.
    nonisolated static func standardSessionLaunch(
        completed: Bool,
        screenRecordingApproved: Bool
    ) -> StandardSessionLaunch {
        guard screenRecordingApproved else {
            return StandardSessionLaunch(
                disposition: .waitForParent(showCaptureLoss: completed),
                // A completed Standard session gets the actionable capture-
                // loss banner only. The parent-administrator setup window
                // beside it repeated the same failure without a usable
                // control. Incomplete setup still needs that parent step.
                presentsParentStep: !completed)
        }
        // A completed child session has no parent-facing step to present.
        return StandardSessionLaunch(
            disposition: .startCapture, presentsParentStep: !completed)
    }

    func beginRecoveryFromParentControls() {
        guard AdminCheck.isAdminSession().admin else { return }
        guard !store.settings.readOnly else {
            presentUpdateRequired(protectionPaused: !protectionVerified)
            return
        }
        beginPINRecovery(origin: .parentControls)
    }

    func beginRepairFromParentControls() {
        guard AdminCheck.isAdminSession().admin else { return }
        guard !store.settings.readOnly else {
            presentUpdateRequired(protectionPaused: !protectionVerified)
            return
        }
        switch failedHealthSource {
        case .settings, .services, .components, .model:
            presentation.surface = .serviceFailure(
                component: failedComponent, detail: failedDetail)
            windowController.present()
        case .screenRecordingPermission:
            presentPermissionFailure(repair: true)
        case .capture, .none:
            presentation.surface = .serviceFailure(
                component: failedComponent, detail: failedDetail)
            windowController.present()
        }
    }

    /// The capture-loss banner is shared by administrator and Standard
    /// sessions, but their safe next action differs. An administrator arms
    /// the correlated fresh-process handoff and opens the macOS pane directly.
    /// A Standard user cannot write the machine-wide handoff record, so it
    /// receives the same direct pane and spotlight without a CGRequest prompt.
    /// Neither route asks for the parent PIN: macOS owns this permission.
    @MainActor func beginRepairFromCaptureLossBanner() {
        let isPermissionFailure: Bool
        if case .screenRecordingPermission = failedHealthSource {
            isPermissionFailure = true
        } else {
            isPermissionFailure = false
        }
        guard isPermissionFailure else {
            log(
                "onboarding",
                "capture-loss Fix kept component-specific repair source="
                    + "\(String(describing: failedHealthSource)) pid=\(getpid())")
            if AdminCheck.isAdminSession().admin {
                beginRepairFromParentControls()
            } else {
                presentStep(.parentAdministratorRequired)
            }
            return
        }

        if AdminCheck.isAdminSession().admin {
            if recoveryOrigin != nil {
                retirePINRecoveryIfNeeded(
                    reason: "permission repair was requested")
            }
            // Put the waiting window behind System Settings before the direct
            // route opens it. When the parent returns after choosing Later,
            // the one required confirmation remains available without an
            // extra PIN or an extra repair click.
            presentPermissionFailure(repair: true)
            openPermissionSettings()
            return
        }

        presentPermissionFailure(repair: true)
        openStandardPermissionSettings()
    }

    private func signals() -> UIOnboardingSignals {
        UIOnboardingSignals(
            activeAccountIsAdministrator: AdminCheck.isAdminSession().admin,
            hostSupport: UIOnboardingInstallationInspector.hostSupport(),
            componentHealth: componentHealth,
            screenRecordingApproved: screenRecordingApproved,
            verification: verification,
            welcomeAcknowledged: welcomeAcknowledged)
    }

    private func presentCurrentStep() {
        let step = coordinator.step(for: signals())
        presentStep(step)
    }

    /// Every step the setup window shows leaves a log line, so a harness (or a
    /// human reading agent.err) can pair what was on screen with what the state
    /// machine did. Before this the first two steps were invisible in the log
    /// (fresh-install run fi-keep-02, 2026-08-29: screenshots of step 1 had to
    /// come from a timer).
    private func presentStep(_ step: UIOnboardingStep) {
        guard Self.presentsWindow(for: step) else {
            log("onboarding", "step=\(step.stateID) not-presented pid=\(getpid())")
            _ = presentation.apply(step)
            windowController.dismiss()
            return
        }
        log("onboarding", "step=\(step.stateID) presented pid=\(getpid())")
        windowController.present(step)
    }

    private func presentPermissionFailure(
        repair: Bool, error: String? = nil, returnedFromSettings: Bool = false
    ) {
        let context: UIOnboardingPermissionContext = repair ? .repair : .initialSetup
        let reason = repair
            ? "SentryScreen is not enabled in Screen Recording. Open Screen Recording settings and turn it on."
            : "SentryScreen is not enabled in Screen Recording."
        if repair {
            failedHealthSource = .screenRecordingPermission
            failedComponent = "Screen Recording"
            failedDetail = reason
        }
        presentation.surface = Self.permissionFailureSurface(
            context: context,
            reason: returnedFromSettings ? UIOnboardingSurface.stillOffAfterSettings : reason,
            error: error)
        windowController.present()
    }

    private func presentStandardRepairFailure(
        source: FailedHealthSource,
        component: String,
        detail: String
    ) {
        presentHealthLoss(
            source: source,
            component: component,
            detail: detail)
    }

    private func presentHealthLoss(
        source: FailedHealthSource,
        component: String,
        detail: String
    ) {
        retirePINRecoveryIfNeeded(
            reason: "health loss source=\(String(describing: source))")
        presentation.surface = Self.healthLossSurface(
            source: source,
            isAdministrator: AdminCheck.isAdminSession().admin,
            component: component,
            detail: detail)
        windowController.present()
    }

    nonisolated static func permissionFailureSurface(
        context: UIOnboardingPermissionContext,
        reason: String,
        error: String?
    ) -> UIOnboardingSurface {
        .permissionMissing(
            context: context,
            reason: reason,
            error: error)
    }

    private func presentUpdateRequired(protectionPaused: Bool) {
        presentation.surface = .updateRequired(
            detail: "Install the latest SentryScreen before you change parent setup or settings.",
            protectionPaused: protectionPaused)
        windowController.present()
    }

    private func retirePINRecoveryIfNeeded(reason: String) {
        guard recoveryOrigin != nil else { return }
        recoveryEpoch += 1
        recovery.cancel()
        recoveryAuthorization = nil
        recoveryOrigin = nil
        log("onboarding", "PIN recovery cancelled: \(reason)")
    }

    private func beginFreshProcessHandoff() {
        guard !restartIssued else { return }
        do {
            let requestID = try coordinator.beginFreshProcessVerification()
            restartIssued = true
            verification = .waitingForReturn
            presentStep(.verifyingFreshProcess)
            log("onboarding", "handoff=requested requestID=\(requestID.uuidString) "
                + "oldPID=\(getpid()) oldStartedAt=\(Self.receiptTime(processStartedAt)) exit=7")
            DispatchQueue.main.async { [restartForVerification] in restartForVerification() }
        } catch {
            presentation.surface = .serviceFailure(
                component: "Fresh-process verification", detail: "\(error)")
            windowController.present()
        }
    }

    /// Standard accounts need the same fresh TCC evaluation, but they cannot
    /// write or settle the machine-wide onboarding transaction. The waiting
    /// state arms AppDelegate's Quit & Reopen exit, and this explicit return
    /// path requests the same single wrapper relaunch with no store mutation.
    private func beginLocalPermissionHandoff() {
        guard !restartIssued else { return }
        restartIssued = true
        verification = .waitingForReturn
        presentStep(.verifyingFreshProcess)
        log(
            "onboarding",
            "handoff=requested authority=standard-local oldPID=\(getpid()) "
                + "oldStartedAt=\(Self.receiptTime(processStartedAt)) exit=7")
        DispatchQueue.main.async { [restartForVerification] in restartForVerification() }
    }

    private func completeHealthyVerification() {
        guard let requestID = store.settings.onboarding.verificationRequestID else {
            presentation.surface = .serviceFailure(
                component: "Fresh-process verification",
                detail: UIOnboardingCoordinatorError.verificationNotPending.description)
            windowController.present()
            return
        }
        let observedAt = Date()
        let liveCapture = captureHealthy && captureIsLive()
        let receipt = UIOnboardingHealthReceipt(
            verificationRequestID: requestID,
            processStartedAt: processStartedAt,
            observedAt: observedAt,
            activeAccountIsAdministrator: AdminCheck.isAdminSession().admin,
            hostSupported: UIOnboardingInstallationInspector.hostSupport() == .supported,
            freshProcess: true,
            screenRecordingApproved: screenRecordingApproved && liveCapture,
            captureHealthy: liveCapture,
            requiredServicesHealthy: true)
        do {
            try coordinator.recordHealthyVerification(receipt)
            finishVerificationDeadline()
            verification = .healthy
            reportHealth(.protecting)
            log("onboarding", "handoff=verified requestID=\(requestID.uuidString) "
                + "newPID=\(getpid()) observedAt=\(Self.receiptTime(observedAt)); "
                + "completion Receipt persisted after first valid frame and healthy services")
            if Self.healthMayReplaceRecovery(recoveryInProgress: recoveryOrigin != nil) {
                presentStep(coordinator.step(for: signals()))
            }
        } catch {
            // Two administrator agents can verify the same machine-wide
            // request. The first durable completion is authoritative. A
            // second locally healthy process must not turn that success into
            // a false Completion Receipt failure.
            let settled = store.settings.onboarding
            if settled.completedAt != nil,
                !settled.verificationPending,
                captureHealthy,
                captureIsLive()
            {
                finishVerificationDeadline()
                verification = .healthy
                reportHealth(.protecting)
                log("onboarding", "completion Receipt was already persisted by another administrator session")
                showPendingSuccessIfNeeded()
                return
            }
            finishVerificationDeadline()
            verification = .failed(reason: "\(error)")
            if Self.healthMayReplaceRecovery(recoveryInProgress: recoveryOrigin != nil) {
                // the card read "Completion Receipt: <Swift error>".
                // "Receipt" is this repo's word for evidence behind a number,
                // not a parent's word for anything.
                presentation.surface = .serviceFailure(
                    component: "Finishing setup",
                    detail: Self.parentDetail(
                        "SentryScreen could not save that setup finished on this Mac.",
                        receipt: "\(error)"))
                windowController.present()
            }
        }
    }

    private func showPendingSuccessIfNeeded() {
        guard store.settings.onboarding.completedAt != nil else { return }
        verification = .healthy
        guard Self.healthMayReplaceRecovery(recoveryInProgress: recoveryOrigin != nil) else {
            return
        }
        presentStep(coordinator.step(for: signals()))
    }

    nonisolated static func healthMayReplaceRecovery(recoveryInProgress: Bool) -> Bool {
        !recoveryInProgress
    }

    /// The explicit System Settings handoff owns the next process transition.
    /// The older capture-loss poll must not retry the stale process or issue a
    /// second exit while the parent completes that handoff.
    var captureLossPollIsSuperseded: Bool {
        Self.captureLossPollIsSuperseded(verification: verification)
    }

    nonisolated static func captureLossPollIsSuperseded(
        verification: UIOnboardingVerificationStatus
    ) -> Bool {
        verification == .waitingForReturn
    }

    nonisolated static func standardPassiveRecoveryMayRun(
        verification: UIOnboardingVerificationStatus
    ) -> Bool {
        !captureLossPollIsSuperseded(verification: verification)
    }

    nonisolated static func protectionIsVerified(
        captureHealthy: Bool,
        captureLive: Bool,
        verification: UIOnboardingVerificationStatus
    ) -> Bool {
        captureHealthy && captureLive && verification == .healthy
    }

    nonisolated static func pinCallbackMayUpdateSurface(settingsReadOnly: Bool) -> Bool {
        !settingsReadOnly
    }

    private func handle(_ action: UIOnboardingAction) {
        switch action {
        case let .saveInitialPIN(pin):
            saveInitialPIN(pin)
        case .openScreenRecordingSettings:
            switch Self.permissionHandoffAuthority(
                isAdministrator: AdminCheck.isAdminSession().admin)
            {
            case .correlated:
                openPermissionSettings()
            case .local:
                openStandardPermissionSettings()
            }
        case .startSetup:
            startSetup()
        case .openDownloadPage:
            if !NSWorkspace.shared.open(UIOnboardingSurface.releasesURL) {
                log("onboarding", "FAILED to open \(UIOnboardingSurface.releasesURL.absoluteString)")
            }
        case .openScreenRecordingSettingsManually:
            let context: UIOnboardingPermissionContext
            if case let .awaitingScreenRecording(activeContext) = presentation.surface {
                context = activeContext
            } else {
                context = .initialSetup
            }
            let route = Self.screenRecordingPermissionRoute(
                context: context, manualFallback: true)
            let opened = performScreenRecordingPermissionRoute(route)
            log(
                "onboarding",
                "\(context == .repair ? "permission-repair" : "permission-setup") "
                    + "state=missing-row-fallback result=\(opened ? "helper" : "helper-failed") "
                    + "pid=\(getpid())")
            if !opened {
                presentSettingsOpenFailure(
                    context: context,
                    requestID: store.settings.onboarding.verificationRequestID)
            } else {
                presentation.armExpectedSettingsReturn()
            }
        case .returnedFromScreenRecordingSettings:
            log("onboarding", "returned from System Settings; waiting for parent confirmation")
        case .confirmScreenRecordingEnabled:
            // The explicit permission return must replace this process.
            // Same-process TCC state can remain stale.
            switch Self.permissionHandoffAuthority(
                isAdministrator: AdminCheck.isAdminSession().admin)
            {
            case .correlated:
                beginFreshProcessHandoff()
            case .local:
                beginLocalPermissionHandoff()
            }
        case .closeCompletion:
            do {
                try coordinator.markSuccessShown()
                log("onboarding", "confirmation=acknowledged pid=\(getpid())")
                windowController.dismiss()
            } catch {
                presentation.surface = .serviceFailure(
                    component: "Setup confirmation", detail: "\(error)")
            }
        case .retryServiceHealth:
            retryFailedHealthCheck()
        case .beginPINRecovery:
            beginPINRecovery(origin: .onboarding(coordinator.step(for: signals())))
        case .authenticatePINRecovery:
            authenticatePINRecovery()
        case let .saveRecoveredPIN(pin):
            saveRecoveredPIN(pin)
        case .finishPINRecovery:
            finishPINRecovery()
        case .cancelPINRecovery:
            cancelPINRecovery()
        case .dismissWindow:
            recovery.cancel()
            recoveryAuthorization = nil
        case .uninstall:
            onUninstall?()
        }
    }

    @discardableResult
    private func performScreenRecordingPermissionRoute(
        _ route: ScreenRecordingPermissionRoute
    ) -> Bool {
        switch route {
        case .nativeRequest:
            requestScreenRecording()
            return true
        case let .settings(guideMode, requestsRegistration):
            if requestsRegistration {
                requestScreenRecording()
            }
            return openScreenRecordingSettings(guideMode)
        }
    }

    private func presentSettingsOpenFailure(
        context: UIOnboardingPermissionContext,
        requestID: UUID?
    ) {
        var requestDisarmed = true
        if let requestID {
            localVerificationTransactionInProgress = true
            do {
                try coordinator.recordVerificationFailure(requestID: requestID)
            } catch {
                requestDisarmed = false
                log(
                    "onboarding",
                    "\(context == .repair ? "permission-repair" : "permission-setup") "
                        + "state=disarm-failed requestID=\(requestID.uuidString) pid=\(getpid())")
            }
            localVerificationTransactionInProgress = false
        }
        if requestDisarmed {
            verification = .failed(reason: "System Settings did not open.")
        }
        presentation.cancelExpectedSettingsReturn()
        presentation.surface = Self.settingsOpenFailureSurface(
            context: context, requestDisarmed: requestDisarmed)
        windowController.present()
    }

    private func completionWasPresented() {
        let number = windowController.visibleWindowNumber.map(String.init) ?? "none"
        let visible = windowController.window?.isVisible == true
        let key = windowController.window?.isKeyWindow == true
        log("onboarding", "confirmation=presented pid=\(getpid()) "
            + "window=\(number) visible=\(visible) key=\(key)")
    }

    nonisolated private static func receiptTime(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Welcome's Start: moves to the PIN step. Only from the Welcome surface, and
    /// not when settings are read-only (the same guard as the PIN save).
    private func startSetup() {
        guard case .welcome = presentation.surface else { return }
        guard Self.pinCallbackMayUpdateSurface(settingsReadOnly: store.settings.readOnly) else {
            presentUpdateRequired(protectionPaused: !protectionVerified)
            return
        }
        welcomeAcknowledged = true
        presentCurrentStep()
    }

    private func saveInitialPIN(_ pin: String) {
        guard AdminCheck.isAdminSession().admin else {
            presentStep(.parentAdministratorRequired)
            return
        }
        guard Self.pinCallbackMayUpdateSurface(settingsReadOnly: store.settings.readOnly) else {
            presentUpdateRequired(protectionPaused: !protectionVerified)
            return
        }
        presentation.surface = .createPIN(isSaving: true, error: nil)
        pinGate.setPin(pin, current: nil) { [weak self] error in
            guard let self else { return }
            guard Self.pinCallbackMayUpdateSurface(
                settingsReadOnly: self.store.settings.readOnly)
            else {
                self.presentUpdateRequired(protectionPaused: !self.protectionVerified)
                return
            }
            if let error {
                self.presentation.surface = .createPIN(isSaving: false, error: "\(error)")
                return
            }
            self.screenRecordingApproved = CGPreflightScreenCaptureAccess()
            if self.screenRecordingApproved {
                self.beginFreshProcessHandoff()
            } else {
                self.verification = .notStarted
                self.presentCurrentStep()
            }
        }
    }

    private func openPermissionSettings() {
        let repair = store.settings.onboarding.completedAt != nil
            || store.settings.onboarding.isLegacyMigrationPending
        let requestID: UUID
        do {
            requestID = try coordinator.beginFreshProcessVerification()
        } catch {
            presentation.cancelExpectedSettingsReturn()
            presentation.surface = .serviceFailure(
                component: "Fresh-process verification", detail: "\(error)")
            windowController.present()
            return
        }
        let context = repair ? "permission-repair" : "permission-setup"
        log(
            "onboarding",
            "\(context) state=armed requestID=\(requestID.uuidString) oldPID=\(getpid())")
        let permissionContext: UIOnboardingPermissionContext = repair ? .repair : .initialSetup
        let route = Self.screenRecordingPermissionRoute(
            context: permissionContext, manualFallback: false)
        if !repair {
            // Initial setup: the system prompt is the only dialog. Its own
            // "Open System Settings" lands on the Screen Recording pane, and
            // the request is what registers the app's row there (tcc-research
            // A1). Deep-linking as well stacked two dialogs (owner, 2026-08-29).
            // The waiting surface carries the manual route for the case where
            // macOS declines to prompt (post-reset, until reboot).
            _ = performScreenRecordingPermissionRoute(route)
            log(
                "onboarding",
                "\(context) state=settings-open-request result=system-prompt "
                    + "requestID=\(requestID.uuidString) pid=\(getpid())")
            presentation.armExpectedSettingsReturn()
            verification = .waitingForReturn
            _ = presentation.apply(.waitingForReturn)
            return
        }
        guard performScreenRecordingPermissionRoute(route) else {
            log(
                "onboarding",
                "\(context) state=settings-open-request result=failed "
                    + "requestID=\(requestID.uuidString) pid=\(getpid())")
            presentSettingsOpenFailure(
                context: repair ? .repair : .initialSetup,
                requestID: requestID)
            return
        }
        log(
            "onboarding",
            "\(context) state=settings-open-request result=accepted "
                + "requestID=\(requestID.uuidString) pid=\(getpid())")
        presentation.armExpectedSettingsReturn()
        verification = .waitingForReturn
        // The setup window is already visible. Update it in place after
        // opening System Settings; calling present() here would reactivate
        // SentryScreen and could look like an immediate settings return.
        presentation.surface = .awaitingScreenRecording(context: .repair)
    }

    /// Direct Screen Recording repair for a Standard account. This mirrors
    /// the visible administrator handoff but deliberately has no coordinator
    /// call, request ID, or settings write.
    private func openStandardPermissionSettings() {
        let route = Self.screenRecordingPermissionRoute(
            context: .repair, manualFallback: false)
        guard performScreenRecordingPermissionRoute(route) else {
            log(
                "onboarding",
                "permission-repair state=settings-open-request "
                    + "result=standard-local-failed pid=\(getpid())")
            presentSettingsOpenFailure(context: .repair, requestID: nil)
            return
        }
        log(
            "onboarding",
            "permission-repair state=settings-open-request "
                + "result=standard-local-accepted pid=\(getpid())")
        presentation.armExpectedSettingsReturn()
        verification = .waitingForReturn
        presentation.surface = .awaitingScreenRecording(context: .repair)
    }

    /// A macOS Quit & Reopen permission change can terminate the waiting
    /// process before it records a handoff request. This generic event records
    /// completed-install health facts only; it is not a causal repair Receipt.
    private func logHealthyCompletedLaunch() {
        // Since 2026-08-28 a Standard session with Screen Recording approved
        // also reaches this state on an unfinished install (legacy migration).
        // That launch is protected and must leave the same receipt; only the
        // source differs, so the log distinguishes the two instead of staying
        // silent about the population the fix added.
        let source = store.settings.onboarding.completedAt != nil
            ? "completed-launch" : "onboarding-incomplete-launch"
        log(
            "onboarding",
            "protection state=verified source=\(source) "
                + "capture=healthy services=healthy pid=\(getpid())")
    }

    private func retryFailedHealthCheck() {
        if store.settings.readOnly {
            presentUpdateRequired(protectionPaused: !protectionVerified)
            if failedHealthSource == .services, captureHealthy {
                verification = .checkingFreshProcess
                checkRequiredServices(epoch: armVerificationDeadline())
            } else if screenRecordingApproved,
                case .healthy = UIOnboardingInstallationInspector.componentHealth(
                    installedMode: installedMode, modelPath: modelPath)
            {
                retryCaptureStartup()
            }
            return
        }
        switch failedHealthSource {
        case .settings:
            store.refresh()
            settingsFileHealthDidChange()
            if settingsRepairRequired {
                presentation.surface = .serviceFailure(
                    component: failedComponent, detail: failedDetail)
                windowController.present()
            }
        case .services:
            if store.settings.onboarding.completedAt == nil,
                !store.settings.onboarding.verificationPending
            {
                beginFreshProcessHandoff()
            } else {
                verification = .checkingFreshProcess
                presentation.surface = .preparing(detail: "Checking required services…")
                checkRequiredServices(epoch: armVerificationDeadline())
            }
        case .screenRecordingPermission, .capture, .model:
            restartIssued = false
            beginFreshProcessHandoff()
        case .components, .none:
            componentHealth = UIOnboardingInstallationInspector.componentHealth(
                installedMode: installedMode, modelPath: modelPath)
            if case .healthy = componentHealth {
                failedHealthSource = nil
                screenRecordingApproved = CGPreflightScreenCaptureAccess()
                if screenRecordingApproved,
                    let pin = store.parentPIN,
                    UIPin.isUsableRecord(pin)
                {
                    beginFreshProcessHandoff()
                    return
                }
            } else {
                failedHealthSource = .components
            }
            presentCurrentStep()
        }
    }

    private func scheduleStandardRecovery(source: FailedHealthSource) {
        guard Self.standardSessionShouldSchedulePassiveRecovery(
            isAdministrator: AdminCheck.isAdminSession().admin,
            alreadyScheduled: passiveRecoveryScheduled)
        else { return }
        passiveRecoveryScheduled = true
        log("onboarding", "Standard-account health retry scheduled once in \(Int(Self.passiveRecoveryDelay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.passiveRecoveryDelay) {
            [weak self] in
            guard let self else { return }
            guard Self.standardPassiveRecoveryMayRun(
                verification: self.verification)
            else {
                self.log(
                    "onboarding",
                    "Standard-account passive retry skipped; explicit permission handoff owns relaunch")
                return
            }
            switch source {
            case .settings:
                self.store.refresh()
                self.settingsDidChange()
            case .services:
                self.checkRequiredServices(epoch: self.armVerificationDeadline())
            case .screenRecordingPermission, .capture, .components, .model:
                self.retryCaptureStartup()
            }
        }
    }

    private func settlePendingVerificationFailure() {
        guard let requestID = store.settings.onboarding.verificationRequestID else { return }
        do {
            try coordinator.recordVerificationFailure(requestID: requestID)
        } catch {
            log("onboarding", "could not settle failed verification request: \(error)")
        }
    }

    private func beginPINRecovery(origin: RecoveryOrigin) {
        guard !store.settings.readOnly else {
            presentUpdateRequired(protectionPaused: !protectionVerified)
            return
        }
        recovery.cancel()
        recoveryAuthorization = nil
        recoveryEpoch += 1
        recoveryOrigin = origin
        presentation.surface = .recoveryAuthentication(isAuthenticating: false, error: nil)
        windowController.present()
    }

    private func authenticatePINRecovery() {
        let operationEpoch = recoveryEpoch
        presentation.surface = .recoveryAuthentication(isAuthenticating: true, error: nil)
        recovery.authenticate { [weak self] result in
            guard let self, self.recoveryEpoch == operationEpoch else { return }
            switch result {
            case let .success(authorization):
                self.recoveryAuthorization = authorization
                self.presentation.surface = .recoveryNewPIN(isSaving: false, error: nil)
            case let .failure(error):
                self.recoveryAuthorization = nil
                self.presentation.surface = .recoveryAuthentication(
                    isAuthenticating: false, error: error.description)
            }
        }
    }

    private func saveRecoveredPIN(_ pin: String) {
        guard let authorization = recoveryAuthorization else {
            presentation.surface = .recoveryAuthentication(
                isAuthenticating: false,
                error: UIPinRecoveryError.authorizationRequired.description)
            return
        }
        presentation.surface = .recoveryNewPIN(isSaving: true, error: nil)
        let operationEpoch = recoveryEpoch
        recovery.replacePin(pin, confirmation: pin, authorization: authorization) {
            [weak self] result in
            guard let self, self.recoveryEpoch == operationEpoch else { return }
            self.recoveryAuthorization = nil
            switch result {
            case .success:
                self.presentation.surface = .recoveryComplete
                self.windowController.present()
            case let .failure(error):
                self.presentation.surface = .recoveryNewPIN(
                    isSaving: false, error: error.description)
            }
        }
    }

    private func cancelPINRecovery() {
        recoveryEpoch += 1
        recovery.cancel()
        recoveryAuthorization = nil
        switch recoveryOrigin {
        case .parentControls, .none:
            windowController.dismiss()
        case let .onboarding(step):
            presentStep(step)
        }
        recoveryOrigin = nil
    }

    private func pinRecoveryWasRevokedForSessionLifecycle() {
        guard recoveryOrigin != nil else { return }
        recoveryEpoch += 1
        recoveryAuthorization = nil
        // The published update is enough for the already-visible recovery
        // window. Do not activate the app while the display sleeps or the
        // active user session changes.
        presentation.surface = Self.recoveryLifecycleRevocationSurface
    }

    private func finishPINRecovery() {
        recoveryEpoch += 1
        recovery.cancel()
        recoveryAuthorization = nil
        let origin = recoveryOrigin
        recoveryOrigin = nil
        switch origin {
        case .parentControls, .none:
            windowController.dismiss()
        case .onboarding(.permissionRepair):
            presentPermissionFailure(repair: true)
        case .onboarding(.pinRecoveryRequired):
            screenRecordingApproved = CGPreflightScreenCaptureAccess()
            if screenRecordingApproved {
                beginFreshProcessHandoff()
            } else {
                presentCurrentStep()
            }
        case .onboarding:
            presentCurrentStep()
        }
    }
}
