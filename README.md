<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Equalizer for Mac

A native, free macOS equalizer inspired by the workflow of Equalizer APO and Peace. SwiftUI controls sit above a small C audio engine. There are no accounts, ads, subscriptions, telemetry, installed audio drivers, or third-party runtime packages.

**Development preview:** the source and local build are available in this checkout. A signed public release has not been produced. Hardware audio acceptance, macOS 14.2 compatibility, and Intel runtime testing remain pending; see [the acceptance record](docs/ACCEPTANCE.md). Building successfully does not establish those results.

## Build and run

The deployment target is macOS 14.2 or later, for Apple Silicon and Intel. Building requires Xcode 26 or later, its command-line tools selected, and its license accepted. The macOS 26 SDK is needed to compile native Liquid Glass; earlier supported systems use standard materials.

```sh
./scripts/check.sh
./scripts/build-app.sh
open "build/Equalizer for Mac.app"
```

The build script creates a universal `arm64` + `x86_64` app by default. For a faster local Apple Silicon build, run `ARCHITECTURES=arm64 ./scripts/build-app.sh`. Local builds are **ad-hoc signed**, without a Developer ID or notarization. They are developer builds, not the intended public download.

Device enumeration is available without starting capture or changing audio settings:

```sh
"build/Equalizer for Mac.app/Contents/MacOS/EqualizerMac" --diagnose
```

## Using the equalizer

- Start with the ten-band Flat preset, then select a band to edit frequency, gain, Q, type, or enablement. Add or remove bands, up to 32. Types are peaking, low/high shelf, low/high pass, and notch. The response graph uses the playback engine's coefficients.
- Choose **Start** to enable processing. macOS may request System Audio Recording permission. That permission permits the audio tap; this app processes samples in memory and does not save or upload recordings. It excludes its own playback and disables unused physical input streams.
- The app follows the macOS default output. Selecting **System output** changes that default. This version processes one physical stereo output with one supported 32-bit floating-point PCM stream. Virtual/aggregate outputs, multichannel processing, per-app routing, separately routed alerts, convolution, and protected-media guarantees are outside this version's scope.
- **Bypass** transitions to the original signal, removing both filters and preamp while routing stays active. **Stop** and **Quit** release the tap and private aggregate device. Closing the window keeps processing active; reopen it or select presets from the menu bar. Processing starts only when you request it.
- Output or sample-rate changes rebuild the route. Sleep pauses it; wake reconnects if processing was requested. Unsupported formats or processing errors stop the engine with a status message. Correct the cause and start again.
- **Apply recommended headroom** estimates steady-state gain from the filter response. It is not a limiter or a guarantee against clipping. The peak meter measures samples before the final output boundary, where samples above digital full scale are hard-clipped to `[-1, 1]`; clipping is indicated.

The UI follows light/dark appearance, uses native Liquid Glass on macOS 26+, and supplies standard-material and reduced-transparency fallbacks. Native controls have keyboard operation and accessibility labels. There are no decorative motion effects; VoiceOver and accessibility acceptance still require the checks below.

| Setting | Accepted range |
| --- | --- |
| Frequency | 10–20,000 Hz; enabled filters must be below the current output's Nyquist frequency |
| Band gain | −24 to +24 dB |
| Q | 0.1–30 |
| Preamp | −60 to +12 dB |
| Engine sample rate | 8,000–384,000 Hz, subject to the output's supported format |

Disabled bands can retain frequencies above the current Nyquist limit. Bypass also permits those stored frequencies. Enabling processing with an incompatible active band requires lowering its frequency or disabling it.

## Presets and Equalizer APO compatibility

**Save a Copy** creates a named preset without overwriting another. Named presets and the current draft are stored locally in `~/Library/Application Support/EqualizerForMac/state.json`. Saves validate a versioned JSON document, write atomically, and retain the previous valid document as `state.backup.json`. Corrupt or unsupported saved data is reported and preserved; it is not silently replaced. To recover manually, quit the app, preserve the damaged file elsewhere, and restore an inspected backup.

Import/export supports UTF-8 text up to 64 KiB and at most 32 numbered filters. Commands and keywords are case-insensitive; `#` comments and blank lines are accepted. Only the following forms are supported:

```text
Preamp: -6 dB
Filter 1: ON PK Fc 1000 Hz Gain 4 dB Q 1.4
Filter 2: OFF PEQ Fc 200 Hz Gain -2 dB Q 2
Filter 3: ON LSC Fc 100 Hz Gain 3 dB Q 0.707
Filter 4: ON HSC Fc 10000 Hz Gain -3 dB Q 0.707
Filter 5: ON HPQ Fc 20 Hz Q 0.707
Filter 6: ON LPQ Fc 16000 Hz Q 0.707
Filter 7: ON NO Fc 4000 Hz Q 5
```

`ON` and `OFF` work for every supported type. `LSC`/`HSC` use the shelf's **center** frequency and explicit Q. `NO` alone may omit Q, which defaults to 30. `PK`/`PEQ` and shelves require both gain and Q; `HPQ`/`LPQ` require Q. Filter numbers must be positive and unique; file order is preserved. An omitted preamp defaults to 0 dB; duplicate preamp commands are rejected.

`LS`/`HS` corner shelves, slope/bandwidth forms, `LP`/`HP`, GraphicEQ, Include, Device, Channel, expressions, and other commands are rejected with line numbers. The entire import must validate before replacing the current preset. This is not full Peace configuration compatibility.

APO treats a trailing group of exactly three decimal digits in a frequency as a thousands group: `1.000 Hz` means 1,000 Hz. Use an exponent for unambiguous fractional frequencies, such as `31.125e0 Hz`. Exports use this form.

## Development and release

`./scripts/check.sh` runs Swift tests for DSP, presets, and APO compatibility, the C audio-callback harness, plist validation, and `git diff --check`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the small code structure and [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) for the separate hardware release gate.

A maintainer with a Developer ID Application certificate and an existing `notarytool` keychain profile can produce a signed candidate:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notary-profile" ./scripts/notarize.sh
```

The script reruns checks, builds both architectures, signs with the hardened runtime, submits to Apple, staples the ticket, checks Gatekeeper, and creates `build/Equalizer-for-Mac-0.1.0.zip` with a SHA-256 sidecar. It does not publish a GitHub release. The source and corresponding free signed binary should be published together only after the acceptance record is complete.

Licensed under [GNU GPL version 3 or any later version](LICENSE), without warranty. Our releases are free; the license also permits paid redistribution subject to its terms. Equalizer APO and Peace are independent projects; this project is not affiliated with them. See [third-party notices](THIRD_PARTY_NOTICES.md).
