#!/bin/bash
# Configure an already-staged SentryScreen payload. The development installer
# and the pkg postinstall both call this file so permissions and launchd
# behavior have one implementation.
set -euo pipefail

ROOT_PREFIX="${SENTRY_INSTALL_ROOT:-}"
SKIP_LAUNCHD="${SENTRY_SKIP_LAUNCHD:-0}"
SKIP_OWNERSHIP="${SENTRY_SKIP_OWNERSHIP:-0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JSON_TOOL="$SCRIPT_DIR/json-tool.sh"

[ -x "$JSON_TOOL" ] || {
  printf 'configure-install: JSON tool configured=executable observed=missing path=%q remediation=rebuild-the-installer\n' \
    "$JSON_TOOL" >&2
  exit 1
}

if [ -z "$ROOT_PREFIX" ] && [ "$(id -u)" != "0" ]; then
  echo "configure-install: root is required for a system install" >&2
  exit 77
fi

SUPPORT="$ROOT_PREFIX/Library/Application Support/SentryScreen"
# Receipt: this file runs from inside the installed payload, where
# packaging/release.env does not exist, so the model basename cannot be
# sourced. packaging/render-model-template.sh substitutes the placeholder
# token when build-pkg.sh writes the package copy. The baked value wins: a
# shipped installer must not let an ambient SENTRY_MODEL_FILE in the
# installer's environment outrank the basename this package actually carries.
# Only an unrendered copy (repo-rooted callers — packaging/install.sh and the
# packaging tests — run this file straight from the tree) falls back to the
# exported SENTRY_MODEL_FILE. No token and no export means the package was
# assembled without the renderer — fail loudly rather than look for a literal
# "@" path.
MODEL_FILE="@SENTRY_MODEL_FILE@"
case "$MODEL_FILE" in
  *@*) MODEL_FILE="${SENTRY_MODEL_FILE:-}" ;;
esac
case "$MODEL_FILE" in
  "" | *@*)
    echo "configure-install: model file name configured=build-time-substitution-or-SENTRY_MODEL_FILE observed=unsubstituted-placeholder remediation=packaging/render-model-template.sh" >&2
    exit 1
    ;;
esac
LOG_ROOT="$ROOT_PREFIX/Library/Logs/SentryScreen"
AGENT_PLIST="$ROOT_PREFIX/Library/LaunchAgents/com.sentryscreen.agent.plist"
WATCHDOG_PLIST="$ROOT_PREFIX/Library/LaunchDaemons/com.sentryscreen.watchdog.plist"
# Paths a pre-open-source install left behind (the retired background
# updater and parent-helper); removed on install so nothing of them keeps running.
LEGACY_UPDATER_PLIST="$ROOT_PREFIX/Library/LaunchDaemons/com.sentryscreen.updater.plist"
LEGACY_HELPER_PLIST="$ROOT_PREFIX/Library/LaunchDaemons/com.sentryscreen.parent-helper.plist"
STATE="$SUPPORT/state"
SETTINGS_FILE="$STATE/settings.json"
PARENT_PIN_ROOT="$STATE/parent"
PARENT_PIN_FILE="$PARENT_PIN_ROOT/pin.json"
TEMPORARY_PATH=""
TEST_TRANSACTION_HOOK="${SENTRY_TEST_TRANSACTION_HOOK:-}"
TEST_OWNER_SWAP_TRIPWIRE="${SENTRY_TEST_OWNER_SWAP_TRIPWIRE:-0}"
STATE_DIRECTORY_OPEN=0
STATE_DIRECTORY_LOCKED=0
PARENT_DIRECTORY_OPEN=0
PARENT_DIRECTORY_LOCKED=0
SETTINGS_MODE_LOCKED=0
PIN_MODE_LOCKED=0
WATCHDOG_PARKED=0

restore_root_transaction() {
  local failed=0
  if [ "$PIN_MODE_LOCKED" = "1" ]; then
    /bin/chmod 660 "$PARENT_PIN_FILE" || {
      printf 'configure-install: parent-PIN-file configured=mode=660 observed=restore-failed path=%q remediation=rerun-installer-permission-repair\n' \
        "$PARENT_PIN_FILE" >&2
      failed=1
    }
    PIN_MODE_LOCKED=0
  fi
  if [ "$SETTINGS_MODE_LOCKED" = "1" ]; then
    /bin/chmod 664 "$SETTINGS_FILE" || {
      printf 'configure-install: public-settings-file configured=mode=664 observed=restore-failed path=%q remediation=rerun-installer-permission-repair\n' \
        "$SETTINGS_FILE" >&2
      failed=1
    }
    SETTINGS_MODE_LOCKED=0
  fi
  if [ "$PARENT_DIRECTORY_LOCKED" = "1" ]; then
    /bin/chmod 2770 /dev/fd/9 || {
      printf 'configure-install: parent-PIN-directory configured=mode=2770 observed=descriptor-restore-failed descriptor=9 remediation=rerun-installer-permission-repair\n' >&2
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
      printf 'configure-install: state-directory configured=mode=2775 observed=descriptor-restore-failed descriptor=8 remediation=rerun-installer-permission-repair\n' >&2
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
  [ -z "$TEMPORARY_PATH" ] || /bin/rm -f "$TEMPORARY_PATH"
  restore_root_transaction || status=1
  # WATCHDOG_PARKED is set only by park_watchdog in the launchd section, which
  # also defines restore_parked_watchdog; an earlier exit never reaches it.
  if [ "$WATCHDOG_PARKED" = 1 ]; then
    restore_parked_watchdog || status=1
  fi
  exit "$status"
}
trap cleanup_root_transaction EXIT

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

path_observation() {
  if ! path_exists "$1"; then
    printf 'missing'
  elif ! /usr/bin/stat -f 'type=%HT,links=%l' "$1" 2>/dev/null; then
    printf 'unreadable'
  fi
}

permission_mode() {
  local raw_mode
  raw_mode=$(/usr/bin/stat -f '%p' "$1")
  printf '%o' "$((8#$raw_mode & 07777))"
}

run_test_transaction_hook() {
  local phase="$1"
  [ -z "$TEST_TRANSACTION_HOOK" ] && return 0
  "$TEST_TRANSACTION_HOOK" "$phase" "$STATE" "$PARENT_PIN_ROOT" \
    "$SETTINGS_FILE" "$PARENT_PIN_FILE" || {
    local hook_status=$?
    printf 'configure-install: test-transaction-hook configured=exit-0 observed=exit-%s phase=%s remediation=inspect-the-focused-lifecycle-test\n' \
      "$hook_status" "$phase" >&2
    return "$hook_status"
  }
}

run_test_owner_swap_tripwire() {
  local phase="$1"
  local hook_status=0
  [ "$TEST_OWNER_SWAP_TRIPWIRE" = "1" ] || return 0
  case "$phase" in
    state)
      /bin/chmod 2555 /dev/fd/8
      "$TEST_TRANSACTION_HOOK" state-owner-locked "$STATE" "$PARENT_PIN_ROOT" \
        "$SETTINGS_FILE" "$PARENT_PIN_FILE" || hook_status=$?
      /bin/chmod 2755 /dev/fd/8
      ;;
    parent)
      /bin/chmod 2555 /dev/fd/8
      /bin/chmod 2550 /dev/fd/9
      "$TEST_TRANSACTION_HOOK" parent-owner-locked "$STATE" "$PARENT_PIN_ROOT" \
        "$SETTINGS_FILE" "$PARENT_PIN_FILE" || hook_status=$?
      /bin/chmod 2750 /dev/fd/9
      /bin/chmod 2755 /dev/fd/8
      ;;
  esac
  [ "$hook_status" -eq 0 ] || {
    printf 'configure-install: owner-swap-tripwire configured=blocked observed=hook-exit-%s phase=%s remediation=inspect-the-focused-lifecycle-test\n' \
      "$hook_status" "$phase" >&2
    return "$hook_status"
  }
}

