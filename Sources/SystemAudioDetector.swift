import AppKit
import CoreAudio
import Accelerate

/// Owns a private, input-only tap device. All HAL calls run off the main thread.
/// The IO callback reduces samples to RMS and discards them; nothing is replayed or saved.
final class SystemAudioDetector: @unchecked Sendable {
    enum Event: Sendable {
        case activity(Bool)
        case candidates([String])
        case muted(Bool)
        case audioAccessVerified(Bool)
        case status(String)
    }
    private let queue = DispatchQueue(label: "org.radiodial.self-radio", qos: .utility)
    private let notify: @Sendable (Event) -> Void
    private var enabled = false
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var output: AudioObjectID = 0
    private var timer: DispatchSourceTimer?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var gate = SystemAudioActivityGate()
    private var generation = UUID()
    private var lastBuffer = ProcessInfo.processInfo.systemUptime
    private var receivedBuffers = false
    private var candidates: [String] = []
    private let includedProcesses: [AudioObjectID]?
    private var applicationMonitors: [String: (ids: [AudioObjectID], detector: SystemAudioDetector, token: UUID)] = [:]
    private var audibleApplications = Set<String>()
    private var outputMuted = false

    init(includedProcesses: [AudioObjectID]? = nil, notify: @escaping @Sendable (Event) -> Void) {
        self.includedProcesses = includedProcesses; self.notify = notify
    }

