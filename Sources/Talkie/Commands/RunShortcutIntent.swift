import Foundation

/// Runs a macOS **Shortcut** by name from a spoken command ("run shortcut Ship It")
/// and from the post-save meeting hook — the one place Talkie hands a side-effect
/// off to the user's own automation instead of inserting text.
///
/// Why `/usr/bin/shortcuts` and not a framework: the Shortcuts run API is a plain
/// local command-line tool that talks to the Shortcuts app over on-device IPC. It
/// needs no new entitlement (the app is not sandboxed) and — critically for the
/// product thesis — nothing here is a network symbol, so `check-no-network.sh` stays
/// green (`Process`/`shortcuts` are local process execution, not sockets). See
/// `_CORES_STANDARDS.md` §1.
///
/// Safety posture (destructive-Shortcut avoidance is the whole design constraint):
/// - **Exact-name match only**, case-insensitive and whitespace-normalized. There is
///   deliberately **no fuzzy matching** in v1 — misfiring a user's "Delete Everything"
///   Shortcut because it sounded like what they said is the failure mode we refuse.
/// - A spoken run resolves the name against the live `list()` and only fires on a
///   unique exact match; anything else returns honest preview text and types nothing.
enum ShortcutsRunner {
    /// Where the CLI lives. A constant so the intent, the meeting hook, and tests all
    /// agree, and so this file is the single place that path is named.
    static let executablePath = "/usr/bin/shortcuts"

    /// How long we wait for `shortcuts list` / `shortcuts run` before giving up. A
    /// Shortcut can legitimately take a while (it may open apps), but the run is
    /// fire-and-forget from Talkie's side — we only need to know it launched, and we
    /// must never wedge a background task forever if the tool hangs.
    static let timeout: TimeInterval = 20

