import Foundation

/// Durable parent-onboarding state stored inside settings.json.
///
/// `schemaVersion == 0` is a decoded legacy installation that already had a
/// PIN before onboarding state existed. It is not a completed migration. A
/// production health Receipt must promote it to `currentSchemaVersion`.
struct UIOnboardingRecord: Equatable {
    static let legacySchemaVersion = 0
    static let currentSchemaVersion = 1

    var schemaVersion = UIOnboardingRecord.currentSchemaVersion
    var completedAt: Date? = nil
    var successShownAt: Date? = nil
    var verificationPending = false
    var verificationRequestID: UUID? = nil
    var verificationStartedAt: Date? = nil

    static let fresh = UIOnboardingRecord()
    static let legacyPINNeedsVerification = UIOnboardingRecord(
        schemaVersion: legacySchemaVersion,
        completedAt: nil,
        successShownAt: nil,
        verificationPending: false,
        verificationRequestID: nil,
        verificationStartedAt: nil)

    var isLegacyMigrationPending: Bool {
        schemaVersion == Self.legacySchemaVersion && completedAt == nil
    }

    var readOnly: Bool { schemaVersion > Self.currentSchemaVersion }
}

enum UIOnboardingHostSupport: Equatable {
    case supported
    case unsupported(required: String, observed: String)
}

enum UIOnboardingComponentHealth: Equatable {
    case unknown
    case healthy
    case unhealthy(reason: String)
}

/// Current-process evidence. A cached TCC value is not represented as a
/// healthy result. Production integration supplies `.healthy` only after a
/// fresh process has verified permission, capture, and required services.
enum UIOnboardingVerificationStatus: Equatable {
    case notStarted
    case waitingForReturn
    case checkingFreshProcess
    case healthy
    case failed(reason: String)
}

struct UIOnboardingSignals: Equatable {
    var activeAccountIsAdministrator: Bool
    var hostSupport: UIOnboardingHostSupport
    var componentHealth: UIOnboardingComponentHealth
    var screenRecordingApproved: Bool
    var verification: UIOnboardingVerificationStatus
    /// True once this process's Welcome screen was passed. Process-local on
    /// purpose: the Welcome step is derived from durable state (no PIN, setup
    /// never completed), so it survives the exit-7 relaunch. Defaults to true
    /// so the pre-existing selftests keep exercising the steps they were
    /// written for; the runtime passes its real flag.
    var welcomeAcknowledged = true
}

/// Production evidence required before onboarding can be marked complete.
/// Tests can construct a Receipt, but production integration must populate it
/// from the active account, supported-host check, and fresh capture process.
struct UIOnboardingHealthReceipt: Equatable {
    var verificationRequestID: UUID
    var processStartedAt: Date
    var observedAt: Date
    var activeAccountIsAdministrator: Bool
    var hostSupported: Bool
    var freshProcess: Bool
    var screenRecordingApproved: Bool
    var captureHealthy: Bool
    var requiredServicesHealthy: Bool

    var failedConditions: [String] {
        var failures: [String] = []
        if !activeAccountIsAdministrator { failures.append("administrator session") }
        if !hostSupported { failures.append("supported host") }
        if !freshProcess { failures.append("fresh process") }
        if !screenRecordingApproved { failures.append("Screen Recording approval") }
        if !captureHealthy { failures.append("healthy capture") }
        if !requiredServicesHealthy { failures.append("required service health") }
        if observedAt < processStartedAt { failures.append("health observed before process start") }
        return failures
    }
}

/// The O0-O9 product contract exposed to a dedicated setup window.
enum UIOnboardingStep: Equatable {
    case preparing
    /// O11: first-run Welcome, before the PIN.
    case welcome
    case createPIN
    case allowScreenRecording
    case waitingForReturn
    case verifyingFreshProcess
    case protectionOn(showConfirmation: Bool)
    case permissionRepair(reason: String)
    case serviceRepair(reason: String)
    case pinRecoveryRequired(reason: String)
    case parentAdministratorRequired
    case unsupportedHost(required: String, observed: String)

