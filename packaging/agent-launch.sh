#!/bin/bash
# Per-user launch wrapper for the production LaunchAgent (B5/B6).
#
# Why a wrapper: /Library/LaunchAgents plists run in EVERY user's session,
# but launchd does not expand $HOME/$UID in StandardOutPath, and a shared
# log file is single-owner. MEASURED 2026-08-22 on the first second-account
# login (uid 502): agent.out/agent.err/run.jsonl were owned by uid 501, so
# uid 502's launchd could not open stdout/stderr and the agent crash-looped
# (watchdog kickstart every 60 s, "agent loaded but not running") — the
# second account was unprotected. Per-uid log dirs fix it structurally.
#
# Layout: /Library/Logs/SentryScreen/<uid>/{run.jsonl,agent.out,agent.err}
# Parent dir is root-owned 1777 (configure-install.sh) so each user can create
# its own subdir and nobody can delete another user's. 1777 also lets any
# account create a name it does NOT own, so this wrapper verifies the shape of
# its own per-uid directory before it writes anything (tripwire LOG_DIR_OWNER
# below), and configure-install.sh pre-creates every root-owned path under that
# root (the launchd .err files) so root never creates one
# lazily where a child could have pre-placed a symlink. The daemon's --log
# flag overrides the config "log" key (flags win, D1).
#
# TTL retired for installed builds (B4, 2026-09-01): the launch line below
# passes `--ttl 0` AFTER `--config`, and flags override config (D1), so the
# daemon runs until launchd stops it — including on machines whose preserved
# config.json still says "ttl": 86400 from the staged rollout (no config
# migration needed; the wrapper is replaced on every install). Why it was
# there: SPEC §8.1(3) makes --ttl the dev dead-man switch, and the staged
# rollout (SPEC §8.3) kept a 24 h cycle in production until the watchdog,
# panic hotkey and uninstall were verified. Those Receipts exist (watchdog
# kill/bootout repair 2026-08-22; uninstall live 2026-08-29 fi-keep-02 and
# the fresh-install runs since; panic hotkey every live run), and the daily
# restart was itself a defect: MEASURED 2026-08-25 (run.jsonl, uid 501) 61 s,
# 14 s and 60 s with no process at each 20:22 restart before the in-wrapper
# relaunch, ~3 s after it. A restart also resets the process RSS, which hid
# any day-scale growth from the health budget — the 24 h ACTIVE soak
# (distribution-plan G4) is the Receipt that replaces the restart. Dev runs
# keep --ttl; TTL_EXIT (75, EX_TEMPFAIL) stays in
# the relaunch set below so a dev `--ttl 30` harness behaves as before.
# Every other exit — 0 (SIGTERM from launchctl bootout / shutdown), 2/3/5
# (capture), 64 (config) — is passed through unchanged.
#
# KeepAlive=true (B4, same date; plist receipt): launchd now relaunches this
# WRAPPER when it exits for any reason — a child account can `kill` the
# wrapper (it runs as their uid) and before B4 that cost a watchdog interval
# (≤60 s, MEASURED 56 s 2026-08-22) of no protection; launchd's relaunch is
# bounded by its 10 s ThrottleInterval (ASSUMED from launchd's documented
# default; the agent plist sets no ThrottleInterval). Since 2026-09-11 that
# 10 s is the ONLY thing pacing a burst trip (below): a trip exits 1 and
# launchd starts a fresh wrapper ~10 s later, so the worst unprotected window a
# crash loop can produce is seconds, not the 900 s the marker used to hold.
#
# Relaunch set (owner 2026-08-26, merged 2026-08-28): TTL_EXIT (75), 7, and
# 137. Exit 7 has TWO in-process owners and this wrapper must relaunch for
# both — (a) the capture-loss poll's "preflight reads TRUE but capture has
# been stuck for captureLossRelaunchSecs = 30 s" exit (main.swift; NOT a
# fallback for a stale preflight — that case never reaches this exit, see the
# caveat at captureLossPollSecs), and (b) the parent-onboarding
# `restartForVerification` fresh-process handoff, which exits on purpose so a
# new process re-evaluates TCC. 137 = the daemon's answer to a Quit
# AppleEvent outside an armed handoff (System Settings' "Quit & Reopen",
# osascript quit, logout) — CORRECTED 2026-08-29: Quit & Reopen is an
# AppleEvent, not SIGKILL; before applicationShouldTerminate answered 137 the
# daemon exited 0 and this wrapper stopped. All three used to fall out to launchd (KeepAlive=false) and wait
# for the watchdog's ~60 s kickstart — MEASURED live 2026-08-26 as the
# menu-bar icon and toast vanishing for ~1 min after Quit & Reopen and again
# every ~2 min while degraded. The same burst tripwire covers all three.
#
# Tripwire RELAUNCH_BURST: too many non-zero child exits inside BURST_WINDOW
# (AMENDED 2026-09-11, receipt at RELAUNCH_BURST: every non-zero exit counts,
# and the window persists across wrapper launches) means
# the TTL is seconds, onboarding is looping, or the daemon is exiting on
# startup — exit 1 with a line naming the budget rather than spin in THIS
# process, and drop a marker file so watchdog.sh can tell a parent. The
# 2026-08-25 review asked for the marker to also SUPPRESS the next launch,
# because a fresh wrapper's counter starts at zero; that suppression is what
# a later fix removed (next paragraph) — pacing is launchd's job, not the job of a
# file the protected account can write.
#
# The marker is EVIDENCE, NEVER A GATE (2026-09-11,
# CONFIRMED). Until this date the wrapper refused to launch at all while
# `<uid log dir>/RELAUNCH_BURST.tripped` was younger than a 900 s cooldown —
# and that directory belongs to the PROTECTED ACCOUNT (the root is 1777 and the
# per-uid subdir is owned by the session). `while :; do touch
# <dir>/RELAUNCH_BURST.tripped; sleep 600; done` from the child's own Terminal
# therefore held protection off indefinitely, with one alerts.log line per trip
# to show it; a `kill -9` loop reached the same state without even needing the
# file (137 is in the relaunch set, so 11 kills inside BURST_WINDOW tripped the
# budget). The previous version of this header admitted "The account itself
# still can". A launch must never be gated on a file the protected account
# owns, so now:
#   * the budget still EXISTS and still fails loudly — the same agent.err line
#     naming budget, limit, observed count and fix location — and still exits 1
#     so launchd records an abnormal stop and paces the next wrapper with its
#     10 s ThrottleInterval. That pacing is what replaces the cooldown;
#   * the counter is per-wrapper-process and in memory, so a fresh wrapper
#     starts at zero. A daemon that exits as fast as it starts therefore
#     oscillates (~RELAUNCH_BURST relaunches, exit 1, ~10 s, repeat) instead of
#     stopping — deliberate: SPEC §8 prefers "cannot see" to "cannot act", and
#     the ALERT trail, not a silent stop, is what gets a parent to look;
#   * the marker file is still WRITTEN on every trip, because watchdog.sh's
#     per-trip ALERT (keyed on its mtime) is the only parent-visible surface
#     this wrapper has — nothing tails agent.err. The NEXT wrapper start moves
#     it to .tripped.last and says so, which is what produces the watchdog's
#     INFO "cleared" line. Neither step can block a launch.
# If a cooldown is ever genuinely wanted it belongs in root-owned watchdog
# state with the watchdog deciding, never in a file the child can touch.

