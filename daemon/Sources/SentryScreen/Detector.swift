import CoreML
import CryptoKit
import Foundation
import Vision

struct Detection {
    let label: String
    let confidence: Float
    /// Normalized (0–1) rect, Vision coordinates (origin bottom-left).
    let box: CGRect
    /// Cover mode `media` only: this box was unioned with a stable media box,
    /// so the tracked region holds it across detector dropouts (Tracker).
    /// Set after Policy/ROI filtering; the raw logged detections keep their
    /// own boxes (Detection is a value type).
    var mediaExpanded = false
    /// Settle re-check (`Pipeline.mergeRecheck`): the score this box had
    /// before the shifted pass raised it (0 when only the shifted pass saw
    /// it). nil for every box the re-check did not change. Trace-only.
    var recheckFrom: Float? = nil
    /// Zoom (tiling) prototype, a tuning tool (`ZoomTiles`): the 2 × 2 tile
    /// index (row-major from the top left) whose pass found this box. nil for
    /// every full-frame box, and always nil in a production build.
    var tile: Int? = nil
}

/// CoreML wrapper. The mlpackage embeds NMS (model/training/export_yolox_coreml.py), so Vision
/// returns ready VNRecognizedObjectObservations — no manual decode here.
final class Detector {
    private let vnModel: VNCoreMLModel
    /// How the model got loaded this launch, for the "startup" record:
    /// `compile=cache|fresh|recompiled|temp loadMs=N idMs=N id=<source>:<8 hex>`
    /// (plus `pruned=N` when this launch removed stale cache entries).
    /// The cache path was silently broken on the first production install
    /// (recompile every launch, ~20 s to first curtain); a launch that says
    /// which it did is a launch that can be grepped for the regression.
    /// `id=` is the cache key's identity (Detector.identity) — two launches
    /// that disagree on it loaded different model bytes.
    let loadInfo: String
    /// ANE/GPU on Apple Silicon (SPEC §5.2). Being re-measured 2026-08-25:
    /// `.all` lets CoreML place layers on the GPU, which a rendering browser
    /// contends for (A/B rig: inference 18-193 ms while Chrome opened a
    /// window, 19 ms steady).
    static let defaultComputeUnits: MLComputeUnits = .all
    /// SENTRY_COMPUTE values <-> CoreML placement: single source for the env
    /// parse AND the "startup" compute= label. The two were hand-duplicated
    /// and the label's fallback silently printed "cpu" for any future case
    /// (review 2026-08-25); unknown now labels "?" — loud, not wrong.
    static let computeNames: [(units: MLComputeUnits, name: String)] = [
        (.all, "all"), (.cpuAndNeuralEngine, "ane"), (.cpuOnly, "cpu")]

    init(modelPath: String) throws {
        let source = URL(fileURLWithPath: modelPath)
        let t0 = CFAbsoluteTimeGetCurrent()
        let identity = Self.identity(for: source)
        let idMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let config = MLModelConfiguration()
        // SENTRY_COMPUTE=all|ane|cpu selects the CoreML placement for A/B
        // measurement (logged in "startup"). Default receipt at
        // `defaultComputeUnits`.
        let units = Self.computeNames.first {
            $0.name == DevEnv.knob("SENTRY_COMPUTE")
        }?.units ?? Self.defaultComputeUnits
        config.computeUnits = units
        // .mlpackage must be compiled to .mlmodelc before loading. The
        // compiled result is cached under the package's IDENTITY (see
        // `identity`), and a cache entry that will not load is repaired once
        // instead of being fatal (see `resolveModel`).
        let resolved = try Self.resolveModel(
            source: source, identity: identity, trust: CacheTrust.of(source),
            compile: { try MLModel.compileModel(at: $0) },
            load: { try VNCoreMLModel(for: MLModel(contentsOf: $0, configuration: config)) })
        vnModel = resolved.model
        loadInfo = String(
            format: "compile=%@ loadMs=%.0f idMs=%.0f id=%@ compute=%@", resolved.compile,
            (CFAbsoluteTimeGetCurrent() - t0) * 1000, idMs,
            identity?.label ?? "none",
            Self.computeNames.first { $0.units == units }?.name ?? "?")
            + (resolved.pruned > 0 ? " pruned=\(resolved.pruned)" : "")
    }

    // MARK: - Compiled-model cache

