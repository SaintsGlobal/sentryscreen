#!/bin/bash
# Assemble and sign SentryScreen.app from the swiftc build.
#
# A bundle gives the app its own Screen Recording (TCC) identity.
#
# SENTRY_SIGN_MODE:
#   adhoc (default)  ad-hoc signature; macOS asks for Screen Recording again
#                    after each rebuild.
#   development      Apple Development identity (auto-selected, or
#                    SENTRY_APP_SIGN_IDENTITY); the grant survives rebuilds.
#   release          Developer ID Application identity named in
#                    SENTRY_APP_SIGN_IDENTITY, hardened runtime, timestamp.
set -euo pipefail
cd "$(dirname "$0")/.."

# The script changes to the runtime repo root first.
# shellcheck disable=SC1091
source packaging/release.env

MODE="${SENTRY_SIGN_MODE:-adhoc}"
IDENTITY="${SENTRY_APP_SIGN_IDENTITY:-}"
# Certificate-signed builds pin the designated requirement to the team, not
# the certificate, so switching between Apple Development and Developer ID
# builds keeps the Screen Recording grant. Ad-hoc builds keep codesign's default.
designated_requirement() {
  printf 'identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"' "$1" "$SENTRY_TEAM_ID"
}
require_team_id() {
  [ -n "$SENTRY_TEAM_ID" ] || {
    echo "bundle: SENTRY_TEAM_ID is empty but signing identity '$IDENTITY' is a certificate; set SENTRY_TEAM_ID to your Apple team ID (packaging/release.env)" >&2
    exit 64
  }
}
# `-r=<text>` is codesign's inline requirement-set form; the set names the designated slot.
APP_DR="designated => $(designated_requirement "$SENTRY_BUNDLE_ID")"

case "$MODE" in
  adhoc)
    [ -z "$IDENTITY" ] || { echo "bundle: SENTRY_APP_SIGN_IDENTITY is invalid in adhoc mode" >&2; exit 64; }
    ;;
  development) ;;
  release)
    [ -n "$IDENTITY" ] || {
      echo "bundle: release requires SENTRY_APP_SIGN_IDENTITY=Developer ID Application ..." >&2
      exit 64
    }
    [[ "$IDENTITY" == Developer\ ID\ Application* ]] || {
      echo "bundle: release identity must be Developer ID Application; observed '$IDENTITY'" >&2
      exit 64
    }
    ;;
  *)
    echo "bundle: SENTRY_SIGN_MODE must be development, adhoc, or release; observed '$MODE'" >&2
    exit 64
    ;;
esac

# SENTRY_BUILD_DIR: where the binaries are read from and the bundle is written.
BUILD_DIR="${SENTRY_BUILD_DIR:-daemon/.build}"
if [ "${SENTRY_BUILD_BINARY:-1}" = "1" ]; then
  if [ -n "${SENTRY_BUILD_DIR:-}" ]; then
    SENTRY_OUT="${SENTRY_OUT:-$BUILD_DIR/sentry-screen}" bash scripts/build.sh
  else
    bash scripts/build.sh
  fi
else
  [ -x "$BUILD_DIR/sentry-screen" ] || {
    echo "bundle: SENTRY_BUILD_BINARY=0 but $BUILD_DIR/sentry-screen is missing" >&2
    exit 1
  }
fi

APP="$BUILD_DIR/SentryScreen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp "$BUILD_DIR/sentry-screen" "$APP/Contents/MacOS/sentry-screen"
cp packaging/Brand/SentryScreen.icns "$APP/Contents/Resources/SentryScreen.icns"
cp packaging/Brand/favicon.svg "$APP/Contents/Resources/favicon.svg"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SENTRY_BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SENTRY_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SENTRY_BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $SENTRY_MIN_MACOS" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SentryDiagnosticsURL string $SENTRY_DIAGNOSTICS_URL" "$APP/Contents/Info.plist"

# A separately registered application job must own removal and its result.
# Reuse the exact product executable; its bundle-id dispatch runs no capture.
UNINSTALLER="$APP/Contents/Helpers/SentryScreen Uninstaller.app"
mkdir -p "$UNINSTALLER/Contents/MacOS" "$UNINSTALLER/Contents/Resources"
cp packaging/Brand/SentryScreen.icns "$UNINSTALLER/Contents/Resources/SentryScreen.icns"
cp packaging/Uninstaller-Info.plist "$UNINSTALLER/Contents/Info.plist"
cp "$BUILD_DIR/sentry-screen" "$UNINSTALLER/Contents/MacOS/sentry-screen"
for field in "CFBundleShortVersionString $SENTRY_VERSION" "CFBundleVersion $SENTRY_BUILD" "LSMinimumSystemVersion $SENTRY_MIN_MACOS"; do
  /usr/libexec/PlistBuddy -c "Set :$field" "$UNINSTALLER/Contents/Info.plist"
