// Machine + OS provenance for the honesty footer. Reads only local system
// facts (CPU brand via sysctl, OS version via ProcessInfo). No network.

import Foundation

enum Provenance {
    /// CPU brand string, e.g. "Apple M3 Pro". Falls back to the arch if sysctl
    /// is unavailable (shouldn't happen on macOS).
    static let machine: String = {
        var size = 0
        let key = "machdep.cpu.brand_string"
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else {
            return fallbackArch
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else {
            return fallbackArch
        }
        // Drop the trailing NUL before decoding.
        if let nul = buffer.firstIndex(of: 0) { buffer = Array(buffer[..<nul]) }
        let brand = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return brand.isEmpty ? fallbackArch : brand
    }()

    /// e.g. "macOS 26.0 (Build 26A...)".
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        // operatingSystemVersionString already reads like "Version 26.0 (Build ...)".
        _ = build
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    private static var fallbackArch: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Unknown (non-arm64)"
        #endif
    }
}

// MARK: - Console output / progress

enum Banner {
    static func header(corpus: URL, locale: String, items: Int, warmup: Int) -> String {
        """
        talkie-bench — Apple SpeechAnalyzer, on-device, raw recognition
          corpus : \(corpus.path)
          locale : \(locale)
          files  : \(items)  (warm-up: \(warmup) discarded)
          machine: \(Provenance.machine) · \(Provenance.osVersion)

        Running… (transcription is on-device; nothing leaves this machine)
        """
    }

    /// Print a transient progress line (carriage-return overwrite when on a TTY,
    /// plain newline otherwise so logs stay readable).
    static func progressLine(_ text: String) {
        if isTTY {
            FileHandle.standardError.write(Data("\r\u{1B}[2K  \(text)".utf8))
        } else {
            FileHandle.standardError.write(Data("  \(text)\n".utf8))
        }
    }

    static func clearProgress() {
        if isTTY {
            FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
        }
    }

    private static var isTTY: Bool { isatty(FileHandle.standardError.fileDescriptor) == 1 }
}
