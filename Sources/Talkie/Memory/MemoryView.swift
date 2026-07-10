import SwiftUI

/// "Memory" — merges what used to be three tabs (History + Memory + Search) into
/// one: a chronological feed of everything you've dictated, and a search box that
/// reuses the real `SearchEngine` (the same on-device semantic+keyword index that
/// used to power a standalone Search tab) to surface matching dictations,
/// meetings, and graph entities together. Deliberately has no People/Projects/
/// Terms sub-tabs — the underlying classification is a heuristic guess, not a
/// reliable fact, so presenting it as browsable categories overclaims confidence
/// it doesn't have. Search doesn't have that problem: a query either matches or
/// it doesn't, so it's the one honest way to reach the graph's contents.
struct MemoryView: View {
    @ObservedObject var contextGraph: ContextGraphStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var searchEngine: SearchEngine
    let meetingStore: MeetingStore
    /// L4: kept in step with the visible history — deleting a dictation decrements
    /// its word/phrase counts, so the lifetime vocabulary never outlives the history
    /// it was built from.
    @ObservedObject var wordFreq: WordFrequencyStore
    /// L2-a: transcripts rescued to the Scratchpad (failed insertions) are part of
    /// the dictation record — deleting a dictation purges the lines it sourced.
    /// Notes/tasks the user typed here (sourceDictationID == nil) survive, matching
    /// the "rules you taught stay" contract.
    @ObservedObject var scratchpad: ScratchpadStore
    /// L2-b (LOG-ONLY): the AI-auto-add calibration log stores commitment TEXT
    /// extracted from dictations, so — like the scratchpad's rescued lines — it is
    /// content-derived and joins true-delete: deleting a dictation purges its
    /// records. Defaulted so previews/tests that don't wire it still compile.
    var autoAddPreviewLog: AutoAddPreviewLog? = nil
    /// Cleared on every delete so `context_summary.json` can't keep quoting text you
    /// just deleted. Defaulted so previews/tests that don't wire it still compile.
    var contextSummary: ContextSummaryStore? = nil
    /// The niche-vocabulary store harvests up to 120 chars of each dictation as
    /// provenance, so deleting a dictation must drop those snippets too — otherwise a
    /// deleted transcript survives in `niche/vocab.json`. Defaulted so previews/tests
    /// that don't wire it still compile.
    var nicheVocab: NicheVocabStore? = nil
    @State private var query = ""

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            pageContent
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
    }

    // MARK: Page content (header + search + history)

    /// The header (title + Copy all), the search bar, and the history / search
    /// results feed — the whole Memory page.
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PageHeader(title: "Memory",
                           subtitle: "Everything you've dictated and recorded, and everyone and everything Talkie has picked up from it.")
                Spacer()
                Button {
                    copyToClipboard(history.allAsText())
                } label: {
                    Label("Copy all", systemImage: "doc.on.doc")
                }
                .disabled(history.entries.isEmpty)
            }

            searchField

            content
        }
    }

    // MARK: Delete (true delete — history + graph provenance + Brief)

    /// Delete one dictation everywhere it left a trace: the history entry, the graph
    /// provenance snippets that quoted its text (matched by the entry's id), and the
    /// persisted Brief (which is regenerated from literal history text, so it could
    /// otherwise still quote the deleted words until the next refresh).
    private func deleteDictation(_ entry: DictationEntry) {
        history.delete(entry)
        contextGraph.purge(source: .dictation, sourceID: entry.id.uuidString)
        wordFreq.purge(text: entry.text)
        scratchpad.purge(sourceID: entry.id.uuidString)
        // L2-b (LOG-ONLY): the AI-auto-add preview log quoted this dictation's
        // commitments — purge them so a deleted transcript leaves no trace there.
        autoAddPreviewLog?.purge(sourceID: entry.id.uuidString)
        // The niche-vocab store quoted up to 120 chars of this dictation as provenance —
        // drop them so the deleted transcript leaves no trace in niche/vocab.json.
        nicheVocab?.purge(sourceID: entry.id.uuidString)
        contextSummary?.clearSummary()
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            TextField("Search everything you've said and recorded, or a name/project/term", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
            if !query.isEmpty {
                Button {
                    query = ""
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

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            browseFeed
        } else {
            searchResults
        }
    }

    /// No query: the plain chronological feed (History's old job). Renders as a bare
    /// `LazyVStack` — the enclosing Memory page owns the single scroll view, so a nested
    /// same-axis ScrollView here would fight it.
    @ViewBuilder
    private var browseFeed: some View {
        if history.entries.isEmpty {
            emptyPrompt(title: "No dictations yet",
                        subtitle: "Hold your dictation key and speak — what you say will show up here.",
                        icon: "text.bubble")
        } else {
            LazyVStack(spacing: 10) {
                ForEach(history.entries) { entry in
                    MemoryDictationRow(entry: entry, formatter: Self.dateFormatter) {
                        copyToClipboard(entry.text)
                    } onDelete: {
                        deleteDictation(entry)
                    }
                }
            }
        }
    }

    /// With a query: real search (dictations + meetings + graph entities,
    /// semantic+keyword blended) via the shared `SearchEngine` — the same engine
    /// that used to power a standalone Search tab.
    @ViewBuilder
    private var searchResults: some View {
        let hits = searchEngine.search(trimmedQuery)
        if hits.isEmpty {
            emptyPrompt(title: "No matches",
                        subtitle: "Try a different word — this searches what you've said, your meetings, and what Talkie's picked up from them.",
                        icon: "magnifyingglass")
        } else {
            // Bare `LazyVStack`: the Memory page's single scroll view scrolls this feed;
            // a nested ScrollView here would conflict.
            LazyVStack(spacing: 10) {
                ForEach(hits) { hit in
                    resolvedRow(for: hit)
                }
            }
        }
    }

    /// Resolve a search hit's stable id back to its real source object and pick
    /// the row type that knows how to display it. Hit ids are
    /// `"<kind>:<uuid-or-key>"` (see `SearchEngine.makeIndex`).
    @ViewBuilder
    private func resolvedRow(for hit: SearchHit) -> some View {
        switch hit.kind {
        case .dictation:
            let uuid = String(hit.id.dropFirst("dictation:".count))
            if let entry = history.entries.first(where: { $0.id.uuidString == uuid }) {
                MemoryDictationRow(entry: entry, formatter: Self.dateFormatter) {
                    copyToClipboard(entry.text)
                } onDelete: {
                    deleteDictation(entry)
                }
            }
        case .meeting:
            let uuid = String(hit.id.dropFirst("meeting:".count))
            if let meeting = meetingStore.meetings.first(where: { $0.id.uuidString == uuid }) {
                MemoryMeetingRow(meeting: meeting)
            }
        case .entity:
            // "entity:<kind>:<key>" — reconstruct the EntityID and look the real
            // Entity up directly (O(1)) so the row gets full provenance, not just
            // the indexed snippet.
            let rest = hit.id.dropFirst("entity:".count)
            if let colon = rest.firstIndex(of: ":"),
               let kind = EntityKind(rawValue: String(rest[..<colon])) {
                let key = String(rest[rest.index(after: colon)...])
                if let entity = contextGraph.entities[EntityID(kind: kind, key: key)] {
                    MemoryEntityRow(entity: entity)
                }
            }
        }
    }

    private func emptyPrompt(title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Theme.inkTertiary)
            Text(title)
                .font(.talkieHeading(15))
                .foregroundStyle(Theme.inkSecondary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// One raw dictation row — copy, delete, date, source app.
private struct MemoryDictationRow: View {
    let entry: DictationEntry
    let formatter: DateFormatter
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var copied = false
    @State private var hovering = false

    private var appSymbol: String {
        AppCategory(rawValue: entry.appCategory ?? "")?.symbol ?? "app.dashed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatter.string(from: entry.date))
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
                if let appName = entry.appName, !appName.isEmpty {
                    HStack(spacing: 3) {
                        Group {
                            if let icon = AppIconLookup.icon(forBundleID: entry.bundleID) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: appSymbol).font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .frame(width: 11, height: 11)
                        Text(appName)
                    }
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Button {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(copied ? Theme.positive : Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy this dictation")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.danger : Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete this dictation")
            }
            Text(entry.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .talkieCard(padding: 14)
        .onHover { hovering = $0 }
    }
}

/// One meeting row — title, relative date, participants, and an inline
/// disclosure over the summary/transcript. Uses an explicit `Button` (not
/// `DisclosureGroup`) for the toggle — `DisclosureGroup`'s built-in tap target
/// didn't respond to clicks in this app when tried on the entity row; a plain
/// Button avoids that class of bug entirely.
private struct MemoryMeetingRow: View {
    let meeting: Meeting
    @State private var expanded = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.featherPlum)
                Text(meeting.title)
                    .font(.talkieHeading(14.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: meeting.date, relativeTo: Date()))
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
            }

            if !meeting.summary.isEmpty {
                MarkdownText(markdown: meeting.summary, bulletColor: Theme.coral)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
            }

            if !meeting.transcript.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(expanded ? "Hide transcript" : "Show transcript")
                            .font(.talkieEyebrow)
                    }
                    .foregroundStyle(Theme.coral)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    Text(meeting.transcript)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
        .talkieCard(padding: 14)
    }
}
