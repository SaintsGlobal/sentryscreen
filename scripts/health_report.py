#!/usr/bin/env python3
"""Health report for a live SentryScreen install, from its own logs.

usage: health_report.py [--root /Library/Logs/SentryScreen] [--budget] [--days N]

Reads every <uid>/run.jsonl generation plus both halves of alerts.log (the
administrator processes' root file and each agent's <uid>/alerts.log) /
watchdog.err and
prints, per uid: process runs and the gaps between them, frames / fps /
inference, idle-gate savings, CPU and RSS trend, curtain episodes with
drop latency, exposure tripwire hits, capture lifecycle, pause time, log
sizes. Read-only; never opens an image.

--budget: exit 1 when a receipted budget is exceeded (the "minimal
footprint is actively maintained" check — run it after every soak). Each
budget names its receipt; change the receipt, not the number.
"""
import argparse, collections, datetime as dt, glob, json, os, re, statistics as st, sys

# Budgets (receipts). CPU/RSS: FrameLogger.cpuTripwirePct / memoryTripwireBytes
# — the per-window tripwires the daemon itself fires; here applied to the
# soak's p95 so a 3-day run is judged, not a minute. Exposure: healthy is 0
# by definition (Pipeline.exposureFrames). Stderr: agent.err is not rotated
# by anything, so its growth is the budget (MEASURED 2026-08-25: 1.3 MB/day
# before the sched-heartbeat move; target after: <100 KB/day).
BUDGETS = {
    "cpu_p95_pct": 30.0,
    # = FrameLogger.memoryTripwireBytes (256 MiB) in the decimal MB this
    # report prints; MEASURED 2026-10-01 healthy UI-driven max 188.2 MB on
    # build 23.
    # Change both together.
    "rss_max_mb": 256 * 1024 * 1024 / 1e6,
    "exposure_events": 0,
    # Every daemon tripwire is already beyond its measured healthy range.
    # A soak is healthy only when none fires; fix the named source limit,
    # not this reporting budget.
    "tripwire_events": 0,
    "agent_err_mb_per_day": 0.1,
    "frames_dropped_pct": 5.0,   # ASSUMED: soak measured 4.37% at 28 fps; re-receipt after the idle gate
}
CURTAIN_TRIPWIRE_PREFIXES = (
    "walk-budget:", "watch-budget: limit", "expansion-cap:", "sweep:",
)

def P(s): return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")

def load(uid_dir, since_iso=None):
    files = sorted(glob.glob(os.path.join(uid_dir, "run.jsonl*")),
                   key=lambda f: -int(f.rsplit(".", 1)[1]) if f[-1].isdigit() else 0)
    recs = []
    for f in files:
        with open(f) as fh:
            for line in fh:
                # Cheap pre-filter (review 2026-08-25): ISO ts compares
                # lexically, so records outside --days skip json.loads —
                # the full rotation footprint (4 x 50 MB, Logger.swift
                # logFileCapBytes/logFilesKept) was parsed before the date
                # filter discarded most of it.
                if since_iso:
                    i = line.find('"ts":"')
                    if i >= 0 and line[i + 6:i + 26] < since_iso: continue
                try: recs.append(json.loads(line))
                except ValueError: pass
    recs.sort(key=lambda r: r.get("ts", ""))
    return recs

def pct(vals, q):
    # Nearest-rank (truncating index) on purpose, NOT statistics.quantiles:
    # this p95 gates the cpu budget, and the stdlib's interpolated form
    # reports different values on small soaks — changing the formula means
    # re-receipting the budget (documented in review 2026-08-25).
    if not vals: return 0.0
    v = sorted(vals); return v[min(len(v) - 1, int(q * len(v)))]

def tripwire_counts(recs):
    names = [
        r["info"].split(":", 1)[0]
        for r in recs if r.get("event") == "tripwire" and r.get("info")
    ]
    names += [
        "curtain/" + r["info"].split(":", 1)[0]
        for r in recs
        if r.get("event") == "curtain"
        and r.get("info", "").startswith(CURTAIN_TRIPWIRE_PREFIXES)
    ]
    return collections.Counter(names)

