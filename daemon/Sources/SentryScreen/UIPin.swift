import AppKit
import CommonCrypto
import Foundation
import Security
import SwiftUI

// Parent PIN. Derivation is PBKDF2-HMAC-SHA256 via
// CommonCrypto. The verifier and failure counters live together behind the
// administrator-only ParentPINAuthority. Standard accounts cannot read them,
// and a process restart cannot reset the shared lockout budget.

/// `pin` object in protected parent/pin.json. Salt and hash are raw bytes
/// (base64 on disk).
struct PinRecord: Equatable {
    static let algo = "pbkdf2-hmac-sha256"
    var rounds: UInt32
    var salt: Data
    var hash: Data
    var setAt: Date?
}

/// `failures` object in protected parent/pin.json.
struct PinFailures: Equatable {
    var count = 0
    var lastAt: Date? = nil
    var lockedUntil: Date? = nil
}

enum UIPin {
    /// PBKDF2-HMAC-SHA256 rounds. MEASURED 2026-08-22 on an M1 Mac (arm64,
    /// swiftc -O, 3 samples): 600k = 97.5 / 100.2 / 101.3 ms; 300k = 48 ms;
    /// 100k = 20.5-25.5 ms. 600k is the OWASP-2023 floor for this PRF and
    /// costs the parent ~0.1 s once per unlock window, off the main thread.
    /// It also caps an offline guesser at ~10 tries/s per core against a
    /// 10,000-entry 4-digit space. Selftest tripwire: verify >= 50 ms.
    static let rounds: UInt32 = 600_000
    /// Floor that `verify` enforces on the stored record. The protected file
    /// is group-writable by admins, so a record with `rounds: 1` is tamper or
    /// corruption, not configuration. Verify refuses it instead of checking
    /// a near-zero-cost hash. Kept separate from `rounds` so a later work-
    /// factor increase does not silently lock out existing PINs.
    static let minRounds: UInt32 = 600_000
    /// DERIVED: matches the SHA-256 output width; filled by SecRandomCopyBytes.
    static let saltBytes = 32
    /// DERIVED: SHA-256 output width — the PRF's native size.
    static let hashBytes = 32
    /// Numeric only, 4-8 digits: the keypad UX the parent expects (spec §4).
    static let digits = 4...8

    /// What the PIN is for, in ONE sentence, used on every surface that makes
    /// the promise: `UISetPinView` and the onboarding create-PIN step.
    ///
    /// Every parent mutation goes through `UIActions.requirePIN`: pause and
    /// turn-off, sensitivity, diagnostic reports and hiding the menu bar icon.
    /// The sentence names the categories rather than listing every row.
    /// REMOVING SentryScreen is deliberately absent — it asks for an
    /// administrator name and password, not the PIN (`UIUninstall.swift`,
    /// and `UISettingsPanelView.removeCaption` says so where it is offered).
    static let purpose = "You will need it to pause protection and change settings on this Mac."
    /// Appended wherever the entry field is on screen with the promise.
    static var purposeWithFormat: String {
        purpose + " Use \(digits.lowerBound) to \(digits.upperBound) digits."
    }
    /// The field's own caption, on every surface that has an entry field
    /// (the popover PIN prompt once refused a 3-digit Return with no
    /// explanation — `UIActions.canSubmitPIN` requires the format).
    static var formatCaption: String {
        "Use \(digits.lowerBound) to \(digits.upperBound) digits."
    }

    static func isValidFormat(_ pin: String) -> Bool {
        digits.contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A decoded record can be preserved for owner recovery even when it is
    /// unusable. It must not count as a configured onboarding PIN unless it
    /// meets every invariant that `make` writes and `verify` requires.
    static func isUsableRecord(_ record: PinRecord) -> Bool {
        record.rounds >= minRounds
            && record.salt.count == saltBytes
            && record.hash.count == hashBytes
    }

    /// Credential identity excludes `setAt`: ISO encoding can remove its
    /// fractional seconds during a store reload, while these three fields are
    /// the complete verifier that must remain unchanged across an attempt.
    static func sameCredential(_ a: PinRecord?, _ b: PinRecord?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return a.rounds == b.rounds && a.salt == b.salt && a.hash == b.hash
        default: return false
        }
    }

