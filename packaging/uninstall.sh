#!/bin/bash
# Full removal (B2; SPEC §8.3 required this verified before KeepAlive turned
# on — live 2026-08-29 fi-keep-02, KeepAlive=true since B4 2026-09-01; a
# booted-out job is not resurrected by KeepAlive). Admin-gated. Logs may contain sensitive
# detection records — deleted, never preserved.
set -uo pipefail
# the installed copy ignores the development and test
# overrides this script reads. Only a copy run from elsewhere (the repo tree,
# the lifecycle tests' isolated payload) honours them, so an environment a
# user can set (launchctl setenv) never reaches the installed script.
case "$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" in
  "/Library/Application Support/SentryScreen" | "") unset SENTRY_INSTALL_ROOT SENTRY_SKIP_LAUNCHD ;;
esac
[ "$(id -u)" = "0" ] || { echo "run with sudo" >&2; exit 77; }

# Settings always passes --reset-permissions. Omitting it is an explicit
# command-line maintenance route, which prints the remaining grant and remedy.
# Any other argument must fail before anything is touched.
RESET_PERMISSIONS=0
for arg in "$@"; do
  case "$arg" in
    --reset-permissions) RESET_PERMISSIONS=1 ;;
    *)
      printf 'ERROR: argument configured=--reset-permissions-or-none observed=%q remediation=sudo-packaging/uninstall.sh-[--reset-permissions]\n' \
        "$arg" >&2
      exit 64
      ;;
  esac
done
# TCC keys the grant to the bundle identifier (packaging/Info.plist
# CFBundleIdentifier; changing it orphans every grant). The installed
# Info.plist is the receipt for the id actually granted, so it is read before
# removal and must agree with this constant — a mismatch means the payload is
# not the one this script knows, and resetting either id blind is wrong. No
# plist at all (payload already gone, e.g. a rerun after a partial removal) is
# the same blind reset and is refused too (review 2026-09-02: the first
# version skipped the check and reset the constant with exit 0).
BUNDLE_ID=com.sentryscreen.agent

# Resolve the settings decision before launchd changes or file removal. An
# invalid non-interactive value must fail closed while the installation is
# still intact. Omitting the variable keeps the existing interactive behavior
# when settings exist; without settings, removal is the only applicable path.
requested_root="${SENTRY_INSTALL_ROOT:-}"
skip_launchd="${SENTRY_SKIP_LAUNCHD:-0}"
case "$skip_launchd" in
  0|1) ;;
  *)
    printf 'ERROR: SENTRY_SKIP_LAUNCHD configured=0|1 observed=%q remediation=set-SENTRY_SKIP_LAUNCHD=1-only-with-an-isolated-root\n' \
      "$skip_launchd" >&2
    exit 64
    ;;
