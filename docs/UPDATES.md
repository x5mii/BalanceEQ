# Native update delivery

BalanceEQ 1.1.2 introduces Sparkle 2.10.1 (pinned in `Package.resolved`).
The manual **Check for Updates…** action is in the menu-bar menu, application
menu and About window. No automatic checks/installations or system profiling
are enabled. Closing the main window does not disable this menu action.

Sparkle verifies both the feed and the archive against `SUPublicEDKey` before
extracting/installing. Invalid feed signatures never expire into trust.
The normal application termination path saves presets and releases Core Audio;
the relaunched app starts with EQ stopped, as on any ordinary launch.

The feed lives at `https://raw.githubusercontent.com/x5mii/BalanceEQ/updates/appcast.xml`.
The dedicated `updates` branch contains only the signed feed, currently advertising
1.2.1/build 8. A candidate newer than the feed reports that it is up to date.
Existing 1.1.1 apps have no
updater and need one initial manual installation of 1.1.2 or later.

## Keys and signing

The private Ed25519 key is in the maintainer's login Keychain under Sparkle's
**Private key for signing Sparkle updates**, account **BalanceEQ**. Only its
public key is in `Resources/Info.plist`. Keep a secure backup of the Keychain;
never commit/export the private key into this repository, CI logs or releases.
Do not generate a replacement key for a routine release. Without the original
key, installed ad-hoc builds cannot trust new updates.

Password dialogs naming `generate_appcast` or **Private key for signing Sparkle updates**
are maintainer-only Keychain requests during publication. They are not part of the
installed app's update flow and end users do not need this private key. Use one
`generate_appcast` invocation for the final archive/feed, then verify using the public
key embedded in the app to avoid redundant private-key lookups. The `sign_update
--verify` command below is an optional Keychain-backed alternative and may prompt again.
Do not export the key or weaken its access controls to suppress prompts.

These signatures authenticate updates to the app's embedded key. They do not
establish an Apple Developer ID or notarization. The existing community-build
disclosure and outstanding hardware/clean-Mac acceptance still apply.

The build script preserves framework symlinks and signs Sparkle's helpers from
the inside out, including the downloader's existing entitlement. Developer ID
builds use that same identity for the framework and helpers. Do not replace
this with `codesign --deep` signing. Deep *verification* is appropriate.

## Publish each future update

1. Increase both app versions; `CFBundleVersion` must increase monotonically.
   Run the checks and universal build, then archive with `ditto --keepParent`.
   Finish any notarization/stapling before creating the final archive.
2. Publish the matching GitHub tag, `BalanceEQ.zip` and checksum using the
   existing release process. Verify the public download before advertising it
   in the feed. Keep old releases available for recovery.
3. Put **only** the final `BalanceEQ.zip` for this release into a fresh staging
   directory. Generate the feed with the pinned Sparkle tools (available after
   `scripts/check.sh`). Substitute the actual release tag below:

   ```sh
   .build/tests/artifacts/sparkle/Sparkle/bin/generate_appcast \
     --account BalanceEQ --maximum-deltas 0 \
     --download-url-prefix https://github.com/x5mii/BalanceEQ/releases/download/v1.2.1/ \
     --link https://github.com/x5mii/BalanceEQ/releases/tag/v1.2.1 \
     path/to/staging-directory
   ```

   The generator reads the version, OS requirement and public key from the app,
   signs the archive and feed, and embeds their signatures. An optional
   `BalanceEQ.html` fragment in that directory supplies embedded release notes.
   With this single-release staging directory, the feed advertises only the
   latest stable version. Do not put prereleases or test builds there.
4. Inspect the generated `appcast.xml`: version/build, public URL, length,
   minimum macOS, and archive signature. Verify its signature with
   `bin/sign_update --account BalanceEQ --verify path/to/appcast.xml`.
   Commit **only** this feed to the `updates` branch and push without force.
   Do not edit a signed feed without re-signing it.
5. Download the public feed again, verify it, and test the update from an older
   updater-enabled build. Keep the audio/preset preservation checks separate
   from signature and build checks.

If the minimum supported OS changes, preserve the last compatible feed entry
for older systems using Sparkle's multi-version generator workflow instead of
the single-release staging directory above.
