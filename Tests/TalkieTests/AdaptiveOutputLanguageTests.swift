import XCTest
@testable import Talkie

/// The gate for Adaptive per-app output language — the multi-language sibling of
/// E8's fixed `outputLanguageCode`. Where E8 requires a hand-picked FIXED target,
/// Adaptive detects each dictation's target from text already present in the app,
/// so one profile can follow a conversation that itself switches languages.
///
/// Two independent things are locked here, in the `AppProfileResolveTests` /
/// `OutputTranslationGuardTests` style:
///  1. The RESOLUTION contract (`AppProfile.outputLanguageAdaptive` →
///     `ResolvedProfile`): mutual exclusivity with the fixed code, `isEmpty`
///     treatment, and sparse-decode back-compat.
///  2. The pure GATE core (`AdaptiveOutputLanguage.preflightGate` / `.decide`):
///     every fail-closed path falls back to "insert as spoken", and — the one
///     that's more than an insertion-quality concern — a gate tripping BEFORE the
///     AX read means the read must never happen at all (consent + Private-app
///     invariant), which is why that check is split into its own pre-read gate
///     function rather than folded into the post-read decision.
final class AdaptiveOutputLanguageTests: XCTestCase {

    private func app(_ bundleID: String?, category: AppCategory = .other) -> TargetApp {
        TargetApp(bundleID: bundleID, name: bundleID ?? "Unknown", category: category)
    }

    // MARK: - Resolution: outputLanguageAdaptive → ResolvedProfile

    @MainActor
    func testAdaptiveTrueResolvesAdaptiveModeRegardlessOfStaleFixedCode() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.adaptive.stale.\(UUID().uuidString)"
        // A profile that has BOTH a stale fixed code (left over from a prior E8
        // pick) and adaptive turned on. Adaptive must win, and the fixed code must
        // never leak into the resolved profile — a call site that only checks
        // `outputLanguageCode` must see nil, or it would try to double-apply E8.
        store.upsert(AppProfile(
            bundleID: bundleID, displayName: "Mixed Channel",
            outputLanguageCode: "en", outputLanguageAdaptive: true
        ))

        let resolved = store.resolve(for: app(bundleID, category: .chat), settings: settings)
        XCTAssertTrue(resolved.outputLanguageAdaptive, "Adaptive must resolve true when set")
        XCTAssertNil(resolved.outputLanguageCode,
                     "A stale fixed code must be ignored once adaptive is on — mutually exclusive")

