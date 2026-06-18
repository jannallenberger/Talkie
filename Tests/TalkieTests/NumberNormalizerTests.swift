import XCTest
@testable import Talkie

/// Spoken-number inverse text normalization: version/decimal patterns always
/// convert; standalone cardinals convert only when > 9. English + German.
final class NumberNormalizerTests: XCTestCase {
    private func eq(_ input: String, _ expected: String,
                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NumberNormalizer.normalize(input), expected, file: file, line: line)
    }

    // MARK: Version / decimal patterns (always convert, any magnitude)

    func testVersionWordedBothSides() {
        eq("Seedance two point zero", "Seedance 2.0")
    }

    func testVersionDigitLeftWordRight() {
        eq("Seedance 2 point zero", "Seedance 2.0")
    }

    func testVersionDotKeyword() {
        eq("Seedance two dot zero", "Seedance 2.0")
    }

    func testVersionOhAsZero() {
        eq("version two point oh", "version 2.0")
    }

    func testDecimalConcatenatesFractionDigits() {
        eq("zero point seven five", "0.75")
    }

    func testDecimalPreservesLeadingZeroInFraction() {
        eq("two point zero five", "2.05")
    }

    func testDecimalPi() {
        eq("three point one four", "3.14")
    }

    func testFractionAsCardinal() {
        eq("Python three point twelve", "Python 3.12")
    }

    func testMultiWordIntegerPart() {
        eq("twenty two point five", "22.5")
    }

    func testSemverChain() {
        eq("two point zero point one", "2.0.1")
    }

    func testSemverChainAllDigits() {
        eq("one dot two dot three", "1.2.3")
    }

    func testIPAddressChain() {
        eq("192 dot 168 dot 0 dot 1", "192.168.0.1")
    }

    func testVersionKeepsSurroundingPunctuation() {
        eq("It's version two point zero.", "It's version 2.0.")
    }

    // MARK: German

    func testGermanVersionPunktIsDot() {
        eq("Seedance zwei punkt null", "Seedance 2.0")
    }

    func testGermanDecimalKommaIsComma() {
        eq("zwei komma fünf", "2,5")
    }

    func testGermanDecimalKommaFractionConcat() {
        eq("null komma sieben fünf", "0,75")
    }

    func testGermanCompoundStandalone() {
        eq("vierundzwanzig", "24")
    }

    func testGermanTeenStandalone() {
        eq("fünfzehn", "15")
    }

    func testGermanHundred() {
        eq("zweihundert", "200")
    }

    /// The >9 gate keeps the German indefinite article ("ein"/"eine" = 1) intact.
    func testGermanArticleNotConverted() {
        eq("ein Hund läuft", "ein Hund läuft")
    }

    func testGermanYearCompound() {
        eq("neunzehnhundertfünfundachtzig", "1985")
    }

    // MARK: Standalone cardinals > 9

    func testTensUnit() {
        eq("twenty four", "24")
    }

    func testTeen() {
        eq("fifteen people", "15 people")
    }

    func testExactlyTenConverts() {
        eq("ten", "10")
    }

    func testHundredsPhrase() {
        eq("one hundred twenty three", "123")
    }

    func testThousandsPhrase() {
        eq("two thousand twenty four", "2024")
    }

    func testTwoHundred() {
        eq("two hundred", "200")
    }

    // MARK: Standalone ≤ 9 stays spelled out

    func testFiveStaysSpelled() {
        eq("I need five of them", "I need five of them")
    }

    func testNineStaysSpelled() {
        eq("nine lives", "nine lives")
    }

    func testTimeStaysSpelled() {
        eq("see you at two", "see you at two")
    }

    func testExistingDigitUntouched() {
        eq("buy 5 apples", "buy 5 apples")
    }

    // MARK: Spoken years (century elided)

    func testYearTwentyTwentyFour() {
        eq("twenty twenty four", "2024")
    }

    func testYearNineteenEightyFive() {
        eq("nineteen eighty five", "1985")
    }

    func testYearTwentyOhFive() {
        eq("twenty oh five", "2005")
    }

    func testYearNineteenNinetyNine() {
        eq("nineteen ninety nine", "1999")
    }

    /// "twenty four" must read as the cardinal 24, NOT the year 2004.
    func testTensUnitIsNotAYear() {
        eq("twenty four", "24")
    }

    // MARK: Safety — no false positives

    func testPointAsNounUntouched() {
        eq("that is a good point", "that is a good point")
    }

    func testStrayUnitRunNotFused() {
        eq("five six", "five six")
    }

    /// A run must never be fused across a sentence boundary.
    func testNoCrossSentenceFusion() {
        eq("I have twenty. Four are left", "I have 20. Four are left")
    }

    func testPlainProseUnchanged() {
        eq("the quick brown fox", "the quick brown fox")
    }

    func testEmptyString() {
        eq("", "")
    }

    // MARK: Mixed

    func testVersionWithTrailingSmallNumber() {
        eq("Seedance two point zero beats version one", "Seedance 2.0 beats version one")
    }
}
