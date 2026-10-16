import Foundation

/// The `SENTRY_*` development environment knobs. They are always honoured;
/// the installed LaunchAgent is protected one layer out, because
/// `packaging/agent-launch.sh` starts the daemon under `env -i` with a fixed
/// variable set, so no ambient `SENTRY_*` variable reaches it.
enum DevEnv {
    /// The prefix that makes a variable a knob of ours.
    static let prefix = "SENTRY_"

    /// The environment a knob reader sees. The default argument of every
    /// function that takes an `env` parameter (`UISettingsStore.resolveRoot`,
    /// `AlertsLog.resolvePath`), so those keep an explicit-env test seam.
    ///
    /// Read fresh every call, never cached: `--ui-selftest` and the demo modes
    /// `setenv("SENTRY_STATE_DIR", …)` on themselves before resolving a root.
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// One knob's value. An EMPTY value counts as unset — every reader treats
    /// `""` as "off" or falls back past it.
    static func knob(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
    }

    /// `SENTRY_*` variables present in this process's environment, sorted.
    static var ambientKnobs: [String] {
        ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    /// The one launch record: the knobs this process saw.
    static var launchSummary: String {
        let ambient = ambientKnobs
        return "devEnv=armed envKnobs=\(ambient.count)"
            + (ambient.isEmpty ? "" : " ambient=[\(ambient.joined(separator: ","))]")
    }
}
