import CoreGraphics
import Darwin
import Foundation

/// Per-frame logging fidelity. `full` (default) writes one record per frame.
/// `lean` is for 24/7 production runs: clean frames collapse
/// into one summary record per 60 s window; everything else still logs at
/// full fidelity (receipt at FrameLogger.leanLingerSecs).
enum LogMode: String {
    case full
    case lean
}

/// JSONL logger + rolling latency stats (SPEC §5.6).
final class FrameLogger {
    private let path: String?
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    private var inferenceMs: [Double] = []
    private var frameCount = 0
    private var windowStart = CFAbsoluteTimeGetCurrent()

    struct FrameRecord: Encodable {
        let ts: String
        // Pixel-replay (--process) only: 0-based source frame index, the join
        // key against a fixture's <name>.truth.jsonl. Omitted for live runs,
        // where frames come from a capture stream with no fixture index.
        let frame: Int?
        let inferMs: Double
        /// Live curtain runs only (Pipeline.step): model time and curtain
        /// attribution time, the two halves of `inferMs` that matter.
        let detectMs: Double?
        let curtainMs: Double?
        let totalMs: Double
        // Media cover mode only (nil, and absent from the JSON, in region
        // mode): wall time of the whole media pixel path — MotionBoxes grid
        // sampling + heat + scroll guard + rigid translation + edge snap.
        // Budget: 2.0 ms/frame average.
        let mediaMs: Double?
        let regions: Int
        let mediaBoxes: Int  // stable media boxes this frame; 0 in region mode
        /// 1 exactly when the detector could not answer this frame and the
        /// pipeline re-painted the previous answered frame's covers
        /// (`Pipeline.holdCovers`). Absent from the JSON otherwise, so the frozen
        /// gate baseline — which never holds — is byte-identical. On such a
        /// record `detections` is EMPTY because no inference ran, while
        /// `tracked`/`painted` are the held covers: the field is what tells the
        /// two apart, and without it a held frame would read as a clean screen.
        let held: Int?
        let tracked: [RegionRecord]
        let detections: [DetectionRecord]
        // Pixel-replay only: the exact rects the overlay would paint for this
        // frame's regions (OverlayManager.paintRect, normalized bottom-left),
        // so headless scoring never needs a screen. Logged to 4 decimals, one
        // more than every other rect here — see `paintedQuantum`.
        let painted: [[Double]]?
        // Live runs with OS-assisted window tracking only (nil, and absent from
        // the JSON, headless and in region mode): the window that owned each
        // media-held region's cover this frame and where that window was when
        // the frame's pixels were on glass. `painted` is what the PIPELINE
        // decided; the overlay then advances it by this window's motion between
        // capture and glass (PaintExtrapolator), so a census that scores live
        // frames needs this to explain them.
        let windows: [WindowRecord]?
        // PAINT TRUTH. Live runs only (nil, and therefore absent from the JSON,
        // in every `--process` run — receipt: logcmp.py vs the i6-a baseline,
        // 13/13 IDENTICAL, and regioncheck.sh 5/5 IDENTICAL).
        //
        // Every rect the overlay actually handed to a CALayer since the previous
        // frame record, at the overlay's own 60 Hz cadence, in paint order.
        //
        // WHY:
        // the live census used to EXTRACT the cover from pixels, and dark video
        // content merges into that extraction — the bottom edge was overstated
        // by >20 CSS px on 5-14% of frames, max 250 px, which biases every
        // published live number optimistic. With this field the census's job
        // becomes "verify the pixels match the claimed paint, then score
        // exposure": a check, not an estimate.
        //
        // One entry per painted layer per tick: [t, regionID, x, y, w, h, source]
        //   t        CFAbsoluteTime at which the rect was committed, on a 0.1 ms
        //            lattice (1/167 of the 16.7 ms refresh — far under anything
        //            scored). Same clock as `capturedAt`, so paint and capture
        //            are directly comparable without a conversion.
        //   x,y,w,h  the CALayer frame: SCREEN POINTS, BOTTOM-LEFT origin, on a
        //            0.01 pt lattice. Deliberately NOT normalized — this is the
        //            last value between the pipeline and the glass, and
        //            renormalizing it would hand the census a conversion it
        //            would then have to trust.
        //   source   0 = pipeline sync (30 Hz), 1 = display-link tick (60 Hz),
        //            2 = lingering layer (a dead region held at its last rect —
        //            still black on screen, so a census that does not know about
        //            it sees an unexplained rectangle),
        //            3 = curtain at pipeline sync, 4 = curtain display-link
        //            advance. CAUTION: for sources 3/4 the id slot carries the
        //            curtain's CGWindowID, NOT a tracker region id — join
        //            against the frame record's `curtains[].wid`, never
        //            against `tracked[].id`.
        let paints: [[Double]]?
        // Present only when non-zero: paint entries the buffer refused since the
        // previous record (receipt at `paintBufferLimit`). A census that finds
        // this field must treat that interval's paint truth as INCOMPLETE, not
        // score around it.
        let paintsDropped: Int?
        // Curtain mode only (nil, and absent from the JSON, in other modes):
        // each active curtain's window id and its painted rect this frame,
        // normalized bottom-left, chrome strip already removed.
        let curtains: [CurtainRecord]?
        // Zoom (tiling) prototype, only with `zoomTiles` on
        // (nil, and absent from the JSON, everywhere else): which tile ran
        // this frame and the FULL-FRAME pass's own boxes, so a session review
        // can tell them from `detections` (the merged list, where a box the
        // tile found carries `tile`).
        let zoom: ZoomRecord?
    }

    struct ZoomRecord: Encodable {
        /// Tile index, row-major from the top left (`ZoomTiles.region`).
        let tile: Int
        /// The detector call that ran the full frame AND the tile on one
        /// handler (`Detector.detect(tile:)`; plus the weak pass when the
        /// Detection view asks for it), ms.
        let ms: Double
        /// Tile boxes dropped as cut by a tile seam (`ZoomTiles.isCut`).
        let cut: Int
        /// The full-frame pass's boxes before the merge.
        let full: [DetectionRecord]
    }

    struct CurtainRecord: Encodable {
        let wid: Int
        let box: [Double]
    }

    struct RegionRecord: Encodable {
        let id: Int
        let box: [Double]  // normalized x, y, w, h
    }

    struct WindowRecord: Encodable {
        let id: Int  // tracker region id
        let wid: Int  // CGWindowID
        let frame: [Double]  // screen points, TOP-LEFT origin: x, y, w, h
        /// The cover as fractions of `frame` (x, y, w, h), top-left origin —
        /// the window-relative pin the overlay rides during motion. Present
        /// whenever the region is owned; without it a census cannot tell a
        /// ridden cover from a lucky pixel fit.
        let pin: [Double]?
        /// Occlusion in progress: another layer-0 window is in front of this
        /// cover, so the overlay is deliberately NOT riding the window this
        /// frame (defect 1c). Absent, not `false`, when the cover is riding —
        /// freeze episodes are the thing a census counts.
        let frozen: Bool?
    }

