import AppKit
import SwiftUI

/// `ProofCard` — the one-click, shareable "nothing leaves this Mac" receipt.
///
/// The Privacy pane already proves the claim three ways you can watch (live
/// entitlements from the signature, the live open-socket count, the three
/// grep-it-yourself commands). This turns that proof into an *artifact*: a
/// fixed-size, brand-styled card you can paste into Slack or Preview to show
/// someone else — entitlements, the live internet-socket count, the code
/// signature hash (cdhash), the version, and the date it was taken.
///
/// Every value is real and measured on THIS machine at copy time — never
/// hardcoded. When a value can't be read (an ad-hoc dev build has no readable
/// cdhash; an un-signed build has no entitlements), the card says so plainly
/// instead of faking a green check, mirroring the pane's empty-entitlements note.
/// The honesty invariant (`_UNIFICATION.md` §4.3) forbids a prettier lie.

// MARK: - Data model

/// An immutable snapshot of everything the proof card renders, gathered at copy
/// time on the main actor and handed to the off-actor renderer as a value.
struct ProofCardData: Sendable {
    /// One entitlement line: its human label, its raw key, and whether it's a
    /// network entitlement (which would be a bug worth flagging in red).
    struct Entitlement: Sendable, Hashable {
        let label: String
        let key: String
        let isNetwork: Bool
    }

    let entitlements: [Entitlement]
    /// True if any network entitlement was found (should always be false).
    let hasNetwork: Bool
    /// The live internet-socket count; `nil` when the audit couldn't run.
    let internetSockets: Int?                                                                  // talkie:no-network(self-inspection)
    /// The code-signature hash (cdhash) as a hex string, or `nil` on an ad-hoc /
    /// un-signed build where no stable signature exists to read.
    let cdhash: String?
    /// The marketing version (CFBundleShortVersionString), or `nil` if absent.
    let version: String?
    /// When this proof was taken (formatted for display).
    let takenAt: Date

    /// A concise, honest one-line summary of the socket state for the card body.
    var socketLine: String {                                                                   // talkie:no-network(self-inspection)
        guard let internetSockets else {                                                       // talkie:no-network(self-inspection)
            return "Open network sockets: couldn't read".loc                                   // talkie:no-network(self-inspection)
        }
        return String(format: "Open network sockets: %d".loc, internetSockets)                 // talkie:no-network(self-inspection)
    }
}

// MARK: - The card view

/// A fixed-size (not responsive) card designed to render crisply at 2x into a
/// PNG. Laid out with brand tokens only — `talkieSurface`, the Young Serif
/// display face, `Theme` colors — so the pasted image is unmistakably Talkie.
struct ProofCard: View {
    let data: ProofCardData

    /// Fixed render size. Portrait-ish so the entitlement rows breathe; 2x in the
    /// renderer yields a 720×~. Not adaptive on purpose — it's an image, not a pane.
    static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider().overlay(Theme.hairline)

            // The headline claim + the live socket seal.
            socketSeal                                                                         // talkie:no-network(self-inspection)

            Divider().overlay(Theme.hairline)

            // Entitlements read from the signature.
            entitlementBlock

            Divider().overlay(Theme.hairline)