set -u
# the LaunchAgent does not override PATH. Resolve all wrapper utilities
# from system directories before reading identity or creating files. The
# hostile-PATH regression exercises this full wrapper with dummy utilities.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# Explicit, not inherited: the parent UI's activity feed
# reads OTHER users' /Library/Logs/SentryScreen/<uid>/run.jsonl from
# the admin session. That worked under launchd's default umask by accident
# (MEASURED 2026-08-22: 0755 dirs, 0644 files); make it a contract.
umask 022
SUPPORT="/Library/Application Support/SentryScreen"
BIN="$SUPPORT/SentryScreen.app/Contents/MacOS/sentry-screen"
LOG_UID="$(id -u)"
d="/Library/Logs/SentryScreen/$LOG_UID"
# Where the logs go when $d cannot be made usable: this account's own
# per-user temporary directory (0700, the value launchd passes as TMPDIR).
LOG_FALLBACK_ROOT="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
# LOG_DIR_OWNER (2026-09-07; T2 revision 2026-09-28). The parent directory is
# 1777, so ANY account can create ANY name in it — including another account's
# uid before that account first logs in — and this account owns its own $d, so
# it can chmod, replace or remove it at will. Logs written into a directory a
# sibling controls could be read and rewritten, so the shape is still checked.
# Until 2026-09-28 a wrong shape was a refusal (exit 78, or 73 when mkdir
# failed): the security review showed that made the directory, which the
# protected account controls, a way to keep protection off. A log location is
# never a reason to leave protection off, so now:
#   1. the account's own directory with a wrong mode is set back to 0755, and
#      its own non-directory (a file or symlink at the name) is replaced;
#   2. anything this account cannot fix (another owner) sends the logs to
#      $LOG_FALLBACK_ROOT/SentryScreen-logs, and failing that to a fresh
#      mktemp directory, and failing THAT to /dev/null — the daemon still runs;
#   3. the root watchdog restores the canonical $d within one 60 s pass
#      (watchdog.sh repair_log_dir) and restarts the agent into it.
# Each repair or fallback is named in agent.err (in whichever directory is in
# use). The
# accepted shapes are still exactly the two this wrapper produces: 0755 under
# its own `umask 022` (the contract the parent UI's activity feed reads across
# accounts) and 0700 for a session whose owner tightened it.
log_dir_shape() { stat -f 'type=%HT,owner=%u,mode=%Lp' "$1" 2>/dev/null || echo 'type=unreadable,owner=?,mode=?'; }
log_dir_ok() {
  case "$(log_dir_shape "$1")" in
    "type=Directory,owner=$LOG_UID,mode=755" | "type=Directory,owner=$LOG_UID,mode=700") return 0 ;;
  esac
  return 1
}
log_dir_note=""
mkdir -p "$d" 2>/dev/null
if ! log_dir_ok "$d"; then
  observed_log_dir="$(log_dir_shape "$d")"
  case "$observed_log_dir" in
    "type=Directory,owner=$LOG_UID,"*) chmod 755 "$d" 2>/dev/null ;;
    *",owner=$LOG_UID,"*) rm -f "$d" 2>/dev/null && mkdir "$d" 2>/dev/null ;;
  esac
  if log_dir_ok "$d"; then
    log_dir_note="sentry-screen: LOG_DIR_OWNER configured type=Directory,owner=$LOG_UID,mode=755-or-700, observed $observed_log_dir at $d — repaired by this wrapper and launching"
  else
    canonical_log_dir="$d"
    d=""
    if [ -n "$LOG_FALLBACK_ROOT" ]; then
      fallback="${LOG_FALLBACK_ROOT%/}/SentryScreen-logs"
      mkdir -p "$fallback" 2>/dev/null && chmod 700 "$fallback" 2>/dev/null && log_dir_ok "$fallback" && d="$fallback"
    fi
    if [ -z "$d" ]; then
      fallback="$(mktemp -d "/tmp/sentry-screen-$LOG_UID.XXXXXX" 2>/dev/null || true)"
      [ -n "$fallback" ] && log_dir_ok "$fallback" && d="$fallback"
    fi
    log_dir_note="sentry-screen: LOG_DIR_OWNER configured type=Directory,owner=$LOG_UID,mode=755-or-700, observed $observed_log_dir at $canonical_log_dir — not repairable by this account; logging to ${d:-/dev/null} and launching anyway (protection is never withheld over a log location; the root watchdog restores $canonical_log_dir within one pass)"
    # Last resort: every log_append to "$d/…" below targets /dev/null/… and
    # fails, which skips that one line only; the launch uses launch_log().
    [ -n "$d" ] || d="/dev/null"
  fi
fi
# LOG_FILE_SAFE_OPEN (review 2026-10-16). This account owns $d, so any file
# name in it can be swapped for a FIFO at any moment, and a shell `>>` on a
# FIFO with no reader blocks forever: one `mkfifo agent.out` kept the daemon
# from ever starting. Every write into $d therefore goes through log_write,
# which opens with O_NONBLOCK|O_NOFOLLOW (a readerless FIFO fails with ENXIO,
# a symlink with ELOOP) and checks the OPEN descriptor is a regular file, so
# no swap between a check and the open can reach it. A refused write returns
# non-zero; it never blocks. `env -i` keeps PERL5OPT/PERL5LIB out (see
# burst_state_read). The watchdog moves a non-regular agent.out, agent.err or
# run.jsonl aside within one pass (watchdog.sh repair_log_files).
log_write() {  # append|replace path; the bytes come on stdin
  # shellcheck disable=SC2016  # perl source: its $ are perl's
  /usr/bin/env -i /usr/bin/perl -e '
use Fcntl;
my ($how, $path) = @ARGV;
my $flags = O_WRONLY | O_CREAT | O_NONBLOCK | O_NOFOLLOW
          | ($how eq "replace" ? O_TRUNC : O_APPEND);
sysopen(my $f, $path, $flags, 0644) or exit 1;
-f $f or exit 2;
local $/; my $bytes = <STDIN>;
exit 0 unless defined $bytes && length $bytes;
defined syswrite($f, $bytes) or exit 3;' "$1" "$2"
}
log_append() { log_write append "$1"; }
log_replace() { log_write replace "$1"; }
# The file the daemon's stdout/stderr go to at each launch: bash skips a
# command whose redirect cannot open, and blocks on a FIFO, so an unusable log
# file would become a daemon that never starts. Checked per launch because the
# account can change its own directory while the wrapper runs. Prints the path
# when it is absent or a regular non-symlink file, otherwise /dev/null.
launch_log() {  # path
  if log_append "$1" </dev/null; then printf '%s\n' "$1"; return; fi
  local note="sentry-screen: LOG_DIR_OWNER log file $1 cannot be opened, is a link or is not a regular file — this launch's output goes to /dev/null and the daemon launches anyway (the watchdog moves it aside; fix: remove $1)"
  echo "$note" | log_append "$d/agent.err" 2>/dev/null || echo "$note" >&2
  printf '/dev/null\n'
}
# The daemon's own launch reopens both files the same non-blocking way and
# then execs it (same pid, same argv), so a swap after launch_log's check falls
# back to /dev/null instead of blocking the shell's `>>`. O_NONBLOCK is cleared
# before the exec; the daemon sees an ordinary O_APPEND descriptor.
# The perl runs under `env -i "${SCRUB_ENV[@]}"` (tripwire ENV_SCRUB below),
# which is both what keeps PERL5OPT out and the environment the daemon gets.
launch_with_logs() {  # out err command...
  # shellcheck disable=SC2016  # perl source: its $ are perl's
  /usr/bin/env -i "${SCRUB_ENV[@]}" /usr/bin/perl -e '
use Fcntl;
sub safe { my $f;
  if (sysopen($f, $_[0], O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK | O_NOFOLLOW, 0644) && -f $f) {
    fcntl($f, F_SETFL, O_APPEND) or return undef; return $f }
  return undef }
my ($out, $err) = splice(@ARGV, 0, 2);
for ([\*STDOUT, $out], [\*STDERR, $err]) {
  my ($std, $path) = @$_;
  my $f = safe($path);
  if ($f) { open($std, ">&", $f) or exit 70 }
  else { open($std, ">>", "/dev/null") or exit 70 }
}
exec { $ARGV[0] } @ARGV;
exit 71;' "$@"
}
if [ -n "$log_dir_note" ]; then
  echo "$log_dir_note" | log_append "$d/agent.err" 2>/dev/null || echo "$log_dir_note" >&2