    struct EventRecord: Encodable {
        let ts: String
        let event: String
        let info: String
    }

    /// Lean mode only: the 60 s window that stands in for the clean frames
    /// that were not written. Never emitted in full mode — see printSummary.
    struct SummaryRecord: Encodable {
        let ts: String
        let event: String  // always "summary"
        let frames: Int  // frames processed in this window, logged or not
        let suppressed: Int  // of those, clean frames not written
        let fps: Double
        let inferP50: Double
        let inferP95: Double
        // Reserved spot for counters other work adds (FrameLogger.count).
        // Absent, not `{}`, when nothing was counted.
        let counters: [String: Int]?
        // Live runs only (nil, and absent from the JSON, under every
        // `--process`/`--replay` run — see FrameLogger.live): resident set
        // size at this tick, so a lean soak-test log gets a memory trend for
        // free without anyone needing to run `ps` alongside it.
        let rssBytes: Int?
        /// Live lean runs only: what the pipeline was doing this window —
        /// `active` (frames flowed), `idle` (capture live, SCK delivered
        /// nothing: static screen), `paused`, `suspended` (lock/sleep/
        /// inactive session). Before this, a 0-frame window wrote no summary
        /// at all, so a day's coverage — protecting vs paused vs asleep —
        /// could not be computed from run.jsonl (health review 2026-08-25:
        /// 1,099 summaries in ~66 h, the other ~48 h indistinguishable).
        /// nil/absent on headless runs, same gate as rssBytes.
        let state: String?
        // Live runs only, same gate as rssBytes, and nil on the first live
        // summary tick besides (no prior sample to delta against yet — see
        // FrameLogger.previousCpuSeconds): process CPU% of one core over this
        // window, from getrusage deltas — see FrameLogger.cpuTripwirePct.
        let cpuPct: Double?
        /// Live runs only (same gate as rssBytes; nil/absent headless, so the
        /// frozen byte-compare baseline never sees it): the number of curtains
        /// painted at this tick. Set from the curtain tick (FrameLogger.setActiveCovers)
        /// and zeroed wherever curtains come down without one: pause and
        /// display change (`Pipeline.resetCurtain`) and shutdown. Capture
        /// suspension leaves it alone on purpose: covers stay painted there.
        let activeCovers: Int?
    }

    struct DetectionRecord: Encodable {
        let label: String
        let conf: Float
        let box: [Double]  // normalized x, y, w, h (Vision bottom-left origin)
        /// Zoom prototype only: the tile whose pass found this box
        /// (`Detection.tile`); absent for every full-frame box.
        var tile: Int? = nil

        init(_ d: Detection) {
            label = d.label
            conf = d.confidence
            box = [d.box.origin.x, d.box.origin.y, d.box.width, d.box.height]
                .map { (Double($0) * 1000).rounded() / 1000 }
            tile = d.tile
        }
    }

    /// Rounding lattice for the `painted` field, as 1/quantum. 1e-4 normalized
    /// = 0.128 px in x on a 1280-wide frame, 0.072 px in y.
    ///
    /// Receipt: `painted` is the only field a scorer measures sub-cell
    /// criteria on, and at the 1e-3 the other fields use it lands on a 1.28 px
    /// lattice — three independent visual verifiers (steady, resize,
    /// vanish-return, 2026-08-17/18) reported hitting that floor and could not
    /// resolve edge offsets the tightness and edge-offset budgets are stated
    /// to hundredths of a px in. One more decimal puts the log quantum an
    /// order of magnitude under the smallest quantity scored (the 3.15 px
    /// media pad). Every other rect here stays at 1e-3: they are inputs to the
    /// pipeline, not measurements of it, and moving them would rewrite the
    /// region-mode baseline for no gain.
    ///
    /// PaintSmoother.quantum tracks this — the smoother rounds media rects to
    /// the same lattice, so a finer log field alone would report nothing new.
    private static let paintedQuantum: Double = 10_000

    // MARK: - Paint truth (live only)

    /// Rounding lattices for a `paints` entry. 1e4 = 0.1 ms on the timestamp,
    /// 1e2 = 0.01 pt on the rect. Both an order of magnitude finer than the
    /// smallest quantity a live census scores (one 16.7 ms refresh; the 3.15 px
    /// media pad), and coarse enough that the field stays human-readable.
    private static let paintTimeQuantum: Double = 10_000
    private static let paintRectQuantum: Double = 100

    /// Paint entries held between two frame records.
    ///
    /// Receipt: the overlay paints at the display's 60 Hz and the buffer drains
    /// on every frame record,
    /// so the healthy occupancy is 2 ticks x the
    /// live region count = 2-4 entries. The measured worst case is 2 x the
    /// `OverlayManager.maxRegions` tripwire = 60. 4096 is 2.3 s of full-rate
    /// paint at that cap — far outside the healthy range, so it can only be
    /// reached by a pipeline stall of seconds, which is itself the bug. Costs
    /// 4096 x 7 doubles = 229 KB if it ever fills.
    ///
    /// Over the limit the logger refuses new entries and COUNTS them into the
    /// next record's `paintsDropped`, plus one stderr line: measurement data may
    /// be lost, but never silently.
    static let paintBufferLimit = 4096
    private let paintLock = NSLock()
    private var paintBuffer: [[Double]] = []
    private var paintDropped = 0
    private var paintDropWarned = false
    /// Busy-gate frame drops since the last drain. Same lock/drain shape as
    /// the paint buffer right above (simplify pass 2026-08-21: this replaced
    /// a second, parallel lock+drain in Pipeline), and piggybacks on
    /// drainPaints' existing per-frame lock acquisition — zero additional
    /// lock traffic on the accepted-frame path.
    private var frameDrops = 0

    /// One busy-gate drop. Called from the capture callback thread; drained
    /// into `counters` on detectQueue by `log()`.
    func recordDrop() {
        paintLock.lock()
        frameDrops += 1
        paintLock.unlock()
    }

    /// Records one committed CALayer frame. Called on the main thread from
    /// OverlayManager (sync, display-link tick, lingering hold); never called
    /// at all by `--process`, which exits before a Pipeline or an overlay
    /// exists. Lock-guarded because the drain runs on detectQueue.
    func recordPaint(at t: CFAbsoluteTime, regionID: Int, frame: CGRect, source: Int) {
        let tq = Self.paintTimeQuantum
        let rq = Self.paintRectQuantum
        let entry: [Double] = [
            (t * tq).rounded() / tq,
            Double(regionID),
            (Double(frame.origin.x) * rq).rounded() / rq,
            (Double(frame.origin.y) * rq).rounded() / rq,
            (Double(frame.width) * rq).rounded() / rq,
            (Double(frame.height) * rq).rounded() / rq,
            Double(source),
        ]
        paintLock.lock()
        if paintBuffer.count >= Self.paintBufferLimit {
            paintDropped += 1
            let warn = !paintDropWarned
            paintDropWarned = true
            paintLock.unlock()
            if warn {
                writeStderr(
                    "WARNING: paint-truth buffer full — budget paintBufferLimit, "
                    + "limit \(Self.paintBufferLimit), observed \(Self.paintBufferLimit + 1) "
                    + "pending entries; paint truth is INCOMPLETE from here "
                    + "(count reported per record as paintsDropped; fix: "
                    + "FrameLogger.paintBufferLimit)\n")
            }
            return
        }
        paintBuffer.append(entry)
        paintLock.unlock()
    }