# Reject unsafe state paths before a root-owned chmod, chown, redirect, or
# parser can follow them. Regular state files must have one name so an
# installer repair cannot change an outside hard-link target.
if [ -L "$SUPPORT" ] || [ ! -d "$SUPPORT" ]; then
  printf 'configure-install: support-directory configured=type-directory observed=unsafe-path,details=%s path=%q remediation=restore-the-package-payload-directory\n' \
    "$(path_observation "$SUPPORT")" "$SUPPORT" >&2
  exit 1
fi
if path_exists "$STATE" && { [ -L "$STATE" ] || [ ! -d "$STATE" ]; }; then
  printf 'configure-install: state-directory configured=type-directory observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$STATE")" "$STATE" >&2
  exit 1
fi
if path_exists "$SETTINGS_FILE" && {
  [ -L "$SETTINGS_FILE" ] || [ ! -f "$SETTINGS_FILE" ] \
    || [ "$(/usr/bin/stat -f '%l' "$SETTINGS_FILE" 2>/dev/null || printf 0)" != "1" ]
}; then
  printf 'configure-install: public-settings-file configured=type-regular,links=1 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-restore-settings-from-a-trusted-copy\n' \
    "$(path_observation "$SETTINGS_FILE")" "$SETTINGS_FILE" >&2
  exit 1
fi
if path_exists "$PARENT_PIN_ROOT" \
  && { [ -L "$PARENT_PIN_ROOT" ] || [ ! -d "$PARENT_PIN_ROOT" ]; }; then
  printf 'configure-install: parent-PIN-directory configured=type-directory,group=admin,mode=2770 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$PARENT_PIN_ROOT")" "$PARENT_PIN_ROOT" >&2
  exit 1
fi
if path_exists "$PARENT_PIN_FILE" && {
  [ -L "$PARENT_PIN_FILE" ] || [ ! -f "$PARENT_PIN_FILE" ] \
    || [ "$(/usr/bin/stat -f '%l' "$PARENT_PIN_FILE" 2>/dev/null || printf 0)" != "1" ]
}; then
  printf 'configure-install: parent-PIN-file configured=type-regular,group=admin,mode=0660,links=1 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$PARENT_PIN_FILE")" "$PARENT_PIN_FILE" >&2
  exit 1
fi
if [ -n "$TEST_TRANSACTION_HOOK" ] && {
  [ -z "$ROOT_PREFIX" ] || [ "$SKIP_OWNERSHIP" != "1" ] \
    || [ -L "$TEST_TRANSACTION_HOOK" ] || [ ! -f "$TEST_TRANSACTION_HOOK" ] \
    || [ ! -x "$TEST_TRANSACTION_HOOK" ]
}; then
  printf 'configure-install: SENTRY_TEST_TRANSACTION_HOOK configured=executable-regular-file-with-isolated-root-and-skip-ownership observed=unsafe-test-hook path=%q remediation=unset-the-hook-outside-the-focused-lifecycle-test\n' \
    "$TEST_TRANSACTION_HOOK" >&2
  exit 64
fi
case "$TEST_OWNER_SWAP_TRIPWIRE" in
  0) ;;
  1)
    [ -n "$TEST_TRANSACTION_HOOK" ] || {
      printf 'configure-install: SENTRY_TEST_OWNER_SWAP_TRIPWIRE configured=0-or-1-with-transaction-hook observed=1-without-hook remediation=use-only-in-the-focused-lifecycle-test\n' >&2
      exit 64
    }
    ;;
  *)
    printf 'configure-install: SENTRY_TEST_OWNER_SWAP_TRIPWIRE configured=0-or-1 observed=%q remediation=use-only-in-the-focused-lifecycle-test\n' \
      "$TEST_OWNER_SWAP_TRIPWIRE" >&2
    exit 64
    ;;
esac

for required in \
  "$SUPPORT/SentryScreen.app" \
  "$SUPPORT/$MODEL_FILE" \
  "$SUPPORT/config.default.json" \
  "$SUPPORT/watchdog.sh" \
  "$SUPPORT/agent-launch.sh" \
  "$SUPPORT/uninstall.sh" \
  "$SUPPORT/reset-pin.sh" \
  "$SUPPORT/json-tool.sh" \
  "$AGENT_PLIST" \
  "$WATCHDOG_PLIST"; do
  [ -e "$required" ] || {
    echo "configure-install: required payload path is missing: $required" >&2
    exit 1
  }
done

if path_exists "$LOG_ROOT" && { [ -L "$LOG_ROOT" ] || [ ! -d "$LOG_ROOT" ]; }; then
  printf 'configure-install: log-root configured=type-directory observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$LOG_ROOT")" "$LOG_ROOT" >&2
  exit 1
fi
mkdir -p "$LOG_ROOT"
# Remove only the exact shared log files created by pre-per-user installs.
# Current per-user log directories are not touched during an install/update.
rm -f "$LOG_ROOT/agent.out" "$LOG_ROOT/agent.err" "$LOG_ROOT"/run.jsonl*
if [ ! -f "$SUPPORT/config.json" ]; then
  cp "$SUPPORT/config.default.json" "$SUPPORT/config.json"
