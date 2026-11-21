import CoreAudio
import XCTest
@testable import Talkie

/// Pure-logic tests for the idle/prewarm policy: touching `AVAudioEngine.inputNode`
/// binds a default-device aggregate that includes the default input, so a Bluetooth
/// headset anywhere in that set must keep the prewarm off (else macOS drops it to the
/// low-quality hands-free profile while Talkie is merely open), and a prewarmed engine
/// must be recognised as stale once the default devices change.
final class AudioIdlePrewarmPolicyTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "BuiltIn", name: "MacBook Microphone", isBuiltIn: true)
    private let usb = AudioInputDevice(id: 2, uid: "USB", name: "USB Mic", isBuiltIn: false)
    private let headset = AudioInputDevice(id: 3, uid: "BT", name: "Headset", isBuiltIn: false, isBluetooth: true)

    func testBuiltInEverywherePrewarms() {
        XCTAssertTrue(AudioDevices.isSafeToPrewarm(resolved: builtIn, defaultInput: builtIn))
    }

    func testBluetoothDefaultInputNeverPrewarms() {
        // The user's preferred mic is built-in, but the engine's aggregate would still
        // pull in the Bluetooth default input.
        XCTAssertFalse(AudioDevices.isSafeToPrewarm(resolved: builtIn, defaultInput: headset))
    }

    func testBluetoothResolvedInputNeverPrewarms() {
        XCTAssertFalse(AudioDevices.isSafeToPrewarm(resolved: headset, defaultInput: builtIn))
        XCTAssertFalse(AudioDevices.isSafeToPrewarm(resolved: headset, defaultInput: headset))
    }

    func testNonBuiltInOrMissingDevicesDoNotPrewarm() {
        XCTAssertFalse(AudioDevices.isSafeToPrewarm(resolved: usb, defaultInput: builtIn))
        XCTAssertFalse(AudioDevices.isSafeToPrewarm(resolved: builtIn, defaultInput: nil))
        XCTAssertFalse(AudioDevices.isSafeToPrewarm(resolved: nil, defaultInput: nil))
    }

    func testPrewarmKeyChangesWhenEitherDefaultOrResolvedDeviceChanges() {
        let base = AudioDevices.PrewarmKey(defaultInput: 1, defaultOutput: 10, resolvedInputUID: "BuiltIn")
        XCTAssertEqual(base, AudioDevices.PrewarmKey(defaultInput: 1, defaultOutput: 10, resolvedInputUID: "BuiltIn"))
        XCTAssertNotEqual(base, AudioDevices.PrewarmKey(defaultInput: 2, defaultOutput: 10, resolvedInputUID: "BuiltIn"))
        XCTAssertNotEqual(base, AudioDevices.PrewarmKey(defaultInput: 1, defaultOutput: 11, resolvedInputUID: "BuiltIn"))
        XCTAssertNotEqual(base, AudioDevices.PrewarmKey(defaultInput: 1, defaultOutput: 10, resolvedInputUID: "USB"))
    }

    func testIdleCaptureStopIsANoOpAndHoldsNothing() {
        // A never-started capture: stop() must not instantiate the input node (it would
        // build the default-device aggregate) or crash.
        let capture = AudioCapture()
        capture.stop()
        XCTAssertNil(capture.secondsSinceLastBuffer())
    }
}
