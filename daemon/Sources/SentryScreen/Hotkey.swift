import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey. Chosen over a CGEventTap
/// because it needs no Accessibility/Input Monitoring TCC grant and receives
/// events regardless of which app has focus. Requires a running main event
/// loop (NSApplication.run).
///
/// Both halves of a stroke are delivered — `kEventHotKeyPressed` and
/// `kEventHotKeyReleased` — so a registration can ask for the release too and
/// require a HOLD (the panic chord, SPEC §8.1(1): `PanicHold`). Carbon owns
/// the chord state and sends the release when the chord ends; press-only
/// registrations never see it.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// Never fatal since 2026-09-02: a failed registration is logged with its
    /// `OSStatus` (`HotkeyStartup.outcome`) and written to alerts.log, and the
    /// pipeline keeps running — before that `Pipeline.registerHotkeys` called
    /// `die(code: 6)`, and 6 is not in agent-launch.sh's relaunch set, so any
    /// registration failure meant protection OFF with the watchdog
    /// kickstarting a doomed daemon every ~60 s. The only failure MEASURED on
    /// this macOS is the same-process duplicate (`HotkeyRegistration`), which
    /// the in-process Pipeline restart used to trigger. SPEC §8.1(1)–(2) still
    /// have the coverage tripwire's region release when the key is gone —
    /// SIGUSR2 stopped being one on an installed build 2026-09-07 (SPEC
    /// §8.1(8), DevSignals.swift): it is a dev trigger, not a safety layer.
    static let panicKey = (code: UInt32(kVK_ANSI_X), label: "Cmd+Opt+Ctrl+X")
    /// Test-only (SPEC §8.2): registered ONLY with `--dev-inject`, never on
    /// an installed build — a shipped daemon has no business holding a
    /// global shortcut that paints a fake cover, and every extra registration
    /// is another chance to collide with a user's app. Scripted tests use
    /// SIGUSR1 (main.swift), which needs no registration at all — and which
    /// the SAME flag arms since 2026-09-07 (DevSignals.swift).
    static let injectKey = (code: UInt32(kVK_ANSI_I), label: "Cmd+Opt+Ctrl+I")
    /// Brings a hidden menu bar icon back (ui-mvp-spec §9.4, Addendum 6B).
    /// Registered in ADMIN sessions only, and never fatal: a registration
    /// failure must not take protection down to restore an icon.
    static let revealKey = (code: UInt32(kVK_ANSI_S), label: "Cmd+Opt+Ctrl+S")
    static let modifiers = UInt32(cmdKey | optionKey | controlKey)

    private var table = HotkeyTable()

    private init() {
        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard let handlers = HotkeyCenter.shared.table.handlers[id.id] else { return noErr }
                switch GetEventKind(event) {
                case UInt32(kEventHotKeyPressed): handlers.press()
                case UInt32(kEventHotKeyReleased): handlers.release?()
                default: break
                }
                return noErr
            }, specs.count, &specs, nil, nil)
    }

    /// Register on the main thread only; handlers fire on the main event loop.
    /// Press-only: the release is ignored.
    @discardableResult
    func register(keyCode: UInt32, handler: @escaping () -> Void) -> HotkeyRegistration {
        register(keyCode: keyCode, onPress: handler, onRelease: nil)
    }

    /// Press and release, for hold semantics. Same thread rule. Idempotent per
    /// key code: a chord this process already holds is re-pointed at the new
    /// handlers (`.rebound`) instead of asking Carbon again — the same-process
    /// duplicate is the one registration failure MEASURED on this macOS
    /// (`HotkeyRegistration`), and a Pipeline restart is exactly that call.
    @discardableResult
    func register(
        keyCode: UInt32, onPress: @escaping () -> Void, onRelease: (() -> Void)?
    ) -> HotkeyRegistration {
        table.bind(keyCode: keyCode, handlers: .init(press: onPress, release: onRelease)) { id in
            let hotKeyID = EventHotKeyID(signature: OSType(0x534E5452 /* 'SNTR' */), id: id)
            var ref: EventHotKeyRef?
            return RegisterEventHotKey(
                keyCode, Self.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        }
    }
}

/// Outcome of one `HotkeyCenter.register` call. `.failed` carries the raw
/// `OSStatus` and nothing else, because the status is the only fact we hold:
/// MEASURED 2026-09-02 (throwaway Carbon program run beside the installed
/// daemon, which held Cmd+Opt+Ctrl+X): registering a chord another PROCESS
/// already owns returned `noErr` with a non-nil ref — Carbon does not report
/// cross-process collisions, so "another app owns the shortcut" is never what
/// a failure means. The one failure reproduced is the same-process duplicate,
/// `eventHotKeyExistsErr` (-9878), which `HotkeyTable` now prevents by
/// re-pointing instead of re-registering.
enum HotkeyRegistration: Equatable {
    /// Carbon accepted a new registration.
    case registered
    /// This process already held the chord; the handlers were replaced and
    /// Carbon was not called. The normal outcome of a Pipeline restart
    /// (onboarding `retryCaptureStartup`: `shutdown()` → new `Pipeline` →
    /// `start()` → `registerHotkeys()`), which used to fail with -9878 and,
    /// before that, exit 6.
    case rebound
    case failed(OSStatus)

