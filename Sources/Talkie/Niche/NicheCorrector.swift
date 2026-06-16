import Foundation

/// Post-hoc niche correction — the approach we pivoted to after the gate-zero test
/// showed on-device `contextualStrings` biasing is a no-op. Instead of hinting the
/// recognizer *before* it types, we let it type normally and then **proofread the
/// transcript**, swapping a known niche term back in wherever the recognizer
/// produced a close-sounding mistake ("Cubernets" → "Kubernetes"). Recognizer-
/// agnostic, deterministic, visible, reversible — and it reuses the confidence
/// model + guard unchanged.

/// Lightweight phonetic matching — enough to catch the misrecognitions biasing was
/// supposed to prevent, without a full Metaphone implementation.
enum NichePhonetics {
    /// A compact consonant-skeleton key: words that *sound* alike collapse to the
    /// same (or near) key, so "cubernets" and "kubernetes" collide despite different
    /// spelling. Maps hard-equivalent sounds (c/q/k → k, z/s → s), drops vowels
    /// after the first, collapses doubles.
    static func skeleton(_ raw: String) -> String {
        var letters = ""
        for ch in raw.lowercased() where ch.isLetter { letters.append(ch) }
        guard !letters.isEmpty else { return "" }
        letters = letters
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "qu", with: "kw")
            .replacingOccurrences(of: "x", with: "ks")
        var mapped = ""
        for ch in letters {
            switch ch {
            case "c", "q", "k": mapped.append("k")
            case "z", "s":      mapped.append("s")
            default:            mapped.append(ch)
            }
        }
        var out = ""
        for (i, ch) in mapped.enumerated() {
            if i != 0, "aeiouy".contains(ch) { continue } // drop non-leading vowels
            if out.last == ch { continue }                // collapse doubles
            out.append(ch)
        }
        return out
    }

    /// Standard Levenshtein. Inputs here are single words, so the O(n·m) table is fine.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}

struct NicheFix: Equatable, Sendable {
    let from: String
    let to: String
}

struct NicheCorrection: Sendable {
    let text: String
    let fixes: [NicheFix]
}

enum NicheCorrector {
    private struct Target {
        let display: String   // canonical spelling to insert
        let core: String      // lowercased letters only
        let skeleton: String
    }

    /// Proofread `text`, replacing close-sounding misrecognitions of any of `terms`
    /// with that term's canonical spelling. `terms` should be the confident niche
    /// vocabulary (in the live store, only graduated terms; in the test panel, the
    /// user's typed list). Never mutates `text` in place — rebuilds it from slices,
    /// so all replacements use valid original indices.
    static func correct(_ text: String, terms: [String], termGuard: NicheTermGuard = .default) -> NicheCorrection {
        let targets = buildTargets(terms)
        guard !targets.isEmpty else { return NicheCorrection(text: text, fixes: []) }

        let words = wordTokens(in: text)
        guard !words.isEmpty else { return NicheCorrection(text: text, fixes: []) }

        // Collect non-overlapping replacements left-to-right.
        var spans: [(range: Range<String.Index>, from: String, to: String)] = []
        var i = 0
        while i < words.count {
            // Bigram first: the recognizer often splits one unknown word into two
            // common ones ("item patent" ← "idempotent").
            if i + 1 < words.count,
               separatedBySpacesOnly(text, words[i].range, words[i + 1].range),
               let term = bestMatch(words[i].text + words[i + 1].text, targets: targets,
                                    termGuard: termGuard, isMultiWord: true) {
                let range = words[i].range.lowerBound..<words[i + 1].range.upperBound
                spans.append((range, String(text[range]), term))
                i += 2
                continue
            }
            if let term = bestMatch(words[i].text, targets: targets, termGuard: termGuard, isMultiWord: false) {
                spans.append((words[i].range, words[i].text, term))
            }
            i += 1
        }

        guard !spans.isEmpty else { return NicheCorrection(text: text, fixes: []) }

        var out = ""
        var cursor = text.startIndex
        var fixes: [NicheFix] = []
        for span in spans {
            out += text[cursor..<span.range.lowerBound]
            out += span.to
            cursor = span.range.upperBound
            fixes.append(NicheFix(from: span.from, to: span.to))
        }
        out += text[cursor..<text.endIndex]
        return NicheCorrection(text: out, fixes: fixes)
    }

    private static func buildTargets(_ terms: [String]) -> [Target] {
        var seen = Set<String>()
        var out: [Target] = []
        for raw in terms {
            let core = lettersLower(raw)
            guard core.count >= 4, seen.insert(core).inserted else { continue }
            out.append(Target(display: raw.trimmingCharacters(in: .whitespaces),
                              core: core, skeleton: NichePhonetics.skeleton(core)))
        }
        return out
    }

    /// Best canonical term for a recognized span, or nil if nothing matches closely.
    private static func bestMatch(_ raw: String, targets: [Target],
                                  termGuard: NicheTermGuard, isMultiWord: Bool) -> String? {
        let core = lettersLower(raw)
        guard core.count >= 4 else { return nil }
        let skel = NichePhonetics.skeleton(core)
        var best: (term: String, skelDist: Int, rawDist: Int)?
        for t in targets {
            if core == t.core { return nil }                 // already the correct term
            let skelDist = NichePhonetics.editDistance(skel, t.skeleton)
            if skelDist > 1 { continue }
            let rawDist = NichePhonetics.editDistance(core, t.core)
            let cap = max(1, Int(0.34 * Double(max(core.count, t.core.count))))
            if rawDist > cap { continue }
            // A single real common word might be what the user meant — only correct
            // it on an exact-sounding match (skeleton identical).
            if !isMultiWord, termGuard.commonWords.contains(core), skelDist != 0 { continue }
            if best == nil || (skelDist, rawDist) < (best!.skelDist, best!.rawDist) {
                best = (t.display, skelDist, rawDist)
            }
        }
        return best?.term
    }

    private static func lettersLower(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter })
    }

    private static func wordTokens(in text: String) -> [(range: Range<String.Index>, text: String)] {
        var out: [(Range<String.Index>, String)] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isLetter {
                let start = idx
                while idx < text.endIndex, text[idx].isLetter || text[idx] == "'" || text[idx] == "\u{2019}" {
                    idx = text.index(after: idx)
                }
                out.append((start..<idx, String(text[start..<idx])))
            } else {
                idx = text.index(after: idx)
            }
        }
        return out
    }

    private static func separatedBySpacesOnly(_ text: String, _ a: Range<String.Index>, _ b: Range<String.Index>) -> Bool {
        let between = text[a.upperBound..<b.lowerBound]
        return !between.isEmpty && between.allSatisfy { $0 == " " }
    }
}
