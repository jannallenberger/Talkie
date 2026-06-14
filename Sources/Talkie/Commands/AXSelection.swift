import ApplicationServices

/// Reads the current selected text in the focused UI element via Accessibility —
/// the input for edit-by-voice / rewrite commands (features 08/12). Read-only;
/// returns nil when there's no selection or AX is unavailable.
enum AXSelection {
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }
        return text
    }
}
