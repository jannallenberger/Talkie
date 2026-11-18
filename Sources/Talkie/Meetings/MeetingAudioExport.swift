import Foundation

/// Which "Audio" items the Meetings Export menu offers for one meeting. Pure, so the
/// 0 / 1 / 2-file decision is unit-tested without a view.
///
/// - No kept audio (keep-audio was off, or every file is gone): one disabled
///   "No audio was kept for this meeting" item, so the menu says why instead of
///   silently omitting audio.
/// - One file (an import, or a recording whose far end never came up): a single
///   "Audio (.ext)" item.
/// - Two lanes: "your side" (`Me`) and "other side" (`Them`), one file each. The two
///   sides are never mixed: their start offsets aren't stored, so a mixdown would
///   drift out of sync.
///
/// Each item copies the kept file byte-for-byte (no re-encode); the save panel
/// default is the note's basename plus a side suffix, e.g. `…-meeting-me.m4a`.
enum MeetingAudioExport {
    enum Side: Equatable {
        /// The only kept file (import or mic-only recording).
        case single
        /// The `Me` lane (microphone).
        case yourSide
        /// The `Them` lane (system audio from the call).
        case otherSide
        /// Any other key (defensive; today only Me/Them/Imported exist).
        case named(String)
    }

    struct Item: Equatable {
        let side: Side
        /// The kept file's basename inside the meetings folder.
        let fileName: String
        /// The save panel's suggested name.
        let defaultName: String

        /// The file's extension, lowercased (`m4a` for recordings; an import keeps
        /// its original container).
        var fileExtension: String {
            let ext = (fileName as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "m4a" : ext
        }

        /// The menu label, localized.
        var title: String {
            switch side {
            case .single:
                return String(format: "Audio (.%@)".loc, fileExtension)
            case .yourSide:
                return String(format: "Audio — your side (.%@)".loc, fileExtension)
            case .otherSide:
                return String(format: "Audio — other side (.%@)".loc, fileExtension)
            case .named(let key):
                return String(format: "Audio — %@ (.%@)".loc, key, fileExtension)
            }
        }
    }

    /// The items to offer. Empty means "no audio was kept" (the caller shows the one
    /// disabled item). `fileExists` filters out files deleted behind Talkie's back so
    /// the menu never offers a copy that would fail.
    static func items(audioFiles: [String: String]?,
                      baseName: String,
                      fileExists: (String) -> Bool = { _ in true }) -> [Item] {
        let present = (audioFiles ?? [:]).filter { !$0.value.isEmpty && fileExists($0.value) }
        guard !present.isEmpty else { return [] }

        if present.count == 1, let name = present.values.first {
            let ext = (name as NSString).pathExtension
            let stem = ext.isEmpty ? baseName : "\(baseName).\(ext)"
            return [Item(side: .single, fileName: name, defaultName: stem)]
        }

        var result: [Item] = []
        if let me = present["Me"] {
            result.append(Item(side: .yourSide, fileName: me,
                               defaultName: suffixed(baseName, "me", me)))
        }
        if let them = present["Them"] {
            result.append(Item(side: .otherSide, fileName: them,
                               defaultName: suffixed(baseName, "them", them)))
        }
        for key in present.keys.sorted() where key != "Me" && key != "Them" {
            let name = present[key]!
            result.append(Item(side: .named(key), fileName: name,
                               defaultName: suffixed(baseName, NoteTemplate.slug(key), name)))
        }
        return result
    }

    private static func suffixed(_ base: String, _ suffix: String, _ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        let stem = "\(base)-\(suffix)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}
