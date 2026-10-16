#!/bin/bash
# install-preflight.sh <build-dir> — check that the app in <build-dir>
# is the app packaging/bundle.sh signed (identifier, valid signatures, one
# Team ID, every architecture slice, hardened runtime) before an installer
# copies it. Writes nothing and needs no root. The build directory is an
# argument, not an environment variable, so an exported value cannot steer
# what `sudo packaging/install.sh` copies.
set -euo pipefail

BUILD_DIR_ARG="${1:-}"
[ -n "$BUILD_DIR_ARG" ] || { echo "usage: $0 <build-dir>" >&2; exit 64; }
# Resolve against the CALLER's working directory, before the cd below.
[ -d "$BUILD_DIR_ARG" ] || {
  echo "install-preflight: FAIL name=build_dir configured=existing-directory observed=missing path=$BUILD_DIR_ARG remediation=scripts/build.sh + packaging/bundle.sh" >&2
  exit 1
}
BUILD_DIR="$(cd "$BUILD_DIR_ARG" && pwd)"

cd "$(dirname "$0")/.."
# The script changes to the runtime repo root first.
# shellcheck disable=SC1091
source packaging/release.env

fail() {
  echo "install-preflight: FAIL $*" >&2
  exit 1
}

# `lipo -archs` prints Mach-O order; compare C-locale sorted, comma joined.
# shellcheck disable=SC2086
sorted_archs() { printf '%s\n' $1 | LC_ALL=C /usr/bin/sort -u | /usr/bin/paste -sd, -; }
EXPECTED_ARCHS=$(sorted_archs "$SENTRY_ARCHS")
# Same self-guard the other two carry: the messages below print EXPECTED_ARCHS
# while the tests that read them grep for the derived SENTRY_ARCH, and those
# two strings are equal only while SENTRY_ARCHS is stored C-locale sorted.
# Reordering it would make every message look right and every grep miss.
[ "$EXPECTED_ARCHS" = "$SENTRY_ARCH" ] || \
  fail "name=architecture_list configured=C-locale-sorted observed='$SENTRY_ARCHS' remediation=packaging/release.env (SENTRY_ARCHS must be sorted; SENTRY_ARCH is its comma join)"

# Set by the app pass.
APP_TEAM=""

# check_artifact <name> <signed-object> <mach-o> <expected-identifier> <verify-deep 0|1>
#
# Order is load-bearing, so a failure names the thing that is actually wrong:
# presence, identifier, whole-object validity, Team ID, the architecture SET,
# then per-slice validity and hardened runtime. The architecture set comes
# before the per-slice loop because a thin binary would otherwise report
# "slice signature invalid" for a slice it simply does not have.
check_artifact() {
  local name="$1" object="$2" macho="$3" expected_id="$4" deep="$5"
  local signature identifier team observed_archs slice

  [ -x "$macho" ] || \
    fail "name=${name}_present configured=executable observed=missing path=$macho remediation=scripts/build.sh + packaging/bundle.sh"

  # `codesign -d` writes to stderr; -dvvv is what prints CDHash/Identifier.
  signature=$(/usr/bin/codesign -dvvv "$object" 2>&1 || true)
  identifier=$(printf '%s\n' "$signature" | /usr/bin/awk -F= '/^Identifier=/ { print $2 }')
  team=$(printf '%s\n' "$signature" | /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2 }')
  [ "$identifier" = "$expected_id" ] || \
    fail "name=${name}_signature_identifier configured=$expected_id observed='${identifier:-none}' path=$object remediation=bash packaging/bundle.sh (something rebuilt or replaced the build directory after bundling)"

  if [ "$deep" = 1 ]; then
    /usr/bin/codesign --verify --deep --strict "$object" 2>/dev/null || \
      fail "name=${name}_signature_valid configured=strict-valid observed=invalid path=$object remediation=bash packaging/bundle.sh"
  else
    /usr/bin/codesign --verify --strict "$object" 2>/dev/null || \
      fail "name=${name}_signature_valid configured=strict-valid observed=invalid path=$object remediation=bash packaging/bundle.sh"
  fi

  team="${team:-not set}"
  APP_TEAM="$team"
  # SENTRY_ALLOW_ADHOC_INSTALL waives THIS assertion and nothing else: an
  # ad-hoc designated requirement is `cdhash H"..."`, unique per build, so a
  # machine whose Screen Recording grant is on a certificate DR would lose it
  # (packaging/bundle.sh header, "TCC thrash").
  if [ "$team" = "not set" ] && [ "${SENTRY_ALLOW_ADHOC_INSTALL:-0}" != 1 ]; then
    fail "name=app_team_id configured=Team-ID-signed observed=adhoc-or-unsigned path=$object remediation=bash packaging/bundle.sh with the Apple Development identity, or SENTRY_ALLOW_ADHOC_INSTALL=1 on a machine whose Screen Recording grant is not on a certificate DR"
  fi

  observed_archs=$(sorted_archs "$(/usr/bin/lipo -archs "$macho" 2>/dev/null || echo unreadable)")
  [ "$observed_archs" = "$EXPECTED_ARCHS" ] || \
    fail "name=${name}_architectures configured=$SENTRY_ARCH observed=${observed_archs:-unreadable} path=$macho remediation=scripts/build.sh (a SENTRY_BUILD_ARCHS=arm64 build leaves a thin binary in the build directory)"

  # Per slice, not once for the file: a universal binary carries ONE signature
  # per slice, and `codesign --verify` without --arch validates only the slice
  # this Mac would run. `--arch` selects a slice of a MACH-O FILE, so the app is
  # addressed through its executable rather than through the bundle directory.
  for slice in $SENTRY_ARCHS; do
    /usr/bin/codesign --verify --strict --arch "$slice" "$macho" 2>/dev/null || \
      fail "name=${name}_slice_signature arch=$slice configured=strict-valid observed=invalid path=$macho remediation=bash packaging/bundle.sh"
    # `grep >/dev/null`, not `grep -q`: -q exits at the first match, and under
    # `set -o pipefail` the SIGPIPE it can deliver to codesign would fail the
    # pipeline on a signature that is CORRECT. Same form as packaging/bundle.sh.
    /usr/bin/codesign -dv --verbose=4 --arch "$slice" "$macho" 2>&1 \
      | /usr/bin/grep 'flags=.*runtime' >/dev/null || \
      fail "name=${name}_hardened_runtime arch=$slice configured=present observed=absent path=$macho remediation=bash packaging/bundle.sh (--options runtime)"
  done
}

APP="$BUILD_DIR/SentryScreen.app"
check_artifact app "$APP" "$APP/Contents/MacOS/$SENTRY_EXECUTABLE" "$SENTRY_BUNDLE_ID" 1

# One value per field: an ad-hoc Team ID reads back as "not set", and a space
# inside a value would break the key=value line every log reader parses.
echo "install-preflight: PASS build_dir=$BUILD_DIR artifacts=app identifiers=checked signature=strict-valid team=${APP_TEAM// /-} slices=$SENTRY_ARCH hardened_runtime=per-slice"
