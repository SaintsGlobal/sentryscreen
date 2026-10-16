import Foundation

enum UISettingsFileHealth: Equatable {
    case readable
    case missing
    case unreadable(String)

    var repairDetail: String {
        switch self {
        case .readable:
            return "Parent settings are readable."
        case .missing:
            return "The installed parent settings file is missing. Reinstall or repair SentryScreen."
        case let .unreadable(reason):
            return "The installed parent settings file cannot be read: \(reason)"
        }
    }
}

// Machine-wide nonsecret UI state: settings.json.
// Every session reads it (a standard user's daemon must obey a parent's
// pause); only admins can write it (the state dir is root:admin 2775,
// install.sh). The parent PIN verifier and failure budget are kept in the
// separate administrator-only ParentPINAuthority. A state-file surprise
// never exits the daemon — exiting disables protection, the wrong failure
// direction.

/// Known settings.json fields (schema version 2). Unknown top-level keys
/// ride along in `extra` and are written back verbatim.
struct UISettings: Equatable {
    /// Schema version this build writes. A file with a HIGHER version is
    /// read (known keys applied) but never written (spec §3.3).
    /// Version 2 removes all parent credential material. An older version-1
    /// app reads this as future state and refuses writes, so a rollback cannot
    /// put a new verifier back into the public file.
    static let currentVersion = 2

    var version = UISettings.currentVersion
    var pause: PauseState = .none
    var policyOverride: PolicyMode? = nil
    var showMenuBarIcon = true
    var onboarding: UIOnboardingRecord = .fresh
    var updatedAt: Date? = nil
    var updatedBy: String? = nil
    var extra: [String: AnyHashableJSON] = [:]

    /// Known top-level keys; anything else is `extra`.
    static let knownKeys: Set<String> = [
        // `pin` and `pinFailures` are retired secret fields. Treat them as
        // known so a read/write cannot preserve exposed verifier bytes in
        // `extra`. The installer also removes them before this build starts.
        "version", "pause", "policyOverride", "showMenuBarIcon", "pin", "pinFailures",
        "onboarding", "updatedAt", "updatedBy",
    ]

