import AppKit
import SwiftUI

// PIN prompt and set-PIN layers and the single
// `requirePIN {}` wrapper every mutation goes through (§6, Addendum 6F: one
// wrapper cannot drift the way a per-control policy would). Slice 7 adds the
// settings-sheet rows to this file.
//
// PRESENTATION — DERIVED from the driver's capture contract (spec §10.2),
// not from a preference: these are INLINE layers inside the popover, never a
// SwiftUI `.sheet`. A sheet is a second window, so both the default popover-
// window capture and the E2E app-owned content render would capture the
// popover BEHIND the PIN UI. `pin-setup.png` / `pin-locked.png` would then be
// false evidence. The settings panel inherits this constraint. Control Center
// swaps its own sub-panels in place, so the idiom is native.

/// Build identity for the settings sheet's version row (spec §9.4).
///
/// The installed bundle is the source of truth: `packaging/Info.plist` keys
/// CFBundleShortVersionString / CFBundleVersion, which TCC and the installer
/// already key on. The constants below are the fallback for a binary run
/// straight out of `daemon/.build`, which has no Info.plist at all — a dev
/// build then says so rather than inventing a version.
enum UIVersion {
    static let fallbackShort = "0.4.0"
    static let fallbackBuild = "1"

    /// `0.4.0 (build 1)`, from the bundle when there is one.
    static var display: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? fallbackShort
        let build = info?["CFBundleVersion"] as? String ?? fallbackBuild
        return "\(short) (build \(build))"
    }

    /// Shown in place of the model id when this process resolved no model
    /// path — reachable ONLY in a dev run: argument parsing requires
    /// `--model` outside `--ui-demo` / the selftests / `--replay`, and those
    /// modes load no detector at all. Named rather than blank so a demo
    /// screenshot says why the row is empty.
    static let modelUnconfigured = "not configured"
    /// Suffix stripped for the Model row: the only extension the daemon
    /// accepts (`Detector.init` compiles a `.mlpackage`).
    ///
    /// Removed by EXACT suffix rather than `deletingPathExtension()`, which
    /// strips whatever follows the last dot whether or not it is this
    /// extension. MEASURED 2026-09-02: on `m_v8.1_fp16.mlpackage`
    /// the two agree (`m_v8.1_fp16`); they diverge on a name that is not a
    /// `.mlpackage` at all — a compiled `m_v8_ep50_fp16.mlmodelc` or a
    /// dot-carrying `m_v8.1_fp16` — where `deletingPathExtension()` silently
    /// returns `m_v8_ep50_fp16` / `m_v8` and this row would then name a model
    /// that does not exist. Showing an unexpected name VERBATIM is the loud
    /// behavior; truncating it is the quiet wrong one.
    static let modelExtension = ".mlpackage"

    /// The loaded detector's identity for the failed-update support line
    /// (owner 2026-09-02: after swapping the detector, Settings could not
    /// answer "which model is this build running").
    ///
    /// The BASENAME without `.mlpackage`, never the path: §9.4's rows are
    /// parent-facing, and the install layout is already answered once, in
    /// one place, by the State caption below it. The value is derived at
    /// RUNTIME from the path this process resolved (config.json `model`,
    /// `--model`, or the dev default `repoModelPath`), so no model name is
    /// compiled into the binary.
    static func modelID(path: String) -> String {
        guard !path.isEmpty else { return modelUnconfigured }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty, name != "/" else { return modelUnconfigured }
        guard name.hasSuffix(modelExtension) else { return name }
        let id = String(name.dropLast(modelExtension.count))
        return id.isEmpty ? modelUnconfigured : id
    }
}

/// A destructive confirmation drawn over the popover's sections: the copy,
/// the two buttons, and the ids the driver taps. Equatable and value-only so
/// it can ride in `UIActions.Layer` (the action itself is held separately —
/// a closure is not Equatable and SwiftUI diffs this).
///
/// `title` + " " + `body` is the spec's confirmation copy VERBATIM, split at
/// the sentence the parent must answer. That split is the NSAlert idiom
/// (messageText / informativeText) and is what `copy` reassembles for the
/// `.note` control the E2E scripts assert against — so the copy can never
/// drift from the spec without failing a test.
struct UIConfirm: Equatable {
    let title: String
    let body: String
    let confirmLabel: String
    /// `ui.settings.showicon`: `.confirm`, `.cancel` and
    /// `.note` hang off it (spec §10.2).
    let idPrefix: String
    let symbol: String

    var copy: String { title + " " + body }
    var confirmID: String { idPrefix + ".confirm" }
    var cancelID: String { idPrefix + ".cancel" }
    var noteID: String { idPrefix + ".note" }

    /// Spec §9.4 — the reveal hotkey is the whole point of confirming: an
    /// icon that vanishes with no way back is a bug report, not a setting.
    /// Review 2026-09-29 (item 9): the keys in Apple's modifier order
    /// (⌃⌥⌘; all four are line-break class AL, so they never wrap apart);
    /// no hyphenated word to break; and the one real way back. The hotkey is
    /// armed only in an administrator's session (`armRevealHotkey`), and
    /// Settings cannot re-enable it because Settings lives in the hidden
    /// popover, so the old "re-enable it in Settings" was not a path.
    static let revealKeys = "\u{2303}\u{2325}\u{2318}S"
    static let hideIcon = UIConfirm(
        title: "Hide the SentryScreen icon?",
        body: "To bring it back, sign in to an administrator account on this Mac "
            + "and press \(revealKeys).",
        confirmLabel: "Hide icon",
        idPrefix: "ui.settings.showicon",
        symbol: UISymbol.hideIcon)

}

/// The three pause presets (spec §9.2 rows; OWNER copy). Timed presets cap
/// at 1 hr and `untilRestart` is unbounded by design (Addendum 6H).
enum PausePreset: String, CaseIterable {
    case m15, h1, restart

    /// Spec §10.2 identifier.
    var controlID: String {
        switch self {
        case .m15: return "ui.pause.15m"
        case .h1: return "ui.pause.1h"
        case .restart: return "ui.pause.restart"
        }
    }

    var label: String {
        switch self {
        case .m15: return "15 minutes"
        case .h1: return "1 hour"
        case .restart: return "Until this Mac restarts"
        }
    }

    /// nil for `restart` — that one is not a duration.
    var seconds: TimeInterval? {
        switch self {
        case .m15: return 15 * 60
        case .h1: return 60 * 60
        case .restart: return nil
        }
    }

    /// What the PIN prompt says the parent is about to do.
    var confirmation: String {
        switch self {
        case .m15: return "Pause protection for 15 minutes."
        case .h1: return "Pause protection for 1 hour."
        case .restart: return "Turn off protection until this Mac restarts."
        }
    }
}

/// Every mutation the popover can perform, plus the PIN gate in front of all
/// of them. Main thread only (the store, the gate and SwiftUI all are).
final class UIActions: ObservableObject {
    /// One successful PIN unlocks all mutations for the shorter of: the
    /// popover being open (UIStatusItem.popoverDidClose calls `lock()`), or
    /// this window. DERIVED: the same 5-minute family as PinGate.lockoutSecs
    /// and Pipeline.pauseSeconds, so the family learns one duration — a
    /// parent adjusting pause AND sensitivity should not type the PIN twice,
    /// and the window dies with the popover so a walk-away leaves nothing
    /// unlocked.
    static let unlockWindowSecs: TimeInterval = 300

    /// Addendum 7 (and §17.16): the pause confirmation must state the scope.
    static let machineWideNote = "Pausing turns off protection for everyone on this Mac."

    /// Which layer is drawn over the popover's sections. `settings` is the
    /// §9.4 panel; `confirm` is a destructive step in front of a mutation.
    /// `remove` is the §8.1(7) removal confirmation: its own layer rather
    /// than a `UIConfirm`, because it asks two questions (keep or delete the
    /// settings, clear the permission record or not) before it acts.
    enum Layer: Equatable { case none, pin, setPin, settings, confirm(UIConfirm), remove, diagnosticsReview }

    /// A mutation waiting for the PIN. `body` runs on success and is dropped
    /// on cancel — never run early, never queued twice.
    private struct Pending {
        let confirmation: String
        let note: String?
        let body: () -> Void
        /// Called once if the layer closes before `body` runs, so a caller
        /// whose work exists only as this body can name the drop.
        var onDrop: (() -> Void)? = nil
    }

    let store: UISettingsStore
    let gate: PinGate
    /// stderr + run.jsonl. A derivation that settles after the parent
    /// cancelled is dropped, and a drop is never silent.
    private let log: (String, String) -> Void
    /// Diagnostic reports (Diagnostics.swift; DiagnosticsViews.swift is the
    /// section). Set by main.swift; nil under --ui-demo.
    var diagnostics: DiagnosticsAgent? {
        didSet {
            diagnostics?.onSendStateChange = { [weak self] state in
                self?.diagnosticsSend = state
                // The notice is a live region: a state change is read out
                // without moving focus off the button.
                if let state { UIAccessibilityAnnouncement.post(DiagnosticsCopy.notice(for: state)) }
            }
            diagnosticsSend = diagnostics?.sendState
        }
    }
    /// The send notice: the agent's state, mirrored for the section
    /// (`DiagnosticsSendState`; nil = no notice).
    @Published private(set) var diagnosticsSend: DiagnosticsSendState?
    /// The report on the review layer; nil while it is being built.
    @Published private(set) var diagnosticsDraft: DiagnosticsDraft?

    /// `--ui-demo` `state diagnostics <…>` only: a demo has no agent, so the
    /// notice is set directly (UIDemoController.apply). Refused with an
    /// agent present — production state comes from the agent alone.
    func showDemoSendState(_ state: DiagnosticsSendState?) {
        guard diagnostics == nil else { return }
        diagnosticsSend = state
    }

    @Published private(set) var layer: Layer = .none
    @Published var pinEntry = ""
    @Published var newPin = ""
    @Published var confirmPin = ""
    /// PBKDF2 in flight (spec §4: never on the main thread; the layer shows
    /// a ProgressView while it runs).
    @Published private(set) var busy = false
    @Published private(set) var pinError: String?
    @Published private(set) var setPinError: String?
    /// Write failure: shown inline, naming the path and the errno (§3.4).
    /// The action is never silently dropped.
    @Published private(set) var writeError: String?
    /// Ticks once a second while the PIN layer is up, so the lockout
    /// countdown repaints. Nil-cost when the popover is closed.
    @Published private var clockTick = 0

