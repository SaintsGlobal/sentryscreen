import Foundation

/// The protected parent credential and its shared lockout budget. This state
/// never enters settings.json: Standard accounts need the machine policy, but
/// they do not need the PIN verifier or failure counters.
struct ParentPINState: Equatable {
    static let currentVersion = 1

    var version = ParentPINState.currentVersion
    var pin: PinRecord? = nil
    var failures = PinFailures()

    var readOnly: Bool { version > Self.currentVersion }

    static let empty = ParentPINState()

    private static func parseOptionalDate(
        _ object: [String: Any],
        key: String,
        field: String
    ) -> (Date?, String?) {
        guard let raw = object[key], !(raw is NSNull) else { return (nil, nil) }
        guard let text = raw as? String,
            let date = UISettings.iso.date(from: text)
        else {
            return (nil, "\(field) must be null or a valid ISO-8601 string")
        }
        return (date, nil)
    }

    static func parse(_ data: Data) -> (ParentPINState?, String?) {
        guard let any = try? JSONSerialization.jsonObject(with: data),
            let object = any as? [String: Any]
        else { return (nil, "not a JSON object") }
        guard let version = object["version"] as? Int, version >= 1 else {
            return (nil, "version must be an integer >=1")
        }

        var state = ParentPINState()
        state.version = version
        if let rawPin = object["pin"], !(rawPin is NSNull) {
            guard let pin = rawPin as? [String: Any],
                (pin["algo"] as? String) == PinRecord.algo,
                let rounds = pin["rounds"] as? Int,
                rounds > 0,
                rounds <= Int(UInt32.max),
                let saltText = pin["salt"] as? String,
                let salt = Data(base64Encoded: saltText),
                let hashText = pin["hash"] as? String,
                let hash = Data(base64Encoded: hashText),
                !salt.isEmpty,
                !hash.isEmpty
            else {
                return (nil,
                    "pin must be null or {algo=\(PinRecord.algo), rounds, salt, hash}")
            }
            let (setAt, setAtError) = parseOptionalDate(
                pin, key: "setAt", field: "pin.setAt")
            if let setAtError { return (nil, setAtError) }
            state.pin = PinRecord(
                rounds: UInt32(rounds),
                salt: salt,
                hash: hash,
                setAt: setAt)
        }
        if let rawFailures = object["failures"], !(rawFailures is NSNull) {
            guard let failures = rawFailures as? [String: Any],
                let count = failures["count"] as? Int,
                count >= 0
            else {
                return (nil, "failures must be null or {count>=0, lastAt, lockedUntil}")
            }
            let (lastAt, lastAtError) = parseOptionalDate(
                failures, key: "lastAt", field: "failures.lastAt")
            if let lastAtError { return (nil, lastAtError) }
            let (lockedUntil, lockedUntilError) = parseOptionalDate(
                failures, key: "lockedUntil", field: "failures.lockedUntil")
            if let lockedUntilError { return (nil, lockedUntilError) }
            state.failures = PinFailures(
                count: count,
                lastAt: lastAt,
                lockedUntil: lockedUntil)
        }
        return (state, nil)
    }

    func encode() throws -> Data {
        var object: [String: Any] = ["version": version]
        if let pin {
            object["pin"] = [
                "algo": PinRecord.algo,
                "rounds": Int(pin.rounds),
                "salt": pin.salt.base64EncodedString(),
                "hash": pin.hash.base64EncodedString(),
                "setAt": pin.setAt.map(UISettings.iso.string(from:)) ?? NSNull(),
            ] as [String: Any]
        } else {
            object["pin"] = NSNull()
        }
        object["failures"] = [
            "count": failures.count,
            "lastAt": failures.lastAt.map(UISettings.iso.string(from:)) ?? NSNull(),
            "lockedUntil": failures.lockedUntil.map(UISettings.iso.string(from:)) ?? NSNull(),
        ] as [String: Any]
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }
}

enum ParentPINAuthorityHealth: Equatable {
    case readable
    case missing
    case unreadable(String)
}

/// The behavior boundary used by PIN gates, onboarding, and recovery. Tests
/// exercise this interface so the UI cannot become coupled to one file shape.
protocol ParentPINAuthorizing: AnyObject {
    var state: ParentPINState { get }
    var health: ParentPINAuthorityHealth { get }
    /// Fires after a same-process write or refresh changes the effective
    /// credential state. The owning UISettingsStore installs the observer.
    var onChange: (() -> Void)? { get set }

    /// Reloads external administrator writes. Returns true when the effective
    /// state changed and a parent surface must repaint.
    @discardableResult func refresh() -> Bool
    func mutate(_ change: (inout ParentPINState) throws -> Void) throws
}

struct ParentPINAuthorityError: Error, CustomStringConvertible {
    let path: String
    let configured: String
    let observed: String
    let remediation: String

    var description: String {
        "parent PIN authority path=\(path) configured=\(configured) "
            + "observed=\(observed) remediation=\(remediation)"
    }
}

