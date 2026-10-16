#!/bin/bash
# SentryScreen watchdog (B3, milestone-3-plan.md). Runs as root from a
# LaunchDaemon on a StartInterval; each run is one pass: check, repair,
# alert, exit. No resident state — launchd is the scheduler.
#
# Division of labor (why this exists when the agent plist has KeepAlive):
#   - launchd KeepAlive restarts a CRASHED agent process. It does NOT
#     restore a job that was booted out of the gui domain (`launchctl
#     bootout gui/$uid/...` works for the session's own user WITHOUT admin
#     — the per-domain job is the user's to unload even when the plist
#     lives in /Library/LaunchAgents), and it does not notice deleted or
#     re-owned files, a job the session DISABLED (`launchctl disable`, no
#     admin, survives reinstall), or a process that is still alive but
#     STOPPED (`kill -STOP`, which SIGSTOP cannot refuse) or wedged.
#   - This watchdog re-bootstraps missing jobs into every active GUI
#     session, re-enables disabled ones, resumes a stopped agent (SIGCONT,
#     then `kickstart -k`), restarts one whose log stopped advancing,
#     verifies the install's files, and appends ALERT lines to a
#     parent-readable file (C2 hook: the future onboarding/parent UI tails
#     alerts.log; email/push lands there too).
#
# Every repair and every failure is an ALERT — a watchdog that fixes
# things silently hides exactly the tampering a parent needs to know about.
#
# Dev mode: SENTRY_WATCHDOG_DEV=1 targets the user-level dev agent
# (com.sentryscreen.dev in the caller's own gui domain, no root needed) so
# the repair loop is testable before the system install exists.
set -u

# the installed copy ignores the development and test
# overrides this script reads. Only a copy run from elsewhere (the repo tree,
# the lifecycle tests' isolated payload) honours them, so an environment a
# user can set (launchctl setenv) never reaches the installed script.
case "$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" in
  "/Library/Application Support/SentryScreen" | "") unset SENTRY_WATCHDOG_DEV ;;
esac
if [ "${SENTRY_WATCHDOG_DEV:-0}" = "1" ]; then
  LABEL=com.sentryscreen.dev
  AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  ALERTS="$HOME/Library/Logs/SentryScreen-dev/alerts.log"
  LOG_ROOT="$HOME/Library/Logs/SentryScreen-dev"
  # The dev daemon's state root is UISettingsStore's per-user dev fallback.
  SETTINGS="$HOME/Library/Application Support/SentryScreen/state/settings.json"
  UIDS="$(id -u)"
  STALE_UIDS=""
  # "<uid> <handle>" per watched session; see session_key below.
  LIVE_SESSIONS="$UIDS $(launchctl print "gui/$UIDS" 2>/dev/null | awk '$1 == "handle" && $2 == "=" { print $3; exit }')"
  REQUIRE_ROOT_OWNER=0
else
  LABEL=com.sentryscreen.agent
  AGENT_PLIST="/Library/LaunchAgents/$LABEL.plist"
  ALERTS="/Library/Application Support/SentryScreen/alerts.log"
  # Per-uid wrapper dirs (agent-launch.sh): $LOG_ROOT/<uid>/{agent.err,...}
  LOG_ROOT="/Library/Logs/SentryScreen"
  # Read (never written) by the silent-process check below. root:admin, state
  # dir 2755 (configure-install.sh), so a Standard child cannot write it.
  SETTINGS="/Library/Application Support/SentryScreen/state/settings.json"
  # Users with an actual GUI session only. `who` also lists SSH/tty logins;
  # its `console` records can remain after logout. MEASURED on the macOS 27
  # test Mac on 2026-09-20: `who` still
  # listed uid 503 after its gui domain had gone (`launchctl print` exit 125).
  # Re-bootstrap then failed on every pass, and the healthy current user's
  # popover reported a failed watchdog. Require the gui domain itself before
  # checking or repairing that session's agent; a row without one goes to
  # STALE_UIDS and is named once below.
  # The same print carries the domain's `handle` (its audit session id; the
  # `handle = 136397` line MEASURED on the macOS 27 test Mac, 2026-09-28), kept as
  # LIVE_SESSIONS "<uid> <handle>" so the missing-job repair can tell a job
  # that left THIS session from one a new login has not loaded yet
  # (session_key below). No extra launchctl call.
  SESSION_ROWS="$(who | awk '$2=="console"{print $1}' | sort -u \
          | while read -r u; do
              uid="$(id -u "$u" 2>/dev/null)" || continue
              if domain="$(launchctl print "gui/$uid" 2>/dev/null)"; then
                printf '%s %s\n' "$uid" "$(printf '%s\n' "$domain" | awk '$1 == "handle" && $2 == "=" { print $3; exit }')"
              else
                printf 'stale:%s\n' "$uid"
              fi
            done)"
  LIVE_SESSIONS="$(printf '%s\n' "$SESSION_ROWS" | grep -v '^stale:' || true)"
  UIDS="$(printf '%s\n' "$LIVE_SESSIONS" | awk 'NF { print $1 }')"
  STALE_UIDS="$(printf '%s\n' "$SESSION_ROWS" | sed -n 's/^stale://p')"
  REQUIRE_ROOT_OWNER=1
fi

mkdir -p "$(dirname "$ALERTS")"
alert() {
  # ISO timestamp + level + message, one line, parseable.
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1 $2" | tee -a "$ALERTS" >&2
}
failed=0

# Report-once state. Full receipt (why it lives beside alerts.log and never in
# a path a child controls) is at report_wrapper_marker below; defined here
# because the liveness checks above it need it too.
STAMP_DIR="$(dirname "$ALERTS")/watchdog-state"
# The recorded value for a key, or "none". Never follows a symlink into a file
# it would then print: STAMP_DIR is root-owned 0755 beside alerts.log (MEASURED
# 2026-09-02) so a child cannot pre-place one, and a stamp that IS a symlink is
# refused by stamp_set rather than written through.
stamp_value() {  # key
  local stamp="$STAMP_DIR/$1"
  [ -f "$stamp" ] && [ ! -L "$stamp" ] || { echo none; return 0; }
  cat "$stamp" 2>/dev/null || echo none
}
# Records a value for a key. A stamp that cannot be written is loud — the
# alternative is a line that repeats silently every pass, or a budget that
# silently never counts.
stamp_set() {  # key value
  local stamp="$STAMP_DIR/$1"
  mkdir -p "$STAMP_DIR" 2>/dev/null
  if [ -L "$stamp" ] || ! printf '%s\n' "$2" >"$stamp" 2>/dev/null; then
    alert ALERT "watchdog stamp $stamp could not be written (symlink or unwritable) — the line it keys will repeat every pass until it can be"
    return 1
  fi
  return 0
}
# True (0) when this key's value differs from the last one recorded, and records
# the new one: the "report this once" primitive.
stamp_changed() {  # key value
  [ "$2" != "$(stamp_value "$1")" ] || return 1
  stamp_set "$1" "$2" || true
  return 0
}

# A console row left out of UIDS for a missing gui domain is named once per
# stale episode, never every pass: a healthy pass stays silent (ALERTS_CAP).
# The stamp flips back to `live` when that uid has a gui domain again, so a
# later logout that leaves another stale row is named again.
for uid in $STALE_UIDS; do
  if stamp_changed "$uid.console" stale; then
    alert INFO "console row for uid $uid has no live gui/$uid domain (logged out); not watched until that account logs in again"
  fi
done
for uid in $UIDS; do stamp_changed "$uid.console" live || true; done