else
  # G6, closed 2026-09-02. config.json is a
  # parent's file and is preserved across updates — EXCEPT its "model" key.
  #
  # Rationale for that one exception: the model file is a package-owned
  # PAYLOAD, not a parent preference. Nothing in the UI sets it, an upgrade
  # ships it, and its value is an absolute path into this package's own
  # support directory. A `--model` control arm on an installed machine is a
  # deliberate developer override, and an upgrade legitimately resets it.
  #
  # What used to happen:
  # an update shipping a different SENTRY_MODEL_FILE left the preserved
  # "model" pointing at the PREVIOUS payload, so the daemon went on loading
  # the OLD detector after an install that shipped a new one — "config wins".
  # The only fix was a root keep-state uninstall + reinstall, which needs an
  # interactive password and is therefore unavailable to the background
  # updater. That made G6 a hard blocker on any model-changing auto-update.
  #
  # So: rewrite ONLY the model value, byte-preserving everything else.
  # A generic JSON rewrite is NOT usable here: it reorders
  # keys, escapes every "/" and collapses the file to one line, so a parent's
  # config would come back unrecognisable. json-tool.sh is used as the parser
  # and verifier instead; the edit itself is a one-line sed.
  config_file="$SUPPORT/config.json"
  "$JSON_TOOL" validate "$config_file" >/dev/null 2>&1 || {
    printf 'configure-install: config.json model rewrite configured=parseable-json observed=unparseable path=%s remediation=repair-or-remove-the-file-and-rerun-the-installer\n' \
      "$config_file" >&2
    exit 1
  }
  # An absent "model" key leaves the parent file unchanged.
  configured_model=$("$JSON_TOOL" get "$config_file" model 2>/dev/null) \
    || configured_model=""
  case "$configured_model" in
    "" | "$MODEL_FILE" | */"$MODEL_FILE") ;;
    *)
      # The new value is $SUPPORT/$MODEL_FILE — where this package's payload
      # actually is. NOT config.default.json's value: that file is rendered
      # with the literal "/Library/Application Support/..." prefix, which is
      # correct for a real install but wrong under SENTRY_INSTALL_ROOT, and a
      # test that asserted it could not tell a right path from a wrong one.
      # config.default.json is still checked, as a tripwire only: if its
      # basename disagrees with MODEL_FILE the package was assembled without
      # the renderer and nothing here should be guessing.
      desired_model="$SUPPORT/$MODEL_FILE"
      default_model=$("$JSON_TOOL" get "$SUPPORT/config.default.json" model 2>/dev/null) \
        || default_model=""
      case "$default_model" in
        */"$MODEL_FILE") ;;
        *)
          printf 'configure-install: config.json model rewrite configured=config.default.json-model-ending-in-%s observed=%s path=%s remediation=packaging/render-model-template.sh\n' \
            "$MODEL_FILE" "${default_model:-absent}" "$SUPPORT/config.default.json" >&2
          exit 1
          ;;
      esac
      # The value is spliced into a sed replacement below. MODEL_FILE is
      # already charset-guarded in packaging/release.env; this guards the
      # rendered prefix too, because a "|", "&" or "\" there would rewrite
      # the substitution itself. Space is allowed: "Application Support".
      case "$desired_model" in
        *[!A-Za-z0-9._/\ -]*)
          printf 'configure-install: config.json model rewrite configured=safe-path-charset observed=%s path=%s remediation=packaging/render-model-template.sh\n' \
            "$desired_model" "$SUPPORT/config.default.json" >&2
          exit 1
          ;;
      esac
      # Shape tripwire: the edit below replaces the FIRST "model" value it
      # finds, so the file must contain exactly one "model" key. Count
      # OCCURRENCES, not matching lines — MEASURED 2026-09-02 while writing
      # the test for this: a nested {"model":...} on the same physical line
      # as the top-level one is a single line but two keys, and a line count
      # waved it through. Anything not shaped like
      # packaging/config.sample.json is refused by name, not edited on a
      # guess. Neither branch is dead: >1 is a nested or duplicated key, and
      # 0 means the JSON parser sees a model key that this pattern cannot (unusual
      # escaping) — both are "not the shape this substitution handles".
      model_key_count=$(/usr/bin/grep -o '"model"[[:space:]]*:' "$config_file" \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ' || true)
      if [ "$model_key_count" != "1" ]; then
        printf 'configure-install: config.json model rewrite configured=exactly-one-model-key observed=%s path=%s remediation=edit-the-file-to-the-packaging/config.sample.json-shape-and-rerun\n' \
          "$model_key_count" "$config_file" >&2
        printf 'configure-install: preserved config.json model configured=%s observed=%s remediation=edit %s\n' \
          "$MODEL_FILE" "${configured_model##*/}" "$config_file" >&2
        exit 1
      fi
      TEMPORARY_PATH=$(/usr/bin/mktemp "$SUPPORT/.config.json.install.XXXXXX") || {
        printf 'configure-install: config.json model rewrite configured=temp-file-created observed=mktemp-failed path=%s remediation=check-free-space-and-permissions\n' \
          "$SUPPORT" >&2
        exit 1
      }
      sed 's|\("model"[[:space:]]*:[[:space:]]*"\)[^"]*\(".*\)|\1'"$desired_model"'\2|' \
        "$config_file" > "$TEMPORARY_PATH"
      # Verify before publishing: the result must parse, must name the model
      # we intended, and must differ from the original on the model line and
      # NOWHERE else. The third check is what makes "every other key is
      # preserved" a receipt rather than a hope.
      "$JSON_TOOL" validate "$TEMPORARY_PATH" >/dev/null 2>&1 || {
        printf 'configure-install: config.json model rewrite configured=parseable-result observed=unparseable path=%s remediation=nothing-was-written-inspect-%s\n' \
          "$config_file" "$config_file" >&2
        exit 1
      }
      rewritten_model=$("$JSON_TOOL" get "$TEMPORARY_PATH" model 2>/dev/null) \
        || rewritten_model=""
      if [ "$rewritten_model" != "$desired_model" ]; then
        printf 'configure-install: config.json model rewrite configured=%s observed=%s path=%s remediation=nothing-was-written-inspect-%s\n' \
          "$desired_model" "${rewritten_model:-absent}" "$config_file" "$config_file" >&2
        exit 1
      fi
      # Compared in-shell rather than with diff/cmp: /usr/bin/diff is a
      # Command Line Tools shim on a stock Mac and must not be a runtime
      # dependency of the installer. These files are a handful of lines.
      config_rest_before=$(/usr/bin/grep -v '"model"[[:space:]]*:' "$config_file" || true)
      config_rest_after=$(/usr/bin/grep -v '"model"[[:space:]]*:' "$TEMPORARY_PATH" || true)
      if [ "$config_rest_before" != "$config_rest_after" ]; then
        printf 'configure-install: config.json model rewrite configured=only-the-model-line-changes observed=other-lines-differ path=%s remediation=nothing-was-written-inspect-%s\n' \
          "$config_file" "$config_file" >&2
        exit 1
      fi
      config_backup="$config_file.pre-$MODEL_FILE-$(date +%s)"
      /bin/cp "$config_file" "$config_backup" || {
        printf 'configure-install: config.json model rewrite configured=backup-written observed=copy-failed path=%s remediation=nothing-was-written-check-free-space\n' \
          "$config_backup" >&2
        exit 1
      }
      [ "$SKIP_OWNERSHIP" = "1" ] || chown root:wheel "$TEMPORARY_PATH"
      chmod 644 "$TEMPORARY_PATH"
      /bin/mv -f "$TEMPORARY_PATH" "$config_file" || {
        printf 'configure-install: config.json model rewrite configured=atomic-replace observed=mv-failed path=%s remediation=restore-from-%s\n' \
          "$config_file" "$config_backup" >&2
        exit 1
      }
      TEMPORARY_PATH=""
      printf 'configure-install: config.json model rewritten configured=%s observed=%s backup=%s\n' \
        "$MODEL_FILE" "${configured_model##*/}" "$config_backup"
      ;;
  esac
fi

if [ "$SKIP_OWNERSHIP" != "1" ]; then
  # State has its own pinned-directory transaction below. Do not touch any
  # state path before the transaction removes admin-group write access.
  while IFS= read -r -d '' path; do
    chown root:wheel "$path"
  done < <(find "$SUPPORT" -path "$STATE" -prune -o -print0)
  chown root:wheel "$AGENT_PLIST" "$WATCHDOG_PLIST"
  chown root:wheel "$LOG_ROOT"
fi

# The model converter can emit 0600/0700 paths. The per-user agent must be
# able to read the root-owned payload, while writes remain root-only. Exclude
# machine state. A package update must not operate on an admin-replaceable
# state entry before the pinned-directory transaction starts.
while IFS= read -r -d '' path; do
  chmod u=rwX,go=rX "$path"
done < <(find "$SUPPORT" -path "$STATE" -prune -o -print0)
chmod 755 "$SUPPORT/watchdog.sh" "$SUPPORT/agent-launch.sh" \
  "$SUPPORT/uninstall.sh" "$SUPPORT/reset-pin.sh" "$SUPPORT/json-tool.sh"
chmod 644 "$SUPPORT/config.json" "$SUPPORT/config.default.json" \
  "$AGENT_PLIST" "$WATCHDOG_PLIST"
chmod 1777 "$LOG_ROOT"

# Root-owned paths that live directly under that 1777 directory (2026-09-07).
# 1777 is deliberate — every account creates its own <uid>/ subdirectory and
# the sticky bit stops anyone deleting another's — but it also lets ANY account
# create the names root itself writes to: launchd opens a StandardErrorPath
# (as root) following a symlink, so a pre-placed link at such a name is a
# root write into whatever it points at. Create them here, root-owned, so nothing root touches under this root is
# ever created lazily. Replace rather than refuse: they carry diagnostics only,
# and refusing the install would hand any account a way to block every future
# update — SPEC §8 puts protection first. Keep the old watchdog.err protected
# for older jobs during update.
LOG_ROOT_ERR_FILES="watchdog.err"
if [ "$SKIP_OWNERSHIP" = "1" ]; then
  log_owner=$(id -u)
else
  log_owner=0
fi
ensure_root_log_path() {  # path dir|file mode
  local path="$1" kind="$2" mode="$3" want observed
  if [ "$kind" = dir ]; then
    want="type=Directory,owner=$log_owner"
  else
    want="type=Regular File,owner=$log_owner,links=1"
  fi
  observed=missing
  if path_exists "$path"; then
    if [ "$kind" = dir ]; then
      observed=$(/usr/bin/stat -f 'type=%HT,owner=%u' "$path" 2>/dev/null || printf unreadable)
    else
      observed=$(/usr/bin/stat -f 'type=%HT,owner=%u,links=%l' "$path" 2>/dev/null || printf unreadable)
    fi
    if [ "$observed" != "$want" ]; then
      printf 'configure-install: log-root path configured=%s observed=%s path=%q — replaced (a 1777 log root lets any account pre-place this name and root writes through a symlink)\n' \
        "$want" "$observed" "$path" >&2
      /bin/rm -rf "$path" || {
        printf 'configure-install: log-root path configured=removable observed=rm-failed path=%q remediation=remove-the-unsafe-path-as-root-and-rerun-installer\n' \
          "$path" >&2
        exit 1
      }
      observed=missing
    fi
  fi
  if [ "$observed" = missing ]; then
    if [ "$kind" = dir ]; then
      mkdir "$path" 2>/dev/null || {
        printf 'configure-install: log-root path configured=creatable observed=mkdir-failed,%s path=%q remediation=remove-the-unsafe-path-as-root-and-rerun-installer\n' \
          "$(path_observation "$path")" "$path" >&2
        exit 1
      }
    else
      # noclobber = O_EXCL: a plain `: >` follows a symlink placed here between
      # the rm above and this open (MEASURED 2026-09-07), which is the exact
      # root write this function exists to prevent. `mkdir` above already
      # fails on any existing name. After either succeeds the path is a
      # root-owned regular file or directory in a sticky directory, so nothing
      # below root can replace it before the chown/chmod below.
      ( set -C; : >"$path" ) 2>/dev/null || {
        printf 'configure-install: log-root path configured=creatable observed=create-failed,%s path=%q remediation=remove-the-unsafe-path-as-root-and-rerun-installer\n' \
          "$(path_observation "$path")" "$path" >&2
        exit 1
      }
    fi
  fi
  [ "$SKIP_OWNERSHIP" = "1" ] || chown root:wheel "$path"
  chmod "$mode" "$path"
}
# 0755 / 0644: the same world-readable contract as the per-uid logs.
# Writable by root only.
for err_file in $LOG_ROOT_ERR_FILES; do
  ensure_root_log_path "$LOG_ROOT/$err_file" file 644
done

# Machine-wide parent state. setgid preserves the admin group across atomic
# rewrites. Standard users can read the state but cannot change it.
mkdir -p "$STATE"
if [ -L "$STATE" ] || [ ! -d "$STATE" ]; then
  printf 'configure-install: state-directory configured=type-directory observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$STATE")" "$STATE" >&2
  exit 1
fi
if [ "$SKIP_OWNERSHIP" != "1" ]; then
  chown root:admin "$STATE"
fi
chmod 2775 "$STATE"
if [ "$SKIP_OWNERSHIP" = "1" ]; then
  expected_group=$(id -g)
  expected_owner=$(id -u)
else
  expected_group=$(dscl . -read /Groups/admin PrimaryGroupID | awk '{print $2}')
  expected_owner=0
fi

exec 8<"$STATE" || {
  printf 'configure-install: state-directory configured=open-directory-descriptor observed=open-failed path=%q remediation=inspect-the-state-directory-and-rerun-installer\n' \
    "$STATE" >&2
  exit 1
}
STATE_DIRECTORY_OPEN=1
state_path_inode=$(/usr/bin/stat -f '%i' "$STATE")
state_fd_inode=$(/usr/bin/stat -f '%i' /dev/fd/8)
observed_state="$(/usr/bin/stat -f '%HT' "$STATE"),owner=$(/usr/bin/stat -f '%u' "$STATE"),group=$(/usr/bin/stat -f '%g' "$STATE"),mode=$(permission_mode "$STATE"),inode=$state_path_inode,fd-inode=$state_fd_inode"
[ "$observed_state" = "Directory,owner=$expected_owner,group=$expected_group,mode=2775,inode=$state_path_inode,fd-inode=$state_path_inode" ] || {
  printf 'configure-install: state-directory configured=type-Directory,owner=%s,group=%s,mode=2775,path-inode=fd-inode observed=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$expected_owner" "$expected_group" "$observed_state" "$STATE" >&2
  exit 1
}
/bin/chmod 2755 /dev/fd/8 || {
  printf 'configure-install: state-directory-lock configured=mode=2755 observed=chmod-failed descriptor=8 remediation=inspect-state-directory-permissions\n' >&2
  exit 1
}
STATE_DIRECTORY_LOCKED=1
[ "$(permission_mode "$STATE")" = "2755" ] || {
  printf 'configure-install: state-directory-lock configured=mode=2755 observed=mode-%s path=%q remediation=inspect-state-directory-permissions\n' \
    "$(permission_mode "$STATE")" "$STATE" >&2
  exit 1
}
if path_exists "$SETTINGS_FILE"; then
  if [ -L "$SETTINGS_FILE" ] || [ ! -f "$SETTINGS_FILE" ] \
    || [ "$(/usr/bin/stat -f '%l' "$SETTINGS_FILE" 2>/dev/null || printf 0)" != "1" ]; then
    printf 'configure-install: public-settings-file configured=type-regular,links=1 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-restore-settings-from-a-trusted-copy\n' \
      "$(path_observation "$SETTINGS_FILE")" "$SETTINGS_FILE" >&2
    exit 1
  fi
  if [ "$SKIP_OWNERSHIP" != "1" ]; then
    chown root:admin "$SETTINGS_FILE"
  fi
  /bin/chmod 644 "$SETTINGS_FILE"
  SETTINGS_MODE_LOCKED=1
fi
run_test_transaction_hook state-locked
run_test_owner_swap_tripwire state

TEMPORARY_PATH=$(/usr/bin/mktemp "$STATE/.settings.json.install.XXXXXX") || {
  printf 'configure-install: public-settings-temporary configured=new-same-directory-file observed=creation-failed path=%q remediation=inspect-state-directory-permissions-and-storage\n' \
    "$STATE" >&2
  exit 1
}
if [ -L "$TEMPORARY_PATH" ] || [ ! -f "$TEMPORARY_PATH" ] \
  || [ "$(/usr/bin/stat -f '%l' "$TEMPORARY_PATH" 2>/dev/null || printf 0)" != "1" ]; then
  printf 'configure-install: public-settings-temporary configured=type-regular,links=1 observed=unsafe-path,details=%s path=%q remediation=inspect-the-state-directory-and-rerun-installer\n' \
    "$(path_observation "$TEMPORARY_PATH")" "$TEMPORARY_PATH" >&2
  exit 1
fi
if path_exists "$SETTINGS_FILE"; then
  if [ -L "$SETTINGS_FILE" ] || [ ! -f "$SETTINGS_FILE" ] \
    || [ "$(/usr/bin/stat -f '%l' "$SETTINGS_FILE" 2>/dev/null || printf 0)" != "1" ]; then
    printf 'configure-install: public-settings-file configured=type-regular,links=1 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-restore-settings-from-a-trusted-copy\n' \
      "$(path_observation "$SETTINGS_FILE")" "$SETTINGS_FILE" >&2
    exit 1
  fi
  /bin/cp "$SETTINGS_FILE" "$TEMPORARY_PATH"
else
  printf '{"version":2}\n' > "$TEMPORARY_PATH"
fi

# Retire the old public verifier without migration. A verifier that was ever
# readable by a Standard account is not trusted in the protected authority.
# The parent must create a new PIN after this security update. Later secure
# updates preserve parent/pin.json byte-for-byte.
if ! json_error=$("$JSON_TOOL" validate "$TEMPORARY_PATH" 2>&1); then
  settings_bytes=$(/usr/bin/wc -c < "$TEMPORARY_PATH" | /usr/bin/tr -d ' ')
  settings_sha256=$(/usr/bin/shasum -a 256 "$TEMPORARY_PATH" | /usr/bin/awk '{print $1}')
  printf 'configure-install: public settings configured=parseable-JSON observed=invalid bytes=%s sha256=%s json-tool=%q path=%q remediation=repair-or-remove-the-damaged-settings-file\n' \
    "$settings_bytes" "$settings_sha256" "$json_error" "$SETTINGS_FILE" >&2
  exit 1
fi
settings_version=$("$JSON_TOOL" get "$TEMPORARY_PATH" version 2>/dev/null) || {
  printf 'configure-install: public-settings-version configured=integer-1-or-2 observed=missing-or-invalid path=%q remediation=repair-the-public-settings-file\n' \
    "$SETTINGS_FILE" >&2
  exit 1
}
case "$settings_version" in
  1|2) ;;
  *)
    printf 'configure-install: public-settings-version configured=1-or-2 observed=%s path=%q remediation=install-a-newer-SentryScreen-build\n' \
      "$settings_version" "$SETTINGS_FILE" >&2
    exit 1
    ;;
