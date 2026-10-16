import Foundation

/// Executable asserts for the two crash-loop defects fixed 2026-09-11,
/// neither of which had a test anywhere:
///
///  * the compiled-model cache (`Detector`): a cache entry that will not load
///    is recovered ONCE instead of being fatal on every launch, and the cache
///    is keyed on the package's CONTENT so replacing a file inside the
///    .mlpackage can no longer keep a stale compiled model alive;
///  * the startup log roll (`Logger`): a run that died inside
///    `minRolledRunLifetimeSecs` does not spend a generation, so a ~10 s
///    launchd crash loop can no longer erase the run that explains it.
///
/// Headless, no weights, no window, no compile: the cache cases inject their
/// own compile/load closures into `Detector.resolveModel`, so a "model" here
/// is a directory and a "load" is whatever the case wants to fail.
///
/// `sentry-screen --resilience-selftest`; exit 0 = every case ok.
enum ResilienceSelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                passed += 1
                print("ok - \(name)")
            } else {
                failed += 1
                print("not ok - \(name)\(detail.isEmpty ? "" : "  \(detail)")")
            }
        }

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentry-resilience-selftest-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: root)
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            print("not ok - selftest temp dir \(root.path)")
            return 1
        }
        defer { try? fm.removeItem(at: root) }

        // MARK: - Model identity (the stale-cache half)

        /// A fake .mlpackage with the real layout: identity walks files, so
        /// the bytes matter and nothing here is ever compiled.
        func makePackage(_ name: String, weights: String) -> URL? {
            let pkg = root.appendingPathComponent(name)
            let inner = pkg.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
            guard (try? fm.createDirectory(at: inner, withIntermediateDirectories: true)) != nil,
                (try? Data("{}".utf8).write(to: pkg.appendingPathComponent("Manifest.json")))
                    != nil,
                (try? Data(weights.utf8).write(to: inner.appendingPathComponent("weight.bin")))
                    != nil
            else { return nil }
            return pkg
        }

        guard let pkg = makePackage("stale.mlpackage", weights: "version-one") else {
            print("not ok - selftest fixture package")
            return 1
        }
        // A whole-second date so "the directory mtime did not move" can be an
        // EXACT comparison (setAttributes stores whole seconds here).
        let frozen = Date(timeIntervalSince1970: 1_600_000_000)
        try? fm.setAttributes([.modificationDate: frozen], ofItemAtPath: pkg.path)
        let pkgMtime = (try? fm.attributesOfItem(atPath: pkg.path))?[.modificationDate] as? Date
        let keyOne = Detector.identity(for: pkg)
        check("content identity reads a package", keyOne?.source == "content",
              "got \(keyOne?.source ?? "nil")")
        check("content identity is stable for unchanged bytes",
              Detector.identity(for: pkg)?.key == keyOne?.key)

        // THE MODEL-IDENTITY PIN: an inner file replaced in place, with the package
        // DIRECTORY's mtime restored to what it was — the exact shape the old
        // mtime key could not see.
        let weight = pkg.appendingPathComponent("Data/com.apple.CoreML/weight.bin")
        try? Data("version-two!".utf8).write(to: weight)
        try? fm.setAttributes([.modificationDate: frozen], ofItemAtPath: pkg.path)
        let afterMtime = (try? fm.attributesOfItem(atPath: pkg.path))?[.modificationDate] as? Date
        check("fixture holds the package directory mtime still",
              pkgMtime == frozen && afterMtime == frozen,
              "before=\(String(describing: pkgMtime)) after=\(String(describing: afterMtime))")
        let keyTwo = Detector.identity(for: pkg)
        check("inner-file change is a DIFFERENT cache key (stale compile cannot win)",
              keyTwo != nil && keyTwo?.key != keyOne?.key,
              "one=\(keyOne?.label ?? "nil") two=\(keyTwo?.label ?? "nil")")
        check("cache candidate name carries the identity",
              Detector.cacheCandidates(for: pkg, identity: keyTwo!).first?.lastPathComponent
                  == "stale.\(keyTwo!.key).mlmodelc")

        // The installed shape: packaging's own number, via the manifest
        // build-pkg.sh writes beside the payload.
        let sha = String(repeating: "ab12cd34", count: 8)  // 64 lowercase hex
        let manifest = root.appendingPathComponent(Detector.identityManifestName)
        let manifestText = "# sentryscreen-model-identity-v1\npayload_path\tstale.mlpackage\n"
            + "sha256\t\(sha)\n"
        try? Data(manifestText.utf8).write(to: manifest)
        let fromManifest = Detector.identity(for: pkg)
        check("manifest identity wins when model-identity.tsv names this payload",
              fromManifest?.source == "manifest" && fromManifest?.digest == sha,
              "got \(fromManifest?.label ?? "nil")")
        try? Data(
            manifestText.replacingOccurrences(of: "stale.mlpackage", with: "other.mlpackage").utf8
        ).write(to: manifest)
        check("a manifest for another payload is ignored",
              Detector.identity(for: pkg)?.source == "content")
        try? fm.removeItem(at: manifest)

        // MARK: - Cache recovery (the no-fallback half)

        /// Stand-in for MLModel.compileModel: a directory whose one file says
        /// which compile produced it.
        var compiles = 0
        func compile(_ source: URL) throws -> URL {
            compiles += 1
            let out = root.appendingPathComponent("compile-\(compiles).mlmodelc", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try Data("compile \(compiles)".utf8)
                .write(to: out.appendingPathComponent("model.mil"))
            return out
        }
        struct LoadFailed: Error { let path: String }
        /// Stand-in for MLModel(contentsOf:) — fails for a cache entry a case
        /// has poisoned with a `corrupt` file, which is what a truncated or
        /// half-written .mlmodelc looks like from here.
        func load(_ url: URL) throws -> String {
            if fm.fileExists(atPath: url.appendingPathComponent("corrupt").path) {
                throw LoadFailed(path: url.path)
            }
            return (try? String(
                contentsOfFile: url.appendingPathComponent("model.mil").path,
                encoding: .utf8)) ?? "?"
        }
        var warnings = ""
        func warn(_ text: String) { warnings += text }

        guard let cachePkg = makePackage("cached.mlpackage", weights: "weights"),
            let cacheIdentity = Detector.identity(for: cachePkg)
        else {
            print("not ok - selftest cache fixture")
            return 1
        }
        // Candidate 1 is next to the source (writable here), so every case
        // below exercises a REAL cache dir, not the user's ~/Library/Caches.
        let entry = Detector.cacheCandidates(for: cachePkg, identity: cacheIdentity)[0]

        let first = try? Detector.resolveModel(
            source: cachePkg, identity: cacheIdentity, compile: compile, load: load, warn: warn)
        check("first load compiles and caches", first?.compile == "fresh" && compiles == 1,
              "compile=\(first?.compile ?? "nil") compiles=\(compiles)")
        let second = try? Detector.resolveModel(
            source: cachePkg, identity: cacheIdentity, compile: compile, load: load, warn: warn)
        check("second load reuses the cache with no compile",
              second?.compile == "cache" && compiles == 1,
              "compile=\(second?.compile ?? "nil") compiles=\(compiles)")

        // THE CACHE-RECOVERY PIN: a poisoned cache entry recovers ONCE and
        // the launch survives, where it used to die(code: 4) forever.
        try? Data("poison".utf8).write(to: entry.appendingPathComponent("corrupt"))
        warnings = ""
        let recovered = try? Detector.resolveModel(
            source: cachePkg, identity: cacheIdentity, compile: compile, load: load, warn: warn)
        check("a corrupt cache entry recovers instead of dying",
              recovered?.compile == "recompiled", "compile=\(recovered?.compile ?? "nil")")
        check("recovery costs EXACTLY one recompile", compiles == 2, "compiles=\(compiles)")
        check("recovery is loud by name",
              warnings.contains("MODEL_CACHE_RECOVERY")
                  && warnings.contains("limit 1 recompile per launch")
                  && warnings.contains("recovered"),
              warnings.isEmpty ? "(no warning)" : warnings)
        check("recovery replaced the poisoned entry",
              !fm.fileExists(atPath: entry.appendingPathComponent("corrupt").path)
                  && fm.fileExists(atPath: entry.path))
        check("the recovered launch loaded the NEW compile", recovered?.model == "compile 2",
              "model=\(recovered?.model ?? "nil")")

        // Second failure is fatal — and says so, rather than recompiling on.
        warnings = ""
        let before = compiles
        var fatal: Error?
        do {
            _ = try Detector.resolveModel(
                source: cachePkg, identity: cacheIdentity, compile: compile,
                load: { (url: URL) throws -> String in throw LoadFailed(path: url.path) },
                warn: warn)
        } catch { fatal = error }
        check("a second load failure is fatal", fatal is LoadFailed,
              "error=\(String(describing: fatal))")
        check("the fatal path recompiled once, not twice", compiles == before + 1,
              "compiles=\(compiles) before=\(before)")
        check("the fatal path names the exhausted tripwire",
              warnings.contains("MODEL_CACHE_RECOVERY exhausted")
                  && warnings.contains("the model source itself is unusable"),
              warnings.isEmpty ? "(no warning)" : warnings)

        // A FRESH compile that will not load is NOT a cache problem: recovery
        // must not run (review 2026-09-11 — `origin != "temp"` let this case
        // pay a second ~20 s compile and delete the entry it had just written
        // correctly). One compile, one throw, no recovery line at all.
        guard let freshPkg = makePackage("fresh-fails.mlpackage", weights: "unloadable"),
            let freshIdentity = Detector.identity(for: freshPkg)
        else {
            print("not ok - selftest fresh-compile fixture")
            return 1
        }
        warnings = ""
        let freshBefore = compiles
        var freshFatal: Error?
        do {
            _ = try Detector.resolveModel(
                source: freshPkg, identity: freshIdentity,
                // The compile output is poisoned, so `load` fails for the
                // freshly compiled model itself — a bad SOURCE, not a bad
                // cache entry.
                compile: { source in
                    let out = try compile(source)
                    try Data("poison".utf8).write(to: out.appendingPathComponent("corrupt"))
                    return out
                },
                load: load, warn: warn)
        } catch { freshFatal = error }
        check("a FRESH compile that will not load is fatal", freshFatal is LoadFailed,
              "error=\(String(describing: freshFatal))")
        check("a fresh-compile failure costs exactly ONE compile",
              compiles == freshBefore + 1, "compiles=\(compiles) before=\(freshBefore)")
        check("a fresh-compile failure never runs cache recovery",
              !warnings.contains("MODEL_CACHE_RECOVERY"),
              warnings.isEmpty ? "(no warning)" : warnings)
        check("a fresh-compile failure leaves its cache entry in place",
              fm.fileExists(
                  atPath: Detector.cacheCandidates(
                      for: freshPkg, identity: freshIdentity)[0].path))

        // A package that cannot be identified gets no cache entry at all, and
        // says so — it must never silently reuse someone else's compile.
        warnings = ""
        let missing = root.appendingPathComponent("absent.mlpackage")
        check("an unreadable package has no identity", Detector.identity(for: missing) == nil)
        let tempOnly = try? Detector.resolveModel(
            source: missing, identity: nil, compile: compile, load: load, warn: warn)
        check("no identity ⇒ temp compile, cache disabled, loudly",
              tempOnly?.compile == "temp" && warnings.contains("cache is DISABLED"),
              "compile=\(tempOnly?.compile ?? "nil") warn=\(warnings)")
        // The other arm of the same guard: a temp compile that will not load
        // has no cache entry to blame either.
        warnings = ""
        let tempBefore = compiles
        var tempFatal: Error?
        do {
            _ = try Detector.resolveModel(
                source: missing, identity: nil,
                compile: { source in
                    let out = try compile(source)
                    try Data("poison".utf8).write(to: out.appendingPathComponent("corrupt"))
                    return out
                },
                load: load, warn: warn)
        } catch { tempFatal = error }
        check("a temp compile that will not load is fatal after ONE compile",
              tempFatal is LoadFailed && compiles == tempBefore + 1
                  && !warnings.contains("MODEL_CACHE_RECOVERY"),
              "error=\(String(describing: tempFatal)) compiles=\(compiles)")

        // Stale entries this scheme owns are pruned; a hand-built
        // <stem>.mlmodelc next to a developer's weights is not touched.
        let handBuilt = cachePkg.deletingLastPathComponent()
            .appendingPathComponent("cached.mlmodelc", isDirectory: true)
        let otherKey = cachePkg.deletingLastPathComponent().appendingPathComponent(
            "cached.content-\(String(repeating: "0", count: 64)).mlmodelc", isDirectory: true)
        try? fm.createDirectory(at: handBuilt, withIntermediateDirectories: true)
        try? fm.createDirectory(at: otherKey, withIntermediateDirectories: true)
        check("pruning removes only this scheme's stale entries",
              Detector.pruneStale(keeping: entry, source: cachePkg) == 1
                  && !fm.fileExists(atPath: otherKey.path)
                  && fm.fileExists(atPath: handBuilt.path)
                  && fm.fileExists(atPath: entry.path))

        // Upgrade path: the pre-2026-09-11 `<stem>.mlmodelc` in a CACHE dir
        // (not the source's own dir) is this scheme's to remove, or it sits in
        // every user's ~/Library/Caches forever.
        let cacheDir = root.appendingPathComponent("caches", isDirectory: true)
        let legacy = cacheDir.appendingPathComponent("cached.mlmodelc", isDirectory: true)
        let cacheEntry = cacheDir.appendingPathComponent(
            "cached.\(cacheIdentity.key).mlmodelc", isDirectory: true)
        try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheEntry, withIntermediateDirectories: true)
        check("pruning removes the legacy cache name outside the source dir",
              Detector.pruneStale(keeping: cacheEntry, source: cachePkg) == 1
                  && !fm.fileExists(atPath: legacy.path)
                  && fm.fileExists(atPath: cacheEntry.path))

        // MARK: - Trusted compiled model (security review 2026-09-28, T3)

        // A protected source (installed: root payload, agent as the user)
        // never reads the per-user cache and loads the entry next to the
        // source only when every node is owned by the source's owner with no
        // group/other write. Root cannot be faked here, so `owner` is set to
        // a uid these files do NOT have (refusal cases) or to this uid
        // (acceptance cases); `protected` is set explicitly.
        guard let guardedPkg = makePackage("guarded.mlpackage", weights: "guarded"),
            let guardedIdentity = Detector.identity(for: guardedPkg)
        else {
            print("not ok - selftest trust fixture")
            return 1
        }
        let me = geteuid()
        let stranger: uid_t = me == 0 ? 501 : 0
        let guardedEntry = Detector.cacheCandidates(
            for: guardedPkg, identity: guardedIdentity, includeUserCache: false)[0]
        check("a protected source has exactly one candidate, next to the source",
              Detector.cacheCandidates(for: guardedPkg, identity: guardedIdentity,
                  includeUserCache: false).count == 1
                  && guardedEntry.deletingLastPathComponent().path
                      == guardedPkg.deletingLastPathComponent().path)
        func plantEntry() {
            try? fm.removeItem(at: guardedEntry)
            try? fm.createDirectory(at: guardedEntry, withIntermediateDirectories: true)
            try? Data("planted".utf8).write(to: guardedEntry.appendingPathComponent("model.mil"))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guardedEntry.path)
            try? fm.setAttributes([.posixPermissions: 0o644],
                ofItemAtPath: guardedEntry.appendingPathComponent("model.mil").path)
        }

        plantEntry()
        warnings = ""
        var trustBefore = compiles
        let refused = try? Detector.resolveModel(
            source: guardedPkg, identity: guardedIdentity,
            trust: Detector.CacheTrust(owner: stranger, protected: true),
            compile: compile, load: load, warn: warn)
        check("a protected source refuses an entry owned by another uid",
              refused?.compile == "temp" && refused?.model != "planted" && compiles == trustBefore + 1,
              "compile=\(refused?.compile ?? "nil") model=\(refused?.model ?? "nil")")
        check("the refusal is a named warning",
              warnings.contains("tamper MODEL_CACHE_TRUST"), warnings)
        check("a refused entry is never written over or deleted by the agent",
              (try? String(contentsOfFile: guardedEntry.appendingPathComponent("model.mil").path,
                  encoding: .utf8)) == "planted")

        plantEntry()
        warnings = ""
        let trusted = try? Detector.resolveModel(
            source: guardedPkg, identity: guardedIdentity,
            trust: Detector.CacheTrust(owner: me, protected: true),
            compile: compile, load: load, warn: warn)
        check("a protected source loads an entry whose whole tree passes the trust rule",
              trusted?.compile == "cache" && trusted?.model == "planted" && !warnings.contains("MODEL_CACHE_TRUST"),
              "compile=\(trusted?.compile ?? "nil") warnings=\(warnings)")

        plantEntry()
        try? fm.setAttributes([.posixPermissions: 0o666],
            ofItemAtPath: guardedEntry.appendingPathComponent("model.mil").path)
        warnings = ""
        trustBefore = compiles
        let writable = try? Detector.resolveModel(
            source: guardedPkg, identity: guardedIdentity,
            trust: Detector.CacheTrust(owner: me, protected: true),
            compile: compile, load: load, warn: warn)
        check("a group/other-writable file anywhere in the entry is refused",
              writable?.compile == "temp" && compiles == trustBefore + 1 && warnings.contains("group/other-writable"),
              "compile=\(writable?.compile ?? "nil") warnings=\(warnings)")

        plantEntry()
        try? fm.removeItem(at: guardedEntry.appendingPathComponent("model.mil"))
        _ = symlink(root.appendingPathComponent("elsewhere").path,
            guardedEntry.appendingPathComponent("model.mil").path)
        warnings = ""
        let linked = try? Detector.resolveModel(
            source: guardedPkg, identity: guardedIdentity,
            trust: Detector.CacheTrust(owner: me, protected: true),
            compile: compile, load: load, warn: warn)
        check("a symlink inside the entry is refused, never followed",
              linked?.compile == "temp" && warnings.contains("not a file or directory"),
              "compile=\(linked?.compile ?? "nil") warnings=\(warnings)")

        try? fm.removeItem(at: guardedEntry)
        warnings = ""
        let missingEntry = try? Detector.resolveModel(
            source: guardedPkg, identity: guardedIdentity,
            trust: Detector.CacheTrust(owner: stranger, protected: true),
            compile: compile, load: load, warn: warn)
        check("a missing trusted entry is a loud temp compile, not a tamper report",
              missingEntry?.compile == "temp"
                  && warnings.contains("no trusted compiled model")
                  && !fm.fileExists(atPath: guardedEntry.path),
              "compile=\(missingEntry?.compile ?? "nil")")

        // Install-time compile (`--compile-model-cache`, run as root by
        // configure-install.sh): lands exactly where the agent looks, with
        // modes the trust rule accepts, and prunes the stale entries it owns.
        let staleGuarded = guardedPkg.deletingLastPathComponent().appendingPathComponent(
            "guarded.content-\(String(repeating: "1", count: 64)).mlmodelc", isDirectory: true)
        try? fm.createDirectory(at: staleGuarded, withIntermediateDirectories: true)
        let installed = try? Detector.installCompiledCache(source: guardedPkg, compile: compile)
        check("the install-time compile lands at the protected candidate",
              installed?.url.path == guardedEntry.path && installed?.pruned == 1
                  && !fm.fileExists(atPath: staleGuarded.path),
              "url=\(installed?.url.path ?? "nil") pruned=\(installed?.pruned ?? -1)")
        check("the install-time entry passes the agent's own trust rule",
              Detector.untrustedReason(guardedEntry, owner: me) == nil,
              Detector.untrustedReason(guardedEntry, owner: me) ?? "")
        let installedLoad = try? Detector.resolveModel(
            source: guardedPkg, identity: guardedIdentity,
            trust: Detector.CacheTrust(owner: me, protected: true),
            compile: compile, load: load, warn: warn)
        check("the agent loads the install-time entry with no compile",
              installedLoad?.compile == "cache")

        // MARK: - Startup log roll

        /// One FrameLogger launch against `path`, with the previous run's file
        /// aged to `lifetime` seconds of life; returns what it wrote to stderr.
        func launch(_ path: String, previous: String?, lifetime: Double) -> String? {
            let errPath = path + ".stderr"
            if let previous {
                try? Data(previous.utf8).write(to: URL(fileURLWithPath: path))
                let now = Date()
                let attrs: [FileAttributeKey: Any] = [
                    .creationDate: now.addingTimeInterval(-lifetime - 1),
                    .modificationDate: now.addingTimeInterval(-1),
                ]
                try? fm.setAttributes(attrs, ofItemAtPath: path)
                // The whole case rests on the fixture: if this filesystem did
                // not take the dates, fail instead of passing for free.
                guard let back = try? fm.attributesOfItem(atPath: path),
                    let measured = FrameLogger.previousRunLifetime(back),
                    abs(measured - lifetime) < 1
                else { return nil }
            }
            fm.createFile(atPath: errPath, contents: nil)
            guard let errHandle = FileHandle(forWritingAtPath: errPath) else { return nil }
            _ = FrameLogger(path: path, quiet: true, errorHandle: errHandle)
            try? errHandle.close()
            return (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        }

        let shortDir = root.appendingPathComponent("roll-short", isDirectory: true)
        try? fm.createDirectory(at: shortDir, withIntermediateDirectories: true)
        let shortPath = shortDir.appendingPathComponent("run.jsonl").path
        // Generation 1 already holds the run that explains the crash.
        try? Data("the failing run\n".utf8).write(to: URL(fileURLWithPath: shortPath + ".1"))
        let shortErr = launch(shortPath, previous: "{\"event\":\"startup\"}\n", lifetime: 2)
        check("short-lived previous run does NOT roll",
              shortErr != nil && !fm.fileExists(atPath: shortPath + ".2"),
              shortErr == nil ? "(fixture could not set file dates)" : "run.jsonl.2 exists")
        check("the evidence in generation 1 survives the loop",
              (try? String(contentsOfFile: shortPath + ".1", encoding: .utf8))
                  == "the failing run\n")
        check("the skipped roll says so by budget name",
              (shortErr ?? "").contains("minRolledRunLifetimeSecs=10")
                  && (shortErr ?? "").contains("NOT rolling"),
              shortErr ?? "(nil)")

        let longDir = root.appendingPathComponent("roll-long", isDirectory: true)
        try? fm.createDirectory(at: longDir, withIntermediateDirectories: true)
        let longPath = longDir.appendingPathComponent("run.jsonl").path
        let longErr = launch(longPath, previous: "a healthy run\n", lifetime: 600)
        check("a run that lived past the floor still rolls (E1 unchanged)",
              longErr != nil
                  && (try? String(contentsOfFile: longPath + ".1", encoding: .utf8))
                      == "a healthy run\n",
              longErr == nil ? "(fixture could not set file dates)" : "no run.jsonl.1")
        check("a normal roll is silent", (longErr ?? "x").isEmpty, longErr ?? "(nil)")

        check("unknown lifetime rolls (absent creation date)",
              FrameLogger.previousRunLifetime([:]) == nil)
        check("a negative span is unknown, not short",
              FrameLogger.previousRunLifetime([
                  .creationDate: Date(), .modificationDate: Date().addingTimeInterval(-60),
              ]) == nil)

        // MARK: - What the content walk costs (informational, never asserted)

        // The identity walk is new work on the startup path, so a developer
        // with weights in the tree gets the number instead of an assumption —
        // this is where the `digestChunkBytes` / startup receipts get their
        // MEASURED value. Silent when model/weights is absent (not in git).
        // resolvingSymlinksInPath: model/weights is often a symlink into
        // another checkout, and subpathsOfDirectory does not walk through one.
        let weights = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("model/weights", isDirectory: true)
            .resolvingSymlinksInPath()
        let packages = ((try? fm.subpathsOfDirectory(atPath: weights.path)) ?? [])
            .filter { $0.hasSuffix(".mlpackage") }.sorted()
        for relative in packages {
            let pkg = weights.appendingPathComponent(relative)
            var bytes = 0
            for entry in (try? fm.subpathsOfDirectory(atPath: pkg.path)) ?? [] {
                let attrs = try? fm.attributesOfItem(
                    atPath: pkg.appendingPathComponent(entry).path)
                bytes += (attrs?[.size] as? Int) ?? 0
            }
            let start = CFAbsoluteTimeGetCurrent()
            let digest = Detector.contentDigest(for: pkg)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print(String(
                format: "# idMs %.1f ms for %@ (%.1f MB, digest %@)", ms, relative,
                Double(bytes) / 1_048_576, String((digest ?? "unreadable").prefix(8))))
        }

        print("resilience-selftest: \(failed == 0 ? "PASS" : "FAIL") passed=\(passed) failed=\(failed)")
        return failed == 0 ? 0 : 1
    }
}