# --- Per-uid log directory repair (T2, security review 2026-09-28) ----------
# Until 2026-09-28 a wrong shape here made agent-launch.sh refuse to launch
# (exit 78) and this script only reported it, so a directory the protected
# account controls decided whether that account was protected. Now
# the wrapper repairs or falls back by itself (it never refuses), and this
# pass restores the canonical directory as root:
#   * the account's own directory with a wrong mode: mode set back to 0755
#     through a no-follow handle (fchmod, never a path a child can swap); the
#     running agent's open files are unaffected, so no restart;
#   * anything else (a symlink, a file, another owner, an unreadable shape):
#     renamed aside to $LOG_ROOT/.<uid>.quarantine.<epoch>.<pid> — rename(2)
#     on the entry itself, never following it, and never deleted as root —
#     then recreated root-side with mode 0755 and handed to the uid with
#     `chown -h` as the LAST root operation on that path (the name is
#     root-owned in the 1777 sticky root until the chown, so it cannot be
#     swapped before it; once the uid owns it, root never touches the path
#     again — a chmod after the chown followed a swapped-in symlink, review
#     2026-10-16), and the agent is restarted so it writes there again;
#   * inside an accepted directory, an agent.out, agent.err or run.jsonl that
#     is not a regular file (a FIFO blocks whoever opens it, a symlink
#     redirects the writes) is renamed aside through a no-follow directory
#     handle, never followed or deleted, and the agent is restarted so it
#     recreates a regular file (repair_log_files).
# Every repair is a tamper event and an ALERT; neither is a `failed` pass
# unless the repair itself fails. Honest limit: repeated tampering can cost a
# restart (a few seconds unfiltered) per 60 s pass in the second case; each
# one is in the ledger and the parent's email.
# The three files the agent and daemon append to. Run as root against a
# directory the uid owns, so the directory is opened once with
# O_DIRECTORY|O_NOFOLLOW and every lstat and rename is relative to that handle
# (fchdir): swapping the directory name cannot point a root rename elsewhere.
# `env -i` keeps PERL5OPT/PERL5LIB from the protected session out.
repair_log_files() {  # uid
  local uid="$1" dir="$LOG_ROOT/$1" result verb name type aside moved=0
  result="$(/usr/bin/env -i /usr/bin/perl - "$dir" "$uid" "$(date +%s)" <<'LOG_FILES_PERL'
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_DIRECTORY :mode);
my ($dir, $uid, $now) = @ARGV;
sysopen(my $d, $dir, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) or exit 0;
my @s = stat($d);
exit 0 unless @s && $s[4] == $uid;
chdir $d or exit 0;
for my $name ('agent.out', 'agent.err', 'run.jsonl') {
    my @l = lstat($name) or next;
    next if S_ISREG($l[2]);
    my $type = S_ISLNK($l[2]) ? 'symlink' : S_ISFIFO($l[2]) ? 'fifo'
             : S_ISDIR($l[2]) ? 'directory' : S_ISSOCK($l[2]) ? 'socket'
             : (S_ISCHR($l[2]) || S_ISBLK($l[2])) ? 'device' : 'non-regular';
    my $aside = ".$name.tamper.$now.$$";
    if (rename($name, $aside)) { print "moved $name $type $aside\n" }
    else { print "failed $name $type -\n" }
}
LOG_FILES_PERL
)"
  while read -r verb name type aside; do
    [ -n "$aside" ] || continue
    if [ "$verb" = moved ]; then
      alert ALERT "per-uid log file $dir/$name configured=type=Regular,no-symlink observed=type=$type — moved aside to $dir/$aside; restarting the agent so it writes a regular file again (tamper: log-file-repaired)"
      moved=1
    else
      alert ALERT "per-uid log file $dir/$name configured=type=Regular,no-symlink observed=type=$type — could not be moved aside; the agent logs that stream to /dev/null (fix: remove $dir/$name as an administrator)"
      failed=1
    fi
  done <<<"$result"
  if [ "$moved" = 1 ] && [ "${SENTRY_WATCHDOG_DEV:-0}" != "1" ]; then
    launchctl kickstart -k "gui/$uid/$LABEL" 2>>"$ALERTS" \
      || { alert ALERT "kickstart -k FAILED for gui/$uid after the log file repair"; failed=1; }
  fi
}
repair_log_dir() {  # uid
  local uid="$1" dir="$LOG_ROOT/$1" have q
  [ -e "$dir" ] || [ -L "$dir" ] || return 0   # absent: the wrapper creates it
  # lstat, never stat: a symlink must report itself, not its target.
  have="$(stat -f 'type=%HT,owner=%u,mode=%Lp' "$dir" 2>/dev/null || echo 'type=unreadable,owner=?,mode=?')"
  case "$have" in
    "type=Directory,owner=$uid,mode=755" | "type=Directory,owner=$uid,mode=700") repair_log_files "$uid"; return 0 ;;
    "type=Directory,owner=$uid,"*)
      if /usr/bin/perl -e 'use Fcntl; sysopen(my $d, $ARGV[0], O_RDONLY | O_NOFOLLOW | O_DIRECTORY) or exit 1;
          my @s = stat($d); exit 2 unless @s && $s[4] == $ARGV[1]; chmod(0755, $d) == 1 or exit 3; exit 0' "$dir" "$uid"; then
        alert ALERT "per-uid log directory $dir configured=type=Directory,owner=$uid,mode=755-or-700 observed=$have — mode restored to 755 by the watchdog; protection was not interrupted (tamper: log-folder-repaired)"
        repair_log_files "$uid"
        return 0
      fi ;;
  esac
  q="$LOG_ROOT/.$uid.quarantine.$(date +%s).$$"
  if ! /usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$dir" "$q"; then
    alert ALERT "per-uid log directory $dir configured=type=Directory,owner=$uid,mode=755-or-700 observed=$have — could not be moved aside; the agent for gui/$uid is logging to its temporary fallback (fix: remove $dir as an administrator)"
    failed=1
    return 0
  fi
  # Mode first, ownership last: nothing as root may touch "$dir" by name after
  # the uid owns it (header above).
  if ! mkdir -m 755 "$dir" 2>/dev/null || ! chown -h "$uid" "$dir" 2>/dev/null; then
    alert ALERT "per-uid log directory $dir was moved aside to $q (observed=$have) but could not be recreated for uid $uid — the agent is logging to its temporary fallback (fix: inspect $LOG_ROOT as an administrator)"
    failed=1
    return 0
  fi
  alert ALERT "per-uid log directory $dir configured=type=Directory,owner=$uid,mode=755-or-700 observed=$have — moved aside to $q and recreated; restarting the agent so it logs there again (tamper: log-folder-repaired)"
  if [ "${SENTRY_WATCHDOG_DEV:-0}" != "1" ]; then
    launchctl kickstart -k "gui/$uid/$LABEL" 2>>"$ALERTS" \
      || { alert ALERT "kickstart -k FAILED for gui/$uid after the log directory repair"; failed=1; }
  fi
}

