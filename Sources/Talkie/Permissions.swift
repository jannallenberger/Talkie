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

    /// True while the system microphone dialog can still appear (status not yet
    /// decided). Once it is denied/restricted a request is a silent no-op.
    @Published private(set) var microphoneCanPrompt = true

    /// Permissions whose system request was already issued in this run. macOS shows
    /// the Input Monitoring / Accessibility dialog at most once, and gives no query
    /// for "was it shown", so after the first Grant tap the row offers System
    /// Settings instead of a button that can no longer do anything.
    @Published private(set) var requested: Set<PermissionKind> = []

    /// Installs the hotkey tap (returns whether it is running). Set by AppDelegate;
    /// called when a poll first observes the Input Monitoring grant.
    var hotKeyRetry: (() -> Bool)?

    /// What the row for `kind` should offer right now.
    func rowAction(_ kind: PermissionKind) -> PermissionRowAction {
        switch kind {
        case .microphone:
            return .decide(granted: microphone, canShowSystemPrompt: microphoneCanPrompt)
        case .inputMonitoring:
            return .decide(granted: inputMonitoring, canShowSystemPrompt: !requested.contains(.inputMonitoring))
        case .accessibility:
            return .decide(granted: accessibility, canShowSystemPrompt: !requested.contains(.accessibility))
        }
    }

    /// Run the row's button: ask when the system dialog can still show, otherwise
    /// open the matching System Settings pane.
    func performRowAction(_ kind: PermissionKind, retryHotKey: (() -> Bool)? = nil) {
        switch rowAction(kind) {
        case .granted:
            return
        case .openSettings:
            switch kind {
            case .microphone: openMicrophoneSettings()
            case .inputMonitoring: openInputMonitoringSettings()
            case .accessibility: openAccessibilitySettings()
            }
        case .request:
            switch kind {
            case .microphone:
                Task { await requestMicrophone() }
            case .inputMonitoring:
                requested.insert(.inputMonitoring)
                requestInputMonitoring()
                // The grant may already be live while the tap still can't install.
                if let retry = retryHotKey ?? hotKeyRetry {
                    hotKeyNeedsRelaunch = HotKeyTapRetry.needsRelaunch(
                        granted: CGPreflightListenEventAccess(), tapInstalled: retry())
                }
            case .accessibility:
                requested.insert(.accessibility)
                promptAccessibility()
            }
        }
    }

    /// The `@MainActor` polling loop. `nil` while nothing is being observed; a
    /// single live task while onboarding's permissions step or the Settings
    /// permissions card is on screen. Guards idempotency (`startPolling()` twice
    /// does not spawn a second loop) and cancellation (`stopPolling()`/`deinit`).
    private var pollTask: Task<Void, Never>?

    func refresh() {
        let wasInputMonitoring = inputMonitoring
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphone = micStatus == .authorized
        microphoneCanPrompt = micStatus == .notDetermined
        // Input Monitoring was granted in System Settings while Talkie sat in the
        // background: install the tap now instead of waiting for the next
        // activation, and surface the relaunch hint when macOS still refuses.
        if HotKeyTapRetry.shouldRetry(wasGranted: wasInputMonitoring, isGranted: inputMonitoring),
           let retry = hotKeyRetry {
            hotKeyNeedsRelaunch = HotKeyTapRetry.needsRelaunch(granted: inputMonitoring, tapInstalled: retry())
        }
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
