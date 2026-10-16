import Foundation

/// The daemon's half of `alerts.log` — the parent-readable record
/// `scripts/health_report.py` prints beside the watchdog's own file
/// (`packaging/watchdog.sh`). One line per alert in the watchdog's format, `date -u +%Y-%m-%dT%H:%M:%SZ LEVEL message`, so the
/// existing readers parse it unchanged.
///
/// A daemon-side alert is for a failure that leaves protection RUNNING but
/// degraded, or stops it altogether, in a way a parent must hear about
/// (2026-09-02: a panic-hotkey registration collision; 2026-09-07: capture
/// loss and capture restore, `CaptureAlert`). It is NOT a substitute for the
/// `run.jsonl` event — the caller logs that first, and this file is the
/// second copy, the one that survives the session the outage happened in.
///
/// WHERE it lands (changed 2026-09-07): the installed
/// support directory is root-owned 0755 (MEASURED 2026-09-02 on an M1 Mac:
/// `drwxr-xr-x root wheel`), so an agent running as the session's uid could
/// never create the file there and every daemon-side alert was refused —
/// the record existed only in `run.jsonl`. The agent now writes into its OWN
/// per-uid log directory, beside the `run.jsonl` it already writes
/// (`/Library/Logs/SentryScreen/<uid>/alerts.log`; `agent-launch.sh` creates
/// that directory as the session's uid). `health_report.py` reads it there,
/// per uid, next to the root file the administrator processes write.
///
/// Why this and not "have the watchdog copy the daemon's alerts into the
/// root file": the smaller change by a wide margin. This side is one line of
/// path resolution plus one loop in the reader; the merge would need the
/// root watchdog to tail four `run.jsonl` generations per uid every 60 s,
/// keep per-uid dedupe state across passes, order two writers' timestamps
/// and carry a second size budget — new state and a new failure mode in the
/// one process that must never wedge.
enum AlertsLog {
    /// `SENTRY_ALERTS_LOG` (tests) → beside `run.jsonl` in this process's
    /// per-uid production log directory (agent-launch.sh passes
    /// `--log /Library/Logs/SentryScreen/<uid>/run.jsonl`) → the watchdog's
    /// dev-mode path (`SENTRY_WATCHDOG_DEV=1` in watchdog.sh), so a dev
    /// daemon and a dev watchdog share one file.
    static func resolvePath(
        logPath: String?,
        env: [String: String] = DevEnv.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let p = env["SENTRY_ALERTS_LOG"], !p.isEmpty { return p }
        if let logPath, logPath.hasPrefix(UIActivity.productionRoot + "/") {
            return (logPath as NSString).deletingLastPathComponent + "/alerts.log"
        }
        return home + "/Library/Logs/SentryScreen-dev/alerts.log"
    }

    /// Size budget, mirroring `watchdog.sh` `ALERTS_CAP_BYTES` (5 MiB, one
    /// generation) so both halves of `alerts.log` have the same shape.
    /// Receipt for the daemon half: a
    /// healthy machine writes NOTHING here (one line per outage, one per
    /// restore); every writer is bounded by a time floor, and the sum of those
    /// bounds is the worst case:
    ///
    /// * capture flap — bounded by the 5 s re-arm poll
    ///   (`AppDelegate.captureLossPollSecs`) at 2 lines per cycle × ~110 B =
    ///   DERIVED ≈3.8 MB/day;
    /// * detector flap — bounded by `DetectorAlertGate.recoverySettleSecs`
    ///   (60 s) at 2 lines per episode, MEASURED 2026-09-11 at 183 B + 114 B =
    ///   297 B ⇒ ≈0.43 MB/day.
    ///
    /// Together DERIVED ≈4.2 MB/day, i.e. 5 MiB is ~1.2 days of a machine
    /// nobody is fixing. Re-derived 2026-09-11 (review): the
    /// detector edges are FRAME-paced, and without the settle floor the
    /// shortest failure cycle (`DetectorWatch.failingStreak` + 1 = 4 frames)
    /// writes 7.5 pairs/s at 30 fps = 2.2 KiB/s, which reaches this cap in
    /// 39 min and deletes the parent's whole alert history in ~78 min. Any new
    /// writer into this file needs its own time floor and a line here before
    /// it ships. Rotation is a plain rename: every writer opens the path per
    /// line, so nothing holds a handle across it.
    static let capBytes = 5 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The exact line `append` writes (minus the newline); split out so the
    /// selftest can assert the format against the watchdog's.
    static func line(level: String, message: String, now: Date = Date()) -> String {
        "\(iso.string(from: now)) \(level) sentry-screen[uid \(getuid())]: \(message)"
    }

