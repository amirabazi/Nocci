#!/bin/bash
# Compiles SwiftTerm into a static library and module, and prints the folder
# holding them. SwiftPM's own build of SwiftTerm runs Apple's `metal` shader
# compiler, which only Xcode has; SwiftTerm compiles that shader from source
# at runtime instead, so compiling its Swift files directly loses nothing and
# keeps the Command Line Tools enough. Swift 5 mode, because this compiler
# rejects eight of its global properties in Swift 6 mode. Built once per
# version, architecture and compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
source Config/Version.env
grep -q "SwiftTerm\", exact: \"$SWIFTTERM_VERSION\"" Package.swift || {
    echo "Package.swift does not pin SwiftTerm $SWIFTTERM_VERSION." >&2
    exit 1
}
SOURCE=".build/checkouts/SwiftTerm/Sources/SwiftTerm"
[[ -d "$SOURCE" ]] || swift package resolve >/dev/null
[[ -d "$SOURCE" ]] || { echo "SwiftTerm $SWIFTTERM_VERSION was not resolved." >&2; exit 1; }
# A module built by one compiler cannot be imported by another, so the folder
# names the compiler too and a toolchain update rebuilds SwiftTerm.
COMPILER="$(swiftc --version 2>&1 | shasum | cut -c1-8)"
OUT=".build/swiftterm/$SWIFTTERM_VERSION-$(uname -m)-$COMPILER"
if [[ ! -f "$OUT/libSwiftTerm.a" ]]; then
    rm -rf "$OUT.partial"
    mkdir -p "$OUT.partial" .build/module-cache
    # SwiftPM generates this file with a build plugin.
    cat > "$OUT.partial/SwiftTermBuildInfo.swift" <<SWIFT
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v$SWIFTTERM_VERSION"
    public static let commit: String? = nil
    public static let hasUncommittedChanges: Bool? = false
    public static let version: String = "v$SWIFTTERM_VERSION"
}
SWIFT
    files=()
    while IFS= read -r -d '' file; do files+=("$file"); done < <(find "$SOURCE" -name '*.swift' -print0 | sort -z)
    swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -suppress-warnings \
        -module-name SwiftTerm -target "$(uname -m)-apple-macosx13.0" -module-cache-path .build/module-cache \
        -emit-library -static -o "$OUT.partial/libSwiftTerm.a" \
        -emit-module -emit-module-path "$OUT.partial/SwiftTerm.swiftmodule" \
        "${files[@]}" "$OUT.partial/SwiftTermBuildInfo.swift"
    rm -rf "$OUT"
    mv "$OUT.partial" "$OUT"
fi
echo "$OUT"
