import Foundation

/// Owns the per-app override sheets (`AppProfile`) and resolves them against the
/// global `AppSettings` into a concrete `ResolvedProfile` the dictation pipeline
/// consumes. This is the single place behaviour is keyed by bundle id; it extends
/// today's per-`AppCategory` style resolution rather than forking it.
///
/// House style: `@MainActor` `ObservableObject`, atomic JSON write to Application
/// Support, failure-tolerant decode (a missing/corrupt file starts empty, which
/// reproduces today's exact behaviour for every app).
@MainActor
final class AppProfileStore: ObservableObject {
    /// The override sheets, keyed by bundle id. Sparse — only apps the user has
    /// actually customized appear here.
    @Published private(set) var profiles: [String: AppProfile] = [:]

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("app_profiles.json")
        load()
    }

    // MARK: - Resolution surface (the pipeline calls these; keep stable)

    /// Two-level merge widened to a three-tier merge for cleanup style:
    /// per-app override → (existing) per-category style → global cleanup level.
    ///
    /// `cleanupStyle` falls back to `settings.cleanupStyle(for:)` — the *existing*
    /// per-category helper — so an existing user with category styles gets
    /// byte-for-byte identical behaviour; the per-bundle layer is purely additive.
    /// `appAdaptiveCleanup` decides which of `cleanupStyle`/`cleanupLevel` the
    /// pipeline actually uses, mirroring the global switch.
    func resolve(for app: TargetApp, settings: AppSettings) -> ResolvedProfile {
        let p = app.bundleID.flatMap { profiles[$0] }
        let categoryStyle = settings.cleanupStyle(for: app.category)
        return ResolvedProfile(
            appAdaptiveCleanup: settings.appAdaptiveCleanup,
            cleanupStyle: p?.cleanupStyle ?? categoryStyle,
            cleanupLevel: p?.cleanupLevel ?? settings.cleanupLevel,
            // Paste is the universal default now that the global "Insert text by"
            // control is gone (B2). An app only ever resolves to `.type` when it has a
            // per-app override — set by the user, or learned automatically the first
            // time a paste verifiably failed to land there.
            insertionMode: p?.insertionMode ?? .paste,
            autoCapitalize: p?.autoCapitalize ?? settings.autoCapitalize,
            removeFillers: p?.removeFillers ?? settings.cleanupFillers,
            bundleID: app.bundleID,
            category: app.category
        )
    }

    /// The vocabulary terms to bias recognition toward in this app: the profile's
    /// filtered subset of the global dictionary, else all global vocab.
    ///
    /// Stale filter entries (terms since deleted from the dictionary) are silently
    /// ignored because we intersect with the *current* snapshot — never crashes,
    /// just yields no bias for the missing term.
    ///
    /// Post-feature-05 seam: this body becomes a graph query
    /// (`graph.biasPhrases(near: app)`) with `vocabularyFilter` narrowing it; the
    /// `beginDictation` call site does not change.
    func biasVocabulary(for app: TargetApp, dictionary: DictionaryStore) -> [String] {
        let all = dictionary.contextualPhrasesSnapshot()
        guard let filter = app.bundleID.flatMap({ profiles[$0]?.vocabularyFilter }),
              !filter.isEmpty else { return all }
        let wanted = Set(filter.map { $0.lowercased() })
        return all.filter { wanted.contains($0.lowercased()) }
    }

    // MARK: - Lookup

    /// The stored override sheet for a bundle id, if any.
    func profile(for bundleID: String) -> AppProfile? {
        profiles[bundleID]
    }

    /// Convenience for the Settings index subtitle ("N apps customized").
    var customizedCount: Int { profiles.count }

    // MARK: - Mutations (UI)

    /// Insert or update a profile. A profile that overrides nothing
    /// (`isEmpty`) is removed instead, so the list never keeps no-op rows.
    func upsert(_ profile: AppProfile) {
        if profile.isEmpty {
            profiles.removeValue(forKey: profile.bundleID)
        } else {
            profiles[profile.bundleID] = profile
        }
        save()
    }

    /// Delete an app's override sheet ("Reset to defaults").
    func remove(bundleID: String) {
        guard profiles.removeValue(forKey: bundleID) != nil else { return }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: AppProfile].self, from: data) else {
            return // absent or corrupt → empty → today's exact behaviour
        }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
