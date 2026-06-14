import SwiftUI

/// The Memory tab — a browsable window into the on-device Personal Context Graph:
/// the commitments, people, projects, and terms Talkie has learned from everything
/// you've dictated and every meeting, each shown with how often it came up, when it
/// was last seen, and a provenance snippet (why it's here). 100% local.
struct MemoryView: View {
    @ObservedObject var graph: ContextGraphStore

    private var entities: [Entity] { Array(graph.entities.values) }
    private static let kindsInOrder: [EntityKind] = [.commitment, .person, .project, .term]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory")
                        .font(.talkieDisplay(26))
                        .foregroundStyle(Theme.ink)
                    Text("What Talkie has learned from everything you've said — commitments, people, projects, and terms. Built on-device; nothing leaves your Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                }

                if entities.isEmpty {
                    emptyState
                } else {
                    ForEach(Self.kindsInOrder, id: \.self) { kind in
                        let items = sorted(for: kind)
                        if !items.isEmpty { section(kind, items) }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sorted(for kind: EntityKind) -> [Entity] {
        let matches = entities.filter { $0.kind == kind }
            .sorted {
                ($0.pinned ? 1 : 0, $0.mentions, $0.lastSeenUnix)
                    > ($1.pinned ? 1 : 0, $1.mentions, $1.lastSeenUnix)
            }
        return Array(matches.prefix(60))
    }

    @ViewBuilder
    private func section(_ kind: EntityKind, _ items: [Entity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Self.label(kind)) · \(items.count)")
                .font(.talkieEyebrow)
                .foregroundStyle(Theme.inkSecondary)
            VStack(spacing: 0) {
                ForEach(items, id: \.id) { entity in
                    row(entity, tint: Self.tint(kind))
                    if entity.id != items.last?.id { Divider() }
                }
            }
            .talkieCard()
        }
    }

    @ViewBuilder
    private func row(_ entity: Entity, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.displayName)
                    .font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if let snippet = entity.provenance.last?.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if entity.mentions > 1 {
                    Text("×\(entity.mentions)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Text(Self.relative(entity.lastSeen))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(Theme.inkTertiary)
            Text("Nothing learned yet")
                .font(.talkieHeading(15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("As you dictate and record meetings, the people, projects, and commitments you mention show up here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private static func label(_ kind: EntityKind) -> String {
        switch kind {
        case .person: return "PEOPLE"
        case .project: return "PROJECTS"
        case .term: return "TERMS"
        case .commitment: return "COMMITMENTS"
        }
    }

    private static func tint(_ kind: EntityKind) -> Color {
        switch kind {
        case .person: return Theme.featherPlum
        case .project: return Theme.featherBlue
        case .term: return Theme.featherGreen
        case .commitment: return Theme.featherCoral
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
