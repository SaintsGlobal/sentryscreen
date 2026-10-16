import CoreGraphics
import Foundation

// The honest answer to "is this Mac protected?" (2026-09-11).
// Before this file the green shield was a function of ONE
// input — `CaptureHealth` — so a healthy capture stream reported "Protected"
// while the detector was dead (frames arriving, nothing examined) and while a
// second display sat completely uncovered.
//
// Three inputs, one verdict, one place to read it:
//   capture health  — are frames arriving at all (CaptureHealth, spec §8)
//   detector health — is the model answering (DetectorWatch, below)
//   display scope   — how many of this Mac's screens are covered (DisplayScope)
//
// Nothing here touches the curtain or region pipelines: this is a status
// boundary. `Pipeline` feeds it, `UIState` publishes it, the popover, the
// menu-bar glyph and the status toast read it.

/// Is the detector answering? `failing` is entered after
/// `DetectorWatch.failingStreak` consecutive throwing frames and left on the
/// first frame that succeeds.
///
/// Deliberately carries no error COUNT: the count changes on every frame of a
/// failure, and this value is `@Published` — a count here would re-evaluate
/// the whole popover body at the capture rate for a number no surface shows.
/// The count lives in the `detectorErrors` summary counter, uncapped.
enum DetectorHealth: Equatable {
    case healthy
    /// `since` is when the streak that crossed the threshold STARTED, not when
    /// it crossed — the parent's "how long has this been broken" clock.
    case failing(since: Date)
}

/// Consecutive-detector-error state machine. A value type with no clock and no
/// logger of its own, so `--ui-selftest` can drive failure AND recovery
/// through it directly (the audit's standing complaint was that no test
/// exercised detector failure at all).
struct DetectorWatch {
    /// Consecutive failing detector frames before the parent surfaces stop
    /// saying "Protected".
    ///
    /// Receipt — MEASURED 2026-09-11 on an M1 Mac's installed agent
    /// (`/Library/Logs/SentryScreen/501/run.jsonl` plus its 3 rolled
    /// generations, 2026-09-08..11): 2,521 summary windows, 622,026 inference
    /// frames, `detectorErrors` = 0 in every window and zero
    /// `"event":"detector-error"` records. The healthy rate is ZERO, so any
    /// streak at all is abnormal and no margin has to be bought from a
    /// measured noise floor.
    ///
    /// 3, not 1: a single throw can be one frame's Vision request losing a
    /// race with a stream reconfigure, and one such frame must not turn a
    /// family's shield red. 3, not 10: at `PerfTier.fpsFloor` (10 fps, the
    /// slowest shipped tier) three frames is 0.3 s, and at 30 fps 0.1 s — the
    /// shield goes red inside a second on every shipped configuration. If a
    /// healthy run ever reaches this, re-measure the counter above and
    /// re-receipt rather than raising the number.
    static let failingStreak = 3

    /// Development fault injection, `SENTRY_FAKE_DETECTOR_ERRORS=<n>`: the
    /// first n `detector.detect` calls of the run throw instead of running the
    /// model, so the hold, the degraded surfaces and the recovery can be
    /// driven end to end through `--process` with no broken model and no live
    /// capture. Production binaries carry
    /// no reader.
    /// `<count>` throws from the first call, `<skip>:<count>` lets `skip` calls
    /// through first — so a replay can fail the detector AFTER covers are up,
    /// which is the case the hold exists for.
    static var injectedFault: (skipLeft: Int, errorsLeft: Int) = {
        let raw = ProcessInfo.processInfo.environment["SENTRY_FAKE_DETECTOR_ERRORS"] ?? ""
        let parts = raw.split(separator: ":").map(String.init)
        if parts.count == 2, let skip = Int(parts[0]), let n = Int(parts[1]) {
            return (max(0, skip), max(0, n))
        }
        return (0, Int(raw) ?? 0)
    }()

    /// Development hang injection, `SENTRY_FAKE_DETECTOR_HANG=<seconds>`: the
    /// FIRST `detector.detect` bracket of the run sleeps that long before the
    /// model runs, so the deadline (`DetectDeadline`), the degraded surfaces and
    /// the recovery can be driven live with no broken model.
    static var injectedHangSecs: Double = {
        return Double(ProcessInfo.processInfo.environment["SENTRY_FAKE_DETECTOR_HANG"] ?? "") ?? 0
    }()

    /// What the caller must log. `.none` is the common case — including every
    /// frame of an ongoing failure after the first, which is why the published
    /// health does not change there either.
    enum Transition: Equatable {
        case none
        /// The streak just reached `failingStreak`.
        case began(since: Date, errors: Int)
        /// A frame succeeded while failing. `afterErrors` is the whole streak.
        case ready
        case recovered(afterErrors: Int)
    }

