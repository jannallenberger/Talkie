import AppKit
import ApplicationServices

/// The shared Accessibility text reader: given the current keyboard focus, best-
/// effort reads the value of the editable field the user is typing into. Extracted
/// verbatim from `LearningEngine` so two consumers can share one battle-tested
/// implementation — `LearningEngine` (watch the field for a correction after we
/// insert) and `InsertionVerifier` (confirm our paste actually landed). Keeping a
/// single reader means the two features agree on exactly which apps are AX-readable
/// and which aren't, instead of drifting apart.
///
/// Best-effort by nature — it relies on the Accessibility text value of the focused
/// element, which native fields (Notes, TextEdit, most AppKit apps) expose but some
/// web/Electron apps (VS Code, Slack, Chrome, ChatGPT) don't. When it can't read,
/// it returns nil and the caller decides how to degrade.
///
/// `@MainActor` because AX calls are made from the main thread throughout this app
/// (the house pattern); the enum holds no state.
@MainActor
enum AXFieldReader {

    // MARK: Focused-field read

    /// The focused text element and its current value. Reads the focused element's
    /// own value first; if that's empty — common in Electron/Chromium apps like
    /// Claude, where the top focused element is a generic group — it walks the app's
    /// tree for the editable text element (AXTextArea / AXTextField / AXWebArea with
    /// a value), the way a screen reader would. nil only when no text is reachable.
    static func focusedElementValue() -> (AXUIElement, String)? {
        if let el = focusedElement() {
            if let v = stringValue(of: el) { return (el, v) }
            if let hit = findTextDescendant(el, depth: 0) { return hit }
        }
        // Fall back through the focused application's own focused element + window.
        if let app = focusedAppElement() {
            for attr in [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute] {
                if let child = copyElement(app, attr as CFString) {
                    if let v = stringValue(of: child) { return (child, v) }
                    if let hit = findTextDescendant(child, depth: 0) { return hit }
                }
            }
        }
        return nil
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return copyElement(system, kAXFocusedUIElementAttribute as CFString)
    }

    static func focusedAppElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    /// Bounded DFS for an editable text element under `el` — a text-role node that
    /// exposes a non-empty string value.
    static func findTextDescendant(_ el: AXUIElement, depth: Int) -> (AXUIElement, String)? {
        if depth > 8 { return nil }
        let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXTextView"]
        if textRoles.contains(roleOf(el)), let v = stringValue(of: el) { return (el, v) }
        for child in children(el).prefix(40) {
            if let hit = findTextDescendant(child, depth: depth + 1) { return hit }
        }
        return nil
    }

    // MARK: AX primitives

    static func copyElement(_ el: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success, let r = ref,
              CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return (r as! AXUIElement)
    }

    static func stringValue(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success,
              let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    static func roleOf(_ el: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success,
              let r = ref as? String else { return "" }
        return r
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    /// One-shot diagnostic: dump the focused subtree's roles + value presence to the
    /// debug log, so we can SEE whether an AX-blind-looking app actually exposes its
    /// text somewhere (and where), rather than guessing.
    static func logFocusedTree() {
        guard let root = focusedElement() ?? focusedAppElement() else {
            talkieDebugLog("axprobe: no focused element"); return
        }
        var lines: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            if depth > 6 || lines.count > 80 { return }
            let role = roleOf(e)
            let v = stringValue(of: e)
            let desc = v.map { "= \"\($0.replacingOccurrences(of: "\n", with: "⏎").prefix(28))\" (\($0.count)ch)" } ?? ""
            lines.append(String(repeating: "· ", count: depth) + (role.isEmpty ? "?" : role) + " " + desc)
            for c in children(e).prefix(15) { walk(c, depth + 1) }
        }
        walk(root, 0)
        talkieDebugLog("axprobe tree (app=\(frontAppName())):\n" + lines.joined(separator: "\n"))
    }

    // MARK: Diagnostics + matching

    /// The frontmost app's name — for the debug log, to see which apps expose a
    /// readable field and which don't.
    static func frontAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    }

    /// The AX role of the focused element (e.g. AXTextArea, AXTextField), or
    /// "none"/"?" when nothing readable is focused — a strong signal in the log of
    /// whether the app exposes an editable text element at all.
    static func focusedRole() -> String {
        guard let el = focusedElement() else { return "none" }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return "?" }
        return role
    }

    /// Substring match that tolerates the reformatting apps apply on insert —
    /// smart quotes, en/em dashes, non-breaking spaces — so the baseline still
    /// recognises our inserted text.
    static func looseContains(_ haystack: String, _ needle: String) -> Bool {
        normalizeForMatch(haystack).contains(normalizeForMatch(needle))
    }

    static func normalizeForMatch(_ s: String) -> String {
        var out = s
        for (from, to) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""),
                           ("\u{201D}", "\""), ("\u{2013}", "-"), ("\u{2014}", "-"),
                           ("\u{00A0}", " ")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }
}
