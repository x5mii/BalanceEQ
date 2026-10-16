#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

fail() { printf 'BalanceEQ: %s\n' "$*" >&2; exit 1; }
allow_unnotarized=false
case "${1:-}" in
    '') ;;
    --allow-unnotarized) allow_unnotarized=true; shift ;;
    *) fail 'Usage: install.sh [--allow-unnotarized]' ;;
esac
[[ "$#" -eq 0 ]] || fail 'Usage: install.sh [--allow-unnotarized]'
[[ "$(uname -s)" == Darwin ]] || fail 'This installer requires macOS.'
[[ "$EUID" -ne 0 ]] || fail 'Run without sudo; BalanceEQ installs for your user.'
IFS=. read -r major minor patch <<< "$(sw_vers -productVersion)"
[[ "$major" =~ ^[0-9]+$ && "${minor:-0}" =~ ^[0-9]+$ ]] || fail 'Cannot determine the macOS version.'
(( major > 14 || (major == 14 && ${minor:-0} >= 2) )) || fail 'macOS 14.2 or later is required.'
if pgrep -x EqualizerMac >/dev/null; then
    fail 'Quit BalanceEQ from its menu-bar icon, then run this command again.'
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/balanceeq-download.XXXXXX")
stage=''
destination="$HOME/Applications/BalanceEQ.app"
cleanup() {
    # A failed replacement or interruption must leave the previous app recoverable.
    if [[ -n "$stage" && -d "$stage/previous.app" && ! -e "$destination" ]]; then
        if ! mv "$stage/previous.app" "$destination"; then
            printf 'Previous app preserved at %s\n' "$stage/previous.app" >&2
            stage=''
        fi
    fi
    [[ -z "$stage" ]] || rm -rf "$stage"
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

base='https://github.com/x5mii/BalanceEQ/releases/latest/download'
printf 'Downloading the latest BalanceEQ release…\n'
for asset in BalanceEQ.zip BalanceEQ.zip.sha256; do
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --connect-timeout 15 --max-time 180 --retry 2 \
        "$base/$asset" --output "$work/$asset" ||
        fail 'No downloadable release was found, or the download failed. See https://github.com/x5mii/BalanceEQ/releases'
done
expected=$(awk 'NR == 1 { print $1; exit }' "$work/BalanceEQ.zip.sha256")
[[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || fail 'The release checksum is invalid.'
actual=$(shasum -a 256 "$work/BalanceEQ.zip" | awk '{ print $1 }')
[[ "$actual" == "$expected" ]] || fail 'Download checksum mismatch. Nothing was installed; please try again.'

# Only the app bundle may be extracted from a release archive.
unzip -Z1 "$work/BalanceEQ.zip" > "$work/entries"
while IFS= read -r entry; do
    case "$entry" in BalanceEQ.app/*) ;; *) fail 'Unexpected file in the release archive.' ;; esac
    case "/$entry/" in */../*|*/./*) fail 'Invalid path in the release archive.' ;; esac
done < "$work/entries"
ditto -x -k "$work/BalanceEQ.zip" "$work/unpacked"
app="$work/unpacked/BalanceEQ.app"
[[ -d "$app" && ! -L "$app" ]] || fail 'The download does not contain BalanceEQ.app.'
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$bundle_id" == org.equalizerformac.app ]] || fail 'The download has an unexpected app identity.'
codesign --verify --deep --strict "$app" || fail 'App signature verification failed.'
approved=true
if ! spctl --assess --type execute "$app"; then
    "$allow_unnotarized" || fail 'macOS did not approve this release. Nothing was installed. The unnotarized community build requires --allow-unnotarized.'
    approved=false
    printf 'This build is not approved by Gatekeeper. Installing only; it will not be launched automatically.\n'
    printf 'Its checksum and code integrity passed, but these do not verify the developer or replace Apple notarization.\n'
fi

if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" ]] || fail 'The install destination is occupied by another file.'
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
    [[ "$existing_id" == org.equalizerformac.app ]] || fail 'An unrelated app already occupies the install destination.'
fi
mkdir -p "$HOME/Applications"
stage=$(mktemp -d "$HOME/Applications/.balanceeq-install.XXXXXX")
ditto "$app" "$stage/BalanceEQ.app"
if [[ -d "$destination" ]]; then mv "$destination" "$stage/previous.app"; fi
mv "$stage/BalanceEQ.app" "$destination"
printf 'Installed %s\nYour presets are preserved. Use the EQ icon in the menu bar.\n' "$destination"
if "$approved"; then
    open "$destination" || printf 'Open BalanceEQ from your Applications folder to finish.\n'
else
    printf 'Open ~/Applications/BalanceEQ.app in Finder when you are ready.\n'
    printf 'If macOS blocks it and you trust this release: System Settings → Privacy & Security → Open Anyway.\n'
    printf 'No security settings or quarantine attributes were changed.\n'
fi
