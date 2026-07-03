import XCTest
import AppKit
@testable import Talkie

/// L7: `ProfileImageStore` owns a single binary asset — `profile.png` under
/// Application Support — rather than a Codable JSON tree. It center-crops to a
/// square, downscales to 256 px, re-encodes PNG (stripping EXIF), and writes
/// atomically; `clear()` deletes the file.
///
/// The store reads/writes that fixed path, so these tests snapshot whatever is on
/// disk in `setUp` and restore it in `tearDown` — a developer running the suite
/// never loses a real profile photo (same discipline as `LatencyStoreTests`).
@MainActor
final class ProfileImageStoreTests: XCTestCase {
    private var fileURL: URL { AppPaths.supportDirectory().appendingPathComponent("profile.png") }
    private var saved: Data?
    private var scratchFiles: [URL] = []

    override func setUp() {
        super.setUp()
        saved = try? Data(contentsOf: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        if let d = saved { try? d.write(to: fileURL) }
        for url in scratchFiles { try? FileManager.default.removeItem(at: url) }
        scratchFiles = []
        super.tearDown()
    }

    // MARK: Helpers

    /// Write a solid-color PNG of the given pixel dimensions to a temp file and
    /// return its URL. Tracked for cleanup in `tearDown`.
    private func makePNGFile(width: Int, height: Int, color: NSColor = .systemBlue) throws -> URL {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw XCTSkip("could not allocate a bitmap rep for the fixture") }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("could not encode the fixture PNG")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-avatar-fixture-\(UUID().uuidString).png")
        try data.write(to: url)
        scratchFiles.append(url)
        return url
    }

    /// The pixel dimensions of the PNG the store persisted, read straight off disk.
    private func persistedPixelSize() -> (width: Int, height: Int)? {
        guard let data = try? Data(contentsOf: fileURL),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    // MARK: set / load round-trip

    func testSetImageWritesFileAndPublishesImage() throws {
        let src = try makePNGFile(width: 512, height: 512)
        let store = ProfileImageStore()
        XCTAssertNil(store.image, "no photo before setting one")

        let ok = store.setImage(fromFile: src)
        XCTAssertTrue(ok, "importing a valid image should succeed")
        XCTAssertNotNil(store.image, "the published image is set after import")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "profile.png is written to Application Support")
    }

    func testSetImageSurvivesRelaunch() throws {
        let src = try makePNGFile(width: 300, height: 300)
        do {
            let store = ProfileImageStore()
            XCTAssertTrue(store.setImage(fromFile: src))
        }
        // A fresh instance loads the persisted file — the photo survives relaunch.
        let reloaded = ProfileImageStore()
        XCTAssertNotNil(reloaded.image, "a set photo is reloaded from disk on init")
    }

    // MARK: downscale bound (256)

    func testLargeImageIsDownscaledTo256() throws {
        // A 4000×3000 source must come out 256×256 on disk (square-cropped + downscaled).
        let src = try makePNGFile(width: 4000, height: 3000)
        let store = ProfileImageStore()
        XCTAssertTrue(store.setImage(fromFile: src))

        let size = try XCTUnwrap(persistedPixelSize(), "the stored PNG must be readable")
        XCTAssertEqual(size.width, ProfileImageStore.targetPixels)
        XCTAssertEqual(size.height, ProfileImageStore.targetPixels)
        XCTAssertEqual(size.width, 256)
        XCTAssertEqual(size.height, 256)
    }

    func testSmallImageIsAlsoNormalizedTo256Square() throws {
        // Even a small, non-square source is normalized to the 256 square (the store
        // targets a fixed on-disk size rather than preserving the original).
        let src = try makePNGFile(width: 120, height: 80)
        let store = ProfileImageStore()
        XCTAssertTrue(store.setImage(fromFile: src))

        let size = try XCTUnwrap(persistedPixelSize())
        XCTAssertEqual(size.width, 256)
        XCTAssertEqual(size.height, 256)
    }

    func testNormalizedPNGProducesSquareBytes() throws {
        // The pure normalizer, exercised directly: any input → a 256² PNG.
        let src = NSImage(size: NSSize(width: 640, height: 200))
        src.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 200).fill()
        src.unlockFocus()

        let png = try XCTUnwrap(ProfileImageStore.normalizedPNG(from: src))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 256)
        XCTAssertEqual(rep.pixelsHigh, 256)
    }

    // MARK: clear (the delete path)

    func testClearRemovesFileAndImage() throws {
        let src = try makePNGFile(width: 256, height: 256)
        let store = ProfileImageStore()
        XCTAssertTrue(store.setImage(fromFile: src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.clear()
        XCTAssertNil(store.image, "the published image is nil after clear")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "profile.png is deleted from disk")

        // And a relaunch stays empty.
        let reloaded = ProfileImageStore()
        XCTAssertNil(reloaded.image)
    }

    // MARK: corrupt / missing → nil (no crash)

    func testMissingFileLoadsNilImage() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let store = ProfileImageStore()
        XCTAssertNil(store.image, "no file → no photo, no crash")
    }

    func testCorruptFileLoadsNilImage() {
        try? Data("this is not a PNG".utf8).write(to: fileURL, options: .atomic)
        let store = ProfileImageStore()
        XCTAssertNil(store.image, "a corrupt file decodes to no photo, never crashes")
    }

    func testSetImageFromNonImageFileFailsGracefully() throws {
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-not-an-image-\(UUID().uuidString).txt")
        try Data("plain text".utf8).write(to: junk)
        scratchFiles.append(junk)

        let store = ProfileImageStore()
        let ok = store.setImage(fromFile: junk)
        XCTAssertFalse(ok, "a non-image file is rejected")
        XCTAssertNil(store.image, "store is left unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "no file is written on a failed import")
    }

    // MARK: atomic overwrite

    func testSecondImageOverwritesFirst() throws {
        let store = ProfileImageStore()

        let first = try makePNGFile(width: 256, height: 256, color: .systemBlue)
        XCTAssertTrue(store.setImage(fromFile: first))
        let firstBytes = try Data(contentsOf: fileURL)

        // A visibly different second image (different color) must replace the file.
        let second = try makePNGFile(width: 256, height: 256, color: .systemGreen)
        XCTAssertTrue(store.setImage(fromFile: second))
        let secondBytes = try Data(contentsOf: fileURL)

        XCTAssertNotEqual(firstBytes, secondBytes,
                          "the second import overwrites the first file's bytes")
        XCTAssertNotNil(store.image)

        // The reloaded store reflects the second image (exactly one file on disk).
        let reloaded = ProfileImageStore()
        let reloadedBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(reloadedBytes, secondBytes)
        XCTAssertNotNil(reloaded.image)
    }
}
