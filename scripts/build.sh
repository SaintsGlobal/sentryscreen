#!/bin/bash
# No-Xcode build: compile directly with swiftc. Do not use swift build or
# xcodebuild; the Command Line Tools SwiftPM manifest library fails to link
# Package.swift on some hosts.
set -euo pipefail
if [ "$#" -ne 0 ]; then
  echo "build: arguments configured=none observed='$*' remediation=scripts/build.sh takes no arguments" >&2
  exit 64
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT/daemon"
# SENTRY_SRC / SENTRY_OUT build from another source copy into another output.
SRC_DIR="${SENTRY_SRC:-$PWD/Sources/SentryScreen}"
OUT="${SENTRY_OUT:-$PWD/.build/sentry-screen}"
RELEASE_ENV="$ROOT/packaging/release.env"
[ -f "$RELEASE_ENV" ] || { echo "build: missing $RELEASE_ENV" >&2; exit 1; }
# Path is resolved from the runtime repo root.
# shellcheck disable=SC1090,SC1091
source "$RELEASE_ENV"

# Each executable is compiled once per architecture in SENTRY_ARCHS
# (packaging/release.env) and joined with lipo.
#   SENTRY_TARGET       one exact triple -> one thin slice, nothing joined.
#   SENTRY_BUILD_ARCHS  override the architecture list (for example arm64 for a
#                       fast development build). packaging/build-pkg.sh always
#                       builds the full SENTRY_ARCHS list.
BUILD_ARCHS="${SENTRY_BUILD_ARCHS:-$SENTRY_ARCHS}"
# Every swiftc line starts from this list; it is never empty, so bash 3.2's
# set -u accepts its expansion.
swift_flags=(-O)
# Count the architectures after word splitting; an all-whitespace value is an error.
build_archs=()
for build_arch in $BUILD_ARCHS; do
  build_archs+=("$build_arch")
done
[ "${#build_archs[@]}" -gt 0 ] || {
  echo "build: architecture list configured=one-or-more observed='$BUILD_ARCHS' remediation=SENTRY_BUILD_ARCHS or packaging/release.env:SENTRY_ARCHS" >&2
  exit 64
}

# Per-slice temporaries never outlive the build, and a failed build leaves no binary.
build_temps=()
cleanup_build_temps() {
  [ "${#build_temps[@]}" -eq 0 ] || /bin/rm -f "${build_temps[@]}"
}
trap cleanup_build_temps EXIT

# build_one <label> <source-dir> <output-path>
build_one() {
  local label="$1" src="$2" out="$3"
  shift 3
  local sources=()
  if [ "$#" -gt 0 ]; then sources=("$@"); else sources=("$src"/*.swift); fi
  local arch slice
  local slices=()
  mkdir -p "$(dirname "$out")"
  # Before compiling, not after: the output is invalid from this point until
  # the build finishes, and saying so on disk is cheaper than any later check.
  /bin/rm -f "$out"
  if [ -n "${SENTRY_TARGET:-}" ]; then
    swiftc "${swift_flags[@]}" -target "$SENTRY_TARGET" -o "$out" "${sources[@]}"
    echo "built: $out (from $src, target $SENTRY_TARGET)"
    return
  fi
  for arch in "${build_archs[@]}"; do
    slice="$out.$arch"
    build_temps+=("$slice")
    swiftc "${swift_flags[@]}" -target "${arch}-apple-macosx${SENTRY_MIN_MACOS}" -o "$slice" "${sources[@]}"
    slices+=("$slice")
  done
  if [ "${#slices[@]}" -eq 1 ]; then
    /bin/mv -f "${slices[0]}" "$out"
  else
    # lipo into a temporary and move: a lipo that fails partway must not leave
    # a truncated file at the path everything else treats as the build output.
    /usr/bin/lipo -create "${slices[@]}" -output "$out.fat"
    build_temps+=("$out.fat")
    /bin/mv -f "$out.fat" "$out"
    /bin/rm -f "${slices[@]}"
  fi
  echo "built: $out (from $src, archs ${build_archs[*]}, min macOS $SENTRY_MIN_MACOS) [$label]"
}


# SDK preflight: type-check a tiny SwiftUI file against the SDK in use
# (SDKROOT, or xcrun's default) and stop early, by name, if this swiftc cannot
# compile the app's SwiftUI against it. Some Command Line Tools SDKs fail on
# `@State`; the message names an SDK that works when one is installed.
sdk_refuse() {
  echo "build: $1" >&2
  /bin/rm -f "$OUT"
  exit 1
}
sdk_preflight() {
  local sdk version developer_dir candidate fix probe_dir target status err
  sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
  [ -n "$sdk" ] && [ -d "$sdk" ] && sdk="$(cd "$sdk" && pwd -P)" \
    || sdk_refuse "sdk configured=a macOS SDK from SDKROOT or xcrun observed=none (SDKROOT='${SDKROOT:-}') remediation=install Apple Command Line Tools or set SDKROOT"
  version="$(xcrun --show-sdk-version 2>/dev/null || echo unknown)"
  target="${SENTRY_TARGET:-${build_archs[0]}-apple-macosx${SENTRY_MIN_MACOS}}"
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/sentry-sdk-probe.XXXXXX" 2>/dev/null)" \
    || sdk_refuse "sdk-probe configured=a temporary directory observed=mktemp failed under TMPDIR='${TMPDIR:-/tmp}' remediation=point TMPDIR at a writable directory"
  printf '%s\n' 'import SwiftUI' \
    'struct SDKProbe: View { @State private var on = false' \
    '  var body: some View { Toggle("probe", isOn: $on) } }' > "$probe_dir/probe.swift"
  status=0
  swiftc -typecheck -target "$target" "$probe_dir/probe.swift" > "$probe_dir/out" 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    /bin/rm -rf "$probe_dir"
    echo "build: sdk=$sdk version=$version probe=swiftui-typecheck-PASS target=$target"
    return
  fi
  err="$(grep -m1 'error:' "$probe_dir/out" | sed 's/^.*error: //' || true)"
  if [ -z "$err" ]; then
    # No compiler diagnostic: the compiler itself failed (crash, missing
    # swiftc), which is not evidence against the SDK.
    err="$(tail -n 1 "$probe_dir/out" || true)"
    /bin/rm -rf "$probe_dir"
    sdk_refuse "swiftc-probe configured=swiftc type-checks a SwiftUI probe observed=exit $status without a compiler error ('$err') sdk=$sdk remediation=check the swiftc on PATH ($(command -v swiftc || echo none)) before changing the SDK"
  fi
  /bin/rm -rf "$probe_dir"
  developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
  candidate="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  [ -d "$candidate" ] || candidate=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  if [ -d "$candidate" ] && [ "$(cd "$candidate" && pwd -P)" != "$sdk" ]; then
    fix="prefix the command with SDKROOT=$candidate"
  else
    fix="no other known SDK on this host; set SDKROOT to an installed macOS SDK"
  fi
  sdk_refuse "sdk configured=an SDK this swiftc can typecheck SwiftUI against observed=$sdk version=$version target=$target error='$err' remediation=$fix"
}
sdk_preflight
build_one agent "$SRC_DIR" "$OUT"

# Print what actually landed in the output.
echo "archs: $OUT -> $(/usr/bin/lipo -archs "$OUT" 2>/dev/null || echo unreadable)"
