#!/bin/bash
set -euo pipefail

IDENTITY="${1:?Usage: sign-app.sh SIGNING_IDENTITY APP_PATH}"
APP="${2:?Usage: sign-app.sh SIGNING_IDENTITY APP_PATH}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

if [[ "$IDENTITY" == "-" ]]; then
    # Keep Sparkle's distributed nested signatures intact for local builds.
    codesign --force --sign - "$APP"
    exit 0
fi

COMMON=(--force --sign "$IDENTITY" --options runtime --timestamp)
for COMPONENT in \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/Autoupdate" \
    "$FRAMEWORK/Versions/B/Updater.app"
do
    [[ -e "$COMPONENT" ]] || continue
    if [[ "$COMPONENT" == *"Downloader.xpc" ]]; then
        codesign "${COMMON[@]}" --preserve-metadata=entitlements "$COMPONENT"
    else
        codesign "${COMMON[@]}" "$COMPONENT"
    fi
done
codesign "${COMMON[@]}" "$FRAMEWORK"
codesign "${COMMON[@]}" "$APP"