    /// Takes everything buffered since the last call. Returns nil when nothing
    /// was recorded, which is exactly the headless case — so the field is absent
    /// from every `--process` log and the byte-compare baseline is untouched.
    private func drainPaints() -> (paints: [[Double]]?, dropped: Int?, frameDrops: Int) {
        paintLock.lock()
        let out = paintBuffer
        let dropped = paintDropped
        let drops = frameDrops
        paintBuffer.removeAll(keepingCapacity: true)
        paintDropped = 0
        frameDrops = 0
        paintLock.unlock()
        return (out.isEmpty ? nil : out, dropped == 0 ? nil : dropped, drops)
    }

    private let quiet: Bool
    private let mode: LogMode
    /// True whenever this is a real process, not a fixture replay (Pipeline's
    /// `liveProcess = opts.process == nil && opts.replay == nil`, main.swift
    /// — deliberately NOT the same as Pipeline's own `live`, which also
    /// requires `opts.overlays` for features that need a real screen; the
    /// memory tripwire does not). Gates the memory tripwire (see
    /// printSummary): headless replay — including every gate fixture — must
    /// never call into Mach's task_info, not just "happen not to trip the
    /// tripwire", so the frozen byte-compare baseline can never see a
    /// "memory" event or a non-nil `rssBytes`. Defaults false so every other
    /// FrameLogger call site (runReplay's own logger, in main.swift) is
    /// live-off without having to say so.
    private let live: Bool

    // These two resources default to the production file and stderr. Selftests
    // supply test-owned handles to exercise actual Foundation I/O failures.
    private let openLogFile: (String) -> FileHandle?
    private let errorHandle: FileHandle