/// Atomic administrator-shared credential authority.
///
/// Production requires `parent/` mode 2770 and `pin.json` mode 0660 with the
/// macOS `admin` group. Other users have no directory or file permissions.
/// The stable directory inode is locked across read/compare/write so two
/// administrator sessions share one failure budget and cannot lose updates.
final class ParentPINFileAuthority: ParentPINAuthorizing {
    static let directoryName = "parent"
    static let fileName = "pin.json"
    static let directoryMode: mode_t = 0o2770
    static let fileMode: mode_t = 0o660

    let root: String
    let path: String
    private(set) var state = ParentPINState.empty
    private(set) var health: ParentPINAuthorityHealth = .missing
    var onChange: (() -> Void)?

    private let expectedGroupID: gid_t
    private let autoCreateDirectory: Bool
    private let log: (String, String) -> Void
    private var hasLoadedGood = false
    private var degraded = false
    /// True in a non-admin session. `parent/` is root:admin 2770 by the tamper
    /// model, so EACCES there is the design working, not a degraded authority;
    /// it is logged once as INFO in that case. Admin sessions keep the DEGRADED
    /// line unchanged (2026-08-29, child-login receipt).
    private let standardSession: Bool

    init(
        stateRoot: String,
        expectedGroupID: gid_t,
        autoCreateDirectory: Bool,
        standardSession: Bool = false,
        log: @escaping (String, String) -> Void
    ) {
        self.standardSession = standardSession
        root = stateRoot + "/" + Self.directoryName
        path = root + "/" + Self.fileName
        self.expectedGroupID = expectedGroupID
        self.autoCreateDirectory = autoCreateDirectory
        self.log = log
        _ = refresh()
    }

    @discardableResult
    func refresh() -> Bool {
        let before = state
        let beforeHealth = health
        do {
            let directoryFD = try openValidatedDirectory()
            defer { close(directoryFD) }
            switch try readState(directoryFD: directoryFD) {
            case let .some(loaded):
                state = loaded
                health = .readable
                hasLoadedGood = true
                if degraded {
                    degraded = false
                    log("pin-authority", "protected credential file is readable again")
                }
            case .none:
                state = .empty
                health = .missing
                hasLoadedGood = false
            }
        } catch {
            degrade(error)
        }
        let changed = state != before || health != beforeHealth
        if changed { onChange?() }
        return changed
    }

    func mutate(_ change: (inout ParentPINState) throws -> Void) throws {
        let changed = try mutateState(change)
        // Notify after the directory lock and file descriptors are released.
        // An observer can then start another parent action without deadlock.
        if changed { onChange?() }
    }

    private func mutateState(
        _ change: (inout ParentPINState) throws -> Void
    ) throws -> Bool {
        let before = state
        let beforeHealth = health
        let directoryFD = try openValidatedDirectory()
        defer { close(directoryFD) }
        guard flock(directoryFD, LOCK_EX) == 0 else {
            throw makeErrnoError(
                path: root,
                configured: "exclusive directory lock",
                action: "flock")
        }
        defer { flock(directoryFD, LOCK_UN) }

        let loaded = try readState(directoryFD: directoryFD) ?? .empty
        guard !loaded.readOnly else {
            throw ParentPINAuthorityError(
                path: path,
                configured: "schema version<=\(ParentPINState.currentVersion)",
                observed: "schema version=\(loaded.version)",
                remediation: "update SentryScreen before changing the parent PIN")
        }
        var next = loaded
        try change(&next)
        next.version = ParentPINState.currentVersion
        let data = try next.encode()
        let temporaryName = ".\(Self.fileName).tmp.\(getpid()).\(UUID().uuidString)"
        let fd = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            Self.fileMode)
        guard fd >= 0 else {
            throw makeErrnoError(
                path: root + "/" + temporaryName,
                configured: "new regular file mode=0660 group=\(expectedGroupID)",
                action: "openat")
        }

