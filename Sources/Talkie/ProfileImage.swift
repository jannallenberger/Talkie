import AppKit
import SwiftUI

/// L7 — the user's optional profile picture.
///
/// **Deviation from the Codable-JSON store norm (documented per the spec):** every
/// other store in the app persists a `Codable` value tree to a `*.json` file with a
/// `Payload`-style back-compat decode. This one owns a *binary asset* — a single
/// `profile.png` — so there is no JSON, no schema, and no versioned payload to
/// migrate. The image bytes ARE the format. A missing or unreadable file simply
/// means "no photo set" (`image == nil`); there is nothing to decode and nothing to
/// crash on.
///
/// Privacy: the file lives in Application Support and is re-encoded on import, which
/// strips EXIF (camera/location metadata) as a side effect. `clear()` is the delete
/// path and joins the "Clear everything" cascade in `MemoryView`. The image is shown
/// only in-app (dashboard header + in-app meeting rows) and is NEVER written into an
/// exported note or any share artifact.
///
/// The store is `@MainActor`, `ObservableObject`, and constructor-injected like the
/// other stores — never `environmentObject`.
@MainActor
final class ProfileImageStore: ObservableObject {
    /// The current photo, or `nil` when none is set. Kept as a single stable
    /// instance for the lifetime of a given photo (replaced wholesale on set/clear)
    /// so SwiftUI's `Image(nsImage:)` identity is stable across re-renders — the
    /// same re-render-identity reasoning as `Brand`'s decode-once cache.
    @Published private(set) var image: NSImage?

    /// The square edge, in pixels, that imported photos are downscaled to. 256 is
    /// plenty for a 34-pt avatar even at 3× backing scale, and keeps the on-disk
    /// file and any pulsing view light.
    static let targetPixels = 256

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("profile.png")
        load()
    }

    // MARK: Load

    /// Load `profile.png` if present. A missing/unreadable/corrupt file leaves
    /// `image == nil` — the normal "no photo" state, never an error.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let img = NSImage(data: data) else { return }
        image = img
    }

    // MARK: Mutation

    /// Import a photo from a file the user picked (`NSOpenPanel`) or dropped. The
    /// source is center-cropped to a square, downscaled to `targetPixels`, and
    /// re-encoded as PNG (which drops any EXIF/location metadata the original
    /// carried), then written atomically to `profile.png`. On any failure to read
    /// or normalize the source the store is left unchanged and `false` is returned.
    @discardableResult
    func setImage(fromFile url: URL) -> Bool {
        guard let source = NSImage(contentsOf: url),
              let png = Self.normalizedPNG(from: source) else { return false }
        guard (try? png.write(to: fileURL, options: .atomic)) != nil else { return false }
        // Decode from the exact bytes we persisted so the in-memory image matches
        // what a relaunch would load (already square + downscaled + metadata-free).
        image = NSImage(data: png)
        return true
    }

    /// Remove the photo: delete `profile.png` and drop the in-memory image so all
    /// surfaces fall back to their no-photo state instantly. This is the delete
    /// path wired into "Clear everything".
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }

    // MARK: Image normalization (pure)

    /// Center-crop `source` to a square, downscale to `targetPixels × targetPixels`,
    /// and encode as PNG. Returns `nil` if the source has no rasterizable
    /// representation. Re-encoding intentionally discards EXIF/GPS metadata.
    static func normalizedPNG(from source: NSImage) -> Data? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let side = min(cg.width, cg.height)
        guard side > 0 else { return nil }
        let cropX = (cg.width - side) / 2
        let cropY = (cg.height - side) / 2
        guard let square = cg.cropping(to: CGRect(x: cropX, y: cropY, width: side, height: side)) else { return nil }

        let target = targetPixels
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: target,
                height: target,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = ctx.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: scaled)
        rep.size = NSSize(width: target, height: target)
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - AvatarView

/// A circle-clipped profile avatar with a hairline ring — the one place the profile
/// picture is drawn (dashboard header + in-app meeting rows). Fixed-size by design:
/// callers pass an explicit `size`, never letting it grow with content.
///
/// `showsPlaceholder` defaults to **false** (photo-only, per Jann's decision — there
/// is no parrot-default avatar). When there's no photo and no placeholder, the view
/// renders nothing, so a caller can mount it unconditionally and it simply vanishes
/// when the photo is unset. The placeholder path exists only for a caller that
/// deliberately wants a neutral silhouette; nothing in L7 opts into it.
struct AvatarView: View {
    @ObservedObject var store: ProfileImageStore
    let size: CGFloat
    /// When true, a photo-less avatar shows a neutral SF-Symbol silhouette instead of
    /// nothing. Default false: no photo → no avatar (never a parrot).
    var showsPlaceholder: Bool = false

    var body: some View {
        Group {
            if let image = store.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            } else if showsPlaceholder {
                Circle()
                    .fill(Theme.surfaceSunken)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(Theme.inkTertiary)
                    )
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
    }
}