    private(set) var health: DetectorHealth = .healthy
    /// Consecutive throwing frames, reset by the first success.
    private(set) var streak = 0
    private var streakSince: Date?
    private var firstSuccess = true

    /// One throwing `detector.detect`. The caller HOLDS the covers on screen
    /// for this frame whatever the return value says: a frame the detector
    /// could not answer carries no evidence that the screen became clean.
    mutating func noteError(at now: Date) -> Transition {
        streak += 1
        let since = streakSince ?? now
        streakSince = since
        guard streak >= Self.failingStreak else { return .none }
        guard case .healthy = health else { return .none }
        health = .failing(since: since)
        return .began(since: since, errors: streak)
    }

    /// One successful `detector.detect`. Recovery is immediate and needs no
    /// streak of its own: a frame the model answered is direct evidence that
    /// it is answering, which is exactly the claim the green shield makes.
    mutating func noteSuccess() -> Transition {
        let errors = streak
        streak = 0
        streakSince = nil
        let first = firstSuccess
        firstSuccess = false
        // UIState survives Pipeline replacement. Its first actual success
        // must clear a failure published by the previous Pipeline.
        guard case .failing = health else { return first ? .ready : .none }
        health = .healthy
        return .recovered(afterErrors: errors)
    }

    /// Panic / pause: the covers are down and every detect-side state is being
    /// rebuilt, so a streak from before the pause must not survive into the
    /// resumed run.
    ///
    /// `health` is deliberately LEFT ALONE. Clearing it here would strand the
    /// parent UI on "interrupted" forever: the edge that publishes recovery is
    /// `noteSuccess` seeing a `failing` health, so a silent clear would consume
    /// that edge and nothing would ever publish `.healthy` again. A pause also
    /// does not repair a broken model — the header says "Paused", which outranks
    /// everything, and the first answered frame after the resume publishes the
    /// real recovery.
    mutating func clearStreak() {
        streak = 0
        streakSince = nil
    }
}

/// A detector that HANGS instead of throwing.
/// `DetectorWatch` only counts calls that RETURN an error; a `detect` that never
/// returns produced no error, no success, and no frame, so the popover kept
/// reading "Protected" over a screen nothing was examining. This is the
/// deadline on the call itself: `Pipeline.step` brackets every `detect` with
/// `begin`/`end`, and a timer OFF `detectQueue` (which the hung call is
/// blocking) calls `check`.
///
/// A class with a lock, not a value type: `begin`/`end` run on `detectQueue`,
/// `check` on the watchdog timer's queue. No clock of its own, so
/// `--ui-selftest` drives a stall without waiting for one.
final class DetectDeadline {
    /// Longest a single `detector.detect` bracket may run before the parent
    /// surfaces stop saying "Protected". TRIPWIRE, not a tuning knob. The
    /// bracket is one call, or two when `recheck` adds the shifted settle pass.
    ///
    /// Receipt — MEASURED 2026-09-30 on a test Mac's installed agent
    /// (`/Library/Logs/SentryScreen/501/run.jsonl`, 2026-09-29T17:54Z to
    /// 2026-09-30T09:46Z): 885 active summary windows, 490,564 frames; the
    /// healthy per-window `inferP95` (a frame's whole `step`, tracking included,
    /// so an upper bound on `detect`) never exceeded 63.3 ms, p50 39.6 ms at
    /// worst. That log was replaced by an agent restart and not archived.
    /// Re-measured the same way on its successor, archived on a test Mac as
    /// `~/dev/transfer/wp3a-receipt-run.jsonl` (sha256 f945502a…8cc8106c,
    /// 2026-09-30T10:35Z to 14:00Z): 206 active windows, 10,444 frames, worst
    /// `inferP95` 19.0 ms, worst `inferP50` 13.2 ms. Single frames, MEASURED 2026-09-30 on a test Mac through `--process`
    /// (steady fixture, 640m model, arm64): 1,800 frames, `inferMs` p50
    /// 8.5, p95 10.4, max 16.5 ms (the first frame).
    /// The slowest thing on record that contains a first call is a COLD BOOT:
    /// `firstFrameMs=19434`.
    /// Every
    /// other start: 577-3,442 ms.
    /// 30 s is above that worst whole-startup number, so even if the entire
    /// startup were one detect call a healthy Mac stays under it (~1.5x the
    /// cold boot, ~470x the worst healthy window, ~1,800x the worst single
    /// frame). The cost is a slower red: the shield turns within `limitSecs +
    /// tickSecs` = 31 s of a hang, which is fine for a status whose covers are
    /// already frozen in place (a hung call changes nothing on screen either
    /// way). Not measured: the longest single call in a LIVE run (only
    /// per-window percentiles are logged there), and the cold-boot call split
    /// out of `firstFrameMs`. If a healthy run reaches this, remeasure and
    /// re-receipt rather than raising the number.
    static let limitSecs: Double = 30
    /// How often the watchdog looks. DERIVED: 1 s is the repo's existing
    /// parent-surface cadence (`Pipeline.pauseTickSecs`); against the 30 s
    /// `limitSecs` it adds at most 1 s (~3 %) to the time-to-red, so a finer
    /// tick buys nothing.
    static let tickSecs: Double = 1

