<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Release acceptance record

Status: **1.0.0 community distribution authorized without notarization; full hardware and signed-distribution acceptance incomplete**.

This record separates deterministic checks from actual playback, supported-platform acceptance, and distribution. Only mark a checkbox after recording evidence from the named build and device. The universal build and passing DSP tests cannot establish real-device volume, latency, recovery, or protected-media behavior.

## Community publication decision — 2026-10-16

The maintainer explicitly requested publishing the current build on GitHub with a one-command installer despite the unavailable Developer ID certificate. Version 1.0.0/build 3 is distributed ad-hoc signed, with that limitation disclosed. The installer retains strict default behavior; `--allow-unnotarized` permits installation after checksum/identity/code-integrity validation but never auto-launches an app rejected by Gatekeeper. No Gatekeeper setting, quarantine attribute, or audio permission is changed. The device and signed-release checkboxes below remain pending. This decision supersedes the earlier publication hold, not the verification record.

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

## 1.0.0 candidate update — 2026-10-16

- Version 1.0.0/build 2, universal arm64/x86_64 with macOS 14.2 minimum, ad-hoc signed on the same Apple Silicon/macOS 27.0.1 development host. This is preparation, not approval for a public stable release.
- All **21 Swift tests** passed, plus the app self-checks, C callback harness, installer checks, plist and whitespace checks. New coverage includes bounded four-channel snapshots across callback chunks, in-place processing, final clipping, bypass, concurrent snapshot ownership, decimal/comma input boundaries, and FFT levels with opposite-phase stereo at 44.1/48/96 kHz.
- Actual keyboard entry accepted `0` followed by `.2` in Q with no interruption; Return committed 0.2. Invalid `0` on Tab retained 0.2 and marked the field without a modal alert. `0,71` restored the original value; Escape cancelled a later draft. The final compact UI showed the graph, all ten bands, inspector, and footer in the saved window without a vertical scrollbar; preamp units no longer wrapped. Primary-action glass follows native styling while graph/editor/status surfaces are opaque. Full VoiceOver and appearance testing remains pending.
- After the user allowed audio access and the app was restarted, live analysis ran on FiiO K11 at 48 kHz/128-frame I/O. A synthetic stereo 1 kHz tone at amplitude 0.005 showed approximately −46 dBFS before EQ and −51 dBFS after the DT990 preset; the output meter read −50.6 dBFS. Bypass made both spectrum peaks approximately −46 dBFS, with output meter −46.1 dBFS. These are digital observations, not measured acoustic response or added latency.
- Analysis uses bounded 2,048-frame snapshots requested only on the visible live-audio tab, and Accelerate FFT on the control queue. It adds no playback queue. The graph cannot establish Harman target matching because raw headphone/target acoustic measurements are not bundled.
- Preset state was compared with the pre-test copy; original tuning was restored. The app was left stopped, matching its state at the start of this session. No valid signing identity was available when rechecked. Notarization, clean installation, and the unresolved hardware matrix remain release prerequisites.

## Smooth UI candidate — 2026-10-16

- Version 1.0.0/build 3 passed all **22 Swift tests**, app self-checks, C callback and installer checks. Universal compilation and local ad-hoc signature verification passed. New checks compare batched response against the original playback-coefficient calculation at 44.1/48/96 kHz and cover silent/finite paths, peak-preserving display reduction, and visible/hidden polling cadence.
- Core Animation interpolates fixed-topology curves; live analysis refreshes at 20 Hz only while visible. Separate observable meter/spectrum models avoid refreshing the entire editor. The analyzer's 128 logarithmic display buckets preserve peaks; 100 ms curve interpolation affects only visualization and settles to the exact final target even when successive audio frames are identical. Reduced motion disables interpolation. No DSP callback or playback queue was added.
- Release-optimized local microbenchmark, 385 frequencies, 100 curves per run, median of five runs: ten bands **0.352 → 0.028 ms/curve (12.5×)**; 32 bands **0.858 → 0.080 ms/curve (10.7×)**. Both paths used identical parameters and checksummed outputs. This measures response computation, not frame rate, audio latency, or total app CPU.
- Native UI inspection confirmed the enlarged graph, unified band panel, correct response orientation, and no vertical scrollbar at 950×768. Slider clicks changed gain, double-click reset to zero, and exact entry restored the original gain. FiiO K11 processing resumed at 48 kHz/128-frame I/O with live before/after traces. Saved preset JSON matched the pre-test copy exactly. Full frame-time profiling and the outstanding hardware/accessibility acceptance remain pending.

## Device and platform matrix

### Headphone profiles and control update — 2026-10-13

