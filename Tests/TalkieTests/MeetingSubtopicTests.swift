import XCTest
@testable import Talkie

/// Pure-logic tests for the live-subtopic gating: response parsing and the
/// confidence + hysteresis step that prevents the pill from ever misrepresenting
/// what's being discussed.
final class MeetingSubtopicTests: XCTestCase {
    private typealias Engine = MeetingSubtopicEngine
    private typealias Gate = MeetingSubtopicEngine.GateState

    // MARK: parse

    func testParseHighConfidenceTopic() {
        let (topic, high) = Engine.parse("TOPIC|Budget planning\nCONFIDENCE|HIGH")
        XCTAssertEqual(topic, "Budget planning")
        XCTAssertTrue(high)
    }

    func testParseNoneIsNilTopic() {
        let (topic, high) = Engine.parse("TOPIC|NONE\nCONFIDENCE|LOW")
        XCTAssertNil(topic)
        XCTAssertFalse(high)
    }

    func testParseToleratesNoiseQuotesAndSpacing() {
        let (topic, high) = Engine.parse("here you go:\nTOPIC| \"Q3 roadmap\" \nCONFIDENCE|  high \ntrailing junk")
        XCTAssertEqual(topic, "Q3 roadmap")
        XCTAssertTrue(high)
    }

    func testParseRejectsRunawayTopic() {
        let (topic, _) = Engine.parse(
            "TOPIC|this is a far too long topic that clearly exceeds the word and character bounds\nCONFIDENCE|HIGH")
        XCTAssertNil(topic, "a sentence-length topic is treated as no usable topic")
    }

    // MARK: step — confidence + hysteresis

    func testNewTopicNeedsTwoConsecutiveHighsToShow() {
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)
        XCTAssertNil(g.accepted, "one high alone never shows")
        g = Engine.step(g, topic: "Budget", high: true)
        XCTAssertEqual(g.accepted, "Budget", "two consecutive highs accept it")
    }

    func testLowConfidenceNeverChangesShownTopic() {
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)
        g = Engine.step(g, topic: "Budget", high: true)   // accepted: Budget
        g = Engine.step(g, topic: "Hiring", high: false)  // a miss
        XCTAssertEqual(g.accepted, "Budget", "low confidence holds the current topic")
    }

    func testSwitchingTopicsRequiresSustainedHighs() {
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)
        g = Engine.step(g, topic: "Budget", high: true)   // Budget shown
        g = Engine.step(g, topic: "Hiring", high: true)
        XCTAssertEqual(g.accepted, "Budget", "a single high for a new topic doesn't switch")
        g = Engine.step(g, topic: "Hiring", high: true)
        XCTAssertEqual(g.accepted, "Hiring", "sustained → switch")
    }

    func testFlipFloppingTopicsNeverSwitch() {
        var g = Gate()
        g = Engine.step(g, topic: "A", high: true)
        g = Engine.step(g, topic: "B", high: true)
        g = Engine.step(g, topic: "A", high: true)
        XCTAssertNil(g.accepted, "alternating candidates never reach a 2-streak")
    }

    func testNoneNeverAccepted() {
        var g = Gate()
        g = Engine.step(g, topic: nil, high: true)
        g = Engine.step(g, topic: nil, high: true)
        XCTAssertNil(g.accepted)
    }

    func testCaseInsensitiveTopicDoesNotReshow() {
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)
        g = Engine.step(g, topic: "Budget", high: true)   // accepted: Budget
        let before = g
        g = Engine.step(g, topic: "budget", high: true)   // same topic, different case
        XCTAssertEqual(g.accepted, "Budget")
        XCTAssertEqual(g.streak, 0, "already-shown topic resets the candidate streak")
        XCTAssertEqual(before.accepted, g.accepted)
    }
}
