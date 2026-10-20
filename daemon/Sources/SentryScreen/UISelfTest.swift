import AppKit
import Carbon.HIToolbox
import Combine
import CoreFoundation
import CoreVideo
import CryptoKit
import Foundation
import SwiftUI

// `--ui-selftest`: plain executable asserts, no
// XCTest (unavailable in this build). The default suite runs before the app
// entry point touches NSApplication; the explicit native-menu-pause case owns
// a small AppKit window. Prints TAP-ish lines and returns the process exit code
// (0 = all pass).
// Always runs against a private temp state dir: a selftest must never touch
// the family's real PIN.

private final class NativeMenuSelfTestDelegate: NSObject, NSMenuDelegate {
    var didOpen = false
    var didClose = false

    func menuWillOpen(_ menu: NSMenu) { didOpen = true }
    func menuDidClose(_ menu: NSMenu) { didClose = true }
}

enum UISelfTest {
    /// PBKDF2 verify must take at least this long (Addendum 4: lower bound
    /// only, no ceiling — this shared box drifts under load). DERIVED from the
    /// MEASURED ~100 ms at UIPin.rounds: half of it trips an accidental
    /// `rounds = 1` or a silently smaller PRF while tolerating a fast CPU.
    static let minVerifySecs = 0.05

    private static var passed = 0
    private static var failed = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            print("ok   - \(name)")
        } else {
            failed += 1
            print("not ok - \(name)")
            let d = detail()
            if !d.isEmpty { print("       \(d)") }
        }
    }

    /// Only for a check the environment makes meaningless (root reads mode
    /// 000). A missing fixture is a failure, never a skip: `fixture(_:)`.
    static func skip(_ name: String, _ reason: String) {
        print("skip - \(name): \(reason)")
    }

    /// Env override for where the checked-in self-test fixtures live (the
    /// checkout root). Unset: search upward from the binary, then from the
    /// working directory.
    static let fixtureRootEnv = "SENTRY_FIXTURE_ROOT"

    /// Path of a checked-in fixture (`relative` to the checkout root), or nil
    /// after recording a FAILED check that names it. Never a skip: a skip let
    /// a binary built outside `daemon/.build/` drop 111 checks and still print
    /// PASS.
    static func fixture(_ relative: String) -> String? {
        let env = ProcessInfo.processInfo.environment[fixtureRootEnv]
        let cwd = FileManager.default.currentDirectoryPath
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let starts: [(URL, String)] = env.map { [(URL(fileURLWithPath: $0), fixtureRootEnv)] }
            ?? [(exeDir, "walk-up from binary"), (URL(fileURLWithPath: cwd), "walk-up from cwd")]
        for (start, source) in starts {
            guard let found = locateFixture(relative, from: [start], walkUp: env == nil) else { continue }
            reportFixtureRoot(String(found.dropLast(relative.count + 1)), source: source)
            return found
        }
        check("fixture: \(relative)", false,
            "missing: expected \(relative) under \(env.map { "\(fixtureRootEnv)=\($0)" } ?? "an ancestor of \(exeDir.path) or of cwd \(cwd)"); "
                + "fix: run the binary from inside the checkout, or set \(fixtureRootEnv) to the checkout root")
        return nil
    }

    /// Prints each distinct fixture root once, so a run shows which checkout's
    /// fixtures it used (the cwd walk-up can land in another checkout).
    private static var reportedFixtureRoots: Set<String> = []
    private static func reportFixtureRoot(_ root: String, source: String) {
        guard reportedFixtureRoots.insert(root).inserted else { return }
        print("# fixture root: \(root) (source: \(source))")
    }

    /// First `start/relative` (or, with `walkUp`, `ancestor/relative`) that exists.
    static func locateFixture(_ relative: String, from starts: [URL], walkUp: Bool) -> String? {
        for start in starts {
            var dir = start.standardizedFileURL
            while true {
                let candidate = dir.appendingPathComponent(relative).path
                if FileManager.default.fileExists(atPath: candidate) { return candidate }
                let parent = dir.deletingLastPathComponent()
                if !walkUp || parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    /// Boundary: a missing fixture fails the run. A child `--ui-selftest`
    /// of the diagnostics group, pointed at an empty fixture root, must exit
    /// 1 and name the fixture.
    /// Tripwire on the child's run time: a hung child fails this check by name
    /// instead of hanging the whole `--ui-selftest`. MEASURED 2026-09-29 (M1 Mac,
    /// arm64, 10 runs of this child): 0.045–0.48 s, the slow one the first
    /// (cold) run; a later run measured 0.42 s. 30 s is ~60x the worst healthy run.
    static let missingFixtureChildLimitSecs = 30.0

    static func caseMissingFixtureFails(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        proc.arguments = ["--ui-selftest"]
        var env = ProcessInfo.processInfo.environment
        env["SENTRY_UI_SELFTEST_CASE"] = "diagnostics"
        env[fixtureRootEnv] = dir
        proc.environment = env
        // A file, not a pipe: reading a pipe to EOF would block on a hung child.
        let outPath = dir + "-child.out"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        proc.standardOutput = FileHandle(forWritingAtPath: outPath)
        proc.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do {
            let started = Date()
            try proc.run()
            let limit = missingFixtureChildLimitSecs
            guard exited.wait(timeout: .now() + limit) == .success else {
                proc.terminate()
                check("fixture: the missing-fixture child self-test exits within missingFixtureChildLimitSecs", false,
                    "limit \(limit) s, observed \(String(format: "%.3f", Date().timeIntervalSince(started))) s without exit; "
                        + "child sent SIGTERM; fix: UISelfTest.missingFixtureChildLimitSecs (remeasure before raising)")
                return
            }
            print("# missing-fixture child exited in \(String(format: "%.3f", Date().timeIntervalSince(started))) s (limit \(limit) s)")
            let text = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
            check("fixture: a missing fixture fails the self-test by name (exit 1, names path and \(fixtureRootEnv))",
                proc.terminationStatus == 1 && text.contains("not ok - fixture: daemon/testdata/diagnostics")
                    && text.contains("fix: ") && text.contains(fixtureRootEnv) && !text.contains("skip - "),
                "exit \(proc.terminationStatus): \(text.suffix(400))")
        } catch {
            check("fixture: the missing-fixture child self-test runs", false, "\(error)")
        }
    }

    static func run() -> Int32 {
        let base = NSTemporaryDirectory() + "sentry-selftest-\(getpid())"
        try? FileManager.default.removeItem(atPath: base)
        try! FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        setenv("SENTRY_STATE_DIR", base, 1)
        print("# state dir \(base)")
        defer { try? FileManager.default.removeItem(atPath: base) }

        // This focused group uses only test-owned files and handles. It avoids
        // UI/window tests when a change is limited to Logger I/O.
        if let selected = ProcessInfo.processInfo.environment["SENTRY_UI_SELFTEST_CASE"] {
            switch selected {
            case "logger": caseLoggerIO(base + "/logger")
            case "uninstall": caseUninstall(base + "/uninstall")
            case "diagnostics": caseDiagnostics(base + "/diagnostics"); caseDevOverrides(base + "/dev-overrides")
            case "fixtures": caseMissingFixtureFails(base + "/missing-fixture")
            case "tuning": caseTuningPolicy(base + "/tuning"); caseSteadiness()
            case "steadiness": caseSteadiness()
            case "zoom": caseZoomTiles(); caseZoomTilesView(base + "/zoom-view")
            case "devtab": caseDeveloperTab(base + "/devtab")
            case "daemon-followup": casePause(); caseDisplayTopology()
            case "active-covers": caseActiveCoversGauge(base + "/active-covers")
            case "native-menu-pause": caseNativeMenuPause()
            case "quick-look": caseQuickLookWindows()
            case "detection-view":
                caseDetectionView(base + "/detection-view")
            case "detection-trace":
                caseDetectionTrace(base + "/detection-trace")
            default:
                print("SELFTEST: unknown SENTRY_UI_SELFTEST_CASE=\(selected); "
                    + "supported=logger|uninstall|diagnostics|tuning|devtab|"
                    + "daemon-followup|active-covers|native-menu-pause|quick-look|detection-view|detection-trace|steadiness|fixtures")
                return 64
            }
            print("SELFTEST: \(passed)/\(passed + failed) PASS")
            return failed == 0 ? 0 : 1
        }

        caseLoggerIO(base + "/logger")
        caseHoldHeartbeat(base + "/hold-heartbeat")
        casePin()
        caseParentPINAuthority(base + "/authority")
        casePinGate(base + "/gate")
        caseStore(base + "/store")
        caseSettingsLock(base + "/settings-lock")
        caseCaptureStreamGenerationGate()
        caseToastQueue()
        casePause()
        caseLogTail(base + "/logtail")
        caseRegistryAndDriver(base + "/driver")
        casePINRecoveryBridge(base + "/recovery-bridge")
        caseCurtain()
        caseActiveCoversGauge(base + "/active-covers")
        caseQuickLookWindows()
        caseCurtainAttributionAtCapture()
        caseCurtainHandoffDirections()
        caseCurtainStripAndSuppression()
        caseCurtainExpansionCapRearm()
        caseCurtainStaticCadence()
        caseWindowServerRefusal()
        caseRegionEntryDebounce()
        caseTuningPolicy(base + "/tuning")
        caseSteadiness()
        caseZoomTiles()
        caseZoomTilesView(base + "/zoom-view")
        caseCoverageTripwire()
        caseCropWriter(base + "/crop-writer")
        caseAdmin()
        casePanicHold()
        casePanicGate()
        casePanicPauseUI(base + "/panic-pause")
        caseDevSignals()
        caseHotkeyStartup(base + "/alerts")
        caseCaptureAlertAndOverlayWindows(base + "/capture-alert")
        caseDeferredCaptureAlert()
        caseDisplayTopology()
        caseStatusToastGate()
        caseChildSessionAndRestoreGrace()
        caseProtectionHealth()
        caseDetectorDeadline()
        caseGlyph()
        caseBrandFoundation()
        caseSpotlight()
        caseHostArch()
        caseUninstall(base + "/uninstall")
        caseDiagnostics(base + "/diagnostics")
        caseMissingFixtureFails(base + "/missing-fixture")
        caseDevOverrides(base + "/dev-overrides")
        caseDriverFinish(base + "/driver-finish")
        caseAccessibility()
        caseDeveloperTab(base + "/devtab")
        caseDetectionTrace(base + "/detection-trace")
        caseDetectionView(base + "/detection-view")
        caseMainMenu()

        print("SELFTEST: \(passed)/\(passed + failed) PASS")
        return failed == 0 ? 0 : 1
    }

    // MARK: Logger I/O failures

    static func caseLoggerIO(_ dir: String) {
        let fm = FileManager.default
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func makeErrorHandle(_ name: String) -> FileHandle {
            let path = dir + "/" + name + ".stderr"
            fm.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)!
        }
        func warnings(_ name: String) -> String {
            (try? String(contentsOfFile: dir + "/" + name + ".stderr", encoding: .utf8)) ?? ""
        }
        func size(_ path: String) -> Int {
            ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? -1
        }
        func prefix(_ path: String, _ count: Int) -> Data {
            guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: count)) ?? Data()
        }
        func cleanFrame(_ logger: FrameLogger, _ frame: Int = 0) {
            logger.log(detections: [], regions: [], inferMs: 1, totalMs: 2, frame: frame)
        }

        let healthyPath = dir + "/healthy.jsonl"
        let healthyError = makeErrorHandle("healthy")
        defer { try? healthyError.close() }
        let healthy = FrameLogger(path: healthyPath, quiet: true, errorHandle: healthyError)
        cleanFrame(healthy, 0)
        cleanFrame(healthy, 1)
        // FileManager, never `Data(contentsOf:)` — same rule as CropWriter:
        // that loader also fetches http(s) URLs and the source egress Tripwire
        // bans it everywhere.
        let healthyBytes = fm.contents(atPath: healthyPath)!
        let lines = healthyBytes.split(separator: 10)
        let rows = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        check("logger: healthy writes retain both JSON records and one newline per record",
            rows.count == 2 && rows.compactMap { $0["frame"] as? Int } == [0, 1]
                && healthyBytes.last == 10 && healthyBytes.filter { $0 == 10 }.count == 2)
        check("logger: healthy file bytes match the complete written records",
            size(healthyPath) == lines.reduce(0) { $0 + $1.count + 1 }
                && rows.allSatisfy { $0["inferMs"] as? Double == 1 && $0["totalMs"] as? Double == 2 }
                && warnings("healthy").isEmpty)

        let failPath = dir + "/write-failure.jsonl"
        let failError = makeErrorHandle("write-failure")
        defer { try? failError.close() }
        var failOpens = 0
        let failing = FrameLogger(path: failPath, quiet: true, openLogFile: { path in
            failOpens += 1
            return FileHandle(forReadingAtPath: path)
        }, errorHandle: failError)
        cleanFrame(failing)
        cleanFrame(failing, 1)
        cleanFrame(failing, 2)
        let failWarning = warnings("write-failure")
        check("logger: actual read-only write failure survives and later writes stay disabled",
            size(failPath) == 0 && failOpens == 1)
        check("logger: one failed handle produces one warning with the path and repair location",
            failWarning.components(separatedBy: "WARNING: log write failed").count == 2
                && failWarning.contains(failPath) && failWarning.contains("FrameLogger.writeLocked"))

        let badErrorPath = dir + "/read-only.stderr"
        fm.createFile(atPath: badErrorPath, contents: nil)
        let badError = FileHandle(forReadingAtPath: badErrorPath)!
        defer { try? badError.close() }
        let badWarning = FrameLogger(path: dir + "/warning-failure.jsonl", quiet: true,
            openLogFile: { FileHandle(forReadingAtPath: $0) }, errorHandle: badError)
        cleanFrame(badWarning)
        cleanFrame(badWarning, 1)
        check("logger: a real stderr write failure also survives",
            size(badErrorPath) == 0 && size(dir + "/warning-failure.jsonl") == 0)

        // Cross the real production limit once per rotation case. One shared
        // harmless label provides the bytes; the limit is never lowered for a
        // test. No detector, model, capture stream, or window is started.
        let large = Detection(label: String(repeating: "x", count: FrameLogger.logFileCapBytes),
            confidence: 0.5, box: .zero)
        func crossLimit(_ logger: FrameLogger) {
            logger.log(detections: [large], regions: [], inferMs: 1, totalMs: 2)
        }

        let rotatePath = dir + "/rotate.jsonl"
        let rotateError = makeErrorHandle("rotate")
        defer { try? rotateError.close() }
        let rotating = FrameLogger(path: rotatePath, quiet: true, errorHandle: rotateError)
        cleanFrame(rotating)
        let retainedPrefix = prefix(rotatePath, size(rotatePath))
        crossLimit(rotating)
        cleanFrame(rotating, 1)
        // Idle tick tolerance (Logger.idleTickToleranceSecs): a 60 s timer
        // that lands a few ms before the window is 60 s old must still close
        // it, or the paused summary slips a whole minute (MEASURED test Mac
        // 2026-09-08). `now` is injected; the window opened at init.
        let idleT0 = CFAbsoluteTimeGetCurrent()
        let idle = FrameLogger(path: dir + "/idle.jsonl", quiet: true, mode: .lean, live: true)
        check("logger: idle tick 2 s early leaves the window open",
            idle.idleTick(state: "paused", now: idleT0 + 58) == false)
        check("logger: idle tick inside the tolerance closes the window as paused",
            idle.idleTick(state: "paused", now: idleT0 + 59.5) == true
                && (try? String(contentsOfFile: dir + "/idle.jsonl", encoding: .utf8))?
                    .contains("\"state\":\"paused\"") == true)
        check("logger: the next window is not due one second after it opened",
            idle.idleTick(state: "paused", now: idleT0 + 60.5) == false)

        check("logger: size rotation retains the previous records and writes a fresh log",
            size(rotatePath + ".1") > FrameLogger.logFileCapBytes
                && prefix(rotatePath + ".1", retainedPrefix.count) == retainedPrefix
                && size(rotatePath) > 0 && size(rotatePath) < FrameLogger.logFileCapBytes
                && warnings("rotate").contains("budget logFileCapBytes"))

        let recoverPath = dir + "/recover.jsonl"
        let recoverError = makeErrorHandle("recover")
        defer { try? recoverError.close() }
        var recoveryOpens = 0
        var restoredSize = 0
        let recovering = FrameLogger(path: recoverPath, quiet: true, openLogFile: { path in
            recoveryOpens += 1
            if recoveryOpens == 2 { return nil }
            if recoveryOpens == 3 { restoredSize = size(path) }
            return FileHandle(forWritingAtPath: path)
        }, errorHandle: recoverError)
        cleanFrame(recovering)
        let recoveryPrefix = prefix(recoverPath, size(recoverPath))
        crossLimit(recovering)
        cleanFrame(recovering, 1)
        check("logger: failed rotation reopen restores the file and appends after a successful seek",
            recoveryOpens == 3 && restoredSize > FrameLogger.logFileCapBytes
                && size(recoverPath) > restoredSize
                && prefix(recoverPath, recoveryPrefix.count) == recoveryPrefix
                && warnings("recover").contains("will grow past its budget"))

        let seekPath = dir + "/seek-failure.jsonl"
        let seekError = makeErrorHandle("seek-failure")
        defer { try? seekError.close() }
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        var seekOpens = 0
        let seekFailing = FrameLogger(path: seekPath, quiet: true, openLogFile: { path in
            seekOpens += 1
            if seekOpens == 2 { return nil }
            // A pipe is writable but cannot seek. The real seekToEnd call
            // throws, so a test can detect any subsequent writes to it.
            if seekOpens == 3 { return pipe.fileHandleForWriting }
            return FileHandle(forWritingAtPath: path)
        }, errorHandle: seekError)
        cleanFrame(seekFailing)
        let seekPrefix = prefix(seekPath, size(seekPath))
        crossLimit(seekFailing)
        let sizeAfterSeek = size(seekPath)
        cleanFrame(seekFailing, 1)
        check("logger: failed recovery seek stops writes and preserves the restored file",
            seekOpens == 3 && sizeAfterSeek > FrameLogger.logFileCapBytes
                && size(seekPath) == sizeAfterSeek
                && prefix(seekPath, seekPrefix.count) == seekPrefix)
        let seekWarning = warnings("seek-failure")
        check("logger: failed seek reports logging stopped once",
            seekWarning.contains("LOGGING HAS STOPPED (recovery seek failed:")
                && seekWarning.components(separatedBy: "WARNING:").count == 2)
        // The error path closes the writer. read then returns at EOF; if
        // a regression leaves it open, nonblocking mode keeps this test finite.
        let fd = pipe.fileHandleForReading.fileDescriptor
        let oldFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
        var byte: UInt8 = 0
        let received = read(fd, &byte, 1)
        check("logger: a failed seek closes the recovered handle without writing to it", received == 0)
        let receipt: [String: Any] = [
            "healthyBytes": healthyBytes.count,
            "healthySHA256": SHA256.hash(data: healthyBytes).map { String(format: "%02x", $0) }.joined(),
            "writeFailureWarning": failWarning,
            "stderrFailureBytes": size(badErrorPath),
            "rotatedBytes": size(rotatePath + ".1"),
            "retainedPrefixBytes": retainedPrefix.count,
            "retainedPrefixSHA256": SHA256.hash(data: retainedPrefix).map { String(format: "%02x", $0) }.joined(),
            "restoredBytesBeforeAppend": restoredSize,
            "restoredBytesAfterAppend": size(recoverPath),
            "seekFailureWarning": seekWarning,
            "seekFailurePipeRead": received,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8) {
            print("LOGGER_IO_RECEIPT: \(text)")
        }
    }

    // MARK: DEV crop writer

    /// HoldHeartbeat.swift: while protection is held in-process (no Pipeline,
    /// so no idle tick) the process itself must keep run.jsonl moving for
    /// packaging/watchdog.sh SUMMARY_STALE_SECS, and must stop the moment a
    /// Pipeline is rebuilt. Driven with a short interval on the real main
    /// run loop — the production cadence is the receipt, not the mechanism.
    static func caseHoldHeartbeat(_ dir: String) {
        let fm = FileManager.default
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/run.jsonl"
        let initial = HoldHeartbeat.pipelineFailed(existing: nil, path: path, quiet: true, mode: .full)
        let initialText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check("hold heartbeat: initial model failure creates a log and writes immediately",
            initial.isRunning && initialText.contains("pipeline-init-failed"))
        let retry = HoldHeartbeat.pipelineFailed(existing: initial, path: path, quiet: true, mode: .full)
        check("hold heartbeat: failed retries retain the logger and timer",
            retry === initial && retry.ticks == 1)
        initial.stop()
        let logger = FrameLogger(path: path, quiet: true)
        func records() -> [String] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
                .filter { $0.contains("\"event\":\"held\"") }
        }
        func mtime() -> Date {
            ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
        }
        check("hold heartbeat: cadence equals the idle tick (60 s) and sits 10x under SUMMARY_STALE_SECS (600 s)",
            HoldHeartbeat.intervalSecs == 60 && HoldHeartbeat.intervalSecs * 10 <= 600)

        let heartbeat = HoldHeartbeat(logger: logger, reason: "blocked(ended)")
        check("hold heartbeat: nothing written before start", records().isEmpty && !heartbeat.isRunning)
        heartbeat.start(interval: 0.05)
        let first = records()
        check("hold heartbeat: start writes the first record immediately with the reason",
            first.count == 1 && first[0].contains("reason=blocked(ended)") && first[0].contains("heartbeat=1"),
            "got \(first)")
        let before = mtime()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let running = records()
        check("hold heartbeat: keeps writing on the run loop while held",
            running.count >= 3 && heartbeat.ticks == running.count && heartbeat.isRunning,
            "records=\(running.count) ticks=\(heartbeat.ticks)")
        check("hold heartbeat: the file's mtime advances (what the watchdog reads)", mtime() >= before)
        // A rebuild whose Pipeline init FAILS (AppDelegate.startPipeline
        // catch: model load failed, runtime shows captureFailed) leaves the
        // process alive with no Pipeline — the heartbeat must keep going,
        // which is why startPipeline stops it only after init succeeds.
        // Modelled here as: the heartbeat object is untouched by a failed
        // rebuild and keeps writing on the run loop.
        let beforeFailedRebuild = records().count
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        check("hold heartbeat: survives a rebuild whose Pipeline init fails",
            heartbeat.isRunning && records().count > beforeFailedRebuild,
            "before \(beforeFailedRebuild), after \(records().count)")
        // A rebuild that SUCCEEDS (AppDelegate.startPipeline after init) stops it.
        heartbeat.stop()
        let atStop = records().count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("hold heartbeat: stops after a successful pipeline rebuild",
            !heartbeat.isRunning && records().count == atStop,
            "at stop \(atStop), after \(records().count)")
        heartbeat.start(interval: 0.05)
        heartbeat.stop()
        check("hold heartbeat: stop is idempotent and restart writes again", records().count == atStop + 1)
    }

    static func caseCropWriter(_ path: String) {
        var buffer: CVPixelBuffer?
        let rc = CVPixelBufferCreate(
            kCFAllocatorDefault, 100, 80, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard rc == kCVReturnSuccess, let buffer else {
            check("crop writer: synthetic BGRA buffer builds", false, "CVReturn=\(rc)")
            return
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * 80)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var events: [String] = []
        do {
            let writer = try CropWriter(directory: path) { events.append($0) }
            writer.submit(
                buffer,
                frameDetections: [
                    Detection(
                        label: "FEMALE_BREAST_EXPOSED", confidence: 0.75,
                        box: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.4)),
                    Detection(
                        label: "FACE_FEMALE", confidence: 0.9,
                        box: CGRect(x: 0.6, y: 0.5, width: 0.2, height: 0.3)),
                ],
                requests: [CropWriter.Request(
                    kind: .regionBirth,
                    detection: Detection(
                        label: "FEMALE_BREAST_EXPOSED", confidence: 0.75,
                        box: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.4)),
                    regionID: 7, windowID: nil)])
            writer.finish()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            check("crop writer: one event writes tight, context, and metadata",
                Set(files) == Set(["crops.jsonl", "tight-000001.jpg", "ctx-000001.jpg"]),
                "files=\(files)")
            let line = (try? String(contentsOfFile: path + "/crops.jsonl", encoding: .utf8)) ?? ""
            let row = line.split(separator: "\n").first.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            check("crop writer: metadata carries frame sequence and region id",
                row?["frame_seq"] as? Int == 1 && row?["kind"] as? String == "region_birth"
                    && row?["region_id"] as? Int == 7
                    && row?["frame_w"] as? Int == 100
                    && row?["frame_h"] as? Int == 80,
                "row=\(String(describing: row))")
            let frameDets = row?["frame_dets"] as? [[String: Any]]
            check("crop writer: metadata carries every frame detection",
                frameDets?.count == 2
                    && frameDets?.map { $0["label"] as? String } == [
                        "FEMALE_BREAST_EXPOSED", "FACE_FEMALE",
                    ], "frame_dets=\(String(describing: frameDets))")
            check("crop writer: healthy write fires no tripwire", events.isEmpty, "events=\(events)")

            var resumeEvents: [String] = []
            let resumed = try CropWriter(directory: path) { resumeEvents.append($0) }
            resumed.submit(
                buffer, frameDetections: [],
                requests: [CropWriter.Request(
                    kind: .regionBirth,
                    detection: Detection(
                        label: "FEMALE_BREAST_EXPOSED", confidence: 0.8,
                        box: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3)),
                    regionID: 8, windowID: nil)])
            resumed.finish()
            let resumedRows = ((try? String(
                contentsOfFile: path + "/crops.jsonl", encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
            check("crop writer: existing metadata resumes at the next crop and frame sequence",
                resumeEvents == ["resumed=true seq=2"] && resumedRows.count == 2
                    && resumedRows[1]["seq"] as? Int == 2
                    && resumedRows[1]["frame_seq"] as? Int == 2,
                "events=\(resumeEvents) rows=\(resumedRows)")

            let request = CropWriter.Request(
                kind: .regionBirth,
                detection: Detection(
                    label: "FEMALE_BREAST_EXPOSED", confidence: 0.75,
                    box: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.4)),
                regionID: 8, windowID: nil)
            var fileCapEvents: [String] = []
            let fileCap = try CropWriter(
                directory: path + "-file-cap", maxFiles: 1
            ) { fileCapEvents.append($0) }
            fileCap.submit(buffer, frameDetections: [], requests: [request])
            fileCap.finish()
            check("crop writer: file cap is a loud named tripwire",
                fileCapEvents.contains {
                    $0.contains("budget=CropWriter.maxFiles limit=1 observed=3 writing=stopped")
                }, "events=\(fileCapEvents)")

            var byteCapEvents: [String] = []
            let byteCap = try CropWriter(
                directory: path + "-byte-cap", maxBytes: 1
            ) { byteCapEvents.append($0) }
            byteCap.submit(buffer, frameDetections: [], requests: [request])
            byteCap.finish()
            check("crop writer: byte cap is a loud named tripwire",
                byteCapEvents.contains {
                    $0.contains("budget=CropWriter.maxBytes limit=1")
                        && $0.contains("writing=stopped")
                }, "events=\(byteCapEvents)")

            var queueCapEvents: [String] = []
            let queueCap = try CropWriter(
                directory: path + "-queue-cap", maxPendingJobs: 0
            ) { queueCapEvents.append($0) }
            queueCap.submit(buffer, frameDetections: [], requests: [request])
            queueCap.finish()
            check("crop writer: queue cap is a loud named tripwire",
                queueCapEvents.contains {
                    $0.contains("budget=CropWriter.maxPendingJobs limit=0 observed=1 writing=stopped")
                }, "events=\(queueCapEvents)")
        } catch {
            check("crop writer: synthetic write completes", false, "\(error)")
        }
    }

    // MARK: Host architecture (universal build, owner 2026-09-02)

    /// The universal binary ships exactly the slices in `packaging/release.env`'s
    /// `SENTRY_ARCHS`. This runs INSIDE whichever slice macOS chose, so running
    /// it under `arch -x86_64` is what proves the x86_64 slice agrees — the
    /// packaging tripwires can only see the file from outside.
    ///
    /// It deliberately does not assert WHICH slice: both are shipped, and the
    /// same suite has to pass natively and translated. What it refuses is a
    /// slice outside the contract and an unanswerable translation probe read as
    /// a fact.
    // MARK: 9e — A dead key can be replaced or removed from the popover (2026-09-10)

    static func caseHostArch() {
        check("host arch: compiled slice is one this package ships",
            shippedArchitectures.contains(HostArch.compiled),
            "compiled=\(HostArch.compiled) shipped=\(shippedArchitectures.joined(separator: ",")) "
                + "remediation=packaging/release.env SENTRY_ARCHS")
        check("host arch: HostArch.shipped matches packaging/release.env",
            HostArch.shipped == shippedArchitectures,
            "observed=\(HostArch.shipped.joined(separator: ",")) "
                + "configured=\(shippedArchitectures.joined(separator: ","))")
        check("host arch: translation probe is answered, not guessed",
            ["0", "1", "unknown"].contains(HostArch.translated),
            "translated=\(HostArch.translated)")
        check("host arch: a translated process is never labelled plain Intel",
            !HostArch.isTranslated || HostArch.description.contains("Rosetta"),
            "translated=\(HostArch.translated) description=\(HostArch.description)")
        check("host arch: the warning names its remediation",
            HostArch.translationWarning.contains("arch -arm64"),
            HostArch.translationWarning)
    }

    /// Mirrors `packaging/release.env`'s `SENTRY_ARCHS`. Duplicated here on
    /// purpose: the point of the check above is that the Swift side and the
    /// packaging side agree, and a check that read the same constant twice
    /// would prove nothing.
    private static let shippedArchitectures = ["arm64", "x86_64"]

    // MARK: 8c — Panic hotkey 1-s hold (SPEC §8.1(1), owner 2026-09-02)

    /// Drives `PanicHold` with a scripted clock and a hand-fired timer — no key
    /// events, no wall clock, so every timing below is exact. Asserts the
    /// owner's four cases (a 0.4-s tap cancels with no prompt; a full hold
    /// fires exactly once; a release at 0.9 s restarts the hold from zero; a
    /// key-repeat inside the hold neither restarts nor extends it), that a
    /// cancelled hold's timer is inert when it comes due, that every record is
    /// named `panic-hold` and never `panic` (the scenario tooling's INVALID
    /// rule), and that a fire feeds the existing gate, whose denied prompt
    /// still clears nothing.
    static func casePanicHold() {
        defer { PanicAuth.override = nil }
        var now: TimeInterval = 0
        var timers: [(due: TimeInterval, run: () -> Void)] = []
        var events: [(String, String)] = []
        var names: [String] = []
        var fires = 0
        let hold = PanicHold(
            log: { events.append(($0, $1)); names.append($0) },
            onFire: { fires += 1 },
            clock: { now },
            schedule: { delay, work in timers.append((due: now + delay, run: work)) })
        // The stand-in for asyncAfter: move the clock, run what has come due.
        func advance(to t: TimeInterval) {
            now = t
            let due = timers.filter { $0.due <= t }
            timers.removeAll { $0.due <= t }
            due.forEach { $0.run() }
        }
        func kinds() -> [String] { events.map { String($0.1.split(separator: ":")[0]) } }

        check("panic-hold: constant is the SPEC §8.1(1) 1 s", PanicHold.holdSecs == 1.0,
            "\(PanicHold.holdSecs)")

        // A: a tap — press, release at 0.4 s. No fire, not even when its timer comes due.
        hold.press()
        check("panic-hold: press ⇒ holding, one timer armed, start record",
            hold.isHolding && timers.count == 1 && kinds() == ["start"],
            "timers=\(timers.count) \(events)")
        advance(to: 0.4)
        hold.release()
        check("panic-hold: release at 0.4 s ⇒ cancel record, idle",
            !hold.isHolding && kinds() == ["start", "cancel"]
                && events[1].1.hasPrefix("cancel: released after 0.40 s")
                && events[1].1.contains("protection unchanged"),
            "\(events)")
        advance(to: 1.0)
        check("panic-hold: tap ⇒ the stale timer fires nothing",
            fires == 0 && events.count == 2 && timers.isEmpty, "fires=\(fires) \(events)")

        // B: a full hold fires exactly once, at holdSecs; the release after it is not an event.
        events.removeAll()
        hold.press()  // t = 1.0, due 2.0
        advance(to: 1.99)
        check("panic-hold: 0.99 s held ⇒ not yet", fires == 0 && hold.isHolding, "fires=\(fires)")
        advance(to: 2.0)
        check("panic-hold: held 1.0 s ⇒ fires exactly once",
            fires == 1 && !hold.isHolding && kinds() == ["start", "fire"]
                && events[1].1.hasPrefix("fire: held 1.00 s"),
            "fires=\(fires) \(events)")
        advance(to: 2.1)
        hold.release()
        check("panic-hold: release after the fire ⇒ no record, still idle",
            events.count == 2 && !hold.isHolding, "\(events)")

        // C: release at 0.9 s, press again — the hold restarts from zero.
        events.removeAll()
        advance(to: 3.0)
        hold.press()  // due 4.0
        advance(to: 3.9)
        hold.release()  // cancel after 0.90 s
        hold.press()  // due 4.9
        advance(to: 4.0)  // the cancelled hold's timer comes due
        check("panic-hold: press again after a 0.9-s release ⇒ old timer inert, still holding",
            fires == 1 && hold.isHolding && timers.count == 1,
            "fires=\(fires) timers=\(timers.count) \(events)")
        advance(to: 4.89)
        check("panic-hold: 0.99 s into the second hold ⇒ not yet", fires == 1, "fires=\(fires)")
        advance(to: 4.9)
        check("panic-hold: the second hold fires after its own full 1.0 s",
            fires == 2 && kinds() == ["start", "cancel", "start", "fire"]
                && events[1].1.contains("after 0.90 s") && events[3].1.hasPrefix("fire: held 1.00 s"),
            "fires=\(fires) \(events)")

        // D: a key-repeat inside the hold neither restarts nor extends it.
        events.removeAll()
        advance(to: 5.0)
        hold.press()  // due 6.0
        advance(to: 5.5)
        hold.press()  // auto-repeat
        check("panic-hold: repeat inside the hold ⇒ no new timer, no record, counted",
            timers.count == 1 && kinds() == ["start"] && hold.repeats == 1,
            "timers=\(timers.count) repeats=\(hold.repeats) \(events)")
        advance(to: 5.99)
        check("panic-hold: the repeat did not extend the hold ⇒ not yet at 0.99 s",
            fires == 2, "fires=\(fires)")
        advance(to: 6.0)
        check("panic-hold: fires at the ORIGINAL 1.0 s, repeat counted in the record",
            fires == 3 && events.last!.1.hasPrefix("fire: held 1.00 s (1 repeats)"),
            "fires=\(fires) \(events)")

        check("panic-hold: every record is panic-hold, none is panic",
            names.count == 10 && names.allSatisfy { $0 == "panic-hold" }, "\(names)")

        // E: a fire feeds the gate; a denied prompt (no administrator at the
        // keyboard, a degraded session) still clears nothing — the existing
        // PanicAuth path, unchanged.
        var gateEvents: [(String, String)] = []
        var panics = 0
        let gate = PanicGate(log: { gateEvents.append(($0, $1)) }, onGranted: { panics += 1 })
        let wired = PanicHold(
            log: { gateEvents.append(($0, $1)) },
            onFire: { gate.press() },
            clock: { now },
            schedule: { delay, work in timers.append((due: now + delay, run: work)) })
        PanicAuth.override = { done in DispatchQueue.main.async { done(.denied, "scripted") } }
        advance(to: 7.0)
        wired.press()
        advance(to: 8.0)
        check("panic-hold: fire ⇒ the gate asks for the administrator",
            gate.inFlight && gateEvents.map(\.0) == ["panic-hold", "panic-hold", "panic-auth"],
            "\(gateEvents)")
        spin(until: { !gate.inFlight })
        check("panic-hold: denied prompt after the hold ⇒ nothing cleared, protection unchanged",
            panics == 0 && gateEvents.last?.0 == "panic-auth"
                && gateEvents.last!.1.contains("denied") && gateEvents.last!.1.contains("protection unchanged"),
            "panics=\(panics) \(gateEvents)")
    }

    // MARK: 8d — Hotkey registration is never fatal (2026-09-02)

    /// Drives `HotkeyTable` (with a fake Carbon call), `HotkeyStartup.outcome`
    /// (pure) and `AlertsLog` (a temp path): a re-registration of a chord this
    /// process holds re-points the handler with no Carbon call (`.rebound`,
    /// the Pipeline-restart path that used to fail -9878 and before that exit
    /// 6); a Carbon failure surfaces its raw status; a failed panic
    /// registration yields a named `hotkey` record naming the chord and the
    /// status, the fact that protection keeps running, and what to do — plus
    /// an alerts.log message in the watchdog's line format; a failed inject
    /// registration yields a record but NO parent alert; the inject key is
    /// reported "not registered" when `--dev-inject` is absent; and an
    /// alerts.log the process cannot write is a returned failure, not a
    /// silent drop. Nothing here calls Carbon, so no hotkey is registered.
    static func caseHotkeyStartup(_ dir: String) {
        // HotkeyTable: idempotent per key code, status passed through.
        var table = HotkeyTable()
        var carbonCalls: [UInt32] = []
        var fired: [String] = []
        let first = table.bind(keyCode: 7, handlers: .init(press: { fired.append("a") }, release: nil)) {
            carbonCalls.append($0); return noErr
        }
        check("hotkey-table: fresh key code ⇒ .registered via one Carbon call (id 1)",
            first == .registered && carbonCalls == [1], "\(first) \(carbonCalls)")
        let again = table.bind(keyCode: 7, handlers: .init(press: { fired.append("b") }, release: nil)) {
            carbonCalls.append($0); return noErr
        }
        table.handlers[1]?.press()
        check("hotkey-table: same key code again ⇒ .rebound, no Carbon call, handler re-pointed",
            again == .rebound && carbonCalls == [1] && fired == ["b"], "\(again) \(carbonCalls) \(fired)")
        let dup = OSStatus(eventHotKeyExistsErr)
        let failed = table.bind(keyCode: 8, handlers: .init(press: {}, release: nil)) { _ in dup }
        check("hotkey-table: Carbon failure ⇒ .failed(status), no handler kept, id not consumed",
            failed == .failed(dup) && table.handlers.count == 1)
        let next = table.bind(keyCode: 9, handlers: .init(press: {}, release: nil)) {
            carbonCalls.append($0); return noErr
        }
        check("hotkey-table: next key code reuses the unconsumed id (2)",
            next == .registered && carbonCalls == [1, 2], "\(carbonCalls)")
        check("hotkey-registration: describe names -9878, leaves others bare",
            HotkeyRegistration.describe(dup) == "-9878 (eventHotKeyExistsErr)"
                && HotkeyRegistration.describe(-50) == "-50")

        let ok = HotkeyStartup.outcome(panic: .registered, inject: nil)
        check("hotkey-startup: healthy install ⇒ 2 records, no alert",
            ok.records.count == 2 && ok.alert == nil, "\(ok.records)")
        check("hotkey-startup: every record is a named hotkey event",
            ok.records.allSatisfy { $0.event == "hotkey" })
        check("hotkey-startup: inject reported not registered without --dev-inject",
            ok.records[1].info.contains("not registered") && ok.records[1].info.contains("--dev-inject"))
        let restarted = HotkeyStartup.outcome(panic: .rebound, inject: nil)
        check("hotkey-startup: pipeline restart ⇒ re-bound record, no alert",
            restarted.records[0].info.contains("re-bound") && restarted.alert == nil, "\(restarted.records)")
        let dev = HotkeyStartup.outcome(panic: .registered, inject: .registered)
        check("hotkey-startup: --dev-inject ⇒ inject registered, no alert",
            dev.records[1].info.contains("registered (--dev-inject)") && dev.alert == nil)
        let panicFailed = HotkeyStartup.outcome(panic: .failed(dup), inject: nil)
        check("hotkey-startup: panic failure ⇒ alert naming chord + status, keeps running, no guessed cause",
            panicFailed.alert.map {
                $0.contains(HotkeyCenter.panicKey.label) && $0.contains("REGISTRATION FAILED")
                    && $0.contains("status -9878 (eventHotKeyExistsErr)")
                    && $0.contains("protection keeps running") && !$0.contains("another app")
            } == true, "\(String(describing: panicFailed.alert))")
        check("hotkey-startup: panic failure record == alert text",
            panicFailed.records.first?.info == panicFailed.alert)
        let injectFailed = HotkeyStartup.outcome(panic: .registered, inject: .failed(-50))
        check("hotkey-startup: inject failure ⇒ record with status + SIGUSR1 fallback, no alert",
            injectFailed.alert == nil && injectFailed.records[1].info.contains("status -50")
                && injectFailed.records[1].info.contains("SIGUSR1"))

        // AlertsLog: the line format the watchdog and health_report.py parse.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/sub/alerts.log"
        check("alerts-log: append creates dir + file",
            AlertsLog.append(level: "ALERT", message: "selftest one", path: path) == nil)
        check("alerts-log: second append does not truncate",
            AlertsLog.append(level: "INFO", message: "selftest two", path: path) == nil)
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let stamp = try! NSRegularExpression(
            pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z (ALERT|INFO) sentry-screen\\[uid \\d+\\]: selftest (one|two)$")
        check("alerts-log: 2 lines in the watchdog's `TS LEVEL message` format",
            lines.count == 2 && lines.allSatisfy {
                stamp.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }, "\(lines)")
        check("alerts-log: resolvePath honours SENTRY_ALERTS_LOG",
            AlertsLog.resolvePath(logPath: nil, env: ["SENTRY_ALERTS_LOG": "/x/a.log"], home: "/h") == "/x/a.log")
        check("alerts-log: installed log root ⇒ alerts.log beside that uid's run.jsonl",
            AlertsLog.resolvePath(logPath: UIActivity.productionRoot + "/501/run.jsonl", env: [:], home: "/h")
                == UIActivity.productionRoot + "/501/alerts.log")
        check("alerts-log: dev run ⇒ watchdog dev path under HOME",
            AlertsLog.resolvePath(logPath: "/tmp/run.jsonl", env: [:], home: "/h")
                == "/h/Library/Logs/SentryScreen-dev/alerts.log")
        // A parent that is a regular FILE cannot become a directory for
        // anyone, root included — a portable stand-in for the root-owned
        // 0755 support directory an installed agent cannot write into.
        let blocker = dir + "/blocker"
        FileManager.default.createFile(atPath: blocker, contents: Data())
        let refused = AlertsLog.append(level: "ALERT", message: "x", path: blocker + "/alerts.log")
        check("alerts-log: unwritable path ⇒ named failure, not silence",
            refused?.contains(blocker) == true, "\(String(describing: refused))")
    }

    // MARK: 8e — Durable capture alert + click-through windows (2026-09-07)

    /// Drives the pure pieces of the durable
    /// capture-loss signal: which health transitions earn an `alerts.log`
    /// line (`CaptureAlert`), the file's own size budget and rotation
    /// (mirroring watchdog.sh's ALERTS_CAP), the popover's persistent
    /// capture row and its registry id, and SPEC §8's core safety property
    /// for every overlay window this app creates (`UIOverlayWindow`). No
    /// window is created here: both window rules are functions, and the four
    /// construction sites (Overlay.swift, FixSpotlight.swift, Banner.swift
    /// twice) read their answer from them.
    static func caseCaptureAlertAndOverlayWindows(_ dir: String) {
        let lost = CaptureHealth.lost(since: Date(), reason: "Screen Recording permission missing at launch")
        check("capture-alert: a healthy machine writes nothing",
            CaptureAlert.record(outageOpen: false, next: .protecting) == nil
                && CaptureAlert.record(outageOpen: false, next: .starting) == nil)
        let opened = CaptureAlert.record(outageOpen: false, next: lost)
        check("capture-alert: entering lost ⇒ one ALERT naming the reason and the way back",
            opened?.level == "ALERT" && opened?.outageOpen == true
                && opened?.message.contains("protection is NOT running") == true
                && opened?.message.contains("Screen Recording permission missing at launch") == true
                && opened?.message.contains("Open repair") == true,
            "\(String(describing: opened))")
        check("capture-alert: a second lost inside one outage writes nothing",
            CaptureAlert.record(outageOpen: true, next: lost) == nil
                && CaptureAlert.record(outageOpen: true,
                    next: .lost(since: Date(), reason: "capture stream lost")) == nil)
        check("capture-alert: the re-arm's .starting does not close the outage",
            CaptureAlert.record(outageOpen: true, next: .starting) == nil)
        let closed = CaptureAlert.record(outageOpen: true, next: .protecting)
        check("capture-alert: restore ⇒ one INFO and the outage closes",
            closed?.level == "INFO" && closed?.outageOpen == false
                && closed?.message.contains("capture restored") == true,
            "\(String(describing: closed))")

        // Across a relaunch (exit 7 / Quit & Reopen SIGKILL) the fresh
        // process must inherit an open outage from the file, or the restore
        // INFO is never written.
        let path = dir + "/alerts.log"
        check("capture-alert: no file ⇒ no open outage",
            !CaptureAlert.outageOpen(at: path))
        _ = AlertsLog.append(level: opened!.level, message: opened!.message, path: path)
        check("capture-alert: a relaunch after the ALERT inherits the open outage",
            CaptureAlert.outageOpen(at: path))
        _ = AlertsLog.append(level: "ALERT", message: "hotkey: Cmd+Opt+Ctrl+X could not be registered", path: path)
        check("capture-alert: an unrelated alert after it does not close the outage",
            CaptureAlert.outageOpen(at: path))
        _ = AlertsLog.append(level: closed!.level, message: closed!.message, path: path)
        check("capture-alert: after the restore INFO a relaunch starts closed",
            !CaptureAlert.outageOpen(at: path))
        _ = try? FileManager.default.removeItem(atPath: path)

        // Size budget: 5 MiB, one generation, the same shape and the same
        // loud budget line as watchdog.sh's half of alerts.log.
        check("alerts-log: cap matches the watchdog's ALERTS_CAP_BYTES (5 MiB)",
            AlertsLog.capBytes == 5 * 1024 * 1024)
        check("alerts-log: first line ⇒ no rotation, no generation, no budget noise",
            AlertsLog.append(level: "ALERT", message: "first", path: path) == nil
                && !FileManager.default.fileExists(atPath: path + ".1")
                && AlertsLog.rotateIfOverCap(path: path, cap: AlertsLog.capBytes) == nil)
        check("alerts-log: reaching the cap ⇒ rotate to .1 and keep appending",
            AlertsLog.append(level: "ALERT", message: "after", path: path, cap: 8) == nil
                && FileManager.default.fileExists(atPath: path + ".1"))
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        check("alerts-log: the fresh file opens with budget/limit/observed/fix, then the alert",
            lines.count == 2 && lines[0].contains(" INFO ") && lines[0].contains("budget AlertsLog.capBytes")
                && lines[0].contains("limit 8 B") && lines[0].contains("observed ")
                && lines[0].contains("fix: AlertsLog.capBytes") && lines[1].hasSuffix("after"),
            "\(lines)")
        check("alerts-log: one generation only — the rotated file holds the earlier line",
            ((try? String(contentsOfFile: path + ".1", encoding: .utf8)) ?? "").contains("first"))

        // The popover's persistent capture row.
        check("popover: capture row names Screen Recording when macOS says the grant is gone",
            UIPopoverView.captureRow(screenRecordingOff: true) == UIPopoverView.captureOffRow
                && UIPopoverView.captureOffRow.contains("Screen Recording is off")
                && UIPopoverView.captureOffRow.contains("protection is not running"))
        check("popover: another failure ⇒ the row does not blame a permission it cannot see",
            UIPopoverView.captureRow(screenRecordingOff: false) == UIPopoverView.captureLostRow
                && !UIPopoverView.captureLostRow.contains("Screen Recording"))
        var degradedState = DemoState()
        degradedState.health = .lost
        check("registry: the capture row is required while degraded, beside the way back",
            UIRegistry.requiredIDs(for: degradedState).isSuperset(of: ["ui.status.capture", "ui.status.fix"]))
        check("registry: a healthy machine has no capture row",
            !UIRegistry.requiredIDs(for: DemoState()).contains("ui.status.capture"))
        var demo = DemoState()
        check("demo: the screenrecording axis parses and is independent of health",
            demo.set("screenrecording", "off") == nil && demo.screenRecordingOff
                && demo.set("screenrecording", "on") == nil && !demo.screenRecordingOff
                && demo.set("screenrecording", "maybe") != nil)

        // Fullscreen Space transition (documented OS-level gap, 2026-09-09):
        // the loud line fires exactly on display-set changes.
        var ds = Set<UInt32>()
        let screen = CGSize(width: 1920, height: 1080)
        let windowed = CGRect(x: 234, y: 170, width: 1000, height: 664)
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        check("space-transition: a window-sized curtain appearing is not a transition",
            OverlayManager.spaceTransition(displaySized: &ds, id: 1, frame: windowed, screenSize: screen) == nil
                && ds.isEmpty)
        check("space-transition: becoming the display ⇒ enter, once",
            OverlayManager.spaceTransition(displaySized: &ds, id: 1, frame: display, screenSize: screen) == "enter"
                && OverlayManager.spaceTransition(displaySized: &ds, id: 1, frame: display, screenSize: screen) == nil
                && ds == [1])
        check("space-transition: shrinking back to a window ⇒ exit",
            OverlayManager.spaceTransition(displaySized: &ds, id: 1, frame: windowed, screenSize: screen) == "exit"
                && ds.isEmpty)
        check("space-transition: a display-sized id unlisting ⇒ exit (Chrome recreates the window id)",
            OverlayManager.spaceTransition(displaySized: &ds, id: 2, frame: display, screenSize: screen) == "enter"
                && OverlayManager.spaceTransition(displaySized: &ds, id: 2, frame: nil, screenSize: screen) == "exit"
                && OverlayManager.spaceTransition(displaySized: &ds, id: 2, frame: nil, screenSize: screen) == nil)

        // SPEC §8 core safety property, for every overlay window we create.
        check("overlay windows: no controls ⇒ click-through (covers, repair dim, informational toasts)",
            UIOverlayWindow.ignoresMouseEvents(hasControls: false))
        check("overlay windows: a window with a control is the one exception, by construction",
            !UIOverlayWindow.ignoresMouseEvents(hasControls: true))
        let card = NSRect(x: 100, y: 800, width: CaptureLossBanner.widthPt, height: CaptureLossBanner.heightPt)
        let screenTopY = card.maxY + CaptureLossBanner.topGapPt
        let interactive = UIOverlayWindow.toastFrame(card: card, screenTopY: screenTopY, hasControls: true)
        check("overlay windows: an interactive toast is exactly the card it draws (no invisible click strip)",
            interactive == card, "\(interactive) vs \(card)")
        let passive = UIOverlayWindow.toastFrame(card: card, screenTopY: screenTopY, hasControls: false)
        check("overlay windows: a click-through toast may keep the taller slide-in clip box",
            passive.minY == card.minY && passive.width == card.width
                && passive.maxY == screenTopY && passive.height > card.height,
            "\(passive)")
    }

    // MARK: Display topology change and the deferred capture ALERT

    /// A scripted geometry change — the thing neither a display hot-plug nor a
    /// sleep/wake can be asked for on a personal, in-use desktop. Drives the
    /// real decision path (`DisplayTopologyWatcher` with an injected reader and
    /// scheduler) and the real conversions, and asserts the capture stream's own
    /// display-change table.
    static func caseDisplayTopology() {
        let display1080 = DisplayGeometry(size: CGSize(width: 1920, height: 1080), origin: .zero)
        let bigger = DisplayGeometry(size: CGSize(width: 2560, height: 1440), origin: .zero)
        // An off-main display: the Sidecar/second-monitor case, where the
        // global origin is not (0,0) and the pre-`--display` maths was silently
        // wrong.
        let second = DisplayGeometry(
            size: CGSize(width: 1366, height: 946), origin: CGPoint(x: -1366, y: 0))

        var reads = display1080
        var inventory = DisplayInventory(
            displayCount: 1, namesByID: [7: "Built-in Retina Display"])
        var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
        var decisions: [DisplayChangeDecision] = []
        let watcher = DisplayTopologyWatcher(
            geometry: display1080,
            read: { reads },
            readInventory: { inventory },
            schedule: { delay, body in scheduled.append((delay, body)) },
            onDecision: { decisions.append($0) })

        // A hot-plug fires several notifications in a row: one decision, armed
        // at the budgeted coalescing window, covering all of them.
        reads = bigger
        for _ in 0..<4 { watcher.note() }
        check("display change: a burst of 4 notifications arms exactly ONE decision",
            scheduled.count == 1, "scheduled=\(scheduled.count)")
        check("display change: armed at the coalescing budget",
            scheduled.first?.delay == DisplayChangeGate.coalesceSecs,
            "delay=\(scheduled.first?.delay ?? -1) budget=\(DisplayChangeGate.coalesceSecs)")
        check("display change: nothing decided before the window elapses", decisions.isEmpty)
        scheduled.removeFirst().body()
        check("display change: the decision covers every notification in the burst",
            decisions.count == 1 && decisions.first?.coalesced == 4,
            "\(decisions.map(\.coalesced))")
        check("display change: the decision names both geometries",
            decisions.first?.changed == true && decisions.first?.from == display1080
                && decisions.first?.to == bigger)
        check("display change: the watcher adopted the new geometry",
            watcher.geometry == bigger)

        // The one log record, and what it has to carry.
        let info = decisions[0].logInfo(source: "didChangeScreenParameters") ?? ""
        check("display change: one capture record names old and new geometry and the rebuild",
            info.contains("state=display-changed") && info.contains("was=1920x1080@0,0")
                && info.contains("now=2560x1440@0,0") && info.contains("coalesced=4")
                && info.contains("rebuilding the capture stream"),
            info)

        // COVER GEOMETRY IS RECOMPUTED, NOT STALE. Same window frame, both
        // geometries: the normalized rect the curtain pipeline would publish
        // must follow the new display, and must be the right fraction of it.
        let window = CGRect(x: 480, y: 270, width: 960, height: 540)
        let stale = decisions[0].from.normalized(window)
        let fresh = decisions[0].to.normalized(window)
        check("cover geometry: the same window normalizes differently after the change",
            stale != fresh, "stale=\(stale) fresh=\(fresh)")
        check("cover geometry: the new rect is the right fraction of the NEW display",
            abs(fresh.width - 960.0 / 2560.0) < 1e-9
                && abs(fresh.height - 540.0 / 1440.0) < 1e-9,
            "fresh=\(fresh)")
        check("cover geometry: screenRect is the inverse of normalized on the new geometry",
            rectsClose(decisions[0].to.screenRect(fresh), window), // round trip
            "\(decisions[0].to.screenRect(fresh)) vs \(window)")
        check("cover geometry: an off-main display carries its global origin both ways",
            rectsClose(
                second.screenRect(second.normalized(CGRect(x: -1000, y: 100, width: 400, height: 300))),
                CGRect(x: -1000, y: 100, width: 400, height: 300)))

        // A notification that moves no geometry (menu bar, Dock, colour
        // profile) decides nothing: no reset, no stream rebuild, no log line.
        watcher.note()
        check("display change: a no-op notification still arms one decision", scheduled.count == 1)
        scheduled.removeFirst().body()
        check("display change: a notification that moves no geometry decides no change",
            decisions.count == 2 && decisions[1].changed == false
                && decisions[1].logInfo(source: "x") == nil)

        // connecting a second display can leave the selected
        // display's size, origin and id unchanged. The inventory still reaches
        // the decision, keeps the actual SCDisplay identity, and does not ask
        // for an unnecessary stream rebuild. Projecting this newer inventory
        // over `captured` also covers the race where the notification lands
        // before Capture.start publishes its first scope.
        let captured = DisplayScope(
            displayCount: 1, protectedDisplayID: 7,
            protectedName: "Built-in Retina Display")
        // Startup reads its seed only after the observer is active, then the
        // capture callback reconciles against a fresh inventory. If attach
        // lands in that interval without another notification, the fresh
        // count must win while Capture's SCDisplay identity stays authoritative.
        let startupSeed = DisplayInventory(
            displayCount: 1, namesByID: [7: "Built-in Retina Display"])
        let freshAtCapture = DisplayInventory(
            displayCount: 2,
            namesByID: [7: "Built-in Retina Display", 9: "Studio Display"])
        let startupScope = freshAtCapture.refreshing(captured)
        check("display inventory: capture callback uses a fresh post-observer inventory",
            startupSeed.displayCount == 1 && startupScope.displayCount == 2
                && startupScope.hasUnprotectedDisplays,
            "seed=\(startupSeed.displayCount) fresh=\(startupScope.displayCount)")
        check("display inventory: startup refresh preserves Capture's display identity",
            startupScope.protectedDisplayID == captured.protectedDisplayID
                && startupScope.protectedName == captured.protectedName
                && startupScope.protectedDisplayConnected,
            "scope=\(startupScope)")
        inventory = DisplayInventory(
            displayCount: 2,
            namesByID: [7: "Built-in Retina Display", 9: "Studio Display"])
        watcher.note()
        scheduled.removeFirst().body()
        let attached = decisions.last!
        let attachedScope = attached.inventory.refreshing(captured)
        check("display inventory: 1→2 refreshes scope when capture geometry is unchanged",
            !attached.changed && attachedScope.displayCount == 2
                && attachedScope.hasUnprotectedDisplays,
            "geometryChanged=\(attached.changed) displays=\(attachedScope.displayCount)")
        check("display inventory: refresh preserves the captured SCDisplay identity",
            attachedScope.protectedDisplayID == captured.protectedDisplayID
                && attachedScope.protectedName == captured.protectedName)

        // The captured display can disappear while another display remains.
        // Keep the capture identity for the repair path, but do not subtract a
        // disconnected protected display from the current inventory: the one
        // remaining display is uncovered and the warning must stay visible.
        let missingProtected = DisplayInventory(
            displayCount: 1, namesByID: [9: "Studio Display"]
        ).refreshing(DisplayScope(
            displayCount: 2, protectedDisplayID: 7,
            protectedName: "Built-in Retina Display"))
        check("display inventory: a missing captured display stays explicit",
            missingProtected.protectedDisplayID == 7
                && missingProtected.protectedName == "Built-in Retina Display"
                && !missingProtected.protectedDisplayConnected,
            "scope=\(missingProtected)")
        check("display inventory: every remaining display is reported uncovered",
            missingProtected.hasUnprotectedDisplays
                && missingProtected.unprotectedCount == 1,
            "displays=\(missingProtected.displayCount) "
                + "unprotected=\(missingProtected.unprotectedCount)")

        inventory = DisplayInventory(
            displayCount: 1, namesByID: [7: "Built-in Retina Display"])
        watcher.note()
        scheduled.removeFirst().body()
        let detached = decisions.last!
        let detachedScope = detached.inventory.refreshing(attachedScope)
        check("display inventory: 2→1 clears the warning without a geometry rebuild",
            !detached.changed && detachedScope == captured,
            "geometryChanged=\(detached.changed) scope=\(detachedScope)")

        // The gate re-opens after firing, so a second hot-plug is not swallowed.
        reads = second
        let beforeSecondChange = decisions.count
        watcher.note()
        check("display change: the gate re-opens for the next burst", scheduled.count == 1)
        scheduled.removeFirst().body()
        check("display change: the second change is seen, including a moved origin",
            decisions.count == beforeSecondChange + 1
                && decisions.last?.to == second && watcher.geometry == second)

        // A `--display` target that was unplugged: UNKNOWN, never a silent
        // fall-back to the main display. Every consumer guards on
        // `screenSize.width > 0`, so this degrades to no curtains.
        check("display change: a vanished display is unknown, not the main display",
            !DisplayGeometry.unknown.isValid && DisplayGeometry.unknown.size == .zero)

        // IDENTITY, not just shape: a main-display reassignment between two
        // displays of the SAME size keeps every conversion numerically right
        // while capture and the overlay end up on different physical displays.
        // It has to count as a change, and the record has to say which.
        let displayA = DisplayGeometry(size: display1080.size, origin: .zero, displayID: 1)
        let displayB = DisplayGeometry(size: display1080.size, origin: .zero, displayID: 2)
        check("display change: the same size on a DIFFERENT display is a change",
            displayA != displayB
                && DisplayChangeDecision(
                    from: displayA, to: displayB, inventory: inventory, coalesced: 1).changed,
            "\(displayA.logText) vs \(displayB.logText)")
        check("display change: the same display reported twice is not a change",
            !DisplayChangeDecision(
                from: displayA, to: displayA, inventory: inventory, coalesced: 1).changed)
        check("display change: the record names which display, not just its shape",
            displayA.logText.hasSuffix("#1") && displayB.logText.hasSuffix("#2"),
            displayA.logText)

        // shutdown() disarms a decision that is already coalescing: the owner
        // has printed its summary and latched `suppressed`, so a late decision
        // would reset state nobody reads and write one more record after the
        // close.
        reads = bigger
        let late = DisplayTopologyWatcher(
            geometry: display1080, read: { reads },
            readInventory: { inventory },
            schedule: { delay, body in scheduled.append((delay, body)) },
            onDecision: { decisions.append($0) })
        let decidedBefore = decisions.count
        late.note()
        late.stop()
        scheduled.removeFirst().body()
        check("display change: stop() disarms a decision that was already coalescing",
            decisions.count == decidedBefore && late.geometry == display1080,
            "decided=\(decisions.count - decidedBefore)")

        // The stream has to be rebuilt because its config width/height are
        // display-derived — but only when rebuilding can achieve anything.
        check("capture: a live unsuspended stream is rebuilt on a display change",
            CaptureStream.displayChangeAction(
                started: true, stopping: false, suspended: false, live: true) == .rebuild)
        check("capture: a suspended stream LATCHES the rebuild for the resume",
            CaptureStream.displayChangeAction(
                started: true, stopping: false, suspended: true, live: true) == .deferToResume
                && CaptureStream.displayChangeAction(
                    started: true, stopping: false, suspended: true, live: false)
                    == .deferToResume)
        // The latch is the whole point of deferring: a LOCK leaves the stream
        // LIVE (MEASURED 2026-08-21 attended lock/unlock run), and the resume
        // path only rebuilds a stream that is DOWN. Without the latch a
        // lock-then-hot-plug would keep a stream configured for the display that
        // is gone for the rest of the process's life.
        check("capture: the resume rebuilds a SURVIVING stream when a display change is latched",
            CaptureStream.resumeAction(live: true, displayChangePending: true) == .rearm)
        check("capture: the resume leaves a surviving stream alone with nothing latched",
            CaptureStream.resumeAction(live: true, displayChangePending: false)
                == .keepLiveStream)
        check("capture: the resume re-arms a stream that is down either way",
            CaptureStream.resumeAction(live: false, displayChangePending: false) == .rearm
                && CaptureStream.resumeAction(live: false, displayChangePending: true) == .rearm)
        check("capture: a chain already in flight builds the new geometry itself",
            CaptureStream.displayChangeAction(
                started: true, stopping: false, suspended: false, live: false)
                == .alreadyRebuilding)
        check("capture: a stream that never started, or is stopping, is ignored",
            CaptureStream.displayChangeAction(
                started: false, stopping: false, suspended: false, live: true) == .ignore
                && CaptureStream.displayChangeAction(
                    started: true, stopping: true, suspended: false, live: true) == .ignore)

        // Off-console capture (owner option B, 2026-09-25): the launch seed, the session
        // resign and an off-console display change share this one test.
        check("capture: an off-console session with a live display keeps capturing",
            CaptureStream.offConsoleDecision(liveDisplays: 1, assumeConsole: nil) == .protect
                && CaptureStream.offConsoleDecision(liveDisplays: 2, assumeConsole: "1")
                    == .protect)
        check("capture: an off-console session with no live display parks",
            CaptureStream.offConsoleDecision(liveDisplays: 0, assumeConsole: nil)
                == .parkNoDisplay)
        check("capture: SENTRY_ASSUME_CONSOLE=0 parks off console even with a live display",
            CaptureStream.offConsoleDecision(liveDisplays: 1, assumeConsole: "0")
                == .parkByOverride
                && CaptureStream.offConsoleDecision(liveDisplays: 0, assumeConsole: "0")
                    == .parkByOverride)

        // T1 (security review 2026-09-28): a lock signal suspends only when
        // the session confirms it; the boundary is the grace itself.
        let grace = CaptureStream.lockConfirmGraceSecs
        check("capture: a lock signal the session confirms suspends at once",
            CaptureStream.lockSignalDecision(sessionLocked: true, elapsed: 0) == .suspend
                && CaptureStream.lockSignalDecision(sessionLocked: true, elapsed: grace + 10) == .suspend)
        check("capture: an unconfirmed lock signal waits for the session inside the grace",
            CaptureStream.lockSignalDecision(sessionLocked: false, elapsed: 0) == .recheck
                && CaptureStream.lockSignalDecision(sessionLocked: false, elapsed: grace - 0.001) == .recheck
                && CaptureStream.lockSignalDecision(sessionLocked: nil, elapsed: grace - 0.001) == .recheck)
        check("capture: a lock signal the session never confirms is refused as tamper at the grace",
            CaptureStream.lockSignalDecision(sessionLocked: false, elapsed: grace) == .refuseUnconfirmed)
        check("capture: an unreadable session refuses the suspension without a tamper claim",
            CaptureStream.lockSignalDecision(sessionLocked: nil, elapsed: grace) == .refuseUnknown)
        check("capture: the confirmation grace fits in a handful of polls",
            grace / CaptureStream.lockConfirmPollSecs <= 8 && CaptureStream.lockRecheckSecs <= 5,
            "grace=\(grace) poll=\(CaptureStream.lockConfirmPollSecs) recheck=\(CaptureStream.lockRecheckSecs)")
    }

    private static func rectsClose(_ a: CGRect, _ b: CGRect, tol: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol
            && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    /// a slow wake must not manufacture a parent-visible ALERT, and a
    /// real loss must still alarm. Drives `CaptureAlert.durable`, which is the
    /// whole decision.
    static func caseDeferredCaptureAlert() {
        // The table below is driven with an explicit delay so the dev bypass
        // being set in this shell cannot change what is asserted; the wiring of
        // the constant itself is the separate check right after.
        let delay: TimeInterval = 30
        let lost = CaptureHealth.lost(since: Date(), reason: "the screen capture stream stopped")

        if let raw = ProcessInfo.processInfo.environment["SENTRY_CAPTURE_ALERT_DELAY_S"],
            !raw.isEmpty
        {
            // Reading the constant is what makes a malformed value refuse
            // itself by name on stderr, so the bypass is EXERCISED here rather
            // than skipped silently: a good value parses, a bad one falls back
            // to the receipt.
            let resolved = AppDelegate.captureAlertDelaySecs
            check("capture alert: the dev bypass parses, or refuses to the receipt",
                resolved >= 0
                    && (TimeInterval(raw) == resolved
                        || resolved == AppDelegate.captureLossRelaunchSecs),
                "raw=\(raw) resolved=\(resolved)")
        } else {
            check("capture alert: the ALERT delay is the exit-7 threshold, not a second number",
                AppDelegate.captureAlertDelaySecs == AppDelegate.captureLossRelaunchSecs
                    && AppDelegate.captureAlertDelaySecs == delay,
                "delay=\(AppDelegate.captureAlertDelaySecs) "
                    + "relaunch=\(AppDelegate.captureLossRelaunchSecs)")
        }

        // A loss HOLDS the ALERT and opens the outage.
        guard let first = CaptureAlert.durable(
            outageOpen: false, alertPending: false, next: lost, delay: delay) else {
            check("capture alert: a loss produces a durable step", false)
            return
        }
        check("capture alert: a loss holds the ALERT for the budgeted window",
            first.action == .hold(
                after: delay, level: "ALERT",
                message: CaptureAlert.record(outageOpen: false, next: lost)!.message)
                && first.outageOpen,
            "\(first)")

        // Nothing else in the outage writes anything.
        check("capture alert: a second loss inside the same outage writes nothing",
            CaptureAlert.durable(
                outageOpen: true, alertPending: true, next: lost, delay: delay) == nil)
        check("capture alert: the .starting a re-arm publishes writes nothing",
            CaptureAlert.durable(
                outageOpen: true, alertPending: true, next: .starting, delay: delay) == nil)

        // THE SLOW WAKE: restored while the ALERT is still held ⇒ alerts.log
        // never sees either edge.
        let transient = CaptureAlert.durable(
            outageOpen: true, alertPending: true, next: .protecting, delay: delay)
        check("capture alert: a restore inside the window drops the ALERT and writes nothing",
            transient?.action == .drop && transient?.outageOpen == false, "\(String(describing: transient))")

        // THE REAL LOSS: the ALERT was written, so the restore must answer it.
        let answered = CaptureAlert.durable(
            outageOpen: true, alertPending: false, next: .protecting, delay: delay)
        check("capture alert: a restore after the ALERT reached the file writes the INFO",
            answered?.action
                == .write(
                    level: "INFO", message: "capture restored — protection is running again")
                && answered?.outageOpen == false,
            "\(String(describing: answered))")

        // DEV BYPASS: delay 0 is the pre-deferral behaviour exactly.
        check("capture alert: SENTRY_CAPTURE_ALERT_DELAY_S=0 writes the ALERT immediately",
            CaptureAlert.durable(outageOpen: false, alertPending: false, next: lost, delay: 0)?
                .action
                == .write(
                    level: "ALERT",
                    message: CaptureAlert.record(outageOpen: false, next: lost)!.message))
    }

    // MARK: 8b — Panic hotkey authorization gate (SPEC §8.1(1), owner 2026-09-01)

    /// Drives `PanicGate` with `PanicAuth.override` standing in for the
    /// system prompt (a real prompt cannot be scripted). Asserts: a cancelled
    /// or denied or errored prompt clears nothing and logs a named
    /// `panic-auth` outcome; a granted prompt runs the panic path exactly
    /// once; a second hold while the prompt is open is ignored and logged; the
    /// override is cleared afterwards so the next case sees production wiring.
    static func casePanicGate() {
        defer { PanicAuth.override = nil }
        var events: [(String, String)] = []
        var panics = 0
        let gate = PanicGate(
            log: { events.append(($0, $1)) },
            onGranted: { panics += 1 })

        for outcome in [PanicAuth.Outcome.cancelled, .denied, .error] {
            events.removeAll()
            PanicAuth.override = { done in DispatchQueue.main.async { done(outcome, "scripted") } }
            gate.press()
            check("panic-gate: \(outcome.rawValue) ⇒ prompt in flight", gate.inFlight)
            spin(until: { !gate.inFlight })
            check("panic-gate: \(outcome.rawValue) ⇒ nothing cleared", panics == 0, "panics=\(panics)")
            check("panic-gate: \(outcome.rawValue) ⇒ named outcome logged",
                events.map(\.0) == ["panic-auth", "panic-auth"]
                    && events.last!.1.contains(outcome.rawValue)
                    && events.last!.1.contains("protection unchanged"),
                "\(events)")
        }

        // A second hold while the prompt is open: ignored, logged, and the
        // one open prompt still decides.
        events.removeAll()
        var pending: ((PanicAuth.Outcome, String) -> Void)?
        PanicAuth.override = { done in pending = done }
        gate.press()
        gate.press()
        check("panic-gate: repeat hold while open ⇒ ignored + logged",
            events.count == 2 && events[1].1.contains("already open"), "\(events)")
        pending?(.granted, "scripted")
        spin(until: { !gate.inFlight })
        check("panic-gate: granted ⇒ panic path runs once", panics == 1, "panics=\(panics)")
        check("panic-gate: granted ⇒ logged before the panic record",
            events.last?.0 == "panic-auth" && events.last!.1.contains("granted"), "\(events)")

        // Production wiring: no override ⇒ requestAdmin goes to the system
        // prompt. Not exercised here (it would block on a real dialog);
        // asserted by the override being nil after this case (the defer).
    }

    // MARK: 8c — Dev-only signal triggers (SPEC §8.1(8), DevSignals.swift)

    /// The gap this closes (CONFIRMED 2026-09-07): the agent runs as the
    /// session uid, so `kill -USR2 $(pgrep -x sentry-screen)` from a child's
    /// own Terminal ran `Pipeline.panic` — every cover cleared for 300 s,
    /// repeatably, with none of the authorization `casePanicGate` proves the
    /// hotkey demands. Asserts both directions of the arming rule, that an
    /// unarmed delivery runs NOTHING and still logs a named record, and that
    /// a flood is coalesced with its count rather than dropped.
    static func caseDevSignals() {
        check("dev-signals: --dev-inject arms them", DevSignals.armed(devInject: true))
        check("dev-signals: without --dev-inject they stay inert",
            !DevSignals.armed(devInject: false))

        // A production-shaped process: unarmed, so the panic path must not run.
        var events: [(String, String)] = []
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var panics = 0
        let refusals = DevSignalRefusals(now: { clock }, log: { events.append(($0, $1)) })
        DevSignals.deliver(DevSignals.panic, armed: false, refusals: refusals) { panics += 1 }
        check("dev-signals: inert build ⇒ SIGUSR2 clears nothing", panics == 0, "panics=\(panics)")
        check("dev-signals: inert build ⇒ one named panic refusal, first attempt logged at once",
            events.count == 1 && events[0].0 == "panic" && events[0].1.contains("REFUSED SIGUSR2")
                && events[0].1.contains("protection is unchanged")
                && events[0].1.contains(DevSignals.flag),
            "\(events)")

        // A flood inside the window: counted, not logged per delivery, and the
        // count is reported by the next record (budget named for the repair).
        for _ in 0..<5_000 {
            DevSignals.deliver(DevSignals.panic, armed: false, refusals: refusals) { panics += 1 }
        }
        check("dev-signals: a flood of 5000 signals writes no further record",
            events.count == 1, "records=\(events.count)")
        clock += DevSignalRefusals.refusalWindowSecs
        DevSignals.deliver(DevSignals.panic, armed: false, refusals: refusals) { panics += 1 }
        check("dev-signals: the next window reports the coalesced count by name",
            events.count == 2 && events[1].1.contains("observed 5000 further SIGUSR2")
                && events[1].1.contains("DEV_SIGNAL_REFUSAL_WINDOW")
                && events[1].1.contains("DevSignalRefusals.refusalWindowSecs"),
            "\(events)")
        check("dev-signals: nothing ran through the whole flood", panics == 0, "panics=\(panics)")

        // SIGUSR1 is refused under its own event name and its own window.
        DevSignals.deliver(DevSignals.inject, armed: false, refusals: refusals) {}
        check("dev-signals: SIGUSR1 refusal is a named inject record",
            events.count == 3 && events[2].0 == "inject"
                && events[2].1.contains("REFUSED SIGUSR1"), "\(events)")

        // A clean stop flushes the tail of a burst (main.swift SIGINT/SIGTERM).
        DevSignals.deliver(DevSignals.inject, armed: false, refusals: refusals) {}
        check("dev-signals: the tail of a burst is held, not written", events.count == 3,
            "records=\(events.count)")
        refusals.flush()
        check("dev-signals: a clean stop flushes the held count",
            events.count == 4 && events[3].0 == "inject"
                && events[3].1.contains("observed 1 further SIGUSR1"), "\(events)")
        refusals.flush()
        check("dev-signals: a second flush with nothing held writes nothing", events.count == 4,
            "records=\(events.count)")

        // A dev run: armed, runs the real path, logs no refusal.
        events.removeAll()
        var ran = 0
        DevSignals.deliver(DevSignals.panic, armed: true, refusals: refusals) { ran += 1 }
        DevSignals.deliver(DevSignals.inject, armed: true, refusals: refusals) { ran += 1 }
        check("dev-signals: armed ⇒ both triggers run their path, no refusal",
            ran == 2 && events.isEmpty, "ran=\(ran) \(events)")
    }

    static func casePINRecoveryBridge(_ dir: String) {
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let store = UISettingsStore(root: dir, log: { _, _ in })
        let actions = UIActions(store: store, log: { _, _ in })
        var recoveryRequests = 0
        actions.onForgotPIN = { recoveryRequests += 1 }
        actions.beginPINRecovery()
        check(
            "pin recovery: parent controls call the dedicated recovery bridge once",
            recoveryRequests == 1)
        var repairRequests = 0
        actions.onRepairProtection = { repairRequests += 1 }
        actions.beginProtectionRepair()
        check(
            "protection repair: degraded parent control calls the gated repair bridge once",
            repairRequests == 1)
    }

    // MARK: 1 — PIN

    static func casePin() {
        let t0 = Date()
        let rec = UIPin.make("4821")
        let t1 = Date()
        let ok = UIPin.verify("4821", rec)
        let verifySecs = Date().timeIntervalSince(t1)
        check("pin: derive/verify roundtrip", ok)
        check("pin: wrong PIN fails", !UIPin.verify("4822", rec))
        check("pin: record.rounds == 600_000", rec.rounds == 600_000, "rounds=\(rec.rounds)")
        check("pin: tampered record with rounds < minRounds is refused", {
            var weak = rec
            weak.rounds = UIPin.minRounds - 1
            weak.hash = UIPin.derive("4821", salt: weak.salt, rounds: weak.rounds)
            return !UIPin.verify("4821", weak)
        }())
        check("pin: salt is \(UIPin.saltBytes) bytes, hash \(UIPin.hashBytes)",
            rec.salt.count == UIPin.saltBytes && rec.hash.count == UIPin.hashBytes)
        check("pin: two make() calls differ in salt and hash",
            UIPin.make("4821").salt != rec.salt && UIPin.make("4821").hash != rec.hash)
        check("pin: length-mismatch compare is false",
            !UIPin.constantTimeEqual(rec.hash, rec.hash.dropLast()))
        check("pin: corrupted hash fails verify", {
            var bad = rec
            bad.hash[0] ^= 0x01
            return !UIPin.verify("4821", bad)
        }())
        let ms = Int(verifySecs * 1000)
        print("# pin: make \(Int(t1.timeIntervalSince(t0) * 1000)) ms, verify \(ms) ms")
        check("pin: verify takes >= \(Int(minVerifySecs * 1000)) ms (tripwire UISelfTest.minVerifySecs)",
            verifySecs >= minVerifySecs, "measured \(ms) ms")
        check("pin: format 4-8 digits only",
            UIPin.isValidFormat("1234") && UIPin.isValidFormat("12345678")
                && !UIPin.isValidFormat("123") && !UIPin.isValidFormat("123456789")
                && !UIPin.isValidFormat("12a4") && !UIPin.isValidFormat("１２３４"))
    }

    // MARK: 2 — PinGate

    static func caseParentPINAuthority(_ dir: String) {
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let store = UISettingsStore(root: dir, log: { _, _ in })
        let record = UIPin.make("4821")
        try! store.parentPINAuthority.mutate {
            $0.pin = record
            $0.failures = PinFailures(count: 2, lastAt: Date(), lockedUntil: nil)
        }

        let second = UISettingsStore(root: dir, log: { _, _ in })
        check("pin authority: second administrator view reads one credential and counter budget",
            UIPin.sameCredential(second.parentPIN, record)
                && second.parentPINFailures.count == 2)
        try! store.parentPINAuthority.mutate { $0.failures.count += 1 }
        try! second.parentPINAuthority.mutate { $0.failures.count += 1 }
        let third = UISettingsStore(root: dir, log: { _, _ in })
        check("pin authority: cross-administrator writes do not lose counter updates",
            third.parentPINFailures.count == 4,
            "count=\(third.parentPINFailures.count)")
        var externalNotifications = 0
        store.onChange = { _ in externalNotifications += 1 }
        try! third.parentPINAuthority.mutate { $0.failures.count += 1 }
        store.refresh()
        check("pin authority: external administrator change notifies after refresh",
            store.parentPINFailures.count == 5 && externalNotifications == 1,
            "count=\(store.parentPINFailures.count) notifications=\(externalNotifications)")

        let parentRoot = dir + "/" + ParentPINFileAuthority.directoryName
        let pinPath = parentRoot + "/" + ParentPINFileAuthority.fileName

        let lastKnownGood = third.parentPINAuthority.state
        let validStateData = try! lastKnownGood.encode()
        for (containerKey, dateKey) in [
            ("pin", "setAt"),
            ("failures", "lastAt"),
            ("failures", "lockedUntil"),
        ] {
            var object = try! JSONSerialization.jsonObject(with: validStateData)
                as! [String: Any]
            var container = object[containerKey] as! [String: Any]
            container[dateKey] = "not-an-ISO-8601-date"
            object[containerKey] = container
            let corruptData = try! JSONSerialization.data(withJSONObject: object)
            let (parsed, reason) = ParentPINState.parse(corruptData)
            check("pin authority: invalid non-null \(containerKey).\(dateKey) is rejected",
                parsed == nil && reason?.contains("\(containerKey).\(dateKey)") == true,
                "reason=\(reason ?? "none")")
        }

        var corruptObject = try! JSONSerialization.jsonObject(with: validStateData)
            as! [String: Any]
        var corruptFailures = corruptObject["failures"] as! [String: Any]
        corruptFailures["lockedUntil"] = "corrupt-lock-date"
        corruptObject["failures"] = corruptFailures
        let corruptStateData = try! JSONSerialization.data(withJSONObject: corruptObject)
        try! corruptStateData.write(to: URL(fileURLWithPath: pinPath))
        _ = third.parentPINAuthority.refresh()
        check("pin authority: corrupt lockedUntil is unreadable and retains last-known-good",
            third.parentPINAuthority.state == lastKnownGood
                && {
                    if case let .unreadable(detail) = third.parentPINAuthority.health {
                        return detail.contains("failures.lockedUntil")
                    }
                    return false
                }(),
            "health=\(third.parentPINAuthority.health)")
        try! validStateData.write(to: URL(fileURLWithPath: pinPath))
        _ = third.parentPINAuthority.refresh()

        var directoryInfo = stat()
        var fileInfo = stat()
        let directoryStat = lstat(parentRoot, &directoryInfo)
        let fileStat = lstat(pinPath, &fileInfo)
        check("pin authority: directory is setgid 2770 with the configured group",
            directoryStat == 0
                && (directoryInfo.st_mode & S_IFMT) == S_IFDIR
                && directoryInfo.st_gid == getegid()
                && (directoryInfo.st_mode & 0o7777) == 0o2770)
        check("pin authority: file is regular 0660 with no other-user permissions",
            fileStat == 0
                && (fileInfo.st_mode & S_IFMT) == S_IFREG
                && fileInfo.st_gid == getegid()
                && (fileInfo.st_mode & 0o7777) == 0o660)

        try! store.mutate { $0.showMenuBarIcon = false }
        let publicData = FileManager.default.contents(atPath: store.path) ?? Data()
        let publicObject = (try? JSONSerialization.jsonObject(with: publicData))
            as? [String: Any]
        check("pin authority: public settings contain no verifier or failure counters",
            publicObject?["version"] as? Int == UISettings.currentVersion
                && UISettings.currentVersion == 2
                && publicObject?["pin"] == nil
                && publicObject?["pinFailures"] == nil)

        chmod(pinPath, 0o664)
        let damaged = UISettingsStore(root: dir, log: { _, _ in })
        var permissionError: Error?
        do {
            try damaged.parentPINAuthority.mutate { $0.failures.count += 1 }
        } catch {
            permissionError = error
        }
        let detail = permissionError.map(String.init(describing:)) ?? ""
        check("pin authority: unsafe mode is refused with configured and observed values",
            permissionError is ParentPINAuthorityError
                && detail.contains("configured=")
                && detail.contains("observed=")
                && detail.contains("remediation="),
            detail)
        chmod(pinPath, ParentPINFileAuthority.fileMode)

        try! FileManager.default.removeItem(atPath: pinPath)
        let symlinkTarget = dir + "/must-not-change"
        let targetBytes = Data("protected target\n".utf8)
        try! targetBytes.write(to: URL(fileURLWithPath: symlinkTarget))
        symlink(symlinkTarget, pinPath)
        let unsafeType = UISettingsStore(root: dir, log: { _, _ in })
        var typeError: Error?
        do {
            try unsafeType.parentPINAuthority.mutate { $0.pin = UIPin.make("2468") }
        } catch {
            typeError = error
        }
        check("pin authority: symbolic-link file is refused and its target is unchanged",
            typeError is ParentPINAuthorityError
                && FileManager.default.contents(atPath: symlinkTarget) == targetBytes,
            "error=\(String(describing: typeError))")
    }

    // MARK: 3 — PinGate

    static func casePinGate(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var logs: [String] = []
        let log: (String, String) -> Void = { logs.append("\($0): \($1)") }
        let store = UISettingsStore(root: dir, log: log)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = PinGate(store: store, log: log, now: { clock })
        var observedPINChanges = 0
        var observedHasParentPIN = false
        store.onChange = { _ in
            observedPINChanges += 1
            observedHasParentPIN = store.parentPIN != nil
        }

        check("gate: no PIN set ⇒ .noPin", (try? gate.attempt("4821")) == .noPin)
        check("gate: setPin rejects 3 digits", (try? gate.setPin("123", current: nil)) == nil)
        try! gate.setPin("4821", current: nil)
        check("gate: direct setPin notifies the store with the new protected credential",
            observedPINChanges == 1 && observedHasParentPIN,
            "notifications=\(observedPINChanges) hasParentPIN=\(observedHasParentPIN)")
        check("gate: correct PIN ⇒ .ok", (try? gate.attempt("4821")) == .ok)
        var last: PinGate.Result?
        for _ in 1...PinGate.maxAttempts { last = try! gate.attempt("0000") }
        let lockUntil = clock.addingTimeInterval(PinGate.lockoutSecs)
        check("gate: \(PinGate.maxAttempts) failures ⇒ locked", last == .locked(until: lockUntil), "got \(String(describing: last))")
        check("gate: lock is persisted", store.parentPINFailures.lockedUntil == lockUntil
            && store.parentPINFailures.count == PinGate.maxAttempts)
        check("gate: while locked the correct PIN is refused",
            (try? gate.attempt("4821")) == .locked(until: lockUntil))
        check("gate: setPin while locked is refused (Refused(.locked))", {
            do { try gate.setPin("9999", current: "4821"); return false }
            catch let e as PinGate.Refused { return e.result == .locked(until: lockUntil) } catch { return false }
        }())
        check("gate: fail + locked log records", logs.filter { $0.hasPrefix("pin: fail count=") }.count == 5
            && logs.contains { $0.hasPrefix("pin: locked until=") }, "\(logs)")
        // the Change PIN sheet renders `Refused` verbatim, so no
        // refusal may name an internal enum case, and the lockout is worded
        // once (PinGate.lockoutMessage) for the prompt and the sheet alike.
        check("a refused PIN is a parent sentence, not an enum spelling", {
            let wrong = PinGate.Refused(result: .wrong(remaining: 2)).description
            let locked = PinGate.Refused(result: .locked(until: lockUntil)).description
            let one = PinGate.Refused(result: .wrong(remaining: 1)).description
            return wrong == "That’s not your current PIN. 2 tries left."
                && one.contains("1 try left.")
                && locked.hasPrefix("Too many tries. Try again in ")
                && [wrong, locked, one].allSatisfy {
                    !$0.contains("refused:") && !$0.contains("remaining") && !$0.contains("(")
                }
        }())
        check("one lockout wording for the prompt and the sheet",
            PinGate.lockoutMessage(until: Date(timeIntervalSince1970: 277),
                now: Date(timeIntervalSince1970: 0)) == "Too many tries. Try again in 4:37.")
        check("gate: counter survives a store reload",
            UISettingsStore(root: dir, log: log).parentPINFailures.count == PinGate.maxAttempts)
        clock = lockUntil.addingTimeInterval(1)
        check("gate: expiry unlocks (wrong PIN counts again from 1)",
            (try? gate.attempt("0000")) == .wrong(remaining: PinGate.maxAttempts - 1))
        check("gate: success resets the counter",
            (try? gate.attempt("4821")) == .ok && store.parentPINFailures == PinFailures())
        check("gate: setPin without current while a PIN is set is refused, not counted", {
            do { try gate.setPin("9999", current: nil); return false }
            catch is PinGate.CurrentRequired { return store.parentPINFailures.count == 0 } catch { return false }
        }())
        check("gate: setPin with a wrong current PIN is refused and counted", {
            do { try gate.setPin("9999", current: "0000"); return false }
            catch let e as PinGate.Refused {
                return e.result == .wrong(remaining: PinGate.maxAttempts - 1) && store.parentPINFailures.count == 1
            } catch { return false }
        }())
        let before = store.parentPIN
        try! gate.setPin("9999", current: "4821")
        check("gate: setPin with the current PIN replaces it and clears counters",
            store.parentPIN != before && store.parentPINFailures == PinFailures()
                && (try? gate.attempt("9999")) == .ok && (try? gate.attempt("4821")) == .wrong(remaining: PinGate.maxAttempts - 1))

        // completion variants: derive off-main, settle on main (landmine 11)
        var async: PinGate.Result?
        var asyncOnMain = false
        gate.attempt("9999") { r in asyncOnMain = Thread.isMainThread; async = try? r.get() }
        check("gate: async attempt has not settled synchronously", async == nil)
        spin(until: { async != nil })
        check("gate: async attempt ⇒ .ok on main, counter reset",
            async == .ok && asyncOnMain && store.parentPINFailures == PinFailures(), "got \(String(describing: async)) main=\(asyncOnMain)")
        var setDone = false
        var setErr: Error?
        gate.setPin("4821", current: "9999") { setErr = $0; setDone = true }
        spin(until: { setDone })
        check("gate: async setPin with current PIN replaces it",
            setDone && setErr == nil && (try? gate.attempt("4821")) == .ok, "err=\(String(describing: setErr))")
    }

    /// Completion tripwire. DERIVED: two derivations ≈ 0.2 s measured; 5 s is
    /// 25× that, so a hang fails the case instead of the whole selftest.
    static let asyncWaitSecs = 5.0

    static func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(asyncWaitSecs)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: 3 — UISettingsStore

    static func caseStore(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var logs: [String] = []
        let log: (String, String) -> Void = { logs.append("\($0): \($1)") }
        let missingDir = dir + "-missing"
        try! FileManager.default.createDirectory(
            atPath: missingDir, withIntermediateDirectories: true)
        let missing = UISettingsStore(root: missingDir, log: log)
        check("store: missing cold-start file remains explicit",
            missing.settings == .defaults && missing.fileHealth == .missing)
        let path = dir + "/settings.json"
        try! Data("{\"version\":1,\"futureKey\":{\"a\":[1,2]}}\n".utf8).write(to: URL(fileURLWithPath: path))
        let store = UISettingsStore(root: dir, log: log)
        let until = Date().addingTimeInterval(900)
        try! store.mutate { $0.pause = .timed(until: until, untilUptime: BootSession.uptime() + 900, by: "t", at: nil); $0.policyOverride = .strict }
        let unknownWarnings = logs.filter { $0.contains("unknown keys") }.count  // init load + mutate re-read: once
        let again = UISettingsStore(root: dir, log: log)
        check("store: write→read roundtrip",
            again.settings.policyOverride == .strict && again.settings.pause.effectiveUntil() != nil)
        let stray = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter {
            $0 != "settings.json" && $0 != ParentPINFileAuthority.directoryName
        } ?? []
        check("store: no stray temp file after write", stray.isEmpty, "found \(stray)")
        var st = stat()
        stat(path, &st)
        check("store: created file mode is 0664", st.st_mode & 0o777 == 0o664, String(format: "mode %o", st.st_mode & 0o777))
        check("store: unknown key preserved and logged once",
            again.settings.extra["futureKey"] == AnyHashableJSON(["a": [1, 2]])
                && unknownWarnings == 1, "warned \(unknownWarnings)x")

        let futureVersion = UISettings.currentVersion + 1
        try! Data("{\"version\":\(futureVersion),\"policyOverride\":\"strict\"}\n".utf8)
            .write(to: URL(fileURLWithPath: path))
        let future = UISettingsStore(root: dir, log: log)
        let writeSucceeded: Bool
        do {
            try future.mutate { $0.showMenuBarIcon = false }
            writeSucceeded = true
        } catch {
            writeSucceeded = false
        }
        check("store: future-version file applies known keys but is read-only",
            future.settings.policyOverride == .strict
                && !writeSucceeded
                && future.settings.showMenuBarIcon)

        try! Data("{\"version\":1,\"pause\":{\"mode\":\"timed\"".utf8).write(to: URL(fileURLWithPath: path))
        let corrupt = UISettingsStore(root: dir, log: log)
        check("store: corrupt JSON ⇒ defaults and NOT paused",
            corrupt.settings == .defaults && corrupt.settings.pause.effectiveUntil() == nil
                && logs.contains { $0.contains("DEGRADED read") })
        check("store: corrupt cold-start file remains explicit",
            { if case .unreadable = corrupt.fileHealth { true } else { false } }())

        let liveDir = dir + "-live-damage"
        try! FileManager.default.createDirectory(
            atPath: liveDir, withIntermediateDirectories: true)
        let livePath = liveDir + "/settings.json"
        try! Data("{\"version\":1}\n".utf8).write(
            to: URL(fileURLWithPath: livePath))
        let guarded = UISettingsStore(
            root: liveDir, requireReadableFileForWrites: true, log: log)
        let damagedBytes = Data("{\"version\":1,\"pause\":".utf8)
        try! damagedBytes.write(to: URL(fileURLWithPath: livePath))
        guarded.refresh()
        check("store: readable-to-corrupt transition remains explicit",
            { if case .unreadable = guarded.fileHealth { true } else { false } }())
        var damageWriteError: Error?
        do {
            try guarded.mutate { $0.showMenuBarIcon = false }
        } catch {
            damageWriteError = error
        }
        check("store: parent write cannot replace damaged production state",
            damageWriteError is UISettingsWriteError
                && FileManager.default.contents(atPath: livePath) == damagedBytes,
            "error=\(String(describing: damageWriteError))")

        let dev = UISettingsStore.resolveRoot(env: [:], productionRootExists: false)
        check("store: missing production root ⇒ dev fallback flagged",
            dev.devFallback && dev.root.hasSuffix("/Library/Application Support/SentryScreen/state")
                && dev.root != UISettingsStore.productionRoot)
        let prod = UISettingsStore.resolveRoot(env: [:], productionRootExists: true)
        check("store: production root wins when present", prod.root == UISettingsStore.productionRoot && !prod.devFallback)
        check("store: SENTRY_STATE_DIR wins", UISettingsStore.resolveRoot(env: ["SENTRY_STATE_DIR": "/x"]).root == "/x")
        check("devEnv: the knobs this selftest sets are honoured",
            DevEnv.environment["SENTRY_STATE_DIR"] != nil)
        check("devEnv: launchSummary names the ambient knob count",
            DevEnv.launchSummary.hasPrefix("devEnv=armed envKnobs="))
    }

    // MARK: 3c — settings.json advisory lock (2026-09-07)

    /// settings.json can have more than one read-modify-rename writer (two
    /// agent processes, or the agent and a dev tool); unserialized, the
    /// loser's keys are lost. Every writer flocks the STATE DIRECTORY. This case pins the three
    /// properties that makes load-bearing: the hold is far under the budget
    /// (the receipt for `lockWaitS`), a lock held by the other writer refuses
    /// the parent's write BY NAME instead of blocking the main thread, and the
    /// lock is the directory because every write renames a new inode over the
    /// file.
    static func caseSettingsLock(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/settings.json"
        try! Data("{\"version\":2}\n".utf8).write(to: URL(fileURLWithPath: path))
        let store = UISettingsStore(root: dir, log: { _, _ in })

        // Receipt for UISettingsStore.lockWaitS / Settings.lockWaitS: how long
        // one writer actually holds the lock.
        var worst = 0.0
        for i in 0..<100 {
            let started = Date()
            try! store.mutate { $0.showMenuBarIcon = i % 2 == 0 }
            worst = max(worst, Date().timeIntervalSince(started))
        }
        print(String(format: "# settings lock: 100 mutates, worst hold %.2f ms, budget %.0f s",
            worst * 1000, UISettingsStore.lockWaitS))
        // Tripwire beyond the measured healthy range: 500 ms is 15x the worst
        // hold seen on a cold run (34 ms) and 50x a warm one.
        check("settings lock: a mutate holds the directory lock far under the \(Int(UISettingsStore.lockWaitS)) s budget",
            worst < UISettingsStore.lockWaitS / 10, String(format: "worst %.2f ms", worst * 1000))

        // Contended. An flock belongs to the open file DESCRIPTION, so a second
        // descriptor here is a genuine second writer without a
        // second process.
        let held = open(dir, O_RDONLY)
        check("settings lock: the fixture holder took the directory lock",
            held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0)
        let before = FileManager.default.contents(atPath: path)
        var logs: [String] = []
        let contended = UISettingsStore(root: dir, lockWaitS: 1, log: { logs.append("\($0): \($1)") })
        let started = Date()
        var refusal: String?
        do { try contended.mutate { $0.policyOverride = .strict } } catch {
            refusal = (error as? UISettingsWriteError)?.reason
        }
        let waited = Date().timeIntervalSince(started)
        check("settings lock: a held lock refuses the write by name — budget, limit, observed, repair",
            refusal?.contains("budget settings lock wait, limit 1 s, observed ") == true
                && logs.contains { $0.contains("write refused: budget settings lock wait") },
            "refusal=\(refusal ?? "none")")
        check("settings lock: the refusal is bounded by the budget, not by the holder",
            waited >= 1 && waited < 3, String(format: "waited %.2f s", waited))
        check("settings lock: a refused write changes nothing on disk",
            FileManager.default.contents(atPath: path) == before)
        flock(held, LOCK_UN)
        close(held)
        var succeeded = false
        do {
            try contended.mutate { $0.policyOverride = .strict }
            succeeded = true
        } catch {}
        check("settings lock: the same write succeeds once the lock is released",
            succeeded && contended.settings.policyOverride == .strict)

        // Why the directory and not settings.json: the file is a new inode
        // after every write, so a lock on it would serialize nothing.
        var beforeStat = stat(), afterStat = stat()
        stat(path, &beforeStat)
        try! contended.mutate { $0.showMenuBarIcon = false }
        stat(path, &afterStat)
        check("settings lock: settings.json changes inode on every write, so the lock is the directory",
            beforeStat.st_ino != afterStat.st_ino)
    }

    // MARK: 4 — pause logic

    static func caseCaptureStreamGenerationGate() {
        let gate = CaptureStreamGenerationGate()
        let old = NSObject()
        let replacement = NSObject()
        gate.accept(old)
        let acceptedOld = gate.token(for: old)
        gate.invalidate()
        let rejectedStaleBeforeReplacement = gate.token(for: old) == nil
        gate.accept(replacement)
        let replacementToken = gate.token(for: replacement)
        check("capture: stale frame cannot satisfy a live replacement generation",
            acceptedOld != nil
                && rejectedStaleBeforeReplacement
                && !gate.isCurrent(acceptedOld!)
                && replacementToken != nil
                && gate.isCurrent(replacementToken!))
    }

    /// ToastQueue: one toast per id; a new title for the showing id is newer
    /// news and replaces it (2026-09-29: "Key added" then a
    /// refusal must not leave "Key added" up).
    static func caseToastQueue() {
        func spec(_ id: String, _ title: String, _ kind: ToastSpec.Kind = .notice) -> ToastSpec {
            ToastSpec(id: id, kind: kind, icon: .appIcon, title: title)
        }
        var q = ToastQueue()
        check("toast queue: an empty queue shows the first toast", q.offer(spec("license-activation", "Key added")))
        check("toast queue: the same id and title is the same toast (no replay)",
            !q.offer(spec("license-activation", "Key added")))
        check("toast queue: the same id with a new title replaces the showing toast",
            q.offer(spec("license-activation", "This link has expired")) && q.current?.title == "This link has expired")
        check("toast queue: another id waits its turn behind a notice of its own kind",
            !q.offer(spec("status-on", "Protection is on")) && q.waiting.map(\.id) == ["status-on"])
    }

    static func casePause() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let up = 1000.0
        check("pause: none ⇒ nil", PauseState.none.effectiveUntil(now: now, uptime: up, bootSession: "b") == nil)
        let timed = PauseState.timed(until: now.addingTimeInterval(600), untilUptime: up + 600, by: nil, at: nil)
        check("pause: timed in force", timed.effectiveUntil(now: now, uptime: up, bootSession: "b") == now.addingTimeInterval(600))
        check("pause: wall clock earlier wins",
            PauseState.timed(until: now.addingTimeInterval(60), untilUptime: up + 600, by: nil, at: nil)
                .effectiveUntil(now: now, uptime: up, bootSession: "b") == now.addingTimeInterval(60))
        check("pause: monotonic earlier wins (wall clock moved back)",
            PauseState.timed(until: now.addingTimeInterval(600), untilUptime: up + 60, by: nil, at: nil)
                .effectiveUntil(now: now, uptime: up, bootSession: "b") == now.addingTimeInterval(60))
        check("pause: past until never resurrects",
            timed.effectiveUntil(now: now.addingTimeInterval(601), uptime: up + 601, bootSession: "b") == nil
                && timed.effectiveUntil(now: now.addingTimeInterval(601), uptime: up, bootSession: "b") == nil)
        let restart = PauseState.untilRestart(bootSession: "boot-A", by: nil, at: nil)
        check("pause: untilRestart live on same boot", restart.effectiveUntil(now: now, uptime: up, bootSession: "boot-A") == .distantFuture)
        check("pause: changed bootSession ends untilRestart", restart.effectiveUntil(now: now, uptime: up, bootSession: "boot-B") == nil)
        check("pause: missing bootSession ends untilRestart (fail toward protection)",
            restart.effectiveUntil(now: now, uptime: up, bootSession: nil) == nil)
        let a = now.addingTimeInterval(300), b = now.addingTimeInterval(3600)
        check("pause: compose = max(panic, settings)",
            PauseState.compose(panic: a, settings: b) == b && PauseState.compose(panic: b, settings: a) == b
                && PauseState.compose(panic: nil, settings: a) == a && PauseState.compose(panic: a, settings: nil) == a
                && PauseState.compose(panic: nil, settings: nil) == nil)

        // Resume is a two-queue transition. The UI must stay Starting while
        // the detector queue is held, and only become Protected after the
        // behavior operation reaches its main-thread acknowledgement.
        let acknowledgedUI = UIState(
            settings: .defaults, devStateRoot: false, isAdmin: true)
        acknowledgedUI.captureHealth = .protecting
        var behaviorJobs: [() -> Void] = []
        var mainJobs: [() -> Void] = []
        var behaviorApplies = 0
        var acknowledgements = 0
        var pendingChanges: [Bool] = []
        let acknowledger = PauseResumeAcknowledger(
            enqueueBehavior: { behaviorJobs.append($0) },
            enqueueMain: { mainJobs.append($0) },
            canAcknowledge: { true },
            onPendingChange: {
                pendingChanges.append($0)
                acknowledgedUI.pauseResumePending = $0
            })
        acknowledger.requestResume(
            applyBehavior: { behaviorApplies += 1 },
            onAcknowledged: { acknowledgements += 1 })
        check("pause acknowledgement: held injected behavior keeps the UI Starting",
            acknowledger.isPending && behaviorJobs.count == 1
                && acknowledgedUI.headerText == "Starting…"
                && acknowledgedUI.glyph == .starting,
            "pending=\(acknowledger.isPending) jobs=\(behaviorJobs.count) "
                + "header=\(acknowledgedUI.headerText) glyph=\(acknowledgedUI.glyph)")
        behaviorJobs.removeFirst()()
        check("pause acknowledgement: behavior alone cannot publish Protected",
            behaviorApplies == 1 && acknowledgements == 0
                && acknowledger.isPending && mainJobs.count == 1
                && acknowledgedUI.headerText == "Starting…",
            "behavior=\(behaviorApplies) acknowledgements=\(acknowledgements) "
                + "pending=\(acknowledger.isPending) mainJobs=\(mainJobs.count)")
        mainJobs.removeFirst()()
        check("pause acknowledgement: main acknowledgement publishes Protected once",
            behaviorApplies == 1 && acknowledgements == 1
                && !acknowledger.isPending && pendingChanges == [true, false]
                && acknowledgedUI.headerText == "Protected"
                && acknowledgedUI.glyph == .protecting,
            "behavior=\(behaviorApplies) acknowledgements=\(acknowledgements) "
                + "pendingChanges=\(pendingChanges) header=\(acknowledgedUI.headerText)")

        // Pending resume only downgrades an otherwise healthy verdict. It must
        // not hide either failure behind the less specific Starting state.
        let pendingCaptureLoss = UIState(
            settings: .defaults, devStateRoot: false, isAdmin: true)
        pendingCaptureLoss.captureHealth = .lost(
            since: now, reason: "capture stream lost")
        pendingCaptureLoss.pauseResumePending = true
        let pendingDetectorFailure = UIState(
            settings: .defaults, devStateRoot: false, isAdmin: true)
        pendingDetectorFailure.captureHealth = .protecting
        pendingDetectorFailure.detectorHealth = .failing(since: now)
        pendingDetectorFailure.pauseResumePending = true
        let captureLossPreserved: Bool
        if case .captureLost = pendingCaptureLoss.protection {
            captureLossPreserved = true
        } else {
            captureLossPreserved = false
        }
        check("pause acknowledgement: pending resume preserves capture loss",
            captureLossPreserved
                && pendingCaptureLoss.headerText == "Protection is off"
                && pendingCaptureLoss.glyph == .degraded,
            "protection=\(pendingCaptureLoss.protection) "
                + "header=\(pendingCaptureLoss.headerText)")
        check("pause acknowledgement: pending resume preserves detector failure",
            pendingDetectorFailure.protection.detectorIsFailing
                && pendingDetectorFailure.headerText == ProtectionCopy.detectorHeader
                && pendingDetectorFailure.glyph == .degraded,
            "protection=\(pendingDetectorFailure.protection) "
                + "header=\(pendingDetectorFailure.headerText)")

        // A current generation may still fail its production predicate. Keep
        // it pending until another state transition explicitly cancels it.
        var refusedBehaviorJobs: [() -> Void] = []
        var refusedMainJobs: [() -> Void] = []
        var refusedAcknowledgements = 0
        var refusedPending: [Bool] = []
        let refusedAcknowledger = PauseResumeAcknowledger(
            enqueueBehavior: { refusedBehaviorJobs.append($0) },
            enqueueMain: { refusedMainJobs.append($0) },
            canAcknowledge: { false },
            onPendingChange: { refusedPending.append($0) })
        refusedAcknowledger.requestResume(
            applyBehavior: {}, onAcknowledged: { refusedAcknowledgements += 1 })
        refusedBehaviorJobs.removeFirst()()
        refusedMainJobs.removeFirst()()
        check("pause acknowledgement: a false current-state predicate refuses acknowledgement",
            refusedAcknowledgements == 0 && refusedAcknowledger.isPending
                && refusedPending == [true],
            "acknowledgements=\(refusedAcknowledgements) pending=\(refusedPending)")
        refusedAcknowledger.cancelPendingResume()

        // A pause that arrives after behavior resume was queued invalidates
        // its main acknowledgement. The stale completion must not publish a
        // healthy state over the newer pause.
        var staleBehaviorJobs: [() -> Void] = []
        var staleMainJobs: [() -> Void] = []
        var staleAcknowledgements = 0
        var stalePending: [Bool] = []
        let staleUI = UIState(settings: .defaults, devStateRoot: false, isAdmin: true)
        staleUI.captureHealth = .protecting
        let staleAcknowledger = PauseResumeAcknowledger(
            enqueueBehavior: { staleBehaviorJobs.append($0) },
            enqueueMain: { staleMainJobs.append($0) },
            canAcknowledge: { true },
            onPendingChange: {
                stalePending.append($0)
                staleUI.pauseResumePending = $0
            })
        staleAcknowledger.requestResume(
            applyBehavior: {}, onAcknowledged: { staleAcknowledgements += 1 })
        staleBehaviorJobs.removeFirst()()
        var repaused = staleUI.settings
        let repauseNow = Date()
        repaused.pause = .timed(
            until: repauseNow.addingTimeInterval(600),
            untilUptime: BootSession.uptime() + 600,
            by: "selftest", at: repauseNow)
        staleUI.settings = repaused
        staleAcknowledger.cancelPendingResume()
        staleMainJobs.removeFirst()()
        check("pause acknowledgement: rapid re-pause rejects a stale resume",
            staleAcknowledgements == 0 && !staleAcknowledger.isPending
                && stalePending == [true, false]
                && staleUI.pauseUntil != nil
                && staleUI.headerText == "Paused"
                && staleUI.glyph == .paused,
            "acknowledgements=\(staleAcknowledgements) pending=\(stalePending) "
                + "header=\(staleUI.headerText) glyph=\(staleUI.glyph)")

        // A timed pause that EXPIRES has no settings write behind it, so
        // UIState must republish on the 1 Hz tick or the menu bar and an open
        // popover keep claiming "paused" after the pipeline resumed.
        var s = UISettings.defaults
        s.pause = .timed(
            until: Date().addingTimeInterval(0.2), untilUptime: BootSession.uptime() + 0.2,
            by: "t", at: Date())
        let live = UIState(settings: s, devStateRoot: false, isAdmin: true)
        var publishes = 0
        let sub = live.objectWillChange.sink { _ in publishes += 1 }
        live.republishIfPauseChanged()
        check("pause: no republish while the pause is live", publishes == 0, "publishes=\(publishes)")
        Thread.sleep(forTimeInterval: 0.35)
        check("pause: deadline has passed", live.pauseUntil == nil)
        live.republishIfPauseChanged()
        check("pause: expiry republishes exactly once", publishes == 1, "publishes=\(publishes)")
        live.republishIfPauseChanged()
        check("pause: an expired pause does not republish every tick", publishes == 1,
            "publishes=\(publishes)")
        sub.cancel()

        // A pause SHORTER than one tick: entering it publishes (the settings
        // write) and it expires before the first tick, so the flip is only
        // seen if the write recorded what it published (UIState.settings
        // didSet). Not reachable from the ≥15m presets, but it is reachable
        // from `state paused until:+0.5` in the demo harness.
        var short = UISettings.defaults
        let brief = UIState(settings: short, devStateRoot: false, isAdmin: true)
        var briefPublishes = 0
        let briefSub = brief.objectWillChange.sink { _ in briefPublishes += 1 }
        short.pause = .timed(
            until: Date().addingTimeInterval(0.1), untilUptime: BootSession.uptime() + 0.1,
            by: "t", at: Date())
        brief.settings = short
        Thread.sleep(forTimeInterval: 0.25)
        brief.republishIfPauseChanged()
        check("pause: a pause shorter than one tick still repaints on expiry",
            briefPublishes >= 2, "publishes=\(briefPublishes)")
        briefSub.cancel()

        // Regression for the native menu-tracking failure. Both timers are due
        // now. The production pause factory is installed in common modes and
        // must fire while the run loop is explicitly in eventTracking; the
        // default-mode control models the old Timer.scheduledTimer path and
        // must remain starved. The run-loop deadline reuses the production
        // one-second cadence, so this test adds no independent wait budget.
        // `--ui-selftest` runs before NSApplication registers AppKit's common
        // modes. Add the same event-tracking membership explicitly so this
        // headless test exercises the production factory without opening UI.
        CFRunLoopAddCommonMode(
            CFRunLoopGetMain(),
            CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        var pauseTickFired = false
        var oldDefaultTickFired = false
        let pauseTimer = Pipeline.schedulePauseTimer { pauseTickFired = true }
        let defaultTimer = Timer(timeInterval: Pipeline.pauseTickSecs, repeats: true) { _ in
            oldDefaultTickFired = true
        }
        RunLoop.main.add(defaultTimer, forMode: .default)
        pauseTimer.fireDate = .distantPast
        defaultTimer.fireDate = .distantPast
        let trackingDeadline = Date().addingTimeInterval(Pipeline.pauseTickSecs)
        var trackingHandledTimer = false
        while !pauseTickFired && Date() < trackingDeadline {
            trackingHandledTimer = RunLoop.main.run(
                mode: .eventTracking, before: trackingDeadline) || trackingHandledTimer
        }
        pauseTimer.invalidate()
        defaultTimer.invalidate()
        check("pause: production expiry timer fires during menu tracking",
            pauseTickFired && !oldDefaultTickFired,
            "handled=\(trackingHandledTimer) common=\(pauseTickFired) default=\(oldDefaultTickFired)")
    }

    /// Explicit-only WindowServer check. The default selftest keeps its
    /// headless run-loop check above; this case opens a real NSMenu and is run
    /// only on an idle test desktop.
    static func caseNativeMenuPause() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 180, height: 90),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "SentryScreen timer test"
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // The private pause expires halfway through the production cadence,
        // so the first 1 Hz tick must observe it as expired. The menu escape is
        // three cadences: beyond the expected first tick, but short enough to
        // fail this focused check clearly if the timer is starved.
        let expirySecs = Pipeline.pauseTickSecs / 2
        let escapeSecs = Pipeline.pauseTickSecs * 3
        let now = Date()
        var settings = UISettings.defaults
        settings.pause = .timed(
            until: now.addingTimeInterval(expirySecs),
            untilUptime: BootSession.uptime() + expirySecs,
            by: "selftest", at: now)
        let state = UIState(settings: settings, devStateRoot: false, isAdmin: true)
        state.captureHealth = .protecting
        var publishes = 0
        let subscription = state.objectWillChange.sink { publishes += 1 }

        let menu = NSMenu(title: "Pause timer tracking")
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Tracking", action: nil, keyEquivalent: "")
        item.isEnabled = true
        menu.addItem(item)
        let delegate = NativeMenuSelfTestDelegate()
        menu.delegate = delegate

        var productionCallbacks = 0
        var defaultCallbacks = 0
        var productionMode: RunLoop.Mode?
        let behaviorQueue = DispatchQueue(label: "ui-selftest.native-menu-pause")
        let behaviorGate = DispatchSemaphore(value: 0)
        behaviorQueue.async { behaviorGate.wait() }
        var behaviorReleased = false
        var behaviorApplies = 0
        var acknowledgements = 0
        var acknowledgementMode: RunLoop.Mode?
        var pendingObservedDuringTracking = false
        var escapeFired = false
        let acknowledger = PauseResumeAcknowledger(
            enqueueBehavior: { body in behaviorQueue.async { body() } },
            enqueueMain: { body in DispatchQueue.main.async { body() } },
            canAcknowledge: { true },
            onPendingChange: { state.pauseResumePending = $0 })
        let productionTimer = Pipeline.schedulePauseTimer {
            productionCallbacks += 1
            productionMode = RunLoop.current.currentMode
            if state.pauseUntil == nil && !acknowledger.isPending
                && acknowledgements == 0
            {
                acknowledger.requestResume(
                    applyBehavior: { behaviorApplies += 1 },
                    onAcknowledged: {
                        acknowledgements += 1
                        acknowledgementMode = RunLoop.current.currentMode
                        menu.cancelTracking()
                    })
            }
            state.republishIfPauseChanged()
        }
        let defaultTimer = Timer(timeInterval: Pipeline.pauseTickSecs, repeats: true) { _ in
            defaultCallbacks += 1
        }
        RunLoop.main.add(defaultTimer, forMode: .default)
        // Hold the real serial behavior queue across expiry. At one and a half
        // cadences the production tick is due, but its acknowledgement must
        // still be pending and every parent-facing projection must stay
        // Starting. Releasing the queue then dispatches the acknowledgement to
        // the real main queue while NSMenu is still tracking.
        let releaseTimer = Timer(
            timeInterval: Pipeline.pauseTickSecs * 1.5, repeats: false
        ) { _ in
            pendingObservedDuringTracking = acknowledger.isPending
                && state.headerText == "Starting…"
                && state.glyph == .starting
                && RunLoop.current.currentMode == .eventTracking
            behaviorReleased = true
            behaviorGate.signal()
        }
        RunLoop.main.add(releaseTimer, forMode: .eventTracking)
        // This escape is installed directly in the mode under test. It does
        // not add eventTracking to the common-mode set and cannot make the
        // production timer pass.
        let escapeTimer = Timer(timeInterval: escapeSecs, repeats: false) { _ in
            escapeFired = true
            if !behaviorReleased {
                behaviorReleased = true
                behaviorGate.signal()
            }
            menu.cancelTracking()
        }
        RunLoop.main.add(escapeTimer, forMode: .eventTracking)

        let started = Date()
        _ = menu.popUp(
            positioning: nil, at: NSPoint(x: 20, y: 50), in: window.contentView)
        let elapsed = Date().timeIntervalSince(started)
        productionTimer.invalidate()
        defaultTimer.invalidate()
        releaseTimer.invalidate()
        escapeTimer.invalidate()
        subscription.cancel()

        let mode = productionMode?.rawValue ?? "nil"
        let ackMode = acknowledgementMode?.rawValue ?? "nil"
        print(String(format:
            "# native-menu callbacks production=%d default=%d behavior=%d acknowledgements=%d publishes=%d mode=%@ ackMode=%@ elapsed=%.3fs pendingObserved=%@ escape=%@",
            productionCallbacks, defaultCallbacks, behaviorApplies,
            acknowledgements, publishes, mode, ackMode, elapsed,
            pendingObservedDuringTracking ? "true" : "false",
            escapeFired ? "true" : "false"))
        check("native menu pause: menu opened and closed",
            delegate.didOpen && delegate.didClose,
            "opened=\(delegate.didOpen) closed=\(delegate.didClose)")
        check("native menu pause: production timer fired in event tracking",
            productionCallbacks > 0 && productionMode == .eventTracking,
            "callbacks=\(productionCallbacks) mode=\(mode)")
        check("native menu pause: default-mode control stayed starved",
            defaultCallbacks == 0, "callbacks=\(defaultCallbacks)")
        check("native menu pause: held behavior keeps the menu UI Starting",
            pendingObservedDuringTracking,
            "pending=\(acknowledger.isPending) header=\(state.headerText) glyph=\(state.glyph)")
        check("native menu pause: acknowledged behavior permits Protected",
            behaviorApplies == 1 && acknowledgements == 1
                && acknowledgementMode == .eventTracking
                && !acknowledger.isPending
                && state.headerText == "Protected" && state.glyph == .protecting,
            "behavior=\(behaviorApplies) acknowledgements=\(acknowledgements) "
                + "mode=\(ackMode) pending=\(acknowledger.isPending) "
                + "header=\(state.headerText)")
        check("native menu pause: private pause expiry publishes each transition once",
            state.pauseUntil == nil && publishes == 3,
            "pauseUntil=\(String(describing: state.pauseUntil)) publishes=\(publishes)")
        check("native menu pause: expiry beat the escape timer",
            !escapeFired,
            String(format: "elapsed=%.3fs escape=%.1fs", elapsed, escapeSecs))
    }

    // MARK: 5 — LogTail (spec §10.3 case 5)

    /// 3 MB synthetic jsonl: 12 `drop` records up front (beyond any small
    /// cap), clean-frame filler, then 12 more drops interleaved with lifts,
    /// malformed lines and a summary record near the end.
    static func caseLogTail(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/run.jsonl"
        var text = ""
        func drop(_ n: Int, app: String?) -> String {
            let a = app.map { " app=\($0)" } ?? ""
            return "{\"ts\":\"2026-08-22T10:00:\(String(format: "%02d", n % 60))Z\",\"event\":\"curtain\",\"info\":\"drop window \(n)\(a)\"}\n"
        }
        for n in 0..<12 { text += drop(n, app: "Early") }
        let filler = "{\"ts\":\"2026-08-22T10:00:00Z\",\"inferMs\":20.5,\"totalMs\":25.1,\"detections\":[],\"regions\":[],\"blocked\":0}\n"
        while text.utf8.count < 3 * 1024 * 1024 { text += filler }
        for n in 100..<112 {
            text += drop(n, app: n == 105 ? nil : (n % 2 == 0 ? "Google Chrome" : "Safari"))
            text += "{\"ts\":\"2026-08-22T10:01:00Z\",\"event\":\"curtain\",\"info\":\"lift (linger) window \(n)\"}\n"
            text += "this is not json\n"
            text += filler
        }
        text += "{\"ts\":\"2026-08-22T10:02:00Z\",\"event\":\"summary\",\"frames\":5}\n"
        text += "{\"ts\":\"2026-08-22T10:03:00Z\",\"event\":\"capture\",\"info\":\"state=down error=x\"}\n"
        text += "{\"ts\":\"2026-08-22T10:04:00Z\",\"inf"  // torn final line
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
        let isDrop: (LogTail.Record) -> Bool = { $0.event == "curtain" && $0.info?.hasPrefix("drop") == true }

        var first: LogTail.Record?
        var captures = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = LogTail.tail(path: path, want: 10) { rec in
            if first == nil { first = rec }
            if rec.event == "capture" { captures += 1 }
            return isDrop(rec)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard case let .success(got) = r else { check("logtail: read ok", false, "\(r)"); return }
        let wantInfos: [String?] = (102..<112).reversed().map { n in
            "drop window \(n)" + (n == 105 ? "" : (n % 2 == 0 ? " app=Google Chrome" : " app=Safari"))
        }
        let gotInfos = got.items.map { $0.info }
        check("logtail: last 10 drops newest-first", gotInfos == wantInfos, "\(gotInfos)")
        check("logtail: not truncated when 10 found", !got.truncated)
        check("logtail: torn last line skipped, newest complete record surfaces first",
            first?.event == "capture" && first?.ts == "2026-08-22T10:03:00Z", "\(String(describing: first))")
        check("logtail: matcher sees non-matching event records", captures == 1)
        print(String(format: "# logtail: 10 drops from a 3 MB file in %.2f ms", ms))

        var scanned = 0
        let t1 = CFAbsoluteTimeGetCurrent()
        let all = LogTail.tail(path: path, want: 100) { scanned += 1; return isDrop($0) }
        let msAll = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        guard case let .success(a) = all else { check("logtail: full read ok", false); return }
        check("logtail: 24 drops in the whole file, not truncated", a.items.count == 24 && !a.truncated,
            "\(a.items.count) \(a.truncated)")
        print(String(format: "# logtail: full 3 MB scan (%d records) in %.2f ms", scanned, msAll))

        let capped = LogTail.tail(path: path, want: 20, maxBytes: 1024 * 1024) { isDrop($0) }
        guard case let .success(c) = capped else { check("logtail: capped read ok", false); return }
        check("logtail: maxBytes cap reports truncation", c.truncated && c.items.count == 12,
            "\(c.items.count) truncated=\(c.truncated)")

        if case .failure(let e) = LogTail.tail(path: dir + "/none.jsonl", want: 1, matching: { _ in true }) {
            check("logtail: missing file is an error, not an empty list", e.description.contains("No such file"), e.description)
        } else {
            check("logtail: missing file is an error, not an empty list", false)
        }

        let chrome = ActivityItem.parseDrop("drop window 42 app=Google Chrome")
        check("activity: parse app + window", chrome?.app == "Google Chrome" && chrome?.window == 42)
        check("activity: no app= ⇒ Unknown app", ActivityItem.parseDrop("drop window 7")?.app == ActivityItem.unknownApp)
        check("activity: parole-return drop parses", ActivityItem.parseDrop("drop (parole return) window 9 app=Safari")?.window == 9)
        check("activity: lift is not a drop", ActivityItem.parseDrop("lift (linger) window 42") == nil)
        let now = Date()
        check("activity: health lost", UIActivity.healthText(lastTs: now, lastCapture: (now, "state=down error=x"), now: now).hasPrefix("capture lost since"))
        check("activity: health stale", UIActivity.healthText(lastTs: now.addingTimeInterval(-UIActivity.staleSecs - 1), lastCapture: nil, now: now) == "no recent log activity")
        check("activity: health live", UIActivity.healthText(lastTs: now, lastCapture: (now, "state=restored after 1 attempt(s)"), now: now).hasPrefix("protecting"))
        check("activity: health detector failing", UIActivity.healthText(lastTs: now, lastCapture: nil, lastDetector: (now, "state=failing budget x"), now: now).hasPrefix("detector failing since"))
        check("activity: health detector recovered", UIActivity.healthText(lastTs: now, lastCapture: nil, lastDetector: (now, "state=recovered observed 3"), now: now).hasPrefix("protecting"))
        check("activity: p95 of 20 samples is the 19th", WindowOwner.p95((1...20).map(Double.init)) == 19)
    }

    // MARK: 6 — registry + driver (static parts; the hosted-view check is
    // the E2E suite's `waitfor`, spec §10.3 case 6 risk note)

    static func caseRegistryAndDriver(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let reg = UIRegistry.shared
        let c1 = UIControl(id: "t.x", kind: .text, read: { "v" }, activate: nil, setText: nil, enabled: { true })
        let c2 = UIControl(id: "t.x", kind: .text, read: { "v2" }, activate: nil, setText: nil, enabled: { true })
        reg.register(c1)
        check("registry: register/lookup/read", reg.control("t.x")?.read() == "v")
        // Two live registrations of one id — SwiftUI evaluating a control's
        // modifier twice, or a second popover built before the first tore
        // down. The newest answers, and each instance can only drop its own
        // (UIRegistry.controls / unregister receipts).
        reg.register(c2)
        check("registry: the newest registration answers", reg.control("t.x")?.read() == "v2")
        reg.unregister("t.x", token: c2.token)
        check("registry: the surviving instance keeps the id", reg.control("t.x")?.read() == "v")
        reg.register(c2)
        reg.unregister("t.x", token: c1.token)
        check("registry: a stale unregister leaves the live control", reg.control("t.x")?.read() == "v2")
        reg.unregister("t.x", token: c2.token)
        check("registry: unregister", reg.control("t.x") == nil)
        var matrix = [DemoState()]
        var dev = DemoState(); dev.devstate = true
        matrix.append(dev)
        var paused = DemoState(); paused.paused = .m15
        matrix.append(paused)
        var noPin = DemoState(); noPin.pin = .unset
        matrix.append(noPin)
        var pinned = DemoState(); pinned.policy = .pinnedStrict
        matrix.append(pinned)
        check("registry: requiredIDs non-empty for every demo state and always has the header",
            matrix.allSatisfy { UIRegistry.requiredIDs(for: $0).contains("ui.status.header") })
        // Addendum 3: the ids are state-keyed, so a state that cannot render
        // a control must not require it — the E2E `waitfor` would hang on an
        // id the view never draws, and `assertmissing` would fail on one it
        // always does.
        let base = UIRegistry.requiredIDs(for: DemoState())
        // App UI redesign: the presets sit behind "Pause protection…".
        check("registry: not paused ⇒ Pause protection… required, resume not",
            base.contains("ui.pause.open")
                && !base.contains("ui.pause.resume"))
        let whilePaused = UIRegistry.requiredIDs(for: paused)
        check("registry: paused ⇒ resume required, presets not",
            whilePaused.contains("ui.pause.resume")
                && whilePaused.isDisjoint(with: PausePreset.allCases.map(\.controlID)))
        check("registry: no PIN ⇒ the amber row is required",
            UIRegistry.requiredIDs(for: noPin).contains("ui.status.nopin")
                && !base.contains("ui.status.nopin"))
        check("registry: settings-only detail is absent from every root state",
            matrix.allSatisfy { state in
                UIRegistry.requiredIDs(for: state).isDisjoint(with: [
                    "ui.sensitivity", "ui.sensitivity.standard", "ui.sensitivity.strict",
                    "ui.sensitivity.pinned", "ui.activity.footer",
                ])
            })
        // Spec §6: `pinned:strict` is the FLAG pinning the run, so
        // settings.json must carry no override — otherwise the E2E would
        // exercise the override branch and prove nothing about precedence.
        check("demo: pinned:strict writes no policyOverride",
            pinned.settings().policyOverride == nil && DemoState.Policy.strict != .pinnedStrict)

        // §9.4 Model row (owner 2026-09-02). The row is a settings-sheet id,
        // which a DemoState cannot express (Addendum 3), so what is checked
        // headlessly is the one thing with logic in it: the path → id
        // reduction. No file path, no extension, and never a blank value.
        check("model row: basename without .mlpackage",
            UIVersion.modelID(path: "/Library/Application Support/SentryScreen/m_v8_ep50_fp16.mlpackage")
                == "m_v8_ep50_fp16")
        check("model row: a dotted name keeps every component but the extension",
            UIVersion.modelID(path: "/tmp/m_v8.1_fp16.mlpackage") == "m_v8.1_fp16")
        // The case that discriminates the exact-suffix strip from
        // `deletingPathExtension()` (2026-09-02): the latter returns
        // `m_v8` here — a model name that does not exist — where the row must
        // show the unexpected name verbatim.
        check("model row: a dotted name with NO .mlpackage is not truncated at its last dot",
            UIVersion.modelID(path: "/tmp/m_v8.1_fp16") == "m_v8.1_fp16")
        check("model row: a trailing slash is still the package name",
            UIVersion.modelID(path: "/tmp/models/m_v8_ep50_fp16.mlpackage/") == "m_v8_ep50_fp16")
        check("model row: another extension is shown verbatim, not truncated",
            UIVersion.modelID(path: "/tmp/m_v8_ep50_fp16.mlmodelc") == "m_v8_ep50_fp16.mlmodelc")
        check("model row: no path configured ⇒ the named fallback, never blank",
            UIVersion.modelID(path: "") == UIVersion.modelUnconfigured
                && UIVersion.modelID(path: "/") == UIVersion.modelUnconfigured
                && UIVersion.modelID(path: "/tmp/.mlpackage") == UIVersion.modelUnconfigured
                && !UIVersion.modelUnconfigured.isEmpty)
        check("model row: the id never carries the path it came from",
            !UIVersion.modelID(path: "/Library/Application Support/SentryScreen/m.mlpackage")
                .contains("/"))
        check("model row: a model-less host (demo, selftests) says so by default",
            UIState(settings: .defaults, devStateRoot: false, isAdmin: true).modelID
                == UIVersion.modelUnconfigured)

        // MEASURED 2026-08-22: `Image(systemName:)` on a name AppKit does not
        // know draws an EMPTY slot with no error — `lock.badge.plus` shipped
        // that way in the first slice-5 build and was only caught by looking
        // at a PNG. Resolving every name headlessly turns a typo into a
        // failing test.
        for name in UISymbol.all {
            check("symbol: \(name) resolves",
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
        check("brand: product casing is exact", SentryBrand.productName == "SentryScreen")
        check("information budget: root sections stay exact",
            UIPopoverInformationBudget.rootSections == [
                "status", "pause", "actionable notices", "footer",
            ])
        check("accessibility: Increase Contrast raises native section strokes",
            UIMetrics.sectionStrokeWidth(increasedContrast: true)
                > UIMetrics.sectionStrokeWidth(increasedContrast: false))
        check("accessibility: Reduce Motion disables animation without changing standard mode",
            UIAnim.disabled(scripted: false, reduceMotion: true)
                && !UIAnim.disabled(scripted: false, reduceMotion: false))

        check("driver: tokenize quotes", UIDriver.tokenize("assert ui.x \"Paused until 3:45 PM\"") == ["assert", "ui.x", "Paused until 3:45 PM"])
        check("driver: tokenize unbalanced ⇒ nil", UIDriver.tokenize("assert ui.x \"oops") == nil)
        check("driver: tokenize empty quoted arg", UIDriver.tokenize("type ui.f \"\"") == ["type", "ui.f", ""])
        var d = DemoState()
        check("demo: unknown key rejected", d.set("bogus", "1") != nil)
        check("demo: bad value rejected", d.set("health", "fine") != nil && d.health == .protecting)
        check("demo: activity range", d.set("activity", "11") != nil && d.set("activity", "10") == nil)
        check("demo: 10 fake rows, Safari first", d.activityItems().count == 10 && d.activityItems().first?.app == "Safari")
        var none = DemoState(); none.activity = 0
        check("registry: activity ids are not required until Settings opens",
            !UIRegistry.requiredIDs(for: none).contains("ui.activity.empty")
                && !UIRegistry.requiredIDs(for: d).contains("ui.activity.row.9")
                && !UIRegistry.requiredIDs(for: d).contains("ui.activity.footer"))
        check("demo: paused until ISO", d.set("paused", "until:2030-01-01T00:00:00Z") == nil)
        d.pin = .locked
        let s = d.parentPINState()
        check("demo: locked ⇒ pin set + failures at maxAttempts",
            s.pin != nil && s.failures.count == PinGate.maxAttempts && s.failures.lockedUntil != nil)

        // Screenshot verifier: the assertions that turn a TCC-denied capture
        // into a loud 72 instead of a green test on garbage.
        check("driver: verify missing file", UIDriver.verify(png: dir + "/none.png") != nil)
        let small = dir + "/small.png"
        FileManager.default.createFile(atPath: small, contents: Data(repeating: 0, count: 100))
        check("driver: verify ≤ minShotBytes", UIDriver.verify(png: small)?.contains("minShotBytes") == true)
        let junk = dir + "/junk.png"
        FileManager.default.createFile(atPath: junk, contents: Data(repeating: 7, count: UIDriver.minShotBytes + 1))
        check("driver: verify non-image", UIDriver.verify(png: junk)?.contains("decode") == true)
        let flat = dir + "/flat.png"
        FileManager.default.createFile(atPath: flat, contents: Self.png(width: 200, height: 120, gradient: false))
        check("driver: verify uniform black ⇒ rejected", UIDriver.verify(png: flat)?.contains("uniform") == true)
        let grad = dir + "/grad.png"
        FileManager.default.createFile(atPath: grad, contents: Self.png(width: 200, height: 120, gradient: true))
        check("driver: verify non-uniform ⇒ ok", UIDriver.verify(png: grad) == nil, UIDriver.verify(png: grad) ?? "")
    }

    /// Both clear minShotBytes: noisy alpha keeps the flat one uncompressible
    /// so it reaches the pixel check (verify compares RGB only).
    static func png(width: Int, height: Int, gradient: Bool) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let p = rep.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let o = y * rep.bytesPerRow + x * 4
                let v: UInt8 = gradient ? UInt8.random(in: 0...255) : 0
                p[o] = v; p[o + 1] = v; p[o + 2] = v; p[o + 3] = UInt8.random(in: 0...255)
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: 7 — Curtain state machine

    /// Headless coverage for the curtain-only port. A scripted window source
    /// exercises ownership and the 120 Hz geometry tracker without touching
    /// the family's display, installed daemon, or model weights.
    static func caseQuickLookWindows() {
        let outer = CGRect(x: 100, y: 100, width: 370, height: 520)
        let inner = CGRect(x: 105, y: 138, width: 360, height: 477)
        let front = CGRect(x: 120, y: 180, width: 100, height: 200)
        let hit = CGRect(x: 300, y: 300, width: 30, height: 30)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let preview: CGWindowID = 9101
        let foreground: CGWindowID = 9102
        func row(_ id: CGWindowID, _ pid: pid_t, _ frame: CGRect, _ layer: Int = 0,
                 _ owner: String = "Test host") -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: 1.0,
             kCGWindowBounds as String: ["X": frame.minX, "Y": frame.minY,
                                       "Width": frame.width, "Height": frame.height]]
        }
        var rows = [row(preview, 1000, outer, 3)]
        var helperRows = [row(9103, 2000, inner, 0, "QuickLookUIService")]
        let tracker = WindowTracker()
        tracker.quickLookProcessSource = { ($0 == 2000, $0 == 1000 || $0 == 1001) }
        tracker.windowSource = { rows }
        tracker.allWindowSource = { rows + helperRows }
        tracker.screenFrame = screen
        var identities: [CGWindowID] = []
        tracker.onQuickLookIdentity = { id, _ in identities.append(id) }
        func owner(_ rect: CGRect = hit, incumbent: CGWindowID? = nil) -> WindowTracker.Resolution {
            tracker.resolveOwners([WindowTracker.Query(authority: rect, gate: rect, incumbent: incumbent)])[0]
        }
        check("Quick Look: pollable outer panel owns detections at layer 3", owner().frontID == preview)
        rows = [row(foreground, 1001, front), row(preview, 1000, outer, 0)]
        check("Quick Look: exposed detection keeps its preview owner behind a foreground window", owner().frontID == preview)
        let covered = owner(front, incumbent: preview)
        check("Quick Look: existing foreground and incumbent ownership rules are preserved",
              covered.frontID == foreground && covered.frontHoldsGate && covered.incumbentHoldsAuthority)
        check("Quick Look: layer/focus change retains the outer identity", identities == [preview])
        check("Quick Look: overlap retains the existing hold", tracker.quickLookHolds([preview]) == [preview])
        rows = [row(preview, 1000, outer, 0), row(foreground, 1001, front)]
        check("Quick Look: a lower window does not delay clean evidence", tracker.quickLookHolds([preview]).isEmpty)
        rows = [row(9110, 3000, outer, 20, "Dock"), row(9111, 3001, outer, 0, "WindowManager"), row(preview, 1000, outer, 3)]
        check("Quick Look: existing system exclusions do not hold the preview", tracker.quickLookHolds([preview]).isEmpty)
        rows = helperRows + [row(preview, 1000, outer, 3)]
        check("Quick Look: helper pixels belong to the pollable outer panel", owner().frontID == preview)
        check("Quick Look: complete panel bounds replace the browser strip",
              Curtain.contentRect(window: outer, display: screen, quickLook: true) == outer)
        check("Quick Look: ordinary window bounds retain the browser strip",
              Curtain.contentRect(window: outer, display: screen).minY == outer.minY + Curtain.chromeStripPt)
        check("Quick Look: successor lookup includes the layer-3 outer",
              tracker.contentWindowIDs(intersecting: outer) == [preview])

        rows = [row(preview, 1000, outer, 3)]
        let curtain = Curtain()
        curtain.walkEvery = 1
        var t = CFAbsoluteTimeGetCurrent()
        func step(_ count: Int, blocked: Bool) {
            for _ in 0..<count {
                t += 0.1
                _ = curtain.update(blockedScreenRects: blocked ? [hit] : [],
                                   tracker: tracker, display: screen, at: t)
            }
        }
        step(Curtain.triggerHits + 1, blocked: true)
        check("Quick Look: ordinary trigger drops the panel curtain", curtain.activeIDs.contains(preview))
        rows = [row(foreground, 1001, outer), row(preview, 1000, outer, 0)]
        // Exercise the existing hold duration and clean-frame bar, without
        // adding a product timer or changing the ordinary curtain thresholds.
        let cleanSteps = max(Int(Curtain.holdSecs / 0.1) + 2, Curtain.holdCleanFrames + 2)
        step(cleanSteps, blocked: false)
        check("Quick Look: hidden content does not expire the active curtain", curtain.activeIDs.contains(preview))
        rows = [row(preview, 1000, outer, 0)]
        step(1, blocked: true)
        check("Quick Look: reveal keeps protection on the same panel", curtain.activeIDs.contains(preview))
        step(cleanSteps, blocked: false)
        check("Quick Look: visible clean content uses the existing release rules", !curtain.activeIDs.contains(preview))

        rows = []
        helperRows = []
        _ = owner()
        check("Quick Look: closed outer identity is removed", !tracker.isQuickLookWindow(preview))
        rows = [row(preview, 1001, outer, 3)]
        check("Quick Look: a recycled ID does not inherit preview eligibility", owner().frontID == nil)
        helperRows = [row(9103, 2000, inner)]
        rows = [row(preview, 1000, outer, 3), row(foreground, 1001, outer, 3)]
        check("Quick Look: ambiguous host geometry grants no eligibility", owner().frontID == nil)
        tracker.stop()
    }

    static func caseCurtain() {
        // The attributed merge is a payload-carrying copy of Geometry.merge.
        // Tie its geometry to the production merge across deterministic
        // overlap, disjoint, empty, and chained-union sets.
        var seed: UInt64 = 0xC0FFEE
        func randomUnit() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return CGFloat((seed >> 32) & 0xffff) / CGFloat(0xffff)
        }
        var mergeMatches = true
        for setIndex in 0..<300 {
            let count = Int(randomUnit() * 16)
            let rects = (0..<count).map { _ in
                let width = 0.02 + randomUnit() * 0.35
                let height = 0.02 + randomUnit() * 0.35
                return CGRect(
                    x: randomUnit() * (1 - width), y: randomUnit() * (1 - height),
                    width: width, height: height)
            }
            let attributed = Curtain.mergeAttributed(
                rects, sourceIndices: Array(rects.indices), iouOver: 0.001).map(\.rect)
            if attributed != Geometry.merge(rects, iouOver: 0.001) {
                mergeMatches = false
                print("# curtain merge mismatch set=\(setIndex) rects=\(rects)")
                break
            }
        }
        check("curtain: attributed merge geometry matches Geometry.merge for 300 random sets",
            mergeMatches)

        struct FakeWin {
            var id: CGWindowID
            var owner: String
            var rect: CGRect
        }
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let big = CGRect(x: 543, y: 213, width: 1172, height: 626)
        let winsLock = NSLock()
        var wins = [
            FakeWin(id: 96, owner: "WindowManager", rect: big),
            FakeWin(id: 6320, owner: "Google Chrome", rect: big),
        ]
        func rows() -> [[String: Any]] {
            winsLock.lock()
            defer { winsLock.unlock() }
            return wins.map { w in
                [
                    "kCGWindowNumber": w.id,
                    "kCGWindowOwnerName": w.owner,
                    "kCGWindowLayer": 0,
                    "kCGWindowAlpha": 1.0,
                    "kCGWindowOwnerPID": pid_t(1),
                    "kCGWindowBounds": [
                        "X": w.rect.minX, "Y": w.rect.minY,
                        "Width": w.rect.width, "Height": w.rect.height,
                    ],
                ] as [String: Any]
            }
        }
        func removeChrome() -> FakeWin {
            winsLock.lock()
            defer { winsLock.unlock() }
            return wins.remove(at: wins.firstIndex { $0.id == 6320 }!)
        }
        func addChrome(_ chrome: FakeWin) {
            winsLock.lock()
            wins.append(chrome)
            winsLock.unlock()
        }
        func resizeChrome(_ rect: CGRect) {
            winsLock.lock()
            wins[wins.firstIndex { $0.id == 6320 }!].rect = rect
            winsLock.unlock()
        }

        let windowTracker = WindowTracker()
        windowTracker.windowSource = rows
        windowTracker.screenFrame = screen
        // The scheduling receipt goes to a sink instead of stderr so its final
        // line (emitted by stop() at the end of this case) can be asserted.
        // The sink is called from the poll thread (heartbeat) and from stop()
        // on this thread, hence the lock.
        let schedLock = NSLock()
        var schedLines: [String] = []
        windowTracker.onReceipt = { line in
            schedLock.lock()
            schedLines.append(line)
            schedLock.unlock()
        }
        windowTracker.start()
        let curtain = Curtain()
        var events: [(String, CGWindowID)] = []
        curtain.onChange = { events.append(($0, $1)) }
        var t = CFAbsoluteTimeGetCurrent()
        let hit = CGRect(x: 900, y: 500, width: 120, height: 90)

        func step(_ count: Int, hits: Bool, dt: CFTimeInterval = 1.0 / 30) {
            for _ in 0..<count {
                t += dt
                _ = curtain.update(
                    blockedScreenRects: hits ? [hit] : [],
                    tracker: windowTracker, display: screen, at: t)
                windowTracker.setTracked(curtain.watchIDs)
            }
        }
        func has(_ prefix: String, _ id: CGWindowID) -> Bool {
            events.contains { $0.0.hasPrefix(prefix) && $0.1 == id }
        }
        func tick(_ count: Int, from start: CFAbsoluteTime) -> CFAbsoluteTime {
            var tickT = start
            for _ in 0..<count {
                tickT += Pipeline.curtainTickSecs
                Thread.sleep(forTimeInterval: 0.05)
                _ = curtain.update(
                    blockedScreenRects: [], tracker: windowTracker,
                    display: screen, at: tickT, evaluated: false)
                windowTracker.setTracked(curtain.watchIDs)
            }
            return tickT
        }

        Thread.sleep(forTimeInterval: 0.1)
        step(6, hits: true)
        check(
            "curtain: ownership ignores a WindowManager proxy with the content window's frame",
            has("drop", 6320) && !has("drop", 96), "events=\(events)")
        events.removeAll()

        // Geometry time alone is not detector evidence and cannot expire a hold.
        t = tick(Int(Curtain.holdSecs / Pipeline.curtainTickSecs) + 4, from: t)
        check(
            "curtain: geometry-only ticks do not expire a detector hold",
            curtain.activeIDs.contains(6320) && !has("lift", 6320), "events=\(events)")

        // A blocked non-walk frame is unknown, not clean. Nineteen later
        // globally clean frames must still be one short of the evidence bar.
        step(1, hits: true)
        step(Curtain.holdCleanFrames - 1, hits: false, dt: 0.3)
        check(
            "curtain: a blocked non-walk frame does not count as clean evidence",
            curtain.activeIDs.contains(6320) && !has("lift", 6320), "events=\(events)")
        step(1, hits: false, dt: 0.3)
        check(
            "curtain: the twentieth proven clean frame satisfies hold evidence",
            has("lift (hold", 6320), "events=\(events)")
        events.removeAll()
        // PAROLE needs paroleHits attributed hits (owner decision 2026-09-02):
        // one hit — a single-frame false positive — no longer re-drops a known
        // offender; two inside windowSecs do.
        step(1, hits: true)
        check(
            "parole: one attributed hit does not re-drop a hit parolee (was an instant re-drop)",
            !curtain.activeIDs.contains(6320) && !has("drop", 6320), "events=\(events)")
        // windowFrames + 1 clean evaluated frames over ~1.03 s: the single
        // hit ages out of BOTH retention arms (receipt at
        // `Curtain.windowFrames`; was 4 frames at 0.3 s — wall clock alone —
        // before the frame arm existed).
        step(curtain.windowFrames() + 1, hits: false, dt: 1.0 / 30)
        check(
            "parole: a single-frame hit ages out of the hit window without a drop",
            !curtain.activeIDs.contains(6320) && !has("drop", 6320), "events=\(events)")
        step(1, hits: true)
        check(
            "parole: the first of two hits still does not drop",
            !curtain.activeIDs.contains(6320), "events=\(events)")
        step(1, hits: true)
        check(
            "parole: the second attributed hit inside windowSecs re-drops as drop (parole)",
            curtain.activeIDs.contains(6320) && has("drop (parole)", 6320), "events=\(events)")
        check("parole: paroleHits == 2 (owner decision 2026-09-02)", Curtain.paroleHits == 2)
        for tier in PerfTier.all {
            let ms = Curtain.paroleExtraDelayMs(fps: tier.fps)
            check(
                "tier \(tier.name.rawValue): parole's extra hit costs one detector frame "
                    + String(format: "(%.0f ms at %d fps)", ms, tier.fps),
                abs(ms - 1000.0 / Double(tier.fps)) < 1e-9, "\(ms)")
        }
        events.removeAll()

        step(5, hits: false, dt: 1.2)
        check(
            "curtain: five clean frames over six seconds do not satisfy holdCleanFrames",
            curtain.activeIDs.contains(6320) && !has("lift", 6320), "events=\(events)")
        step(Curtain.holdCleanFrames - 5, hits: false)
        check(
            "curtain: hold lifts after wall time and enough evaluated clean frames",
            has("lift (hold", 6320), "events=\(events)")
        // HIT-PAROLE CHURN (2026-09-09, receipt at Curtain.hitParoleSecs): this
        // is the episode's SECOND hold-expiry lift inside hitParoleSecs, so
        // the re-drop bar climbs to triggerHits and the daemon says so.
        check(
            "parole: constants — hitParoleSecs 30 s < paroleSecs 300 s, hard cap 300 s",
            Curtain.hitParoleSecs == 30 && Curtain.paroleSecs == 300
                && Curtain.paroleHardCapSecs == 300 && Curtain.hitParoleSecs < Curtain.paroleSecs)
        check(
            "parole: a second hold-expiry lift inside hitParoleSecs is loud (parole-churn) and names the raised bar",
            events.contains {
                $0.1 == 6320 && $0.0.hasPrefix("parole-churn: 2 hold-expiry lifts")
                    && $0.0.contains("re-drop bar \(Curtain.triggerHits) hits")
            }, "events=\(events)")
        events.removeAll()

        // NO PROMOTION (2026-09-09): a hold-expiry parolee that leaves the
        // stage stays hit parole — no return re-arm, no strip cover, no
        // geometry re-drop when it comes back. These two checks are the
        // deliberate inverse of the pre-2026-09-09 assertions.
        let chrome = removeChrome()
        step(3, hits: false, dt: 0.2)
        Thread.sleep(forTimeInterval: 0.3)
        step(3, hits: false, dt: 0.2)
        check(
            "curtain: a hold-expiry parolee is NOT re-armed for return when its window leaves the stage",
            !has("parole re-armed", 6320) && !has("strip-cover on", 6320), "events=\(events)")
        addChrome(chrome)
        Thread.sleep(forTimeInterval: 0.2)
        step(3, hits: false, dt: 0.1)
        check(
            "curtain: a proven-clean parolee returning to the stage does NOT re-drop from geometry",
            !has("drop (parole return)", 6320) && !curtain.activeIDs.contains(6320),
            "events=\(events)")
        // After the churn the bar is triggerHits: the 2-frame burst that
        // re-dropped the owner's clean window
        // no longer does; a third frame still does.
        step(Curtain.paroleHits, hits: true)
        check(
            "parole: after a churn, paroleHits attributed hits no longer re-drop",
            !curtain.activeIDs.contains(6320) && !has("drop", 6320), "events=\(events)")
        step(Curtain.triggerHits - Curtain.paroleHits, hits: true)
        check(
            "parole: the escalated parolee re-drops at triggerHits",
            curtain.activeIDs.contains(6320) && has("drop", 6320), "events=\(events)")
        events.removeAll()

        // Close while capture is static: geometry ticks lift, then expire linger.
        _ = removeChrome()
        t = tick(Int(Curtain.deadLiftSecs / Pipeline.curtainTickSecs) + 2, from: t)
        check(
            "curtain: a closed window lifts on geometry ticks within deadLiftSecs plus one tick",
            has("lift (linger)", 6320), "events=\(events)")
        check(
            "curtain: the geometry path did not convert the close into a hold lift",
            !has("lift (hold", 6320), "events=\(events)")
        t = tick(Int(Curtain.curtainLingerSecs / Pipeline.curtainTickSecs) + 2, from: t)
        check("curtain: geometry ticks expire the close linger", !curtain.hasLinger, "events=\(events)")
        events.removeAll()

        // Minimize and restore with no capture frame.
        addChrome(chrome)
        Thread.sleep(forTimeInterval: 0.2)
        step(3, hits: false, dt: 0.1)
        check(
            "curtain: the closed-window parole re-drops when the window returns",
            has("drop (parole return)", 6320), "events=\(events)")
        events.removeAll()
        resizeChrome(CGRect(x: 16, y: 764, width: 82, height: 111))
        t = tick(Int(Curtain.subFloorLiftSecs / Pipeline.curtainTickSecs) + 3, from: t)
        check(
            "curtain: a minimized window lifts to sub-floor state on geometry ticks",
            has("lift (sub-floor)", 6320), "events=\(events)")
        check(
            "curtain: the Dock thumbnail receives a strip cover without a capture frame",
            has("strip-cover on", 6320), "events=\(events)")
        let thumbnail = curtain.update(
            blockedScreenRects: [], tracker: windowTracker,
            display: screen, at: t + Pipeline.curtainTickSecs, evaluated: false)
        check(
            "curtain: the strip cover uses the thumbnail frame",
            thumbnail.contains { $0.id == 6320 && $0.frame.width < 100 },
            "output=\(thumbnail)")
        resizeChrome(big)
        Thread.sleep(forTimeInterval: 0.2)
        t = tick(3, from: t)
        check(
            "curtain: restoring from the Dock re-drops on geometry",
            has("drop (parole return)", 6320), "events=\(events)")
        events.removeAll()

        // ---- Close lifts on evidence (2026-09-09; receipts at
        // Curtain.destroyedLiftSecs / lingerCleanFrames / the transient rule
        // and WindowTracker.DeadKind). Each block re-drops 6320 through the
        // geometry parole return the block before it armed.
        func redrop() {
            // Past any ghost ban: two dead lifts inside ghostWindowSecs ban
            // the id for ghostBanSecs, and every block here ends in a dead
            // lift. No curtain is active here, so the jump re-stamps nothing.
            t += Curtain.ghostBanSecs + 1
            addChrome(chrome)
            Thread.sleep(forTimeInterval: 0.2)
            step(3, hits: false, dt: 0.1)
            check("close: rig re-dropped 6320", curtain.activeIDs.contains(6320), "events=\(events)")
            events.removeAll()
        }
        var lastOut: [(id: CGWindowID, frame: CGRect)] = []
        func frame(_ hits: Bool, dt: CFTimeInterval = 1.0 / 30) {
            t += dt
            lastOut = curtain.update(
                blockedScreenRects: hits ? [hit] : [],
                tracker: windowTracker, display: screen, at: t)
            windowTracker.setTracked(curtain.watchIDs)
        }
        // A. Destroyed + two clean evaluated frames ⇒ fast lift, no linger.
        _ = removeChrome()
        Thread.sleep(forTimeInterval: 0.1)
        frame(false)
        check(
            "close: the tracker classified the closed window as destroyed",
            has("dead (destroyed)", 6320), "events=\(events)")
        check(
            "close: one clean frame over the departed rect is not enough",
            curtain.activeIDs.contains(6320) && !has("lift", 6320), "events=\(events)")
        frame(false)
        check(
            "close: the second clean frame lifts as `lift (closed, 2 clean frames)`",
            has("lift (closed, 2 clean frames)", 6320), "events=\(events)")
        check(
            "close: a closed-clean lift does not linger",
            !curtain.hasLinger && !lastOut.contains { $0.id == 6320 } && !has("lift (linger)", 6320),
            "events=\(events) out=\(lastOut)")
        check("close: lingerCleanFrames == 2", Curtain.lingerCleanFrames == 2)
        // A2. `.destroyed` is terminal (receipt at WindowTracker.deadRecheckSecs):
        // the lifted id is a RETURN parolee, so it stays tracked and keeps
        // missing; the tracker must NOT re-take the `.optionAll` snapshot
        // every deadRecheckSecs for that whole streak. Wall-clock wait (the
        // poll thread's recheck clock is wall time), > 2 x deadRecheckSecs.
        check("close: the lifted id stays tracked as a parolee (the streak outlives the lift)",
              curtain.watchIDs.contains(6320) && windowTracker.deadKind(6320) == .destroyed,
              "watch=\(curtain.watchIDs)")
        let snapshotsAtLift = windowTracker.allSnapshotCount
        let recheckWait = WindowTracker.deadRecheckSecs * 2 + 0.2
        let waitUntil = CFAbsoluteTimeGetCurrent() + recheckWait
        while CFAbsoluteTimeGetCurrent() < waitUntil {
            Thread.sleep(forTimeInterval: 0.05)
            frame(false, dt: 0.05)  // scripted clock advances with the wall clock
        }
        check("close: a destroyed id is not re-snapshotted while its parolee streak lasts",
              windowTracker.allSnapshotCount == snapshotsAtLift
                  && windowTracker.deadKind(6320) == .destroyed
                  && windowTracker.missSeconds(of: 6320) > WindowTracker.deadSecs,
              "snapshots \(snapshotsAtLift) -> \(windowTracker.allSnapshotCount) over \(recheckWait)s, streak=\(windowTracker.missStreak(of: 6320))")
        // B. Sustained blocked content where the window was ⇒ the full
        // ceiling, then a linger that only clean frames end.
        redrop()
        _ = removeChrome()
        Thread.sleep(forTimeInterval: 0.1)
        step(14, hits: true, dt: 0.1)
        check(
            "close: blocked boxes inside the departed rect hold the curtain past 1.4 s",
            curtain.activeIDs.contains(6320) && !has("lift", 6320), "events=\(events)")
        step(2, hits: true, dt: 0.1)
        check(
            "close: the destroyed ceiling (destroyedLiftSecs) lifts into a linger",
            has("lift (linger)", 6320) && !has("lift (closed", 6320), "events=\(events)")
        for _ in 0..<5 { frame(true, dt: 0.1) }
        check(
            "close: the linger keeps painting while boxes land inside it",
            curtain.hasLinger && lastOut.contains { $0.id == 6320 } && !has("linger off", 6320),
            "events=\(events) out=\(lastOut)")
        step(2, hits: false)
        check(
            "close: two clean frames end the linger as `linger off (2 clean frames)`",
            has("linger off (2 clean frames)", 6320) && !curtain.hasLinger, "events=\(events)")
        check("close: destroyedLiftSecs == deadLiftSecs (ceiling kept, receipt at the symbol)",
            Curtain.destroyedLiftSecs == Curtain.deadLiftSecs)
        // C. A capture gap re-stamps the departed-rect evidence: the outage
        // frame cannot be the second clean frame.
        redrop()
        _ = removeChrome()
        Thread.sleep(forTimeInterval: 0.1)
        frame(false)
        frame(false, dt: Curtain.gapGuardSecs + 0.5)
        check(
            "close: an evaluated-frame gap re-stamps the clean counter (no fast lift)",
            has("evaluated-frame gap", 0) && !has("lift (closed", 6320) && has("lift (linger)", 6320),
            "events=\(events)")
        step(2, hits: false)
        check("close: post-gap linger ends on fresh clean frames",
            has("linger off", 6320) && !curtain.hasLinger, "events=\(events)")
        // D. Offstage (unpollable but still listed in .optionAll — the
        // fullscreen-exit shape) keeps the pure wall-clock dead lift: clean
        // frames do NOT lift it early.
        redrop()
        let offstageRow = rows().first { ($0["kCGWindowNumber"] as? CGWindowID) == 6320 }!
        windowTracker.allWindowSource = { rows() + [offstageRow] }
        let snapshotsBeforeOffstage = windowTracker.allSnapshotCount  // D2 below
        _ = removeChrome()
        Thread.sleep(forTimeInterval: 0.1)
        step(12, hits: false, dt: 0.1)
        check(
            "close: an offstage id is classified offstage and clean frames do not lift it",
            has("dead (offstage)", 6320) && curtain.activeIDs.contains(6320) && !has("lift", 6320),
            "events=\(events)")
        step(5, hits: false, dt: 0.1)
        check(
            "close: the offstage ceiling (deadLiftSecs) lifts into a linger as before",
            has("lift (linger)", 6320), "events=\(events)")
        // D2. Offstage twin of A2 (receipt at WindowTracker.deadRechecksPerStreak):
        // the lifted offstage id is a RETURN parolee too, so its streak also
        // outlives its consumer; the tracker takes the first snapshot plus
        // deadRechecksPerStreak re-checks and then stops. Wall-clock wait long
        // enough for two more re-checks if the cap were missing.
        let offstageSnapshots = windowTracker.allSnapshotCount - snapshotsBeforeOffstage
        let capWait = WindowTracker.deadRecheckSecs * Double(WindowTracker.deadRechecksPerStreak + 2) + 0.2
        let capUntil = CFAbsoluteTimeGetCurrent() + capWait
        while CFAbsoluteTimeGetCurrent() < capUntil {
            Thread.sleep(forTimeInterval: 0.05)
            frame(false, dt: 0.05)
        }
        check(
            "close: an offstage parolee's streak is re-snapshotted deadRechecksPerStreak times, then stops",
            windowTracker.allSnapshotCount - snapshotsBeforeOffstage == WindowTracker.deadRechecksPerStreak + 1
                && windowTracker.deadKind(6320) == .offstage
                && curtain.watchIDs.contains(6320),
            "snapshots this streak \(offstageSnapshots) -> \(windowTracker.allSnapshotCount - snapshotsBeforeOffstage) over \(capWait)s (cap \(WindowTracker.deadRechecksPerStreak + 1)), kind=\(String(describing: windowTracker.deadKind(6320)))")
        windowTracker.allWindowSource = nil
        step(2, hits: false)
        // E. Transient handoff: a contain-arm successor that dies inside
        // deadLiftSecs lifts as transient, no linger, and the churn counter
        // is loud.
        redrop()
        _ = removeChrome()
        let successor = FakeWin(id: 7000, owner: "Google Chrome", rect: screen)
        addChrome(successor)
        Thread.sleep(forTimeInterval: 0.1)
        step(2, hits: true)
        check(
            "close: a containing successor of the departed curtain drops on the handoff bar",
            has("drop (handoff)", 7000), "events=\(events)")
        step(8, hits: true, dt: 0.05)
        winsLock.lock()
        wins.removeAll { $0.id == 7000 }
        winsLock.unlock()
        Thread.sleep(forTimeInterval: 0.1)
        step(17, hits: true, dt: 0.1)
        check(
            "close: a handoff curtain that lived < deadLiftSecs lifts as `lift (transient, …)`",
            has("lift (transient, lived 0.", 7000), "events=\(events)")
        check(
            "close: the transient lift skips the linger",
            !lastOut.contains { $0.id == 7000 } && !has("lift (linger)", 7000), "events=\(events)")
        check(
            "close: transient lifts are counted loudly",
            has("transient-handoff churn: 1 transient curtain(s) lifted in 10 s", 0),
            "events=\(events)")
        step(2, hits: false)
        events.removeAll()
        // F. SUCCESSOR LINGER (2026-09-09; receipt at Curtain.successorLinger).
        // Block A above is the no-successor path and is unchanged: nothing
        // listed overlaps the departed rect there, so it still lifts as
        // `lift (closed, …)`. Here a window DOES overlap it, and the three
        // exits are scripted one each. `successorRect` overlaps `big` on the
        // right; `hitB` sits inside it and clear of `big`, so a frame can be
        // clean over the departed rect and still be a hit for the successor.
        let successorRect = CGRect(x: 1500, y: 200, width: 400, height: 700)
        let hitB = CGRect(x: 1740, y: 300, width: 120, height: 120)
        check(
            "close: the successor rect overlaps the departed rect but hitB does not",
            successorRect.intersects(big) && !hitB.intersects(big)
                && successorRect.contains(hitB))
        func frameRects(_ rects: [CGRect], dt: CFTimeInterval = 1.0 / 30) {
            t += dt
            lastOut = curtain.update(
                blockedScreenRects: rects, tracker: windowTracker, display: screen, at: t)
            windowTracker.setTracked(curtain.watchIDs)
        }
        // A FRESH id per block on purpose: an id that already had a curtain is
        // a parolee, and a parolee re-drops on geometry alone the moment it is
        // listed again — which would end every later block on signal 1.
        func openSuccessor(_ id: CGWindowID) {
            _ = removeChrome()
            addChrome(FakeWin(id: id, owner: "Google Chrome", rect: successorRect))
            Thread.sleep(forTimeInterval: 0.2)
        }
        func closeSuccessor(_ id: CGWindowID) {
            winsLock.lock()
            wins.removeAll { $0.id == id }
            winsLock.unlock()
            Thread.sleep(forTimeInterval: 0.1)
        }
        // F1 — signal 1: the revealed window gets its own curtain.
        redrop()
        openSuccessor(7100)
        frameRects([hitB])
        frameRects([hitB])
        check(
            "close: a close that reveals a listed window lingers on it, not `lift (closed…)`",
            has("linger (successor 7100)", 6320) && !has("lift (closed", 6320),
            "events=\(events)")
        check(
            "close: the successor linger keeps painting the departed rect",
            curtain.hasLinger && lastOut.contains { $0.id == 6320 },
            "out=\(lastOut)")
        frameRects([hitB])
        frameRects([hitB])
        check(
            "close: the successor's own curtain ends the linger (`lift (successor curtained)`)",
            has("drop", 7100) && has("lift (successor curtained)", 6320)
                && !has("lift (successor clean", 6320) && !has("lift (successor ceiling", 6320),
            "events=\(events)")
        check(
            "close: nothing paints the departed rect once the successor is covered",
            !lastOut.contains { $0.id == 6320 }, "out=\(lastOut)")
        step(2, hits: false)
        closeSuccessor(7100)
        step(20, hits: false, dt: 0.1)
        events.removeAll()
        // F2 — signal 2: nothing ever drops on the successor, and the rect
        // reads clean for lingerCleanFrames AFTER the first frame that
        // actually carried the revealed window's pixels.
        redrop()
        openSuccessor(7101)
        frameRects([])
        frameRects([])
        check(
            "close: a benign revealed window still gets a successor linger",
            has("linger (successor 7101)", 6320), "events=\(events)")
        frameRects([])
        check(
            "close: the first evaluated frame after entry only marks the successor seen",
            !has("lift (successor", 6320) && lastOut.contains { $0.id == 6320 },
            "events=\(events) out=\(lastOut)")
        frameRects([])
        check(
            "close: one clean frame after that is still not enough",
            !has("lift (successor", 6320), "events=\(events)")
        frameRects([])
        check(
            "close: two clean frames lift it as `lift (successor clean, 2 frames)`",
            has("lift (successor clean, 2 frames)", 6320) && !curtain.hasLinger
                && !lastOut.contains { $0.id == 6320 },
            "events=\(events) out=\(lastOut)")
        step(2, hits: false)
        closeSuccessor(7101)
        step(20, hits: false, dt: 0.1)
        events.removeAll()
        // F3 — signal 3: the rect keeps reading blocked, so signal 2 never
        // arrives and the ceiling is what ends it. A ceiling, not a wait:
        // F1 and F2 both left long before it.
        redrop()
        openSuccessor(7102)
        frameRects([])
        frameRects([])
        check(
            "close: the ceiling case enters the successor linger the same way",
            has("linger (successor 7102)", 6320), "events=\(events)")
        let entered = t
        for _ in 0..<12 { frameRects([hit], dt: 0.05) }
        check(
            "close: blocked frames over the departed rect hold it to `lift (successor ceiling)`",
            has("lift (successor ceiling)", 6320) && !has("lift (successor clean", 6320)
                && !has("lift (successor curtained)", 6320),
            "events=\(events)")
        check(
            "close: the ceiling is successorLingerSecs, not a longer wall clock",
            t - entered <= Curtain.successorLingerSecs + 0.1 && !curtain.hasLinger,
            "held=\(t - entered)")
        check(
            "close: successorLingerSecs 0.5 s bounds the measured 0.387 s successor drop",
            Curtain.successorLingerSecs == 0.5)
        step(2, hits: false)
        closeSuccessor(7102)
        step(20, hits: false, dt: 0.1)
        events.removeAll()

        // MERGE BRIDGE (integration 2026-09-09): the parole blocks below ran
        // straight after the Dock-restore check on their own branch. The close
        // blocks above end with 6320 closed and on RETURN parole, so re-drop it
        // the same way those blocks do before asserting on the strip cover.
        redrop()

        // HARD CAP (receipt at Curtain.paroleHardCapSecs): a RETURN parolee
        // whose thumbnail stays listed re-stamps its aging clock every tick,
        // so only the cap can end it. Minimize again, then run the clock past
        // the cap WHILE the thumbnail stays listed (see the loop below).
        resizeChrome(CGRect(x: 16, y: 764, width: 82, height: 111))
        t = tick(Int(Curtain.subFloorLiftSecs / Pipeline.curtainTickSecs) + 3, from: t)
        check(
            "hard cap: the re-minimized window is strip-covered again (positive control)",
            has("lift (sub-floor)", 6320) && has("strip-cover on", 6320), "events=\(events)")
        events.removeAll()
        // The window STAYS in the strip the whole time, which is the only
        // state the cap exists for: every update re-stamps the entry's aging
        // clock (the strip-cover block), so `paroleSecs` never runs out and
        // only `paroleHardCapSecs` — read from the lift, immune to the
        // re-stamp — can end it. Advancing in ONE jump past both clocks (what
        // this check did before 2026-09-09) expires the entry through the
        // ordinary horizon instead and proves nothing about the cap.
        let capStep = Curtain.paroleHardCapSecs / 4
        for _ in 0..<5 {
            t += capStep
            _ = curtain.update(
                blockedScreenRects: [], tracker: windowTracker, display: screen, at: t,
                evaluated: false)
            windowTracker.setTracked(curtain.watchIDs)
            if has("parole hard cap", 6320) { break }
        }
        check(
            "hard cap: a CONTINUOUSLY strip-listed return parolee expires loudly at paroleHardCapSecs",
            has("parole hard cap", 6320) && has("strip-cover off", 6320) && !curtain.hasLinger,
            "events=\(events)")
        resizeChrome(big)
        Thread.sleep(forTimeInterval: 0.2)
        t = tick(3, from: t)
        check(
            "hard cap: the capped id does not re-drop from geometry on restore",
            !has("drop (parole return)", 6320) && !curtain.activeIDs.contains(6320),
            "events=\(events)")
        events.removeAll()

        // HIT-PAROLE HORIZON: a fresh episode, then hitParoleSecs pass with
        // no lift — the window is back on the full trigger.
        step(Curtain.triggerHits, hits: true)
        check(
            "parole horizon: a fresh curtain drops on the full trigger (no parole left)",
            events.contains { $0.0 == "drop" && $0.1 == 6320 }, "events=\(events)")
        step(Curtain.holdCleanFrames, hits: false, dt: 0.3)
        check(
            "parole horizon: the clean hold lifts and arms a fresh hit-parole episode",
            has("lift (hold", 6320) && !has("parole-churn", 6320), "events=\(events)")
        events.removeAll()
        step(1, hits: false, dt: Curtain.hitParoleSecs + 1)
        step(Curtain.paroleHits, hits: true)
        check(
            "parole horizon: past hitParoleSecs, paroleHits attributed hits do not drop",
            !curtain.activeIDs.contains(6320), "events=\(events)")
        step(Curtain.triggerHits - Curtain.paroleHits, hits: true)
        check(
            "parole horizon: past hitParoleSecs the drop is a plain trigger drop, not parole",
            events.contains { $0.0 == "drop" && $0.1 == 6320 } && !has("drop (parole", 6320),
            "events=\(events)")
        events.removeAll()

        // CROSS-ID SCOPE: hit parole matches by id only. Put 6320 on hit
        // parole, wait out liftGraceSecs (the handoff arm must not be what
        // lowers the bar), then a NEW front window at the same frame needs
        // the full trigger.
        step(Curtain.holdCleanFrames, hits: false, dt: 0.3)
        check(
            "cross-id: 6320 is on hit parole again",
            has("lift (hold", 6320), "events=\(events)")
        events.removeAll()
        step(1, hits: false, dt: Curtain.liftGraceSecs + 0.5)
        winsLock.lock()
        wins.insert(FakeWin(id: 7200, owner: "Google Chrome", rect: big), at: 0)
        winsLock.unlock()
        Thread.sleep(forTimeInterval: 0.2)
        step(Curtain.paroleHits, hits: true)
        check(
            "cross-id: a second window at a matching frame does not inherit hit parole",
            !curtain.activeIDs.contains(7200) && !has("drop", 7200) && !has("drop", 6320),
            "events=\(events)")
        step(Curtain.triggerHits - Curtain.paroleHits, hits: true)
        check(
            "cross-id: the second window drops on the full trigger",
            events.contains { $0.0 == "drop" && $0.1 == 7200 }, "events=\(events)")

        // Late-poll receipt (2026-09-02): cumulative AND windowed, and the
        // cumulative wording health_report.py parses is unchanged.
        windowTracker.stop()
        schedLock.lock()
        let finalSched = schedLines.last ?? ""
        schedLock.unlock()
        check(
            "sched: stop() emits the final scheduling receipt",
            finalSched.hasPrefix("-- windowTracker sched (final)"), "line=\(finalSched)")
        check(
            "sched: the cumulative pair keeps the wording health_report.py parses",
            finalSched.range(
                of: #"polls late \([0-9.]+%\), worst [0-9.]+ ms"#, options: .regularExpression)
                != nil, finalSched)
        check(
            "sched: the last-window late rate is printed alongside, named",
            finalSched.range(
                of: #"last window [0-9]+/[0-9]+ late \([0-9.]+%\)"#, options: .regularExpression)
                != nil, finalSched)
        // The close-pair pair (2026-09-08): the TOTAL is a cadence symptom and
        // the NEW-POSITION subset is the tripwire, so both have to be printed —
        // a single number here is what made the old "want 0" unactionable
        // (receipt at WindowTracker.closeSamples). Wording, not value: this case
        // scripts no drag, so the counts it produces are whatever this machine's
        // scheduler did during the case.
        check(
            "sched: the close-pair total AND its new-position subset are both named",
            finalSched.range(
                of: #"[0-9]+ ring samples closer than half a poll period, "#
                    + #"[0-9]+ of them a new position \(want 0\)"#,
                options: .regularExpression) != nil, finalSched)
    }

    /// Pause with a curtain up, then the next summaries must read
    /// `activeCovers 0`. A real Curtain over a fake window list is driven up
    /// by detector hits and its gauge written exactly as the curtain tick
    /// writes it; then the pause path's curtain reset (`Pipeline.resetCurtain`,
    /// called by `resetDetectState`) runs and no tick follows, as while paused.
    /// The summaries go through a live lean FrameLogger into a test-owned file.
    static func caseActiveCoversGauge(_ dir: String) {
        let fm = FileManager.default
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/run.jsonl"
        let logger = FrameLogger(path: path, quiet: true, mode: .lean, live: true)
        func lastSummaryCovers() -> Int? {
            guard let bytes = fm.contents(atPath: path) else { return nil }
            let rows = bytes.split(separator: 10).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
            return rows.last { $0["event"] as? String == "summary" }?["activeCovers"] as? Int
        }

        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let win = CGRect(x: 543, y: 213, width: 1172, height: 626)
        let windowTracker = WindowTracker()
        windowTracker.windowSource = {
            [[
                "kCGWindowNumber": CGWindowID(6320), "kCGWindowOwnerName": "Google Chrome",
                "kCGWindowLayer": 0, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": pid_t(1),
                "kCGWindowBounds": [
                    "X": win.minX, "Y": win.minY, "Width": win.width, "Height": win.height,
                ],
            ] as [String: Any]]
        }
        windowTracker.screenFrame = screen
        windowTracker.onReceipt = { _ in }
        windowTracker.start()
        defer { windowTracker.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        let curtain = Curtain()
        var t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<6 {
            t += 1.0 / 30
            let frames = curtain.update(
                blockedScreenRects: [CGRect(x: 900, y: 500, width: 120, height: 90)],
                tracker: windowTracker, display: screen, at: t)
            windowTracker.setTracked(curtain.watchIDs)
            logger.setActiveCovers(frames.count)  // as Pipeline.curtainRects does
        }
        logger.printSummary(elapsed: 60)
        check("active-covers: a painted curtain reads activeCovers 1 in the summary",
            curtain.activeIDs == [6320] && lastSummaryCovers() == 1,
            "active=\(curtain.activeIDs) covers=\(String(describing: lastSummaryCovers()))")

        Pipeline.resetCurtain(curtain, gauge: logger)
        logger.printSummary(elapsed: 60, state: "paused")
        let first = lastSummaryCovers()
        logger.printSummary(elapsed: 60, state: "paused")
        check("active-covers: pause with a curtain up, then every later summary reads 0",
            curtain.activeIDs.isEmpty && first == 0 && lastSummaryCovers() == 0,
            "active=\(curtain.activeIDs) first=\(String(describing: first)) "
                + "next=\(String(describing: lastSummaryCovers()))")
    }

    // MARK: 7c1 — capture-time attribution (owner report 2026-09-09)

    /// A clean window dragged across two stationary curtains must not earn
    /// a curtain from their boxes, and a blocked window sitting in front
    /// must still drop at `triggerHits`. Real ring, real clock: the fake
    /// window source is moved in 8.3 ms steps in wall time and every update
    /// is stamped with a capture time 100 ms in the past, the capture->walk
    /// lag the receipt at `Curtain.frontCandidateSecs` describes. Boxes are
    /// the curtained window's content just AHEAD of the dragged window at
    /// capture time — which the dragged window covers by walk time.
    static func caseCurtainAttributionAtCapture() {
        struct FakeWin {
            var id: CGWindowID
            var rect: CGRect
        }
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let aRect = CGRect(x: 300, y: 100, width: 500, height: 700)
        let bRect = CGRect(x: 900, y: 100, width: 500, height: 700)
        let cSize = CGSize(width: 300, height: 800)
        let aID: CGWindowID = 7001, bID: CGWindowID = 7002, cID: CGWindowID = 7003
        let lag: CFTimeInterval = 0.1
        let speed: CGFloat = 900
        let stepSecs: CFTimeInterval = 1.0 / 120
        let frameSecs: CFTimeInterval = 1.0 / 30

        func rig(_ wins: [FakeWin]) -> (
            WindowTracker, Curtain, () -> [(String, CGWindowID)], (CGWindowID, CGRect) -> Void,
            ([CGRect], CFAbsoluteTime) -> Void, () -> Void
        ) {
            let lock = NSLock()
            var rows = wins
            let tracker = WindowTracker()
            tracker.windowSource = {
                lock.lock()
                defer { lock.unlock() }
                return rows.map { w in
                    [
                        "kCGWindowNumber": w.id, "kCGWindowOwnerName": "Google Chrome",
                        "kCGWindowLayer": 0, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": pid_t(1),
                        "kCGWindowBounds": [
                            "X": w.rect.minX, "Y": w.rect.minY,
                            "Width": w.rect.width, "Height": w.rect.height,
                        ],
                    ] as [String: Any]
                }
            }
            tracker.screenFrame = screen
            tracker.onReceipt = { _ in }
            tracker.start()
            let curtain = Curtain()
            var events: [(String, CGWindowID)] = []
            curtain.onChange = { events.append(($0, $1)) }
            let move: (CGWindowID, CGRect) -> Void = { id, r in
                lock.lock()
                if let i = rows.firstIndex(where: { $0.id == id }) {
                    rows[i].rect = r
                } else {
                    rows.insert(FakeWin(id: id, rect: r), at: 0)
                }
                lock.unlock()
            }
            let update: ([CGRect], CFAbsoluteTime) -> Void = { boxes, t in
                _ = curtain.update(
                    blockedScreenRects: boxes, tracker: tracker, display: screen, at: t)
                tracker.setTracked(curtain.watchIDs)
            }
            return (tracker, curtain, { events }, move, update, { tracker.stop() })
        }
        func content(_ f: CGRect) -> CGRect { Curtain.contentRect(window: f, display: screen) }
        func has(_ events: [(String, CGWindowID)], _ prefix: String, _ id: CGWindowID) -> Bool {
            events.contains { $0.0.hasPrefix(prefix) && $0.1 == id }
        }
        // A 60 pt strip of `win`'s content immediately ahead (to the right)
        // of `c`, or nil when `c` is not inside `win`'s content there.
        func aheadBox(_ c: CGRect, in win: CGRect) -> CGRect? {
            let box = CGRect(x: c.maxX, y: content(win).minY + 40, width: 60,
                             height: content(win).height - 80).intersection(content(win))
            return box.isNull || box.width < 30 ? nil : box
        }
        // Curtain A and B first: boxes inside both, C far left and topmost.
        func curtainBoth(_ update: ([CGRect], CFAbsoluteTime) -> Void, _ t: inout CFAbsoluteTime) {
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: frameSecs)
                t = CFAbsoluteTimeGetCurrent() - lag
                update([content(aRect).insetBy(dx: 100, dy: 100),
                        content(bRect).insetBy(dx: 100, dy: 100)], t)
            }
        }
        // Drag C from x0 to x1 at `speed`, one window commit per 8.3 ms,
        // one detector frame per 33 ms stamped `lag` in the past.
        func drag(_ move: (CGWindowID, CGRect) -> Void, _ update: ([CGRect], CFAbsoluteTime) -> Void,
                  from x0: CGFloat, to x1: CGFloat) {
            var cx = x0
            var steps = 0
            let t0 = CFAbsoluteTimeGetCurrent()
            while cx < x1 {
                cx = min(x1, cx + speed * CGFloat(stepSecs))
                move(cID, CGRect(origin: CGPoint(x: cx, y: 50), size: cSize))
                steps += 1
                // Sleep to the schedule, not a fixed amount: keeps the
                // commanded speed honest when the poll thread steals time.
                let due = t0 + Double(steps) * stepSecs
                let now = CFAbsoluteTimeGetCurrent()
                if due > now { Thread.sleep(forTimeInterval: due - now) }
                if steps % 4 == 0 {
                    let tc = CFAbsoluteTimeGetCurrent() - lag
                    let cThen = CGRect(
                        origin: CGPoint(x: cx - speed * CGFloat(lag), y: 50), size: cSize)
                    let boxes = [aheadBox(cThen, in: aRect), aheadBox(cThen, in: bRect)]
                        .compactMap { $0 }
                    update(boxes, tc)
                }
            }
        }

        // 1. C topmost from the start: its ring is mature before it reaches a
        // box (frontCandidate), so nothing is ever credited on a young ring.
        do {
            let cStart = CGRect(origin: CGPoint(x: -350, y: 50), size: cSize)
            let (_, curtain, events, move, update, stop) = rig([
                FakeWin(id: cID, rect: cStart), FakeWin(id: aID, rect: aRect),
                FakeWin(id: bID, rect: bRect),
            ])
            var t = CFAbsoluteTimeGetCurrent()
            Thread.sleep(forTimeInterval: 0.1)
            curtainBoth(update, &t)
            check("attribution: A and B curtain with C clean in front, off to the side",
                  has(events(), "drop", aID) && has(events(), "drop", bID) && !has(events(), "drop", cID),
                  "events=\(events())")
            check("attribution: the topmost clean window is polled before its first box",
                  curtain.frontCandidateID == cID && curtain.watchIDs.contains(cID),
                  "candidate=\(String(describing: curtain.frontCandidateID)) watch=\(curtain.watchIDs)")
            _ = curtain.takeAttributionCounters()
            drag(move, update, from: -350, to: 1450)
            let ev = events()
            let counters = curtain.takeAttributionCounters()
            check("attribution: a clean window dragged across two stationary curtains earns no curtain",
                  !has(ev, "drop", cID), "events=\(ev)")
            check("attribution: neither curtain lifts during the drag",
                  !has(ev, "lift", aID) && !has(ev, "lift", bID), "events=\(ev)")
            check("attribution: at least one attribution-rewind names the curtain the hit belonged to",
                  ev.contains { $0.0.hasPrefix("attribution-rewind (hit at capture") && $0.1 == cID
                      && ($0.0.contains("curtain \(aID)") || $0.0.contains("curtain \(bID)")) },
                  "events=\(ev)")
            check("attribution: a mature ring never falls back to the live frame",
                  counters.ringYoungCredited == 0 && counters.ringYoungMoved == 0, "\(counters)")
            stop()
        }

        // 2. C appears and moves in the same instant (not topmost before):
        // the first sighting is credited as before, every young-ring walk
        // after it sees a moved window and is not, and the ring takes over.
        do {
            let (_, curtain, events, move, update, stop) = rig([
                FakeWin(id: aID, rect: aRect), FakeWin(id: bID, rect: bRect),
            ])
            var t = CFAbsoluteTimeGetCurrent()
            Thread.sleep(forTimeInterval: 0.1)
            curtainBoth(update, &t)
            _ = curtain.takeAttributionCounters()
            drag(move, update, from: 200, to: 1450)
            let ev = events()
            let counters = curtain.takeAttributionCounters()
            check("attribution: a window that appears mid-motion is credited at most its first sighting",
                  counters.ringYoungCredited <= 1 && counters.ringYoungMoved >= 1, "\(counters)")
            check("attribution: ... and still earns no curtain",
                  !has(ev, "drop", cID) && has(ev, "attribution-rewind", cID), "events=\(ev)")
            stop()
        }

        // 3. FALSIFIER: a blocked window sitting still in front of A, boxes
        // inside its own rect from its first frame, drops at triggerHits.
        do {
            let cRect = CGRect(x: 400, y: 150, width: 400, height: 500)
            let (_, curtain, events, _, update, stop) = rig([
                FakeWin(id: cID, rect: cRect), FakeWin(id: aID, rect: aRect),
                FakeWin(id: bID, rect: bRect),
            ])
            var t = CFAbsoluteTimeGetCurrent()
            Thread.sleep(forTimeInterval: 0.1)
            for _ in 0..<Curtain.triggerHits {
                Thread.sleep(forTimeInterval: frameSecs)
                t = CFAbsoluteTimeGetCurrent() - lag
                update([content(cRect).insetBy(dx: 60, dy: 60)], t)
            }
            check("attribution: a still blocked window in front drops within triggerHits frames",
                  has(events(), "drop", cID) && !has(events(), "drop", aID), "events=\(events())")
            stop()
        }
    }

    // MARK: 7c2 — curtain handoff, both directions

    /// Both arms of `Curtain.inheritsTrust`, scripted end to end against a
    /// real `WindowTracker` ring (the same rig `caseCurtain` uses), plus the
    /// two negatives that keep the restore arm narrow. Each transition gets a
    /// fresh tracker and curtain, so nothing carries between assertions.
    static func caseCurtainHandoffDirections() {
        struct FakeWin {
            var id: CGWindowID
            var rect: CGRect
        }
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowed = CGRect(x: 543, y: 213, width: 1172, height: 626)
        // A fullscreen EXIT's successor: above minCurtainSize, inside the
        // departing display-sized frame, and further than paroleMatchPt from
        // `windowed` on every edge, so no parole path can explain its drop.
        let restored = CGRect(x: 80, y: 640, width: 620, height: 340)
        // A window that merely sits inside a NON-display-scale predecessor.
        let inside = CGRect(x: 600, y: 300, width: 500, height: 300)
        // A second window revealed by the same fullscreen exit, disjoint from
        // `restored` so each successor's hits attribute to one window only.
        let bystander = CGRect(x: 1000, y: 100, width: 620, height: 340)

        /// Script one transition. Window 6320 wears `first` and earns a full
        /// trigger curtain; then each of `successors` appears in turn as a new
        /// id (in front of everything, and of 6320, which is removed from the
        /// list unless `predecessorStays`) and feeds hits inside its own frame.
        /// Returns each successor's drop label and how many hits it needed, or
        /// nil where it never dropped inside the step budget.
        func transition(
            first: CGRect, successors: [CGRect], predecessorStays: Bool = false
        ) -> [(label: String, hits: Int)?] {
            let lock = NSLock()
            var wins = [FakeWin(id: 6320, rect: first)]
            func rows() -> [[String: Any]] {
                lock.lock()
                defer { lock.unlock() }
                return wins.map { w in
                    [
                        "kCGWindowNumber": w.id,
                        "kCGWindowOwnerName": "Google Chrome",
                        "kCGWindowLayer": 0,
                        "kCGWindowAlpha": 1.0,
                        "kCGWindowOwnerPID": pid_t(1),
                        "kCGWindowBounds": [
                            "X": w.rect.minX, "Y": w.rect.minY,
                            "Width": w.rect.width, "Height": w.rect.height,
                        ],
                    ] as [String: Any]
                }
            }
            let tracker = WindowTracker()
            tracker.windowSource = rows
            tracker.screenFrame = screen
            // Sink the scheduler receipts (same reason as caseCurtain): they
            // are stderr noise here and interleave with the check lines.
            tracker.onReceipt = { _ in }
            tracker.start()
            defer { tracker.stop() }
            let curtain = Curtain()
            var events: [(String, CGWindowID)] = []
            curtain.onChange = { events.append(($0, $1)) }
            var t = CFAbsoluteTimeGetCurrent()
            func box(_ f: CGRect) -> CGRect {
                CGRect(x: f.midX - 60, y: f.midY - 45, width: 120, height: 90)
            }
            func step(_ hit: CGRect) {
                t += 1.0 / 30
                _ = curtain.update(
                    blockedScreenRects: [hit], tracker: tracker, display: screen, at: t)
                tracker.setTracked(curtain.watchIDs)
            }
            Thread.sleep(forTimeInterval: 0.1)
            for _ in 0..<(Curtain.triggerHits + 1) { step(box(first)) }
            guard events.contains(where: { $0.0 == "drop" && $0.1 == 6320 }) else {
                return successors.map { _ in nil }
            }
            var out: [(label: String, hits: Int)?] = []
            var live = predecessorStays ? [FakeWin(id: 6320, rect: first)] : []
            for (i, second) in successors.enumerated() {
                let sid = CGWindowID(7100 + i)
                lock.lock()
                live.insert(FakeWin(id: sid, rect: second), at: 0)
                wins = live
                lock.unlock()
                // Let the 120 Hz ring build the miss streak that IS "unlisted"
                // (Curtain.unlistedSecs = 50 ms of wall clock). The synthetic clock
                // `t` advances only 1/30 s per step, so the predecessor stays
                // dead-PENDING (deadLiftSecs = 1.5 s) — and so inside the
                // restore arm's own window (`Curtain.restoreArmed`) — for the
                // whole accumulation, successors included.
                Thread.sleep(forTimeInterval: 0.15)
                events.removeAll()
                // Budget, not a bar: when the predecessor is in transition the
                // walk runs every frame (`transitionActive`), so steps == hits
                // and the counts below are exact. The healthy-predecessor
                // negative has no bypass until its first attributed hit, so it
                // needs the walkEvery slack and only its LABEL is asserted.
                var landed: (label: String, hits: Int)?
                for step2 in 1...(Curtain.triggerHits * curtain.walkEvery + 2) {
                    step(box(second))
                    if let drop = events.first(where: { $0.0.hasPrefix("drop") && $0.1 == sid }) {
                        landed = (drop.0, step2)
                        break
                    }
                }
                out.append(landed)
            }
            return out
        }

        let enter = transition(first: windowed, successors: [screen]).first!
        check(
            "handoff contain: a fullscreen successor inherits at handoffHits",
            enter?.label == "drop (handoff)" && enter?.hits == Curtain.handoffHits,
            "result=\(String(describing: enter))")

        // The exit, then a SECOND window revealed by the same exit: the
        // breadth cap (`Curtain.restoreFree`) spends one grant per departing
        // predecessor, so the bystander pays the full trigger.
        let exit = transition(first: screen, successors: [restored, bystander])
        check(
            "handoff restore: the successor of a departing fullscreen curtain "
                + "inherits at handoffHits",
            exit[0]?.label == "drop (handoff restore)"
                && exit[0]?.hits == Curtain.handoffHits,
            "result=\(String(describing: exit[0]))")
        check(
            "handoff restore: one grant per departing predecessor — the second "
                + "window revealed by the same exit pays triggerHits",
            exit[1]?.label == "drop" && exit[1]?.hits == Curtain.triggerHits,
            "result=\(String(describing: exit[1]))")

        // NEGATIVE 1 — the display-scale guard. A window inside a departing
        // ORDINARY window earns nothing: reverse containment without it would
        // arm on every window close (receipt at Curtain.restoreShaped).
        let ordinary = transition(first: windowed, successors: [inside])[0]
        check(
            "handoff restore: a departing non-fullscreen predecessor grants no trust",
            ordinary?.label == "drop" && ordinary?.hits == Curtain.triggerHits,
            "result=\(String(describing: ordinary))")

        // NEGATIVE 2 — the leaving guard, the restore-side mirror of the owner
        // Gmail false positive: a HEALTHY fullscreen curtain that is still
        // listed grants no trust to the windows in front of it.
        let healthy = transition(first: screen, successors: [restored], predecessorStays: true)[0]
        check(
            "handoff restore: a healthy listed fullscreen curtain grants no trust",
            healthy?.label == "drop",
            "result=\(String(describing: healthy))")

        for tier in PerfTier.all {
            let ms = Curtain.handoffSavedMs(fps: tier.fps)
            check(
                "tier \(tier.name.rawValue): an inherited hit is worth one detector frame "
                    + String(format: "(%.0f ms at %d fps)", ms, tier.fps),
                abs(ms - 1000.0 / Double(tier.fps)) < 1e-9, "\(ms)")
        }
        check(
            "handoff: the contain and restore bars are the same number of hits",
            Curtain.handoffHits == 2 && Curtain.triggerHits == 3)
    }

    // MARK: 7f — expansion cap re-arm cooldown (curtain-loop finding)

    /// The transition shield is a FULL-DISPLAY cover, and `expansionCapSecs`
    /// was supposed to bound it. It did not: `extendExpansion` removed the
    /// capped entry and the very next walk re-armed it with a fresh clock,
    /// so persistent orphan evidence held the shield ~99% of the time with a
    /// one-frame blink every cap (scenario `curtain-expansion-cap`). This
    /// case drives the real state machine headlessly through that shape —
    /// a window whose bounds the window server reports MALFORMED is skipped
    /// by the ownership snapshot (every detection over it is shield-grade
    /// orphan evidence) while its miss cause is not `.unknownID`, so it is
    /// "currently unlisted" without ever being dead-lifted: the shield's
    /// evidence never clears on its own.
    static func caseCurtainExpansionCapRearm() {
        check(
            "expansion cap: the re-arm cooldown is liftGraceSecs — this file's "
                + "measured \"a transition can still be in flight\" interval",
            Curtain.expansionRearmCooldownSecs == Curtain.liftGraceSecs,
            "cooldown=\(Curtain.expansionRearmCooldownSecs) "
                + "liftGraceSecs=\(Curtain.liftGraceSecs)")
        let dutyBound = Curtain.expansionCapSecs
            / (Curtain.expansionCapSecs + Curtain.expansionRearmCooldownSecs)
        check(
            "expansion cap: cap + cooldown bound the shield below 70% duty by arithmetic",
            dutyBound < 0.70, String(format: "bound=%.2f", dutyBound))

        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let big = CGRect(x: 400, y: 200, width: 1000, height: 600)
        let hit = CGRect(x: 700, y: 400, width: 120, height: 90)
        let winID: CGWindowID = 7001
        let boundsLock = NSLock()
        var boundsListed = true
        func rows() -> [[String: Any]] {
            boundsLock.lock()
            let listed = boundsListed
            boundsLock.unlock()
            // A malformed bounds dictionary is one of WindowTracker's three
            // failure shapes (PollOutcome.malformed): the row exists, so the
            // id is not `.unknownID` and `isDead` stays false, but neither
            // the snapshot nor the per-id poll can place it.
            let bounds: [String: Any] = listed
                ? ["X": big.minX, "Y": big.minY, "Width": big.width, "Height": big.height]
                : ["Unparseable": 1]
            return [
                [
                    "kCGWindowNumber": winID,
                    "kCGWindowOwnerName": "Google Chrome",
                    "kCGWindowLayer": 0,
                    "kCGWindowAlpha": 1.0,
                    "kCGWindowOwnerPID": pid_t(1),
                    "kCGWindowBounds": bounds,
                ] as [String: Any]
            ]
        }
        let tracker = WindowTracker()
        tracker.windowSource = rows
        tracker.screenFrame = screen
        tracker.start()
        defer { tracker.stop() }
        let curtain = Curtain()
        var events: [(String, CGWindowID)] = []
        curtain.onChange = { events.append(($0, $1)) }
        var t = CFAbsoluteTimeGetCurrent()
        let dt: CFTimeInterval = 1.0 / 30
        var painted: [(t: CFAbsoluteTime, frame: CGRect?)] = []
        func step(_ count: Int) {
            for _ in 0..<count {
                t += dt
                let out = curtain.update(
                    blockedScreenRects: [hit], tracker: tracker, display: screen, at: t)
                painted.append((t, out.first { $0.id == winID }?.frame))
                tracker.setTracked(curtain.watchIDs)
            }
        }
        func count(_ prefix: String) -> Int {
            events.filter { $0.0.hasPrefix(prefix) && $0.1 == winID }.count
        }

        Thread.sleep(forTimeInterval: 0.1)
        step(Curtain.triggerHits + 1)
        check(
            "expansion cap: the scripted window earns an ordinary curtain first",
            curtain.activeIDs.contains(winID) && painted.last?.frame == big,
            "events=\(events) painted=\(String(describing: painted.last?.frame))")

        // The window server starts reporting bounds nobody can parse.
        boundsLock.lock()
        boundsListed = false
        boundsLock.unlock()
        Thread.sleep(forTimeInterval: 0.15)
        check(
            "expansion cap: the malformed window reads as unlisted but NOT dead, "
                + "so no lift can clear the orphan evidence",
            tracker.missSeconds(of: winID) >= Curtain.unlistedSecs && !tracker.isDead(winID),
            "missSeconds=\(tracker.missSeconds(of: winID)) isDead=\(tracker.isDead(winID))")

        step(2)
        let shieldFrom = t
        check(
            "expansion cap: shield-grade orphan evidence arms the full-display shield",
            painted.last?.frame == screen, "painted=\(String(describing: painted.last?.frame))")

        // Past the cap with the orphan evidence never clearing.
        step(Int(Curtain.expansionCapSecs / dt) + 6)
        check(
            "expansion cap: the cap fires once and says so",
            count("expansion-cap") == 1, "events=\(events.map(\.0))")
        check(
            "expansion cap: the cap record names the budget, what was observed, and the fix",
            events.contains {
                $0.0.hasPrefix("expansion-cap") && $0.0.contains("4.5") && $0.0.contains("held")
                    && $0.0.contains("fix: Curtain.expansionCapSecs")
            }, "events=\(events.map(\.0))")
        check(
            "expansion cap: the shield actually comes down at the cap",
            painted.last?.frame == big, "painted=\(String(describing: painted.last?.frame))")
        // The frame the shield actually came down on, not the end of the
        // stepping loop — the down-time assertion below must not be paid a
        // few frames of slack it did not earn.
        let cappedAt = painted.first { $0.t > shieldFrom && $0.frame == big }?.t ?? t

        // Cooldown: the evidence is unchanged and every walk asks again.
        step(Int(Curtain.expansionRearmCooldownSecs / dt) - 12)
        let duringCooldown = painted.filter { $0.t > cappedAt }
        check(
            "expansion cap: the re-arm is REFUSED for the whole cooldown — no full-display "
                + "frame while the same evidence keeps asking",
            duringCooldown.allSatisfy { $0.frame == big },
            "fullDisplayFrames=\(duringCooldown.filter { $0.frame == screen }.count)")
        check(
            "expansion cap: the refusal is loud exactly once per cooldown, not once per walk",
            count("expansion-rearm refused") == 1, "events=\(events.map(\.0))")
        check(
            "expansion cap: the refusal record names its own budget and fix location",
            events.contains {
                $0.0.hasPrefix("expansion-rearm refused")
                    && $0.0.contains("expansionRearmCooldownSecs")
                    && $0.0.contains("fix: Curtain.expansionRearmCooldownSecs")
            }, "events=\(events.map(\.0))")

        // Past the cooldown the shield is allowed back: this is a bounded
        // duty cycle, not a permanent stand-down.
        step(24)
        let rearmedAt = painted.first { $0.t > cappedAt && $0.frame == screen }?.t
        check(
            "expansion cap: the shield re-arms once the cooldown has passed",
            rearmedAt != nil, "painted tail=\(painted.suffix(3).map { String(describing: $0.frame) })")
        check(
            "expansion cap: the shield stayed down for at least the full cooldown",
            (rearmedAt ?? 0) - cappedAt >= Curtain.expansionRearmCooldownSecs,
            String(format: "down=%.2f s", (rearmedAt ?? 0) - cappedAt))

        // One more full cycle, then the measured duty over the whole
        // sustained-orphan window — the number the finding is about.
        step(Int((Curtain.expansionCapSecs + Curtain.expansionRearmCooldownSecs) / dt))
        let sustained = painted.filter { $0.t >= shieldFrom }
        let duty = Double(sustained.filter { $0.frame == screen }.count)
            / Double(max(sustained.count, 1))
        check(
            "expansion cap: MEASURED shield duty under sustained orphan evidence is bounded "
                + "(was ~99% before the cooldown)",
            duty < 0.75, String(format: "duty=%.2f over %d frames", duty, sustained.count))
        check(
            "expansion cap: the cycle repeats — a second cap and a second refusal, "
                + "each announced once",
            count("expansion-cap") == 2 && count("expansion-rearm refused") == 2,
            "events=\(events.map(\.0))")
        print(String(
            format: "EXPANSION_CAP_RECEIPT: duty=%.3f frames=%d shieldDownSecs=%.2f",
            duty, sustained.count, (rearmedAt ?? 0) - cappedAt))
        check(
            "expansion cap: the curtain over the named window never stopped painting",
            sustained.allSatisfy { $0.frame != nil },
            "unpaintedFrames=\(sustained.filter { $0.frame == nil }.count)")
        check(
            "expansion cap: no bridge was ever refused in this fixture",
            !events.contains { $0.0.contains("expansion-rearm refused: bridge") },
            "events=\(events.map(\.0))")

        expansionBridgeSurvivesShieldCap()
    }

    /// `extendExpansion` has TWO callers and one cooldown (review 2026-09-09):
    /// the transition SHIELD (full display, unnameable evidence) and the
    /// transition BRIDGE (one named successor's frame, so cover is continuous
    /// while the successor accumulates hits). The cooldown's receipt priced
    /// the shield only, so a shield-fired cap must NOT also refuse the
    /// bridge — that would leave a real successor window uncovered for 2.0 s
    /// of a transition, an exposure nobody measured. This fixture drives a
    /// shield to its cap, then, still inside the cooldown, presents a
    /// successor with its own hit plus orphan evidence that keeps asking for
    /// the shield: the bridge must be granted and the shield must stay
    /// refused, in the same walk.
    private static func expansionBridgeSurvivesShieldCap() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let pred = CGRect(x: 400, y: 200, width: 1000, height: 600)
        // Contains `pred` with room for the 8 pt handoff tolerance, and is
        // far from full-display — so "bridge granted" and "shield granted"
        // are distinguishable by the painted frame alone.
        let succ = CGRect(x: 380, y: 180, width: 1040, height: 640)
        let predHit = CGRect(x: 700, y: 400, width: 120, height: 90)
        // Outside `succ`, so it stays shield-grade orphan evidence even once
        // the successor is listed: the shield keeps asking during the cooldown.
        let orphanHit = CGRect(x: 1600, y: 860, width: 120, height: 90)
        let predID: CGWindowID = 7101
        let succID: CGWindowID = 7102
        let rowsLock = NSLock()
        var predListed = true
        var succListed = false
        func rows() -> [[String: Any]] {
            rowsLock.lock()
            let (p, s) = (predListed, succListed)
            rowsLock.unlock()
            var out: [[String: Any]] = []
            if s {
                out.append([
                    "kCGWindowNumber": succID,
                    "kCGWindowOwnerName": "Google Chrome",
                    "kCGWindowLayer": 0,
                    "kCGWindowAlpha": 1.0,
                    "kCGWindowOwnerPID": pid_t(1),
                    "kCGWindowBounds": [
                        "X": succ.minX, "Y": succ.minY,
                        "Width": succ.width, "Height": succ.height,
                    ],
                ] as [String: Any])
            }
            let bounds: [String: Any] = p
                ? ["X": pred.minX, "Y": pred.minY, "Width": pred.width, "Height": pred.height]
                : ["Unparseable": 1]
            out.append([
                "kCGWindowNumber": predID,
                "kCGWindowOwnerName": "Google Chrome",
                "kCGWindowLayer": 0,
                "kCGWindowAlpha": 1.0,
                "kCGWindowOwnerPID": pid_t(1),
                "kCGWindowBounds": bounds,
            ] as [String: Any])
            return out
        }
        let tracker = WindowTracker()
        tracker.windowSource = rows
        tracker.screenFrame = screen
        tracker.start()
        defer { tracker.stop() }
        let curtain = Curtain()
        var events: [(String, CGWindowID)] = []
        curtain.onChange = { events.append(($0, $1)) }
        var t = CFAbsoluteTimeGetCurrent()
        let dt: CFTimeInterval = 1.0 / 30
        var painted: [CGRect?] = []
        func step(_ count: Int, _ blocked: [CGRect]) {
            for _ in 0..<count {
                t += dt
                let out = curtain.update(
                    blockedScreenRects: blocked, tracker: tracker, display: screen, at: t)
                painted.append(out.first { $0.id == predID }?.frame)
                tracker.setTracked(curtain.watchIDs)
            }
        }

        Thread.sleep(forTimeInterval: 0.1)
        step(Curtain.triggerHits + 1, [predHit])
        rowsLock.lock()
        predListed = false
        rowsLock.unlock()
        Thread.sleep(forTimeInterval: 0.15)
        step(2, [predHit])
        check(
            "expansion bridge: the shield is up before the cap (fixture precondition)",
            painted.last == screen, "painted=\(String(describing: painted.last))")
        step(Int(Curtain.expansionCapSecs / dt) + 6, [predHit])
        check(
            "expansion bridge: the cap fired and the shield came down (fixture precondition)",
            events.contains { $0.0.hasPrefix("expansion-cap") && $0.1 == predID }
                && painted.last == pred,
            "painted=\(String(describing: painted.last)) events=\(events.map(\.0))")
        let capIndex = painted.count

        // Still inside the cooldown: a successor appears with its own hit,
        // and unnameable evidence keeps asking for the shield.
        rowsLock.lock()
        succListed = true
        rowsLock.unlock()
        Thread.sleep(forTimeInterval: 0.15)
        step(3, [predHit, orphanHit])
        let afterSucc = painted[capIndex...]
        check(
            "expansion bridge: a shield cap does NOT refuse the bridge — the successor's "
                + "frame is unioned in while the cooldown is still running",
            painted.last == pred.union(succ) && painted.last != screen,
            "painted=\(String(describing: painted.last)) succ=\(succ)")
        check(
            "expansion bridge: the shield stayed refused through the same walks — no "
                + "full-display frame after the cap",
            !afterSucc.contains(screen),
            "fullDisplayFrames=\(afterSucc.filter { $0 == screen }.count)")
        check(
            "expansion bridge: the shield refusal is the one that was announced, and it "
                + "names its kind",
            events.contains {
                $0.0.hasPrefix("expansion-rearm refused: shield") && $0.1 == predID
            } && !events.contains { $0.0.contains("expansion-rearm refused: bridge") },
            "events=\(events.map(\.0))")
        check(
            "expansion bridge: the cap record names both budgets and both fix locations",
            events.contains {
                $0.0.hasPrefix("expansion-cap")
                    && $0.0.contains("fix: Curtain.expansionCapSecs")
                    && $0.0.contains("fix: Curtain.expansionRearmCooldownSecs")
            }, "events=\(events.map(\.0))")
    }

    // MARK: 7d — chrome strip geometry and region suppression

    /// The two mechanisms re-applied on 2026-08-28 from the
    /// debug/curtain-failure evidence: `defaultChromeStripPt` = 80 (MEASURED,
    /// owner saw page content under the toolbar at 96) and the one-way read of
    /// curtain-painted rects by the region pipeline (MEASURED, 34 layers and
    /// 14 overlay-count tripwires under a single curtain). Neither source
    /// commit carried a test; these are new. Pure geometry — no window
    /// server, no capture.
    static func caseCurtainStripAndSuppression() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // COVER LABEL LADDER (2026-09-09, receipt at RegionLayer.labelLadder):
        // measured at runtime, longest that fits, never outside the rect.
        let longLabel = RegionLayer.labelSizes.first!.size
        let shortLabel = RegionLayer.labelSizes.last!.size
        let pad = 2 * RegionLayer.labelPadPt
        check(
            "cover label: the ladder is measured, not hardcoded (long ~102 pt, short ~50 pt at 13 pt medium)",
            (90...115).contains(longLabel.width) && (40...60).contains(shortLabel.width)
                && longLabel.width > shortLabel.width,
            "long=\(longLabel) short=\(shortLabel)")
        check(
            "cover label: a 1172 pt wide cover reads \"Content blocked\"",
            RegionLayer.labelText(forWidth: 1172, height: 626) == "Content blocked")
        check(
            "cover label: the 92x129 pt strip thumbnail reads \"Blocked\"",
            RegionLayer.labelText(forWidth: 92, height: 129) == "Blocked")
        check(
            "cover label: the measured 101x121 pt strip thumbnail reads \"Blocked\"",
            RegionLayer.labelText(forWidth: 101, height: 121) == "Blocked")
        check(
            "cover label: narrower than the short form plus its margin hides the label",
            RegionLayer.labelText(forWidth: shortLabel.width + pad - 1, height: 129) == nil)
        check(
            "cover label: shorter than one line plus its margin hides the label",
            RegionLayer.labelText(forWidth: 400, height: shortLabel.height + pad - 1) == nil)
        var inside = true
        for w in stride(from: 20, through: 400, by: 1) {
            if let text = RegionLayer.labelText(forWidth: CGFloat(w), height: 129),
                let s = RegionLayer.labelSizes.first(where: { $0.text == text })?.size,
                s.width + pad > CGFloat(w) {
                inside = false
                break
            }
        }
        check("cover label: invariant — the chosen label always fits inside the cover", inside)
        // CURTAIN HINT (owner 2026-10-18): whole-window covers lead with the
        // way out; region covers never show it; narrow curtains fall back.
        let hint = RegionLayer.curtainLabelSizes.first!.size
        check("cover label: a 1172 pt curtain reads the ⌘W hint",
            RegionLayer.labelText(forWidth: 1172, height: 626, curtain: true) == RegionLayer.curtainHint,
            "hint=\(hint)")
        check("cover label: a 1172 pt region cover never reads the hint",
            RegionLayer.labelText(forWidth: 1172, height: 626) == "Content blocked")
        check("cover label: a curtain too narrow for the hint falls back to \"Content blocked\"",
            RegionLayer.labelText(forWidth: hint.width + pad - 1, height: 626, curtain: true) == "Content blocked")
        check("cover label: the hint says ⌘W, never ⌘Q",
            RegionLayer.curtainHint.contains("⌘W") && !RegionLayer.curtainHint.contains("⌘Q"))
        var curtainInside = true
        for w in stride(from: 20, through: 800, by: 1) {
            if let text = RegionLayer.labelText(forWidth: CGFloat(w), height: 129, curtain: true),
                let s = RegionLayer.curtainLabelSizes.first(where: { $0.text == text })?.size,
                s.width + pad > CGFloat(w) {
                curtainInside = false
                break
            }
        }
        check("cover label: invariant — a curtain's chosen label always fits inside it", curtainInside)
        // The SOURCE DEFAULT, not the live `chromeStripPt`: main.swift applies
        // `--config` (~263) and `--curtain-strip` (~344) before it dispatches
        // `--ui-selftest` (~2016), so the mutable var here is whatever the
        // operator passed. `defaultChromeStripPt` is the `let` that carries
        // the MEASURED receipt and is the thing this check is about.
        check(
            "curtain strip: the shipped default is the MEASURED 80 pt, not the old 96",
            Curtain.defaultChromeStripPt == 80,
            "defaultChromeStripPt=\(Curtain.defaultChromeStripPt) "
                + "live chromeStripPt=\(Curtain.chromeStripPt)")

        // The window the 2026-08-26 luminance probe measured: toolbar ends
        // ~100 pt down, so an 80 pt strip leaves the curtain edge inside it.
        let chrome = CGRect(x: 200, y: 100, width: 1410, height: 829)
        let cut = Curtain.contentRect(window: chrome, display: display)
        check(
            "curtain strip: a Chrome-sized window is cut by exactly chromeStripPt from the top",
            cut.minY == chrome.minY + Curtain.chromeStripPt
                && cut.height == chrome.height - Curtain.chromeStripPt
                && cut.minX == chrome.minX && cut.width == chrome.width,
            "cut=\(cut)")

        // Fullscreen bypass (2026-08-20 owner test) is untouched by the value.
        check(
            "curtain strip: a fullscreen window keeps no visible strip",
            Curtain.contentRect(window: display, display: display) == display)

        // DERIVED consequence of the DEFAULT moving 96 -> 80: contentRect's
        // `height > 2 * strip` bail moved 192 -> 160 pt. Both sides are
        // asserted relative to the live `chromeStripPt`, so the boundary is
        // checked under an override too and a future strip change cannot move
        // it unnoticed.
        let short = CGRect(x: 0, y: 0, width: 900, height: 2 * Curtain.chromeStripPt)
        check(
            "curtain strip: a window no taller than twice the strip is covered whole",
            Curtain.contentRect(window: short, display: display) == short)
        let justOver = CGRect(x: 0, y: 0, width: 900, height: 2 * Curtain.chromeStripPt + 10)
        check(
            "curtain strip: a window just past twice the strip is strip-cut",
            Curtain.contentRect(window: justOver, display: display).height
                == justOver.height - Curtain.chromeStripPt)

        // Region suppression: normalized bottom-left on both sides.
        let painted = CGRect(x: 0.28, y: 0.20, width: 0.60, height: 0.50)
        func det(_ box: CGRect) -> Detection {
            Detection(label: "FEMALE_BREAST_EXPOSED", confidence: 0.9, box: box)
        }
        let under = det(CGRect(x: 0.45, y: 0.40, width: 0.10, height: 0.10))
        let inStrip = det(CGRect(x: 0.45, y: 0.74, width: 0.10, height: 0.10))
        let elsewhere = det(CGRect(x: 0.02, y: 0.05, width: 0.10, height: 0.10))
        let all = [under, inStrip, elsewhere]
        check(
            "region suppression: no curtain painted last step means no detection is filtered",
            Pipeline.regionInput(all, underCurtains: []).count == 3)
        let kept = Pipeline.regionInput(all, underCurtains: [painted])
        check(
            "region suppression: a detection centred inside the painted rect is dropped",
            !kept.contains { $0.box == under.box }, "kept=\(kept.map(\.box))")
        check(
            "region suppression: the visible chrome strip stays region-cover territory",
            kept.contains { $0.box == inStrip.box }, "kept=\(kept.map(\.box))")
        check(
            "region suppression: a detection outside every painted rect still earns a region",
            kept.contains { $0.box == elsewhere.box }, "kept=\(kept.map(\.box))")
        check(
            "region suppression: exactly one detection was suppressed, so the counter is honest",
            all.count - kept.count == 1, "kept=\(kept.count)")
    }

    // MARK: 7e — curtain-mode region-entry debounce (owner decision 2026-09-02)

    /// Region covers in curtain mode wait for a second consecutive detector
    /// frame before their first paint (receipt at `Tracker.curtainEntryFrames`);
    /// region/media modes keep SPEC §5.4's first-frame paint. Scripted
    /// detections, no pixels: a single-frame false positive, a two-frame
    /// confirmation, sustained content, and the one-frame cost per tier.
    /// The static-content gap (receipt at `Curtain.windowFrames`): at the
    /// ~1 frame/s a static screen is captured at, `triggerHits` evaluated
    /// frames cannot fit in `windowSecs` of wall clock. Scripted window,
    /// scripted clock, one blocked box per frame — the curtain must drop on
    /// the third evaluated frame at 1 fps exactly as it does at 30 fps, and
    /// the frame arm must keep the wall-clock arm's bound (hits spaced past
    /// the window never accumulate).
    static func caseCurtainStaticCadence() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let big = CGRect(x: 543, y: 213, width: 1172, height: 626)
        let rows: () -> [[String: Any]] = {
            [[
                "kCGWindowNumber": CGWindowID(18866),
                "kCGWindowOwnerName": "Google Chrome",
                "kCGWindowLayer": 0,
                "kCGWindowAlpha": 1.0,
                "kCGWindowOwnerPID": pid_t(1),
                "kCGWindowBounds": [
                    "X": big.minX, "Y": big.minY, "Width": big.width, "Height": big.height,
                ],
            ] as [String: Any]]
        }
        let hit = CGRect(x: 900, y: 500, width: 120, height: 90)
        // Each run gets its own tracker + curtain: the walk-bypass budget
        // and the hit ring are per-instance state.
        func run(dt: CFTimeInterval, pattern: [Bool], fps: Int = 30) -> (dropFrame: Int?, events: [String]) {
            let windowTracker = WindowTracker()
            windowTracker.windowSource = rows
            windowTracker.screenFrame = screen
            windowTracker.onReceipt = { _ in }
            windowTracker.start()
            defer { windowTracker.stop() }
            Thread.sleep(forTimeInterval: 0.1)
            let curtain = Curtain()
            curtain.walkEvery = Curtain.walkEvery(fps: fps)
            curtain.fps = fps
            var events: [String] = []
            curtain.onChange = { label, _ in events.append(label) }
            var t = CFAbsoluteTimeGetCurrent()
            var dropFrame: Int?
            for (i, hits) in pattern.enumerated() {
                t += dt
                let out = curtain.update(
                    blockedScreenRects: hits ? [hit] : [],
                    tracker: windowTracker, display: screen, at: t)
                windowTracker.setTracked(curtain.watchIDs)
                if dropFrame == nil, out.contains(where: { $0.id == 18866 }) { dropFrame = i + 1 }
            }
            return (dropFrame, events)
        }
        let fast = run(dt: 1.0 / 30, pattern: Array(repeating: true, count: 6))
        check("curtain: static cadence — 30 fps drops on evaluated frame 3 (reference)",
              fast.dropFrame == 3, "drop=\(String(describing: fast.dropFrame)) events=\(fast.events)")
        // THE GAP: 1 evaluated frame/s, blocked box on every frame.
        let slow = run(dt: 1.0, pattern: Array(repeating: true, count: 6))
        check("curtain: static cadence — 1 fps drops on evaluated frame 3, same bar as 30 fps",
              slow.dropFrame == 3, "drop=\(String(describing: slow.dropFrame)) events=\(slow.events)")
        let two = run(dt: 0.5, pattern: Array(repeating: true, count: 6))
        check("curtain: static cadence — 2 fps drops on evaluated frame 3",
              two.dropFrame == 3, "drop=\(String(describing: two.dropFrame)) events=\(two.events)")
        // FP margin, frame arm: one hit frame then clean frames never drops.
        let single = run(dt: 1.0, pattern: [true] + Array(repeating: false, count: 40))
        check("curtain: static cadence — a single hit frame at 1 fps never drops",
              single.dropFrame == nil, "drop=\(String(describing: single.dropFrame)) events=\(single.events)")
        // Bound of the frame arm: three hits spaced windowFrames + 1 evaluated
        // frames apart (each also past windowSecs) never accumulate.
        let gap = Curtain().windowFrames()
        var sparse: [Bool] = []
        for _ in 0..<3 { sparse.append(true); sparse.append(contentsOf: Array(repeating: false, count: gap)) }
        let spaced = run(dt: 1.0, pattern: sparse)
        check("curtain: static cadence — hits \(gap + 1) evaluated frames apart never accumulate",
              spaced.dropFrame == nil, "drop=\(String(describing: spaced.dropFrame)) events=\(spaced.events)")
        // Bound of the wall-clock arm is unchanged at full cadence: three
        // hits 1.1 s apart at 30 fps (33 ticks, past both arms) never drop.
        var wide: [Bool] = []
        for _ in 0..<3 { wide.append(true); wide.append(contentsOf: Array(repeating: false, count: 32)) }
        let wall = run(dt: 1.0 / 30, pattern: wide)
        check("curtain: static cadence — hits 1.1 s apart at 30 fps never accumulate (wall-clock arm unchanged)",
              wall.dropFrame == nil, "drop=\(String(describing: wall.dropFrame)) events=\(wall.events)")
        check("curtain: windowFrames is windowSecs at the configured rate (30 at 30 fps, 15 at 15 fps)",
              Curtain().windowFrames() == 30 && { let c = Curtain(); c.fps = 15; return c.windowFrames() }() == 15)
    }

    // MARK: 7c5 — a WindowServer refusal, a capture gap, and ordered attribution

    /// Three findings that had no test before 2026-09-11, driven headlessly against a real 120 Hz poll thread:
    ///
    ///  1. The standing complaint that nothing exercises a WindowServer
    ///     REFUSAL. `allWindowSource` returning nil is a refused `.optionAll`
    ///     snapshot. It used to arrive as `[]` — "the server knows no windows"
    ///     — which classified every dead-pending id `.destroyed`, a TERMINAL
    ///     verdict, and lifted its curtain on `lingerCleanFrames` clean frames
    ///     instead of holding for `deadLiftSecs`. A genuinely empty answer
    ///     (`[]`) is the positive control: that one still means destroyed.
    ///  2. Pending hit evidence must not survive a capture gap, so one
    ///     post-wake hit cannot drop a curtain on pre-sleep pixels.
    ///  3. Attribution among OVERLAPPING curtains is ordered (most
    ///     held, then id), not whatever order the Dictionary hash gave.
    static func caseWindowServerRefusal() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let big = CGRect(x: 543, y: 213, width: 1172, height: 626)
        let hit = CGRect(x: 900, y: 500, width: 120, height: 90)
        let wid: CGWindowID = 6320
        let winLock = NSLock()
        var listed = true
        enum AllMode { case answer, refuse, empty }
        var allMode = AllMode.answer
        func row() -> [String: Any] {
            [
                "kCGWindowNumber": wid,
                "kCGWindowOwnerName": "Google Chrome",
                "kCGWindowLayer": 0,
                "kCGWindowAlpha": 1.0,
                "kCGWindowOwnerPID": pid_t(1),
                "kCGWindowBounds": [
                    "X": big.minX, "Y": big.minY, "Width": big.width, "Height": big.height,
                ],
            ] as [String: Any]
        }
        func rows() -> [[String: Any]] {
            winLock.lock()
            defer { winLock.unlock() }
            return listed ? [row()] : []
        }
        func allRows() -> [[String: Any]]? {
            winLock.lock()
            defer { winLock.unlock() }
            switch allMode {
            case .refuse: return nil  // the window server did not answer
            case .empty: return []  // it answered: it knows no windows
            case .answer: return [row()]
            }
        }
        func set(listed newListed: Bool, all: AllMode) {
            winLock.lock()
            listed = newListed
            allMode = all
            winLock.unlock()
        }

        let tracker = WindowTracker()
        tracker.windowSource = rows
        tracker.allWindowSource = allRows
        tracker.screenFrame = screen
        tracker.onReceipt = { _ in }
        let tripLock = NSLock()
        var tripwires: [String] = []
        tracker.onTripwire = { line in
            tripLock.lock()
            tripwires.append(line)
            tripLock.unlock()
        }
        tracker.start()
        let curtain = Curtain()
        var events: [(String, CGWindowID)] = []
        curtain.onChange = { events.append(($0, $1)) }
        var t = CFAbsoluteTimeGetCurrent()
        func step(_ count: Int, hits: Bool, dt: CFTimeInterval = 1.0 / 30) {
            for _ in 0..<count {
                t += dt
                _ = curtain.update(
                    blockedScreenRects: hits ? [hit] : [], tracker: tracker,
                    display: screen, at: t)
                tracker.setTracked(curtain.watchIDs)
            }
        }
        func has(_ prefix: String) -> Bool { events.contains { $0.0.hasPrefix(prefix) } }
        func trips() -> [String] {
            tripLock.lock()
            defer { tripLock.unlock() }
            return tripwires
        }

        Thread.sleep(forTimeInterval: 0.1)
        step(Curtain.triggerHits + 1, hits: true)
        check(
            "refusal: the scripted window earns an ordinary curtain first",
            curtain.activeIDs.contains(wid), "events=\(events)")
        events.removeAll()

        // The window stops answering per-id polls AND the server refuses the
        // `.optionAll` list — the Space-transition / wake shape.
        set(listed: false, all: .refuse)
        Thread.sleep(forTimeInterval: 0.25)
        step(Curtain.lingerCleanFrames + 2, hits: false, dt: 0.1)
        check(
            "refusal: the id reads dead (an unknownID streak past deadSecs)",
            tracker.isDead(wid),
            "isDead=\(tracker.isDead(wid)) missSeconds=\(tracker.missSeconds(of: wid))")
        check(
            "refusal: a REFUSED .optionAll snapshot classifies nothing — no DeadKind, no kind event",
            tracker.deadKind(wid) == nil && !has("dead ("),
            "kind=\(String(describing: tracker.deadKind(wid))) events=\(events)")
        check(
            "refusal: the curtain keeps holding — clean frames cannot lift an unclassified dead id",
            curtain.activeIDs.contains(wid) && !has("lift"), "events=\(events)")
        check(
            "refusal: the refusal is counted, not swallowed",
            tracker.allSnapshotRefusalCount >= 1,
            "refusals=\(tracker.allSnapshotRefusalCount)")
        check(
            "refusal: ONE loud record per streak, naming budget, observation and remediation",
            trips().filter { $0.hasPrefix("window-list-refused") }.count == 1
                && trips().contains {
                    $0.contains("budget=allRefusalTripwire") && $0.contains("configured=1")
                        && $0.contains("remediation=WindowTracker.allRefusalTripwire")
                }, "tripwires=\(trips())")

        // POSITIVE CONTROL: the server now ANSWERS, and its answer is an empty
        // list — the same `[]` the old code manufactured for a refusal. This
        // one really is evidence of destruction and must classify as before.
        set(listed: false, all: .empty)
        Thread.sleep(forTimeInterval: WindowTracker.deadRecheckSecs + 0.15)
        step(1, hits: false, dt: 0.1)
        check(
            "refusal: an EMPTY .optionAll answer still means destroyed (nil is not [])",
            tracker.deadKind(wid) == .destroyed && has("dead (destroyed)"),
            "kind=\(String(describing: tracker.deadKind(wid))) events=\(events)")
        step(Curtain.lingerCleanFrames, hits: false, dt: 0.1)
        check(
            "refusal: once the kind is known the destroyed curtain lifts on clean frames",
            has("lift (closed"), "events=\(events)")
        tracker.stop()

        // 2. A capture gap discards pending hit evidence. Fresh rig:
        //    part 1's parole and ghost accounting must not price this.
        let gapTracker = WindowTracker()
        set(listed: true, all: .answer)
        gapTracker.windowSource = rows
        gapTracker.screenFrame = screen
        gapTracker.onReceipt = { _ in }
        gapTracker.start()
        defer { gapTracker.stop() }
        let gapCurtain = Curtain()
        var gapEvents: [(String, CGWindowID)] = []
        gapCurtain.onChange = { gapEvents.append(($0, $1)) }
        var gt = CFAbsoluteTimeGetCurrent()
        func gapStep(_ count: Int, hits: Bool, dt: CFTimeInterval = 1.0 / 30) {
            for _ in 0..<count {
                gt += dt
                _ = gapCurtain.update(
                    blockedScreenRects: hits ? [hit] : [], tracker: gapTracker,
                    display: screen, at: gt)
                gapTracker.setTracked(gapCurtain.watchIDs)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
        gapStep(Curtain.triggerHits - 1, hits: true)
        check(
            "gap: one hit short of triggerHits does not drop (the evidence the outage must eat)",
            !gapCurtain.activeIDs.contains(wid), "events=\(gapEvents)")
        // The outage: no evaluated frame for longer than gapGuardSecs, then one
        // post-wake hit. `tick` did not advance across the gap, which is exactly
        // why the frame arm used to keep the pre-gap hits "recent".
        gt += Curtain.gapGuardSecs + 0.5
        gapStep(1, hits: true)
        check(
            "gap: the first post-wake hit does not inherit pre-gap evidence",
            !gapCurtain.activeIDs.contains(wid)
                && !gapEvents.contains { $0.0.hasPrefix("drop") }, "events=\(gapEvents)")
        check(
            "gap: the discarded pending evidence is loud, with a count",
            gapEvents.contains {
                $0.0.contains("evaluated-frame gap")
                    && $0.0.contains(
                        "discarded \(Curtain.triggerHits - 1) pending hit(s) across 1 window(s)")
            }, "events=\(gapEvents)")
        gapStep(Curtain.triggerHits - 1, hits: true)
        check(
            "gap: post-wake evidence earns the drop on its own, at the full bar",
            gapCurtain.activeIDs.contains(wid), "events=\(gapEvents)")

        // 3. Ordered attribution. `bestHolder` is the whole decision,
        //    so it is asserted directly AND under every input order: the defect
        //    was that the answer depended on iteration order.
        let box = CGRect(x: 100, y: 100, width: 100, height: 100)
        let mostly = CGRect(x: 90, y: 90, width: 200, height: 200)  // holds all of it
        let partly = CGRect(x: 150, y: 150, width: 200, height: 200)  // holds a corner
        check(
            "attribution: the curtain holding more of the box wins, whatever the input order",
            Curtain.bestHolder(of: box, among: [(id: 2, rect: mostly), (id: 1, rect: partly)]) == 2
                && Curtain.bestHolder(
                    of: box, among: [(id: 1, rect: partly), (id: 2, rect: mostly)]) == 2)
        check(
            "attribution: equal holders tie-break on the smaller id, both orders",
            Curtain.bestHolder(of: box, among: [(id: 9, rect: mostly), (id: 4, rect: mostly)]) == 4
                && Curtain.bestHolder(
                    of: box, among: [(id: 4, rect: mostly), (id: 9, rect: mostly)]) == 4)
        check("attribution: no candidate is nil, not a crash",
              Curtain.bestHolder(of: box, among: []) == nil)
        var answers = Set<CGWindowID?>()
        let pool: [(id: CGWindowID, rect: CGRect)] = [
            (id: 7, rect: mostly), (id: 3, rect: mostly), (id: 5, rect: partly),
        ]
        for _ in 0..<100 { answers.insert(Curtain.bestHolder(of: box, among: pool.shuffled())) }
        check(
            "attribution: 100 shuffled candidate orders give one answer",
            answers == [3], "answers=\(answers)")
    }

    static func caseRegionEntryDebounce() {
        func det(_ x: CGFloat, conf: Float = 0.9) -> Detection {
            Detection(
                label: "FEMALE_BREAST_EXPOSED", confidence: conf,
                box: CGRect(x: x, y: 0.40, width: 0.10, height: 0.10))
        }
        func tracker(curtain: Bool) -> Tracker {
            let t = Tracker(
                clearAfter: Tracker.defaultClearAfter(fps: 30),
                stickyHold: Tracker.defaultStickyHold(fps: 30))
            t.curtainEntry = curtain
            return t
        }
        let curtainEntryFrames = TuningPolicy.ClassRule.defaultEntryFrames
        check(
            "region entry: the default per-class entryFrames == 2 (owner decision 2026-09-02)",
            curtainEntryFrames == 2 && TuningPolicy.defaults.entryFrames(for: "FEMALE_BREAST_EXPOSED") == 2)
        check(
            "region entry: a fresh Tracker paints on the first detection (region/media modes, SPEC §5.4)",
            Tracker(clearAfter: 12).curtainEntry == false
                && tracker(curtain: false).update(detections: [det(0.45)]).count == 1)

        let curtainMode = tracker(curtain: true)
        check(
            "region entry: the first sighting births no region in curtain mode",
            curtainMode.update(detections: [det(0.45)]).isEmpty)
        check(
            "region entry: a single-frame false positive never paints — the clean next frame drops it",
            curtainMode.update(detections: []).isEmpty)
        check(
            "region entry: the dropped candidate is counted, not silent",
            curtainMode.takeDebouncedEntries() == 1)
        check(
            "region entry: consecutive means consecutive — a sighting after a gap starts over",
            curtainMode.update(detections: [det(0.45)]).isEmpty)
        let born = curtainMode.update(detections: [det(0.46, conf: 0.7)])
        check(
            "region entry: the second consecutive frame births the region, even if the box moved",
            born.count == 1, "regions=\(born.count)")
        check(
            "region entry: peakConf is the higher of the two sightings",
            born.first?.peakConf == 0.9, "peakConf=\(born.first?.peakConf ?? -1)")
        check(
            "region entry: a confirmed birth is not counted as debounced",
            curtainMode.takeDebouncedEntries() == 0)
        let following = curtainMode.update(detections: [det(0.47)])
        check(
            "region entry: sustained content keeps the same region — no re-debounce",
            following.count == 1 && following.first?.id == born.first?.id)
        check(
            "region entry: hysteresis is untouched — the region survives a clean frame",
            curtainMode.update(detections: []).count == 1)

        // The cost, in frames: first paint one detector frame later than the
        // first-frame path on the same sustained, slowly moving sequence.
        func firstPaintFrame(_ t: Tracker) -> Int? {
            for frame in 0..<10 {
                let regions = t.update(detections: [det(0.30 + CGFloat(frame) * 0.005)])
                if !regions.isEmpty { return frame }
            }
            return nil
        }
        let plainFirst = firstPaintFrame(tracker(curtain: false))
        let curtainFirst = firstPaintFrame(tracker(curtain: true))
        check(
            "region entry: the debounce costs exactly one detector frame of first paint",
            plainFirst == 0 && curtainFirst == 1,
            "plain=\(plainFirst ?? -1) curtain=\(curtainFirst ?? -1)")
        for tier in PerfTier.all {
            let ms = Double(curtainEntryFrames - 1) * 1000.0 / Double(tier.fps)
            check(
                "tier \(tier.name.rawValue): one frame of first-paint cost is "
                    + String(format: "%.0f ms and stays inside SPEC §6's %.0f ms budget",
                             ms, PerfTier.latencyBudgetMs),
                PerfTier.latencyEstimateMs(tier) + ms <= PerfTier.latencyBudgetMs,
                String(format: "estimate %.1f + %.1f ms", PerfTier.latencyEstimateMs(tier), ms))
        }
        // reset() (the panic path) forgets a pending candidate.
        let reset = tracker(curtain: true)
        _ = reset.update(detections: [det(0.2)])
        reset.reset()
        check(
            "region entry: reset() forgets a pending candidate",
            reset.update(detections: [det(0.2)]).isEmpty)
    }

    // MARK: 7f — full-coverage tripwire measures the painted rects

    /// SPEC §8.1(2). Proves the number `Pipeline.checkCoverage` compares
    /// against `coverageLimit` is the area of the rects the overlay paints —
    /// PaintSmoother's output, pad/lead/`minPaintedSide` included — and not
    /// the tracker rects, which are strictly smaller.
    static func caseCoverageTripwire() {
        func region(_ id: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat)
            -> TrackedRegion
        {
            TrackedRegion(id: id, rect: CGRect(x: x, y: y, width: w, height: h), missed: 0)
        }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

        check(
            "coverage: no rects paint nothing",
            Pipeline.paintedArea([]) == 0 && Pipeline.paintedArea([.zero]) == 0)
        // Two disjoint rects: areas add, and the gap between them is NOT
        // painted (a bounding-box merge would have swallowed it).
        let a = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.5)
        let b = CGRect(x: 0.6, y: 0.0, width: 0.2, height: 0.5)
        check(
            "coverage: disjoint rects add, the gap between them is not painted",
            close(Pipeline.paintedArea([a, b]), 0.2), "\(Pipeline.paintedArea([a, b]))")
        // Overlap is counted once: two 0.5x0.5 rects sharing a 0.25x0.25 corner.
        let c = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        let d = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        check(
            "coverage: overlap is counted once",
            close(Pipeline.paintedArea([c, d]), 0.4375), "\(Pipeline.paintedArea([c, d]))")
        check(
            "coverage: a rect fully inside another adds nothing",
            close(Pipeline.paintedArea([c, c.insetBy(dx: 0.1, dy: 0.1)]), 0.25))

        // The measured quantity is the PAINTED area. Two region-mode regions,
        // far enough apart that neither paintRect touches the other, so the
        // painted total is exactly the sum of the two paintRects.
        let regions = [region(1, 0.05, 0.05, 0.20, 0.20), region(2, 0.60, 0.60, 0.04, 0.04)]
        let smoother = PaintSmoother()
        smoother.setFrameSize(width: 1920, height: 1080)
        let painted = smoother.rects(for: regions, mustCover: [])
        let expected = painted.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        check(
            "coverage: measured area == the summed area of the two disjoint painted rects",
            painted.count == 2 && close(Pipeline.paintedCoverage(painted), expected),
            "painted=\(painted) measured=\(Pipeline.paintedCoverage(painted)) expected=\(expected)")
        // And it is strictly more than the tracker rects it replaced: pad
        // (0.10/side) and the 0.10 minimum painted side both grow the cover.
        let trackerArea = regions.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        check(
            "coverage: painted area exceeds the tracker area the tripwire used to sum",
            Pipeline.paintedArea(painted) > trackerArea * 1.4,
            "painted=\(Pipeline.paintedArea(painted)) tracker=\(trackerArea)")
        check(
            "coverage: the minPaintedSide floor is inside the measured area",
            close(painted[1].width, OverlayManager.minPaintedSide)
                && close(painted[1].height, OverlayManager.minPaintedSide),
            "small region painted \(painted[1])")
        // A screen-filling cover reads as full coverage; the gate fixtures'
        // busiest frame does not.
        check(
            "coverage: a full-screen paint reads 1.0, the limit is 0.9",
            close(Pipeline.paintedArea([CGRect(x: 0, y: 0, width: 1, height: 1)]), 1.0))
        // The runaway case the cap exists for: 31 full-height stripes, one
        // more than `maxRegions`. The overlay paints the first 30 and drops
        // the rest (loudly, `overlay-count`), so the tripwire must measure 30
        // — measuring all 31 would auto-panic over a stripe nobody can see.
        let stripes = (0..<(OverlayManager.maxRegions + 1)).map {
            CGRect(x: CGFloat($0) * 0.032, y: 0, width: 0.031, height: 1)
        }
        check(
            "coverage: past maxRegions the measure counts the rects the overlay paints",
            close(
                Pipeline.paintedCoverage(stripes),
                Pipeline.paintedArea(Array(stripes.prefix(OverlayManager.maxRegions)))),
            "capped=\(Pipeline.paintedCoverage(stripes)) all=\(Pipeline.paintedArea(stripes))")
        check(
            "coverage: the uncapped union of those stripes would have been larger",
            Pipeline.paintedArea(stripes) > Pipeline.paintedCoverage(stripes),
            "all=\(Pipeline.paintedArea(stripes)) capped=\(Pipeline.paintedCoverage(stripes))")
        // RELEASE (owner 2026-10-18): a trip lifts region covers only, briefly,
        // and its parent-visible line is coalesced.
        check("coverage release: brief (≤ 30 s) and not the 300 s panic",
            Pipeline.regionReleaseSecs > 0 && Pipeline.regionReleaseSecs <= 30)
        check("coverage release: the first release writes an alert line",
            Pipeline.releaseAlertDue(now: 1000, last: nil))
        check("coverage release: a second release inside the gap is coalesced",
            !Pipeline.releaseAlertDue(now: 1000 + Pipeline.releaseAlertGapSecs - 1, last: 1000))
        check("coverage release: a release after the gap writes again",
            Pipeline.releaseAlertDue(now: 1000 + Pipeline.releaseAlertGapSecs, last: 1000))
        let one = Pipeline.releaseAlertMessage(observed: 0.934, count: 1)
        let many = Pipeline.releaseAlertMessage(observed: 0.95, count: 7)
        check("coverage release: the line names the share, the length and what stayed on",
            one.contains("93%") && one.contains("10 s") && one.contains("window covers and detection stayed on")
                && !one.contains("times since"), one)
        check("coverage release: a coalesced line counts the releases it stands for",
            many.contains("(7 times since the last line)"), many)
    }

    // MARK: 8 — AdminCheck

    static func caseAdmin() {
        check("admin: uid 0 ⇒ admin", AdminCheck.isAdminSession(uid: 0) == (true, nil))
        let nobody = AdminCheck.isAdminSession(uid: uid_t(bitPattern: -2))
        check("admin: nobody (no gid 80) ⇒ not admin, no error", nobody.admin == false && nobody.error == nil, "\(nobody)")
        let bogus = AdminCheck.isAdminSession(uid: 4_000_000_123)
        check("admin: lookup failure ⇒ not admin AND an error to log", bogus.admin == false && bogus.error != nil, "\(bogus)")
    }

    // MARK: 15 — "Remove SentryScreen…" (SPEC §8.1(7); owner 2026-09-05)

    /// The removal path, driven headlessly: who may see the row, the
    /// confirmation's state machine, the command handed to the administrator
    /// prompt, the bounded seat-release wait, and the three outcomes. No real
    /// authorization prompt and no real script — `Uninstall.override` stands
    /// in, the same way `PanicAuth.override` does for the panic hold.
    static func caseUninstall(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { Uninstall.override = nil }

        // --- The command handed to the administrator prompt -------------
        let keep = Uninstall.Choice(keepSettings: true, resetPermissions: false)
        let del = Uninstall.Choice(keepSettings: false, resetPermissions: true)
        check("uninstall: defaults are complete removal + permission reset",
            Uninstall.Choice() == del, "\(Uninstall.Choice())")
        check("uninstall: keep ⇒ SENTRY_KEEP_SETTINGS=yes and no flag",
            Uninstall.shellCommand(keep, scriptPath: "/x/uninstall.sh")
                == "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin SENTRY_KEEP_SETTINGS='yes' /bin/bash -p '/x/uninstall.sh' 2>&1",
            Uninstall.shellCommand(keep, scriptPath: "/x/uninstall.sh"))
        check("uninstall: delete + reset ⇒ =no and --reset-permissions",
            Uninstall.shellCommand(del, scriptPath: "/x/uninstall.sh")
                == "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin SENTRY_KEEP_SETTINGS='no' /bin/bash -p '/x/uninstall.sh' '--reset-permissions' 2>&1",
            Uninstall.shellCommand(del, scriptPath: "/x/uninstall.sh"))
        // The installed path has a space in it; a quote in a path would end
        // the AppleScript literal. Both must survive intact.
        let nasty = "/Library/Application Support/Sen\"try/uninstall.sh"
        let source = Uninstall.appleScript(keep, scriptPath: nasty)
        check("uninstall: the script path is shell-quoted", Uninstall.shellCommand(keep, scriptPath: nasty)
            .contains("'/Library/Application Support/Sen\"try/uninstall.sh'"))
        check("uninstall: a quote in the path is escaped in the AppleScript literal",
            source.contains("Sen\\\"try"), source)
        check("uninstall: the prompt is an administrator prompt",
            source.hasPrefix("do shell script \"")
                && source.hasSuffix("\" with administrator privileges"), source)
        check("uninstall: the real script path is the installed one, never PATH-resolved",
            Uninstall.scriptPath == "/Library/Application Support/SentryScreen/uninstall.sh")

        // --- Who may open it --------------------------------------------
        var logs: [(String, String)] = []
        let store = UISettingsStore(root: dir, log: { _, _ in })
        let actions = UIActions(store: store, log: { logs.append(($0, $1)) })
        actions.removalAllowed = { false }
        actions.beginRemove()
        check("uninstall: a Standard session cannot open the confirmation",
            actions.layer == .none, "\(actions.layer)")
        check("uninstall: the refusal is logged by name",
            logs.last?.0 == "uninstall" && logs.last!.1.contains("REFUSED"), "\(logs)")
        logs.removeAll()
        var ran = 0
        Uninstall.override = { _, _ in ran += 1 }
        actions.confirmRemove()
        check("uninstall: a Standard session cannot run the script either",
            ran == 0 && logs.last!.1.contains("nothing ran"), "ran=\(ran) \(logs)")

        actions.removalAllowed = { true }
        actions.beginRemove()
        check("uninstall: an administrator session opens the confirmation",
            actions.layer == .remove, "\(actions.layer)")
        check("uninstall: the confirmation opens with complete removal + permission reset",
            actions.removeChoice == Uninstall.Choice(), "\(actions.removeChoice)")

        // --- Confirmation state machine ---------------------------------
        actions.removeChoice.keepSettings = false
        actions.removeChoice.resetPermissions = true
        actions.cancelRemove()
        check("uninstall: Cancel returns to the settings panel",
            actions.layer == UIActions.Layer.settings, "\(actions.layer)")
        actions.beginRemove()
        check("uninstall: reopening resets both answers to the safe defaults",
            actions.removeChoice == Uninstall.Choice(), "\(actions.removeChoice)")

        // --- Copy the parent must see -----------------------------------
        check("uninstall: the closing line says the app closes now",
            UninstallCopy.closing.contains("close now"), UninstallCopy.closing)
        check("uninstall: the row and the confirmation name an administrator, not the PIN",
            UninstallCopy.body.contains("administrator")
                && !UninstallCopy.body.lowercased().contains("pin")
                && UISettingsPanelView.removeCaption.contains("administrator"))
        check("uninstall: the permission control names all users and a new grant on reinstall",
            UninstallCopy.resetPermissionsLabel.contains("all users")
                && UninstallCopy.resetPermissionsCaption.contains("reinstall"))
        // --- The gate: order and the single-flight rule -----------------
        struct Rig {
            var events: [(String, String)] = []
            var stages: [UninstallGate.Stage] = []
            var scriptRuns: [Uninstall.Choice] = []
            var stageWhenScriptRan: UninstallGate.Stage?
            var pending: [(TimeInterval, () -> Void)] = []
        }
        final class Box { var r = Rig() }

        func makeGate(_ box: Box, outcome: Uninstall.Outcome) -> UninstallGate {
            var gate: UninstallGate!
            gate = UninstallGate(
                log: { box.r.events.append(($0, $1)) },
                runScript: { choice, done in
                    box.r.scriptRuns.append(choice)
                    box.r.stageWhenScriptRan = gate.stage
                    done(outcome)
                },
                schedule: { delay, work in box.r.pending.append((delay, work)) })
            gate.onStage = { box.r.stages.append($0) }
            return gate
        }
        func drain(_ box: Box) {
            var guardCount = 0
            while !box.r.pending.isEmpty {
                guardCount += 1
                if guardCount > 200 { check("uninstall: the gate terminates", false, "runaway schedule"); return }
                box.r.pending.removeFirst().1()
            }
        }

        var box = Box()
        var gate = makeGate(box, outcome: .removed("removed."))
        gate.begin(keep)
        drain(box)
        check("uninstall: the closing line is published BEFORE the script runs",
            box.r.scriptRuns == [keep] && box.r.stageWhenScriptRan == .closing,
            "\(box.r.scriptRuns) \(String(describing: box.r.stageWhenScriptRan))")
        check("uninstall: the stages are closing → done",
            box.r.stages == [.closing, .done(.removed("removed."))], "\(box.r.stages)")
        check("uninstall: every stage is a named `uninstall` record",
            box.r.events.allSatisfy { $0.0 == "uninstall" } && box.r.events.count >= 3,
            "\(box.r.events)")

        // A second press while a removal is in flight changes nothing.
        box = Box()
        gate = makeGate(box, outcome: .removed(""))
        gate.begin(keep)
        gate.begin(del)
        check("uninstall: a second press while in flight is ignored and logged",
            box.r.events.contains { $0.1.contains("stage=start ignored") }, "\(box.r.events)")
        drain(box)
        check("uninstall: only one run reached the script", box.r.scriptRuns.count == 1)

        // --- Outcomes as the sheet shows them ---------------------------
        actions.beginRemove()
        var scripted: [Uninstall.Choice] = []
        Uninstall.override = { choice, done in
            scripted.append(choice)
            done(.cancelled("the administrator prompt was cancelled — nothing was removed"))
        }
        actions.uninstallGate = nil
        actions.confirmRemove()
        spin(until: {
            if case .done = actions.removeStage { return true } else { return false }
        })
        check("uninstall: a cancelled administrator prompt leaves the machine alone",
            actions.removeMessage == UninstallCopy.cancelledNotice
                && actions.layer == .remove, "\(String(describing: actions.removeMessage))")

        actions.uninstallGate = nil
        let scriptError = "ERROR: removal target=support observed=command-failed "
            + "remediation=inspect-permissions-and-rerun-packaging/uninstall.sh"
        Uninstall.override = { _, done in done(.failed(code: 1, message: scriptError)) }
        actions.confirmRemove()
        spin(until: {
            if case .done(.failed) = actions.removeStage { return true } else { return false }
        })
        check("uninstall: a failed removal shows the script's OWN error text, verbatim",
            actions.removeMessage?.contains(scriptError) == true
                && actions.removeMessage?.contains("exited 1") == true,
            "\(String(describing: actions.removeMessage))")
        check("uninstall: a failure names the exit code and does not claim success",
            actions.removeMessage?.hasPrefix(UninstallCopy.failedPrefix) == true)
        check("uninstall: the parent's answers reached the script unchanged",
            scripted == [Uninstall.Choice()], "\(scripted)")

        // A dev build must never run the INSTALLED removal script: the app it
        // would remove is not the app being tested.
        Uninstall.override = nil
        actions.uninstallGate = nil
        logs.removeAll()
        check("uninstall: a development state root suppresses removal",
            actions.removalSuppressedReason != nil, "\(String(describing: actions.removalSuppressedReason))")
        actions.confirmRemove()
        check("uninstall: the suppression is loud and nothing runs",
            actions.removeMessage?.hasPrefix("Removal is not available in this build") == true
                && logs.last?.1.contains("SUPPRESSED") == true
                && actions.uninstallGate == nil,
            "\(String(describing: actions.removeMessage)) \(logs)")
    }

    // MARK: 8b — green status toast gate

    /// The green "SentryScreen is on" toast used to be gated on
    /// `--capture-loss banner` alone while its receipt claimed "only if the
    /// icon is shown" (review 2026-08-28). The gate is now a predicate and
    /// this case is what keeps the two from drifting apart again. The
    /// Capture-loss visibility has its own arbitration predicate below. It
    /// must stay visible when no parent repair surface owns the outage.
    static func caseStatusToastGate() {
        func shown(
            _ banner: Bool,
            _ driver: Bool,
            _ admin: Bool,
            _ icon: Bool,
            _ confirmation: Bool = false
        ) -> Bool {
            AppDelegate.statusToastIsShown(
                bannerMode: banner, underUIDriver: driver,
                isAdmin: admin, showMenuBarIcon: icon,
                successConfirmationPending: confirmation)
        }
        check("toast: admin + icon on + banner mode ⇒ shown",
            shown(true, false, true, true))
        check("toast: pending setup confirmation ⇒ suppressed",
            !shown(true, false, true, true, true))
        check("toast: menu-bar icon off ⇒ suppressed (an invisible install stays invisible)",
            !shown(true, false, true, false))
        check("toast: Standard (child) session ⇒ suppressed (durable shield is sufficient)",
            !shown(true, false, false, true))
        check("toast: not in --capture-loss banner mode ⇒ suppressed",
            !shown(false, false, true, true))
        check("toast: under the UI driver ⇒ suppressed (screenshots stay byte-stable)",
            !shown(true, true, true, true))

        check("capture-loss banner: Standard session with no parent surface ⇒ shown",
            AppDelegate.captureLossBannerIsShown(
                bannerMode: true, runtimeOwnsCaptureLossSurface: false))
        check("capture-loss banner: runtime-owned parent repair surface ⇒ suppressed",
            !AppDelegate.captureLossBannerIsShown(
                bannerMode: true, runtimeOwnsCaptureLossSurface: true))
        check("capture-loss banner: non-banner mode ⇒ suppressed",
            !AppDelegate.captureLossBannerIsShown(
                bannerMode: false, runtimeOwnsCaptureLossSurface: false))
    }

    // MARK: 8c — panic pause in the UI (owner 2026-09-29, plan §6 item 3)

    /// Option B: one toast after the emergency keys, the popover's real
    /// Paused state while the panic pause runs, Resume now ending it through
    /// the pipeline hook without touching settings.json, and expiry reading
    /// Protected again. The pipeline's own deadline bookkeeping
    /// (`Pipeline.endPanicPause`, `expirePanicIfDue`) is not reached here: it
    /// is exercised on an installed agent with SIGUSR2;
    /// this case covers the UI contract.
    static func casePanicPauseUI(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        let keys = PanicPause(until: now.addingTimeInterval(300), source: "hotkey")
        let dev = PanicPause(until: keys.until, source: "SIGUSR2")
        let trip = PanicPause(until: keys.until, source: "coverage-tripwire")

        // Toast: once per panic the keys started.
        let first = PanicToast.spec(previous: nil, next: keys)
        check("panic toast: the keys start a panic ⇒ one notice naming the deadline",
            first?.id == PanicToast.toastID && first?.kind == .notice && first?.hasControls == false
                && first?.title == "Covers cleared. Paused until \(UIState.clockTime.string(from: keys.until)).",
            first?.title ?? "nil")
        check("panic toast: the same deadline republished ⇒ not shown again",
            PanicToast.spec(previous: keys, next: keys) == nil)
        check("panic toast: a second press extends the deadline ⇒ shown for the new time",
            PanicToast.spec(previous: keys, next: PanicPause(until: keys.until.addingTimeInterval(60),
                source: "hotkey")) != nil)
        check("panic toast: SIGUSR2 (the dev stand-in) ⇒ shown; tripwire, resume, expiry ⇒ not",
            PanicToast.spec(previous: nil, next: dev) != nil
                && PanicToast.spec(previous: nil, next: trip) == nil
                && PanicToast.spec(previous: keys, next: nil) == nil)
        var queue = ToastQueue()
        check("panic toast: a repeat offer of the showing toast is not replayed",
            queue.offer(first!) && !queue.offer(first!))

        // Popover: the real Paused state during the panic.
        let ui = UIState(settings: .defaults, devStateRoot: false, isAdmin: true)
        ui.captureHealth = .protecting
        check("panic popover: before the panic ⇒ Protected", ui.headerText == "Protected", ui.headerText)
        ui.panicPause = keys
        check("panic popover: during the panic ⇒ Paused, Back on at <time> · N min left",
            ui.headerText == "Paused" && ui.pauseUntil == keys.until
                && ui.detailText == UIPauseCountdown.detail(until: keys.until, now: Date())
                && ui.detailText.hasSuffix("min left"),
            "\(ui.headerText) / \(ui.detailText)")
        check("panic popover: the chip says the emergency keys were used",
            ui.activePanic.map(UIPopoverCopy.panicChip) == "Emergency keys used. Every cover was cleared.")
        check("panic popover: a longer settings pause still wins (later deadline)",
            PauseState.compose(panic: keys.until, settings: keys.until.addingTimeInterval(600))
                == keys.until.addingTimeInterval(600))

        // Resume now: ends the panic through the hook, no PIN, no settings write.
        let store = UISettingsStore(root: dir, log: { _, _ in })
        let actions = UIActions(store: store, log: { _, _ in })
        var ended = 0
        actions.endPanicPause = { ended += 1; ui.panicPause = nil }
        let before = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        actions.resume()
        let after = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        check("panic popover: Resume now ⇒ the panic ends once, no PIN layer, settings.json untouched",
            ended == 1 && actions.layer != .pin && before == after && store.settings.pause == .none,
            "ended=\(ended) layer=\(actions.layer) files \(before) → \(after)")
        check("panic popover: after Resume now ⇒ Protected", ui.headerText == "Protected", ui.headerText)

        // Expiry: a deadline in the past reads Protected even before the
        // pipeline's nil arrives (it lands up to one tick late).
        ui.panicPause = PanicPause(until: Date().addingTimeInterval(-1), source: "hotkey")
        check("panic popover: an expired panic ⇒ Protected, no chip",
            ui.headerText == "Protected" && ui.pauseUntil == nil && ui.activePanic == nil, ui.headerText)
    }

    // MARK: 8c — child-session shield + restore grace (owner 2026-08-29)

    static func caseChildSessionAndRestoreGrace() {
        // Status item: the child session gets the shield; the two other gates
        // (icon setting, onboarding complete) are unchanged.
        check("status item: Standard session + icon on + onboarding complete ⇒ wanted",
            AppDelegate.statusItemWanted(isAdmin: false, showMenuBarIcon: true, onboardingComplete: true))
        check("status item: icon off ⇒ not wanted, admin or not",
            !AppDelegate.statusItemWanted(isAdmin: true, showMenuBarIcon: false, onboardingComplete: true)
                && !AppDelegate.statusItemWanted(isAdmin: false, showMenuBarIcon: false, onboardingComplete: true))
        check("status item: onboarding incomplete ⇒ not wanted (setup window owns the parent surface)",
            !AppDelegate.statusItemWanted(isAdmin: false, showMenuBarIcon: true, onboardingComplete: false))
        // Popover: no mutating controls in a Standard session. The read-only
        // branch draws exactly one text control; everything that reaches
        // store.mutate / PinGate lives behind parentControlsAvailable.
        check("popover: parent controls unavailable in a Standard session",
            !UIPopoverView.parentControlsAvailable(isAdmin: false)
                && UIPopoverView.parentControlsAvailable(isAdmin: true))
        check("popover: child copy names the administrator account as the way to change anything",
            UIPopoverView.childManagedBody.contains("administrator login")
                && UIPopoverView.childDegradedBody.contains("administrator login"))
        // Restore grace: only protecting→lost with a re-arm in flight waits.
        let lost = CaptureHealth.lost(since: Date(), reason: "x")
        check("restore grace: protecting→lost while re-arming is deferred",
            AppDelegate.lostIsDeferred(previous: .protecting, restoreInFlight: true))
        check("restore grace: protecting→lost with no re-arm goes red at once",
            !AppDelegate.lostIsDeferred(previous: .protecting, restoreInFlight: false))
        check("restore grace: starting→lost and lost→lost are never deferred",
            !AppDelegate.lostIsDeferred(previous: .starting, restoreInFlight: true)
                && !AppDelegate.lostIsDeferred(previous: lost, restoreInFlight: true))
        check("restore grace: 1 s (ASSUMED; the measured same-second restore fits inside it)",
            AppDelegate.restoreGraceSecs == 1.0)
        // PIN authority wording: EACCES in a Standard session is expected; the
        // same error in an admin session, or any other error, stays DEGRADED.
        let denied = ParentPINAuthorityError(
            path: "/x/parent", configured: "directory", observed: "open errno=13 Permission denied",
            remediation: "r")
        let other = ParentPINAuthorityError(
            path: "/x/parent", configured: "directory", observed: "open errno=2 No such file",
            remediation: "r")
        check("pin-authority: Standard session + EACCES ⇒ expected (INFO wording)",
            ParentPINFileAuthority.isExpectedStandardSessionDenial(standardSession: true, error: denied))
        check("pin-authority: admin session + EACCES ⇒ DEGRADED unchanged",
            !ParentPINFileAuthority.isExpectedStandardSessionDenial(standardSession: false, error: denied))
        check("pin-authority: Standard session + other error ⇒ DEGRADED",
            !ParentPINFileAuthority.isExpectedStandardSessionDenial(standardSession: true, error: other))
    }

    // MARK: 7c2 — a HUNG detector is not "Protected"

    /// A `detect` that never returns, driven through the same `DetectDeadline`
    /// the pipeline brackets every call with, then composed exactly as the
    /// popover composes it. Before the deadline existed nothing could publish
    /// `.failing` for a call that produced neither an error nor a frame.
    static func caseDetectorDeadline() {
        let t0: CFAbsoluteTime = 800_000_000
        let limit = DetectDeadline.limitSecs
        // Doubles at 8e8 s carry ~1e-7 s of resolution: compare durations loosely.
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-3 }
        check("deadline: limit 30 s, tick 1 s (receipt: above the 19.4 s cold-boot firstFrameMs)",
            limit == 30 && DetectDeadline.tickSecs == 1 && limit * 1000 > 19_434)

        var health = DetectorHealth.healthy
        func compose() -> ProtectionHealth {
            ProtectionHealth.compose(capture: .protecting, detector: health)
        }

        // Healthy call: fast, never flagged.
        let ok = DetectDeadline()
        ok.begin(at: t0)
        check("deadline: a 60 ms call is not a stall", ok.check(at: t0 + 0.06) == nil)
        let okFin = ok.end(at: t0 + 0.06)
        check("deadline: …and finishes clean",
            near(okFin.elapsedSecs, 0.06) && !okFin.stallWasPublished && compose() == .protecting)

        // Hung call: nothing returns, nothing throws.
        let d = DetectDeadline()
        d.begin(at: t0)
        check("deadline: inside the limit ⇒ nothing yet (limit − 0.1 s)", d.check(at: t0 + limit - 0.1) == nil)
        let stall = d.check(at: t0 + limit + 0.1)
        check("deadline: past the limit ⇒ ONE stall naming since and observed",
            stall?.since == t0 && stall.map { near($0.observedSecs, limit + 0.1) } == true
                && d.isStalled)
        check("deadline: the next tick does not re-fire", d.check(at: t0 + limit + 1) == nil)
        if let stall {
            health = .failing(since: Date(timeIntervalSinceReferenceDate: stall.since))
        }
        check("deadline: the popover composes NOT-protecting while the call hangs",
            compose() != .protecting && compose().isFailing)

        // The call finally returns: recovery is republished by the caller.
        let fin = d.end(at: t0 + limit + 4)
        check("deadline: the late return reports the stall it ended",
            near(fin.elapsedSecs, limit + 4) && fin.stallWasPublished && !d.isStalled)
        health = .healthy
        check("deadline: recovery ⇒ protecting again", compose() == .protecting)
        d.begin(at: t0 + limit + 5)
        check("deadline: the next call starts clean", d.check(at: t0 + limit + 5.1) == nil)
        _ = d.end(at: t0 + limit + 5.1)

        // A late timer never hides a breach: end() still reports the overrun.
        let late = DetectDeadline()
        late.begin(at: t0)
        let lateFin = late.end(at: t0 + limit + 2)
        check("deadline: an overrun no tick caught is still reported by end()",
            near(lateFin.elapsedSecs, limit + 2) && !lateFin.stallWasPublished)
        check("deadline: end() with no begin() is harmless",
            DetectDeadline().end(at: t0) == .init(elapsedSecs: 0, stallWasPublished: false))
    }

    // MARK: 7c — honest protection status (2026-09-11)

    /// The detector-failure state machine driven through an INJECTED error
    /// sequence — failure, no-op while failing, recovery, re-failure — plus the
    /// composition and every parent surface that reads it. Before this, no test
    /// in the repo exercised a detector failure at all.
    static func caseProtectionHealth() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

        // --- The threshold and its receipt -------------------------------
        check("detector: the streak threshold is 3 (MEASURED healthy rate 0 over 622,026 frames)",
            DetectorWatch.failingStreak == 3)

        var replacement = DetectorWatch()
        check("detector: replacement publishes its first successful result",
            replacement.noteSuccess() == .ready && replacement.health == .healthy)
        check("detector: later successful frames do not publish repeatedly",
            replacement.noteSuccess() == .none)

        // --- Failure: the first errors HOLD but do not yet turn the UI ----
        var w = DetectorWatch()
        check("detector: a fresh watch is healthy", w.health == .healthy)
        check("detector: error 1 of 3 ⇒ no edge, still healthy (one throw is not a failure)",
            w.noteError(at: at(0)) == .none && w.health == .healthy && w.streak == 1)
        check("detector: error 2 of 3 ⇒ still no edge",
            w.noteError(at: at(0.1)) == .none && w.health == .healthy)
        check("detector: error 3 ⇒ the edge fires, dated from the FIRST error of the streak",
            w.noteError(at: at(0.2)) == .began(since: at(0), errors: 3)
                && w.health == .failing(since: at(0)))
        let failing = w.health
        check("detector: error 4+ ⇒ no second edge and the published value does not change",
            w.noteError(at: at(0.3)) == .none && w.health == failing && w.streak == 4)

        // --- Recovery: immediate, on the first answered frame -------------
        check("detector: one success ⇒ recovered, naming the whole streak",
            w.noteSuccess() == .recovered(afterErrors: 4) && w.health == .healthy)
        check("detector: a second success is not a second edge",
            w.noteSuccess() == .none && w.health == .healthy)
        check("detector: it can fail AGAIN after recovering (the streak restarts)",
            w.noteError(at: at(10)) == .none && w.noteError(at: at(10.1)) == .none
                && w.noteError(at: at(10.2)) == .began(since: at(10), errors: 3))

        // --- A success under the threshold clears the streak -------------
        var t = DetectorWatch()
        _ = t.noteError(at: at(0))
        _ = t.noteError(at: at(0.1))
        check("detector: a success at 2 errors clears the streak — 2+2 never reaches 3",
            t.noteSuccess() == .ready && t.streak == 0
                && t.noteError(at: at(1)) == .none && t.noteError(at: at(1.1)) == .none
                && t.health == .healthy)

        // --- Pause/panic: the streak goes, the verdict stays -------------
        var p = DetectorWatch()
        for i in 0..<DetectorWatch.failingStreak { _ = p.noteError(at: at(Double(i))) }
        p.clearStreak()
        check("detector: clearStreak zeroes the streak and KEEPS failing (so recovery still edges)",
            p.streak == 0 && p.health == .failing(since: at(0)))
        check("detector: the first frame after the resume publishes the real recovery",
            p.noteSuccess() == .recovered(afterErrors: 0) && p.health == .healthy)

        // --- The durable pair is RATE-FLOORED (review 2026-09-11) ---------
        // The edges above are FRAME-paced: a 3-fail/1-success flap edges every
        // 4 frames, 7.5 times a second at 30 fps. One alerts.log pair per edge
        // filled AlertsLog.capBytes in 39 min and deleted the parent's whole
        // alert history in ~78. The floor is on the CLOSE, so a flapping
        // episode costs exactly ONE ALERT and the file never claims recovery
        // while the detector is still dead.
        check("alerts: the settle floor is 60 s, DERIVED from detectorErrorEventInterval",
            DetectorAlertGate.recoverySettleSecs == 60)
        // The cost side of that receipt, measured from the real line builder
        // rather than asserted in a comment. 297 B at uid 501; a 4-digit uid
        // adds 1 B per line.
        let pairBytes = AlertsLog.line(level: "ALERT", message: ProtectionCopy.detectorAlert)
            .utf8.count + 1
            + AlertsLog.line(level: "INFO", message: ProtectionCopy.detectorAlertCleared)
            .utf8.count + 1
        check("alerts: the detector pair is ~297 B — the input to AlertsLog.capBytes' worst case",
            (290...302).contains(pairBytes), "pair=\(pairBytes) B")
        var gate = DetectorAlertGate()
        check("alerts: the first failing edge opens the outage (no floor on the OPEN)",
            gate.health(failing: true) == .open && gate.outageOpen)
        let staleArm = gate.generation + 1
        check("alerts: a recovery ARMS the close instead of writing it",
            gate.health(failing: false) == .armClose(generation: staleArm) && gate.outageOpen)
        check("alerts: a flap back into failure writes NOTHING and keeps the outage open",
            gate.health(failing: true) == .nothing && gate.outageOpen)
        check("alerts: the stale timer from before the flap closes nothing and arms nothing",
            gate.close(generation: staleArm) == .nothing
                && gate.outageOpen && !gate.closePending)
        var opens = 0, arms = 0
        for _ in 0..<1_000 {
            if case .armClose = gate.health(failing: false) { arms += 1 }
            if gate.health(failing: true) == .open { opens += 1 }
        }
        check("alerts: 1,000 flap cycles write NO second ALERT (the 7.5/s flood is gone)",
            gate.outageOpen && opens == 0, "extra ALERTs=\(opens)")
        check("alerts: …and leave at most ONE timer in flight, not one per cycle",
            arms == 1 && gate.closePending, "timers armed over 1,000 cycles=\(arms)")
        // Recovery inside a window that was armed earlier: one more window,
        // never an early close.
        _ = gate.health(failing: false)
        let armedAt = gate.generation
        check("alerts: a close armed BEFORE the latest recovery re-arms instead of writing",
            gate.close(generation: armedAt - 1) == .rearm(generation: armedAt)
                && gate.outageOpen && gate.closePending)
        check("alerts: a whole healthy window then writes the restore INFO, once",
            gate.close(generation: armedAt) == .write && !gate.outageOpen)
        check("alerts: a timer that fires with no outage open writes nothing",
            gate.close(generation: armedAt) == .nothing)
        check("alerts: a later failure opens a NEW outage (the episode boundary is real)",
            gate.health(failing: true) == .open && gate.outageOpen)

        // --- Display coordinate space ------------------
        // Not closed, reported: the two helpers must be exact inverses or the
        // tripwire would fire on a single-display Mac.
        if let first = NSScreen.screens.first, let id = Pipeline.displayID(of: first) {
            check("displays: NSScreen -> displayID -> NSScreen round-trips on this Mac",
                CaptureStream.screen(for: id) == first, "id=\(id)")
        }
        check("displays: no NSScreen ⇒ no fabricated id", Pipeline.displayID(of: nil) == nil)

        // --- Composition precedence --------------------------------------
        let lost = CaptureHealth.lost(since: at(5), reason: "capture stream lost")
        check("protection: healthy capture + healthy detector ⇒ protecting",
            ProtectionHealth.compose(capture: .protecting, detector: .healthy) == .protecting)
        check("protection: healthy capture + dead detector ⇒ detectorFailing (NOT protecting)",
            ProtectionHealth.compose(capture: .protecting, detector: .failing(since: at(0)))
                == .detectorFailing(since: at(0)))
        check("protection: capture OUTRANKS the detector — the failure with a repair wins",
            ProtectionHealth.compose(capture: lost, detector: .failing(since: at(0)))
                == .captureLost(since: at(5), reason: "capture stream lost"))
        check("protection: starting outranks a detector that has not answered yet",
            ProtectionHealth.compose(capture: .starting, detector: .failing(since: at(0)))
                == .starting)
        check("protection: both failures count as failing; protecting and starting do not",
            ProtectionHealth.compose(capture: lost, detector: .healthy).isFailing
                && ProtectionHealth.compose(capture: .protecting, detector: .failing(since: at(0))).isFailing
                && !ProtectionHealth.compose(capture: .protecting, detector: .healthy).isFailing
                && !ProtectionHealth.compose(capture: .starting, detector: .healthy).isFailing)

        // --- The parent surfaces (real UIState, real computed properties) --
        let ui = UIState(settings: .defaults, devStateRoot: false, isAdmin: true)
        ui.captureHealth = .protecting
        check("popover: a healthy single-display Mac is unchanged (Protected / On for everyone on this Mac)",
            ui.headerText == "Protected" && ui.detailText == "On for everyone on this Mac"
                && ui.glyph == .protecting)
        ui.detectorHealth = .failing(since: at(0))
        check("popover: a dead detector no longer reads Protected",
            ui.headerText == ProtectionCopy.detectorHeader
                && ui.detailText == ProtectionCopy.detectorDetail,
            "header=\(ui.headerText) detail=\(ui.detailText)")
        check("menu bar: a dead detector is NOT a green shield, and the tooltip says which failure",
            ui.glyph == .degraded && ui.statusSummary == ProtectionCopy.detectorSummary)
        check("popover: the §8 banner invariant is untouched — isDegraded stays CAPTURE-only",
            !ui.isDegraded && ui.protection.detectorIsFailing)
        check("copy: the detector row says BOTH halves — held covers, unchecked new content",
            ProtectionCopy.detectorRow.contains("stays covered")
                && ProtectionCopy.detectorRow.contains("not being checked"))
        // Review 2026-09-11: the body used to open with "This usually clears up
        // on its own", which has no receipt (zero detector errors in 622,026
        // MEASURED frames) and told a parent to wait. The action comes first and
        // the wait-and-see sentence must not come back.
        check("copy: the detector body LEADS with the one action a parent has",
            ProtectionCopy.detectorBody.hasPrefix("Restart this Mac")
                && !ProtectionCopy.detectorBody.lowercased().contains("clears up"),
            ProtectionCopy.detectorBody)
        // Pause still outranks everything: a paused machine is what the parent
        // asked for, detector or no detector.
        ui.settings.pause = .untilRestart(
            bootSession: BootSession.uuid ?? "x", by: "test", at: at(0))
        check("popover: pause outranks a dead detector (same precedence as capture)",
            ui.headerText == "Paused" && ui.glyph == .paused)
        ui.settings.pause = .none
        ui.detectorHealth = .healthy
        check("popover: recovery puts the green shield back",
            ui.headerText == "Protected" && ui.glyph == .protecting && !ui.protection.detectorIsFailing)

        // --- Display scope ---------------------------------------
        check("displays: one display ⇒ no warning, no overstatement to fix",
            !DisplayScope.single.hasUnprotectedDisplays
                && DisplayScope.single.unprotectedCount == 0)
        let two = DisplayScope(displayCount: 2, protectedDisplayID: 7, protectedName: "Studio Display")
        check("displays: two displays ⇒ one uncovered, and the warning exists",
            two.hasUnprotectedDisplays && two.unprotectedCount == 1)
        check("displays: the row NAMES the protected screen instead of claiming the Mac",
            UIPopoverView.displayScopeText(two).contains("Studio Display")
                && UIPopoverView.displayScopeText(two).contains("the other screen")
                && UIPopoverView.displayScopeText(two).contains("not covered"))
        let three = DisplayScope(displayCount: 3, protectedDisplayID: 7, protectedName: "Studio Display")
        check("displays: three displays ⇒ the row counts the other TWO",
            UIPopoverView.displayScopeText(three).contains("the other 2 screens"))
        check("displays: the tripwire record carries counts, ids and a fix — and NO display name",
            two.logInfo.contains("displays=2") && two.logInfo.contains("protected=7")
                && two.logInfo.contains("unprotected=1") && two.logInfo.contains("fix: Capture.start")
                && !two.logInfo.contains("Studio Display"))
        ui.displayScope = two
        check("popover: the detail line stops saying \"this Mac\" on a multi-display Mac",
            ui.detailText == "Only Studio Display is covered", ui.detailText)
        ui.displayScope = .single
        check("popover: back to one display ⇒ the original sentence",
            ui.detailText == "On for everyone on this Mac")

        // --- Registry + demo axes -----------------------------------------
        var failingDemo = DemoState()
        failingDemo.detectorFailing = true
        check("registry: a failing detector requires its row, above the healthy sections",
            UIRegistry.requiredIDs(for: failingDemo).contains("ui.status.detector")
                && UIRegistry.requiredIDs(for: failingDemo).contains("ui.settings.open"))
        // Review 2026-09-11: the view draws this row on
        // `protection.detectorIsFailing`, which needs capture PROTECTING, so
        // `health=starting detector=failing` must NOT require the id — it is an
        // expressible demo state and a script there would have failed with a
        // missing-id error that is the registry's bug, not the view's.
        var startingDemo = DemoState()
        startingDemo.health = .starting
        startingDemo.detectorFailing = true
        check("registry: starting capture + failing detector ⇒ no detector row (starting outranks)",
            !UIRegistry.requiredIDs(for: startingDemo).contains("ui.status.detector"))
        var twoDisplayDemo = DemoState()
        twoDisplayDemo.displays = 2
        check("registry: a second display requires the scope row",
            UIRegistry.requiredIDs(for: twoDisplayDemo).contains("ui.status.displays"))
        check("registry: a healthy single-display Mac requires neither row",
            !UIRegistry.requiredIDs(for: DemoState()).contains("ui.status.detector")
                && !UIRegistry.requiredIDs(for: DemoState()).contains("ui.status.displays"))
        var lostDemo = DemoState()
        lostDemo.health = .lost
        lostDemo.detectorFailing = true
        lostDemo.displays = 2
        check("registry: a LOST capture owns the surface — neither new row is drawn under it",
            !UIRegistry.requiredIDs(for: lostDemo).contains("ui.status.detector")
                && !UIRegistry.requiredIDs(for: lostDemo).contains("ui.status.displays"))
        var demo = DemoState()
        check("demo: the detector axis parses and composes with health",
            demo.set("detector", "failing") == nil && demo.detectorFailing
                && demo.detectorHealth != .healthy
                && demo.set("detector", "ok") == nil && !demo.detectorFailing
                && demo.set("detector", "maybe") != nil)
        check("demo: the displays axis parses, is bounded, and never leaks this Mac's hardware",
            demo.set("displays", "2") == nil && demo.displays == 2
                && demo.displayScopeValue.protectedName == DemoState.demoDisplayName
                && demo.set("displays", "0") != nil
                && demo.set("displays", "\(DemoState.maxDisplays + 1)") != nil
                && demo.set("displays", "1") == nil && demo.displayScopeValue == .single)
        check("demo: disconnected display parses without changing the default",
            DemoState().displayConnected
                && demo.set("displayconnected", "off") == nil
                && !demo.displayScopeValue.protectedDisplayConnected
                && demo.displayScopeValue.hasUnprotectedDisplays
                && demo.displayScopeValue.unprotectedCount == 1
                && demo.set("displayconnected", "maybe") != nil
                && UIRegistry.requiredIDs(for: demo).contains("ui.status.displays"))
        check("demo: resume acknowledgement axis parses and defaults off",
            !DemoState().resuming
                && demo.set("resuming", "on") == nil && demo.resuming
                && demo.set("resuming", "off") == nil && !demo.resuming
                && demo.set("resuming", "maybe") != nil)
    }

    // MARK: 7b — FixSpotlight window discovery round trip
    /// Regression (2026-08-26): the id→bounds step returned nothing, so the
    /// dim rendered with no hole and the helper never appeared. Exercise the
    /// real path on a window WE own (no other app is guaranteed to exist).
    static func caseSpotlight() {
        check("spotlight: System Settings hole uses the measured macOS 26 corner",
            FixSpotlight.settingsCornerRadius == 24)
        check("spotlight: dialogs keep a tighter corner than the main settings window",
            FixSpotlight.auxiliaryCornerRadius < FixSpotlight.settingsCornerRadius)
        check("spotlight: cutout stays inside fractional WindowServer bounds",
            FixSpotlight.cutoutInset == 0.5)
        check("spotlight helper: copy gives one direct drag instruction",
            AddEntryHelper.title == "Can’t find SentryScreen?"
                && AddEntryHelper.instruction
                    == "Drag the large SentryScreen icon into the open Settings list.")
        check("spotlight helper: transfer guide fits inside the receipted panel",
            AddEntryHelper.sizePt.width >= TransferGuideView.sizePt.width + 28
                && AddEntryHelper.sizePt.height >= TransferGuideView.sizePt.height + 100)
        check("spotlight helper: appears only when System Settings is frontmost",
            FixSpotlight.helperMayBeVisible(
                frontmostBundleID: FixSpotlight.settingsBundleID,
                securePromptOverlayVisible: false)
                && !FixSpotlight.helperMayBeVisible(
                    frontmostBundleID: FixSpotlight.settingsBundleID,
                    securePromptOverlayVisible: true)
                && !FixSpotlight.helperMayBeVisible(
                    frontmostBundleID: "com.apple.UserNotificationCenter",
                    securePromptOverlayVisible: true)
                && !FixSpotlight.helperMayBeVisible(
                    frontmostBundleID: Bundle.main.bundleIdentifier,
                    securePromptOverlayVisible: false)
                && !FixSpotlight.helperMayBeVisible(
                    frontmostBundleID: nil,
                    securePromptOverlayVisible: false))
        check("spotlight helper: macOS 26 Screen Recording prompt is a passthrough agent",
            FixSpotlight.passthroughBundleIDs.contains(
                "com.apple.accessibility.universalAccessAuthWarn"))
        check("capture-loss toast: action names the destination",
            CaptureLossBanner.fixLabel == "Turn on")
        // MARK: parent-facing copy (2026-09-11)
        //
        // "paused" belongs to the pause the PARENT asked for. Every
        // surface that reports a permission or update loss says "off".
        check("no surface calls a permission or update loss a pause", {
            let surfaces = [
                CaptureLossBanner.title,
                UIOnboardingChrome(surface: .permissionMissing(
                    context: .repair, reason: "r", error: nil)).title,
                UIOnboardingChrome(surface: .updateRequired(
                    detail: "d", protectionPaused: true)).title,
                UIOnboardingChrome(surface: .updateRequired(
                    detail: "d", protectionPaused: true)).symbolLabel,
            ]
            return surfaces.allSatisfy { !$0.lowercased().contains("paus") }
                && CaptureLossBanner.title == "Protection is off: Screen Recording is off"
        }())
        // ONE sentence about what the PIN gates, on all three surfaces,
        // and it does not claim the PIN removes SentryScreen (admin password).
        check("one true PIN-purpose sentence, shared", {
            let sheet = UISetPinView.body
            let step = UIOnboardingChrome(surface: .createPIN(isSaving: false, error: nil)).body
            return sheet.hasPrefix(UIPin.purpose) && step.hasSuffix(UIPin.purpose)
                && !UIPin.purpose.lowercased().contains("remove")
                && !UIPin.purpose.contains("sensitivity")
                && sheet.contains("Use 4 to 8 digits.")
        }())
        // the page switcher has a name for VoiceOver (`.labelsHidden()`
        // hides it on screen, it does not delete it).
        check("the Settings page picker is named",
            UISettingsPanelView.tabPickerLabel == "Settings page")
        // the popover PIN prompt says what the field accepts — the
        // reason Return on three digits does nothing.
        check("the PIN prompt states the accepted format",
            UIPin.formatCaption == "Use 4 to 8 digits."
                && UIPin.purposeWithFormat.hasSuffix(UIPin.formatCaption))
        // the subheadline leads with the parent's clock and puts the
        // developer reason on its own line, instead of gluing it on with "·".
        check("a lost capture keeps its reason off the parent's line", {
            let ui = UIState(settings: .defaults, devStateRoot: false, isAdmin: true)
            let since = Date(timeIntervalSince1970: 0)
            ui.captureHealth = .lost(since: since, reason: "capture stream lost")
            // App UI redesign 2026-09-28: the reason line is dropped from the
            // popover (it stays in alerts.log and the repair window).
            return ui.detailText.hasPrefix("Since")
                && !ui.detailText.contains("capture stream lost")
                && !ui.detailText.contains("\n")
        }())
        // a failure card leads with a parent sentence; the receipt that
        // names a constant and launchd follows on the second line.
        check("a failure receipt is the second line, never the first", {
            let one = UIOnboardingRuntime.parentDetail("Plain sentence.", receipt: nil)
            let two = UIOnboardingRuntime.parentDetail(
                "SentryScreen's background parts did not finish starting.",
                receipt: "Required service verification did not finish within "
                    + "UIOnboardingRuntime.freshFrameDeadline=30 seconds.")
            let lines = two.split(separator: "\n")
            return one == "Plain sentence." && lines.count == 2
                && !lines[0].contains("freshFrameDeadline")
                && lines[1].contains("freshFrameDeadline")
        }())
        // the update-required card's way out is the releases page.
        check("update-required offers a download from the releases page",
            UIOnboardingSurface.downloadAction == "Download the latest version"
                && UIOnboardingSurface.releasesURL.absoluteString.contains("github.com"))
        // the Settings fold tripwire exists, is named, and has its
        // documented one-run override.
        check("the Settings fold tripwire is named and overridable",
            UIDriver.foldBudget == "UIDriver.settingsFoldAtDefaultText"
                && !UIDriver.allowsSettingsFold)
        let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        // The WindowServer learns of the window on the next run-loop turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let own = CGWindowID(win.windowNumber)
        let ids = FixSpotlight.windowIDs(ofPIDs: [getpid()])
        check("spotlight: discovery finds our own window", ids.contains(own), "ids=\(ids)")
        let rects = FixSpotlight.rects(of: [own])
        check("spotlight: id→bounds yields one rect", rects.count == 1, "rects=\(rects)")
        check("spotlight: bounds size matches (320x240)",
            rects.first.map { $0.width == 320 && $0.height == 240 } ?? false, "rects=\(rects)")
    }

    // MARK: 8 — status-item glyph image

    static func caseGlyph() {
        var seen: [Data] = []
        for glyph in [UIGlyph.protecting, .paused, .degraded, .starting] {
            let got = UIStatusItem.glyphImage(glyph, description: "d")
            check("glyph: \(glyph.rawValue) is the receipted 16x16 pt Lantern face",
                got.size == NSSize(width: SentryLanternGlyph.side, height: SentryLanternGlyph.side), "\(got.size)")
            // Quiet states follow the bar (template); badged ones carry red.
            check("glyph: \(glyph.rawValue) isTemplate only for on and starting",
                got.isTemplate == (glyph == .protecting || glyph == .starting))
            check("glyph: \(glyph.rawValue) carries the accessibility description",
                got.accessibilityDescription == "d")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            if let rep {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                got.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
                NSGraphicsContext.restoreGraphicsState()
                seen.append(rep.tiffRepresentation ?? Data())
            }
        }
        check("glyph: the four states draw four different images (owner: separate icons)",
            Set(seen).count == 4, "distinct=\(Set(seen).count)")
    }
}

