import Foundation

/// One `.app` bundle discovered on disk, independent of whether it's currently
/// running — so the meeting-apps picker can offer Zoom/Teams/etc. even when
/// they're closed.
struct InstalledApp: Identifiable, Hashable, Sendable {
    var bundleID: String
    var displayName: String
    var path: String
    /// Apple's `LSApplicationCategoryType` (e.g. "public.app-category.business"),
    /// used only to group the picker's "All apps" section; nil groups as "Other".
    var category: String?

    var id: String { bundleID }
}

/// Scans the standard app locations for installed `.app` bundles. A plain read
/// of each bundle's Info.plist — no LaunchServices registration, no icon
/// loading (that stays lazy in the view via `NSWorkspace`, which caches it).
enum InstalledAppScanner {
    private static let searchDirectories: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Every distinct, bundle-identified app under the search directories,
    /// sorted by name. Does a handful of directory listings + small local
    /// Info.plist reads — cheap, but callers still run it off the main actor.
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [InstalledApp] = []
        for directory in searchDirectories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = directory + "/" + name
                guard let bundle = Bundle(path: path),
                      let bundleID = bundle.bundleIdentifier,
                      bundleID != AppPaths.bundleIdentifier,
                      seen.insert(bundleID).inserted
                else { continue }
                let displayName = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? (name as NSString).deletingPathExtension
                let category = bundle.infoDictionary?["LSApplicationCategoryType"] as? String
                out.append(InstalledApp(bundleID: bundleID, displayName: displayName, path: path, category: category))
            }
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

extension InstalledApp {
    /// Friendly label for `category`'s `LSApplicationCategoryType`, for the
    /// picker's "All apps" section headers. Falls back to "Other".
    var categoryLabel: String {
        guard let category, let name = Self.categoryNames[category] else { return "Other" }
        return name
    }

    private static let categoryNames: [String: String] = [
        "public.app-category.business": "Business",
        "public.app-category.developer-tools": "Developer Tools",
        "public.app-category.education": "Education",
        "public.app-category.entertainment": "Entertainment",
        "public.app-category.finance": "Finance",
        "public.app-category.games": "Games",
        "public.app-category.graphics-design": "Graphics & Design",
        "public.app-category.healthcare-fitness": "Health & Fitness",
        "public.app-category.lifestyle": "Lifestyle",
        "public.app-category.medical": "Medical",
        "public.app-category.music": "Music",
        "public.app-category.news": "News",
        "public.app-category.photography": "Photography",
        "public.app-category.productivity": "Productivity",
        "public.app-category.reference": "Reference",
        "public.app-category.social-networking": "Social Networking",
        "public.app-category.sports": "Sports",
        "public.app-category.travel": "Travel",
        "public.app-category.utilities": "Utilities",
        "public.app-category.video": "Video",
        "public.app-category.weather": "Weather",
    ]
}
