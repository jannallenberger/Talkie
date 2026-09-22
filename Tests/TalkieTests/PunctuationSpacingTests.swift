import XCTest
@testable import Talkie

final class PunctuationSpacingTests: XCTestCase {
    func testRemovesSpaceBeforeClosingMarks() {
        XCTAssertEqual(SentenceFlow.tightenPunctuationSpacing("dann kommt da was raus . Und"),
                       "dann kommt da was raus. Und")
        XCTAssertEqual(SentenceFlow.tightenPunctuationSpacing("starten will , dann"), "starten will, dann")
        XCTAssertEqual(SentenceFlow.tightenPunctuationSpacing("einen PullRequest aufmachen ?"),
                       "einen PullRequest aufmachen?")
        XCTAssertEqual(SentenceFlow.tightenPunctuationSpacing("damit du weißt , wie"), "damit du weißt, wie")
    }

    func testLeavesLegitimateSpacingAlone() {
        // Ellipsis, already-tight text, a colon inside a time, a spaced dash.
        // (Terminals/editors skip this pass entirely, so "ls ." never reaches it.)
        for s in ["Warte ... und dann", "Version 2.0, danach", "Zeit: 3:30 Uhr", "a - b"] {
            XCTAssertEqual(SentenceFlow.tightenPunctuationSpacing(s), s, s)
        }
    }

    func testIdempotent() {
        let once = SentenceFlow.tightenPunctuationSpacing("raus . Und , dann ?")
        XCTAssertEqual(SentenceFlow.tightenPunctuationSpacing(once), once)
    }

    func testDropsMidSentencePausePeriod() {
        XCTAssertEqual(SentenceFlow.dropMidSentencePeriods("dass die Wörter bitte auf einmal. gepastet werden."),
                       "dass die Wörter bitte auf einmal gepastet werden.")
        XCTAssertEqual(SentenceFlow.dropMidSentencePeriods("I think we should. refactor it."),
                       "I think we should refactor it.")
    }

    func testKeepsRealBoundariesAndAbbreviations() {
        for s in ["Das ist gut. Und dann weiter.",          // capitalized next sentence
                  "Wir brauchen z. B. das Log.",             // z. B.
                  "Das kostet ca. drei Euro.",               // ca.
                  "Äpfel, Birnen usw. sind da.",             // usw.
                  "Tools etc. and more.",                    // etc.
                  "mit iOS 26.5 hat Apple",
                  "Das ist neu. iPhone ist toll.",           // lowercase brand starts a sentence
                  "Das Update ist fertig. macOS läuft.",
                  "Der Shop ist online. eBay folgt."] {                // no space after the dot
            XCTAssertEqual(SentenceFlow.dropMidSentencePeriods(s), s, s)
        }
    }

    func testNicheCorrectorIsOffByDefault() {
        let key = Dev.nicheCorrectorKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Dev.nicheCorrector)
    }
}
