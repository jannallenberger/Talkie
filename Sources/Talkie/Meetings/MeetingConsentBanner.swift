import AppKit
import SwiftUI

/// The proactive "a meeting started — record it?" offer. A sibling of the dictation
/// HUD (same under-notch floating panel via `NotchPanel`) but **interactive** — it
/// has Record / Dismiss buttons. Talkie never records silently; this banner is the
/// only path auto-detection takes to a recording, and it requires an affirmative tap.
///
/// `.nonactivatingPanel` is deliberate: tapping "Record" must not steal focus from
/// the call. An untouched banner soft-dismisses after ~12 s (suppresses re-offering
/// this meeting session, but doesn't count toward muting the app).
@MainActor
final class MeetingConsentBannerController {
    private var panel: NSPanel?
    private let model = BannerModel()
    private var autoHide: Task<Void, Never>?

    private static let panelSize = NSSize(width: 480, height: 156)

    /// Show the offer. `onDismiss(explicit:)` distinguishes the user tapping Dismiss
    /// (`true` — counts toward the per-app mute) from the auto-hide (`false`).
    func show(appName: String?,
              isBrowser: Bool,
              onRecord: @escaping () -> Void,
              onDismiss: @escaping (_ explicit: Bool) -> Void) {
        autoHide?.cancel()
        let panel = ensurePanel()

        model.appName = appName
        model.isBrowser = isBrowser
        model.onRecord = { [weak self] in
            self?.dismissPanel()
            onRecord()
        }
        model.onDismiss = { [weak self] in
            self?.dismissPanel()
            onDismiss(true)
        }
        model.visible = true

        NotchPanel.reposition(panel)
        panel.orderFrontRegardless()

        autoHide = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self else { return }
            self.dismissPanel()
            onDismiss(false)   // soft dismiss: this session only, no mute
        }
    }

    /// Hide the banner without invoking any callback (e.g. on the record handoff).
    func hide() {
        autoHide?.cancel()
        autoHide = nil
        dismissPanel()
    }

    private func dismissPanel() {
        autoHide?.cancel()
        autoHide = nil
        model.visible = false
        // Let the exit animation play before ordering the panel out.
        let panel = self.panel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NotchPanel.make(size: Self.panelSize, interactive: true)
        panel.contentView = NSHostingView(rootView: BannerView(model: model))
        self.panel = panel
        return panel
    }
}

@MainActor
private final class BannerModel: ObservableObject {
    @Published var appName: String?
    @Published var isBrowser = false
    @Published var visible = false
    var onRecord: () -> Void = {}
    var onDismiss: () -> Void = {}
}

private struct BannerView: View {
    @ObservedObject var model: BannerModel

    var body: some View {
        card
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
            // Same calm spring entrance as the HUD: pops up and drops from the notch.
            .scaleEffect(model.visible ? 1 : 0.6, anchor: .top)
            .offset(y: model.visible ? 0 : -8)
            .opacity(model.visible ? 1 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.visible)
    }

    /// Honest, second-person copy. A dedicated meeting app is a strong signal; a
    /// browser is softer ("a call *may* have started").
    private var title: String {
        guard let app = model.appName else { return "Meeting detected".loc }
        return model.isBrowser
            ? String(format: "A call may have started in %@.".loc, app)
            : String(format: "%@ is in a call.".loc, app)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.coral)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Record it on-device? Audio stays on your Mac.".loc)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: model.onRecord) {
                        Text("Record".loc).fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    Button("Dismiss".loc, action: model.onDismiss)
                        .buttonStyle(.bordered)
                }
                .controlSize(.regular)
                .padding(.top, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
    }
}
