import XCTest
@testable import Talkie

/// P1-07: live meeting export must not write UNESCAPED YAML front-matter from a
/// calendar/meeting title. `TalkieFolderDestination.render` builds the block
/// line-by-line, so a title carrying a YAML metachar — or a NEWLINE — could
/// terminate the value early and inject arbitrary keys (or a premature `---`).
/// These tests pin the escaped-renderer contract.
final class TalkieFolderDestinationTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(title: String,
                      frontMatter: [String: String] = [:],
                      body: String = "## Summary\n\nbody text") -> ExportableNote {
        ExportableNote(
            kind: .meeting,
            title: title,
            date: fixedDate,
            bodyMarkdown: body,
            frontMatter: frontMatter,
            suggestedFileName: "note.md"
        )
    }

    /// Splits a rendered note into (front-matter lines between the fences, body).
    private func frontMatterLines(_ rendered: String) -> [String] {
        let lines = rendered.components(separatedBy: "\n")
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else {
            XCTFail("rendered note had no closing front-matter fence:\n\(rendered)")
            return []
        }
        return Array(lines[1..<closing])
    }

    // MARK: Injection

    func testNewlineAndQuoteTitleCannotInjectFrontMatter() {
        let rendered = TalkieFolderDestination.render(
            note(title: "Sync: Q3 \"plan\"\ninjected: pwned")
        )

        // The whole title value — colon, quotes, AND the embedded newline — is
        // wrapped in a SINGLE double-quoted YAML scalar, with the inner quotes
        // backslash-escaped. The opening quote is on the `title:` line and the
        // matching closing quote only appears after `pwned`, so a YAML parser
        // folds the newline INTO the title value rather than starting a new key.
        XCTAssertTrue(
            rendered.contains("title: \"Sync: Q3 \\\"plan\\\"\ninjected: pwned\"\n"),
            "title was not safely quoted/escaped:\n\(rendered)"
        )

        // The `injected:` text is therefore NOT a real top-level front-matter key:
        // no physical line both begins with `injected:` AND ends the document line
        // without a closing quote — i.e. it never escaped the quoted scalar.
        // Concretely, the embedded newline must be immediately followed by
        // `injected: pwned"` (still inside the quotes), never a bare `injected:`.
        XCTAssertFalse(
            rendered.contains("\ninjected: pwned\n"),
            "the newline broke out of the title value and injected a key:\n\(rendered)"
        )

        // Quote-balance sanity: an even number of UNescaped double-quotes in the
        // front-matter region means every opening quote is closed — no dangling
        // scalar that could swallow or terminate later lines unexpectedly.
        let fmRegion = String(rendered.prefix(while: { $0 != "#" }))  // body has no `"` here
        let unescapedQuotes = fmRegion.replacingOccurrences(of: "\\\"", with: "").filter { $0 == "\"" }.count
        XCTAssertEqual(unescapedQuotes % 2, 0,
                       "unbalanced YAML quotes in front-matter:\n\(rendered)")
    }

    func testLeadingSpaceTitleIsQuoted() {
        let rendered = TalkieFolderDestination.render(note(title: " leading space"))
        let fm = frontMatterLines(rendered)
        XCTAssertEqual(fm.first, "title: \" leading space\"")
    }

    func testHashLeadingTitleIsQuoted() {
        let rendered = TalkieFolderDestination.render(note(title: "#standup notes"))
        let fm = frontMatterLines(rendered)
        XCTAssertEqual(fm.first, "title: \"#standup notes\"")
    }

    // MARK: Values

    func testScalarValueWithMetacharIsQuotedButArrayPassesThrough() {
        let rendered = TalkieFolderDestination.render(
            note(title: "Plain",
                 frontMatter: [
                    "participants": "[Me, Them]",   // producer-composed array literal
                    "source": "calendar: work",      // scalar with a metachar
                 ])
        )
        let fm = frontMatterLines(rendered)
        // Array literal is passed through untouched (no quoting).
        XCTAssertTrue(fm.contains("participants: [Me, Them]"),
                      "array literal was wrongly escaped:\n\(fm.joined(separator: "\n"))")
        // Scalar with a colon is quoted.
        XCTAssertTrue(fm.contains("source: \"calendar: work\""),
                      "scalar value with metachar was not quoted:\n\(fm.joined(separator: "\n"))")
    }

    // MARK: Body / regression

    func testPlainTitleStaysUnquotedAndBodyUnchanged() {
        let body = "## Summary\n\nAll good.\n\n## Transcript\n\nVerbatim."
        let rendered = TalkieFolderDestination.render(note(title: "Weekly Standup", body: body))
        let fm = frontMatterLines(rendered)

        // A metachar-free title is NOT quoted — byte-compat with the prior renderer.
        XCTAssertEqual(fm.first, "title: Weekly Standup")
        // Body is glued unchanged after the closing fence + single blank line.
        XCTAssertTrue(rendered.hasSuffix("---\n\n" + body),
                      "body was altered or re-spaced:\n\(rendered)")
    }
}