fi

# --- Tripwire ENV_SCRUB (2026-09-11) ----------------
# A /Library/LaunchAgents job inherits its gui domain's environment, and
# `launchctl setenv` in one's OWN gui domain needs no administrator. MEASURED
# 2026-09-11 on an M1 Mac (uid 501, throwaway job com.sentryscreen.envprobe, a
# harmless variable, the real agent untouched): a variable set with `launchctl
# setenv` reached the job on `bootstrap`, and a value set while the job was
# already loaded reached it on `kickstart -k`. So a Standard (child) account
# could do `launchctl setenv SENTRY_STATE_DIR ~/s; launchctl kickstart -k
# gui/$UID/com.sentryscreen.agent` and the relaunched daemon would read its
# settings (a pause) — or, with an EMPTY directory, find no license entitlement
# and withhold protection — while the watchdog saw a running job writing logs.
# `SENTRY_FAKE_NO_DISPLAY`, `SENTRY_IDLE_GATE=0`, `SENTRY_ALERTS_LOG`,
# `SENTRY_LOG_DIR` and the rest of the knob list are the same class. The daemon
# itself always honours those variables (daemon DevEnv.swift), so this wrapper
# is the one boundary: the daemon is launched
# through `env -i`, so NOTHING ambient reaches it — not our knobs, not
# DYLD_*/CF*/Malloc* debug variables, not a poisoned PATH.
#
# The minimum set, and why each one is here. Every value comes from an
# authoritative source (the passwd database, confstr, a literal), NEVER from
# this wrapper's own inherited environment, which the same `launchctl setenv`
# can poison:
#   PATH    launchd's own default for an agent, MEASURED 2026-09-11 in the probe
#           above as exactly /usr/bin:/bin:/usr/sbin:/sbin. The daemon's
#           subprocesses use absolute paths (/bin/launchctl,
#           /usr/sbin/screencapture), but the uninstall path hands a command
#           line to osascript → /bin/sh, which needs a sane PATH. A literal, so
#           PATH hijacking is not reachable either.
#   HOME    NSHomeDirectory()/FileManager.homeDirectoryForCurrentUser honour
#           HOME, and the dev-fallback state root and the dev alerts.log path
#           are built from it. Read from `id -P` (passwd field 9).
#   USER,   NSUserName() and the activity feed's "updatedBy" label. `id -un`.
#   LOGNAME
#   TMPDIR  per-uid confstr (`getconf DARWIN_USER_TEMP_DIR`), the value launchd
#           itself passes. Dropping it would send NSTemporaryDirectory() — and
#           every CoreML/Foundation temp file — to world-writable /tmp, which is
#           a downgrade, not a scrub.
# Deliberately NOT forwarded: XPC_FLAGS / XPC_SERVICE_NAME (launchd sets them
# for the JOB, and the probe measured XPC_SERVICE_NAME=0, i.e. "not an XPC
# service", so they carry nothing this daemon reads), SSH_AUTH_SOCK, SHELL,
# LANG, and everything else.
# A scrub that succeeds is SILENT about what it removed, and the daemon cannot
# name what it never saw, so the wrapper reports the drop itself — names only,
# plus a marker the root watchdog turns into an ALERT. See "ENV_SCRUB evidence"
# below; that is the only place a refused environment attack becomes visible.
# VERIFIED 2026-09-11: the built agent's `--ui-selftest` reports the same
# 1061/1062 under this exact variable set as under a full inherited environment
# (the one failure is the pre-existing WindowServer-geometry `spotlight: bounds
# size matches` check, observed in both runs). OWED: one live installed run
# confirming the menu-bar item and capture start under the scrub — AppKit takes
# its window-server connection from the inherited Mach bootstrap port, not from
# the environment, but that is ASSUMED until a live run says so.
SCRUB_PATH="$PATH"
SCRUB_USER="$(id -un 2>/dev/null || true)"
SCRUB_HOME="$(id -P "${SCRUB_USER:-}" 2>/dev/null | awk -F: 'NR==1{print $9}')"
SCRUB_TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
# Fail loudly, but never refuse to launch over a missing convenience variable:
# an unprotected session is the worse failure (SPEC §8), and none of these is a
# safety boundary: each comes from the passwd database or getconf, never the
# ambient environment.
SCRUB_ENV=(PATH="$SCRUB_PATH")
if [ -n "$SCRUB_HOME" ]; then
  SCRUB_ENV+=(HOME="$SCRUB_HOME")
else
  echo "sentry-screen: tripwire ENV_SCRUB, configured HOME from the passwd database," \
       "observed none (id -P returned no home for user '${SCRUB_USER:-?}') —" \
       "launching with no HOME; Foundation falls back to getpwuid" \
       "(fix: agent-launch.sh SCRUB_HOME)" | log_append "$d/agent.err"
fi
if [ -n "$SCRUB_USER" ]; then
  SCRUB_ENV+=(USER="$SCRUB_USER" LOGNAME="$SCRUB_USER")
fi
if [ -n "$SCRUB_TMPDIR" ]; then
  SCRUB_ENV+=(TMPDIR="$SCRUB_TMPDIR")
else
  echo "sentry-screen: tripwire ENV_SCRUB, configured TMPDIR from getconf" \
       "DARWIN_USER_TEMP_DIR, observed none — launching with no TMPDIR, so" \
       "temporary files land in /tmp (fix: agent-launch.sh SCRUB_TMPDIR)" | log_append "$d/agent.err"
fi
# --- ENV_SCRUB evidence: a refused attempt must be LOUD ---------------------
# Review repair 2026-09-11 (critic blocker 2). `env -i` deletes the evidence
# before the daemon can name it: under `env -i` the daemon's own
# `DevEnv.ambientKnobs` is necessarily EMPTY on an installed machine, so its
# launch `"event":"env"` record reads `devEnv=inert envKnobs=0` whether or not a
# child ran `launchctl setenv SENTRY_STATE_DIR …; launchctl kickstart -k`. This
# repo's rule is that tamper is loud (watchdog.sh header: "a watchdog that fixes
# things silently hides exactly the tampering a parent needs to know about"), so
# the wrapper — the last process that still SEES the ambient environment —
# records what it dropped, and leaves a marker the root watchdog turns into an
# ALERT (nothing tails agent.err).
#
# NAMES ONLY, never values: a value is an attacker-chosen string that can carry
# a path, a token or a PIN, and agent.err is readable by the account that set
# it. `cut -d= -f1` on a line matching the prefix is the whole extraction.
# Honest limit: some OTHER variable's value may contain a newline followed by a
# plausible `SENTRY_X=` line, so a name in this list is this wrapper's reading
# of its environment and not proof of which variable was set — the COUNT and
# the fact of a drop are the signal, and the drop itself is what keeps the
# variable out of the daemon. DYLD_* is in the pattern because it is the other family that changes a
# process before main() (insert-libraries, library paths) — defence in depth
# only: MEASURED 2026-09-11 on an M1 Mac (macOS 26), dyld strips every DYLD_*
# across an exec of a SIP-protected platform binary, and the plist runs
# /bin/bash, so a DYLD_* set in the gui domain never reaches this wrapper at
# all. It is kept in the pattern so a future non-platform launcher is covered
# without anyone having to remember this paragraph.
ENV_SCRUB_MARKER="$d/ENV_SCRUB.dropped"
# Absolute paths throughout: this runs BEFORE the scrub, so $PATH here is the
# inherited one and `launchctl setenv PATH …` can poison it.
scrub_dropped="$(/usr/bin/env \
  | /usr/bin/grep -E '^(SENTRY_|DYLD_)[A-Za-z0-9_]*=' \
  | /usr/bin/cut -d= -f1 | /usr/bin/sort -u | /usr/bin/tr '\n' ' ')"
