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

    /// Whether secure keyboard entry is on right now (a focused password field, a
    /// password manager's lock screen, Terminal's Secure Keyboard Entry, …). This is
    /// exactly the condition under which `insert` copies to the clipboard with a
    /// `secureInputReason()`. Exposed so callers handling `.leftOnClipboard` can
    /// STRICTLY exclude the secure case (a dictated password must never be persisted
    /// anywhere) without re-importing Carbon or string-matching the reason — and it's
    /// authoritative because `.leftOnClipboard` is handled synchronously right after
    /// `insert` returns, with no await in between to let the state change.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Whether the process may post synthetic events. `prompt: true` surfaces the
    /// System Settings → Privacy & Security → Accessibility request once.
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt` (non-concurrency-safe
        // C global in Swift 6); the string key is stable API.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Surfaces the system Accessibility prompt at most once per launch, so a
    /// missing post-event grant self-corrects without nagging on every dictation.
    private static var didPromptTrust = false
    private static func promptTrustOnce() {
        guard !didPromptTrust else { return }
        didPromptTrust = true
        ensureTrusted(prompt: true)
    }

    static func insert(_ raw: String, mode: InsertionMode) -> Outcome {
        let text = raw
        guard !text.isEmpty else { return .empty }

        // Secure-input fields (passwords) reject synthetic events — never force it.
        if IsSecureEventInputEnabled() {
            copyToClipboard(text)
            return .leftOnClipboard(reason: secureInputReason())
        }

        // Synthetic ⌘V needs Accessibility (post-event) trust. The hotkey only
        // needs Input Monitoring, so dictation can work while paste silently
        // can't — the usual cause of "it never auto-pastes". Don't spam the
        // prompt on every dictation, but DO surface it once so a missing grant
        // self-corrects; the text stays on the clipboard for a manual ⌘V.
        guard ensureTrusted(prompt: false) else {
            promptTrustOnce()
            copyToClipboard(text)
            // K1: route through `.loc` (was a raw English literal). Names the exact
            // fix (grant Accessibility) and the exact next action (⌘V from clipboard).
            return .leftOnClipboard(reason: "Turn on Accessibility so I can paste for you — tap to copy for now.".loc)
        }

        switch mode {
        case .paste:
            // Best-effort: AX focused-element detection false-negatives on Electron
            // / web / Catalyst apps (VS Code, Cursor, Slack, browsers, ChatGPT) —
            // the apps people dictate into most. Hard-gating ⌘V on it was making
            // auto-paste fail in exactly those apps. So always paste when trusted +
            // not secure; only the clipboard RESTORE is gated on a confident field
            // detection. When unconfirmed we leave the transcript on the clipboard,
            // so a missed paste is still recoverable with a manual ⌘V (no regression
            // — that was already the everyday behaviour).
            let confident = hasEditableFocus()
            pasteViaClipboard(text, restorePrevious: confident)
        case .type:
            // The per-character usleep loop must not run on the main actor.
            let payload = text
            DispatchQueue.global(qos: .userInitiated).async {
                typeUnicode(payload)
            }
        }
        return .inserted
    }

    /// Replace the `graphemeCount` characters immediately before the caret with
    /// `text`, by selecting them (⇧←×count) and pasting over the selection.
    /// Paste mode only; best-effort — falls back to leaving `text` on the
    /// clipboard when it can't run safely (no Accessibility trust, a secure
    /// field, nothing focused). Used by the optional "optimistic insertion"
    /// path, which inserts the raw transcript instantly and swaps in the cleaned
    /// version once the on-device model finishes.
    ///
    /// Inherent fragility: if the caret moved or the user typed since the
    /// interim text was inserted, the backward selection covers the wrong range.
    /// The caller gates this on focus/timing, and the feature ships off.
    @discardableResult
    static func replaceBackward(graphemeCount: Int, with text: String, mode: InsertionMode) -> Outcome {
        guard mode == .paste, graphemeCount > 0, !text.isEmpty else { return .empty }
        if IsSecureEventInputEnabled() {
            copyToClipboard(text)
            return .leftOnClipboard(reason: secureInputReason())
        }
        guard ensureTrusted(prompt: false) else {
            copyToClipboard(text)
            // K1: localized; still names the failure and the recoverable next action.
            return .leftOnClipboard(reason: "Couldn’t paste that — it’s on your clipboard, tap to copy.".loc)
        }
        // STRICT: only replace-in-place where ⇧←-select-then-paste reliably REPLACES
        // (a settable native field). If focus drifted to a terminal / Electron field
        // since the interim was inserted, a paste-over would append the cleaned copy
        // *underneath* the raw one — so fall back to the clipboard instead of
        // duplicating. The optimistic INSERT is gated on the same signal, so this is
        // normally already satisfied; this re-check just guards a focus change during
        // the cleanup await.
        guard focusIsInPlaceReplaceable() else {
            copyToClipboard(text)
            return .leftOnClipboard(reason: "Didn’t paste — it’s safe on your clipboard, tap to copy.".loc)
        }
        selectBackward(graphemeCount)
        pasteViaClipboard(text, restorePrevious: true) // ⌘V over a selection replaces it
        return .inserted
    }

    /// Delete the `graphemeCount` characters immediately before the caret, by
    /// selecting them (⇧←×count) and pressing Delete over the selection. The
    /// backspace-over-a-selection deletes the whole run in one keystroke, so this can't
    /// leave a partial delete the way `graphemeCount` separate backspaces could if a
    /// keystroke were dropped. Paste-mode only and gated by the SAME secure-input /
    /// Accessibility-trust / editable-focus guards as `replaceBackward` — a delete is
    /// as destructive as a replace, so it fails closed identically: when it can't run
    /// safely it does nothing (returns `.empty`) rather than blindly firing Delete keys
    /// into whatever is focused.
    ///
    /// Used by B9's "scratch that" to remove the text you just dictated. Same inherent
    /// caret-position fragility as `replaceBackward` (if the caret moved since the
    /// insertion the backward selection covers the wrong range); the caller gates this
    /// on the 45-second / same-app `ImplicitSelectionGate` plus a best-effort
    /// AX end-of-field check, and offers an immediate Undo.
    @discardableResult
    static func deleteBackward(graphemeCount: Int, mode: InsertionMode) -> Outcome {
        guard mode == .paste, graphemeCount > 0 else { return .empty }
        if IsSecureEventInputEnabled() { return .empty }
        guard ensureTrusted(prompt: false) else { return .empty }
        guard hasEditableFocus() else { return .empty }
        selectBackward(graphemeCount)
        postDelete()
        return .inserted
    }

    /// Extend the selection left by `n` characters from the caret (⇧←×n).
    private static func selectBackward(_ n: Int) {
        let source = CGEventSource(stateID: .privateState)
        let left = CGKeyCode(kVK_LeftArrow)
        for _ in 0..<n {
            let down = CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: true)
            down?.flags = .maskShift
            let up = CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: false)
            up?.flags = []
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    /// STRICT check: is the current keyboard focus a field where selecting text with
    /// ⇧←×N and pasting over it reliably REPLACES those characters? True only when the
    /// focused element exposes a *settable* `AXValue` — i.e. a native macOS text field
    /// or text view. This is deliberately narrower than `hasEditableFocus()`:
    ///
    ///  - Terminals (Terminal.app, iTerm2, Warp, VS Code's integrated terminal, …) do
    ///    NOT expose a settable AXValue — their command line isn't a GUI text field, so
    ///    ⇧← is swallowed and a paste-over lands the new text AFTER the old instead of
    ///    replacing it (the "raw block, then the polished copy underneath" bug).
    ///  - Electron / web fields (Slack, Chrome, ChatGPT, Claude desktop) also usually
    ///    aren't settable — they only expose a selectable range — so they're excluded
    ///    too. That's the SAFE direction: an app wrongly excluded just falls back to a
    ///    single clean insert; an app wrongly *included* would duplicate.
    ///
    /// Used to gate the optional optimistic-insertion swap (`replaceBackward`), which is
    /// the only place a select-and-paste-over runs. Fails closed: any element we can't
    /// confirm settable returns false, so the swap never fires where it might duplicate.
    static func focusIsInPlaceReplaceable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return false }
        let element = focusedRef as! AXUIElement
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    /// Best-effort check: is the current keyboard focus an editable text element?
    /// Used as a CONFIDENCE signal, not a gate: when true we paste and restore the
    /// prior clipboard; when false we still paste (this AX query false-negatives on
    /// Electron / web apps) but leave the transcript on the clipboard as a
    /// recoverable fallback. Accessibility is already verified by the caller, so
    /// this AX query can succeed.
    private static func hasEditableFocus() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return false }
        let element = focusedRef as! AXUIElement

        // Most native text inputs expose a settable AXValue.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // Accept known editable roles (some editors don't flag settability).
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole {
            return true
        }
        // A selectable text range is the most reliable cross-toolkit signal of a
        // text input — Electron / web fields (VS Code, Slack, Chrome, ChatGPT)
        // expose it even when they don't flag AXValue settable or report a known
        // role, which is why the two checks above miss them.
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           rangeRef != nil {
            return true
        }
        return false
    }

    // MARK: Secure-input diagnosis

    /// Build the "couldn't paste — text is on the clipboard" reason shown by the HUD
    /// when secure keyboard entry is on. Secure input is system-wide, and the culprit
    /// is frequently NOT the focused field — it's a password manager whose lock
    /// screen is still up, or Terminal's "Secure Keyboard Entry" left toggled on. So
    /// we name the holding app when we can resolve it, and only fall back to the old
    /// generic "Password field" guess when we genuinely can't tell who holds it.
    ///
    /// The lookup is a pure diagnostic read (see `SecureInputCulprit`); it never
    /// blocks or delays insertion beyond a microsecond IOKit read on this already-
    /// failed path, and it reads no keystrokes or field contents.
    private static func secureInputReason() -> String {
        guard let culprit = SecureInputCulprit.current() else {
            // Nobody resolvable — keep today's honest, generic guess.
            return "Password field — I don’t peek. Tap to copy.".loc
        }
        // If the holder is the app you're actually in, a focused password field is
        // the likely story: the short, familiar message is right.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if culprit.pid == frontPID {
            return "Password field — I don’t peek. Tap to copy.".loc
        }
        // The holder is some OTHER app (the stuck-state case). Name it so you know
        // exactly what to dismiss — a 1Password lock screen, Terminal's Secure
        // Keyboard Entry, etc. — instead of hunting blind.
        return String(
            format: "%@ is holding secure input — switch to it and dismiss its password prompt. Tap to copy.".loc,
            culprit.name
        )
    }

    // MARK: Clipboard paste

    /// Bumped on each paste; a stale restore (from an earlier, very recent
    /// dictation) checks this and bails so it can't clobber a newer paste.
    private static var restoreGeneration = 0

    /// Writes `text` to the pasteboard and posts ⌘V. When `restorePrevious` is
    /// true (a confident editable-focus detection) the prior clipboard is restored
    /// after the paste lands; when false the transcript is intentionally left on
    /// the clipboard as a fallback for a manual ⌘V (the unconfirmed-focus path).
    private static func pasteViaClipboard(_ text: String, restorePrevious: Bool) {
        let pb = NSPasteboard.general
        restoreGeneration &+= 1
        let myGen = restoreGeneration

        // Snapshot only when we intend to restore. Promised / lazy pasteboard
        // types (e.g. dragged files) can't be captured eagerly — a known
        // limitation of save/restore.
        let saved = restorePrevious ? snapshot(pb) : []

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

        // Leave the transcript on the clipboard when we're not restoring, so an
        // unconfirmed paste is still recoverable with a manual ⌘V.
        guard restorePrevious else { return }

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

    /// Synthesize a single Delete (backspace) keystroke over the current selection —
    /// the same `.privateState` source as `postCommandV` so it doesn't inherit ambient
    /// hardware modifiers. `kVK_Delete` (51) is the top-row Delete/Backspace that
    /// deletes the selection (or the char to the caret's left when nothing is selected),
    /// which is exactly what B9's `deleteBackward` wants after a ⇧←×n selection.
    private static func postDelete() {
        let source = CGEventSource(stateID: .privateState)
        let del = CGKeyCode(kVK_Delete) // 51
        let down = CGEvent(keyboardEventSource: source, virtualKey: del, keyDown: true)
        down?.flags = []
        let up = CGEvent(keyboardEventSource: source, virtualKey: del, keyDown: false)
        up?.flags = []
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
