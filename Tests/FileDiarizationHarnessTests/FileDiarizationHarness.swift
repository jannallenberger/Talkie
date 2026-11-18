@preconcurrency import AVFoundation
import Darwin
import NaturalLanguage
import XCTest
import TalkieDiarization
import TalkieFileKit
@testable import Talkie

/// OPT-IN end-to-end harness: one real single-channel recording, treated as a mic-only
/// meeting (single "Me" lane, no voice profile, no system lane). Skipped unless
/// TALKIE_FILETEST_INPUT and TALKIE_FILETEST_OUT are set. Reuses SpeakerDiarizer,
/// MeetingDiarizationPipeline and SpeakerLabelling unchanged; transcription goes through
/// TalkieFileKit's FileTranscriber (the standalone mirror of the app's SpeechAnalyzer
/// path), since the app's live MultiLangStreamTranscriber is mic-capture driven.
/// Writes nothing to Application Support: output goes only to TALKIE_FILETEST_OUT.
///
///   TALKIE_FILETEST_INPUT=/path/file.m4a TALKIE_FILETEST_OUT=/path/out \
///   swift test -c release -Xswiftc -enable-testing --filter FileDiarizationHarness
final class FileDiarizationHarness: XCTestCase {
    private struct CachedDiarizer: LaneDiarizing {
        let output: DiarizationOutput
        func diarize(fileURL: URL) async throws -> DiarizationOutput { output }
    }

    private static func peakMB() -> Double {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
    }

