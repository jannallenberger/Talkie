import CoreAudio
import XCTest
@testable import Talkie

/// Pure-logic tests for `AudioDevices.resolveSwap` — the decision `handleConfigurationChange`
/// consults when the active input device changes mid-session (unplug a headset, AirPods
/// connect, default flips). Validates the swap policy without any Core Audio hardware.
final class AudioDeviceSwapTests: XCTestCase {

    private func device(_ id: AudioDeviceID, _ uid: String, _ name: String, builtIn: Bool = false) -> AudioInputDevice {
        AudioInputDevice(id: id, uid: uid, name: name, isBuiltIn: builtIn)
    }

    private lazy var builtIn = device(1, "BuiltInMicUID", "MacBook Pro Microphone", builtIn: true)
    private lazy var headset = device(2, "HeadsetUID", "USB Headset")
    private lazy var airpods = device(3, "AirPodsUID", "AirPods Pro")

    // MARK: preferred-still-present → .keep

    func testPreferredStillPresentKeeps() {
        // The user's preferred device is still in the list and is the one we're tapping.
        let decision = AudioDevices.resolveSwap(
            preferred: "HeadsetUID",
            devices: [builtIn, headset],
            currentUID: "HeadsetUID",
            defaultID: builtIn.id
        )
        XCTAssertEqual(decision, SwapDecision.keep, "preferred device still present + currently tapped → keep")
    }

    func testCurrentMatchesResolvedTargetKeepsWithoutPreference() {
        // No saved preference; the system default is what we're already tapping → keep.
        let decision = AudioDevices.resolveSwap(
            preferred: nil,
            devices: [builtIn, headset],
            currentUID: "HeadsetUID",
            defaultID: headset.id
        )
        XCTAssertEqual(decision, SwapDecision.keep, "resolved default equals current device → keep")
    }

    // MARK: preferred-gone but built-in present → .swap(builtin)

    func testPreferredGoneSwapsToBuiltIn() {
        // The preferred headset was unplugged; with no matching default, fall to built-in.
        let decision = AudioDevices.resolveSwap(
            preferred: "HeadsetUID",
            devices: [builtIn],
            currentUID: "HeadsetUID",
            defaultID: nil
        )
        XCTAssertEqual(decision, SwapDecision.swap(to: builtIn), "preferred gone, built-in present → swap to built-in")
    }

    func testDefaultFlipPrefersInputCapableDefaultOverBuiltIn() {
        // No saved preference; default flipped to AirPods while we were on built-in.
        let decision = AudioDevices.resolveSwap(
            preferred: nil,
            devices: [builtIn, airpods],
            currentUID: "BuiltInMicUID",
            defaultID: airpods.id
        )
        XCTAssertEqual(decision, SwapDecision.swap(to: airpods), "default flipped to a present device → swap to it")
    }

    func testPreferredReappearsTakesPriorityOverDefault() {
        // Preferred headset reconnects mid-session; it wins over the current default.
        let decision = AudioDevices.resolveSwap(
            preferred: "HeadsetUID",
            devices: [builtIn, headset],
            currentUID: "BuiltInMicUID",
            defaultID: builtIn.id
        )
        XCTAssertEqual(decision, SwapDecision.swap(to: headset), "preferred device reappeared → swap to preference")
    }

    // MARK: empty device list → .noDevice

    func testEmptyDeviceListReportsNoDevice() {
        let decision = AudioDevices.resolveSwap(
            preferred: "HeadsetUID",
            devices: [],
            currentUID: "HeadsetUID",
            defaultID: nil
        )
        XCTAssertEqual(decision, SwapDecision.noDevice, "no input devices at all → noDevice")
    }

    func testEmptyDeviceListWithNoPreferenceReportsNoDevice() {
        let decision = AudioDevices.resolveSwap(
            preferred: nil,
            devices: [],
            currentUID: nil,
            defaultID: nil
        )
        XCTAssertEqual(decision, SwapDecision.noDevice, "empty list regardless of preference → noDevice")
    }

    // MARK: fallback when default isn't input-capable

    func testFallsBackToFirstWhenNoDefaultNoBuiltInNoPreference() {
        // No preference, default not in the list, no built-in → first available device.
        let decision = AudioDevices.resolveSwap(
            preferred: nil,
            devices: [headset, airpods],
            currentUID: "AirPodsUID",
            defaultID: 999 // a device id not in the list
        )
        XCTAssertEqual(decision, SwapDecision.swap(to: headset), "no default/built-in/preference → first available")
    }
}