    private var pending: Pending?
    /// The layer a finished (or cancelled) PIN / confirmation returns to:
    /// `.none` for the popover root, `.settings` for a mutation the parent
    /// started inside the settings panel. Without it, changing a setting
    /// dumps the parent back to the status screen mid-task.
    private var returnLayer: Layer = .none
    /// The mutation a `.confirm` layer will run on Accept, dropped on Cancel
    /// — the same never-run-early contract as `Pending`.
    private var confirmBody: (() -> Void)?
    /// The PIN this unlock window was opened with, so Change PIN… can hand
    /// it to `PinGate.setPin(_:current:)` instead of bypassing the gate's own
    /// current-PIN check. Lives exactly as long as the unlock window and is
    /// cleared by `lock()` (popover close, cancel), like the entry fields.
    private var verifiedPin: String?
    private var unlockedUntil: Date?
    private var lockTimer: Timer?
    /// Invalidates an in-flight PBKDF2 derivation. MEASURED: one derivation
    /// costs ~100 ms (UIPin.rounds receipt: 97.5 / 100.2 / 101.3 ms) on a
    /// global queue, and Cancel, Esc (`.keyboardShortcut(.cancelAction)`) and
    /// the popover closing (UIStatusItem.popoverDidClose → `lock()`) all land
    /// inside that window. Without this counter the completion arrives after
    /// `lock()` has cleared `pending` and `unlockedUntil`, and re-opens the
    /// gate for `unlockWindowSecs` against the parent's explicit cancel.
    /// Every completion captures the value it was issued under and drops
    /// itself — loudly — if `lock()` moved it.
    private var epoch = 0

    /// AppDelegate wires the normal parent surfaces to the dedicated,
    /// LocalAuthentication-backed recovery window. Standard-user sessions
    /// have no status item, so they cannot reach this callback.
    var onForgotPIN: (() -> Void)?
    var onRepairProtection: (() -> Void)?

    init(store: UISettingsStore, log: @escaping (String, String) -> Void) {
        self.store = store
        self.log = log
        gate = PinGate(store: store, log: log)
    }

    // MARK: Removal (SPEC §8.1(7); owner 2026-09-05)

    /// The parent's answers to the two questions `uninstall.sh` accepts.
    /// Published so the confirmation's controls and the registry read one
    /// source of truth (the `showIcon` row's rule).
    @Published var removeChoice = Uninstall.Choice()
    /// The Settings page on screen. On the actions object, not the panel's
    /// own @State: a PIN prompt or confirmation replaces the panel view and
    /// returns to a fresh one, and a parent who tapped Change PIN on App
    /// must land back on App (settings-changepin.txt, hide-icon.txt). `nil`
    /// until a page is shown: the panel then starts on
    /// `.general`.
    @Published var settingsTab: UISettingsTab?
    /// Whether General's "More settings" fold is open (Settings-General,
    /// Settings-App boards). Held here for the `settingsTab` reason: Change
    /// PIN and Hide icon go through a PIN prompt or confirmation and must
    /// land back on the open fold. Shut on every `openSettings()`.
    @Published var moreSettingsOpen = false
    /// Where the removal has got to. `.idle` while the confirmation is still
    /// a question.
    @Published private(set) var removeStage: UninstallGate.Stage = .idle
    /// The script's own text on a failure, or the cancelled notice. Never a
    /// friendlier sentence in place of the script's remediation line.
    @Published private(set) var removeMessage: String?

    /// Built on first use so a session that never opens the sheet pays
    /// nothing, and so the selftest can install its own before the first
    /// `beginRemove()`.
    var uninstallGate: UninstallGate?

    /// Whether removal may even be offered. Set by whoever owns `UIState`
    /// (main.swift, the UI driver) so the ROW's condition and this refusal
    /// read the same published `isAdmin`, and cannot drift into a row that is
    /// drawn but refuses, or one that is hidden but still reachable by a
    /// script. Fail-safe default for a session that never wires it.
    var removalAllowed: () -> Bool = { AdminCheck.isAdminSession().admin }

    /// Non-nil when this process must not run the installed removal script:
    /// a dev state root (the binary is not the installed app, so the script
    /// it would run belongs to a different installation) or the UI driver
    /// (an E2E tap must never raise a real administrator prompt — the same
    /// rule `openLink` follows for the browser).
    var removalSuppressedReason: String? {
        if UIDriver.scriptPath != nil { return "the UI test driver is running this session" }
        if !store.isProductionRoot {
            return "this build uses the development state root \(store.root), "
                + "not an installed SentryScreen"
        }
        return nil
    }

    private func makeUninstallGate() -> UninstallGate {
        UninstallGate(log: log)
    }

    /// The row. Reachable ONLY from an administrator session — the row does
    /// not exist otherwise (`UISettingsPanelView.remove`), so this is the
    /// second half of one gate, not a second policy.
    func beginRemove(from origin: Layer = .settings) {
        guard removalAllowed() else {
            // Not reachable from the sheet (the row does not exist), so a
            // call that gets here is a script or a bug: refuse loudly.
            log("uninstall", "stage=offered REFUSED: not an administrator session "
                + "(\(AdminCheck.currentUserLabel())) — the removal row is not offered here")
            return
        }
        removeMessage = nil
        removeStage = .idle
        removeChoice = Uninstall.Choice()
        returnLayer = origin
        layer = .remove
        log("uninstall", "stage=offered \(AdminCheck.currentUserLabel()) opened the removal confirmation")
    }

    func cancelRemove() {
        guard uninstallGate?.inFlight != true else {
            log("uninstall", "cancel ignored: the removal is already running")
            return
        }
        removeMessage = nil
        removeStage = .idle
        layer = returnLayer
        log("uninstall", "stage=cancelled at the confirmation — nothing was changed")
    }

    /// The popover footer's "Uninstall SentryScreen…", drawn in every popover
    /// state (owner 2026-10-16: someone stuck in a bug, such as a permission
    /// loop, must always be able to remove the app). The parent PIN is asked
    /// first when one is set; then the same card and Uninstaller as Settings.
    func beginUninstall() {
        guard store.parentPIN != nil else { beginRemove(from: .none); return }
        requirePIN(UninstallCopy.pinConfirmation) { [weak self] in
            self?.beginRemove(from: .none)
        }
    }

    /// The Setup window's "Uninstall SentryScreen…". That window has no PIN
    /// keypad, so a set PIN is asked for in a plain alert and checked by the
    /// same `PinGate` (same lockout). Then the Uninstaller runs with the
    /// default choice (complete removal); its admin prompt is the last step.
    func uninstallFromSetupWindow() {
        guard store.parentPIN != nil else { startSetupWindowRemoval(); return }
        let alert = NSAlert()
        alert.messageText = UninstallCopy.anywhereTitle
        alert.informativeText = UninstallCopy.pinConfirmation
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Parent PIN"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: UninstallCopy.cancelLabel)
        guard alert.runModal() == .alertFirstButtonReturn else {
            log("uninstall", "stage=cancelled at the setup-window PIN prompt — nothing was changed")
            return
        }
        gate.attempt(field.stringValue) { [weak self] result in
            guard let self else { return }
            let refusal: String
            switch result {
            case .success(.ok), .success(.noPin):
                startSetupWindowRemoval()
                return
            case .success(.wrong(let remaining)):
                refusal = "Wrong PIN. \(remaining) attempt\(remaining == 1 ? "" : "s") left."
            case .success(.locked):
                refusal = lockedMessage() ?? "Too many attempts. Try again later."
            case .failure(let error):
                refusal = "\(error)"
            }
            log("uninstall", "stage=refused at the setup-window PIN prompt: \(refusal)")
            let notice = NSAlert()
            notice.messageText = UninstallCopy.anywhereTitle
            notice.informativeText = refusal
            notice.runModal()
        }
    }

    private func startSetupWindowRemoval() {
        removeMessage = nil
        removeStage = .idle
        removeChoice = Uninstall.Choice()
        log("uninstall", "stage=offered \(AdminCheck.currentUserLabel()) chose Uninstall from the setup window")
        confirmRemove()
        if let removeMessage { log("uninstall", "stage=setup-window \(removeMessage)") }
    }

    /// Administrator authority, then the script. The
    /// PIN is deliberately NOT asked for here: it is not the authority for
    /// removing a parental control (see `Uninstall`).
    func confirmRemove() {
        guard removalAllowed() else {
            log("uninstall", "stage=script REFUSED: not an administrator session "
                + "(\(AdminCheck.currentUserLabel())) — nothing ran")
            return
        }
        // A dev build and the UI E2E driver run the SAME view and the same
        // controls, and the script this would run is the INSTALLED one — so
        // without this a `--ui-demo` tap, or an E2E script exercising the
        // confirm button, would put a real administrator prompt on the
        // screen and remove the SentryScreen installed on the machine
        // running the test. Suppressed loudly (the sheet says why), never
        // silently. `Uninstall.override` set ⇒ a selftest is driving, which
        // runs no script at all.
        if Uninstall.override == nil, let why = removalSuppressedReason {
            removeMessage = UninstallCopy.suppressed(why)
            log("uninstall", "stage=script SUPPRESSED: \(why) — nothing ran")
            return
        }
        let gate = uninstallGate ?? makeUninstallGate()
        uninstallGate = gate
        gate.onStage = { [weak self] stage in
            guard let self else { return }
            removeStage = stage
            if case let .done(outcome) = stage {
                switch outcome {
                case .removed, .handedOff:
                    // Handoff is not removal success. The independent worker
                    // owns the final result; keep this sheet in closing state.
                    removeMessage = nil
                case let .cancelled(why):
                    removeMessage = UninstallCopy.cancelledNotice
                    _ = why
                case let .failed(code, message):
                    removeMessage = UninstallCopy.failure(code: code, message: message)
                }
            }
        }
        gate.begin(removeChoice)
    }

    /// Opens a parent-facing https link in the default browser. Under the UI
    /// driver it only logs — an E2E tap must not open Safari on the shared
    /// desktop. A failed open is loud, never silent: the button promised
    /// something.
    static func openLink(_ url: URL, what: String, log: (String) -> Void) {
        guard UIDriver.scriptPath == nil else {
            log("open \(what) \(url.absoluteString) [suppressed under UI driver]")
            return
        }
        if NSWorkspace.shared.open(url) {
            log("opened \(what) \(url.absoluteString)")
        } else {
            log("FAILED to open \(what) \(url.absoluteString) — open it by hand")
        }
    }

