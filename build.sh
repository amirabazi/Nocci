#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source Config/Version.env
APP="${NOCCI_APP_OUTPUT:-../Nocci.app}"
IDENTITY="${NOCCI_CODE_SIGN_IDENTITY:--}"
FEED_URL="${NOCCI_UPDATE_FEED_URL:-}"
PUBLIC_KEY="${NOCCI_UPDATE_PUBLIC_KEY:-}"

if [[ -n "$FEED_URL" || -n "$PUBLIC_KEY" ]]; then
    [[ -n "$FEED_URL" && -n "$PUBLIC_KEY" ]] || {
        echo "NOCCI_UPDATE_FEED_URL and NOCCI_UPDATE_PUBLIC_KEY must be provided together." >&2
        exit 1
    }
    [[ "$FEED_URL" == https://* ]] || { echo "The update feed must use HTTPS." >&2; exit 1; }
fi

swift package resolve >/dev/null
SWIFTTERM="$(Scripts/build-swiftterm.sh)"
SPARKLE_ROOT=".build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle $SPARKLE_VERSION was not resolved." >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" .build/module-cache
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path .build/module-cache Sources/*.swift \
    -I "$SWIFTTERM" -L "$SWIFTTERM" -lSwiftTerm \
    -o "$APP/Contents/MacOS/Nocci" \
    -F "$(dirname "$SPARKLE_FRAMEWORK")" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework AppKit -framework SwiftUI -framework ServiceManagement \
    -framework UserNotifications -framework Charts -lsqlite3
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Nocci</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>com.github.amirabazi.nocci</string>
<key>CFBundleName</key><string>Nocci</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>__MARKETING_VERSION__</string>
<key>CFBundleVersion</key><string>__BUILD_NUMBER__</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrefersDisplaySafeAreaCompatibilityMode</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST
sed -i '' -e "s/__MARKETING_VERSION__/$MARKETING_VERSION/" \
          -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/" "$APP/Contents/Info.plist"
if [[ -n "$FEED_URL" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$APP/Contents/Info.plist"
fi
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp Assets/*.pdf Assets/AppIcon.icns "$APP/Contents/Resources/"
cp GUIDE.md "$APP/Contents/Resources/GUIDE.md"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
Scripts/sign-app.sh "$IDENTITY" "$APP"
echo "Built $APP"
