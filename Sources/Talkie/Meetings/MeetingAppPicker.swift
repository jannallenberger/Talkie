import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Meeting apps" picker sheet: browse installed apps as icon tiles
/// (grouped like the Languages picker), or hand-pick one via Finder — replaces
/// free-typing a bundle id, which almost nobody knows offhand.
struct MeetingAppPickerSheet: View {
    @ObservedObject var settings: AppSettings
    let onDismiss: () -> Void

    @State private var apps: [InstalledApp] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 110), spacing: 12)]

    private var suggested: [InstalledApp] { apps.filter(Self.isSuggested) }
    private var othersByCategory: [(String, [InstalledApp])] {
        let others = apps.filter { !Self.isSuggested($0) }
        return Dictionary(grouping: others, by: \.categoryLabel)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if apps.isEmpty {
                        Text("No apps found — use Choose from Finder below.".loc)
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.top, 40)
                    } else {
                        if !suggested.isEmpty {
                            section(title: "Suggested".loc, apps: suggested)
                        }
                        ForEach(othersByCategory, id: \.0) { title, group in
                            section(title: title, apps: group)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 560, height: 620)
        .background(Theme.canvas)
        .task {
            apps = InstalledAppScanner.scan()
            loaded = true
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting apps".loc)
                    .font(.talkieDisplay(18))
                    .foregroundStyle(Theme.ink)
                Text("Tap an app to add or remove it.".loc)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button("Done".loc, action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(Theme.coral)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button {
                chooseFromFinder()
            } label: {
                Label("Choose from Finder…".loc, systemImage: "folder")
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private func section(title: String, apps: [InstalledApp]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(apps) { app in
                    AppTile(
                        name: app.displayName,
                        icon: NSWorkspace.shared.icon(forFile: app.path),
                        selected: isAdded(app.bundleID)
                    ) { toggle(app) }
                }
            }
        }
    }

    private func isAdded(_ bundleID: String) -> Bool {
        settings.meetingAllowlist.contains { $0.bundleID == bundleID }
    }

    private func toggle(_ app: InstalledApp) {
        if isAdded(app.bundleID) {
            settings.meetingAllowlist.removeAll { $0.bundleID == app.bundleID }
        } else {
            settings.meetingAllowlist.append(
                MeetingApp(bundleID: app.bundleID, displayName: app.displayName, tier: .meetingApp)
            )
        }
    }

    private func chooseFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add".loc
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  !settings.meetingAllowlist.contains(where: { $0.bundleID == bundleID })
            else { continue }
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            settings.meetingAllowlist.append(MeetingApp(bundleID: bundleID, displayName: name, tier: .meetingApp))
        }
    }

    private static let knownBundleIDs = Set(MeetingApp.builtInAllowlist.map(\.bundleID))
    /// Floats known conferencing/chat apps to the top of the picker: anything
    /// already on the built-in seed list, plus anything the OS categorizes as
    /// Business or Social Networking (covers third-party apps like Skype,
    /// WhatsApp, or RingCentral that aren't hardcoded).
    private static func isSuggested(_ app: InstalledApp) -> Bool {
        if knownBundleIDs.contains(app.bundleID) { return true }
        return app.category == "public.app-category.business"
            || app.category == "public.app-category.social-networking"
    }
}

/// One tappable app tile in the picker grid — icon, name, and a selection
/// check — matching the Languages picker's `LanguageCard` visual language.
private struct AppTile: View {
    let name: String
    let icon: NSImage?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app.dashed").foregroundStyle(Theme.inkTertiary)
                    }
                }
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if selected { checkBadge.offset(x: 4, y: 4) }
                }
                Text(name)
                    .font(.talkieHeading(11.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(selected ? Theme.coralWash : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Theme.coral : Color.clear, lineWidth: 2)
            )
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.14), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var checkBadge: some View {
        ZStack {
            Circle().fill(Theme.coral)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 15, height: 15)
    }
}