    var stateID: String {
        switch self {
        case .preparing: return "O0"
        case .welcome: return "O11"
        case .createPIN: return "O1"
        case .allowScreenRecording: return "O2"
        case .waitingForReturn: return "O3"
        case .verifyingFreshProcess: return "O4"
        case .protectionOn: return "O5"
        case .permissionRepair: return "O6"
        case .serviceRepair, .pinRecoveryRequired: return "O7"
        case .parentAdministratorRequired: return "O8"
        case .unsupportedHost: return "O9"
        }
    }
}

enum UIOnboardingCoordinatorError: Error, CustomStringConvertible {
    case pinRequired
    case pinRecoveryRequired
    case incompleteHealthReceipt([String])
    case verificationNotPending
    case verificationRequestMismatch
    case processPredatesVerification
    case completionRequired
    case clockBeforeCompletion

    var description: String {
        switch self {
        case .pinRequired:
            return "Create a parent PIN before verification starts."
        case .pinRecoveryRequired:
            return "Reset the parent PIN before verification starts."
        case let .incompleteHealthReceipt(failures):
            return "Onboarding health is incomplete: \(failures.joined(separator: ", "))."
        case .verificationNotPending:
            return "Start a fresh-process verification before you record its result."
        case .verificationRequestMismatch:
            return "This verification result does not match the active request."
        case .processPredatesVerification:
            return "The verification process started before the active request."
        case .completionRequired:
            return "Verify protection before you record the success message."
        case .clockBeforeCompletion:
            return "The system clock precedes onboarding completion. Check the Mac date and time."
        }
    }
}

/// Owns durable onboarding transitions. UI code supplies live signals and
/// renders `step(for:)`; capture integration supplies the health Receipt.
@MainActor
final class UIOnboardingCoordinator {
    let store: UISettingsStore
    let pinAuthority: any ParentPINAuthorizing
    var now: () -> Date

    init(
        store: UISettingsStore,
        pinAuthority: (any ParentPINAuthorizing)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.pinAuthority = pinAuthority ?? store.parentPINAuthority
        self.now = now
    }

    func step(for signals: UIOnboardingSignals) -> UIOnboardingStep {
        if case let .unsupported(required, observed) = signals.hostSupport {
            return .unsupportedHost(required: required, observed: observed)
        }
        guard signals.activeAccountIsAdministrator else {
            return .parentAdministratorRequired
        }
        switch signals.componentHealth {
        case let .unhealthy(reason):
            return .serviceRepair(reason: reason)
        case .unknown:
            return .preparing
        case .healthy:
            break
        }

        let settings = store.settings
        guard let pin = pinAuthority.state.pin else {
            // Welcome only before first completion: an installed Mac that lost
            // its PIN must not see the Welcome step a second time.
            let firstRun = settings.onboarding.completedAt == nil
                && !settings.onboarding.isLegacyMigrationPending
            return firstRun && !signals.welcomeAcknowledged ? .welcome : .createPIN
        }
        guard UIPin.isUsableRecord(pin) else {
            return .pinRecoveryRequired(
                reason: "The parent PIN data needs recovery before setup can continue.")
        }
        let onboarding = settings.onboarding
        let wasCompleted = onboarding.completedAt != nil
        let isLegacy = onboarding.isLegacyMigrationPending

        guard signals.screenRecordingApproved else {
            if wasCompleted || isLegacy {
                return .permissionRepair(
                    reason: "Screen Recording is off. A parent must turn it on to restore protection.")
            }
            return .allowScreenRecording
        }

        switch signals.verification {
        case .waitingForReturn:
            return .waitingForReturn
        case .checkingFreshProcess:
            return .verifyingFreshProcess
        case let .failed(reason):
            return .permissionRepair(reason: reason)
        case .healthy:
            if wasCompleted {
                return .protectionOn(showConfirmation: onboarding.successShownAt == nil)
            }
            // The production integration must persist its health Receipt
            // before UI can make a success claim.
            return .verifyingFreshProcess
        case .notStarted:
            if onboarding.verificationPending { return .verifyingFreshProcess }
            if wasCompleted { return .preparing }
            if isLegacy {
                return .permissionRepair(
                    reason: "SentryScreen must verify this existing installation before it reports protection.")
            }
            return .verifyingFreshProcess
        }
    }