# shellcheck disable=SC2086  # word splitting IS the count here
scrub_dropped_count="$(set -- $scrub_dropped; echo $#)"
if [ -n "$scrub_dropped" ]; then
  echo "sentry-screen: tripwire ENV_SCRUB, configured 'no ambient SENTRY_*/DYLD_*" \
       "variable in this wrapper's environment', observed $scrub_dropped_count" \
       "dropped before exec: $scrub_dropped — the daemon is launched through" \
       "\`env -i\` so none of them reached it, and a production daemon honours no" \
       "SENTRY_* knob anyway (DevEnv.swift); names only, never values." \
       "(fix: whoever set them — \`launchctl unsetenv <name>\` in that domain;" \
       "tripwire: agent-launch.sh ENV_SCRUB)" | log_append "$d/agent.err"
  # Marker for watchdog.sh (report_wrapper_marker env-scrub): content is never
  # read there — it is in the protected account's own directory, so only its
  # existence, mtime and owner may be trusted. Rewritten on every launch that
  # drops something, so a repeat attempt moves the mtime and alerts again.
  date -u +%Y-%m-%dT%H:%M:%SZ | log_replace "$ENV_SCRUB_MARKER" 2>/dev/null \
    || echo "sentry-screen: ENV_SCRUB marker $ENV_SCRUB_MARKER could not be written —" \
            "the drop above is in this file only, not in alerts.log" | log_append "$d/agent.err"
else
  # Nothing ambient: clear a stale marker so the watchdog's next pass does not
  # keep a closed attempt alive. Removing it is not a "cleared" event worth an
  # ALERT — the attempt never reached the daemon in the first place.
  rm -f "$ENV_SCRUB_MARKER" 2>/dev/null || true
fi

TTL_EXIT=75
TCC_RELAUNCH_EXIT=7
# 128 + SIGKILL(9). MEASURED live 2026-08-26: System Settings' "Quit &
# Reopen" prompt, shown after the Screen Recording switch is toggled, SIGKILLs
# the daemon, so the exact moment a parent finishes the fix is the moment
# protection would otherwise stay down until the watchdog's next ~60 s pass.
QUIT_REOPEN_EXIT=137
# RE-DERIVED 2026-08-28 for the widened relaunch set {75,7,137}. The old
# receipt derived 3/120 s from the TTL cadence alone ("≥30x faster than any
# healthy cycle"), which no longer parses once a 40-second code is in the set.
# The window is TUMBLING, not sliding: the first exit past the boundary does
# `burst_start=$now; burst_count=0`, so a code of cadence C contributes at
# most floor(BURST_WINDOW/C)+1 exits to any one window.
# AMENDED 2026-08-28 (review repair 2): the enumeration below omitted the
# SECOND exit-7 owner this file's own header names — the onboarding
# fresh-process handoff — and the poll's "≤3" used the slow end of its own
# 38-43 s range (floor(120/38)+1 = 4). Both are corrected here. The union is a
# PACKING bound, not a sum of per-owner maxima: this wrapper runs exactly ONE
# child at a time, so N counted exits in a window need N process LIFETIMES to
# fit inside it.
#   * exit 7, onboarding fresh-process handoff
#     (UIOnboardingRuntime.beginFreshProcessHandoff): the shortest healthy
#     lifetime in the set — ~3.4 s start plus the settings projection that
#     decides to hand off, call it ≈4 s. NOT automatically repeatable: the
#     handoff sets `verificationPending`, so the NEXT process takes
#     `checkRequiredServices` instead, and `restartIssued` blocks a second
#     handoff in the same process. The one place that clears it
#     (UIOnboardingRuntime.swift, retryFailedHealthCheck `case .capture,
#     .model`) runs only when a parent taps Retry on a visible failure
#     surface. DERIVED ≤1 automatic + ASSUMED ≤1 human retry = ≤2 per window,
#     ≈8 s of it.
#   * exit 7, capture-loss poll: one cycle = ≤3.4 s process start (MEASURED
#     2026-08-25, "startup" record) + captureLossPollSecs 5 s to the first
#     poll + captureLossRelaunchSecs 30 s (7 polls ⇒ 35 s) = 38-43 s. Standing
#     alone it is floor(120/38)+1 = ≤4; it is mutually exclusive with the
#     handoff WITHIN a process (captureLossPollIsSuperseded mutes this poll
#     while verification == .waitingForReturn), so in the union it can only
#     fill the ≈112 s the two handoff lifetimes leave: ≤3 per window.
#   * TTL exit 75: never on an installed build since B4 (`--ttl 0` below);
#     kept in the union at its old ≤1 per window so the budget is unchanged.
#   * exit 137 ("Quit & Reopen" SIGKILL): human-paced; ASSUMED ≤2 per window
#     for a parent toggling the switch off and on while confused.
# Worst healthy union in one window = 2 + 3 + 1 + 2 = 8, so the old budget 8
# had margin ZERO — the exact defect the 2026-08-28 re-derivation was written
# to remove. Budget 10 restores the margin of 2 that derivation chose. A
# pathological loop (daemon exits as soon as it starts, cycle ≈3.4 s, ~35
# exits per window) still trips on its 11th exit at ~37 s — its 1-per-3.4 s
# rate is 4.4x the fastest healthy union rate (8 per 120 s = 1 per 15 s). Two
# back-to-back manual `--ttl 30` tests still pass, as before.
# AMENDED 2026-09-11. Two changes, budget UNCHANGED:
#   (1) EVERY non-zero child exit is counted, not a hand-picked set. The old
#       `case` counted only {75,7,137} and let every other non-zero code — 4
#       (model load failed), 2/3/5 (capture), 64 (config), 139 (SIGSEGV) —
#       past the budget untouched, so a daemon that dies on every launch was
#       relaunched by launchd's KeepAlive (~10 s ThrottleInterval) forever with
#       nothing ever counted and no budget line anywhere. The healthy union
#       derived above is unaffected — no healthy cycle exits non-zero OUTSIDE
#       the relaunch set, TTL/7/137 are already in it and exit 0 is not
#       counted — so 10 per 120 s keeps the margin of 2 that derivation chose.
#       PRECONDITION, stated because the arithmetic is not obvious (review
#       2026-09-11): the window is TUMBLING, so N exits must fit inside one
#       BURST_WINDOW for the budget to be reached, and with one child at a time
#       that needs a relaunch period P with RELAUNCH_BURST*P <= BURST_WINDOW,
#       i.e. P <= 12 s. This tripwire therefore bounds exactly the loops whose
#       child never reaches a working state (launchd's own 10 s floor, plus a
#       ≈3.4 s startup, is the fast end of that range) and deliberately NOT a
#       loop whose child lives LONGER than 12 s: that daemon is protecting for
#       most of every cycle, so trading it for a long cooldown of no agent at
#       all would be the worse failure. (Moot as well as correct now: 2026-09-11
#       deleted the cooldown outright — one in this directory was an off switch
#       a child could hold. Kept because it is the reason the budget was NOT
#       widened to catch slow loops.) A slow loop is instead made VISIBLE rather
#       than silent — one named line per counted exit below, and the watchdog's own lines
#       for the job it keeps restarting.
#       What this is NOT: the model-load failure is not an exit on a
#       shipped install. `packaging/config.sample.json` sets
#       `captureLoss: banner`, so main.swift routes a failed Pipeline init to
#       UIOnboardingRuntime.captureFailed and the process STAYS ALIVE with no
#       pipeline (a failure surface for the parent, a watchdog restart every
#       SUMMARY_STALE_SECS). Exit 4 is the `captureLoss: exit` / `--process`
#       dev shape. Those launches DO open run.jsonl, and deliberately since
#       2026-09-12 — this sentence used to claim the opposite and was made
#       false by the fix below it. `startPipeline`'s catch arms
#       `HoldHeartbeat.pipelineFailed`, which builds its own FrameLogger and
#       writes a record immediately, so the banner state keeps its OWN
#       freshness. It has to: the old claim leaned on watchdog.sh's
#       `[ "$mtime" -ge "$started" ]` guard skipping judgement, a later fix deleted
#       that guard (an absent run.jsonl is now judged as `observed=missing`),
#       and a completed install has `completedAt` set so `waiting_for_parent`
#       does not park it either — the repair UI would have been restarted out
#       from under a parent. Opening the log also ROLLS it, which is harmless
#       here because this route STAYS ALIVE: there is no relaunch loop to
#       spend generations on, and a route that does loop is still covered by
#       the minRolledRunLifetimeSecs skip (Logger.swift names which
#       loops that covers).
#   (2) The window is PERSISTED ($BURST_STATE below), because a passed-through
#       non-zero exit ENDS this wrapper: launchd then starts a FRESH wrapper
#       whose in-memory counter is zero, so an in-process-only counter can
#       never reach the budget for exactly the exits (1) adds. This also closes
#       the hole the 2026-08-25 review named for the watchdog (a kickstart
#       every ~60 s produced a fresh wrapper with a zeroed count). The window
#       stays tumbling: a launch more than BURST_WINDOW after the recorded
#       start resets it, and a trip CONSUMES the window (the marker and its
#       cooldown are the enforcement from that point, so the next wrapper after
#       the cooldown starts from zero, as it did before this change).
RELAUNCH_BURST=10
BURST_WINDOW=120
# Evidence only since 2026-09-11 (receipt in the header): written on every
# trip so watchdog.sh can ALERT, moved aside by the next wrapper start, and
# never consulted before a launch. There is no cooldown constant any more —
# launchd's ThrottleInterval paces the retry.
BURST_MARKER="$d/RELAUNCH_BURST.tripped"
# The tumbling window, carried across wrapper launches (receipt (2) above):
# one line, "<window start epoch> <count>". Written only when a non-zero exit
# is counted, so a healthy machine never has one. It lives in the per-uid log
# dir, whose owner and mode the LOG_DIR_OWNER tripwire enforces, so only this
# account and root can write it — the same trust boundary as BURST_MARKER, and
# the same consequence if the account poisons its own (it can already kill its
# own agent, and the watchdog ALERTs on the marker a poisoned count produces).
# WHY A COUNTER MAY LIVE HERE WHEN A GATE MAY NOT (integration receipt,
# 2026-09-12): 2026-09-11 removed the marker cooldown precisely because this
# directory belongs to the protected account, so anything here that WITHHOLDS a
# launch is an off switch a child can hold. This file withholds nothing. The
# worst a poisoned count does is make one wrapper exit 1 after one child exit;
# launchd starts a fresh wrapper ~10 s later and that wrapper launches the
# daemon regardless. Keep it that way: never add a branch that refuses to launch
# on the strength of this file.
# An unreadable, malformed, future-dated or non-regular entry is ignored and
# named in agent.err rather than obeyed. The next non-zero exit replaces it.
BURST_STATE="$d/RELAUNCH_BURST.window"
# DERIVED: BURST_STATE_READ_BYTES is an input bound, not an operating timeout. The
# writer's contract is two signed 64-bit-compatible decimal integers plus one
# space and one newline: at most 40 bytes (19 + 1 + 19 + 1). A larger record is
# malformed; it is never needed for a healthy state value.
BURST_STATE_READ_BYTES=40
burst_state_read() {
  # The protected account owns $d and can replace BURST_STATE at any time.
  # One lstat followed by `head` is therefore not safe: the name can become a
  # FIFO or symlink between those operations. Open once with O_NONBLOCK and
  # O_NOFOLLOW, verify the open descriptor, and read only the bounded record.
  # The helper also opens $d with O_DIRECTORY|O_NOFOLLOW and fchdirs through
  # that descriptor before it resolves the state basename. Replacing the
  # checked log-directory pathname cannot redirect this state read.
  # /usr/bin/perl is a system executable and File::Temp, Fcntl and Errno are
  # core modules. `env -i` blocks PERL5OPT/PERL5LIB startup injection from the
  # protected session. A missing helper is a persistence failure, never a
  # launch gate; burst_state_load names it and starts from an in-memory zero
  # count.
  /usr/bin/env -i /usr/bin/perl - \
    "$d" "RELAUNCH_BURST.window" "$BURST_STATE_READ_BYTES" \
    "$RELAUNCH_BURST" <<'PERL'
use strict;
use warnings;
use Errno qw(ENOENT ELOOP);
use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW O_DIRECTORY);

