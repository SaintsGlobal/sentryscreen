#!/bin/bash
# Regenerate packaging/Brand/SentryScreen.icns from packaging/Brand/app-icon.svg
# with macOS's own sips and iconutil.
set -euo pipefail
cd "$(dirname "$0")"
set_dir=$(/usr/bin/mktemp -d)/SentryScreen.iconset
/bin/mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
  /usr/bin/sips -s format png -z "$size" "$size" app-icon.svg --out "$set_dir/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  /usr/bin/sips -s format png -z "$double" "$double" app-icon.svg --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$set_dir" -o SentryScreen.icns
/bin/rm -rf "$(dirname "$set_dir")"
echo "wrote $(pwd)/SentryScreen.icns"
