import Foundation

/// Best-effort overwrite-then-delete for the small text files Talkie persists
/// (a meeting's `.md`, `history.json`) when the user asks to delete their data.
///
/// ── What this DOES ──────────────────────────────────────────────────────────────
/// Before unlinking a file it opens it, overwrites its full byte length with zeros,
/// forces those zeros to the physical device (`F_FULLFSYNC`, which — unlike a plain
/// `fsync` — asks the drive to flush its own write cache to the platters/flash),
/// truncates to zero, and only then removes it. On a classic overwrite-in-place
/// filesystem this leaves the on-disk bytes as zeros rather than intact-but-unlinked.
///
/// ── What this CANNOT promise (and we refuse to pretend otherwise) ────────────────
/// On APFS and every modern SSD, an "overwrite" is NOT guaranteed to land on the same
/// physical cells. Copy-on-write means the write may go to a fresh block while the old
/// one lingers until the filesystem reuses it; SSD wear-levelling and the flash
/// translation layer relocate writes by design; and prior copies may survive in APFS
/// snapshots, Time Machine backups, or the drive's spare area. So this is a genuine
/// best effort that raises the cost of casual recovery — it is emphatically NOT a
/// forensic secure-erase, and the UI copy says so plainly. The real protection for
/// data at rest if the Mac is lost or seized is **FileVault** (full-disk encryption):
/// with it on, the unreachable bytes are ciphertext without the key. That is the
/// honest privacy story, and the app tells the user to keep FileVault on rather than
/// implying deletion is unrecoverable.
///
/// Ordering matters and is deliberate: the `F_FULLFSYNC` + truncate MUST happen while
/// the handle is open and BEFORE `removeItem`, or we would just be unlinking a file
/// whose bytes were never actually overwritten. Every step is failure-tolerant — a
/// file that cannot be opened (already gone, permissions) still falls through to the
/// unlink, so delete never gets stuck; the overwrite is an enhancement, not a gate.
///
/// 100% local disk I/O — no `URLSession`, nothing leaves the Mac (per _CORES_STANDARDS.md §1).
enum FileShredder {
    /// Overwrite `url`'s contents with zeros, flush to the physical device, truncate,
    /// then delete it. Missing / unwritable files fall through to a plain remove so
    /// deletion always completes.
    static func shred(_ url: URL) {
        // Only try to overwrite a regular file with a known length; anything else
        // (directory, symlink, missing) skips straight to removeItem.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let length = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let isRegular = (attrs?[.type] as? FileAttributeType) == .typeRegular

        if isRegular, length > 0, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Overwrite the whole file with zeros, chunked so a large file never
            // allocates its full length in one Data buffer.
            let chunk = 64 * 1024
            let zeros = Data(count: min(chunk, Int(clamping: length)))
            var remaining = length
            do {
                try handle.seek(toOffset: 0)
                while remaining > 0 {
                    let n = Int(min(UInt64(zeros.count), remaining))
                    try handle.write(contentsOf: n == zeros.count ? zeros : zeros.prefix(n))
                    remaining -= UInt64(n)
                }
                // Force the zeros to the physical device before we drop the file.
                // `F_FULLFSYNC` is stronger than `fsync`: it asks the drive to flush
                // its own cache, so on overwrite-in-place media the bytes are really
                // gone, not just scheduled. Advisory on APFS/SSD (see header) — we ask
                // for it and don't rely on it.
                _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
                try handle.truncate(atOffset: 0)
            } catch {
                // Overwrite is best effort; fall through to the unlink regardless.
            }
        }

        try? FileManager.default.removeItem(at: url)
    }
}
