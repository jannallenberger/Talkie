// Discovers (audio file, reference transcript) pairs under a corpus folder.
//
// Two reference layouts are auto-detected, in priority order:
//   1. LibriSpeech: a `*.trans.txt` index in the same directory whose lines are
//      `<utt-id> THE REFERENCE TEXT`; the audio file stem is the utt-id.
//   2. Sidecar: a `<audiostem>.txt` / `.ref` / `.lab` next to the audio file,
//      whose entire contents are the reference for that one clip.
//
// Audio files with no resolvable reference are skipped (and counted), since a
// hypothesis with nothing to score against would silently inflate the corpus.

import Foundation

/// One scored unit: an audio file paired with its ground-truth transcript.
struct CorpusItem: Sendable {
    /// Stable identifier (the audio file stem, e.g. a LibriSpeech utt-id).
    let id: String
    let audioURL: URL
    let reference: String
}

enum CorpusLoaderError: LocalizedError {
    case notADirectory(URL)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "\(url.path) is not a directory."
        }
    }
}

enum CorpusLoader {
    /// Audio extensions AVAudioFile can decode on macOS 26.
    static let audioExtensions: Set<String> = ["flac", "wav", "caf", "aif", "aiff", "m4a", "mp3"]

    /// Walk `corpusDirectory` recursively and return all resolvable items, sorted
    /// by id for determinism. `limit > 0` caps the count (after sorting).
    static func load(corpusDirectory: URL, limit: Int) throws -> [CorpusItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: corpusDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            throw CorpusLoaderError.notADirectory(corpusDirectory)
        }

        // Collect every audio file and every LibriSpeech-style index up front.
        var audioFiles: [URL] = []
        var transIndexFiles: [URL] = []

        let keys: [URLResourceKey] = [.isRegularFileKey]
        if let enumerator = fm.enumerator(at: corpusDirectory,
                                          includingPropertiesForKeys: keys,
                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    audioFiles.append(url)
                } else if url.lastPathComponent.lowercased().hasSuffix(".trans.txt") {
                    transIndexFiles.append(url)
                }
            }
        }

        // Build the LibriSpeech utt-id → text map from all *.trans.txt indices.
        let transcriptIndex = buildTranscriptIndex(from: transIndexFiles)

        var items: [CorpusItem] = []
        for audio in audioFiles.sorted(by: { $0.path < $1.path }) {
            let stem = audio.deletingPathExtension().lastPathComponent
            if let ref = transcriptIndex[stem] ?? sidecarReference(for: audio) {
                let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    items.append(CorpusItem(id: stem, audioURL: audio, reference: trimmed))
                }
            }
        }

        items.sort { $0.id < $1.id }
        if limit > 0 && items.count > limit {
            items = Array(items.prefix(limit))
        }
        return items
    }

    /// Merge every `<utt-id> TEXT` line from the discovered index files.
    private static func buildTranscriptIndex(from files: [URL]) -> [String: String] {
        var index: [String: String] = [:]
        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let spaceIdx = line.firstIndex(of: " ") else { continue }
                let id = String(line[line.startIndex..<spaceIdx])
                let text = String(line[line.index(after: spaceIdx)...])
                if !id.isEmpty { index[id] = text }
            }
        }
        return index
    }

    /// Look for a `<audiostem>.txt|.ref|.lab` sidecar next to the audio file.
    private static func sidecarReference(for audio: URL) -> String? {
        let base = audio.deletingPathExtension()
        for ext in ["txt", "ref", "lab"] {
            let candidate = base.appendingPathExtension(ext)
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text
            }
        }
        return nil
    }
}
