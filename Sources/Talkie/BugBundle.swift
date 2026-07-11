import Foundation

/// A one-click, **redacted** diagnostic bundle for bug reports (K8).
///
/// The whole feature is privacy optics: a good bug report needs version,
/// environment, a settings snapshot, permission states, and a tail of the debug
/// log — but Talkie's debug log (`~/Library/Application Support/Talkie/debug.log`,
/// written by `talkieDebugLog`, opt-in via `TALKIE_DEBUG_LOG`) records LEARNED
/// corrections that embed the user's *actual*
/// dictated words (e.g. `learn: ✓ LEARNED 'higgs field' → 'Higgsfield'`, see
/// `LearningEngine.swift:88,107`). Shipping that raw would leak private speech.
///
/// So the bundle is built in three pure, testable pieces:
///   1. `redact(_:)` drops or masks any log line that could carry learned or
///      dictated content — it errs hard toward over-redaction (§"redaction").
///   2. `build(environment:logTail:)` assembles the human-readable report from an
///      explicit, WHITELISTED `Environment` snapshot plus the already-redacted
///      log tail. It is a pure function of its inputs — no `Bundle.main`, no
///      `ProcessInfo`, no disk — so tests can pin every byte.
///   3. `gather(...)` (the only impure entry point) reads the real environment
///      and log file on the main actor and calls `build`.
///
/// The whitelist is the safety contract: `Environment` carries only SCALAR
/// settings (activation key, cleanup summary, feature toggles) and NEVER the
/// user's name, parrot name, dictionary contents, history, or the meeting
/// allowlist's user-added entries. Adding a field here is a deliberate,
/// reviewed act — the default is "not in the bundle".
enum BugBundle {

    // MARK: - The whitelisted input snapshot

    /// Everything the bundle is allowed to know, gathered by the caller so
    /// `build` stays pure. Only scalars and small enumerations — anything that
    /// could contain free-form user text (names, dictionary words, transcript
    /// history, custom allowlist entries) is deliberately absent and must stay so.
    struct Environment: Sendable, Equatable {
        // App identity
        var appVersion: String          // CFBundleShortVersionString, e.g. "0.1.0"
        var appBuild: String            // CFBundleVersion, e.g. "1"

        // Machine
        var osVersion: String           // e.g. "26.0.0"
        var architecture: String        // "arm64" / "x86_64"

        // Language
        var localeIdentifier: String    // primary dictation locale, e.g. "en-US"
        var spokenLanguages: [String]   // catalog locale ids the user selected

        // Permission grant states (booleans only — no identifiers)
        var accessibilityGranted: Bool
        var inputMonitoringGranted: Bool
        var microphoneGranted: Bool

        // Whitelisted scalar settings (NO free-form user text)
        var activationKey: String       // ActivationKey.rawValue
        var cleanupSummary: String      // derived, non-identifying (see gather)
        var historyRetentionDays: Int
        var autoDetectMeetings: Bool
        var contextAwareness: Bool
        var vibeCoding: Bool
        var learnFromEdits: Bool
        var optimisticInsertion: Bool
        var playSounds: Bool
        var launchAtLogin: Bool
        var showBirdBuddy: Bool
    }

    // MARK: - Pure builder

