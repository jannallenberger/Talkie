import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in visual evidence without launching the app: renders the diarization UI to PNGs
/// with `ImageRenderer`. Skipped unless TALKIE_UI_SNAPSHOT_DIR is set. The app bundles no
/// font files (system fonts), so nothing needs registering.
@MainActor
final class UISnapshotTests: XCTestCase {
    private func seg(_ who: String, _ s: Double, _ text: String) -> MeetingSegment {
        MeetingSegment(speaker: who, start: s, end: s + 6, text: text)
    }

    private var sample: [MeetingSegment] {
        [seg("Me", 0, "Thanks everyone for joining. I want to walk through the launch plan and then leave plenty of time for questions."),
         seg("Speaker 1", 14, "Sure. From the design side we are on track, the last open item is the onboarding flow which should land by Thursday."),
         seg("Speaker 1", 29, "I would like a second review pass on the empty states before we ship."),
         seg("Speaker 2", 41, "Engineering is fine with that. The only risk I see is the migration, we have not rehearsed it on a large account yet."),
         seg("Me", 58, "Good point. Can you own a dry run this week and report back on Friday?"),
         seg("Speaker 3", 70, "I can help with that, I have a staging copy of a big account from last month."),
         seg("Speaker 2", 83, "Great, then let us plan the rehearsal for Wednesday afternoon.")]
    }

    private func render<V: View>(_ view: V, name: String, dir: URL, width: CGFloat = 560) throws {
        for (scheme, appearanceName) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                let content = view
                    .padding(16)
                    .frame(width: width, alignment: .topLeading)
                    .background(Theme.canvas)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    png = rep.representation(using: .png, properties: [:])
                }
            }
            let data = try XCTUnwrap(png, "render failed: \(name)")
            try data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    func testRenderDiarizationUI() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_UI_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_UI_SNAPSHOT_DIR to render UI snapshots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try render(SpeakerTurnsView(segments: sample), name: "speaker-turns", dir: dir)
        try render(MeetingPlaybackView(segments: sample, audioFiles: ["Me": "a-me.m4a", "Them": "a-them.m4a"],
                                       folderURL: dir, showsSpeakerLabels: true),
                   name: "playback-rows", dir: dir)
        try render(VoiceProfileCard(onForget: {}), name: "your-voice-card", dir: dir)
    }
}
