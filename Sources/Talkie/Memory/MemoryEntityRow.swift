import SwiftUI

/// One entity in the Memory tab: kind icon, name, mention count, and — inline,
/// no push, no sheet — a disclosure over its provenance (which dictation or
/// meeting mentioned it, when, with a snippet). Mirrors the "Show transcript"
/// disclosure pattern already used for meeting rows.
struct MemoryEntityRow: View {
    let entity: Entity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: kindIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(kindTint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.displayName)
                        .font(.talkieHeading(14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(mentionsSubtitle)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 8)
                if entity.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.coral)
                }
            }

            if !entity.provenance.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(expanded ? "Hide sources" : "Show \(entity.provenance.count) source\(entity.provenance.count == 1 ? "" : "s")")
                            .font(.talkieEyebrow)
                    }
                    .foregroundStyle(Theme.coral)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entity.provenance.reversed().enumerated()), id: \.offset) { _, p in
                            ProvenanceLine(provenance: p)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .talkieCard(padding: 14)
    }

    private var mentionsSubtitle: String {
        let times = entity.mentions == 1 ? "once" : "\(entity.mentions) times"
        return "Mentioned \(times) · last \(Self.relativeFormatter.localizedString(for: entity.lastSeen, relativeTo: Date()))"
    }

    private var kindIcon: String {
        switch entity.kind {
        case .person:     return "person.fill"
        case .project:    return "folder.fill"
        case .term:       return "textformat"
        case .commitment: return "checklist"
        }
    }

    private var kindTint: Color {
        switch entity.kind {
        case .person:     return Theme.featherPlum
        case .project:    return Theme.featherBlue
        case .term:       return Theme.featherGreen
        case .commitment: return Theme.featherGold
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// One provenance entry: where a mention came from, when, and a short quote.
private struct ProvenanceLine: View {
    let provenance: Provenance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: sourceIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sourceLabel)
                        .font(.talkieHeading(12, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                    Text(Self.dateFormatter.string(from: provenance.date))
                        .font(.talkieHeading(11.5, weight: .regular))
                        .foregroundStyle(Theme.inkTertiary)
                }
                if let snippet = provenance.snippet, !snippet.isEmpty {
                    Text("“\(snippet)”")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceIcon: String {
        switch provenance.source {
        case .dictation:  return "text.bubble"
        case .meeting:    return "person.2"
        case .dictionary: return "character.book.closed"
        case .calendar:   return "calendar"
        case .appContext: return "app.badge"
        }
    }

    private var sourceLabel: String {
        switch provenance.source {
        case .dictation:  return "Dictation"
        case .meeting:    return "Meeting"
        case .dictionary: return "Dictionary"
        case .calendar:   return "Calendar"
        case .appContext: return "On-screen context"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
