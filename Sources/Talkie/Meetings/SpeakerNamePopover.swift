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

    static func unavailableReason(_ a: MeetingRecorder.VoiceRememberAvailability) -> String? {
        switch a {
        case .inMemory, .fromKeptAudio: return nil
        case .unavailable(.notEnoughSpeech):
            return "Not enough speech from this person to recognise their voice. At least 20 seconds are needed.".loc
        case .unavailable(.noVoice):
            return "This person’s voice is no longer available for this meeting. Keep audio with meeting notes to use this later.".loc
        case .unavailable(.modelsMissing):
            return "Speaker recognition isn’t available on this Mac.".loc
        }
    }

    static func outcomeMessage(_ o: MeetingRecorder.RememberVoiceOutcome) -> String? {
        switch o {
        case .remembered: return nil
        case .notEnoughSpeech:
            return "Not enough speech from this person to recognise their voice. At least 20 seconds are needed.".loc
        case .unavailable, .failed: return "Couldn’t read this person’s voice.".loc
        }
    }
}

/// Click a speaker label -> type or clear a name for every turn of that speaker in this
/// meeting; optionally (off by default, per person) remember the voice for future meetings.
struct SpeakerNamePopover: View {
    let label: String
    let context: SpeakerNamingContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var remembered = false
    @State private var working = false
    @State private var message: String?
    @State private var vocabularyNote: String?

    private var current: SpeakerName? { context.names[label] }
    private var availability: MeetingRecorder.VoiceRememberAvailability {
        context.recorder.voiceRememberAvailability(meetingID: context.meetingID, label: label)
    }
    private var trimmed: String { SpeakerNames.clean(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Name this speaker")
                TextField("Name".loc, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(save)
                if let note = vocabularyNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note = SpeakerNamingCopy.sourceNote(current?.source) {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if current != nil {
                        Button("Clear name".loc) {
                            context.recorder.setSpeakerName(nil, label: label, meetingID: context.meetingID)
                            dismiss()
                        }
                        .buttonStyle(.talkie(.secondary, size: .small))
                    }
                    Spacer()
                    Button("Save".loc, action: save)
                        .buttonStyle(.talkie(.primary, size: .small))
                        .disabled(trimmed.isEmpty || trimmed == current?.name && current?.source == .manual)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 4) {
                SettingsToggleRow(
                    title: "Recognise this voice in future meetings".loc,
                    subtitle: "A voice print of this person is stored on this Mac only and can be deleted here or in Meeting settings.".loc,
                    isOn: Binding(get: { remembered }, set: { setRemembered($0) }))
                    .disabled(working || (!remembered && (trimmed.isEmpty || !availability.isAvailable)))
                if let why = remembered ? nil : (message ?? (trimmed.isEmpty
                    ? "Give this speaker a name first.".loc
                    : SpeakerNamingCopy.unavailableReason(availability))) {
                    Text(why).font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                }
                if working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading this person’s voice…".loc).font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: 320)
        .onAppear {
            draft = current?.name ?? ""
            remembered = context.recorder.knownVoiceStore.entry(meetingID: context.meetingID, label: label) != nil
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        // A name not added to the dictionary keeps the popover open with the reason.
        if let why = context.recorder.saveManualSpeakerName(trimmed, label: label, meetingID: context.meetingID) {
            vocabularyNote = why
        } else {
            dismiss()
        }
    }

    private func setRemembered(_ on: Bool) {
        message = nil
        guard on else {
            context.recorder.forgetVoice(meetingID: context.meetingID, label: label)
            remembered = false
            return
        }
        guard !trimmed.isEmpty else { return }
        // The voice is stored under the name shown here, so make that the speaker's name.
        if trimmed != current?.name {
            vocabularyNote = context.recorder.saveManualSpeakerName(trimmed, label: label, meetingID: context.meetingID)
        }
        working = true
        let name = trimmed
        Task { @MainActor in
            let outcome = await context.recorder.rememberVoice(meetingID: context.meetingID, label: label, name: name)
            working = false
            remembered = outcome == .remembered
            message = SpeakerNamingCopy.outcomeMessage(outcome)
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

/// "Speakers" under the meta line: every speaker of the meeting as a small chip that
/// opens the naming popover, whatever way the transcript itself is rendered.
struct SpeakersRow: View {
    let meeting: Meeting
    @Environment(\.speakerNaming) private var naming

    var body: some View {
        let chips = SpeakerChip.chips(for: meeting)
        if !chips.isEmpty {
            HStack(spacing: 8) {
                Eyebrow(text: "Speakers")
                ForEach(chips, id: \.label) { chip in SpeakerChipView(chip: chip, naming: naming) }
            }
        }
    }
}

private struct SpeakerChipView: View {
    let chip: SpeakerChip
    let naming: SpeakerNamingContext?
    @State private var editing = false

    private var title: some View {
        HStack(spacing: 3) {
            Text(chip.name ?? SpeakerPresentation.displayName(for: chip.label))
            if chip.voiceDerived {
                Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
                    .accessibilityLabel("Recognised by voice".loc)
            }
        }
    }

    var body: some View {
        if chip.nameable, let naming {
            Button { editing = true } label: { title }
                .buttonStyle(.talkie(.secondary, size: .small))
                .help(chip.voiceDerived ? "Recognised by voice. Click to change the name.".loc : "Name this speaker".loc)
                .pointerStyle(.link)
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    SpeakerNamePopover(label: chip.label, context: naming)
                }
        } else {
            title.font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
        }
    }
}
