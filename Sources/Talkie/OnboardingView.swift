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

    private enum Step: CaseIterable { case welcome, privacy, gesture, permissions, ready }
    private let steps = Step.allCases
    @State private var step = 0
    @State private var tryText = ""

    private var current: Step { steps[step] }
    private var permissionsIndex: Int { steps.firstIndex(of: .permissions) ?? 3 }

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
            Text("Three quick permissions")
                .font(.talkieDisplay(27))
                .foregroundStyle(Theme.ink)
            Text("Talkie needs these to hear your key and place your text. Each is used only on this Mac.")
                .font(.talkieHeading(14, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 9) {
                OnboardPermissionRow(
                    icon: "IconMic",
                    title: "Microphone",
                    why: "To hear you while you dictate.",
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
                Button(primaryTitle, action: advance)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 460)
    }

    private var primaryTitle: String {
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
