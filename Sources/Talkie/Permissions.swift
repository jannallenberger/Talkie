import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// Reflects and requests the three TCC permissions Talkie needs:
/// Accessibility / PostEvent (post the paste keystroke), Input Monitoring /
/// ListenEvent (observe the global hotkey), and Microphone (capture audio).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var microphone = false

    var allGranted: Bool { accessibility && inputMonitoring && microphone }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Shows the system Accessibility prompt (adds the app to the list).
    func promptAccessibility() {
        // Literal value of `kAXTrustedCheckOptionPrompt` (a non-concurrency-safe
        // C global in Swift 6); the string is stable API.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    func requestMicrophone() async {
        _ = await AudioCapture.requestMicrophoneAccess()
        refresh()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
