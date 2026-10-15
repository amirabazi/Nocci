#!/bin/bash
# Packs a built Nocci.app into a disk image whose window shows the app, an
# arrow and an Applications shortcut, so a first install lands in
# Applications rather than running from Downloads.
#   Scripts/build-dmg.sh <path/to/Nocci.app> <output.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?Usage: build-dmg.sh <Nocci.app> <output.dmg>}"
OUTPUT="${2:?Usage: build-dmg.sh <Nocci.app> <output.dmg>}"
[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }

# The window and its background share one layout, in points.
WIDTH=640 HEIGHT=400 APP_X=170 APPLICATIONS_X=470 ICON_Y=150 ICON_SIZE=128

# dmgbuild lives in its own environment, rebuilt when the pinned versions change.
VENV=.build/dmgbuild
if ! cmp -s Scripts/dmg-requirements.txt "$VENV/requirements.txt"; then
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: \
        -r Scripts/dmg-requirements.txt
    cp Scripts/dmg-requirements.txt "$VENV/requirements.txt"
fi

mkdir -p .build/module-cache
swiftc -module-cache-path .build/module-cache Scripts/dmg-background.swift -o .build/dmg-background
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
.build/dmg-background "$WORK/background.png" "$WIDTH" "$HEIGHT" "$APP_X" "$APPLICATIONS_X" "$ICON_Y" "$ICON_SIZE" >/dev/null

rm -f "$OUTPUT"
"$VENV/bin/dmgbuild" -s Scripts/dmg-settings.py \
    -D app="$APP" -D background="$WORK/background.png" -D volume_icon=Assets/AppIcon.icns \
    -D width="$WIDTH" -D height="$HEIGHT" -D app_x="$APP_X" -D applications_x="$APPLICATIONS_X" \
    -D icon_y="$ICON_Y" -D icon_size="$ICON_SIZE" \
    Nocci "$OUTPUT" >/dev/null
hdiutil verify -quiet "$OUTPUT"
echo "Disk image: $OUTPUT"