esac
legacy_verifier_present=0
if [ "$("$JSON_TOOL" type "$TEMPORARY_PATH" pin)" = "dictionary" ]; then
  legacy_verifier_present=1
fi
for retired_key in pin pinFailures; do
  if [ "$("$JSON_TOOL" has "$TEMPORARY_PATH" "$retired_key")" = "true" ]; then
    "$JSON_TOOL" remove "$TEMPORARY_PATH" "$retired_key" || {
      printf 'configure-install: retired-field-removal configured=absent observed=present key=%s path=%q remediation=repair-the-public-settings-file\n' \
        "$retired_key" "$SETTINGS_FILE" >&2
      exit 1
    }
  fi
done
if [ "$legacy_verifier_present" = "1" ] \
  && [ "$("$JSON_TOOL" has "$TEMPORARY_PATH" onboarding.successShownAt)" = "true" ]; then
  "$JSON_TOOL" set "$TEMPORARY_PATH" onboarding.successShownAt null || {
    printf 'configure-install: onboarding-confirmation configured=successShownAt-null-after-legacy-verifier-removal observed=update-failed path=%q remediation=repair-the-public-settings-file\n' \
      "$SETTINGS_FILE" >&2
    exit 1
  }
fi
if [ "$settings_version" = "1" ]; then
  "$JSON_TOOL" set "$TEMPORARY_PATH" version 2 || {
    printf 'configure-install: public-settings-version configured=2 observed=1 path=%q remediation=repair-the-public-settings-file\n' \
      "$SETTINGS_FILE" >&2
    exit 1
  }