def report_uid(uid, uid_dir, since, budget):
    recs = [r for r in load(uid_dir, since.strftime("%Y-%m-%dT%H:%M:%SZ"))
            if "ts" in r and P(r["ts"]) >= since]
    fails = []
    print(f"\n=== uid {uid}: {len(recs)} records", f"{recs[0]['ts']} .. {recs[-1]['ts']}" if recs else "")
    if not recs: return fails
    starts = [r["ts"] for r in recs if r.get("event") == "policy"]
    print(f"process starts: {len(starts)}")
    for s in starts[1:]:
        prev = max((r["ts"] for r in recs if r["ts"] < s), default=None)
        if prev: print(f"  gap before {s}: {(P(s) - P(prev)).total_seconds():.0f}s without records")
    for r in recs:
        if r.get("event") == "startup": print("  startup:", r["ts"], r["info"])
    summ = [r for r in recs if r.get("event") == "summary"]
    active = [r for r in summ if r.get("frames", 0) > 0]
    states = collections.Counter(r.get("state", "active" if r.get("frames") else "?") for r in summ)
    print(f"summaries={len(summ)} by state={dict(states)}")
    frames = sum(r["frames"] for r in summ)
    skipped = sum((r.get("counters") or {}).get("framesSkippedIdle", 0) for r in summ)
    dropped = sum((r.get("counters") or {}).get("framesDropped", 0) for r in summ)
    print(f"frames detected={frames} idle-skipped={skipped} "
          f"({100 * skipped / max(frames + skipped, 1):.1f}% of delivered) "
          f"busy-gate dropped={dropped} ({100 * dropped / max(frames, 1):.2f}%)")
    # Idle-gate health (main.swift dirty-area receipt; surfaced per review
    # 2026-08-25): framesDirtyFull dominating on a mostly-static soak means
    # the SCK attachment stopped parsing; changePct pinned high on a static
    # desktop means FrameDelta is defeated — either way the gate is silently
    # off, and these are the only fields that show it.
    dirty = {k: sum((r.get("counters") or {}).get(k, 0) for r in summ)
             for k in ("framesDirtyFull", "framesDirtySmall", "framesDirtyMid")}
    if any(dirty.values()):
        print("dirty-area frames:", dirty)
    for k in ("dirtyPctP50", "dirtyPctP90", "changePctP50", "changePctP90"):
        v = [c.get(k) for r in summ for c in [(r.get("counters") or {})] if c.get(k) is not None]
        if v: print(f"  {k}: med={st.median(v):.0f} max={max(v):.0f}")
    hi = [r for r in active if r["fps"] >= 20]
    if active:
        print(f"fps (active windows) p50={st.median([r['fps'] for r in active]):.1f} max={max(r['fps'] for r in active):.1f}; windows>=20fps={len(hi)}")
    if hi:
        print(f"at >=20fps: inferP50 med={st.median([r['inferP50'] for r in hi]):.1f}ms inferP95 med={st.median([r['inferP95'] for r in hi]):.1f}ms max={max(r['inferP95'] for r in hi):.1f}ms")
    cpu = [r["cpuPct"] for r in summ if r.get("cpuPct") is not None]
    if cpu:
        by = collections.defaultdict(list)
        for r in summ:
            if r.get("cpuPct") is not None: by[r.get("state", "active")].append(r["cpuPct"])
        print(f"cpu% n={len(cpu)} p50={st.median(cpu):.1f} p95={pct(cpu, .95):.1f} max={max(cpu):.1f}; "
              + " ".join(f"{k}:p50={st.median(v):.1f}" for k, v in by.items()))
        if pct(cpu, .95) > BUDGETS["cpu_p95_pct"]: fails.append(f"cpu_p95_pct {pct(cpu, .95):.1f} > {BUDGETS['cpu_p95_pct']}")
    rss = [r["rssBytes"] / 1e6 for r in summ if r.get("rssBytes")]
    if rss:
        print(f"rss MB min={min(rss):.0f} med={st.median(rss):.0f} max={max(rss):.0f} first={rss[0]:.0f} last={rss[-1]:.0f}")
        if max(rss) > BUDGETS["rss_max_mb"]: fails.append(f"rss_max_mb {max(rss):.0f} > {BUDGETS['rss_max_mb']:.1f}")
    if frames and 100 * dropped / frames > BUDGETS["frames_dropped_pct"]:
        fails.append(f"frames_dropped_pct {100 * dropped / frames:.2f} > {BUDGETS['frames_dropped_pct']}")
    ev = collections.Counter(r.get("event", "frame") for r in recs)
    print("events:", dict(ev))
    cur = [r for r in recs if r.get("event") == "curtain"]
    kinds = collections.Counter(r["info"].split(" window")[0] for r in cur)
    print("curtain:", dict(kinds))
    lat = [float(r["info"].split("latencyMs=")[1].split()[0]) for r in cur if "latencyMs=" in r["info"]]
    if lat: print(f"  drop latencyMs n={len(lat)} p50={st.median(lat):.0f} max={max(lat):.0f}")
    tripwires = tripwire_counts(recs)
    print("tripwire:", dict(tripwires))
    tripwire_count = sum(tripwires.values())
    if tripwire_count > BUDGETS["tripwire_events"]:
        fails.append(
            "tripwire_events "
            f"configured={BUDGETS['tripwire_events']} observed={tripwire_count} "
            "remediation=inspect each event's named fix location; "
            "budget=scripts/health_report.py:BUDGETS[tripwire_events]")

    # WindowTracker cadence is the curtain geometry receipt. Both heartbeat
    # and final records contain "N/M polls late (P%), worst W ms behind".
    sched = [
        r["info"] for r in recs
        if r.get("event") == "sched" and "polls late" in r.get("info", "")
    ]
    if sched:
        pattern = re.compile(r"polls late \(([\d.]+)%\), worst ([\d.]+) ms")
        samples = [match for line in sched if (match := pattern.search(line))]
        late_pct = [float(match.group(1)) for match in samples]
        worst_ms = max((float(match.group(2)) for match in samples), default=0)
        print(
            "windowTracker sched: "
            f"heartbeats={len(sched)} "
            f"late% p50={st.median(late_pct) if late_pct else 0:.1f} "
            f"max={max(late_pct) if late_pct else 0:.1f} "
            f"worst={worst_ms:.0f} ms behind")

    region_counts = [r.get("regions", 0) for r in recs if "regions" in r]
    if region_counts:
        print(f"regions/frame: max={max(region_counts)} p95={pct(region_counts, 0.95)}")

    # Detections the region pipeline skipped because a curtain had already
    # painted over them (Pipeline.regionInput). Work this daemon drops is
    # never dropped silently: the counter rides the 60 s summary record, so
    # the suppression is auditable against regions/frame above — a rising
    # total with no fall in region births means it is eating detections a
    # curtain is not actually covering.
    suppressed_dets = sum(
        (r.get("counters") or {}).get("detsSuppressedUnderCurtain", 0) for r in summ
    )
    if suppressed_dets:
        print(f"detections suppressed under a painted curtain: {suppressed_dets}")

    # Region candidates the curtain-mode entry debounce refused because the
    # next detector frame did not re-see them (Tracker.curtainEntryFrames = 2).
    # Same contract as the line above: work this daemon drops is counted, never
    # dropped silently. Read it against regions/frame — an upper bound on the
    # one-frame false positives the debounce is there to swallow.
    debounced_entries = sum(
        (r.get("counters") or {}).get("regionEntriesDebounced", 0) for r in summ
    )
    if debounced_entries:
        print(f"region entries debounced (single-frame candidates): {debounced_entries}")

    exp = [r for r in recs if r.get("event") == "exposure"]
    print(f"exposure tripwire: {len(exp)}")
    for r in exp: print("  ", r["ts"], r["info"])
    if len(exp) > BUDGETS["exposure_events"]: fails.append(f"exposure_events {len(exp)} > 0")
    ct = [r for r in recs if r.get("event") == "cpu"]
    if ct: print(f"cpu tripwire records: {len(ct)}, max observed "
                 f"{max(float(r['info'].split('observed ')[1].split('%')[0]) for r in ct):.1f}%")
    cap = collections.Counter(" ".join(r["info"].split()[:2]) for r in recs if r.get("event") == "capture")
    print("capture:", dict(cap))
    paused = 0; pa = None
    for r in recs:
        if r.get("event") == "pause" and pa is None: pa = P(r["ts"])
        elif r.get("event") == "resume" and pa: paused += (P(r["ts"]) - pa).total_seconds(); pa = None
    print(f"pauses={ev.get('pause', 0)} paused≈{paused / 3600:.1f}h")
    labs = collections.Counter(d["label"] for r in recs if "detections" in r for d in r["detections"])
    if labs: print("detections (flagged frames):", dict(labs.most_common(6)))
    # log sizes / stderr growth
    span_days = max((P(recs[-1]["ts"]) - P(recs[0]["ts"])).total_seconds() / 86400, 1 / 24)
    for name in ("agent.err", "agent.out"):
        p = os.path.join(uid_dir, name)
        if os.path.exists(p):
            size = os.path.getsize(p)
            # Append-only for the install's life (agent-launch.sh `>>`; only
            # install.sh ever removes it), so the rate divisor is the FILE's
            # age — dividing cumulative size by the --days-capped record span
            # overstated the rate ~(install_age/days)x on installs older than
            # the window, a false agent_err_mb_per_day FAIL (review
            # 2026-08-25). st_birthtime is macOS; the span stays as the
            # (overstating) fallback elsewhere.
            try:
                age = max((dt.datetime.now().timestamp()
                           - os.stat(p).st_birthtime) / 86400, 1 / 24)
            except AttributeError:
                age = span_days
            rate = size / 1e6 / age
            print(f"{name}: {size / 1e6:.2f} MB (~{rate:.2f} MB/day over {age:.1f}d)")
            if name == "agent.err" and rate > BUDGETS["agent_err_mb_per_day"]:
                fails.append(f"agent_err_mb_per_day {rate:.2f} > {BUDGETS['agent_err_mb_per_day']}")
    total = sum(os.path.getsize(f) for f in glob.glob(os.path.join(uid_dir, "*")))
    print(f"log dir total: {total / 1e6:.1f} MB")
    return fails

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="/Library/Logs/SentryScreen")
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--budget", action="store_true")
    a = ap.parse_args()
    since = dt.datetime.utcnow() - dt.timedelta(days=a.days)
    fails = []
    for d in sorted(glob.glob(os.path.join(a.root, "[0-9]*"))):
        if os.path.isdir(d):
            try: fails += [f"uid {os.path.basename(d)}: {x}" for x in report_uid(os.path.basename(d), d, since, a.budget)]
            except PermissionError as e: print(f"\n=== uid {os.path.basename(d)}: unreadable ({e}) — run from an admin session")
    print("\n=== watchdog / alerts ===")
    # Two writers, two files, one format. The administrator processes (the
    # watchdog, the updater) own the root file; each agent owns the
    # alerts.log in ITS OWN per-uid log dir — the support dir is root 0755,
    # so an agent could never write there and its alerts (capture lost /
    # restored, a failed panic hotkey) used to reach nobody. Same parser.
    # Newer installs move launchd stderr outside the log root so recovery can start
    # when that root is absent. Keep the old location for earlier installs.
    for p in ([os.path.join(a.root, "watchdog.err"),
               "/Library/Application Support/SentryScreen/watchdog.err",
               "/Library/Application Support/SentryScreen/alerts.log"]
              + sorted(glob.glob(os.path.join(a.root, "[0-9]*", "alerts.log")))):
        if os.path.exists(p):
            lines = [l for l in open(p, errors="replace") if l[:4].isdigit() and P(l[:20]) >= since]
            print(f"{p}: {len(lines)} lines since cutoff; "
                  f"{collections.Counter(l.split()[1] for l in lines if len(l.split()) > 1)}")
            for l in lines[-5:]: print("  ", l.rstrip()[:140])
    print("\nNOT CHECKED: other users' DiagnosticReports (unreadable cross-account); "
          "ground truth for missed detections (only the exposure tripwire, which needs a detection to fire).")
    if a.budget:
        if fails:
            print("\nBUDGET FAIL:"); [print("  ", f) for f in fails]; sys.exit(1)
        print("\nBUDGET OK")

if __name__ == "__main__":
    main()