    // MARK: Gate

    /// The one wrapper (Addendum 6F). No PIN set ⇒ the set-PIN layer opens
    /// first and `body` runs on save (§4.3: until a PIN exists no mutation is
    /// possible, including by someone who is not the parent).
    func requirePIN(
        _ confirmation: String, note: String? = nil, returnTo: Layer = .none,
        onDrop: (() -> Void)? = nil,
        _ body: @escaping () -> Void
    ) {
        writeError = nil
        returnLayer = returnTo
        let replaced = pending?.onDrop
        pending = Pending(confirmation: confirmation, note: note, body: body, onDrop: onDrop)
        replaced?()
        if store.parentPIN == nil {
            newPin = ""
            confirmPin = ""
            setPinError = nil
            layer = .setPin
            return
        }
        if let until = unlockedUntil, until > Date() {
            pending = nil
            layer = returnTo
            body()
            return
        }
        pinEntry = ""
        pinError = lockedMessage()
        layer = .pin
        startLockTimer()
    }

    /// Opens the set-PIN layer with no pending mutation (the `ui.status.nopin`
    /// row, and Change PIN… once the current PIN has verified).
    func beginSetPin(returnTo: Layer = .none) {
        writeError = nil
        returnLayer = returnTo
        let dropped = pending?.onDrop
        pending = nil
        dropped?()
        newPin = ""
        confirmPin = ""
        setPinError = nil
        layer = .setPin
    }

    /// Spec §9.4: Change PIN… requires the CURRENT PIN, then the set-PIN
    /// layer. It goes through the one `requirePIN` wrapper like every other
    /// mutation (Addendum 6F) — so a wrong current PIN counts toward the same
    /// lockout — and `saveNewPin` then replays the verified PIN through
    /// `PinGate.setPin(_:current:)` rather than writing behind the gate's back.
    func beginChangePin() {
        // No PIN yet: there is nothing to verify, and routing through
        // requirePIN would open the set-PIN layer as the GATE and then run
        // the pending body — a second, empty sheet titled "Change PIN",
        // which reads exactly like the save did not take (MEASURED
        // 2026-08-22: settings-changepin.txt failed on this before the
        // guard).
        guard store.parentPIN != nil else {
            beginSetPin(returnTo: .settings)
            return
        }
        requirePIN("Change the PIN for this Mac.", returnTo: .settings) { [weak self] in
            self?.beginSetPin(returnTo: .settings)
        }
    }

    func beginPINRecovery() {
        let recover = onForgotPIN
        lock()
        recover?()
    }

    func beginProtectionRepair() {
        let repair = onRepairProtection
        lock()
        repair?()
    }

    // MARK: Settings panel and confirmations (spec §9.4, §9.5)

    func openSettings() {
        writeError = nil
        settingsTab = nil
        moreSettingsOpen = false
        layer = .settings
        returnLayer = .none
    }

    func closeSettings() {
        layer = .none
        returnLayer = .none
        // A notice never outlives the sheet it was shown in.
        diagnosticsDraft = nil
        diagnostics?.clearSendNotice()
    }

    /// Puts a destructive confirmation in front of `body` (spec §9.4 hide
    /// icon, §9.5 turn off). Cancel returns to `from` with `body` dropped.
    func confirm(_ spec: UIConfirm, from: Layer, _ body: @escaping () -> Void) {
        writeError = nil
        returnLayer = from
        confirmBody = body
        layer = .confirm(spec)
    }

    func cancelConfirm() {
        confirmBody = nil
        layer = returnLayer
    }

    func acceptConfirm() {
        let run = confirmBody
        confirmBody = nil
        // `run` opens the PIN layer itself (every mutation is gated), so the
        // layer is left to it rather than reset here.
        run?()
    }

    /// Popover closed, or the parent cancelled: drop the unlock window, any
    /// pending mutation, and any derivation still in flight. Cancel is a real
    /// abort, not a repaint — see `epoch`.
    func lock() {
        epoch &+= 1
        layer = .none
        let dropped = pending?.onDrop
        pending = nil
        dropped?()
        returnLayer = .none
        confirmBody = nil
        diagnosticsDraft = nil
        diagnostics?.clearSendNotice()
        verifiedPin = nil
        pinEntry = ""
        newPin = ""
        confirmPin = ""
        pinError = nil
        setPinError = nil
        unlockedUntil = nil
        // The dropped completion will never clear this, so a close/reopen
        // mid-derivation must not leave the field disabled forever.
        busy = false
        stopLockTimer()
    }

    /// Cancel is a real abort (the unlock window and any in-flight
    /// derivation die with it — see `epoch`), but it must not also throw the
    /// parent out of the settings panel they were working in, so the layer
    /// they came from is restored after the reset.
    func cancelLayer() {
        let back = returnLayer
        lock()
        layer = back
    }

    /// Text of the pending action, for the layer's subtitle.
    var pendingConfirmation: String? { pending?.confirmation }
    var pendingNote: String? { pending?.note }

    // MARK: PIN entry

    /// Lockout deadline in force, or nil.
    var lockedUntil: Date? { gate.lockedUntil() }

    /// `Try again in 4:37.` — the countdown §4.1 requires. One wording, in
    /// `PinGate.lockoutMessage`, shared with `PinGate.Refused`.
    func lockedMessage() -> String? {
        guard let until = lockedUntil else { return nil }
        return PinGate.lockoutMessage(until: until)
    }

    /// Shown once the lockout has elapsed, replacing the countdown. OWNER
    /// 2026-08-22 live test: the countdown stalled at "0:01" after the 5 min
    /// because the tick kept the last message when lockedMessage() went nil.
    static let lockEndedMessage = "You can try again now."

    var canSubmitPIN: Bool { !busy && lockedUntil == nil && UIPin.isValidFormat(pinEntry) }

    func submitPIN() {
        guard canSubmitPIN else { return }
        busy = true
        pinError = nil
        let issued = epoch
        // Captured BEFORE the derivation: the completion clears `pinEntry`
        // before it reaches the success case, so reading it there would hand
        // Change PIN… an empty current PIN — which PinGate would count as a
        // wrong attempt against the parent's own lockout budget.
        let entered = pinEntry
        gate.attempt(pinEntry) { [weak self] result in
            guard let self else { return }
            guard issued == epoch else {
                // The counters PinGate.settle wrote still stand (a wrong PIN
                // cancelled mid-derivation still counts — fail toward
                // protection); only the unlock window is refused.
                log("pin", "attempt settled after cancel — unlock window NOT opened")
                return
            }
            busy = false
            pinEntry = ""
            switch result {
            case .failure(let error):
                // A counter that could not be persisted is refused, not
                // counted in memory (PinGate.attempt): say so rather than
                // pretending the PIN was wrong.
                pinError = "\(error)"
            case .success(.ok):
                unlockedUntil = Date().addingTimeInterval(Self.unlockWindowSecs)
                verifiedPin = entered
                let run = pending?.body
                pending = nil
                layer = returnLayer
                stopLockTimer()
                run?()
            case .success(.wrong(let remaining)):
                pinError = "Wrong PIN. \(remaining) attempt\(remaining == 1 ? "" : "s") left."
            case .success(.locked):
                pinError = lockedMessage()
            case .success(.noPin):
                // Reachable only if the file lost its PIN between the gate
                // check and here; send the parent where they can fix it.
                beginSetPin()
            }
        }
    }

    // MARK: Set PIN

    var canSavePin: Bool { !busy && !newPin.isEmpty && !confirmPin.isEmpty }

    func saveNewPin() {
        guard canSavePin else { return }
        guard newPin == confirmPin else {
            setPinError = "Those PINs do not match."
            return
        }
        guard UIPin.isValidFormat(newPin) else {
            setPinError = "Use \(UIPin.digits.lowerBound) to \(UIPin.digits.upperBound) digits, numbers only."
            return
        }
        busy = true
        setPinError = nil
        // `current: nil` is accepted only while no PIN is set (PinGate
        // enforces that, not this call site); Change PIN… replays the PIN
        // this unlock window was opened with, so a replacement still goes
        // through the gate's own current-PIN check. A missing one surfaces
        // as PinGate.CurrentRequired in `setPinError` rather than a silent
        // overwrite.
        let issued = epoch
        let saved = newPin
        gate.setPin(newPin, current: store.parentPIN == nil ? nil : verifiedPin) { [weak self] error in
            guard let self else { return }
            guard issued == epoch else {
                // PinGate writes the record on its own main hop, before this
                // closure runs, so a cancel this late cannot un-write it —
                // and there is no `setPinError` on screen to carry a failure.
                // Say both out loud rather than swallow either.
                log("pin", "set-PIN settled after cancel — unlock window NOT opened; "
                    + (error.map { "PIN NOT changed: \($0)" } ?? "the new PIN WAS written"))
                return
            }
            busy = false
            if let error {
                setPinError = "\(error)"
                return
            }
            newPin = ""
            confirmPin = ""
            // Setting a PIN is itself proof of the parent, so it opens the
            // unlock window: §4.3's "on save, the mutation proceeds".
            unlockedUntil = Date().addingTimeInterval(Self.unlockWindowSecs)
            verifiedPin = saved
            let run = pending?.body
            pending = nil
            layer = returnLayer
            run?()
        }
    }

    // MARK: Mutations

    func pause(_ preset: PausePreset) {
        requirePIN(preset.confirmation, note: Self.machineWideNote) { [weak self] in
            guard let self else { return }
            let now = Date()
            let by = AdminCheck.currentUserLabel()
            let next: PauseState
            if let secs = preset.seconds {
                next = .timed(until: now.addingTimeInterval(secs),
                    untilUptime: BootSession.uptime() + secs, by: by, at: now)
            } else {
                // A missing boot id would read as "expired" the instant it
                // was written (PauseState.effectiveUntil fails toward
                // protection), so refuse loudly rather than write a pause
                // that silently does nothing.
                guard let session = BootSession.uuid else {
                    writeError = "cannot pause until restart: kern.bootsessionuuid is unavailable "
                        + "on this Mac — use a timed pause"
                    return
                }
                next = .untilRestart(bootSession: session, by: by, at: now)
            }
            write { $0.pause = next }
        }
    }

