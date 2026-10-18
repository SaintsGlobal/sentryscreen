import Combine
import Foundation

// Parent-UI state types. No SwiftUI
// here: these are the values every session — admin or not — must evaluate to
// obey a machine-wide pause. The views (later slices) only observe them.

/// Boot identity and clocks the pause logic keys on. Read once per process:
/// none of these can change within a process lifetime, and a 1 Hz tick
/// must not pay a sysctl each second for a constant.
enum BootSession {
    /// `kern.bootsessionuuid` — a genuine per-boot identity (MEASURED present
    /// on an M1 Mac, spec §1). nil if the sysctl fails, which the pause logic
    /// treats as "untilRestart has expired" (fail toward protection).
    static let uuid: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }()

    /// CLOCK_MONOTONIC seconds. Immune to wall-clock changes; does not
    /// survive a reboot — hence the wall/monotonic pair in `PauseState.timed`.
    static func uptime() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }
}

/// A panic-class pause of THIS session's agent (SPEC §8.1(1)-(2)), as the
/// pipeline publishes it to the UI (owner 2026-09-29, plan §6 item 3).
/// Unlike `PauseState` it is not machine-wide and never written to disk.
struct PanicPause: Equatable {
    let until: Date
    /// `Pipeline.panic` source: "hotkey" or "SIGUSR2".
    let source: String

    /// The emergency keys, or their dev stand-in on a dev run (SPEC
    /// §8.1(8)): the sources the parent pressed a chord for.
    var fromEmergencyKeys: Bool { source == "hotkey" || source == "SIGUSR2" }
}

/// The machine-wide pause as stored in settings.json (`pause` object).
enum PauseState: Equatable {
    case none
    /// `until` is wall clock; `untilUptime` is CLOCK_MONOTONIC seconds. The
    /// EARLIER of the two wins (spec §3.3): a wall clock moved backwards
    /// cannot extend a pause, and the wall deadline survives a reboot.
    case timed(until: Date, untilUptime: Double, by: String?, at: Date?)
    /// Over the moment `bootSession` differs from the running boot.
    case untilRestart(bootSession: String, by: String?, at: Date?)

    /// Deadline this pause is in effect until, or nil if it is not in effect
    /// now. `.distantFuture` for a live untilRestart. A past deadline never
    /// resurrects: this is re-evaluated every tick against fresh clocks.
    func effectiveUntil(
        now: Date = Date(), uptime: Double = BootSession.uptime(),
        bootSession: String? = BootSession.uuid
    ) -> Date? {
        switch self {
        case .none:
            return nil
        case let .timed(until, untilUptime, _, _):
            let monotonicDeadline = now.addingTimeInterval(untilUptime - uptime)
            let deadline = min(until, monotonicDeadline)
            return deadline > now ? deadline : nil
        case let .untilRestart(session, _, _):
            // A missing boot id reads as a different boot: fail toward
            // protection (spec §3.3).
            guard let current = bootSession, current == session else { return nil }
            return .distantFuture
        }
    }

    /// The one pause deadline the pipeline obeys (spec §5): the LATER of the
    /// panic and settings deadlines, so a short panic can never end a long
    /// parent pause early, and vice versa.
    static func compose(panic: Date?, settings: Date?) -> Date? {
        [panic, settings].compactMap { $0 }.max()
    }

    var by: String? {
        switch self {
        case .none: return nil
        case let .timed(_, _, by, _), let .untilRestart(_, by, _): return by
        }
    }

    /// `event=pause` info text (spec §5), e.g.
    /// `source=ui user=parent mode=timed until=2026-08-22T15:30:00Z (15 min)`.
    var logInfo: String {
        let user = by.map { "user=\($0) " } ?? ""
        switch self {
        case .none:
            return "source=ui \(user)mode=none"
        case let .timed(until, _, _, at):
            let mins = at.map { " (\(Int((until.timeIntervalSince($0) / 60).rounded())) min)" } ?? ""
            return "source=ui \(user)mode=timed until=\(UISettings.iso.string(from: until))\(mins)"
        case let .untilRestart(session, _, _):
            return "source=ui \(user)mode=untilRestart bootSession=\(session)"
        }
    }
}

/// Capture health as the UI will show it. Invariant (spec §8): the UI shows
/// Degraded exactly when `CaptureLossBanner` is up. The five call sites that
/// set this land in slice 4; slice 1 only defines the type.
enum CaptureHealth: Equatable {
    case starting
    case protecting
    case lost(since: Date, reason: String)
}

