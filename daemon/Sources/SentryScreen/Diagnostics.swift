import Foundation
import Network

// Diagnostic reports: the app's only network egress (docs/diagnostics.md).
//
// Nothing is ever sent on its own. The Mac's owner opens Settings, presses
// "Review a diagnostic report…", enters the parent PIN when one is set, reads
// the whole redacted report, and presses Send. That one press POSTs the report
// once to `DiagnosticsUpload.endpoint`. The reply is read only for its status
// code; nothing from the server is kept. There is no queue, no retry and no
// identifier that links one report to another.
//
// DiagnosticsRedaction.swift builds the report from allowlists; this file
// reads the inputs, wraps the report in the receiver's envelope, and sends it.

// MARK: - Copy

enum DiagnosticsCopy {
    static let explanation =
        "If something is wrong, you can send us a diagnostic report. You see the whole report before anything is sent. Never screen content."
    static let disclosureTitle = "What is sent"
    static let disclosureLines: [String] = [
        "The SentryScreen version and the macOS version.",
        "This Mac's model and how long it has been running.",
        "Whether SentryScreen's background services are running.",
        "SentryScreen's own status lines and counters from its logs.",
        "SentryScreen's settings.",
        "SentryScreen's most recent crash log, if there is one.",
    ]
    static let disclosureNever = "Never screen content, images, what was detected, window titles, application names, your name, or your e-mail address."
    static let disclosureOnce = "Sent once, only when you press Send. Nothing is sent in the background."
    static let review = "Review a diagnostic report…"
    static let reviewTitle = "Diagnostic report"
    static let reviewIntro = "This is exactly what will be sent. Nothing is sent unless you press Send."
    static let reviewBuilding = "Building the report…"
    static let send = "Send"
    static let sending = "Sending…"
    static let buildFailed = "The report could not be built. Details are in the log."
    static let unreachable = "Could not reach the server. Nothing was sent."
    static func refused(status: Int) -> String { "The server refused the report (HTTP \(status))." }
    static func sent(at unixS: Int) -> String {
        "Report sent at \(sentTime.string(from: Date(timeIntervalSince1970: TimeInterval(unixS))))."
    }
    private static let sentTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func notice(for state: DiagnosticsSendState) -> String {
        switch state {
        case .sending: return sending
        case let .sent(at): return sent(at: at)
        case let .failed(text): return text
        }
    }
}

/// The notice under the button. In memory only; cleared when Settings closes.
enum DiagnosticsSendState: Equatable {
    case sending
    case sent(at: Int)
    case failed(String)

    /// Machine vocabulary for the UI driver (`ui.settings.diagnostics.notice.state`).
    var name: String {
        switch self {
        case .sending: return "sending"
        case .sent: return "sent"
        case .failed: return "failed"
        }
    }
}

// MARK: - Input sources

/// Where the report's inputs live for this process. `launchctl` is a
/// closure so the selftest can feed canned output.
struct DiagnosticsSources {
    /// `/Library/Application Support/SentryScreen` on an install (the parent
    /// of the state root): build-metadata.tsv, model-identity.tsv.
    var supportDir: String
    /// `/Library/Logs/SentryScreen/<uid>`: agent.err, alerts.log, run.jsonl.
    var logDir: String
    /// `~/Library/Logs/DiagnosticReports`, where macOS writes `.ips` files
    /// for this user's processes.
    var crashReportsDir: String
    var settingsPath: String
    var launchctl: (String) -> String? = DiagnosticsSources.runLaunchctl
    /// Copied into the report's `app` section (DiagnosticsInputs.appExtras).
    var appExtras: [String: Any] = [:]
    var isAdminUID: (uid_t) -> Bool = { AdminCheck.isAdminSession(uid: $0).admin }