    static func make(_ pin: String) -> PinRecord {
        var salt = Data(count: saltBytes)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltBytes, $0.baseAddress!) }
        // A failed RNG is not something to paper over with a fixed salt.
        precondition(rc == errSecSuccess, "SecRandomCopyBytes failed: \(rc)")
        return PinRecord(rounds: rounds, salt: salt, hash: derive(pin, salt: salt, rounds: rounds), setAt: Date())
    }

    /// Constant-time: length-checked XOR-accumulate, never `==`.
    /// A record below `minRounds` is refused outright (see its receipt).
    static func verify(_ pin: String, _ record: PinRecord) -> Bool {
        guard isUsableRecord(record) else { return false }
        let candidate = derive(pin, salt: record.salt, rounds: record.rounds)
        return constantTimeEqual(candidate, record.hash)
    }

    static func derive(_ pin: String, salt: Data, rounds: UInt32) -> Data {
        var out = Data(count: hashBytes)
        let pinBytes = Array(pin.utf8)
        let rc = out.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pin, pinBytes.count,
                    saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), hashBytes)
            }
        }
        precondition(rc == kCCSuccess, "CCKeyDerivationPBKDF failed: \(rc)")
        return out
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var acc: UInt8 = 0
        for (x, y) in zip(a, b) { acc |= x ^ y }
        return acc == 0
    }
}

/// PIN attempts against the persisted counters (spec §4.1). Every method is
/// main-thread only: the store's reload/onChange are main-only and slice 4/5
/// wire onChange to @MainActor state. The synchronous `attempt`/`setPin`
/// derive inline (~100 ms) and exist for the selftest and scripts; UI code
/// uses the `completion` variants, which move only the PBKDF2 derivation to
/// a global queue (spec §17 landmine 11) and hop back to main to settle.
final class PinGate {
    /// Wrong-PIN attempts before lockout.
    /// DERIVED, honestly scoped: the PIN gate exists only inside an admin GUI
    /// session, so an attacker is already logged in as a parent — this is a
    /// shoulder-surf / sibling-guessing rail, not a cryptographic one. 5 tries
    /// is 0.05 % of a 4-digit space, and each try costs ~100 ms of PBKDF2.
    static let maxAttempts = 5
    /// Lockout after maxAttempts. DERIVED: 5 tries / 5 min bounds exhaustive
    /// search of a 4-digit PIN to ~7 days of continuous attention, and reuses
    /// the number the family already meets in the panic pause
    /// (Pipeline.pauseSeconds = 300) so there is one duration to learn.
    static let lockoutSecs: TimeInterval = 300

    enum Result: Equatable {
        case ok
        case wrong(remaining: Int)
        case locked(until: Date)
        case noPin
    }

    let authority: any ParentPINAuthorizing
    private let log: (String, String) -> Void
    /// Injected clock for the selftest; production uses the wall clock.
    var now: () -> Date

    init(
        authority: any ParentPINAuthorizing,
        log: @escaping (String, String) -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.authority = authority
        self.log = log
        self.now = now
    }

    convenience init(
        store: UISettingsStore,
        log: @escaping (String, String) -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(authority: store.parentPINAuthority, log: log, now: now)
    }

    /// Current lockout deadline if one is in force.
    func lockedUntil() -> Date? {
        guard let until = authority.state.failures.lockedUntil, until > now() else { return nil }
        return until
    }

    /// Throws when the counter cannot be persisted: an attempt whose failure
    /// could not be recorded is refused rather than counted in memory.
    func attempt(_ pin: String) throws -> Result {
        if let r = precheck() { return r }
        let record = authority.state.pin!
        return try settle(
            verified: UIPin.verify(pin, record), against: record, at: now())
    }

