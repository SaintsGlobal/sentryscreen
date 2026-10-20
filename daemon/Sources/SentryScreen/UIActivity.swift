import AppKit
import Combine
import Foundation

// Activity feed and the one frame-path change the
// parent UI makes: the curtain owner-name lookup (§7.1, `WindowOwner`).
// The feed shows app name + time only — no titles, no URLs, no pixels.

/// One curtain drop as the popover shows it.
struct ActivityItem: Equatable {
    let app: String
    let at: Date
    let uid: uid_t

    /// Spec §7.3: a record with no `app=` renders as this, never as blank.
    static let unknownApp = "Unknown app"

    /// Parses a `curtain` record's info (`drop window 42 app=Google Chrome`,
    /// `drop (parole return) window 7`) into (app, window). nil unless the
    /// info is a drop. The prefix `drop… window <id>` is the pre-slice-6
    /// string byte-for-byte; `app=` is the appended enrichment (§7.1).
    static func parseDrop(_ info: String) -> (app: String, window: UInt32)? {
        guard info.hasPrefix("drop"), let w = info.range(of: " window ") else { return nil }
        let rest = info[w.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        guard let id = UInt32(digits) else { return nil }
        let tail = rest.dropFirst(digits.count)
        let app = tail.hasPrefix(" app=") ? String(tail.dropFirst(" app=".count)) : ""
        return (app.isEmpty ? unknownApp : app, id)
    }
}

// MARK: - WindowOwner (frame path, detectQueue only)

/// `kCGWindowOwnerName` for a curtain's window (spec §7.1). Resolved ONLY on
/// drop — by lift the window may be gone — and memoized so the lift record
/// carries the same name. detectQueue-confined, like every caller.
enum WindowOwner {
    /// Memo bound. DERIVED (spec §13): Curtain never holds anywhere near 64
    /// live windows, and each entry is evicted on its lift. Reaching it means
    /// lifts stopped arriving — said loudly, then the memo is cleared rather
    /// than grown.
    static let cacheLimit = 64
    /// Frame-path budget for one lookup, ms. DERIVED (spec §7.1): the
    /// comparable is the full-list ownership walk at 1.2–1.4 ms run every
    /// 3rd frame; a drop happens seconds apart at best, so a single-window
    /// query must sit in a fraction of that. Above it the lookup belongs off
    /// the frame path (main-thread hop + separate record) — a code move,
    /// not a bigger number.
    static let p95BudgetMs = 5.0
    /// Samples before the p95 is judged. DERIVED: p95 of fewer than 20
    /// samples is the max, and one cold call (MEASURED 2026-08-22, fresh
    /// process microbenchmark: first CGWindowListCopyWindowInfo 4.0-4.2 ms,
    /// then p50 0.10 / p95 0.16 ms; in the daemon the first drop measured
    /// 0.14 ms because WindowTracker has already warmed the connection)
    /// would trip the budget on its own.
    static let tripwireMinSamples = 20
    /// Timing ring. DERIVED: same bound as the memo; a p95 over the last 64
    /// drops is a session's worth on a family desktop.
    static let sampleCapacity = 64

    private static var cache: [CGWindowID: String] = [:]
    private static var samplesMs: [Double] = []
    private static var tripped = false