    /// Assemble the full, human-readable bundle text from a whitelisted snapshot
    /// and an already-redacted log tail. Pure and deterministic — same inputs,
    /// same bytes — so the preview the user reads IS exactly what gets copied.
    ///
    /// `logTail` is expected to be the caller's raw last-N log lines; we run it
    /// through `redact` here too, so `build` is safe even if a caller forgets —
    /// redaction is idempotent, so double-redacting is harmless.
    static func build(environment env: Environment, logTail: [String]) -> String {
        var out = ""
        func section(_ title: String) { out += "## \(title)\n" }
        func line(_ key: String, _ value: String) { out += "- \(key): \(value)\n" }

        out += "# Talkie diagnostic bundle\n"
        out += "_Generated on this Mac. Everything below stays on your Mac until you paste it somewhere._\n\n"

        section("App")
        line("Version", env.appVersion)
        line("Build", env.appBuild)
        out += "\n"

        section("Environment")
        line("macOS", env.osVersion)
        line("Architecture", env.architecture)
        line("Primary language", env.localeIdentifier)
        line("Spoken languages", env.spokenLanguages.isEmpty
              ? "—" : env.spokenLanguages.joined(separator: ", "))
        out += "\n"

        section("Permissions")
        line("Accessibility", grant(env.accessibilityGranted))
        line("Input Monitoring", grant(env.inputMonitoringGranted))
        line("Microphone", grant(env.microphoneGranted))
        out += "\n"

        section("Settings")
        line("Activation key", env.activationKey)
        line("Cleanup", env.cleanupSummary)
        line("History retention", env.historyRetentionDays == 0
              ? "kept forever" : "\(env.historyRetentionDays) days")
        line("Auto-detect meetings", onOff(env.autoDetectMeetings))
        line("Context awareness", onOff(env.contextAwareness))
        line("Vibe coding", onOff(env.vibeCoding))
        line("Learn from edits", onOff(env.learnFromEdits))
        line("Optimistic insertion", onOff(env.optimisticInsertion))
        line("Play sounds", onOff(env.playSounds))
        line("Launch at login", onOff(env.launchAtLogin))
        line("Bird Buddy", onOff(env.showBirdBuddy))
        out += "\n"

        // The debug-log tail, redacted. We redact here (not just at the call
        // site) so this function alone guarantees no learned/dictated content —
        // the tests exercise exactly this path.
        section("Debug log (redacted tail)")
        let redacted = redact(logTail)
        if redacted.isEmpty {
            out += "_No debug log on this Mac._\n"
        } else {
            out += "```\n"
            out += redacted.joined(separator: "\n")
            out += "\n```\n"
        }

        return out
    }

    private static func grant(_ ok: Bool) -> String { ok ? "granted" : "not granted" }
    private static func onOff(_ on: Bool) -> String { on ? "on" : "off" }

    // MARK: - Redaction (pure)

    /// Filter a list of debug-log lines down to ones that are safe to share,
    /// dropping any that could carry the user's learned or dictated words.
    ///
    /// The threat is `LearningEngine`'s log lines. Its "learned" records embed the
    /// user's real speech and real correction verbatim:
    ///
    ///     learn: ✓ LEARNED 'higgs field' → 'Higgsfield'
    ///     learn: ✓ LEARNED on send 'cloud MD' → 'claude.md'
    ///
    /// and its baseline/watch lines quote app names and can echo field text. We do
    /// NOT try to parse-and-mask the private substring out of an otherwise-useful
    /// line — that's fragile and one missed format leaks speech. Instead we DROP
    /// any line that shows a redaction signal at all, and keep only lines that are
    /// plainly diagnostic (timings, counts, plain-prose status with no quoted
    /// payload). Over-redaction is the correct failure mode here: a bug reporter
    /// can always add detail by hand; they can't un-leak a sentence they said.
    ///
    /// Signals that drop a line (any one is enough):
    ///   • the `LEARNED` marker (case-insensitive) — the correction record itself;
    ///   • the `→` / `->` correction arrow — the from→to shape;
    ///   • any straight or smart QUOTE pair wrapping content — 'x', "x", ‘x’, “x”,
    ///     『x』 — the containers LearningEngine uses to hold user words;
    ///   • the `learn:` prefix — the whole learning subsystem's lines are treated
    ///     as untrusted, because several of them interpolate field/app content.
    ///
    /// Pure and idempotent: redacting an already-redacted list is a no-op.
    static func redact(_ lines: [String]) -> [String] {
        lines.filter { isSafe($0) }
    }

