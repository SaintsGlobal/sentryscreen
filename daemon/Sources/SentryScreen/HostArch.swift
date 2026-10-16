import Foundation

/// Which slice of the universal binary is running, and whether macOS is
/// translating it.
///
/// Why this exists (owner 2026-09-02, universal build): the shipped executable
/// carries an `arm64` and an `x86_64` slice, and macOS does NOT always pick the
/// native one. A process spawned from a translated parent — a Rosetta terminal,
/// an x86_64 Homebrew shell, a literal `arch -x86_64` — inherits the parent's
/// architecture, so on an Apple-silicon Mac the x86_64 slice can run under
/// Rosetta 2 with nobody noticing. That is not a cosmetic difference: Core ML
/// under Rosetta is CPU-only (no ANE, no Apple-silicon GPU).
///
/// MEASURED 2026-09-02 on an M1 Mac, same universal binary, same 640m model,
/// 6,765 media frames:
/// inference p50/p95 went 20.1/24.3 ms native to 65.2/118.8 ms
/// translated, and 7 of 13 synthetic fixtures blew the 2.0 ms
/// `media_path_pixel_work` budget (observed 2.61–3.73 ms). A silent 3x is
/// exactly the kind of limit this repo refuses to let pass quietly.
///
/// The installed product is not exposed: launchd launches the job natively.
/// The exposure is development and `live-run`, which is why this fails LOUDLY
/// by name and does not exit — refusing to start would break the one case
/// (a real Intel Mac) the universal build exists to serve.
enum HostArch {
    /// The slice this process is. Compile-time, so each slice of the fat binary
    /// carries its own answer and there is nothing to get wrong at run time.
    /// A third architecture must fail here rather than at a customer's Mac.
    #if arch(arm64)
    static let compiled = "arm64"
    #elseif arch(x86_64)
    static let compiled = "x86_64"
    #else
    #error("unsupported architecture: packaging/release.env ships SENTRY_ARCHS=\"arm64 x86_64\"")
    #endif

    /// The shipped contract, mirrored from `packaging/release.env`'s
    /// `SENTRY_ARCHS`. `--ui-selftest` asserts `compiled` is one of these, so a
    /// binary built outside that contract is caught by the gate, not in the
    /// field.
    static let shipped = ["arm64", "x86_64"]

    /// `sysctl.proc_translated`: "1" translated, "0" not, "unknown" if the
    /// query itself failed. Apple's documented contract is that the sysctl is
    /// ABSENT (errno ENOENT) on hosts that cannot translate, which means "not
    /// translated" — only a different errno is genuinely unknown, and it is
    /// reported as such rather than being rounded down to "0".
    static let translated: String = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == -1 {
            return errno == ENOENT ? "0" : "unknown"
        }
        return value == 1 ? "1" : "0"
    }()

    static var isTranslated: Bool { translated == "1" }

    /// Parent-facing processor name. A translated process is NOT an Intel Mac:
    /// calling it "Intel" in a message a parent reads would send them to the
    /// wrong support answer for a problem that is fixed by relaunching the
    /// process natively.
    static var description: String {
        if isTranslated { return "\(compiled) under Rosetta translation" }
        return compiled == "arm64" ? "Apple silicon" : "Intel"
    }

    /// The one named warning. Same text on stderr and in the log record so a
    /// terminal and a log agree, and it names the remediation.
    static let translationWarning =
        "rosetta: the \(compiled) slice is running under Rosetta translation on an "
        + "Apple-silicon Mac. Core ML will run CPU-only: MEASURED 2026-09-02, "
        + "inference p50 65.2 ms vs 20.1 ms native and 7/13 synthetic fixtures "
        + "exceed the 2.0 ms media_path_pixel_work budget. Not a crash and not "
        + "the installed product (launchd launches natively) — a translated "
        + "PARENT process. Remediation: relaunch from a native shell, or "
        + "`arch -arm64 <command>`."

    private static var warned = false

    /// Stderr half of the warning, emitted once per process from the one place
    /// every mode passes through (`main.swift`, right after option parsing), so
    /// `--process`, `--ui-selftest` and a live run all shout. The LOG half is
    /// emitted next to the "startup" record, which is the only site that has a
    /// logger. Two channels, one emission each — not a duplicate.
    static func warnIfTranslatedOnce() {
        guard isTranslated, !warned else { return }
        warned = true
        FileHandle.standardError.write(Data(("WARNING: " + translationWarning + "\n").utf8))
    }
}
