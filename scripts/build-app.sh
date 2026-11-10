#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A local universal build requires no account. Signing is opt-in for releases.
configuration=${CONFIGURATION:-release}
architectures=${ARCHITECTURES:-"arm64 x86_64"}
mkdir -p .build/cache .build/clang-cache build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
executables=()
for architecture in $architectures; do
    swift build --disable-sandbox --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build/$architecture" \
        -c "$configuration" --arch "$architecture"
    binary_directory=$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" \
        --scratch-path "$PWD/.build/$architecture" -c "$configuration" --arch "$architecture" --show-bin-path)
    executables+=("$binary_directory/EqualizerMac")
done

bundle="$PWD/build/BalanceEQ.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
if [ "${#executables[@]}" -eq 1 ]; then
    cp "${executables[0]}" "$bundle/Contents/MacOS/EqualizerMac"
else
    xcrun lipo -create "${executables[@]}" -output "$bundle/Contents/MacOS/EqualizerMac"
fi
cp Resources/BalanceEQ.icns "$bundle/Contents/Resources/"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$bundle/Contents/Resources/"
resource_bundle="EqualizerForMac_EQCore.bundle"
rm -rf "$bundle/Contents/Resources/$resource_bundle"
ditto "$binary_directory/$resource_bundle" "$bundle/Contents/Resources/$resource_bundle"
sparkle="$PWD/.build/$architecture/artifacts/sparkle/Sparkle"
framework="$bundle/Contents/Frameworks/Sparkle.framework"
mkdir -p "$bundle/Contents/Frameworks"
rm -rf "$framework"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
cp "$sparkle/LICENSE" "$bundle/Contents/Resources/Sparkle-LICENSE.txt"
# Sign nested updater code from the inside out, preserving the downloader's sandbox entitlement.
signing=(--force --sign "${SIGNING_IDENTITY:-${LOCAL_SIGNING_IDENTITY:--}}")
if [ -n "${SIGNING_IDENTITY:-}" ]; then signing+=(--options runtime --timestamp)
else signing+=(--timestamp=none); fi
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign "${signing[@]}" --preserve-metadata=entitlements "$framework/Versions/B/$component"
done
codesign "${signing[@]}" "$framework"
plutil -lint "$bundle/Contents/Info.plist"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$bundle"
elif [ -n "${LOCAL_SIGNING_IDENTITY:-}" ]; then
    codesign --force --timestamp=none --sign "$LOCAL_SIGNING_IDENTITY" "$bundle"
else
    codesign --force --sign - "$bundle"
fi
codesign --verify --deep --strict --verbose=2 "$bundle"
python3 scripts/check-updater.py "$bundle"
printf 'Built %s\n' "$bundle"