    /// Whether a single line is safe to include (carries no learned/dictated
    /// content signal). See `redact` for the rationale behind each rule.
    static func isSafe(_ line: String) -> Bool {
        let lower = line.lowercased()

        // The learning subsystem's lines are untrusted wholesale — many embed the
        // focused app name or echo field text, and the "learned" ones carry the
        // user's actual words. Drop anything the learner emitted.
        if lower.contains("learn:") { return false }
        if lower.contains("learned") { return false }

        // The from→to correction shape, wherever it appears.
        if line.contains("→") || line.contains("->") { return false }

        // Any quote pair that could be wrapping user content. We check for the
        // presence of quote characters at all (not balanced pairs) — a lone quote
        // is cheap to drop and closes the "half-logged line" hole.
        for q in Self.quoteMarkers where line.contains(q) { return false }

        return true
    }

    /// Quote characters Talkie's logs (and macOS text) use to wrap words. Any
    /// occurrence makes a line suspect. Includes straight quotes, curly quotes,
    /// and the CJK corner brackets so localized/echoed text can't slip a quoted
    /// payload past the filter.
    private static let quoteMarkers: [String] = [
        "'", "\"", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}",
        "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}",
    ]

    // MARK: - Impure gather (the only side-effecting entry point)

    /// Path of the best-effort debug log `talkieDebugLog` writes to. Kept in one
    /// place so this and `talkieDebugLog` can't drift — must match
    /// `TalkieDebugLogSink.fileURL` in TranscriptionEngine.swift.
    static let debugLogPath = AppPaths.supportDirectory().appendingPathComponent("debug.log").path

    /// How many trailing log lines to include. Enough to show recent behavior,
    /// small enough to stay reviewable in the preview sheet.
    static let logTailLineCount = 80

    /// Read the real environment + log file and produce the bundle text. The only
    /// impure entry point; everything it depends on is injected or read here so
    /// `build`/`redact` stay pure and fully unit-tested. `@MainActor` because it
    /// touches `PermissionsModel`/`AppSettings` (both main-actor state).
    @MainActor
    static func gather(settings: AppSettings, permissions: PermissionsModel) -> String {
        permissions.refresh()

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "—"
        let buildNumber = (info?["CFBundleVersion"] as? String) ?? "—"

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let env = Environment(
            appVersion: version,
            appBuild: buildNumber,
            osVersion: osString,
            architecture: machineArchitecture(),
            localeIdentifier: settings.localeIdentifier,
            spokenLanguages: settings.spokenLanguages,
            accessibilityGranted: permissions.accessibility,
            inputMonitoringGranted: permissions.inputMonitoring,
            microphoneGranted: permissions.microphone,
            activationKey: settings.activationKey.rawValue,
            cleanupSummary: cleanupSummary(settings.appCleanupStyles),
            historyRetentionDays: settings.historyRetentionDays,
            autoDetectMeetings: settings.autoDetectMeetings,
            contextAwareness: settings.contextAwareness,
            vibeCoding: settings.vibeCoding,
            learnFromEdits: settings.learnFromEdits,
            optimisticInsertion: settings.optimisticInsertion,
            playSounds: settings.playSounds,
            launchAtLogin: settings.launchAtLogin,
            showBirdBuddy: settings.showBirdBuddy
        )

        return build(environment: env, logTail: readLogTail())
    }

    /// A non-identifying one-line summary of the per-app cleanup styles. We report
    /// the DEFAULT style and how many apps have a custom override — never the app
    /// bundle ids the user configured (those are personal), and never the raw dict.
    static func cleanupSummary(_ styles: [String: String]) -> String {
        let overrides = styles.count
        if overrides == 0 { return "default only" }
        return "default + \(overrides) app override\(overrides == 1 ? "" : "s")"
    }

    /// Best-effort CPU architecture string ("arm64" / "x86_64"). Read from
    /// `utsname`; falls back to "unknown".
    private static func machineArchitecture() -> String {
        var sys = utsname()
        guard uname(&sys) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    /// The last `logTailLineCount` lines of the debug log, or an empty array if the
    /// file is missing/unreadable ("no debug log on this Mac"). Read here, redacted
    /// downstream in `build`.
    private static func readLogTail() -> [String] {
        guard let text = try? String(contentsOfFile: debugLogPath, encoding: .utf8)
        else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(lines.suffix(logTailLineCount))
    }
}