    /// Name for `action` on window `id`: a drop looks the window up and
    /// memoizes; anything else (lift, ghost-ban) returns the memo and evicts.
    /// `log` receives `curtain-app` records: the first timing sample, the
    /// memo-full warning, and the p95 tripwire.
    static func name(of id: CGWindowID, action: String, log: (String) -> Void) -> String? {
        guard action.hasPrefix("drop") else {
            let memo = cache.removeValue(forKey: id)
            return memo?.isEmpty == false ? memo : nil
        }
        // A handoff drop (`drop (handoff) window B`) replaces window A with
        // no lift for A (MEASURED 2026-08-22, run_fs.sh ui6), so A's entry
        // stays until here. Bounded and loud, never silently grown.
        if cache.count >= cacheLimit, cache[id] == nil {
            log("memo full at budget WindowOwner.cacheLimit=\(cacheLimit) (handoffs leave no "
                + "lift for the replaced window); clearing it — in-flight lifts will log "
                + "without app=")
            cache.removeAll()
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let name = lookup(id)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        cache[id] = name ?? ""
        record(ms, id: id, name: name, log: log)
        return name
    }

    /// One `CGWindowListCopyWindowInfo(.optionIncludingWindow, id)`; nil if
    /// the window is already gone or has no owner name.
    static func lookup(_ id: CGWindowID) -> String? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
            let name = list.first?[kCGWindowOwnerName as String] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    private static func record(_ ms: Double, id: CGWindowID, name: String?, log: (String) -> Void) {
        if samplesMs.isEmpty {
            log(String(format: "owner lookup %.2f ms window %u app=%@", ms, id, name ?? "<missing>"))
        }
        samplesMs.append(ms)
        if samplesMs.count > sampleCapacity { samplesMs.removeFirst() }
        guard !tripped, samplesMs.count >= tripwireMinSamples else { return }
        let p95 = Self.p95(samplesMs)
        if p95 > p95BudgetMs {
            tripped = true
            log(String(format: "TRIPWIRE owner lookup p95 %.2f ms over %d samples > budget "
                + "WindowOwner.p95BudgetMs=%.0f ms — move the lookup off the frame path "
                + "(spec §7.1), do not raise the budget", p95, samplesMs.count, p95BudgetMs))
        }
    }

    static func p95(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[Int(Double(s.count - 1) * 0.95)]
    }

    /// Stats for a summary line: (count, p50, p95, max) of the ring.
    static var stats: (n: Int, p50: Double, p95: Double, max: Double) {
        let s = samplesMs.sorted()
        guard !s.isEmpty else { return (0, 0, 0, 0) }
        return (s.count, s[s.count / 2], p95(s), s[s.count - 1])
    }
}

// MARK: - LogTail (spec §7.3)

/// Reads a jsonl file backwards in chunks until `want` matches are found.
enum LogTail {
    /// One decoded line. `event`/`info` are nil for frame and summary
    /// records; `ts` is on every record FrameLogger writes.
    struct Record: Decodable, Equatable {
        let ts: String
        let event: String?
        let info: String?
    }

    /// Read granularity. DERIVED: 64 KB is ≥ 22 worst-case records (2861 B)
    /// and ~560 clean ones, so a popover-full of drops on a quiet log is
    /// usually one read; larger buys nothing once pread is page-aligned.
    static let chunkBytes = 64 * 1024
    /// Cap on bytes scanned per session (shared across its rolled
    /// generations by `tailGenerations`). DERIVED from the record sizes Logger
    /// receipts (clean frame 116 B, detection-heavy 2861 B): 8 MB is ≥ 2,900
    /// heavy frames (~100 s of the worst case) or ~70,000 clean records.
    /// Hitting the cap with fewer than `want`
    /// matches is REPORTED (`truncated`), never rendered as a short list.
    static let maxTailBytes = 8 * 1024 * 1024

    struct ReadError: Error, CustomStringConvertible {
        let description: String
    }

    /// Newest-first records for which `matching` returned true. `matching`
    /// sees EVERY decodable record newest-first (so a caller can note the
    /// last timestamp or the last `capture` event in passing) and the scan
    /// stops as soon as `want` have matched. Malformed lines are skipped.
    /// Throws when the file cannot be opened or read — the caller must show
    /// that, not an empty list.
    static func tail(
        path: String, want: Int, maxBytes: Int = maxTailBytes,
        matching: (Record) -> Bool
    ) -> Result<(items: [Record], truncated: Bool), ReadError> {
        tailCounting(path: path, want: want, maxBytes: maxBytes, matching: matching)
            .map { (items: $0.items, truncated: $0.truncated) }
    }

