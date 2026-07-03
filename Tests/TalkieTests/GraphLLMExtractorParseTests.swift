import XCTest
@testable import Talkie

/// Pure-parse tests for `GraphLLMExtractor.parse` — the Stage-2 LLM extractor's
/// defensive `KIND|surface` parser. `parse` is a `static` pure function, so the
/// whole table runs with no live model, no disk, no actor. These lock the
/// grammar the finalize wiring (F3) depends on: well-formed records land as
/// candidates, malformed lines are dropped (never sink the batch), commitment
/// clauses keep everything after the first pipe, ORG folds to `.project`,
/// duplicates collapse case-insensitively, and the `maxCandidates` cap holds.
final class GraphLLMExtractorParseTests: XCTestCase {

    /// Convenience: the (kind, displayName) pairs a response parses to.
    private func pairs(_ response: String) -> [(EntityKind, String)] {
        GraphLLMExtractor.parse(response).map { ($0.kind, $0.displayName) }
    }

    // MARK: Well-formed records

    func testWellFormedRecordsParseToEachKind() {
        let out = GraphLLMExtractor.parse("""
        PERSON|Sarah Chen
        PROJECT|Talkie
        TERM|map-reduce
        COMMITMENT|I'll send the deck Friday
        """)
        XCTAssertEqual(out.count, 4, "one candidate per well-formed line")
        XCTAssertEqual(out[0].kind, .person)
        XCTAssertEqual(out[0].displayName, "Sarah Chen")
        XCTAssertEqual(out[1].kind, .project)
        XCTAssertEqual(out[1].displayName, "Talkie")
        XCTAssertEqual(out[2].kind, .term)
        XCTAssertEqual(out[2].displayName, "map-reduce")
        XCTAssertEqual(out[3].kind, .commitment)
        XCTAssertEqual(out[3].displayName, "I'll send the deck Friday")
    }

    func testKindTokenIsCaseInsensitiveAndTrimmed() {
        let out = pairs("  person | Alex \n\tCOMMITMENT|follow up with Sam")
        XCTAssertEqual(out.count, 2, "lowercase/whitespace-padded kinds still parse: \(out)")
        XCTAssertEqual(out[0].0, .person)
        XCTAssertEqual(out[0].1, "Alex", "surface form is trimmed")
        XCTAssertEqual(out[1].0, .commitment)
    }

    // MARK: Malformed lines are dropped, batch survives

    func testMalformedLinesDroppedButValidLinesKept() {
        let out = pairs("""
        this line has no pipe
        PERSON|Jordan
        UNKNOWNKIND|whatever
        PERSON|
        |orphan surface
        TERM|Swift 6
        """)
        // Only the two valid records survive; the four malformed lines are dropped
        // silently rather than sinking the whole batch.
        XCTAssertEqual(out.count, 2, "got \(out)")
        XCTAssertEqual(out[0].0, .person)
        XCTAssertEqual(out[0].1, "Jordan")
        XCTAssertEqual(out[1].0, .term)
        XCTAssertEqual(out[1].1, "Swift 6")
    }

    func testEmptyAndWhitespaceResponseParsesToNothing() {
        XCTAssertTrue(GraphLLMExtractor.parse("").isEmpty)
        XCTAssertTrue(GraphLLMExtractor.parse("   \n\t \n").isEmpty)
    }

    func testProseOnlyResponseParsesToNothing() {
        // The model occasionally ignores the grammar and writes a sentence; none of
        // it should leak into the graph.
        XCTAssertTrue(GraphLLMExtractor.parse(
            "Sure! Here are the entities I found in the meeting transcript."
        ).isEmpty, "prose without pipe records must yield no candidates")
    }

    // MARK: Commitments keep everything after the FIRST pipe