my ($dir, $name, $read_bytes, $budget) = @ARGV;
my $directory;
if (!sysopen($directory, $dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)) {
    print 'observed=log-directory-open-error';
    exit 12;
}
if (!chdir $directory) {
    print 'observed=log-directory-fchdir-error';
    exit 12;
}
my $state;
if (!sysopen($state, $name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)) {
    exit 10 if $! == ENOENT;
    print 'observed=symlink' if $! == ELOOP;
    exit($! == ELOOP ? 11 : 12);
}
if (!-f $state) {
    my $type = -p $state ? 'fifo'
             : -d $state ? 'directory'
             : -c $state ? 'character-device'
             : -b $state ? 'block-device'
             : -S $state ? 'socket'
             : 'non-regular';
    print "observed=$type";
    exit 11;
}
my @stat = stat($state);
if (!@stat) {
    print 'observed=fstat-error';
    exit 12;
}
my $size = $stat[7];
if ($size > $read_bytes) {
    print "observed_bytes=$size reason=record-too-large";
    exit 13;
}
my $record = '';
my $read = sysread($state, $record, $read_bytes);
if (!defined $read) {
    print 'observed=sysread-error';
    exit 12;
}
if ($record !~ /\A([0-9]{1,19}) ([0-9]{1,19})\n?\z/) {
    print "observed_bytes=$size reason=invalid-format";
    exit 13;
}
my ($start, $count) = ($1, $2);
# Bash reads a leading zero as octal in arithmetic expressions. Normalize both
# fields to canonical decimal before the shell sees them.
$start =~ s/^0+(?=\d)//;
$count =~ s/^0+(?=\d)//;
# DERIVED: Bash arithmetic uses signed 64-bit integers on supported macOS;
# 2^63-1 is the largest input that cannot overflow that representation.
my $signed_max = '9223372036854775807';
for my $value ($start, $count) {
    if (length($value) == 19 && $value gt $signed_max) {
        print "observed_bytes=$size limit_integer=$signed_max observed_integer=$value reason=integer-out-of-range";
        exit 13;
    }
}
# DERIVED: the writer saves before it tests for a trip, so RELAUNCH_BURST+1 is the
# largest count it can create. Rejecting anything larger avoids a signed Bash
# increment overflow. This is derived from the existing budget, not a new cap.
my $largest_written_count = $budget + 1;
if (length($count) > length($largest_written_count)
        || (length($count) == length($largest_written_count)
            && $count gt "$largest_written_count")) {
    print "observed_bytes=$size limit_count=$largest_written_count observed_count=$count reason=count-above-writer-maximum";
    exit 13;
}
print "$start $count\n" or exit 12;
PERL
}
burst_state_load() {
  local line start count now read_rc
  now=$(date +%s)
  burst_start=$now
  burst_count=0
  line="$(burst_state_read)"
  read_rc=$?
  case "$read_rc" in
    0) ;;
    10) return 0 ;;
    11)
      echo "sentry-screen: budget RELAUNCH_BURST window state $BURST_STATE has" \
           "an unsafe non-regular entry (configured regular file, ${line:-observed=unknown})" \
           "— ignoring it and starting a fresh window;" \
           "the next non-zero exit replaces it (fix: remove the entry)" | log_append "$d/agent.err"
      return 0
      ;;
    13)
      echo "sentry-screen: budget RELAUNCH_BURST window state $BURST_STATE is" \
           "malformed (limit ${BURST_STATE_READ_BYTES} B, ${line:-observed_bytes=unknown}," \
           "expected two non-negative" \
           "signed-64-bit-compatible integers) — starting a fresh window; the next" \
           "non-zero exit replaces it (fix: agent-launch.sh burst_state_read)" \
           | log_append "$d/agent.err"
      return 0
      ;;
    *)
      echo "sentry-screen: budget RELAUNCH_BURST window state $BURST_STATE could not" \
           "be read safely (helper exit $read_rc, ${line:-observed=none}) — non-zero" \
           "exits start from an" \
           "in-memory zero count (fix: agent-launch.sh burst_state_read)" | log_append "$d/agent.err"
      return 0
      ;;
  esac
  start=${line%% *}
  count=${line##* }
  # A start in the future means the clock moved, not that a window is open.
  if [ "$start" -gt "$now" ]; then
    echo "sentry-screen: budget RELAUNCH_BURST window state $BURST_STATE starts in the" \
         "future (observed $start > now $now; the clock moved) — starting a fresh window" \
         | log_append "$d/agent.err"
    return 0
  fi
  if [ $((now - start)) -le "$BURST_WINDOW" ]; then
    burst_start=$start
    burst_count=$count
  fi
}
burst_state_save() {
  # File::Temp returns an already-open regular file. Write through that
  # descriptor. The helper first opens $d with O_DIRECTORY|O_NOFOLLOW and uses
  # fchdir through that descriptor, so a concurrent replacement of the log-dir
  # pathname cannot redirect its state operations. Perl's rename() maps to
  # rename(2): it replaces a FIFO or symlink as a directory entry and never
  # follows its target. It
  # also fails for a directory instead of moving the source inside it. The
  # temporary file is in $d, so a successful replacement is atomic on the same
  # filesystem. A same-uid process can still replace the temporary name after
  # creation, but rename does not open or follow either name; such a race can
  # prevent persistence, but it cannot block this wrapper or write through a
  # symlink. The descriptor write remains bound to the file File::Temp opened.
  # Perl itself has startup controls such as PERL5OPT and PERL5LIB. Run with an
  # empty environment so a protected session cannot execute a module before
  # this helper reaches its file-safety checks.
  /usr/bin/env -i /usr/bin/perl - \
    "$d" "RELAUNCH_BURST.window" "$burst_start" "$burst_count" <<'PERL'
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_DIRECTORY);
use File::Temp qw(tempfile);