    /// No PIN (review 2026-09-29, item 12): turning protection back on is
    /// the safe direction, so anyone at an admin session may do it. Checked:
    /// nothing in the tamper ledger, the watchdog or PanicAuth keys on a
    /// resume; a standard (child) session draws no Resume button and cannot
    /// write settings.json (664 root:admin) anyway.
    ///
    /// Also ends this session's panic pause (owner 2026-09-29, plan §6 item
    /// 3): the pipeline owns that deadline, so the call goes through
    /// `endPanicPause`, wired by AppDelegate. A panic-only pause leaves
    /// settings.json untouched.
    func resume() {
        endPanicPause()
        if store.settings.pause != .none { write { $0.pause = .none } }
    }

    /// Set by AppDelegate to `Pipeline.endPanicPause`. A no-op where there
    /// is no pipeline (`--ui-demo`, the self-tests).
    var endPanicPause: () -> Void = {}

    /// Spec §9.5 / Addendum 6A: `Turn off protection…` IS a pause with
    /// `mode: untilRestart`, behind the confirmation copy and then the PIN.
    /// It replaces Quit deliberately — a Quit in a watchdog-supervised agent
    /// is a lie, the process is back inside 60 s.
    /// Spec §9.4. Turning the icon OFF names the reveal path before it takes
    /// effect; turning it back on is an ordinary gated write.
    func setShowMenuBarIcon(_ show: Bool) {
        guard show else {
            confirm(.hideIcon, from: .settings) { [weak self] in
                self?.requirePIN("Hide the SentryScreen menu bar icon.", returnTo: .settings) {
                    [weak self] in self?.write { $0.showMenuBarIcon = false }
                }
            }
            return
        }
        requirePIN("Show the SentryScreen icon in the menu bar.", returnTo: .settings) { [weak self] in
            self?.write { $0.showMenuBarIcon = true }
        }
    }

    /// "Review a diagnostic report…": behind the parent PIN when one is set,
    /// then the review layer, where only Send reaches the network.
    func reviewDiagnosticReport() {
        guard store.parentPIN != nil else {
            openDiagnosticReview()
            return
        }
        requirePIN("Review a diagnostic report before sending it.", returnTo: .settings) { [weak self] in
            self?.openDiagnosticReview()
        }
    }

    private func openDiagnosticReview() {
        guard let agent = diagnostics else { return }
        writeError = nil
        diagnosticsDraft = nil
        layer = .diagnosticsReview
        let issued = epoch
        agent.prepare { [weak self] draft in
            guard let self, issued == epoch, layer == .diagnosticsReview else { return }
            guard let draft else {
                layer = .settings
                writeError = DiagnosticsCopy.buildFailed
                return
            }
            diagnosticsDraft = draft
        }
    }

    func cancelDiagnosticReview() {
        diagnosticsDraft = nil
        layer = .settings
    }

    /// The owner pressed Send on the review: the report goes once.
    func sendDiagnosticReport() {
        guard let draft = diagnosticsDraft, layer == .diagnosticsReview else { return }
        diagnosticsDraft = nil
        layer = .settings
        diagnostics?.send(draft)
    }

    func setPolicy(_ mode: PolicyMode) {
        requirePIN("Set sensitivity to \(mode.displayName).", returnTo: .settings) { [weak self] in
            self?.write { $0.policyOverride = mode }
        }
    }

    /// TUNING TOOL: the Developer tab's model (UIDevTuning.swift). Set by
    /// AppDelegate.startSettings and the demo; nil in unit-style tests.
    var devTuning: UIDevTuning?
    static let devTuningUnavailable = "Developer tuning is not wired in this host."

    /// A slider release, a typed value or the toggle: the draft goes to
    /// parent/tuning.json behind the PIN like every other parent/ write
    /// (Addendum 6F). One PIN unlocks the usual window, so a tuning session
    /// types it once.
    func commitDevTuning() {
        requirePIN("Apply the curtain tuning.", returnTo: .settings) { [weak self] in
            self?.devTuning?.writeFile()
        }
    }

    /// "Reset to shipped defaults": removes the file; the agent returns to
    /// the launch policy and logs it.
    func resetDevTuning() {
        requirePIN("Reset the curtain tuning to the launch policy.", returnTo: .settings) { [weak self] in
            self?.devTuning?.reset()
        }
    }

    /// TUNING TOOL: the Detection view (DetectionViewController.swift),
    /// shared by Settings › Developer and the popover row. AppDelegate
    /// attaches it to each pipeline; in a host with none (`--ui-demo`) it
    /// renders its controls and refuses to turn on, by name.
    let detectionView = DetectionViewController()

    /// Turning the view ON — either mode — is behind the PIN (D5): Detections
    /// only turns protection off. The safe directions never ask: off, and
    /// Detections only → Outline over covers (covers come back).
    func selectDetectionViewMode(_ mode: DetectionViewMode, returnTo: Layer) {
        guard mode != .off else {
            detectionView.turnOff(reason: .user)
            return
        }
        guard mode != detectionView.mode else { return }
        if detectionView.mode == .detectionsOnly, mode == .outlineOverCovers {
            detectionView.turnOn(mode)
            return
        }
        requirePIN(DetectionViewCopy.pinTurnOn(mode),
            note: mode == .detectionsOnly ? DetectionViewCopy.pinTurnOnNote : nil,
            returnTo: returnTo) { [weak self] in
            self?.detectionView.turnOn(mode)
        }
    }

    func renewDetectionView(returnTo: Layer) {
        requirePIN(DetectionViewCopy.pinRenew, returnTo: returnTo) { [weak self] in
            self?.detectionView.renew()
        }
    }

    /// Synthetic boxes make real covers appear, so adding them asks for the
    /// PIN; removing them does not.
    func setDetectionViewSynthetic(_ on: Bool) {
        guard on else {
            detectionView.setSynthetic(false)
            return
        }
        requirePIN(DetectionViewCopy.pinSynthetic, returnTo: .settings) { [weak self] in
            self?.detectionView.setSynthetic(true)
        }
    }

    func turnOffDetectionView() { detectionView.turnOff(reason: .user) }

    func snapshotDetectionView() { detectionView.snapshot() }

    /// Every write goes through here: a failure names the path and the errno
    /// in the UI (§3.4) instead of vanishing.
    private func write(_ change: (inout UISettings) -> Void) {
        do {
            try store.mutate(change)
            writeError = nil
        } catch {
            writeError = "\(error)"
        }
    }

    // MARK: Lockout countdown

    private func startLockTimer() {
        guard lockTimer == nil else { return }
        // 1 Hz, and only while the PIN layer is up: the countdown is the only
        // thing in the popover that changes without an event behind it.
        lockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            clockTick &+= 1
            if layer == .pin, pinError?.hasPrefix("Too many") == true {
                pinError = lockedMessage() ?? Self.lockEndedMessage
            }
        }
    }

    private func stopLockTimer() {
        lockTimer?.invalidate()
        lockTimer = nil
    }
}

// MARK: - PIN prompt (spec §4, §4.1)

struct UIPinPromptView: View {
    @ObservedObject var actions: UIActions
    @FocusState private var focused: Bool

    /// One predicate for both the SwiftUI `.disabled` and the registry's
    /// `enabled` closure — two mechanisms that drift the moment the
    /// condition is written twice.
    private var locked: Bool { actions.lockedUntil != nil }

    var body: some View {
        UISection {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Enter your PIN").uiFont(.headline)
                } icon: {
                    Image(systemName: locked ? UISymbol.lockedOut : UISymbol.lock)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                }
                if let confirmation = actions.pendingConfirmation {
                    Text(confirmation)
                        .uiFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = actions.pendingNote {
                    Text(note)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Deliberately NO `.uiFont`: a PIN field inherits AppKit's own
                // 13 pt field font, so the typed digits do not follow
                // `\.uiTextScale`. MEASURED 2026-09-07:
                // adding `.uiFont(.body)` — nominally the same 13 pt —
                // moved `pin-setup.png` at the DEFAULT size (0.004% of pixels),
                // and the brief for this change is that the shipped design
                // does not move. Every label around the field does scale.
                SecureField("PIN", text: $actions.pinEntry)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .disabled(locked || actions.busy)
                    .onSubmit { actions.submitPIN() }
                    .uiControl("ui.pin.field", kind: .field,
                        read: { actions.pinEntry },
                        setText: { actions.pinEntry = $0 },
                        enabled: { actions.lockedUntil == nil && !actions.busy })
                // `canSubmitPIN` requires `UIPin.isValidFormat`, so
                // Return on three digits does nothing and Unlock stays grey.
                // The onboarding field has said what it accepts since it
                // shipped; this one said nothing. Hidden while an error is up
                // so the prompt never shows two captions at once.
                if actions.pinError == nil {
                    Text(UIPin.formatCaption)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiControl("ui.pin.format", kind: .text, read: { UIPin.formatCaption })
                }
                if let error = actions.pinError {
                    UIInlineMessage(text: error, symbol: UISymbol.error, tint: .systemRed)
                        .uiControl("ui.pin.error", kind: .text, read: { actions.pinError ?? "" })
                }
                HStack(spacing: 8) {
                    UIOnboardingForgotPINButton { actions.beginPINRecovery() }
                    if actions.busy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking your PIN")
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { actions.cancelLayer() }
                        .keyboardShortcut(.cancelAction)
                        .uiControl("ui.pin.cancel", kind: .button, read: { "Cancel" },
                            activate: { actions.cancelLayer() })
                    Button("Unlock") { actions.submitPIN() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!actions.canSubmitPIN)
                        .uiControl("ui.pin.submit", kind: .button, read: { "Unlock" },
                            activate: { actions.submitPIN() },
                            enabled: { actions.canSubmitPIN })
                }
            }
        }
        // §9.7: an accessory app's popover does not take keyboard focus by
        // default. UIStatusItem makes the window key on show; this puts the
        // caret where the parent expects it.
        .onAppear { focused = true }
    }
}

// MARK: - Set a PIN (spec §4.3)

struct UISetPinView: View {
    @ObservedObject var actions: UIActions
    /// The two fields are a chain, exactly as the wizard's are
    /// (UIOnboardingPINSetupView): Return in "New PIN" moves the caret to
    /// "Repeat PIN" instead of dead-ending, and Return there saves. A Bool
    /// could only ever focus the first one.
    enum Field: Hashable { case pin, confirmation }
    @FocusState private var focused: Field?

