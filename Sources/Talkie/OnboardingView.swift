import SwiftUI
import AppKit

/// First-run welcome — a live aurora-glass backdrop with each step floating on a
/// frosted panel.
///
/// Shaped by the archetype review, then cut down (2026-11-23, Jann: fewer steps,
/// plainer copy):
///   • The on-device promise is one line on the welcome; each permission row
///     carries a one-line *why* and says it is used only on this Mac. (The separate
///     privacy panel and its Wi-Fi dare were removed as an extra step.)
///   • **No required typing** before first use: "About you" (name, app language,
///     spoken languages) and "Style" (colours, how text comes out) come after the
///     try-it, apply as you choose and can be left with Continue.
///   • Copy: a title, at most one plain line under it. No slogans.
///   • A skippable spine: impatient users can jump straight to permissions.
///   • After the permissions, the AI-agent step connects Claude (or another agent)
///     over the local MCP, which can then finish the setup (`update_settings`).
///   • The final panel is an **accessible try-it**: it adapts to hold vs. toggle,
///     and confirms visually (the words land in the field), not by sound alone.
///   • Motion + transparency defer to the system accessibility settings — handled
///     by `TalkieBackdrop` and `GlassCard`.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Bool
    /// The step to open on (snapshot tests); 0 = the welcome.
    var initialStep = 0
    // One-time speech-model download state (macOS performs it; Talkie only reports it).
    @ObservedObject private var modelTracker = SpeechModelInstallTracker.shared

    // Speak-first order (H5): the mic-only try-it comes BEFORE the setup steps,
    // the gesture, and — crucially — before Input Monitoring or Accessibility are ever
    // mentioned. A new user speaks and sees their words within ~15s of first launch.
    // The `ready` step keeps the real-hotkey try-it as the graduation moment.
    // Adding a case here needs no other change (the dots, Back/Continue and the
    // snapshot indices all follow `Step.allCases`).
    private enum Step: CaseIterable {
        case welcome, tryIt, about, gesture, style, permissions, agent, ready
    }
    /// Where a restart for a new app language comes back to (the step after `about`).
    static let resumeStepKey = "onboardingResumeStep"
    private let steps = Step.allCases
    @State private var step = 0
    /// Index of the final "You're ready" step (snapshot tests).
    static var readyStepIndex: Int { Step.allCases.count - 1 }
    static var permissionsStepIndex: Int { Step.allCases.firstIndex(of: .permissions) ?? 4 }
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
            TalkieBackdrop(turn: 0)

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
        // Poll for the whole flow (not just the permissions step) so the rows, the
        // final-step hint and button label, and the hotkey-tap retry all stay live
        // while System Settings changes land. Idempotent; stopped when the view goes.
        .onAppear {
            if step == 0, initialStep > 0 { step = min(initialStep, steps.count - 1) }
            // Back from the restart that switched the app language: carry on where
            // the user was.
            let resume = UserDefaults.standard.integer(forKey: Self.resumeStepKey)
            if resume > 0, initialStep == 0 {
                step = min(resume, steps.count - 1)
                UserDefaults.standard.removeObject(forKey: Self.resumeStepKey)
            }
            permissions.refresh()
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
        // Know whether the speech model is installed before the offline dare is
        // offered; stops once it is (or when the view goes away).
        .task {
            while !Task.isCancelled, modelTracker.phase != .installed {
                await modelTracker.probe(localeIdentifier: settings.spokenLanguages.first ?? "en-US")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Model download notice

    /// Visible state while macOS downloads the on-device speech model (first run on a
    /// Mac that does not have it yet). Says plainly that macOS does this download.
    @ViewBuilder
    private var modelDownloadNotice: some View {
        if modelTracker.phase.showsDownloadNotice {
            VStack(spacing: 6) {
                if let fraction = modelTracker.phase.progressFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Theme.coral)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Downloading the speech model (one time)…")
                    .font(.talkieHeading(12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("macOS does this one download itself — this app never connects to the internet. After it, everything runs offline.")
                    .font(.talkieHeading(11.5, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
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
        case .about:       OnboardingAboutStep(settings: settings, onRestartForLanguage: restartForLanguage)
        case .gesture:     gesture
        case .style:       OnboardingStyleStep(settings: settings)
        case .permissions: permissionsStep
        case .agent:       OnboardingAgentStep()
        case .ready:       ready
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 14) {
            Text("Welcome to Talkie")
                .font(.talkieDisplay(32))
                .foregroundStyle(Theme.ink)
            Text("Hold a key, talk, and your words are typed wherever your cursor is. Everything runs on this Mac.")
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
            Text("Try it")
                .font(.talkieDisplay(29))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Click the button and say something.")
                .font(.talkieHeading(14.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TryItRecordButton(active: tryItActive) { toggleTryIt() }
                .padding(.top, 2)

            modelDownloadNotice

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
                onFinal: {
                    tryItText = $0
                    // Words came back, so the model is certainly installed.
                    if !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        modelTracker.markInstalled()
                    }
                },
                onError: { tryItError = $0; tryItActive = false },
                onEnded: { tryItActive = false }
            )
            tryItActive = started
        }
    }

    private var gesture: some View {
        VStack(spacing: 16) {
            Text("Hold, talk, let go")
                .font(.talkieDisplay(27))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hold the key while you talk. When you let go, the text is typed where your cursor is.")
                .font(.talkieHeading(15, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("To record without holding, keep the key down a moment longer. Tap it once to stop.")
                .font(.talkieHeading(12.5, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
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

    /// Rows still needing a grant (the step lists all three, granted ones checked).
    private var missingPermissionCount: Int {
        PermissionKind.allCases.filter { permissions.rowAction($0) != .granted }.count
    }

    private var permissionsStep: some View {
        let missing = missingPermissionCount
        return VStack(spacing: 15) {
            // The heading counts the rows that still need a grant, so it always
            // matches what the step shows (the mic row stays listed, checked, once
            // it has been granted by the try-it).
            Text(LocalizedStringKey(OnboardingPermissionsCopy.headingKey(missing: missing)))
                .font(.talkieDisplay(27))
                .foregroundStyle(Theme.ink)
            Text(LocalizedStringKey(OnboardingPermissionsCopy.bodyKey(missing: missing)))
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
                    action: permissions.rowAction(.microphone)
                ) { permissions.performRowAction(.microphone) }
                OnboardPermissionRow(
                    icon: "IconKeyboard",
                    title: "Input Monitoring",
                    why: "Only to notice your dictation key.",
                    action: permissions.rowAction(.inputMonitoring)
                ) { permissions.performRowAction(.inputMonitoring, retryHotKey: onRetryHotKey) }
                OnboardPermissionRow(
                    icon: "IconAccessibility",
                    title: "Accessibility",
                    why: "To type the text into the app you're using.",
                    action: permissions.rowAction(.accessibility)
                ) { permissions.performRowAction(.accessibility) }
            }
            .padding(.top, 2)

            // The rows flip to granted on their own as polling observes each grant —
            // no manual "Re-check" needed. When the key grant lands but the tap
            // can't install, offer a one-click relaunch (always the user's tap).
            if permissions.hotKeyNeedsRelaunch {
                relaunchHint
            } else if permissions.allGranted {
                Label("All set", systemImage: "checkmark.seal.fill")
                    .font(.talkieHeading(13, weight: .semibold))
                    .foregroundStyle(Theme.positive)
            }
        }
    }

    private var relaunchHint: some View {
        VStack(spacing: 8) {
            Text("Input Monitoring is on, but Talkie needs a quick relaunch to start hearing your key.")
                .font(.talkieHeading(12.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Relaunch now") { permissions.relaunch() }
                .buttonStyle(.talkie(.primary))
                .controlSize(.large)
        }
        .padding(.top, 2)
    }

    private var ready: some View {
        VStack(spacing: 15) {
            Text("You're ready")
                .font(.talkieDisplay(30))
                .foregroundStyle(Theme.ink)
            Text("Try it here, or start using it.")
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
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface.opacity(0.55)))
                .accessibilityLabel("Try dictation here")
                .accessibilityHint("Hold your dictation key and speak; the words appear in this field.")

                if !readiness.canDictate {
                    HStack(alignment: .center, spacing: 10) {
                        TalkieStatusLine(text: String(format: "Still off: %@".loc, missingList), tone: .warning)
                        Spacer(minLength: 8)
                        Button("Review permissions") { jumpToPermissions() }
                            .buttonStyle(.talkie(.secondary, size: .small))
                    }
                }
                if permissions.hotKeyNeedsRelaunch {
                    relaunchHint
                }
            }
        }
    }

    private var readiness: OnboardingReadiness {
        OnboardingReadiness(microphone: permissions.microphone,
                            inputMonitoring: permissions.inputMonitoring,
                            accessibility: permissions.accessibility)
    }

    /// "Microphone, Input Monitoring" — the permissions still missing, localised.
    private var missingList: String {
        readiness.missing.map { $0.nameKey.loc }.joined(separator: ", ")
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
                        .buttonStyle(.talkie(.secondary))
                        .controlSize(.large)
                } else {
                    Button("Skip intro") { jumpToPermissions() }
                        .buttonStyle(.talkie(.secondary))
                        .controlSize(.large)
                        .help("Jump straight to granting permissions")
                }
                Spacer()
                // A `LocalizedStringKey` (not a plain `String`) so the label localizes
                // — `Button(_: String)` would bypass the .strings lookup.
                Button(primaryTitle, action: advance)
                    .buttonStyle(.talkie(.primary))
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 460)
    }

    private var primaryTitle: LocalizedStringKey {
        switch current {
        case .welcome:     return "Get started"
        case .ready:       return LocalizedStringKey(readiness.finishTitleKey)
        default:           return "Continue"
        }
    }

    // MARK: Navigation

    /// Restart into the app language just chosen, then come back to the next step.
    private func restartForLanguage() {
        let next = (steps.firstIndex(of: .about) ?? 0) + 1
        UserDefaults.standard.set(next, forKey: Self.resumeStepKey)
        permissions.relaunch()
    }

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

struct OnboardPermissionRow: View {
    let icon: String
    /// Localisation keys, looked up with `.loc` (a `String` would bypass the catalog).
    let title: String
    let why: String
    let action: PermissionRowAction
    let onTap: () -> Void

    private var granted: Bool { action == .granted }

    var body: some View {
        HStack(spacing: 12) {
            ClayIcon(name: icon, size: 24)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title.loc)
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(verbatim: why.loc)
                    .font(.talkieHeading(11.5, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch action {
            case .granted:
                // Shape + colour (never colour alone), sized like the buttons it replaces.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.positive)
                    .frame(minHeight: 24)
                    .accessibilityHidden(true)
            case .request:
                Button("Grant", action: onTap)
                    .buttonStyle(.talkie(.secondary, size: .small))
            case .openSettings:
                // The system dialog can no longer appear, so a "Grant" tap would do
                // nothing: send the user to the matching System Settings pane.
                Button("Open System Settings", action: onTap)
                    .buttonStyle(.talkie(.secondary, size: .small))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.surface.opacity(0.55)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title.loc). \(why.loc) \(granted ? "Granted.".loc : "Not granted.".loc)")
    }
}