    /// Derives on a global queue; `completion` runs on main.
    func attempt(_ pin: String, completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        if let r = precheck() { completion(.success(r)); return }
        let record = authority.state.pin!
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = UIPin.verify(pin, record)
            DispatchQueue.main.async {
                completion(Swift.Result {
                    try self.settle(verified: ok, against: record, at: self.now())
                })
            }
        }
    }

    /// Lock / no-PIN short-circuit; nil means "derive, then settle".
    private func precheck() -> Result? {
        if let until = lockedUntil() { return .locked(until: until) }
        if authority.state.pin == nil { return .noPin }
        return nil
    }

    /// Counter bookkeeping for one derived attempt.
    private func settle(verified: Bool, against record: PinRecord, at t: Date) throws -> Result {
        var result: Result = .wrong(remaining: 0)
        try authority.mutate { s in
            guard UIPin.sameCredential(s.pin, record) else { throw CredentialChanged() }
            if let until = s.failures.lockedUntil, until > t {
                result = .locked(until: until)
                return
            }
            if verified {
                s.failures = PinFailures()
                result = .ok
                return
            }
            var f = s.failures
            if let until = f.lockedUntil, until <= t { f = PinFailures() }  // expired lock: fresh budget
            f.count += 1
            f.lastAt = t
            let user = AdminCheck.currentUserLabel()
            log("pin", "fail count=\(f.count)/\(Self.maxAttempts) user=\(user)")
            if f.count >= Self.maxAttempts {
                let until = t.addingTimeInterval(Self.lockoutSecs)
                f.lockedUntil = until
                log("pin", "locked until=\(UISettings.iso.string(from: until)) after \(f.count) failures "
                    + "(budget PinGate.maxAttempts=\(Self.maxAttempts))")
                result = .locked(until: until)
            } else {
                result = .wrong(remaining: Self.maxAttempts - f.count)
            }
            s.failures = f
        }
        return result
    }

    struct FormatError: Error, CustomStringConvertible {
        var description: String { UIPinCopy.badFormat }
    }

    /// A PIN is set and `current` was nil: the caller forgot the gate.
    struct CurrentRequired: Error, CustomStringConvertible {
        var description: String { "a PIN is set — the current PIN is required to replace it" }
    }
    /// The current PIN did not verify (or the gate is locked); `result` is
    /// what `attempt` returned, so the sheet can show remaining tries.
    ///
    /// PARENT-FACING: the Change PIN sheet renders this verbatim in
    /// `setPinError`, so it may not name an internal enum case. It said
    /// "current PIN refused: wrong(remaining: 2)" until 2026-09-11.
    /// The words are `UIPinCopy`'s, shortened to the board's
    /// (Popover-SetPin "That’s not your current PIN. 4 tries left."), and the
    /// same for the same two outcomes everywhere they are shown.
    struct Refused: Error, CustomStringConvertible {
        let result: Result
        var description: String {
            switch result {
            case let .wrong(remaining): return UIPinCopy.notCurrent(remaining: remaining)
            case let .locked(until): return PinGate.lockoutMessage(until: until)
            // Not reachable: `setPin` throws this only for a refusal. Named
            // rather than left to `\(result)` so a future case cannot leak an
            // enum spelling onto the sheet.
            case .ok, .noPin: return "Your current PIN could not be checked. Try again."
            }
        }
    }

    /// "Too many tries. Try again in 4:37." — §4.1's countdown, in ONE
    /// place so the PIN prompt and the Change PIN sheet cannot word the same
    /// lockout differently. The prefix "Too many" is load-bearing:
    /// `UIActions` swaps the message for `lockEndedMessage` by matching it.
    static func lockoutMessage(until: Date, now: Date = Date()) -> String {
        UIPinCopy.lockedTitle + ". " + UIPinCopy.retry(until: until, now: now)
    }
    /// Another authorized session replaced the credential while PBKDF2 was
    /// running. The result is stale and must not unlock or mutate counters.
    struct CredentialChanged: Error, CustomStringConvertible {
        var description: String {
            UIPinCopy.changedElsewhere
        }
    }

    /// Set the first PIN (`current: nil` is accepted only while none is set)
    /// or replace it (spec §9.4 change-PIN requires the current PIN). The
    /// current PIN goes through the same settle path as `attempt`, so a wrong
    /// one counts toward lockout and an active lockout refuses replacement.
    func setPin(_ new: String, current: String?) throws {
        guard UIPin.isValidFormat(new) else { throw FormatError() }
        let existing = authority.state.pin
        if let existing {
            guard let current else { throw CurrentRequired() }
            if let r = precheck() { throw Refused(result: r) }
            guard UIPin.verify(current, existing) else {
                let r = try settle(verified: false, against: existing, at: now())
                throw Refused(result: r)
            }
        }
        try write(UIPin.make(new), replacing: existing, at: now())
    }

    /// Same contract; both derivations run on a global queue, `completion`
    /// (nil = success) runs on main.
    func setPin(_ new: String, current: String?, completion: @escaping (Error?) -> Void) {
        guard UIPin.isValidFormat(new) else { completion(FormatError()); return }
        guard let record = authority.state.pin else {
            DispatchQueue.global(qos: .userInitiated).async {
                let made = UIPin.make(new)
                DispatchQueue.main.async {
                    completion(Self.failure {
                        try self.write(made, replacing: nil, at: self.now())
                    })
                }
            }
            return
        }
        guard let current else { completion(CurrentRequired()); return }
        if let r = precheck() { completion(Refused(result: r)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = UIPin.verify(current, record)
            let made = ok ? UIPin.make(new) : nil
            DispatchQueue.main.async {
                completion(Self.failure {
                    guard ok, let made else {
                        let r = try self.settle(
                            verified: false, against: record, at: self.now())
                        throw Refused(result: r)
                    }
                    try self.write(made, replacing: record, at: self.now())
                })
            }
        }
    }

    private func write(_ record: PinRecord, replacing expected: PinRecord?, at t: Date) throws {
        try authority.mutate { s in
            guard UIPin.sameCredential(s.pin, expected) else { throw CredentialChanged() }
            if expected != nil, let until = s.failures.lockedUntil, until > t {
                throw Refused(result: .locked(until: until))
            }
            s.pin = record
            s.failures = PinFailures()
        }
        log("pin", "set by \(AdminCheck.currentUserLabel())")
    }

    private static func failure(_ body: () throws -> Void) -> Error? {
        do { try body(); return nil } catch { return error }
    }
}