    var body: some View {
        UISection {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    // Replacing a PIN and setting the first one are the same
                    // fields and the same save path; only the promise the
                    // title makes is different.
                    Text(actions.store.parentPIN == nil ? "Set a PIN" : "Change PIN")
                        .uiFont(.headline)
                } icon: {
                    // MEASURED 2026-08-22: `lock.badge.plus` does not exist in
                    // this macOS build and rendered as an empty slot. Names
                    // live in UISymbol, which --ui-selftest resolves.
                    Image(systemName: UISymbol.setPin)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                }
                Text(Self.body)
                    .uiFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let confirmation = actions.pendingConfirmation {
                    Text("Next: " + confirmation)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 6) {
                    SecureField("New PIN", text: $actions.newPin)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .focused($focused, equals: .pin)
                        .disabled(actions.busy)
                        .onSubmit { focused = .confirmation }
                        .uiControl("ui.sheet.setpin.field1", kind: .field,
                            read: { actions.newPin },
                            setText: { actions.newPin = $0 },
                            enabled: { !actions.busy })
                    SecureField("Repeat PIN", text: $actions.confirmPin)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .focused($focused, equals: .confirmation)
                        .disabled(actions.busy)
                        .onSubmit { actions.saveNewPin() }
                        .uiControl("ui.sheet.setpin.field2", kind: .field,
                            read: { actions.confirmPin },
                            setText: { actions.confirmPin = $0 },
                            enabled: { !actions.busy })
                }
                if let error = actions.setPinError {
                    UIInlineMessage(text: error, symbol: UISymbol.error, tint: .systemRed)
                        .uiControl("ui.sheet.setpin.error", kind: .text, read: { actions.setPinError ?? "" })
                }
                HStack(spacing: 8) {
                    if actions.busy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving your PIN")
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { actions.cancelLayer() }
                        .keyboardShortcut(.cancelAction)
                        .uiControl("ui.sheet.setpin.cancel", kind: .button, read: { "Cancel" },
                            activate: { actions.cancelLayer() })
                    Button("Save PIN") { actions.saveNewPin() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!actions.canSavePin)
                        .uiControl("ui.sheet.setpin.save", kind: .button, read: { "Save PIN" },
                            activate: { actions.saveNewPin() },
                            enabled: { actions.canSavePin })
                }
            }
        }
        .onAppear { focused = .pin }
        // A mismatch or a bad format puts the caret back where the correction
        // is made, instead of leaving it in the field that was already right.
        .onChange(of: actions.setPinError) { _, error in
            if error != nil { focused = .pin }
        }
    }

    /// Says what the PIN is for and what the field accepts, in the family's
    /// words. The recovery path (§4.3 forgotten PIN) is README material, not
    /// a line that belongs on a 320 pt popover.
    ///
    /// `UIPin.purpose` is the one sentence all three surfaces use:
    /// this sheet said "protects pause and sensitivity", which named two of
    /// the seven things the PIN actually gates.
    static var body: String { UIPin.purposeWithFormat }
}

// MARK: - Settings panel (spec §9.4)

/// The §9.4 rows, drawn as one grouped card the way macOS Settings draws a
/// section: title on the left, state on the right, an explanatory caption
/// under the row it explains. Inline over the popover's sections, never a
/// `.sheet` — see the presentation receipt at the top of this file.
/// The pages of the Settings sheet: General (the old App page folds shut
/// under it as "More settings") and Developer. Every control of General is
/// on screen without scrolling at the default text size.
enum UISettingsTab: String, CaseIterable {
    case general
    /// The live curtain-tuning page (UIDevTuning.swift).
    case developer

    var label: String {
        switch self {
        case .general: return "General"
        case .developer: return "Developer"
        }
    }

    /// Sub-id under `ui.settings.tab`, one button per page so a script taps
    /// the page it needs by name (`tap ui.settings.tab.developer`).
    var controlID: String { "ui.settings.tab.\(rawValue)" }

    /// Where the sheet opens.
    static let initial = UISettingsTab.general
}

struct UISettingsPanelView: View {
    @ObservedObject var state: UIState
    @ObservedObject var actions: UIActions
    @ObservedObject var activity: UIActivity
    @Environment(\.uiTextScale) private var textScale

    private var tab: UISettingsTab {
        actions.settingsTab ?? UISettingsTab.initial
    }

