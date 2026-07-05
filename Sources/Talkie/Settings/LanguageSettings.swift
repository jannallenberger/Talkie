import SwiftUI

// MARK: - Language selection (L6b)
//
// The Settings root no longer renders all eleven 96×96 flag tiles inline — that
// grid was the single biggest block on the page. Instead the root shows a compact
// horizontal strip of the languages you actually speak (`LanguageSettings`), and
// the full picker moves to a pushed "All languages" subpage (`AllLanguagesPage`,
// resolved from `SettingsPage.allLanguages`).
//
// BOTH surfaces mutate the exact same `settings.spokenLanguages` through one shared
// entry point (`toggleSpokenLanguage`) so selection behaviour is byte-identical no
// matter where the user taps. The invariants the rest of the app depends on are
// preserved unchanged:
//   • at least one language stays selected (the ≥1 guard in `toggleSpokenLanguage`),
//   • the first entry is the primary — never reordered implicitly here, because
//     `AppSettings.spokenLanguages.didSet` syncs `localeIdentifier` off `.first`,
//   • that same `didSet` fires `notifyChanged()`, so engine warm-up / locale
//     switching keeps working exactly as before.
// No settings keys change; storage is untouched.

/// Toggle a language in `settings.spokenLanguages`, keeping at least one always
/// selected. This is the ONE place selection is mutated — the root strip and the
/// All-languages grid both call it, so the two surfaces can never drift. Appends
/// (never reorders) so the primary-language contract holds: the first entry stays
/// first, and `AppSettings` keeps `localeIdentifier` synced to it.
@MainActor
func toggleSpokenLanguage(_ id: String, in settings: AppSettings) {
    var langs = settings.spokenLanguages
    if langs.contains(id) {
        guard langs.count > 1 else { return }
        langs.removeAll { $0 == id }
    } else {
        langs.append(id)
    }
    settings.spokenLanguages = langs
}

/// The Settings-root Languages surface (L6b): a compact horizontal strip of the
/// languages you speak, then one or two unselected suggestions (system locale
/// first), then an "All languages ›" tile that pushes the full picker. The strip
/// scrolls horizontally on its own — vertical trackpad/wheel deltas pass straight
/// through to the page's outer `ScrollView`, so it never hijacks the page scroll.
struct LanguageSettings: View {
    @ObservedObject var settings: AppSettings

    /// Unselected catalog languages offered as quick-add suggestions next to the
    /// ones you already speak. The system locale (canonicalised to a catalog id)
    /// leads when it isn't already selected; we then top up to two from catalog
    /// order. Deliberately NO new heuristic — system locale is the only signal.
    private var suggestions: [TalkieLanguage] {
        let selected = Set(settings.spokenLanguages)
        var ordered: [TalkieLanguage] = []
        let systemID = canonicalLocaleID(Locale.current.identifier)
        if !selected.contains(systemID),
           let sys = talkieLanguageCatalog.first(where: { $0.id == systemID }) {
            ordered.append(sys)
        }
        for lang in talkieLanguageCatalog where !selected.contains(lang.id) {
            if ordered.contains(where: { $0.id == lang.id }) { continue }
            ordered.append(lang)
            if ordered.count >= 2 { break }
        }
        return ordered
    }

    /// The selected languages, in stored order (primary first) — mapped back to
    /// catalog entries so the strip reuses the same flag/name rendering.
    private var selectedLanguages: [TalkieLanguage] {
        settings.spokenLanguages.compactMap { id in
            talkieLanguageCatalog.first(where: { $0.id == id })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A wrapping grid of the languages you speak (+ a couple of suggestions and
            // the "All languages" tile) that FILLS the card width — no dead horizontal
            // whitespace, wrapping to a second row only when there are many. Tiles share
            // the detail page's flag size so the two surfaces read as one design.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(selectedLanguages) { lang in
                    LanguageStripTile(
                        language: lang,
                        selected: true,
                        locked: settings.spokenLanguages == [lang.id]
                    ) { toggleSpokenLanguage(lang.id, in: settings) }
                }
                ForEach(suggestions) { lang in
                    LanguageStripTile(
                        language: lang,
                        selected: false,
                        locked: false
                    ) { toggleSpokenLanguage(lang.id, in: settings) }
                }
                AllLanguagesTile()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            Text(settings.spokenLanguages.count > 1
                 ? "Talkie auto-detects which of these you're speaking each time."
                 : "Pick more than one to have Talkie auto-detect your language.")
                .font(.callout)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.horizontal, 4)
        }
    }
}

