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
    /// its word/phrase counts, and "Clear everything" wipes the store, so the
    /// lifetime vocabulary never outlives the history it was built from.
    @ObservedObject var wordFreq: WordFrequencyStore
    /// L2-a: transcripts rescued to the Scratchpad (failed insertions) are part of
    /// the dictation record — deleting a dictation purges the lines it sourced, and
    /// "Clear everything" drops all dictation-sourced lines. Notes/tasks the user
    /// typed here (sourceDictationID == nil) survive, matching the "rules you taught
    /// stay" contract.
    @ObservedObject var scratchpad: ScratchpadStore
    /// L2-b (LOG-ONLY): the AI-auto-add calibration log stores commitment TEXT
    /// extracted from dictations, so — like the scratchpad's rescued lines — it is
    /// content-derived and joins true-delete: deleting a dictation purges its records,
    /// and "Clear everything" drops all dictation-sourced records. Defaulted so
    /// previews/tests that don't wire it still compile.
    var autoAddPreviewLog: AutoAddPreviewLog? = nil
    /// Cleared on every delete so `context_summary.json` can't keep quoting text you
    /// just deleted. Defaulted so previews/tests that don't wire it still compile.
    var contextSummary: ContextSummaryStore? = nil
    /// L5-b: the invented job title is derived from your vocabulary + app usage, so
    /// "Clear everything" wipes its cache alongside the word-frequency store — a
    /// coinage can't outlive the inputs it was made from. Defaulted so previews/tests
    /// that don't wire it still compile.
    var jobTitle: JobTitleStore? = nil
    /// L7: the user's profile picture is personal data on disk, so a full wipe removes
    /// it too — "Clear everything" calls `clear()`, deleting `profile.png`. Defaulted so
    /// previews/tests that don't wire it still compile.
    var profileImage: ProfileImageStore? = nil

    @State private var query = ""
    /// Drives the "Clear everything" confirmation — clearing history also erases what
    /// Talkie's memory extracted from it, so we ask first and state the scope honestly.
    @State private var showingClearConfirm = false
    /// True while the pointer is over the graph region. Drives `.scrollDisabled` on the
    /// page scroll view: over the graph, page scrolling is OFF so the graph's own
    /// drag-pan / pinch-zoom own the gesture; at or below the search bar it's ON so the
    /// search bar + history scroll up over the graph as normal. Tracked via
    /// `.onContinuousHover` on the graph layer.
    @State private var pointerOverGraph = false

    /// The graph occupies this fraction of the Memory viewport height as a top-anchored
    /// background band; the scroll content opens with a transparent spacer this tall, so
    /// the graph shows through until the user scrolls the search + history up over it.
    private static let graphHeightFraction: CGFloat = 0.57

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
        GeometryReader { geo in
            let graphHeight = geo.size.height * Self.graphHeightFraction

            // The graph is the FIRST child of the scroll view — a real, directly
            // interactive element, NOT a layer behind a transparent hole (SwiftUI can't
            // reliably route drags / hover / taps through that, which is what left the
            // graph completely un-navigable). Scrolling is disabled while the pointer is
            // over the graph, so a drag there pans / selects the graph instead of
            // scrolling the page; move below it (onto the search bar or history) and the
            // page scrolls, carrying the graph up out of view. The graph fades at its top
            // and bottom edges via its own gradient mask.
            ScrollView {
                VStack(spacing: 0) {
                    graphLayer(height: graphHeight)

                    pageContent
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.canvas)
                }
            }
            .scrollDisabled(pointerOverGraph)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Clear your dictation history?",
                            isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("Clear everything", role: .destructive) { clearEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes your dictation history and everything Talkie's memory extracted from it. Dictionary rules you taught, and notes you wrote in your Scratchpad, stay. Talkie overwrites the file before deleting it. For protection if your Mac is lost or seized, keep FileVault on.")
        }
    }

    // MARK: Graph layer (scroll-view header, blur-faded top + bottom)

    /// The knowledge graph as the scroll view's first child — a fixed-height, full-width
    /// band, faded at both edges via a vertical gradient mask (opaque in the middle,
    /// transparent at the very top and bottom) so it dissolves into the page rather than
    /// ending in a hard line. An `.onContinuousHover` tracks whether the pointer is over
    /// it, which gates page scrolling so the graph keeps its own drag-pan / pinch-zoom /
    /// tap-to-select while the pointer is inside it.
    private func graphLayer(height: CGFloat) -> some View {
        KnowledgeGraphView(contextGraph: contextGraph, chromeHidden: true)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.10),
                        .init(color: .black, location: 0.80),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .onContinuousHover { phase in
                switch phase {
                case .active:  pointerOverGraph = true
                case .ended:   pointerOverGraph = false
                }
            }
    }

    // MARK: Page content (header + search + history — the solid layer over the graph)

    /// The header (title + Copy All / Clear), the search bar, and the history / search
    /// results feed — everything that was the Memory page before, now stacked on the
    /// solid surface that scrolls up over the graph.
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PageHeader(title: "Memory",
                           subtitle: "Everything you've dictated and recorded, and everyone and everything Talkie has picked up from it.")
                Spacer()
                Button {
                    copyToClipboard(history.allAsText())
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .disabled(history.entries.isEmpty)
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("Clear", systemImage: "trash")
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
        contextSummary?.clearSummary()
    }

    /// Clear all history AND everything the memory graph learned from dictations,
    /// then wipe the Brief. Pinned dictionary terms the user taught survive (the graph
    /// purge keeps them). Meetings are a separate source and are untouched here.
    private func clearEverything() {
        history.clearAll()
        contextGraph.purge(source: .dictation, sourceID: nil)
        wordFreq.clearAll()
        // L5-b: the invented job title is derived from the vocabulary/usage being
        // cleared, so drop its cache too — right beside the word-freq wipe it tracks.
        jobTitle?.clearCache()
        scratchpad.purgeAllDictationSourced()
        // L2-b (LOG-ONLY): drop every dictation-sourced AI-auto-add preview record —
        // it's derived from the dictation history being cleared.
        autoAddPreviewLog?.purgeAllDictationSourced()
        contextSummary?.clearSummary()
        // L13-a: wipe the on-disk sentence-vector sidecar now, so the search cache
        // doesn't keep vectors for text you just cleared until the debounced rebuild
        // eventually rewrites it. (A delete of a single dictation ages out via that
        // rebuild; a full clear shouldn't have to wait for the debounce.)
        searchEngine.clearSidecar()
        // L7: a full wipe removes the profile picture too — it's personal data on disk.
        // Deletes `profile.png` and clears every surface instantly.
        profileImage?.clear()
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
    /// `LazyVStack` — the enclosing Memory page owns the single scroll view now (the
    /// graph sits behind it), so a nested same-axis ScrollView here would fight it.
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
            // Bare `LazyVStack`: the Memory page's single scroll view scrolls this feed
            // up over the graph behind it; a nested ScrollView here would conflict.
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