    /// Appends one line, creating the directory and file (0644) as needed, after rotating a file that has reached `cap`
    /// (`cap` is the budget; the parameter exists so the selftest can drive
    /// rotation without writing 5 MiB). One `open(2)` with O_APPEND, one `write(2)`: our
    /// line lands atomically at the end even beside the watchdog's `tee -a`
    /// (also O_APPEND). The refusal reason is the real
    /// errno. Returns nil on success, otherwise a one-line description of what
    /// failed and where — the caller logs it.
    static func append(level: String, message: String, path: String, cap: Int = capBytes) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return "cannot create \(dir): \((error as NSError).localizedDescription)"
        }
        let budget = rotateIfOverCap(path: path, cap: cap)
        let data = Data(((budget.map { line(level: $0.level, message: $0.message) + "\n" } ?? "")
            + line(level: level, message: message) + "\n").utf8)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return "cannot open \(path) for append: \(String(cString: strerror(errno)))" }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else {
            return "short write to \(path): \(written) of \(data.count) bytes\(written < 0 ? " (\(String(cString: strerror(errno))))" : "")"
        }
        return nil
    }

    /// Renames `path` to `path.1` once it reaches `capBytes`, and returns the
    /// budget line the caller writes into the fresh file first — the limit
    /// fails LOUDLY in the same file the parent already reads, whether the
    /// rename worked (INFO, rotated) or not (ALERT, still growing). nil when
    /// the file is under the cap, which is every healthy machine.
    static func rotateIfOverCap(
        path: String, cap: Int = capBytes, fm: FileManager = .default
    ) -> (level: String, message: String)? {
        let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        guard size >= cap else { return nil }
        let budget = "budget AlertsLog.capBytes, limit \(cap) B, observed \(size) B"
        do {
            _ = try? fm.removeItem(atPath: path + ".1")
            try fm.moveItem(atPath: path, toPath: path + ".1")
            return ("INFO", "\(budget) — rotated \(path) to \(path).1 (fix: AlertsLog.capBytes)")
        } catch {
            return ("ALERT", "\(budget) — rename to \(path).1 FAILED "
                + "(\((error as NSError).localizedDescription)), file left growing "
                + "(fix: inspect permissions on \((path as NSString).deletingLastPathComponent))")
        }
    }
}

/// Which capture-health transitions earn a durable `alerts.log` line
/// (2026-09-07). Pure so the selftest can falsify it.
///
/// Before this, capture loss produced a red menu-bar glyph and a dismissible
/// toast and nothing else: both are session UI, both are gone by the time a
/// parent looks, and the health report showed an outage that left the family
/// unprotected as a silent gap between runs. One ALERT per outage and one
/// INFO per restore — the same "one line per trip, one per recovery" shape
/// the watchdog's burst marker uses, and the reason healthy machines still
/// write nothing.
enum CaptureAlert {
    /// nil = this transition writes no durable line. `outageOpen` is the
    /// caller's flag, threaded back out so the intermediate `.starting` a
    /// re-arm publishes (lost → starting → protecting) cannot swallow the
    /// restore line, and so a reason that changes mid-outage does not open a
    /// second one.
    static func record(
        outageOpen: Bool, next: CaptureHealth
    ) -> (level: String, message: String, outageOpen: Bool)? {
        switch next {
        case let .lost(_, reason):
            guard !outageOpen else { return nil }
            return ("ALERT", "capture lost — protection is NOT running: \(reason). "
                + "Fix it from the SentryScreen menu-bar icon (Open repair…)", true)
        case .protecting:
            guard outageOpen else { return nil }
            return ("INFO", "capture restored — protection is running again", false)
        case .starting:
            return nil
        }
    }

