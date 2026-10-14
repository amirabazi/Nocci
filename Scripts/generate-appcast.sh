#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVES="${1:?Usage: generate-appcast.sh ARCHIVES_DIRECTORY DOWNLOAD_URL_PREFIX [stable|preview]}"
DOWNLOAD_PREFIX="${2:?Usage: generate-appcast.sh ARCHIVES_DIRECTORY DOWNLOAD_URL_PREFIX [stable|preview]}"
CHANNEL="${3:-stable}"
[[ "$DOWNLOAD_PREFIX" == https://* ]] || { echo "Download URL prefix must use HTTPS." >&2; exit 1; }
# Archive names are appended to the prefix, so without the slash the release
# tag's folder would be lost from every download link.
[[ "$DOWNLOAD_PREFIX" == */ ]] || { echo "Download URL prefix must end with /." >&2; exit 1; }
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "preview" ]] || {
    echo "Channel must be stable or preview." >&2
    exit 1
}

swift package resolve >/dev/null
TOOL=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$TOOL" ]] || { echo "Sparkle's generate_appcast tool is missing." >&2; exit 1; }

# Markdown notes are only linked by default, which would need the .md file
# hosted beside the feed; embedding puts them in Sparkle's window directly.
# Deltas are off: each would be one more file to upload to the release.
ARGS=(--download-url-prefix "$DOWNLOAD_PREFIX" --link "https://github.com/amirabazi/Nocci/releases"
      --embed-release-notes --maximum-deltas 0)
[[ "$CHANNEL" == "preview" ]] && ARGS+=(--channel preview)
"$TOOL" "${ARGS[@]}" "$ARCHIVES"
echo "Generated signed appcast in $ARCHIVES"