fi
if [ "$SKIP_OWNERSHIP" != "1" ]; then
  chown root:admin "$TEMPORARY_PATH"
fi
chmod 600 "$TEMPORARY_PATH"
observed_settings="$(stat -f '%HT' "$TEMPORARY_PATH"),owner=$(stat -f '%u' "$TEMPORARY_PATH"),group=$(stat -f '%g' "$TEMPORARY_PATH"),mode=$(permission_mode "$TEMPORARY_PATH"),links=$(stat -f '%l' "$TEMPORARY_PATH")"
[ "$observed_settings" = "Regular File,owner=$expected_owner,group=$expected_group,mode=600,links=1" ] || {
  printf 'configure-install: public-settings-temporary configured=type-Regular-File,owner=%s,group=%s,mode=600,links=1 observed=%s path=%q remediation=inspect-the-state-directory-and-rerun-installer\n' \
    "$expected_owner" "$expected_group" "$observed_settings" "$TEMPORARY_PATH" >&2
  exit 1
}
/bin/mv -fh "$TEMPORARY_PATH" "$SETTINGS_FILE" || {
  printf 'configure-install: public-settings-install configured=atomic-same-directory-rename observed=rename-failed path=%q remediation=inspect-the-state-directory-and-rerun-installer\n' \
    "$SETTINGS_FILE" >&2
  exit 1
}
TEMPORARY_PATH=""
SETTINGS_MODE_LOCKED=1

