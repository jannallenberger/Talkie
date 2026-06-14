import CoreAudio
import Foundation

/// A known meeting / conferencing app, keyed by bundle id. The allowlist maps a
/// detected mic-hot process to a friendly name (for banner copy) and a confidence
/// `Tier` — a dedicated meeting app is a stronger signal than a browser, which a
/// user might have mic-hot for a non-meeting reason (a voice-note site, a STT demo).
struct MeetingApp: Codable, Sendable, Hashable {
    var bundleID: String
    var displayName: String

    enum Tier: String, Codable, Sendable {
        /// A purpose-built conferencing app — a mic-hot here almost always means a call.
        case meetingApp
        /// A browser — mic-hot is a weaker (still useful) signal; softer copy upstream.
        case browser
    }
    var tier: Tier

    /// The built-in, zero-config seed. Bundle ids verified against the design doc /
    /// installed apps; the set is plain data so it can be extended by a one-line PR
    /// or a user setting without touching the detector.
    static let builtInAllowlist: [MeetingApp] = [
        MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", tier: .meetingApp),
        MeetingApp(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", tier: .meetingApp),
        MeetingApp(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams", tier: .meetingApp),
        MeetingApp(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex", tier: .meetingApp),
        MeetingApp(bundleID: "com.apple.FaceTime", displayName: "FaceTime", tier: .meetingApp),
        MeetingApp(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", tier: .meetingApp),
        MeetingApp(bundleID: "com.hnc.Discord", displayName: "Discord", tier: .meetingApp),
        // Browsers — Google Meet / web-hosted calls. Weaker tier (see `Tier.browser`).
        MeetingApp(bundleID: "com.google.Chrome", displayName: "Chrome", tier: .browser),
        MeetingApp(bundleID: "com.apple.Safari", displayName: "Safari", tier: .browser),
        MeetingApp(bundleID: "company.thebrowser.Browser", displayName: "Arc", tier: .browser),
        MeetingApp(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", tier: .browser),
        MeetingApp(bundleID: "com.brave.Browser", displayName: "Brave", tier: .browser),
        MeetingApp(bundleID: "org.mozilla.firefox", displayName: "Firefox", tier: .browser),
    ]
}

/// One process currently capturing microphone input, as read off Core Audio's
/// per-process hardware objects. Carries just enough to gate the allowlist and to
/// exclude Talkie itself.
struct ActiveInputProcess: Sendable, Hashable {
    let pid: pid_t
    let bundleID: String?
}

/// The Core Audio read layer. A *pure read* of the system's per-process audio
/// objects — it creates no tap, captures no audio, and triggers no TCC prompt
/// (enumerating processes and reading their `IsRunningInput`/`PID`/`BundleID`
/// metadata is not "recording"; the consent prompt is tied to creating a tap).
///
/// All helpers mirror the `AudioObjectGetPropertyData` pattern proven in
/// `SystemAudioCapture` — this is a strict, read-only subset of it. Available on
/// macOS 14.4+ (we target 26, so always present).
enum AudioProcessScanner {
    /// Every process currently capturing mic input, excluding Talkie's own PID.
    /// Returns an empty array on any Core Audio failure (degrade to "no meeting").
    static func processesCapturingInput(excludingPID selfPID: pid_t) -> [ActiveInputProcess] {
        var out: [ActiveInputProcess] = []
        for object in processObjectList() {
            guard let pid = pid(of: object) else { continue }
            if pid == selfPID { continue }            // exclude self (step 2a)
            guard isRunningInput(object) else { continue } // the trigger (step 2b)
            out.append(ActiveInputProcess(pid: pid, bundleID: bundleID(of: object)))
        }
        return out
    }

    // MARK: Core Audio property reads

    /// `kAudioHardwarePropertyProcessObjectList` ('prs#') → every audio process
    /// the system knows about.
    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids
    }

    /// `kAudioProcessPropertyPID` ('ppid') → the process id, used to exclude self
    /// and to identify the process.
    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        guard status == noErr, pid >= 0 else { return nil }
        return pid
    }

    /// `kAudioProcessPropertyBundleID` ('pbid') → the process's bundle id for the
    /// allowlist match and friendly name. May be nil for some processes. The
    /// returned CFString is owned by us (Get semantics return a +1 CFString here),
    /// so it's bridged into a Swift String which manages its lifetime.
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfString else { return nil }
        let string = cfString as String
        return string.isEmpty ? nil : string
    }

    /// `kAudioProcessPropertyIsRunningInput` ('piri') → 1 iff the process is doing
    /// IO with at least one active *input* stream (i.e. it's recording the mic now).
    /// This is the trigger; reading input-only is why music / video (output) can
    /// never match.
    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }
}

/// The first `MeetingContextProvider` implementation: it answers "is a meeting
/// likely in progress right now, and in what app?" by reading Core Audio for a
/// **non-Talkie** process actively capturing the mic, then raising confidence when
/// that process's bundle id is on a known-meeting-app allowlist.
///
/// It is an `actor` so its allowlist / self-PID config is safely mutable from any
/// isolation domain (settings can re-bind it live via `updateAllowlist`). The scan
/// itself is a pure synchronous Core Audio read with no audio I/O, so a one-shot
/// `detectActiveMeeting()` probe is cheap; an upstream poll loop calls it on a
/// cadence (the loop, debounce/session state and consent banner live in a separate
/// serial wiring pass — this type is the detection seam only).
///
/// `eventContext(at:)` returns `nil` — that is feature 04 (EventKit), which will
/// either fill this in or be composed alongside this provider.
actor ActiveMeetingDetector: MeetingContextProvider {
    /// Talkie's own PID, excluded from the scan so our dictation never self-triggers.
    private let selfPID: pid_t
    /// Bundle ids → friendly name + tier. Looked up to raise confidence.
    private var allowlist: [String: MeetingApp]

    /// Confidence floors per situation. A high value crosses the banner threshold
    /// upstream; a low value is still returned (04/05 may want it) but is below the
    /// default "offer" bar.
    enum Confidence {
        /// Allowlisted dedicated meeting app on the mic — the strongest signal.
        static let meetingApp = 0.85
        /// Allowlisted browser on the mic — a call *may* have started; softer.
        static let browser = 0.6
        /// Some non-Talkie process on the mic, but unknown / not allowlisted.
        static let micHotOnly = 0.4
    }

    /// - Parameters:
    ///   - allowlist: known meeting apps (defaults to the built-in seed).
    ///   - selfPID: Talkie's PID to exclude (defaults to the current process).
    init(allowlist: [MeetingApp] = MeetingApp.builtInAllowlist, selfPID: pid_t = getpid()) {
        self.selfPID = selfPID
        self.allowlist = Dictionary(allowlist.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Re-bind the allowlist live (e.g. when the user edits it in Settings).
    func updateAllowlist(_ allowlist: [MeetingApp]) {
        self.allowlist = Dictionary(allowlist.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Process taps / per-process audio objects exist on macOS 14.4+. We deploy to
    /// 26, so this is always true; the gate documents the floor and degrades
    /// gracefully (no-op detector) on a hypothetically lower target.
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    // MARK: MeetingContextProvider

    /// One-shot probe: is a meeting likely happening right now? Reads Core Audio
    /// once, picks the *highest-confidence* mic-hot process, and maps it to a
    /// `MeetingSignal`. Returns nil when nothing (other than Talkie) is on the mic.
    func detectActiveMeeting() async -> MeetingSignal? {
        guard Self.isSupported else { return nil }

        let active = AudioProcessScanner.processesCapturingInput(excludingPID: selfPID)
        guard !active.isEmpty else { return nil }   // no meeting

        // Prefer the strongest signal: an allowlisted meeting app > browser >
        // unknown mic-hot. This way "Zoom + Chrome both on the mic" names Zoom.
        let best = active
            .map { proc -> (process: ActiveInputProcess, app: MeetingApp?, confidence: Double) in
                let app = proc.bundleID.flatMap { allowlist[$0] }
                let confidence: Double
                switch app?.tier {
                case .meetingApp: confidence = Confidence.meetingApp
                case .browser: confidence = Confidence.browser
                case nil: confidence = Confidence.micHotOnly
                }
                return (proc, app, confidence)
            }
            .max { $0.confidence < $1.confidence }!

        return MeetingSignal(
            confidence: best.confidence,
            appBundleID: best.process.bundleID,
            startedAtUnix: Date().timeIntervalSince1970
        )
    }

    /// Calendar naming / attendees — owned by feature 04 (EventKit). Returns nil
    /// here so this provider can ship the detection seam independently.
    func eventContext(at date: Date) async -> MeetingEventContext? { nil }
}
