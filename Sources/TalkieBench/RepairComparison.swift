// `--repair`: confidence-gated repair, measured.
//
// Each clip is transcribed once with per-word confidence. Words below the
// threshold are grouped into spans and handed to the on-device model, which may
// only replace those spans (see `ConfidenceRepair` in TalkieFileKit); every
// confident word is copied through untouched by construction. The report shows
// raw vs repaired WER per clip plus every individual change, so each one can be
// judged — WER alone hides punctuation fixes (it strips punctuation) and can't
// say whether a change was right.

@preconcurrency import AVFoundation
import Foundation
import AppKit
import TalkieFileKit

/// German/English dictionary membership for the snap's ordinary-word guard.
@MainActor
enum OrdinaryWord {
    static func check(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        for lang in ["de_DE", "en_US"] {
            let miss = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                             inSpellDocumentWithTag: 0, wordCount: nil)
            if miss.location == NSNotFound { return true }
        }
        return false
    }
}

struct RepairFileResult {
    let id: String
    let referenceWords: Int
    let errorsRaw: Int
    let errorsRepaired: Int
    let errorsSnap: Int
    let errorsCombined: Int
    let snapChanges: [(from: String, to: String)]
    let combined: String
    let raw: String
    let repaired: String
    let wordCount: Int
    let changes: [(from: String, to: String)]
    let spanCount: Int
    let modelMs: Double
    let prompt: String
    let modelOutput: String
}

enum RepairComparison {
    static func run(items: [CorpusItem], localeIdentifier: String, threshold: Double,
                    vocabulary: [String], quiet: Bool) async -> [RepairFileResult] {
        guard FileTranscriber.isAvailable else {
            FileHandle.standardError.write(Data("error: on-device SpeechTranscriber is not available on this Mac.\n".utf8))
            return []
        }
        if !ConfidenceRepairer.isAvailable {
            FileHandle.standardError.write(Data("warning: Apple Intelligence model unavailable — repaired text will equal raw.\n".utf8))
        }
        let engine = FileTranscriber(localeIdentifier: localeIdentifier)
        let format: AVAudioFormat
        do {
            try await engine.prepare()
            format = try await engine.preferredAudioFormat()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return []
        }
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: localeIdentifier) ?? localeIdentifier
        let repairer = ConfidenceRepairer(threshold: threshold, vocabulary: vocabulary, languageName: languageName)