    /// The installed --log path is in a directory the protected account owns,
    /// so it can be swapped for a FIFO, and a blocking open of a FIFO with no
    /// reader never returns (review 2026-10-16: the daemon would stall before
    /// its first frame). Open O_NONBLOCK|O_NOFOLLOW, keep the descriptor only
    /// when fstat says it is a regular file, then clear O_NONBLOCK. Anything
    /// else returns nil, which the callers already report loudly. The root
    /// watchdog moves a non-regular run.jsonl aside (watchdog.sh
    /// repair_log_files).
    static func openRegularFile(_ path: String) -> FileHandle? {
        let fd = Darwin.open(path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) == 0
        else {
            Darwin.close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    init(
        path: String?, quiet: Bool = false, mode: LogMode = .full, live: Bool = false,
        openLogFile: @escaping (String) -> FileHandle? = FrameLogger.openRegularFile,
        errorHandle: FileHandle = .standardError
    ) {
        self.quiet = quiet
        self.mode = mode
        self.live = live
        self.path = path
        self.openLogFile = openLogFile
        self.errorHandle = errorHandle
        if let path {
            // E1 (MEASURED 2026-08-22, second-account session): createFile
            // TRUNCATES, so every process restart — watchdog kickstart, TTL
            // exit, crash, session reload — erased the previous run's log
            // (observed: run.jsonl dropped 961 -> 577 lines mid-session). A
            // fail-loud logger that discards the record right before a restart
            // is the landmine. Roll a non-empty previous run to path.1 through
            // the SAME generation chain size-rotation uses, so each launch
            // starts clean and last run survives as path.1 .. path.(kept-1).
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: path),
                (attrs[.size] as? Int ?? 0) > 0 {
                let lifetime = Self.previousRunLifetime(attrs)
                if let lifetime, lifetime < Self.minRolledRunLifetimeSecs {
                    // a crash loop must not spend its generations on
                    // its own wreckage (receipt at minRolledRunLifetimeSecs).
                    // The createFile below truncates this short run — which is
                    // the point: the generations it would have pushed out hold
                    // the runs that still explain anything.
                    writeStderr(
                        "INFO: previous --log run at \(path) lived \(Int(lifetime))s, under "
                        + "budget minRolledRunLifetimeSecs=\(Int(Self.minRolledRunLifetimeSecs))"
                        + " — NOT rolling it, so \(path).1 keeps the older run "
                        + "(budget logFilesKept=\(Self.logFilesKept); fix: "
                        + "FrameLogger.minRolledRunLifetimeSecs)\n")
                } else if !rollGenerations(path) {
                    // The move failed (unwritable dir, cross-device) and the
                    // createFile below WILL truncate the prior run. Cannot
                    // preserve it here — but never lose evidence silently.
                    writeStderr(
                        "WARNING: could not preserve previous --log run at \(path) "
                        + "(roll to \(path).1 failed) — this launch truncates it. "
                        + "budget logFilesKept=\(Self.logFilesKept)\n")
                }
            }
            fm.createFile(atPath: path, contents: nil)
            handle = openLogFile(path)
            if handle == nil {
                // An unwritable --log path used to degrade to "no log" with
                // no message — a 24/7 install that silently records nothing
                // (2026-08-21: root-owned log dir + per-user
                // agent is exactly this shape). The run continues (logging
                // is evidence, not protection) but says so loudly.
                writeStderr(
                    "WARNING: cannot open --log \(path) for writing — NO LOG WILL BE "
                    + "WRITTEN for this run (fix: the path/permissions, or --log)\n")
            }
        } else {
            handle = nil
        }
    }

    // MARK: - Timestamps

    /// One formatter for the process, not one per record. Same reason
    /// `encoder` is a stored property: this runs on the per-frame path, and
    /// ISO8601DateFormatter construction is not free. Lock-guarded because
    /// event records come from the main thread while frame records come from
    /// detectQueue, and Foundation only documents formatter thread-safety for
    /// DateFormatter — an uncontended NSLock is orders of magnitude cheaper
    /// than the allocation it replaces.
    private static let isoFormatter = ISO8601DateFormatter()
    private static let isoLock = NSLock()
    private static func timestamp() -> String {
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoFormatter.string(from: .now)
    }

    // MARK: - Rotation + disk budget (always on, both modes)

    /// Disk budget for the `--log` file: `logFileCapBytes` per file across
    /// `logFilesKept` files — the active path plus `logFilesKept - 1` rotated
    /// generations (path.1 … path.3) — so 200 MB total, whatever the run does.
    ///
    /// DERIVED from measured record sizes (2026-08-21): a clean frame record
    /// is ~116 B and a detection-heavy one ~2861 B, so at 30 fps full mode
    /// writes 3.5 KB/s ≈ 300 MB/day on a clean stream and 86 KB/s ≈
    /// 7.4 GB/day under sustained detection. 200 MB therefore retains ~16 h
    /// of clean history — an incident from last night is still on disk this
    /// morning — and ~39 min of the sustained-detection worst case, which is
    /// the case that would otherwise fill the volume. Lean mode on a clean
    /// stream writes one summary per 60 s (~216 KB/day), so there the same
    /// budget is bounded by episode volume, not by frame rate.
    ///
    /// Cannot fire during the gate, and that margin is what keeps the frozen
    /// baseline valid (rotation emits a record the byte-compare has never
    /// seen): the largest fixture log in synth/runs/vispolicy-base is
    /// 505,548 B = 1.0% of one file's cap, and all 13 together are 2.9 MB.
    static let logFileCapBytes = 50 * 1024 * 1024
    /// Generations kept: the active file plus logFilesKept-1 rotated copies.
    /// Two consumers now: (a) size rotation, the 200 MB disk budget the
    /// receipt above sizes; (b) STARTUP roll (E1), which spends ONE generation
    /// per process launch regardless of size. So a restart/crash-loop keeps
    /// only the last logFilesKept-1 = 3 runs — the 4th restart evicts the
    /// oldest (loudly, see rollGenerations). Adequate for the fail-loud goal
    /// (the run that failed + its two predecessors survive); if a fast
    /// crash-loop ever needs deeper history, raise this, not silently.
    /// AMENDED 2026-09-11: a launchd crash loop relaunches about every
    /// ~10 s (ThrottleInterval), so for a crash that happens AFTER this logger
    /// opens, "3 restarts" was ~30-40 seconds of history — the evidence was
    /// always gone before anyone looked. A launch whose predecessor lived under
    /// minRolledRunLifetimeSecs now spends NO generation, so the loop cannot
    /// evict anything; this budget again bounds restarts, not crashes.
    static let logFilesKept = 4
    /// How long the PREVIOUS run must have lived for this launch to spend a
    /// generation rolling its log (E1's startup roll, above).
    ///
    /// 2026-09-11: launchd's KeepAlive relaunches a crash-looping
    /// agent about every 10 s (ThrottleInterval), and every launch spent one
    /// generation — so with logFilesKept = 4 the run that EXPLAINS the crash
    /// was gone in ~30-40 s, exactly when an operator started looking. A run
    /// that lived under this floor is the wreckage, not the evidence: it is
    /// truncated in place instead, and path.1 … path.3 keep the older runs
    /// (including the last healthy one) for as long as the loop lasts.
    ///
    /// WHICH loops this covers, precisely — the roll can only be spent by a
    /// launch that gets far enough to CONSTRUCT a FrameLogger, and
    /// `Pipeline.init` builds `Detector` first (main.swift), so:
    ///  * covered: a process that opened run.jsonl and then died inside 10 s —
    ///    a SIGSEGV or `die` past the detector, and any KeepAlive loop with a
    ///    sub-10 s lifetime. This is the shape that erased its own evidence.
    ///  * NOT covered, and does not need to be: a model-load failure
    /// never reaches this initializer, so it never opens or rolls
    ///    run.jsonl at all — the last healthy run's log simply stays put.
    ///  * unchanged: the capture-loss exit-7 relaunch (38-43 s per cycle,
    ///    main.swift captureLossRelaunchSecs) lives well past this floor and
    ///    rolls exactly as it did before.
    ///
    /// 10 s, DERIVED from two existing receipts rather than measured here:
    /// `packaging/agent-launch.sh` MIN_LIFETIME is 10 s for the same judgement
    /// ("a healthy daemon that was not asked to stop lives far longer than its
    /// own ≈3.4 s startup", MEASURED 2026-08-25), and launchd's 10 s
    /// ThrottleInterval is the crash loop's own period, so a looping launch is
    /// always under it and a healthy run always over it. Keep the two numbers
    /// equal: a run the wrapper calls abnormally short is the same run whose
    /// log is not worth a generation.
    static let minRolledRunLifetimeSecs: Double = 10

    /// How long the run that wrote the file at `path` lived: last write minus
    /// creation, both from the file the previous launch created (E1 creates it
    /// at startup and appends until the process stops). nil when the
    /// filesystem did not answer with a creation date, or answered with a
    /// negative span — unknown means ROLL, so a missing attribute can never
    /// silently suppress the roll.
    static func previousRunLifetime(_ attrs: [FileAttributeKey: Any]) -> Double? {
        guard let created = attrs[.creationDate] as? Date,
            let modified = attrs[.modificationDate] as? Date
        else { return nil }
        let lifetime = modified.timeIntervalSince(created)
        return lifetime >= 0 ? lifetime : nil
    }

    private let writeLock = NSLock()
    /// The active file's size, tracked in process: a stat per frame would put
    /// a syscall on the detect path for a number we already know.
    private var bytesWritten = 0
    /// Stop rotation after a rotation or write failure. A restored handle can
    /// still append after a successful seek; a failed write, reopen, or seek
    /// clears the handle and stops logging. Each failure reports its outcome.
    private var rotationDisabled = false

    /// The throwing API also keeps a failed warning write from raising an
    /// Objective-C exception. Losing stderr must not stop protection.
    private func writeStderr(_ text: String) {
        try? errorHandle.write(contentsOf: Data(text.utf8))
    }

    /// The one place bytes reach the log file.
    private func writeRecord(_ data: Data) {
        // `path`, not `handle`: rotation mutates `handle` under writeLock, and
        // this early-out (the no-`--log` case) must not read it unsynchronized.
        guard path != nil else { return }
        writeLock.lock()
        writeLocked(data)
        if bytesWritten >= Self.logFileCapBytes && !rotationDisabled { rotateLocked() }
        writeLock.unlock()
    }

    /// Newline framing + byte accounting in ONE place — `bytesWritten` is the
    /// trigger input for rotation, so a second copy of this body (rotateLocked
    /// once had one) could silently desync the tracked size from the real
    /// file. Caller holds writeLock.
    ///
    /// Receipt: the legacy FileHandle.write(_:) raises an Objective-C
    /// exception on I/O failure. The throwing API lets logging stop without
    /// aborting detection or covering. The focused logger selftest uses a
    /// real read-only handle to exercise this failure and repeated writes.
    private func writeLocked(_ data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            bytesWritten += data.count + 1
        } catch {
            // Close and warning writes must also use throwing APIs: they can
            // fail on the same volume that caused the original write error.
            try? handle.close()
            self.handle = nil
            rotationDisabled = true
            writeStderr(
                "WARNING: log write failed (\(error)) — LOGGING HAS STOPPED for "
                + "the rest of this run; protection continues. Check disk space "
                + "or volume health at \(path ?? "?") "
                + "(fix: FrameLogger.writeLocked)\n")
        }
    }

