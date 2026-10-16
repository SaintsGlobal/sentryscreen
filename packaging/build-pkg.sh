#!/bin/bash
# Build a flat SentryScreen installer package (does not install it).
#
#   bash packaging/build-pkg.sh
#
# Default: ad-hoc signed app, unsigned package, for people building from source.
# Signed release (optional):
#   SENTRY_PACKAGE_MODE=release \
#   SENTRY_APP_SIGN_IDENTITY="Developer ID Application: ..." \
#   SENTRY_INSTALLER_SIGN_IDENTITY="Developer ID Installer: ..." \
#   bash packaging/build-pkg.sh
# then packaging/notarize-pkg.sh <pkg>.
#
# SENTRY_SIGN_MODE=development signs the app with an Apple Development identity
# instead of ad-hoc (keeps the Screen Recording grant across rebuilds).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source packaging/release.env
# shellcheck disable=SC1091
source packaging/package-script-inventory.sh

fail() { echo "build-pkg: $*" >&2; exit 1; }

# `lipo -archs` prints slices in Mach-O order; compare sorted, comma-joined lists.
# shellcheck disable=SC2086
sorted_archs() { printf '%s\n' $1 | LC_ALL=C /usr/bin/sort -u | /usr/bin/paste -sd, -; }
EXPECTED_ARCHS=$(sorted_archs "$SENTRY_ARCHS")

# A package must not advertise an architecture or macOS version that one of its
# executables does not provide (a thin dev build is the usual cause).
assert_mach_o() {
  local path="$1" observed arch minos
  observed=$(sorted_archs "$(/usr/bin/lipo -archs "$path" 2>/dev/null || echo unreadable)")
  [ "$observed" = "$EXPECTED_ARCHS" ] || \
    fail "architectures configured=$EXPECTED_ARCHS observed=$observed path=$path remediation=scripts/build.sh"
  for arch in $SENTRY_ARCHS; do
    minos=$(/usr/bin/otool -arch "$arch" -l "$path" 2>/dev/null | /usr/bin/awk '
      $1 == "cmd" { lc = $2; next }
      lc == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }')
    [ "$minos" = "$SENTRY_MIN_MACOS" ] || \
      fail "minimum_macos configured=$SENTRY_MIN_MACOS observed=${minos:-unreadable} arch=$arch path=$path"
  done
}

MODE="${SENTRY_PACKAGE_MODE:-development}"
case "$MODE" in
  development) SIGN_MODE="${SENTRY_SIGN_MODE:-adhoc}" ;;
  release)
    SIGN_MODE=release
    [[ "${SENTRY_APP_SIGN_IDENTITY:-}" == Developer\ ID\ Application* ]] || \
      fail "release requires SENTRY_APP_SIGN_IDENTITY=Developer ID Application ..."
    [[ "${SENTRY_INSTALLER_SIGN_IDENTITY:-}" == Developer\ ID\ Installer* ]] || \
      fail "release requires SENTRY_INSTALLER_SIGN_IDENTITY=Developer ID Installer ..."
    ;;
  *) fail "SENTRY_PACKAGE_MODE must be development or release; observed '$MODE'" ;;
esac

BUILD_DIR="${SENTRY_BUILD_DIR:-$ROOT/daemon/.build}"
APP="$BUILD_DIR/SentryScreen.app"
MODEL="${SENTRY_MODEL_PATH:-model/weights/$SENTRY_MODEL_FILE}"
# The committed model is checked against its manifest; a custom model gets a
# freshly measured one unless SENTRY_MODEL_MANIFEST names one.
if [ -z "${SENTRY_MODEL_PATH:-}" ]; then
  MODEL_MANIFEST_SOURCE="${SENTRY_MODEL_MANIFEST:-packaging/release-model.manifest}"
else
  MODEL_MANIFEST_SOURCE="${SENTRY_MODEL_MANIFEST:-}"
fi
OUT_DIR="${SENTRY_PACKAGE_OUT_DIR:-packaging/out}"
OUT="${SENTRY_PACKAGE_OUT:-$OUT_DIR/SentryScreen-${SENTRY_VERSION}-${SENTRY_BUILD}.pkg}"
[ ! -e "$OUT" ] || fail "output already exists: $OUT (remove it or set SENTRY_PACKAGE_OUT)"
[ -d "$MODEL" ] || fail "model is missing: $MODEL (fix: SENTRY_MODEL_PATH)"

SOURCE_COMMIT=$(/usr/bin/git rev-parse --verify HEAD 2>/dev/null || echo unknown)
SOURCE_DIRTY=no
/usr/bin/git diff --quiet HEAD -- 2>/dev/null || SOURCE_DIRTY=yes
if [ "$MODE" = release ] && [ "$SOURCE_DIRTY" != no ]; then
  fail "release builds need a clean, committed tree"
fi

# Always build universal from source: SENTRY_TARGET="" ignores an inherited
# single-triple build and SENTRY_BUILD_ARCHS is set to the shipped list.
SENTRY_TARGET="" SENTRY_BUILD_ARCHS="$SENTRY_ARCHS" SENTRY_SIGN_MODE="$SIGN_MODE" \
  SENTRY_BUILD_DIR="$BUILD_DIR" \
  SENTRY_OUT="$BUILD_DIR/sentry-screen" \
  SENTRY_APP_SIGN_IDENTITY="${SENTRY_APP_SIGN_IDENTITY:-}" \
  bash packaging/bundle.sh

APP_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
assert_mach_o "$APP/Contents/MacOS/$APP_EXECUTABLE"
[ "$MODE" != release ] || /bin/bash packaging/install-preflight.sh "$BUILD_DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sentryscreen-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/payload"
SUPPORT="$PAYLOAD/Library/Application Support/SentryScreen"
mkdir -p "$SUPPORT/licenses" "$PAYLOAD/Library/LaunchAgents" \
  "$PAYLOAD/Library/LaunchDaemons" "$(dirname "$OUT")"

