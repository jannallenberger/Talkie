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
/// that process's bundle id is on a known-meeting-app allowlist — and, layered on
/// top, runs the live **poll loop + session/debounce state machine** that turns a
/// sustained high-confidence signal into a single "record?" offer (never silent).
///
/// It is an `actor` so its config / session state is safely mutable from any
/// isolation domain (settings re-bind it live via `updateConfig`). The scan itself
/// is a pure synchronous Core Audio read with no audio I/O. The decision logic
/// (`bestCandidate`, `decide`) is factored into pure static functions so the
/// debounce/session behavior is unit-testable without hardware.
///
/// `eventContext(at:)` returns `nil` — that is feature 04 (EventKit), which will
/// either fill this in or be composed alongside this provider.
actor ActiveMeetingDetector: MeetingContextProvider {
    /// Tunable behavior, re-bindable live via `updateConfig`.
    struct Config: Sendable {
        /// Master switch; when false the loop doesn't run and nothing is scanned.
        var enabled: Bool
        /// Known meeting apps (bundle id → name + tier).
        var allowlist: [MeetingApp]
        /// Bundle ids the user muted (via repeated dismissals); never offered.
        var muted: Set<String> = []
        /// How often to scan. Cheap metadata reads, so 1.5 s is comfortable.
        var pollInterval: Duration = .seconds(1.5)
        /// Consecutive offer-worthy polls before a meeting is "started" (~3 s).
        var startConfirmPolls: Int = 2
        /// Seconds the trigger must stay absent before the session resets — absorbs
        /// a mute / hold / screen-share swap mid-call.
        var endDebounce: TimeInterval = 20
    }

    /// Talkie's own PID, excluded from the scan so our dictation never self-triggers.
    private let selfPID: pid_t
    private var config: Config
    /// Bundle ids → friendly name + tier, derived from `config.allowlist`.
    private var allowlist: [String: MeetingApp]
    private var state = DetectorState()
    /// Per-app dismissal tallies driving auto-mute for browser-tier and unknown
    /// (non-allowlisted) apps. Ephemeral (resets on relaunch — acceptable, and honest).
    private var dismissalCounts: [String: Int] = [:]
    private var loop: Task<Void, Never>?
    private var onDetect: (@Sendable (MeetingSignal) -> Void)?
    private var onMute: (@Sendable (String) -> Void)?

    /// Confidence floors per situation. A high value crosses the banner threshold;
    /// a low value is still returned by `detectActiveMeeting` (04/05 may want it) but
    /// is below the default "offer" bar.
    enum Confidence {
        /// Allowlisted dedicated meeting app on the mic — the strongest signal.
        static let meetingApp = 0.85
        /// Allowlisted browser on the mic — a call *may* have started; softer.
        static let browser = 0.6
        /// Some non-Talkie process on the mic, but unknown / not allowlisted.
        static let micHotOnly = 0.4
    }

    init(config: Config, selfPID: pid_t = getpid()) {
        self.selfPID = selfPID
        self.config = config
        self.allowlist = Self.indexed(config.allowlist)
    }

    private static func indexed(_ list: [MeetingApp]) -> [String: MeetingApp] {
        Dictionary(list.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Process taps / per-process audio objects exist on macOS 14.4+. We deploy to
    /// 26, so this is always true; the gate documents the floor and degrades
    /// gracefully (no-op detector) on a hypothetically lower target.
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    // MARK: Poll loop

    /// Begin the poll loop. `onDetect` fires (once per meeting session) when a new
    /// meeting crosses the start threshold; the caller hops it to the MainActor and
    /// applies the dictation/recording suppression checks before showing the banner.
    /// `onMute` fires when an app crosses the dismissal threshold (browser-tier or
    /// unknown, non-allowlisted apps), so the caller can persist the mute.
    func start(onDetect: @escaping @Sendable (MeetingSignal) -> Void,
               onMute: @escaping @Sendable (String) -> Void) {
        self.onDetect = onDetect
        self.onMute = onMute
        startLoop()
    }

    private func startLoop() {
        guard config.enabled, Self.isSupported, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Re-bind live when settings change (toggle, allowlist edits, mute). Starts or
    /// stops the loop to match the new `enabled`.
    func updateConfig(_ config: Config) {
        let wasEnabled = self.config.enabled
        self.config = config
        self.allowlist = Self.indexed(config.allowlist)
        if !config.enabled {
            loop?.cancel()
            loop = nil
            state = DetectorState()
        } else if !wasEnabled {
            startLoop()
        }
    }

    /// One poll tick: scan, decide, maybe fire. Returns the interval to wait next.
    private func pollOnce() -> Duration {
        let active = AudioProcessScanner.processesCapturingInput(excludingPID: selfPID)
        let candidate = Self.bestCandidate(active, allowlist: allowlist)
        let now = Date().timeIntervalSince1970
        let (newState, offer) = Self.decide(state: state, candidate: candidate, now: now, config: config)
        state = newState
        if let offer {
            onDetect?(MeetingSignal(confidence: offer.confidence, appBundleID: offer.bundleID,
                                    appName: offer.appName, tier: offer.tier, startedAtUnix: now))
        }
        return config.pollInterval
    }

    /// Record that the current session was dismissed so it never re-offers. When
    /// `mute` is set (an explicit Dismiss tap, not a soft auto-hide), tally it and —
    /// for browser-tier and unknown, non-allowlisted apps — mute the app after the
    /// threshold. Dedicated meeting apps never auto-mute.
    func markSessionDismissed(_ bundleID: String?, mute: Bool) {
        state.dismissed = true
        guard mute, let id = bundleID else { return }
        dismissalCounts[id, default: 0] += 1
        // Explicit dedicated meeting apps almost always mean a recordable call, so
        // they never auto-mute. Everything weaker mutes after 2 dismissals: browsers
        // (a call *may* have started) AND unknown, non-allowlisted apps. That cap is
        // what makes always-offering-for-unknown-apps safe — two dismissals silence a
        // noisy app for good. (The consent banner still gates every actual recording.)
        let threshold: Int
        switch allowlist[id]?.tier {
        case .meetingApp: threshold = Int.max
        case .browser, nil: threshold = 2
        }
        if dismissalCounts[id, default: 0] >= threshold, !config.muted.contains(id) {
            config.muted.insert(id)
            onMute?(id)
        }
    }

    // MARK: MeetingContextProvider

    /// One-shot probe: is a meeting likely happening right now? Reports any mic-hot
    /// app (so 04/05 can read a low-confidence signal); the *offer* gate lives in the
    /// poll loop, not here. `bestCandidate` now returns any mic-hot app regardless of
    /// the allowlist, so this probe is unchanged — it always reported unknown apps too.
    func detectActiveMeeting() async -> MeetingSignal? {
        guard Self.isSupported else { return nil }
        let active = AudioProcessScanner.processesCapturingInput(excludingPID: selfPID)
        guard let c = Self.bestCandidate(active, allowlist: allowlist) else { return nil }
        return MeetingSignal(confidence: c.confidence, appBundleID: c.bundleID,
                             appName: c.appName, tier: c.tier,
                             startedAtUnix: Date().timeIntervalSince1970)
    }

    /// Calendar naming / attendees — owned by feature 04 (EventKit). Returns nil
    /// here so this provider can ship the detection seam independently.
    func eventContext(at date: Date) async -> MeetingEventContext? { nil }

    // MARK: - Pure decision logic (testable without Core Audio)

    /// The highest-confidence mic-hot process for a poll, already mapped to a tier.
    struct DetectionCandidate: Equatable, Sendable {
        var bundleID: String?
        var appName: String?
        var tier: MeetingApp.Tier?
        var confidence: Double
    }

    /// Ephemeral session/debounce state, evolved by `decide`. Intentionally not
    /// persisted (§6 of the design doc): a relaunch mid-call simply re-detects.
    struct DetectorState: Equatable, Sendable {
        var sessionBundleID: String?
        var sessionStartUnix: Double?
        var highStreak: Int = 0
        var offered: Bool = false
        var dismissed: Bool = false
        var lastSeenUnix: Double?
    }

    /// Pick the highest-confidence mic-hot process. Every mic-hot process is now
    /// offer-worthy: allowlisted apps (meeting/browser) at their tier confidence, and
    /// unknown, non-allowlisted apps at the low `micHotOnly` floor. (The old opt-in
    /// "offer for any mic app" gate is gone — adaptive two-dismissal muting in
    /// `markSessionDismissed` caps the resulting noise instead.) Returns nil only when
    /// nothing is on the mic. (`max` keeps the strongest, so "Zoom + Chrome both on the
    /// mic" names Zoom.)
    static func bestCandidate(_ active: [ActiveInputProcess],
                              allowlist: [String: MeetingApp]) -> DetectionCandidate? {
        guard !active.isEmpty else { return nil }
        let ranked = active.map { proc -> DetectionCandidate in
            let app = proc.bundleID.flatMap { allowlist[$0] }
            let confidence: Double
            switch app?.tier {
            case .meetingApp: confidence = Confidence.meetingApp
            case .browser: confidence = Confidence.browser
            case nil: confidence = Confidence.micHotOnly
            }
            return DetectionCandidate(bundleID: proc.bundleID, appName: app?.displayName,
                                      tier: app?.tier, confidence: confidence)
        }
        return ranked.max(by: { $0.confidence < $1.confidence })
    }

    /// Evolve the session/debounce state by one poll and decide whether to fire an
    /// offer. Pure: no Core Audio, no clock — `now` and `candidate` are supplied, so
    /// a synthetic sequence can be replayed in tests.
    ///
    /// - A muted candidate is treated as "nothing offer-worthy".
    /// - A new app (or first sighting) starts a session; the same app sustained for
    ///   `startConfirmPolls` polls fires the offer exactly once.
    /// - A dismissed session never re-offers; once the trigger has been gone for
    ///   `endDebounce` seconds the session resets, so a later call re-offers.
    static func decide(state: DetectorState,
                       candidate: DetectionCandidate?,
                       now: Double,
                       config: Config) -> (state: DetectorState, offer: DetectionCandidate?) {
        var s = state

        // Treat a muted app as no candidate.
        let effective: DetectionCandidate?
        if let c = candidate, let id = c.bundleID, config.muted.contains(id) {
            effective = nil
        } else {
            effective = candidate
        }

        guard let c = effective else {
            // No offer-worthy app this poll. End the session once the trigger has
            // been absent past the debounce window.
            if let last = s.lastSeenUnix, now - last > config.endDebounce {
                s = DetectorState()
            }
            return (s, nil)
        }

        if s.sessionBundleID != c.bundleID {
            // A different app (or none before) → a fresh meeting session.
            s = DetectorState(sessionBundleID: c.bundleID, sessionStartUnix: now,
                              highStreak: 1, offered: false, dismissed: false, lastSeenUnix: now)
        } else {
            s.highStreak += 1
            s.lastSeenUnix = now
        }

        if !s.offered, !s.dismissed, s.highStreak >= config.startConfirmPolls {
            s.offered = true
            return (s, c)
        }
        return (s, nil)
    }
}
