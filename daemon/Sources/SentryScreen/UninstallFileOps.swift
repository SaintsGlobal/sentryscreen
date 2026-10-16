import Foundation
import Darwin

/// App-owned data only. Directory descriptors prevent a writable home from
/// redirecting privileged cleanup. No system scripting runtime is required.
enum UninstallFileOps {
    static let userLeaves = [
        "Library/Caches/SentryScreen", "Library/Application Support/SentryScreen",
        "Library/Caches/com.sentryscreen.agent", "Library/Caches/com.sentryscreen.uninstaller",
        "Library/Preferences/com.sentryscreen.agent.plist",
        "Library/Preferences/com.sentryscreen.uninstaller.plist",
        "Library/Saved Application State/com.sentryscreen.agent.savedState",
        "Library/Saved Application State/com.sentryscreen.uninstaller.savedState"
    ]
    static let darwinCacheLeaves = ["com.sentryscreen.agent", "com.sentryscreen.uninstaller"]
    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let code: Int32
        var description: String { "ERROR: uninstall-file-ops operation=\(operation) errno=\(code) remediation=repair-account-path-and-retry-removal" }
    }
    private static func failure(_ operation: String) -> Failure {
        Failure(operation: operation, code: errno)
    }

    /// Open each component relative to an already-open directory. ENOENT
    /// means the app-owned leaf cannot exist. All other failures are visible.
    static func directory(_ path: String) throws -> Int32? {
        guard path.hasPrefix("/") else { throw Failure(operation: "absolute-path", code: EINVAL) }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(".") && !parts.contains("..") else {
            throw Failure(operation: "dot-component", code: EINVAL)
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw failure("open-root") }
        do {
            for part in parts {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next < 0 {
                    if errno == ENOENT { close(fd); return nil }
                    throw failure("open-parent-no-follow")
                }
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func erase(_ name: String, in parent: Int32, device: dev_t) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw failure("stat-leaf-no-follow")
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard info.st_dev == device else { throw Failure(operation: "refuse-mounted-tree", code: EXDEV) }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw failure("open-child-no-follow") }
            defer { close(child) }
            let copy = dup(child)
            guard copy >= 0 else { throw failure("duplicate-directory") }
            guard let stream = fdopendir(copy) else { close(copy); throw failure("read-directory") }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw failure("read-entry") }
                    break
                }
                let entryName = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if entryName == "." || entryName == ".." { continue }
                try erase(entryName, in: child, device: device)
            }
            if unlinkat(parent, name, AT_REMOVEDIR) != 0 { throw failure("remove-directory") }
        } else if unlinkat(parent, name, 0) != 0 { throw failure("unlink-leaf") }
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw Failure(operation: "leaf-still-present", code: EEXIST)
        }
        if errno != ENOENT { throw failure("verify-absent") }
    }

    static func cleanHome(_ home: String) throws {
        guard home != "/", home != "/Users", home != "/Library", home != "/System",
              home != "/var/empty", !home.contains("\n"), !home.contains("\r") else {
            throw Failure(operation: "safe-home", code: EINVAL)
        }
        for relative in userLeaves {
            let target = home + "/" + relative
            let parent = (target as NSString).deletingLastPathComponent
            guard let fd = try directory(parent) else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw failure("stat-parent") }
            try erase((target as NSString).lastPathComponent, in: fd, device: info.st_dev)
        }
    }

    static func darwinCacheDirectory() throws -> String {
        // Receipt: macOS confstr(3) identifies the current user's cache root.
        // Unlike the temporary directory, it is not normally cleaned by macOS.
        let count = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard count > 0 else { throw failure("discover-darwin-cache") }
        var bytes = [CChar](repeating: 0, count: count)
        let needed = confstr(_CS_DARWIN_USER_CACHE_DIR, &bytes, count)
        guard needed > 0 else { throw failure("discover-darwin-cache") }
        guard needed <= count else {
            throw Failure(operation: "darwin-cache-path-changed", code: EOVERFLOW)
        }
        let path = String(cString: bytes)
        // /var is Apple's system alias. Do not resolve any user-controlled
        // symlink: directory() must still pin every remaining component.
        return path.hasPrefix("/var/") ? "/private" + path : path
    }

    static func cleanDarwinCache(at path: String, owner: uid_t) throws {
        guard let fd = try directory(path) else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("stat-darwin-cache") }
        guard info.st_uid == owner else {
            throw Failure(operation: "darwin-cache-owner", code: EPERM)
        }
        for leaf in darwinCacheLeaves {
            try erase(leaf, in: fd, device: info.st_dev)
        }
    }

    static func cleanDarwinCache(for uid: uid_t) throws {
        guard uid != 0, let account = getpwuid(uid) else {
            throw Failure(operation: "darwin-cache-account", code: EINVAL)
        }
        // This command is a separate, short-lived root worker. Drop its
        // credentials permanently before discovery and removal, so confstr
        // selects this account and cleanup cannot exceed its file access.
        let gid = account.pointee.pw_gid
        guard setgroups(0, nil) == 0, setgid(gid) == 0, setuid(uid) == 0,
              getuid() == uid, geteuid() == uid else {
            throw failure("darwin-cache-drop-credentials")
        }
        try cleanDarwinCache(at: darwinCacheDirectory(), owner: uid)
    }

    static func rootCommand(_ arguments: [String]) -> Int32 {
        guard geteuid() == 0 else { return 77 }
        guard arguments.count == 2 else { return 64 }
        do {
            switch arguments[0] {
            case "--uninstall-clean-home": try cleanHome(arguments[1])
            case "--uninstall-clean-cache":
                guard let uid = uid_t(arguments[1]) else { return 64 }
                try cleanDarwinCache(for: uid)
            default: return 64
            }
            return 0
        } catch {
            // JSON errors can include input details; never print those.
            let message = (error as? Failure)?.description
                ?? "ERROR: uninstall-file-ops operation=unknown remediation=rerun-uninstall"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return 1
        }
    }
}
