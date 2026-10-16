#!/bin/bash
# Administrator recovery for the protected parent PIN authority. This script
# replaces the verifier and its failure counters together with an empty schema
# record. Shared settings.json is not changed.
set -euo pipefail

# the installed copy ignores the development and test
# overrides this script reads. Only a copy run from elsewhere (the repo tree,
# the lifecycle tests' isolated payload) honours them, so an environment a
# user can set (launchctl setenv) never reaches the installed script.
case "$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" in
  "/Library/Application Support/SentryScreen" | "") unset SENTRY_STATE_DIR SENTRY_SKIP_OWNERSHIP SENTRY_TEST_TRANSACTION_HOOK SENTRY_TEST_OWNER_SWAP_TRIPWIRE ;;
esac
STATE_ROOT="${SENTRY_STATE_DIR:-/Library/Application Support/SentryScreen/state}"
PARENT_ROOT="$STATE_ROOT/parent"
PIN_FILE="$PARENT_ROOT/pin.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JSON_TOOL="$SCRIPT_DIR/json-tool.sh"
if [ ! -x "$JSON_TOOL" ]; then
  JSON_TOOL="$SCRIPT_DIR/pkg-scripts/json-tool.sh"
fi
[ -x "$JSON_TOOL" ] || {
  printf 'reset-pin: JSON tool configured=executable observed=missing path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$JSON_TOOL" >&2
  exit 1
}
SKIP_OWNERSHIP="${SENTRY_SKIP_OWNERSHIP:-0}"
TEST_TRANSACTION_HOOK="${SENTRY_TEST_TRANSACTION_HOOK:-}"
TEST_OWNER_SWAP_TRIPWIRE="${SENTRY_TEST_OWNER_SWAP_TRIPWIRE:-0}"
temporary=""
STATE_DIRECTORY_OPEN=0
STATE_DIRECTORY_LOCKED=0
PARENT_DIRECTORY_OPEN=0
PARENT_DIRECTORY_LOCKED=0
PIN_MODE_LOCKED=0

restore_root_transaction() {
  local failed=0
  if [ "$PIN_MODE_LOCKED" = "1" ]; then
    /bin/chmod 660 "$PIN_FILE" || {
      printf 'reset-pin: parent-PIN-file configured=mode=660 observed=restore-failed path=%q remediation=rerun-the-SentryScreen-installer\n' \
        "$PIN_FILE" >&2
      failed=1
    }
    PIN_MODE_LOCKED=0
  fi
  if [ "$PARENT_DIRECTORY_LOCKED" = "1" ]; then
    /bin/chmod 2770 /dev/fd/9 || {
      printf 'reset-pin: parent-PIN-directory configured=mode=2770 observed=descriptor-restore-failed descriptor=9 remediation=rerun-the-SentryScreen-installer\n' >&2
      failed=1
    }
    PARENT_DIRECTORY_LOCKED=0
  fi
  if [ "$PARENT_DIRECTORY_OPEN" = "1" ]; then
    exec 9<&-
    PARENT_DIRECTORY_OPEN=0
  fi
  if [ "$STATE_DIRECTORY_LOCKED" = "1" ]; then
    /bin/chmod 2775 /dev/fd/8 || {
      printf 'reset-pin: state-directory configured=mode=2775 observed=descriptor-restore-failed descriptor=8 remediation=rerun-the-SentryScreen-installer\n' >&2
      failed=1
    }
    STATE_DIRECTORY_LOCKED=0
  fi
  if [ "$STATE_DIRECTORY_OPEN" = "1" ]; then
    exec 8<&-
    STATE_DIRECTORY_OPEN=0
  fi
  return "$failed"
}

cleanup_root_transaction() {
  local status=$?
  trap - EXIT
  [ -z "$temporary" ] || /bin/rm -f "$temporary"
  restore_root_transaction || status=1
  exit "$status"
}
trap cleanup_root_transaction EXIT

case "$SKIP_OWNERSHIP" in
  0|1) ;;
  *)
    printf 'reset-pin: SENTRY_SKIP_OWNERSHIP configured=0|1 observed=%q remediation=use-1-only-for-an-isolated-test-root\n' \
      "$SKIP_OWNERSHIP" >&2
    exit 64
    ;;
esac
if [ "$SKIP_OWNERSHIP" = "0" ] && [ "$(id -u)" != "0" ]; then
  echo 'reset-pin: configured=root-administrator observed=non-root remediation=run with sudo' >&2
  exit 77