# --- Budget ALERTS_CAP ------------------------------------------------------
# alerts.log had no size limit. A healthy
# pass writes nothing — MEASURED 2026-09-02 on an M1 Mac: no alerts.log exists
# ~16 h after the 01:56 install, i.e. ~960 passes with zero lines. Growth is a
# PERSISTENT failure repeating every 60 s pass: DERIVED worst case 6 lines x
# ~250 B per pass = 2.16 MB/day, so 5 MiB is ~2.3 days of an unattended
# un-repairable state. (Was 3 lines/1.08 MB/day/~5 days until 2026-09-07: the
# disabled-job, stopped-process and stalled-log repairs below can each add an
# ALERT+INFO pair to the same pass. The cap is unchanged deliberately — it
# bounds disk, not evidence, one generation is kept, and an alert nobody has
# read in two days is not news on day five.) The updater's per-phase lines
# (Alerts.swift) are hourly at most. Rotation is a plain `mv`: every writer —
# this one-shot script (`tee -a`) and the updater (opens per line) — reopens
# the path on each write, so nothing keeps a handle across the rename. One
# generation.
ALERTS_CAP_BYTES=5242880   # 5 MiB
alerts_size="$(stat -f %z "$ALERTS" 2>/dev/null || echo 0)"
if [ "$alerts_size" -ge "$ALERTS_CAP_BYTES" ]; then
  if mv -f "$ALERTS" "$ALERTS.1"; then
    alert INFO "budget ALERTS_CAP, limit ${ALERTS_CAP_BYTES} B, observed ${alerts_size} B — rotated $ALERTS to $ALERTS.1 (fix: watchdog.sh ALERTS_CAP_BYTES)"
  else
    alert ALERT "budget ALERTS_CAP, limit ${ALERTS_CAP_BYTES} B, observed ${alerts_size} B — mv to $ALERTS.1 FAILED, file left growing (fix: inspect permissions on $(dirname "$ALERTS"))"
  fi
fi

