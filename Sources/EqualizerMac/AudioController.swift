// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import CoreAudio
import CEQ
import EQCore

struct AudioOutput: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var selectedOutputID: AudioDeviceID = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "Ready. Start to enable system-wide EQ."
    @Published private(set) var sampleRate = 48000.0
    @Published private(set) var peakDB = -120.0
    @Published private(set) var clipping = false

    private let worker = AudioWorker()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var startPending = false
    private var startupGeneration = 0

    init() {
        worker.publish = { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.outputs != state.outputs { self.outputs = state.outputs }
                if self.selectedOutputID != state.selected { self.selectedOutputID = state.selected }
                if self.isRunning != state.running { self.isRunning = state.running }
                if state.starting { self.startPending = false }
                if !self.startPending { self.setStarting(state.starting) }
                if self.status != state.status { self.status = state.status }
                if self.sampleRate != state.sampleRate { self.sampleRate = state.sampleRate }
                if self.peakDB != state.peakDB { self.peakDB = state.peakDB }
                if self.clipping != state.clipping { self.clipping = state.clipping }
            }
        }
        worker.initialize()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak worker] _ in worker?.sleep() })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak worker] _ in worker?.wake() })
    }

    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        worker.shutdown()
    }

    func refreshDevices() { worker.refresh() }
    func start(preset: EQPreset, bypassed: Bool) {
        guard !isStarting else { return }
        startPending = true
        setStarting(true)
        status = "Starting. Allow System Audio Recording if macOS asks."
        worker.start(preset: preset, bypassed: bypassed)
    }
    func stop() { worker.stop() }
    func shutdown() { worker.shutdown() }
    func update(preset: EQPreset, bypassed: Bool) { worker.update(preset: preset, bypassed: bypassed) }
    func selectOutput(_ id: AudioDeviceID) { worker.selectOutput(id) }
    func setMeteringEnabled(_ enabled: Bool) { worker.setMeteringEnabled(enabled) }

    private func setStarting(_ starting: Bool) {
        guard isStarting != starting else { return }
        isStarting = starting
        startupGeneration += 1
        guard starting else { return }
        let generation = startupGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
            guard let self, self.isStarting, generation == self.startupGeneration else { return }
            self.status = "Audio startup is waiting for macOS. Check for an audio permission prompt; quit and reopen if needed."
        }
    }

    /// Read-only: no tap, IOProc, permission request, or device setting changes.
    nonisolated static func diagnostics() -> String {
        do {
            let selected = try HAL.defaultOutput()
            let devices = try HAL.outputs()
            let lines = try devices.map { output in
                let rate = try HAL.sampleRate(output.id)
                return "\(output.id == selected ? "*" : " ") \(output.name): \(Int(rate)) Hz (id \(output.id))\n  \(HAL.bufferDiagnostics(output.id, sampleRate: rate))"
            }
            return "Eligible stereo outputs (* = macOS default):\n" + lines.joined(separator: "\n") +
                "\nBuffer durations and HAL-reported latency are not a measurement of added EQ latency." +
                "\nDiscord audio clients kept outside EQ: \(try HAL.discordProcesses())"
        } catch { return "Audio diagnostics: \(error.localizedDescription)" }
    }

    #if DEBUG
    /// Fault-inject HAL failures without opening a device or requesting permission.
    nonisolated static func checkCleanupHandling() {
        var aggregate: AudioObjectID = 42
        var tap: AudioObjectID = 43
        var proc: AudioDeviceIOProcID? = eq_audio_io_proc
        var mayRun = true
        var tapAttempts = 0
        let fail: OSStatus = -1
        let retained = HAL.releaseRoute(aggregate: &aggregate, proc: &proc, tap: &tap, callbackMayRun: &mayRun,
            stop: { _, _ in fail }, destroyProc: { _, _ in preconditionFailure("Callback may still execute") },
            destroyAggregate: { _ in preconditionFailure("Aggregate destruction is asynchronous") },
            destroyTap: { _ in tapAttempts += 1; return noErr })
        precondition(retained != nil && mayRun && aggregate == 42 && proc != nil && tap == 43 && tapAttempts == 0)
        let callbackRetained = HAL.releaseRoute(aggregate: &aggregate, proc: &proc, tap: &tap, callbackMayRun: &mayRun,
            stop: { _, _ in noErr }, destroyProc: { _, _ in fail },
            destroyAggregate: { _ in preconditionFailure("Callback is still registered") },
            destroyTap: { _ in preconditionFailure("Aggregate is still retained") })
        precondition(callbackRetained != nil && !mayRun && aggregate == 42 && proc != nil && tap == 43)
        let stopped = HAL.releaseRoute(aggregate: &aggregate, proc: &proc, tap: &tap, callbackMayRun: &mayRun,
            stop: { _, _ in preconditionFailure("Already stopped") },
            destroyProc: { _, _ in noErr }, destroyAggregate: { _ in fail },
            destroyTap: { _ in tapAttempts += 1; return noErr })
        precondition(stopped != nil && !mayRun && aggregate == 42 && proc == nil && tap == 43 && tapAttempts == 0)
        let tapRetained = HAL.releaseRoute(aggregate: &aggregate, proc: &proc, tap: &tap, callbackMayRun: &mayRun,
            stop: { _, _ in preconditionFailure("Already stopped") },
            destroyProc: { _, _ in preconditionFailure("Already destroyed") },
            destroyAggregate: { _ in noErr }, destroyTap: { _ in fail })
        precondition(tapRetained != nil && aggregate == 0 && proc == nil && tap == 43)
        let released = HAL.releaseRoute(aggregate: &aggregate, proc: &proc, tap: &tap, callbackMayRun: &mayRun,
            stop: { _, _ in preconditionFailure("Already stopped") },
            destroyProc: { _, _ in preconditionFailure("Already destroyed") },
            destroyAggregate: { _ in preconditionFailure("Already destroyed") }, destroyTap: { _ in noErr })
        precondition(released == nil && aggregate == 0 && proc == nil && tap == 0)

        // Simulate a HAL call waiting for permission without opening any audio resources.
        let stalledWorker = AudioWorker()
        let releaseControlQueue = DispatchSemaphore(value: 0)
        stalledWorker.queue.async { releaseControlQueue.wait() }
        let shutdownStarted = ProcessInfo.processInfo.systemUptime
        stalledWorker.shutdown()
        precondition(ProcessInfo.processInfo.systemUptime - shutdownStarted < 2.5,
            "A stalled audio control queue must not block application termination")
        releaseControlQueue.signal()
        stalledWorker.queue.sync {} // Drain the queued, resource-free cleanup.
        stalledWorker.shutdown() // A repeated shutdown is a no-op.
        AudioWorker.checkMeteringHandling()
        HAL.checkDiscordExclusions()
        precondition(HAL.preferredBufferFrames(current: 512, range: AudioValueRange(mMinimum: 15, mMaximum: 4096)) == 128)
        precondition(HAL.preferredBufferFrames(current: 64, range: AudioValueRange(mMinimum: 15, mMaximum: 4096)) == 64)
        precondition(HAL.preferredBufferFrames(current: 512, range: AudioValueRange(mMinimum: 256, mMaximum: 4096)) == 256)
        precondition(HAL.preferredBufferFrames(current: 512, range: AudioValueRange(mMinimum: 15, mMaximum: 64)) == 64)
        precondition(HAL.preferredBufferFrames(current: 512, range: AudioValueRange(mMinimum: 0, mMaximum: .infinity)) == nil)
        var restore: (device: AudioDeviceID, original: UInt32, applied: UInt32, pending: Bool)? = (42, 512, 128, false)
        precondition(HAL.restoreBuffer(&restore, read: { _ in 64 }, set: { _, _ in
            preconditionFailure("Never overwrite another client's buffer change")
        }) == nil && restore == nil)
        restore = (42, 512, 128, false)
        precondition(HAL.restoreBuffer(&restore, read: { _ in 128 }, set: { _, _ in -1 }) != nil && restore != nil)
        precondition(HAL.restoreBuffer(&restore, read: { _ in 128 }, set: { _, _ in noErr }, pause: {}) != nil && restore != nil)
        var reads = 0
        precondition(HAL.restoreBuffer(&restore, read: { _ in reads += 1; return reads < 3 ? 128 : 512 }, set: { device, frames in
            precondition(device == 42 && frames == 512)
            return noErr
        }, pause: {}) == nil && restore == nil && reads == 3)
        restore = (42, 512, 128, true)
        var restoredPending = false
        precondition(HAL.restoreBuffer(&restore, read: { _ in 512 }, set: { _, _ in restoredPending = true; return noErr },
                                      pause: {}) == nil && restoredPending && restore == nil)
    }
    #endif
}