    struct Stall: Equatable {
        /// When the hung call began.
        let since: CFAbsoluteTime
        /// Seconds it had been running when the watchdog saw it.
        let observedSecs: Double
    }
    /// What `end` tells the caller.
    struct Finish: Equatable {
        /// Seconds the call took.
        let elapsedSecs: Double
        /// A stall was published for this call: the caller must republish
        /// health now that the detector answered.
        let stallWasPublished: Bool
    }

    private let lock = NSLock()
    private var inFlightSince: CFAbsoluteTime?
    private var published = false

    /// `detectQueue`, immediately before a `detect` call.
    func begin(at now: CFAbsoluteTime) {
        lock.lock(); defer { lock.unlock() }
        inFlightSince = now
        published = false
    }

    /// `detectQueue`, after the call returned OR threw.
    func end(at now: CFAbsoluteTime) -> Finish {
        lock.lock(); defer { lock.unlock() }
        let elapsed = inFlightSince.map { now - $0 } ?? 0
        let wasPublished = published
        inFlightSince = nil
        published = false
        return Finish(elapsedSecs: elapsed, stallWasPublished: wasPublished)
    }

    /// A stall was published for the call still in flight.
    var isStalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// Watchdog queue. Non-nil exactly ONCE per hung call, on the tick that
    /// first finds it past `limitSecs`.
    func check(at now: CFAbsoluteTime) -> Stall? {
        lock.lock(); defer { lock.unlock() }
        guard let since = inFlightSince, !published, now - since > Self.limitSecs else { return nil }
        published = true
        return Stall(since: since, observedSecs: now - since)
    }
}

/// How many of this Mac's screens protection actually covers.
///
/// MVP scope (owner, 2026-09-11): this value makes the status HONEST. It
/// does not add multi-display capture — `Capture.start` still captures one
/// `SCDisplay` and the overlay still paints one `NSScreen`.
struct DisplayScope: Equatable {
    /// Displays AppKit currently reports as connected.
    var displayCount: Int
    /// The one display that is captured and covered.
    var protectedDisplayID: CGDirectDisplayID
    /// `NSScreen.localizedName` of that display ("Built-in Retina Display"),
    /// or `Display <id>` when no `NSScreen` matches. Used ONLY on this Mac's
    /// own screen — it is deliberately absent from the log record, which
    /// carries ids and counts, so a diagnostics report never ships a
    /// parent's monitor model.
    var protectedName: String
    /// Whether the captured display is still in the current AppKit inventory.
    /// False means every connected display is outside the capture scope.
    var protectedDisplayConnected: Bool = true

    /// Before capture starts, and for every host with no capture at all
    /// (`--ui-demo`, the selftests, `--process`). One display is the only
    /// claim a surface may make without evidence, and it is the claim that
    /// shows NO warning — a warning invented before the count is known would
    /// be a false alarm on every single-display Mac.
    static let single = DisplayScope(displayCount: 1, protectedDisplayID: 0, protectedName: "")

    /// True exactly when screens this build cannot cover are connected.
    var hasUnprotectedDisplays: Bool { unprotectedCount > 0 }
    var unprotectedCount: Int {
        max(0, displayCount - (protectedDisplayConnected ? 1 : 0))
    }

    /// The tripwire record's info text (`"event":"capture"`). Ids and counts
    /// only — see `protectedName`. MEASURED 2026-09-11: an M1 Mac is
    /// single-display (no such record in 2,521 summary windows of
    /// `/Library/Logs/SentryScreen/501/run.jsonl`), so in production today the
    /// record fires only on a Mac the audit's multi-display gap is real for.
    var logInfo: String {
        let coverage = protectedDisplayConnected
            ? "only the captured display is covered"
            : "the captured display is not connected; no connected display is covered"
        return "state=display-scope displays=\(displayCount) protected=\(protectedDisplayID) "
            + "connected=\(protectedDisplayConnected ? 1 : 0) "
            + "unprotected=\(unprotectedCount) — \(coverage); "
            + "content on the other display(s) is NOT covered "
            + "(fix: Capture.start captures one SCDisplay)"
    }
}

