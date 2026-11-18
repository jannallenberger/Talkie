import Foundation

/// Builds the pasted text of a dictation that contained at least one command span.
/// Splits the transcript into regions by audio time (`FormatTimeline`), cleans every
/// region the usual way, and formats the formatted ones AFTER cleaning. The result's
/// `normalStream` (normal text with placeholders for the formatted pieces) then runs
/// the app's usual post-cleanup chain, and `FormatAssembly.substitute` puts the
/// formatted pieces back at the very end.
///
/// Only reached when `FormatAssembly.needsAssembly(marks)` — a dictation in which
/// the command key was never held takes the untouched normal path.
enum FormatDictationAssembler {

    struct Plan: Sendable, Equatable {
        /// Normal text + placeholders, for the usual post-cleanup chain.
        var normalStream: String
        /// The ordered parts (normal texts and rendered formatted pieces).
        var parts: [FormatAssembly.Part]
        /// Every dictated word without the command words (what History keeps as raw).
        var plainRaw: String
        var resolutions: [FormatSpanResolution]
        /// A model format fell back to the plain cleaned text (model unavailable or
        /// its output was rejected).
        var modelFallback: Bool
    }

    typealias Cleaner = @Sendable (String) async -> String?
    typealias ModelRunner = @Sendable (FormatPreset, String, String?) async -> String?

    /// - Parameters:
    ///   - clean: the usual cleanup pass for one piece of text, or nil when cleanup is
    ///     off / the model is unavailable (then the deterministic de-seam is used).
    ///   - postProcessFormatted: the deterministic dictionary/number pass for formatted
    ///     text (normal text gets the full chain later, through `normalStream`).
    ///   - words: use these words instead of `segments`' (the proportional fallback).
    ///   - fallbackCommands: per span, the command to use when its words here are empty
    ///     or unmatched (see `FormatTimeline.layout`).
    ///   - refineByPhrase: word times are estimates — snap span edges to the phrase.
    ///   - model: the model-format runner (injected so tests can stub it).
    static func assemble(
        segments: [TimedSegment],
        marks: [FormatMark],
        words wordsOverride: [FormatWord]? = nil,
        fallbackCommands: [FormatCommand?] = [],
        refineByPhrase: Bool = false,
        clean: Cleaner?,
        postProcessFormatted: @Sendable (String) -> String,
        languageCode: String?,
        userName: String,
        model: ModelRunner = { await FormatModelPass.run($0, text: $1, languageCode: $2) }
    ) async -> Plan {
        let words = wordsOverride ?? FormatTimeline.words(from: segments)
        let layout = FormatTimeline.layout(
            words: words, marks: marks,
            fallback: { n in n < fallbackCommands.count ? fallbackCommands[n] : nil },
            refineByPhrase: refineByPhrase)
        var parts: [FormatAssembly.Part] = []
        var modelFallback = false

        for region in layout.regions {
            guard let preset = region.format else {
                parts.append(.normal(await cleanedRegionText(region.words, clean: clean)))
                continue
            }
            let piece: FormatRenderer.Piece
            switch preset {
            case .verbatim:
                piece = FormatRenderer.verbatim(chunks: FormatTimeline.pauseChunks(of: region.words))
            case .bulletList, .numberedList, .todoList:
                let chunks = FormatTimeline.pauseChunks(of: region.words)
                let cleaned = await cleanAll(chunks, clean: clean).map(postProcessFormatted)
                piece = FormatRenderer.Piece(text: FormatRenderer.list(preset, items: cleaned), isBlock: true)
            default:
                let text = postProcessFormatted(await cleanedRegionText(region.words, clean: clean))
                piece = await render(preset, text: text, languageCode: languageCode, userName: userName,
                                     model: model, fellBack: &modelFallback)
            }
            parts.append(.formatted(piece))
        }

        let plainRaw = layout.regions.map { FormatTimeline.text(of: $0.words) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return Plan(normalStream: FormatAssembly.normalStream(parts), parts: parts, plainRaw: plainRaw,
                    resolutions: layout.resolutions, modelFallback: modelFallback)
    }

    /// Render a single-text format (everything except lists and verbatim).
    static func render(_ preset: FormatPreset, text: String, languageCode: String?, userName: String,
                       model: ModelRunner, fellBack: inout Bool) async -> FormatRenderer.Piece {
        switch preset {
        case .allCaps:
            return .init(text: FormatRenderer.allCaps(text, languageCode: languageCode), isBlock: false)
        case .lowercase:
            return .init(text: FormatRenderer.lowercase(text, languageCode: languageCode), isBlock: false)
        case .quotes:
            return .init(text: FormatRenderer.quoted(text, languageCode: languageCode), isBlock: false)
        case .parentheses:
            return .init(text: FormatRenderer.parenthesized(text), isBlock: false)
        case .heading:
            return .init(text: FormatRenderer.heading(text), isBlock: true)
        case .email, .formal, .shorter, .translateToEnglish, .translateToGerman:
            guard !text.isEmpty, let out = await model(preset, text, languageCode) else {
                if !text.isEmpty { fellBack = true }
                return .init(text: text, isBlock: preset.isBlock)
            }
            if preset == .email {
                return .init(text: FormatRenderer.emailFrame(body: out, languageCode: languageCode,
                                                             userName: userName), isBlock: true)
            }
            return .init(text: out, isBlock: false)
        case .bulletList, .numberedList, .todoList, .verbatim:
            return .init(text: text, isBlock: preset.isBlock)   // handled by the caller
        }
    }

    /// The usual cleanup of one region: de-seam the pause-split segments (as the
    /// normal path does), then the cleanup pass when available.
    static func cleanedRegionText(_ words: [FormatWord], clean: Cleaner?) async -> String {
        let segments = FormatTimeline.segmentTexts(of: words)
        guard !segments.isEmpty else { return "" }
        guard let clean else {
            return segments.count > 1 ? SentenceFlow.mergeContinuations(segments) : segments[0]
        }
        let deseamed = segments.count > 1 ? SentenceFlow.stripSeams(segments) : segments[0]
        return (await clean(deseamed)) ?? deseamed
    }

    /// Clean several list items concurrently, keeping their order.
    static func cleanAll(_ items: [String], clean: Cleaner?) async -> [String] {
        guard let clean else { return items }
        return await withTaskGroup(of: (Int, String).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask { (i, (await clean(item)) ?? item) }
            }
            var out = items
            for await (i, text) in group { out[i] = text }
            return out
        }
    }
}

