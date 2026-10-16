import Foundation

/// Liveness while this process has NO Pipeline but is still alive.
///
/// A capture restart or a failed model load leaves this process with no
/// Pipeline (`pipeline = nil`). The Pipeline owns the 60 s idle tick
/// (`FrameLogger.idleTick`) and nothing else writes run.jsonl, so from that
/// moment the file's mtime froze while the process stayed alive and healthy.
/// The watchdog (`packaging/watchdog.sh`, budget `SUMMARY_STALE_SECS`) reads
/// that mtime as liveness; its "log newer than the newest process" guard
/// does not cover this case because THIS process wrote the file. Result
/// before 2026-09-07: ~600 s into every legitimate hold, a false "agent
/// wedged" ALERT and a `kickstart -k` restart under the parent.
///
/// The fix keeps the pipeline's own `FrameLogger` alive across the hold (its
/// handle stays open for the object's lifetime; `Pipeline.shutdown` never
/// closes it) and writes one `"event":"held"` record per `intervalSecs`
/// through it, carrying the hold reason. Owned by AppDelegate, not by the
/// Pipeline: it exists precisely while there is no Pipeline, and stops the
/// moment one is rebuilt (`startPipeline`), whose fresh logger rolls the
/// file as every launch does.
///
/// `retryCaptureStartup` (`reason` = `capture-restart`) is the short one: it
/// tears a running Pipeline down to build a fresh one, and if that rebuild
/// THROWS — an unreadable model file mid-update — the process parks in the
/// repair UI with no Pipeline at all, which is the same frozen log for the same
/// reason. A successful retry stops it on the next line, so it normally costs
/// one record. The rule for a third caller: if the Pipeline being dropped wrote
/// run.jsonl, arm this before dropping it.
final class HoldHeartbeat {
    /// Cadence. DERIVED from the two numbers it sits between: it equals the
    /// idle tick's 60 s (main.swift `Pipeline.start`, the cadence the
    /// watchdog's receipt was measured against — gap p50 60 s, max 120 s),
    /// so a held process looks to the watchdog exactly like a paused one;
    /// and it is 10x under `SUMMARY_STALE_SECS` = 600 s, so a missed or late
    /// tick (main run loop blocked by a modal prompt) still leaves the same
    /// 5x margin the summary path has. A day-long hold costs ~1,440 records
    /// of ~110 B — 160 KB, nothing against the 50 MiB file cap.
    static let intervalSecs: TimeInterval = 60

    let logger: FrameLogger
    let reason: String
    private var timer: Timer?
    private(set) var ticks = 0

    init(logger: FrameLogger, reason: String) {
        self.logger = logger
        self.reason = reason
    }

    /// Initial model failure has no Pipeline logger. Reuse a hold on retries;
    /// otherwise open the log and write the first liveness record immediately.
    static func pipelineFailed(
        existing: HoldHeartbeat?, path: String?, quiet: Bool, mode: LogMode
    ) -> HoldHeartbeat {
        let heartbeat = existing ?? HoldHeartbeat(
            logger: FrameLogger(path: path, quiet: quiet, mode: mode, live: true),
            reason: "pipeline-init-failed")
        heartbeat.start()
        return heartbeat
    }

    /// Writes the first record immediately (the hold is itself an event the
    /// log must carry, and the file's mtime should move now, not 60 s from
    /// now), then one per interval on the main run loop. `interval` is
    /// overridable for the selftest only.
    ///
    /// `.common` MODE, not `Timer.scheduledTimer`'s default
    /// (2026-09-11). A default-mode timer only fires while the main run loop
    /// runs in `.default`: an NSMenu tracking session
    /// (`NSEventTrackingRunLoopMode`) or a modal panel
    /// (`NSModalPanelRunLoopMode`) starves it for as long as it is up. This
    /// heartbeat IS the liveness signal `packaging/watchdog.sh`'s
    /// `SUMMARY_STALE_SECS` reads, so starving it past 600 s earns a
    /// `kickstart -k` — i.e. a parent holding a menu open through a hold would
    /// restart the agent. `.common` includes the tracking and modal modes, so
    /// the heartbeat keeps writing. Cheap and one-directional: nothing here
    /// depends on the mode set being narrow.
    func start(interval: TimeInterval = HoldHeartbeat.intervalSecs) {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    private func tick() {
        ticks += 1
        logger.event(
            "held",
            "reason=\(reason) heartbeat=\(ticks) pid=\(getpid()) "
                + "(no Pipeline in this process; liveness for packaging/watchdog.sh SUMMARY_STALE_SECS)")
    }
}