fi
if [ -n "$TEST_TRANSACTION_HOOK" ] && {
  [ "$SKIP_OWNERSHIP" != "1" ] \
    || [ "$STATE_ROOT" = "/Library/Application Support/SentryScreen/state" ] \
    || [ -L "$TEST_TRANSACTION_HOOK" ] || [ ! -f "$TEST_TRANSACTION_HOOK" ] \
    || [ ! -x "$TEST_TRANSACTION_HOOK" ]
}; then
  printf 'reset-pin: SENTRY_TEST_TRANSACTION_HOOK configured=executable-regular-file-with-isolated-state-and-skip-ownership observed=unsafe-test-hook path=%q remediation=unset-the-hook-outside-the-focused-lifecycle-test\n' \
    "$TEST_TRANSACTION_HOOK" >&2
  exit 64
fi
case "$TEST_OWNER_SWAP_TRIPWIRE" in
  0) ;;
  1)
    [ -n "$TEST_TRANSACTION_HOOK" ] || {
      printf 'reset-pin: SENTRY_TEST_OWNER_SWAP_TRIPWIRE configured=0-or-1-with-transaction-hook observed=1-without-hook remediation=use-only-in-the-focused-lifecycle-test\n' >&2
      exit 64
    }
    ;;
  *)
    printf 'reset-pin: SENTRY_TEST_OWNER_SWAP_TRIPWIRE configured=0-or-1 observed=%q remediation=use-only-in-the-focused-lifecycle-test\n' \
      "$TEST_OWNER_SWAP_TRIPWIRE" >&2
    exit 64
    ;;
esac

permission_mode() {
  local raw_mode
  raw_mode=$(/usr/bin/stat -f '%p' "$1")
  printf '%o' "$((8#$raw_mode & 07777))"
}

run_test_owner_swap_tripwire() {
  local hook_status=0
  [ "$TEST_OWNER_SWAP_TRIPWIRE" = "1" ] || return 0
  /bin/chmod 2555 /dev/fd/8
  /bin/chmod 2550 /dev/fd/9
  "$TEST_TRANSACTION_HOOK" reset-owner-locked "$STATE_ROOT" "$PARENT_ROOT" \
    "$STATE_ROOT/settings.json" "$PIN_FILE" || hook_status=$?
  /bin/chmod 2750 /dev/fd/9
  /bin/chmod 2755 /dev/fd/8
  [ "$hook_status" -eq 0 ] || {
    printf 'reset-pin: owner-swap-tripwire configured=blocked observed=hook-exit-%s phase=reset remediation=inspect-the-focused-lifecycle-test\n' \
      "$hook_status" >&2
    return "$hook_status"
  }
}

if [ "$SKIP_OWNERSHIP" = "1" ]; then
  expected_group=$(id -g)
  expected_owner=$(id -u)
else
  expected_group=$(dscl . -read /Groups/admin PrimaryGroupID | awk '{print $2}')
  expected_owner=0
fi
if [ -L "$STATE_ROOT" ] || [ ! -d "$STATE_ROOT" ]; then
  printf 'reset-pin: state-directory configured=type-directory observed=missing-or-unsafe path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$STATE_ROOT" >&2
  exit 66
fi
if [ "$SKIP_OWNERSHIP" = "0" ]; then
  /usr/sbin/chown root:admin "$STATE_ROOT"
fi
observed_state="$(/usr/bin/stat -f '%HT' "$STATE_ROOT"),owner=$(/usr/bin/stat -f '%u' "$STATE_ROOT"),group=$(/usr/bin/stat -f '%g' "$STATE_ROOT"),mode=$(permission_mode "$STATE_ROOT")"
[ "$observed_state" = "Directory,owner=$expected_owner,group=$expected_group,mode=2775" ] || {
  printf 'reset-pin: state-directory configured=type-Directory,owner=%s,group=%s,mode=2775 observed=%s path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$expected_owner" "$expected_group" "$observed_state" "$STATE_ROOT" >&2
  exit 66
}
exec 8<"$STATE_ROOT" || {
  printf 'reset-pin: state-directory configured=open-directory-descriptor observed=open-failed path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$STATE_ROOT" >&2
  exit 66
}
STATE_DIRECTORY_OPEN=1
state_path_inode=$(/usr/bin/stat -f '%i' "$STATE_ROOT")
state_fd_inode=$(/usr/bin/stat -f '%i' /dev/fd/8)
[ "$state_path_inode" = "$state_fd_inode" ] || {
  printf 'reset-pin: state-directory configured=path-inode-equals-fd-inode observed=path-%s,fd-%s path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$state_path_inode" "$state_fd_inode" "$STATE_ROOT" >&2
  exit 66
}
/bin/chmod 2755 /dev/fd/8 || {
  printf 'reset-pin: state-directory-lock configured=mode=2755 observed=chmod-failed descriptor=8 remediation=rerun-the-SentryScreen-installer\n' >&2
  exit 66
}
STATE_DIRECTORY_LOCKED=1
if [ -L "$PARENT_ROOT" ] || [ ! -d "$PARENT_ROOT" ]; then
  printf 'reset-pin: parent-PIN-directory configured=type-Directory,group=%s,mode=2770 observed=missing-or-unsafe path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$expected_group" "$PARENT_ROOT" >&2
  exit 66