    var readOnly: Bool {
        version > Self.currentVersion || onboarding.readOnly
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Defaults are PROTECTIVE: not paused, no override, icon shown.
    static let defaults = UISettings()

    // MARK: JSON

    /// nil (with a reason) on any schema violation; a torn or corrupt file
    /// must never read as "paused".
    static func parse(_ data: Data) -> (UISettings?, String?) {
        guard let any = try? JSONSerialization.jsonObject(with: data),
            let obj = any as? [String: Any]
        else { return (nil, "not a JSON object") }
        var s = UISettings()
        if let v = obj["version"] {
            guard let n = v as? Int else { return (nil, "version is not an integer") }
            s.version = n
        } else {
            return (nil, "missing version")
        }
        if let p = obj["pause"] as? [String: Any] {
            let mode = p["mode"] as? String ?? "none"
            let by = p["by"] as? String
            let at = (p["at"] as? String).flatMap(iso.date(from:))
            switch mode {
            case "none":
                s.pause = .none
            case "timed":
                guard let u = p["until"] as? String, let until = iso.date(from: u),
                    let up = p["untilUptime"] as? Double
                else { return (nil, "pause.mode=timed needs until (ISO 8601) and untilUptime") }
                s.pause = .timed(until: until, untilUptime: up, by: by, at: at)
            case "untilRestart":
                guard let b = p["bootSession"] as? String else {
                    return (nil, "pause.mode=untilRestart needs bootSession")
                }
                s.pause = .untilRestart(bootSession: b, by: by, at: at)
            default:
                return (nil, "unknown pause.mode '\(mode)'")
            }
        }
        if let po = obj["policyOverride"], !(po is NSNull) {
            guard let str = po as? String, let mode = PolicyMode(rawValue: str) else {
                return (nil, "policyOverride must be null, \"standard\" or \"strict\"")
            }
            s.policyOverride = mode
        }
        if let show = obj["showMenuBarIcon"] {
            guard let b = show as? Bool else { return (nil, "showMenuBarIcon must be a bool") }
            s.showMenuBarIcon = b
        }
        if let rawOnboarding = obj["onboarding"] {
            guard let onboarding = rawOnboarding as? [String: Any],
                let schemaVersion = onboarding["schemaVersion"] as? Int,
                schemaVersion >= UIOnboardingRecord.legacySchemaVersion
            else {
                return (nil,
                    "onboarding must be an object with integer schemaVersion>=0")
            }
            if schemaVersion > UIOnboardingRecord.currentSchemaVersion {
                // Do not apply current-schema validation to a future schema.
                // Its shape can change. Retaining only the version is enough
                // to make the complete settings record read-only, so mutate()
                // cannot replace the future payload with writable defaults.
                s.onboarding = UIOnboardingRecord(
                    schemaVersion: schemaVersion,
                    completedAt: nil,
                    successShownAt: nil,
                    verificationPending: false,
                    verificationRequestID: nil,
                    verificationStartedAt: nil)
            } else {
                guard let verificationPending = onboarding["verificationPending"] as? Bool else {
                    return (nil,
                        "current onboarding schema requires completedAt, successShownAt, and verificationPending")
                }
                let completedAt: Date?
                if let value = onboarding["completedAt"], !(value is NSNull) {
                    guard let text = value as? String, let date = iso.date(from: text) else {
                        return (nil, "onboarding.completedAt must be null or ISO 8601")
                    }
                    completedAt = date
                } else {
                    completedAt = nil
                }
                let successShownAt: Date?
                if let value = onboarding["successShownAt"], !(value is NSNull) {
                    guard let text = value as? String, let date = iso.date(from: text) else {
                        return (nil, "onboarding.successShownAt must be null or ISO 8601")
                    }
                    successShownAt = date
                } else {
                    successShownAt = nil
                }
                let verificationRequestID: UUID?
                if let value = onboarding["verificationRequestID"], !(value is NSNull) {
                    guard let text = value as? String, let requestID = UUID(uuidString: text) else {
                        return (nil, "onboarding.verificationRequestID must be null or a UUID")
                    }
                    verificationRequestID = requestID
                } else {
                    verificationRequestID = nil
                }
                let verificationStartedAt: Date?
                if let value = onboarding["verificationStartedAt"], !(value is NSNull) {
                    guard let text = value as? String, let date = iso.date(from: text) else {
                        return (nil, "onboarding.verificationStartedAt must be null or ISO 8601")
                    }
                    verificationStartedAt = date
                } else {
                    verificationStartedAt = nil
                }
                guard completedAt != nil || successShownAt == nil else {
                    return (nil, "onboarding.successShownAt requires completedAt")
                }
                if let completedAt, let successShownAt, successShownAt < completedAt {
                    return (nil, "onboarding.successShownAt cannot precede completedAt")
                }
                guard schemaVersion != UIOnboardingRecord.legacySchemaVersion
                    || (completedAt == nil && successShownAt == nil)
                else {
                    return (nil, "onboarding schema 0 must remain incomplete")
                }
                guard verificationPending
                    || (verificationRequestID == nil && verificationStartedAt == nil)
                else {
                    return (nil, "settled onboarding verification cannot retain a request")
                }
                guard (verificationRequestID == nil) == (verificationStartedAt == nil) else {
                    return (nil, "onboarding verification request and start time must appear together")
                }
                s.onboarding = UIOnboardingRecord(
                    schemaVersion: schemaVersion,
                    completedAt: completedAt,
                    successShownAt: successShownAt,
                    verificationPending: verificationPending,
                    verificationRequestID: verificationRequestID,
                    verificationStartedAt: verificationStartedAt)
            }
        } else {
            // The retired public PIN verifier is deliberately not migrated.
            // An installation with no onboarding record must create a fresh
            // protected PIN before setup can continue.
            s.onboarding = .fresh
        }
        s.updatedAt = (obj["updatedAt"] as? String).flatMap(iso.date(from:))
        s.updatedBy = obj["updatedBy"] as? String
        for (k, v) in obj where !knownKeys.contains(k) {
            s.extra[k] = AnyHashableJSON(v)
        }
        return (s, nil)
    }

    func encode() throws -> Data {
        var obj: [String: Any] = [:]
        for (k, v) in extra { obj[k] = v.value }
        obj["version"] = version
        var p: [String: Any] = ["mode": "none", "until": NSNull(), "untilUptime": NSNull(),
            "bootSession": NSNull(), "by": NSNull(), "at": NSNull()]
        switch pause {
        case .none:
            break
        case let .timed(until, up, by, at):
            p["mode"] = "timed"
            p["until"] = Self.iso.string(from: until)
            p["untilUptime"] = up
            p["by"] = by ?? NSNull()
            p["at"] = at.map(Self.iso.string(from:)) ?? NSNull()
        case let .untilRestart(b, by, at):
            p["mode"] = "untilRestart"
            p["bootSession"] = b
            p["by"] = by ?? NSNull()
            p["at"] = at.map(Self.iso.string(from:)) ?? NSNull()
        }
        obj["pause"] = p
        obj["policyOverride"] = policyOverride?.rawValue ?? NSNull()
        obj["showMenuBarIcon"] = showMenuBarIcon
        obj["onboarding"] = [
            "schemaVersion": onboarding.schemaVersion,
            "completedAt": onboarding.completedAt.map(Self.iso.string(from:)) ?? NSNull(),
            "successShownAt": onboarding.successShownAt.map(Self.iso.string(from:)) ?? NSNull(),
            "verificationPending": onboarding.verificationPending,
            "verificationRequestID": onboarding.verificationRequestID?.uuidString ?? NSNull(),
            "verificationStartedAt": onboarding.verificationStartedAt.map(Self.iso.string(from:)) ?? NSNull(),
        ] as [String: Any]
        obj["updatedAt"] = updatedAt.map(Self.iso.string(from:)) ?? NSNull()
        obj["updatedBy"] = updatedBy ?? NSNull()
        var data = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }
}

/// Equatable wrapper so unknown JSON values can sit inside an Equatable
/// settings struct. Compares by re-encoded bytes.
struct AnyHashableJSON: Equatable {
    let value: Any
    init(_ value: Any) { self.value = value }
    static func == (a: AnyHashableJSON, b: AnyHashableJSON) -> Bool {
        let da = try? JSONSerialization.data(withJSONObject: [a.value], options: [.sortedKeys])
        let db = try? JSONSerialization.data(withJSONObject: [b.value], options: [.sortedKeys])
        return da != nil && da == db
    }
}

struct UISettingsWriteError: Error, CustomStringConvertible {
    let path: String
    let reason: String
    var description: String { "cannot write \(path): \(reason)" }
}

final class UISettingsStore {
    /// How often a session re-checks the machine-wide state file.
    ///
    /// Requirement: a parent taps Pause in the admin session; the child's
    /// session must stop curtaining before the parent can walk to the other
    /// Mac — call it one second, which reads as "immediately".
    /// Cost, MEASURED 2026-08-22 (an M1 Mac, 100,000 calls): stat() on
    /// /Library/Application Support/SentryScreen/... is 0.96 µs, so a 1 Hz
    /// poll is 0.0001 % of one core. Only an (ino, mtime, size) change
    /// triggers a full read+parse. Precedent: AppDelegate.captureLossPollSecs
    /// = 5 for a poll whose requirement is "within two ticks".
    static let pollSecs: TimeInterval = 1.0

