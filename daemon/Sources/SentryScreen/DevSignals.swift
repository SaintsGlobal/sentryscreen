import Foundation

/// One dev-only process signal and what it would do if it were armed.
struct DevSignalTrigger {
    /// The signal's name, as it appears in the log record.
    let name: String
    /// The `"event"` name of the refusal record. Deliberately the SAME name
    /// the armed path logs (`panic` / `inject`), so a parent or an analysis
    /// script greps one event name for both the attempt and the effect.
    let event: String
    /// What the armed path would have done, in the refusal record.
    let effect: String
}

/// Dev-only signal triggers (SPEC §8.1(8)).
///
/// `SIGUSR1` (inject) and `SIGUSR2` (panic) drive the same code paths as the
/// hotkeys so scripted tests exercise the real behavior. Until 2026-09-07
/// both were armed in EVERY build, and the agent runs as the session uid — so
/// a child in a Standard account could run
/// `kill -USR2 $(pgrep -x sentry-screen)` from their own Terminal and clear
/// every cover for `Pipeline.pauseSeconds` (300 s), repeatably, with no
/// administrator prompt (the authorization `PanicGate` has demanded of the
/// hotkey since 2026-09-01) and nothing on screen to show it happened.
///
/// The arming rule is the one `--dev-inject` already sets for the inject
/// hotkey (SPEC §8.2, `Options.devInject`): a command-line flag, deliberately
/// NOT a `config.json` key, so no installed build can arm it — the production
/// LaunchAgent line is `--config … --log … --ttl 0` and nothing else
/// (`packaging/agent-launch.sh`).
enum DevSignals {
    /// Named in every refusal record so the record itself carries the repair.
    static let flag = "--dev-inject"

    static let panic = DevSignalTrigger(
        name: "SIGUSR2", event: "panic",
        effect: "clear every cover and pause detection")
    static let inject = DevSignalTrigger(
        name: "SIGUSR1", event: "inject",
        effect: "paint a fake detection box")

    /// True when this process may act on the dev signals: only a run that
    /// asked for dev affordances on the command line. The installed agent
    /// never does, so a Standard account cannot clear covers with `kill`.
    static func armed(devInject: Bool) -> Bool {
        return devInject
    }

    /// The exact body the `DispatchSourceSignal` handlers run. Extracted so
    /// `--ui-selftest` proves both directions (inert on a production build,
    /// live on a dev run) without sending a real signal.
    static func deliver(
        _ trigger: DevSignalTrigger, armed: Bool, refusals: DevSignalRefusals,
        run: () -> Void
    ) {
        guard armed else {
            refusals.refuse(trigger)
            return
        }
        run()
    }
}

/// Records a refused dev-signal delivery, coalesced.
///
/// The first refusal of each signal is logged immediately — an attempt must be
/// visible to the parent reading `run.jsonl` — and further attempts inside
/// `refusalWindowSecs` are counted and reported by the next record, or by
/// `flush()` on a clean stop. Nothing is dropped silently.
final class DevSignalRefusals {
    /// Budget DEV_SIGNAL_REFUSAL_WINDOW: at most one refusal record per signal
    /// per window. Receipt (MEASURED 2026-09-07 on an M1 Mac, a bash
    /// `while :; do kill -USR2 "$pid"; done` loop against a process that
    /// ignores the signal): ~28,000 deliveries/s. A refusal record is ~200 B,
    /// so logging every one would write ~5 MB/s and roll run.jsonl's entire
    /// 50 MiB x 4 rotation budget (`FrameLogger.logFileCapBytes`) in under a
    /// minute — the flood would ERASE the evidence of the covers it is
    /// attacking, which is the same "cannot see" failure §8 exists to prevent.
    /// 60 s bounds a sustained attack at 1 record/min per signal (≈0.2 KB/h)
    /// while the first attempt is always logged the instant it arrives.
    static let refusalWindowSecs = 60.0

    private let log: (String, String) -> Void
    private let now: () -> Date
    private var lastLogged: [String: Date] = [:]
    private var pending: [String: (trigger: DevSignalTrigger, count: Int)] = [:]

    init(now: @escaping () -> Date = Date.init, log: @escaping (String, String) -> Void) {
        self.now = now
        self.log = log
    }

    /// Called from the signal handlers on the main queue, and from the
    /// termination handler on the same queue — no extra synchronization.
    func refuse(_ trigger: DevSignalTrigger) {
        let at = now()
        if let last = lastLogged[trigger.name],
            at.timeIntervalSince(last) < Self.refusalWindowSecs {
            let seen = pending[trigger.name]?.count ?? 0
            pending[trigger.name] = (trigger, seen + 1)
            return
        }
        emit(trigger, at: at)
    }

    /// Reports whatever the window is still holding. Called on SIGINT/SIGTERM
    /// so a clean stop never loses the tail of a burst; a SIGKILL or a crash
    /// does, which is why the FIRST attempt is never coalesced.
    func flush() {
        let at = now()
        for held in pending.values { emit(held.trigger, at: at) }
    }

    private func emit(_ trigger: DevSignalTrigger, at: Date) {
        let coalesced = pending.removeValue(forKey: trigger.name)?.count ?? 0
        lastLogged[trigger.name] = at
        var info =
            "REFUSED \(trigger.name): the dev-only signal triggers are not armed on this "
            + "build, so nothing was cleared and protection is unchanged (it would "
            + "\(trigger.effect)). Fix: for a dev run use \(DevSignals.flag); "
            + "the supported escape is the panic hotkey (SPEC §8.1(1)), which asks for an "
            + "administrator password."
        if coalesced > 0 {
            info += " Budget DEV_SIGNAL_REFUSAL_WINDOW, limit 1 record per "
                + "\(Int(Self.refusalWindowSecs))s per signal, observed \(coalesced) further "
                + "\(trigger.name) deliveries coalesced into this record "
                + "(fix: DevSignalRefusals.refusalWindowSecs)."
        }
        log(trigger.event, info)
    }
}
