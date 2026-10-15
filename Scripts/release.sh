#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Config/Version.env

: "${NOCCI_UPDATE_FEED_URL:?Set the public HTTPS appcast URL.}"
: "${NOCCI_UPDATE_PUBLIC_KEY:?Set the Sparkle Ed25519 public key.}"

# Sparkle accepts an EdDSA-signed archive without Developer ID signing, so an
# identity is optional. Without one the app is ad-hoc signed and cannot be
# notarized, which costs users a one-time Gatekeeper prompt on first launch.
IDENTITY="${NOCCI_CODE_SIGN_IDENTITY:--}"
NOTARIZE=1
if [[ "$IDENTITY" == "-" ]]; then
    NOTARIZE=0
    echo "No Developer ID identity set. Building an ad-hoc signed release."
    echo "Updates still work: Sparkle verifies the EdDSA signature."
    echo "First launch will show Gatekeeper's unidentified-developer warning."
else
    : "${NOCCI_NOTARY_PROFILE:?Set the notarytool Keychain profile name, or unset NOCCI_CODE_SIGN_IDENTITY for an ad-hoc release.}"
fi

# Sparkle shows these in its update window; an empty body looks broken.
NOTES="ReleaseNotes/$MARKETING_VERSION.md"
[[ -f "$NOTES" ]] || {
    echo "Missing release notes at $NOTES" >&2
    echo "Write them first. generate_appcast embeds this file as the update's" >&2
    echo "description, and without it Sparkle offers an update with no explanation." >&2
    exit 1
}

# A release describes a commit; uncommitted or untracked files would ship unrecorded.
[[ -z "$(git status --porcelain)" ]] || {
    echo "Commit or stash your changes before building a release." >&2
    exit 1
}

ARCH="$(uname -m)"
ROOT="dist/Nocci-$MARKETING_VERSION-$BUILD_NUMBER-$ARCH"
APP="$ROOT/Nocci.app"
TEMP_ZIP="$ROOT/notarization.zip"
BASENAME="Nocci-$MARKETING_VERSION-$BUILD_NUMBER-macos-$ARCH"
FINAL_ZIP="dist/$BASENAME.zip"

rm -rf "$ROOT" "$FINAL_ZIP" "$FINAL_ZIP.sha256" "dist/$BASENAME.md"
mkdir -p "$ROOT"
NOCCI_CODE_SIGN_IDENTITY="$IDENTITY" NOCCI_APP_OUTPUT="$APP" ./build.sh
codesign --verify --strict --verbose=2 "$APP"
# The first archive anyone installs must already carry the feed, or that copy
# can never learn an update exists.
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" 2>/dev/null)" == "$NOCCI_UPDATE_FEED_URL" \
   && "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null)" == "$NOCCI_UPDATE_PUBLIC_KEY" ]] || {
    echo "The built app does not carry the update feed and key." >&2
    exit 1
}

if [[ "$NOTARIZE" == "1" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP_ZIP"
    xcrun notarytool submit "$TEMP_ZIP" --keychain-profile "$NOCCI_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$TEMP_ZIP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$FINAL_ZIP"
# Name the bare archive, so `shasum -c` works wherever the two files are downloaded.
(cd dist && shasum -a 256 "$BASENAME.zip") > "$FINAL_ZIP.sha256"
# generate_appcast pairs notes with an archive by matching basename.
cp "$NOTES" "dist/$BASENAME.md"
# The disk image is what people download; the ZIP above stays the update archive.
# Its name carries no version, so .../releases/latest/download/Nocci.dmg always works.
Scripts/build-dmg.sh "$APP" "$ROOT/Nocci.dmg"
(cd "$ROOT" && shasum -a 256 Nocci.dmg) > "$ROOT/Nocci.dmg.sha256"

echo "Release archive: $FINAL_ZIP"
echo "Disk image: $ROOT/Nocci.dmg"
[[ "$NOTARIZE" == "1" ]] || echo "Not notarized: users bypass Gatekeeper once on first launch."
echo "Next: run Scripts/generate-appcast.sh dist <download-url-prefix> [stable|preview]"