        var rows: [RepairFileResult] = []
        for (index, item) in items.enumerated() {
            do {
                let buffers = try AudioFileLoader.buffers(from: item.audioURL, target: format).buffers
                let words = try await engine.transcribeWords(buffers: buffers)
                // Which uncertain single words are real dictionary words — both the
                // snap and the model's plausibility check refuse to jargon-ify those.
                let snapSpans = ConfidenceRepair.spans(words, threshold: threshold)
                var ordinaryWords = Set<String>()
                for span in snapSpans {
                    let bare = span.text.trimmingCharacters(in: .punctuationCharacters)
                    if await OrdinaryWord.check(bare) { ordinaryWords.insert(bare) }
                }
                let outcome = await repairer.repair(words, ordinaryWords: ordinaryWords)
                let raw = ConfidenceRepair.apply(words, spans: [], replacements: [:])
                // Snap only (no model): instant vocabulary matches on uncertain spans.
                let snaps = ConfidenceRepair.vocabularySnaps(snapSpans, vocabulary: vocabulary,
                                                             isOrdinaryWord: { ordinaryWords.contains($0) })
                let snapText = ConfidenceRepair.apply(words, spans: snapSpans, replacements: snaps)
                let snapChanges = snapSpans.compactMap { sp in snaps[sp.id].map { (sp.text, $0) } }
                // Snap first, then the model on what's still uncertain.
                let combinedOutcome = await repairer.repair(
                    ConfidenceRepair.applyingSnaps(words, spans: snapSpans, snaps: snaps),
                    ordinaryWords: ordinaryWords)
                let changes = outcome.spans.compactMap { span -> (String, String)? in
                    guard let to = outcome.replacements[span.id], to != span.text else { return nil }
                    return (span.text, to)
                }
                let wRaw = WER.score(reference: item.reference, hypothesis: raw)
                let wRep = WER.score(reference: item.reference, hypothesis: outcome.text)
                let wSnap = WER.score(reference: item.reference, hypothesis: snapText)
                let wComb = WER.score(reference: item.reference, hypothesis: combinedOutcome.text)
                rows.append(RepairFileResult(
                    id: item.id, referenceWords: wRaw.referenceLength,
                    errorsRaw: wRaw.totalErrors, errorsRepaired: wRep.totalErrors,
                    errorsSnap: wSnap.totalErrors, errorsCombined: wComb.totalErrors,
                    snapChanges: snapChanges, combined: combinedOutcome.text,
                    raw: raw, repaired: outcome.text, wordCount: words.count,
                    changes: changes, spanCount: outcome.spans.count, modelMs: outcome.modelMs,
                    prompt: outcome.prompt, modelOutput: outcome.modelOutput))
                if !quiet {
                    Banner.progressLine("[\(index + 1)/\(items.count)] \(item.id)  \(outcome.spans.count) spans, \(changes.count) changed")
                }
            } catch {
                if !quiet { Banner.progressLine("skip \(item.id): \(error.localizedDescription)") }
            }
        }
        if !quiet { Banner.clearProgress() }
        return rows
    }

    static func render(_ rows: [RepairFileResult], threshold: Double) -> String {
        var lines = ["", "══════════════════════════════════════════════════════════",
                     "  Confidence-gated repair — threshold \(String(format: "%.2f", threshold))",
                     "══════════════════════════════════════════════════════════"]
        for r in rows {
            lines.append("")
            lines.append("── \(r.id): WER raw \(pct(r.errorsRaw, r.referenceWords))"
                         + " | snap \(pct(r.errorsSnap, r.referenceWords))"
                         + " | model \(pct(r.errorsRepaired, r.referenceWords))"
                         + " | snap+model \(pct(r.errorsCombined, r.referenceWords))"
                         + "   spans \(r.spanCount)/\(r.wordCount) words, model \(Int(r.modelMs)) ms")
            for c in r.snapChanges { lines.append("   snap:  “\(c.from)” → “\(c.to)”") }
            for c in r.changes { lines.append("   model: “\(c.from)” → “\(c.to)”") }
            if r.changes.isEmpty { lines.append("   (no changes)") }
            if ProcessInfo.processInfo.environment["TALKIE_REPAIR_DEBUG"] != nil {
                lines.append("   PROMPT:\n" + r.prompt.split(separator: "\n").map { "     " + $0 }.joined(separator: "\n"))
                lines.append("   MODEL:\n" + r.modelOutput.split(separator: "\n").map { "     " + $0 }.joined(separator: "\n"))
            }
            lines.append("   RAW:      \(r.raw)")
            lines.append("   MODEL:    \(r.repaired)")
            lines.append("   COMBINED: \(r.combined)")
        }
        let ref = rows.reduce(0) { $0 + $1.referenceWords }
        let raw = rows.reduce(0) { $0 + $1.errorsRaw }
        let rep = rows.reduce(0) { $0 + $1.errorsRepaired }
        let snap = rows.reduce(0) { $0 + $1.errorsSnap }
        let comb = rows.reduce(0) { $0 + $1.errorsCombined }
        let spans = rows.reduce(0) { $0 + $1.spanCount }
        let words = rows.reduce(0) { $0 + $1.wordCount }
        let ms = rows.map(\.modelMs)
        lines.append("")
        lines.append("  TOTAL  WER raw \(pct(raw, ref)) | snap \(pct(snap, ref)) | model \(pct(rep, ref))"
                     + " | snap+model \(pct(comb, ref))   (errors \(raw) / \(snap) / \(rep) / \(comb), \(ref) ref words)")
        lines.append("         spans \(spans) of \(words) words (\(pct(spans, words)))"
                     + "   model median \(Int(median(ms))) ms, max \(Int(ms.max() ?? 0)) ms")
        return lines.joined(separator: "\n")
    }

    private static func pct(_ n: Int, _ d: Int) -> String {
        d == 0 ? "n/a" : String(format: "%.2f%%", Double(n) / Double(d) * 100)
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