// MARK: - Copy (boards Popover-PinPrompt, Popover-SetPin)

/// Parent-facing PIN words, from the approved boards. `PinGate` builds its
/// refusals from these, and `UIActions` (UISettingsSheet.swift, not this
/// slice) still builds three strings of its own in `submitPIN` and
/// `saveNewPin`: it should call `wrong(remaining:)`, `mismatch` and
/// `badFormat` so one refusal is not worded two ways.
enum UIPinCopy {
    static let enterTitle = "Enter your PIN"
    static let lockedTitle = "Too many tries"
    static let setTitle = "Set a PIN"
    static let changeTitle = "Change PIN"
    /// Board Popover-SetPin A. `UIPin.purpose` (onboarding, Setup-2-Pin) is a
    /// different board sentence and stays as it is.
    static let setPurpose = "You’ll need it to pause, change settings or manage your plan."
    static let changePurpose = "Pick a new PIN for this Mac."
    static let newLabel = "New PIN"
    static let repeatLabel = "Type it again"
    static let mismatch = "Those PINs don’t match."
    static let changedElsewhere = "Someone just changed the PIN. Enter the current one."
    static let forgot = "Forgot PIN?"
    /// Same id the onboarding window's button uses (UIOnboardingControlID
    /// `recoveryStart`): one control, one id, on whichever surface is up.
    static let forgotID = "onboarding.recovery.start"

