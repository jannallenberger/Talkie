import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in render of the voice-library surfaces (naming popover: new person, known-voice
/// suggestions, unavailable with a reason; Known voices card) in light and dark.
/// Skipped unless TALKIE_VOICE_SNAPSHOT_DIR is set. Throwaway stores; invented names.
@MainActor
final class SpeakerVoiceSnapshotTests: XCTestCase {
    func testVoiceLibrarySurfaces() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_VOICE_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_VOICE_SNAPSHOT_DIR to render")
        }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voice-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        var m = Meeting(title: "Weekly sync", startUnix: 0, durationSec: 600, transcript: "", summary: "", fileName: "w.md")
        m.segments = [MeetingSegment(speaker: "Me", start: 0, end: 30, text: "a", lane: "Me"),
                      MeetingSegment(speaker: "Speaker 1", start: 30, end: 90, text: "b", lane: "Them"),
                      MeetingSegment(speaker: "Speaker 2", start: 90, end: 150, text: "c", lane: "Them")]
        m.diarizationState = DiarizationState.applied.rawValue
        store.add(m)
        store.voiceSidecar.save(["Speaker 1": MicSpeakerCandidate(cluster: 0, embedding: [1, 0, 0, 0], speechSeconds: 60)], for: m.id)

        let empty = KnownVoiceStore(url: tmp.appendingPathComponent("empty.json"))
        let library = KnownVoiceStore(url: tmp.appendingPathComponent("lib.json"))
        for (name, n) in [("Dana Weber", 3), ("Jonas", 1), ("Priya Raman", 2)] {
            for _ in 0..<n {
                library.add(name: name, sample: MicSpeakerCandidate(cluster: 0, embedding: [0, 1, 0, 0], speechSeconds: 40),
                            meetingID: UUID(), label: "Speaker 1")
            }
        }
        func context(_ voices: KnownVoiceStore) -> SpeakerNamingContext {
            let r = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
            r.knownVoiceStore = voices
            r.diarizationModelsDirectory = { tmp }
            return SpeakerNamingContext(meetingID: m.id, names: [:], recorder: r)
        }
        let popoverBG = Color(nsColor: .windowBackgroundColor)
        try shot(dir, "voice-popover-new-person", width: 360, background: popoverBG, padding: 0) {
            SpeakerNamePopover(label: "Speaker 1", context: context(empty))
        }
        try shot(dir, "voice-popover-known-suggestions", width: 360, background: popoverBG, padding: 0) {
            SpeakerNamePopover(label: "Speaker 1", context: context(library))
        }
        try shot(dir, "voice-popover-unavailable", width: 360, background: popoverBG, padding: 0) {
            SpeakerNamePopover(label: "Speaker 2", context: context(library))
        }
        try shot(dir, "known-voices-card", width: 620) {
            KnownVoicesCard(voices: library.all(), onDelete: { _ in }, onForgetAll: {})
        }
    }

    private func shot<V: View>(_ dir: URL, _ name: String, width: CGFloat, background: Color = Theme.canvas,
                               padding: CGFloat = 16, @ViewBuilder _ view: () -> V) throws {
        let content = view()
        for (scheme, an) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let appearance = NSAppearance(named: an)!
            let root = content.padding(padding).frame(width: width, alignment: .topLeading)
                .background(background).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: root)
            host.appearance = appearance
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                let fit = host.fittingSize
                host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(40, fit.height)))
                window.setContentSize(host.frame.size)
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
            window.orderOut(nil); window.close()
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