done
sign_uninstaller() {
  if [ "$MODE" = release ]; then
    codesign --force --timestamp --options runtime -r="designated => $(designated_requirement com.sentryscreen.uninstaller)" -s "$IDENTITY" "$UNINSTALLER"
  elif [ "$IDENTITY" = - ]; then
    codesign --force --timestamp=none --options runtime -s "$IDENTITY" "$UNINSTALLER"
  else
    codesign --force --timestamp=none --options runtime -r="designated => $(designated_requirement com.sentryscreen.uninstaller)" -s "$IDENTITY" "$UNINSTALLER"
  fi
}

case "$MODE" in
  adhoc)
    [ -z "$IDENTITY" ] || { echo "bundle: SENTRY_APP_SIGN_IDENTITY is invalid in adhoc mode" >&2; exit 64; }
    IDENTITY="-"
    sign_uninstaller
    codesign --force --timestamp=none --options runtime -s "$IDENTITY" "$APP"
    ;;
  development)
    if [ -z "$IDENTITY" ]; then
      IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"Apple Development[^"]*"' | head -1 | tr -d '"') \
        || IDENTITY=""
    fi
    if [ -z "$IDENTITY" ]; then
      echo "bundle: no Apple Development identity found — ad-hoc (TCC grant will NOT survive a rebuild)" >&2
      IDENTITY="-"
    elif [[ "$IDENTITY" != Apple\ Development* ]]; then
      echo "bundle: development identity must be Apple Development; observed '$IDENTITY'" >&2
      exit 64
    fi
    [ "$IDENTITY" = "-" ] || require_team_id
    sign_uninstaller
    if [ "$IDENTITY" = "-" ]; then
      codesign --force --timestamp=none --options runtime -s "$IDENTITY" "$APP"
    else
      codesign --force --timestamp=none --options runtime -r="$APP_DR" -s "$IDENTITY" "$APP"
    fi
    ;;
  release)
    require_team_id
    sign_uninstaller
    codesign --force --timestamp --options runtime -r="$APP_DR" -s "$IDENTITY" "$APP"
    ;;
esac
codesign --verify --deep --strict "$APP"
case "$MODE" in
  adhoc|development)
    codesign -dv --verbose=4 "$APP" 2>&1 | grep 'flags=.*runtime' >/dev/null || {
      echo "bundle: $MODE signature lacks hardened runtime (fix: packaging/bundle.sh $MODE mode)" >&2
      exit 1
    }
    ;;
esac
# A universal binary carries one signature per slice: verify each one.
for slice_arch in ${SENTRY_BUILD_ARCHS:-$SENTRY_ARCHS}; do
  for signed_path in "$APP/Contents/MacOS/sentry-screen" "$UNINSTALLER/Contents/MacOS/sentry-screen"; do
    codesign --verify --strict --arch "$slice_arch" "$signed_path" || {
      echo "bundle: signature invalid arch=$slice_arch path=$signed_path (fix: packaging/bundle.sh $MODE mode)" >&2
      exit 1
    }
    codesign -dv --verbose=4 --arch "$slice_arch" "$signed_path" 2>&1 | grep 'flags=.*runtime' >/dev/null || {
      echo "bundle: $MODE signature lacks hardened runtime arch=$slice_arch path=$signed_path (fix: packaging/bundle.sh $MODE mode)" >&2
      exit 1
    }
  done
done
echo "signed slices: ${SENTRY_BUILD_ARCHS:-$SENTRY_ARCHS} (app, uninstaller; hardened runtime verified per slice)"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|Authority" | head -4
codesign -d -r- "$APP" 2>&1 | grep designated
if [ "$IDENTITY" != "-" ]; then
  # codesign -d -r- prints the OU value unquoted; compare in that form.
  OBSERVED_DR=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
  EXPECTED_DR="$(designated_requirement "$SENTRY_BUNDLE_ID" | sed "s/= \"$SENTRY_TEAM_ID\"\$/= $SENTRY_TEAM_ID/")"
  [ "$OBSERVED_DR" = "$EXPECTED_DR" ] || {
    echo "bundle: designated requirement configured='$EXPECTED_DR' observed='$OBSERVED_DR' remediation=packaging/bundle.sh-designated_requirement (a certificate-bound DR orphans the TCC grant on every identity switch)" >&2
    exit 1
  }
fi
echo "bundled: $APP (mode $MODE)"