    /// "4 to 8 digits", from the format rule itself.
    static var digitsHint: String { "\(UIPin.digits.lowerBound) to \(UIPin.digits.upperBound) digits" }
    static var badFormat: String { "Use \(digitsHint)." }

    static func tries(_ n: Int) -> String { "\(n) \(n == 1 ? "try" : "tries")" }
    static func wrong(remaining: Int) -> String { "Wrong PIN. \(tries(remaining)) left." }
    static func notCurrent(remaining: Int) -> String {
        "That’s not your current PIN. \(tries(remaining)) left."
    }

    /// "Try again in 4:37." Rounded UP, like the trial's days left and the
    /// pause's minutes left: a lockout never reads 0:00 while it still holds.
    static func retry(until: Date, now: Date = Date()) -> String {
        let left = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        return String(format: "Try again in %d:%02d.", left / 60, left % 60)
    }

    /// `PausePreset.confirmation` and the other `requirePIN` sentences are
    /// imperatives ("Pause protection for 15 minutes."). The board's line
    /// under the title is "To pause protection for 15 minutes".
    static func actionLine(_ confirmation: String) -> String {
        "To " + lowercasedFirst(trimmedPeriod(confirmation))
    }

    /// Board Popover-SetPin A: "Then: pause for 15 minutes".
    static func thenLine(_ confirmation: String) -> String {
        let plain = trimmedPeriod(confirmation)
        let pausePrefix = "Pause protection for "
        if plain.hasPrefix(pausePrefix) { return "Then: pause for " + plain.dropFirst(pausePrefix.count) }
        return "Then: " + lowercasedFirst(plain)
    }

    private static func trimmedPeriod(_ s: String) -> String {
        s.hasSuffix(".") ? String(s.dropLast()) : s
    }

    /// Lowercases the first letter of a leading verb; leaves "SentryScreen"
    /// style words and acronyms alone (second letter not lowercase).
    private static func lowercasedFirst(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1, chars[0].isUppercase, chars[1].isLowercase else { return s }
        return chars[0].lowercased() + String(chars.dropFirst())
    }
}

/// The keypad's entry rules, pure so the self-test can pin them.
enum UIPinKeypad {
    static let digitRows: [[Int]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    /// A ninth digit is not accepted: 8 is the format rule's top
    /// (`UIPin.digits`), and the prompt's hint says so beside the dots.
    static func appending(_ digit: Character, to entry: String) -> String {
        guard digit.isASCII, digit.isNumber, entry.count < UIPin.digits.upperBound else { return entry }
        return entry + String(digit)
    }

    static func deletingLast(_ entry: String) -> String { String(entry.dropLast()) }
}

// MARK: - Views

/// A keypad key: cream slip, ink edge, hand-cut corners that differ per key
/// (board Popover-PinPrompt). `filled: false` is the Delete key, which the
/// board draws with no plate.
struct UIPinKeyStyle: ButtonStyle {
    let variant: Int
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        UIPinKey(configuration: configuration, variant: variant, filled: filled)
    }
}

private struct UIPinKey: View {
    let configuration: ButtonStyleConfiguration
    let variant: Int
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = UIPopoverShape.keys[variant % UIPopoverShape.keys.count]
        configuration.label
            .uiFont(.headline)
            .foregroundStyle(filled ? SentryColor.slipInk : SentryColor.ink)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(shape.fill(filled ? SentryColor.slip : Color.clear))
            .overlay(shape.strokeBorder(filled ? SentryColor.controlBorder : Color.clear, lineWidth: 2))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
            .contentShape(shape)
    }
}