private struct AudioState: Equatable, Sendable {
    var outputs: [AudioOutput] = []
    var selected: AudioDeviceID = 0
    var running = false
    var starting = false
    var status = "Ready. Start to enable system-wide EQ."
    var sampleRate = 48000.0
    var peakDB = -120.0
    var clipping = false
}

// All HAL objects and DSP ownership stay on this queue; the render path is C only.
private final class AudioWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "org.equalizermac.audio-control", qos: .userInitiated)
    var publish: ((AudioState) -> Void)?
    private var state = AudioState()
    private var lastPublished: AudioState?
    private var preset: EQPreset?
    private var bypassed = false
    private var wantsRunning = false
    private var sleeping = false
    private var cleanupBlocked = false
    private var tap: AudioObjectID = 0
    private var tapDescription: CATapDescription?
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var callbackMayRun = false
    private var dsp: OpaquePointer?
    private var context: OpaquePointer?
    private var route: AudioDeviceID = 0
    private var routeSignature = ""
    private var bufferFrames: UInt32 = 0
    private var bufferRestore: (device: AudioDeviceID, original: UInt32, applied: UInt32, pending: Bool)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var routeListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var meterTimer: DispatchSourceTimer?
    private var meteringEnabled = false
    private var changeGeneration = 0
    private let shutdownLock = NSLock()
    private var shutdownRequested = false // Protected by shutdownLock; never read on the render thread.
    private var isShuttingDown = false // Control queue only.

    func initialize() {
        queue.async { [self] in
            do {
                try self.listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
                try self.listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
                try self.refreshOnQueue()
                self.emit()
            } catch { self.fail(error) }
        }
    }

    func refresh() { queue.async { self.hardwareChanged() } }
    func setMeteringEnabled(_ enabled: Bool) {
        queue.async {
            guard self.meteringEnabled != enabled else { return }
            self.meteringEnabled = enabled
            if enabled { self.poll() }
        }
    }
    func start(preset: EQPreset, bypassed: Bool) {
        queue.async {
            self.preset = preset
            self.bypassed = bypassed
            self.sleeping = false // An explicit user action can recover from a missed wake notification.
            self.wantsRunning = true
            self.restart()
        }
    }
    func stop() {
        queue.async {
            self.wantsRunning = false
            if self.teardown() { self.state.status = "Stopped. Native playback restored." }
            self.emit()
        }
    }
    func update(preset: EQPreset, bypassed: Bool) {
        queue.async {
            self.preset = preset
            self.bypassed = bypassed
            guard self.state.running, !self.cleanupBlocked, let dsp = self.dsp else { return }
            do {
                var parameters = try preset.parameters(sampleRate: self.state.sampleRate, bypassed: bypassed)
                guard eq_dsp_set_parameters(dsp, &parameters) else {
                    throw AudioFailure("The EQ settings are invalid for this output sample rate.")
                }
                self.state.status = self.processingStatus
                self.emit()
            } catch { self.fail(error) }
        }
    }

    func selectOutput(_ id: AudioDeviceID) {
        queue.async {
            guard !self.cleanupBlocked else { self.emit(); return }
            do {
                let outputs = try HAL.outputs()
                guard outputs.contains(where: { $0.id == id }) else {
                    throw AudioFailure("This output is unavailable or does not expose a supported stereo stream.")
                }
                var selected = id
                var address = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
                try HAL.check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                    0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &selected), "Select output")
                self.hardwareChanged()
            } catch {
                self.state.status = error.localizedDescription
                self.emit()
            }
        }
    }

    func sleep() {
        queue.async {
            self.sleeping = true
            if self.teardown() {
                self.state.status = self.wantsRunning ? "Paused while your Mac sleeps." : "Ready. Start to enable system-wide EQ."
            }
            self.emit()
        }
    }
    func wake() {
        queue.async {
            self.sleeping = false
            if self.wantsRunning { self.restart() }
            else {
                if !self.cleanupBlocked { self.state.status = "Ready. Start to enable system-wide EQ." }
                self.hardwareChanged()
            }
        }
    }
    func shutdown() {
        shutdownLock.lock()
        guard !shutdownRequested else { shutdownLock.unlock(); return }
        shutdownRequested = true
        shutdownLock.unlock()
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            defer { finished.signal() }
            isShuttingDown = true
            wantsRunning = false
            teardown()
            removeListeners(&listeners)
            meterTimer?.cancel()
            meterTimer = nil
            publish = nil
        }
        // A permission dialog or stalled HAL server must not trap application termination.
        // The queued closure retains all resources; only its confirmed teardown may free them.
        if finished.wait(timeout: .now() + .seconds(1)) == .timedOut {
            NSLog("Core Audio shutdown is still pending. Audio resources remain retained until cleanup or process exit.")
        }
    }

    private func emit() {
        guard state != lastPublished else { return }
        lastPublished = state
        publish?(state)
    }
    private var processingStatus: String {
        let text = bypassed ? "Bypassed. Original signal; routing remains active." : "Processing system audio."
        return bufferFrames > 0 ? "\(text) · \(bufferFrames)-frame I/O" : text
    }
    private func refreshOnQueue() throws {
        state.outputs = try HAL.outputs()
        state.selected = try HAL.defaultOutput()
        if !state.running, state.selected != 0 {
            state.sampleRate = (try? HAL.sampleRate(state.selected)) ?? state.sampleRate
        }
    }
    private func hardwareChanged() {
        guard !isShuttingDown else { return }
        do {
            try refreshOnQueue()
            if wantsRunning && !sleeping {
                guard state.outputs.contains(where: { $0.id == state.selected }) else {
                    throw AudioFailure("The selected output disconnected or changed to an unsupported format. Choose an output and start again.")
                }
                let signature = try HAL.signature(state.selected)
                if route != state.selected || signature != routeSignature { restart(); return }
                bufferFrames = (try? HAL.value(aggregate, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))) ?? bufferFrames
                state.status = processingStatus
            }
            emit()
        } catch { fail(error) }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        routeOnly: Bool = false) throws {
        var address = HAL.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if selector == kAudioHardwarePropertyProcessObjectList {
                // Process changes must not restart the route or wait for device-event debounce.
                self.refreshTapExclusions()
                return
            }
            self.changeGeneration += 1
            let generation = self.changeGeneration
            self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                guard let self, generation == self.changeGeneration else { return }
                self.hardwareChanged()
            }
        }
        try HAL.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Observe audio device")
        if routeOnly { routeListeners.append((object, address, block)) }
        else { listeners.append((object, address, block)) }
    }

    private func refreshTapExclusions() {
        guard !isShuttingDown, state.running, let description = tapDescription else { return }
        do {
            let processes = try HAL.captureExclusions()
            guard processes != description.processes else { return }
            description.processes = processes
            var reference = Unmanaged.passUnretained(description)
            var address = HAL.address(kAudioTapPropertyDescription)
            try HAL.check(AudioObjectSetPropertyData(tap, &address, 0, nil,
                UInt32(MemoryLayout.size(ofValue: reference)), &reference), "Keep Discord outside EQ")
        } catch {
            // Never keep replaying voice chat after a failed exclusion update.
            fail(error)
        }
    }

    private func removeListeners(_ entries: inout [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]) {
        for (object, storedAddress, block) in entries {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        entries.removeAll()
    }

    private func restart() {
        guard !isShuttingDown else { return }
        state.starting = true
        state.status = "Starting. Allow System Audio Recording if macOS asks."
        emit()
        guard teardown() else { state.starting = false; emit(); return }
        state.starting = true
        defer { state.starting = false; emit() }
        guard wantsRunning, !sleeping, let preset else { return }
        do {
            try refreshOnQueue()
            let output = state.selected
            guard state.outputs.contains(where: { $0.id == output }) else {
                throw AudioFailure("Choose a stereo physical output in macOS Sound settings, then start again.")
            }
            state.status = "Starting. Allow System Audio Recording if macOS asks."
            emit()
            let outputUID = try HAL.string(output, kAudioDevicePropertyDeviceUID)
            let outputStreams = try HAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard outputStreams.count == 1 else {
                throw AudioFailure("This version supports outputs with one stereo stream.")
            }
            let physicalFormat = try HAL.format(outputStreams[0])
            try HAL.validateStereoFloat(physicalFormat)
            let rate = physicalFormat.mSampleRate
            var parameters = try preset.parameters(sampleRate: rate, bypassed: bypassed)
            try listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, routeOnly: true)
            let description = CATapDescription(excludingProcesses: try HAL.captureExclusions(), deviceUID: outputUID, stream: 0)
            if #available(macOS 26.0, *) {
                // Match even before Discord opens its first audio client; older OSes use the listener.
                description.bundleIDs = HAL.discordBundleIDs
            }
            description.name = "BalanceEQ"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")
            tapDescription = description
            let tapFormat = try HAL.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            try HAL.validateStereoFloat(tapFormat)
            guard abs(tapFormat.mSampleRate - rate) < 0.1 else {
                throw AudioFailure("The tap and output sample rates do not match.")
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "BalanceEQ (Private)",
                kAudioAggregateDeviceUIDKey: "org.equalizermac.private.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create audio route")
            var alive = false
            for _ in 0..<40 {
                if (try? HAL.value(aggregate, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1 {
                    alive = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            guard alive else { throw AudioFailure("The output did not become ready. Native playback was restored.") }
            let hardwareInputs = try HAL.channelCount(output, scope: kAudioObjectPropertyScopeInput)
            let allInputs = try HAL.channelCount(aggregate, scope: kAudioObjectPropertyScopeInput)
            let allOutputs = try HAL.channelCount(aggregate, scope: kAudioObjectPropertyScopeOutput)
            guard allInputs == hardwareInputs + 2, allOutputs == 2 else {
                throw AudioFailure("The aggregate's channel layout is unsupported; native playback was restored.")
            }
            let aggregateOutputStreams = try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard aggregateOutputStreams.count == 1 else { throw AudioFailure("The aggregate output is not a single stereo stream.") }
            let aggregateOutputFormat = try HAL.format(aggregateOutputStreams[0])
            try HAL.validateStereoFloat(aggregateOutputFormat)
            let inputStreams = try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            let physicalInputs = try HAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            guard inputStreams.count == physicalInputs.count + 1, let tapStream = inputStreams.last else {
                throw AudioFailure("The system audio tap could not be mapped safely.")
            }
            let aggregateInputFormat = try HAL.format(tapStream)
            try HAL.validateStereoFloat(aggregateInputFormat)
            guard abs(aggregateOutputFormat.mSampleRate - rate) < 0.1,
                  abs(aggregateInputFormat.mSampleRate - rate) < 0.1 else {
                throw AudioFailure("The audio route changed sample rate while starting. Start again to reconnect.")
            }
            let range = try HAL.value(aggregate, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange())
            guard HAL.preferredBufferFrames(current: 128, range: range) != nil else {
                throw AudioFailure("The output reports an unsupported audio buffer size.")
            }
            bufferFrames = HAL.configureBuffer(aggregate: aggregate, output: output, range: range, restore: &bufferRestore)
            let variableMaximum = (try? HAL.value(aggregate, kAudioDevicePropertyUsesVariableBufferFrameSizes, initial: UInt32(0))) ?? 0
            guard variableMaximum <= 65536 else { throw AudioFailure("The output reports an unsupported variable audio buffer size.") }
            let maxFrames = max(UInt32(range.mMaximum.rounded(.up)), variableMaximum)
            guard let newDSP = eq_dsp_create(rate, maxFrames) else { throw AudioFailure("Could not allocate the equalizer.") }
            dsp = newDSP
            guard eq_dsp_set_parameters(newDSP, &parameters) else { throw AudioFailure("The EQ settings are invalid.") }
            guard let newContext = eq_audio_create(newDSP, hardwareInputs, allInputs, maxFrames) else {
                throw AudioFailure("Could not allocate the audio callback.")
            }
            context = newContext
            try HAL.check(AudioDeviceCreateIOProcID(aggregate, eq_audio_io_proc,
                UnsafeMutableRawPointer(newContext), &proc), "Connect audio callback")
            guard let proc else { throw AudioFailure("Core Audio did not create an audio callback.") }
            try HAL.check(eq_audio_disable_hardware_inputs(aggregate, proc,
                UInt32(physicalInputs.count), UInt32(inputStreams.count)), "Disable unused microphone inputs")
            callbackMayRun = true // Even a failed start must be stopped before its storage is reclaimed.
            try HAL.check(AudioDeviceStart(aggregate, proc), "Start system audio (check System Audio Recording permission)")
            bufferFrames = (try? HAL.value(aggregate, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))) ?? bufferFrames
            route = output
            routeSignature = try HAL.signature(output)
            try listen(output, kAudioDevicePropertyNominalSampleRate, routeOnly: true)
            try listen(output, kAudioDevicePropertyDeviceIsAlive, routeOnly: true)
            try listen(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, routeOnly: true)
            try listen(output, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, routeOnly: true)
            try listen(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, routeOnly: true)
            try listen(output, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput, routeOnly: true)
            try listen(outputStreams[0], kAudioStreamPropertyVirtualFormat, routeOnly: true)
            try listen(aggregate, kAudioDevicePropertyBufferFrameSize, routeOnly: true)
            state.running = true
            startPolling()
            state.starting = false
            state.sampleRate = rate
            state.status = processingStatus
            emit()
        } catch { fail(error) }
    }

    @discardableResult
    private func teardown() -> Bool {
        meterTimer?.cancel()
        meterTimer = nil
        removeListeners(&routeListeners)
        state.running = false
        state.starting = false
        state.peakDB = -120
        state.clipping = false
        let releaseError = HAL.releaseRoute(aggregate: &aggregate, proc: &proc, tap: &tap, callbackMayRun: &callbackMayRun)
        let cleanupError = releaseError ?? HAL.restoreBuffer(&bufferRestore)
        if let error = cleanupError {
            // Keep this one route's pointers alive. No new route may replace them until cleanup succeeds.
            cleanupBlocked = true
            wantsRunning = false
            state.status = "Core Audio cleanup is incomplete (\(error)). Native playback restoration is unconfirmed. Start retries cleanup; quit if it persists."
            NSLog("%@", state.status)
            return false
        }
        cleanupBlocked = false
        tapDescription = nil
        if let context { eq_audio_destroy(context) }
        context = nil
        if let dsp { eq_dsp_destroy(dsp) }
        dsp = nil
        route = 0
        routeSignature = ""
        bufferFrames = 0
        return true
    }
    private func fail(_ error: Error) {
        wantsRunning = false // A missing/unsupported device must not cause a restart loop.
        if teardown() { state.status = error.localizedDescription }
        emit()
    }
    private func poll() {
        guard state.running, !cleanupBlocked, let dsp, let context else { return }
        let error = eq_audio_error(context)
        if error != 0 {
            fail(AudioFailure(String(cString: eq_audio_error_message(error))))
            return
        }
        guard meteringEnabled else { return }
        state.peakDB = (max(-120, 20 * log10(max(1e-6, Double(eq_dsp_peak(dsp))))) * 10).rounded() / 10
        state.clipping = eq_dsp_take_clipping(dsp)
        emit()
    }

    private func startPolling() {
        guard state.running, meterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100),
                       leeway: .milliseconds(10))
        // Keep the cheap callback-error watchdog alive when hidden so failures restore native audio.
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        meterTimer = timer
    }

    #if DEBUG
    static func checkMeteringHandling() {
        let worker = AudioWorker()
        worker.queue.sync {
            var emissions = 0
            worker.publish = { _ in emissions += 1 }
            worker.startPolling()
            precondition(worker.meterTimer == nil, "Stopped audio must not schedule polling")
            worker.dsp = eq_dsp_create(48000, 16)
            worker.context = eq_audio_create(worker.dsp!, 0, 2, 16)
            precondition(worker.dsp != nil && worker.context != nil)
            worker.state.running = true
            worker.startPolling()
            precondition(worker.meterTimer != nil)
            worker.poll()
            precondition(emissions == 0, "A hidden window must not receive meter updates")
            worker.meteringEnabled = true
            worker.poll()
            worker.poll()
            precondition(emissions == 1, "An unchanged meter must not republish the audio state")
            precondition(worker.teardown() && worker.meterTimer == nil)
            worker.poll()
            precondition(emissions == 1)
        }
        worker.shutdown()
    }
    #endif
}

