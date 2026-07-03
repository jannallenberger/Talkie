import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// `DoctorReport` — the whole "verify it yourself" story rendered as one pasteable
/// markdown receipt (feature I6). The Privacy pane proves Talkie's zero-network
/// claim in pieces you can watch; this collapses all of them — entitlements, live
/// sockets, FileVault, permission triage, and where your data lives — into a single
/// artifact you can paste into a GitHub issue or a chat.
///
/// Two entry points share one generator:
///   • `/Applications/Talkie.app/Contents/MacOS/Talkie doctor` (the CLI seam in
///     `main.swift`, `includeTCC: false`) — prints and exits before any UI.
///   • the "Copy diagnostic report" button in the Privacy pane (`includeTCC: true`)
///     — copies the same report with real, in-app TCC states.
///
/// Every value is measured on THIS machine at call time — nothing is hardcoded.
/// When a value can't be read (an ad-hoc build has no cdhash; `fdesetup` errors),
/// the report says so plainly instead of faking one. Honesty invariant
/// (`_UNIFICATION.md` §4.3): a truthful "unknown" beats a comforting lie.
///
/// It inspects; it never connects. FileVault status comes from a *local* exec of
/// `/usr/bin/fdesetup` (a `Process`, not a network call); the socket count comes
/// from `SocketAudit`'s own-pid libproc introspection. No network symbol lives in
/// this file, so it doesn't touch the zero-network wall.
enum DoctorReport {

    /// The on-disk locations the data section inspects. Mirrors `AppPaths` but is
    /// injectable so `DoctorReportTests` can point it at a fixture temp dir instead
    /// of the developer's real support directory. Defaults to the real paths.
    struct Paths: Sendable {
        /// ~/Library/Application Support/Talkie — settings, history, the JSON stores.
        let support: URL
        /// ~/Talkie Meetings — recordings and transcripts in plain folders.
        let meetings: URL

        /// The real, shipped locations.
        static var live: Paths {
            Paths(support: AppPaths.supportDirectory(), meetings: AppPaths.meetingsDirectory())
        }
    }

    /// Generate the full markdown report.
    ///
    /// - Parameters:
    ///   - includeTCC: whether to report live permission states. The in-app button
    ///     passes `true`; the CLI passes `false` because TCC answers to a
    ///     terminal-spawned process are attributed to the *terminal*, not Talkie,
    ///     so a CLI "microphone: denied" would be a misleading lie. With `false`
    ///     the Permissions section prints an honest pointer to the in-app pane.
    ///   - paths: where to look for on-disk data (defaults to the live locations).
    ///   - retentionDays: the history-retention setting in days (`0` = forever).
    ///     Defaults to reading the same `UserDefaults` key `AppSettings` registers
    ///     and `HistoryStore` reads — inlined here (rather than calling the
    ///     `@MainActor` `HistoryStore.storedRetentionDays()`) so the default is
    ///     nonisolated and the CLI seam can call `generate` before any actor exists.
    ///     Injectable for tests.
    static func generate(includeTCC: Bool,
                         paths: Paths = .live,
                         retentionDays: Int = UserDefaults.standard.integer(forKey: "historyRetentionDays")) -> String {
        var out: [String] = []
        out.append("# Talkie — privacy self-check")
        out.append("")
        out.append("Everything below is read from this Mac right now. Nothing here is typed in, and nothing here is sent anywhere — this report is generated entirely on-device.")
        out.append("")

        out.append(contentsOf: buildSection())
        out.append(contentsOf: entitlementsSection())
        out.append(contentsOf: socketsSection())                                                // talkie:no-network(self-inspection)
        out.append(contentsOf: fileVaultSection())
        out.append(contentsOf: permissionsSection(includeTCC: includeTCC))
        out.append(contentsOf: dataSection(paths: paths, retentionDays: retentionDays))
        out.append(contentsOf: verifySection())

        return out.joined(separator: "\n")
    }

    // MARK: - 1. Build

