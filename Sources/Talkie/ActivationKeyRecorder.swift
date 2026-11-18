import SwiftUI
import AppKit

/// "Press the key you want" control for the dictation key. While recording it
/// listens (inside Talkie's own window only, via a local event monitor, so it
/// needs no permission) for the next modifier key, F1-F20 or extra mouse button.
/// Escape cancels; refused keys show a one-line reason and keep listening;
/// risky-but-allowed keys are saved with an inline warning. All classification
/// lives in the pure `ActivationKey.evaluate`.
struct ActivationKeyRecorder: View {
    @Binding var key: ActivationKey
    @State private var recording = false
    @State private var message: String?
    @State private var messageIsRefusal = false
    @State private var monitor = MonitorBox()

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                if let symbol = key.symbolName {
                    Label(key.displayName, systemImage: symbol)
                        .foregroundStyle(Theme.ink)
                } else {
                    Text(key.displayName).foregroundStyle(Theme.ink)
                }
                Button(recording ? "Press the key you want".loc : "Change…".loc) {
                    recording ? stop() : start()
                }
            }
            if recording {
                Text("Press Esc to cancel".loc)
                    .font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageIsRefusal ? Theme.coral : Theme.inkSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { message = key.warning; messageIsRefusal = false }
        .onDisappear { stop() }
        // Closing the settings window or leaving the app mid-recording must resume the hotkey.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        message = nil
        recording = true
        ActivationRecordingGate.shared.begin()
        monitor.install { input in
            MainActor.assumeIsolated { handle(input) }
        }
    }

    private func stop() {
        recording = false
        monitor.remove()
        ActivationRecordingGate.shared.end()
    }

    private func handle(_ input: ActivationKey.RecorderInput) {
        switch ActivationKey.evaluate(input) {
        case .ignored: break
        case .cancelled:
            stop()
            message = key.warning; messageIsRefusal = false
        case .refused(let reason):
            message = reason; messageIsRefusal = true
        case .accepted(let newKey, let warning):
            key = newKey
            message = warning; messageIsRefusal = false
            stop()
        }
    }
}

/// Owns the local NSEvent monitor token.
private final class MonitorBox {
    private var token: Any?

    /// Key-downs are swallowed while recording so the key isn't also typed or beeped.
    func install(_ onInput: @escaping (ActivationKey.RecorderInput) -> Void) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            let input: ActivationKey.RecorderInput
            switch event.type {
            case .keyDown:
                if event.isARepeat { return nil }
                input = .keyDown(keyCode: Int(event.keyCode))
            case .flagsChanged:
                input = .flagsChanged(keyCode: Int(event.keyCode),
                                      rawFlags: UInt64(event.modifierFlags.rawValue))
            case .otherMouseDown:
                input = .mouseDown(button: event.buttonNumber)
            default: return event
            }
            onInput(input)
            return event.type == .keyDown ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