private struct AudioFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum HAL {
    /// Mutates only identifiers whose destruction is confirmed. A failed step is retryable.
    /// Aggregate destruction is asynchronous; it is never used as proof that a callback stopped.
    static func releaseRoute(aggregate: inout AudioObjectID, proc: inout AudioDeviceIOProcID?,
        tap: inout AudioObjectID, callbackMayRun: inout Bool,
        stop: (AudioObjectID, AudioDeviceIOProcID) -> OSStatus = AudioDeviceStop,
        destroyProc: (AudioObjectID, AudioDeviceIOProcID) -> OSStatus = AudioDeviceDestroyIOProcID,
        destroyAggregate: (AudioObjectID) -> OSStatus = AudioHardwareDestroyAggregateDevice,
        destroyTap: (AudioObjectID) -> OSStatus = AudioHardwareDestroyProcessTap) -> String? {
        if let callback = proc {
            if callbackMayRun {
                let stopped = stop(aggregate, callback)
                guard stopped == noErr else { return "stop \(stopped)" }
                callbackMayRun = false
            }
            let destroyed = destroyProc(aggregate, callback)
            guard destroyed == noErr else { return "callback \(destroyed)" }
            proc = nil
        }
        guard !callbackMayRun else { return "callback stop unconfirmed" }
        if aggregate != 0 {
            let result = destroyAggregate(aggregate)
            guard result == noErr else { return "aggregate \(result)" }
            aggregate = 0
        }
        if tap != 0 {
            let result = destroyTap(tap)
            guard result == noErr else { return "tap \(result)" }
            tap = 0
        }
        return nil
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioFailure("\(operation) failed (Core Audio \(status)).") }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var a = address(selector, scope: scope)
        try withUnsafeMutableBytes(of: &value) {
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!), "Read audio device")
        }
        guard size == MemoryLayout<T>.size else { throw AudioFailure("The audio device returned an invalid property size.") }
        return value
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "Read audio device list")
        guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0, size <= 65536 else {
            throw AudioFailure("The audio device returned an invalid list.")
        }
        if size == 0 { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try result.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!), "Read audio device list")
        }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ref), "Read audio device name")
        guard let ref else { throw AudioFailure("The audio device returned no name.") }
        return ref.takeRetainedValue() as String
    }
    static func defaultOutput() throws -> AudioDeviceID {
        try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
    }
    static func sampleRate(_ device: AudioDeviceID) throws -> Double {
        try value(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
    }
    static func preferredBufferFrames(current: UInt32, range: AudioValueRange) -> UInt32? {
        guard range.mMinimum.isFinite, range.mMaximum.isFinite,
              range.mMinimum >= 1, range.mMaximum <= 65536,
              range.mMinimum.rounded(.up) <= range.mMaximum.rounded(.down) else { return nil }
        let preferred = Double(current > 0 ? min(current, 128) : 128)
        return UInt32(max(range.mMinimum.rounded(.up), min(preferred, range.mMaximum.rounded(.down))))
    }
    static func setBufferFrames(_ device: AudioDeviceID, _ frames: UInt32) -> OSStatus {
        var frames = frames
        var a = address(kAudioDevicePropertyBufferFrameSize)
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }
    static func configureBuffer(aggregate: AudioDeviceID, output: AudioDeviceID, range: AudioValueRange,
        restore: inout (device: AudioDeviceID, original: UInt32, applied: UInt32, pending: Bool)?) -> UInt32 {
        let current = (try? value(aggregate, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))) ?? 0
        guard let requested = preferredBufferFrames(current: current, range: range), requested != current else { return current }
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(aggregate, &a, &settable) == noErr, settable.boolValue else { return current }
        guard let previousPhysical = try? value(output, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)),
              previousPhysical > 0 else { return current }
        let result = setBufferFrames(aggregate, requested)
        guard result == noErr else { return current }
        // Some aggregate drivers share this setting with their physical subdevice.
        if previousPhysical != requested {
            restore = (output, previousPhysical, requested, true)
        }
        let actual = awaitBufferFrames(aggregate, expected: requested) ?? current
        if restore != nil {
            let physical = (try? value(output, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))) ?? previousPhysical
            if physical == requested { restore = (output, previousPhysical, requested, false) }
            else if actual != current, physical == actual {
                restore = (output, previousPhysical, actual, false)
            } // Otherwise keep the request tracked while propagation is pending.
        }
        return actual
    }
    private static func awaitBufferFrames(_ device: AudioDeviceID, expected: UInt32,
        read: (AudioDeviceID) -> UInt32? = { try? value($0, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) },
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.02) }) -> UInt32? {
        var observed: UInt32?
        for _ in 0..<10 {
            pause() // Core Audio property writes are asynchronous; this is never the render queue.
            observed = read(device)
            if observed == expected { break }
        }
        return observed
    }
    static func restoreBuffer(_ record: inout (device: AudioDeviceID, original: UInt32, applied: UInt32, pending: Bool)?,
        read: (AudioDeviceID) -> UInt32? = { try? value($0, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) },
        set: (AudioDeviceID, UInt32) -> OSStatus = setBufferFrames,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.02) }) -> String? {
        guard let saved = record else { return nil }
        // A disconnected device or a later change by another client must not be overwritten.
        let current = read(saved.device)
        if current == saved.applied || (saved.pending && current == saved.original) {
            let result = set(saved.device, saved.original)
            guard result == noErr else { return "restore output buffer \(result)" }
            guard awaitBufferFrames(saved.device, expected: saved.original, read: read, pause: pause) == saved.original else {
                return "output buffer restoration is still pending"
            }
        }
        record = nil
        return nil
    }
    static func bufferDiagnostics(_ device: AudioDeviceID, sampleRate: Double) -> String {
        var parts: [String] = []
        if let frames = try? value(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)), sampleRate > 0 {
            parts.append("I/O buffer \(frames) frames (\(String(format: "%.2f", Double(frames) * 1000 / sampleRate)) ms)")
        }
        if let range = try? value(device, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange()),
           range.mMinimum.isFinite, range.mMaximum.isFinite {
            parts.append("supported buffer range \(range.mMinimum)–\(range.mMaximum) frames")
        }
        if let frames = try? value(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) {
            parts.append("device output latency \(frames) frames")
        }
        if let frames = try? value(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) {
            parts.append("output safety offset \(frames) frames")
        }
        if let streams = try? ids(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) {
            for stream in streams {
                if let frames = try? value(stream, kAudioStreamPropertyLatency, initial: UInt32(0)) {
                    parts.append("stream \(stream) latency \(frames) frames")
                }
            }
        }
        return parts.isEmpty ? "Buffer and latency properties unavailable." : parts.joined(separator: "; ")
    }
    static func format(_ stream: AudioStreamID) throws -> AudioStreamBasicDescription {
        try value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
    }
    static func validateStereoFloat(_ f: AudioStreamBasicDescription) throws {
        let planar = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard f.mFormatID == kAudioFormatLinearPCM,
              f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              f.mBitsPerChannel == 32, f.mChannelsPerFrame == 2,
              f.mFramesPerPacket == 1, f.mBytesPerFrame == (planar ? 4 : 8),
              f.mSampleRate.isFinite, (8000...384000).contains(f.mSampleRate) else {
            throw AudioFailure("This output must expose native 32-bit floating-point stereo PCM. Native playback restored.")
        }
    }
    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> UInt32 {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size), "Read channel layout")
        guard size >= MemoryLayout<UInt32>.size, size <= 65536 else { throw AudioFailure("Invalid audio channel layout.") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, storage), "Read channel layout")
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        if count == 0 { return 0 }
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard count <= 256, offset + count * MemoryLayout<AudioBuffer>.stride <= Int(size) else {
            throw AudioFailure("Invalid audio buffer layout.")
        }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }
    static func outputs() throws -> [AudioOutput] {
        try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard (try? value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1,
                  let transport = try? value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)),
                  transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual,
                  (try? channelCount(id, scope: kAudioObjectPropertyScopeOutput)) == 2,
                  let name = try? string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutput(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    // Discord excludes its own audio from screen sharing. Replaying it as BalanceEQ defeats that.
    // Keep the desktop app and its Electron helpers on native playback, without EQ or preamp.
    static let discordBundleIDs = ["", ".helper", ".helper.Renderer", ".helper.GPU", ".helper.Plugin"]
        .map { "com.hnc.Discord" + $0 }

    static func isDiscord(_ bundleID: String) -> Bool {
        bundleID == "com.hnc.Discord" || bundleID.hasPrefix("com.hnc.Discord.")
    }

    static func discordProcesses() throws -> [AudioObjectID] {
        try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter { id in
            // A process may disappear between enumeration and reading its bundle ID.
            guard let bundle = try? string(id, kAudioProcessPropertyBundleID) else { return false }
            return isDiscord(bundle)
        }
    }

    static func captureExclusions() throws -> [AudioObjectID] {
        Array(Set(try [ownProcessObject()] + discordProcesses())).sorted()
    }

    #if DEBUG
    static func checkDiscordExclusions() {
        for bundle in discordBundleIDs + ["com.hnc.Discord.helper.audio"] {
            precondition(isDiscord(bundle), "Discord helpers must retain their native audio identity")
        }
        for bundle in ["", "org.equalizerformac.app", "com.apple.Safari", "com.hnc.DiscordOther", "x.com.hnc.Discord"] {
            precondition(!isDiscord(bundle), "Unrelated apps must retain EQ processing")
        }
        let description = CATapDescription(excludingProcesses: [41, 42], deviceUID: "test-output", stream: 0)
        description.muteBehavior = .mutedWhenTapped
        description.processes = [41, 43] // Discord relaunches; own-process exclusion remains.
        precondition(description.isExclusive && description.processes == [41, 43])
        precondition(description.deviceUID == "test-output" && description.muteBehavior == .mutedWhenTapped)
        if #available(macOS 26.0, *) {
            description.bundleIDs = discordBundleIDs
            precondition(description.bundleIDs == discordBundleIDs && description.processes.contains(41))
        }
    }
    #endif

    static func ownProcessObject() throws -> AudioObjectID {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var process = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Exclude equalizer from capture")
        guard process != 0 else { throw AudioFailure("The equalizer could not exclude itself from capture. Start again.") }
        return process
    }
    static func signature(_ output: AudioDeviceID) throws -> String {
        guard output != 0 else { throw AudioFailure("No output device is available. Connect an output and start again.") }
        let streams = try ids(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var parts = [String(output), String(try sampleRate(output)), String(try channelCount(output, scope: kAudioObjectPropertyScopeInput))]
        for stream in streams {
            let f = try format(stream)
            parts.append("\(stream):\(f.mSampleRate):\(f.mFormatID):\(f.mFormatFlags):\(f.mBytesPerFrame):\(f.mChannelsPerFrame)")
        }
        return parts.joined(separator: "|")
    }
}
