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

    /// True when Input Monitoring is granted but the hotkey tap still couldn't be
    /// installed (a known TCC quirk where the grant lands yet the existing process
    /// can't create the event tap until it relaunches). Surfaces a prominent
    /// "Relaunch now" button; set by the retry callers, never triggers an
    /// automatic relaunch — the relaunch is always the user's tap.
    @Published var hotKeyNeedsRelaunch = false

    var allGranted: Bool { accessibility && inputMonitoring && microphone }

    /// The `@MainActor` polling loop. `nil` while nothing is being observed; a
    /// single live task while onboarding's permissions step or the Settings
    /// permissions card is on screen. Guards idempotency (`startPolling()` twice
    /// does not spawn a second loop) and cancellation (`stopPolling()`/`deinit`).
    private var pollTask: Task<Void, Never>?

    func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: Live polling

    /// Begin polling the three permissions once a second so the UI reflects a
    /// grant made in System Settings within ~1s, with no user action in Talkie.
    /// Idempotent: a second call while a loop is already running is a no-op, so
    /// two visible surfaces (onboarding + Settings) can each call it without
    /// spawning duplicate loops. `CGPreflightListenEventAccess` and the two TCC
    /// checks are cheap, so a 1s cadence is fine. Cancelled in `stopPolling()`
    /// and `deinit`; the loop captures `self` weakly so it can never keep the
    /// model alive.
    func startPolling() {
        guard pollTask == nil else { return }
        #if DEBUG
        print("[Permissions] startPolling — a surface is visible, polling every 1s")
        #endif
        refresh() // reflect current state immediately, don't wait a full second
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }

    /// Stop the polling loop (called from `onDisappear` of each surface). Safe to
    /// call when no loop is running.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        #if DEBUG
        // Verifiable in debug: once both surfaces (onboarding step + Settings card)
        // have disappeared, no polling Task remains — the loop never runs unobserved.
        print("[Permissions] stopPolling — no surface visible, polling halted")
        assert(pollTask == nil, "PermissionsModel stopped polling but pollTask is still set")
        #endif
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: Requests

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

    // MARK: Relaunch

    /// Quit and reopen Talkie. Lives here (not in a view) because both the
    /// onboarding permissions step and the Settings permissions card offer the
    /// same one-click relaunch when the hotkey tap can't install without a fresh
    /// process. Always user-initiated — an app that kills itself mid-onboarding
    /// reads as a crash, so nothing calls this automatically.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
