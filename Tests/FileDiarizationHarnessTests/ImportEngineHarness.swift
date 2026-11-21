@preconcurrency import AVFoundation
import XCTest
import TalkieDiarization
@testable import Talkie

/// OPT-IN: runs the app's real `FileImportEngine` (windowed, the path the Meetings tab
/// uses) over one file, then the real diarization pass over the tee'd lane audio.
/// Skipped unless TALKIE_IMPORT_INPUT and TALKIE_IMPORT_OUT are set; writes only
/// aggregate numbers (no transcript text) to TALKIE_IMPORT_OUT/import-stats.json.
/// TALKIE_IMPORT_LOCALES (comma list, default "en-US") picks the spoken languages.
final class ImportEngineHarness: XCTestCase {
    func testImportEngineEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["TALKIE_IMPORT_INPUT"], let outPath = env["TALKIE_IMPORT_OUT"] else {
            throw XCTSkip("set TALKIE_IMPORT_INPUT and TALKIE_IMPORT_OUT to run")
        }
        let locales = (env["TALKIE_IMPORT_LOCALES"] ?? "en-US").split(separator: ",").map(String.init)
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let t0 = Date()
        let engine = FileImportEngine(teeLaneAudio: { true })
        let result = try await engine.importFile(
            url: URL(fileURLWithPath: input), primaryLocale: locales[0], localeIDs: locales,
            onProgress: { _ in })
        var stats: [String: Any] = [
            "importWallSeconds": Date().timeIntervalSince(t0),
            "durationSec": result.durationSec,
            "segments": result.segments?.count ?? 0,
            "lastSegmentEnd": result.segments?.last?.end ?? 0,
            "segmentsWithWords": result.words?.compactMap { $0 }.count ?? 0,
            "laneAudio": result.laneAudioURL != nil,
        ]
        if let lane = result.laneAudioURL, let segments = result.segments {
            defer { try? FileManager.default.removeItem(at: lane) }
            let f = try AVAudioFile(forReading: lane)
            stats["laneSeconds"] = Double(f.length) / f.processingFormat.sampleRate
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Vendor/DiarizationModels", isDirectory: true)
            if SpeakerDiarizer.modelsAvailable(at: root) {
                let d0 = Date()
                let outcome = await MeetingDiarizationPipeline.run(
                    inputs: [.init(lane: SpeakerLabels.me, fileURL: lane)], segments: segments, words: result.words,
                    diarizer: SpeakerDiarizer(modelsDirectory: root),
                    budgetSeconds: MeetingDiarizationPipeline.budget(audioSeconds: result.durationSec))
                stats["diarizationWallSeconds"] = Date().timeIntervalSince(d0)
                if case .labelled(let r) = outcome {
                    stats["speakerCount"] = r.speakerCount
                    stats["labelledSegments"] = r.segments.count
                    stats["labels"] = Set(r.segments.map(\.speaker)).count
                } else { stats["outcome"] = "\(outcome)" }
            }
        }
        try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
            .write(to: outDir.appendingPathComponent("import-stats.json"))
        XCTAssertGreaterThan(result.segments?.count ?? 0, 0)
    }
}
