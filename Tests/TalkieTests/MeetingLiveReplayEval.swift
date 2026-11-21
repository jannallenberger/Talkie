import XCTest
@testable import Talkie

/// OPT-IN replay of real meetings through the LIVE summary (W2): each meeting's
/// segments are fed in time order, accelerated (no waiting), with a live pass every
/// minute of meeting time exactly as the recorder schedules them, then "Stop" runs the
/// pipeline with the live results. The same meeting is also summarized by the full
/// batch path. Reports stop-to-summary time for live+tail versus batch and whether
/// the two summaries differ in item count. Skips unless BOTH are set:
///
///   TALKIE_LIVE_EVAL_MEETINGS=/path/to/meetings.json   (opened read-only)
///   TALKIE_LIVE_EVAL_OUT=/some/dir/outside/the/repo
///   TALKIE_LIVE_EVAL_INDICES=0,3,7   (optional; default: the 3 longest meetings
///                                     of 1,500-6,000 words that have segments)
///
/// Two schedules are replayed per meeting: single-language (text counts as stable 45 s
/// after it ends) and multi-language (text is final only at each 10-minute language
/// window). Nothing from the meetings is written anywhere but TALKIE_LIVE_EVAL_OUT,
/// and only counts and timings are written or printed — never transcript, summary
/// or note text.
final class MeetingLiveReplayEval: XCTestCase {
    func testLivePlusTailVersusBatchOnRealMeetings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TALKIE_LIVE_EVAL_MEETINGS"], !path.isEmpty,
              let outPath = env["TALKIE_LIVE_EVAL_OUT"], !outPath.isEmpty else {
            throw XCTSkip("set TALKIE_LIVE_EVAL_MEETINGS and TALKIE_LIVE_EVAL_OUT to run")
        }
        guard MeetingSummarizer.isAvailable else { throw XCTSkip("Apple Intelligence model unavailable") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        let meetings = try JSONDecoder().decode([Meeting].self, from: data)
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func words(_ m: Meeting) -> Int { m.transcript.split(whereSeparator: \.isWhitespace).count }
        let indices: [Int] = env["TALKIE_LIVE_EVAL_INDICES"].map {
            $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        } ?? Array(meetings.indices
            .filter { (meetings[$0].segments?.isEmpty == false) && (1500...6000).contains(words(meetings[$0])) }
            .sorted { words(meetings[$0]) > words(meetings[$1]) }
            .prefix(3))

        let model = OnDeviceMeetingSummaryModel()
        var rows = ["index\twords\tminutes\tlang\tschedule\tpasses\tlive_calls\tlive_compute_s\tmax_pass_s"
            + "\tstop_live_s\tstop_batch_s\tchunks\treused\titems_live\titems_batch\tsame_counts\tlive_used"]
        for i in indices where meetings.indices.contains(i) {
            let m = meetings[i]
            guard let segments = m.segments, !segments.isEmpty else { continue }
            // The live pass sees lane labels; diarized labels arrive only after Stop.
            let lane = segments.map { s -> MeetingSegment in
                var l = s; l.speaker = s.audioKey; l.lane = nil; return l
            }
            let duration = max(m.durationSec, segments.map(\.end).max() ?? 0)

            var t0 = Date()
            let batch = await MeetingSummaryPipeline(model: model).run(transcript: m.transcript, segments: segments)
            let batchSecs = Date().timeIntervalSince(t0)

            for schedule in ["single", "multi"] {
                let engine = LiveSummaryEngine(model: model)
                var passes = 0, compute = 0.0, maxPass = 0.0
                var t = LiveSummaryTiming.interval
                while t < duration + LiveSummaryTiming.interval {
                    let stable = schedule == "single"
                        ? LiveSummaryTiming.stableUntil(elapsed: t)
                        : (t / 600).rounded(.down) * 600
                    let arrived = lane.filter { $0.end <= stable }
                    if !arrived.isEmpty {
                        let p0 = Date()
                        _ = await engine.pass(segments: arrived, stableUntil: stable, notes: [])
                        let secs = Date().timeIntervalSince(p0)
                        passes += 1; compute += secs; maxPass = max(maxPass, secs)
                    }
                    t += LiveSummaryTiming.interval
                }
                await engine.stop()
                let cache = await engine.results()
                let calls = await engine.calls
                t0 = Date()
                let live = await MeetingSummaryPipeline(model: model).run(
                    transcript: m.transcript, segments: segments,
                    live: cache.isEmpty ? nil : .init(cache: cache, laneSegments: lane))
                let liveSecs = Date().timeIntervalSince(t0)
                func count(_ n: MergedNotes) -> Int {
                    n.topics.count + n.decisions.count + n.actionItems.count + n.openQuestions.count
                }
                func shape(_ n: MergedNotes) -> [Int] {
                    [n.topics.count, n.decisions.count, n.actionItems.count, n.openQuestions.count]
                }
                let row = "\(i)\t\(words(m))\t\(Int(duration / 60))\t\(batch.language.code)\t\(schedule)\t\(passes)\t\(calls)"
                    + String(format: "\t%.0f\t%.0f\t%.0f\t%.0f", compute, maxPass, liveSecs, batchSecs)
                    + "\t\(live.chunks)\t\(live.reusedChunks)\t\(count(live.merged))\t\(count(batch.merged))"
                    + "\t\(shape(live.merged) == shape(batch.merged))\t\(live.usedLive)"
                rows.append(row)
                print("LIVE-EVAL " + row)
                try rows.joined(separator: "\n").write(to: out.appendingPathComponent("live-table.tsv"),
                                                       atomically: true, encoding: .utf8)
            }
        }
    }
}
