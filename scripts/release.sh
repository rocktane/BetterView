#!/bin/bash
# Build a universal app and authenticate its update archive with Sparkle (no Apple certificate).
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:-}"
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Usage: scripts/release.sh v1.0.0" >&2
    exit 1
fi
version="${tag#v}"
output="build/release/$tag"
if [[ -e "$output" ]]; then
    echo "Output already exists: $output. Use a fresh checkout to rebuild this version." >&2
    exit 1
fi

xcodegen generate --quiet
xcodebuild -scheme BetterView -configuration Release -derivedDataPath build \
    -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO -quiet build
app="build/Build/Products/Release/BetterView.app"
plist="$app/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
    actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")
    if [[ "$actual" != "$version" ]]; then
        echo "$key is $actual, expected $version. Update both versions in project.yml." >&2
        exit 1
    fi
done
lipo "$app/Contents/MacOS/BetterView" -verify_arch arm64
lipo "$app/Contents/MacOS/BetterView" -verify_arch x86_64
codesign --verify --deep --strict "$app"

mkdir -p "$output"
archive="$output/BetterView-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
sparkle="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
# CI passes the private key through stdin; local builds use the dedicated Keychain account.
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle/generate_appcast" --ed-key-file - \
        --download-url-prefix "https://github.com/rocktane/BetterView/releases/download/$tag/" \
        --link "https://github.com/rocktane/BetterView/releases/tag/$tag" \
        --maximum-deltas 0 "$output"
else
    "$sparkle/generate_appcast" --account com.yohan.betterview \
        --download-url-prefix "https://github.com/rocktane/BetterView/releases/download/$tag/" \
        --link "https://github.com/rocktane/BetterView/releases/tag/$tag" \
        --maximum-deltas 0 "$output"
fi
# generate_appcast can warn and continue on signing errors: never publish an unsigned enclosure.
swift scripts/verify-release.swift "$output/appcast.xml" "$archive" "$plist"
(cd "$output" && shasum -a 256 "BetterView-$version.zip" > SHA256SUMS.txt)
echo "Release ready: $output"
