#!/usr/bin/env bash
# Build ~/Applications/Claude Blue.app: a copy of /Applications/Claude.app with a blue Dock icon.
#   dock-icon/build.sh [degrees]   (hue rotation, default 225: orange -> blue)
# The copy is re-signed ad hoc, so it doesn't auto-update. Rebuild it after each Claude update;
# each rebuild changes its signature, and macOS asks once more for the "Claude Safe Storage" key.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src=/Applications/Claude.app
dst="$HOME/Applications/Claude Blue.app"
deg="${1:-225}"
work="$here/work/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$work" "$HOME/Applications"

if pgrep -f "^$dst/Contents/MacOS/Claude" >/dev/null; then
  echo "Claude Blue is running; quit it first." >&2; exit 1
fi

iconutil -c iconset -o "$work/orig.iconset" "$src/Contents/Resources/electron.icns"
swift "$here/recolor.swift" "$work/orig.iconset" "$work/blue.iconset" "$deg"
iconutil -c icns -o "$work/blue.icns" "$work/blue.iconset"

# The old copy goes to the Trash, never deleted outright.
[ -d "$dst" ] && mv "$dst" "$HOME/.Trash/Claude Blue $(date +%Y%m%d-%H%M%S).app"
ditto "$src" "$dst"
cp "$work/blue.icns" "$dst/Contents/Resources/electron.icns"
# The app's icon normally comes from Assets.car (CFBundleIconName); without it macOS uses electron.icns.
plutil -remove CFBundleIconName "$dst/Contents/Info.plist"
codesign --force --deep --sign - "$dst"
codesign --verify --deep --strict "$dst"
echo "built $dst ($(plutil -extract CFBundleShortVersionString raw "$dst/Contents/Info.plist"))"
