import Foundation

// Pure decision logic for the first-run onboarding, kept free of SwiftUI/TCC so it
// can be unit-tested. The views and `PermissionsModel` only feed it facts.

/// The three TCC permissions Talkie asks for.
enum PermissionKind: CaseIterable, Sendable {
    case microphone, inputMonitoring, accessibility
}

/// What a permission row's button does right now.
enum PermissionRowAction: Equatable, Sendable {
    /// Already granted: no button, a check mark.
    case granted
    /// The system dialog can still appear: the button reads "Grant" and asks.
    case request
    /// The system dialog can no longer appear (denied, restricted, or already shown
    /// once): the button reads "Open System Settings" and opens the right pane.
    case openSettings

    /// `canShowSystemPrompt` is whether a request would still show the system
    /// dialog. After the first decision macOS makes every request a silent no-op,
    /// which used to leave the row as a dead button.
    static func decide(granted: Bool, canShowSystemPrompt: Bool) -> PermissionRowAction {
        if granted { return .granted }
        return canShowSystemPrompt ? .request : .openSettings
    }
}

/// The permission-state half of the Input Monitoring retry (the tap can only be
/// installed once the grant exists, and macOS does not tell the app it landed).
enum HotKeyTapRetry {
    /// Retry installing the tap when a poll first sees the Input Monitoring grant.
    static func shouldRetry(wasGranted: Bool, isGranted: Bool) -> Bool {
        isGranted && !wasGranted
    }

    /// Whether the relaunch hint must show after a retry: the grant is present but
    /// the tap would not install in this process.
    static func needsRelaunch(granted: Bool, tapInstalled: Bool) -> Bool {
        granted && !tapInstalled
    }
}

/// Headline and body of the permissions step, driven by how many rows still need a
/// grant (the step always lists all three, granted ones with a check).
enum OnboardingPermissionsCopy {
    /// Localisation key for the heading.
    static func headingKey(missing: Int) -> String {
        switch missing {
        case ...0: return "Permissions are set"
        case 1:    return "One more permission"
        case 2:    return "Two more permissions"
        default:   return "Three permissions"
        }
    }

    /// Localisation key for the body.
    static func bodyKey(missing: Int) -> String {
        missing <= 0
            ? "Everything dictation needs is on. Each is used only on this Mac."
            : "To hear you, notice your dictation key, and place your text into other apps, dictation needs these. Each is used only on this Mac."
    }
}

/// Which permissions the dictation key needs, and how the last step's button reads.
struct OnboardingReadiness: Equatable, Sendable {
    var microphone: Bool
    var inputMonitoring: Bool
    var accessibility: Bool

    /// The dictation key needs all three.
    var canDictate: Bool { microphone && inputMonitoring && accessibility }

    /// The permissions still missing, in display order.
    var missing: [PermissionKind] {
        var out: [PermissionKind] = []
        if !microphone { out.append(.microphone) }
        if !inputMonitoring { out.append(.inputMonitoring) }
        if !accessibility { out.append(.accessibility) }
        return out
    }

    /// Localisation key for the last step's primary button. Finishing without the
    /// grants stays allowed, but the label says what that means.
    var finishTitleKey: String {
        canDictate ? "Start dictating" : "Finish without the dictation key"
    }
}

extension PermissionKind {
    /// Localisation key for the permission's name.
    var nameKey: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }
}

/// The state of the on-device speech model, as the try-it steps show it.
enum SpeechModelPhase: Equatable, Sendable {
    /// Not known yet (or not reported by macOS).
    case unknown
    /// macOS is downloading it. `fraction` is nil when the API gives no progress.
    case downloading(fraction: Double?)
    case installed
    case failed

    /// Show the visible "Downloading the speech model" state.
    var showsDownloadNotice: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// The "turn off Wi-Fi" dare only makes sense once the model is on this Mac;
    /// before that, cutting the network would make the dictation fail or hang.
    var offersOfflineDare: Bool { self == .installed }

    /// Clamped progress for a determinate bar, or nil for an indeterminate one.
    var progressFraction: Double? {
        guard case .downloading(let fraction) = self, let fraction, fraction.isFinite else { return nil }
        return min(1, max(0, fraction))
    }
}