    func testCommitmentKeepsTextAfterFirstPipeOnly() {
        // A commitment clause may itself contain a pipe / delimiter; the split is on
        // the FIRST pipe only, so the whole clause is preserved for commitments.
        let out = GraphLLMExtractor.parse("COMMITMENT|ship v2 | then tell Sarah")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .commitment)
        XCTAssertEqual(out[0].displayName, "ship v2 | then tell Sarah",
                       "commitments keep everything after the first pipe: \(out[0].displayName)")
    }

    func testNonCommitmentDropsTailAfterSecondaryPipeOrDash() {
        // For names/terms the extractor keeps only the head, dropping a trailing
        // "| extra" or " - description" the model sometimes appends.
        let out = pairs("""
        PROJECT|Coralate - the PM tool
        TERM|CRDT | conflict-free replicated data type
        """)
        XCTAssertEqual(out.count, 2, "got \(out)")
        XCTAssertEqual(out[0].1, "Coralate", "dash-tail stripped for a project: \(out[0].1)")
        XCTAssertEqual(out[1].1, "CRDT", "secondary-pipe tail stripped for a term: \(out[1].1)")
    }

    // MARK: ORG / synonyms fold to .project

    func testOrgAndSynonymKindsFoldToProject() {
        // EntityKind has no `.organization`; ORG/ORGANIZATION/COMPANY/PRODUCT/CODEBASE
        // all fold into `.project` (the closest "thing you work on / with").
        for token in ["ORG", "ORGANIZATION", "COMPANY", "PRODUCT", "CODEBASE"] {
            let out = GraphLLMExtractor.parse("\(token)|Acme")
            XCTAssertEqual(out.count, 1, "\(token) should parse")
            XCTAssertEqual(out[0].kind, .project, "\(token) must fold to .project")
            XCTAssertEqual(out[0].displayName, "Acme")
        }
    }

    func testKindSynonymsMapToCanonicalKinds() {
        XCTAssertEqual(GraphLLMExtractor.parse("PEOPLE|Dana").first?.kind, .person)
        XCTAssertEqual(GraphLLMExtractor.parse("TOPIC|latency").first?.kind, .term)
        XCTAssertEqual(GraphLLMExtractor.parse("VOCAB|squircle").first?.kind, .term)
        XCTAssertEqual(GraphLLMExtractor.parse("ACTION|email Pat").first?.kind, .commitment)
        XCTAssertEqual(GraphLLMExtractor.parse("TASK|book room").first?.kind, .commitment)
        XCTAssertEqual(GraphLLMExtractor.parse("TODO|renew cert").first?.kind, .commitment)
    }

    // MARK: Dedupe (case-insensitive, per kind)

    func testDuplicatesCollapseCaseInsensitivelyPerKind() {
        let out = pairs("""
        PERSON|Sarah
        PERSON|sarah
        PERSON|SARAH
        TERM|Sarah
        """)
        // The three PERSON|Sarah variants collapse to one; TERM|Sarah is a different
        // kind, so it survives independently.
        XCTAssertEqual(out.count, 2, "got \(out)")
        XCTAssertEqual(out[0].0, .person)
        XCTAssertEqual(out[0].1, "Sarah", "first-seen surface form is kept")
        XCTAssertEqual(out[1].0, .term)
        XCTAssertEqual(out[1].1, "Sarah")
    }

    // MARK: maxCandidates cap

    func testResponseIsCappedAtMaxCandidates() {
        // 100 distinct valid records; the parser must stop at its defensive cap so a
        // runaway model can't flood the graph.
        let lines = (0..<100).map { "TERM|term-\($0)" }.joined(separator: "\n")
        let out = GraphLLMExtractor.parse(lines)
        XCTAssertEqual(out.count, 60, "must cap at maxCandidates (60), got \(out.count)")
        XCTAssertEqual(out.first?.displayName, "term-0", "cap keeps the earliest records")
        XCTAssertEqual(out.last?.displayName, "term-59")
    }

    // MARK: Surface acceptance bounds

    func testOverlongSurfacesRejectedPerKind() {
        // Names/terms cap at 80 chars; commitments at 200. Anything longer is a
        // likely mis-parse and is dropped.
        let longName = String(repeating: "a", count: 81)
        XCTAssertTrue(GraphLLMExtractor.parse("TERM|\(longName)").isEmpty,
                      "an 81-char term must be rejected")
        let longCommitment = String(repeating: "b", count: 201)
        XCTAssertTrue(GraphLLMExtractor.parse("COMMITMENT|\(longCommitment)").isEmpty,
                      "a 201-char commitment must be rejected")
        // A too-short commitment (<4 chars) is also rejected.
        XCTAssertTrue(GraphLLMExtractor.parse("COMMITMENT|go").isEmpty,
                      "a 2-char commitment must be rejected")
    }

    func testLeadingBulletAndWrappingQuotesStripped() {
        let out = pairs("""
        PERSON|- Morgan
        TERM|"backpressure"
        """)
        XCTAssertEqual(out.count, 2, "got \(out)")
        XCTAssertEqual(out[0].1, "Morgan", "leading bullet stripped: \(out[0].1)")
        XCTAssertEqual(out[1].1, "backpressure", "wrapping quotes stripped: \(out[1].1)")
    }
}