/// The PIN prompt layer: dots, a 3-by-4 keypad, Cancel and Unlock, and the
/// forgot-PIN link. Replaces `UIPinPromptView` in the popover's layer switch
/// and keeps its control ids (`ui.pin.*`). The number keys, Delete and Return
/// work from the Mac keyboard too.
///
/// NOT DRAWN, and why: the board's "Unlocked" state. `UIActions.submitPIN`
/// closes this layer and runs the mutation in the same main-thread turn, so
/// there is no moment for this view to show it; it needs `UIActions` to hold
/// the layer, which is UISettingsSheet.swift's.
struct UIPinKeypadView: View {
    @ObservedObject var actions: UIActions
    @FocusState private var keysFocused: Bool

    private var locked: Bool { actions.lockedUntil != nil }
    private var interactive: Bool { !locked && !actions.busy }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: locked ? UISymbol.lockedOut : UISymbol.lock)
                .uiFont(size: UIMetrics.headerSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(locked ? SentryColor.danger : SentryColor.accent)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(locked ? UIPinCopy.lockedTitle : UIPinCopy.enterTitle)
                    .uiFont(.headline)
                    .foregroundStyle(SentryColor.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                subtitle
            }
            dots
            messageLine
            keypad
            actionRow
            Button(UIPinCopy.forgot) { actions.beginPINRecovery() }
                .buttonStyle(.sentryQuiet)
                .uiControl(UIPinCopy.forgotID, kind: .button, read: { UIPinCopy.forgot },
                    activate: { actions.beginPINRecovery() })
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .overlay(alignment: .top) { UIPopoverRule(width: 1) }
        // Keys from the keyboard. A focusable container with no ring: the
        // popover is key on show (UIStatusItem), this puts the digits here.
        .focusable()
        .focused($keysFocused)
        .focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits) { key in
            guard interactive, let digit = key.characters.first else { return .ignored }
            press(digit)
            return .handled
        }
        .onKeyPress(.delete) {
            guard interactive else { return .ignored }
            deleteLast()
            return .handled
        }
        .onAppear { keysFocused = true }
    }

    // MARK: Pieces

    @ViewBuilder private var subtitle: some View {
        if locked, let until = actions.lockedUntil {
            Text(UIPinCopy.retry(until: until))
                .uiFont(.callout)
                .foregroundStyle(SentryColor.ink2)
                .uiControl("ui.pin.error", kind: .text, read: {
                    actions.lockedUntil.map { UIPinCopy.retry(until: $0) } ?? ""
                })
        } else {
            if let confirmation = actions.pendingConfirmation {
                Text(UIPinCopy.actionLine(confirmation))
                    .uiFont(.callout)
                    .foregroundStyle(SentryColor.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Addendum 7 (spec): the pause confirmation states its scope at the
            // moment of confirmation. Not on the board; kept, one caption line.
            if let note = actions.pendingNote {
                Text(note)
                    .uiFont(.caption)
                    .foregroundStyle(SentryColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dots: some View {
        let count = actions.pinEntry.count
        return HStack(spacing: 10) {
            ForEach(0..<max(UIPin.digits.lowerBound, count), id: \.self) { index in
                Circle()
                    .strokeBorder(SentryColor.controlBorder, lineWidth: 2)
                    .background(Circle().fill(index < count ? SentryColor.ink : Color.clear))
                    .frame(width: 14, height: 14)
            }
        }
        .frame(height: 16)
        .opacity(locked ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        // The digits are never announced; only how many there are.
        .accessibilityLabel("PIN, \(count) digit\(count == 1 ? "" : "s") entered")
        .uiControl("ui.pin.field", kind: .field,
            read: { actions.pinEntry },
            setText: { actions.pinEntry = $0 },
            enabled: { actions.lockedUntil == nil && !actions.busy })
    }

    @ViewBuilder private var messageLine: some View {
        if actions.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(SentryColor.accent)
                Text("Checking…").uiFont(.callout).foregroundStyle(SentryColor.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Checking your PIN")
        } else if !locked, let error = actions.pinError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: UISymbol.error)
                    .foregroundStyle(SentryColor.danger)
                    .accessibilityHidden(true)
                Text(error)
                    .uiFont(.callout)
                    .foregroundStyle(SentryColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .uiControl("ui.pin.error", kind: .text, read: { actions.pinError ?? "" })
        } else if !locked {
            Text(UIPinCopy.digitsHint)
                .uiFont(.callout)
                .foregroundStyle(SentryColor.muted)
                .uiControl("ui.pin.format", kind: .text, read: { UIPinCopy.digitsHint })
        }
    }

    private var keypad: some View {
        VStack(spacing: 8) {
            ForEach(UIPinKeypad.digitRows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key($0) }
                }
            }
            HStack(spacing: 8) {
                Color.clear.frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                key(0)
                deleteKey
            }
        }
    }

    private func key(_ digit: Int) -> some View {
        Button { press(Character(String(digit))) } label: { Text("\(digit)") }
            .buttonStyle(UIPinKeyStyle(variant: digit))
            .disabled(!interactive)
            .uiControl("ui.pin.key.\(digit)", kind: .button, read: { "\(digit)" },
                activate: { press(Character(String(digit))) },
                enabled: { actions.lockedUntil == nil && !actions.busy })
    }

    private var deleteKey: some View {
        Button { deleteLast() } label: { Image(systemName: UISymbol.deleteDigit) }
            .buttonStyle(UIPinKeyStyle(variant: 3, filled: false))
            .disabled(!interactive || actions.pinEntry.isEmpty)
            .accessibilityLabel("Delete last digit")
            .uiControl("ui.pin.delete", kind: .button, read: { "Delete last digit" },
                activate: { deleteLast() },
                enabled: { actions.lockedUntil == nil && !actions.busy && !actions.pinEntry.isEmpty })
    }

    private var actionRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { actions.cancelLayer() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                .buttonStyle(UIPopoverOutlineButtonStyle(height: SentryPrimaryButtonStyle.minHeight))
                .keyboardShortcut(.cancelAction)
                .uiControl("ui.pin.cancel", kind: .button, read: { "Cancel" },
                    activate: { actions.cancelLayer() })
            Button { actions.submitPIN() } label: { Text("Unlock").frame(maxWidth: .infinity) }
                .buttonStyle(.sentryPrimary)
                .padding(.trailing, SentryPrimaryButtonStyle.shadowOffset.width)
                .padding(.bottom, SentryPrimaryButtonStyle.shadowOffset.height)
                .keyboardShortcut(.defaultAction)
                .disabled(!actions.canSubmitPIN)
                .uiControl("ui.pin.submit", kind: .button, read: { "Unlock" },
                    activate: { actions.submitPIN() }, enabled: { actions.canSubmitPIN })
        }
    }

    private func press(_ digit: Character) {
        actions.pinEntry = UIPinKeypad.appending(digit, to: actions.pinEntry)
    }

    private func deleteLast() {
        actions.pinEntry = UIPinKeypad.deletingLast(actions.pinEntry)
    }
}

/// The set / change PIN layer (board Popover-SetPin). Replaces `UISetPinView`
/// in the popover's layer switch and keeps its control ids
/// (`ui.sheet.setpin.*`). Two secure fields, one message line that is either
/// the format hint or the error, and "Then: …" when a mutation is waiting.
struct UIPinSetView: View {
    @ObservedObject var actions: UIActions
    /// The two fields are a chain: Return in "New PIN" moves to "Type it
    /// again", Return there saves.
    enum Field: Hashable { case pin, confirmation }
    @FocusState private var focused: Field?

    private var isChange: Bool { actions.store.parentPIN != nil }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: UISymbol.setPin)
                .uiFont(size: UIMetrics.headerSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(SentryColor.accent)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(isChange ? UIPinCopy.changeTitle : UIPinCopy.setTitle)
                    .uiFont(.headline)
                    .foregroundStyle(SentryColor.ink)
                Text(isChange ? UIPinCopy.changePurpose : UIPinCopy.setPurpose)
                    .uiFont(.callout)
                    .foregroundStyle(SentryColor.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                field(UIPinCopy.newLabel, text: $actions.newPin, field: .pin,
                    id: "ui.sheet.setpin.field1", invalid: false) {
                        focused = .confirmation
                    }
                field(UIPinCopy.repeatLabel, text: $actions.confirmPin, field: .confirmation,
                    id: "ui.sheet.setpin.field2", invalid: actions.setPinError != nil) { actions.saveNewPin() }
            }
            messageLine
            if let confirmation = actions.pendingConfirmation {
                UIPopoverInfoCard(shape: UIPopoverShape.outlineSmall, horizontal: 12, vertical: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: UISymbol.disclosure)
                            .uiFont(.caption, weight: .semibold)
                            .foregroundStyle(SentryColor.muted)
                            .accessibilityHidden(true)
                        Text(UIPinCopy.thenLine(confirmation))
                            .uiFont(.callout)
                            .foregroundStyle(SentryColor.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Button { actions.cancelLayer() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(UIPopoverOutlineButtonStyle(height: SentryPrimaryButtonStyle.minHeight))
                    .keyboardShortcut(.cancelAction)
                    .uiControl("ui.sheet.setpin.cancel", kind: .button, read: { "Cancel" },
                        activate: { actions.cancelLayer() })
                Button { actions.saveNewPin() } label: { Text("Save PIN").frame(maxWidth: .infinity) }
                    .buttonStyle(.sentryPrimary)
                    .padding(.trailing, SentryPrimaryButtonStyle.shadowOffset.width)
                    .padding(.bottom, SentryPrimaryButtonStyle.shadowOffset.height)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!actions.canSavePin)
                    .uiControl("ui.sheet.setpin.save", kind: .button, read: { "Save PIN" },
                        activate: { actions.saveNewPin() }, enabled: { actions.canSavePin })
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .overlay(alignment: .top) { UIPopoverRule(width: 1) }
        .onAppear { focused = .pin }
        // A mismatch or a bad format puts the caret back where the correction
        // is made, instead of leaving it in the field that was already right.
        .onChange(of: actions.setPinError) { _, error in
            if error != nil { focused = .pin }
        }
    }

    @ViewBuilder private var messageLine: some View {
        if actions.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(SentryColor.accent)
                Text("Saving…").uiFont(.callout).foregroundStyle(SentryColor.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Saving your PIN")
        } else if let error = actions.setPinError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: UISymbol.error)
                    .foregroundStyle(SentryColor.danger)
                    .accessibilityHidden(true)
                Text(error)
                    .uiFont(.callout)
                    .foregroundStyle(SentryColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .uiControl("ui.sheet.setpin.error", kind: .text, read: { actions.setPinError ?? "" })
        } else {
            Text(UIPinCopy.digitsHint)
                .uiFont(.callout)
                .foregroundStyle(SentryColor.muted)
        }
    }

    private func field(
        _ label: String, text: Binding<String>, field: Field, id: String, invalid: Bool,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .uiFont(.callout, weight: .semibold)
                .foregroundStyle(SentryColor.ink2)
            // Deliberately NO `.uiFont` on the field: a PIN field keeps
            // AppKit's own field font, so the typed digits do not follow
            // `\.uiTextScale`.
            // Every label around it does scale.
            // DESIGN.md "Inputs" in both rooms (review 2026-09-29, item 2):
            // the same slip and dark edge as the setup window's fields.
            SecureField("", text: text)
                .sentrySlipField(invalid: invalid)
                .accessibilityLabel(label)
                .focused($focused, equals: field)
                .disabled(actions.busy)
                .onSubmit(onSubmit)
                .uiControl(id, kind: .field,
                    read: { text.wrappedValue },
                    setText: { text.wrappedValue = $0 },
                    enabled: { !actions.busy })
        }
    }
}
