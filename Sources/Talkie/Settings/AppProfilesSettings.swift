import AppKit
import SwiftUI

/// "Per-app rules" — override how Talkie cleans up, inserts, and biases for a
/// specific app, keyed by bundle id. An app with no override inherits your global
/// settings (or the per-category style), so the list only ever shows the apps you
/// actually customized — exactly what `AppProfileStore` stores.
///
/// Writes go through `AppProfileStore.upsert` / `.remove`. The editor mirrors the
/// global Cleanup pane's controls so the two read as the same surface, narrowed to
/// one app. Reuses the shared `SubPage` / `SettingsCard` / `SettingsRow` vocabulary.
struct AppProfilesSettings: View {
    @ObservedObject var profiles: AppProfileStore
    @ObservedObject var settings: AppSettings

    /// The profile being edited in the sheet (nil = sheet closed).
    @State private var editing: AppProfile?

    private var sortedProfiles: [AppProfile] {
        profiles.profiles.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        SubPage(title: "Per-app rules",
                subtitle: "Give an app its own cleanup, insertion, and vocabulary.") {
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

    /// A compact one-line description of what a profile overrides.
    private func summary(for p: AppProfile) -> String {
        var parts: [String] = []
        if let s = p.cleanupStyle { parts.append(s.displayName) }
        if let l = p.cleanupLevel { parts.append(l.displayName) }
        if let m = p.insertionMode { parts.append(m == .paste ? "Paste" : "Type") }
        if let filter = p.vocabularyFilter, !filter.isEmpty {
            parts.append("\(filter.count) terms")
        }
        return parts.isEmpty ? "Custom" : parts.joined(separator: " · ")
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
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == profile.bundleID }?.icon
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
    let settings: AppSettings
    let dictionaryVocab: [String]
    let onSave: (AppProfile) -> Void
    let onCancel: () -> Void

    // Each override is modeled as an optional binding the picker maps to "Inherit".
    private var cleanupStyle: Binding<CleanupStyle?> { $profile.cleanupStyle }
    private var cleanupLevel: Binding<CleanupLevel?> { $profile.cleanupLevel }
    private var insertionMode: Binding<InsertionMode?> { $profile.insertionMode }

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
                        footer: "“Inherit” follows your global Settings. Override either the per-app personality or the intensity, depending on which mode you use globally."
                    ) {
                        SettingsRow(title: "Personality") {
                            Picker("", selection: cleanupStyle) {
                                Text("Inherit").tag(CleanupStyle?.none)
                                ForEach(CleanupStyle.allCases) { Text($0.displayName).tag(CleanupStyle?.some($0)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        SettingsDivider()
                        SettingsRow(title: "Intensity") {
                            Picker("", selection: cleanupLevel) {
                                Text("Inherit").tag(CleanupLevel?.none)
                                ForEach(CleanupLevel.allCases) { Text($0.displayName).tag(CleanupLevel?.some($0)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }

                    SettingsCard(header: "Insertion & basics") {
                        SettingsRow(title: "Insert text by") {
                            Picker("", selection: insertionMode) {
                                Text("Inherit").tag(InsertionMode?.none)
                                ForEach(InsertionMode.allCases) { Text($0.displayName).tag(InsertionMode?.some($0)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        SettingsDivider()
                        TriStateRow(title: "Capitalize the first letter",
                                    value: $profile.autoCapitalize,
                                    inheritedDefault: settings.autoCapitalize)
                        SettingsDivider()
                        TriStateRow(title: "Remove filler words",
                                    value: $profile.removeFillers,
                                    inheritedDefault: settings.cleanupFillers)
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

/// A row for a `Bool?` override: Inherit / On / Off as a small segmented control,
/// labeled with what "Inherit" currently resolves to.
private struct TriStateRow: View {
    let title: String
    @Binding var value: Bool?
    let inheritedDefault: Bool

    private enum Choice: Hashable { case inherit, on, off }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch value {
                case .none: return .inherit
                case .some(true): return .on
                case .some(false): return .off
                }
            },
            set: {
                switch $0 {
                case .inherit: value = nil
                case .on: value = true
                case .off: value = false
                }
            }
        )
    }

    var body: some View {
        SettingsRow(title: title,
                    subtitle: value == nil ? "Inherits: \(inheritedDefault ? "On" : "Off")" : nil) {
            Picker("", selection: choice) {
                Text("Inherit").tag(Choice.inherit)
                Text("On").tag(Choice.on)
                Text("Off").tag(Choice.off)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}
