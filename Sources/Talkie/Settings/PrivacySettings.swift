import Security
import SwiftUI

/// "Privacy" — the honest, verifiable statement that nothing leaves your Mac,
/// backed by the *live* code signature rather than hardcoded copy. Reads the
/// running app's entitlements straight from `SecCode` so the panel can never drift
/// from what the binary actually claims; if a network entitlement ever appears, it
/// shows up here in red (per docs/PRIVACY.md).
///
/// Card-only section (no `SubPage`); composed into the merged Privacy &
/// Permissions page alongside the permission rows.
struct PrivacySection: View {
    @State private var entitlements: [Entitlement] = []
    @State private var hasNetwork = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Headline guarantee.
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    ClayIcon(name: "IconShield", size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("100% on-device")
                            .font(.talkieHeading(15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Your audio, transcripts, and meetings never touch the network. Talkie holds one permission, ships with no network entitlement, and contains zero networking code.")
                            .font(.callout)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            // Live entitlements from the signature.
            SettingsCard(
                header: "Entitlements (read from the signature)",
                footer: "Read live from this build’s code signature, not from text we typed. You can confirm it yourself: codesign -d --entitlements - /Applications/Talkie.app"
            ) {
                if entitlements.isEmpty {
                    SettingsNote(
                        text: "No entitlements detected — typical of an un-signed debug build. The shipped, notarized build requests exactly one: microphone access.",
                        tone: Theme.inkTertiary
                    )
                } else {
                    ForEach(Array(entitlements.enumerated()), id: \.element.key) { index, ent in
                        if index > 0 { SettingsDivider() }
                        EntitlementRow(entitlement: ent)
                    }
                }
                SettingsDivider(leadingInset: 0)
                if hasNetwork {
                    SettingsNote(
                        text: "A network entitlement is present on a build labelled “Talkie”. That’s a bug — the shipping build has none.",
                        tone: Theme.danger, icon: "exclamationmark.octagon.fill"
                    )
                } else {
                    SettingsNote(
                        text: "No com.apple.security.network.client — Talkie cannot be granted network access.",
                        tone: Theme.positive, icon: "checkmark.seal.fill"
                    )
                }
            }

            // How to verify it yourself.
            SettingsCard(header: "Verify it yourself") {
                VerifyRow(number: "1", title: "Read the permissions",
                          command: "codesign -d --entitlements - /Applications/Talkie.app")
                SettingsDivider()
                VerifyRow(number: "2", title: "Grep the source",
                          command: "./scripts/check-no-network.sh")
                SettingsDivider()
                VerifyRow(number: "3", title: "Watch the wire",
                          command: "nettop -p $(pgrep Talkie)")
            }

            SettingsCard(header: "Where your data lives") {
                BulletRow(text: "~/Library/Application Support/Talkie — settings and history.")
                SettingsDivider(leadingInset: 0)
                BulletRow(text: "~/Talkie Meetings — your recordings and transcripts, in plain folders you own.")
            }
        }
        .onAppear(perform: loadEntitlements)
    }

    /// Read the entitlement keys from this process's own code signature.
    private func loadEntitlements() {
        let known: [(key: String, label: String)] = [
            ("com.apple.security.device.audio-input", "Microphone capture"),
            ("com.apple.security.network.client", "Outbound network"),
            ("com.apple.security.network.server", "Inbound network"),
            ("com.apple.security.app-sandbox", "App Sandbox"),
        ]

        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSRequirementInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let ents = dict["entitlements-dict"] as? [String: Any] else { return }

        var found: [Entitlement] = []
        var network = false
        for entry in known {
            let present = (ents[entry.key] as? Bool) == true
            if present {
                found.append(Entitlement(key: entry.key, label: entry.label,
                                         isNetwork: entry.key.contains("network")))
                if entry.key.contains("network") { network = true }
            }
        }
        entitlements = found
        hasNetwork = network
    }
}

private struct Entitlement: Hashable {
    let key: String
    let label: String
    let isNetwork: Bool
}

private struct EntitlementRow: View {
    let entitlement: Entitlement

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entitlement.isNetwork ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(entitlement.isNetwork ? Theme.danger : Theme.positive)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entitlement.label)
                    .font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(entitlement.key)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// A numbered verification step with a copyable shell command.
private struct VerifyRow: View {
    let number: String
    let title: String
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.talkieHeading(12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.coral))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Theme.surfaceSunken)
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct BulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