    /// What the DURABLE half of a capture-health transition must do, once the
    /// deferral is applied. `record` above says WHAT a transition would
    /// write; this says WHEN the parent-visible ALERT is allowed to reach the
    /// file.
    enum Durable: Equatable {
        /// Hold the ALERT for `after` seconds, then write it if the outage is
        /// still open. Nothing reaches `alerts.log` yet.
        case hold(after: TimeInterval, level: String, message: String)
        /// The outage closed before its ALERT came due: a slow wake, not a
        /// failure. Drop the armed write — there is then nothing for a restore
        /// INFO to answer, so that is dropped with it.
        case drop
        /// Append this line now.
        case write(level: String, message: String)
    }

    /// Deferral (2026-09-11). The re-arm budget is
    /// 5 x 1 s and its receipt is self-labelled DERIVED with no live sleep/wake
    /// run behind it (`CaptureStream.rearmAttempts`). If `SCShareableContent`
    /// refuses for more than 5 s after an unlock, `onCaptureLost` fired, this
    /// file got `capture lost — protection is NOT running`, and a parent reading
    /// the health report saw an outage — for a machine that was merely slow to
    /// wake.
    ///
    /// So the ALERT now waits out `delay` (`AppDelegate.captureAlertDelaySecs`)
    /// and a loss that recovers inside it leaves NOTHING in `alerts.log`. The
    /// event is still fully traceable: the caller logs info-level `capture`
    /// records in `run.jsonl` both when the ALERT is armed and when it is
    /// dropped, and `CaptureStream`'s own `state=` lifecycle records were never
    /// touched.
    ///
    /// `delay <= 0` is the old behaviour exactly (the dev bypass, and the reason
    /// this is a parameter rather than a constant read here).
    ///
    /// `outageOpen` and `alertPending` are the caller's flags, threaded back
    /// out the way `record`'s already are.
    static func durable(
        outageOpen: Bool, alertPending: Bool, next: CaptureHealth, delay: TimeInterval
    ) -> (action: Durable, outageOpen: Bool)? {
        guard let r = record(outageOpen: outageOpen, next: next) else { return nil }
        guard r.outageOpen else {
            // A restore. An ALERT still in the holding window never reached the
            // file, so this outage was a transient and needs no answer.
            return alertPending
                ? (.drop, false)
                : (.write(level: r.level, message: r.message), false)
        }
        guard delay > 0 else { return (.write(level: r.level, message: r.message), true) }
        return (.hold(after: delay, level: r.level, message: r.message), true)
    }

    /// The two message prefixes `record` writes (the line is
    /// `<ts> LEVEL sentry-screen[uid N]: <message>`), matched by `outageOpen(at:)`.
    static let lostMarker = "]: capture lost — "
    static let restoredMarker = "]: capture restored — "

    /// Whether the previous PROCESS left an outage open in `alerts.log`:
    /// true when the last capture line in the file is the ALERT, not the
    /// INFO. Verifier 2026-09-07: the common way back from a lost Screen
    /// Recording grant is a relaunch — exit 7 after the re-grant, or exit
    /// 137 from System Settings' "Quit & Reopen" — and a fresh process that
    /// starts with `outageOpen = false` would never write the restore INFO,
    /// so the parent read an ALERT with no recovery line, forever. Seeding
    /// from the file also keeps a still-missing grant to ONE ALERT across
    /// the wrapper's relaunches instead of one per process.
    ///
    /// Reads only the last `tailBytes` (64 KiB ≈ 600 lines at ~110 B; the
    /// only other writers into this file are the hotkey alert and the
    /// rotation budget line, so the last capture line is always inside the
    /// tail). Missing or unreadable file ⇒ false, the fresh-install answer.
    static func outageOpen(at path: String, tailBytes: Int = 64 * 1024) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { fh.closeFile() }
        let size = Int(fh.seekToEndOfFile())
        fh.seek(toFileOffset: UInt64(max(0, size - tailBytes)))
        let text = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            if line.contains(lostMarker) { return true }
            if line.contains(restoredMarker) { return false }
        }
        return false
    }
}