    /// run.jsonl tail read: a `summary` every 60 s plus cover events; 2 MiB is
    /// several hours, far more than the 20 summaries + 50 events kept.
    static let runTailBytes = 2 * 1024 * 1024
    /// agent.err / alerts.log tail: both are capped and rotated by
    /// agent-launch.sh and AlertsLog, so 1 MiB reads the current file whole.
    static let textTailBytes = 1024 * 1024
    /// Crash log read cap; the report cap truncates a larger one by name.
    static let ipsTailBytes = 512 * 1024

    /// The two launchd labels: the agent in this GUI session and the system
    /// watchdog.
    static func launchdTargets(uid: uid_t) -> [(label: String, target: String)] {
        [
            ("com.sentryscreen.agent", "gui/\(uid)/com.sentryscreen.agent"),
            ("com.sentryscreen.watchdog", "system/com.sentryscreen.watchdog"),
        ]
    }

    /// The last `maxBytes` of a file as UTF-8 (lossy), nil when absent.
    static func tail(_ path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") {
            // A mid-line start: drop the partial first line.
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    /// `/bin/launchctl print <target>` with the onboarding checker's budget
    /// (UIOnboardingServiceChecker.launchctlTimeout). nil on a non-zero exit
    /// or the tripwire; the report then says `unavailable`.
    static func runLaunchctl(_ target: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let lock = NSLock()
        var expired = false
        let watchdog = DispatchWorkItem {
            lock.lock(); expired = true; lock.unlock()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + UIOnboardingServiceChecker.launchctlTimeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        lock.lock(); let tripped = expired; lock.unlock()
        if tripped {
            FileHandle.standardError.write(Data(
                ("diagnostics: " + UIOnboardingServiceChecker.launchctlTripwireRecord([target]) + "\n").utf8))
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Whether THIS uid owns the console.
    static func consoleUserPresent(uid: uid_t) -> Bool {
        var st = stat()
        return stat("/dev/console", &st) == 0 && st.st_uid == uid
    }

    /// Newest `sentry-screen-*.ips` / `SentryScreen-*.ips` in
    /// `crashReportsDir`, nil when there is none. The date is in the name,
    /// so the lexically last is the newest.
    func newestCrashFile() -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: crashReportsDir) else { return nil }
        return names.filter {
            let lower = $0.lowercased()
            return lower.hasSuffix(".ips") && (lower.hasPrefix("sentry-screen-") || lower.hasPrefix("sentryscreen-"))
        }.sorted().last
    }

    func gather(now: Int, uid: uid_t, isAdmin: Bool) -> DiagnosticsInputs {
        var launchd: [String: [String: Any]] = [:]
        for (label, target) in Self.launchdTargets(uid: uid) {
            if let text = launchctl(target) {
                launchd[label] = DiagnosticsReport.launchdFacts(text)
            } else {
                launchd[label] = ["state": "unavailable", "pid_present": false, "last_exit": NSNull()]
            }
        }
        var crash: (file: String, ips: String)?
        if let crashFile = newestCrashFile() {
            let text = Self.tail(crashReportsDir + "/" + crashFile, maxBytes: Self.ipsTailBytes) ?? "(unreadable)"
            crash = (file: crashFile, ips: text)
        }
        return DiagnosticsInputs(
            createdAt: now,
            buildMetadataTSV: try? String(contentsOfFile: supportDir + "/build-metadata.tsv", encoding: .utf8),
            modelIdentityTSV: try? String(contentsOfFile: supportDir + "/model-identity.tsv", encoding: .utf8),
            osVersion: Self.osVersion(),
            arch: HostArch.compiled,
            hwModel: Self.hardwareModel(),
            uptimeS: Int(ProcessInfo.processInfo.systemUptime),
            uid: uid,
            isAdmin: isAdmin,
            consoleUserPresent: Self.consoleUserPresent(uid: uid),
            settingsJSON: FileManager.default.contents(atPath: settingsPath),
            launchd: launchd,
            alertsLog: Self.tail(logDir + "/alerts.log", maxBytes: Self.textTailBytes),
            agentErr: Self.tail(logDir + "/agent.err", maxBytes: Self.textTailBytes),
            runJSONL: Self.tail(logDir + "/run.jsonl", maxBytes: Self.runTailBytes),
            crash: crash,
            isAdminUID: isAdminUID,
            appExtras: appExtras)
    }
}

// MARK: - The draft (what the review shows is what is sent)

/// One report, wrapped in the receiver's envelope. `text` is the envelope
/// pretty-printed for the review; `body` is the same object, gzipped, for
/// the POST. Nothing else is sent.
struct DiagnosticsDraft: Equatable {
    let text: String
    let body: Data

    /// The receiver's envelope (web `src/diagnostics.ts`). `machine_id` is a
    /// field the receiver requires; here it is a fresh random UUID for every
    /// report and is never stored, so two reports cannot be linked by it.
    static func make(report: [String: Any], createdAt: Int) throws -> DiagnosticsDraft {
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String
        let envelope: [String: Any] = [
            "machine_id": UUID().uuidString.lowercased(),
            "app_version": info?["CFBundleShortVersionString"] as? String ?? UIVersion.fallbackShort,
            "app_build": Int(build ?? UIVersion.fallbackBuild) ?? 0,
            "os_version": DiagnosticsSources.osVersion(),
            "arch": HostArch.compiled,
            // A binary run straight out of daemon/.build has no Info.plist.
            "channel": build == nil ? "dev" : "stable",
            "reason": "manual",
            "created_at": createdAt,
            "report": report,
        ]
        let pretty = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let compact = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return DiagnosticsDraft(text: String(decoding: pretty, as: UTF8.self), body: try Gzip.compress(compact))
    }
}

// MARK: - The agent

/// Builds a draft on request and sends it on request. Main-thread API; the
/// gather (a few MiB of log tails, three launchctl calls) runs on a utility
/// queue so it never blocks the thread that paints.
final class DiagnosticsAgent {
    let sources: DiagnosticsSources
    let isAdmin: Bool
    private let log: (String, String) -> Void
    private let queue = DispatchQueue(label: "sentry.diagnostics", qos: .utility)
    private let now: () -> Int

    /// The notice under the button (nil = none). Changes reach the UI through
    /// `onSendStateChange`.
    private(set) var sendState: DiagnosticsSendState?
    var onSendStateChange: ((DiagnosticsSendState?) -> Void)?
    /// A result for an earlier send (the sheet closed meanwhile) is dropped.
    private var generation = 0

    init(sources: DiagnosticsSources, isAdmin: Bool, log: @escaping (String, String) -> Void,
        now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) })
    {
        self.sources = sources
        self.isAdmin = isAdmin
        self.log = log
        self.now = now
    }