    private static func hms(_ t: Double) -> String {
        let s = Int(max(0, t)); return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    private static func pct(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * q + 0.5))]
    }
    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    func testFileEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["TALKIE_FILETEST_INPUT"], let outPath = env["TALKIE_FILETEST_OUT"] else {
            throw XCTSkip("set TALKIE_FILETEST_INPUT and TALKIE_FILETEST_OUT to run")
        }
        XCTAssertNotNil(AppPaths.testSandboxRoot)
        let fm = FileManager.default
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("filetest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        var stats: [String: Any] = [:]

        // 1. Convert.
        let wav = tmp.appendingPathComponent("lane.wav")
        let t0 = Self.now()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input, wav.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        stats["convertSeconds"] = Self.now() - t0

        let f = try AVAudioFile(forReading: wav)
        let audioSeconds = Double(f.length) / f.processingFormat.sampleRate
        stats["audioSeconds"] = audioSeconds

        // 3a. Diarize (timed; real SpeakerDiarizer, bundled-model folder from the repo).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/DiarizationModels", isDirectory: true)
        guard SpeakerDiarizer.modelsAvailable(at: root) else { throw XCTSkip("models missing at \(root.path)") }
        let diarizer = SpeakerDiarizer(modelsDirectory: root)
        let d0 = Self.now()
        try await diarizer.prepare()
        let loaded = Self.now()
        let diar = try await diarizer.diarize(fileURL: wav)
        stats["diarizationModelLoadSeconds"] = loaded - d0
        stats["diarizationWallSeconds"] = Self.now() - d0
        stats["peakMemoryAfterDiarizationMB"] = Self.peakMB()

        // 2. Transcribe: pick the locale by sampling 3 min per candidate.
        let candidates = ["de-DE", "en-US", "es-ES"]
        let tr0 = Self.now()
        var scores: [String: Double] = [:]
        var prepFailures: [String: String] = [:]
        var best: String?
        var ready: [String: FileTranscriber] = [:]
        for loc in candidates {
            let ft = FileTranscriber(localeIdentifier: loc)
            do { try await ft.prepare(); ready[loc] = ft } catch { prepFailures[loc] = String(describing: error) }
        }
        stats["localePrepareFailures"] = prepFailures
        guard let first = candidates.first(where: { ready[$0] != nil }) else {
            try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
                .write(to: outDir.appendingPathComponent("stats.json"))
            XCTFail("no recognizer locale could be prepared: \(prepFailures)"); return
        }
        let probeFormat = try await ready[first]!.preferredAudioFormat()
        do {
            let (all, _) = try AudioFileLoader.buffers(from: wav, target: probeFormat)
            let from = min(60, max(0, all.count / 4)), to = min(all.count, from + 180)
            nonisolated(unsafe) let sample = Array(all[from..<to])
            for (loc, ft) in ready {
                let fmt = try await ft.preferredAudioFormat()
                XCTAssertEqual(fmt.sampleRate, probeFormat.sampleRate)
                let text = try await ft.transcribe(buffers: sample)
                let words = text.split(separator: " ").count
                let rec = NLLanguageRecognizer()
                rec.processString(text)
                let lang = String(loc.prefix(2))
                let prob = rec.languageHypotheses(withMaximum: 5)[NLLanguage(rawValue: lang)] ?? 0
                scores[loc] = Double(words) * prob
            }
            best = scores.max { $0.value < $1.value }?.key
        }
        stats["localeScores"] = scores
        stats["localeChosen"] = best ?? first
        let ft = ready[best ?? first]!
        let fmt = try await ft.preferredAudioFormat()
        nonisolated(unsafe) let (buffers, _) = try AudioFileLoader.buffers(from: wav, target: fmt)
        let timed = try await ft.transcribeTimed(buffers: buffers, wordTimings: true)
        stats["transcriptionWallSeconds"] = Self.now() - tr0
        stats["peakMemoryAfterTranscriptionMB"] = Self.peakMB()
        let segments = timed.segments.map {
            MeetingSegment(speaker: SpeakerLabels.me, start: $0.startSeconds, end: $0.endSeconds, text: $0.text)
        }

        // Word timings, in memory only (exactly what the live path hands the labeller).
        let words: [[SegmentWord]?] = timed.segments.map { seg in
            seg.words.isEmpty ? nil : seg.words.map { SegmentWord(text: $0.text, start: $0.startSeconds, end: $0.endSeconds) }
        }
        stats["segmentsWithWordTimings"] = zip(segments, words).filter { SegmentWord.validated($1, for: $0.text) != nil }.count
        stats["wordTimingTokens"] = words.reduce(0) { $0 + ($1?.count ?? 0) }

        // 4. Label through the real pipeline (single mic lane; cached diarization output).
        let outcome = await MeetingDiarizationPipeline.run(
            inputs: [.init(lane: SpeakerLabels.me, fileURL: wav)], segments: segments, words: words,
            diarizer: CachedDiarizer(output: diar),
            budgetSeconds: MeetingDiarizationPipeline.budget(audioSeconds: audioSeconds))
        guard case .labelled(let result) = outcome else { XCTFail("pipeline outcome \(outcome)"); return }

        // Diarizer statistics.
        var spk: [String: Any] = [:]
        for s in diar.speakers {
            let turns = diar.turns.filter { $0.speaker == s.speaker }
            spk["\(s.speaker)"] = ["speechSeconds": s.speechSeconds, "turns": turns.count]
        }
        let speech = diar.turns.reduce(0) { $0 + $1.duration }
        stats["diarizerSpeakers"] = diar.speakerCount
        stats["perDiarizerSpeaker"] = spk
        stats["speechSeconds"] = speech
        stats["silenceSeconds"] = max(0, audioSeconds - speech)
        stats["totalDiarizerTurns"] = diar.turns.count
        let canon = SpeakerLabelling.foldFragments(diar, minSeconds: SpeakerLabelling.defaultMinSpeakerSeconds)
        stats["speakersAfterFold"] = Set(canon.values).count
        stats["finalSpeakerCount"] = result.speakerCount
        stats["labelsChanged"] = result.changed
        stats["participants"] = result.participants

        // Segment statistics (folded clusters).
        var noOverlap = 0, changeCount = 0
        var changeTime = 0.0, totalSegTime = 0.0
        var beforeMulti = 0.0 // diagnosis: failing time where a second person actually speaks
        for seg in segments {
            let dur = max(0, seg.end - seg.start)
            totalSegTime += dur
            var per: [Int: Double] = [:]
            for t in diar.turns {
                let o = min(seg.end, t.end) - max(seg.start, t.start)
                if o > 0 { per[canon[t.speaker] ?? t.speaker, default: 0] += o }
            }
            if per.isEmpty { noOverlap += 1; continue }
            if dur > 0, (per.values.max() ?? 0) / dur < 0.8 {
                changeCount += 1; changeTime += dur
                if (per.values.max() ?? 0) / max(per.values.reduce(0, +), 1e-9) < 0.8 { beforeMulti += dur }
            }
        }
        stats["diag_beforeSplit_failingBecauseSecondSpeakerSpeechShareOfTime"] = totalSegTime > 0 ? beforeMulti / totalSegTime : 0
        let lens = segments.map { max(0, $0.end - $0.start) }
        stats["segmentCountBeforeSplit"] = segments.count
        stats["segmentsNoDiarizerOverlap"] = noOverlap
        stats["segmentLenMedianBeforeSplit"] = Self.pct(lens, 0.5)
        stats["segmentLenP90BeforeSplit"] = Self.pct(lens, 0.9)
        stats["segmentLenMaxBeforeSplit"] = lens.max() ?? 0
        stats["segmentsWithSpeakerChangeBeforeSplit"] = changeCount
        stats["speakerChangeShareOfSegmentTimeBeforeSplit"] = totalSegTime > 0 ? changeTime / totalSegTime : 0
        stats["totalSegmentSecondsBeforeSplit"] = totalSegTime

        // The SAME metric (same definition: the majority speaker's diarizer turns cover under
        // 80 % of the segment, folded clusters) on the FINAL (split) segments.
        var finalChange = 0, finalNoOverlap = 0
        var finalChangeTime = 0.0, finalTime = 0.0
        // Diagnosis only (not the metric): of the failing segments, how many are failing because
        // of pauses (all speakers together cover under 80 %, but the speech present is one
        // person's) versus real second-speaker speech inside the segment.
        var pauseOnly = 0, pauseOnlyTime = 0.0, multiSpeech = 0, multiSpeechTime = 0.0
        for seg in result.segments {
            let dur = max(0, seg.end - seg.start)
            finalTime += dur
            var per: [Int: Double] = [:]
            for t in diar.turns {
                let o = min(seg.end, t.end) - max(seg.start, t.start)
                if o > 0 { per[canon[t.speaker] ?? t.speaker, default: 0] += o }
            }
            if per.isEmpty { finalNoOverlap += 1; continue }
            if dur > 0, (per.values.max() ?? 0) / dur < 0.8 {
                finalChange += 1; finalChangeTime += dur
                let speech = per.values.reduce(0, +)
                if (per.values.max() ?? 0) / max(speech, 1e-9) >= 0.8 { pauseOnly += 1; pauseOnlyTime += dur }
                else { multiSpeech += 1; multiSpeechTime += dur }
            }
        }
        stats["diag_failingBecausePauses"] = pauseOnly
        stats["diag_failingBecausePausesShareOfTime"] = finalTime > 0 ? pauseOnlyTime / finalTime : 0
        stats["diag_failingBecauseSecondSpeakerSpeech"] = multiSpeech
        stats["diag_failingBecauseSecondSpeakerSpeechShareOfTime"] = finalTime > 0 ? multiSpeechTime / finalTime : 0
        let finalLens = result.segments.map { max(0, $0.end - $0.start) }
        stats["segmentCount"] = result.segments.count
        stats["segmentsNoDiarizerOverlap"] = finalNoOverlap
        stats["segmentLenMedian"] = Self.pct(finalLens, 0.5)
        stats["segmentLenP90"] = Self.pct(finalLens, 0.9)
        stats["segmentLenMax"] = finalLens.max() ?? 0
        stats["segmentsWithSpeakerChange"] = finalChange
        stats["speakerChangeShareOfSegmentTime"] = finalTime > 0 ? finalChangeTime / finalTime : 0
        stats["totalSegmentSeconds"] = finalTime
        stats["segmentsSplitIntoPieces"] = Set(result.sourceIndex).count == result.segments.count
            ? 0 : Dictionary(grouping: result.sourceIndex, by: { $0 }).values.filter { $0.count > 1 }.count

        // Structure: short pieces that carry their own label, and A-b-A islands.
        let rs = result.segments
        var shortPieces = 0, islands = 0, shortWithOwnLabel = 0
        for (k, s) in rs.enumerated() {
            let wc = SegmentWord.normalized(s.text).split(separator: " ").count
            let isShort = (s.end - s.start) < 2.0 && wc <= 4
            if isShort { shortPieces += 1 }
            let prev = k > 0 ? rs[k - 1].speaker : nil, nextL = k + 1 < rs.count ? rs[k + 1].speaker : nil
            if isShort, prev != nil, prev != s.speaker { shortWithOwnLabel += 1 }
            if isShort, let prev, let nextL, prev == nextL, prev != s.speaker { islands += 1 }
        }
        stats["shortPieces(<2s,<=4w)"] = shortPieces
        stats["shortPiecesWithOwnLabel"] = shortWithOwnLabel
        stats["shortIslandsAbA"] = islands
        stats["labelRunsPerHour"] = Double(zip(rs, rs.dropFirst()).filter { $0.speaker != $1.speaker }.count) / (audioSeconds / 3600)

        // Labelled transcript: merge consecutive segments with the same label into a turn.
        var lines: [String] = []
        var turnsPerLabel: [String: Int] = [:]
        var cur: (label: String, start: Double, text: String)?
        for s in result.segments {
            if var c = cur, c.label == s.speaker { c.text += " " + s.text; cur = c; continue }
            if let c = cur { lines.append("[\(Self.hms(c.start))] \(c.label): \(c.text)") }
            turnsPerLabel[s.speaker, default: 0] += 1
            cur = (s.speaker, s.start, s.text)
        }
        if let c = cur { lines.append("[\(Self.hms(c.start))] \(c.label): \(c.text)") }
        stats["labelledTurnLines"] = lines.count
        stats["turnsPerFinalLabel"] = turnsPerLabel
        try lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("labelled-transcript.txt"),
                                                atomically: true, encoding: .utf8)
        stats["peakMemoryFinalMB"] = Self.peakMB()
        let json = try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outDir.appendingPathComponent("stats.json"))
        try? fm.removeItem(at: wav)
    }
}