- The full check script passed **19 tests**, plus the C callback, teardown fault-injection, frequency-gesture boundary, plist, and whitespace checks. The catalog check validates all 12,588 bundled profiles, unique saved names, exact parameter conversion, attribution export/import, and malformed-data rejection. Packaged apps resolve their embedded catalog without relying on a developer's build directory. Legacy preset JSON without attribution still loads.
- On the development Mac, the packaged universal app opened the offline browser, searched by headphone and tuning target, applied the oratory1990 Sennheiser HD 650 profile with its −9.3 dB preamp, and saved it locally. A separate APO text import was saved and applied. An unsupported GraphicEQ import reported line 2 and left the previous preset and saved data intact.
- Actual mouse checks confirmed both band and preamp double-click reset to 0 dB. Frequency dragging changed 31.25→62.5 Hz to the right, 62.5→88.39 Hz upward, 88.39→62.5 Hz downward, and 62.5→52.56 Hz to the left. Exact numerical editing remained available.
- These profile/UI checks ran with processing stopped. The user's original tuning and saved presets were restored afterward; temporary test imports were removed. The hardware release matrix remains separate.

### BalanceEQ background and latency update — 2026-10-13

- The renamed app builds for both arm64 and x86_64 with macOS 14.2 minimum, keeps the existing bundle identifier and preset store, and is still ad-hoc signed. All 19 Swift tests, C callback checks, lifecycle/buffer fault-injection checks, plist validation, and whitespace checks passed. New checks cover stopped polling, hidden metering, unchanged-state publication, buffer bounds, delayed property application, restoration timeouts, and another client's buffer changes.
- Native UI inspection confirmed the B/EQ logo, Apple blue controls, integrated native window buttons, and no vertical or horizontal scrollbar with the user's attributed ten-band DT990 profile at the default window size. Closing the window kept the process alive; reopening retained processing and resumed live metering. BalanceEQ uses accessory activation and `LSUIElement` for menu-bar operation without a Dock icon.
- On FiiO K11 at 48 kHz the app's private aggregate reported **128 frames** (2.67 ms per callback buffer). The physical device remained at its original **512 frames**, both during processing and after Stop/Quit. This device did not require a propagated physical-buffer restoration; that branch has injected software checks, not real-device acceptance yet. These values do not establish end-to-end or added EQ latency.
- The quiet 997 Hz test tone registered **−50.6 dBFS** with the user's DT990 tuning. After closing/reopening, processing and metering remained active. Stop reported native playback restored; normal Quit while processing exited the process. No new permission prompt appeared during these starts. Presets and tuning were preserved unchanged.
- A short closed-window sample showed CPU time rising from 1.31 to 1.53 seconds over 39 seconds of elapsed time (about **0.56% of one CPU core**), with 135,280 KiB RSS. It included brief test-tone playback and silence, not a sustained-load benchmark. The GUI meter is suspended while hidden; a small callback-error watchdog remains active to release capture promptly on failure.
- Persistent local signing is now supported with an existing certificate. None is configured on this host; ad-hoc rebuilds can still prompt again. macOS's active system-audio privacy indicator remains expected during processing. Public Developer ID signing, notarization, supported-platform checks, and physical latency measurement remain pending.

### Discord stream echo fix — 2026-10-13

- Stable Discord and its Electron helpers are excluded from the tap, preserving their native playback identity instead of replaying voice chat through BalanceEQ. macOS 26+ also receives bundle-ID exclusions before clients launch; a Core Audio process-list listener refreshes process exclusions without restarting the route. An update failure stops processing through the existing cleanup path.
- All 19 Swift tests and the check script passed, including new checks for Discord/helper matching, unrelated bundle IDs, and tap-description process replacement. Both architecture slices built and the local ad-hoc signature verified.
- The updated app resumed processing on FiiO K11 at 48 kHz with 128-frame I/O and live metering. Saved profiles loaded; the user changed the selected profile during the live check, and that change was retained. Discord had no audio client in the read-only HAL enumeration, so actual Discord voice/stream exclusion and launch/relaunch remain unverified.
- Acceptance still requires a direct Discord stream with a second participant: check no returned voice, game/music stream audio, Discord launched before and after EQ, helper restart/reconnect, and macOS 14.2 behavior. The pre-26 listener reacts after process registration and cannot guarantee exclusion of the first buffers of a newly launched client. Discord browser sessions and PTB/Canary are not covered by this stable-desktop exception.

### Hardware acceptance

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
- [ ] Run the README's one-command installer on a clean Mac without Xcode or Homebrew, then update an existing installation. Verify the published checksum/signature, Gatekeeper approval, first launch, and preservation of presets. Ten isolated installer checks cover success and failure/rollback paths; downloads and signing approval are simulated in those checks and do not establish this acceptance result.
- [ ] Publish the source revision and corresponding free signed universal binary together through GitHub Releases, with checksum, build instructions, license/notices, and observed compatibility limits. Publication is pending.

## Result format

For each completed item record: date, tester, source commit/app version, macOS build/CPU, output and connection, sample rate/buffer settings, exact procedure, expected result, observed result/measurements, and pass/fail/limitation. Link non-sensitive supporting logs or plots. Leave unavailable hardware and unfinished checks explicitly pending.