/// "Format while you dictate" after the stop-time language check re-transcribed the
/// audio in another language. The command spans are in audio time, so they carry
/// over; only the words change.
enum FormatRetranscription {

    /// The words to lay out: the re-transcription's own timed words when they
    /// reproduce its text, else per-token times estimated proportionally from the
    /// original recording (`proportional` = true → snap spans to the phrase).
    static func words(retranscribed segments: [TimedSegment], text: String,
                      original: [FormatWord], duration: Double) -> (words: [FormatWord], proportional: Bool) {
        let joined = SegmentWord.normalized(segments.map(\.text).joined(separator: " "))
        let target = SegmentWord.normalized(text)
        if !segments.isEmpty, joined == target {
            let allTimed = segments.allSatisfy { SegmentWord.validated($0.words, for: $0.text) != nil }
            return (FormatTimeline.words(from: segments), !allTimed)
        }
        return (FormatTimeline.proportionalWords(text: text, reference: original, duration: duration), true)
    }

    /// Per span: the command read from the ORIGINAL transcript's words in that span,
    /// else the one the live preview matched at release.
    static func fallbackCommands(original: [FormatWord], marks: [FormatMark],
                                 live: [FormatCommand?]) -> [FormatCommand?] {
        FormatTimeline.spanCommands(words: original, marks: marks).enumerated().map { n, fromOriginal in
            fromOriginal ?? (n < live.count ? live[n] : nil)
        }
    }
}