        store.remove(bundleID: bundleID)
    }

    @MainActor
    func testExplicitCodeResolvesFixedWhenAdaptiveIsNilOrFalse() {
        let store = AppProfileStore()
        let settings = AppSettings()

        // adaptive: nil (unset) + a fixed code ⇒ fixed mode, exactly E8's existing
        // behavior, untouched by this feature.
        let nilBundle = "com.fixed.nil.\(UUID().uuidString)"
        store.upsert(AppProfile(bundleID: nilBundle, displayName: "Slack", outputLanguageCode: "en"))
        let nilResolved = store.resolve(for: app(nilBundle, category: .chat), settings: settings)
        XCTAssertEqual(nilResolved.outputLanguageCode, "en")
        XCTAssertFalse(nilResolved.outputLanguageAdaptive)

        // adaptive: false (explicit) + a fixed code ⇒ still fixed mode.
        let falseBundle = "com.fixed.false.\(UUID().uuidString)"
        store.upsert(AppProfile(
            bundleID: falseBundle, displayName: "Slack",
            outputLanguageCode: "de", outputLanguageAdaptive: false
        ))
        let falseResolved = store.resolve(for: app(falseBundle, category: .chat), settings: settings)
        XCTAssertEqual(falseResolved.outputLanguageCode, "de")
        XCTAssertFalse(falseResolved.outputLanguageAdaptive)

        store.remove(bundleID: nilBundle)
        store.remove(bundleID: falseBundle)
    }

    @MainActor
    func testNeitherSetResolvesToOff() {
        let store = AppProfileStore()
        let settings = AppSettings()

        // No profile at all.
        let noProfile = store.resolve(for: app("com.no.profile.adaptive", category: .browser), settings: settings)
        XCTAssertNil(noProfile.outputLanguageCode)
        XCTAssertFalse(noProfile.outputLanguageAdaptive)

        // A profile that overrides something unrelated but leaves both output-
        // language fields untouched.
        let bundleID = "com.other.override.\(UUID().uuidString)"
        store.upsert(AppProfile(bundleID: bundleID, displayName: "App", insertionMode: .type))
        let resolved = store.resolve(for: app(bundleID, category: .other), settings: settings)
        XCTAssertNil(resolved.outputLanguageCode)
        XCTAssertFalse(resolved.outputLanguageAdaptive)

        store.remove(bundleID: bundleID)
    }

    @MainActor
    func testAdaptiveIsScopedByBundleID() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.adaptive.scoped.\(UUID().uuidString)"
        store.upsert(AppProfile(bundleID: bundleID, displayName: "Mixed", outputLanguageAdaptive: true))

        let resolved = store.resolve(for: app(bundleID, category: .chat), settings: settings)
        XCTAssertTrue(resolved.outputLanguageAdaptive)

        let other = store.resolve(for: app("com.other.unaffected", category: .chat), settings: settings)
        XCTAssertFalse(other.outputLanguageAdaptive, "adaptive is scoped by bundle id — a different app is unaffected")

        store.remove(bundleID: bundleID)
    }

    // MARK: - isEmpty

    func testOutputLanguageAdaptiveOnlyProfileIsNotEmpty() {
        let p = AppProfile(bundleID: "com.app", displayName: "App", outputLanguageAdaptive: true)
        XCTAssertFalse(p.isEmpty, "a profile carrying only adaptive=true is a real override")

        // false / nil are no-ops and must still read as empty, mirroring neverStore.
        XCTAssertTrue(
            AppProfile(bundleID: "com.app", displayName: "App", outputLanguageAdaptive: false).isEmpty,
            "outputLanguageAdaptive=false overrides nothing")
        XCTAssertTrue(
            AppProfile(bundleID: "com.app", displayName: "App").isEmpty,
            "an unset outputLanguageAdaptive overrides nothing")
    }

    @MainActor
    func testAdaptiveOnlyProfileSurvivesUpsert() {
        // The store must actually persist an adaptive-only profile (not drop it as
        // a no-op row), exactly like a neverStore-only or outputLanguageCode-only
        // profile already does.
        let store = AppProfileStore()
        let bundleID = "com.adaptive.persist.\(UUID().uuidString)"
        store.upsert(AppProfile(bundleID: bundleID, displayName: "App", outputLanguageAdaptive: true))
        XCTAssertNotNil(store.profile(for: bundleID), "upsert must keep an adaptive-only profile")
        store.remove(bundleID: bundleID)
    }

    // MARK: - Decode tolerance (round-trip + old-JSON back-compat)

    func testOutputLanguageAdaptiveSurvivesSparseDecodeOfOldProfilesJSON() throws {
        // A pre-this-feature profile with no outputLanguageAdaptive key at all
        // (this is literally today's on-disk shape for every E8 user) must decode
        // cleanly to nil ⇒ resolves to off/fixed-mode-only, never a crash or a
        // silently-wrong adaptive-on default.
        let oldJSON = Data("""
        { "com.tinyspeck.slackmacgap": { "bundleID": "com.tinyspeck.slackmacgap", "displayName": "Slack", "outputLanguageCode": "en" } }
        """.utf8)
        let oldDecoded = try JSONDecoder().decode([String: AppProfile].self, from: oldJSON)
        let oldProfile = try XCTUnwrap(oldDecoded["com.tinyspeck.slackmacgap"])
        XCTAssertNil(oldProfile.outputLanguageAdaptive,
                     "A profile written before this field existed decodes to nil, not a failure")
        XCTAssertEqual(oldProfile.outputLanguageCode, "en", "the pre-existing E8 field is untouched")

        // A sparse profile carrying ONLY outputLanguageAdaptive round-trips through
        // decode (mirrors the neverStore-only and outputLanguageCode-only tests).
        let sparseJSON = Data("""
        { "com.mixed.channel": { "bundleID": "com.mixed.channel", "displayName": "Mixed Channel", "outputLanguageAdaptive": true } }
        """.utf8)
        let sparseDecoded = try JSONDecoder().decode([String: AppProfile].self, from: sparseJSON)
        let p = try XCTUnwrap(sparseDecoded["com.mixed.channel"], "an adaptive-only profile must decode")
        XCTAssertEqual(p.outputLanguageAdaptive, true, "the adaptive flag survives a sparse decode")
        XCTAssertFalse(p.isEmpty, "a decoded adaptive-only profile is not empty")
        XCTAssertNil(p.cleanupStyle, "no other field is invented by the decode")
        XCTAssertNil(p.outputLanguageCode, "no fixed code is invented by the decode")

        // Round-trip: encode what we just decoded and decode it again.
        let reencoded = try JSONEncoder().encode(p)
        let roundTripped = try JSONDecoder().decode(AppProfile.self, from: reencoded)
        XCTAssertEqual(roundTripped.outputLanguageAdaptive, true)
    }

    // MARK: - Mutual exclusivity (the picker's state model — pure, no UI)

    /// The editor sheet's picker binding is a pure function of `AppProfile`: setting
    /// Adaptive clears the fixed code, and setting an explicit code clears Adaptive.
    /// This exercises that same read-modify-write shape directly on the model
    /// (without SwiftUI), so the contract is locked independent of the view layer.
    func testSelectingAdaptiveClearsFixedCodeAndViceVersa() {
        var profile = AppProfile(bundleID: "com.app", displayName: "App", outputLanguageCode: "en")
        XCTAssertEqual(profile.outputLanguageCode, "en")
        XCTAssertNil(profile.outputLanguageAdaptive)

        // Simulate picking "Adaptive" in the UI: the editor's binding setter must
        // set adaptive AND clear the fixed code in the same write.
        profile.outputLanguageAdaptive = true
        profile.outputLanguageCode = nil
        XCTAssertTrue(profile.outputLanguageAdaptive == true)
        XCTAssertNil(profile.outputLanguageCode)

        // Simulate picking an explicit language afterward: must clear adaptive back
        // to nil and set the code.
        profile.outputLanguageCode = "de"
        profile.outputLanguageAdaptive = nil
        XCTAssertEqual(profile.outputLanguageCode, "de")
        XCTAssertNil(profile.outputLanguageAdaptive)

        // Simulate picking "As spoken" (—): both clear.
        profile.outputLanguageCode = nil
        profile.outputLanguageAdaptive = nil
        XCTAssertTrue(profile.isEmpty, "clearing both leaves the profile with no output-language override")
    }

    // MARK: - Gate 1 (preflightGate): consent + Private-app invariant, BEFORE any AX read

    func testPreflightGateBlocksWhenContextAwarenessOff() {
        let d = AdaptiveOutputLanguage.preflightGate(contextAwareness: false, neverStore: false)
        XCTAssertEqual(d, .noAttempt(reason: "context-awareness-off"),
                       "Adaptive detection must never fire when context awareness is off")
    }

    func testPreflightGateBlocksWhenNeverStore() {
        let d = AdaptiveOutputLanguage.preflightGate(contextAwareness: true, neverStore: true)
        XCTAssertEqual(d, .noAttempt(reason: "never-store"),
                       "A Private app's focused content must never be read for adaptive detection either")
    }

    func testPreflightGateBlocksWhenBothOff() {
        let d = AdaptiveOutputLanguage.preflightGate(contextAwareness: false, neverStore: true)
        XCTAssertNotNil(d, "either failing condition alone must block")
    }

    func testPreflightGateClearsWhenConsentedAndNotPrivate() {
        let d = AdaptiveOutputLanguage.preflightGate(contextAwareness: true, neverStore: false)
        XCTAssertNil(d, "both conditions satisfied ⇒ proceed to the bounded AX read")
    }

    // MARK: - Gate 2 (decide): usable signal, AFTER the (already-gated) AX read

    func testDecideFallsBackWhenContextTextIsNil() {
        // The AX read itself failed (unreadable app, e.g. Electron with no exposed
        // value) ⇒ cannot detect ⇒ insert as spoken.
        let d = AdaptiveOutputLanguage.decide(contextText: nil, inputCode: "de", contextCode: nil)
        XCTAssertEqual(d, .fallback(reason: "context-unreadable"))
    }

    func testDecideFallsBackWhenContextTextIsEmpty() {
        let d = AdaptiveOutputLanguage.decide(contextText: "   ", inputCode: "de", contextCode: nil)
        XCTAssertEqual(d, .fallback(reason: "context-unreadable"))
    }

    func testDecideFallsBackWhenContextTextIsTooShortToScore() {
        // Fewer than LanguageDetector.minimumScorableTokens (3) whitespace tokens —
        // too short to language-ID, same floor OutputTranslator itself uses.
        let d = AdaptiveOutputLanguage.decide(contextText: "hi there", inputCode: "de", contextCode: "en")
        XCTAssertEqual(d, .fallback(reason: "context-unreadable"),
                       "a too-short context sample must not gamble a translation, even if a code was passed in")
    }

    func testDecideFallsBackWhenContextLanguageUndetected() {
        // Enough text, but the (precomputed) language code came back nil — the
        // recognizer couldn't call it confidently.
        let d = AdaptiveOutputLanguage.decide(
            contextText: "asdf qwer zxcv asdf qwer", inputCode: "de", contextCode: nil)
        XCTAssertEqual(d, .fallback(reason: "context-undetected"))
    }

    func testDecideFallsBackWhenInputCodeUndetected() {
        let d = AdaptiveOutputLanguage.decide(
            contextText: "this is a plain english sentence with enough words", inputCode: nil, contextCode: "en")
        XCTAssertEqual(d, .fallback(reason: "input-undetected"))
    }

    func testDecideFallsBackWhenInputCodeIsEmpty() {
        let d = AdaptiveOutputLanguage.decide(
            contextText: "this is a plain english sentence with enough words", inputCode: "", contextCode: "en")
        XCTAssertEqual(d, .fallback(reason: "input-undetected"))
    }

    func testDecideSkipsWhenContextLanguageMatchesInput() {
        // The app is already in the language you spoke — no LLM call needed.
        let d = AdaptiveOutputLanguage.decide(
            contextText: "this is a plain english sentence with enough words", inputCode: "en", contextCode: "en")
        XCTAssertEqual(d, .skipSameLanguage)
    }

    func testDecideDetectsWhenContextLanguageDiffersFromInput() {
        // German dictation into an English-context app ⇒ translate to English.
        let d = AdaptiveOutputLanguage.decide(
            contextText: "this is a plain english sentence with enough words", inputCode: "de", contextCode: "en")
        XCTAssertEqual(d, .detected(languageCode: "en"))
    }

    func testDecideDetectsTheOtherDirectionToo() {
        // English dictation into a German-context app ⇒ translate to German.
        let d = AdaptiveOutputLanguage.decide(
            contextText: "das ist ein ganz normaler deutscher satz", inputCode: "en", contextCode: "de")
        XCTAssertEqual(d, .detected(languageCode: "de"))
    }

    // MARK: - End-to-end pure composition: gate 1 → (read) → gate 2

    /// A realistic walk through both gates for each of the four safety scenarios
    /// named in the spec, composed exactly the way `AppDelegate` will call them:
    /// `preflightGate` first (deciding whether to even attempt the AX read), then
    /// `decide` on whatever the (simulated) read returned.
    func testFullGateSequenceContextAwarenessOff() {
        let gate1 = AdaptiveOutputLanguage.preflightGate(contextAwareness: false, neverStore: false)
        // A real caller must stop here and never call AXFieldReader at all.
        XCTAssertEqual(gate1, .noAttempt(reason: "context-awareness-off"))
    }

    func testFullGateSequenceNeverStoreApp() {
        let gate1 = AdaptiveOutputLanguage.preflightGate(contextAwareness: true, neverStore: true)
        XCTAssertEqual(gate1, .noAttempt(reason: "never-store"))
    }

    func testFullGateSequenceUnreadableContext() {
        XCTAssertNil(AdaptiveOutputLanguage.preflightGate(contextAwareness: true, neverStore: false))
        // Simulated AX read: nothing readable in the target field.
        let gate2 = AdaptiveOutputLanguage.decide(contextText: nil, inputCode: "de", contextCode: nil)
        XCTAssertEqual(gate2, .fallback(reason: "context-unreadable"))
    }

    func testFullGateSequenceSuccessfulDetectionCallsForTranslation() {
        XCTAssertNil(AdaptiveOutputLanguage.preflightGate(contextAwareness: true, neverStore: false))
        let gate2 = AdaptiveOutputLanguage.decide(
            contextText: "hey can you send me the file when you get a chance",
            inputCode: "de", contextCode: "en")
        guard case .detected(let code) = gate2 else {
            return XCTFail("expected a detected code, got \(gate2)")
        }
        XCTAssertEqual(code, "en", "OutputTranslator.translate should be called with this detected code")
    }
}
