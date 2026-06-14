import AppKit
import ApplicationServices

/// The app you're dictating *into*, captured the instant a session begins.
/// Sendable so it can cross into the post-processing Task.
struct TargetApp: Sendable, Equatable {
    var bundleID: String?
    var name: String
    var category: AppCategory

    static let unknown = TargetApp(bundleID: nil, name: "Unknown", category: .other)
}

/// What `ContextCapture` learns from the target app at the start of a dictation:
/// who you're talking to, and a short list of names/identifiers worth spelling
/// correctly (window title, the text around your cursor).
struct CapturedContext: Sendable {
    var target: TargetApp
    /// Proper nouns + code identifiers to feed the recognizer as contextual
    /// strings, so it spells *this app's* names right.
    var phrases: [String]
    /// The raw window title (used for project/file matching downstream).
    var windowTitle: String?

    static let empty = CapturedContext(target: .unknown, phrases: [], windowTitle: nil)
}

/// Reads the frontmost app and (best-effort, via Accessibility) its focused
/// window title and the text around the cursor — turning that into a small,
/// *relevant* bias set. This is what lets Talkie spell the name of the person
/// you're messaging, or the symbol you're editing, correctly the first time.
///
/// Entirely local and read-only. Falls back gracefully when AX is unavailable
/// (sandboxed/Electron apps) — it just contributes fewer phrases.
@MainActor
enum ContextCapture {
    /// Capture the current target app + context. Cheap; called once per session.
    /// `minePhrases` gates the (slightly costlier) Accessibility reads — when the
    /// context-awareness setting is off we still capture the target app for the
    /// usage dashboard, but skip mining names to bias the recognizer.
    static func capture(selfBundleID: String, minePhrases: Bool) -> CapturedContext {
        guard let front = NSWorkspace.shared.frontmostApplication else { return .empty }

        let name = front.localizedName ?? "Unknown"
        let bundleID = front.bundleIdentifier
        let category = AppCategory.classify(bundleID: bundleID, name: name)
        let target = TargetApp(bundleID: bundleID, name: name, category: category)

        // Don't mine Talkie's own UI for context, and respect the setting.
        if !minePhrases || bundleID == selfBundleID {
            return CapturedContext(target: target, phrases: [], windowTitle: nil)
        }

        var sources: [String] = []
        let windowTitle = focusedWindowTitle(pid: front.processIdentifier)
        if let windowTitle { sources.append(windowTitle) }
        if let near = focusedText() { sources.append(near) }

        let phrases = PhraseMiner.mine(from: sources)
        return CapturedContext(target: target, phrases: phrases, windowTitle: windowTitle)
    }

    // MARK: Accessibility reads

    /// Title of the target app's focused (or main) window, e.g. the open file
    /// name in an editor or the conversation name in a chat app.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appEl = AXUIElementCreateApplication(pid)
        func title(of attribute: String) -> String? {
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, attribute as CFString, &windowRef) == .success,
                  let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let t = titleRef as? String, !t.isEmpty else { return nil }
            return t
        }
        return title(of: kAXFocusedWindowAttribute as String) ?? title(of: kAXMainWindowAttribute as String)
    }

    /// The value of the focused text element (the field you're about to dictate
    /// into) — gives us the names already on screen. Capped so a huge document
    /// doesn't flood the bias set.
    private static func focusedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &valueRef) == .success,
              let str = valueRef as? String else { return nil }
        return String(str.prefix(2000))
    }
}

/// Extracts a small set of "worth spelling right" phrases from free text:
/// proper nouns (Capitalized words), CamelCase / snake_case identifiers, and
/// filename-like tokens. Pure + Sendable.
enum PhraseMiner {
    static func mine(from sources: [String], limit: Int = 40) -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        for source in sources {
            // Split on whitespace and common separators, but keep dots (Foo.tsx),
            // underscores and internal capitals intact.
            let tokens = source.split { ch in
                ch.isWhitespace || "•|—–-/\\()[]{}<>\"'`,:;!?".contains(ch)
            }
            for raw in tokens {
                let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".#@"))
                guard token.count >= 3, token.count <= 40 else { continue }
                guard isInteresting(token) else { continue }
                let dedupKey = token.lowercased()
                if seen.insert(dedupKey).inserted {
                    out.append(token)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    private static func isInteresting(_ token: String) -> Bool {
        // A filename-ish token: has a dot with a short alpha extension.
        if let dot = token.lastIndex(of: "."), dot != token.startIndex {
            let ext = token[token.index(after: dot)...]
            if (1...5).contains(ext.count) && ext.allSatisfy(\.isLetter) { return true }
        }
        // CamelCase or contains an internal capital (ExerciseLibrary, useState).
        let hasInternalCapital = token.dropFirst().contains { $0.isUppercase }
        if hasInternalCapital { return true }
        // snake_case identifier.
        if token.contains("_") && token.contains(where: \.isLetter) { return true }
        // A capitalized proper-noun word (Coralate) that isn't a common stopword.
        if let first = token.first, first.isUppercase,
           token.dropFirst().allSatisfy({ $0.isLowercase }),
           token.count >= 4, !stopwords.contains(token.lowercased()) {
            return true
        }
        return false
    }

    /// Common capitalized sentence-starters we don't want to bias toward.
    private static let stopwords: Set<String> = [
        "the", "this", "that", "these", "those", "there", "then", "what", "when",
        "where", "which", "while", "with", "your", "you", "and", "but", "for",
        "from", "have", "here", "into", "more", "most", "name", "untitled",
        "new", "open", "save", "edit", "file", "menu", "window", "settings",
    ]
}