/// Observable root for the SwiftUI tree (slices 4+). Main-thread only.
final class UIState: ObservableObject {
    @Published var captureHealth: CaptureHealth = .starting
    /// Is the DETECTOR answering (2026-09-11)? Published by
    /// AppDelegate from `Pipeline`'s `DetectorWatch` — capture health alone
    /// could not represent this, so a dead model reported "Protected". Every
    /// surface reads the composition (`protection`), never this field.
    @Published var detectorHealth: DetectorHealth = .healthy
    /// How many of this Mac's screens protection covers (2026-09-11).
    /// Published once, when capture starts and the display list is
    /// known. `.single` until then: see DisplayScope.single for why that is the
    /// only honest default.
    @Published var displayScope = DisplayScope.single
    /// True after a pause deadline expires and until detectQueue confirms that
    /// frame processing resumed. This prevents a premature Protected claim.
    @Published var pauseResumePending = false
    /// `didSet` records what the write published. Without it a pause SHORTER
    /// than one tick is never repainted: entering it publishes (the write)
    /// but leaves `publishedPaused` false, so the tick after it expires sees
    /// false == false and skips — the popover stays on a deadline in the past
    /// forever, the exact failure `republishIfPauseChanged` exists to stop.
    /// It also drops the redundant publish one tick after every pause entry.
    /// (`didSet` does not fire from `init`, hence the seed there too.)
    @Published var settings: UISettings {
        didSet { publishedPaused = pauseUntil != nil }
    }
    /// This session's panic pause, pushed by `Pipeline.onPanicPause` on each
    /// change. `pauseUntil` composes it with the settings pause.
    @Published var panicPause: PanicPause? {
        didSet { publishedPaused = pauseUntil != nil }
    }
    /// Credential presence only. The verifier and failure counters stay in
    /// ParentPINAuthority and never enter this observable UI state.
    @Published var hasParentPIN: Bool
    @Published var devStateRoot: Bool
    /// Admin status of this session. Re-evaluated on the 1 Hz poll tick until
    /// it reads true once (spec Addendum 5).
    @Published var isAdmin: Bool
    /// Sensitivity in effect when settings.json carries no override — the
    /// tail of the §6 precedence chain (config.json policy / mode default).
    /// Resolved ONCE by `Pipeline` and pushed here (AppDelegate.startPipeline)
    /// rather than recomputed: two copies of that expression would drift, and
    /// the picker would then show a sensitivity the detector is not using.
    /// `.standard` until the pipeline exists — the popover cannot be opened
    /// before then, and the value is corrected in the same launch.
    @Published var basePolicy: PolicyMode = .standard
    /// True once ⌘⌥⌃S (spec §9.4, Addendum 6B) is actually registered.
    /// Registration is deliberately non-fatal — a collision must not take
    /// protection down over a menu-bar icon — so the result has to reach the
    /// UI or the hide-icon confirmation promises a hotkey this build does not
    /// own and the failure lives only in run.jsonl. Set from the `register()`
    /// return in AppDelegate.armRevealHotkey; false until then, and false
    /// forever in a session that never arms it (non-admin sessions have no
    /// status item, so nothing reads it there).
    @Published var revealHotkeyArmed = false
    /// True when `--policy` pinned the run (spec §6: flags win, D1).
    /// Production never passes the flag; a dev run that does gets a disabled
    /// picker saying so instead of a control that silently loses.
    @Published var policyPinned = false
    /// 2026-09-07: macOS's own answer to "is Screen
    /// Recording granted", read by AppDelegate (`CGPreflightScreenCaptureAccess`)
    /// whenever capture health changes, and false whenever capture is not
    /// lost. It names the ONE degraded cause the family can fix themselves,
    /// so the popover's persistent capture row can say "Screen Recording is
    /// off" instead of the generic "not running" for a model, component or
    /// settings failure. Presence only,
    /// and deliberately not parsed out of the `lost(reason:)` string, which
    /// six call sites and the onboarding classifier all write.
    @Published var screenRecordingOff = false
    /// This session's curtain drops, newest first (spec §7.2). Appended from
    /// the Pipeline's curtain hook via the main thread; the popover merges it
    /// with the other sessions' log tails.
    @Published private(set) var recentEvents: [ActivityItem] = []
    /// Ring bound. DERIVED (spec §13): the popover shows 10 (UIActivity.rows)
    /// × 5 popover-fulls of scrollback at ~80 B/entry = 4 KB.
    static let eventRingCapacity = 50