    /// `tail` plus the bytes it read, so a caller walking several files can
    /// share one `maxBytes` budget across them.
    static func tailCounting(
        path: String, want: Int, maxBytes: Int = maxTailBytes,
        matching: (Record) -> Bool
    ) -> Result<(items: [Record], truncated: Bool, scanned: Int), ReadError> {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .failure(ReadError(description: String(cString: strerror(errno)))) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(ReadError(description: String(cString: strerror(errno)))) }
        var pos = Int(st.st_size)
        var items: [Record] = []
        var carry = Data()  // the partial FIRST line of the chunk just read
        var scanned = 0
        let newline = UInt8(ascii: "\n")
        while pos > 0, items.count < want, scanned < maxBytes {
            let n = min(chunkBytes, pos)
            pos -= n
            var buf = Data(count: n)
            let got = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n, off_t(pos)) }
            guard got == n else { return .failure(ReadError(description: "short read at \(pos)")) }
            scanned += n
            buf.append(carry)
            var lines = buf.split(separator: newline, omittingEmptySubsequences: false)
            // The first segment is cut unless this chunk starts the file.
            carry = pos > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() where !line.isEmpty {
                guard let rec = decode(line) else { continue }
                if matching(rec) {
                    items.append(rec)
                    if items.count == want { break }
                }
            }
        }
        return .success((items, items.count < want && pos > 0, scanned))
    }

    /// Rolled generations walked after `path` (`path.1` … `path.N`).
    /// DERIVED: Logger rolls on EVERY launch (FrameLogger.init) and keeps
    /// `logFilesKept - 1` rotated files, so a session's visible history lives
    /// across exactly these; anything older is gone from disk too.
    static let generations = FrameLogger.logFilesKept - 1

    /// `tail` over `path`, then `path.1`, `path.2` … while fewer than `want`
    /// have matched and `maxBytes` remains (one budget shared across files).
    /// MEASURED 2026-08-22 on this machine: after a watchdog restart every
    /// real drop sat in `run.jsonl.2` and `run.jsonl` was 1 KB — reading
    /// only the head file rendered "Nothing has been covered yet" for a
    /// session that WAS covered. A missing head file is an error (the
    /// session should have one); a missing generation just ends the walk.
    static func tailGenerations(
        path: String, want: Int, maxBytes: Int = maxTailBytes,
        matching: (Record) -> Bool
    ) -> Result<(items: [Record], truncated: Bool), ReadError> {
        var items: [Record] = []
        var budget = maxBytes
        for gen in 0...generations {
            let file = gen == 0 ? path : "\(path).\(gen)"
            if gen > 0, !FileManager.default.fileExists(atPath: file) { break }
            switch tailCounting(path: file, want: want - items.count, maxBytes: budget, matching: matching) {
            case let .failure(e):
                return .failure(gen == 0 ? e : ReadError(description: "\(file): \(e.description)"))
            case let .success(r):
                items += r.items
                budget -= r.scanned
                if r.truncated || budget <= 0 { return .success((items, items.count < want)) }
            }
            if items.count >= want { break }
        }
        return .success((items, false))
    }

    private static let decoder = JSONDecoder()
    private static let eventKey = Data("\"event\"".utf8)
    private static let tsKey = Data("\"ts\":\"".utf8)

    /// Full decode only for lines that carry an `event` key; the far more
    /// numerous frame records yield just their `ts` from a byte scan.
    static func decode(_ line: Data) -> Record? {
        // A torn line (the writer mid-record, or a rotation cut) is not a
        // record even when its `ts` survived.
        guard line.last == UInt8(ascii: "}") else { return nil }
        if line.range(of: eventKey) != nil {
            return try? decoder.decode(Record.self, from: line)
        }
        guard let r = line.range(of: tsKey) else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")),
            let ts = String(data: rest[rest.startIndex..<end], encoding: .utf8)
        else { return nil }
        return Record(ts: ts, event: nil, info: nil)
    }
}

// MARK: - UIActivity (main thread; lives only while the popover is open)

/// The feed the popover shows (spec §7.2–§7.4): this session's in-memory
/// ring plus a tail of every other session's `run.jsonl` (and its rolled
/// generations). Refreshed on open and every `refreshSecs` while open; a
/// closed popover costs nothing.
///
/// The file scan runs on `scanQueue`, never the main thread: MEASURED
/// 2026-08-22 (selftest case 5) a full scan costs ~12-16 ms/MB, so a file
/// that walks to `LogTail.maxTailBytes` blocks for ~100-130 ms — a visible
/// hitch if it ran under the popover. An own-session drop only re-merges the
/// ring with the cached other-session rows (it cannot change another
/// session's file); only the timer and open trigger a scan, and a tick that
/// finds one still running is skipped rather than queued.
final class UIActivity: ObservableObject {
    /// Rows shown. OWNER (spec §9.2): fixed by the design.
    static let rows = 10
    /// Rows visible at once in Settings › Recent activity; the rest of the
    /// `rows` scroll (`UIActivitySettingsSection.itemList`). OWNER decision
    /// 2026-10-20 (Settings cleanup): show 3, scroll the rest. Not measured;
    /// it only shortens the page, so `UIDriver.foldBudget` can only gain.
    static let visibleRows = 3
    /// Refresh while open. DERIVED (spec §7.3): mirrors
    /// `AppDelegate.captureLossPollSecs`; the timer is invalidated on close.
    static let refreshSecs: TimeInterval = 5
    /// A session whose log has been silent this long is flagged (spec §7.4).
    /// DERIVED: lean mode writes a summary every 60 s while capturing, so 15
    /// min of silence is 15 missed summaries — a stopped daemon, not a quiet
    /// screen.
    static let staleSecs: TimeInterval = 15 * 60
    /// Where every session's daemon logs (packaging/agent-launch.sh:
    /// `/Library/Logs/SentryScreen/<uid>/run.jsonl`).
    static let productionRoot = "/Library/Logs/SentryScreen"