fi
if [ "$SKIP_OWNERSHIP" = "0" ]; then
  /usr/sbin/chown root:admin "$PARENT_ROOT"
fi
observed_directory="$(/usr/bin/stat -f '%HT' "$PARENT_ROOT"),owner=$(/usr/bin/stat -f '%u' "$PARENT_ROOT"),group=$(/usr/bin/stat -f '%g' "$PARENT_ROOT"),mode=$(permission_mode "$PARENT_ROOT")"
[ "$observed_directory" = "Directory,owner=$expected_owner,group=$expected_group,mode=2770" ] || {
  printf 'reset-pin: parent-PIN-directory configured=type-Directory,owner=%s,group=%s,mode=2770 observed=%s path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$expected_owner" "$expected_group" "$observed_directory" "$PARENT_ROOT" >&2
  exit 66
}
exec 9<"$PARENT_ROOT" || {
  printf 'reset-pin: parent-PIN-directory configured=open-directory-descriptor observed=open-failed path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$PARENT_ROOT" >&2
  exit 66
}
PARENT_DIRECTORY_OPEN=1
parent_path_inode=$(/usr/bin/stat -f '%i' "$PARENT_ROOT")
parent_fd_inode=$(/usr/bin/stat -f '%i' /dev/fd/9)
[ "$parent_path_inode" = "$parent_fd_inode" ] || {
  printf 'reset-pin: parent-PIN-directory configured=path-inode-equals-fd-inode observed=path-%s,fd-%s path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$parent_path_inode" "$parent_fd_inode" "$PARENT_ROOT" >&2
  exit 66
}
/bin/chmod 2750 /dev/fd/9 || {
  printf 'reset-pin: parent-PIN-directory-lock configured=mode=2750 observed=chmod-failed descriptor=9 remediation=rerun-the-SentryScreen-installer\n' >&2
  exit 66
}
PARENT_DIRECTORY_LOCKED=1
if [ -L "$PIN_FILE" ] || [ ! -f "$PIN_FILE" ]; then
  printf 'reset-pin: parent-PIN-file configured=type-Regular-File,group=%s,mode=660,links=1 observed=missing-or-unsafe path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$expected_group" "$PIN_FILE" >&2
  exit 66
fi
if [ "$SKIP_OWNERSHIP" = "0" ]; then
  /usr/sbin/chown root:admin "$PIN_FILE"
fi
observed_pin="$(/usr/bin/stat -f '%HT' "$PIN_FILE"),owner=$(/usr/bin/stat -f '%u' "$PIN_FILE"),group=$(/usr/bin/stat -f '%g' "$PIN_FILE"),mode=$(permission_mode "$PIN_FILE"),links=$(/usr/bin/stat -f '%l' "$PIN_FILE")"
[ "$observed_pin" = "Regular File,owner=$expected_owner,group=$expected_group,mode=660,links=1" ] || {
  printf 'reset-pin: parent-PIN-file configured=type-Regular-File,owner=%s,group=%s,mode=660,links=1 observed=%s path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$expected_owner" "$expected_group" "$observed_pin" "$PIN_FILE" >&2
  exit 66
}
/bin/chmod 600 "$PIN_FILE"
PIN_MODE_LOCKED=1
if [ -n "$TEST_TRANSACTION_HOOK" ]; then
  "$TEST_TRANSACTION_HOOK" reset-locked "$STATE_ROOT" "$PARENT_ROOT" \
    "$STATE_ROOT/settings.json" "$PIN_FILE" || {
    hook_status=$?
    printf 'reset-pin: test-transaction-hook configured=exit-0 observed=exit-%s phase=reset-locked remediation=inspect-the-focused-lifecycle-test\n' \
      "$hook_status" >&2
    exit "$hook_status"
  }
