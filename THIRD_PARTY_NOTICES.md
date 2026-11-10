# Third-party notices

BalanceEQ is licensed under GNU GPL version 3 or any later version.
See LICENSE for the full license. The app is provided without warranty.

The app links to Apple's system frameworks (SwiftUI, AppKit, Core Audio,
Accelerate, Foundation and Combine). Their implementation is provided by macOS;
these frameworks are not bundled.

## Sparkle updates

The app bundles [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/tree/2.10.1),
pinned to commit `ab7d71291238df6e0492143b120c9b696a35f603`, for native software updates.
Sparkle is MIT licensed, with additional BSD/zlib-licensed components. Its complete
license and component notices are retained in `Resources/Sparkle-LICENSE.txt` and
copied into the app. Update checks are manual; system profiling and automatic
installation are disabled. Sparkle does not participate in audio processing.

The original DSP implementation follows the equations in Robert Bristow-Johnson's
Audio EQ Cookbook, published by the W3C Audio Working Group:
https://www.w3.org/TR/audio-eq-cookbook/
The reference is used for mathematical formulas, not copied source code.

Equalizer APO text compatibility follows the upstream configuration reference:
https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/
Equalizer APO and Peace are independent projects. This app does not contain their
code, use their branding, or claim affiliation.

## OPRA headphone profiles

The bundled headphone catalog and logo come from [OPRA — Open Profiles for
Revealing Audio](https://github.com/opra-project/OPRA), a community-maintained
directory of headphone information and EQ profiles. The dataset is licensed
under **Creative Commons Attribution-ShareAlike 4.0 International**, separately
from this app's GPL license. Individual profile creators are credited in the
browser, saved presets, and exported APO text.

The source is pinned to commit
[`0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865`](https://github.com/opra-project/OPRA/tree/0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865).
We convert its `dist/database_v1.jsonl` into a compact offline catalog, preserving
the parameters of 12,588 complete profiles. Six profiles with unsupported filter
conventions or parameter ranges are excluded; no filter is approximated. The
converted dataset remains under CC BY-SA 4.0. OPRA includes contributions from
AutoEQ and other profile creators; its supplied third-party notices are retained.

Bundled source resources:

- [Dataset license](Sources/EQCore/Resources/OPRA-LICENSE.md)
- [Upstream third-party notices](Sources/EQCore/Resources/OPRA-THIRD_PARTY_LICENSES.md)
- [Provenance](Sources/EQCore/Resources/OPRA-Provenance.txt) and [excluded profiles](Sources/EQCore/Resources/OPRA-Excluded.json)
- [Converted catalog](Sources/EQCore/Resources/headphones.json) and [official logo](Sources/EQCore/Resources/opra_logo_landscape.png)

[scripts/update-headphone-catalog.py](scripts/update-headphone-catalog.py)
reproduces the conversion from the pinned upstream dataset.

## AutoEq calibration measurements and targets

The calibration catalog is derived from [AutoEq](https://github.com/jaakkopasanen/AutoEq)
at commit `7ae0f56d53074872b028649617a22bbb4232feb7`, under its MIT license.
Copyright (c) 2018–2022 Jaakko Pasanen. The complete license is retained in
`Sources/EQCore/Resources/AutoEq-LICENSE.txt` and the packaged resource bundle.
Each entry credits the measurement source, exact variant, and immutable result URL.
Published measurement and target samples are preserved; only supported paired
parametric settings are included. Missing/unsupported pairs are listed in
`AutoEq-Excluded.json`; `AutoEq-Provenance.txt` records the conversion.

`scripts/update-calibration-catalog.py` reproduces the offline catalog. The app
includes no AutoEq Python runtime, Sonarworks calibration data or SoundID code.
SoundID is an independent product; BalanceEQ is not affiliated with Sonarworks.

For 1.2, `scripts/update-calibration-targets.py` extracts explicit recommended and
compatible rig mappings from the same pinned AutoEq `dbtools/create_webapp_data.py`.
Nine source target curves and 50 source/variant mappings are bundled in
`calibration-targets.json`. `Calibration-Targets-Provenance.txt` records the source;
`Calibration-Target-Exclusions.json` lists 90 measurements without compatible Harman
mappings. Neutral omits the preference bass shelf; Harman retains AutoEq’s documented
bass gain, 105 Hz center and Q 0.7. Target samples retain their original MIT license.
