<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Release acceptance record

Status: **development preview; not accepted for public binary release**.

This record separates deterministic checks from actual playback, supported-platform acceptance, and distribution. Only mark a checkbox after recording evidence from the named build and device. The universal build and passing DSP tests cannot establish real-device volume, latency, recovery, or protected-media behavior.

## Evidence available on 2026-10-13

- Development host: Apple Silicon, macOS 27.0.1.
- Local candidate: version 0.1.0, code revision `b49d888`, universal `arm64` + `x86_64`, ad-hoc signed. Both architecture slices declare macOS 14.2 as their minimum. This does not verify execution on Intel or macOS 14.2.
- The check script passed 15 Swift tests, Core Audio teardown fault-injection checks, the standalone C callback harness, plist validation, and whitespace checks. Tests cover actual DSP tone/impulse response, exact unity output, bypass ramps, parameter limits, 32-band processing, rapid edits, clipping, APO import/export, and persistence. Fault injection covers failed stop/destruction, cleanup retries, and bounded shutdown with a stalled control queue.
- A separate ThreadSanitizer stress run completed 50,000 parameter publications concurrent with 768,000 rendered frames without reported races. This is a software concurrency result, not a live audio measurement.
- No valid Developer ID signing identity was available on the development host. No signed/notarized release or clean-install result has been established.

## Limited live checks on the development host

The following checks used the local 0.1.0 candidate on 2026-10-13. Measurements are the app's digital peak readings, not independent measurements at the physical output.

- The user granted System Audio Recording permission. Startup completed on FiiO K11 at 48 kHz. Subsequent starts completed without the initial permission wait.
- A generated stereo 997 Hz tone, amplitude 0.005 with short fade-in/out ramps, was played with `afplay`. With ten flat bands and 0 dB preamp, the peak read **−46.1 dBFS**. Setting preamp to −6 dB produced **−52.1 dBFS**. Enabling bypass restored **−46.1 dBFS**. This verifies the live capture/DSP/meter path and preamp removal in bypass; it does not establish speaker level, volume-key behavior, or added latency.
- Selecting MacBook Pro Speakers while processing rebuilt the route at 48 kHz; the same tone registered −46.1 dBFS. Physical disconnects and Bluetooth were not tested.
- Stop completed without an error and reported native playback restored. Closing the window kept the process alive; reopening the latest build through Finder restored the main window. A development instance was force-terminated after test playback ended; forced termination **during** playback and independently measured native recovery remain pending.
- Native sliders, numerical gain editing, graph updates, bypass, and the final window layout were exercised. Full keyboard-only and VoiceOver acceptance remain pending.
- The final app was left stopped, with Flat selected, preamp at 0 dB, bypass off, and FiiO K11 selected.

The full playback and distribution checkboxes below remain pending; the limited observations above do not satisfy an entire checklist item.

## Device and platform matrix

Record the exact device, connection, OS build, CPU, app commit/version, and sample rate with each result.

| Target | Required coverage | Status |
| --- | --- | --- |
| Built-in output | Full playback/recovery checklist | Partial: live route and digital peak observed; full acceptance pending |
| Wired/USB output, including FiiO K11 | Full checklist; distinguish hardware volume from macOS-controlled volume | Partial: live preamp/bypass verified; full acceptance pending |
| Bluetooth stereo output | Full checklist; reconnect and profile/sample-rate changes | Pending |
| macOS 14.2 | Install, permission, start/stop, routing, UI fallback, recovery | Pending |
| Intel Mac | Native execution and full playback checklist | Pending |
| macOS 26+ | Native glass UI and accessibility settings | Partial: macOS 27.0.1 launch/layout verified; accessibility acceptance pending |

A device that does not expose the supported stereo float format should produce a clear stopped/error state with ordinary playback available. Mark that scenario as an observed limitation, not as successful EQ playback.

## Playback and failure checks

- [ ] **Unity first:** use flat filters and 0 dB preamp, then bypass. Compare with native playback for channel mapping, level, duplication/feedback, distortion, and silence handling before assessing tuned presets.
- [ ] **Volume:** on each applicable output compare native, flat, and bypass at macOS 25%, 50%, and 100%; test mute, unmute, and volume keys. Record unsupported software-volume controls explicitly and verify the device's hardware control separately. There must be no unexplained gain jump or double attenuation.
- [ ] **EQ and headroom:** verify an audible/measured known response, rapid gain/Q/frequency changes, band enable/disable, preset changes, and bypass. Confirm peak indication and clipping with a controlled signal; headroom guidance must not be presented as a limiter.
- [ ] **Lifecycle:** close/reopen the main window, use menu presets, stop, quit normally, and force-terminate during playback. Confirm native playback returns and no stale capture route prevents normal output.
- [ ] **Routing:** switch the default output in macOS and in the app; disconnect/reconnect wired and Bluetooth devices; change sample rate/format; sleep and wake. Record automatic recovery versus the documented explicit restart after an error.
- [ ] **Permissions:** first allow, deny, later grant, and revoke system-audio permission. Confirm understandable state and recovery without recording or processing a physical microphone stream.
- [ ] **Unsupported route:** exercise a virtual/aggregate or multichannel default and an incompatible format. Confirm a stopped/error state, no feedback, and native playback availability.
- [ ] **Sustained playback:** run a documented duration with normal desktop load, default ten-band and maximum 32-band presets. Record dropouts, CPU/memory behavior, and the actual duration. No result or duration is assumed here.
- [ ] **Added latency:** use a repeatable loopback/measurement method with the same device and settings for native and processed playback; record sample rate, buffer size, baseline, processed result, delta, repetitions, and audible/video-sync assessment. No latency number is currently available.
- [ ] **Protected media:** test identified services/apps with permission to play their content. Record whether playback is captured, bypassed, silent, or rejected and publish observed limits; do not imply universal DRM compatibility.

## UI and distribution checks

- [ ] Verify keyboard-only band selection/editing, sliders, presets, import/export, start/stop, bypass, and menu-bar operation.
- [ ] Verify VoiceOver labels and values, light/dark appearance, reduced transparency/motion settings, large text where available, and material fallback on an older supported OS.
- [ ] Exercise malformed APO import and corrupted local state in a disposable profile; confirm line-number errors, unchanged current preset, preserved files, and backup recovery.
- [ ] Obtain maintainer Developer ID and notarization credentials; run `./scripts/notarize.sh` successfully for the exact release revision.
- [ ] Verify both architecture slices, code signature, notarization ticket, Gatekeeper assessment, archive contents, version, and checksum.
- [ ] Download the signed candidate on a clean Mac/account through the intended distribution path; install, launch with normal Gatekeeper checks, grant permission, process audio, quit, and remove it. Do not substitute a developer-machine launch for this check.
- [ ] Publish the source revision and corresponding free signed universal binary together through GitHub Releases, with checksum, build instructions, license/notices, and observed compatibility limits. Publication is pending.

## Result format

For each completed item record: date, tester, source commit/app version, macOS build/CPU, output and connection, sample rate/buffer settings, exact procedure, expected result, observed result/measurements, and pass/fail/limitation. Link non-sensitive supporting logs or plots. Leave unavailable hardware and unfinished checks explicitly pending.
