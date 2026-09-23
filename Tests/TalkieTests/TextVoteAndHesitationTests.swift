import XCTest
@testable import Talkie

/// The text vote (the live model's own words decide the language when they clearly
/// read as another spoken language) and the `#um` hesitation-marker stripper. All
/// fixtures are real raw transcripts from the debug log.
final class TextVoteAndHesitationTests: XCTestCase {
    private let spoken = ["de-DE", "en-GB", "en-US"]

    // MARK: - textVote

    /// 2026-09-23: English speech decoded by the GERMAN model. The words read as
    /// English, so the vote switches — the case the acoustic margins kept missing.
    func testGermanModelOnEnglishSpeechVotesEnglish() {
        let raw = "But please tell me exactly how bevel and exist or barrable are able to have such a Speed for new.s without aarable. I mean, there is not always black and white"
        XCTAssertEqual(LanguageDetector.textVote(raw, spokenLanguages: spoken, currentCode: "de"), "en-GB")
    }

    /// The pill text of a German-model session on English speech, 8 words in.
    func testEightWordsAreEnoughForAClearCase() {
        let raw = "Alright Bright up prompt for another Session to"
        XCTAssertEqual(LanguageDetector.textVote(raw, spokenLanguages: spoken, currentCode: "de"), "en-GB")
    }

    /// German speech in a German session: words read German — no vote (the current
    /// language is never "confirmed" by text; the acoustic check decides).
    func testGermanSpeechCastsNoVote() {
        let raw = "Okay, ich werde das Ganze jetzt noch mal kurz testen und werde gucken, inwieweit die Transkription sich verbessert hat"
        XCTAssertNil(LanguageDetector.textVote(raw, spokenLanguages: spoken, currentCode: "de"))
    }

    /// German speech decoded by the ENGLISH model: the whole reads German → switch.
    func testEnglishModelOnGermanSpeechVotesGermanOnceItReadsGerman() {
        let raw = "I'm miss Momentein, I just know not the unter dietel video, existerien in reels, unter zetzen, auser dem, rich gene när bilder von Mansen Stendenhaden, wär wied, yeah. Um... Oh, Ansonsten, Wundie Profilag updated. No, yeah, I spent a friedman in posts, and dansten, wigman my, yeah, exact border, das, um, ich imma, ibitz, uh, Lastarias, on the road, ainland, soil, and Lastarias, ibitz, auch, das, mal, on the, kan, zebstein, shin, up, the, collaboration, anim mulanich. um, for the common videos on builder, beskanskeiden, bisen, you feel that the context, the context, student, handler, and sich. and that's what a very good fleck, so... um, And, um, as a debation, besion, bil dan, undanfleicht, or, kleiner, einseiler, alt information, mas, uh, biden, namme from Hendler is und so weit."
        XCTAssertEqual(LanguageDetector.textVote(raw, spokenLanguages: spoken, currentCode: "en"), "de-DE")
    }

    /// ...but its opening reads English — the reason text can't CONFIRM the current
    /// language, only vote for a switch.
    func testEnglishModelOnGermanSpeechOpeningCastsNoVote() {
        let raw = "I'm miss Momentein, I just know not the unter dietel video,"
        XCTAssertNil(LanguageDetector.textVote(raw, spokenLanguages: spoken, currentCode: "en"))
    }

    func testTooFewWordsCastNoVote() {
        XCTAssertNil(LanguageDetector.textVote("Please tell me exactly how this",
                                               spokenLanguages: spoken, currentCode: "de"))
    }

    func testSingleSpokenLanguageCastsNoVote() {
        XCTAssertNil(LanguageDetector.textVote("But please tell me exactly how this works for new users",
                                               spokenLanguages: ["de-DE"], currentCode: "de"))
    }

    /// A German dictation that quotes English stays German when the English model
    /// fits the audio worse; a genuine English dictation passes.
    func testAcousticConfirmation() {
        XCTAssertTrue(LanguageDetector.textVoteConfirmed(targetConfidence: 0.91, liveConfidence: 0.84))
        XCTAssertTrue(LanguageDetector.textVoteConfirmed(targetConfidence: 0.85, liveConfidence: 0.86))
        XCTAssertFalse(LanguageDetector.textVoteConfirmed(targetConfidence: 0.60, liveConfidence: 0.88))
        XCTAssertTrue(LanguageDetector.textVoteConfirmed(targetConfidence: 0.70, liveConfidence: nil))
    }

    // MARK: - HesitationMarkers

    func testStripsMarkerAfterComma() {
        XCTAssertEqual(HesitationMarkers.strip("Okay, #um is it possible that this will occur"),
                       "Okay, is it possible that this will occur")
    }

    func testStripsMarkerWithTrailingComma() {
        XCTAssertEqual(HesitationMarkers.strip("I think #um, we should ship it"), "I think we should ship it")
    }

    func testStripsLeadingAndCapitalisedMarker() {
        XCTAssertEqual(HesitationMarkers.strip("#Ah, so this works"), "so this works")
    }

    func testStripsBeforeSentencePunctuation() {
        XCTAssertEqual(HesitationMarkers.strip("that is it #um."), "that is it.")
    }

    func testStripsGermanHesitation() {
        XCTAssertEqual(HesitationMarkers.strip("Das ist #äh eigentlich gut"), "Das ist eigentlich gut")
    }

    /// The German word "um" (no marker) and real hashtags are dictated content.
    func testKeepsPlainUmAndHashtags() {
        XCTAssertEqual(HesitationMarkers.strip("Es geht um #launch und um Geld"), "Es geht um #launch und um Geld")
        XCTAssertEqual(HesitationMarkers.strip("#umbrella #umlaut"), "#umbrella #umlaut")
    }

    func testIsMarker() {
        XCTAssertTrue(HesitationMarkers.isMarker("#um"))
        XCTAssertTrue(HesitationMarkers.isMarker("#Ah,"))
        XCTAssertFalse(HesitationMarkers.isMarker("um"))
        XCTAssertFalse(HesitationMarkers.isMarker("#launch"))
    }
}
