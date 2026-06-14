import AppKit
import SwiftUI

/// The recall surface (feature 19): a calm, on-device search over everything
/// you've dictated, every meeting Talkie has transcribed, and the people /
/// projects / terms in your context graph. Reads the injected `SearchEngine`
/// (the hub keeps its index fresh); tapping a hit reveals the source inline.
///
/// Design parity: serif `PageHeader`, `talkieCard` rows, feather tints per kind,
/// the same second-person voice as the rest of the app. No network — every word
/// here stays on your Mac.
struct SearchView: View {
    @ObservedObject var engine: SearchEngine
    let history: HistoryStore       // resolve a dictation hit back to its full text
    let meetingStore: MeetingStore  // resolve a meeting hit back to its note

    init(engine: SearchEngine, history: HistoryStore, meetingStore: MeetingStore) {
        self.engine = engine
        self.history = history
        self.meetingStore = meetingStore
    }

    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            PageHeader(title: "Search",
                       subtitle: "Find anything you've said — on-device.")

            searchField

            content
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            TextField("Search your dictations, meetings, and people", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .onChange(of: query) { _, _ in runSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    hits = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .talkieSurface(cornerRadius: Theme.Radius.control)
    }

    // MARK: Results

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyPrompt
        } else if hits.isEmpty {
            noMatches
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(hits) { hit in
                        SearchHitRow(hit: hit, detail: detail(for: hit))
                    }
                }
            }
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Theme.inkTertiary)
            Text("Search your second brain")
                .font(.talkieHeading(15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("Type a name, a topic, or a phrase. Talkie looks across everything you've dictated and recorded — meaning first, not just exact words.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Theme.inkTertiary)
            Text("Nothing matches yet.")
                .font(.talkieHeading(15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("Try a different word, or keep dictating — your history fills in as you go.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Logic

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = []; return }
        hits = engine.search(q)
    }

    /// Resolve a hit's stable id back to the full source so a tap can reveal more
    /// than the 160-char snippet. Hit ids are `"<kind>:<uuid…>"` (see SearchEngine).
    private func detail(for hit: SearchHit) -> SearchHitDetail {
        switch hit.kind {
        case .dictation:
            let uuid = String(hit.id.dropFirst("dictation:".count))
            if let entry = history.entries.first(where: { $0.id.uuidString == uuid }) {
                return .dictation(entry)
            }
        case .meeting:
            let uuid = String(hit.id.dropFirst("meeting:".count))
            if let meeting = meetingStore.meetings.first(where: { $0.id.uuidString == uuid }) {
                return .meeting(meeting)
            }
        case .entity:
            break
        }
        return .none
    }
}

// MARK: - Hit detail (resolved source)

/// What a hit points back to — used to reveal more than the snippet on tap.
private enum SearchHitDetail {
    case dictation(DictationEntry)
    case meeting(Meeting)
    case none
}

// MARK: - Row

private struct SearchHitRow: View {
    let hit: SearchHit
    let detail: SearchHitDetail
    @State private var expanded = false
    @State private var hovering = false

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var date: Date { Date(timeIntervalSince1970: hit.dateUnix) }

    /// Feather tint per source kind (per the design contract).
    private var tint: Color {
        switch hit.kind {
        case .dictation: return Theme.featherGold
        case .meeting:   return Theme.featherPlum
        case .entity:    return Theme.featherGreen
        }
    }

    private var glyph: String {
        switch hit.kind {
        case .dictation: return "text.quote"
        case .meeting:   return "person.2.fill"
        case .entity:    return "tag.fill"
        }
    }

    private var kindLabel: String {
        switch hit.kind {
        case .dictation: return "Dictation"
        case .meeting:   return "Meeting"
        case .entity:    return "From your graph"
        }
    }

    /// Whether tapping can reveal anything beyond the snippet.
    private var canExpand: Bool {
        switch detail {
        case .dictation, .meeting: return true
        case .none:                return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(kindLabel)
                    .font(.talkieEyebrow)
                    .tracking(0.8)
                    .foregroundStyle(tint)
                Spacer()
                Text(Self.dateFormatter.localizedString(for: date, relativeTo: Date()))
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
                if hovering {
                    actions
                }
            }

            Text(hit.snippet)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canExpand {
                DisclosureGroup(isExpanded: $expanded) {
                    expandedDetail
                } label: {
                    Text(expanded ? "Hide source" : "Show source")
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.coral)
                }
            }
        }
        .talkieCard(padding: 14)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch detail {
        case .dictation(let entry):
            Text(entry.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        case .meeting(let meeting):
            VStack(alignment: .leading, spacing: 6) {
                if !meeting.summary.isEmpty {
                    MarkdownText(markdown: meeting.summary, bulletColor: Theme.coral)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                } else {
                    Text(meeting.transcript)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch detail {
        case .dictation(let entry):
            Button {
                copy(entry.text)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
            .help("Copy this dictation")
        case .meeting(let meeting):
            Button {
                reveal(meeting)
            } label: {
                Image(systemName: "folder").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
            .help("Reveal note in Finder")
        case .none:
            EmptyView()
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func reveal(_ meeting: Meeting) {
        let url = AppPaths.meetingsDirectory().appendingPathComponent(meeting.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
