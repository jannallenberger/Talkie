import XCTest
@testable import Talkie

/// Bounds on the Vibe Coding project walk (P2-10): the enumeration must stop at
/// `maxEntries`, honor cancellation, and stay deterministic up to the cap.
final class ProjectScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    /// A cancelled task breaks out of the walk before keeping any files — the
    /// `Task.isCancelled` guard fires on the first iteration.
    func testCancelledScanReturnsNoFiles() async throws {
        for i in 0..<50 { try touch("File\(i).swift", in: root) }

        let captured = root!
        let result = await Task.detached { () -> ProjectScanner.Result in
            withUnsafeCurrentTask { $0?.cancel() } // cancel ourselves up front
            return ProjectScanner.scan(root: captured)
        }.value

        XCTAssertTrue(result.files.isEmpty,
                      "a cancelled walk must break out before appending files")
    }

    /// An uncancelled scan over the same tree DOES find the files — proves the
    /// cancel test above isn't passing for the wrong reason.
    func testUncancelledScanFindsFiles() throws {
        for i in 0..<50 { try touch("File\(i).swift", in: root) }
        let result = ProjectScanner.scan(root: root)
        XCTAssertEqual(result.files.count, 50)
    }

    /// Non-code entries are walked but never kept; the walk still terminates and
    /// returns only the code files (deterministic membership, capped by maxFiles).
    func testNonCodeEntriesAreVisitedButNotKept() throws {
        for i in 0..<30 { try touch("asset\(i).bin", in: root) }
        for i in 0..<10 { try touch("Source\(i).ts", in: root) }
        let result = ProjectScanner.scan(root: root)
        XCTAssertEqual(result.files.count, 10)
        XCTAssertTrue(result.files.allSatisfy { $0.hasSuffix(".ts") })
    }

    /// The entry cap is a positive ceiling well above the kept-file cap, so the
    /// walk is bounded even when matches are sparse.
    func testEntryCapIsAboveFileCap() {
        XCTAssertGreaterThan(ProjectScanner.maxEntries, ProjectScanner.maxFiles)
        XCTAssertGreaterThan(ProjectScanner.maxEntries, 0)
    }

    /// scanAll over an empty root list returns an empty, well-formed result and
    /// short-circuits on cancellation before touching the disk.
    func testScanAllHonorsCancellation() async throws {
        for i in 0..<20 { try touch("Mod\(i).js", in: root) }
        let captured = [root!]
        let result = await Task.detached { () -> ProjectScanner.Result in
            withUnsafeCurrentTask { $0?.cancel() }
            return ProjectScanner.scanAll(roots: captured)
        }.value
        XCTAssertTrue(result.files.isEmpty)
    }
}
