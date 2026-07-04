import XCTest
@testable import Talkie

/// The gate for E8 (dictate-in-L1, insert-in-L2). This is a DETERMINISTIC-fallback
/// suite over `OutputTranslator`'s pure guard core plus its `translate` seam driven
/// by a stub summarizer — no Foundation Models, no network, no flakiness. The one
/// invariant every test defends: a guard failure inserts the UNTRANSLATED text,
/// never a refusal string and never the silently-wrong language.
///
/// It also locks the `AppProfile.outputLanguageCode` sparse-override contract in the
/// `AppProfileResolveTests` style (round-trips old JSON, resolves nil for everyone
/// who hasn't set it, survives a decode when it's the only field).
final class OutputTranslationGuardTests: XCTestCase {

    // MARK: - Guard (d): already the target language ⇒ skip the model entirely

    func testPreflightSkipsWhenInputAlreadyTarget() {
        // Pinned input code says English; the app wants English → nothing to do.
        let d = OutputTranslator.preflight(input: "this is a plain english sentence",
                                           inputCode: "en-US", target: "en")
        XCTAssertEqual(d, .skipAlreadyTarget,
                       "English dictation into an English-output app must skip the model (guard d)")
    }

    func testPreflightSkipsWhenTargetIsALocaleIDMatchingInput() {
        // The field may hold a full locale id — it must still base-match the input.
        let d = OutputTranslator.preflight(input: "das ist ein deutscher satz hier",
                                           inputCode: "de-DE", target: "de-DE")
        XCTAssertEqual(d, .skipAlreadyTarget)
    }

    func testPreflightProceedsWhenLanguagesDiffer() {
        // German pinned input, English target → there IS something to translate.
        let d = OutputTranslator.preflight(input: "das ist ein deutscher satz hier",
                                           inputCode: "de-DE", target: "en")
        XCTAssertNil(d, "A genuine mismatch must fall through to the model (nil preflight)")
    }

    func testPreflightSkipsShortUndetectableUtteranceWithNoPinnedCode() {
        // Too short to language-ID and no session language to trust → don't gamble a
        // translation on a fragment; insert as spoken.
        let d = OutputTranslator.preflight(input: "ok thanks", inputCode: nil, target: "de")
        XCTAssertEqual(d, .skipAlreadyTarget)
    }

    func testPreflightUsesPinnedCodeOverContentForShortInput() {
        // A short utterance the detector couldn't call, but the session was pinned to
        // German → still proceeds to translate toward the English target.
        let d = OutputTranslator.preflight(input: "guten tag", inputCode: "de-DE", target: "en")
        XCTAssertNil(d, "The pinned session language decides for a short input — proceed")
    }

    func testPreflightSkipsEmptyInputAndEmptyTarget() {
        XCTAssertEqual(OutputTranslator.preflight(input: "   ", inputCode: "de", target: "en"),
                       .skipAlreadyTarget)
        XCTAssertEqual(OutputTranslator.preflight(input: "das ist ein satz", inputCode: "de", target: ""),
                       .skipAlreadyTarget)
    }

    // MARK: - Guard (a): the output must READ as the target language

    func testDecideRejectsWhenOutputStillReadsAsWrongLanguage() {
        // The "model" returned German prose but the target was English → it failed to
        // translate. Fall back to the original.
        let d = OutputTranslator.decideOutput(
            input: "das ist ein deutscher satz den ich diktiert habe",
            output: "das ist immer noch ein rein deutscher satz ohne übersetzung",
            target: "en", mustSurvive: [])
        guard case .fallback(let reason) = d else {
            return XCTFail("A wrong-language output must fall back, got \(d)")
        }
        XCTAssertTrue(reason.hasPrefix("not-target"), "reason should name the language mismatch")
    }

    func testDecideAcceptsAGenuineTranslationIntoTheTarget() {
        let d = OutputTranslator.decideOutput(
            input: "das ist ein deutscher satz den ich diktiert habe",
            output: "this is a German sentence that I dictated",
            target: "en", mustSurvive: [])
        XCTAssertEqual(d, .accept("this is a German sentence that I dictated"),
                       "Correct-language output with no lost jargon is accepted")
    }

    // MARK: - Guard (b): refusals are never inserted

    func testDecideRejectsAModelRefusal() {
        // Reuses CleanupEngine.isRefusal — an opener AND a justification marker.
        let refusal = "I cannot comply with this request as it goes against my guidelines."
        XCTAssertTrue(CleanupEngine.isRefusal(refusal), "precondition: this is a refusal")
        let d = OutputTranslator.decideOutput(
            input: "das ist ein deutscher satz den ich diktiert habe",
            output: refusal, target: "en", mustSurvive: [])
        XCTAssertEqual(d, .fallback(reason: "refusal"))
    }

    // MARK: - Guard (c): dictionary / niche jargon survives verbatim