my ($dir, $name, $start, $count) = @ARGV;
my $directory;
if (!sysopen($directory, $dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)) {
    exit 23;
}
if (!chdir $directory) {
    exit 24;
}
my ($state, $temporary) = tempfile('.RELAUNCH_BURST.window.XXXXXXXX',
                                   DIR => '.', UNLINK => 0);
if (!chmod 0644, $state) {
    unlink $temporary;
    exit 20;
}
if (!print {$state} "$start $count\n" || !close $state) {
    unlink $temporary;
    exit 21;
}
if (!rename $temporary, $name) {
    unlink $temporary;
    exit 22;
}
PERL
  local save_rc=$?
  [ "$save_rc" -eq 0 ] || \
    echo "sentry-screen: budget RELAUNCH_BURST window state $BURST_STATE could not be" \
         "written safely (helper exit $save_rc) — non-zero exits stop accumulating" \
         "across wrapper launches (fix: agent-launch.sh burst_state_save and the" \
         "per-uid log dir permissions)" | log_append "$d/agent.err"
}
# Tripwire MIN_LIFETIME: exit 0 means "launchd stopped us" and is passed
# through silently — which is exactly what hid the 2026-09-01 install outage:
# a wrong binary exited 0 within a second
# of every launch, launchd saw a clean stop, and nothing was written
# anywhere. A healthy daemon that was not asked to stop lives far longer
# than its own startup (≈3.4 s to first frame, MEASURED 2026-08-25); an exit
# 0 inside MIN_LIFETIME with no TERM from this wrapper is abnormal and must
# say so by name. 10 s is ASSUMED: ~3x the measured startup, well under any
# healthy lifetime. Exit 1 so launchd records an abnormal stop.
MIN_LIFETIME=10
# Budget AGENT_LOG_CAP: agent.out and agent.err — the daemon's stdout/stderr
# plus this wrapper's own lines — had no size limit. run.jsonl rotates at
# 50 MiB x 4 generations (Logger.swift logFileCapBytes); these two did not.
# MEASURED
# 2026-09-02 on an M1 Mac (uid 501, one process up ~16 h): agent.out 183,034 B
# / 1,170 lines (sched summaries, pause ticks, curtain and capture events),
# agent.err 9,424 B / 151 lines (curtain, capture, ui, onboarding lines) —
# ≈0.27 MB/day, so a healthy machine reaches 5 MiB in ≈19 days. This is a
# rotation budget healthy use is EXPECTED to hit, not a tripwire: the line it
# writes names the budget, the limit and the observed size so the rate keeps
# being re-measured for free. One rotated generation each (.1), so the pair is
# bounded at 4 x 5 MiB = 20 MiB per uid on top of run.jsonl's 200 MiB.
AGENT_LOG_CAP_BYTES=5242880   # 5 MiB
# The child holds both files open, so rotation is copy-then-truncate: the
# daemon's fds were opened O_APPEND by launch_with_logs, a truncate under them is
# safe and the next write lands at the new end, whereas a `mv` would leave the
# child writing into the moved inode until its next relaunch. Lines the child
# writes between the cp and the truncate are lost; at the measured rate
# (~1 line/min) that window is empty. AGENT_LOG_CAP_CHECK_SECS is how often
# the cap is checked while a child runs — it bounds the OVERSHOOT, not the
# healthy rate: ASSUMED worst plausible spew is a line per frame (30 fps x
# ~100 B = 3 KB/s), which is 180 KB per 60 s check, 3.5 % of the cap.
AGENT_LOG_CAP_CHECK_SECS=60
cap_log() {  # file
  # Through descriptors opened O_NONBLOCK|O_NOFOLLOW and checked to be
  # regular files (LOG_FILE_SAFE_OPEN above): `cp` or `>` on a name this
  # account swapped for a FIFO would block the wrapper. Prints nothing under
  # the cap or for a non-regular file (the watchdog moves that one aside).
  local result
  # shellcheck disable=SC2016  # perl source: its $ are perl's
  result="$(/usr/bin/env -i /usr/bin/perl -e '
use Fcntl;
my ($f, $cap) = @ARGV;
sysopen(my $src, $f, O_RDWR | O_NONBLOCK | O_NOFOLLOW) or exit 0;
-f $src or exit 0;
my $size = -s _;
exit 0 if $size < $cap;
my $action = "copy to $f.1 FAILED, truncated in place";
my $dst;
if (sysopen($dst, "$f.1", O_WRONLY | O_CREAT | O_TRUNC | O_NONBLOCK | O_NOFOLLOW, 0644) && -f $dst) {
  my ($buf, $ok) = ("", 1);
  while (1) {
    my $n = sysread($src, $buf, 1 << 20);
    if (!defined $n) { $ok = 0; last }
    last if $n == 0;
    if (!defined syswrite($dst, $buf)) { $ok = 0; last }
  }
  $action = "rotated to $f.1" if $ok;
}
truncate($src, 0) or $action .= "; truncate FAILED, file still $size B";
print "$size B in $f, $action";' "$1" "$AGENT_LOG_CAP_BYTES")"
  [ -n "$result" ] || return 0
  echo "sentry-screen: budget AGENT_LOG_CAP, limit ${AGENT_LOG_CAP_BYTES} B," \
       "observed $result" \
       "(fix: agent-launch.sh AGENT_LOG_CAP_BYTES)" | log_append "$d/agent.err"
}
# Tripwire CAPPER_STOP_TRIES x CAPPER_STOP_INTERVAL: how long the teardown
# below keeps re-sending pkill to the checker's `sleep`. One pkill can miss: if
# the child died between the checker's `kill -0` and its `sleep` fork there is
# no sleep yet, and a bare `wait` would then block a full
# AGENT_LOG_CAP_CHECK_SECS (60 s) before the relaunch — on the exit-7 handoff a
# parent is watching (review 2026-09-02). The only other thing the checker can
# be doing is cap_logs: MEASURED 2026-09-02, `cp` of a 5 MiB file 7 ms on this
# Mac's APFS, so 10 rounds x 0.1 s = 1 s is >100x that window; past it the
# checker's own loop head sees the child gone and exits on its own. 0.1 s is
# the interval (ASSUMED: ~10x the fork+exec latency of `sleep`, and the
# smallest step that keeps the common case — one pkill hits — at one round).
# Exhausting the rounds is logged by name below; the wait after it still
# returns as soon as the checker's cp finishes.
CAPPER_STOP_TRIES=10
CAPPER_STOP_INTERVAL=0.1
cap_logs() { cap_log "$d/agent.out"; cap_log "$d/agent.err"; }
if [ -e "$BURST_MARKER" ] || [ -L "$BURST_MARKER" ]; then
  # The previous wrapper — or the account itself, this being its own directory —
  # left a marker. It is evidence, not a gate: move it aside and launch.
  # Renamed rather than deleted because watchdog.sh reports the .tripped.last
  # it finds; `mv -f` preserves the mtime the watchdog keys on. The next trip
  # overwrites the breadcrumb.
  mv -f "$BURST_MARKER" "$BURST_MARKER.last" 2>/dev/null || rm -f "$BURST_MARKER"
  echo "sentry-screen: budget RELAUNCH_BURST — a previous wrapper tripped it;" \
       "moved $BURST_MARKER to $BURST_MARKER.last and launching anyway" \
       "(the marker is evidence, never a gate — receipt in this file;" \
       "the exits and the count are above in this log)" | log_append "$d/agent.err"