esac
install_root=''
if [ -n "$requested_root" ]; then
  case "$requested_root" in
    /*) ;;
    *)
      printf 'ERROR: SENTRY_INSTALL_ROOT configured=absolute-non-root-path observed=%q remediation=use-an-existing-isolated-root\n' \
        "$requested_root" >&2
      exit 64
      ;;
  esac
  if ! install_root=$(cd "$requested_root" 2>/dev/null && pwd -P); then
    printf 'ERROR: SENTRY_INSTALL_ROOT configured=existing-directory observed=%q remediation=create-the-isolated-root-before-uninstall\n' \
      "$requested_root" >&2
    exit 64
  fi
  if [ "$install_root" = / ] || [ "$skip_launchd" != 1 ]; then
    printf 'ERROR: isolated-uninstall configured=non-root-path+SENTRY_SKIP_LAUNCHD=1 observed=root=%q,skip=%q remediation=use-a-non-root-fixture-and-set-SENTRY_SKIP_LAUNCHD=1\n' \
      "$install_root" "$skip_launchd" >&2
    exit 64
  fi
elif [ "$skip_launchd" != 0 ]; then
  printf 'ERROR: live-uninstall configured=SENTRY_SKIP_LAUNCHD=0 observed=%q remediation=unset-SENTRY_SKIP_LAUNCHD\n' \
    "$skip_launchd" >&2
  exit 64
fi
SUPPORT="$install_root/Library/Application Support/SentryScreen"
STATE="$SUPPORT/state"
SETTINGS="$SUPPORT/state/settings.json"
PARENT_PIN="$SUPPORT/state/parent/pin.json"
AGENT_PLIST="$install_root/Library/LaunchAgents/com.sentryscreen.agent.plist"
WATCHDOG_PLIST="$install_root/Library/LaunchDaemons/com.sentryscreen.watchdog.plist"
LOG_ROOT="$install_root/Library/Logs/SentryScreen"
INFO_PLIST="$SUPPORT/SentryScreen.app/Contents/Info.plist"

if [ "$RESET_PERMISSIONS" = 1 ]; then
  # Fail closed while the installation is intact: id mismatch, no tccutil,
  # or an isolated root pointed at the real tool.
  if [ ! -f "$INFO_PLIST" ]; then
    printf 'ERROR: reset-permissions configured=installed-Info.plist-names-the-granted-id observed=missing path=%q remediation=remove-without---reset-permissions-then-tccutil-reset-ScreenCapture-<id>-by-hand-for-the-id-System-Settings-lists\n' \
      "$INFO_PLIST" >&2
    exit 64
  fi
  installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null) \
    || installed_id=unreadable
  if [ "$installed_id" != "$BUNDLE_ID" ]; then
    printf 'ERROR: reset-permissions configured=CFBundleIdentifier=%s observed=%q path=%q remediation=remove-without---reset-permissions-then-tccutil-reset-ScreenCapture-<id-from-that-plist>-by-hand\n' \
      "$BUNDLE_ID" "$installed_id" "$INFO_PLIST" >&2
    exit 64
  fi
  # `tccutil` is resolved through PATH like `launchctl`, so the isolated
  # lifecycle test can stand in a recorder. The TCC database is NOT under an
  # isolated root, so an isolated run that would reach the REAL tool is
  # refused: it would reset the grant of whatever is installed on this Mac.
  tccutil_path=$(command -v tccutil || true)
  if [ -z "$tccutil_path" ]; then
    echo 'ERROR: reset-permissions configured=tccutil-on-PATH observed=missing remediation=run-from-a-standard-macOS-shell' >&2
    exit 64
  fi
  if [ "$skip_launchd" = 1 ] && [ "$tccutil_path" = /usr/bin/tccutil ]; then
    printf 'ERROR: reset-permissions configured=isolated-root-never-runs-/usr/bin/tccutil observed=%q remediation=drop---reset-permissions-for-isolated-roots-or-put-a-recorder-tccutil-on-PATH\n' \
      "$tccutil_path" >&2
    exit 64
  fi
fi
keep=''
if [ "${SENTRY_KEEP_SETTINGS+x}" = x ]; then
  keep="$SENTRY_KEEP_SETTINGS"
  case "$keep" in
    yes|no) ;;
    *)
      printf 'ERROR: SENTRY_KEEP_SETTINGS configured=yes|no observed=%q remediation=set SENTRY_KEEP_SETTINGS=yes or SENTRY_KEEP_SETTINGS=no\n' \
        "$keep" >&2
      exit 64
      ;;
  esac
fi
if [ "$keep" = yes ] && { [ ! -f "$SETTINGS" ] || [ ! -f "$PARENT_PIN" ]; }; then
  printf 'ERROR: SENTRY_KEEP_SETTINGS configured=yes observed=parent-state-incomplete remediation=set-SENTRY_KEEP_SETTINGS=no-or-restore-state-path=%q\n' \
    "$STATE" >&2
  exit 64
fi
if { [ -f "$SETTINGS" ] || [ -f "$PARENT_PIN" ]; } && [ -z "$keep" ]; then
  ans=''
  read -r -p "Delete parent PIN and shared protection settings? [y/N] " ans
  case "$ans" in y|Y|yes|YES) keep=no ;; *) keep=yes ;; esac
elif [ -z "$keep" ]; then
  keep=no
fi

# Inventory local accounts, not only `who`'s current console user. Fast user
# switching can leave several GUI domains loaded. An isolated fixture instead
# inventories only its own Users directory and never reads real home paths.
user_uids=()
user_homes=()
if [ -n "$install_root" ]; then
  if [ -d "$install_root/Users" ]; then
    while IFS= read -r fixture_home; do
      user_uids+=("fixture")
      user_homes+=("$fixture_home")
    done < <(find "$install_root/Users" -mindepth 1 -maxdepth 1 -type d -print)
  fi
else
  if ! user_records=$(dscl . -list /Users UniqueID); then
    echo 'ERROR: account-inventory observed=directory-service-failed remediation=restore-directory-service-and-retry-removal' >&2
    exit 1
  fi
  while read -r account uid; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    { [ "$uid" -ge 500 ] || [ "$account" = Guest ]; } && [ "$uid" -lt 65534 ] || continue
    if ! home_record=$(dscl . -read "/Users/$account" NFSHomeDirectory); then
      echo "ERROR: account-home uid=$uid observed=directory-service-failed remediation=repair-account-home-and-retry-removal" >&2
      exit 1
    fi
    home_path="${home_record#NFSHomeDirectory: }"
    case "$home_path" in
      /|/var/empty|/Library|/System|/Users|''|*[[:cntrl:]]*)
        echo "ERROR: account-home uid=$uid observed=unsafe-path remediation=repair-account-home-and-retry-removal" >&2; exit 1 ;;
      /*) ;;
      *) echo "ERROR: account-home uid=$uid observed=not-absolute remediation=repair-account-home-and-retry-removal" >&2; exit 1 ;;
    esac
    user_uids+=("$uid")
    user_homes+=("$home_path")
  done <<< "$user_records"
fi

native_uninstaller="$SUPPORT/SentryScreen.app/Contents/Helpers/SentryScreen Uninstaller.app/Contents/MacOS/sentry-screen"

# Record launchd-owned PIDs, boot out each exact job, then verify both the job
# and its recorded PID are gone. A process name or command line is not an
# ownership Receipt and must never be used as a kill target.
#
# Bootout, then VERIFY each job is actually gone — an uninstall that
# reports success while the agent keeps running off deleted files is the
# worst outcome this script can produce, and SPEC §8.3 gates KeepAlive on
# this script being trustworthy. Isolated-root tests must explicitly skip this
# live interface; live uninstalls cannot skip it.
failed=0
# bootout is asynchronous: launchd sends SIGTERM, agent-launch.sh forwards it
# to the daemon and waits for the child's real exit, and only then does the
# job leave the domain. Checking immediately after bootout saw the job still
# draining and aborted the uninstall with nothing removed while the agent
# went on to exit anyway — a half-uninstalled, unprotected machine
# (MEASURED 2026-08-29, fresh-install run fi-keep-01). Poll for the job and
# its receipt-owned PID to be gone, bounded.
# BOOTOUT_WAIT 10 s receipt — ASSUMED: the daemon's shutdown is a capture
# stream stop + overlay teardown, sub-second in every log so far; 10 s is a
# tripwire, not an expectation. The observed wait is printed so healthy runs
# re-measure it for free.
BOOTOUT_WAIT=10
wait_gone() {  # label domain/label pid
  local label="$1" job="$2" pid="$3" i=0
  while [ "$i" -lt "$((BOOTOUT_WAIT * 10))" ]; do
    if ! launchctl print "$job" >/dev/null 2>&1 \
       && { [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }; then
      echo "bootout $label: gone after $((i / 10)).$((i % 10)) s"
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  echo "bootout $label: still present after ${BOOTOUT_WAIT} s (tripwire BOOTOUT_WAIT in packaging/uninstall.sh)" >&2
  return 1
}
if [ "$skip_launchd" = 0 ]; then
  watchdog_pid=$(launchctl print system/com.sentryscreen.watchdog 2>/dev/null \
    | awk '$1=="pid" && $2=="=" {print $3; exit}')
  launchctl bootout system/com.sentryscreen.watchdog 2>/dev/null
  wait_gone "watchdog" system/com.sentryscreen.watchdog "$watchdog_pid"
  if launchctl print system/com.sentryscreen.watchdog >/dev/null 2>&1; then
    echo "ERROR: watchdog job still loaded after bootout" >&2; failed=1
  fi
  if [ -n "$watchdog_pid" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
    echo "ERROR: watchdog receipt-owned PID $watchdog_pid survived bootout" >&2; failed=1
  fi
  # Legacy cleanup: the retired parent-helper root daemon from older installs.
  launchctl bootout system/com.sentryscreen.parent-helper 2>/dev/null || true
  for ((account_index=0; account_index<${#user_uids[@]}; account_index++)); do
    uid="${user_uids[$account_index]}"
    agent_pid=$(launchctl print "gui/$uid/com.sentryscreen.agent" 2>/dev/null \
      | awk '$1=="pid" && $2=="=" {print $3; exit}')
    launchctl bootout "gui/$uid/com.sentryscreen.agent" 2>/dev/null
    wait_gone "agent gui/$uid" "gui/$uid/com.sentryscreen.agent" "$agent_pid"
    if launchctl print "gui/$uid/com.sentryscreen.agent" >/dev/null 2>&1; then
      echo "ERROR: agent job still loaded in gui/$uid after bootout" >&2; failed=1
    fi
    if [ -n "$agent_pid" ] && kill -0 "$agent_pid" 2>/dev/null; then
      echo "ERROR: agent receipt-owned PID $agent_pid survived bootout in gui/$uid" >&2; failed=1
    fi
  done
fi

if [ "$failed" != "0" ]; then
  echo "nothing removed: a launchd job or receipt-owned PID survived bootout" >&2
  exit 1
fi

# A stopped launchd wrapper alone does not prove that its child is gone.
# Verify exact installed executable paths, without reading command arguments
# or killing any extra process. The separate uninstaller has a different path.
if [ "$skip_launchd" = 0 ]; then
  if ! survivor_pids=$(ps -axo pid=,comm= | awk -v app="$SUPPORT/SentryScreen.app/Contents/MacOS/sentry-screen" \
    '{pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if($0==app) print pid}'); then
    echo 'ERROR: process-verification observed=inventory-failed remediation=restore-process-inventory-and-retry-removal' >&2
    exit 1
  fi
  if [ -n "$survivor_pids" ]; then
    echo "ERROR: process-verification observed=installed-executable-survivor pids=$survivor_pids remediation=inspect-exact-survivor-before-retrying-removal" >&2
    exit 1
  fi
fi

if [ "$RESET_PERMISSIONS" = 1 ]; then
  # Apple documents root reset for all accounts and app-specific All reset.
  # Do this after stopping capture but BEFORE deleting the retryable payload.
  # Never edit TCC.db, reset another app, or infer permission from UI closure.
  if ! tccutil reset All "$BUNDLE_ID"; then
    echo 'ERROR: reset-permissions target=tccutil-reset-All-com.sentryscreen.agent observed=command-failed remediation=payload-kept;-retry-removal-after-correcting-permission-reset' >&2
    exit 1
  fi
fi

removal_failed=0
remove_target() {
  label="$1"
  shift
  if ! rm "$@"; then
    printf 'ERROR: removal target=%s observed=command-failed remediation=inspect-permissions-and-rerun-packaging/uninstall.sh\n' \
      "$label" >&2
    removal_failed=1
  fi
}
verify_absent() {
  label="$1"
  path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf 'ERROR: removal target=%s observed=path-still-present path=%q remediation=inspect-permissions-and-rerun-packaging/uninstall.sh\n' \
      "$label" "$path" >&2
    removal_failed=1
  fi
}

# Parent directories must not redirect a privileged deletion. Remove only
# known app-owned leaf paths; never follow a symlinked home/Library tree.
for ((account_index=0; account_index<${#user_homes[@]}; account_index++)); do
  home_path="${user_homes[$account_index]}"
  if [ -x "$native_uninstaller" ]; then
    if ! "$native_uninstaller" --uninstall-clean-home "$home_path"; then
      echo "ERROR: user-data uid=${user_uids[$account_index]} observed=native-removal-failed remediation=repair-account-path-and-retry-removal" >&2
      removal_failed=1
    fi
    # Only the live account inventory contains real UIDs. An isolated fixture
    # must never discover or remove caches outside its disposable install root.
    # Receipt: a post-reboot check found product Metal caches for both
    # actual accounts under confstr's DARWIN_USER_CACHE_DIR, outside ~/Library.
    if [ -z "$install_root" ] && ! "$native_uninstaller" --uninstall-clean-cache "${user_uids[$account_index]}"; then
      echo "ERROR: user-cache uid=${user_uids[$account_index]} observed=native-removal-failed remediation=repair-account-cache-and-retry-removal" >&2
      removal_failed=1
    fi
    continue
  fi
  # Legacy repair fallback only. All new payloads require the native worker.
  for relative in 'Library/Caches/SentryScreen' \
    'Library/Application Support/SentryScreen' \
    'Library/Caches/com.sentryscreen.agent' \
    'Library/Caches/com.sentryscreen.uninstaller' \
    'Library/Preferences/com.sentryscreen.agent.plist' \
    'Library/Preferences/com.sentryscreen.uninstaller.plist' \
    'Library/Saved Application State/com.sentryscreen.agent.savedState' \
    'Library/Saved Application State/com.sentryscreen.uninstaller.savedState'; do
    target="$home_path/$relative"
    parent="${target%/*}"
    safe=1
    while [ "$parent" != / ]; do
      if [ -L "$parent" ]; then safe=0; break; fi
      parent="${parent%/*}"
      [ -n "$parent" ] || parent=/
    done
    if [ "$safe" != 1 ]; then
      echo "ERROR: user-data uid=${user_uids[$account_index]} observed=symlink-parent remediation=repair-account-path-and-retry-removal" >&2
      removal_failed=1
      continue
    fi
    # Pin every directory with O_NOFOLLOW. A check followed by rm alone is
    # racy in a Standard user's writable home. fchdir anchors rm to the
    # already-open parent even if a directory name changes during removal.
    # Receipt: Darwin Fcntl O_DIRECTORY/O_NOFOLLOW, verified on the owner M1 Mac;
    # the hostile-parent regression below exercises refusal, not traversal.
    if ! /usr/bin/perl - "$target" <<'REMOVE_USER_DATA'
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_DIRECTORY O_NOFOLLOW);
use Errno qw(ENOENT);
my $target = shift;
my @parts = grep { length } split '/', $target;
my $leaf = pop @parts;
sysopen(my $directory, '/', O_RDONLY | O_DIRECTORY) or die "user-data: open root failed\n";
chdir($directory) or die "user-data: pin root failed\n";
for my $part (@parts) {
    unless (sysopen(my $next, $part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)) {
        exit 0 if $! == ENOENT;
        die "user-data: unsafe or inaccessible parent; repair account path and retry\n";
    } else {
        $directory = $next;
        chdir($directory) or die "user-data: pin parent failed\n";
    }
}
system('/bin/rm', '-rf', './' . $leaf) == 0 or die "user-data: removal failed; repair account path and retry\n";
die "user-data: leaf remains; retry removal\n" if lstat($leaf);
REMOVE_USER_DATA
    then
      echo "ERROR: user-data uid=${user_uids[$account_index]} observed=secure-removal-failed remediation=repair-account-path-and-retry-removal" >&2
      removal_failed=1
    fi
  done
done
if [ "$removal_failed" != 0 ]; then
  echo 'ERROR: uninstall incomplete; payload kept for retry.' >&2
  exit 1
fi

remove_target agent-plist -f "$AGENT_PLIST"
remove_target watchdog-plist -f "$WATCHDOG_PLIST"
# Legacy cleanup: the retired parent-helper plist (its binary goes with $SUPPORT).
remove_target legacy-helper-plist -f "$install_root/Library/LaunchDaemons/com.sentryscreen.parent-helper.plist"
verify_absent agent-plist "$AGENT_PLIST"
verify_absent watchdog-plist "$WATCHDOG_PLIST"
remove_target logs -rf "$LOG_ROOT"
verify_absent logs "$LOG_ROOT"
if [ "$removal_failed" != 0 ]; then
  echo 'ERROR: uninstall incomplete; success not reported. Payload kept for retry.' >&2
  exit 1
fi
# state/ holds public protection settings and the administrator-only PIN
# authority: ask before deleting it. SENTRY_KEEP_SETTINGS=yes|no answers
# non-interactively. A kept state directory survives for the next install.
if [ "$keep" = "yes" ]; then
  if ! find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -name state \
    -exec rm -rf {} +; then
    echo 'ERROR: removal target=support-except-state observed=find-or-remove-failed remediation=inspect-permissions-and-rerun-packaging/uninstall.sh' >&2
    removal_failed=1
  fi
  unexpected_entry=''
  if ! unexpected_entry=$(find "$SUPPORT" -mindepth 1 -maxdepth 1 \
    ! -name state -print -quit); then
    echo 'ERROR: removal target=support-except-state observed=verification-failed remediation=inspect-permissions-and-rerun-packaging/uninstall.sh' >&2
    removal_failed=1
  elif [ -n "$unexpected_entry" ]; then
    printf 'ERROR: removal target=support-except-state observed=path-still-present path=%q remediation=inspect-permissions-and-rerun-packaging/uninstall.sh\n' \
      "$unexpected_entry" >&2
    removal_failed=1
  fi
  if [ ! -f "$SETTINGS" ]; then
    printf 'ERROR: preservation target=settings.json observed=missing path=%q remediation=restore-settings-before-rerunning-uninstall\n' \
      "$SETTINGS" >&2
    removal_failed=1
  fi
  if [ ! -f "$PARENT_PIN" ]; then
    printf 'ERROR: preservation target=parent/pin.json observed=missing path=%q remediation=restore-parent-state-before-rerunning-uninstall\n' \
      "$PARENT_PIN" >&2
    removal_failed=1
  fi
  # Files a pre-open-source install kept in state/ (license, check-in and
  # updater records, the old diagnostics outbox). Nothing reads them now; drop
  # them with the install.
  for legacy_rel in parent/license.json parent/entitlement.json \
    parent/release-request.json parent/checkin-request.json entitlement.json \
    machine-id updater-state.json parent/diagnostics-request.json; do
    remove_target "legacy-$legacy_rel" -f "$STATE/$legacy_rel"
    verify_absent "legacy-$legacy_rel" "$STATE/$legacy_rel"
  done
  remove_target legacy-diagnostics -rf "$STATE/diagnostics"
  verify_absent legacy-diagnostics "$STATE/diagnostics"
else
  remove_target support -rf "$SUPPORT"
  verify_absent support "$SUPPORT"
fi

if [ "$removal_failed" != 0 ]; then
  echo 'ERROR: uninstall incomplete; success not reported. Correct the named removal failure and rerun packaging/uninstall.sh.' >&2
  exit 1
fi
if [ "$skip_launchd" = 0 ]; then
  if pkgutil --pkg-info com.sentryscreen.pkg >/dev/null 2>&1; then
    pkgutil --forget com.sentryscreen.pkg || {
      echo 'ERROR: package-receipt observed=forget-failed remediation=run-pkgutil---forget-com.sentryscreen.pkg-as-administrator' >&2
      exit 1
    }
  fi
fi
if [ "$keep" = yes ]; then
  echo "kept $STATE"
fi
if [ "$RESET_PERMISSIONS" = 1 ]; then
  echo "removed. SentryScreen permission records for all users reset (tccutil reset All $BUNDLE_ID as root)."
else
  echo "removed. Per-user TCC grants remain; clear with:"
  echo "  tccutil reset ScreenCapture $BUNDLE_ID"
  echo "(or rerun the uninstaller with --reset-permissions)"
fi