    /// The sheet's own scroll viewport (2026-09-11). Only the
    /// SELECTED PAGE scrolls: the page switcher, a write error and Done are
    /// pinned above and below it.
    ///
    /// MEASURED 2026-09-11: with
    /// the switcher, the "Settings" label and Done inside the scroll document
    /// the App page was 462 pt in a 410 pt viewport — 52 pt, including Remove
    /// and Done, below a fold with no scroll cue. That is the same failure the
    /// three-page sheet was built to end (`UISettingsTab`). Pinning the chrome
    /// takes ~80 pt out of the document, so every page fits its viewport at
    /// the default text size again; `UIDriver.foldBudget` is the tripwire.
    ///
    /// RECEIPT STALE: the 229 / 283 / 384 pt page heights above were taken
    /// before General became two described rows and before the one PIN note
    /// joined Done in the pinned footer.
    var body: some View {
        VStack(alignment: .leading, spacing: UIMetrics.labelGap) {
            // Settings-General: Shantell 19 pt.
            Text(Self.title)
                .uiDisplayFont(size: 19)
                .foregroundStyle(SentryColor.ink)
                .accessibilityAddTraits(.isHeader)
            tabs
            // Pin the opening page on first render.
            .onAppear { if actions.settingsTab == nil { actions.settingsTab = tab } }
            ScrollView {
                ScrollViewReader { proxy in
                    // Same spacing the sections had when they were children
                    // of the outer stack, so the drawn page is unchanged.
                    VStack(alignment: .leading, spacing: UIMetrics.labelGap) {
                        page
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear { UIScrollAnchors.shared.proxy = proxy }
                    .onDisappear { UIScrollAnchors.shared.proxy = nil }
                    // Page height, for the driver's `assertfits` fold report.
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: UIScrollDocumentSizeKey.self, value: proxy.size)
                    })
                    // Where the page's bottom is, for the "More below" cue.
                    .background(GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.frame(in: .named(Self.scrollSpace)).maxY,
                            initial: true) { _, maxY in pageBottom = maxY }
                    })
                }
            }
            .coordinateSpace(name: Self.scrollSpace)
            .frame(maxHeight: UIMetrics.settingsViewportMaxHeight(scale: textScale))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: UIScrollViewportSizeKey.self, value: proxy.size)
                    .onChange(of: proxy.size.height, initial: true) { _, h in viewportHeight = h }
            })
            // Review 2026-09-29 (item 7): a page taller than its viewport
            // says so. The cue shows while more than `moreBelowSlack` of the
            // page is under the fold and is gone once the bottom is reached.
            .overlay(alignment: .bottom) {
                if pageBottom - viewportHeight > Self.moreBelowSlack {
                    moreBelowCue
                }
            }
            // Pinned, not scrolled: a settings write that failed is the one
            // line on this sheet a parent must not be able to scroll past.
            if let error = actions.writeError {
                UIInlineMessage(text: error, symbol: UISymbol.writeError, tint: .systemRed)
            }
            UISettingsDashedRule()
                .padding(.top, 4)
            // One PIN note for the whole sheet, by Done (Settings-General):
            // it replaces a line under each control. Neutral: it makes no
            // claim about which change asks, only that changes do.
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: UISymbol.lock)
                        .uiFont(.caption)
                        .accessibilityHidden(true)
                    Text(Self.pinNote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .uiFont(.caption)
                .foregroundStyle(SentryColor.muted)
                .uiControl("ui.settings.pinnote", kind: .text, read: { Self.pinNote })
                Spacer(minLength: 0)
                // Outlined, not mustard: no page of Settings has a primary.
                Button("Done") { actions.closeSettings() }
                    .buttonStyle(UISettingsOutlineButtonStyle(
                        minHeight: UISettingsLook.doneHeight,
                        horizontalPadding: UISettingsLook.doneInset))
                    .keyboardShortcut(.defaultAction)
                    .uiControl("ui.settings.close", kind: .button, read: { "Done" },
                        activate: { actions.closeSettings() })
            }
            .padding(.top, 2)
        }
    }

    static let title = "Settings"
    static let scrollSpace = "ui.settings.scroll"
    /// A page this close to fitting reads as fitting: 4 pt is under one line
    /// of `.caption` padding, so the cue never flickers on rounding. ASSUMED,
    /// not measured: no installed page has been seen within 4 pt of fitting.
    static let moreBelowSlack: CGFloat = 4
    static let moreBelowLabel = "More below"
    @State private var pageBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    /// A paper fade and a small "More below" tag over the viewport's
    /// bottom edge; not a control, so taps pass through to the page.
    private var moreBelowCue: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [SentryColor.paper.opacity(0), SentryColor.paper],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
            HStack(spacing: 4) {
                Text(Self.moreBelowLabel)
                Image(systemName: UISettingsSymbol.disclosureOpen).accessibilityHidden(true)
            }
            .uiFont(.caption, weight: .semibold)
            .foregroundStyle(SentryColor.ink2)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .background(SentryColor.paper)
        }
        .allowsHitTesting(false)
        .uiControl("ui.settings.morebelow", kind: .text, read: { Self.moreBelowLabel })
    }
    /// Settings-General, verbatim.
    static let pinNote = "Changes ask for your PIN"

    /// The selected page's sections — everything that scrolls.
    @ViewBuilder private var page: some View {
        switch tab {
        case .general:
            // Sheet-local replacement for `UISensitivitySettingsSection`
            // (UIPopoverView.swift, outside this slice): the same ids and the
            // same `actions.setPolicy` path, drawn as two described rows.
            UISettingsSensitivitySection(state: state, actions: actions)
            UIActivitySettingsSection(activity: activity)
            moreSettingsToggle
            if actions.moreSettingsOpen { moreSettings }
        case .developer:
            if let tuning = actions.devTuning {
                UIDeveloperSettingsSection(state: state, actions: actions, tuning: tuning)
            } else {
                // A host that wired no model (unit-style tests): say so
                // rather than draw an empty page.
                UIInlineMessage(text: UIActions.devTuningUnavailable, symbol: UISymbol.warning, tint: .systemOrange)
                    .uiControl("ui.settings.developer.unavailable", kind: .text,
                        read: { UIActions.devTuningUnavailable })
            }
        }
    }

    /// Settings-General board, verbatim.
    static let moreTitle = "More settings"
    static let moreCaption = "PIN, menu bar icon, remove"

    /// The fold's header: an outlined row with a chevron. Closed, it carries
    /// the caption naming what is inside; open, only the title.
    private var moreSettingsToggle: some View {
        let open = actions.moreSettingsOpen
        let toggle = { [actions] in actions.moreSettingsOpen.toggle() }
        return Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .uiFont(.caption, weight: .bold)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.moreTitle).uiFont(.subheadline, weight: .semibold)
                    if !open {
                        Text(Self.moreCaption).uiFont(.caption).foregroundStyle(SentryColor.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(SentryColor.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: open ? 40 : 46)
            .contentShape(Rectangle())
            .overlay(UIPopoverShape.hand(12, 10, 13, 9).strokeBorder(SentryColor.controlBorder, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.moreTitle)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .uiControl("ui.settings.more", kind: .button,
            read: { [actions] in actions.moreSettingsOpen ? "open" : "closed" }, activate: toggle)
    }

    /// The old App page's rows, unchanged, under the fold.
    @ViewBuilder private var moreSettings: some View {
            UISection(padding: 0) {
                VStack(spacing: 0) {
                    changePIN
                    rowDivider
                    forgotPIN
                    rowDivider
                    startAtLogin
                    rowDivider
                    showIcon
                    rowDivider
                    version
                }
                .padding(.vertical, 4)
            }
            UIDiagnosticsSettingsSection(actions: actions)
            remove
    }

    /// The page switcher, drawn as the Settings-General board draws it: an
    /// ink-bordered slip with the selected page filled in ink. Owner-approved
    /// board (plan §2 Settings). Each segment takes an equal share of the
    /// PROPOSED width, so the row is laid out inside the content column (ASSUMED
    /// from SwiftUI layout; `assertfits` in the a11y-textsize scripts passed
    /// at 1.35x and 1.6x on macOS 27, test Mac, 2026-09-29);
    /// that is what the old NSSegmentedControl bridge got wrong on macOS 27.
    /// Labels shrink to fit rather than spill.
    private var tabs: some View {
        let sel = Binding<UISettingsTab>(
            get: { [actions, state] in actions.settingsTab ?? UISettingsTab.initial },
            set: { [actions] in actions.settingsTab = $0 })
        return UISettingsTabBar(selection: sel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.tabPickerLabel)
        .uiControl("ui.settings.tab", kind: .picker,
            read: { sel.wrappedValue.rawValue },
            setText: { if let t = UISettingsTab(rawValue: $0) { sel.wrappedValue = t } })
        .uiControl(UISettingsTab.general.controlID, kind: .button,
            read: { UISettingsTab.general.label }, activate: { sel.wrappedValue = .general })
        .uiControl(UISettingsTab.developer.controlID, kind: .button,
            read: { UISettingsTab.developer.label }, activate: { sel.wrappedValue = .developer })
    }

    /// VoiceOver's name for the page switcher.
    static let tabPickerLabel = "Settings page"

    private var rowDivider: some View {
        Divider().padding(.leading, UIMetrics.sectionPadding)
    }

    /// "Remove SentryScreen…" (SPEC §8.1(7); owner 2026-09-05).
    ///
    /// ABSENT — not disabled — outside an administrator session. A disabled
    /// row advertises the removal to the child it is protecting the family
    /// from and invites them to hunt for the way round it; a row that is not
    /// there says nothing. The same rule the status item itself follows
    /// (`main.swift`: a Standard session gets no status item at all).
    ///
    /// Last in the sheet because it is the
    /// end of the relationship with the app and nothing below it would be
    /// read afterwards.
    @ViewBuilder private var remove: some View {
        if state.isAdmin {
            UISection(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    UIListRow(label: UninstallCopy.row) { actions.beginRemove() }
                        .uiControl("ui.settings.remove", kind: .button,
                            read: { UninstallCopy.row },
                            activate: { actions.beginRemove() })
                    Text(Self.removeCaption)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, UIMetrics.sectionPadding)
                        .padding(.bottom, 8)
                        .uiControl("ui.settings.remove.caption", kind: .text,
                            read: { Self.removeCaption })
                }
                .padding(.vertical, 4)
            }
            .uiScrollAnchor("ui.settings.remove")
        }
    }

    // MARK: Rows

    private var changePIN: some View {
        UIListRow(label: Self.changePinLabel) { actions.beginChangePin() }
            .uiControl("ui.settings.changepin", kind: .button, read: { Self.changePinLabel },
                activate: { actions.beginChangePin() })
    }

    private var forgotPIN: some View {
        HStack {
            UIOnboardingForgotPINButton { actions.beginPINRecovery() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIMetrics.sectionPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Spec §9.4: NON-INTERACTIVE. A Toggle that cannot toggle would be a
    /// lie, so this row states the fact and says who owns it — the same
    /// shape macOS itself uses for a managed setting. Registered as `.text`
    /// with `enabled: false`, which is what `assertenabled … false` reads.
    private var startAtLogin: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Start at login")
                    .uiFont(.callout)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: UISymbol.managed)
                        .uiFont(.caption, weight: .semibold)
                        .accessibilityHidden(true)
                    Text(Self.managedText)
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
            }
            Text(Self.startAtLoginCaption)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, UIMetrics.sectionPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .uiControl("ui.settings.startatlogin", kind: .text,
            read: { "Start at login — " + Self.managedText },
            enabled: { false })
    }

    /// Spec §9.4. The row is DISABLED when ⌘⌥⌃S did not register: the
    /// confirmation's promise ("Press ⌘⌥⌃S to bring it back") is the only
    /// reason hiding is offered at all, and `armRevealHotkey` is deliberately
    /// non-fatal on a collision — so without this the parent hides the icon on
    /// a promise the build cannot keep, and the only way back is a sudo
    /// command named in a log they will never read. Disabled-with-a-reason
    /// rather than alternate copy: `UIConfirm.hideIcon` stays the spec's
    /// verbatim text, and the failure is stated where the decision is made.
    ///
    /// Only the hide direction is at stake, and it is the only reachable one:
    /// the panel needs an icon to open, so `showMenuBarIcon` is always true
    /// here.
    private var showIcon: some View {
        // One flag behind the SwiftUI `.disabled`, the caption and the
        // registry's `enabled` closure — three mechanisms that drift the
        // moment any of them derives the answer its own way.
        let canHide = state.revealHotkeyArmed
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Show menu bar icon")
                    .uiFont(.callout)
                Spacer(minLength: 8)
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { state.settings.showMenuBarIcon },
                    set: { actions.setShowMenuBarIcon($0) }))
                    // No mirror @State behind it: the binding reads the store's
                    // value, so a cancelled confirmation snaps the switch back by
                    // construction instead of needing an undo path.
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!canHide)
            }
            .frame(minHeight: UIMetrics.rowHeight(scale: textScale))
            if !canHide {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: UISymbol.warning)
                        .accessibilityHidden(true)
                    Text(Self.noRevealHotkeyCaption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
                // Its own id, like `ui.sensitivity.pinned`: the toggle's
                // `read()` is "on"/"off" and must stay that, so the reason a
                // control is disabled needs somewhere of its own to be
                // asserted. Registered only while it is on screen.
                .uiControl("ui.settings.showicon.nohotkey", kind: .text,
                    read: { Self.noRevealHotkeyCaption })
            }
        }
        .padding(.horizontal, UIMetrics.sectionPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiControl("ui.settings.showicon", kind: .toggle,
            read: { state.settings.showMenuBarIcon ? "on" : "off" },
            activate: { actions.setShowMenuBarIcon(!state.settings.showMenuBarIcon) },
            enabled: { state.revealHotkeyArmed })
    }

    /// Spec §9.4: the build, and nothing internal beside it. The model file
    /// name and the state-root path were rows here until 2026-09-07 (owner):
    /// they are developer facts, not parent facts.
    private var version: some View {
        HStack(spacing: 8) {
            Text("Version")
                .uiFont(.callout)
            Spacer(minLength: 8)
            Text(UIVersion.display)
                .uiFont(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, UIMetrics.sectionPadding)
        .frame(minHeight: UIMetrics.rowHeight(scale: textScale))
        .accessibilityElement(children: .combine)
        .uiControl("ui.settings.version", kind: .text,
            read: { UIVersion.display })
    }

    static let changePinLabel = "Change PIN…"
    /// Spec §9.4, verbatim.
    static let managedText = "Managed by the system"
    static let startAtLoginCaption = "SentryScreen is installed as a system LaunchAgent and "
        + "starts for every user at login. Removing it requires an administrator."
    /// Why hiding is unavailable. Names the cause (the key is taken) and the
    /// consequence (there would be no way back), which is exactly what the
    /// confirmation would otherwise have promised.
    /// `UIConfirm.revealKeys`, not `HotkeyCenter.revealKey.label`
    /// ("Cmd+Opt+Ctrl+S"): that label is the log's spelling, and this line
    /// has to read as the same key the confirmation names.
    /// Says what a parent needs before they press: the Mac's password, not the PIN.
    static let removeCaption = "Removing SentryScreen needs an administrator name and password."

    static let noRevealHotkeyCaption = "Another app owns \(UIConfirm.revealKeys), so a hidden icon could not be "
        + "brought back. Hiding is unavailable until that key is free."
}

// MARK: - Confirmation (spec §9.4 hide icon, §9.5 turn off)