    /// What the compiled-model cache is keyed on.
    ///
    /// Until 2026-09-11 the key was "a cache whose mtime is newer than the
    /// .mlpackage DIRECTORY's mtime wins" — two defects in one comparison:
    /// (a) replacing a file INSIDE the package (a `ditto` of
    /// new weights over the old ones, an exporter rewriting
    /// `Data/com.apple.CoreML/model.mlmodel` in place) does not change the
    /// directory's mtime, so the STALE compiled model kept winning — a model
    /// upgrade that silently does not take effect; (b) whatever a writable
    /// cache dir contained won on mtime alone. Keyed on CONTENT, a changed
    /// byte is a different cache entry, so a stale entry can never win.
    /// (A downgrade does NOT get its old entry back for free: the launch that
    /// writes a new entry prunes the other entries this scheme owns in that
    /// directory — see `pruneStale` — so going back to the previous model pays
    /// one more ~20 s compile. Deliberate: ~50 MB per kept generation in a
    /// user's Caches for a case only a developer hits.)
    ///
    /// Identity is `packaging/model-identity.sh`'s, not a second scheme:
    /// `manifest` reads the `sha256` field out of the `model-identity.tsv`
    /// that `build-pkg.sh` installs beside the payload — the same number
    /// `model-identity.sh verify` checks at build time, so an installed Mac
    /// hashes nothing at all. `content` is the dev-checkout fallback (no
    /// manifest beside `model/weights/...`): it hashes the inputs that script
    /// measures — every non-AppleDouble file's relative path, byte size and
    /// contents, in sorted order. The two digests are deliberately NOT equal
    /// (the script also covers directory entries and POSIX modes, which a
    /// cache key does not need), so the source name is part of the key and
    /// the two key spaces cannot collide.
    struct ModelIdentity {
        /// `manifest` (packaging's own number) or `content` (hashed here).
        let source: String
        /// 64 lowercase hex.
        let digest: String
        /// Cache-name component.
        var key: String { "\(source)-\(digest)" }
        /// For the `startup` record: enough to tell two models apart.
        var label: String { "\(source):\(digest.prefix(8))" }
    }

    /// `packaging/build-pkg.sh`: `install -m 644 "$MODEL_MANIFEST"
    /// "$SUPPORT/model-identity.tsv"` — always beside the model payload on an
    /// installed Mac, absent in a dev checkout.
    static let identityManifestName = "model-identity.tsv"

    static func identity(for source: URL) -> ModelIdentity? {
        if let digest = manifestDigest(for: source) {
            return ModelIdentity(source: "manifest", digest: digest)
        }
        if let digest = contentDigest(for: source) {
            return ModelIdentity(source: "content", digest: digest)
        }
        return nil
    }

    /// `sha256` from the sibling `model-identity.tsv`, but only when its
    /// `payload_path` names THIS package: a manifest left behind by a
    /// different model must never key this one (an install-over that changes
    /// `SENTRY_MODEL_FILE` replaces both files, but a hand-copied model into
    /// the support dir would not).
    static func manifestDigest(for source: URL) -> String? {
        let manifest = source.deletingLastPathComponent()
            .appendingPathComponent(Self.identityManifestName)
        // contentsOfFile, not contentsOf(URL:): a URL overload is a network
        // API to the egress audit and this
        // file may not hold one.
        guard let text = try? String(contentsOfFile: manifest.path, encoding: .utf8)
        else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard fields["payload_path"] == source.lastPathComponent,
            let sha = fields["sha256"], sha.count == 64,
            sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        return sha
    }

    /// Read size for the content walk. ASSUMED: one plain read syscall per MiB
    /// bounds this walk's peak RSS at the chunk while this runs on the startup
    /// path, before the first curtain.
    ///
    /// What the walk costs (MEASURED 2026-09-11, M1 Mac, warm page cache,
    /// `--resilience-selftest`'s `# idMs` lines): 14.0 ms for the shipped
    /// 17.5 MB student, 34.9 ms for the 51.5 MB fp16 export, 71.1 ms for the
    /// 102.6 MB fp32 one — ≈0.7 GB/s, so 0.4 % of the ≈3.4 s startup for the
    /// model we ship. An INSTALLED Mac does not pay it at all: the identity
    /// comes from the manifest beside the payload. Every launch also records
    /// its own number as `idMs=` in the `startup` record, so this stays
    /// measured rather than assumed.
    static let digestChunkBytes = 1 << 20

