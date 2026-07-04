import AppKit
import SwiftUI

/// "Per-app rules" — override how Talkie cleans up, inserts, and biases for a
/// specific app, keyed by bundle id. An app with no override inherits your global
/// settings (or the per-category style), so the list only ever shows the apps you
/// actually customized — exactly what `AppProfileStore` stores.
///
/// Writes go through `AppProfileStore.upsert` / `.remove`. The editor mirrors the
/// global Cleanup pane's controls (cleanup style, insertion, vocabulary) so the two
/// read as the same surface, narrowed to one app. Reuses the shared `SubPage` /
/// `SettingsCard` / `SettingsRow` vocabulary.
struct AppProfilesSettings: View {
    @ObservedObject var profiles: AppProfileStore
    /// The global settings — needed so an "Inherit" override can state the live
    /// value it resolves to (the per-category cleanup style) instead of a bare
    /// "Inherit", both in each row summary here and inside the editor sheet.
    @ObservedObject var settings: AppSettings

    /// The profile being edited in the sheet (nil = sheet closed).
    @State private var editing: AppProfile?

    private var sortedProfiles: [AppProfile] {
        profiles.profiles.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Customized apps",
                footer: "Anything not listed here follows your global Settings. Add an app to give it a different personality — faithful in your terminal, friendly in Messages."
            ) {
                if sortedProfiles.isEmpty {
                    SettingsNote(
                        text: "No per-app rules yet. Talkie behaves the same in every app.",
                        tone: Theme.inkTertiary
                    )
                } else {
                    ForEach(Array(sortedProfiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { SettingsDivider() }
                        ProfileRow(
                            profile: profile,
                            summary: summary(for: profile),
                            onEdit: { editing = profile },
                            onRemove: { profiles.remove(bundleID: profile.bundleID) }
                        )
                    }
                }
                SettingsDivider(leadingInset: 0)
                HStack {
                    Spacer()
                    Menu {
                        if addableApps.isEmpty {
                            Text("No other apps are running")
                        } else {
                            ForEach(addableApps, id: \.bundleID) { app in
                                Button(app.name) {
                                    editing = AppProfile(bundleID: app.bundleID, displayName: app.name)
                                }
                            }
                        }
                    } label: {
                        Label("Add an app", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
        .sheet(item: $editing) { profile in
            AppProfileEditor(
                profile: profile,
                settings: settings,
                dictionaryVocab: dictionaryVocab,
                onSave: { profiles.upsert($0); editing = nil },
                onCancel: { editing = nil }
            )
        }
    }

    /// The global dictionary vocabulary, for the per-app filter chooser. Pulled
    /// from the shared store via the AppDelegate accessor so this pane stays
    /// settings-owned without threading a fourth store through the window.
    private var dictionaryVocab: [String] {
        AppDelegate.shared?.dictionary.vocabulary ?? []
    }

    /// A compact one-line description of what a profile does — stating the *effective*
    /// value for each facet, not just the overrides. The cleanup style always resolves
    /// to something (a per-app override, else the app's category style), so the row
    /// leads with the real style the app will use and tags it "inherited" when it's the
    /// category default. Private + a narrowed vocabulary are additive notes.
    private func summary(for p: AppProfile) -> String {
        let category = AppCategory.classify(bundleID: p.bundleID, name: p.displayName)
        let effectiveStyle = p.cleanupStyle ?? settings.cleanupStyle(for: category)
        var parts: [String] = []
        if p.neverStore == true { parts.append("Private".loc) }
        // Leading facet: the style the app actually cleans up in. Overrides read as
        // the plain style name; an inherited style is tagged so the row doesn't imply
        // the user set it here.
        if p.cleanupStyle != nil {
            parts.append(effectiveStyle.displayName)
        } else {
            parts.append(String(format: "%@ (inherited)".loc, effectiveStyle.displayName))
        }
        if let m = p.insertionMode { parts.append(m == .paste ? "Paste".loc : "Type".loc) }
        if let filter = p.vocabularyFilter, !filter.isEmpty {
            parts.append(filter.count == 1
                         ? "1 term".loc
                         : String(format: "%d terms".loc, filter.count))
        }
        return parts.joined(separator: " · ")
    }

    /// The currently-running apps the user can still add a rule for (regular,
    /// not Talkie itself, not already customized), sorted by name.
    private var addableApps: [AppPick] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppPick? in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != AppPaths.bundleIdentifier,
                      !profiles.profiles.keys.contains(bundleID) else { return nil }
                return AppPick(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A running app the user can attach a per-app rule to.
private struct AppPick { let bundleID: String; let name: String }

/// One customized-app row: the app's icon + name, a summary of its overrides, and
/// edit / reset affordances.
private struct ProfileRow: View {
    let profile: AppProfile
    let summary: String
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    private var icon: NSImage? {
        // Prefer the running instance's icon (reflects any live Dock-icon
        // override); fall back to a LaunchServices lookup so a per-app rule
        // for an app that isn't currently open still shows its real icon
        // instead of the generic placeholder.
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == profile.bundleID }?.icon
            ?? AppIconLookup.icon(forBundleID: profile.bundleID)
    }

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "app.dashed").foregroundStyle(Theme.inkTertiary) }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.talkieHeading(14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(summary)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.danger : Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Reset this app to your global settings")
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Editor sheet

/// Edit one app's override sheet. Every control is "Inherit + an override" so a
/// row left on Inherit writes `nil` (the field falls back to your global setting).
/// On save the profile is upserted; an all-Inherit profile is dropped by the store.
private struct AppProfileEditor: View {
    @State var profile: AppProfile
    /// Injected so each "Inherit" row can state the concrete value it resolves to —
    /// the same per-category cleanup style shown in Settings ▸ Smart cleanup.
    @ObservedObject var settings: AppSettings
    let dictionaryVocab: [String]
    let onSave: (AppProfile) -> Void
    let onCancel: () -> Void

    // Each override is modeled as an optional binding the picker maps to "Inherit".
    private var cleanupStyle: Binding<CleanupStyle?> { $profile.cleanupStyle }
    private var insertionMode: Binding<InsertionMode?> { $profile.insertionMode }

    /// This app's coarse category, from its bundle id + name — the key the cleanup
    /// style inherits through (matches the pipeline's `AppCategory.classify`).
    private var category: AppCategory {
        AppCategory.classify(bundleID: profile.bundleID, name: profile.displayName)
    }

    /// The concrete style Inherit resolves to for this app right now: its category's
    /// style from the global Smart-cleanup pane (a user override there, else the
    /// per-category default). Exactly what the dictation pipeline would use.
    private var inheritedStyle: CleanupStyle { settings.cleanupStyle(for: category) }

    /// Subtitle under the Style row: when overridden, the picked style's one-line
    /// `detail`; when left on Inherit, the live resolved value + its category, e.g.
    /// "Inherit — Faithful (Terminal apps)".
    private var styleSubtitle: String {
        if let s = profile.cleanupStyle { return s.detail }
        return String(format: "Inherit — %1$@ (%2$@ apps)".loc,
                      inheritedStyle.displayName, category.label)
    }

    /// Subtitle under the Insert-text-by row when left on Inherit. Paste is the
    /// universal default (B2 removed the global picker); Talkie flips just this app
    /// to Type automatically if a paste is seen to fail here.
    private var insertionSubtitle: String? {
        profile.insertionMode == nil
            ? "Paste (Talkie's default — switches to Type automatically if pastes fail here).".loc
            : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header.
            HStack(spacing: 10) {
                Group {
                    if let icon = appIcon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "app.dashed").foregroundStyle(Theme.inkTertiary) }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                        .font(.talkieDisplay(18))
                        .foregroundStyle(Theme.ink)
                    Text("Rules for this app only")
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
            }
            .padding(20)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsCard(
                        header: "Cleanup",
                        footer: "“Inherit” follows the style for this app's category in Settings. Override it to give just this app its own style."
                    ) {
                        SettingsRow(title: "Style", subtitle: styleSubtitle) {
                            Picker("", selection: cleanupStyle) {
                                Text("Inherit").tag(CleanupStyle?.none)
                                ForEach(CleanupStyle.allCases) { Text($0.displayName).tag(CleanupStyle?.some($0)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }

                    SettingsCard(header: "Insertion") {
                        // Since B2 removed the global insert-by picker, this per-app
                        // control is BOTH the sole escape hatch and the visible readout
                        // of what Talkie learned: an app shows "Type" here after a paste
                        // verifiably failed to land in it (Talkie switched it
                        // automatically). Pick "Inherit" to go back to the paste default
                        // and let it re-learn.
                        SettingsRow(title: "Insert text by", subtitle: insertionSubtitle) {
                            Picker("", selection: insertionMode) {
                                Text("Inherit").tag(InsertionMode?.none)
                                ForEach(InsertionMode.allCases) { Text($0.displayName).tag(InsertionMode?.some($0)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }

                    // "Private app" (I1): dictation still works, but Talkie stores and
                    // learns NOTHING from what you say here. The binding writes `true`
                    // when on and `nil` when off so the field stays sparse in
                    // `app_profiles.json` — an all-off profile is still dropped as empty.
                    SettingsCard(
                        header: "Privacy",
                        footer: "Turn this on for anything sensitive — a password manager, a private journal, a therapy note. Talkie still types what you say; it just never keeps a copy or learns from it. Your lifetime word count and streak still tick up (no content, no app name)."
                    ) {
                        // `SettingsToggleRow` renders its title/subtitle as plain
                        // `Text(String)`, which does NOT auto-localize a `String`
                        // argument — so route both through `.loc` (the same lever
                        // `Eyebrow` uses) and add the keys to all 10 `.lproj` files.
                        SettingsToggleRow(
                            title: "Private app".loc,
                            subtitle: "Dictation works here, but Talkie keeps no history and learns nothing.".loc,
                            isOn: Binding(
                                get: { profile.neverStore ?? false },
                                set: { profile.neverStore = $0 ? true : nil }
                            )
                        )
                    }

                    if !dictionaryVocab.isEmpty {
                        SettingsCard(
                            header: "Vocabulary",
                            footer: "By default this app is biased toward your whole dictionary. Narrow it to keep, say, contact names out of your terminal."
                        ) {
                            SettingsRow(
                                title: "Bias toward",
                                subtitle: vocabularyFilterSummary
                            ) {
                                Menu("Choose…") {
                                    Button("All terms") { profile.vocabularyFilter = nil }
                                    Divider()
                                    ForEach(dictionaryVocab, id: \.self) { term in
                                        let selected = (profile.vocabularyFilter ?? []).contains(term)
                                        Button {
                                            toggleTerm(term)
                                        } label: {
                                            if selected {
                                                Label(term, systemImage: "checkmark")
                                            } else {
                                                Text(term)
                                            }
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.canvas)

            Divider().overlay(Theme.hairline)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(profile) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
        .background(Theme.canvas)
    }

    private var appIcon: NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == profile.bundleID }?.icon
            ?? AppIconLookup.icon(forBundleID: profile.bundleID)
    }

    private var vocabularyFilterSummary: String {
        guard let filter = profile.vocabularyFilter, !filter.isEmpty else { return "All terms" }
        return filter.count == 1 ? "1 term" : "\(filter.count) terms"
    }

    private func toggleTerm(_ term: String) {
        var filter = profile.vocabularyFilter ?? []
        if let i = filter.firstIndex(of: term) { filter.remove(at: i) } else { filter.append(term) }
        profile.vocabularyFilter = filter.isEmpty ? nil : filter
    }
}
