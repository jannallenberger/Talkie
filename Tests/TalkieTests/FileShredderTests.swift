import XCTest
@testable import Talkie

/// I3 — best-effort shred. `FileShredder.shred` overwrites a file's bytes with zeros,
/// forces them to the device, truncates, then removes the file. The overwrite is a
/// best effort on APFS/SSD (physical erasure is not guaranteed — that's what the
/// honest UI copy and FileVault are for), so these tests assert the *observable*
/// contract: the file always ends up gone, and every non-happy path still falls
/// through to removal so a delete never gets stuck. Hermetic: all files live in a
/// per-test temp directory.
final class FileShredderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shredder-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A normal non-empty file is removed by shred.
    func testShredRemovesRegularFile() throws {
        let url = dir.appendingPathComponent("history.json")
        try "the literal text of a dictation".data(using: .utf8)!.write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "sanity: file exists first")

        FileShredder.shred(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "shred must remove the file after overwriting it")
    }

    /// An empty file (zero length → nothing to overwrite) is still removed.
    func testShredRemovesEmptyFile() throws {
        let url = dir.appendingPathComponent("empty.md")
        try Data().write(to: url)

        FileShredder.shred(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an empty file still falls through to removal")
    }

    /// Shredding a path that doesn't exist is a safe no-op (never throws / hangs) —
    /// the delete path must complete even if the file is already gone.
    func testShredMissingFileDoesNotCrash() {
        let url = dir.appendingPathComponent("does-not-exist.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        FileShredder.shred(url) // must simply return
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A larger-than-one-chunk file is fully removed (exercises the chunked overwrite
    /// loop, which writes 64 KiB at a time).
    func testShredRemovesMultiChunkFile() throws {
        let url = dir.appendingPathComponent("big.md")
        try Data(repeating: 0x41, count: 200 * 1024).write(to: url) // 200 KiB of 'A'

        FileShredder.shred(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a multi-chunk file is overwritten and removed")
    }
}
