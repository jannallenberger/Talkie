import SwiftUI

/// What a speaker label in the meeting detail needs to show a name and open the naming
/// popover. Absent (nil) everywhere else, so labels elsewhere stay plain text.
struct SpeakerNamingContext {
    let meetingID: UUID
    let names: [String: SpeakerName]
    let recorder: MeetingRecorder
}

extension EnvironmentValues {
    @Entry var speakerNaming: SpeakerNamingContext? = nil
}

/// Plain-language copy for the naming popover, pure so it is tested without a view.
enum SpeakerNamingCopy {
    static func sourceNote(_ source: SpeakerName.Source?) -> String? {
        switch source {
        case .conversation: return "Named from what was said in this meeting.".loc
        case .voice: return "Recognised by a voice you chose to remember.".loc
        case .manual, nil: return nil
        }
    }

    static func reasonText(_ r: MeetingRecorder.VoiceRememberAvailability.Reason) -> String {
        switch r {
        case .notEnoughSpeech:
            return "Not enough speech from this person to recognise their voice. At least 20 seconds are needed.".loc
        case .noVoice:
            return "Only speakers told apart in this meeting can be recognised by voice.".loc
        case .audioNotKept:
            return "This meeting was analysed before voices were kept, and its audio was not kept, so this voice can’t be saved. Meetings from now on keep it.".loc
        case .reimport:
            return "This file was analysed before voices were kept. Import it again to save this voice.".loc
        case .modelsMissing:
            return "Speaker recognition isn’t available on this Mac.".loc
        }
    }

    static func unavailableReason(_ a: MeetingRecorder.VoiceRememberAvailability) -> String? {
        if case .unavailable(let r) = a { return reasonText(r) }
        return nil
    }

    static func outcomeMessage(_ o: MeetingRecorder.RememberVoiceOutcome) -> String? {
        switch o {
        case .remembered: return nil
        case .notEnoughSpeech: return reasonText(.notEnoughSpeech)
        case .unavailable(let r): return reasonText(r)
        case .audioUnreadable:
            return "The kept audio of this meeting couldn’t be read, so this voice can’t be saved.".loc
        case .notSaved:
            return "The voice couldn’t be saved to your voice library. Try again.".loc
        }
    }

    /// Known people whose name contains what is typed (all of them when empty), minus
    /// an exact match, most recently built first; at most `limit`.
    static func suggestions(_ people: [KnownVoice], typed: String, limit: Int = 6) -> [KnownVoice] {
        let t = SpeakerNames.key(typed)
        return people
            .filter { t.isEmpty || (SpeakerNames.key($0.name).contains(t) && SpeakerNames.key($0.name) != t) }
            .sorted { ($0.samples.map(\.createdUnix).max() ?? 0) > ($1.samples.map(\.createdUnix).max() ?? 0) }
            .prefix(limit).map { $0 }
    }

    /// What saving with the switch on will do to the library, for the switch subtitle.
    static func mergeNote(_ people: [KnownVoice], typed: String) -> String? {
        let t = SpeakerNames.key(typed)
        guard !t.isEmpty, let p = people.first(where: { SpeakerNames.key($0.name) == t }) else { return nil }
        return String(format: "Adds this meeting to %@’s voice profile (built from %d meetings).".loc, p.name, p.meetingCount)
    }
}

/// Click a speaker label -> type or clear a name for every turn of that speaker in this
/// meeting, pick a person already in Known voices, and (on by default whenever the voice
/// is available) save this speaker's voice to that person's profile on Save.
struct SpeakerNamePopover: View {
    let label: String
    let context: SpeakerNamingContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var recognise = false
    @State private var working = false
    @State private var message: String?
    @State private var vocabularyNote: String?
    @State private var people: [KnownVoice] = []

    private var current: SpeakerName? { context.names[label] }
    private var availability: MeetingRecorder.VoiceRememberAvailability {
        context.recorder.voiceRememberAvailability(meetingID: context.meetingID, label: label)
    }
    private var trimmed: String { SpeakerNames.clean(draft) }
    private var alreadySaved: Bool {
        context.recorder.knownVoiceStore.entry(meetingID: context.meetingID, label: label) != nil
    }