if [ -L "$PARENT_PIN_ROOT" ] \
  || { path_exists "$PARENT_PIN_ROOT" && [ ! -d "$PARENT_PIN_ROOT" ]; }; then
  printf 'configure-install: parent-PIN-directory configured=type-directory,group=admin,mode=2770 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$PARENT_PIN_ROOT")" "$PARENT_PIN_ROOT" >&2
  exit 1
fi
mkdir -p "$PARENT_PIN_ROOT"
if [ -L "$PARENT_PIN_ROOT" ] || [ ! -d "$PARENT_PIN_ROOT" ]; then
  printf 'configure-install: parent-PIN-directory configured=type-directory,group=admin,mode=2770 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$PARENT_PIN_ROOT")" "$PARENT_PIN_ROOT" >&2
  exit 1
fi
if [ "$SKIP_OWNERSHIP" != "1" ]; then
  chown root:admin "$PARENT_PIN_ROOT"
fi
chmod 2770 "$PARENT_PIN_ROOT"

exec 9<"$PARENT_PIN_ROOT" || {
  printf 'configure-install: parent-PIN-directory configured=open-directory-descriptor observed=open-failed path=%q remediation=inspect-parent-directory-permissions\n' \
    "$PARENT_PIN_ROOT" >&2
  exit 1
}
PARENT_DIRECTORY_OPEN=1
parent_path_inode=$(/usr/bin/stat -f '%i' "$PARENT_PIN_ROOT")
parent_fd_inode=$(/usr/bin/stat -f '%i' /dev/fd/9)
observed_parent="$(/usr/bin/stat -f '%HT' "$PARENT_PIN_ROOT"),owner=$(/usr/bin/stat -f '%u' "$PARENT_PIN_ROOT"),group=$(/usr/bin/stat -f '%g' "$PARENT_PIN_ROOT"),mode=$(permission_mode "$PARENT_PIN_ROOT"),inode=$parent_path_inode,fd-inode=$parent_fd_inode"
[ "$observed_parent" = "Directory,owner=$expected_owner,group=$expected_group,mode=2770,inode=$parent_path_inode,fd-inode=$parent_path_inode" ] || {
  printf 'configure-install: parent-PIN-directory configured=type-Directory,owner=%s,group=%s,mode=2770,path-inode=fd-inode observed=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$expected_owner" "$expected_group" "$observed_parent" "$PARENT_PIN_ROOT" >&2
  exit 1
}
/bin/chmod 2750 /dev/fd/9 || {
  printf 'configure-install: parent-PIN-directory-lock configured=mode=2750 observed=chmod-failed descriptor=9 remediation=inspect-parent-directory-permissions\n' >&2
  exit 1
}
PARENT_DIRECTORY_LOCKED=1
[ "$(permission_mode "$PARENT_PIN_ROOT")" = "2750" ] || {
  printf 'configure-install: parent-PIN-directory-lock configured=mode=2750 observed=mode-%s path=%q remediation=inspect-parent-directory-permissions\n' \
    "$(permission_mode "$PARENT_PIN_ROOT")" "$PARENT_PIN_ROOT" >&2
  exit 1
}

if path_exists "$PARENT_PIN_FILE" && {
  [ -L "$PARENT_PIN_FILE" ] || [ ! -f "$PARENT_PIN_FILE" ] \
    || [ "$(/usr/bin/stat -f '%l' "$PARENT_PIN_FILE" 2>/dev/null || printf 0)" != "1" ]
}; then
  printf 'configure-install: parent-PIN-file configured=type-regular,group=admin,mode=0660,links=1 observed=unsafe-path,details=%s path=%q remediation=remove-the-unsafe-path-and-rerun-installer\n' \
    "$(path_observation "$PARENT_PIN_FILE")" "$PARENT_PIN_FILE" >&2
  exit 1
fi
if path_exists "$PARENT_PIN_FILE"; then
  if [ "$SKIP_OWNERSHIP" != "1" ]; then
    chown root:admin "$PARENT_PIN_FILE"
  fi
  /bin/chmod 600 "$PARENT_PIN_FILE"
  PIN_MODE_LOCKED=1
  observed_pin_owner=$(/usr/bin/stat -f '%u' "$PARENT_PIN_FILE")
  [ "$observed_pin_owner" = "$expected_owner" ] || {
    printf 'configure-install: parent-PIN-file configured=owner=%s observed=owner-%s path=%q remediation=rerun-installer-permission-repair\n' \
      "$expected_owner" "$observed_pin_owner" "$PARENT_PIN_FILE" >&2
    exit 1
  }
fi
run_test_transaction_hook parent-locked
run_test_owner_swap_tripwire parent
if ! path_exists "$PARENT_PIN_FILE"; then
  TEMPORARY_PATH=$(/usr/bin/mktemp "$PARENT_PIN_ROOT/.pin.json.install.XXXXXX") || {
    printf 'configure-install: parent-PIN-temporary configured=new-same-directory-file observed=creation-failed path=%q remediation=inspect-parent-directory-permissions-and-storage\n' \
      "$PARENT_PIN_ROOT" >&2
    exit 1
  }
  printf '{"version":1}\n' > "$TEMPORARY_PATH"
  chmod 600 "$TEMPORARY_PATH"
  if [ "$SKIP_OWNERSHIP" != "1" ]; then
    chown root:admin "$TEMPORARY_PATH"
  fi
  observed_temporary="$(stat -f '%HT' "$TEMPORARY_PATH"),owner=$(stat -f '%u' "$TEMPORARY_PATH"),group=$(stat -f '%g' "$TEMPORARY_PATH"),mode=$(permission_mode "$TEMPORARY_PATH"),links=$(stat -f '%l' "$TEMPORARY_PATH")"
  [ "$observed_temporary" = "Regular File,owner=$expected_owner,group=$expected_group,mode=600,links=1" ] || {
    printf 'configure-install: parent-PIN-temporary configured=type-Regular-File,owner=%s,group=%s,mode=600,links=1 observed=%s path=%q remediation=inspect-parent-directory-permissions-and-rerun-installer\n' \
      "$expected_owner" "$expected_group" "$observed_temporary" "$TEMPORARY_PATH" >&2
    exit 1
  }
  /bin/mv -fh "$TEMPORARY_PATH" "$PARENT_PIN_FILE" || {
    printf 'configure-install: parent-PIN-install configured=atomic-same-directory-rename observed=rename-failed path=%q remediation=inspect-parent-directory-permissions-and-rerun-installer\n' \
      "$PARENT_PIN_FILE" >&2
    exit 1
  }
  TEMPORARY_PATH=""
  PIN_MODE_LOCKED=1