    func testDecideRejectsWhenJargonInInputIsLostInTranslation() {
        // "claude.md" and "Higgsfield" were spoken; the translation mangled them.
        let d = OutputTranslator.decideOutput(
            input: "bitte öffne claude.md und prüfe Higgsfield",
            output: "please open cloud MD and check the Higgs field",
            target: "en", mustSurvive: ["claude.md", "Higgsfield"])
        guard case .fallback(let reason) = d else {
            return XCTFail("Lost jargon must fall back, got \(d)")
        }
        XCTAssertTrue(reason.hasPrefix("jargon-lost"))
    }

    func testDecideAcceptsWhenJargonSurvivesVerbatim() {
        let d = OutputTranslator.decideOutput(
            input: "bitte öffne claude.md und prüfe Higgsfield",
            output: "please open claude.md and check Higgsfield",
            target: "en", mustSurvive: ["claude.md", "Higgsfield"])
        XCTAssertEqual(d, .accept("please open claude.md and check Higgsfield"),
                       "A translation that preserves every spoken term verbatim is accepted")
    }

    func testJargonGuardOnlyRequiresTermsThatWereActuallySpoken() {
        // "Kubernetes" is in the must-survive set but never appeared in the input, so
        // its absence from the output must NOT trip the guard.
        let d = OutputTranslator.decideOutput(
            input: "das ist ein ganz normaler satz",
            output: "this is a completely normal sentence",
            target: "en", mustSurvive: ["Kubernetes", "Higgsfield"])
        XCTAssertEqual(d, .accept("this is a completely normal sentence"))
    }

    func testJargonGuardIsCaseInsensitive() {
        // The term survives with different casing — still counts as surviving.
        let d = OutputTranslator.decideOutput(
            input: "prüfe higgsfield jetzt bitte",
            output: "check Higgsfield now please",
            target: "en", mustSurvive: ["Higgsfield"])
        XCTAssertEqual(d, .accept("check Higgsfield now please"))
    }

    func testDecideRejectsEmptyModelOutput() {
        let d = OutputTranslator.decideOutput(
            input: "das ist ein satz", output: "   ", target: "en", mustSurvive: [])
        XCTAssertEqual(d, .fallback(reason: "empty"))
    }

    // MARK: - translate(): end-to-end fallback via a stub summarizer (no model)

    func testTranslateSkipsModelWhenAlreadyTarget() async {
        // Guard (d): the stub must never be called, and translated == false.
        let stub = CountingSummarizer(reply: "SHOULD NOT BE USED")
        let (text, translated) = await OutputTranslator.translate(
            "this is already a fine english sentence",
            to: "en", inputCode: "en-US", summarizer: stub)
        XCTAssertEqual(text, "this is already a fine english sentence")
        XCTAssertFalse(translated)
        XCTAssertEqual(stub.calls, 0, "guard (d) must short-circuit before the model")
    }

    func testTranslateAppliesAGoodTranslation() async {
        let stub = CountingSummarizer(reply: "please open the file now")
        let (text, translated) = await OutputTranslator.translate(
            "bitte öffne die datei jetzt",
            to: "en", inputCode: "de-DE", summarizer: stub)
        XCTAssertEqual(text, "please open the file now")
        XCTAssertTrue(translated, "a guard-cleared translation reports translated == true")
        XCTAssertEqual(stub.calls, 1)
    }

    func testTranslateFallsBackToOriginalOnRefusal() async {
        let stub = CountingSummarizer(
            reply: "I cannot comply with this request; it is against my guidelines.")
        let original = "bitte öffne die datei jetzt sofort"
        let (text, translated) = await OutputTranslator.translate(
            original, to: "en", inputCode: "de-DE", summarizer: stub)
        XCTAssertEqual(text, original, "a refusal falls back to the SPOKEN text, never the refusal")
        XCTAssertFalse(translated, "no learn-from-edits arming when we didn't translate")
    }

    func testTranslateFallsBackWhenModelReturnsNil() async {
        // Model unavailable / produced nothing → insert as spoken, translated == false.
        let stub = CountingSummarizer(reply: nil)
        let original = "bitte öffne die datei jetzt sofort noch einmal"
        let (text, translated) = await OutputTranslator.translate(
            original, to: "en", inputCode: "de-DE", summarizer: stub)
        XCTAssertEqual(text, original)
        XCTAssertFalse(translated)
    }

    func testTranslateFallsBackWhenJargonLostEndToEnd() async {
        let stub = CountingSummarizer(reply: "please open cloud em dee and check the Higgs field")
        let original = "bitte öffne claude.md und prüfe Higgsfield sofort"
        let (text, translated) = await OutputTranslator.translate(
            original, to: "en", inputCode: "de-DE",
            mustSurvive: ["claude.md", "Higgsfield"], summarizer: stub)
        XCTAssertEqual(text, original, "mangled jargon ⇒ keep the exact spoken text")
        XCTAssertFalse(translated)
    }

