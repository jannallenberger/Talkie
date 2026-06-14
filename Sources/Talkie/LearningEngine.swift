import AppKit
import ApplicationServices

/// Recursive self-improvement: after Talkie inserts text, it snapshots the
/// focused text field. Before the next dictation it re-reads that field; if the
/// user fixed a word Talkie produced, that correction becomes a dictionary rule.
///
/// Best-effort by nature — it relies on the Accessibility text value of the
/// focused element, which native fields (Notes, TextEdit, most AppKit apps)
/// expose but some web/Electron apps don't. When it can't read, it simply
/// learns nothing.
@MainActor
final class LearningEngine {
    private struct Pending {
        let element: AXUIElement
        let inserted: String
        let valueAfter: String
    }

    private var pending: Pending?

    /// Snapshot the focused field shortly after we inserted `inserted`.
    func recordInsertion(_ inserted: String) {
        guard let (element, value) = focusedElementValue(), value.contains(inserted) else {
            pending = nil
            return
        }
        pending = Pending(element: element, inserted: inserted, valueAfter: value)
    }

    /// If the user edited our last insertion in the same field, return the
    /// learned (from → to) corrections. Clears the pending snapshot.
    func collectCorrections() -> [(from: String, to: String)] {
        guard let p = pending else { return [] }
        pending = nil

        guard let (element, current) = focusedElementValue() else { return [] }
        guard CFEqual(element, p.element) else { return [] } // must be the same field
        guard current != p.valueAfter else { return [] }     // nothing changed

        return CorrectionExtractor.extract(before: p.valueAfter, after: current, inserted: p.inserted)
    }

    // MARK: Accessibility read

    private func focusedElementValue() -> (AXUIElement, String)? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        // CFTypeRef from the AX API is an AXUIElement.
        let element = focused as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let str = valueRef as? String else { return nil }
        return (element, str)
    }
}

/// Pure word-level diff that extracts conservative single-word corrections.
enum CorrectionExtractor {
    static func extract(
        before: String,
        after: String,
        inserted: String,
        maxLearned: Int = 3
    ) -> [(from: String, to: String)] {
        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)
        let insertedWords = Set(tokenize(inserted).map(normalized))

        // A big change is a rewrite, not a one-word fix — don't learn from it.
        let diff = afterTokens.difference(from: beforeTokens)
        guard !diff.isEmpty, diff.count <= 8 else { return [] }

        var removes: [Int: String] = [:]
        var inserts: [Int: String] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, let element, _): removes[offset] = element
            case .insert(let offset, let element, _): inserts[offset] = element
            }
        }

        var learned: [(String, String)] = []
        for (offset, old) in removes.sorted(by: { $0.key < $1.key }) {
            // Pair a removal with an insertion at (about) the same position.
            guard let new = inserts[offset] ?? inserts[offset + 1] ?? inserts[offset - 1] else { continue }
            let on = normalized(old), nn = normalized(new)
            guard on != nn, on.count >= 2, nn.count >= 2,
                  isWordLike(old), isWordLike(new),
                  insertedWords.contains(on) else { continue }
            let fromWord = stripped(old), toWord = stripped(new)
            guard !fromWord.isEmpty, !toWord.isEmpty else { continue }
            learned.append((fromWord, toWord))
            if learned.count >= maxLearned { break }
        }
        return learned
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static let punctuation = CharacterSet(charactersIn: ",.!?;:\"'()[]{}…—-")

    private static func stripped(_ token: String) -> String {
        token.trimmingCharacters(in: punctuation)
    }

    private static func normalized(_ token: String) -> String {
        stripped(token).lowercased()
    }

    private static func isWordLike(_ token: String) -> Bool {
        let core = stripped(token)
        return core.count >= 2 && core.contains(where: { $0.isLetter })
    }
}