# --- Log-root recovery -------------------------------------------
# Receipt: after the macOS 27 upgrade on 2026-09-17 the root was root:wheel
# 0744. agent-launch.sh exited 73 on mkdir <uid>; kickstart could not repair
# it. Its creator is unknown. Keep the wrapper's LOG_DIR_OWNER refusal intact.
# The function is extracted by watchdog-log-root-test.sh for isolated fixtures.
repair_log_root() {
  /usr/bin/perl - "$@" <<'LOG_ROOT_PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(dirname);
my ($root, $uid, $gid) = @ARGV;
sub refuse {
    my ($path, $observed) = @_;
    die "LOG_ROOT configured=directory,owner=$uid:$gid,mode=01777,protected-root-writers observed=$observed path=$path remediation=inspect-the-exact-path-as-admin-or-reinstall; watchdog-restarts-skipped\n";
}
sub no_acl {
    my ($path) = @_;
    open(my $ls, '-|', '/bin/ls', '-lde', $path) or refuse($path, 'acl-check-failed');
    my @lines = <$ls>;
    close($ls) or refuse($path, 'acl-check-failed');
    refuse($path, 'ACL-present') if @lines != 1;
}
sub inspect {
    my ($path, $directory) = @_;
    my @s = lstat($path);
    refuse($path, 'stat-failed') unless @s;
    refuse($path, 'unsafe-type') unless $directory ? S_ISDIR($s[2]) : S_ISREG($s[2]);
    refuse($path, "owner=$s[4]:$s[5]") unless $s[4] == $uid && $s[5] == $gid;
    refuse($path, "links=$s[3]") if !$directory && $s[3] != 1;
    no_acl($path);
    open(my $flags, '-|', '/usr/bin/stat', '-f', '%f', $path) or refuse($path, 'flags-check-failed');
    my $value = <$flags>;
    close($flags) or refuse($path, 'flags-check-failed');
    chomp($value);
    refuse($path, "flags=$value") unless $value eq '0';
    return @s;
}
# Walk the real ancestors, not a resolved symlink target. Production uses the
# fixed /Library/Logs/SentryScreen path and root:wheel; fixture arguments never
# enter the installed call. No non-root account can replace an ancestor.
my $parent = dirname($root);
for (my $p = $parent; ; $p = dirname($p)) {
    my @s = lstat($p);
    # A root-owned sticky ancestor (e.g. /private/tmp in isolated tests) also
    # protects its owned child from replacement by other accounts.
    refuse($p, 'unsafe-parent') unless @s && S_ISDIR($s[2]) &&
        ($s[4] == 0 || $s[4] == $uid) &&
        (!($s[2] & 0022) || ($s[4] == 0 && ($s[2] & 01000)));
    no_acl($p);
    last if $p eq '/';
}
my @changes;
if (!lstat($root)) {
    mkdir($root, 0700) or refuse($root, 'mkdir-failed');
    chown($uid, $gid, $root) == 1 or refuse($root, 'chown-failed');
    push @changes, 'created';
}
my @before = inspect($root, 1);
sysopen(my $dir, $root, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) or refuse($root, 'open-failed');
my @opened = stat($dir);
refuse($root, 'identity-changed') unless $opened[0] == $before[0] && $opened[1] == $before[1];
my $mode = $before[2] & 07777;
if ($mode != 01777) {
    # Lock a non-sticky or inaccessible directory before checking its writers.
    # On failure it stays private. Never make an unsafe directory public.
    chmod(0700, $dir) == 1 or refuse($root, 'lock-mode-failed');
    push @changes, sprintf('mode=%04o->1777', $mode);
}
for my $name ('watchdog.err') {
    my $path = "$root/$name";
    my $directory = 0;
    if (!lstat($path)) {
        if ($directory) {
            mkdir($path, 0700) or refuse($path, 'mkdir-failed');
        } else {
            sysopen(my $file, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
                or refuse($path, 'exclusive-create-failed');
            close($file) or refuse($path, 'close-failed');
        }
        # New paths belong to the root process. Never chown an existing name.
        push @changes, "created=$name";
    }
    my @s = inspect($path, $directory);
    refuse($path, 'group-or-world-writable') if $s[2] & 0022;
}
if ($mode != 01777) {
    chmod(01777, $dir) == 1 or refuse($root, 'restore-mode-failed');
}
my @after = stat($dir);
refuse($root, 'mode-verification-failed') unless ($after[2] & 07777) == 01777;
print "LOG_ROOT repaired path=$root ", join(',', @changes), "\n" if @changes;
LOG_ROOT_PERL
}
if [ "$REQUIRE_ROOT_OWNER" = "1" ]; then
  if log_root_result="$(repair_log_root "$LOG_ROOT" 0 0 2>&1)"; then
    [ -z "$log_root_result" ] || alert ALERT "$log_root_result"
  else
    alert ALERT "$log_root_result; protection recovery requires administrator action"
    exit 1
  fi
fi

# --- File integrity -------------------------------------------------------
if [ ! -f "$AGENT_PLIST" ]; then
  alert ALERT "agent plist missing: $AGENT_PLIST (tamper or broken install — reinstall required; watchdog cannot recreate policy)"
  exit 1
fi
if [ "$REQUIRE_ROOT_OWNER" = "1" ]; then
  owner="$(stat -f %u "$AGENT_PLIST")"
  if [ "$owner" != "0" ]; then
    alert ALERT "agent plist not root-owned (uid $owner): $AGENT_PLIST — a non-admin could have edited policy"
    failed=1
  fi
fi

# The production plist execs through agent-launch.sh (per-uid logs, B6);
# a missing or non-root wrapper is the same class of tamper as the plist.
if [ "$REQUIRE_ROOT_OWNER" = "1" ]; then
  WRAPPER="/Library/Application Support/SentryScreen/agent-launch.sh"
  if [ ! -f "$WRAPPER" ]; then
    alert ALERT "agent launch wrapper missing: $WRAPPER (reinstall required)"
    failed=1
  elif [ "$(stat -f %u "$WRAPPER")" != "0" ]; then
    alert ALERT "agent launch wrapper not root-owned: $WRAPPER — a non-admin could have edited the launch line"
    failed=1
  fi
fi

# --- Budget SUMMARY_STALE_SECS ---------------------------------------------
# `state = running` is launchd's view of the JOB, not of the process: a child's
# `kill -STOP <pid>` (SIGSTOP cannot be caught, blocked or ignored) freezes the
# daemon with the job still "running" and the pid still alive, so every check
# in this script passed while nothing on that screen was filtered. Liveness
# therefore needs a signal the daemon itself produces: its run.jsonl. The
# daemon writes one `summary` record per 60 s window and keeps writing while
# paused, suspended or idle (FrameLogger.idleTick, Logger.swift), so the file's
# mtime advances at least that often for as long as a Pipeline exists. When
# there is no Pipeline (failed model load, capture restart) there is no idle
# tick, but the process is alive and healthy; since 2026-09-07 it writes one
# `"event":"held"` record per 60 s through the same logger (HoldHeartbeat.swift,
# same cadence by receipt) so this check sees the file move. Before that fix
# every such hold produced a false "wedged" ALERT and a restart ~600 s in.
# mtime only, no record parsing: any write by the live process counts.
# MEASURED 2026-09-07 on an M1 Mac's installed agent
# (/Library/Logs/SentryScreen/501/run.jsonl plus its 3 rolled generations,
# 553 summaries over 7.4 h): consecutive-summary gap p50 60 s, p95 120 s,
# max 120 s, zero gaps above 120 s. 600 s is 5x that worst healthy gap and 10x
# the cadence — a tripwire, not a working limit. The SIGSTOP case is caught in
# one 60 s pass by the process-state check below; this is the backstop for a
# process wedged without being stopped, and its repair costs a restart, so it
# sits far beyond every no-frames gap we can name (including a modal system
# prompt that blocks the main run loop's idle tick on a static screen, where no
# frame arrives to close the window from the detect queue instead).
SUMMARY_STALE_SECS=600

# --- Budget SILENT_RESTART_MAX (review repair 2026-09-11, critic blocker 3) --
# How many CONSECUTIVE `kickstart -k`s this script will spend on a SILENT
# daemon — one that is alive but has never written run.jsonl — before it stops
# restarting and leaves the failure standing for a parent.
#
# Why a budget at all. The silent branch below restarts unless $SETTINGS says
# the agent is waiting for a parent, and `waiting_for_parent` recognises three
# parked states. `UIOnboardingRuntime.start` returns `.waitForParent` from more
# than three, and `.waitForParent` builds no Pipeline (main.swift) so those
# processes write no run.jsonl at all. Three of them are parked on something a
# restart provably cannot fix: an unsupported host, an unhealthy installed
# component, and a future/read-only settings schema ("update required"). All
# three have `completedAt` set and `verificationPending:false`, so they reach
# the restart — and the next pass finds another silent process, forever. That
# is the churn the comment this branch replaced was written to prevent; without
# a budget the parent-facing failure window is destroyed and re-presented every
# SUMMARY_STALE_SECS, with no escalation.
#
# Why NOT simply withhold the restart for those parks: for the PERMISSION
# parks the restart IS the repair. `CGPreflightScreenCaptureAccess` is cached
# in-process (main.swift captureLossPollSecs caveat), so a parent who flips the
# Screen Recording switch out-of-band is recovered only by a fresh process. A
# budget keeps that repair and bounds the loop; classifying parks would need
# the daemon to publish its park reason somewhere root-owned, which no path
# does today.
#
# 3 is DERIVED, not measured: a restart that repairs converges on the FIRST one
# (a fresh process re-reads TCC in its own launch preflight, MEASURED as the
# exit-7 re-grant path in agent-launch.sh), so the budget only needs margin for
# a restart that lands inside a transient — a display waking, an install
# replacing the binary, the updater's own swap. 3 attempts at the 600 s budget
# is ~30 minutes of trying. Past it the counter stops the restarts and says so
# by name; the ALERT keeps firing per new process start, so the state stays
# visible. Reset to 0 the moment the daemon writes its log again, so a Mac that
# recovers gets the full budget back.
SILENT_RESTART_MAX=3

# max(kern.waketime, kern.boottime) as unix seconds; empty when neither parses,
# which skips the freshness check rather than guessing. `sysctl -n` prints
# `{ sec = 1788457963, usec = 922294 } <date>` (MEASURED 2026-09-07, macOS 26
# on an M1 Mac), and kern.waketime is `sec = 0` until the Mac has slept once —
# hence max() of the two, not a choice between them. A guard, not decoration:
# a sleeping Mac writes no summaries, so without it every wake from a sleep
# longer than the budget would kickstart a perfectly healthy agent.
awake_since() {
  local w b out=0
  w="$(sysctl -n kern.waketime 2>/dev/null | sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')"
  b="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')"
  case "${w:-}" in ''|*[!0-9]*) ;; *) [ "$w" -gt "$out" ] && out="$w" ;; esac
  case "${b:-}" in ''|*[!0-9]*) ;; *) [ "$b" -gt "$out" ] && out="$b" ;; esac
  [ "$out" -gt 0 ] && printf '%s\n' "$out"
}
# The pids ps reports as stopped. BSD `ps -o stat=` puts the state character
# first and pads on the right, so a leading T is the whole test.
stopped_pids() {  # pid...
  local p out=""
  for p in "$@"; do
    case "$(ps -o stat= -p "$p" 2>/dev/null)" in T*) out="$out $p" ;; esac
  done
  printf '%s' "$out"
}
# Newest process start among a job's pids, unix seconds; empty when none
# parses. `ps -o lstart=` prints `Mon Sep  7 16:03:59 2026` (MEASURED
# 2026-09-07) with trailing padding that `date -j -f` warns about, so it is
# trimmed before parsing.
newest_start() {  # pid...
  local p s out=0
  for p in "$@"; do
    s="$(ps -o lstart= -p "$p" 2>/dev/null | sed 's/[[:space:]]*$//')"
    [ -n "$s" ] || continue
    s="$(date -j -f '%a %b %e %T %Y' "$s" +%s 2>/dev/null)" || continue
    case "$s" in ''|*[!0-9]*) continue ;; esac
    [ "$s" -gt "$out" ] && out="$s"
  done
  [ "$out" -gt 0 ] && printf '%s\n' "$out"
}
# --- Budget CPU_FROZEN_SECS (2026-09-30) ----------------
# run.jsonl is written, and its directory owned, by the PROTECTED account, so
# its mtime is a signal the child can forge: `touch run.jsonl` in a loop keeps
# the SUMMARY_STALE_SECS check below green over a daemon that is wedged (the silent-process
# check's admitted residual). The daemon runs as that same uid, so no file it can write
# is out of the child's reach either. What the child CANNOT write is the kernel's
# accounting: a process's accumulated CPU time (`ps -o time=`) advances only when
# that process runs, and root reads it. A live daemon always runs a little (its
# 1 Hz pause tick, the WindowTracker poll, the 60 s summary or hold heartbeat); a
# wedged one does not.
# MEASURED 2026-09-30 on a test Mac's installed agent
# (/Library/Logs/SentryScreen/501/run.jsonl, 957 summary windows: 885 active,
# 72 idle): `cpuPct` never fell below 0.7 in any window, active or idle, i.e.
# >= 0.42 s of CPU per 60 s window, >= 4.2 s per 600 s, against `ps` resolution
# of 0.01 s. That log was since replaced by an agent restart and not archived.
# Re-measured on its successor, archived on a test Mac as
# ~/dev/transfer/wp3a-receipt-run.jsonl (sha256 f945502a...8cc8106c,
# 2026-09-30T10:35Z..14:00Z, 206 summary windows, all active, no idle window in
# it): `cpuPct` min 1.3 across the 205 windows that carry it (the first window
# after start has none). So 600 s with NO advance in the summed CPU time of the job pid and
# its children is beyond every healthy state we can name — a tripwire like SUMMARY_STALE_SECS (its equal, so the two
# repairs cost the same wait), not a working limit. Judged only on a pass whose
# log mtime looks FRESH: a stale mtime is already caught by the branch above it.
# No restart loop: this branch is reached only when run.jsonl was written within
# the last SUMMARY_STALE_SECS and after the process started, and a daemon cannot
# write a record without using CPU, so a healthy one never gets here; a forged log
# does, once, and the restarted process runs (its CPU advances, the stamp resets).
# Honest limits: this proves the daemon is not running, not that it is filtering
# correctly (a live daemon with a broken detector is the app's own DetectDeadline
# / DetectorWatch); a child cannot add CPU time to the daemon, but it
# can make it busy by other means (a same-uid process it does not own is out of
# scope of this script).
CPU_FROZEN_SECS=600
# Sum of accumulated CPU time of the given pids, in centiseconds; empty when
# none parses. macOS `ps -o time=` prints `M:SS.cc`, `H:MM:SS` or `D-HH:MM:SS`
# (minutes are not wrapped at 60); MEASURED 2026-09-30 `45:16.95` on a test Mac.
cpu_centis() {  # pid...
  local p t out sum=0 got=0
  for p in "$@"; do
    t="$(ps -o time= -p "$p" 2>/dev/null | tr -d ' ')"
    [ -n "$t" ] || continue
    out="$(printf '%s' "$t" | awk '{
      s = $0; d = 0
      if (index(s, "-")) { split(s, a, "-"); d = a[1]; s = a[2] }
      n = split(s, f, ":"); v = 0
      for (i = 1; i <= n; i++) v = v * 60 + f[i]
      printf "%d", (v + d * 86400) * 100 + 0.5 }')"
    case "$out" in ''|*[!0-9]*) continue ;; esac
    sum=$((sum + out)); got=1
  done
  [ "$got" = 1 ] && printf '%s\n' "$sum"
  return 0
}
AWAKE_SINCE="$(awake_since)"