    var isBound: Bool {
        if case .failed = self { return false }
        return true
    }

    /// `-9878 (eventHotKeyExistsErr)` for the one status we have a name for,
    /// the bare number otherwise — the log must not invent a cause.
    static func describe(_ status: OSStatus) -> String {
        status == OSStatus(eventHotKeyExistsErr) ? "\(status) (eventHotKeyExistsErr)" : "\(status)"
    }
}

/// `HotkeyCenter`'s bookkeeping, pure so `--ui-selftest` (`caseHotkeyStartup`)
/// can drive it with a fake `register` and never touch Carbon (the selftest
/// runs on an M1 Mac beside the installed daemon, which holds the real chords).
/// Ids are handed out once per key code and kept for the life of the process;
/// a key code seen again is re-pointed, not re-registered.
struct HotkeyTable {
    struct Handlers {
        let press: () -> Void
        let release: (() -> Void)?
    }
    /// Carbon hot-key id → handlers, read by the event handler.
    private(set) var handlers: [UInt32: Handlers] = [:]
    /// Key code → the id Carbon accepted for it.
    private var bound: [UInt32: UInt32] = [:]
    private var nextId: UInt32 = 1

    /// `register(id)` performs the Carbon call for a fresh id and returns its
    /// status; it is not called for a key code already bound here.
    mutating func bind(
        keyCode: UInt32, handlers h: Handlers, register: (UInt32) -> OSStatus
    ) -> HotkeyRegistration {
        if let id = bound[keyCode] {
            handlers[id] = h
            return .rebound
        }
        let id = nextId
        let status = register(id)
        guard status == noErr else { return .failed(status) }
        nextId += 1
        handlers[id] = h
        bound[keyCode] = id
        return .registered
    }
}

/// What `Pipeline.registerHotkeys` logs for a registration outcome — pure, so
/// `--ui-selftest` (`caseHotkeyStartup`) asserts the non-fatal path without a
/// Carbon event target. Every record is a named `hotkey` event; a failure
/// carries the raw status (never a guessed cause — see `HotkeyRegistration`),
/// says what still works, and what to do, because the log line is the only
/// place the failure is visible until alerts.log is surfaced.
enum HotkeyStartup {
    struct Outcome {
        /// `run.jsonl` records, in order.
        let records: [(event: String, info: String)]
        /// The alerts.log message, present only when the PANIC hotkey failed —
        /// the inject hotkey is a dev convenience and gets no parent alert.
        let alert: String?
    }

    /// `inject == nil` means the inject hotkey was not requested
    /// (no `--dev-inject`), which is every installed build.
    static func outcome(panic: HotkeyRegistration, inject: HotkeyRegistration?) -> Outcome {
        var records: [(event: String, info: String)] = []
        var alert: String?
        let panicLabel = HotkeyCenter.panicKey.label
        switch panic {
        case .registered:
            records.append(("hotkey", "panic \(panicLabel) registered"))
        case .rebound:
            records.append(("hotkey", "panic \(panicLabel) re-bound to the restarted pipeline "
                + "(already held by this process)"))
        case .failed(let status):
            let msg = "panic hotkey \(panicLabel) REGISTRATION FAILED "
                + "(RegisterEventHotKey status \(HotkeyRegistration.describe(status))) — protection keeps "
                + "running; the coverage tripwire still lifts stuck covers; the key stays "
                + "unavailable until the agent restarts (log out and back in); if it recurs, report the status"
            records.append(("hotkey", msg))
            alert = msg
        }
        let injectLabel = HotkeyCenter.injectKey.label
        switch inject {
        case nil:
            records.append(("hotkey", "inject \(injectLabel) not registered (no \(DevSignals.flag))"))
        case .registered?:
            records.append(("hotkey", "inject \(injectLabel) registered (\(DevSignals.flag))"))
        case .rebound?:
            records.append(("hotkey", "inject \(injectLabel) re-bound to the restarted pipeline (\(DevSignals.flag))"))
        case .failed(let status)?:
            records.append(("hotkey", "inject \(injectLabel) REGISTRATION FAILED "
                + "(RegisterEventHotKey status \(HotkeyRegistration.describe(status))) — dev-only; "
                + "use SIGUSR1 (kill -USR1 <pid>) to inject"))
        }
        return Outcome(records: records, alert: alert)
    }
}