    static let productionRoot = "/Library/Application Support/SentryScreen/state"
    static let fileName = "settings.json"

    /// Bounded wait for the state-directory lock `mutate` holds, 5 s.
    ///
    /// Receipt: the critical section is a reload, an in-memory edit, a write
    /// and a rename of a settings.json — MEASURED 2026-09-07 by
    /// `--ui-selftest` "settings lock" on an M1 Mac: worst 7-10 ms over 100
    /// `mutate` calls across three consecutive runs, 34 ms on a cold first
    /// run. 5 s is ~150x that, so it is a tripwire for a writer stopped or
    /// hung while holding the lock, not a working wait.
    static let lockWaitS: TimeInterval = 5
    /// Poll step. DERIVED: 20 ms is under one measured hold, so an ordinary
    /// hand-off costs at most one extra step.
    static let lockPollUS: UInt32 = 20_000

    let root: String
    let parentPINAuthority: any ParentPINAuthorizing
    /// True when root 3 (per-user dev fallback) is in use: settings are
    /// per-account and a machine-wide pause is NOT in effect.
    let devFallback: Bool
    /// True when `root` is the machine-wide production root: the parent
    /// directory's group is then `admin` (gid 80), otherwise this process's
    /// group — the PIN authority's rule.
    let isProductionRoot: Bool
    var path: String { root + "/" + Self.fileName }
    var parentPIN: PinRecord? { parentPINAuthority.state.pin }
    var parentPINFailures: PinFailures { parentPINAuthority.state.failures }