    /// Gather → build → redact → envelope. Synchronous; the selftest calls it.
    func makeDraft() throws -> DiagnosticsDraft {
        let at = now()
        let inputs = sources.gather(now: at, uid: getuid(), isAdmin: isAdmin)
        let (data, _) = try DiagnosticsReport.encode(DiagnosticsReport.build(inputs))
        let report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return try DiagnosticsDraft.make(report: report, createdAt: at)
    }

    /// Builds the draft off the main thread; `completion` runs on main with
    /// nil when it could not be built (the reason is logged).
    func prepare(_ completion: @escaping (DiagnosticsDraft?) -> Void) {
        queue.async { [self] in
            var draft: DiagnosticsDraft?
            do { draft = try makeDraft() } catch {
                log("diagnostics", "report could not be built: \(error)")
            }
            DispatchQueue.main.async { completion(draft) }
        }
    }

    /// The owner pressed Send on the review. One POST, no retry.
    func send(_ draft: DiagnosticsDraft) {
        generation += 1
        let gen = generation
        setSendState(.sending)
        log("diagnostics", "sending one report (\(draft.body.count) B gzip) to \(DiagnosticsUpload.endpoint)")
        DiagnosticsUpload.post(draft.body) { [weak self] result in
            DispatchQueue.main.async { self?.finishSend(result, generation: gen) }
        }
    }

