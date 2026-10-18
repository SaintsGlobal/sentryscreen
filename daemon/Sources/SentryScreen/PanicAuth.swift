import Foundation
import Security

/// Administrator authorization in front of the panic hotkey.
///
/// SPEC §8.1(1): "Production: require the admin password." Owner decision
/// 2026-09-01: required now. The hotkey path is `PanicHold` (the chord held
/// for 1 s, owner 2026-09-02) → `PanicGate.press()` → `PanicAuth.requestAdmin`
/// → the unchanged `Pipeline.panic(source:)` only on `.granted`. Covers stay
/// up while the prompt is open: they are click-through
/// by construction (SPEC §8), so the prompt is usable underneath or beside
/// them, and the coverage tripwire (SPEC §8.1(2), >90 % covered for 60 s)
/// still lifts runaway region covers without any prompt — so a child cannot
/// hold the key to buy a five-minute window, and nobody stays behind a screen
/// of region covers. Since 2026-10-18 the tripwire no longer goes through
/// `panic()`: it lifts region covers for `Pipeline.regionReleaseSecs` with
/// curtains and detection still on. SIGUSR2 also
/// bypassed this gate and WAS reachable — by any process in the session,
/// `kill -USR2 <pid>` — so since 2026-09-07 it is armed only on a dev run
/// (`DevSignals.swift`, SPEC §8.1(8)) and refused, by name, everywhere else.
enum PanicAuth {
    /// The authorization right the prompt asks for. `system.privilege.admin`
    /// is a stock right in the authorization database whose rule is
    /// "authenticate as an administrator", so it needs no custom right
    /// installed, works on a fresh machine, and asks for an administrator's
    /// name and password from ANY account — including a standard (child)
    /// account, which is the case that matters. Receipt: /etc/authorization
    /// (`security authorizationdb read system.privilege.admin` → class `user`,
    /// group `admin`; checked 2026-09-01 on this Mac, macOS 26.6).
    static let right = "system.privilege.admin"

    /// What the system prompt says above the name/password fields. Copy from
    /// the approved Notices-PanicHotkey board;
    /// it states what the 5-minute pause does and nothing more.
    static let prompt = "Clears every cover and pauses protection for 5 minutes."

    enum Outcome: String { case granted, denied, cancelled, error }

    /// `--ui-selftest` hook: replaces the system prompt with a scripted
    /// answer so the gate can be driven headlessly (a real prompt cannot be
    /// scripted). nil in production; set and called on the main thread.
    static var override: ((@escaping (Outcome, String) -> Void) -> Void)?

