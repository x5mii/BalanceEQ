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
bundle="$PWD/build/BalanceEQ.app"
zip="$PWD/build/BalanceEQ-notarization.zip"
ditto -c -k --keepParent "$bundle" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
spctl --assess --type execute --verbose=2 "$bundle"
release="$PWD/build/BalanceEQ.zip"
ditto -c -k --keepParent "$bundle" "$release"
(cd build && shasum -a 256 BalanceEQ.zip > BalanceEQ.zip.sha256)
printf 'Notarized release: %s\n' "$release"