    /// The installed Shortcuts, one name per line, as `shortcuts list` prints them.
    /// Empty on any failure (tool missing, non-zero exit, timeout) — callers treat an
    /// empty list as "no shortcut matched", never as an error to surface loudly.
    static func list() async -> [String] {
        guard let output = await runProcess(arguments: ["list"]) else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The result of asking to run a shortcut: launched, or a reason we didn't.
    enum RunOutcome: Sendable, Equatable {
        case ran(name: String)
        /// No installed shortcut matched `requested` (exact, normalized).
        case noMatch(requested: String)
        /// The `shortcuts run` invocation itself failed (non-zero exit / timeout).
        case failed(name: String)
    }

    /// Resolve `name` against the installed shortcuts (exact, normalized) and run the
    /// unique match, optionally feeding it a file at `inputPath` via `-i`. Returns an
    /// honest outcome; never throws. `inputPath` is the note's path for the post-save
    /// hook, and `nil` for the spoken command.
    static func run(name: String, inputPath: String?) async -> RunOutcome {
        let installed = await list()
        guard let match = resolve(name, in: installed) else {
            return .noMatch(requested: name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var arguments = ["run", match]
        if let inputPath, !inputPath.isEmpty {
            arguments.append(contentsOf: ["-i", inputPath])
        }
        // `shortcuts run` prints nothing on success and exits 0; a nil return means a
        // non-zero exit or timeout. We can't do better than "it launched" — the
        // Shortcut owns everything after that.
        if await runProcess(arguments: arguments) != nil {
            return .ran(name: match)
        }
        return .failed(name: match)
    }

    /// The exact installed name that matches `requested` case-insensitively and
    /// whitespace-normalized, or nil if there is not exactly one. Pure + testable: the
    /// whole match policy (exact only, ambiguity → no match) lives here, so a spoken
    /// run and the tests exercise identical logic.
    static func resolve(_ requested: String, in installed: [String]) -> String? {
        let needle = normalize(requested)
        guard !needle.isEmpty else { return nil }
        let matches = installed.filter { normalize($0) == needle }
        // Exactly one exact match fires; zero (miss) or many (ambiguous) both refuse,
        // because guessing which of two same-named Shortcuts to run is unsafe.
        return matches.count == 1 ? matches[0] : nil
    }

    /// Lowercase + collapse internal whitespace so "Ship  It" spoken as "ship it"
    /// still matches, without any fuzzier normalization that could collapse two
    /// genuinely different Shortcut names together.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Launch `/usr/bin/shortcuts` with `arguments` on a detached utility task, wait up
    /// to `timeout`, and return trimmed stdout on a clean (exit 0) run — or nil on a
    /// missing tool, non-zero exit, or timeout. All local process I/O; no network.
    private static func runProcess(arguments: [String]) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()   // swallow tool chatter; we only care about exit + stdout
            do {
                try process.run()
            } catch {
                return nil                    // tool missing / not launchable
            }
            // Timebox: if the tool hangs, terminate it and treat as failure rather than
            // block this background task indefinitely.
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

/// Parses a spoken "run [the] shortcut <name>" command into the shortcut name to run.
/// Deterministic, offline, side-effect free — mirrors `SpellingParser`/`CrossSurfaceParser`
/// so the router can try it and fall through to normal dictation when it doesn't match.
///
/// The trigger is a **literal carrier phrase**: it must start with "run" and the word
/// "shortcut" must immediately follow (optionally with "the"/"a" between). That keeps
/// ordinary dictation like "run the tests then commit" — which starts with "run" but
/// never says "shortcut" — out of this path entirely; it falls through and types
/// literally. The `<name>` is everything after the carrier, original-cased for display
/// and for the exact match.
enum RunShortcutParser {
    /// The shortcut name a spoken command asks to run, or nil if the phrase isn't a
    /// run-shortcut command. Pure; the actual "does a shortcut by this name exist"
    /// check is `ShortcutsRunner.resolve` against the live list, not here.
    static func parse(_ spoken: String) -> String? {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2 else { return nil }        // need at least "shortcut <name>" worth
        guard tokens[0].lowercased() == "run" else { return nil }

        // Consume an optional "the"/"a"/"an" article, then require the literal word
        // "shortcut". Anything else after "run" (e.g. "run the tests") is not a command.
        var index = 1
        if ["the", "a", "an"].contains(tokens[index].lowercased()) {
            index += 1
            guard index < tokens.count else { return nil }
        }
        guard tokens[index].lowercased() == "shortcut" else { return nil }
        index += 1

        // Everything after "shortcut" is the name. Recover its original casing from the
        // source string so the display + exact match use what the user actually said.
        let nameTokens = tokens[index...]
        guard !nameTokens.isEmpty else { return nil }
        let name = nameTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// `CommandIntent` for "run shortcut <name>" (G8). It is **not** a text transform:
/// it resolves the name against the installed Shortcuts and runs the unique match,
/// inserting nothing. On success it returns `CommandResult(replacement: "", preview: false)`
/// — an explicit "ran, insert nothing" signal the AppDelegate command branch honors
/// with a confirmation toast instead of injecting empty text. On no match it returns
/// honest **preview** text ("No shortcut named 'X'") so the phrase is shown for review
/// and never typed into the document.
///
/// `needsSelection == false` (it acts on the Shortcuts system, not the current
/// selection) and `isMutating == false` (it inserts nothing to transform).
struct RunShortcutIntent: CommandIntent {
    let id = "run-shortcut"
    let needsSelection = false
    let isMutating = false

    func run(_ ctx: CommandContext) async -> CommandResult? {
        guard let requested = RunShortcutParser.parse(ctx.spokenCommand) else { return nil }
        switch await ShortcutsRunner.run(name: requested, inputPath: nil) {
        case .ran:
            // Side-effect done, nothing to insert. The empty replacement is the contract
            // with the command branch: it shows a "Ran shortcut …" toast and hides.
            return CommandResult(replacement: "", preview: false, undoToken: nil)
        case .noMatch(let name):
            // Honest, previewed, never typed: tell the user there's no such shortcut.
            return CommandResult(replacement: String(format: "No shortcut named “%@”".loc, name),
                                 preview: true, undoToken: ctx.selection)
        case .failed(let name):
            return CommandResult(replacement: String(format: "Couldn't run the shortcut “%@”".loc, name),
                                 preview: true, undoToken: ctx.selection)
        }
    }
}