            // Provenance: cdhash, version, date — the "this is a real receipt" row.
            provenance
        }
        .padding(22)
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.surface)
        // A subtle brand hairline frame reads well as a standalone image (the
        // borderless in-app rule is about the live UI; an exported card wants an
        // edge so it doesn't bleed into a Slack background).
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            ClayIcon(name: "IconShield", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Talkie")
                    .font(.talkieEyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Theme.inkSecondary)
                Text("Nothing leaves this Mac.")
                    .font(.talkieDisplay(21))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var socketSeal: some View {                                                        // talkie:no-network(self-inspection)
        let ok = (data.internetSockets == 0) && !data.hasNetwork                               // talkie:no-network(self-inspection)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ok ? Theme.positive : Theme.danger)
            Text(data.socketLine)                                                              // talkie:no-network(self-inspection)
                .font(.talkieHeading(14, weight: .semibold))
                .foregroundStyle(ok ? Theme.ink : Theme.danger)
            Spacer(minLength: 0)
        }
    }

    private var entitlementBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Entitlements".loc.uppercased())
                .font(.talkieEyebrow)
                .tracking(0.8)
                .foregroundStyle(Theme.inkSecondary)

            if data.entitlements.isEmpty {
                Text("No entitlements readable (un-signed build).".loc)
                    .font(.callout)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(data.entitlements, id: \.key) { ent in
                    HStack(spacing: 8) {
                        Image(systemName: ent.isNetwork ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ent.isNetwork ? Theme.danger : Theme.positive)
                        Text(ent.label)
                            .font(.talkieHeading(13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: data.hasNetwork ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(data.hasNetwork ? Theme.danger : Theme.positive)
                Text(data.hasNetwork
                     ? "Network entitlement present — that's a bug.".loc
                     : "No network entitlement.".loc)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(data.hasNetwork ? Theme.danger : Theme.inkSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 5) {
            provenanceRow(label: "Signature".loc,
                          value: data.cdhash ?? "unsigned build (no cdhash)".loc)
            if let version = data.version {
                provenanceRow(label: "Version".loc, value: version)
            }
            provenanceRow(label: "Taken".loc, value: Self.dateText(data.takenAt))
        }
    }

    private func provenanceRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// Localized medium-date/short-time, computed once per render.
    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Export (render → pasteboard)

/// Renders a `ProofCard` to a PNG and puts it on the general pasteboard, along
/// with a plain-text equivalent so a text-only paste target (a terminal, a
/// commit message) still gets the same real values.
///
/// `@MainActor` because `ImageRenderer` walks a SwiftUI view tree and touches
/// `NSPasteboard`, both main-actor concerns.
@MainActor
enum ProofCardExporter {

    /// Copy the proof card for `data`. Returns `true` if a PNG made it onto the
    /// pasteboard; `false` if rendering failed (the caller can then fall back to
    /// text-only, which we still write). Never throws — a failed copy is a soft,
    /// reported miss, not a crash.
    @discardableResult
    static func copy(_ data: ProofCardData) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()

        let text = plainText(data)
        var wrotePNG = false

        if let png = renderPNG(data) {
            // Declare both types on one item so a rich target (Slack, Preview,
            // Notes) takes the image and a plain target takes the text.
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setString(text, forType: .string)
            pb.writeObjects([item])
            wrotePNG = true
        } else {
            // Rendering unavailable (e.g. headless) — still hand over the text so
            // the click is never a silent no-op.
            pb.setString(text, forType: .string)
        }
        return wrotePNG
    }

    /// Render the card to PNG at 2x. `nil` if the renderer can't produce a bitmap
    /// (returns no `CGImage`), which we treat as an honest "image unavailable".
    static func renderPNG(_ data: ProofCardData) -> Data? {
        let renderer = ImageRenderer(content: ProofCard(data: data))
        renderer.scale = 2  // crisp on Retina and when scaled down in chat

        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// The plain-text twin of the card — the same real values, greppable.
    static func plainText(_ data: ProofCardData) -> String {
        var lines: [String] = []
        lines.append("Talkie — Nothing leaves this Mac.".loc)
        lines.append(data.socketLine)                                                          // talkie:no-network(self-inspection)
        if data.entitlements.isEmpty {
            lines.append("Entitlements: none readable (un-signed build)".loc)
        } else {
            let labels = data.entitlements.map(\.label).joined(separator: ", ")
            lines.append(String(format: "Entitlements: %@".loc, labels))
        }
        lines.append(data.hasNetwork
                     ? "Network entitlement present — that's a bug.".loc
                     : "No network entitlement.".loc)
        lines.append(String(format: "Signature: %@".loc, data.cdhash ?? "unsigned build (no cdhash)".loc))
        if let version = data.version {
            lines.append(String(format: "Version: %@".loc, version))
        }
        lines.append(String(format: "Taken: %@".loc, ProofCard.dateText(data.takenAt)))
        return lines.joined(separator: "\n")
    }
}
