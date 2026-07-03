import XCTest
@testable import Talkie

/// The pure `ioreg`-output parser behind the "name the secure-input culprit" HUD
/// (B3). `parseSecureInputPID` is the only piece of `SecureInputCulprit` that can
/// be exercised deterministically off-device — the IOKit read, the subprocess
/// fallback, and the PID→name lookup all depend on live machine state and are the
/// maker's (headless) manual matrix. Everything that could parse *wrong* lives in
/// this one pure function, so this is its whole contract: a well-formed line yields
/// the PID, an absent key yields nil, a zero value yields nil (nobody holds it), and
/// malformed lines yield nil rather than a bogus number.
///
/// The line format under test is exactly what `ioreg -l -d 1 -w 0` prints for the
/// holder property, with its leading indentation:
///
///     "kCGSSessionSecureInputPID" = 1234
@MainActor
final class SecureInputCulpritTests: XCTestCase {

    // MARK: Well-formed

    func testWellFormedLineYieldsPID() {
        let output = #"    "kCGSSessionSecureInputPID" = 1234"#
        XCTAssertEqual(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output), 1234,
            "the documented ioreg line must yield the exact PID to the right of the =")
    }

    func testPIDFoundAmongSurroundingRegistryLines() {
        // Realistic: the property sits inside a big IOHIDSystem property block.
        let output = """
              +-o IOHIDSystem  <class IOHIDSystem, id 0x100000abc, registered>
                {
                  "IOClass" = "IOHIDSystem"
                  "kCGSSessionSecureInputPID" = 5678
                  "HIDIdleTime" = 4200000000
                }
            """
        XCTAssertEqual(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output), 5678,
            "the parser must find the key line even embedded in the surrounding dump")
    }

    func testExtraWhitespaceAroundEqualsIsTolerated() {
        let output = #"        "kCGSSessionSecureInputPID"    =      42   "#
        XCTAssertEqual(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output), 42,
            "arbitrary spacing around the = and trailing spaces must not defeat the parse")
    }

    func testTabsAroundValueAreTolerated() {
        let output = "\t\"kCGSSessionSecureInputPID\"\t=\t99\t"
        XCTAssertEqual(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output), 99,
            "tab-separated ioreg output must parse the same as space-separated")
    }

    // MARK: Absent

    func testAbsentKeyYieldsNil() {
        let output = """
              "IOClass" = "IOHIDSystem"
              "HIDIdleTime" = 4200000000
            """
        XCTAssertNil(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output),
            "no secure-input key present means nobody holds it — must be nil, not 0")
    }

    func testEmptyOutputYieldsNil() {
        XCTAssertNil(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: ""),
            "empty ioreg output (e.g. the tool failed) must yield nil, never a default PID")
    }

    // MARK: Zero — the "nobody holds it" sentinel

    func testZeroPIDYieldsNil() {
        let output = #"    "kCGSSessionSecureInputPID" = 0"#
        XCTAssertNil(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output),
            "a PID of 0 is macOS's explicit 'no process holds secure input' — must be nil")
    }

    // MARK: Malformed — must degrade to nil, never a bogus number

    func testNonNumericValueYieldsNil() {
        let output = #"    "kCGSSessionSecureInputPID" = "notanumber""#
        XCTAssertNil(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output),
            "a non-integer right-hand side must yield nil, not a coerced value")
    }

    func testDictionaryValueYieldsNil() {
        // If the value ever renders as a brace-dictionary, the RHS starts with '{',
        // not a digit — the parser must reject it rather than invent a PID.
        let output = #"    "kCGSSessionSecureInputPID" = {"foo"=1}"#
        XCTAssertNil(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output),
            "a non-scalar value must not be mistaken for a PID")
    }

    func testKeyWithNoEqualsYieldsNil() {
        let output = #"    "kCGSSessionSecureInputPID""#
        XCTAssertNil(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output),
            "the key with no '=' assignment carries no PID and must yield nil")
    }

    func testKeyWithEmptyRHSYieldsNil() {
        let output = #"    "kCGSSessionSecureInputPID" = "#
        XCTAssertNil(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output),
            "an '=' with nothing after it must yield nil, not crash or default")
    }

    // MARK: Robustness

    func testFirstPositivePIDWinsAcrossLines() {
        // Defensive: if two matching lines ever appear, the first positive PID is
        // the answer (a later stray line can't override a real holder).
        let output = """
              "kCGSSessionSecureInputPID" = 314
              "kCGSSessionSecureInputPID" = 271
            """
        XCTAssertEqual(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output), 314,
            "the first positive PID must win over any subsequent duplicate line")
    }

    func testTrailingGarbageAfterNumberIsIgnored() {
        let output = #"    "kCGSSessionSecureInputPID" = 808 (stale)"#
        XCTAssertEqual(
            SecureInputCulprit.parseSecureInputPID(fromIORegOutput: output), 808,
            "the leading digit run is the PID; trailing tokens on the line are ignored")
    }
}
