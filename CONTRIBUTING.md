<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Contributing

Keep changes focused and use Swift, C, and the existing Apple frameworks before adding dependencies. Contributions are made under GPL-3.0-or-later. Preserve existing license notices and record any new third-party source and license in `THIRD_PARTY_NOTICES.md`.

## Build and checks

Use Xcode 26 or later with its command-line tools selected and license accepted:

```sh
./scripts/check.sh
./scripts/build-app.sh
```

The first command runs the Swift tests, Core Audio teardown fault-injection checks, standalone C callback checks, plist validation, and whitespace checks. The second creates a universal ad-hoc-signed development app. `ARCHITECTURES=arm64` or `ARCHITECTURES=x86_64` limits a local build; compiling an architecture is not runtime acceptance on that hardware. The GitHub Actions workflow performs these checks and uploads a development artifact; it does not notarize or publish a release.

## Code map

- `Sources/EqualizerMac`: SwiftUI UI, app/menu lifecycle, and the serial Core Audio control queue. The controller owns device listeners, the process tap, private aggregate device, and engine lifetime.
- `Sources/EQCore`: validated preset data, the strict APO codec, and atomic local persistence. Changes to imported syntax must include rejection and round-trip tests.
- `Sources/CEQ`: C-only render callback and double-precision biquad DSP. Coefficients are prepared outside the callback. A lock-free triple buffer transfers the latest parameters; complete filter banks crossfade over 20 ms.

The render callback must not allocate memory, block, lock, log, call Swift, or access files. Keep publication to one serial producer and rendering to one consumer. Stop the audio callback before destroying its context or DSP. UI response and audio playback must use the same coefficient implementation. Preserve strict finite/range checks and the existing parameter bounds.

## Review and acceptance

Add the smallest reproducible check for a behavior change. Run the full check script before submitting, and exercise changed UI controls with the keyboard and relevant accessibility settings. Include the observed result and any untested device/OS boundaries in the change description.

Audio-route changes also need the relevant manual checks in [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md). Record hardware, OS version, sample rate, exact build/commit, procedure, and measurements; do not turn an untested row into a pass because the code builds. Keep raw audio recordings out of bug reports; synthetic test signals and logs without private content are preferable.

For releases, align the bundle version and release archive name, complete hardware and clean-install acceptance, then run `scripts/notarize.sh` with maintainer credentials. Keep signing credentials out of the repository. Publish the matching source revision, notarized universal archive, checksum, and known compatibility limits together. The notarization script itself performs no publication.