/// A compact strip tile: a smaller flag over the language name, a selection check
/// when it's in the set. Tapping toggles the language (byte-identical to the grid).
/// The whole tile is the hit target and is sized for a comfortable tap.
private struct LanguageStripTile: View {
    let language: TalkieLanguage
    let selected: Bool
    /// True when this is the *only* selected language — tapping it is a no-op
    /// (Talkie always needs at least one), so the tile reads as locked-on.
    let locked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                flag
                    .frame(width: 72, height: 72)
                    .overlay(alignment: .bottomTrailing) {
                        if selected { checkBadge.offset(x: 4, y: 4) }
                    }
                Text(language.gridTitle)
                    .font(.talkieHeading(12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 128)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(selected ? Theme.coralWash : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Theme.coral : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.14), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(locked ? "Talkie keeps at least one language"
                     : (selected ? "Tap to remove" : "Tap to add"))
    }

    private var flag: some View {
        Group {
            if let region = Locale(identifier: language.id).region?.identifier,
               let img = Brand.image("Flag\(region)") {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                Text(language.flag).font(.system(size: 52))
            }
        }
    }

    private var checkBadge: some View {
        ZStack {
            Circle().fill(Theme.coral)
                .overlay(Circle().strokeBorder(selected ? Theme.coralWash : Theme.surface, lineWidth: 2.5))
                .frame(width: 20, height: 20)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// The trailing strip tile that pushes the full picker. A `NavigationLink` into
/// `SettingsPage.allLanguages`, styled to match the language tiles (globe over an
/// "All languages" label + chevron affordance) so the strip reads as one row.
private struct AllLanguagesTile: View {
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: SettingsPage.allLanguages) {
            VStack(spacing: 9) {
                Image(systemName: "globe")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Theme.coral)
                    .frame(width: 72, height: 72)
                HStack(spacing: 2) {
                    Text("All languages")
                        .font(.talkieHeading(12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("See every language")
    }
}

/// The "All languages" subpage (L6b), resolved from `SettingsPage.allLanguages`.
/// This is today's full flag grid, moved verbatim — identical toggle semantics,
/// `.help` strings, and locked-tile state — just wrapped in the shared `SubPage`
/// chrome so it reads as a proper pushed detail screen.
struct AllLanguagesPage: View {
    @ObservedObject var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)]

    var body: some View {
        SubPage(title: "All languages",
                subtitle: "Pick every language you speak; Talkie auto-detects which.") {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(talkieLanguageCatalog) { lang in
                        LanguageCard(
                            language: lang,
                            selected: settings.spokenLanguages.contains(lang.id),
                            locked: settings.spokenLanguages == [lang.id]
                        ) { toggleSpokenLanguage(lang.id, in: settings) }
                    }
                }
                Text(settings.spokenLanguages.count > 1
                     ? "Talkie auto-detects which of these you're speaking each time."
                     : "Pick more than one to have Talkie auto-detect your language.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

/// A tappable language tile: flag, language + country, and a check that fills the
/// corner when selected. Selected tiles wear the brand wash + ring.
private struct LanguageCard: View {
    let language: TalkieLanguage
    let selected: Bool
    /// True when this is the *only* selected language — tapping it is a no-op
    /// (Talkie always needs at least one), so the tile reads as locked-on.
    let locked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 13) {
                // The flag is the hero — large, centered, with the selection check
                // as a badge on its corner.
                flag
                    .frame(width: 72, height: 72)
                    .overlay(alignment: .bottomTrailing) {
                        if selected { checkBadge.offset(x: 5, y: 5) }
                    }
                VStack(spacing: 1) {
                    Text(language.gridTitle)
                        .font(.talkieHeading(14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(language.regionName)
                        .font(.talkieHeading(11.5, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(selected ? Theme.coralWash : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Theme.coral : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 7)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.14), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(locked ? "Talkie keeps at least one language"
                     : (selected ? "Tap to remove" : "Tap to add"))
    }

    private var flag: some View {
        Group {
            if let region = Locale(identifier: language.id).region?.identifier,
               let img = Brand.image("Flag\(region)") {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                Text(language.flag).font(.system(size: 52))
            }
        }
    }

    private var checkBadge: some View {
        ZStack {
            Circle().fill(Theme.coral)
                .overlay(Circle().strokeBorder(selected ? Theme.coralWash : Theme.surface, lineWidth: 3))
                .frame(width: 26, height: 26)
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
