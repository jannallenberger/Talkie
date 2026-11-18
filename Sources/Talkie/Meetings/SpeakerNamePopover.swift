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

    private var current: SpeakerName? { context.names[label] }
    private var availability: MeetingRecorder.VoiceRememberAvailability {
        context.recorder.voiceRememberAvailability(meetingID: context.meetingID, label: label)
    }
    private var trimmed: String { SpeakerNames.clean(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Name this speaker".loc)
                TextField("Name".loc, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(save)
                if let note = SpeakerNamingCopy.sourceNote(current?.source) {
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
        context.recorder.setSpeakerName(trimmed, label: label, meetingID: context.meetingID)
        dismiss()
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
            context.recorder.setSpeakerName(trimmed, label: label, meetingID: context.meetingID)
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