/// One card for every destructive confirmation (Settings-Confirm board, with
/// the owner's revisions): the red mark and the title on ONE line, the spec's
/// copy under it split the way an NSAlert splits it, then Cancel and a red
/// confirm, centred. Deliberately NOT given `.defaultAction`: Return should
/// not be able to turn protection off. The card says nothing about the PIN
/// (owner revision: no "Asks for your PIN"); the PIN layer that follows says
/// what it is for.
///
/// The copy is UNCHANGED from `UIConfirm` (spec §9.4/§9.5 verbatim). The
/// board words some cards differently ("Hide the menu bar icon?", "Deactivate
/// this Mac?"); only the layout was approved, so those wordings are open
/// decisions, not edits made here.
struct UIConfirmView: View {
    @ObservedObject var actions: UIActions
    let spec: UIConfirm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                UISettingsConfirmMark(symbol: spec.symbol)
                Text(spec.title)
                    .uiFont(.headline)
                    .foregroundStyle(SentryColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(spec.body)
                .uiFont(.callout)
                .foregroundStyle(SentryColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                // Reads the WHOLE copy, title included: the assert that
                // guards this text must fail if either half drifts from
                // the spec.
                .uiControl(spec.noteID, kind: .text, read: { spec.copy })
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { actions.cancelConfirm() }
                    .buttonStyle(UISettingsOutlineButtonStyle(
                        minHeight: UISettingsLook.doneHeight, horizontalPadding: 16))
                    .keyboardShortcut(.cancelAction)
                    .uiControl(spec.cancelID, kind: .button, read: { "Cancel" },
                        activate: { actions.cancelConfirm() })
                Button(spec.confirmLabel) { actions.acceptConfirm() }
                    .buttonStyle(UISettingsDangerButtonStyle())
                    .uiControl(spec.confirmID, kind: .button, read: { spec.confirmLabel },
                        activate: { actions.acceptConfirm() })
                Spacer(minLength: 0)
            }
            // The confirm button's offset shadow is drawn outside its frame.
            .padding(.trailing, UISettingsLook.shadowRoom.width)
            .padding(.bottom, UISettingsLook.shadowRoom.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spec.copy)
    }
}

// MARK: - Removal confirmation (SPEC §8.1(7))

/// The one card between "Remove SentryScreen…" and the administrator prompt.
/// Same shape as `UIConfirmView` — red glyph, the copy, Cancel and a red
/// confirm — plus the two questions `packaging/uninstall.sh` accepts, and the
/// closing line that must be on screen BEFORE the script boots this agent out.
struct UIRemoveView: View {
    @ObservedObject var actions: UIActions

    private var running: Bool {
        switch actions.removeStage {
        case .closing: return true
        case .idle, .done: return false
        }
    }

    private var closing: Bool {
        switch actions.removeStage {
        case .closing, .done(.removed), .done(.handedOff): return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Same head as `UIConfirmView` (review 2026-09-29, item 11): the
            // site danger mark, not systemRed.
            HStack(alignment: .center, spacing: 12) {
                UISettingsConfirmMark(symbol: UISymbol.remove)
                Text(UninstallCopy.title)
                    .uiFont(.headline)
                    .foregroundStyle(SentryColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(UninstallCopy.body)
                .uiFont(.callout)
                .foregroundStyle(SentryColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                // Reads the WHOLE copy, title included: the assert that
                // guards this text must fail if either half drifts.
                .uiControl("ui.settings.remove.note", kind: .text,
                    read: { UninstallCopy.title + " " + UninstallCopy.body })
            deleteSettings
            // Permission cleanup always happens; it is a fact, not a switch
            // (review 2026-09-29, item 10: the locked-on toggle looked like
            // a choice the parent was refused).
            Text(UninstallCopy.resetPermissionsCaption)
                .uiFont(.caption)
                .foregroundStyle(SentryColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .uiControl("ui.settings.remove.permissions", kind: .text,
                    read: { UninstallCopy.resetPermissionsCaption })
            if closing {
                let line = UninstallCopy.closing
                UIInlineMessage(text: line,
                    symbol: UISymbol.remove, tint: .secondaryLabelColor)
                    .uiControl("ui.settings.remove.closing", kind: .text,
                        read: { line })
            }
            if let message = actions.removeMessage {
                // The script's own error text, verbatim and selectable so
                // it can be pasted into a support email.
                UIInlineMessage(text: message, symbol: UISymbol.writeError, tint: .systemRed)
                    .textSelection(.enabled)
                    .uiControl("ui.settings.remove.error", kind: .text, read: { message })
            }
            buttons
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(UninstallCopy.title)
    }

    /// One checkbox, "Also delete settings and PIN" (review 2026-09-29, item
    /// 10), ticked by default: complete removal stays the default, as it was
    /// with the radio pair. `ui.settings.remove.keep` keeps its old reading
    /// (the effective choice's label) so the removal scripts keep one id.
    private var deleteSettings: some View {
        let deleting = !actions.removeChoice.keepSettings
        let toggle = { actions.removeChoice.keepSettings.toggle() }
        return VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UICheckboxMark(on: deleting)
                    Text(UninstallCopy.deleteTickLabel)
                        .uiFont(.callout, weight: .semibold)
                        .foregroundStyle(SentryColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(running)
            .accessibilityLabel(UninstallCopy.deleteTickLabel)
            .accessibilityValue(deleting ? "checked" : "unchecked")
            .accessibilityAddTraits(.isToggle)
            Text(deleting ? UninstallCopy.deleteCaption
                : UninstallCopy.keepCaption)
                .uiFont(.caption)
                .foregroundStyle(SentryColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, UICheckboxMark.side + 8)
                // Its own id, so the caption is assertable.
                .uiControl("ui.settings.remove.keep.caption", kind: .text,
                    read: { actions.removeChoice.keepSettings
                        ? UninstallCopy.keepCaption : UninstallCopy.deleteCaption })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiControl("ui.settings.remove.keep", kind: .picker,
            read: { actions.removeChoice.keepSettings
                ? UninstallCopy.keepLabel : UninstallCopy.deleteLabel },
            activate: toggle,
            enabled: { !running })
    }

    /// Deliberately NOT given `.defaultAction`: Return must not be able to
    /// remove a parental control. Design buttons, as on every confirm card.
    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button(UninstallCopy.cancelLabel) { actions.cancelRemove() }
                .buttonStyle(UISettingsOutlineButtonStyle(
                    minHeight: UISettingsLook.doneHeight, horizontalPadding: 16))
                .keyboardShortcut(.cancelAction)
                .disabled(running)
                .uiControl("ui.settings.remove.cancel", kind: .button,
                    read: { UninstallCopy.cancelLabel },
                    activate: { actions.cancelRemove() },
                    enabled: { !running })
            Button(UninstallCopy.confirmLabel) { actions.confirmRemove() }
                .buttonStyle(UISettingsDangerButtonStyle())
                .disabled(running)
                .uiControl("ui.settings.remove.confirm", kind: .button,
                    read: { UninstallCopy.confirmLabel },
                    activate: { actions.confirmRemove() },
                    enabled: { !running })
            Spacer(minLength: 0)
        }
        .padding(.trailing, UISettingsLook.shadowRoom.width)
        .padding(.bottom, UISettingsLook.shadowRoom.height)
    }
}

/// A drawn checkbox: an 18 pt hand-cut square with a 2 pt ink edge, filled
/// ink with a paper check when on, empty when off — two states that differ in
/// fill, not only in a small glyph.
struct UICheckboxMark: View {
    static let side: CGFloat = UISettingsLook.radioSize
    let on: Bool

    var body: some View {
        let shape = UISettingsLook.field
        ZStack {
            shape.fill(on ? SentryColor.ink : Color.clear)
            shape.strokeBorder(SentryColor.controlBorder, lineWidth: UISettingsLook.borderWidth)
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(SentryColor.paper)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .accessibilityHidden(true)
    }
}

// MARK: - Shared

/// One-line inline message with a leading glyph: errors, warnings, notices.
/// `tint` is an NSColor semantic system color (§9.3 forbids literal RGB, not
/// the system's own adaptive palette).
struct UIInlineMessage: View {
    let text: String
    let symbol: String
    let tint: NSColor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(nsColor: tint))
                .accessibilityHidden(true)
            Text(text)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

extension PolicyMode {
    /// Picker label. The raw values (`standard`/`strict`) stay the machine
    /// vocabulary — settings.json, the `policy` log record and
    /// `assert ui.sensitivity strict` all read those.
    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .strict: return "Strict"
        }
    }
}

/// Settings-General board tab row: 2 pt ink border, 3 pt inset, 32 pt
/// segments, hand-cut radii 11/9/12/9 outside and 8/7/8/6 inside.
private struct UISettingsTabBar: View {
    @Binding var selection: UISettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UISettingsTab.allCases, id: \.self) { tab in
                let on = tab == selection
                Button { selection = tab } label: {
                    Text(tab.label)
                        .uiFont(.callout)
                        .fontWeight(.semibold)
                        // Shrink before wrapping, never truncate (no lineLimit):
                        // a cut-off tab name would pass assertfits silently.
                        // Receipt: the longest label fits unshrunk in
                        // half the column at 1.35x (a11y-large render,
                        // test Mac, 2026-09-29) and in a third of it at
                        // 1.00x on an installed build; 0.7
                        // is headroom for larger sizes, beyond which it wraps.
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(on ? SentryColor.paper : SentryColor.ink2)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(on ? SentryColor.ink : Color.clear,
                            in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 6,
                                bottomTrailingRadius: 8, topTrailingRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(SentryColor.slip.opacity(0.08), in: Self.shape)
        .overlay(Self.shape.strokeBorder(SentryColor.controlBorder, lineWidth: 2))
    }

    static let shape = UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 9,
        bottomTrailingRadius: 12, topTrailingRadius: 9, style: .continuous)
}

// MARK: - Settings look (app UI redesign, slice 7)

/// Geometry of the Settings boards (Settings-General, -Labels,
/// -Confirm .dc.html in the approved canvas). Every value is DERIVED from a
/// board's inline CSS, in points, and nothing here was measured on a running
/// app (no build was allowed in this slice): the Mac Mini render matrix is
/// the acceptance receipt, and the fold receipts on `UISettingsPanelView` are
/// stale until it is re-taken. Heights scale with the text (`UITypography
/// .points`) at their use sites; the boards' 12-15 px text is drawn with the
/// spec's `.callout`/`.caption` styles (ui-mvp-spec §9.3), so text is
/// smaller than the boards' by the same open decision the foundation notes
/// at `SentryPrimaryButtonStyle`.
enum UISettingsLook {
    static let borderWidth: CGFloat = 2
    /// Done, Cancel on a confirm card: 38 pt, 18 pt (Done) / 16 pt (Cancel) inset.
    static let doneHeight: CGFloat = 38
    static let doneInset: CGFloat = 18
    /// Activate (30), Check now (28), Manage billing (34).
    static let activateHeight: CGFloat = 30
    static let checkNowHeight: CGFloat = 28
    static let linkButtonHeight: CGFloat = 34
    /// Monthly under the mustard Yearly.
    static let monthlyHeight: CGFloat = 40
    /// A facts row (Status / Plan / Macs) and a row inside the links card.
    static let factRowHeight: CGFloat = 36
    static let linkRowHeight: CGFloat = 38
    static let radioRowHeight: CGFloat = 42
    static let disclosureHeight: CGFloat = 46
    static let fieldHeight: CGFloat = 34
    static let radioSize: CGFloat = 18
    static let confirmMark: CGFloat = 38
    /// The offset shadow of a primary or danger button is drawn outside its
    /// frame; callers leave this much free trailing and below it or it clips
    /// (same values as `SentryPrimaryButtonStyle.shadowOffset`).
    static let shadowRoom = SentryPrimaryButtonStyle.shadowOffset

    /// CSS `border-radius` order: top-left, top-right, bottom-right,
    /// bottom-left.
    static func shape(_ tl: CGFloat, _ tr: CGFloat, _ br: CGFloat, _ bl: CGFloat)
        -> UnevenRoundedRectangle
    {
        UnevenRoundedRectangle(
            topLeadingRadius: tl, bottomLeadingRadius: bl,
            bottomTrailingRadius: br, topTrailingRadius: tr, style: .continuous)
    }
    static let card = shape(12, 10, 13, 9)
    static let cardAlt = shape(10, 12, 9, 13)
    static let control = shape(10, 8, 11, 9)
    static let field = shape(9, 7, 10, 8)
}

/// SF Symbols the Settings slice draws that `UISymbol` does not name. Standard
/// symbols that exist on every macOS this app supports; `--ui-selftest` does
/// not resolve them (UISelfTest is outside this slice), so a typo here would
/// draw an empty slot: add them to `UISymbol` and its resolver when the
/// slices merge.
enum UISettingsSymbol {
    static let external = "arrow.up.right"
    static let disclosureClosed = "chevron.right"
    static let disclosureOpen = "chevron.down"
    static let statusOK = "checkmark.circle.fill"
    static let statusWaiting = "clock.fill"
    static let statusUnknown = "questionmark.circle.fill"
}

/// The card the boards draw around a group of rows: a 2 pt ink border, hand-cut
/// radii, and a slip-coloured fill by day, the night room's raised paper at
/// night. Text inside uses `SentryColor.ink`, which is cream at night, so it
/// sits on the DARK night fill; `slip`'s night value is light and would put
/// cream text on cream.
private struct UISettingsCard: ViewModifier {
    let alt: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = alt ? UISettingsLook.cardAlt : UISettingsLook.card
        content
            .background(shape.fill(scheme == .dark ? SentryColor.paper2 : SentryColor.slip))
            .clipShape(shape)
            .overlay(shape.strokeBorder(SentryColor.controlBorder,
                lineWidth: UISettingsLook.borderWidth))
    }
}

extension View {
    func uiSettingsCard(alt: Bool = false) -> some View {
        modifier(UISettingsCard(alt: alt))
    }
}

/// The hairline between rows inside a card. The boards draw #d1bf9c by day and
/// #473c33 at night; `SentryColor.line` (ink 20% / cream 16%) is the
/// token both approximate.
struct UISettingsRule: View {
    var body: some View {
        Rectangle().fill(SentryColor.line).frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The dashed 2 pt rule above the footer.
struct UISettingsDashedRule: View {
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }

    var body: some View {
        Line()
            .stroke(SentryColor.line, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}

/// "SENSITIVITY", "CHOOSE A PLAN": the boards' small accent-coloured
/// upper-case section label.
struct UISettingsSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .uiFont(.caption2, weight: .bold)
            .tracking(1)
            .foregroundStyle(SentryColor.accent)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The plain outlined button: Done, Cancel, Activate, Check now, Manage
/// billing, Monthly. Never mustard (that is `.sentryPrimary`).
struct UISettingsOutlineButtonStyle: ButtonStyle {
    var minHeight: CGFloat = UISettingsLook.doneHeight
    var horizontalPadding: CGFloat = UISettingsLook.doneInset
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        UISettingsOutlineButton(configuration: configuration, style: self)
    }
}

private struct UISettingsOutlineButton: View {
    let configuration: ButtonStyleConfiguration
    let style: UISettingsOutlineButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.uiTextScale) private var textScale

    var body: some View {
        let shape = UISettingsLook.control
        configuration.label
            .uiFont(.callout, weight: .semibold)
            .foregroundStyle(SentryColor.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, style.horizontalPadding)
            .frame(maxWidth: style.fillsWidth ? CGFloat.infinity : nil)
            .frame(minHeight: UITypography.points(style.minHeight, scale: textScale))
            .overlay(shape.strokeBorder(SentryColor.controlBorder,
                lineWidth: UISettingsLook.borderWidth))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : SentryPrimaryButtonStyle.disabledOpacity)
            .contentShape(shape)
    }
}

/// The confirm card's red button (Settings-Confirm): the primary button's
/// shape and offset shadow, filled `danger`. It is the only strong button on
/// a confirm card; there is no mustard there. The label is cream by day and
/// ink at night, where `danger` is a light coral (the board has no night
/// confirm card, so the night pairing is a contrast choice, not a copy of a
/// board).
struct UISettingsDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        UISettingsDangerButton(configuration: configuration)
    }
}