    private(set) var settings: UISettings = .defaults
    /// A production onboarding decision must distinguish a valid first-run
    /// record from damage that happened to decode as protective defaults.
    private(set) var fileHealth: UISettingsFileHealth = .missing
    /// Fires on the main thread after every observed change (poll or own
    /// write). Not called for the initial load: read `settings` after init.
    var onChange: ((UISettings) -> Void)?
    /// Fires every poll tick (AdminCheck re-evaluation, spec Addendum 5).
    var onTick: (() -> Void)?

    private let log: (String, String) -> Void
    private let requireReadableFileForWrites: Bool
    /// `Self.lockWaitS` in production; `--ui-selftest` passes a short one to
    /// drive the contended path without a five-second pause.
    private let lockWait: TimeInterval
    private var timer: Timer?
    private var lastStat: (ino: UInt64, mtime: timespec, size: Int64)?
    private var degraded = false
    private var warnedUnknownKeys = false
    private var hasLoadedGood = false

    /// State-root resolution (spec §3.2): SENTRY_STATE_DIR → production root
    /// if it exists → per-user dev fallback, loud once.
    /// The installed agent never sees `SENTRY_STATE_DIR`: its launch wrapper
    /// scrubs the environment (DevEnv.swift).
    static func resolveRoot(
        env: [String: String] = DevEnv.environment,
        productionRootExists: Bool = FileManager.default.fileExists(atPath: productionRoot)
    ) -> (root: String, devFallback: Bool) {
        if let dir = env["SENTRY_STATE_DIR"], !dir.isEmpty { return (dir, false) }
        if productionRootExists { return (productionRoot, false) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home + "/Library/Application Support/SentryScreen/state", true)
    }

    /// `log(event, info)` writes an `event=ui-state` style record; the caller
    /// decides where (run log + stderr). `root` overrides resolution
    /// (selftest only; production always resolves).
    init(
        root fixedRoot: String? = nil,
        requireReadableFileForWrites explicitWriteGuard: Bool? = nil,
        parentPINAuthority explicitPINAuthority: (any ParentPINAuthorizing)? = nil,
        standardSession: Bool = false,
        lockWaitS: TimeInterval? = nil,
        log: @escaping (String, String) -> Void
    ) {
        self.log = log
        lockWait = lockWaitS ?? Self.lockWaitS
        let r: (root: String, devFallback: Bool) = fixedRoot.map { ($0, false) } ?? Self.resolveRoot()
        let resolvedPath = URL(fileURLWithPath: r.root).standardizedFileURL.path
        let productionPath = URL(fileURLWithPath: Self.productionRoot).standardizedFileURL.path
        let isProductionRoot = resolvedPath == productionPath
        root = r.root
        devFallback = r.devFallback
        self.isProductionRoot = isProductionRoot
        parentPINAuthority = explicitPINAuthority ?? ParentPINFileAuthority(
            stateRoot: r.root,
            expectedGroupID: isProductionRoot ? AdminCheck.adminGID : getegid(),
            autoCreateDirectory: !isProductionRoot,
            standardSession: standardSession,
            log: log)
        requireReadableFileForWrites = explicitWriteGuard
            ?? isProductionRoot
        if devFallback {
            try? FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true)
            log("ui-state",
                "DEV FALLBACK state root \(root) — settings are per-user and machine-wide "
                + "pause/policy is NOT in effect (fix: sudo packaging/install.sh)")
        }
        reload(force: true)
        parentPINAuthority.onChange = { [weak self] in
            guard let self else { return }
            self.onChange?(self.settings)
        }
    }