# Is the agent legitimately waiting for a PARENT rather than wedged? Prints a
# short reason when it is, nothing when it is not (branch below).
#
# Read-only, and the only file read here is $SETTINGS — root:admin, in a 2755
# state directory (configure-install.sh), so a Standard child cannot write it.
# The three parked-by-design states, all of which build no Pipeline and so write
# no run.jsonl:
#   * no settings.json at all — nothing has ever been configured on this Mac;
#   * onboarding never completed (`completedAt` null, or no record yet): the
#     Setup window is the surface, and restarting it under the parent every
#     SUMMARY_STALE_SECS is churn, not repair;
#   * a Screen Recording handoff armed within HANDOFF_MAX_AGE — the parent is in
#     System Settings right now.
# HANDOFF_MAX_AGE is 600 s: over twice the 272 s upper bound of the 2026-08-29
# owner-attended repair episode (one episode, not a population percentile). The
# full DERIVED receipt is beside agent-launch.sh's tripwire of that name; keep
# the two equal.
HANDOFF_MAX_AGE=600
waiting_for_parent() {
  local ts started age
  [ -f "$SETTINGS" ] || { printf 'no settings.json (%s) — nothing onboarded yet' "$SETTINGS"; return 0; }
  if ! grep -q '"completedAt"' "$SETTINGS" 2>/dev/null \
    || grep -q '"completedAt" *: *null' "$SETTINGS" 2>/dev/null; then
    printf 'onboarding has no completedAt — Setup is still open'
    return 0
  fi
  grep -q '"verificationPending" *: *true' "$SETTINGS" 2>/dev/null || return 1
  ts="$(sed -n 's/.*"verificationStartedAt" *: *"\([^"]*\)".*/\1/p' "$SETTINGS" 2>/dev/null | head -1)"
  started="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${ts:-}" +%s 2>/dev/null || true)"
  case "${started:-}" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - started ))
  [ "$age" -lt "$HANDOFF_MAX_AGE" ] || return 1
  printf 'a Screen Recording handoff armed %ss ago (verificationPending, limit %ss)' \
    "$age" "$HANDOFF_MAX_AGE"
}

for uid in $UIDS; do
  repair_log_dir "$uid"
done

# --- Which login session is this (bootout reporting, E2E 2026-09-28) --------
# A job missing from a gui domain is either a child's `launchctl bootout`
# (no admin needed) or a session whose LaunchAgents have not loaded yet: a
# fresh login or boot, where launchd creates the gui domain first and loads
# /Library/LaunchAgents into it after. Both get the same re-bootstrap, but
# only the first may reach the parent's email as a tamper event. The line
# between them: this pass or an earlier one SAW the job loaded in this very
# session. Stamp <uid>.job-session holds "<boot time>:<gui domain handle>"
# from the last pass that saw it. The handle is the domain's audit session id,
# new for every login; the boot time keeps a handle reused after a restart
# from matching. Installs and uninstalls are not bootouts from here: both
# stop this watchdog before they boot the agent out (configure-install.sh
# park_watchdog, uninstall.sh). Honest limits: a bootout before the first pass
# that sees the job in a new session (<= one 60 s StartInterval after login)
# is repaired but not reported; a session whose handle or boot time cannot be
# read is never reported (named in its ALERT), because a false alarm email is
# the worse failure for a parent.
BOOT_SECS="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')"
session_key() {  # uid -> "<boot>:<handle>", or nothing when either is unreadable
  local handle
  handle="$(printf '%s\n' "$LIVE_SESSIONS" | awk -v u="$1" '$1 == u { print $2; exit }')"
  case "${BOOT_SECS:-}:${handle:-}" in
    *[!0-9:]*|:*|*:) return 0 ;;
  esac
  printf '%s:%s\n' "$BOOT_SECS" "$handle"
}

