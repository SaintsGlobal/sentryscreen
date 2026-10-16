import AppKit
import Foundation
import LocalAuthentication

struct UIAdministratorCheckResult: Equatable {
    var isAdministrator: Bool
    var diagnostic: String? = nil
}

@MainActor
protocol UIAdministratorChecking {
    /// This must inspect the active account on every call. A cached result is
    /// not an authorization Receipt.
    func checkCurrentSession() -> UIAdministratorCheckResult
}

@MainActor
struct UISystemAdministratorChecker: UIAdministratorChecking {
    func checkCurrentSession() -> UIAdministratorCheckResult {
        let result = AdminCheck.isAdminSession()
        return UIAdministratorCheckResult(
            isAdministrator: result.admin,
            diagnostic: result.error)
    }
}

enum UIOwnerAuthenticationResult: Equatable {
    case success
    case cancelled
    case failed(diagnostic: String)
}

/// Injectable boundary. Automated onboarding UI must use a fake and must not
/// display a real owner-authentication prompt.
@MainActor
protocol UIOwnerAuthenticating: AnyObject {
    func authenticate(
        reason: String,
        completion: @escaping @MainActor (UIOwnerAuthenticationResult) -> Void)
    func cancel()
}

/// Production owner authentication. `.deviceOwnerAuthentication` lets macOS
/// choose an available owner method, including the Mac login password.
@MainActor
final class UILocalOwnerAuthenticator: UIOwnerAuthenticating {
    private var context: LAContext?
    private var requestID: UUID?

    func authenticate(
        reason: String,
        completion: @escaping @MainActor (UIOwnerAuthenticationResult) -> Void
    ) {
        cancel()
        let context = LAContext()
        let requestID = UUID()
        self.context = context
        self.requestID = requestID

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            self.context = nil
            self.requestID = nil
            completion(.failed(
                diagnostic: policyError?.localizedDescription
                    ?? "device owner authentication is unavailable"))
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
            [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, self.requestID == requestID else { return }
                self.context = nil
                self.requestID = nil
                if success {
                    completion(.success)
                    return
                }
                let nsError = error as NSError?
                if let code = nsError.flatMap({ LAError.Code(rawValue: $0.code) }),
                    code == .userCancel || code == .appCancel || code == .systemCancel
                {
                    completion(.cancelled)
                } else {
                    completion(.failed(
                        diagnostic: nsError?.localizedDescription
                            ?? "device owner authentication failed"))
                }
            }
        }
    }

    func cancel() {
        requestID = nil
        context?.invalidate()
        context = nil
    }
}

enum UIPinRecoveryError: Error, CustomStringConvertible {
    case administratorRequired(diagnostic: String?)
    case existingPINRequired
    case authenticationInProgress
    case authenticationCancelled
    case authenticationFailed(diagnostic: String)
    case authorizationRequired
    case format
    case confirmationMismatch
    case replacementInProgress
    case replacementCancelled
    case writeFailed(Error)

    var description: String {
        switch self {
        case .administratorRequired:
            return "A parent must use an administrator account to reset the PIN."
        case .existingPINRequired:
            return "Create the first parent PIN in setup. PIN recovery replaces an existing PIN."
        case .authenticationInProgress:
            return "Authentication is already in progress."
        case .authenticationCancelled:
            return "PIN reset was canceled. The current PIN is unchanged."
        case .authenticationFailed:
            return "This Mac could not verify the parent. Try again."
        case .authorizationRequired:
            return "Authenticate with this Mac before you reset the parent PIN."
        case .format:
            return "Use \(UIPin.digits.lowerBound) to \(UIPin.digits.upperBound) digits, numbers only."
        case .confirmationMismatch:
            return "The PINs do not match."
        case .replacementInProgress:
            return "The PIN is already being replaced."
        case .replacementCancelled:
            return "PIN reset was canceled. The current PIN is unchanged."
        case let .writeFailed(error):
            return "The PIN could not be saved. The current PIN is unchanged. \(error)"
        }
    }
}

