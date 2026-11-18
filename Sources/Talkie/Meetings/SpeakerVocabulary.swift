import Foundation

// A speaker name the user typed by hand also goes into the custom vocabulary, so
// dictation spells it right. ONLY manual names (conversation-derived spellings come
// from the recognizer and may be wrong; voice re-recognition never re-adds). Uses the
// Dictionary page's own add path (`DictionaryStore.addVocabularyTerm` + `save()`), with
// the app's existing poisoning safeguards in front of it, and the same
// confirm-with-Undo pill as an agent-suggested term — never silent.

@MainActor
enum SpeakerVocabulary {
    enum Decision: Equatable {
        case add(String)
        /// Already in the vocabulary (case-insensitive): nothing to do, no pill.
        case alreadyPresent
        case skip(Reason)
    }
    enum Reason: Equatable {
        /// 3 letters or fewer: too short to be distinctive.
        case tooShort
        /// An ordinary German/English word ("Mark"/"mark", "Will"/"will"), or close
        /// enough to a common word that biasing toward it would rewrite that word.
        case ordinaryWord
    }

    /// Pure decision. `isOrdinary` = `DictionaryStore.isOrdinaryPhraseOrWord` (system
    /// spell checker, de + en, plus the built-in common words: every word of a phrase
    /// must be ordinary to skip it); `guardSafe` = `NicheTermGuard.isSafeToInject`
    /// (a term that is, or is one edit from, a high-frequency common word). The full
    /// typed name is the term — parts are never added separately.
    static func decide(_ name: String, vocabulary: [String],
                       isOrdinary: (String) -> Bool = { DictionaryStore.isOrdinaryPhraseOrWord($0) },
                       guardSafe: (String) -> Bool = { NicheTermGuard.default.isSafeToInject($0) }) -> Decision {
        let term = SpeakerNames.clean(name)
        guard !term.isEmpty else { return .alreadyPresent }
        if vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) { return .alreadyPresent }
        if term.filter(\.isLetter).count <= 3 { return .skip(.tooShort) }
        if isOrdinary(term) || !guardSafe(term) { return .skip(.ordinaryWord) }
        return .add(term)
    }

    static func message(_ reason: Reason) -> String {
        switch reason {
        case .tooShort:
            return "Name saved, not added to the dictionary: it is too short to tell apart from other words.".loc
        case .ordinaryWord:
            return "Name saved, not added to the dictionary: it is also an everyday word, and dictation would start changing that word.".loc
        }
    }
}

/// Applies `SpeakerVocabulary` decisions to the real dictionary and shows the pill.
@MainActor
final class SpeakerVocabularyAdder {
    typealias PillPresenter = @MainActor (_ message: String, _ onUndo: @escaping () -> Void) -> Void
    private let dictionary: DictionaryStore
    private let presentPill: PillPresenter
    private let presentReverted: @MainActor () -> Void
    var isOrdinary: (String) -> Bool = { DictionaryStore.isOrdinaryPhraseOrWord($0) }
    var guardSafe: (String) -> Bool = { NicheTermGuard.default.isSafeToInject($0) }

    init(dictionary: DictionaryStore, presentPill: @escaping PillPresenter,
         presentReverted: @escaping @MainActor () -> Void) {
        self.dictionary = dictionary
        self.presentPill = presentPill
        self.presentReverted = presentReverted
    }

    convenience init(dictionary: DictionaryStore, hud: HUDController) {
        self.init(dictionary: dictionary,
                  presentPill: { message, onUndo in hud.showLearned(message, onUndo: onUndo) },
                  presentReverted: { hud.showReverted() })
    }

    /// Add a manually saved speaker name. Returns the one-line reason when skipped.
    @discardableResult
    func addManualName(_ name: String) -> String? {
        switch SpeakerVocabulary.decide(name, vocabulary: dictionary.vocabulary,
                                        isOrdinary: isOrdinary, guardSafe: guardSafe) {
        case .alreadyPresent:
            return nil
        case .skip(let reason):
            return SpeakerVocabulary.message(reason)
        case .add(let term):
            dictionary.addVocabularyTerm(term)
            dictionary.save()
            presentPill(String(format: "Added “%@” to dictionary".loc, term)) { [weak self] in
                guard let self else { return }
                // Undo removes the term only; the speaker keeps the name.
                self.dictionary.removeVocabularyTerm(term)
                self.dictionary.save()
                self.presentReverted()
            }
            return nil
        }
    }
}
