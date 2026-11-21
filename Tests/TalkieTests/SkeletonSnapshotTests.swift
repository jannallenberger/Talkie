import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in renderer for the skeleton loaders: every shared part and the in-app
/// placements (Memory search rows, the meeting summary card, the learned-vocabulary
/// card, the meeting-apps grid, the job title), light and dark, so the look can be
/// reviewed before an install. Skipped unless TALKIE_UI_SNAPSHOT_DIR is set.
@MainActor
final class SkeletonSnapshotTests: XCTestCase {

    private struct Gallery: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                TalkiePageHeader(title: "Memory", subtitle: "Searching — the results land where these placeholders are.")
                VStack(spacing: 10) {
                    MemoryRowSkeleton(lines: 2)
                    MemoryRowSkeleton(lines: 1)
                }
                .talkieSkeletonRegion(label: "Searching…")
                HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "Summary")
                        SummarySkeleton().talkieCard(padding: 16)
                    }
                    TalkieSkeletonCard(lines: 2, showsMetric: true)
                        .frame(width: 240)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow(text: "Learned vocabulary")
                    TalkieSkeletonGroup {
                        VStack(alignment: .leading, spacing: 14) {
                            TalkieSkeletonText(lines: 2, textSize: 13, lastLineFraction: 0.45)
                            TalkieSkeletonChips(count: 9)
                        }
                    }
                }
                .talkieCard()
                HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                    TalkieSkeletonList(rows: 3, leading: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "Your Talkie title")
                        TalkieSkeletonGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                TalkieSkeletonLine(width: 230, textSize: 22)
                                TalkieSkeletonLine(fraction: 0.8, textSize: 14)
                            }
                        }
                    }
                    .talkieCard()
                }
            }
            .padding(Theme.Space.pageSide)
            .frame(width: 820, alignment: .topLeading)
            .background(Theme.canvas)
        }
    }

    func testRenderSkeletonGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_UI_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_UI_SNAPSHOT_DIR")
        }
        _ = NSApplication.shared
        // Park the shimmer band a third of the way across so the shot shows it.
        ShimmerBandView.testPhase = 0.3
        defer { ShimmerBandView.testPhase = nil }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (scheme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let host = NSHostingView(rootView: Gallery()
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            // Let the shimmer reach mid-sweep so the highlight band is in the shot.
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            // Render the LAYER tree (the shimmer band is a Core Animation layer, which
            // `cacheDisplay` would not draw).
            let scale: CGFloat = 2
            let size = host.bounds.size
            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // The hosting view is flipped; flip the context to match.
            ctx.translateBy(x: 0, y: size.height * scale)
            ctx.scaleBy(x: scale, y: -scale)
            appearance.performAsCurrentDrawingAppearance { host.layer?.render(in: ctx) }
            let image = try XCTUnwrap(ctx.makeImage())
            let rep = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("skeletons-\(scheme).png"))
            window.orderOut(nil)
            window.close()
        }
    }
}
