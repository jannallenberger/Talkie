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

        guard ensureTrusted(prompt: true) else {
            copyToClipboard(text)
            return .leftOnClipboard(reason: "Grant Accessibility to Talkie to paste automatically — text copied for now.")
        }

        switch mode {
        case .paste:
            pasteViaClipboard(text)
        case .type:
            typeUnicode(text)
        }
        return .inserted
    }

    // MARK: Clipboard paste

    private static func pasteViaClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let savedChangeCount = pb.changeCount
        let saved = snapshot(pb)

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Mark transient so other clipboard managers skip recording it.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])

        postCommandV()

        // Restore only if no third party wrote in between; wait for the target to
        // consume the paste (it reads the pasteboard asynchronously).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard pb.changeCount == savedChangeCount + 1 else { return }
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
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V) // 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Fallback typing path: per-character Unicode injection (no clipboard touch).
    private static func typeUnicode(_ text: String) {
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