    /// Asks for `right` with interaction allowed. `AuthorizationCopyRights`
    /// blocks until the person answers, so it runs on a utility queue and the
    /// completion hops back to main. Every failure maps to an `Outcome` with a
    /// detail string for the log — this never throws and never returns
    /// silently.
    static func requestAdmin(completion: @escaping (Outcome, String) -> Void) {
        if let override {
            override(completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (outcome, detail) = copyRightsBlocking()
            DispatchQueue.main.async { completion(outcome, detail) }
        }
    }

    private static func copyRightsBlocking() -> (Outcome, String) {
        var authRef: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &authRef)
        guard created == errAuthorizationSuccess, let auth = authRef else {
            return (.error, "AuthorizationCreate=\(created)")
        }
        defer { AuthorizationFree(auth, []) }

        var status: OSStatus = errAuthorizationInternal
        // AuthorizationItem stores borrowed C pointers. Keep the environment
        // prompt key alive through item construction and AuthorizationCopyRights,
        // as with the right and prompt value strings below.
        let promptKey: String = kAuthorizationEnvironmentPrompt
        right.withCString { rightName in
            promptKey.withCString { promptKeyName in
                prompt.withCString { promptText in
                    var rightItem = AuthorizationItem(
                        name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(
                        name: promptKeyName,
                        valueLength: strlen(promptText),
                        value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    withUnsafeMutablePointer(to: &rightItem) { rightPtr in
                        withUnsafeMutablePointer(to: &promptItem) { promptPtr in
                            var rights = AuthorizationRights(count: 1, items: rightPtr)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPtr)
                            // .extendRights: actually obtain the right, not just
                            // check it. .interactionAllowed: show the prompt.
                            // No .preAuthorize (that would skip the prompt for an
                            // already-authorized admin session) — every hold asks.
                            status = AuthorizationCopyRights(
                                auth, &rights, &environment,
                                [.extendRights, .interactionAllowed], nil)
                        }
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess: return (.granted, "status=0")
        case errAuthorizationCanceled: return (.cancelled, "status=\(status)")
        case errAuthorizationDenied, errAuthorizationInteractionNotAllowed:
            return (.denied, "status=\(status)")
        default: return (.error, "status=\(status)")
        }
    }
}

/// The gate between the hotkey and `Pipeline.panic`. Separate from `Pipeline`
/// so `--ui-selftest` can drive it without capture or overlays.
///
/// Log records use the event name `panic-auth`, NOT `panic`: the scenario
/// tooling counts `"panic"` records in daemon.jsonl and declares the run
/// INVALID on any hit, and a
/// cancelled prompt cleared nothing. A granted prompt still produces the
/// unchanged `event=panic` record from `panic(source: "hotkey")`.
final class PanicGate {
    /// A second hold while the prompt is open is ignored and logged; the
    /// prompt already on screen is the one that decides.
    private(set) var inFlight = false
    private let log: (String, String) -> Void
    private let onGranted: () -> Void

    init(log: @escaping (String, String) -> Void, onGranted: @escaping () -> Void) {
        self.log = log
        self.onGranted = onGranted
    }

    /// Main thread (hotkey handlers fire on the main event loop).
    func press() {
        if inFlight {
            log("panic-auth", "source=hotkey: prompt already open, hold ignored")
            return
        }
        inFlight = true
        log("panic-auth", "source=hotkey: administrator authorization requested (\(PanicAuth.right))")
        PanicAuth.requestAdmin { [self] outcome, detail in
            inFlight = false
            switch outcome {
            case .granted:
                log("panic-auth", "source=hotkey: granted (\(detail))")
                onGranted()
            case .denied, .cancelled, .error:
                log(
                    "panic-auth",
                    "source=hotkey: \(outcome.rawValue) (\(detail)) — nothing cleared, protection unchanged")
            }
        }
    }
}

/// The hold in front of the gate (SPEC §8.1(1); owner decision 2026-09-02:
/// implement the documented 1-s hold, do not drop it). The chord must stay
/// down for `holdSecs` before the administrator prompt is asked for; a release
/// before that cancels with no prompt, and a key-repeat press during the hold
/// neither restarts nor extends it. After a fire the machine is idle again at
/// once — it does not wait for the release, because the SecurityAgent prompt
/// the fire opens takes secure event input, which can keep that release from
/// ever reaching this process, and a state waiting for it would leave the
/// hotkey dead. A repeat that lands after the fire starts a fresh hold, and
/// `PanicGate` ignores (and logs) a second fire while its prompt is open.
///
/// Every transition is a named `panic-hold` record — start, cancel, fire — so
/// the taps that never reached the prompt are visible in run.jsonl. Not
/// `panic`: the scenario tooling's INVALID rule (see `PanicGate`).
///
/// The clock and the timer are injected so `--ui-selftest` drives the machine
/// with scripted timestamps and fires the timer by hand; production reads the
/// monotonic uptime clock and schedules on the main queue, the thread the
/// hotkey handlers run on.
final class PanicHold {
    /// SPEC §8.1(1) has said "hold Cmd+Opt+Ctrl+X for 1 s" since the design;
    /// owner decision 2026-09-02 confirmed the number and asked for it to be
    /// built. Rationale (a requirement, not a measurement): the chord is one a
    /// child's hand can land on by accident, and until this change every
    /// accidental press put a full administrator prompt on the family screen;
    /// one deliberate second costs a parent who knows the chord nothing.
    /// ASSUMED: that a full second is rare by accident. Re-receipt once live
    /// data exists: the held-time distribution of `panic-hold` `cancel`
    /// records over a soak — accidental holds clustering near 1 s argue for
    /// a longer hold, never for a silent change here. The log strings,
    /// `--hotkey-test` and the selftest read it from here — one place.
    static let holdSecs: TimeInterval = 1.0

    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let log: (String, String) -> Void
    private let onFire: () -> Void
    private let clock: () -> TimeInterval
    private let schedule: Schedule

    /// Clock reading at the start of the current hold; nil = idle.
    private var heldSince: TimeInterval?
    var isHolding: Bool { heldSince != nil }
    /// Key-repeat presses inside the current hold: ignored, counted for the record.
    private(set) var repeats = 0
    /// Cancels a scheduled fire without a timer handle: cancel and fire both
    /// advance it, and a callback carrying a stale generation does nothing.
    private var generation = 0

    init(
        log: @escaping (String, String) -> Void,
        onFire: @escaping () -> Void,
        clock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.log = log
        self.onFire = onFire
        self.clock = clock
        self.schedule = schedule
    }

    /// Main thread: `kEventHotKeyPressed`, auto-repeats included.
    func press() {
        if heldSince != nil {
            repeats += 1
            return
        }
        heldSince = clock()
        repeats = 0
        generation += 1
        let armed = generation
        log("panic-hold", "start: hold \(Self.holdSecs) s for the administrator prompt; a release before that cancels")
        schedule(Self.holdSecs) { [weak self] in self?.fire(generation: armed) }
    }

    /// Main thread: `kEventHotKeyReleased`. With nothing held (after a fire,
    /// or a stray release) there is nothing to record.
    func release() {
        guard let since = heldSince else { return }
        let held = clock() - since
        heldSince = nil
        generation += 1
        log(
            "panic-hold",
            "cancel: released after \(Self.secs(held)) of \(Self.holdSecs) s (\(repeats) repeats) "
                + "— no prompt, protection unchanged")
    }

    private func fire(generation armed: Int) {
        guard armed == generation, let since = heldSince else { return }
        let held = clock() - since
        heldSince = nil
        generation += 1
        log("panic-hold", "fire: held \(Self.secs(held)) (\(repeats) repeats) — administrator prompt next")
        onFire()
    }

    private static func secs(_ t: TimeInterval) -> String { String(format: "%.2f s", t) }
}
