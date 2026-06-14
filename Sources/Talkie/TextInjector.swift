import AppKit
import ApplicationServices
import Carbon.HIToolbox // IsSecureEventInputEnabled(), kVK_ANSI_V

/// Inserts a finished string at the current keyboard-focus cursor. Default
/// strategy: write to the pasteboard, synthesize ⌘V into the front app, then
/// restore the previous clipboard. Falls back to leaving text on the clipboard
/// when a secure (password) field is focused or Accessibility isn't granted.
@MainActor
enum TextInjector {
    enum Outcome: Sendable {
        case inserted
        case leftOnClipboard(reason: String)
        case empty
    }

    /// Whether the process may post synthetic events. `prompt: true` surfaces the
    /// System Settings → Privacy & Security → Accessibility request once.
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt` (non-concurrency-safe
        // C global in Swift 6); the string key is stable API.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func insert(_ raw: String, mode: InsertionMode) -> Outcome {
        let text = raw
        guard !text.isEmpty else { return .empty }

        // Secure-input fields (passwords) reject synthetic events — never force it.
        if IsSecureEventInputEnabled() {
            copyToClipboard(text)
            return .leftOnClipboard(reason: "A password field is focused — text copied; press ⌘V where you want it.")
        }

        // Check silently here (don't spam the system prompt on every dictation);
        // the Permissions tab is where the user is asked to grant it.
        guard ensureTrusted(prompt: false) else {
            copyToClipboard(text)
            return .leftOnClipboard(reason: "Grant Accessibility to Talkie to paste automatically — text copied for now.")
        }

        switch mode {
        case .paste:
            pasteViaClipboard(text)
        case .type:
            // The per-character usleep loop must not run on the main actor.
            let payload = text
            DispatchQueue.global(qos: .userInitiated).async {
                typeUnicode(payload)
            }
        }
        return .inserted
    }

    // MARK: Clipboard paste

    /// Bumped on each paste; a stale restore (from an earlier, very recent
    /// dictation) checks this and bails so it can't clobber a newer paste.
    private static var restoreGeneration = 0

    private static func pasteViaClipboard(_ text: String) {
        let pb = NSPasteboard.general
        restoreGeneration &+= 1
        let myGen = restoreGeneration

        // Best-effort snapshot. Promised / lazy pasteboard types (e.g. dragged
        // files) can't be captured eagerly — a known limitation of save/restore.
        let saved = snapshot(pb)

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Mark transient so other clipboard managers skip recording it.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let mineChangeCount = pb.changeCount // the count OUR write produced

        // Focus may have moved to a secure (password) field between the entry
        // guard and now — never post synthetic keys into one.
        guard !IsSecureEventInputEnabled() else { return }

        postCommandV()

        // Restore after the target consumed the paste (it reads the pasteboard
        // asynchronously). Skip if a newer paste superseded us, or if anyone else
        // wrote to the pasteboard in the meantime.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard myGen == restoreGeneration else { return }
            let pb = NSPasteboard.general
            guard pb.changeCount == mineChangeCount else { return }
            restore(saved, to: pb)
        }
    }

    private static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    // MARK: Synthetic key events

    private static func postCommandV() {
        // `.privateState` so the synthetic event doesn't inherit ambient hardware
        // modifiers (e.g. the Option key the user is still releasing).
        let source = CGEventSource(stateID: .privateState)
        let vKey = CGKeyCode(kVK_ANSI_V) // 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = [] // clear ⌘ on key-up so no stray modifier latches
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Fallback typing path: per-character Unicode injection (no clipboard touch).
    /// `nonisolated` so it can run on a background queue (it never touches main state).
    nonisolated private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalarChunk in text.chunkedScalars(of: 1) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            var utf16 = Array(scalarChunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            usleep(1500)
        }
    }
}

private extension String {
    /// Split into substrings of `size` characters (keeps grapheme clusters intact).
    func chunkedScalars(of size: Int) -> [String] {
        guard size > 0 else { return [self] }
        var result: [String] = []
        var current = ""
        var count = 0
        for ch in self {
            current.append(ch)
            count += 1
            if count == size {
                result.append(current)
                current = ""
                count = 0
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
