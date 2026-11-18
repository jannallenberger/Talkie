import XCTest
@testable import Talkie

final class ActivationKeyTests: XCTestCase {
    // MARK: Migration and encode/decode

    func testAllFiveLegacyValuesMigrateLosslessly() {
        let legacy: [(String, ActivationKey)] = [
            ("rightOption", .rightOption), ("leftOption", .leftOption),
            ("rightControl", .rightControl), ("mouseButton4", .mouseButton4),
            ("mouseButton5", .mouseButton5),
        ]
        for (raw, expected) in legacy {
            XCTAssertEqual(ActivationKey(rawValue: raw), expected, raw)
            XCTAssertEqual(expected.rawValue, raw, "legacy key must keep its stored string")
        }
        XCTAssertEqual(ActivationKey.rightOption.code, 61)
        XCTAssertEqual(ActivationKey.leftOption.code, 58)
        XCTAssertEqual(ActivationKey.rightControl.code, 62)
        XCTAssertEqual(ActivationKey.mouseButton4.code, 3)
        XCTAssertEqual(ActivationKey.mouseButton5.code, 4)
    }

    func testRoundTripEveryAcceptableKey() throws {
        var keys: [ActivationKey] = ActivationKey.modifiers.map { .init(kind: .modifier, code: $0.keyCode) }
        keys += ActivationKey.functionKeys.keys.map { .init(kind: .function, code: $0) }
        keys += [3, 4, 5, 8].map { .init(kind: .mouse, code: $0) }
        XCTAssertEqual(keys.count, 8 + 20 + 4)
        for key in keys {
            XCTAssertEqual(ActivationKey(rawValue: key.rawValue), key)
            let data = try JSONEncoder().encode([key])
            XCTAssertEqual(try JSONDecoder().decode([ActivationKey].self, from: data), [key])
        }
    }

    func testGarbageRawValuesAreRejected() {
        for raw in ["", "fn", "modifier:9", "function:0", "mouse:2", "mouse:x", "key:61:1"] {
            XCTAssertNil(ActivationKey(rawValue: raw), raw)
        }
    }

    // MARK: Classification

    private func accepted(_ i: ActivationKey.RecorderInput) -> (ActivationKey, String?)? {
        if case .accepted(let k, let w) = ActivationKey.evaluate(i) { return (k, w) }
        return nil
    }
    private func isRefused(_ i: ActivationKey.RecorderInput) -> Bool {
        if case .refused(let r) = ActivationKey.evaluate(i) { return !r.isEmpty }
        return false
    }

    func testTypingKeysAreRefused() {
        // letters A,S,Z, digits 1,0, Space, Return, Tab, arrows, Delete
        for code in [0, 1, 6, 18, 29, 49, 36, 48, 123, 124, 125, 126, 51] {
            XCTAssertTrue(isRefused(.keyDown(keyCode: code)), "\(code)")
        }
    }

    func testFnGlobeAndCapsLockAreRefused() {
        XCTAssertTrue(isRefused(.flagsChanged(keyCode: 63, rawFlags: ActivationKey.secondaryFnFlag)))
        XCTAssertEqual(ActivationKey.evaluate(.flagsChanged(keyCode: 63, rawFlags: 0)), .ignored)
        XCTAssertTrue(isRefused(.keyDown(keyCode: 179)))
        XCTAssertTrue(isRefused(.flagsChanged(keyCode: 57, rawFlags: 0x10000)))
    }

    func testEscapeCancels() {
        XCTAssertEqual(ActivationKey.evaluate(.keyDown(keyCode: 53)), .cancelled)
    }

    func testFunctionKeysF1ToF20Accepted() {
        XCTAssertEqual(ActivationKey.functionKeys.count, 20)
        for (code, n) in ActivationKey.functionKeys {
            let (k, w) = accepted(.keyDown(keyCode: code))!
            XCTAssertEqual(k.displayName, "F\(n)")
            XCTAssertNil(w)
        }
    }

    func testModifiersAcceptedAndWarningsOnlyForLeftCommandAndShift() {
        for m in ActivationKey.modifiers {
            let (k, w) = accepted(.flagsChanged(keyCode: m.keyCode, rawFlags: m.deviceBit))!
            XCTAssertEqual(k.code, m.keyCode)
            XCTAssertEqual(w != nil, [56, 60, 55].contains(m.keyCode), m.name)
            // the release of the same key is ignored
            XCTAssertEqual(ActivationKey.evaluate(.flagsChanged(keyCode: m.keyCode, rawFlags: 0)), .ignored)
        }
    }

