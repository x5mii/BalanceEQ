#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile}"
case "$SIGNING_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) printf 'Release signing requires a Developer ID Application identity.\n' >&2; exit 1 ;;
esac
./scripts/check.sh
ARCHITECTURES="arm64 x86_64" CONFIGURATION=release ./scripts/build-app.sh
bundle="$PWD/build/Equalizer for Mac.app"
zip="$PWD/build/Equalizer-for-Mac-notarization.zip"
ditto -c -k --keepParent "$bundle" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
spctl --assess --type execute --verbose=2 "$bundle"
release="$PWD/build/Equalizer-for-Mac-0.1.0.zip"
ditto -c -k --keepParent "$bundle" "$release"
shasum -a 256 "$release" > "$release.sha256"
printf 'Notarized release: %s\n' "$release"