fi

child=""
capper=""
stopping=""
# A TERM while the onboarding handoff is armed (settings.json
# verificationPending=true, written before System Settings opens) is macOS's
# Quit & Reopen after the Screen Recording toggle, not launchd stopping the
# job: keep running so the child's exit 7 relaunches through the normal path.
# MEASURED fi-reset-01 (2026-08-29): this wrapper took that TERM as a stop and
# exited 0; the watchdog's next pass was the only thing that brought the agent
# back. A real bootout during an armed handoff still ends: launchd kills what
# remains of the job after its exit timeout, and uninstall.sh verifies.
#
# Tripwire HANDOFF_MAX_AGE (2026-09-11, CONFIRMED).
# `verificationPending:true` alone used to arm this forever: a flag the daemon
# failed to settle (MEASURED on a test Mac 2026-09-03 — a handoff armed by a
# permission repair on a Mac with no usable license left it set; see
# UIOnboardingRuntime.armedHandoffOutcome) made this wrapper read EVERY launchd
# TERM as macOS's Quit & Reopen, including a real bootout, a logout and an
# uninstall. The record always carries `verificationStartedAt` beside the flag
# (UIOnboardingState.beginFreshProcessVerification writes the two together, and
# UISettingsStore refuses a record that has one without the other), so the age
# is checkable: armed only while that timestamp is within HANDOFF_MAX_AGE, and
# anything else is reported by name and treated as NOT armed — the conservative
# direction, because a TERM taken as a stop is recovered by launchd's KeepAlive
# within ~10 s, while a TERM ignored forever is a job that cannot be stopped.
# Receipt, DERIVED from the owner-attended 2026-08-29 permission repair: the
# full 07:54:00–07:58:32Z episode took at most 272 s, including failed attempts
# before the successful handoff. Thus the successful handoff was shorter than 272 s; 600 s exceeds twice that bound.
# This is one observed episode, not a percentile for all parents. The earlier
# 100x human-step claim used machine startup time and was invalid. If a healthy
# handoff reaches this unchanged limit, record that flow before changing it.
HANDOFF_MAX_AGE=600
SETTINGS="$SUPPORT/state/settings.json"
handoff_armed() {
  local ts started age
  grep -q '"verificationPending" *: *true' "$SETTINGS" 2>/dev/null || return 1
  # One key, one line (the daemon writes this file pretty-printed, which is why
  # the grep above works too). Nothing else in the file is read: settings.json
  # is root:admin in a 2755 state directory (configure-install.sh), so a
  # Standard child cannot write it — but a torn or hand-edited file must still
  # not arm anything.
  ts="$(sed -n 's/.*"verificationStartedAt" *: *"\([^"]*\)".*/\1/p' "$SETTINGS" 2>/dev/null | head -1)"
  if [ -z "$ts" ]; then
    echo "sentry-screen: tripwire HANDOFF_MAX_AGE, configured verificationPending=true" \
         "with a verificationStartedAt timestamp, observed the flag with none in" \
         "$SETTINGS — treating the onboarding handoff as NOT armed, so this TERM" \
         "stops the job (fix: the daemon settles the flag —" \
         "UIOnboardingState.recordVerificationFailure)" | log_append "$d/agent.err"
    return 1
  fi
  started="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || true)"
  case "${started:-}" in
    ''|*[!0-9]*)
      echo "sentry-screen: tripwire HANDOFF_MAX_AGE, configured an ISO 8601 UTC" \
           "verificationStartedAt, observed \"$ts\" in $SETTINGS — unparseable," \
           "treating the handoff as NOT armed (fix: inspect $SETTINGS)" | log_append "$d/agent.err"
      return 1
      ;;
  esac
  age=$(( $(date +%s) - started ))
  if [ "$age" -ge "$HANDOFF_MAX_AGE" ]; then
    echo "sentry-screen: tripwire HANDOFF_MAX_AGE, limit ${HANDOFF_MAX_AGE}s," \
         "observed ${age}s since verificationStartedAt=$ts — the onboarding" \
         "handoff flag is STUCK; treating this TERM as a real stop" \
         "(fix: agent-launch.sh HANDOFF_MAX_AGE, or the daemon path that never" \
         "settled verificationPending in $SETTINGS)" | log_append "$d/agent.err"
    return 1
  fi
  return 0
}
forward() {
  if handoff_armed; then
    echo "sentry-screen: TERM during armed onboarding handoff (Quit & Reopen) — not stopping, child relaunches on exit 7" | log_append "$d/agent.err"
  else
    stopping=1
  fi
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
}
trap forward TERM INT
utc_timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

burst_state_load
pending_relaunch_exit=""
pending_old_pid=""
pending_old_started_at=""
pending_old_exited_at=""
while :; do
  # Trap race (review 2026-08-25): a TERM/INT landing while child="" (between
  # a child's exit and the next launch) killed nothing, and the next
  # iteration launched a fresh daemon before `stopping` was rechecked —
  # shutdown deferred a whole TTL cycle. Check at the loop head, and again
  # once the new pid is known.
  [ -n "$stopping" ] && exit 0
  # AGENT_LOG_CAP at every launch boundary (this covers a KeepAlive relaunch
  # of the wrapper too), then every AGENT_LOG_CAP_CHECK_SECS while the child
  # runs — the daemon writes to both files mid-run, and an installed build has
  # no TTL, so a launch-only check would never bound a months-long process.
  cap_logs
  # --ttl 0 after --config: flags win, so the installed build never TTL-exits
  # whatever the (possibly preserved) config.json says — header receipt.
  # `env -i`: tripwire ENV_SCRUB above. The flag SET on this line is also the
  # daemon's arming rule for its SENTRY_* knobs (DevEnv.installedFlags), so it
  # stays exactly --config/--log/--ttl; agent-launch-test.sh asserts both.
  launch_out="$(launch_log "$d/agent.out")"
  launch_err="$(launch_log "$d/agent.err")"
  launch_with_logs "$launch_out" "$launch_err" \
    "$BIN" --config "$SUPPORT/config.json" --log "$d/run.jsonl" --ttl 0 &
  child=$!
  child_started_at=$(utc_timestamp)
  child_started_epoch=$(date +%s)
  # The subshell's stderr is dropped: every line cap_log writes goes to
  # agent.err by explicit redirect, and the only thing left on stderr is bash's
  # "Terminated: 15 sleep" job notice when the pkill below ends the sleep.
  ( while kill -0 "$child" 2>/dev/null; do
      sleep "$AGENT_LOG_CAP_CHECK_SECS"
      kill -0 "$child" 2>/dev/null && cap_logs
    done ) 2>/dev/null &
  capper=$!
  if [ "$pending_relaunch_exit" = "$TCC_RELAUNCH_EXIT" ]; then
    echo "sentry-screen: relaunch_receipt exit=$pending_relaunch_exit" \
         "oldPID=$pending_old_pid oldStartedAt=$pending_old_started_at" \
         "oldExitedAt=$pending_old_exited_at newPID=$child" \
         "newStartedAt=$child_started_at" | log_append "$d/agent.err"
    pending_relaunch_exit=""
    pending_old_pid=""
    pending_old_started_at=""
    pending_old_exited_at=""
  fi
  [ -n "$stopping" ] && kill -TERM "$child" 2>/dev/null
  wait "$child"
  rc=$?
  # A trapped signal returns from `wait` early; wait again for the child's
  # real exit before deciding anything.
  while kill -0 "$child" 2>/dev/null; do wait "$child"; rc=$?; done
  # The cap checker is tied to this child; end it before deciding anything so
  # no checker outlives the wrapper. Its `sleep` is what gets the signal, not
  # the subshell: the loop then sees the child gone and exits by itself. A
  # TERM at the bash subshell instead hit bash 3.2's run_pending_traps
  # ("bad value in trap_list[15]", MEASURED in agent-launch-test 2026-09-02) —
  # the parent's trap slot is inherited but reset — and a mid-`cp` signal
  # would turn a rotation into a truncation.
  i=0
  while kill -0 "$capper" 2>/dev/null && [ "$i" -lt "$CAPPER_STOP_TRIES" ]; do
    pkill -P "$capper" -x sleep 2>/dev/null
    sleep "$CAPPER_STOP_INTERVAL"; i=$((i + 1))
  done
  if kill -0 "$capper" 2>/dev/null; then
    echo "sentry-screen: tripwire CAPPER_STOP_TRIES, limit ${CAPPER_STOP_TRIES} x ${CAPPER_STOP_INTERVAL}s," \
         "observed log-cap checker pid $capper still alive — waiting for it; the relaunch is" \
         "delayed until it exits (fix: agent-launch.sh CAPPER_STOP_TRIES)" | log_append "$d/agent.err"
  fi
  wait "$capper" 2>/dev/null
  capper=""
  exited_child=$child
  exited_child_started_at=$child_started_at
  exited_child_exited_at=$(utc_timestamp)
  child=""
  [ -n "$stopping" ] && exit 0
  lifetime=$(( $(date +%s) - child_started_epoch ))
  if [ "$rc" -eq 0 ]; then
    if [ "$lifetime" -lt "$MIN_LIFETIME" ]; then
      echo "sentry-screen: tripwire MIN_LIFETIME, limit ${MIN_LIFETIME}s, observed ${lifetime}s —" \
           "daemon pid $exited_child exited 0 without a stop from this wrapper" \
           "(fix: verify the installed binary and its signature: codesign -dv" \
           "\"$SUPPORT/SentryScreen.app\"; reinstall with packaging/install.sh)" | log_append "$d/agent.err"
      exit 1
    fi
  fi
  # Burst accounting, receipt amendment (1)/(2) at RELAUNCH_BURST: EVERY
  # non-zero exit counts, including the ones passed through to launchd below —
  # those end this wrapper, so the count only exists if it is written down.
  if [ "$rc" -ne 0 ]; then
    now=$(date +%s)
    if [ $((now - burst_start)) -gt "$BURST_WINDOW" ]; then
      burst_start=$now; burst_count=0
    fi
    burst_count=$((burst_count + 1))
    burst_state_save
    if [ "$burst_count" -gt "$RELAUNCH_BURST" ]; then
      echo "sentry-screen: budget RELAUNCH_BURST, limit $RELAUNCH_BURST non-zero exits" \
           "per ${BURST_WINDOW}s, observed $burst_count (last exit $rc) — this wrapper" \
           "exits 1; launchd starts a fresh one after its ThrottleInterval (~10s)," \
           "which launches the daemon anyway (the marker is evidence, never a gate" \
           "— receipt in this file), so protection resumes unless the daemon keeps failing" \
           "(fix: agent-launch.sh RELAUNCH_BURST)" | log_append "$d/agent.err"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) RELAUNCH_BURST tripped: $burst_count non-zero exits in ${BURST_WINDOW}s" | log_replace "$BURST_MARKER"
      # The trip CONSUMES the window. There is no cooldown to be "the
      # enforcement from here" (removed 2026-09-11), which makes this `rm`
      # load-bearing rather than tidy: without it the next wrapper would load a
      # count already past the budget and trip on its FIRST child exit, again
      # and again for the rest of BURST_WINDOW. The next wrapper starts at zero
      # and launches the daemon; the marker it finds is evidence it moves aside.
      rm -f "$BURST_STATE"
      exit 1
    fi
  fi
  # Relaunch set — receipt in the header comment. Everything else is passed
  # through to launchd unchanged.
  case "$rc" in
    "$TTL_EXIT"|"$TCC_RELAUNCH_EXIT"|"$QUIT_REOPEN_EXIT") ;;
    0) exit 0 ;;
    *)
      # This exit ends the wrapper, so it is the last chance to say that it was
      # counted and — when the child outlived the budget's reach (PRECONDITION
      # at RELAUNCH_BURST) — that the count will never reach the budget. Never
      # silent: a loop that this tripwire cannot stop must at least be legible
      # here.
      burst_reach=$((BURST_WINDOW / RELAUNCH_BURST))
      if [ "$lifetime" -gt "$burst_reach" ]; then
        burst_verdict="longer than the ${burst_reach}s this budget can reach, so the window resets every cycle and the loop is reported here, not stopped"
      else
        burst_verdict="within the ${burst_reach}s this budget reaches, so a repeat trips it"
      fi
      echo "sentry-screen: abnormal exit $rc after ${lifetime}s — counted" \
           "$burst_count/$RELAUNCH_BURST toward budget RELAUNCH_BURST in its" \
           "${BURST_WINDOW}s window; this cycle is $burst_verdict" \
           "(fix: agent-launch.sh RELAUNCH_BURST)" | log_append "$d/agent.err"
      exit "$rc"
      ;;
  esac
  # Only exit 7 gets the PID-pairing receipt: it is the one relaunch a human
  # (or the onboarding window) is waiting on, so old→new PID must be provable
  # in agent.err. TTL and Quit & Reopen relaunches log the plain line below.
  if [ "$rc" -eq "$TCC_RELAUNCH_EXIT" ]; then
    pending_relaunch_exit=$rc
    pending_old_pid=$exited_child
    pending_old_started_at=$exited_child_started_at
    pending_old_exited_at=$exited_child_exited_at
  fi
  echo "sentry-screen: relaunch exit $rc (ttl/tcc-reeval/quit-reopen) — relaunching ($burst_count/$RELAUNCH_BURST in window)" | log_append "$d/agent.err"
done