extension UISelfTest {
    // MARK: 8b — redesign foundation (SentryColor, Lantern, shields, primary budget)

    static func caseBrandFoundation() {
        let failures = SentryLanternArt.validate()
        check("brand: every Lantern path parses", failures.isEmpty, "\(failures)")
        for (name, parts) in [("face", SentryLanternArt.face), ("figure", SentryLanternArt.figure)] {
            let empty = parts.filter {
                if case let .path(d) = $0.shape { return SentryLanternArt.path(d).boundingRect.isEmpty }
                return false
            }.count
            check("brand: Lantern \(name) paths are non-empty", empty == 0, "empty=\(empty)")
        }
        // Headless provider check: the token resolves per appearance. The
        // real NSPopover render is a separate, visual receipt.
        let expected: [(String, NSColor, UInt32, UInt32)] = [
            ("paper", SentryColor.NS.paper, 0xf6ecd5, 0x1f1712),
            ("ink", SentryColor.NS.ink, 0x2b1d16, 0xf3e6cc),
            ("primary", SentryColor.NS.primary, 0xd6a53a, 0xe2ae45),
            ("controlBorder", SentryColor.NS.controlBorder, 0x2b1d16, 0xcdb994),
        ]
        for (name, color, day, night) in expected {
            for (appearance, want) in [(NSAppearance.Name.aqua, day), (.darkAqua, night)] {
                var got: UInt32 = 0
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    if let c = color.usingColorSpace(.sRGB) {
                        got = UInt32((c.redComponent * 255).rounded()) << 16
                            | UInt32((c.greenComponent * 255).rounded()) << 8
                            | UInt32((c.blueComponent * 255).rounded())
                    }
                }
                check("brand: SentryColor.\(name) resolves under \(appearance.rawValue)", got == want,
                    String(format: "want %06x, got %06x", want, got))
            }
        }
        check("brand: embedded Shantell Sans Bold registers (owner 2026-09-28)",
            SentryFont.displayName != nil, SentryFont.failure ?? "")
        if let name = SentryFont.displayName {
            check("brand: Shantell resolves by its PostScript name",
                NSFont(name: name, size: 16) != nil, name)
        }
        check("brand: one primary passes the budget",
            SentryBrand.primaryButtonBudgetFailure(state: "s", primaryIDs: ["a"]) == nil)
        let over = SentryBrand.primaryButtonBudgetFailure(state: "s", primaryIDs: ["a", "b"]) ?? ""
        check("brand: two primaries fail the budget by name",
            over.contains("budget=primary-buttons-per-state") && over.contains("limit=1 observed=2"), over)
    }
}