    func testMouseButtons() {
        for b in 0...2 { XCTAssertTrue(isRefused(.mouseDown(button: b)), "\(b)") }
        for b in 3...7 { XCTAssertEqual(accepted(.mouseDown(button: b))?.0, ActivationKey(kind: .mouse, code: b)) }
    }

    // MARK: Display names

    func testDisplayNames() {
        XCTAssertEqual(ActivationKey.rightOption.displayName, "Right ⌥ Option")
        XCTAssertEqual(ActivationKey.mouseButton4.displayName, "Mouse Button 4 (side)")
        XCTAssertEqual(ActivationKey(kind: .mouse, code: 5).displayName, "Mouse Button 6")
        XCTAssertEqual(ActivationKey(kind: .modifier, code: 54).displayName, "Right ⌘ Command")
        XCTAssertEqual(ActivationKey(kind: .function, code: 105).displayName, "F13")
        XCTAssertNotNil(ActivationKey.mouseButton4.symbolName)
        XCTAssertNil(ActivationKey.rightOption.symbolName)
    }

    // MARK: Edge extraction (hold / release / auto-repeat)

    func testModifierEdgesUseSideSpecificBits() {
        let right = ActivationKey.rightOption
        XCTAssertEqual(right.edge(for: .flagsChanged(keyCode: 61, rawFlags: 0x40)), true)
        XCTAssertEqual(right.edge(for: .flagsChanged(keyCode: 61, rawFlags: 0)), false)
        XCTAssertNil(right.edge(for: .flagsChanged(keyCode: 58, rawFlags: 0x20)))
        // other side still held while ours releases
        XCTAssertEqual(right.edge(for: .flagsChanged(keyCode: 61, rawFlags: 0x20)), false)
        XCTAssertNil(right.edge(for: .keyDown(keyCode: 61, isAutorepeat: false)))
    }

    func testFunctionKeyAutoRepeatDoesNotRetrigger() {
        let f13 = ActivationKey(kind: .function, code: 105)
        XCTAssertEqual(f13.edge(for: .keyDown(keyCode: 105, isAutorepeat: false)), true)
        XCTAssertNil(f13.edge(for: .keyDown(keyCode: 105, isAutorepeat: true)))
        XCTAssertNil(f13.edge(for: .keyDown(keyCode: 107, isAutorepeat: false)))
        XCTAssertEqual(f13.edge(for: .keyUp(keyCode: 105)), false)
        XCTAssertNil(f13.edge(for: .flagsChanged(keyCode: 105, rawFlags: 0)))
    }

    func testMouseEdges() {
        let b6 = ActivationKey(kind: .mouse, code: 5)
        XCTAssertEqual(b6.edge(for: .mouseDown(button: 5)), true)
        XCTAssertEqual(b6.edge(for: .mouseUp(button: 5)), false)
        XCTAssertNil(b6.edge(for: .mouseDown(button: 3)))
    }

    func testFunctionKeyDrivesGestureLikeAnyOtherTrigger() {
        var g = ActivationGesture()
        let f = ActivationKey(kind: .function, code: 122)
        var t = 0.0
        func feed(_ e: ActivationKey.Event) -> ActivationGesture.Action {
            guard let down = f.edge(for: e) else { return .none }
            t += 0.01
            return down ? g.keyDown(at: t) : g.keyUp(at: t)
        }
        XCTAssertNotEqual(feed(.keyDown(keyCode: 122, isAutorepeat: false)), .none)
        XCTAssertEqual(feed(.keyDown(keyCode: 122, isAutorepeat: true)), .none)
        XCTAssertEqual(feed(.keyUp(keyCode: 122)), .end)
    }

    // MARK: Paste-last chord never collides

    func testPasteShortcutAvoidsActivationModifier() {
        XCTAssertEqual(ActivationKey.rightOption.pasteShortcut.secondary, .control)
        XCTAssertEqual(ActivationKey(kind: .modifier, code: 59).pasteShortcut.secondary, .option)
        XCTAssertEqual(ActivationKey.rightControl.pasteShortcut.secondary, .option)
        XCTAssertEqual(ActivationKey(kind: .function, code: 122).pasteShortcut.display, "⌃⌘V")
    }
}
