import XCTest
@testable import Talkie

/// Opt-in bench for the dictation-start cost of the scoped vibe snapshot
/// (`ProjectIndexStore.snapshot(for:)`, read on the main actor in `beginDictation`).
/// Copies a real `project_index.json` (read-only) into the test sandbox and times the
/// first and repeated lookups for every indexed root. Skipped unless
/// TALKIE_PERF_BENCH_SOURCE points at a Talkie support folder.
@MainActor
final class VibeSnapshotBenchTests: XCTestCase {
    private func now() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }

    func testScopedSnapshotLookupCost() async throws {
        guard let srcPath = ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_SOURCE"], !srcPath.isEmpty else {
            throw XCTSkip("set TALKIE_PERF_BENCH_SOURCE")
        }
        let src = URL(fileURLWithPath: srcPath, isDirectory: true).appendingPathComponent("project_index.json")
        let dst = AppPaths.supportDirectory().appendingPathComponent("bench_project_index.json")
        XCTAssertTrue(dst.path.contains("tk-tests-"), "bench must only ever write into the test sandbox")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)

        var lines: [String] = []
        let t0 = now()
        let store = ProjectIndexStore(fileURL: dst)
        lines.append(String(format: "init                         %7.1f ms", now() - t0))
        // Give the launch-time background builds a moment, as a real launch would have
        // long before the first dictation.
        try await Task.sleep(nanoseconds: 3_000_000_000)

        for folder in store.folders {
            let root = URL(fileURLWithPath: folder.path)
            var times: [Double] = []
            for _ in 0..<5 {
                let s = now()
                _ = store.snapshot(for: root)
                times.append(now() - s)
            }
            lines.append(String(format: "%-28@ first %7.2f ms   repeat avg %7.2f ms",
                                folder.name as NSString, times[0],
                                times.dropFirst().reduce(0, +) / Double(times.count - 1)))
        }
        let report = lines.joined(separator: "\n")
        if let out = ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_OUT"], !out.isEmpty {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
    }
}