# --- Job enabled, present, and really running in every GUI session --------
for uid in $UIDS; do
  # `launchctl disable gui/<uid>/<label>` from the session's OWN account needs
  # no admin, and the disabled set belongs to launchd, not to the plist: it
  # survives a reinstall. Every bootstrap below then fails with the same error
  # once a minute forever — the missing-job repair was a no-op exactly when it
  # was needed. `enable` is the only thing that clears it, so it runs first.
  # Format MEASURED 2026-09-07 on macOS 26: `"<label>" => enabled|disabled`;
  # other releases print `true|false`, so both spellings count as disabled and
  # anything else is left alone rather than enabled on a guess.
  if launchctl print-disabled "gui/$uid" 2>/dev/null \
    | grep -Eq "\"$LABEL\" *=> *(disabled|true)"; then
    alert ALERT "agent job DISABLED in gui/$uid — re-enabling (launchctl disable needs no admin from that session and survives reinstall; every bootstrap fails until it is cleared)"
    if launchctl enable "gui/$uid/$LABEL" 2>>"$ALERTS"; then
      alert INFO "agent re-enabled in gui/$uid"
    else
      alert ALERT "re-enable FAILED for gui/$uid — parent intervention needed"
      failed=1
    fi
  fi
  # One job `launchctl print` per session per pass (the StartInterval receipt
  # in com.sentryscreen.watchdog.plist), after the one gui-domain print per
  # console row in the session selection; its text is reused below.
  key="$(session_key "$uid")"
  if ! job="$(launchctl print "gui/$uid/$LABEL" 2>/dev/null)"; then
    # Tamper only when the job was seen loaded in THIS session (receipt at
    # session_key). Recorded after the bootstrap, never before: a logout
    # also empties the domain, and that must not reach the parent as tamper.
    if [ -z "$key" ]; then
      booted_out=0
      why="session identity unreadable (boot time or gui/$uid handle), so NOT recorded as tamper"
    elif [ "$(stamp_value "$uid.job-session")" = "$key" ]; then
      booted_out=1
      why="it was loaded earlier in this session, so it was booted out (tamper: agent-disabled, unless the session is ending)"
    else
      booted_out=0
      why="not seen loaded in this session yet (login or install still loading it), so not recorded as tamper"
    fi
    alert ALERT "agent job missing from gui/$uid — re-bootstrapping; $why"
    if launchctl bootstrap "gui/$uid" "$AGENT_PLIST" 2>>"$ALERTS"; then
      alert INFO "agent re-bootstrapped into gui/$uid"
    elif ! launchctl print "gui/$uid" >/dev/null 2>&1; then
      # Logout can remove the domain after the selection above. The job has
      # no session to protect, so this is not a failed repair.
      alert INFO "gui/$uid ended during agent repair; no job to restore"
    else
      alert ALERT "re-bootstrap FAILED for gui/$uid — parent intervention needed"
      failed=1
    fi
    continue
  fi
  # Seen loaded in this session: a later missing job here is a bootout.
  # Written only when the session changes, not every pass.
  if [ -n "$key" ] && [ "$(stamp_value "$uid.job-session")" != "$key" ] \
    && ! stamp_set "$uid.job-session" "$key"; then
    alert ALERT "bootout reporting is OFF for gui/$uid until $STAMP_DIR/$uid.job-session can be written: a bootout there is still repaired but will not reach the parent's email (fix: inspect $STAMP_DIR as an administrator)"
  fi
  # Job loaded but process dead: during the staged rollout (B2/B3,
  # KeepAlive=false + 24 h config TTL) this kickstart WAS the dead-man
  # restart path. Since B4 (2026-09-01, KeepAlive=true, no TTL) launchd
  # itself relaunches the wrapper within ~10 s and this branch is the
  # backstop — it still fires if launchd is throttling a fast-failing job.
  # Dev mode skips it because the dev agent is RunAtLoad=false and idles
  # by design — which also means dev mode structurally cannot exercise
  # this branch; it is verified only on the system install.
  # Deliberate consequence: ANY dead agent is resurrected within 60 s,
  # including one an owner killed by hand — the tamper model cannot tell
  # an owner's pkill from a child's. (Panic hotkey does NOT exit the
  # process, so panic is unaffected.) For owner testing, stop the
  # watchdog first: launchctl bootout system/com.sentryscreen.watchdog.
  if [ "${SENTRY_WATCHDOG_DEV:-0}" != "1" ]; then
    if ! printf '%s\n' "$job" | grep -q "state = running"; then
      alert INFO "agent loaded but not running in gui/$uid — kickstarting"
      if ! launchctl kickstart "gui/$uid/$LABEL" 2>>"$ALERTS"; then
        alert ALERT "kickstart FAILED for gui/$uid"
        failed=1
      fi
    fi
  fi

  # --- Frozen agent: a stopped process, or a log that stopped advancing ----
  # The job pid is the launch wrapper (agent-launch.sh) and the daemon is its
  # child, so a `kill -STOP` aimed at the daemon alone is invisible at the job
  # pid: check the job pid AND its direct children (daemon + log capper).
  # Repair is SIGCONT first — surgical: no restart, no re-grant, no dropped
  # capture stream — and `kickstart -k` only if the process is still stopped,
  # which SIGKILL reaches even then (that is why the escalation can work at
  # all). No pid in the print means the job is loaded but not running, which
  # the branch above owns; dev mode idles in exactly that state.
  pid="$(printf '%s\n' "$job" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
  case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
  pids="$pid $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
  # shellcheck disable=SC2086  # word splitting IS the argument list here
  stopped="$(stopped_pids $pids)"
  if [ -n "$stopped" ]; then
    alert ALERT "agent process STOPPED in gui/$uid: pid(s)$stopped — the job still reports running so launchd will never relaunch it and nothing is being filtered; sending SIGCONT"
    # shellcheck disable=SC2086
    kill -CONT $stopped 2>>"$ALERTS"
    # shellcheck disable=SC2086
    still="$(stopped_pids $stopped)"
    if [ -n "$still" ]; then
      alert ALERT "agent still stopped after SIGCONT in gui/$uid: pid(s)$still — kickstarting with -k (SIGKILL is delivered to a stopped process)"
      if launchctl kickstart -k "gui/$uid/$LABEL" 2>>"$ALERTS"; then
        alert INFO "agent restarted in gui/$uid"
      else
        alert ALERT "kickstart -k FAILED for gui/$uid — parent intervention needed"
        failed=1
      fi
    else
      alert INFO "agent resumed in gui/$uid (pid(s)$stopped)"
    fi
    continue  # its state just changed; judge the log on the next pass
  fi

  # CPU-time ledger (budget CPU_FROZEN_SECS above), updated on EVERY pass that
  # reaches here so the interval is measured from the last observed advance.
  # Stamp "<process start> <cpu centiseconds> <unix time of last advance>".
  # shellcheck disable=SC2086  # word splitting IS the argument list here
  cpu_now="$(cpu_centis $pids)"
  # shellcheck disable=SC2086
  cpu_started="$(newest_start $pids)"
  cpu_frozen_for=0
  if [ -n "$cpu_now" ] && [ -n "$cpu_started" ]; then
    now_cpu="$(date +%s)"
    read -r c_start c_cpu c_since <<CPUSTAMP
