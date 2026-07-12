import AppKit
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
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @State private var entitlements: [Entitlement] = []
    @State private var hasNetwork = false
    /// The running build's code-signature hash (cdhash), read once from the
    /// signature alongside the entitlements; `nil` on an ad-hoc / un-signed build.
    @State private var cdhash: String? = nil
    /// The marketing version, read from `Bundle.main` for the proof card.
    @State private var appVersion: String? = nil
    /// Set true while the "Copy proof card" button flashes its confirmation.
    @State private var copiedProof = false
    /// Set true while the "Copy diagnostic report" button flashes its confirmation.
    @State private var copiedReport = false

    /// Bridges the scalar `historyRetentionDays` setting to the typed picker.
    private var retention: Binding<HistoryRetention> {
        Binding(
            get: { HistoryRetention.from(days: settings.historyRetentionDays) },
            set: { settings.historyRetentionDays = $0.rawValue }
        )
    }

    /// Bridges the scalar `historyMaxCount` setting to the typed picker.
    private var maxCount: Binding<HistoryMaxCount> {
        Binding(
            get: { HistoryMaxCount.from(count: settings.historyMaxCount) },
            set: { settings.historyMaxCount = $0.rawValue }
        )
    }

    /// Compact on-disk-size formatter for the history footprint. `.file` count
    /// style with KB→GB units so a small `history.json` reads "312 KB", not the
    /// "0 MB" that `ProcessFootprint.formatBytes` (MB/GB only) would round it to.
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    /// The "Your history" card footer: the live retained-dictation count plus the
    /// disk space it currently occupies. Uses `%d`/`%@`-format `.loc` strings (the
    /// codebase's plural idiom — no `.stringsdict`), with a singular form for exactly
    /// one entry so it never reads "1 dictations". The size is read from
    /// `history.onDiskByteCount` (a file stat, not a re-encode), so it costs nothing
    /// to recompute on each render. The old "capped at 2,000" sentence is gone: the
    /// cap is now a visible, user-set control (the "Maximum dictations" row) rather
    /// than a fixed fact to disclose.
    private var historyFooter: String {
        let count = history.entries.count
        let size = Self.sizeFormatter.string(fromByteCount: Int64(history.onDiskByteCount))
        let kept = count == 1
            ? "You're keeping 1 dictation right now.".loc
            : String(format: "You're keeping %d dictations right now.".loc, count)
        let disk = String(format: "It takes up %@ on this Mac.".loc, size)
        return kept + " " + disk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // ONE consolidated proof card (L6d): the on-device headline, a live
            // entitlement verdict line (green/red, from the same `loadEntitlements`
            // read), the embedded live socket readout, and the two copy buttons
            // (shareable PNG + diagnostic report). The full detail — the entitlement
            // LIST, the three verify-yourself commands, and the data locations —
            // lives on the "Verify our claims" subpage below, not crowding the root.
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    // Headline guarantee.
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

                    SettingsDivider(leadingInset: 0)

                    // Live entitlement verdict — one line, green/red, read from the
                    // signature. The full per-entitlement list is on the subpage.
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

                    SettingsDivider(leadingInset: 0)

                    // Live open-socket readout — the claim you can watch tick, not
                    // copy we typed. Refreshes every 2s ONLY while this pane is on
                    // screen (the TimelineView lives in a subview torn down when you
                    // navigate away, so there's no background timer).
                    SocketReadoutInline()                                                      // talkie:no-network(self-inspection)
                    // The honest caption that used to be the socket card's footer —
                    // preserved verbatim so the readout still names why the count
                    // stays zero mid speech-model download.                                  // talkie:no-network(self-inspection)
                    Text("Counted live from this app’s own file descriptors, refreshed while you’re on this page. Speech-model downloads run in Apple’s system services, not inside Talkie, so they never appear here.")
                        .font(.callout)
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 11)

                    SettingsDivider(leadingInset: 0)

                    // The two one-click receipts: a shareable branded PNG and the
                    // pasteable markdown diagnostic report. Both read live state at
                    // click time — nothing here is typed in.                               // talkie:no-network(self-inspection)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Copy proof card".loc)
                                .font(.talkieHeading(14, weight: .medium)).foregroundStyle(Theme.ink)
                            Text("A shareable receipt that nothing leaves this Mac.".loc)
                                .font(.talkieHeading(12, weight: .regular))
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button {
                            ProofCardExporter.copy(makeProofCardData())
                            copiedProof = true
                            Task { try? await Task.sleep(for: .seconds(1.4)); copiedProof = false }
                        } label: {
                            Label(copiedProof ? "Copied".loc : "Copy proof card".loc,
                                  systemImage: copiedProof ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.coral)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)

                    SettingsDivider()

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Copy diagnostic report".loc)
                                .font(.talkieHeading(14, weight: .medium)).foregroundStyle(Theme.ink)
                            Text("A pasteable markdown receipt you can drop into a GitHub issue.".loc)
                                .font(.talkieHeading(12, weight: .regular))
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button {
                            let report = DoctorReport.generate(includeTCC: true)
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(report, forType: .string)
                            copiedReport = true
                            Task { try? await Task.sleep(for: .seconds(1.4)); copiedReport = false }
                        } label: {
                            Label(copiedReport ? "Copied".loc : "Copy diagnostic report".loc,
                                  systemImage: copiedReport ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.coral)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
            }

            // "Verify our claims" push — the full detail (entitlement list, the
            // three verify-yourself commands, data locations) relocated intact to a
            // subpage so the root stays a single legible proof card.
            NavigationLink(value: SettingsPage.verifyClaims) {
                VerifyClaimsRow()
            }
            .buttonStyle(.plain)

            // How long history is kept — a threat-model choice, so it's your call,
            // not a silent default. Replaces the old hardcoded 7-day window. The
            // header localizes via `Eyebrow`→`.loc`; the footer/title/subtitle go
            // through `SettingsCard`/`SettingsRow`'s plain-`String` `Text`, which
            // does NOT auto-localize, so they're routed through `.loc` explicitly.
            // The footer states the live count (from `history`) plus the honest,
            // always-true cap — so the number the user sees matches what's on disk.
            SettingsCard(
                header: "Your history",
                footer: historyFooter
            ) {
                SettingsRow(
                    title: "Keep dictation history".loc,
                    subtitle: "Older dictations are deleted from this Mac after this long.".loc
                ) {
                    Picker("", selection: retention) {
                        ForEach(HistoryRetention.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsDivider()
                SettingsRow(
                    title: "Maximum dictations".loc,
                    subtitle: "Only the most recent are kept; older ones drop off past this count.".loc
                ) {
                    Picker("", selection: maxCount) {
                        ForEach(HistoryMaxCount.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .onAppear(perform: loadEntitlements)
    }

    /// Read the entitlement keys — plus the code-signature hash (cdhash) and the
    /// app version — from this process's own code signature.
    ///
    /// The SecCode logic itself now lives in `EntitlementInspector` (I6), so this
    /// pane and the `talkie doctor` CLI describe the exact same binary through one
    /// code path. We map the inspector's `Capability` values onto this view's local
    /// `Entitlement` type (which the rows bind to) — the read is identical to
    /// before, just factored out. The cdhash and version feed the shareable proof
    /// card (I5). On an ad-hoc / un-signed build the inspector returns an empty
    /// list and a `nil` cdhash, and the UI degrades honestly rather than inventing
    /// a value.
    private func loadEntitlements() {
        // Version is independent of the signature — read it unconditionally so the
        // proof card can show it even on an un-signed build.
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        cdhash = EntitlementInspector.cdhashHex
        let caps = EntitlementInspector.capabilities()
        entitlements = caps.map {
            Entitlement(key: $0.key, label: $0.label, isNetwork: $0.isNetwork)
        }
        hasNetwork = caps.contains { $0.isNetwork }
    }

    /// Assemble the current, real proof-card data from live state: the
    /// entitlements read from the signature, the live socket count, the cdhash,
    /// the version, and now. Called at click time so the values are fresh.
    private func makeProofCardData() -> ProofCardData {
        let snap = SocketAudit.snapshot()                                                      // talkie:no-network(self-inspection)
        return ProofCardData(
            entitlements: entitlements.map {
                ProofCardData.Entitlement(label: $0.label, key: $0.key, isNetwork: $0.isNetwork)
            },
            hasNetwork: hasNetwork,
            internetSockets: snap.isAvailable ? snap.internetSockets : nil,                    // talkie:no-network(self-inspection)
            cdhash: cdhash,
            version: appVersion,
            takenAt: Date()
        )
    }
}

/// The root's tappable "Verify our claims" row — a titled card with a trailing
/// chevron that pushes `SettingsPage.verifyClaims`. It's the single entry point to
/// the full proof detail (entitlement list, the three verify-yourself commands,
/// data locations) that L6d relocated off the root; the root itself keeps only the
/// one consolidated proof card above.
private struct VerifyClaimsRow: View {
    var body: some View {
        SettingsCard {
            HStack(spacing: 12) {
                ClayIcon(name: "IconSeal", size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify our claims".loc)
                        .font(.talkieHeading(14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("See the live entitlement list, the commands to check it yourself, and where your data lives.".loc)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }
}

/// "Verify our claims" (L6d) — the full zero-network proof detail, relocated off
/// the Privacy root intact: the live per-entitlement list read from this build's
/// signature, the three verify-yourself shell commands, and the data-locations
/// bullets. Reads its own entitlement snapshot on appear (the same
/// `EntitlementInspector` path the root and the `talkie doctor` CLI use), so the
/// list here always describes the running binary.
struct VerifyClaimsSubpage: View {
    @State private var entitlements: [Entitlement] = []
    @State private var hasNetwork = false

    var body: some View {
        SubPage(
            title: "Verify our claims",
            subtitle: "Every value below is read from this Mac right now — nothing is typed in."
        ) {
            // The live per-entitlement list read from the signature. The
            // codesign command that used to repeat in this card's footer is
            // de-duplicated (L6d) — it now lives once, as step 1 below.
            SettingsCard(
                header: "Entitlements (read from the signature)",
                footer: "Read live from this build’s code signature, not from text we typed. The exact command to confirm it yourself is step 1 below.".loc
            ) {
                if entitlements.isEmpty {
                    SettingsNote(
                        text: "No entitlements detected — typical of an un-signed debug build. The shipped, notarized build requests exactly one: microphone access.".loc,
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
                        text: "A network entitlement is present on a build labelled “Talkie”. That’s a bug — the shipping build has none.".loc,
                        tone: Theme.danger, icon: "exclamationmark.octagon.fill"
                    )
                } else {
                    SettingsNote(
                        text: "No com.apple.security.network.client — Talkie cannot be granted network access.".loc,
                        tone: Theme.positive, icon: "checkmark.seal.fill"
                    )
                }
            }

            // How to verify it yourself — the three shell commands, relocated intact.
            SettingsCard(
                header: "Verify it yourself",
                footer: "Run these against the app on your own Mac. They read the live signature, grep the source, and watch the wire — the same checks the diagnostic report gathers for you.".loc // talkie:no-network(self-inspection)
            ) {
                VerifyRow(number: "1", title: "Read the permissions".loc,
                          command: "codesign -d --entitlements - /Applications/Talkie.app")
                SettingsDivider()
                VerifyRow(number: "2", title: "Grep the source".loc,
                          command: "./scripts/check-no-network.sh")
                SettingsDivider()
                VerifyRow(number: "3", title: "Watch the wire".loc,
                          command: "nettop -p $(pgrep Talkie)")
            }

            SettingsCard(header: "Where your data lives") {
                BulletRow(text: "~/Library/Application Support/Talkie — settings and history.".loc)
                SettingsDivider(leadingInset: 0)
                BulletRow(text: "~/Talkie Meetings — your recordings and transcripts, in plain folders you own.".loc)
            }
        }
        .onAppear(perform: loadEntitlements)
    }

    /// Read the entitlement keys from this process's own code signature via the
    /// shared `EntitlementInspector` (I6) — the same path the root proof card and
    /// the `talkie doctor` CLI use, so all three describe the exact same binary. On
    /// an ad-hoc / un-signed build the inspector returns an empty list and the UI
    /// degrades honestly rather than inventing a value.
    private func loadEntitlements() {
        let caps = EntitlementInspector.capabilities()
        entitlements = caps.map {
            Entitlement(key: $0.key, label: $0.label, isNetwork: $0.isNetwork)
        }
        hasNetwork = caps.contains { $0.isNetwork }
    }
}

/// The live "open network sockets right now: 0" readout, as a row group with no
/// surface of its own so it embeds cleanly inside the one consolidated proof card
/// (L6d) rather than nesting a card-in-a-card. Isolated into its own view for one
/// reason: the `TimelineView(.periodic(from:by: 2))` that drives the 2s refresh
/// only exists while this view is in the hierarchy. When you leave the Privacy
/// pane the view is torn down and the timeline stops — so the audit runs exactly
/// while you're looking at it and never as a background timer (an I5 acceptance
/// criterion). Each tick re-reads `SocketAudit.snapshot()`, a cheap own-pid fd
/// walk.
///
/// The honest caption names the one thing that could otherwise confuse the number:
/// speech-model downloads happen in Apple's system daemons, in a *different*
/// process, so they can never show up in Talkie's own socket count — the zero
/// here is Talkie's, and it stays zero even mid-download.
private struct SocketReadoutInline: View {                                                     // talkie:no-network(self-inspection)
    var body: some View {
        // `.periodic` fires immediately then every 2s; the closure re-samples
        // per tick. TimelineView owns the cadence, so no Timer/Task leaks.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            SocketReadoutRow(snapshot: SocketAudit.snapshot())                                 // talkie:no-network(self-inspection)
        }
    }
}

/// One rendered readout line for a given snapshot. Green seal + "0" in the
/// expected case; `Theme.danger` with the count if any internet socket is ever
/// open; an honest "couldn't read" if the audit itself failed.
private struct SocketReadoutRow: View {                                                        // talkie:no-network(self-inspection)
    let snapshot: SocketAudit.Snapshot                                                         // talkie:no-network(self-inspection)

    private var isClean: Bool { snapshot.isAvailable && snapshot.internetSockets == 0 }        // talkie:no-network(self-inspection)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Open network sockets right now:".loc)                                // talkie:no-network(self-inspection)
                        .font(.talkieHeading(14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(countText)
                        .font(.talkieHeading(14, weight: .bold))
                        .foregroundStyle(tone)
                }
                if !snapshot.isAvailable {
                    Text("Couldn’t read this process’s sockets on this build.".loc)            // talkie:no-network(self-inspection)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkTertiary)
                } else if !isClean {
                    Text("An internet socket is open — that’s unexpected for the on-device core.".loc) // talkie:no-network(self-inspection)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.danger)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var iconName: String {
        guard snapshot.isAvailable else { return "questionmark.circle.fill" }
        return isClean ? "checkmark.seal.fill" : "exclamationmark.octagon.fill"
    }

    private var tone: Color {
        guard snapshot.isAvailable else { return Theme.inkTertiary }
        return isClean ? Theme.positive : Theme.danger
    }

    /// The number itself, or an em dash when the audit couldn't run.
    private var countText: String {
        snapshot.isAvailable ? String(snapshot.internetSockets) : "—"                          // talkie:no-network(self-inspection)
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
