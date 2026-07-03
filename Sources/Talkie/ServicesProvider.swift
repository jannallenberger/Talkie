import AppKit
import Foundation

// Talkie's macOS Services surface — the two right-click / Services-menu actions
// registered by the `NSServices` array in Resources/Info.plist:
//
//   • "Transcribe with Talkie"  — select an audio/video file in Finder, and this
//     enqueues it on the same import queue the Meetings tab uses (D1/D5's
//     `FileImportCoordinator`). It foregrounds Talkie on the Meetings tab and
//     returns immediately; the transcription happens off the service call.
//   • "Clean up with Talkie"    — select messy text in ANY app, and this rewrites
//     it in place through the on-device `CleanupEngine`, writing the polished
//     text back onto the pasteboard so the host app swaps the selection.
//
// This makes Talkie feel installed *into* macOS rather than beside it, with no
// new UI, no settings, and no network (the cleanup runs through the same
// Foundation Models on-device path dictation uses — no privacy delta; the text
// never leaves the Mac).
//
// ─── Concurrency shape (read before touching `cleanupText`) ──────────────────
// Services handlers arrive on the MAIN thread and are contractually SYNCHRONOUS:
// the pasteboard must already carry the result (or the untouched original) by the
// time the method returns. `CleanupEngine` is an `actor` with an async API, so the
// cleanup handler bridges the async call with a bounded `DispatchSemaphore`:
// a detached Task runs `cleanup.clean(…)`, signals the semaphore, and the handler
// blocks on `semaphore.wait(timeout:)` for at most `cleanupTimeout`.
//
// This block is deadlock-free — and only because the cleanup work NEVER hops to
// the main actor. `CleanupEngine.clean` → `generate` awaits `LanguageModelSession`
// and calls only free/`static` helpers (`LanguageDetector`, `talkieDebugLog`,
// `sanitize`), none `@MainActor`-isolated. The actor's continuations therefore run
// on the cooperative thread pool, not the (blocked) main thread, so waiting on the
// main thread cannot starve the work it's waiting for. If a future change makes any
// step of the cleanup path require the main actor, this wait WOULD deadlock — keep
// that path off the main actor, or move this bridge off it.
//
// The file handler (`transcribeFiles`) never blocks: it hands the URLs to the
// main-actor import queue via a Task and returns at once, so a long transcription
// can't wedge the Services machinery.
//
// On-device only: no network symbols here. This file lives under Sources/Talkie
// and is scanned by scripts/check-no-network.sh.
final class ServicesProvider: NSObject {
    /// Hard ceiling on how long the synchronous cleanup service will block the
    /// main thread waiting for the on-device model. A Services error dialog is a
    /// worse outcome than a no-op, so on timeout we return the ORIGINAL text with
    /// `error = nil` — the user simply sees their selection unchanged. Ten seconds
    /// comfortably covers a normal paragraph's rewrite while bounding a wedged or
    /// cold model.
    private static let cleanupTimeout: DispatchTimeInterval = .seconds(10)

    // MARK: Transcribe with Talkie (files)

    /// Services handler for "Transcribe with Talkie". Bound in Info.plist via
    /// `NSMessage = transcribeFiles`. Reads the selected file URLs from the
    /// pasteboard, foregrounds Talkie on the Meetings tab, and enqueues them on the
    /// D1/D5 import queue. Returns immediately — transcription runs off this call.
    ///
    /// The `@objc` selector shape is fixed by the Services contract:
    /// `service:userData:error:` with an `AutoreleasingUnsafeMutablePointer<NSString?>`
    /// out-param for an error string (we never set it — a failed enqueue surfaces in
    /// the app's own import UI, not a system dialog).
    @objc func transcribeFiles(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        // File services deliver file URLs on the pasteboard; read them as NSURLs
        // restricted to file URLs. Filtering to importable media happens inside
        // `FileImportCoordinator.enqueue` (ImportableMedia.expand), so a stray
        // non-media file the user multi-selected is simply ignored there.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        guard !urls.isEmpty else { return }

        // Hop to the main actor: the app, its window, and the import coordinator are
        // all main-actor-isolated. This handler is already on the main thread, but
        // the hop is what makes it statically correct under Swift 6 (the same
        // framework-callback boundary the App Intents `perform()`s cross).
        Task { @MainActor in
            guard let app = AppDelegate.shared else { return }
            // Bring Talkie forward and land on Meetings so the import is visible
            // (progress row, and the finished Meeting appears there).
            NSApp.activate(ignoringOtherApps: true)
            app.openSettings(tab: .meetings)
            app.fileImporter.enqueue(urls)
        }
    }

    // MARK: Clean up with Talkie (text)

    /// Services handler for "Clean up with Talkie". Bound in Info.plist via
    /// `NSMessage = cleanupText`. Reads the selected string, runs ONE bounded
    /// on-device cleanup pass, and writes the polished text back onto the pasteboard
    /// so the host app replaces the selection in place. On timeout or when the model
    /// is unavailable, the original text is left untouched and `error` stays nil (a
    /// no-op beats a Services error dialog).
    @objc func cleanupText(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let original = pboard.string(forType: .string),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Nothing to do if the on-device model isn't available — return the text
        // unchanged (the pasteboard already holds it), no dialog.
        guard CleanupEngine.isAvailable else { return }

        // Resolve the user's configured "Other"-category cleanup style so the
        // rewrite matches what dictation into a generic app would produce. If that
        // resolves to `.off` (verbatim), fall back to `.neutral`: a user who picked
        // "Clean up with Talkie" is asking for a cleanup, so a verbatim no-op would
        // be pointless. Read on the main thread (this handler runs there); `settings`
        // is main-actor-isolated but the Services call is already on the main thread,
        // so a synchronous `assumeIsolated` read is safe and keeps the value local.
        let style = MainActor.assumeIsolated { () -> CleanupStyle in
            let resolved = AppDelegate.shared?.settings.cleanupStyle(for: .other) ?? .neutral
            return resolved == .off ? .neutral : resolved
        }

        // Bridge the async actor call to this synchronous handler with a bounded
        // wait. A FRESH engine (not the app's shared one, which is `private` and may
        // hold a dictation's warm session) keeps this self-contained. `cleaned` is
        // written only from inside the Task before the signal, and read only after
        // the wait returns `.success`, so there is no data race on it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = CleanupBox()
        Task.detached {
            let engine = CleanupEngine()
            let result = await engine.clean(original, style: style)
            box.value = result
            semaphore.signal()
        }

        // Block the main thread up to the timeout. On `.timedOut` we leave the
        // original text in place; on `.success` we swap in the cleaned text if the
        // engine produced one (it returns nil on refusal / language-flip / empty —
        // all of which mean "keep the raw text").
        if semaphore.wait(timeout: .now() + Self.cleanupTimeout) == .success,
           let cleaned = box.value,
           !cleaned.isEmpty {
            pboard.clearContents()
            pboard.setString(cleaned, forType: .string)
        }
        // else: timeout, or the engine kept the raw text — the pasteboard still
        // holds `original`, so the host app's selection is unchanged.
    }
}

/// A tiny reference box the detached cleanup Task writes and the (blocked) main
/// thread reads once the semaphore signals. The semaphore's signal→wait pair is a
/// full memory barrier and the write strictly happens-before the read, so a plain
/// `@unchecked Sendable` box is sound here — there is no concurrent access to
/// synchronize (write completes before `signal()`, read happens after `wait()`).
private final class CleanupBox: @unchecked Sendable {
    var value: String?
}
