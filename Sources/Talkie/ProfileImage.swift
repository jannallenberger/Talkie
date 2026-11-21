import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

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

    /// The square edge, in pixels, that imported photos are downscaled to. 512 keeps
    /// the large avatar in Settings (72 pt) and the photo popover (112 pt) sharp at
    /// 3× backing scale, and is still a small file.
    nonisolated static let targetPixels = 512

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
    /// source is turned upright (cameras store the rotation as metadata), cropped to
    /// a square around the face when there is one (else the centre), downscaled to
    /// `targetPixels`, and re-encoded as PNG (which drops any EXIF/location metadata
    /// the original carried), then written atomically to `profile.png`. On any
    /// failure to read or normalize the source the store is left unchanged and
    /// `false` is returned.
    @discardableResult
    func setImage(fromFile url: URL) -> Bool {
        guard let upright = Self.uprightImage(at: url),
              let png = Self.normalizedPNG(from: upright, face: Self.largestFace(in: upright)) else { return false }
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

    // MARK: Picking

    /// Open a file picker restricted to images, and import the chosen file. A plain
    /// `NSOpenPanel` — deliberately NOT a PhotosPicker, so there is no photo-library
    /// permission: the panel grants exactly the one file the user chooses. Returns
    /// false when the chosen file could not be read as an image.
    @discardableResult
    func choosePhoto() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose".loc
        panel.message = "Choose a photo".loc
        guard panel.runModal() == .OK, let url = panel.url else { return true }
        return setImage(fromFile: url)
    }

    /// Whether a dropped URL is an image file we can take (extension → UTType).
    nonisolated static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: Image normalization (pure)

    /// The largest edge decoded from a source file. A phone photo is 4000+ pixels
    /// wide; the avatar needs 512, and face detection is happy with far less.
    private nonisolated static let decodePixels = 2048

    /// The image at `url`, decoded with its stored rotation applied. `NSImage` alone
    /// ignores the orientation tag, so a portrait phone photo came in sideways.
    nonisolated static func uprightImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodePixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The biggest face in `image`, in pixels with a top-left origin, or nil when
    /// there is none (or detection is unavailable). On-device Vision; nothing leaves.
    nonisolated static func largestFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return faces
            .map { f -> CGRect in
                // Vision: unit square, origin bottom-left.
                let b = f.boundingBox
                return CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// The square to cut out of an image: around the face (head and shoulders, the
    /// face about 40 % of the height) when there is one, else the centre. Always
    /// inside the image. Pixels, top-left origin.
    nonisolated static func cropSquare(imageSize: CGSize, face: CGRect?) -> CGRect {
        let shortest = min(imageSize.width, imageSize.height)
        guard shortest > 0 else { return .zero }
        guard let face, face.width > 0, face.height > 0 else {
            return CGRect(x: (imageSize.width - shortest) / 2, y: (imageSize.height - shortest) / 2,
                          width: shortest, height: shortest)
        }
        let side = min(shortest, max(face.height * 2.5, shortest * 0.35))
        // A touch below the face's middle: the box runs brow to chin, hair needs
        // less room above than the shoulders below.
        let centre = CGPoint(x: face.midX, y: face.midY + face.height * 0.08)
        let x = min(max(0, centre.x - side / 2), imageSize.width - side)
        let y = min(max(0, centre.y - side / 2), imageSize.height - side)
        return CGRect(x: x, y: y, width: side, height: side).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Crop `source` to a square (centre), downscale to `targetPixels`, encode as PNG.
    /// Returns `nil` if the source has no rasterizable representation.
    static func normalizedPNG(from source: NSImage) -> Data? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return normalizedPNG(from: cg, face: nil)
    }

    /// Crop `cg` to `cropSquare`, downscale to `targetPixels × targetPixels`, and
    /// encode as PNG. Re-encoding intentionally discards EXIF/GPS metadata.
    nonisolated static func normalizedPNG(from cg: CGImage, face: CGRect?) -> Data? {
        let crop = cropSquare(imageSize: CGSize(width: cg.width, height: cg.height), face: face)
        guard crop.width > 0, let square = cg.cropping(to: crop) else { return nil }

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

/// The profile avatar: the photo in a circle with a fine light rim, or — when
/// `showsPlaceholder` is on and there is no photo — the user's initial (or a person
/// glyph) on the accent. Fixed-size by design: callers pass an explicit `size`.
///
/// `showsPlaceholder` defaults to **false**: with no photo the view renders nothing,
/// so a caller can mount it unconditionally (the meeting rows). The places where the
/// photo is SET (the dashboard header, Settings ▸ Profile) turn it on, so there is
/// always something to click.
struct AvatarView: View {
    @ObservedObject var store: ProfileImageStore
    let size: CGFloat
    var showsPlaceholder: Bool = false
    /// The user's name, for the placeholder's initial.
    var name: String = ""

    var body: some View {
        Group {
            if let image = store.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(rim)
                    .shadow(color: .black.opacity(size >= 40 ? 0.16 : 0), radius: size * 0.12, x: 0, y: size * 0.05)
            } else if showsPlaceholder {
                Circle()
                    .fill(LinearGradient(colors: [Theme.brand.mix(with: .white, by: 0.22), Theme.brand],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: size, height: size)
                    .overlay(placeholderGlyph)
                    .overlay(rim)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var rim: some View {
        Circle().strokeBorder(
            LinearGradient(colors: [Theme.glassRim, Theme.glassRim.opacity(0.2)], startPoint: .top, endPoint: .bottom),
            lineWidth: max(1, size / 36))
    }

    @ViewBuilder private var placeholderGlyph: some View {
        if let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
            Text(verbatim: String(initial).uppercased())
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.onBrand)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.46))
                .foregroundStyle(Theme.onBrand)
        }
    }
}

/// The control that sets the profile photo: a large avatar you can drop an image
/// onto, with "Choose photo…" and "Remove photo" beside it. Used in Settings ▸
/// Profile and in the dashboard avatar's popover.
struct ProfilePhotoEditor: View {
    @ObservedObject var store: ProfileImageStore
    var name: String = ""
    var avatarSize: CGFloat = 72

    @State private var dropTargeting = false
    @State private var failed = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            AvatarView(store: store, size: avatarSize, showsPlaceholder: true, name: name)
                .overlay(Circle().strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .opacity(dropTargeting ? 1 : 0))
                .contentShape(Circle())
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: ProfileImageStore.isImageFile) else { failed = true; return false }
                    let ok = store.setImage(fromFile: url)
                    failed = !ok
                    return ok
                } isTargeted: { dropTargeting = $0 }
                .animation(.easeOut(duration: 0.12), value: dropTargeting)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(store.image == nil ? "Choose photo…".loc : "Change photo…".loc) {
                        failed = !store.choosePhoto()
                    }
                    .buttonStyle(.talkie(.secondary))
                    if store.image != nil {
                        Button("Remove photo".loc) { store.clear(); failed = false }
                            .buttonStyle(.talkie(.destructive))
                    }
                }
                if failed {
                    TalkieStatusLine(text: "That file couldn’t be read as a picture.".loc, tone: .error)
                } else {
                    Text("Or drop a picture onto the circle. It is centered on your face and stays on this Mac.".loc)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