fi

observed_directory="$(stat -f '%HT' "$PARENT_PIN_ROOT"),owner=$(stat -f '%u' "$PARENT_PIN_ROOT"),group=$(stat -f '%g' "$PARENT_PIN_ROOT"),mode=$(permission_mode "$PARENT_PIN_ROOT")"
observed_file="$(stat -f '%HT' "$PARENT_PIN_FILE"),owner=$(stat -f '%u' "$PARENT_PIN_FILE"),group=$(stat -f '%g' "$PARENT_PIN_FILE"),mode=$(permission_mode "$PARENT_PIN_FILE"),links=$(stat -f '%l' "$PARENT_PIN_FILE")"
[ "$observed_directory" = "Directory,owner=$expected_owner,group=$expected_group,mode=2750" ] || {
  printf 'configure-install: parent-PIN-directory configured=type-Directory,owner=%s,group=%s,mode=2750-during-root-transaction observed=%s path=%q remediation=rerun-installer-permission-repair\n' \
    "$expected_owner" "$expected_group" "$observed_directory" "$PARENT_PIN_ROOT" >&2
  exit 1
}
[ "$observed_file" = "Regular File,owner=$expected_owner,group=$expected_group,mode=600,links=1" ] || {
  printf 'configure-install: parent-PIN-file configured=type-Regular-File,owner=%s,group=%s,mode=600-during-root-transaction,links=1 observed=%s path=%q remediation=rerun-installer-permission-repair\n' \
    "$expected_owner" "$expected_group" "$observed_file" "$PARENT_PIN_FILE" >&2
  exit 1
}

restore_root_transaction || exit 1
observed_final="state-mode=$(permission_mode "$STATE"),settings-mode=$(permission_mode "$SETTINGS_FILE"),parent-mode=$(permission_mode "$PARENT_PIN_ROOT"),pin-mode=$(permission_mode "$PARENT_PIN_FILE")"
[ "$observed_final" = "state-mode=2775,settings-mode=664,parent-mode=2770,pin-mode=660" ] || {
  printf 'configure-install: state-transaction-restore configured=state-2775,settings-664,parent-2770,pin-660 observed=%s remediation=rerun-installer-permission-repair\n' \
    "$observed_final" >&2
  exit 1
}

# Stale model payloads (G6, 2026-09-02). An update replaces only the basename
# it ships, so a model swap leaves the PREVIOUS *.mlpackage in the support
# directory. Now that the config rewrite above repoints the daemon, that
# leftover is inert — but it is real disk (the shipped payload is ~18 MB) and
# a future reader must not mistake it for the model in use.
#
# DECIDED 2026-09-02: report, do NOT delete. Deleting is one bad interaction
# away from the failure mode RUNBOOK stage 12 already documents — a config
# naming a model that is not there makes the daemon exit 4 and the watchdog
# kickstart it in a loop — and rollback/roll-forward paths that might want the
# old payload are not proven to re-stage it. This script otherwise only adds
# and configures; deleting a payload it did not ship would be a new class of
# destructive behavior, and reclaiming disk is not what G6 blocked. Removal
# stays a deliberate operator action (packaging/uninstall.sh sweeps the whole
# support directory). Scope: this directory only, this extension only,
# symlinks never followed.
while IFS= read -r -d '' stale_payload; do
  printf 'configure-install: stale model payload retained configured=%s observed=%s path=%s remediation=remove-it-deliberately-once-the-new-model-is-proven\n' \
    "$MODEL_FILE" "${stale_payload##*/}" "$stale_payload"
done < <(find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -type l \
  -name '*.mlpackage' ! -name "$MODEL_FILE" -print0 2>/dev/null)

# Trusted compiled model (T3, security review 2026-09-28). The agent runs as
# the protected account, and until this date it loaded a compiled model from
# that account's own Caches folder, which the account can replace. The agent
# now loads a compiled model only from beside the root-owned package, and only
# when every file in it is owned by root and not group/other-writable
# (Detector.swift CacheTrust); anything else is refused, reported as tamper,
# and the model is compiled into a private temporary copy for that launch.
# This compiles the trusted copy once, here, as root. `env -i`: nothing from
# the installer's environment reaches the daemon binary. Never fatal: without
# it every launch still protects, just after a slower temporary compile, and
# the agent names that in its log.
if [ -z "$ROOT_PREFIX" ]; then
  if compile_result="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root \
      "$SUPPORT/SentryScreen.app/Contents/MacOS/sentry-screen" --compile-model-cache "$SUPPORT/$MODEL_FILE" 2>&1)"; then
    printf 'configure-install: %s\n' "$compile_result"
  else
    printf 'configure-install: trusted compiled model configured=root-owned-entry-beside-%s observed=compile-failed detail=%s remediation=agent-compiles-a-temporary-copy-each-launch;rerun-installer\n' \
      "$MODEL_FILE" "$(printf '%s' "$compile_result" | tr '\n' ' ')" >&2
  fi
fi

if [ "$SKIP_LAUNCHD" = "1" ]; then
  echo "configure-install: payload configured; launchd skipped"
  exit 0
fi
[ -z "$ROOT_PREFIX" ] || {
  echo "configure-install: launchd cannot run with SENTRY_INSTALL_ROOT" >&2
  exit 64
}

