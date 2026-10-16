import Foundation

// `--onboarding-selftest`: executable domain checks with no XCTest, model,
// capture, UI, subprocess, or production-state dependency. Every store uses a
// private directory below one temporary root and is removed when the run ends.
@MainActor
enum UIOnboardingSelfTest {
    private static var passed = 0
    private static var failed = 0

    /// Receipt: UIPin documents about 0.1 s for one production derivation.
    /// The slowest case waits for two asynchronous derivations. Five seconds
    /// is a hang tripwire, not a normal operating delay.
    private static let asyncWaitSecs: TimeInterval = 5

    static func run() -> Int32 {
        passed = 0
        failed = 0

        let base = NSTemporaryDirectory()
            + "sentry-onboarding-selftest-\(getpid())-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(
                atPath: base, withIntermediateDirectories: true)
        } catch {
            print("not ok - onboarding selftest: create isolated state root")
            print("       \(error)")
            return 1
        }
        print("# onboarding state dir \(base)")
        defer { try? FileManager.default.removeItem(atPath: base) }

        caseLegacyMigration(base + "/legacy")
        caseFutureSchemaReadOnly(base + "/future-schema")
        caseFutureTopLevelReadOnly(base + "/future-settings")
        casePINRequiredBeforeVerification(base + "/pin-required")
        caseCorrelatedFreshProcess(base + "/correlation")
        caseHealthyCompletionAndOneTimeSuccess(base + "/completion")
        caseCompletedRepairVerification(base + "/completed-repair")
        caseIncompleteHealthRejected(base + "/incomplete")
        caseFailureClearsRequest(base + "/failure")
        caseAccountAndHostSteps(base + "/steps")
        caseStandardSessionRestartGate()
        caseStandardSessionLaunchDisposition()
        caseConfiguredModelComponent(base + "/model-component")
        caseLaunchctlTimeoutTripwire()
        caseRecoveryCancellation(base + "/recovery-cancel")
        caseRecoveryLifecycleRevocation(base + "/recovery-lifecycle")
        caseRecoveryFailure(base + "/recovery-failure")
        caseRecoverySuccess(base + "/recovery-success")
        caseStaleInFlightPINWork(base + "/stale-pin-work")
        caseWelcomeStep(base + "/welcome")

        print("ONBOARDING SELFTEST: \(passed)/\(passed + failed) PASS")
        return failed == 0 ? 0 : 1
    }

    // MARK: - Onboarding state

    private static func caseLegacyMigration(_ dir: String) {
        let record = testRecord(seed: 0x11)
        makeDirectory(dir)
        writeLegacySettings(record, to: dir + "/" + UISettingsStore.fileName)
        let store = makeStore(dir)

        check("onboarding: exposed legacy verifier is not migrated",
            store.parentPIN == nil && store.settings.onboarding == .fresh)

        let clock = Clock(Date(timeIntervalSince1970: 2_000_000_000))
        let coordinator = UIOnboardingCoordinator(store: store, now: { clock.value })
        let repairStep = coordinator.step(for: healthySignals(
            screenRecordingApproved: true, verification: .notStarted))
        check("onboarding: exposed legacy verifier requires a new protected PIN", {
            guard case .createPIN = repairStep else { return false }
            return true
        }(), "step=\(repairStep)")

        try! store.parentPINAuthority.mutate { $0.pin = record }

        let requestID = requireRequest(coordinator, name: "legacy migration")
        guard let requestID else { return }
        clock.value = clock.value.addingTimeInterval(2)
        do {
            try coordinator.recordHealthyVerification(healthyReceipt(
                requestID: requestID,
                processStartedAt: clock.value.addingTimeInterval(-1),
                observedAt: clock.value))
        } catch {
            check("onboarding: healthy receipt promotes legacy state", false, "\(error)")
            return
        }
        check("onboarding: healthy receipt completes after the new protected PIN",
            store.settings.onboarding.schemaVersion == UIOnboardingRecord.currentSchemaVersion
                && store.settings.onboarding.completedAt == clock.value
                && !store.settings.onboarding.verificationPending)
    }

    private static func caseFutureSchemaReadOnly(_ dir: String) {
        makeDirectory(dir)
        let futureSchema = UIOnboardingRecord.currentSchemaVersion + 1
        let object: [String: Any] = [
            "version": UISettings.currentVersion,
            "showMenuBarIcon": true,
            "onboarding": [
                "schemaVersion": futureSchema,
                // A future schema can remove or change every current field.
                "futureOnly": ["contract": "preserve without current validation"],
                "verificationPending": "not a current-schema bool",
            ],
        ]
        let path = dir + "/" + UISettingsStore.fileName
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0a)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            check("onboarding: future schema fixture is written", false, "\(error)")
            return
        }

        let before = fileBytes(path)
        let store = makeStore(dir)
        check("onboarding: future schema decodes before current fields",
            store.settings.onboarding.schemaVersion == futureSchema
                && store.settings.onboarding.readOnly
                && store.settings.readOnly)

        let error = caught { try store.mutate { $0.showMenuBarIcon = false } }
        check("onboarding: future schema refuses mutation without overwrite",
            error is UISettingsWriteError
                && store.settings.showMenuBarIcon
                && fileBytes(path) == before,
            "error=\(String(describing: error))")
    }

    private static func caseFutureTopLevelReadOnly(_ dir: String) {
        makeDirectory(dir)
        let futureVersion = UISettings.currentVersion + 1
        let object: [String: Any] = [
            "version": futureVersion,
            "showMenuBarIcon": true,
        ]
        let path = dir + "/" + UISettingsStore.fileName
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0a)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            check("onboarding: future settings fixture is written", false, "\(error)")
            return
        }

        let before = fileBytes(path)
        let store = makeStore(dir)
        check("onboarding: future top-level version is read-only",
            store.settings.version == futureVersion
                && store.settings.readOnly
                && store.settings.onboarding.completedAt == nil)

        let error = caught { try store.mutate { $0.showMenuBarIcon = false } }
        check("onboarding: future top-level version refuses setup mutation",
            error is UISettingsWriteError
                && store.settings.showMenuBarIcon
                && fileBytes(path) == before,
            "error=\(String(describing: error))")
    }

    private static func casePINRequiredBeforeVerification(_ dir: String) {
        let store = freshStore(dir)
        let coordinator = UIOnboardingCoordinator(store: store)
        let error = caught { _ = try coordinator.beginFreshProcessVerification() }
        check("onboarding: PIN is required before verification",
            isCoordinatorError(error, matching: { if case .pinRequired = $0 { true } else { false } }),
            "error=\(String(describing: error))")
        check("onboarding: refused verification leaves no pending request",
            !store.settings.onboarding.verificationPending
                && store.settings.onboarding.verificationRequestID == nil
                && store.settings.onboarding.verificationStartedAt == nil)
    }

    private static func caseCorrelatedFreshProcess(_ dir: String) {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_100_000))
        let store = storeWithPIN(dir, record: testRecord(seed: 0x21))
        let coordinator = UIOnboardingCoordinator(store: store, now: { clock.value })
        let requestID = requireRequest(coordinator, name: "correlation")
        guard let requestID else { return }

        let duplicate = try? coordinator.beginFreshProcessVerification()
        check("onboarding: one pending handoff keeps one request ID",
            duplicate == requestID
                && store.settings.onboarding.verificationRequestID == requestID
                && store.settings.onboarding.verificationStartedAt == clock.value)

        clock.value = clock.value.addingTimeInterval(3)
        let mismatch = caught {
            try coordinator.recordHealthyVerification(healthyReceipt(
                requestID: UUID(),
                processStartedAt: clock.value.addingTimeInterval(-1),
                observedAt: clock.value))
        }
        check("onboarding: stale request ID is rejected",
            isCoordinatorError(mismatch, matching: {
                if case .verificationRequestMismatch = $0 { true } else { false }
            }), "error=\(String(describing: mismatch))")
        check("onboarding: stale receipt cannot settle the active request",
            store.settings.onboarding.verificationPending
                && store.settings.onboarding.verificationRequestID == requestID
                && store.settings.onboarding.completedAt == nil)

        let predates = caught {
            try coordinator.recordHealthyVerification(healthyReceipt(
                requestID: requestID,
                processStartedAt: Date(timeIntervalSince1970: 2_000_099_999),
                observedAt: clock.value))
        }
        check("onboarding: process that predates the handoff is rejected",
            isCoordinatorError(predates, matching: {
                if case .processPredatesVerification = $0 { true } else { false }
            }), "error=\(String(describing: predates))")
    }

    private static func caseHealthyCompletionAndOneTimeSuccess(_ dir: String) {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_200_000))
        let store = storeWithPIN(dir, record: testRecord(seed: 0x31))
        let coordinator = UIOnboardingCoordinator(store: store, now: { clock.value })
        let requestID = requireRequest(coordinator, name: "completion")
        guard let requestID else { return }

        let processStart = clock.value.addingTimeInterval(1)
        clock.value = clock.value.addingTimeInterval(2)
        do {
            try coordinator.recordHealthyVerification(healthyReceipt(
                requestID: requestID,
                processStartedAt: processStart,
                observedAt: clock.value))
        } catch {
            check("onboarding: complete health receipt finishes setup", false, "\(error)")
            return
        }
        check("onboarding: complete health receipt finishes setup",
            store.settings.onboarding.completedAt == clock.value
                && !store.settings.onboarding.verificationPending
                && store.settings.onboarding.verificationRequestID == nil
                && store.settings.onboarding.verificationStartedAt == nil)
        let successStep = coordinator.step(for: healthySignals(
            screenRecordingApproved: true, verification: .healthy))
        check("onboarding: completed setup requests one confirmation",
            successStep == .protectionOn(showConfirmation: true), "step=\(successStep)")

        clock.value = clock.value.addingTimeInterval(1)
        do {
            try coordinator.markSuccessShown()
        } catch {
            check("onboarding: success confirmation is recorded", false, "\(error)")
            return
        }
        let firstShownAt = store.settings.onboarding.successShownAt
        clock.value = clock.value.addingTimeInterval(60)
        let secondError = caught { try coordinator.markSuccessShown() }
        check("onboarding: success confirmation is recorded once",
            secondError == nil
                && firstShownAt != nil
                && store.settings.onboarding.successShownAt == firstShownAt
                && coordinator.step(for: healthySignals(
                    screenRecordingApproved: true,
                    verification: .healthy)) == .protectionOn(showConfirmation: false),
            "error=\(String(describing: secondError))")
    }

    private static func caseCompletedRepairVerification(_ dir: String) {
        let completedAt = Date(timeIntervalSince1970: 2_000_250_000)
        let clock = Clock(completedAt.addingTimeInterval(60))
        let store = storeWithPIN(dir, record: testRecord(seed: 0x39))
        try! store.mutate { settings in
            settings.onboarding.schemaVersion = UIOnboardingRecord.currentSchemaVersion
            settings.onboarding.completedAt = completedAt
            settings.onboarding.successShownAt = completedAt.addingTimeInterval(1)
        }
        let coordinator = UIOnboardingCoordinator(store: store, now: { clock.value })

        let cancelledRequest = requireRequest(coordinator, name: "completed repair cancel")
        guard let cancelledRequest else { return }
        check("onboarding: completed repair arms a correlated verification request",
            store.settings.onboarding.verificationPending
                && store.settings.onboarding.verificationRequestID == cancelledRequest
                && store.settings.onboarding.completedAt == completedAt)
        let failure = caught {
            try coordinator.recordVerificationFailure(requestID: cancelledRequest)
        }
        check("onboarding: failed settings launch disarms repair without reopening setup",
            failure == nil
                && !store.settings.onboarding.verificationPending
                && store.settings.onboarding.completedAt == completedAt,
            "error=\(String(describing: failure))")

        clock.value = clock.value.addingTimeInterval(10)
        let repairRequest = requireRequest(coordinator, name: "completed repair recovery")
        guard let repairRequest else { return }
        let processStartedAt = clock.value.addingTimeInterval(1)
        clock.value = clock.value.addingTimeInterval(2)
        let recovery = caught {
            try coordinator.recordHealthyVerification(healthyReceipt(
                requestID: repairRequest,
                processStartedAt: processStartedAt,
                observedAt: clock.value))
        }
        check("onboarding: healthy repair settles the request and preserves first completion",
            recovery == nil
                && !store.settings.onboarding.verificationPending
                && store.settings.onboarding.verificationRequestID == nil
                && store.settings.onboarding.completedAt == completedAt
                && store.settings.onboarding.successShownAt == completedAt.addingTimeInterval(1),
            "error=\(String(describing: recovery))")
    }

    private static func caseIncompleteHealthRejected(_ dir: String) {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_300_000))
        let store = storeWithPIN(dir, record: testRecord(seed: 0x41))
        let coordinator = UIOnboardingCoordinator(store: store, now: { clock.value })
        let requestID = requireRequest(coordinator, name: "incomplete health")
        guard let requestID else { return }
        clock.value = clock.value.addingTimeInterval(2)
        var receipt = healthyReceipt(
            requestID: requestID,
            processStartedAt: clock.value.addingTimeInterval(-1),
            observedAt: clock.value)
        receipt.captureHealthy = false
        receipt.requiredServicesHealthy = false
        let error = caught { try coordinator.recordHealthyVerification(receipt) }
        check("onboarding: incomplete health receipt is rejected",
            isCoordinatorError(error, matching: {
                guard case let .incompleteHealthReceipt(failures) = $0 else { return false }
                return failures.contains("healthy capture")
                    && failures.contains("required service health")
            }), "error=\(String(describing: error))")
        check("onboarding: incomplete health does not create completion",
            store.settings.onboarding.completedAt == nil
                && store.settings.onboarding.verificationPending
                && store.settings.onboarding.verificationRequestID == requestID)
    }

    private static func caseFailureClearsRequest(_ dir: String) {
        let store = storeWithPIN(dir, record: testRecord(seed: 0x51))
        let coordinator = UIOnboardingCoordinator(store: store)
        let requestID = requireRequest(coordinator, name: "failure")
        guard let requestID else { return }
        let error = caught { try coordinator.recordVerificationFailure(requestID: requestID) }
        check("onboarding: settled failure clears the pending request",
            error == nil
                && !store.settings.onboarding.verificationPending
                && store.settings.onboarding.verificationRequestID == nil
                && store.settings.onboarding.verificationStartedAt == nil
                && store.settings.onboarding.completedAt == nil,
            "error=\(String(describing: error))")
    }

    private static func caseAccountAndHostSteps(_ dir: String) {
        let store = storeWithPIN(dir, record: testRecord(seed: 0x61))
        let coordinator = UIOnboardingCoordinator(store: store)
        var signals = healthySignals(
            screenRecordingApproved: false, verification: .notStarted)
        signals.activeAccountIsAdministrator = false
        check("onboarding: standard account requires a parent administrator",
            coordinator.step(for: signals) == .parentAdministratorRequired)

        // Owner 2026-09-07 (gap list): the wizard never said the child's
        // account has to be a Standard one, and the first account on a Mac is
        // an administrator — one who can reset the parent PIN with their own
        // password and remove the app.
        check("onboarding: O8 states the Standard-account requirement and why",
            UIOnboardingSurface.standardAccountRequirement
                == "Your child's account must be a Standard account. "
                    + "An administrator account can turn SentryScreen off.",
            UIOnboardingSurface.standardAccountRequirement)
        let scripted = ["Alex Rivera", "Sam Chen"]
        let warning = UIOnboardingSurface.standardAccountAdmins(scripted)
        check("onboarding: the O8 warning names every administrator account and the repair",
            scripted.allSatisfy { warning.contains($0) }
                && warning.contains("Administrator accounts on this Mac")
                && warning.contains("Users & Groups"), warning)
        // The list rides on the surface, so the view stays pure and this can
        // be scripted; VoiceOver hears the requirement either way and the
        // names only when there are any.
        AdminAccounts.setCachedForTest(scripted)
        let withAdmins = UIOnboardingSurface(step: .parentAdministratorRequired)
        AdminAccounts.setCachedForTest([])
        let withoutAdmins = UIOnboardingSurface(step: .parentAdministratorRequired)
        AdminAccounts.setCachedForTest(nil)
        check("onboarding: O8 carries the administrator list from AdminAccounts",
            withAdmins == .parentAdministratorRequired(administrators: scripted)
                && withoutAdmins == .parentAdministratorRequired(administrators: []),
            "\(withAdmins) \(withoutAdmins)")
        check("onboarding: O8 speaks the requirement always and the names only when there are any",
            withAdmins.accessibilityAnnouncement?.contains(warning) == true
                && withoutAdmins.accessibilityAnnouncement?
                    .contains(UIOnboardingSurface.standardAccountRequirement) == true
                && withoutAdmins.accessibilityAnnouncement?
                    .contains("Administrator accounts on this Mac") == false,
            "\(String(describing: withoutAdmins.accessibilityAnnouncement))")
        // The real lookup, read-only: `root` is in the admin group on every
        // Mac and is never a family's account, so its absence is the receipt
        // that the system-account floor and the de-duplication both hold.
        let live = AdminAccounts.otherAdministrators()
        check("onboarding: the administrator lookup skips system accounts, sorted and unique",
            !live.contains("root") && !live.contains(where: \.isEmpty)
                && live == Array(Set(live)).sorted(), "\(live)")

        signals.hostSupport = .unsupported(required: "macOS 14 or later", observed: "macOS 13.6")
        check("onboarding: unsupported host reports required and observed versions",
            coordinator.step(for: signals)
                == .unsupportedHost(required: "macOS 14 or later", observed: "macOS 13.6"))
    }

    /// Owner 2026-09-07: the Setup window can be closed (red button, Cmd-W,
    /// Escape, the card's Close) ONLY while the menu-bar icon is shown —
    /// INVARIANT `UIOnboardingWindowController.closable`. Every surface is
    /// unclosable with the icon hidden (every first-run step: the status
    /// item exists only once onboarding completes); with it shown, the
    /// completion card and in-flight operations stay unclosable.
    private static func caseSetupWindowClose() {
        typealias W = UIOnboardingWindowController
        let all: [UIOnboardingSurface] = [
            .preparing(detail: "x"), .welcome, .createPIN(isSaving: false, error: nil), .createPIN(isSaving: true, error: nil),
            .allowScreenRecording, .awaitingScreenRecording(context: .initialSetup), .awaitingScreenRecording(context: .repair),
            .verifying(detail: "x"), .protectionOn(showConfirmation: true), .protectionOn(showConfirmation: false),
            .permissionMissing(context: .initialSetup, reason: "r", error: nil),
            .permissionMissing(context: .repair, reason: "r", error: nil),
            .serviceFailure(component: "c", detail: "d"), .administratorRepairRequired(component: "c", detail: "d"),
            .pinRecoveryRequired(reason: "r"), .updateRequired(detail: "d", protectionPaused: true),
            .parentAdministratorRequired(administrators: []), .parentAdministratorRequired(administrators: ["Alex Rivera"]),
            .unsupportedHost(required: "a", observed: "b"),
            .recoveryAuthentication(isAuthenticating: false, error: nil), .recoveryAuthentication(isAuthenticating: true, error: nil),
            .recoveryNewPIN(isSaving: false, error: nil), .recoveryNewPIN(isSaving: true, error: nil), .recoveryComplete,
        ]
        check("setup window close: with the menu-bar icon hidden NO surface is closable (the invariant, over every surface)",
            all.allSatisfy { !W.closable($0, menuBarIconVisible: false) })
        let never: [UIOnboardingSurface] = [
            .protectionOn(showConfirmation: true), .createPIN(isSaving: true, error: nil),
            .recoveryAuthentication(isAuthenticating: true, error: nil), .recoveryNewPIN(isSaving: true, error: nil),
            .preparing(detail: "x"), .verifying(detail: "x"),
        ]
        check("setup window close: icon shown ⇒ the completion card and in-flight operations still refuse",
            never.allSatisfy { !W.closable($0, menuBarIconVisible: true) })
        let holds: [UIOnboardingSurface] = [
            .permissionMissing(context: .repair, reason: "r", error: nil), .awaitingScreenRecording(context: .repair),
            .serviceFailure(component: "c", detail: "d"), .updateRequired(detail: "d", protectionPaused: true),
        ]
        check("setup window close: icon shown ⇒ every hold/repair surface closes",
            holds.allSatisfy { W.closable($0, menuBarIconVisible: true) })

        // Repair hides only the reason that repeats the title (review item 3);
        // any other cause stays on screen.
        typealias M = UIOnboardingPermissionMissingView
        check("repair reason: the Screen-Recording-off sentences are hidden in repair only",
            !M.showsReason("Screen Recording is off. A parent must turn it on to restore protection.", context: .repair)
                && !M.showsReason("SentryScreen is not enabled in Screen Recording.", context: .repair)
                && M.showsReason("SentryScreen is not enabled in Screen Recording.", context: .initialSetup))
        check("repair reason: any other cause is shown in repair",
            M.showsReason("System Settings did not open. Open Privacy & Security, then Screen Recording.", context: .repair)
                && M.showsReason("Capture stopped: the display went away.", context: .repair))

        // Live: the controller's red button, windowShouldClose and the
        // presentation's mirrored bit follow the same rule.
        let presentation = UIOnboardingPresentation(surface: .permissionMissing(context: .repair, reason: "r", error: nil))
        let controller = W(presentation: presentation)
        var icon = false
        controller.menuBarIconVisible = { icon }
        let window = controller.window!
        // syncWindowState is dispatched from the surface sink with one
        // DispatchQueue.main.async hop; one run-loop turn settles it. 50 ms
        // is ~3 display refreshes — far past one turn, and paid five times
        // here only.
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        controller.present()
        settle()
        let hiddenIcon = !controller.windowShouldClose(window) && window.isVisible
            && window.standardWindowButton(.closeButton)?.isEnabled == false && !presentation.closable
        icon = true
        presentation.surface = .awaitingScreenRecording(context: .repair)
        settle()
        let shownIcon = window.standardWindowButton(.closeButton)?.isEnabled == true && presentation.closable
            && controller.windowShouldClose(window)
        presentation.requestClose()  // the card's Close → performClose → windowShouldClose → close
        settle()
        let closedByCard = !window.isVisible
        controller.present()
        settle()
        let reopened = window.isVisible
        controller.cancelOperation(nil)  // Escape → the same route
        settle()
        let closedByEscape = !window.isVisible
        check("setup window close (live): icon hidden ⇒ red button off + windowShouldClose false; icon shown ⇒ on + true; the card's Close hides, present() reopens, Escape hides",
            hiddenIcon && shownIcon && closedByCard && reopened && closedByEscape,
            "hidden=\(hiddenIcon) shown=\(shownIcon) card=\(closedByCard) reopened=\(reopened) esc=\(closedByEscape)")
        controller.dismiss()
        check("setup window close: the demo mirrors production — repair-dress scenarios show the icon, initial-setup ones do not",
            UIOnboardingDemoScenario.repair.menuBarIconVisible
                && !UIOnboardingDemoScenario.complete.menuBarIconVisible
                && !UIOnboardingDemoScenario.pinLight.menuBarIconVisible)
    }

    /// `launchctl print` runs in a subprocess with no timeout before
    /// 2026-08-28; a wedged launchd would hang the service check forever. This
    /// pins the bounded wait against its measurement and against the total
    /// verification budget it must never exceed. `freshFrameDeadline` is a
    /// *shared* budget (capture start + first frame + this check), so fitting
    /// under it does not guarantee the main-actor completion is still accepted
    /// — the stderr tripwire in `launchdJobIsHealthy` is the channel that
    /// cannot be swallowed. See the `launchctlTimeout` receipt.
    private static func caseLaunchctlTimeoutTripwire() {
        // MEASURED Receipt: /bin/launchctl print returned in 3.6-6.7 ms across
        // 80 invocations on the installed M1 Mac on 2026-08-28.
        let measuredWorstCaseSecs = 0.0067
        check("onboarding services: the launchctl tripwire is far above the measured range",
            UIOnboardingServiceChecker.launchctlTimeout >= measuredWorstCaseSecs * 100,
            "limit=\(UIOnboardingServiceChecker.launchctlTimeout)s measured=\(measuredWorstCaseSecs)s")
        check("onboarding services: both bounded checks stay under the whole verification budget",
            UIOnboardingServiceChecker.launchctlTimeout * 2
                < UIOnboardingRuntime.freshFrameDeadline,
            "limit=\(UIOnboardingServiceChecker.launchctlTimeout)s "
                + "deadline=\(UIOnboardingRuntime.freshFrameDeadline)s")

        let record = UIOnboardingServiceChecker.launchctlTripwireRecord(
            ["system/com.sentryscreen.watchdog"])
        check("onboarding services: the tripwire record names budget, limit, value and fix",
            record.contains("tripwire=UIOnboardingServiceChecker.launchctlTimeout")
                && record.contains("limit=\(UIOnboardingServiceChecker.launchctlTimeout)s")
                && record.contains("observed=no-exit")
                && record.contains("system/com.sentryscreen.watchdog")
                && record.contains("UIOnboardingRuntime.swift"),
            record)
        check("onboarding services: a timeout is a distinct unhealthy outcome",
            UIOnboardingServiceChecker.JobHealth.timedOut
                != UIOnboardingServiceChecker.JobHealth.healthy
                && UIOnboardingServiceChecker.JobHealth.timedOut.rawValue == "timed-out")
    }

    /// The installed-component check must verify the detector the daemon will
    /// actually load. The daemon's model is a swappable file behind
    /// `--model` / `config.json`, and the shipped config points at the
    /// student package (`yolox_50ep_v8_ep50_fp16.mlpackage` since the
    /// 2026-09-01 swap, v5 before it); a hardcoded `640m.mlpackage` would
    /// report a healthy install as broken and would miss a genuinely absent
    /// configured model.
    private static func caseConfiguredModelComponent(_ dir: String) {
        makeDirectory(dir)
        let model = dir + "/yolox_50ep_v8_ep50_fp16.mlpackage"
        makeDirectory(model)

        let components = UIOnboardingInstallationInspector.requiredComponents(
            modelPath: model, supportRoot: dir)
        check("onboarding install: the detector component is the configured model path",
            components.contains { $0.name == "detector model" && $0.path == model },
            "\(components)")
        check("onboarding install: no component path is hardcoded to 640m.mlpackage",
            !components.contains { $0.path.contains("640m.mlpackage") },
            "\(components.map(\.path))")

        check("onboarding install: a present configured model is not reported missing",
            !UIOnboardingInstallationInspector.missingComponentPaths(
                installedMode: true, modelPath: model, supportRoot: dir).contains(model))

        let absent = dir + "/640m.mlpackage"
        let missing = UIOnboardingInstallationInspector.missingComponentPaths(
            installedMode: true, modelPath: absent, supportRoot: dir)
        check("onboarding install: an absent configured model is reported by its own path",
            missing.contains(absent), "\(missing)")
        let absentHealth = UIOnboardingInstallationInspector.componentHealth(
            installedMode: true, modelPath: absent, supportRoot: dir)
        check("onboarding install: an absent configured model is unhealthy", {
            guard case let .unhealthy(reason) = absentHealth else { return false }
            return reason.contains("detector model")
        }(), "\(absentHealth)")

        // A development agent runs from the repo tree and owns no installed
        // payload, so the whole check stays off.
        check("onboarding install: a development agent skips the installed-component check",
            UIOnboardingInstallationInspector.componentHealth(
                installedMode: false, modelPath: absent, supportRoot: dir) == .healthy
                && UIOnboardingInstallationInspector.missingComponentPaths(
                    installedMode: false, modelPath: absent, supportRoot: dir).isEmpty)

        let unconfigured = UIOnboardingInstallationInspector.componentHealth(
            installedMode: true, modelPath: "", supportRoot: dir)
        check("onboarding install: an unconfigured model path fails loudly",
            unconfigured == .unhealthy(
                reason: UIOnboardingInstallationInspector.unconfiguredModelReason),
            "\(unconfigured)")
    }

    /// Pins the whole non-administrator launch table. Protection fails toward
    /// capture: Screen Recording approval alone starts the pipeline, whatever
    /// the install state, because a Standard session can never finish the
    /// parent-facing onboarding that would otherwise gate it.
    private static func caseStandardSessionLaunchDisposition() {
        func launch(
            completed: Bool, approved: Bool
        ) -> UIOnboardingRuntime.StandardSessionLaunch {
            UIOnboardingRuntime.standardSessionLaunch(
                completed: completed, screenRecordingApproved: approved)
        }

        // The regression this case exists for. A legacy install
        // (schemaVersion 0, parent PIN set, completedAt nil) enters as
        // completed == false; before 2026-08-28 this row returned
        // .waitForParent(showCaptureLoss: false) — no capture and no banner.
        check("onboarding runtime: legacy install + Standard session + approved ⇒ capture starts",
            launch(completed: false, approved: true)
                == .init(disposition: .startCapture, presentsParentStep: true),
            "\(launch(completed: false, approved: true))")

        check("onboarding runtime: completed install + Standard session + approved ⇒ capture starts",
            launch(completed: true, approved: true)
                == .init(disposition: .startCapture, presentsParentStep: false),
            "\(launch(completed: true, approved: true))")

        check("onboarding runtime: completed install + Standard session + denied ⇒ capture-loss banner only",
            launch(completed: true, approved: false)
                == .init(
                    disposition: .waitForParent(showCaptureLoss: true),
                    presentsParentStep: false),
            "\(launch(completed: true, approved: false))")

        check("onboarding runtime: incomplete install + Standard session + denied ⇒ parent step only",
            launch(completed: false, approved: false)
                == .init(
                    disposition: .waitForParent(showCaptureLoss: false),
                    presentsParentStep: true),
            "\(launch(completed: false, approved: false))")

        check("onboarding runtime: Screen Recording approval alone decides the Standard capture start",
            [true, false].allSatisfy {
                launch(completed: $0, approved: true).disposition == .startCapture
                    && launch(completed: $0, approved: false).disposition != .startCapture
            })
    }

    private static func caseStandardSessionRestartGate() {
        let completedAt = Date(timeIntervalSince1970: 2_000_350_000)
        var completed = UIOnboardingRecord.fresh
        completed.completedAt = completedAt

        check("onboarding runtime: fresh setup completion restarts a waiting Standard session",
            UIOnboardingRuntime.waitingSessionNeedsRestart(
                awaitingMachineWideOnboarding: true,
                previousCompletedAt: nil,
                previousVerificationPending: true,
                current: completed))

        check("onboarding runtime: settled repair restarts a waiting Standard session",
            UIOnboardingRuntime.waitingSessionNeedsRestart(
                awaitingMachineWideOnboarding: true,
                previousCompletedAt: completedAt,
                previousVerificationPending: true,
                current: completed))

        let localDisarmNotificationsSuppressed = [1, 2].allSatisfy { _ in
            !UIOnboardingRuntime.waitingSessionNeedsRestart(
                awaitingMachineWideOnboarding: true,
                previousCompletedAt: completedAt,
                previousVerificationPending: true,
                current: completed,
                localVerificationTransactionInProgress: true)
        }
        check("onboarding runtime: local repair disarm suppresses all transaction notifications",
            localDisarmNotificationsSuppressed)

        check("onboarding runtime: fresh-frame deadline defers while capture is suspended, fails otherwise",
            UIOnboardingRuntime.deadlineOutcome(captureHealthy: false, captureSuspended: true) == .deferred
                && UIOnboardingRuntime.deadlineOutcome(captureHealthy: false, captureSuspended: false) == .captureFailed
                && UIOnboardingRuntime.deadlineOutcome(captureHealthy: true, captureSuspended: true) == .servicesFailed)
        check("onboarding runtime: System Settings handoff supersedes capture-loss polling",
            UIOnboardingRuntime.captureLossPollIsSuperseded(
                verification: .waitingForReturn))
        check("onboarding surface: waiting for the Screen Recording handoff carries the manual Settings route",
            UIOnboardingSurface(step: .waitingForReturn) == .awaitingScreenRecording(context: .initialSetup)
                && UIOnboardingSurface(step: .allowScreenRecording) == .allowScreenRecording
                && UIOnboardingSurface(step: .verifyingFreshProcess)
                    != .awaitingScreenRecording(context: .initialSetup))
        check("onboarding copy: Screen Recording shows the board's two instructions",
            UIOnboardingSurface.screenRecordingSteps.map(\.title)
                == ["Switch on SentryScreen.", "Choose Quit & Reopen."]
                && UIOnboardingSurface.notInTheList == "Not in the list?")
        check("onboarding rail: setup stages count two steps",
            [UIOnboardingSurface.createPIN(isSaving: false, error: nil), .allowScreenRecording,
                .awaitingScreenRecording(context: .initialSetup), .verifying(detail: "x")]
                .compactMap { UIOnboardingChrome(surface: $0).stage }
                .allSatisfy { $0.hasSuffix("of 2") })
        check("onboarding routing: the first Open System Settings raises only the native permission request",
            UIOnboardingRuntime.screenRecordingPermissionRoute(
                context: .initialSetup, manualFallback: false)
                == .nativeRequest)
        check("onboarding routing: initial manual fallback registers and shows the add helper",
            UIOnboardingRuntime.screenRecordingPermissionRoute(
                context: .initialSetup, manualFallback: true)
                == .settings(
                    guideMode: .spotlightWithAddHelper,
                    requestsRegistration: true))
        check("onboarding routing: normal repair opens spotlight-only Settings without a permission request",
            UIOnboardingRuntime.screenRecordingPermissionRoute(
                context: .repair, manualFallback: false)
                == .settings(
                    guideMode: .spotlight,
                    requestsRegistration: false))
        check("onboarding routing: administrator permission-only repair bypasses the parent PIN",
            UIOnboardingRuntime.permissionHandoffAuthority(isAdministrator: true)
                == .correlated
                && UIOnboardingRuntime.screenRecordingPermissionRoute(
                    context: .repair, manualFallback: false)
                    == .settings(
                        guideMode: .spotlight,
                        requestsRegistration: false))
        check("onboarding routing: Standard permission-only repair remains a direct Settings route",
            UIOnboardingRuntime.permissionHandoffAuthority(isAdministrator: false)
                == .local
                && UIOnboardingRuntime.screenRecordingPermissionRoute(
                    context: .repair, manualFallback: false)
                    == .settings(
                        guideMode: .spotlight,
                        requestsRegistration: false))
        check("onboarding routing: explicit missing-row repair registers and shows the add helper",
            UIOnboardingRuntime.screenRecordingPermissionRoute(
                context: .repair, manualFallback: true)
                == .settings(
                    guideMode: .spotlightWithAddHelper,
                    requestsRegistration: true))
        check("onboarding projection: capture permission loss stays on the direct repair surface",
            UIOnboardingRuntime.permissionFailureSurface(
                context: .repair,
                reason: "Screen Recording is off.",
                error: nil)
                == .permissionMissing(
                    context: .repair,
                    reason: "Screen Recording is off.",
                    error: nil))
        let permissionWait = UIOnboardingSurface.awaitingScreenRecording(
            context: .repair)
        let legacyPermissionRepair = UIOnboardingSurface(
            step: .permissionRepair(
                reason: "Screen Recording is off during legacy migration."))
        check("onboarding launch: legacy migration permission repair owns capture loss",
            UIOnboardingRuntime.launchPermissionRepairIsActive(
                completed: false,
                legacyMigrationPending: true,
                screenRecordingApproved: false)
                && !UIOnboardingRuntime.launchPermissionRepairIsActive(
                    completed: false,
                    legacyMigrationPending: false,
                    screenRecordingApproved: false)
                && !UIOnboardingRuntime.launchPermissionRepairIsActive(
                    completed: false,
                    legacyMigrationPending: true,
                    screenRecordingApproved: true)
                && UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                    legacyPermissionRepair,
                    windowVisible: true)
                && UIOnboardingRuntime.captureLossSurfaceIsOwned(
                    isAdministrator: true,
                    captureFailureIsActive: true,
                    repairSurfaceIsVisible: true))
        check("onboarding projection: a visible permission repair owns capture loss in either account",
            UIOnboardingRuntime.captureLossSurfaceIsOwned(
                isAdministrator: true,
                captureFailureIsActive: true,
                repairSurfaceIsVisible: true)
                && UIOnboardingRuntime.captureLossSurfaceIsOwned(
                    isAdministrator: false,
                    captureFailureIsActive: true,
                    repairSurfaceIsVisible: true)
                && !UIOnboardingRuntime.captureLossSurfaceIsOwned(
                    isAdministrator: true,
                    captureFailureIsActive: false,
                    repairSurfaceIsVisible: true)
                && !UIOnboardingRuntime.captureLossSurfaceIsOwned(
                    isAdministrator: true,
                    captureFailureIsActive: true,
                    repairSurfaceIsVisible: false))
        check("onboarding projection: the Standard permission wait replaces the fallback banner",
            UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                permissionWait, windowVisible: true)
                && !UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                    permissionWait, windowVisible: false)
                && !AppDelegate.captureLossBannerIsShown(
                    bannerMode: true,
                    runtimeOwnsCaptureLossSurface: true))
        let activeRecovery = UIOnboardingSurface.recoveryAuthentication(
            isAuthenticating: true,
            error: nil)
        let recoveryRacePresentation = UIOnboardingPresentation(
            surface: activeRecovery)
        recoveryRacePresentation.surface = UIOnboardingRuntime.healthLossSurface(
            source: .model,
            isAdministrator: true,
            component: "Detector model",
            detail: "The configured model could not load.")
        check("onboarding lifecycle: health loss replaces PIN recovery with the named failure",
            !UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                activeRecovery, windowVisible: true)
                && recoveryRacePresentation.surface == .serviceFailure(
                    component: "Detector model",
                    detail: "The configured model could not load.")
                && UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                    recoveryRacePresentation.surface,
                    windowVisible: true)
                && !AppDelegate.captureLossBannerIsShown(
                    bannerMode: true,
                    runtimeOwnsCaptureLossSurface: true))
        let classifiedSources: [UIOnboardingRuntime.FailedHealthSource] = [
            .settings, .components, .services,
            .screenRecordingPermission, .capture, .model,
        ]
        check("onboarding projection: every named runtime failure source is active banner state",
            classifiedSources.allSatisfy {
                UIOnboardingRuntime.captureLossSourceIsActive($0)
                    && UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                        UIOnboardingRuntime.healthLossSurface(
                            source: $0,
                            isAdministrator: true,
                            component: "Named component",
                            detail: "Named failure"),
                        windowVisible: true)
            } && !UIOnboardingRuntime.captureLossSourceIsActive(nil))
        let standardModelRepair = UIOnboardingRuntime.standardRepairSurface(
            source: .model,
            component: "Detector model",
            detail: "The configured model could not load.")
        let standardServiceRepair = UIOnboardingRuntime.standardRepairSurface(
            source: .services,
            component: "Required background service",
            detail: "The watchdog is not responding.")
        check("onboarding projection: Standard model and service failures use specific read-only repair",
            standardModelRepair == .administratorRepairRequired(
                component: "Detector model",
                detail: "The configured model could not load.")
                && standardServiceRepair == .administratorRepairRequired(
                    component: "Required background service",
                    detail: "The watchdog is not responding.")
                && UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                    standardModelRepair, windowVisible: true)
                && UIOnboardingRuntime.captureLossRepairSurfaceIsVisible(
                    standardServiceRepair, windowVisible: true))
        check("onboarding projection: completion suppresses competing success UI until Done",
            UIOnboardingRuntime.successConfirmationIsPending(
                completedAt: completedAt, successShownAt: nil)
                && !UIOnboardingRuntime.successConfirmationIsPending(
                    completedAt: nil, successShownAt: nil)
                && !UIOnboardingRuntime.successConfirmationIsPending(
                    completedAt: completedAt,
                    successShownAt: completedAt.addingTimeInterval(1)))
        let nonPermissionCaptureRepair = UIOnboardingStep.serviceRepair(
            reason: "The capture stream stopped while permission remained approved.")
        check("onboarding routing: non-permission capture loss stays in component-specific repair",
            UIOnboardingRuntime.captureLossUsesPermissionRepair(
                settingsRepairRequired: false, screenRecordingApproved: false)
                && !UIOnboardingRuntime.captureLossUsesPermissionRepair(
                    settingsRepairRequired: true, screenRecordingApproved: false)
                && !UIOnboardingRuntime.captureLossUsesPermissionRepair(
                    settingsRepairRequired: false, screenRecordingApproved: true)
                && UIOnboardingRuntime.presentsWindow(for: nonPermissionCaptureRepair)
                && UIOnboardingSurface(step: nonPermissionCaptureRepair)
                    == .serviceFailure(
                        component: "Required service",
                        detail: "The capture stream stopped while permission remained approved."))
        check("onboarding routing: Standard local permission handoff uses the exit-7 restart state",
            UIOnboardingRuntime.permissionHandoffAuthority(isAdministrator: false) == .local
                && UIOnboardingRuntime.captureLossPollIsSuperseded(
                    verification: .waitingForReturn)
                && !UIOnboardingRuntime.standardPassiveRecoveryMayRun(
                    verification: .waitingForReturn)
                && UIOnboardingRuntime.standardPassiveRecoveryMayRun(
                    verification: .failed(reason: "permission lost"))
                && AppDelegate.terminationExitCode(handoffArmed: true) == 7)
        let standardRecoveryPresentation = UIOnboardingPresentation(
            surface: .parentAdministratorRequired(administrators: []))
        standardRecoveryPresentation.surface = .preparing(detail: "Checking protection…")
        let standardHealthyStep = UIOnboardingRuntime.standardHealthyPresentationStep(
            isAdministrator: false)
        let standardHealthyKeepsWindow = standardHealthyStep.map {
            standardRecoveryPresentation.apply($0)
        }
        check("onboarding lifecycle: Standard repair surfaces retire after healthy services",
            standardHealthyStep == .protectionOn(showConfirmation: false)
                && standardHealthyKeepsWindow == false
                && standardRecoveryPresentation.surface
                    == .protectionOn(showConfirmation: false))
        check("app: quit AppleEvent exits 7 during an armed handoff, else 137 (wrapper relaunch); never 0",
            AppDelegate.terminationExitCode(handoffArmed: true) == 7
                && AppDelegate.terminationExitCode(handoffArmed: false) == 137)
        check("onboarding runtime: other verification states retain capture-loss recovery",
            !UIOnboardingRuntime.captureLossPollIsSuperseded(verification: .notStarted)
                && !UIOnboardingRuntime.captureLossPollIsSuperseded(
                    verification: .checkingFreshProcess)
                && !UIOnboardingRuntime.captureLossPollIsSuperseded(
                    verification: .failed(reason: "test")))

        var unrelated = completed
        unrelated.successShownAt = completedAt.addingTimeInterval(1)
        check("onboarding runtime: unrelated completed-state change does not restart",
            !UIOnboardingRuntime.waitingSessionNeedsRestart(
                awaitingMachineWideOnboarding: true,
                previousCompletedAt: completedAt,
                previousVerificationPending: false,
                current: unrelated))

        check("onboarding runtime: session that is not waiting does not restart",
            !UIOnboardingRuntime.waitingSessionNeedsRestart(
                awaitingMachineWideOnboarding: false,
                previousCompletedAt: nil,
                previousVerificationPending: true,
                current: completed))

        var stillPending = completed
        stillPending.verificationPending = true
        check("onboarding runtime: pending repair that has not settled does not restart",
            !UIOnboardingRuntime.waitingSessionNeedsRestart(
                awaitingMachineWideOnboarding: true,
                previousCompletedAt: completedAt,
                previousVerificationPending: true,
                current: stillPending))

        check("onboarding runtime: second administrator restarts after peer completion",
            UIOnboardingRuntime.waitingSessionNeedsRestart(
                awaitingMachineWideOnboarding: true,
                previousCompletedAt: nil,
                previousVerificationPending: true,
                current: completed))

        check("onboarding runtime: Standard health failure schedules one passive retry",
            UIOnboardingRuntime.standardSessionShouldSchedulePassiveRecovery(
                isAdministrator: false, alreadyScheduled: false))
        check("onboarding runtime: administrator health failure does not use passive retry",
            !UIOnboardingRuntime.standardSessionShouldSchedulePassiveRecovery(
                isAdministrator: true, alreadyScheduled: false))
        check("onboarding runtime: Standard passive retry is bounded to one per process",
            !UIOnboardingRuntime.standardSessionShouldSchedulePassiveRecovery(
                isAdministrator: false, alreadyScheduled: true))
        check("onboarding runtime: healthy completion does not replace active PIN recovery",
            !UIOnboardingRuntime.healthMayReplaceRecovery(recoveryInProgress: true))
        check("onboarding runtime: completion error does not replace active PIN recovery",
            !UIOnboardingRuntime.healthMayReplaceRecovery(recoveryInProgress: true)
                && UIOnboardingRuntime.healthMayReplaceRecovery(recoveryInProgress: false))
        check("onboarding runtime: first frame is not verified protection before service health",
            !UIOnboardingRuntime.protectionIsVerified(
                captureHealthy: true, captureLive: true,
                verification: .checkingFreshProcess))
        check("onboarding runtime: failed services are not verified protection",
            !UIOnboardingRuntime.protectionIsVerified(
                captureHealthy: true, captureLive: true,
                verification: .failed(reason: "service failure"))
                && UIOnboardingRuntime.protectionIsVerified(
                    captureHealthy: true, captureLive: true, verification: .healthy))
        check("onboarding runtime: newer schema blocks an in-flight PIN callback surface",
            !UIOnboardingRuntime.pinCallbackMayUpdateSurface(settingsReadOnly: true)
                && UIOnboardingRuntime.pinCallbackMayUpdateSurface(settingsReadOnly: false))
        check("onboarding runtime: lifecycle revocation exposes a retryable recovery surface",
            UIOnboardingRuntime.recoveryLifecycleRevocationSurface
                == .recoveryAuthentication(
                    isAuthenticating: false,
                    error: UIPinRecoveryError.authenticationCancelled.description))
        check("onboarding runtime: failed settings open is retryable after request disarm",
            UIOnboardingRuntime.settingsOpenFailureSurface(
                context: .repair, requestDisarmed: true)
                == .permissionMissing(
                    context: .repair,
                    reason: "System Settings did not open. Open Privacy & Security, then Screen Recording.",
                    error: nil))
        check("onboarding runtime: failed request disarm exposes the stale verification",
            UIOnboardingRuntime.settingsOpenFailureSurface(
                context: .repair, requestDisarmed: false)
                == .serviceFailure(
                    component: "Fresh-process verification",
                    detail: "System Settings did not open, and the pending verification "
                        + "request could not be cleared. Restart SentryScreen before you retry."))
    }

    // MARK: - PIN recovery

    private static func caseRecoveryCancellation(_ dir: String) {
        let store = storeWithPINAndFailures(dir, record: testRecord(seed: 0x71))
        let before = fileBytes(parentPINPath(store))
        let admin = FakeAdministrator(isAdministrator: true)
        let owner = FakeOwnerAuthenticator(result: .cancelled)
        let controller = UIPinRecoveryController(
            store: store,
            administratorChecker: admin,
            ownerAuthenticator: owner,
            makeRecord: { _ in testRecord(seed: 0x72) },
            log: { _, _ in })
        var result: Result<UIPinRecoveryAuthorization, UIPinRecoveryError>?
        controller.authenticate { result = $0 }
        check("pin recovery: cancellation is reported",
            recoveryAuthenticationError(result, matches: {
                if case .authenticationCancelled = $0 { true } else { false }
            }))
        check("pin recovery: cancellation leaves PIN and counters byte-for-byte unchanged",
            controller.state == .idle && fileBytes(parentPINPath(store)) == before)
    }

    private static func caseRecoveryFailure(_ dir: String) {
        let store = storeWithPINAndFailures(dir, record: testRecord(seed: 0x81))
        let before = fileBytes(parentPINPath(store))
        let admin = FakeAdministrator(isAdministrator: true)
        let owner = FakeOwnerAuthenticator(result: .failed(diagnostic: "test refusal"))
        let controller = UIPinRecoveryController(
            store: store,
            administratorChecker: admin,
            ownerAuthenticator: owner,
            makeRecord: { _ in testRecord(seed: 0x82) },
            log: { _, _ in })
        var result: Result<UIPinRecoveryAuthorization, UIPinRecoveryError>?
        controller.authenticate { result = $0 }
        check("pin recovery: owner-authentication failure is reported",
            recoveryAuthenticationError(result, matches: {
                guard case let .authenticationFailed(diagnostic) = $0 else { return false }
                return diagnostic == "test refusal"
            }))
        check("pin recovery: authentication failure leaves PIN and counters unchanged",
            controller.state == .idle
                && UIPin.sameCredential(store.parentPIN, testRecord(seed: 0x81))
                && store.parentPINFailures == testFailures
                && fileBytes(parentPINPath(store)) == before)
    }

    private static func caseRecoveryLifecycleRevocation(_ dir: String) {
        let store = storeWithPINAndFailures(dir, record: testRecord(seed: 0x79))
        let before = fileBytes(parentPINPath(store))
        let owner = SuspendedOwnerAuthenticator()
        let controller = UIPinRecoveryController(
            store: store,
            administratorChecker: FakeAdministrator(isAdministrator: true),
            ownerAuthenticator: owner,
            makeRecord: { _ in testRecord(seed: 0x7a) },
            log: { _, _ in })
        var revocations = 0
        controller.onLifecycleRevocation = { revocations += 1 }
        var result: Result<UIPinRecoveryAuthorization, UIPinRecoveryError>?
        controller.authenticate { result = $0 }
        check("pin recovery: suspended owner authentication is busy before revocation",
            controller.state == .authenticating && result == nil)
        controller.revokeForSessionLifecycleChange()
        check("pin recovery: session lifecycle revocation ends busy authentication",
            controller.state == .idle
                && revocations == 1
                && owner.cancelCount == 1
                && result == nil)

        owner.complete(.success)
        controller.revokeForSessionLifecycleChange()
        check("pin recovery: revoked callback cannot grant or change the PIN",
            controller.state == .idle
                && revocations == 1
                && result == nil
                && fileBytes(parentPINPath(store)) == before)
    }

    private static func caseRecoverySuccess(_ dir: String) {
        let oldRecord = UIPin.make("4821")
        let replacement = UIPin.make("2468")
        let store = storeWithPINAndFailures(dir, record: oldRecord)
        let admin = FakeAdministrator(isAdministrator: true)
        let owner = FakeOwnerAuthenticator(result: .success)
        let controller = UIPinRecoveryController(
            store: store,
            administratorChecker: admin,
            ownerAuthenticator: owner,
            makeRecord: { pin in
                precondition(pin == "2468")
                return replacement
            },
            log: { _, _ in })

        var authentication: Result<UIPinRecoveryAuthorization, UIPinRecoveryError>?
        controller.authenticate { authentication = $0 }
        guard case let .success(authorization)? = authentication else {
            check("pin recovery: successful owner authentication grants replacement", false,
                "result=\(String(describing: authentication))")
            return
        }
        check("pin recovery: successful owner authentication grants replacement",
            controller.state == .authorized)

        var replacementResult: Result<Void, UIPinRecoveryError>?
        controller.replacePin(
            "2468", confirmation: "2468", authorization: authorization
        ) { replacementResult = $0 }
        spin(until: { replacementResult != nil })
        let reloaded = UISettingsStore(root: dir, log: { _, _ in })
        check("pin recovery: replacement writes PIN and cleared counters together",
            replacementSucceeded(replacementResult)
                && controller.state == .idle
                && UIPin.sameCredential(reloaded.parentPIN, replacement)
                && reloaded.parentPINFailures == PinFailures()
                && reloaded.parentPIN.map { UIPin.verify("2468", $0) } == true
                && reloaded.parentPIN.map { UIPin.verify("4821", $0) } == false
                && admin.checkCount == 3,
            "result=\(String(describing: replacementResult)) checks=\(admin.checkCount)")

        let settledBytes = fileBytes(parentPINPath(store))
        var replayResult: Result<Void, UIPinRecoveryError>?
        controller.replacePin(
            "2468", confirmation: "2468", authorization: authorization
        ) { replayResult = $0 }
        check("pin recovery: one-use authorization cannot be replayed",
            recoveryReplacementError(replayResult, matches: {
                if case .authorizationRequired = $0 { true } else { false }
            }) && fileBytes(parentPINPath(store)) == settledBytes)
    }

    private static func caseStaleInFlightPINWork(_ dir: String) {
        makeDirectory(dir)
        let store = makeStore(dir)
        let oldRecord = UIPin.make("4821")
        try! store.parentPINAuthority.mutate {
            $0.pin = oldRecord
            $0.failures = PinFailures(count: 2, lastAt: Date(), lockedUntil: nil)
        }
        let gate = PinGate(store: store, log: { _, _ in })

        var attemptResult: Result<PinGate.Result, Error>?
        gate.attempt("0000") { attemptResult = $0 }
        let recoveredRecord = UIPin.make("2468")
        try! store.parentPINAuthority.mutate {
            $0.pin = recoveredRecord
            $0.failures = PinFailures()
        }
        spin(until: { attemptResult != nil })
        check("pin gate: stale in-flight attempt cannot mutate recovered credentials",
            pinGateCredentialChanged(attemptResult)
                && UIPin.sameCredential(store.parentPIN, recoveredRecord)
                && store.parentPINFailures == PinFailures(),
            "result=\(String(describing: attemptResult))")

        var setResult: Error?? = nil
        gate.setPin("9999", current: "2468") { error in setResult = .some(error) }
        let secondRecovery = UIPin.make("1357")
        try! store.parentPINAuthority.mutate {
            $0.pin = secondRecovery
            $0.failures = PinFailures()
        }
        spin(until: { setResult != nil })
        let staleSetError = setResult ?? nil
        check("pin gate: stale in-flight PIN replacement cannot overwrite recovery",
            staleSetError is PinGate.CredentialChanged
                && UIPin.sameCredential(store.parentPIN, secondRecovery)
                && store.parentPINFailures == PinFailures(),
            "error=\(String(describing: staleSetError))")
    }

    // MARK: - Fixtures and assertions

    private static let testFailures = PinFailures(
        count: 3,
        lastAt: Date(timeIntervalSince1970: 2_000_400_000),
        lockedUntil: nil)

    private final class Clock {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private final class FakeAdministrator: UIAdministratorChecking {
        var result: UIAdministratorCheckResult
        private(set) var checkCount = 0

        init(isAdministrator: Bool, diagnostic: String? = nil) {
            result = UIAdministratorCheckResult(
                isAdministrator: isAdministrator, diagnostic: diagnostic)
        }

        func checkCurrentSession() -> UIAdministratorCheckResult {
            checkCount += 1
            return result
        }
    }

    private final class FakeOwnerAuthenticator: UIOwnerAuthenticating {
        var result: UIOwnerAuthenticationResult
        private(set) var cancelCount = 0

        init(result: UIOwnerAuthenticationResult) { self.result = result }

        func authenticate(
            reason: String,
            completion: @escaping @MainActor (UIOwnerAuthenticationResult) -> Void
        ) {
            completion(result)
        }

        func cancel() { cancelCount += 1 }
    }

    private final class SuspendedOwnerAuthenticator: UIOwnerAuthenticating {
        private var completion: ((UIOwnerAuthenticationResult) -> Void)?
        private(set) var cancelCount = 0

        func authenticate(
            reason: String,
            completion: @escaping @MainActor (UIOwnerAuthenticationResult) -> Void
        ) {
            self.completion = completion
        }

        func cancel() { cancelCount += 1 }

        func complete(_ result: UIOwnerAuthenticationResult) {
            let callback = completion
            completion = nil
            callback?(result)
        }
    }

    private static func testRecord(seed: UInt8) -> PinRecord {
        PinRecord(
            rounds: UIPin.minRounds,
            salt: Data(repeating: seed, count: UIPin.saltBytes),
            hash: Data(repeating: seed ^ 0xff, count: UIPin.hashBytes),
            setAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private static func healthySignals(
        screenRecordingApproved: Bool,
        verification: UIOnboardingVerificationStatus
    ) -> UIOnboardingSignals {
        UIOnboardingSignals(
            activeAccountIsAdministrator: true,
            hostSupport: .supported,
            componentHealth: .healthy,
            screenRecordingApproved: screenRecordingApproved,
            verification: verification)
    }

    private static func healthyReceipt(
        requestID: UUID,
        processStartedAt: Date,
        observedAt: Date
    ) -> UIOnboardingHealthReceipt {
        UIOnboardingHealthReceipt(
            verificationRequestID: requestID,
            processStartedAt: processStartedAt,
            observedAt: observedAt,
            activeAccountIsAdministrator: true,
            hostSupported: true,
            freshProcess: true,
            screenRecordingApproved: true,
            captureHealthy: true,
            requiredServicesHealthy: true)
    }

    private static func freshStore(_ dir: String) -> UISettingsStore {
        makeDirectory(dir)
        return makeStore(dir)
    }

    private static func storeWithPIN(_ dir: String, record: PinRecord) -> UISettingsStore {
        let store = freshStore(dir)
        try! store.parentPINAuthority.mutate { $0.pin = record }
        return store
    }

    private static func storeWithPINAndFailures(
        _ dir: String,
        record: PinRecord
    ) -> UISettingsStore {
        let store = freshStore(dir)
        try! store.parentPINAuthority.mutate {
            $0.pin = record
            $0.failures = testFailures
        }
        return store
    }

    private static func makeStore(_ dir: String) -> UISettingsStore {
        UISettingsStore(root: dir, log: { _, _ in })
    }

    private static func makeDirectory(_ dir: String) {
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        } catch {
            fatalError("cannot create onboarding selftest directory \(dir): \(error)")
        }
    }

    private static func writeLegacySettings(_ record: PinRecord, to path: String) {
        let object: [String: Any] = [
            "version": 1,
            "pin": [
                "algo": PinRecord.algo,
                "rounds": Int(record.rounds),
                "salt": record.salt.base64EncodedString(),
                "hash": record.hash.base64EncodedString(),
            ],
        ]
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0a)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("cannot write legacy onboarding fixture: \(error)")
        }
    }

    private static func fileBytes(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// settings.json as text with whitespace removed: the updater and
    /// agent-launch.sh both read the FILE, and JSONSerialization's pretty
    /// printer decides the spacing around the colon.
    private static func settingsText(_ path: String) -> String {
        let text = String(data: fileBytes(path) ?? Data(), encoding: .utf8) ?? ""
        return text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func parentPINPath(_ store: UISettingsStore) -> String {
        store.root + "/" + ParentPINFileAuthority.directoryName
            + "/" + ParentPINFileAuthority.fileName
    }

    private static func requireRequest(
        _ coordinator: UIOnboardingCoordinator,
        name: String
    ) -> UUID? {
        do {
            return try coordinator.beginFreshProcessVerification()
        } catch {
            check("onboarding: \(name) request starts", false, "\(error)")
            return nil
        }
    }

    private static func caught(_ body: () throws -> Void) -> Error? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }

    private static func isCoordinatorError(
        _ error: Error?,
        matching: (UIOnboardingCoordinatorError) -> Bool
    ) -> Bool {
        guard let typed = error as? UIOnboardingCoordinatorError else { return false }
        return matching(typed)
    }

    private static func recoveryAuthenticationError(
        _ result: Result<UIPinRecoveryAuthorization, UIPinRecoveryError>?,
        matches: (UIPinRecoveryError) -> Bool
    ) -> Bool {
        guard case let .failure(error)? = result else { return false }
        return matches(error)
    }

    private static func recoveryReplacementError(
        _ result: Result<Void, UIPinRecoveryError>?,
        matches: (UIPinRecoveryError) -> Bool
    ) -> Bool {
        guard case let .failure(error)? = result else { return false }
        return matches(error)
    }

    private static func replacementSucceeded(
        _ result: Result<Void, UIPinRecoveryError>?
    ) -> Bool {
        guard case .success? = result else { return false }
        return true
    }

    private static func pinGateCredentialChanged(
        _ result: Result<PinGate.Result, Error>?
    ) -> Bool {
        guard case let .failure(error)? = result else { return false }
        return error is PinGate.CredentialChanged
    }

    private static func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(asyncWaitSecs)
        while !done(), Date() < deadline {
            _ = RunLoop.main.run(
                mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func check(
        _ name: String,
        _ ok: Bool,
        _ detail: @autoclosure () -> String = ""
    ) {
        if ok {
            passed += 1
            print("ok   - \(name)")
        } else {
            failed += 1
            print("not ok - \(name)")
            let message = detail()
            if !message.isEmpty { print("       \(message)") }
        }
    }

    /// O11 Welcome: derived from durable state, so it survives the exit-7
    /// relaunch; shown only before first completion, never to an installed
    /// Mac that lost its PIN.
    private static func caseWelcomeStep(_ dir: String) {
        makeDirectory(dir)
        let store = makeStore(dir)
        let coordinator = UIOnboardingCoordinator(store: store)
        var signals = healthySignals(screenRecordingApproved: false, verification: .notStarted)
        signals.welcomeAcknowledged = false
        let first = coordinator.step(for: signals)
        check("welcome: no PIN, first run, not acknowledged ⇒ O11", first == .welcome && first.stateID == "O11", "\(first)")
        check("welcome: a relaunch (flag reset, still no PIN) shows it again",
            coordinator.step(for: signals) == .welcome)
        signals.welcomeAcknowledged = true
        check("welcome: acknowledged ⇒ createPIN (O1)", coordinator.step(for: signals) == .createPIN)
        check("welcome: surface and chrome",
            UIOnboardingSurface(step: .welcome) == .welcome
                && UIOnboardingChrome(surface: .welcome).title == "Hi! Let\u{2019}s protect this Mac."
                && UIOnboardingChrome(surface: .welcome).stage == nil)
        check("welcome: Start control id registered",
            UIOnboardingControlID.all.contains(UIOnboardingControlID.welcomeStart))
    }
}
