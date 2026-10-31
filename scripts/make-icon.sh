#!/usr/bin/env bash
#
# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
# Only needed when the icon design changes; the .icns is committed.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set="$work/AppIcon.iconset"
mkdir -p "$set" Resources

swift scripts/make-icon.swift "$work/icon-1024.png"

for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$work/icon-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$work/icon-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$set" -o Resources/AppIcon.icns
cp "$work/icon-1024.png" Resources/icon-preview.png
echo "Wrote Resources/AppIcon.icns"
