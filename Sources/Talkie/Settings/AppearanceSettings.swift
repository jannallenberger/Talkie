import SwiftUI

/// Settings ▸ Profile & appearance: who you are (photo, name) and how Talkie looks —
/// light or dark, the accent feather, the logo-colour backdrop behind every page
/// (palette, strength, direction) and how see-through the glass cards are. Every
/// control applies at once: the page you are looking at is the preview.
struct AppearanceSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var profileImage: ProfileImageStore
    @ObservedObject private var appearance = AppearanceStore.shared

    private var look: TalkieLook { appearance.look }

    var body: some View {
        SubPage(title: "Profile & appearance",
                subtitle: "Your photo and name, plus colors, backdrop and glass.") {
            profileCard
            colourCard
            backdropCard
            glassCard
            HStack {
                Spacer()
                Button("Reset appearance".loc) { appearance.reset() }
                    .buttonStyle(.talkie(.secondary))
                    .disabled(look == TalkieLook())
            }
        }
    }

    // MARK: Profile

    private var profileCard: some View {
        SettingsCard(header: "Profile") {
            ProfilePhotoEditor(store: profileImage, name: settings.userName)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            SettingsDivider()
            SettingsRow(title: "Name".loc, subtitle: "Shown on the dashboard.".loc) {
                TextField("Your name".loc, text: $settings.userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }

    // MARK: Light / dark, accent

    private var colourCard: some View {
        SettingsCard(header: "Colors") {
            SettingsRow(title: "Appearance".loc) {
                Picker("", selection: binding(\.mode)) {
                    ForEach(TalkieAppearanceMode.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(title: "Accent color".loc,
                        subtitle: "Leads buttons, selection and links.".loc) {
                HStack(spacing: 10) {
                    ForEach(TalkieAccent.allCases) { accent in
                        AccentSwatch(accent: accent, selected: look.accent == accent) {
                            appearance.update { $0.accent = accent }
                        }
                    }
                }
            }
        }
    }

    // MARK: Backdrop

    private var backdropCard: some View {
        SettingsCard(header: "Backdrop",
                     footer: "The gradient is mixed from the colors of the logo and sits behind every page. Charts and buttons take their colors from it.".loc) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Colors".loc)
                    .font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 10) {
                    ForEach(TalkieBackdropStyle.allCases) { style in
                        BackdropSwatch(style: style, angle: look.angle, selected: look.backdrop == style) {
                            // The buttons follow: each backdrop brings its accent.
                            appearance.update { $0.backdrop = style; $0.accent = style.accent }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            SettingsDivider()
            SettingsRow(title: "Strength".loc) {
                HStack(spacing: 8) {
                    Text("Soft".loc).font(.talkieHeading(11.5, weight: .regular)).foregroundStyle(Theme.inkTertiary)
                    TalkieSlider(value: binding(\.intensity), label: "Strength".loc)
                        .frame(width: 220)
                    Text("Vivid".loc).font(.talkieHeading(11.5, weight: .regular)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .disabled(look.backdrop == .plain)
            SettingsDivider()
            SettingsRow(title: "Direction".loc) {
                HStack(spacing: 10) {
                    DirectionDial(degrees: look.angle)
                    TalkieSlider(value: binding(\.angle), range: 0...359, step: 1, label: "Direction".loc,
                                 valueText: "\(Int(look.angle.rounded()))°")
                        .frame(width: 220)
                    Text(verbatim: "\(Int(look.angle.rounded()))°")
                        .font(.talkieHeading(12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .disabled(look.backdrop == .plain)
            SettingsDivider()
            SettingsToggleRow(title: "Turn it on every page".loc,
                              subtitle: "Each page shows the gradient from a different angle.".loc,
                              isOn: binding(\.variesByPage))
                .disabled(look.backdrop == .plain)
        }
    }

    // MARK: Glass

    private var glassCard: some View {
        SettingsCard(header: "Glass",
                     footer: "With Reduce Transparency on in System Settings, cards are always solid.".loc) {
            SettingsRow(title: "Cards".loc,
                        subtitle: "How much of the backdrop shows through.".loc) {
                Picker("", selection: binding(\.glass)) {
                    ForEach(TalkieGlassStyle.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TalkieLook, Value>) -> Binding<Value> {
        Binding(get: { appearance.look[keyPath: keyPath] },
                set: { value in appearance.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Swatches

/// One accent choice: a lit dot of the colour; the selected one wears a ring and a check.
private struct AccentSwatch: View {
    let accent: TalkieAccent
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(LinearGradient(colors: [accent.palette.base.mix(with: .white, by: 0.22), accent.palette.base],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Theme.glassRim.opacity(0.7), lineWidth: 1))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accent.palette.on)
                    }
                }
                .padding(3)
                .overlay(Circle().strokeBorder(accent.palette.base, lineWidth: selected ? 2 : 0))
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(accent.title)
        .accessibilityLabel(Text(verbatim: accent.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One backdrop choice: a small tile of the gradient with its name under it.
private struct BackdropSwatch: View {
    let style: TalkieBackdropStyle
    let angle: Double
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                shape.fill(fill)
                    .frame(height: 46)
                    .overlay(shape.strokeBorder(Theme.glassRim.opacity(0.6), lineWidth: 1))
                    .overlay(shape.strokeBorder(Theme.brand, lineWidth: selected ? 2 : 0))
                Text(verbatim: style.title)
                    .font(.talkieHeading(12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(verbatim: style.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: AnyShapeStyle {
        guard style != .plain else { return AnyShapeStyle(Theme.surfaceSunken) }
        let points = TalkieBackdropGeometry.points(degrees: angle)
        return AnyShapeStyle(.linearGradient(
            Gradient(colors: style.colors.map { $0.opacity(0.85) }).colorSpace(.perceptual),
            startPoint: points.start, endPoint: points.end))
    }
}

/// A small dial showing where the gradient runs to.
private struct DirectionDial: View {
    let degrees: Double

    var body: some View {
        Circle()
            .fill(Theme.surfaceSunken)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .rotationEffect(.degrees(degrees))
            )
            .accessibilityHidden(true)
    }
}