    // MARK: - AppProfile.outputLanguageCode sparse-override contract

    @MainActor
    func testOutputLanguageResolvesNilByDefault() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let target = TargetApp(bundleID: "com.no.profile", name: "None", category: .browser)
        let resolved = store.resolve(for: target, settings: settings)
        XCTAssertNil(resolved.outputLanguageCode,
                     "An app with no rule inserts as spoken — no translation for anyone who hasn't set it")
    }

    @MainActor
    func testOutputLanguageResolvesWhenSet() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.tinyspeck.slackmacgap.\(UUID().uuidString)"
        store.upsert(AppProfile(bundleID: bundleID, displayName: "Slack", outputLanguageCode: "en"))

        let resolved = store.resolve(
            for: TargetApp(bundleID: bundleID, name: "Slack", category: .chat), settings: settings)
        XCTAssertEqual(resolved.outputLanguageCode, "en")

        // Scoped by bundle id — a different app is unaffected.
        let other = store.resolve(
            for: TargetApp(bundleID: "com.other", name: "Other", category: .chat), settings: settings)
        XCTAssertNil(other.outputLanguageCode)
        store.remove(bundleID: bundleID)
    }

    @MainActor
    func testEmptyOutputLanguageResolvesToNil() {
        // A stored "" (e.g. an old/edge write) must resolve to nil, not a no-op
        // translate to an empty target.
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.empty.\(UUID().uuidString)"
        // Carry another real override so the profile isn't dropped as empty.
        store.upsert(AppProfile(bundleID: bundleID, displayName: "App",
                                insertionMode: .type, outputLanguageCode: ""))
        let resolved = store.resolve(
            for: TargetApp(bundleID: bundleID, name: "App", category: .other), settings: settings)
        XCTAssertNil(resolved.outputLanguageCode, "an empty code is not an override")
        store.remove(bundleID: bundleID)
    }

    func testOutputLanguageOnlyProfileIsNotEmpty() {
        let p = AppProfile(bundleID: "com.app", displayName: "App", outputLanguageCode: "en")
        XCTAssertFalse(p.isEmpty, "a profile carrying only an output language is a real override")

        // nil / "" are no-ops and must still read as empty.
        XCTAssertTrue(AppProfile(bundleID: "com.app", displayName: "App", outputLanguageCode: "").isEmpty,
                      "an empty output language overrides nothing")
        XCTAssertTrue(AppProfile(bundleID: "com.app", displayName: "App").isEmpty,
                      "an unset output language overrides nothing")
    }

    func testOutputLanguageSurvivesSparseDecodeOfOldProfilesJSON() throws {
        // A pre-E8 profile with no outputLanguageCode key decodes cleanly (absent ⇒ nil).
        let oldJSON = Data("""
        { "com.apple.Terminal": { "bundleID": "com.apple.Terminal", "displayName": "Terminal", "insertionMode": "type" } }
        """.utf8)
        let oldDecoded = try JSONDecoder().decode([String: AppProfile].self, from: oldJSON)
        XCTAssertNil(oldDecoded["com.apple.Terminal"]?.outputLanguageCode,
                     "a pre-E8 profile decodes to nil, not a failure")

        // A sparse profile carrying only outputLanguageCode round-trips.
        let sparseJSON = Data("""
        { "com.tinyspeck.slackmacgap": { "bundleID": "com.tinyspeck.slackmacgap", "displayName": "Slack", "outputLanguageCode": "en" } }
        """.utf8)
        let sparseDecoded = try JSONDecoder().decode([String: AppProfile].self, from: sparseJSON)
        let p = try XCTUnwrap(sparseDecoded["com.tinyspeck.slackmacgap"])
        XCTAssertEqual(p.outputLanguageCode, "en", "the output language survives a sparse decode")
        XCTAssertFalse(p.isEmpty)
        XCTAssertNil(p.cleanupStyle, "no other field is invented by the decode")

        // And it must re-encode + decode back to the same value (round-trip when present).
        let reencoded = try JSONEncoder().encode(p)
        let roundTripped = try JSONDecoder().decode(AppProfile.self, from: reencoded)
        XCTAssertEqual(roundTripped.outputLanguageCode, "en")
    }
}

/// A stub `Summarizer` that returns a fixed reply and counts its calls, so the
/// `translate` guards can be exercised without Foundation Models.
private final class CountingSummarizer: Summarizer, @unchecked Sendable {
    static var isAvailable: Bool { true }
    let requiresNetwork = false
    private let reply: String?
    private(set) var calls = 0

    init(reply: String?) { self.reply = reply }

    func generate(instructions: String, input: String) async -> String? {
        calls += 1
        return reply
    }
}
