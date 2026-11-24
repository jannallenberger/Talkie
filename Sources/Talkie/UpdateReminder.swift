import AppKit
import SwiftUI

/// "This build is getting old" policy. Talkie never goes online, so it cannot
/// know whether a newer version exists; the only honest signal is the age of
/// this build. Pure and clock-injected so it is unit-tested; no I/O, no network.
enum UpdateReminder {
    enum Decision: Equatable {
        case hidden
        case show(days: Int)
    }

    /// Show once the build is this many days old.
    static let thresholdDays = 45
    /// A dismissal hides the line for this many days.
    static let snoozeDays = 14

    /// Parse the `TalkieBuildDate` Info.plist value (ISO 8601, UTC). Nil if
    /// missing or malformed.
    static func parseBuildDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func decide(buildDate: Date?, now: Date, lastDismissed: Date?) -> Decision {
        guard let buildDate, now >= buildDate else { return .hidden }
        let day: TimeInterval = 86_400
        let age = Int(now.timeIntervalSince(buildDate) / day)
        guard age >= thresholdDays else { return .hidden }
        if let lastDismissed, now >= lastDismissed,
           now.timeIntervalSince(lastDismissed) < Double(snoozeDays) * day {
            return .hidden
        }
        return .show(days: age)
    }

    // MARK: Bundle + browser hand-off

    static var bundleBuildDate: Date? {
        parseBuildDate(Bundle.main.object(forInfoDictionaryKey: "TalkieBuildDate") as? String)
    }

    /// The page "See the latest version" opens: the website's changelog (newest
    /// version, its download, what changed), from `Brand.websiteURL`.
    /// Without that key it falls back to the GitHub releases page.
    static func latestVersionURL(website: String?, repo: String?) -> URL? {
        if let website, !website.isEmpty {
            let base = website.hasSuffix("/") ? String(website.dropLast()) : website
            return URL(string: base + "/changelog/")
        }
        if let repo, !repo.isEmpty { return URL(string: repo + "/releases/latest") }
        return nil
    }

    /// Opens that page in the user's default browser; nothing is fetched in-process.
    @MainActor static func openLatestRelease() {
        guard let url = latestVersionURL(
            website: Brand.websiteURL,
            repo: Brand.repoURL
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The quiet, dismissible dashboard line.
struct UpdateReminderLine: View {
    let days: Int
    let onDismiss: () -> Void

    var body: some View {
        TalkieNotice(
            text: String(format: "This version of Talkie is %d days old. Talkie never goes online, so it cannot check for you.".loc, days),
            icon: "clock.arrow.circlepath",
            onDismiss: onDismiss
        ) {
            if Brand.marketingURL != nil {
                Button("See the latest version".loc) { UpdateReminder.openLatestRelease() }
                    .buttonStyle(.talkie(.secondary, size: .small))
            }
        }
    }
}

/// Settings row: version, build number and build date, with the same button.
struct VersionRow: View {
    private var info: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        if let d = UpdateReminder.bundleBuildDate {
            return String(format: "Version %@ (build %@), built on %@".loc, v, b,
                          d.formatted(date: .long, time: .omitted))
        }
        return String(format: "Version %@ (build %@)".loc, v, b)
    }

    var body: some View {
        SettingsCard(header: "Version") {
            SettingsRow(title: info, subtitle: "Talkie never goes online, so it cannot check for updates.".loc) {
                if Brand.marketingURL != nil {
                    Button("See the latest version".loc) { UpdateReminder.openLatestRelease() }
                        .buttonStyle(.talkie(.secondary))
                }
            }
        }
    }
}