extension PinGate.Result: CustomStringConvertible {
    var description: String {
        switch self {
        case .ok: return "ok"
        case let .wrong(r): return "wrong(remaining: \(r))"
        case let .locked(u): return "locked(until: \(UISettings.iso.string(from: u)))"
        case .noPin: return "noPin"
        }
    }
}

private func == (a: (admin: Bool, error: String?), b: (Bool, String?)) -> Bool {
    a.admin == b.0 && a.error == b.1
}

extension UISelfTest {
    // MARK: Hidden main menu (owner 2026-09-07)

    /// An accessory app has no menu bar, so without a main menu Cmd-X/C/V/A
    /// have nothing to route through and the key field cannot be pasted
    /// into. The menu is built by AppDelegate.makeMainMenu and installed in
    /// applicationDidFinishLaunching (every mode).
    static func caseMainMenu() {
        let menu = AppDelegate.makeMainMenu()
        let edit = menu.items.first { $0.submenu?.title == "Edit" }?.submenu
        let file = menu.items.first { $0.submenu?.title == "File" }?.submenu
        let actions = Set((edit?.items ?? []).compactMap { $0.action.map(NSStringFromSelector) })
        let wanted = Set(AppDelegate.editMenuSelectors.map(NSStringFromSelector))
        check("main menu: Edit carries undo/redo/cut/copy/paste/selectAll with nil targets (responder chain)",
            actions.isSuperset(of: wanted) && (edit?.items ?? []).allSatisfy { $0.target == nil }
                && wanted == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"], "\(actions)")
        check("main menu: the standard key equivalents",
            edit?.items.first { $0.action == #selector(NSText.paste(_:)) }?.keyEquivalent == "v"
                && edit?.items.first { $0.action == #selector(NSText.selectAll(_:)) }?.keyEquivalent == "a"
                && edit?.items.first { $0.action == #selector(NSText.copy(_:)) }?.keyEquivalent == "c"
                && edit?.items.first { $0.action == #selector(NSText.cut(_:)) }?.keyEquivalent == "x")
        check("main menu: File > Close (Cmd-W) → performClose: on the key window (the Setup window's windowShouldClose decides)",
            file?.items.first?.action == #selector(NSWindow.performClose(_:)) && file?.items.first?.keyEquivalent == "w"
                && file?.items.first?.target == nil)
    }

    // MARK: Accessibility (UIAccessibility.swift, spec §9.3)

    static func caseAccessibility() {
        // 1. macOS has no Dynamic Type. This is the measurement the whole file
        // rests on, re-run on every selftest so a future macOS that DOES scale
        // fails here instead of silently making `.uiFont` redundant.
        let probeStyles: [Font.TextStyle] = [.headline, .body, .callout, .caption, .caption2]
        for style in probeStyles {
            let system = NSFont.preferredFont(forTextStyle: UITypography.appKitStyle(style))
            check("a11y: \(style) resolves a real AppKit point size", system.pointSize > 0,
                "\(system.pointSize)")
        }

        // 2. Scale 1 is the identity: the same Font value the call sites used
        // before `.uiFont` existed, which is why the default-size renders are
        // byte-identical.
        check("a11y: scale 1 returns the static style font",
            UITypography.font(.callout, scale: UITextScale.standard) == Font.callout)
        check("a11y: scale 1 with a weight matches .font(.callout.weight(.medium))",
            UITypography.font(.callout, scale: UITextScale.standard, weight: .medium)
                == Font.callout.weight(.medium))
        check("a11y: scale 1 leaves a point metric alone",
            UITypography.points(UIMetrics.rowHeight, scale: UITextScale.standard)
                == UIMetrics.rowHeight)

        // 3. Above 1 everything grows, and by the receipted ratios.
        let callout = NSFont.preferredFont(forTextStyle: .callout).pointSize
        check("a11y: large is 23/17 and xl is 28/17 (UITextScale receipts)",
            abs(UITextScale.large - 23.0 / 17.0) < 0.0001
                && abs(UITextScale.xl - 28.0 / 17.0) < 0.0001,
            "large=\(UITextScale.large) xl=\(UITextScale.xl)")
        check("a11y: xl scales callout past its default size",
            UITypography.font(.callout, scale: UITextScale.xl)
                != UITypography.font(.callout, scale: UITextScale.standard)
                && (callout * UITextScale.xl).rounded() > callout,
            "callout=\(callout) scaled=\((callout * UITextScale.xl).rounded())")
        check("a11y: rowHeight grows with the text and stays a whole point",
            UIMetrics.rowHeight(scale: UITextScale.xl) > UIMetrics.rowHeight
                && UIMetrics.rowHeight(scale: UITextScale.xl)
                    == UIMetrics.rowHeight(scale: UITextScale.xl).rounded(),
            "\(UIMetrics.rowHeight(scale: UITextScale.xl))")
        check("a11y: the settings viewport scales with the text too",
            UIMetrics.settingsViewportMaxHeight(scale: UITextScale.large)
                > UIMetrics.settingsViewportMaxHeight)

        // 4. The script vocabulary. A typo must fail at parse time, before a
        // window exists, and both new values must be --ui-demo only.
        var thrown: String?
        do { _ = try UIDriver.parse("textsize huge\n", isDemo: true) } catch { thrown = "\(error)" }
        check("a11y: `textsize huge` is a parse error naming the accepted values",
            thrown?.contains(UITextScale.acceptedValues) == true, thrown ?? "no error")
        thrown = nil
        do { _ = try UIDriver.parse("textsize xl\n", isDemo: false) } catch { thrown = "\(error)" }
        check("a11y: `textsize` is refused for a live script",
            thrown?.contains("only allowed under --ui-demo") == true, thrown ?? "no error")
        thrown = nil
        do { _ = try UIDriver.parse("appearance sepia\n", isDemo: true) } catch { thrown = "\(error)" }
        check("a11y: `appearance` names its accepted values",
            thrown?.contains(UIAppearanceOption.acceptedValues) == true, thrown ?? "no error")
        do {
            let parsed = try UIDriver.parse(
                "textsize large\nappearance light\nassertfits\n", isDemo: true)
            check("a11y: the three new actions parse",
                parsed.count == 3 && parsed[2].action == .assertfits, "\(parsed.count)")
        } catch { check("a11y: the three new actions parse", false, "\(error)") }
        thrown = nil
        do { _ = try UIDriver.parse("assertfits ui.x\n", isDemo: true) } catch { thrown = "\(error)" }
        check("a11y: `assertfits` takes no argument",
            thrown?.contains("takes 0 arguments") == true, thrown ?? "no error")
        // The onboarding grammar gained the same verb.
        do {
            let parsed = try UIOnboardingTestScript.parse("textsize xl\n", path: "/tmp/x.txt")
            check("a11y: the onboarding driver parses `textsize`",
                parsed.lines.count == 1 && parsed.lines[0].action == .textSize("xl"))
        } catch { check("a11y: the onboarding driver parses `textsize`", false, "\(error)") }

        // 5. `assertfits` with nothing measured must say so rather than pass.
        UIRegistry.shared.removeAll()
        let why = UIDriver.fitFailure()
        check("a11y: assertfits without a popover fails loudly",
            why?.contains("no popover surface") == true, why ?? "nil (it passed)")

        let layout = UILayoutProbe.shared
        layout.surface = CGSize(width: UIMetrics.popoverWidth, height: 400)
        layout.frames = ["ui.settings.tab": CGRect(x: UIMetrics.popoverPadding, y: 80,
            width: UIMetrics.popoverWidth - 2 * UIMetrics.popoverPadding, height: 24)]
        check("a11y: Settings tabs within the content insets fit", UIDriver.fitFailure() == nil)
        layout.frames["ui.settings.tab"]?.size.width += UIMetrics.popoverPadding
        check("a11y: Settings tabs entering the right margin fail",
            UIDriver.fitFailure()?.contains("Settings tabs span") == true)
        layout.clear()

        // 6. Appearance values map to real NSAppearances.
        for name in UIAppearanceOption.names {
            check("a11y: appearance '\(name)' resolves an NSAppearance",
                UIAppearanceOption.appearance(name) != nil)
        }
        // Receipt on UIAppearanceOption: macOS collapses both accessibility
        // high-contrast appearances onto the plain ones, so an app cannot put
        // Increase Contrast on one window. If a future macOS stops collapsing
        // them this check fails, and `-contrast` script values become worth
        // adding.
        check("a11y: macOS still collapses the high-contrast appearances",
            NSAppearance(named: .accessibilityHighContrastAqua)?.name == .aqua
                && NSAppearance(named: .accessibilityHighContrastDarkAqua)?.name == .darkAqua,
            NSAppearance(named: .accessibilityHighContrastAqua)?.name.rawValue ?? "nil")

        // 7. Reduce Transparency / Increase Contrast mapping. The real setting
        // is system-wide and SwiftUI's environment value has no setter, so the
        // mapping is a pure function and this is where it is asserted.
        check("a11y: Reduce Transparency makes the card fill solid",
            UISurface.cardFillOpacity(reduceTransparency: true) == 1
                && UISurface.cardFillOpacity(reduceTransparency: false) == 0.5)
        check("a11y: Reduce Transparency darkens the card stroke like Increase Contrast",
            UISurface.cardStrokeOpacity(increasedContrast: false, reduceTransparency: true)
                == UISurface.cardStrokeOpacity(increasedContrast: true, reduceTransparency: false),
            "\(UISurface.cardStrokeOpacity(increasedContrast: false, reduceTransparency: true))")
        check("a11y: normal settings keep the designed stroke",
            UISurface.cardStrokeOpacity(increasedContrast: false, reduceTransparency: false) == 0.42)

        // 8. Initial keyboard focus (spec §9.7). Never a pause preset, never
        // anything under a script.
        check("a11y: a degraded admin popover focuses the way back",
            UIPopoverView.initialFocus(isAdmin: true, isDegraded: true)
                == .repair)
        check("a11y: a healthy admin popover focuses Settings…, not a pause preset",
            UIPopoverView.initialFocus(isAdmin: true, isDegraded: false)
                == .settings)
        check("a11y: a standard session has no parent control to focus",
            UIPopoverView.initialFocus(isAdmin: false, isDegraded: false)
                == nil)
        check("a11y: a scripted run takes no initial focus (byte-stable renders)",
            !UIPopoverView.takesInitialFocus(scripted: true)
                && UIPopoverView.takesInitialFocus(scripted: false))
    }

    // MARK: Driver completion without exit

    /// Spins the main run loop until `done` or the deadline. Receipt: every
    /// driver step is a main-queue continuation, and the longest chain here
    /// is a few actions; 5 s is a tripwire ~100x that, never a wait.
    private static func spin(until done: () -> Bool, secs: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(secs)
        while !done() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    static func caseDriverFinish(_ dir: String) {
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Parse errors are thrown, not fatal, so a queue can report them.
        var thrown: String?
        do { _ = try UIDriver.parse("open\nstate paused 15m\n", isDemo: false) } catch { thrown = "\(error)" }
        check("driver: `state` is refused for a live script by throwing",
            thrown?.contains("only allowed under --ui-demo") == true, thrown ?? "no error")
        thrown = nil
        do { _ = try UIDriver.parse("tap\n", isDemo: true) } catch { thrown = "\(error)" }
        check("driver: arity error names the line", thrown?.hasPrefix("line 1:") == true, thrown ?? "no error")
        thrown = nil
        do { _ = try UIOnboardingTestScript.parse("wait 999999\n", path: dir + "/x.onb.txt") } catch { thrown = "\(error)" }
        check("onboarding driver: milliseconds budget is a thrown parse error",
            thrown?.contains("UIOnboardingTestScript.maximum") == true, thrown ?? "no error")
        do {
            let ok = try UIDriver.parse("# c\nopen\ntap ui.x\nclose\n", isDemo: false)
            check("driver: parse keeps line numbers", ok.map(\.number) == [2, 3, 4], "\(ok.map(\.number))")
        } catch { check("driver: parse of a good script", false, "\(error)") }

        // A `type` line's argument is a PIN after the UI
        // test runner substitutes ${PIN}: neither driver may echo it.
        let typed = try! UIDriver.parse("type ui.pin.field 4821\n", isDemo: false)
        check("driver: a `type` line renders redacted",
            typed.first?.display == "type ui.pin.field <redacted>",
            typed.first?.display ?? "no line")
        let onbTyped = try! UIOnboardingTestScript.parse(
            "type onboarding.pin.field 4821\n", path: dir + "/pin.onb.txt")
        check("onboarding driver: a `type` line renders redacted",
            onbTyped.lines.first?.display == "type onboarding.pin.field <redacted>",
            onbTyped.lines.first?.display ?? "no line")

        // A driver with onFinish reports the driver code and never exits.
        let lines = try! UIDriver.parse("tap ui.selftest.missing\n", isDemo: false)
        let driver = UIDriver(path: dir + "/s.txt", lines: lines, shotsDir: dir)
        var got: (Int32, String)?
        driver.onFinish = { code, message, _ in got = (code, message) }
        let host = UIDriverHost(
            open: { .failed("no popover in a selftest") }, close: {}, isShown: { false },
            windowNumber: { 0 }, contentView: { nil }, setState: { _, _ in nil }, setAppearance: { _ in },
            setTextSize: { _ in nil })
        driver.run(host: host)
        check("driver: onFinish receives the assert code instead of exit",
            spin(until: { got != nil }) && got?.0 == UIDriver.Exit.assertFailed.rawValue,
            "\(String(describing: got))")
        check("driver: the failure message names the line", got?.1.contains("line 1") == true, got?.1 ?? "")
        // waituntil: arity is 3, and a value that never arrives is a 71 that
        // names the id, the wanted text and why (never registered here).
        thrown = nil
        do { _ = try UIDriver.parse("waituntil ui.x \"Protected\"\n", isDemo: false) } catch { thrown = "\(error)" }
        check("driver: waituntil takes 3 arguments", thrown?.contains("takes 3 arguments") == true, thrown ?? "no error")
        let untilLines = try! UIDriver.parse("waituntil ui.selftest.missing \"Protected\" 100\n", isDemo: false)
        let untilDriver = UIDriver(path: dir + "/u.txt", lines: untilLines, shotsDir: dir)
        var untilGot: (Int32, String)?
        untilDriver.onFinish = { code, message, _ in untilGot = (code, message) }
        untilDriver.run(host: host)
        check("driver: waituntil reports 71 with the wanted text when the value never arrives",
            spin(until: { untilGot != nil }) && untilGot?.0 == UIDriver.Exit.waitforTimeout.rawValue
                && untilGot?.1.contains("did not read \"Protected\" within 100 ms") == true
                && untilGot?.1.contains("not registered") == true,
            "\(String(describing: untilGot))")
        // The whole point of `display`: this message is what the UI
        // queue writes to done/<name>.result.json, which the test runner
        // copies into steps.jsonl, harness.log and the assessor prompt.
        let pinDriver = UIDriver(path: dir + "/pin.txt", lines: typed, shotsDir: dir)
        var pinGot: (Int32, String)?
        pinDriver.onFinish = { code, message, _ in pinGot = (code, message) }
        pinDriver.run(host: host)
        let pinMsg = spin(until: { pinGot != nil }) ? (pinGot?.1 ?? "") : ""
        check("driver: a failing `type` reports the id and <redacted>, never the value",
            pinMsg.contains("type ui.pin.field <redacted>") && !pinMsg.contains("4821"),
            pinMsg)
        // An empty script finishes 0 through the same callback.
        let empty = UIDriver(path: dir + "/e.txt", lines: [], shotsDir: dir)
        var code: Int32?
        empty.onFinish = { c, _, _ in code = c }
        empty.run(host: host)
        check("driver: an empty script finishes 0 via onFinish", spin(until: { code != nil }) && code == 0)
        // The onboarding driver: no window ⇒ `show` fails 70 through the callback.
        let onb = try! UIOnboardingTestScript.parse("show\n", path: dir + "/o.onb.txt")
        var onbCode: Int32?
        MainActor.assumeIsolated {
            let onbHost = UIOnboardingTestHost(
                present: {}, dismiss: {}, signal: { _ in false }, isVisible: { false },
                windowNumber: { 0 }, windowTitle: { nil }, windowCloseButtonEnabled: { nil },
                attemptWindowClose: { false }, closeWindow: { false }, contentView: { nil },
                setAppearance: { _ in }, setTextSize: { _ in nil })
            let d = UIOnboardingTestDriver(script: onb, host: onbHost, shotsDirectory: dir)
            d.onFinish = { c, _, _ in onbCode = c }
            d.run()
            check("onboarding driver: `show` without a window reports 70 via onFinish",
                spin(until: { onbCode != nil }) && onbCode == UIDriver.Exit.assertFailed.rawValue,
                "\(String(describing: onbCode))")
            _ = d
        }
    }

}
