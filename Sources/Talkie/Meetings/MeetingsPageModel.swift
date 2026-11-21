import Foundation

/// Which meeting the two-pane Meetings page shows. Pure, so the rules are unit-tested
/// without a view: ids are in store order (newest first).
enum MeetingSelection {
    /// The selection after the list changed from `old` to `new`.
    /// - A meeting that just appeared (a recording stopped, an import finished) wins.
    /// - Otherwise the current selection is kept while it still exists.
    /// - A deleted selection moves to its neighbour: the next older meeting, else the
    ///   next newer one.
    /// - Nothing selected yet → the newest. An empty list → nil.
    static func resolve(current: UUID?, old: [UUID], new: [UUID]) -> UUID? {
        guard !new.isEmpty else { return nil }
        let oldSet = Set(old)
        // `old` empty = first load, not "everything was just added".
        if !old.isEmpty, let added = new.first(where: { !oldSet.contains($0) }) {
            return added
        }
        guard let current else { return new.first }
        let newSet = Set(new)
        if newSet.contains(current) { return current }
        if let index = old.firstIndex(of: current) {
            if let older = old[(index + 1)...].first(where: newSet.contains) { return older }
            if let newer = old[..<index].reversed().first(where: newSet.contains) { return newer }
        }
        return new.first
    }

    /// The meeting one step up/down from `current` (arrow keys in the list).
    static func step(from current: UUID?, in ids: [UUID], by offset: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}

/// The small date headers the meeting list is grouped under.
enum MeetingDateBucket: Hashable {
    case today, yesterday, earlierThisWeek
    case month(year: Int, month: Int)

    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> MeetingDateBucket {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        // A clock nudge can put a meeting slightly "in the future": still Today.
        if day >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day >= yesterday {
            return .yesterday
        }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), date >= week.start {
            return .earlierThisWeek
        }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    /// Consecutive groups in list order (the store is newest first, so groups come out
    /// newest first too). A bucket never repeats unless the input is out of order.
    static func group<T>(_ items: [T], date: (T) -> Date, now: Date,
                         calendar: Calendar = .current) -> [MeetingDateGroup<T>] {
        var out: [MeetingDateGroup<T>] = []
        for item in items {
            let b = bucket(for: date(item), now: now, calendar: calendar)
            if let last = out.indices.last, out[last].bucket == b {
                out[last].items.append(item)
            } else {
                out.append(MeetingDateGroup(bucket: b, items: [item]))
            }
        }
        return out
    }

    func title(calendar: Calendar = .current) -> String {
        switch self {
        case .today: return "Today".loc
        case .yesterday: return "Yesterday".loc
        case .earlierThisWeek: return "Earlier this week".loc
        case let .month(year, month):
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
            let f = DateFormatter()
            f.calendar = calendar
            f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return f.string(from: date)
        }
    }
}

/// One date header and the meetings under it.
struct MeetingDateGroup<T>: Identifiable {
    let bucket: MeetingDateBucket
    var items: [T]
    var id: MeetingDateBucket { bucket }
}

/// Display strings for a meeting's meta line. Stored values stay raw; only the view
/// localizes them.
enum MeetingMeta {
    static func duration(_ seconds: Double) -> String {
        String(format: "%d min".loc, Int((seconds / 60).rounded()))
    }

    static func speakers(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 speaker".loc : String(format: "%d speakers".loc, count)
    }

    /// The capture source in plain words, or nil for a source this build doesn't know.
    static func source(_ raw: String) -> String? {
        let importedPrefix = "talkie (imported: "
        if raw.hasPrefix(importedPrefix), raw.hasSuffix(")") {
            let name = raw.dropFirst(importedPrefix.count).dropLast()
            return name.isEmpty ? "Imported".loc : String(format: "Imported from %@".loc, String(name))
        }
        switch raw {
        case "talkie (mic + system audio)": return "Mic + call audio".loc
        case "talkie (mic-only)": return "Mic only".loc
        case "talkie (notes only)": return "Notes only".loc
        case "talkie (recovered)": return "Recovered".loc
        default: return nil
        }
    }
}