    /// Persist before handing control to the fresh process. A restart can
    /// then resume O4 without a cached success result.
    @discardableResult
    func beginFreshProcessVerification() throws -> UUID {
        guard let pin = pinAuthority.state.pin else {
            throw UIOnboardingCoordinatorError.pinRequired
        }
        guard UIPin.isUsableRecord(pin) else {
            throw UIOnboardingCoordinatorError.pinRecoveryRequired
        }
        var activeRequestID: UUID?
        try store.mutate { settings in
            if settings.onboarding.verificationPending,
                let requestID = settings.onboarding.verificationRequestID,
                settings.onboarding.verificationStartedAt != nil
            {
                activeRequestID = requestID
                return
            }
            let requestID = UUID()
            activeRequestID = requestID
            settings.onboarding.verificationPending = true
            settings.onboarding.verificationRequestID = requestID
            settings.onboarding.verificationStartedAt = now()
        }
        guard let activeRequestID else {
            throw UIOnboardingCoordinatorError.verificationNotPending
        }
        return activeRequestID
    }

    /// A settled failure ends this one handoff. A later parent action can
    /// start another one; no automatic restart loop is encoded here.
    func recordVerificationFailure(requestID: UUID) throws {
        try store.mutate { settings in
            guard settings.onboarding.verificationPending else {
                throw UIOnboardingCoordinatorError.verificationNotPending
            }
            guard settings.onboarding.verificationRequestID == requestID else {
                throw UIOnboardingCoordinatorError.verificationRequestMismatch
            }
            settings.onboarding.verificationPending = false
            settings.onboarding.verificationRequestID = nil
            settings.onboarding.verificationStartedAt = nil
        }
    }

    /// This is the only onboarding transition that creates `completedAt` or
    /// promotes a schema-0 legacy PIN installation. All required production
    /// evidence must be green in one Receipt.
    func recordHealthyVerification(_ receipt: UIOnboardingHealthReceipt) throws {
        var failures = receipt.failedConditions
        if receipt.observedAt > now() { failures.append("health observation is in the future") }
        guard failures.isEmpty else {
            throw UIOnboardingCoordinatorError.incompleteHealthReceipt(failures)
        }
        guard let pin = pinAuthority.state.pin else {
            throw UIOnboardingCoordinatorError.pinRequired
        }
        guard UIPin.isUsableRecord(pin) else {
            throw UIOnboardingCoordinatorError.pinRecoveryRequired
        }
        try store.mutate { settings in
            guard settings.onboarding.verificationPending else {
                throw UIOnboardingCoordinatorError.verificationNotPending
            }
            guard settings.onboarding.verificationRequestID == receipt.verificationRequestID else {
                throw UIOnboardingCoordinatorError.verificationRequestMismatch
            }
            guard let requestStartedAt = settings.onboarding.verificationStartedAt,
                receipt.processStartedAt >= requestStartedAt
            else {
                throw UIOnboardingCoordinatorError.processPredatesVerification
            }
            settings.onboarding.schemaVersion = UIOnboardingRecord.currentSchemaVersion
            if settings.onboarding.completedAt == nil {
                settings.onboarding.completedAt = receipt.observedAt
            }
            settings.onboarding.verificationPending = false
            settings.onboarding.verificationRequestID = nil
            settings.onboarding.verificationStartedAt = nil
        }
    }

    /// Record the one-time confirmation only after durable completion. A
    /// second call is a no-op so an update cannot move this timestamp.
    func markSuccessShown() throws {
        try store.mutate { settings in
            guard let completedAt = settings.onboarding.completedAt else {
                throw UIOnboardingCoordinatorError.completionRequired
            }
            guard settings.onboarding.successShownAt == nil else { return }
            let shownAt = now()
            guard shownAt >= completedAt else {
                throw UIOnboardingCoordinatorError.clockBeforeCompletion
            }
            settings.onboarding.successShownAt = shownAt
        }
    }
}
