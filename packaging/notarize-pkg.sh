#!/bin/bash
# Notarize and staple a Developer ID-signed package (optional; release builds only).
#
#   packaging/notarize-pkg.sh <signed-pkg>
#
# Needs a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials sentryscreen-notary \
#     --key <AuthKey_*.p8> --key-id <id> --issuer <uuid>
# SENTRY_NOTARY_PROFILE names a different profile. Or skip the profile and pass
# the API key directly: SENTRY_NOTARY_KEY=<AuthKey_*.p8>, SENTRY_NOTARY_KEY_ID,
# SENTRY_NOTARY_ISSUER (useful on a build Mac without an unlocked login keychain).
set -euo pipefail
PKG="${1:-}"
[ -f "$PKG" ] || { echo "usage: $0 <signed-pkg>" >&2; exit 64; }
PROFILE="${SENTRY_NOTARY_PROFILE:-sentryscreen-notary}"
# Apple usually answers within an hour; the slowest seen took about 90 minutes.
WAIT_TIMEOUT="${SENTRY_NOTARY_WAIT_TIMEOUT:-2h}"

/usr/sbin/pkgutil --check-signature "$PKG" | grep 'Developer ID Installer' >/dev/null || {
  echo "notarize-pkg: $PKG is not signed with a Developer ID Installer identity" >&2
  exit 1
}
if [ -n "${SENTRY_NOTARY_KEY:-}" ]; then
  AUTH=(--key "$SENTRY_NOTARY_KEY" --key-id "${SENTRY_NOTARY_KEY_ID:?}" --issuer "${SENTRY_NOTARY_ISSUER:?}")
else
  AUTH=(--keychain-profile "$PROFILE")
fi
xcrun notarytool submit "$PKG" "${AUTH[@]}" --wait --timeout "$WAIT_TIMEOUT"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
/usr/sbin/spctl --assess --type install -vv "$PKG"
echo "notarized: $PKG"
