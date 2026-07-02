import XCTest
@testable import Talkie

/// P1-24: the dictation persist moved OFF the main actor and became coalesced,
/// but the persisted bytes must be unchanged. `HistoryFileWriter` is the seam
/// that does the encode + atomic write; these pin both invariants.
final class HistoryFileWriterTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-writer-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func sample() -> [DictationEntry] {
        [
            DictationEntry(timestampUnix: 1_700_000_000, text: "hello world",
                           wordCount: 2, durationSec: 1.5, appName: "Notes", appCategory: "writing"),
            DictationEntry(timestampUnix: 1_700_000_100, text: "second entry",
                           wordCount: 2, durationSec: 0.9),
        ]
    }

    /// The bytes on disk match exactly what `HistoryFileWriter` encodes with its
    /// deterministic (`.sortedKeys`) encoder. The `expected` encoder MUST use the
    /// same formatting — otherwise this comparison would flake, because Foundation
    /// doesn't guarantee stable JSON key ordering and two bare encodes of the same
    /// value can differ byte-for-byte (same length, different order).
    func testWrittenBytesMatchDirectEncode() async throws {
        let entries = sample()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let expected = try encoder.encode(entries)

        let writer = HistoryFileWriter(fileURL: fileURL)
        await writer.write(entries, generation: 1)

        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertEqual(onDisk, expected)

        // And it round-trips back to the same entries.
        let decoded = try JSONDecoder().decode([DictationEntry].self, from: onDisk)
        XCTAssertEqual(decoded, entries)
    }

    /// A stale-generation write is dropped: once gen N has landed, an older gen
    /// can't clobber it. This is what lets a burst of saves coalesce to the last.
    func testStaleGenerationWriteIsDropped() async throws {
        let writer = HistoryFileWriter(fileURL: fileURL)
        let newest = sample()
        let stale = [DictationEntry(timestampUnix: 1, text: "stale", wordCount: 1, durationSec: 1)]

        await writer.write(newest, generation: 5)
        await writer.write(stale, generation: 3)   // older — must be ignored

        let decoded = try JSONDecoder().decode([DictationEntry].self,
                                               from: Data(contentsOf: fileURL))
        XCTAssertEqual(decoded, newest)
    }

    /// A newer generation does overwrite.
    func testNewerGenerationOverwrites() async throws {
        let writer = HistoryFileWriter(fileURL: fileURL)
        let first = [DictationEntry(timestampUnix: 1, text: "first", wordCount: 1, durationSec: 1)]
        let second = sample()

        await writer.write(first, generation: 1)
        await writer.write(second, generation: 2)

        let decoded = try JSONDecoder().decode([DictationEntry].self,
                                               from: Data(contentsOf: fileURL))
        XCTAssertEqual(decoded, second)
    }
}