    /// The loaded detector's id for the settings sheet's Model row (owner
    /// 2026-09-02). Constant for the life of the process — the model path is
    /// resolved once, before the detector loads — so it is a `let`, not
    /// `@Published`. Already reduced to a BASENAME by `UIVersion.modelID` at
    /// the one place that knows the path (AppDelegate.startSettings): no
    /// filesystem path enters the UI state, so no row can leak one.
    /// Defaults to `UIVersion.modelUnconfigured` for the model-less hosts of
    /// this state (`--ui-demo`, the selftests), which load no detector.
    let modelID: String

    /// Whether the last publish said "paused". Seeded from the initial
    /// settings so an already-paused launch does not republish on tick one.
    private var publishedPaused: Bool

    init(
        settings: UISettings,
        hasParentPIN: Bool = false,
        devStateRoot: Bool,
        isAdmin: Bool,
        modelID: String = UIVersion.modelUnconfigured
    ) {
        self.settings = settings
        self.hasParentPIN = hasParentPIN
        self.devStateRoot = devStateRoot
        self.isAdmin = isAdmin
        self.modelID = modelID
        publishedPaused = settings.pause.effectiveUntil() != nil
    }

    /// Main thread. Newest first, bounded by `eventRingCapacity`.
    func recordDrop(_ item: ActivityItem) {
        recentEvents.insert(item, at: 0)
        if recentEvents.count > Self.eventRingCapacity { recentEvents.removeLast() }
    }

    /// Demo only: replace the ring wholesale with fake rows.
    func setRecentEvents(_ items: [ActivityItem]) { recentEvents = items }

    /// Republishes when the pause has expired since the last publish.
    ///
    /// `pauseUntil` is derived from the CLOCK, so a timed pause expires with
    /// nothing writing settings.json and no `@Published` firing: before this,
    /// the menu-bar glyph and an OPEN popover kept saying
    /// `Paused until 3:45 PM` — a time already in the past — indefinitely,
    /// while the pipeline's own pause tick had requested protection to resume.
    /// Called from
    /// `UISettingsStore.onTick` (1 Hz = `UISettingsStore.pollSecs`, the same
    /// cadence `Pipeline.pauseTickSecs` requests resume at). The separate
    /// `pauseResumePending` state keeps this publication from claiming
    /// Protected before detectQueue acknowledges the change. Published on
    /// `UIState` rather than pushed at the status item, because both consumers
    /// re-derive from here and
    /// `UIPopoverView` only re-reads `headerText` when this object publishes.
    ///
    /// Keyed on the paused/not-paused FLIP, not on `pauseUntil` itself: the
    /// monotonic branch of `effectiveUntil` re-derives its deadline from
    /// `now` on every call and jitters by microseconds, so comparing the Date
    /// would republish every second and re-evaluate the whole SwiftUI body
    /// for nothing. The deadline STRING can only move by a settings write,
    /// which publishes on its own — and nil→non-nil without a write is not
    /// reachable, since a pause is only ever entered by writing settings.json.
    func republishIfPauseChanged() {
        let paused = pauseUntil != nil
        guard paused != publishedPaused else { return }
        publishedPaused = paused
        objectWillChange.send()
    }
}

/// Admin-session gate (spec §9.1). uid 0 is admin; otherwise the user's group
/// list must contain gid 80 (MEASURED on an M1 Mac: uid 501 → gid 80 present).
/// A lookup FAILURE is not-admin — never show the parent controls to a child
/// because Open Directory hiccupped — and the failure text is returned so the
/// caller can log it loudly.
enum AdminCheck {
    /// gid of the `admin` group on macOS. Stable OS constant, not tunable.
    static let adminGID: gid_t = 80

