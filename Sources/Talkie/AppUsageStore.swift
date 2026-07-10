import Foundation
import AppKit

/// A coarse category for the app you dictated into — drives the icon + grouping
/// on the dashboard's usage breakdown.
enum AppCategory: String, Codable, CaseIterable {
    case coding, browser, mail, chat, notes, terminal, design, other

    var label: String {
        switch self {
        case .coding:   return "Coding"
        case .browser:  return "Browsing"
        case .mail:     return "Email"
        case .chat:     return "Messages"
        case .notes:    return "Notes & Docs"
        case .terminal: return "Terminal"
        case .design:   return "Design"
        case .other:    return "Other"
        }
    }

    /// SF Symbol for the category.
    var symbol: String {
        switch self {
        case .coding:   return "chevron.left.forwardslash.chevron.right"
        case .browser:  return "globe"
        case .mail:     return "envelope.fill"
        case .chat:     return "bubble.left.and.bubble.right.fill"
        case .notes:    return "doc.text.fill"
        case .terminal: return "terminal.fill"
        case .design:   return "paintbrush.pointed.fill"
        case .other:    return "app.dashed"
        }
    }

    /// Best-effort classification from a bundle id + display name.
    static func classify(bundleID: String?, name: String) -> AppCategory {
        let b = (bundleID ?? "").lowercased()
        let n = name.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { b.contains($0) || n.contains($0) } }

        if has(["xcode", "vscode", "visual-studio", "visualstudio", "code", "jetbrains",
                "intellij", "pycharm", "webstorm", "android-studio", "sublime", "nova",
                "cursor", "zed", "windsurf", "neovim", "vim", "fleet"]) { return .coding }
        if has(["terminal", "iterm", "warp", "alacritty", "kitty", "ghostty", "tmux"]) { return .terminal }
        if has(["mail", "outlook", "spark", "airmail", "superhuman", "missiveapp"]) { return .mail }
        if has(["slack", "discord", "telegram", "whatsapp", "messages", "imessage",
                "signal", "messenger", "teams", "zoom"]) { return .chat }
        if has(["safari", "chrome", "firefox", "arc", "brave", "edge", "vivaldi", "orion"]) { return .browser }
        if has(["notion", "obsidian", "bear", "notes", "craft", "ulysses", "textedit",
                "pages", "word", "docs", "logseq", "drafts"]) { return .notes }
        if has(["figma", "sketch", "framer", "photoshop", "illustrator", "affinity",
                "canva", "pixelmator"]) { return .design }
        return .other
    }
}

/// One app's lifetime dictation totals.
struct AppUsage: Codable, Identifiable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var category: AppCategory
    var words: Int = 0
    var dictations: Int = 0
}

/// A row ready for display, with its share of total words.
struct UsageSlice: Identifiable {
    let id: String
    let name: String
    let category: AppCategory
    let words: Int
    let dictations: Int
    let fraction: Double
}

/// Tracks which apps you dictate into. Populated from the frontmost app captured
/// at the moment each dictation begins. Feeds the dashboard "where your words
/// went" breakdown.
@MainActor
final class AppUsageStore: ObservableObject {
    @Published private(set) var apps: [String: AppUsage] = [:]

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("appusage.json")
        load()
    }

    func record(target: TargetApp, words: Int) {
        guard words > 0 else { return }
        let key = target.bundleID ?? target.name
        var entry = apps[key] ?? AppUsage(
            bundleID: key,
            name: target.name,
            category: AppCategory.classify(bundleID: target.bundleID, name: target.name)
        )
        entry.name = target.name // keep the freshest display name
        entry.words += words
        entry.dictations += 1
        apps[key] = entry
        save()
    }

    func reset() {
        apps = [:]
        save()
    }

    var totalWords: Int { apps.values.reduce(0) { $0 + $1.words } }
    var distinctApps: Int { apps.count }

    /// Top apps by words, with their share of the total. `limit` caps the list.
    func topApps(limit: Int = 6) -> [UsageSlice] {
        let total = max(1, totalWords)
        return apps.values
            .sorted { $0.words > $1.words }
            .prefix(limit)
            .map { UsageSlice(id: $0.id, name: $0.name, category: $0.category,
                              words: $0.words, dictations: $0.dictations,
                              fraction: Double($0.words) / Double(total)) }
    }

    /// Aggregated by category, share of total — used for the compact summary.
    func byCategory() -> [UsageSlice] {
        let total = max(1, totalWords)
        var buckets: [AppCategory: (words: Int, dictations: Int)] = [:]
        for app in apps.values {
            var b = buckets[app.category] ?? (0, 0)
            b.words += app.words; b.dictations += app.dictations
            buckets[app.category] = b
        }
        return buckets
            .sorted { $0.value.words > $1.value.words }
            .map { UsageSlice(id: $0.key.rawValue, name: $0.key.label, category: $0.key,
                              words: $0.value.words, dictations: $0.value.dictations,
                              fraction: Double($0.value.words) / Double(total)) }
    }

    private func load() {
        guard let decoded = StoreLoad.loadJSONWithQuarantine([String: AppUsage].self, from: fileURL) else { return }
        apps = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