$(stamp_value "$uid.cpu")
CPUSTAMP
    case "${c_cpu:-}:${c_since:-}" in *[!0-9:]*|:*|*:) c_cpu=""; c_since="" ;; esac
    if [ "${c_start:-}" != "$cpu_started" ] || [ -z "${c_cpu:-}" ] || [ "$cpu_now" -gt "$c_cpu" ]; then
      stamp_set "$uid.cpu" "$cpu_started $cpu_now $now_cpu" || true
    else
      # A Mac that slept did not run its daemon either: count from the later
      # of the last advance and the last wake (`AWAKE_SINCE`).
      since="$c_since"
      [ -z "$AWAKE_SINCE" ] || [ "$AWAKE_SINCE" -le "$since" ] || since="$AWAKE_SINCE"
      [ -n "$AWAKE_SINCE" ] && cpu_frozen_for=$((now_cpu - since))
    fi
    stamp_changed "$uid.cpu-read" ok || true
  else
    # No usable CPU time (or start time) for pids that are alive: the check
    # above cannot run, so say so once per change instead of skipping it
    # silently on every pass. No kickstart: an unreadable counter is not
    # evidence of a wedge.
    # shellcheck disable=SC2086,SC2116  # word splitting normalizes the list
    cpu_pids="$(echo $pids)"
    if stamp_changed "$uid.cpu-read" "unreadable $cpu_pids"; then
      alert ALERT "budget CPU_FROZEN_SECS, limit ${CPU_FROZEN_SECS} s, not checked for gui/$uid: cpu time unreadable for pid(s) $cpu_pids (ps -o time='${cpu_now}', ps -o lstart= newest='${cpu_started}') — a forged run.jsonl would go unnoticed while this lasts (fix: packaging/watchdog.sh cpu_centis/newest_start)"
    fi
  fi

  # Log freshness (budget SUMMARY_STALE_SECS above). mtime only — never the
  # file's CONTENT and never through a symlink: $LOG_ROOT/<uid>/ is created and
  # owned by the CHILD's account while this script runs as root, so the rule
  # the RELAUNCH_BURST reader carries applies here too, and anything that is
  # not a regular file owned by that uid is reported as tamper and not used.
  # mtime is the conservative reading of the summary cadence: every summary is
  # a write, so a file unwritten for the budget has certainly had no summary.
  # A child who can write that directory can `touch` run.jsonl, so mtime alone
  # never proves life: the CPU-time check at the end of this pass (budget
  # CPU_FROZEN_SECS) reads a counter the child cannot write. The
  # stopped-process check above does not depend on the log either.
  [ -n "$AWAKE_SINCE" ] || continue
  now="$(date +%s)"
  [ "$((now - AWAKE_SINCE))" -ge "$SUMMARY_STALE_SECS" ] || continue
  runlog="$LOG_ROOT/$uid/run.jsonl"
  # shellcheck disable=SC2086  # word splitting IS the argument list here
  started="$(newest_start $pids)"
  [ -n "$started" ] || continue
  life="$((now - started))"
  # mtime stays empty when there is no run.jsonl at all — the silent-process check
  # below owns that case, which used to `continue` here.
  mtime=""
  if [ -e "$runlog" ] || [ -L "$runlog" ]; then
    if [ -L "$runlog" ] || [ ! -f "$runlog" ] \
      || [ "$(stat -f %u "$runlog" 2>/dev/null || echo '?')" != "$uid" ]; then
      alert ALERT "$runlog is not a regular file owned by uid $uid (symlink, other type, or another owner) — freshness not judged; only the agent writes that name (fix: inspect and remove it as an administrator)"
      failed=1
      continue
    fi
    mtime="$(stat -f %m "$runlog" 2>/dev/null)" || continue
  fi
  # --- A SILENT process (2026-09-11, CONFIRMED) ------
  # Until this date the line here was `[ "$mtime" -ge "$started" ] || continue`:
  # any daemon that started and NEVER wrote a summary was exempt from the
  # freshness budget forever. That is not a corner — it is the shape of every
  # blinded daemon: capture wedged before the first frame, or the
  # environment attack. Result: "running", zero frames filtered, no repair and
  # NO ALERT.
  # NOT in that list (corrected 2026-09-11, review repair): the launch
  # display-wait park. `Pipeline.start` writes `screen` and then `capture
  # state=waiting` every displayWaitLogEvery polls (~60 s, main.swift), so a
  # display-less launch keeps run.jsonl fresh and is caught by neither branch —
  # correctly, since a Mac with every display asleep is not blinded.
  # The exemption existed for a real reason — a daemon parked in
  # onboarding or permission repair (UIOnboardingRuntime.waitForParent) builds
  # no Pipeline and therefore no FrameLogger, so its run.jsonl belongs to the
  # previous process, and restarting it every budget would kill the app under
  # a parent who is mid-re-grant. So the two cases are now SEPARATED:
  #   * the ALERT fires either way, once per observed process start (stamped,
  #     like the wrapper markers) — an unprotected session must be visible;
  #   * the `kickstart -k` is withheld while $SETTINGS says the daemon is
  #     waiting for a parent (that file is root:admin with a 2755 state dir, so
  #     unlike run.jsonl the child cannot forge it), and bounded by
  #     SILENT_RESTART_MAX when it is not.
  #
  # ADDED 2026-09-11 (review repair, critic blocker 1): "no write since its
  # start" and "no file at all" are the SAME observation, and the second is the
  # cheaper one for a child to produce. `/Library/Logs/SentryScreen/<uid>/` is
  # owned by the protected account, so `rm run.jsonl` unlinks the path while the
  # daemon keeps writing to the unlinked inode and never recreates it (the
  # logger opens the file once per process). The old
  # `[ -e "$runlog" ] || continue` skipped the WHOLE freshness section for the
  # life of that process, with zero ALERT — one `rm`, no loop to keep running,
  # and strictly quieter than the `touch` limit this receipt already admits.
  # A missing file is normal in exactly one case, a Mac that has never been
  # onboarded, and `waiting_for_parent` already answers that one by name (no
  # settings.json ⇒ ALERT, no restart).
  #
  # A child who owns $LOG_ROOT/<uid> can still `touch` run.jsonl to keep mtime
  # moving and hide a freeze from the age check below. A root-owned heartbeat is
  # impossible (the daemon runs as the session uid, so anything it writes the
  # child can write); the residual is closed instead by the CPU-time ledger
  # (budget CPU_FROZEN_SECS), which the branch after this one applies.
  if [ -z "$mtime" ] || [ "$mtime" -lt "$started" ]; then
    [ "$life" -ge "$SUMMARY_STALE_SECS" ] || continue
    if [ -z "$mtime" ]; then
      observed="${life} s of process life with NO $runlog at all (observed=missing; the file was removed or never created)"
    else
      observed="${life} s of process life with NO write to $runlog since this process started"
    fi
    parked="$(waiting_for_parent)"
    if stamp_changed "$uid.silent" "$started"; then
      alert ALERT "budget SUMMARY_STALE_SECS, limit ${SUMMARY_STALE_SECS} s, observed $observed (job running, pid $pid alive and not stopped) — the daemon has never produced a log record, so nothing is being filtered in gui/$uid (fix: packaging/watchdog.sh SUMMARY_STALE_SECS)"
    fi
    if [ -n "$parked" ]; then
      # No restart: the app is showing a parent something.
      if stamp_changed "$uid.silent-parked" "$started" ; then
        alert INFO "gui/$uid not restarted: $SETTINGS says $parked, so the agent is waiting for a parent (onboarding or permission repair), which writes no run.jsonl by construction"
      fi
      continue
    fi
    # Budget SILENT_RESTART_MAX (receipt at the constant): consecutive restarts
    # spent on a daemon that keeps coming back silent. Reset below the moment it
    # writes its log again.
    spent="$(stamp_value "$uid.silent-restarts")"
    case "$spent" in ''|*[!0-9]*) spent=0 ;; esac
    if [ "$spent" -ge "$SILENT_RESTART_MAX" ]; then
      if stamp_changed "$uid.silent-budget" "$spent"; then
        alert ALERT "budget SILENT_RESTART_MAX, limit ${SILENT_RESTART_MAX} consecutive restarts, observed ${spent} — NOT restarting gui/$uid again: every restart came back silent, so this is a park a restart cannot repair (an unsupported host, an unhealthy installed component, or an update-required settings schema — the daemon's own surfaces name which) and further kickstarts would destroy the failure window a parent has to read. That session is UNPROTECTED until a human acts (fix: packaging/watchdog.sh SILENT_RESTART_MAX; clear with rm '$STAMP_DIR/$uid.silent-restarts')"
      fi
      continue
    fi
    alert ALERT "restarting gui/$uid with kickstart -k (silent daemon, nothing in $SETTINGS says it is waiting for a parent; attempt $((spent + 1)) of budget SILENT_RESTART_MAX=$SILENT_RESTART_MAX)"
    stamp_set "$uid.silent-restarts" "$((spent + 1))" || true
    if launchctl kickstart -k "gui/$uid/$LABEL" 2>>"$ALERTS"; then
      alert INFO "agent restarted in gui/$uid after a silent start"
    else
      alert ALERT "kickstart -k FAILED for gui/$uid — parent intervention needed"
      failed=1
    fi
    continue
  fi
  # The daemon has written since it started: the silent-restart budget counts
  # CONSECUTIVE failures, so a working daemon gives it all back. Recovery is an
  # event a parent should see once, not silently (this script's header rule).
  spent="$(stamp_value "$uid.silent-restarts")"
  if [ "$spent" != none ] && [ "$spent" != 0 ]; then
    stamp_set "$uid.silent-restarts" 0 || true
    stamp_set "$uid.silent-budget" none || true
    alert INFO "gui/$uid is writing $runlog again — budget SILENT_RESTART_MAX reset to 0 (was $spent of $SILENT_RESTART_MAX)"
  fi
  age="$((now - mtime))"
  if [ "$age" -ge "$SUMMARY_STALE_SECS" ]; then
    alert ALERT "budget SUMMARY_STALE_SECS, limit ${SUMMARY_STALE_SECS} s, observed ${age} s since $runlog was last written (job running, pid $pid alive and not stopped) — agent wedged, restarting with kickstart -k (fix: packaging/watchdog.sh SUMMARY_STALE_SECS)"
    if launchctl kickstart -k "gui/$uid/$LABEL" 2>>"$ALERTS"; then
      alert INFO "agent restarted in gui/$uid after a stalled log"
    else
      alert ALERT "kickstart -k FAILED for gui/$uid — parent intervention needed"
      failed=1
    fi
  elif [ "$cpu_frozen_for" -ge "$CPU_FROZEN_SECS" ]; then
    # A fresh-looking log over a process that has not run: the log is a file the
    # protected account can touch, the CPU counter is not.
    alert ALERT "budget CPU_FROZEN_SECS, limit ${CPU_FROZEN_SECS} s, observed ${cpu_frozen_for} s with no CPU time used by the agent (job running, pid $pid alive and not stopped) while $runlog looks fresh (${age} s old) — the log is forgeable by the protected account, so it is not trusted; agent wedged, restarting with kickstart -k (fix: packaging/watchdog.sh CPU_FROZEN_SECS)"
    if launchctl kickstart -k "gui/$uid/$LABEL" 2>>"$ALERTS"; then
      alert INFO "agent restarted in gui/$uid after a frozen CPU counter"
    else
      alert ALERT "kickstart -k FAILED for gui/$uid — parent intervention needed"
      failed=1
    fi
  fi