/usr/bin/ditto "$APP" "$SUPPORT/SentryScreen.app"
PAYLOAD_MODEL="$SUPPORT/$SENTRY_MODEL_FILE"
/bin/bash packaging/model-identity.sh measure "$MODEL" >/dev/null   # rejects links and special files
/usr/bin/ditto "$MODEL" "$PAYLOAD_MODEL"
# The per-user agent reads the root-owned model: 0644 files, 0755 directories.
# The model manifest is measured with these modes.
/bin/chmod -R u=rwX,go=rX "$PAYLOAD_MODEL"

if [ -n "$MODEL_MANIFEST_SOURCE" ]; then
  /bin/bash packaging/model-identity.sh verify "$PAYLOAD_MODEL" "$MODEL_MANIFEST_SOURCE" >/dev/null
  install -m 644 "$MODEL_MANIFEST_SOURCE" "$SUPPORT/model-identity.tsv"
else
  /bin/bash packaging/model-identity.sh write-development "$PAYLOAD_MODEL" > "$WORK/model-identity.tsv"
  install -m 644 "$WORK/model-identity.tsv" "$SUPPORT/model-identity.tsv"
fi

{
  printf '# sentryscreen-build-metadata-v1\n'
  printf 'schema_version\t1\n'
  printf 'source_commit\t%s\n' "$SOURCE_COMMIT"
  printf 'source_tracked_dirty\t%s\n' "$SOURCE_DIRTY"
  printf 'app_signing_mode_requested\t%s\n' "$SIGN_MODE"
  printf 'package_mode\t%s\n' "$MODE"
  printf 'version\t%s\n' "$SENTRY_VERSION"
  printf 'build\t%s\n' "$SENTRY_BUILD"
  printf 'bundle_id\t%s\n' "$SENTRY_BUNDLE_ID"
  printf 'package_id\t%s\n' "$SENTRY_PACKAGE_ID"
  printf 'minimum_macos\t%s\n' "$SENTRY_MIN_MACOS"
  printf 'architecture\t%s\n' "$SENTRY_ARCH"
  printf 'executable\t%s\n' "$SENTRY_EXECUTABLE"
} > "$SUPPORT/build-metadata.tsv"
/bin/chmod 644 "$SUPPORT/build-metadata.tsv"

for script_source in "${SENTRY_SUPPORT_SCRIPT_SOURCES[@]}"; do
  install -m 755 "$script_source" "$SUPPORT/${script_source##*/}"
done
/bin/bash packaging/render-model-template.sh packaging/config.sample.json \
  "$SUPPORT/config.default.json" 644
install -m 644 LICENSE "$SUPPORT/licenses/LICENSE.txt"
install -m 644 NOTICE "$SUPPORT/licenses/NOTICE.txt"
install -m 644 packaging/THIRD-PARTY.txt "$SUPPORT/licenses/THIRD-PARTY.txt"
install -m 644 packaging/licenses/Apache-2.0.txt "$SUPPORT/licenses/Apache-2.0.txt"
install -m 644 packaging/launchd/com.sentryscreen.agent.plist "$PAYLOAD/Library/LaunchAgents/"
install -m 644 packaging/launchd/com.sentryscreen.watchdog.plist "$PAYLOAD/Library/LaunchDaemons/"

SCRIPTS="$WORK/scripts"
mkdir -p "$SCRIPTS"
for script_source in "${SENTRY_INSTALLER_SCRIPT_SOURCES[@]}"; do
  dest="$SCRIPTS/${script_source##*/}"
  if [ "$script_source" = packaging/pkg-scripts/configure-install.sh ]; then
    /bin/bash packaging/render-model-template.sh "$script_source" "$dest" 755
  else
    install -m 755 "$script_source" "$dest"
  fi
done

COMPONENT="$WORK/SentryScreen-component.pkg"
COMPONENT_PLIST="$WORK/components.plist"
REQUIREMENTS="$WORK/requirements.plist"
pkgbuild --analyze --root "$PAYLOAD" "$COMPONENT_PLIST"
# The app has one fixed system path; the launchd plists point at it.
/usr/bin/plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"
/usr/bin/plutil -replace 0.BundleIsVersionChecked -bool NO "$COMPONENT_PLIST"
pkgbuild --root "$PAYLOAD" --scripts "$SCRIPTS" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier "$SENTRY_PACKAGE_ID" --version "$SENTRY_VERSION" \
  --install-location / "$COMPONENT"
/usr/bin/plutil -create xml1 "$REQUIREMENTS"
/usr/bin/plutil -insert os -array "$REQUIREMENTS"
/usr/bin/plutil -insert os.0 -string "$SENTRY_MIN_MACOS" "$REQUIREMENTS"
/usr/bin/plutil -insert arch -array "$REQUIREMENTS"
i=0
for arch in $SENTRY_ARCHS; do
  /usr/bin/plutil -insert "arch.$i" -string "$arch" "$REQUIREMENTS"
  i=$((i + 1))
done
productbuild --synthesize --product "$REQUIREMENTS" --package "$COMPONENT" "$WORK/Distribution"

if [ "$MODE" = release ]; then
  productbuild --distribution "$WORK/Distribution" --package-path "$WORK" \
    --sign "$SENTRY_INSTALLER_SIGN_IDENTITY" "$OUT"
else
  productbuild --distribution "$WORK/Distribution" --package-path "$WORK" "$OUT"
fi

echo "built-package: $OUT mode=$MODE version=$SENTRY_VERSION build=$SENTRY_BUILD"