/// Unforgeable capability returned by one successful owner-authentication
/// request. UI keeps it only while the recovery surface is active and passes
/// it once to `replacePin`. A new recovery surface has no usable capability.
final class UIPinRecoveryAuthorization {
    fileprivate let id: UUID
    fileprivate init(id: UUID) { self.id = id }
}

/// Authenticates the Mac owner and replaces the parent PIN without a no-PIN
/// interval. Successful authentication issues one private, in-memory grant.
/// One valid replacement attempt consumes that grant before PBKDF2 starts.
@MainActor
final class UIPinRecoveryController: NSObject {
    enum State: Equatable {
        case idle
        case authenticating
        case authorized
        case replacing
    }

    private let authority: any ParentPINAuthorizing
    private let administratorChecker: UIAdministratorChecking
    private let ownerAuthenticator: UIOwnerAuthenticating
    private let makeRecord: (String) -> PinRecord
    private let log: (String, String) -> Void

    /// The runtime uses this callback to exit a disabled busy surface after
    /// sleep or fast user switching revokes the authentication request.
    var onLifecycleRevocation: (@MainActor () -> Void)?

    private(set) var state: State = .idle
    private var authenticationRequestID: UUID?
    private var activeAuthorizationID: UUID?
    private var replacementRequestID: UUID?