# Replacing a plist does not replace launchd's loaded definition.
# MEASURED 2026-09-17: the exact package passed byte verification but the
# loaded watchdog retained its old stderr path under the missing log root.
# Reload it on install; never wait for a reboot.
#
# The watchdog stays parked (booted out) for the whole launchd section below
# and is reloaded from the new plist at its end. MEASURED 2026-09-20
# (macOS 27 test Mac): a loaded watchdog re-bootstrapped gui/501's agent while the
# postinstall was draining it, so the agent's BOOTOUT_WAIT failed the
# install. Parking it before the legacy cleanup, not just before the agent handoff,
# makes every exit after that point consistent: success reloads it, and any
# failure reaches the EXIT trap, which reloads a parked watchdog from the new
# plist (restore_parked_watchdog). No path leaves the old definition loaded
# unless the watchdog's own bootout or drain failed, and that failure is named.
park_watchdog() {
  WATCHDOG_PARKED=1
  if launchctl print system/com.sentryscreen.watchdog >/dev/null 2>&1; then
    launchctl bootout system/com.sentryscreen.watchdog || {
      echo 'configure-install: watchdog configured=unloaded observed=bootout-failed remediation=inspect-system/com.sentryscreen.watchdog' >&2
      return 1
    }
    # BOOTOUT_WAIT: same 10 s / 0.1 s drain as the agent below.
    # Receipt: the installed watchdog pass completed within 1 s on
    # 2026-09-17. Ten seconds also preserves the existing installer allowance.
    local i=0
    while launchctl print system/com.sentryscreen.watchdog >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if launchctl print system/com.sentryscreen.watchdog >/dev/null 2>&1; then
      echo 'configure-install: BOOTOUT_WAIT configured=10s observed=watchdog-still-loaded remediation=inspect-system/com.sentryscreen.watchdog' >&2
      return 1
    fi
  fi
}
reload_watchdog() {
  park_watchdog || return 1
  launchctl bootstrap system "$WATCHDOG_PLIST" || {
    echo 'configure-install: watchdog configured=current-plist-loaded observed=bootstrap-failed remediation=inspect-system/com.sentryscreen.watchdog' >&2
    return 1
  }
  WATCHDOG_PARKED=0
}
# EXIT-trap half. A watchdog still loaded here is one whose bootout or drain
# failed; that failure was already named and launchd keeps that job.
restore_parked_watchdog() {
  if ! launchctl print system/com.sentryscreen.watchdog >/dev/null 2>&1; then
    launchctl bootstrap system "$WATCHDOG_PLIST" || {
      echo 'configure-install: watchdog configured=current-plist-loaded observed=recovery-bootstrap-failed-after-install-error remediation=inspect-system/com.sentryscreen.watchdog' >&2
      return 1
    }
    echo 'configure-install: watchdog reloaded from the current plist after an install error'
  fi
  WATCHDOG_PARKED=0
}
park_watchdog || exit 1
# Legacy cleanup: the retired parent-helper root daemon (older installs).
launchctl bootout system/com.sentryscreen.parent-helper 2>/dev/null || true
rm -f "$LEGACY_HELPER_PLIST" "$SUPPORT/sentry-screen-helper"
# Retired background updater (pre-open-source installs): stop it and remove
# its files so an upgrade leaves no job that contacts a server.
if launchctl print system/com.sentryscreen.updater >/dev/null 2>&1; then
  launchctl bootout system/com.sentryscreen.updater 2>/dev/null \
    || echo "configure-install: legacy updater bootout failed; removing its files anyway" >&2
fi
rm -f "$LEGACY_UPDATER_PLIST" "$SUPPORT/sentry-screen-updater" "$SUPPORT/updater.json" \
  "$SUPPORT/updater.lock"
rm -rf "$SUPPORT/updates"

# Receipt: an ad-hoc signed app's designated requirement is its cdhash, so a
# Screen Recording row written for the previous build never matches the new
# one. Upgrading 0.3.0 -> 0.4.0 on the Mac Studio (2026-10-16) left a row that
# showed "on" while CGPreflightScreenCaptureAccess stayed false: an endless
# "permission-repair state=required" relaunch loop. Resetting the row makes the
# next launch ask fresh. The same holds when the REPLACED app was ad-hoc (an
# ad-hoc -> Developer ID upgrade): the row still names the old cdhash, so the
# pkg preinstall leaves a marker for it. Developer ID -> Developer ID is
# skipped: that requirement names the team and survives updates. Isolated
# roots never touch real TCC.
PREVIOUS_ADHOC_MARKER="$SUPPORT/.previous-app-adhoc"
if [ "$SKIP_LAUNCHD" != "1" ]; then
  tcc_reason=""
  if /usr/bin/codesign -dv "$SUPPORT/SentryScreen.app" 2>&1 | grep '^Signature=adhoc$' >/dev/null; then
    tcc_reason="installed-app-adhoc"
  elif [ -f "$PREVIOUS_ADHOC_MARKER" ]; then
    tcc_reason="previous-app-adhoc"
  fi
  if [ -n "$tcc_reason" ]; then
    if /usr/bin/tccutil reset ScreenCapture com.sentryscreen.agent >/dev/null 2>&1; then
      echo "configure-install: tcc-reset service=ScreenCapture reason=$tcc_reason result=reset"
    else
      echo "configure-install: tcc-reset service=ScreenCapture reason=$tcc_reason result=failed remediation=tccutil-reset-ScreenCapture-com.sentryscreen.agent" >&2
    fi
  fi
fi
rm -f "$PREVIOUS_ADHOC_MARKER"

for u in $(who | awk '$2=="console"{print $1}' | sort -u); do
  uid="$(id -u "$u" 2>/dev/null)" || continue
  [ "$uid" != "0" ] || continue
  # `who` can retain a console row after logout (macOS 27 test Mac, 2026-09-20).
  # An absent gui domain has no agent to restart, and bootstrapping it fails
  # the install (status 125 for the gui/503 bootstrap).
  if ! launchctl print "gui/$uid" >/dev/null 2>&1; then
    echo "configure-install: console row for uid $uid has no live gui/$uid domain (logged out); no agent to restart"
    continue
  fi
  launchctl bootout "gui/$uid/com.sentryscreen.agent" 2>/dev/null || true
  # bootout is asynchronous (the wrapper forwards TERM and waits for the
  # daemon). Bootstrapping immediately fails while the old job drains, and the
  # old fallback — "print still succeeds, so call it bootstrapped" — accepted
  # the DRAINING job as success: the agent then vanished until the watchdog
  # re-bootstrapped it ~60 s later (MEASURED 2026-08-29 08:06→08:07:56Z, plain
  # install.sh over a running agent). Same tripwire as uninstall.sh
  # BOOTOUT_WAIT: 10 s, ASSUMED (observed 0.0 s); print the observed wait.
  i=0
  while launchctl print "gui/$uid/com.sentryscreen.agent" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
    sleep 0.1; i=$((i + 1))
  done
  if launchctl print "gui/$uid/com.sentryscreen.agent" >/dev/null 2>&1; then
    echo "configure-install: bootout of gui/$uid/com.sentryscreen.agent still draining after 10 s (tripwire BOOTOUT_WAIT in packaging/pkg-scripts/configure-install.sh)" >&2
    exit 1
  fi
  if ! launchctl bootstrap "gui/$uid" "$AGENT_PLIST"; then
    # The user can log out between the domain check and this bootstrap.
    if ! launchctl print "gui/$uid" >/dev/null 2>&1; then
      echo "configure-install: gui/$uid ended during agent handoff; no job to restart"
      continue
    fi
    echo "configure-install: bootstrap FAILED for gui/$uid ($u)" >&2
    exit 1
  fi
  echo "configure-install: agent (re)bootstrapped into gui/$uid ($u) after bootout drain of $((i / 10)).$((i % 10)) s"
done

reload_watchdog || exit 1

echo "configure-install: installed; Screen Recording requires manual approval"