    /// The switch can be used when a voice is available (or one is already saved).
    private var voiceSwitchEnabled: Bool { !working && (alreadySaved || availability.isAvailable) }

    private var voiceStatus: (String, TalkieStatusTone)? {
        if working { return ("Saving this person’s voice…".loc, .progress) }
        if let message { return (message, .warning) }
        if !alreadySaved, let why = SpeakerNamingCopy.unavailableReason(availability) { return (why, .info) }
        if recognise, let note = SpeakerNamingCopy.mergeNote(people, typed: trimmed) { return (note, .info) }
        return nil
    }

    private var saveDisabled: Bool {
        guard !trimmed.isEmpty, !working else { return true }
        let unchangedName = trimmed == current?.name && current?.source == .manual
        return unchangedName && recognise == alreadySaved
    }

    var body: some View {
        let suggestions = SpeakerNamingCopy.suggestions(people, typed: trimmed)
        TalkiePopover(title: "Name this speaker",
                      subtitle: SpeakerPresentation.displayName(for: label)) {
            TalkieField(label: "Name", help: SpeakerNamingCopy.sourceNote(current?.source)) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name".loc, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    if !suggestions.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(suggestions) { p in
                                Button { draft = p.name; message = nil } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
                                        Text(verbatim: p.name)
                                        Image(systemName: "arrow.turn.down.left").font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
                                    }
                                }
                                .buttonStyle(.talkieChip)
                                .help("Use this known voice".loc)
                            }
                        }
                    }
                }
            }
            if let note = vocabularyNote {
                TalkieStatusLine(text: note, tone: .info)
            }
            TalkiePopoverDivider()
            VStack(alignment: .leading, spacing: 8) {
                TalkieSwitchRow(
                    title: "Recognise this voice in future meetings".loc,
                    subtitle: "A voice print of this person is stored on this Mac only and can be deleted here or in Meeting settings.".loc,
                    isOn: $recognise)
                    .disabled(!voiceSwitchEnabled)
                if let (text, tone) = voiceStatus {
                    TalkieStatusLine(text: text, tone: tone)
                }
            }
            TalkiePopoverDivider()
        } actions: {
            TalkieActionRow {
                if current != nil {
                    Button("Clear name".loc) {
                        context.recorder.setSpeakerName(nil, label: label, meetingID: context.meetingID)
                        dismiss()
                    }
                    .buttonStyle(.talkie(.destructive))
                }
            } trailing: {
                Button("Cancel".loc) { dismiss() }
                    .buttonStyle(.talkie(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save".loc, action: save)
                    .buttonStyle(.talkie(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveDisabled)
            }
        }
        .onAppear {
            draft = current?.name ?? ""
            people = context.recorder.knownVoiceStore.all()
            recognise = context.recorder.defaultRecognise(meetingID: context.meetingID, label: label)
        }
    }

    private func save() {
        guard !saveDisabled else { return }
        message = nil
        working = true
        let name = trimmed, on = recognise && voiceSwitchEnabled
        Task { @MainActor in
            let r = await context.recorder.saveSpeaker(name: name, label: label, meetingID: context.meetingID, recognise: on)
            working = false
            vocabularyNote = r.vocabularyNote
            message = r.voice.flatMap(SpeakerNamingCopy.outcomeMessage)
            people = context.recorder.knownVoiceStore.all()
            // Anything worth reading (dictionary skip, voice not saved) keeps the popover open.
            if r.vocabularyNote == nil && message == nil { dismiss() }
        }
    }
}

// MARK: - Speakers row (meeting detail header)

/// One chip of the "Speakers" row. Pure so which chips appear is tested without a view.
struct SpeakerChip: Equatable {
    let label: String
    /// The stored name, or nil (then the localized label is shown).
    let name: String?
    /// "Me" is shown plain and cannot be renamed.
    let nameable: Bool
    /// The name came from a remembered voice (shown with a waveform mark).
    let voiceDerived: Bool

    /// The chips for a meeting: one per speaker label in its segments — Me, Them,
    /// Speaker 1…N (other labels such as an import's "Imported" are not people) — in
    /// that order. Empty (no row) without segments or without any nameable speaker.
    static func chips(for meeting: Meeting) -> [SpeakerChip] {
        guard let segments = meeting.segments, !segments.isEmpty else { return [] }
        var labels = Set<String>()
        for s in segments where s.speaker == SpeakerLabels.me || s.speaker == SpeakerLabels.them
            || SpeakerPresentation.speakerNumber(s.speaker) != nil { labels.insert(s.speaker) }
        guard labels.contains(where: SpeakerNames.isNameable) else { return [] }
        func rank(_ l: String) -> Int {
            if l == SpeakerLabels.me { return -2 }
            if l == SpeakerLabels.them { return -1 }
            return SpeakerPresentation.speakerNumber(l) ?? Int.max
        }
        return labels.sorted { rank($0) < rank($1) }.map { l in
            let n = SpeakerNames.name(for: l, in: meeting.speakerNames)
            return SpeakerChip(label: l, name: n, nameable: SpeakerNames.isNameable(l),
                               voiceDerived: n != nil && meeting.speakerNames?[l]?.source == .voice)
        }
    }
}

/// "Speakers" under the meta line: every speaker of the meeting as a chip that opens
/// the naming popover, whatever way the transcript itself is rendered.
struct SpeakersRow: View {
    let meeting: Meeting
    @Environment(\.speakerNaming) private var naming

    var body: some View {
        let chips = SpeakerChip.chips(for: meeting)
        if !chips.isEmpty {
            let slots = SpeakerPresentation.colorIndices(for: (meeting.segments ?? []).map(\.speaker))
            HStack(alignment: .center, spacing: 8) {
                Eyebrow(text: "Speakers")
                FlowLayout(spacing: 6) {
                    ForEach(chips, id: \.label) { chip in
                        SpeakerChipView(chip: chip, slot: slots[chip.label] ?? 0, naming: naming)
                    }
                }
            }
        }
    }
}

private struct SpeakerChipView: View {
    let chip: SpeakerChip
    let slot: Int
    let naming: SpeakerNamingContext?
    @State private var editing = false

    var body: some View {
        let title = chip.name ?? SpeakerPresentation.displayName(for: chip.label)
        if chip.nameable, let naming {
            SpeakerNameButton(title: title, slot: slot, voiceDerived: chip.voiceDerived) { editing = true }
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    SpeakerNamePopover(label: chip.label, context: naming)
                }
        } else {
            SpeakerNameText(title: title, slot: slot, voiceDerived: chip.voiceDerived)
        }
    }
}