fi
run_test_owner_swap_tripwire

version=$("$JSON_TOOL" get "$PIN_FILE" version 2>/dev/null) || {
  printf 'reset-pin: parent-PIN-schema configured=parseable-version-1 observed=invalid path=%q remediation=repair-the-protected-credential-file\n' \
    "$PIN_FILE" >&2
  exit 1
}
[ "$version" = "1" ] || {
  printf 'reset-pin: parent-PIN-schema configured=version-1 observed=version-%s path=%q remediation=update-SentryScreen-before-resetting-the-PIN\n' \
    "$version" "$PIN_FILE" >&2
  exit 1
}

umask 007
temporary=$(/usr/bin/mktemp "$PARENT_ROOT/.pin.json.reset.XXXXXX") || {
  printf 'reset-pin: parent-PIN-temporary configured=new-same-directory-file observed=creation-failed path=%q remediation=inspect-parent-directory-permissions-and-storage\n' \
    "$PARENT_ROOT" >&2
  exit 1
}
if [ -L "$temporary" ] || [ ! -f "$temporary" ] \
  || [ "$(/usr/bin/stat -f '%l' "$temporary" 2>/dev/null || printf 0)" != "1" ]; then
  printf 'reset-pin: parent-PIN-temporary configured=type-regular,links=1 observed=unsafe-path path=%q remediation=inspect-parent-directory-and-rerun-reset\n' \
    "$temporary" >&2
  exit 1
fi
printf '{"version":1}\n' > "$temporary"
chmod 600 "$temporary"
if [ "$SKIP_OWNERSHIP" = "0" ]; then
  chown root:admin "$temporary"
fi
observed_temporary="$(/usr/bin/stat -f '%HT' "$temporary"),owner=$(/usr/bin/stat -f '%u' "$temporary"),group=$(/usr/bin/stat -f '%g' "$temporary"),mode=$(permission_mode "$temporary"),links=$(/usr/bin/stat -f '%l' "$temporary")"
[ "$observed_temporary" = "Regular File,owner=$expected_owner,group=$expected_group,mode=600,links=1" ] || {
  printf 'reset-pin: parent-PIN-temporary configured=type-Regular-File,owner=%s,group=%s,mode=600,links=1 observed=%s path=%q remediation=inspect-parent-directory-and-rerun-reset\n' \
    "$expected_owner" "$expected_group" "$observed_temporary" "$temporary" >&2
  exit 1
}
/bin/mv -fh "$temporary" "$PIN_FILE" || {
  printf 'reset-pin: parent-PIN-install configured=atomic-same-directory-rename observed=rename-failed path=%q remediation=inspect-parent-directory-and-rerun-reset\n' \
    "$PIN_FILE" >&2
  exit 1
}
temporary=""

observed_pin="$(/usr/bin/stat -f '%HT' "$PIN_FILE"),owner=$(/usr/bin/stat -f '%u' "$PIN_FILE"),group=$(/usr/bin/stat -f '%g' "$PIN_FILE"),mode=$(permission_mode "$PIN_FILE"),links=$(/usr/bin/stat -f '%l' "$PIN_FILE")"
[ "$observed_pin" = "Regular File,owner=$expected_owner,group=$expected_group,mode=600,links=1" ] || {
  printf 'reset-pin: parent-PIN-file configured=type-Regular-File,owner=%s,group=%s,mode=600-during-root-transaction,links=1 observed=%s path=%q remediation=rerun-the-SentryScreen-installer\n' \
    "$expected_owner" "$expected_group" "$observed_pin" "$PIN_FILE" >&2
  exit 1
}
restore_root_transaction || exit 1
[ "$(permission_mode "$STATE_ROOT")" = "2775" ] \
  && [ "$(permission_mode "$PARENT_ROOT")" = "2770" ] \
  && [ "$(permission_mode "$PIN_FILE")" = "660" ] || {
  printf 'reset-pin: state-transaction-restore configured=state-2775,parent-2770,pin-660 observed=state-%s,parent-%s,pin-%s remediation=rerun-the-SentryScreen-installer\n' \
    "$(permission_mode "$STATE_ROOT")" "$(permission_mode "$PARENT_ROOT")" \
    "$(permission_mode "$PIN_FILE")" >&2
  exit 1
}
echo "PIN RESET in $PIN_FILE — the next parent action requires a new PIN."
