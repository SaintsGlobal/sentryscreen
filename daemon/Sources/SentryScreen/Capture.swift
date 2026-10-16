import AppKit
import CoreMedia
import ScreenCaptureKit

/// Crops a capture buffer down to the part of it that actually holds display
/// content.
///
/// The whole pipeline assumes one thing about a capture buffer: that it is a
/// TIGHT, uniform render of the display's point rect. Every normalized rect the
/// detector, MotionBoxes and the tracker produce is turned back into display
/// points by multiplying by the display size, and the overlay paints there. On
/// the main display that assumption holds exactly.
///
/// It does not hold on a Sidecar (iPad) display. Measured 2026-08-19 with
/// scratchpad/capprobe.swift, which runs Capture.start's exact configuration
/// and reports the opaque bbox of the delivered buffer:
///
///   display 1 (1920x1080 pt), config 1280x720  -> content 1280x720, minAlpha 255
///   display 3 (1366x946 pt),  config 1280x886  -> content 1056x730 at +112+0
///   display 3 (1366x946 pt),  config 2732x1892 -> content 2508x1736 at +112+0
///
/// The whole desktop is present, uniformly scaled, inset inside a larger buffer
/// whose remaining pixels are fully TRANSPARENT (alpha 0; the pad area matched
/// the alpha-zero pixel count exactly, 363200 px, on the 1280x886 buffer).
/// `scalesToFit = false` and `destinationRect` do not remove it.
///
/// Left unhandled this mis-scales every rect the daemon paints. Receipt
/// (runs/ipad-drag1, the run that motivated this): the media box hugged the
/// player correctly in buffer space, but normalizing against the padded buffer
/// turned the player's true 1120x630 pt rect into a painted 960x547 pt rect —
/// 89 pt of the player uncovered on the left, 70 on the right, 129 at the
/// bottom, and 45 pt of cover proud of the player's top edge, static for the
/// whole run. That is a cover-mode failure produced entirely by capture
/// geometry; MotionBoxes and EdgeSnap were doing the right thing.
///
/// Cropping to the content rect restores the pipeline's assumption for
/// everything downstream at once — detector input, motion grid, edge snap and
/// the overlay — instead of threading an offset through each of them.
///
/// Live capture only. `--process` (pixel replay) never constructs one: a
/// decoded video frame is not a display capture, its alpha carries no padding
/// meaning, and the headless logs must stay byte-identical to the baseline.
final class CaptureContentCrop {
    /// Buffer geometry this crop was measured against; a resolution change
    /// re-measures.
    private var measuredFor: (width: Int, height: Int)?
    /// Opaque content rect in buffer pixels, or nil for "buffer is all content"
    /// (the main-display case — then `apply` returns the buffer untouched).
    private var content: (x: Int, y: Int, width: Int, height: Int)?
    /// True only after the current geometry has produced at least one pixel
    /// of display content. This distinguishes an ordinary uncropped main
    /// display from a fully transparent ScreenCaptureKit warm-up frame.
    private var measuredContentPresent = false
    private var scratch: CVPixelBuffer?
    /// Consecutive fully-transparent frames seen while trying to measure. A
    /// transparent frame during stream warm-up must not latch a no-crop
    /// verdict for the whole run, so measurement retries until this budget is
    /// spent, then latches loudly.
    private var transparentFrames = 0
    /// Budget transparentWarmup: 1 s of frames. SCK warm-up transients span at
    /// most a few frames; a buffer still transparent after a full second is not
    /// warming up, it is capturing nothing.
    ///
    /// RESTATED AS A DURATION 2026-09-02 (PerfTier.swift): "a full second" is
    /// what the receipt reasons about, but the constant was a fixed 30 frames,
    /// so at the no-ane tier's 15 fps the same budget would have waited 2 s
    /// before saying anything — a doubled silent window on the machines least
    /// able to afford it. 30 frames at 30 fps (unchanged), 15 at 15 fps.
    /// Live capture only: `--process` never constructs a CaptureContentCrop,
    /// so no headless log moves either way.
    static let transparentWarmupSecs = 1.0
    static func transparentWarmup(fps: Int) -> Int {
        max(1, Int((transparentWarmupSecs * Double(fps)).rounded()))
    }
    /// Resolved once from the effective fps at construction.
    private let transparentWarmup: Int
    private let onFirstMeasure: (String) -> Void
    /// Aspect agreement between the cropped content and the display it claims
    /// to be. A crop whose shape does not match the display is not a padding
    /// artifact we understand, and silently painting rects derived from it
    /// would be worse than stopping. 2% is ~4x the 0.18% disagreement measured
    /// between the two axes on the Sidecar display (1056/1366 = 0.7731 px/pt
    /// horizontally vs 730/946 = 0.7717 vertically, both from integer buffer
    /// sizes) and well under the 20% the unhandled padding itself produced.
    private static let aspectTolerance = 0.02

    init(fps: Int, onFirstMeasure: @escaping (String) -> Void) {
        self.transparentWarmup = Self.transparentWarmup(fps: fps)
        self.onFirstMeasure = onFirstMeasure
    }

    /// A restarted ScreenCaptureKit stream must prove content again. The
    /// previous stream's opaque-main-display result is not evidence for the
    /// new stream generation.
    func resetMeasurement() {
        measuredFor = nil
        content = nil
        measuredContentPresent = false
        scratch = nil
        transparentFrames = 0
    }

