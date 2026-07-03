import AppKit
import Darwin // proc_name
import IOKit // IOServiceGetMatchingService, IORegistryEntryCreateCFProperty

/// Names the process currently holding *secure keyboard entry* — the system-wide
/// mode a password manager, the login window, or Terminal's "Secure Keyboard
/// Entry" toggle switches on, which makes macOS silently drop every synthetic
/// key event (so Talkie's ⌘V paste can't land). When that state is stuck, the
/// classic symptom is "paste stopped working and I don't know why"; without a
/// name the HUD can only guess "Password field", which is frequently wrong (it's
/// often Terminal or a still-open 1Password window, not a focused field at all).
///
/// PRIVACY: this is a pure diagnostic read. It resolves a single PID → app name so
/// the HUD can tell you *which* app to dismiss. It reads no keystrokes, no field
/// contents, nothing the secured app is protecting — only the public "who holds
/// secure input" registry value that `ioreg -l | grep SecureInput` already prints
/// for anyone at a shell. It never acts on the culprit (no quitting, no prompting).
///
/// `@MainActor` because it is only ever called from `TextInjector` (main-actor) on
/// the already-failed paste path, and it touches `NSRunningApplication`.
@MainActor
enum SecureInputCulprit {

    /// The app holding secure input right now, or `nil` if none is (or it can't be
    /// resolved). Resolves synchronously with a hard, bounded cost: the in-process
    /// IOKit registry read is microseconds; the `ioreg` subprocess fallback runs
    /// ONLY when the primary read yields nothing, and only on the already-failed
    /// paste path, so it never delays a paste that would have succeeded.
    static func current() -> (pid: pid_t, name: String)? {
        guard let pid = securePID(), pid > 0 else { return nil }
        return (pid, appName(for: pid))
    }

    // MARK: PID resolution

    /// The PID holding secure input. Primary path: read `kCGSSessionSecureInputPID`
    /// straight out of the `IOHIDSystem` registry entry (the same value `ioreg`
    /// surfaces, without spawning a process). Fallback: if the in-process read finds
    /// nothing — a real possibility if the property location shifts on a future
    /// macOS — shell out to `ioreg` and parse. Both are local-only; neither opens a
    /// connection.
    private static func securePID() -> pid_t? {
        if let pid = securePIDFromIOKit() { return pid }
        return securePIDFromIORegTool()
    }

    /// In-process IOKit read of `kCGSSessionSecureInputPID` from the `IOHIDSystem`
    /// service. `IOServiceGetMatchingService` consumes the matching dictionary, so it
    /// must not be released separately. The returned service object is released here.
    private static func securePIDFromIOKit() -> pid_t? {
        // kIOMainPortDefault (0) — the renamed kIOMasterPortDefault; passing 0
        // avoids the deprecation-vs-availability split across SDKs.
        let service = IOServiceGetMatchingService(0, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            secureInputPropertyKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }

        // The property is a CFNumber; anything else means the layout changed and we
        // should fall through to the text parser rather than trust a coercion.
        guard let number = value as? NSNumber else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
    }

    /// Fallback: spawn `/usr/sbin/ioreg -l -d 1 -w 0` and parse its output for the
    /// secure-input PID. Runs only when the IOKit read returned nothing. Kept thin —
    /// all the logic that can be wrong lives in the pure `parseSecureInputPID`.
    private static func securePIDFromIORegTool() -> pid_t? {
        guard let output = runIOReg() else { return nil }
        return parseSecureInputPID(fromIORegOutput: output)
    }

    /// The registry property key macOS uses for the secure-input holder. Named once
    /// here so the IOKit read and the text parser agree on the exact spelling.
    static let secureInputPropertyKey = "kCGSSessionSecureInputPID"

    // MARK: Pure parser (the unit-tested core)

    /// Extract the secure-input PID from `ioreg -l` text. Pure and side-effect free:
    /// the whole fallback contract lives here so it can be unit-tested against
    /// well-formed, absent, and malformed lines without spawning anything.
    ///
    /// `ioreg` prints the property as, with leading indentation:
    ///
    ///     "kCGSSessionSecureInputPID" = 1234
    ///
    /// A value of `0` means "no process holds secure input" and is treated as absent.
    /// Returns the first positive PID found; returns `nil` if the key is missing, the
    /// value isn't an integer, or the value is `0`.
    static func parseSecureInputPID(fromIORegOutput output: String) -> pid_t? {
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard line.contains(secureInputPropertyKey) else { continue }
            guard let pid = pidValue(afterKeyIn: line) else { continue }
            if pid > 0 { return pid }
            // A PID of 0 on the matched line is an explicit "nobody holds it"; stop
            // rather than keep scanning for a stray later match.
            return nil
        }
        return nil
    }

    /// Given a single line known to contain the key, pull the integer to the right of
    /// the first `=`. Tolerates arbitrary surrounding whitespace and the quoting/
    /// indentation `ioreg` emits; rejects a line whose right-hand side isn't a plain
    /// integer (e.g. a dictionary value), which is what makes malformed input yield
    /// `nil` instead of a bogus number.
    private static func pidValue(afterKeyIn line: Substring) -> pid_t? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let rhs = line[line.index(after: eq)...]
        // Take the leading run of digits (after trimming spaces). Using a scanned
        // digit run — not a full-string Int() — means trailing garbage on the line
        // can't invalidate an otherwise-valid PID, while a non-numeric RHS still
        // produces an empty run → nil.
        var digits = ""
        var seenDigit = false
        for ch in rhs {
            if ch == " " || ch == "\t" {
                if seenDigit { break } // trailing space ends the number
                continue               // leading space before the number
            }
            if ch.isNumber {
                digits.append(ch)
                seenDigit = true
            } else {
                break // first non-space, non-digit char ends (or invalidates) the run
            }
        }
        guard seenDigit, let pid = pid_t(digits) else { return nil }
        return pid
    }

    // MARK: Name resolution

    /// Map a PID to a human-facing app name. Prefer `NSRunningApplication`'s
    /// `localizedName` (what the user sees in the Dock / ⌘-Tab), falling back to the
    /// BSD process name via `proc_name` for daemons/helpers without an app record
    /// (e.g. the login window). Never empty: worst case returns a generic label.
    private static func appName(for pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let name = processName(for: pid), !name.isEmpty {
            return name
        }
        return "another app".loc
    }

    /// BSD process name via libproc. `proc_name` reads only the executable's short
    /// name — no arguments, no environment, no keystrokes. It writes a
    /// null-terminated name and returns the length (excluding the terminator), so we
    /// decode exactly that many bytes as UTF-8 rather than the deprecated
    /// `String(cString:)`.
    private static func processName(for pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256) // ample for a proc short name
        let count = proc_name(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<Int(count)], as: UTF8.self)
    }

    // MARK: Subprocess

    /// Run `/usr/sbin/ioreg -l -d 1 -w 0` and return its stdout, or `nil` on failure.
    /// `-d 1` limits depth (we only need the top-level `IOHIDSystem` property) and
    /// `-w 0` disables line wrapping so the PID line stays intact for the parser.
    /// This is a local device-registry query — no network, no file writes.
    private static func runIOReg() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l", "-d", "1", "-w", "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