    /// Other sessions' log root: `SENTRY_LOG_DIR` (tests) → production root.
    /// A demo reads NOTHING real unless told to: its screenshots are meant
    /// to contain no personal content.
    static func resolveRoot(demo: Bool) -> String? {
        if let dir = DevEnv.knob("SENTRY_LOG_DIR") { return dir }
        return demo ? nil : productionRoot
    }

    struct SessionHealth: Equatable {
        let user: String
        let text: String
    }

    @Published private(set) var items: [ActivityItem] = []
    /// `Cannot read <user>'s activity — <reason>` per unreadable session.
    @Published private(set) var errors: [String] = []
    /// Some session hit `LogTail.maxTailBytes` before `rows` drops.
    @Published private(set) var truncated = false
    @Published private(set) var sessions: [SessionHealth] = []

    private let state: UIState
    private let root: String?
    private let log: ((String) -> Void)?
    private var timer: Timer?
    private var observer: AnyCancellable?
    private let scanQueue = DispatchQueue(label: "sentry.ui.activity.scan", qos: .userInitiated)
    private var scanning = false
    /// Last scan of the other sessions, merged with the ring on every refresh.
    private var others = Scan()
    private var loggedRootError = false

    /// `log` receives `ui` records: the log-root read failure (once).
    init(state: UIState, root: String?, log: ((String) -> Void)? = nil) {
        self.state = state
        self.root = root
        self.log = log
    }

    func start() {
        // Idempotent by construction: `start()` overwriting `timer` without
        // invalidating the old one leaked a repeating scan per cycle (the
        // orphan kept firing with no popover open, against §7.3). Cheap, and
        // the pairing no longer depends on every caller getting it right.
        stop()
        refresh()
        // Own-session drops land in the ring at once; re-merge without
        // waiting for the file tick (no scan: the files did not change).
        observer = state.$recentEvents.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.merge() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshSecs, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observer = nil
    }

    /// Text the driver reads for `ui.activity.row.<i>` — the live row, not
    /// the value the view captured on appear (UIRegistry contract).
    func rowText(_ i: Int) -> String {
        guard items.indices.contains(i) else { return "" }
        return "\(items[i].app) \(Self.relative(items[i].at))"
    }
    func errorText(_ i: Int) -> String { errors.indices.contains(i) ? errors[i] : "" }
    func sessionText(_ i: Int) -> String {
        guard sessions.indices.contains(i) else { return "" }
        return "\(sessions[i].user) — \(sessions[i].text)"
    }