    /// Returns `buffer` unchanged when it is fully opaque (every display we
    /// have measured except Sidecar), else a cropped copy of its content rect.
    /// Caller must be the single frame consumer: the crop target is reused, so
    /// only one cropped frame may be in flight. Pipeline.process's `busy`
    /// semaphore already guarantees that.
    func apply(_ buffer: CVPixelBuffer, displaySize: CGSize) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return buffer
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if measuredFor == nil || measuredFor! != (width, height) || !stillValid(buffer) {
            measure(buffer, width: width, height: height, displaySize: displaySize)
        }
        guard measuredContentPresent else { return nil }
        guard let c = content else { return buffer }
        // A failed copy cannot fall back to the padded source: its coordinate
        // space is already known to be unsafe for detector and overlay use.
        return copy(buffer, rect: c)
    }

    /// Cheap per-frame re-validation of the cached content rect: the pixel just
    /// inside each content edge must still be opaque and the pixel just outside
    /// it (where padding exists) must still be transparent. 8 reads, not 1.1M.
    /// A Sidecar reconnect or display-mode change moves the inset, and a stale
    /// crop would be as wrong as no crop at all — silently.
    private func stillValid(_ buffer: CVPixelBuffer) -> Bool {
        guard let c = content else { return true }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return true
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return p[y * bpr + x * 4 + 3]
        }
        let midX = c.x + c.width / 2
        let midY = c.y + c.height / 2
        // Inside each edge: must be content.
        guard alpha(c.x, midY) > 0, alpha(c.x + c.width - 1, midY) > 0,
            alpha(midX, c.y) > 0, alpha(midX, c.y + c.height - 1) > 0
        else { return false }
        // Outside each padded edge: must still be pad.
        if c.x > 0, alpha(c.x - 1, midY) > 0 { return false }
        if c.x + c.width < width, alpha(c.x + c.width, midY) > 0 { return false }
        if c.y > 0, alpha(midX, c.y - 1) > 0 { return false }
        if c.y + c.height < height, alpha(midX, c.y + c.height) > 0 { return false }
        return true
    }

    private func measure(
        _ buffer: CVPixelBuffer, width: Int, height: Int, displaySize: CGSize
    ) {
        measuredFor = (width, height)
        content = nil
        measuredContentPresent = false
        scratch = nil
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
            let base = CVPixelBufferGetBaseAddress(buffer)
        else { return }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = p + y * bpr
            var x = 0
            while x < width {
                if row[x * 4 + 3] > 0 {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    // Right edge of this row: scan inward from the far side.
                    var r = width - 1
                    while r > x, row[r * 4 + 3] == 0 { r -= 1 }
                    if r > maxX { maxX = r }
                    break
                }
                x += 1
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        guard maxX >= minX, maxY >= minY else {
            transparentFrames += 1
            if transparentFrames >= transparentWarmup {
                onFirstMeasure(
                    "capture: buffer \(width)x\(height) fully transparent for "
                    + "\(transparentFrames) consecutive frames (budget transparentWarmupSecs "
                    + "limit \(transparentWarmup) frames) — no display content to crop to "
                    + "(fix: Capture.start display selection)")
            } else {
                measuredFor = nil  // warm-up transient: re-measure next frame
            }
            return
        }
        transparentFrames = 0
        let w = maxX - minX + 1
        let h = maxY - minY + 1
        if w == width && h == height {
            measuredContentPresent = true
            return  // main display: no padding, no crop
        }
        let want = displaySize.width / displaySize.height
        let got = CGFloat(w) / CGFloat(h)
        guard displaySize.height > 0, abs(got - want) / want <= Self.aspectTolerance else {
            onFirstMeasure(
                "capture: TRIPWIRE aspect — buffer \(width)x\(height) holds content "
                + "\(w)x\(h) at +\(minX)+\(minY), aspect \(String(format: "%.4f", got)) vs "
                + "display \(Int(displaySize.width))x\(Int(displaySize.height)) aspect "
                + "\(String(format: "%.4f", want)); budget captureContentAspect limit "
                + "\(Self.aspectTolerance). Painted rects would be mis-scaled "
                + "(fix: CaptureContentCrop.aspectTolerance / Capture.start config)")
            return
        }
        measuredContentPresent = true
        content = (minX, minY, w, h)
        onFirstMeasure(
            "capture: display content is INSET in the capture buffer — \(width)x\(height) "
            + "buffer holds \(w)x\(h) of content at +\(minX)+\(minY) (pad L\(minX) "
            + "R\(width - maxX - 1) T\(minY) B\(height - maxY - 1), transparent). Cropping; "
            + "effective capture width \(w) px = "
            + "\(String(format: "%.4f", CGFloat(w) / displaySize.width)) px/pt")
    }

    private func copy(
        _ buffer: CVPixelBuffer, rect: (x: Int, y: Int, width: Int, height: Int)
    ) -> CVPixelBuffer? {
        if scratch == nil {
            var out: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            guard
                CVPixelBufferCreate(
                    kCFAllocatorDefault, rect.width, rect.height,
                    kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess
            else { return nil }
            scratch = out
        }
        guard let dst = scratch else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let src = CVPixelBufferGetBaseAddress(buffer),
            let out = CVPixelBufferGetBaseAddress(dst)
        else { return nil }
        let sbpr = CVPixelBufferGetBytesPerRow(buffer)
        let dbpr = CVPixelBufferGetBytesPerRow(dst)
        let bytes = rect.width * 4
        for y in 0..<rect.height {
            memcpy(
                out.advanced(by: y * dbpr),
                src.advanced(by: (rect.y + y) * sbpr + rect.x * 4), bytes)
        }
        return dst
    }
}

/// ScreenCaptureKit stream for the main display, downscaled (SPEC §5.1).
/// Thread-safe identity gate between ScreenCaptureKit's callback queue and
/// stream replacement on the main queue. A late frame from an invalidated
/// stream never reaches Pipeline, even after a replacement becomes live.
final class CaptureStreamGenerationGate {
    private let lock = NSLock()
    private var accepted: ObjectIdentifier?
    private var epoch: UInt64 = 0

    func accept(_ stream: AnyObject) {
        lock.lock()
        accepted = ObjectIdentifier(stream)
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        accepted = nil
        epoch &+= 1
        lock.unlock()
    }

    func token(for stream: AnyObject) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return accepted == ObjectIdentifier(stream) ? epoch : nil
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepted != nil && epoch == token
    }
}