done

# --- Wrapper markers (agent-launch.sh) --------------------------------------
# Two things the wrapper can only say in agent.err, which nothing tails, so it
# leaves a marker in its per-uid log dir and this script turns it into a
# parent-visible line: a RELAUNCH_BURST trip, and (since 2026-09-11, review
# repair) an ENV_SCRUB drop — an ambient SENTRY_*/DYLD_* variable the wrapper
# removed before exec, which is what an environment attack looks like from here.
# The wrapper's burst tripwire writes $LOG_ROOT/<uid>/RELAUNCH_BURST.tripped
# and exits 1; the NEXT wrapper launchd starts (~10 s) moves it to
# .tripped.last and launches the daemon anyway. Since 2026-09-11 the marker
# never suppresses a launch (it lives in the protected account's own
# directory, so gating on it was a child-operated off switch) — it is the
# evidence this ALERT is built on, nothing more. Until 2026-09-02 both events
# reached only agent.err, which nothing tails (the wrapper header named this
# follow-up). Report each ONCE: this script is one-shot on a 60 s
# interval, so "once" needs state — a stamp per (uid, marker) under STAMP_DIR
# holding the marker's mtime as text. A marker whose mtime differs from the
# stamp is a new trip (the wrapper rewrites the file on every trip; `mv -f`
# preserves the mtime into .tripped.last, so the expiry stamp keys the same
# way). Not a repair and not a failure: `failed` is untouched — the wrapper
# owns the recovery, this is the parent-visible line it lacked. Dev mode has
# no wrapper, so the loop finds nothing there.
#
# Threat model (adversarial review 2026-09-02, blocker): $LOG_ROOT/<uid>/ is
# created and owned by the CHILD's account (the wrapper runs as the user), this
# script runs as root, and alerts.log is world-readable by contract. The first
# version did `head -1` on the marker and `touch -r` onto a stamp beside it —
# a Standard child could symlink RELAUNCH_BURST.tripped at state/parent/pin.json
# and read the PIN verifier back out of alerts.log 200 bytes per pass, or move
# any root file's mtime through a symlinked stamp (both reproduced in dev
# mode). So nothing here follows a path the child controls:
#   1. the marker's CONTENT is never read — the alert carries the uid and the
#      trip time from lstat only; the wrapper's count stays in agent.err;
#   2. the marker must be a regular file (not a symlink: BSD stat(1) is lstat
#      unless -L, `-L` is tested first, `-f` alone would follow) owned by that
#      uid — anything else is reported as tamper, once, and not used;
#   3. stamps live in STAMP_DIR beside alerts.log — root-owned 0755 on the
#      installed Mac (MEASURED 2026-09-02, /Library/Application Support/
#      SentryScreen root:wheel drwxr-xr-x) — so the child cannot pre-place one,
#      and a stamp that is a symlink anyway is refused, not written through.
# uninstall.sh removes STAMP_DIR with the support dir (keep-state too: it is
# not under state/).
# The ENV_SCRUB marker is the same shape and carries the same caveat one step
# further: it is WRITTEN by the wrapper as the protected account, so a child can
# forge it and cause a false ALERT. That is noise, not a hole (the burst marker
# has had the same property since 2026-09-02), it is bounded by the stamp — one
# line per mtime change — and by ALERTS_CAP, and the alternative is the silence
# this script's header rule forbids.
report_wrapper_marker() {  # uid file tripped|expired|env-scrub
  local uid="$1" f="$2" kind="$3" stamp have want owner when
  stamp="$STAMP_DIR/$uid.$(basename "$f")"
  [ -e "$f" ] || [ -L "$f" ] || return 0
  # lstat, never stat: a symlink reports its own mtime and owner.
  have="$(stat -f %m "$f" 2>/dev/null)" || return 0
  owner="$(stat -f %u "$f" 2>/dev/null || echo '?')"
  if [ -L "$f" ] || [ ! -f "$f" ] || [ "$owner" != "$uid" ]; then
    have="tamper:$have:$owner"
  fi
  want="$(cat "$stamp" 2>/dev/null || echo none)"
  [ "$have" != "$want" ] || return 0
  case "$have" in
    tamper:*)
      alert ALERT "wrapper marker $f is not a regular file owned by uid $uid (symlink, other type, or owner $owner) — not read; only the wrapper writes that name (fix: inspect and remove it as an administrator)"
      ;;
    *)
      when="$(date -u -r "$have" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "epoch $have")"
      case "$kind" in
        tripped)
          alert ALERT "RELAUNCH_BURST tripped in gui/$uid at $when — the daemon relaunched more than the budget allows, so that wrapper exited 1 and launchd started a fresh one (the exits and the wrapper's count are in $LOG_ROOT/$uid/agent.err; budget: agent-launch.sh RELAUNCH_BURST)"
          ;;
        expired)
          alert INFO "RELAUNCH_BURST trip cleared in gui/$uid — a later wrapper moved the marker aside and launched (trip was at $when)"
          ;;
        env-scrub)
          alert ALERT "ENV_SCRUB dropped ambient environment variables before launching the agent in gui/$uid at $when — a SENTRY_*/DYLD_* variable was set in that gui domain (launchctl setenv needs no administrator there), which is the shape of a state-root attack. NONE of them reached the daemon (env -i, and a production daemon honours no SENTRY_* knob), so protection was not affected; the NAMES are in $LOG_ROOT/$uid/agent.err, never the values (fix: find what sets them and launchctl unsetenv <name>; tripwire: agent-launch.sh ENV_SCRUB)"
          ;;
      esac
      ;;
  esac
  mkdir -p "$STAMP_DIR" 2>/dev/null
  if [ -L "$stamp" ] || ! printf '%s\n' "$have" >"$stamp" 2>/dev/null; then
    alert ALERT "wrapper marker report stamp $stamp could not be written (symlink or unwritable) — this line will repeat every pass until it can be"
  fi
}
for uid in $UIDS; do
  report_wrapper_marker "$uid" "$LOG_ROOT/$uid/RELAUNCH_BURST.tripped" tripped
  report_wrapper_marker "$uid" "$LOG_ROOT/$uid/RELAUNCH_BURST.tripped.last" expired
  report_wrapper_marker "$uid" "$LOG_ROOT/$uid/ENV_SCRUB.dropped" env-scrub
done
exit "$failed"