        var writeFailure: Error?
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count, writeFailure == nil {
                let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    writeFailure = makeErrnoError(
                        path: path,
                        configured: "complete atomic credential write",
                        action: "write")
                } else if written == 0 {
                    writeFailure = ParentPINAuthorityError(
                        path: path,
                        configured: "write progress>0 bytes",
                        observed: "write returned 0 bytes",
                        remediation: "inspect storage health and rerun the parent action")
                } else {
                    offset += written
                }
            }
        }
        if writeFailure == nil, fchmod(fd, Self.fileMode) != 0 {
            writeFailure = makeErrnoError(
                path: path, configured: "file mode=0660", action: "fchmod")
        }
        if writeFailure == nil, fchown(fd, uid_t.max, expectedGroupID) != 0 {
            writeFailure = makeErrnoError(
                path: path,
                configured: "file group=\(expectedGroupID)",
                action: "fchown")
        }
        if writeFailure == nil {
            do { try validateFileDescriptor(fd, path: path) } catch { writeFailure = error }
        }
        if writeFailure == nil, fsync(fd) != 0 {
            writeFailure = makeErrnoError(
                path: path, configured: "durable credential write", action: "fsync")
        }
        close(fd)

        if writeFailure == nil,
            renameat(directoryFD, temporaryName, directoryFD, Self.fileName) != 0
        {
            writeFailure = makeErrnoError(
                path: path, configured: "atomic same-directory rename", action: "renameat")
        }
        if writeFailure == nil, fsync(directoryFD) != 0 {
            writeFailure = makeErrnoError(
                path: root, configured: "durable directory update", action: "fsync")
        }
        if let writeFailure {
            unlinkat(directoryFD, temporaryName, 0)
            log("pin-authority", "write refused: \(writeFailure)")
            throw writeFailure
        }

        state = next
        health = .readable
        hasLoadedGood = true
        degraded = false
        return state != before || health != beforeHealth
    }

    private func openValidatedDirectory() throws -> Int32 {
        if autoCreateDirectory, !FileManager.default.fileExists(atPath: root) {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            guard chmod(root, Self.directoryMode) == 0 else {
                throw makeErrnoError(
                    path: root, configured: "directory mode=2770", action: "chmod")
            }
        }
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw makeErrnoError(
                path: root,
                configured: "directory type=directory group=\(expectedGroupID) mode=2770",
                action: "open")
        }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                throw makeErrnoError(
                    path: root,
                    configured: "directory type=directory group=\(expectedGroupID) mode=2770",
                    action: "fstat")
            }
            let observedMode = info.st_mode & mode_t(0o7777)
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                info.st_gid == expectedGroupID,
                observedMode == Self.directoryMode
            else {
                throw ParentPINAuthorityError(
                    path: root,
                    configured: "type=directory group=\(expectedGroupID) mode=2770",
                    observed: "type=\(fileType(info.st_mode)) group=\(info.st_gid) mode=\(octal(observedMode))",
                    remediation: "run the SentryScreen installer permission repair")
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func readState(directoryFD: Int32) throws -> ParentPINState? {
        let fd = openat(directoryFD, Self.fileName, O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else {
            throw makeErrnoError(
                path: path,
                configured: "regular file group=\(expectedGroupID) mode=0660",
                action: "openat")
        }
        defer { close(fd) }
        do {
            try validateFileDescriptor(fd, path: path)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            let (parsed, reason) = ParentPINState.parse(data)
            guard let parsed else {
                throw ParentPINAuthorityError(
                    path: path,
                    configured: "valid parent PIN schema version<=\(ParentPINState.currentVersion)",
                    observed: "invalid schema: \(reason ?? "unknown parse failure")",
                    remediation: "use authenticated PIN recovery or reinstall without migrating the exposed verifier")
            }
            return parsed
        } catch {
            throw error
        }
    }

    private func validateFileDescriptor(_ fd: Int32, path: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw makeErrnoError(
                path: path,
                configured: "regular file group=\(expectedGroupID) mode=0660",
                action: "fstat")
        }
        let observedMode = info.st_mode & mode_t(0o7777)
        guard (info.st_mode & S_IFMT) == S_IFREG,
            info.st_gid == expectedGroupID,
            observedMode == Self.fileMode
        else {
            throw ParentPINAuthorityError(
                path: path,
                configured: "type=regular group=\(expectedGroupID) mode=0660",
                observed: "type=\(fileType(info.st_mode)) group=\(info.st_gid) mode=\(octal(observedMode))",
                remediation: "run the SentryScreen installer permission repair")
        }
    }

    private func degrade(_ error: Error) {
        health = .unreadable("\(error)")
        if !degraded {
            degraded = true
            if Self.isExpectedStandardSessionDenial(
                standardSession: standardSession, error: error)
            {
                log("pin-authority", "parent PIN authority not readable in a Standard "
                    + "session (expected; parent controls unavailable) path=\(path)")
            } else {
                log("pin-authority", "DEGRADED read: \(error) — keeping "
                    + (hasLoadedGood ? "last-known-good" : "no credential"))
            }
        }
    }

    /// Only a permission denial in a Standard session is expected; any other
    /// error (or the same denial in an admin session) is a real degradation.
    static func isExpectedStandardSessionDenial(standardSession: Bool, error: Error) -> Bool {
        guard standardSession, let e = error as? ParentPINAuthorityError else { return false }
        return e.observed.contains("errno=13 ")
    }

    private func makeErrnoError(path: String, configured: String, action: String) -> Error {
        let code = errno
        return ParentPINAuthorityError(
            path: path,
            configured: configured,
            observed: "\(action) errno=\(code) \(String(cString: strerror(code)))",
            remediation: "run the SentryScreen installer permission repair")
    }

    private func fileType(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: return "directory"
        case S_IFREG: return "regular"
        case S_IFLNK: return "symlink"
        default: return "other"
        }
    }

    private func octal(_ mode: mode_t) -> String {
        String(format: "%04o", mode)
    }
}