    /// Shift path -> path.1 -> … -> path.(logFilesKept - 1), oldest dropped.
    /// Does NOT touch `handle` — the caller owns close/create. Shared by
    /// startup (preserve the prior run, E1) and size rotation. Every
    /// destination is removed before its move: moveItem throws on an existing
    /// destination and one failed move mid-chain would cascade.
    /// Returns whether the primary path -> path.1 move succeeded. A false
    /// return means the caller is about to truncate `path` without having
    /// preserved it (E1): the caller must say so loudly, never silently.
    @discardableResult
    private func rollGenerations(_ path: String) -> Bool {
        let fm = FileManager.default
        let oldest = "\(path).\(Self.logFilesKept - 1)"
        // Eviction of a non-empty oldest generation is a real data drop; the
        // size-rotation path names its budget line, and startup rolls (now
        // once per launch) must not evict silently (2026-08-22).
        if ((try? fm.attributesOfItem(atPath: oldest))?[.size] as? Int ?? 0) > 0 {
            writeStderr(
                "INFO: log rotation evicting oldest generation \(oldest) — budget "
                + "logFilesKept=\(Self.logFilesKept)\n")
        }
        try? fm.removeItem(atPath: oldest)
        for i in stride(from: Self.logFilesKept - 2, through: 1, by: -1) {
            try? fm.removeItem(atPath: "\(path).\(i + 1)")
            try? fm.moveItem(atPath: "\(path).\(i)", toPath: "\(path).\(i + 1)")
        }
        try? fm.removeItem(atPath: "\(path).1")
        do { try fm.moveItem(atPath: path, toPath: "\(path).1"); return true }
        catch { return false }
    }

    /// path -> path.1 -> … -> path.(logFilesKept - 1), oldest deleted. The
    /// active path is recreated, so scripts tailing it keep a stable name
    /// (`tail -F`; plain `tail -f` follows the old inode across a rotation).
    /// Caller holds writeLock.
    private func rotateLocked() {
        guard let path else { return }
        let rotated = bytesWritten
        try? handle?.close()
        let fm = FileManager.default
        rollGenerations(path)
        fm.createFile(atPath: path, contents: nil)
        handle = openLogFile(path)
        let info = "rotated — budget logFileCapBytes, limit \(Self.logFileCapBytes) bytes, "
            + "observed \(rotated) bytes rotated to \(path).1, files kept \(Self.logFilesKept) "
            + "(fix: FrameLogger.logFileCapBytes)"
        guard handle != nil else {
            // Could not reopen (unwritable directory, full volume). Put the
            // rotated file back and keep appending to it instead of going
            // silent for the rest of the run.
            try? fm.removeItem(atPath: path)
            try? fm.moveItem(atPath: "\(path).1", toPath: path)
            handle = openLogFile(path)
            var seekFailure: Error?
            if let restoredHandle = handle {
                do {
                    try restoredHandle.seekToEnd()
                } catch {
                    // A reopened file starts at offset zero. Continuing after
                    // a failed seek could overwrite the retained evidence.
                    seekFailure = error
                    try? restoredHandle.close()
                    handle = nil
                }
            }
            rotationDisabled = true
            // Report whether the restored handle can append. A failed reopen
            // or seek stops logging instead of claiming the file will grow.
            let outcome: String
            if let seekFailure {
                outcome = "rotation is OFF and LOGGING HAS STOPPED (recovery seek failed: \(seekFailure))"
            } else if handle != nil {
                outcome = "rotation is now OFF and this file will grow past its budget"
            } else {
                outcome = "rotation is OFF and LOGGING HAS STOPPED (reopen failed twice)"
            }
            writeStderr(
                "WARNING: log rotation could not reopen \(path) — \(outcome); "
                + info + "\n")
            return
        }
        bytesWritten = 0
        // First record in the fresh file explains the gap to whoever reads it.
        let record = EventRecord(ts: Self.timestamp(), event: "log", info: info)
        if let data = try? encoder.encode(record) { writeLocked(data) }
        writeStderr("log: " + info + "\n")
    }

    func event(_ event: String, _ info: String) {
        let record = EventRecord(ts: Self.timestamp(), event: event, info: info)
        if let data = try? encoder.encode(record) { writeRecord(data) }
        print("[\(record.ts)] event=\(event) \(info)")
    }

    func log(
        detections: [Detection], regions: [TrackedRegion], mediaBoxes: Int = 0,
        inferMs: Double, totalMs: Double, mediaMs: Double? = nil,
        detectMs: Double? = nil, curtainMs: Double? = nil,
        blockedCount: Int? = nil, frame: Int? = nil,
        painted: [CGRect]? = nil, windows: [WindowRecord]? = nil,
        curtains: [CurtainRecord]? = nil, held: Bool = false, zoom: ZoomRecord? = nil
    ) {
        frameCount += 1
        inferenceMs.append(inferMs)
        let drained = drainPaints()
        // detectQueue, same thread as count() — no extra synchronization.
        if drained.frameDrops > 0 { counters["framesDropped", default: 0] += drained.frameDrops }
        // Lean mode: a frame with nothing detected, tracked, held, covered or
        // painted carries nothing the 60 s summary does not already say.
        // Anything else logs at full fidelity — including a paint-truth drop,
        // which marks the interval INCOMPLETE and must never be summarized
        // away. `event` records are NEVER suppressed in either mode: curtain
        // drops/lifts, tripwires, ownership changes and panic are the
        // safety-relevant records.
        if mode == .lean {
            // "Clean" is judged on POLICY-RELEVANT detections (blockedCount,
            // when the caller supplies it), not the raw detection list.
            // MEASURED (after-soak 2026-08-21): a family desktop with faces
            // on screen fired 16k benign FACE_* detections in 10 min; with
            // raw detections as the bar, lean mode logged 9,960/10,171
            // frames at full fidelity (~319 MB/day) — the mode bought
            // nothing. Benign classes are not policy evidence; blocked
            // detections, tracked regions, covers and paints are, and any
            // of those still forces full fidelity. Callers that do not
            // classify (nil) keep the conservative raw-detections bar.
            let policyRelevant = blockedCount ?? detections.count
            let clean = policyRelevant == 0 && regions.isEmpty && mediaBoxes == 0
                && (painted?.isEmpty ?? true) && (curtains?.isEmpty ?? true)
                && drained.paints == nil && drained.dropped == nil
            let now = CFAbsoluteTimeGetCurrent()
            if clean {
                guard now < lingerUntil else {
                    suppressed += 1
                    maybePrintSummary()
                    return
                }
            } else {
                lingerUntil = now + Self.leanLingerSecs
            }
        }
        let record = FrameRecord(
            ts: Self.timestamp(),
            frame: frame,
            inferMs: (inferMs * 10).rounded() / 10,
            detectMs: detectMs.map { ($0 * 10).rounded() / 10 },
            curtainMs: curtainMs.map { ($0 * 10).rounded() / 10 },
            totalMs: (totalMs * 10).rounded() / 10,
            mediaMs: mediaMs.map { ($0 * 1000).rounded() / 1000 },
            regions: regions.count,
            mediaBoxes: mediaBoxes,
            held: held ? 1 : nil,
            tracked: regions.map {
                RegionRecord(
                    id: $0.id,
                    box: [$0.rect.origin.x, $0.rect.origin.y, $0.rect.width, $0.rect.height]
                        .map { (Double($0) * 1000).rounded() / 1000 })
            },
            detections: detections.map(DetectionRecord.init),
            painted: painted?.map { rect in
                [rect.origin.x, rect.origin.y, rect.width, rect.height]
                    .map { (Double($0) * Self.paintedQuantum).rounded() / Self.paintedQuantum }
            },
            windows: windows,
            paints: drained.paints,
            paintsDropped: drained.dropped,
            curtains: curtains,
            zoom: zoom)
        if let data = try? encoder.encode(record) { writeRecord(data) }
        if !detections.isEmpty && !quiet {
            let summary = detections.map { "\($0.label)@\(String(format: "%.2f", $0.confidence))" }
                .joined(separator: " ")
            print("[\(record.ts)] \(summary) regions=\(regions.count) infer=\(record.inferMs)ms")
        }
        maybePrintSummary()
    }

