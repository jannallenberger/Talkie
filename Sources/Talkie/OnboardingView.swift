import SwiftUI
import AppKit

/// First-run welcome: meet the bird, set your name, learn the gesture, grant the
/// three permissions. Shown in place of the main window until completed.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Void

    @State private var step = 0
    private let total = 3
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            VStack(spacing: 24) {
                Image(nsImage: Brand.logo)
                    .resizable()
                    .frame(width: 74, height: 74)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
                content
                    .frame(maxWidth: 440)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 44)
            Spacer(minLength: 30)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(onboardingBackground)
        .onAppear { permissions.refresh() }
    }

    /// Cream canvas in light; in dark, the generated feather-bokeh ambient art
    /// (its center stays dark so the text reads). Decorative — accessibility-hidden.
    private var onboardingBackground: some View {
        ZStack {
            Theme.canvas
            if colorScheme == .dark, let bg = Brand.image("AmbientDark") {
                Image(nsImage: bg)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.9)
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
        .clipped()
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: gesture
        default: permissionsStep
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Text("Welcome to Talkie")
                .font(.talkieDisplay(34))
                .foregroundStyle(Theme.ink)
            Text("Your private, on-device dictation companion.\nFirst — what should we call you?")
                .font(.talkieHeading(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            TextField("Your name", text: $settings.userName)
                .textFieldStyle(.plain)
                .font(.talkieDisplay(22))
                .multilineTextAlignment(.center)
                .padding(.vertical, 13)
                .padding(.horizontal, 18)
                .frame(width: 290)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.hairline))
                .onSubmit(advance)
                .padding(.top, 4)
        }
    }

    private var gesture: some View {
        VStack(spacing: 16) {
            Text(settings.userName.isEmpty ? "Hold, speak, release" : "Nice to meet you, \(settings.userName)")
                .font(.talkieDisplay(30))
                .foregroundStyle(Theme.ink)
            Text("Hold your key, say what you want to write, and let go. Talkie types it wherever your cursor is — fully on your Mac.")
                .font(.talkieHeading(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 10) {
                Keycap(text: settings.activationKey.displayName)
                Image(systemName: "arrow.right").foregroundStyle(Theme.inkTertiary)
                Label("Speak", systemImage: "mic.fill").foregroundStyle(Theme.coral)
                Image(systemName: "arrow.right").foregroundStyle(Theme.inkTertiary)
                Label("Inserted", systemImage: "text.cursor").foregroundStyle(Theme.positive)
            }
            .font(.talkieHeading(13, weight: .semibold))
            .padding(.top, 6)
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Text("Three quick permissions")
                .font(.talkieDisplay(30))
                .foregroundStyle(Theme.ink)
            Text("All local — Talkie never sends your audio anywhere.")
                .font(.talkieHeading(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            VStack(spacing: 9) {
                OnboardPermissionRow(title: "Microphone", granted: permissions.microphone) {
                    Task { await permissions.requestMicrophone() }
                }
                OnboardPermissionRow(title: "Input Monitoring", granted: permissions.inputMonitoring) {
                    permissions.requestInputMonitoring(); onRetryHotKey()
                }
                OnboardPermissionRow(title: "Accessibility", granted: permissions.accessibility) {
                    permissions.promptAccessibility()
                }
            }
            .padding(.top, 4)
            if permissions.allGranted {
                Label("All set", systemImage: "checkmark.seal.fill")
                    .font(.talkieHeading(13, weight: .semibold))
                    .foregroundStyle(Theme.positive)
            } else {
                Button("Re-check") { permissions.refresh() }
                    .buttonStyle(.plain)
                    .font(.talkieHeading(12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Theme.coral : Theme.hairline)
                        .frame(width: i == step ? 20 : 7, height: 7)
                }
            }
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation(.easeInOut(duration: 0.2)) { step -= 1 } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button(step == total - 1 ? "Start dictating" : "Continue", action: advance)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .controlSize(.large)
            }
            .frame(maxWidth: 440)
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 40)
    }

    private func advance() {
        if step < total - 1 {
            withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
            if step == total - 1 { permissions.refresh() }
        } else {
            settings.hasOnboarded = true
        }
    }
}

private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.talkieHeading(13, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct OnboardPermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Theme.positive : Theme.inkTertiary)
            Text(title)
                .font(.talkieHeading(14, weight: .medium))
                .foregroundStyle(Theme.ink)
            Spacer()
            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}