    private static func buildSection() -> [String] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let cdhash = EntitlementInspector.cdhashHex

        var lines = ["## Build", ""]
        lines.append("- Version: **\(version ?? "unknown")**" + (build.map { " (build \($0))" } ?? ""))
        if let cdhash {
            lines.append("- Code signature (cdhash): `\(cdhash)`")
            lines.append("- Signing status: signed — the entitlements below are read from this exact signature.")
        } else {
            lines.append("- Code signature (cdhash): _none — this is an ad-hoc or un-signed build, so there's no stable signature hash to read._")
            lines.append("- Signing status: unsigned / ad-hoc.")
        }
        lines.append("")
        return lines
    }

    // MARK: - 2. Entitlements

    private static func entitlementsSection() -> [String] {
        let caps = EntitlementInspector.capabilities()

        var lines = ["## Entitlements (read from the signature)", ""]
        if caps.isEmpty {
            lines.append("- _No entitlements detected — typical of an un-signed debug build. The shipped, notarized build requests exactly one: microphone access._")
        } else {
            for cap in caps {
                let mark = cap.isNetwork ? "✗" : "✓"
                lines.append("- \(mark) \(cap.label) — `\(cap.key)`")
            }
        }
        if EntitlementInspector.hasNetworkEntitlement {
            lines.append("")
            lines.append("**✗ A network entitlement is present on a build labelled \"Talkie\". That is a bug — the shipping build has none.**")
        } else {
            lines.append("")
            lines.append("✓ No `com.apple.security.network.client` — Talkie cannot be granted network access.")
        }
        lines.append("")
        return lines
    }

    // MARK: - 3. Live sockets

    private static func socketsSection() -> [String] {                                          // talkie:no-network(self-inspection)
        let snap = SocketAudit.snapshot()                                                       // talkie:no-network(self-inspection)

        var lines = ["## Live sockets", ""]                                                     // talkie:no-network(self-inspection)
        if !snap.isAvailable {
            lines.append("- _Couldn't read this process's sockets on this build._")             // talkie:no-network(self-inspection)
        } else if snap.internetSockets == 0 {                                                   // talkie:no-network(self-inspection)
            lines.append("- ✓ Open internet sockets right now: **0**")                          // talkie:no-network(self-inspection)
            lines.append("- Counted live from this app's own file descriptors. Speech-model downloads run in Apple's system services, not inside Talkie, so they never appear here.")
        } else {
            lines.append("- ✗ Open internet sockets right now: **\(snap.internetSockets)** — that's unexpected for the on-device core.") // talkie:no-network(self-inspection)
        }
        lines.append("")
        return lines
    }

    // MARK: - 4. FileVault

    /// Parse `/usr/bin/fdesetup status`. This is a LOCAL process exec — Talkie asks
    /// the OS whether the disk is encrypted; no network call, no `Socket`. If the
    /// tool is missing, errors, or prints something unrecognised, we report an
    /// honest "unknown" rather than guessing on/off.
    private static func fileVaultSection() -> [String] {
        var lines = ["## FileVault", ""]
        switch fileVaultStatus() {
        case .on:
            lines.append("- ✓ FileVault is **On** — the disk holding your data is encrypted at rest.")
        case .off:
            lines.append("- FileVault is **Off** — your data lives in the folders below unencrypted. Talkie still never sends it anywhere; disk encryption is a separate macOS setting you control in System Settings → Privacy & Security.")
        case .unknown:
            lines.append("- _FileVault status: unknown (couldn't read `fdesetup status` on this machine)._")
        }
        lines.append("")
        return lines
    }

    private enum FileVaultState { case on, off, unknown }

    private static func fileVaultStatus() -> FileVaultState {
        let tool = "/usr/bin/fdesetup"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return .unknown }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unknown
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        // `fdesetup status` prints "FileVault is On." / "FileVault is Off." (plus,
        // mid-conversion, an "…Encryption in progress" line — we treat that as On,
        // since encryption is active). Match on the stable substrings.
        if output.contains("filevault is on") || output.contains("encryption in progress") {
            return .on
        } else if output.contains("filevault is off") {
            return .off
        }
        return .unknown
    }

    // MARK: - 5. Permissions

    private static func permissionsSection(includeTCC: Bool) -> [String] {
        var lines = ["## Permissions", ""]
        guard includeTCC else {
            // TCC answers from a terminal-spawned invocation are attributed to the
            // terminal, not Talkie — so a CLI "denied" would be a lie about the
            // app. Point at the live in-app readout instead of printing a wrong one.
            lines.append("- _Permission state is reported live inside the app (Settings → Privacy); CLI answers may reflect your terminal, not Talkie, so they're omitted here._")
            lines.append("")
            return lines
        }

        // Read the same three TCC states the app uses (mirrors PermissionsModel).
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let inputMonitoring = CGPreflightListenEventAccess()
        let accessibility = AXIsProcessTrusted()

        lines.append(permissionLine(name: "Microphone", granted: mic))
        lines.append(permissionLine(name: "Input Monitoring", granted: inputMonitoring))
        lines.append(permissionLine(name: "Accessibility", granted: accessibility))
        if !(mic && inputMonitoring && accessibility) {
            lines.append("")
            lines.append("If you just granted one of these, quit Talkie and reopen it — macOS only hands a permission to the app on its next launch, so a freshly granted permission won't take effect until you restart the app.")
        }
        lines.append("")
        return lines
    }

    private static func permissionLine(name: String, granted: Bool) -> String {
        granted ? "- ✓ \(name): granted" : "- ✗ \(name): not granted"
    }

    // MARK: - 6. Your data

    /// Walk the known on-disk stores under the support dir plus the meetings dir,
    /// reporting each one's existence, size, and — where it's a JSON store we can
    /// decode — a meaningful count (dictations, dictionary rules, graph entities,
    /// meetings). Decoded directly from disk (not from the live stores) so the CLI,
    /// which has no in-memory stores, reports the same numbers as the app.
    private static func dataSection(paths: Paths, retentionDays: Int) -> [String] {
        var lines = ["## Your data", ""]
        lines.append("Everything Talkie keeps lives in two places you own — plain files on this Mac, nothing in a cloud:")
        lines.append("")

        // The support directory and its known JSON stores.
        lines.append("**`\(tildeAbbreviated(paths.support.path))`** — settings and history:")
        lines.append("")

        // history.json → dictation count
        lines.append(fileLine(paths.support.appendingPathComponent("history.json"),
                              detail: countDetail(decode: [DictationEntry].self,
                                                  at: paths.support.appendingPathComponent("history.json"),
                                                  singular: "dictation", plural: "dictations")))
        // dictionary.json → replacement rules + vocabulary terms
        lines.append(fileLine(paths.support.appendingPathComponent("dictionary.json"),
                              detail: dictionaryDetail(at: paths.support.appendingPathComponent("dictionary.json"))))
        // entities.json → context-graph entity count
        lines.append(fileLine(paths.support.appendingPathComponent("entities.json"),
                              detail: countDetail(decode: [Entity].self,
                                                  at: paths.support.appendingPathComponent("entities.json"),
                                                  singular: "graph entity", plural: "graph entities")))
        // meetings.json → meeting index count
        lines.append(fileLine(paths.support.appendingPathComponent("meetings.json"),
                              detail: countDetail(decode: [Meeting].self,
                                                  at: paths.support.appendingPathComponent("meetings.json"),
                                                  singular: "meeting", plural: "meetings")))

        // Other known stores, reported by existence + size only (no meaningful
        // "count" to decode, or the shape isn't load-bearing for the receipt).
        for name in ["macros.json", "app_profiles.json", "stats.json", "activity.json",
                     "appusage.json", "context_summary.json", "project_index.json",
                     "export_prefs.json"] {
            lines.append(fileLine(paths.support.appendingPathComponent(name), detail: nil))
        }
        // niche vocabulary store (nested)
        lines.append(fileLine(paths.support.appendingPathComponent("niche/vocab.json"), detail: nil))

        lines.append("")
        lines.append("**`\(tildeAbbreviated(paths.meetings.path))`** — your recordings and transcripts, in plain folders you own:")
        lines.append("")
        lines.append(directoryLine(paths.meetings))

        // Retention — the one privacy knob that shapes how much history is kept.
        lines.append("")
        let retention = HistoryRetention.from(days: retentionDays)
        if retention == .forever {
            lines.append("History retention: **kept forever** (your choice — Settings → Privacy → Your history). A hard cap of 2,000 most-recent dictations still applies regardless of age.")
        } else {
            lines.append("History retention: **\(retention.displayName)** — older dictations are deleted from this Mac after that. (Settings → Privacy → Your history.)")
        }
        lines.append("")
        return lines
    }

    /// Decode a JSON array store and describe its element count, or an honest
    /// fallback when the file is missing or unreadable. Takes explicit singular /
    /// plural nouns so irregular plurals ("entity" → "entities") read correctly
    /// rather than a naive "+ s".
    private static func countDetail<T: Decodable>(decode type: [T].Type, at url: URL,
                                                  singular: String, plural: String) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([T].self, from: data) else {
            return "present, but couldn't be decoded"
        }
        let n = items.count
        return "\(n) \(n == 1 ? singular : plural)"
    }

    /// The dictionary store has a `{replacements, vocabulary}` payload, so it gets a
    /// two-count detail rather than the generic array decoder.
    private static func dictionaryDetail(at url: URL) -> String? {
        struct Payload: Decodable { var replacements: [Replacement]; var vocabulary: [String] }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return "present, but couldn't be decoded"
        }
        let r = payload.replacements.count
        let v = payload.vocabulary.count
        return "\(r) rule\(r == 1 ? "" : "s"), \(v) vocabulary term\(v == 1 ? "" : "s")"
    }

    /// One markdown bullet for a file: name, whether it exists, its size, and an
    /// optional decoded detail (e.g. entry count).
    private static func fileLine(_ url: URL, detail: String?) -> String {
        let fm = FileManager.default
        let name = url.lastPathComponent
        guard fm.fileExists(atPath: url.path) else {
            return "- `\(name)` — not created yet"
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let sizeText = size.map { byteText($0) } ?? "unknown size"
        if let detail {
            return "- `\(name)` — \(sizeText), \(detail)"
        }
        return "- `\(name)` — \(sizeText)"
    }

    /// One markdown bullet for a directory: whether it exists and how many entries
    /// it holds (top-level, e.g. per-meeting folders).
    private static func directoryLine(_ url: URL) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return "- _(no meetings recorded yet — the folder is created on your first recording)_"
        }
        let entries = (try? fm.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") } ?? []
        let n = entries.count
        return "- \(n) item\(n == 1 ? "" : "s") in the folder"
    }

    // MARK: - 7. Verify further

    private static func verifySection() -> [String] {
        var lines = ["## Verify further", ""]
        lines.append("Don't take this report's word for it — reproduce every line yourself:")
        lines.append("")
        lines.append("1. **Read the permissions** — `codesign -d --entitlements - /Applications/Talkie.app`")
        lines.append("2. **Grep the source** — `./scripts/check-no-network.sh`")
        lines.append("3. **Watch the wire** — `nettop -p $(pgrep Talkie)`")
        lines.append("")
        lines.append("`check-no-network.sh` is the exact grep that backs the \"zero networking code\" claim; CI runs it on every push, so the claim can't silently rot.")
        lines.append("")
        return lines
    }

    // MARK: - Formatting helpers

    /// Abbreviate a home-relative path back to `~/…` for a shorter, friendlier line.
    /// Falls back to the raw path when it isn't under home (e.g. a test temp dir).
    private static func tildeAbbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Human-readable byte size (B / KB / MB), enough precision for a receipt.
    private static func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
