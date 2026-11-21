import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in evidence for the Commands page and the pill's format states, in light and
/// dark. Skipped unless TALKIE_COMMANDS_SNAPSHOT_DIR is set. Uses only throwaway
/// stores (AppPaths' test sandbox).
/// Test-only: makes `Bundle.main` answer string lookups from one language's
/// `Localizable.strings` (the test host has no .lproj of its own), so snapshots can
/// show the German chrome. Restored by `CommandsSnapshotTests.useUILanguage(nil)`.
private final class LocalizedMainBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var table: [String: String] = [:]
    nonisolated(unsafe) static var language = "en"
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        Self.table[key] ?? ((value?.isEmpty ?? true) ? key : value!)
    }
    override var preferredLocalizations: [String] { [Self.language] }
}

@MainActor
final class CommandsSnapshotTests: XCTestCase {

    /// "de" → German chrome for the following snapshots; nil/"en" → the English source.
    private func useUILanguage(_ code: String?) {
        if object_getClass(Bundle.main) !== LocalizedMainBundle.self {
            object_setClass(Bundle.main, LocalizedMainBundle.self)
        }
        LocalizedMainBundle.language = code ?? "en"
        guard let code, code != "en" else { LocalizedMainBundle.table = [:]; return }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("Resources/Localizations/\(code).lproj/Localizable.strings")
        LocalizedMainBundle.table = (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }

    private var dir: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_COMMANDS_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_COMMANDS_SNAPSHOT_DIR to render the Commands snapshots")
        }
        _ = NSApplication.shared
        dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Hosts `view` offscreen (so AppKit-backed controls draw for real) and writes a
    /// light and a dark PNG. `height: nil` = the view's fitting height.
    func shot<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil,
                       background: Color = Theme.canvas, padding: CGFloat = 16,
                       @ViewBuilder _ view: () -> V) throws {
        let content = view()
        for (scheme, an) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let appearance = NSAppearance(named: an)!
            let root = content
                .padding(padding)
                .frame(width: width, height: height, alignment: .topLeading)
                .background(background)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: root)
            host.appearance = appearance
            let fitting = host.fittingSize
            let size = NSSize(width: width, height: height ?? max(40, fitting.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "no rep: \(name)")
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
            window.orderOut(nil)
            window.close()
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "render failed: \(name)")
            try data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private func store() throws -> MeetingStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-commands-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
    }

    func testCommandsPage() throws {
        let settings = AppSettings()
        let macros = MacroStore()
        let savedMacros = macros.macros
        let savedUser = settings.userFormatCommands
        let savedSynonyms = settings.formatSynonyms
        let savedDisabled = settings.disabledFormatPresets
        let savedEnabled = settings.formatCommandsEnabled
        defer {
            settings.userFormatCommands = savedUser
            settings.formatSynonyms = savedSynonyms
            settings.disabledFormatPresets = savedDisabled
            settings.formatCommandsEnabled = savedEnabled
            for m in macros.macros { macros.delete(m) }
            for m in savedMacros { macros.upsert(m) }
        }
        for m in macros.macros { macros.delete(m) }
        // An old snippet (no name) shows up as a user-made fixed-text card.
        macros.add(trigger: "my address", expansion: "1 Example Street, {date}")
        let shout = UserCommand(name: "Bold", phrases: ["make it bold", "in bold"], action: .wrap(before: "**", after: "**"))
        let quote = UserCommand(name: "Reply quote", phrases: ["quote reply"], action: .linePrefix("> "))
        settings.userFormatCommands = [shout, quote]
        settings.formatSynonyms = ["bulletList": ["tick marks", "Liste machen"]]
        settings.disabledFormatPresets = [FormatPreset.verbatim.rawValue]
        settings.formatCommandsEnabled = true
        let meetings = try store()

        try shot("commands-page", width: 900, height: 2000, padding: 0) {
            CommandsView(settings: settings, macros: macros, commandRouter: CommandRouter(macros: macros),
                         hud: HUDController(), meetingStore: meetings)
        }
        try shot("commands-how-it-works", width: 760) {
            HowItWorksStrip(dictationKey: settings.activationKey, formatKey: settings.effectiveFormatCommandKey)
        }
        try shot("commands-illustrations", width: 900) {
            let kinds: [CommandIllustration.Kind] = FormatPreset.allCases.map { .preset($0) } + [
                .user(.wrap(before: "**", after: "**")), .user(.linePrefix("> ")), .user(.textCase(.title)),
                .user(.rewrite(instruction: "x")), .user(.insert(text: "x")), .newCommand,
            ] + EditCommandKind.allCases.map { .edit($0) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { _, k in CommandIllustration(kind: k) }
            }
        }
        try shot("commands-edit-group", width: 900) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(EditCommandKind.allCases, id: \.self) { EditCommandCard(kind: $0) }
            }
        }
        let pop = Color(nsColor: .windowBackgroundColor)
        try shot("commands-detail-bullets", width: 392, background: pop, padding: 0) {
            FormatCommandDetail(preset: .bulletList, settings: settings, macros: macros, uiLanguageCode: "en")
        }
        try shot("commands-detail-email", width: 392, background: pop, padding: 0) {
            FormatCommandDetail(preset: .email, settings: settings, macros: macros, uiLanguageCode: "de")
        }
        try shot("commands-new", width: 392, background: pop, padding: 0) {
            UserCommandEditor(settings: settings, macros: macros, existing: nil) {}
        }
        try shot("commands-edit-user", width: 392, background: pop, padding: 0) {
            UserCommandEditor(settings: settings, macros: macros, existing: shout) {}
        }
        try shot("commands-edit-rewrite", width: 392, background: pop, padding: 0) {
            UserCommandEditor(settings: settings, macros: macros,
                              existing: UserCommand(name: "Friendly", phrases: ["friendlier"],
                                                    action: .rewrite(instruction: "warmer and a bit shorter"))) {}
        }
        try shot("commands-edit-snippet", width: 392, background: pop, padding: 0) {
            UserCommandEditor(settings: settings, macros: macros, existing: macros.macros[0].userCommand) {}
        }
        try shot("commands-edit-case", width: 392, background: pop, padding: 0) {
            UserCommandEditor(settings: settings, macros: macros,
                              existing: UserCommand(name: "Title", phrases: ["title case"], action: .textCase(.title))) {}
        }
        try shot("commands-edit-prefix", width: 392, background: pop, padding: 0) {
            UserCommandEditor(settings: settings, macros: macros, existing: quote) {}
        }
    }

    func testPunctuationSection() throws {
        let settings = AppSettings()
        let saved = settings.spokenPunctuation
        defer { settings.spokenPunctuation = saved }
        settings.spokenPunctuation = true
        for lang in ["en", "de"] {
            try shot("punctuation-card-\(lang)", width: 760) {
                SpokenPunctuationCard(settings: settings, uiLanguageCode: lang)
            }
            try shot("punctuation-card-\(lang)-expanded", width: 760) {
                SpokenPunctuationCard(settings: settings, uiLanguageCode: lang, expanded: true)
            }
        }
        settings.spokenPunctuation = false
        try shot("punctuation-card-off", width: 760) {
            SpokenPunctuationCard(settings: settings, uiLanguageCode: "en", expanded: true)
        }
        settings.spokenPunctuation = true
        let macros = MacroStore()
        try shot("commands-page-with-punctuation", width: 900, height: 1500, padding: 0) {
            CommandsView(settings: settings, macros: macros, commandRouter: CommandRouter(macros: macros),
                         hud: HUDController(), meetingStore: try! store())
        }
    }

    // MARK: Clarity (global state, card switches, details)

    private func withSettings(_ body: (AppSettings, MacroStore, MeetingStore) throws -> Void) throws {
        let settings = AppSettings()
        let macros = MacroStore()
        let saved = (settings.userFormatCommands, settings.formatSynonyms, settings.disabledFormatPresets,
                     settings.formatCommandsEnabled, settings.spokenLanguages, settings.localeIdentifier)
        let savedMacros = macros.macros
        defer {
            settings.userFormatCommands = saved.0
            settings.formatSynonyms = saved.1
            settings.disabledFormatPresets = saved.2
            settings.formatCommandsEnabled = saved.3
            settings.spokenLanguages = saved.4
            settings.localeIdentifier = saved.5
            for m in macros.macros { macros.delete(m) }
            for m in savedMacros { macros.upsert(m) }
            useUILanguage(nil)
        }
        for m in macros.macros { macros.delete(m) }
        settings.userFormatCommands = [UserCommand(name: "Bold", phrases: ["make it bold", "in bold"],
                                                   action: .wrap(before: "**", after: "**"))]
        settings.formatSynonyms = ["bulletList": ["tick marks"]]
        settings.disabledFormatPresets = [FormatPreset.verbatim.rawValue, FormatPreset.shorter.rawValue]
        try body(settings, macros, try store())
    }

    func testClarityPage() throws {
        try withSettings { settings, macros, meetings in
            for lang in ["en", "de"] {
                useUILanguage(lang)
                settings.spokenLanguages = lang == "de" ? ["de-DE", "en-US"] : ["en-US"]
                for on in [true, false] {
                    settings.formatCommandsEnabled = on
                    try shot("page-\(on ? "on" : "off")-\(lang)", width: 900, height: 2300, padding: 0) {
                        CommandsView(settings: settings, macros: macros, commandRouter: CommandRouter(macros: macros),
                                     hud: HUDController(), meetingStore: meetings)
                    }
                }
            }
        }
    }

    func testClarityCardsAndDetails() throws {
        try withSettings { settings, macros, _ in
            let pop = Color(nsColor: .windowBackgroundColor)
            for lang in ["en", "de"] {
                useUILanguage(lang)
                settings.formatCommandsEnabled = true
                settings.spokenLanguages = lang == "de" ? ["de-DE", "en-US"] : ["en-US"]
                let langs = settings.commandPhraseLanguages
                func card(_ preset: FormatPreset, on: Bool) -> some View {
                    FormatCommandCard(
                        illustration: .preset(preset), name: preset.displayName,
                        phrases: FormatPhraseCatalog.phrases(preset, languages: langs),
                        slower: preset.usesModel, isOn: .constant(on),
                        helpOpen: "", onOpen: {})
                }
                try shot("card-states-\(lang)", width: 680) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                        card(.bulletList, on: true)
                        card(.email, on: true)
                        card(.verbatim, on: false)
                    }
                }
                // Worst case: off + slower + many wordings, narrowest column.
                try shot("card-worst-\(lang)", width: 232) { card(.shorter, on: false).frame(width: 200) }
                try shot("card-detail-\(lang)", width: 392, background: pop, padding: 0) {
                    FormatCommandDetail(preset: .bulletList, settings: settings, macros: macros,
                                        uiLanguageCode: lang)
                }
                try shot("card-detail-off-\(lang)", width: 392, background: pop, padding: 0) {
                    FormatCommandDetail(preset: .verbatim, settings: settings, macros: macros,
                                        uiLanguageCode: lang)
                }
            }
            try shot("master-card", width: 760) { CommandsMasterCard(settings: settings) }
            settings.formatCommandsEnabled = false
            try shot("master-card-off", width: 760) { CommandsMasterCard(settings: settings) }
        }
    }

    // MARK: Pill

    private func pill(_ name: String, _ events: [PillFormatState.Event], text: String = "Ich brauche",
                      volatile: String = "", height: CGFloat = 110, volatileContinues: Bool = false,
                      appliedAtEnd: Bool = false) throws {
        let model = HUDModel()
        model.phase = .listening
        model.levels = (0..<HUDModel.barCount).map { i in CGFloat(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) }
        model.text = text
        model.volatileText = volatile
        model.volatileContinues = volatileContinues
        model.formatAppliedAtEnd = appliedAtEnd
        for e in events { model.formatState.handle(e) }
        for (label, bg) in [("bglight", Color(white: 0.93)), ("bgdark", Color(white: 0.16))] {
            try shot("pill-\(name)-\(label)", width: 440, height: height, background: bg, padding: 0) {
                HUDView(model: model, pillFrame: PillFrameBox())
            }
        }
    }

    func testPillStates() throws {
        useUILanguage("en")
        defer { useUILanguage(nil) }
        try pill("1-normal", [])
        try pill("2-key-held", [.keyDown])
        try pill("2b-checking", [.keyDown, .spanReleased])
        try pill("3-recognised", [.keyDown, .spanReleased, .resolved(.format("Bullet list"))])
        try pill("4-active-format", [.resolved(.format("Bullet list")), .flashExpired])
        try pill("5-not-recognised", [.keyDown, .spanReleased, .resolved(.notRecognised)])
        try pill("6-not-recognised-while-active",
                 [.resolved(.format("ALL CAPS")), .flashExpired, .keyDown, .spanReleased, .resolved(.notRecognised)])
        try pill("7-inserted", [.keyDown, .spanReleased, .resolved(.inserted("my address"))])
        try pill("8-ended", [.resolved(.format("Bullet list")), .flashExpired, .tapped])
        // The live text: a few lines grow the pill; more than it holds shows the newest.
        let long = "Yes, please. We also need to make a couple of changes that I will list now. First of all, "
            + "we need to make sure that the Commands option when pressing the control key or whatever key is "
            + "selected for the user is actually enabled by just pressing the key once and disabled by pressing "
            + "the key once again because currently there is kind of like a long press going on that I do not "
            + "seem to understand."
        try pill("9-live-two-lines", [], text: "We also need to make a couple of changes",
                 volatile: "that I will list now", height: 170)
        try pill("9-live-rolling", [], text: long, volatile: "The newest words are here", height: 170)
        try pill("9-live-rolling-format", [.resolved(.format("Bullet list")), .flashExpired], text: long,
                 volatile: "The newest words are here", height: 190)
        // After a command the live text is shown in the format (`FormatLivePreview`).
        let caps = FormatLivePreview.displayed(
            finalized: "Please note all caps this is very", volatile: "urgent indeed",
            commands: [.init(start: 2, end: 4, effect: .format(.preset(.allCaps)))], languageCode: "en")
        try pill("10-live-all-caps", [.resolved(.format("ALL CAPS")), .flashExpired], text: caps.firm,
                 volatile: caps.rest, height: 150, volatileContinues: true)
        let list = FormatLivePreview.displayed(
            finalized: "I need bullet list milk. Eggs.", volatile: "Fresh bread",
            commands: [.init(start: 2, end: 4, effect: .format(.preset(.bulletList)))], languageCode: "en")
        try pill("10-live-bullet-list", [.resolved(.format("Bullet list")), .flashExpired], text: list.firm,
                 volatile: list.rest, height: 190, volatileContinues: true)
        try pill("10-live-model-format", [.resolved(.format("Formal")), .flashExpired],
                 text: "Hello can you send it", height: 150, appliedAtEnd: true)
        useUILanguage("de")
        try pill("de-10-live-model-format", [.resolved(.format("Formell")), .flashExpired],
                 text: "Hallo kannst du es schicken", height: 150, appliedAtEnd: true)
        try pill("de-2-key-held", [.keyDown])
        try pill("de-4-active-format", [.resolved(.format("Aufzählung")), .flashExpired])
        try pill("de-5-not-recognised", [.keyDown, .spanReleased, .resolved(.notRecognised)])
        try pill("de-8-ended", [.resolved(.format("Aufzählung")), .flashExpired, .tapped])
    }
}