    // MARK: - Lean mode

    /// Full-fidelity tail logged after the last non-clean frame in lean
    /// mode, 3.0 s of wall clock. Was 90 FRAMES (3.0 s at 30 fps); with the
    /// idle gate the detector cadence drops to 10 fps on a quiet screen, so
    /// the same 90 frames became a 9 s tail (MEASURED 2026-08-25 first
    /// deploy: 20:38:17-28Z logged at full fidelity after a lift at :17) —
    /// a duration is what the receipt below actually reasons about.
    ///
    /// ASSUMED, pending live confirmation: 3 s is the longest tail a cover can
    /// outlive its own evidence anywhere in the pipeline — Curtain's
    /// deadLiftSecs + curtainLingerSecs = 3.0 s (receipt at
    /// Curtain.curtainLingerSecs) — so an episode's lift, linger and final
    /// clear are all inside the linger and an analyzer never sees an episode
    /// end mid-air. (Note: the tracker's own hysteresis is much shorter —
    /// clearAfter is 8 frames ≈ 400 ms, stickyHold ≈ 1 s — so it is the
    /// curtain tail that sets this scale.) Confirm on a live lean run that no
    /// episode boundary lands outside the logged tail; if one does, raise this
    /// and re-receipt rather than accepting a clipped episode.
    static let leanLingerSecs: CFTimeInterval = 3.0
    private var lingerUntil: CFAbsoluteTime = 0
    private var suppressed = 0
    private var counters: [String: Int] = [:]

    /// One idle-gated frame (Pipeline.process skipped the detector). Counted
    /// into the summary as `framesSkippedIdle` so the gate's savings and its
    /// activity are both visible per window; also ticks the summary clock,
    /// since a window made only of skipped frames must still close.
    /// detectQueue only, same as `log`.
    func skipIdle() {
        counters["framesSkippedIdle", default: 0] += 1
        maybePrintSummary()
    }

    /// Live lean runs: called once per Pipeline idle tick (60 s, main-thread
    /// timer hopped to detectQueue) with the pipeline's current state. Closes
    /// the window when it is due exactly as a frame would, so a paused,
    /// suspended or static-screen minute still writes a summary (0 frames,
    /// RSS/CPU still sampled — the idle footprint is the number a background
    /// agent is judged on).
    /// Slack under the 60 s window for the idle tick. The tick is a 60 s
    /// Timer and the window it closed opened AT that tick, so the next tick
    /// lands at 60 s ± the timer's jitter: MEASURED on a test Mac 2026-09-08
    /// — window closed 01:06:30, the 01:07:30 tick found
    /// it 59.99 s old and skipped, and the paused summary came 120 s after
    /// the pause instead of 60. Half the paused/suspended minutes were
    /// missing that way. 1 s is ~30x the jitter Timer shows on a busy main
    /// thread (tens of ms) and keeps every summary inside 59–61 s, which
    /// SPEC §5.6's "every 60 s" means.
    static let idleTickToleranceSecs: CFAbsoluteTime = 1.0

    /// Returns whether the window closed (the selftest's only reader).
    @discardableResult
    func idleTick(state: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard live, mode == .lean else { return false }
        guard now - windowStart >= 60 - Self.idleTickToleranceSecs else { return false }
        // A window that DID see frames is active whatever the timer thinks
        // (MEASURED 2026-08-25 first deploy: 589-frame windows labeled
        // "idle" because the tick, not a frame, happened to close them).
        closeWindow(now: now, state: frameCount > 0 ? "active" : state)
        return true
    }

    /// Reserved spot for counters other work adds to the 60 s summary.
    ///
    /// detectQueue ONLY — the same thread as `log`, where the summary is
    /// assembled and reset. Do NOT call from the curtain `onChange`,
    /// cover-ownership or tripwire callbacks: those fire on the main thread,
    /// and this dictionary is deliberately unsynchronized. Counting one of
    /// those events means recording it on the frame path instead.
    func count(_ name: String, _ n: Int = 1) {
        counters[name, default: 0] += n
    }

    /// Per-window distribution sample; the summary carries `<name>P50` and
    /// `<name>P90` (integers) in `counters` and the samples reset with the
    /// window. detectQueue only, same as `count`. Used for the dirty-area
    /// receipt (Pipeline.process) — a gate that keys on a number needs the
    /// number's distribution in the log, not only the count of what it did.
    func sample(_ name: String, _ v: Double) {
        samples[name, default: []].append(v)
    }
    private var samples: [String: [Double]] = [:]
    private func foldSamples() {
        for (name, vals) in samples where !vals.isEmpty {
            let s = vals.sorted()
            counters[name + "P50"] = Int(s[s.count / 2].rounded())
            counters[name + "P90"] = Int(s[min(s.count - 1, Int(Double(s.count) * 0.9))].rounded())
        }
        samples.removeAll()
    }

    // MARK: - Memory tripwire (live only)

    /// RSS threshold above which a 60 s tick fires a loud "event":"memory"
    /// record. MEASURED 2026-10-01,
    /// installed build 23 on the
    /// test Mac, real popover driven through the UI queue: healthy max
    /// 188.2 MB (179.5 MiB) in the agent's own summary, at the start of a
    /// customer-flow settings run. 20 Settings open/close cycles plateaued
    /// (174.9-175.0 MiB from cycle 2 to 20), 30 min with Settings open
    /// stayed flat (175.9-176.0 MiB, one 177.4 sample), and a fresh agent
    /// reached 177.0 MiB within 90 s of launch, so this is the shipped UI's
    /// working set, not accumulation. The old 150 MiB came from a 46.6 MB
    /// headless August run before the paper-ink UI.
    /// Margin: 256 MiB = 1.43x the measured max and about half the SPEC §6
    /// 500 MB budget, so a real leak still fires long before it. The
    /// 2026-08-27 test Mac run that grew 170 -> 206 MB in 35 min (Detector.observe
    /// autoreleasepool note) was never remeasured; it is not counted as
    /// healthy here, and growth like it would still cross this line.
    /// If a healthy run reaches it, remeasure and re-receipt; do not raise.
    /// health_report.py `rss_max_mb` is this same value in decimal MB.
    static let memoryTripwireBytes = 256 * 1024 * 1024