/// The one protection verdict every parent surface reads. Composed, never
/// stored: the popover header, the detail line, the menu-bar glyph and the
/// status toast all derive from the same expression, so they cannot disagree.
enum ProtectionHealth: Equatable {
    case starting
    case protecting
    /// Frames are arriving and the model is not answering. Covers already on
    /// screen are HELD (Pipeline.step's detector catch branch); nothing new
    /// can be found until the detector answers again.
    case detectorFailing(since: Date)
    case captureLost(since: Date, reason: String)

    /// Capture outranks the detector. Receipt (requirement, not a
    /// measurement): with no frames arriving the detector cannot be asked at
    /// all, so its last verdict is stale — and a lost capture is the failure a
    /// parent can act on, with a named repair surface behind it. Reporting the
    /// detector over it would send them to the wrong door.
    static func compose(capture: CaptureHealth, detector: DetectorHealth) -> ProtectionHealth {
        switch capture {
        case .starting:
            return .starting
        case let .lost(since, reason):
            return .captureLost(since: since, reason: reason)
        case .protecting:
            if case let .failing(since) = detector { return .detectorFailing(since: since) }
            return .protecting
        }
    }

    var detectorIsFailing: Bool {
        if case .detectorFailing = self { return true }
        return false
    }

    /// True for both failure kinds: whatever the cause, this Mac is not doing
    /// what the green shield promises.
    var isFailing: Bool {
        switch self {
        case .protecting, .starting: return false
        case .detectorFailing, .captureLost: return true
        }
    }
}

/// Parent copy for the two states this file adds. Parent sentences, not engine
/// strings: every line says what is true of the family's Mac and, where there
/// is one, the one thing a parent can do.
enum ProtectionCopy {
    // MARK: Detector failing

    static let detectorHeader = "Protection is interrupted"
    static let detectorDetail = "SentryScreen cannot check the screen right now"
    /// The persistent row. Says both halves honestly — what is still covered,
    /// and what is not.
    static let detectorRow =
        "SentryScreen stopped being able to check the screen. Anything already "
        + "covered stays covered, but new content is not being checked."
    /// The one action a parent has, FIRST (review 2026-09-11). There is no
    /// in-app repair: the model is loaded once at launch, so a restart is what
    /// reloads it. The earlier first sentence ("This usually clears up on its
    /// own") had no receipt and was contradicted by this file's own MEASURED
    /// baseline — 622,026 frames with zero detector errors ever, i.e. no
    /// evidence at all that these faults are transient — and it told a parent
    /// to wait while new content went unchecked.
    static let detectorBody =
        "Restart this Mac to fix this. Until then, anything already covered stays covered."
    static let detectorSummary = "SentryScreen — protection interrupted"
    /// alerts.log, the durable parent-readable trail (same file and shape as
    /// the capture alert, `CaptureAlert`): a parent reading the health report
    /// the next day must not see a detector outage as a silent gap.
    static let detectorAlert =
        "detector stopped responding — covers on screen are held, new content is "
        + "NOT being checked. Restart this Mac if it does not clear."
    static let detectorAlertCleared = "detector responding again — protection is checking the screen"

    // MARK: Display scope

    /// The persistent row on a multi-display Mac. Names the protected screen,
    /// because "this Mac" is exactly the overstatement the audit found.
    static func displayRow(_ scope: DisplayScope) -> String {
        let name = scope.protectedName.isEmpty ? "one screen" : scope.protectedName
        if !scope.protectedDisplayConnected {
            let screens = scope.unprotectedCount == 1
                ? "The connected screen is" : "The connected screens are"
            return "\(name) is no longer connected. \(screens) not protected."
        }
        let unprotected = scope.unprotectedCount
        let screens = unprotected == 1 ? "the other screen" : "the other \(unprotected) screens"
        return "Only \(name) is protected. Anything on \(screens) connected to this Mac is "
            + "not covered."
    }

    /// `detailText` while protecting. One display ⇒ who it covers; more ⇒
    /// name the one screen that is covered. Review 2026-09-29 (item 1):
    /// "Watching this Mac" read as surveillance of the child; the product
    /// covers content, it does not watch people.
    static let protectingDetail = "On for everyone on this Mac"

    static func watchingDetail(_ scope: DisplayScope) -> String {
        if !scope.protectedDisplayConnected { return "No connected screen is protected" }
        guard scope.hasUnprotectedDisplays, !scope.protectedName.isEmpty else {
            return protectingDetail
        }
        return "Only \(scope.protectedName) is covered"
    }
}
