import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in evidence for the Commands page and the pill's format states, in light and
/// dark. Skipped unless TALKIE_COMMANDS_SNAPSHOT_DIR is set. Uses only throwaway
/// stores (AppPaths' test sandbox).
@MainActor
final class CommandsSnapshotTests: XCTestCase {
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
        settings.formatSynonyms = ["bulletList": ["dot points", "Liste machen"]]
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
        try shot("commands-cards", width: 640) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 14)], spacing: 14) {
                Button {} label: {
                    CommandCardLabel(illustration: .preset(.bulletList), name: FormatPreset.bulletList.displayName,
                                     phrase: "bullet points", slower: false, isOff: false)
                }.buttonStyle(.talkieCard(selected: true))
                Button {} label: {
                    CommandCardLabel(illustration: .preset(.email), name: FormatPreset.email.displayName,
                                     phrase: "as an email", slower: true, isOff: false)
                }.buttonStyle(.talkieCard(selected: false))
                Button {} label: {
                    CommandCardLabel(illustration: .preset(.verbatim), name: FormatPreset.verbatim.displayName,
                                     phrase: "verbatim", slower: false, isOff: true)
                }.buttonStyle(.talkieCard(selected: false))
            }
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

    // MARK: Pill

    private func pill(_ name: String, _ events: [PillFormatState.Event]) throws {
        let model = HUDModel()
        model.phase = .listening
        model.levels = (0..<HUDModel.barCount).map { i in CGFloat(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) }
        model.text = "Ich brauche"
        for e in events { model.formatState.handle(e) }
        try shot("pill-\(name)", width: 440, height: 110, background: Color(white: 0.5), padding: 0) {
            HUDView(model: model, pillFrame: PillFrameBox())
        }
    }

    func testPillStates() throws {
        try pill("normal", [])
        try pill("key-held", [.keyDown])
        try pill("checking", [.keyDown, .spanReleased])
        try pill("recognised", [.keyDown, .spanReleased, .resolved(.format("Bullet list"))])
        try pill("format-active", [.resolved(.format("Bullet list")), .flashExpired])
        try pill("not-recognised", [.keyDown, .spanReleased, .resolved(.notRecognised)])
        try pill("not-recognised-while-active",
                 [.resolved(.format("ALL CAPS")), .flashExpired, .keyDown, .spanReleased, .resolved(.notRecognised)])
        try pill("inserted", [.keyDown, .spanReleased, .resolved(.inserted("my address"))])
        try pill("ended", [.resolved(.format("Bullet list")), .flashExpired, .tapped])
    }
}
