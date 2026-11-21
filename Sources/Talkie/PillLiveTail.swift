import AppKit
import SwiftUI

/// The arithmetic of the pill's live text, pure so it is unit-tested.
enum PillLiveText {
    /// Lines that stay fully readable; one more fades out above them.
    static let visibleLines: CGFloat = 4
    /// The line above the readable ones is drawn too, fading out towards the top
    /// edge — so a line never ends in half-cut letters.
    static let fadingLineShare: CGFloat = 1

    /// A very long dictation is not laid out in full on every partial result: past
    /// `maxCharacters` only the newest part is kept.
    static let maxCharacters = 2400
    static let keptCharacters = 1200
    /// The cut moves in steps this large, so the text above the visible lines is
    /// re-wrapped once per step and not with every new word.
    static let cutStep = 600

    /// How many leading characters to leave out of a text `length` long.
    static func dropCount(length: Int) -> Int {
        guard length > maxCharacters else { return 0 }
        return ((length - keptCharacters) / cutStep) * cutStep
    }

    /// The newest part of `text`, starting at a word.
    static func window(_ text: String) -> String {
        let drop = dropCount(length: text.count)
        guard drop > 0 else { return text }
        let rest = text.dropFirst(drop)
        // Never start inside a word: skip to the next one.
        guard let gap = rest.firstIndex(where: \.isWhitespace) else { return String(rest) }
        return String(rest[gap...].drop(while: \.isWhitespace))
    }

    /// The height one line of the live text takes.
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// The tallest the live text gets; past this the oldest lines leave at the top.
    static func maxHeight(fontSize: CGFloat) -> CGFloat {
        ceil(lineHeight(fontSize: fontSize) * (visibleLines + fadingLineShare))
    }

    /// How far the text is pushed down when it grew by `delta` so the lines already
    /// on screen stay where they are, before they roll up to make room. Only a text
    /// that fills the block rolls; a shrinking one (the recogniser took a word back)
    /// snaps.
    static func rollStart(current: CGFloat, delta: CGFloat, newHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard delta > 0, newHeight > maxHeight else { return 0 }
        // Never more than the block itself: after a long gap the text may have grown
        // by many lines at once.
        return min(current + delta, maxHeight)
    }
}

/// The live transcript below the waveform: the newest lines, bottom-anchored. When
/// the text needs more than the block holds, the lines roll up one at a time and the
/// oldest one fades out under the top edge. Nothing moves while nothing is said.
struct PillLiveTail: View {
    let text: AttributedString
    let fontSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The laid-out text is taller than the block (so there is something to fade).
    @State private var overflowing = false
    /// The remaining distance of a roll in progress (0 at rest).
    @State private var rollOffset: CGFloat = 0

    /// The real height of the block's lines, measured from a hidden reference text
    /// in the same font (font metrics alone come out a point or two short, which
    /// cut the tops off the oldest line). Nil until it has been laid out once.
    @State private var measuredBlockHeight: CGFloat?

    private static let blockLines = Int(PillLiveText.visibleLines + PillLiveText.fadingLineShare)

    var body: some View {
        let maxHeight = measuredBlockHeight ?? PillLiveText.maxHeight(fontSize: fontSize)
        let fade = maxHeight / CGFloat(Self.blockLines) * PillLiveText.fadingLineShare
        Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, new in
                heightChanged(from: old, to: new, maxHeight: maxHeight)
            }
            .offset(y: rollOffset)
            .frame(maxHeight: maxHeight, alignment: .bottomLeading)
            .clipped()
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    // Dimmed, not gone: the oldest line stays whole and readable as it
                    // leaves, instead of losing the tops of its letters.
                    LinearGradient(colors: [.black.opacity(0.3), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflowing ? fade : 0)
                    Color.black
                }
            }
            .background(alignment: .topLeading) {
                Text(verbatim: Array(repeating: "Ag", count: Self.blockLines).joined(separator: "\n"))
                    .font(.system(size: fontSize, weight: .medium))
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { _, new in
                        if new > 0, measuredBlockHeight != new { measuredBlockHeight = new }
                    }
            }
            .accessibilityHidden(true)
    }

    private func heightChanged(from old: CGFloat, to new: CGFloat, maxHeight: CGFloat) {
        let nowOverflowing = new > maxHeight + 0.5
        if nowOverflowing != overflowing { overflowing = nowOverflowing }
        guard !reduceMotion else { return }
        let start = PillLiveText.rollStart(current: rollOffset, delta: new - old, newHeight: new,
                                           maxHeight: maxHeight)
        guard start > 0 else {
            if rollOffset != 0 { rollOffset = 0 }
            return
        }
        // Hold the lines where they were for this frame, then let them roll up.
        var hold = Transaction()
        hold.disablesAnimations = true
        withTransaction(hold) { rollOffset = start }
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.26)) { rollOffset = 0 }
        }
    }
}