    init(
        store: UISettingsStore,
        administratorChecker: UIAdministratorChecking? = nil,
        ownerAuthenticator: UIOwnerAuthenticating? = nil,
        makeRecord: @escaping (String) -> PinRecord = UIPin.make,
        log: @escaping (String, String) -> Void
    ) {
        authority = store.parentPINAuthority
        self.administratorChecker = administratorChecker ?? UISystemAdministratorChecker()
        self.ownerAuthenticator = ownerAuthenticator ?? UILocalOwnerAuthenticator()
        self.makeRecord = makeRecord
        self.log = log
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceSessionDidChange(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceSessionDidChange(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Performs a fresh AdminCheck, then asks macOS to verify the device
    /// owner. Failure and cancellation do not write settings.json.
    func authenticate(
        completion: @escaping @MainActor (
            Result<UIPinRecoveryAuthorization, UIPinRecoveryError>) -> Void
    ) {
        guard state != .authenticating else {
            completion(.failure(.authenticationInProgress))
            return
        }
        guard state != .replacing else {
            completion(.failure(.replacementInProgress))
            return
        }
        activeAuthorizationID = nil
        guard authority.state.pin != nil else {
            state = .idle
            completion(.failure(.existingPINRequired))
            return
        }
        let administrator = administratorChecker.checkCurrentSession()
        guard administrator.isAdministrator else {
            state = .idle
            log("pin-recovery", "admin check refused: \(administrator.diagnostic ?? "not an administrator")")
            completion(.failure(.administratorRequired(diagnostic: administrator.diagnostic)))
            return
        }

        let requestID = UUID()
        authenticationRequestID = requestID
        state = .authenticating
        ownerAuthenticator.authenticate(
            reason: "Authenticate to reset the SentryScreen parent PIN. Protection stays on.") {
                [weak self] result in
                guard let self, self.authenticationRequestID == requestID else { return }
                self.authenticationRequestID = nil
                switch result {
                case .success:
                    let authorization = UIPinRecoveryAuthorization(id: UUID())
                    self.activeAuthorizationID = authorization.id
                    self.state = .authorized
                    self.log("pin-recovery", "owner authentication succeeded")
                    completion(.success(authorization))
                case .cancelled:
                    self.activeAuthorizationID = nil
                    self.state = .idle
                    self.log("pin-recovery", "owner authentication canceled; PIN unchanged")
                    completion(.failure(.authenticationCancelled))
                case let .failed(diagnostic):
                    self.activeAuthorizationID = nil
                    self.state = .idle
                    self.log("pin-recovery", "owner authentication failed: \(diagnostic); PIN unchanged")
                    completion(.failure(.authenticationFailed(diagnostic: diagnostic)))
                }
            }
    }

    /// Consumes one owner authorization and derives the replacement off the
    /// main thread. The old record and counters are replaced together by the
    /// store's atomic same-directory write.
    func replacePin(
        _ newPIN: String,
        confirmation: String,
        authorization: UIPinRecoveryAuthorization,
        completion: @escaping @MainActor (Result<Void, UIPinRecoveryError>) -> Void
    ) {
        guard state != .replacing else {
            completion(.failure(.replacementInProgress))
            return
        }
        guard UIPin.isValidFormat(newPIN) else {
            completion(.failure(.format))
            return
        }
        guard newPIN == confirmation else {
            completion(.failure(.confirmationMismatch))
            return
        }
        guard activeAuthorizationID == authorization.id else {
            completion(.failure(.authorizationRequired))
            return
        }

        // A valid submission consumes the grant before derivation. A failed
        // write requires fresh owner authentication and cannot be replayed.
        activeAuthorizationID = nil
        guard authority.state.pin != nil else {
            state = .idle
            completion(.failure(.existingPINRequired))
            return
        }
        let administrator = administratorChecker.checkCurrentSession()
        guard administrator.isAdministrator else {
            state = .idle
            log("pin-recovery", "fresh admin check refused replacement: "
                + "\(administrator.diagnostic ?? "not an administrator"); PIN unchanged")
            completion(.failure(.administratorRequired(diagnostic: administrator.diagnostic)))
            return
        }

        let requestID = UUID()
        replacementRequestID = requestID
        state = .replacing
        let makeRecord = self.makeRecord
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let record = makeRecord(newPIN)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.replacementRequestID == requestID else {
                    completion(.failure(.replacementCancelled))
                    return
                }
                self.replacementRequestID = nil

                // Check the active account again at the consequential write.
                let administrator = self.administratorChecker.checkCurrentSession()
                guard administrator.isAdministrator else {
                    self.state = .idle
                    self.log("pin-recovery", "write-time admin check refused replacement: "
                        + "\(administrator.diagnostic ?? "not an administrator"); PIN unchanged")
                    completion(.failure(.administratorRequired(diagnostic: administrator.diagnostic)))
                    return
                }
                do {
                    try self.authority.mutate { parentPIN in
                        guard parentPIN.pin != nil else {
                            throw UIPinRecoveryError.existingPINRequired
                        }
                        parentPIN.pin = record
                        parentPIN.failures = PinFailures()
                    }
                    self.state = .idle
                    self.log("pin-recovery", "PIN replaced atomically by \(AdminCheck.currentUserLabel())")
                    completion(.success(()))
                } catch let recoveryError as UIPinRecoveryError {
                    self.state = .idle
                    self.log("pin-recovery", "atomic replacement refused; PIN unchanged: \(recoveryError)")
                    completion(.failure(recoveryError))
                } catch {
                    self.state = .idle
                    self.log("pin-recovery", "atomic replacement failed; PIN unchanged: \(error)")
                    completion(.failure(.writeFailed(error)))
                }
            }
        }
    }

    /// Invalidates pending authentication, a one-use grant, and any in-flight
    /// replacement before it can write. Existing PIN state is not changed.
    func cancel() {
        authenticationRequestID = nil
        activeAuthorizationID = nil
        replacementRequestID = nil
        ownerAuthenticator.cancel()
        state = .idle
    }

    /// Fast user switching, session lock, and display sleep revoke the grant
    /// without a guessed timeout. The recovery UI must also call `cancel()`
    /// whenever its surface exits.
    @objc private func workspaceSessionDidChange(_ notification: Notification) {
        revokeForSessionLifecycleChange()
    }

    /// Visible to the domain self-test so the sleep/session transition can be
    /// verified without changing the real workspace session.
    func revokeForSessionLifecycleChange() {
        let revokedState = state
        log("pin-recovery", "session lifecycle changed; owner authorization revoked")
        cancel()
        guard revokedState != .idle else { return }
        onLifecycleRevocation?()
    }
}