/// The speaker's data colour as a small dot. Feathers stay on data marks; the name
/// itself is ink (docs/DESIGN_GUIDELINES.md §1).
struct SpeakerDot: View {
    let slot: Int
    var body: some View {
        Circle().fill(SpeakerLabel.color(slot: slot)).frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// A speaker name that cannot be renamed ("Me"): dot + name, no chip, no hover.
struct SpeakerNameText: View {
    let title: String
    let slot: Int
    var voiceDerived = false

    var body: some View {
        HStack(spacing: 5) {
            SpeakerDot(slot: slot)
            Text(verbatim: title)
            if voiceDerived {
                Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityLabel("Recognised by voice".loc)
            }
        }
        .font(.talkieHeading(12, weight: .semibold))
        .foregroundStyle(Theme.ink)
        // Same inset as a chip, so dots line up down the transcript.
        .padding(.horizontal, 9)
        .frame(minHeight: 24)
    }
}

/// A renameable speaker: a clickable chip (dot, name, trailing pencil) that opens the
/// naming popover.
struct SpeakerNameButton: View {
    let title: String
    let slot: Int
    var voiceDerived = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                SpeakerDot(slot: slot)
                Text(verbatim: title)
                if voiceDerived {
                    Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityLabel("Recognised by voice".loc)
                }
                Image(systemName: "pencil")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.talkieChip)
        .help(voiceDerived ? "Recognised by voice. Click to change the name.".loc : "Name this speaker".loc)
        .pointerStyle(.link)
    }
}