/// The detector half of the durable trail (2026-09-11; the time
/// floor added on review). Same ALERT/INFO pair as `CaptureAlert`, but the
/// two signals are paced completely differently and that difference is the
/// whole reason this type exists:
///
/// a capture edge is bounded by the 5 s re-arm poll, while a detector edge is
/// FRAME-paced — `DetectorWatch` publishes `began` on the 3rd consecutive
/// throw and `recovered` on the very next success, so a 3-fail/1-success flap
/// (the expected shape of a thermal or driver fault, not an exotic case) edges
/// every 4 frames = 7.5 times a second at 30 fps. Writing the pair on every
/// edge filled `AlertsLog.capBytes` in 39 minutes and destroyed every
/// pre-existing capture/hotkey/updater line in ~78 (arithmetic in that
/// receipt) — the trail added to make an outage durable was deleting the
/// parent's history instead.
///
/// The floor is on the CLOSE, not on the open: an outage is recorded the
/// instant it is real, and the restore INFO is only written once the detector
/// has answered continuously for `recoverySettleSecs`. A flap therefore never
/// closes the pair, so the whole episode costs exactly one ALERT — and while
/// it flaps the open ALERT is the TRUE record, because protection is in fact
/// interrupted. Flooring the OPEN instead would have left the file claiming
/// "responding again" during a permanent failure whose re-open the floor
/// suppressed.
///
/// No cross-process seeding (deliberate, unlike `CaptureAlert.outageOpen`):
/// the way back from a lost capture grant IS a relaunch, with no in-process
/// edge left to write the restore, whereas a detector outage that survives a
/// relaunch re-edges on the new process's first frames (0.1 s at 30 fps) and
/// one that does not had nothing to restore.
struct DetectorAlertGate {
    /// Continuous healthy seconds before the restore INFO is written.
    ///
    /// 60 s, DERIVED from `Pipeline.detectorErrorEventInterval` (also 60 s),
    /// which throttles the `detector-error` record in run.jsonl for exactly
    /// this reason — the two halves of the detector trail then have the same
    /// cadence, instead of one file moving 60× faster than the other. The cost
    /// side is MEASURED 2026-09-11: the pair is 183 B + 114 B = 297 B, so one
    /// episode per settle window is ≈0.43 MB/day against `AlertsLog.capBytes`
    /// (5 MiB). This is a bound, not a tuning knob: if a healthy run ever
    /// writes a pair a minute the detector IS flapping and the open ALERT is
    /// correct — re-measure rather than raise this.
    ///
    /// Development override `SENTRY_DETECTOR_SETTLE_SECS=<seconds>`
    /// so a test run can see the close without
    /// waiting a minute. Production binaries carry no reader.
    static let recoverySettleSecs: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["SENTRY_DETECTOR_SETTLE_SECS"],
            let secs = TimeInterval(raw), secs >= 0 { return secs }
        return 60
    }()

    /// What one health edge asks the caller to do.
    enum Step: Equatable {
        case nothing
        /// Write the ALERT now: this is a new outage.
        case open
        /// Arm a one-shot close `recoverySettleSecs` from now, carrying this
        /// generation.
        case armClose(generation: Int)
    }

    /// What an armed close, having fired, asks the caller to do.
    enum Close: Equatable {
        case nothing
        /// Write the restore INFO: healthy for a whole window.
        case write
        /// The state moved after this timer was armed and the detector is
        /// healthy again but not yet for a whole window: one more window.
        case rearm(generation: Int)
    }

    private(set) var outageOpen = false
    private(set) var failing = false
    /// At most ONE pending close exists at a time — `rearm` is how a longer
    /// wait is expressed. A flapping detector edges 7.5×/s, and arming a timer
    /// per healthy edge would leave 7.5 live closures a second behind it
    /// (650k over a day): the same flood as the log lines, in memory.
    private(set) var closePending = false
    private(set) var generation = 0

    /// One published detector health edge (`failing` = `health != .healthy`).
    mutating func health(failing next: Bool) -> Step {
        generation += 1
        failing = next
        if next {
            guard !outageOpen else { return .nothing }
            outageOpen = true
            return .open
        }
        guard outageOpen, !closePending else { return .nothing }
        closePending = true
        return .armClose(generation: generation)
    }

    /// An armed close fired, carrying the generation it was armed with.
    mutating func close(generation: Int) -> Close {
        closePending = false
        guard outageOpen else { return .nothing }
        if generation == self.generation {
            outageOpen = false
            return .write
        }
        // The state moved since this timer was armed. Still failing ⇒ there is
        // nothing to close and no timer to keep alive; healthy again ⇒ the
        // health is younger than this window, so wait one more.
        guard !failing else { return .nothing }
        closePending = true
        return .rearm(generation: self.generation)
    }
}
