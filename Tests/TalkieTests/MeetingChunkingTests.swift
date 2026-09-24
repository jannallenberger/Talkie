import XCTest
@testable import Talkie

/// A single-speaker meeting transcript renders as ONE line of prose. The chunker
/// used to pack by lines only, sending a whole 16k-char meeting as one excerpt that
/// overflowed the model's window again and again (402 s → 19 s once fixed).
final class MeetingChunkingTests: XCTestCase {
    private func prose(sentences n: Int) -> String {
        (0..<n).map { "Das ist Satz Nummer \($0) im Meeting und er ist nicht besonders lang." }
            .joined(separator: " ")
    }

    func testNewlineFreeTranscriptIsSplitIntoBoundedChunks() {
        let text = prose(sentences: 250)          // ~17k chars, no newlines
        XCTAssertFalse(text.contains("\n"))
        let chunks = MeetingSummarizer.chunk(text, maxChars: 4000, maxChunks: 16)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 4000 }, chunks.map(\.count).description)
    }

    func testSplitsAtSentenceEnds() {
        let chunks = MeetingSummarizer.chunk(prose(sentences: 250), maxChars: 4000, maxChunks: 16)
        for chunk in chunks.dropLast() {
            XCTAssertTrue(chunk.hasSuffix("."), "a chunk should end on a sentence: …\(chunk.suffix(20))")
        }
    }

    func testNothingIsLost() {
        let text = prose(sentences: 250)
        let chunks = MeetingSummarizer.chunk(text, maxChars: 4000, maxChunks: 16)
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " ").count,
                       text.split(separator: " ").count)
    }

    func testFallsBackToSpacesWithoutSentenceEnds() {
        let text = Array(repeating: "wort", count: 3000).joined(separator: " ")   // 15k chars, no periods
        let pieces = MeetingSummarizer.splitLongLine(text, size: 4000)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 4000 })
        XCTAssertTrue(pieces.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        XCTAssertEqual(pieces.joined(separator: " "), text)
    }

    func testShortLinesAreStillPackedTogether() {
        let text = (0..<10).map { "Me: kurze Zeile \($0)" }.joined(separator: "\n")
        XCTAssertEqual(MeetingSummarizer.chunk(text, maxChars: 4000, maxChunks: 16), [text])
    }
}