    func setEnabled(_ value: Bool) {
        queue.async { [self] in
            guard enabled != value else { return }
            enabled = value
            if value {
                guard #available(macOS 14.2, *) else {
                    notify(.status("System audio detection requires macOS 14.2 or later.")); return
                }
                installListeners()
                rebuild()
            } else { removeListeners(); tearDown(); notify(.status("Detection is off.")) }
        }
    }

    func retry() { queue.async { [self] in if enabled { rebuild() } } }

    static func verifyAccess() async -> Bool {
        let (events, continuation) = AsyncStream<Bool>.makeStream()
        let detector = SystemAudioDetector { event in
            if case .audioAccessVerified(true) = event { continuation.yield(true) }
        }
        detector.setEnabled(true)
        defer { detector.setEnabled(false); continuation.finish() }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await result in events { return result }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size), a = address(selector, scope: scope)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size), a = address(selector)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        return result == noErr ? value as String : nil
    }
    private func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope: scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !values.isEmpty else { return [] }
        let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        return result == noErr ? values : []
    }
    private func installListeners() {
        guard includedProcesses == nil else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
            var a = address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.enabled else { return }
                if selector == kAudioHardwarePropertyDefaultOutputDevice || self.tap == 0 { self.rebuild() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block) == noErr {
                listeners.append((a, block))
            }
        }
    }
    private func removeListeners() {
        for (var a, block) in listeners { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block) }
        listeners.removeAll()
    }
    private func tearDown() {
        generation = UUID()
        for monitor in applicationMonitors.values { monitor.detector.setEnabled(false) }
        applicationMonitors.removeAll(); audibleApplications.removeAll()
        timer?.cancel(); timer = nil
        if let io, aggregate != 0 { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }
        io = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if #available(macOS 14.2, *), tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        gate.reset(); candidates = []; notify(.activity(false)); notify(.candidates([]))
        outputMuted = false; notify(.muted(false))
        if receivedBuffers { receivedBuffers = false; notify(.audioAccessVerified(false)) }
    }
    private func rebuild() {
        tearDown()
        guard enabled, #available(macOS 14.2, *) else { return }
        do {
            let system = AudioObjectID(kAudioObjectSystemObject)
            guard let device = uint(system, kAudioHardwarePropertyDefaultOutputDevice), device != 0,
                  let uid = string(device, kAudioDevicePropertyDeviceUID) else { throw Failure("No default output device is available.") }
            output = device
            // Refuse to monitor if our process cannot be excluded reliably.
            var pid = getpid(), own: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
            var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            let result = AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)
            guard result == noErr, own != 0 else { throw Failure("Waiting for Radio Dial’s audio process. Retry after opening a station.") }
            let description = includedProcesses.map { CATapDescription(processes: $0, deviceUID: uid, stream: 0) }
                ?? CATapDescription(excludingProcesses: [own], deviceUID: uid, stream: 0)
            description.name = "Radio Dial Self Radio activity"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "System audio access is unavailable. Allow Radio Dial in System Settings → Privacy & Security → Screen & System Audio Recording, then retry.")
            var format = AudioStreamBasicDescription(), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            a = address(kAudioTapPropertyFormat)
            try check(AudioObjectGetPropertyData(tap, &a, 0, nil, &formatSize, &format), "Couldn’t read the system audio format.")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw Failure("This output device uses an unsupported audio format.") }
            guard let tapUID = string(tap, kAudioTapPropertyUID) else { throw Failure("Couldn’t read the system audio tap identifier.") }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Radio Dial Activity Monitor",
                kAudioAggregateDeviceUIDKey: "org.radiodial.self-radio.\(UUID())",
                kAudioAggregateDeviceIsPrivateKey: true,
                // Clock the tap from the current output without changing the default route.
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Couldn’t create the private system audio monitor.")
            let token = generation
            let reducer = LevelReducer()
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { [weak self] _, input, _, _, _ in
                // No output writes, disk IO, networking, or retained sample buffers.
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                if let level = reducer.consume(buffers) {
                    self?.queue.async { [weak self] in
                        guard let self, self.enabled, self.generation == token else { return }
                        self.lastBuffer = ProcessInfo.processInfo.systemUptime
                        if !self.receivedBuffers {
                            self.receivedBuffers = true
                            self.notify(.audioAccessVerified(true))
                        }
                        let previous = self.gate.active
                        let active = self.gate.consume(rms: level, at: self.lastBuffer)
                        if active != previous { self.notify(.activity(active)) }
                    }
                }
            }, "Couldn’t read system audio. Check the system audio permission and retry.")
            try check(AudioDeviceStart(aggregate, io), "System audio permission was denied or the output device is unavailable.")
            lastBuffer = ProcessInfo.processInfo.systemUptime
            notify(.status("Listening for external audio. If nothing is detected, check System Audio Recording permission."))
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1)
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t; t.resume()
        } catch {
            tearDown(); notify(.status(error.localizedDescription))
        }
    }
    private func poll() {
        guard #available(macOS 14.2, *) else { return }
        var isMuted = uint(output, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) == 1
        var volume: Float32 = 1, size = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectGetPropertyData(output, &volumeAddress, 0, nil, &size, &volume) == noErr, volume <= 0 { isMuted = true }
        if isMuted != outputMuted { outputMuted = isMuted; notify(.muted(isMuted)) }
        if ProcessInfo.processInfo.systemUptime - lastBuffer > 3 {
            gate.reset(); notify(.activity(false))
            notify(.status("No system audio buffers received. Check System Audio Recording permission, then retry."))
        }
        guard includedProcesses == nil else { return }
        var running: [String: [AudioObjectID]] = [:]
        for object in objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard uint(object, kAudioProcessPropertyPID) != UInt32(getpid()),
                  uint(object, kAudioProcessPropertyIsRunningOutput) == 1,
                  objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).contains(output),
                  let bundle = string(object, kAudioProcessPropertyBundleID), !bundle.isEmpty,
                  bundle != "com.apple.CoreSpeech" else { continue }
            running[bundle, default: []].append(object)
        }
        // Only attribute an app after its own tap reports non-silent samples.
        // Cap monitors to keep large installations bounded; unmonitored audio remains generic.
        let bundles = running.keys.sorted {
            let a = ["com.apple.Music", "com.spotify.client"].contains($0)
            let b = ["com.apple.Music", "com.spotify.client"].contains($1)
            return a == b ? $0 < $1 : a
        }.prefix(8)
        let wanted = Set(bundles)
        for bundle in Array(applicationMonitors.keys) where !wanted.contains(bundle) || applicationMonitors[bundle]?.ids != running[bundle]?.sorted() {
            applicationMonitors.removeValue(forKey: bundle)?.detector.setEnabled(false)
            audibleApplications.remove(bundle)
        }
        for bundle in bundles where applicationMonitors[bundle] == nil {
            let token = UUID(), ids = running[bundle]!.sorted()
            let monitor = SystemAudioDetector(includedProcesses: ids) { [weak self] event in
                guard case .activity(let active) = event else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.applicationMonitors[bundle]?.token == token else { return }
                    if active { self.audibleApplications.insert(bundle) } else { self.audibleApplications.remove(bundle) }
                    self.publishApplications()
                }
            }
            applicationMonitors[bundle] = (ids, monitor, token)
            monitor.setEnabled(true)
        }
        publishApplications()
    }
    private func publishApplications() {
        let next = audibleApplications.sorted()
        if next != candidates { candidates = next; notify(.candidates(next)) }
    }
    private func check(_ status: OSStatus, _ message: String) throws {
        if status != noErr { throw Failure("\(message) (\(status))") }
    }
    private struct Failure: LocalizedError { var errorDescription: String?; init(_ message: String) { errorDescription = message } }
}

private final class LevelReducer: @unchecked Sendable {
    private var last = 0.0
    func consume(_ buffers: UnsafeMutableAudioBufferListPointer) -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= 0.1 else { return nil }
        last = now
        var sum = 0.0, count = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { continue }
            var rms: Float = 0
            vDSP_rmsqv(data.assumingMemoryBound(to: Float.self), 1, &rms, vDSP_Length(n))
            if rms.isFinite { sum += Double(rms * rms) * Double(n); count += n }
        }
        return count > 0 ? sqrt(sum / Double(count)) : 0
    }
}
