import AVFoundation
import CoreAudio

/// A microphone-capable audio input device, surfaced for the Settings picker and
/// for resolving which device dictation should actually capture from.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    /// Stable across reconnects/reboots, unlike `id` — so it's what we persist.
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

/// The outcome of evaluating a mid-session input-device change: whether the
/// currently-tapped device is still the right one, a different device should be
/// swapped to, or no input device remains at all.
enum SwapDecision: Equatable, Sendable {
    /// The device currently in use is still the best choice — no swap needed.
    case keep
    /// Swap to this device (the previous one vanished, or a preferred one appeared).
    case swap(to: AudioInputDevice)
    /// No input device is available at all — capture cannot continue.
    case noDevice
}

/// Core Audio helpers for choosing a *real* microphone.
///
/// `AVAudioEngine.inputNode` follows the system **default input**, which can point
/// at hardware with no input channels — e.g. a Bluetooth A2DP speaker that is only
/// an output. When that happens the engine reports a 0-channel format and dictation
/// fails to start. We enumerate input-capable devices and resolve a sensible one
/// instead of blindly trusting the default, which also keeps a Bluetooth speaker in
/// high-quality A2DP output mode rather than dragging it into degraded HFP just to
/// expose a phantom mic.
enum AudioDevices {

    /// Every device that currently exposes at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
        deviceIDs().compactMap { id -> AudioInputDevice? in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                isBuiltIn: transportType(id) == kAudioDeviceTransportTypeBuiltIn
            )
        }
    }

    /// Resolve the device dictation should capture from, given the user's saved
    /// preference. Policy, in order:
    ///   1. the explicitly chosen device, if it's still connected and input-capable;
    ///   2. the system default input — but only if it actually has input channels;
    ///   3. the built-in microphone;
    ///   4. the first available input device.
    /// Returns `nil` only when the Mac has no input device at all.
    static func resolveInput(preferredUID: String?) -> AudioInputDevice? {
        let devices = inputDevices()
        guard !devices.isEmpty else { return nil }
        if let preferredUID, !preferredUID.isEmpty,
           let match = devices.first(where: { $0.uid == preferredUID }) {
            return match
        }
        if let defaultID = defaultInputDeviceID(),
           let def = devices.first(where: { $0.id == defaultID }) {
            return def
        }
        return devices.first(where: { $0.isBuiltIn }) ?? devices.first
    }

    /// Pure decision for a mid-session input-device change: given the user's saved
    /// preference, the *current* device list, the device we're tapping right now
    /// (`currentUID`), and the system default (`defaultID`), decide whether to keep,
    /// swap, or report no device. Mirrors `resolveInput`'s priority ladder but as a
    /// hardware-free function so the swap policy is unit-testable:
    ///   1. empty list → `.noDevice` (capture can't continue);
    ///   2. the resolved target equals the current device → `.keep`;
    ///   3. otherwise → `.swap(to:)` the resolved target.
    /// The resolved target follows the same order as `resolveInput`: explicit
    /// preference if present, else the (input-capable) system default, else the
    /// built-in mic, else the first available device.
    static func resolveSwap(
        preferred preferredUID: String?,
        devices: [AudioInputDevice],
        currentUID: String?,
        defaultID: AudioDeviceID?
    ) -> SwapDecision {
        guard !devices.isEmpty else { return .noDevice }

        let target: AudioInputDevice
        if let preferredUID, !preferredUID.isEmpty,
           let match = devices.first(where: { $0.uid == preferredUID }) {
            target = match
        } else if let defaultID,
                  let def = devices.first(where: { $0.id == defaultID }) {
            target = def
        } else if let builtIn = devices.first(where: { $0.isBuiltIn }) {
            target = builtIn
        } else {
            target = devices[0]
        }

        if let currentUID, target.uid == currentUID {
            return .keep
        }
        return .swap(to: target)
    }

    /// True iff some *other* process is currently playing audio on an output device.
    /// Used to gate the blind media-key fallback so it can never *start* silent
    /// playback — it only nudges play/pause when something is genuinely playing.
    static func isOtherProcessPlayingOutput(excludingPID selfPID: pid_t) -> Bool {
        for object in processObjectList() {
            guard processPID(object) != selfPID, isRunningOutput(object) else { continue }
            return true
        }
        return false
    }

    // MARK: - Device property reads

    /// `kAudioHardwarePropertyDevices` → every audio device the system knows about.
    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    /// `kAudioHardwarePropertyDefaultInputDevice` → the current default input.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Sum of input-scope channels on a device. 0 means "can't record" (e.g. a
    /// pure output like a Bluetooth A2DP speaker), which is exactly what we skip.
    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// `kAudioDevicePropertyTransportType` → built-in vs USB vs Bluetooth, etc.
    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    /// A `CFString` device property (UID, name, …) as a Swift `String`.
    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfString else { return nil }
        let string = cfString as String
        return string.isEmpty ? nil : string
    }

    // MARK: - Output-activity reads (media-key fallback gate)

    /// `kAudioHardwarePropertyProcessObjectList` → every audio process.
    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func processPID(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return pid
    }

    /// `kAudioProcessPropertyIsRunningOutput` → 1 iff the process has an active
    /// output stream (i.e. it's playing audio right now).
    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}
