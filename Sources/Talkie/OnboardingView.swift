import SwiftUI
import AppKit

/// First-run welcome — a live aurora-glass backdrop with each step floating on a
/// frosted panel.
///
/// Shaped by the archetype review:
///   • The on-device **privacy promise gets its own panel, before any permission**
///     is requested (a dictation app asking for Accessibility + Input Monitoring
///     is keylogger-shaped until you explain it).
///   • Each permission row carries a one-line *why*.
///   • **No required typing** before first use — the name lives in Settings.
///   • A short, skippable spine: impatient users can jump straight to permissions.
///   • The final panel is an **accessible try-it**: it adapts to hold vs. toggle,
///     and confirms visually (the words land in the field), not by sound alone.
///   • Motion + transparency defer to the system accessibility settings — handled
///     by `LiveBackground` and `GlassCard`.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Bool

    // Speak-first order (H5): the mic-only try-it comes BEFORE the privacy promise,
    // the gesture, and — crucially — before Input Monitoring or Accessibility are ever
    // mentioned. A new user speaks and sees their words within ~15s of first launch.
    // The `ready` step keeps the real-hotkey try-it as the graduation moment.
    // Room is deliberately left after `tryIt` for one more step later (the A-series
    // profession packs) — adding a case here needs no other change.
    private enum Step: CaseIterable { case welcome, tryIt, privacy, gesture, permissions, ready }
    private let steps = Step.allCases
    @State private var step = 0
    // The final-step (`ready`) hotkey-driven try-it field (needs all permissions).
    @State private var tryText = ""
    // The speak-first (`tryIt`) step: a read-only results field + record button,
    // driven by a SEALED programmatic dictation (no clipboard/paste/History/stats).
    @State private var tryItText = ""
    @State private var tryItActive = false
    @State private var tryItError: String?

    private var current: Step { steps[step] }
    private var permissionsIndex: Int { steps.firstIndex(of: .permissions) ?? 4 }

    var body: some View {
        ZStack {
            LiveBackground(mood: .hero)

            VStack(spacing: 22) {
                Spacer(minLength: 16)
                card
                footer
                Spacer(minLength: 16)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { permissions.refresh() }
    }

    // MARK: Card

    private var card: some View {
        GlassCard {
            VStack(spacing: 22) {
                Image(nsImage: Brand.logo)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)

                content
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .id(current)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity
                    ))
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 38)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 460)
        .animation(.smooth(duration: 0.32), value: step)
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .welcome:     welcome
        case .tryIt:       tryIt
        case .privacy:     privacy
        case .gesture:     gesture
        case .permissions: permissionsStep
        case .ready:       ready
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 14) {
            Text("Welcome to Talkie")
                .font(.talkieDisplay(32))
                .foregroundStyle(Theme.ink)
            Text("Speak, and Talkie writes it for you — in any app, wherever your cursor is. It all runs on this Mac.")
                .font(.talkieHeading(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Speak-first try-it (H5)

    /// The mic-only first taste: a big record button and a read-only field the
    /// dictated words land in. Tapping record triggers the SEALED try-it dictation
    /// (`AppDelegate.toggleTryItDictation`) — the only permission it needs is the
    /// microphone, requested inline by the system when recording starts. No Input
    /// Monitoring, no Accessibility, and nothing the user says here is pasted,
    /// copied, learned, or stored.
    private var tryIt: some View {
        VStack(spacing: 18) {
            Text("Try it — just talk")
                .font(.talkieDisplay(29))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("No setup needed — click, speak, see your words.")
                .font(.talkieHeading(14.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TryItRecordButton(active: tryItActive) { toggleTryIt() }
                .padding(.top, 2)

            // Read-only results field — the words appear here as you speak. Never
            // editable: this is a demo of recognition, not a place to type.
            ScrollView {
                Text(tryItResultsDisplay)
                    .font(.talkieHeading(14, weight: .regular))
                    .foregroundStyle(tryItText.isEmpty ? Theme.inkTertiary : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 64, maxHeight: 96)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your dictated words")
            .accessibilityValue(tryItText.isEmpty ? "Empty" : tryItText)

            if let tryItError {
                Label(tryItError, systemImage: "exclamationmark.triangle")
                    .font(.talkieHeading(11.5, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // If the user walks away mid-recording (Back/Continue), stop the sealed
        // session so no dictation is left running behind the onboarding.
        .onDisappear { if tryItActive { AppDelegate.shared?.toggleTryItDictation(
            onInterim: { _ in }, onFinal: { _ in }, onError: { _ in }, onEnded: {}) } }
    }

    /// Placeholder-or-content for the results field. The read-only field shows a
    /// gentle prompt until the first words land.
    private var tryItResultsDisplay: String {
        if !tryItText.isEmpty { return tryItText }
        return tryItActive
            ? "Listening… say anything.".loc
            : "Your words will appear here.".loc
    }

    private func toggleTryIt() {
        guard let app = AppDelegate.shared else { return }
        if tryItActive {
            // Stop: the originally-installed onEnded resets `tryItActive`; the passed
            // closures here are ignored by the toggle's stop branch.
            app.toggleTryItDictation(
                onInterim: { _ in }, onFinal: { _ in }, onError: { _ in }, onEnded: {})
        } else {
            tryItError = nil
            tryItText = ""
            // Only flip to the recording state if a session actually started — a busy
            // engine or a synchronous refusal returns false (and surfaces its own error),
            // so the button must stay idle rather than lie about recording.
            let started = app.toggleTryItDictation(
                onInterim: { tryItText = $0 },
                onFinal: { tryItText = $0 },
                onError: { tryItError = $0; tryItActive = false },
                onEnded: { tryItActive = false }
            )
            tryItActive = started
        }
    }

    private var privacy: some View {
        VStack(spacing: 16) {
            Text("Private by design")
                .font(.talkieDisplay(30))
                .foregroundStyle(Theme.ink)
            Text("Your voice never leaves this Mac. Talkie transcribes and tidies your words entirely on-device — no servers, no account, nothing uploaded.")
                .font(.talkieHeading(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                PrivacyChip(icon: "lock.fill", text: "On-device")
                PrivacyChip(icon: "wifi.slash", text: "No cloud")
                PrivacyChip(icon: "person.crop.circle.badge.xmark", text: "No account")
            }
            .padding(.top, 2)
        }
    }

    private var gesture: some View {
        VStack(spacing: 16) {
            Text("Hold, speak, release — or tap twice to go hands-free")
                .font(.talkieDisplay(27))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hold your key, say what you want to write, and let go — Talkie drops the text in wherever you're typing. In a hurry? Tap the key twice to lock recording hands-free, then tap once to stop.")
                .font(.talkieHeading(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // One row, evenly spaced, never wraps: keycap → speak → typed.
            HStack(spacing: 10) {
                Keycap(text: settings.activationKey.displayName, symbol: settings.activationKey.symbolName)
                stepArrow
                HStack(spacing: 6) {
                    ClayIcon(name: "IconMic", size: 18)
                    Text("Speak").foregroundStyle(Theme.coral)
                }
                stepArrow
                HStack(spacing: 6) {
                    ClayIcon(name: "IconType", size: 18)
                    Text("Typed for you").foregroundStyle(Theme.positive)
                }
            }
            .font(.talkieHeading(13, weight: .semibold))
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    private var stepArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)
    }

    private var permissionsStep: some View {
        VStack(spacing: 15) {
            // After the speak-first try-it, the mic is usually already granted, so the
            // two remaining grants are the point of this step. Naming them honestly —
            // and only them — keeps the ask small and non-alarming.
            Text("Two more permissions")
                .font(.talkieDisplay(27))
                .foregroundStyle(Theme.ink)
            Text("To hear your dictation key and place your text into other apps, Talkie needs these two. Each is used only on this Mac.")
                .font(.talkieHeading(14, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 9) {
                OnboardPermissionRow(
                    icon: "IconMic",
                    title: "Microphone",
                    // Reads as an already-done confirmation for anyone who used the
                    // try-it; still tappable for those who skipped straight here.
                    why: permissions.microphone
                        ? "Granted while you tried it out."
                        : "To hear you while you dictate.",
                    granted: permissions.microphone
                ) { Task { await permissions.requestMicrophone() } }
                OnboardPermissionRow(
                    icon: "IconKeyboard",
                    title: "Input Monitoring",
                    why: "To notice your one dictation key — nothing else you type.",
                    granted: permissions.inputMonitoring
                ) {
                    permissions.requestInputMonitoring()
                    // If the grant is already live but the tap won't install yet,
                    // surface a one-click relaunch instead of a dead hotkey.
                    if !onRetryHotKey() && permissions.inputMonitoring {
                        permissions.hotKeyNeedsRelaunch = true
                    }
                }
                OnboardPermissionRow(
                    icon: "IconAccessibility",
                    title: "Accessibility",
                    why: "To place the finished text into the app you're using.",
                    granted: permissions.accessibility
                ) { permissions.promptAccessibility() }
            }
            .padding(.top, 2)

            // The rows flip to granted on their own as polling observes each grant —
            // no manual "Re-check" needed. When the key grant lands but the tap
            // can't install, offer a one-click relaunch (always the user's tap).
            if permissions.hotKeyNeedsRelaunch {
                VStack(spacing: 8) {
                    Text("Input Monitoring is on, but Talkie needs a quick relaunch to start hearing your key.")
                        .font(.talkieHeading(12.5, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch now") { permissions.relaunch() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.coral)
                        .controlSize(.large)
                }
                .padding(.top, 2)
            } else if permissions.allGranted {
                Label("All set", systemImage: "checkmark.seal.fill")
                    .font(.talkieHeading(13, weight: .semibold))
                    .foregroundStyle(Theme.positive)
            }
        }
        // Poll only while this step is on screen; the rows above flip to granted
        // live as System Settings changes land. Stopped on disappear so no loop
        // runs once the user moves past permissions.
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private var ready: some View {
        VStack(spacing: 15) {
            Text("You're ready")
                .font(.talkieDisplay(30))
                .foregroundStyle(Theme.ink)
            Text("Give it a go right here — or jump straight in.")
                .font(.talkieHeading(14.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "Click here, then hold \(settings.activationKey.displayName) and speak…",
                    text: $tryText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.talkieHeading(14, weight: .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(2...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                .accessibilityLabel("Try dictation here")
                .accessibilityHint("Hold your dictation key and speak; the words appear in this field.")

                if !permissions.allGranted {
                    Label("Grant the permissions to try it now — or skip and start using Talkie.",
                          systemImage: "info.circle")
                        .font(.talkieHeading(11.5, weight: .regular))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Theme.coral : Theme.inkTertiary.opacity(0.4))
                        .frame(width: i == step ? 22 : 7, height: 7)
                        .animation(.smooth(duration: 0.3), value: step)
                }
            }

            HStack {
                if step > 0 {
                    Button("Back") { back() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    Button("Skip intro") { jumpToPermissions() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkTertiary)
                        .help("Jump straight to granting permissions")
                }
                Spacer()
                // A `LocalizedStringKey` (not a plain `String`) so the label localizes
                // — `Button(_: String)` would bypass the .strings lookup.
                Button(primaryTitle, action: advance)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 460)
    }

    private var primaryTitle: LocalizedStringKey {
        switch current {
        case .welcome:     return "Get started"
        case .ready:       return "Start dictating"
        default:           return "Continue"
        }
    }

    // MARK: Navigation

    private func advance() {
        if step >= steps.count - 1 {
            settings.hasOnboarded = true
            return
        }
        withAnimation(.smooth(duration: 0.32)) { step += 1 }
        if current == .permissions { permissions.refresh() }
    }

    private func back() {
        withAnimation(.smooth(duration: 0.32)) { step = max(0, step - 1) }
    }

    private func jumpToPermissions() {
        withAnimation(.smooth(duration: 0.32)) { step = permissionsIndex }
        permissions.refresh()
    }
}

// MARK: - Pieces

private struct PrivacyChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.talkieHeading(11.5, weight: .semibold))
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surface.opacity(0.6)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

private struct Keycap: View {
    let text: String
    /// Optional SF Symbol shown before the label — a mouse glyph for the mouse
    /// side-button triggers, since there's no ⌥/⌃-style character for them.
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.talkieHeading(12, weight: .semibold))
            }
            Text(text)
        }
        .font(.talkieHeading(13, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// The big record button on the speak-first try-it step. Click to start, click to
/// stop. When recording, it turns to the live/recording feather tint and shows a
/// pulsing dot (a self-contained level cue — the real `onLevel` plumbing feeds the
/// HUD/bird, not this onboarding surface, so a dependency-free pulse is used here).
private struct TryItRecordButton: View {
    let active: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(active ? Theme.featherRed.opacity(0.16) : Theme.coral.opacity(0.14))
                    .frame(width: 76, height: 76)
                if active {
                    Circle()
                        .stroke(Theme.featherRed.opacity(0.5), lineWidth: 2)
                        .frame(width: 76, height: 76)
                        .scaleEffect(pulse ? 1.12 : 0.96)
                        .opacity(pulse ? 0 : 0.9)
                }
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(active ? Theme.featherRed : Theme.coral)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(active ? "Stop recording" : "Start recording")
        .accessibilityHint(active
            ? "Stops the demo and shows what you said."
            : "Records your voice and shows your words. Only the microphone is used.")
        .onChange(of: active) { _, isActive in
            pulse = false
            if isActive {
                withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
        }
    }
}

private struct OnboardPermissionRow: View {
    let icon: String
    let title: String
    let why: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ClayIcon(name: icon, size: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(why)
                    .font(.talkieHeading(11.5, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.positive)
                    .accessibilityHidden(true)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(why) \(granted ? "Granted." : "Not granted.")")
    }
}