final class CaptureStream: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let capturedAt: CFAbsoluteTime
        /// Identity of the SCStream generation that produced this frame.
        /// Revalidated at Pipeline's actual health-Receipt edge.
        let generation: UInt64
        /// Fraction of the frame SCK reports as changed since the previous
        /// delivered frame (sum of `SCStreamFrameInfo.dirtyRects` areas over
        /// the frame area, clamped to 1). 1.0 when the attachment is absent
        /// or unparseable — "unknown" must read as "everything changed", so a
        /// missing attachment can only cost CPU, never a detection. Consumed
        /// by Pipeline.process's idle-frame gate (receipt at
        /// Pipeline.idleDirtyFraction).
        let dirtyFraction: Double
    }

    private var stream: SCStream?
    private let generationGate = CaptureStreamGenerationGate()
    private var display: SCDisplay?
    /// Hook: the display scope of the stream that just STARTED.
    /// Pipeline logs the tripwire record and hands the value to the parent UI.
    /// Called on the main thread because resolving `NSScreen.localizedName`
    /// reads AppKit state. Nothing in the capture path reads it back — this
    /// stream still captures exactly one display.
    var onDisplayScope: ((DisplayScope) -> Void)?
    private let onFrame: (Frame) -> Void
    /// Frame-delivery queue. `SENTRY_CAPTURE_QOS=ui` raises it for A/B
    /// measurement. Default stays .default — MEASURED 2026-08-25:
    /// raising it to userInteractive left region
    /// latency unchanged (118 ms) and made curtain worse/noise (244 ms), so
    /// it was REJECTED; only the detect queue's raise survived measurement
    /// (receipt at Pipeline.detectQoS).
    static let captureQoS: DispatchQoS = DevEnv.knob("SENTRY_CAPTURE_QOS") == "ui"
        ? .userInteractive : .default
    private let queue = DispatchQueue(label: "sentryscreen.capture", qos: CaptureStream.captureQoS)
    /// Sink for the loud `"event":"capture"` lifecycle records. Set by
    /// Pipeline; nil under `--process` (pixel replay), which constructs a
    /// CaptureStream but never calls `start`, so none of the lifecycle machinery
    /// below can run there.
    var onState: ((String) -> Void)?
    /// `--capture-loss banner` only (C1): called on the main queue when the
    /// re-arm budget is exhausted INSTEAD of exit(2). nil (dev default)
    /// keeps the fatal exit.
    var onCaptureLost: (() -> Void)?
    /// Main queue. Fires before any automatic replacement stream starts so
    /// its first frame must earn new pixel-content and health Receipts.
    var onStreamGenerationInvalidated: (() -> Void)?
    /// Main-queue read for the capture-loss poll loop.
    var isLive: Bool { live }
    /// Main-queue reads for the UI: a stream that is down because the session
    /// is inactive or the screen is locked is EXPECTED down (no retry budget
    /// spent), and a re-arm chain in flight means "down" is about to be
    /// re-decided. Both feed the UI-only debounce in AppDelegate; the log
    /// records stay exactly as reported.
    var isSuspended: Bool { suspended }
    var isRestoring: Bool { rearmInFlight || rearmWanted || rearmAttempt != nil }
    func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generationGate.isCurrent(generation)
    }
    /// Shape of the first frame's `dirtyRects` attachment (element type and
    /// count), for the "startup" record: the idle gate's whole premise is
    /// that this attachment parses, and "1.0 = unknown" is indistinguishable
    /// from "1.0 = whole screen changed" without it. Written once on the
    /// capture queue, read after the first frame on detectQueue.
    private(set) var dirtyAttachmentShape: String?

    /// Fires on the suspended⇄active edge (main queue). The pipeline pauses
    /// the WindowTracker while suspended. Capture (SCStream + CoreML) stops
    /// on session-inactive / lock / sleep, but the tracker is FRAME-DRIVEN
    /// (`setTracked` is only reached from `process()` via `curtainRects`), so
    /// with no frames it keeps polling its last window set at 120 Hz forever:
    /// ~1.3% of a core PER tracked window on an INACTIVE user's session, and a
    /// stale cover frozen behind an apiFailed streak (E2, MEASURED 2026-08-22:
    /// window 28352, 14763 consecutive apiFailed polls, tripwire fired). The
    /// callback lets the pipeline drop the tracked set on suspend; the first
    /// frame after resume repopulates it. true = suspended.
    var onSuspendedChange: ((Bool) -> Void)?
    private var lastSuspendedReported = false

    /// Main queue. Fresh retry chain after a capture-loss period — the poll
    /// loop calls this when CGPreflightScreenCaptureAccess turns true again.
    /// Full budget on purpose: the budget bounds retries against a machine
    /// that claims to be ready, and a restored permission is a new claim.
    func retryAfterCaptureLoss() {
        guard !live, !suspended, !stopping, startArgs != nil else { return }
        report("state=retry capture-loss poll saw permission restored — re-arming")
        beginRearm()
    }

    // MARK: - Stream lifecycle (main queue only)
    //
    // A stream stop used to be fatal: `didStopWithError` called exit(2) on ANY
    // stop, including the routine one a display sleep produces. Everything in
    // this section is confined to the main queue so the delegate callback (the
    // capture queue), the NSWorkspace notifications (main) and the retry chain
    // (main) cannot race each other.

    /// Re-arm attempts after an unexpected stream stop, and the gap between
    /// them.
    ///
    /// DERIVED, not measured: this is the same 5-attempt / 1 s shape as
    /// `refreshExclusion` below — the daemon's only other SCStream /
    /// SCShareableContent recovery — reused here for the same reason, to ride
    /// out a transient WindowServer refusal without pretending to be a
    /// supervisor (a supervisor is Milestone 3). No live sleep/wake run has
    /// confirmed 5 s is enough runway for SCShareableContent to come back after
    /// a wake, which is exactly why every suspend/resume transition RESETS
    /// this budget (see `suspendBegan`/`resumeBegan`) instead of spending it:
    /// the budget bounds retries against a session that is AWAKE, UNLOCKED,
    /// NOT PARKED OFF CONSOLE, and still refusing. Since 2026-09-25
    /// that includes an off-console session with a live display (remote
    /// desktop, Screen Sharing); the 5 × 1 s shape is UNMEASURED there.
    private static let rearmAttempts = 5
    private static let rearmDelay: TimeInterval = 1
    /// `start` arguments, kept so a re-arm rebuilds the identical stream.
    private var startArgs: (fps: Int, width: Int, displayID: CGDirectDisplayID?)?
    /// True between a successful `start` and the stop that ends it.
    private var live = false
    /// Bumped on every transition that invalidates an in-flight retry chain
    /// (sleep, wake, a fresh chain). An async attempt whose generation is stale
    /// discards its own result instead of stepping on the current chain.
    private var rearmGeneration = 0
    /// The attempt a retry chain is on, or nil when no chain is in flight.
    private var rearmAttempt: Int?
    /// True while an `attemptRearm` Task is running. AT MOST ONE may be alive:
    /// `stream` is a single slot, so two Tasks both inside `await start()` would
    /// each assign it and whichever lost would keep capturing forever, unowned
    /// and never torn down (`didStopWithError` ignores it by identity, which is
    /// exactly why nothing would reclaim it). The generation counter serializes
    /// OUTCOMES; this serializes TASKS.
    private var rearmInFlight = false
    /// A transition asked for a fresh chain while a Task was still in flight.
    /// Acted on when that Task lands, not by spawning a second one.
    private var rearmWanted = false
    /// Why capture is currently suspended, if it is. A stream stop that
    /// arrives while ANY reason is present is EXPECTED and spends no retry
    /// budget; re-arm is deferred until the resume that clears the LAST
    /// reason. Reasons are independent and overlap in real sequences — the
    /// common wake path is sleep+screenLocked, where didWake clears `.sleep`
    /// but the console is still on the password screen until
    /// screenIsUnlocked clears `.screenLocked`; re-arming at didWake would
    /// spend the whole budget against a locked session that cannot vend
    /// capture yet.
    enum SuspendReason: String {
        case sleep
        case screenLocked = "screen-locked"
        case sessionInactive = "session-inactive"
    }
    private var suspendReasons: Set<SuspendReason> = []
    private var suspended: Bool { !suspendReasons.isEmpty }
    /// A display change landed while suspended, so its rebuild was deferred.
    /// LATCHED, because the resume path only rebuilds a stream that
    /// is DOWN and a lock leaves the stream LIVE (MEASURED 2026-08-21, attended
    /// lock/unlock run: "The stream SURVIVED the lock — zero re-arm needed").
    /// Without the latch a lock-then-hot-plug would keep a stream whose
    /// `config.width/height` describe the display that is gone for the rest of
    /// the process's life. Cleared by `beginRearm`, because any fresh chain
    /// reads the current geometry by itself.
    private var displayChangePending = false
    private var reasonList: String {
        suspendReasons.map(\.rawValue).sorted().joined(separator: ",")
    }
    /// Latched by `shutdown`, so our own teardown never looks like a failure.
    private var stopping = false
    /// Main-queue read: true once shutdown() has latched the stream closed,
    /// so the launch display-wait loop can stop polling on a graceful exit.
    var isStopping: Bool { stopping }
    /// SCShareableContent had no display to capture at start() time. Transient
    /// (a display can appear), so the launch path retries instead of dying.
    struct NoDisplayAvailable: Error {}
    /// Harness hook: throw NoDisplayAvailable from the first N start()
    /// attempts, then behave normally — exercises the launch display-wait
    /// poll (Pipeline.displayWaitPollSecs) without needing every display
    /// physically off. Never set in production; --process never calls start().
    private static var fakeNoDisplayLeft =
        Int(DevEnv.knob("SENTRY_FAKE_NO_DISPLAY") ?? "") ?? 0
    /// Streams whose `didStopWithError` arrived while they were NOT yet
    /// `self.stream` — a stop can outrun `start()` returning (startCapture
    /// documents no ordering guarantee). Without this, `noteStarted` would
    /// mark a dead stream `live` and nothing would ever re-arm it: the stop
    /// was already dropped, and it is the only re-arm trigger. Bounded: at
    /// most one entry per start attempt, cleared on every `noteStarted`.
    private var earlyStops: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []
    /// Lock/unlock observers live on DistributedNotificationCenter, not
    /// NSWorkspace's center — kept separately so `shutdown` removes each
    /// token from the center that issued it.
    private var distObservers: [NSObjectProtocol] = []
    /// Last window set handed to `refreshExclusion`. A rebuilt SCStream carries
    /// a fresh content filter, so the self-feedback guard (SPEC §5.5) has to be
    /// re-applied after a re-arm or the new stream can strobe against our own
    /// overlays.
    private var excluded: [Int] = []
    /// Harness-only extra exclusion:
    /// foreign windows the detector must see THROUGH — the privacy
    /// shield the harness holds over test content on a test Mac. Merged into
    /// every `refreshExclusion` so a re-armed stream keeps them out too. Set
    /// before `start`. An id SCShareableContent cannot find is FATAL: a
    /// missing shield would mean capturing whatever is under it, and a
    /// silently-ignored id is exactly the failure the harness must not have.
    var extraExcluded: [Int] = []
    /// TUNING TOOL (Detection view, DetectionViewController.swift): the
    /// exclusion handshake. Called on main after a content filter the
    /// NEWEST `refreshExclusion` applied to the CURRENT stream (`applied:
    /// true`, `ids` = the window ids that filter excludes; rechecked after
    /// the apply's await), and after the newest refresh's final failure
    /// (`applied: false`, `ids: []`). ASSUMED: SCStream applies
    /// `updateContentFilter` calls in call order, so a stale request that
    /// was already applying when a newer one began is overwritten by it. A
    /// refresh that finds no stream (capture stopped, or mid-rebuild) reports
    /// nothing: the rebuild's own re-arm refresh answers, and a stopped
    /// capture means a pause, which turns the view off. Until an answer the
    /// view stays hidden ("waiting for capture…") and its TTL still runs.
    /// The Detection view draws nothing until
    /// the latest result names its own window: the detector must never see
    /// the view's labels.
    var onExclusionResult: ((ExclusionResult) -> Void)?
    /// One `refreshExclusion` outcome. `request` is that refresh's number
    /// (`newestExclusionRequest` when it was made), so a listener can ignore
    /// answers to requests older than something it knows about — a stream
    /// rebuild, or its own newer request.
    struct ExclusionResult: Equatable {
        let applied: Bool
        let ids: Set<Int>
        let request: Int
    }
    /// The number the most recent `refreshExclusion` was given (0: none yet).
    var newestExclusionRequest: Int { exclusionRequests.newest }
    /// Orders refreshes. The window set changes when the Detection view turns
    /// on or off, and each refresh is its own Task: without this an older
    /// Task landing late would apply the OLD set over the newer one (the
    /// view's window unexcluded, or a dead id re-applied). A refresh that is
    /// no longer the newest stands down before it applies anything; the
    /// newest one reports. Production never changes the set (one cover
    /// window, created once), so it has no counter.
    private let exclusionRequests = ExclusionRequestOrder()
    /// The window set the next re-arm re-applies (read by the Detection
    /// view's self-test: a turned-off view must leave no dead id here).
    var excludedWindowNumbers: [Int] { excluded }
    /// Capture's own retry budget (`rearmAttempts`), which the Detection
    /// view reuses as its bound on unconfirmed exclusion results.
    static var exclusionAttemptBudget: Int { rearmAttempts }

    private func reportExclusion(_ result: ExclusionResult) {
        DispatchQueue.main.async { [weak self] in self?.onExclusionResult?(result) }
    }

    init(onFrame: @escaping (Frame) -> Void) {
        self.onFrame = onFrame
    }

    /// `requestedDisplayID` nil reproduces prior behavior byte for byte:
    /// `content.displays.first`, with the same "more than one display"
    /// warning. Given, that display is used INSTEAD, refusing loudly (with
    /// the full list SCShareableContent actually offers) if it is not there —
    /// never a silent fall-back to display 1.
    func start(fps: Int, width: Int, requestedDisplayID: CGDirectDisplayID? = nil) async throws {
        if Self.fakeNoDisplayLeft > 0 {
            Self.fakeNoDisplayLeft -= 1
            throw NoDisplayAvailable()
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let display: SCDisplay
        if let requestedDisplayID {
            guard let match = content.displays.first(where: { $0.displayID == requestedDisplayID })
            else {
                let list = content.displays.map { d in
                    "  \(d.displayID): \(d.width)x\(d.height)"
                }.joined(separator: "\n")
                throw SentryError(
                    "--display \(requestedDisplayID) is not in SCShareableContent's display "
                    + "list. Available:\n\(list)")
            }
            display = match
        } else {
            guard let first = content.displays.first else {
                // Transient, not fatal: SCShareableContent vends no display
                // right now (headless boot, all displays asleep, a remote
                // session not yet connected). The launch path polls and
                // re-attempts rather than exiting — see Pipeline.start's
                // display-wait loop (displayWaitPollSecs).
                throw NoDisplayAvailable()
            }
            display = first
        }
        self.display = display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = Double(width) / Double(display.width)
        config.width = width
        config.height = Int((Double(display.height) * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // No cursor in the capture. The detector never needs it, and with it
        // on every pointer move is a fresh `.complete` frame at up to `fps`
        // on an otherwise static desktop — each one a full inference.
        // MEASURED (live soak 2026-08-23..25, run.jsonl summaries): the
        // agent ran at 28 fps for whole minutes of ordinary desktop use with
        // no video on screen; cursor-driven frames are the only source of
        // that rate on a static screen. Overlay rects are window/region
        // geometry, not cursor-relative, so nothing downstream changes.
        config.showsCursor = false
        // ASSUMED (2026-08-21, receipt added): 3 buffers ≈ 11 MB at
        // 1280-wide BGRA — one being written by SCK, one in flight to the
        // busy-gate, one slack so a frame held across the detectQueue handoff
        // never stalls delivery. 2 risks SCK dropping internally (invisible
        // to our drop counter); more only adds memory, since the busy-gate
        // drops rather than queues. Remeasure if SCK late/dropped-frame
        // status codes ever appear.
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        generationGate.accept(stream)
        self.stream = stream
        noteStarted(fps: fps, width: width, displayID: requestedDisplayID,
                    started: ObjectIdentifier(stream))
        // 2026-09-11: this used to be a stderr WARNING inside the
        // display pick and NOTHING else, so `agent.err` was the only reader —
        // the popover said "Protected" and "Watching this Mac" on a Mac with an
        // uncovered second screen. Now the scope reaches the log as a named
        // record and the parent UI as state. After the stream is actually up, so
        // a start that throws never publishes a scope; and on EVERY start,
        // re-arms included, because a display can be plugged in while the agent
        // runs and the value is idempotent.
        publishDisplayScope(displayCount: content.displays.count, display: display)
    }

    /// Resolve and publish the display scope. `NSScreen` is consulted
    /// for one thing only — the display's name, and only for the popover row —
    /// by matching `NSScreenNumber` against the `SCDisplay` we actually
    /// captured, never by position in a list: SCK's display order and AppKit's
    /// `NSScreen.screens` order are not documented to agree, which is exactly
    /// the suspected mismatch the audit asked to close.
    private func publishDisplayScope(displayCount: Int, display: SCDisplay) {
        let displayID = display.displayID
        DispatchQueue.main.async { [weak self] in
            let screen = Self.screen(for: displayID)
            self?.onDisplayScope?(DisplayScope(
                displayCount: displayCount,
                protectedDisplayID: displayID,
                protectedName: screen?.localizedName ?? "Display \(displayID)"))
        }
    }

    /// The `NSScreen` backing a `CGDirectDisplayID`, or nil. Same key
    /// `resolveDisplayTarget` (main.swift) uses for `--display`.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } == displayID
        }
    }

    /// Hop back to the main queue with what `start` just established.
    /// Deliberately a separate synchronous method: forming the hop closure
    /// inside `start`'s async body captures non-Sendable self across an
    /// isolation boundary. Re-entered by every re-arm attempt, so idempotent.
    private func noteStarted(
        fps: Int, width: Int, displayID: CGDirectDisplayID?, started: ObjectIdentifier
    ) {
        DispatchQueue.main.async {
            self.startArgs = (fps, width, displayID)
            self.installObservers()
            self.live = true
            // The stop that outran us (see `earlyStops`): take the normal
            // down path now instead of vouching for a dead stream.
            let stoppedEarly = self.earlyStops.contains(started)
            self.earlyStops.removeAll()
            if stoppedEarly {
                self.streamDown("stopped during startup (stop preceded start completion)")
            }
        }
    }

    func stop() async {
        shutdown()
        try? await stream?.stopCapture()
        stream = nil
    }

    /// Synchronous teardown of everything the lifecycle machinery holds.
    /// `Pipeline.shutdown()` does not await `stop()`, so the observers have to
    /// be droppable on their own; latching `stopping` also means the stop our
    /// own exit produces cannot start a re-arm.
    func shutdown() {
        stopping = true
        generationGate.invalidate()
        rearmGeneration &+= 1
        rearmAttempt = nil
        rearmWanted = false
        // Nothing registered means no stream was ever started — `--process`
        // constructs a CaptureStream but never starts one, and must not touch
        // NSWorkspace at all.
        guard !observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        let dist = DistributedNotificationCenter.default()
        for observer in distObservers { dist.removeObserver(observer) }
        distObservers.removeAll()
    }

    /// Main queue. Idempotent: `start` runs again on every re-arm attempt.
    private func installObservers() {
        guard observers.isEmpty, !stopping else { return }
        seedSuspendState()
        let center = NSWorkspace.shared.notificationCenter
        // screensDidSleep/Wake fire for display sleep without a system sleep;
        // willSleep/didWake for the system. Either one is enough to mark the
        // window in which a stream stop is expected, so they share one reason.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.suspendBegan(.sleep, source: name.rawValue)
                })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.resumeBegan(.sleep, source: name.rawValue)
                })
        }
        // Our login session left the console: fast user switching, OR a
        // remote-desktop / Screen Sharing session taking it over. The launch
        // seed's test decides (`applyOffConsole`): park only when no display
        // is live. Owner decision 2026-09-25 (option B).
        // MEASURED 2026-09-23 on an M1 Mac: `screenIsUnlocked` was
        // followed by this notification, capture parked and stayed parked
        // until a restart, and the relaunched agent's seed protected the
        // session (1 live display). DERIVED: the unlock came over Screen
        // Sharing and that session could capture for the ~36 min it was
        // parked (not checked whether the owner stayed connected).
        // ASSUMED, not measured: a fast-user-switched-out session reports no
        // live display here and still parks. If it reports one, it stays
        // active on its own idle stream, which is harmless: overlays are
        // per-session.
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.stopping else { return }
            self.offConsole = true
            self.applyOffConsole(source: "sessionDidResignActive", announce: true)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.offConsole = false
            self?.resumeBegan(.sessionInactive, source: "sessionDidBecomeActive")
        })
        // Screen lock/unlock: AppKit has no public equivalent; these
        // distributed notifications are the de-facto interface (stable since
        // 10.x, used by every lock-state observer in the wild). ASSUMED until
        // the attended lock/unlock live run: delivery is symmetric. A missed
        // unlock is the bad failure — capture parked on an active desktop
        // with NO further record (the log just ends on `state=suspended`);
        // the loud transition records make that state readable after the
        // fact, they do not detect it live. The attended run is what
        // confirms delivery on this macOS version.
        // The stream is deliberately NOT torn down on lock: if it survives
        // the lock there must be zero detection gap at the instant the
        // desktop reappears on unlock.
        //
        // The lock notification is a HINT, never the truth (security review
        // 2026-09-28, T1). It is not authenticated: MEASURED 2026-09-28 on
        // a test Mac (macOS 27.0 26A428, Build 20), a process with no
        // special rights produced it and the installed agent logged
        // `state=suspended source=screenIsLocked` and stopped detecting until
        // the matching unlock. So a lock signal now suspends only once the
        // session itself says it is locked (`lockSignalReceived`), and a
        // signal the session never confirms is a named tamper event.
        let dist = DistributedNotificationCenter.default()
        distObservers.append(dist.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.lockSignalReceived()
        })
        distObservers.append(dist.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // A pending confirmation belongs to a lock that has already ended.
            self.lockConfirmGeneration &+= 1
            self.resumeBegan(.screenLocked, source: "screenIsUnlocked")
        })
    }

    // MARK: - Lock-signal confirmation (T1)

    /// How long a lock signal may wait for the session to report the lock
    /// before it is judged unconfirmed. ASSUMED, not measured: loginwindow
    /// sets the session's lock state before (or within moments of) posting
    /// the notification. The grace makes the decision independent of that
    /// order up to 2 s, and every confirmed lock logs its own
    /// `lock-confirm … afterMs=` so the first attended lock on each macOS
    /// version is the receipt (owed: no lock can be driven headless on the
    /// test Mac, where unlocking needs the console password). A real lock missed
    /// by this grace costs little: MEASURED 2026-08-21 (attended lock run),
    /// the stream survives a lock, so capture just keeps running on the lock
    /// screen, and the recheck below never suspends on its own.
    static let lockConfirmGraceSecs: TimeInterval = 2
    /// Poll step inside the grace. DERIVED: grace / 8 steps. One
    /// `CGSessionCopyCurrentDictionary` read per step (a small dictionary
    /// copy), at most 8 per lock signal; a confirmed lock suspends within
    /// 250 ms of the session reporting it, and `afterMs=` resolves the
    /// confirm time to that step, enough to place it against the 2 s grace.
    static let lockConfirmPollSecs: TimeInterval = 0.25
    /// While suspended for a lock, how often the session's own lock state is
    /// re-read. A missed `screenIsUnlocked` used to leave capture parked on an
    /// active desktop with no further record (see the observer comment); now
    /// it resumes within this interval. DERIVED: one dictionary read per 5 s
    /// only while locked is negligible, and 5 s is inside the 5 s re-arm poll
    /// the capture-loss path already accepts.
    static let lockRecheckSecs: TimeInterval = 5

    enum LockSignalDecision: Equatable {
        /// The session is locked: suspend, as before.
        case suspend
        /// Not locked yet, still inside the grace: poll again.
        case recheck
        /// The session is not locked and the grace has run out: refuse the
        /// suspension and record the tamper event.
        case refuseUnconfirmed
        /// The session dictionary is unavailable, so nothing can be
        /// confirmed or refuted: keep protecting, log it, record no tamper.
        case refuseUnknown
    }

    /// Pure so `--ui-selftest` can assert the table without a WindowServer.
    static func lockSignalDecision(sessionLocked: Bool?, elapsed: TimeInterval) -> LockSignalDecision {
        if sessionLocked == true { return .suspend }
        if elapsed < lockConfirmGraceSecs { return .recheck }
        return sessionLocked == nil ? .refuseUnknown : .refuseUnconfirmed
    }

    /// The session's own lock state, the same source `seedSuspendState`
    /// reads at launch. nil when the session dictionary is unavailable.
    static func sessionScreenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Bumped by every lock signal and every unlock signal, so a confirmation
    /// or recheck chain started for an earlier signal stands down.
    private var lockConfirmGeneration = 0

    /// Main queue.
    private func lockSignalReceived() {
        guard !stopping else { return }
        lockConfirmGeneration &+= 1
        let generation = lockConfirmGeneration
        let started = CFAbsoluteTimeGetCurrent()
        func step() {
            guard !stopping, generation == lockConfirmGeneration else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            let ms = Int(elapsed * 1000)
            switch Self.lockSignalDecision(sessionLocked: Self.sessionScreenLocked(), elapsed: elapsed) {
            case .suspend:
                report("lock-confirm source=screenIsLocked afterMs=\(ms)")
                suspendBegan(.screenLocked, source: "screenIsLocked")
                scheduleLockRecheck(generation: generation)
            case .recheck:
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockConfirmPollSecs) { step() }
            case .refuseUnconfirmed:
                report("state=active source=screenIsLocked REFUSED: the session is not locked "
                    + "\(ms) ms after the signal (grace lockConfirmGraceSecs="
                    + "\(Self.lockConfirmGraceSecs) s) — protection keeps running")
            case .refuseUnknown:
                report("state=active source=screenIsLocked REFUSED: the session dictionary is "
                    + "unavailable, so the lock cannot be confirmed — protection keeps running")
            }
        }
        step()
    }

    /// Main queue. While suspended for a lock, re-read the session's lock
    /// state; resume if it says unlocked (a missed or late unlock signal).
    private func scheduleLockRecheck(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockRecheckSecs) { [weak self] in
            guard let self, !self.stopping, generation == self.lockConfirmGeneration,
                self.suspendReasons.contains(.screenLocked)
            else { return }
            if Self.sessionScreenLocked() == false {
                self.lockConfirmGeneration &+= 1
                self.resumeBegan(.screenLocked, source: "lock-recheck (session reports unlocked; no unlock signal arrived)")
            } else {
                self.scheduleLockRecheck(generation: generation)
            }
        }
    }

    /// Main queue. Loud lifecycle record: stderr plus an `"event":"capture"`
    /// record. Reachable only from a started stream's lifecycle.
    private func report(_ info: String) {
        FileHandle.standardError.write(Data("capture: \(info)\n".utf8))
        onState?(info)
    }

    /// Emit the suspended⇄active edge exactly once per real transition.
    /// Called wherever `suspendReasons` changes.
    private func noteSuspendEdge() {
        guard suspended != lastSuspendedReported else { return }
        lastSuspendedReported = suspended
        onSuspendedChange?(suspended)
    }

    private func suspendBegan(_ reason: SuspendReason, source: String) {
        guard !stopping else { return }
        defer { noteSuspendEdge() }
        // A chain already in flight would spend its whole budget against a
        // WindowServer that is on its way down (sleep) or a session that
        // cannot vend capture (lock, console switch). Park it; the resume
        // that clears the last reason starts a fresh one.
        let parked = rearmAttempt != nil
        if parked {
            rearmGeneration &+= 1
            rearmAttempt = nil
            rearmWanted = false
        }
        guard suspendReasons.insert(reason).inserted || parked else { return }
        report(
            "state=suspended source=\(source) reasons=\(reasonList)"
            + (parked ? " re-arm parked at attempt, budget reset for resume" : ""))
    }

    /// Main queue. Observers track no state until the first stream starts,
    /// so a lock/switch that predates launch would be invisible: without
    /// this, a stream stop in that window spends the full retry budget
    /// against a session that cannot vend capture (up to the fatal exit) and
    /// the eventual unlock is dropped as an unmatched resume. Matters for
    /// the Milestone 3 launch-at-login path, where the daemon can start
    /// behind the password screen. `CGSessionCopyCurrentDictionary` is
    /// public API; the ScreenIsLocked key is undocumented-but-stable, same
    /// ASSUMED status as the lock notifications it seeds.
    private func seedSuspendState() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            suspendReasons.insert(.screenLocked)
            lockConfirmGeneration &+= 1
            scheduleLockRecheck(generation: lockConfirmGeneration)
        }
        if suspended {
            report("state=suspended source=launch-seed reasons=\(reasonList)")
        }
        // Off-console: the shared test (`applyOffConsole`), which logs its own
        // decision. By the time this seed runs, `start()`'s `startCapture()`
        // has already SUCCEEDED (noteStarted → installObservers → here).
        offConsole = (session[kCGSessionOnConsoleKey as String] as? Bool) != true
        if offConsole {
            applyOffConsole(source: "launch-seed", announce: true)
        }
        noteSuspendEdge()
    }

    /// True while our session is off the console: seeded at launch from
    /// `kCGSessionOnConsoleKey`, set by `sessionDidResignActive`, cleared by
    /// `sessionDidBecomeActive`. While set, a display change re-runs the
    /// off-console test (`displaysChanged`).
    private var offConsole = false

    /// What an off-console session does with capture. Pure so `--ui-selftest`
    /// can assert the table without a WindowServer.
    enum OffConsoleDecision: Equatable {
        /// A display is live, so this session has one to capture (a
        /// remote-desktop virtual display, a Screen Sharing session): keep
        /// capturing.
        case protect
        /// No live display, nothing to vend (fast-user-switched out): park.
        case parkNoDisplay
        /// `SENTRY_ASSUME_CONSOLE=0`: the old always-park, for A/B measurement.
        case parkByOverride
    }

    static func offConsoleDecision(liveDisplays: UInt32, assumeConsole: String?)
        -> OffConsoleDecision
    {
        if assumeConsole == "0" { return .parkByOverride }
        return liveDisplays > 0 ? .protect : .parkNoDisplay
    }

    /// Main queue. The ONE off-console test, shared by the launch seed, the
    /// session-resign observer and the display-change re-evaluation.
    ///
    /// `kCGSSessionOnConsoleKey == false` is NOT the same as "cannot
    /// capture": a remote-desktop session (Jump Desktop virtual display) is
    /// off-console yet owns and vends its own display. MEASURED 2026-08-25:
    /// the production agent, relaunched by the daily TTL cycle while the
    /// owner was connected over Jump, seeded session-inactive and sat at 0
    /// frames for the whole session; every window the owner opened through
    /// the remote display was UNCOVERED. DERIVED 2026-09-23:
    /// the resign path had the same fault after a Screen Sharing unlock.
    /// So: off-console with a live display → stay active and say so loudly;
    /// off-console with no live display → park. A locked session is the
    /// separate `.screenLocked` reason and still suspends.
    ///
    /// `announce` logs a protect decision that changes nothing. The
    /// display-change caller passes false, because `didChangeScreenParameters`
    /// also fires for menu-bar and Dock changes; it logs only a real
    /// park⇄protect edge. `SENTRY_ASSUME_CONSOLE=0` restores the old
    /// always-park on every path; default and =1 both protect.
    private func applyOffConsole(source: String, announce: Bool) {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        let decision = Self.offConsoleDecision(
            liveDisplays: n, assumeConsole: DevEnv.knob("SENTRY_ASSUME_CONSOLE"))
        switch decision {
        case .protect:
            if suspendReasons.contains(.sessionInactive) {
                resumeBegan(.sessionInactive, source: "\(source) off-console session has "
                    + "\(n) live display(s) — protecting")
            } else if announce {
                // Another reason (lock, sleep) can still hold capture: the
                // record must not say "active" while it is suspended.
                let state = suspended
                    ? "state=suspended source=\(source) off-console session with \(n) live "
                        + "display(s) — off-console protect decided, still suspended "
                        + "reasons=\(reasonList)"
                    : "state=active source=\(source) off-console session with \(n) live "
                        + "display(s) — remote-desktop session, protecting"
                report(state + " (SENTRY_ASSUME_CONSOLE=0 parks instead)")
            }
        case .parkNoDisplay, .parkByOverride:
            let why = decision == .parkByOverride
                ? "SENTRY_ASSUME_CONSOLE=0" : "no live display to vend"
            suspendBegan(.sessionInactive, source: "\(source) off-console, \(why)")
        }
    }

    /// Main queue. A display change while off console re-runs the off-console
    /// test: a display that appears after a park resumes capture, and the
    /// last display going away parks it instead of spending retry budget
    /// against a session with nothing to vend. Call BEFORE
    /// `rebuildForDisplayChange`, so the rebuild sees the new suspend state.
    ///
    /// Returns true when this call resumed capture. The resume already
    /// rebuilt for a changed geometry (the latch below makes `resumeAction`
    /// re-arm even a surviving stream), so the caller must skip
    /// `rebuildForDisplayChange`: calling it would find the chain in flight,
    /// latch again, and rebuild a second time (~1 s more blind).
    func displaysChanged(geometryChanged: Bool) -> Bool {
        guard offConsole, !stopping, startArgs != nil else { return false }
        let wasSuspended = suspended
        // Same latch `rebuildForDisplayChange` sets while suspended.
        if geometryChanged, wasSuspended { displayChangePending = true }
        applyOffConsole(source: "didChangeScreenParameters", announce: false)
        return wasSuspended && !suspended
    }

    private func resumeBegan(_ reason: SuspendReason, source: String) {
        // An unmatched resume is dropped SILENTLY on purpose: it is routine,
        // not exceptional — didWake and screensDidWake both fire on every
        // wake, and whichever lands second finds `.sleep` already cleared.
        // The launched-while-locked case that would make an unmatched unlock
        // meaningful is closed by `seedSuspendState`, not by logging here.
        guard !stopping, suspendReasons.remove(reason) != nil else { return }
        defer { noteSuspendEdge() }
        guard suspendReasons.isEmpty else {
            // The common wake path: didWake clears .sleep while the console
            // is still on the password screen. Stay parked until the last
            // reason clears; re-arming here would burn budget for nothing.
            report("state=suspended source=\(source) still suspended, reasons=\(reasonList)")
            return
        }
        switch Self.resumeAction(live: live, displayChangePending: displayChangePending) {
        case .keepLiveStream:
            // Tearing down a stream that survived the suspension would open a
            // real gap in detection for no reason.
            report("state=resumed source=\(source) stream still live")
        case .rearm:
            if live {
                // the surviving stream is precisely the WRONG stream —
                // its config.width/height describe the display that changed
                // while we were parked. The stream we are about to replace must
                // not also take the `streamDown` path when its own stop lands.
                report("state=resumed source=\(source) re-arming for the display change "
                    + "deferred at suspend — the surviving stream is configured for the "
                    + "previous display")
                live = false
            } else {
                report("state=resumed source=\(source) re-arming")
            }
            beginRearm()
        }
    }

    /// What the resume that clears the LAST suspend reason must do with the
    /// stream. Pure so `--ui-selftest` can assert the table without a
    /// WindowServer, like `displayChangeAction` below.
    enum ResumeAction: Equatable {
        /// Build a fresh stream: it is down, or it is live but was left
        /// describing a display that changed while we were suspended.
        case rearm
        /// It survived the suspension and still describes the live display.
        case keepLiveStream
    }

    static func resumeAction(live: Bool, displayChangePending: Bool) -> ResumeAction {
        (!live || displayChangePending) ? .rearm : .keepLiveStream
    }

    /// What a display-topology change means for a stream in a given state.
    /// Pure so `--ui-selftest` can assert the table without a WindowServer.
    enum DisplayChangeAction: Equatable {
        /// Tear the stream down and build a replacement.
        case rebuild
        /// Suspended (asleep, locked, off console): spending retry budget here
        /// would burn it against a session that cannot vend capture. The
        /// rebuild is LATCHED (`displayChangePending`) and performed by the
        /// resume that clears the last reason — including when the stream
        /// survived the suspension, which a lock does.
        case deferToResume
        /// A re-arm chain is already in flight; its next `start()` reads the
        /// new geometry by itself.
        case alreadyRebuilding
        /// No stream was ever started (`--process`), or we are shutting down.
        case ignore
    }

    static func displayChangeAction(
        started: Bool, stopping: Bool, suspended: Bool, live: Bool
    ) -> DisplayChangeAction {
        guard started, !stopping else { return .ignore }
        if suspended { return .deferToResume }
        return live ? .rebuild : .alreadyRebuilding
    }

    /// Main queue. The display this stream captures changed shape.
    ///
    /// `start()` derives `config.width/height` from the display's own size
    /// (`scale = width / display.width`), so after a resolution change, a
    /// hot-plug or a main-display reassignment the live stream is delivering
    /// buffers for a display that no longer exists. Rebuilt on the SAME retry
    /// budget, the SAME generation gate and the SAME
    /// `onStreamGenerationInvalidated` hook an unexpected stop uses — nothing
    /// new, so nothing new to get wrong.
    func rebuildForDisplayChange(_ reason: String) {
        switch Self.displayChangeAction(
            started: startArgs != nil, stopping: stopping, suspended: suspended, live: live)
        {
        case .ignore:
            return
        case .deferToResume:
            displayChangePending = true
            // No retry budget is spent, but the frames a SURVIVING stream keeps
            // delivering describe the OLD display while the pipeline has already
            // swapped to the new geometry. Invalidating the gate here (the same
            // two calls `beginRearm` makes) drops them at `token(for:)` instead
            // of normalizing them against a display they were not captured from.
            generationGate.invalidate()
            onStreamGenerationInvalidated?()
            report("state=suspended \(reason) — stream rebuild LATCHED for the resume "
                + "(\(reasonList)), no retry budget spent; frames from the current stream "
                + "are dropped until it is rebuilt")
        case .alreadyRebuilding:
            // Latched as well: the attempt in flight is inside `await start()`
            // and may already have resolved the OLD display, in which case
            // `finishRearm`'s success path spends one more rebuild.
            displayChangePending = true
            report("state=down \(reason) — a re-arm chain is already in flight; it builds "
                + "against the new geometry, or is rebuilt once when it lands")
        case .rebuild:
            report("state=rebuilding \(reason)")
            // The stream we are about to replace must not also take the
            // `streamDown` path when its own stop lands.
            live = false
            beginRearm()
        }
    }

    /// Main queue. An unexpected stop of the CURRENT stream.
    private func streamDown(_ reason: String) {
        guard live else { return }
        live = false
        guard !suspended else {
            report("state=suspended \(reason) — deferred to resume (\(reasonList)), "
                + "no retry budget spent")
            return
        }
        report("state=down \(reason)")
        beginRearm()
    }

    /// Main queue. Starts a retry chain with a full budget, superseding any
    /// chain still in flight.
    private func beginRearm() {
        generationGate.invalidate()
        onStreamGenerationInvalidated?()
        rearmGeneration &+= 1
        guard !rearmInFlight else {
            // Defer rather than spawn a second Task: see `rearmInFlight`.
            rearmWanted = true
            return
        }
        rearmWanted = false
        startChain()
    }

    /// Main queue. Runs the restart a transition asked for while a Task held
    /// the slot — unless that Task's attempt happened to succeed, in which case
    /// the stream is live and there is nothing to rebuild.
    private func resumeDeferredRearm() {
        guard rearmWanted, !stopping else { return }
        rearmWanted = false
        guard !live, !suspended else {
            rearmAttempt = nil
            return
        }
        startChain()
    }

    /// Main queue. First attempt of a fresh chain, shared by both entry
    /// points above.
    private func startChain() {
        rearmAttempt = 1
        attemptRearm(1, generation: rearmGeneration)
    }

    private func attemptRearm(_ attempt: Int, generation: Int) {
        // Unreachable: `live` is set in the same main-queue block as
        // `startArgs`, and only a live stream can go down.
        guard let args = startArgs else { return }
        // A `start()` that BEGINS now reads the CURRENT geometry, so it
        // satisfies a latched display change whatever armed it.
        // Cleared here rather than in `beginRearm` so that an attempt which
        // began BEFORE the change — the `.alreadyRebuilding` window — still
        // finds the latch set when it lands, and is rebuilt once.
        displayChangePending = false
        rearmInFlight = true
        Task {
            try? await self.stream?.stopCapture()
            self.stream = nil
            do {
                try await self.start(
                    fps: args.fps, width: args.width, requestedDisplayID: args.displayID)
                self.finishRearm(attempt, generation: generation, error: nil)
            } catch {
                self.finishRearm(attempt, generation: generation, error: error)
            }
        }
    }

    /// Main-queue landing for one attempt's outcome. Synchronous for the same
    /// reason `noteStarted` is.
    private func finishRearm(_ attempt: Int, generation: Int, error: Error?) {
        DispatchQueue.main.async {
            self.rearmInFlight = false
            guard let error else {
                // A success counts even if a sleep/wake transition superseded
                // this chain: `stream` and `live` already belong to the stream
                // it just built, so saying nothing here would leave the log
                // claiming a capture that is actually up is still down.
                self.rearmWanted = false
                self.rearmAttempt = nil
                self.report("state=restored after \(attempt) attempt(s)")
                // The rebuilt stream carries a fresh content filter.
                if !self.excluded.isEmpty { self.refreshExclusion(windowNumbers: self.excluded) }
                // The `.alreadyRebuilding` window: this attempt resolved
                // its display INSIDE `await start()`, which may have been before
                // the change landed. A latch still set here says no chain has
                // started since, so the stream now live can still be describing
                // the old display. One more rebuild — bounded, because
                // `beginRearm` clears the latch before spending anything.
                if self.displayChangePending, !self.suspended, !self.stopping {
                    self.report("state=rebuilding the restored stream may predate the display "
                        + "change (started inside the re-arm already in flight)")
                    self.live = false
                    self.beginRearm()
                }
                return
            }
            guard generation == self.rearmGeneration else {
                // Superseded chain's failure: the transition that superseded it
                // decides what happens next.
                self.resumeDeferredRearm()
                return
            }
            self.rearmFailed(attempt, error, generation: generation)
        }
    }

    private func rearmFailed(_ attempt: Int, _ error: Error, generation: Int) {
        guard !suspended else {
            rearmAttempt = nil
            report("state=suspended re-arm attempt \(attempt) failed while suspended "
                + "(\(reasonList)) — parked")
            return
        }
        guard attempt < Self.rearmAttempts else {
            let detail = "budget captureRearm limit \(Self.rearmAttempts) attempts, observed "
                + "\(attempt) failures \(Self.rearmDelay)s apart while awake, unlocked, and "
                + "not parked off console; last error: \(error)"
            // `--capture-loss banner` (C1): the process stays up, shows the
            // parent-needed banner and polls for the permission coming back —
            // exiting here under launchd KeepAlive would be a relaunch loop,
            // and exiting without KeepAlive leaves the machine silently
            // unfiltered. Default dev behavior (no handler) stays exit(2).
            if let onCaptureLost {
                report("state=lost \(detail) (fix: re-grant Screen Recording in "
                    + "System Settings — banner is up, preflight is polled)")
                onCaptureLost()
                return
            }
            report("state=fatal \(detail) "
                + "(fix: CaptureStream.rearmAttempts, or restart the daemon)")
            exit(2)
        }
        rearmAttempt = attempt + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rearmDelay) { [self] in
            guard generation == rearmGeneration else { return }
            attemptRearm(attempt + 1, generation: generation)
        }
    }

    /// Self-feedback guard (SPEC §5.5): exclude our own overlay windows from
    /// capture so an overlay cannot hide content from the detector and
    /// oscillate. Called once when the persistent overlay window is created;
    /// retries because a transient SCShareableContent/updateContentFilter
    /// failure would otherwise permanently disable the anti-strobe guard.
    func refreshExclusion(windowNumbers: [Int]) {
        excluded = windowNumbers
        let wanted = windowNumbers + extraExcluded
        let request = exclusionRequests.next()
        // Turning the Detection view off before any cover window exists
        // leaves nothing to exclude: apply the empty filter rather than
        // retry an empty set into a false "self-exclusion failed" warning.
        let emptySetApplies = wanted.isEmpty
        Task {
            // Same budget as the re-arm chain (Self.rearmAttempts/rearmDelay)
            // ON PURPOSE — one source of truth for "how long to ride out a
            // transient SCShareableContent refusal" (reuse review 2026-08-21).
            for attempt in 1...Self.rearmAttempts {
                guard exclusionRequests.isNewest(request) else { return }
                guard let display, let stream else { return }
                if let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                {
                    let mine = content.windows.filter {
                        wanted.contains(Int($0.windowID))
                    }
                    let found = Set(mine.map { Int($0.windowID) })
                    // ALL wanted ids must be present before the filter counts
                    // as applied. MEASURED 2026-08-28 (shielded harness r1): a
                    // freshly created overlay window is not yet in
                    // SCShareableContent's on-screen list at this instant; a
                    // "some found" success here excluded only the shield,
                    // left our own covers visible to the detector, and the
                    // region pipeline strobed (dets → cover → no dets → lift
                    // → dets, ~10 s period). Missing ids retry on the same
                    // budget; the extras fail loudly below if never found.
                    guard exclusionRequests.isNewest(request) else { return }
                    if found.isSuperset(of: wanted), !mine.isEmpty || emptySetApplies,
                        (try? await stream.updateContentFilter(
                            SCContentFilter(display: display, excludingWindows: mine))) != nil
                    {
                        // Recheck after the await: a newer request, or a
                        // stream rebuilt meanwhile, makes this filter stale
                        // news — the newer request (the re-arm's refresh,
                        // for a rebuild) reports for itself.
                        if exclusionRequests.isNewest(request), self.stream === stream {
                            reportExclusion(.init(applied: true, ids: found, request: request))
                        }
                        if !extraExcluded.isEmpty {
                            report("state=excluded windows=\(Array(found).sorted()) "
                                + "extra=\(extraExcluded)")
                        }
                        return
                    }
                }
                if attempt < Self.rearmAttempts {
                    try? await Task.sleep(for: .seconds(Self.rearmDelay))
                }
            }
            // A superseded refresh's failure is not the answer: the newer
            // request decides, and reports for itself.
            guard exclusionRequests.isNewest(request) else { return }
            reportExclusion(.init(applied: false, ids: [], request: request))
            if !extraExcluded.isEmpty {
                die(
                    "--exclude-windows: window id(s) \(extraExcluded) not excludable after "
                        + "\(Self.rearmAttempts) attempts (not in SCShareableContent's "
                        + "on-screen list, or updateContentFilter refused) — refusing to "
                        + "capture with an unexcluded shield (fix: the harness must keep "
                        + "the shield on screen for the daemon's lifetime)",
                    code: 2)
            }
            let warning = "WARNING: capture self-exclusion failed after "
                + "\(Self.rearmAttempts) attempts — "
                + "overlay strobe possible (fix: Capture.refreshExclusion)\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard let generation = generationGate.token(for: stream),
            type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: statusRaw) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        if dirtyAttachmentShape == nil {
            let raw = attachments.first?[.dirtyRects]
            let list = raw as? [Any]
            dirtyAttachmentShape = raw == nil ? "absent"
                : "\(Swift.type(of: raw!)) n=\(list?.count ?? -1)"
                + (list?.first.map { " first=\(Swift.type(of: $0))" } ?? "")
        }
        onFrame(Frame(
            pixelBuffer: pixelBuffer, capturedAt: Self.presentationTime(sampleBuffer),
            generation: generation,
            dirtyFraction: Self.dirtyFraction(
                attachments.first?[.dirtyRects],
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer))))
    }

    /// Changed-area fraction from SCK's `dirtyRects` attachment. The rects
    /// arrive in the stream's output pixel space (same as the buffer), as an
    /// NSArray of CGRect dictionary representations; both that and NSValue
    /// rects are accepted. Anything else — nil, empty, a shape we do not
    /// recognise — returns 1.0 (see Frame.dirtyFraction). Rects are summed,
    /// not unioned: overlap can only over-report change, which is the safe
    /// direction for a gate that skips work.
    static func dirtyFraction(_ raw: Any?, width: Int, height: Int) -> Double {
        guard width > 0, height > 0, let list = raw as? [Any], !list.isEmpty else { return 1 }
        var area = 0.0
        for item in list {
            if let dict = item as? NSDictionary,
               let r = CGRect(dictionaryRepresentation: dict) {
                area += Double(r.width * r.height)
            } else if let value = item as? NSValue {
                let r = value.rectValue
                area += Double(r.width * r.height)
            } else {
                return 1
            }
        }
        return min(1, area / Double(width * height))
    }

    /// When the frame's pixels were on glass, as a CFAbsoluteTime.
    ///
    /// This used to be `CFAbsoluteTimeGetCurrent()` at delivery, which is the
    /// wrong quantity in a measured way. Receipt:
    /// SCK's PTS is a DISPLAY PRESENT TIME in the mach_absolute_time
    /// domain — its phase on the CADisplayLink vsync grid is p50 0.44 ms
    /// (min 0.37, max 0.50, n=432) — and frames are DELIVERED 4-12 ms BEFORE
    /// their own PTS because the compositor runs a frame ahead. So the delivery
    /// stamp understated content age by the whole 0-33 ms sampling wait and
    /// misplaced the frame by a further ~4 ms.
    ///
    /// The extrapolator's horizon is measured from this stamp, so it has to be
    /// the moment those pixels existed, not the moment we got them.
    ///
    /// Consequence for logs: `totalMs` (now - capturedAt) is now honest pipeline
    /// age measured from presentation, and can read a few ms SMALLER — or
    /// negative on a frame delivered ahead of its PTS. Headless `--process`
    /// passes its own stamp and is unaffected; regioncheck.sh ignores totalMs.
    private static func presentationTime(_ sampleBuffer: CMSampleBuffer) -> CFAbsoluteTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return CFAbsoluteTimeGetCurrent() }
        // PTS and the host clock share the mach domain; CFAbsoluteTime does not,
        // so cross over with a delta rather than a raw conversion.
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        let age = CMTimeGetSeconds(CMTimeSubtract(host, pts))
        guard age.isFinite else { return CFAbsoluteTimeGetCurrent() }
        return CFAbsoluteTimeGetCurrent() - age
    }

    /// A stop is no longer fatal by itself. Display sleep produces one on a
    /// perfectly healthy machine, and killing the daemon there is worse than
    /// rebuilding the stream: the covers stay exactly as they are while capture
    /// is down (nothing clears them — `Overlay.sync`/`clearAll` are only ever
    /// reached from a frame or from panic/shutdown), so a frozen cover fails
    /// safe and a dead process does not.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard !stopping else { return }
            guard stream === self.stream else {
                // Either a late stop from a stream a re-arm already replaced
                // (not a failure), or a stop that outran `start()` assigning
                // `self.stream`. Remember the identity so `noteStarted` can
                // tell the two apart; it clears this set on every start.
                earlyStops.insert(ObjectIdentifier(stream))
                return
            }
            self.stream = nil
            streamDown("error=\(error.localizedDescription)")
        }
    }
}

struct SentryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// TUNING TOOL (see `CaptureStream.onExclusionResult`): which
/// `refreshExclusion` request is the newest. `next` runs on main, `isNewest`
/// inside a refresh Task on any thread, so the counter is locked.
final class ExclusionRequestOrder {
    private let lock = NSLock()
    private var counter = 0

    var newest: Int {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }

    func isNewest(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request == counter
    }
}
