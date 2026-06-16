import Foundation
import AppKit
import Combine

/// Where the updater is in its check → download → install lifecycle. Drives the
/// "App updates" card in Developer settings.
public enum UpdateState: Sendable, Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case downloading(Double?)   // nil = indeterminate
    case installing
    case failed(String)
}

/// The in-app updater (dev-tools flavor only): checks the GitHub `dev-*` channel,
/// downloads the newest prebuilt Talkie, and swaps this app in place. A singleton
/// so the launch-time auto-check and the settings card share one state.
@MainActor
public final class AppUpdater: ObservableObject {
    public static let shared = AppUpdater()

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var auth: UpdaterAuth = .none
    @Published public var autoCheckOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoCheckOnLaunch, forKey: Self.autoKey) }
    }

    /// The running build's marketing version and build number (CFBundleVersion),
    /// the latter compared against `dev-<build>` tags to detect a newer release.
    public let currentVersion: String
    public let currentBuild: Int

    private static let autoKey = "TalkieUpdaterAutoCheck"

    private init() {
        let info = Bundle.main.infoDictionary
        currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "—"
        currentBuild = Int((info?["CFBundleVersion"] as? String) ?? "") ?? 0
        // Default ON for the dev flavor: collaborators should land on the newest
        // build without thinking about it.
        if UserDefaults.standard.object(forKey: Self.autoKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoKey)
        }
        autoCheckOnLaunch = UserDefaults.standard.bool(forKey: Self.autoKey)
        refreshAuth()
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var token: String? { UpdaterKeychain.token() }

    /// Recompute the auth mode (prefers an already-authenticated `gh` CLI, then a
    /// stored token). `gh` detection spawns a process, so it runs off the main actor.
    public func refreshAuth() {
        Task { await refreshAuthAwait() }
    }

    private func refreshAuthAwait() async {
        let ghAuthed = await Task.detached { GH.isAuthenticated() }.value
        if ghAuthed {
            auth = .githubCLI
        } else if token != nil {
            auth = .token
        } else {
            auth = .none
        }
    }

    /// Check the dev channel. When `announce` is true (the launch-time check), an
    /// available update is surfaced with a modal prompt instead of waiting for the
    /// user to open settings.
    public func check(announce: Bool = false) async {
        guard !isBusy else { return }
        state = .checking
        await refreshAuthAwait()
        guard auth != .none else {
            state = .failed(UpdaterError.notAuthenticated.errorDescription ?? "Not connected to GitHub.")
            return
        }
        do {
            let fetcher = ReleaseFetcher(auth: auth, token: token)
            guard let latest = try await fetcher.latest() else {
                state = .upToDate
                return
            }
            if latest.build > currentBuild {
                state = .available(latest)
                if announce { promptInstall(latest) }
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(message(for: error))
        }
    }

    /// Download the available release and swap it in. Only valid from `.available`.
    public func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        do {
            state = .downloading(nil)
            let fetcher = ReleaseFetcher(auth: auth, token: token)
            let zip = try await fetcher.download(release, to: UpdaterPaths.updatesDir()) { [weak self] p in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(p)
                }
            }
            state = .installing
            try await UpdateInstaller.installAndRelaunch(zip: zip)
            // On success the app terminates inside installAndRelaunch.
        } catch {
            state = .failed(message(for: error))
        }
    }

    public func saveToken(_ token: String) {
        UpdaterKeychain.setToken(token)
        refreshAuth()
    }

    public func clearToken() {
        UpdaterKeychain.deleteToken()
        refreshAuth()
    }

    // MARK: - Internals

    private func promptInstall(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "Talkie build \(release.build) is available"
        alert.informativeText = release.notes.isEmpty
            ? "You're on build \(currentBuild). Update now?"
            : release.notes
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await downloadAndInstall() }
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
