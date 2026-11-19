import SwiftUI

/// The first thing on the Commands page: is "format while you dictate" on or off, in
/// words, with the switch beside it — and which key to hold. The state is the title,
/// so it is readable without finding a switch ("Commands are on · hold Left ⌃ Control
/// while dictating" / "Commands are off"). A card row, per the guideline (no switches in
/// a header).
struct CommandsMasterCard: View {
    @ObservedObject var settings: AppSettings

    private var formatKey: ActivationKey { settings.effectiveFormatCommandKey }

    private var commandKeyBinding: Binding<ActivationKey> {
        Binding(get: { settings.effectiveFormatCommandKey },
                set: { settings.formatCommandKey = $0 })
    }

    /// The state line. Pure so it is tested.
    static func stateTitle(isOn: Bool, keyName: String) -> String {
        isOn ? String(format: "Commands are on · hold %@ while dictating".loc, keyName)
             : "Commands are off".loc
    }

    static func stateSubtitle(isOn: Bool) -> String {
        isOn ? "Say a format while you hold the key, then let go and keep talking.".loc
             : "Turn on to format as you dictate. Normal dictation keeps working either way.".loc
    }

    var body: some View {
        SettingsCard {
            SettingsToggleRow(
                title: Self.stateTitle(isOn: settings.formatCommandsEnabled, keyName: formatKey.displayName),
                subtitle: Self.stateSubtitle(isOn: settings.formatCommandsEnabled),
                isOn: $settings.formatCommandsEnabled)
            SettingsDivider()
            SettingsRow(title: "Format key".loc,
                        subtitle: "Pressed together with another key or a click, it does nothing.".loc) {
                ActivationKeyRecorder(key: commandKeyBinding) { candidate in
                    FormatCommandKey.refusal(for: candidate, dictationKey: settings.activationKey)
                }
            }
        }
    }
}