    /// (admin, error). `error` non-nil means the answer is a fail-safe
    /// default, not a measurement.
    static func isAdminSession(uid: uid_t = getuid()) -> (admin: Bool, error: String?) {
        if uid == 0 { return (true, nil) }
        guard let pw = getpwuid(uid) else {
            return (false, "getpwuid(\(uid)) failed errno=\(errno)")
        }
        // Buffer sizes. MEASURED 2026-08-22 on an M1 Mac: uid 501 is in 18
        // groups; on -1 macOS leaves `count` at the size passed in (1→1, 2→2),
        // so the "retry with the returned count" idiom does not exist here —
        // retry once with a fixed 16× buffer, then fail loudly (and not-admin).
        for size: Int32 in [64, 1024] {
            var count = size
            var groups = [Int32](repeating: 0, count: Int(size))
            let rc = getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count)
            if rc == 0 {
                return (groups.prefix(Int(count)).contains(Int32(bitPattern: adminGID)), nil)
            }
        }
        return (false, "getgrouplist(\(uid)) failed after retry: >1024 groups or lookup error")
    }

    /// `name(uid)` for `updatedBy` / `pause.by`; `uid N` if the lookup fails.
    static func currentUserLabel(uid: uid_t = getuid()) -> String {
        guard let pw = getpwuid(uid) else { return "uid \(uid)" }
        return "\(String(cString: pw.pointee.pw_name))(\(uid))"
    }
}

/// The OTHER administrator accounts on this Mac, named, for the setup
/// window's Standard-account warning (owner 2026-09-07: nothing in the app
/// told a parent that the child's account must be a Standard account, and the
/// first account on a Mac is an administrator — an administrator child can
/// reset the parent PIN with their own password, `UIPinRecovery`, and remove
/// the app).
///
/// Read-only and least-privilege: `getgrnam("admin")` is the same membership
/// list `dscl . -read /Groups/admin GroupMembership` prints (MEASURED
/// 2026-09-07 on an M1 Mac: both print `root parent`), through the C library
/// rather than a subprocess — no `dscl` fork, no OpenDirectory session, no
/// authorization, and nothing writable. Names only ever reach this Mac's own
/// screen.
enum AdminAccounts {
    /// System accounts are not a child's account, and naming them would be
    /// noise. Receipt (a macOS convention, not a tunable): macOS assigns
    /// local login accounts uids from 501 up; root is 0 and every service
    /// account is below 500 (`_`-prefixed). MEASURED 2026-09-07 on an M1 Mac:
    /// the admin group holds `root` (0) and `parent` (501), and only the
    /// second is an account a family logs in to.
    static let firstLoginUID: uid_t = 500

    /// One process-lifetime cache. Receipt: MEASURED 2026-09-07 on an M1 Mac,
    /// `getgrnam("admin")` costs 1.8–2.8 ms — cheap, but the setup surface is
    /// rebuilt on every coordinator tick, so the lookup is made once. Staleness
    /// is bounded by the repair itself: changing an account's type is done in
    /// System Settings and takes effect at the next login, which is a new
    /// process here.
    private static var cached: [String]?

    /// Display names of the administrator accounts other than this session's
    /// own, sorted, or [] when the lookup finds none. A FAILED lookup is also
    /// [] — the warning row simply does not appear; it never guesses.
    static func otherAdministrators(uid: uid_t = getuid()) -> [String] {
        if let cached { return cached }
        let names = lookup(uid: uid)
        cached = names
        return names
    }

    /// Test seam: `--ui-selftest` and `--ui-onboarding-demo` script the list
    /// rather than reading this Mac's directory.
    static func setCachedForTest(_ names: [String]?) { cached = names }

    /// Main thread only (the surface is built there): `getgrnam`/`getpwnam`
    /// both answer out of static storage. The membership is copied out FIRST,
    /// before any `getpwnam` call, so nothing depends on the two libc caches
    /// being independent of each other.
    private static func lookup(uid: uid_t) -> [String] {
        guard let group = getgrnam("admin"), let members = group.pointee.gr_mem else { return [] }
        var shortNames: [String] = []
        var cursor = members
        while let member = cursor.pointee {
            shortNames.append(String(cString: member))
            cursor = cursor.advanced(by: 1)
        }
        var names: [String] = []
        for short in shortNames {
            guard let pw = getpwnam(short),
                pw.pointee.pw_uid >= firstLoginUID, pw.pointee.pw_uid != uid else { continue }
            names.append(displayName(pw, short: short))
        }
        return Array(Set(names)).sorted()
    }

    /// The full name macOS shows in Users & Groups, or the short name when
    /// the account has none.
    private static func displayName(_ pw: UnsafeMutablePointer<passwd>, short: String) -> String {
        guard let gecos = pw.pointee.pw_gecos else { return short }
        // pw_gecos is a comma-separated record on BSD; macOS puts the full
        // name in the first field.
        let full = String(cString: gecos).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = full.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? short : trimmed
    }
}