    /// `.common` run-loop mode, not `Timer.scheduledTimer`'s default
    /// (2026-09-11): a default-mode timer stops firing while the main
    /// run loop is in an NSMenu tracking session or a modal panel. This tick is
    /// how a machine-wide pause, a policy change and a timed pause's EXPIRY
    /// reach a running agent (`onTick` → `UIState.republishIfPauseExpired`), so
    /// starving it means the menu a parent is looking at can be showing state
    /// the pipeline has already left. Cheap, and no caller depends on the tick
    /// being suspended during tracking.
    func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.pollSecs, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.parentPINAuthority.refresh()
            self.reload(force: false)
            self.onTick?()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-reads if the (ino, mtime, size) triple changed. Main thread.
    private func reload(force: Bool) {
        var st = stat()
        if stat(path, &st) != 0 {
            if !force, lastStat == nil { return }  // still missing: no change
            lastStat = nil
            fileHealth = .missing
            // A missing file is "defaults", not "degraded": a fresh install
            // or a dev dir simply has nothing to say yet.
            if hasLoadedGood { apply(.defaults, source: "missing (defaults)") }
            hasLoadedGood = false
            return
        }
        let sig = (ino: UInt64(st.st_ino), mtime: st.st_mtimespec, size: Int64(st.st_size))
        if !force, let last = lastStat, last.ino == sig.ino, last.size == sig.size,
            last.mtime.tv_sec == sig.mtime.tv_sec, last.mtime.tv_nsec == sig.mtime.tv_nsec
        {
            return
        }
        lastStat = sig
        guard let data = FileManager.default.contents(atPath: path) else {
            degrade("unreadable \(path) errno=\(errno)")
            return
        }
        let (parsed, err) = UISettings.parse(data)
        guard let s = parsed else {
            degrade("parse failed \(path): \(err ?? "?")")
            return
        }
        fileHealth = .readable
        if degraded {
            degraded = false
            log("ui-state", "state file readable again: \(path)")
        }
        hasLoadedGood = true
        if !s.extra.isEmpty, !warnedUnknownKeys {
            warnedUnknownKeys = true
            log("ui-state", "unknown keys \(s.extra.keys.sorted()) preserved")
        }
        if s.readOnly {
            let versionDetail = s.version > UISettings.currentVersion
                ? "settings version \(s.version) > \(UISettings.currentVersion)"
                : "onboarding schema \(s.onboarding.schemaVersion) > "
                    + "\(UIOnboardingRecord.currentSchemaVersion)"
            log("ui-state", "\(versionDetail): read-only — writes refused until SentryScreen is updated")
        }
        apply(s, source: "file")
    }

    /// Keep last-known-good (or defaults if there is none); log once per
    /// transition into the degraded state.
    private func degrade(_ why: String) {
        fileHealth = .unreadable(why)
        if !degraded {
            degraded = true
            log("ui-state",
                "DEGRADED read: \(why) — keeping "
                + (hasLoadedGood ? "last-known-good" : "defaults (not paused)"))
        }
        if !hasLoadedGood { apply(.defaults, source: "degraded (defaults)") }
    }

    /// Retry the exact settings read after an attended repair action. Polling
    /// remains the normal recovery path; this avoids making the parent wait
    /// for the next one-second tick.
    func refresh() {
        parentPINAuthority.refresh()
        reload(force: true)
    }