    /// Re-merge now from the cache, then rescan the files off-main.
    func refresh() {
        merge()
        guard !scanning else { return }
        scanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.scan(now: Date())
            DispatchQueue.main.async {
                self.scanning = false
                self.others = result
                if let e = result.rootError, !self.loggedRootError {
                    self.loggedRootError = true
                    self.log?("activity: cannot list log root \(self.root ?? "") — \(e)")
                }
                self.merge()
            }
        }
    }

    private func merge() {
        var all = state.recentEvents + others.items
        all.sort { $0.at > $1.at }
        items = Array(all.prefix(Self.rows))
        errors = others.errors
        truncated = others.truncated
        sessions = others.sessions
    }

    struct Scan {
        var items: [ActivityItem] = []
        var errors: [String] = []
        var truncated = false
        var sessions: [SessionHealth] = []
        var rootError: String?
    }

    /// One pass over every other session's log. Pure file I/O plus
    /// `getpwuid`; runs on `scanQueue`.
    private func scan(now: Date) -> Scan {
        var out = Scan()
        let uids: [uid_t]
        switch otherSessionUIDs() {
        case let .failure(e):
            out.rootError = e.description
            out.errors.append("Cannot read other sessions' activity — \(e.description)")
            return out
        case let .success(u):
            uids = u
        }
        for uid in uids {
            let user = Self.userName(uid)
            var lastTs: Date?
            var lastCapture: (at: Date, info: String)?
            var lastDetector: (at: Date, info: String)?
            let result = LogTail.tailGenerations(path: "\(root!)/\(uid)/run.jsonl", want: Self.rows) { rec in
                let at = UISettings.iso.date(from: rec.ts)
                if lastTs == nil { lastTs = at }
                if lastCapture == nil, rec.event == "capture", let at, let info = rec.info {
                    lastCapture = (at, info)
                }
                if lastDetector == nil, rec.event == "detector", let at, let info = rec.info {
                    lastDetector = (at, info)
                }
                return rec.event == "curtain" && rec.info?.hasPrefix("drop") == true
            }
            switch result {
            case let .failure(e):
                out.errors.append("Cannot read \(user)'s activity — \(e.description)")
            case let .success(r):
                out.truncated = out.truncated || r.truncated
                for rec in r.items {
                    guard let at = UISettings.iso.date(from: rec.ts),
                        let drop = ActivityItem.parseDrop(rec.info ?? "") else { continue }
                    out.items.append(ActivityItem(app: drop.app, at: at, uid: uid))
                }
                out.sessions.append(SessionHealth(user: user,
                    text: Self.healthText(
                        lastTs: lastTs, lastCapture: lastCapture, lastDetector: lastDetector, now: now)))
            }
        }
        return out
    }

    /// Numeric subdirectories of the log root, own uid excluded (this
    /// session's drops come from the ring, which is ahead of its own file).
    /// An unreadable root is an error the feed must show (spec §7.2): a
    /// regressed mode on /Library/Logs/SentryScreen would otherwise look
    /// exactly like "no other sessions". The caller logs it once per process.
    private func otherSessionUIDs() -> Result<[uid_t], LogTail.ReadError> {
        guard let root else { return .success([]) }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: root)
            return .success(names.compactMap { uid_t($0) }.filter { $0 != getuid() }.sorted())
        } catch {
            return .failure(LogTail.ReadError(description: (error as NSError).localizedDescription))
        }
    }

    /// Spec §7.4 wording. The latest `capture` event seen in the tail decides
    /// lost-vs-live; none seen means drops were logged after any outage, so
    /// the stream was live. Stale beats live: a session whose log stopped is
    /// not protecting whatever its last capture record said. The latest
    /// `detector` event decides the same way (review 2026-10-16): capture can
    /// stay healthy while every inference throws, and `state=failing` or
    /// `state=stalled` with no later `healthy`/`recovered`/`stall-cleared`
    /// means new content is not being checked, which is not "protecting".
    static func healthText(
        lastTs: Date?, lastCapture: (at: Date, info: String)?,
        lastDetector: (at: Date, info: String)? = nil, now: Date
    ) -> String {
        guard let lastTs else { return "no log records" }
        if now.timeIntervalSince(lastTs) > staleSecs { return "no recent log activity" }
        if let c = lastCapture {
            let state = c.info.split(separator: " ").first.map(String.init) ?? ""
            switch state {
            case "state=down", "state=lost", "state=fatal", "state=retry":
                return "capture lost since \(UIState.clockTime.string(from: c.at))"
            case "state=exclusion-failed":
                return "covers not excluded from capture since \(UIState.clockTime.string(from: c.at))"
            case "state=suspended":
                return "session inactive (last activity \(relative(lastTs, now: now)))"
            default: break
            }
        }
        if let d = lastDetector {
            let state = d.info.split(separator: " ").first.map(String.init) ?? ""
            if state == "state=failing" || state == "state=stalled" {
                return "detector failing since \(UIState.clockTime.string(from: d.at))"
            }
        }
        return "protecting (last activity \(relative(lastTs, now: now)))"
    }

    /// `parent`; `uid 503` when the account is unknown (spec §7.2).
    static func userName(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid) else { return "uid \(uid)" }
        return String(cString: pw.pointee.pw_name)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// `3 min. ago`; `now` for anything under a minute, which the formatter
    /// would otherwise print as `in 0 sec.` when the clocks straddle.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