    /// Content digest of the package: sorted `<relative path>\0<size>\0` plus
    /// the file's bytes, for every regular file. nil when any entry cannot be
    /// read — an unreadable package gets NO cache entry rather than a digest
    /// over a partial read (`resolveModel` says so by name).
    static func contentDigest(for source: URL) -> String? {
        let fm = FileManager.default
        guard let subpaths = try? fm.subpathsOfDirectory(atPath: source.path) else { return nil }
        var hasher = SHA256()
        for relative in subpaths.sorted() {
            // pkgbuild can encode extended attributes as AppleDouble
            // sidecars; they are package metadata, not model identity, and
            // `model-identity.sh measure` skips them for the same reason.
            if relative.split(separator: "/").contains(where: { $0.hasPrefix("._") }) { continue }
            let full = source.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &isDirectory) else { return nil }
            if isDirectory.boolValue { continue }
            guard
                let size = (try? fm.attributesOfItem(atPath: full.path))?[.size] as? Int,
                let handle = try? FileHandle(forReadingFrom: full)
            else { return nil }
            defer { try? handle.close() }
            hasher.update(data: Data("\(relative)\0\(size)\0".utf8))
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: Self.digestChunkBytes),
                        !chunk.isEmpty
                    else { break }
                    hasher.update(data: chunk)
                } catch {
                    return nil
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Cache locations in preference order, named by identity. Next to the
    /// source is fast and shared (writable for a dev checkout). The per-user
    /// caches dir is the D2 fallback: a PRODUCTION install roots the support
    /// dir at root:wheel, so the next-to-source write fails and — before that
    /// fallback — every launch re-paid the compile (MEASURED 2026-08-22,
    /// first system install: the recompile landed in the post-boot window and
    /// pushed the first curtain out ~20 s). ~/Library/Caches is user-writable
    /// and per-account, so the compile is paid once per user, not once per
    /// launch.
    ///
    /// CORRECTED 2026-09-28 (security review). The earlier receipt here
    /// called a poisoned per-user cache "self-harm only". That was wrong for
    /// this product: the protected account IS the adversary, and a loadable
    /// model that never fires leaves protection looking healthy while it
    /// covers nothing. So when the source is PROTECTED (`CacheTrust`: owned
    /// by another uid, i.e. the root-owned installed payload), the per-user
    /// Caches candidate is not a candidate at all (`includeUserCache: false`),
    /// and the entry next to the source is used only when its whole tree
    /// passes `untrustedReason`. That entry is compiled as root at install
    /// (`--compile-model-cache`, configure-install.sh), which also removes the
    /// D2 cost the per-user fallback existed for. A dev checkout (source owned
    /// by this uid) keeps both candidates: there the account and the source
    /// owner are the same person.
    static func cacheCandidates(
        for source: URL, identity: ModelIdentity, includeUserCache: Bool = true
    ) -> [URL] {
        let name = "\(source.deletingPathExtension().lastPathComponent).\(identity.key).mlmodelc"
        var out = [source.deletingLastPathComponent().appendingPathComponent(name)]
        if includeUserCache, let caches = userCacheDir() {
            out.append(caches.appendingPathComponent(name))
        }
        return out
    }

    static func userCacheDir() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SentryScreen", isDirectory: true)
    }

    /// Who may have written a compiled model this process loads (T3).
    struct CacheTrust {
        /// Every node of a trusted entry must be owned by this uid: the
        /// source package's owner.
        let owner: uid_t
        /// This process cannot write the source (installed Mac: root payload,
        /// agent running as the user). Then only a verified entry next to the
        /// source is used, and the per-user cache is never read.
        let protected: Bool

        /// Dev fallback when the source cannot be stat'ed: unprotected, which
        /// is also what `identity == nil` already degrades to (no cache).
        static func of(_ source: URL) -> CacheTrust {
            var info = stat()
            guard lstat(source.path, &info) == 0 else {
                return CacheTrust(owner: geteuid(), protected: false)
            }
            return CacheTrust(owner: info.st_uid, protected: info.st_uid != geteuid())
        }
    }

    /// nil when every node of `entry` is a directory or regular file owned by
    /// `owner` with no group- or other-write bit; else what was observed on
    /// the first node that failed. lstat throughout: a symlink anywhere in the
    /// tree is refused, never followed.
    static func untrustedReason(_ entry: URL, owner: uid_t) -> String? {
        func check(_ path: String) -> String? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return "unreadable \(path) errno=\(errno)" }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { return "not a file or directory: \(path)" }
            guard info.st_uid == owner else { return "owner uid \(info.st_uid) (want \(owner)): \(path)" }
            guard info.st_mode & 0o022 == 0 else {
                return "group/other-writable mode \(String(info.st_mode & 0o7777, radix: 8)): \(path)"
            }
            return nil
        }
        if let problem = check(entry.path) { return problem }
        guard let walker = FileManager.default.enumerator(atPath: entry.path) else {
            return "cannot list \(entry.path)"
        }
        while let relative = walker.nextObject() as? String {
            if let problem = check(entry.appendingPathComponent(relative).path) { return problem }
        }
        return nil
    }

    /// The `--compile-model-cache` entry point: one line on stdout, exit 0,
    /// or one named failure on stderr, exit 1 (configure-install.sh reports
    /// it, the agent refuses to start, and the root watchdog retries the build).
    static func installCompiledCacheCommand(packagePath: String) -> Int32 {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let result = try installCompiledCache(
                source: URL(fileURLWithPath: packagePath), compile: { try MLModel.compileModel(at: $0) })
            print(String(format: "compile-model-cache: installed=%@ pruned=%d ms=%.0f",
                result.url.path, result.pruned, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            return 0
        } catch {
            FileHandle.standardError.write(Data(
                "compile-model-cache: FAILED package=\(packagePath) error=\(error)\n".utf8))
            return 1
        }
    }

    /// `--check-model-cache <package>` (watchdog.sh, as root, every pass): the
    /// agent's own rule for the trusted entry — the same identity, name and
    /// trust check — so the watchdog never re-derives the name in shell (a
    /// shell copy that disagreed would rebuild and restart every pass). One
    /// line on stdout, always exit 0: `ok <entry>`, `missing <entry>`,
    /// `untrusted <entry> — <reason>` or `unidentified <package>`. No compile
    /// and no CoreML load, so a pass stays cheap.
    static func checkCompiledCacheCommand(packagePath: String) -> Int32 {
        print(checkCompiledCache(source: URL(fileURLWithPath: packagePath)))
        return 0
    }

    /// The line `--check-model-cache` prints. Pure apart from reads;
    /// `--resilience-selftest` checks each answer.
    static func checkCompiledCache(source: URL, owner: uid_t? = nil) -> String {
        guard let identity = identity(for: source) else { return "unidentified \(source.path)" }
        let entry = cacheCandidates(for: source, identity: identity, includeUserCache: false)[0]
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { return "missing \(entry.path)" }
        if let problem = untrustedReason(entry, owner: owner ?? CacheTrust.of(source).owner) {
            return "untrusted \(entry.path) — \(problem)"
        }
        return "ok \(entry.path)"
    }

    /// `--compile-model-cache <package>` (configure-install.sh, as root): the
    /// trusted entry next to the source, compiled once at install so no
    /// launch has to compile or trust a user-writable copy. Staged beside the
    /// destination and renamed into place, modes 0755/0644, then verified with
    /// the same rule the agent applies. Returns the entry and how many stale
    /// entries it pruned.
    static func installCompiledCache(
        source: URL, compile: (URL) throws -> URL
    ) throws -> (url: URL, pruned: Int) {
        struct InstallFailed: Error, CustomStringConvertible { let description: String }
        let fm = FileManager.default
        guard let identity = identity(for: source) else {
            throw InstallFailed(description: "cannot identify \(source.path) (no readable model-identity.tsv or package)")
        }
        let dest = cacheCandidates(for: source, identity: identity, includeUserCache: false)[0]
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).\(getpid()).staging")
        try? fm.removeItem(at: staging)
        let fresh = try compile(source)
        defer { try? fm.removeItem(at: fresh) }
        try fm.copyItem(at: fresh, to: staging)
        for relative in [""] + ((try? fm.subpathsOfDirectory(atPath: staging.path)) ?? []) {
            let path = relative.isEmpty ? staging.path : staging.appendingPathComponent(relative).path
            var isDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: path, isDirectory: &isDirectory)
            try fm.setAttributes([.posixPermissions: isDirectory.boolValue ? 0o755 : 0o644], ofItemAtPath: path)
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        guard rename(staging.path, dest.path) == 0 else {
            let err = errno
            try? fm.removeItem(at: staging)
            throw InstallFailed(description: "rename \(staging.path) -> \(dest.path) errno=\(err)")
        }
        if let problem = untrustedReason(dest, owner: geteuid()) {
            throw InstallFailed(description: "installed entry fails its own trust check: \(problem)")
        }
        return (dest, pruneStale(keeping: dest, source: source))
    }

    /// Compile-or-reuse, then load — with exactly ONE recovery attempt.
    ///
    /// RECEIPT (2026-09-11): a cache entry the daemon cannot load used
    /// to throw straight out of `init` with no fallback, and the per-user cache
    /// dir is writable by the very account the agent runs as — so one corrupt
    /// ~/Library/Caches entry was a PERMANENT protection outage, repeated on
    /// every launch. On a shipped install (`captureLoss: banner`,
    /// `packaging/config.sample.json`) that surfaces as
    /// `UIOnboardingRuntime.captureFailed` — the process lives on with no
    /// pipeline, the parent sees the failure surface, and the watchdog
    /// restarts it every SUMMARY_STALE_SECS (600 s) forever; with
    /// `captureLoss: exit` or `--process` (dev, the gate) it is
    /// `die(code: 4)`. Either way nothing was filtered and nothing healed.
    ///
    /// The limit is ONE recompile per launch, and only when a PRE-EXISTING
    /// cache entry is the suspect (`origin == "cache"`). A recompile costs
    /// ~20 s (MEASURED 2026-08-22), so two would be a ~40 s startup — and for
    /// `fresh` (just compiled and copied into the cache) or `temp` (compiled
    /// into /tmp because no cache dir was writable) there is nothing to
    /// blame: those bytes came out of `compile` seconds ago, so a load failure
    /// means the SOURCE is broken, which no amount of recompiling repairs.
    /// Recompiling them anyway would also DELETE a cache entry this launch
    /// just wrote correctly. Both outcomes — recovered, and
    /// recompile-did-not-help — are named loudly.
    ///
    /// Generic over the loaded model so `--resilience-selftest` can drive
    /// every branch with its own compile/load closures (no weights, no ~20 s
    /// compile); the production call site passes the real CoreML ones.
    static func resolveModel<Model>(
        source: URL,
        identity: ModelIdentity?,
        trust: CacheTrust? = nil,
        compile: (URL) throws -> URL,
        load: (URL) throws -> Model,
        warn: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) throws -> (model: Model, compile: String, pruned: Int) {
        let trust = trust ?? CacheTrust(owner: geteuid(), protected: false)
        let first = try compiledURL(
            source: source, identity: identity, trust: trust, ignoringCache: false,
            compile: compile, warn: warn)
        do {
            return (try load(first.url), first.origin, first.pruned)
        } catch {
            // Only a PRE-EXISTING cache entry can be the suspect: "fresh" and
            // "temp" were produced from the source seconds ago, so there is
            // nothing to blame, nothing to delete, and a second ~20 s compile
            // would change nothing (receipt above).
            guard first.origin == "cache" else { throw error }
            // A protected source cannot delete or replace its trusted entry
            // and never compiles its own (`UntrustedOnly`), so the repair is
            // the root watchdog's: main.swift leaves MODEL_LOAD_FAILED in this
            // account's log dir and watchdog.sh rebuilds the entry.
            if trust.protected {
                throw TrustedLoadFailed(description: "the trusted compiled model at "
                    + "\(first.url.path) is present but will not load (\(error)) — the watchdog "
                    + "rebuilds it as root within a minute (fix: reinstall the package if this persists)")
            }
            warn("WARNING: tripwire MODEL_CACHE_RECOVERY, limit 1 recompile per launch, "
                + "observed a compiled-model load failure at \(first.url.path) (\(error)) — "
                + "deleting that cache entry and recompiling once "
                + "(fix: if this repeats, reinstall the model payload; the cache locations "
                + "are Detector.cacheCandidates)\n")
            // Never silent: if the entry cannot be removed (an immutable flag,
            // a root-owned candidate next to the payload) the recompile below
            // still recovers via the next writable candidate or a temp
            // compile, but EVERY launch then pays ~20 s — and the line above
            // would otherwise claim a deletion that did not happen.
            do {
                try FileManager.default.removeItem(at: first.url)
            } catch {
                warn("WARNING: MODEL_CACHE_RECOVERY could not delete \(first.url.path) "
                    + "(\(error)) — the poisoned entry stays, so every launch pays the "
                    + "recompile (~20 s) until it is removed by hand "
                    + "(fix: rm -rf that path)\n")
            }
            let second = try compiledURL(
                source: source, identity: identity, trust: trust, ignoringCache: true,
                compile: compile, warn: warn)
            do {
                let model = try load(second.url)
                warn("WARNING: MODEL_CACHE_RECOVERY recovered — recompiled "
                    + "\(source.lastPathComponent) to \(second.url.path) and loaded it; "
                    + "this launch paid the compile (~20 s)\n")
                return (model, "recompiled", first.pruned + second.pruned)
            } catch {
                warn("WARNING: tripwire MODEL_CACHE_RECOVERY exhausted, limit 1 recompile per "
                    + "launch, observed a second load failure at \(second.url.path) "
                    + "(\(error)) — the model source itself is unusable, not the cache "
                    + "(fix: reinstall the model payload, packaging/install.sh)\n")
                throw error
            }
        }
    }

    /// A protected source with no trusted compiled entry.
    struct UntrustedOnly: Error, CustomStringConvertible { let description: String }
    /// A protected source whose trusted entry exists but will not load.
    struct TrustedLoadFailed: Error, CustomStringConvertible { let description: String }
    /// The marker an agent leaves in its own log dir for `TrustedLoadFailed`;
    /// watchdog.sh rebuilds the entry when it is newer than the entry.
    static let loadFailedMarker = "MODEL_LOAD_FAILED"

    private static func compiledURL(
        source: URL,
        identity: ModelIdentity?,
        trust: CacheTrust,
        ignoringCache: Bool,
        compile: (URL) throws -> URL,
        warn: (String) -> Void
    ) throws -> (url: URL, origin: String, pruned: Int) {
        let fm = FileManager.default
        if identity == nil {
            warn("WARNING: cannot read \(source.path) to identify it, so the compiled-model "
                + "cache is DISABLED for this launch and every launch recompiles (~20 s) "
                + "(fix: the model path/permissions — Detector.identity)\n")
        }
        let candidates = identity.map {
            Self.cacheCandidates(for: source, identity: $0, includeUserCache: !trust.protected)
        } ?? []
        // A protected source never reads the per-user cache again, so the
        // entries older builds wrote there are dead weight (~50 MB each).
        // Removing our own names in our own Caches is housekeeping, not a
        // tamper signal: those entries are expected on every upgraded Mac.
        var pruned = 0
        if trust.protected, !ignoringCache, let identity, let dir = userCacheDir() {
            let probe = dir.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent).\(identity.key).mlmodelc")
            // pruneStale keeps `keeping`, so remove that exact name as well.
            if (try? fm.removeItem(at: probe)) != nil { pruned += 1 }
            pruned += pruneStale(keeping: probe, source: source)
        }
        if !ignoringCache {
            // Keyed on content, so EXISTING is fresh — no mtime comparison.
            for cache in candidates where fm.fileExists(atPath: cache.path) {
                if trust.protected, let problem = untrustedReason(cache, owner: trust.owner) {
                    // Never trusted, never deleted (it is not ours to delete:
                    // only root or an administrator can have placed it).
                    warn("WARNING: tamper MODEL_CACHE_TRUST, configured=every node owned by uid "
                        + "\(trust.owner) with no group/other write, observed \(problem) — "
                        + "NOT loading \(cache.path); the root watchdog rebuilds it "
                        + "(fix: reinstall the package if this repeats; configure-install.sh recompiles it)\n")
                    continue
                }
                return (cache, "cache", pruned)
            }
        }
        // A protected source (the installed, root-owned payload) never compiles
        // a copy of its own (security review 2026-10-18): the only place this
        // process could write one is the account's own temp or cache folder,
        // which a Standard account controls, so it could swap the compiled
        // model between compile and load for one that never fires. The agent
        // shows the failure and the root watchdog rebuilds the trusted entry
        // (watchdog.sh check_model_cache), then restarts this agent.
        if trust.protected {
            throw UntrustedOnly(description: (candidates.isEmpty
                    ? "the model at \(source.path) cannot be identified, so no trusted compiled entry can be named"
                    : "no trusted compiled model at \(candidates.map(\.path).joined(separator: ", "))")
                + " — refusing to compile a copy "
                + "this account could change; the watchdog rebuilds it as root within a minute "
                + "(fix: reinstall the package if this persists; configure-install.sh compiles it)")
        }
        let fresh = try compile(source)
        // A protected source's only candidate is the root-owned entry, which
        // this process must never write (a copy it made would be owned by
        // the protected account and refused on the next launch).
        for cache in candidates where !trust.protected {
            try? fm.createDirectory(
                at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: cache)
            if (try? fm.copyItem(at: fresh, to: cache)) != nil {
                // Compile output copied — drop the ~50 MB temp now instead of
                // leaving it for macOS's days-later reaping (2026-08-21).
                try? fm.removeItem(at: fresh)
                return (cache, "fresh", pruned + pruneStale(keeping: cache, source: source))
            }
        }
        // No candidate writable — per-launch temp compile keeps the launch
        // alive (vs the old die-here path that leaked a temp per restart).
        // Loud: per-launch recompile is a real cost someone must fix.
        if !candidates.isEmpty {
            warn("WARNING: compiled-model cache unwritable at all of "
                + "\(candidates.map(\.path).joined(separator: ", ")) — using temp compile "
                + "for this launch; every launch recompiles (~20 s) until a cache dir is "
                + "writable.\n")
        }
        return (fresh, "temp", pruned)
    }

    /// Content-keyed names mean a model upgrade would leave the old compiled
    /// model (~50 MB) behind forever, so the launch that writes a NEW entry
    /// removes the stale entries it owns. Two shapes count as ours:
    /// `<stem>.<source>-<64 hex>.mlmodelc` (this scheme's own name), and — only
    /// OUTSIDE the source's own directory — the pre-2026-09-11
    /// `<stem>.mlmodelc`, which is the UPGRADE PATH: the first launch on this
    /// change recompiles under the new name, and without this the old entry
    /// would sit in every user's ~/Library/Caches forever. Inside the source's
    /// directory that same name may be a developer's or an exporter's
    /// own artifact, so it is never touched there. Counted into the `startup`
    /// record's `pruned=` so a cache that churns is visible rather than silent.
    static func pruneStale(keeping cache: URL, source: URL) -> Int {
        let fm = FileManager.default
        let stem = source.deletingPathExtension().lastPathComponent
        let dir = cache.deletingLastPathComponent()
        let ownsLegacyName = dir.standardizedFileURL
            != source.deletingLastPathComponent().standardizedFileURL
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names where name != cache.lastPathComponent {
            guard name.hasPrefix("\(stem)."), name.hasSuffix(".mlmodelc") else { continue }
            let middle = String(name.dropFirst(stem.count + 1).dropLast(".mlmodelc".count))
            if middle.isEmpty {
                guard ownsLegacyName else { continue }
            } else {
                guard let dash = middle.firstIndex(of: "-") else { continue }
                let keySource = String(middle[middle.startIndex..<dash])
                let digest = String(middle[middle.index(after: dash)...])
                guard ["manifest", "content"].contains(keySource), digest.count == 64,
                    digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
                else { continue }
            }
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// One detector pass: `kept` is every box at or above `minConfidence`
    /// (what protection sees), `weak` every box under it. `weak` is empty
    /// unless `nmsFloor` lowered the model's own floor below `minConfidence`.
    struct Pass {
        var kept: [Detection]
        var weak: [Detection] = []
        /// Zoom prototype (`detect(tile:)`): the tile pass's boxes
        /// at the model's floor, mapped to the full frame. Empty otherwise.
        var tile: [Detection] = []
    }

    /// TUNING TOOL — the Detection view's "Show weak detections". Both
    /// exported model families declare the embedded NMS's confidence floor
    /// as an optional pipeline input, `confidenceThreshold`
    /// (`model/training/export_yolox_coreml.py`, default
    /// CONF_DEFAULT 0.25), and Vision feeds
    /// inputs the image does not supply from `VNCoreMLModel.featureProvider`.
    /// So the SAME model file returns boxes under 0.25 on request — no
    /// second export. MEASURED 2026-09-25 on an M1 Mac (benign
    /// daemon/testdata/portrait.jpg, shipped v8 student): default 1 box (FACE_FEMALE
    /// 0.589); at 0.05 two boxes, the same 0.589 box first and unchanged plus
    /// FACE_MALE 0.074; back to the default, 1 box again.
    ///
    /// A LOWER FLOOR IS NOT A SUPERSET. MEASURED 2026-09-25 on an M1 Mac, the
    /// 13 gate fixtures through `--process` with the floor at 0.05 against
    /// unset, 640m and the v8 student alike: every log differed — the boxes
    /// over 0.25 themselves move (steady/region 640m frame 13: FACE_FEMALE
    /// 0.6982 → 0.6973, box x 0.368 → 0.369; 1,441 of 1,803 rows differ).
    /// Deterministic (floor 0.05 twice: identical; floor 0.25 through this
    /// provider: identical to unset), and the same on CPU only, so it is the
    /// NMS's own selection, not run-to-run noise. Hence `detect` runs the
    /// default-floor pass for protection ALWAYS and the lowered floor as a
    /// SECOND pass whose boxes only feed `Pass.weak`.
    private final class NMSFloor: NSObject, MLFeatureProvider {
        let floor: Double
        init(_ floor: Float) { self.floor = Double(floor) }
        var featureNames: Set<String> { ["confidenceThreshold"] }
        func featureValue(for name: String) -> MLFeatureValue? {
            name == "confidenceThreshold" ? MLFeatureValue(double: floor) : nil
        }
    }

    /// `nmsFloor` (tuning tools; nil otherwise): the model's
    /// NMS floor for this call (`NMSFloor`). `shiftPx` (the settle re-check,
    /// `Pipeline.settleShiftPx`): crop that many buffer pixels off the left
    /// and the top edge (`regionOfInterest`), so the content sits at a
    /// different offset on the model's input grid; boxes come back mapped to
    /// the FULL frame (Vision reports them relative to the region of
    /// interest — MEASURED 2026-09-25 with a half-frame region: a face at
    /// x 0.63–0.94 of the frame came back at x 0.48 of the region).
    ///
    /// `kept` always comes from a pass at the model's own floor. With
    /// `nmsFloor` set, a second pass at that floor supplies `weak` (its
    /// boxes under `minConfidence`); the two are never mixed (receipt at
    /// `NMSFloor`). The second pass costs one more inference per frame, only
    /// while the toggle is on.
    ///
    /// `tile` (tuning tools; nil otherwise): the zoom prototype
    /// (`ZoomTiles`). A second request on `tile` (a Vision region of
    /// interest, so Vision crops it and `.scaleFill`-stretches it to the
    /// model input) runs on the SAME handler as the full-frame request, and
    /// supplies `Pass.tile`. One handler, not two: MEASURED 2026-10-07 on the
    /// Studio, full + tile cost p50
    /// 18.0 ms on one handler against 22.1 ms on two, and the full-frame
    /// boxes are identical either way (6,765 of 6,765 frames).
    func detect(
        _ pixelBuffer: CVPixelBuffer, minConfidence: Float, nmsFloor: Float? = nil, shiftPx: Int = 0,
        tile: CGRect? = nil
    ) throws -> Pass {
        let roi = shiftPx > 0 ? Self.shiftedRegion(pixelBuffer, shiftPx: shiftPx) : nil
        let results = try observe(pixelBuffer, rois: [roi] + (tile.map { [$0] } ?? []))
        var pass = Pass(kept: results[0].filter { $0.confidence >= minConfidence })
        if tile != nil { pass.tile = results[1].filter { $0.confidence >= minConfidence } }
        if let nmsFloor {
            vnModel.featureProvider = NMSFloor(nmsFloor)
            defer { vnModel.featureProvider = nil }
            pass.weak = try observe(pixelBuffer, roi: roi).filter { $0.confidence < minConfidence }
        }
        return pass
    }

    /// The settle re-check's region: `shiftPx` buffer pixels cropped off the
    /// left and the top edge. Vision's region is bottom-left normalized.
    private static func shiftedRegion(_ pixelBuffer: CVPixelBuffer, shiftPx: Int) -> CGRect {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        return CGRect(x: CGFloat(shiftPx) / w, y: 0,
            width: 1 - CGFloat(shiftPx) / w, height: 1 - CGFloat(shiftPx) / h)
    }

    /// A box Vision reports relative to `roi` (both bottom-left normalized),
    /// mapped to the full frame.
    static func toFrame(_ b: CGRect, roi: CGRect) -> CGRect {
        CGRect(x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height,
            width: b.width * roi.width, height: b.height * roi.height)
    }

    /// One inference: every box the model returns, mapped to the full frame.
    /// `roi` nil is the whole frame (no region set on the request).
    private func observe(_ pixelBuffer: CVPixelBuffer, roi: CGRect?) throws -> [Detection] {
        try observe(pixelBuffer, rois: [roi])[0]
    }

    /// One request per region, all on ONE handler (one `perform`); results
    /// in the same order.
    private func observe(_ pixelBuffer: CVPixelBuffer, rois: [CGRect?]) throws -> [[Detection]] {
        // MEASURED 2026-08-27: a test Mac acceptance run grew from 170 MB
        // to 206 MB RSS in 35 minutes and crossed the existing 150 MiB
        // tripwire in every summary. Vision and CoreML return Objective-C
        // objects, so bound one complete synchronous inference lifetime. The
        // returned Detection values contain only Swift values and CGRects.
        return try autoreleasepool {
            let requests = rois.map { roi in
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .scaleFill
                if let roi { request.regionOfInterest = roi }
                return request
            }
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform(requests)
            return zip(requests, rois).map { request, roi in
                Self.detections(request.results as? [VNRecognizedObjectObservation] ?? [], roi: roi)
            }
        }
    }

    /// Vision observations -> Detections, boxes mapped to the full frame.
    private static func detections(
        _ observations: [VNRecognizedObjectObservation], roi: CGRect?
    ) -> [Detection] {
        var out: [Detection] = []
        for obs in observations {
            // The detection's confidence is `obs.confidence` — the model's
            // raw obj·cls score for this box — NOT `top.confidence`.
            // RECEIPT:
            // Vision re-normalises every
            // observation's label row to Σ = 1 (1.000 ± 3e-8 on all 230),
            // so `labels.first.confidence` is the top class's SHARE of the
            // row — ≥ 0.99 for 95 % of those boxes and exactly 1.0 for
            // 86 % of 9,202 live detections
            // — while `VNObservation.confidence` spans 0.25–0.92 and
            // matches the raw NMS row top within the resampler seam on
            // every box checked. Until 2026-09-02 this line read the share,
            // so every receipted floor (TuningPolicy.defaults: 0.5
            // explicit / 0.6 covered, Tracker.stickyConf 0.6, --conf 0.25)
            // compared against ≈ 1.0. DERIVED: the daemon's only effective
            // floor was therefore the export constant CONF_DEFAULT 0.25
            // baked into the NMS (re-scoring the probe at 0.25 for every
            // class reproduces the as-shipped counts exactly).
            // DERIVED effect of reading the raw score — an emulation from
            // the probe's `obs_conf` at today's floors on stored eval-v8
            // frames, not a run of this binary: clean-screen FP 6 → 0 /250,
            // v3_all FP 108 → 44 (P .878 → .941, R .634 → .575), parity
            // headline FAIL → PASS at X = 0.05 and 0.10; covered captures
            // 57/37 → 25/12 tp/fp.
            // CAVEAT: "VNObservation.confidence is the raw score" is
            // empirical (230 observations, 5 box-level matches against the
            // coremltools NMS output), not Apple-documented. Two tripwires
            // hold it: the gate fixtures pin every logged `conf` byte-for-
            // byte (vispolicy-base, re-frozen with this change), and
            // score.py's `detector_conf_not_saturated` criterion fails a
            // replay whose detections read ≥ 0.99 again.
            guard let top = obs.labels.first else { continue }
            let b = obs.boundingBox
            let box = roi.map { Self.toFrame(b, roi: $0) } ?? b
            out.append(Detection(label: top.identifier, confidence: obs.confidence, box: box))
        }
        return out
    }
}