private struct UISettingsDangerButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.uiTextScale) private var textScale

    var body: some View {
        let shape = SentryPrimaryButtonStyle.shape
        let offset = SentryPrimaryButtonStyle.shadowOffset
        let pressed = configuration.isPressed
        configuration.label
            .uiFont(.headline)
            .foregroundStyle(scheme == .dark ? SentryColor.slipInk : SentryColor.coverInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .frame(minHeight: UITypography.points(UISettingsLook.doneHeight, scale: textScale))
            .background(SentryColor.danger, in: shape)
            .overlay(shape.strokeBorder(SentryColor.buttonShadow,
                lineWidth: SentryPrimaryButtonStyle.edgeWidth))
            // DESIGN.md "disabled": no lift, no shadow.
            .background(shape.fill(SentryColor.buttonShadow)
                .offset(pressed ? .zero : offset)
                .opacity(isEnabled ? 1 : 0))
            .offset(pressed && isEnabled ? offset : .zero)
            .opacity(isEnabled ? 1 : SentryPrimaryButtonStyle.disabledOpacity)
            .contentShape(shape)
    }
}

/// The red mark that leads a confirm card's title: a 38 pt outlined square
/// with the action's symbol. Sits on the title's own line.
struct UISettingsConfirmMark: View {
    let symbol: String
    @Environment(\.uiTextScale) private var textScale

    var body: some View {
        let side = UITypography.points(UISettingsLook.confirmMark, scale: textScale)
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .uiFont(.headline)
            .foregroundStyle(SentryColor.danger)
            .frame(width: side, height: side)
            .overlay(UISettingsLook.card.strokeBorder(SentryColor.danger,
                lineWidth: UISettingsLook.borderWidth))
            .accessibilityHidden(true)
    }
}

/// A link label that opens the browser: the text and the boards' small
/// up-right arrow ("Links that open the browser carry an arrow"). The arrow is
/// decoration; the hint carries the fact for VoiceOver.
struct UISettingsLinkLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: UISettingsSymbol.external)
                .uiFont(.caption2, weight: .bold)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityHint("Opens in your browser")
    }
}

// MARK: - Sensitivity, two described rows (Settings-General)

/// Sensitivity as two radio rows, each with its own one-line description,
/// replacing the segmented control and the caption under it. Same ids as
/// `UISensitivitySettingsSection` (`ui.sensitivity` reads the policy's raw
/// value; `.standard` and `.strict` are the rows; `.pinned` is the
/// command-line note) and the same `actions.setPolicy` PIN path, so the
/// scripts that drive it keep their ids. Tapping the row that is already
/// selected does nothing, as a radio does: the segmented control never asked
/// for a PIN to re-choose what was chosen.
struct UISettingsSensitivitySection: View {
    @ObservedObject var state: UIState
    @ObservedObject var actions: UIActions
    @Environment(\.uiTextScale) private var textScale
    @Environment(\.colorScheme) private var scheme

    private var pinned: Bool { state.policyPinned }

    static let label = "Sensitivity"
    static let standardDetail = "Explicit content"
    static let strictDetail = "Also swimwear and underwear"

    static func detail(_ mode: PolicyMode) -> String {
        mode == .standard ? standardDetail : strictDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UISettingsSectionLabel(text: Self.label)
            VStack(spacing: 0) {
                row(.standard)
                UISettingsRule()
                row(.strict)
            }
            .uiSettingsCard()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.label)
            .uiControl("ui.sensitivity", kind: .picker,
                read: { state.policy.rawValue }, enabled: { !pinned })
            if pinned {
                UIInlineMessage(text: UIPopoverView.sensitivityPinnedText,
                    symbol: UISymbol.commandLine, tint: .systemOrange)
                    .uiControl("ui.sensitivity.pinned", kind: .text,
                        read: { UIPopoverView.sensitivityPinnedText })
            }
        }
    }

    private func choose(_ mode: PolicyMode) {
        guard mode != state.policy else { return }
        actions.setPolicy(mode)
    }

    private func row(_ mode: PolicyMode) -> some View {
        let selected = state.policy == mode
        return Button { choose(mode) } label: {
            HStack(spacing: 10) {
                radio(selected: selected)
                VStack(alignment: .leading, spacing: 0) {
                    Text(mode.displayName)
                        .uiFont(.callout, weight: .semibold)
                        .foregroundStyle(SentryColor.ink)
                    Text(Self.detail(mode))
                        .uiFont(.caption)
                        .foregroundStyle(SentryColor.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIMetrics.sectionPadding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: UITypography.points(UISettingsLook.radioRowHeight, scale: textScale))
            .background(selected ? SentryColor.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pinned)
        .opacity(pinned ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.displayName), \(Self.detail(mode))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .uiControl("ui.sensitivity.\(mode.rawValue)", kind: .button,
            read: { mode.displayName }, activate: { choose(mode) },
            enabled: { !pinned })
    }

    private func radio(selected: Bool) -> some View {
        let side = UITypography.points(UISettingsLook.radioSize, scale: textScale)
        return Circle()
            .fill(scheme == .dark ? SentryColor.paper : SentryColor.slip)
            .overlay(Circle().strokeBorder(SentryColor.controlBorder,
                lineWidth: UISettingsLook.borderWidth))
            .overlay {
                if selected {
                    Circle().fill(SentryColor.ink).frame(width: side * 8 / 18, height: side * 8 / 18)
                }
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}