    private func apply(_ s: UISettings, source: String) {
        guard s != settings || source != "file" else { return }
        settings = s
        onChange?(s)
    }

    /// Atomic write: re-read, apply `change`, write `settings.json.tmp.<pid>`
    /// in the same directory, fchmod 0664 (FileManager.createFile would give
    /// 0644 and the SECOND admin account could never rewrite it — spec §17
    /// landmine 3), fsync, rename over the target, notify observers now.
    /// Throws a UISettingsWriteError naming the path and errno; the caller
    /// shows it — the action is never silently dropped.
    func mutate(_ change: (inout UISettings) throws -> Void) throws {
        // The settings file inode changes on every atomic rename, so locking
        // that inode would not serialize two GUI-session processes. Lock the
        // stable state-directory inode across reload, validation, and rename.
        // flock is released by the kernel if a process exits.

        let lockFD = open(root, O_RDONLY)
        guard lockFD >= 0 else {
            throw UISettingsWriteError(
                path: root,
                reason: "open directory lock errno=\(errno) \(String(cString: strerror(errno)))")
        }
        // Bounded, because this runs on the main thread: a plain blocking
        // LOCK_EX would beachball the parent's UI for as long as a stopped or
        // hung root process held the lock. Exhausting the budget writes
        // nothing and says so by name — the parent's action is refused
        // visibly, never silently dropped.
        let lockStarted = Date()
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK else {
                close(lockFD)
                throw UISettingsWriteError(
                    path: root,
                    reason: "flock errno=\(lockError) \(String(cString: strerror(lockError)))")
            }
            let waited = Date().timeIntervalSince(lockStarted)
            guard waited < lockWait else {
                close(lockFD)
                let detail = "budget settings lock wait, limit \(Int(lockWait)) s, "
                    + "observed \(String(format: "%.1f", waited)) s — another writer holds the "
                    + "lock on \(root). Nothing was written; try again."
                log("ui-state", "write refused: \(detail)")
                throw UISettingsWriteError(path: root, reason: detail)
            }
            usleep(Self.lockPollUS)
        }
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }

        reload(force: true)
        if requireReadableFileForWrites, fileHealth != .readable {
            let reason = fileHealth.repairDetail
            log("ui-state", "write refused: \(reason)")
            throw UISettingsWriteError(path: path, reason: reason)
        }
        if settings.readOnly {
            let reason: String
            if settings.version > UISettings.currentVersion {
                reason = "written by a newer version of SentryScreen (version \(settings.version))"
            } else {
                reason = "onboarding state uses newer schema version \(settings.onboarding.schemaVersion)"
            }
            log("ui-state", "write refused: \(reason)")
            throw UISettingsWriteError(path: path, reason: reason)
        }
        var next = settings
        try change(&next)
        next.version = UISettings.currentVersion
        next.updatedAt = Date()
        next.updatedBy = AdminCheck.currentUserLabel()
        let data = try next.encode()
        let tmp = root + "/" + Self.fileName + ".tmp.\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o664)
        guard fd >= 0 else {
            throw UISettingsWriteError(path: tmp, reason: "open errno=\(errno) \(String(cString: strerror(errno)))")
        }
        var failure: String?
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { failure = "write errno=\(errno)"; return }
                off += n
            }
        }
        if failure == nil, fchmod(fd, 0o664) != 0 { failure = "fchmod errno=\(errno)" }
        if failure == nil, fsync(fd) != 0 { failure = "fsync errno=\(errno)" }
        close(fd)
        if failure == nil, rename(tmp, path) != 0 { failure = "rename errno=\(errno)" }
        if let failure {
            unlink(tmp)
            log("ui-state", "write FAILED \(path): \(failure)")
            throw UISettingsWriteError(path: path, reason: failure)
        }
        var st = stat()
        if stat(path, &st) == 0 {
            lastStat = (UInt64(st.st_ino), st.st_mtimespec, Int64(st.st_size))
        }
        hasLoadedGood = true
        apply(next, source: "write")
    }
}