    /// Resident set size via task_info(MACH_TASK_BASIC_INFO) — the same call
    /// `ps`/Activity Monitor's RSS column reads. nil only on a Mach call
    /// failure (not expected; task_info's contract requires checking the
    /// kern_return_t rather than assuming success).
    private func residentBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int(info.resident_size)
    }

    // MARK: - CPU tripwire (live only)

    /// CPU% (of one core) above which a 60 s tick fires a loud "event":"cpu"
    /// record.
    ///
    /// Calibration caveat carried over from that suggestion: the 22.5% max it
    /// is set beyond comes from 35 s sustained-motion runs,
    /// and this tripwire's own window is 60 s — neither catches slow
    /// multi-hour drift the way a long soak would. This tripwire's job is
    /// sustained overuse inside one window; drift detection is a separate,
    /// not-yet-done measurement (a long soak run), not something raising or
    /// lowering this number would buy.
    static let cpuTripwirePct = 30

    /// Consecutive 60 s windows over `cpuTripwirePct`. The "cpu" record and
    /// its stderr WARNING fire on the first window of a breach and then every
    /// `cpuEventEvery`-th consecutive window, not every window. MEASURED
    /// (live soak 2026-08-23..25): 161 cpu records in three days, one per
    /// window at 30-35%, all during ordinary 28 fps use — a loud line that
    /// fires every minute of normal load is noise that hides a real runaway.
    /// The streak is carried in the record (`streak=N`) so nothing is lost:
    /// a 10-window breach is one record saying streak=1 and one saying
    /// streak=10.
    private var cpuBreachStreak = 0
    /// DERIVED: 10 windows = 10 min between reminders, so a breach lasting
    /// a whole day writes ≤145 records instead of 1,440 while still showing
    /// up within one summary of starting.
    static let cpuEventEvery = 10

    // MARK: - Performance-tier tripwire (live only, OFF by default)

    /// `SENTRY_PERF_TRIPWIRE=1` arms an OBSERVE-ONLY check: when the 60 s
    /// summary's inference p95 stays over the configured fps's own frame
    /// interval for `perfBreachWindows` consecutive windows, write a loud
    /// `"event":"tier"` record naming the budget, the observed value, the
    /// streak and the tier the machine's measured behaviour belongs in — then
    /// one reminder every `perfEventEvery` windows while the breach lasts.
    ///
    /// ENV, NOT A CONFIG KEY, and the same receipt as
    /// `Pipeline.idleGateEnabled`: a config key is one more thing a parent can
    /// set wrong, and `Options.applyConfig` exits on unknown keys — so a key
    /// added here would also have to ship in `Options.configKeys` before any
    /// installer could ever write it. This is for the harness.
    ///
    /// IT DOES NOT ACT, ON PURPOSE.
    /// Stepping fps down at runtime silently moves the
    /// meaning of NINE other constants at once (the landmine list, doc §4):
    /// `Tracker.defaultClearAfter` and `defaultStickyHold` LOOK fps-derived
    /// and floor out below 20 fps; `Pipeline.idleDetectEvery`,
    /// `Pipeline.exposureFrames`, `Curtain.holdCleanFrames`,
    /// `Capture.transparentWarmup`, `MotionBoxes.scrollLagFrames`,
    /// `MotionBoxes.scrollShiftRange` and `PaintExtrapolator.
    /// maxVelocityHorizon` are fixed frame counts whose receipts reason in
    /// 30-fps terms. Two of those are themselves tripwires. And no step-down
    /// has ever been observed to fire, so there is nothing to receipt an
    /// action against. Observe first; the record is what a later decision
    /// would be built on.
    ///
    /// ARMED BY DEFAULT since the tiers shipped (owner decision 2026-09-02).
    /// It was off while it was an investigation prototype; a tier that decides
    /// the frame rate at launch needs a live tripwire saying whether the
    /// decision held, or the ASSUMED Intel fps at `PerfTier.noAne` can never be
    /// falsified by anything but a bug report. `SENTRY_PERF_TRIPWIRE=0` is the
    /// kill switch; live runs only, so the frozen gate baseline cannot see it.
    static let perfTripwireEnabled =
        DevEnv.knob("SENTRY_PERF_TRIPWIRE") != "0"
    /// Frame interval for the configured fps, ms. Set by `Pipeline` on live
    /// runs only and left at 0 everywhere else, so `--process` and `--replay`
    /// cannot reach the check at all — the same belt-and-braces the memory and
    /// CPU tripwires use to stay invisible to the frozen byte-compare baseline.
    var perfInferBudgetMs: Double = 0
    /// The tier this run resolved to, for the record's `tier=` field. Set
    /// alongside `perfInferBudgetMs`.
    var tierName = "?"
    private var perfBreachStreak = 0
    /// Consecutive 60 s windows over budget before the FIRST record fires.
    /// DERIVED from the CPU tripwire's measured failure mode (receipt at
    /// `cpuEventEvery`: firing on the first breached window produced 161
    /// records in three days of ordinary use). A tier verdict is a much
    /// heavier claim than a CPU warning, so it needs three consecutive minutes
    /// of sustained overrun rather than one — long enough that a single busy
    /// minute (a Chrome window opening contends for the GPU: 18-193 ms
    /// inference, receipt at `Detector.defaultComputeUnits`) cannot produce
    /// one.
    static let perfBreachWindows = 3
    /// Windows between REPEAT records once a breach is established. A separate
    /// constant from `perfBreachWindows` on purpose (2026-09-02):
    /// reusing 3 as the re-fire cadence would write ~480 records/day on
    /// exactly the sustained no-ANE machine this exists to catch — worse than
    /// the 161-in-three-days that `cpuEventEvery`'s receipt already calls
    /// "noise that hides a real runaway". Reuses `cpuEventEvery`'s derivation
    /// verbatim: 10 windows = 10 min between reminders, so a breach lasting a
    /// whole day writes <=145 records instead of 1,440, while still showing up
    /// within one summary of starting. The streak is carried in the record, so
    /// nothing is lost between reminders.
    static let perfEventEvery = cpuEventEvery

    /// Previous window's cumulative process CPU time (user+system, seconds),
    /// for the delta this window's `cpuSeconds()` reading is compared against.
    /// nil until the first live summary tick has run once — see printSummary's
    /// "first window has no delta" skip. detectQueue-only, same as
    /// `windowStart`/`frameCount` above: no lock needed.
    private var previousCpuSeconds: Double? = nil

    /// Cumulative process CPU time (user+system) since process start, via
    /// getrusage(RUSAGE_SELF) — the same call `ps` reads for %CPU, but
    /// cumulative rather than instantaneous, so a caller diffs two samples
    /// over a known wall-clock span to get a percentage. nil only on a
    /// getrusage failure (not expected; checked rather than assumed per the
    /// same convention as `residentBytes` above).
    private func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }

    /// Summary every 60 s (SPEC §5.6).
    private func maybePrintSummary() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - windowStart >= 60 else { return }
        closeWindow(now: now, state: "active")
    }

    private func closeWindow(now: CFAbsoluteTime, state: String) {
        foldSamples()
        printSummary(elapsed: now - windowStart, state: state)
        inferenceMs.removeAll()
        frameCount = 0
        suppressed = 0
        counters.removeAll()
        windowStart = now
    }

    func printSummary(elapsed: CFAbsoluteTime, state: String = "active") {
        // A 0-frame window is only ever closed by idleTick (live lean) or by
        // a window of nothing but idle-gated frames; every other caller
        // (full mode, --process, shutdown) keeps the old frame-driven shape.
        guard frameCount > 0 || live && (mode == .lean || !counters.isEmpty) else { return }
        let sorted = inferenceMs.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty
            ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0
        // Counters print on stdout in EVERY mode, not just lean's JSON
        // SummaryRecord below: full is the default, so without this a
        // full-mode run (the common case) would have nowhere at all to show
        // framesDropped/detectorErrors. Sorted for a stable line across ticks.
        let counterText = counters.isEmpty
            ? ""
            : " " + counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        // stdout for windows that processed frames, and — full mode only,
        // where stdout is the ONLY record — for a window of nothing but
        // idle-gated frames, so its counters are never reset unrecorded. A
        // lean idle tick (0 frames, no counters) stays off stdout: its
        // record is the rotated JSON summary below.
        if frameCount > 0 || (mode == .full && !counters.isEmpty) {
            print(String(
                format: "-- summary: %d frames, %.1f fps, infer p50=%.1fms p95=%.1fms",
                frameCount, fps, p50, p95) + counterText)
        }
        // Live only: `--process` (every gate fixture) and `--replay` must
        // never call into Mach's task_info at all, not just avoid tripping
        // the tripwire — the frozen byte-compare baseline has never seen a
        // "memory" event and headless replay is not where a resident-size
        // reading would mean anything anyway (no capture, no overlay window).
        var rss: Int? = nil
        if live {
            rss = residentBytes()
            if let rss, rss > Self.memoryTripwireBytes {
                let info = "budget memoryTripwireBytes, limit \(Self.memoryTripwireBytes) bytes, "
                    + "observed \(rss) bytes (fix: FrameLogger.memoryTripwireBytes)"
                // Same channel as every other tripwire here (rotation,
                // cover-ownership, curtain): stderr AND the log, never only
                // one — a daemon quietly over budget looks clean and is not.
                writeStderr("WARNING: memory: " + info + "\n")
                event("memory", info)
            }
        }
        // Same live-only gate as the RSS block above, and the same reason:
        // getrusage is real syscall cost a `--process`/`--replay` run (every
        // gate fixture) must never pay, and the frozen byte-compare baseline
        // has never seen a "cpu" event or a non-nil `cpuPct`.
        var cpuPct: Double? = nil
        if live {
            if let cpuNow = cpuSeconds() {
                // First window after process start has no prior sample to
                // delta against — skip the report rather than fabricate a 0%
                // reading (a real 0% and "no data yet" are different facts).
                if let prevCpu = previousCpuSeconds, elapsed > 0 {
                    let pct = (cpuNow - prevCpu) / elapsed * 100
                    cpuPct = pct
                    if pct > Double(Self.cpuTripwirePct) {
                        cpuBreachStreak += 1
                        if cpuBreachStreak == 1 || cpuBreachStreak % Self.cpuEventEvery == 0 {
                            let info = "budget cpuTripwirePct, limit \(Self.cpuTripwirePct)%, "
                                + "observed \(String(format: "%.1f", pct))% "
                                + "streak=\(cpuBreachStreak) (fix: FrameLogger.cpuTripwirePct)"
                            writeStderr("WARNING: cpu: " + info + "\n")
                            event("cpu", info)
                        }
                    } else {
                        cpuBreachStreak = 0
                    }
                }
                previousCpuSeconds = cpuNow
            }
        }
        // Performance-tier tripwire. Live AND armed AND given a budget —
        // three separate gates, any one of which keeps `--process` out.
        if live && Self.perfTripwireEnabled && perfInferBudgetMs > 0 && !sorted.isEmpty {
            if p95 > perfInferBudgetMs {
                perfBreachStreak += 1
                // First record at perfBreachWindows, then one every
                // perfEventEvery windows — two different constants, two
                // different receipts (see both above).
                if perfBreachStreak == Self.perfBreachWindows
                    || (perfBreachStreak > Self.perfBreachWindows
                        && (perfBreachStreak - Self.perfBreachWindows)
                            % Self.perfEventEvery == 0)
                {
                    let belongs = PerfTier.all.first { p95 <= 1000.0 / Double($0.fps) }
                    let info = "budget perfInferBudget (this tier's frame "
                        + "interval), limit "
                        + String(format: "%.1f", perfInferBudgetMs) + " ms, observed "
                        + "inferP95 " + String(format: "%.1f", p95) + " ms, "
                        + "tier=\(tierName) streak=\(perfBreachStreak) "
                        + "fitsTier=" + (belongs?.name.rawValue ?? "none-below-fpsFloor")
                        + " action=none (the tier NEVER changes at runtime — owner "
                        + "decision 2026-09-02, no moving parts) "
                        + "remediation=set `tier` in config.json, or re-receipt "
                        + "PerfTier.noAne against this machine"
                    writeStderr("WARNING: tier: " + info + "\n")
                    event("tier", info)
                }
            } else {
                perfBreachStreak = 0
            }
        }
        // LEAN ONLY below this line. The SummaryRecord type is one the frozen
        // byte-compare baseline has never seen, and a `--process` fixture run
        // can exceed 60 s of wall clock — so in full mode the summary stays
        // on stdout exactly where it has always been, and the gate cannot
        // observe this at all.
        guard mode == .lean else { return }
        let record = SummaryRecord(
            ts: Self.timestamp(), event: "summary", frames: frameCount,
            suppressed: suppressed,
            fps: (fps * 10).rounded() / 10,
            inferP50: (p50 * 10).rounded() / 10,
            inferP95: (p95 * 10).rounded() / 10,
            counters: counters.isEmpty ? nil : counters,
            rssBytes: rss,
            state: state,
            cpuPct: cpuPct.map { ($0 * 10).rounded() / 10 },
            activeCovers: live ? currentActiveCovers() : nil)
        if let data = try? encoder.encode(record) { writeRecord(data) }
    }

    // MARK: - Active-cover gauge

    /// Curtains painted right now. Written from the curtain tick (main
    /// thread) and read at the summary tick (detectQueue), so — unlike the
    /// deliberately unsynchronized `counters` — this one gauge is locked.
    private let activeCoversLock = NSLock()
    private var activeCovers = 0

    func setActiveCovers(_ n: Int) {
        activeCoversLock.lock()
        activeCovers = n
        activeCoversLock.unlock()
    }

    private func currentActiveCovers() -> Int {
        activeCoversLock.lock()
        defer { activeCoversLock.unlock() }
        return activeCovers
    }
}