    private func finishSend(_ result: Result<Int, DiagnosticsUpload.Failure>, generation gen: Int) {
        guard gen == generation else { return }
        switch result {
        case let .success(status) where (200..<300).contains(status):
            log("diagnostics", "report sent (HTTP \(status))")
            setSendState(.sent(at: now()))
        case let .success(status):
            log("diagnostics", "report refused (HTTP \(status))")
            setSendState(.failed(DiagnosticsCopy.refused(status: status)))
        case let .failure(error):
            log("diagnostics", "report not sent: \(error)")
            setSendState(.failed(DiagnosticsCopy.unreachable))
        }
    }

    /// Settings closed or locked: the notice goes, and a late result is dropped.
    func clearSendNotice() {
        generation += 1
        setSendState(nil)
    }

    private func setSendState(_ next: DiagnosticsSendState?) {
        guard next != sendState else { return }
        sendState = next
        onSendStateChange?(next)
    }
}

// MARK: - The one network call

/// One HTTPS POST over Network.framework, every header byte written here.
/// URLSession is not used because it adds a User-Agent (and other headers)
/// that cannot be removed; this product sends no User-Agent.
enum DiagnosticsUpload {
    /// The receiver, set at build time: packaging writes SENTRY_DIAGNOSTICS_URL
    /// (packaging/release.env) into Info.plist as `SentryDiagnosticsURL`. Forks
    /// set their own receiver there. An unbundled build uses the default.
    static let defaultEndpoint = "https://api.sentry-screen.com/v1/diagnostics"
    static let endpoint: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "SentryDiagnosticsURL") as? String,
           !value.isEmpty {
            return value
        }
        return defaultEndpoint
    }()
    /// Whole-exchange budget. ASSUMED: a ≤256 KiB gzip body on a home
    /// connection takes a few seconds; past 30 s the owner is told it failed.
    static let timeoutS = 30

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// POSTs `body` (gzipped JSON) and reports the HTTP status, or why there
    /// is none. Only the status line of the reply is read.
    static func post(_ body: Data, completion: @escaping (Result<Int, Failure>) -> Void) {
        guard let url = URL(string: endpoint), let host = url.host, url.scheme == "https" else {
            completion(.failure(Failure(description: "bad endpoint \(endpoint)")))
            return
        }
        var head = "POST \(url.path) HTTP/1.1\r\n"
        head += "host: \(host)\r\n"
        head += "content-type: application/json\r\n"
        head += "content-encoding: gzip\r\n"
        head += "content-length: \(body.count)\r\n"
        head += "connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 443))!,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let queue = DispatchQueue(label: "sentry.diagnostics.upload")
        var finished = false
        var received = Data()
        func finish(_ result: Result<Int, Failure>) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(result)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                if let data { received.append(data) }
                if let line = received.range(of: Data("\r\n".utf8)) {
                    let status = String(decoding: received[..<line.lowerBound], as: UTF8.self).split(separator: " ")
                    if status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) {
                        finish(.success(code))
                    } else {
                        finish(.failure(Failure(description: "malformed status line")))
                    }
                } else if let error {
                    finish(.failure(Failure(description: error.localizedDescription)))
                } else if complete || received.count > 4096 {
                    finish(.failure(Failure(description: "no status line")))
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error { finish(.failure(Failure(description: error.localizedDescription))) } else { receive() }
                })
            case let .failed(error):
                finish(.failure(Failure(description: error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(timeoutS)) {
            finish(.failure(Failure(description: "no reply within \(timeoutS) s")))
        }
    }
}

// MARK: - gzip

/// RFC 1952 container around Foundation's raw DEFLATE (`NSData.compressed(using:
/// .zlib)` yields a raw deflate stream), which the receiver inflates.
enum Gzip {
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])  // ID1 ID2 CM FLG MTIME(4) XFL OS=Unix
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }
}
